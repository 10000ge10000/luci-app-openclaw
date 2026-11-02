#!/bin/sh
# 可移植超时 helper 行为测试 (#110)。
#
# 背景: iStoreOS / Kwrt 等固件的 BusyBox 没有 timeout applet，
# 设备配对接口直接调用 `timeout 20 node ...` 时报 "sh: timeout: not found"。
# 本测试从控制器中提取 OC_PORTABLE_TIMEOUT_SH，在隐藏 timeout(1) 的 PATH 中实际执行，
# 校验: 正常退出码透传、超时返回 124、超时后不会因残留 sleep 持有输出管道而挂起。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONTROLLER="$REPO_ROOT/luasrc/controller/openclaw.lua"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# 提取 Lua 字符串拼接并还原为 shell 文本
sed -n '/^local OC_PORTABLE_TIMEOUT_SH =/,/return \$_oc_r; }; "$/p' "$CONTROLLER" \
	| sed '1d' \
	| sed -e 's/^[[:space:]]*"//' -e 's/" \.\.[[:space:]]*$//' -e 's/"$//' -e 's/\\"/"/g' \
	| tr -d '\n' > "$TMP_DIR/helper.sh"
grep -q '_oc_timeout()' "$TMP_DIR/helper.sh" || fail "cannot extract OC_PORTABLE_TIMEOUT_SH from controller"

# 构造不含 timeout 的最小 PATH
BIN="$TMP_DIR/bin"
mkdir -p "$BIN"
for tool in sh sleep date rm cat; do
	src=$(command -v "$tool" 2>/dev/null || true)
	[ -n "$src" ] || fail "missing host tool: $tool"
	ln -s "$src" "$BIN/$tool"
done
[ ! -e "$BIN/timeout" ] || fail "test PATH must not contain timeout"

run_helper() {
	PATH="$BIN" sh -c ". \"$TMP_DIR/helper.sh\"; $1"
}

PATH="$BIN" sh -c 'command -v timeout' >/dev/null 2>&1 && fail "timeout unexpectedly visible in test PATH"

# 1. 正常完成: 退出码与输出透传
out=$(run_helper '_oc_timeout 5 sh -c "echo hello; exit 3"; echo "rc=$?"')
echo "$out" | grep -q '^hello$' || fail "stdout must pass through (got: $out)"
echo "$out" | grep -q '^rc=3$' || fail "exit code must pass through (got: $out)"

# 2. 超时: 返回 124，且命令替换在合理时间内返回 (不被残留 sleep 卡住)
start=$(date +%s)
out=$(run_helper '_oc_timeout 1 sleep 30; echo "rc=$?"')
elapsed=$(( $(date +%s) - start ))
echo "$out" | grep -q '^rc=124$' || fail "timeout must return 124 (got: $out)"
[ "$elapsed" -le 6 ] || fail "timeout helper must not block caller pipe (elapsed ${elapsed}s)"

# 3. 快速完成后不残留超时标记，且 2>&1 捕获的输出只有命令本身的输出
#    (控制器以 2>&1 捕获 devices list 的 JSON，任何 "Terminated" 作业通知都会破坏解析)
out=$(run_helper '_oc_timeout 3 sh -c "echo [1]"' 2>&1)
[ "$out" = "[1]" ] || fail "captured output must contain only command output (got: $out)"
out=$(run_helper '_oc_timeout 3 sh -c "exit 0"; echo "rc=$?"')
echo "$out" | grep -q '^rc=0$' || fail "fast command must return 0 (got: $out)"
start=$(date +%s)
out=$(run_helper '_oc_timeout 3 sh -c "exit 0" | cat; echo done')
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 2 ] || fail "watchdog must not hold the output pipe after fast completion (elapsed ${elapsed}s)"

echo "ok"
