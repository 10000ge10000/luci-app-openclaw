#!/bin/sh
# 旧版配置迁移 (oc-config-fixups.js) 行为测试。
#
# 背景: OpenClaw 2026.9.35 起配置校验对未知键报错，Gateway 遇到非法配置拒绝启动，
# Doctor 会直接删除未知键。插件 v2.2.x 及更早版本写入过三个上游不接受的字段:
#   gateway.controlUi.allowInsecureAuth  (已退役，存在即拒绝启动 —— 实测 P0)
#   channels.discord.botToken            (上游字段为 token，Doctor 会删掉导致 Token 丢失)
#   gateway.logLevel                     (上游字段为 logging.level)
# 升级到新版前必须先迁移，且不得丢失用户的 Token、不得在日志中输出值。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
FIXUPS="$REPO_ROOT/root/usr/share/openclaw/oc-config-fixups.js"
INITD="$REPO_ROOT/root/etc/init.d/openclaw"
ENV_SCRIPT="$REPO_ROOT/root/usr/bin/openclaw-env"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

# ── 静态: 迁移必须在 Doctor / Gateway 之前执行，且插件自身不再写入退役字段 ──
grep -q 'oc-config-fixups.js' "$INITD" || fail "init.d must run config fixups before starting the gateway"
grep -q 'oc-config-fixups' "$ENV_SCRIPT" || fail "openclaw-env must run config fixups during upgrades"
fix_line=$(grep -n 'oc-config-fixups.js "$CONFIG_FILE"' "$INITD" | head -1 | cut -d: -f1)
# 比较的是调用点 (函数定义在前，调用在后)
doctor_line=$(grep -n '^[[:space:]]*_run_config_migration "$oc_entry"' "$INITD" | head -1 | cut -d: -f1)
[ -n "$fix_line" ] && [ -n "$doctor_line" ] && [ "$fix_line" -lt "$doctor_line" ] \
	|| fail "fixups must run before doctor --fix (doctor deletes unknown keys such as discord botToken)"
for f in "$INITD" "$ENV_SCRIPT" "$REPO_ROOT/root/usr/share/openclaw/oc-config.sh" "$REPO_ROOT/root/usr/share/openclaw/oc-config-interactive.js"; do
	if grep -nE "allowInsecureAuth[\"']?[[:space:]]*[=:,][[:space:]]*true|allowInsecureAuth=true|'gateway\.controlUi\.allowInsecureAuth', *true" "$f"; then
		fail "$(basename "$f") must not write the retired gateway.controlUi.allowInsecureAuth"
	fi
done
# telegram / slack 的 botToken 是上游合法字段，只检查 discord 的写入
if grep -nE "jsonSet\('channels\.discord\.botToken'|discord\.botToken *= " "$REPO_ROOT/root/usr/share/openclaw/oc-config-interactive.js"; then
	fail "interactive menu must write channels.discord.token, not botToken"
fi

command -v node >/dev/null 2>&1 || { echo "ok (static only: no node interpreter available)"; exit 0; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
CFG="$WORK/openclaw.json"

run_fix() {
	set +e
	node "$FIXUPS" "$@" >"$WORK/out" 2>&1
	RC=$?
	set -e
}
cfg_assert() {
	node -e '
const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
if (!('"$1"')) { console.error(JSON.stringify(c, null, 1)); process.exit(1); }
' "$CFG" || fail "$2"
}

# 场景 1: v2.2.x 典型配置 → 三项全部迁移，其余内容不变，日志不含值
cat > "$CFG" <<'EOF'
{
  "gateway": { "port": 18789, "logLevel": "debug", "controlUi": { "allowInsecureAuth": true, "enabled": true } },
  "channels": { "discord": { "botToken": "DISCORD-SECRET", "enabled": true }, "telegram": { "botToken": "TG-SECRET" } },
  "models": { "providers": { "keep": { "apiKey": "KEEP-SECRET" } } }
}
EOF
chmod 640 "$CFG"
run_fix "$CFG"
[ "$RC" -eq 0 ] || { cat "$WORK/out" >&2; fail "fixups should succeed on a legacy config"; }
cfg_assert '!("allowInsecureAuth" in c.gateway.controlUi) && c.gateway.controlUi.enabled === true' "allowInsecureAuth must be removed, siblings kept"
cfg_assert 'c.channels.discord.token === "DISCORD-SECRET" && !("botToken" in c.channels.discord) && c.channels.discord.enabled === true' \
	"discord botToken must move to token without losing the value"
cfg_assert 'c.channels.telegram.botToken === "TG-SECRET"' "telegram botToken is a valid upstream key and must be left alone"
cfg_assert 'c.logging.level === "debug" && !("logLevel" in c.gateway) && c.gateway.port === 18789' "gateway.logLevel must move to logging.level"
cfg_assert 'c.models.providers.keep.apiKey === "KEEP-SECRET"' "unrelated content must be preserved"
if grep -q 'SECRET' "$WORK/out"; then fail "fixups output must not contain config values"; fi
grep -q 'channels.discord.botToken -> channels.discord.token' "$WORK/out" || fail "fixups must report which paths changed"
mode=$(ls -l "$CFG" | cut -c1-10)
[ "$mode" = "-rw-r-----" ] || fail "fixups must preserve the original file mode (got $mode)"

# 场景 2: 幂等 —— 再跑一次不改动文件
cp "$CFG" "$WORK/before"
run_fix "$CFG"
[ "$RC" -eq 0 ] && cmp -s "$CFG" "$WORK/before" || fail "fixups must be idempotent"
[ ! -s "$WORK/out" ] || fail "no-op run must not print changes"

# 场景 3: 新旧字段同时存在时以新字段为准，只删除旧字段
cat > "$CFG" <<'EOF'
{ "gateway": { "logLevel": "debug" }, "logging": { "level": "warn" }, "channels": { "discord": { "token": "NEW", "botToken": "OLD" } } }
EOF
run_fix "$CFG"
cfg_assert 'c.channels.discord.token === "NEW" && !("botToken" in c.channels.discord)' "existing discord token must win over the legacy botToken"
cfg_assert 'c.logging.level === "warn" && !("logLevel" in c.gateway)' "existing logging.level must win over gateway.logLevel"

# 场景 4: 损坏 / 非对象 / 空文件 / 不存在 —— 不写入
printf '{ "gateway": { "controlUi": { "allowInsecureAuth": true } }, }' > "$CFG"
cp "$CFG" "$WORK/before"
run_fix "$CFG"
[ "$RC" -eq 3 ] || fail "corrupt config must exit 3"
cmp -s "$CFG" "$WORK/before" || fail "corrupt config must stay byte-for-byte unchanged"
printf '[1,2]' > "$CFG"
run_fix "$CFG"
[ "$RC" -eq 3 ] && [ "$(cat "$CFG")" = "[1,2]" ] || fail "non-object root must be left untouched"
: > "$CFG"
run_fix "$CFG"
[ "$RC" -eq 0 ] && [ ! -s "$CFG" ] || fail "empty config must be a no-op"
run_fix "$WORK/missing.json"
[ "$RC" -eq 0 ] && [ ! -e "$WORK/missing.json" ] || fail "missing config must be a no-op"
run_fix
[ "$RC" -eq 2 ] || fail "missing argument must be a usage error"
ls "$WORK"/.openclaw.json.fixups-* >/dev/null 2>&1 && fail "fixups must not leave temporary files behind"

echo "ok"
