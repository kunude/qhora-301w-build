#!/usr/bin/env bash
#
# 为 QNAP QHora-301W 准备 OpenWrt 构建环境。
#
#   1. 追加 NSS feed，更新 feed；从 ImmortalWrt 引入官方 feed 没有的包；安装全部 feed
#   2. 把 configs/common.config + configs/qhora_301w.config 拼成 .config，跑 make defconfig
#   3. 校验 defconfig 没有静默丢弃符号（Kconfig 在依赖不满足时会无声地去掉选项）
#   4. 关闭 NSS feed 的整体打包（feeds.conf 里声明了，但我们只要 .config 里显式选的包）
#   5. 叠加 files/ 覆盖文件
#
# 必需的环境变量：
#   OPENWRT_DIR   已检出的 OpenWrt 源码目录（必须是 git 工作区）
#   BUILDER_DIR   本仓库的检出目录
# 可选：
#   NSS_FEED      NSS feed 的 src-git 行，默认指向 edma-nss 分支
#
set -Eeuo pipefail

# ── CI 可诊断性 ──────────────────────────────────────────────
# 这个脚本跑在 GitHub Actions 上，而 job 日志要仓库 admin 权限才能下载，
# 失败时远程完全看不到原因。所以：
#   · 全部输出同时落盘到 $LOG_FILE（供回放）
#   · 失败时把「出错行号 + 出错命令 + 日志尾部」输出成 ::error::，
#     那会变成 check-run annotation —— 公开可读，远程就能定位。
LOG_FILE="${LOG_FILE:-${GITHUB_WORKSPACE:-${RUNNER_TEMP:-/tmp}}/prepare-build.log}"
: >"$LOG_FILE" 2>/dev/null || LOG_FILE=/tmp/prepare-build.log
exec 3>&1 4>&2            # 保留原始 stdout/stderr，失败时切回来发注解
exec >>"$LOG_FILE" 2>&1   # 之后的输出全部进日志

_dump_log_tail() {
  local n="${1:-25}"
  tail -n "$n" "$LOG_FILE" 2>/dev/null | while IFS= read -r l; do
    printf '::error::[log] %s\n' "$l"
  done
}

_on_error() {
  local rc=$? line="$1" cmd="$2"
  exec 1>&3 2>&4
  printf '::error::prepare-build.sh 在第 %s 行失败（退出码 %s）\n' "$line" "$rc"
  printf '::error::失败命令：%s\n' "$cmd"
  _dump_log_tail 25
  exit "$rc"
}
trap '_on_error "$LINENO" "$BASH_COMMAND"' ERR

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
BUILDER_DIR="${BUILDER_DIR:?BUILDER_DIR 未设置}"
NSS_FEED="${NSS_FEED:-src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;edma-nss}"

# log/warn 同时进日志和 CI 控制台，这样远程也能看到进度。
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&3; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&3; }
die()  {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exec 1>&3 2>&4
  printf '::error::%s\n' "$*"
  _dump_log_tail 30
  exit 1
}

CONFIGS=(
  "$BUILDER_DIR/configs/common.config"
  "$BUILDER_DIR/configs/qhora_301w.config"
)

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

# 官方 feed 里没有 ddns-go / msd_lite，从 ImmortalWrt feed 抠出来放进 feed 目录树。
# 必须在 install 之前、update 之后：update 负责把 feeds/ 目录建出来，
# install 读的是索引文件，看不到中途塞进去的包。
log "引入官方 feed 之外的包"
OPENWRT_DIR="$OPENWRT_DIR" bash "$BUILDER_DIR/scripts/extra-packages.sh"

# 重建索引。-i 只重扫目录、不执行 git pull，所以不会碰刚拷进去的文件。
log "重建 feed 索引（不拉取仓库）"
./scripts/feeds update -i -a

log "安装全部 feed"
./scripts/feeds install -a

log "feeds install 完成，package/feeds/ 下有："
ls -1 package/feeds/ 2>/dev/null | sed 's/^/    /' | tee -a "$LOG_FILE" >&3 || true

# 确认那 4 个引入的包真的被 install 认领了（索引没重建的话这一步会漏）。
for p in ddns-go msd_lite; do
  [[ -e "package/feeds/packages/$p" ]] \
    || die "package/feeds/packages/$p 不存在，引入的包没有被 feeds install 接管"
done
for p in luci-app-ddns-go luci-app-msd_lite; do
  [[ -e "package/feeds/luci/$p" ]] \
    || die "package/feeds/luci/$p 不存在，引入的包没有被 feeds install 接管"
done

# 没有这个 feed，ATH11K_NSS_SUPPORT 会因依赖不满足而无法在 menuconfig 里选中。
[[ -d "$OPENWRT_DIR/feeds/nss" ]] || die "NSS feed 没有就位（feeds/nss 不存在），检查上面的 feeds 步骤"

# ── 2. 组装 .config ──────────────────────────────────────────
log "生成 .config：common.config + qhora_301w.config"
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
  printf '  %s\n' "${dropped[@]}" >&2
  die "defconfig 丢弃了 ${#dropped[@]} 个配置文件请求的符号（通常是依赖未满足），不要使用这个 .config"
fi
log "配置文件请求的符号全部保留"

# ── 4. 不要把整个自定义 feed 打进镜像 ───────────────────────
feed_name="$(awk '{print $2}' <<<"$NSS_FEED")"
log "关闭 CONFIG_FEED_${feed_name}（只保留 .config 里显式选中的包）"
sed -i "s/^CONFIG_FEED_${feed_name}=.*/# CONFIG_FEED_${feed_name} is not set/" .config

# ── 5. 叠加 files/ ──────────────────────────────────────────
if [[ -d "$BUILDER_DIR/files" ]]; then
  log "叠加 files/ 覆盖文件"
  mkdir -p files
  # 用 cp -a 而不是 rsync：GitHub runner 上两者都有，但本地 Windows/MSYS 环境
  # 通常没有 rsync，用 cp 可以两边通用。斜杠点号保证是"合并"而不是"替换"。
  cp -a "$BUILDER_DIR/files/." files/
  # sshd_config 必须是 0600，否则 dropbear/openssh 会拒绝加载。
  if [[ -f files/etc/ssh/sshd_config ]]; then
    chmod 0600 files/etc/ssh/sshd_config
  fi
  # uci-defaults 里的脚本需要可执行位才会在首次启动时运行。
  if [[ -d files/etc/uci-defaults ]]; then
    chmod 0755 files/etc/uci-defaults/* 2>/dev/null || true
  fi
fi

log "构建环境就绪：qualcommax/ipq807x → QNAP QHora-301W（qnap_301w）"
