#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  HomeProxy 规则集（.srs）拉取 / 校验
#
#  ── 为什么需要它 ──────────────────────────────────────────────────────
#  HomeProxy 的 ruleset 若是 type='remote'，sing-box **在服务启动时**才去
#  url 下载。首启时 9 个规则集全要下载，而 raw.githubusercontent.com 直连
#  不通（要经代理，可代理又恰恰是此刻在启动的那个服务）——任何一个下载失败
#  sing-box 就起不来；而 /etc/init.d/homeproxy 在启动 sing-box **之前**已经
#  把 dnsmasq 劫持到 127.0.0.1:5333（redirect-dns.conf），于是 DNS 全挂、
#  整个 LAN 无法上网。
#
#  所以固件里这 9 条一律是 type='local' + path='/etc/homeproxy/ruleset/x.srs'，
#  文件随固件预置。本脚本负责把这些文件准备好：
#
#    ① 构建期刷新（prepare-build.sh 自动调用，默认）
#         把上游**最新版**下载进构建树的覆盖层
#         <OPENWRT_DIR>/files/etc/homeproxy/ruleset/
#       ⇒ 每次编译都拿到最新规则，且编译产物不需要联网。
#    ② 刷新仓库内置兜底副本（人工，--dest 指向仓库里的 files-homeproxy/...）
#       ⇒ 上游下载不到时靠它顶着，固件里永远有可用规则、绝不出现空文件。
#
#  ── 失败策略 ──────────────────────────────────────────────────────────
#  单个文件下载失败：保留目标目录里已有的那份（= 仓库兜底副本），打
#  ::warning:: 注解，**继续构建**。目标目录里也没有、兜底也没有 ⇒ 直接失败
#  （否则出厂配置会指向不存在的文件，sing-box check 一启动就 FATAL）。
#  加 --strict / RULESETS_STRICT=1：任何一个文件下载失败就中断构建
#  （宁可编不过，也不要出一份规则版本不明的固件）。
#
#  ── 用法 ──────────────────────────────────────────────────────────────
#    # 构建期刷新（prepare-build.sh 用的就是这条）
#    bash scripts/fetch-homeproxy-rulesets.sh --dest "$OPENWRT_DIR/files/etc/homeproxy/ruleset"
#
#    # 拉最新，写回仓库兜底副本
#    bash scripts/fetch-homeproxy-rulesets.sh --dest files-homeproxy/etc/homeproxy/ruleset
#
#    # 只校验，不联网（CI 上想做"离线固化"时用）
#    bash scripts/fetch-homeproxy-rulesets.sh --dest ... --verify-only
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

MANIFEST="$REPO_DIR/configs/homeproxy-rulesets.list"
DEST=""
PINNED="$REPO_DIR/files-homeproxy/etc/homeproxy/ruleset"
STRICT="${RULESETS_STRICT:-0}"
VERIFY_ONLY=0

# .srs 是 sing-box 的二进制规则集格式，文件头固定 3 字节 "SRS"（随后是
# 格式版本号）。用它挡掉"下载到一张 HTML 错误页 / 半截文件"这种最阴的失败 ——
# 光看"退出码 0 + 文件非空"是挡不住的（实测：raw.githubusercontent.com 在
# 某些网络下会回一个 200 的 HTML 提示页）。
SRS_MAGIC="SRS"
# 阈值只用来挡"空文件 / 半截文件"。别设大 —— 实测 geosite-apple-update.srs
# 上游就只有 249 字节（Apple 的更新服务器域名本来就没几条），设 512 会误杀。
SRS_MIN_SIZE=64

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)        DEST="${2:-}"; shift 2 ;;
    --manifest)    MANIFEST="${2:-}"; shift 2 ;;
    --pinned)      PINNED="${2:-}"; shift 2 ;;
    --strict)      STRICT=1; shift ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    -h|--help)     usage 0 ;;
    *) echo "不认识的参数：$1" >&2; usage 1 ;;
  esac
done

[[ -n "$DEST" ]]    || { echo "--dest 是必填的（目标 ruleset 目录）" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "规则清单不存在：$MANIFEST" >&2; exit 1; }

ann()  { [[ "${GITHUB_ACTIONS:-}" == "true" ]] && echo "$1" || true; }
warn() { echo "::warning::$*" >&2; echo "[warn] $*" >&2; }
log()  { echo "[ruleset] $*"; }

# ── 读清单 ────────────────────────────────────────────────────────────────
# 同时滤掉注释与空行；顺带做一次格式校验（必须是 name|url）。
declare -a NAMES=() URLS=()
while IFS= read -r line; do
  line="${line%%#*}"                       # 去掉行尾注释
  line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -z "$line" ]] && continue
  if [[ "$line" != *"|"* ]]; then
    echo "清单格式错误（应为 <名字>|<URL>）：$line" >&2
    exit 1
  fi
  NAMES+=( "${line%%|*}" )
  URLS+=(  "${line#*|}" )
done < "$MANIFEST"

