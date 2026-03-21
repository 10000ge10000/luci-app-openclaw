#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

BUILD_SCRIPT="$REPO_ROOT/scripts/build-node-musl.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/build-node-musl.yml"
MAKEFILE="$REPO_ROOT/Makefile"
BUILD_IPK="$REPO_ROOT/scripts/build_ipk.sh"
BUILD_RUN="$REPO_ROOT/scripts/build_run.sh"
ENV_SCRIPT="$REPO_ROOT/root/usr/bin/openclaw-env"
CONTROLLER_SCRIPT="$REPO_ROOT/luasrc/controller/openclaw.lua"
BASIC_LUA="$REPO_ROOT/luasrc/model/cbi/openclaw/basic.lua"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq 'patchelf --set-interpreter "/lib/ld-musl-aarch64.so.1"' "$BUILD_SCRIPT" || fail "build script should use system musl loader"
grep -Fq '$ORIGIN/../lib' "$BUILD_SCRIPT" || fail "build script should use relative rpath"
if grep -Fq 'patchelf --set-interpreter "${INSTALL_PREFIX}/lib/ld-musl-aarch64.so.1"' "$BUILD_SCRIPT"; then
	fail "build script should not hardcode interpreter to install prefix"
fi

grep -Fq 'verify_prefix /opt/openclaw/node' "$WORKFLOW" || fail "workflow should verify default install path"
grep -Fq 'verify_prefix /tmp/custom-openclaw-root/openclaw/node' "$WORKFLOW" || fail "workflow should verify custom install path"

grep -Fq 'oc_node_version_ge "$installed_ver" "$node_ver"' "$ENV_SCRIPT" || fail "installer should enforce minimum node version after extraction"
if grep -Fq 'mirror_list="$mirror_list ${NODE_SELF_HOST}/${v1_tarball}"' "$ENV_SCRIPT"; then
	fail "installer should not auto-fallback from V2 to V1 tarball"
fi
grep -Fq 'OPENCLAW_GITHUB_REPO="${OPENCLAW_GITHUB_REPO:-hotwa/luci-app-openclaw}"' "$ENV_SCRIPT" || fail "installer should default to hotwa repo"
grep -Fq 'NODE_SELF_HOST="${NODE_SELF_HOST:-https://github.com/${OPENCLAW_GITHUB_REPO}/releases/download/node-bins}"' "$ENV_SCRIPT" || fail "installer should derive node-bins release URL from hotwa repo"
grep -Fq 'NODE_RELEASE_API="${NODE_RELEASE_API:-https://api.github.com/repos/${OPENCLAW_GITHUB_REPO}/releases/tags/node-bins}"' "$ENV_SCRIPT" || fail "installer should derive node-bins release API from hotwa repo"
grep -Fq 'oc_select_node_release_asset_url' "$ENV_SCRIPT" || fail "installer should dynamically select ARM64 musl asset"
grep -Fq 'arm64_musl_url=$(resolve_arm64_musl_node_url "$node_ver") || exit 1' "$ENV_SCRIPT" || fail "installer should resolve ARM64 musl asset dynamically"
if grep -Fq 'mirror_list="${NODE_SELF_HOST}/${musl_tarball}"' "$ENV_SCRIPT"; then
	fail "installer should not hardcode exact ARM64 musl asset path"
fi

grep -Fq 'openclaw-paths.sh' "$MAKEFILE" || fail "package makefile should install path helper"
grep -Fq 'openclaw-node.sh' "$MAKEFILE" || fail "package makefile should install node helper"
grep -Fq 'openclaw/paths.lua' "$MAKEFILE" || fail "package makefile should install Lua path helper"
grep -Fq '+libstdcpp' "$MAKEFILE" || fail "package makefile should depend on libstdcpp"
if grep -Fq 'libstdcpp6' "$MAKEFILE" "$BUILD_IPK" "$BUILD_RUN"; then
	fail "packaging metadata should not reference libstdcpp6"
fi
grep -Fq 'openclaw-paths.sh' "$BUILD_IPK" || fail "ipk builder should package path helper"
grep -Fq 'openclaw-node.sh' "$BUILD_IPK" || fail "ipk builder should package node helper"
grep -Fq 'openclaw/paths.lua' "$BUILD_IPK" || fail "ipk builder should package Lua path helper"
grep -Fq 'openclaw-paths.sh' "$BUILD_RUN" || fail "run builder should package path helper"
grep -Fq 'openclaw-node.sh' "$BUILD_RUN" || fail "run builder should package node helper"
grep -Fq 'openclaw/paths.lua' "$BUILD_RUN" || fail "run builder should package Lua path helper"
grep -Fq 'local GITHUB_REPO = "hotwa/luci-app-openclaw"' "$CONTROLLER_SCRIPT" || fail "controller should default to hotwa repo"
grep -Fq 'local GITHUB_RELEASES_URL = "https://github.com/" .. GITHUB_REPO .. "/releases"' "$CONTROLLER_SCRIPT" || fail "controller should derive release URLs from hotwa repo"
grep -Fq 'local GITHUB_API_RELEASES_URL = "https://api.github.com/repos/" .. GITHUB_REPO .. "/releases"' "$CONTROLLER_SCRIPT" || fail "controller should derive API URLs from hotwa repo"
grep -Fq "https://github.com/hotwa/luci-app-openclaw/releases/latest" "$BASIC_LUA" || fail "UI should link manual download to hotwa repo"
grep -Fq "ARM64 musl" "$BASIC_LUA" || fail "UI should mention ARM64 musl specific guidance"
if grep -Fq 'NODE_MIRROR=https://npmmirror.com/mirrors/node openclaw-env setup' "$BASIC_LUA"; then
	fail "UI should not recommend NODE_MIRROR for ARM64 musl node download failures"
fi

echo "ok"
