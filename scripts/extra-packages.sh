#!/usr/bin/env bash
#
# 引入 OpenWrt 官方 feed 之外的包。现在分三类，处理方式按"上游有没有可指的
# 源码仓库 / 配方是不是我们自己的"来区分：
#
# ── ① ddns-go / msd_lite / autocore → 本仓库自带配方 ─────────────
# 配方在 packages/<分类>/<包>/ 下：
#   packages/net/ddns-go、packages/net/msd_lite
#     PKG_SOURCE 直接指向上游源码仓库（jeessy2/ddns-go、rozhuk-im/msd_lite），
#     版本与 hash 由 scripts/resolve-versions.sh 在构建时解析后注入。
#   packages/emortal/autocore
#     纯脚本包（无 PKG_SOURCE、Build/Compile 为空），抄自 ImmortalWrt 主源码树，
#     提供 /sbin/tempinfo、/sbin/cpuinfo —— ImmortalWrt 首页温度那一行背后的东西。
#     它不属于任何 feed，ImmortalWrt 主仓库又太大不值得整库拉，所以自带一份。
#
# 为什么不再从 ImmortalWrt 取这两个包：ImmortalWrt 的配方把版本**写死**了
# （例如 PKG_VERSION:=6.17.6 配对应 PKG_HASH），上游发了新版要等它 bump
# 才跟得上；而 OpenWrt 官方 packages feed 里干脆没有这两个包
# （实测 net/ddns-go 与 net/msd_lite 都是 404）。既然两边都不合适，
# 就自己写配方直接引用上游源码。
#
# ── ② ImmortalWrt 的 luci 前端 → 稀疏检出 immortalwrt/luci ──────
# 三类东西都在这个仓库里，都只有"抄上游"这一条路（没有独立的源码仓库可指，
# 自己抄一份到本仓库只会让上游更新跟不进来）：
#
#   applications/luci-app-ddns-go / -msd_lite（+ homeproxy 版还有 -homeproxy）
#     只是页面（JS / ucode / 翻译），靠 LUCI_DEPENDS:=+ddns-go / +msd_lite
#     接上面 ① 里那两个包，包名没变，照样接得上。
#
#   modules/luci-base + modules/luci-mod-status ← 首页「CPU 占用率 / 温度」的来源
#     官方 openwrt/luci 的首页（luci-mod-status 的 10_system.js）只有主机名、
#     型号、内核、时间、运行时长、负载均值，**没有** CPU 占用率和温度；
#     内存是标准 20_memory.js 给的。
#     ImmortalWrt 那两行不是"多一个包"，而是三处配套改动：
#       ① luci-base 的 rpcd ucode 插件（root/usr/share/rpcd/ucode/luci）
#          比上游多出 getTempInfo / getCPUInfo / getCPUUsage / getCPUBench，
#          分别 popen 执行 /sbin/tempinfo、/sbin/cpuinfo、`top -n1|awk …`、
#          读 /etc/bench.log。（上游那份的 luci.c 与 immortalwrt 逐字节相同，
#          这几个方法**不在** rpcd-mod-luci 里，只在 luci-base 的这个 ucode 里。）
#       ② luci-mod-status 的 10_system.js 把这些值画进「系统」块 ——
#          所以温度和 CPU 出现在页面**顶部**，内存仍由 20_memory.js 排第二块。
#       ③ 两包各自的 acl.d/*.json 补上授权（luci-mod-status.json 里加了
#          getCPUBench / getCPUUsage / getOnlineUsers）。
#     /sbin/tempinfo、/sbin/cpuinfo 由 ① 段的 autocore 提供，两边正好凑齐。
#     **必须成对替换**：只换 luci-mod-status 会调不到 ubus 方法（显示空），
#     只换 luci-base 则没人画那两行。
#     风险已核对：两个目录在两边的**文件清单与 Makefile 完全一致**
#     （luci-base 各 136 个文件、零增删），ucode 插件的 import 也只有
#     fs/uci/ubus 与 luci-base 自带的 luci.sys / luci.core / luci.version /
#     luci.zoneinfo —— 同包发布，不会缺模块。
#
# ── ③ passwall2（项目 + 依赖组件）→ 上游自己的仓库 ───────────────
# 注意仓库归属：passwall 项目已从个人账号 xiaorouji 迁到
# **Openwrt-Passwall** 组织（xiaorouji/... 现在返回 404）。三个仓库各司其职：
#   openwrt-passwall2          只含 luci-app-passwall2（界面 + 运行脚本）
#   openwrt-passwall-packages  17 个依赖组件的配方（xray-core / sing-box / …）
#   openwrt-passwall           只含 v1 的 luci-app-passwall，本仓库不用
#
# 为什么不自己写 passwall 的配方（像 ① 那样）：这些组件的配方和上游版本是
# **同步维护**的 —— 上游 bump 版本时 PKG_VERSION / PKG_HASH / 编译标签是一起改的，
# 分开抄反而容易对不上。而且它们没有"滞后"问题（不像 ImmortalWrt 抄 ddns-go
# 会慢半拍），所以这里只要每次构建都取最新的 main 就行。
# 组件清单**不写死**：上游加新组件会自动被带上（见下面的 find）。
#
# ⚠️ 有 4 个组件与官方 feed 同名：microsocks / sing-box / v2ray-geodata / xray-core。
#    落位时是**故意覆盖**官方那份 —— passwall 上游的 CI 也把 passwall feed 排在
#    feeds.conf 最前面，效果一样（同名时前者胜）。其余 13 个官方 feed 里没有，
#    实测 openwrt/packages 的 net/ 与 lang/ 下均为 404。
#
# ⚠️ shadowsocks-rust / shadow-tls 需要 **Rust 工具链**（它们的配方写着
#    PKG_BUILD_DEPENDS:=rust/host），要从源码编 rustc + LLVM，构建时间显著增长。
#    所以 configs/common.config 里把两个 INCLUDE_Shadowsocks_Rust_* 都关掉了；
#    要 ss-rust 就在 LuCI 的「组件更新」里在线下载（passwall2 自带这个入口，
#    见 root/usr/share/passwall2/app.sh 里的 ss-rust 分支）。
#    配方仍然落位，只是不选 —— 哪天想编，把那个开关改成 y 即可。
#
# ── 为什么必须放进 feed 目录，而不是 package/ ───────────────────
# 这些包的 Makefile 里是相对路径：
#   applications/luci-app-*/Makefile  →  include ../../luci.mk
#   net/ddns-go/Makefile              →  include ../../lang/golang/golang-package.mk
# 只有放在 <feed根>/<二级目录>/<包>/ 这个位置才能解析得到。
# 放进 package/ 会直接 `No rule to make target '../../luci.mk'`。
# （passwall 的配方用的是**绝对路径** $(TOPDIR)/feeds/... 或 $(INCLUDE_DIR)/…，
#   放哪都能解析，但仍然放进 feed 目录 —— 否则 feeds install 扫不到它。）
#
# ── 调用时机 ────────────────────────────────────────────────────
# 必须在 `feeds update` 之后（此时 feeds/ 目录树已就位）、`feeds install` 之前。
# 跑完本脚本后必须执行 `feeds update -i -a` 重建索引 —— install 读的是
# feeds/<name>.index，不重建就看不到新包。用 -i 而不是普通 update：-i 只重建索引、
# 不执行 git pull，不会碰到刚拷进去的文件。
#
# ── 环境变量 ────────────────────────────────────────────────────
#   OPENWRT_DIR     OpenWrt 源码目录（必需）
#   BUILDER_DIR     本仓库检出目录（必需）
#   PROXY_STACK     代理栈：passwall2（默认）| homeproxy | dae | daed
#   IMM_REF         ImmortalWrt 的分支，默认 master（luci 侧也用它）
#   IMM_LUCI        immortalwrt/luci 仓库地址
#   IMM_PKGS        immortalwrt/packages 仓库地址（homeproxy 版取 sing-box 用）
#   SINGBOX_PKGS_REF
#                   IMM_PKGS 用哪个 ref，默认 openwrt-25.12。**只有 fixed 通道看它**，
#                   而且它**故意不跟 IMM_REF 走**：IMM_REF 默认 master，而 master 在
#                   2026-10-15（提交 0d7620f1ab7d）把 net/sing-box 从 1.12.25 抬到了
#                   1.14.3 —— 1.12.25 在 master 上已经不存在。openwrt-25.12 是
#                   ImmortalWrt 的发布分支，仍带 1.12.25（openwrt-24.10 也是，可作备选）。
#                   想让它跟 IMM_REF 走（比如自己钉了个旧提交）就显式赋值。
#   SINGBOX_EXPECT  homeproxy 版期望的 sing-box 配方版本，默认 1.12.25。
#                   不符**直接中断构建**（不是警告）。想要 1.12.x 任意补丁版就写
#                   `SINGBOX_EXPECT=1.12.*`（支持通配）。只在 SINGBOX_MODE=fixed 下生效。
#   SINGBOX_MODE    homeproxy 版怎么处理「HomeProxy 生成的配置 ↔ sing-box 版本」
#                   这一对。四选一：
#                     fixed （默认）从 immortalwrt/packages 取 SINGBOX_EXPECT 那版
#                           （1.12.25）覆盖官方配方，HomeProxy 一字不动；
#                     latest 不覆盖官方配方，沿用现有那份 sing-box、把版本改成
#                           SINGBOX_VERSION，并给 HomeProxy 的
#                           generate_client.uc 打兼容补丁；
#                     builtin 两边都不动 —— 用基座自带的那一对。只对
#                           **immortalwrt 基座**成立：它的 HomeProxy 与 sing-box
#                           在同一个上游同步维护、已互相适配（实测依据见下面
#                           ③-H 的 builtin 分支）。
#                     source **从 reF1nd/sing-box 源码编译内核**，覆盖 feed 那份。
#                           配方由 packages/net/sing-box-refind/Makefile.in 渲染，
#                           commit 由 SINGBOX_SRC_REF 钉死（默认 testing 的 HEAD）。
#                           这是"不再套壳"的那条路：内核在本构建树里交叉编译，
#                           不下载任何预编译二进制。详见 ③-H-S 段。
#   SINGBOX_SRC_REF SINGBOX_MODE=source 时取哪个 ref（分支/tag/sha），默认 testing
#   SINGBOX_SRC_BASE 同上，包版本号里的上游基线（默认 1.14.0，只影响显示）
#   SINGBOX_VERSION SINGBOX_MODE=latest 时的目标版本（如 1.14.3）。留空则沿用
#                   官方配方自带版本，只打补丁、不换版本。
#   PW_REF          passwall 三个仓库的分支，默认 main
#   PW_APP_REPO     openwrt-passwall2 仓库地址
#   PW_PKGS_REPO    openwrt-passwall-packages 仓库地址
#
# ── PROXY_STACK=homeproxy 时有什么不同（默认 passwall2，行为完全不变）──
#   ② 段多稀疏检出一个目录：immortalwrt/luci 的 applications/luci-app-homeproxy。
#      HomeProxy 是**单包自包含**的（主程序 + init + rpcd 后端 + LuCI 视图
#      全在这一个包），所以引入它就只需要这一个目录，不像 passwall2 那样
#      要拉一个"界面仓库 + 组件仓库"。
#   ③ 段完全不跑（不引入 passwall 的两个仓库），sing-box 那边按
#      SINGBOX_MODE 分三种处理：
#       fixed  从 immortalwrt/packages@SINGBOX_PKGS_REF（默认 openwrt-25.12）取
#              net/sing-box 落位到 feeds/packages/net/，**覆盖官方那份**。
#              为什么：nss-edma 基座的 openwrt/packages 是 1.14.x，而**旧线**
#              （1.12.25 时代的 HomeProxy）要的是 ImmortalWrt 长期在用的 1.12.25。
#              该版本被 SINGBOX_EXPECT（默认 1.12.25）**硬断言**：不一致就中断构建。
#              2026-10-15 上游把 immortalwrt/packages 的 master 抬到 1.14.3，
#              线1/线2 就是在这里红掉的 —— 修法是**别跟着 master 走**、钉发布分支，
#              而不是放弃 1.12.25。
#              ⚠️ 基座是 immortalwrt 的线不要走这里（它自带的那对本来就是新版的），
#                 用 builtin。
#       latest 见下面 ③-H 的通道说明（改 HomeProxy、留新 sing-box）。
#       builtin 什么都不做：直接用基座自带的那一对。
#
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
BUILDER_DIR="${BUILDER_DIR:?BUILDER_DIR 未设置}"
PROXY_STACK="${PROXY_STACK:-passwall2}"
IMM_REF="${IMM_REF:-master}"
IMM_LUCI="${IMM_LUCI:-https://github.com/immortalwrt/luci.git}"
IMM_PKGS="${IMM_PKGS:-https://github.com/immortalwrt/packages.git}"
# homeproxy 版期望的 sing-box 配方版本。默认钉在 1.12.25 —— ImmortalWrt 自己
# 配 HomeProxy 用的就是它。支持通配（如 1.12.*）。
SINGBOX_EXPECT="${SINGBOX_EXPECT:-1.12.25}"
# 上面那版从 immortalwrt/packages 的**哪个 ref** 取，见文件头。默认发布分支
# openwrt-25.12，而不是 IMM_REF（master 上已经没有 1.12.25 了）。
SINGBOX_PKGS_REF="${SINGBOX_PKGS_REF:-openwrt-25.12}"
# homeproxy 版处理「配置 ↔ sing-box 版本」的通道，见文件头说明。默认 fixed =
# 与以前完全一致的行为；latest 改 HomeProxy、留新 sing-box；builtin 两边都不动
# （基座自带的那一对，只对 immortalwrt 基座成立）。
SINGBOX_MODE="${SINGBOX_MODE:-fixed}"
SINGBOX_VERSION="${SINGBOX_VERSION:-}"
SINGBOX_SRC_REF="${SINGBOX_SRC_REF:-testing}"
SINGBOX_SRC_BASE="${SINGBOX_SRC_BASE:-1.14.0}"
PW_REF="${PW_REF:-main}"
PW_APP_REPO="${PW_APP_REPO:-https://github.com/Openwrt-Passwall/openwrt-passwall2.git}"
PW_PKGS_REPO="${PW_PKGS_REPO:-https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git}"

