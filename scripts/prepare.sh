#!/usr/bin/env bash
#
# 统一构建准备入口 —— 把「基座 × NSS × 代理栈」收敛成一次调用。
#
# 以前这套组合是 11 个 600~900 行的 workflow 手工展开的（源 × 代理栈 ×
# sing-box 模式），90% 内容逐字重复，改一处要同步改 11 处。现在所有差异都
# 收敛到本文件的几个环境变量上，workflow 只剩一条。
#
# ── 输入（环境变量）────────────────────────────────────────────
#   OPENWRT_DIR   已检出的基座源码目录（必需）
#   BUILDER_DIR   本仓库的检出目录（必需）
#
#   DISTRO        immortalwrt（默认）| openwrt
#                 决定发行版本身（固件 DISTRIB_ID），优先级最高。
#   NSS           0（默认）| 1
#                 1 有两种落法，按**检出的树**自动选，调用方不指定：
#                   整树  树里已有 package/kernel/nss-wifi-drv
#                          （= JuliusBairaktaris/openwrt-ppe-nss@ppe-nss 直接编）
#                   移植  树里没有（immortalwrt / openwrt main）
#                          = scripts/integrate-nss-wifi.sh 把 Wi-Fi 卸载搬进来
#                 0 = 该基座的原始树：不引 feed、不打补丁、不开任何 NSS 符号。
#   PROXY_STACK   daed（默认）| dae | honk | homeproxy | singbox | passwall |
#                 passwall2 | none
#                 passwall  = v1（Lua 界面，luci-app-passwall）
#                 passwall2 = v2（ucode 界面，luci-app-passwall2）
#   SINGBOX_MODE  builtin（默认，仅 homeproxy）| source（仅 singbox）
#                 其余代理栈一律按 fixed 处理 —— 它们不碰 sing-box
#   EXTRA_PACKAGES  逗号分隔，从 kenzok8/small 取的额外插件（可空）
#
#   其余变量（GH_TOKEN / DDNS_GO_VERSION / MSD_LITE_SHA …）原样透传给
#   scripts/prepare-build.sh，本脚本不干预。
#
# ── NSS 的两种落法 ───────────────────────────────────────────
# 「NSS 的 Wi-Fi 卸载」在 OpenWrt 里不是一套 feed 包，而是三样东西：
#   nss-wifi-drv 包 + 18 个 mac80211/ath11k 补丁 + mac80211 里的三处挂钩。
# 以前只有 ppe-nss 整树一条路（直接编那棵树）。现在多一条：把这三样搬到
# 任意一棵同基线的树上（immortalwrt 走这条）。两条路的产物一样，差别只在
# 「谁维护那三样」—— 整树是上游维护，移植是我们构建时搬。
#
# 怎么选不看参数、看树：树里有 nss-wifi-drv 就是整树，没有就是移植。这样
# workflow 里就不会出现「参数说移植、实际检出整树」这种静默错配 —— 那种
# 不一致编出来也是好固件，只是做法和你以为的不一样。
#
# 有线加速两边都有，但来源不同：整树靠树内的 PPE 改动，imm 靠它自己
# 已经合并的 qca_ppe（ipq807x 的 config-default 默认开）。
#
set -Eeuo pipefail

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
BUILDER_DIR="${BUILDER_DIR:?BUILDER_DIR 未设置}"

DISTRO="${DISTRO:-immortalwrt}"
NSS="${NSS:-0}"
PROXY_STACK="${PROXY_STACK:-daed}"
# SINGBOX_MODE 只对 homeproxy / singbox 有意义。其余栈（daed / dae / honk /
# passwall / passwall2 / none）根本不碰 sing-box，传它一个 builtin 会被 extra-packages.sh
# 里的断言直接拒绝（"builtin 只对 homeproxy / singbox 有意义"）。
# workflow 的 singbox_mode 是个全局默认值，不分栈，所以这里统一归一 ——
# 与其让调用方每次都记得传对，不如在这里兜住。
case "${PROXY_STACK}" in
  homeproxy|singbox) SINGBOX_MODE="${SINGBOX_MODE:-builtin}" ;;
  *)
    if [[ -n "${SINGBOX_MODE:-}" && "${SINGBOX_MODE}" != "fixed" ]]; then
      printf '\033[1;33m[!]\033[0m SINGBOX_MODE=%s 对代理栈 %s 没有意义，按 fixed 处理\n' \
        "$SINGBOX_MODE" "$PROXY_STACK"
    fi
    SINGBOX_MODE=fixed
    ;;
esac
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

case "$DISTRO" in
  immortalwrt|openwrt) ;;
  *) die "DISTRO 只能是 openwrt / immortalwrt，收到：$DISTRO" ;;
esac
case "$NSS" in
  0|1) ;;
  *) die "NSS 只能是 0 或 1，收到：$NSS" ;;
