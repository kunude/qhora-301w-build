#!/usr/bin/env bash
#
# 解析两个上游包的最新版本，注入到刚落位的自带配方里。
#
# ── 为什么需要这一步 ────────────────────────────────────────────
# packages/net/{ddns-go,msd_lite} 是本仓库自己的配方，PKG_SOURCE 直接指向上游
# 源码仓库。要让「上游一发新版，下次构建就自动是新的」，版本号和 hash 就不能
# 写死在配方里 —— 由这个脚本在构建时解析出来再写回去。
#
# ── 解析方式 ────────────────────────────────────────────────────
#   ddns-go  : GET /repos/jeessy2/ddns-go/releases/latest 取 tag
#              （用 releases/latest 而不是 /tags：它会自动跳过预发布版与草稿）
#              再读压缩包里 go.mod 的 module 行 —— 上游升到 v7 时 GO_PKG 要跟着变
#   msd_lite : GET /repos/rozhuk-im/msd_lite/commits/master 取 sha 与日期
#              （上游一个 tag 都没有，只能跟 master 的 HEAD）
# 两个都用 codeload 拉下压缩包、本地算 sha256 当作 PKG_HASH，顺带把包装进
# $OPENWRT_DIR/dl/ 让后面的 make download 复用 —— 也就顺带证明了
# 「我们算出来的 hash」就是「构建时会校验的那个 hash」。
#
# ── 失败时为什么**不**中断构建 ──────────────────────────────────
# 配方里写了兜底版本（当前可用的值）。GitHub API 抖动、限流、网络抽风都不该
# 让一轮两小时的编译白跑，所以这里只发 ::warning:: 注解、保持兜底值，并以 0 退出。
# 注入则是**按包原子**的：版本、ref/GO_PKG、hash 一起替换，绝不让「新版本配旧
# hash」这种半截状态落进文件（那会让下载阶段的 hash 校验直接失败）。
#
# ── 两个踩过的坑（改这个脚本时绕开）────────────────────────────
# ① GitHub API 返回的是**单行** JSON。所以解析字段不能用带行首锚点 ^ 的正则，
#    而且像 "sha" 这种字段在 tree / parents / files 里会重复出现，必须取**第一个**
#    （外层那个），不能贪心匹配到最后一个。
# ② `cmd | head -n1` 在 set -o pipefail 下会失败：head 读够一行就退出，cmd 收到
#    SIGPIPE（退出码 141），pipefail 把它当失败。取第一行一律用纯 bash 的
#    first_line()，需要截断的上游命令先把输出整体收进变量。
#
# ── 输出策略 ────────────────────────────────────────────────────
# 本脚本由 prepare-build.sh 调用，而父进程已经把 fd1 重定向进日志文件、
# 把原始终端另存为 fd3（见 prepare-build.sh 顶部）。所以：
#   · 普通日志 → fd1，落进日志文件，由工作流的「回放构建准备日志」那步打出来
#   · 注解    → fd3，直接到 runner，才能变成公开可读的 check-run annotation
# 单独运行时没有 fd3，退回 fd1（那时 fd1 就是终端，注解照样有效）。
#
# ── 环境变量 ────────────────────────────────────────────────────
#   OPENWRT_DIR       必需，OpenWrt 源码目录（feeds/ 与 dl/ 都在它下面）
#   GH_TOKEN          可选，有就用上，避免撞 GitHub 未认证限额（60 次/小时）
#   DDNS_GO_VERSION   可选，钉死 ddns-go 版本，例如 6.17.7（填了就不查 API）
#   MSD_LITE_SHA      可选，钉死 msd_lite 的 commit sha（填了就不查 API）
#
# SPDX-License-Identifier: GPL-2.0-only
set -Eeuo pipefail

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
GH_TOKEN="${GH_TOKEN:-}"
DDNS_GO_VERSION="${DDNS_GO_VERSION:-}"
MSD_LITE_SHA="${MSD_LITE_SHA:-}"

FEEDS_NET="$OPENWRT_DIR/feeds/packages/net"
DL_DIR="$OPENWRT_DIR/dl"
DDNS_MAKE="$FEEDS_NET/ddns-go/Makefile"
MSD_MAKE="$FEEDS_NET/msd_lite/Makefile"

if { : >&3; } 2>/dev/null; then ANN_FD=3; else ANN_FD=1; fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
# 注解走 fd3（原始终端），见文件头的说明。
ann()  { printf '%s\n' "$*" >&"$ANN_FD"; }

# 取字符串的第一行。纯 bash，不走管道 —— 理由见文件头坑 ②。
first_line() { printf '%s' "${1%%$'\n'*}"; }

mkdir -p "$DL_DIR"

# 从 JSON 里取某个字符串字段的**第一个**值。理由见文件头坑 ①。
# 匹配形如 "field":"value" 的片段（GitHub 的紧凑 JSON 冒号后无空格），
# 用 cut 按引号切：f1 空、f2 字段名、f3 冒号、f4 值。
json_field() {
  local json="$1" field="$2" hits
  hits=$(printf '%s' "$json" | grep -oE "\"${field}\":\"[^\"]*\"" 2>/dev/null) || hits=""
  [[ -n "$hits" ]] || return 1
  first_line "$hits" | cut -d'"' -f4
}

