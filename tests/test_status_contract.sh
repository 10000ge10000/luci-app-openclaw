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

grep -Fq "ubus call service list" "$CONTROLLER" || fail "status API should inspect procd state via ubus"
grep -Fq "openclaw.instances.gateway" "$CONTROLLER" || fail "status API should inspect gateway instance state"
grep -Fq "gateway_failed" "$CONTROLLER" || fail "status API should report gateway failure state"
grep -Fq "gateway_exit_code" "$CONTROLLER" || fail "status API should expose recent gateway exit code"
grep -Fq "gateway_crash_loop" "$CONTROLLER" || fail "status API should expose procd crash-loop state"
grep -Fq "procd_pid_alive" "$CONTROLLER" || fail "status API should ignore stale procd pidfiles"
grep -Fq "pidfile_stale" "$CONTROLLER" || fail "status API should require current stale pidfile evidence for crash-loop"
grep -Fq 'enabled=$(uci -q get openclaw.main.enabled' "$INIT_SCRIPT" || fail "status_service should honor disabled service state"
grep -Fq "网关:     已禁用" "$INIT_SCRIPT" || fail "status_service should report disabled gateway before crash-loop"
if grep -Fq 'pgrep -f "openclaw.*gateway"' "$CONTROLLER" "$INIT_SCRIPT" || grep -Fq "pgrep -f 'openclaw.*gateway'" "$CONTROLLER" "$INIT_SCRIPT"; then
	fail "status checks must not use broad pgrep fallback that can match the status shell itself"
fi

grep -Fq "启动失败" "$STATUS_VIEW" || fail "status panel should distinguish startup failure from startup in progress"
grep -Fq "gateway_failed" "$STATUS_VIEW" || fail "status panel should render gateway failure state"

grep -Fq "ubus call service list" "$INIT_SCRIPT" || fail "status_service should report procd state via ubus"
grep -Fq "crash-loop 抑制" "$INIT_SCRIPT" || fail "status_service should report procd crash-loop suppression"
grep -Fq "result.phase" "$CONTROLLER" || fail "status API should report upgrade transaction phase"
grep -Fq "result.target_version" "$CONTROLLER" || fail "status API should report upgrade transaction target_version"
grep -Fq "result.backup_verified" "$CONTROLLER" || fail "status API should report upgrade transaction backup_verified"
grep -Fq "result.migration_started" "$CONTROLLER" || fail "status API should report upgrade transaction migration_started"
grep -Fq "result.rollback_mode" "$CONTROLLER" || fail "status API should report upgrade transaction rollback_mode"
grep -Fq "result.error_code" "$CONTROLLER" || fail "status API should report upgrade transaction error_code"

echo "ok"
