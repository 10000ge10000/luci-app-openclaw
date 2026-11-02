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
// AI 模型配置 (对应 oc-config.sh 的 configure_model)
//
// 业务逻辑全部在 oc-providers.js，本文件只负责交互。Shell 菜单调用同一个
// 后端与同一份 provider-catalog.json，两边菜单项、按键与流程保持一致。
// ═══════════════════════════════════════════════════════════════════════════

const providers = require('./oc-providers');

// 模型模块的菜单只用 Esc 返回: select() 默认把 'q' 也当退出键，且先于搜索处理，
// 会导致可搜索列表里无法输入 q (如搜索 qwen)，也与「q 快速配置」快捷键冲突
function selectMenu(opts) {
  return select({ exitKeys: ['escape'], ...opts });
}

function printResultNotes(r) {
  for (const n of (r.notes || [])) console.log(`${C.dim}   ${n}${C.reset}`);
}

function pause() {
  return input({ prompt: '按回车继续', defaultValue: '' });
}

function verificationHeader() {
  try {
    const v = providers.catalogVerification();
    if (!v.installed) return `${C.yellow}OpenClaw 未安装${C.reset}`;
    return v.verified
      ? `${C.dim}OpenClaw ${v.installed} — provider 目录已在此版本核实 (${v.verifiedAt})${C.reset}`
      : `${C.yellow}OpenClaw ${v.installed} 不在 provider 目录核实范围 (${v.verifiedWith.join(' / ')})，配置项可能有出入${C.reset}`;
  } catch (e) {
    return `${C.red}provider 目录读取失败: ${e.message}${C.reset}`;
  }
}

async function showModelMenu() {
  const currentModel = getCurrentModel();
  return selectMenu({
    title: 'AI 模型配置',
    header: `${currentModel ? `${C.green}当前默认模型: ${currentModel}${C.reset}` : `${C.yellow}尚未设置默认模型${C.reset}`}\n${verificationHeader()}`,
    showSearch: false,
    items: [
      { label: `${C.green}${C.bold}── 快速配置 ──${C.reset}`, disabled: true },
      { key: 'q', label: '常用 Provider 快速配置', desc: `${C.green}(推荐)${C.reset}`, value: 'quick' },

      { label: `${C.bold}── 按类别添加 ──${C.reset}`, disabled: true },
      { key: '1', label: '官方 API (按量付费)', desc: 'OpenAI / Claude / Gemini / DeepSeek / 千问 / 智谱 ...', value: 'group:official' },
      { key: '2', label: '订阅套餐 / Coding Plan / 账号登录', desc: '百炼 / GLM / Kimi Code / Copilot ...', value: 'group:plan' },
      { key: '3', label: '聚合平台 / 自定义 API', desc: 'OpenRouter / 硅基流动 / OpenAI 兼容 ...', value: 'group:aggregator' },
      { key: '4', label: '本地 / 局域网模型', desc: 'Ollama / vLLM / LM Studio', value: 'group:local' },

      { label: `${C.bold}── 模型管理 ──${C.reset}`, disabled: true },
      { key: '5', label: '查看模型与认证状态', desc: '', value: 'status' },
      { key: '6', label: '切换默认模型', desc: '', value: 'set-default' },
      { key: '7', label: '管理备用模型 (fallback)', desc: '', value: 'fallbacks' },
      { key: '8', label: '连通性测试', desc: '真实请求，验证账号能否调用', value: 'probe' },
      { key: '9', label: '删除凭据 / Provider', desc: '', value: 'remove' },

      { label: `${C.bold}── 其他 ──${C.reset}`, disabled: true },
      { key: 'w', label: '官方完整配置向导', desc: 'openclaw configure --section model', value: 'wizard' },
      { label: '', disabled: true },
      { key: '0', label: '返回', desc: '', value: 'back' },
    ],
  });
}

