#!/usr/bin/env node
/**
 * openclaw-package-contract.js
 *
 * OpenClaw 与 Node.js 运行时及包清单不可变契约校验工具。
 *
 * 契约规范:
 * 1. OpenClaw @ 2026.9.1 默认清单白名单校验:
 *    - name = "openclaw"
 *    - version = "2026.9.1"
 *    - bin = "openclaw.mjs"
 *    - preinstall = "node scripts/preinstall-package-manager-warning.mjs"
 *    - postinstall = "node scripts/postinstall-bundled-plugins.mjs"
 *    - optionalDependencies 中若存在 sqlite-vec 则必须为 "0.1.9" (不限定只有该项)
 *    - engines.node = ">=22.22.3 <23 || >=24.15.0 <25 || >=25.9.0"
 * 2. 运行时校验: 针对完整 engines.node 规则做精确比对，失败关闭 (fail-closed)。
 * 3. 自定义/latest 版本策略: 不套用 2026.9.1 白名单；存在 lifecycle 时 fail-closed；
 *    无 lifecycle 时校验包名、bin、实际解析版本及 engines，并标记为未验证。
 * 4. 退出码约定:
 *    - 0: 验证成功或帮助
 *    - 1: 契约不满足 / 运行时不匹配 / 脚本缺失
 *    - 2: CLI 用法或输入格式错误 (多余参数、非法/前后缀 semver、空或不支持 range、非对象 JSON 等)
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const EXPECTED_NAME = 'openclaw';
const EXPECTED_VERSION = '2026.9.1';
const EXPECTED_BIN = 'openclaw.mjs';
const EXPECTED_PREINSTALL = 'node scripts/preinstall-package-manager-warning.mjs';
const EXPECTED_POSTINSTALL = 'node scripts/postinstall-bundled-plugins.mjs';
const EXPECTED_PREINSTALL_FILE = 'scripts/preinstall-package-manager-warning.mjs';
const EXPECTED_POSTINSTALL_FILE = 'scripts/postinstall-bundled-plugins.mjs';
const EXPECTED_SQLITE_VEC_VERSION = '0.1.9';
const DEFAULT_NODE_ENGINES = '>=22.22.3 <23 || >=24.15.0 <25 || >=25.9.0';

/**
 * 严格语义化版本号解析 (严格禁止前后缀、非数字以及多余段)
 * 形如 "22.23.2" 或 "v22.23.2"
 * 拒绝 "22.23", "22.23.2.1", "22.23.2-beta", "v22.23.2foo", "abc"
 * @param {string} raw
 * @returns {{ major: number, minor: number, patch: number } | null}
 */
