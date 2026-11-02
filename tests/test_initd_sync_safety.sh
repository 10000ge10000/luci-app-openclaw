#!/bin/sh
# init.d 启动同步安全契约。
#
# 背景: sync_uci_to_json() 会在每次 start_service 时把 UCI 配置同步进
# openclaw.json。旧实现用 try{...}catch(e){} 吞掉解析错误后让 d 保持 {}，
# 然后把这个空对象连同默认值一起写回磁盘。
#
# 实测后果: 一份仅多出尾随逗号的配置(OpenClaw 自身的 JSON5 解析器可容忍)，
# 经过一次普通的 /etc/init.d/openclaw start 之后，文件从 177 字节
# (含 models.providers 的 apiKey 与 channels.openclaw-weixin) 变成 221 字节，
# apiKey 与渠道配置全部消失。
#
# 这比手工操作触发的同类缺陷更危险: 它在服务启动路径上自动执行。
# 本测试锁定 fail-closed 行为，并校验同步写入的字段类型符合上游 schema。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INIT_SCRIPT="$REPO_ROOT/root/etc/init.d/openclaw"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

[ -f "$INIT_SCRIPT" ] || fail "missing $INIT_SCRIPT"

# ── 静态契约 ──
grep -Fq 'sync_uci_to_json' "$INIT_SCRIPT" || fail "sync_uci_to_json missing"
grep -Fq '已跳过 UCI 同步' "$INIT_SCRIPT" \
	|| fail "sync_uci_to_json must abort instead of overwriting an unparsable config"

# 不得再出现"解析失败后静默继续"的写法
if awk '/^OC_SYNC_PORT=/,/^" 2>\/dev\/null$/' "$INIT_SCRIPT" \
	| grep -Fq "try{d=JSON.parse(fs.readFileSync(f,'utf8'));}catch(e){}"; then
	fail "sync_uci_to_json must not swallow JSON parse errors (that wipes user config)"
fi

# 启动路径上所有「读配置 → 改 → 写回」的内嵌脚本都不得吞掉解析错误后继续写
# (_ensure_critical_config 每次启动都执行，旧实现会把含尾随逗号的配置覆盖成默认值)
if grep -nE "try ?\{ ?d ?= ?JSON\.parse\(fs\.readFileSync\([^)]*\)\); ?\} ?catch ?\(e\) ?\{ ?\}" "$INIT_SCRIPT"; then
	fail "init.d must not swallow JSON parse errors before writing config back"
fi
grep -Fq '已跳过关键字段补全' "$INIT_SCRIPT" \
	|| fail "_ensure_critical_config must abort instead of overwriting an unparsable config"

# 函数必须先定义后调用 (#108 日志: "_ensure_critical_config: not found")
for fn in _ensure_critical_config _sync_token_after_doctor; do
	def_line=$(grep -n "^[[:space:]]*${fn}() {" "$INIT_SCRIPT" | head -1 | cut -d: -f1)
	[ -n "$def_line" ] || fail "$fn definition missing"
	first_call=$(grep -nE "^[[:space:]]*${fn}[[:space:]]*$" "$INIT_SCRIPT" | head -1 | cut -d: -f1)
	[ -n "$first_call" ] || fail "$fn is never called"
	[ "$first_call" -gt "$def_line" ] || fail "$fn is called at line $first_call before its definition at line $def_line"
done

# ── 行为契约 (需要 node) ──
NODE_BIN=""
for cand in node nodejs /opt/openclaw/node/bin/node; do
	if command -v "$cand" >/dev/null 2>&1; then NODE_BIN=$(command -v "$cand"); break; fi
	[ -x "$cand" ] && { NODE_BIN="$cand"; break; }
done
if [ -z "$NODE_BIN" ]; then
	echo "ok (static only: no node interpreter available)"
	exit 0
fi