case "$PROXY_STACK" in
  passwall2|homeproxy|singbox|dae|daed) ;;
  *) echo "不认识的 PROXY_STACK：$PROXY_STACK（只支持 passwall2 / homeproxy / singbox / dae / daed）" >&2; exit 1 ;;
esac

case "$SINGBOX_MODE" in
  fixed|latest|builtin|source) ;;
  *) echo "不认识的 SINGBOX_MODE：$SINGBOX_MODE（只支持 fixed / latest / builtin / source）" >&2; exit 1 ;;
esac
if [[ "$SINGBOX_MODE" != "fixed" && "$PROXY_STACK" != "homeproxy" && "$PROXY_STACK" != "singbox" ]]; then
  echo "SINGBOX_MODE=$SINGBOX_MODE 只对 PROXY_STACK=homeproxy / singbox 有意义（当前 $PROXY_STACK）" >&2
  exit 1
fi
# singbox 这条线**没有前端**，所以 fixed / builtin / latest 三条"配 HomeProxy"的
# 通道对它毫无意义 —— 只允许 source，否则会静默产出"装了内核但没人配它"的固件。
if [[ "$PROXY_STACK" == "singbox" && "$SINGBOX_MODE" != "source" ]]; then
  echo "PROXY_STACK=singbox 只用源码内核：SINGBOX_MODE 必须是 source（当前 $SINGBOX_MODE）" >&2
  exit 1
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# 注解走 fd3（原始终端）。prepare-build.sh 顶部把原始终端另存成了 fd3，
# 子进程会继承；单独运行时没有 fd3，退回 fd1。理由见 prepare-build.sh 的说明。
if { : >&3; } 2>/dev/null; then ANN_FD=3; else ANN_FD=1; fi
ann() { printf '%s\n' "$*" >&"$ANN_FD"; }

