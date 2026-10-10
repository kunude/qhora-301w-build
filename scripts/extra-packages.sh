#!/usr/bin/env bash
#
# 引入 OpenWrt 官方 feed 之外的包。现在分三类，处理方式按"上游有没有可指的
# 源码仓库 / 配方是不是我们自己的"来区分：
#
# ── ① ddns-go / msd_lite / autocore → 本仓库自带配方 ─────────────
# 配方在 packages/<分类>/<包>/ 下：
#   packages/net/ddns-go、packages/net/msd_lite
#     PKG_SOURCE 直接指向上游源码仓库（jeessy2/ddns-go、rozhuk-im/msd_lite），
#     版本与 hash 由 scripts/resolve-versions.sh 在构建时解析后注入。
#   packages/emortal/autocore
#     纯脚本包（无 PKG_SOURCE、Build/Compile 为空），抄自 ImmortalWrt 主源码树，
#     提供 /sbin/tempinfo、/sbin/cpuinfo —— ImmortalWrt 首页温度那一行背后的东西。
#     它不属于任何 feed，ImmortalWrt 主仓库又太大不值得整库拉，所以自带一份。
#
# 为什么不再从 ImmortalWrt 取这两个包：ImmortalWrt 的配方把版本**写死**了
# （例如 PKG_VERSION:=6.17.6 配对应 PKG_HASH），上游发了新版要等它 bump
# 才跟得上；而 OpenWrt 官方 packages feed 里干脆没有这两个包
# （实测 net/ddns-go 与 net/msd_lite 都是 404）。既然两边都不合适，
# 就自己写配方直接引用上游源码。
#
# ── ② luci-app-ddns-go / luci-app-msd_lite（纯前端）→ ImmortalWrt ─
# 它们只是页面（JS / ucode / 翻译），没有独立的"上游源码仓库"可指，抄一份到
# 本仓库只会让上游的界面更新跟不进来。它们通过
# LUCI_DEPENDS:=+ddns-go / +msd_lite 依赖上面那两个包，包名没变，照样接得上。
#
# ── ③ passwall2（项目 + 依赖组件）→ 上游自己的仓库 ───────────────
# 注意仓库归属：passwall 项目已从个人账号 xiaorouji 迁到
# **Openwrt-Passwall** 组织（xiaorouji/... 现在返回 404）。三个仓库各司其职：
#   openwrt-passwall2          只含 luci-app-passwall2（界面 + 运行脚本）
#   openwrt-passwall-packages  17 个依赖组件的配方（xray-core / sing-box / …）
#   openwrt-passwall           只含 v1 的 luci-app-passwall，本仓库不用
#
# 为什么不自己写 passwall 的配方（像 ① 那样）：这些组件的配方和上游版本是
# **同步维护**的 —— 上游 bump 版本时 PKG_VERSION / PKG_HASH / 编译标签是一起改的，
# 分开抄反而容易对不上。而且它们没有"滞后"问题（不像 ImmortalWrt 抄 ddns-go
# 会慢半拍），所以这里只要每次构建都取最新的 main 就行。
# 组件清单**不写死**：上游加新组件会自动被带上（见下面的 find）。
#
# ⚠️ 有 4 个组件与官方 feed 同名：microsocks / sing-box / v2ray-geodata / xray-core。
#    落位时是**故意覆盖**官方那份 —— passwall 上游的 CI 也把 passwall feed 排在
#    feeds.conf 最前面，效果一样（同名时前者胜）。其余 13 个官方 feed 里没有，
#    实测 openwrt/packages 的 net/ 与 lang/ 下均为 404。
#
# ⚠️ shadowsocks-rust / shadow-tls 需要 **Rust 工具链**（它们的配方写着
#    PKG_BUILD_DEPENDS:=rust/host），要从源码编 rustc + LLVM，构建时间显著增长。
#    所以 configs/common.config 里把两个 INCLUDE_Shadowsocks_Rust_* 都关掉了；
#    要 ss-rust 就在 LuCI 的「组件更新」里在线下载（passwall2 自带这个入口，
#    见 root/usr/share/passwall2/app.sh 里的 ss-rust 分支）。
#    配方仍然落位，只是不选 —— 哪天想编，把那个开关改成 y 即可。
#
# ── 为什么必须放进 feed 目录，而不是 package/ ───────────────────
# 这些包的 Makefile 里是相对路径：
#   applications/luci-app-*/Makefile  →  include ../../luci.mk
#   net/ddns-go/Makefile              →  include ../../lang/golang/golang-package.mk
# 只有放在 <feed根>/<二级目录>/<包>/ 这个位置才能解析得到。
# 放进 package/ 会直接 `No rule to make target '../../luci.mk'`。
# （passwall 的配方用的是**绝对路径** $(TOPDIR)/feeds/... 或 $(INCLUDE_DIR)/…，
#   放哪都能解析，但仍然放进 feed 目录 —— 否则 feeds install 扫不到它。）
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
#   PW_REF          passwall 三个仓库的分支，默认 main
#   PW_APP_REPO     openwrt-passwall2 仓库地址
#   PW_PKGS_REPO    openwrt-passwall-packages 仓库地址
#
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
BUILDER_DIR="${BUILDER_DIR:?BUILDER_DIR 未设置}"
IMM_REF="${IMM_REF:-master}"
IMM_LUCI="${IMM_LUCI:-https://github.com/immortalwrt/luci.git}"
PW_REF="${PW_REF:-main}"
PW_APP_REPO="${PW_APP_REPO:-https://github.com/Openwrt-Passwall/openwrt-passwall2.git}"
PW_PKGS_REPO="${PW_PKGS_REPO:-https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# 注解走 fd3（原始终端）。prepare-build.sh 顶部把原始终端另存成了 fd3，
# 子进程会继承；单独运行时没有 fd3，退回 fd1。理由见 prepare-build.sh 的说明。
if { : >&3; } 2>/dev/null; then ANN_FD=3; else ANN_FD=1; fi
ann() { printf '%s\n' "$*" >&"$ANN_FD"; }