function parseStrictSemver(raw) {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  const m = trimmed.match(/^v?(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return null;
  return {
    major: parseInt(m[1], 10),
    minor: parseInt(m[2], 10),
    patch: parseInt(m[3], 10)
  };
}

/**
 * 比较两个语义化版本号
 * @returns {number} a > b 返回 1, a < b 返回 -1, 相等返回 0
 */
function compareSemver(a, b) {
  if (a.major !== b.major) return a.major > b.major ? 1 : -1;
  if (a.minor !== b.minor) return a.minor > b.minor ? 1 : -1;
  if (a.patch !== b.patch) return a.patch > b.patch ? 1 : -1;
  return 0;
}

/**
 * 解析比较器
 * 支持形如 ">=22.22.3", "<23", "<25", ">=25.9.0", "=22.23.2"
 * @param {string} comp
 * @returns {{ op: string, target: { major: number, minor: number, patch: number } } | null}
 */
function parseComparator(comp) {
  if (typeof comp !== 'string') return null;
  const m = comp.trim().match(/^([><]=?|=)\s*v?(\d+)(?:\.(\d+))?(?:\.(\d+))?$/);
  if (!m) return null;
  return {
    op: m[1],
    target: {
      major: parseInt(m[2], 10),
      minor: m[3] !== undefined ? parseInt(m[3], 10) : 0,
      patch: m[4] !== undefined ? parseInt(m[4], 10) : 0
    }
  };
}

/**
 * 判断版本是否满足单个比较条件
 */
function satisfiesComparator(ver, comp) {
  const parsed = parseComparator(comp);
  if (!parsed) return false;
  const cmp = compareSemver(ver, parsed.target);
  switch (parsed.op) {
    case '>': return cmp > 0;
    case '>=': return cmp >= 0;
    case '<': return cmp < 0;
    case '<=': return cmp <= 0;
    case '=': return cmp === 0;
    default: return false;
  }
}

/**
 * 校验 range 表达式合法性并判定版本是否满足
 * @param {string} verStr
 * @param {string} [rangeStr]
 * @returns {{ validRange: boolean, satisfied: boolean, error?: string }}
 */
function evaluateNodeEngines(verStr, rangeStr) {
  const ver = parseStrictSemver(verStr);
  if (!ver) {
    return { validRange: false, satisfied: false, error: `非法或包含前后缀的 semver 版本号: "${verStr}"` };
  }
  const spec = rangeStr !== undefined ? rangeStr : DEFAULT_NODE_ENGINES;
  if (typeof spec !== 'string' || !spec.trim()) {
    return { validRange: false, satisfied: false, error: 'engines.node 范围定义为空' };
  }

  const clauses = spec.split('||');
  if (clauses.length === 0) {
    return { validRange: false, satisfied: false, error: 'engines.node 范围格式非法' };
  }

  for (const clause of clauses) {
    const comps = clause.trim().split(/\s+/).filter(Boolean);
    if (comps.length === 0) {
      return { validRange: false, satisfied: false, error: 'engines.node 存在空条件区间' };
    }
    for (const comp of comps) {
      if (!parseComparator(comp)) {
        return { validRange: false, satisfied: false, error: `不支持或非法的比较器: "${comp}"` };
      }
    }
  }

  for (const clause of clauses) {
    const comps = clause.trim().split(/\s+/).filter(Boolean);
    let allSatisfied = true;
    for (const comp of comps) {
      if (!satisfiesComparator(ver, comp)) {
        allSatisfied = false;
        break;
      }
    }
    if (allSatisfied) {
      return { validRange: true, satisfied: true };
    }
  }

  return { validRange: true, satisfied: false };
}

/**
 * 兼容旧接口的布尔检查函数
 */
function satisfiesNodeEngines(verStr, rangeStr) {
  const res = evaluateNodeEngines(verStr, rangeStr);
  return res.validRange && res.satisfied;
}

/**
 * 校验 package.json 清单
 * @param {object|string} pkgOrPath
 * @param {string} targetVersion
 * @returns {{ valid: boolean, isUsageError?: boolean, vettedScripts?: string[], error?: string, warning?: string, unverified?: boolean }}
 */
function validateManifest(pkgOrPath, targetVersion, nodeVersion) {
  let pkg;
  let pkgDir = null;

  if (typeof pkgOrPath === 'string') {
    if (!fs.existsSync(pkgOrPath)) {
      return { valid: false, isUsageError: true, error: `文件不存在: ${pkgOrPath}` };
    }
    try {
      const raw = fs.readFileSync(pkgOrPath, 'utf8');
      pkg = JSON.parse(raw);
    } catch (e) {
      return { valid: false, isUsageError: true, error: `无法读取或解析 package.json (${pkgOrPath}): ${e.message}` };
    }
    pkgDir = path.dirname(path.resolve(pkgOrPath));
  } else {
    pkg = pkgOrPath;
  }

  if (!pkg || typeof pkg !== 'object' || Array.isArray(pkg)) {
    return { valid: false, isUsageError: true, error: 'package.json 内容为空或不是有效的非数组 JSON 对象' };
  }

  if (typeof targetVersion !== 'string' || !targetVersion.trim()) {
    return { valid: false, isUsageError: true, error: '缺少或非法的 target-version 参数' };
  }

  const targetVerTrimmed = targetVersion.trim();
  const isPinned2026_9_1 = (targetVerTrimmed === '2026.9.1' || targetVerTrimmed === 'stable');

  if (isPinned2026_9_1) {
    // ── 针对 2026.9.1 进行精确不可变清单校验 ──
    // name 校验: 存在、类型为 string、值精确等于 openclaw
    if (pkg.name === undefined) {
      return { valid: false, error: 'package.json 缺少 name 字段' };
    }
    if (typeof pkg.name !== 'string') {
      return { valid: false, error: `name 字段类型错误: 期望 string, 实际 ${typeof pkg.name}` };
    }
    if (pkg.name !== EXPECTED_NAME) {
      return { valid: false, error: `包名漂移: 期望 "${EXPECTED_NAME}", 实际 "${pkg.name}"` };
    }

    // version 校验: 存在、类型为 string、值精确等于 2026.9.1
    if (pkg.version === undefined) {
      return { valid: false, error: 'package.json 缺少 version 字段' };
    }
    if (typeof pkg.version !== 'string') {
      return { valid: false, error: `version 字段类型错误: 期望 string, 实际 ${typeof pkg.version}` };
    }
    if (pkg.version !== EXPECTED_VERSION) {
      return { valid: false, error: `版本号漂移: 期望 "${EXPECTED_VERSION}", 实际 "${pkg.version}"` };
    }

    // bin 校验: 必须为对象，bin.openclaw 必须存在且为 EXPECTED_BIN
    if (pkg.bin === undefined) {
      return { valid: false, error: 'package.json 缺少 bin 对象' };
    }
    if (typeof pkg.bin !== 'object' || pkg.bin === null || Array.isArray(pkg.bin)) {
      return { valid: false, error: `bin 字段类型错误: 期望 object, 实际 ${Array.isArray(pkg.bin) ? 'array' : (pkg.bin === null ? 'null' : typeof pkg.bin)}` };
    }
    if (pkg.bin.openclaw === undefined) {
      return { valid: false, error: 'package.json 缺少 bin.openclaw 字段' };
    }
    if (typeof pkg.bin.openclaw !== 'string') {
      return { valid: false, error: `bin.openclaw 字段类型错误: 期望 string, 实际 ${typeof pkg.bin.openclaw}` };
    }
    if (pkg.bin.openclaw !== EXPECTED_BIN) {
      return { valid: false, error: `bin 入口漂移: 期望 "${EXPECTED_BIN}", 实际 "${pkg.bin.openclaw}"` };
    }
    const binKeys = Object.keys(pkg.bin);
    if (binKeys.length !== 1 || binKeys[0] !== 'openclaw') {
      return { valid: false, error: `bin 结构漂移: 仅允许定义 openclaw 入口, 实际包含: ${binKeys.join(', ')}` };
    }

    // scripts 校验: 必须为对象，preinstall 与 postinstall 必须精确匹配
    if (pkg.scripts === undefined) {
      return { valid: false, error: 'package.json 缺少 scripts 对象' };
    }
    if (typeof pkg.scripts !== 'object' || pkg.scripts === null || Array.isArray(pkg.scripts)) {
      return { valid: false, error: `scripts 字段类型错误: 期望 object, 实际 ${Array.isArray(pkg.scripts) ? 'array' : (pkg.scripts === null ? 'null' : typeof pkg.scripts)}` };
    }
    if (pkg.scripts.preinstall === undefined) {
      return { valid: false, error: 'package.json 缺少 preinstall 脚本' };
    }
    if (typeof pkg.scripts.preinstall !== 'string') {
      return { valid: false, error: `preinstall 脚本类型错误: 期望 string, 实际 ${typeof pkg.scripts.preinstall}` };
    }
    if (pkg.scripts.preinstall !== EXPECTED_PREINSTALL) {
      return { valid: false, error: `preinstall 脚本漂移: 期望 "${EXPECTED_PREINSTALL}", 实际 "${pkg.scripts.preinstall}"` };
    }

    if (pkg.scripts.postinstall === undefined) {
      return { valid: false, error: 'package.json 缺少 postinstall 脚本' };
    }
    if (typeof pkg.scripts.postinstall !== 'string') {
      return { valid: false, error: `postinstall 脚本类型错误: 期望 string, 实际 ${typeof pkg.scripts.postinstall}` };
    }
    if (pkg.scripts.postinstall !== EXPECTED_POSTINSTALL) {
      return { valid: false, error: `postinstall 脚本漂移: 期望 "${EXPECTED_POSTINSTALL}", 实际 "${pkg.scripts.postinstall}"` };
    }

    const knownLifecycle = new Set(['preinstall', 'postinstall']);
    const INSTALL_LIFECYCLE_KEYS = new Set([
      'install', 'preinstall', 'postinstall',
      'prepare', 'prepack', 'postpack'
    ]);
    for (const k of Object.keys(pkg.scripts)) {
      const isLifecycle = INSTALL_LIFECYCLE_KEYS.has(k);
      if (isLifecycle && !knownLifecycle.has(k)) {
        return { valid: false, error: `存在未知或额外 lifecycle 脚本漂移: ${k}="${pkg.scripts[k]}"` };
      }
      const val = pkg.scripts[k];
      if (typeof val !== 'string' || !val.trim()) {
        return { valid: false, error: `scripts.${k} 脚本值为空或类型非法` };
      }
    }

    // optionalDependencies 校验 (必须存在对象且包含 sqlite-vec="0.1.9")
    if (pkg.optionalDependencies === undefined) {
      return { valid: false, error: 'package.json 缺少 optionalDependencies 对象' };
    }
    if (typeof pkg.optionalDependencies !== 'object' || pkg.optionalDependencies === null || Array.isArray(pkg.optionalDependencies)) {
      return { valid: false, error: `optionalDependencies 字段类型错误: 期望 object, 实际 ${Array.isArray(pkg.optionalDependencies) ? 'array' : (pkg.optionalDependencies === null ? 'null' : typeof pkg.optionalDependencies)}` };
    }
    if (pkg.optionalDependencies['sqlite-vec'] === undefined) {
      return { valid: false, error: 'package.json 缺少 optionalDependencies.sqlite-vec 字段' };
    }
    if (typeof pkg.optionalDependencies['sqlite-vec'] !== 'string') {
      return { valid: false, error: `sqlite-vec 字段类型错误: 期望 string, 实际 ${typeof pkg.optionalDependencies['sqlite-vec']}` };
    }
    if (pkg.optionalDependencies['sqlite-vec'] !== EXPECTED_SQLITE_VEC_VERSION) {
      return { valid: false, error: `sqlite-vec 版本漂移: 期望 "${EXPECTED_SQLITE_VEC_VERSION}", 实际 "${pkg.optionalDependencies['sqlite-vec']}"` };
    }

    // engines.node 校验
    if (pkg.engines === undefined) {
      return { valid: false, error: 'package.json 缺少 engines 对象' };
    }
    if (typeof pkg.engines !== 'object' || pkg.engines === null || Array.isArray(pkg.engines)) {
      return { valid: false, error: `engines 字段类型错误: 期望 object, 实际 ${Array.isArray(pkg.engines) ? 'array' : (pkg.engines === null ? 'null' : typeof pkg.engines)}` };
    }
    if (pkg.engines.node === undefined) {
      return { valid: false, error: 'package.json 缺少 engines.node 定义' };
    }
    if (typeof pkg.engines.node !== 'string') {
      return { valid: false, error: `engines.node 字段类型错误: 期望 string, 实际 ${typeof pkg.engines.node}` };
    }
    if (pkg.engines.node !== DEFAULT_NODE_ENGINES) {
      return { valid: false, error: `engines.node 漂移: 期望 "${DEFAULT_NODE_ENGINES}", 实际 "${pkg.engines.node}"` };
    }

    // 如果所在目录存在 scripts 目录 (真实已解压安装包)，则校验两脚本文件真实存在
    if (pkgDir && fs.existsSync(path.join(pkgDir, 'scripts'))) {
      const preinstallFile = path.join(pkgDir, EXPECTED_PREINSTALL_FILE);
      const postinstallFile = path.join(pkgDir, EXPECTED_POSTINSTALL_FILE);
      if (!fs.existsSync(preinstallFile)) {
        return { valid: false, error: `白名单 preinstall 脚本文件不存在: ${preinstallFile}` };
      }
      if (!fs.existsSync(postinstallFile)) {
        return { valid: false, error: `白名单 postinstall 脚本文件不存在: ${postinstallFile}` };
      }
    }

    return {
      valid: true,
      vettedScripts: [EXPECTED_PREINSTALL_FILE, EXPECTED_POSTINSTALL_FILE]
    };
  } else {
    // ── latest 或自定义版本: 不套用 2026.9.1 白名单 ──
    if (pkg.name !== EXPECTED_NAME) {
      return { valid: false, error: `包名不匹配: 期望 "${EXPECTED_NAME}", 实际 "${pkg.name}"` };
    }

    let binTarget = '';
    if (typeof pkg.bin === 'string') {
      binTarget = pkg.bin;
    } else if (pkg.bin && typeof pkg.bin === 'object' && !Array.isArray(pkg.bin)) {
      binTarget = pkg.bin.openclaw || pkg.bin[EXPECTED_NAME] || '';
    }
    if (!binTarget || !binTarget.endsWith('openclaw.mjs')) {
      return { valid: false, error: `bin 入口漂移或无效: "${binTarget}"` };
    }

    if (typeof pkg.version !== 'string') {
      return { valid: false, error: 'package.json 缺少或非法 version 字段' };
    }
    const parsedVer = parseStrictSemver(pkg.version);
    if (!parsedVer) {
      return { valid: false, error: `package.json 版本号非法或包含前后缀: "${pkg.version}"` };
    }
    if (targetVerTrimmed !== 'latest' && targetVerTrimmed !== pkg.version) {
      return { valid: false, error: `实际版本 (${pkg.version}) 与请求版本 (${targetVerTrimmed}) 不一致` };
    }

    const engineSpec = (pkg.engines && pkg.engines.node) || '';
    if (!engineSpec || typeof engineSpec !== 'string') {
      return { valid: false, error: 'package.json 缺少 engines.node 定义' };
    }
    const currentNodeVer = (nodeVersion ? String(nodeVersion).replace(/^v/, '') : (process.versions.node || (process.version ? process.version.replace(/^v/, '') : '')));
    const evalRes = evaluateNodeEngines(currentNodeVer, engineSpec);
    if (!evalRes.validRange) {
      return { valid: false, error: `engines.node 语法非法: ${evalRes.error}` };
    }
    if (!evalRes.satisfied) {
      return { valid: false, error: `当前 Node.js 运行时 v${currentNodeVer} 不满足 engines.node 契约: "${engineSpec}"` };
    }

    const scripts = (pkg.scripts && typeof pkg.scripts === 'object' && !Array.isArray(pkg.scripts)) ? pkg.scripts : {};
    const INSTALL_LIFECYCLE_KEYS = new Set([
      'install', 'preinstall', 'postinstall',
      'prepare', 'prepack', 'postpack'
    ]);
    const detectedLifecycles = [];
    for (const k of Object.keys(scripts)) {
      if (INSTALL_LIFECYCLE_KEYS.has(k)) {
        detectedLifecycles.push(k);
      }
    }
    if (detectedLifecycles.length > 0) {
      return {
        valid: false,
        error: `拒绝执行未验证版本的 lifecycle 脚本 (${detectedLifecycles.join(', ')}). 自定义/latest 版本不得套用 2026.9.1 白名单 (fail-closed)`
      };
    }

    return {
      valid: true,
      vettedScripts: [],
      unverified: true,
      warning: `当前安装版本为自定义/latest (${pkg.version || targetVerTrimmed})，未套用 2026.9.1 白名单，已阻断所有 lifecycle 脚本并标记为未验证安装`
    };
  }
}

/**
 * 校验 Node.js 运行时
 * @param {string} nodeBin
 * @param {string} [spec]
 * @returns {{ valid: boolean, version?: string, isUsageError?: boolean, error?: string }}
 */
function validateRuntime(nodeBin, spec) {
  try {
    const raw = execFileSync(nodeBin, ['--version'], { encoding: 'utf8' }).trim();
    const ver = raw.replace(/^v/, '');
    const engineSpec = spec || DEFAULT_NODE_ENGINES;
    const evalRes = evaluateNodeEngines(ver, engineSpec);
    if (!evalRes.validRange) {
      return { valid: false, isUsageError: true, error: evalRes.error };
    }
    if (!evalRes.satisfied) {
      return {
        valid: false,
        version: ver,
        error: `Node.js v${ver} 不满足 engines.node 契约: "${engineSpec}"`
      };
    }
    return { valid: true, version: ver };
  } catch (e) {
    return { valid: false, isUsageError: true, error: `无法执行 Node.js (${nodeBin}): ${e.message}` };
  }
}

/**
 * 获取经过审核的脚本列表并检查文件真实存在
 * @param {string} pkgPath
 * @param {string} targetVersion
 * @returns {{ valid: boolean, isUsageError?: boolean, scripts?: string[], error?: string }}
 */
function getVettedScripts(pkgPath, targetVersion) {
  const res = validateManifest(pkgPath, targetVersion);
  if (!res.valid) {
    return res;
  }
  if (!res.vettedScripts || res.vettedScripts.length === 0) {
    return { valid: true, scripts: [] };
  }
  const pkgDir = path.dirname(path.resolve(pkgPath));
  for (const s of res.vettedScripts) {
    const fullPath = path.join(pkgDir, s);
    if (!fs.existsSync(fullPath)) {
      return { valid: false, error: `白名单脚本文件真实路径不存在: ${fullPath}` };
    }
  }
  return { valid: true, scripts: res.vettedScripts };
}

// ── CLI 执行入口 ──
if (require.main === module) {
  const args = process.argv.slice(2);
  const command = args[0];

  if (command === '--help' || command === '-h') {
    console.log(`用法: node openclaw-package-contract.js <command> [args...]
命令:
  validate-manifest <package.json-path> <target-version>
  validate-node-version <version-string> [engine-spec]
  validate-runtime <node-binary-path> [engine-spec]
  get-vetted-scripts <package.json-path> <target-version>
`);
    process.exit(0);
  }

  if (!command) {
    console.error('错误: 请指定命令。使用 --help 查看帮助。');
    process.exit(2);
  }

  if (command === 'validate-manifest') {
    if (args.length !== 3) {
      console.error('用法错误: validate-manifest 需要恰好 2 个参数: <package.json-path> <target-version>');
      process.exit(2);
    }
    const pkgPath = args[1];
    const targetVer = args[2];
    const res = validateManifest(pkgPath, targetVer);
    if (!res.valid) {
      console.error(`[✗] 包清单校验失败: ${res.error}`);
      process.exit(res.isUsageError ? 2 : 1);
    }
    if (res.warning) {
      console.warn(`[!] ${res.warning}`);
    }
    console.log('[✓] 包清单契约校验通过');
    process.exit(0);
  }

  if (command === 'validate-node-version') {
    if (args.length < 2 || args.length > 3) {
      console.error('用法错误: validate-node-version 需要 1 或 2 个参数: <version-string> [engine-spec]');
      process.exit(2);
    }
    const ver = args[1];
    const spec = args[2];
    const evalRes = evaluateNodeEngines(ver, spec);
    if (!evalRes.validRange) {
      console.error(`[✗] 输入格式错误: ${evalRes.error}`);
      process.exit(2);
    }
    if (!evalRes.satisfied) {
      console.error(`[✗] Node.js 版本 v${ver} 不满足契约: "${spec || DEFAULT_NODE_ENGINES}"`);
      process.exit(1);
    }
    console.log(`[✓] Node.js 版本 v${ver} 满足契约`);
    process.exit(0);
  }

  if (command === 'validate-runtime') {
    if (args.length < 2 || args.length > 3) {
      console.error('用法错误: validate-runtime 需要 1 或 2 个参数: <node-binary-path> [engine-spec]');
      process.exit(2);
    }
    const nodeBin = args[1];
    const engineSpec = args[2];
    const res = validateRuntime(nodeBin, engineSpec);
    if (!res.valid) {
      console.error(`[✗] 运行时校验失败: ${res.error}`);
      process.exit(res.isUsageError ? 2 : 1);
    }
    console.log(`[✓] Node.js 运行时 v${res.version} 满足契约 (${engineSpec || DEFAULT_NODE_ENGINES})`);
    process.exit(0);
  }

  if (command === 'get-vetted-scripts') {
    if (args.length !== 3) {
      console.error('用法错误: get-vetted-scripts 需要恰好 2 个参数: <package.json-path> <target-version>');
      process.exit(2);
    }
    const pkgPath = args[1];
    const targetVer = args[2];
    const res = getVettedScripts(pkgPath, targetVer);
    if (!res.valid) {
      console.error(`[✗] ${res.error}`);
      process.exit(res.isUsageError ? 2 : 1);
    }
    if (res.scripts && res.scripts.length > 0) {
      for (const s of res.scripts) {
        console.log(s);
      }
    }
    process.exit(0);
  }

  console.error(`未知命令: ${command}`);
  process.exit(2);
}

module.exports = {
  EXPECTED_NAME,
  EXPECTED_VERSION,
  EXPECTED_BIN,
  EXPECTED_PREINSTALL,
  EXPECTED_POSTINSTALL,
  EXPECTED_PREINSTALL_FILE,
  EXPECTED_POSTINSTALL_FILE,
  EXPECTED_SQLITE_VEC_VERSION,
  DEFAULT_NODE_ENGINES,
  parseStrictSemver,
  compareSemver,
  parseComparator,
  evaluateNodeEngines,
  satisfiesNodeEngines,
  validateManifest,
  validateRuntime,
  getVettedScripts
};
