#!/bin/sh
# 配置写入类型契约。
#
# 背景: 旧的 json_set() 把所有值都当字符串落盘 (源码注释原文"读取值并作为
# 字符串保存")。上游对类型做严格校验，实测报错:
#   gateway.port: Invalid input                       (要求 integer)
#   acp.dispatch.enabled: Invalid input (allowed: true, false)
#   channels.telegram.enabled: invalid config: must be boolean
# 结果是配置写进去了、openclaw config validate 却失败，网关拒绝启动。
#
# 另外两个键名/枚举问题:
#   - gateway.logLevel 不存在于 schema (gateway.additionalProperties=false)，
#     正确键是顶层 logging.level；错写时被静默忽略，界面显示已设置但从不生效。
#   - gateway.bind 的旧选项 all 不被上游接受 (允许: auto/lan/loopback/custom/tailnet)。
#
# 本测试同时做静态契约与真实写入行为验证。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SH_CONFIG="$REPO_ROOT/root/usr/share/openclaw/oc-config.sh"
JS_CONFIG="$REPO_ROOT/root/usr/share/openclaw/oc-config-interactive.js"
FIXTURE="$REPO_ROOT/tests/fixtures/openclaw-schema-types.tsv"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

[ -f "$SH_CONFIG" ] || fail "missing $SH_CONFIG"
[ -f "$JS_CONFIG" ] || fail "missing $JS_CONFIG"
[ -f "$FIXTURE" ] || fail "missing schema baseline $FIXTURE"

# ── 静态契约 ──

# json_set 必须有类型表与枚举白名单，而不是一律写字符串
grep -Fq 'oc_schema_type_for_key()' "$SH_CONFIG" || fail "json_set must resolve value types from a schema table"
grep -Fq 'oc_schema_enum_for_key()' "$SH_CONFIG" || fail "json_set must validate enum values before writing"
if grep -Fq '// 读取值并作为字符串保存' "$SH_CONFIG"; then
	fail "json_set must not store every value as a string"
fi

# 关键键的类型判定必须与 schema 基线一致
for key in gateway.port acp.dispatch.enabled; do
	want=$(awk -F'\t' -v k="$key" '$1==k {print $2}' "$FIXTURE")
	[ -n "$want" ] || fail "schema baseline missing $key"
	case "$want" in
		integer) want="number" ;;
	esac
	grep -Fq "$key" "$SH_CONFIG" || fail "$key not handled in oc-config.sh"
	# 类型表里必须给出非 string 的判定
	awk '/^oc_schema_type_for_key\(\)/,/^}/' "$SH_CONFIG" | grep -Fq "$want" \
		|| fail "oc_schema_type_for_key must map $key to $want"
done

# 正确的日志级别键
grep -Fq 'logging.level' "$SH_CONFIG" || fail "shell menu must write logging.level"
grep -Fq 'logging.level' "$JS_CONFIG" || fail "interactive menu must write logging.level"
if awk '/^oc_schema_enum_for_key\(\)/,/^}/' "$SH_CONFIG" | grep -Fq 'gateway.logLevel'; then
	fail "gateway.logLevel must not be reintroduced as a writable key"
fi
grep -Fq "jsonSet('gateway.logLevel'" "$JS_CONFIG" && fail "interactive menu must not write gateway.logLevel"

# bind 枚举: 不得再把 all 作为可选项提供
awk '/^oc_schema_enum_for_key\(\)/,/^}/' "$SH_CONFIG" | grep -Fq 'auto lan loopback custom tailnet' \
	|| fail "gateway.bind enum must match upstream (auto/lan/loopback/custom/tailnet)"
grep -Fq "value: 'all' }" "$JS_CONFIG" && fail "interactive bind menu must not offer 'all'"

# 写入失败不得报告成功 (避免"界面显示已设置、实际未生效")
grep -Fq 'if json_set "$2" "$3"; then' "$SH_CONFIG" || fail "--set must check json_set exit status"

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

WORK=$(mktemp -d 2>/dev/null || echo "/tmp/oc-types-$$")
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

CONFIG="$WORK/openclaw.json"
printf '{}\n' > "$CONFIG"

