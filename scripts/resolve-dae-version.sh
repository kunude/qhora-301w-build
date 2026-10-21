#!/usr/bin/env bash
#
# 把 dae 换成上游**最新 release**（或指定版本），在构建时注入 feeds 的 dae 配方。
#
# ── 为什么需要这一步 ────────────────────────────────────────────
# dae 的配方在 immortalwrt/packages（feeds/packages/net/dae），版本是**写死的**：
#
#     PKG_VERSION:=2.0.0
#     PKG_SOURCE_URL:=.../releases/download/v$(PKG_VERSION)/dae-full-src.zip?
#
# feed 的维护者不是每次上游发版都跟着 bump，所以「拉最新 feeds」≠「编最新 dae」
# （2026-10-22 实测：feed 还是 2.0.0，上游已经 2.1.1）。这个脚本在 prepare 阶段
# 解析上游 latest tag、把源码包下到 dl/ 并算出 sha256、再写回配方 —— 于是每次
# 构建用的都是当时的最新版，同时 hash 仍然是构建期算的、下载时会被校验。
#
# ── 为什么改的是 feed 里的文件而不是自己复制一份配方 ─────────────
# 复制一份到 package/ 会和 feeds install 出来的 package/feeds/packages/dae 撞名，
# OpenWrt 对同名包的处理是「先扫到哪个用哪个」，结果取决于目录扫描顺序 ——
# 这种不确定性比版本落后更难查。所以这里**原地改** feeds 里那份：只动
# PKG_VERSION / PKG_HASH / PKG_RELEASE 三行，其余（bpf-headers、GO_PKG_TAGS 等）
# 继续跟随 feed 维护者的判断。
#
# ── 失败时 ──────────────────────────────────────────────────────
#   · 没指定 DAE_VERSION（跟随最新）：只 warn + 保留 feed 里的版本，退出 0。
#     GitHub API 抖动/限流不该让一轮两小时的编译白跑。
#   · 指定了 DAE_VERSION（钉死）：**硬失败**。用户点名要 2.1.0 却静默编成 2.0.0，
#     比直接报错更糟。
#
# ── 三个必须知道的前提（改这个脚本时绕开）──────────────────────
# ① 源码包是 zip，不是 tar。配方里 UNZIP_CMD 把它解到 PKG_BUILD_DIR 根下，
#    所以没有顶层目录可校验 —— 只在解包清单里确认 go.mod / cmd/ 存在。
# ② dae-full-src.zip 已经**内置了两个子模块**（control/kern/headers、
#    trace/kern/headers 各 22 个 .h）。GitHub 的源码 zip 默认不含子模块，但
#    dae 的 release 产物是自带 hack/ 脚本打进去的，所以别自作聪明去 clone
#    dae_bpf_headers。
# ③ PKG_SOURCE_URL 末尾那个 `?` 是给 download.pl 拼名用的，我们直接下载时
#    不能带 —— 带上不影响内容，但会让 curl 的 -o 名字和缓存判断变乱。
#
# ── 环境变量 ────────────────────────────────────────────────────
#   OPENWRT_DIR   必需，OpenWrt 源码目录（feeds/ 与 dl/ 都在它下面）
#   GH_TOKEN      可选，有就用上，避免撞 GitHub 未认证限额（60 次/小时）
#   DAE_VERSION   可选，钉死版本，例如 2.1.1 或 v2.1.1（填了就不查 API）
#
# ── 输出策略 ────────────────────────────────────────────────────
# 与 resolve-versions.sh 相同：普通日志 → fd1（落进 prepare 日志），
# 注解 → fd3（原始终端，才能变成公开可读的 check-run annotation）。
#
# SPDX-License-Identifier: GPL-2.0-only
set -Eeuo pipefail

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
GH_TOKEN="${GH_TOKEN:-}"
DAE_VERSION="${DAE_VERSION:-}"

FEEDS_NET="$OPENWRT_DIR/feeds/packages/net"
DAE_MAKE="$FEEDS_NET/dae/Makefile"
DL_DIR="$OPENWRT_DIR/dl"
STAMP="$OPENWRT_DIR/.dae-resolved"