async function pickMethodFromGroup(groupId) {
  const entries = providers.menuEntries().filter((e) => e.group === groupId);
  if (!entries.length) return null;
  const keys = 'abcdefghijklmnoprstuvwxyz'.split('');
  const items = [];
  let ki = 0;
  for (const e of entries) {
    for (const m of e.methods) {
      const label = e.methods.length > 1 ? `${e.label} — ${m.label}` : e.label;
      items.push({ key: keys[ki++], label, desc: e.plugin ? `${C.dim}需官方插件${C.reset}` : '', value: m.ref });
    }
  }
  items.push({ label: '', disabled: true });
  items.push({ key: '0', label: '返回', desc: '', value: 'back' });
  const choice = await selectMenu({ title: entries[0].groupLabel, showSearch: true, items });
  return choice && choice.value !== 'back' ? choice.value : null;
}

async function pickQuickMethod() {
  const items = providers.quickEntries().map((q, i) => ({ key: String(i + 1), label: q.label, desc: '', value: q.ref }));
  items.push({ label: '', disabled: true });
  items.push({ key: '0', label: '返回', desc: '', value: 'back' });
  const choice = await selectMenu({ title: '常用 Provider 快速配置', showSearch: false, items });
  return choice && choice.value !== 'back' ? choice.value : null;
}

function printMethodIntro(f) {
  const p = f.provider;
  const m = f.method;
  console.log(`\n${C.bold}${p.label}${p.methods.length > 1 ? ` — ${m.label}` : ''}${C.reset}`);
  if (p.keyUrl) console.log(`${C.yellow}获取 Key: ${p.keyUrl}${C.reset}`);
  const docs = providers.docsUrl(p);
  if (docs) console.log(`${C.dim}文档: ${docs}${C.reset}`);
  if (m.baseUrl) console.log(`${C.dim}Base URL: ${m.baseUrl}${C.reset}`);
  if (p.note) console.log(`${C.cyan}说明: ${p.note}${C.reset}`);
  if (m.note) console.log(`${C.cyan}说明: ${m.note}${C.reset}`);
  if (m.keyHint) console.log(`${C.cyan}提示: ${m.keyHint}${C.reset}`);
  if (m.unverified) console.log(`${C.yellow}未实测: ${m.unverified}${C.reset}`);
  console.log('');
}

/** 插件缺失时征得同意后安装；返回 false 表示用户取消或安装失败 */
async function ensurePluginInteractive(f) {
  const pkg = f.provider.plugin;
  if (!pkg) return true;
  console.log(`${C.cyan}检查官方插件 ${pkg}...${C.reset}`);
  const st = providers.pluginStatus(pkg);
  if (st.installed) return true;
  if (st.error) console.log(`${C.yellow}插件状态查询失败: ${st.error}${C.reset}`);
  console.log(`${C.yellow}该 Provider 需要 OpenClaw 官方插件 ${pkg}，将通过 npm 下载安装 (版本与当前 OpenClaw 匹配)。${C.reset}`);
  const ok = await confirm({ prompt: '是否安装该插件?', defaultYes: true });
  if (!ok) return false;
  console.log(`${C.cyan}正在安装 ${pkg} (可能需要 1~3 分钟)...${C.reset}`);
  const r = providers.installPlugin(pkg);
  if (!r.ok) {
    console.log(`${C.red}插件安装失败: ${r.reason}${C.reset}\n`);
    return false;
  }
  console.log(`${C.green}✅ 插件已安装${C.reset}`);
  return true;
}

/**
 * 模型选择: 精选 + 动态发现 + 手动输入 + 保持当前默认。
 * 返回 { model } / { keep: true } / null(取消)。
 */
