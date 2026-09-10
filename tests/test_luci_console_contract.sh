#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONSOLE_VIEW="$REPO_ROOT/luasrc/view/openclaw/console.htm"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq "https_console_url" "$CONSOLE_VIEW" || fail "console view should extract and validate https_console_url from UCI"
grep -Fq "uciHttpsConsoleUrl" "$CONSOLE_VIEW" || fail "console view should expose uciHttpsConsoleUrl to JavaScript"
grep -Fq "'http://' + host + ':' + gwPort" "$CONSOLE_VIEW" || fail "console view should fall back to HTTP host:port"
grep -Fq "新窗口直达" "$CONSOLE_VIEW" || fail "console view should provide new window direct access"
grep -Fq "访问条件提示" "$CONSOLE_VIEW" || fail "console view should provide access conditions hint for secure context"
grep -Fq "isSecureContext" "$CONSOLE_VIEW" || fail "console view should check isSecureContext"
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
