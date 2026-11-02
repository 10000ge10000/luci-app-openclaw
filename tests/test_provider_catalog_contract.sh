#!/bin/sh
# 模型提供商目录 (provider-catalog.json) 与两套菜单的一致性契约。
#
# 背景: 旧版两套菜单各自硬编码 provider / 模型列表并严重腐坏 (大量模型 ID 在上游已不存在，
# 「粉丝专享 API」等入口停运后仍残留)。v2.3 起:
#   1. provider-catalog.json 是两套菜单共读的唯一目录，记录核实所依据的上游版本
#   2. 所有写入经由 oc-providers.js 走官方 CLI，菜单不直接拼 onboard 参数
#   3. 菜单结构 (按键、文案、分组) 两边一致
#   4. 精选模型之外保留动态发现与手动输入
# 本测试锁定这些约束，防止回退成各自维护的硬编码列表。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SHARE="$REPO_ROOT/root/usr/share/openclaw"
CATALOG="$SHARE/provider-catalog.json"
COMPAT="$SHARE/openclaw-compat.json"
SH_CONFIG="$SHARE/oc-config.sh"
JS_CONFIG="$SHARE/oc-config-interactive.js"
BACKEND="$SHARE/oc-providers.js"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

for f in "$CATALOG" "$COMPAT" "$SH_CONFIG" "$JS_CONFIG" "$BACKEND"; do
	[ -f "$f" ] || fail "missing $f"
done
[ ! -e "$SHARE/model-presets.json" ] || fail "retired model-presets.json must be removed (replaced by provider-catalog.json)"

# ── 两套菜单只经由共享后端 ──
grep -Fq "require('./oc-providers')" "$JS_CONFIG" || fail "interactive menu must use oc-providers.js"
grep -Fq 'OC_PROVIDERS_JS=' "$SH_CONFIG" || fail "shell menu must use oc-providers.js"
for f in "$SH_CONFIG" "$JS_CONFIG"; do
	if grep -nE -- "--auth-choice[\"' ]+[a-z]" "$f" | grep -v 'skip' ; then
		fail "$(basename "$f") must not hardcode provider onboard calls (use oc-providers.js)"
	fi
	grep -q 'provider-catalog.json\|oc-providers' "$f" || fail "$(basename "$f") must reference the shared catalog/backend"
done

# 手动输入、动态发现与「列表 ≠ 权限」提示两边都要有
grep -Fq '手动输入模型 ID' "$JS_CONFIG" || fail "interactive menu must keep manual model entry"
grep -Fq '手动输入模型 ID' "$SH_CONFIG" || fail "shell menu must keep manual model entry"
grep -Fq -- '--discover' "$SH_CONFIG" || fail "shell menu must offer live model discovery"
grep -Fq 'providers.discoverModels(' "$JS_CONFIG" || fail "interactive menu must offer live model discovery"
grep -q '不代表.*有权\|不等于.*权限\|≠.*权限' "$JS_CONFIG" || fail "interactive menu must state that listed models are not proof of access"
grep -q '不代表.*有权\|不等于.*权限\|≠.*权限' "$SH_CONFIG" || fail "shell menu must state that listed models are not proof of access"

# 真机实测: 不暂停 stdin 时交互式菜单退出后进程不结束，Web 终端停在「再见」
grep -Fq 'main().then(() => process.stdin.pause())' "$JS_CONFIG" || fail "interactive menu must release stdin on exit"

command -v node >/dev/null 2>&1 || { echo "ok (static only: no node interpreter available)"; exit 0; }

# ── 目录结构与内容校验 ──
node - "$CATALOG" "$COMPAT" <<'EOF' || fail "provider-catalog.json failed validation"
const fs = require('fs');
const cat = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const compat = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const errs = [];
const err = (m) => errs.push(m);

