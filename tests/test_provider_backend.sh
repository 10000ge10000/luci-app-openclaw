#!/bin/sh
# 模型 / 提供商配置后端 (oc-providers.js) 行为测试。
#
# 两套菜单 (交互式 JS 与传统 Shell) 都只是这个后端的前端，凭据写入、默认模型、
# 自定义 provider、模型发现与连通性测试的正确性都在这里验证。
# 使用 tests/fixtures/mock-openclaw-cli.js 替身模拟上游 CLI，不访问网络、不需要真实 Key。
#
# 覆盖的约束:
#   - Key 只经由环境变量 (onboard) 或 stdin (paste-api-key) 传给上游，绝不进 argv，
#     也不出现在后端输出中 (即使上游意外回显)
#   - 新增凭据不改变用户原有默认模型 (除非用户选择设为默认)，不动其它 provider / 渠道
#   - 已有凭据走官方 paste-api-key 原地更新，不重复 onboard
#   - 认证失败如实转述上游原因，不留下半成品
#   - 外部插件必须经用户确认后才安装，且只允许官方 @openclaw/*-provider
#   - 自定义 provider: 同 id 同地址只追加模型，地址冲突拒绝，空 Key 不清除已有 Key
#   - 配置损坏或上游校验失败时 fail-closed，原文件逐字节不变
#   - 模型发现: 实时 → --refresh → 缓存 → 无，并上报 auth-rejected 提示
#   - 连通性测试: 优先 Gateway models.probe，不可用时退回 CLI；认证失败给出明确状态
#   - 不再写 auth-profiles.json (上游已退役)
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROVIDERS_JS="$REPO_ROOT/root/usr/share/openclaw/oc-providers.js"
CATALOG="$REPO_ROOT/root/usr/share/openclaw/provider-catalog.json"
MOCK_SRC="$SCRIPT_DIR/fixtures/mock-openclaw-cli.js"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

NODE_BIN=$(command -v node 2>/dev/null || true)
[ -n "$NODE_BIN" ] || [ ! -x /opt/openclaw/node/bin/node ] || NODE_BIN=/opt/openclaw/node/bin/node
if [ -z "$NODE_BIN" ]; then
	echo "SKIP: node interpreter unavailable"
	exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/oc" "$WORK/data/.openclaw"
cp "$MOCK_SRC" "$WORK/oc/openclaw.cjs"
printf '{ "name": "openclaw", "version": "2026.9.36" }\n' > "$WORK/oc/package.json"
# 真机上以 root 运行时，后端会切换到 openclaw 用户执行 CLI，测试目录需对其可写
if [ "$(id -u)" = "0" ] && grep -q '^openclaw:' /etc/passwd 2>/dev/null; then
	chown -R openclaw:openclaw "$WORK" 2>/dev/null || true
fi

STATE="$WORK/data/.openclaw"
CFG="$STATE/openclaw.json"
LOG="$WORK/oc-calls.log"
OUT="$WORK/out.txt"
KEY="sk-test-$$-SECRETVALUE"
KEY2="sk-test-$$-ROTATEDVALUE"

ocp() {
	OC_ENTRY="$WORK/oc/openclaw.cjs" NODE_BIN="$NODE_BIN" OC_DATA="$WORK/data" \
	OPENCLAW_STATE_DIR="$STATE" OPENCLAW_CONFIG_PATH="$CFG" \
	OC_PROVIDER_CATALOG="$CATALOG" OC_MODEL_CACHE_DIR="$WORK/cache" MOCK_OC_LOG="$LOG" \
		"$NODE_BIN" "$PROVIDERS_JS" "$@"
}

# 运行并把输出存入 $OUT；第一个参数为 stdin 内容 ("-" 表示无)
run() {
	_in="$1"; shift
	set +e
	if [ "$_in" = "-" ]; then
		ocp "$@" </dev/null >"$OUT" 2>&1
	else
		printf '%s\n' "$_in" | ocp "$@" >"$OUT" 2>&1
	fi
	RC=$?
	set -e
}