esac
case "$PROXY_STACK" in
  daed|dae|honk|homeproxy|singbox|passwall|passwall2|none) ;;
  *) die "PROXY_STACK 不认识：$PROXY_STACK（只支持 daed / dae / honk / homeproxy / singbox / passwall / passwall2 / none）" ;;
esac

[[ -d "$OPENWRT_DIR" ]] || die "基座源码目录不存在：$OPENWRT_DIR"

export PROXY_STACK SINGBOX_MODE NSS DISTRO EXTRA_PACKAGES

# ── 树指纹：不信任调用方传进来的 DISTRO/NSS，直接看树 ──────────
# workflow 里 checkout 和 prepare 是两个步骤，中间任何一处写错都会让
# 「以为选的是 imm」和「实际检出 ppe-nss」对不上，而那种不一致编出来是
# 好好的固件 —— 只是发行版和 NSS 都不是你要的那个。所以三样一起看：
#   · include/version.mk 里 VERSION_DIST 的兜底值 → 这棵树自称哪个发行版
#   · package/kernel/nss-wifi-drv、seeds/*.seed   → 是不是 ppe-nss 整树
HAS_NSS_WIFI_DRV=0
[[ -d "$OPENWRT_DIR/package/kernel/nss-wifi-drv" ]] && HAS_NSS_WIFI_DRV=1
HAS_PPE_SEED=0
[[ -f "$OPENWRT_DIR/seeds/qualcommax-nss-wifi.seed" ]] && HAS_PPE_SEED=1

# 树的身份就是 VERSION_DIST 的兜底值：openwrt main 是 OpenWrt、immortalwrt
# 是 ImmortalWrt、ppe-nss（openwrt main 的 fork）也是 OpenWrt。取不到就留空，
# 按「没有指纹」处理 —— 宁可不查，也不拿猜出来的值当断言依据。
TREE_DIST=""
if [[ -f "$OPENWRT_DIR/include/version.mk" ]]; then
  TREE_DIST="$(sed -n 's/^[[:space:]]*VERSION_DIST:=\$(if \$(VERSION_DIST),\$(VERSION_DIST),\([A-Za-z0-9_]*\)).*/\1/p' \
                 "$OPENWRT_DIR/include/version.mk" | head -n1)"
  TREE_DIST="$(printf '%s' "$TREE_DIST" | tr '[:upper:]' '[:lower:]')"
fi

# ── NSS=1：先看树里有没有 ppe-nss 的 seed，决定「整树」还是「移植」──
# 判据用 seed 而不是 nss-wifi-drv 目录：移植线跑完以后树里也会有那个目录，
# 拿目录当判据的话，第二次跑就会把「移植过的 imm」认成「ppe-nss 整树」，
# 然后因为缺少 seeds/ 而失败 —— 明明什么都没错。
if [[ "$NSS" == "1" ]]; then
  if (( HAS_PPE_SEED )); then
    NSS_MODE=tree
  else
    NSS_MODE=port
  fi
else
  NSS_MODE=none
fi

