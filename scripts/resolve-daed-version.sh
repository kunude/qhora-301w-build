#!/usr/bin/env bash
#
# 把 feeds 里的 daed 换成「指定版本（默认 2.1.1）的官方预编译二进制」。
#
# ── 为什么是预编译而不是源码 ────────────────────────────────────
# daed 2.x 把仓库拆成了 pnpm workspace（apps/web）+ wing 子模块，**不再发布
# web.zip**。feed 里那份配方（1.27.0）正是靠 web.zip 把前端塞进
# wing/webrender/web 再 go:embed 的 —— 换到 2.x 后：
#   · codeload 的源码包不含 wing/（子模块），编不了；
#   · 官方 daed-full-src.zip（220MB）里也没有 dist，前端仍要 pnpm 现编；
#   · OpenWrt 构建树里没有 node/pnpm。
# 三条路都堵着，而上游 release 自带 daed-linux-arm64.zip（静态、stripped、
# 内含已编译前端），因此这条测试线直接用它 —— 与 dae 线「预编译二进制」同一思路。
#
# ── 它改的是什么 ────────────────────────────────────────────────
# 只覆盖一个文件：feeds/packages/net/daed/Makefile（用 scripts/daed-prebuilt.mk
# 渲染）。同一目录下的 files/（daed.init、daed.config）保持 feed 原样 ——
# init 脚本才是决定监听地址 / 数据库位置的地方，没必要自己维护一份。
# feeds update 会把这行改动覆盖回去，所以每次构建都要重新渲染（本脚本负责）。
#
# ── 失败时 ──────────────────────────────────────────────────────
#   · 没指定 DAED_VERSION（默认 2.1.1）：下载失败只 warn，保留 feed 原配方。
#   · 指定了 DAED_VERSION：硬失败（点名要的版本拿不到，静默编成别的更糟）。
#
# ── 环境变量 ────────────────────────────────────────────────────
#   OPENWRT_DIR    必需
#   BUILDER_DIR    必需（找 scripts/daed-prebuilt.mk）
#   GH_TOKEN       可选（只有 DAED_VERSION=latest 时才用得上）
#   DAED_VERSION   可选，默认 2.1.1；写 latest 则查 releases/latest
#
# SPDX-License-Identifier: GPL-2.0-only
set -Eeuo pipefail

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
BUILDER_DIR="${BUILDER_DIR:?BUILDER_DIR 未设置}"
GH_TOKEN="${GH_TOKEN:-}"
DAED_VERSION="${DAED_VERSION:-2.1.1}"

DAE_PKG_DIR="$OPENWRT_DIR/feeds/packages/net/daed"
DAE_MAKE="$DAE_PKG_DIR/Makefile"
TPL="$BUILDER_DIR/scripts/daed-prebuilt.mk"
DL_DIR="$OPENWRT_DIR/dl"
STAMP="$OPENWRT_DIR/.daed-resolved"

if { : >&3; } 2>/dev/null; then ANN_FD=3; else ANN_FD=1; fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ann()  { printf '%s\n' "$*" >&"$ANN_FD"; }

[[ -f "$TPL" ]] || die "找不到模板 $TPL"
[[ -d "$DAE_PKG_DIR" ]] || die "找不到 $DAE_PKG_DIR —— feeds install 还没跑？"
mkdir -p "$DL_DIR"

# ── 1. 定版本 ───────────────────────────────────────────────────
strict=1
if [[ "$DAED_VERSION" == "latest" ]]; then
  strict=0
  tmp="$(mktemp)"
  if curl -fsSL -m 45 -o "$tmp" \
       -H "Authorization: Bearer ${GH_TOKEN:-none}" \
       -H 'Accept: application/vnd.github+json' \
       -H 'User-Agent: qhora-301w-build' \
       "https://api.github.com/repos/daeuniverse/daed/releases/latest" 2>/dev/null \
     && [[ -s "$tmp" ]]; then
    tag=$(grep -oE '"tag_name":"[^"]*"' "$tmp" | head -1 | cut -d'"' -f4)
  else
    tag=""
  fi
  rm -f "$tmp"
  if [[ -z "${tag:-}" ]]; then
    warn "查不到 daed 上游最新 release，保留 feed 原配方（1.27.0 源码版）"
    exit 0
  fi
  ver="${tag#v}"
  log "daed：上游最新 tag = ${tag}"