[[ -d "$OPENWRT_DIR" ]] || die "OPENWRT_DIR 不是有效目录：$OPENWRT_DIR"
[[ -d "$OPENWRT_DIR/feeds/packages" ]] || die "feeds/packages 不存在，请先跑 ./scripts/feeds update -a"
[[ -d "$OPENWRT_DIR/feeds/luci" ]]     || die "feeds/luci 不存在，请先跑 ./scripts/feeds update -a"

cd "$OPENWRT_DIR"

WORK="$(mktemp -d)"
# 清理失败不能拖垮整个构建步骤（例如 Windows/MSYS 下 rm 对 /tmp 路径的处理）。
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# 把 <克隆目录>/<源相对路径> 拷进 <feed目录>/<目标相对路径>。
# 源和目标**分开传**：不同仓库的目录层级不一样 ——
#   immortalwrt/luci            包在 applications/<包>/，喂进去正好也是这个层级
#   Openwrt-Passwall/openwrt-passwall2   包直接在根目录 <包>/
#   Openwrt-Passwall/openwrt-passwall-packages  同样是根目录 <包>/
# 目标目录同名时先删 —— 这是有意的（passwall 组件要覆盖官方 feed 的同名包）。
place() {
  local src_root="$1" feed_dir="$2" src_rel="$3" dst_rel="$4" label="$5"

  [[ -f "$src_root/$src_rel/Makefile" ]] \
    || die "上游没有 $src_rel/Makefile（结构可能变了），检查 $src_root"
  [[ -d "$feed_dir" ]] || die "目标 feed 目录不存在：$feed_dir"

  rm -rf "${feed_dir:?}/$dst_rel"
  mkdir -p "$feed_dir/$(dirname "$dst_rel")"
  cp -a "$src_root/$src_rel" "$feed_dir/$dst_rel"
  log "  落位（$label）$feed_dir/$dst_rel"
}