if { : >&3; } 2>/dev/null; then ANN_FD=3; else ANN_FD=1; fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ann()  { printf '%s\n' "$*" >&"$ANN_FD"; }

first_line() { printf '%s' "${1%%$'\n'*}"; }

json_field() {
  local json="$1" field="$2" hits
  hits=$(printf '%s' "$json" | grep -oE "\"${field}\":\"[^\"]*\"" 2>/dev/null) || hits=""
  [[ -n "$hits" ]] || return 1
  first_line "$hits" | cut -d'"' -f4
}

# 带重试的 JSON 拉取（与 resolve-versions.sh 同一套写法，理由见那边的注释）。
gh_json() {
  local url="$1" tmp i
  tmp="$(mktemp)" || return 1
  for i in 1 2 3; do
    if [[ -n "$GH_TOKEN" ]]; then
      curl -fsSL -m 45 --connect-timeout 15 -o "$tmp" \
        -H "Authorization: Bearer $GH_TOKEN" \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: qhora-301w-build' "$url" 2>/dev/null || true
    else
      curl -fsSL -m 45 --connect-timeout 15 -o "$tmp" \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: qhora-301w-build' "$url" 2>/dev/null || true
    fi
    if [[ -s "$tmp" ]]; then cat "$tmp"; rm -f "$tmp"; return 0; fi
    sleep $((i * 3))
  done
  rm -f "$tmp"
  return 1
}

# 把 <file> 里以 "<var>:=" 开头的行整行替换掉；变量名对不上就失败。
inject() {
  local f="$1" var="$2" val="$3"
  [[ -f "$f" ]] || return 1
  grep -qE "^${var}:=" "$f" || return 1
  sed -i "s|^${var}:=.*|${var}:=${val}|" "$f"
}

# 下载到 dl/ 并按 OpenWrt 的命名（dae-<ver>.zip）放好，打印 sha256。
fetch_and_hash() {
  local url="$1" dest="$2"
  rm -f "$DL_DIR/$dest"
  curl -fsSL -m 600 --retry 3 --connect-timeout 15 -o "$DL_DIR/$dest" "$url" || return 1
  [[ -s "$DL_DIR/$dest" ]] || return 1
  sha256sum "$DL_DIR/$dest" | awk '{print $1}' | tr -d '\\'
}

# 上游 go.mod 的 go 指令 vs feed 里 golang/host 的版本。
# 不判定成败（OpenWrt 会自己报 "go.mod requires go >= x"），只提前把话说清楚，
# 免得看 40 分钟日志才发现是工具链太旧。
check_go_floor() {
  local zip="$1"
  local req tool tok
  req=$(unzip -p "$zip" go.mod 2>/dev/null | sed -n 's/^go[[:space:]]\{1,\}//p') || req=""
  req=$(first_line "${req:-}")
  tok=$(sed -n 's/^PKG_VERSION:=[[:space:]]*//p' \
        "$OPENWRT_DIR/feeds/packages/lang/golang/golang/Makefile" 2>/dev/null) || tok=""
  tok=$(first_line "${tok:-}")
  [[ -n "$req" ]] || { warn "没能从 go.mod 里读出 go 指令"; return 0; }
  printf '           go.mod 要求 go >= %s；feed 的 golang/host = %s\n' "$req" "${tok:-未知}"
  if [[ -n "$tok" ]] && [[ "$(printf '%s\n%s\n' "$req" "$tok" | sort -V | tail -1)" == "$req" ]] \
     && [[ "$req" != "$tok" ]]; then
    warn "go.mod 要求 ${req}，而 feed 的 golang/host 是 ${tok} —— 如果前者更大，编译会直接失败；此时应等 feeds 跟进或钉回旧版本"
  fi
}

[[ -f "$DAE_MAKE" ]] || die "找不到 $DAE_MAKE —— feeds install 还没跑，或这条线没装 dae"
mkdir -p "$DL_DIR"

