#!/usr/bin/env bash
#
# 引入 OpenWrt 官方 feed 之外的包。现在分两类，处理方式不同：
#
# ── ① ddns-go / msd_lite（带二进制的包）→ 本仓库自带配方 ─────────
# 配方在 packages/net/*，PKG_SOURCE 直接指向上游源码仓库
# （jeessy2/ddns-go、rozhuk-im/msd_lite），版本与 hash 由
# scripts/resolve-versions.sh 在构建时解析后注入。
#
# 为什么不再从 ImmortalWrt 取这两个包：ImmortalWrt 的配方把版本**写死**了
# （例如 PKG_VERSION:=6.17.6 配对应 PKG_HASH），上游发了新版要等它 bump
# 才跟得上；而 OpenWrt 官方 packages feed 里干脆没有这两个包
# （实测 net/ddns-go 与 net/msd_lite 都是 404）。既然两边都不合适，
# 就自己写配方直接引用上游源码。
#
# ── ② luci-app-ddns-go / luci-app-msd_lite（纯前端）→ 仍取自 ImmortalWrt ─
# 它们只是页面（JS / ucode / 翻译），没有独立的"上游源码仓库"可指，抄一份到
# 本仓库只会让上游的界面更新跟不进来。它们通过
# LUCI_DEPENDS:=+ddns-go / +msd_lite 依赖上面那两个包，包名没变，照样接得上。
#
# ── 为什么必须放进 feed 目录，而不是 package/ ───────────────────
# 这些包的 Makefile 里是相对路径：
#   applications/luci-app-*/Makefile  →  include ../../luci.mk
#   net/ddns-go/Makefile              →  include ../../lang/golang/golang-package.mk
# 只有放在 <feed根>/<二级目录>/<包>/ 这个位置才能解析得到。
# 放进 package/ 会直接 `No rule to make target '../../luci.mk'`。
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
#   IMM_REF         ImmortalWrt 的分支，默认 master
#   IMM_LUCI        immortalwrt/luci 仓库地址
#
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
BUILDER_DIR="${BUILDER_DIR:?BUILDER_DIR 未设置}"
IMM_REF="${IMM_REF:-master}"
IMM_LUCI="${IMM_LUCI:-https://github.com/immortalwrt/luci.git}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -d "$OPENWRT_DIR" ]] || die "OPENWRT_DIR 不是有效目录：$OPENWRT_DIR"
[[ -d "$OPENWRT_DIR/feeds/packages" ]] || die "feeds/packages 不存在，请先跑 ./scripts/feeds update -a"
[[ -d "$OPENWRT_DIR/feeds/luci" ]]     || die "feeds/luci 不存在，请先跑 ./scripts/feeds update -a"

cd "$OPENWRT_DIR"

# ══════════════════════════════════════════════════════════════
# ① 本仓库自带的配方：packages/<分类>/<包>/ → feeds/packages/<分类>/<包>/
# ══════════════════════════════════════════════════════════════
OWN_ROOT="$BUILDER_DIR/packages"
[[ -d "$OWN_ROOT" ]] || die "本仓库里没有 packages/ 目录：$OWN_ROOT"

place_own() {
  local rel="$1"
  local src="$OWN_ROOT/$rel"
  local dst="feeds/packages/$rel"

  [[ -f "$src/Makefile" ]] || die "自带配方缺少 Makefile：$src"
  rm -rf "${dst:?}"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  log "  落位（本仓库自带）$dst"
}

own_count=0
while IFS= read -r -d '' mk; do
  rel="${mk#"$OWN_ROOT"/}"
  rel="${rel%/Makefile}"
  [[ -n "$rel" ]] || die "解析自带配方相对路径失败：$mk"
  place_own "$rel"
  own_count=$((own_count + 1))
done < <(find "$OWN_ROOT" -type f -name Makefile -print0 | sort -z)

((own_count > 0)) || die "$OWN_ROOT 下没找到任何 Makefile，自带配方不见了？"
log "自带配方落位完成，共 $own_count 个"

# ══════════════════════════════════════════════════════════════
# ② ImmortalWrt 的纯前端包（只取 luci 那一半）
# ══════════════════════════════════════════════════════════════
LUCI_PATHS=(applications/luci-app-ddns-go applications/luci-app-msd_lite)

WORK="$(mktemp -d)"
# 清理失败不能拖垮整个构建步骤（例如 Windows/MSYS 下 rm 对 /tmp 路径的处理）。
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# 稀疏检出：只下载指定目录的 blob，仓库其余部分不落地。
sparse_clone() {
  local repo="$1" dest="$2"; shift 2

  log "稀疏检出 $(basename "$repo")（只取：$*）"
  if git clone -q --depth=1 --filter=blob:none --sparse \
       --branch "$IMM_REF" "$repo" "$dest" 2>/dev/null; then
    git -C "$dest" sparse-checkout set "$@" >/dev/null 2>&1 \
      || warn "sparse-checkout set 失败，改用已有内容继续"
  else
    # 少数环境不支持 partial clone（--filter），退化为浅克隆整库。
    warn "稀疏检出失败，退化为浅克隆整库（会慢一些）"
    rm -rf "$dest"
    git clone -q --depth=1 --branch "$IMM_REF" "$repo" "$dest" \
      || die "克隆 $repo 失败"
    git -C "$dest" sparse-checkout set "$@" >/dev/null 2>&1 || true
  fi
}

# 把 <克隆目录>/<相对路径> 拷进 <feed目录>/<相对路径>
place() {
  local src_root="$1" feed_dir="$2" rel="$3"

  [[ -f "$src_root/$rel/Makefile" ]] \
    || die "上游没有 $rel/Makefile（$IMM_REF 分支结构可能变了），检查 $src_root"
  [[ -d "$feed_dir" ]] || die "目标 feed 目录不存在：$feed_dir"

  rm -rf "${feed_dir:?}/$rel"
  mkdir -p "$feed_dir/$(dirname "$rel")"
  cp -a "$src_root/$rel" "$feed_dir/$rel"
  log "  落位（ImmortalWrt 前端）$feed_dir/$rel"
}

sparse_clone "$IMM_LUCI" "$WORK/luci" "${LUCI_PATHS[@]}"
for rel in "${LUCI_PATHS[@]}"; do place "$WORK/luci" feeds/luci "$rel"; done

# ══════════════════════════════════════════════════════════════
# 前置依赖自检
# ══════════════════════════════════════════════════════════════
# ddns-go 是 Go 包，构建时要 include 官方 feed 的 golang 框架。
# 它不在就说明 packages feed 不完整，早点失败比编到一半炸好。
[[ -f feeds/packages/lang/golang/golang-package.mk ]] \
  || die "缺少 feeds/packages/lang/golang/golang-package.mk，ddns-go 无法构建"
[[ -f feeds/luci/luci.mk ]] \
  || die "缺少 feeds/luci/luci.mk，luci-app-* 无法构建"

log "引入完成：自带配方 ddns-go / msd_lite + ImmortalWrt 前端 luci-app-{ddns-go,msd_lite}"
warn "别忘了接着跑：./scripts/feeds update -i -a   # 重建索引，install 才看得到这些包"
