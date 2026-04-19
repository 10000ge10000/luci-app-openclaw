#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

CONTROLLER="$REPO_ROOT/luasrc/controller/openclaw.lua"
STATUS_VIEW="$REPO_ROOT/luasrc/view/openclaw/status.htm"
INIT_SCRIPT="$REPO_ROOT/root/etc/init.d/openclaw"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq "ubus call service list '{\"name\":\"openclaw\"}'" "$CONTROLLER" || fail "status API should inspect procd state via ubus"
grep -Fq "gateway_failed" "$CONTROLLER" || fail "status API should report gateway failure state"
grep -Fq "exit_code" "$CONTROLLER" || fail "status API should expose recent gateway exit code"

grep -Fq "启动失败" "$STATUS_VIEW" || fail "status panel should distinguish startup failure from startup in progress"
grep -Fq "gateway_failed" "$STATUS_VIEW" || fail "status panel should render gateway failure state"

grep -Fq "ubus call service list '{\"name\":\"openclaw\"}'" "$INIT_SCRIPT" || fail "status_service should inspect procd state via ubus"
grep -Fq "启动失败" "$INIT_SCRIPT" || fail "status_service should print startup failure when procd reports a crash"

if grep -Fq 'elif pgrep -f "openclaw.*gateway" >/dev/null 2>&1; then' "$INIT_SCRIPT"; then
	fail "status_service should not treat any gateway-shaped process as \"starting\""
fi

echo "ok"
