#!/usr/bin/env bash
#
# 为 QNAP QHora-301W 准备 OpenWrt 构建环境。
#
#   1. 追加 NSS feed，更新 feed；引入官方 feed 没有的包；安装全部 feed
#      · ddns-go / msd_lite 用本仓库自带配方（packages/net/*，直接引上游源码），
#        版本由 resolve-versions.sh 在构建时解析注入
#      · luci-app-ddns-go / luci-app-msd_lite 是纯前端，从 ImmortalWrt 稀疏检出
#      · luci-app-passwall2 + 17 个依赖组件取自 Openwrt-Passwall 组织的仓库，
#        直接用上游当前 main（这些配方与上游版本同步维护，不需要我们注入版本）
#   2. 把 configs/common.config + configs/qhora_301w.config 拼成 .config，跑 make defconfig
#   3. 校验 defconfig 没有静默丢弃符号（Kconfig 在依赖不满足时会无声地去掉选项）
#   4. 关闭 NSS feed 的整体打包（feeds.conf 里声明了，但我们只要 .config 里显式选的包）
#   5. 扫描出厂预置（files*/etc/config/），命中节点凭据 / 订阅链接就中断构建
#      —— 固件是公开产物，凭据进来就等于公开
#   6. 叠加 files/ 覆盖文件，再叠一层 files-<PROXY_STACK>/（变体专属）
#   6b.（仅 PROXY_STACK=homeproxy）先断言出厂配置确实走"本地规则集"这条路
#      （routing_mode=custom 且 ruleset 全是 type=local），再把 9 个 .srs
#      规则集刷成上游最新版并放进覆盖层 —— 固件里这些 ruleset 是
#      type=local + path，首次启动零下载，不会出现"规则下载失败 ⇒
#      sing-box 起不来 ⇒ dnsmasq 已把 DNS 劫持到 5333 ⇒ 整个 LAN 断网"这条链。
#      断言是必需的：模式不对时预置会**静默失效**（见 6b 处的注释）。
#   7. 把 patches/kernel/<KERNEL_PATCHVER>/ 下的补丁注入上游内核源码树
#      （当前只有一条：arm64 的 /proc/cpuinfo 补 model name，修首页「架构」显示 ?）
#
# 必需的环境变量：
#   OPENWRT_DIR      已检出的 OpenWrt 源码目录（必须是 git 工作区）
#   BUILDER_DIR      本仓库的检出目录
# 可选：
#   NSS_FEED         NSS feed 的 src-git 行，默认指向 edma-nss 分支
#   GH_TOKEN         查 GitHub API 用，避免未认证限额（Actions 里默认注入）
#   PROXY_STACK      代理栈：passwall2（默认）| homeproxy | dae | daed
#                    homeproxy 时额外拼接 configs/homeproxy.config（覆盖层），
#                    并把 feed 断言换成 homeproxy 那一组；默认值下本文件
#                    的行为与以前完全一致。传给 extra-packages.sh 的是同一个变量。
#                    同时决定叠加哪个变体覆盖目录：files-passwall2/ 或
#                    files-homeproxy/（不存在就跳过）。
#   DDNS_GO_VERSION  钉死 ddns-go 版本，例如 6.17.7（默认跟随上游最新 release）
#   MSD_LITE_SHA     钉死 msd_lite 的 commit sha（默认跟随上游 master HEAD）
#   EXTRA_CONFIG     再追加一层 .config 覆盖层（后拼接者覆盖前者）。只有
#                    immortalwrt 线（scripts/prepare-build-imm-nss.sh）会设它：
#                    换成 ImmortalWrt 基座后个别符号与 openwrt 不同，那些差异
#                    只对那条线成立，不能写进 common.config。不设则行为不变。
#   RULESETS_REFRESH 仅 PROXY_STACK=homeproxy 有意义。1（默认）= 构建时从上游
#                    拉最新 .srs；0 = 只用仓库内置的固定版（完全不联网）。
#   RULESETS_STRICT  仅 PROXY_STACK=homeproxy 有意义。1 = 规则集没拿到最新版
#                    就中断构建（默认 0：下载失败退回仓库副本并告警，照常出固件）。
#   SINGBOX_MODE     仅 PROXY_STACK=homeproxy 有意义，原样透传给 extra-packages.sh：
#                    fixed（默认）= 把 sing-box 钉回 1.12.25（旧线的组合）；
#                    builtin = 用基座自带的那一对（基座是 immortalwrt 的线走这条）；
#                    latest = 给 HomeProxy 打 1.13+ 兼容补丁（已过时，见该脚本）。
#   SINGBOX_PKGS_REF 仅 SINGBOX_MODE=fixed 有意义：从 immortalwrt/packages 的哪个
#                    ref 取那份 1.12.25，默认发布分支 openwrt-25.12。
#                    **故意不跟 IMM_REF 走** —— master 上的 1.12.25 已在
#                    2026-10-15 被 1.14.3 取代，跟着 master 走这条通道必然失败。
#
set -Eeuo pipefail

