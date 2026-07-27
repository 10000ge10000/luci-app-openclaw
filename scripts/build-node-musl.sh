#!/bin/sh
# ============================================================================
# Node.js ARM64 musl 构建脚本
# 在 Alpine ARM64 Docker 容器内运行
# 
# 环境变量: 
#   NODE_VER (目标版本号)
#   BUILD_MODE (apk|unofficial|cross) - apk: 使用 Alpine apk,
#     unofficial: 下载 Node.js 官方 unofficial-builds 的 ARM64 musl 资产,
#     cross: 从官方 glibc 版本交叉编译
#   /output (输出目录)
#
# 打包策略:
#   1. apk 模式: 使用 Alpine apk 安装 nodejs，版本受限于 Alpine 仓库
#   2. unofficial 模式: 下载并校验 Node.js 官方 ARM64 musl 资产
#   3. cross 模式: 从 Node.js 官方下载 glibc 版本，转换为 musl
#   使用 patchelf 修改 node 二进制的 ELF interpreter 和 rpath，
#   使其直接使用打包的 musl 链接器和共享库，无需 LD_LIBRARY_PATH。
#   这样 process.execPath 返回正确的 node 路径，子进程 fork 也能正常工作。
#   安装路径固定为 /opt/openclaw/node (与 openclaw-env 一致)。
# ============================================================================
set -e

BUILD_MODE="${BUILD_MODE:-apk}"

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

	# 资产文件名必须与请求版本完全一致；否则安装器按版本下载时会得到 404。
	# Alpine 仓库漂移时直接失败，避免把错误版本静默发布成目标版本资产。
	if [ "$ACTUAL_VER" != "$NODE_VER" ]; then
		echo "ERROR: Actual version (${ACTUAL_VER}) differs from requested (${NODE_VER})" >&2
		echo "       Refusing to publish a wrongly named Node.js asset." >&2
		exit 1
	fi
	PKG_NAME="node-v${ACTUAL_VER}-linux-arm64-musl"
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

