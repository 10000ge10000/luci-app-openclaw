#!/bin/sh
# 传统 Shell 菜单 (oc-config.sh) 配置写入安全契约。
#
# 背景: oc-config.sh 早期的写入函数沿用 try{d=JSON.parse(...)}catch(e){} 写法，配置损坏
# (如手改后多一个尾随逗号) 时 d 保持 {}，随后整份写回，models.providers 中其它 apiKey、
# channels 全部丢失；auth_set_apikey 还会把 auth-profiles.json 覆盖成只剩本次的 Key。
#
# v2.3 起模型 / 凭据配置全部交给共享后端 oc-providers.js (见 test_provider_backend.sh)，
# Shell 菜单剩下的直接写入只有 json_set (渠道、网关等字段)。本测试校验:
#   1. 静态: 不再吞掉解析错误；模型菜单不直接写 Key / 不写退役的 auth-profiles.json
#   2. 行为: json_set 遇到损坏配置失败且原文件逐字节不变；正常写入保留其它字段；
#      升级事务迁移期间暂停写入
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
MENU="$REPO_ROOT/root/usr/share/openclaw/oc-config.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

# ── 静态契约 ──
if grep -nE "try\{d=JSON\.parse\(fs\.readFileSync\([^)]*\)\);\}catch\(e\)\{\}" "$MENU"; then
	fail "oc-config.sh must not swallow JSON parse errors before writing config back"
fi
for gone in auth_set_apikey auth_set_copilot_token register_and_set_model register_custom_provider; do
	if grep -q "^${gone}() {" "$MENU"; then
		fail "$gone wrote credentials directly and must stay removed (use oc-providers.js)"
	fi
done
if grep -nE "auth-profiles\.json.*(writeFileSync|>)" "$MENU"; then
	fail "shell menu must not write the retired auth-profiles.json"
fi
# Key 只能经由 stdin 交给后端 (printf ... | ocp apply-key)，不能出现在 ocp 的参数里
if grep -nE 'ocp apply-(key|custom)[^|]*\$OC_SECRET' "$MENU"; then
	fail "API key must be piped to oc-providers.js on stdin, never passed as an argument"
fi
grep -Fq 'printf '"'"'%s\n'"'"' "$OC_SECRET" | ocp apply-key' "$MENU" || fail "shell menu must pipe the key to apply-key on stdin"

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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

for fn in oc_schema_type_for_key json_set; do
	awk -v fn="$fn" '$0 ~ "^"fn"\\(\\) \\{" { grab = 1 } grab { print } grab && /^}/ { exit }' "$MENU" >> "$WORK/funcs.sh"
	grep -q "^${fn}() {" "$WORK/funcs.sh" || fail "cannot extract $fn from oc-config.sh"
done

STATE="$WORK/data/.openclaw"
mkdir -p "$STATE"
CFG="$STATE/openclaw.json"

run_fn() {
	OC_DATA="$WORK/data" OC_STATE_DIR="$STATE" OC_BASE_PATH="$WORK/base" CONFIG_FILE="$CFG" NODE_BIN="$NODE_BIN" \
		sh -c "fix_openclaw_state_permissions() { :; }; . \"$WORK/funcs.sh\"; $1" >/dev/null 2>&1
}

# 场景 1: 配置带尾随逗号 -> json_set 必须失败且原文件不变
printf '{\n "models": { "providers": { "keep": { "apiKey": "SECRET-A" } } },\n "channels": { "telegram": { "botToken": "TG" } },\n}\n' > "$CFG"
cp "$CFG" "$WORK/before"
if run_fn 'json_set channels.discord.token NEW-TOKEN'; then
	fail "json_set should fail on a corrupt config"
fi
cmp -s "$CFG" "$WORK/before" || fail "corrupt openclaw.json was overwritten (apiKey / channel tokens lost)"

# 场景 2: 文件不存在属首装正常情况
rm -f "$CFG"
run_fn 'json_set gateway.port 18789' || fail "json_set should create a missing config"
"$NODE_BIN" -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if (c.gateway.port !== 18789) process.exit(1)' "$CFG" \
	|| fail "json_set must store gateway.port as a number on a fresh config"

# 场景 3: 正常配置 -> 写入生效且保留其它字段
printf '{ "models": { "providers": { "keep": { "apiKey": "SECRET-A" } } }, "channels": { "telegram": { "botToken": "TG" } } }\n' > "$CFG"
run_fn 'json_set channels.discord.token NEW-TOKEN' || fail "json_set failed on a valid config"
"$NODE_BIN" -e '
const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
if (c.channels.discord.token !== "NEW-TOKEN") { console.error("value not written"); process.exit(1); }
if (c.models.providers.keep.apiKey !== "SECRET-A" || c.channels.telegram.botToken !== "TG") { console.error("other fields lost"); process.exit(1); }
' "$CFG" || fail "json_set must only change the requested key"

# 场景 4: 升级事务迁移期间暂停写入 (不报错、不修改)
mkdir -p "$WORK/data/.luci-openclaw-upgrade"
printf '{ "phase": "migrating" }\n' > "$WORK/data/.luci-openclaw-upgrade/status.json"
cp "$CFG" "$WORK/before"
run_fn 'json_set channels.discord.token OTHER' || fail "json_set should return quietly while an upgrade is migrating"
cmp -s "$CFG" "$WORK/before" || fail "json_set must not write while an upgrade transaction is migrating"

echo "ok"