# ── CI 可诊断性 ──────────────────────────────────────────────
# 这个脚本跑在 GitHub Actions 上，而 job 日志要仓库 admin 权限才能下载，
# 失败时远程完全看不到原因。所以：
#   · 全部输出同时落盘到 $LOG_FILE（供回放）
#   · 失败时把「出错行号 + 出错命令 + 日志尾部」输出成 ::error::，
#     那会变成 check-run annotation —— 公开可读，远程就能定位。
#
# 两个必须绕开的坑：
#   1) 不能拿 fd1/fd2 当"留给注解"的通道。fd1/fd2 被重定向到日志文件后，
#      bash 对普通文件是块缓冲的，脚本 exit 时缓冲区里最后几 KB 根本没落盘，
#      而 _dump_log_tail 是用 tail 去读那个文件的 —— 翻了半天看不到关键行，
#      就是这个原因。所以原始终端另存成 fd3，注解一律写 >&3，
#      而写日志用 tee（tee 自己不做用户态缓冲，立刻落盘）。
#   2) GitHub 对每个 step 的注解数量有上限，超出的会被丢掉。所以日志尾部只截
#      少量行，并且把最重要的那句放在最后输出。
LOG_FILE="${LOG_FILE:-${GITHUB_WORKSPACE:-${RUNNER_TEMP:-/tmp}}/prepare-build.log}"
: >"$LOG_FILE" 2>/dev/null || LOG_FILE=/tmp/prepare-build.log
exec 3>&1 4>&2            # 原始终端另存为 fd3；之后 fd1/fd2 全部进日志
exec >>"$LOG_FILE" 2>&1

# 一条注解 = 原始 stdout → Actions 日志流 → check-run annotation。
ann() { printf '%s\n' "$*" >&3; }

# 把日志最后 n 行发成注解。空行跳过：GitHub 会去重，空行只是白占配额。
_dump_log_tail() {
  local n="${1:-6}"
  tail -n "$n" "$LOG_FILE" 2>/dev/null | while IFS= read -r l; do
    case "$l" in *[![:space:]]*) ;; *) continue ;; esac
    ann "::error::[log] $l"
  done
}

# 打印某个符号在生成出来的 kconfig 里的定义。这是定位"为什么被丢弃"的
# 直接证据（有没有 prompt、default 是什么、depends on 什么），只写日志，
# 因为它有几十行，塞成注解会把注解配额吃光。
#
# 传进来的名字要去掉 CONFIG_ 前缀：.config 里叫 CONFIG_PACKAGE_foo，
# 而生成的 kconfig 里那个符号叫 PACKAGE_foo。包在 tmp/.config-package.in，
# target 选项在 tmp/.config-target.in，所以几个都找一遍。
_dump_symbol_def() {
  local sym="$1" f hit=0
  for f in tmp/.config-package.in tmp/.config-target.in tmp/.config.in; do
    [[ -f "$f" ]] || continue
    grep -qE "^[[:space:]]*config[[:space:]]+${sym}[[:space:]]*$" "$f" || continue
    hit=1
    printf '\n----- kconfig 定义：%s（来自 %s）-----\n' "$sym" "$f"
    awk -v sym="$sym" '
      {
        line = $0
        sub(/^[ \t]+/, "", line)
        sub(/[ \t]+$/, "", line)
        if (line == "config " sym) { inblk = 1; print "  " line; next }
        if (inblk && line ~ /^config /) exit
        if (inblk && (line == "endmenu" || line == "endif" || line == "menu")) exit
        if (inblk) print "  " line
      }
    ' "$f" | head -40
  done
  ((hit)) || printf '\n（%s 不在任何生成的 kconfig 里，说明这个包根本没被扫描到）\n' "$sym"
}

_on_error() {
  local rc=$? line="$1" cmd="$2"
  _dump_log_tail "${LOG_TAIL_LINES:-6}"
  ann "::error::失败命令：${cmd}"
  ann "::error::prepare-build.sh 在第 ${line} 行失败（退出码 ${rc}）"
  exit "$rc"
}
trap '_on_error "$LINENO" "$BASH_COMMAND"' ERR

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
BUILDER_DIR="${BUILDER_DIR:?BUILDER_DIR 未设置}"
NSS_FEED="${NSS_FEED:-src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;edma-nss}"

# log/warn 同时进日志和 CI 控制台，这样远程也能看到进度。
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&3; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&3; }
# 除了第一条消息之外，后面每个参数都单独发一条注解放最后。
# 注解有数量上限，超出的会被 GitHub 丢掉 —— 具体的符号名是最要紧的信息，
# 所以它必须是最晚发出的那几条。
die()  {
  local msg="$1"; shift
  printf '\033[1;31m[x]\033[0m %s\n' "$msg" | tee -a "$LOG_FILE" >&3
  _dump_log_tail "${LOG_TAIL_LINES:-6}"
  ann "::error::$msg"
  local x
  for x in "$@"; do ann "::error::  $x"; done
  exit 1
}

# 代理栈 profile。决定拼哪几份 config、以及断言哪些包真的被 feed 接管。
#   passwall2（默认）—— 与以前完全一致：common + 机型
#   homeproxy         —— 再追加 configs/homeproxy.config 作为覆盖层
#                        （它把 passwall2 那组符号用 =n 按掉，见该文件头部）
PROXY_STACK="${PROXY_STACK:-passwall2}"

CONFIGS=(
  "$BUILDER_DIR/configs/common.config"
  "$BUILDER_DIR/configs/qhora_301w.config"
)
case "$PROXY_STACK" in
  passwall2) ;;
  homeproxy) CONFIGS+=( "$BUILDER_DIR/configs/homeproxy.config" ) ;;
  dae)       CONFIGS+=( "$BUILDER_DIR/configs/dae.config" ) ;;
  daed)      CONFIGS+=( "$BUILDER_DIR/configs/daed.config" ) ;;
  *) die "不认识的 PROXY_STACK：$PROXY_STACK（只支持 passwall2 / homeproxy / dae / daed）" ;;
esac

