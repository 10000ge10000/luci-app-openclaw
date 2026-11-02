#!/bin/sh
# 发布通道与版本锁定的选择逻辑。
#
# 两层都要校验:
#   - Shell: openclaw-env 的 resolve_target_version 把 OC_VERSION / OC_CHANNEL / UCI pin_version /
#     上游 dist-tag 组合后交给 openclaw-package-contract.js resolve-target
#   - Lua: controller 的 parse_version_selection 对前端参数做白名单校验，之后才拼入 shell
# 约束: 默认只安装已验证版本；上游更新只提示；未验证版本必须显式允许；
#       registry 不可达时不影响安装已验证版本；非法输入失败关闭。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ENV_SCRIPT="$REPO_ROOT/root/usr/bin/openclaw-env"
CONTRACT_JS="$REPO_ROOT/root/usr/share/openclaw/openclaw-package-contract.js"
REAL_COMPAT="$REPO_ROOT/root/usr/share/openclaw/openclaw-compat.json"
CONTROLLER="$REPO_ROOT/luasrc/controller/openclaw.lua"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

# ── 静态: 前端参数必须先过白名单 ──
grep -Fq 'local function parse_version_selection' "$CONTROLLER" || fail "controller must validate version selection"
grep -Fq 'pin:match("^%d+%.%d+%.%d+$")' "$CONTROLLER" || fail "controller must whitelist pinned versions"
grep -Fq 'channel ~= "extended-stable" and channel ~= "latest"' "$CONTROLLER" || fail "controller must whitelist channels"
grep -Fq 'OC_CHANNEL=" .. shellquote(sel.channel)' "$CONTROLLER" || fail "controller must shell-quote the channel"
grep -Fq 'OC_VERSION=" .. shellquote(sel.pin)' "$CONTROLLER" || fail "controller must shell-quote the pinned version"

