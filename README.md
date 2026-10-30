# QHora-301W 固件构建

为 **QNAP QHora-301W**（`qualcommax` / `ipq807x` / `qnap_301w`，IPQ8072A + NSS）
编译 OpenWrt / ImmortalWrt 固件。两条线，各自一个入口，代理栈在两边都能选。

## 怎么用

Actions 里两个入口，按基座选：

| 入口 | 基座 | NSS 怎么来 |
|---|---|---|
| **Build ImmortalWrt** | `immortalwrt/immortalwrt` | **移植**：构建时把 ppe-nss 的 `nss-wifi-drv` + 18 个 mac80211 补丁搬进来（`nss` 可选，默认开） |
| **Build OpenWrt (NSS)** | `JuliusBairaktaris/openwrt-ppe-nss@ppe-nss` | **整树**：直接编那棵树，组件本来就在里面 |

两边的 `proxy` 取值一样：`daed` `dae` `honk` `homeproxy` `singbox` `passwall`
`passwall2` `none`。另有 `extra_packages`（额外插件，逗号分隔）和 `release`。

## NSS：一套东西，两种落法

NSS 的 Wi-Fi 卸载不是一个 feed 包，而是四样：`nss-wifi-drv` 包 + 18 个
mac80211/ath11k 补丁 + mac80211 里的三处挂钩 + 内核侧的 EDMA/PPE 驱动。

```
openwrt 基座  →  ppe-nss 整树直接编  →  四样都在树里，上游维护
imm 基座      →  scripts/integrate-nss-wifi.sh 搬过来
              →  有线加速也是同一套 EDMA/PPE，一起换
```

第四样最容易漏：驱动直接调内核的 `qca_edma_cpu_queues_to_ring`、
`qca_ppe_fw_booted`、`qca_ppe_fw_carrier_set`（让固件和 host 共用接收 ring、
把 flow 交给固件）。上游 main 的 `qca_edma` 走的是另一套 DSA switch ops，
同名头文件的路径和内容都不同 —— 所以内核侧是整块换 7 个文件，不是打补丁。
设备树也要加一行 `#include "ipq8074-nss.dtsi"`（NSS 固件区的 reserved-memory）。

移植线只在三个前提下成立，缺一个就当场失败（不会静默编出无 NSS 的固件）：

- mac80211 backports 版本是 **7.2** —— 补丁按它生成，跳版就没法应用
- 挂钩锚点在 `Makefile` / `ath.mk` / 设备树里找得到 —— 找不到说明上游改结构了
- 内核里 `qca_edma.c` 还是上游那套 —— 上游要是自己吃进了 NSS 接口，就别覆盖

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
| 默认出口 | `fallback: proxy` —— 填了订阅就能出国。上游自带配置是 `direct`（全直连），照抄会「装完也不出国」，见下 |
| 首次使用 | 面板里先「初始化」再「启用」—— 包默认 `enabled=0`，不在开机时自启 |
| 订阅 | 包不带任何节点，**必须自己导入**：LuCI「服务 → Honk」里填订阅，或设备上往 `/etc/honk/config.dae` 的 `subscription` 块里填（0600） |

⚠️ 上游自述 **alpha**（核心 0.0.1-alpha），量产前自己压测。

**刷完机「出国不通」的两个必查点**（都不是 bug，是 honk 的默认姿态）：

1. **服务没起** —— `honk` 出厂 `enabled=0` / `initialized=0`，`/etc/init.d/honk start`
   会直接拒绝启动并在 syslog 里留一行 `refusing to start before explicit initialization`。
   先初始化再启用（LuCI「服务 → Honk」，等价命令是 `/usr/share/honk/control.sh initialize`）。
2. **没有节点** —— 预置里只有注释掉的订阅示例（公开仓库不能放真链接）。没订阅时
   `proxy` 组是空的，墙外流量必然不通。

排查用 `/usr/share/honk/control.sh diagnose`：它把 `kernel_requirements_unmet` /
`lan_network_unavailable` / `proxy_conflict` 这些原因一次性列出来，比翻日志快。

**命令行重启有个坑（实测于 2026-10-30，QHora-301W）**：`/etc/init.d/honk restart`
是 `stop` 紧接着 `start`，而旧实例在收到 TERM 后还要把 4 条连接 drain 完（最长 5s）
才删掉 `dae0`。新实例的 preflight 看到 `dae0 已存在` 就直接拒绝启动，表现为
`status` 说 stopped、`pgrep honk-core` 空、局域网全直连。LuCI 页面的「重启」
走的是 rpcd 的 `honk_lifecycle_restart`（带 30s 等待），没有这个问题。命令行改完
配置请用：

