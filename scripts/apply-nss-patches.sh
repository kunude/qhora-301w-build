#!/usr/bin/env bash
#
# 把 NSS 支持移植进 immortalwrt 源码树。
#
# ── 为什么要有这个脚本 ──────────────────────────────────────────
# NSS（Qualcomm Network Subsystem 硬件卸载）**不在** OpenWrt / ImmortalWrt
# 上游：它是一整套内核补丁 + 一堆包（驱动 / ECM / qdisc / 固件），
# 需要碰 EDMA、PPE、DTS、mac80211、ath11k、ipmr、nat46、iproute2。
#
# 老两条线（build-qhora-301w.yml / -homeproxy.yml）用的是现成的基座：
#   JuliusBairaktaris/openwrt-nss-edma @ nss-edma-rework
# 那个仓库本身就是「openwrt main + NSS」，拿来就能编。
# 但它在 2026-10-10 之后被作者**归档**了（该分支 README 首行：
# "This branch is archived. It carried the vendor NSS stack ... and is no
#  longer updated or built."），默认分支已迁到 openwrt-ppe-nss。
# 归档意味着基座（内核 / 驱动 / DTS / LuCI）从此不再跟上游走。
#
# 本脚本做的就是把这层关系拆开：
#      基座  ← 活的 immortalwrt（内核、DTS、驱动、feed 持续更新）
#      NSS   ← patches/immortalwrt-nss/ 里那一份**固定**的补丁集
# 补丁文件的来源、基线、再生成方法见 patches/immortalwrt-nss/README.md。
#
# ── 只做三件事 ──────────────────────────────────────────────────
#   1. 身份校验：确认 OPENWRT_DIR 真的是 ImmortalWrt 源码树、且带 qualcommax
#      目标 —— 把补丁打到 openwrt/openwrt 或别的树上不会报错，只会编出怪东西，
#      所以这里先卡住。
#   2. 应用补丁（幂等）：已经打过的补丁反向能干净应用 ⇒ 跳过，重跑不炸。
#      先 git apply（报错准确），失败再 patch -p1 兜底（对上下文漂移宽容些）。
#   3. 断言 NSS 关键件真的就位：13 个补丁、152 个新增文件，任何一个没落地都
#      会在几十分钟后才以晦涩的方式炸掉（或者更糟：静默编出一份没有 NSS 的固件）。
#      所以这里按「文件存在 + 关键字符串在位」逐条确认，缺一条即中断。
#
# ── 环境变量 ────────────────────────────────────────────────────
#   OPENWRT_DIR   已检出的 immortalwrt 源码目录（必需）
#   BUILDER_DIR   本仓库的检出目录（必需）
#
# ── 与其他脚本的关系 ────────────────────────────────────────────
# 本脚本**只改源码树**，不碰 feed、不碰 .config。跑完之后由
# scripts/prepare-build-imm-nss.sh 接手，转交 scripts/prepare-build.sh
# 走与老两条线完全相同的那套编排。
#
set -Eeuo pipefail

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
BUILDER_DIR="${BUILDER_DIR:?BUILDER_DIR 未设置}"
NSS_PATCH_DIR="$BUILDER_DIR/patches/immortalwrt-nss"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# 与 prepare-build.sh 不同：这个脚本跑在它**之前**，此时 fd3 还没建立，
# 所以注解直接写 stdout —— GitHub 一样会解析成 check-run annotation。
# 失败时把「出错点 + 怎么查」放在最后输出，前面那些注解不会被配额挤掉。
ann() { printf '%s\n' "$*"; }
die() {
  local msg="$1"; shift
  printf '\033[1;31m[x]\033[0m %s\n' "$msg" >&2
  printf '::error::%s\n' "$msg"
  local x
  for x in "$@"; do printf '::error::  %s\n' "$x"; done
  exit 1
}

