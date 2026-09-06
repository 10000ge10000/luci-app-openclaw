#!/usr/bin/env node
/**
 * ============================================================================
 * OpenClaw 配置工具 — 交互式菜单前端
 * ============================================================================
 *
 * 功能特性:
 * - 方向键 (↑↓) 导航菜单选项 (使用 oc-menu-engine 引擎)
 * - 回车/空格 确认选择
 * - 实时搜索过滤
 * - 与 oc-config.sh 业务逻辑完全一致
 * - 纯 Node.js 实现，零外部依赖
 * - 完全兼容 xterm.js / Web PTY 环境
 */

const path = require('path');
const fs = require('fs');
const { spawn, spawnSync, execSync, execFileSync } = require('child_process');
const menu = require('./oc-menu-engine');
const { C, select, input, confirm, spinner, resetRenderCount } = menu;

// ═══════════════════════════════════════════════════════════════════════════
// 配置路径 (与 oc-config.sh 保持一致)
// ═══════════════════════════════════════════════════════════════════════════

const OC_BASE_PATH = process.env.OC_BASE_PATH || '/opt';
const OC_INSTALL_PATH = process.env.OC_INSTALL_PATH || `${OC_BASE_PATH}/openclaw`;
const NODE_BASE = process.env.NODE_BASE || `${OC_INSTALL_PATH}/node`;
const OC_GLOBAL = process.env.OC_GLOBAL || `${OC_INSTALL_PATH}/global`;
const OC_DATA = process.env.OC_DATA || `${OC_INSTALL_PATH}/data`;
const OC_STATE_DIR = process.env.OPENCLAW_STATE_DIR || `${OC_DATA}/.openclaw`;
const CONFIG_FILE = process.env.OPENCLAW_CONFIG_PATH || `${OC_STATE_DIR}/openclaw.json`;
const NODE_BIN = `${NODE_BASE}/bin/node`;
const PERMISSIONS_HELPER = '/usr/libexec/openclaw-permissions.sh';

// 写前备份的后缀。特意不用 .bak: OpenClaw 自身维护 openclaw.json.bak
// 及 .bak.1~.bak.4 轮转，占用同名文件会破坏上游备份链。
const CONFIG_BACKUP_SUFFIX = '.luci-pre-write';

// 精选模型预设 (shell 与 JS 共读的唯一数据源)
const MODEL_PRESETS_FILE = process.env.OC_MODEL_PRESETS
  || '/usr/share/openclaw/model-presets.json';

// 动态发现模型列表的超时。OpenWrt 上要避免菜单长时间卡住，
// 超时或失败时回落到本地精选预设。
const MODEL_DISCOVERY_TIMEOUT_MS = 6000;

// ═══════════════════════════════════════════════════════════════════════════
// 辅助函数 (与 oc-config.sh 逻辑对应)
// ═══════════════════════════════════════════════════════════════════════════

/**
 * 执行命令并返回结果
 * options.interactive: 若为 true，使用 stdio: 'inherit' 直通终端（用于向导/全屏交互），保证 child.stdout.isTTY 为 true
 * options.capture: 若为 true，静默收集 stdout/stderr 并返回，不输出到终端
 */
function runCommand(cmd, args = [], options = {}) {
  return new Promise((resolve, reject) => {
    const isInteractive = options.interactive === true || options.stdio === 'inherit';
    const isCapture = options.capture === true;

    // 交互模式下使用同步直通 (spawnSync inherit)，使子进程独占控制终端 TTY，
    // 避免父子进程竞争读取 stdin，执行完毕后排空残留按键并恢复终端模式
    if (isInteractive) {
      menu.setRawMode(false);
      process.stdout.write(C.show);
      if (process.stdin.pause) {
        try { process.stdin.pause(); } catch {}
      }
      try {
        const res = spawnSync(cmd, args, {
          stdio: 'inherit',
          shell: false,
          cwd: options.cwd,
          env: { ...process.env, ...options.env },
        });
        try {
          if (process.stdin.isTTY) process.stdin.setRawMode(false);
          while (process.stdin.read() !== null) {}
        } catch {}
        if (process.stdin.resume) {
          try { process.stdin.resume(); } catch {}
        }
        if (res.error) {
          return reject(res.error);
        }
        if (res.status === 0) {
          return resolve({ stdout: '', stderr: '', code: 0 });
        } else {
          return reject(new Error(`Command failed with code ${res.status}: ${res.signal || ''}`));
        }
      } catch (err) {
        return reject(err);
      }
    }

    const child = spawn(cmd, args, {
      stdio: isCapture ? ['ignore', 'pipe', 'pipe'] : ['ignore', 'pipe', 'pipe'],
      shell: !options.noShell,
      env: { ...process.env, ...options.env },
    });

    let stdout = '';
    let stderr = '';

    if (child.stdout) {
      child.stdout.on('data', (data) => {
        stdout += data;
        if (!isCapture) process.stdout.write(data);
      });
    }

    if (child.stderr) {
      child.stderr.on('data', (data) => {
        stderr += data;
        if (!isCapture) process.stderr.write(data);
      });
    }

    child.on('close', (code, signal) => {
      if (code === 0) {
        resolve({ stdout, stderr, code });
      } else {
        reject(new Error(`Command failed with code ${code ?? signal}: ${stderr}`));
      }
    });

    child.on('error', (err) => {
      reject(err);
    });
  });
}

/**
 * 清理过时插件配置并启用有效认证插件 (与 oc-config.sh 的 enable_auth_plugins 对应)
 */
function enableAuthPlugins() {
  if (!fs.existsSync(CONFIG_FILE)) return;
  try {
    const config = readConfig();
    if (!config.plugins) config.plugins = {};
    if (!config.plugins.entries) config.plugins.entries = {};
    const e = config.plugins.entries;
    ['copilot-proxy'].forEach(p => {
      if (!e[p]) e[p] = {};
      e[p].enabled = true;
    });
    delete e['qwen-portal-auth'];
    delete e['google-gemini-cli-auth'];
    delete e['minimax-portal-auth'];
    writeConfig(config);
  } catch {}
}

/**
 * 读取 JSON 配置文件
 */
function fixStatePermissions() {
  try {
    execFileSync(PERMISSIONS_HELPER, ['fix-state', OC_STATE_DIR], { stdio: 'ignore', timeout: 10000 });
  } catch {
    try {
      execSync(`find "${OC_STATE_DIR}" -user root ! -path "*/archived-extensions*" ! -path "*/npm/projects*" -exec chown openclaw:openclaw {} + 2>/dev/null || true`, { stdio: 'ignore' });
      execSync(`[ -d "${OC_STATE_DIR}/extensions" ] && chown -R openclaw:openclaw "${OC_STATE_DIR}/extensions" && chmod -R 755 "${OC_STATE_DIR}/extensions" 2>/dev/null || true`, { stdio: 'ignore' });
      execSync(`[ -d "${OC_STATE_DIR}/archived-extensions" ] && chown -R root:root "${OC_STATE_DIR}/archived-extensions" && chmod -R 755 "${OC_STATE_DIR}/archived-extensions" 2>/dev/null || true`, { stdio: 'ignore' });
    } catch {}
  }
}

/**
 * 配置文件损坏时抛出的专用错误。
 * 用于把“文件存在但内容不是合法 JSON 对象”与“文件不存在”区分开。
 */
class ConfigParseError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ConfigParseError';
  }
}

/**
 * 配置损坏时给用户的恢复指引。
 * 不直接自动改文件，避免在用户不知情的情况下丢配置。
 */
function configRecoveryHint() {
  const lines = [
    `${C.yellow}配置文件可能已损坏，为避免覆盖后丢失全部配置，本次操作已中止。${C.reset}`,
    `${C.yellow}文件:${C.reset} ${CONFIG_FILE}`,
    '',
    `${C.cyan}可尝试的恢复方式:${C.reset}`,
    `  1. 让 OpenClaw 自行修复:  openclaw doctor --fix`,
    `  2. 查看具体语法错误:      openclaw config validate`,
  ];
  const lastGood = `${CONFIG_FILE}.last-good`;
  if (fs.existsSync(lastGood)) {
    lines.push(`  3. 从上次正常配置恢复:    cp ${lastGood} ${CONFIG_FILE}`);
  }
  const preWrite = `${CONFIG_FILE}${CONFIG_BACKUP_SUFFIX}`;
  if (fs.existsSync(preWrite)) {
    lines.push(`  4. 从上次修改前的副本恢复: cp ${preWrite} ${CONFIG_FILE}`);
  }
  return lines.join('\n');
}

/**
 * 读取 JSON 配置文件。
 *
 * 语义 (与旧实现的关键差异):
 * - 文件不存在 / 内容为空  → 返回 {} (首次安装属正常情况)
 * - 文件存在但解析失败     → 抛出 ConfigParseError，绝不返回 {}
 *
 * 旧实现在解析失败时返回 {}，调用方随后 writeConfig() 会把这个空对象
 * 写回磁盘，导致 models.providers / apiKey / channels 等全部配置被静默清空。
 * 因此这里必须 fail closed，让写入路径中止。
 */
function readConfig() {
  if (!fs.existsSync(CONFIG_FILE)) return {};

  let raw;
  try {
    raw = fs.readFileSync(CONFIG_FILE, 'utf8');
  } catch (e) {
    throw new ConfigParseError(`无法读取配置文件: ${e.message}`);
  }

  if (raw.trim() === '') return {};

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    throw new ConfigParseError(`配置文件不是合法 JSON: ${e.message}`);
  }

  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new ConfigParseError('配置根节点必须是 JSON 对象');
  }
  return parsed;
}

/**
 * 只读场景下的安全读取: 配置损坏时返回 {} 而不抛错。
 * 仅供“显示当前值”这类不会回写磁盘的路径使用 (如菜单标题里的当前配置)。
 * 任何会写回磁盘的逻辑都必须用 readConfig()。
 */
function readConfigForDisplay() {
  try {
    return readConfig();
  } catch (e) {
    if (e instanceof ConfigParseError) return {};
    throw e;
  }
}

/**
 * 写入 JSON 配置文件 (原子写 + 写前备份 + 写后校验)。
 *
 * 旧实现直接 fs.writeFileSync 覆盖目标文件，写入中断会留下截断的 JSON，
 * 且没有任何备份可回退。这里改为:
 *   1. 先把现有配置复制为 .luci-pre-write 备份
 *   2. 写入同目录临时文件
 *   3. 回读校验临时文件可被 JSON.parse
 *   4. rename 原子替换目标文件
 *
 * 备份后缀特意不用 .bak: OpenClaw 自身维护 openclaw.json.bak 及 .bak.1~.bak.4
 * 轮转，占用同名文件会破坏上游的备份链。
 */
function writeConfig(config) {
  if (config === null || typeof config !== 'object' || Array.isArray(config)) {
    throw new Error('拒绝写入非对象配置');
  }

  const dir = path.dirname(CONFIG_FILE);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true }); try { execSync(`chown openclaw:openclaw "${dir}"`, { stdio: "ignore" }); } catch {}
  }

  // 保留原文件权限位，避免 rename 后权限被临时文件的 0600 覆盖
  let mode = 0o644;
  if (fs.existsSync(CONFIG_FILE)) {
    try { mode = fs.statSync(CONFIG_FILE).mode & 0o777; } catch {}
    // 写前备份 (best effort: 备份失败不应阻止用户修改配置)
    try { fs.copyFileSync(CONFIG_FILE, `${CONFIG_FILE}${CONFIG_BACKUP_SUFFIX}`); } catch {}
  }

  const payload = `${JSON.stringify(config, null, 2)}\n`;
  const tmpFile = `${CONFIG_FILE}.tmp-${process.pid}`;
  try {
    fs.writeFileSync(tmpFile, payload, { mode: 0o600 });
    // 回读校验: 确认落盘内容可解析，避免把坏内容 rename 成正式配置
    JSON.parse(fs.readFileSync(tmpFile, 'utf8'));
    try { fs.chmodSync(tmpFile, mode); } catch {}
    fs.renameSync(tmpFile, CONFIG_FILE);
  } catch (e) {
    try { if (fs.existsSync(tmpFile)) fs.unlinkSync(tmpFile); } catch {}
    throw new Error(`写入配置失败，原配置未被修改: ${e.message}`);
  }

  try {
    execSync(`chown openclaw:openclaw "${CONFIG_FILE}"`, { stdio: 'ignore' });
    fixStatePermissions();
  } catch {}
}

/**
 * 获取 JSON 配置值 (对应 json_get)
 *
 * 只读路径: 配置损坏时返回 null 而不抛错，保证菜单仍能打开并显示恢复提示。
 * 需要回写磁盘的逻辑必须直接用 readConfig()，以便在损坏时中止写入。
 */
function jsonGet(keyPath) {
  const config = readConfigForDisplay();
  const keys = keyPath.split('.');
  let value = config;
  for (const key of keys) {
    if (value && typeof value === 'object' && key in value) {
      value = value[key];
    } else {
      return null;
    }
  }
  return value;
}

/**
 * 设置 JSON 配置值 (对应 json_set)
 */
function jsonSet(keyPath, value) {
  const config = readConfig();
  const keys = keyPath.split('.');
  let obj = config;
  for (let i = 0; i < keys.length - 1; i++) {
    if (!obj[keys[i]]) obj[keys[i]] = {};
    obj = obj[keys[i]];
  }
  obj[keys[keys.length - 1]] = value;
  writeConfig(config);
}

/**
 * 获取当前活跃模型
 */
function getCurrentModel() {
  const primary = jsonGet('agents.defaults.model.primary');
  if (primary) return primary;
  // 只读路径: 与 jsonGet 保持一致，配置损坏时不抛错
  const config = readConfigForDisplay();
  if (config.models?.defaultModel) return config.models.defaultModel;
  return null;
}

/**
 * 查找 OpenClaw 入口文件
 */
