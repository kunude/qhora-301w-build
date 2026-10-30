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
#   scripts/test-local.sh ~/work/imm nss-imm             # imm + NSS 移植
#   scripts/test-local.sh ~/work/ppe nss                 # NSS 线（树必须是 ppe-nss）
#
# 组合：
#   none      immortalwrt + 无代理 + 两个 small 插件（验证依赖闭包）
#   daed      immortalwrt + daed（线上在用的那套）
#   homeproxy immortalwrt + homeproxy（会额外刷规则集，需要联网）
#   honk      immortalwrt + honk（含 doona 面板；会查 GitHub API 补构建元数据）
#   passwall  immortalwrt + passwall v1（Lua 界面 + luci-compat + Xray）
#   passwall2 immortalwrt + passwall v2（默认栈，ucode 界面；v1/v2 共用组件仓库）
#   nss-imm   immortalwrt + NSS 移植（树是上游树，组件由构建时搬进来）
#   nss       openwrt + ppe-nss 整树 + daed（树必须是 ppe-nss）
#   err       点一个不存在的包，**期望失败**（验证报错清晰）
#   conflict  参数与树不一致（immortalwrt + ppe-nss 树），**期望失败**
#
# 退出码 0 = 全通过。任何一步不符合预期即失败并打印该步日志尾部。
#
set -Eeuo pipefail

TREE="${1:?用法：$0 <基座源码目录> [none|daed|homeproxy|honk|passwall|passwall2|nss|err ...]}"
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

# 树指纹：判据用 seeds/ 而不是 nss-wifi-drv 目录 —— 移植线跑完以后上游树里
# 也会有那个目录，拿目录当判据会把「移植过的 imm」误判成 ppe-nss 整树。
HAS_PPE_SEED=0
[[ -f "$TREE/seeds/qualcommax-nss-wifi.seed" ]] && HAS_PPE_SEED=1

pass=0 fail=0
declare -a FAILED=()

