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

export OPENCLAW_OPT_COMPAT_ROOT="$tmpdir/compat-opt"
target_root="$tmpdir/install-root/openclaw"
mkdir -p "$target_root"

oc_ensure_opt_compat_link "$target_root" || fail "compat symlink should be created for custom install root"
[ -L "$OPENCLAW_OPT_COMPAT_ROOT/openclaw" ] || fail "compat symlink should exist"
[ "$(readlink "$OPENCLAW_OPT_COMPAT_ROOT/openclaw")" = "$target_root" ] || fail "compat symlink should point to install root"

oc_ensure_opt_compat_link "$target_root" || fail "compat symlink should be idempotent"

conflict_root="$tmpdir/conflict-openclaw"
mkdir -p "$conflict_root"
rm -f "$OPENCLAW_OPT_COMPAT_ROOT/openclaw"
ln -s "$conflict_root" "$OPENCLAW_OPT_COMPAT_ROOT/openclaw"
if oc_ensure_opt_compat_link "$target_root" >/dev/null 2>&1; then
	fail "compat symlink should fail when pointing at another install root"
fi

echo "ok"
