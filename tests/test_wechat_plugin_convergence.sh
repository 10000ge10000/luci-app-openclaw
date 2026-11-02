#!/bin/sh
# 微信插件版本收敛契约。
#
# 背景 (真机实测, 2026-11-02): 2026.6.11 → 2026.9.36 升级后 Gateway 健康，
# plugins list 显示 openclaw-weixin loaded，但渠道崩溃循环:
#   channel exited: Package subpath './plugin-sdk/channel-runtime' is not defined by "exports"
# 官方插件 peerDependencies 只声明 >=2026.5.12，安装时不会拦截，
# 因此每个核心版本要求的最低插件版本记录在兼容矩阵里，升级时按矩阵收敛。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SHARE="$REPO_ROOT/root/usr/share/openclaw"
COMPAT="$SHARE/openclaw-compat.json"
CONTRACT="$SHARE/openclaw-package-contract.js"
ENV_SCRIPT="$REPO_ROOT/root/usr/bin/openclaw-env"
HELPER="$REPO_ROOT/root/usr/libexec/openclaw-upgrade-state.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

# ── 静态: 收敛必须在 Doctor 之后、启动 Gateway 之前，报告里要有结果 ──
BODY=$(awk '/^upgrade_openclaw\(\) \{/,/^}/' "$ENV_SCRIPT")
line_of() { printf '%s\n' "$BODY" | grep -n -F "$1" | head -1 | cut -d: -f1; }
doc_line=$(line_of '"$state_helper" doctor-migration')
wx_line=$(line_of '"$state_helper" wechat-install')
gw_line=$(line_of 'record_verified_cmd "gateway-start"')
[ -n "$doc_line" ] && [ -n "$wx_line" ] && [ -n "$gw_line" ] \
	&& [ "$doc_line" -lt "$wx_line" ] && [ "$wx_line" -lt "$gw_line" ] \
	|| fail "wechat-install must run after doctor migration and before the gateway starts"
printf '%s\n' "$BODY" | grep -Fq 'echo "WECHAT: ${rep_wechat}"' || fail "upgrade report must include a WECHAT line"

