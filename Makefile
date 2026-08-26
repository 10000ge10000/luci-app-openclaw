# luci-app-openclaw — OpenWrt package Makefile
# 兼容两种集成方式:
#   1. 作为 feeds 源: echo "src-git openclaw ..." >> feeds.conf.default
#   2. 直接放入 package/ 目录: git clone ... package/luci-app-openclaw

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-openclaw
PKG_VERSION:=$(strip $(shell cat $(CURDIR)/VERSION 2>/dev/null || echo "1.0.0"))
PKG_RELEASE:=1

PKG_MAINTAINER:=10000ge10000 <10000ge10000@users.noreply.github.com>
PKG_LICENSE:=GPL-3.0

LUCI_TITLE:=OpenClaw AI 网关 LuCI 管理插件
LUCI_DEPENDS:=+luci-compat +luci-base +curl +openssl-util +script-utils +tar +libstdcpp6
LUCI_PKGARCH:=all

# 始终使用 package.mk 并显式定义 Package/...。
#
# 历史实现在检测到 feeds/luci/luci.mk 时改走 luci.mk 分支，且不定义
# Package/...，依赖 luci.mk 由 LUCI_* 变量自动生成。该机制在 OpenWrt 25.x
# 的 feeds 布局下失效，表现为 (issue #60):
#   Ignoring feed 'openclaw' - index missing
# 且 menuconfig 的 LuCI → Applications 下找不到本插件。
#
# 显式声明对两种集成方式都有效，不再依赖 luci.mk 的隐式行为:
#   1. 作为 feeds 源: echo "src-git openclaw ..." >> feeds.conf.default
#   2. 直接放入 package/ 目录
include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE)
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  OpenClaw AI Gateway 的 LuCI 管理插件。
  支持 12+ AI 模型提供商和 Telegram/Discord 等多种消息渠道。
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/openclaw
endef

# 安装清单必须与 scripts/build_ipk.sh / scripts/build_run.sh 保持一致。
# 特别是 /usr/share/openclaw 下的 oc-config-interactive.js 与 oc-menu-engine.js:
# 缺失时 oc-config.sh 的 can_use_interactive() 会静默回落到功能较少的传统
# 数字菜单，用户只会觉得"界面和教程不一样"，不会看到任何报错。
# tests/test_packaging_parity.sh 会校验三条打包路径的清单一致性。
define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/openclaw $(1)/etc/config/openclaw
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99-openclaw $(1)/etc/uci-defaults/99-openclaw
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/openclaw $(1)/etc/init.d/openclaw
	$(INSTALL_DIR) $(1)/etc/profile.d
	$(INSTALL_DATA) ./root/etc/profile.d/openclaw.sh $(1)/etc/profile.d/openclaw.sh
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/openclaw-env $(1)/usr/bin/openclaw-env
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./root/usr/libexec/openclaw-paths.sh $(1)/usr/libexec/openclaw-paths.sh
	$(INSTALL_BIN) ./root/usr/libexec/openclaw-node.sh $(1)/usr/libexec/openclaw-node.sh
	$(INSTALL_BIN) ./root/usr/libexec/openclaw-permissions.sh $(1)/usr/libexec/openclaw-permissions.sh
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/openclaw.lua $(1)/usr/lib/lua/luci/controller/openclaw.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/openclaw
	$(INSTALL_DATA) ./luasrc/openclaw/paths.lua $(1)/usr/lib/lua/openclaw/paths.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/openclaw
	$(INSTALL_DATA) ./luasrc/model/cbi/openclaw/basic.lua $(1)/usr/lib/lua/luci/model/cbi/openclaw/basic.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/openclaw
	$(INSTALL_DATA) ./luasrc/view/openclaw/status.htm $(1)/usr/lib/lua/luci/view/openclaw/status.htm
	$(INSTALL_DATA) ./luasrc/view/openclaw/advanced.htm $(1)/usr/lib/lua/luci/view/openclaw/advanced.htm
	$(INSTALL_DATA) ./luasrc/view/openclaw/console.htm $(1)/usr/lib/lua/luci/view/openclaw/console.htm
	$(INSTALL_DATA) ./luasrc/view/openclaw/wechat.htm $(1)/usr/lib/lua/luci/view/openclaw/wechat.htm
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-openclaw.json $(1)/usr/share/rpcd/acl.d/luci-app-openclaw.json
	$(INSTALL_DIR) $(1)/usr/share/openclaw
	$(INSTALL_DATA) ./VERSION $(1)/usr/share/openclaw/VERSION
	$(INSTALL_BIN) ./root/usr/share/openclaw/oc-config.sh $(1)/usr/share/openclaw/oc-config.sh
	$(INSTALL_DATA) ./root/usr/share/openclaw/web-pty.js $(1)/usr/share/openclaw/web-pty.js
	$(INSTALL_BIN) ./root/usr/share/openclaw/oc-config-interactive.js $(1)/usr/share/openclaw/oc-config-interactive.js
	$(INSTALL_DATA) ./root/usr/share/openclaw/oc-menu-engine.js $(1)/usr/share/openclaw/oc-menu-engine.js
	$(INSTALL_DIR) $(1)/usr/share/openclaw/ui
	$(CP) ./root/usr/share/openclaw/ui/* $(1)/usr/share/openclaw/ui/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	( . /etc/uci-defaults/99-openclaw ) && rm -f /etc/uci-defaults/99-openclaw
	OPENCLAW_INSTALL_BASE="$$(uci -q get openclaw.main.install_path 2>/dev/null || echo /opt)"
	if [ -r /usr/libexec/openclaw-paths.sh ]; then
		. /usr/libexec/openclaw-paths.sh
		oc_load_paths "$${OPENCLAW_INSTALL_BASE}" 2>/dev/null || true
	else
		OPENCLAW_INSTALL_BASE="$${OPENCLAW_INSTALL_BASE%/}"
		OC_DATA="$${OPENCLAW_INSTALL_BASE}/openclaw/data"
	fi
	if [ -n "$${OC_DATA:-}" ] && [ -d "$${OC_DATA}/.openclaw" ] && [ -x /usr/libexec/openclaw-permissions.sh ]; then
		/usr/libexec/openclaw-permissions.sh fix-state "$${OC_DATA}/.openclaw" >/dev/null 2>&1 || true
	fi
	if [ "$$(uci -q get openclaw.main.enabled 2>/dev/null || echo 0)" = "1" ] && [ -x /etc/init.d/openclaw ]; then
		/etc/init.d/openclaw enable >/dev/null 2>&1 || true
		/etc/init.d/openclaw start >/dev/null 2>&1 || true
	fi
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
	exit 0
}
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
}
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
