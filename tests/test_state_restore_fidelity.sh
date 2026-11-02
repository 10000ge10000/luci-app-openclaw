#!/bin/sh
# 备份与恢复的真实场景回归 (均来自 2026-11-02 真机验证):
#   1. oc_run_as_user 的环境变量只绑定到复合命令的第一条，CLI 带着 root 的 HOME 运行，
#      2026.9.36 上 backup create 因临时目录不安全而失败
#   2. 插件 npm 目录里的相对软链接被当成路径穿透，备份无法恢复
#   3. plugins install 创建的绝对软链接被新版 backup verify 拒绝，升级后无法回滚
#   4. 2026.9.x 的备份不含 workspace / npm，恢复时整目录替换会删掉它们
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
HELPER="$REPO_ROOT/root/usr/libexec/openclaw-upgrade-state.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
GLOBAL="$WORK/global"
DATA="$WORK/data"
STATE="$DATA/.openclaw"
mkdir -p "$GLOBAL/lib/node_modules/openclaw" "$STATE"

helper() {
	OC_GLOBAL="$GLOBAL" OC_DATA="$DATA" OPENCLAW_STATE_DIR="$STATE" OPENCLAW_CONFIG_PATH="$STATE/openclaw.json" \
		sh "$HELPER" "$@"
}

# 构造归档: $1 归档名，归档内 state 目录由 $2 给出
pack() {
	( cd "$(dirname "$2")" && tar -czf "$WORK/$1.tar.gz" "$(basename "$2")" )
}

new_src() {
	SRC="$WORK/src-$1/.openclaw"
	mkdir -p "$SRC/state"
	echo '{"marker":"archive"}' > "$SRC/openclaw.json"
	echo 'db' > "$SRC/state/openclaw.sqlite"
}

reset_live() {
	rm -rf "$STATE"
	mkdir -p "$STATE/workspace" "$STATE/npm/projects/p"
	echo '{"marker":"live"}' > "$STATE/openclaw.json"
	echo 'my notes' > "$STATE/workspace/AGENTS.md"
	echo 'plugin' > "$STATE/npm/projects/p/index.js"
}

restore() {
	set +e
	helper restore-state "$WORK/$1.tar.gz" "$STATE" >"$WORK/out" 2>&1
	RC=$?
	set -e
}

# ── 复合命令也要拿到完整环境 ──
CLI="$WORK/cli"
cat > "$CLI" <<'EOS'
#!/bin/sh
case "$1 $2" in
	"backup create")
		printf 'HOME=%s\nSTATE=%s\n' "$HOME" "$OPENCLAW_STATE_DIR" > "$ENV_LOG"
		printf 'x' | gzip > "./fake-openclaw-backup.tar.gz"
		;;
	"backup verify")
		[ -z "${VERIFY_MSG:-}" ] && exit 0
		echo "$VERIFY_MSG"
		exit 1
		;;
esac
EOS
chmod +x "$CLI"
ENV_LOG="$WORK/env.log"
export ENV_LOG
OPENCLAW_CLI="$CLI" HOME=/nonexistent-root-home helper backup-create "$WORK/bk" "$STATE" >"$WORK/out" 2>&1 \
	|| { cat "$WORK/out" >&2; fail "backup-create should succeed with the mock CLI"; }
grep -Fxq "HOME=$DATA" "$ENV_LOG" || fail "CLI must run with the service HOME, not the caller's (got: $(cat "$ENV_LOG"))"
grep -Fxq "STATE=$STATE" "$ENV_LOG" || fail "CLI must receive OPENCLAW_STATE_DIR"

# ── 软链接检查: 留在解包目录内的相对链接和插件 peer 链接放行，其它拒绝 ──
new_src ok
mkdir -p "$SRC/npm/node_modules/.bin" "$SRC/npm/node_modules/qr/bin" "$SRC/npm/node_modules/@t/w/node_modules"
echo 'x' > "$SRC/npm/node_modules/qr/bin/qr.js"
ln -s ../qr/bin/qr.js "$SRC/npm/node_modules/.bin/qr"
ln -s "$GLOBAL/lib/node_modules/openclaw" "$SRC/npm/node_modules/@t/w/node_modules/openclaw"
pack links "$SRC"
reset_live
restore links
[ "$RC" -eq 0 ] || { cat "$WORK/out" >&2; fail "npm .bin links and the peerDependency link must not block a restore"; }
[ -L "$STATE/npm/node_modules/.bin/qr" ] || fail "restore must keep symlinks"
grep -q '"archive"' "$STATE/openclaw.json" || fail "restore must apply the archive"

for bad in "../../../../../../outside" "/etc/passwd" "$GLOBAL/lib/node_modules/openclaw/evil" "$GLOBAL/../other"; do
	rm -rf "$WORK/src-bad"
	new_src bad
	ln -s "$bad" "$SRC/escape"
	pack bad "$SRC"
	reset_live
	restore bad
	[ "$RC" -ne 0 ] || fail "symlink to $bad must be rejected"
	grep -q '"live"' "$STATE/openclaw.json" || fail "rejected restore must leave the live state untouched ($bad)"
done

# ── 新版备份不含 workspace / npm: 保留现有目录 ──
new_src noworkspace
pack noworkspace "$SRC"
reset_live
restore noworkspace
[ "$RC" -eq 0 ] || { cat "$WORK/out" >&2; fail "restore of an archive without workspace should succeed"; }
grep -q '"archive"' "$STATE/openclaw.json" || fail "archive config must win"
[ "$(cat "$STATE/workspace/AGENTS.md" 2>/dev/null)" = "my notes" ] || fail "workspace missing from the archive must survive a restore"
[ -f "$STATE/npm/projects/p/index.js" ] || fail "npm plugins missing from the archive must survive a restore"
ls "$DATA"/.state-pre-restore-* >/dev/null 2>&1 && fail "restore must not leave the old state directory behind"

# 归档自带 workspace 时以归档为准
new_src withworkspace
mkdir -p "$SRC/workspace"
echo 'from archive' > "$SRC/workspace/AGENTS.md"
pack withworkspace "$SRC"
reset_live
restore withworkspace
[ "$(cat "$STATE/workspace/AGENTS.md")" = "from archive" ] || fail "workspace in the archive must take precedence"
[ ! -e "$STATE/workspace/workspace" ] || fail "the old workspace must not be nested into the restored one"

# ── backup verify: 只放行绝对软链接这一种拒绝 ──
reset_live
new_src verify
pack verify "$SRC"
set +e
OPENCLAW_CLI="$CLI" VERIFY_MSG="Archive symbolic link target must be relative: /x" helper backup-verify "$WORK/verify.tar.gz" "$STATE" >"$WORK/out" 2>&1
RC_LINK=$?
OPENCLAW_CLI="$CLI" VERIFY_MSG="Archive checksum mismatch" helper backup-verify "$WORK/verify.tar.gz" "$STATE" >"$WORK/out" 2>&1
RC_OTHER=$?
set -e
[ "$RC_LINK" -eq 0 ] || fail "archives rejected only for absolute links must fall back to local checks (rc=$RC_LINK)"
[ "$RC_OTHER" -ne 0 ] || fail "any other verify failure must still abort"

echo "ok"