[[ -d "$OPENWRT_DIR" ]] || die "OPENWRT_DIR 不是有效目录：$OPENWRT_DIR"
[[ -d "$OPENWRT_DIR/feeds/packages" ]] || die "feeds/packages 不存在，请先跑 ./scripts/feeds update -a"
[[ -d "$OPENWRT_DIR/feeds/luci" ]]     || die "feeds/luci 不存在，请先跑 ./scripts/feeds update -a"

cd "$OPENWRT_DIR"

WORK="$(mktemp -d)"
# 清理失败不能拖垮整个构建步骤（例如 Windows/MSYS 下 rm 对 /tmp 路径的处理）。
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# 把 <克隆目录>/<源相对路径> 拷进 <feed目录>/<目标相对路径>。
# 源和目标**分开传**：不同仓库的目录层级不一样 ——
#   immortalwrt/luci            包在 applications/<包>/，喂进去正好也是这个层级
#   Openwrt-Passwall/openwrt-passwall2   包直接在根目录 <包>/
#   Openwrt-Passwall/openwrt-passwall-packages  同样是根目录 <包>/
# 目标目录同名时先删 —— 这是有意的（passwall 组件要覆盖官方 feed 的同名包）。
place() {
  local src_root="$1" feed_dir="$2" src_rel="$3" dst_rel="$4" label="$5"

  [[ -f "$src_root/$src_rel/Makefile" ]] \
    || die "上游没有 $src_rel/Makefile（结构可能变了），检查 $src_root"
  [[ -d "$feed_dir" ]] || die "目标 feed 目录不存在：$feed_dir"

  rm -rf "${feed_dir:?}/$dst_rel"
  mkdir -p "$feed_dir/$(dirname "$dst_rel")"
  cp -a "$src_root/$src_rel" "$feed_dir/$dst_rel"
  log "  落位（$label）$feed_dir/$dst_rel"
}

# ══════════════════════════════════════════════════════════════
# ① 本仓库自带的配方：packages/<分类>/<包>/ → feeds/packages/<分类>/<包>/
# ══════════════════════════════════════════════════════════════
OWN_ROOT="$BUILDER_DIR/packages"
[[ -d "$OWN_ROOT" ]] || die "本仓库里没有 packages/ 目录：$OWN_ROOT"

own_count=0
while IFS= read -r -d '' mk; do
  rel="${mk#"$OWN_ROOT"/}"
  rel="${rel%/Makefile}"
  [[ -n "$rel" ]] || die "解析自带配方相对路径失败：$mk"
  # 基座主树里已经有同路径的包 ⇒ 跳过落位。
  #
  # 实例：autocore 在 **ImmortalWrt 基座**里是主树自带的（`package/emortal/autocore`，
  # 本仓库的配方本来就是从那儿抄来的）。两份同名包同时存在没有意义 ——
  # feeds install 会打印
  #     WARNING: Not overriding core package 'autocore'; use -f to force
  # 并且**不用** feed 那份（主树优先），落位纯属白做，还会让
  # "引入的包有没有被 feeds install 接管" 那条断言误报。
  #
  # 老两条线的基座是 openwrt main，主树里没有 ddns-go / msd_lite / autocore
  # ⇒ 这个分支永远不进，行为与以前完全一致。
  if [[ -d "$OPENWRT_DIR/package/$rel" ]]; then
    log "  跳过（基座主树已自带，用主树那份）：$rel"
    continue
  fi
  place "$OWN_ROOT" feeds/packages "$rel" "$rel" "本仓库自带"
  own_count=$((own_count + 1))
done < <(find "$OWN_ROOT" -type f -name Makefile -print0 | sort -z)

((own_count > 0)) || die "$OWN_ROOT 下没找到任何 Makefile，自带配方不见了？"
log "自带配方落位完成，共 $own_count 个"

# ══════════════════════════════════════════════════════════════
# ② ImmortalWrt 的 luci 前端（只取 luci 那一半）
# ══════════════════════════════════════════════════════════════
LUCI_PATHS=(applications/luci-app-ddns-go applications/luci-app-msd_lite)

# 首页「CPU 占用率 / 温度」两行。**必须成对替换**，理由见文件头 ②：
#   只换 luci-mod-status → 调用 luci.getTempInfo 报 ACL/方法不存在，显示空；
#   只换 luci-base       → 有数据但没人画那两行。
# 与 PROXY_STACK 无关：autocore 两个 profile 都编、files/ 也共用，所以两边都换。
LUCI_PATHS+=(modules/luci-base modules/luci-mod-status)

# HomeProxy 也在这条路上：它同样没有独立的"上游源码仓库"可指，
# 整包（主程序 + init + rpcd 后端 + 视图 + po）都躺在 immortalwrt/luci 里。
if [[ "$PROXY_STACK" == "homeproxy" ]]; then
  LUCI_PATHS+=(applications/luci-app-homeproxy)
fi

