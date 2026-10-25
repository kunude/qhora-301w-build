#!/usr/bin/env bash
#
# 本地先验：在**已经 configure 好**的 OpenWrt 树里，只编 sing-box 一个包。
#
# ── 为什么需要它 ────────────────────────────────────────────────
# 2026-10-26 连续三轮 CI 全量编译都挂在 sing-box 上，两次是断言自伤、
# 一次是真编不过（codeload tar.gz 顶层多一层目录 → go.mod 找不到）。
# 每一次的代价都是"推一次 + 等 30~60 分钟 + 读日志"，而这条链路
# （渲染 → 落位 → feeds install → 单包编译）在本机 **10 分钟**内就能走完。
# 所以：改 packages/net/sing-box-refind/** 或 resolve 脚本之后，
# 先跑这个，绿了再推。
#
# ── 前提 ────────────────────────────────────────────────────────
# 树要"能立刻编"的状态：
#   · .config 已生成（make menuconfig/defconfig 过）
#   · 交叉工具链已编（staging_dir/toolchain-* 存在）
#   · feeds 已 update（feeds/packages 存在）
# 跑过至少一次完整 make 的树天然满足。用 cron 之外的方式准备一棵树：
#   git clone --depth 1 https://github.com/immortalwrt/immortalwrt
#   cd immortalwrt && ./scripts/feeds update -a && ./scripts/feeds install -a
#   echo 'CONFIG_TARGET_qualcommax_ipq807x_DEVICE_qnap_301w=y' > .config
#   make defconfig && make tools/install toolchain/install
#
# ── 它不动你的树 ────────────────────────────────────────────────
# 落位前把 feeds/packages/net/sing-box 备份到临时目录，跑完（无论成败）
# 都还原 —— 只留下 build_dir 里的产物，下次跑还能吃编译缓存。
#
# ── 用法 ────────────────────────────────────────────────────────
#   scripts/local-verify-singbox.sh [OPENWRT_DIR] [--keep]
#     OPENWRT_DIR  默认 $OPENWRT_DIR；再没有就用 ~/build/immortalwrt
#     --keep       跑完不还原（想直接拿 build_dir 里的二进制时用）
#   SINGBOX_SRC_REF  透传给 resolve 脚本（默认 testing）
#   GH_TOKEN         查 commit 日期用，可选
#
# 退出码：0 = 编出来了且校验通过；非 0 = 失败（日志在 $LOG）
#
# SPDX-License-Identifier: GPL-2.0-only
set -Eeuo pipefail

KEEP=0
OPENWRT_DIR=""
for a in "$@"; do
	case "$a" in
		--keep) KEEP=1 ;;
		*) OPENWRT_DIR="$a" ;;
	esac
done
OPENWRT_DIR="${OPENWRT_DIR:-${OPENWRT_DIR_ENV:-$HOME/build/immortalwrt}}"
BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${LOG:-/tmp/local-verify-singbox.log}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ── 0. 树是不是"能立刻编" ───────────────────────────────────────
[[ -d "$OPENWRT_DIR" ]] || die "找不到 OpenWrt 树：$OPENWRT_DIR"
cd "$OPENWRT_DIR"
[[ -f .config ]] || die "$OPENWRT_DIR 没有 .config（先 make defconfig）"
compgen -G "staging_dir/toolchain-*" >/dev/null \
	|| die "$OPENWRT_DIR 没有交叉工具链（先 make tools/install toolchain/install）"
[[ -d feeds/packages ]] || die "$OPENWRT_DIR/feeds/packages 不存在（先 ./scripts/feeds update/install）"
command -v tar >/dev/null && command -v sha256sum >/dev/null \
	|| die "缺 tar / sha256sum"

log "树：$OPENWRT_DIR（$(git log -1 --format='%h %s' 2>/dev/null || echo '不是 git 树')）"

# ── 1. 渲染配方 ────────────────────────────────────────────────
RENDER="$(mktemp -d /tmp/sb-render.XXXXXX)"
trap 'rm -rf "$RENDER"' EXIT
log "渲染源码配方（ref=${SINGBOX_SRC_REF:-testing}）"
OPENWRT_DIR="$OPENWRT_DIR" GH_TOKEN="${GH_TOKEN:-}" \
	bash "$BUILDER_DIR/scripts/resolve-singbox-src.sh" \
		"$BUILDER_DIR/packages/net/sing-box-refind" "$RENDER" \
	| sed 's/^/    /'