if (cat.schema !== 1) err('schema must be 1');
if (!/^\d{4}-\d{2}-\d{2}$/.test(cat.verifiedAt || '')) err('verifiedAt must be a YYYY-MM-DD date');
// 目录核实版本必须覆盖兼容矩阵中每个通道的已验证版本，避免「装了已验证版本，菜单却未核实」
for (const [name, ch] of Object.entries(compat.channels)) {
  if (!(cat.verifiedWith || []).includes(ch.verified)) err(`verifiedWith must include ${name} verified version ${ch.verified}`);
}
if (!/^https:\/\/docs\.openclaw\.ai\//.test(cat.docsBase || '')) err('docsBase must point to the official docs');

const groupIds = (cat.groups || []).map((g) => g.id);
for (const g of ['official', 'plan', 'aggregator', 'local']) if (!groupIds.includes(g)) err(`missing group ${g}`);

const MODEL_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,199}$/;
const ENV_RE = /^[A-Z][A-Z0-9_]*$/;
const TYPES = new Set(['api-key', 'oauth', 'custom', 'local']);
const COMPAT = new Set(['openai', 'openai-responses', 'anthropic']);
const ids = new Set();
const refs = new Set();
for (const p of cat.providers || []) {
  if (!/^[a-z0-9][a-z0-9-]*$/.test(p.id || '')) err(`bad provider id ${p.id}`);
  if (ids.has(p.id)) err(`duplicate provider id ${p.id}`);
  ids.add(p.id);
  if (!p.label) err(`${p.id}: missing label`);
  if (!groupIds.includes(p.group)) err(`${p.id}: unknown group ${p.group}`);
  if (p.plugin && !/^@openclaw\/[a-z0-9-]+-provider$/.test(p.plugin)) err(`${p.id}: plugin must be an official @openclaw/*-provider package`);
  if (p.keyUrl && !/^https:\/\//.test(p.keyUrl)) err(`${p.id}: keyUrl must be https`);
  if (!Array.isArray(p.methods) || !p.methods.length) { err(`${p.id}: no methods`); continue; }
  const mids = new Set();
  for (const m of p.methods) {
    const where = `${p.id}:${m.id}`;
    refs.add(where);
    if (mids.has(m.id)) err(`${where}: duplicate method id`);
    mids.add(m.id);
    if (!TYPES.has(m.type)) err(`${where}: bad type ${m.type}`);
    if (!m.label) err(`${where}: missing label`);
    if (m.baseUrl && !/^https:\/\//.test(m.baseUrl)) err(`${where}: baseUrl must be https`);
    if (m.type === 'api-key') {
      // 上游 auth-choice 名称大小写不统一 (如 anthropic 为 apiKey)，按实测原样保存
      if (!/^[A-Za-z0-9-]+$/.test(m.authChoice || '')) err(`${where}: api-key needs authChoice`);
      if (!ENV_RE.test(m.env || '')) err(`${where}: api-key needs env var name`);
      if (!m.provider) err(`${where}: api-key needs runtime provider id`);
      if (m.defaultModel && !MODEL_ID_RE.test(m.defaultModel)) err(`${where}: bad defaultModel`);
    }
    if (m.type === 'oauth') {
      if (!Array.isArray(m.loginArgs) || !m.loginArgs.length) err(`${where}: oauth needs loginArgs`);
      // 没有真实账号验证过的登录流程必须如实标注
      if (!m.unverified) err(`${where}: oauth flows not verified with a real account must be marked unverified`);
    }
    if (m.type === 'custom') {
      if (!COMPAT.has(m.compatibility)) err(`${where}: custom needs compatibility openai|openai-responses|anthropic`);
      if (m.baseUrlDefault && !/^https?:\/\//.test(m.baseUrlDefault)) err(`${where}: bad baseUrlDefault`);
    }
  }
}
for (const q of cat.quick || []) if (!refs.has(q)) err(`quick entry ${q} does not resolve`);
if ((cat.quick || []).length < 4) err('quick setup should list the common providers');
for (const [key, list] of Object.entries(cat.models || {})) {
  if (!Array.isArray(list)) { err(`models.${key} must be an array`); continue; }
  const seen = new Set();
  for (const m of list) {
    if (!MODEL_ID_RE.test(m.id || '')) err(`models.${key}: bad id ${m.id}`);
    if (seen.has(m.id)) err(`models.${key}: duplicate ${m.id}`);
    seen.add(m.id);
  }
}
// 已确认在上游不存在或已停运的条目不得回到目录
const STALE = ['gpt-5-mini', 'claude-sonnet-4-20250514', 'deepseek-r1', 'Qwen2.5-72B-Instruct', 'glm-4-9b-chat', 'yiwanai', '910501'];
const raw = fs.readFileSync(process.argv[2], 'utf8');
for (const s of STALE) if (raw.includes(s)) err(`stale entry ${s} found in catalog`);
if (errs.length) { console.error(errs.join('\n')); process.exit(1); }
EOF

# ── 两套菜单结构一致 (按键、文案) ──
node - "$JS_CONFIG" "$SH_CONFIG" <<'EOF' || fail "interactive and shell model menus have drifted apart"
const fs = require('fs');
const js = fs.readFileSync(process.argv[2], 'utf8');
const sh = fs.readFileSync(process.argv[3], 'utf8');
const jsBody = (js.match(/async function showModelMenu\(\)[\s\S]*?\n}\n/) || [''])[0];
const shBody = (sh.match(/\nconfigure_model\(\) \{[\s\S]*?\n}\n/) || [''])[0];
if (!jsBody || !shBody) { console.error('cannot locate model menus'); process.exit(1); }
const jsItems = [...jsBody.matchAll(/\{ key: '([0-9a-z])', label: '([^']+)'/g)].map((m) => [m[1], m[2]]);
const shItems = [...shBody.matchAll(/\$\{CYAN\}([0-9a-z])\)\$\{NC\} ([^"$]+)/g)].map((m) => [m[1], m[2].trim()]);
const errs = [];
const jsKeys = jsItems.map((x) => x[0]).sort().join(' ');
const shKeys = shItems.map((x) => x[0]).sort().join(' ');
if (jsKeys !== shKeys) errs.push(`keys differ: js=[${jsKeys}] sh=[${shKeys}]`);
for (const [k, label] of jsItems) {
  const s = shItems.find((x) => x[0] === k);
  if (s && !s[1].startsWith(label)) errs.push(`key ${k}: js "${label}" vs sh "${s[1]}"`);
}
// Shell 的 case 必须覆盖所有打印出来的按键
const cases = new Set([...shBody.matchAll(/^\t\t\t([0-9a-z])(?:\|[A-Z])?\)/gm)].map((m) => m[1]));
for (const [k] of shItems) if (!cases.has(k)) errs.push(`shell menu prints ${k}) but has no case branch`);
// 分组按键调用同一组目录分组
for (const g of ['official', 'plan', 'aggregator', 'local']) {
  if (!jsBody.includes(`group:${g}`)) errs.push(`js menu missing group ${g}`);
  if (!shBody.includes(`oc_pick_method ${g}`)) errs.push(`shell menu missing group ${g}`);
}
if (errs.length) { console.error(errs.join('\n')); process.exit(1); }
EOF

echo "ok"
