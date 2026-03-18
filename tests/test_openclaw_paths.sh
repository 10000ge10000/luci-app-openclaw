#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$REPO_ROOT/root/usr/libexec/openclaw-paths.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

oc_load_paths "/mnt/emmc/"
[ "$OPENCLAW_INSTALL_ROOT" = "/mnt/emmc" ] || fail "normalized install root"
[ "$OC_ROOT" = "/mnt/emmc/openclaw" ] || fail "derived OpenClaw root"
[ "$NODE_BASE" = "/mnt/emmc/openclaw/node" ] || fail "derived node path"
[ "$OC_GLOBAL" = "/mnt/emmc/openclaw/global" ] || fail "derived global path"
[ "$OC_DATA" = "/mnt/emmc/openclaw/data" ] || fail "derived data path"

oc_load_paths "relative/path"
[ "$OPENCLAW_INSTALL_ROOT" = "/opt" ] || fail "fallback install root"
[ "$OC_ROOT" = "/opt/openclaw" ] || fail "fallback OpenClaw root"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT INT TERM
existing=$(oc_find_existing_path "$tmpdir/missing/nested")
[ "$existing" = "$tmpdir" ] || fail "nearest existing path"

echo "ok"
