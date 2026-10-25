#!/usr/bin/env bash
#
# 把 packages/net/sing-box-refind/Makefile.in 渲染成一份**可直接构建**的配方。
#
# 三处占位符由本脚本填：
#   @VER@   包版本，形如 1.14.0_git20261024（见下面"版本号"）
#   @SHA@   reF1nd/sing-box 的 commit sha（40 位）
#   @HASH@  codeload 该 commit 的 tar.gz 的 sha256
#
# ── 为什么版本号长这样 ──────────────────────────────────────────
# OpenWrt 25.12 起默认用 apk，apk 的版本串有严格白名单：
#   1.2.3[_alpha|_beta|_pre|_rc|_cvs|_svn|_git|_hg|_p][数字][~数字][-r数字]
# 所以不能写成 `1.14.0-refind-abc123`（字母后缀会被 apk 拒绝）。
# 采用 `<上游基线>_git<commit 日期>`：
#   · 合法、可排序（_git 高于同版本正式版，符合"这是更新代码"的语义）；
#   · 能一眼看出"这是源码快照、不是发布版"；
#   · 日期取**上游 commit 时间**而不是构建时间 —— 同一个 commit 反复构建，
#     包版本稳定不变，ccache/构建缓存才有机会复用。
# 基线版本（SINGBOX_SRC_BASE）只是给人看的参考值，不参与任何逻辑判断；
# 上游升大版本时改一下这个默认值即可（改错了也不会影响编出来的二进制）。
#
# ── 环境变量 ────────────────────────────────────────────────────
#   OPENWRT_DIR       OpenWrt 源码目录（必需；tarball 要放进它的 dl/）
#   SINGBOX_SRC_REF   取哪个 ref，默认 testing。可以是分支 / tag / 40 位 sha
#   SINGBOX_SRC_BASE  版本号里的上游基线，默认 1.14.0
#   GH_TOKEN          查 commit 日期用（未认证 60 次/小时，够用，但 CI 里一般都注入）
#
# ── 用法 ────────────────────────────────────────────────────────
#   resolve-singbox-src.sh <模板目录> <输出目录>
# 输出目录里会得到：Makefile + files/ + resolve.env（VER/SHA/HASH/SHA7/REF）
#
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

TEMPLATE_DIR="${1:?用法：resolve-singbox-src.sh <模板目录> <输出目录>}"
OUT_DIR="${2:?用法：resolve-singbox-src.sh <模板目录> <输出目录>}"
OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
SINGBOX_SRC_REF="${SINGBOX_SRC_REF:-testing}"
SINGBOX_SRC_BASE="${SINGBOX_SRC_BASE:-1.14.0}"
GH_TOKEN="${GH_TOKEN:-}"

REPO="https://github.com/reF1nd/sing-box.git"
REPO_SLUG="reF1nd/sing-box"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ann()  { printf '::notice title=%s::%s\n' "$1" "$2" 2>/dev/null || true; }

[[ -f "$TEMPLATE_DIR/Makefile.in" ]] \
	|| die "模板不存在：$TEMPLATE_DIR/Makefile.in"
[[ -d "$OPENWRT_DIR/dl" ]] || mkdir -p "$OPENWRT_DIR/dl"

# ── 1. ref → sha ────────────────────────────────────────────────
# git ls-remote 不消耗 API 配额，比 REST 更耐造。40 位 sha 直接透传
# （ls-remote 对裸 sha 会返回空，得单独判断）。
if [[ "$SINGBOX_SRC_REF" =~ ^[0-9a-f]{40}$ ]]; then
	SHA="$SINGBOX_SRC_REF"
	log "sing-box 源码：直接用给定 sha ${SHA}"
else
	log "sing-box 源码：解析 ref '$SINGBOX_SRC_REF'"
	ls_out="$(git ls-remote "$REPO" "$SINGBOX_SRC_REF" 2>/dev/null || true)"
	# 精确匹配 refs/heads/<ref> 或 refs/tags/<ref>，避免 ls-remote 的
	# 前缀匹配把 refs/heads/testing-foo 之类带进来。
	SHA="$(printf '%s\n' "$ls_out" \
		| awk -v r="$SINGBOX_SRC_REF" '
			$2 == "refs/heads/" r || $2 == "refs/tags/" r { print $1; exit }
		')"
	[[ -n "$SHA" ]] || SHA="$(printf '%s\n' "$ls_out" | awk 'NR==1{print $1}')"
	[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] \
		|| die "解析不出 '$SINGBOX_SRC_REF' 的 commit sha（git ls-remote 返回：${ls_out:-空}）"
