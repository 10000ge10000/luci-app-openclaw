#!/usr/bin/env node
/**
 * ============================================================================
 * oc-providers.js — AI 模型提供商配置后端
 * ============================================================================
 *
 * 交互式菜单 (oc-config-interactive.js) 直接 require 本模块，
 * 传统 Shell 菜单 (oc-config.sh) 通过命令行子命令调用，两边共享同一套逻辑与
 * 同一份目录 (provider-catalog.json)，保证功能一致。
 *
 * 设计原则:
 *   1. 凭据写入只走上游官方路径:
 *      - API Key: `openclaw onboard --non-interactive --auth-choice <choice>`，
 *        Key 通过 provider 对应的环境变量传入 (不进 argv、不进进程列表)，
 *        上游把 Key 写入 state/openclaw.sqlite 认证库，openclaw.json 不含 Key。
 *      - OAuth / 设备码: 透传上游交互命令。
 *      - 不再写 auth-profiles.json: OpenClaw 2026.9.x 起该文件已退役，
 *        写入会触发 AUTH_PROFILE_MIGRATION_REQUIRED 并使该 provider 不可用。
 *   2. 不覆盖用户已有配置: onboard 只新增 provider / 认证 / 模型白名单，
 *      但会改默认模型，因此执行前记录原默认模型，用户未选择「设为默认」时恢复。
 *      (已在 2026.9.36 / 2026.10.9 上用含网关、渠道、自定义 provider、
 *       fallback 的配置实测: 其余字段不变。)
 *   3. 「能查到模型」≠「账号有权调用」: 模型列表只说明上游登记过，
 *      调用权限只能通过连通性测试 (models status --probe) 确认。
 *   4. 不在任何输出中回显 Key: 上游输出中的掩码标签也一律不展示。
 *   5. 失败时原样转述上游的真实原因，不做伪成功。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

// ═══════════════════════════════════════════════════════════════════════════
// 路径 (与 oc-config.sh / oc-config-interactive.js 保持一致)
// ═══════════════════════════════════════════════════════════════════════════

const OC_BASE_PATH = process.env.OC_BASE_PATH || '/opt';
const OC_INSTALL_PATH = process.env.OC_INSTALL_PATH || `${OC_BASE_PATH}/openclaw`;
const NODE_BASE = process.env.NODE_BASE || `${OC_INSTALL_PATH}/node`;
const OC_GLOBAL = process.env.OC_GLOBAL || `${OC_INSTALL_PATH}/global`;
const OC_DATA = process.env.OC_DATA || `${OC_INSTALL_PATH}/data`;
const OC_STATE_DIR = process.env.OPENCLAW_STATE_DIR || `${OC_DATA}/.openclaw`;
const CONFIG_FILE = process.env.OPENCLAW_CONFIG_PATH || `${OC_STATE_DIR}/openclaw.json`;
const PERMISSIONS_HELPER = '/usr/libexec/openclaw-permissions.sh';
const CATALOG_FILE = process.env.OC_PROVIDER_CATALOG || path.join(__dirname, 'provider-catalog.json');
const MODEL_CACHE_DIR = process.env.OC_MODEL_CACHE_DIR || `${OC_DATA}/.cache/luci-models`;
const CONFIG_BACKUP_SUFFIX = '.luci-pre-write';

// 超时: OpenWrt 上 CLI 冷启动较慢 (实测 x86 软路由 5~15 秒)，留足余量但不让菜单无限卡住
const T_QUICK = 60 * 1000;
const T_ONBOARD = 180 * 1000;
const T_PLUGIN = 600 * 1000;
const T_PROBE = 120 * 1000;

const ONBOARD_FLAGS = [
  '--non-interactive', '--accept-risk', '--mode', 'local',
  '--skip-daemon', '--skip-health', '--skip-channels', '--skip-skills', '--skip-search', '--skip-hooks',
];

function nodeBin() {
  const p = process.env.NODE_BIN || `${NODE_BASE}/bin/node`;
  return fs.existsSync(p) ? p : process.execPath;
}

function findOpenClawEntry() {
  if (process.env.OC_ENTRY && fs.existsSync(process.env.OC_ENTRY)) return process.env.OC_ENTRY;
  const candidates = [
    `${OC_GLOBAL}/lib/node_modules/openclaw/openclaw.mjs`,
    `${OC_GLOBAL}/node_modules/openclaw/openclaw.mjs`,
    `${NODE_BASE}/lib/node_modules/openclaw/openclaw.mjs`,
  ];
  for (const p of candidates) if (fs.existsSync(p)) return p;
  return null;
}

function installedOpenClawVersion() {
  const entry = findOpenClawEntry();
  if (!entry) return null;
  try {
    return JSON.parse(fs.readFileSync(path.join(path.dirname(entry), 'package.json'), 'utf8')).version || null;
  } catch {
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 目录
// ═══════════════════════════════════════════════════════════════════════════

let catalogCache = null;

function loadCatalog() {
  if (catalogCache) return catalogCache;
  const raw = fs.readFileSync(CATALOG_FILE, 'utf8');
  const cat = JSON.parse(raw);
  if (!cat || cat.schema !== 1 || !Array.isArray(cat.providers) || !Array.isArray(cat.groups)) {
    throw new Error(`provider 目录格式不正确: ${CATALOG_FILE}`);
  }
  catalogCache = cat;
  return cat;
}

/** 解析 "providerId:methodId" */
function findMethod(ref) {
  const cat = loadCatalog();
  const [pid, mid] = String(ref || '').split(':');
  const provider = cat.providers.find((p) => p.id === pid);
  if (!provider) return null;
  const method = mid
    ? provider.methods.find((m) => m.id === mid)
    : (provider.methods.length === 1 ? provider.methods[0] : null);
  if (!method) return null;
  return { provider, method, ref: `${provider.id}:${method.id}` };
}

