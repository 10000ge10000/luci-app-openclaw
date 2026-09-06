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
grep -Fq 'NODE_VER="22.23.2"' "$WORKFLOW" || fail "workflow should build current musl-compatible Node.js"
grep -Fq 'BUILD_MODE=apk' "$WORKFLOW" || fail "workflow should use apk mode for ARM64 musl package"
grep -Fq 'PKG_TYPE=lts' "$WORKFLOW" || fail "workflow should use Alpine LTS Node.js package"
grep -Fq 'node-v22.23.2-linux-arm64-musl.tar.xz' "$WORKFLOW" || fail "workflow should name ARM64 musl artifact node-v22.23.2-linux-arm64-musl.tar.xz"

# 校验构建脚本行为契约:
# 1. 实际版本与请求版本不一致时必须报错退出，不得改名发布
grep -Fq 'Actual Alpine Node.js version (${ACTUAL_VER}) does not match requested version (${NODE_VER})' "$BUILD_SCRIPT" || fail "build script must reject version mismatch in apk mode"
# 2. 禁止使用 glibc 二进制替换 ELF interpreter 冒充 musl
grep -Fq 'cross mode (glibc binary with patched ELF interpreter) is forbidden' "$BUILD_SCRIPT" || fail "build script must forbid fake glibc cross mode"

grep -Fq 'oc_node_version_ge "$current_ver" "$node_ver"' "$ENV_SCRIPT" || fail "installer should require installed Node.js to satisfy target version"
if grep -Fq 'v1_tarball' "$ENV_SCRIPT"; then
	fail "installer should not auto-fallback from current Node.js to legacy tarball"
fi

echo "ok"