# 可选：再追加一层覆盖层（同样"后拼接者覆盖前者"）。
# 只有 immortalwrt 线（scripts/prepare-build-imm-nss.sh）会设它 —— 基座换成
# ImmortalWrt 之后，个别包名 / 符号取值与 openwrt 不同，那些差异只对那条线
# 成立，写进 common.config 会连累两条老线，所以单独放一层。
#
# ⚠️ 不设 EXTRA_CONFIG 时以下代码一行都不执行 —— 两条老线的行为与以前**完全一致**。
if [[ -n "${EXTRA_CONFIG:-}" ]]; then
  [[ -f "$EXTRA_CONFIG" ]] || die "EXTRA_CONFIG 指向的配置文件不存在：$EXTRA_CONFIG"
  log "追加覆盖层：${EXTRA_CONFIG##*/}"
  CONFIGS+=( "$EXTRA_CONFIG" )
fi

# 关于符号校验：不在这里维护一份"我认为重要的符号"清单。
# 要断言什么，由 CONFIGS 里实际写了的符号决定（见下面的步骤 3）——
# 清单式的写法会把 DEVICE_PACKAGES 带入的包（如 ipq-wifi-qnap_301w）
# 也算进来，而那种包根本不会以 CONFIG_PACKAGE_* 的形式出现在 .config 里
# （image.mk 用 CONFIG_TARGET_DEVICE_PACKAGES_* 传字符串），必然误报。

for f in "${CONFIGS[@]}"; do
  [[ -f "$f" ]] || die "找不到配置文件：$f"
done

# ── 1. feed ──────────────────────────────────────────────────
[[ -f "$OPENWRT_DIR/feeds.conf" ]] || cp "$OPENWRT_DIR/feeds.conf.default" "$OPENWRT_DIR/feeds.conf"

if ! grep -qxF "$NSS_FEED" "$OPENWRT_DIR/feeds.conf"; then
  log "追加 NSS feed：$NSS_FEED"
  printf '%s\n' "$NSS_FEED" >> "$OPENWRT_DIR/feeds.conf"
else
  log "NSS feed 已存在，跳过追加"
fi

cd "$OPENWRT_DIR"

# 把实际生效的 feed 配置打进日志：配置错误会让 feeds 在解析阶段直接 die。
log "feeds.conf 实际内容："
sed 's/^/    /' feeds.conf | tee -a "$LOG_FILE" >&3

log "更新全部 feed（最耗时的一步）"
./scripts/feeds update -a

log "feeds update 完成，feeds/ 下有："
ls -1 feeds/ 2>/dev/null | sed 's/^/    /' | tee -a "$LOG_FILE" >&3 || true

# 官方 feed 里没有 ddns-go / msd_lite。
#   · 这两个带二进制的包 → 本仓库自带配方（直接引上游源码，版本构建时解析）
#   · 它们的 LuCI 前端 → 从 ImmortalWrt 稀疏检出（纯页面，没有可指的独立上游）
# 必须在 install 之前、update 之后：update 负责把 feeds/ 目录建出来，
# install 读的是索引文件，看不到中途塞进去的包。
log "引入官方 feed 之外的包（PROXY_STACK=${PROXY_STACK}）"
OPENWRT_DIR="$OPENWRT_DIR" BUILDER_DIR="$BUILDER_DIR" PROXY_STACK="$PROXY_STACK" \
  SINGBOX_MODE="${SINGBOX_MODE:-fixed}" SINGBOX_VERSION="${SINGBOX_VERSION:-}" \
  SINGBOX_EXPECT="${SINGBOX_EXPECT:-}" SINGBOX_PKGS_REF="${SINGBOX_PKGS_REF:-}" \
  bash "$BUILDER_DIR/scripts/extra-packages.sh"

# 解析这两个包的上游最新版本，注入到刚落位的自带配方里 —— 这是「上游一发新版，
# 下次构建就自动是新的」的实现处。失败不中断构建（配方里有兜底版本），
# 只发 warning 注解，并把最终生效的版本发成 notice 注解（公开可读）。
log "解析上游包最新版本（ddns-go / msd_lite）"
if ! OPENWRT_DIR="$OPENWRT_DIR" \
     GH_TOKEN="${GH_TOKEN:-}" \
     DDNS_GO_VERSION="${DDNS_GO_VERSION:-}" \
     MSD_LITE_SHA="${MSD_LITE_SHA:-}" \
     bash "$BUILDER_DIR/scripts/resolve-versions.sh"; then
  warn "版本解析脚本异常退出，两个包都沿用配方里的兜底值"
fi

# 重建索引。-i 只重扫目录、不执行 git pull，所以不会碰刚拷进去的文件。
log "重建 feed 索引（不拉取仓库）"
./scripts/feeds update -i -a

log "安装全部 feed"
./scripts/feeds install -a

log "feeds install 完成，package/feeds/ 下有："
ls -1 package/feeds/ 2>/dev/null | sed 's/^/    /' | tee -a "$LOG_FILE" >&3 || true

# 确认这些引入的包真的被 install 认领了（索引没重建的话这一步会漏）。
for p in ddns-go msd_lite; do
  [[ -e "package/feeds/packages/$p" ]] \
    || die "package/feeds/packages/$p 不存在，引入的包没有被 feeds install 接管"
done
# autocore 有两种合法来源：
#   · 老两条线（openwrt main 基座）：主树里没有它 ⇒ 由 extra-packages.sh 落位到
#     feeds/packages/emortal/autocore，再被 feeds install 接管；
#   · immortalwrt 线：**基座主树自带**（package/emortal/autocore），而
#     feeds install 不会用 feed 覆盖主树包（"Not overriding core package"），
#     所以 feeds 里那份会被跳过 —— 这是正常的，主树那份就是我们要的
#     （本仓库的配方本来就是从 ImmortalWrt 主树抄来的）。
# 两种位置都算"就位"，缺了才算错。
if [[ -e package/feeds/packages/autocore ]]; then
  :
