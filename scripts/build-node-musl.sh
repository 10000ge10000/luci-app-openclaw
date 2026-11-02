#!/bin/sh
# ============================================================================
# Node.js ARM64 musl 构建脚本
# 在 Alpine ARM64 Docker 容器内运行
# 
# 环境变量: 
#   NODE_VER (目标版本号，如 24.22.2)
#   BUILD_MODE (unofficial | apk) - 两种模式都严格产出请求版本
#   /output (输出目录)
#
# 打包契约:
#   1. unofficial 模式 (Node 24+ 默认): 转发 unofficial-builds.nodejs.org 官方社区构建的
#      linux-arm64-musl 原始 tarball，按同目录 SHASUMS256.txt 校验后原样发布，不改动内容。
#      Alpine apk 的 nodejs 补丁版本经常与目标版本不一致 (2026-11-01: v3.23/edge 为 24.22.1)，
#      不能用于精确版本。
#   2. apk 模式 (仅 V1 旧版): 使用 Alpine apk 安装 nodejs，必须精确产出 NODE_VER，禁止版本不符改名
#   3. 禁止 cross 模式使用 glibc 替换 ELF interpreter 冒充 musl
#   使用 patchelf 修改 node 二进制的 ELF interpreter 和 rpath，
#   使其直接使用打包的 musl 链接器和共享库，无需 LD_LIBRARY_PATH。
#   这样 process.execPath 返回正确的 node 路径，子进程 fork 也能正常工作。
#   安装路径固定为 /opt/openclaw/node (与 openclaw-env 一致)。
# ============================================================================
set -e

BUILD_MODE="${BUILD_MODE:-unofficial}"

echo "=== Node.js ARM64 musl Build ==="
echo "  Target version: v${NODE_VER}"
echo "  Build mode: ${BUILD_MODE}"

# ── apk 模式: 使用 Alpine 仓库的 Node.js ──
# PKG_TYPE: lts (nodejs) 或 current (nodejs-current)
build_apk() {
	echo ""
	echo "=== Building with Alpine apk mode ==="
	
	# 根据请求的版本选择包
	if [ "${PKG_TYPE}" = "current" ]; then
		echo "Using nodejs-current package for newer version"
		apk add --no-cache nodejs-current npm xz icu-data-full patchelf
	else
		echo "Using nodejs (LTS) package"
		apk add --no-cache nodejs npm xz icu-data-full patchelf
	fi

	ACTUAL_VER=$(node --version | sed 's/^v//')
	echo "Alpine Node.js version: v${ACTUAL_VER} (requested: v${NODE_VER})"

	# 必须产出请求的精确版本；禁止接受 Alpine apk 实际版本与 NODE_VER 不一致后改名发布
	if [ "$ACTUAL_VER" != "$NODE_VER" ]; then
		echo "ERROR: Actual Alpine Node.js version (${ACTUAL_VER}) does not match requested version (${NODE_VER})" >&2
		echo "       Refusing to rename or publish mismatched version" >&2
		exit 1
	fi
	PKG_NAME="node-v${NODE_VER}-linux-arm64-musl"
	PKG_DIR="/tmp/${PKG_NAME}"
	mkdir -p "${PKG_DIR}/bin" "${PKG_DIR}/lib/node_modules" "${PKG_DIR}/include/node"

	# 复制 node 二进制
	cp "$(which node)" "${PKG_DIR}/bin/node"
	chmod +x "${PKG_DIR}/bin/node"

	# 收集 node 依赖的所有共享库 (Alpine node 是动态链接的)
	echo "=== Collecting shared libraries ==="
	LIB_DIR="${PKG_DIR}/lib"
	ldd "$(which node)" 2>/dev/null | while read -r line; do
		lib_path=$(echo "$line" | grep -oE '/[^ ]+\.so[^ ]*' | head -1)
		if [ -n "$lib_path" ] && [ -f "$lib_path" ]; then
			cp -L "$lib_path" "$LIB_DIR/" 2>/dev/null || true
			echo "  + $(basename "$lib_path")"
		fi
	done
	# 确保 musl 动态链接器也在
	if [ -f /lib/ld-musl-aarch64.so.1 ]; then
		cp -L /lib/ld-musl-aarch64.so.1 "$LIB_DIR/" 2>/dev/null || true
		echo "  + ld-musl-aarch64.so.1"
	fi
	echo "Libraries collected: $(ls "$LIB_DIR"/*.so* 2>/dev/null | wc -l) files"

	# 复制 ICU 完整数据
	echo "=== Copying ICU data ==="
	ICU_DAT=$(find /usr/share/icu -name "icudt*.dat" 2>/dev/null | head -1)
	if [ -n "$ICU_DAT" ] && [ -f "$ICU_DAT" ]; then
		mkdir -p "${PKG_DIR}/share/icu"
		cp "$ICU_DAT" "${PKG_DIR}/share/icu/"
		echo "  + $(basename "$ICU_DAT") ($(du -h "$ICU_DAT" | cut -f1))"
	else
		echo "  WARNING: ICU data file not found"
	fi

	# 复制 npm
	if [ -d /usr/lib/node_modules/npm ]; then
		cp -r /usr/lib/node_modules/npm "${PKG_DIR}/lib/node_modules/"
	fi

	# 返回包名供后续使用
	echo "PKG_NAME=${PKG_NAME}" >> /tmp/build_env
	echo "PKG_DIR=${PKG_DIR}" >> /tmp/build_env
}

