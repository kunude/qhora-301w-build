#!/usr/bin/env bash
#
# 把 NSS 的 Wi-Fi 卸载支持移植到「不是 ppe-nss 整树」的基座上
# （immortalwrt / openwrt main 都能用）。ppe-nss 树里它是四样东西，逐样搬：
#
#   ① package/kernel/nss-wifi-drv
#      NSS 固件宿主驱动 + `/etc/config/nss-wifi` + 开机脚本。DEPENDS 里有
#      `nss-firmware`（feed 提供）和 `kmod-nft-bridge`（flowtable 要用）。
#   ② package/kernel/mac80211/patches/nss-wifi/*.patch
#      18 个补丁：ath11k 把数据面 ring 描述给 NSS 固件、mac80211 侧的四个
#      回调（mesh 路径表镜像、AP isolation 通知）。
#   ③ mac80211 的 Makefile / ath.mk 里那几行挂钩
#      没有它们补丁根本不会被应用、`kmod-nss-wifi-drv` 也不会被依赖带出来。
#      症状是「一切正常、固件照出」，只是 Wi-Fi 还在 CPU 上 —— 所以本脚本
#      的每一步之后都要回读断言，锚点对不上就当场失败。
#   ④ 内核侧：EDMA/PPE 驱动 + NSS 的 reserved-memory
#      驱动不是只跟 mac80211 打交道，它直接调内核里 qca_edma / qca_ppe 的
#      导出符号（`qca_edma_cpu_queues_to_ring`、`qca_ppe_fw_booted`、
#      `qca_ppe_fw_carrier_set`）—— 让 NSS 固件和 host 共用接收 ring、把
#      flow 交给固件处理。这几个函数在上游 main 里**不存在**：上游的 qca_edma
#      走的是另一套（DSA switch ops + flow offload），同名头文件的路径和内容
#      都不同。所以内核侧也得换。
#
# 为什么内核侧是「整块覆盖」而不是打补丁：两边是同一条基线的两个快照，
# ppe-nss 那边就是在这份代码上加 NSS 支持 —— 实测差集约 300 行新增、删改
# 不到 40 行。打补丁要维护十几个 hunk 的上下文，覆盖只要 7 个文件。
#
# 为什么是「插入几行」而不是整份抄 ppe-nss 的 Makefile / ath.mk：
# imm 自己还带着 ath10k-sdio 等差异，整份抄会把 imm 的东西抹掉；而且两份
# 文件里跟 NSS 无关的漂移会变成无谓的冲突源。锚点插入 + 断言命中，改动
# 面最小，漂移时也只会红在「锚点没了」而不是悄悄少一行。
#
# 环境变量：
#   OPENWRT_DIR   目标树（必需）
#   NSS_WIFI_REF  从 ppe-nss 的哪个 ref 取（默认 ppe-nss，可传 sha）
#   NSS_WIFI_SRC  取下来的源码放哪（默认 $RUNNER_TEMP/nss-wifi-src，可复用）
#   NSS_DTS       给哪个设备 dts 加 NSS 引用（默认 ipq8072-301w）
#
# ⚠️ 只做移植，不做编译。能不能编过由后面的 `make` 说了算。
set -Eeuo pipefail

OPENWRT_DIR="${OPENWRT_DIR:?OPENWRT_DIR 未设置}"
NSS_WIFI_REF="${NSS_WIFI_REF:-ppe-nss}"
NSS_WIFI_SRC="${NSS_WIFI_SRC:-${RUNNER_TEMP:-/tmp}/nss-wifi-src}"
NSS_DTS="${NSS_DTS:-ipq8072-301w}"
UPSTREAM="https://github.com/JuliusBairaktaris/openwrt-ppe-nss.git"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

MAC="$OPENWRT_DIR/package/kernel/mac80211"

[[ -d "$OPENWRT_DIR" ]] || die "目标树不存在：$OPENWRT_DIR"
[[ -f "$MAC/Makefile" && -f "$MAC/ath.mk" ]] || die "$MAC 里没有 Makefile / ath.mk —— 这不是带 mac80211 包的 OpenWrt 树"

