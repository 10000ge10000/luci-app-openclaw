/**
 * ============================================================================
 * OpenClaw 配置工具 — 交互式菜单引擎
 * ============================================================================
 *
 * 功能特性:
 * - 方向键 (↑↓) 导航菜单选项
 * - 回车/空格 确认选择
 * - Tab 在多列菜单中切换
 * - ESC/q 返回上级菜单
 * - 搜索过滤 (输入字符实时过滤)
 * - 纯 Node.js 实现，零外部依赖
 * - 完全兼容 xterm.js / Web PTY 环境
 *
 * 使用方式:
 *   const menu = require('./oc-menu-engine');
 *   const choice = await menu.select({
 *     title: '选择模型提供商',
 *     items: [
 *       { key: 'a', label: 'OpenAI', desc: 'GPT-5, GPT-4.1' },
 *       { key: 'b', label: 'Anthropic', desc: 'Claude' },
 *     ]
 *   });
 */

// ANSI 颜色代码
const C = {
  reset: '\x1b[0m',
  bold: '\x1b[1m',
  dim: '\x1b[2m',
  italic: '\x1b[3m',
  underline: '\x1b[4m',
  // 前景色
  black: '\x1b[30m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
  white: '\x1b[37m',
  // 亮色
  brightRed: '\x1b[91m',
  brightGreen: '\x1b[92m',
  brightYellow: '\x1b[93m',
  brightBlue: '\x1b[94m',
  brightMagenta: '\x1b[95m',
  brightCyan: '\x1b[96m',
  // 背景色
  bgBlack: '\x1b[40m',
  bgRed: '\x1b[41m',
  bgGreen: '\x1b[42m',
  bgYellow: '\x1b[43m',
  bgBlue: '\x1b[44m',
  bgMagenta: '\x1b[45m',
  bgCyan: '\x1b[46m',
  bgWhite: '\x1b[47m',
  // 光标控制
  hide: '\x1b[?25l',
  show: '\x1b[?25h',
  save: '\x1b[s',
  restore: '\x1b[u',
  clearLine: '\x1b[2K',
  clearDown: '\x1b[J',
  // 移动
  up: (n = 1) => `\x1b[${n}A`,
  down: (n = 1) => `\x1b[${n}B`,
  right: (n = 1) => `\x1b[${n}C`,
  left: (n = 1) => `\x1b[${n}D`,
  toCol: (n) => `\x1b[${n}G`,
  toRow: (n) => `\x1b[${n}H`,
  to: (row, col) => `\x1b[${row};${col}H`,
};

// ═══════════════════════════════════════════════════════════════════════════
// 终端输入处理
// ═══════════════════════════════════════════════════════════════════════════

/**
 * 设置终端为原始模式 (逐字节读取)
 */
function setRawMode(enable) {
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(enable);
  }
}

/**
 * 从 stdin 读取单个按键
 * 支持 Bracketed Paste Mode (粘贴检测)
 * @returns {Promise<{name: string, sequence: string, char: string, paste?: string}>}
 */
function readKey() {
  return new Promise((resolve) => {
    const onData = (buffer) => {
      process.stdin.off('data', onData);

      const seq = buffer.toString('utf8');

      // 解析按键
      let key = { sequence: seq, char: '', name: '' };

      // 检测 Bracketed Paste (粘贴操作)
      // 终端在粘贴时发送: ESC[200~ <粘贴内容> ESC[201~
      if (seq.startsWith('\x1b[200~') && seq.endsWith('\x1b[201~')) {
        // 提取粘贴的内容 (去掉首尾的转义序列)
        const pasteContent = seq.slice(6, -6);
        key.name = 'paste';
        key.paste = pasteContent;
        key.char = '';
        resolve(key);
        return;
      }

      if (seq === '\r' || seq === '\n') {
        key.name = 'return';
      } else if (seq === '\t') {
        key.name = 'tab';
      } else if (seq === '\x1b') {
        key.name = 'escape';
      } else if (seq === '\x7f' || seq === '\x08') {
        key.name = 'backspace';
      } else if (seq === '\x1b[A') {
        key.name = 'up';
      } else if (seq === '\x1b[B') {
        key.name = 'down';
      } else if (seq === '\x1b[C') {
        key.name = 'right';
      } else if (seq === '\x1b[D') {
        key.name = 'left';
      } else if (seq === '\x1b[1;2A' || seq === '\x1b[1;2B') {
        // Shift+Up/Down - 可用于快速滚动
        key.name = seq.endsWith('A') ? 'shift-up' : 'shift-down';
      } else if (seq === '\x1b[5~') {
        key.name = 'pageup';
      } else if (seq === '\x1b[6~') {
        key.name = 'pagedown';
      } else if (seq === '\x1b[H') {
        key.name = 'home';
      } else if (seq === '\x1b[F') {
        key.name = 'end';
      } else if (seq.length === 1 && seq >= ' ' && seq <= '~') {
        key.char = seq;
        key.name = seq.toLowerCase();
      } else if (seq.startsWith('\x1b[') && seq.endsWith('~')) {
        // 功能键 F1-F12
        const code = seq.slice(2, -1);
        if (code >= '11' && code <= '24') {
          key.name = `f${parseInt(code) - 10}`;
        }
      }

      resolve(key);
    };

    process.stdin.once('data', onData);
  });
}

