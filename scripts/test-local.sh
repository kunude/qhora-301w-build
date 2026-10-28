#!/usr/bin/env bash
#
# 本地回归：在**真实基座树**上跑 scripts/prepare.sh，覆盖几条关键组合。
#
# 为什么要有这个脚本：prepare.sh 有太多"只在真树上才暴露"的行为 —— feeds 脚本
# 到底解不解析依赖、defconfig 会不会静默丢符号、反复跑会不会残留上一轮状态。
# 这些在 CI 上要等 20 分钟才知道，本地跑一遍 prepare 阶段只要 1~2 分钟。
# 2026-10-28 这次改动就是靠它抓出三个真问题：
#   · extra-packages.sh 不认识 PROXY_STACK=none
#   · common.config 里还留着上一代 NSS 的 21 个符号
#   · 反复跑时 feeds.conf 里残留的 small 行让 `feeds install -a` 装了整个 feed
#
# 用法：
#   scripts/test-local.sh ~/work/imm                     # 默认跑 none + daed
#   scripts/test-local.sh ~/work/imm none daed err       # 指定组合
#   scripts/test-local.sh ~/work/ppe nss                 # NSS 线（树必须是 ppe-nss）
#
# 组合：
#   none      immortalwrt + 无代理 + 两个 small 插件（验证依赖闭包）
#   daed      immortalwrt + daed（线上在用的那套）
#   homeproxy immortalwrt + homeproxy（会额外刷规则集，需要联网）
#   nss       ppe-nss 整树 + daed（树必须是 ppe-nss）
#   err       点一个不存在的包，**期望失败**（验证报错清晰）
#
# 退出码 0 = 全通过。任何一步不符合预期即失败并打印该步日志尾部。
#
set -Eeuo pipefail

TREE="${1:?用法：$0 <基座源码目录> [none|daed|homeproxy|nss|err ...]}"
shift || true
CASES=("$@")
((${#CASES[@]})) || CASES=(none daed)

BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="$(cd "$TREE" && pwd)"
OUT="${TMPDIR:-/tmp}/qhora-test-$$"
mkdir -p "$OUT"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; }
hr()   { printf '\033[1m%s\033[0m\n' "────────────────────────────────────────────────────"; }

# 树指纹：先确认节点树的类型，NSS 组合与非 NSS 组合不能串树
HAS_NSS_DRV=0
[[ -d "$TREE/package/kernel/nss-wifi-drv" ]] && HAS_NSS_DRV=1

pass=0 fail=0
declare -a FAILED=()

run_case() {
  local case="$1" distro nss stack extra expect_fail=0 logf
  case "$case" in
    none)      distro=immortalwrt nss=0 stack=none      extra="luci-app-mosdns,luci-app-nikki" ;;
    daed)      distro=immortalwrt nss=0 stack=daed      extra="luci-app-mosdns" ;;
    homeproxy) distro=immortalwrt nss=0 stack=homeproxy extra="" ;;
    nss)       distro=openwrt     nss=1 stack=daed      extra="luci-app-mosdns" ;;
    err)       distro=immortalwrt nss=0 stack=none      extra="luci-app-mosdns,luci-app-no-such-pkg"
               expect_fail=1 ;;
    *) bad "不认识的组合：$case"; fail=$((fail+1)); FAILED+=("$case"); return 0 ;;
  esac

  log "组合 $case：distro=$distro NSS=$nss 代理=$stack 额外插件=${extra:-（无）}"
  logf="$OUT/$case.log"

  local rc=0
  OPENWRT_DIR="$TREE" BUILDER_DIR="$BUILDER_DIR" \
    DISTRO="$distro" NSS="$nss" PROXY_STACK="$stack" EXTRA_PACKAGES="$extra" \
    LOG_FILE="$logf" \
    bash "$BUILDER_DIR/scripts/prepare.sh" >"$OUT/$case.out" 2>&1 || rc=$?

  if ((expect_fail)); then
    if ((rc == 0)); then
      bad "$case：期望失败但成功了（点不存在的包应该当场报错）"
      fail=$((fail+1)); FAILED+=("$case")
    elif ! grep -q "既不在 kenzok8/small" "$OUT/$case.out"; then
      bad "$case：确实失败了，但报错信息不清晰（没指出包名找不到）"
      tail -n 5 "$OUT/$case.out" | sed 's/^/      /'
      fail=$((fail+1)); FAILED+=("$case")
    else
      ok "$case：按预期失败，且报错点明了包名"
      pass=$((pass+1))
    fi
    return 0
  fi

  if ((rc != 0)); then
    bad "$case：prepare.sh 失败（rc=$rc）"
    tail -n 12 "$OUT/$case.out" | sed 's/^/      /'
    fail=$((fail+1)); FAILED+=("$case")
    return 0
  fi

  # ── 断言：真正的失败模式都在这三条上 ─────────────────────────
  local bads=0
  # ① 符号没被 defconfig 静默丢掉
  if grep -q "配置文件请求的符号全部保留" "$OUT/$case.out"; then
    ok "$case：配置请求的符号全部保留"
  else
    bad "$case：有符号被 defconfig 丢弃"; bads=1
  fi
  # ② 额外插件的依赖真的进了 .config，而不只是建了软链
  if [[ -n "$extra" ]]; then
    if grep -q "无符号（包没被 make 扫描到）" "$OUT/$case.out"; then
      bad "$case：有依赖包在 make 眼里不存在"; bads=1
    elif grep -q "额外插件的依赖落位" "$OUT/$case.out"; then
      ok "$case：依赖落位清单已打印，且没有无符号项"
    else
      bad "$case：没打印依赖落位清单（闭包没生效？）"; bads=1
    fi
  fi
  # ③ NSS 线的树指纹断言必须真的跑过
  if ((nss == 1)); then
    if grep -qx "CONFIG_PACKAGE_kmod-nss-wifi-drv=y" "$TREE/.config" 2>/dev/null; then
      ok "$case：kmod-nss-wifi-drv 确实进了 .config"
    else
      bad "$case：kmod-nss-wifi-drv 不在 .config 里 —— NSS 等于没开"; bads=1
    fi
  fi

  if ((bads)); then
    fail=$((fail+1)); FAILED+=("$case")
    tail -n 8 "$OUT/$case.out" | sed 's/^/      /'
  else
    pass=$((pass+1))
  fi
}

hr
log "基座树：$TREE（NSS 指纹：$([[ $HAS_NSS_DRV == 1 ]] && echo ppe-nss || echo 上游)）"
log "仓库：$BUILDER_DIR"
hr

for c in "${CASES[@]}"; do
  # 树与组合的一致性先做一次快速检查，省得白跑 2 分钟
  if [[ "$c" == "nss" && $HAS_NSS_DRV -eq 0 ]]; then
    bad "组合 nss 需要 ppe-nss 树，但 $TREE 不是（缺少 package/kernel/nss-wifi-drv）"
    fail=$((fail+1)); FAILED+=("$c"); continue
  fi
  if [[ "$c" != "nss" && $HAS_NSS_DRV -eq 1 ]]; then
    bad "组合 $c 需要上游树，但 $TREE 是 ppe-nss"
    fail=$((fail+1)); FAILED+=("$c"); continue
  fi
  run_case "$c"
  hr
done

log "结果：通过 $pass，失败 $fail"
if ((fail)); then
  printf '  失败组合：%s\n' "${FAILED[*]}"
  printf '  原始输出在 %s\n' "$OUT"
  exit 1
fi
log "全部通过 —— 可以推送"