```sh
/etc/init.d/honk stop; while pidof honk-core >/dev/null; do sleep 1; done; /etc/init.d/honk start
```

已经卡住时不用慌：残留的 `dae0` 会在旧进程退出后由下一次 preflight 自动回收，
再 `start` 一次就正常。

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

两条线**不共用出厂预置**：`files-passwall2/` 那份分流模板是 v2 的配置格式，
v1 的字段完全不同，混用会解析失败。v1 的预置改用**薄补丁**的方式
（`files-passwall/etc/uci-defaults/zz-passwall-preset`），原因与做法见下面
「出厂预置」一节 —— 一句话：v1 的 `/etc/config/passwall` 不是随包发布的静态文件，
而是包内脚本在首启时生成并做字段迁移的，覆盖静态文件会把上游那份带分流总节点的
默认配置整份顶掉。

## 出厂预置

固件不是"装了一堆包的空系统"：刷完机就能用的东西，都在 `files/` 与
`files-<栈>/` 里，由 `prepare-build.sh` 第 6 步合并进源码树的 `files/`，
OpenWrt 在拼 rootfs 时原样铺上去。`etc/uci-defaults/*` 里的脚本在**首次开机**
跑一次、跑完自动删除。

| 层 | 内容 |
|---|---|
| `files/`（所有变体） | 主机名 `QHora-301W`、LAN 改 `192.168.35.1/24`、ddns-go 与 msd_lite 开机自启、温度采集打开、`sshd_config` |
| `files-daed/` | `wing.db` —— 构建期从 `configs/daed/*.dae` 编出来的 SQLite（DNS / 路由 / 分组 / 管理员口令哈希），刷完机 daed 一起来就是配好的 |
| `files-dae/` | `config.dae` 骨架（订阅留空）、`dae-geo-update`、`dae-switch`、配置 0600、SSH 登录修复 |
| `files-homeproxy/` | `/etc/config/homeproxy` + 9 个本地 `.srs` 规则集（**必须 local**，remote 会在服务启动时才下载，任一条失败即断网） |
| `files-singbox/` | `/etc/config/sing-box` + 配置模板 + 开机启用 |
| `files-passwall2/` | `/etc/config/passwall2` 分流模板（Direct / Proxy / Reject + URLTest 组） |
| `files-passwall/` | `zz-passwall-preset` —— 在厂商默认配置之上打的薄补丁（见下） |
| `files-honk/` | `/etc/honk/config.dae` —— 分组 / DNS / 分流 / 订阅占位，`include system.dae`（native_api + doona） |

### 两个非显而易见的取舍

**honk 的配置是"两份拼起来"的。** 我们的 `config.dae` 只管出站分组、DNS、分流和
订阅占位；`system.dae`（包的，管 wan/lan 接口、`data_dir`、`native_api` 与 doona 的
`ui` 路径）靠第一行的 `include` 挂进来。少这一行不会有任何报错，只是 doona 面板 404
—— 所以 `prepare-build.sh` 有一条断言专门查它。

**passwall v1 的预置是脚本、不是静态配置。** v1 的 `/etc/config/passwall` 由包内的
`/etc/uci-defaults/luci-app-passwall` 在首启时从 `/usr/share/passwall/0_default_config`
生成，随后就地做字段迁移（`tcp_node`→`node` 等）。直接塞一份静态文件会踩两个坑：
`[ ! -s ]` 判定不再成立 → 上游那份带分流总节点（`myshunt`）和三套 shunt_rules 的
默认配置整份用不上；schema 一变，我们这份就成了旧格式。所以只在它之后打一层
薄补丁，文件名用 `zz-` 前缀 —— `/etc/uci-defaults/*` 按文件名排序执行，`'l' < 'z'`。
改名会被 `prepare-build.sh` 判红（改名后脚本会在配置文件还没生成时就退出，静默失效）。

### 三道守卫，防"编得出来、刷得进去、配置空白"

1. **`check-no-credentials.sh`** —— 覆盖层里不许出现节点凭据或订阅链接。
   扫 `etc/config/*`（uci 语法）与 `etc/{dae,honk}/*.dae`（dae 语法，`url:` 只出现在
   subscription 块内）。固件是公开产物，写进去就等于公开你的机场。