elif [[ -e package/emortal/autocore ]]; then
  log "autocore 来自基座主树（package/emortal/autocore），ImmortalWrt 自带这份"
else
  die "autocore 既不在 feed 也不在基座主树里" \
      "（package/feeds/packages/autocore 与 package/emortal/autocore 都不存在）"
fi

if [[ "$PROXY_STACK" == "homeproxy" ]]; then
  # ── homeproxy 版 ──────────────────────────────────────────
  # 代理前端只有一个包（homeproxy 是单包自包含的），代理核心只有一个
  # sing-box —— 而且它必须是我们从 ImmortalWrt 覆盖过来的那份：
  # 官方 feed 的是 1.14.0，HomeProxy 生成的配置会在 sing-box check 上
  # 直接 FATAL，服务起不来（详见 configs/homeproxy.config 头部）。
  for p in luci-app-ddns-go luci-app-msd_lite luci-app-homeproxy; do
    [[ -e "package/feeds/luci/$p" ]] \
      || die "package/feeds/luci/$p 不存在，引入的包没有被 feeds install 接管"
  done
  [[ -e "package/feeds/packages/sing-box" ]] \
    || die "package/feeds/packages/sing-box 不存在，sing-box 没有被 feeds install 接管"
  # 确认 sing-box 那边处于什么状态。分两类：
  #   builtin（= 基座自带的组合，immortalwrt 线）：HomeProxy 与 sing-box 由同一个
  #     上游同步维护、已互相适配，用 1.14.x 本来就是对的 —— 不做 1.12.x 判断；
  #   其余（fixed / latest，老两条 nss-edma 线）：确认落位的是 ImmortalWrt 那份
  #     1.12.x 配方，而不是官方 1.14.0。
  sb_ver="$(sed -n 's/^PKG_VERSION:=\s*//p' package/feeds/packages/sing-box/Makefile 2>/dev/null | head -n1)"
  if [[ "${SINGBOX_MODE:-fixed}" == "builtin" ]]; then
    log "sing-box 配方版本：${sb_ver:-未知}（SINGBOX_MODE=builtin —— 用基座自带的那份，不换版本、不打补丁）"
  else
    case "$sb_ver" in
      1.12.*) log "sing-box 配方版本确认：$sb_ver（ImmortalWrt 那份，与 HomeProxy 匹配）" ;;
      *) warn "sing-box 配方版本是 ${sb_ver:-未知}，不是 1.12.x —— HomeProxy 可能无法启动（1.13 起删除了它仍在用的 inbound 字段）" ;;
    esac
  fi
elif [[ "$PROXY_STACK" == "dae" ]]; then
  # ── dae 版 ────────────────────────────────────────────────
  # dae 与 luci-app-dae 都在**基座自带 feed** 里：extra-packages.sh 的 dae 分支
  # 一个仓库都没拉，所以这里只核对"feeds install 之后它们真的在 package/feeds/ 下"
  # —— 少了就说明 feed 没更新到含 dae 的版本（dae 2023 年就进了 immortalwrt/packages，
  # 真缺了通常是 imm_pkgs 被钉到了很旧的 ref）。
  for p in luci-app-ddns-go luci-app-msd_lite luci-app-dae; do
    [[ -e "package/feeds/luci/$p" ]] \
      || die "package/feeds/luci/$p 不存在，引入的包没有被 feeds install 接管"
  done
  for p in dae v2ray-geodata; do
    [[ -e "package/feeds/packages/$p" ]] \
      || die "package/feeds/packages/$p 不存在（dae 本体或它依赖的 geo 数据配方缺失）"
  done
  # dae 是 eBPF(CO-RE) 程序：内核没有 BTF 时它**编得出来、刷得进去、跑不起来**。
  # 这一层只能看配置，真正的证据在产物阶段（vmlinux 的 .BTF 段大小）。
  btf_req="$(grep -c '^CONFIG_KERNEL_DEBUG_INFO_BTF=y' "${CONFIGS[@]}" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
  [[ "${btf_req:-0}" -ge 1 ]] \
    || die "配置里没有 CONFIG_KERNEL_DEBUG_INFO_BTF=y —— dae 的 CO-RE 前提不成立" \
           "（检查 configs/dae.config 的内核段）"
  log "dae 与 luci-app-dae 已就位；内核 BTF 已请求（产物阶段会验 vmlinux 的 .BTF 段）"

  # 把 feed 里写死的 dae 版本换成**上游最新 release**（或 DAE_VERSION 指定的版本）。
  # 为什么要这一步：immortalwrt/packages 的 dae 是 PKG_VERSION:=2.0.0 写死的，
  # 「拉最新 feeds」并不等于「编最新 dae」（2026-10-22 实测：feed 2.0.0 / 上游 2.1.1）。
  # 位置很关键：必须在 feeds install 之后（改的是 package/feeds 背后那份 Makefile）、
  # 且在建 .config 之前（版本号只影响下载与校验，不影响 PACKAGE_dae 符号）。
  # 没指定 DAE_VERSION 时脚本只 warn 不中断 —— API 抖动不该让两小时的编译白跑。
  log "解析 dae 上游版本（留空 DAE_VERSION = 跟随最新 release）"
  OPENWRT_DIR="$OPENWRT_DIR" GH_TOKEN="${GH_TOKEN:-}" DAE_VERSION="${DAE_VERSION:-}" \
    bash "$BUILDER_DIR/scripts/resolve-dae-version.sh" \
    || die "dae 版本解析失败：DAE_VERSION=${DAE_VERSION:-（未指定）}，详见上面的输出"
