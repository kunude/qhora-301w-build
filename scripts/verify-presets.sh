#!/usr/bin/env bash
#
# 出厂预置对齐校验：覆盖层里的每个文件，必须原样出现在最终 rootfs 里。
#
# ── 为什么需要它 ──────────────────────────────────────────────────────────
# prepare-build.sh 的第 6 步做的是：
#     for d in files/ files-<栈>/; do cp -a "$d/." <树>/files/; done
# 这是一个**静默**的合并：目录名拼错（files-passwal）、被 .gitignore 吃掉、
# 或者某次重构把目录挪了位置，都不报错 —— 编出来的固件照样能刷、能开机，
# 只是打开配置页面是空的。这类问题只有刷完机才发现，代价是一个固件周期。
#
# 已有的守卫只覆盖了一半：
#   · check-no-credentials.sh  只管 etc/config/ 里**有没有凭据**，不管在不在；
#   · prepare-build.sh 的断言 只对 dae（config.dae）和 daed（wing.db）点名核对。
#   passwall / passwall2 / homeproxy / singbox / 公共层 files/ 都没有任何一步
#   去镜像里确认过。这个脚本补的就是这一块，而且是**按覆盖层逐个文件**核对，
#   所以不管以后谁新增变体，都不需要再补一份名单。
#
# ── 为什么核对的是 build_dir 里的 root-* 而不是 .bin ────────────────────
# root-<board> 是 make 组镜像之前**已经拼好的根文件系统**，prepare_rootfs 正是
# 把 files/ 拷进它里面再打成 squashfs 的。直接从 .bin 里验需要先算 squashfs
# 的偏移量（binwalk/unsquashfs -o），既慢又依赖额外工具；而 root-* 目录就在
# build_dir 里，跑完 make 必然存在，内容与镜像一致。所以校验点放在这里。
#
# ── 用法 ──────────────────────────────────────────────────────────────────
#   bash scripts/verify-presets.sh                       # 自动找树与 root-*
#   bash scripts/verify-presets.sh --tree openwrt        # 指定源码树
#   bash scripts/verify-presets.sh --overlay openwrt/files \
#                                  --root openwrt/build_dir/target-*/root-qualcommax
#   bash scripts/verify-presets.sh --self-test           # 自我验证（不需要编译）
#
#   --overlay  默认 <树>/files（prepare 之后它= files/ + files-<栈>/ 的合并结果）
#   --root     默认在 <树>/build_dir 下找唯一的 root-* 目录
#   --self-test 造一个假 rootfs 验证本脚本本身能通过、并且在缺文件时能判红
#
# 退出码：0 全部对齐；1 有缺失 / 内容不一致 / 权限不对 / 参数问题。
#
set -Eeuo pipefail

BUILDER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OPENWRT_DIR="${OPENWRT_DIR:-$BUILDER_DIR/openwrt}"

TREE=""
OVERLAY=""
ROOT=""
SELF_TEST=0

die() { echo "[x] $*" >&2; exit 1; }
log() { echo "  · $*"; }

while (($#)); do
  case "$1" in
    --tree)     TREE="${2:?--tree 需要参数}"; shift 2 ;;
    --overlay)  OVERLAY="${2:?--overlay 需要参数}"; shift 2 ;;
    --root)     ROOT="${2:?--root 需要参数}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help)  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "不认识的参数：$1（--help 看用法）" ;;
  esac
done

TREE="${TREE:-$OPENWRT_DIR}"
OVERLAY="${OVERLAY:-$TREE/files}"