command -v node >/dev/null 2>&1 || { echo "ok (static only: no node interpreter available)"; exit 0; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# ── 矩阵: 每个版本都写明要求，且安装版本满足全部要求；写死的版本与矩阵一致 ──
node - "$COMPAT" "$CONTRACT" <<'EOF' || fail "compat matrix wechat data is inconsistent"
const fs = require('fs');
const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const k = require(process.argv[3]);
const errs = [];
if (c.wechat.package !== '@tencent-weixin/openclaw-weixin') errs.push('bad wechat.package');
const pin = k.parseStrictSemver(c.wechat.pin);
if (!pin) errs.push('wechat.pin must be an exact version');
for (const [v, e] of Object.entries(c.versions)) {
  const min = k.parseStrictSemver(e.wechat && e.wechat.minPlugin);
  if (!min) { errs.push(`${v}: missing wechat.minPlugin`); continue; }
  if (pin && k.compareSemver(pin, min) < 0) errs.push(`${v}: pin is below minPlugin`);
}
if (errs.length) { console.error(errs.join('\n')); process.exit(1); }
EOF
PIN=$(node -p "require('$COMPAT').wechat.pin")
for f in "$REPO_ROOT/luasrc/controller/openclaw.lua" "$REPO_ROOT/root/etc/init.d/openclaw"; do
	grep -Fq "openclaw-weixin@${PIN}" "$f" || fail "$(basename "$f") must install the matrix pin ${PIN}"
	if grep -E 'openclaw-weixin@[0-9]' "$f" | grep -vFq "openclaw-weixin@${PIN}"; then
		fail "$(basename "$f") installs a wechat plugin version other than the matrix pin"
	fi
done

# ── wechat-plan 判定表 ──
check_plan() {
	got=$(node "$CONTRACT" wechat-plan "$1" ${2:+"$2"} | cut -d' ' -f1)
	[ "$got" = "$3" ] || fail "wechat-plan $1 ${2:-<none>}: expected $3, got $got"
}
check_plan 2026.9.36 2.4.6 upgrade   # 真机崩溃循环的组合
check_plan 2026.9.36 2.4.8 upgrade   # 能加载，但缺 2.4.9 的入站回复修复
check_plan 2026.9.36 2.4.9 ok
check_plan 2026.9.36 2.4.10 ok
check_plan 2026.10.9 2.4.9 upgrade   # 2.4.10 才适配 2026.10
check_plan 2026.10.9 2.4.10 ok
check_plan 2026.10.9 2.5.0 ok        # 用户自行装的更新版本不降级
check_plan 2026.9.36 2.4.9-beta.0 upgrade  # 无法严格解析时按矩阵收敛
check_plan 2026.9.36 "" upgrade
check_plan 2099.1.1 2.4.6 unknown    # 未验证核心不做猜测

# ── wechat_installed_version: 只认已启用且确实安装的插件 ──
awk '/^wechat_installed_version\(\) \{/,/^}/' "$ENV_SCRIPT" > "$WORK/fn.sh"
grep -q '^wechat_installed_version() {' "$WORK/fn.sh" || fail "cannot extract wechat_installed_version"
DATA="$WORK/data"
STATE="$DATA/.openclaw"
NPM_PKG="$STATE/npm/projects/p1/node_modules/@tencent-weixin/openclaw-weixin"
mkdir -p "$NPM_PKG"
installed() {
	OC_DATA="$DATA" NODE_BIN="$(command -v node)" sh -c ". \"$WORK/fn.sh\"; wechat_installed_version"
}
[ -z "$(installed)" ] || fail "no config: must report nothing"
printf '{"version":"2.4.6"}\n' > "$NPM_PKG/package.json"
printf '{"channels":{"openclaw-weixin":{"enabled":false}}}\n' > "$STATE/openclaw.json"
[ -z "$(installed)" ] || fail "disabled plugin must not be touched"
printf '{"channels":{"openclaw-weixin":{"enabled":true}}}\n' > "$STATE/openclaw.json"
[ "$(installed)" = "2.4.6" ] || fail "enabled npm-project plugin must report its version"
printf '{"plugins":{"entries":{"openclaw-weixin":{"enabled":true}}}}\n' > "$STATE/openclaw.json"
[ "$(installed)" = "2.4.6" ] || fail "plugins.entries enabled must count as in use"
printf '{ broken' > "$STATE/openclaw.json"
[ -z "$(installed)" ] || fail "corrupt config must report nothing, not fail the upgrade"
rm -rf "$STATE/npm"
mkdir -p "$STATE/extensions/openclaw-weixin"
printf '{"version":"2.0.1"}\n' > "$STATE/extensions/openclaw-weixin/package.json"
printf '{"channels":{"openclaw-weixin":{"enabled":true}}}\n' > "$STATE/openclaw.json"
[ "$(installed)" = "2.0.1" ] || fail "legacy extensions directory must be detected"
rm -rf "$STATE/extensions"
[ -z "$(installed)" ] || fail "enabled but not installed must report nothing"

# ── wechat-install: 经官方 CLI 安装，版本号非法时不调用 ──
CLI="$WORK/cli"
cat > "$CLI" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CLI_LOG"
printf '%s\n' "${OPENCLAW_SUPERVISOR_MODE:-}" >> "$CLI_LOG"
exit "${CLI_RC:-0}"
EOF
chmod +x "$CLI"
CLI_LOG="$WORK/cli.log"
export CLI_LOG
run_helper() {
	set +e
	# 设置 OC_GLOBAL 才不会被 oc_load_paths 覆盖成 /opt/openclaw
	OPENCLAW_CLI="$CLI" OC_GLOBAL="$WORK/global" OC_DATA="$DATA" OPENCLAW_STATE_DIR="$STATE" sh "$HELPER" wechat-install "$@" >"$WORK/helper.out" 2>&1
	RC=$?
	set -e
}
run_helper "$STATE" "1.2.3;touch $WORK/pwned"
[ "$RC" -eq 2 ] && [ ! -e "$CLI_LOG" ] && [ ! -e "$WORK/pwned" ] || fail "invalid version must be rejected before any shell evaluation"
run_helper "$STATE" "$PIN"
[ "$RC" -eq 0 ] || { cat "$WORK/helper.out" >&2; fail "wechat-install should succeed"; }
grep -Fxq "plugins install --force --pin @tencent-weixin/openclaw-weixin@${PIN}" "$CLI_LOG" || fail "wechat-install must use the official installer with a pinned version"
grep -Fxq "external" "$CLI_LOG" || fail "wechat-install must not let the CLI touch the service supervisor"
CLI_RC=7
export CLI_RC
run_helper "$STATE" "$PIN"
[ "$RC" -eq 7 ] || fail "wechat-install must propagate the installer exit code (got $RC)"
unset CLI_RC

# ── 收敛分支: 从 upgrade_openclaw 中抽出实际代码运行 ──
SNIPPET="$WORK/snippet.sh"
{
	cat <<'EOF'
log_info() { :; }; log_warn() { :; }; log_error() { echo "ERROR: $*" >&2; }
record_verified_cmd() { echo "$1=$2" >> "$WORK/rec"; }
wechat_installed_version() { cat "$WORK/ver" 2>/dev/null || true; }
run() {
	local rep_wechat="not-enabled" target_ver="$1" state_dir="$WORK/state" state_helper="$WORK/helper"
EOF
	awk '/微信插件版本收敛: 核心移除/{g=1} /# 3\. 启动 Gateway/{g=0} g' "$ENV_SCRIPT"
	cat <<'EOF'
	echo "$rep_wechat"
}
run "$TARGET"
EOF
} > "$SNIPPET"
grep -q 'wechat-install' "$SNIPPET" || fail "cannot extract the convergence block"
cat > "$WORK/helper" <<'EOF'
#!/bin/sh
echo "$*" >> "$WORK/helper.log"
[ "${HELPER_RC:-0}" -eq 0 ] || exit "$HELPER_RC"
[ -n "${HELPER_SETS:-}" ] && echo "$HELPER_SETS" > "$WORK/ver"
exit 0
EOF
chmod +x "$WORK/helper"
export WORK
converge() {
	# $1 目标核心 $2 当前插件 (空=未启用)
	rm -f "$WORK/helper.log" "$WORK/ver" "$WORK/rec"
	[ -z "$2" ] || echo "$2" > "$WORK/ver"
	TARGET="$1" NODE_BIN="$(command -v node)" OC_PACKAGE_CONTRACT="$CONTRACT" sh -c ". \"$SNIPPET\"" 2>"$WORK/conv.err"
}
[ "$(converge 2026.9.36 "")" = "not-enabled" ] && [ ! -e "$WORK/helper.log" ] || fail "plugin not in use: nothing to do"
[ "$(converge 2026.9.36 2.4.10)" = "ok (2.4.10)" ] && [ ! -e "$WORK/helper.log" ] || fail "satisfied plugin must not be reinstalled"
got=$(HELPER_SETS=$PIN converge 2026.9.36 2.4.6)
[ "$got" = "updated (2.4.6 -> $PIN)" ] || fail "outdated plugin must be upgraded (got: $got)"
grep -Fq "wechat-install $WORK/state $PIN" "$WORK/helper.log" || fail "must install the matrix pin"
grep -Fxq "wechat-plugin=0" "$WORK/rec" || fail "must record the install result"
# 失败不能说成成功: 安装报错或安装后版本没变都算失败，且不中断事务
got=$(HELPER_RC=5 converge 2026.9.36 2.4.6) || fail "install failure must not abort the upgrade transaction"
case "$got" in failed*) ;; *) fail "install failure must be reported as failed (got: $got)" ;; esac
grep -q 'ERROR' "$WORK/conv.err" || fail "install failure must be logged as an error"
got=$(converge 2026.9.36 2.4.6)
case "$got" in failed*) ;; *) fail "installer succeeding without changing the version must be reported as failed (got: $got)" ;; esac
got=$(converge 2099.1.1 2.4.6)
case "$got" in unknown*) ;; *) fail "unverified core must be reported as unknown (got: $got)" ;; esac
[ ! -e "$WORK/helper.log" ] || fail "unverified core: must not guess a plugin version"

echo "ok"
