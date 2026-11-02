#!/bin/sh
# Web PTY 文本帧编码测试。
#
# 背景: BusyBox script 每次最多读 1024 字节，中文字符会被切到两个输出块里。
# 把原始块直接当文本帧发送时，浏览器判定 UTF-8 非法并以 1007 断开，
# 终端反复显示「正在连接终端」，菜单被重新启动，正在填写的内容丢失。
# 这里用替身脚本稳定地制造切分，不依赖真实菜单和 script 命令。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WEB_PTY="$REPO_ROOT/root/usr/share/openclaw/web-pty.js"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

command -v node >/dev/null 2>&1 || { echo "ok (skipped: no node interpreter available)"; exit 0; }
NODE_BIN=$(command -v node)

WORK=$(mktemp -d)
PTY_PID=""
cleanup() {
	[ -z "$PTY_PID" ] || kill "$PTY_PID" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# 「中」= e4 b8 ad，分三次输出；stderr 同样切分，末尾再留一个截断的字符
cat > "$WORK/split.sh" <<'EOF'
printf '\344'
sleep 0.2
printf '\270'
sleep 0.2
printf '\255|'
sleep 0.2
printf '\346\226' >&2
sleep 0.2
printf '\207|' >&2
sleep 0.2
printf 'END|'
printf '\345\233'
exit 0
EOF

# 空 PATH 让 which script 失败，走不依赖 script 的回退路径
mkdir -p "$WORK/empty"
PORT=$((20000 + $$ % 20000))
env PATH="$WORK/empty" OC_CONFIG_PORT="$PORT" OC_CONFIG_HOST=127.0.0.1 OC_CONFIG_SCRIPT="$WORK/split.sh" \
	OC_PTY_TOKEN=test-pty-token "$NODE_BIN" "$WEB_PTY" >"$WORK/server.log" 2>&1 &
PTY_PID=$!

cat > "$WORK/client.js" <<'EOF'
const net = require('net');
const port = +process.argv[2];
const fatal = new TextDecoder('utf-8', { fatal: true });
const decoded = [];
let buf = Buffer.alloc(0), upgraded = false, invalid = 0;
function connect(left) {
  const s = net.connect(port, '127.0.0.1');
  s.on('error', () => {
    if (left <= 0) { console.log('connect failed'); process.exit(2); }
    setTimeout(() => connect(left - 1), 200);
  });
  s.on('connect', () => s.write('GET /ws?token=test-pty-token HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'));
  s.on('data', (c) => {
    buf = Buffer.concat([buf, c]);
    if (!upgraded) {
      const i = buf.indexOf('\r\n\r\n');
      if (i < 0) return;
      buf = buf.slice(i + 4);
      upgraded = true;
    }
    while (buf.length >= 2) {
      const op = buf[0] & 15;
      let len = buf[1] & 127, off = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
      if (buf.length < off + len) return;
      const data = buf.slice(off, off + len);
      buf = buf.slice(off + len);
      if (op !== 1) continue;
      try { decoded.push(fatal.decode(data)); } catch { invalid++; }
    }
  });
}
connect(25);
setTimeout(() => {
  console.log(JSON.stringify({ invalid, text: decoded.join('') }));
  process.exit(0);
}, 2500);
EOF

RESULT=$("$NODE_BIN" "$WORK/client.js" "$PORT")

RESULT="$RESULT" "$NODE_BIN" -e '
const r = JSON.parse(process.env.RESULT);
if (r.invalid !== 0) { console.error("invalid text frames: " + r.invalid); process.exit(1); }
for (const want of ["中|", "文|", "END|"]) {
  if (!r.text.includes(want)) { console.error("missing " + want + " in " + JSON.stringify(r.text)); process.exit(1); }
}
if (!r.text.includes("�")) { console.error("truncated tail must be flushed as U+FFFD"); process.exit(1); }
' || fail "every text frame must be valid UTF-8 and characters split across chunks must arrive whole"

if grep -q 'test-pty-token' "$WORK/server.log"; then
	fail "web-pty must not log the token from the upgrade URL"
fi

echo "ok"