# 稀疏检出：只下载指定目录的 blob，仓库其余部分不落地。
# immortalwrt/luci 很大，所以这里值得用稀疏；passwall 那两个仓库很小，
# 用后面的 clone_shallow 就够，不必把稀疏那套脆弱性引进来。
#
# ref 默认取 IMM_REF（luci 侧都是这样）。调用方可以用 `SPARSE_REF=xxx sparse_clone ...`
# 覆盖 —— fixed 通道要钉 immortalwrt/packages 的**发布分支**，不能跟着 master 走。
sparse_clone() {
  local repo="$1" dest="$2" ref="${SPARSE_REF:-$IMM_REF}"; shift 2

  log "稀疏检出 $(basename "$repo")@${ref}（只取：$*）"
  if git clone -q --depth=1 --filter=blob:none --sparse \
       --branch "$ref" "$repo" "$dest" 2>/dev/null; then
    git -C "$dest" sparse-checkout set "$@" >/dev/null 2>&1 \
      || warn "sparse-checkout set 失败，改用已有内容继续"
  else
    # 少数环境不支持 partial clone（--filter），退化为浅克隆整库。
    warn "稀疏检出失败，退化为浅克隆整库（会慢一些）"
    rm -rf "$dest"
    git clone -q --depth=1 --branch "$ref" "$repo" "$dest" \
      || die "克隆 $repo 失败（ref=$ref）"
    git -C "$dest" sparse-checkout set "$@" >/dev/null 2>&1 || true
  fi
}

sparse_clone "$IMM_LUCI" "$WORK/luci" "${LUCI_PATHS[@]}"
for rel in "${LUCI_PATHS[@]}"; do place "$WORK/luci" feeds/luci "$rel" "$rel" "ImmortalWrt 前端"; done

# 硬断言：首页那两行（CPU 占用率 / 温度）完全依赖 luci-base 的 rpcd ucode 插件，
# 上游哪天把方法挪走或改名，就**直接中断构建** —— 否则会悄悄编出一份首页
# 既没有温度也没有 CPU 的固件（这台设备刷完才发现，排查成本很高）。
HP_UCODE="feeds/luci/modules/luci-base/root/usr/share/rpcd/ucode/luci"
[[ -f "$HP_UCODE" ]] || die "luci-base 的 rpcd ucode 插件没落位：$HP_UCODE"
for m in getTempInfo getCPUInfo getCPUUsage; do
  grep -q "$m" "$HP_UCODE" \
    || die "luci-base ucode 里没有 $m（首页温度/CPU 就靠它）—— 检查 $IMM_LUCI@$IMM_REF 的 modules/luci-base"
done
HP_ACL="feeds/luci/modules/luci-mod-status/root/usr/share/rpcd/acl.d/luci-mod-status.json"
grep -q "getCPUUsage" "$HP_ACL" \
  || die "luci-mod-status 的 ACL 没授权 getCPUUsage，首页 CPU 占用率会是空的"
log "  首页温度/CPU 已就位：getTempInfo / getCPUInfo / getCPUUsage（luci-base + luci-mod-status）"

# ══════════════════════════════════════════════════════════════
# ③ 代理栈的核心组件
# ══════════════════════════════════════════════════════════════
# 取版本字段时不能只认 PKG_VERSION：少数组件把版本放在别的变量里
# （v2ray-geodata 用 GEOIP_VER，配方里根本没有 PKG_VERSION）。
# 取不到就如实显示 "-"，不编造。
pkg_ver_of() {
  local mk="$1" v=""
  v="$({ sed -n 's/^PKG_VERSION:=\s*//p'        "$mk" 2>/dev/null || true; } | head -n1)"
  [[ -n "$v" ]] || v="$({ sed -n 's/^PKG_SOURCE_DATE:=\s*//p'   "$mk" 2>/dev/null || true; } | head -n1)"
  [[ -n "$v" ]] || v="$({ sed -n 's/^[A-Z0-9_]*_VER:=\s*//p'    "$mk" 2>/dev/null || true; } | head -n1)"
  [[ -n "$v" ]] || v="-"
  printf '%s' "$v"
}

# 版本注解统一发：作业日志要登录才能看，注解不用。
# 这些版本**不是**我们注入的，而是上游仓库当前分支里的值 ——
# 所以这条注解同时是"上游最近一次更新有没有被这轮构建吃到"的凭证。

# 简单浅克隆就够：openwrt-passwall2 ~0.5MB、openwrt-passwall-packages ~3MB。
# 不用稀疏检出 —— 一是没必要，二是 sparse-checkout 在个别环境里会静默失败。
clone_shallow() {
  local repo="$1" dest="$2" label="$3"

  log "浅克隆 $label（$PW_REF）"
  rm -rf "$dest"
  git clone -q --depth=1 --branch "$PW_REF" "$repo" "$dest" 2>/dev/null \
    || die "克隆 $repo 失败（分支 $PW_REF）"
  [[ -d "$dest/.git" ]] || die "$repo 克隆后没有 .git，检出不完整"
}

