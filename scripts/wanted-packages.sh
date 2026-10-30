#!/usr/bin/env bash
#
# 输出「当前变体应该进固件的包清单」——一行一个包名。
#
# 这段清单以前硬编码在 11 个 workflow 里，每条线抄一份，共 4 套几乎相同的
# 列表（dae / daed / homeproxy / sing-box / passwall2 各一份）。现在按
# 「恒定项 + NSS + 代理栈」拼装，改一处全局生效。
#
# 用法（workflow 的「校验功能包」步骤调用）：
#   DISTRO=immortalwrt NSS=0 PROXY_STACK=daed bash scripts/wanted-packages.sh
#
# 列进来的判据是「缺了它功能就不完整」，不是「编出来就行」：
#   · daed 缺 kmod-sched-bpf       → eBPF 程序挂不上，分流不生效
#   · homeproxy 缺 ucode-mod-math  → 刷进去起不来，报 module 'math' 找不到
#   · NSS 缺 kmod-nss-wifi-drv     → 选 NSS 等于没选，Wi-Fi 还在 CPU 上跑
#
# ⚠️ NSS 相关的包名分两代，不要混：
#   老 edma-nss 栈：kmod-qca-nss-drv / kmod-qca-nss-ecm / nssqos / nss-tools
#   新栈（整树与 imm 移植都是它）：kmod-nss-wifi-drv / nss-firmware-ipq807x
#   本脚本只跟新栈。NSS=1 现在有两条实现（openwrt 整树 / imm 移植），
#   但两者产出的包名完全一样：驱动包都叫 kmod-nss-wifi-drv，固件都来自
#   nss-packages feed。所以这里不需要按基座分支。
#
set -Eeuo pipefail

DISTRO="${DISTRO:-immortalwrt}"
NSS="${NSS:-0}"
PROXY_STACK="${PROXY_STACK:-daed}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

out=()
add() { out+=("$@"); }

# ── 恒定项：不管基座 / NSS / 代理栈，四样都带 ──────────────────────
# msd_lite / ddns-go 用本仓库自带配方（构建时解析上游最新版本）；
# 它们的 LuCI 前端从 ImmortalWrt 稀疏检出，所以包名固定。
add msd_lite luci-app-msd_lite luci-i18n-msd_lite-zh-cn
add ddns-go luci-app-ddns-go luci-i18n-ddns-go-zh-cn
add wireguard-tools luci-proto-wireguard kmod-wireguard
# qrencode：WireGuard 客户端页与订阅链接的二维码，靠它渲染。
add qrencode

# ── NSS：只有 ppe-nss 整树才有 ─────────────────────────────────────
if [[ "$NSS" == "1" ]]; then
  add kmod-nss-wifi-drv
  add nss-firmware-ipq807x
  # 注：qca-ppe-qos / ppe-help 故意不列。
  # 它们在树里的包名可能随 PR 调整，列错会让校验红在"找不到包"而不是
  # "功能缺失"上 —— 那种误报比漏报更耗时间。它们的可用性由
  # prepare-build.sh 的符号校验负责（seed 里写了 CONFIG_PACKAGE_*=y，
  # 被 defconfig 丢掉就当场 die，比这里更早也更准）。
fi