/** 菜单用的扁平条目列表 (两套菜单共用，保证顺序与文案一致) */
function menuEntries() {
  const cat = loadCatalog();
  const out = [];
  for (const g of cat.groups) {
    for (const p of cat.providers.filter((x) => x.group === g.id)) {
      out.push({
        group: g.id,
        groupLabel: g.label,
        id: p.id,
        label: p.label,
        plugin: p.plugin || '',
        methods: p.methods.map((m) => ({ ref: `${p.id}:${m.id}`, label: m.label, type: m.type })),
      });
    }
  }
  return out;
}

function quickEntries() {
  const cat = loadCatalog();
  return (cat.quick || []).map((ref) => {
    const f = findMethod(ref);
    if (!f) return null;
    const label = f.provider.methods.length > 1 ? `${f.provider.label} — ${f.method.label}` : f.provider.label;
    return { ref: f.ref, label, type: f.method.type };
  }).filter(Boolean);
}

function docsUrl(provider) {
  const cat = loadCatalog();
  return provider.docs ? `${cat.docsBase}${provider.docs}` : '';
}

/** 当前安装版本是否在目录核实范围内 */
function catalogVerification() {
  const cat = loadCatalog();
  const v = installedOpenClawVersion();
  return { installed: v, verifiedWith: cat.verifiedWith, verified: !!v && cat.verifiedWith.includes(v), verifiedAt: cat.verifiedAt };
}

function curatedModels(method) {
  const cat = loadCatalog();
  const key = method.models || method.provider;
  return (cat.models[key] || []).map((m) => ({ ...m }));
}

// ═══════════════════════════════════════════════════════════════════════════
// 运行 OpenClaw CLI
// ═══════════════════════════════════════════════════════════════════════════

function isRoot() {
  return typeof process.getuid === 'function' && process.getuid() === 0;
}

/** root 身份下返回 openclaw 服务用户的 { uid, gid }，否则 null */
function serviceUser() {
  if (!isRoot()) return null;
  try {
    const line = fs.readFileSync('/etc/passwd', 'utf8').split('\n').find((l) => l.startsWith('openclaw:'));
    if (!line) return null;
    const f = line.split(':');
    const uid = Number(f[2]);
    const gid = Number(f[3]);
    return Number.isInteger(uid) && Number.isInteger(gid) && uid > 0 ? { uid, gid } : null;
  } catch {
    return null;
  }
}