# ── 期望权限表 ────────────────────────────────────────────────────────────
# 只对**有硬性要求**的路径设检查，其余不查 —— 否则脚本会因为无关的
# 0644/0755 差异天天误报，反而没人看它。
#
# 这些权限不是"好看"，是功能前提：
#   etc/ssh/*             sshd 拒绝加载 group/other 可写的配置（整个服务起不来）
#   etc/dae/*             `dae validate` 只接受 0640/0600，否则拒绝启动
#   etc/honk/*.dae        honk 与 dae 同源，配置里天生要放订阅链接
#   etc/daed/*            管理员口令哈希在 wing.db 里
#   etc/uci-defaults/*    不可执行就不会在首启时跑（预置等于没做）
#   usr/bin/*             覆盖层带来的命令（dae-switch / dae-geo-update）
expected_mode() {
  local rel="$1"
  case "$rel" in
    etc/ssh/*)           echo 600 ;;
    etc/dae/*)           echo 600 ;;
    etc/honk/*.dae)      echo 600 ;;
    etc/daed/*)          echo 600 ;;
    etc/uci-defaults/*)  echo 755 ;;
    usr/bin/*)           echo 755 ;;
    *)                   echo "" ;;
  esac
}

# mode_of <file> → 三位八进制（跨 GNU/BSD 兼容：先试 stat -c，再退到 stat -f）
mode_of() {
  local m
  m="$(stat -c '%a' "$1" 2>/dev/null)" || m="$(stat -f '%Lp' "$1" 2>/dev/null)" || m=""
  # 去掉 setuid/setgid/sticky 高位（如 4755 → 755），只比低三位
  printf '%s' "${m: -3}"
}

# ── 核心比对 ──────────────────────────────────────────────────────────────
# check_tree <overlay> <root>
# 输出三段：缺失（致命）、内容不一致（致命）、权限不对（致命，因为上面那张表
# 里的每一条都是功能前提）。返回不一致的条目数。
check_tree() {
  local overlay="$1" root="$2"
  local missing=0 differ=0 badmode=0 total=0 bad=0
  local f rel tgt want got

  [[ -d "$overlay" ]] || die "覆盖层目录不存在：$overlay"
  [[ -d "$root" ]]    || die "rootfs 目录不存在：$root"

  while IFS= read -r -d '' f; do
    rel="${f#"$overlay"/}"
    tgt="$root/$rel"
    total=$((total + 1))

    if [[ ! -e "$tgt" ]]; then
      echo "  [缺失] $rel"
      missing=$((missing + 1)); bad=$((bad + 1))
      continue
    fi

    # 内容必须逐字节一致：rootfs 里同名文件被别的包覆盖，说明我们的预置没生效
    if ! cmp -s "$f" "$tgt"; then
      echo "  [内容不一致] $rel（rootfs 里那份与覆盖层不同 —— 多半被某个包的同名文件盖掉了）"
      differ=$((differ + 1)); bad=$((bad + 1))
    fi

    want="$(expected_mode "$rel")"
    if [[ -n "$want" ]]; then
      got="$(mode_of "$tgt")"
      if [[ "$got" != "$want" ]]; then
        echo "  [权限] $rel  期望 $want，实际 ${got:-读不到}"
        badmode=$((badmode + 1)); bad=$((bad + 1))
      fi
    fi
  done < <(find "$overlay" -type f -print0 | sort -z)

  echo "  · 覆盖层 $total 个文件：缺失 $missing / 内容不一致 $differ / 权限不符 $badmode"
  return "$bad"
}

# ── 自我验证：不需要编译 ──────────────────────────────────────────────────
# 用覆盖层自己造一个"假 rootfs"，先确认全通过，再删掉一个文件确认能判红。
# 这样在没有构建产物的机器上（本地开发机）也能证明脚本本身是好的。
if ((SELF_TEST)); then
  command -v cmp >/dev/null 2>&1 || die "self-test 需要 cmp（diffutils）"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/root"
  cp -a "$OVERLAY/." "$tmp/root/"

  echo "== self-test ① 完整复制到假 rootfs，应当全部通过"
  if check_tree "$OVERLAY" "$tmp/root"; then
    echo "   ✓ 通过（与预期一致）"
  else
    die "self-test 失败：完整复制居然判红，说明比对逻辑有问题"
  fi

  echo "== self-test ② 删掉一个文件，应当判红并点名"
  victim="$(find "$tmp/root" -type f | head -n1)"
  rm -f "$victim"
  if check_tree "$OVERLAY" "$tmp/root" 2>/dev/null; then
    die "self-test 失败：缺了文件却判绿，这个校验等于没有"
  else
    echo "   ✓ 按预期判红"
  fi

  echo "self-test 通过：覆盖层 $OVERLAY 的比对逻辑可用"
  exit 0
fi

# ── 自动发现 root-* ───────────────────────────────────────────────────────
# make 之后 build_dir 下会有 root-<board>（prepare_rootfs 的产物）。
# 可能有多个（不同 target 编过），挑含有 etc/ 且文件数最多的那个。
if [[ -z "$ROOT" ]]; then
  # maxdepth 3：不同版本 OpenWrt 的 root 目录层数不完全一致
  # （build_dir/target-*/root-<board> 是常见形态，个别分支多一层），
  # 多给一层不会误伤 —— 后面还会按"含 etc/ 且文件最多"筛一次。
  mapfile -t cands < <(find "$TREE/build_dir" -maxdepth 3 -type d -name 'root-*' 2>/dev/null)
  if ((${#cands[@]} == 0)); then
    die "在 $TREE/build_dir 下没找到 root-* 目录" \
        "（还没 make 过？或者构建产物已被清理。CI 里这一步必须放在 make 之后）"
  fi
  ROOT=""
  best=0
  for d in "${cands[@]}"; do
    [[ -d "$d/etc" ]] || continue
    n="$(find "$d" -type f 2>/dev/null | wc -l)"
    if ((n > best)); then best="$n"; ROOT="$d"; fi
  done
  [[ -n "$ROOT" ]] || die "找到 ${#cands[@]} 个 root-* 目录但没有一个含 etc/：${cands[*]}"
  log "自动选中 rootfs：$ROOT（$best 个文件）"
fi

echo "校验出厂预置是否进了镜像"
log "覆盖层：$OVERLAY"
log "rootfs：$ROOT"

if check_tree "$OVERLAY" "$ROOT"; then
  echo "✓ 出厂预置全部就位（缺失 0 / 内容一致 / 权限正确）"
  exit 0
else
  echo
  echo "[x] 出厂预置没有全部进镜像。"
  echo "    典型原因："
  echo "      · files-<栈>/ 目录名拼错（prepare-build.sh 对不存在的目录是静默跳过的）"
  echo "      · 覆盖层文件被 .gitignore 吃掉，没进仓库"
  echo "      · 某个包也装同名文件，且装在我们的覆盖层之后（内容不一致那一类）"
  echo "      · 权限在 prepare-build.sh 里没被收紧（uci-defaults 不可执行 = 首启不跑）"
  exit 1
fi