// ═══════════════════════════════════════════════════════════════════════════
// 交互式选择菜单
// ═══════════════════════════════════════════════════════════════════════════

// 记录上一次渲染的菜单行数，用于正确清除
let lastRenderLines = 0;

/**
 * 重置渲染计数器 (在打印非菜单内容前调用)
 */
function resetRenderCount() {
  lastRenderLines = 0;
}

/**
 * 渲染菜单选项
 * @param {Array} items 菜单项数组
 * @param {number} selected 当前选中索引
 * @param {string} searchFilter 搜索过滤字符串
 * @param {object} options 配置选项
 * @returns {Array} 过滤后的菜单项
 */
function renderMenu(items, selected, searchFilter = '', options = {}) {
  const {
    title = '请选择',
    header = '',
    footer = '',
    showSearch = true,
    showHelp = true,
    maxWidth = 80,
  } = options;

  // 过滤项目
  let filteredItems = items;
  if (searchFilter) {
    const filter = searchFilter.toLowerCase();
    filteredItems = items.filter(item =>
      (item.label || '').toLowerCase().includes(filter) ||
      (item.desc || '').toLowerCase().includes(filter) ||
      (item.key || '').toLowerCase().includes(filter)
    );
  }

  // 输出缓冲
  const lines = [];

  // 标题
  if (title) {
    lines.push(`${C.bold}${C.cyan}  ${title}${C.reset}`);
    lines.push('');
  }

  // 头部信息
  if (header) {
    lines.push(`  ${header}`);
    lines.push('');
  }

  // 搜索框
  if (showSearch && searchFilter !== undefined) {
    const searchPrompt = searchFilter
      ? `${C.dim}搜索: ${C.reset}${C.yellow}${searchFilter}${C.reset}${C.dim}█${C.reset}`
      : `${C.dim}搜索: ${C.reset}${C.dim}(输入字符过滤，ESC 清空)${C.reset}`;
    lines.push(`  ${searchPrompt}`);
    lines.push('');
  }

  // 菜单项
  filteredItems.forEach((item, idx) => {
    const isSelected = idx === selected;
    const isDisabled = item.disabled;

    // 选中态样式 - 使用背景色高亮整行
    const cursor = isSelected ? `${C.cyan}▸${C.reset} ` : '  ';
    const labelStyle = isSelected ? `${C.bold}${C.cyan}` : (isDisabled ? C.dim : '');
    const descStyle = isSelected ? C.cyan : C.dim;

    // 构建行
    const keyLabel = item.key ? `${C.yellow}${item.key}${C.reset}` : '';
    const mainLabel = `${labelStyle}${item.label || ''}${C.reset}`;
    const descLabel = item.desc ? `${descStyle}— ${item.desc}${C.reset}` : '';

    // 拼接
    let line = cursor;
    if (keyLabel) line += `${C.dim}[${C.reset}${keyLabel}${C.dim}]${C.reset} `;
    line += mainLabel;
    if (descLabel && !isDisabled) line += ` ${descLabel}`;

    lines.push(line);
  });

  // 空状态
  if (filteredItems.length === 0) {
    lines.push(`  ${C.dim}(没有匹配的项目)${C.reset}`);
  }

  // 底部帮助
  if (showHelp) {
    lines.push('');
    lines.push(`  ${C.dim}↑↓ 导航  回车 确认  ESC/q 返回${showSearch ? '  输入 搜索' : ''}${C.reset}`);
  }

  // 自定义底部
  if (footer) {
    lines.push('');
    lines.push(`  ${footer}`);
  }

  // 计算需要的清除行数
  const totalLines = lines.length + 1;

  // 清除之前的内容: 移动到开头，清除到屏幕底部
  let clearSeq = '\r';
  if (lastRenderLines > 0) {
    // 移动到上一次渲染的第一行
    clearSeq += `\x1b[${lastRenderLines}A`;
    // 清除从此行到屏幕底部
    clearSeq += C.clearDown;
  }
  lastRenderLines = totalLines;

  // 输出: 清除旧内容 + 新内容
  process.stdout.write(clearSeq + lines.join('\n') + '\n');

  return filteredItems;
}