async function pickModel(providerId, curated, opts = {}) {
  let discovered = null;
  const current = getCurrentModel();
  while (true) {
    const keys = 'abcdefghijkmnoprstuvwxy'.split('');
    let ki = 0;
    const items = [];
    if (curated.length) {
      items.push({ label: `${C.bold}── 精选模型 ──${C.reset}`, disabled: true });
      for (const m of curated) items.push({ key: keys[ki++], label: m.id, desc: `${m.tier ? `[${m.tier}] ` : ''}${m.desc || ''}`, value: `m:${m.id}` });
    }
    if (discovered && discovered.models.length) {
      const known = new Set(curated.map((m) => m.id));
      const extra = discovered.models.filter((m) => !known.has(m.id));
      if (extra.length) {
        const title = discovered.source === 'cache' ? `OpenClaw 模型列表 (缓存 ${discovered.cachedAt || ''})` : 'OpenClaw 当前模型列表';
        items.push({ label: `${C.bold}── ${title} ──${C.reset}`, disabled: true });
        for (const m of extra) items.push({ key: keys[ki++], label: m.id, desc: m.name || '', value: `m:${m.id}` });
      }
    }
    items.push({ label: '', disabled: true });
    if (!discovered && providerId) items.push({ key: 'r', label: '从 OpenClaw 获取完整模型列表', desc: '动态发现', value: 'discover' });
    items.push({ key: 'z', label: '手动输入模型 ID', desc: '', value: 'manual' });
    if (opts.allowKeep && current) items.push({ key: 'k', label: '保持当前默认模型不变', desc: current, value: 'keep' });
    items.push({ key: '0', label: '取消', desc: '', value: 'back' });

    const choice = await selectMenu({ title: opts.title || '选择模型', showSearch: true, items });
    if (!choice || choice.value === 'back') return null;
    if (choice.value === 'keep') return { keep: true };
    if (choice.value === 'manual') {
      const v = await input({ prompt: '请输入模型 ID (不含 provider/ 前缀)', defaultValue: opts.defaultModel || '' });
      const t = v ? String(v).trim() : '';
      if (!t) continue;
      return { model: t };
    }
    if (choice.value === 'discover') {
      console.log(`\n${C.cyan}正在从 OpenClaw 获取模型列表 (路由器上可能需要 10~60 秒)...${C.reset}`);
      discovered = providers.discoverModels(providerId);
      if (discovered.source === 'none') {
        console.log(`${C.yellow}未获取到模型列表${discovered.reason ? `: ${discovered.reason}` : ''}，仍可使用精选列表或手动输入。${C.reset}`);
      } else {
        console.log(`${C.green}获取到 ${discovered.models.length} 个模型${discovered.source === 'cache' ? ' (来自缓存)' : ''}${C.reset}`);
      }
      if (discovered.hints.includes('auth-rejected')) {
        console.log(`${C.yellow}⚠️  上游报告该 Provider 的认证被拒绝: Key 可能无效或无权限。${C.reset}`);
      }
      console.log(`${C.dim}注意: 列表只代表上游登记的模型，不代表你的账号有权调用；请用「连通性测试」确认。${C.reset}\n`);
      continue;
    }
    return { model: choice.value.slice(2) };
  }
}

async function configureApiKeyMethod(f) {
  if (!(await ensurePluginInteractive(f))) { console.log(`${C.yellow}已取消${C.reset}\n`); return false; }
  const key = await input({ prompt: `请输入 ${f.provider.label} API Key`, hidden: true });
  if (!key) { console.log(`\n${C.yellow}已取消${C.reset}\n`); return false; }
  console.log(`\n${C.cyan}正在写入凭据 (通过 OpenClaw 官方命令，Key 保存在认证库，不写入 openclaw.json)...${C.reset}`);
  const r = providers.applyApiKey(f.ref, key, { keepDefault: true, pluginConfirmed: true });
  if (!r.ok) {
    console.log(`${C.red}❌ 配置失败: ${r.reason}${C.reset}\n`);
    return false;
  }
  console.log(`${C.green}✅ ${f.provider.label} 凭据已保存${C.reset}`);
  printResultNotes(r);
  await chooseDefaultAfterAuth(f.method.provider, providers.curatedModels(f.method), f.method.defaultModel);
  return true;
}

async function chooseDefaultAfterAuth(providerId, curated, defaultModel) {
  const pick = await pickModel(providerId, curated, { title: `将哪个 ${providerId} 模型设为默认?`, allowKeep: true, defaultModel });
  if (!pick || pick.keep) {
    console.log(`${C.dim}默认模型保持为 ${getCurrentModel() || '未设置'}${C.reset}\n`);
    return;
  }
  const ref = `${providerId}/${pick.model}`;
  const s = providers.setDefault(ref);
  if (s.ok) console.log(`${C.green}✅ 默认模型已设为 ${ref}${C.reset}\n`);
  else console.log(`${C.red}❌ 设置默认模型失败: ${s.reason}${C.reset}\n`);
}

