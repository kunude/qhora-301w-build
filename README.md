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
│   ├── common.config                        # NSS 卸载栈 + 通用选项
│   └── qhora_301w.config                    # 机型：target/子目标/设备/内存档位
├── scripts/prepare-build.sh                 # 组装 .config、跑 defconfig、校验、叠加覆盖文件
├── files/etc/uci-defaults/99-qhora-301w     # 首次启动的设置（主机名）
├── .gitattributes / .gitignore
└── README.md
```

`configs/` 里的内容取自上游作者自己维护的
[Qualcommax_NSS_Builder](https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder)
的 `devices/common/config` 与 `devices/ipq807x-1g/config` —— 那是这套 NSS 栈
**唯一被持续验证过**的配置组合，所以基本保持原样，只做了两处针对性改动（见下）。

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

---

## 五、改配置

| 想改什么 | 改哪 |
|---|---|
| 多加一个软件包 | 在 `configs/common.config` 末尾加 `CONFIG_PACKAGE_xxx=y` |
| 开关某个内核选项 | 同上，`CONFIG_KERNEL_xxx=y` |
| 换编译分支 | 工作流 `Run workflow` 时填 `upstream_ref`，或改 YAML 里 `UPSTREAM_REF` 的默认值 |
| 用自己 fork 的源码 | 改 YAML `env.UPSTREAM_REPOSITORY` |
| 系统默认配置（主机名、IP、无线） | 往 `files/` 里按路径放文件，会原样叠加进镜像 |
| 同时编多个机型 | 在 `configs/qhora_301w.config` 再加 `CONFIG_TARGET_DEVICE_qualcommax_ipq807x_DEVICE_xxx=y`，注意 RTL 相关的高危项见下 |

改完 `.config` 的选项要**推送到仓库再跑**，否则不会生效。

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
./scripts/feeds update -a && ./scripts/feeds install -a
make defconfig
```

工作流每次都是全新 checkout，所以不受影响。

---

## 六、相对上游配方做的改动

只有两处，其余保持原样：

1. **打开了 initramfs**（`CONFIG_TARGET_ROOTFS_INITRAMFS=y`）。
   上游为了多机型共用镜像关掉了它——因为 Asus RT-AX89X 的 recovery trx 把内核
   卡在 16MiB，而 NSS initramfs 内核约 21MiB。单机型编译没有这个约束，而
   QHora-301W 的**首次安装恰恰必须靠 initramfs**（U-Boot TFTP 引导）。

2. **把设备/子目标固定到 QHora-301W**，并把上游按内存容量分组的
   `devices/ipq807x-1g` 配置合并进 `configs/qhora_301w.config`。

---

## 七、本地编译（不用 CI）

```sh
git clone -b nss-edma-rework https://github.com/JuliusBairaktaris/openwrt-nss-edma openwrt
cd openwrt
cp feeds.conf.default feeds.conf
echo "src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;edma-nss" >> feeds.conf
./scripts/feeds update -a && ./scripts/feeds install -a

OPENWRT_DIR="$PWD" BUILDER_DIR="../qhora-301w-build" bash ../qhora-301w-build/scripts/prepare-build.sh

make -j"$(nproc)"
```

Ubuntu 24.04/26.04 上需要：
`bzip2 g++ gawk gcc git glibc-source libncurses-dev make rsync`，
磁盘留 **35GB** 以上。全量编译（含 LTO）在 4 核机器上要几个小时。

---

## 八、常见问题

**构建超时（6 小时）。**
首次运行没有 ccache，最慢；GitHub 托管 runner 单 job 上限就是 6 小时。
直接重跑一次即可 —— `dl` 源码包缓存和 ccache 都会复用，第二次快很多。

**`defconfig 丢弃了关键符号`。**
说明某条依赖没满足，通常是因为 NSS feed 没拉到位，或者上游 rebase 后改了符号名。
看报错里列出的符号名，对照上游最新代码修正 `configs/`。

**artifact 里没有 sysupgrade 镜像。**
工作流在"收集并校验产物"那步就会 `exit 1` 报出来，不会静默给你一个空包。

**上游改名/迁移了。**
改 `env.UPSTREAM_REPOSITORY` / `UPSTREAM_REF` / `NSS_FEED` 三个地方即可。

---

## 九、致谢与许可

编译配方与配置来自
[JuliusBairaktaris/Qualcommax_NSS_Builder](https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder)（GPL-2.0）。
NSS 上游链路涉及
[Ansuel](https://github.com/Ansuel)（EDMA/PPE 驱动）、
[robimarko](https://github.com/robimarko)（qualcommax target 维护）、
[qosmio](https://github.com/qosmio)（NSS 打包与 Wi-Fi 卸载补丁）以及
OpenWrt 的 [NSS build 讨论帖](https://forum.openwrt.org/t/qualcommax-nss-build/148529)。

本仓库内容沿用 GPL-2.0。
