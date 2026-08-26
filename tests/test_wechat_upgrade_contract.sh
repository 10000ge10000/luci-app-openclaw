#!/bin/sh
# 微信插件升级检测契约。
#
# 背景: action_wechat_check_upgrade 用 `npx view @tencent-weixin/openclaw-weixin version`
# 查询最新版本，但 view 是 npm 的子命令而非 npx 的。npx 会把 view 当作待执行的包
# 去解析并失败:
#   npm error could not determine executable to run
# 该错误被 2>/dev/null 吞掉后 latest_version 恒为空，is_newer_version("", x) 恒为
# false，前端又把这种情况落到 else if (d.current_version) 分支显示
# "✅ 当前已是最新版本" —— 于是升级检测从未真正工作过，真有新版也永远不提示。
#
# 本测试锁定: 用 npm 而非 npx；查询失败必须显式报错而不是伪装成"已是最新"。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONTROLLER="$REPO_ROOT/luasrc/controller/openclaw.lua"
VIEW="$REPO_ROOT/luasrc/view/openclaw/wechat.htm"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

[ -f "$CONTROLLER" ] || fail "missing $CONTROLLER"
[ -f "$VIEW" ] || fail "missing $VIEW"

# 取出升级检测函数体
BODY=$(awk '/^function action_wechat_check_upgrade/,/^end$/' "$CONTROLLER")
[ -n "$BODY" ] || fail "cannot locate action_wechat_check_upgrade"

# ── 必须用 npm view，不能用 npx view ──
printf '%s' "$BODY" | grep -Fq 'npm_bin' \
	|| fail "check_upgrade must resolve the npm binary (view is an npm subcommand, not npx)"
if printf '%s' "$BODY" | grep -E 'npx[a-z_]*_bin|npx.*view' | grep -qv '^[[:space:]]*--'; then
	fail "check_upgrade must not call 'npx view' — npx cannot run npm's view subcommand"
fi
printf '%s' "$BODY" | grep -Fq 'view @tencent-weixin/openclaw-weixin version' \
	|| fail "check_upgrade must query the wechat plugin version"

# ── 查询失败必须可诊断，不能被 2>/dev/null 吞掉 ──
if printf '%s' "$BODY" | grep -F 'view @tencent-weixin/openclaw-weixin version 2>/dev/null' | grep -q .; then
	fail "check_upgrade must not discard stderr — a failed query would look like 'up to date'"
fi
printf '%s' "$BODY" | grep -Fq 'check_err' \
	|| fail "check_upgrade must retain the error output for diagnostics"

# ── 响应必须区分"已是最新"与"查不到" ──
printf '%s' "$BODY" | grep -Fq 'status = (latest_version ~= "") and "ok" or "error"' \
	|| fail "check_upgrade must report status=error when the version lookup fails"
printf '%s' "$BODY" | grep -Fq 'message' \
	|| fail "check_upgrade must return a message explaining a failed lookup"

# ── 前端不得把查询失败显示成"已是最新版本" ──
# 正确顺序: has_upgrade -> 未安装 -> 查询失败 -> 已是最新
printf '%s' "$(cat "$VIEW")" | grep -Fq "d.status !== 'ok' || !d.latest_version" \
	|| fail "wechat.htm must handle a failed version lookup before claiming 'up to date'"
printf '%s' "$(cat "$VIEW")" | grep -Fq '无法确认最新版本' \
	|| fail "wechat.htm must surface an explicit 'cannot determine latest version' state"

# 旧的错误分支顺序不得复现: else if (d.current_version) 直接说已是最新
if grep -F 'else if (d.current_version) {' "$VIEW" | grep -q .; then
	fail "wechat.htm still falls back to 'up to date' whenever current_version exists"
fi

echo "ok"
