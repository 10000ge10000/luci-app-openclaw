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
# 当前 Node (与 openclaw-env 的 NODE_VERSION_V2 一致) 走 unofficial-builds 转发模式;
# Alpine apk 的补丁版本经常与目标不符，只保留给 V1 旧版。
NODE_V2=$(sed -n 's/^NODE_VERSION_V2="\([0-9.]*\)"$/\1/p' "$ENV_SCRIPT")
[ -n "$NODE_V2" ] || fail "cannot read NODE_VERSION_V2 from openclaw-env"
grep -Fq "NODE_VER=\"$NODE_V2\"" "$WORKFLOW" || fail "workflow V2 must build NODE_VERSION_V2 ($NODE_V2)"
grep -Fq 'BUILD_MODE=unofficial' "$WORKFLOW" || fail "workflow V2 should forward the unofficial-builds ARM64 musl tarball"
grep -Fq 'BUILD_MODE=unofficial' "$REPO_ROOT/.github/workflows/build.yml" || fail "release workflow should forward the unofficial-builds ARM64 musl tarball"
if grep -Fq 'BUILD_MODE=apk' "$REPO_ROOT/.github/workflows/build.yml"; then
	fail "release workflow must not use apk mode for NODE_VERSION_V2 (Alpine patch version drifts)"
fi
grep -Fq "node-v${NODE_V2}-linux-arm64-musl.tar.xz" "$WORKFLOW" || fail "workflow should document node-v${NODE_V2}-linux-arm64-musl.tar.xz"
# unofficial 模式必须按上游 SHASUMS256.txt 校验并实际运行一次
grep -Fq 'SHASUMS256.txt' "$BUILD_SCRIPT" || fail "unofficial mode must verify against upstream SHASUMS256.txt"
grep -Fq 'SHA256 mismatch for' "$BUILD_SCRIPT" || fail "unofficial mode must reject a hash mismatch"
grep -Fq 'extracted node reports' "$BUILD_SCRIPT" || fail "unofficial mode must run the extracted node and check its version"

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
