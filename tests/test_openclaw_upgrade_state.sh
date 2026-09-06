#!/bin/sh
# ============================================================================
# test_openclaw_upgrade_state.sh
# 验证 openclaw-upgrade-state.sh 事务生命周期、SQLite 前向预检、回滚安全及
# oc-config / openclaw-env 在升级期间的状态防写穿契约。
# ============================================================================
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
STATE_SCRIPT="$REPO_ROOT/root/usr/libexec/openclaw-upgrade-state.sh"
OC_CONFIG_SCRIPT="$REPO_ROOT/root/usr/share/openclaw/oc-config.sh"
ENV_SCRIPT="$REPO_ROOT/root/usr/bin/openclaw-env"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -f "$STATE_SCRIPT" ] || fail "state helper script not found: $STATE_SCRIPT"

TMP_DIR=$(mktemp -d /tmp/oc-state-test-XXXXXX 2>/dev/null || mktemp -d 2>/dev/null || echo "/tmp/oc-state-test-$$")
chmod 755 "$TMP_DIR" 2>/dev/null || true
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# ── 1. 脚本调用与 Source 契约 ──
# 1.1 验证 source openclaw-upgrade-state.sh 不会意外 exit (之前因未定义 OPENCLAW_PERMISSIONS_SOURCED 导致 fatal exit 2)
(
	export OPENCLAW_STATE_DIR="$TMP_DIR/mock-state"
	# shellcheck source=/dev/null
	. "$STATE_SCRIPT"
) || fail "sourcing $STATE_SCRIPT should not exit non-zero"

# 1.2 验证未知参数退出码为 2
set +e
sh "$STATE_SCRIPT" invalid-subcommand >/dev/null 2>&1
RC_INVALID=$?
set -e
[ "$RC_INVALID" -eq 2 ] || fail "invalid subcommand must exit with code 2 (actual: $RC_INVALID)"

# ── 2. status 子命令返回合法 JSON ──
STATUS_JSON=$(sh "$STATE_SCRIPT" status "$TMP_DIR/mock-state" 2>/dev/null) || fail "status command failed"
echo "$STATUS_JSON" | grep -q '"phase"' || fail "status JSON missing phase"
echo "$STATUS_JSON" | grep -q '"backup_verified"' || fail "status JSON missing backup_verified"
echo "$STATUS_JSON" | grep -q '"migration_started"' || fail "status JSON missing migration_started"
echo "$STATUS_JSON" | grep -q '"rollback_mode"' || fail "status JSON missing rollback_mode"
echo "$STATUS_JSON" | grep -q '"error_code"' || fail "status JSON missing error_code"

# ── 3. init-transaction 与 set-phase 事务状态流转 ──
MOCK_ROOT="$TMP_DIR/inst"
MOCK_STATE="$MOCK_ROOT/data/.openclaw"
mkdir -p "$MOCK_STATE"

# 3.1 init-transaction
sh "$STATE_SCRIPT" init-transaction "2026.9.1" "$MOCK_STATE" >/dev/null 2>&1 || fail "init-transaction failed"
STATUS_FILE="$MOCK_ROOT/.luci-openclaw-upgrade/status.json"
[ -f "$STATUS_FILE" ] || fail "status.json not created at expected meta location: $STATUS_FILE"
grep -q '"phase"[[:space:]]*:[[:space:]]*"init"' "$STATUS_FILE" || fail "phase must be init"
grep -q '"target_version"[[:space:]]*:[[:space:]]*"2026.9.1"' "$STATUS_FILE" || fail "target_version must be 2026.9.1"
grep -q '"backup_verified"[[:space:]]*:[[:space:]]*false' "$STATUS_FILE" || fail "backup_verified must be false initially"

# 3.2 set-phase backing_up
sh "$STATE_SCRIPT" set-phase backing_up "$MOCK_STATE" 0 "" "" >/dev/null 2>&1 || fail "set-phase backing_up failed"
grep -q '"phase"[[:space:]]*:[[:space:]]*"backing_up"' "$STATUS_FILE" || fail "phase must be backing_up"

