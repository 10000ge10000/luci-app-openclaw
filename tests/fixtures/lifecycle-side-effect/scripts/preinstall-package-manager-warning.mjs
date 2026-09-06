import fs from 'fs';
import path from 'path';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);

// 1. 验证受控环境 (npm_config_ignore_scripts=true)
if (process.env.npm_config_ignore_scripts !== 'true') {
  console.error('[preinstall] 错误: npm_config_ignore_scripts 必须为 "true", 实际为: ' + process.env.npm_config_ignore_scripts);
  process.exit(98);
}

// 2. 验证 cwd 为安装包根目录 (必须包含 package.json)
const rawCwd = process.cwd();
const cwd = rawCwd.replace(/\\/g, '/');
const localPkgPath = path.resolve(rawCwd, 'package.json');
if (!fs.existsSync(localPkgPath)) {
  console.error('[preinstall] 错误: cwd 必须为安装包根目录，当前未找到 package.json: ' + cwd);
  process.exit(97);
}

// 3. 验证依赖可解析 (通过 Node require.resolve 机制确认当前上下文或依赖树有效)
// 可通过环境变量 OC_TEST_DEP 指定必须可解析的依赖；未指定时解析 package.json 自身以验证解析上下文就绪
try {
  const depToResolve = process.env.OC_TEST_DEP || './package.json';
  require.resolve(depToResolve, { paths: [cwd] });
} catch (err) {
  console.error('[preinstall] 依赖解析失败: ' + err.message);
  process.exit(96);
}

// 4. 写入可计数副作用 (文件追加写入)
const sideEffectFile = process.env.OC_SIDE_EFFECT_FILE;
if (sideEffectFile) {
  const record = JSON.stringify({
    script: 'preinstall',
    cwd: cwd,
    npm_config_ignore_scripts: process.env.npm_config_ignore_scripts,
    timestamp: Date.now()
  }) + '\n';
  fs.appendFileSync(sideEffectFile, record, 'utf8');
}

// 5. 失败注入支持 (用于验证失败时回滚并保持现有安装不变)
if (process.env.OC_FAIL_PREINSTALL === '1') {
  console.error('[preinstall] 模拟 preinstall 失败 (OC_FAIL_PREINSTALL=1)');
  process.exit(42);
}

process.exit(0);