# ══════════════════════════════════════════════════════════════
# sing-box 源码配方的渲染与落位（PROXY_STACK=homeproxy / singbox 共用）
# ══════════════════════════════════════════════════════════════
# 两条线用的是**同一份内核、同一份配方**，区别只在"有没有 HomeProxy 这层前端"：
#   homeproxy → 内核给 /etc/init.d/homeproxy 用（它自己生成 sing-box 配置）
#   singbox   → 内核自己跑（用包自带的 config.json + procd 脚本）
# 所以落位逻辑抽成函数；只有"顺手检查 HomeProxy 生成器"那一步是 homeproxy 独有
# （参数 1）。
#
# 结果写到两个全局变量里，与 fixed / builtin / latest 三条通道同名同义，
# 供后面的 ann 注解与调用方复用：
#   sb_ver / sb_desc
place_singbox_from_source() {
	local check_homeproxy="${1:-0}"
	local sb_tpl="$BUILDER_DIR/packages/net/sing-box-refind"
	local sb_render="$WORK/sing-box-refind"
	local gin

	# 模板故意叫 Makefile.in（不叫 Makefile）：① 段的
	# `find packages -name Makefile` 会把它当普通自带配方落位到
	# feeds/packages/net/sing-box-refind —— 那样会和 feed 里的 net/sing-box
	# 变成两个同名包，feeds install 直接冲突。
	[[ -f "$sb_tpl/Makefile.in" ]] \
		|| die "找不到源码配方模板：$sb_tpl/Makefile.in"

	OPENWRT_DIR="$OPENWRT_DIR" \
		SINGBOX_SRC_REF="$SINGBOX_SRC_REF" \
		SINGBOX_SRC_BASE="$SINGBOX_SRC_BASE" \
		GH_TOKEN="${GH_TOKEN:-}" \
		bash "$BUILDER_DIR/scripts/resolve-singbox-src.sh" "$sb_tpl" "$sb_render" \
		|| die "渲染 sing-box 源码配方失败（详见上面的输出）"

	# shellcheck disable=SC1090
	. "$sb_render/resolve.env"

	# 覆盖 feed 里那份（同名同目录 —— feeds install 之后包名就是 sing-box）。
	rm -rf feeds/packages/net/sing-box
	mkdir -p feeds/packages/net/sing-box
	cp -a "$sb_render"/. feeds/packages/net/sing-box/
	# resolve.env 只是给本脚本传值用的中间文件，不该进构建树。
	rm -f feeds/packages/net/sing-box/resolve.env
	log "  落位 feeds/packages/net/sing-box（源码配方，PKG_VERSION=${SINGBOX_SRC_VER}）"

	# 硬断言：渲染结果必须指向 reF1nd。模板哪天被改回 SagerNet，这条会拦住 ——
	# 否则"源码编译版"会静默变成"官方版"，只有版本号不对劲。
	grep -q 'codeload\.github\.com/reF1nd/sing-box' feeds/packages/net/sing-box/Makefile \
		|| die "渲染出的配方没有指向 reF1nd/sing-box（模板被改坏了？）"

	# 硬断言：⚠️ 别把 with_naive_outbound 加回来。它拉进的 cronet-go 静态库是
	# glibc 的（文件头 `//go:build linux && !android && arm64 && !with_musl ...`），
	# 而当前 go.mod 钉的 cronet-go 里没有 musl_arm64 → musl 目标上必然失败：
	#   CGO_ENABLED=0 → build constraints exclude all Go files
	#   CGO_ENABLED=1 → 链接期一堆 glibc 专有符号未定义
	# 2026-10-25 那两轮整机编译就是死在这上面（报错被 subdir.mk 吞进
	# logs/package/.../compile.txt，控制台只剩一句 failed to build）。
	# 只比对 GO_PKG_TAGS 这一行的**实际取值**，不 grep 全文 ——
	# 模板注释里反复用 with_naive_outbound 解释「为什么不要它」，
	# 全文 grep 会把这些注释当成违规（2026-10-25 三条线全挂在这上面）。
	sb_tags="$(sed -n 's/^GO_PKG_TAGS[[:space:]]*:=[[:space:]]*//p' \
		feeds/packages/net/sing-box/Makefile | tr -d '\\' | tr ',' '\n')"
	[[ -n "$sb_tags" ]] \
		|| die "读不到 feeds/packages/net/sing-box/Makefile 里的 GO_PKG_TAGS（模板结构变了？）"
	if printf '%s\n' "$sb_tags" | grep -qx '[[:space:]]*with_naive_outbound[[:space:]]*'; then
		die "配方里的 GO_PKG_TAGS 含 with_naive_outbound —— musl 目标编不出来。
      cronet-go 的 libcronet.a 是 glibc 静态库，且该版本没有 musl_arm64 目录。
      详见 packages/net/sing-box-refind/Makefile.in 里 GO_PKG_TAGS 上方的注释。"
	fi
	# 顺手把实际标签数报出来：标签被误删（比如漏了 with_quic）时能早点发现。
	log "  GO_PKG_TAGS（$(printf '%s\n' "$sb_tags" | grep -c .) 个）：$(printf '%s' "$sb_tags" | tr '\n' ',' | sed 's/,$//')"

	# HomeProxy 的生成器必须已是 1.13+ 写法。reF1nd/testing 是 1.14.x-dev，
	# legacy inbound 字段（sniff / sniff_override_destination = true）会直接 FATAL。
	if [[ "$check_homeproxy" == "1" ]]; then
		gin="feeds/luci/applications/luci-app-homeproxy/root/etc/homeproxy/scripts/generate_client.uc"
		[[ -f "$gin" ]] || die "找不到 HomeProxy 的 generate_client.uc：$gin"
		if grep -qE '^[ \t]*(sniff|sniff_override_destination)[ \t]*:[ \t]*true' "$gin"; then
			die "HomeProxy 的 generate_client.uc 里仍有 legacy inbound 字段（sniff / sniff_override_destination = true）
      sing-box ${SINGBOX_SRC_VER}（≥1.13）会在 /etc/init.d/homeproxy 的 check 阶段 FATAL。
      出路：改用新版 immortalwrt/luci 的 HomeProxy（IMM_REF=master），
            或先跑 scripts/patch-homeproxy-for-singbox113.py 把它迁到 route.rules 写法。"
		fi
	fi

	sb_ver="$SINGBOX_SRC_VER"
	sb_desc="reF1nd/sing-box@${SINGBOX_SRC_REF}（源码编译，commit ${SINGBOX_SRC_SHA7}）"
}

if [[ "$PROXY_STACK" == "dae" ]]; then
  # ════════════════════════════════════════════════════════════
  # ③-D 代理栈 = dae：**一个仓库都不用拉**
  # ════════════════════════════════════════════════════════════
  # dae / dae-geoip / dae-geosite 在 immortalwrt/packages（feeds/packages/net/dae），
  # luci-app-dae 在 immortalwrt/luci（feeds/luci/applications/luci-app-dae）——
  # 都是本线基座**自带的官方 feed**，`feeds install -a` 之后就在 package/feeds/ 下，
  # 不需要像 homeproxy / passwall2 那样从别的仓库落位。
  #
  # 与 passwall2 线的区别只在于"不引入"：openwrt-passwall2 与
  # openwrt-passwall-packages 那两个仓库是 passwall2 的依赖来源，dae 用不上，
  # 故本分支不调用 clone_shallow / place。
  #
  # ⚠️ 本分支之所以必须是**独立分支**而不是落进 else（passwall2 那条）：
  #    else 会无条件克隆并落位 passwall 的 18 个组件配方，把它们摆进
  #    feeds/packages/net/ —— 虽然 dae.config 里这些符号都置了 =n、不会被编进固件，
  #    但那是"多做一遍无用功 + 让 feeds 索引里混进一堆无关包"，
  #    而且一旦哪天有人手滑把它们选中，就会和 dae 抢同一份流量。
  log "代理栈 = dae：全部来自基座官方 feed，不引入任何第三方仓库"
  ann "::notice title=dae 来源::immortalwrt/packages@${IMM_REF} + immortalwrt/luci@${IMM_REF}（官方 feed，无需外部落位）"
elif [[ "$PROXY_STACK" == "daed" ]]; then
  # ════════════════════════════════════════════════════════════
  # ③-D2 代理栈 = daed：同样**一个仓库都不用拉**
  # ════════════════════════════════════════════════════════════
  # daed / daed-geoip / daed-geosite 在 immortalwrt/packages
  # （feeds/packages/net/daed），luci-app-daed 在 immortalwrt/luci ——
  # 与 dae 线一样全部来自基座官方 feed。
  #
  # 与 dae 线的差别只在"编什么"：dae 是单二进制 + 配置文件；daed 是
  # dae-wing（Go 服务）+ 内嵌 Web 面板 + SQLite（/etc/daed/wing.db），
  # 编译时还要从 daeuniverse/daed 的 release 拉一份 web.zip 打进二进制
  # （配方里的 Download/daed-web 段），所以构建时间比 dae 更长一点。
  #
  # 内核前提完全相同（BTF / cls_bpf / act_bpf / XDP），不需要任何额外落位；
  # 两个内核不能同时装（抢 clsact qdisc 上的 eBPF 程序），configs/daed.config
  # 里已把 dae 那组符号显式置 n。
  log "代理栈 = daed：全部来自基座官方 feed，不引入任何第三方仓库"
  ann "::notice title=daed 来源::immortalwrt/packages@${IMM_REF} + immortalwrt/luci@${IMM_REF}（官方 feed，无需外部落位）"
