#!/usr/bin/env node
/**
 * openclaw-package-contract.js
 *
 * OpenClaw 与 Node.js 运行时及包清单不可变契约校验工具。
 *
 * 契约规范 (数据来自同目录 openclaw-compat.json，可用 OC_COMPAT_FILE 覆盖):
 * 1. 已验证版本 (compat.versions 中列出): 逐项精确校验
 *    - name = "openclaw"，bin 只允许 { openclaw: "openclaw.mjs" }
 *    - preinstall / postinstall 与 compat.lifecycle 完全一致，不允许额外 lifecycle
 *    - optionalDependencies.sqlite-vec 与矩阵记录一致
 *    - engines.node 与矩阵记录完全一致
 *    - tarball sha512 integrity 与矩阵记录一致 (validate-integrity)
 * 2. 未验证版本 (上游已发布但不在矩阵中): 默认拒绝。
 *    仅当调用方显式允许 (OC_ALLOW_UNVERIFIED=1) 时放行，且 lifecycle 只能是
 *    与已验证版本完全相同的 preinstall/postinstall 命令，engines 必须被当前 Node 满足。
 * 3. 运行时校验: 针对完整 engines.node 规则做精确比对，失败关闭 (fail-closed)。
 * 4. 退出码约定:
 *    - 0: 验证成功或帮助
 *    - 1: 契约不满足 / 运行时不匹配 / 脚本缺失 / 未验证版本被拒绝
 *    - 2: CLI 用法或输入格式错误 (多余参数、非法/前后缀 semver、空或不支持 range、非对象 JSON 等)
 */

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const EXPECTED_NAME = 'openclaw';
const EXPECTED_BIN = 'openclaw.mjs';
const INSTALL_LIFECYCLE_KEYS = new Set(['install', 'preinstall', 'postinstall', 'prepare', 'prepack', 'postpack']);
const CHANNEL_NAMES = ['extended-stable', 'latest'];

function compatFilePath() {
  return process.env.OC_COMPAT_FILE || path.join(__dirname, 'openclaw-compat.json');
}

/**
 * 读取兼容矩阵。缺失或损坏时抛错，由调用方失败关闭。
 */
function loadCompat(file) {
  const p = file || compatFilePath();
  const raw = fs.readFileSync(p, 'utf8');
  const data = JSON.parse(raw);
  if (!data || typeof data !== 'object' || !data.versions || !data.channels || !data.lifecycle) {
    throw new Error(`兼容矩阵结构无效: ${p}`);
  }
  return data;
}

let compatCache = null;
function compat() {
  if (!compatCache) compatCache = loadCompat();
  return compatCache;
}

function safeCompat() {
  try { return compat(); } catch { return null; }
}