# ── unofficial 模式: 转发官方社区 musl 构建 ──
# 产物与 unofficial-builds 上的文件逐字节一致，.sha256 边车与上游 SHASUMS256.txt 相同；
# 在 arm64 容器内实际运行一次，确认版本、架构与 Unicode 正则能力。
build_unofficial() {
	echo ""
	echo "=== Fetching unofficial-builds linux-arm64-musl ==="
	apk add --no-cache curl xz libstdc++ >/dev/null

	MIRROR="${NODE_MUSL_MIRROR:-https://unofficial-builds.nodejs.org/download/release}"
	PKG_NAME="node-v${NODE_VER}-linux-arm64-musl"
	TARBALL="${PKG_NAME}.tar.xz"
	WORK=/tmp/unofficial
	rm -rf "$WORK" && mkdir -p "$WORK"

	curl -fsSL --retry 3 -o "$WORK/SHASUMS256.txt" "${MIRROR}/v${NODE_VER}/SHASUMS256.txt"
	EXPECTED=$(awk -v f="$TARBALL" '$2 == f {print $1}' "$WORK/SHASUMS256.txt")
	if [ -z "$EXPECTED" ]; then
		echo "ERROR: ${TARBALL} not listed in upstream SHASUMS256.txt" >&2
		exit 1
	fi
	curl -fsSL --retry 3 -o "$WORK/$TARBALL" "${MIRROR}/v${NODE_VER}/${TARBALL}"
	ACTUAL=$(sha256sum "$WORK/$TARBALL" | awk '{print $1}')
	if [ "$ACTUAL" != "$EXPECTED" ]; then
		echo "ERROR: SHA256 mismatch for ${TARBALL} (actual ${ACTUAL}, expected ${EXPECTED})" >&2
		exit 1
	fi
	echo "  SHA256 OK: ${EXPECTED}"

	tar xJf "$WORK/$TARBALL" -C "$WORK"
	NODE="$WORK/${PKG_NAME}/bin/node"
	GOT=$("$NODE" --version)
	if [ "$GOT" != "v${NODE_VER}" ]; then
		echo "ERROR: extracted node reports ${GOT}, expected v${NODE_VER}" >&2
		exit 1
	fi
	"$NODE" -e "if(process.arch!=='arm64'||process.platform!=='linux')throw new Error('Mismatched architecture: '+process.arch)"
	"$NODE" -e "new RegExp('\\\\p{Extended_Pictographic}','u')"
	"$NODE" "$WORK/${PKG_NAME}/lib/node_modules/npm/bin/npm-cli.js" --version

	cp "$WORK/$TARBALL" "/output/$TARBALL"
	(cd /output && sha256sum "$TARBALL" > "${TARBALL}.sha256")
	ls -lh "/output/$TARBALL"
	echo "=== Done: ${TARBALL} (upstream unofficial-builds, unmodified) ==="
}

