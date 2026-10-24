# SPDX-License-Identifier: GPL-2.0-only
#
# daed —— **预编译二进制版**（由 scripts/resolve-daed-version.sh 在构建时渲染）
#
# 为什么不用 feed 里那份源码配方：
#   1) feed 的 daed 还是 1.27.0，我们要 2.1.x；
#   2) 2.x 起上游把仓库拆成了 pnpm workspace + wing 子模块，**不再发布 web.zip**
#      （1.27 那份配方靠它把前端塞进 wing/webrender/web 再 go:embed）；
#      而 OpenWrt 的构建树里没有 node/pnpm，编不出前端 ⇒ 源码路线在本仓库走不通。
#   3) 上游 release 自带 daed-linux-arm64.zip：aarch64 静态链接 stripped 二进制
#      （内含已编译的前端），musl 固件可直接跑，和 dae 的预编译包同一思路。
#
# 所以这里只做三件事：取官方二进制 → 装成 /usr/bin/daed → 复用 feed 的
# /etc/config/daed 与 /etc/init.d/daed（$(CURDIR)/files/ 仍是 feed 那份）。
#
# 版本与 hash 由 scripts/resolve-daed-version.sh 在构建时写入下面两个字段；
# 直接改 feeds 里那份没用 —— feeds update 会覆盖回去。

include $(TOPDIR)/rules.mk

PKG_NAME:=daed
PKG_VERSION:=@VER@
PKG_RELEASE:=1

# 压缩包里没有 LICENSE 文件（只有二进制 + 图标 + geo 数据），所以不写 PKG_LICENSE_FILES。
PKG_LICENSE:=AGPL-3.0-only
PKG_MAINTAINER:=daeuniverse

# 用标准下载流程（PKG_SOURCE），不用自定义 Download/ 块：
#   · PKG_SOURCE 是 $(STAMP_PREPARED) 的依赖，download 目标会自动带上它；
#     自定义 Download/ 只注册规则、不挂依赖，prepare 时 dl/ 里可能还是空的。
#   · dl/ 里存成 daed-bin-<ver>.zip（版本化），避免换版本时与旧缓存撞名；
#     远端资产名用 PKG_SOURCE_URL_FILE 指定。
PKG_SOURCE:=daed-bin-$(PKG_VERSION).zip
PKG_SOURCE_URL:=https://github.com/daeuniverse/daed/releases/download/v$(PKG_VERSION)
PKG_SOURCE_URL_FILE:=daed-linux-arm64.zip
PKG_HASH:=@HASH@

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-bin-$(PKG_VERSION)

# ⚠️ 这行不能少：package.mk 才定义 BuildPackage / build 规则。
#    少了它 $(call BuildPackage,...) 会静默展开成空 —— 包不报错、也不存在，
#    make defconfig 只是"丢弃符号"（2026-10-25 的 run 就栽在这）。
include $(INCLUDE_DIR)/package.mk

define Package/daed/Default
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  URL:=https://github.com/daeuniverse/daed
endef

define Package/daed
  $(call Package/daed/Default)
  TITLE:=A Modern Dashboard For dae
  # 二进制里已经带了 dae 核心与前端；这里只要运行时内核前提。
  DEPENDS:=+ca-bundle +kmod-sched-core +kmod-sched-bpf \
    +kmod-xdp-sockets-diag +kmod-veth
endef

define Package/daed/description
  daed is a modern dashboard for dae (dae-wing + embedded frontend).
  This package ships the **official prebuilt aarch64 binary**; see the header.
endef

define Package/daed/conffiles
/etc/daed/wing.db
/etc/config/daed
endef

define Package/daed-geoip
  $(call Package/daed/Default)
  TITLE:=geoip for daed
  DEPENDS:=+daed +v2ray-geoip
  PKGARCH:=all
endef

define Package/daed-geosite
  $(call Package/daed/Default)
  TITLE:=geosite for daed
  DEPENDS:=+daed +v2ray-geosite
  PKGARCH:=all
endef

# zip 里多一层 daed-linux-arm64/，默认解包不会 strip，所以自己解到 PKG_BUILD_DIR。
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	unzip -q -o $(DL_DIR)/$(PKG_SOURCE) -d $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/daed/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/daed-linux-arm64/daed-linux-arm64 $(1)/usr/bin/daed

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/daed.config $(1)/etc/config/daed

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/daed.init $(1)/etc/init.d/daed
endef

define Package/daed-geoip/install
	$(INSTALL_DIR) $(1)/usr/share/daed
	$(LN) ../v2ray/geoip.dat $(1)/usr/share/daed/geoip.dat
endef

define Package/daed-geosite/install
	$(INSTALL_DIR) $(1)/usr/share/daed
	$(LN) ../v2ray/geosite.dat $(1)/usr/share/daed/geosite.dat
endef

$(eval $(call BuildPackage,daed))
$(eval $(call BuildPackage,daed-geoip))
$(eval $(call BuildPackage,daed-geosite))