run_case() {
  local case="$1" distro nss stack extra expect_fail=0 expect_msg="" logf
  case "$case" in
    none)      distro=immortalwrt nss=0 stack=none      extra="luci-app-mosdns,luci-app-nikki" ;;
    daed)      distro=immortalwrt nss=0 stack=daed      extra="luci-app-mosdns" ;;
    homeproxy) distro=immortalwrt nss=0 stack=homeproxy extra="" ;;
    honk)      distro=immortalwrt nss=0 stack=honk      extra="" ;;
    passwall)  distro=immortalwrt nss=0 stack=passwall  extra="" ;;
    passwall2) distro=immortalwrt nss=0 stack=passwall2 extra="" ;;
    nss)       distro=openwrt     nss=1 stack=daed      extra="luci-app-mosdns" ;;
    # imm 基座 + NSS 移植：组件由构建时从 ppe-nss 搬进来，产物同上
    nss-imm)   distro=immortalwrt nss=1 stack=none      extra="" ;;
    err)       distro=immortalwrt nss=0 stack=none      extra="luci-app-mosdns,luci-app-no-such-pkg"
               expect_fail=1 expect_msg="既不在 kenzok8/small" ;;
    # 参数与树不一致：树是 ppe-nss 整树，却按 immortalwrt 要符号层 ——
    # 必须当场失败，否则编出来的 DISTRIB_ID 是 OpenWrt，和参数说的不是一件事
    conflict)  distro=immortalwrt nss=1 stack=none      extra=""
               expect_fail=1 expect_msg="树与参数不一致" ;;
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
      bad "$case：期望失败但成功了（这类参数组合不该产出固件）"
      fail=$((fail+1)); FAILED+=("$case")
    elif ! grep -qF "$expect_msg" "$OUT/$case.out"; then
      bad "$case：确实失败了，但报错信息对不上（找不到「$expect_msg」）"
      tail -n 5 "$OUT/$case.out" | sed 's/^/      /'
      fail=$((fail+1)); FAILED+=("$case")
    else
      ok "$case：按预期失败，且报错点明了原因"
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
    # 移植线还多一道：ath11k 那只开关。它在 =n 的时候补丁不会被应用，
    # 而 kmod-nss-wifi-drv 照样能编出来 —— 「装了驱动但 Wi-Fi 没卸载」。
    if [[ "$case" == "nss-imm" ]]; then
      if grep -qx "CONFIG_ATH11K_NSS_WIFI=y" "$TREE/.config" 2>/dev/null; then
        ok "$case：ATH11K_NSS_WIFI 已开（补丁会被应用）"
      else
        bad "$case：ATH11K_NSS_WIFI 没开 —— 驱动在，Wi-Fi 还在 CPU 上"; bads=1
      fi
      if [[ -d "$TREE/package/kernel/mac80211/patches/nss-wifi" ]] &&
         [[ "$(find "$TREE/package/kernel/mac80211/patches/nss-wifi" -name '*.patch' | wc -l)" -ge 18 ]]; then
        ok "$case：18 个 NSS 补丁已落位"
      else
        bad "$case：NSS 补丁没落位或数量不足"; bads=1
      fi
    fi
  fi

  # ④ 出厂预置：变体覆盖目录里的每个文件都必须真的落到 <树>/files/，
  #    并且权限要符合 verify-presets.sh 里的期望表。
  #    覆盖目录不存在时 prepare-build.sh 是静默跳过的，所以这一步是唯一
  #    能在 prepare 阶段发现"目录名写错 / 文件没进仓库"的地方。
  local ov="$BUILDER_DIR/files-$stack" rel miss=0
  if [[ -d "$ov" ]]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$ov"/}"
      if [[ ! -e "$TREE/files/$rel" ]]; then
        bad "$case：覆盖层 $rel 没落到 <树>/files/"; miss=1
      fi
    done < <(find "$ov" -type f -print0)
    if ((miss == 0)); then
      ok "$case：变体覆盖层 files-$stack/ 全部落位"
    else
      bads=1
    fi
  fi
  # 权限即功能：uci-defaults 不可执行 = 首启不跑，dae/honk 配置不是 0600 = 服务拒绝启动。
  # --self-test 会拿覆盖层造一个假 rootfs 跑完整比对，不需要真编译。
  if bash "$BUILDER_DIR/scripts/verify-presets.sh" --self-test --overlay "$TREE/files" \
       >>"$OUT/$case.out" 2>&1; then
    ok "$case：覆盖层权限表与比对逻辑自检通过"
  else
    bad "$case：verify-presets.sh 自检失败（权限不符或比对逻辑坏）"; bads=1
    tail -n 6 "$OUT/$case.out" | sed 's/^/      /'
  fi

  # ③-b passwall v1 线的四条硬指标。最容易出的错是"v2 被顺手也装进来"和
  #      "Lua 界面缺 luci-compat, 页面 404" —— 两者都编得过, 只有刷进去才发现。
  if [[ "$stack" == "passwall" ]]; then
    local v1ok=1
    grep -qx "CONFIG_PACKAGE_luci-app-passwall=y" "$TREE/.config" 2>/dev/null || v1ok=0
    grep -qx "CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=y" "$TREE/.config" 2>/dev/null || v1ok=0
    if ((v1ok)); then
      ok "$case：luci-app-passwall + 中文翻译都进了 .config"
    else
      bad "$case：luci-app-passwall / 翻译不在 .config 里"; bads=1
    fi
    if [[ -x "$TREE/files/etc/uci-defaults/zz-passwall-preset" ]]; then
      ok "$case：passwall 出厂补丁已落位且可执行"
    else
      bad "$case：zz-passwall-preset 缺失或不可执行（首启不会跑，出厂设置等于没做）"; bads=1
    fi
    if grep -qx "CONFIG_PACKAGE_luci-app-passwall2=y" "$TREE/.config" 2>/dev/null; then
      bad "$case：passwall2 也被选进来了（两代不能同装，会抢 nft 表与 dnsmasq）"; bads=1
    else
      ok "$case：passwall2 已被按掉（没有两代同装）"
    fi
    local luaok=1
    grep -qx "CONFIG_PACKAGE_luci-compat=y" "$TREE/.config" 2>/dev/null || luaok=0
    grep -qx "CONFIG_PACKAGE_xray-core=y" "$TREE/.config" 2>/dev/null || luaok=0
    if ((luaok)); then
      ok "$case：luci-compat（CBI 兼容层）与 xray-core 都在 .config 里"
    else
      bad "$case：luci-compat 或 xray-core 缺失（v1 的页面/节点会起不来）"; bads=1
    fi
  fi

  # ④ honk 线的三条硬指标：核心 / 面板进 .config，构建元数据被补齐。
  #    这三样任何一样缺了，编译阶段都不会"慢慢暴露"—— 直接 make download 就挂。
  if [[ "$stack" == "honk" ]]; then
    if grep -qx "CONFIG_PACKAGE_honk=y" "$TREE/.config" 2>/dev/null &&
       grep -qx "CONFIG_PACKAGE_luci-app-honk=y" "$TREE/.config" 2>/dev/null; then
      ok "$case：honk + luci-app-honk（doona 面板）都进了 .config"
    else
      bad "$case：honk / luci-app-honk 不在 .config 里"; bads=1
    fi
    if [[ -s "$TREE/feeds/small/honk/generated-stage.mk" &&
          -s "$TREE/feeds/small/luci-app-honk/generated-doona-stage.mk" ]]; then
      ok "$case：generated-stage.mk / generated-doona-stage.mk 已补齐"
    else
      bad "$case：honk 的构建元数据没补齐（make download 必挂）"; bads=1
    fi
    # 出厂配置：必须 include system.dae（native_api + doona 面板靠它）
    if [[ -f "$TREE/files/etc/honk/config.dae" ]] &&
       grep -qE '^[[:space:]]*system\.dae[[:space:]]*$' "$TREE/files/etc/honk/config.dae"; then
      ok "$case：honk 出厂 config.dae 已落位，且 include system.dae"
    else
      bad "$case：honk 出厂 config.dae 缺失或没 include system.dae（doona 面板会 404）"; bads=1
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
log "基座树：$TREE（NSS 指纹：$([[ $HAS_PPE_SEED == 1 ]] && echo ppe-nss 整树 || echo 上游树)）"
log "仓库：$BUILDER_DIR"
hr

for c in "${CASES[@]}"; do
  # 树与组合的一致性先做一次快速检查，省得白跑 2 分钟
  if [[ "$c" == "nss" && $HAS_PPE_SEED -eq 0 ]]; then
    bad "组合 nss 需要 ppe-nss 整树，但 $TREE 不是（缺少 seeds/qualcommax-nss-wifi.seed）"
    fail=$((fail+1)); FAILED+=("$c"); continue
  fi
  # nss-imm 要求上游树：ppe-nss 整树跑这条没有意义（组件本来就在树里）
  if [[ "$c" == "nss-imm" && $HAS_PPE_SEED -eq 1 ]]; then
    bad "组合 nss-imm 需要上游树（imm / openwrt main），但 $TREE 是 ppe-nss 整树"
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
