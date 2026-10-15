# NSS 补丁集（immortalwrt 基座）

这一目录是 **immortalwrt + NSS** 那条线（`.github/workflows/build-qhora-301w-imm-nss.yml`）
的核心：把 NSS 硬件卸载支持以**补丁**的形式叠到活的 immortalwrt 源码树上。

```
nss-edma-rework-over-openwrt-main.patch   213 个文件、152 个新增
provenance.env                            来源（基线提交 / 来源分支 / 末端提交）
```

## 一、为什么是"补丁"，而不是直接用一个 fork

NSS（Qualcomm Network Subsystem 硬件卸载）**不在** OpenWrt / ImmortalWrt 上游。
它要碰 EDMA、PPE、DTS、mac80211、ath11k、ipmr、nat46、iproute2 和内核 conntrack，
是一整套改动，没法当普通包编进镜像。

老两条线用的是一个现成的基座：

```
JuliusBairaktaris/openwrt-nss-edma @ nss-edma-rework   =  openwrt main + NSS
```

问题是**那个分支已经被作者归档**（该分支 README 首行原文）：

> This branch is archived. It carried the vendor NSS stack (qca-nss-drv, ECM,
> NSS qdiscs) and is no longer updated or built. The default branch is now
> [`ppe-nss`](https://github.com/JuliusBairaktaris/openwrt-ppe-nss/tree/ppe-nss).

归档的含义是：内核、DTS、驱动、mac80211、LuCI 这一层**从此不再跟着上游走**。
所以本线把这层关系拆开：

| | 提供者 | 是否跟着上游更新 |
|---|---|---|
| **基座**（内核 / DTS / 驱动 / LuCI / feed） | `immortalwrt/immortalwrt` | ✅ 活的 |
| **NSS 改动** | 本目录这一份补丁 | ❌ 固定的，需要时手动重新生成 |

补丁里 213 个文件全是「相对 openwrt main 基线」的改动 —— 也就是说，
它描述的是"NSS 需要额外做什么"，与"基座是谁家的"无关。换基座不影响这份描述，
只要基座在这些文件上没有大改，补丁就能干净落下。

## 二、来源（可追溯）

| 项 | 值 |
|---|---|
| 基座项目 | `openwrt/openwrt` |
| 基线提交（fork 的分叉点，`merge-base`） | `53ec2d05a487e6011cfa096de9211d15197c501b` |
| 来源项目 | `JuliusBairaktaris/openwrt-nss-edma` |
| 来源分支 | `nss-edma-rework` |
| 来源末端提交 | `8520955773518b7c7bcf35cf029e118ac60e1d3b` |

同样的三行也写在 `provenance.env` 里，由 `scripts/apply-nss-patches.sh` 读出来
发成 `::notice::` 注解 —— 这样"这次编出来的固件里是哪一份 NSS"是公开可查的。

## 三、补丁里有什么（213 个文件）

| 组 | 内容 |
|---|---|
| `target/linux/qualcommax/patches-6.18/` | ECM（CORE / PPPoE / DSCPREMARK / 网桥 VLAN）、NSS qdisc、组播 MFC 卸载钩子、qca8k 的 etype / 8021q 打标、ramoops、NSS crypto RCG 时钟 |
| `target/linux/qualcommax/files/` | NSS 设备树片段（`ipq8074-nss.dtsi` / `ipq6018-nss.dtsi`）、EDMA/PPE 驱动里"与 NSS 固件共用硬件"的改动、conntrack DSCP 扩展、NSS mirror 的 uapi |
| `target/linux/qualcommax/dts/` | 各机型设备树挂上 NSS 节点（**QHora-301W 就是 `ipq8072-301w.dts` 加一行 `#include "ipq8074-nss.dtsi"`**） |
| `target/linux/generic/` | `hack-6.18/262-lib-crypto-unhide.patch`（NSS crypto 要）、`pending-6.18/682-ipmr-...patch` |
| `package/kernel/mac80211/` | ath11k + mac80211 的 **80 个** NSS Wi-Fi 卸载补丁、`ATH11K_NSS_SUPPORT` / `MAC80211_NSS_SUPPORT` 两个 Kconfig 开关、pbuf 的 init 与 uci 默认值 |
| `package/kernel/qca-ppe-nss/` | `kmod-qca-ppe-nss`：NSS 固件与主机 EDMA/PPE 之间的数据面胶水 |
| `package/kernel/nat46/` | 17 个补丁 + Makefile：MAP-T / MAP-E 的 ECM 卸载导出 |
| `package/nss/nss-tools/` | NSS 运行期工具：`nss` 开机服务、`nss-up`、`nss-status`、`edma-dump`、`nss-ppe-diff`、LuCI 页面（状态 → NSS Offload、网络 → QoS Marking (NSS)） |
| `package/network/utils/iproute2/patches/` | NSS qdisc 与 `nssmirred` 的 `tc` 支持 |
| 零散 | `package/base-files/files/sbin/sysupgrade`（升级前优雅停网络）、`package/kernel/linux/modules/`（ramoops / ipt-ipopt / evdev 的 kmod 条件） |

## 四、刻意排除的东西

| 排除了什么 | 为什么 |
|---|---|
| `.github/**` | 那是来源 fork 自己的 CI / issue 模板，与固件无关 |
| `README.md` | 来源项目的说明，与本仓库无关 |
| `toolchain/gcc/Config.version` | 来源 fork 在那里做的是"不要 `imply KERNEL_WERROR`"；ImmortalWrt 已经用注释实现了同样效果，套上去反而会把 ImmortalWrt 自己的工具链配置**回退**成旧版 |

## 五、怎么重新生成（基座往前走、补丁对不上时）

报错长这样（`scripts/apply-nss-patches.sh` 会逐条列出对不上的文件）：

```
::error::NSS 补丁应用失败：nss-edma-rework-over-openwrt-main.patch
::error::  target/linux/qualcommax/dts/ipq8072-301w.dts
::error::  ...
```

两条出路，按代价从小到大：

**出路一（最省事）：把基座钉回一个验证过的提交。**

```
Actions → 本工作流 → Run workflow → imm_ref = <一个能打上补丁的 commit>
```

这只解决"现在要出一份能用的固件"，基座仍然停在旧提交上。

**出路二：按新的上下文重新生成补丁。** 触发条件通常是"基座改了补丁也要改的那些文件"。

```sh
# 1) 拿来源 fork 的全历史（含基线提交，不然算不出 diff）
git clone -b nss-edma-rework https://github.com/JuliusBairaktaris/openwrt-nss-edma nss-edma
cd nss-edma

# 2) 基线提交就在它自己的历史里（它是 openwrt/openwrt 的 fork）
MB=$(git merge-base HEAD origin/main 2>/dev/null || echo 53ec2d05a487e6011cfa096de9211d15197c501b)

# 3) 生成补丁：排除上面第四节列的那三样
git diff --binary --full-index "$MB" HEAD -- \
  . ':(exclude).github' ':(exclude).github/**' \
  ':(exclude)README.md' ':(exclude)toolchain/gcc/Config.version' \
  > nss-edma-rework-over-openwrt-main.patch

# 4) 换掉本目录里的那份，同步更新 provenance.env 里的 NSS_BASE_COMMIT / NSS_FORK_COMMIT
```

> 来源分支已归档 ⇒ 它的末端提交不会变了，diff 是稳定的。
> 真要跟进的是**基座**：`immortalwrt` 往前走了，补丁的上下文可能对不上。

生成之后在本地验证一遍（不必等 CI）：

```sh
git clone --depth=1 https://github.com/immortalwrt/immortalwrt
cd immortalwrt
git apply --check /path/to/qhora-301w-build/patches/immortalwrt-nss/*.patch && echo 能干净应用
```

## 六、补丁集怎么被用

```
scripts/prepare-build-imm-nss.sh
   └─ scripts/apply-nss-patches.sh      # 本目录的补丁 → immortalwrt 源码树
        · 身份校验：OPENWRT_DIR 必须真是 ImmortalWrt（看 include/version.mk）
        · 应用（幂等：打过的反向能干净应用就跳过；先 git apply，再 patch -p1 兜底）
        · 断言：15 个关键文件 + 7 处关键字符串 + mac80211 的 80 个 NSS 补丁
   └─ scripts/prepare-build.sh          # 之后与老两条线完全同一套编排
```

断言那一步不是形式主义：补丁"应用成功"与"固件里真的带 NSS"是两件事。
少了 `ATH11K_NSS_SUPPORT` 这样的关键项，构建要么在符号校验时失败，
要么更糟 —— 静默编出一份**没有 NSS 的固件**。所以缺任何一项都当场中断。