out_has() { grep -Fq -- "$1" "$OUT" || { cat "$OUT" >&2; fail "$2"; }; }
out_lacks() { if grep -Fq -- "$1" "$OUT"; then cat "$OUT" >&2; fail "$2"; fi; }
log_reset() { : > "$LOG"; }
# 断言调用日志: node 表达式，calls 为调用数组
log_assert() {
	"$NODE_BIN" -e '
const calls = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map(JSON.parse);
const KEY = process.argv[3], KEY2 = process.argv[4];
if (!('"$1"')) { console.error(JSON.stringify(calls, null, 1)); process.exit(1); }
' "$LOG" "$1" "$KEY" "$KEY2" || fail "$2"
}
cfg_assert() {
	"$NODE_BIN" -e '
const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const g = (p) => p.split(".").reduce((o, k) => (o == null ? undefined : o[k]), c);
if (!('"$1"')) { console.error(JSON.stringify(c, null, 1)); process.exit(1); }
' "$CFG" || fail "$2"
}
auth_assert() {
	"$NODE_BIN" -e '
let a = { profiles: [] };
try { a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); } catch {}
const KEY = process.argv[2], KEY2 = process.argv[3];
if (!('"$1"')) { console.error(JSON.stringify(a, null, 1)); process.exit(1); }
' "$STATE/mock-auth.json" "$KEY" "$KEY2" || fail "$2"
}
no_key_in_argv() {
	log_assert 'calls.every((c) => !JSON.stringify(c.argv).includes(KEY) && !JSON.stringify(c.argv).includes(KEY2))' \
		"API key must never be passed on the command line ($1)"
}

# Kwrt 等固件的 BusyBox 没有 su / runuser，降权必须用 spawn 的 uid/gid (真机实测)
if grep -nE "'su'|'runuser'|su -s " "$PROVIDERS_JS"; then fail "backend must not depend on su/runuser"; fi
grep -Fq 'uid: asUser.uid' "$PROVIDERS_JS" || fail "backend must drop root privileges via spawn uid/gid"

# 基线配置: 已有默认模型、fallback、一个带 Key 的自定义 provider 和一个渠道 Token
write_baseline() {
	cat > "$CFG" <<'EOF'
{
  "agents": { "defaults": {
    "model": { "primary": "keep/keep-model", "fallbacks": ["keep/keep-model-2", "demo/old-model"] },
    "models": { "keep/keep-model": {}, "keep/keep-model-2": {}, "demo/old-model": {} }
  } },
  "models": { "providers": {
    "keep": { "baseUrl": "https://keep.example.invalid/v1", "api": "openai-completions", "apiKey": "KEEP-SECRET",
              "models": [{ "id": "keep-model" }, { "id": "keep-model-2" }] },
    "demo": { "baseUrl": "https://demo.example.invalid/v1", "api": "openai-completions", "apiKey": "DEMO-SECRET",
              "models": [{ "id": "old-model" }] }
  } },
  "channels": { "telegram": { "botToken": "TG-SECRET", "enabled": true } },
  "gateway": { "port": 18789, "bind": "lan" }
}
EOF
	printf '{ "profiles": [ { "id": "other:default", "provider": "other", "type": "api_key", "key": "OTHER-SECRET" } ] }\n' > "$STATE/mock-auth.json"
	rm -f "$STATE/mock-plugins.json"
}
preserved() {
	cfg_assert 'g("models.providers.keep.apiKey") === "KEEP-SECRET" && g("channels.telegram.botToken") === "TG-SECRET" && g("gateway.port") === 18789' \
		"unrelated providers / channels / gateway must be preserved ($1)"
	auth_assert 'a.profiles.some((p) => p.id === "other:default" && p.key === "OTHER-SECRET")' \
		"existing credentials of other providers must be preserved ($1)"
}