[[ ${#NAMES[@]} -gt 0 ]] || { echo "清单里一条规则都没有：$MANIFEST" >&2; exit 1; }
log "清单：$MANIFEST（${#NAMES[@]} 条）"

mkdir -p "$DEST"

# ── 校验单个 .srs ─────────────────────────────────────────────────────────
# 返回 0 = 好文件
check_srs() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  local sz magic
  sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  [[ "$sz" -ge "$SRS_MIN_SIZE" ]] || return 1
  magic="$(head -c3 "$f" 2>/dev/null || true)"
  [[ "$magic" == "$SRS_MAGIC" ]] || return 1
  return 0
}

sha12() { sha256sum "$1" 2>/dev/null | cut -c1-12; }

# ── 主循环 ────────────────────────────────────────────────────────────────
declare -a LOCK=()
fail=0; fetched=0; kept=0; from_pinned=0

for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; url="${URLS[$i]}"
  target="$DEST/$name.srs"
  src=""

  if [[ "$VERIFY_ONLY" == "1" ]]; then
    if check_srs "$target"; then
      src="existing"
    else
      warn "$name.srs 缺失或不合法（--verify-only 不做下载）"
      fail=1
      continue
    fi
  else
    tmp="$(mktemp "$DEST/.$name.XXXXXX")"
    if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 \
            -o "$tmp" "$url" 2>/dev/null && check_srs "$tmp"; then
      mv -f "$tmp" "$target"
      src="upstream"
      fetched=$((fetched + 1))
    else
      rm -f "$tmp"
      # 退一步：目标目录里已有的那份（通常是仓库兜底副本刚覆盖进去的）
      if check_srs "$target"; then
        src="kept"
        kept=$((kept + 1))
        warn "$name：上游拉取失败，继续用构建树里已有的那份（$(sha12 "$target")）"
      elif check_srs "$PINNED/$name.srs"; then
        mkdir -p "$DEST"
        cp -f "$PINNED/$name.srs" "$target"
        src="pinned"
        from_pinned=$((from_pinned + 1))
        warn "$name：上游拉取失败，改用仓库兜底副本（$(sha12 "$target")）"
      else
        echo "::error::$name：上游拉取失败，且构建树与仓库里都没有可用副本" >&2
        fail=1
        continue
      fi
    fi
  fi

  printf -v line '%-10s %-8s %10s  %s\n' "$name" "$(sha12 "$target")" \
    "$(stat -c%s "$target")" "$src"
  log "$line"
  LOCK+=( "$name $(sha256sum "$target" | cut -d' ' -f1) $(stat -c%s "$target") $src $url" )
done

# ── 三处名字对齐（清单 ↔ 出厂配置 ↔ uci-defaults）───────────────────────
# 名字对不上的后果很隐蔽：固件里配了 ruleset 'x'，但文件叫 y.srs ⇒
# sing-box check 失败、服务起不来。所以在构建期就拦住。
align_fail=0
for f in "$REPO_DIR/files-homeproxy/etc/config/homeproxy" \
         "$REPO_DIR/files-homeproxy/etc/uci-defaults/95-homeproxy-rulesets"; do
  [[ -f "$f" ]] || { warn "找不到 $f，跳过名字对齐检查"; continue; }
  for name in "${NAMES[@]}"; do
    if ! grep -q "$name" "$f"; then
      echo "::error::${f##*/} 里没有 '$name'（清单里有 ⇒ 三处必须一致）" >&2
      align_fail=1
    fi
  done
done
[[ "$align_fail" == "0" ]] || { echo "规则集名字在清单/出厂配置/uci-defaults 之间不一致" >&2; exit 1; }

# ── 写溯源文件 ────────────────────────────────────────────────────────────
# 随固件一起进 /etc/homeproxy/rulesets.lock：日后在机器上就能看到"这份固件
# 里的规则是哪天从哪拉的、sha256 是多少"，不用猜。
LOCK_FILE="$(dirname "$DEST")/rulesets.lock"
{
  echo "# HomeProxy 规则集溯源（由 scripts/fetch-homeproxy-rulesets.sh 生成）"
  echo "# 生成时间(UTC): $(date -u '+%Y-%m-%d %H:%M:%S')"
  echo "# dest: $DEST"
  echo "# 字段: <名字> <sha256> <字节> <来源: upstream|kept|pinned|existing> <URL>"
  for l in "${LOCK[@]}"; do echo "$l"; done
} > "$LOCK_FILE"
log "溯源文件：$LOCK_FILE"

log "汇总：上游新拉 $fetched ／ 沿用已有 $kept ／ 仓库兜底 $from_pinned ／ 共 ${#NAMES[@]} 条"

if [[ "$fail" != "0" ]]; then
  if [[ "$STRICT" == "1" ]]; then
    echo "::error::规则集有缺失（RULESETS_STRICT=1 ⇒ 中断构建）" >&2
  else
    echo "::error::规则集有缺失且无兜底副本可用" >&2
  fi
  exit 1
fi
[[ "$STRICT" == "1" && ( "$kept" -gt 0 || "$from_pinned" -gt 0 ) ]] && {
  echo "::error::RULESETS_STRICT=1 但没拿到全部最新版（沿用已有 $kept / 兜底 $from_pinned）" >&2
  exit 1
}

if [[ "$fetched" -eq "${#NAMES[@]}" ]]; then
  ann "::notice title=HomeProxy 规则集::已从上游拉取最新版 ${fetched}/${#NAMES[@]}（随固件预置，首启零下载）"
else
  ann "::notice title=HomeProxy 规则集::上游新拉 $fetched ／ 沿用已有 $kept ／ 兜底 $from_pinned（共 ${#NAMES[@]}）"
fi
exit 0
