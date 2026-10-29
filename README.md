# QHora-301W 固件构建

为 **QNAP QHora-301W**（`qualcommax` / `ipq807x` / `qnap_301w`，IPQ8072A + NSS）
编译 OpenWrt / ImmortalWrt 固件。一条 workflow，三层参数，选完就唯一确定一个固件。

## 怎么用

Actions → **Build QHora-301W** → Run workflow，填三个选择：

| 层 | 输入 | 取值 | 作用 |
|---|---|---|---|
| ① | `distro` | `immortalwrt` / `openwrt` | 检出哪棵上游树 |
| ② | `nss` | 是 / 否 | 是否换成 ppe-nss 整树（见下） |
| ③ | `proxy` | `daed` `dae` `honk` `homeproxy` `singbox` `passwall` `passwall2` `none` | 装哪套透明代理 |

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

## 代理栈之间只能选一个

`daed` / `dae` / `honk` 是同一族（eBPF 内核态分流，抢 clsact / NFQUEUE），
`homeproxy` / `passwall` / `passwall2` / `singbox` 是另一族（userspace + TPROXY/nft），
任何两套同时装都会互相打架，所以 ③ 只能选一个。
`passwall` 与 `passwall2` 是同一项目的两代（见下），连配置命名空间都不同，更不能并存。

### honk + doona（2026-10-28 新增）

