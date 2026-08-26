#!/bin/sh
# 配置写入安全契约。
#
# 背景: 旧实现的 readConfig() 在 JSON.parse 失败时返回 {}，调用方随后
# writeConfig() 会把这个空对象写回磁盘，导致整份配置 (含 models.providers
# 里的 apiKey) 被静默清空。且 writeConfig() 直接覆盖目标文件，无备份、
# 非原子写，中断会留下截断的 JSON。
#
# 本测试用真实 Node 加载 oc-config-interactive.js 的实现，验证:
#   1. 配置损坏时写入被拒绝，原文件字节不变 (fail closed)
#   2. 正常写入是原子的，且留有写前备份
#   3. 备份后缀不占用 OpenClaw 自己的 .bak 轮转链
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TARGET="$REPO_ROOT/root/usr/share/openclaw/oc-config-interactive.js"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

[ -f "$TARGET" ] || fail "missing $TARGET"

# ── 静态契约: 关键防护不能被回退 ──
grep -Fq 'class ConfigParseError' "$TARGET" || fail "must define ConfigParseError to distinguish corrupt config from missing config"
grep -Fq 'renameSync' "$TARGET" || fail "writeConfig must replace the config atomically via rename"
grep -Fq 'CONFIG_BACKUP_SUFFIX' "$TARGET" || fail "writeConfig must keep a pre-write backup"
grep -Fq "'.luci-pre-write'" "$TARGET" || fail "pre-write backup must not reuse OpenClaw's own .bak rotation names"
grep -Fq 'readConfigForDisplay' "$TARGET" || fail "read-only paths need a non-throwing accessor"

# readConfig() 不得在解析失败时返回 {}
awk '/^function readConfig\(\)/,/^}/' "$TARGET" | grep -Fq 'throw new ConfigParseError' \
	|| fail "readConfig must throw on unparsable config instead of returning {}"

# ── 行为契约: 需要 node 才能执行 ──
NODE_BIN=""
for cand in node nodejs /opt/openclaw/node/bin/node; do
	if command -v "$cand" >/dev/null 2>&1; then NODE_BIN=$(command -v "$cand"); break; fi
	[ -x "$cand" ] && { NODE_BIN="$cand"; break; }
done

if [ -z "$NODE_BIN" ]; then
	echo "ok (static only: no node interpreter available)"
	exit 0
fi

TMPDIR_T=$(mktemp -d 2>/dev/null || echo "/tmp/oc-write-safety-$$")
mkdir -p "$TMPDIR_T"
cleanup() { rm -rf "$TMPDIR_T"; }
trap cleanup EXIT

# 把 readConfig/writeConfig 从目标文件中抽出来单独求值:
# 直接 require 整个脚本会启动交互菜单，因此这里只提取所需函数体。
HARNESS="$TMPDIR_T/harness.js"
cat > "$HARNESS" <<'HARNESS_EOF'
const fs = require('fs');
const path = require('path');
const target = process.argv[2];
const configFile = process.argv[3];
const src = fs.readFileSync(target, 'utf8');

// 抽取被测函数 (含依赖的错误类与常量)，避免执行脚本的交互入口
function extract(startMarker, endMarker) {
  const s = src.indexOf(startMarker);
  if (s < 0) throw new Error(`marker not found: ${startMarker}`);
  const e = src.indexOf(endMarker, s);
  if (e < 0) throw new Error(`end marker not found: ${endMarker}`);
  return src.slice(s, e);
}

const body = [
  extract('class ConfigParseError', 'function configRecoveryHint'),
  extract('function readConfig()', 'function readConfigForDisplay'),
  extract('function readConfigForDisplay()', '/**\n * 写入 JSON 配置文件'),
  extract('function writeConfig(config)', '/**\n * 注册模型'),
].join('\n');

const CONFIG_BACKUP_SUFFIX = '.luci-pre-write';
const C = new Proxy({}, { get: () => '' });
const execSync = () => {};
const fixStatePermissions = () => {};
const CONFIG_FILE = configFile;

const factory = new Function(
  'fs', 'path', 'CONFIG_FILE', 'CONFIG_BACKUP_SUFFIX', 'C', 'execSync', 'fixStatePermissions',
  `${body}\nreturn { readConfig, readConfigForDisplay, writeConfig, ConfigParseError };`
);
const api = factory(fs, path, CONFIG_FILE, CONFIG_BACKUP_SUFFIX, C, execSync, fixStatePermissions);

const results = [];
function check(name, fn) {
  try { fn(); results.push(`PASS ${name}`); }
  catch (e) { results.push(`FAIL ${name}: ${e.message}`); }
}
function assert(cond, msg) { if (!cond) throw new Error(msg); }