# ── 2. 落位（备份原样，跑完还原）────────────────────────────────
FEED_PKG="feeds/packages/net/sing-box"
BAK=""
if [[ -e "$FEED_PKG" ]]; then
	BAK="$(mktemp -d /tmp/sb-feedbak.XXXXXX)/pkg"
	cp -a "$FEED_PKG" "$BAK"
	log "已备份原 $FEED_PKG → $BAK"
fi
restore() {
	[[ "$KEEP" == "1" ]] && { warn "--keep：保留落位结果，不还原 $FEED_PKG"; return 0; }
	rm -rf "$FEED_PKG"
	if [[ -n "$BAK" && -e "$BAK" ]]; then
		cp -a "$BAK" "$FEED_PKG"
		log "已还原 $FEED_PKG"
	else
		log "原本没有 $FEED_PKG，保持不存在的状态"
	fi
}
trap 'restore; rm -rf "$RENDER"' EXIT

rm -rf "$FEED_PKG"
mkdir -p "$FEED_PKG"
cp -a "$RENDER"/. "$FEED_PKG"/
rm -f "$FEED_PKG/resolve.env"
./scripts/feeds install -f sing-box >/dev/null 2>&1 \
	|| die "feeds install -f sing-box 失败"
[[ -e package/feeds/packages/sing-box ]] \
	|| die "feeds install 之后 package/feeds/packages/sing-box 仍不存在"
ok "配方已落位（$(sed -n 's/^PKG_VERSION:=//p' "$FEED_PKG/Makefile" | head -1)）"

# ── 3. 单包编译 ────────────────────────────────────────────────
NPROC="$(nproc 2>/dev/null || echo 4)"
log "make package/feeds/packages/sing-box/compile -j$NPROC（日志 $LOG）"
set +e
make package/feeds/packages/sing-box/compile -j"$NPROC" V=s >"$LOG" 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
	# 只回放真正有信息量的尾部，别把 1 万行 V=s 全倒出来
	tail -n 40 "$LOG" | sed 's/^/    /' >&2
	die "编译失败（完整日志：$LOG）"
fi
ok "编译通过"

# ── 4. 校验产物 ────────────────────────────────────────────────
# 二进制在 .go_work 里（golang-package.mk 的 GOPATH 布局），不是 PKG_BUILD_DIR 根。
BIN="$(find build_dir -type f -path '*sing-box*/bin/*/sing-box' -print -quit 2>/dev/null || true)"
[[ -n "$BIN" ]] || BIN="$(find build_dir -type f -name sing-box -perm -u+x -print -quit 2>/dev/null || true)"
[[ -n "$BIN" ]] || die "编译说成功，但 find 不到 sing-box 二进制（日志 $LOG）"

sz="$(stat -c %s "$BIN")"
log "二进制：$BIN（$((sz / 1024 / 1024)) MB）"

# ELF 架构 + 动态链接器：必须是 aarch64 + musl，否则说明交叉编译没生效
hdr="$(head -c 200000 "$BIN" | strings | grep -m1 'ld-musl-aarch64' || true)"
[[ -n "$hdr" ]] || warn "二进制里没看到 ld-musl-aarch64 —— 检查 TARGET 是不是 aarch64/musl"
grep -aq -- '-refind' "$BIN" \
	|| die "二进制里没有 -refind 版本串 —— GO_PKG_LDFLAGS_X 没生效"
ver="$(grep -ao '[0-9][0-9.]*_git[0-9]\{8\}-refind' "$BIN" | head -1 || true)"
ok "版本串：${ver:-（含 -refind，未取到完整串）}"

# 编译产物大小兜底：正常 100~160MB（未 strip）。明显偏小说明标签被裁掉了。
(( sz > 60 * 1024 * 1024 )) \
	|| die "二进制只有 $((sz / 1024 / 1024)) MB，远小于正常体积 —— 构建标签可能被裁掉"

# ── 5. 结论 ────────────────────────────────────────────────────
ok "本地先验通过 —— 可以推了"
printf '  树      %s\n' "$OPENWRT_DIR"
printf '  版本    %s\n' "${ver:-?}"
printf '  二进制  %s\n' "$BIN"
printf '  日志    %s\n' "$LOG"
