# QHora-301W · OpenWrt NSS EDMA 自动编译

用 GitHub Actions 为 **QNAP QHora-301W**（`qualcommax` / `ipq807x` / `qnap_301w`）
编译带 **Qualcomm NSS 硬件卸载**（NAT、PPPoE、SQM、网桥、ath11k Wi-Fi）的 OpenWrt 固件。

源码来自 [`JuliusBairaktaris/openwrt-nss-edma`](https://github.com/JuliusBairaktaris/openwrt-nss-edma)
的 **`nss-edma-rework`** 分支 —— 即 OpenWrt `main` 加上一整套跑在
上游 `qca_edma` / `qca_ppe` 驱动之上的 NSS 固件支持
（不使用 out-of-tree 的 `qca-nss-dp` / `qca-ssdk`）。

---

## 一、这个仓库是什么

它本身**不包含 OpenWrt 源码**，只是一个"编译配方"仓库：工作流运行时会把上游源码
拉下来，套上这里的配置编译。这样你不需要 fork 一个几百 MB 的 OpenWrt 树。

```
.
├── .github/workflows/
│   ├── build-qhora-301w.yml                 # 编译工作流（主线：passwall2 版）
│   └── build-qhora-301w-homeproxy.yml       # 同一套流水线的 HomeProxy 版（见第五节末）
├── configs/
│   ├── common.config                        # NSS 卸载栈 + 通用选项 + 附加功能包
│   ├── homeproxy.config                     # 覆盖层：把 passwall2 那组换成 HomeProxy
│   └── qhora_301w.config                    # 机型：target/子目标/设备/内存档位
├── packages/net/                            # 本仓库自带的包配方（直接引用上游源码）
│   ├── ddns-go/                             #   Makefile + files/（init、UCI 默认配置）
│   └── msd_lite/                            #   同上
├── scripts/
│   ├── prepare-build.sh                     # 组装 .config、跑 defconfig、校验、叠加覆盖文件
│   ├── extra-packages.sh                    # 把自带配方 / ImmortalWrt 前端 / 代理栈放进 feed 目录树
│   ├── resolve-versions.sh                  # 构建时解析上游最新版本，注入到上面两个配方
│   └── push-to-github.sh                    # 本地一键推送脚本
├── files/                                   # 原样叠加进固件的覆盖文件（两个变体共用）
│   ├── etc/uci-defaults/99-qhora-301w       #   首次启动的设置（主机名、LAN 网段、启用服务）
│   ├── etc/uci-defaults/99-luci-statistics  #   打开 collectd 的温度采集
│   ├── www/luci-static/resources/view/status/include/95_qhora_hw.js
│   │                                        #   首页「CPU / 温度 / 内存」区块（见第六节 7）
│   └── usr/share/rpcd/acl.d/qhora-overview.json
│                                            #   上面那个 JS 读 /proc、/sys 的 rpcd 授权
├── files-passwall2/                         # 变体专属覆盖层：只叠进 passwall2 版固件
│   └── etc/config/passwall2                 #   passwall2 出厂预置：分流/DNS/选路，节点留空
├── files-homeproxy/                         # 变体专属覆盖层：只叠进 HomeProxy 版固件
│   └── etc/config/homeproxy                 #   HomeProxy 出厂预置：custom 三分流/DNS/订阅开关，
│                                            #   节点与订阅链接留空
├── .gitattributes / .gitignore
└── README.md
```

> 出厂代理配置按变体分开放：passwall2 的在 `files-passwall2/`，HomeProxy 的在
> `files-homeproxy/`，都只出现在对应变体的固件里。`prepare-build.sh` 会先叠 `files/`，
> 再叠 `files-<PROXY_STACK>/`（对方目录不存在就跳过），后者同名文件覆盖前者。
>
> **这两份预置里只有「策略」，没有任何「凭据」** —— 节点地址、端口、密码、UUID、
> REALITY 公钥、机场订阅链接一律不进仓库：固件是公开产物，写进去就等于公开。
> 构建时会跑 `scripts/check-no-credentials.sh` 扫一遍 `files*/etc/config/`，
> 命中疑似凭据或订阅链接就**直接中断构建**（连合法内容如规则集 URL 不会被误判），
> 把问题挡在 CI 里，而不是等镜像发出去才发现。

`configs/` 里的内容取自上游作者自己维护的
[Qualcommax_NSS_Builder](https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder)
的 `devices/common/config` 与 `devices/ipq807x-1g/config` —— 那是这套 NSS 栈
**唯一被持续验证过**的配置组合，所以基本保持原样，只做了两处针对性改动（见下），
外加在文件末尾追加了 ddns-go / msd_lite / WireGuard / passwall2 / statistics 五组独立的功能包，
以及一个首页硬件区块（`files/www/…/status/include/95_qhora_hw.js`，见第五节、第六节 7）。

---

## 二、怎么用

### 1. 建一个仓库并推上去

**先在 GitHub 网页上建一个空仓库**（`https://github.com/new`，公开/私有都行，
**不要**勾 Add a README / .gitignore / license）。然后二选一：

**A. 用配套脚本（推荐）** —— 会自动检查 SSH、配置身份、提交并推送：

```sh
# 前提：已把 ~/.ssh/id_ed25519_github.pub 加到 GitHub 的 SSH keys
scripts/push-to-github.sh <你的用户名> [提交邮箱] [仓库名]
```

不传邮箱时默认用 `<用户名>@users.noreply.github.com`。脚本是幂等的，
重复跑只会补提交，不会重复初始化。

**B. 手动推**：

```sh
cd qhora-301w-build
git init -b main
git add -A
git commit -m "QHora-301W NSS EDMA build"
git remote add origin git@github.com:<你的用户名>/<仓库名>.git
git push -u origin main
```

### 2. 打开工作流写权限（只有勾选 Release 时才需要）

`Settings → Actions → General → Workflow permissions` → 选 **Read and write permissions**。
不打算发 Release 的话保持默认即可。

### 3. 跑一次

`Actions` → 左侧 `Build QHora-301W (NSS EDMA)` → `Run workflow`：

| 输入项 | 说明 |
|---|---|
| `upstream_ref` | 要编译的上游 ref，默认 `nss-edma-rework`。也可以填 tag 或 commit |
| `release` | 勾上则编译成功后创建 Release 并把镜像挂上去；不勾就只出 Actions artifact |
| `ddns_go_version` | 留空 = 跟随上游最新 release；填 `6.17.7` 这类版本号则钉死（见第五节） |
| `msd_lite_sha` | 留空 = 跟随上游 `master` HEAD；填 commit sha 则钉死 |

后两个输入只影响 `ddns-go` / `msd_lite` 这两个包。**平时留空即可** —— 留空就是
"上游一发新版，下次构建自动编新版"。需要可复现的固件时才填。

推送改动、或每周一 00:30（东八区）定时检查上游更新时也会自动触发（定时触发只出 artifact）。
`push` / `schedule` 这两种触发方式没有输入框，两个值天然为空，所以走的也是"跟随上游最新"。

### 4. 取固件

构建完成后在 **Artifacts** 里下载 `openwrt-qnap_301w-<run_number>`，里面是：

| 文件 | 用途 |
|---|---|
| `openwrt-...-qnap_301w-**initramfs**-uImage.itb` | **首次安装**：U-Boot 里用 TFTP 引导它 |
| `openwrt-...-qnap_301w-squashfs-**sysupgrade**.bin` | 日常升级（设备已在跑 OpenWrt） |
| `openwrt-...-qnap_301w-squashfs-**factory**.bin` | eMMC 整盘写入 |
| `sha256sums` | 刷机前校验用 |
| `config.buildinfo` | 这次镜像里到底选了什么，用于溯源 |
| `profiles.json` | 本次构建实际产出的设备列表 |

---

## 三、刷机

> ⚠️ **不保留原厂系统的分区**。QHora-301W 是 A/B 双分区，下面只动第 0 组
> （`mmcblk0p1` / `mmcblk0p4`），第 1 组原样保留，随时可以 `fw_setenv current_entry 1` 切回原厂。

### 首次安装（设备还没跑 OpenWrt）

需要一根 USB-TTL 串口线。

1. 串口接好，路由器上电，在 U-Boot 字符输出出现时**一直敲空格**打断自动启动。
2. 电脑上开 TFTP 服务，把 `initramfs-uImage.itb` 放到 TFTP 根目录。
3. U-Boot 里执行：

   ```
   setenv serverip 192.168.10.2      # 你电脑的 IP
   setenv ipaddr   192.168.10.10     # 随便给路由器一个同网段 IP
   saveenv
   tftpboot openwrt-...-qnap_301w-initramfs-uImage.itb
   bootm
   ```

4. 起来后路由器地址是 **`192.168.35.1`**（本仓库把出厂默认的 `192.168.1.1` 换掉了，
   见第四节），`root` 无密码。电脑重新获取一次 IP（DHCP 会发 `192.168.35.x`），
   然后把 sysupgrade 镜像传上去：

   ```sh
   scp openwrt-...-qnap_301w-squashfs-sysupgrade.bin root@192.168.35.1:/tmp/
   ssh root@192.168.35.1
   sysupgrade -n /tmp/openwrt-...-qnap_301w-squashfs-sysupgrade.bin
   ```

   注意先确认 `fw_printenv -n current_entry` 输出是 `0`，不是就 `fw_setenv current_entry 0`。

### 以后升级

```sh
sysupgrade -n /tmp/openwrt-...-qnap_301w-squashfs-sysupgrade.bin
```

或者在 LuCI 里 `系统 → 备份/刷写固件`。

### 回原厂

U-Boot 里打断启动：

```
setenv current_entry 1
saveenv
bootipq
```

### 10GbE 网口（Aquantia AQR113C）

两个万兆口需要 Aquantia PHY 固件才能工作，而这个固件存在板子的 `0:ETHPHYFW`
mtd 分区里，原厂系统里才有。**建议在动手前先从原厂系统把这个分区备份出来**，
否则刷完 OpenWrt 后万兆口不亮。

```sh
# OpenWrt 里
cat /proc/mtd | grep -i ethphyfw
dd if=/dev/mtd10 of=/tmp/ethphyfw.backup
```

如果分区是空的，可以从原厂固件里解出 `AQR_ethphyfw.mbn` 写进去，然后在 U-Boot 里
把加载固件加进 bootcmd（`aq_load_fw 0; aq_load_fw 8; bootipq`）。
细节见 [OpenWrt 设备页](https://openwrt.org/toh/qnap/301w)。

---

## 四、刷完之后

NSS 卸载**开机自动启动**，镜像先按主机协议栈起来，再切到 NSS 数据面。

```sh
nss-status                                  # 健康状态
logread -e nss                              # 启动日志
```

LuCI：`状态 → NSS Offload`、`网络 → QoS Marking (NSS)`。

想退回纯主机协议栈（就是普通 OpenWrt）：

```sh
uci set nss.general.enabled='0'; uci commit nss; reboot
```

**Wi-Fi 默认是关闭的，且没有密码。** 用网线连上后到 `网络 → 无线` 自己开射频并设密钥。

### 默认 LAN 地址是 `192.168.35.1`

出厂镜像是 `192.168.1.1`，本仓库在 `files/etc/uci-defaults/99-qhora-301w` 里改成
**`192.168.35.1/24`**（DHCP 段随之变成 `192.168.35.100-249`，因为 `/etc/config/dhcp`
里 lan 的 `start=100 limit=150` 是按网段算的）。

时间点很关键：这个 uci-defaults 由 `/etc/init.d/boot`（`START=10`）执行，而 `network`
是 `START=20` —— **在网络起来之前就写进 uci 了**，所以首次开机直接就是 `192.168.35.1`，
不需要重启第二次（两个 START 值在实际设备上核对过）。

### passwall2 出厂预置：只填节点信息就能用

passwall2 版固件里带了一份完整的 `/etc/config/passwall2`
（源文件 `files-passwall2/etc/config/passwall2`，逐字段搬自一台实际在跑的参考机）。
**除了节点本身，分流 / DNS / 转发 / 选路全都配好了：**

| 项 | 预置内容 |
|---|---|
| 直连 | `geosite-cn` + Apple 系（`apple`、`apple@cn`、`apple-update`）+ `geosite-category-bank-cn` + `geosite-douyin` + `geoip-cn` |
| 代理 | `geosite-geolocation-!cn`；**没命中任何规则的流量也走代理** |
| 拦截 | `geosite-category-ads-all` → 黑洞 |
| DNS | DoH（`https://8.8.8.8/dns-query`）**走代理**去解析；直连侧 `UseIP`；`dns_redirect=1` 由 passwall2 接管 dnsmasq |
| 转发 | nftables TPROXY（`prefer_nft=1`），TCP/UDP 全端口 |
| 选路 | URLTest 组：`urltest_url=https://www.google.com/generate_204`，3 分钟一测、容差 50ms，自动用延迟最低的节点 |
| 接线 | 分流节点 `mainshunt`：Reject→黑洞、Direct→直连、Proxy→URLTest 组 |

**没预置的是节点凭据**（地址 / 端口 / 密码 / UUID / REALITY 公钥），因为固件是公开
仓库的产物，写进去等于把账号贴到网上。文件里留了两个模板节点：

- `node_vless` —— VLESS + REALITY，`type=sing-box`，协议/传输/uTLS 指纹/vision 流控都已设好，
  只需填 `address` / `uuid` / `tls_serverName` / `reality_publicKey` / `reality_shortId`
- `node_ss` —— Shadowsocks，`type=SS-Rust`，只需填 `address` / `port` / `password`

用法：`服务 → Pass Wall 2 → 节点列表`，编辑对应模板填完保存；确认 `地址` 那栏不再是空的后，
把主界面的总开关打开（相当于 `uci set passwall2.@global[0].enabled='1' && uci commit passwall2`）。
不用的那个模板留空即可 —— 地址为空的节点不会被选中。

三点必须注意：

1. **节点类型别选 `Xray`**。本固件**不编译 xray-core**（只编 sing-box，见第五节），
   类型选 `Xray` 的节点会因为没有 `/usr/bin/xray` 而启动失败。VLESS / VMess / Trojan /
   Hysteria2 都请用 `sing-box` 类型；SS 用 `SS-Rust`（走 `sslocal`）。
   如果你手上的节点是从别处导出的 `Xray` 类型，把下拉框改成 `sing-box` 再保存即可。
2. **`enabled` 故意留 `0`**。节点还空着的时候，passwall2 会把 dnsmasq 的解析劫持到一条
   走不通的代理链上，症状是"国内正常、国外网站全打不开"，很像断网。填好节点再打开开关，
   不会遇到这个现象。
3. 走**订阅**的话：在 `服务 → Pass Wall 2 → 订阅` 里加一条、更新出节点后，有两种接法 ——
   ① 把节点的「分组」设成和 URLTest 组一致再手动勾进成员列表；
   ② 或者把 URLTest 节点的「节点添加方式」从 `manual` 改成 `batch`，用「选择分组」动态纳入
   （订阅更新后自动跟上，不用每次改成员列表）。

### HomeProxy 出厂预置（仅 HomeProxy 版固件）

HomeProxy 版固件带了一份 `/etc/config/homeproxy`（源文件 `files-homeproxy/etc/config/homeproxy`），
把上面那套 passwall2 三分流**等价搬到了 HomeProxy 的 Custom routing（自定义路由）**上。
HomeProxy 吃的是 sing-box 原生配置，和 passwall2 的 `shunt_rules` 结构完全不同，对应关系是：

| passwall2 | HomeProxy custom |
|---|---|
| `nodes` 里 `_urltest` 组 | `routing_node 'main'`（`node=urltest`）→ 生成 `cfg-main-out` |
| `shunt_rules 'Reject'` | `ruleset 'ads'` + `routing_rule 'Reject'`（**`action='reject'`**） |
| `shunt_rules 'Direct'` | `ruleset` ×7 + `routing_rule 'Direct'`（`outbound='direct-out'`） |
| `shunt_rules 'Proxy'` | `ruleset 'noncn'` + `routing_rule 'Proxy'`（`outbound='main'`） |
| shunt 节点 `default_node` | `routing.default_outbound` |
| `remote_dns_doh` + `remote_dns_detour=remote` | `dns_server 'remote_dns'`（https 8.8.8.8，`outbound='main'`） |
| 直连 DNS | `dns_server 'direct_dns'`（udp 223.5.5.5）+ `dns_rule 'cn_dns'`（国内域名走它） |

分流结果与 passwall2 版一致：**国内直连、境外走 URLTest 代理、广告域名丢弃**；DNS 也分域
（国内用 223.5.5.5 直连解析，其余走 8.8.8.8 的 DoH 经代理）。

**节点从哪来 —— 固件里只有策略，没有凭据**

| 路线 | 你要做的 | 说明 |
|---|---|---|
| **A 手动** | 填 `node_vless`（VLESS+REALITY）或 `node_ss`（Shadowsocks）模板里的地址 / 公钥 / 密码 | 预置的 URLTest 组成员就是这两个模板，填完即可用 |
| **B 订阅** | `服务 → HomeProxy → 节点 → Subscriptions` 填**你自己的**订阅链接 → `Update nodes from subscriptions` | 订阅开关已预置，唯独链接要自己填 |

订阅那组设置（`auto_update` + 更新时间、`update_via_proxy`、`filter_nodes` / `filter_keywords`
关键词过滤）已经预置在 `config homeproxy 'subscription'` 里，**唯独没有 `subscription_url`**
—— 这条链接含机场的 service id 与密钥，不能进公开仓库。自动更新失败时
`update_subscriptions.uc` 会跳过失败的那组、**保留旧节点**（`node_cache` 为空即 `return`），
不会把节点清空，所以预置里默认就把 `auto_update` 打开了。

> ⚠️ 走**订阅**路线时有个绕不开的步骤：订阅自动建出来的节点，section id 是 `MD5(节点名)`，
> 固件没法预知，所以得把它们勾进 URLTest 组（HomeProxy 没有 passwall2 那种"按分组自动
> 纳入"）。在设备上一条命令搞定：
>
> ```sh
> # 把所有订阅节点（带 grouphash 的）加进 Main 组，并删掉空的手动模板
> uci -q delete homeproxy.main.urltest_nodes
> for n in $(uci show homeproxy | sed -n "s/^homeproxy\.\([^.]*\)=node$/\1/p"); do
>   [ -n "$(uci -q get homeproxy.$n.grouphash)" ] && uci add_list homeproxy.main.urltest_nodes="$n"
> done
> # 注意 uci delete 一次只能删一个 section，别写成一行两个
> uci -q delete homeproxy.node_vless
> uci -q delete homeproxy.node_ss
> uci commit homeproxy && /etc/init.d/homeproxy restart
> ```
>
> 走**手动**路线则不用动成员列表 —— 预置的 `urltest_nodes` 已经指着那两个模板。

**启用方式**（比 passwall2 多一步）：自定义路由模式下 HomeProxy 的"开关"不是主节点下拉，
而是 `routing.default_outbound` —— `/etc/init.d/homeproxy` 取到 `nil` 时直接 `return 1`
不启动、不劫持 DNS，所以预置里它是 `nil`。填完节点后二选一：

- 界面：`服务 → HomeProxy → 路由设置` → **Default outbound 选 `Main`** → 保存
- 命令：`uci set homeproxy.routing.default_outbound='main' && uci commit homeproxy && /etc/init.d/homeproxy restart`

三个实测踩过的坑：

1. 列表型选项必须写 `list`，不能写 `option x 'a' 'b'`（uci 解析器会报 `too many arguments`）。
2. `routing_rule` 段的**先后顺序就是匹配优先级**，Reject 必须排在最前。
3. `urltest_interval` 要写裸秒数（生成器做的是 `值 + 's'`），写 `3m` 会得到 `3ms`。

> HomeProxy 版固件里的 sing-box 是 **ImmortalWrt 源的 1.12.25**（见第五节）。
> 这个版本是必须的：HomeProxy 生成的 inbound 用了 sing-box 1.13 已删除的字段，
> 官方 packages 源上的 1.14.x 会让它 `check` 直接失败、服务起不来。

### 已启用的附加服务

| 服务 | 状态 | 怎么用 |
|---|---|---|
| **ddns-go** | 开机自启 | Web 界面 `http://<路由器IP>:9876`，在里面添加 DDNS 记录。数据在 `/etc/ddns-go/config.yaml` |
| **msd_lite** | 开机自启 | 客户端按 `http://<路由器IP>:7088/udp/<组播地址>:<端口>` 取流。**接收组播的网卡需要在 `服务 → msd_lite` 里选**（见下） |
| **WireGuard** | 仅装好 | 没有常驻服务，到 `网络 → 接口` 新建一个 `wg` 协议接口即可，内核模块会自动加载 |
| **passwall2** | 已预置分流，未启用 | 分流规则 / DNS / 转发 / URLTest 选路都已随固件预置好，**只剩节点凭据 / 订阅链接要填**（见上一节）。填完在 `服务 → Pass Wall 2` 打开总开关即可。核心只编了 **`sing-box`**（原生支持 SS/SSR/VMess/VLESS/Trojan/Hysteria2，`_shunt` 分流也由它实现），外带 **`sslocal`**（Shadowsocks-Rust 客户端，SS-Rust 类型节点靠它启动）；**没有** xray（见第五节，所以节点类型别选 Xray）。界面里缺的组件可在「组件更新」在线拉 |
| **HomeProxy**（仅 HomeProxy 版） | 已预置 custom 三分流，未启用 | 与 passwall2 同源的三分流规则（Reject / Direct / Proxy）、URLTest 选路、分域 DNS（国内直连解析、其余 DoH 经代理）全部随固件预置，**只剩节点凭据 / 订阅链接要填**（订阅开关也已预置，见上一节）。填完把 `路由设置 → Default outbound` 选成 `Main` 即启用，详见上一节 |
| **statistics** | 开机自启 | `状态 → 统计` 里有 CPU（每核占用）、**温度**、内存、接口流量、无线的曲线图。温度采集默认是开的（uci-defaults 打开了 thermal 插件），如果想调去 `统计 → 设置` |
| **首页硬件区块** | 装好即生效 | `状态 → 总览` 页底部多出一块「CPU / 温度 / 内存」：CPU 占用率（带当前频率）、每个温度传感器（`cpu-thermal` / `nss-*-thermal` / `wifi-thermal` …）、内存用量。是本仓库自己写的 include（`files/www/luci-static/resources/view/status/include/95_qhora_hw.js`），**不依赖 collectd**，开机就有数 —— 和上面 collectd 那套曲线图是两回事（一个看当前值，一个看历史） |
| **autocore** | 装好即生效 | 两个命令行脚本：`tempinfo`（输出 `CPU: 52.3°C, WiFi: 61.0°C`）和 `cpuinfo`（CPU 型号）。就是 ImmortalWrt 首页温度那一行背后用的东西，本仓库把它同源抄了进来（见第六节 7）。首页显示仍由上面那块自写区块负责，不依赖它 |

LuCI 界面默认就是简体中文（`CONFIG_LUCI_LANG_zh_Hans=y`，见第六节）。
注意「状态 → NSS Offload」那一页是英文 —— 它定义在 NSS 分支主树的
`package/nss/nss-tools` 里，是纯 JS 页面（`luci-nss-{status,qos,connections}.js`），
**不走 luci.mk、没有 po/ 翻译文件**，所以语言开关对它无效；上游没有翻译，只能保持英文。

想验证服务真的起来了：

```sh
/etc/init.d/ddns-go status
/etc/init.d/msd_lite status
ls /etc/rc.d/ | grep -E 'ddns-go|msd_lite'   # 有 S99 开头的链接说明开机自启已生效
wg show                                      # 建好 wg 接口后可用
/etc/init.d/passwall2 status                 # 配好节点后才有意义
sing-box version                             # 核心二进制在固件里（本轮起不再编 xray）
sslocal --version                            # SS-Rust 客户端在不在（passwall2 的 SS-Rust 节点要用它）
/etc/init.d/luci_statistics status           # collectd 在跑就有图表
cat /sys/class/thermal/thermal_zone*/type    # 固件里有哪些温度传感器（首页区块读的就是这个）
```

**关于 msd_lite 的组播网卡（`network` 项）**：出厂留空。它填的是"从哪张网卡收组播"，
取决于你的 IPTV 拓扑 —— 组播源在 ISP 侧（WAN 进来）还是 LAN 侧（另一台设备发出）。
填错的表现是客户端连得上 7088 端口但拉不到流。填了之后 init 脚本会注册接口触发器，
对应接口 up/down 时自动重启服务。

---

## 五、改配置

| 想改什么 | 改哪 |
|---|---|
| 多加一个软件包 | 在 `configs/common.config` 末尾加 `CONFIG_PACKAGE_xxx=y` |
| 加一个**官方 feed 没有**的包 | 在 `packages/<分类>/<包>/` 放一份自带配方，`extra-packages.sh` 会自动落位；再到 `common.config` 加符号（见下） |
| 只加一个 luci 前端页面 | 在 `scripts/extra-packages.sh` 的 `LUCI_PATHS` 里加路径，再到 `common.config` 加符号 |
| 开关 passwall2 的某个组件 | 改 `common.config` 里 `CONFIG_PACKAGE_luci-app-passwall2_*` 那几行（`INCLUDE_Shadowsocks_Rust_Client` 现在是 `y`，把它改回 `n` 就不再编 Rust） |
| 换 passwall 核心（比如要回 xray） | 把 `..._Basic_Core_SingBox=y` 换成 `..._Basic_Core_Xray=y` 或 `..._Basic_Core_All=y`，再到工作流 `WANT` 清单里补回 `xray-core` |
| 改首页硬件区块显示什么 | `files/www/luci-static/resources/view/status/include/95_qhora_hw.js`；新读的路径要同步加到 `files/usr/share/rpcd/acl.d/qhora-overview.json`（否则 rpcd 会拒读） |
| 换 passwall 的仓库 / 分支 | 改 `extra-packages.sh` 顶部的 `PW_APP_REPO` / `PW_PKGS_REPO` / `PW_REF` 默认值（也可以用同名环境变量在 CI 里覆盖） |
| 调 statistics 采集哪些数据 | `统计 → 设置` 页面，或直接改 `/etc/config/luci_statistics`（温度在 `collectd_thermal` 段） |
| 钉死 ddns-go / msd_lite 的版本 | `Run workflow` 时填 `ddns_go_version` / `msd_lite_sha`，或改 `packages/net/*/Makefile` 里的兜底值 |
| 开关某个内核选项 | `common.config` 加 `CONFIG_KERNEL_xxx=y` |
| 换编译分支 | 工作流 `Run workflow` 时填 `upstream_ref`，或改 YAML 里 `UPSTREAM_REF` 的默认值 |
| 用自己 fork 的源码 | 改 YAML `env.UPSTREAM_REPOSITORY` |
| 系统默认配置（主机名、**LAN 网段**、无线、服务开关） | 往 `files/` 里按路径放文件，会原样叠加进镜像；首次启动脚本在 `files/etc/uci-defaults/`。LAN 网段在 `files/etc/uci-defaults/99-qhora-301w` 里（现在是 `192.168.35.1/24`） |
| 改 passwall2 的出厂预置（分流规则 / DNS / 节点模板） | `files-passwall2/etc/config/passwall2`（**改完记得把 `address` 之类留空**，别把凭据提交上去）；这个目录只叠进 passwall2 版固件 |
| 改 HomeProxy 的出厂预置（custom 三分流 / DNS / 节点模板 / 订阅开关） | `files-homeproxy/etc/config/homeproxy`（同样**别把凭据提交上去**）；只叠进 HomeProxy 版固件。注意它 `routing.default_outbound` 默认是 `nil`，即预置但不启用 |
| 想确认预置里没夹带凭据 | 每次构建都会自动跑 `scripts/check-no-credentials.sh` —— 扫 `files*/etc/config/`，命中节点地址 / 密码 / UUID / REALITY 公钥 / 订阅链接就中断构建。也可以手动跑：`BUILDER_DIR=$PWD bash scripts/check-no-credentials.sh` |
| 同时编多个机型 | 在 `configs/qhora_301w.config` 再加 `CONFIG_TARGET_DEVICE_qualcommax_ipq807x_DEVICE_xxx=y`，注意 RTL 相关的高危项见下 |

自带配方不用登记：`extra-packages.sh` 是 `find packages -name Makefile` 扫出来的，
放进 `packages/net/<任意名字>/` 就会被落位到 `feeds/packages/net/<同名>/` ——
但**二级目录名要跟包的性质对上**（`net/`、`utils/`……），因为配方里的
`include ../../…` 依赖这个层级。

改完 `.config` 的选项要**推送到仓库再跑**，否则不会生效。

### 关于 extra-packages.sh

`extra-packages.sh` 负责把所有"官方 feed 里没有、或者官方那份不该用"的包塞进
feed 目录树。为什么不干脆往 `feeds.conf` 里加第三方 feed（那样最省事）？因为加整个
feed 会把成百上千个同名包一起带进来 —— ImmortalWrt 的 packages/luci 就是官方 feed
的分支，`luci-app-firewall`、`aria2`…… 都在里面 —— 两份同名包互相打架，而这个
NSS 构建对 luci/packages 的版本组合相当敏感。（唯一的例外是下面第③类，理由写在那里。）

脚本把包放进对应的 feed 目录树，来源分**三类**：

- **① 自带配方** —— `packages/<分类>/<包>/`，用 `find` 扫（新增目录自动生效）
- **② ImmortalWrt 纯前端** —— 脚本里 `LUCI_PATHS` 数组列出的路径
- **③ passwall2** —— 从 Openwrt-Passwall 的两个仓库浅克隆

| 放进哪 | 来自哪（第几类） | 为什么 |
|---|---|---|
| `feeds/packages/net/ddns-go` | 本仓库 `packages/net/ddns-go/`（①） | 带二进制，要跟上游版本 |
| `feeds/packages/net/msd_lite` | 本仓库 `packages/net/msd_lite/`（①） | 同上 |
| `feeds/luci/applications/luci-app-ddns-go` | ImmortalWrt 稀疏检出（②） | 纯前端页面，没有独立的"上游源码仓库" |
| `feeds/luci/applications/luci-app-msd_lite` | ImmortalWrt 稀疏检出（②） | 同上 |
| `feeds/luci/applications/luci-app-passwall2` | Openwrt-Passwall 浅克隆（③） | passwall2 的界面 + 运行脚本 |
| `feeds/packages/net/<组件>` × 17 | Openwrt-Passwall 浅克隆（③） | 组件的配方与上游版本同步维护，直接用上游 main |

**为什么前者不抄 ImmortalWrt 的配方。** ImmortalWrt 那份把版本**写死**了
（`PKG_VERSION:=6.17.6` 配一个对应的 `PKG_HASH`），上游发了新版得等它 bump 才跟得上
—— 写这套东西的时候上游已经到 `6.17.7` 了。所以这两个包改成**直接引用上游源码仓库**
（`jeessy2/ddns-go`、`rozhuk-im/msd_lite`），版本号和 hash 由构建时的
`resolve-versions.sh` 解析后注入，配方里写的只是**兜底值**（见下）。

⚠️ **但这两个包的取源方式不一样，别照抄：**

| | ddns-go | msd_lite |
|---|---|---|
| 取源方式 | codeload 压缩包（`PKG_SOURCE_URL` 指向 `tar.gz/v<版本>`） | **git 源**（`PKG_SOURCE_PROTO:=git`） |
| 为什么 | 自包含，压缩包就够 | **它依赖 git 子模块 `src/liblcb`，压缩包里没有**（见下） |
| `resolve-versions.sh` 注入 | `PKG_VERSION` / `PKG_HASH` / `GO_PKG` | `PKG_SOURCE_DATE` / `PKG_SOURCE_VERSION` |

`msd_lite` 的 `CMakeLists.txt` 第 245 行是**无条件**的
`include(src/liblcb/CMakeLists.txt)`，而 `liblcb` 是 `.gitmodules` 里的子模块
（`https://github.com/rozhuk-im/liblcb.git`）。GitHub 的 `/archive/<sha>.tar.gz`
**不打包子模块内容** —— 解出来 `src/liblcb/` 是空目录，cmake 直接报
`include could not find requested file`。

用 git 源时 `include/download.mk` 会自动处理这条路：GitHub URL 先走
`github_archive`（`dl_github_archive.py`），该脚本**拒绝**带子模块的仓库
（`Fetching submodules is not yet supported`），于是回落到 `rawgit` —— 它会
`git clone` 后执行 `git submodule update --init --recursive`，子模块这才进得来。
配方里 `PKG_MIRROR_HASH:=skip` 是**故意**的，目的是让 `github_archive` 在初始化校验
hash 时就失败，从而**确定性**地走 `rawgit`，不依赖"子模块检测是否命中"。
（这套机制是 run 8 挂掉之后查出来的 —— 当时图省事把 msd_lite 也换成了压缩包。）

**为什么两个 luci-app 还从 ImmortalWrt 拿。** 它们只是页面（JS / ucode / 翻译），
没有可指的源码仓库，抄一份进本仓库只会让上游的界面更新再也跟不进来。它们通过
`LUCI_DEPENDS:=+ddns-go` / `+msd_lite` 依赖上面那两个包 —— 包名没变，照样接得上。

**为什么必须放进 feed 目录而不是 `package/`**：这些 Makefile 用的是相对路径 ——
luci 应用是 `include ../../luci.mk`，`ddns-go` 是
`include ../../lang/golang/golang-package.mk`。只有放在 `<feed根>/<二级目录>/<包>/`
这个位置才能解析得到，放进 `package/` 会直接报找不到 luci.mk。

**调用顺序不能变**：`feeds update -a` → `extra-packages.sh` → `feeds update -i -a` → `feeds install -a`。
`-i` 表示只重建索引、不执行 `git pull`（否则会碰到刚拷进去的文件），而 `install`
读的是 `feeds/<name>.index`，不重建索引就看不到新包。`prepare-build.sh` 里已经按这个
顺序串好了，并在 install 之后检查 `package/feeds/...` 是否真的存在 —— 索引没生效的话
会立刻失败，而不是默默编出一个缺功能的固件。

自带的配方文件（`files/ddns-go.init`、`files/msd_lite.config` 等）仍取自 ImmortalWrt
（同为 GPL-2.0）。它们只负责 UCI 解析和 procd 拉起，**与包本身的版本无关**；所以
`resolve-versions.sh` 只管版本/hash，不会去动 `files/`。代价是：ImmortalWrt 若改了
这些 init 脚本，需要手工同步过来。

### passwall2（项目 + 依赖组件）

⚠️ **仓库搬家了**：passwall 项目已经不在个人账号 `xiaorouji` 下（那里现在返回 404），
迁到了 **`Openwrt-Passwall`** 组织。三份仓库各司其职：

| 仓库 | 内容 | 本仓库用不用 |
|---|---|---|
| `openwrt-passwall2` | 只有 `luci-app-passwall2`（界面 + 运行脚本） | **用** |
| `openwrt-passwall-packages` | 17 个依赖组件的配方 | **用** |
| `openwrt-passwall` | 只有 v1 的 `luci-app-passwall` | 不用 |

**为什么不自己写配方（像 ddns-go 那样直接引上游源码）。** 这 17 个组件的配方和上游
版本是**同步维护**的：bump 版本时 `PKG_VERSION` / `PKG_HASH` / 编译标签是一起改的，
拆开抄反而容易对不上。而且它们没有"滞后"问题（不像 ImmortalWrt 抄 ddns-go 会慢半拍），
所以每次构建取一次上游 `main` 就是当时最新的，**不需要** `resolve-versions.sh` 注入。

**组件清单不写死。** `extra-packages.sh` 遍历 `openwrt-passwall-packages` 顶层所有含
`Makefile` 的目录，上游加新组件会自动被带上，不用改脚本（这条是实测过的）。

⚠️ **有 4 个组件与官方 feed 同名**：`microsocks` / `sing-box` / `v2ray-geodata` /
`xray-core`。落位时是本仓库这份**覆盖**官方那份（`place()` 先 `rm -rf` 再 `cp -a`）。
passwall 上游 CI 是让 passwall feed 排在 `feeds.conf` 最前面来取胜，效果一样。
其余 13 个官方 feed 里没有（实测 `openwrt/packages` 的 `net/`、`lang/` 下均为 404）。

**核心只留 `sing-box`，不编 xray。** 上游对 aarch64 的默认值是 `Basic_Core_All`
（xray + sing-box 都编），这份配置改成 `..._Basic_Core_SingBox=y`：sing-box 原生支持
SS / SSR / VMess / VLESS / Trojan / Hysteria2 / WireGuard，`_shunt` 分流也是它自己用
`route.rules` 实现的，日常用不到 xray，少编一个省下约 20MB 镜像和几分钟构建时间。
（组件配方仍会被落位到 `feeds/packages/net/xray-core`，只是不选中、不编译 —— 想切回来
就改这一个符号，再到工作流 `WANT` 清单里补回 `xray-core`。）

**这个选择对用的人有一个直接后果**：passwall2 节点列表里的「类型」选 `Xray` 时，
它会去执行 `/usr/bin/xray` 来起每个节点；固件里没有这个二进制，节点就起不来。
所以本仓库出厂预置的节点模板用的是 `type=sing-box`（VLESS/REALITY 直接由 sing-box
原生收发），SS 用 `type=SS-Rust`（走 `sslocal`）。从别处导入的 `Xray` 类型节点，
把类型改成 `sing-box` 即可。详见第四节「passwall2 出厂预置」。

⚠️ **`sslocal`（Shadowsocks-Rust 客户端）必须编，不能省。** passwall2 里节点类型为
`SS-Rust` 的节点是直接 exec `/usr/bin/sslocal` 的（`app.sh` 的 `ss-rust` 分支 →
`ln_run "$(first_type sslocal)" "sslocal" ${QUEUE_RUN} …`），缺了它运行日志会报
`sslocal not found, unable to start...`，那种节点的透明代理 / 分流就起不来。
最容易踩的场景是**从别的固件恢复了 passwall2 配置** —— 那台机器上有 sslocal，节点
`type` 就存成了 `SS-Rust`，换到本固件后立刻变成"缺依赖"。

它属于 `shadowsocks-rust`，配方写着 `PKG_BUILD_DEPENDS:=rust/host`，要拉 Rust 工具链
（prebuilt 下载 + cargo 编译，构建大概多 15~25 分钟，固件 +6~8MB）。服务端
（`INCLUDE_Shadowsocks_Rust_Server`）和 `shadow-tls` 用不上，继续关着；真要用就在 LuCI
的「组件更新」里在线拉预编译二进制（passwall2 自带这个入口）。

> **一个容易踩的副作用：**`sslocal` 一旦存在，从订阅导入的 **SS 节点默认类型会变成
> `SS-Rust`**（`subscribe.lua` 里的候选顺序是 shadowsocks-rust → sing-box → xray）。
> 这是上游默认行为。想让 SS 节点走 sing-box（不额外起 sslocal 进程），到「节点订阅」
> 页把 SS 类型显式选成 sing-box。

**透明代理走 nftables 那支。** 这份配置用的是 `firewall4`，所以开
`..._Nftables_Transparent_Proxy=y`、关 `..._Iptables_Transparent_Proxy`。前者会
`select` 一串依赖：`chinadns-ng`、`dnsmasq-full`、`dnsmasq_full_nftset`、`nftables`、
`kmod-nft-socket`、`kmod-nft-tproxy`、`kmod-nft-nat`。

> **选中 `dnsmasq-full` 会把镜像里默认的 `dnsmasq` 挤掉 —— 但不需要手写
> `CONFIG_PACKAGE_dnsmasq=n`。** `scripts/package-metadata.pl` 的
> `add_implicit_provides_conflicts()` 会给默认变体补一条冲突，再由
> `mconf_conflicts()` 生成 `depends on m || (PACKAGE_dnsmasq-full != y)`，
> kconfig 自己就会取消选择。

**本轮取到的版本会发成公开注解**（作业日志要登录才能看，注解不用）：

```
::notice:: passwall2 项目版本：luci-app-passwall2=26.10.1-2（取自 …openwrt-passwall2.git@main）
::notice:: passwall 组件版本（引自上游 main）：chinadns-ng=2025.08.09  …  sing-box=1.14.3
```

这条注解同时是"上游最近一次更新有没有被这轮构建吃到"的凭证 —— 和 ddns-go 那条一样，
都是**不看作业日志也能核对**的公开信息。

取版本字段时按 `PKG_VERSION` → `PKG_SOURCE_DATE` → 第一个 `*_VER`（有的组件用
`GEOIP_VER` 之类，配方里根本没有 `PKG_VERSION`）依次回退，都取不到就显示 `-` ——
如实反映"这份配方没有可直接读的版本号"，不编造。

### HomeProxy（并行的第二条构建线）

除了上面那条 passwall2 主线，仓库里还有一条**并行的构建线**：只换代理栈，其余一切
不变（NSS 卸载栈、ddns-go、msd_lite、WireGuard、statistics、autocore、`files/`
覆盖、target / device 全都一样）。

```
.github/workflows/build-qhora-301w-homeproxy.yml
configs/homeproxy.config
```

**它不是 fork 出来的第二套逻辑**，而是给同一份脚本加了个开关：环境变量
`PROXY_STACK`（默认 `passwall2`）。工作流里设成 `homeproxy`，`prepare-build.sh` 与
`extra-packages.sh` 就切到另一支 —— 主线那份的行为一字未改，两边的踩坑经验
（日志缓冲、注解配额、符号校验、ccache key）也全都共用。

| | 主线 | HomeProxy 版 |
|---|---|---|
| 代理前端 | `luci-app-passwall2`（来自 `Openwrt-Passwall/openwrt-passwall2`） | `luci-app-homeproxy`（来自 `immortalwrt/luci`） |
| 依赖组件 | 17 个（chinadns-ng / geoview / tcping / v2ray-geodata / ss-rust …） | **没有**：上游 `LUCI_DEPENDS` 只有 `+sing-box +firewall4 +kmod-nft-tproxy +ucode-mod-digest` |
| sing-box | passwall-packages 那份（1.14.x） | **`immortalwrt/packages` 那份（1.12.25）** |
| DNS / 分流 | chinadns-ng + dnsmasq-full + nftset | HomeProxy 自带的 sing-box DNS（5330-5333）+ nftables 的 china_ip4 内核快路径 |
| 构建时间 | 长（要拉 Rust 工具链编 `sslocal`） | 短（配方里没有 Rust 依赖） |

HomeProxy 是**单包自包含**的：主程序（`/etc/init.d/homeproxy`、`/etc/homeproxy/scripts/*`）、
rpcd 后端、LuCI 视图全在 `applications/luci-app-homeproxy` 这一个目录里，所以引入它
只需从 `immortalwrt/luci` 稀疏检出一个目录 —— 而那个 feed 本仓库早就在拉
（为了 `luci-app-ddns-go` / `luci-app-msd_lite`）。

#### 为什么连 sing-box 版本一起换（这条最容易踩）

HomeProxy 生成的 client 配置里**仍写着 sing-box 1.13 已删除的 inbound 字段**
（`sniff` / `sniff_override_destination` / `set_system_proxy`）。在 1.14 上
`sing-box check` 直接报

```
FATAL: legacy inbound fields are deprecated in 1.11.0 and removed in 1.13.0
```

而 `/etc/init.d/homeproxy` 会据此 `return 1` —— **服务永远起不来**。这不是推测：
在参考机（192.168.2.1）上实测过，包齐全、`main_node` 也配了，就是起不来；
把那几个字段摘掉后同一份配置 `check` 零输出通过，说明问题**只**在这一处字段代差。

三处来源的实测版本：

| 来源 | sing-box |
|---|---|
| `openwrt/packages` master `net/sing-box` | 1.14.0 |
| `openwrt-passwall-packages`（主线用的） | 1.14.0 |
| `immortalwrt/packages` master `net/sing-box` | **1.12.25** |

所以 HomeProxy 版在 `extra-packages.sh` 里从 `immortalwrt/packages` 取 `net/sing-box`
落位，**覆盖**官方那份 —— 这就是 ImmortalWrt 自己配 HomeProxy 用的组合。
`prepare-build.sh` 里另有一处对配方版本的显式检查：上游哪天把这份配方升到 1.13+，
构建会在「准备构建环境」阶段发一条 warning 注解（那种情况下 homeproxy 会在启动时
被它自己生成的配置卡死，属于运行期才暴露的问题，越早提示越好）。

#### 覆盖层为什么必须写 `CONFIG_X=n`

`configs/homeproxy.config` 是拼在 `common.config` **之后**的覆盖层。它"关掉" passwall2
的写法**不能**用惯常的 `# CONFIG_X is not set`：

```bash
# prepare-build.sh 按"配置里最后一个赋值"取值，且只断言不以 =n 结尾的行
cat 所有 CONFIGS | grep -E '^CONFIG_[A-Za-z0-9_-]+=' \
  | awk -F= '{ last[$1] = $0 } END { for (s in last) print last[s] }' \
  | grep -vE '=n$'
```

`# CONFIG_X is not set` 以 `#` 开头，会被那条 `grep '^CONFIG_…='` 过滤掉 —— 于是
`common.config` 里原本的 `=y` 仍然是"最后一个值"，照样进断言清单；而它在最终
`.config` 里已经被 defconfig 关掉了，**符号校验必然失败**。写成 `CONFIG_X=n` 才
既真正关掉、又不进断言清单。

#### 触发方式

```
Actions -> Build QHora-301W (NSS EDMA, HomeProxy) -> Run workflow
```

推送 `configs/homeproxy.config` 或那份工作流文件本身也会触发。**故意不监听
`scripts/` `files/` `packages/`** —— 那几个目录一改，主线工作流本来就会跑，
两条全量编译一起排队要等好几个小时；要让它跟着重编，手动跑一次即可。

⚠️ 两条线的 `concurrency` 用的是**各自独立的 group**，别改成共用：实测往主线那个
group 里挤，新进来的 run 会被 GitHub 直接判 `cancelled`（创建 1 秒后就没了，
一个 step 都跑不到）。

⚠️ HomeProxy 与 passwall2 **共用同一个 `/usr/bin/sing-box` 和同一套 nftables 透明
代理**，两者只能同时启用一个 —— 切换时先停另一个。本固件里本来就只有 HomeProxy。

### 版本是"跟上游最新"还是"钉死"

这是**两层**，别混在一起：

| 层 | 谁决定 | 什么时候变 |
|---|---|---|
| 配方本身（Makefile、init 脚本） | feed 的每次重新拉取 | 每次构建都是最新的（pin 的是上游 ref，不是某个 feed 快照） |
| **包编出来的版本** | 配方里的 `PKG_VERSION` / `PKG_SOURCE_VERSION` | 由 `resolve-versions.sh` 在构建时改写 → 每次构建都是上游最新 |

`scripts/resolve-versions.sh` 在 `extra-packages.sh` 之后、`feeds update -i` 之前跑，
做三件事：

1. `ddns-go`：查 `releases/latest` 拿 tag（用 `releases/latest` 而不是 `/tags`，
   它会自动跳过预发布版和草稿），拉 codeload 压缩包算 sha256，再把
   `PKG_VERSION` / `PKG_HASH` 写回配方。顺带读压缩包里 `go.mod` 的 `module` 行
   注入 `GO_PKG` —— 上游哪天升到 v7（`.../ddns-go/v7`），这一步自动跟上，不用手改。
2. `msd_lite`：上游**一个 tag 都没有**，只能查 `commits/master` 拿 sha 和日期，
   注入 `PKG_SOURCE_VERSION`（sha）+ `PKG_SOURCE_DATE`。它是 **git 源**，所以
   `PKG_VERSION` / `PKG_SOURCE_SUBDIR` / `PKG_BUILD_DIR` 全部由 `download.mk`
   从这两个值自动推导，配方里**不写**（详见上一节）。版本号形如
   `2026.07.20~fa68e131` —— apk 要求版本号以数字开头，裸 sha 会被判非法。
3. `ddns-go` 的压缩包会下载进 `$OPENWRT_DIR/dl/`，让后面的 `make download` 直接复用
   —— 也就顺带证明了"我们算出来的 hash"就是"构建时会校验的那个 hash"。
   `msd_lite` 是 git 源，不下载、本地不算 hash（由 OpenWrt 自己 clone + 打包）。

> **关于 msd_lite 的日期可能和 ImmortalWrt 差一天。** 脚本取的是 commit 的
> **UTC** 日期；ImmortalWrt 那份配方里的 `PKG_SOURCE_DATE` 是**手工维护**的，且按
> 维护者本地时区（UTC+8）算。同一个 commit `fa68e131`（实际 `2026-07-20T20:24Z`）
> 我们得出 `2026.07.20~fa68e131`，ImmortalWrt 编出来的是 `2026.07.21~fa68e131`。
> 这**不是 bug**：版本号里真正标识修订的是那段短 sha，日期只是为了让版本号以数字开头
> 并且大致单调。整镜像 sysupgrade 不比较包版本，所以"看起来变旧一个 patch"实际无影响。
>
> `ddns-go` 没有这个问题：它的版本号直接来自上游 tag（`6.17.7`），两边必然一致。

几个刻意的设计：

- **失败不中断构建。** API 抖动、限流、网络抽风都不该让一轮两小时的编译白跑。
  解析失败就发一条 `::warning::` 注解、沿用配方里的兜底值照常编。
- **注入按包原子。** 一个包的版本、ref/`GO_PKG`、hash 是一组一起替换的，绝不会出现
  "新版本配旧 hash"这种半截状态 —— 那会让下载阶段的 hash 校验直接失败。
- **压缩包顶层目录名会校验**（只对 ddns-go）。`include/unpack.mk` 解到 `BUILD_DIR` 下、
  靠目录名对上 `PKG_BUILD_DIR`，命名规则一变就会在"解压完找不到源码"这种晦涩的地方炸；
  所以先 `tar -tzf` 确认顶层目录，不符就回落兜底值。
- **sha 形状会校验。** `msd_lite` 的 sha 必须是 40 位小写十六进制，否则 `git checkout`
  会在很后面才失败，不如在这里拦住回落兜底值。
- **两个包互相独立。** 一个解析失败不影响另一个（bash 在 `if` 条件位置会关掉 `-e`，
  函数内部靠显式 `return 1` 退出）。

**这轮到底编了哪个版本，看注解。** 作业日志要登录才能看，注解不用，所以脚本把结果
发成公开注解：

```
::notice:: 本轮固件里的上游包版本：ddns-go=6.17.7  msd_lite=2026.07.20~fa68e131
           （ddns-go 已跟随上游最新版；msd_lite 已跟随上游最新版）
```

要钉死某次构建的版本（比如复现一个固件），在 `Run workflow` 里填
`ddns_go_version` / `msd_lite_sha`；本地跑时同名环境变量即可，填了就不查 API。

### 怎么确认某个包真的编进去了

「配置里写了 `CONFIG_PACKAGE_x=y`」和「x 真的在固件里」是两件事，分三层验证：

| 层次 | 由谁保证 | 失败时 |
|---|---|---|
| Kconfig 符号没被静默丢弃 | `prepare-build.sh` 断言配置里每个 `=y` 都原样出现在 `.config` | 构建在第 6 步失败，注解列出被丢的符号名 |
| 包**被编译**（生成了包文件） | 工作流「校验功能包是否真的编进固件」 | 构建失败，注解点名是哪个包 |
| 包**进了 rootfs** | 同上：在 rootfs `.manifest` 里查包名 | 降级为 warning（`.manifest` 格式变化时不会误杀构建） |

前两层是硬性失败，第三层是告警 —— 因为 `.manifest` 的行格式（`名字 - 版本`）
属于上游实现细节，不该拿它把整个构建卡死。

⚠️ **包文件是按后端命名的，别写死扩展名。** 这个分支 `CONFIG_USE_APK`
默认为 `y`（见 `include/package-pack.mk` 第 305-309 行）：

```
apk  后端：<name>-<version>.apk          ← 本分支走这条
opkg 后端：<name>_<version>_<arch>.ipk
```

**想连版本一起核对**：`.manifest` 里每行是 `包名 - 版本`，版本号就是
`resolve-versions.sh` 注入的那个（`PKG_VERSION`）；运行页的注解也会把它们列出来，
两者对得上就说明"跟上游最新"确实生效了。

**自己核对的最快办法**：下载运行页上的 artifact，解压后打开
`openwrt-qualcommax-ipq807x*.manifest`（文件名由 `IMG_PREFIX` + profile 拼成，
**不一定含设备名**），那是最终 rootfs 的完整包清单，直接搜包名即可。
运行页的 **Summary** 区块也有产物清单（`ls -lh` 输出）。

> 注意：GitHub 对 artifact **内容**也要登录才能下载（公开仓库一样），
> 作业级日志同理。所以工作流才把这些清单用 `::notice::` 发成注解 ——
> 注解是公开可读的，无人值守的脚本也能核对。


### 两个高危坑（改配置前务必看）

1. **内存档位是编译期写死的，而且整镜像生效。**
   QHora-301W 是 1GB RAM，所以是 `CONFIG_ATH11K_MEM_PROFILE_1G=y` +
   `CONFIG_NSS_MEM_PROFILE_HIGH=y`。如果和别人共用同一个镜像，档位必须一致；
   档位选错**构建过程不会报任何错**，但上机后无线/NSS 行为会不对。

2. **NSS feed 不能少。**
   `nss-edma-rework` 只提供内核侧补丁，NSS 驱动 / ECM / qdisc / 固件在
   [`nss-packages`](https://github.com/JuliusBairaktaris/nss-packages) 的 `edma-nss` 分支。
   少了它 `ATH11K_NSS_SUPPORT` 依赖不满足，`defconfig` 直接失败。

另外：`nss-edma-rework` 分支和 `edma-nss` feed **会被上游定期 rebase**。
所以本地增量 `git pull` 是无效的，正确姿势是：

```sh
git fetch origin && git reset --hard origin/nss-edma-rework
rm -rf feeds/nss package/feeds/nss
./scripts/feeds update -a
# 官方 feed 里没有 ddns-go / msd_lite，这一步会把自带配方和 luci 前端放进 feed 目录树
OPENWRT_DIR="$PWD" BUILDER_DIR=/path/to/qhora-301w-build \
  /path/to/qhora-301w-build/scripts/extra-packages.sh
# 再解析这两个包的上游最新版本，写回配方（不跑也行，那就会用配方里的兜底值）
OPENWRT_DIR="$PWD" /path/to/qhora-301w-build/scripts/resolve-versions.sh
./scripts/feeds update -i -a && ./scripts/feeds install -a
make defconfig
```

`resolve-versions.sh` 最好带上 `GH_TOKEN`（本地 `export GH_TOKEN=$(gh auth token)`
之类）：不带也能跑，但 GitHub 未认证 API 限额只有 60 次/小时，容易被别处撞掉，
那时脚本会回落成兜底值 —— 不报错，只是编的不是最新版。

工作流每次都是全新 checkout，所以不受影响；上面这一串的 CI 版本就是
`prepare-build.sh` 内部的顺序（`extra-packages.sh` → `resolve-versions.sh` →
`feeds update -i -a` → `feeds install -a`）。

---

## 六、相对上游配方做的改动

三处基调改动，其余保持原样：

1. **打开了 initramfs**（`CONFIG_TARGET_ROOTFS_INITRAMFS=y`）。
   上游为了多机型共用镜像关掉了它——因为 Asus RT-AX89X 的 recovery trx 把内核
   卡在 16MiB，而 NSS initramfs 内核约 21MiB。单机型编译没有这个约束，而
   QHora-301W 的**首次安装恰恰必须靠 initramfs**（U-Boot TFTP 引导）。

2. **把设备/子目标固定到 QHora-301W**，并把上游按内存容量分组的
   `devices/ipq807x-1g` 配置合并进 `configs/qhora_301w.config`。

3. **打开了 LuCI 简体中文**（`CONFIG_LUCI_LANG_zh_Hans=y`）。
   注意只能用这个开关，不能写 `CONFIG_PACKAGE_luci-i18n-…=y` ——
   `luci.mk` 生成的 i18n 包都带 `HIDDEN:=1`，没有 prompt，
   `.config` 里的值会被 kconfig 直接忽略。原因见第八节陷阱②。

在上面三条之外，追加了五组功能包（`ddns-go` / `msd_lite` / `WireGuard` / `passwall2` / `statistics`，见第五节）：

4. **`ddns-go` / `msd_lite` 改为自带配方**（`packages/net/`），直接引用上游源码
   （`jeessy2/ddns-go`、`rozhuk-im/msd_lite`），版本/ref 由
   `scripts/resolve-versions.sh` 在构建时解析注入 —— 不再等 ImmortalWrt bump。
   两者取源方式不同：`ddns-go` 用 codeload 压缩包，`msd_lite` **必须**用 git 源
   （它依赖 git 子模块 `src/liblcb`，压缩包里没有）。只有两个 luci 前端页面仍从
   ImmortalWrt 稀疏检出。

5. **`passwall2` 连组件一起引入**（`packages/net/` × 17 + `luci/` × 1），全部来自
   `Openwrt-Passwall` 组织的浅克隆 —— **不抄配方、不改版本**，每次构建取当时的上游
   `main`。组件清单不写死（遍历上游顶层目录），上游加新组件会自动带上。带同名冲突的
   4 个组件（`xray-core` / `sing-box` / `v2ray-geodata` / `microsocks`）在落位时**覆盖**
   官方 feed 那份。编进固件的是 **`sing-box`**（核心，xray 不编 —— 上游 aarch64 默认
   是"All"，这里改成只 SingBox）和 **`sslocal`**（Shadowsocks-Rust 客户端，SS-Rust
   类型节点必须靠它启动）；`shadow-tls` / SS-Rust 服务端不编。详见第五节。

6. **`luci-app-statistics` 补上官方 LuCI 缺的 CPU/温度图表**。官方总览页只有
   负载均值 —— 10_system.js 里就没有 CPU 占用率和温度这两项，这不是缺包，
   是官方 LuCI 就这样设计。统计图表走标准方案：collectd + rrdtool1 +
   cpu/memory/interface/load/iwinfo 采集插件（由 luci-app-statistics 的依赖带出），
   另外温度插件 `collectd-mod-thermal` **不在**它的默认依赖里，必须显式写出。
   采集开关在 `/etc/config/luci_statistics`，thermal 出厂是关的，由
   `files/etc/uci-defaults/99-luci-statistics` 在开机时打开。
   全套在官方 feed 里，不需要 `extra-packages.sh` 介入。

7. **首页（状态 → 总览）加了一块「CPU / 温度 / 内存」**，是两份覆盖文件，不走任何包：
   - `files/www/luci-static/resources/view/status/include/95_qhora_hw.js` —— 渲染表格。
     放这里就能生效，因为**上游总览页的 include 列表不是写死的**：`index.js` 用
     `fs.list('/www/luci-static/resources/view/status/include')` 扫目录、按文件名排序后
     逐个 `L.require()`。所以我们只是"多放了一个文件"，没有改上游任何代码。
     数据源是只读 procfs / sysfs（`/proc/stat`、`/proc/meminfo`、
     `/sys/class/thermal/thermal_zone<N>/`、`/sys/class/hwmon/hwmon<N>/`、
     cpufreq 的 `scaling_cur_freq`），CPU 占用率用两次 `/proc/stat` 采样做差得到
     （首页本来每几秒就轮询一次，直接用上一轮样本，首次打开才多采一次）。
   - `files/usr/share/rpcd/acl.d/qhora-overview.json` —— 给 rpcd 开这些路径的读权限。
     **这步不能省**：官方 `luci-base` 那组只授了 `list`（`read.file` 是 `/`+`/*` 的
     `list`、`read.ubus.file` 只有 `list`），没授 `read`，LuCI 前端读任何文件都会被拒。
     自己定义一个新 group 是安全的 —— `/etc/config/rpcd` 出厂就给 root 授
     `list read '*'`，新 group 自动对 root 生效。
   - 为什么不学 ImmortalWrt 那套：他们首页的温度走 ubus 的 `luci.getTempInfo`，
     由 luci-base 的 ucode 插件（`/usr/share/rpcd/ucode/luci`）执行 `/sbin/tempinfo`
     得到；那个**方法**和那个**脚本**分别来自 ImmortalWrt 的 luci 分支和它的
     `autocore` 包，官方 `openwrt/luci` 两边都没有。
     ⚠️ 别跟 `rpcd-mod-luci` 搞混 —— 那个包注册的 ubus 对象是 `luci-rpc`，
     只有 `getBoardJSON` / `getDHCPLeases` 那 6 个方法，跟首页温度毫无关系。
     要照搬就得覆盖上游的 `10_system.js` **和**整个 ucode 插件（跨分支替换，
     上游一升级就漂移），而直读 sysfs 是等效的、且不改上游任何文件。
   - 那为什么还编进来一个 `autocore`：它提供 `/sbin/tempinfo` 和 `/sbin/cpuinfo`
     两个脚本（SSH 里可直接执行），与 ImmortalWrt 同源，日后若想接那套 ubus 前端
     也现成。配方抄在 `packages/emortal/autocore/`（本仓库自带那类），
     **纯脚本、零编译**；注意它的 Makefile 只对 `ipq% / mediatek% / qualcommax%`
     目标安装 `tempinfo`，我们是 qualcommax ✓。

另外，工作流本身也加了一条能力：**编译失败可远程诊断**（make 输出落盘 + 失败时把
失败包名和真实报错行发成公开注解，见第八节）。

这五组功能包（外加第七节那条首页小组件）都是**独立追加**的，删掉它们不影响 NSS 卸载栈本身。
`WireGuard` 走的是官方 feed 的原生包，`statistics` 也在官方 feed 里，都不需要额外脚本。

---

## 七、本地编译（不用 CI）

```sh
git clone -b nss-edma-rework https://github.com/JuliusBairaktaris/openwrt-nss-edma openwrt
cd openwrt

# 下面这一步会自己做完全部准备工作：追加 nss feed、落位自带配方 + 两个 luci 前端
# + passwall2 及其 17 个组件、解析 ddns-go/msd_lite 的上游最新版本、
# 跑 feeds update/install、拼 .config、跑 defconfig、校验符号、
# 叠加 files/ 以及变体覆盖层 files-<PROXY_STACK>/（默认 files-passwall2/）。
export GH_TOKEN=<你的 GitHub token>   # 可选，但建议给：避免撞未认证 API 限额
OPENWRT_DIR="$PWD" BUILDER_DIR="../qhora-301w-build" bash ../qhora-301w-build/scripts/prepare-build.sh

make -j"$(nproc)"
```

想编某个确定版本的 ddns-go / msd_lite，在 `prepare-build.sh` 前面加环境变量即可：

```sh
DDNS_GO_VERSION=6.17.7 MSD_LITE_SHA=fa68e131343fb58c67ad77b2d26f2cb7c49a2c95 \
  OPENWRT_DIR="$PWD" BUILDER_DIR="../qhora-301w-build" \
  bash ../qhora-301w-build/scripts/prepare-build.sh
```

passwall2 没有"钉版本"的开关（组件和上游 `main` 是同步维护的），但可以换源/换分支：
`PW_REF`（默认 `main`）、`PW_APP_REPO`、`PW_PKGS_REPO` 三个环境变量都能覆盖，
工作流里对应 `passwall_ref` / `passwall_app_repo` / `passwall_pkgs_repo` 三个输入
（见第五节）。

Ubuntu 24.04/26.04 上需要：
`bzip2 g++ gawk gcc git glibc-source libncurses-dev make curl`，
磁盘留 **35GB** 以上。全量编译（含 LTO）在 4 核机器上要几个小时。

（脚本里的文件叠加用的是 `cp -a` 而不是 `rsync`，所以**不需要**装 rsync。）

---

## 八、排查构建失败

工作流的 job 日志要仓库 admin 权限才能从 API 下载，所以整个流程都特意让失败
**可远程诊断**：

- `scripts/prepare-build.sh` 的输出落盘到 `$GITHUB_WORKSPACE/prepare-build.log`；
  失败时把「出错行号 + 出错命令 + 日志尾部」以 `::error::` 输出 —— 那会变成
  check-run annotation，在 Actions 页面和公开 API 上都能直接看到；
- 工作流里有一堆 `if: always()` 的「回放…日志」步骤，把日志尾部打到控制台；
- **`make` 的输出也全程落盘**（`$RUNNER_TEMP/build.log`），失败时由
  「回放编译日志」打到控制台、并由「上报编译失败原因」把
  **失败的包名**和**真实报错行**发成 `::error::` 注解。

> 为什么编译阶段也要做这一套：这一层的失败原因（比如某个包的
> `CMake Error` / `undefined reference`）**只存在于 make 的输出里**，
> 而作业日志公开侧拿不到 —— 不做这个的话，编译失败就只剩一句
> `Process completed with exit code 2.`，等于抓瞎。

典型报错：

| 注解内容 | 含义 | 怎么处理 |
|---|---|---|
| `prepare-build.sh 在第 N 行失败` + `失败命令：…` | 该命令返回非零 | 看注解随附的日志尾部 |
| `defconfig 丢弃了 N 个配置请求的符号` | Kconfig 依赖没满足，选项被静默丢弃 | 后面几条注解会逐个列出符号名 |
| `defconfig 丢弃符号：CONFIG_PACKAGE_xxx=y` | 具体是哪个选项被丢了 | 日志里有该符号的 kconfig 定义，看它的 `bool`/`default`/`depends on` |
| `package/feeds/... 不存在` | 放进 feed 的包没被 `feeds install` 接管 | 检查 `feeds update -i` 那一步 |
| `ddns-go / msd_lite 解析上游最新版本失败` **（warning）** | 查 GitHub API 或算 hash 失败 | **不影响构建**，那两个包会用配方里的兜底值；想确认编的是哪个版本，看同批的 notice |
| `本轮固件里的上游包版本：…` **（notice）** | 这轮实际编进去的版本 | 核对是否是预期版本；不是就用 `ddns_go_version` / `msd_lite_sha` 钉死 |
| `passwall2 项目版本：luci-app-passwall2=…` **（notice）** | 这轮取到的 passwall2 界面版本 | 和上游 release 对照；不对就看 `passwall_ref` / `passwall_app_repo` |
| `passwall 组件版本（引自上游 …）` **（notice）** | 17 个组件各自的 `PKG_VERSION` | 想确认某个组件（如 `sing-box`）这轮编的是哪版，看这条 |
| `克隆 … 失败（分支 …）` **（error）** | passwall 仓库浅克隆失败 | 检查 `passwall_ref` 分支是否存在、`passwall_*_repo` 地址、网络 |
| `上游没有 …/Makefile（结构可能变了）` **（error）** | 上游仓库顶层结构变了 | 改 `extra-packages.sh` 里对应 `place()` 的 `src_rel` |
| `passwall 组件 <名> 没落位` **（error）** | 关键组件在上游找不到了 | 看 `passwall_pkgs_repo` 的 `passwall_ref` 分支里是否还有它 |
| `并行编译失败（make 退出码 N）` **（warning）** | `make -j` 挂了，正在用 `-j1 V=s` 重跑 | 不用管；只有下面那条 error 才说明真失败 |
| `编译失败的包::<包路径>` **（error）** | 这个包没编过（OpenWrt 会打印 `ERROR: package/… failed to build.`） | 到「回放编译日志」里搜这个包名 |
| `编译报错行（尾部 8 条）` **（error）** | 从日志里挑出的真实报错行 | 通常一眼能看出原因（缺头文件、CMake 找不到文件、未定义引用……） |

### 诊断代码里有三个必须遵守的约束

改 `prepare-build.sh` 的诊断部分之前先看这三条，否则会写出「看起来能报错、
实际什么都看不到」的代码：

1. **注解必须写 `>&3`，不能写 fd1/fd2。** 脚本会把 fd1/fd2 重定向到日志文件，
   而 bash 对普通文件是**块缓冲**的：脚本 `exit` 时缓冲区里最后几 KB 根本没落盘，
   而 `_dump_log_tail` 是用 `tail` 去读那个文件的。写 fd1/fd2 的报错信息恰好就是
   「看不到」的原因。（写日志用 `tee`，`tee` 不做用户态缓冲。）
2. **注解有数量上限，超出的会被 GitHub 丢掉。** 所以 `die` 把日志尾部先发、
   最要紧的那几条（具体符号名）**最后**发。
3. **多行证据写日志，不要塞进注解。** `_dump_symbol_def` 会把符号在
   `tmp/.config-package.in` 里的定义抄进日志（有没有 prompt、default 是什么、
   depends on 什么），几十行内容塞注解会把配额吃光。

### 两个已知的「符号被静默丢弃」陷阱

**① 不要手写「我认为重要的符号」清单来做校验。**
`DEVICE_PACKAGES` 带入的包（例如 `ipq-wifi-qnap_301w`）**不会**以
`CONFIG_PACKAGE_*` 的形式出现在 `.config` 里 —— `image.mk` 是用
`CONFIG_TARGET_DEVICE_PACKAGES_*` 传字符串的。写进清单必然误报、把构建整个卡死。
现在的做法是「配置里写了什么，就断言什么」。

**② LuCI 的语言包不能用 `CONFIG_PACKAGE_luci-i18n-…=y` 打开。**
`luci.mk` 生成的每个 `luci-i18n-<包>-<语言>` 包都带 `HIDDEN:=1`，
`scripts/package-metadata.pl` 于是把它写成：

```
config PACKAGE_luci-i18n-xxx-zh-cn
	bool                      ← 注意：没有标题，是个空 prompt
	default LUCI_LANG_zh_Hans||(ALL&&m)
```

而 `scripts/config/symbol.c` 规定：**只有 `sym->visible != no` 时才会采用
`.config` 里的用户值**，否则一律回落到 `default`。没有 prompt 的包在普通构建里
`default` 不成立，于是这一行写了也白写。正确做法是打开语言开关本身：

```
CONFIG_LUCI_LANG_zh_Hans=y
```

它是 luci-base 在 `Config.in` 里带标题的正常 `tristate`，能被 `.config` 赋值；
它 `=y` 之后上面那个 `default` 成立，所有 luci 包的简体中文翻译会一起被打开。

## 九、常见问题

**首页（状态 → 总览）怎么没有 CPU 占用率和温度？**
官方 LuCI 的总览页本来就没有这两项 —— `10_system.js` 只显示主机名/型号/内核/
时间/运行时长/负载均值。本固件在两个地方补上了：
- **首页底部多了「CPU / 温度 / 内存」一块**（本仓库自己写的 include，
  `files/www/…/status/include/95_qhora_hw.js`），显示当前 CPU 占用率（带频率）、
  每个温度传感器、内存用量，开机就有数，不需要等采集；
- 想看**曲线/历史**去 `状态 → 统计`（collectd 那套，本固件已带，温度采集默认开着）；
- `状态 → NSS Offload` 里还有 NSS 专用的核心负载和端口卸载统计。

如果首页那块显示的是 `?`，说明 rpcd 把读取拒了：确认
`/usr/share/rpcd/acl.d/qhora-overview.json` 在固件里（`ls` 一下），
再退出重新登录一次 LuCI 让会话重新取 ACL。

**首页那块温度是空的？**
先 `cat /sys/class/thermal/thermal_zone*/type` 看内核暴露了哪些温度区 ——
有哪个就显示哪个。ipq8072（QHora-301W）在 `ipq8074.dtsi` 里定义的区包括
`nss-top-thermal`、`nss0-thermal`、`nss1-thermal`、`wcss-phya0-thermal`、
`wcss-phya1-thermal`、`wcss-phyb0-thermal`、`wcss-phyb1-thermal`
（**`wcss-*` 就是无线子系统，也就是 WiFi 温度** —— 射频没开时读数不动是正常的）。
`hwmon` 里的传感器也会被一并收进来。

**`tempinfo` 在哪？首页为什么不像 ImmortalWrt 那样显示一行「Temperature」？**
`tempinfo` / `cpuinfo` 是 `autocore` 包装的两个脚本，SSH 里直接跑：

```sh
tempinfo        # CPU: 51.3°C, WiFi: 58.0°C
cpuinfo         # Qualcomm Technologies, Inc. IPQ8072A
```

注意 `tempinfo` 只读 `thermal_zone0`，**不是**全部热区；WiFi 那半截按
`/sys/class/ieee80211/phy*/hwmon*/` 找，ath11k 平台不一定有该路径，
所以常见输出只有 `CPU: …` 半截 —— 属正常。

我们**故意没有**照搬 ImmortalWrt 那种「System 表里插一行 Temperature」的样式：
那要覆盖上游的 `10_system.js` 和整个 rpcd ucode 插件，跨分支替换会随上游漂移。
首页温度由自写的 `95_qhora_hw.js` 负责，列的是**全部**热区（含 NSS / WiFi），
信息比 ImmortalWrt 那一行更全，而且不依赖任何 ubus 方法，也就不受
「官方 LuCI 没有 `luci.getTempInfo`」影响。

**「状态 → NSS Offload」为什么是英文？**
这个页面不是 luci feed 里的应用，而是 NSS 分支主树 `package/nss/nss-tools` 附带的
纯 JS 页面，上游没有提供任何翻译文件（也不走 luci.mk 的翻译机制），所以
`CONFIG_LUCI_LANG_zh_Hans` 管不到它。除非上游加翻译，否则只能英文。

**统计页里没有温度曲线？**
温度插件（`collectd-mod-thermal`）固件里已带、开机脚本也已打开采集开关；
如果还是空的，去 `统计 → 设置 → Thermal` 看传感器列表有没有被选上，
或者 `cat /sys/class/thermal/thermal_zone*/type` 确认内核暴露了哪些温度区。

**构建超时（6 小时）。**
首次运行没有 ccache，最慢；GitHub 托管 runner 单 job 上限就是 6 小时。
直接重跑一次即可 —— `dl` 源码包缓存和 ccache 都会复用，第二次快很多。

**`defconfig 丢弃了配置文件请求的符号`。**
说明某条依赖没满足，或者那个符号根本没有 prompt（见第八节陷阱②）。
注解里会逐个列出被丢的符号名，日志里有它们在 kconfig 里的定义，
对照着修 `configs/` 即可。

**artifact 里没有 sysupgrade 镜像。**
工作流在"收集并校验产物"那步就会 `exit 1` 报出来，不会静默给你一个空包。

**ddns-go 上游发了新版，为什么固件里还是旧的？**
按可能性排序：

1. **这一轮解析失败了，回落成了配方兜底值。** 运行页会有一条 warning 注解
   （`解析上游最新版本失败`）。点 `Re-run all jobs` 即可，多半是 API 抖动。
2. **`ddns-go` 发的是预发布版。** 脚本查的是 `releases/latest`，它**不加**
   预发布标签 —— 这是故意的，上游的 rc/beta 不该自动进固件。
3. **ImmortalWrt 的 luci 前端没跟上。** 页面是 ImmortalWrt 那边维护的，
   二进制是新的、页面是旧的，功能一般不受影响；等它更新或手工改 `LUCI_PATHS`。
4. **本地增量编译时没重下源码。** `dl/` 里已有同名压缩包时不会重下，
   而 `PKG_VERSION` 变了就会拉新的；确认办法是看运行页的
   `本轮固件里的上游包版本` 注解。

**上游改名/迁移了。**
改 `env.UPSTREAM_REPOSITORY` / `UPSTREAM_REF` / `NSS_FEED` 三个地方即可。
`ddns-go` / `msd_lite` 的源码地址在 `packages/net/*/Makefile` 里，各自独立。
passwall2 的两个仓库地址是 `extra-packages.sh` 的 `PW_APP_REPO` / `PW_PKGS_REPO`
（工作流里对应 `passwall_app_repo` / `passwall_pkgs_repo` 输入）——
这个项目刚从个人账号 `xiaorouji` 搬到 `Openwrt-Passwall` 组织，所以这类迁移**已经**
发生过一次；再遇到时改这两个变量即可，脚本其他地方不用动。

**passwall2 编进去之后构建变慢了？**
正常。17 个组件里有 Go 项目（`sing-box` / `geoview` 等，走 `lang/golang` 那套，
自带 toolchain 编译），还有 `haproxy` 这种 C 大件，比不编它们肯定要久。
另外 `sslocal` 属于 `shadowsocks-rust`，要拉整套 Rust 工具链（prebuilt 下载 +
cargo 编译），比之前多 15~25 分钟 —— 这是为了 SS-Rust 类型节点能启动，不能省
（见第五节）。没编的是 `shadow-tls` 和 SS-Rust 服务端。
如果因此撞上 6 小时超时，重跑一次通常能过（`dl` 缓存和 ccache 会复用）。

**passwall2 日志报 `sslocal not found, unable to start...`？**
说明节点类型是 `SS-Rust` 但固件里没有 `sslocal`。本固件从这一版起已编入；
如果你刷的是更早的 run，要么升级，要么在「节点订阅」页把 SS 类型显式选成
`sing-box`（sing-box 原生支持 SS，不需要外部进程）。

**为什么固件里没有 xray？**
这是刻意的：`Basic_Core_SingBox=y`，只编 sing-box。sing-box 覆盖了 SS / SSR /
VMess / VLESS / Trojan / Hysteria2 / WireGuard 全部常用协议，`_shunt` 分流也是它
自己实现的。想切回 xray 见第五节表格最后一行。

---

## 十、致谢与许可

编译配方与配置来自
[JuliusBairaktaris/Qualcommax_NSS_Builder](https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder)（GPL-2.0）。
NSS 上游链路涉及
[Ansuel](https://github.com/Ansuel)（EDMA/PPE 驱动）、
[robimarko](https://github.com/robimarko)（qualcommax target 维护）、
[qosmio](https://github.com/qosmio)（NSS 打包与 Wi-Fi 卸载补丁）以及
OpenWrt 的 [NSS build 讨论帖](https://forum.openwrt.org/t/qualcommax-nss-build/148529)。

本仓库内容沿用 GPL-2.0。