// 场景 1: 轻微损坏的配置 (尾随逗号, OpenClaw 自身的 JSON5 解析器可容忍)
// 用户只想改一个端口 -> 必须中止, 原文件一字节都不能变
check('corrupt config is not overwritten', () => {
  const corrupt = '{\n "gateway": { "port": 18789 },\n "models": { "providers": { "p": { "apiKey": "SECRET" } } },\n';
  fs.writeFileSync(CONFIG_FILE, corrupt);
  const before = fs.readFileSync(CONFIG_FILE);
  let threw = null;
  try {
    // 精确复刻 jsonSet 的写入路径: 它会自动创建缺失的中间对象，
    // 因此不会因为键不存在而抛 TypeError —— 唯一能阻止数据丢失的
    // 就是 readConfig() 自己抛错。用真实路径才能守住真实的回归。
    const cfg = api.readConfig();
    const keys = ['gateway', 'port'];
    let obj = cfg;
    for (let i = 0; i < keys.length - 1; i++) {
      if (!obj[keys[i]]) obj[keys[i]] = {};
      obj = obj[keys[i]];
    }
    obj[keys[keys.length - 1]] = 18790;
    api.writeConfig(cfg);
  } catch (e) { threw = e; }
  // 最关键的性质放在最前面: 配置不能丢
  const after = fs.readFileSync(CONFIG_FILE);
  assert(after.includes('SECRET'), 'apiKey was lost: corrupt config got overwritten');
  assert(before.equals(after), 'corrupt config file was modified');
  assert(threw !== null, 'readConfig should have thrown on corrupt config');
  assert(threw instanceof api.ConfigParseError, `expected ConfigParseError, got ${threw && threw.name}`);
});

// 场景 2: 数组/标量根节点也必须拒绝
check('non-object root is rejected', () => {
  fs.writeFileSync(CONFIG_FILE, '[1,2,3]');
  let threw = false;
  try { api.readConfig(); } catch (e) { threw = e instanceof api.ConfigParseError; }
  assert(threw, 'array root should be rejected');
});

// 场景 3: 文件不存在 / 空文件属正常首装情况 -> 返回 {}
check('missing and empty config are treated as empty', () => {
  fs.rmSync(CONFIG_FILE, { force: true });
  assert(JSON.stringify(api.readConfig()) === '{}', 'missing file should yield {}');
  fs.writeFileSync(CONFIG_FILE, '   \n');
  assert(JSON.stringify(api.readConfig()) === '{}', 'empty file should yield {}');
});

// 场景 4: 正常写入保留其他字段, 且留下写前备份
check('normal write preserves siblings and leaves a backup', () => {
  const good = { gateway: { port: 18789 }, models: { providers: { p: { apiKey: 'KEEPME' } } } };
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(good, null, 2));
  const cfg = api.readConfig();
  cfg.gateway.port = 18790;
  api.writeConfig(cfg);
  const out = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
  assert(out.gateway.port === 18790, 'port not updated');
  assert(out.models.providers.p.apiKey === 'KEEPME', 'sibling config lost on normal write');
  assert(fs.existsSync(CONFIG_FILE + CONFIG_BACKUP_SUFFIX), 'pre-write backup missing');
  const bak = JSON.parse(fs.readFileSync(CONFIG_FILE + CONFIG_BACKUP_SUFFIX, 'utf8'));
  assert(bak.gateway.port === 18789, 'backup should hold the pre-write value');
});

// 场景 5: 写入不留临时文件残留
check('no temp file residue after write', () => {
  const leftovers = fs.readdirSync(path.dirname(CONFIG_FILE))
    .filter((f) => f.includes('.tmp-'));
  assert(leftovers.length === 0, `temp files left behind: ${leftovers.join(',')}`);
});

// 场景 6: 拒绝写入非对象
check('writeConfig rejects non-object payloads', () => {
  let threw = false;
  try { api.writeConfig(null); } catch { threw = true; }
  assert(threw, 'null payload should be rejected');
});

console.log(results.join('\n'));
if (results.some((r) => r.startsWith('FAIL'))) process.exit(1);
HARNESS_EOF

OUT=$("$NODE_BIN" "$HARNESS" "$TARGET" "$TMPDIR_T/openclaw.json" 2>&1) || {
	echo "$OUT" | sed 's/^/  /' >&2
	fail "config write safety behavior checks failed"
}

echo "$OUT" | grep -q '^FAIL' && { echo "$OUT" | sed 's/^/  /' >&2; fail "config write safety behavior checks failed"; }

echo "ok"