WORK=$(mktemp -d 2>/dev/null || echo "/tmp/oc-initd-sync-$$")
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# 抽出内嵌的 node 脚本正文单独执行。
# 边界: 紧跟 '"$NODE_BIN" -e "' 的下一行开始，到单独一行 '" 2>/dev/null' 之前。
EXTRACT="$WORK/extract.js"
cat > "$EXTRACT" <<'EXTRACT_EOF'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8').split('\n');
let start = -1;
for (let i = 1; i < src.length; i++) {
  if (src[i].includes('"$NODE_BIN" -e "') && src[i - 1].startsWith('OC_SYNC_PORT=')) { start = i + 1; break; }
}
if (start < 0) { console.error('START NOT FOUND'); process.exit(1); }
let end = -1;
for (let i = start; i < src.length; i++) {
  if (/^"\s*2>\/dev\/null$/.test(src[i])) { end = i; break; }
}
if (end < 0) { console.error('END NOT FOUND'); process.exit(1); }
fs.writeFileSync(process.argv[3], src.slice(start, end).join('\n'));
EXTRACT_EOF

SYNC="$WORK/sync.js"
"$NODE_BIN" "$EXTRACT" "$INIT_SCRIPT" "$SYNC" || fail "cannot extract the embedded sync script"
"$NODE_BIN" --check "$SYNC" >/dev/null 2>&1 || fail "embedded sync script has a syntax error"

run_sync() {
	OC_SYNC_PORT="$1" OC_SYNC_BIND="$2" OC_SYNC_TOKEN="$3" OC_SYNC_FILE="$4" \
		"$NODE_BIN" "$SYNC" >/dev/null 2>&1
}

# 场景 1: 损坏配置 -> 必须中止且一字节不改
BAD="$WORK/bad.json"
printf '{\n "gateway": { "port": 18789 },\n "models": { "providers": { "p": { "apiKey": "SECRET" } } },\n' > "$BAD"
before=$(cat "$BAD")
if run_sync 19999 lan tok "$BAD"; then
	fail "sync should have failed on a corrupt config"
fi
after=$(cat "$BAD")
[ "$before" = "$after" ] || fail "corrupt config was modified by sync_uci_to_json"
grep -Fq SECRET "$BAD" || fail "apiKey lost: sync_uci_to_json overwrote a corrupt config"

# 场景 2: 数组根节点同样必须拒绝
ARR="$WORK/arr.json"
printf '[1,2,3]' > "$ARR"
if run_sync 18789 lan tok "$ARR"; then
	fail "sync should reject a non-object config root"
fi

# 场景 3: 正常配置 -> 同步生效且保留其它字段
GOOD="$WORK/good.json"
printf '{ "gateway": { "port": 18789 }, "models": { "providers": { "p": { "apiKey": "KEEPME" } } }, "channels": { "openclaw-weixin": { "enabled": true } } }' > "$GOOD"
run_sync 19999 lan tok2 "$GOOD" || fail "sync failed on a valid config"
"$NODE_BIN" -e '
const fs = require("fs");
const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const errs = [];
if (j.gateway.port !== 19999) errs.push("port not synced from UCI");
if (typeof j.gateway.port !== "number") errs.push("gateway.port must be a number per schema");
if (typeof j.acp.dispatch.enabled !== "boolean") errs.push("acp.dispatch.enabled must be a boolean per schema");
if (!j.models || !j.models.providers || j.models.providers.p.apiKey !== "KEEPME") errs.push("provider apiKey lost during sync");
if (!j.channels || !j.channels["openclaw-weixin"]) errs.push("channel config lost during sync");
if (errs.length) { console.error(errs.join("; ")); process.exit(1); }
' "$GOOD" || fail "sync_uci_to_json damaged a valid config"

# 场景 4: 空文件属首装正常情况
EMPTY="$WORK/empty.json"
printf '' > "$EMPTY"
run_sync 18789 lan t3 "$EMPTY" || fail "sync should treat an empty file as a fresh install"
"$NODE_BIN" -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$EMPTY" \
	|| fail "sync produced invalid JSON for a fresh install"

# ── _ensure_critical_config 行为契约 ──
# 边界: 'OC_SYNC_TOKEN="$critical_token" "$NODE_BIN" -e "' 的下一行，到以 '" 2>/dev/null' 开头的行之前。
ENSURE="$WORK/ensure.js"
awk '
	/OC_SYNC_TOKEN="\$critical_token" "\$NODE_BIN" -e "/ { grab = 1; next }
	grab && /^" 2>\/dev\/null/ { exit }
	grab { print }
' "$INIT_SCRIPT" > "$ENSURE.tpl"
[ -s "$ENSURE.tpl" ] || fail "cannot extract _ensure_critical_config script"

run_ensure() {
	sed "s#\${CONFIG_FILE}#$1#g" "$ENSURE.tpl" > "$ENSURE"
	OC_SYNC_TOKEN="tok" "$NODE_BIN" "$ENSURE" >/dev/null 2>&1
}

# 场景 5: 尾随逗号配置 -> 必须中止且一字节不改
BAD2="$WORK/bad2.json"
printf '{\n "gateway": { "port": 18789, },\n "models": { "providers": { "p": { "apiKey": "SECRET2" } } }\n}\n' > "$BAD2"
before=$(cat "$BAD2")
if run_ensure "$BAD2"; then
	fail "_ensure_critical_config should fail on a corrupt config"
fi
[ "$before" = "$(cat "$BAD2")" ] || fail "_ensure_critical_config modified a corrupt config (apiKey would be lost)"

# 场景 6: 正常配置 -> 补全关键字段且保留其它字段
GOOD2="$WORK/good2.json"
printf '{ "models": { "providers": { "p": { "apiKey": "KEEP2" } } } }' > "$GOOD2"
run_ensure "$GOOD2" || fail "_ensure_critical_config failed on a valid config"
"$NODE_BIN" -e '
const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
if (j.models.providers.p.apiKey !== "KEEP2") { console.error("apiKey lost"); process.exit(1); }
if (j.gateway.mode !== "local" || j.gateway.auth.token !== "tok") { console.error("critical fields missing"); process.exit(1); }
' "$GOOD2" || fail "_ensure_critical_config damaged a valid config"

echo "ok"