# 选一个内置 (无需外部插件) 的 API Key 接入方式，以及一个需要插件的
BUILTIN_REF=$("$NODE_BIN" -e '
const c = require(process.argv[1]);
for (const p of c.providers) if (!p.plugin) for (const m of p.methods) if (m.type === "api-key" && m.env && m.provider && m.defaultModel) { console.log(p.id + ":" + m.id); process.exit(0); }
process.exit(1);' "$CATALOG") || fail "catalog must contain at least one built-in API key provider"
BUILTIN_PROV=$("$NODE_BIN" -e 'const c=require(process.argv[1]);const [p,m]=process.argv[2].split(":");console.log(c.providers.find(x=>x.id===p).methods.find(x=>x.id===m).provider)' "$CATALOG" "$BUILTIN_REF")
BUILTIN_ENV=$("$NODE_BIN" -e 'const c=require(process.argv[1]);const [p,m]=process.argv[2].split(":");console.log(c.providers.find(x=>x.id===p).methods.find(x=>x.id===m).env)' "$CATALOG" "$BUILTIN_REF")

# ── 1. 目录与菜单数据 ──
run - menu
[ "$RC" -eq 0 ] || fail "menu listing failed"
[ "$(wc -l < "$OUT")" -ge 20 ] || fail "menu listing should expose the full provider catalog"
for g in official plan aggregator local; do
	grep -q "^${g}	" "$OUT" || fail "menu listing must contain group $g"
done
cut -f3 "$OUT" > "$WORK/refs.txt"
while read -r ref; do
	ocp info "$ref" >/dev/null 2>&1 || fail "menu ref $ref cannot be resolved by info"
done < "$WORK/refs.txt"
run - quick
[ "$RC" -eq 0 ] && [ -s "$OUT" ] || fail "quick setup list must not be empty"
run - verify
out_has "verified	1" "installed 2026.9.36 must be reported as catalog-verified"
run - info no-such:ref
[ "$RC" -ne 0 ] || fail "unknown method ref must be rejected"

# ── 2. 新增内置 provider: Key 走环境变量，保留原默认模型与其它配置 ──
write_baseline; log_reset
run "$KEY" apply-key "$BUILTIN_REF" --keep-default
[ "$RC" -eq 0 ] || { cat "$OUT" >&2; fail "apply-key for $BUILTIN_REF should succeed"; }
out_has "PRIMARY	keep/keep-model" "keep-default must restore the original default model"
out_lacks "$KEY" "backend output must not echo the API key"
log_assert "calls.some((c) => c.argv[0] === 'onboard' && c.env['$BUILTIN_ENV'] === KEY)" \
	"onboard must receive the key through $BUILTIN_ENV"
no_key_in_argv "onboard"
cfg_assert 'g("agents.defaults.model.primary") === "keep/keep-model"' "default model must be restored in config"
cfg_assert 'JSON.stringify(g("agents.defaults.model.fallbacks")) === JSON.stringify(["keep/keep-model-2","demo/old-model"])' \
	"fallbacks must be untouched by apply-key"
preserved "apply-key new"
auth_assert "a.profiles.some((p) => p.provider === '$BUILTIN_PROV' && p.key === KEY)" "new credential must be stored"

# ── 3. 已有凭据再次配置: 走 paste-api-key (stdin)，不重复 onboard，不新增 profile ──
log_reset
run "$KEY2" apply-key "$BUILTIN_REF" --model chosen-model
[ "$RC" -eq 0 ] || { cat "$OUT" >&2; fail "re-key should succeed"; }
log_assert "!calls.some((c) => c.argv[0] === 'onboard')" "existing credential must not be re-onboarded"
log_assert "calls.some((c) => c.argv.join(' ').startsWith('models auth paste-api-key --provider $BUILTIN_PROV') && c.stdin.split('\\n')[0] === KEY2)" \
	"re-key must use paste-api-key with the key on stdin"
no_key_in_argv "paste-api-key"
out_lacks "$KEY2" "backend output must not echo the rotated key"
out_has "PRIMARY	$BUILTIN_PROV/chosen-model" "user-selected model must become the default"
auth_assert "a.profiles.filter((p) => p.provider === '$BUILTIN_PROV').length === 1 && a.profiles.find((p) => p.provider === '$BUILTIN_PROV').key === KEY2" \
	"re-key must update the existing profile in place"
preserved "re-key"

# ── 4. 认证失败: 转述上游原因，不留半成品，即使上游回显 Key 也要脱敏 ──
write_baseline; log_reset
cp "$CFG" "$WORK/cfg.before"
set +e
printf '%s\n' "$KEY" | MOCK_ONBOARD_FAIL="Error: 401 Unauthorized - invalid api key" MOCK_ECHO_SECRET=1 \
	ocp apply-key "$BUILTIN_REF" --keep-default >"$OUT" 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "apply-key must fail when upstream rejects the key"
out_has "ERROR	Error: 401 Unauthorized - invalid api key" "auth failure must surface the real upstream reason"
out_lacks "$KEY" "a key echoed by upstream must be redacted from backend output"
cmp -s "$CFG" "$WORK/cfg.before" || fail "failed onboard must not modify the config"
auth_assert "!a.profiles.some((p) => p.provider === '$BUILTIN_PROV')" "failed onboard must not leave a credential behind"
run "" apply-key "$BUILTIN_REF"
[ "$RC" -ne 0 ] || fail "empty key must be rejected"
out_has "API Key 为空" "empty key must give a clear reason"

# ── 5. 外部插件: 未确认时不安装；确认后只安装目录登记的官方包 ──
PLUGIN_REF=zai:cn
write_baseline; log_reset
run "$KEY" apply-key "$PLUGIN_REF"
[ "$RC" -ne 0 ] || fail "plugin-backed provider must ask for confirmation first"
out_has "NEEDPLUGIN	@openclaw/zai-provider" "missing plugin must be reported"
log_assert "!calls.some((c) => c.argv[0] === 'plugins' && c.argv[1] === 'install') && !calls.some((c) => c.argv[0] === 'onboard')" \
	"nothing may be installed or written before the user confirms"
log_reset
run "$KEY" apply-key "$PLUGIN_REF" --install-plugin --keep-default
[ "$RC" -eq 0 ] || { cat "$OUT" >&2; fail "apply-key with confirmed plugin install should succeed"; }
log_assert "calls.some((c) => c.argv.join(' ') === 'plugins install @openclaw/zai-provider --accept-capabilities')" \
	"confirmed install must install exactly the catalog package"
no_key_in_argv "plugin flow"
# 插件已装 (按 id 匹配，name 为显示名) 时不再重复安装
log_reset
run - plugin-status "$PLUGIN_REF"
out_has "INSTALLED" "installed plugin must be detected by id even when name is a display name"
# 换区域 (中国站 → 国际站) 更新 Key 时同步 Base URL
log_reset
run "$KEY2" apply-key zai:global --keep-default
[ "$RC" -eq 0 ] || { cat "$OUT" >&2; fail "region switch re-key should succeed"; }
cfg_assert 'g("models.providers.zai.baseUrl") === "https://api.z.ai/api/paas/v4"' "region switch must update the provider base URL"
out_has "Base URL 已从" "region switch must be reported"
preserved "region switch"

# ── 6. 自定义 provider ──
write_baseline; log_reset
run "$KEY" apply-custom --id newp --base-url https://newp.example.invalid/v1/ --model new-model --compat anthropic
[ "$RC" -eq 0 ] || { cat "$OUT" >&2; fail "new custom provider should be created"; }
log_assert "calls.some((c) => c.argv[0] === 'onboard' && c.argv.includes('custom-api-key') && c.argv.includes('anthropic') && c.env.CUSTOM_API_KEY === KEY)" \
	"custom provider must be created via onboard with CUSTOM_API_KEY"
log_assert "calls.some((c) => c.argv.includes('https://newp.example.invalid/v1'))" "base URL trailing slash must be normalized"
no_key_in_argv "custom onboard"
cfg_assert 'g("agents.defaults.model.primary") === "keep/keep-model"' "new custom provider must not steal the default model unless asked"
preserved "custom new"

# 同 id 同地址: 只追加模型，不重复 onboard；空 Key + key-optional 不清除已有 Key
log_reset
run "" apply-custom --id demo --base-url https://demo.example.invalid/v1 --model added-model --key-optional --set-default
[ "$RC" -eq 0 ] || { cat "$OUT" >&2; fail "appending a model to an existing custom provider should succeed"; }
log_assert "!calls.some((c) => c.argv[0] === 'onboard')" "existing custom provider must not be re-onboarded"
cfg_assert 'g("models.providers.demo.apiKey") === "DEMO-SECRET"' "empty key must not clear the existing custom provider key"
cfg_assert 'g("models.providers.demo.models").map((m) => m.id).join(",") === "old-model,added-model"' "model must be appended, existing models kept"
cfg_assert 'g("agents.defaults.models")["demo/added-model"] !== undefined && g("agents.defaults.model.primary") === "demo/added-model"' \
	"appended model must be allow-listed and set as default when requested"
preserved "custom append"
[ -f "$CFG.luci-pre-write" ] || fail "direct config edits must keep a pre-write backup"
if cmp -s "$CFG.luci-pre-write" "$CFG"; then fail "pre-write backup must hold the previous config"; fi

# 同 id 不同地址: 拒绝且不改配置
cp "$CFG" "$WORK/cfg.before"
run "$KEY" apply-custom --id demo --base-url https://elsewhere.example.invalid/v1 --model x
[ "$RC" -ne 0 ] || fail "custom provider id clash with a different base URL must be rejected"
out_has "已存在且 Base URL 不同" "id clash must explain the conflict"
cmp -s "$CFG" "$WORK/cfg.before" || fail "rejected id clash must not modify the config"

# 非法输入
run "$KEY" apply-custom --id 'Bad_ID' --base-url https://x.invalid/v1 --model m
[ "$RC" -ne 0 ] || fail "invalid provider id must be rejected"
run "$KEY" apply-custom --id okid --base-url ftp://x.invalid --model m
[ "$RC" -ne 0 ] || fail "non-http base URL must be rejected"

# ── 7. fail-closed: 配置损坏 / 上游校验失败 ──
printf '{\n "models": { "providers": { "demo": { "baseUrl": "https://demo.example.invalid/v1", "apiKey": "DEMO-SECRET" } } },\n}\n' > "$CFG"
cp "$CFG" "$WORK/cfg.before"
run "$KEY" apply-custom --id demo --base-url https://demo.example.invalid/v1 --model m2
[ "$RC" -ne 0 ] || fail "writes must abort on an unparsable config"
out_has "不是合法 JSON" "corrupt config must be reported"
cmp -s "$CFG" "$WORK/cfg.before" || fail "corrupt config must stay byte-for-byte unchanged"
run - remove-provider demo
[ "$RC" -ne 0 ] || fail "remove-provider must abort on an unparsable config"
cmp -s "$CFG" "$WORK/cfg.before" || fail "corrupt config must stay unchanged after remove-provider"

write_baseline
cp "$CFG" "$WORK/cfg.before"
set +e
( MOCK_VALIDATE_FAIL=1 ocp apply-custom --id demo --base-url https://demo.example.invalid/v1 --model m3 --key-optional </dev/null ) >"$OUT" 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "write must fail when upstream config validate rejects it"
out_has "已回滚" "validation failure must report the rollback"
cmp -s "$CFG" "$WORK/cfg.before" || fail "config must be rolled back after a failed validate"

# ── 8. 模型发现: 实时 → --refresh → 缓存 → 无 ──
write_baseline
run - models "$BUILTIN_REF" --discover
[ "$RC" -eq 0 ] || fail "model discovery should succeed"
out_has "M	live-model-a	live" "live discovery results must be listed"
out_lacks "not-mine" "models of other providers must be filtered out"
out_has "DISCOVERY	live" "discovery source must be reported"
grep -q "^M	[^	]*	curated" "$OUT" || fail "curated presets must stay available alongside live results"
[ -f "$WORK/cache/$BUILTIN_PROV.json" ] || fail "live discovery must refresh the cache"

set +e
( MOCK_DISCOVERY=empty-then-refresh ocp models "$BUILTIN_REF" --discover </dev/null ) >"$OUT" 2>&1
set -e
out_has "M	live-model-b	live" "empty first listing must be retried with --refresh"

set +e
( MOCK_DISCOVERY=fail ocp models "$BUILTIN_REF" --discover </dev/null ) >"$OUT" 2>&1
set -e
out_has "DISCOVERY	cache	auth-rejected" "failed discovery must fall back to cache and report the auth rejection"
out_has "M	live-model-a	cache" "cached models must be offered when discovery fails"

rm -rf "$WORK/cache"
set +e
( MOCK_DISCOVERY=fail ocp models "$BUILTIN_REF" --discover </dev/null ) >"$OUT" 2>&1
set -e
out_has "DISCOVERY	none	auth-rejected" "no cache must be reported as source none"
grep -q "^M	[^	]*	curated" "$OUT" || fail "curated presets must remain when discovery and cache both fail"

# ── 9. 连通性测试 ──
write_baseline
printf '{ "profiles": [ { "id": "%s:default", "provider": "%s", "type": "api_key", "key": "X" } ] }\n' "$BUILTIN_PROV" "$BUILTIN_PROV" > "$STATE/mock-auth.json"
log_reset
run - probe "$BUILTIN_PROV"
[ "$RC" -eq 0 ] || { cat "$OUT" >&2; fail "probe via gateway should succeed"; }
out_has "OK	gateway" "probe must prefer the running gateway"
grep -q "^R	gw-model	ok	可用	123	$" "$OUT" || { cat "$OUT" >&2; fail "probe result must show model, status and latency"; }
log_assert "!calls.some((c) => c.argv.includes('--probe'))" "CLI probe must not run when the gateway answered"

set +e
( MOCK_PROBE_STATUS=auth ocp probe "$BUILTIN_PROV" </dev/null ) >"$OUT" 2>&1
set -e
grep -q "^R	gw-model	auth	认证失败.*	HTTP 401: invalid api key$" "$OUT" || { cat "$OUT" >&2; fail "auth failure must be reported with the upstream reason"; }

set +e
( MOCK_GATEWAY=down MOCK_PROBE_STATUS=billing ocp probe "$BUILTIN_PROV" </dev/null ) >"$OUT" 2>&1
set -e
out_has "OK	cli" "probe must fall back to the CLI when the gateway is down"
grep -q "^R	cli-model	billing	余额不足.*	HTTP 401: invalid api key$" "$OUT" || { cat "$OUT" >&2; fail "CLI probe must keep only the first error line"; }

set +e
( MOCK_GATEWAY=down MOCK_GATEWAY_RUNNING=1 ocp probe "$BUILTIN_PROV" </dev/null ) >"$OUT" 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "probe must fail when neither path works"
out_has "A Gateway is running" "probe failure must explain the real cause"
out_has "ECONNREFUSED" "probe failure must include the gateway error as well"

run - probe 'bad provider;rm'
[ "$RC" -ne 0 ] || fail "probe must reject invalid provider names"

# ── 10. 默认模型 / fallback / 删除 ──
write_baseline
run - set-default notaref
[ "$RC" -ne 0 ] || fail "set-default must require provider/model"
run - set-default keep/keep-model-2
[ "$RC" -eq 0 ] || fail "set-default should succeed"
cfg_assert 'g("agents.defaults.model.primary") === "keep/keep-model-2"' "set-default must update the primary model"
run - fallbacks add demo/old-model
run - fallbacks list
out_has "F	keep/keep-model-2" "fallback list must show existing entries"
run - configured-models
out_has "keep/keep-model" "configured models must include allow-listed refs"
out_has "demo/old-model" "configured models must include models.providers entries"

run - set-default demo/old-model
run - remove-provider demo
[ "$RC" -ne 0 ] || fail "removing the provider of the default model must be refused"
out_has "正在使用该 provider" "refusal must explain why"
run - set-default keep/keep-model
run - remove-provider demo
[ "$RC" -eq 0 ] || { cat "$OUT" >&2; fail "remove-provider should succeed"; }
out_has "NOTE	已同时移除 fallback: demo/old-model" "removed fallbacks must be reported"
cfg_assert '!g("models.providers.demo") && !("demo/old-model" in g("agents.defaults.models")) && !g("agents.defaults.model.fallbacks").includes("demo/old-model")' \
	"remove-provider must drop the provider, its allow-list entries and fallbacks"
preserved "remove-provider"

run - remove-auth nope:default
[ "$RC" -ne 0 ] || fail "remove-auth must refuse unknown profiles"
log_reset
run - remove-auth other:default
[ "$RC" -eq 0 ] || fail "remove-auth should log out an existing profile"
log_assert "calls.some((c) => c.argv.join(' ') === 'models auth logout other:default --yes')" "remove-auth must use the official logout"

# ── 11. 状态概览不泄露凭据 ──
write_baseline
run - status
out_has "PROFILE	other:default	other	api_key" "status must list credential profiles"
out_has "PROVIDER	keep	https://keep.example.invalid/v1	openai-completions	key	keep-model,keep-model-2" "status must summarize custom providers"
out_lacks "KEEP-SECRET" "status must not print custom provider keys"
out_lacks "OTHER-SECRET" "status must not print stored credentials"
out_lacks "sk-***" "status must not print upstream masked labels"

# ── 12. 退役文件 ──
if find "$WORK/data" -name 'auth-profiles.json' | grep -q .; then
	fail "backend must never write the retired auth-profiles.json"
fi

echo "ok"
