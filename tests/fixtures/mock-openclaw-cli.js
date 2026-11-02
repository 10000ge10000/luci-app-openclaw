#!/usr/bin/env node
/**
 * 测试用 OpenClaw CLI 替身 (仅覆盖 oc-providers.js 用到的子命令)。
 *
 * 行为依据 2026.9.36 / 2026.10.9 实测:
 *   - 凭据存于认证库 (此处用 $OPENCLAW_STATE_DIR/mock-auth.json 模拟 openclaw.sqlite)，
 *     openclaw.json 不含内置 provider 的 Key
 *   - onboard 会把默认模型改成该 provider 的默认模型，其余配置不动
 *   - 已有 provider id 再次 onboard custom-api-key 会失败
 *   - Gateway 运行时 `models status --probe` 被拒绝
 *
 * 每次调用向 $MOCK_OC_LOG 追加一行 JSON: { argv, env: {名称: 值}, stdin }，
 * 测试据此检查 Key 只经由环境变量或 stdin 传递、从不出现在 argv。
 *
 * 可用环境变量控制故障:
 *   MOCK_ONBOARD_FAIL=<消息>   onboard 失败并输出该消息
 *   MOCK_PASTE_FAIL=<消息>     paste-api-key 失败
 *   MOCK_ECHO_SECRET=1         失败时把收到的 Key 回显到 stderr (检验脱敏)
 *   MOCK_VALIDATE_FAIL=1       config validate 失败
 *   MOCK_DISCOVERY=fail|empty-then-refresh|static
 *   MOCK_GATEWAY=down          gateway call 失败
 *   MOCK_GATEWAY_RUNNING=1     models status --probe 报 Gateway 正在运行
 *   MOCK_PROBE_STATUS=ok|auth|rate_limit|billing
 */
'use strict';

const fs = require('fs');
const path = require('path');

const argv = process.argv.slice(2);
const STATE = process.env.OPENCLAW_STATE_DIR;
const CONFIG = process.env.OPENCLAW_CONFIG_PATH;
const AUTH = path.join(STATE, 'mock-auth.json');
const PLUGINS = path.join(STATE, 'mock-plugins.json');
const SECRET_ENV = /(_API_KEY|_TOKEN|_SECRET)$/;

function readStdin() {
  if (process.stdin.isTTY) return '';
  try { return fs.readFileSync(0, 'utf8'); } catch { return ''; }
}
const needsStdin = argv[0] === 'models' && argv[1] === 'auth' && argv[2] === 'paste-api-key';
const stdin = needsStdin ? readStdin() : '';

if (process.env.MOCK_OC_LOG) {
  const env = {};
  for (const [k, v] of Object.entries(process.env)) if (SECRET_ENV.test(k)) env[k] = v;
  fs.appendFileSync(process.env.MOCK_OC_LOG, JSON.stringify({ argv, env, stdin }) + '\n');
}

const readJson = (f, dflt) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return dflt; } };
const writeJson = (f, d) => fs.writeFileSync(f, JSON.stringify(d, null, 2) + '\n');
const out = (s) => process.stdout.write(typeof s === 'string' ? s + '\n' : JSON.stringify(s) + '\n');
const die = (msg, secret) => {
  process.stderr.write(msg + (secret && process.env.MOCK_ECHO_SECRET === '1' ? ` (received key ${secret})` : '') + '\n');
  process.exit(1);
};
const flag = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
const has = (name) => argv.includes(name);

function config() {
  if (!fs.existsSync(CONFIG)) return {};
  return JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
}
function ensureDefaults(c) {
  c.agents = c.agents || {};
  c.agents.defaults = c.agents.defaults || {};
  c.agents.defaults.model = c.agents.defaults.model || {};
  c.agents.defaults.models = c.agents.defaults.models || {};
  return c;
}
function setPrimary(c, ref) {
  ensureDefaults(c);
  c.agents.defaults.model.primary = ref;
  if (!c.agents.defaults.models[ref]) c.agents.defaults.models[ref] = {};
}
function catalogMethodByChoice(choice) {
  const cat = readJson(process.env.OC_PROVIDER_CATALOG, { providers: [] });
  for (const p of cat.providers) for (const m of p.methods) if (m.authChoice === choice) return m;
  return null;
}
function auth() { return readJson(AUTH, { profiles: [] }); }

const [a0, a1, a2] = argv;