# ══════════════════════════════════════════════════════════════
# ① 本仓库自带的配方：packages/<分类>/<包>/ → feeds/packages/<分类>/<包>/
# ══════════════════════════════════════════════════════════════
OWN_ROOT="$BUILDER_DIR/packages"
[[ -d "$OWN_ROOT" ]] || die "本仓库里没有 packages/ 目录：$OWN_ROOT"

own_count=0
while IFS= read -r -d '' mk; do
  rel="${mk#"$OWN_ROOT"/}"
  rel="${rel%/Makefile}"
  [[ -n "$rel" ]] || die "解析自带配方相对路径失败：$mk"
  place "$OWN_ROOT" feeds/packages "$rel" "$rel" "本仓库自带"
  own_count=$((own_count + 1))
done < <(find "$OWN_ROOT" -type f -name Makefile -print0 | sort -z)

((own_count > 0)) || die "$OWN_ROOT 下没找到任何 Makefile，自带配方不见了？"
log "自带配方落位完成，共 $own_count 个"

# ══════════════════════════════════════════════════════════════
# ② ImmortalWrt 的纯前端包（只取 luci 那一半）
# ══════════════════════════════════════════════════════════════
LUCI_PATHS=(applications/luci-app-ddns-go applications/luci-app-msd_lite)

# 稀疏检出：只下载指定目录的 blob，仓库其余部分不落地。
# immortalwrt/luci 很大，所以这里值得用稀疏；passwall 那两个仓库很小，
# 用后面的 clone_shallow 就够，不必把稀疏那套脆弱性引进来。
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

sparse_clone "$IMM_LUCI" "$WORK/luci" "${LUCI_PATHS[@]}"
for rel in "${LUCI_PATHS[@]}"; do place "$WORK/luci" feeds/luci "$rel" "$rel" "ImmortalWrt 前端"; done

# ══════════════════════════════════════════════════════════════
# ③ passwall2：项目仓库 + 依赖组件仓库
# ══════════════════════════════════════════════════════════════
# 简单浅克隆就够：openwrt-passwall2 ~0.5MB、openwrt-passwall-packages ~3MB。
# 不用稀疏检出 —— 一是没必要，二是 sparse-checkout 在个别环境里会静默失败。
clone_shallow() {
  local repo="$1" dest="$2" label="$3"

  log "浅克隆 $label（$PW_REF）"
  rm -rf "$dest"
  git clone -q --depth=1 --branch "$PW_REF" "$repo" "$dest" 2>/dev/null \
    || die "克隆 $repo 失败（分支 $PW_REF）"
  [[ -d "$dest/.git" ]] || die "$repo 克隆后没有 .git，检出不完整"
}

# ③-a 界面：openwrt-passwall2 的 <根>/luci-app-passwall2 → feeds/luci/applications/
#     注意源在仓库根目录、目标要落到 applications/ 下，两边层级不同。
clone_shallow "$PW_APP_REPO" "$WORK/passwall2" "openwrt-passwall2"
place "$WORK/passwall2" feeds/luci luci-app-passwall2 applications/luci-app-passwall2 "passwall2"

# ③-b 依赖组件：openwrt-passwall-packages 顶层每个含 Makefile 的目录都是一个包。
# 清单**不写死** —— 上游加新组件时这里自动跟上，也不用改这个脚本。
clone_shallow "$PW_PKGS_REPO" "$WORK/passwall-packages" "openwrt-passwall-packages"

pw_rels=()
while IFS= read -r dir; do
  rel="$(basename "$dir")"
  [[ "$rel" == .* ]] && continue          # 跳过 .github / .gitattributes 之类
  [[ -f "$dir/Makefile" ]] || continue    # 只认带配方的目录
  place "$WORK/passwall-packages" feeds/packages/net "$rel" "$rel" "passwall 组件"
  pw_rels+=("$rel")
