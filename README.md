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
├── .github/workflows/build-qhora-301w.yml   # 编译工作流（入口）
├── configs/
│   ├── common.config                        # NSS 卸载栈 + 通用选项 + 附加功能包
│   └── qhora_301w.config                    # 机型：target/子目标/设备/内存档位
├── scripts/
│   ├── prepare-build.sh                     # 组装 .config、跑 defconfig、校验、叠加覆盖文件
│   ├── extra-packages.sh                    # 引入官方 feed 没有的包（ddns-go / msd_lite）
│   └── push-to-github.sh                    # 本地一键推送脚本
├── files/etc/uci-defaults/99-qhora-301w     # 首次启动的设置（主机名、启用服务）
├── .gitattributes / .gitignore
└── README.md
```

`configs/` 里的内容取自上游作者自己维护的
[Qualcommax_NSS_Builder](https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder)
的 `devices/common/config` 与 `devices/ipq807x-1g/config` —— 那是这套 NSS 栈
**唯一被持续验证过**的配置组合，所以基本保持原样，只做了两处针对性改动（见下），
外加在文件末尾追加了 ddns-go / msd_lite / WireGuard 三组独立的功能包（见第五节）。

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

推送改动、或每周一 00:30（东八区）定时检查上游更新时也会自动触发（定时触发只出 artifact）。

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

4. 起来后路由器默认地址 `192.168.1.1`，`root` 无密码。把 sysupgrade 镜像传上去：

   ```sh
   scp openwrt-...-qnap_301w-squashfs-sysupgrade.bin root@192.168.1.1:/tmp/
   ssh root@192.168.1.1
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

### 已启用的附加服务

| 服务 | 状态 | 怎么用 |
|---|---|---|
| **ddns-go** | 开机自启 | Web 界面 `http://<路由器IP>:9876`，在里面添加 DDNS 记录。数据在 `/etc/ddns-go/config.yaml` |
| **msd_lite** | 开机自启 | 客户端按 `http://<路由器IP>:7088/udp/<组播地址>:<端口>` 取流。**接收组播的网卡需要在 `服务 → msd_lite` 里选**（见下） |
| **WireGuard** | 仅装好 | 没有常驻服务，到 `网络 → 接口` 新建一个 `wg` 协议接口即可，内核模块会自动加载 |

LuCI 界面默认就是简体中文（`CONFIG_LUCI_LANG_zh_Hans=y`，见第六节）。

想验证服务真的起来了：

```sh
/etc/init.d/ddns-go status
/etc/init.d/msd_lite status
ls /etc/rc.d/ | grep -E 'ddns-go|msd_lite'   # 有 S99 开头的链接说明开机自启已生效
wg show                                      # 建好 wg 接口后可用
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
| 加一个**官方 feed 没有**的包 | 在 `scripts/extra-packages.sh` 的 `PKG_PATHS` / `LUCI_PATHS` 里加路径，再到 `common.config` 加符号 |
| 开关某个内核选项 | 同上，`CONFIG_KERNEL_xxx=y` |
| 换编译分支 | 工作流 `Run workflow` 时填 `upstream_ref`，或改 YAML 里 `UPSTREAM_REF` 的默认值 |
| 用自己 fork 的源码 | 改 YAML `env.UPSTREAM_REPOSITORY` |
| 系统默认配置（主机名、IP、无线、服务开关） | 往 `files/` 里按路径放文件，会原样叠加进镜像；首次启动脚本在 `files/etc/uci-defaults/` |
| 同时编多个机型 | 在 `configs/qhora_301w.config` 再加 `CONFIG_TARGET_DEVICE_qualcommax_ipq807x_DEVICE_xxx=y`，注意 RTL 相关的高危项见下 |

改完 `.config` 的选项要**推送到仓库再跑**，否则不会生效。

### 关于 extra-packages.sh

`ddns-go` 和 `msd_lite` 在 OpenWrt 官方 `packages` feed 里**不存在**，只有 ImmortalWrt
的 feed 在维护。这里没有把整个 ImmortalWrt feed 加进 `feeds.conf` —— 那个 feed 是官方
feed 的分支，有成百上千个同名包（`luci-app-firewall`、`aria2`……），两份同名包会互相
打架，而这个 NSS 构建对 luci/packages 的版本组合相当敏感。

所以改成用 git 稀疏检出，只把这 4 个目录抠出来，放进对应 feed 的目录树：

```
feeds/packages/net/ddns-go
feeds/packages/net/msd_lite
feeds/luci/applications/luci-app-ddns-go
feeds/luci/applications/luci-app-msd_lite
```

**为什么必须放进 feed 目录而不是 `package/`**：这些 Makefile 用的是相对路径 ——
luci 应用是 `include ../../luci.mk`，`ddns-go` 是
`include ../../lang/golang/golang-package.mk`。只有放在 `<feed根>/<二级目录>/<包>/`
这个位置才能解析得到，放进 `package/` 会直接报找不到 luci.mk。

**调用顺序不能变**：`feeds update -a` → `extra-packages.sh` → `feeds update -i -a` → `feeds install -a`。
`-i` 表示只重建索引、不执行 `git pull`（否则会碰到刚拷进去的文件），而 `install`
读的是 `feeds/<name>.index`，不重建索引就看不到新包。`prepare-build.sh` 里已经按这个
顺序串好了，并在 install 之后检查 `package/feeds/...` 是否真的存在 —— 索引没生效的话
会立刻失败，而不是默默编出一个缺功能的固件。

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
# 官方 feed 里没有 ddns-go / msd_lite，这一步会把它们放回 feed 目录树
OPENWRT_DIR="$PWD" /path/to/qhora-301w-build/scripts/extra-packages.sh
./scripts/feeds update -i -a && ./scripts/feeds install -a
make defconfig
```