# 3.3 set-phase backup_verified
sh "$STATE_SCRIPT" set-phase backup_verified "$MOCK_STATE" 0 "" "$MOCK_ROOT/backup.tar.gz" >/dev/null 2>&1 || fail "set-phase backup_verified failed"
grep -q '"phase"[[:space:]]*:[[:space:]]*"backup_verified"' "$STATUS_FILE" || fail "phase must be backup_verified"
grep -q '"backup_verified"[[:space:]]*:[[:space:]]*true' "$STATUS_FILE" || fail "backup_verified must be true"
grep -q '"backup_file"[[:space:]]*:[[:space:]]*".*backup.tar.gz"' "$STATUS_FILE" || fail "backup_file must be recorded"

# 3.4 set-phase migrating
sh "$STATE_SCRIPT" set-phase migrating "$MOCK_STATE" 0 "" "$MOCK_ROOT/backup.tar.gz" >/dev/null 2>&1 || fail "set-phase migrating failed"
grep -q '"phase"[[:space:]]*:[[:space:]]*"migrating"' "$STATUS_FILE" || fail "phase must be migrating"
grep -q '"migration_started"[[:space:]]*:[[:space:]]*true' "$STATUS_FILE" || fail "migration_started must be true"

# 3.5 set-phase recovery
sh "$STATE_SCRIPT" set-phase recovery "$MOCK_STATE" 42 "Migration failed" "$MOCK_ROOT/backup.tar.gz" >/dev/null 2>&1 || fail "set-phase recovery failed"
grep -q '"phase"[[:space:]]*:[[:space:]]*"recovery"' "$STATUS_FILE" || fail "phase must be recovery"
grep -q '"rollback_mode"[[:space:]]*:[[:space:]]*"manual_recovery"' "$STATUS_FILE" || fail "rollback_mode must be manual_recovery"
grep -q '"error_code"[[:space:]]*:[[:space:]]*42' "$STATUS_FILE" || fail "error_code 42 must be recorded"

# 3.6 set-phase rolled_back
sh "$STATE_SCRIPT" set-phase rolled_back "$MOCK_STATE" 0 "" "$MOCK_ROOT/backup.tar.gz" >/dev/null 2>&1 || fail "set-phase rolled_back failed"
grep -q '"phase"[[:space:]]*:[[:space:]]*"rolled_back"' "$STATUS_FILE" || fail "phase must be rolled_back"
grep -q '"rollback_mode"[[:space:]]*:[[:space:]]*"rolled_back"' "$STATUS_FILE" || fail "rollback_mode must be rolled_back"

# 3.7 set-phase completed 时显式清空旧的 error_message 与 error_code
sh "$STATE_SCRIPT" set-phase recovery "$MOCK_STATE" 99 "Prior error occurred" "$MOCK_ROOT/backup.tar.gz" >/dev/null 2>&1 || fail "set-phase recovery failed"
grep -q '"error_message"[[:space:]]*:[[:space:]]*"Prior error occurred"' "$STATUS_FILE" || fail "error_message must be recorded"
sh "$STATE_SCRIPT" set-phase completed "$MOCK_STATE" 0 "" "$MOCK_ROOT/backup.tar.gz" >/dev/null 2>&1 || fail "set-phase completed failed"
grep -q '"phase"[[:space:]]*:[[:space:]]*"completed"' "$STATUS_FILE" || fail "phase must be completed"
grep -q '"error_code"[[:space:]]*:[[:space:]]*0' "$STATUS_FILE" || fail "error_code must be reset to 0 on completed"
grep -q '"error_message"[[:space:]]*:[[:space:]]*""' "$STATUS_FILE" || fail "error_message must be cleared on completed"

