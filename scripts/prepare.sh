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
#   NSS           0（默认）| 1   —— 仅 DISTRO=openwrt 可用
#                 1 = 整棵树换成 JuliusBairaktaris/openwrt-ppe-nss@ppe-nss
#                     有线 PPE 加速 + NSS Wi-Fi offload 全都在，不打补丁。
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
# ── 为什么 NSS 只有两态 ───────────────────────────────────────
# 曾经有过第三种「immortalwrt + NSS 移植补丁」。它现在不成立了：
#   · PR #22381（qca_edma 重构）2026-07-11 合入 openwrt main
#   · PR #24806（qca_ppe host-driven offload）2026-10-26 合入 openwrt main
#   · immortalwrt master 已同步，且 ipq807x/config-default 里
#     CONFIG_QCOM_EDMA=y / CONFIG_QCOM_80211AX_PPE=y 默认就开
# 所以「有线加速」imm 自带，不需要补丁；而「Wi-Fi offload」的 nss-wifi-drv
# 是 ppe-nss 树内的包，还改了 mac80211 的 ath11k 源码 —— 那是补丁补不出来的
# 量级，只能整树用。两头一夹，中间态就没了。
#
# 换句话说：NSS 是 openwrt 基座上的一个开关，**不能反过来决定发行版**。
# DISTRO=immortalwrt 时没有 NSS 可用（imm 树里根本没有 nss-wifi-drv），
# 传 NSS=1 直接失败，不静默降级 —— 「以为开了 NSS」比没有 NSS 更糟。
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

# ── ① = immortalwrt：不许有 NSS ────────────────────────────────
# NSS 的 Wi-Fi offload 由 ppe-nss 树内的 nss-wifi-drv 提供，还改了 mac80211
# 的 ath11k 源码 —— 补丁补不出来，只能整树用。所以 imm + NSS 这个组合物理上
# 不存在：要么静默编出一个"imm 但不带 NSS"的固件（用户以为拿到了 NSS），
# 要么当场失败。选后者。
if [[ "$DISTRO" == "immortalwrt" ]]; then
  [[ "$NSS" == "0" ]] || die \
    "① = immortalwrt 时不支持 NSS：nss-wifi-drv 只存在于 JuliusBairaktaris/openwrt-ppe-nss 整树（openwrt main 的 fork），补丁补不出来。" \
    "二选一：要 ImmortalWrt 就把 NSS 设为 0；要 NSS 就把 DISTRO 改成 openwrt。"
  if (( HAS_NSS_WIFI_DRV )) || (( HAS_PPE_SEED )); then
    die "① = immortalwrt 但检出的是 ppe-nss 树（package/kernel/nss-wifi-drv 存在）—— 编出来会是 OpenWrt，不是 ImmortalWrt"
  fi
fi

# ── NSS=1：必须是 ppe-nss 树，且两样东西都得在 ─────────────────
# 这两条断言是本脚本最值钱的部分。ppe-nss 的 .config 里有一堆 imm/openwrt
# 不认识的符号（CONFIG_PACKAGE_kmod-nss-wifi-drv / CONFIG_ATH11K_NSS_WIFI /
# CONFIG_NSS_FIRMWARE_VERSION_12_5 …）。树不对时 `make defconfig` 会**静默
# 丢掉**它们，固件照样编出来、名字一样、刷进去也能开机 —— 只是 Wi-Fi 走的
# 还是 CPU。宁可在第一步就炸。
if [[ "$NSS" == "1" ]]; then
  (( HAS_NSS_WIFI_DRV )) || die \
    "NSS=1 但 $OPENWRT_DIR 里没有 package/kernel/nss-wifi-drv —— 这不是 ppe-nss 树，编出来会静默降级成无 NSS 的固件"
  (( HAS_PPE_SEED )) || die \
    "NSS=1 但 $OPENWRT_DIR 里没有 seeds/qualcommax-nss-wifi.seed —— ppe-nss 分支选错了？"
  [[ -d "$OPENWRT_DIR/target/linux/qualcommax" ]] || die \
    "NSS=1 但树里没有 target/linux/qualcommax —— 检出的不是这个 target 的源码"

  # ppe-nss 的 nss-packages 分支只提供 nss-firmware，驱动在树里。
  export NSS_FEED="src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;ppe-nss"
  # 顺序要紧：树的 seed 先上（提供全部 NSS 符号），本仓库的 nss.config 后上
  # （只做减法 —— 关掉 seed 里在原版 feed 上取不到的可选包，否则符号校验会红）。
  [[ -f "$BUILDER_DIR/configs/nss.config" ]] || die "缺少 configs/nss.config"
  [[ -f "$OPENWRT_DIR/seeds/qualcommax-nss-wifi.seed" ]] \
    || die "ppe-nss 树里没有 seeds/qualcommax-nss-wifi.seed"
  EXTRA_LAYERS=(
    "$OPENWRT_DIR/seeds/qualcommax-nss-wifi.seed"
    "$BUILDER_DIR/configs/nss.config"
  )

else
  # ── NSS=0：树里不能有 NSS 的东西，否则说明检出了 ppe-nss ──────
  if (( HAS_NSS_WIFI_DRV )) || (( HAS_PPE_SEED )); then
    die "NSS=0 但检出的是 ppe-nss 树（package/kernel/nss-wifi-drv 存在）—— 参数与树不一致"
  fi
  # 显式置空：prepare-build.sh 用 ${NSS_FEED-…} 区分「未设置」和「空」，
  # 空串才会真正跳过 feed 追加与 feeds/nss 守卫。
  export NSS_FEED=""
  EXTRA_LAYERS=()
fi

# ── 树指纹核对：DISTRO 与树的自我声明必须一致 ──────────────────
# imm 线上这一条最要紧：固件的 DISTRIB_ID 就取自这里。树检错了，
# 编出来的固件照样能开机、什么报错都没有，只是发行版不是你要的那个。
if [[ -n "$TREE_DIST" ]]; then
  expect_dist=openwrt
  if [[ "$DISTRO" == "immortalwrt" ]]; then expect_dist=immortalwrt; fi
  [[ "$TREE_DIST" == "$expect_dist" ]] || die \
    "树与参数不一致：DISTRO=$DISTRO 期望 ${expect_dist} 树，但 include/version.mk 的 VERSION_DIST 兜底值是 ${TREE_DIST}"
  log "树指纹核对通过：${TREE_DIST}$([[ "$NSS" == "1" ]] && echo '（ppe-nss 整树）' || echo '')"
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

if [[ "$NSS" == "1" ]]; then tree_label="ppe-nss 整树"; else tree_label="${DISTRO} 原始树"; fi
log "基座=$DISTRO  NSS=$NSS（树=$tree_label）  代理栈=$PROXY_STACK  sing-box=$SINGBOX_MODE"
[[ -n "$EXTRA_PACKAGES" ]] && log "额外插件（kenzok8/small）：$EXTRA_PACKAGES"

if [[ ${#EXTRA_LAYERS[@]} -gt 0 ]]; then
  export EXTRA_CONFIG="${EXTRA_LAYERS[*]}"
  log "额外 config 层：$EXTRA_CONFIG"
fi

# ── feeds → 第三方包 → .config → 校验 → 覆盖文件 → 内核补丁 ─────
exec bash "$BUILDER_DIR/scripts/prepare-build.sh"