async function configureCustomMethod(f) {
  const m = f.method;
  const id = await input({ prompt: 'Provider ID (小写字母/数字/连字符)', defaultValue: m.customProviderId || (m.compatibility === 'anthropic' ? 'custom-anthropic' : 'custom') });
  if (!id) { console.log(`${C.yellow}已取消${C.reset}\n`); return false; }
  const baseUrl = await input({ prompt: 'API Base URL', defaultValue: m.baseUrl || m.baseUrlDefault || '', placeholder: 'https://api.example.com/v1' });
  if (!baseUrl) { console.log(`${C.yellow}已取消${C.reset}\n`); return false; }
  const model = await input({ prompt: '模型 ID', defaultValue: '', placeholder: m.modelHint || '' });
  if (!model) { console.log(`${C.yellow}已取消${C.reset}\n`); return false; }
  const image = await confirm({ prompt: '该模型支持图片输入吗?', defaultYes: false });
  const key = await input({ prompt: m.keyOptional ? 'API Key (可留空)' : 'API Key', hidden: true, defaultValue: '' });
  if (key === null) { console.log(`\n${C.yellow}已取消${C.reset}\n`); return false; }
  if (!key && !m.keyOptional) {
    const cont = await confirm({ prompt: '\n未填写 API Key，若该 Provider 已存在将沿用原 Key，否则不带 Key 接入。继续?', defaultYes: false });
    if (!cont) return false;
  }
  const setDef = await confirm({ prompt: '\n设为默认模型?', defaultYes: true });
  console.log(`\n${C.cyan}正在写入...${C.reset}`);
  const r = providers.applyCustom({ providerId: String(id).trim(), baseUrl, model: String(model).trim(), compatibility: m.compatibility, image, keyOptional: true }, key || '', { setDefault: setDef });
  if (!r.ok) { console.log(`${C.red}❌ 配置失败: ${r.reason}${C.reset}\n`); return false; }
  console.log(`${C.green}✅ ${r.appended ? '已向现有 Provider 追加模型' : '自定义 Provider 已添加'}: ${r.provider}/${String(model).trim()}${C.reset}`);
  console.log(`${C.dim}   注意: 按上游设计，自定义 Provider 的 Key 明文保存在 openclaw.json${C.reset}`);
  printResultNotes(r);
  console.log(`${C.dim}   当前默认模型: ${r.primary || '未设置'}${C.reset}\n`);
  return true;
}

