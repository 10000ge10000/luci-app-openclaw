#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

OC_CONFIG_SCRIPT="$REPO_ROOT/root/usr/share/openclaw/oc-config.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq "d.plugins.installs" "$OC_CONFIG_SCRIPT" || fail "channel cleanup should inspect plugins.installs"
grep -Fq "delete d.plugins.installs[p];" "$OC_CONFIG_SCRIPT" || fail "channel cleanup should remove stale plugin install metadata"
grep -Fq 'rm -rf "${feishu_ext_dir}"' "$OC_CONFIG_SCRIPT" || fail "channel cleanup should remove stale feishu plugin directory"
grep -Fq 'rm -rf "${qqbot_ext_dir}"' "$OC_CONFIG_SCRIPT" || fail "channel cleanup should remove stale qqbot plugin directory"

echo "ok"
