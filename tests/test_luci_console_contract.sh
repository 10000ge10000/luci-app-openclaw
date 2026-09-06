#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONSOLE_VIEW="$REPO_ROOT/luasrc/view/openclaw/console.htm"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq "var url = 'http://' + host + ':' + gwPort + '/'" "$CONSOLE_VIEW" || fail "console view should force HTTP gateway URL"
grep -Fq "document.createElement('iframe')" "$CONSOLE_VIEW" || fail "console view should embed the OpenClaw UI in an iframe"
grep -Fq "oc-console-iframe" "$CONSOLE_VIEW" || fail "console view should define oc-console-iframe"
grep -Fq "allowfullscreen" "$CONSOLE_VIEW" || fail "console view should support fullscreen"
grep -Fq "microphone" "$CONSOLE_VIEW" || fail "console view should allow media permissions"

if grep -Fq 'window.location.protocol' "$CONSOLE_VIEW"; then
	fail "console view should not reuse the LuCI page protocol for the gateway URL"
fi

cr=$(printf '\r')
if LC_ALL=C grep -q "$cr" "$CONSOLE_VIEW"; then
	fail "console view should use LF line endings"
fi

echo "ok"
