#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_SCRIPT="$REPO_ROOT/scripts/build-node-musl.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/build-node-musl.yml"
ENV_SCRIPT="$REPO_ROOT/root/usr/bin/openclaw-env"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq 'patchelf --set-interpreter "/lib/ld-musl-aarch64.so.1"' "$BUILD_SCRIPT" || fail "build script should use system musl loader"
grep -Fq '$ORIGIN/../lib' "$BUILD_SCRIPT" || fail "build script should use relative rpath"
if grep -Fq 'patchelf --set-interpreter "${INSTALL_PREFIX}/lib/ld-musl-aarch64.so.1"' "$BUILD_SCRIPT"; then
	fail "build script should not hardcode interpreter to install prefix"
fi

grep -Fq 'verify_prefix /opt/openclaw/node' "$BUILD_SCRIPT" || fail "build script should verify default install path"
grep -Fq 'verify_prefix /tmp/custom-openclaw-root/openclaw/node' "$BUILD_SCRIPT" || fail "build script should verify custom install path"
grep -Fq 'NODE_VER="22.23.1"' "$WORKFLOW" || fail "workflow should build current musl-compatible Node.js"
grep -Fq 'BUILD_MODE=apk' "$WORKFLOW" || fail "workflow should use apk mode for ARM64 musl package"
grep -Fq 'PKG_TYPE=lts' "$WORKFLOW" || fail "workflow should use Alpine LTS Node.js package"
grep -Fq 'Generate SHA256SUMS' "$WORKFLOW" || fail "Node Release must publish a SHA256SUMS asset"
grep -Fq 'dist/SHA256SUMS' "$WORKFLOW" || fail "Node Release must upload the SHA256SUMS asset"

grep -Fq 'oc_node_version_ge "$current_ver" "$node_ver"' "$ENV_SCRIPT" || fail "installer should require installed Node.js to satisfy target version"
grep -Fq '拒绝使用该镜像' "$ENV_SCRIPT" || fail "installer must reject Node mirrors without SHA256"
if grep -Fq 'v1_tarball' "$ENV_SCRIPT"; then
	fail "installer should not auto-fallback from current Node.js to legacy tarball"
fi

echo "ok"