2. **`prepare-build.sh` 的断言** —— dae / daed / honk / passwall 四条线各自点名核对
   关键文件的结构（例如 honk 必须 `include system.dae`、passwall 补丁必须排在厂商
   脚本之后）。
3. **`verify-presets.sh`** —— 构建后按覆盖层**逐个文件**核对 `build_dir` 里的
   `root-*`：存在性、逐字节内容、以及「权限即功能」的期望值
   （`uci-defaults` 不可执行 = 首启不跑；dae/honk 配置不是 0600 = 服务拒绝启动）。
   这条是唯一能兜住"目录名拼错 / 被 .gitignore 吃掉"的守卫 —— 覆盖层合并是静默的，
   出错时固件照样能刷能开机，只是页面空白。

本地没编译也能验 2、3 的逻辑：`scripts/verify-presets.sh --self-test` 会拿覆盖层
造一个假 rootfs 跑完整比对，先确认全通过、再删一个文件确认能判红。

### 防静默降级

ppe-nss 的 config 里有一堆上游不认识的符号：

```
CONFIG_PACKAGE_kmod-nss-wifi-drv
CONFIG_ATH11K_NSS_WIFI
CONFIG_NSS_FIRMWARE_VERSION_12_5
CONFIG_PACKAGE_ppe-help
```

树不对时 `make defconfig` 会**静默丢弃**它们 —— 固件照样编出来、名字一样、
刷进去也能开机，只是 Wi-Fi 还在 CPU 上。所以判据不是「传没传 NSS=1」：

- **整树**：`scripts/prepare.sh` 用 `seeds/qualcommax-nss-wifi.seed` 认树，
  没有就当场失败（移植过的 imm 树里也有 `nss-wifi-drv`，光看它分不清）；
- **移植**：`scripts/integrate-nss-wifi.sh` 按锚点插挂钩，锚点找不到就失败，
  半搬状态过不去；backports 版本对不上也在这里拦。

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

`NSS=是`（即 openwrt + ppe-nss 整树）时还有一层：ppe-nss 是 openwrt main 的
fork，它的 luci / packages feed 是**官方 openwrt** 的，没有 `dae` / `daed` /
`homeproxy` 这些 ImmortalWrt 专属包。
`extra-packages.sh` 会按「feed 里有没有」判断，缺了才从 immortalwrt 稀疏检出补进来
（`place_imm_extra`）—— 判据是 feed 而不是树名，ImmortalWrt 基座直接跳过。

## 目录

```
.github/workflows/
  _build.yml              两条线的共用实现（workflow_call，不手动触发）
  build-immortalwrt.yml   入口 1：immortalwrt 基座（NSS 走移植）
  build-openwrt-nss.yml   入口 2：openwrt 基座 + ppe-nss 整树
  debug-singbox-pkg.yml   单包调试线（只编 sing-box，验配方）
configs/
  common.config           所有变体共用
  qhora_301w.config       机型
  imm.config              immortalwrt 差异层（distro=imm 时挂，含 NSS 线）
  nss.config              整树线的减法层（在 ppe-nss 的 seed 之后挂）
  nss-wifi-imm.config     移植线的符号层（imm + NSS 时挂）
  passwall.config         passwall v1 的符号层（把 v2 那组按掉、换 v1 的）
  none.config             不集成代理（把 passwall2 全家 + Rust 工具链按掉）
  daed.config 等          各代理栈的覆盖层
scripts/
  prepare.sh              唯一入口：参数 → 树选择 + NSS 落法 + config 拼装
  integrate-nss-wifi.sh   移植线：把 ppe-nss 的驱动与补丁搬进上游树
  prepare-build.sh        feeds / .config / 符号校验 / 覆盖文件 / 内核补丁
  resolve-deps.sh         展开插件依赖闭包（small feed 内部递归）
  wanted-packages.sh      当前变体「必须进固件」的包清单 → 产物校验用
  fetch-honk-stage.sh     补齐 honk / doona 的构建元数据（generated-*.mk）
  verify-presets.sh       核对覆盖层是否原样进了镜像（存在 + 内容 + 权限）
  check-no-credentials.sh 出厂预置安全闸：不许有节点凭据 / 订阅链接
  extra-packages.sh       ddns-go / msd_lite / passwall(v1|v2) 组件落位
  test-local.sh           本地回归：在真树上跑 prepare，几组参数一起验
  resolve-*.sh            上游版本解析（每次构建取最新）
files/ files-<stack>/     rootfs 覆盖，按代理栈叠加（files-honk / files-passwall 见「出厂预置」）
packages/                 自带配方（如 sing-box-refind）
patches/kernel/           内核补丁
archive/                  旧的 11 个 workflow、旧 NSS 补丁与脚本
docs/build-lines-archive.md  旧结构文档（各代理栈的配置字段仍可参考）
```

