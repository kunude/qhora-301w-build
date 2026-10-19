# QHora-301W · OpenWrt NSS EDMA 自动编译

用 GitHub Actions 为 **QNAP QHora-301W**（`qualcommax` / `ipq807x` / `qnap_301w`）编译带
**Qualcomm NSS 硬件卸载**（NAT / PPPoE / SQM / 网桥 / ath11k Wi-Fi）的 OpenWrt 固件。

源码是 [`JuliusBairaktaris/openwrt-nss-edma`](https://github.com/JuliusBairaktaris/openwrt-nss-edma)
的 `nss-edma-rework` 分支 —— OpenWrt `main` 加上一整套跑在上游 `qca_edma` / `qca_ppe`
驱动之上的 NSS 支持（不使用 out-of-tree 的 `qca-nss-dp` / `qca-ssdk`）。

本仓库**不含 OpenWrt 源码**，只是一份"编译配方"：运行时拉上游源码、套上这里的配置来编。

## 两条并行构建线（只有代理栈不同）

| | **passwall2**（主线） | **HomeProxy** |
|---|---|---|
| 工作流 | `build-qhora-301w.yml` | `build-qhora-301w-homeproxy.yml` |
| 代理前端 | `luci-app-passwall2` + 17 个依赖组件 | `luci-app-homeproxy`（ImmortalWrt，单包自包含） |
| 代理核心 | `sing-box`（**不编 xray**）+ `sslocal` | `sing-box` **1.12.25**（ImmortalWrt 源） |
| 出厂预置 | 分流 / DNS / 转发 / URLTest 选路 | custom 三分流 / 分域 DNS / 订阅开关 |
| 构建耗时 | 长（要拉 Rust 工具链编 `sslocal`） | 短（无 Rust 依赖） |

其余完全一致：NSS 卸载栈、ddns-go、msd_lite、WireGuard、statistics、autocore、`files/` 覆盖、
target / device。两条线**共用同一个 `/usr/bin/sing-box` 与同一套 nftables 透明代理**，
所以一套固件里只能启用其中一个（固件里本来也只有其中一个）。

## 第三条线：immortalwrt 基座 + NSS 补丁

上面两条线的**基座**都是 [`JuliusBairaktaris/openwrt-nss-edma`](https://github.com/JuliusBairaktaris/openwrt-nss-edma)
的 `nss-edma-rework` 分支 —— 它本身就是「openwrt main + NSS」，拿来即用。
但那个分支**已被作者归档**（该分支 README 首行原文：*This branch is archived.
It carried the vendor NSS stack … and is no longer updated or built.*），
基座（内核 / DTS / 驱动 / mac80211 / LuCI）从此不再跟着上游走。

第三条线把「基座」与「NSS 改动」拆开：

| | 两条老线 | **imm-nss 线** |
|---|---|---|
| 工作流 | `build-qhora-301w.yml` / `build-qhora-301w-homeproxy.yml` | `build-qhora-301w-imm-nss.yml` |
| 基座源码 | `openwrt-nss-edma@nss-edma-rework`（已归档） | **`immortalwrt/immortalwrt`**（活的） |
| NSS 从哪来 | 基座自带 | `patches/immortalwrt-nss/` 的补丁集，构建时叠进源码树 |
| 代理栈 | passwall2 / HomeProxy | passwall2（HomeProxy 版是下面的第四条线） |
| NSS feed | `nss-packages@edma-nss` | **同一个**（feed 是独立包仓库，与基座无关） |
| 其余 | NSS 卸载栈、`configs/`、`files/`、产物结构 —— **三条线完全一致** | |

补丁集的来源（基线提交 / 来源分支 / 末端提交）、内容、**刻意排除的文件**、
以及**基座往前走之后怎么重新生成**，都写在
[`patches/immortalwrt-nss/README.md`](patches/immortalwrt-nss/README.md)。

补丁描述的是「NSS 相对 openwrt main 基线需要额外做什么」，所以它与基座是谁家的无关；
但它绑定在那份基线的上下文上。immortalwrt 改到补丁也要改的那些文件时，构建会在
「NSS 补丁应用失败」这一步**明确中断**，并逐个列出对不上的文件 ——
不会静默编出一份没有 NSS 的固件。那时要么把 `imm_ref` 钉回一个验证过的提交，
要么按上面那份 README 重新生成补丁。

> ⚠️ 固件**基座不同，不要混刷**。刷机方式与产物结构一样，但内核 / 驱动 / DTS
> 的来源不同（前两条线是 nss-edma fork，后两条是 immortalwrt），
> 建议每条线各留一份可回退的镜像。

## 第四条线：immortalwrt 基座 + NSS 补丁 + HomeProxy

第三条线只跑 passwall2。想要**活的基座 + 活的 HomeProxy**，就用第四条线 ——
它把第三条线的基座（`immortalwrt/immortalwrt` + NSS 补丁）与
`build-qhora-301w-homeproxy.yml` 的代理栈合在一起，**软件集与后者逐字一致**。

| | **imm-nss 线** | **imm-nss-homeproxy 线（本线）** |
|---|---|---|
| 工作流 | `build-qhora-301w-imm-nss.yml` | `build-qhora-301w-imm-nss-homeproxy.yml` |
| 基座 | `immortalwrt/immortalwrt` + `patches/immortalwrt-nss/` | **同一个** |
| 代理栈 | passwall2 | HomeProxy（`luci-app-homeproxy`） |
| sing-box | 基座 feed 自带 | 基座 feed 自带（**不降级**，见下） |
| dnsmasq | `dnsmasq-full`（passwall2 的 nftables 分支 select 进来的） | **`dnsmasq-full`**（见下） |
| 其余 | NSS 卸载栈、`files/` `files-homeproxy/` 覆盖、产物结构 —— 与各线一致 | |

> **关于 dnsmasq：** 第四条线这一格是 `dnsmasq-full`，但**不是我们加的** ——
> ImmortalWrt 的 `include/target.mk` 里 `DEFAULT_PACKAGES` 写的就是 `dnsmasq-full`
> （OpenWrt 官方写的是精简的 `dnsmasq`）。前两条线是从 nss-edma 基座起的，
> homeproxy 版又关掉了 passwall2 那条会 select `dnsmasq-full` 的链，
> 所以它们那里是精简 `dnsmasq`。换句话说：**换到 immortalwrt 基座之后，
> dnsmasq-full 是默认就有的** —— 不需要在 `configs/` 里额外写任何东西。

### 与前两条 homeproxy 线最大的不同：sing-box 不降版本

`build-qhora-301w-homeproxy.yml` 把 sing-box 钉在 **1.12.25**，是为了配**1.12.25 时代**的
HomeProxy 组合（legacy 写法在 1.14 上会 FATAL、`/etc/init.d/homeproxy` 据此 `return 1`，
服务起不来 —— 详见第五章）。

第四条线的基座是 immortalwrt，HomeProxy 与 sing-box 由**同一个上游**同步维护。
实测（2026-10-15，immortalwrt master `da63f7d6`）两者已经互相适配：

- `generate_client.uc` 的路由规则已是新版写法

      rules: [
          { inbound: 'dns-in', action: 'hijack-dns' },
          { action: 'sniff' }
      ]

  1.13 删掉的 inbound 字段 `sniff` / `sniff_override_destination` 上游已经删干净；
- 唯一残留的 `set_system_proxy: false` 是**合法字段**，不是 legacy —— sing-box
  1.14.3 源码 `option/simple.go:18` 的 `HTTPMixedInboundOptions` 里仍有
  `SetSystemProxy bool` 带着 `json:"set_system_proxy,omitempty"`；
  真正触发 FATAL 的是 `option/inbound.go:72-74` 的
  `SniffEnabled` / `SniffOverrideDestination` / `SniffTimeout`。

所以这条线走 `SINGBOX_MODE=builtin`：**sing-box 停在基座自带的 1.14.x，不降级、
也不给 HomeProxy 打补丁**（`scripts/patch-homeproxy-for-singbox113.py` 是为旧版
HomeProxy 写的，其正则已经匹配不上 immortalwrt 当前的结构）。

构建期仍有两道保险丝（`extra-packages.sh` 的 builtin 分支 + 工作流的功能包校验），
一旦上游把 legacy inbound 字段写回来，构建会**直接失败**，而不是悄悄产出一份
homeproxy 起不来的固件。

> ⚠️ `builtin` 只对 **immortalwrt 基座**成立 —— 它依赖"基座自带的 HomeProxy 与基座的
> sing-box 是同一上游配好的"这一条。nss-edma 基座不满足：它的 sing-box 来自
> `openwrt/packages`（1.14.0），而 HomeProxy 是从 `immortalwrt/luci` 取的，那条线于是走
> `fixed`（钉 1.12.25）。
> 顺带说明：`immortalwrt/luci` 的生成器**已经迁移**到新版写法，所以 `fixed` 那条线实际
> 拿到的是"迁移后的生成器 + 1.12.25"—— 实测这个组合 `check` 通过，成立（见第五章的对照表）。

## 第六条线：immortalwrt 基座 + NSS 补丁 + dae

第五条线是第四条的**副本**（软件集逐字一致，只改了触发方式），所以这里跳过它。
第六条线才是又一个**软件集不同**的线：基座与第三条/第四条相同（`immortalwrt/immortalwrt`
+ `patches/immortalwrt-nss/`），代理栈从 HomeProxy 换成 **dae** —— 一个跑在
**eBPF（CO-RE）**上的透明代理。

| | **imm-nss-homeproxy 线** | **imm-nss-dae 线（本线）** |
|---|---|---|
| 工作流 | `build-qhora-301w-imm-nss-homeproxy.yml` | `build-qhora-301w-imm-nss-dae.yml` |
| 代理前端 | `luci-app-homeproxy` | `luci-app-dae` + `luci-i18n-dae-zh-cn` |
| 代理核心 | `sing-box`（基座 feed 自带） | `dae`（`feeds/packages/net/dae`，2.0.x） |
| 分流在哪做 | **用户态**：sing-box 跑一堆入站 + nftables 转发 | **内核态**：eBPF 程序直接在 socket 层分流 |
| 地理数据 | `.srs` 规则集（9 条，预置进固件） | `v2ray-geoip` / `v2ray-geosite`（`dae-geoip`/`dae-geosite` 只是软链） |
| 额外内核模块 | `kmod-nft-tproxy` | `kmod-sched-core` / `kmod-sched-bpf` / `kmod-veth` / `kmod-xdp-sockets-diag` |
| 其余 | NSS 卸载栈、`files/` `files-dae/` 覆盖、产物结构 —— 与各线一致 | |

### 为什么值得单独一条线

这**不是**"换个代理前端"。HomeProxy 是 sing-box 的 UCI 外壳：UCI → JSON → 用户态
sing-box 进程建 5330-5333 一组入站，再由 nftables 把 LAN 流量转发过去。也就是说
**连直连流量也要在用户态绕一圈**。dae 把这些搬进内核：

- 分流判断由 eBPF 程序在 socket 收发时就做完，命中直连的包**根本不出内核**；
- 不建 conntrack、不起 TPROXY 回环，BT/PT 这类几万连接并发的场景差距最明显；
- 用户态只留一个轻量的控制面（拉订阅、算节点延迟、下发规则）。

代价是它对内核有**三条硬前提**，缺一条的表现是"编得出、刷得进、跑不起来"。

### 三条内核硬前提（以及为什么单独写一份 `configs/dae.config`）

| 前提 | 对应 Kconfig | immortalwrt 通用内核默认 | 缺了会怎样 |
|---|---|---|---|
| `/sys/kernel/btf/vmlinux` 存在 | `CONFIG_DEBUG_INFO_BTF` | **关** | eBPF 程序加载失败，日志报 `failed to load eBPF` |
| tc 的 bpf 分类器 / 动作 | `CONFIG_NET_CLS_BPF` + `CONFIG_NET_ACT_BPF` | **关** | 隧道模式挂不上挂载点 |
| `sch_ingress` | `CONFIG_NET_SCH_INGRESS` | **关** | 同上（`kmod-sched-core`） |
| XDP socket | `CONFIG_XDP_SOCKETS` | **关** | `kmod-xdp-sockets-diag` 直接不生成 |

2026-10-19 在 `192.168.35.1`（ImmortalWrt SNAPSHOT `r0-da63f7d`，kernel 6.18.55）上实测：
`ls /sys/kernel/btf/vmlinux` 报 `No such file or directory`，`/proc/config.gz` 也不存在，
基座的 `target/linux/generic/config-6.18` 里就写着 `# CONFIG_DEBUG_INFO_BTF is not set`、
`# CONFIG_NET_CLS_BPF is not set`、`# CONFIG_NET_SCH_INGRESS is not set`、
`# CONFIG_XDP_SOCKETS is not set`。

所以 `configs/dae.config` 里显式打开这些（**不要照抄 `homeproxy.config`**，它把
`v2ray-geoip` / `v2ray-geosite` 写成 `=n`）：

```
CONFIG_KERNEL_DEBUG_INFO=y
CONFIG_KERNEL_DEBUG_INFO_REDUCED=n     # ← 关键，见下
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_KERNEL_BPF_EVENTS=y
CONFIG_KERNEL_XDP_SOCKETS=y
```

> ⚠️ `DEBUG_INFO_REDUCED` 必须显式关掉。Kconfig 里 BTF 的依赖是
> `depends on KERNEL_DEBUG_INFO && !KERNEL_DEBUG_INFO_REDUCED`，
> 有些基座默认把它设成 `y`（为了压内核体积）—— 那样 `=y` 的 BTF 会被
> **静默丢弃**，编译一路绿灯，编完才发现没有 `.BTF` 段。

因为这种失败模式太安静，本线在产物阶段加了两道**验真**（不只是 grep `.config`）：

1. 构建期：`objcopy -O binary --only-section=.BTF` 把 `vmlinux` 的 `.BTF` 段抽出来，
   小于 1 MB 直接 `::error::` 中断构建；
2. 打包期：解开 sysupgrade tar → `unsquashfs` 进临时目录，逐个点名
   `/usr/bin/dae`、`/etc/config/dae`、`/etc/dae/config.dae`、
   `/etc/uci-defaults/97-ssh-login-fix`，并检查修复脚本有可执行位。

### 出厂配置：`/etc/dae/config.dae` 是**一份完整可运行的配置**（订阅留空）

出厂 `/etc/config/dae` 里是 `option enabled '0'`，`/etc/init.d/dae` 的
`start_service()` 第一句就是 `config_get_bool enabled ... "0"` +
`[ "$enabled" -eq "1" ] || return 1` —— **没显式启用时连配置都不解析**。

启用后才会跑 `dae validate -c <配置>`。出厂这份配置本身是**语法完整、能通过
validate 的**（2026-10-19 在 192.168.100.1 上实测 `RC=0`），唯一留空的是
`subscription` —— 没有订阅就没节点，所以 dae 起不来、**不会改变任何流量去向**。
这是故意的：固件是公开产物，订阅链接等于账号密码，不进仓库。

用之前只做两件事：

```sh
# 1) 填订阅（也可以直接用 LuCI「服务 → dae → 配置」编辑同一个文件）
vi /etc/dae/config.dae
#     subscription {
#         jms: 'https://你的机场/api/v1/client/subscribe?token=xxx'
#     }

# 2) 校验 + 启用
dae validate -c /etc/dae/config.dae && \
  uci set dae.config.enabled='1' && uci commit dae && /etc/init.d/dae restart
dae-switch status                          # 看每个组选中了哪个节点
```

也可以用 `node { }` 直接贴分享链接（`ss://` / `vless://` / `hysteria2://` …），
和订阅混用没问题，会并进同一个池子。

### 节点切换：四个组，一个命令

配置里预置了四个组，`policy` 决定"这个组怎么挑节点"：

| 组 | policy | 用途 |
|---|---|---|
| `proxy` | `min_moving_avg` | 默认出口，按最近延迟的滑动平均挑最优 |
| `stream` | `min_avg10`（探测地址换成 gstatic） | 流媒体专线；延迟独立计算，所以大概率落在与 `proxy` 不同的节点 |
| `ai` | `fixed(1)` | 第二出口 IP（AI 站点 / 多账号），固定池里第 2 个节点 |
| `pin` | `fixed(0)` | 手动钉死一个节点，调试 / 需要固定 IP 时用 |

切换不靠改 policy，靠 `dae-switch`（`/usr/bin/dae-switch`，随固件预置）：

```sh
dae-switch status          # 当前默认出口、pin 序号、各组选中的节点
dae-switch list            # 订阅里的节点清单 + 最近测速
dae-switch use stream      # 默认出口切成 stream 组（改 routing 的 fallback）
dae-switch pin 3           # pin 组固定到第 4 个节点（序号从 0 开始）
dae-switch use pin         # 再让默认出口走 pin，就等于"锁死在这个节点"
```

`use` / `pin` 都会**先备份 → 改 → `dae validate` → `hot_reload`**，校验不过
自动回滚；`hot_reload` 走 `dae reload <pid>`，是热加载，不断已有连接。

### 节点分流：哪些流量走哪个组

`routing` 段从上往下匹配，第一条命中就定去向：

| 规则 | 去向 | 说明 |
|---|---|---|
| `domain(geosite:category-ads-all)` | `block` | 广告 / 追踪 |
| `domain(geosite:openai)` / `claude.ai` / `anthropic.com` / `gemini` | `ai` | AI 站点走第二出口，避免"同一 IP 被风控" |
| `geosite:netflix` / `disney` / `hbo` / `primevideo` / `youtube` / `spotify` / `twitch` | `stream` | 流媒体专线 |
| `l4proto(udp) && dport(443)` | `block` | 关 QUIC，浏览器秒回落 TCP |
| `dip(geoip:cn)` / `domain(geosite:cn)` / `.lan` `.local` | `direct` | 国内与内网直连 |
| `fallback` | `proxy` | 其余全部走自动选优 |

实测（2026-10-19，192.168.100.1 的 dae 日志）：

```
outbound=proxy  policy=min_moving_avg  dialer=...c38s1...:17170   x.com
outbound=stream policy=min_avg10       dialer=...c38s4...:443     youtube
outbound=ai     policy=fixed           dialer=...c38s2...:443     openai
```

三个组确实落在三个不同节点上。

配置里已经调好的几处（都是踩过坑的）：

| 项 | 值 | 为什么 |
|---|---|---|
| `wan_interface` | `auto` | 本机型 WAN 是 `10g-1` / `wan` / `pppoe-wan`，auto 都能认 |
| `lan_interface` | `br-lan` | **必须显式写**。dae 上游默认不代理 LAN（`example.dae` 里这行是注释掉的），不写就只有路由器本机走代理，LAN 客户端全是直连，日志里也不会有一句抱怨 |
| `dial_mode` | **`domain++`** | `domain` 模式是**先按 IP 分流、后嗅探**，域名规则能否命中取决于 "DNS 有没有穿过 dae"；LAN 里 dnsmasq 有缓存，命中缓存时 dae 拿不到映射 ⇒ netflix / openai 规则时灵时不灵。`domain++` 嗅探后强制按域名重路由（实测由"全落 fallback"变成 netflix→stream、openai→ai） |
| `sniffing_timeout` | **`300ms`** | 30ms 在这台机器上抓不到 ClientHello，日志里 `sniffed=` 全是空；300ms 后 SNI 稳定 |
| `tls_implementation` | `utls` + `chrome_auto` | Client Hello 伪装成 Chrome，纯 TLS 节点更稳 |
| `bootstrap_resolver` | `223.5.5.5:53` | 启动早期拉订阅时 dae 自己的 DNS 还没起来 |
| `sub(jms) -> alidns` + `subnode(subtag: jms) -> alidns` | 订阅与**节点域名**走国内 DNS | 不加 `subnode` 会死循环：解节点域名 → 走代理 → 代理要先知道节点 IP → 日志刷 `bootstrap resolver returned no usable address`。实测加上之后该类告警从 4 条/40s 降到 0 |
| `googledns: 'tcp://dns.google:53'` | DNS 走 TCP | 用 `tcp+udp` 时 UDP 到 8.8.4.4 经节点经常超时（日志 `DNS forward to upstream failed`，实测 12 条/40s），改纯 TCP 后归零 |
| `l4proto(udp) && dport(443) -> block` | 关 QUIC | 浏览器立刻回落 TCP，避开"有的站通、Google 不通"那类 UDP 443 问题 |
| `pname(NetworkManager) -> direct` | 直连 | 否则 dae 绑 WAN 时的连通性自检会被自己代理掉 |
| `dip(224.0.0.0/3, 'ff00::/8') -> direct` | 直连 | 广播/组播/链路本地绝不能进代理，否则 LAN 内发现协议被打断 |

还有一条不在配置里、但同样致命的：**`/etc/dae/config.dae` 的权限必须是 0600**
（0640 也认，0644 都不认）。`dae validate` 会检查权限，太宽就拒绝启动，
而表现是 procd 说 `running`、实际一个实例都没有。造镜像时
`scripts/prepare-build.sh` 会统一 `chmod 0600`，`files-dae/etc/uci-defaults/98-dae-config-perms`
首启再兜一次；自己手改过配置就补一句 `chmod 600 /etc/dae/config.dae`。

### geo 数据（`geoip.dat` / `geosite.dat`）从哪来、怎么更新

`routing` 里的 `geoip:cn`、`geosite:netflix` 这些不是 dae 自带的，也不是运行时下载的：

```
v2ray-geodata（feed 里的一个配方，产出两个子包）
  ├── v2ray-geoip    →  /usr/share/v2ray/geoip.dat
  └── v2ray-geosite  →  /usr/share/v2ray/geosite.dat
dae-geoip / dae-geosite（只是软链）
  └── /usr/share/dae/geoip.dat   -> ../v2ray/geoip.dat
      /usr/share/dae/geosite.dat -> ../v2ray/geosite.dat
```

也就是说数据是**编译期打进 rootfs 的**，dae 运行时不联网更新。出厂那份（2026-10-12 构建）

| 文件 | 大小 | 版本 |
|---|---|---|
| `geoip.dat` | 22.2 MB | `v2ray-geoip` 202610050438 |
| `geosite.dat` | 2.2 MB | `v2ray-geosite` 20261009101206 |

要更新有三条路，按推荐顺序：

**① 重编固件（最干净）** —— feed 的 `v2ray-geodata` 每次 `feeds update` 都会拉上游最新，
CI 每次都是全新树，所以重跑一次工作流就带新数据。缺点是慢（一次完整构建）。

**② 设备上就地替换（秒级）** —— 固件预置了 `dae-geo-update`：

```sh
dae-geo-update --check              # 只对比：本地多大 / 上游多大，不动文件
dae-geo-update                      # 从 v2fly 拉最新（与固件同源）并替换 + 重启 dae
dae-geo-update --only geosite       # 只更新一个
dae-geo-update --cron               # 装每周一 05:10 的定时更新（busybox crond）
```

它做的事：下载 → **校验**（大小下限 + 不能用 HTML 错误页 + 找得到 `CN` / `google` 这类
特征串）→ 备份到 `/root/geo-backup/<时间>/` → 同目录重命名（原子替换）→
`dae validate` → 重启 dae → 实测 `generate_204` 必须回 204。任何一步失败**自动回滚**。

**③ `apk upgrade`（不推荐，会降级）** —— snapshot 的 `packages.adb` 里
`v2ray-geoip` 还是 `202607171233`（2026-07-17），比固件里的 `202610050438`（10-05）**更旧**，
`apk upgrade v2ray-geoip` 等于把数据倒回去。

三个必须知道的坑：

- **`geosite.dat` 别贪大**。Loyalsoldier 那份有 11 MB（分类更全），实测这台机器上 dae 建规则
  要吃 **158 MiB 堆**、启动从 3.7 s 涨到 **60 s+**，而且 `Routing match set len` 从 18 掉到 16
  —— 部分 `geosite:` 规则直接没编进去，流量全落回 `fallback`。所以脚本默认用 v2fly（≈2 MB），
  超过 6 MB 会直接拦下来，真要试得加 `--force`。
- **换的是 apk 包里的文件**。`/usr/share/v2ray/*.dat` 属于 `v2ray-geoip` / `v2ray-geosite` 包，
  `apk upgrade` 会把你的替换覆盖回包里的版本；`sysupgrade` 保留配置时 overlay 里的替换保留，
  但**重刷整镜像会回到固件版本**。
- **短 tag 要用 `strings -n 2` 查**。`CN`、`hk` 这些只有 2 个字符，`strings` 默认跳过长度 <4 的串，
  不加 `-n 2` 会一个都搜不到（脚本第一版就栽在这上面）。

验证新数据确实生效：

```sh
strings -n 2 /usr/share/v2ray/geosite.dat | grep -xE 'NETFLIX|OPENAI'   # tag 是否存在
grep "Routing match set len" /var/log/dae/dae.log | tail -1              # 18 正常，掉到 16 说明有规则没编进去
curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 https://www.netflix.com   # 应落到 stream 组
grep "sniffed=www.netflix.com" /var/log/dae/dae.log | tail -1            # outbound=stream 才对
```

### `dae.config` 与另外两份覆盖层的关系

`configs/dae.config` 是在 `homeproxy.config` 的基础上整块换掉代理栈：
关掉 passwall2 全家 + `sing-box`，打开 dae 那一组。**`common.config` 与
`qhora_301w.config` 一行没动**，`imm-nss.config` 也照旧叠在最后。构建时的拼装顺序是

```
common.config  →  qhora_301w.config  →  dae.config  →  imm-nss.config
```

`scripts/extra-packages.sh` 里 dae 分支**一个仓库都不拉** —— `dae`、`luci-app-dae`、
`dae-geoip`/`dae-geosite` 全在 immortalwrt 官方 feed 里，`v2ray-geoip`/`v2ray-geosite`
由 `feeds/packages/net/v2ray-geodata` 一个配方产出两个子包（所以 `dae.config` 里可以直接写 `=y`，
不用像 homeproxy 那样另建目录）。

## 目录结构

```
.github/workflows/          # 七条构建线：nss-edma 基座 4 条（passwall2 / HomeProxy 钉 1.12.25 /
                            #   HomeProxy 新版 sing-box / 上面那条的副本）
                            #   + immortalwrt 基座 3 条（passwall2 / HomeProxy / dae）
configs/
  common.config             # NSS 卸载栈 + 通用选项 + 附加功能包
  qhora_301w.config         # 机型：target / 子目标 / 设备 / 内存档位
  homeproxy.config          # 覆盖层：关掉 passwall2 那组、换成 HomeProxy
  dae.config                # 覆盖层：关掉 passwall2 那组、换成 dae（含内核 BTF/BPF 项）
  imm-nss.config            # 覆盖层：只给三条 imm 线（immortalwrt 的符号差异）
  homeproxy-rulesets.list   # HomeProxy 规则集清单（名字 ↔ 上游 URL，9 条）
packages/net/{ddns-go,msd_lite}/   # 自带配方（直接引用上游源码，版本构建时解析注入）
packages/emortal/autocore/         # 纯脚本包，提供 tempinfo / cpuinfo
patches/kernel/6.18/               # 叠进上游内核源码树的内核补丁（见下）
patches/immortalwrt-nss/           # imm-nss 线专用：NSS 补丁集 + 来源说明（见下）
scripts/
  prepare-build.sh          # 组装 .config、跑 defconfig、校验符号、叠加覆盖文件
  prepare-build-imm-nss.sh  # imm-nss 线的入口：先移植 NSS，再交给 prepare-build.sh
  apply-nss-patches.sh      # 把 patches/immortalwrt-nss/ 的补丁打进 immortalwrt 源码树
  extra-packages.sh         # 把 feed 里没有 / 不该用官方那份的包放进 feed 目录树
  resolve-versions.sh       # 构建时解析 ddns-go / msd_lite 的上游最新版本
  check-no-credentials.sh   # 构建期守卫：预置文件里出现凭据/订阅链接就中断
  fetch-homeproxy-rulesets.sh # 拉取/校验 9 个 .srs 规则集（构建期刷新 + 刷新仓库副本）
files/                      # 各变体共用的覆盖文件（uci-defaults、首页硬件区块等）
files-passwall2/            # 只叠进 passwall2 版：etc/config/passwall2
files-homeproxy/            # 只叠进 HomeProxy 版：etc/config/homeproxy、
                            #   etc/homeproxy/ruleset/*.srs（9 个预置规则集）、
                            #   etc/uci-defaults/95-homeproxy-rulesets（升级时 remote→local）
files-dae/                  # 只叠进 dae 版：etc/dae/config.dae（完整配置，订阅留空）、
                            #   usr/bin/dae-switch（节点切换命令）、
                            #   etc/uci-defaults/97-ssh-login-fix（首启修 SSH，见下）
```

**预置文件里只有「策略」，没有「凭据」。** 节点地址 / 端口 / 密码 / UUID / REALITY 公钥 /
订阅链接一律不进仓库 —— 固件是公开产物，写进去等于公开。每次构建都会跑
`scripts/check-no-credentials.sh` 扫 `files*/etc/config/`，命中就**中断构建**。
dae 线另有一道：`prepare-build.sh` 的第 6a 步会读 `files/etc/dae/config.dae`，
剥掉注释行后如果还能匹配到 `vless://` `vmess://` `ss://` `trojan://` `hysteria2://`
`tuic://` `anytls://` 或 `标签: 'http(s)://…'` 这种订阅行，直接中断。
（`tcp_check_url` / `udp_check_dns` / `bootstrap_resolver` 这几行在检查前会被滤掉 ——
它们本来就是公网探测地址，不滤会误伤 `http://cp.cloudflare.com`；
DNS 上游的 `tcp://dns.google:53` 也不在匹配范围内。）

### 内核补丁：`patches/kernel/6.18/`

这是本仓库**唯一**往上游源码树（`openwrt-nss-edma` 那棵树）里加东西的地方。其余改动全部落在
"配方层"：`configs/`（Kconfig 选项）、`scripts/`（构建编排）、`files*/`（镜像内文件覆盖）、
`packages/`（自带配方）。

落点由 `scripts/prepare-build.sh` 的第 7 步决定：把补丁拷进上游源码树的
`target/linux/generic/hack-<ver>/`，也就是内核补丁队列的最后一站。这条链在源码树里是
`include/target.mk`（定义 `GENERIC_HACK_DIR`）→ `include/quilt.mk`（`Kernel/Patch/Default`
按 `backport-<ver>` → `pending-<ver>` → **`hack-<ver>`** → `<target>/patches-<ver>` 顺序应用）
→ `rules.mk` 的 `KPATCH`（= `scripts/patch-kernel.sh`，用 `patch -f -p1` 执行）。
补丁对不上时它打 `Patch failed!` 并 `exit 1`，所以**会中断构建**，不会静默编出没打补丁的内核。

目前只有一条，解决首页「架构」显示 `?`（详见第六节排查表）：

```
patches/kernel/6.18/312-arm64-cpuinfo-Add-model-name-in-proc-cpuinfo-for-64bit-ta.patch
```

补丁本身抄自 ImmortalWrt 收录的版本（NVIDIA 的 Sumit Gupta 2016 年发到 LKML、**未被主线接受**），
只改 `arch/arm64/kernel/cpuinfo.c` 一处。**上游把内核升到新版本时必须补一份对应版本**：
同一个补丁在 6.12 与 6.18 上的 hunk 上下文不同（6.12 是 `i` + 两层缩进，6.18 是 `cpu` + 一层），
拿 6.18 那份去打 6.12 内核会 `Hunk #1 FAILED`。目录名取自
`target/linux/qualcommax/Makefile` 的 `KERNEL_PATCHVER` —— 读不到或对应目录不存在都**明确报错**，
不会静默跳过。

---

## 一、编译

### 1. 前置

- **发 Release 才需要**：`Settings → Actions → General → Workflow permissions`
  选 **Read and write permissions**。不发 Release 保持默认即可。
- 想在自己机器上编而不走 CI，见文末「本地编译」。

### 2. 跑一次

`Actions` → 左侧选工作流（**记得两条线分别跑**）→ `Run workflow`：

| 输入 | 说明 |
|---|---|
| `upstream_ref` | 要编译的上游 ref，默认 `nss-edma-rework`，也可填 tag / commit |
| `release` | 勾上 = 编译成功后创建 Release 并把镜像挂上去；不勾 = 只出 Actions artifact |
| `clean_build` | **勾上 = 忽略 dl 与 ccache 缓存，完全从零编译**（慢很多，单条约 3 小时以上） |
| `ddns_go_version` / `msd_lite_sha` | 留空 = 跟随上游最新；填版本号 / sha 则钉死（要可复现固件时才填） |
| HomeProxy 版另有 `imm_ref` / `imm_luci` / `imm_pkgs` | ImmortalWrt 的 ref 与仓库地址，留空 = 官方 master |
| HomeProxy 版另有 `singbox_expect` | 期望的 sing-box 配方版本，留空 = `1.12.25`（见第三节） |

推送改动也会触发：主线监听 `configs/**` `scripts/**` `files/**` `files-passwall2/**`，
HomeProxy 线监听 `configs/homeproxy.config` 与 `files-homeproxy/**`（**故意不监听 `scripts/`**，
否则两条全量编译一起排队几小时）。主线另有每周一 00:30（东八区）的定时检查。
`push` / `schedule` 触发没有输入框，值天然为空 —— 也就是"跟随上游最新、不发 Release"。

### 3. 产物

Artifact 名 `openwrt-qnap_301w[-homeproxy]-<run_number>`：

| 文件 | 用途 |
|---|---|
| `*-initramfs-uImage.itb` | **首次安装**：U-Boot 里用 TFTP 引导 |
| `*-squashfs-sysupgrade.bin` | 日常升级（设备已在跑 OpenWrt） |
| `*-squashfs-factory.bin` | eMMC 整盘写入 |
| `sha256sums` / `config.buildinfo` / `profiles.json` / `*.manifest` | 校验与溯源 |

勾了 `release` 时，Release 正文里会写明**编译日期**（UTC + 北京时间）、上游 ref 与提交、
OpenWrt 版本标识，以及一张**各组件版本表**（passwall2 / HomeProxy / sing-box / ddns-go /
msd_lite / WireGuard / statistics / autocore ……）。版本取自固件 rootfs 清单，是**实际装进去**
的版本。

> GitHub 对 artifact **内容**和作业日志都要登录才能看（公开仓库一样）。所以工作流把关键信息
> 都用 `::notice::` 发成 check-run annotation —— 那是公开可读的。

---

## 二、刷机

> ⚠️ **不保留原厂系统的分区**。QHora-301W 是 A/B 双分区，下面只动第 0 组
> （`mmcblk0p1` / `mmcblk0p4`），第 1 组原样保留，随时能切回原厂。

### 首次安装（设备还没跑 OpenWrt）

需要 USB-TTL 串口线。

1. 串口接好、路由器上电，在 U-Boot 输出出现时一直敲空格打断自动启动。
2. 电脑开 TFTP 服务，把 `initramfs-uImage.itb` 放进 TFTP 根目录。
3. U-Boot 里执行：

   ```
   setenv serverip 192.168.10.2      # 你电脑的 IP
   setenv ipaddr   192.168.10.10     # 随便给路由器一个同网段 IP
   saveenv
   tftpboot openwrt-...-qnap_301w-initramfs-uImage.itb
   bootm
   ```

4. 起来后路由器地址是 **`192.168.35.1`**（本仓库把出厂默认的 `192.168.1.1` 换掉了），
   `root` **没有密码**。⚠️ 此时 **LuCI 网页能空密码登录，SSH 不能** —— 本固件用的
   openssh 默认拒绝空密码（原因与解法见「三、刷完之后 → SSH 登录」）。所以先在
   **串口控制台**里给 root 设个密码，之后才能 `scp` / `ssh`：

   ```sh
   # ① 串口控制台（本来就插着 USB-TTL，回车进 shell）
   passwd                            # 设 root 密码；不设的话 SSH 一律拒绝

   # ② 电脑上（重取一次 DHCP）
   scp openwrt-...-qnap_301w-squashfs-sysupgrade.bin root@192.168.35.1:/tmp/
   ssh root@192.168.35.1
   fw_printenv -n current_entry      # 必须是 0，不是就 fw_setenv current_entry 0
   sysupgrade -n /tmp/openwrt-...-qnap_301w-squashfs-sysupgrade.bin
   ```

   不想设密码也行：镜像直接用 LuCI（`http://192.168.35.1`，空密码登录）的
   `系统 → 备份/刷写固件` 上传。

### 以后升级

```sh
sysupgrade -n /tmp/openwrt-...-qnap_301w-squashfs-sysupgrade.bin
```

或用 LuCI：`系统 → 备份/刷写固件`。

### 回原厂

U-Boot 里打断启动：`setenv current_entry 1; saveenv; bootipq`

### ⚠️ 10GbE 网口（Aquantia AQR113C）

两个万兆口需要 Aquantia PHY 固件，而它存在板子的 `0:ETHPHYFW` mtd 分区里，**只有原厂系统才有**。
**动手刷机前先从原厂系统把这个分区备份出来**，否则刷完万兆口不亮：

```sh
cat /proc/mtd | grep -i ethphyfw
dd if=/dev/mtd10 of=/tmp/ethphyfw.backup        # 分区号以 /proc/mtd 实际输出为准
```

分区是空的可以从原厂固件里解出 `AQR_ethphyfw.mbn` 写回，并在 U-Boot 的 bootcmd 里加
`aq_load_fw 0; aq_load_fw 8; bootipq`。细节见
[OpenWrt 设备页](https://openwrt.org/toh/qnap/301w)。

---

## 三、刷完之后

NSS 卸载**开机自动启动**：先按主机协议栈起来，再切到 NSS 数据面。

```sh
nss-status                       # 健康状态
logread -e nss                   # 启动日志
```

LuCI：`状态 → NSS Offload`、`网络 → QoS Marking (NSS)`。退回纯主机协议栈（等于普通 OpenWrt）：

```sh
uci set nss.general.enabled='0'; uci commit nss; reboot
```

**默认 LAN 是 `192.168.35.1/24`**（DHCP 段 `192.168.35.100-249`）。改动点在
`files/etc/uci-defaults/99-qhora-301w`，由 `/etc/init.d/boot`（`START=10`）在网络起来之前执行，
所以首次开机直接生效，不用重启第二遍。

**Wi-Fi 默认关闭且没有密码**，用网线连上后到 `网络 → 无线` 自己开射频并设密钥。

### SSH 登录（root 密码；为什么"网页能进、SSH 提示密码错误"）

本固件**关掉了 dropbear、改用 openssh-server**（`configs/common.config` 里
`CONFIG_PACKAGE_dropbear=n` + `CONFIG_PACKAGE_openssh-server=y`）。OpenWrt 的 openssh
包是**直接把上游原版 `sshd_config` 装进去**的，里面 `PermitRootLogin` 那行处于
**注释**状态 ⇒ 生效值 = 上游默认的 **`prohibit-password`** ⇒ **root 只接受公钥，
密码一律被拒**。而 LuCI 走的是 rpcd，其 `session.c` 的 `rpc_login_test_password()`
第一句就是 `if (!hash || !*hash) return true;` —— **密码哈希为空就放行**。两者叠加
就是你看到的现象：网页空密码能进，SSH 永远 `Permission denied, please try again`。

2026-10-19 在 `192.168.35.1` 上实测，还有**第三个**更要命的原因：出厂 `/etc/shadow`
里 root 那行是

```
root:::0:99999:7:::
```

密码字段**根本是空的**（root 从未设过密码）。`PermitEmptyPasswords` 上游默认 `no`，
所以即使把 `PermitRootLogin` 放开，**空密码照样登不进来**。这三条叠在一起，
SSH 密码登录没有任何一条路能走通。

还有**第四个**（只影响免密登录）：LuCI 的「系统 → 管理权 → SSH 密钥」页把公钥写进
`/etc/dropbear/authorized_keys`（见
`feeds/luci/modules/luci-mod-system/htdocs/luci-static/resources/view/system/sshkeys.js:150`），
而本固件**没有 dropbear**，OpenSSH 读的是 `AuthorizedKeysFile .ssh/authorized_keys`
（= `/root/.ssh/authorized_keys`）⇒ 在网页里加的公钥**永远不生效**。

固件现已用 `files/etc/ssh/sshd_config` 覆盖这份配置（只改 3 处：顶部加
`Include /etc/ssh/sshd_config.d/*.conf`、`PermitRootLogin yes`、
`PasswordAuthentication yes`）。

#### 已经有自动修复：`files-dae/etc/uci-defaults/97-ssh-login-fix`

第六（dae）线起，上面这几件事由 `/etc/uci-defaults/97-ssh-login-fix` 在**首启时一次做完**，
刷完就能直接 `ssh root@192.168.35.1`：

| 做了什么 | 怎么做的 |
|---|---|
| 给空密码的 root 写入出厂密码 | 只在 `/etc/shadow` 里确实是 `root::` 时才 `sed` 成 `root:$5$…`（`password`）；**已经设过密码的绝不覆盖** |
| 修正公钥路径 | `/root` 750、`/root/.ssh` 700、`authorized_keys` 600，并把 `/etc/dropbear/authorized_keys` **软链**到它 |
| 确保 sshd 开机自启 | `/etc/init.d/sshd enable` |

执行时机是 `/etc/init.d/boot`（`START=10`），早于 `sshd`（50）和代理服务（99），
所以首次开机就是最终状态，不用重启第二遍。**刷完第一件事仍然是 `passwd` 改掉它，
或者干脆改用公钥。**

> 另外六条线目前**没有**这个脚本（它只放在 `files-dae/`，避免动到已发过的构建）。
> 想让它们也自动修，把 `files-dae/etc/uci-defaults/97-ssh-login-fix` 复制到
> `files/etc/uci-defaults/` 即可 —— 那个文件不带任何代理栈相关的内容，七条线通用。

**刷了更早 build 的设备要手动补一次**：

```sh
# ① 确认主配置里有 Include 那行（更早的 build 没有）
grep -n '^Include' /etc/ssh/sshd_config
#    没有 → 直接改主文件这两行也行：
#    sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/;
#            s/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# ② 放开 root 密码登录（有 ① 的 Include 时用 drop-in，比改主文件干净）
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-root-login.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
chmod 0600 /etc/ssh/sshd_config.d/10-root-login.conf

# ③ root 必须有密码 —— 出厂是空的，而 `PermitEmptyPasswords` 默认 no，空密码照样进不来
grep '^root:' /etc/shadow          # 输出 root:::0:99999:7::: 就是没密码
passwd                            # 等价于 LuCI 的 `系统 → 管理权`

# ④ 重启并核对**生效值**（-T 打印的是合并后的最终配置）
/etc/init.d/sshd restart
sshd -T | grep -Ei 'permitrootlogin|passwordauth|permitempty'   # 期望 yes / yes / no
```

排错提示：`sshd` 对同一关键字**取先出现的值**，所以 drop-in 必须写在 `Include` 那行
之后的位置才能覆盖主配置；`sshd_config.d/` 里的文件权限太松（group/other 可写）
会导致**整份配置被拒**，必须 `0600`。

**设备是旧 build、此刻还没有 shell 怎么办**（鸡生蛋问题，三条路都不用拆机）：

1. LuCI `系统 → 软件包` 装 `luci-app-ttyd` → `系统 → 终端`，在网页里跑上面的命令；
2. **串口控制台**（USB-TTL，刷机本来就用）回车即进 shell —— 最快；
3. failsafe 模式：`/lib/preinit/99_10_failsafe_sshd` 在 dropbear 缺席时会临时起 sshd，
   其配置写死 `PermitRootLogin yes` + `PermitEmptyPasswords yes` ⇒ 可以**空密码**
   `ssh root@192.168.1.1`（failsafe 网段是 `192.168.1.1`，不是 `192.168.35.1`）。

注意：只设密码**不解决**旧 build 的问题 —— `PermitRootLogin prohibit-password`
和密码是否存在无关，必须先放开这一项。

安全性：`PermitRootLogin yes` 只把密码爆破面暴露给**能连上 LAN 的人**，和 LuCI 原本的
暴露面一致。想更稳就走公钥 —— `prohibit-password` 本来就允许 root 用公钥登录，把
`id_ed25519.pub` 追加到 `/root/.ssh/authorized_keys`（`chmod 700 /root/.ssh`、
`chmod 600 /root/.ssh/authorized_keys`）即可。

> ⚠️ 走公钥时**别用 LuCI 那个「SSH 密钥」页** —— 它写的是
> `/etc/dropbear/authorized_keys`，本固件没有 dropbear，写了不生效。
> 要么直接改 `/root/.ssh/authorized_keys`，要么先按上面的表格把
> `/etc/dropbear/authorized_keys` 软链过去（`97-ssh-login-fix` 已经做了这一步）。

### passwall2 出厂预置（仅 passwall2 版）

`/etc/config/passwall2` 是一份完整配置（逐字段搬自一台在跑的参考机），**除节点外全都配好了**：

| 项 | 预置内容 |
|---|---|
| 直连 | `geosite-cn` + Apple 系（`apple` / `apple@cn` / `apple-update`）+ `geosite-category-bank-cn` + `geosite-douyin` + `geoip-cn` |
| 代理 | `geosite-geolocation-!cn`；**没命中任何规则的流量也走代理** |
| 拦截 | `geosite-category-ads-all` → 黑洞 |
| DNS | DoH（`https://8.8.8.8/dns-query`）**走代理**解析；直连侧 `UseIP`；`dns_redirect=1` 由 passwall2 接管 dnsmasq |
| 转发 | nftables TPROXY（`prefer_nft=1`），TCP/UDP 全端口 |
| 选路 | URLTest 组：3 分钟一测、容差 50ms，自动用延迟最低的节点 |
| 接线 | `mainshunt`：Reject→黑洞、Direct→直连、Proxy→URLTest 组 |

没预置的只有节点凭据。文件里留了两个模板：

- **`node_vless`** —— VLESS + REALITY，`type=sing-box`；只需填
  `address` / `uuid` / `tls_serverName` / `reality_publicKey` / `reality_shortId`
- **`node_ss`** —— Shadowsocks，`type=SS-Rust`；只需填 `address` / `port` / `password`

用法：`服务 → Pass Wall 2 → 节点列表`，编辑模板填完保存；确认「地址」不为空后，打开主界面总开关。
不用的模板留空即可（地址为空的节点不会被选中）。

三点必须注意：

1. **节点类型别选 `Xray`** —— 本固件不编 xray-core，选 `Xray` 会因缺 `/usr/bin/xray` 起不来。
   VLESS / VMess / Trojan / Hysteria2 都用 `sing-box` 类型，SS 用 `SS-Rust`。
   从别处导入的节点把下拉框改成 `sing-box` 再保存即可。
2. **`enabled` 故意留 `0`** —— 节点还空着时 passwall2 会把 dnsmasq 解析劫持到一条走不通的
   代理链上，症状是"国内正常、国外全打不开"，很像断网。填好节点再打开开关。
3. **走订阅**：`服务 → Pass Wall 2 → 订阅` 加一条并更新出节点后，二选一 ——
   ① 把节点的「分组」设成与 URLTest 组一致再手动勾进成员列表；
   ② 把 URLTest 节点的「节点添加方式」从 `manual` 改成 `batch`，用「选择分组」动态纳入
   （订阅更新后自动跟上）。

### HomeProxy 出厂预置（仅 HomeProxy 版）

`/etc/config/homeproxy` 把上面那套三分流**等价搬到了 HomeProxy 的 Custom routing**。
HomeProxy 吃 sing-box 原生配置，与 passwall2 的 `shunt_rules` 结构完全不同：

| passwall2 | HomeProxy custom |
|---|---|
| `_urltest` 组 | `routing_node 'main'`（`node=urltest`）→ 出站 `cfg-main-out` |
| `shunt_rules 'Reject'` | `ruleset 'ads'` + `routing_rule 'Reject'`（**`action='reject'`**） |
| `shunt_rules 'Direct'` | `ruleset` ×7 + `routing_rule 'Direct'`（`outbound='direct-out'`） |
| `shunt_rules 'Proxy'` | `ruleset 'noncn'` + `routing_rule 'Proxy'`（`outbound='main'`） |
| shunt `default_node` | `routing.default_outbound` |
| DoH 经代理 / 直连 DNS | `dns_server 'remote_dns'`（https 8.8.8.8，走 `main`）+ `dns_server 'direct_dns'`（udp 223.5.5.5）+ `dns_rule 'cn_dns'` |

分流结果与 passwall2 版一致：**国内直连、境外走 URLTest 代理、广告域名丢弃**，
DNS 分域（国内 223.5.5.5 直连解析，其余 8.8.8.8 的 DoH 经代理）。

**节点从哪来**（固件里只有策略）：

| 路线 | 你要做的 |
|---|---|
| **A 手动** | 填 `node_vless`（VLESS+REALITY）或 `node_ss`（Shadowsocks）模板 —— 预置的 URLTest 成员就是这两个，填完即用 |
| **B 订阅** | `服务 → HomeProxy → 节点 → Subscriptions` 填**你自己的**订阅链接 → 更新节点 |

订阅那组开关（自动更新 + 时间、经代理更新、`filter_nodes` / `filter_keywords` 关键词过滤）
已预置在 `config homeproxy 'subscription'` 里，**唯独没有 `subscription_url`**（链接含机场
service id 与密钥）。自动更新失败时 `update_subscriptions.uc` 会跳过失败那组、保留旧节点，
不会清空，所以默认就把 `auto_update` 打开了。

> ⚠️ 走**订阅**时有个绕不开的步骤：订阅节点的 section id 是 `MD5(节点名)`，固件没法预知，
> 得把它们勾进 URLTest 组（HomeProxy 没有 passwall2 那种"按分组自动纳入"）。设备上一条命令：
>
> ```sh
> uci -q delete homeproxy.main.urltest_nodes
> for n in $(uci show homeproxy | sed -n "s/^homeproxy\.\([^.]*\)=node$/\1/p"); do
>   [ -n "$(uci -q get homeproxy.$n.grouphash)" ] && uci add_list homeproxy.main.urltest_nodes="$n"
> done
> # 注意：uci delete 一次只能删一个 section
> uci -q delete homeproxy.node_vless
> uci -q delete homeproxy.node_ss
> uci commit homeproxy && /etc/init.d/homeproxy restart
> ```
>
> 走**手动**路线不用动成员列表。

**启用方式**（与 passwall2 不同）：custom 模式的"开关"不是主节点下拉，而是
`routing.default_outbound` —— init 取到 `nil` 时直接 `return 1`，不启动、不劫持 DNS，
所以预置里它是 `nil`。填完节点后二选一：

- 界面：`服务 → HomeProxy → 路由设置` → **Default outbound 选 `Main`** → 保存
- 命令：`uci set homeproxy.routing.default_outbound='main' && uci commit homeproxy && /etc/init.d/homeproxy restart`

三个实测踩过的坑：

1. 列表型选项必须写 `list`，写 `option x 'a' 'b'` 会被 uci 解析器拒（`too many arguments`）。
2. `routing_rule` 段的**先后顺序就是匹配优先级**，Reject 必须排最前。
3. `urltest_interval` 要写裸秒数（生成器做的是 `值 + 's'`），写 `3m` 会得到 `3ms`。

#### 规则集（9 个 `.srs`）是**随固件预置**的，首启不下载

出厂配置里这 9 条 ruleset 一律是 `type 'local'` + `path '/etc/homeproxy/ruleset/x.srs'`，
文件直接打进固件。**别改成 `remote`** —— 那不是风格问题，是会断网的事故链：

```
type=remote  ⇒ sing-box 在**服务启动那一刻**才去 url 下载规则（还得经代理）
             ⇒ 9 条里任一条失败（raw.githubusercontent.com 直连不通，
                能用的代理恰恰是这个还没起来的服务，先有鸡后有蛋）
             ⇒ sing-box 起不来
             ⇒ 而 /etc/init.d/homeproxy 早在起 sing-box **之前**
                就把 dnsmasq 劫持到 127.0.0.1:5333 了
             ⇒ DNS 指向一个没人监听的端口 ⇒ 整个 LAN 上不了网
```

实测复现过这个现象（刷完配好节点一启用就断网），所以固件端必须消灭这条链。

**换成 local 之后，失败发生的阶段也前移了 —— 断了也不会全网断**

这不只是"少一次下载"。实测（官方 sing-box 1.14.3，与固件内同版本）：

| 形态 | `sing-box check` 结果 |
|---|---|
| `local` + 合法文件 | rc=0 |
| `local` + 文件不存在 | **rc=1** `parse rule-set[0]: no such file or directory` |
| `local` + 垃圾内容 | **rc=1** `invalid sing-box rule-set file` |
| `local` + 文件被截断 | **rc=1** `unexpected EOF` |
| `remote` + 不存在的 URL（对照） | **rc=0 放行**，跑到 `run` 才 `FATAL` |

关键在错误信息里的 `initialize router:` —— `check` 会把本地规则集整个解析一遍，
而 remote 它根本不碰。`/etc/init.d/homeproxy` 里那句
`elif ! "$PROG" check ...; then return 1` 位于**劫持 dnsmasq 之前**，`return 1`
意味着后面每一行都不执行 ⇒ dnsmasq 从头到尾没被碰过。

所以本地化之后最坏情况是「代理起不来、但网是通的」，不再是「整个 LAN 断网」。

**⚠️ 前提：`routing_mode` 必须是 `custom`**

`generate_client.uc:62` 是 `if (routing_mode !== 'custom')` 的顶层分叉：

- **`custom`** → 走 `else` 分支，才轮到我们预置的那 9 条 local 规则集；
- **非 `custom`**（`bypass_mainland_china` / `gfwlist` / `proxy_mainland_china` / `global`）
  → 走"自动生成"分支，它**完全忽略** `config ruleset` 节；其中
  `bypass_mainland_china` 还会另行硬编码注入 3 个 **remote** 规则集：

  | tag | URL |
  |---|---|
  | `geoip-cn` | `fastly.jsdelivr.net/gh/1715173329/IPCIDR-CHINA@rule-set/cn.srs` |
  | `geosite-cn` | `.../sing-geosite@rule-set-unstable/geosite-geolocation-cn.srs` |
  | `geosite-noncn` | `.../geosite-geolocation-!cn.srs` |

  三个都带 `download_detour: 'main-out'`，在 `run` 阶段才下载 ⇒ 断网那条链原样回来，
  **而且预置的 9 个本地文件一点用都没有**。

这个耦合不报任何错、只会静默失效，所以 `prepare-build.sh` 第 6b 步加了断言：
`routing_mode` 必须是 `custom`，且 ruleset 节数必须等于 `type 'local'` 的个数，
对不上直接中断构建。

**规则文件怎么保持最新**

| 时机 | 做法 |
|---|---|
| 编译时（默认） | `prepare-build.sh` 第 6b 步自动从上游拉最新 `.srs` 写进覆盖层，并写一份 `/etc/homeproxy/rulesets.lock` 溯源 |
| 编译时（固定版） | `RULESETS_REFRESH=0`：完全不联网，用仓库里 `files-homeproxy/etc/homeproxy/ruleset/` 那份固定副本（= 可复现固件） |
| 编译时（严格） | `RULESETS_STRICT=1`：没拿到全部最新版就中断构建（默认 0：下载失败退回仓库副本 + `::warning::`，照常出固件） |
| 机器上 | 换掉 `/etc/homeproxy/ruleset/*.srs` 后 `/etc/init.d/homeproxy restart` |
| 想彻底换成自动更新 | LuCI 里把某条的 **Type 改成 Remote** 并填 URL（选 Local 时 URL 字段会自动隐藏，反之亦然）。⚠️ 在节点还没配好之前别这么干 |

CI 上直接勾选：第四条线的 `rulesets_refresh`（默认勾选）/ `rulesets_strict`（默认不勾）。

**升级时旧配置怎么办**：`/etc/uci-defaults/95-homeproxy-rulesets` 会在首次开机
（`/etc/init.d/boot`，START=10 → 早于 homeproxy 的 START=99）把你机器上那份
**remote 配置就地改写成 local**，并删掉只有 remote 才用的 `url` / `outbound` /
`update_interval`：

```sh
# ⚠️ type=local 时这三个字段必须删干净，否则 sing-box check 直接 FATAL：
#    FATAL decode config: route.rule_set[0].url: json: unknown field "url"
# （用官方 sing-box 1.14.3 实测确认过）
```

这正是"保留配置升级"也不会再断网的原因；全新刷机时配置本来就是 local，脚本只做兜底校正。

**三处名字必须一致**（改名字要同步改）：

```
configs/homeproxy-rulesets.list                              ← 清单（名字 ↔ URL）
files-homeproxy/etc/config/homeproxy                          ← 出厂配置（local + path）
files-homeproxy/etc/uci-defaults/95-homeproxy-rulesets         ← 升级迁移
```

构建期由 `scripts/fetch-homeproxy-rulesets.sh` 自动核对，名字对不上会**直接中断构建**
（否则会出现"配了 ruleset x、文件却叫 y.srs"这种一启动就 FATAL 的固件）。
文件校验用的是硬指标：非空 + 文件头必须是 `SRS`（sing-box 二进制规则集魔数），
外加用官方 `sing-box 1.14.3 rule-set decompile` 逐条解过一遍（9/9 通过）。

想手动刷新仓库里那份固定副本：

```sh
bash scripts/fetch-homeproxy-rulesets.sh --dest files-homeproxy/etc/homeproxy/ruleset
bash scripts/fetch-homeproxy-rulesets.sh --dest files-homeproxy/etc/homeproxy/ruleset --verify-only  # 只校验不联网
```

### 附加服务

| 服务 | 状态 | 怎么用 |
|---|---|---|
| **ddns-go** | 开机自启 | Web `http://<路由器IP>:9876` 添加 DDNS 记录；数据在 `/etc/ddns-go/config.yaml` |
| **msd_lite** | 开机自启 | 客户端按 `http://<路由器IP>:7088/udp/<组播地址>:<端口>` 取流。**收组播的网卡要在 `服务 → msd_lite` 里选**（出厂留空，填错的表现是端口能连但拉不到流） |
| **WireGuard** | 仅装好 | 无常驻服务；到 `网络 → 接口` 新建一个 `wg` 协议接口即可 |
| **passwall2 / HomeProxy / dae** | 已预置，未启用 | 见各自章节（dae 版固件里只有 dae，没有另外两个） |
| **statistics** | 开机自启 | `状态 → 统计` 有 CPU / **温度** / 内存 / 接口流量 / 无线曲线。温度采集由 uci-defaults 默认打开 |
| **首页 CPU / 温度** | 装好即生效 | `状态 → 总览` 的「系统」块里**顶部**就有 `CPU usage (%)` 与 `Temperature`；内存由标准「内存」块紧随其后。走的是 ImmortalWrt 原生实现，**不依赖 collectd**（与统计页的历史曲线是两回事） |
| **autocore** | 装好即生效 | 提供 `/sbin/tempinfo`（`CPU: 52.3°C, WiFi: 61.0°C`）与 `/sbin/cpuinfo` —— 上面那两行的数据源 |

LuCI 默认简体中文。`状态 → NSS Offload` 那一页是英文 —— 它是 NSS 主树里的纯 JS 页面，
不走 luci.mk，没有翻译文件，语言开关对它无效，这是上游现状。

验证服务真的起来了：

```sh
/etc/init.d/ddns-go status ; /etc/init.d/msd_lite status
ls /etc/rc.d/ | grep -E 'ddns-go|msd_lite'    # 有 S99 链接 = 开机自启生效
/etc/init.d/passwall2 status ; /etc/init.d/homeproxy status ; /etc/init.d/dae status
sing-box version ; sslocal --version ; dae version   # 核心二进制在不在
/etc/init.d/luci_statistics status
cat /sys/class/thermal/thermal_zone*/type     # 固件里有哪些温度传感器
```

---

## 四、改配置

| 想改什么 | 改哪 |
|---|---|
| 加一个软件包 | `configs/common.config` 末尾加 `CONFIG_PACKAGE_xxx=y` |
| 加一个官方 feed 没有的包 | 在 `packages/<分类>/<包>/` 放自带配方（`extra-packages.sh` 用 `find` 扫，自动落位），再到 `common.config` 加符号。**二级目录名要与包的性质对上**（`net/`、`utils/`…），配方里的 `include ../../…` 依赖这个层级 |
| 加一个 luci 前端页 | `scripts/extra-packages.sh` 的 `LUCI_PATHS` 里加路径，再到 `common.config` 加符号 |
| 换 passwall 核心（比如要回 xray） | 把 `..._Basic_Core_SingBox=y` 换成 `..._Basic_Core_Xray=y`，并在工作流 `WANT` 清单里补回 `xray-core` |
| 换 passwall 仓库 / 分支 | `extra-packages.sh` 顶部的 `PW_APP_REPO` / `PW_PKGS_REPO` / `PW_REF`，或工作流的 `passwall_*` 输入 |
| 钉死 ddns-go / msd_lite 版本 | `Run workflow` 时填 `ddns_go_version` / `msd_lite_sha`，或改 `packages/net/*/Makefile` 的兜底值 |
| 系统默认配置（主机名、**LAN 网段**、无线、服务开关） | 往 `files/` 按路径放文件，首启脚本在 `files/etc/uci-defaults/`；LAN 网段在 `99-qhora-301w` |
| 改 passwall2 / HomeProxy 出厂预置 | `files-passwall2/etc/config/passwall2` / `files-homeproxy/etc/config/homeproxy`（**改完把 `address` 之类留空**，别把凭据提交上去） |
| 改 dae 出厂配置（组 / 分流 / 全局项） | `files-dae/etc/dae/config.dae`（**订阅留空**；节点组与 routing 都在这个文件里） |
| 改 dae 的节点切换命令 | `files-dae/usr/bin/dae-switch`（换成固件里的 `/usr/bin/dae-switch`，`prepare-build.sh` 会 `chmod 0755`） |
| 加内核 BPF 选项 | `configs/dae.config`（BTF 那几行是硬前提，别减） |
| 确认预置里没夹带凭据 | 构建会自动跑 `scripts/check-no-credentials.sh`；也可手动 `BUILDER_DIR=$PWD bash scripts/check-no-credentials.sh` |
| 换源码仓库 / 分支 | 工作流 `env.UPSTREAM_REPOSITORY` / `UPSTREAM_REF` / `NSS_FEED`，或 `Run workflow` 时的 `upstream_ref` |

改完 `configs/` 要**推送后再跑**，否则不生效。

### 改配置前必看的三个坑

1. **覆盖层关掉某个符号必须写 `CONFIG_X=n`，不能写 `# CONFIG_X is not set`。**
   `prepare-build.sh` 按"配置里最后一个赋值"取值、且只断言不以 `=n` 结尾的行；
   注释行会被 `grep '^CONFIG_…='` 过滤掉，于是 `common.config` 里的 `=y` 仍是"最后一个值"，
   照样进断言清单 —— 而它在最终 `.config` 里已被 defconfig 关掉，**符号校验必然失败**。

2. **LuCI 语言包不能用 `CONFIG_PACKAGE_luci-i18n-…=y` 打开。**
   `luci.mk` 生成的 i18n 包都带 `HIDDEN:=1`（没有 prompt），kconfig 会忽略 `.config` 里的值。
   正确做法是打开语言开关：`CONFIG_LUCI_LANG_zh_Hans=y`。

3. **内存档位是编译期写死的，且整镜像生效。**
   QHora-301W 是 1GB RAM，所以是 `CONFIG_ATH11K_MEM_PROFILE_1G=y` + `CONFIG_NSS_MEM_PROFILE_HIGH=y`。
   档位选错**构建不会报错**，但上机后无线 / NSS 行为会不对。

另外 `nss-edma-rework` 分支与 `edma-nss` feed **会被上游定期 rebase**，本地增量 `git pull` 无效，
要 `git fetch origin && git reset --hard origin/nss-edma-rework` 并清掉 `feeds/nss`。

---

## 五、sing-box 版本（两条 HomeProxy 线走了相反的路）

| 工作流 | `SINGBOX_MODE` | sing-box | 说明 |
|---|---|---|---|
| `build-qhora-301w-homeproxy.yml`（正式线） | `fixed`（默认） | **钉 1.12.25** | 从 `immortalwrt/packages@openwrt-25.12` 取配方覆盖基座那份 |
| `Build imm QHora-301W (NSS EDMA, HomeProxy).yml` | 同上 | 同上 | 与正式线内容一致的副本 |
| `build-qhora-301w-homeproxy-sb114.yml`（实验线） | `builtin` | **基座自带**（`openwrt/packages`，1.14.0） | 不换版本、不打补丁 |
| `build-qhora-301w-imm-nss-homeproxy.yml`（第四条线） | `builtin` | **基座自带**（`immortalwrt/packages`，1.14.3） | 同上 |

先纠正一个流传很久的错话：**`set_system_proxy` 不是 legacy 字段。** 它在 sing-box 1.14.x 的
`option/simple.go` 里仍是 `HTTPMixedInboundOptions` 的合法成员（1.14.0 与 1.14.3 都一样）。
真正会让 `sing-box check` 报错的是 `option/inbound.go` 里的 `SniffEnabled` /
`SniffOverrideDestination` / `SniffTimeout`：

```
FATAL: legacy inbound fields are deprecated in sing-box 1.11.0 and removed in sing-box 1.13.0
```

`/etc/init.d/homeproxy` 会据此 `return 1` —— **服务永远起不来**，而且这是**运行期**才暴露的问题
（编得出来、刷得进去、跑不起来）。

### 实测对照（官方二进制，与固件里那份同版本）

同一份配置形态，两个版本分别跑 `sing-box check`：

| 配置形态 | 1.12.25 | 1.14.3 |
|---|---|---|
| **迁移后写法**：`route.rules` 里 `{ action: 'sniff' }` / `{ action: 'hijack-dns' }`，inbound 带 `set_system_proxy: false`，规则集 `type: local` | ✅ 通过 | ✅ 通过 |
| **legacy 写法**：inbound 上直接写 `sniff: true` | ✅ 通过（1.12 上还合法） | ❌ FATAL（上面那条） |

这张表解释了两条线的全部理由：**迁移后的写法两个版本都吃**，所以"迁移后的生成器 + 1.12.25"
（正式线现在的实际组合）和"迁移后的生成器 + 1.14.3"（builtin 那两条）都成立；而 legacy 写法在
1.14 上必挂，所以才需要"把 sing-box 钉回 1.12.25"或者"换掉生成器"。

### 正式线：钉 1.12.25（`SINGBOX_MODE=fixed`）

做法是从 `immortalwrt/packages` 取 `net/sing-box` 覆盖基座那份，并做**两道硬断言**：

1. `extra-packages.sh` 断言引入的**配方版本** == `SINGBOX_EXPECT`（默认 `1.12.25`；
   工作流输入 `singbox_expect` 可覆盖，支持通配如 `1.12.*`）；
2. 工作流「校验功能包是否真的编进固件」再断言**实际编出的那个包**的版本以 `1.12.25` 开头。

任一不符则 `::error::` 并中断构建 —— 宁可编不出来，也不产出一份 HomeProxy 起不来的固件。

#### ⚠️ 取 1.12.25 的那个 ref 是**发布分支**，不是 master

`SINGBOX_PKGS_REF`（默认 `openwrt-25.12`）决定从 `immortalwrt/packages` 的哪个 ref 取它，
**故意不跟 `imm_ref` 走**：

```
2026-10-15T09:30:34Z   immortalwrt/packages 提交 0d7620f1ab7d
    "sing-box: Update to 1.14.3"        master: 1.12.25  →  1.14.3
```

master 上已经没有 1.12.25 了，跟着 master 走必然在版本断言处失败 —— 这正是 2026-10-16 那轮
CI 红掉的原因（报错里会直接指出这一点）。仍带 1.12.25 的 ref：

| ref | sing-box |
|---|---|
| `openwrt-25.12` | 1.12.25 ← **默认** |
| `openwrt-24.10` | 1.12.25 |
| `ea19b15494f4ec531d608a9e9324e8794d47544f` | 1.12.25（master 上最后一次） |
| `openwrt-23.05` | 1.11.15（不要用） |

工作流输入 `singbox_pkgs_ref` 可以按次覆盖它。

### 实验线：反过来 —— 用基座自带的新版 sing-box（`SINGBOX_MODE=builtin`）

`build-qhora-301w-homeproxy-sb114.yml` 原来走 `latest`：不换配方、把 `PKG_VERSION` 改成输入
`singbox_version` 并重算 `PKG_HASH`，再调 `scripts/patch-homeproxy-for-singbox113.py` 给生成器
打补丁。**这条路现在必然失败**，因为上游自己把这件事做完了：

- `immortalwrt/luci` 的 `generate_client.uc` 已迁移到 1.13+ 写法 —— `route.rules` 里直接就是
  `{ action: 'sniff' }` / `{ action: 'hijack-dns' }`，1.13 删掉的那两个 inbound 字段
  **已删干净**；
- 于是补丁脚本的正则匹配不上新结构，`latest` 会在"打补丁"这一步报错（实测确认）。

所以实验线改走 `builtin`：**两边都不动**。它的输入里 `singbox_version` / `singbox_expect`
已删除（不再换版本，留着只会误导 —— 填了不生效，界面却写着"要编的版本"）。产物阶段改为核对
两件事：真正进固件的 sing-box 版本，以及同轮源码树里的 `generate_client.uc` 有没有 legacy
inbound 字段（只认 `字段: true`；上游那份 `set_system_proxy: false` 不在此列，老版本的本步骤
把它当 legacy 是**误杀**）。

`extra-packages.sh` 里的 `latest` 通道与那个补丁脚本都保留着（万一上游回退还有出口），
但**目前没有工作流用它**。

实验线只能手动触发，产物单独打标签 `qhora-301w-homeproxy-sb114-*`，不会和正式线混。

### 另外还有个「必须有」：ucode 的 `math` 模块

`generate_client.uc` 第 11 行是 `import { isnan } from 'math';`，而 ucode 的每个模块都是
**独立子包**（`/usr/lib/ucode/<名>.so`，见 `package/utils/ucode/Makefile` 里的 `UcodeModule`
列表）—— 基础包 `ucode` 只依赖 `libucode`，**本身不带 `math`**。
`luci-base` 的依赖里只有 `ucode-mod-fs` / `-log` / `-uci` / `-ubus`，
`luci-app-homeproxy` 自己只声明了 `+ucode-mod-digest`，**`math` 谁都不会拉**（上游漏声明）。

少了它的后果同样是**运行期**才暴露：

```
Syntax error: Unable to resolve path for module 'math'
In line 11, byte 29:
`import { isnan } from 'math';`
Near here ------------------^
[DAEMON] Error: failed to generate client configuration.
```

HomeProxy 起不来。所以 `configs/homeproxy.config` 显式选了 `CONFIG_PACKAGE_ucode-mod-math=y`，
HomeProxy 工作流的「校验功能包」清单里也点名核对它 —— 保证不会又编出一份跑不起来的固件。
（`isnan` 确实由 `math` 模块导出，装上即好，不需要打补丁。）

> 已经刷了不带这个包的固件：设备上 `apk add ucode-mod-math` 再 `/etc/init.d/homeproxy restart`。

---

## 六、排查

整个流程都刻意做成**失败可远程诊断**：`prepare-build.sh` 的输出落盘并在失败时以 `::error::`
报出「出错行号 + 失败命令 + 日志尾部」；`make` 的输出也全程落盘，失败时把**失败的包名**和
**真实报错行**发成注解 —— 因为作业日志公开侧拿不到，不做这个就只剩一句
`Process completed with exit code 2.`。

| 注解 | 含义 | 处理 |
|---|---|---|
| `defconfig 丢弃了 N 个配置请求的符号` | Kconfig 依赖没满足 / 符号没有 prompt | 后面会逐个列出符号名，对照 `configs/` 修 |
| `编译失败的包::<包路径>` | 该包没编过 | 到「回放编译日志」里搜这个包名 |
| `sing-box 配方版本不符` / `sing-box 实际版本是 …` | 版本断言失败 | 见第五节 |
| `ddns-go / msd_lite 解析上游最新版本失败`（warning） | 查 API 或算 hash 失败 | **不影响构建**，会用配方兜底值；重跑即可 |
| `克隆 … 失败（分支 …）` | 仓库浅克隆失败 | 检查分支是否存在、仓库地址、网络 |

常见问题：

- **构建超时（6 小时）** —— 首次没有 ccache 最慢。直接重跑一次，`dl` 与 ccache 会复用。
- **artifact 里没有 sysupgrade 镜像** —— 工作流在"收集并校验产物"那步就 `exit 1` 报出来，
  不会静默给你空包。
- **首页没有 `Temperature` / `CPU usage (%)` 这两行** —— 它们是**三处配套**的结果，
  缺一环就整行不见（见第三节）：
  1. `autocore` 提供 `/sbin/tempinfo`、`/sbin/cpuinfo`；
  2. ImmortalWrt 版 `luci-base` 的 rpcd ucode 插件提供 ubus `luci.getTempInfo` /
     `getCPUInfo` / `getCPUUsage`（官方 openwrt/luci **没有**这几个方法）；
  3. ImmortalWrt 版 `luci-mod-status` 的 `10_system.js` 负责把它们画出来。
  设备上按顺序自查：`/sbin/tempinfo` 有输出 → 数据源 OK，问题在 ②③；
  `ubus -v list luci | grep getTempInfo` 有 → ② OK；再看 LuCI 里那一块有没有渲染（③）。
  三条命令都给空 → 会话 ACL 没刷：`/etc/init.d/rpcd restart` 后**退出重新登录** LuCI。
- **`/sbin/tempinfo` 这个文件不存在** —— 配方里它只对 `ipq% / mediatek% / qualcommax%`
  目标安装，QHora 是 qualcommax ✓；真缺失说明刷的是更早的 build。
- **温度只有 `CPU: xx°C`，没有 WiFi** —— `cat /sys/class/ieee80211/phy*/hwmon*/temp1_input`
  看 WiFi 温区在不在；射频没开时读数本来就不动。
- **首页那两行在页面最底部、或出现两块内存** —— 那是早期版本留下的自写 JS
  （`/www/luci-static/resources/view/status/include/95_qhora_hw.js`）还在。
  从 2026-10-10 起已改为上游原生方案并删除该文件，刷新 build 即恢复正确顺序。
- **首页「架构」显示 `? x 4 (1651MHz)`** —— 本固件已修（见「唯一的源码改动」）。原因是
  `autocore` 的 `/sbin/cpuinfo` 只认 `/proc/cpuinfo` 的 `model name` 字段，而 arm64 内核
  默认**只为 32 位进程**打印这一行（`if (compat)` 那处），64 位的 shell 读不到就回落成 `?`；
  核数 `x 4` 与频率 `1651MHz` 都是真值，纯显示瑕疵、零功能影响。旧 build 上自查：
  `grep -c 'model name' /proc/cpuinfo` 返回 **0** 就是中招（修好后应 ≥1，那一格变成
  `ARMv8 Processor rev N (v8l) x 4`）。注意它显示的其实是 **CPU 型号**、不是架构名 ——
  x86 上那一格显示的是 `Intel(R) Celeron...`，arm32 上是 `ARMv7 Processor rev N`。
- **注解报 `defconfig 丢弃了 N 个配置请求的符号`，且符号都是 NSS 相关的** —— 十有八九是
  上游改了 feed 的包名或删了包。2026-10-10 就撞过一次：feed 提交 `qca-mcs: remove` 把
  `kmod-qca-mcs` 整个删了，我们 `configs/common.config` 里那一行随即变成必然失败
  （HomeProxy 线只丢这 1 个符号）。**权威对照物是上游自己的
  `JuliusBairaktaris/Qualcommax_NSS_Builder`** —— 它的 `devices/common/config`
  与 `devices/ipq807x-1g/config` 就是本仓库 `configs/` 的源头，上游改包名时这两个
  文件会同步更新。逐符号 diff 一下就定位了：
  `devices/ipq807x-1g/config` 我们只少那 31 个别的机型，其余全一致。
- **同一次推送里两条线丢的符号不一样** —— 说明上游正在连推多个提交，两条线
  check out 到了中间的不同状态。等上游推完重跑即可，不用改我们的代码。
- **HomeProxy 起不来，日志报 `Unable to resolve path for module 'math'`** —— 缺 `ucode-mod-math`
  （见第五节）。早期 build 没带这个包；设备上 `apk add ucode-mod-math` 后重启 HomeProxy 即可。
- **passwall2 日志报 `sslocal not found`** —— 节点类型是 `SS-Rust` 但固件里没有 `sslocal`。
  本固件已编入；刷的是更早的 run 就把 SS 类型改成 `sing-box`（sing-box 原生支持 SS）。
- **为什么固件里没有 xray** —— 刻意的：`Basic_Core_SingBox=y`，只编 sing-box。它覆盖
  SS / SSR / VMess / VLESS / Trojan / Hysteria2 / WireGuard 全部常用协议，`_shunt` 分流
  也是它自己实现的。
- **网页能登录、SSH 一直提示密码错误** —— 不是密码打错了，是 sshd 的策略：本固件用
  openssh（不是 dropbear），上游默认 `PermitRootLogin prohibit-password`（root 只收公钥），
  空密码还会被 `PermitEmptyPasswords no` 挡掉；LuCI 走 rpcd，密码哈希为空时直接放行，
  所以**只有 SSH 受影响**。补 `/etc/ssh/sshd_config.d/10-root-login.conf` 并给 root
  设密码即可，详见「三、刷完之后 → SSH 登录」。
- **`scp` 报 `subsystem request failed`** —— openssh ≥9 的 `scp` 默认走 SFTP 协议，
  需要 `sshd_config` 里有 `Subsystem sftp /usr/libexec/sftp-server`（本固件带的覆盖版
  有这行；`openssh-sftp-server` 也已编入）。临时可用 `scp -O` 退回旧协议。

dae 专属（第六条线）：

| 现象 | 原因 | 处理 |
|---|---|---|
| 构建在「验真 vmlinux 的 .BTF 段」处 `::error::` 中断 | 内核没真编出 BTF | 检查 `configs/dae.config` 里 `CONFIG_KERNEL_DEBUG_INFO_REDUCED=n` 是否被别的覆盖层改回 `y`（BTF `depends on !REDUCED`，会被静默丢弃） |
| 构建报 `defconfig 丢弃了 N 个配置请求的符号`，且都是 `KERNEL_*` | 那个符号在当前基座内核版本里没 prompt | 对照 `target/linux/generic/config-6.18` 与 `config/Config-kernel.in` 逐项核 |
| `dae` 启动失败，日志里有 `failed to load eBPF` / `BTF` 字样 | 内核没有 `/sys/kernel/btf/vmlinux` | `ls /sys/kernel/btf/vmlinux`；没有 = 刷的不是 dae 线固件 |
| `dae validate` 不过、服务起不来（但网络正常） | ① 没填订阅（出厂默认就是这个状态）；② 配置语法错 | `dae validate -c /etc/dae/config.dae -l debug` 看具体行；init 脚本 validate 失败会直接 `return 1`，**不会 respawn 循环**，所以不会拖垮网络 |
| 日志刷 `bootstrap resolver returned no usable address for "c38s1.xxx"` | 死循环：要解节点域名 → DNS 查询走代理 → 代理要先知道节点 IP | `dns.routing.request` 里加 `subnode(subtag: <订阅标签>) -> alidns`，让节点域名直接走国内 DNS（出厂配置已带） |
| 日志里 `sniffed=` 全是空、域名规则时灵时不灵 | ① `sniffing_timeout` 太小（30ms 抓不到 ClientHello）；② `dial_mode: domain` 是先按 IP 分流后嗅探，dnsmasq 缓存命中时 dae 没有 domain→IP 映射 | 出厂配置已改 `sniffing_timeout: 300ms` + `dial_mode: domain++`；自己改过就照这两行补 |
| 换了 geo 数据后所有流量都走 `fallback`、`Routing match set len` 从 18 掉到 16 | `geosite.dat` 太大/格式不兼容，dae 静默少编译了一批规则 | `dae-geo-update` 用默认的 v2fly 源重来一遍（它会拦 >6MB 的文件），或从 `/root/geo-backup/` 回滚 |
| `apk upgrade v2ray-geoip` 之后数据反而变旧 | snapshot 的 packages 索引比固件里的版本还老 | 用 `dae-geo-update`，别用 apk 升这两个包 |
| 日志刷 `DNS forward to upstream failed ... udp ... i/o timeout` | DNS 用 `tcp+udp://` 时先发 UDP，UDP 经节点容易丢 | 上游改成 `tcp://dns.google:53`（出厂配置已改，实测失败数从 12 条/40s 降到 0） |
| `/etc/init.d/dae status` 说 `running`，但 `pgrep -af "dae run"` 是空的、`/var/log/dae` 也不存在（procd 的 `active with no instances`） | **`/etc/dae/config.dae` 权限太宽**。`dae validate` 会拒绝 group 可写 / other 可读的文件，报 `permissions 0644 ... are too open; requires ... 0640 or 0600`。**0644 也不行** | `chmod 600 /etc/dae/config.dae && /etc/init.d/dae restart`。造镜像时 `scripts/prepare-build.sh` 已统一收紧，`/etc/uci-defaults/98-dae-config-perms` 首启再兜一次；自己手改过就用这条修 |
| 路由器本机能翻墙，**LAN 客户端全是直连**（日志里只有 `Bind to WAN`，没有 `Bind to LAN`） | `global` 段没写 `lan_interface`。dae 上游默认**不代理 LAN**（`example.dae` 里这行是注释掉的） | 加上 `lan_interface: br-lan` 再 `restart`；日志应出现 `Bind to LAN: br-lan`。多网口用逗号分隔 |
| 填了节点、启用后全部断网 | 节点连不上（订阅没拉到 / 节点已失效），而 routing 已 `fallback: proxy` | 先 `dae validate` 再启用；`/var/log/dae/dae.log` 里看节点握手。**别把 fallback 改成 `direct`**，那只是把问题藏起来。想快速试单节点：`dae-switch pin 0 && dae-switch use pin` |
| LuCI 里没有「服务 → dae」 | `luci-app-dae` 没编进去 | `apk list --installed \| grep dae`；缺就说明刷的是别的线 |
| 某些网站打不开、但 TCP 站点正常 | 该站走 HTTP/3（UDP 443） | 骨架里已 `l4proto(udp) && dport(443) -> block`；自己改过配置的要保留这条 |
| `dae-geoip` / `dae-geosite` 装了但规则里 `geoip:cn` 不生效 | `/usr/share/dae/` 下没有数据文件 | `ls -l /usr/share/dae/` 应看到两个指向 `/usr/share/v2ray/*.dat` 的软链；`v2ray-geoip`/`v2ray-geosite` 没装则软链悬空 |

---

## 七、本地编译（不用 CI）

```sh
# ① nss-edma 基座（第一/二条线）
git clone -b nss-edma-rework https://github.com/JuliusBairaktaris/openwrt-nss-edma openwrt

# ② immortalwrt 基座（第三/四/六条线）：先移植 NSS，再走同一个 prepare-build.sh
git clone --depth 1 https://github.com/immortalwrt/immortalwrt openwrt
cd openwrt
OPENWRT_DIR="$PWD" BUILDER_DIR="../qhora-301w-build" \
  bash ../qhora-301w-build/scripts/prepare-build-imm-nss.sh
cd ..

cd openwrt
export GH_TOKEN=<你的 GitHub token>     # 可选但建议：避免撞未认证 API 限额（60 次/小时）
PROXY_STACK=passwall2 \                 # 或 homeproxy / dae（dae 必须用 immortalwrt 基座）
OPENWRT_DIR="$PWD" BUILDER_DIR="../qhora-301w-build" \
  bash ../qhora-301w-build/scripts/prepare-build.sh

make -j"$(nproc)"
```

`prepare-build.sh` 会做完所有准备：追加 nss feed、落位自带配方与 ImmortalWrt 前端、引入代理栈、
解析 ddns-go / msd_lite 上游版本、`feeds update/install`、拼 `.config`、`defconfig`、校验符号、
叠加 `files/` 与变体覆盖层。

依赖（Ubuntu 24.04/26.04）：`bzip2 g++ gawk gcc git glibc-source libncurses-dev make curl`，
磁盘留 **35GB** 以上。脚本里用的是 `cp -a` 而不是 `rsync`，**不需要**装 rsync。

---

## 八、致谢与许可

编译配方与配置来自
[JuliusBairaktaris/Qualcommax_NSS_Builder](https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder)（GPL-2.0）。
NSS 上游链路涉及 [Ansuel](https://github.com/Ansuel)（EDMA/PPE 驱动）、
[robimarko](https://github.com/robimarko)（qualcommax target 维护）、
[qosmio](https://github.com/qosmio)（NSS 打包与 Wi-Fi 卸载补丁）以及
OpenWrt 的 [NSS build 讨论帖](https://forum.openwrt.org/t/qualcommax-nss-build/148529)。

本仓库内容沿用 GPL-2.0。