elif [[ "$PROXY_STACK" == "daed" ]]; then
  # ── daed 版（测试线）────────────────────────────────────────
  # daed 与 luci-app-daed 同样来自**基座自带 feed**，extra-packages.sh 的
  # daed 分支一个仓库都没拉，所以这里只核对 install 之后它们真的在 package/feeds/ 下。
  #
  # 与 dae 线的区别：daed 的内核不是单独一个 dae 包，而是 dae-wing 里嵌的；
  # 数据包叫 daed-geoip / daed-geosite（不是 dae-geoip / dae-geosite）。
  for p in luci-app-ddns-go luci-app-msd_lite luci-app-daed; do
    [[ -e "package/feeds/luci/$p" ]] \
      || die "package/feeds/luci/$p 不存在，引入的包没有被 feeds install 接管"
  done
  for p in daed daed-geoip daed-geosite v2ray-geodata; do
    [[ -e "package/feeds/packages/$p" ]] \
      || die "package/feeds/packages/$p 不存在（daed 本体 / geo 软链包 / geo 数据配方缺失）"
  done
  # daed 与 dae 共用 CO-RE 前提：内核没有 BTF 时它同样"编得出来、跑不起来"。
  btf_req="$(grep -c '^CONFIG_KERNEL_DEBUG_INFO_BTF=y' "${CONFIGS[@]}" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
  [[ "${btf_req:-0}" -ge 1 ]] \
    || die "配置里没有 CONFIG_KERNEL_DEBUG_INFO_BTF=y —— daed 的 CO-RE 前提不成立" \
           "（检查 configs/daed.config 的内核段）"
  log "daed 与 luci-app-daed 已就位；内核 BTF 已请求（产物阶段会验 vmlinux 的 .BTF 段）"
else
  for p in luci-app-ddns-go luci-app-msd_lite luci-app-passwall2; do
    [[ -e "package/feeds/luci/$p" ]] \
      || die "package/feeds/luci/$p 不存在，引入的包没有被 feeds install 接管"
  done
  # passwall 的依赖组件是个会变的集合（上游加组件时 extra-packages.sh 自动带上），
  # 所以这里只抽查几个**稳定必需**的，剩下的交给 .config 符号校验和产物校验。
  for p in xray-core sing-box chinadns-ng v2ray-geodata geoview tcping; do
    [[ -e "package/feeds/packages/$p" ]] \
      || die "package/feeds/packages/$p 不存在，passwall 组件没有被 feeds install 接管"
  done
fi

# 没有这个 feed，ATH11K_NSS_SUPPORT 会因依赖不满足而无法在 menuconfig 里选中。
[[ -d "$OPENWRT_DIR/feeds/nss" ]] || die "NSS feed 没有就位（feeds/nss 不存在），检查上面的 feeds 步骤"

