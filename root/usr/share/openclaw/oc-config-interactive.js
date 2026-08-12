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
const { spawn, execSync, execFileSync } = require('child_process');
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

// ═══════════════════════════════════════════════════════════════════════════
// 辅助函数 (与 oc-config.sh 逻辑对应)
// ═══════════════════════════════════════════════════════════════════════════

/**
 * 执行命令并返回结果
 */
function runCommand(cmd, args = [], options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, {
      stdio: ['inherit', 'pipe', 'pipe'],
      shell: true,
      env: { ...process.env, ...options.env },
    });

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (data) => {
      stdout += data;
      process.stdout.write(data);
    });

    child.stderr.on('data', (data) => {
      stderr += data;
      process.stderr.write(data);
    });

    child.on('close', (code) => {
      if (code === 0) {
        resolve({ stdout, stderr, code });
      } else {
        reject(new Error(`Command failed with code ${code}: ${stderr}`));
      }
    });
  });
}

/**
 * 读取 JSON 配置文件
 */
function fixStatePermissions() {
  try {
    execFileSync(PERMISSIONS_HELPER, ['fix-state', OC_STATE_DIR], { stdio: 'ignore', timeout: 10000 });
  } catch {
    try {
      execSync(`find "${OC_STATE_DIR}" -user root ! -path "*/extensions*" ! -path "*/archived-extensions*" ! -path "*/npm/projects*" -exec chown openclaw:openclaw {} + 2>/dev/null || true`, { stdio: 'ignore' });
    } catch {}
  }
}

function readConfig() {
  try {
    if (fs.existsSync(CONFIG_FILE)) {
      return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
    }
  } catch (e) {
    console.error(`${C.red}读取配置失败:${C.reset} ${e.message}`);
  }
  return {};
}

/**
 * 写入 JSON 配置文件
 */
function writeConfig(config) {
  const dir = path.dirname(CONFIG_FILE);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true }); try { execSync(`chown openclaw:openclaw "${dir}"`, { stdio: "ignore" }); } catch {}
  }
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
  try {
    execSync(`chown openclaw:openclaw "${CONFIG_FILE}"`, { stdio: 'ignore' });
    fixStatePermissions();
  } catch {}
}

/**
 * 获取 JSON 配置值 (对应 json_get)
 */
