#!/bin/sh
# OpenClaw 浏览器设备配对语义与安全契约测试。
#
# 背景 (OpenClaw 2026.9.1+):
# 上游安全策略要求首次连接 Control UI 时进行设备配对审批：
#   - 列出请求: openclaw devices list --json
#   - 批准请求: openclaw devices approve <requestId>
#
# 核心规范:
#   1. 终端交互菜单 (oc-config-interactive.js) 与传统 Shell 菜单 (oc-config.sh)
#      必须提供设备配对管理与一键批准功能。
#   2. Web 控制台 (console.htm) 与终端配置 (advanced.htm) 必须提供一键批准设备配对能力，
#      且必须显式标注安全风险提示。
#   3. LuCI 控制器 (openclaw.lua) 的批准端点必须使用 post() 注册以防 CSRF 越权。
#   4. 所有受影响文件必须保持 LF 换行。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
JS_CONFIG="$REPO_ROOT/root/usr/share/openclaw/oc-config-interactive.js"
SH_CONFIG="$REPO_ROOT/root/usr/share/openclaw/oc-config.sh"
CONTROLLER="$REPO_ROOT/luasrc/controller/openclaw.lua"
CONSOLE="$REPO_ROOT/luasrc/view/openclaw/console.htm"
ADVANCED="$REPO_ROOT/luasrc/view/openclaw/advanced.htm"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

for f in "$JS_CONFIG" "$SH_CONFIG" "$CONTROLLER" "$CONSOLE" "$ADVANCED"; do
	[ -f "$f" ] || fail "missing $f"
done

# ── 1. 终端菜单 CLI 调用契约 ──
grep -Fq "'devices', 'list'" "$JS_CONFIG" || fail "interactive config must use devices list"
grep -Fq "'devices', 'approve'" "$JS_CONFIG" || fail "interactive config must use devices approve"
grep -Fq "oc_cmd devices list" "$SH_CONFIG" || fail "shell config must use oc_cmd devices list"
grep -Fq "oc_cmd devices approve" "$SH_CONFIG" || fail "shell config must use oc_cmd devices approve"

# ── 2. 菜单项注册与可达性 ──
grep -Fq "value: 'devices'" "$JS_CONFIG" || fail "interactive config must expose devices menu item"
grep -Fq "manageDevicePairing" "$JS_CONFIG" || fail "interactive config must implement manageDevicePairing"
grep -Fq "devices_pairing_menu" "$SH_CONFIG" || fail "shell config must implement devices_pairing_menu"

# ── 3. LuCI 控制器端点契约 (必须遵循 CSRF 安全规范) ──
grep -Fq 'entry({"admin", "services", "openclaw", "devices_list"}, call("action_devices_list"), nil).leaf = true' "$CONTROLLER" \
	|| fail "controller must register devices_list with call()"
grep -Fq 'entry({"admin", "services", "openclaw", "devices_approve"}, post("action_devices_approve"), nil).leaf = true' "$CONTROLLER" \
	|| fail "controller must register devices_approve with post()"
grep -Fq 'devices list --json' "$CONTROLLER" || fail "controller must invoke devices list --json"
grep -Fq 'devices approve' "$CONTROLLER" || fail "controller must invoke devices approve"
grep -Fq 'fix_openclaw_state_permissions' "$CONTROLLER" || fail "controller must fix permissions after approval"

# ── 4. Web 端安全风险提示契约 ──
# 必须在 4 处界面中显著标注风险说明
for f in "$JS_CONFIG" "$SH_CONFIG" "$CONSOLE" "$ADVANCED"; do
	grep -Fq "风险提示" "$f" || fail "$(basename "$f") missing risk warning heading"
	grep -Fq "完全控制权限" "$f" || fail "$(basename "$f") missing full control permission warning"
done

# ── 5. 前端 POST + CSRF 调用契约 ──
for f in "$CONSOLE" "$ADVANCED"; do
	grep -Fq "devices_approve" "$f" || fail "$(basename "$f") missing devices_approve call"
	grep -Fq "devices_list" "$f" || fail "$(basename "$f") missing devices_list call"
	grep -Fq "ocCsrfToken" "$f" || fail "$(basename "$f") must send CSRF token"
done

# ── 6. XSS 防护契约 ──
for f in "$CONSOLE" "$ADVANCED"; do
	grep -Fq "function escapeHtml" "$f" || fail "$(basename "$f") must define escapeHtml"
	grep -Fq "escapeHtml(item.remoteIp" "$f" || fail "$(basename "$f") must escape remoteIp"
	grep -Fq "escapeHtml(item.clientId" "$f" || fail "$(basename "$f") must escape clientId"
	grep -Fq "escapeHtml(item.requestId" "$f" || fail "$(basename "$f") must escape requestId"
done

# ── 7. 控制器退出码与参数完整性契约 ──
grep -Fq "__EXIT" "$CONTROLLER" || fail "controller must check command exit code"
grep -Fq "缺少 request_id 或 all 参数" "$CONTROLLER" || fail "controller must reject empty approve requests"

# ── 8. 换行符约束 (LF only) ──
cr=$(printf '\r')
for f in "$JS_CONFIG" "$SH_CONFIG" "$CONTROLLER" "$CONSOLE" "$ADVANCED"; do
	if LC_ALL=C grep -q "$cr" "$f"; then
		fail "$(basename "$f") must use LF line endings"
	fi
done

echo "ok"