elif [[ "$PROXY_STACK" == "singbox" ]]; then
  # ════════════════════════════════════════════════════════════
  # ③-S 代理栈 = singbox（纯净内核线）
  # ════════════════════════════════════════════════════════════
  # **一个前端都不装**：
  #   · 不拉 immortalwrt/luci 的 luci-app-homeproxy（② 段只在 homeproxy 分支加）；
  #   · 不拉 passwall 的两个仓库；
  #   · 只把 reF1nd/sing-box 源码编成的内核 + 它自带的 init/config 落进固件。
  # 分流、订阅、节点全部靠手改 /etc/sing-box/config.json。
  #
  # 为什么要这条线：HomeProxy 那套是「ucode 生成配置 → 写 nft 规则 → 拉起 sing-box」，
  # 环节多、出错面大（math 模块缺失、legacy 字段、规则集下载失败都踩过）。
  # 纯净线把这些全省掉，只留一个进程和一份 JSON —— 适合"规则自己维护、
  # 就想让内核按我说的跑"的场景。代价见 configs/singbox.config 头部。
  log "代理栈 = singbox：只要内核，不要前端（reF1nd/sing-box@${SINGBOX_SRC_REF} 源码编译）"
  place_singbox_from_source 0
  ann "::notice title=内核来源::reF1nd/sing-box 源码编译（${sb_desc}），无 LuCI 前端"