const C0 = safeCompat();
const LIFECYCLE = (C0 && C0.lifecycle) || {};
const EXPECTED_PREINSTALL = LIFECYCLE.preinstall || 'node scripts/preinstall-package-manager-warning.mjs';
const EXPECTED_POSTINSTALL = LIFECYCLE.postinstall || 'node scripts/postinstall-bundled-plugins.mjs';
const EXPECTED_PREINSTALL_FILE = LIFECYCLE.preinstallFile || 'scripts/preinstall-package-manager-warning.mjs';
const EXPECTED_POSTINSTALL_FILE = LIFECYCLE.postinstallFile || 'scripts/postinstall-bundled-plugins.mjs';
// 兼容旧接口: EXPECTED_VERSION / DEFAULT_NODE_ENGINES 指向默认通道的已验证版本
const EXPECTED_VERSION = C0 ? C0.channels[C0.defaultChannel].verified : '';
const DEFAULT_NODE_ENGINES = (C0 && C0.versions[EXPECTED_VERSION] && C0.versions[EXPECTED_VERSION].engines) || '';
const EXPECTED_SQLITE_VEC_VERSION = (C0 && C0.versions[EXPECTED_VERSION] && C0.versions[EXPECTED_VERSION].sqliteVec) || '';

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
    if (comps.every((comp) => satisfiesComparator(ver, comp))) {
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

function typeName(v) {
  if (Array.isArray(v)) return 'array';
  if (v === null) return 'null';
  return typeof v;
}

function isPlainObject(v) {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/**
 * 把调用方传入的目标解析成精确版本:
 *   - 精确 semver: 原样返回
 *   - "stable": 默认通道的已验证版本 (历史别名)
 *   - 通道名: 该通道的已验证版本
 *   - "latest" 历史上表示 npm latest 标签，这里同样解析为 latest 通道的已验证版本
 */
function resolveTargetAlias(target, data) {
  const t = String(target || '').trim();
  if (parseStrictSemver(t)) return t.replace(/^v/, '');
  if (!data) return null;
  if (t === 'stable' || t === '') return data.channels[data.defaultChannel].verified;
  if (data.channels[t]) return data.channels[t].verified;
  return null;
}

function allowUnverifiedFromEnv() {
  return process.env.OC_ALLOW_UNVERIFIED === '1';
}

/**
 * 校验 package.json 清单
 * @param {object|string} pkgOrPath
 * @param {string} targetVersion  精确版本或别名 (stable / extended-stable / latest)
 * @param {string} [nodeVersion]  未验证版本做 engines 校验时使用的 Node 版本，默认当前进程
 * @param {{ allowUnverified?: boolean }} [opts]
 * @returns {{ valid: boolean, isUsageError?: boolean, vettedScripts?: string[], error?: string, warning?: string, unverified?: boolean, verified?: boolean }}
 */
function validateManifest(pkgOrPath, targetVersion, nodeVersion, opts = {}) {
  let pkg;
  let pkgDir = null;

  if (typeof pkgOrPath === 'string') {
    if (!fs.existsSync(pkgOrPath)) {
      return { valid: false, isUsageError: true, error: `文件不存在: ${pkgOrPath}` };
    }
    try {
      pkg = JSON.parse(fs.readFileSync(pkgOrPath, 'utf8'));
    } catch (e) {
      return { valid: false, isUsageError: true, error: `无法读取或解析 package.json (${pkgOrPath}): ${e.message}` };
    }
    pkgDir = path.dirname(path.resolve(pkgOrPath));
  } else {
    pkg = pkgOrPath;
  }

  if (!isPlainObject(pkg)) {
    return { valid: false, isUsageError: true, error: 'package.json 内容为空或不是有效的非数组 JSON 对象' };
  }
  if (typeof targetVersion !== 'string' || !targetVersion.trim()) {
    return { valid: false, isUsageError: true, error: '缺少或非法的 target-version 参数' };
  }

  let data;
  try {
    data = compat();
  } catch (e) {
    return { valid: false, error: `兼容矩阵不可用，失败关闭: ${e.message}` };
  }

  const targetExact = resolveTargetAlias(targetVersion, data);
  if (!targetExact) {
    return { valid: false, isUsageError: true, error: `无法解析目标版本: "${targetVersion}"` };
  }

  // ── 公共字段: 包名、bin、版本号 ──
  if (pkg.name === undefined) return { valid: false, error: 'package.json 缺少 name 字段' };
  if (typeof pkg.name !== 'string') return { valid: false, error: `name 字段类型错误: 期望 string, 实际 ${typeof pkg.name}` };
  if (pkg.name !== EXPECTED_NAME) return { valid: false, error: `包名漂移: 期望 "${EXPECTED_NAME}", 实际 "${pkg.name}"` };

  if (pkg.bin === undefined) return { valid: false, error: 'package.json 缺少 bin 对象' };
  if (!isPlainObject(pkg.bin)) return { valid: false, error: `bin 字段类型错误: 期望 object, 实际 ${typeName(pkg.bin)}` };
  if (pkg.bin.openclaw === undefined) return { valid: false, error: 'package.json 缺少 bin.openclaw 字段' };
  if (typeof pkg.bin.openclaw !== 'string') return { valid: false, error: `bin.openclaw 字段类型错误: 期望 string, 实际 ${typeof pkg.bin.openclaw}` };
  if (pkg.bin.openclaw !== EXPECTED_BIN) return { valid: false, error: `bin 入口漂移: 期望 "${EXPECTED_BIN}", 实际 "${pkg.bin.openclaw}"` };
  const binKeys = Object.keys(pkg.bin);
  if (binKeys.length !== 1 || binKeys[0] !== 'openclaw') {
    return { valid: false, error: `bin 结构漂移: 仅允许定义 openclaw 入口, 实际包含: ${binKeys.join(', ')}` };
  }

  if (pkg.version === undefined) return { valid: false, error: 'package.json 缺少 version 字段' };
  if (typeof pkg.version !== 'string') return { valid: false, error: `version 字段类型错误: 期望 string, 实际 ${typeof pkg.version}` };
  if (!parseStrictSemver(pkg.version)) return { valid: false, error: `package.json 版本号非法或包含前后缀: "${pkg.version}"` };
  if (pkg.version !== targetExact) {
    return { valid: false, error: `版本号漂移: 期望 "${targetExact}", 实际 "${pkg.version}"` };
  }

  // ── scripts: 只允许与已验证版本完全相同的 preinstall/postinstall ──
  const scripts = pkg.scripts === undefined ? {} : pkg.scripts;
  if (!isPlainObject(scripts)) {
    return { valid: false, error: `scripts 字段类型错误: 期望 object, 实际 ${typeName(scripts)}` };
  }
  for (const k of Object.keys(scripts)) {
    const val = scripts[k];
    if (typeof val !== 'string' || !val.trim()) {
      return { valid: false, error: `scripts.${k} 脚本值为空或类型非法` };
    }
    if (INSTALL_LIFECYCLE_KEYS.has(k) && k !== 'preinstall' && k !== 'postinstall') {
      return { valid: false, error: `存在未知或额外 lifecycle 脚本漂移: ${k}="${val}"` };
    }
  }
  if (scripts.preinstall !== undefined && scripts.preinstall !== EXPECTED_PREINSTALL) {
    return { valid: false, error: `preinstall 脚本漂移: 期望 "${EXPECTED_PREINSTALL}", 实际 "${scripts.preinstall}"` };
  }
  if (scripts.postinstall !== undefined && scripts.postinstall !== EXPECTED_POSTINSTALL) {
    return { valid: false, error: `postinstall 脚本漂移: 期望 "${EXPECTED_POSTINSTALL}", 实际 "${scripts.postinstall}"` };
  }
  const vetted = [];
  if (scripts.preinstall !== undefined) vetted.push(EXPECTED_PREINSTALL_FILE);
  if (scripts.postinstall !== undefined) vetted.push(EXPECTED_POSTINSTALL_FILE);

  // 真实解压目录中必须存在要执行的脚本文件
  if (pkgDir && fs.existsSync(path.join(pkgDir, 'scripts'))) {
    for (const rel of vetted) {
      const full = path.join(pkgDir, rel);
      if (!fs.existsSync(full)) {
        return { valid: false, error: `白名单 ${rel.includes('preinstall') ? 'preinstall' : 'postinstall'} 脚本文件不存在: ${full}` };
      }
    }
  }

  const entry = data.versions[pkg.version];
  if (entry) {
    // ── 已验证版本: 必须与矩阵逐项一致 ──
    if (scripts.preinstall === undefined) return { valid: false, error: 'package.json 缺少 preinstall 脚本' };
    if (scripts.postinstall === undefined) return { valid: false, error: 'package.json 缺少 postinstall 脚本' };

    if (entry.sqliteVec) {
      if (!isPlainObject(pkg.optionalDependencies)) {
        return { valid: false, error: `optionalDependencies 字段类型错误: 期望 object, 实际 ${typeName(pkg.optionalDependencies)}` };
      }
      if (pkg.optionalDependencies['sqlite-vec'] !== entry.sqliteVec) {
        return { valid: false, error: `sqlite-vec 版本漂移: 期望 "${entry.sqliteVec}", 实际 "${pkg.optionalDependencies['sqlite-vec']}"` };
      }
    }

    if (!isPlainObject(pkg.engines)) {
      return { valid: false, error: `engines 字段类型错误: 期望 object, 实际 ${typeName(pkg.engines)}` };
    }
    if (pkg.engines.node !== entry.engines) {
      return { valid: false, error: `engines.node 漂移: 期望 "${entry.engines}", 实际 "${pkg.engines.node}"` };
    }

    return { valid: true, verified: true, vettedScripts: vetted };
  }

  // ── 未验证版本 ──
  const allow = opts.allowUnverified !== undefined ? !!opts.allowUnverified : allowUnverifiedFromEnv();
  if (!allow) {
    return {
      valid: false,
      error: `OpenClaw ${pkg.version} 未经本插件验证 (不在兼容矩阵中)。如确需安装，请在界面勾选「允许安装未验证版本」后重试`
    };
  }
  const engineSpec = isPlainObject(pkg.engines) ? pkg.engines.node : '';
  if (!engineSpec || typeof engineSpec !== 'string') {
    return { valid: false, error: 'package.json 缺少 engines.node 定义' };
  }
  const currentNodeVer = nodeVersion ? String(nodeVersion).replace(/^v/, '') : process.versions.node;
  const evalRes = evaluateNodeEngines(currentNodeVer, engineSpec);
  if (!evalRes.validRange) return { valid: false, error: `engines.node 语法非法: ${evalRes.error}` };
  if (!evalRes.satisfied) {
    return { valid: false, error: `当前 Node.js 运行时 v${currentNodeVer} 不满足 engines.node 契约: "${engineSpec}"` };
  }
  return {
    valid: true,
    verified: false,
    unverified: true,
    vettedScripts: vetted,
    warning: `OpenClaw ${pkg.version} 未经本插件验证，已按用户明确选择继续安装；lifecycle 命令与已验证版本一致`
  };
}

/**
 * 计算 tarball 的 npm 风格 sha512 integrity
 */
function computeIntegrity(file) {
  const hash = crypto.createHash('sha512');
  hash.update(fs.readFileSync(file));
  return `sha512-${hash.digest('base64')}`;
}

/**
 * 已验证版本: tarball integrity 必须与矩阵一致；未验证版本由 npm 依据 registry 元数据校验，这里返回 skipped。
 */
function validateIntegrity(tarball, version) {
  if (!fs.existsSync(tarball)) {
    return { valid: false, isUsageError: true, error: `tarball 不存在: ${tarball}` };
  }
  let data;
  try {
    data = compat();
  } catch (e) {
    return { valid: false, error: `兼容矩阵不可用，失败关闭: ${e.message}` };
  }
  const entry = data.versions[String(version || '').replace(/^v/, '')];
  if (!entry) return { valid: true, skipped: true };
  if (!entry.integrity) return { valid: false, error: `兼容矩阵缺少 ${version} 的 integrity 记录` };
  const actual = computeIntegrity(tarball);
  if (actual !== entry.integrity) {
    return { valid: false, error: `tarball integrity 不匹配: 期望 ${entry.integrity}, 实际 ${actual}` };
  }
  return { valid: true };
}

/**
 * 解析安装/升级目标。
 * @param {{ channel?: string, pin?: string, upstream?: string, allowUnverified?: boolean }} req
 * @returns {{ ok: boolean, version?: string, channel?: string, verified?: boolean, upstream?: string, newerUpstream?: boolean, error?: string }}
 */
function resolveInstallTarget(req, data) {
  const d = data || compat();
  const pin = String(req.pin || '').trim().replace(/^v/, '');
  if (pin) {
    if (!parseStrictSemver(pin)) return { ok: false, error: `锁定版本格式非法: "${req.pin}"` };
    const verified = !!d.versions[pin];
    if (!verified && !req.allowUnverified) {
      return { ok: false, error: `锁定版本 ${pin} 未经本插件验证，需显式允许安装未验证版本` };
    }
    return { ok: true, version: pin, channel: verified ? d.versions[pin].channel : 'pinned', verified };
  }
  let channel = String(req.channel || '').trim();
  if (channel === 'stable' || channel === '') channel = d.defaultChannel;
  if (!d.channels[channel]) return { ok: false, error: `未知发布通道: "${req.channel}"` };
  const verifiedVer = d.channels[channel].verified;
  const upstream = parseStrictSemver(String(req.upstream || '')) ? String(req.upstream).replace(/^v/, '') : '';
  const newerUpstream = !!(upstream && compareSemver(parseStrictSemver(upstream), parseStrictSemver(verifiedVer)) > 0);
  if (newerUpstream && req.allowUnverified) {
    return { ok: true, version: upstream, channel, verified: !!d.versions[upstream], upstream, newerUpstream };
  }
  return { ok: true, version: verifiedVer, channel, verified: true, upstream, newerUpstream };
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
      return { valid: false, version: ver, error: `Node.js v${ver} 不满足 engines.node 契约: "${engineSpec}"` };
    }
    return { valid: true, version: ver };
  } catch (e) {
    return { valid: false, isUsageError: true, error: `无法执行 Node.js (${nodeBin}): ${e.message}` };
  }
}

