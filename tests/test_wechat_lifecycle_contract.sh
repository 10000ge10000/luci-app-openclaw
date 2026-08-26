#!/bin/sh
# 微信插件生命周期契约 (安装 / 登录 / 登出 / 卸载)。
#
# 背景 (实机验证发现):
# action_wechat_uninstall 删除了插件与状态目录，却不重启网关。网关进程仍在
# 内存中持有已加载的微信渠道，会把会话游标 (get_updates_buf, 内含账号标识)
# 写回刚被删除的 .openclaw/openclaw-weixin/accounts/ 目录 —— 于是目录被重建，
# 卸载后仍残留登录态。实测该残留文件 mtime 与卸载时刻相同，是"删除后被重建"。
#
# 对比证据: action_wechat_login 与 action_wechat_logout 本来就会重启网关，
# 只有卸载遗漏了这一步，属实现不一致。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONTROLLER="$REPO_ROOT/luasrc/controller/openclaw.lua"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

[ -f "$CONTROLLER" ] || fail "missing $CONTROLLER"

fnbody() {
	awk "/^function $1/,/^end\$/" "$CONTROLLER"
}

# ── 卸载必须重启网关，否则登录态会被写回 ──
UNINSTALL=$(fnbody action_wechat_uninstall)
[ -n "$UNINSTALL" ] || fail "cannot locate action_wechat_uninstall"

printf '%s' "$UNINSTALL" | grep -Fq '/etc/init.d/openclaw restart' \
	|| fail "uninstall must restart the gateway — otherwise the still-loaded wechat channel rewrites its session state into the deleted directory"

# 重启后需再清理一次状态目录 (重启是异步的)
printf '%s' "$UNINSTALL" | grep -Fq 'wechat_state_dir' \
	|| fail "uninstall must remove the wechat state directory"
printf '%s' "$UNINSTALL" | grep -Eq 'sleep [0-9]+; *rm -rf' \
	|| fail "uninstall must re-clean the state dir after the async gateway restart"

# ── 登录/登出本来就重启，不得退化 ──
for fn in action_wechat_login action_wechat_logout; do
	body=$(fnbody "$fn")
	[ -n "$body" ] || fail "cannot locate $fn"
	printf '%s' "$body" | grep -Eq '/etc/init.d/openclaw (restart|reload)|restart_gateway' \
		|| fail "$fn must reload the gateway so the channel change takes effect"
done

# ── 卸载必须清理配置中的微信痕迹，但不得动无关配置 ──
printf '%s' "$UNINSTALL" | grep -Fq "x !== 'openclaw-weixin' && x !== 'weixin'" \
	|| fail "uninstall must drop both the current and legacy wechat plugin ids from plugins.allow"
# 不得整体清空 channels / models / plugins
if printf '%s' "$UNINSTALL" | grep -Eq 'delete d\.channels[^.\[]|d\.channels *= *\{\}|d\.models *= *\{\}'; then
	fail "uninstall must not wipe unrelated channels or model config"
fi

# ── 安装/卸载都必须经 POST + CSRF ──
for ep in wechat_install wechat_uninstall wechat_login wechat_logout wechat_upgrade_plugin; do
	line=$(grep -F "\"openclaw\", \"$ep\"}" "$CONTROLLER" | head -1)
	[ -n "$line" ] || fail "endpoint $ep not registered"
	case "$line" in
		*'post("action_'*) ;;
		*) fail "endpoint $ep must require POST + CSRF (it changes plugin state)" ;;
	esac
done

echo "ok"
