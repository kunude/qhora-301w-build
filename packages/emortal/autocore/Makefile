#
# autocore —— ImmortalWrt「首页显示 CPU 温度」背后真正的那个包。
#
# 来源：immortalwrt/immortalwrt 主源码树的 package/emortal/autocore
# （不在任何 feed 里，是主源码树自带的；从 Lean 的 lede 继承下来）。
# 抄进本仓库是因为它提供官方 feed 完全没有的两样东西：
#   files/tempinfo   被 ubus 方法 luci.getTempInfo 执行，输出 "CPU: 52.3°C, WiFi: 61.0°C"
#   files/cpuinfo    被 ubus 方法 luci.getCPUInfo  执行，输出 CPU 型号
# 外加一份 ACL（files/luci-mod-status-autocore.json），把这两个方法授权给 LuCI 前端。
#
# 注意：**只装这个包并不会让首页出现温度**。上面那两个 ubus 方法本身是
# ImmortalWrt 往 luci-base 的 ucode 插件里加的补丁，官方 openwrt/luci 没有；
# 本仓库的首页温度走自写的 files/www/.../status/include/95_qhora_hw.js 直读
# sysfs，不依赖 ubus。这里编入 autocore 是为了拿到与 ImmortalWrt 同源的
# /sbin/tempinfo、/sbin/cpuinfo（命令行可直接执行），并为将来接那套 ubus
# 前端留出可能性。
#
# 纯脚本包：Build/Compile 为空、没有 PKG_SOURCE，既不下载也不编译任何东西。
# 本仓库这份与上游 master 逐字节一致（2026-10-10 取的）；上游更新时按需
# 重新取 files/ 下那几个文件覆盖即可。
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2020 Lean <coolsnowwolf@gmail.com>
# Copyright (C) 2021-2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

PKG_NAME:=autocore
PKG_FLAGS:=nonshared
PKG_RELEASE:=42

PKG_CONFIG_DEPENDS:= \
	CONFIG_TARGET_bcm27xx \
	CONFIG_TARGET_bcm53xx \
	CONFIG_TARGET_x86

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/target.mk

define Package/autocore
  TITLE:=auto core loadbalance script.
  DEPENDS:=@(aarch64||arm||i386||i686||x86_64) \
    +TARGET_bcm27xx:bcm27xx-utils \
    +TARGET_bcm53xx:nvram \
    +TARGET_x86:ethtool \
    +TARGET_x86:lm-sensors
endef

define Build/Compile
endef

define Package/autocore/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/60-autocore-reload-rpcd $(1)/etc/uci-defaults/

ifneq ($(filter i386 i686 x86_64, $(ARCH)),)
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/autocore $(1)/etc/init.d/
endif

	$(INSTALL_DIR) $(1)/sbin
	$(INSTALL_BIN) ./files/cpuinfo $(1)/sbin/
ifneq ($(filter ipq% mediatek% qualcommax%, $(TARGETID)),)
	$(INSTALL_BIN) ./files/tempinfo $(1)/sbin/
endif

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(CP) ./files/luci-mod-status-autocore.json $(1)/usr/share/rpcd/acl.d/
endef

$(eval $(call BuildPackage,autocore))
