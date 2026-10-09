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
set -euo pipefail

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
BUILDER_DIR="${BUILDER_DIR:?BUILDER_DIR 未设置}"
NSS_FEED="${NSS_FEED:-src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;edma-nss}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

CONFIGS=(
  "$BUILDER_DIR/configs/common.config"
  "$BUILDER_DIR/configs/qhora_301w.config"
)

# 缺任何一个关键符号就中止：这些符号被丢掉说明镜像不是我们想要的东西，
# 早点失败比默默产出一个残废固件好。
CRITICAL_SYMBOLS=(
  'CONFIG_TARGET_qualcommax=y'
  'CONFIG_TARGET_qualcommax_ipq807x=y'
  'CONFIG_TARGET_DEVICE_qualcommax_ipq807x_DEVICE_qnap_301w=y'
  'CONFIG_ATH11K_MEM_PROFILE_1G=y'
  'CONFIG_NSS_MEM_PROFILE_HIGH=y'
  'CONFIG_ATH11K_NSS_SUPPORT=y'
  'CONFIG_PACKAGE_MAC80211_NSS_SUPPORT=y'
  'CONFIG_PACKAGE_kmod-qca-nss-drv=y'
  'CONFIG_PACKAGE_kmod-qca-nss-ecm=y'
  'CONFIG_PACKAGE_kmod-qca-nss-drv-pppoe=y'
  'CONFIG_PACKAGE_kmod-qca-nss-drv-qdisc=y'
  'CONFIG_PACKAGE_nss-tools=y'
  'CONFIG_NSS_FIRMWARE_VERSION_12_5=y'
  'CONFIG_PACKAGE_ipq-wifi-qnap_301w=y'
  'CONFIG_CCACHE=y'
  # 用户明确要求启用的三项。不放进来的话，一旦引入失败，
  # defconfig 会静默丢掉它们、编出一个"看起来正常但少了功能"的固件。
  'CONFIG_PACKAGE_ddns-go=y'
  'CONFIG_PACKAGE_luci-app-ddns-go=y'
  'CONFIG_PACKAGE_msd_lite=y'
  'CONFIG_PACKAGE_luci-app-msd_lite=y'
  'CONFIG_PACKAGE_kmod-wireguard=y'
  'CONFIG_PACKAGE_luci-proto-wireguard=y'
)

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

log "更新全部 feed"
./scripts/feeds update -a

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
make defconfig

# ── 3. 校验符号 ──────────────────────────────────────────────
log "校验关键符号是否保留"
missing=()
for sym in "${CRITICAL_SYMBOLS[@]}"; do
  grep -qxF "$sym" .config || missing+=("$sym")
done
if ((${#missing[@]})); then
  printf '  %s\n' "${missing[@]}" >&2
  die "defconfig 丢弃了 ${#missing[@]} 个关键符号（通常是依赖未满足），不要使用这个 .config"
fi

# 其余符号只告警：工具链版本号这类可选项被丢掉不影响功能。
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
  warn "以下 ${#dropped[@]} 个符号被 defconfig 丢弃（不影响构建，仅供留意）："
  printf '  %s\n' "${dropped[@]}" >&2
fi

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