/**
 * 交互式单选菜单
 * @param {object} options 配置选项
 * @returns {Promise<object|null>} 选中的项目或 null (取消)
 */
async function select(options = {}) {
  const {
    items = [],
    title = '请选择',
    header = '',
    footer = '',
    defaultIndex = 0,
    showSearch = true,
    allowCancel = true,
    // q 必须在搜索模式下作为普通字符，避免搜索 qwen 时立即退出。
    exitKeys = ['escape'],
    onSelect = null, // 选择回调 (可用于预览)
  } = options;

  if (items.length === 0) {
    return null;
  }

  // 重置渲染行计数
  lastRenderLines = 0;

  // 初始化状态
  let selected = Math.min(defaultIndex, items.length - 1);
  let searchFilter = '';
  let filteredItems = items;
  let done = false;
  let result = null;

  // 保存终端状态
  setRawMode(true);
  process.stdout.write(C.hide);
  process.stdout.write(C.save);

  try {
    // 初始渲染
    filteredItems = renderMenu(items, selected, searchFilter, { title, header, footer, showSearch });

    while (!done) {
      const key = await readKey();

      // 处理按键
      if (key.name === 'return') {
        // 确认选择
        if (filteredItems.length > 0 && !filteredItems[selected].disabled) {
          result = filteredItems[selected];
          done = true;
        } else { process.stdout.write('\x07'); }
      } else if (key.name === 'up') {
        // 上移
        let next = selected - 1;
        while (next >= 0 && filteredItems[next].disabled) next--;
        if (next >= 0) {
          selected = next;
          filteredItems = renderMenu(items, selected, searchFilter, { title, header, footer, showSearch });
        }
      } else if (key.name === 'down') {
        // 下移
        let next = selected + 1;
        while (next < filteredItems.length && filteredItems[next].disabled) next++;
        if (next < filteredItems.length) {
          selected = next;
          filteredItems = renderMenu(items, selected, searchFilter, { title, header, footer, showSearch });
        }
      } else if (key.name === 'pageup') {
        // 上翻页
        selected = Math.max(0, selected - 10);
        while (selected < filteredItems.length && filteredItems[selected].disabled) selected++;
        if (selected >= filteredItems.length) selected = 0;
        filteredItems = renderMenu(items, selected, searchFilter, { title, header, footer, showSearch });
      } else if (key.name === 'pagedown') {
        // 下翻页
        selected = Math.min(filteredItems.length - 1, selected + 10);
        while (selected >= 0 && filteredItems[selected].disabled) selected--;
        if (selected < 0) selected = filteredItems.length - 1;
        filteredItems = renderMenu(items, selected, searchFilter, { title, header, footer, showSearch });
      } else if (key.name === 'home') {
        selected = 0;
        while (selected < filteredItems.length && filteredItems[selected].disabled) selected++;
        if (selected >= filteredItems.length) selected = 0;
        filteredItems = renderMenu(items, selected, searchFilter, { title, header, footer, showSearch });
      } else if (key.name === 'end') {
        selected = filteredItems.length - 1;
        while (selected >= 0 && filteredItems[selected].disabled) selected--;
        if (selected < 0) selected = filteredItems.length - 1;
        filteredItems = renderMenu(items, selected, searchFilter, { title, header, footer, showSearch });
      } else if (exitKeys.includes(key.name) && allowCancel) {
        // 取消/退出
        done = true;
      } else if (key.name === 'backspace') {
        // 删除搜索字符
        if (searchFilter.length > 0) {
          searchFilter = searchFilter.slice(0, -1);
          selected = 0; // 重置选中
          filteredItems = renderMenu(items, selected, searchFilter, { title, header, footer, showSearch });
        }
      } else if (key.char && key.char.length === 1) {
        // 输入字符 -> 搜索
        if (showSearch) {
          searchFilter += key.char;
          selected = 0;
          filteredItems = renderMenu(items, selected, searchFilter, { title, header, footer, showSearch });
        }
      }

      // 直接按键选择 (如果菜单项有 key 属性)
      if (key.char && !showSearch) {
        const matchByChar = items.find(item => (item.key || '').toLowerCase() === key.name);
        if (matchByChar) {
          result = matchByChar;
          done = true;
        }
      }
    }
  } finally {
    // 恢复终端状态
    process.stdout.write(C.restore);
    process.stdout.write(C.clearDown);
    process.stdout.write(C.show);
    setRawMode(false);
  }

  return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// 其他交互组件
// ═══════════════════════════════════════════════════════════════════════════

/**
 * 文本输入框
 * 支持粘贴操作 (Bracketed Paste Mode)
 * @param {object} options 配置选项
 * @returns {Promise<string|null>} 输入的文本或 null (取消)
 */
async function input(options = {}) {
  const {
    prompt = '请输入',
    defaultValue = '',
    placeholder = '',
    validate = null,
    allowCancel = true,
    hidden = false, // 密码输入模式
  } = options;

  let value = '';
  let done = false;
  let cancelled = false;

  // 启用 Bracketed Paste Mode
  process.stdout.write('\x1b[?2004h');
  setRawMode(true);
  process.stdout.write(C.hide);

  try {
    // 初始渲染
    const renderInput = () => {
      const displayValue = hidden ? '*'.repeat(value.length) : value;
      const promptText = `${C.bold}${C.cyan}${prompt}:${C.reset} `;
      const valueText = displayValue || `${C.dim}${placeholder}${C.reset}`;

      process.stdout.write(`\r${C.clearLine}${promptText}${valueText}`);

      // 光标定位
      if (displayValue) {
        process.stdout.write(C.left(displayValue.length - value.length));
      }
    };

    renderInput();

    while (!done) {
      const key = await readKey();

      if (key.name === 'return') {
        // 确认
        const finalValue = value || defaultValue;
        if (validate) {
          const error = validate(finalValue);
          if (error) {
            process.stdout.write(`\n${C.red}  ✗ ${error}${C.reset}\n`);
            renderInput();
            continue;
          }
        }
        done = true;
      } else if ((key.name === 'escape' || key.name === 'q') && allowCancel) {
        done = true;
        cancelled = true;
      } else if (key.name === 'backspace') {
        if (value.length > 0) {
          value = value.slice(0, -1);
          renderInput();
        }
      } else if (key.name === 'paste' && key.paste) {
        // 处理粘贴操作 (Bracketed Paste Mode)
        // 清理粘贴内容中的控制字符和换行符
        const cleanPaste = key.paste
          .replace(/[\r\n]+/g, ' ')  // 换行符替换为空格
          .replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '')  // 移除 ANSI 转义序列
          .replace(/[\x00-\x1f]/g, '');  // 移除控制字符
        value += cleanPaste;
        renderInput();
      } else if (key.char && key.char.length === 1) {
        value += key.char;
        renderInput();
      } else if (key.sequence && key.sequence.length > 1 && !key.name.startsWith('page') &&
                 !['up', 'down', 'left', 'right', 'home', 'end'].includes(key.name)) {
        // 回退处理: 如果收到未知的多字符序列，可能是粘贴内容
        // 尝试提取可打印字符
        const extracted = key.sequence
          .replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '')
          .replace(/[\r\n]+/g, ' ')
          .replace(/[\x00-\x1f]/g, '')
          .replace(/[^\x20-\x7e]/g, '');
        if (extracted.length > 0) {
          value += extracted;
          renderInput();
        }
      }
    }
  } finally {
    // 禁用 Bracketed Paste Mode
    process.stdout.write('\x1b[?2004l');
    process.stdout.write(C.show);
    setRawMode(false);
  }

  if (cancelled) return null;

  // 显示最终值 (非隐藏模式)
  if (!hidden) {
    process.stdout.write(`\n`);
  }

  return value || defaultValue;
}

