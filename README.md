# QHora-301W 固件构建

为 **QNAP QHora-301W**（`qualcommax` / `ipq807x` / `qnap_301w`，IPQ8072A + NSS）
编译 OpenWrt / ImmortalWrt 固件。一条 workflow，三层参数，选完就唯一确定一个固件。

## 怎么用

Actions → **Build QHora-301W** → Run workflow，填三个选择：

| 层 | 输入 | 取值 | 作用 |
|---|---|---|---|
| ① | `distro` | `immortalwrt` / `openwrt` | 检出哪棵上游树 |
| ② | `nss` | 是 / 否 | 是否换成 ppe-nss 整树（见下） |
| ③ | `proxy` | `daed` `dae` `homeproxy` `singbox` `passwall2` `none` | 装哪套透明代理 |

另外两个可选项：`extra_packages`（额外插件，逗号分隔）、`release`（成功后发 Release）。

### ②选「是」时，①会失效

`nss=是` 时检出的是 `JuliusBairaktaris/openwrt-ppe-nss@ppe-nss` —— 它是
**openwrt main 的 fork**，不是 immortalwrt 的分支。所以这时候 ① 选的
immortalwrt 拿不到，imm 特有的包也不会有。这是刻意的，不是 bug。

## NSS 只有两态，没有中间态

```
nss=是  →  ppe-nss 整树   →  有线 PPE 加速 + Wi-Fi offload（NSS 核心跑 Wi-Fi 数据面）
nss=否  →  纯上游树       →  不引 NSS feed、不开任何 NSS 符号
```

以前有过第三种「immortalwrt + NSS 补丁」，现在不成立了，因为情况变了：

- PR #22381（`qca_edma` 重构）2026-07-11 合入 openwrt main
- PR #24806（`qca_ppe` host-driven offload）2026-10-26 合入 openwrt main
- immortalwrt master 已同步，且 `ipq807x/config-default` 里
  `CONFIG_QCOM_EDMA=y`、`CONFIG_QCOM_80211AX_PPE=y` 默认就开

也就是说**「有线加速」imm 自带，不需要任何补丁**；而「Wi-Fi offload」的
`nss-wifi-drv` 是 ppe-nss 树内的包，还改了 mac80211 的 ath11k 源码
（给 QCN9074 加 wifili 实例、多实例卸载），那不是补丁能补出来的量级。

两头一夹，中间态就没了。

> 顺带一句：跑透明代理时，被代理的流量本来就在 CPU 上（dae 是 eBPF、
> sing-box 是 userspace），PPE/NSS 加速对它们**无效**——它只加速 fw4
> flowtable 里的直连流量。所以「为了代理更快」去开 NSS 是方向错的；
> NSS 真正帮到的是不走代理的 LAN↔WAN 大流量（NAS、IPTV）。

### 防静默降级

ppe-nss 的 config 里有一堆上游不认识的符号：

```
CONFIG_PACKAGE_kmod-nss-wifi-drv
CONFIG_ATH11K_NSS_WIFI
CONFIG_NSS_FIRMWARE_VERSION_12_5
CONFIG_PACKAGE_ppe-help
```

树不对时 `make defconfig` 会**静默丢弃**它们 —— 固件照样编出来、名字一样、
刷进去也能开机，只是 Wi-Fi 还在 CPU 上。所以 `scripts/prepare.sh` 不看变量，
直接查树里有没有 `package/kernel/nss-wifi-drv` 和
`seeds/qualcommax-nss-wifi.seed`，对不上立刻失败。

## 恒定的东西（不占选择层）

**四个默认插件永远带上**：`msd_lite`、`ddns-go`、`wireguard`、`qrencode`。
前两个用本仓库自带配方（构建时解析上游最新版本），LuCI 前端从 ImmortalWrt 稀疏检出；
`qrencode` 给 WireGuard 客户端页和订阅链接渲染二维码。

**其他插件全部从 [kenzok8/small](https://github.com/kenzok8/small) 取最新源码**，
不写死版本：每次构建 `feeds update small` 拿当时最新的。填在 `extra_packages`
里即可（例如 `luci-app-openclash,mosdns`）。

接入点在 `feeds install -a` **之后** —— small 里不少包与官方 feed 同名
（sing-box / homeproxy / daed），提前加 feed 行会让 `install -a` 把 small
全部二十多个包 link 一遍，撞名直接让 make 报 `duplicate package`。

## 目录

```
.github/workflows/
  build.yml               唯一的构建入口
  debug-singbox-pkg.yml   单包调试线（只编 sing-box，验配方）
configs/
  common.config           所有变体共用
  qhora_301w.config       机型
  imm.config              immortalwrt 差异层（仅 distro=imm 且 nss=否 时挂）
  none.config             不集成代理（把 passwall2 全家 + Rust 工具链按掉）
  daed.config 等          各代理栈的覆盖层
scripts/
  prepare.sh              唯一入口：三层参数 → 树选择 + config 拼装
  prepare-build.sh        feeds / .config / 符号校验 / 覆盖文件 / 内核补丁
  wanted-packages.sh      当前变体「必须进固件」的包清单 → 产物校验用
  extra-packages.sh       ddns-go / msd_lite / passwall2 组件落位
  resolve-*.sh            上游版本解析（每次构建取最新）
files/ files-<stack>/     rootfs 覆盖，按代理栈叠加
packages/                 自带配方（如 sing-box-refind）
patches/kernel/           内核补丁
archive/                  旧的 11 个 workflow、旧 NSS 补丁与脚本
docs/build-lines-archive.md  旧结构文档（各代理栈的配置字段仍可参考）
```

## 本地构建

```sh
git clone --depth 1 https://github.com/immortalwrt/immortalwrt openwrt   # 或 ppe-nss
OPENWRT_DIR=$PWD/openwrt BUILDER_DIR=$PWD \
  DISTRO=immortalwrt NSS=0 PROXY_STACK=daed bash scripts/prepare.sh
cd openwrt && make -j"$(nproc)"
```

`NSS=1` 时把第一行换成：

```sh
git clone --depth 1 -b ppe-nss https://github.com/JuliusBairaktaris/openwrt-ppe-nss openwrt
```

## 构建后的校验

`.config` 里写 `=y` 只证明「被选中」，不证明「编出来了」。所以有三道独立核对：

1. **符号**：`prepare-build.sh` 把配置文件请求的每个 `=y` 符号与 `make defconfig`
   之后的结果比对，丢一个就失败并打印该符号在 kconfig 里的定义。
2. **产物**：`wanted-packages.sh` 按变体生成包清单，逐个查包文件
   （apk 后端 `.apk` / opkg 后端 `.ipk`）与 rootfs 的 `.manifest`。
3. **内核前提**：`daed` / `dae` 的 eBPF 程序靠 CO-RE 读内核结构，必须查
   `vmlinux` 里真的有 `.BTF` 段 —— `.config` 开了 `DEBUG_INFO` 也可能被
   `KERNEL_DEBUG_INFO_REDUCED` 挡掉。

## 归档

`archive/` 下的东西不再参与构建，只作回溯：

- `archive/workflows/` —— 重构前的 11 个 workflow（源 × 代理栈 × sing-box 模式）
- `archive/patches/immortalwrt-nss/` —— 把 openwrt main 的 NSS 改动打到 imm 上的补丁集
- `archive/scripts/apply-nss-patches.sh` —— 应用上述补丁的脚本
- `archive/configs/imm-nss.config` —— 那条线的 config 覆盖层

它们退出历史的原因：NSS 已经不需要「往 imm 上打补丁」这条路了（见上文）。