function findOpenClawEntry() {
  const searchPaths = [
    `${OC_GLOBAL}/lib/node_modules/openclaw/openclaw.mjs`,
    `${OC_GLOBAL}/lib/node_modules/openclaw/dist/cli.js`,
    `${OC_GLOBAL}/node_modules/openclaw/openclaw.mjs`,
    `${OC_GLOBAL}/node_modules/openclaw/dist/cli.js`,
  ];
  for (const p of searchPaths) {
    if (fs.existsSync(p)) return p;
  }
  try {
    const dirs = fs.readdirSync(OC_GLOBAL);
    for (const dir of dirs) {
      const p = `${OC_GLOBAL}/${dir}/node_modules/openclaw/openclaw.mjs`;
      if (fs.existsSync(p)) return p;
    }
  } catch {}
  return null;
}

/**
 * 执行 OpenClaw CLI 命令 (对应 oc_cmd)
 * 交互式向导（configure / models auth login 等）以 interactive: true 运行，直通 stdio 保证 TTY 正常交互；
 * 命令执行后在 finally 中自动修复状态文件属主。
 */
async function ocCmd(...args) {
  const ocEntry = findOpenClawEntry();
  if (!ocEntry) throw new Error('OpenClaw 未安装');

  const isJson = args.includes('--json');
  const isInteractive = !isJson && (
    args[0] === 'configure' ||
    (args[0] === 'models' && args[1] === 'auth')
  );

  try {
    const res = await runCommand(NODE_BIN, [ocEntry, ...args], {
      interactive: isInteractive,
      capture: isJson,
      env: {
        OPENCLAW_HOME: OC_DATA,
        OPENCLAW_CONFIG_PATH: CONFIG_FILE,
        OPENCLAW_STATE_DIR: OC_STATE_DIR,
        HOME: OC_DATA,
      }
    });
    return res;
  } finally {
    try {
      execSync(`chown openclaw:openclaw "${CONFIG_FILE}" 2>/dev/null || true`, { stdio: 'ignore' });
      execSync(`chown openclaw:openclaw "${CONFIG_FILE}.bak" 2>/dev/null || true`, { stdio: 'ignore' });
      fixStatePermissions();
    } catch {}
  }
}

/**
 * 静默执行 OpenClaw CLI 并返回输出。
 *
 * ocCmd() 会把子进程输出直接透传到终端，适合交互式命令；
 * 但解析 `pairing list --json` 这类结果时需要拿到纯输出且不污染界面，
 * 因此单独提供同步捕获版本。
 *
 * 返回 { ok, stdout }: 命令不存在或非零退出时 ok=false，不抛异常。
 */
function ocCmdCapture(...args) {
  const ocEntry = findOpenClawEntry();
  if (!ocEntry) return { ok: false, stdout: '' };
  try {
    const stdout = execFileSync(NODE_BIN, [ocEntry, ...args], {
      encoding: 'utf8',
      timeout: 20000,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        ...process.env,
        OPENCLAW_HOME: OC_DATA,
        OPENCLAW_CONFIG_PATH: CONFIG_FILE,
        OPENCLAW_STATE_DIR: OC_STATE_DIR,
        HOME: OC_DATA,
      },
    });
    return { ok: true, stdout: stdout || '' };
  } catch (e) {
    // 保留 stdout: 部分命令失败时仍会输出有用信息
    return { ok: false, stdout: (e && (e.stdout || '')) ? String(e.stdout) : '' };
  }
}

/**
 * 从 `openclaw pairing list <channel> --json` 的输出中提取配对码。
 * 优先按 JSON 解析；输出夹带非 JSON 前后缀时回退到正则扫描。
 */
function parsePairingCodes(raw) {
  if (!raw || !raw.trim()) return [];
  const codes = [];
  const pushFrom = (node) => {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) { node.forEach(pushFrom); return; }
    if (typeof node.code === 'string' && node.code.trim()) codes.push(node.code.trim());
    Object.keys(node).forEach((k) => pushFrom(node[k]));
  };
  try {
    pushFrom(JSON.parse(raw));
  } catch {
    const re = /"code"\s*:\s*"([^"]+)"/g;
    let m;
    while ((m = re.exec(raw)) !== null) codes.push(m[1]);
  }
  return [...new Set(codes)];
}

/**
 * 读取精选模型预设 (shell 与 JS 共读的唯一数据源)。
 * 文件缺失或损坏时返回空结构，调用方回落到"手动输入"。
 */
function loadModelPresets() {
  try {
    const raw = fs.readFileSync(MODEL_PRESETS_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && parsed.providers) return parsed;
  } catch {}
  return { providers: {} };
}

/**
 * 动态发现某个 provider 当前实际可用的模型。
 *
 * 调 `openclaw models list --provider <id> --plain`，输出形如
 * "openai/gpt-5.5" 每行一个，这里剥掉 provider 前缀只留裸模型 ID。
 *
 * 注意上游行为 (已实测): `models list --all` 不是各 provider 的超集，
 * 必须按 provider 查询才能拿到完整列表；未安装对应插件的 provider
 * 会返回 "No models found."。因此失败/空结果都属正常，调用方回落预设。
 */
function discoverProviderModels(providerId) {
  const ocEntry = findOpenClawEntry();
  if (!ocEntry) return [];
  try {
    const stdout = execFileSync(
      NODE_BIN,
      [ocEntry, 'models', 'list', '--provider', providerId, '--plain'],
      {
        encoding: 'utf8',
        timeout: MODEL_DISCOVERY_TIMEOUT_MS,
        stdio: ['ignore', 'pipe', 'ignore'],
        env: {
          ...process.env,
          OPENCLAW_HOME: OC_DATA,
          OPENCLAW_CONFIG_PATH: CONFIG_FILE,
          OPENCLAW_STATE_DIR: OC_STATE_DIR,
          HOME: OC_DATA,
        },
      }
    );
    const prefix = `${providerId}/`;
    return [...new Set(
      String(stdout || '')
        .split('\n')
        .map((l) => l.trim())
        .filter((l) => l.startsWith(prefix))
        .map((l) => l.slice(prefix.length))
        .filter(Boolean)
    )];
  } catch {
    // 超时 / 命令不可用 / provider 无模型: 均回落到精选预设
    return [];
  }
}

/**
 * 构建模型选择菜单项: 精选预设 + 动态发现 + 手动输入。
 *
 * 三层设计的取舍 (架构决定):
 *   - 完全硬编码: 上游更新后必然过期。本项目此前正因如此积累了
 *     openai/gpt-5.2、claude-sonnet-4、grok-4 等一批上游已不存在的 ID。
 *   - 完全动态: 依赖 CLI 可用且已配置 Key，未装插件时返回 0 条，
 *     且逐 provider 调用在路由器上较慢，不能作为唯一来源。
 *   - 精选 + 动态 + 手动: 首屏快、能自动跟进、离线仍可用。
 */
function buildModelMenuItems(providerId, opts = {}) {
  const presets = loadModelPresets();
  const entry = presets.providers[providerId] || {};
  const presetModels = Array.isArray(entry.models) ? entry.models : [];
  const keys = 'abcdefghijkmnpqrstuvwxyz'.split('');
  const items = [];
  let ki = 0;

  if (presetModels.length) {
    items.push({ label: `${C.bold}── 精选模型 ──${C.reset}`, disabled: true });
    for (const m of presetModels) {
      items.push({
        key: keys[ki++] || undefined,
        label: m.model,
        desc: m.desc || '',
        value: m.model,
      });
    }
  }

  // 动态发现: 只展示不在精选列表里的，避免重复
  if (opts.discovered && opts.discovered.length) {
    const known = new Set(presetModels.map((m) => m.model));
    const extra = opts.discovered.filter((m) => !known.has(m));
    if (extra.length) {
      items.push({ label: `${C.bold}── OpenClaw 当前可用 ──${C.reset}`, disabled: true });
      for (const m of extra) {
        items.push({ key: keys[ki++] || undefined, label: m, desc: '', value: m });
      }
    }
  }

  items.push({ label: '', disabled: true });
  if (!opts.discovered) {
    items.push({ key: 'r', label: '从 OpenClaw 获取完整模型列表', desc: '动态发现当前可用模型', value: '__discover__' });
  }
  // 手动输入是永久保留的兼容出口: 上游新增模型时无需等插件更新
  items.push({ key: 'z', label: '手动输入模型 ID', desc: '', value: '__custom__' });
  return items;
}

/**
 * 统一的模型选择流程: 处理动态发现与手动输入两个特殊分支。
 * 返回裸模型 ID (不含 provider 前缀)，取消时返回 null。
 */
async function selectProviderModel(providerId, title, fallbackDefault) {
  let discovered = null;
  for (let round = 0; round < 2; round++) {
    const choice = await select({
      title,
      showSearch: true,
      items: buildModelMenuItems(providerId, discovered ? { discovered } : {}),
    });
    if (!choice) return null;

    if (choice.value === '__discover__') {
      console.log(`\n${C.cyan}正在从 OpenClaw 获取模型列表...${C.reset}`);
      discovered = discoverProviderModels(providerId);
      if (!discovered.length) {
        console.log(`${C.yellow}未获取到模型列表 (该 Provider 可能需要先安装插件或配置 API Key)，`
          + `已显示内置精选列表。${C.reset}\n`);
        discovered = [];
      } else {
        console.log(`${C.green}获取到 ${discovered.length} 个模型${C.reset}\n`);
      }
      continue;
    }

    if (choice.value === '__custom__') {
      const manual = await input({ prompt: '请输入模型 ID', defaultValue: fallbackDefault || '' });
      const trimmed = manual ? String(manual).trim() : '';
      return trimmed || null;
    }
    return choice.value;
  }
  return null;
}

/**
 * 注册模型并设为默认 (对应 register_and_set_model)
 */
function registerAndSetModel(modelId) {
  const config = readConfig();
  if (!config.agents) config.agents = {};
  if (!config.agents.defaults) config.agents.defaults = {};
  if (!config.agents.defaults.models) config.agents.defaults.models = {};
  if (!config.agents.defaults.model) config.agents.defaults.model = {};
  config.agents.defaults.models[modelId] = {};
  config.agents.defaults.model.primary = modelId;
  writeConfig(config);
}

/**
 * 写入 API Key 到 auth-profiles.json (对应 auth_set_apikey)
 */
function authSetApikey(provider, apiKey, profileId) {
  const authDir = `${OC_STATE_DIR}/agents/main/agent`;
  const authFile = `${authDir}/auth-profiles.json`;
  try {
    fs.mkdirSync(authDir, { recursive: true }); try { execSync(`chown openclaw:openclaw "${authDir}"`, { stdio: "ignore" }); } catch {}
  } catch {}

  let authData = { version: 1, profiles: {}, usageStats: {} };
  try {
    if (fs.existsSync(authFile)) {
      authData = JSON.parse(fs.readFileSync(authFile, 'utf8'));
    }
  } catch {}

  if (!authData.profiles) authData.profiles = {};
  authData.profiles[profileId || `${provider}:manual`] = {
    type: 'api_key',
    provider: provider,
    key: apiKey,
  };

  fs.writeFileSync(authFile, JSON.stringify(authData, null, 2));
  try {
    execSync(`chown openclaw:openclaw "${authFile}"`, { stdio: 'ignore' });
    fixStatePermissions();
  } catch {}
}

/**
 * 注册自定义提供商 (对应 register_custom_provider)
 */
function registerCustomProvider(providerName, baseUrl, apiKey, modelId, modelDisplay, ctxWindow, maxTok) {
  const config = readConfig();
  if (!config.models) config.models = {};
  if (!config.models.providers) config.models.providers = {};
  config.models.mode = 'merge';
  config.models.providers[providerName] = {
    baseUrl: baseUrl,
    apiKey: apiKey,
    api: 'openai-completions',
    models: [{
      id: modelId,
      name: modelDisplay || modelId,
      reasoning: false,
      input: ['text', 'image'],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: parseInt(ctxWindow) || 128000,
      maxTokens: parseInt(maxTok) || 32000,
    }]
  };
  writeConfig(config);
}

/**
 * 注册 Coding Plan 提供商 (对应 register_codingplan_provider)
 */
