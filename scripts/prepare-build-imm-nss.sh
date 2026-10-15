#!/usr/bin/env bash
#
# immortalwrt + NSS 线的构建准备入口。
#
# ── 与老两条线的关系 ────────────────────────────────────────────
# 三条线共用同一个 scripts/prepare-build.sh（feed → 引入第三方包 → 拼 .config
# → defconfig → 符号校验 → 凭据守卫 → 叠加覆盖文件 → 注入内核补丁）。
# 本线的**唯一**区别是第 0 步：
#
#   老线（passwall2 / homeproxy）
#     源码树 = JuliusBairaktaris/openwrt-nss-edma @ nss-edma-rework
#              —— 本身就是「openwrt main + NSS」，拿来即用；
#              该分支已被作者归档（不再更新），基座从此不再跟着上游走。
#
#   本线（imm-nss）
#     源码树 = immortalwrt/immortalwrt（活的，内核 / DTS / 驱动 / LuCI / feed
#              持续更新），NSS 那一系列改动由
#              scripts/apply-nss-patches.sh 以补丁形式叠上去。
#
# 拆开之后：基座能持续更新，NSS 改动是一份固定、可追溯、可重新生成的补丁。
#
# ── 环境变量 ────────────────────────────────────────────────────
#   OPENWRT_DIR   已检出的 immortalwrt 源码目录（必需）
#   BUILDER_DIR   本仓库的检出目录（必需）
# 其余变量（GH_TOKEN / DDNS_GO_VERSION / MSD_LITE_SHA / PW_* / SINGBOX_* /
# IMM_REF …）原样透传给 prepare-build.sh —— 工作流里怎么设，这里不干预。
#
# 本脚本额外用的两个：
#   NSS_FEED       NSS 包所在的 feed，默认与老线同一个 feed、同一个分支
#                  （feed 是独立的包仓库，与"换不换基座"无关）
#   IMM_CONFIG     immortalwrt 特有的 .config 覆盖层，默认 configs/imm-nss.config
#                  （immortalwrt 的包名 / 符号取值与 openwrt 有差异，见该文件）
#
set -Eeuo pipefail

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
BUILDER_DIR="${BUILDER_DIR:?BUILDER_DIR 未设置}"

# NSS 驱动 / ECM / qdisc / 固件所在的 feed —— 与老线完全同一个（feed 不依赖基座）。
# prepare-build.sh 里也有同样的默认值，这里写出来是为了让本线的意图自解释。
export NSS_FEED="${NSS_FEED:-src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;edma-nss}"

# 代理栈：默认 passwall2（与主线一致），传 homeproxy 就切到 HomeProxy 那套。
export PROXY_STACK="${PROXY_STACK:-passwall2}"

# immortalwrt 特有的 .config 覆盖层。老线的 prepare-build.sh 只认识
# common.config + qhora_301w.config [+ homeproxy.config]，所以这一层通过
# EXTRA_CONFIG 传进去（那是个可选参数：不设时行为与以前完全一致）。
IMM_CONFIG="${IMM_CONFIG:-$BUILDER_DIR/configs/imm-nss.config}"
[[ -f "$IMM_CONFIG" ]] || { printf '::error::找不到 immortalwrt 覆盖层：%s\n' "$IMM_CONFIG" >&2; exit 1; }
export EXTRA_CONFIG="$IMM_CONFIG"

printf '\033[1;34m==>\033[0m immortalwrt + NSS 线：基座 %s，NSS 补丁 %s\n' \
  "$OPENWRT_DIR" "$BUILDER_DIR/patches/immortalwrt-nss"

# ── 第 0 步（本线独有）：把 NSS 移植进 immortalwrt 源码树 ──────────
bash "$BUILDER_DIR/scripts/apply-nss-patches.sh"

# ── 第 1–7 步：与老两条线完全相同 ────────────────────────────────
# exec 而不是普通调用：把进程让给 prepare-build.sh，它的 fd3/日志/ERR trap
# 都按原样生效（它会把日志写到 $GITHUB_WORKSPACE/prepare-build.log）。
exec bash "$BUILDER_DIR/scripts/prepare-build.sh"