# ── 2. 组装 .config ──────────────────────────────────────────
log "生成 .config：$(for f in "${CONFIGS[@]}"; do printf '%s ' "${f##*/}"; done)"
cat "${CONFIGS[@]}" > .config
log "make defconfig 开始（输入 $(wc -l < .config) 行）"
make defconfig
log "make defconfig 完成（输出 $(wc -l < .config) 行）"

# ── 3. 校验符号 ──────────────────────────────────────────────
# Kconfig 在依赖不满足时会**静默**丢掉选项。断言：配置文件里显式请求的每一个
# =y 符号都必须出现在 .config 里 —— 少了就说明依赖链断了，编出来的镜像会缺
# 功能，那比直接失败更糟。只断言 =y：请求 =n 的符号可能被别的包 select 回来，
# 那属于正常情况，不算丢失。
log "校验 defconfig 是否保留了配置文件请求的全部符号"
dropped=()
while IFS= read -r req; do
  grep -qxF "$req" .config || dropped+=("$req")
done < <(
  cat "${CONFIGS[@]}" |
    grep -E '^CONFIG_[A-Za-z0-9_-]+=' |
    awk -F= '{ last[$1] = $0 } END { for (s in last) print last[s] }' |
    grep -vE '=n$'
)
if ((${#dropped[@]})); then
  # 先把证据留全：每个被丢弃的符号，把它在生成的 kconfig 里的定义抄进日志，
  # 这样"为什么会被丢"（没有 prompt？default 不成立？depends 没满足？）
  # 不用靠猜。
  for s in "${dropped[@]}"; do
    sym="${s%%=*}"; _dump_symbol_def "${sym#CONFIG_}"
  done
  # 符号名交给 die 逐个发注解（它会把它们放在最后，不会被注解上限截掉）。
  die "defconfig 丢弃了 ${#dropped[@]} 个配置请求的符号，详见上面的注解与日志" \
      "${dropped[@]}"
fi
log "配置文件请求的符号全部保留"

# ── 4. 不要把整个自定义 feed 打进镜像 ───────────────────────
feed_name="$(awk '{print $2}' <<<"$NSS_FEED")"
log "关闭 CONFIG_FEED_${feed_name}（只保留 .config 里显式选中的包）"
sed -i "s/^CONFIG_FEED_${feed_name}=.*/# CONFIG_FEED_${feed_name} is not set/" .config

# ── 5. 出厂预置守卫：不许出现凭据 / 订阅链接 ─────────────────
# 固件是公开产物：覆盖层里任何节点地址 / 密码 / 订阅链接都会随镜像公开。
# 这一步把「不小心把机场订阅写进预置文件」挡在构建阶段。
log "扫描出厂预置（files*/etc/config/），确认没有节点凭据 / 订阅链接"
if ! cred_report="$(BUILDER_DIR="$BUILDER_DIR" bash "$BUILDER_DIR/scripts/check-no-credentials.sh" 2>&1)"; then
  mapfile -t _cred_hits <<<"$cred_report"
  die "出厂预置里出现了疑似凭据 / 订阅链接（固件是公开产物，绝不能有）" "${_cred_hits[@]}"
fi
log "$cred_report"

# ── 6. 叠加 files/ 与 files-<PROXY_STACK>/ ──────────────────
# files/               各变体共用（主机名、LAN 网段、首页硬件区块…）
# files-<PROXY_STACK>/ 只给对应变体叠加：
#                      files-passwall2/  → etc/config/passwall2
#                      files-homeproxy/  → etc/config/homeproxy + 9 个 .srs
#                      files-dae/        → etc/dae/config.dae + SSH 修复脚本
#                      files-daed/       → 目前不存在（daed 测试线刻意不带预置配置）
# 目录不存在就跳过；先叠共用、后叠变体，变体里的同名文件覆盖共用。
overlay_variant="$BUILDER_DIR/files-$PROXY_STACK"
for d in "$BUILDER_DIR/files" "$overlay_variant"; do
  [[ -d "$d" ]] || continue
  log "叠加覆盖文件：$(basename "$d")/"
  mkdir -p files
  # 用 cp -a 而不是 rsync：GitHub runner 上两者都有，但本地 Windows/MSYS 环境
  # 通常没有 rsync，用 cp 可以两边通用。斜杠点号保证是"合并"而不是"替换"。
  cp -a "$d/." files/
done

if [[ -d files/etc/ssh ]]; then
  # sshd 的配置文件不能对 group/other 可写，否则 openssh 会拒绝加载整个配置；
  # 一律收紧成 0600（git 只记可执行位，检出后权限是 0644，所以必须在这里补）。
  find files/etc/ssh -type f -exec chmod 0600 {} + 2>/dev/null || true
fi
# uci-defaults 里的脚本需要可执行位才会在首次启动时运行。
if [[ -d files/etc/uci-defaults ]]; then
  chmod 0755 files/etc/uci-defaults/* 2>/dev/null || true
fi
# 覆盖层里的命令（如 dae-switch）也要可执行位。git 只记 0755/0644 两种，
# 而 Windows 上检出后全是 0777 —— 统一在构建前拍平，别指望仓库里的模式。
if [[ -d files/usr/bin ]]; then
  chmod 0755 files/usr/bin/* 2>/dev/null || true
fi

# dae 的配置文件**必须是 0600**，否则 dae 根本起不来：
#     $ dae validate -c /etc/dae/config.dae
#     permissions 0777 for '/etc/dae/config.dae' are too open;
#     requires the file is NOT writable by the same group and NOT accessible by others
# 注意 0644 也不行（other 可读），只有 0640 / 0600 过得了。而 git 只记可执行位、
# Windows 上检出时还是 0777 —— 所以必须在这里统一收紧，别指望仓库里的模式。
if [[ -d files/etc/dae ]]; then
  find files/etc/dae -type f -exec chmod 0600 {} + 2>/dev/null || true
  log "dae 配置权限已收紧为 0600（dae validate 只接受 0640/0600）"
fi

# ── 6a. dae 覆盖层的两道断言 ───────────────────────────────────
# files-<PROXY_STACK>/ 是"目录不存在就静默跳过"的，写错目录名不会报错，
# 只会编出一份**没有骨架配置**的固件 —— 刷进去 dae 一启动就因为找不到
# /etc/dae/config.dae 而失败。所以在叠加之后点名核对。
#
# 第二道是安全闸：dae 的配置里天生就要填订阅/节点链接，而这个仓库和固件
# 都是公开的。骨架里只允许出现注释掉的示例，不允许出现有效的链接。
# （注意 dns 段的 'tcp+udp://dns.google:53' 是合法内容，所以只查 http(s)://
#   与分享链接协议头，不查任意 "://"。）
if [[ "$PROXY_STACK" == "dae" ]]; then
  dae_conf="files/etc/dae/config.dae"
  [[ -f "$dae_conf" ]] || die \
    "PROXY_STACK=dae 但覆盖层里没有 $dae_conf" \
    "（files/ 与 files-dae/ 都没提供 dae 出厂配置，检查覆盖目录名）"
  [[ -f files/etc/uci-defaults/97-ssh-login-fix ]] || die \
    "PROXY_STACK=dae 但缺少 files/etc/uci-defaults/97-ssh-login-fix" \
    "（出厂 root 密码为空 + LuCI 密钥路径不一致，删了它 SSH 就永远登不进去）"

  # 安全闸：允许的是**健康检查地址**（tcp_check_url / udp_check_dns /
  # bootstrap_resolver 这类公网探测点），禁止的是订阅链接与分享链接。
  if grep -vE '^[[:space:]]*#' "$dae_conf" |
       grep -vE '(tcp_check_url|udp_check_dns|bootstrap_resolver|fallback_resolver)[[:space:]]*:' |
       grep -qE '(vless|vmess|ss|ssr|trojan|hysteria2?|tuic|anytls)://|^[[:space:]]*[A-Za-z0-9_]+:[[:space:]]*.?https?://'; then
    die "dae 出厂配置里出现了**有效**的订阅链接或分享链接（固件是公开产物）" \
        "把值删掉、只保留注释掉的示例；真正的节点在设备上填"
  fi
  log "dae 出厂配置就位：无有效订阅/节点链接（订阅留空，实测该配置能通过 dae validate）"
fi

# ── 6b. HomeProxy 规则集：编译期刷新到最新版 ──────────────────
# 为什么固件里必须是 local 规则文件、不能是 remote：
#   remote 时 sing-box 是**在服务启动那一刻**才去下载的，而
#   /etc/init.d/homeproxy 早在那之前就把 dnsmasq 劫持到 127.0.0.1:5333 ——
#   9 条规则里任意一条下载失败（raw.githubusercontent.com 直连不通，能用的
#   代理又正是这个还没起来的服务），sing-box 就起不来，DNS 指向一个没人
#   监听的端口 ⇒ 整个 LAN 上不了网。文件预置进固件后这条链不存在。
#
# 这里做两件事：
#   ① 把 9 个 .srs 刷成上游最新（RULESETS_REFRESH=0 则用仓库里的固定版）；
#   ② 断言"清单 ↔ 出厂配置 ↔ uci-defaults"三处名字一致、文件都是合法 .srs。
# 下载失败默认不中断构建（用仓库兜底副本顶上 + ::warning::），
# 需要"必须最新才允许编"时设 RULESETS_STRICT=1。
if [[ "$PROXY_STACK" == "homeproxy" ]]; then
  # ── 6b-0. 前提断言：这份配置真的会走"本地规则集"那条路 ──────────────
  # generate_client.uc 第 62 行是 `if (routing_mode !== 'custom')` 的顶层分叉：
  #   非 custom 模式 → 走"自动生成"分支，它**完全忽略** UCI 里的 config
  #                    ruleset 节；bypass_mainland_china 还会另行硬编码注入
  #                    3 个 remote 规则集（geoip-cn / geosite-cn /
  #                    geosite-noncn，指向 fastly.jsdelivr.net，
  #                    download_detour='main-out'），在 run 阶段才下载
  #                    ⇒ "下载失败 ⇒ 起不来 ⇒ DNS 已被劫持到 5333"原样复现；
  #   custom 模式   → 才轮到下面预置的那 9 条 local。
  # 这个耦合不会报任何错、只会静默失效（预置白做、断网照旧），所以构建期拦死。
  hp_conf="files/etc/config/homeproxy"
  [[ -f "$hp_conf" ]] || die \
    "PROXY_STACK=homeproxy 但覆盖层里没有 $hp_conf" \
    "（files/ 与 files-homeproxy/ 都没提供出厂配置，检查覆盖目录）"

  hp_mode="$(awk -F"'" '/^[[:space:]]*option[[:space:]]+routing_mode/ {print $2; exit}' "$hp_conf")"
  if [[ "$hp_mode" != "custom" ]]; then
    die "HomeProxy 出厂配置的 routing_mode 是 '${hp_mode:-未设置}'，必须是 custom" \
        "非 custom 模式会忽略全部 config ruleset 节，并改用 3 个硬编码的 remote 规则集" \
        "（generate_client.uc:62）—— 预置的 9 个本地 .srs 会静默失效、首启断网复现" \
        "确实要换模式的话，得连本脚本与 README 的预期一起改，别只改这一行配置"
  fi

  hp_sections="$(grep -cE "^[[:space:]]*config[[:space:]]+ruleset[[:space:]]" "$hp_conf" || true)"
  hp_local="$(grep -cE "^[[:space:]]*option[[:space:]]+type[[:space:]]+'local'" "$hp_conf" || true)"
  if [[ "$hp_sections" != "$hp_local" ]]; then
    die "HomeProxy 出厂配置里有 ruleset 不是 type='local'（共 $hp_sections 节，只有 $hp_local 节是 local）" \
        "remote 规则集由 sing-box 在服务启动那一刻才下载，而 init.d 早已把 dnsmasq" \
        "劫持到 5333 —— 任一条下载失败即整个 LAN 断网。必须全部 type='local' + path"
  fi
  log "HomeProxy 出厂配置：routing_mode=custom，$hp_local 条规则集全为 local（预置生效的前提成立）"

  ruleset_dir="files/etc/homeproxy/ruleset"
  if [[ ! -d "$ruleset_dir" ]]; then
    die "PROXY_STACK=homeproxy 但覆盖层里没有 $ruleset_dir ——" \
        "出厂配置里的 ruleset 是 type=local + path，文件缺失会让 sing-box check 直接 FATAL"
  fi

  if [[ "${RULESETS_REFRESH:-1}" == "1" ]]; then
    log "HomeProxy 规则集：从上游拉取最新版（RULESETS_REFRESH=1）"
    run_env=()
    [[ "${RULESETS_STRICT:-0}" == "1" ]] && run_env+=( "--strict" )
    if ! bash "$BUILDER_DIR/scripts/fetch-homeproxy-rulesets.sh" \
           --dest "$ruleset_dir" \
           --manifest "$BUILDER_DIR/configs/homeproxy-rulesets.list" \
           --pinned "$BUILDER_DIR/files-homeproxy/etc/homeproxy/ruleset" \
           "${run_env[@]}" 2>&1 | sed 's/^/    /'; then
      die "HomeProxy 规则集处理失败"
    fi
  else
    log "HomeProxy 规则集：RULESETS_REFRESH=0，使用仓库内置的固定版本（不联网）"
    if ! bash "$BUILDER_DIR/scripts/fetch-homeproxy-rulesets.sh" \
           --dest "$ruleset_dir" \
           --manifest "$BUILDER_DIR/configs/homeproxy-rulesets.list" \
           --verify-only 2>&1 | sed 's/^/    /'; then
      die "HomeProxy 规则集校验失败（RULESETS_REFRESH=0 时要求仓库副本齐全）"
    fi
  fi

  # 逐条列出来，日志里能一眼看到"这次固件里到底带了哪 9 个规则、多大"
  mapfile -t _rs < <(find "$ruleset_dir" -maxdepth 1 -name '*.srs' -printf '%f %s\n' | sort)
  log "固件预置规则集 ${#_rs[@]} 个：${_rs[*]}"
  [[ "${#_rs[@]}" -gt 0 ]] || die "规则集目录是空的：$ruleset_dir"
fi

# ── 7. 注入 arm64 内核补丁：让 /proc/cpuinfo 带 model name ────
# 现象：首页「架构」那一格显示 "? x 4 (1651MHz)"。
#
# 根因链（三处代码全在上游，我们一行都没改）：
#   ① autocore 的 /sbin/cpuinfo 用
#        awk -F ': ' '/model name/ {print $2}' /proc/cpuinfo
#      取型号，取不到就写死 `?`；
#   ② arm64 内核 arch/arm64/kernel/cpuinfo.c 里那一行被 `if (compat)` 包着，
#      compat = "读它的进程是 32 位" ⇒ 64 位的 shell 永远读不到这一行；
#   ③ LuCI 的 10_system.js 写的是 `cpuinfo.cpuinfo || boardinfo.system`，
#      只有输出**为空**才回退 —— 脚本吐的是非空的 "?"，回退永不触发。
# 核数（x 4）和频率（1651MHz，读 cpufreq/policy0/cpuinfo_cur_freq）不受影响。
#
# 修法：把本仓库 patches/kernel/<ver>/ 下的补丁叠进内核源码树，去掉那个 `if`。
# 补丁是 NVIDIA 的 Sumit Gupta 2016 年发到 LKML 的版本，**没被主线接受**，
# 所以 openwrt/openwrt（以及它的 fork，也就是我们的主线源码树）都没有；
# ImmortalWrt 收编了它，放在同样的 generic/hack-<ver>/ 下 —— 这就是
# 「同一份 autocore、同一份 LuCI，ImmortalWrt 的机器显示正常、我们的显示 ?」
# 的全部原因：我们的固件是混血，UI 层借 ImmortalWrt，内核层来自 openwrt/openwrt。
#
# 落点与生效机制（都在上游源码里，已逐条核对）：
#   include/target.mk:159  GENERIC_HACK_DIR := target/linux/generic/hack-$(KERNEL_PATCHVER)
#   include/quilt.mk:104   $(call PatchDir,$(LINUX_DIR),$(GENERIC_HACK_DIR),generic-hack/)
#   rules.mk:365           KPATCH := $(SCRIPT_DIR)/patch-kernel.sh
# 即 Kernel/Patch/Default 按固定顺序应用：
#   backport-<ver> → pending-<ver> → hack-<ver> → <target>/patches-<ver>
# （hack 排在目标自己的 patches 之前；我们的补丁只碰 arch/arm64/kernel/cpuinfo.c，
# 与 qualcommax 那批 arm64-dts-* 补丁没有交集。）
# patch-kernel.sh 用 `patch -f -p1` 应用，失败会打 "Patch failed!" 并 exit 1，
# 所以补丁对不上会**中断构建**，不会静默编出一个没打补丁的内核。
#
# 编号 312 在当前 generic/hack-6.18 里是空的（3xx 段只占 300 / 301-01 / 301-02），
# 不会和上游撞号；万一上游以后收了同号补丁，下面的 cmp 会给 warning。
kver="$(sed -n 's/^KERNEL_PATCHVER:=[[:space:]]*//p' "$OPENWRT_DIR/target/linux/qualcommax/Makefile" | head -n1)"
[[ -n "$kver" ]] || die "没能从 target/linux/qualcommax/Makefile 读出 KERNEL_PATCHVER"
kernel_patch_src="$BUILDER_DIR/patches/kernel/$kver"
kernel_hack_dir="$OPENWRT_DIR/target/linux/generic/hack-$kver"
[[ -d "$kernel_patch_src" ]] \
  || die "本仓库没有为内核 $kver 准备补丁（$kernel_patch_src 不存在）" \
         "上游很可能把 KERNEL_PATCHVER 升到 $kver 了，需要按新内核的上下文补一份" \
         "（同一个补丁在 6.12 / 6.18 上的 hunk 不同：6.12 是 i + 两层缩进，6.18 是 cpu + 一层）"
[[ -d "$kernel_hack_dir" ]] || die "上游的内核补丁目录不存在：$kernel_hack_dir"
kernel_patches=0
for kp in "$kernel_patch_src"/*.patch; do
  [[ -f "$kp" ]] || continue
  kp_dst="$kernel_hack_dir/$(basename "$kp")"
  if [[ -e "$kp_dst" ]] && ! cmp -s "$kp" "$kp_dst"; then
    warn "内核补丁同名但内容不同，已覆盖：$(basename "$kp")（上游后来收了同号补丁？）"
  fi
  cp -f "$kp" "$kp_dst"
  log "注入内核补丁：generic/hack-$kver/$(basename "$kp")"
  kernel_patches=$((kernel_patches + 1))
done
# 算术展开返回 0 在 set -e 下算失败，但它是 || 的左侧，所以安全。
((kernel_patches)) || die "本仓库的补丁目录里没有 .patch 文件：$kernel_patch_src"

log "构建环境就绪：qualcommax/ipq807x → QNAP QHora-301W（qnap_301w）"
