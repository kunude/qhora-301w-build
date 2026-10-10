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

## 目录结构

```
.github/workflows/          # 两条构建线
configs/
  common.config             # NSS 卸载栈 + 通用选项 + 附加功能包
  qhora_301w.config         # 机型：target / 子目标 / 设备 / 内存档位
  homeproxy.config          # 覆盖层：关掉 passwall2 那组、换成 HomeProxy
packages/net/{ddns-go,msd_lite}/   # 自带配方（直接引用上游源码，版本构建时解析注入）
packages/emortal/autocore/         # 纯脚本包，提供 tempinfo / cpuinfo
scripts/
  prepare-build.sh          # 组装 .config、跑 defconfig、校验符号、叠加覆盖文件
  extra-packages.sh         # 把 feed 里没有 / 不该用官方那份的包放进 feed 目录树
  resolve-versions.sh       # 构建时解析 ddns-go / msd_lite 的上游最新版本
  check-no-credentials.sh   # 构建期守卫：预置文件里出现凭据/订阅链接就中断
files/                      # 两个变体共用的覆盖文件（uci-defaults、首页硬件区块等）
files-passwall2/            # 只叠进 passwall2 版：etc/config/passwall2
files-homeproxy/            # 只叠进 HomeProxy 版：etc/config/homeproxy
```

**预置文件里只有「策略」，没有「凭据」。** 节点地址 / 端口 / 密码 / UUID / REALITY 公钥 /
订阅链接一律不进仓库 —— 固件是公开产物，写进去等于公开。每次构建都会跑
`scripts/check-no-credentials.sh` 扫 `files*/etc/config/`，命中就**中断构建**。

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
   `root` 无密码。电脑重取一次 DHCP，再刷 sysupgrade：

   ```sh
   scp openwrt-...-qnap_301w-squashfs-sysupgrade.bin root@192.168.35.1:/tmp/
   ssh root@192.168.35.1
   fw_printenv -n current_entry      # 必须是 0，不是就 fw_setenv current_entry 0
   sysupgrade -n /tmp/openwrt-...-qnap_301w-squashfs-sysupgrade.bin
   ```

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

### 附加服务

| 服务 | 状态 | 怎么用 |
|---|---|---|
| **ddns-go** | 开机自启 | Web `http://<路由器IP>:9876` 添加 DDNS 记录；数据在 `/etc/ddns-go/config.yaml` |
| **msd_lite** | 开机自启 | 客户端按 `http://<路由器IP>:7088/udp/<组播地址>:<端口>` 取流。**收组播的网卡要在 `服务 → msd_lite` 里选**（出厂留空，填错的表现是端口能连但拉不到流） |
| **WireGuard** | 仅装好 | 无常驻服务；到 `网络 → 接口` 新建一个 `wg` 协议接口即可 |
| **passwall2 / HomeProxy** | 已预置，未启用 | 见上两节 |
| **statistics** | 开机自启 | `状态 → 统计` 有 CPU / **温度** / 内存 / 接口流量 / 无线曲线。温度采集由 uci-defaults 默认打开 |
| **首页硬件区块** | 装好即生效 | `状态 → 总览` 底部多出「CPU / 温度 / 内存」，**不依赖 collectd**，开机就有数（与统计页的历史曲线是两回事） |
| **autocore** | 装好即生效 | `tempinfo`（`CPU: 52.3°C, WiFi: 61.0°C`）与 `cpuinfo` 两个脚本 |

LuCI 默认简体中文。`状态 → NSS Offload` 那一页是英文 —— 它是 NSS 主树里的纯 JS 页面，
不走 luci.mk，没有翻译文件，语言开关对它无效，这是上游现状。

验证服务真的起来了：

```sh
/etc/init.d/ddns-go status ; /etc/init.d/msd_lite status
ls /etc/rc.d/ | grep -E 'ddns-go|msd_lite'    # 有 S99 链接 = 开机自启生效
/etc/init.d/passwall2 status ; /etc/init.d/homeproxy status
sing-box version ; sslocal --version          # 两个核心二进制在不在
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

## 五、sing-box 版本（HomeProxy 版必须是 1.12.25）

HomeProxy 生成的 client 配置里**仍写着 sing-box 1.13 已删除的 inbound 字段**
（`sniff` / `sniff_override_destination` / `set_system_proxy`）。在 1.14 上：

```
FATAL: legacy inbound fields are deprecated in 1.11.0 and removed in 1.13.0
```

`/etc/init.d/homeproxy` 会据此 `return 1` —— **服务永远起不来**，而且这是**运行期**才暴露的问题
（编得出来、刷得进去、跑不起来）。三处来源的实测版本：`openwrt/packages` = 1.14.0、
`openwrt-passwall-packages` = 1.14.0、**`immortalwrt/packages` = 1.12.25**。

所以 HomeProxy 版从 `immortalwrt/packages` 取 `net/sing-box` 覆盖官方那份，并做了**两道硬断言**：

1. `extra-packages.sh` 断言引入的**配方版本** == `SINGBOX_EXPECT`（默认 `1.12.25`；
   工作流输入 `singbox_expect` 可覆盖，支持通配如 `1.12.*`）；
2. 工作流「校验功能包是否真的编进固件」再断言**实际编出的那个包**的版本以 `1.12.25` 开头。

任一不符则 `::error::` 并中断构建 —— 宁可编不出来，也不产出一份 HomeProxy 起不来的固件。

> 上游哪天把 `immortalwrt/packages` 的 sing-box 抬到 1.13+，构建会在这里明确失败。
> 出路：① 把 `imm_ref` 钉到 sing-box 仍是 1.12.25 的那个提交；② 确认 HomeProxy 的配置
> 生成器已兼容后，设 `singbox_expect` 显式放行。

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
- **首页硬件区块显示 `?`** —— rpcd 拒读：确认 `/usr/share/rpcd/acl.d/qhora-overview.json`
  在固件里，然后退出重新登录 LuCI 让会话重取 ACL。
- **首页温度某些项是空的** —— `cat /sys/class/thermal/thermal_zone*/type` 看内核暴露了哪些；
  `wcss-*` 是 WiFi 子系统，射频没开时读数不动属正常。
- **passwall2 日志报 `sslocal not found`** —— 节点类型是 `SS-Rust` 但固件里没有 `sslocal`。
  本固件已编入；刷的是更早的 run 就把 SS 类型改成 `sing-box`（sing-box 原生支持 SS）。
- **为什么固件里没有 xray** —— 刻意的：`Basic_Core_SingBox=y`，只编 sing-box。它覆盖
  SS / SSR / VMess / VLESS / Trojan / Hysteria2 / WireGuard 全部常用协议，`_shunt` 分流
  也是它自己实现的。

---

## 七、本地编译（不用 CI）

```sh
git clone -b nss-edma-rework https://github.com/JuliusBairaktaris/openwrt-nss-edma openwrt
cd openwrt

export GH_TOKEN=<你的 GitHub token>     # 可选但建议：避免撞未认证 API 限额（60 次/小时）
PROXY_STACK=passwall2 \                 # 或 homeproxy
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