# ── 1. 定版本 ───────────────────────────────────────────────────
strict=0
if [[ -n "$DAE_VERSION" ]]; then
  ver="${DAE_VERSION#v}"
  tag="v${ver}"
  strict=1
  log "dae：使用指定版本 ${ver}（不查 API）"
else
  if json=$(gh_json "https://api.github.com/repos/daeuniverse/dae/releases/latest"); then
    tag=$(json_field "$json" tag_name) || tag=""
    ver="${tag#v}"
  else
    tag=""
    ver=""
  fi
  if [[ -z "$ver" ]]; then
    warn "查不到 dae 上游最新 release（API 限流/网络问题），保留 feed 里的版本"
    exit 0
  fi
  log "dae：上游最新 tag = ${tag}"
fi

[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "解析出的版本号不像 semver：'${ver}'（tag=${tag:-空}）"

cur=$(sed -n 's/^PKG_VERSION:=[[:space:]]*//p' "$DAE_MAKE" | head -n1)
log "dae：feed 里当前版本 = ${cur:-未知}，目标 = ${ver}"

# ── 2. 下载 + 校验 + 算 hash ────────────────────────────────────
file="dae-${ver}.zip"
url="https://github.com/daeuniverse/dae/releases/download/${tag}/dae-full-src.zip"

if ! hash=$(fetch_and_hash "$url" "$file"); then
  if [[ "$strict" -eq 1 ]]; then
    die "下载 ${url} 失败 —— 指定的版本 ${ver} 可能不存在"
  fi
  warn "下载 ${url} 失败，保留 feed 里的版本 ${cur:-未知}"
  exit 0
fi
[[ ${#hash} -eq 64 ]] || die "sha256 长度异常（${#hash}）：$hash"

listing=$(unzip -l "$DL_DIR/$file" 2>/dev/null) || listing=""
if ! printf '%s' "$listing" | grep -qE '[[:space:]](\./)?go\.mod$'; then
  if [[ "$strict" -eq 1 ]]; then
    die "${file} 里没有 go.mod —— 下回来的不是 dae 的源码包（可能是错误页）"
  fi
  warn "${file} 里没有 go.mod，放弃注入，保留 feed 版本"
  exit 0
fi
printf '%s' "$listing" | grep -qE '[[:space:]](\./)?cmd/' \
  || warn "${file} 里没有 cmd/ 目录（不致命，但和以往的结构不一样）"

check_go_floor "$DL_DIR/$file"

# ── 3. 写回配方 ─────────────────────────────────────────────────
inject "$DAE_MAKE" PKG_VERSION "$ver"  || die "注入 PKG_VERSION 失败（配方里没有这一行？）"
inject "$DAE_MAKE" PKG_HASH    "$hash" || die "注入 PKG_HASH 失败"
inject "$DAE_MAKE" PKG_RELEASE 1       || warn "配方里没有 PKG_RELEASE，跳过"

grep -q 'v\$(PKG_VERSION)' "$DAE_MAKE" \
  || warn "配方里的 PKG_SOURCE_URL 不含 v\$(PKG_VERSION) —— 版本换了但下载地址可能没跟着换，检查一下"

now=$(sed -n 's/^PKG_VERSION:=[[:space:]]*//p' "$DAE_MAKE" | head -n1)
[[ "$now" == "$ver" ]] || die "写回后 PKG_VERSION 是 '${now}'，期望 '${ver}'"

# 给产物校验那一步用（它不重新解析，直接读这个文件）
{
  printf 'ver=%s\n'  "$ver"
  printf 'hash=%s\n' "$hash"
  printf 'file=%s\n' "$file"
} >"$STAMP"

log "dae 配方已更新：${cur:-?} -> ${ver}"
printf '  sha256=%s\n  源码包=%s（已放进 dl/，make download 会直接复用）\n' "$hash" "$file"
ann "::notice title=dae 跟随上游最新版::${ver}（feed 原为 ${cur:-未知}，sha256 ${hash:0:8}…）"