function shq(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

function ocEnv() {
  return {
    OPENCLAW_HOME: OC_DATA,
    OPENCLAW_STATE_DIR: OC_STATE_DIR,
    OPENCLAW_CONFIG_PATH: CONFIG_FILE,
    HOME: OC_DATA,
    NODE_ICU_DATA: `${NODE_BASE}/share/icu`,
  };
}

function fixPermissions() {
  if (!isRoot()) return;
  try { spawnSync('chown', ['openclaw:openclaw', CONFIG_FILE], { stdio: 'ignore' }); } catch {}
  try {
    if (fs.existsSync(PERMISSIONS_HELPER)) {
      spawnSync(PERMISSIONS_HELPER, ['fix-state', OC_STATE_DIR], { stdio: 'ignore', timeout: 30000 });
    }
  } catch {}
}

/**
 * 运行 openclaw 子命令。
 *
 * root 身份下改以 openclaw 服务用户执行: OpenClaw 的插件安全检查按进程 uid
 * 校验插件目录属主，root 运行可能把 openclaw 属主的插件判为 suspicious
 * ownership 并清理相关配置 (oc-config.sh 的 oc_doctor_as_openclaw 同理)。
 * 用 spawn 的 uid/gid 选项降权，不依赖 su: Kwrt 等固件的 BusyBox 没有 su / runuser。
 *
 * 秘密值通过 opts.secretEnv = { NAME: value } 传入: 经由 stdin 交给子 shell
 * 再 export，不出现在任何进程的 argv 中。
 */
function runOpenClaw(args, opts = {}) {
  const entry = findOpenClawEntry();
  if (!entry) return { status: 127, stdout: '', stderr: 'OpenClaw 未安装 (找不到 openclaw.mjs)', error: 'not-installed' };
  const node = nodeBin();
  const env = { ...process.env, ...ocEnv() };
  const secret = opts.secretEnv || null;
  const secretName = secret ? Object.keys(secret)[0] : null;
  if (secretName && !/^[A-Z][A-Z0-9_]*$/.test(secretName)) throw new Error(`非法环境变量名: ${secretName}`);

  const asUser = serviceUser();
  const stdio = opts.interactive ? 'inherit' : ['pipe', 'pipe', 'pipe'];

  // 统一构造: sh -c '<读取秘密>; cd; exec node entry args...'
  const envExports = Object.entries(ocEnv()).map(([k, v]) => `export ${k}=${shq(v)};`).join(' ');
  const readSecret = secretName ? `IFS= read -r __OC_S || [ -n "$__OC_S" ]; export ${secretName}="$__OC_S"; unset __OC_S;` : '';
  const script = `${envExports} ${readSecret} cd ${shq(OC_DATA)} 2>/dev/null || cd /; exec ${shq(node)} ${shq(entry)} ${args.map(shq).join(' ')}`;

  if (opts.interactive && (secretName || opts.stdinSecret)) throw new Error('交互模式不支持传入秘密值');
  if (secretName && opts.stdinSecret) throw new Error('secretEnv 与 stdinSecret 不能同时使用');
  const stdinValue = secretName ? secret[secretName] : opts.stdinSecret;
  const res = spawnSync('/bin/sh', ['-c', script], {
    ...(asUser ? { uid: asUser.uid, gid: asUser.gid, cwd: '/' } : {}),
    env,
    input: stdinValue ? `${stdinValue}\n` : undefined,
    stdio,
    encoding: 'utf8',
    timeout: opts.timeout || T_QUICK,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (!asUser) fixPermissions();
  const out = {
    status: res.status === null ? (res.signal ? 124 : 1) : res.status,
    stdout: res.stdout || '',
    stderr: res.stderr || '',
    timedOut: !!(res.error && res.error.code === 'ETIMEDOUT'),
  };
  // 防御: 即使上游意外回显了 Key，也不让它进入我们的输出
  if (stdinValue) {
    out.stdout = out.stdout.split(stdinValue).join('<已隐藏>');
    out.stderr = out.stderr.split(stdinValue).join('<已隐藏>');
  }
  return out;
}

/** 从 CLI 输出里提取 JSON (容忍前后夹带日志行) */
function parseJsonOutput(text) {
  const s = String(text || '');
  try { return JSON.parse(s); } catch {}
  const start = s.indexOf('{');
  const end = s.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try { return JSON.parse(s.slice(start, end + 1)); } catch {}
  }
  return null;
}

/** 提炼上游失败原因: 优先 JSON error.message，其次含关键字的行 */
function failureReason(res) {
  if (res.timedOut) return '命令超时 (设备负载过高或网络不通)';
  const j = parseJsonOutput(res.stdout);
  if (j && j.error && j.error.message) return String(j.error.message).split('\n')[0];
  const lines = `${res.stderr}\n${res.stdout}`.split('\n').map((l) => l.trim()).filter(Boolean)
    .filter((l) => !/^\[(diagnostic|state\/agent-db|provider-transport-fetch|openclaw\])/.test(l) && !/^Tip:/.test(l));
  const hit = lines.find((l) => /(error|invalid|fail|not |could not|couldn't|unknown|required|rejected|denied|looks like|unreachable|refused|timeout)/i.test(l));
  return hit || lines[lines.length - 1] || `退出码 ${res.status}`;
}

// ═══════════════════════════════════════════════════════════════════════════
// 配置读写 (仅用于 CLI 无对应命令的少数操作，fail-closed)
// ═══════════════════════════════════════════════════════════════════════════

function readConfigStrict() {
  let raw;
  try {
    raw = fs.readFileSync(CONFIG_FILE, 'utf8');
  } catch (e) {
    if (e.code === 'ENOENT') return {};
    throw new Error(`无法读取配置文件: ${e.message}`);
  }
  if (raw.trim() === '') return {};
  let d;
  try { d = JSON.parse(raw); } catch (e) { throw new Error(`配置文件不是合法 JSON，已中止以免覆盖: ${e.message}`); }
  if (d === null || typeof d !== 'object' || Array.isArray(d)) throw new Error('配置根节点不是 JSON 对象，已中止');
  return d;
}

function writeConfigSafely(d) {
  let mode = 0o600;
  try { mode = fs.statSync(CONFIG_FILE).mode & 0o777; } catch {}
  try { fs.copyFileSync(CONFIG_FILE, CONFIG_FILE + CONFIG_BACKUP_SUFFIX); } catch {}
  const tmp = path.join(path.dirname(CONFIG_FILE), `.${path.basename(CONFIG_FILE)}.providers-${process.pid}`);
  fs.writeFileSync(tmp, JSON.stringify(d, null, 2) + '\n', { mode });
  fs.renameSync(tmp, CONFIG_FILE);
  fixPermissions();
  // 写后交给上游校验，不合法则回滚
  const v = runOpenClaw(['config', 'validate']);
  if (v.status !== 0) {
    try { fs.copyFileSync(CONFIG_FILE + CONFIG_BACKUP_SUFFIX, CONFIG_FILE); fixPermissions(); } catch {}
    throw new Error(`上游配置校验未通过，已回滚: ${failureReason(v)}`);
  }
}

function readPrimary() {
  try {
    const d = readConfigStrict();
    return (d.agents && d.agents.defaults && d.agents.defaults.model && d.agents.defaults.model.primary) || null;
  } catch {
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 插件
// ═══════════════════════════════════════════════════════════════════════════

/** 查询官方 provider 插件是否已安装。返回 { installed, error? } */
function pluginStatus(pkg) {
  if (!pkg) return { installed: true, builtin: true };
  const res = runOpenClaw(['plugins', 'list', '--json']);
  const j = parseJsonOutput(res.stdout);
  if (!j || !Array.isArray(j.plugins)) return { installed: false, error: failureReason(res) };
  // name 字段不可靠 (plugins install 安装时为包名，onboard 自动安装时为显示名如 "StepFun")，
  // 以插件 id 为准: 官方包 @openclaw/<id>-provider 的 manifest id 即 <id> (已对全部目录内插件核实)
  const id = pkg.replace(/^@openclaw\//, '').replace(/-provider$/, '');
  const hit = j.plugins.find((p) => p && (p.id === id || p.name === pkg));
  return { installed: !!hit, enabled: hit ? hit.enabled !== false : false, version: hit ? hit.version : null };
}

/** 显式安装官方 provider 插件 (调用方负责先征得用户同意) */
function installPlugin(pkg) {
  if (!/^@openclaw\/[a-z0-9-]+-provider$/.test(pkg)) return { ok: false, reason: `拒绝安装非官方 provider 插件: ${pkg}` };
  const res = runOpenClaw(['plugins', 'install', pkg, '--accept-capabilities'], { timeout: T_PLUGIN });
  if (res.status !== 0) return { ok: false, reason: failureReason(res) };
  return { ok: true };
}

// ═══════════════════════════════════════════════════════════════════════════
// 写入凭据
// ═══════════════════════════════════════════════════════════════════════════

function validateSecret(key, optional) {
  const k = String(key == null ? '' : key).trim();
  if (!k) return optional ? '' : null;
  if (/[\r\n\0]/.test(k)) return null;
  return k;
}

/**
 * 默认模型处理:
 *   opts.model     用户选择的模型 (裸 ID 或 provider/model)，设为默认
 *   opts.keepDefault  true 时恢复执行前的默认模型
 */
function finalizeDefault(provider, prevPrimary, opts) {
  const notes = [];
  if (opts.model) {
    const ref = opts.model.includes('/') && opts.model.split('/')[0] === provider ? opts.model : `${provider}/${opts.model}`;
    const r = setDefault(ref);
    if (!r.ok) notes.push(`设置默认模型失败: ${r.reason}`);
    return { primary: r.ok ? ref : readPrimary(), notes };
  }
  if (opts.keepDefault && prevPrimary && readPrimary() !== prevPrimary) {
    const r = setDefault(prevPrimary);
    if (r.ok) notes.push(`已保留原默认模型 ${prevPrimary}`);
    else notes.push(`恢复原默认模型失败: ${r.reason}`);
  }
  return { primary: readPrimary(), notes };
}

/** API Key 方式 */
function applyApiKey(ref, key, opts = {}) {
  const f = findMethod(ref);
  if (!f || f.method.type !== 'api-key') return { ok: false, reason: `未知的接入方式: ${ref}` };
  const k = validateSecret(key);
  if (!k) return { ok: false, reason: 'API Key 为空或包含非法字符' };
  if (f.provider.plugin) {
    const ps = pluginStatus(f.provider.plugin);
    if (!ps.installed && !opts.pluginConfirmed) {
      return { ok: false, reason: `需要先安装官方插件 ${f.provider.plugin}`, needPlugin: f.provider.plugin };
    }
    if (!ps.installed) {
      const ir = installPlugin(f.provider.plugin);
      if (!ir.ok) return { ok: false, reason: `插件安装失败: ${ir.reason}` };
    }
  }
  const prev = readPrimary();
  const authProvider = f.method.authProvider || f.method.provider;
  const existing = listProfiles().filter((p) => p.provider === authProvider && p.type === 'api_key');
  const notes = [];
  if (existing.length) {
    // 已有凭据: 重复 onboard 会被上游拒绝 (实测 zai 报 "does not expose a starter model")，
    // 改用官方 paste-api-key 原地更新同一 profile，配置文件不变
    const profileId = (existing.find((p) => p.id === `${authProvider}:default`) || existing[0]).id;
    const res = runOpenClaw(['models', 'auth', 'paste-api-key', '--provider', authProvider, '--profile-id', profileId], {
      stdinSecret: k, timeout: T_ONBOARD,
    });
    if (res.status !== 0) return { ok: false, reason: failureReason(res) };
    notes.push(`已更新现有凭据 ${profileId}`);
    const r = syncBaseUrl(f.method);
    if (r) notes.push(r);
  } else {
    const res = runOpenClaw(['onboard', ...ONBOARD_FLAGS, '--auth-choice', f.method.authChoice], {
      secretEnv: { [f.method.env]: k }, timeout: T_ONBOARD,
    });
    if (res.status !== 0) return { ok: false, reason: failureReason(res) };
  }
  const fin = finalizeDefault(f.method.provider, prev, opts);
  return { ok: true, provider: f.method.provider, primary: fin.primary, notes: [...notes, ...fin.notes] };
}

function listProfiles() {
  const al = runOpenClaw(['models', 'auth', 'list', '--json']);
  const aj = parseJsonOutput(al.stdout);
  return aj && Array.isArray(aj.profiles) ? aj.profiles.map((p) => ({ id: p.id, provider: p.provider, type: p.type })) : [];
}

/** 更新 Key 时若用户换了区域 (如中国站 → 国际站)，同步 provider 的 baseUrl */
function syncBaseUrl(method) {
  if (!method.baseUrl || !method.provider) return null;
  let cfg;
  try { cfg = readConfigStrict(); } catch { return null; }
  const p = cfg.models && cfg.models.providers && cfg.models.providers[method.provider];
  if (!p || p.baseUrl === method.baseUrl) return null;
  const old = p.baseUrl;
  p.baseUrl = method.baseUrl;
  try { writeConfigSafely(cfg); } catch (e) { return `Base URL 切换失败: ${e.message}`; }
  return `Base URL 已从 ${old || '(空)'} 切换为 ${method.baseUrl}`;
}

function normalizeBaseUrl(u) {
  const s = String(u || '').trim().replace(/\/+$/, '');
  if (!/^https?:\/\/[^\s/]+/.test(s)) return null;
  return s;
}

const CUSTOM_ID_RE = /^[a-z0-9][a-z0-9-]{0,47}$/;
const MODEL_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,199}$/;

/**
 * 自定义 OpenAI / Anthropic 兼容 provider。
 * provider id 已存在时只追加模型 (上游 onboard 对已存在 id 会拒绝并留下一条未激活凭据，已实测)，
 * 并仅在用户提供了新 Key 时更新 Key。
 */
function applyCustom(spec, key, opts = {}) {
  const id = String(spec.providerId || '').trim();
  const baseUrl = normalizeBaseUrl(spec.baseUrl);
  const model = String(spec.model || '').trim();
  const compat = spec.compatibility || 'openai';
  if (!CUSTOM_ID_RE.test(id)) return { ok: false, reason: 'Provider ID 只能包含小写字母、数字和连字符，且以字母或数字开头' };
  if (!baseUrl) return { ok: false, reason: 'Base URL 必须以 http:// 或 https:// 开头' };
  if (!MODEL_ID_RE.test(model)) return { ok: false, reason: '模型 ID 为空或包含非法字符' };
  if (!['openai', 'openai-responses', 'anthropic'].includes(compat)) return { ok: false, reason: `不支持的兼容模式: ${compat}` };
  const k = validateSecret(key, !!spec.keyOptional);
  if (k === null) return { ok: false, reason: 'API Key 为空或包含非法字符' };

  let cfg;
  try { cfg = readConfigStrict(); } catch (e) { return { ok: false, reason: e.message }; }
  const existing = cfg.models && cfg.models.providers && cfg.models.providers[id];
  const prev = readPrimary();

  if (existing) {
    if (existing.baseUrl && normalizeBaseUrl(existing.baseUrl) !== baseUrl) {
      return { ok: false, reason: `Provider ID "${id}" 已存在且 Base URL 不同 (${existing.baseUrl})，请换一个 ID 或先删除旧的` };
    }
    const models = Array.isArray(existing.models) ? existing.models : (existing.models = []);
    if (!models.some((m) => m && m.id === model)) {
      models.push({
        id: model,
        name: model,
        contextWindow: 128000,
        maxTokens: 4096,
        input: spec.image ? ['text', 'image'] : ['text'],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        reasoning: false,
      });
    }
    if (k) existing.apiKey = k;
    cfg.agents = cfg.agents || {};
    cfg.agents.defaults = cfg.agents.defaults || {};
    cfg.agents.defaults.models = cfg.agents.defaults.models || {};
    if (!cfg.agents.defaults.models[`${id}/${model}`]) cfg.agents.defaults.models[`${id}/${model}`] = {};
    try { writeConfigSafely(cfg); } catch (e) { return { ok: false, reason: e.message }; }
  } else {
    const args = ['onboard', ...ONBOARD_FLAGS, '--auth-choice', 'custom-api-key',
      '--custom-base-url', baseUrl, '--custom-model-id', model, '--custom-provider-id', id,
      '--custom-compatibility', compat, spec.image ? '--custom-image-input' : '--custom-text-input'];
    const res = runOpenClaw(args, { secretEnv: k ? { CUSTOM_API_KEY: k } : null, timeout: T_ONBOARD });
    if (res.status !== 0) return { ok: false, reason: failureReason(res) };
  }
  const fin = finalizeDefault(id, prev, { ...opts, model: opts.setDefault ? model : null, keepDefault: !opts.setDefault });
  return { ok: true, provider: id, primary: fin.primary, notes: fin.notes, appended: !!existing };
}

/** Ollama: 上游会先检测服务可达性 */
function applyOllama(baseUrl, model, opts = {}) {
  const u = normalizeBaseUrl(baseUrl);
  if (!u) return { ok: false, reason: 'Ollama 地址必须以 http:// 或 https:// 开头' };
  if (!MODEL_ID_RE.test(String(model || ''))) return { ok: false, reason: '模型名为空或包含非法字符' };
  const prev = readPrimary();
  const res = runOpenClaw(['onboard', ...ONBOARD_FLAGS, '--auth-choice', 'ollama',
    '--custom-base-url', u.replace(/\/v1$/, ''), '--custom-model-id', model], { timeout: T_ONBOARD });
  if (res.status !== 0) return { ok: false, reason: failureReason(res) };
  const fin = finalizeDefault('ollama', prev, { model: opts.setDefault ? model : null, keepDefault: !opts.setDefault });
  return { ok: true, provider: 'ollama', primary: fin.primary, notes: fin.notes };
}

/** OAuth / 设备码登录: 透传终端交互 */
function login(ref) {
  const f = findMethod(ref);
  if (!f || f.method.type !== 'oauth') return { ok: false, reason: `未知的登录方式: ${ref}` };
  const res = runOpenClaw(f.method.loginArgs, { interactive: true, timeout: 30 * 60 * 1000 });
  return res.status === 0 ? { ok: true, provider: f.method.provider } : { ok: false, reason: `登录未完成 (退出码 ${res.status})` };
}

// ═══════════════════════════════════════════════════════════════════════════
// 模型管理
// ═══════════════════════════════════════════════════════════════════════════

function setDefault(modelRef) {
  if (!MODEL_ID_RE.test(String(modelRef || '')) || !String(modelRef).includes('/')) {
    return { ok: false, reason: '模型引用格式应为 provider/model' };
  }
  const res = runOpenClaw(['models', 'set', modelRef]);
  return res.status === 0 ? { ok: true } : { ok: false, reason: failureReason(res) };
}

function fallbacks(op, modelRef) {
  if (op === 'list') {
    const res = runOpenClaw(['models', 'fallbacks', 'list', '--json']);
    const j = parseJsonOutput(res.stdout);
    if (!j) return { ok: false, reason: failureReason(res) };
    return { ok: true, fallbacks: j.fallbacks || [] };
  }
  if (op === 'clear') {
    const res = runOpenClaw(['models', 'fallbacks', 'clear']);
    return res.status === 0 ? { ok: true } : { ok: false, reason: failureReason(res) };
  }
  if (op === 'add' || op === 'remove') {
    if (!MODEL_ID_RE.test(String(modelRef || '')) || !String(modelRef).includes('/')) {
      return { ok: false, reason: '模型引用格式应为 provider/model' };
    }
    const res = runOpenClaw(['models', 'fallbacks', op, modelRef]);
    return res.status === 0 ? { ok: true } : { ok: false, reason: failureReason(res) };
  }
  return { ok: false, reason: `未知操作: ${op}` };
}

/**
 * 认证与模型状态概览 (已脱敏: 只保留 provider / profile id / 类型 / 计数)。
 * 注意: 这是本地状态检查，不是调用测试。
 */
function status() {
  const out = { ok: true, defaultModel: null, fallbacks: [], providers: [], profiles: [], custom: [], issues: [] };
  const st = runOpenClaw(['models', 'status', '--json']);
  const j = parseJsonOutput(st.stdout);
  if (!j || j.ok === false) {
    out.ok = false;
    out.reason = failureReason(st);
  } else {
    out.defaultModel = j.resolvedDefault || j.defaultModel || null;
    out.fallbacks = Array.isArray(j.fallbacks) ? j.fallbacks : [];
    const a = j.auth || {};
    for (const p of (a.providers || [])) {
      const pr = p.profiles || {};
      out.providers.push({
        provider: p.provider,
        source: (p.effective && p.effective.kind) || '',
        profiles: pr.count || 0,
        oauth: pr.oauth || 0,
        apiKey: pr.apiKey || 0,
        token: pr.token || 0,
      });
    }
    for (const m of (a.missingProvidersInUse || [])) out.issues.push(`正在使用但缺少凭据: ${typeof m === 'string' ? m : (m.provider || JSON.stringify(m))}`);
    for (const u of (a.unusableProfiles || [])) out.issues.push(`凭据不可用: ${u.profileId || u.id || u.provider || ''}${u.reason ? ` (${u.reason})` : ''}`);
  }
  out.profiles = listProfiles();
  try {
    const cfg = readConfigStrict();
    const provs = (cfg.models && cfg.models.providers) || {};
    for (const [id, p] of Object.entries(provs)) {
      out.custom.push({
        id,
        baseUrl: p.baseUrl || '',
        api: p.api || '',
        hasKey: typeof p.apiKey === 'string' ? p.apiKey.length > 0 : !!p.apiKey,
        models: Array.isArray(p.models) ? p.models.map((m) => m && m.id).filter(Boolean) : [],
      });
    }
  } catch (e) {
    out.issues.push(e.message);
  }
  return out;
}

/** 可选为默认 / 备用的模型: 配置中登记的模型白名单 + models.providers 下声明的模型 */
function configuredModels() {
  let cfg;
  try { cfg = readConfigStrict(); } catch { return []; }
  const refs = new Set(Object.keys((cfg.agents && cfg.agents.defaults && cfg.agents.defaults.models) || {}));
  for (const [id, p] of Object.entries((cfg.models && cfg.models.providers) || {})) {
    for (const m of (Array.isArray(p.models) ? p.models : [])) if (m && m.id) refs.add(`${id}/${m.id}`);
  }
  return [...refs].sort();
}

function cacheFile(provider) {
  return path.join(MODEL_CACHE_DIR, `${provider.replace(/[^a-z0-9-]/gi, '_')}.json`);
}

function readCache(provider) {
  try {
    const j = JSON.parse(fs.readFileSync(cacheFile(provider), 'utf8'));
    if (j && Array.isArray(j.models)) return j;
  } catch {}
  return null;
}

function writeCache(provider, models) {
  try {
    fs.mkdirSync(MODEL_CACHE_DIR, { recursive: true });
    fs.writeFileSync(cacheFile(provider), JSON.stringify({ at: new Date().toISOString(), version: installedOpenClawVersion(), models }));
  } catch {}
}

/**
 * 动态发现某 provider 的模型。
 * 依次: models list (Gateway 运行时经由 Gateway) → 加 --refresh 重试 → 本地缓存 → 精选预设。
 * 返回的 hints 用于告诉用户「列表 ≠ 权限」以及上游报告的认证问题。
 */
function discoverModels(provider, opts = {}) {
  const hints = [];
  const attempt = (extra) => {
    const res = runOpenClaw(['models', 'list', '--all', '--provider', provider, '--json', ...extra], { timeout: T_QUICK });
    const j = parseJsonOutput(res.stdout);
    const text = `${res.stderr}\n${res.stdout}`;
    if (new RegExp(`authentication was rejected for ${provider}\\b`, 'i').test(text)) hints.push('auth-rejected');
    if (new RegExp(`unavailable for ${provider}\\b`, 'i').test(text)) hints.push('discovery-unavailable');
    if (!j || j.ok === false || !Array.isArray(j.models)) return { models: [], reason: failureReason(res) };
    const prefix = `${provider}/`;
    return {
      models: j.models.filter((m) => m && typeof m.key === 'string' && m.key.startsWith(prefix)).map((m) => ({
        id: m.key.slice(prefix.length), name: m.name || '', input: m.input || '', contextWindow: m.contextWindow || 0,
      })),
    };
  };
  let r = opts.refresh ? { models: [] } : attempt([]);
  if (!r.models.length) r = attempt(['--refresh']);
  if (r.models.length) {
    writeCache(provider, r.models);
    return { source: 'live', models: r.models, hints: [...new Set(hints)] };
  }
  const c = readCache(provider);
  if (c && c.models.length) return { source: 'cache', cachedAt: c.at, models: c.models, hints: [...new Set(hints)], reason: r.reason };
  return { source: 'none', models: [], hints: [...new Set(hints)], reason: r.reason };
}

/** 模型候选: 精选 + 动态 (去重)，manual 入口由前端永久保留 */
function modelChoices(ref, opts = {}) {
  const f = findMethod(ref);
  if (!f) return { ok: false, reason: `未知的接入方式: ${ref}` };
  const curated = curatedModels(f.method).map((m) => ({ ...m, source: 'curated' }));
  let discovered = null;
  if (opts.discover && f.method.provider) discovered = discoverModels(f.method.provider, opts);
  const seen = new Set(curated.map((m) => m.id));
  const extra = discovered ? discovered.models.filter((m) => !seen.has(m.id)).map((m) => ({ id: m.id, desc: m.name || '', source: discovered.source })) : [];
  return {
    ok: true, provider: f.method.provider, defaultModel: f.method.defaultModel || '',
    curated, extra, discovery: discovered ? { source: discovered.source, hints: discovered.hints, reason: discovered.reason, cachedAt: discovered.cachedAt } : null,
  };
}

const PROBE_STATUS = {
  ok: '可用',
  auth: '认证失败 (Key 无效、过期或无权限)',
  rate_limit: '触发限流',
  billing: '余额不足或未开通计费',
  timeout: '请求超时',
  format: '响应格式异常',
  no_model: '该凭据下没有可用模型',
  unknown: '未知错误',
};

/**
 * 连通性测试 (真实请求，可能消耗少量 token)。
 *
 * 优先经由运行中的 Gateway 调用 models.probe (2026.9.36 / 2026.10.9 实测可用，
 * 不中断服务，返回结果已由上游脱敏)；Gateway 未运行时再用 `models status --probe`
 * (该命令要求独占状态目录，Gateway 运行时会被上游拒绝)。
 */
function probe(provider) {
  if (!/^[a-z0-9][a-z0-9-]*$/.test(String(provider || ''))) return { ok: false, reason: 'provider 名称不合法' };
  const mapResult = (r, fallbackModel) => ({
    model: r.model || (r.label && r.label.includes(' · ') ? r.label.split(' · ').pop() : fallbackModel || ''),
    profileId: r.profileId || '',
    status: r.status,
    statusText: PROBE_STATUS[r.status] || r.status,
    latencyMs: r.latencyMs || 0,
    error: r.status === 'ok' ? '' : String(r.error || '').split('\n')[0],
  });

  const gw = runOpenClaw(['gateway', 'call', 'models.probe', '--params', JSON.stringify({ provider, timeoutMs: 20000 }), '--json', '--timeout', '60000'], { timeout: T_PROBE });
  const gj = parseJsonOutput(gw.stdout);
  if (gw.status === 0 && gj && Array.isArray(gj.results)) {
    if (!gj.results.length) return { ok: false, via: 'gateway', reason: '没有找到该 provider 的凭据或模型可供测试' };
    return { ok: true, via: 'gateway', results: gj.results.map((r) => mapResult(r)) };
  }

  const res = runOpenClaw(['models', 'status', '--probe', '--probe-provider', provider, '--probe-max-tokens', '8', '--probe-timeout', '20000', '--json'], { timeout: T_PROBE });
  const j = parseJsonOutput(res.stdout);
  if (!j || j.ok === false) {
    return { ok: false, via: 'cli', reason: `${failureReason(res)} (经由 Gateway: ${failureReason(gw)})` };
  }
  const probes = (j.auth && j.auth.probes) || j.probes || {};
  const results = (probes.results || []).map((r) => mapResult(r));
  if (!results.length) return { ok: false, via: 'cli', reason: '没有找到该 provider 的凭据或模型可供测试' };
  return { ok: true, via: 'cli', results };
}

/** 删除认证凭据 (仅限 models auth list 中存在的 profile) */
function removeAuth(profileId) {
  if (!listProfiles().some((p) => p.id === profileId)) return { ok: false, reason: `凭据不存在: ${profileId}` };
  const res = runOpenClaw(['models', 'auth', 'logout', profileId, '--yes']);
  return res.status === 0 ? { ok: true } : { ok: false, reason: failureReason(res) };
}

/**
 * 删除 models.providers 下的条目及其模型白名单。
 * 默认模型正在使用它时拒绝删除；fallback 中引用它的条目一并移除。
 */
function removeProvider(id) {
  let cfg;
  try { cfg = readConfigStrict(); } catch (e) { return { ok: false, reason: e.message }; }
  const provs = cfg.models && cfg.models.providers;
  if (!provs || !provs[id]) return { ok: false, reason: `配置中没有 provider: ${id}` };
  const model = cfg.agents && cfg.agents.defaults && cfg.agents.defaults.model;
  const prefix = `${id}/`;
  if (model && typeof model.primary === 'string' && model.primary.startsWith(prefix)) {
    return { ok: false, reason: `默认模型 ${model.primary} 正在使用该 provider，请先切换默认模型` };
  }
  delete provs[id];
  const removed = [];
  if (model && Array.isArray(model.fallbacks)) {
    model.fallbacks = model.fallbacks.filter((m) => { const hit = String(m).startsWith(prefix); if (hit) removed.push(m); return !hit; });
  }
  const allow = cfg.agents && cfg.agents.defaults && cfg.agents.defaults.models;
  if (allow) for (const k of Object.keys(allow)) if (k.startsWith(prefix)) delete allow[k];
  try { writeConfigSafely(cfg); } catch (e) { return { ok: false, reason: e.message }; }
  return { ok: true, removedFallbacks: removed };
}

module.exports = {
  CATALOG_FILE, CONFIG_FILE,
  loadCatalog, findMethod, menuEntries, quickEntries, docsUrl, catalogVerification, curatedModels,
  runOpenClaw, parseJsonOutput, failureReason,
  pluginStatus, installPlugin,
  applyApiKey, applyCustom, applyOllama, login,
  setDefault, fallbacks, status, configuredModels, discoverModels, modelChoices, probe, removeAuth, removeProvider,
  PROBE_STATUS,
};

// ═══════════════════════════════════════════════════════════════════════════
// 命令行接口 (供 oc-config.sh 调用；输出为 TSV / 纯文本，便于 ash 解析)
// ═══════════════════════════════════════════════════════════════════════════

function readStdinLine() {
  try {
    const buf = fs.readFileSync(0, 'utf8');
    return buf.split('\n')[0].replace(/\r$/, '');
  } catch {
    return '';
  }
}

function flag(args, name) {
  const i = args.indexOf(name);
  if (i < 0) return undefined;
  const v = args[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
}

function printResult(r) {
  if (r.ok) {
    console.log('OK');
    if (r.primary) console.log(`PRIMARY\t${r.primary}`);
    for (const n of (r.notes || [])) console.log(`NOTE\t${n}`);
  } else {
    console.log(`ERROR\t${r.reason}`);
    if (r.needPlugin) console.log(`NEEDPLUGIN\t${r.needPlugin}`);
  }
  return r.ok ? 0 : 1;
}

function cli(argv) {
  const [cmd, ...args] = argv;
  switch (cmd) {
    case 'menu': {
      // group<TAB>groupLabel<TAB>ref<TAB>label<TAB>type<TAB>plugin
      for (const e of menuEntries()) {
        for (const m of e.methods) {
          const label = e.methods.length > 1 ? `${e.label} — ${m.label}` : e.label;
          console.log([e.group, e.groupLabel, m.ref, label, m.type, e.plugin].join('\t'));
        }
      }
      return 0;
    }
    case 'quick':
      for (const q of quickEntries()) console.log([q.ref, q.label, q.type].join('\t'));
      return 0;
    case 'info': {
      const f = findMethod(args[0]);
      if (!f) { console.log(`ERROR\t未知的接入方式: ${args[0]}`); return 1; }
      const m = f.method;
      const kv = {
        ref: f.ref, label: f.provider.label, method: m.label, type: m.type, provider: m.provider || m.customProviderId || '',
        plugin: f.provider.plugin || '', env: m.env || '', baseUrl: m.baseUrl || m.baseUrlDefault || '',
        compatibility: m.compatibility || '', defaultModel: m.defaultModel || m.modelHint || '',
        keyUrl: f.provider.keyUrl || '', docs: docsUrl(f.provider), note: f.provider.note || m.note || '',
        keyHint: m.keyHint || '', keyOptional: m.keyOptional ? '1' : '', unverified: m.unverified || '',
      };
      for (const [k, v] of Object.entries(kv)) console.log(`${k}\t${String(v).replace(/[\t\n]/g, ' ')}`);
      return 0;
    }
    case 'verify': {
      const v = catalogVerification();
      console.log(`installed\t${v.installed || ''}`);
      console.log(`verified\t${v.verified ? '1' : '0'}`);
      console.log(`verifiedWith\t${v.verifiedWith.join(', ')}`);
      console.log(`verifiedAt\t${v.verifiedAt}`);
      return 0;
    }
    case 'plugin-status': {
      const f = findMethod(args[0]);
      if (!f) { console.log(`ERROR\t未知的接入方式: ${args[0]}`); return 1; }
      if (!f.provider.plugin) { console.log('BUILTIN'); return 0; }
      const s = pluginStatus(f.provider.plugin);
      if (s.error) { console.log(`ERROR\t${s.error}`); return 1; }
      console.log(s.installed ? `INSTALLED\t${s.version || ''}` : `MISSING\t${f.provider.plugin}`);
      return 0;
    }
    case 'install-plugin': {
      const f = findMethod(args[0]);
      if (!f || !f.provider.plugin) { console.log('ERROR\t该接入方式不需要插件'); return 1; }
      return printResult(installPlugin(f.provider.plugin));
    }
    case 'models': {
      const r = modelChoices(args[0], { discover: !!flag(args, '--discover'), refresh: !!flag(args, '--refresh') });
      if (!r.ok) { console.log(`ERROR\t${r.reason}`); return 1; }
      console.log(`PROVIDER\t${r.provider || ''}`);
      console.log(`DEFAULT\t${r.defaultModel}`);
      for (const m of r.curated) console.log(['M', m.id, 'curated', `${m.tier ? `[${m.tier}] ` : ''}${m.desc || ''}`].join('\t'));
      for (const m of r.extra) console.log(['M', m.id, m.source, m.desc || ''].join('\t'));
      if (r.discovery) {
        console.log(`DISCOVERY\t${r.discovery.source}\t${(r.discovery.hints || []).join(',')}\t${r.discovery.reason || ''}`);
      }
      return 0;
    }
    case 'apply-key': {
      const key = readStdinLine();
      const model = flag(args, '--model');
      return printResult(applyApiKey(args[0], key, {
        model: typeof model === 'string' ? model : null,
        keepDefault: !!flag(args, '--keep-default'),
        pluginConfirmed: !!flag(args, '--install-plugin'),
      }));
    }
    case 'apply-custom': {
      const key = readStdinLine();
      return printResult(applyCustom({
        providerId: flag(args, '--id'), baseUrl: flag(args, '--base-url'), model: flag(args, '--model'),
        compatibility: flag(args, '--compat') || 'openai', image: !!flag(args, '--image'), keyOptional: !!flag(args, '--key-optional'),
      }, key, { setDefault: !!flag(args, '--set-default') }));
    }
    case 'apply-ollama':
      return printResult(applyOllama(flag(args, '--base-url'), flag(args, '--model'), { setDefault: !!flag(args, '--set-default') }));
    case 'login':
      return printResult(login(args[0]));
    case 'set-default':
      return printResult(setDefault(args[0]));
    case 'configured-models':
      for (const r of configuredModels()) console.log(r);
      return 0;
    case 'fallbacks': {
      const r = fallbacks(args[0], args[1]);
      if (r.ok && r.fallbacks) { console.log('OK'); for (const f of r.fallbacks) console.log(`F\t${f}`); return 0; }
      return printResult(r);
    }
    case 'status': {
      const s = status();
      if (!s.ok) console.log(`ERROR\t${s.reason}`);
      console.log(`DEFAULT\t${s.defaultModel || ''}`);
      for (const f of s.fallbacks) console.log(`FALLBACK\t${f}`);
      for (const p of s.providers) console.log(['AUTH', p.provider, p.source, p.profiles, p.apiKey, p.oauth, p.token].join('\t'));
      for (const p of s.profiles) console.log(['PROFILE', p.id, p.provider, p.type].join('\t'));
      for (const c of s.custom) console.log(['PROVIDER', c.id, c.baseUrl, c.api, c.hasKey ? 'key' : 'nokey', c.models.join(',')].join('\t'));
      for (const i of s.issues) console.log(`ISSUE\t${i}`);
      return s.ok ? 0 : 1;
    }
    case 'probe': {
      const r = probe(args[0]);
      if (!r.ok) { console.log(`ERROR\t${r.reason}`); return 1; }
      console.log(`OK\t${r.via}`);
      for (const x of r.results) console.log(['R', x.model, x.status, x.statusText, x.latencyMs, x.error].join('\t'));
      return 0;
    }
    case 'remove-auth':
      return printResult(removeAuth(args[0]));
    case 'remove-provider': {
      const r = removeProvider(args[0]);
      const rc = printResult(r);
      if (r.ok && r.removedFallbacks && r.removedFallbacks.length) console.log(`NOTE\t已同时移除 fallback: ${r.removedFallbacks.join(', ')}`);
      return rc;
    }
    default:
      console.error('用法: oc-providers.js <menu|quick|info|verify|plugin-status|install-plugin|models|apply-key|apply-custom|apply-ollama|login|set-default|configured-models|fallbacks|status|probe|remove-auth|remove-provider> ...');
      return 2;
  }
}

if (require.main === module) {
  let rc;
  try {
    rc = cli(process.argv.slice(2));
  } catch (e) {
    console.log(`ERROR\t${e.message}`);
    rc = 1;
  }
  process.exit(rc);
}
