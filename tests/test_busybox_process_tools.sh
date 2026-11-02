#!/bin/sh
# BusyBox 进程工具兼容测试。
#
# 背景: BusyBox 1.37 的 pgrep 没有 -u，部分固件没有 pkill。调用处都带 2>/dev/null，
# 失败时没有任何提示，清理逻辑直接失效。替身 ls 把后台进程列成 /proc 条目，
# 只会向这些测试自己启动的进程发信号。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INITD="$REPO_ROOT/root/etc/init.d/openclaw"
CONTROLLER="$REPO_ROOT/luasrc/controller/openclaw.lua"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

# ── 静态: 运行时代码不得再依赖 pgrep -u 和 pkill ──
if grep -rnE 'pgrep( -[a-zA-Z]+)* -u[ =]|(^|[^a-z_-])pkill( |$)' \
	"$REPO_ROOT/root" "$REPO_ROOT/luasrc" "$REPO_ROOT/scripts"; then
	fail "runtime code must not use pgrep -u or pkill (missing on BusyBox)"
fi
grep -q "openclaw-\[w\]eixin" "$CONTROLLER" \
	|| fail "wechat login cleanup must not match the shell running it"
grep -q 'ls -ld /proc/\[0-9\]\* 2>/dev/null | awk .*xargs -r kill -9' "$CONTROLLER" \
	|| fail "uninstall must enumerate service user processes through /proc"

# ── 行为: 从 init.d 取出真实函数执行 ──
WORK=$(mktemp -d)
GENTLE="" STUBBORN="" BYSTANDER=""
cleanup() {
	for p in "$GENTLE" "$STUBBORN" "$BYSTANDER"; do
		[ -z "$p" ] || kill -9 "$p" 2>/dev/null || true
	done
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

sed -n '/^_oc_user_pids()/,/^}/p; /^_oc_stop_user_procs()/,/^}/p' "$INITD" > "$WORK/funcs.sh"
grep -q '_oc_stop_user_procs' "$WORK/funcs.sh" || fail "init.d must define _oc_stop_user_procs"

# 双重 fork 交给 init 回收，否则已退出的进程是僵尸，kill -0 仍会成功
( sleep 60 >/dev/null 2>&1 & echo $! > "$WORK/gentle.pid" )
( sh -c 'trap "" TERM; while :; do sleep 1; done' >/dev/null 2>&1 & echo $! > "$WORK/stubborn.pid" )
( sleep 60 >/dev/null 2>&1 & echo $! > "$WORK/bystander.pid" )
GENTLE=$(cat "$WORK/gentle.pid")
STUBBORN=$(cat "$WORK/stubborn.pid")
BYSTANDER=$(cat "$WORK/bystander.pid")

mkdir -p "$WORK/bin"
cat > "$WORK/bin/ls" <<EOF
#!/bin/sh
# 只列出还活着的进程，和真实 /proc 一样
for p in $GENTLE $STUBBORN; do
	kill -0 "\$p" 2>/dev/null && echo "dr-xr-xr-x 9 openclaw openclaw 0 Nov  2 16:00 /proc/\$p"
done
echo "dr-xr-xr-x 9 root root 0 Nov  2 16:00 /proc/$BYSTANDER"
exit 0
EOF
chmod +x "$WORK/bin/ls"

# 枚举只返回服务用户的进程
PIDS=$(PATH="$WORK/bin:$PATH" sh -c '. "$1"; _oc_user_pids' sh "$WORK/funcs.sh" | sort | tr '\n' ' ')
EXPECT=$(printf '%s\n%s\n' "$GENTLE" "$STUBBORN" | sort | tr '\n' ' ')
[ "$PIDS" = "$EXPECT" ] || fail "_oc_user_pids must list only service user processes (got: $PIDS, want: $EXPECT)"

# 能响应 TERM 的进程先退出，忽略 TERM 的进程最后被 KILL，其它用户的进程不受影响
PATH="$WORK/bin:$PATH" sh -c '. "$1"; _oc_stop_user_procs' sh "$WORK/funcs.sh"
sleep 1
if kill -0 "$GENTLE" 2>/dev/null; then fail "service user process must receive SIGTERM"; fi
if kill -0 "$STUBBORN" 2>/dev/null; then fail "process ignoring SIGTERM must be killed after the grace period"; fi
kill -0 "$BYSTANDER" 2>/dev/null || fail "processes owned by other users must not be touched"

echo "ok"