# 直接调用 json_set 的实现: 抽出被测函数, 注入受控的 CONFIG_FILE / NODE_BIN
HARNESS="$WORK/harness.sh"
{
	printf 'CONFIG_FILE=%s\n' "$CONFIG"
	printf 'NODE_BIN=%s\n' "$NODE_BIN"
	printf 'fix_openclaw_state_permissions() { :; }\n'
	awk '/^oc_schema_type_for_key\(\)/,/^}/' "$SH_CONFIG"
	awk '/^oc_schema_enum_for_key\(\)/,/^}/' "$SH_CONFIG"
	awk '/^json_set\(\)/,/^\}$/' "$SH_CONFIG"
	cat <<'DRIVER'
case "$1" in
	set) shift; json_set "$@" ;;
esac
DRIVER
} > "$HARNESS"

set_val() { sh "$HARNESS" set "$1" "$2" >/dev/null 2>&1; }

# 合法值必须写入成功
for pair in "gateway.port 18789" "acp.dispatch.enabled true" \
            "channels.telegram.enabled true" "gateway.bind lan" "logging.level debug"; do
	k=${pair%% *}; v=${pair##* }
	set_val "$k" "$v" || fail "valid write rejected: $k=$v"
done

# 落盘类型必须匹配 schema
"$NODE_BIN" -e '
const fs=require("fs");
const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const get=(o,k)=>k.split(".").reduce((a,x)=>a&&a[x],o);
const want={
 "gateway.port":"number",
 "acp.dispatch.enabled":"boolean",
 "channels.telegram.enabled":"boolean",
 "gateway.bind":"string",
 "logging.level":"string",
};
let bad=[];
for(const k of Object.keys(want)){
  const t=typeof get(j,k);
  if(t!==want[k]) bad.push(`${k}: want ${want[k]}, got ${t}`);
}
if(bad.length){ console.error(bad.join("; ")); process.exit(1); }
' "$CONFIG" || fail "written values do not match schema types"

# 非法值必须被拒绝, 且不得破坏已有配置
for pair in "gateway.bind all" "gateway.mode cluster" "logging.level verbose" \
            "acp.dispatch.enabled maybe" "gateway.port notanumber" "tools.profile turbo"; do
	k=${pair%% *}; v=${pair##* }
	if set_val "$k" "$v"; then
		fail "invalid value accepted: $k=$v"
	fi
done

"$NODE_BIN" -e '
const fs=require("fs");
const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(j.gateway.bind!=="lan") { console.error("bind clobbered: "+JSON.stringify(j.gateway.bind)); process.exit(1); }
if(j.logging.level!=="debug") { console.error("level clobbered: "+JSON.stringify(j.logging.level)); process.exit(1); }
if(j.acp.dispatch.enabled!==true) { console.error("acp clobbered"); process.exit(1); }
if(j.gateway.port!==18789) { console.error("port clobbered"); process.exit(1); }
' "$CONFIG" || fail "rejected writes must not modify existing config"

# 损坏配置时必须中止写入, 不能用 {} 覆盖
printf '{\n "gateway": { "port": 18789 },\n "models": { "providers": { "p": { "apiKey": "SECRET" } } },\n' > "$CONFIG"
before=$(cat "$CONFIG")
if set_val gateway.port 18790; then
	fail "write into corrupt config should have failed"
fi
after=$(cat "$CONFIG")
[ "$before" = "$after" ] || fail "corrupt config was modified by json_set"
grep -Fq SECRET "$CONFIG" || fail "apiKey lost: json_set overwrote a corrupt config"

# 显式类型参数必须生效
printf '{}\n' > "$CONFIG"
set_val meta.customFlag true || fail "explicit string write failed"
sh "$HARNESS" set meta.customNum 42 number >/dev/null 2>&1 || fail "explicit number write failed"
"$NODE_BIN" -e '
const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
if(typeof j.meta.customFlag!=="string"){console.error("default should stay string");process.exit(1);}
if(typeof j.meta.customNum!=="number"){console.error("explicit number type ignored");process.exit(1);}
' "$CONFIG" || fail "explicit type argument not honored"

echo "ok"
