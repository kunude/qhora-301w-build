#!/usr/bin/env bash
#
# 引入 OpenWrt 官方 feed 之外的包。
#
# ── 为什么需要这个脚本 ──────────────────────────────────────────
# ddns-go 和 msd_lite 在 OpenWrt 官方 packages feed 里**不存在**，
# 只有 ImmortalWrt 的 feed 在维护。（已实测：openwrt/packages 的
# net/ddns-go 与 net/msd_lite 都是 404。）
#
# 不能直接把整个 ImmortalWrt feed 加进 feeds.conf：那个 feed 是官方 feed 的
# 分支，里面有成百上千个同名包（luci-app-firewall、aria2……），两份同名包
# 会互相打架，而这个 NSS 构建对 luci/packages 的版本组合相当敏感。
# 所以这里用 git 稀疏检出，只把这 4 个目录抠出来。
#
# ── 为什么必须放进 feed 目录，而不是 package/ ───────────────────
# 这些包的 Makefile 里是相对路径：
#   applications/luci-app-*/Makefile  →  include ../../luci.mk
#   net/ddns-go/Makefile              →  include ../../lang/golang/golang-package.mk
# 只有放在 <feed根>/<二级目录>/<包>/ 这个位置才能解析得到。
# 放进 package/ 会直接 `No rule to make target '../../luci.mk'`。
#
# ── 调用时机 ────────────────────────────────────────────────────
# 必须在 `feeds update` 之后（此时 feeds/ 目录树已就位）、
# `feeds install` 之前。跑完本脚本后必须执行 `feeds update -i -a`
# 重建索引 —— install 读的是 feeds/<name>.index，不重建就看不到新包。
# 用 -i 而不是普通 update：-i 只重建索引、不执行 git pull，不会碰到刚拷进去的文件。
#
# 环境变量：
#   OPENWRT_DIR     OpenWrt 源码目录（必需）
#   IMM_REF         ImmortalWrt 的分支，默认 master
#   IMM_PACKAGES    immortalwrt/packages 仓库地址
#   IMM_LUCI        immortalwrt/luci 仓库地址
#
set -euo pipefail

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
IMM_REF="${IMM_REF:-master}"
IMM_PACKAGES="${IMM_PACKAGES:-https://github.com/immortalwrt/packages.git}"
IMM_LUCI="${IMM_LUCI:-https://github.com/immortalwrt/luci.git}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -d "$OPENWRT_DIR" ]] || die "OPENWRT_DIR 不是有效目录：$OPENWRT_DIR"

cd "$OPENWRT_DIR"

# packages feed 需要的子包目录
PKG_PATHS=(net/ddns-go net/msd_lite)
# luci feed 需要的子包目录
LUCI_PATHS=(applications/luci-app-ddns-go applications/luci-app-msd_lite)

[[ -d feeds/packages ]] || die "feeds/packages 不存在，请先跑 ./scripts/feeds update -a"
[[ -d feeds/luci ]]     || die "feeds/luci 不存在，请先跑 ./scripts/feeds update -a"

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
  log "  落位 $feed_dir/$rel"
}

sparse_clone "$IMM_PACKAGES" "$WORK/packages" "${PKG_PATHS[@]}"
sparse_clone "$IMM_LUCI"     "$WORK/luci"     "${LUCI_PATHS[@]}"

for rel in "${PKG_PATHS[@]}";  do place "$WORK/packages" feeds/packages "$rel"; done
for rel in "${LUCI_PATHS[@]}"; do place "$WORK/luci"     feeds/luci     "$rel"; done

# ── 关键前置依赖自检 ────────────────────────────────────────────
# ddns-go 是 Go 包，构建时要 include 官方 feed 的 golang 框架。
# 它不在就说明 packages feed 不完整，早点失败比编到一半炸好。
[[ -f feeds/packages/lang/golang/golang-package.mk ]] \
  || die "缺少 feeds/packages/lang/golang/golang-package.mk，ddns-go 无法构建"
[[ -f feeds/luci/luci.mk ]] \
  || die "缺少 feeds/luci/luci.mk，luci-app-* 无法构建"

log "引入完成：ddns-go / msd_lite（含各自的 LuCI 界面）"
warn "别忘了接着跑：./scripts/feeds update -i -a   # 重建索引，install 才看得到这些包"