# 整树里这三样本来就有，再跑一遍只会把上游那份覆盖成我们的补丁副本。
# 重复跑（同一棵树先 prepare 过一次）也在这里收口 —— 移植是幂等的，但重新
# 取源没有意义，只会浪费一次网络往返。
if [[ -f "$OPENWRT_DIR/seeds/qualcommax-nss-wifi.seed" ]]; then
  log "检出的是 ppe-nss 整树（有 seeds/qualcommax-nss-wifi.seed），跳过移植"
  exit 0
fi
if [[ -d "$OPENWRT_DIR/package/kernel/nss-wifi-drv" ]]; then
  log "树里已经有 package/kernel/nss-wifi-drv（本脚本上次跑过），跳过移植"
  exit 0
fi

[[ -d "$OPENWRT_DIR/target/linux/qualcommax" ]] ||
  die "树里没有 target/linux/qualcommax —— NSS 只对 qualcommax 有意义"

# ── 基线一致性 ───────────────────────────────────────────────
# 补丁是按 backports 7.2 生成的。基座跳到别的 backports 版本时，补丁上下文
# 对不上，后面 `make` 会在解包阶段报 "patch does not apply" —— 那个报错离
# 根因很远（看起来像网络问题或补丁坏了）。在这里先比一句版本，失败信息才
# 指得准：要跟上 ppe-nss，不是改这里。
basever="$(sed -n 's/^PKG_SOURCE_VERSION:=//p' "$MAC/Makefile" | head -n1)"
[[ "$basever" == "7.2" ]] ||
  die "mac80211 backports 版本是 ${basever:-未知}，本移植按 7.2 生成 —— 先跟 ppe-nss 对齐再说"

# ── 取源码：稀疏检出，只要用得上的路径 ────────────────────────
# 整树 clone 是 ~110MB，这里只取驱动包、补丁、以及内核侧那几个文件（几十个
# 小文件），靠 --filter=blob:none + sparse-checkout 把无关的 blob 全挡掉。
log "取 NSS 组件：$UPSTREAM@$NSS_WIFI_REF"
rm -rf "$NSS_WIFI_SRC"
mkdir -p "$NSS_WIFI_SRC"
git -C "$NSS_WIFI_SRC" init -q
git -C "$NSS_WIFI_SRC" remote add origin "$UPSTREAM"
git -C "$NSS_WIFI_SRC" config core.sparseCheckout true
printf '%s\n' \
  "package/kernel/nss-wifi-drv/" \
  "package/kernel/mac80211/patches/nss-wifi/" \
  "target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/" \
  "target/linux/qualcommax/files/include/linux/soc/" \
  "target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq8074-nss.dtsi" \
  "target/linux/qualcommax/dts/$NSS_DTS.dts" \
  >"$NSS_WIFI_SRC/.git/info/sparse-checkout"
git -C "$NSS_WIFI_SRC" fetch -q --depth 1 --filter=blob:none origin "$NSS_WIFI_REF"
git -C "$NSS_WIFI_SRC" checkout -q FETCH_HEAD
log "  对应提交：$(git -C "$NSS_WIFI_SRC" log -1 --format='%h %cs %s' | cut -c1-80)"

src_drv="$NSS_WIFI_SRC/package/kernel/nss-wifi-drv"
src_pat="$NSS_WIFI_SRC/package/kernel/mac80211/patches/nss-wifi"
src_kern="$NSS_WIFI_SRC/target/linux/qualcommax"
[[ -f "$src_drv/Makefile" ]] || die "取不到 $src_drv/Makefile（ref 选错了？）"
[[ -d "$src_pat" ]] || die "取不到 $src_pat（ref 选错了？）"
[[ -f "$src_kern/files/drivers/net/ethernet/qualcomm/qca_edma.c" ]] ||
  die "取不到内核侧的 qca_edma.c（ref 选错了？）"

# ── ① 驱动包 ─────────────────────────────────────────────────
log "安装 package/kernel/nss-wifi-drv"
rm -rf "$OPENWRT_DIR/package/kernel/nss-wifi-drv"
cp -a "$src_drv" "$OPENWRT_DIR/package/kernel/nss-wifi-drv"

# ── ② 补丁 ───────────────────────────────────────────────────
log "安装 mac80211/patches/nss-wifi"
mkdir -p "$MAC/patches/nss-wifi"
cp -a "$src_pat"/. "$MAC/patches/nss-wifi"/
n_patch=$(find "$MAC/patches/nss-wifi" -maxdepth 1 -name '*.patch' | wc -l)
(( n_patch >= 18 )) || die "只拿到 $n_patch 个 NSS 补丁（期望 ≥18）—— 取源不完整"
log "  补丁 $n_patch 个"

