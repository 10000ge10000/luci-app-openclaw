#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$REPO_ROOT/root/usr/libexec/openclaw-node.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

normalized=$(oc_normalize_node_version "v22.16.1") || fail "normalize valid version"
[ "$normalized" = "22.16.1" ] || fail "normalized version value"

if oc_normalize_node_version "broken-version" >/dev/null 2>&1; then
	fail "invalid version should not normalize"
fi

oc_node_version_ge "22.16.0" "22.16.0" || fail "exact version should satisfy requirement"
oc_node_version_ge "22.16.1" "22.16.0" || fail "newer patch should satisfy requirement"
oc_node_version_ge "23.0.0" "22.16.0" || fail "newer major should satisfy requirement"
if oc_node_version_ge "22.15.1" "22.16.0"; then
	fail "older minor version should not satisfy requirement"
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT INT TERM

cat > "$tmpdir/node-ok" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
	echo "v22.16.2"
	exit 0
fi
exit 1
EOF
chmod +x "$tmpdir/node-ok"

cat > "$tmpdir/node-bad" <<'EOF'
#!/bin/sh
exit 127
EOF
chmod +x "$tmpdir/node-bad"

read_ver=$(oc_read_node_version "$tmpdir/node-ok") || fail "read runnable node version"
[ "$read_ver" = "22.16.2" ] || fail "read version value"

if oc_read_node_version "$tmpdir/node-bad" >/dev/null 2>&1; then
	fail "broken node binary should not be accepted"
fi

echo "ok"