/**
 * 确认对话框
 * @param {object} options 配置选项
 * @returns {Promise<boolean>} 用户选择
 */
async function confirm(options = {}) {
  const {
    prompt = '确认吗?',
    defaultYes = true,
  } = options;

  let selected = defaultYes; // true = Yes, false = No

  setRawMode(true);
  process.stdout.write(C.hide);

  const renderConfirm = () => {
    const yesStyle = selected ? `${C.bold}${C.green}` : C.dim;
    const noStyle = selected ? C.dim : `${C.bold}${C.red}`;

    process.stdout.write(
      `\r${C.clearLine}${C.bold}${C.cyan}${prompt}${C.reset} ` +
      `${yesStyle}[Y] 是${C.reset} / ` +
      `${noStyle}[N] 否${C.reset} ` +
      `${C.dim}(←→ 切换, 回车 确认)${C.reset}`
    );
  };

  renderConfirm();

  try {
    while (true) {
      const key = await readKey();

      if (key.name === 'return') {
        process.stdout.write('\n');
        return selected;
      } else if (key.name === 'left' || key.name === 'y') {
        selected = true;
        renderConfirm();
      } else if (key.name === 'right' || key.name === 'n') {
        selected = false;
        renderConfirm();
      } else if (key.name === 'escape') {
        process.stdout.write('\n');
        return false;
      }
    }
  } finally {
    process.stdout.write(C.show);
    setRawMode(false);
  }
}

