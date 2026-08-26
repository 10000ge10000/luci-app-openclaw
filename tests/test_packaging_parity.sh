#!/bin/sh
# 打包清单一致性契约。
#
# 背景: 本项目有三条打包路径，各自独立维护安装清单:
#   1. Makefile              — feeds / OpenWrt SDK 编译 (逐个 INSTALL_* 枚举)
#   2. scripts/build_ipk.sh  — 本地 .ipk 构建 (大量使用 cp *.js / *.sh 通配)
#   3. scripts/build_run.sh  — .run 自解压包构建 (同上)
#
# 实测漂移: Makefile 只安装 oc-config.sh + web-pty.js，漏掉
# oc-config-interactive.js 与 oc-menu-engine.js。Release 的 .ipk/.run 正常，
# 但走 feeds/SDK 编译装出来的包缺这两个文件，此时 oc-config.sh 的
# can_use_interactive() 因 [ -f "$OC_INTERACTIVE" ] 失败而静默回落到传统菜单
# —— 用户看不到任何报错，只会觉得界面和教程不一致。
#
# 本测试对每个应打包的源文件，校验三条路径都会安装它。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
MK="$REPO_ROOT/Makefile"
IPK="$REPO_ROOT/scripts/build_ipk.sh"
RUN="$REPO_ROOT/scripts/build_run.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

for f in "$MK" "$IPK" "$RUN"; do
	[ -f "$f" ] || fail "missing $f"
done

# 判断某条打包脚本是否会安装指定源文件。
# 命中方式二选一:
#   - 显式提到文件名
#   - 存在覆盖其目录 + 扩展名的通配 (如 root/usr/share/openclaw/"*.js)
covered() {
	_file="$1"   # 相对仓库根的路径, 如 root/usr/share/openclaw/oc-menu-engine.js
	_script="$2"

	_base=$(basename "$_file")
	_dir=$(dirname "$_file")
	_ext=$(printf '%s' "$_base" | sed -n 's/.*\.\([A-Za-z0-9]\+\)$/\1/p')

	# 显式文件名
	if grep -Fq "$_base" "$_script"; then
		return 0
	fi
	# 目录通配: 匹配形如 <dir>/"*.ext 或 <dir>/*.ext
	if [ -n "$_ext" ] && grep -Fq "${_dir}/" "$_script" && grep -Fq "*.${_ext}" "$_script"; then
		# 进一步确认同一行里既有该目录又有该扩展通配
		if grep -F "${_dir}/" "$_script" | grep -Fq "*.${_ext}"; then
			return 0
		fi
	fi
	return 1
}

# ── 应打包的源文件集合 ──
# 只列运行时必需的文件; tests/ 与 docs/ 由 .gitattributes export-ignore 排除。
FILES=""
add_files() {
	for p in "$@"; do
		[ -e "$REPO_ROOT/$p" ] || continue
		FILES="$FILES $p"
	done
}

add_files root/etc/config/openclaw
add_files root/etc/uci-defaults/99-openclaw
add_files root/etc/init.d/openclaw
add_files root/etc/profile.d/openclaw.sh
add_files root/usr/bin/openclaw-env
for f in "$REPO_ROOT"/root/usr/libexec/*.sh; do
	[ -f "$f" ] && add_files "root/usr/libexec/$(basename "$f")"
done
add_files luasrc/controller/openclaw.lua
for f in "$REPO_ROOT"/luasrc/openclaw/*.lua; do
	[ -f "$f" ] && add_files "luasrc/openclaw/$(basename "$f")"
done
for f in "$REPO_ROOT"/luasrc/model/cbi/openclaw/*.lua; do
	[ -f "$f" ] && add_files "luasrc/model/cbi/openclaw/$(basename "$f")"
done
for f in "$REPO_ROOT"/luasrc/view/openclaw/*.htm; do
	[ -f "$f" ] && add_files "luasrc/view/openclaw/$(basename "$f")"
done
for f in "$REPO_ROOT"/root/usr/share/rpcd/acl.d/*.json; do
	[ -f "$f" ] && add_files "root/usr/share/rpcd/acl.d/$(basename "$f")"
done
# /usr/share/openclaw 下的脚本与前端 (ui/ 目录整体复制, 单独校验)
for f in "$REPO_ROOT"/root/usr/share/openclaw/*.sh "$REPO_ROOT"/root/usr/share/openclaw/*.js; do
	[ -f "$f" ] && add_files "root/usr/share/openclaw/$(basename "$f")"
done

[ -n "$FILES" ] || fail "no packageable source files detected (parser drift?)"

# ── 三条路径逐一校验 ──
missing=""
for rel in $FILES; do
	covered "$rel" "$MK"  || missing="${missing}\n  Makefile        缺少 $rel"
	covered "$rel" "$IPK" || missing="${missing}\n  build_ipk.sh    缺少 $rel"
	covered "$rel" "$RUN" || missing="${missing}\n  build_run.sh    缺少 $rel"
done

if [ -n "$missing" ]; then
	# shellcheck disable=SC2059
	printf "打包清单不一致:$missing\n" >&2
	fail "packaging paths disagree on which files to install"
fi

# ── ui/ 目录与 VERSION ──
for s in "$MK" "$IPK" "$RUN"; do
	grep -Fq 'share/openclaw/ui' "$s" || fail "$(basename "$s") must install the Web PTY ui/ directory"
	grep -Fq 'VERSION' "$s" || fail "$(basename "$s") must ship the VERSION file"
done

# ── 回归钉子 ──
# 这两个文件曾只在 build 脚本里、Makefile 漏装
grep -Fq 'oc-config-interactive.js' "$MK" || fail "Makefile must install oc-config-interactive.js (feeds/SDK builds fell back to the legacy menu without it)"
grep -Fq 'oc-menu-engine.js' "$MK" || fail "Makefile must install oc-menu-engine.js"

# 依赖声明三处必须一致, 且不得丢掉 libstdcpp6 (issue #28: 缺失导致 Node 无法运行)
for s in "$MK" "$IPK" "$RUN"; do
	grep -Fq 'libstdcpp6' "$s" || fail "$(basename "$s") must keep the libstdcpp6 dependency (issue #28)"
done

# feeds 集成: 不得再依赖 luci.mk 的隐式 Package 生成 (issue #60)
# 只看真正的 include 语句, 注释里提到 luci.mk (说明历史原因) 是允许的。
if grep -E '^[[:space:]]*include[[:space:]].*feeds/luci/luci\.mk' "$MK" >/dev/null 2>&1; then
	fail "Makefile must not depend on luci.mk implicit package generation (breaks OpenWrt 25.x feeds, issue #60)"
fi
if grep -E '^[[:space:]]*ifeq[[:space:]]*\(\$\(wildcard[[:space:]].*luci\.mk' "$MK" >/dev/null 2>&1; then
	fail "Makefile must not branch on luci.mk availability (issue #60)"
fi
grep -Fq 'define Package/$(PKG_NAME)' "$MK" || fail "Makefile must define Package/... explicitly"

echo "ok"