NODE_BIN=$(command -v node 2>/dev/null || true)
[ -n "$NODE_BIN" ] || { echo "ok (static only: no node interpreter available)"; exit 0; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/bin"

# fixture 矩阵，与真实版本号解耦
COMPAT="$WORK/compat.json"
"$NODE_BIN" -e '
const fs = require("fs");
const base = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const v = (channel) => ({ channel, engines: ">=24.22.1 <25", integrity: "sha512-x", unpackedSize: 1, sqliteVec: "0.1.9", verification: {} });
fs.writeFileSync(process.argv[2], JSON.stringify({
  schema: 1, node: base.node, lifecycle: base.lifecycle, defaultChannel: "extended-stable",
  channels: { "extended-stable": { verified: "2030.1.5" }, latest: { verified: "2030.2.3" } },
  versions: { "2030.1.5": v("extended-stable"), "2030.2.3": v("latest"), "2029.12.1": v("legacy") }
}));' "$REAL_COMPAT" "$COMPAT"

# uci / npm 替身
cat > "$WORK/bin/uci" <<'EOF'
#!/bin/sh
[ -n "${MOCK_UCI_PIN:-}" ] && { echo "$MOCK_UCI_PIN"; exit 0; }
exit 1
EOF
cat > "$WORK/bin/npm" <<'EOF'
#!/bin/sh
[ -n "${MOCK_DISTTAGS:-}" ] && { echo "$MOCK_DISTTAGS"; exit 0; }
echo "npm ERR! network" >&2
exit 1
EOF
chmod +x "$WORK/bin/uci" "$WORK/bin/npm"

HARNESS="$WORK/harness.sh"
{
	echo 'log_info() { :; }; log_warn() { echo "WARN: $*" >&2; }; log_error() { echo "ERROR: $*" >&2; }'
	for fn in fetch_upstream_disttags upstream_disttag compat_default_channel resolve_target_version; do
		awk -v fn="$fn" '$0 ~ "^"fn"\\(\\) \\{" { grab = 1 } grab { print } grab && /^}/ { exit }' "$ENV_SCRIPT"
	done
	cat <<'EOF'
resolve_target_version || exit $?
echo "$OC_TARGET_VER $OC_TARGET_CHANNEL $OC_TARGET_VERIFIED $OC_TARGET_NEWER ${OC_TARGET_UPSTREAM:--}"
EOF
} > "$HARNESS"
for fn in fetch_upstream_disttags upstream_disttag compat_default_channel resolve_target_version; do
	grep -q "^${fn}() {" "$HARNESS" || fail "cannot extract $fn from openclaw-env"
done

# 用法: resolve 环境赋值...  (每次独立子进程，变量不会泄漏到后续用例)
resolve() {
	env PATH="$WORK/bin:$PATH" NODE_BIN="$NODE_BIN" NPM_BIN="$WORK/bin/npm" OC_PACKAGE_CONTRACT="$CONTRACT_JS" \
		OC_COMPAT_FILE="$COMPAT" OC_CHANNEL="" OC_VERSION="" OC_ALLOW_UNVERIFIED=0 "$@" sh "$HARNESS" 2>"$WORK/err"
}
expect() {
	_want="$1"; shift
	_got=$(resolve "$@") || { cat "$WORK/err" >&2; fail "resolve [$*] should succeed"; }
	[ "$_got" = "$_want" ] || fail "resolve [$*]: expected '$_want', got '$_got'"
}
expect_reject() {
	if resolve "$@" >/dev/null; then fail "resolve [$*] must be rejected"; fi
}
TAGS='MOCK_DISTTAGS={"latest":"2030.2.9","extended-stable":"2030.1.5"}'

# 默认: 长期稳定通道的已验证版本
expect "2030.1.5 extended-stable verified same 2030.1.5" "$TAGS"
# 通道来源: OC_CHANNEL (UCI 保存值由前端传入) 与 OC_VERSION 别名
expect "2030.2.3 latest verified newer 2030.2.9" "$TAGS" OC_CHANNEL=latest
expect "2030.2.3 latest verified newer 2030.2.9" "$TAGS" OC_VERSION=latest
expect "2030.1.5 extended-stable verified same 2030.1.5" "$TAGS" OC_VERSION=stable
# 显式允许才安装未验证的上游新版
expect "2030.2.9 latest unverified newer 2030.2.9" "$TAGS" OC_CHANNEL=latest OC_ALLOW_UNVERIFIED=1
# registry 不可达: 仍可安装已验证版本，并提示
expect "2030.1.5 extended-stable verified same -"
grep -q '无法查询上游' "$WORK/err" || fail "unreachable registry must be reported"
expect "2030.2.3 latest verified same -" OC_CHANNEL=latest OC_ALLOW_UNVERIFIED=1
# 锁定版本: OC_VERSION 优先于 UCI，UCI 优先于通道，锁定时不查询上游
expect "2029.12.1 legacy verified same -" OC_VERSION=2029.12.1
expect "2029.12.1 legacy verified same -" MOCK_UCI_PIN=2029.12.1 OC_CHANNEL=latest
expect "2030.1.5 extended-stable verified same -" MOCK_UCI_PIN=2029.12.1 OC_VERSION=2030.1.5
expect_reject OC_VERSION=2030.3.1
expect "2030.3.1 pinned unverified same -" OC_VERSION=2030.3.1 OC_ALLOW_UNVERIFIED=1
# 非法输入失败关闭
expect_reject OC_VERSION=not-a-version
expect_reject 'OC_VERSION=1.2.3;id'
expect_reject OC_CHANNEL=nightly
expect_reject OC_COMPAT_FILE="$WORK/missing.json"
# 畸形 dist-tag 不得被当作版本使用
expect "2030.2.3 latest verified same -" 'MOCK_DISTTAGS={"latest":"$(id)"}' OC_CHANNEL=latest OC_ALLOW_UNVERIFIED=1

# ── Lua: parse_version_selection (CI 安装了 lua5.1；本机无解释器时跳过) ──
lua_bin=""
for cand in lua5.1 lua luajit; do
	command -v "$cand" >/dev/null 2>&1 && { lua_bin="$cand"; break; }
done
if [ -z "$lua_bin" ]; then
	echo "ok (Lua checks skipped: interpreter unavailable)"
	exit 0
fi
{
	cat <<'EOF'
local function shellquote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
EOF
	awk '/^local function parse_version_selection/,/^end$/' "$CONTROLLER"
	awk '/^local function version_env_prefix/,/^end$/' "$CONTROLLER"
	cat <<'EOF'
local saved = ""
package.loaded["luci.model.uci"] = { cursor = function() return { get = function() return saved end } end }
local function check(cond, msg) if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); os.exit(1) end end
local s = parse_version_selection("", "", "", "")
check(s.channel == "extended-stable" and s.pin == "" and s.allow == false, "default channel")
s = parse_version_selection("latest", "", "", "1")
check(s.channel == "latest" and s.allow == true, "explicit channel and allow")
s = parse_version_selection("", "", "stable", "")
check(s.channel == "extended-stable", "legacy stable alias")
s = parse_version_selection("", "", "latest", "")
check(s.channel == "latest", "legacy latest alias")
s = parse_version_selection("", "", "v2026.9.1", "")
check(s.pin == "2026.9.1", "legacy exact version becomes pin")
s = parse_version_selection("", "v2026.9.36", "", "")
check(s.pin == "2026.9.36", "pin strips v prefix")
saved = "latest"
s = parse_version_selection("", "", "", "")
check(s.channel == "latest", "falls back to the saved UCI channel")
saved = ""
check(parse_version_selection("nightly", "", "", "") == nil, "unknown channel rejected")
check(parse_version_selection("", "1.2.3;id", "", "") == nil, "shell metacharacters in pin rejected")
check(parse_version_selection("$(id)", "", "", "") == nil, "shell metacharacters in channel rejected")
check(parse_version_selection("", "2026.9", "", "") == nil, "incomplete pin rejected")
local p = version_env_prefix({ channel = "latest", pin = "2026.9.1", allow = true })
check(p:find("OC_CHANNEL='latest'", 1, true) and p:find("OC_VERSION='2026.9.1'", 1, true) and p:find("OC_ALLOW_UNVERIFIED=1", 1, true), "env prefix")
p = version_env_prefix({ channel = "latest", pin = "", allow = false })
check(not p:find("OC_VERSION", 1, true) and not p:find("OC_ALLOW_UNVERIFIED", 1, true), "env prefix omits unset values")
EOF
} > "$WORK/sel.lua"
"$lua_bin" "$WORK/sel.lua" || fail "parse_version_selection behavior checks failed"

echo "ok"