/**
 * 多选菜单 (复选框)
 * @param {object} options 配置选项
 * @returns {Promise<Array>} 选中的项目数组
 */
async function multiselect(options = {}) {
  const {
    items = [],
    title = '请选择 (空格 切换选中)',
    defaultSelected = [],
  } = options;

  if (items.length === 0) return [];

  const selectedSet = new Set(defaultSelected);
  let cursor = 0;
  let done = false;
  let cancelled = false;

  setRawMode(true);
  process.stdout.write(C.hide);

  const render = () => {
    const lines = [`\r${C.bold}${C.cyan}${title}${C.reset}\n`];

    items.forEach((item, idx) => {
      const isCursor = idx === cursor;
      const isChecked = selectedSet.has(idx);

      const cursorStyle = isCursor ? `${C.bold}${C.cyan}▸` : ' ';
      const checkChar = isChecked ? `${C.green}✓${C.reset}` : `${C.dim}○${C.reset}`;
      const labelStyle = isCursor ? C.bold : '';

      lines.push(`\r${cursorStyle} ${checkChar} ${labelStyle}${item.label}${C.reset}`);
    });

    lines.push(`\r\n${C.dim}↑↓ 移动  空格 选中  回车 确认  ESC 取消${C.reset}`);

    process.stdout.write(C.clearDown + lines.join('\n') + '\n');
  };

  render();

  try {
    while (!done) {
      const key = await readKey();

      if (key.name === 'return') {
        done = true;
      } else if (key.name === 'escape' || key.name === 'q') {
        done = true;
        cancelled = true;
      } else if (key.name === 'up' && cursor > 0) {
        cursor--;
        render();
      } else if (key.name === 'down' && cursor < items.length - 1) {
        cursor++;
        render();
      } else if (key.name === ' ' || key.name === 'tab') {
        if (selectedSet.has(cursor)) {
          selectedSet.delete(cursor);
        } else {
          selectedSet.add(cursor);
        }
        render();
      }
    }
  } finally {
    process.stdout.write(C.show);
    setRawMode(false);
  }

  if (cancelled) return [];

  return Array.from(selectedSet).map(idx => items[idx]);
}

// ═══════════════════════════════════════════════════════════════════════════
// 进度指示器
// ═══════════════════════════════════════════════════════════════════════════

/**
 * 加载动画 (Spinner)
 */
const spinners = {
  dots: ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
  line: ['-', '\\', '|', '/'],
  circle: ['◜', '◠', '◝', '◞', '◡', '◟'],
};

function spinner(options = {}) {
  const {
    text = '加载中...',
    style = 'dots',
  } = options;

  const frames = spinners[style] || spinners.dots;
  let frame = 0;
  let interval = null;
  let stopped = false;

  return {
    start() {
      process.stdout.write(C.hide);
      interval = setInterval(() => {
        if (stopped) return;
        const symbol = `${C.cyan}${frames[frame]}${C.reset}`;
        process.stdout.write(`\r${C.clearLine}${symbol} ${text}`);
        frame = (frame + 1) % frames.length;
      }, 80);
    },
    update(newText) {
      if (interval && !stopped) {
        const symbol = `${C.cyan}${frames[frame]}${C.reset}`;
        process.stdout.write(`\r${C.clearLine}${symbol} ${newText}`);
      }
    },
    stop(finalText = '') {
      stopped = true;
      if (interval) {
        clearInterval(interval);
        interval = null;
      }
      process.stdout.write(`\r${C.clearLine}${finalText}\n`);
      process.stdout.write(C.show);
    },
    succeed(text) {
      this.stop(`${C.green}✓${C.reset} ${text}`);
    },
    fail(text) {
      this.stop(`${C.red}✗${C.reset} ${text}`);
    },
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// 导出
// ═══════════════════════════════════════════════════════════════════════════

module.exports = {
  // 颜色常量
  C,

  // 核心交互
  select,
  input,
  confirm,
  multiselect,

  // 工具
  spinner,
  readKey,
  setRawMode,
  resetRenderCount,

  // 底层渲染
  renderMenu,
};