function registerCodingPlanProvider(apiKey) {
  const config = readConfig();
  if (!config.models) config.models = {};
  if (!config.models.providers) config.models.providers = {};
  config.models.mode = 'merge';
  config.models.providers['bailian'] = {
    baseUrl: 'https://coding.dashscope.aliyuncs.com/v1',
    apiKey: apiKey,
    api: 'openai-completions',
    models: [
      { id: 'qwen3.5-plus', name: 'qwen3.5-plus', reasoning: false, input: ['text', 'image'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000000, maxTokens: 65536 },
      { id: 'qwen3-coder-plus', name: 'qwen3-coder-plus', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000000, maxTokens: 65536 },
      { id: 'qwen3-coder-next', name: 'qwen3-coder-next', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 262144, maxTokens: 65536 },
      { id: 'qwen3-max-2026-01-23', name: 'qwen3-max-2026-01-23', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 262144, maxTokens: 65536 },
      { id: 'MiniMax-M2.5', name: 'MiniMax-M2.5', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 204800, maxTokens: 131072 },
      { id: 'glm-5', name: 'glm-5', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 202752, maxTokens: 16384 },
      { id: 'glm-4.7', name: 'glm-4.7', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 202752, maxTokens: 16384 },
      { id: 'kimi-k2.5', name: 'kimi-k2.5', reasoning: false, input: ['text', 'image'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 262144, maxTokens: 32768 },
    ]
  };

  if (!config.agents) config.agents = {};
  if (!config.agents.defaults) config.agents.defaults = {};
  if (!config.agents.defaults.models) config.agents.defaults.models = {};
  ['qwen3.5-plus', 'qwen3-coder-plus', 'qwen3-coder-next', 'qwen3-max-2026-01-23', 'MiniMax-M2.5', 'glm-5', 'glm-4.7', 'kimi-k2.5'].forEach(m => {
    config.agents.defaults.models[`bailian/${m}`] = {};
  });

  writeConfig(config);
}

/**
 * 注册腾讯云 Coding Plan 提供商 (对应 register_lkeap_codingplan_provider)
 */
function registerLkeapCodingPlanProvider(apiKey) {
  const config = readConfig();
  if (!config.models) config.models = {};
  if (!config.models.providers) config.models.providers = {};
  config.models.mode = 'merge';
  config.models.providers['lkeap'] = {
    baseUrl: 'https://api.lkeap.cloud.tencent.com/coding/v3',
    apiKey: apiKey,
    api: 'openai-completions',
    models: [
      { id: 'tc-code-latest', name: 'Auto (智能匹配最优模型)', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 8192 },
      { id: 'hunyuan-2.0-instruct', name: 'Tencent HY 2.0 Instruct', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 16000 },
      { id: 'hunyuan-2.0-thinking', name: 'Tencent HY 2.0 Think', reasoning: true, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 64000 },
      { id: 'hunyuan-t1', name: 'Hunyuan-T1', reasoning: true, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32000, maxTokens: 64000 },
      { id: 'hunyuan-turbos', name: 'Hunyuan-TurboS', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32000, maxTokens: 16000 },
      { id: 'minimax-m2.5', name: 'MiniMax-M2.5', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 204800, maxTokens: 131072 },
      { id: 'kimi-k2.5', name: 'Kimi-K2.5', reasoning: false, input: ['text', 'image'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 262144, maxTokens: 32768 },
      { id: 'glm-5', name: 'GLM-5', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 202752, maxTokens: 8192 },
    ]
  };

  if (!config.agents) config.agents = {};
  if (!config.agents.defaults) config.agents.defaults = {};
  if (!config.agents.defaults.models) config.agents.defaults.models = {};
  ['tc-code-latest', 'hunyuan-2.0-instruct', 'hunyuan-2.0-thinking', 'hunyuan-t1', 'hunyuan-turbos', 'minimax-m2.5', 'kimi-k2.5', 'glm-5'].forEach(m => {
    config.agents.defaults.models[`lkeap/${m}`] = {};
  });

  writeConfig(config);
}

/**
 * 重启 Gateway
 */
async function restartGateway() {
  resetRenderCount();
  console.log(`\n${C.yellow}正在重启 Gateway...${C.reset}`);

  try {
    await runCommand('/bin/sh', ['-c', [
      "if [ \"$(uci -q get openclaw.main.enabled 2>/dev/null || echo 0)\" != \"1\" ]; then",
      "  uci -q set openclaw.main.enabled='1';",
      "  uci -q commit openclaw;",
      "  /etc/init.d/openclaw enable >/dev/null 2>&1 || true;",
      'fi;',
      '/etc/init.d/openclaw restart_gateway >/dev/null 2>&1 || true;',
      '/etc/init.d/openclaw start >/dev/null 2>&1 || true'
    ].join(' ')]);
  } catch {}

  const spin = spinner({ text: 'Gateway 启动中，请稍候 (约 15-30 秒)...' });
  spin.start();

  const gwPort = jsonGet('gateway.port') || '18789';
  let waited = 0;
  const maxWait = 30;

  while (waited < maxWait) {
    await new Promise(r => setTimeout(r, 3000));
    waited += 3;
    try {
      // 兼容 OpenWrt: 优先 ss，回退 netstat
      let stdout = '';
      try {
        stdout = execSync('ss -tulnp 2>/dev/null', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
      } catch {
        // ss 不存在，使用 netstat
        try {
          stdout = execSync('netstat -tulnp 2>/dev/null', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
        } catch {}
      }
      if (stdout && stdout.includes(`:${gwPort} `)) {
        spin.succeed(`Gateway 已重启成功 (${waited}秒)`);
        return;
      }
    } catch {}
  }

  spin.stop(`${C.yellow}Gateway 仍在启动中，请稍后确认${C.reset}`);
  console.log(`${C.cyan}   查看日志: logread -e openclaw${C.reset}\n`);
}

/**
 * 询问是否重启
 */
async function askRestart() {
  const ok = await confirm({ prompt: '是否立即重启服务以应用配置?', defaultYes: true });
  if (ok) {
    await restartGateway();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 主菜单 (对应 main_menu)
// ═══════════════════════════════════════════════════════════════════════════

async function showMainMenu() {
  const currentModel = getCurrentModel();
  const statusLine = currentModel
    ? `${C.green}当前模型: ${currentModel}${C.reset}`
    : `${C.yellow}未配置模型${C.reset}`;

  const result = await select({
    title: 'OpenClaw AI Gateway — OpenWrt 配置管理',
    header: statusLine,
    showSearch: false,
    items: [
      { label: `${C.dim}━━━ AI 模型配置 ━━━${C.reset}`, disabled: true },
      { key: '1', label: '配置 AI 模型和提供商', desc: '', value: 'model' },
      { key: '2', label: '设置活动模型', desc: '', value: 'set-active-model' },

      { label: `${C.dim}━━━ 消息渠道 ━━━${C.reset}`, disabled: true },
      { key: '3', label: '配置消息渠道', desc: '电报/QQ/飞书', value: 'channels' },

      { label: `${C.dim}━━━ 系统管理 ━━━${C.reset}`, disabled: true },
      { key: '4', label: '健康检查与状态', desc: '', value: 'health' },
      { key: '5', label: '查看日志', desc: '', value: 'logs' },
      { key: '6', label: '重启 Gateway', desc: '', value: 'restart' },
      { key: '7', label: '设备配对管理', desc: '审批 Control UI 浏览器配对', value: 'devices' },

      { label: `${C.dim}━━━ 高级选项 ━━━${C.reset}`, disabled: true },
      { key: '8', label: '高级配置', desc: '', value: 'advanced' },
      { key: '9', label: '重置配置', desc: '', value: 'reset' },
      { key: '10', label: '显示当前配置概览', desc: '', value: 'show-config' },
      { key: '11', label: '备份/还原配置', desc: '', value: 'backup' },

      { label: '', disabled: true },
      { key: '0', label: '退出', desc: '', value: 'quit' },
    ],
  });

  return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// 模型配置菜单 (对应 configure_model)
// ═══════════════════════════════════════════════════════════════════════════

async function showModelMenu() {
  const result = await select({
    title: '配置 AI 模型和提供商',
    showSearch: false,
    items: [
      { label: `${C.green}${C.bold}── 推荐 ──${C.reset}`, disabled: true },
      { key: 'w', label: '官方完整模型配置向导', desc: `${C.green}(推荐，支持所有提供商)${C.reset}`, value: 'wizard' },

      { label: `${C.bold}── 国外模型提供商 ──${C.reset}`, disabled: true },
      { key: 'a', label: 'OpenAI', desc: '', value: 'openai' },
      { key: 'b', label: 'Anthropic', desc: '', value: 'anthropic' },
      { key: 'c', label: 'Google Gemini', desc: '', value: 'google' },
      { key: 'd', label: 'OpenRouter', desc: '聚合多家模型', value: 'openrouter' },
      { key: 'e', label: 'GitHub Copilot', desc: '需要 Copilot 订阅', value: 'copilot' },
      { key: 'f', label: 'xAI Grok', desc: '', value: 'xai' },

      { label: `${C.bold}── 国内模型提供商 ──${C.reset}`, disabled: true },
      { key: 'g', label: '阿里云通义千问 Qwen', desc: '', value: 'qwen' },
      { key: 'h', label: '硅基流动 SiliconFlow', desc: '', value: 'siliconflow' },
      { key: 'i', label: '腾讯云 Coding Plan', desc: '', value: 'tencent' },
      { key: 'j', label: '百度千帆', desc: '', value: 'baidu' },
      { key: 'k', label: '智谱 GLM / Z.AI', desc: '', value: 'zhipu' },

      { label: `${C.bold}── 本地模型 / 自定义 API ──${C.reset}`, disabled: true },
      { key: 'l', label: 'Ollama', desc: '本地模型，无需 API Key', value: 'ollama' },
      { key: 'm', label: '自定义 OpenAI 兼容 API', desc: '', value: 'custom' },
      { key: 'n', label: '自定义 Anthropic 兼容 API', desc: '', value: 'custom-anthropic' },
      { key: 'o', label: '一万AI分享 粉丝专享 API', desc: '', value: 'yiwanai-fan' },

      { label: '', disabled: true },
      { key: '0', label: '返回', desc: '', value: 'back' },
    ],
  });

  return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// 消息渠道菜单 (对应 configure_channels)
// ═══════════════════════════════════════════════════════════════════════════

async function showChannelsMenu() {
  const result = await select({
    title: '配置消息渠道',
    showSearch: false,
    items: [
      { label: `${C.dim}提示: 微信配置请使用 LuCI 界面「微信配置」菜单${C.reset}`, disabled: true },
      { label: '', disabled: true },
      { key: '1', label: 'QQ 机器人', desc: '腾讯QQ', value: 'qq' },
      { key: '2', label: 'Telegram', desc: `${C.green}最常用${C.reset} — 配置 Bot Token`, value: 'telegram' },
      { key: '3', label: 'Discord', desc: '', value: 'discord' },
      { key: '4', label: '飞书 (Feishu)', desc: '', value: 'feishu' },
      { key: '5', label: 'Slack', desc: '', value: 'slack' },
      { key: '6', label: 'WhatsApp', desc: '需通过 Web 控制台扫码', value: 'whatsapp' },
      { key: '7', label: 'Telegram 配对助手', desc: '审批用户配对请求 (需先配置 Token)', value: 'telegram-pairing' },
      { key: '8', label: '官方完整渠道配置向导', desc: '', value: 'wizard' },
      { label: '', disabled: true },
      { key: '0', label: '返回', desc: '', value: 'back' },
    ],
  });

  return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// 高级配置菜单 (对应 advanced_menu)
// ═══════════════════════════════════════════════════════════════════════════

async function showAdvancedMenu() {
  const gwPort = jsonGet('gateway.port') || '18789';
  const gwBind = jsonGet('gateway.bind') || 'lan';
  const gwMode = jsonGet('gateway.mode') || 'local';
  // 正确键是顶层 logging.level；gateway.logLevel 不在 OpenClaw schema 中
  // (gateway.additionalProperties=false)，仅为显示旧配置残留值做兼容读取。
  const logLevel = jsonGet('logging.level') || jsonGet('gateway.logLevel') || '未设置';
  const acpDispatch = jsonGet('acp.dispatch.enabled') || 'false';

  const result = await select({
    title: '高级配置',
    showSearch: false,
    items: [
      { key: '1', label: 'Gateway 端口', desc: `当前: ${gwPort}`, value: 'port' },
      { key: '2', label: 'Gateway 绑定地址', desc: `当前: ${gwBind}`, value: 'bind' },
      { key: '3', label: 'Gateway 运行模式', desc: `当前: ${gwMode}`, value: 'mode' },
      { key: '4', label: '日志级别', desc: `当前: ${logLevel}`, value: 'loglevel' },
      { key: '5', label: 'ACP Dispatch 设置', desc: `当前: ${acpDispatch}`, value: 'acp' },
      { key: '6', label: '官方完整配置向导', desc: 'oc configure', value: 'wizard' },
      { key: '7', label: '查看原始配置 JSON', desc: '', value: 'view-json' },
      { key: '8', label: '编辑配置文件', desc: 'vi / nano', value: 'edit' },
      { key: '9', label: '导出配置备份', desc: '', value: 'backup' },
      { key: '10', label: '导入配置', desc: '', value: 'import' },
      { key: '11', label: '设备配对管理', desc: '审批 Control UI 配对', value: 'devices' },
      { label: '', disabled: true },
      { key: '0', label: '返回', desc: '', value: 'back' },
    ],
  });

  return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// 重置配置菜单 (对应 reset_to_defaults)
// ═══════════════════════════════════════════════════════════════════════════

async function showResetMenu() {
  const result = await select({
    title: '恢复默认配置',
    showSearch: false,
    items: [
      { label: `${C.yellow}请选择恢复级别:${C.reset}`, disabled: true },
      { label: '', disabled: true },
      { key: '1', label: '仅重置网关设置', desc: '端口/绑定/模式恢复默认，保留模型和渠道', value: 'gateway' },
      { key: '2', label: '清除模型配置', desc: '移除所有 AI 模型和 API Key', value: 'models' },
      { key: '3', label: '清除渠道配置', desc: '移除所有消息渠道配置', value: 'channels' },
      { key: '4', label: '完全恢复出厂', desc: '删除所有配置，重新初始化', value: 'full' },
      { label: '', disabled: true },
      { key: '0', label: '返回', desc: '', value: 'back' },
    ],
  });

  return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// 备份/还原菜单 (对应 backup_restore_menu)
// ═══════════════════════════════════════════════════════════════════════════

async function showBackupMenu() {
  const result = await select({
    title: '备份/还原配置',
    showSearch: false,
    items: [
      { key: '1', label: '创建配置备份', desc: '仅配置文件', value: 'create-config' },
      { key: '2', label: '创建完整备份', desc: '配置 + 状态数据', value: 'create-full' },
      { key: '3', label: '验证最新备份', desc: '', value: 'verify' },
      { key: '4', label: '查看备份列表', desc: '', value: 'list' },
      { key: '5', label: '从最新备份恢复配置', desc: '', value: 'restore' },
      { label: '', disabled: true },
      { key: '0', label: '返回', desc: '', value: 'back' },
    ],
  });

  return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// 模型配置处理函数 (与 oc-config.sh 完全对应)
// ═══════════════════════════════════════════════════════════════════════════

async function configureOpenAI() {
  resetRenderCount();
  console.log(`\n${C.bold}OpenAI 配置${C.reset}`);
  console.log(`${C.yellow}获取 API Key: https://platform.openai.com/api-keys${C.reset}\n`);

  const apiKey = await input({ prompt: '请输入 OpenAI API Key (sk-...)', placeholder: 'sk-...' });
  if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  const modelName = await selectProviderModel('openai', 'OpenAI 模型选择', 'gpt-5.6-sol');
  if (!modelName) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  authSetApikey('openai', apiKey);
  registerAndSetModel(`openai/${modelName}`);
  console.log(`\n${C.green}✅ OpenAI 已配置，活跃模型: openai/${modelName}${C.reset}\n`);
  return true;
}

async function configureAnthropic() {
  resetRenderCount();
  console.log(`\n${C.bold}Anthropic 配置${C.reset}`);
  console.log(`${C.yellow}获取 API Key: https://console.anthropic.com/settings/keys${C.reset}\n`);

  const apiKey = await input({ prompt: '请输入 Anthropic API Key (sk-ant-...)', placeholder: 'sk-ant-...' });
  if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  const modelName = await selectProviderModel('anthropic', 'Anthropic 模型选择', 'claude-sonnet-5');
  if (!modelName) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  authSetApikey('anthropic', apiKey);
  registerAndSetModel(`anthropic/${modelName}`);
  console.log(`\n${C.green}✅ Anthropic 已配置，活跃模型: anthropic/${modelName}${C.reset}\n`);
  return true;
}

async function configureGoogle() {
  resetRenderCount();
  console.log(`\n${C.bold}Google Gemini 配置${C.reset}`);
  console.log(`${C.yellow}获取 API Key: https://aistudio.google.com/apikey${C.reset}\n`);

  const apiKey = await input({ prompt: '请输入 Google AI API Key', placeholder: 'AIza...' });
  if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  const modelName = await selectProviderModel('google', 'Google Gemini 模型选择', 'gemini-2.5-pro');
  if (!modelName) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  authSetApikey('google', apiKey);
  registerAndSetModel(`google/${modelName}`);
  console.log(`\n${C.green}✅ Google Gemini 已配置，活跃模型: google/${modelName}${C.reset}\n`);
  return true;
}

async function configureOpenRouter() {
  resetRenderCount();
  console.log(`\n${C.bold}OpenRouter 配置${C.reset}`);
  console.log(`${C.yellow}获取 API Key: https://openrouter.ai/keys${C.reset}`);
  console.log(`${C.dim}聚合多家模型，一个 Key 可调用所有主流模型${C.reset}\n`);

  const apiKey = await input({ prompt: '请输入 OpenRouter API Key', placeholder: 'sk-or-...' });
  if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  // OpenRouter 的模型 ID 本身带上游 provider 前缀 (如 moonshotai/kimi-k2.6)
  const modelName = await selectProviderModel('openrouter', 'OpenRouter 模型选择', 'auto');
  if (!modelName) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  authSetApikey('openrouter', apiKey);
  registerCustomProvider('openrouter', 'https://openrouter.ai/api/v1', apiKey, modelName, modelName);
  registerAndSetModel(`openrouter/${modelName}`);
  console.log(`\n${C.green}✅ OpenRouter 已配置，活跃模型: openrouter/${modelName}${C.reset}\n`);
  return true;
}

async function configureCopilot() {
  resetRenderCount();
  console.log(`\n${C.bold}GitHub Copilot 配置${C.reset}`);
  console.log(`${C.yellow}需要有效的 GitHub Copilot 订阅 (Free/Pro/Business 均可)${C.reset}\n`);

  console.log(`${C.cyan}启动 GitHub Copilot OAuth 登录...${C.reset}`);
  console.log(`${C.dim}请在浏览器中打开显示的 URL，输入授权码完成登录${C.reset}\n`);

  try {
    await ocCmd('models', 'auth', 'login-github-copilot', '--yes');
    console.log(`\n${C.green}✅ GitHub Copilot OAuth 认证成功${C.reset}\n`);

    // 登录成功后动态发现通常可用，因此这里默认就尝试拉取一次
    const modelName = await selectProviderModel('github-copilot', 'GitHub Copilot 模型选择', 'gpt-5.5');
    if (modelName) {
      registerAndSetModel(`github-copilot/${modelName}`);
      console.log(`\n${C.green}✅ 活跃模型已设置: github-copilot/${modelName}${C.reset}\n`);
    }
    return true;
  } catch (e) {
    console.log(`\n${C.yellow}OAuth 授权已退出或失败${C.reset}\n`);
    return false;
  }
}

async function configureXAI() {
  resetRenderCount();
  console.log(`\n${C.bold}xAI Grok 配置${C.reset}`);
  console.log(`${C.yellow}获取 API Key: https://console.x.ai${C.reset}\n`);

  const apiKey = await input({ prompt: '请输入 xAI API Key', placeholder: '' });
  if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  const modelName = await selectProviderModel('xai', 'xAI Grok 模型选择', 'grok-4.3');
  if (!modelName) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  authSetApikey('xai', apiKey);
  registerAndSetModel(`xai/${modelName}`);
  console.log(`\n${C.green}✅ xAI Grok 已配置，活跃模型: xai/${modelName}${C.reset}\n`);
  return true;
}

async function configureQwen() {
  resetRenderCount();
  console.log(`\n${C.bold}阿里云通义千问 Qwen 配置${C.reset}\n`);

  const modeChoice = await select({
    title: '配置方式',
    showSearch: false,
    items: [
      { key: 'a', label: '通过官方向导配置', desc: 'Qwen Portal OAuth', value: 'portal' },
      { key: 'b', label: '百炼按量付费 API Key', desc: 'sk-xxx, 按 token 计费', value: 'bailian' },
      { key: 'c', label: 'Coding Plan 套餐', desc: `${C.green}★ 推荐${C.reset}`, value: 'codingplan' },
    ],
  });
  if (!modeChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  if (modeChoice.value === 'portal') {
    console.log(`\n${C.cyan}启动 Qwen OAuth 授权...${C.reset}\n`);
    try {
      enableAuthPlugins();
      await ocCmd('models', 'auth', 'login', '--provider', 'qwen-portal', '--set-default');
      console.log(`\n${C.green}✅ Qwen OAuth 授权完成${C.reset}\n`);
      return true;
    } catch {
      console.log(`\n${C.yellow}OAuth 授权已退出${C.reset}\n`);
      return false;
    }
  }

  if (modeChoice.value === 'bailian') {
    console.log(`\n${C.bold}百炼按量付费配置${C.reset}`);
    console.log(`${C.yellow}获取 API Key: https://dashscope.console.aliyun.com/apiKey${C.reset}`);
    console.log(`${C.dim}Base URL: https://dashscope.aliyuncs.com/compatible-mode/v1${C.reset}\n`);

    const apiKey = await input({ prompt: '请输入百炼 API Key (sk-...)', placeholder: 'sk-...' });
    if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

    const modelChoice = await select({
      title: '百炼模型选择',
      showSearch: false,
      items: [
        { key: 'a', label: 'qwen-max', desc: '千问Max 旗舰模型 (推荐)', value: 'qwen-max' },
        { key: 'b', label: 'qwen-plus', desc: '千问Plus 均衡之选', value: 'qwen-plus' },
        { key: 'c', label: 'qwen-flash', desc: '千问Flash 速度最快', value: 'qwen-flash' },
        { key: 'd', label: 'qwen-turbo', desc: '千问Turbo 经济实惠', value: 'qwen-turbo' },
        { key: 'e', label: 'qwen-long', desc: '千问Long 超长上下文', value: 'qwen-long' },
        { key: 'f', label: 'qwen3-coder-plus', desc: '代码专用旗舰', value: 'qwen3-coder-plus' },
        { key: 'g', label: 'qwq-plus', desc: 'QwQ推理模型', value: 'qwq-plus' },
        { key: 'h', label: '手动输入模型名', desc: '', value: 'custom' },
      ],
    });
    if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

    let modelName = modelChoice.value;
    if (modelChoice.value === 'custom') {
      modelName = await input({ prompt: '请输入模型名称', defaultValue: 'qwen-max' });
      if (!modelName) return false;
    }

    authSetApikey('dashscope', apiKey);
    registerCustomProvider('dashscope', 'https://dashscope.aliyuncs.com/compatible-mode/v1', apiKey, modelName, modelName);
    registerAndSetModel(`dashscope/${modelName}`);
    console.log(`\n${C.green}✅ 通义千问已配置 (按量付费)，活跃模型: dashscope/${modelName}${C.reset}\n`);
    return true;
  }

  if (modeChoice.value === 'codingplan') {
    console.log(`\n${C.bold}Coding Plan 套餐配置${C.reset}`);
    console.log(`${C.yellow}订阅套餐: https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan${C.reset}`);
    console.log(`${C.dim}Base URL: https://coding.dashscope.aliyuncs.com/v1${C.reset}\n`);

    const apiKey = await input({ prompt: '请输入 Coding Plan 专属 API Key (sk-sp-...)', placeholder: 'sk-sp-...' });
    if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

    const modelChoice = await select({
      title: 'Coding Plan 模型选择',
      showSearch: false,
      items: [
        { key: 'a', label: 'qwen3.5-plus', desc: 'Qwen3.5 Plus (推荐, 100万上下文)', value: 'qwen3.5-plus' },
        { key: 'b', label: 'qwen3-coder-plus', desc: 'Qwen3 Coder Plus', value: 'qwen3-coder-plus' },
        { key: 'c', label: 'qwen3-coder-next', desc: 'Qwen3 Coder Next', value: 'qwen3-coder-next' },
        { key: 'd', label: 'qwen3-max-2026-01-23', desc: 'Qwen3 Max', value: 'qwen3-max-2026-01-23' },
        { key: 'e', label: 'MiniMax-M2.5', desc: 'MiniMax M2.5', value: 'MiniMax-M2.5' },
        { key: 'f', label: 'glm-5', desc: '智谱 GLM-5', value: 'glm-5' },
        { key: 'g', label: 'kimi-k2.5', desc: 'Kimi K2.5', value: 'kimi-k2.5' },
        { key: 'h', label: '手动输入模型名', desc: '', value: 'custom' },
      ],
    });
    if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

    let modelName = modelChoice.value;
    if (modelChoice.value === 'custom') {
      modelName = await input({ prompt: '请输入模型名称', defaultValue: 'qwen3.5-plus' });
      if (!modelName) return false;
    }

    console.log(`\n${C.cyan}正在注册 Coding Plan 提供商 (含全部可用模型)...${C.reset}`);
    authSetApikey('bailian', apiKey);
    registerCodingPlanProvider(apiKey);
    registerAndSetModel(`bailian/${modelName}`);
    console.log(`\n${C.green}✅ Coding Plan 已配置，活跃模型: bailian/${modelName}${C.reset}`);
    console.log(`${C.dim}提示: 套餐内全部模型已注册，可随时在 WebChat 中通过 /model 切换${C.reset}\n`);
    return true;
  }

  return false;
}

async function configureSiliconFlow() {
  resetRenderCount();
  console.log(`\n${C.bold}硅基流动 SiliconFlow 配置${C.reset}`);
  console.log(`${C.yellow}获取 API Key: https://cloud.siliconflow.cn/account/ak${C.reset}`);
  console.log(`${C.yellow}国内推理平台，支持多种开源模型${C.reset}\n`);

  const apiKey = await input({ prompt: '请输入 SiliconFlow API Key', placeholder: '' });
  if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  // SiliconFlow 不是 OpenClaw 内置/官方插件 provider，走 OpenAI 兼容接入，
  // 因此 `openclaw models list --provider siliconflow` 拿不到列表，
  // 也无法用上游 catalog 核实模型 ID。
  //
  // 此处不再维护硬编码清单: 原列表里的 Qwen2.5-7B/72B、Yi-1.5-34B-Chat-16K、
  // glm-4-9b-chat 均已明显过期，而我们无法自动判断哪些仍然有效。
  // 让用户从官方模型广场复制当前 ID 更可靠，也不会随时间腐坏。
  console.log(`\n${C.cyan}请从官方模型广场复制模型 ID:${C.reset}`);
  console.log(`  ${C.cyan}https://cloud.siliconflow.cn/models${C.reset}`);
  console.log(`${C.dim}格式形如 deepseek-ai/DeepSeek-V3.2；Pro/ 前缀的模型仅支持充值余额支付${C.reset}\n`);

  const modelName = await input({ prompt: '请输入模型 ID', placeholder: 'deepseek-ai/DeepSeek-V3.2' });
  if (!modelName) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  authSetApikey('siliconflow', apiKey);
  registerCustomProvider('siliconflow', 'https://api.siliconflow.cn/v1', apiKey, modelName, modelName);
  registerAndSetModel(`siliconflow/${modelName}`);
  console.log(`\n${C.green}✅ SiliconFlow 已配置，活跃模型: siliconflow/${modelName}${C.reset}\n`);
  return true;
}

async function configureTencent() {
  resetRenderCount();
  console.log(`\n${C.bold}腾讯云大模型 Coding Plan 套餐配置${C.reset}`);
  console.log(`${C.yellow}订阅/管理套餐: https://hunyuan.cloud.tencent.com/#/app/subscription${C.reset}`);
  console.log(`${C.dim}文档: https://cloud.tencent.com/document/product/1772/128947${C.reset}\n`);

  const apiKey = await input({ prompt: '请输入 Coding Plan API Key (sk-sp-...)', placeholder: 'sk-sp-...' });
  if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  const modelChoice = await select({
    title: '腾讯云 Coding Plan 模型选择',
    showSearch: false,
    items: [
      { key: 'a', label: 'tc-code-latest', desc: '自动路由 (推荐)', value: 'tc-code-latest' },
      { key: 'b', label: 'hunyuan-t1', desc: '混元 T1 深度推理', value: 'hunyuan-t1' },
      { key: 'c', label: 'hunyuan-2.0-thinking', desc: '混元 2.0 Thinking', value: 'hunyuan-2.0-thinking' },
      { key: 'd', label: 'hunyuan-turbos', desc: '混元 TurboS 旗舰', value: 'hunyuan-turbos' },
      { key: 'e', label: 'hunyuan-2.0-instruct', desc: '混元 2.0 Instruct', value: 'hunyuan-2.0-instruct' },
      { key: 'f', label: 'glm-5', desc: '智谱 GLM-5', value: 'glm-5' },
      { key: 'g', label: 'kimi-k2.5', desc: 'Moonshot Kimi K2.5', value: 'kimi-k2.5' },
      { key: 'h', label: 'minimax-m2.5', desc: 'MiniMax M2.5', value: 'minimax-m2.5' },
      { key: 'z', label: '手动输入模型名', desc: '', value: 'custom' },
    ],
  });
  if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  let modelName = modelChoice.value;
  if (modelChoice.value === 'custom') {
    modelName = await input({ prompt: '请输入模型名称', defaultValue: 'tc-code-latest' });
    if (!modelName) return false;
  }

  console.log(`\n${C.cyan}正在注册腾讯云 Coding Plan 提供商 (含全部套餐模型)...${C.reset}`);
  authSetApikey('lkeap', apiKey);
  registerLkeapCodingPlanProvider(apiKey);
  registerAndSetModel(`lkeap/${modelName}`);
  console.log(`\n${C.green}✅ 腾讯云 Coding Plan 已配置，活跃模型: lkeap/${modelName}${C.reset}`);
  console.log(`${C.dim}提示: 套餐内全部模型已注册，可随时在 WebChat 中通过 /model 切换${C.reset}\n`);
  return true;
}

async function configureBaidu() {
  resetRenderCount();
  console.log(`\n${C.bold}百度千帆大模型配置${C.reset}`);
  console.log(`${C.yellow}获取 API Key: https://console.bce.baidu.com/qianfan/ais/console/onlineService${C.reset}\n`);

  const apiKey = await input({ prompt: '请输入百度千帆 API Key (Access Token)', placeholder: '' });
  if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  const modelName = await selectProviderModel('qianfan', '百度千帆模型选择', 'ernie-5.0-thinking-preview');
  if (!modelName) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  authSetApikey('qianfan', apiKey);
  registerCustomProvider('qianfan', 'https://aip.baidubce.com/rpc/2.0/ai_custom/v1/wenxinworkshop', apiKey, modelName, modelName);
  registerAndSetModel(`qianfan/${modelName}`);
  console.log(`\n${C.green}✅ 百度千帆已配置，活跃模型: qianfan/${modelName}${C.reset}\n`);
  return true;
}

async function configureZhipu() {
  resetRenderCount();
  console.log(`\n${C.bold}智谱 GLM / Z.AI 配置${C.reset}\n`);

  const methodChoice = await select({
    title: '认证方式',
    showSearch: false,
    items: [
      { key: 'a', label: 'CN (open.bigmodel.cn)', desc: `${C.green}★ 国内用户推荐${C.reset}`, value: 'cn' },
      { key: 'b', label: 'Coding-Plan-CN', desc: '智谱 Coding Plan 套餐', value: 'coding-plan-cn' },
      { key: 'c', label: 'Global (api.z.ai)', desc: '全球版', value: 'global' },
      { key: 'd', label: '手动输入', desc: '', value: 'custom' },
    ],
  });
  if (!methodChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  let baseUrl = 'https://open.bigmodel.cn/api/paas/v4';
  switch (methodChoice.value) {
    case 'cn':
      console.log(`${C.yellow}获取 API Key: https://open.bigmodel.cn/api-key${C.reset}`);
      break;
    case 'coding-plan-cn':
      baseUrl = 'https://open.bigmodel.cn/api/coding/paas/v4';
      console.log(`${C.yellow}Coding Plan 套餐 API Key${C.reset}`);
      break;
    case 'global':
      baseUrl = 'https://api.z.ai/api/paas/v4';
      console.log(`${C.yellow}全球版 API Key${C.reset}`);
      break;
    case 'custom':
      const customUrl = await input({ prompt: '请输入 Base URL', defaultValue: 'https://open.bigmodel.cn/api/paas/v4' });
      if (customUrl) baseUrl = customUrl;
      break;
  }

  const apiKey = await input({ prompt: '请输入智谱 API Key', placeholder: '' });
  if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  const modelName = await selectProviderModel('zai', '智谱 GLM 模型选择', 'glm-5.2');
  if (!modelName) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  // 智谱 GLM 使用原生 zai provider (OpenClaw 内置支持)
  registerCustomProvider('zai', baseUrl, apiKey, modelName, modelName, 128000, 4096);
  authSetApikey('zai', apiKey);
  registerAndSetModel(`zai/${modelName}`);
  console.log(`\n${C.green}✅ 智谱 GLM 已配置，活跃模型: zai/${modelName}${C.reset}`);
  console.log(`${C.dim}   Base URL: ${baseUrl}${C.reset}\n`);
  return true;
}

async function configureOllama() {
  resetRenderCount();
  console.log(`\n${C.bold}Ollama 本地模型配置${C.reset}`);
  console.log(`${C.yellow}Ollama 在本地或局域网运行大模型，无需 API Key${C.reset}`);
  console.log(`${C.yellow}安装 Ollama: https://ollama.com${C.reset}\n`);

  const modeChoice = await select({
    title: '连接方式',
    showSearch: false,
    items: [
      { key: 'a', label: '本机运行', desc: 'localhost:11434', value: 'local' },
      { key: 'b', label: '局域网其他设备', desc: '', value: 'remote' },
    ],
  });
  if (!modeChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  let ollamaUrl = 'http://127.0.0.1:11434';
  if (modeChoice.value === 'remote') {
    const host = await input({ prompt: 'Ollama 地址 (如 192.168.1.100:11434)', placeholder: '' });
    if (!host) { console.log(`${C.yellow}已取消${C.reset}`); return false; }
    ollamaUrl = host.startsWith('http') ? host : `http://${host}`;
    ollamaUrl = ollamaUrl.replace(/\/v1$/, '').replace(/\/$/, '');
  }

  // 尝试检测 Ollama 连通性
  console.log(`\n${C.cyan}检测 Ollama 连通性...${C.reset}`);
  let modelList = [];
  try {
    const stdout = execSync(`curl -sf --connect-timeout 3 --max-time 5 ${ollamaUrl}/api/tags`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    const data = JSON.parse(stdout);
    modelList = data.models || [];
    console.log(`${C.green}✅ Ollama 已连接${C.reset}`);
  } catch {
    console.log(`${C.yellow}⚠️  无法连接 Ollama (${ollamaUrl})${C.reset}`);
    const continueAnyway = await confirm({ prompt: '仍要继续配置?', defaultYes: false });
    if (!continueAnyway) return false;
  }

  let modelName = '';
  if (modelList.length > 0) {
    const items = modelList.map((m, i) => ({
      key: String(i + 1),
      label: m.name,
      desc: '',
      value: m.name,
    }));
    items.push({ key: 'm', label: '手动输入模型名', desc: '', value: 'custom' });

    const modelChoice = await select({
      title: '已安装的模型',
      showSearch: false,
      items,
    });

    if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }
    modelName = modelChoice.value === 'custom'
      ? await input({ prompt: '请输入模型名称', defaultValue: 'llama3.3' })
      : modelChoice.value;
  } else {
    modelName = await input({ prompt: '请输入模型名称', placeholder: 'llama3.3, qwen2.5...' });
  }

  if (!modelName) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  // 注册 Ollama 提供商
  const config = readConfig();
  if (!config.models) config.models = {};
  if (!config.models.providers) config.models.providers = {};
  config.models.mode = 'merge';
  config.models.providers['ollama'] = {
    baseUrl: ollamaUrl,
    apiKey: 'ollama-local',
    api: 'ollama',
    models: [{
      id: modelName,
      name: modelName,
      reasoning: false,
      input: ['text'],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 128000,
      maxTokens: 32000,
    }]
  };
  writeConfig(config);

  authSetApikey('ollama', 'ollama-local', 'ollama:local');
  registerAndSetModel(`ollama/${modelName}`);
  console.log(`\n${C.green}✅ Ollama 已配置，活跃模型: ollama/${modelName}${C.reset}`);
  console.log(`${C.cyan}   Ollama 地址: ${ollamaUrl}${C.reset}\n`);
  return true;
}

async function configureCustomAPI() {
  resetRenderCount();
  console.log(`\n${C.bold}自定义 OpenAI 兼容 API 配置${C.reset}`);
  console.log(`${C.yellow}支持任何兼容 OpenAI API 格式的服务商${C.reset}\n`);

  const baseUrl = await input({ prompt: 'API Base URL (如 https://api.example.com/v1)', placeholder: '' });
  if (!baseUrl) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  const apiKey = await input({ prompt: 'API Key', placeholder: 'sk-...' });
  if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  const modelName = await input({ prompt: '模型名称', placeholder: '' });
  if (!modelName) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  authSetApikey('openai-compatible', apiKey, 'openai-compatible:manual');
  registerCustomProvider('openai-compatible', baseUrl.replace(/\/$/, ''), apiKey, modelName, modelName);
  registerAndSetModel(`openai-compatible/${modelName}`);
  console.log(`\n${C.green}✅ 自定义 API 已配置，活跃模型: openai-compatible/${modelName}${C.reset}\n`);
  return true;
}

async function configureCustomAnthropic() {
  resetRenderCount();
  console.log(`\n${C.bold}自定义 Anthropic 兼容 API 配置${C.reset}`);
  console.log(`${C.yellow}支持任何兼容 Anthropic Messages API 格式的服务商${C.reset}\n`);

  const baseUrl = await input({ prompt: 'API Base URL', placeholder: 'https://api.anthropic.com' });
  if (!baseUrl) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  const apiKey = await input({ prompt: 'API Key', placeholder: 'sk-ant-...' });
  if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  // 复用 anthropic 的精选预设作为候选 (第三方兼容服务通常沿用同名模型 ID)，
  // 但保留手动输入出口: 自建/代理服务的模型名可能完全不同。
  const modelName = await selectProviderModel('anthropic', '模型选择 (可手动输入)', 'claude-sonnet-5');
  if (!modelName) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  const config = readConfig();
  if (!config.models) config.models = {};
  if (!config.models.providers) config.models.providers = {};
  config.models.mode = 'merge';
  config.models.providers['anthropic-compatible'] = {
    baseUrl: baseUrl.replace(/\/$/, ''),
    apiKey: apiKey,
    api: 'anthropic-messages',
    models: [{
      id: modelName,
      name: modelName,
      reasoning: false,
      input: ['text', 'image'],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 200000,
      maxTokens: 16000,
    }]
  };
  writeConfig(config);

  authSetApikey('anthropic-compatible', apiKey, 'anthropic-compatible:manual');
  registerAndSetModel(`anthropic-compatible/${modelName}`);
  console.log(`\n${C.green}✅ 自定义 Anthropic API 已配置，活跃模型: anthropic-compatible/${modelName}${C.reset}\n`);
  return true;
}

async function configureYiwanAIFanAPI() {
  resetRenderCount();
  const providerName = 'yiwanai';
  const baseUrl = 'https://api.910501.xyz/v1';
  const modelName = 'gpt-5.5';

  console.log(`\n${C.bold}一万AI分享 粉丝专享 API 配置${C.reset}`);
  console.log(`${C.yellow}OpenAI 兼容模式；Base URL 和模型已内置，只需要填写 API Key。${C.reset}`);
  console.log(`${C.dim}Base URL: ${baseUrl}${C.reset}`);
  console.log(`${C.dim}Model: ${modelName}${C.reset}\n`);

  const apiKey = await input({ prompt: 'API Key', placeholder: 'sk-...' });
  if (!apiKey) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  authSetApikey(providerName, apiKey, `${providerName}:fan`);
  registerCustomProvider(providerName, baseUrl, apiKey, modelName, modelName, 1000000, 32000);
  const config = readConfig();
  const provider = config.models?.providers?.[providerName];
  if (provider?.models?.[0]) {
    provider.models[0].reasoning = true;
  }
  writeConfig(config);
  registerAndSetModel(`${providerName}/${modelName}`);
  console.log(`\n${C.green}✅ 一万AI分享粉丝专享 API 已配置，活跃模型: ${providerName}/${modelName}${C.reset}\n`);
  return true;
}

async function launchWizard() {
  resetRenderCount();
  console.log(`\n${C.cyan}启动官方完整模型配置向导...${C.reset}\n`);
  console.log(`${C.yellow}提示: ↑↓ 移动, Tab/空格 选中, 回车 确认${C.reset}\n`);
  try {
    enableAuthPlugins();
    await ocCmd('configure', '--section', 'model');
    return true;
  } catch (e) {
    console.log(`${C.yellow}配置向导已退出${C.reset}\n`);
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 模型配置处理入口
// ═══════════════════════════════════════════════════════════════════════════

async function handleModelConfig() {
  while (true) {
    const choice = await showModelMenu();
    if (!choice || choice.value === 'back') break;

    resetRenderCount();
    let configured = false;

    switch (choice.value) {
      case 'wizard': {
        const ok = await launchWizard();
        if (ok) await askRestart();
        break;
      }
      case 'openai': configured = await configureOpenAI(); break;
      case 'anthropic': configured = await configureAnthropic(); break;
      case 'google': configured = await configureGoogle(); break;
      case 'openrouter': configured = await configureOpenRouter(); break;
      case 'copilot': configured = await configureCopilot(); break;
      case 'xai': configured = await configureXAI(); break;
      case 'qwen': configured = await configureQwen(); break;
      case 'siliconflow': configured = await configureSiliconFlow(); break;
      case 'tencent': configured = await configureTencent(); break;
      case 'baidu': configured = await configureBaidu(); break;
      case 'zhipu': configured = await configureZhipu(); break;
      case 'ollama': configured = await configureOllama(); break;
      case 'custom': configured = await configureCustomAPI(); break;
      case 'custom-anthropic': configured = await configureCustomAnthropic(); break;
      case 'yiwanai-fan': configured = await configureYiwanAIFanAPI(); break;
    }

    if (configured) await askRestart();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 设置活动模型 (对应 set_active_model)
// ═══════════════════════════════════════════════════════════════════════════

async function handleSetActiveModel() {
  resetRenderCount();
  console.log(`\n${C.bold}设定当前活跃模型${C.reset}\n`);

  const currentModel = getCurrentModel();
  console.log(`  当前活跃模型: ${C.green}${C.bold}${currentModel || '未设置'}${C.reset}\n`);

  try {
    const result = await ocCmd('models', 'list', '--json');
    const modelsData = JSON.parse(result.stdout);
    const models = modelsData.models || [];

    if (models.length > 0) {
      const items = models.map((m, i) => ({
        key: String(i + 1),
        label: m.key,
        desc: m.name && m.name !== m.key ? `(${m.name})` : '',
        value: m.key,
        selected: m.key === currentModel,
      }));

      items.push({ label: '', disabled: true });
      items.push({ key: 'm', label: '手动输入模型 ID', desc: '', value: 'manual' });
      items.push({ key: '0', label: '返回', desc: '', value: 'back' });

      const choice = await select({
        title: '已配置的模型',
        showSearch: true,
        items,
      });

      if (!choice || choice.value === 'back') return;

      if (choice.value === 'manual') {
        const manualModel = await input({
          prompt: '请输入模型 ID',
          placeholder: 'openai/gpt-5.6-sol',
          defaultValue: currentModel || '',
        });
        if (manualModel) {
          registerAndSetModel(manualModel);
          console.log(`\n${C.green}✅ 活跃模型已设为: ${manualModel}${C.reset}\n`);
          await askRestart();
        }
      } else {
        registerAndSetModel(choice.value);
        console.log(`\n${C.green}✅ 活跃模型已切换为: ${choice.value}${C.reset}\n`);
        await askRestart();
      }
    } else {
      console.log(`${C.yellow}尚未配置任何模型。${C.reset}`);
      console.log(`${C.yellow}请先通过「配置 AI 模型提供商」添加模型。${C.reset}\n`);

      const manualModel = await input({
        prompt: '直接输入模型 ID 设置 (留空返回)',
        defaultValue: '',
      });
      if (manualModel) {
        registerAndSetModel(manualModel);
        console.log(`\n${C.green}✅ 活跃模型已设为: ${manualModel}${C.reset}\n`);
        await askRestart();
      }
    }
  } catch (e) {
    console.log(`${C.red}获取模型列表失败: ${e.message}${C.reset}\n`);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 消息渠道处理 (对应 configure_channels 等函数)
// ═══════════════════════════════════════════════════════════════════════════

async function handleChannels() {
  while (true) {
    const choice = await showChannelsMenu();
    if (!choice || choice.value === 'back') break;

    resetRenderCount();

    switch (choice.value) {
      case 'qq': {
        console.log(`\n${C.bold}QQ 机器人配置${C.reset}\n`);
        console.log(`${C.yellow}获取 App ID 和 App Secret:${C.reset}`);
        console.log(`  1. 前往 ${C.cyan}https://q.qq.com/qqbot/openclaw/login.html${C.reset}`);
        console.log(`  2. 用手机 QQ 扫码注册/登录`);
        console.log(`  3. 创建机器人后复制 App ID 和 App Secret\n`);

        const appId = await input({ prompt: '请输入 QQ 机器人 App ID', placeholder: '' });
        if (!appId) { console.log(`${C.yellow}已取消${C.reset}`); break; }

        const appSecret = await input({ prompt: '请输入 QQ 机器人 App Secret', placeholder: '' });
        if (!appSecret) { console.log(`${C.yellow}已取消${C.reset}`); break; }

        // 写入配置
        const cfg = readConfig();
        if (!cfg.channels) cfg.channels = {};
        if (!cfg.channels.qqbot) cfg.channels.qqbot = {};
        cfg.channels.qqbot.appId = appId;
        cfg.channels.qqbot.clientSecret = appSecret;
        cfg.channels.qqbot.enabled = true;
        writeConfig(cfg);

        console.log(`\n${C.green}✅ QQ 机器人配置已保存${C.reset}\n`);
        await askRestart();
        break;
      }
      case 'telegram': {
        console.log(`\n${C.bold}Telegram Bot 配置${C.reset}\n`);
        console.log(`${C.yellow}获取 Bot Token:${C.reset}`);
        console.log(`  1. 打开 Telegram → 搜索 ${C.cyan}@BotFather${C.reset}`);
        console.log(`  2. 发送 ${C.cyan}/newbot${C.reset} → 按提示创建`);
        console.log(`  3. 复制生成的 Token\n`);

        const token = await input({ prompt: '请输入 Telegram Bot Token', placeholder: '123456:ABC...' });
        if (!token) { console.log(`${C.yellow}已取消${C.reset}`); break; }

        // 验证格式
        if (!/^[0-9]+:[A-Za-z0-9_-]+$/.test(token)) {
          console.log(`${C.red}✗ Token 格式错误${C.reset}`);
          console.log(`${C.yellow}正确格式: 123456789:ABCdefGHIjklMNOpqr${C.reset}\n`);
          break;
        }

        const cfg = readConfig();
        if (!cfg.channels) cfg.channels = {};
        if (!cfg.channels.telegram) cfg.channels.telegram = {};
        cfg.channels.telegram.botToken = token;
        writeConfig(cfg);

        console.log(`\n${C.green}✅ Telegram Bot Token 已保存${C.reset}\n`);
        await askRestart();
        break;
      }
      case 'discord': {
        console.log(`\n${C.bold}Discord Bot 配置${C.reset}\n`);
        console.log(`${C.yellow}获取 Bot Token:${C.cyan} https://discord.com/developers/applications${C.reset}\n`);

        const token = await input({ prompt: '请输入 Discord Bot Token', placeholder: '' });
        if (!token) { console.log(`${C.yellow}已取消${C.reset}`); break; }

        const cfg = readConfig();
        if (!cfg.channels) cfg.channels = {};
        if (!cfg.channels.discord) cfg.channels.discord = {};
        cfg.channels.discord.botToken = token;
        writeConfig(cfg);

        console.log(`\n${C.green}✅ Discord Bot Token 已保存${C.reset}\n`);
        await askRestart();
        break;
      }
      case 'feishu': {
        console.log(`\n${C.bold}飞书 Bot 配置${C.reset}\n`);
        console.log(`${C.cyan}即将执行飞书官方安装向导...${C.reset}\n`);

        const doInstall = await confirm({ prompt: '是否开始安装?', defaultYes: true });
        if (!doInstall) break;

        console.log(`\n${C.cyan}正在启动飞书安装向导...${C.reset}\n`);
        try {
          const npxBin = fs.existsSync(`${NODE_BASE}/bin/npx`) ? `${NODE_BASE}/bin/npx` : 'npx';
          await runCommand(npxBin, ['-y', '@larksuite/openclaw-lark-tools', 'install'], {
            interactive: true,
            cwd: OC_DATA,
            env: { HOME: OC_DATA, PATH: `${NODE_BASE}/bin:${process.env.PATH || ''}` }
          });
        } catch (e) {
          console.log(`${C.yellow}安装向导已退出${C.reset}\n`);
        }
        break;
      }
      case 'slack': {
        console.log(`\n${C.bold}Slack Bot 配置${C.reset}\n`);
        console.log(`${C.yellow}获取 Bot Token:${C.cyan} https://api.slack.com/apps${C.reset}\n`);

        const token = await input({ prompt: '请输入 Slack Bot Token (xoxb-...)', placeholder: '' });
        if (!token) { console.log(`${C.yellow}已取消${C.reset}`); break; }

        const cfg = readConfig();
        if (!cfg.channels) cfg.channels = {};
        if (!cfg.channels.slack) cfg.channels.slack = {};
        cfg.channels.slack.botToken = token;
        writeConfig(cfg);

        console.log(`\n${C.green}✅ Slack Bot Token 已保存${C.reset}\n`);
        await askRestart();
        break;
      }
      case 'whatsapp': {
        const gwToken = jsonGet('gateway.auth.token') || '';
        const gwPort = jsonGet('gateway.port') || '18789';
        console.log(`\n${C.yellow}WhatsApp 需要通过 Web 控制台扫码配对:${C.reset}`);
        console.log(`${C.cyan}http://<你的路由器IP>:${gwPort}/?token=${gwToken}${C.reset}`);
        console.log(`打开后进入 Channels → WhatsApp 扫码即可。\n`);
        await input({ prompt: '按回车继续', defaultValue: '' });
        break;
      }
      case 'telegram-pairing': {
        // 配对 (pairing) 与 Bot Token 配置是两件不同的事:
        //   - Token 配置 -> 上面的 'telegram' 分支 / channels add --bot-token
        //   - 用户配对   -> openclaw pairing list / pairing approve
        // 旧实现调用的 `models auth login-telegram-bot` 在 2026.6+ 已不存在
        // (实测报 Too many arguments for this command)，这里改为对齐上游
        // pairing 命令，与 oc-config.sh 的 telegram_pairing() 行为保持一致。
        console.log(`\n${C.bold}🤝 Telegram 配对助手${C.reset}\n`);

        const tgToken = jsonGet('channels.telegram.botToken');
        if (!tgToken) {
          console.log(`${C.yellow}未检测到 Telegram Bot Token，请先在「Telegram」中配置 Token。${C.reset}\n`);
          await input({ prompt: '按回车返回', defaultValue: '' });
          break;
        }

        // 先确认 Token 与网络可用，避免用户在配对环节盲等
        console.log(`${C.cyan}诊断 Telegram API 连通性...${C.reset}`);
        let botName = '';
        try {
          const probe = execSync(
            `curl -s --connect-timeout 5 --max-time 10 "https://api.telegram.org/bot${tgToken}/getMe"`,
            { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }
          );
          if (/"ok"\s*:\s*true/.test(probe)) {
            const m = probe.match(/"username"\s*:\s*"([^"]+)"/);
            botName = m ? m[1] : '';
            console.log(`${C.green}✅ Telegram API 连通正常${botName ? ` — @${botName}` : ''}${C.reset}`);
          } else {
            console.log(`${C.red}❌ Telegram API 连通检测未通过${C.reset}`);
            console.log(`${C.yellow}   可能原因: Token 不正确、网络不通 或 Telegram 被屏蔽${C.reset}`);
            console.log(`${C.cyan}   建议: 重新配置 Token 或检查代理/网络设置${C.reset}\n`);
            await input({ prompt: '按回车返回', defaultValue: '' });
            break;
          }
        } catch {
          console.log(`${C.yellow}⚠️  无法完成连通性检测，继续尝试配对${C.reset}`);
        }

        console.log('');
        console.log(`${C.green}请在 Telegram 中向 Bot 发送 /start，然后回到这里继续${C.reset}`);
        console.log('');
        const go = await input({ prompt: '发送 /start 后按回车继续 (输入 q 退出)', defaultValue: '' });
        if (String(go).toLowerCase() === 'q') break;

        const approveCode = (code) => {
          const res = ocCmdCapture('pairing', 'approve', 'telegram', code);
          return res.ok || /approved|success|ok/i.test(res.stdout);
        };

        let paired = false;
        for (let attempt = 1; attempt <= 3 && !paired; attempt++) {
          console.log(`${C.cyan}检测配对请求... (第 ${attempt}/3 轮)${C.reset}`);
          const listed = ocCmdCapture('pairing', 'list', 'telegram', '--json');
          const codes = parsePairingCodes(listed.stdout);

          for (const code of codes) {
            console.log(`${C.cyan}发现配对请求: ${code}${C.reset}`);
            if (approveCode(code)) {
              console.log(`\n${C.green}${C.bold}🎉 Telegram 配对成功！${C.reset}`);
              paired = true;
            } else {
              console.log(`${C.yellow}配对码 ${code} 处理失败${C.reset}`);
            }
          }

          if (!paired && attempt < 3) {
            console.log(`${C.yellow}未检测到，等待 8 秒后重试...${C.reset}`);
            await new Promise((r) => setTimeout(r, 8000));
          }
        }

        if (!paired) {
          console.log('');
          console.log(`${C.yellow}未自动检测到配对请求。${C.reset}`);
          console.log(`${C.cyan}如果 Bot 已回复配对码，可手动输入 (回车跳过):${C.reset}`);
          const manual = await input({ prompt: '配对码', defaultValue: '' });
          if (manual) {
            if (approveCode(String(manual).trim())) {
              console.log(`${C.green}${C.bold}🎉 Telegram 配对成功！${C.reset}`);
              paired = true;
            } else {
              console.log(`${C.yellow}配对失败，请确认配对码是否正确或重新发送 /start${C.reset}`);
            }
          }
        }

        if (paired) {
          console.log(`\n${C.cyan}正在重启 Gateway 使配对生效...${C.reset}`);
          await restartGateway();
          console.log(`${C.green}✅ 现在可以在 Telegram 中与 Bot 对话了！${C.reset}\n`);
        } else {
          console.log('');
          await input({ prompt: '按回车返回', defaultValue: '' });
        }
        break;
      }
      case 'wizard': {
        resetRenderCount();
        console.log(`\n${C.cyan}启动官方渠道配置向导...${C.reset}\n`);
        console.log(`${C.yellow}提示: ↑↓ 移动, Tab/空格 选中, 回车 确认${C.reset}\n`);
        let ok = false;
        try {
          enableAuthPlugins();
          await ocCmd('configure', '--section', 'channels');
          ok = true;
        } catch (e) {
          console.log(`${C.yellow}配置向导已退出${C.reset}\n`);
        }
        if (ok) await askRestart();
        break;
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 健康检查 (对应 health_check)
// ═══════════════════════════════════════════════════════════════════════════

async function handleHealthCheck() {
  resetRenderCount();
  console.log(`\n${C.bold}健康检查${C.reset}\n`);

  // 验证配置文件
  console.log(`${C.cyan}验证配置文件格式...${C.reset}`);
  try {
    const result = await ocCmd('config', 'validate', '--json');
    const validateData = JSON.parse(result.stdout);
    if (validateData.valid) {
      console.log(`${C.green}✅ 配置文件格式有效${C.reset}\n`);
    } else if (validateData.errors && validateData.errors.length > 0) {
      console.log(`${C.red}❌ 配置文件存在错误:${C.reset}`);
      validateData.errors.forEach(e => console.log(`   ${C.yellow}• ${e.message}${C.reset}`));
      console.log('');
    }
  } catch (e) {
    console.log(`${C.yellow}⚠️ 无法验证配置文件${C.reset}\n`);
  }

  // 检查端口
  console.log(`${C.cyan}检查服务状态...${C.reset}`);
  try {
    await runCommand('/etc/init.d/openclaw', ['status_service']);
  } catch (e) {}

  console.log(`\n${C.cyan}提示: 查看详细日志请运行 logread -e openclaw${C.reset}`);
  await input({ prompt: '按回车继续', defaultValue: '' });
}

// ═══════════════════════════════════════════════════════════════════════════
// 显示当前配置 (对应 show_current_config)
// ═══════════════════════════════════════════════════════════════════════════

async function handleShowConfig() {
  resetRenderCount();

  const gwPort = jsonGet('gateway.port') || '18789';
  const gwBind = jsonGet('gateway.bind') || 'lan';
  const gwMode = jsonGet('gateway.mode') || 'local';
  const currentModel = getCurrentModel();

  console.log(`\n${C.green}┌──────────────────────────────────────────────────────────┐${C.reset}`);
  console.log(`${C.green}│${C.reset}  📋 ${C.bold}当前配置概览${C.reset}`);
  console.log(`${C.green}├──────────────────────────────────────────────────────────┤${C.reset}`);
  console.log(`${C.green}│${C.reset}  网关端口 ............ ${C.cyan}${gwPort}${C.reset}`);
  console.log(`${C.green}│${C.reset}  绑定模式 ............ ${C.cyan}${gwBind}${C.reset}`);
  console.log(`${C.green}│${C.reset}  运行模式 ............ ${C.cyan}${gwMode}${C.reset}`);
  console.log(`${C.green}│${C.reset}  活跃模型 ............ ${currentModel ? C.cyan + currentModel : C.yellow + '未配置'}${C.reset}`);

  // 渠道状态
  console.log(`${C.green}├──────────────────────────────────────────────────────────┤${C.reset}`);
  console.log(`${C.green}│${C.reset}  ${C.bold}渠道配置状态${C.reset}`);

  const tgToken = jsonGet('channels.telegram.botToken');
  const dcToken = jsonGet('channels.discord.botToken');
  const fsAppId = jsonGet('channels.feishu.appId');
  const skToken = jsonGet('channels.slack.botToken');
  const qqAppId = jsonGet('channels.qqbot.appId');

  if (qqAppId) {
    console.log(`${C.green}│${C.reset}  QQ (qqbot) ......... ${C.green}✅ 已配置${C.reset} (AppID: ${qqAppId.slice(0, 8)}...)`);
  } else {
    console.log(`${C.green}│${C.reset}  QQ (qqbot) ......... ${C.yellow}❌ 未配置${C.reset}`);
  }
  if (tgToken) {
    console.log(`${C.green}│${C.reset}  Telegram ........... ${C.green}✅ 已配置${C.reset} (${tgToken.slice(0, 12)}...)`);
  } else {
    console.log(`${C.green}│${C.reset}  Telegram ........... ${C.yellow}❌ 未配置${C.reset}`);
  }
  if (dcToken) {
    console.log(`${C.green}│${C.reset}  Discord ............ ${C.green}✅ 已配置${C.reset}`);
  } else {
    console.log(`${C.green}│${C.reset}  Discord ............ ${C.yellow}❌ 未配置${C.reset}`);
  }
  if (fsAppId) {
    console.log(`${C.green}│${C.reset}  飞书 ............... ${C.green}✅ 已配置${C.reset} (AppID: ${fsAppId.slice(0, 6)}...)`);
  } else {
    console.log(`${C.green}│${C.reset}  飞书 ............... ${C.yellow}❌ 未配置${C.reset}`);
  }
  if (skToken) {
    console.log(`${C.green}│${C.reset}  Slack .............. ${C.green}✅ 已配置${C.reset}`);
  } else {
    console.log(`${C.green}│${C.reset}  Slack .............. ${C.yellow}❌ 未配置${C.reset}`);
  }

  console.log(`${C.green}└──────────────────────────────────────────────────────────┘${C.reset}\n`);

  await input({ prompt: '按回车继续', defaultValue: '' });
}

// ═══════════════════════════════════════════════════════════════════════════
// 设备配对管理 (Control UI / 浏览器配对审批)
// ═══════════════════════════════════════════════════════════════════════════

async function manageDevicePairing() {
  while (true) {
    resetRenderCount();
    console.log(`\n${C.bold}📱 设备配对管理 (Control UI / 浏览器配对审批)${C.reset}\n`);
    console.log(`${C.yellow}⚠️  风险提示：${C.reset}`);
    console.log(`${C.yellow}   批准设备配对后，该浏览器/客户端将获得 OpenClaw 网关的完全控制权限。${C.reset}`);
    console.log(`${C.yellow}   请确保在受信任的局域网环境，并仅在您本人正在连接时批准！${C.reset}\n`);

    const listed = ocCmdCapture('devices', 'list', '--json');
    let pending = [];
    let paired = [];
    try {
      const data = JSON.parse(listed.stdout);
      if (Array.isArray(data.pending)) pending = data.pending;
      if (Array.isArray(data.paired)) paired = data.paired;
    } catch (e) {
      const m = (listed.stdout || '').match(/(\{[\s\S]*"pending"[\s\S]*\})/);
      if (m) {
        try {
          const d = JSON.parse(m[1]);
          if (Array.isArray(d.pending)) pending = d.pending;
          if (Array.isArray(d.paired)) paired = d.paired;
        } catch (_) {}
      }
    }

    function renderPairedDevices(list) {
      console.log(`\n${C.bold}📋 已配对设备 (${list.length})${C.reset}\n`);
      if (list.length === 0) {
        console.log(`  ${C.dim}暂无已配对设备记录${C.reset}`);
      } else {
        list.forEach((d, idx) => {
          console.log(`  ${C.cyan}[${idx + 1}]${C.reset} 设备 ID: ${d.deviceId || ''}`);
          console.log(`      平台: ${d.platform || '未知'} | 客户端: ${d.clientId || ''} | IP: ${d.remoteIp || ''}`);
        });
      }
      console.log('');
    }

    if (pending.length > 0) {
      console.log(`${C.green}🔔 当前检测到 ${pending.length} 个待配对请求：${C.reset}\n`);
      pending.forEach((item, idx) => {
        const rid = item.requestId || '未知ID';
        const ip = item.remoteIp || item.ip || '未知IP';
        const client = item.clientId || item.clientMode || 'webchat';
        const plat = item.platform || '';
        const role = item.role || (item.roles && item.roles.join(',')) || 'operator';
        console.log(`  ${C.cyan}[${idx + 1}]${C.reset} 请求 ID: ${C.bold}${rid}${C.reset}`);
        console.log(`      来源 IP: ${C.green}${ip}${C.reset} | 客户端: ${client}${plat ? ' (' + plat + ')' : ''} | 角色: ${role}`);
      });
      console.log('');

      const choice = await select({
        title: '请选择操作',
        showSearch: false,
        items: [
          { key: '1', label: '一键批准所有待配对请求', desc: `共 ${pending.length} 个待审批`, value: 'approve-all' },
          { key: '2', label: '选择指定请求批准', desc: '', value: 'approve-select' },
          { key: '3', label: '刷新待配对列表', desc: '', value: 'refresh' },
          { key: '4', label: '查看已配对设备列表', desc: `当前已配对 ${paired.length} 台设备`, value: 'view-paired' },
          { label: '', disabled: true },
          { key: '0', label: '返回上级菜单', desc: '', value: 'back' },
        ],
      });

      if (!choice || choice.value === 'back') break;
      if (choice.value === 'refresh') continue;
      if (choice.value === 'view-paired') {
        renderPairedDevices(paired);
        await input({ prompt: '按回车继续', defaultValue: '' });
        continue;
      }

      if (choice.value === 'approve-all') {
        const ok = await confirm({
          message: `${C.yellow}确认一键批准全部 ${pending.length} 个设备配对请求吗？${C.reset}`,
          defaultValue: true,
        });
        if (ok) {
          console.log(`\n${C.cyan}正在批准设备配对...${C.reset}`);
          let success = 0;
          for (const item of pending) {
            const res = ocCmdCapture('devices', 'approve', item.requestId);
            if (res.ok || /approved|success/i.test(res.stdout)) {
              console.log(`${C.green}✅ 已批准: ${item.requestId} (${item.remoteIp || ''})${C.reset}`);
              success++;
            } else {
              console.log(`${C.red}❌ 批准失败: ${item.requestId} — ${res.stdout || res.stderr}${C.reset}`);
            }
          }
          fixStatePermissions();
          console.log(`\n${C.green}操作完成：成功 ${success}/${pending.length} 个${C.reset}`);
          await input({ prompt: '按回车继续', defaultValue: '' });
        }
      } else if (choice.value === 'approve-select') {
        const selectItems = pending.map((item, idx) => ({
          key: String(idx + 1),
          label: `批准: ${item.remoteIp || '设备'} (${(item.requestId || '').slice(0, 8)}...)`,
          desc: `IP: ${item.remoteIp || ''} | ${item.platform || ''}`,
          value: item.requestId,
        }));
        selectItems.push({ label: '', disabled: true });
        selectItems.push({ key: '0', label: '取消', desc: '', value: 'cancel' });

        const picked = await select({
          title: '请选择要批准的设备请求',
          showSearch: false,
          items: selectItems,
        });

        if (picked && picked.value !== 'cancel') {
          const res = ocCmdCapture('devices', 'approve', picked.value);
          if (res.ok || /approved|success/i.test(res.stdout)) {
            fixStatePermissions();
            console.log(`\n${C.green}✅ 成功批准设备请求: ${picked.value}${C.reset}`);
          } else {
            console.log(`\n${C.red}❌ 批准失败: ${res.stdout || res.stderr}${C.reset}`);
          }
          await input({ prompt: '按回车继续', defaultValue: '' });
        }
      }
    } else {
      console.log(`${C.dim}当前无待配对设备请求。${C.reset}`);
      console.log(`${C.dim}(在浏览器访问 OpenClaw Web 控制台时若提示「需要设备配对」，在此处刷新即可发现)${C.reset}\n`);

      const choice = await select({
        title: '设备配对管理',
        showSearch: false,
        items: [
          { key: '1', label: '刷新待配对列表', desc: '', value: 'refresh' },
          { key: '2', label: '手动输入 Request ID 批准', desc: '', value: 'manual' },
          { key: '3', label: '查看已配对设备列表', desc: `当前已配对 ${paired.length} 台设备`, value: 'view-paired' },
          { label: '', disabled: true },
          { key: '0', label: '返回上级菜单', desc: '', value: 'back' },
        ],
      });

      if (!choice || choice.value === 'back') break;
      if (choice.value === 'refresh') continue;

      if (choice.value === 'manual') {
        const reqId = await input({ prompt: '请输入待批准的 Request ID', defaultValue: '' });
        if (reqId && reqId.trim()) {
          const res = ocCmdCapture('devices', 'approve', reqId.trim());
          if (res.ok || /approved|success/i.test(res.stdout)) {
            fixStatePermissions();
            console.log(`\n${C.green}✅ 成功批准设备请求: ${reqId.trim()}${C.reset}`);
          } else {
            console.log(`\n${C.red}❌ 批准失败: ${res.stdout || res.stderr}${C.reset}`);
          }
          await input({ prompt: '按回车继续', defaultValue: '' });
        }
      } else if (choice.value === 'view-paired') {
        renderPairedDevices(paired);
        await input({ prompt: '按回车继续', defaultValue: '' });
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 高级配置处理 (对应 advanced_menu)
// ═══════════════════════════════════════════════════════════════════════════

async function handleAdvancedConfig() {
  while (true) {
    const choice = await showAdvancedMenu();
    if (!choice || choice.value === 'back') break;

    resetRenderCount();

    switch (choice.value) {
      case 'port': {
        const newPort = await input({
          prompt: '请输入 Gateway 端口',
          defaultValue: String(jsonGet('gateway.port') || '18789'),
        });
        if (newPort) {
          jsonSet('gateway.port', parseInt(newPort));
          try { execSync(`uci set openclaw.main.port="${newPort}" && uci commit openclaw`, { stdio: 'ignore' }); } catch {}
          console.log(`\n${C.green}✅ 端口已设置为 ${newPort}${C.reset}\n`);
          await askRestart();
        }
        break;
      }
      case 'bind': {
        const bindChoice = await select({
          title: '绑定地址选项',
          showSearch: false,
          items: [
            // 取值必须与 schema 的 gateway.bind 枚举一致:
            // auto/lan/loopback/custom/tailnet。旧选项 all 不被上游接受
            // (实测: gateway.bind: Invalid input)，监听所有接口用 custom。
            { key: '1', label: 'lan', desc: '仅 LAN 接口 (推荐)', value: 'lan' },
            { key: '2', label: 'loopback', desc: '仅本机访问', value: 'loopback' },
            { key: '3', label: 'auto', desc: '自动选择', value: 'auto' },
            { key: '4', label: 'custom', desc: '自定义地址 (0.0.0.0 = 所有接口)', value: 'custom' },
            { key: '5', label: 'tailnet', desc: 'Tailscale 网络', value: 'tailnet' },
          ],
        });
        if (bindChoice) {
          if (bindChoice.value === 'custom') {
            const host = await input({ prompt: '监听地址', defaultValue: jsonGet('gateway.customBindHost') || '0.0.0.0' });
            if (host) jsonSet('gateway.customBindHost', host);
          }
          jsonSet('gateway.bind', bindChoice.value);
          try { execSync(`uci set openclaw.main.bind="${bindChoice.value}" && uci commit openclaw`, { stdio: 'ignore' }); } catch {}
          console.log(`\n${C.green}✅ 绑定地址已设置为 ${bindChoice.value}${C.reset}\n`);
          await askRestart();
        }
        break;
      }
      case 'mode': {
        const modeChoice = await select({
          title: '运行模式选项',
          showSearch: false,
          items: [
            { key: '1', label: 'local', desc: '本地模式 (推荐)', value: 'local' },
            { key: '2', label: 'remote', desc: '远程模式', value: 'remote' },
          ],
        });
        if (modeChoice) {
          jsonSet('gateway.mode', modeChoice.value);
          console.log(`\n${C.green}✅ 运行模式已设置为 ${modeChoice.value}${C.reset}\n`);
          await askRestart();
        }
        break;
      }
      case 'loglevel': {
        const levelChoice = await select({
          title: '日志级别选项',
          showSearch: false,
          items: [
            // 取值与 schema 的 logging.level 枚举一致 (7 档)
            { key: '1', label: 'info', desc: '常规信息 (默认)', value: 'info' },
            { key: '2', label: 'warn', desc: '警告及以上', value: 'warn' },
            { key: '3', label: 'error', desc: '仅错误', value: 'error' },
            { key: '4', label: 'debug', desc: '详细调试', value: 'debug' },
            { key: '5', label: 'trace', desc: '最详细 (排障用)', value: 'trace' },
            { key: '6', label: 'fatal', desc: '仅致命错误', value: 'fatal' },
            { key: '7', label: 'silent', desc: '完全静默', value: 'silent' },
          ],
        });
        if (levelChoice) {
          // 正确键是顶层 logging.level；gateway.logLevel 不在 schema 中，
          // 写入会被上游忽略，表现为"显示已设置但从未生效"。
          jsonSet('logging.level', levelChoice.value);
          // 清理旧配置里可能残留的错误键，避免界面回显到失效值
          try {
            const cfg = readConfig();
            if (cfg.gateway && Object.prototype.hasOwnProperty.call(cfg.gateway, 'logLevel')) {
              delete cfg.gateway.logLevel;
              writeConfig(cfg);
            }
          } catch {}
          console.log(`\n${C.green}✅ 日志级别已设置为 ${levelChoice.value}${C.reset}\n`);
          await askRestart();
        }
        break;
      }
      case 'acp': {
        const acpChoice = await select({
          title: 'ACP Dispatch 选项',
          showSearch: false,
          items: [
            { key: '1', label: 'false', desc: '禁用 (推荐路由器使用)', value: 'false' },
            { key: '2', label: 'true', desc: '启用 (可能占用大量内存)', value: 'true' },
          ],
        });
        if (acpChoice) {
          jsonSet('acp.dispatch.enabled', acpChoice.value === 'true');
          console.log(`\n${C.green}✅ ACP Dispatch 已设置为 ${acpChoice.value}${C.reset}\n`);
          await askRestart();
        }
        break;
      }
      case 'wizard': {
        resetRenderCount();
        console.log(`\n${C.cyan}启动官方配置向导...${C.reset}\n`);
        console.log(`${C.yellow}提示: ↑↓ 移动, Tab/空格 选中, 回车 确认${C.reset}\n`);
        let ok = false;
        try {
          enableAuthPlugins();
          await ocCmd('configure');
          ok = true;
        } catch (e) {
          console.log(`${C.yellow}配置向导已退出${C.reset}\n`);
        }
        if (ok) await askRestart();
        break;
      }
      case 'view-json':
        console.log(`\n${C.cyan}配置文件路径: ${CONFIG_FILE}${C.reset}\n`);
        try {
          const content = fs.readFileSync(CONFIG_FILE, 'utf8');
          console.log(content);
        } catch (e) {
          console.log(`${C.red}无法读取配置文件${C.reset}`);
        }
        await input({ prompt: '按回车继续', defaultValue: '' });
        break;
      case 'edit':
        console.log(`\n${C.yellow}请在 SSH 终端中手动编辑配置文件:${C.reset}`);
        console.log(`  vi ${CONFIG_FILE}\n`);
        await input({ prompt: '按回车继续', defaultValue: '' });
        break;
      case 'backup':
        await handleBackup();
        break;
      case 'import': {
        const importPath = await input({
          prompt: '请输入备份文件路径',
          defaultValue: '',
        });
        if (importPath && fs.existsSync(importPath)) {
          try {
            fs.copyFileSync(importPath, CONFIG_FILE);
            execSync(`chown openclaw:openclaw "${CONFIG_FILE}" 2>/dev/null || true`, { stdio: 'ignore' });
            fixStatePermissions();
            console.log(`\n${C.green}✅ 配置已导入${C.reset}\n`);
            await askRestart();
          } catch (e) {
            console.log(`${C.red}导入失败: ${e.message}${C.reset}\n`);
          }
        } else {
          console.log(`${C.yellow}文件不存在${C.reset}\n`);
        }
        break;
      }
      case 'devices':
        await manageDevicePairing();
        break;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 重置配置处理 (对应 reset_to_defaults)
// ═══════════════════════════════════════════════════════════════════════════

async function handleReset() {
  while (true) {
    const choice = await showResetMenu();
    if (!choice || choice.value === 'back') break;

    resetRenderCount();

    switch (choice.value) {
      case 'gateway': {
        console.log(`\n${C.yellow}将重置: 网关端口→18789, 绑定→lan, 模式→local${C.reset}`);
        console.log(`${C.yellow}保留: 认证令牌、模型配置、消息渠道${C.reset}\n`);
        const ok = await confirm({ prompt: '确认恢复网关默认设置?', defaultYes: false });
        if (ok) {
          jsonSet('gateway.port', 18789);
          jsonSet('gateway.bind', 'lan');
          jsonSet('gateway.mode', 'local');
          jsonSet('gateway.controlUi.allowInsecureAuth', true);
          jsonSet('gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback', true);
          jsonSet('gateway.tailscale.mode', 'off');
          console.log(`\n${C.green}✅ 网关设置已恢复默认${C.reset}\n`);
          await askRestart();
        }
        break;
      }
      case 'models': {
        console.log(`\n${C.red}⚠️  将清除: 所有模型配置、API Key、活跃模型设置${C.reset}\n`);
        const ok = await confirm({ prompt: '确认清除所有模型配置?', defaultYes: false });
        if (ok) {
          const cfg = readConfig();
          delete cfg.models;
          if (cfg.agents?.defaults?.model) delete cfg.agents.defaults.model;
          if (cfg.agents?.defaults?.models) delete cfg.agents.defaults.models;
          writeConfig(cfg);
          // 清除 auth-profiles.json
          const authFile = `${OC_STATE_DIR}/agents/main/agent/auth-profiles.json`;
          try {
            fs.writeFileSync(authFile, JSON.stringify({ version: 1, profiles: {}, usageStats: {} }, null, 2));
          } catch {}
          console.log(`\n${C.green}✅ 模型配置已清除${C.reset}`);
          console.log(`${C.yellow}请通过菜单 [1] 重新配置 AI 模型${C.reset}\n`);
          await askRestart();
        }
        break;
      }
      case 'channels': {
        console.log(`\n${C.red}⚠️  将清除: 所有消息渠道配置 (Telegram/Discord/飞书等)${C.reset}\n`);
        const ok = await confirm({ prompt: '确认清除所有渠道配置?', defaultYes: false });
        if (ok) {
          const cfg = readConfig();
          delete cfg.channels;
          writeConfig(cfg);
          console.log(`\n${C.green}✅ 渠道配置已清除${C.reset}\n`);
          await askRestart();
        }
        break;
      }
      case 'full': {
        console.log(`\n${C.red}╔══════════════════════════════════════════════════════╗${C.reset}`);
        console.log(`${C.red}║  ⚠️  完全恢复出厂设置                               ║${C.reset}`);
        console.log(`${C.red}║  此操作将删除所有配置并重新初始化                    ║${C.reset}`);
        console.log(`${C.red}╚══════════════════════════════════════════════════════╝${C.reset}\n`);

        const confirmStr = await input({ prompt: '输入 RESET 确认恢复出厂设置', defaultValue: '' });
        if (confirmStr !== 'RESET') {
          console.log(`${C.cyan}已取消${C.reset}\n`);
          break;
        }

        // 执行恢复
        console.log(`\n${C.cyan}[1/5] 停止 Gateway...${C.reset}`);
        try { await runCommand('/etc/init.d/openclaw', ['stop']); } catch {}

        console.log(`${C.cyan}[2/5] 备份当前配置...${C.reset}`);
        const backupDir = `${OC_STATE_DIR}/backups`;
        const backupTs = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
        try {
          if (!fs.existsSync(backupDir)) fs.mkdirSync(backupDir, { recursive: true }); try { execSync(`chown openclaw:openclaw "${backupDir}"`, { stdio: "ignore" }); } catch {}
          fs.copyFileSync(CONFIG_FILE, `${backupDir}/openclaw_${backupTs}.json`);
          console.log(`${C.green}   备份已保存: backups/openclaw_${backupTs}.json${C.reset}`);
        } catch {}

        console.log(`${C.cyan}[3/5] 重置配置...${C.reset}`);
        writeConfig({});

        console.log(`${C.cyan}[4/5] 重新初始化...${C.reset}`);
        // 生成新 token
        const crypto = require('crypto');
        const newToken = crypto.randomBytes(24).toString('hex');

        console.log(`${C.cyan}[5/5] 应用 OpenWrt 适配配置...${C.reset}`);
        jsonSet('gateway.port', 18789);
        jsonSet('gateway.bind', 'lan');
        jsonSet('gateway.mode', 'local');
        jsonSet('gateway.auth.mode', 'token');
        jsonSet('gateway.auth.token', newToken);
        jsonSet('gateway.controlUi.allowInsecureAuth', true);
        jsonSet('gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback', true);
        jsonSet('gateway.tailscale.mode', 'off');
        jsonSet('acp.dispatch.enabled', false);
        jsonSet('tools.profile', 'coding');

        try { execSync(`uci set openclaw.main.token="${newToken}" && uci commit openclaw`, { stdio: 'ignore' }); } catch {}

        console.log(`\n${C.green}✅ 出厂设置已恢复！${C.reset}\n`);
        console.log(`${C.cyan}新认证令牌: ${newToken}${C.reset}\n`);

        await restartGateway();
        break;
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 备份/还原处理 (对应 backup_restore_menu)
// ═══════════════════════════════════════════════════════════════════════════

async function handleBackup() {
  while (true) {
    const choice = await showBackupMenu();
    if (!choice || choice.value === 'back') break;

    resetRenderCount();
    const backupDir = `${OC_STATE_DIR}/backups`;
    try { if (!fs.existsSync(backupDir)) fs.mkdirSync(backupDir, { recursive: true }); try { execSync(`chown openclaw:openclaw "${backupDir}"`, { stdio: "ignore" }); } catch {} } catch {}

    switch (choice.value) {
      case 'create-config': {
        console.log(`\n${C.cyan}正在创建配置备份...${C.reset}`);
        try {
          await ocCmd('backup', 'create', '--only-config', '--no-include-workspace');
          console.log(`${C.green}✅ 配置备份已创建${C.reset}\n`);
        } catch (e) {
          console.log(`${C.yellow}⚠️ 备份功能需要 OpenClaw v2026.3.8+${C.reset}\n`);
        }
        await input({ prompt: '按回车继续', defaultValue: '' });
        break;
      }
      case 'create-full': {
        console.log(`\n${C.cyan}正在创建完整备份...${C.reset}`);
        try {
          await ocCmd('backup', 'create', '--no-include-workspace');
          console.log(`${C.green}✅ 完整备份已创建${C.reset}\n`);
        } catch (e) {
          console.log(`${C.yellow}⚠️ 备份失败${C.reset}\n`);
        }
        await input({ prompt: '按回车继续', defaultValue: '' });
        break;
      }
      case 'verify': {
        const files = fs.readdirSync(backupDir).filter(f => f.endsWith('.tar.gz')).sort().reverse();
        if (files.length === 0) {
          console.log(`${C.yellow}未找到备份文件${C.reset}\n`);
        } else {
          const latest = `${backupDir}/${files[0]}`;
          console.log(`${C.cyan}验证备份: ${latest}${C.reset}`);
          try {
            await ocCmd('backup', 'verify', latest);
          } catch {}
        }
        await input({ prompt: '按回车继续', defaultValue: '' });
        break;
      }
      case 'list': {
        const files = fs.readdirSync(backupDir).filter(f => f.endsWith('.tar.gz') || f.endsWith('.json')).sort().reverse();
        if (files.length === 0) {
          console.log(`${C.yellow}暂无备份文件${C.reset}\n`);
        } else {
          console.log(`\n${C.bold}备份文件列表:${C.reset}`);
          files.slice(0, 10).forEach(f => {
            const stat = fs.statSync(`${backupDir}/${f}`);
            console.log(`  ${C.dim}${f} (${(stat.size / 1024).toFixed(1)} KB)${C.reset}`);
          });
          console.log(`${C.dim}\n备份目录: ${backupDir}${C.reset}\n`);
        }
        await input({ prompt: '按回车继续', defaultValue: '' });
        break;
      }
      case 'restore': {
        const files = fs.readdirSync(backupDir).filter(f => f.endsWith('.json')).sort().reverse();
        if (files.length === 0) {
          console.log(`${C.yellow}未找到配置备份文件${C.reset}\n`);
          await input({ prompt: '按回车继续', defaultValue: '' });
          break;
        }

        const fileChoice = await select({
          title: '选择备份文件',
          showSearch: false,
          items: files.slice(0, 10).map((f, i) => ({
            key: String(i + 1),
            label: f,
            desc: '',
            value: f,
          })),
        });

        if (!fileChoice) break;

        const ok = await confirm({ prompt: '确认恢复此备份?', defaultYes: false });
        if (ok) {
          try {
            fs.copyFileSync(`${backupDir}/${fileChoice.value}`, CONFIG_FILE);
            console.log(`\n${C.green}✅ 配置已恢复${C.reset}\n`);
            await askRestart();
          } catch (e) {
            console.log(`${C.red}恢复失败: ${e.message}${C.reset}\n`);
          }
        }
        break;
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 主函数
// ═══════════════════════════════════════════════════════════════════════════

async function main() {
  const command = process.argv[2];

  if (command === 'model') {
    await handleModelConfig();
    return;
  }

  if (command === 'status') {
    await runCommand('/etc/init.d/openclaw', ['status_service']);
    return;
  }

  if (command === 'restart') {
    const ok = await confirm({ prompt: '确认重启 OpenClaw 服务?' });
    if (ok) await runCommand('/etc/init.d/openclaw', ['restart']);
    return;
  }

  // 交互式主菜单
  while (true) {
    const choice = await showMainMenu();

    if (!choice || choice.value === 'quit') {
      console.log(`\n${C.green}再见！${C.reset}\n`);
      break;
    }

    switch (choice.value) {
      case 'model':
        await handleModelConfig();
        break;
      case 'set-active-model':
        await handleSetActiveModel();
        break;
      case 'channels':
        await handleChannels();
        break;
      case 'health':
        await handleHealthCheck();
        break;
      case 'logs':
        resetRenderCount();
        console.log(`\n${C.cyan}=== OpenClaw 日志 ===${C.reset}\n`);
        await runCommand('logread', ['-e', 'openclaw']);
        console.log('');
        await input({ prompt: '按回车继续', defaultValue: '' });
        break;
      case 'restart':
        resetRenderCount();
        await restartGateway();
        break;
      case 'devices':
        await manageDevicePairing();
        break;
      case 'advanced':
        await handleAdvancedConfig();
        break;
      case 'reset':
        await handleReset();
        break;
      case 'show-config':
        await handleShowConfig();
        break;
      case 'backup':
        await handleBackup();
        break;
    }
  }
}

main().catch(e => {
  if (e instanceof ConfigParseError) {
    // 配置损坏: 给出可直接执行的恢复步骤，而不是丢一句解析错误了事
    console.error(`\n${C.red}配置读取失败:${C.reset} ${e.message}\n`);
    console.error(configRecoveryHint());
    console.error('');
    process.exit(2);
  }
  console.error(`${C.red}错误:${C.reset}`, e.message);
  process.exit(1);
});
