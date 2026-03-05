#!/bin/sh
# ============================================================================
# 本地构建 .ipk 包 (无需 OpenWrt SDK)
# 用法: sh scripts/build_ipk.sh [output_dir]
# ============================================================================
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PKG_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_DIR="${1:-$PKG_DIR/dist}"
# 确保 OUT_DIR 是绝对路径
case "$OUT_DIR" in
	/*) ;;
	*) OUT_DIR="$PKG_DIR/$OUT_DIR" ;;
esac
mkdir -p "$OUT_DIR"
PKG_NAME="luci-app-openclaw"
PKG_VERSION=$(cat "$PKG_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "1.0.0")
PKG_RELEASE="1"

echo "=== 构建 ${PKG_NAME} .ipk 包 ==="

STAGING=$(mktemp -d)
trap "rm -rf '$STAGING'" EXIT

# ── 构建 data.tar.gz ──
DATA_DIR="$STAGING/data"
mkdir -p "$DATA_DIR"

# UCI config
mkdir -p "$DATA_DIR/etc/config"
cp "$PKG_DIR/root/etc/config/openclaw" "$DATA_DIR/etc/config/"

# UCI defaults
mkdir -p "$DATA_DIR/etc/uci-defaults"
cp "$PKG_DIR/root/etc/uci-defaults/99-openclaw" "$DATA_DIR/etc/uci-defaults/"
chmod +x "$DATA_DIR/etc/uci-defaults/99-openclaw"

# init.d
mkdir -p "$DATA_DIR/etc/init.d"
cp "$PKG_DIR/root/etc/init.d/openclaw" "$DATA_DIR/etc/init.d/"
chmod +x "$DATA_DIR/etc/init.d/openclaw"

# bin
mkdir -p "$DATA_DIR/usr/bin"
cp "$PKG_DIR/root/usr/bin/openclaw-env" "$DATA_DIR/usr/bin/"
chmod +x "$DATA_DIR/usr/bin/openclaw-env"

# LuCI controller
mkdir -p "$DATA_DIR/usr/lib/lua/luci/controller"
cp "$PKG_DIR/luasrc/controller/openclaw.lua" "$DATA_DIR/usr/lib/lua/luci/controller/"

# LuCI CBI
mkdir -p "$DATA_DIR/usr/lib/lua/luci/model/cbi/openclaw"
cp "$PKG_DIR/luasrc/model/cbi/openclaw/"*.lua "$DATA_DIR/usr/lib/lua/luci/model/cbi/openclaw/"

# LuCI views
mkdir -p "$DATA_DIR/usr/lib/lua/luci/view/openclaw"
cp "$PKG_DIR/luasrc/view/openclaw/"*.htm "$DATA_DIR/usr/lib/lua/luci/view/openclaw/"

# oc-config assets
mkdir -p "$DATA_DIR/usr/share/openclaw"
cp "$PKG_DIR/VERSION" "$DATA_DIR/usr/share/openclaw/VERSION"
cp "$PKG_DIR/root/usr/share/openclaw/oc-config.sh" "$DATA_DIR/usr/share/openclaw/"
chmod +x "$DATA_DIR/usr/share/openclaw/oc-config.sh"
cp "$PKG_DIR/root/usr/share/openclaw/web-pty.js" "$DATA_DIR/usr/share/openclaw/"

# Web PTY UI
cp -r "$PKG_DIR/root/usr/share/openclaw/ui" "$DATA_DIR/usr/share/openclaw/"

# i18n (po2lmo 可选)
mkdir -p "$DATA_DIR/usr/lib/lua/luci/i18n"
if command -v po2lmo >/dev/null 2>&1 && [ -f "$PKG_DIR/po/zh-cn/openclaw.po" ]; then
	po2lmo "$PKG_DIR/po/zh-cn/openclaw.po" "$DATA_DIR/usr/lib/lua/luci/i18n/openclaw.zh-cn.lmo" 2>/dev/null || true
fi

# 计算安装大小
INSTALLED_SIZE=$(du -sk "$DATA_DIR" | awk '{print $1}')

(cd "$DATA_DIR" && tar czf "$STAGING/data.tar.gz" .)

# ── 构建 control.tar.gz ──
CTRL_DIR="$STAGING/control"
mkdir -p "$CTRL_DIR"

cat > "$CTRL_DIR/control" << EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}-${PKG_RELEASE}
Depends: luci-compat, luci-base, curl, openssl-util, script-utils, tar
Source: https://github.com/10000ge10000/luci-app-openclaw
SourceName: ${PKG_NAME}
License: GPL-3.0
Section: luci
SourceDateEpoch: $(date +%s)
Maintainer: 10000ge10000 <10000ge10000@users.noreply.github.com>
Architecture: all
Installed-Size: ${INSTALLED_SIZE}
Description: OpenClaw AI 网关 LuCI 管理插件
EOF

cat > "$CTRL_DIR/postinst" << 'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	( . /etc/uci-defaults/99-openclaw ) && rm -f /etc/uci-defaults/99-openclaw
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
	exit 0
}
EOF
chmod +x "$CTRL_DIR/postinst"

cat > "$CTRL_DIR/postrm" << 'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
}
EOF
chmod +x "$CTRL_DIR/postrm"

cat > "$CTRL_DIR/conffiles" << 'EOF'
/etc/config/openclaw
EOF

(cd "$CTRL_DIR" && tar czf "$STAGING/control.tar.gz" .)

# ── 组装 .ipk (ar 格式) ──
mkdir -p "$OUT_DIR"
IPK_FILE="$OUT_DIR/${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_all.ipk"

echo "2.0" > "$STAGING/debian-binary"

# 清理旧文件
rm -f "$IPK_FILE"

# 组装 .ipk — OpenWrt opkg 使用 tar.gz 格式 (非 Debian 的 ar 格式)
(cd "$STAGING" && tar czf "$IPK_FILE" debian-binary control.tar.gz data.tar.gz)

IPK_SIZE=$(wc -c < "$IPK_FILE" | tr -d ' ')
echo ""
echo "=== 构建完成 ==="
echo "输出文件: $IPK_FILE"
echo "文件大小: ${IPK_SIZE} bytes"
echo "安装大小: ${INSTALLED_SIZE} KB"
echo ""
echo "安装方法: opkg install ${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_all.ipk"
