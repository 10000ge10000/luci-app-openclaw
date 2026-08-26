#!/bin/sh
# Web PTY 安全契约。
#
# 背景: Web PTY 服务监听 0.0.0.0:18793，原先返回
#   Access-Control-Allow-Origin: *
#   X-Frame-Options: ALLOWALL
#   Content-Security-Policy: default-src * 'unsafe-inline' 'unsafe-eval' ...
# 等于对任意站点开放；且页面把含 PTY token 的 WebSocket URL 写进可见
# 调试文本与 console，token 会残留在截图、录屏与浏览器历史中。
#
# 收紧依据(已逐项核实):
#   - 页面资源全为本地 /lib/*.js|css，无外链          -> default-src 'self'
#   - 唯一 fetch 是 /health，与 iframe 自身同源       -> 不需要 ACAO
#   - 存在内联 <style>/<script> 块                    -> 保留 'unsafe-inline'
#   - xterm.js 不需要 eval                            -> 去掉 'unsafe-eval'
#   - LuCI(80) 与 PTY(18793) 跨源嵌入                 -> 仅需 frame-ancestors
#
# 真正的访问控制始终是 WebSocket 升级时的 token 校验(无/错 token 均 403)。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PTY="$REPO_ROOT/root/usr/share/openclaw/web-pty.js"
PAGE="$REPO_ROOT/root/usr/share/openclaw/ui/index.html"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

[ -f "$PTY" ] || fail "missing $PTY"
[ -f "$PAGE" ] || fail "missing $PAGE"

# ── WebSocket token 校验是唯一的访问控制，不得移除 ──
grep -Fq "searchParams.get('token')" "$PTY" || fail "WS upgrade must read the token parameter"
grep -Fq 'WS auth failed' "$PTY" || fail "WS upgrade must reject unauthenticated connections"
grep -Fq '403' "$PTY" || fail "WS upgrade must answer 403 on auth failure"

# ── 响应头不得回退成全开放 ──
if grep -Fq "'Access-Control-Allow-Origin': '*'" "$PTY"; then
	fail "web-pty.js must not send Access-Control-Allow-Origin: * (no cross-origin fetch is needed)"
fi
if grep -Fq 'ALLOWALL' "$PTY" | grep -qv '^[[:space:]]*//'; then
	fail "web-pty.js must not send X-Frame-Options: ALLOWALL"
fi
# CSP 必须存在且不得是 default-src *
grep -Fq 'Content-Security-Policy' "$PTY" || fail "web-pty.js must send a Content-Security-Policy"
if grep -Fq 'default-src *' "$PTY" | grep -qv '^[[:space:]]*//'; then
	fail "CSP must not use a wildcard default-src"
fi
grep -Fq "default-src 'self'" "$PTY" || fail "CSP default-src should be 'self'"
grep -Fq 'frame-ancestors' "$PTY" || fail "CSP must keep frame-ancestors so LuCI can embed the terminal"
# 内联块仍在, 因此 unsafe-inline 必须保留; 但不应保留 unsafe-eval
grep -Fq "'unsafe-inline'" "$PTY" || fail "CSP must keep 'unsafe-inline' (the page has inline style/script blocks)"
if grep -F "'unsafe-eval'" "$PTY" | grep -qv '^[[:space:]]*//'; then
	fail "CSP should not need 'unsafe-eval'"
fi

# ── 页面不得把含 token 的 URL 写进可见文本或 console ──
grep -Fq 'wsUrlSafe' "$PAGE" || fail "page must use a redacted URL for display/logging"
# 展示位置一律使用脱敏 URL
if grep -F 'loadingDebug.textContent = wsUrl;' "$PAGE" | grep -q .; then
	fail "page must not print the token-bearing WebSocket URL into visible text"
fi
if grep -F 'console.log' "$PAGE" | grep -F 'wsUrl' | grep -Fqv 'wsUrlSafe'; then
	fail "page must not log the token-bearing WebSocket URL"
fi
# 真实 wsUrl 只应出现在建立连接处
ws_uses=$(grep -c 'new WebSocket(wsUrl)' "$PAGE" || true)
[ "$ws_uses" -ge 1 ] || fail "page must still connect using the real token-bearing URL"

# ── token 读取后必须从地址栏移除 ──
grep -Fq 'history.replaceState' "$PAGE" \
	|| fail "page must scrub pty_token from the address bar after reading it"
grep -Fq "searchParams.delete('pty_token')" "$PAGE" \
	|| fail "page must remove the pty_token query parameter"

echo "ok"