case "$NSS_MODE" in
  tree)
    # 整树：两样东西都得在。ppe-nss 的 .config 里有一堆别处不认识的符号
    # （CONFIG_PACKAGE_kmod-nss-wifi-drv / CONFIG_ATH11K_NSS_WIFI /
    # CONFIG_NSS_FIRMWARE_VERSION_12_5 …）。树不对时 `make defconfig` 会
    # **静默丢掉**它们，固件照样编出来、名字一样、刷进去也能开机 —— 只是
    # Wi-Fi 走的还是 CPU。宁可在第一步就炸。
    (( HAS_NSS_WIFI_DRV )) || die \
      "树里有 seeds/qualcommax-nss-wifi.seed 却没有 package/kernel/nss-wifi-drv —— 半棵树，分支选错了？"
    [[ -d "$OPENWRT_DIR/target/linux/qualcommax" ]] || die \
      "NSS=1 但树里没有 target/linux/qualcommax —— 检出的不是这个 target 的源码"

    # ppe-nss 的 nss-packages 分支只提供 nss-firmware，驱动在树里。
    export NSS_FEED="src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;ppe-nss"
    # 顺序要紧：树的 seed 先上（提供全部 NSS 符号），本仓库的 nss.config 后上
    # （只做减法 —— 关掉 seed 里在原版 feed 上取不到的可选包，否则符号校验会红）。
    [[ -f "$BUILDER_DIR/configs/nss.config" ]] || die "缺少 configs/nss.config"
    EXTRA_LAYERS=(
      "$OPENWRT_DIR/seeds/qualcommax-nss-wifi.seed"
      "$BUILDER_DIR/configs/nss.config"
    )
    ;;

  port)
    # 移植：树里没有 nss-wifi-drv，就把 ppe-nss 那三样搬过来。
    # 下面这个脚本是唯一动树的地方 —— 它按锚点插挂钩、插不上就失败，
    # 所以「搬了一半」不可能静默通过。
    [[ -f "$BUILDER_DIR/scripts/integrate-nss-wifi.sh" ]] ||
      die "缺少 scripts/integrate-nss-wifi.sh —— 移植线没法成立"
    [[ -f "$BUILDER_DIR/configs/nss-wifi-imm.config" ]] ||
      die "缺少 configs/nss-wifi-imm.config"
    [[ -d "$OPENWRT_DIR/target/linux/qualcommax" ]] || die \
      "NSS=1 但树里没有 target/linux/qualcommax —— 检出的不是这个 target 的源码"

    log "NSS 走移植线：从 ppe-nss 搬驱动与补丁进 $OPENWRT_DIR"
    OPENWRT_DIR="$OPENWRT_DIR" \
    NSS_WIFI_REF="${NSS_WIFI_REF:-ppe-nss}" \
      bash "$BUILDER_DIR/scripts/integrate-nss-wifi.sh"

    # 移植线的 feed 只要 nss-firmware 那一个包（驱动由我们搬进来的包提供）。
    export NSS_FEED="src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;ppe-nss"
    EXTRA_LAYERS=( "$BUILDER_DIR/configs/nss-wifi-imm.config" )
    ;;

  none)
    # ── NSS=0：树里不能是 ppe-nss 整树，否则说明检出了 ppe-nss ──────
    if (( HAS_PPE_SEED )); then
      die "NSS=0 但检出的是 ppe-nss 整树（seeds/qualcommax-nss-wifi.seed 存在）—— 参数与树不一致"
    fi
    # 移植线跑过的树会留下 nss-wifi-drv，但没有符号层它不会被编进去。
    # 只提示，不失败 —— 复用同一棵树时这不是错。
    (( HAS_NSS_WIFI_DRV )) && \
      warn "树里有上次移植留下的 package/kernel/nss-wifi-drv；NSS=0 不会编它"
    # 显式置空：prepare-build.sh 用 ${NSS_FEED-…} 区分「未设置」和「空」，
    # 空串才会真正跳过 feed 追加与 feeds/nss 守卫。
    export NSS_FEED=""
    EXTRA_LAYERS=()
    ;;
esac

# ── 树指纹核对：DISTRO 与树的自我声明必须一致 ──────────────────
# imm 线上这一条最要紧：固件的 DISTRIB_ID 就取自这里。树检错了，
# 编出来的固件照样能开机、什么报错都没有，只是发行版不是你要的那个。
if [[ -n "$TREE_DIST" ]]; then
  expect_dist=openwrt
  if [[ "$DISTRO" == "immortalwrt" ]]; then expect_dist=immortalwrt; fi
  [[ "$TREE_DIST" == "$expect_dist" ]] || die \
    "树与参数不一致：DISTRO=$DISTRO 期望 ${expect_dist} 树，但 include/version.mk 的 VERSION_DIST 兜底值是 ${TREE_DIST}"
  log "树指纹核对通过：${TREE_DIST}（$([[ "$NSS_MODE" == tree ]] && echo 'ppe-nss 整树' || echo '上游树')）"
fi

# ── 基座的 config 差异层 ────────────────────────────────────────
# 只有 immortalwrt 需要：换成 imm 之后个别包名 / 符号取值与 openwrt 不同，
# 那些差异只对这条线成立，写进 common.config 会连累其他线。
# （imm 线不可能是 NSS=1，上面的断言已经挡掉了，所以这里只看 DISTRO。）
if [[ "$DISTRO" == "immortalwrt" ]]; then
  base_layer="$BUILDER_DIR/configs/imm.config"
  [[ -f "$base_layer" ]] || die "缺少 immortalwrt 的 config 覆盖层：$base_layer"
  EXTRA_LAYERS=("$base_layer" "${EXTRA_LAYERS[@]}")
fi

case "$NSS_MODE" in
  tree) tree_label="ppe-nss 整树" ;;
  port) tree_label="${DISTRO} 原始树 + NSS 移植" ;;
  *)    tree_label="${DISTRO} 原始树" ;;
esac
log "基座=$DISTRO  NSS=$NSS（树=$tree_label）  代理栈=$PROXY_STACK  sing-box=$SINGBOX_MODE"
[[ -n "$EXTRA_PACKAGES" ]] && log "额外插件（kenzok8/small）：$EXTRA_PACKAGES"

if [[ ${#EXTRA_LAYERS[@]} -gt 0 ]]; then
  export EXTRA_CONFIG="${EXTRA_LAYERS[*]}"
  log "额外 config 层：$EXTRA_CONFIG"
fi

# ── feeds → 第三方包 → .config → 校验 → 覆盖文件 → 内核补丁 ─────
exec bash "$BUILDER_DIR/scripts/prepare-build.sh"
