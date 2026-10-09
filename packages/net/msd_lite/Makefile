#
# msd_lite —— 本仓库自带的包配方，PKG_SOURCE 直接指向上游源码仓库
#
# ── 为什么用 commit sha 而不是版本号 ────────────────────────────
# rozhuk-im/msd_lite 上游**一个 tag 都没有**（实测 /repos/rozhuk-im/msd_lite/tags
# 返回 0 条），所以只能拿 commit sha 当 ref，根本没得选。
# sha / 日期 / hash 都由 scripts/resolve-versions.sh 在构建时注入，
# 下面写的是兜底值。
#
# ── 与 ddns-go 那份的唯一区别：PKG_BUILD_DIR 必须显式指定 ────────
# codeload 用 sha 作 ref 时，压缩包顶层目录是 `msd_lite-<完整 sha>`；
# 而 PKG_BUILD_DIR 的默认值是 `msd_lite-<PKG_VERSION>`。PKG_VERSION 为了能读
# 写成了 2026.07.20~fa68e13，两者对不上 —— include/unpack.mk 是
# tar -C $(PKG_BUILD_DIR)/..，解到 BUILD_DIR 下靠目录名对上，对不上就找不到源码。
# 所以把 PKG_BUILD_DIR 显式改成 sha 形式。
#
# 必须在 include $(INCLUDE_DIR)/package.mk **之前**赋值：那里是
# PKG_BUILD_DIR ?= ...，先赋值者生效。
#
# 顺带一个好处：版本标签（日期）变了也不会让 build_dir 跟着变，
# 同一个 commit 重复构建能命中已有的 build_dir。
#
# ── PKG_VERSION 为什么是「日期~短sha」而不是裸 sha ──────────────
# apk 的版本号要求以数字开头。裸 sha 以字母开头（比如 fa68e13…）会被判成
# 非法版本。`2026.07.20~fa68e13` 这个形状是 OpenWrt 自己的惯例
# （见 include/download.mk 第 13 行），ImmortalWrt 对同一个包也是这么写的。
#
# ── files/ 的来源 ───────────────────────────────────────────────
# files/ 下三个文件取自 ImmortalWrt（GPL-2.0）。它们只负责 procd 拉起和
# 配置模板的替换（把 @logLevel@ 之类的占位符换成 UCI 值），与 msd_lite 本身
# 的版本无关；如果 ImmortalWrt 之后改了它们，需要手工同步。
#
# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=msd_lite
# ↓ 构建时注入；此处为兜底值
PKG_VERSION:=2026.07.20~fa68e13
PKG_RELEASE:=1

# ↓ 构建时注入；此处为兜底值。上游 ref（commit sha）
MSD_LITE_REF:=fa68e131343fb58c67ad77b2d26f2cb7c49a2c95

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/rozhuk-im/msd_lite/tar.gz/$(MSD_LITE_REF)?
# ↓ 构建时注入（与上面的 MSD_LITE_REF 严格配对）；此处为兜底值
PKG_HASH:=3452208a162ac3640745353918765fa26e7ef1c4f2d1c82683945344bed9f39d

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(MSD_LITE_REF)

PKG_LICENSE:=BSD-2-Clause
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/msd_lite
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Program for IP TV streaming on the network via HTTP
  URL:=https://github.com/rozhuk-im/msd_lite
endef

define Package/msd_lite/description
  msd_lite - Multi stream daemon lite. The lightweight version of
  Multi Stream daemon (msd) Program for organizing IP TV streaming
  on the network via HTTP.
endef

define Package/msd_lite/conffiles
/etc/config/msd_lite
endef

CMAKE_OPTIONS+= -DCONFDIR=../etc/msd_lite

define Package/msd_lite/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/msd_lite $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/etc/msd_lite
	$(CP) $(CURDIR)/files/msd_lite.sample $(1)/etc/msd_lite/msd_lite.conf.sample
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/msd_lite.config $(1)/etc/config/msd_lite
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/msd_lite.init $(1)/etc/init.d/msd_lite
endef

$(eval $(call BuildPackage,msd_lite))
