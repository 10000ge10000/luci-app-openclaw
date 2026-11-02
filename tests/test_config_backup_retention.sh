#!/bin/sh
# .ipk 安装时的配置备份保留策略: 时间戳备份含 Token，只留最近 5 份，
# 其它名称的备份 (pre-upgrade、user、用户手工备份) 不能被清理。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD="$REPO_ROOT/scripts/build_ipk.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
SNIPPET="$WORK/snippet.sh"
CONF="$WORK/config"
mkdir -p "$CONF"

# 抽出 postinst 中的实际代码，只把 /etc/config 换成沙箱目录
awk '/BAK_FILE="\/etc\/config\/openclaw\./{g=1} g{print} g&&/^[[:space:]]*done$/{exit}' "$BUILD" \
	| sed "s#/etc/config/#$CONF/#g" > "$SNIPPET"
grep -q 'tail -n +6' "$SNIPPET" || fail "cannot extract the backup block from build_ipk.sh"
sed -n '/cp "\$OLD_CONFIG"/p' "$SNIPPET" | grep -q . || fail "cleanup must follow the backup copy"

seed() {
	rm -f "$CONF"/*
	echo live > "$CONF/openclaw"
	for i in $(seq 1 "$1"); do
		echo "old$i" > "$CONF/openclaw.2026010100000$i.bak"
	done
	echo keep > "$CONF/openclaw.pre-upgrade.bak"
	echo keep > "$CONF/openclaw.user.bak"
	echo keep > "$CONF/openclaw.2024-manual.bak"
	echo keep > "$CONF/openclaw.123.bak"
	echo keep > "$CONF/network.20260101000001.bak"
}
run() {
	OLD_CONFIG="$CONF/openclaw" sh "$SNIPPET" >/dev/null
}
count() {
	ls "$CONF" | grep -cE '^openclaw\.[0-9]{14}\.bak$' || true
}

# 已有 8 份再加一份: 只留最新 5 份，且本次备份一定在内
seed 8
run
[ "$(count)" -eq 5 ] || fail "must keep exactly 5 timestamped backups (got $(count))"
for i in 1 2 3 4; do
	[ ! -e "$CONF/openclaw.2026010100000$i.bak" ] || fail "oldest backup $i must be removed"
done
for i in 5 6 7 8; do
	[ -e "$CONF/openclaw.2026010100000$i.bak" ] || fail "recent backup $i must be kept"
done
ls "$CONF" | grep -E '^openclaw\.[0-9]{14}\.bak$' | sort | tail -1 > "$WORK/newest"
[ "$(cat "$CONF/$(cat "$WORK/newest")")" = "live" ] || fail "the backup just taken must be kept"

# 其它名称不受影响，当前配置不变
for f in openclaw.pre-upgrade.bak openclaw.user.bak openclaw.2024-manual.bak openclaw.123.bak network.20260101000001.bak; do
	[ -e "$CONF/$f" ] || fail "$f does not match the timestamp pattern and must survive"
done
[ "$(cat "$CONF/openclaw")" = "live" ] || fail "current config must not change"

# 未超限时不删除
seed 3
run
[ "$(count)" -eq 4 ] || fail "must not remove backups below the limit (got $(count))"

echo "ok"