# ── 0. 身份与前置校验 ─────────────────────────────────────────────
[[ -d "$OPENWRT_DIR" ]] || die "OPENWRT_DIR 不是有效目录：$OPENWRT_DIR"
[[ -d "$NSS_PATCH_DIR" ]] || die "本仓库里找不到 NSS 补丁目录：$NSS_PATCH_DIR"

# 只看一个字符串不够：openwrt/openwrt 的 include/version.mk 里没有 ImmortalWrt，
# 而 ImmortalWrt 的里面有几个 —— 用它做「基座是不是 ImmortalWrt」的判据。
grep -q 'ImmortalWrt' "$OPENWRT_DIR/include/version.mk" 2>/dev/null \
  || die "OPENWRT_DIR 看起来不是 ImmortalWrt 源码树（include/version.mk 里没有 ImmortalWrt）" \
         "本线的基座必须是 https://github.com/immortalwrt/immortalwrt" \
         "老两条线（nss-edma fork 基座）请走 build-qhora-301w.yml，不要用这个入口"

[[ -f "$OPENWRT_DIR/target/linux/qualcommax/image/ipq807x.mk" ]] \
  || die "源码树里没有 qualcommax/ipq807x target：$OPENWRT_DIR/target/linux/qualcommax/image/ipq807x.mk"

# 基座版本：不打补丁就编不出 NSS，所以补丁只对「它相对 openwrt main 没大改」
# 的树成立。把这个版本打进日志，出问题时一眼能看出编的是哪一版。
base_commit="$(git -C "$OPENWRT_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
base_subject="$(git -C "$OPENWRT_DIR" log -1 --format='%cs %s' 2>/dev/null || echo '?')"
log "基座（ImmortalWrt）：$base_commit · $base_subject"
ann "::notice title=基座源码::immortalwrt/immortalwrt @ ${base_commit}（${base_subject}）"

cd "$OPENWRT_DIR"

# ── 1. 应用补丁 ──────────────────────────────────────────────────
# 补丁集里每一条都记着它与上游的对应版本；跑之前把来源发成注解，
# 这样"这次编出来的 NSS 到底是哪一份"是公开可追溯的（作业日志要登录才能看）。
if [[ -f "$NSS_PATCH_DIR/provenance.env" ]]; then
  # shellcheck disable=SC1091
  . "$NSS_PATCH_DIR/provenance.env"
  ann "::notice title=NSS 补丁集::${NSS_FORK_REPOSITORY}@${NSS_FORK_BRANCH} 提交 ${NSS_FORK_COMMIT:0:10} 相对 ${NSS_BASE_REPOSITORY}@${NSS_BASE_COMMIT:0:10} 的全部改动"
  # 这条是给"补丁打不上"那天用的：把这行里的提交填进工作流输入 imm_ref，
  # 一定打得中（这一版是完整编译验证过的）。
  [[ -n "${IMM_VERIFIED_COMMIT:-}" ]] && ann \
    "::notice title=NSS 补丁验证过的基座::immortalwrt @ ${IMM_VERIFIED_COMMIT:0:10}（${IMM_VERIFIED_DATE}，完整编译通过；补丁打不上时可把 imm_ref 钉到这里）"
fi