/**
 * 获取经过审核的脚本列表并检查文件真实存在
 */
function getVettedScripts(pkgPath, targetVersion) {
  const res = validateManifest(pkgPath, targetVersion);
  if (!res.valid) return res;
  if (!res.vettedScripts || res.vettedScripts.length === 0) return { valid: true, scripts: [] };
  const pkgDir = path.dirname(path.resolve(pkgPath));
  for (const s of res.vettedScripts) {
    const fullPath = path.join(pkgDir, s);
    if (!fs.existsSync(fullPath)) {
      return { valid: false, error: `白名单脚本文件真实路径不存在: ${fullPath}` };
    }
  }
  return { valid: true, scripts: res.vettedScripts };
}

/**
 * 供 shell / LuCI 读取的矩阵摘要 (不含 integrity 等大字段)
 */
function channelSummary(data) {
  const d = data || compat();
  const channels = {};
  for (const name of CHANNEL_NAMES) {
    const c = d.channels[name];
    if (!c) continue;
    const v = d.versions[c.verified] || {};
    channels[name] = {
      label: c.label,
      description: c.description,
      verified: c.verified,
      engines: v.engines || '',
      deviceVerified: !!(v.verification && v.verification.device)
    };
  }
  return { defaultChannel: d.defaultChannel, node: d.node.recommended, channels };
}

