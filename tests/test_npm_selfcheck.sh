#!/bin/sh
# npm 运行时自检契约 (#109)。
#
# 背景: 用户升级时 npm pack 报 "Class extends value undefined is not a constructor or null"。
# 这是 npm 自身无法运行 (运行时文件损坏或不完整) 的表现，而旧实现:
#   - 升级流程直到 npm pack 才失败，只打印 npm 原始错误，没有修复指引
#   - setup 只比较 Node 版本号，版本满足即跳过下载，「安装运行环境」修不好损坏的 npm
#   - 已安装时 setup 直接退出，用户只能卸载重装
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ENV_SCRIPT="$REPO_ROOT/root/usr/bin/openclaw-env"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

# ── 静态契约 ──
upgrade_body=$(awk '/^upgrade_openclaw\(\) \{/,/^}/' "$ENV_SCRIPT")
selfcheck_line=$(printf '%s\n' "$upgrade_body" | grep -n 'if ! npm_selfcheck; then' | head -1 | cut -d: -f1)
pack_line=$(printf '%s\n' "$upgrade_body" | grep -n '"$NPM_BIN" pack' | head -1 | cut -d: -f1)
[ -n "$selfcheck_line" ] || fail "upgrade must run npm_selfcheck"
[ -n "$pack_line" ] || fail "upgrade must run npm pack"
[ "$selfcheck_line" -lt "$pack_line" ] || fail "npm_selfcheck must run before npm pack in upgrade"

download_body=$(awk '/^download_node\(\) \{/,/^}/' "$ENV_SCRIPT")
printf '%s\n' "$download_body" | grep -Fq 'if npm_selfcheck; then' \
	|| fail "download_node must not skip a same-version runtime whose npm is broken"

setup_body=$(awk '/^do_setup\(\) \{/,/^}/' "$ENV_SCRIPT")
printf '%s\n' "$setup_body" | grep -Fq 'if [ -e "$NPM_BIN" ] && ! npm_selfcheck; then' \
	|| fail "setup must repair the Node.js runtime only when npm exists but is broken (#109, #113)"
repair_branch=$(printf '%s\n' "$setup_body" | awk '/! npm_selfcheck; then/,/^\t\tfi$/')
if printf '%s\n' "$repair_branch" | grep -Fq 'OC_SETUP_CLEANUP=1'; then
	fail "runtime repair must never enable partial-install cleanup (it would delete an existing install)"
fi

# 预放置安装 (#113): 已有程序文件但未初始化时补齐初始化，且不得下载或解压
preplaced_branch=$(printf '%s\n' "$setup_body" | awk '/if \[ ! -f "\$OC_DATA\/.openclaw\/openclaw.json" \]; then/,/^\t\tfi$/')
[ -n "$preplaced_branch" ] || fail "setup must initialize a pre-placed install that has no openclaw.json (#113)"
for want in ensure_openclaw_user assert_node_runtime init_openclaw; do
	printf '%s\n' "$preplaced_branch" | grep -Fq "$want" || fail "pre-placed init branch must call $want"
done
if printf '%s\n' "$preplaced_branch" | grep -Eq 'download_node|install_openclaw[^_]|tar x'; then
	fail "pre-placed init branch must not download or extract anything (#113 devices reset on bulk writes)"
fi

# ── 行为契约: 抽出 npm_selfcheck 单独执行 ──
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

awk '/^NPM_SELFCHECK_OUTPUT=""$/ { grab = 1 } grab { print } grab && /^}$/ { exit }' "$ENV_SCRIPT" > "$WORK/selfcheck.sh"
grep -q '^npm_selfcheck() {' "$WORK/selfcheck.sh" || fail "cannot extract npm_selfcheck"

check() {
	NPM_BIN="$1" sh -c ". \"$WORK/selfcheck.sh\"; if npm_selfcheck; then echo PASS; else echo \"FAILED:\$NPM_SELFCHECK_OUTPUT\"; fi"
}

cat > "$WORK/npm-ok" <<'EOF'
#!/bin/sh
echo "10.9.1"
EOF
cat > "$WORK/npm-broken" <<'EOF'
#!/bin/sh
echo "npm error Class extends value undefined is not a constructor or null" >&2
exit 1
EOF
cat > "$WORK/npm-garbage" <<'EOF'
#!/bin/sh
echo "Segmentation fault"
EOF
chmod 755 "$WORK/npm-ok" "$WORK/npm-broken" "$WORK/npm-garbage"

[ "$(check "$WORK/npm-ok")" = "PASS" ] || fail "working npm must pass self-check"
out=$(check "$WORK/npm-broken")
case "$out" in
	FAILED:*"Class extends value undefined"*) ;;
	*) fail "broken npm must fail self-check and keep its error output (got: $out)" ;;
esac
case "$(check "$WORK/npm-garbage")" in
	FAILED:*) ;;
	*) fail "npm --version without a version number must fail self-check" ;;
esac
case "$(check "$WORK/does-not-exist")" in
	FAILED:*) ;;
	*) fail "missing npm must fail self-check" ;;
esac

echo "ok"
