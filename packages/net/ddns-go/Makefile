#
# ddns-go —— 本仓库自带的包配方，PKG_SOURCE 直接指向上游源码仓库
#
# ── 为什么不照抄 ImmortalWrt 那份 ─────────────────────────────────
# OpenWrt 官方 packages feed 里没有 ddns-go（实测 net/ddns-go 是 404）。
# ImmortalWrt 有，但它的配方把版本**写死**了：PKG_VERSION:=6.17.6 配一个
# 对应的 PKG_HASH。上游发了新版也要等 ImmortalWrt 维护者 bump 才跟得上 ——
# 写这份配方时上游已经到 6.17.7 了。
#
# 这里改成直接引用上游源码：版本号和 hash 由 scripts/resolve-versions.sh
# 在构建时解析后注入。下面写的是**兜底值**，解析失败（GitHub 抖动等）时
# 用它们照常构建，不至于因为一个 API 不可达就废掉整轮两小时的编译。
#
# ── 三个不能改坏的地方 ──────────────────────────────────────────
# ① PKG_SOURCE_URL 末尾那个 `?`
#    include/download.mk 交给 download.pl 的 URL 是「PKG_SOURCE_URL 去掉 ?」
#    再接上「/PKG_SOURCE」，也就是：
#      https://codeload.github.com/jeessy2/ddns-go/tar.gz/v6.17.7?/ddns-go-6.17.7.tar.gz
#    末尾的 ? 把后一段变成 codeload 会忽略的 query。少了它，请求会变成
#      https://codeload.github.com/jeessy2/ddns-go/tar.gz/ddns-go-6.17.7.tar.gz
#    直接 404。已实测（两种写法各拉一次，比对 sha256）。
# ② 压缩包顶层目录必须等于 $(PKG_NAME)-$(PKG_VERSION)
#    include/unpack.mk 用的是 tar -C $(PKG_BUILD_DIR)/..，即解到 BUILD_DIR 下，
#    靠目录名对上 PKG_BUILD_DIR。codeload 对 tag `v6.17.7` 生成的顶层目录是
#    `ddns-go-6.17.7`（自动去掉前缀 v），正好吻合。
# ③ GO_PKG 结尾的 /v6 是 Go 的语义化导入路径，不是可以随手删的版本号
#    上游哪天升到 v7，这里必须跟着变成 .../v7，否则 Go 会报"模块路径不匹配"。
#    resolve-versions.sh 会读压缩包里的 go.mod 自动注入，正常不用手改。
#
# ── files/ 的来源 ───────────────────────────────────────────────
# files/ddns-go.init 与 files/ddns-go.conf 取自 ImmortalWrt（同为 GPL-2.0）。
# 它们只负责 UCI 解析和 procd 拉起，与 ddns-go 本身的版本无关；
# 如果 ImmortalWrt 之后改了这两个文件，需要手工同步过来。
#
# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=ddns-go
# ↓ 构建时注入；此处为兜底值
PKG_VERSION:=6.17.7
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/jeessy2/ddns-go/tar.gz/v$(PKG_VERSION)?
# ↓ 构建时注入（与上面的 PKG_VERSION 严格配对）；此处为兜底值
PKG_HASH:=f7001004e092d9641aad5a94158e0b4cae4a53a7f5c7d96d5c6af3d246c56fcc

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

# ↓ 构建时注入（取自上游 go.mod 的 module 行）；此处为兜底值
GO_PKG:=github.com/jeessy2/ddns-go/v6
GO_PKG_LDFLAGS_X:=main.version=$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk
include ../../lang/golang/golang-package.mk

define Package/ddns-go
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=IP Addresses and Names
  TITLE:=Simple and easy-to-use Dynamic DNS client
  URL:=https://github.com/jeessy2/ddns-go
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle
  USERID:=ddns-go:ddns-go
endef

define Package/ddns-go/description
  A simple and easy-to-use Dynamic DNS client with IPv6 support.
  Supported backend:
    - Alidns
    - Baidu Cloud
    - CloudFlare
    - DnsPod
    - GoDaddy Domains
    - Google Domains
    - Huawei Cloud
    - Porkbun
    - Custom callback
endef

define Package/ddns-go/conffiles
/etc/config/ddns-go
/etc/ddns-go/config.yaml
endef

define Package/ddns-go/install
	$(call GoPackage/Package/Install/Bin,$(1))

	$(INSTALL_DIR) $(1)/etc/config/
	$(INSTALL_CONF) $(CURDIR)/files/ddns-go.conf $(1)/etc/config/ddns-go
	$(INSTALL_DIR) $(1)/etc/init.d/
	$(INSTALL_BIN) $(CURDIR)/files/ddns-go.init $(1)/etc/init.d/ddns-go
endef

$(eval $(call GoBinPackage,ddns-go))
$(eval $(call BuildPackage,ddns-go))
