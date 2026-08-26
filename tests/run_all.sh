#!/bin/sh
# 运行全部契约测试。
# 用法: sh tests/run_all.sh
# 必须在仓库根目录执行 (部分测试依赖相对路径 ./root/...)。
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT" || exit 1

pass=0
fail=0
failed_list=""

for t in tests/test_*.sh; do
	[ -f "$t" ] || continue
	printf '%-46s' "$t"
	if out=$(sh "$t" 2>&1); then
		echo "ok"
		pass=$((pass + 1))
	else
		echo "FAIL"
		echo "$out" | sed 's/^/    /'
		fail=$((fail + 1))
		failed_list="${failed_list} ${t}"
	fi
done

# Lua 测试 (可选: 仅在有 lua 解释器时运行)
for t in tests/test_*.lua; do
	[ -f "$t" ] || continue
	lua_bin=""
	for cand in lua5.1 lua; do
		command -v "$cand" >/dev/null 2>&1 && { lua_bin="$cand"; break; }
	done
	printf '%-46s' "$t"
	if [ -z "$lua_bin" ]; then
		echo "SKIP (no lua interpreter)"
		continue
	fi
	if out=$("$lua_bin" "$t" 2>&1); then
		echo "ok"
		pass=$((pass + 1))
	else
		echo "FAIL"
		echo "$out" | sed 's/^/    /'
		fail=$((fail + 1))
		failed_list="${failed_list} ${t}"
	fi
done

echo ""
echo "passed=${pass} failed=${fail}"
if [ "$fail" -ne 0 ]; then
	echo "failed tests:${failed_list}" >&2
	exit 1
fi
echo "ALL OK"