fi
SHA7="${SHA:0:7}"

# ── 2. commit 日期 → 版本号 ─────────────────────────────────────
# 取不到就退回构建当天并告警：版本号只影响显示与缓存命中，不该让构建失败。
api="https://api.github.com/repos/${REPO_SLUG}/commits/${SHA}"
auth_hdr=()
[[ -n "$GH_TOKEN" ]] && auth_hdr=(-H "Authorization: Bearer ${GH_TOKEN}")
cdate="$(curl -fsSL --retry 2 --max-time 60 "${auth_hdr[@]}" \
	-H 'Accept: application/vnd.github+json' "$api" 2>/dev/null \
	| sed -n 's/.*"date"[[:space:]]*:[[:space:]]*"\([0-9-]\{10\}\)T.*/\1/p' | head -n1 || true)"
if [[ "$cdate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
	CDATE="${cdate//-/}"
else
	CDATE="$(date -u +%Y%m%d)"
	warn "取不到 commit ${SHA7} 的日期（GitHub API 失败），版本号退回构建日 ${CDATE}"
fi
VER="${SINGBOX_SRC_BASE}_git${CDATE}"

# ── 3. tarball → sha256（顺带塞进 dl/，免得构建时再下一次）────────
SRC_NAME="sing-box-refind-${SHA}.tar.gz"
DL_FILE="$OPENWRT_DIR/dl/$SRC_NAME"
if [[ -f "$DL_FILE" ]]; then
	log "dl/ 里已有 $SRC_NAME，直接算 hash"
	HASH="$(sha256sum "$DL_FILE" | awk '{print $1}')"
else
	log "下载 codeload tarball（$SHA7）"
	tmp="$DL_FILE.part"
	curl -fsSL --retry 3 --max-time 600 \
		"https://codeload.github.com/${REPO_SLUG}/tar.gz/${SHA}" \
		-o "$tmp" || die "下载 codeload tar.gz 失败（sha=$SHA）"
	# 空文件 / HTML 错误页都要拦住：它们在 sha256 那里看不出来。
	[[ -s "$tmp" ]] || die "下载到的 tar.gz 是空的"
	tar -tzf "$tmp" >/dev/null 2>&1 || die "下载到的不是有效 tar.gz（是不是被 CDN 拦了？）"
	mv -f "$tmp" "$DL_FILE"
	HASH="$(sha256sum "$DL_FILE" | awk '{print $1}')"
fi
[[ "$HASH" =~ ^[0-9a-f]{64}$ ]] || die "算 sha256 失败（拿到 '$HASH'）"

# ── 4. 渲染 ────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"
sed -e "s|@VER@|${VER}|g" \
    -e "s|@SHA@|${SHA}|g" \
    -e "s|@HASH@|${HASH}|g" \
    "$TEMPLATE_DIR/Makefile.in" > "$OUT_DIR/Makefile"

# 占位符必须全部替换干净 —— 漏一个会变成把 "@HASH@" 字面量写进 PKG_HASH，
# 报错信息会难看得多（"Hash mismatch" 而不是"模板没渲染"）。
if grep -qE '@(VER|SHA|HASH)@' "$OUT_DIR/Makefile"; then
	die "模板里还有没替换掉的占位符：$(grep -nE '@(VER|SHA|HASH)@' "$OUT_DIR/Makefile" | head -n 3)"
fi

cp -a "$TEMPLATE_DIR/files" "$OUT_DIR/files"
chmod 0755 "$OUT_DIR/files/sing-box.init"

cat > "$OUT_DIR/resolve.env" <<EOF
SINGBOX_SRC_VER=${VER}
SINGBOX_SRC_SHA=${SHA}
SINGBOX_SRC_SHA7=${SHA7}
SINGBOX_SRC_HASH=${HASH}
SINGBOX_SRC_REF=${SINGBOX_SRC_REF}
EOF

log "  版本 ${VER}（基线 ${SINGBOX_SRC_BASE} + commit 日 ${CDATE}）"
log "  sha  ${SHA}"
log "  hash ${HASH}"
ann "sing-box 源码版本" "sing-box=${VER}  commit=${SHA7}  来源=${REPO_SLUG}@${SINGBOX_SRC_REF}"

printf '%s\n' "$OUT_DIR"