# ── unofficial 模式: 下载 Node.js 官方 unofficial-builds ARM64 musl 资产 ──
build_unofficial() {
	echo ""
	echo "=== Building from Node.js unofficial-builds ARM64 musl ==="
	apk add --no-cache xz curl ca-certificates patchelf libstdc++ libgcc

	case "${NODE_VER}" in
		[0-9]*.[0-9]*.[0-9]*) ;;
		*) echo "ERROR: invalid Node.js version: ${NODE_VER}" >&2; exit 1 ;;
	esac

	TMP_DIR=$(mktemp -d /tmp/openclaw-node.XXXXXX)
	TARBALL="node-v${NODE_VER}-linux-arm64-musl.tar.xz"
	BASE_URL="https://unofficial-builds.nodejs.org/download/release/v${NODE_VER}"
	trap 'rm -rf "${TMP_DIR}"' EXIT

	echo "=== Downloading ${TARBALL} ==="
	curl -fSL --retry 3 -o "${TMP_DIR}/${TARBALL}" "${BASE_URL}/${TARBALL}"
	curl -fSL --retry 3 -o "${TMP_DIR}/SHASUMS256.txt" "${BASE_URL}/SHASUMS256.txt"
	EXPECTED_SHA=$(awk -v file="${TARBALL}" '$2 == file || $2 == "*" file { print $1; exit }' "${TMP_DIR}/SHASUMS256.txt")
	[ -n "${EXPECTED_SHA}" ] || { echo "ERROR: SHA256 entry not found for ${TARBALL}" >&2; exit 1; }
	ACTUAL_SHA=$(sha256sum "${TMP_DIR}/${TARBALL}" | awk '{print $1}')
	[ "${ACTUAL_SHA}" = "${EXPECTED_SHA}" ] || { echo "ERROR: SHA256 mismatch for ${TARBALL}" >&2; exit 1; }

	tar -xJf "${TMP_DIR}/${TARBALL}" -C "${TMP_DIR}"
	SRC_DIR="${TMP_DIR}/node-v${NODE_VER}-linux-arm64-musl"
	[ -x "${SRC_DIR}/bin/node" ] || { echo "ERROR: Node.js binary missing from ${TARBALL}" >&2; exit 1; }

	PKG_NAME="node-v${NODE_VER}-linux-arm64-musl"
	PKG_DIR="/tmp/${PKG_NAME}"
	rm -rf "${PKG_DIR}"
	mkdir -p "${PKG_DIR}/bin" "${PKG_DIR}/lib" "${PKG_DIR}/share/icu"
	cp "${SRC_DIR}/bin/node" "${PKG_DIR}/bin/node"
	chmod +x "${PKG_DIR}/bin/node"
	if [ -d "${SRC_DIR}/lib/node_modules/npm" ]; then
		mkdir -p "${PKG_DIR}/lib/node_modules"
		cp -r "${SRC_DIR}/lib/node_modules/npm" "${PKG_DIR}/lib/node_modules/"
	fi
	ICU_DAT=$(find "${SRC_DIR}" -name "icudt*.dat" 2>/dev/null | head -1)
	if [ -n "${ICU_DAT}" ] && [ -f "${ICU_DAT}" ]; then
		cp "${ICU_DAT}" "${PKG_DIR}/share/icu/"
	fi

	# unofficial-builds 的 ARM64 musl 二进制仍依赖 libstdc++/libgcc；把依赖
	# 连同动态链接器放进包，避免不同 OpenWrt 固件的库版本漂移。
	LIB_DIR="${PKG_DIR}/lib"
	ldd "${PKG_DIR}/bin/node" 2>/dev/null | while read -r line; do
		lib_path=$(echo "$line" | grep -oE '/[^ ]+\.so[^ ]*' | head -1)
		if [ -n "$lib_path" ] && [ -f "$lib_path" ]; then
			cp -L "$lib_path" "$LIB_DIR/" 2>/dev/null || true
		fi
	done
	if [ -f /lib/ld-musl-aarch64.so.1 ]; then
		cp -L /lib/ld-musl-aarch64.so.1 "${LIB_DIR}/"
	fi

	echo "PKG_NAME=${PKG_NAME}" >> /tmp/build_env
	echo "PKG_DIR=${PKG_DIR}" >> /tmp/build_env
}

