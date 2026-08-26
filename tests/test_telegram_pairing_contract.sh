#!/bin/sh
# Telegram 配对语义契约。
#
# 背景 (issue #98 / PR #102):
# 旧实现在「Telegram 配对助手」里调用 `openclaw models auth login-telegram-bot`，
# 该子命令在 OpenClaw 2026.6+ 已不存在，实测报:
#   Too many arguments for this command. Try: openclaw models auth --help
#
# 关键在于修法。配对与 Token 配置是两件不同的事:
#   - Bot Token 配置 -> channels.telegram.botToken / channels add --bot-token
#   - 用户配对       -> openclaw pairing list / pairing approve
# 把「配对助手」改成「再配一次 Token」虽然能消除报错，但等于删掉了配对功能。
# 本测试锁定二者不被混为一谈。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
JS_CONFIG="$REPO_ROOT/root/usr/share/openclaw/oc-config-interactive.js"
SH_CONFIG="$REPO_ROOT/root/usr/share/openclaw/oc-config.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

[ -f "$JS_CONFIG" ] || fail "missing $JS_CONFIG"
[ -f "$SH_CONFIG" ] || fail "missing $SH_CONFIG"

# ── 废弃 CLI 不得复活 ──
for f in "$JS_CONFIG" "$SH_CONFIG"; do
	if grep -n 'login-telegram-bot' "$f" | grep -qv '^[0-9]*: *[/*#]'; then
		fail "$(basename "$f") still calls the removed models auth login-telegram-bot subcommand"
	fi
done

# ── 配对必须走上游 pairing 命令 (两侧实现一致) ──
grep -Fq "'pairing', 'list'" "$JS_CONFIG" || fail "interactive pairing must use openclaw pairing list"
grep -Fq "'pairing', 'approve'" "$JS_CONFIG" || fail "interactive pairing must use openclaw pairing approve"
grep -Fq 'pairing list telegram' "$SH_CONFIG" || fail "shell pairing must use openclaw pairing list"
grep -Fq 'pairing approve telegram' "$SH_CONFIG" || fail "shell pairing must use openclaw pairing approve"

# ── 配对与 Token 配置必须是两个独立入口 ──
grep -Fq "value: 'telegram' }" "$JS_CONFIG" || fail "Telegram token entry must remain in the channel menu"
grep -Fq "value: 'telegram-pairing' }" "$JS_CONFIG" || fail "Telegram pairing entry must remain in the channel menu"

# 配对分支不得把自己变成"再输入一次 Token"
pairing_block=$(awk "/case 'telegram-pairing': \{/,/^      \}$/" "$JS_CONFIG")
[ -n "$pairing_block" ] || fail "cannot locate telegram-pairing branch"
printf '%s' "$pairing_block" | grep -Fq 'pairing' || fail "telegram-pairing branch must invoke pairing commands"
if printf '%s' "$pairing_block" | grep -Eq 'channels\.telegram\.botToken *='; then
	fail "telegram-pairing must not overwrite botToken (that is the token config feature, not pairing)"
fi
# 配对前应校验 Token 已存在，而不是引导用户重新录入
printf '%s' "$pairing_block" | grep -Fq "jsonGet('channels.telegram.botToken')" \
	|| fail "telegram-pairing should require an existing bot token instead of asking for a new one"

# ── 捕获式 CLI 调用与解析器 ──
grep -Fq 'function ocCmdCapture' "$JS_CONFIG" || fail "need a silent CLI capture helper to parse pairing output"
grep -Fq 'function parsePairingCodes' "$JS_CONFIG" || fail "need a pairing code parser"

# ── 解析器行为验证 (需要 node) ──
NODE_BIN=""
for cand in node nodejs /opt/openclaw/node/bin/node; do
	if command -v "$cand" >/dev/null 2>&1; then NODE_BIN=$(command -v "$cand"); break; fi
	[ -x "$cand" ] && { NODE_BIN="$cand"; break; }
done
if [ -z "$NODE_BIN" ]; then
	echo "ok (static only: no node interpreter available)"
	exit 0
fi

"$NODE_BIN" -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
const start = src.indexOf("function parsePairingCodes");
if (start < 0) { console.error("parsePairingCodes not found"); process.exit(1); }
const body = src.slice(start, src.indexOf("\n}", start) + 2);
const parse = new Function(body + "; return parsePairingCodes;")();

const cases = [
  // 上游 pairing list --json 的真实形状 (实测): {channel, requests:[...]}
  ["upstream shape", JSON.stringify({ channel: "telegram", requests: [{ code: "A1" }, { code: "B2" }] }), 2],
  ["upstream empty", JSON.stringify({ channel: "telegram", requests: [] }), 0],
  ["plain array", JSON.stringify([{ code: "X1" }]), 1],
  ["noise around json", "WARN boot\n[{\"code\":\"R1\"}]\ndone", 1],
  ["dedupe", JSON.stringify([{ code: "D" }, { code: "D" }]), 1],
  ["empty output", "", 0],
  ["garbage", "not json at all", 0],
];
let bad = [];
for (const [name, input, want] of cases) {
  const got = parse(input);
  if (!Array.isArray(got) || got.length !== want) {
    bad.push(`${name}: want ${want}, got ${JSON.stringify(got)}`);
  }
}
if (bad.length) { console.error(bad.join("; ")); process.exit(1); }
' "$JS_CONFIG" || fail "parsePairingCodes behavior mismatch"

echo "ok"