shopt -s nullglob
patches=( "$NSS_PATCH_DIR"/*.patch )
shopt -u nullglob
((${#patches[@]})) || die "补丁目录里没有 .patch 文件：$NSS_PATCH_DIR"

applied=0
skipped=0
for p in "${patches[@]}"; do
  name="$(basename "$p")"

  # 幂等：能反向干净应用 ⇒ 这份补丁已经在树里了。重跑（或本地反复试）不会炸。
  if git apply --reverse --check "$p" >/dev/null 2>&1; then
    log "已应用过，跳过：$name"
    skipped=$((skipped + 1))
    continue
  fi

  # 首选 git apply：它按整份补丁做原子检查，失败就一个字都不落，
  # 报错信息里直接给出「哪个文件、哪一段上下文对不上」，便于远程定位。
  # --whitespace=nowarn 只是不打印"空格混缩进"这类噪音警告（不会改文件内容：
  # 要用 --whitespace=fix 才会改，我们不用那个）。
  if git apply --whitespace=nowarn "$p" >/tmp/nss-apply.err 2>&1; then
    log "已应用：$name"
    applied=$((applied + 1))
    continue
  fi

  # 兜底：patch(1) 对上下文漂移更宽容（--fuzz 允许偏移几行）。
  # 先 --dry-run 整体预演，成功才真打 —— 避免 patch 打一半留下 .rej 残局。
  if patch -p1 --dry-run -N --forward --fuzz=3 < "$p" >/tmp/nss-patch-dry.err 2>&1; then
    patch -p1 -N --forward --fuzz=3 < "$p" >/tmp/nss-patch.err 2>&1 \
      || die "patch -p1 预演通过但实际应用失败：$name" \
             "$(tail -n 5 /tmp/nss-patch.err 2>/dev/null || true)"
    warn "git apply 失败，已用 patch -p1 --fuzz=3 兜底应用：$name"
    applied=$((applied + 1))
    continue
  fi

  # 两条路都走不通：把「哪个文件对不上」逐个报出来，再给结论。
  failed_files="$(
    git apply --check -v "$p" 2>&1 \
      | sed -n 's/^error: \(.*\): patch does not apply$/\1/p' \
      | sort -u
  )"
  # shellcheck disable=SC2086
  die "NSS 补丁应用失败：$name" \
      "（git apply 与 patch -p1 都失败，下面列出对不上的文件）" \
      $failed_files \
      "最常见的原因是基座往前走了：immortalwrt 改了这些文件，补丁的上下文对不上。" \
      "出路：① 把工作流输入 imm_ref 钉到本次验证过的提交；" \
      "      ② 按新的上下文重新生成补丁（方法见 patches/immortalwrt-nss/README.md）。"
done

log "补丁处理完成：新应用 ${applied} 份，跳过 ${skipped} 份"

# ── 2. 断言 NSS 关键件真的就位 ────────────────────────────────────
# 补丁"应用成功"与"固件里真的有 NSS"是两件事。下面按「文件在不在 +
# 关键字符串在不在」逐条确认 —— 这些是 NSS 卸载能起来的必要条件，
# 少任何一条都必须在构建开始前就中断，而不是等一小时后编出一份没有 NSS 的固件。
log "断言 NSS 关键件是否就位"

# 2-a 补丁新增的文件（在树里 = 补丁确实落地了）
must_exist=(
  # NSS 运行期工具 + LuCI 页面（本线新增的包，common.config 里选了 nss-tools）
  package/nss/nss-tools/Makefile
  # NSS 数据面胶水（kmod-qca-ppe-nss，由 kmod-qca-nss-drv 自动拉入）
  package/kernel/qca-ppe-nss/Makefile
  # 设备树的 NSS 节点：301w 用 ipq8074 那份
  target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq8074-nss.dtsi
  target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-nss.dtsi
  # ECM / PPPoE / DSCPREMARK / 网桥 VLAN / qdisc / 组播 MFC 卸载
  target/linux/qualcommax/patches-6.18/0960-qca-nss-ecm-support-CORE.patch
  target/linux/qualcommax/patches-6.18/0961-qca-nss-ecm-support-PPPOE-offload.patch
  target/linux/qualcommax/patches-6.18/0963-qca-nss-ecm-support-netfilter-DSCPREMARK.patch
  target/linux/qualcommax/patches-6.18/0969-qca-nss-clients-add-qdisc-support.patch
  target/linux/qualcommax/patches-6.18/0971-net-ipmr-ip6mr-add-MFC-offload-hooks.patch
  # 内核侧的 conntrack DSCP 扩展头 + lib/crypto 放开（NSS crypto 要）
  target/linux/qualcommax/files/include/net/netfilter/nf_conntrack_dscpremark_ext.h
  target/linux/qualcommax/files/net/netfilter/nf_conntrack_dscpremark_ext.c
  target/linux/generic/hack-6.18/262-lib-crypto-unhide.patch
  # nat46 的 MAP-T 导出（ECM 卸载用）
  package/kernel/nat46/patches/102-mapt.patch
  # iproute2 的 NSS qdisc / nssmirred
  package/network/utils/iproute2/patches/400-add-nss-qdisc.patch
  package/network/utils/iproute2/patches/500-add-nssmirred.patch
)
missing=()
for f in "${must_exist[@]}"; do
  [[ -e "$f" ]] || missing+=("$f")
done
if ((${#missing[@]})); then
  die "NSS 补丁没落全，缺 ${#missing[@]} 个关键文件（补丁应用不完整）" "${missing[@]}"
fi
log "  补丁新增的关键文件全部就位（${#must_exist[@]} 项）"

# 2-b 被补丁修改的文件里，关键字符串必须在位。
#     文件"存在"不代表内容被改对了 —— 比如 ath.mk 少加了 ATH11K_NSS_SUPPORT，
#     符号校验就会报"defconfig 丢弃了 NSS 符号"，那时才知道就太晚了。
declare -a must_grep=(
  # ath11k / mac80211 的 NSS Wi-Fi 卸载开关。缺了它，CONFIG_ATH11K_NSS_SUPPORT
  # 与 CONFIG_PACKAGE_MAC80211_NSS_SUPPORT 在 kconfig 里压根不存在 ——
  # 而 common.config 里选着它们，校验必然失败（或更糟：静默被丢）。
  "package/kernel/mac80211/ath.mk:ATH11K_NSS_SUPPORT"
  "package/kernel/mac80211/Makefile:MAC80211_NSS_SUPPORT"
  # 301w 自己的设备树必须引到 NSS 节点，否则 NSS 数据面没有硬件描述可依
  "target/linux/qualcommax/dts/ipq8072-301w.dts:ipq8074-nss.dtsi"
  # 内核配置：ECM 的 conntrack DSCP 标记扩展
  "target/linux/qualcommax/config-6.18:NF_CONNTRACK_DSCPREMARK_EXT"
  # NSS 数据面共享 EDMA/PPE：驱动里必须有 NSS 相关的钩子
  "target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/qca_edma.c:nss"
  "target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/qca_ppe_main.c:nss"
  # mac80211/ath11k 的 NSS 补丁目录（下面再单独数数量）
  "package/kernel/mac80211/files/qca-nss-pbuf.init:nss"
)
grep_fail=()
for ent in "${must_grep[@]}"; do
  file="${ent%%:*}"; pat="${ent#*:}"
  [[ -f "$file" ]] || { grep_fail+=("$file（文件不存在）"); continue; }
  grep -qi -- "$pat" "$file" || grep_fail+=("$file 里找不到 '$pat'")
done
if ((${#grep_fail[@]})); then
  die "NSS 补丁改的文件内容不对，${#grep_fail[@]} 项缺失" "${grep_fail[@]}"
fi
log "  关键文件内容校验通过（${#must_grep[@]} 项）"

# 2-c mac80211 的 NSS 补丁是一整个目录（80 个补丁，Wi-Fi 卸载的核心）。
#     数量只是"目录没被清空/没被打断"的粗校验；真正的正确性由编译与
#     产物校验负责。阈值取 50：比实际值低一截，避免上游增删几个补丁就误报。
nss_patch_n="$(find package/kernel/mac80211/patches/nss -type f -name '*.patch' 2>/dev/null | wc -l)"
((nss_patch_n >= 50)) \
  || die "mac80211 的 NSS 补丁目录里只有 ${nss_patch_n} 个补丁（期望 ≥50），补丁集不完整" \
         "package/kernel/mac80211/patches/nss"
log "  mac80211 NSS 补丁：${nss_patch_n} 个"

log "NSS 移植完成：源码树已具备 NSS 卸载能力（数据面 + ECM + Wi-Fi 卸载 + qdisc + 运行期工具）"
