#!/bin/sh
# LuCI 端点 CSRF 契约。
#
# 背景: LuCI 的 dispatcher 只对 post() 注册的端点执行 test_post_security()
# (同时要求 REQUEST_METHOD=POST 且表单 token 与会话 authtoken 匹配)。
# call() 注册的端点允许 GET 触发且完全不校验 token。
#
# 原实现里会改状态或返回凭据的端点全都是 call():
#   service_ctl     启停/重启/安装 OpenClaw
#   uninstall       删除整个运行环境
#   plugin_upgrade  下载并执行 .run 安装包
#   backup          create/restore/delete 备份
#   get_token       返回网关 token 与 PTY token
# 这些端点都在 admin/services/openclaw 下(需登录)，但 GET 可触发意味着
# 诱导已登录的管理员访问一个链接即可卸载环境或读出凭据。
#
# 本测试锁定: 改状态/返回凭据的端点必须是 post()，只读端点可以是 call()。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONTROLLER="$REPO_ROOT/luasrc/controller/openclaw.lua"
BASIC="$REPO_ROOT/luasrc/model/cbi/openclaw/basic.lua"
ADVANCED="$REPO_ROOT/luasrc/view/openclaw/advanced.htm"
CONSOLE="$REPO_ROOT/luasrc/view/openclaw/console.htm"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

for f in "$CONTROLLER" "$BASIC" "$ADVANCED" "$CONSOLE"; do
	[ -f "$f" ] || fail "missing $f"
done

# 必须用 post() 注册的端点: 会改状态或返回凭据
MUST_POST="service_ctl uninstall plugin_upgrade backup get_token
wechat_install wechat_login wechat_logout wechat_uninstall wechat_upgrade_plugin
devices_approve"

for ep in $MUST_POST; do
	line=$(grep -F "\"openclaw\", \"$ep\"}" "$CONTROLLER" | head -1)
	[ -n "$line" ] || fail "endpoint $ep not registered"
	case "$line" in
		*"post(\"action_"*) ;;
		*"call(\"action_"*)
			fail "endpoint $ep must be registered with post() — it changes state or returns credentials, and call() allows GET without CSRF validation"
			;;
		*) fail "endpoint $ep: unrecognized registration form" ;;
	esac
done

# 前端必须以 POST 方式调用这些端点，并带上 CSRF token。
# basic.lua 里针对 post 端点的调用不得再使用 XHR get。
for u in ctl_url uninstall_url plugin_upgrade_url backup_url; do
	if grep -F '(new XHR()).get(' "$BASIC" | grep -Fq ".. $u"; then
		fail "basic.lua still calls $u with XHR get (post endpoints reject GET with 405)"
	fi
done

# CSRF token 必须被注入前端并随请求提交
grep -Fq 'context.authtoken' "$BASIC" || fail "basic.lua must expose the CSRF token to its scripts"
grep -Fq 'ocCsrfToken' "$BASIC" || fail "basic.lua must pass the CSRF token in requests"
# 允许 {token:ocCsrfToken} 与 {token: ocCsrfToken} 两种写法
grep -Eq 'token:[[:space:]]*ocCsrfToken' "$BASIC" \
	|| fail "basic.lua post calls must include the CSRF token"

# 每个 post 调用都必须带 token, 不能漏掉某一处
post_calls=$(grep -c '(new XHR()).post(' "$BASIC" || true)
post_with_token=$(grep '(new XHR()).post(' "$BASIC" | grep -Ec 'token:[[:space:]]*ocCsrfToken' || true)
[ "$post_calls" = "$post_with_token" ] \
	|| fail "basic.lua has $post_calls post calls but only $post_with_token carry the CSRF token"

# get_token 的两个调用方也必须改为带 token 的 POST
for f in "$ADVANCED" "$CONSOLE"; do
	b=$(basename "$f")
	grep -Fq '(new XHR()).get(tokenUrl' "$f" \
		&& fail "$b must POST to get_token (it is now a post() endpoint)"
	grep -Fq '(new XHR()).post(tokenUrl' "$f" \
		|| fail "$b must call get_token via POST"
	grep -Eq 'token:[[:space:]]*ocCsrfToken' "$f" || fail "$b must send the CSRF token to get_token"
	grep -Fq "var ocCsrfToken = '<%=token%>'" "$f" \
		|| fail "$b must read the CSRF token from the LuCI template"
done

# 只读端点保持 call() 即可 —— 确认没有被误改成 post 而导致前端 GET 调用失效
READ_ONLY="status_api setup_log check_update check_system plugin_upgrade_log
wechat_status wechat_install_log wechat_login_status wechat_check_upgrade
devices_list"
for ep in $READ_ONLY; do
	line=$(grep -F "\"openclaw\", \"$ep\"}" "$CONTROLLER" | head -1)
	[ -n "$line" ] || fail "endpoint $ep not registered"
	case "$line" in
		*"post(\"action_"*)
			# 若改为 post，前端必须同步改为带 token 的 POST，否则会 405
			if grep -F "$ep" "$BASIC" "$ADVANCED" "$CONSOLE" 2>/dev/null | grep -Fq '(new XHR()).get('; then
				fail "endpoint $ep was switched to post() but a frontend caller still uses GET"
			fi
			;;
	esac
done

echo "ok"