/**
 * 升级到 coreVersion 时已安装的微信插件要怎么处理:
 *   ok      已满足该核心的最低要求
 *   upgrade 低于最低要求 (或版本号无法解析)，需要升级到 pin
 *   unknown 目标核心不在矩阵内，无从判断
 */
function wechatPlan(coreVersion, installedPlugin, data) {
  const d = data || compat();
  const pin = (d.wechat && d.wechat.pin) || '';
  const entry = d.versions[String(coreVersion || '').replace(/^v/, '')];
  const min = entry && entry.wechat && entry.wechat.minPlugin;
  if (!min) return { action: 'unknown', pin, min: '' };
  const cur = parseStrictSemver(installedPlugin);
  if (cur && compareSemver(cur, parseStrictSemver(min)) >= 0) return { action: 'ok', pin, min };
  return { action: 'upgrade', pin, min };
}

// ── CLI 执行入口 ──
function parseFlags(list) {
  const out = {};
  for (let i = 0; i < list.length; i++) {
    const a = list[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const next = list[i + 1];
    if (next !== undefined && !next.startsWith('--')) { out[key] = next; i++; } else { out[key] = '1'; }
  }
  return out;
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const command = args[0];

  if (command === '--help' || command === '-h') {
    console.log(`用法: node openclaw-package-contract.js <command> [args...]
命令:
  validate-manifest <package.json-path> <target-version>
  validate-integrity <tarball> <version>
  validate-node-version <version-string> [engine-spec]
  validate-runtime <node-binary-path> [engine-spec]
  get-vetted-scripts <package.json-path> <target-version>
  resolve-target [--channel <name>] [--pin <version>] [--upstream <version>] [--allow-unverified]
  channels                   输出通道与已验证版本摘要 (JSON)
  engines <version>          输出已验证版本的 engines.node (未验证时退出码 1)
  wechat-plan <version> [installed]  微信插件处理方式，输出 "<ok|upgrade|unknown> <pin> <min>"
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
    const res = validateManifest(args[1], args[2]);
    if (!res.valid) {
      console.error(`[✗] 包清单校验失败: ${res.error}`);
      process.exit(res.isUsageError ? 2 : 1);
    }
    if (res.warning) console.warn(`[!] ${res.warning}`);
    console.log(res.verified ? '[✓] 包清单契约校验通过 (已验证版本)' : '[✓] 包清单契约校验通过');
    process.exit(0);
  }

  if (command === 'validate-integrity') {
    if (args.length !== 3) {
      console.error('用法错误: validate-integrity 需要恰好 2 个参数: <tarball> <version>');
      process.exit(2);
    }
    const res = validateIntegrity(args[1], args[2]);
    if (!res.valid) {
      console.error(`[✗] ${res.error}`);
      process.exit(res.isUsageError ? 2 : 1);
    }
    console.log(res.skipped ? '[!] 未验证版本: integrity 由 npm 依据 registry 元数据校验' : '[✓] tarball integrity 与兼容矩阵一致');
    process.exit(0);
  }

  if (command === 'validate-node-version') {
    if (args.length < 2 || args.length > 3) {
      console.error('用法错误: validate-node-version 需要 1 或 2 个参数: <version-string> [engine-spec]');
      process.exit(2);
    }
    const evalRes = evaluateNodeEngines(args[1], args[2]);
    if (!evalRes.validRange) {
      console.error(`[✗] 输入格式错误: ${evalRes.error}`);
      process.exit(2);
    }
    if (!evalRes.satisfied) {
      console.error(`[✗] Node.js 版本 v${args[1]} 不满足契约: "${args[2] || DEFAULT_NODE_ENGINES}"`);
      process.exit(1);
    }
    console.log(`[✓] Node.js 版本 v${args[1]} 满足契约`);
    process.exit(0);
  }

  if (command === 'validate-runtime') {
    if (args.length < 2 || args.length > 3) {
      console.error('用法错误: validate-runtime 需要 1 或 2 个参数: <node-binary-path> [engine-spec]');
      process.exit(2);
    }
    const res = validateRuntime(args[1], args[2]);
    if (!res.valid) {
      console.error(`[✗] 运行时校验失败: ${res.error}`);
      process.exit(res.isUsageError ? 2 : 1);
    }
    console.log(`[✓] Node.js 运行时 v${res.version} 满足契约 (${args[2] || DEFAULT_NODE_ENGINES})`);
    process.exit(0);
  }

  if (command === 'get-vetted-scripts') {
    if (args.length !== 3) {
      console.error('用法错误: get-vetted-scripts 需要恰好 2 个参数: <package.json-path> <target-version>');
      process.exit(2);
    }
    const res = getVettedScripts(args[1], args[2]);
    if (!res.valid) {
      console.error(`[✗] ${res.error}`);
      process.exit(res.isUsageError ? 2 : 1);
    }
    for (const s of res.scripts || []) console.log(s);
    process.exit(0);
  }

  if (command === 'resolve-target') {
    const f = parseFlags(args.slice(1));
    let res;
    try {
      res = resolveInstallTarget({ channel: f.channel, pin: f.pin, upstream: f.upstream, allowUnverified: f['allow-unverified'] === '1' });
    } catch (e) {
      res = { ok: false, error: `兼容矩阵不可用: ${e.message}` };
    }
    if (!res.ok) {
      console.error(`[✗] ${res.error}`);
      process.exit(1);
    }
    // 机器可读: version channel verified newerUpstream upstream
    console.log([res.version, res.channel, res.verified ? 'verified' : 'unverified', res.newerUpstream ? 'newer' : 'same', res.upstream || '-'].join(' '));
    process.exit(0);
  }

  if (command === 'channels') {
    try {
      console.log(JSON.stringify(channelSummary()));
      process.exit(0);
    } catch (e) {
      console.error(`[✗] 兼容矩阵不可用: ${e.message}`);
      process.exit(1);
    }
  }

  if (command === 'engines') {
    try {
      const entry = compat().versions[String(args[1] || '').replace(/^v/, '')];
      if (!entry) process.exit(1);
      console.log(entry.engines);
      process.exit(0);
    } catch (e) {
      console.error(`[✗] 兼容矩阵不可用: ${e.message}`);
      process.exit(2);
    }
  }

  if (command === 'wechat-plan') {
    try {
      const plan = wechatPlan(args[1], args[2]);
      console.log([plan.action, plan.pin || '-', plan.min || '-'].join(' '));
      process.exit(0);
    } catch (e) {
      console.error(`[✗] 兼容矩阵不可用: ${e.message}`);
      process.exit(2);
    }
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
  CHANNEL_NAMES,
  wechatPlan,
  loadCompat,
  parseStrictSemver,
  compareSemver,
  parseComparator,
  evaluateNodeEngines,
  satisfiesNodeEngines,
  resolveTargetAlias,
  resolveInstallTarget,
  validateManifest,
  validateIntegrity,
  computeIntegrity,
  validateRuntime,
  getVettedScripts,
  channelSummary
};