# 908（mesh 路径表镜像）的 hunk #2 拿 `ieee80211_recalc_dtim(sdata, …)` 当上下文。
# 上游 main 后来把它改成「每个 link 一份 DTIM」（imm 的 subsys/423 就是这个），
# 签名变成 `(&sdata->deflink, …)`，于是这一 hunk 对不上 —— 而 908 恰恰是 mesh
# 下 NSS 生效的那条线，不能跳过。改上下文两行即可，插入的内容不变。
if grep -rqs 'ieee80211_recalc_dtim(&sdata->deflink' "$MAC/patches/"; then
  python3 - "$MAC/patches/nss-wifi" <<'PY'
import sys, pathlib
d = pathlib.Path(sys.argv[1])
for p in d.glob("908-*.patch"):
    t = p.read_text(encoding="utf-8")
    old = "\tieee80211_recalc_dtim(sdata, drv_get_tsf(local, sdata));\n"
    new = "\tieee80211_recalc_dtim(&sdata->deflink, drv_get_tsf(local, sdata));\n"
    if old in t:
        p.write_text(t.replace(old, new, 1), encoding="utf-8")
        print(f"  适配 {p.name}：recalc_dtim 用 deflink 签名")
PY
fi

# ── ③ 挂钩 ───────────────────────────────────────────────────
# 全部按锚点插入，且带幂等判断：重复跑不会插两遍。
python3 - "$MAC" <<'PY'
import sys, pathlib, textwrap

mac = pathlib.Path(sys.argv[1])
mk = mac / "Makefile"
am = mac / "ath.mk"

def read(p):
    return p.read_text(encoding="utf-8")

def write(p, s):
    p.write_text(s, encoding="utf-8")

def insert_after(text, anchor, block, marker, path, what):
    """锚点后插入；marker 已在文里就跳过（幂等）；锚点不在就硬失败。"""
    if marker in text:
        print(f"  跳过（已存在）：{what}")
        return text
    if anchor not in text:
        sys.exit(f"[x] {path} 里找不到锚点（{what}）：{anchor!r}\n"
                 f"    基座漂移了，改本脚本的锚点，别绕过。")
    return text.replace(anchor, anchor + block, 1)

# ---- Makefile ----
t = read(mk)
t = insert_after(
    t, "PKG_BUILD_PARALLEL:=1\n",
    "PKG_BUILD_DEPENDS:=ATH11K_NSS_WIFI:nss-wifi-drv\n",
    "PKG_BUILD_DEPENDS:=ATH11K_NSS_WIFI:", "Makefile", "构建依赖")

t = insert_after(
    t, "ifneq ($(CONFIG_PACKAGE_kmod-cfg80211),)\n",
    """# NSS：ath11k 的 ring 描述结构由 nss-wifi-drv 装进 staging，kbuild 不会自己去找。
ifdef CONFIG_ATH11K_NSS_WIFI
  MAKE_OPTS += CFLAGS="-I$(STAGING_DIR)/usr/include/nss-wifi-drv -DCONFIG_NSS_WIFI_DRV=1"
endif

""",
    "CONFIG_NSS_WIFI_DRV=1", "Makefile", "staging 头文件路径")

t = insert_after(
    t, "\t$(call PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/ath11k,ath11k/)\n",
    "\t$(if $(CONFIG_ATH11K_NSS_WIFI),$(call PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/nss-wifi,nss-wifi/))\n",
    "$(PATCH_DIR)/nss-wifi,nss-wifi/)", "Makefile", "PatchDir")

t = insert_after(
    t, "\t$(call Quilt/RefreshDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/ath11k,ath11k/)\n",
    "\t$(if $(CONFIG_ATH11K_NSS_WIFI),$(call Quilt/RefreshDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/nss-wifi,nss-wifi/))\n",
    "Quilt/RefreshDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/nss-wifi", "Makefile", "Quilt/RefreshDir")
write(mk, t)

# ---- ath.mk ----
t = read(am)
t = insert_after(
    t, "\tCONFIG_ATH10K_THERMAL \\\n",
    "\tCONFIG_ATH11K_NSS_WIFI \\\n",
    "CONFIG_ATH11K_NSS_WIFI \\\n", "ath.mk", "PKG_CONFIG_DEPENDS")