# ── 4. 纯 Shell 降级状态写入 (Node.js 缺失时) ──
(
	PATH="/usr/bin:/bin"
	STATUS_FILE_FALLBACK="$TMP_DIR/fallback-meta/.luci-openclaw-upgrade/status.json"
	mkdir -p "$TMP_DIR/fallback-meta/data/.openclaw"
	# 屏蔽 node
	sh -c "
		export PATH=\"/nonexistent:\$PATH\"
		sh \"$STATE_SCRIPT\" set-phase migrating \"$TMP_DIR/fallback-meta/data/.openclaw\" 0 \"\" \"\" >/dev/null 2>&1
	"
	[ -f "$STATUS_FILE_FALLBACK" ] || fail "fallback status file not created"
	grep -q '"phase"[[:space:]]*:[[:space:]]*"migrating"' "$STATUS_FILE_FALLBACK" || fail "fallback must write phase"
	grep -q '"migration_started"[[:space:]]*:[[:space:]]*true' "$STATUS_FILE_FALLBACK" || fail "fallback must write migration_started: true"

	# 验证降级路径在 completed 时同样清空 error_message 并保持已记录的 target_version
	sh -c "
		export PATH=\"/nonexistent:\$PATH\"
		sh \"$STATE_SCRIPT\" init-transaction \"2026.9.1\" \"$TMP_DIR/fallback-meta/data/.openclaw\" >/dev/null 2>&1
		sh \"$STATE_SCRIPT\" set-phase recovery \"$TMP_DIR/fallback-meta/data/.openclaw\" 55 \"Shell fallback error\" \"\" >/dev/null 2>&1
		sh \"$STATE_SCRIPT\" set-phase completed \"$TMP_DIR/fallback-meta/data/.openclaw\" 0 \"\" \"\" >/dev/null 2>&1
	"
	grep -q '"phase"[[:space:]]*:[[:space:]]*"completed"' "$STATUS_FILE_FALLBACK" || fail "fallback must write phase completed"
	grep -q '"target_version"[[:space:]]*:[[:space:]]*"2026.9.1"' "$STATUS_FILE_FALLBACK" || fail "fallback must preserve target_version"
	grep -q '"error_code"[[:space:]]*:[[:space:]]*0' "$STATUS_FILE_FALLBACK" || fail "fallback error_code must be 0 on completed"
	grep -q '"error_message"[[:space:]]*:[[:space:]]*""' "$STATUS_FILE_FALLBACK" || fail "fallback error_message must be empty on completed"
)

# ── 5. database-preflight 数据库前向预检 ──
# 5.1 合法 SQLite 文件 (>=16 字节且含 'SQLite format 3\0')
VALID_DB_DIR="$TMP_DIR/valid-db"
mkdir -p "$VALID_DB_DIR"
# 生成 100 字节标准 SQLite3 文件头
printf 'SQLite format 3\000\004\000\001\001\000@  \000\000\000\001\000\000\000\000' > "$VALID_DB_DIR/agents.db"
# 附加合法 helper 文件 (0 字节 wal / shm 不应报损坏)
touch "$VALID_DB_DIR/agents.db-wal"
touch "$VALID_DB_DIR/agents.db-shm"

sh "$STATE_SCRIPT" database-preflight "$VALID_DB_DIR" >/dev/null 2>&1 || fail "database-preflight should pass on valid SQLite"

# 5.2 损坏 SQLite 文件: 长度 < 16 字节
CORRUPT_DB_DIR="$TMP_DIR/corrupt-db"
mkdir -p "$CORRUPT_DB_DIR"
printf 'bad' > "$CORRUPT_DB_DIR/corrupt.sqlite"
set +e
sh "$STATE_SCRIPT" database-preflight "$CORRUPT_DB_DIR" >/dev/null 2>&1
RC_CORRUPT_SIZE=$?
set -e
[ "$RC_CORRUPT_SIZE" -ne 0 ] || fail "database-preflight must fail on truncated SQLite file"

# 5.3 损坏 SQLite 文件: 长度 >= 16 字节但 Header 错误
printf 'NOT_SQLITE_HEADER_1234567890' > "$CORRUPT_DB_DIR/badheader.sqlite"
set +e
sh "$STATE_SCRIPT" database-preflight "$CORRUPT_DB_DIR" >/dev/null 2>&1
RC_CORRUPT_HEADER=$?
set -e
[ "$RC_CORRUPT_HEADER" -ne 0 ] || fail "database-preflight must fail on invalid SQLite header"

# 5.4 tar.gz 归档输入预检
ARCHIVE_VALID="$TMP_DIR/valid-archive.tar.gz"
tar -czf "$ARCHIVE_VALID" -C "$VALID_DB_DIR" agents.db agents.db-wal
sh "$STATE_SCRIPT" database-preflight "$ARCHIVE_VALID" >/dev/null 2>&1 || fail "database-preflight should pass on tar.gz containing valid SQLite"

