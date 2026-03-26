#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

CONSOLE_VIEW="$REPO_ROOT/luasrc/view/openclaw/console.htm"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq "http://' + host + ':' + gwPort + '/'" "$CONSOLE_VIEW" || fail "console view should force http for the gateway URL"
grep -Fq '请点击上方「新窗口打开」访问控制台。' "$CONSOLE_VIEW" || fail "console view should explain that the console must open in a new window"

if grep -Fq "document.createElement('iframe')" "$CONSOLE_VIEW"; then
	fail "console view should not embed the OpenClaw UI in an iframe"
fi

if grep -Fq 'window.location.protocol' "$CONSOLE_VIEW"; then
	fail "console view should not reuse the LuCI page protocol for the gateway URL"
fi

cr=$(printf '\r')
if LC_ALL=C grep -q "$cr" "$CONSOLE_VIEW"; then
	fail "console view should use LF line endings"
fi

echo "ok"