async function configureOllamaMethod(f) {
  const url = await input({ prompt: 'Ollama 地址', defaultValue: f.method.baseUrlDefault || 'http://127.0.0.1:11434' });
  if (!url) { console.log(`${C.yellow}已取消${C.reset}\n`); return false; }
  const base = /^https?:\/\//.test(url) ? url.replace(/\/+$/, '').replace(/\/v1$/, '') : `http://${url.replace(/\/+$/, '')}`;
  let names = [];
  try {
    const out = execFileSync('curl', ['-sf', '--connect-timeout', '3', '--max-time', '6', `${base}/api/tags`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    names = (JSON.parse(out).models || []).map((x) => x.name).filter(Boolean);
    console.log(`${C.green}✅ Ollama 已连接，发现 ${names.length} 个本地模型${C.reset}`);
  } catch {
    console.log(`${C.yellow}⚠️  无法连接 ${base}，上游写入时也会检测，不可达将被拒绝${C.reset}`);
  }
  let model = '';
  if (names.length) {
    const items = names.map((n, i) => ({ key: String(i + 1), label: n, desc: '', value: n }));
    items.push({ key: 'z', label: '手动输入模型名', desc: '', value: '__manual__' });
    const c = await selectMenu({ title: 'Ollama 模型', showSearch: true, items });
    if (!c) return false;
    model = c.value === '__manual__' ? await input({ prompt: '模型名', defaultValue: '' }) : c.value;
  } else {
    model = await input({ prompt: '模型名', placeholder: 'qwen3:8b' });
  }
  if (!model) { console.log(`${C.yellow}已取消${C.reset}\n`); return false; }
  const setDef = await confirm({ prompt: '设为默认模型?', defaultYes: true });
  console.log(`\n${C.cyan}正在写入...${C.reset}`);
  const r = providers.applyOllama(base, String(model).trim(), { setDefault: setDef });
  if (!r.ok) { console.log(`${C.red}❌ 配置失败: ${r.reason}${C.reset}\n`); return false; }
  console.log(`${C.green}✅ Ollama 已配置${C.reset}`);
  printResultNotes(r);
  console.log(`${C.dim}   当前默认模型: ${r.primary || '未设置'}${C.reset}\n`);
  return true;
}

async function configureOAuthMethod(f) {
  console.log(`${C.cyan}即将启动 OpenClaw 官方登录流程，请按屏幕提示在浏览器中完成授权。${C.reset}\n`);
  const ok = await confirm({ prompt: '开始登录?', defaultYes: true });
  if (!ok) return false;
  const r = providers.login(f.ref);
  if (!r.ok) { console.log(`\n${C.yellow}${r.reason}${C.reset}\n`); return false; }
  console.log(`\n${C.green}✅ 登录完成${C.reset}`);
  await chooseDefaultAfterAuth(f.method.provider, providers.curatedModels(f.method), '');
  return true;
}

async function configureMethod(ref) {
  resetRenderCount();
  const f = providers.findMethod(ref);
  if (!f) { console.log(`${C.red}未知的接入方式: ${ref}${C.reset}`); return false; }
  printMethodIntro(f);
  switch (f.method.type) {
    case 'api-key': return configureApiKeyMethod(f);
    case 'custom': return configureCustomMethod(f);
    case 'local': return configureOllamaMethod(f);
    case 'oauth': return configureOAuthMethod(f);
    default:
      console.log(`${C.red}不支持的接入类型: ${f.method.type}${C.reset}`);
      return false;
  }
}

async function handleModelStatus() {
  resetRenderCount();
  console.log(`\n${C.cyan}正在读取模型与认证状态...${C.reset}`);
  const s = providers.status();
  if (!s.ok) console.log(`${C.red}读取失败: ${s.reason}${C.reset}`);
  console.log(`\n${C.bold}默认模型:${C.reset} ${s.defaultModel ? C.green + s.defaultModel : C.yellow + '未设置'}${C.reset}`);
  console.log(`${C.bold}备用模型:${C.reset} ${s.fallbacks.length ? s.fallbacks.join(', ') : C.dim + '无' + C.reset}`);
  console.log(`\n${C.bold}已保存的凭据:${C.reset}`);
  if (!s.profiles.length) console.log(`  ${C.dim}无${C.reset}`);
  for (const p of s.profiles) console.log(`  • ${p.id}  ${C.dim}(${p.provider}, ${p.type})${C.reset}`);
  console.log(`\n${C.bold}Provider 配置:${C.reset}`);
  if (!s.custom.length) console.log(`  ${C.dim}无${C.reset}`);
  for (const c of s.custom) {
    console.log(`  • ${c.id}  ${C.dim}${c.baseUrl || ''} ${c.api || ''}${c.hasKey ? ' [配置内含 Key]' : ''}${C.reset}`);
    if (c.models.length) console.log(`    ${C.dim}模型: ${c.models.join(', ')}${C.reset}`);
  }
  if (s.issues.length) {
    console.log(`\n${C.yellow}${C.bold}发现问题:${C.reset}`);
    for (const i of s.issues) console.log(`  ${C.yellow}• ${i}${C.reset}`);
  }
  console.log(`\n${C.dim}以上是本地凭据状态，不代表调用一定成功；请用「连通性测试」确认。${C.reset}\n`);
  await pause();
}

async function pickConfiguredModel(title) {
  const current = getCurrentModel();
  const refs = providers.configuredModels();
  const items = refs.map((r, i) => ({ key: i < 9 ? String(i + 1) : undefined, label: r, desc: r === current ? `${C.green}(当前默认)${C.reset}` : '', value: r }));
  items.push({ label: '', disabled: true });
  items.push({ key: 'z', label: '手动输入 provider/model', desc: '', value: '__manual__' });
  items.push({ key: '0', label: '取消', desc: '', value: 'back' });
  const c = await selectMenu({ title, showSearch: true, items });
  if (!c || c.value === 'back') return null;
  if (c.value === '__manual__') {
    const v = await input({ prompt: '模型引用 (provider/model)', defaultValue: '' });
    return v ? String(v).trim() : null;
  }
  return c.value;
}

async function handleSetDefaultModel() {
  resetRenderCount();
  console.log(`\n${C.bold}切换默认模型${C.reset}  当前: ${C.green}${getCurrentModel() || '未设置'}${C.reset}\n`);
  const ref = await pickConfiguredModel('选择默认模型');
  if (!ref) return false;
  const r = providers.setDefault(ref);
  if (r.ok) { console.log(`\n${C.green}✅ 默认模型已切换为 ${ref}${C.reset}\n`); return true; }
  console.log(`\n${C.red}❌ 切换失败: ${r.reason}${C.reset}\n`);
  return false;
}

async function handleFallbacks() {
  let changed = false;
  while (true) {
    resetRenderCount();
    const l = providers.fallbacks('list');
    const list = l.ok ? l.fallbacks : [];
    if (!l.ok) console.log(`${C.red}读取备用模型失败: ${l.reason}${C.reset}`);
    const c = await selectMenu({
      title: '管理备用模型 (fallback)',
      header: `${C.dim}默认模型不可用时按顺序尝试: ${list.length ? list.join(' → ') : '无'}${C.reset}`,
      showSearch: false,
      items: [
        { key: '1', label: '添加备用模型', desc: '', value: 'add' },
        { key: '2', label: '移除备用模型', desc: '', value: 'remove' },
        { key: '3', label: '清空备用模型', desc: '', value: 'clear' },
        { label: '', disabled: true },
        { key: '0', label: '返回', desc: '', value: 'back' },
      ],
    });
    if (!c || c.value === 'back') return changed;
    let r = null;
    if (c.value === 'add') {
      const ref = await pickConfiguredModel('选择要添加的备用模型');
      if (ref) r = providers.fallbacks('add', ref);
    } else if (c.value === 'remove') {
      if (!list.length) { console.log(`${C.yellow}没有备用模型${C.reset}`); continue; }
      const p = await selectMenu({ title: '移除哪个?', showSearch: false, items: list.map((x, i) => ({ key: String(i + 1), label: x, value: x })) });
      if (p) r = providers.fallbacks('remove', p.value);
    } else if (c.value === 'clear') {
      if (await confirm({ prompt: '确认清空所有备用模型?', defaultYes: false })) r = providers.fallbacks('clear');
    }
    if (r) {
      if (r.ok) { console.log(`${C.green}✅ 已更新${C.reset}`); changed = true; }
      else console.log(`${C.red}❌ 失败: ${r.reason}${C.reset}`);
    }
  }
}

async function handleProbe() {
  resetRenderCount();
  console.log(`\n${C.cyan}正在读取已配置的 Provider...${C.reset}`);
  const s = providers.status();
  const ids = [...new Set([...s.profiles.map((p) => p.provider), ...s.custom.map((c) => c.id)])].sort();
  if (!ids.length) { console.log(`${C.yellow}尚未配置任何 Provider${C.reset}\n`); await pause(); return; }
  const c = await selectMenu({ title: '测试哪个 Provider?', showSearch: true, items: ids.map((id, i) => ({ key: i < 9 ? String(i + 1) : undefined, label: id, value: id })) });
  if (!c) return;
  console.log(`\n${C.yellow}连通性测试会向 ${c.value} 发送真实请求 (每个模型约 8 个 token)，可能产生少量费用或触发限流。${C.reset}`);
  if (!(await confirm({ prompt: '继续?', defaultYes: true }))) return;
  console.log(`${C.cyan}测试中 (约 5~60 秒)...${C.reset}`);
  const r = providers.probe(c.value);
  if (!r.ok) {
    console.log(`${C.red}❌ 无法完成测试: ${r.reason}${C.reset}\n`);
  } else {
    for (const x of r.results) {
      const color = x.status === 'ok' ? C.green : C.red;
      console.log(`  ${color}${x.status === 'ok' ? '✅' : '❌'} ${x.model || c.value}  ${x.statusText}${x.latencyMs ? ` (${x.latencyMs} ms)` : ''}${C.reset}`);
      if (x.error) console.log(`     ${C.dim}${x.error}${C.reset}`);
    }
    console.log('');
  }
  await pause();
}

async function handleRemove() {
  resetRenderCount();
  const s = providers.status();
  const items = [];
  for (const p of s.profiles) items.push({ label: `删除凭据 ${p.id}`, desc: `${p.provider} / ${p.type}`, value: `auth:${p.id}` });
  for (const c of s.custom) items.push({ label: `删除 Provider 配置 ${c.id}`, desc: c.baseUrl, value: `prov:${c.id}` });
  if (!items.length) { console.log(`\n${C.yellow}没有可删除的凭据或 Provider${C.reset}\n`); await pause(); return false; }
  items.forEach((it, i) => { if (i < 9) it.key = String(i + 1); });
  items.push({ label: '', disabled: true });
  items.push({ key: '0', label: '返回', desc: '', value: 'back' });
  const c = await selectMenu({ title: '删除凭据 / Provider', showSearch: true, items });
  if (!c || c.value === 'back') return false;
  const [kind, id] = [c.value.slice(0, c.value.indexOf(':')), c.value.slice(c.value.indexOf(':') + 1)];
  console.log(`\n${C.red}将删除 ${id}${kind === 'prov' ? ' 的 Provider 配置及其模型白名单 (默认模型使用中时会拒绝)' : ' 这条凭据'}，此操作不可撤销。${C.reset}`);
  if (!(await confirm({ prompt: '确认删除?', defaultYes: false }))) return false;
  const r = kind === 'auth' ? providers.removeAuth(id) : providers.removeProvider(id);
  if (r.ok) {
    console.log(`${C.green}✅ 已删除${C.reset}`);
    if (r.removedFallbacks && r.removedFallbacks.length) console.log(`${C.dim}   同时移除了备用模型: ${r.removedFallbacks.join(', ')}${C.reset}`);
    console.log('');
    return true;
  }
  console.log(`${C.red}❌ 删除失败: ${r.reason}${C.reset}\n`);
  return false;
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

async function handleModelConfig() {
  while (true) {
    const choice = await showModelMenu();
    if (!choice || choice.value === 'back') break;
    resetRenderCount();
    let changed = false;
    try {
      if (choice.value === 'quick') {
        const ref = await pickQuickMethod();
        if (ref) changed = await configureMethod(ref);
      } else if (choice.value.startsWith('group:')) {
        const ref = await pickMethodFromGroup(choice.value.slice(6));
        if (ref) changed = await configureMethod(ref);
      } else if (choice.value === 'status') {
        await handleModelStatus();
      } else if (choice.value === 'set-default') {
        changed = await handleSetDefaultModel();
      } else if (choice.value === 'fallbacks') {
        changed = await handleFallbacks();
      } else if (choice.value === 'probe') {
        await handleProbe();
      } else if (choice.value === 'remove') {
        changed = await handleRemove();
      } else if (choice.value === 'wizard') {
        changed = await launchWizard();
      }
    } catch (e) {
      console.log(`${C.red}操作失败: ${e.message}${C.reset}\n`);
      await pause();
    }
    if (changed) await askRestart();
  }
}

// 主菜单「设置活动模型」入口与模型管理中的「切换默认模型」共用实现
async function handleSetActiveModel() {
  if (await handleSetDefaultModel()) await askRestart();
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
        cfg.channels.discord.token = token;
        delete cfg.channels.discord.botToken;
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
  const dcToken = jsonGet('channels.discord.token') || jsonGet('channels.discord.botToken');
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
          // 凭据保存在上游认证库 (state/openclaw.sqlite)，通过官方 logout 逐条注销；
          // auth-profiles.json 已在 2026.9.x 退役，不再读写
          const failed = [];
          for (const p of providers.status().profiles) {
            const r = providers.removeAuth(p.id);
            if (!r.ok) failed.push(`${p.id}: ${r.reason}`);
          }
          const cfg = readConfig();
          delete cfg.models;
          if (cfg.agents?.defaults?.model) delete cfg.agents.defaults.model;
          if (cfg.agents?.defaults?.models) delete cfg.agents.defaults.models;
          writeConfig(cfg);
          if (failed.length) {
            console.log(`\n${C.yellow}以下凭据未能注销:${C.reset}`);
            failed.forEach((f) => console.log(`  ${C.yellow}• ${f}${C.reset}`));
          }
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

// 菜单引擎读过 stdin 后它仍处于 flowing 状态，不暂停的话进程不会退出，Web 终端会停在「再见」
main().then(() => process.stdin.pause()).catch(e => {
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
