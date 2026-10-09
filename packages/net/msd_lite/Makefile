#
# msd_lite —— 本仓库自带的包配方，PKG_SOURCE 直接指向上游源码仓库
#
# ══ 为什么必须是 git 源，绝不能换成 codeload 压缩包 ═══════════════
# msd_lite 依赖一个 **git 子模块** src/liblcb
# （.gitmodules 里写着 https://github.com/rozhuk-im/liblcb.git），
# 而 CMakeLists.txt 第 245 行是**无条件**的：
#     include(src/liblcb/CMakeLists.txt)
#
# GitHub 的 /archive/<sha>.tar.gz（也就是 codeload 压缩包）**不包含子模块内容**：
# 解出来 src/liblcb/ 是个空目录，cmake 直接报
#     include could not find requested file: src/liblcb/CMakeLists.txt
# OpenWrt 自己的 scripts/dl_github_archive.py 第 223 行也写着这一点。
#
# 用 PKG_SOURCE_PROTO:=git 时 include/download.mk 的行为（已逐行核对）：
#   · 第 26 行 dl_method_git：URL 匹配 github.com/* → 走 github_archive
#   · github_archive（第 218 行）调用 dl_github_archive.py
#   · 该脚本 __init__ 里立刻 _init_hasher()，hash 不是 64/32 字符就直接抛错
#     "Requires sha256sum for verification"（第 305-313 行）；
#     即使 hash 合法，它检测到子模块也会抛
#     "Fetching submodules is not yet supported"（第 247、270 行）
#   · github_archive 的结尾是 `... || ( $(call DownloadMethod/rawgit) )`
#   · 于是回落到 rawgit —— 它 clone 之后会执行
#     `git submodule update --init --recursive`（download.mk 第 255 行），
#     子模块内容这才进得来
# 这就是 ImmortalWrt 那份配方（同样是 git 源）能编过、
# 而"自己下 codeload 压缩包"会编不过的真正原因 —— 实测被 run 8 挂掉验证过。
#
# PKG_MIRROR_HASH 写 skip 是**故意**的：让 dl_github_archive.py 在初始化那步就
# 失败，从而不依赖"子模块检测是否命中"，稳定走 rawgit。download.mk 第 182 行
# 明确允许 MIRROR_HASH 取 skip。
#
# ══ PKG_VERSION / PKG_BUILD_DIR 都不用自己写 ═══════════════════════
# download.mk 第 10-16 行：PKG_VERSION **未定义**时会自动推导
#     PKG_VERSION := $(subst -,.,$(PKG_SOURCE_DATE))~$(version_abbrev ...)
#                   → 2026.07.20~fa68e131
#     PKG_SOURCE_SUBDIR ?= $(PKG_NAME)-$(PKG_VERSION)      → 克隆目录名
#     PKG_SOURCE        ?= $(PKG_SOURCE_SUBDIR).tar.zst    → dl/ 里的文件名
#     PKG_BUILD_DIR     ?= $(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
# 四者自动对齐，所以既不需要显式 PKG_BUILD_DIR，也不会再有
# "压缩包顶层目录和 PKG_BUILD_DIR 对不上 → 找不到源码" 这类问题。
#
# 版本号形如 `2026.07.20~fa68e131` 是 OpenWrt 惯例：apk 要求版本号以数字开头，
# 裸 sha（fa68e13… 以字母开头）会被判非法。
#
# ── 为什么用 commit sha 而不是版本号 ────────────────────────────
# rozhuk-im/msd_lite 上游**一个 tag 都没有**（实测 /repos/rozhuk-im/msd_lite/tags
# 返回 0 条），所以只能拿 master 的 commit sha 当 ref，根本没得选。
#
# ── files/ 的来源 ───────────────────────────────────────────────
# files/ 下三个文件取自 ImmortalWrt（GPL-2.0）。它们只负责 procd 拉起和
# 配置模板的替换（把 @logLevel@ 之类的占位符换成 UCI 值），与 msd_lite 本身
# 的版本无关；如果 ImmortalWrt 之后改了它们，需要手工同步。
#
# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=msd_lite
PKG_RELEASE:=1

# ↓ 这两个都由 scripts/resolve-versions.sh 在构建时注入；此处为兜底值
#   PKG_VERSION 和 PKG_BUILD_DIR 都**不要**写：download.mk 会用上面这两个自动推导
PKG_SOURCE_DATE:=2026-07-20
PKG_SOURCE_VERSION:=fa68e131343fb58c67ad77b2d26f2cb7c49a2c95

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/rozhuk-im/msd_lite.git
# ↓ 故意写成 skip：让 github_archive 那条路在初始化校验 hash 时就失败，
#   从而**确定性**地回落到会执行 `git submodule update` 的 rawgit（见文件头）
PKG_MIRROR_HASH:=skip

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
