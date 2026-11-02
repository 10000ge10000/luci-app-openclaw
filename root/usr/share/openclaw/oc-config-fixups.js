#!/usr/bin/env node
/**
 * oc-config-fixups.js — 修正插件历史版本写入、但新版 OpenClaw 不再接受的配置字段。
 *
 * 用法: node oc-config-fixups.js <openclaw.json>
 *
 * 背景: OpenClaw 2026.9.35 起 config 校验对未知键报错，Gateway 遇到非法配置会拒绝启动，
 * Doctor 则会直接删除未知键。插件历史上写入过几个上游已改名或退役的字段，
 * 需要在 Doctor / Gateway 运行之前先迁移，否则要么网关起不来，要么用户的 Token 被删掉。
 *
 * 修正项 (只改动下列路径，其余内容原样保留):
 *   1. gateway.controlUi.allowInsecureAuth  上游早已退役 (2026.9.1 已列入 retired paths)，
 *      9.35+ 存在即视为非法配置 → 删除
 *   2. channels.discord.botToken  上游字段名一直是 channels.discord.token → 迁移后删除旧键
 *   3. gateway.logLevel  上游字段为 logging.level → 迁移后删除旧键
 *
 * 安全约束:
 *   - 文件不存在或为空: 不做任何事 (退出码 0)
 *   - 解析失败或根节点不是对象: 不写入 (退出码 3)，避免覆盖用户配置
 *   - 只在确有变更时写入；先写临时文件再 rename，并保持原文件权限
 *   - 输出只包含字段路径，不输出任何值 (Token 等敏感信息不会进入日志)
 */
'use strict';

const fs = require('fs');
const path = require('path');

function isObj(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

/**
 * 对配置对象执行修正，返回变更说明列表 (纯函数，便于测试)
 * @param {object} d
 * @returns {string[]}
 */
function applyFixups(d) {
  const changes = [];

  const cu = isObj(d.gateway) && isObj(d.gateway.controlUi) ? d.gateway.controlUi : null;
  if (cu && Object.prototype.hasOwnProperty.call(cu, 'allowInsecureAuth')) {
    delete cu.allowInsecureAuth;
    changes.push('removed gateway.controlUi.allowInsecureAuth (retired upstream)');
  }

  const dc = isObj(d.channels) && isObj(d.channels.discord) ? d.channels.discord : null;
  if (dc && Object.prototype.hasOwnProperty.call(dc, 'botToken')) {
    if (dc.token === undefined || dc.token === null || dc.token === '') {
      dc.token = dc.botToken;
      changes.push('moved channels.discord.botToken -> channels.discord.token');
    } else {
      changes.push('removed channels.discord.botToken (channels.discord.token already set)');
    }
    delete dc.botToken;
  }

  const gw = isObj(d.gateway) ? d.gateway : null;
  if (gw && Object.prototype.hasOwnProperty.call(gw, 'logLevel')) {
    if (!isObj(d.logging)) d.logging = {};
    if (d.logging.level === undefined && typeof gw.logLevel === 'string' && gw.logLevel) {
      d.logging.level = gw.logLevel;
      changes.push('moved gateway.logLevel -> logging.level');
    } else {
      changes.push('removed gateway.logLevel (logging.level already set)');
    }
    delete gw.logLevel;
  }

  return changes;
}

function run(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (e) {
    if (e.code === 'ENOENT') return 0;
    console.error(`oc-config-fixups: 无法读取 ${file}: ${e.message}`);
    return 3;
  }
  if (raw.trim() === '') return 0;

  let d;
  try {
    d = JSON.parse(raw);
  } catch (e) {
    console.error(`oc-config-fixups: 配置文件解析失败，已跳过修正以避免覆盖: ${e.message}`);
    return 3;
  }
  if (!isObj(d)) {
    console.error('oc-config-fixups: 配置根节点不是对象，已跳过修正');
    return 3;
  }

  const changes = applyFixups(d);
  if (changes.length === 0) return 0;

  let mode = 0o600;
  try { mode = fs.statSync(file).mode & 0o777; } catch {}
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.fixups-${process.pid}`);
  try {
    fs.writeFileSync(tmp, JSON.stringify(d, null, 2), { mode });
    fs.renameSync(tmp, file);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch {}
    console.error(`oc-config-fixups: 写入失败，原配置保持不变: ${e.message}`);
    return 1;
  }
  for (const c of changes) console.log(`oc-config-fixups: ${c}`);
  return 0;
}

if (require.main === module) {
  const file = process.argv[2];
  if (!file || process.argv.length !== 3) {
    console.error('用法: node oc-config-fixups.js <openclaw.json>');
    process.exit(2);
  }
  process.exit(run(file));
}

module.exports = { applyFixups, run };