if (a0 === 'config' && a1 === 'validate') {
  let c;
  try { c = config(); } catch (e) { die(`Error: Config invalid: ${e.message}`); }
  if (process.env.MOCK_VALIDATE_FAIL === '1') die('Error: Config invalid: models.providers.demo.models.0: unknown key "bogus"');
  if (c.gateway && c.gateway.controlUi && 'allowInsecureAuth' in c.gateway.controlUi) die('Error: Config invalid: gateway.controlUi.allowInsecureAuth is not allowed');
  out('Config valid');
  process.exit(0);
}

if (a0 === 'models' && a1 === 'auth' && a2 === 'list') {
  out({ profiles: auth().profiles.map((p) => ({ id: p.id, provider: p.provider, type: p.type, label: `${p.id} (sk-***)` })) });
  process.exit(0);
}

if (a0 === 'models' && a1 === 'auth' && a2 === 'paste-api-key') {
  const key = stdin.split('\n')[0];
  if (process.env.MOCK_PASTE_FAIL) die(process.env.MOCK_PASTE_FAIL, key);
  const a = auth();
  const id = flag('--profile-id');
  const p = a.profiles.find((x) => x.id === id);
  if (!p) die(`Error: profile ${id} not found`);
  p.key = key;
  writeJson(AUTH, a);
  out(`Updated ${id}`);
  process.exit(0);
}

if (a0 === 'models' && a1 === 'auth' && a2 === 'logout') {
  const a = auth();
  const id = argv[3];
  const before = a.profiles.length;
  a.profiles = a.profiles.filter((p) => p.id !== id);
  if (a.profiles.length === before) die(`Error: unknown profile ${id}`);
  writeJson(AUTH, a);
  out(`Logged out ${id}`);
  process.exit(0);
}

if (a0 === 'onboard') {
  const choice = flag('--auth-choice');
  const c = config();
  if (choice === 'custom-api-key') {
    const id = flag('--custom-provider-id');
    if (c.models && c.models.providers && c.models.providers[id]) die('Error: Replacement credential saved but inactive');
    const key = process.env.CUSTOM_API_KEY || '';
    if (process.env.MOCK_ONBOARD_FAIL) die(process.env.MOCK_ONBOARD_FAIL, key);
    c.models = c.models || {};
    c.models.providers = c.models.providers || {};
    const compat = flag('--custom-compatibility');
    c.models.providers[id] = {
      baseUrl: flag('--custom-base-url'),
      api: compat === 'anthropic' ? 'anthropic-messages' : compat === 'openai-responses' ? 'openai-responses' : 'openai-completions',
      ...(key ? { apiKey: key } : {}),
      models: [{ id: flag('--custom-model-id'), name: flag('--custom-model-id'), input: has('--custom-image-input') ? ['text', 'image'] : ['text'] }],
    };
    setPrimary(c, `${id}/${flag('--custom-model-id')}`);
    writeJson(CONFIG, c);
    out('Onboarding complete');
    process.exit(0);
  }
  if (choice === 'ollama') {
    if (process.env.MOCK_ONBOARD_FAIL) die(process.env.MOCK_ONBOARD_FAIL);
    c.models = c.models || {};
    c.models.providers = c.models.providers || {};
    c.models.providers.ollama = { baseUrl: flag('--custom-base-url'), api: 'ollama', models: [{ id: flag('--custom-model-id') }] };
    setPrimary(c, `ollama/${flag('--custom-model-id')}`);
    writeJson(CONFIG, c);
    out('Onboarding complete');
    process.exit(0);
  }
  if (choice === 'skip') { out('Onboarding complete'); process.exit(0); }
  const m = catalogMethodByChoice(choice);
  if (!m) die(`Error: unknown auth choice ${choice}`);
  const key = process.env[m.env] || '';
  if (!key) die(`Error: ${m.env} is required for --auth-choice ${choice}`);
  if (process.env.MOCK_ONBOARD_FAIL) die(process.env.MOCK_ONBOARD_FAIL, key);
  const a = auth();
  const prov = m.authProvider || m.provider;
  a.profiles.push({ id: `${prov}:default`, provider: prov, type: 'api_key', key });
  writeJson(AUTH, a);
  if (m.baseUrl) {
    c.models = c.models || {};
    c.models.providers = c.models.providers || {};
    c.models.providers[m.provider] = Object.assign(c.models.providers[m.provider] || {}, { baseUrl: m.baseUrl });
  }
  setPrimary(c, `${m.provider}/${m.defaultModel || 'default-model'}`);
  writeJson(CONFIG, c);
  out('Onboarding complete');
  process.exit(0);
}

