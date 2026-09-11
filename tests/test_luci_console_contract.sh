#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONSOLE_VIEW="$REPO_ROOT/luasrc/view/openclaw/console.htm"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq "console_utils.normalize_https_url" "$CONSOLE_VIEW" || fail "console view should validate console_url with the shared helper"
grep -Fq "uciHttpsConsoleUrl" "$CONSOLE_VIEW" || fail "console view should expose uciHttpsConsoleUrl to JavaScript"
grep -Fq "'http://' + host + ':' + gwPort" "$CONSOLE_VIEW" || fail "console view should fall back to HTTP host:port"
grep -Fq "SSH localhost 隧道" "$CONSOLE_VIEW" || fail "console view should explain the localhost tunnel"
grep -Fq "127.0.0.1:18790:127.0.0.1:" "$CONSOLE_VIEW" || fail "console view should generate the localhost tunnel command"
grep -Fq "访问条件提示" "$CONSOLE_VIEW" || fail "console view should provide access conditions hint for secure context"
grep -Fq "getEmbeddedConsoleUrl" "$CONSOLE_VIEW" || fail "console view should separate embedded and external URLs"
grep -Fq "getExternalConsoleUrl" "$CONSOLE_VIEW" || fail "console view should separate embedded and external URLs"
grep -Fq "data-console-url" "$CONSOLE_VIEW" || fail "console URL should be passed through an escaped HTML attribute"
if grep -Fq "var uciHttpsConsoleUrl = '<%=" "$CONSOLE_VIEW"; then
	fail "console URL must not be interpolated into a JavaScript string"
fi
grep -Fq "document.createElement('iframe')" "$CONSOLE_VIEW" || fail "console view should embed the OpenClaw UI in an iframe"
grep -Fq "oc-console-iframe" "$CONSOLE_VIEW" || fail "console view should define oc-console-iframe"
grep -Fq "allowfullscreen" "$CONSOLE_VIEW" || fail "console view should support fullscreen"
grep -Fq "microphone" "$CONSOLE_VIEW" || fail "console view should allow media permissions"

if grep -Fq 'window.location.protocol' "$CONSOLE_VIEW"; then
	fail "console view should not reuse the LuCI page protocol for the gateway URL"
fi

custom_url_branch=$(sed -n '/function getExternalConsoleUrl/,/^\t}/p' "$CONSOLE_VIEW")
printf '%s' "$custom_url_branch" | grep -Fq "return uciHttpsConsoleUrl" || fail "custom HTTPS URL should be external-only"
if printf '%s' "$custom_url_branch" | grep -Fq "appendGatewayToken(uciHttpsConsoleUrl)"; then
	fail "custom HTTPS URL must never receive the Gateway token"
fi

cr=$(printf '\r')
if LC_ALL=C grep -q "$cr" "$CONSOLE_VIEW"; then
	fail "console view should use LF line endings"
fi

echo "ok"