# DEPENDS 是多行续行，不能"另起一行插入"（那会断成两句），只能把锚点行
# 本身换成「锚点行 + 续行符 + 新行」。
dep_anchor = "  +ATH11K_THERMAL:kmod-thermal +kmod-qcom-qmi-helpers\n"
dep_new = ("  +ATH11K_THERMAL:kmod-thermal +kmod-qcom-qmi-helpers \\\n"
           "  $(if $(DUMP),,$(if $(CONFIG_ATH11K_NSS_WIFI),+kmod-nss-wifi-drv))\n")
if "+kmod-nss-wifi-drv))" in t:
    print("  跳过（已存在）：ath11k 依赖")
elif dep_anchor not in t:
    sys.exit("[x] ath.mk 里找不到 ath11k 的 DEPENDS 末行 —— 基座漂移了")
else:
    t = t.replace(dep_anchor, dep_new, 1)

NSS_CONFIG = """
       config ATH11K_NSS_WIFI
               bool "Describe the data-path rings to the NSS firmware"
               depends on PACKAGE_kmod-ath11k
               depends on TARGET_qualcommax_ipq807x || TARGET_qualcommax_ipq60xx
               select PACKAGE_kmod-nss-wifi-drv
               help
                 The NSS cores can reap the WLAN hardware's rings
                 themselves, which takes the Wi-Fi data path off the host.
                 Say Y to have ath11k describe those rings to the NSS
                 firmware driver when its data path is set up.

"""
if "config ATH11K_NSS_WIFI" in t:
    print("  跳过（已存在）：ATH11K_NSS_WIFI 的 Kconfig 块")
else:
    head = "define KernelPackage/ath11k/config\n"
    i = t.find(head)
    if i < 0:
        sys.exit("[x] ath.mk 里找不到 KernelPackage/ath11k/config —— 基座漂移了")
    j = t.find("\nendef\n", i)
    if j < 0:
        sys.exit("[x] KernelPackage/ath11k/config 块没有结尾 endef")
    t = t[: j + 1] + NSS_CONFIG + t[j + 1 :]

for mod in ("ath11k_ahb", "ath11k_pci"):
    old = f"  AUTOLOAD:=$(call AutoProbe,{mod})\n"
    new = f"  AUTOLOAD:=$(if $(CONFIG_ATH11K_NSS_WIFI),,$(call AutoProbe,{mod}))\n"
    if new in t:
        print(f"  跳过（已存在）：{mod} 的 AUTOLOAD")
        continue
    if old not in t:
        sys.exit(f"[x] ath.mk 里找不到 {mod} 的 AUTOLOAD 行")
    t = t.replace(old, new, 1)

write(am, t)
print("  挂钩写入完成")
PY

# ── ④ 内核侧：EDMA / PPE 驱动 ────────────────────────────────
# nss-wifi-drv 直接调这几个导出符号：
#   qca_edma_cpu_queues_to_ring()  让 CPU 端队列避开固件独占的 ring
#   qca_edma_cpu_queues_to_host()   固件挂了把队列还回 host
#   qca_ppe_fw_booted()             固件起来后恢复 PPE 表
#   qca_ppe_fw_carrier_set()        决定 flow 走固件还是走 host
# 上游 main 里没有它们（那边的 qca_edma 是 DSA switch ops 那一套），所以
# 内核侧也得换。判据先查一遍：基座要是已经带了，说明上游吃进去了，别倒退。
KQF="$OPENWRT_DIR/target/linux/qualcommax/files/drivers/net/ethernet/qualcomm"
[[ -f "$KQF/qca_edma.c" ]] || die "$KQF 里没有 qca_edma.c —— qualcommax 树不该是这样"

if grep -q 'qca_edma_cpu_queues_to_ring' "$KQF/qca_edma.c"; then
  log "基座内核已自带 NSS 的 EDMA 接口，跳过内核侧覆盖"