if (a0 === 'models' && a1 === 'set') {
  const c = config();
  setPrimary(c, argv[2]);
  writeJson(CONFIG, c);
  out(`Default model: ${argv[2]}`);
  process.exit(0);
}

if (a0 === 'models' && a1 === 'fallbacks') {
  const c = ensureDefaults(config());
  const fb = c.agents.defaults.model.fallbacks = c.agents.defaults.model.fallbacks || [];
  if (a2 === 'list') { out({ fallbacks: fb }); process.exit(0); }
  if (a2 === 'add') { if (!fb.includes(argv[3])) fb.push(argv[3]); }
  else if (a2 === 'remove') { const i = fb.indexOf(argv[3]); if (i < 0) die(`Error: ${argv[3]} is not a fallback`); fb.splice(i, 1); }
  else if (a2 === 'clear') fb.length = 0;
  writeJson(CONFIG, c);
  out('OK');
  process.exit(0);
}

if (a0 === 'models' && a1 === 'list') {
  const p = flag('--provider');
  const mode = process.env.MOCK_DISCOVERY || 'static';
  if (mode === 'fail') {
    process.stderr.write(`[model-discovery] authentication was rejected for ${p}\n`);
    out({ ok: false, error: { message: `Model discovery failed for ${p}: HTTP 401` } });
    process.exit(1);
  }
  if (mode === 'empty-then-refresh' && !has('--refresh')) { out({ models: [] }); process.exit(0); }
  out({ models: [
    { key: `${p}/live-model-a`, name: 'Live A', input: 'text', contextWindow: 128000, available: true },
    { key: `${p}/live-model-b`, name: 'Live B', input: 'text+image', contextWindow: 64000, available: true },
    { key: `other/not-mine`, name: 'Other', available: true },
  ] });
  process.exit(0);
}

if (a0 === 'models' && a1 === 'status') {
  const c = ensureDefaults(config());
  if (has('--probe')) {
    if (process.env.MOCK_GATEWAY_RUNNING === '1') die('Error: A Gateway is running for this state directory; stop it before probing');
    const p = flag('--probe-provider');
    const st = process.env.MOCK_PROBE_STATUS || 'ok';
    out({ auth: { probes: { results: [{ profileId: `${p}:default`, label: `${p}:default · cli-model`, status: st, latencyMs: 456, error: st === 'ok' ? '' : 'HTTP 401: invalid api key\nstack...' }] } } });
    process.exit(0);
  }
  const provs = {};
  for (const p of auth().profiles) {
    provs[p.provider] = provs[p.provider] || { provider: p.provider, effective: { kind: 'profiles' }, profiles: { count: 0, apiKey: 0, oauth: 0, token: 0 } };
    provs[p.provider].profiles.count++;
    provs[p.provider].profiles.apiKey++;
  }
  out({ defaultModel: c.agents.defaults.model.primary || null, resolvedDefault: c.agents.defaults.model.primary || null,
    fallbacks: c.agents.defaults.model.fallbacks || [], auth: { providers: Object.values(provs), missingProvidersInUse: [], unusableProfiles: [] } });
  process.exit(0);
}

if (a0 === 'plugins' && a1 === 'list') {
  out({ plugins: readJson(PLUGINS, []) });
  process.exit(0);
}

if (a0 === 'plugins' && a1 === 'install') {
  const pkg = argv[2];
  const list = readJson(PLUGINS, []);
  list.push({ id: pkg.replace(/^@openclaw\//, '').replace(/-provider$/, ''), name: 'Display Name', enabled: true, version: '2026.9.36' });
  writeJson(PLUGINS, list);
  out(`Installed ${pkg}`);
  process.exit(0);
}

if (a0 === 'gateway' && a1 === 'call' && a2 === 'models.probe') {
  if (process.env.MOCK_GATEWAY === 'down') die('Error: gateway closed (1006): connect ECONNREFUSED 127.0.0.1:18789');
  const params = JSON.parse(flag('--params'));
  const st = process.env.MOCK_PROBE_STATUS || 'ok';
  const a = auth().profiles.filter((p) => p.provider === params.provider);
  out({ provider: params.provider, status: st, results: a.map((p) => ({
    profileId: p.id, label: `${p.id} · gw-model`, status: st, latencyMs: 123,
    error: st === 'ok' ? '' : st === 'auth' ? 'HTTP 401: invalid api key' : 'HTTP 429: slow down',
  })) });
  process.exit(0);
}

die(`mock-openclaw: unsupported command: ${argv.join(' ')}`);
