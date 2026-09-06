#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ENV_SCRIPT="$REPO_ROOT/root/usr/bin/openclaw-env"

. "$REPO_ROOT/root/usr/libexec/openclaw-node.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

# 1. 基础版本归一化与版本比较契约
[ "$(oc_normalize_node_version v22.23.2)" = "22.23.2" ] || fail "normalize v"
oc_node_version_ge 22.22.3 22.22.3 || fail "exact version"
oc_node_version_ge 22.22.4 22.22.3 || fail "patch version"
oc_node_version_ge 22.23.2 22.22.3 || fail "supported LTS version"
if oc_node_version_ge 22.22.2 22.22.3; then
	fail "older patch accepted"
fi
if oc_node_version_ge 22.19.0 22.22.3; then
	fail "older minor accepted"
fi

# 2. 隔离 Mock 环境: 验证全部候选镜像源失败时的失败闭合行为
TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'oc-node-test-XXXXXX' 2>/dev/null || echo "/tmp/oc-node-test-$$")
mkdir -p "$TMP_DIR"
cleanup() {
	rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"

CURL_LOG="$TMP_DIR/curl.log"
cat > "$MOCK_BIN/curl" <<EOF
#!/bin/sh
echo "\$@" >> "$CURL_LOG"
exit 22
EOF
chmod +x "$MOCK_BIN/curl"

WGET_LOG="$TMP_DIR/wget.log"
cat > "$MOCK_BIN/wget" <<EOF
#!/bin/sh
echo "\$@" >> "$WGET_LOG"
exit 1
EOF
chmod +x "$MOCK_BIN/wget"

cat > "$MOCK_BIN/id" <<EOF
#!/bin/sh
exit 0
EOF
chmod +x "$MOCK_BIN/id"

NPM_LOG="$TMP_DIR/npm.log"
cat > "$MOCK_BIN/npm" <<EOF
#!/bin/sh
echo "\$@" >> "$NPM_LOG"
exit 0
EOF
chmod +x "$MOCK_BIN/npm"

MOCK_ROOT="$TMP_DIR/opt"
MOCK_OC="$MOCK_ROOT/openclaw"
MOCK_GLOBAL="$MOCK_OC/global"
MOCK_NODE="$MOCK_OC/node"
mkdir -p "$MOCK_GLOBAL/bin" "$MOCK_GLOBAL/lib/node_modules/openclaw" "$MOCK_NODE/bin"

echo "EXISTING_MARKER_GLOBAL" > "$MOCK_GLOBAL/marker.txt"
echo "EXISTING_WRAPPER" > "$MOCK_GLOBAL/bin/openclaw"
chmod +x "$MOCK_GLOBAL/bin/openclaw"
echo "EXISTING_ENTRY" > "$MOCK_GLOBAL/lib/node_modules/openclaw/openclaw.mjs"
echo '{"name":"openclaw","version":"2026.9.1"}' > "$MOCK_GLOBAL/lib/node_modules/openclaw/package.json"

# (2.1) 提取 download_node 逻辑并在隔离环境直接调用: 候选镜像全部失败必须退出非零
HARNESS_DOWNLOADER="$TMP_DIR/test-download.sh"
cat > "$HARNESS_DOWNLOADER" <<EOF
#!/bin/sh
set -e
export PATH="$MOCK_BIN:\$PATH"
OC_BASE_PATH="$MOCK_ROOT"
OC_INSTALL_PATH="$MOCK_OC"
NODE_BASE="$MOCK_NODE"
NODE_BIN="\$NODE_BASE/bin/node"
OC_GLOBAL="$MOCK_GLOBAL"
OC_DATA="$MOCK_OC/data"
OC_PACKAGE_CONTRACT="$REPO_ROOT/root/usr/share/openclaw/openclaw-package-contract.js"
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

set +e
sh "$HARNESS_DOWNLOADER" >/dev/null 2>&1
RC_EXHAUSTED=$?
set -e
[ "$RC_EXHAUSTED" -ne 0 ] || fail "downloader must fail when all candidate mirrors fail"

# (2.2) 验证仅有 wget 可用且全部候选失败时同样必须退出非零
MOCK_BIN_WGET="$TMP_DIR/bin-wget"
mkdir -p "$MOCK_BIN_WGET"
cp "$MOCK_BIN/wget" "$MOCK_BIN_WGET/wget"
HARNESS_WGET="$TMP_DIR/test-download-wget.sh"
cat > "$HARNESS_WGET" <<EOF
#!/bin/sh
set -e
export PATH="$MOCK_BIN_WGET:\$PATH"
OC_BASE_PATH="$MOCK_ROOT"
OC_INSTALL_PATH="$MOCK_OC"
NODE_BASE="$MOCK_NODE"
NODE_BIN="\$NODE_BASE/bin/node"
OC_GLOBAL="$MOCK_GLOBAL"
OC_DATA="$MOCK_OC/data"
OC_PACKAGE_CONTRACT="$REPO_ROOT/root/usr/share/openclaw/openclaw-package-contract.js"
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
awk '/^oc_sum256\(\)/,/^download_node\(\)/' "$ENV_SCRIPT" | sed '$d' >> "$HARNESS_WGET"
awk '/^download_node\(\)/,/^install_pnpm\(\)/' "$ENV_SCRIPT" | sed '$d' >> "$HARNESS_WGET"
cat >> "$HARNESS_WGET" <<EOF
download_node "22.23.2"
EOF

set +e
sh "$HARNESS_WGET" >/dev/null 2>&1
RC_WGET_EXHAUSTED=$?
set -e
[ "$RC_WGET_EXHAUSTED" -ne 0 ] || fail "downloader must fail when all candidate mirrors fail (wget only)"

# (2.3) 验证 openclaw-env setup 调用链：Node 下载失败立即退出，不产生伪成功，且 OC_GLOBAL 零副作用
set +e
PATH="$MOCK_BIN:$PATH" \
OC_INSTALL_PATH="$MOCK_ROOT" \
NODE_VERSION="22.23.2" \
sh "$ENV_SCRIPT" setup >/dev/null 2>&1
RC_SETUP=$?
set -e
[ "$RC_SETUP" -ne 0 ] || fail "openclaw-env setup must fail non-zero when candidate mirrors fail"

# 检查后续安装未发生且原有安装保持完整
[ ! -f "$NPM_LOG" ] || fail "npm install/pack was called after node download failure"
[ -f "$MOCK_GLOBAL/marker.txt" ] || fail "existing OC_GLOBAL marker was deleted on download failure"
[ "$(cat "$MOCK_GLOBAL/marker.txt")" = "EXISTING_MARKER_GLOBAL" ] || fail "existing OC_GLOBAL marker corrupted"
[ -f "$MOCK_GLOBAL/bin/openclaw" ] || fail "existing OC_GLOBAL wrapper was lost"
[ "$(cat "$MOCK_GLOBAL/bin/openclaw")" = "EXISTING_WRAPPER" ] || fail "existing OC_GLOBAL wrapper corrupted"
[ -f "$MOCK_GLOBAL/lib/node_modules/openclaw/openclaw.mjs" ] || fail "existing OC_GLOBAL entry was lost"

# (2.4) 验证 openclaw-env node 调用链：旧 Node 版本需要升级但镜像全挂时必须退出非零且保留旧安装
cat > "$MOCK_NODE/bin/node" <<'EOF'
#!/bin/sh
case "$1" in
	--version|-v) echo "v22.15.1" ;;
	*) exit 0 ;;
esac
EOF
chmod +x "$MOCK_NODE/bin/node"
echo "EXISTING_NODE_MARKER" > "$MOCK_NODE/marker.txt"

set +e
PATH="$MOCK_BIN:$PATH" \
OC_INSTALL_PATH="$MOCK_ROOT" \
NODE_VERSION="22.23.2" \
sh "$ENV_SCRIPT" node >/dev/null 2>&1
RC_NODE=$?
set -e
[ "$RC_NODE" -ne 0 ] || fail "openclaw-env node must fail non-zero when candidate mirrors fail"

# 检查旧 node 标记及旧 OC_GLOBAL 均未被破坏
[ -f "$MOCK_NODE/marker.txt" ] || fail "existing NODE_BASE marker was lost on node download failure"
[ -f "$MOCK_GLOBAL/marker.txt" ] || fail "existing OC_GLOBAL marker was deleted on node download failure"
[ "$(cat "$MOCK_GLOBAL/marker.txt")" = "EXISTING_MARKER_GLOBAL" ] || fail "existing OC_GLOBAL was modified on node download failure"

echo "ok"