# 把 <file> 里以 "<var>:=" 开头的行整行替换掉。
# 变量名对不上就返回 1 —— 免得名字写错了却静默"成功"。
inject() {
  local f="$1" var="$2" val="$3"
  [[ -f "$f" ]] || return 1
  grep -qE "^${var}:=" "$f" || return 1
  sed -i "s|^${var}:=.*|${var}:=${val}|" "$f"
}

# 带重试的 JSON 拉取。有 token 就走 Authorization，免限额。
# 落临时文件而不是用命令替换的管道：MSYS 的 curl 往管道写较大的响应会报
# "client returned ERROR on write"（本地 Windows 才有的毛病），会白重试一轮。
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

# 下载到 dl/ 并按 OpenWrt 的命名放好，然后打印 sha256。
# 注意 URL 里的 ref 是**原始** ref（带 v 前缀的 tag / 完整 sha），不带配方里
# 那个 ? 后缀 —— 那个 ? 是留给 download.pl 拼 PKG_SOURCE 用的。
fetch_and_hash() {
  local url="$1" dest="$2"
  rm -f "$DL_DIR/$dest"
  curl -fsSL -m 600 --retry 3 --connect-timeout 15 -o "$DL_DIR/$dest" "$url" || return 1
  [[ -s "$DL_DIR/$dest" ]] || return 1
  # MinGW 的 sha256sum 会输出 "<hash> *<file>"，Linux 是 "<hash>  <file>"；
  # awk 取第一列后统一清掉可能出现的反斜杠前缀。
  sha256sum "$DL_DIR/$dest" | awk '{print $1}' | tr -d '\\'
}

# 压缩包顶层目录必须正好是 <期望值>/。include/unpack.mk 是解到 BUILD_DIR 下、
# 靠目录名对上 PKG_BUILD_DIR，命名规则一旦变了必须在这里失败回落兜底值，
# 而不是编到一半才报"找不到源码"。
check_topdir() {
  local file="$1" expect="$2" listing topdir
  # 先把清单整体收进变量：直接 `tar -tzf | head -n1` 会因为 pipefail 误判失败。
  listing=$(tar -tzf "$DL_DIR/$file" 2>/dev/null) || return 1
  topdir=$(first_line "$listing")
  if [[ "$topdir" != "$expect" ]]; then
    warn "压缩包顶层目录是 '$topdir'，期望 '$expect'"
    return 1
  fi
  printf '%s' "$topdir"
}