# ── 代理栈 ────────────────────────────────────────────────────────
case "$PROXY_STACK" in
  daed)
    # 逐个都是硬需求：
    #   daed / luci-app-daed     主程序 + 三个页面
    #   daed-geoip / daed-geosite 把 geo 数据软链到 /usr/share/daed/
    #   kmod-sched-core          sch_ingress（clsact，dae 挂程序的钩子点）
    #   kmod-sched-bpf           cls_bpf + act_bpf（内核侧分流动作）
    #   kmod-veth                配方 DEPENDS 点名
    #   kmod-xdp-sockets-diag    DEPENDS 是 @KERNEL_XDP_SOCKETS，符号没开就不编
    # 故意没有 sing-box / homeproxy / kmod-nft-tproxy：daed 不走 TPROXY、
    # 不生成 sing-box 配置、不劫持 dnsmasq。
    add daed luci-app-daed luci-i18n-daed-zh-cn
    add daed-geoip daed-geosite v2ray-geoip v2ray-geosite
    add kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag
    ;;
  dae)
    add dae luci-app-dae luci-i18n-dae-zh-cn
    add dae-geoip dae-geosite v2ray-geoip v2ray-geosite
    add kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag
    ;;
  homeproxy)
    # ucode-mod-math 是必须的：homeproxy 的 generate_client.uc 第 11 行
    # `import { isnan } from 'math'`，而上游 LUCI_DEPENDS 漏声明了这个模块。
    # 少了它固件刷进去 HomeProxy 直接起不来。
    add luci-app-homeproxy luci-i18n-homeproxy-zh-cn
    add sing-box kmod-nft-tproxy ucode-mod-digest ucode-mod-math
    ;;
  singbox)
    # 无前端，清单很短，但每一项都是硬前提：
    #   sing-box        内核本体
    #   kmod-tun        tun 入站的设备节点，缺了启动即报错
    #   kmod-inet-diag  auto_redirect / 进程匹配依赖 inet_diag
    add sing-box kmod-tun kmod-inet-diag
    ;;
  passwall2)
    # v2（ucode 界面）。核心只留 sing-box —— configs/common.config 里
    # Basic_Core_SingBox=y、xray 不选，所以这里也不列 xray-core。
    add luci-app-passwall2 luci-i18n-passwall2-zh-cn
    add sing-box shadowsocks-rust-sslocal
    add chinadns-ng geoview tcping
    add v2ray-geoip v2ray-geosite shadowsocksr-libev-ssr-local
    add simple-obfs-client v2ray-plugin haproxy lyaml
    add dnsmasq-full kmod-nft-tproxy kmod-nft-socket
    ;;
  passwall)
    # v1（Lua CBI 界面）。与 v2 的差别全部来自它的 LUCI_DEPENDS 与配方里的
    # select，逐条对应（configs/passwall.config）：
    #   xray-core + unzip   INCLUDE_Xray（v1 的核心按节点选，默认带 Xray）
    #   dns2socks           老式 socks 转发，v1 的 LUCI_DEPENDS 点名要它
    #   microsocks          SOCKS5 服务端，同上
    #   ipt2socks           nftables/iptables 两条透明代理通道都 select 它
    #   nftables            v1 的 nft 模式直接调 nft 命令（v2 走 ucode 封装）
    #   shadowsocksr-libev-ssr-redir  INCLUDE_ShadowsocksR_Libev_Client 一起 select
    #   luci-compat + lua   v1 是 Lua CBI 界面，缺了页面直接 404
    # 故意不列：kmod-nf-reject / kmod-nf-reject6（内核心基础项，恒在）、
    #           coreutils* / resolveip（base 里的常驻小包）。
    add luci-app-passwall luci-i18n-passwall-zh-cn
    add xray-core sing-box unzip
    add shadowsocks-rust-sslocal
    add chinadns-ng dns2socks microsocks geoview tcping lyaml ip-full
    add v2ray-geoip v2ray-geosite
    add shadowsocksr-libev-ssr-local shadowsocksr-libev-ssr-redir
    add simple-obfs-client v2ray-plugin haproxy
    add dnsmasq-full nftables ipt2socks
    add kmod-nft-tproxy kmod-nft-socket kmod-nft-nat
    add luci-compat lua
    ;;
  honk)
    # honk 也是 eBPF 内核态分流的引擎（dae 那一支），清单与 dae / daed 高度
    # 重合，差别只有两处：
    #   ① 核心与面板来自 kenzok8/small —— honk + luci-app-honk，后者把 doona
    #      静态面板装进 /usr/share/doona（不是独立的 doona 包，别去找它）；
    #   ② UDP 首包暂存走 NFQUEUE（kmod-nft-queue 带出 nfnetlink_queue），
    #      dae / daed 没有这一条。
    # 这些全是 honk/files/control.sh 的 check_kernel 逐个点名要 modprobe 的
    # 模块：sch_ingress / cls_bpf / veth / nft_queue / nfnetlink_queue，
    # 缺一个面板初始化就报 kernel module unavailable。
    add honk luci-app-honk
    add v2ray-geoip v2ray-geosite
    add kmod-sched-core kmod-sched-bpf kmod-veth kmod-nft-queue
    # curl：honk 的 initialize_preflight 里是硬检查（command -v curl），
    # 但配方 DEPENDS 没写它 —— 靠 common.config 的 =y 兜着，这里列出来一起验。
    add curl ip-full
    ;;
  none|"")
    ;;
  *)
    printf '不认识的 PROXY_STACK：%s\n' "$PROXY_STACK" >&2
    exit 2
    ;;
esac

# ── 统计页（每条线都带）──────────────────────────────────────────
add luci-app-statistics luci-i18n-statistics-zh-cn
add collectd-mod-thermal rrdtool1 autocore

# ── 额外插件（kenzok8/small 里按需取）────────────────────────────
# 只做去重，不做存在性判断：判断由 workflow 的产物校验负责。
if [[ -n "$EXTRA_PACKAGES" ]]; then
  IFS=', ' read -r -a _extra <<<"$EXTRA_PACKAGES"
  for p in "${_extra[@]}"; do
    [[ -n "$p" ]] && add "$p"
  done
fi

printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
