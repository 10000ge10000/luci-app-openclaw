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

oc_node_version_ge "24.14.1" "24.14.1" || fail "exact version should satisfy requirement"
oc_node_version_ge "24.14.2" "24.14.1" || fail "newer patch should satisfy requirement"
oc_node_version_ge "25.0.0" "24.14.1" || fail "newer major should satisfy requirement"
if oc_node_version_ge "24.14.0" "24.14.1"; then
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

cat > "$tmpdir/node-legacy-opt" <<'EOF'
#!/bin/sh
/opt/openclaw/node/lib/ld-musl-aarch64.so.1
EOF
chmod +x "$tmpdir/node-legacy-opt"

oc_node_requires_opt_compat "$tmpdir/node-legacy-opt" || fail "legacy opt-bound node binary should be detected"
if oc_node_requires_opt_compat "$tmpdir/node-ok" >/dev/null 2>&1; then
	fail "modern runnable node helper should not require opt compatibility"
fi

cat > "$tmpdir/node-bins-release.json" <<'EOF'
{
  "tag_name": "node-bins",
  "assets": [
    {
      "name": "node-v22.15.1-linux-arm64-musl.tar.xz",
      "browser_download_url": "https://github.com/hotwa/luci-app-openclaw/releases/download/node-bins/node-v22.15.1-linux-arm64-musl.tar.xz"
    },
    {
      "name": "node-v24.14.1-linux-arm64-musl.tar.xz",
      "browser_download_url": "https://github.com/hotwa/luci-app-openclaw/releases/download/node-bins/node-v24.14.1-linux-arm64-musl.tar.xz"
    },
    {
      "name": "node-v22.16.0-linux-x64-musl.tar.xz",
      "browser_download_url": "https://github.com/hotwa/luci-app-openclaw/releases/download/node-bins/node-v22.16.0-linux-x64-musl.tar.xz"
    }
  ]
}
EOF

selected_url=$(oc_select_node_release_asset_url "$tmpdir/node-bins-release.json" "linux-arm64" "24.14.1") || fail "select compatible ARM64 musl asset"
[ "$selected_url" = "https://github.com/hotwa/luci-app-openclaw/releases/download/node-bins/node-v24.14.1-linux-arm64-musl.tar.xz" ] || fail "selected asset should be newest compatible ARM64 musl release"

cat > "$tmpdir/gitea-node-bins-release.json" <<'EOF'
{
  "tag_name": "node-bins",
  "assets": [
    {
      "name": "node-v24.14.1-linux-arm64-musl.tar.xz",
      "browser_download_url": "http://100.64.0.27:8418/lingyuzeng/luci-app-openclaw/releases/download/node-bins/node-v24.14.1-linux-arm64-musl.tar.xz"
    }
  ]
}
EOF

gitea_selected_url=$(oc_select_node_release_asset_url "$tmpdir/gitea-node-bins-release.json" "linux-arm64" "24.14.1") || fail "select compatible ARM64 musl asset from Gitea release JSON"
[ "$gitea_selected_url" = "http://100.64.0.27:8418/lingyuzeng/luci-app-openclaw/releases/download/node-bins/node-v24.14.1-linux-arm64-musl.tar.xz" ] || fail "selected Gitea asset should preserve browser_download_url"

if oc_select_node_release_asset_url "$tmpdir/node-bins-release.json" "linux-arm64" "24.14.2" >/dev/null 2>&1; then
	fail "asset selection should fail when no compatible version exists"
fi

echo "ok"