工作流每次都是全新 checkout，所以不受影响。

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

在上面三条之外，追加了三组功能包（`ddns-go` / `msd_lite` / `WireGuard`，见第五节），
以及配套的 `scripts/extra-packages.sh`。这三组是**独立追加**的，删掉它们不影响
NSS 卸载栈本身。

---

## 七、本地编译（不用 CI）

```sh
git clone -b nss-edma-rework https://github.com/JuliusBairaktaris/openwrt-nss-edma openwrt
cd openwrt

# 下面这一步会自己做完全部准备工作：追加 nss feed、引入 ddns-go/msd_lite、
# 跑 feeds update/install、拼 .config、跑 defconfig、校验符号、叠加 files/。
OPENWRT_DIR="$PWD" BUILDER_DIR="../qhora-301w-build" bash ../qhora-301w-build/scripts/prepare-build.sh

make -j"$(nproc)"
```

Ubuntu 24.04/26.04 上需要：
`bzip2 g++ gawk gcc git glibc-source libncurses-dev make`，
磁盘留 **35GB** 以上。全量编译（含 LTO）在 4 核机器上要几个小时。

（脚本里的文件叠加用的是 `cp -a` 而不是 `rsync`，所以**不需要**装 rsync。）

---

## 八、排查构建失败

工作流的 job 日志要仓库 admin 权限才能从 API 下载，所以 `scripts/prepare-build.sh`
特意让失败**可远程诊断**：

- 全部输出落盘到 `$GITHUB_WORKSPACE/prepare-build.log`；
- 失败时把「出错行号 + 出错命令 + 日志尾部」以 `::error::` 输出 —— 那会变成
  check-run annotation，在 Actions 页面和公开 API 上都能直接看到；
- 工作流里还有一步 `if: always()` 的「回放构建准备日志」，把日志尾部打到控制台。

典型报错：

| 注解内容 | 含义 | 怎么处理 |
|---|---|---|
| `prepare-build.sh 在第 N 行失败` + `失败命令：…` | 该命令返回非零 | 看注解随附的日志尾部 |
| `defconfig 丢弃了 N 个配置请求的符号` | Kconfig 依赖没满足，选项被静默丢弃 | 后面几条注解会逐个列出符号名 |
| `defconfig 丢弃符号：CONFIG_PACKAGE_xxx=y` | 具体是哪个选项被丢了 | 日志里有该符号的 kconfig 定义，看它的 `bool`/`default`/`depends on` |
| `package/feeds/... 不存在` | 放进 feed 的包没被 `feeds install` 接管 | 检查 `feeds update -i` 那一步 |

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

**构建超时（6 小时）。**
首次运行没有 ccache，最慢；GitHub 托管 runner 单 job 上限就是 6 小时。
直接重跑一次即可 —— `dl` 源码包缓存和 ccache 都会复用，第二次快很多。

**`defconfig 丢弃了配置文件请求的符号`。**
说明某条依赖没满足，或者那个符号根本没有 prompt（见第八节陷阱②）。
注解里会逐个列出被丢的符号名，日志里有它们在 kconfig 里的定义，
对照着修 `configs/` 即可。

**artifact 里没有 sysupgrade 镜像。**
工作流在"收集并校验产物"那步就会 `exit 1` 报出来，不会静默给你一个空包。

**上游改名/迁移了。**
改 `env.UPSTREAM_REPOSITORY` / `UPSTREAM_REF` / `NSS_FEED` 三个地方即可。

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