ARCHIVE_CORRUPT="$TMP_DIR/corrupt-archive.tar.gz"
tar -czf "$ARCHIVE_CORRUPT" -C "$CORRUPT_DB_DIR" badheader.sqlite
set +e
sh "$STATE_SCRIPT" database-preflight "$ARCHIVE_CORRUPT" >/dev/null 2>&1
RC_ARCHIVE_CORRUPT=$?
set -e
[ "$RC_ARCHIVE_CORRUPT" -ne 0 ] || fail "database-preflight must fail on tar.gz containing corrupt SQLite"

# ── 6. rollback-explicit 边界与破坏性防范 ──
# 6.1 备份文件缺失时，拒绝执行回滚，保持状态为 recovery
set +e
sh "$STATE_SCRIPT" rollback-explicit "$TMP_DIR/nonexistent.tar.gz" "$MOCK_STATE" >/dev/null 2>&1
RC_RB_NONEXIST=$?
set -e
[ "$RC_RB_NONEXIST" -ne 0 ] || fail "rollback-explicit must fail if backup archive does not exist"

# 6.2 备份文件损坏（如缺少 openclaw.json），拒绝执行回滚，保持服务不被杀
CORRUPT_BK="$TMP_DIR/broken-backup.tar.gz"
tar -czf "$CORRUPT_BK" -C "$VALID_DB_DIR" agents.db
set +e
sh "$STATE_SCRIPT" rollback-explicit "$CORRUPT_BK" "$MOCK_STATE" >/dev/null 2>&1
RC_RB_CORRUPT=$?
set -e
[ "$RC_RB_CORRUPT" -ne 0 ] || fail "rollback-explicit must abort when backup archive verification fails"
grep -q '"phase"[[:space:]]*:[[:space:]]*"recovery"' "$STATUS_FILE" || fail "phase must remain recovery when rollback aborted"

# ── 7. oc-config.sh json_set 升级事务防写穿契约 ──
OC_CFG_DIR="$TMP_DIR/cfg-test"
mkdir -p "$OC_CFG_DIR/data/.openclaw"
mkdir -p "$OC_CFG_DIR/.luci-openclaw-upgrade"
CFG_FILE="$OC_CFG_DIR/data/.openclaw/openclaw.json"
echo '{"gateway":{"port":18789}}' > "$CFG_FILE"

# 7.1 当 phase 为 migrating 时，json_set 暂停写入 openclaw.json
cat > "$OC_CFG_DIR/.luci-openclaw-upgrade/status.json" <<'EOF'
{
  "phase": "migrating",
  "target_version": "2026.9.1"
}
EOF

OPENCLAW_STATE_DIR="$OC_CFG_DIR/data/.openclaw" \
CONFIG_FILE="$CFG_FILE" \
OC_DATA="$OC_CFG_DIR/data" \
sh "$OC_CONFIG_SCRIPT" --set "gateway.port" "28888" >/dev/null 2>&1 || true

# 验证 openclaw.json 未被篡改 (端口仍为 18789)
grep -q '18789' "$CFG_FILE" || fail "json_set must NOT mutate openclaw.json when phase is migrating"
! grep -q '28888' "$CFG_FILE" || fail "json_set unexpectedly updated openclaw.json during migrating phase"

# 7.2 当 phase 为 idle 时，json_set 正常写入
cat > "$OC_CFG_DIR/.luci-openclaw-upgrade/status.json" <<'EOF'
{
  "phase": "idle"
}
EOF

OPENCLAW_STATE_DIR="$OC_CFG_DIR/data/.openclaw" \
CONFIG_FILE="$CFG_FILE" \
OC_DATA="$OC_CFG_DIR/data" \
sh "$OC_CONFIG_SCRIPT" --set "gateway.port" "28888" || true
grep -q '28888' "$CFG_FILE" || fail "json_set must succeed when phase is idle"