elif [[ "$PROXY_STACK" == "homeproxy" ]]; then
  # ════════════════════════════════════════════════════════════
  # ③-H 代理栈 = homeproxy：只要一个 sing-box 组件
  # ════════════════════════════════════════════════════════════
  # 不拉 passwall 那两个仓库 —— HomeProxy 不需要它们（分流、DNS、协议实现
  # 全部由它自己生成的 sing-box 配置完成）。
  #
  # 【背景】这件事有两个互不相干的时代，别混起来看：
  #
  #   旧时代（1.12.25）：immortalwrt/luci 的 HomeProxy 生成器还在写 sing-box
  #     1.13.0 已删除的 inbound 字段（sniff / sniff_override_destination），
  #     而它配套的 sing-box 是 immortalwrt/packages 里的 1.12.25。openwrt/packages
  #     已经是 1.14.x，直接混编会在运行期 FATAL：
  #         legacy inbound fields are deprecated in 1.11.0 and removed in 1.13.0
  #     /etc/init.d/homeproxy 据此 return 1，服务永远起不来
  #     （编得出、刷得进、跑不起来；在 192.168.2.1 上实测确认过）。
  #     所以旧线的做法是**把 sing-box 钉回 1.12.25**（通道 fixed）。
  #
  #   新时代（2026-10-15 起）：immortalwrt/luci 的生成器**自己迁移到新版写法**了
  #     （route.rules 里直接是 { action: 'sniff' }；legacy inbound 字段已删干净），
  #     immortalwrt/packages 也随之把 sing-box 抬到 1.14.3。两边由同一个上游
  #     同步维护、已互相适配 —— 这时什么都不用做（通道 builtin）。
  #
  # 四条通道（由 SINGBOX_MODE 选，下面四个分支一一对应）：
  #   ① fixed   钉 1.12.25：从 immortalwrt/packages@SINGBOX_PKGS_REF
  #             （默认发布分支 openwrt-25.12）取那份配方覆盖掉基座的。
  #             只有「基座是 openwrt / nss-edma 且要旧组合」的线才用它。
  #   ② builtin 两边都不动，用基座自带的那一对（基座是 immortalwrt 的线走这条）。
  #   ③ latest  给 HomeProxy 的生成器打 1.13+ 兼容补丁、留新 sing-box。
  #             **已过时**：上游的生成器迁移之后，补丁脚本的正则匹配不上新结构，
  #             这条通道现在必然报错。留着是给"万一上游回退"留个出口，别用它。
  #             想跟新 sing-box 就走 builtin。
  #   ④ source  从 reF1nd/sing-box **源码编译**内核（本仓库新增，见 ③-H-S）。
  #             要"最新内核 + 不套壳"就走这条；基座必须是 immortalwrt
  #             （HomeProxy 生成器得是新版写法）。

  if [[ "$SINGBOX_MODE" == "source" ]]; then
    # ── 通道 D：内核从 reF1nd/sing-box 源码编（实现见 place_singbox_from_source）──
    # 这是"不再套壳"那条路：不再下载 reF1nd 预编译的 tar.gz，也不再受
    # "壳与核被两个补丁字段绑死"的限制 —— 内核在本构建树里用 golang-package.mk
    # 交叉编译，GOARCH/GOARM64/ABI/musl 全跟基座一致，版本由 commit 钉死。
    log "代理栈 = homeproxy：sing-box 改由源码编译（reF1nd/sing-box@${SINGBOX_SRC_REF}）"
    place_singbox_from_source 1
  elif [[ "$SINGBOX_MODE" == "builtin" ]]; then
    # ── 通道 C：基座自带的那一对，两边都不动 ────────────────────────────
    # 适用：基座 = immortalwrt。它的 feeds/luci 的 luci-app-homeproxy 与
    # feeds/packages 的 sing-box 由同一个上游同步维护、**已经互相适配**，
    # 既不需要我们固定 sing-box 版本，也不需要给 HomeProxy 打补丁。
    #
    # 实测依据（2026-10-15，immortalwrt master da63f7d6）：
    #   · generate_client.uc 的 route.rules 已是新版写法
    #         { inbound: 'dns-in', action: 'hijack-dns' },
    #         { action: 'sniff' }
    #     而 1.13 明确删除的 inbound 字段 sniff / sniff_override_destination
    #     上游**已经删干净** —— 也就是 scripts/patch-homeproxy-for-singbox113.py
    #     本来要修的东西上游自己修好了。那个脚本的正则因此匹配不上当前结构
    #     （会报 "没找到 config.route 的默认 rules 块"），所以这条线**不能**
    #     走 latest。
    #   · 唯一残留的 set_system_proxy: false 是**合法字段**，不是 legacy：
    #     sing-box 1.14.3 源码 option/simple.go:18 里
    #         type HTTPMixedInboundOptions struct {
    #             Users          []auth.User           `json:"users,omitempty"`
    #             DomainResolver *DomainResolveOptions `json:"domain_resolver,omitempty"`
    #             SetSystemProxy bool                  `json:"set_system_proxy,omitempty"`
    #         }
    #     真正触发 FATAL 的是 option/inbound.go:72-74 的
    #     SniffEnabled / SniffOverrideDestination / SniffTimeout。
    #   · 所以基座自带的组合可以直接用，sing-box 停在 1.14.3，不降级到 1.12.25。
    #
    # fixed 通道之所以对 immortalwrt 基座不再适用：它断言 immortalwrt/packages
    # 里仍是 1.12.25，而那边现在已经是 1.14.3。
    [[ -f feeds/packages/net/sing-box/Makefile ]] \
      || die "feeds/packages/net/sing-box 不存在，feeds update 没跑全？"
    gin="feeds/luci/applications/luci-app-homeproxy/root/etc/homeproxy/scripts/generate_client.uc"
    [[ -f "$gin" ]] \
      || die "找不到 HomeProxy 的 generate_client.uc：$gin（基座的 feeds/luci 里没有 luci-app-homeproxy？）"

    sb_ver="$(pkg_ver_of feeds/packages/net/sing-box/Makefile)"
    log "代理栈 = homeproxy：SINGBOX_MODE=builtin，沿用基座自带的 HomeProxy + sing-box ${sb_ver}（不改版本、不打补丁）"

    # 保险丝：万一上游哪天把 legacy inbound 字段写回来，这里必须有人喊。
    # （注意只认 `字段: true` —— 残留的 `set_system_proxy: false` 是**合法**的
    #   HTTPMixedInboundOptions 字段，不是 legacy，别把 line 误杀。）
    if grep -qE '^[ \t]*(sniff|sniff_override_destination)[ \t]*:[ \t]*true' "$gin"; then
      die "基座的 generate_client.uc 里又出现了 legacy inbound 字段 sniff / sniff_override_destination（上游回退了？）
      sing-box ${sb_ver} 会在 /etc/init.d/homeproxy 的 sing-box check 阶段 FATAL。
      出路：改用 SINGBOX_MODE=latest（给 HomeProxy 打 1.13+ 兼容补丁），
            或把 sing-box 钉回 1.12.25（SINGBOX_MODE=fixed + SINGBOX_PKGS_REF）。"
    fi
    sb_desc="基座自带（$IMM_PKGS@$IMM_REF，HomeProxy 与 sing-box 由上游同步维护）"
  elif [[ "$SINGBOX_MODE" == "latest" ]]; then
    # ── 通道 B（实验）：留 1.14.x，改 HomeProxy ─────────────────────────
    # 不覆盖官方配方，直接用 openwrt/packages 的 net/sing-box，把版本改成
    # SINGBOX_VERSION 并重算 PKG_HASH（配方取的是 codeload 的
    # .../tar.gz/v<版本>，哈希只能现下现算），再给 HomeProxy 的
    # generate_client.uc 打 sing-box 1.13+ 兼容补丁。
    # 补丁已用 sing-box 官方二进制 `check` 验证：1.14.3 通过、1.12.25 也通过。
    [[ -f feeds/packages/net/sing-box/Makefile ]] \
      || die "feeds/packages/net/sing-box 不存在，feeds update 没跑全？"

    if [[ -n "$SINGBOX_VERSION" ]]; then
      log "代理栈 = homeproxy：把官方 sing-box 配方改到 $SINGBOX_VERSION"
      sb_mk="feeds/packages/net/sing-box/Makefile"
      sb_hash="$(curl -fsSL --retry 3 --max-time 300 \
        "https://codeload.github.com/SagerNet/sing-box/tar.gz/v${SINGBOX_VERSION}" \
        | sha256sum | awk '{print $1}')"
      [[ "$sb_hash" =~ ^[0-9a-f]{64}$ ]] \
        || die "算 $SINGBOX_VERSION 源码包的 sha256 失败（拿到 '$sb_hash'），检查版本号或网络"
      sed -i "s|^PKG_VERSION:=.*|PKG_VERSION:=${SINGBOX_VERSION}|" "$sb_mk"
      sed -i "s|^PKG_HASH:=.*|PKG_HASH:=${sb_hash}|" "$sb_mk"
      grep -q "^PKG_VERSION:=${SINGBOX_VERSION}$" "$sb_mk" || die "改 PKG_VERSION 没生效：$sb_mk"
      grep -q "^PKG_HASH:=${sb_hash}$" "$sb_mk"           || die "改 PKG_HASH 没生效：$sb_mk"
      log "  PKG_VERSION=${SINGBOX_VERSION}  PKG_HASH=${sb_hash}"
    else
      log "代理栈 = homeproxy：沿用官方 sing-box 配方自带版本（未指定 SINGBOX_VERSION）"
    fi

    gin="feeds/luci/applications/luci-app-homeproxy/root/etc/homeproxy/scripts/generate_client.uc"
    [[ -f "$gin" ]] || die "找不到 HomeProxy 的 generate_client.uc：$gin"
    command -v python3 >/dev/null 2>&1 \
      || die "打 HomeProxy 兼容补丁需要 python3，但当前环境没有"
    python3 "$BUILDER_DIR/scripts/patch-homeproxy-for-singbox113.py" "$gin" \
      || die "HomeProxy 的 sing-box 1.13+ 兼容补丁没打上（详见上面的输出）"

    sb_ver="$(pkg_ver_of feeds/packages/net/sing-box/Makefile)"
    sb_desc="openwrt/packages 配方（已改为 ${SINGBOX_VERSION:-配方自带版本}）+ HomeProxy 1.13+ 兼容补丁"
  else
    # ── 通道 A（默认）：钉 1.12.25，HomeProxy 一字不动 ─────────────────
    # ImmortalWrt 自己就是 sing-box 1.12.25 + homeproxy，上游验证过的组合。
    # 关键：**不跟着 IMM_REF 走**，而是钉 SINGBOX_PKGS_REF（默认发布分支
    # openwrt-25.12）—— 2026-10-15 上游把 immortalwrt/packages 的 master 从
    # 1.12.25 抬到了 1.14.3，跟着 master 走这条通道就永远不成立。
    log "代理栈 = homeproxy：取 ImmortalWrt 的 sing-box 配方（覆盖官方那份）"
    log "  ref = $SINGBOX_PKGS_REF（IMM_PKGS=$IMM_PKGS）"
    SPARSE_REF="$SINGBOX_PKGS_REF" \
      sparse_clone "$IMM_PKGS" "$WORK/imm-packages" net/sing-box
    place "$WORK/imm-packages" feeds/packages/net net/sing-box sing-box \
      "ImmortalWrt sing-box（homeproxy 用）"

    [[ -f feeds/packages/net/sing-box/Makefile ]] \
      || die "immortalwrt/packages 的 net/sing-box 没落位，检查 $IMM_PKGS 的 $SINGBOX_PKGS_REF"

    sb_ver="$(pkg_ver_of feeds/packages/net/sing-box/Makefile)"
    # sing-box 1.13 起删掉了旧版 HomeProxy 仍在写的 inbound 字段
    # （sniff / sniff_override_destination），1.14 上 `sing-box check` 直接
    # FATAL、/etc/init.d/homeproxy 据此 return 1，服务永远起不来 ——
    # 而且是**运行期才暴露**（编得出来、刷得进去、跑不起来）。
    #
    # 所以这里不留余地：配方版本必须等于 SINGBOX_EXPECT（默认 1.12.25），
    # 否则中断构建。SINGBOX_PKGS_REF 指的 ref 哪天也把 1.12.25 抬走，
    # 构建会在这里明确失败，而不是悄悄产出一份 homeproxy 起不来的固件。
    # 注意 RHS 不加引号：SINGBOX_EXPECT 支持 1.12.* 这类通配。
    [[ "$sb_ver" == ${SINGBOX_EXPECT} ]] || die "sing-box 配方版本不符：实际 '$sb_ver'，期望 '$SINGBOX_EXPECT'
      （配方取自 $IMM_PKGS@$SINGBOX_PKGS_REF）
      这条通道要的是 1.12.25 那版 sing-box（旧线 HomeProxy 与它配套）。
      出路：① 换一个仍带该版本的 ref —— 设 SINGBOX_PKGS_REF=openwrt-24.10
              （或打开本仓库 README 第五章，那里列了所有仍带 1.12.25 的 ref）；
            ② 真要跟着新 sing-box 走，就改用 SINGBOX_MODE=builtin（基座自带）
               或 =latest（给 HomeProxy 打兼容补丁）—— 这两条通道不要 1.12.25。"
    sb_desc="$IMM_PKGS@$SINGBOX_PKGS_REF（已断言 == ${SINGBOX_EXPECT}）"
  fi

  luci_sha="$(git -C "$WORK/luci" rev-parse --short HEAD 2>/dev/null || echo '?')"
  ann "::notice title=HomeProxy 版本::luci-app-homeproxy（取自 immortalwrt/luci@$IMM_REF，commit ${luci_sha}）"
  ann "::notice title=sing-box 版本::sing-box=${sb_ver}（取自 ${sb_desc}）"