function jsonGet(keyPath) {
  const config = readConfig();
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
  const config = readConfig();
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
 */
async function ocCmd(...args) {
  const ocEntry = findOpenClawEntry();
  if (!ocEntry) throw new Error('OpenClaw 未安装');
  return runCommand(NODE_BIN, [ocEntry, ...args], {
    env: {
      OPENCLAW_HOME: OC_DATA,
      OPENCLAW_CONFIG_PATH: CONFIG_FILE,
      OPENCLAW_STATE_DIR: OC_STATE_DIR,
      HOME: OC_DATA,
    }
  });
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

      { label: `${C.dim}━━━ 高级选项 ━━━${C.reset}`, disabled: true },
      { key: '7', label: '高级配置', desc: '', value: 'advanced' },
      { key: '8', label: '重置配置', desc: '', value: 'reset' },
      { key: '9', label: '显示当前配置概览', desc: '', value: 'show-config' },
      { key: '10', label: '备份/还原配置', desc: '', value: 'backup' },

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
    showSearch: true,
    items: [
      { label: `${C.green}${C.bold}── 推荐 ──${C.reset}`, disabled: true },
      { key: 'w', label: '官方完整模型配置向导', desc: `${C.green}(推荐，支持所有提供商)${C.reset}`, value: 'wizard' },

      { label: `${C.bold}── 国外模型提供商 ──${C.reset}`, disabled: true },
      { key: 'a', label: 'OpenAI', desc: 'GPT-5.2, GPT-5 mini, GPT-4.1', value: 'openai' },
      { key: 'b', label: 'Anthropic', desc: 'Claude Sonnet 4, Opus 4, Haiku', value: 'anthropic' },
      { key: 'c', label: 'Google Gemini', desc: 'Gemini 2.5 Pro/Flash, Gemini 3', value: 'google' },
      { key: 'd', label: 'OpenRouter', desc: '聚合多家模型', value: 'openrouter' },
      { key: 'e', label: 'GitHub Copilot', desc: '需要 Copilot 订阅', value: 'copilot' },
      { key: 'f', label: 'xAI Grok', desc: 'Grok-4/3', value: 'xai' },

      { label: `${C.bold}── 国内模型提供商 ──${C.reset}`, disabled: true },
      { key: 'g', label: '阿里云通义千问 Qwen', desc: 'Portal/API/Coding Plan', value: 'qwen' },
      { key: 'h', label: '硅基流动 SiliconFlow', desc: '', value: 'siliconflow' },
      { key: 'i', label: '腾讯云 Coding Plan', desc: 'HY T1/TurboS/GLM-5/Kimi', value: 'tencent' },
      { key: 'j', label: '百度千帆', desc: 'ERNIE-4.0, ERNIE-3.5', value: 'baidu' },
      { key: 'k', label: '智谱 GLM / Z.AI', desc: 'GLM-5.1, GLM-5, GLM-4.7', value: 'zhipu' },

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
      { key: '2', label: 'Telegram', desc: `${C.green}最常用${C.reset}`, value: 'telegram' },
      { key: '3', label: 'Discord', desc: '', value: 'discord' },
      { key: '4', label: '飞书 (Feishu)', desc: '', value: 'feishu' },
      { key: '5', label: 'Slack', desc: '', value: 'slack' },
      { key: '6', label: 'WhatsApp', desc: '需通过 Web 控制台扫码', value: 'whatsapp' },
      { key: '7', label: 'Telegram 配对助手', desc: '', value: 'telegram-pairing' },
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
  const logLevel = jsonGet('gateway.logLevel') || '未设置';
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

  const modelChoice = await select({
    title: 'OpenAI 模型选择',
    showSearch: false,
    items: [
      { key: 'a', label: 'gpt-5.2', desc: '最强编程与代理旗舰 (推荐)', value: 'gpt-5.2' },
      { key: 'b', label: 'gpt-5-mini', desc: '高性价比推理', value: 'gpt-5-mini' },
      { key: 'c', label: 'gpt-5-nano', desc: '极速低成本', value: 'gpt-5-nano' },
      { key: 'd', label: 'gpt-4.1', desc: '最强非推理模型', value: 'gpt-4.1' },
      { key: 'e', label: 'o3', desc: '推理模型', value: 'o3' },
      { key: 'f', label: 'o4-mini', desc: '推理轻量', value: 'o4-mini' },
      { key: 'g', label: '手动输入模型名', desc: '', value: 'custom' },
    ],
  });
  if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  let modelName = modelChoice.value;
  if (modelChoice.value === 'custom') {
    modelName = await input({ prompt: '请输入模型名称', defaultValue: 'gpt-5.2' });
    if (!modelName) return false;
  }

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

  const modelChoice = await select({
    title: 'Anthropic 模型选择',
    showSearch: false,
    items: [
      { key: 'a', label: 'claude-sonnet-4-20250514', desc: 'Claude Sonnet 4 (推荐)', value: 'claude-sonnet-4-20250514' },
      { key: 'b', label: 'claude-opus-4-20250514', desc: 'Claude Opus 4 顶级推理', value: 'claude-opus-4-20250514' },
      { key: 'c', label: 'claude-haiku-4-5', desc: 'Claude Haiku 4.5 轻量快速', value: 'claude-haiku-4-5' },
      { key: 'd', label: 'claude-sonnet-4.5', desc: 'Claude Sonnet 4.5', value: 'claude-sonnet-4.5' },
      { key: 'e', label: 'claude-sonnet-4.6', desc: 'Claude Sonnet 4.6', value: 'claude-sonnet-4.6' },
      { key: 'f', label: '手动输入模型名', desc: '', value: 'custom' },
    ],
  });
  if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  let modelName = modelChoice.value;
  if (modelChoice.value === 'custom') {
    modelName = await input({ prompt: '请输入模型名称', defaultValue: 'claude-sonnet-4-20250514' });
    if (!modelName) return false;
  }

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

  const modelChoice = await select({
    title: 'Google Gemini 模型选择',
    showSearch: false,
    items: [
      { key: 'a', label: 'gemini-2.5-pro', desc: '旗舰推理 (推荐)', value: 'gemini-2.5-pro' },
      { key: 'b', label: 'gemini-2.5-flash', desc: '快速均衡', value: 'gemini-2.5-flash' },
      { key: 'c', label: 'gemini-2.5-flash-lite', desc: '极速低成本', value: 'gemini-2.5-flash-lite' },
      { key: 'd', label: 'gemini-3-flash-preview', desc: 'Gemini 3 Flash 预览', value: 'gemini-3-flash-preview' },
      { key: 'e', label: 'gemini-3-pro-preview', desc: 'Gemini 3 Pro 预览', value: 'gemini-3-pro-preview' },
      { key: 'f', label: '手动输入模型名', desc: '', value: 'custom' },
    ],
  });
  if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  let modelName = modelChoice.value;
  if (modelChoice.value === 'custom') {
    modelName = await input({ prompt: '请输入模型名称', defaultValue: 'gemini-2.5-pro' });
    if (!modelName) return false;
  }

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

  const modelChoice = await select({
    title: 'OpenRouter 常用模型',
    showSearch: false,
    items: [
      { key: 'a', label: 'anthropic/claude-sonnet-4', desc: 'Claude Sonnet 4 (推荐)', value: 'anthropic/claude-sonnet-4' },
      { key: 'b', label: 'anthropic/claude-opus-4', desc: 'Claude Opus 4', value: 'anthropic/claude-opus-4' },
      { key: 'c', label: 'openai/gpt-5.2', desc: 'GPT-5.2', value: 'openai/gpt-5.2' },
      { key: 'd', label: 'google/gemini-2.5-pro', desc: 'Gemini 2.5 Pro', value: 'google/gemini-2.5-pro' },
      { key: 'e', label: 'deepseek/deepseek-r1', desc: 'DeepSeek R1', value: 'deepseek/deepseek-r1' },
      { key: 'f', label: 'meta-llama/llama-4-maverick', desc: 'Meta Llama 4', value: 'meta-llama/llama-4-maverick' },
      { key: 'g', label: '手动输入模型名', desc: '', value: 'custom' },
    ],
  });
  if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  let modelName = modelChoice.value;
  if (modelChoice.value === 'custom') {
    modelName = await input({ prompt: '请输入模型名称 (格式: provider/model)', defaultValue: 'anthropic/claude-sonnet-4' });
    if (!modelName) return false;
  }

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

    const modelChoice = await select({
      title: 'GitHub Copilot 模型选择',
      showSearch: false,
      items: [
        { key: 'a', label: 'gpt-4.1', desc: 'GPT-4.1 (推荐)', value: 'gpt-4.1' },
        { key: 'b', label: 'gpt-4o', desc: 'GPT-4o', value: 'gpt-4o' },
        { key: 'c', label: 'gpt-5', desc: 'GPT-5', value: 'gpt-5' },
        { key: 'd', label: 'gpt-5-mini', desc: 'GPT-5 mini', value: 'gpt-5-mini' },
        { key: 'e', label: 'gpt-5.1', desc: 'GPT-5.1', value: 'gpt-5.1' },
        { key: 'f', label: 'gpt-5.2', desc: 'GPT-5.2', value: 'gpt-5.2' },
        { key: 'g', label: 'gpt-5.2-codex', desc: 'GPT-5.2 Codex', value: 'gpt-5.2-codex' },
        { key: 'h', label: 'claude-sonnet-4', desc: 'Claude Sonnet 4', value: 'claude-sonnet-4' },
        { key: 'i', label: 'claude-sonnet-4.5', desc: 'Claude Sonnet 4.5', value: 'claude-sonnet-4.5' },
        { key: 'j', label: 'claude-sonnet-4.6', desc: 'Claude Sonnet 4.6', value: 'claude-sonnet-4.6' },
        { key: 'k', label: 'gemini-2.5-pro', desc: 'Gemini 2.5 Pro', value: 'gemini-2.5-pro' },
        { key: 'm', label: '手动输入模型名', desc: '', value: 'custom' },
      ],
    });

    if (modelChoice) {
      let modelName = modelChoice.value;
      if (modelChoice.value === 'custom') {
        modelName = await input({ prompt: '请输入模型名称', defaultValue: 'gpt-4.1' });
        if (!modelName) return false;
      }
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

  const modelChoice = await select({
    title: 'xAI Grok 模型选择',
    showSearch: false,
    items: [
      { key: 'a', label: 'grok-4', desc: 'Grok 4 旗舰 (推荐)', value: 'grok-4' },
      { key: 'b', label: 'grok-4-fast', desc: 'Grok 4 Fast', value: 'grok-4-fast' },
      { key: 'c', label: 'grok-3', desc: 'Grok 3', value: 'grok-3' },
      { key: 'd', label: 'grok-3-fast', desc: 'Grok 3 Fast', value: 'grok-3-fast' },
      { key: 'e', label: 'grok-3-mini', desc: 'Grok 3 Mini', value: 'grok-3-mini' },
      { key: 'f', label: 'grok-3-mini-fast', desc: 'Grok 3 Mini Fast', value: 'grok-3-mini-fast' },
      { key: 'g', label: '手动输入模型名', desc: '', value: 'custom' },
    ],
  });
  if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  let modelName = modelChoice.value;
  if (modelChoice.value === 'custom') {
    modelName = await input({ prompt: '请输入模型名称', defaultValue: 'grok-4' });
    if (!modelName) return false;
  }

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
      await ocCmd('models', 'auth', 'login', '--provider', 'qwen-portal', '--set-default');
    } catch {}
    console.log(`\n${C.yellow}OAuth 授权已退出${C.reset}\n`);
    return true;
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

  console.log(`\n${C.cyan}可用模型分类说明:${C.reset}`);
  console.log(`${C.yellow}* Pro模型: 仅支持充值余额支付${C.reset}`);
  console.log(`${C.yellow}* 非Pro模型: 支持代金券/免费额度${C.reset}\n`);

  const modelChoice = await select({
    title: 'SiliconFlow 模型选择',
    showSearch: false,
    items: [
      { label: `${C.cyan}── 非Pro模型 (支持代金券) ──${C.reset}`, disabled: true },
      { key: '1', label: 'deepseek-ai/DeepSeek-V3', desc: 'DeepSeek-V3 (推荐)', value: 'deepseek-ai/DeepSeek-V3' },
      { key: '2', label: 'deepseek-ai/DeepSeek-R1', desc: 'DeepSeek-R1 推理模型', value: 'deepseek-ai/DeepSeek-R1' },
      { key: '3', label: 'Qwen/Qwen2.5-72B-Instruct', desc: '通义千问 2.5 72B', value: 'Qwen/Qwen2.5-72B-Instruct' },
      { key: '4', label: 'Qwen/Qwen2.5-7B-Instruct', desc: '通义千问 2.5 7B', value: 'Qwen/Qwen2.5-7B-Instruct' },
      { key: '5', label: 'THUDM/glm-4-9b-chat', desc: '智谱 GLM-4 9B', value: 'THUDM/glm-4-9b-chat' },
      { key: '6', label: '01-ai/Yi-1.5-34B-Chat-16K', desc: '零一万物 Yi-1.5', value: '01-ai/Yi-1.5-34B-Chat-16K' },
      { label: `${C.cyan}── Pro模型 (仅支持充值余额) ──${C.reset}`, disabled: true },
      { key: '7', label: 'Pro/deepseek-ai/DeepSeek-V3', desc: 'DeepSeek-V3 (Pro)', value: 'Pro/deepseek-ai/DeepSeek-V3' },
      { key: '8', label: 'Pro/zai-org/GLM-5', desc: '智谱 GLM-5', value: 'Pro/zai-org/GLM-5' },
      { key: '0', label: '手动输入其他模型名称', desc: '', value: 'custom' },
    ],
  });
  if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  let modelName = modelChoice.value;
  if (modelChoice.value === 'custom') {
    modelName = await input({ prompt: '请输入模型详细名称', defaultValue: 'deepseek-ai/DeepSeek-V3' });
    if (!modelName) return false;
  }

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

  const modelChoice = await select({
    title: '百度千帆模型选择',
    showSearch: false,
    items: [
      { key: 'a', label: 'ernie-4.0-8k', desc: '文心一言 4.0 (推荐)', value: 'ernie-4.0-8k' },
      { key: 'b', label: 'ernie-3.5-8k', desc: '文心一言 3.5', value: 'ernie-3.5-8k' },
      { key: 'c', label: 'ernie-4.0-turbo-8k', desc: '文心一言 4.0 Turbo', value: 'ernie-4.0-turbo-8k' },
      { key: 'd', label: 'ernie-speed-8k', desc: '文心一言 Speed 极速', value: 'ernie-speed-8k' },
      { key: 'e', label: '手动输入模型名', desc: '', value: 'custom' },
    ],
  });
  if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  let modelName = modelChoice.value;
  if (modelChoice.value === 'custom') {
    modelName = await input({ prompt: '请输入模型名称', defaultValue: 'ernie-4.0-8k' });
    if (!modelName) return false;
  }

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

  const modelChoice = await select({
    title: '智谱 GLM 模型选择',
    showSearch: false,
    items: [
      { key: 'a', label: 'glm-5.1', desc: 'GLM-5.1 (推荐)', value: 'glm-5.1' },
      { key: 'b', label: 'glm-5', desc: 'GLM-5', value: 'glm-5' },
      { key: 'c', label: 'glm-4.7', desc: 'GLM-4.7', value: 'glm-4.7' },
      { key: 'd', label: 'glm-4.7-flash', desc: 'GLM-4.7 Flash', value: 'glm-4.7-flash' },
      { key: 'e', label: 'glm-4.5', desc: 'GLM-4.5', value: 'glm-4.5' },
      { key: 'f', label: 'glm-4.5-flash', desc: 'GLM-4.5 Flash (免费)', value: 'glm-4.5-flash' },
      { key: 'g', label: '手动输入模型名', desc: '', value: 'custom' },
    ],
  });
  if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  let modelName = modelChoice.value;
  if (modelChoice.value === 'custom') {
    modelName = await input({ prompt: '请输入模型名称', defaultValue: 'glm-5.1' });
    if (!modelName) return false;
  }

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

  const modelChoice = await select({
    title: 'Anthropic 模型选择',
    showSearch: false,
    items: [
      { key: 'a', label: 'claude-sonnet-4-20250514', desc: 'Claude Sonnet 4 (推荐)', value: 'claude-sonnet-4-20250514' },
      { key: 'b', label: 'claude-opus-4-20250514', desc: 'Claude Opus 4', value: 'claude-opus-4-20250514' },
      { key: 'c', label: '手动输入模型名', desc: '', value: 'custom' },
    ],
  });
  if (!modelChoice) { console.log(`${C.yellow}已取消${C.reset}`); return false; }

  let modelName = modelChoice.value;
  if (modelChoice.value === 'custom') {
    modelName = await input({ prompt: '请输入模型名称', defaultValue: 'claude-sonnet-4-20250514' });
    if (!modelName) return false;
  }

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
    await ocCmd('configure', '--section', 'model');
  } catch (e) {
    console.log(`${C.yellow}配置向导已退出${C.reset}\n`);
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
      case 'wizard': await launchWizard(); break;
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
          placeholder: 'openai/gpt-4o',
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
          await runCommand('npx', ['-y', '@larksuite/openclaw-lark-tools', 'install'], { env: { HOME: OC_DATA } });
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
        // v2026.6+ 兼容 (issue #98): 原代码调用 `ocCmd('models', 'auth', 'login-telegram-bot')`,
        // 但 OpenClaw 2026.6.x 的 `models auth` 子命令不再接受额外的位置参数
        // (错误: "Too many arguments for this command. Try: openclaw models auth --help")。
        // Telegram bot 本身无需"配对"流程,设置 botToken 即可工作,因此这里重定向到
        // 标准 Bot Token 配置。
        console.log(`\n${C.yellow}提示: Telegram 机器人无需额外配对流程,设置 Bot Token 即可工作。${C.reset}\n`);
        console.log(`${C.bold}Telegram Bot 配置${C.reset}\n`);
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
      case 'wizard': {
        console.log(`\n${C.cyan}启动官方渠道配置向导...${C.reset}\n`);
        try {
          await ocCmd('configure', '--section', 'channels');
        } catch (e) {}
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
            { key: '1', label: 'lan', desc: '仅 LAN 接口 (推荐)', value: 'lan' },
            { key: '2', label: 'loopback', desc: '仅本机访问', value: 'loopback' },
            { key: '3', label: 'all', desc: '所有接口 (0.0.0.0)', value: 'all' },
          ],
        });
        if (bindChoice) {
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
            { key: '1', label: 'debug', desc: '详细调试', value: 'debug' },
            { key: '2', label: 'info', desc: '常规信息', value: 'info' },
            { key: '3', label: 'warn', desc: '警告及以上', value: 'warn' },
            { key: '4', label: 'error', desc: '仅错误', value: 'error' },
          ],
        });
        if (levelChoice) {
          jsonSet('gateway.logLevel', levelChoice.value);
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
      case 'wizard':
        console.log(`\n${C.cyan}启动官方配置向导...${C.reset}\n`);
        try {
          await ocCmd('configure');
        } catch (e) {}
        break;
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
          jsonSet('gateway.controlUi.dangerouslyDisableDeviceAuth', true);
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
        jsonSet('gateway.controlUi.dangerouslyDisableDeviceAuth', true);
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
  console.error(`${C.red}错误:${C.reset}`, e.message);
  process.exit(1);
});