# ── 禁止使用 glibc 二进制仅替换 ELF interpreter 冒充 musl ──
build_cross() {
	echo "ERROR: cross mode (glibc binary with patched ELF interpreter) is forbidden" >&2
	echo "       Cannot impersonate musl using glibc binaries" >&2
	exit 1
}

# ── 公共步骤: patchelf 和打包 ──
finalize_package() {
	. /tmp/build_env

	# 用 patchelf 修改 node 二进制
	echo "=== Patching ELF binary ==="
	patchelf --set-interpreter "/lib/ld-musl-aarch64.so.1" "${PKG_DIR}/bin/node"
	patchelf --set-rpath '$ORIGIN/../lib' "${PKG_DIR}/bin/node"
	echo "  interpreter: /lib/ld-musl-aarch64.so.1"
	echo "  rpath: \$ORIGIN/../lib"

	# 创建 node wrapper 脚本
	cat > "${PKG_DIR}/bin/node-wrapper" << 'NODEWRAPPER'
#!/bin/sh
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
export NODE_ICU_DATA="${SELF_DIR}/../share/icu"
exec "${SELF_DIR}/node" "$@"
NODEWRAPPER
	chmod +x "${PKG_DIR}/bin/node-wrapper"

	# 创建 npm wrapper
	cat > "${PKG_DIR}/bin/npm" << 'NPMWRAPPER'
#!/bin/sh
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
export NODE_ICU_DATA="${SELF_DIR}/../share/icu"
exec "${SELF_DIR}/node" "${SELF_DIR}/../lib/node_modules/npm/bin/npm-cli.js" "$@"
NPMWRAPPER

	# 创建 npx wrapper
	cat > "${PKG_DIR}/bin/npx" << 'NPXWRAPPER'
#!/bin/sh
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
export NODE_ICU_DATA="${SELF_DIR}/../share/icu"
exec "${SELF_DIR}/node" "${SELF_DIR}/../lib/node_modules/npm/bin/npx-cli.js" "$@"
NPXWRAPPER
	chmod +x "${PKG_DIR}/bin/npm" "${PKG_DIR}/bin/npx"

	verify_prefix() {
		local prefix="$1"
		echo "=== Verifying prefix: ${prefix} ==="
		rm -rf "$prefix"
		mkdir -p "$prefix"
		cp -a "${PKG_DIR}"/* "$prefix/"
		"${prefix}/bin/node" --version
		"${prefix}/bin/node" -e "console.log('execPath:', process.execPath)"
		"${prefix}/bin/node" -e "console.log(process.arch, process.platform, process.versions.modules)"
		"${prefix}/bin/node" -e "if(process.arch!=='arm64'||process.platform!=='linux')throw new Error('Mismatched architecture: '+process.arch)"
		NODE_ICU_DATA="${prefix}/share/icu" "${prefix}/bin/npm" --version 2>/dev/null || echo "npm needs ICU data"
		rm -rf "$prefix"
	}

	verify_prefix /opt/openclaw/node
	verify_prefix /tmp/custom-openclaw-root/openclaw/node

	# 打包
	echo "=== Creating tarball ==="
	cd /tmp
	tar cJf "/output/${PKG_NAME}.tar.xz" "${PKG_NAME}"
	if command -v sha256sum >/dev/null 2>&1; then
		(cd /output && sha256sum "${PKG_NAME}.tar.xz" > "${PKG_NAME}.tar.xz.sha256")
	fi
	ls -lh "/output/${PKG_NAME}.tar.xz"
	echo "=== Done: ${PKG_NAME}.tar.xz ==="
}

# ── 主入口 ──
rm -f /tmp/build_env

case "$BUILD_MODE" in
	unofficial)
		build_unofficial
		exit 0
		;;
	apk)
		build_apk
		;;
	cross)
		build_cross
		;;
	*)
		echo "ERROR: Unknown BUILD_MODE: $BUILD_MODE"
		exit 1
		;;
esac

finalize_package