else
  # ════════════════════════════════════════════════════════════
  # ③-P 代理栈 = passwall2（默认）
  # ════════════════════════════════════════════════════════════
  # ③-a 界面：openwrt-passwall2 的 <根>/luci-app-passwall2 → feeds/luci/applications/
  #     注意源在仓库根目录、目标要落到 applications/ 下，两边层级不同。
  clone_shallow "$PW_APP_REPO" "$WORK/passwall2" "openwrt-passwall2"
  place "$WORK/passwall2" feeds/luci luci-app-passwall2 applications/luci-app-passwall2 "passwall2"

  # ③-b 依赖组件：openwrt-passwall-packages 顶层每个含 Makefile 的目录都是一个包。
  # 清单**不写死** —— 上游加新组件时这里自动跟上，也不用改这个脚本。
  clone_shallow "$PW_PKGS_REPO" "$WORK/passwall-packages" "openwrt-passwall-packages"

  pw_rels=()
  while IFS= read -r dir; do
    rel="$(basename "$dir")"
    [[ "$rel" == .* ]] && continue          # 跳过 .github / .gitattributes 之类
    [[ -f "$dir/Makefile" ]] || continue    # 只认带配方的目录
    place "$WORK/passwall-packages" feeds/packages/net "$rel" "$rel" "passwall 组件"
    pw_rels+=("$rel")
  done < <(find "$WORK/passwall-packages" -mindepth 1 -maxdepth 1 -type d -print | sort)

  ((${#pw_rels[@]} > 0)) || die "openwrt-passwall-packages 里一个包都没找到，上游结构变了？"
  # 两个核心组件必须在 —— 缺了说明这份检出不对，早点失败比编到一半炸好。
  for must in xray-core sing-box chinadns-ng; do
    [[ -f "feeds/packages/net/$must/Makefile" ]] \
      || die "passwall 组件 $must 没落位，检查 $PW_PKGS_REPO 的 $PW_REF 分支"
  done
  log "passwall 组件落位完成，共 ${#pw_rels[@]} 个：${pw_rels[*]}"

  # 不是所有组件都会被编进固件（只有 luci-app-passwall2 选中/依赖的那些），
  # 这里列的是"本仓库引入的配方版本"。
  app_ver="$(pkg_ver_of feeds/luci/applications/luci-app-passwall2/Makefile)"
  app_rel="$(sed -n 's/^PKG_RELEASE:=\s*//p' feeds/luci/applications/luci-app-passwall2/Makefile 2>/dev/null | head -n1)"
  ann "::notice title=passwall2 项目版本::luci-app-passwall2=${app_ver:-未知}${app_rel:+-${app_rel}}（取自 $PW_APP_REPO@$PW_REF）"

  pw_summary=""
  for rel in "${pw_rels[@]}"; do
    pw_summary="${pw_summary}${rel}=$(pkg_ver_of "feeds/packages/net/$rel/Makefile")  "
  done
  ann "::notice title=passwall 组件版本（引自上游 $PW_REF）::${pw_summary}"
fi

# ══════════════════════════════════════════════════════════════
# 前置依赖自检
# ══════════════════════════════════════════════════════════════
# ddns-go 是 Go 包，构建时要 include 官方 feed 的 golang 框架。
# 它不在就说明 packages feed 不完整，早点失败比编到一半炸好。
# （sing-box 同样是 Go 包，两个 profile 都要用到这个框架。）
[[ -f feeds/packages/lang/golang/golang-package.mk ]] \
  || die "缺少 feeds/packages/lang/golang/golang-package.mk，ddns-go / sing-box 等 Go 包无法构建"
[[ -f feeds/luci/luci.mk ]] \
  || die "缺少 feeds/luci/luci.mk，luci-app-* 无法构建"

log "引入完成（PROXY_STACK=${PROXY_STACK}）："
log "  · 自带配方        ddns-go / msd_lite / autocore"
if [[ "$PROXY_STACK" == "homeproxy" ]]; then
  log "  · ImmortalWrt 前端 luci-app-{ddns-go,msd_lite,homeproxy}"
  case "$SINGBOX_MODE" in
    source)  log "  · 代理核心        sing-box（reF1nd/sing-box 源码编译，覆盖官方那份）" ;;
    builtin) log "  · 代理核心        sing-box（基座自带，未覆盖）" ;;
    *)       log "  · 代理核心        sing-box（ImmortalWrt 配方，覆盖官方那份）" ;;
  esac
elif [[ "$PROXY_STACK" == "dae" ]]; then
  log "  · ImmortalWrt 前端 luci-app-{ddns-go,msd_lite}"
  log "  · 代理核心        dae（基座官方 feed，未引入任何第三方仓库）"
elif [[ "$PROXY_STACK" == "daed" ]]; then
  log "  · ImmortalWrt 前端 luci-app-{ddns-go,msd_lite}"
  log "  · 代理核心        daed（dae-wing + 内嵌面板，基座官方 feed，未引入第三方仓库）"
elif [[ "$PROXY_STACK" == "singbox" ]]; then
  log "  · ImmortalWrt 前端 luci-app-{ddns-go,msd_lite}（没有代理前端）"
  log "  · 代理核心        sing-box（reF1nd 源码编译，自带 init + config.json）"
else
  log "  · ImmortalWrt 前端 luci-app-{ddns-go,msd_lite}"
  log "  · passwall2       luci-app-passwall2 + ${#pw_rels[@]} 个依赖组件"
fi
warn "别忘了接着跑：./scripts/feeds update -i -a   # 重建索引，install 才看得到这些包"