else
  ver="${DAED_VERSION#v}"
  log "daed：使用指定版本 ${ver}（官方预编译二进制）"
fi

[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "版本号不像 semver：'${ver}'"

# ── 2. 下载 + 校验 ──────────────────────────────────────────────
file="daed-bin-${ver}.zip"
url="https://github.com/daeuniverse/daed/releases/download/v${ver}/daed-linux-arm64.zip"

if [[ ! -s "$DL_DIR/$file" ]]; then
  log "下载 $url"
  if ! curl -fsSL -m 900 --retry 3 --connect-timeout 15 -o "$DL_DIR/$file" "$url"; then
    rm -f "$DL_DIR/$file"
    if [[ "$strict" -eq 1 ]]; then
      die "下载失败：$url —— 指定的版本 ${ver} 可能不存在，或上游改了资产名"
    fi
    warn "下载失败，保留 feed 原配方"
    exit 0
  fi
fi

hash=$(sha256sum "$DL_DIR/$file" | awk '{print $1}' | tr -d '\\')
[[ ${#hash} -eq 64 ]] || die "sha256 长度异常（${#hash}）"

# 资产结构变了就早点失败，别等到编译阶段才报"找不到文件"
listing=$(unzip -l "$DL_DIR/$file" 2>/dev/null) || listing=""
printf '%s' "$listing" | grep -qE 'daed-linux-arm64/daed-linux-arm64$' \
  || die "$file 里没有 daed-linux-arm64/daed-linux-arm64 —— 上游换了打包结构，先去看一眼再改模板"

# ── 3. 渲染配方 ─────────────────────────────────────────────────
sed -e "s|@VER@|${ver}|g" -e "s|@HASH@|${hash}|g" "$TPL" >"$DAE_MAKE.tmp"
mv "$DAE_MAKE.tmp" "$DAE_MAKE"

grep -qx "PKG_VERSION:=${ver}" "$DAE_MAKE" \
  || die "渲染后 PKG_VERSION 不是 ${ver}，检查模板"
grep -q "$hash" "$DAE_MAKE" || die "渲染后 HASH 没写进去"
if grep -qE '@[A-Z_]+@' "$DAE_MAKE"; then
  die "渲染后还有未替换的占位符：$(grep -oE '@[A-Z_]+@' "$DAE_MAKE" | sort -u | tr '\n' ' ')"
fi

# 包必须**真的被注册**。少了 include $(INCLUDE_DIR)/package.mk 时 BuildPackage 未定义，
# $(eval $(call BuildPackage,...)) 静默展开成空 —— 包既不报错也不存在，扫描阶段发现不了，
# make defconfig 只会"丢弃配置请求的符号"（2026-10-25 的 run 就是这么失败的）。
grep -qx 'include $(INCLUDE_DIR)/package.mk' "$DAE_MAKE" \
  || die "渲染后没有 include \$(INCLUDE_DIR)/package.mk —— 包不会被注册（BuildPackage 未定义），检查模板"
for p in daed daed-geoip daed-geosite; do
  grep -qx "define Package/${p}" "$DAE_MAKE" || die "配方里缺 define Package/${p}"
  grep -qF "\$(eval \$(call BuildPackage,${p}))" "$DAE_MAKE" \
    || die "配方里缺 \$(eval \$(call BuildPackage,${p}))"
done
# files/ 必须还在（init 与 UCI 默认配置来自 feed，不属于本模板）
for f in files/daed.init files/daed.config; do
  [[ -f "$DAE_PKG_DIR/$f" ]] || die "$DAE_PKG_DIR/$f 不见了 —— 上游把 init/config 挪走的话要改模板"
done

{
  printf 'ver=%s\n'  "$ver"
  printf 'hash=%s\n' "$hash"
  printf 'file=%s\n' "$file"
} >"$STAMP"

log "daed 配方已换成预编译版：v${ver}（sha256 ${hash:0:8}…）"
ann "::notice title=daed 预编译::v${ver}（官方 daed-linux-arm64.zip，sha256 ${hash:0:8}…）"
