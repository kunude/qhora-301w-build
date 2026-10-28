#!/usr/bin/env bash
#
# 解析一个 feed 内部的包依赖闭包。
#
# 为什么需要它：OpenWrt 的 `scripts/feeds install <pkg>` **不解析依赖**，只给
# 那一个包建软链。而从 kenzok8/small 里点一个插件，它常常依赖同 feed 里的
# 另外几个包（luci-app-mosdns → mosdns + geo2txt，luci-app-ssr-plus →
# dns2tcp + microsocks + ipt2socks …）。这些包没被 install 就没有 Kconfig
# 符号，`make defconfig` 会因为「depends on PACKAGE_mosdns 不成立」把整条链
# **静默丢掉** —— 插件装不上，固件却照样编出来。
#
# 所以：进固件的显式包只有用户点名的那几个，但进构建系统的包必须是闭包。
#
# 用法：
#   FEED_DIR=feeds/small bash scripts/resolve-deps.sh luci-app-mosdns
#
# 输出（依赖在前的拓扑序），每行两列：
#   <包名>\t<small|external>
#     small    —— 这个包里就是这个 feed 提供的，需要 feeds install
#     external —— 这个 feed 里没有，靠官方 feed / 主树，调用方按需校验
#
# 只认 [LUCI_]DEPENDS 与 define Package/* 段名。不展开 $(VAR)、不处理
# @TARGET_xxx 这类 Kconfig 条件 —— 前者是构建参数（golang/host 之类），
# 后者不是包，混进来只会污染闭包。
#
set -Eeuo pipefail

FEED_DIR="${FEED_DIR:?FEED_DIR 未设置（指向已 feeds update 的 feed 源码目录）}"
[[ -d "$FEED_DIR" ]] || { printf 'Feed 目录不存在：%s\n' "$FEED_DIR" >&2; exit 2; }
(($#)) || { printf '用法：FEED_DIR=<dir> %s <包名>...\n' "${0##*/}" >&2; exit 2; }

# ── 一次扫描，产出 PROVIDES / NEEDS 两类边 ───────────────────────
# awk 输出三列：<kind>\t<group>\t<name>，group 用 Makefile 路径当标识。
# 一个 Makefile 可能 define 多个 Package/（主包 + 变体），依赖按 group 共享。
scan() {
  find "$FEED_DIR" -name Makefile -not -path '*/.git/*' -print0 |
    sort -z |
    xargs -0 awk '
      function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

      # 不用 ENDFILE —— 那是 gawk 扩展，Ubuntu 的 awk 默认是 mawk，会直接语法错。
      # 每个文件开头先单独读一遍拿 PKG_NAME：define Package/$(PKG_NAME) 展开要用，
      # 而它偶尔出现在 define 之后。
      FNR == 1 {
        pkg = ""
        while ((getline l < FILENAME) > 0) {
          if (l ~ /^[ \t]*PKG_NAME[ \t]*[:+]?=/) {
            v = l; sub(/^[^=]*=/, "", v); pkg = trim(v); break
          }
        }
        close(FILENAME)
        # luci-app-nikki / luci-app-momo 这类没有 PKG_NAME —— luci.mk 里
        # `PKG_NAME:=$(notdir $(CURDIR))`，包名就等于目录名。不兜底的话
        # 它们会被当成「外部包」，依赖闭包直接漏掉。
        if (pkg == "") {
          d = FILENAME
          sub(/\/Makefile$/, "", d)
          k = split(d, dp, "/")
          pkg = dp[k]
        }
        if (pkg != "") print "PROVIDES\t" FILENAME "\t" pkg
      }

      {
        line = $0

        # 续行：DEPENDS:=+a +b \  <换行>  +c。不合并的话只看到半条依赖。
        while (line ~ /\\[ \t]*$/) {
          sub(/\\[ \t]*$/, "", line)
          if ((getline nxt) <= 0) break
          line = line " " nxt
        }

        if (line ~ /^[ \t]*PKG_NAME[ \t]*[:+]?=/) {
          v = line; sub(/^[^=]*=/, "", v); pkg = trim(v)
        }
        # 段名既是「这个 Makefile 提供什么」，也是 install 时认的包名
        if (line ~ /^[ \t]*define[ \t]+Package\//) {
          v = line
          sub(/^[ \t]*define[ \t]+Package\//, "", v)
          sub(/[ \t].*$/, "", v)
          gsub(/\$\(PKG_NAME\)/, pkg, v)
          if (v ~ /^[A-Za-z0-9]/) print "PROVIDES\t" FILENAME "\t" v
        }

        if (line ~ /^[ \t]*(LUCI_)?DEPENDS[ \t]*[:+]?=/) {
          v = line; sub(/^[^=]*=/, "", v)
          n = split(v, a, /[ \t]+/)
          for (i = 1; i <= n; i++) {
            t = a[i]
            # Kconfig 条件是 @TARGET_x / @!BROKEN，不是包
            if (t ~ /^@/) continue
            if (t ~ /^!/) continue
            sub(/^\+/, "", t)
            # +PACKAGE_luci-app-x_INCLUDE_MosDNS:mosdns → 右边才是包名
            if (index(t, ":")) { k = split(t, b, ":"); t = b[k] }
            # 裸名（DEPENDS:=firewall4 这种没有 + 的）同样要认：它的符号
            # 不存在时，Kconfig 一样会把依赖它的包整条丢掉。
            if (t ~ /^PACKAGE_/) continue
            if (t !~ /^[a-zA-Z][a-zA-Z0-9._+-]*$/) continue
            # 变量、路径（golang/host）、赋值残留都不是包名
            if (t ~ /[\/$()=]/) continue
            print "NEEDS\t" FILENAME "\t" t
          }
        }
      }
    '
}

edges="$(mktemp)"
trap 'rm -f "$edges"' EXIT
scan >"$edges"

# ── 建索引 ──────────────────────────────────────────────────────
# owner[pkg] = group；gdeps[group] = "依赖 依赖 …"
declare -A owner=() gdeps=() gpkg=()
while IFS=$'\t' read -r kind group name; do
  case "$kind" in
    PROVIDES)
      owner["$name"]="$group"
      gpkg["$group"]+="$name "
      ;;
    NEEDS)
      gdeps["$group"]+="$name "
      ;;
  esac
done <"$edges"

# ── 深度优先展开闭包，后序输出 ⇒ 依赖一定排在依赖者之前 ──────────
declare -A seen=()
order=()

walk() {
  local p="$1"
  [[ -n "${seen[$p]:-}" ]] && return 0
  seen["$p"]=1

  if [[ -z "${owner[$p]:-}" ]]; then
    # 不归这个 feed 管：可能是官方 feed、主树，也可能名字拼错。交给调用方判断。
    order+=("$p"$'\t'"external")
    return 0
  fi

  local g="${owner[$p]}" d
  for d in ${gdeps[$g]:-}; do
    walk "$d"
  done
  order+=("$p"$'\t'"small")
}

for t in "$@"; do
  walk "$t"
done

printf '%s\n' "${order[@]}"