# ── 8. Node.js musl ARM64 下载镜像源优先级契约 ──
# 验证 openclaw-env download_node 为 aarch64 musl 构建的镜像列表优先使用 unofficial-builds
ARM64_HARNESS="$TMP_DIR/harness-arm64.sh"
cat > "$ARM64_HARNESS" <<'EOF'
#!/bin/sh
set -e
test_mirrors() {
	local libc_type="musl"
	local node_ver="22.23.2"
	local node_arch="linux-arm64"
	local musl_tarball="node-v${node_ver}-${node_arch}-musl.tar.xz"
	local NODE_MUSL_MIRROR="https://unofficial-builds.nodejs.org/download/release"
	local NODE_MIRROR_CN="https://npmmirror.com/mirrors/node"
	local NODE_SELF_HOST="https://github.com/10000ge10000/luci-app-openclaw/releases/download/node-bins"
	local mirror_list=""
EOF

awk '/if \[ "\$libc_type" = "musl" \]; then/,/local downloaded=0/ { if (/local downloaded=0/) exit; print }' "$ENV_SCRIPT" >> "$ARM64_HARNESS"

cat >> "$ARM64_HARNESS" <<'EOF'
	echo "$mirror_list"
}
test_mirrors
EOF

ARM64_MIRRORS=$(sh "$ARM64_HARNESS")
FIRST_MIRROR=$(echo "$ARM64_MIRRORS" | awk '{print $1}')
echo "$FIRST_MIRROR" | grep -q "unofficial-builds.nodejs.org" || fail "arm64 musl first candidate mirror must be unofficial-builds (actual: $FIRST_MIRROR)"
echo "$ARM64_MIRRORS" | grep -q "npmmirror.com" || fail "arm64 musl mirror list must include npmmirror"
echo "$ARM64_MIRRORS" | grep -q "github.com/10000ge10000" || fail "arm64 musl mirror list must include fallback self-hosted asset"

# ── 9. gateway-verify 输出正则适配 OpenClaw 2026.9.1 ──
MOCK_GW_STATE="$TMP_DIR/gw-mock/data/.openclaw"
mkdir -p "$MOCK_GW_STATE"
MOCK_CLI_BIN="$TMP_DIR/gw-mock/bin/openclaw"
mkdir -p "$(dirname "$MOCK_CLI_BIN")"
cat > "$MOCK_CLI_BIN" <<'EOF'
#!/bin/sh
if [ "$1" = "gateway" ] && [ "$2" = "health" ]; then
	echo '{"ok": true, "durationMs": 5}'
	exit 0
fi
exit 1
EOF
chmod 755 "$MOCK_CLI_BIN"
chmod -R 755 "$TMP_DIR/gw-mock"

OPENCLAW_CLI="$MOCK_CLI_BIN" sh "$STATE_SCRIPT" gateway-verify "mock-token" "$MOCK_GW_STATE" >/dev/null 2>&1 \
	|| fail "gateway-verify must succeed when health reports {\"ok\": true}"

# 验证带空格的 "ok" : true 输出
cat > "$MOCK_CLI_BIN" <<'EOF'
#!/bin/sh
if [ "$1" = "gateway" ] && [ "$2" = "health" ]; then
	echo '{ "ok" : true, "status": "online" }'
	exit 0
fi
exit 1
EOF
chmod 755 "$MOCK_CLI_BIN"
chmod -R 755 "$TMP_DIR/gw-mock"

OPENCLAW_CLI="$MOCK_CLI_BIN" sh "$STATE_SCRIPT" gateway-verify "mock-token" "$MOCK_GW_STATE" >/dev/null 2>&1 \
	|| fail "gateway-verify must succeed when health reports { \"ok\" : true }"

# ── 10. CLI 路径探测 /opt/openclaw/global/bin/openclaw 兜底 ──
MOCK_OPT_DIR="$TMP_DIR/opt/openclaw/global/bin"
mkdir -p "$MOCK_OPT_DIR"
cat > "$MOCK_OPT_DIR/openclaw" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$MOCK_OPT_DIR/openclaw"

(
	# 清空环境变量，模拟独立外部调用
	unset OPENCLAW_CLI OC_GLOBAL OC_INSTALL_PATH
	PATH="/usr/bin:/bin"
	. "$STATE_SCRIPT"
	# 若全局存在 /opt/openclaw/global/bin/openclaw 或有 mock，验证 oc_find_cli 逻辑
	type oc_find_cli >/dev/null 2>&1 || fail "oc_find_cli must be defined in upgrade helper"
)

echo "ok"