done < <(find "$WORK/passwall-packages" -mindepth 1 -maxdepth 1 -type d -print | sort)

((${#pw_rels[@]} > 0)) || die "openwrt-passwall-packages 里一个包都没找到，上游结构变了？"
# 两个核心组件必须在 —— 缺了说明这份检出不对，早点失败比编到一半炸好。
for must in xray-core sing-box chinadns-ng; do
  [[ -f "feeds/packages/net/$must/Makefile" ]] \
    || die "passwall 组件 $must 没落位，检查 $PW_PKGS_REPO 的 $PW_REF 分支"
done
log "passwall 组件落位完成，共 ${#pw_rels[@]} 个：${pw_rels[*]}"

# ── 把这一轮引入的版本发成公开注解 ──────────────────────────────
# 和 resolve-versions.sh 的思路一致：作业日志要登录才能看，注解不用。
# 这些版本**不是**我们注入的，而是上游仓库当前 main 里的值 —— 所以这条注解
# 同时是"上游最近一次更新有没有被这轮构建吃到"的凭证。
# 不是所有组件都会被编进固件（只有 luci-app-passwall2 选中/依赖的那些），
# 这里列的是"本仓库引入的配方版本"。
#
# 取版本字段时不能只认 PKG_VERSION：少数组件把版本放在别的变量里
# （v2ray-geodata 用 GEOIP_VER，配方里根本没有 PKG_VERSION）。
# 取不到就如实显示 "-"，不编造。
pkg_ver_of() {
  local mk="$1" v=""
  v="$({ sed -n 's/^PKG_VERSION:=\s*//p'        "$mk" 2>/dev/null || true; } | head -n1)"
  [[ -n "$v" ]] || v="$({ sed -n 's/^PKG_SOURCE_DATE:=\s*//p'   "$mk" 2>/dev/null || true; } | head -n1)"
  [[ -n "$v" ]] || v="$({ sed -n 's/^[A-Z0-9_]*_VER:=\s*//p'    "$mk" 2>/dev/null || true; } | head -n1)"
  [[ -n "$v" ]] || v="-"
  printf '%s' "$v"
}

app_ver="$(pkg_ver_of feeds/luci/applications/luci-app-passwall2/Makefile)"
app_rel="$(sed -n 's/^PKG_RELEASE:=\s*//p' feeds/luci/applications/luci-app-passwall2/Makefile 2>/dev/null | head -n1)"
ann "::notice title=passwall2 项目版本::luci-app-passwall2=${app_ver:-未知}${app_rel:+-${app_rel}}（取自 $PW_APP_REPO@$PW_REF）"

pw_summary=""
for rel in "${pw_rels[@]}"; do
  pw_summary="${pw_summary}${rel}=$(pkg_ver_of "feeds/packages/net/$rel/Makefile")  "
done
ann "::notice title=passwall 组件版本（引自上游 $PW_REF）::${pw_summary}"

# ══════════════════════════════════════════════════════════════
# 前置依赖自检
# ══════════════════════════════════════════════════════════════
# ddns-go 是 Go 包，构建时要 include 官方 feed 的 golang 框架。
# 它不在就说明 packages feed 不完整，早点失败比编到一半炸好。
[[ -f feeds/packages/lang/golang/golang-package.mk ]] \
  || die "缺少 feeds/packages/lang/golang/golang-package.mk，ddns-go / xray-core / sing-box 等 Go 包无法构建"
[[ -f feeds/luci/luci.mk ]] \
  || die "缺少 feeds/luci/luci.mk，luci-app-* 无法构建"

log "引入完成："
log "  · 自带配方        ddns-go / msd_lite / autocore"
log "  · ImmortalWrt 前端 luci-app-{ddns-go,msd_lite}"
log "  · passwall2       luci-app-passwall2 + ${#pw_rels[@]} 个依赖组件"
warn "别忘了接着跑：./scripts/feeds update -i -a   # 重建索引，install 才看得到这些包"