`honk` 是 [daeuniverse/honk](https://github.com/daeuniverse/honk) —— dae 那一支的
Rust 重写，配置语法沿用 dae，出站组 / Clash 兼容 API 借自 sing-box。
`doona` 是它的静态 Web 面板（不单独成包，装在 `/usr/share/doona`，
由 honk 自己在 `127.0.0.1:9527/ui/` 提供）。

| | |
|---|---|
| 包从哪来 | `kenzok8/small` 的 `honk` + `luci-app-honk`（后者自带 doona） |
| 核心形态 | 预编译 aarch64 二进制（kenzok8 CI 从上游源码交叉编译），**不拉 Rust 工具链** |
| 内核前提 | Linux ≥ 6.12（当前三棵树都是 6.18）、BTF、`CGROUP_BPF`、cls_bpf、NFQUEUE |
| 首次使用 | 面板里先「初始化」再「启用」—— 包默认 `enabled=0`，不在开机时自启 |

⚠️ 上游自述 **alpha**（核心 0.0.1-alpha），量产前自己压测。

small 里那两个 Makefile 只是骨架：**下载地址与哈希在三个不随仓库提交的
`generated-*.mk` / `provenance.json` 里**，而它们默认指向一个已经删掉的
`staging` 标签（实测 404）。所以 `scripts/fetch-honk-stage.sh` 会在 feeds 落位之后，
按 small 写死的 `CORE_COMMIT` 去 `kenzok8/openwrt-honk` 的 `source-*` 发布里
**匹配资产名**（不是取最新：取错就是 404），把三个文件补齐并校验后落位。

### passwall 与 passwall2 是两代，不是两个皮肤

同一个项目（[Openwrt-Passwall](https://github.com/Openwrt-Passwall)）的两代前端：

| | `passwall`（v1） | `passwall2`（v2） |
|---|---|---|
| 界面实现 | **Lua CBI**（`luasrc` + `luci-compat` + `lua`） | ucode / JS |
| 配置 | `/etc/config/passwall` + `passwall_server` | `/etc/config/passwall2` |
| 分流 | dnsmasq + chinadns-ng + 核心规则 | sing-box `route.rules` |
| 核心 | **Xray 与 sing-box 都带**（按节点选） | 只带 sing-box（省 20MB） |
| 仓库 | `openwrt-passwall` | `openwrt-passwall2` |

两者的**依赖组件共用** `openwrt-passwall-packages`（17 个配方），所以切换只影响
前端包与 `.config` 里的符号组：`configs/passwall.config` 会把 common.config 里
那组 v2 符号整组按掉、换成 v1 的（`INCLUDE_Xray` / `INCLUDE_SingBox` / …）。

v1 为什么带 Xray：它的核心是**按节点选**的，社区里的老配置绝大多数是 Xray 节点；
只带 sing-box 会"编得出来、刷得进去、节点起不来"。想省空间就把
`configs/passwall.config` 里 `INCLUDE_Xray` 那行改成 `n`（sing-box 覆盖
SS / VMess / VLESS / Trojan / Hysteria2）。

两条线都**不带出厂预置**给 v1 —— `files-passwall2/` 那份分流模板是 v2 的配置格式，
v1 的字段完全不同，混用会解析失败。v1 起来就是上游默认值（`enabled=0`），
在「服务 → PassWall」里自行配置。

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

### 依赖会自动带出来

点一个插件，它的依赖不用手填。两层机制：

**第一层，`feeds install` 自己会跟**：它沿 `DEPENDS` 递归装**同一个 feed 内**的
运行时依赖（源码里 `install_src` 遍历 `packages->depends`）。所以
`luci-app-nikki` 会带上 `nikki` 和 `mihomo`。

**第二层，`scripts/resolve-deps.sh` 展开完整闭包**：`feeds install` 只在同一个
feed 内跟依赖、跳过 `@条件`、也不处理 `+COND:pkg` 里的条件包名，所以它不够。
闭包脚本把整条链算出来，缺的补建软链，然后在日志里打出**每个依赖的最终落位**：

```
==> 闭包共 21 项：luci-base[external] … mihomo[small] nikki[small] mosdns[small] …
==> 额外插件的依赖落位：
    mosdns                   进固件
    mihomo                   进固件
    geo2txt                  进固件
```

三种状态含义不同：`进固件`（`=y`，真的会打进镜像）、`未选`（条件依赖没满足，
正常）、`无符号`（包没被 make 扫描到，**硬失败**——插件会在固件里缺东西）。

只点名包会写进 `.config`（`CONFIG_PACKAGE_*=y`），依赖不写——由 defconfig 顺着
`select` 精确带出。这样既不会漏，也不会把整个闭包硬塞进镜像。

`NSS=是` 时还有一层：ppe-nss 是 openwrt main 的 fork，它的 luci / packages feed
是**官方 openwrt** 的，没有 `dae` / `daed` / `homeproxy` 这些 ImmortalWrt 专属包。
`extra-packages.sh` 会按「feed 里有没有」判断，缺了才从 immortalwrt 稀疏检出补进来
（`place_imm_extra`）—— 判据是 feed 而不是树名，ImmortalWrt 基座直接跳过。

## 目录

```
.github/workflows/
  build.yml               唯一的构建入口
  debug-singbox-pkg.yml   单包调试线（只编 sing-box，验配方）
configs/
  common.config           所有变体共用
  qhora_301w.config       机型
  imm.config              immortalwrt 差异层（仅 distro=imm 且 nss=否 时挂）
  nss.config              NSS 线的减法层（仅 nss=是 时挂，在 seed 之后）
  passwall.config         passwall v1 的符号层（把 v2 那组按掉、换 v1 的）
  none.config             不集成代理（把 passwall2 全家 + Rust 工具链按掉）
  daed.config 等          各代理栈的覆盖层
scripts/
  prepare.sh              唯一入口：三层参数 → 树选择 + config 拼装
  prepare-build.sh        feeds / .config / 符号校验 / 覆盖文件 / 内核补丁
  resolve-deps.sh         展开插件依赖闭包（small feed 内部递归）
  wanted-packages.sh      当前变体「必须进固件」的包清单 → 产物校验用
  fetch-honk-stage.sh     补齐 honk / doona 的构建元数据（generated-*.mk）
  extra-packages.sh       ddns-go / msd_lite / passwall(v1|v2) 组件落位
  test-local.sh           本地回归：在真树上跑 prepare，几组参数一起验
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

## 改完脚本先本地回归

`scripts/test-local.sh` 在**真实基座树**上跑 `prepare.sh`，覆盖几组关键参数。
prepare 阶段只要 1~3 分钟，而同样的错误丢到 CI 上要等二十几分钟，且日志要
admin 权限才下载得到。

```sh
scripts/test-local.sh ~/work/imm                  # 默认 none + daed
scripts/test-local.sh ~/work/imm none daed honk err   # 指定组合
scripts/test-local.sh ~/work/ppe nss              # NSS 线，树必须是 ppe-nss
```

它断言的不是"脚本跑完了"，而是三个真正的失败模式：

- **符号没被静默丢掉** —— defconfig 因为依赖不满足去掉了某个 `=y`
- **依赖真的进了 `.config`** —— 不只是建了软链（`无符号` 直接判失败）
- **NSS 线 `kmod-nss-wifi-drv` 确实在 `.config` 里** —— 否则"选了 NSS 等于没选"

`err` 组合是反向用例：故意点一个不存在的包，期望**失败且报错点明包名**。

这套脚本是 2026-10-28 那轮改动的产物，它一次抓出三个只在真树上暴露的问题：
`extra-packages.sh` 不认识 `PROXY_STACK=none`、`common.config` 里还留着上一代
NSS 的 21 个符号、反复跑时残留的 small feed 行会让 `feeds install -a` 装下整个 feed。

## 构建后的校验

`.config` 里写 `=y` 只证明「被选中」，不证明「编出来了」。所以有三道独立核对：

1. **符号**：`prepare-build.sh` 把配置文件请求的每个 `=y` 符号与 `make defconfig`
   之后的结果比对，丢一个就失败并打印该符号在 kconfig 里的定义。
2. **产物**：`wanted-packages.sh` 按变体生成包清单，逐个查包文件
   （apk 后端 `.apk` / opkg 后端 `.ipk`）与 rootfs 的 `.manifest`。
3. **内核前提**：`daed` / `dae` / `honk` 的 eBPF 程序靠 CO-RE 读内核结构，必须查
   `vmlinux` 里真的有 `.BTF` 段 —— `.config` 开了 `DEBUG_INFO` 也可能被
   `KERNEL_DEBUG_INFO_REDUCED` 挡掉。

## 归档

`archive/` 下的东西不再参与构建，只作回溯：

- `archive/workflows/` —— 重构前的 11 个 workflow（源 × 代理栈 × sing-box 模式）
- `archive/patches/immortalwrt-nss/` —— 把 openwrt main 的 NSS 改动打到 imm 上的补丁集
- `archive/scripts/apply-nss-patches.sh` —— 应用上述补丁的脚本
- `archive/configs/imm-nss.config` —— 那条线的 config 覆盖层

它们退出历史的原因：NSS 已经不需要「往 imm 上打补丁」这条路了（见上文）。