else
  log "覆盖内核侧 EDMA/PPE 驱动（7 个文件）"
  for f in qca_edma.c qca_edma.h qca_ppe.h qca_ppe_flow.c \
           qca_ppe_flow_offload.c qca_ppe_main.c qca_ppe_scheduler.c; do
    [[ -f "$src_kern/files/drivers/net/ethernet/qualcomm/$f" ]] ||
      die "上游取不到 $f —— 文件清单和 ppe-nss 现在对不上了"
    cp -a "$src_kern/files/drivers/net/ethernet/qualcomm/$f" "$KQF/$f"
  done
  # 头文件路径也不同：上游在 include/linux/，NSS 版在 include/linux/soc/qcom/。
  mkdir -p "$OPENWRT_DIR/target/linux/qualcommax/files/include/linux/soc"
  cp -a "$src_kern/files/include/linux/soc/qcom" \
        "$OPENWRT_DIR/target/linux/qualcommax/files/include/linux/soc/"
fi

grep -q 'qca_edma_cpu_queues_to_ring' "$KQF/qca_edma.c" ||
  die "qca_edma.c 里没有 cpu_queues_to_ring —— 内核侧没换成功"
grep -rqs 'qca_ppe_fw_booted' "$KQF" ||
  die "内核侧找不到 qca_ppe_fw_booted —— PPE 固件接口没搬进来"

# ── ④b 设备树：NSS 的 reserved-memory ────────────────────────
# 驱动要从设备树拿 NSS 固件区的物理地址。上游的 301w dts 没有这一段，
# 只有一个 include 的差别（实测就一行）。
if [[ "$NSS_DTS" == ipq60* ]]; then dtsi=ipq6018-nss.dtsi; else dtsi=ipq8074-nss.dtsi; fi
dtsf="$OPENWRT_DIR/target/linux/qualcommax/dts/$NSS_DTS.dts"
[[ -f "$dtsf" ]] || die "$dtsf 不存在 —— NSS_DTS=$NSS_DTS 选错设备了？"
[[ -f "$src_kern/files/arch/arm64/boot/dts/qcom/$dtsi" ]] ||
  die "上游取不到 $dtsi"

mkdir -p "$OPENWRT_DIR/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom"
cp -a "$src_kern/files/arch/arm64/boot/dts/qcom/$dtsi" \
      "$OPENWRT_DIR/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
log "安装 $dtsi，并给 $NSS_DTS.dts 加引用"

python3 - "$dtsf" "$dtsi" <<'PY'
import sys, pathlib
p, dtsi = pathlib.Path(sys.argv[1]), sys.argv[2]
t = p.read_text(encoding="utf-8")
if dtsi in t:
    print(f"  跳过（已存在）：{dtsi}")
else:
    anchor = '#include "ipq8074.dtsi"\n' if dtsi.startswith("ipq8074") \
             else '#include "ipq6018.dtsi"\n'
    if anchor not in t:
        sys.exit(f"[x] {p.name} 里找不到锚点 {anchor!r} —— dts 结构漂移了")
    p.write_text(t.replace(anchor, anchor + f'#include "{dtsi}"\n', 1),
                 encoding="utf-8")
    print(f"  已插入 {dtsi}")
PY

grep -qF "$dtsi" "$dtsf" || die "$NSS_DTS.dts 里没有 $dtsi —— 设备树没挂上"

# ── 回读断言：写完的文件真的带上了这五处 ──────────────────────
check() { grep -qF "$2" "$1" || die "$1 里没有「$3」—— 挂钩没写进去"; }
check "$MAC/Makefile" "PKG_BUILD_DEPENDS:=ATH11K_NSS_WIFI:nss-wifi-drv" "构建依赖"
check "$MAC/Makefile" '$(call PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/nss-wifi,nss-wifi/)' "PatchDir"
check "$MAC/ath.mk" "config ATH11K_NSS_WIFI" "Kconfig 开关"
check "$MAC/ath.mk" "+kmod-nss-wifi-drv))" "ath11k 依赖 nss-wifi-drv"
check "$MAC/ath.mk" '$(if $(CONFIG_ATH11K_NSS_WIFI),,$(call AutoProbe,ath11k_ahb))' "ahb 不自启"

# 依赖关系是这套移植唯一的「顺序保证」：nss-wifi-drv 先装头文件，ath11k 后编。
grep -q 'PKG_BUILD_DEPENDS:=ATH11K_NSS_WIFI:nss-wifi-drv' "$MAC/Makefile" ||
  die "缺 PKG_BUILD_DEPENDS：ath11k 会在驱动装头文件之前开始编"

log "NSS 移植完成：$(du -sh "$OPENWRT_DIR/package/kernel/nss-wifi-drv" | cut -f1) 驱动 + $n_patch 个补丁 + 内核侧 EDMA/PPE + $dtsi"