# ── ddns-go ─────────────────────────────────────────────────────
resolve_ddns_go() {
  local tag ver url file hash module topdir gomod

  if [[ -n "$DDNS_GO_VERSION" ]]; then
    ver="${DDNS_GO_VERSION#v}"
    tag="v${ver}"
    log "ddns-go：使用指定版本 ${ver}（不查 API）"
  else
    local json
    json=$(gh_json "https://api.github.com/repos/jeessy2/ddns-go/releases/latest") || return 1
    tag=$(json_field "$json" tag_name) || return 1
    ver="${tag#v}"
    log "ddns-go：上游最新 tag = ${tag}"
  fi
  [[ -n "$ver" ]] || return 1

  file="ddns-go-${ver}.tar.gz"
  url="https://codeload.github.com/jeessy2/ddns-go/tar.gz/${tag}"

  hash=$(fetch_and_hash "$url" "$file") || return 1
  [[ ${#hash} -eq 64 ]] || { warn "hash 长度异常（${#hash}）：$hash"; return 1; }
  topdir=$(check_topdir "$file" "ddns-go-${ver}/") || return 1

  # GO_PKG 必须跟着上游 go.mod 走，否则 Go 报模块路径不匹配。
  # go.mod 只有一行 module 指令，所以不需要再截第一行。
  gomod=$(tar -xzOf "$DL_DIR/$file" "${topdir}go.mod" 2>/dev/null) || return 1
  module=$(printf '%s\n' "$gomod" | sed -n 's/^module[[:space:]]\{1,\}//p')
  [[ -n "$module" ]] || { warn "没能从 go.mod 里读出 module 行"; return 1; }

  inject "$DDNS_MAKE" PKG_VERSION "$ver"    || return 1
  inject "$DDNS_MAKE" PKG_HASH    "$hash"   || return 1
  inject "$DDNS_MAKE" GO_PKG      "$module" || return 1

  printf '  ddns-go  version=%s\n' "$ver"
  printf '           hash=%s\n' "$hash"
  printf '           module=%s  压缩包=%s（顶层目录 %s）\n' "$module" "$file" "$topdir"
  ann "::notice title=ddns-go 跟随上游最新版::${ver}  module=${module}  sha256=${hash:0:8}…"
}

# ── msd_lite ────────────────────────────────────────────────────
resolve_msd_lite() {
  local sha date ver url file hash topdir json

  if [[ -n "$MSD_LITE_SHA" ]]; then
    sha="$MSD_LITE_SHA"
    log "msd_lite：使用指定 sha ${sha:0:12}…（不查 API）"
    date=""
    json=$(gh_json "https://api.github.com/repos/rozhuk-im/msd_lite/commits/$sha" 2>/dev/null) || json=""
    if [[ -n "$json" ]]; then
      date=$(json_field "$json" date) || date=""
      date="${date%%T*}"
    fi
  else
    json=$(gh_json "https://api.github.com/repos/rozhuk-im/msd_lite/commits/master") || return 1
    # json_field 取的是第一个 "sha" —— 也就是外层那个提交 sha。
    # tree / parents / files 里也有 "sha"，不能取错。
    sha=$(json_field "$json" sha) || return 1
    date=$(json_field "$json" date) || date=""
    date="${date%%T*}"
    log "msd_lite：master HEAD = ${sha:0:12}…  (${date:-日期未知})"
  fi
  [[ -n "$sha" ]] || return 1

  # apk 的版本号必须以数字开头，裸 sha 会被判非法；日期拿不到就用 0 垫。
  [[ -n "$date" ]] || date="0000-00-00"
  ver="${date//-/.}~${sha:0:7}"

  file="msd_lite-${ver}.tar.gz"
  url="https://codeload.github.com/rozhuk-im/msd_lite/tar.gz/${sha}"

  hash=$(fetch_and_hash "$url" "$file") || return 1
  [[ ${#hash} -eq 64 ]] || { warn "hash 长度异常（${#hash}）：$hash"; return 1; }
  # codeload 用 sha 作 ref 时顶层目录就是 msd_lite-<完整 sha>，
  # 与配方里显式指定的 PKG_BUILD_DIR($(BUILD_DIR)/msd_lite-$(MSD_LITE_REF)) 对应。
  topdir=$(check_topdir "$file" "msd_lite-${sha}/") || return 1

  inject "$MSD_MAKE" MSD_LITE_REF "$sha"  || return 1
  inject "$MSD_MAKE" PKG_VERSION  "$ver"  || return 1
  inject "$MSD_MAKE" PKG_HASH     "$hash" || return 1

  printf '  msd_lite version=%s\n' "$ver"
  printf '           hash=%s\n' "$hash"
  printf '           ref=%s  压缩包=%s（顶层目录 %s）\n' "$sha" "$file" "$topdir"
  ann "::notice title=msd_lite 跟随上游最新版::${ver}  ref=${sha:0:12}"
}

# ── 主流程 ──────────────────────────────────────────────────────
# 用 if 包住：bash 在 if 的条件位置会关掉 -e，函数内部靠显式 return 1 退出，
# 于是一个包解析失败不会连带把另一个也跳过。
log "解析两个上游包的最新版本"

ddns_state="未处理"
if [[ -f "$DDNS_MAKE" ]]; then
  if resolve_ddns_go; then
    ddns_state="已跟随上游最新版"
  else
    ddns_state="解析失败，沿用配方兜底值"
    warn "ddns-go 解析失败，沿用配方里的兜底值"
    ann "::warning title=ddns-go::解析上游最新版本失败，沿用配方里的兜底值"
  fi
else
  warn "找不到 $DDNS_MAKE，跳过 ddns-go（extra-packages.sh 没先跑？）"
fi

msd_state="未处理"
if [[ -f "$MSD_MAKE" ]]; then
  if resolve_msd_lite; then
    msd_state="已跟随上游最新版"
  else
    msd_state="解析失败，沿用配方兜底值"
    warn "msd_lite 解析失败，沿用配方里的兜底值"
    ann "::warning title=msd_lite::解析上游最新版本失败，沿用配方里的兜底值"
  fi
else
  warn "找不到 $MSD_MAKE，跳过 msd_lite（extra-packages.sh 没先跑？）"
fi

# 把最终生效的值打进日志与注解 —— 这是"这轮到底编了哪个版本"的唯一凭证。
# 作业日志要登录才能看，注解不用，所以两边都发。
printf '\n最终生效的包版本：\n'
for mk in "$DDNS_MAKE" "$MSD_MAKE"; do
  [[ -f "$mk" ]] || continue
  grep -E '^(PKG_NAME|PKG_VERSION|PKG_HASH|GO_PKG|MSD_LITE_REF):=' "$mk" | sed 's/^/  /'
done

summary=""
for mk in "$DDNS_MAKE" "$MSD_MAKE"; do
  [[ -f "$mk" ]] || continue
  summary="${summary}$(sed -n 's/^PKG_NAME:=//p' "$mk" | sed -n '1p')=$(sed -n 's/^PKG_VERSION:=//p' "$mk" | sed -n '1p')  "
done
ann "::notice title=本轮固件里的上游包版本::${summary}（ddns-go ${ddns_state}；msd_lite ${msd_state}）"

exit 0