## 本地构建

```sh
git clone --depth 1 https://github.com/immortalwrt/immortalwrt openwrt
OPENWRT_DIR=$PWD/openwrt BUILDER_DIR=$PWD \
  DISTRO=immortalwrt NSS=1 PROXY_STACK=daed bash scripts/prepare.sh
cd openwrt && make -j"$(nproc)"
```

`NSS=1` 在 imm 树上会给 `prepare.sh` 加一道移植（搬驱动 + 补丁进树）；
想走整树就把第一行换成 ppe-nss、`DISTRO=openwrt`：

```sh
git clone --depth 1 -b ppe-nss https://github.com/JuliusBairaktaris/openwrt-ppe-nss openwrt
# 然后 DISTRO=openwrt NSS=1 ...
```

## 改完脚本先本地回归

`scripts/test-local.sh` 在**真实基座树**上跑 `prepare.sh`，覆盖几组关键参数。
prepare 阶段只要 1~3 分钟，而同样的错误丢到 CI 上要等二十几分钟，且日志要
admin 权限才下载得到。

```sh
scripts/test-local.sh ~/work/imm                  # 默认 none + daed
scripts/test-local.sh ~/work/imm none daed honk err   # 指定组合
scripts/test-local.sh ~/work/imm nss-imm          # imm + NSS 移植（树是上游树）
scripts/test-local.sh ~/work/ppe nss              # NSS 线，树必须是 ppe-nss
```

它断言的不是"脚本跑完了"，而是三个真正的失败模式：

- **符号没被静默丢掉** —— defconfig 因为依赖不满足去掉了某个 `=y`
- **依赖真的进了 `.config`** —— 不只是建了软链（`无符号` 直接判失败）
- **NSS 线 `kmod-nss-wifi-drv` 确实在 `.config` 里** —— 否则"选了 NSS 等于没选"

两个反向用例，都是期望**失败且报错点明原因**：`err`（点一个不存在的包）、
`conflict`（`immortalwrt` + `NSS=1`，验证 ① 优先的规则真的挡住了）。

这套脚本是 2026-10-28 那轮改动的产物，它一次抓出三个只在真树上暴露的问题：
`extra-packages.sh` 不认识 `PROXY_STACK=none`、`common.config` 里还留着上一代
NSS 的 21 个符号、反复跑时残留的 small feed 行会让 `feeds install -a` 装下整个 feed。

## 构建后的校验

`.config` 里写 `=y` 只证明「被选中」，不证明「编出来了」。所以有四道独立核对：

1. **符号**：`prepare-build.sh` 把配置文件请求的每个 `=y` 符号与 `make defconfig`
   之后的结果比对，丢一个就失败并打印该符号在 kconfig 里的定义。
2. **产物**：`wanted-packages.sh` 按变体生成包清单，逐个查包文件
   （apk 后端 `.apk` / opkg 后端 `.ipk`）与 rootfs 的 `.manifest`。
3. **内核前提**：`daed` / `dae` / `honk` 的 eBPF 程序靠 CO-RE 读内核结构，必须查
   `vmlinux` 里真的有 `.BTF` 段 —— `.config` 开了 `DEBUG_INFO` 也可能被
   `KERNEL_DEBUG_INFO_REDUCED` 挡掉。
4. **出厂预置**：`verify-presets.sh` 把覆盖层里每个文件拿去拼镜像前的 `root-*` 核对
   （存在 + 内容一致 + 权限），见上面「出厂预置」一节。

## 归档

`archive/` 下的东西不再参与构建，只作回溯：

- `archive/workflows/` —— 重构前的 11 个 workflow（源 × 代理栈 × sing-box 模式）
- `archive/patches/immortalwrt-nss/` —— 把 openwrt main 的 NSS 改动打到 imm 上的补丁集
- `archive/scripts/apply-nss-patches.sh` —— 应用上述补丁的脚本
- `archive/configs/imm-nss.config` —— 那条线的 config 覆盖层

它们退出历史的原因：NSS 已经不需要「往 imm 上打补丁」这条路了（见上文）。