# ── cross 模式: 从 Node.js 官方 glibc 版本交叉编译 ──
build_cross() {
	echo ""
	echo "=== Building with cross-compilation mode ==="
	apk add --no-cache xz patchelf curl wget ca-certificates

	# 下载 Node.js 官方 ARM64 glibc 版本
	NODE_TARBALL="node-v${NODE_VER}-linux-arm64.tar.xz"
	NODE_URL="https://nodejs.org/dist/v${NODE_VER}/${NODE_TARBALL}"

	echo "=== Downloading Node.js v${NODE_VER} ARM64 glibc ==="
	cd /tmp
	if ! curl -fSL -o "$NODE_TARBALL" "$NODE_URL"; then
		echo "ERROR: Failed to download Node.js from $NODE_URL"
		exit 1
	fi

	# 解压
	echo "=== Extracting Node.js ==="
	rm -rf "node-v${NODE_VER}-linux-arm64" 2>/dev/null || true
	tar xf "$NODE_TARBALL"
	SRC_DIR="node-v${NODE_VER}-linux-arm64"

	# 创建输出目录
	PKG_NAME="node-v${NODE_VER}-linux-arm64-musl"
	PKG_DIR="/tmp/${PKG_NAME}"
	rm -rf "$PKG_DIR" 2>/dev/null || true
	mkdir -p "${PKG_DIR}/bin" "${PKG_DIR}/lib" "${PKG_DIR}/share/icu"

	# 复制 node 二进制
	echo "=== Copying Node.js binary ==="
	cp "${SRC_DIR}/bin/node" "${PKG_DIR}/bin/node"
	chmod +x "${PKG_DIR}/bin/node"

	# 复制 npm
	if [ -d "${SRC_DIR}/lib/node_modules/npm" ]; then
		mkdir -p "${PKG_DIR}/lib/node_modules"
		cp -r "${SRC_DIR}/lib/node_modules/npm" "${PKG_DIR}/lib/node_modules/"
	fi

	# 复制 ICU 数据
	ICU_DAT=$(find "${SRC_DIR}" -name "icudt*.dat" 2>/dev/null | head -1)
	if [ -n "$ICU_DAT" ] && [ -f "$ICU_DAT" ]; then
		cp "$ICU_DAT" "${PKG_DIR}/share/icu/"
		echo "  + ICU data: $(basename "$ICU_DAT")"
	fi

	# ── 关键步骤: musl 库收集 ──
	echo "=== Converting to musl libc ==="

	# 复制 musl 动态链接器
	if [ -f /lib/ld-musl-aarch64.so.1 ]; then
		cp -L /lib/ld-musl-aarch64.so.1 "${PKG_DIR}/lib/"
		echo "  + ld-musl-aarch64.so.1"
	else
		echo "ERROR: musl dynamic linker not found"
		exit 1
	fi

	# 收集 musl 版本的依赖库
	# Node.js 官方 ARM64 版本依赖: libcrypto, libssl, libz, libstdc++, libgcc_s
	# 这些库需要从 Alpine (musl) 版本获取
	echo "=== Collecting musl libraries ==="
	LIB_DIR="${PKG_DIR}/lib"
	
	# 安装必要的库包
	apk add --no-cache libcrypto3 libssl3 zlib libstdc++ libgcc
	
	# 复制库文件
	for lib in libcrypto.so.3 libssl.so.3 libz.so.1 libstdc++.so.6 libgcc_s.so.1; do
		for libpath in /usr/lib/$lib /lib/$lib; do
			if [ -f "$libpath" ]; then
				cp -L "$libpath" "$LIB_DIR/" 2>/dev/null || true
				echo "  + $lib"
				break
			fi
		done
	done

	# 收集所有 musl 库的依赖
	for lib in "$LIB_DIR"/*.so*; do
		[ -f "$lib" ] || continue
		ldd "$lib" 2>/dev/null | while read -r line; do
			lib_path=$(echo "$line" | grep -oE '/[^ ]+\.so[^ ]*' | head -1)
			if [ -n "$lib_path" ] && [ -f "$lib_path" ]; then
				lib_name=$(basename "$lib_path")
				[ -f "$LIB_DIR/$lib_name" ] || cp -L "$lib_path" "$LIB_DIR/" 2>/dev/null || true
			fi
		done
	done

	echo "Libraries collected: $(ls "$LIB_DIR"/*.so* 2>/dev/null | wc -l) files"

	# 返回包名供后续使用
	echo "PKG_NAME=${PKG_NAME}" >> /tmp/build_env
	echo "PKG_DIR=${PKG_DIR}" >> /tmp/build_env
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
		NODE_ICU_DATA="${prefix}/share/icu" "${prefix}/bin/npm" --version 2>/dev/null || echo "npm needs ICU data"
		rm -rf "$prefix"
	}

	verify_prefix /opt/openclaw/node
	verify_prefix /tmp/custom-openclaw-root/openclaw/node

	# 打包
	echo "=== Creating tarball ==="
	cd /tmp
	tar cJf "/output/${PKG_NAME}.tar.xz" "${PKG_NAME}"
	ls -lh "/output/${PKG_NAME}.tar.xz"
	echo "=== Done: ${PKG_NAME}.tar.xz ==="
}

# ── 主入口 ──
rm -f /tmp/build_env

case "$BUILD_MODE" in
	apk)
			build_apk
			;;
		unofficial)
			build_unofficial
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
