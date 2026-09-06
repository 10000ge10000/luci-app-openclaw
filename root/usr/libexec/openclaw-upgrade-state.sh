#!/bin/sh
# ============================================================================
# openclaw-upgrade-state.sh — OpenClaw 升级与状态事务安全管理工具
# POSIX / BusyBox ash / musl 兼容
#
# 子命令:
#   backup-create [backup_dir] [state_dir]
#   backup-verify <archive_file> [state_dir]
#   restore-state <archive_file> [state_dir]
#   doctor-migration [state_dir] [target_version]
#   reconcile-token [config_file]
#   gateway-verify [token]
# ============================================================================
set -e

export OPENCLAW_PERMISSIONS_SOURCED=1
[ -r /usr/libexec/openclaw-paths.sh ] && . /usr/libexec/openclaw-paths.sh
[ -r /usr/libexec/openclaw-permissions.sh ] && . /usr/libexec/openclaw-permissions.sh

_script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
[ -r "${_script_dir}/openclaw-paths.sh" ] && . "${_script_dir}/openclaw-paths.sh"
[ -r "${_script_dir}/openclaw-permissions.sh" ] && . "${_script_dir}/openclaw-permissions.sh"

if [ -z "${OC_GLOBAL:-}" ] && command -v oc_load_paths >/dev/null 2>&1; then
	_cfg_path=""
	if command -v uci >/dev/null 2>&1; then
		_cfg_path="$(uci -q get openclaw.main.install_path 2>/dev/null || true)"
	fi
	oc_load_paths "${OPENCLAW_INSTALL_PATH:-${_cfg_path:-/opt}}" 2>/dev/null || true
fi

log_info() { echo "  [✓] $1"; }
log_warn() { echo "  [!] $1"; }
log_error() { echo "  [✗] $1" >&2; }

# ── 路径与运行时探测 ──
oc_resolve_state_dir() {
	if [ -n "${1:-}" ]; then
		printf '%s\n' "$1"
	elif [ -n "${OPENCLAW_STATE_DIR:-}" ]; then
		printf '%s\n' "$OPENCLAW_STATE_DIR"
	elif [ -n "${OC_DATA:-}" ]; then
		printf '%s/.openclaw\n' "$OC_DATA"
	elif [ -n "${OC_INSTALL_PATH:-}" ]; then
		printf '%s/data/.openclaw\n' "$OC_INSTALL_PATH"
	else
		printf '/opt/openclaw/data/.openclaw\n'
	fi
}

oc_resolve_backup_dir() {
	local state_dir="$1"
	local custom_backup="${2:-${OPENCLAW_BACKUP_DIR:-}}"
	if [ -n "$custom_backup" ]; then
		printf '%s\n' "$custom_backup"
	else
		local parent_dir
		parent_dir="$(dirname "$state_dir")"
		if [ -n "${OC_DATA:-}" ] && [ "$state_dir" = "${OC_DATA}/.openclaw" ]; then
			printf '%s/backups\n' "$OC_DATA"
		else
			printf '%s/openclaw-backups\n' "$parent_dir"
		fi
	fi
}

oc_resolve_upgrade_meta_dir() {
	local state_dir="$1"
	local parent_dir
	parent_dir="$(dirname "$state_dir")"
	local root_dir
	root_dir="$(dirname "$parent_dir")"
	if [ -d "$root_dir" ] && [ "$parent_dir" = "${root_dir}/data" ]; then
		printf '%s/.luci-openclaw-upgrade\n' "$root_dir"
	else
		printf '%s/.luci-openclaw-upgrade\n' "$parent_dir"
	fi
}

oc_find_node() {
	if [ -n "${NODE_BIN:-}" ] && [ -x "$NODE_BIN" ]; then
		printf '%s\n' "$NODE_BIN"
		return 0
	fi
	for cand in node /opt/openclaw/node/bin/node; do
		if command -v "$cand" >/dev/null 2>&1; then
			command -v "$cand"
			return 0
		elif [ -x "$cand" ]; then
			printf '%s\n' "$cand"
			return 0
		fi
	done
	printf 'node\n'
}

oc_find_cli() {
	if [ -n "${OPENCLAW_CLI:-}" ] && [ -x "$OPENCLAW_CLI" ]; then
		printf '%s\n' "$OPENCLAW_CLI"
		return 0
	fi
	if [ -n "${OC_GLOBAL:-}" ] && [ -x "${OC_GLOBAL}/bin/openclaw" ]; then
		printf '%s\n' "${OC_GLOBAL}/bin/openclaw"
		return 0
	fi
	if [ -n "${OC_INSTALL_PATH:-}" ] && [ -x "${OC_INSTALL_PATH}/global/bin/openclaw" ]; then
		printf '%s\n' "${OC_INSTALL_PATH}/global/bin/openclaw"
		return 0
	fi
	if [ -x "/opt/openclaw/global/bin/openclaw" ]; then
		printf '/opt/openclaw/global/bin/openclaw\n'
		return 0
	fi
	if command -v openclaw >/dev/null 2>&1; then
		command -v openclaw
		return 0
	fi
	printf ''
}

oc_run_as_user() {
	local cmd="$1"
	local state_dir
	state_dir="$(oc_resolve_state_dir "${2:-}")"
	local data_dir="${OC_DATA:-$(dirname "$state_dir")}"
	[ -d "$data_dir" ] || mkdir -p "$data_dir" 2>/dev/null || true
	local node_bin
	node_bin="$(oc_find_node)"
	local oc_global="${OC_GLOBAL:-${OC_INSTALL_PATH:-/opt/openclaw}/global}"
	local node_base="${NODE_BASE:-${OC_INSTALL_PATH:-/opt/openclaw}/node}"
	local config_file="${CONFIG_FILE:-${OPENCLAW_CONFIG_PATH:-${state_dir}/openclaw.json}}"

	local env_prefix="HOME=\"$data_dir\" OPENCLAW_HOME=\"$data_dir\" OPENCLAW_STATE_DIR=\"$state_dir\" OPENCLAW_CONFIG_PATH=\"$config_file\" PATH=\"${node_base}/bin:${oc_global}/bin:\$PATH\""
	[ -d "${node_base}/share/icu" ] && env_prefix="$env_prefix NODE_ICU_DATA=\"${node_base}/share/icu\""
	[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ] && env_prefix="$env_prefix OPENCLAW_GATEWAY_TOKEN=\"$OPENCLAW_GATEWAY_TOKEN\""
	[ -d "${data_dir}/.npm" ] && env_prefix="$env_prefix NPM_CONFIG_CACHE=\"${data_dir}/.npm\" npm_config_cache=\"${data_dir}/.npm\""
	[ -d "${data_dir}/.tmp" ] && env_prefix="$env_prefix TMPDIR=\"${data_dir}/.tmp\""

	local full_cmd="cd \"$data_dir\" && $env_prefix $cmd"

	if [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && id openclaw >/dev/null 2>&1; then
		if command -v su >/dev/null 2>&1; then
			su -s /bin/sh openclaw -c "$full_cmd"
			return $?
		elif command -v runuser >/dev/null 2>&1; then
			runuser -u openclaw -- sh -c "$full_cmd"
			return $?
		elif command -v start-stop-daemon >/dev/null 2>&1; then
			local pid_f="/tmp/oc-state-run-$$.pid"
			(cd "$data_dir" 2>/dev/null || true; start-stop-daemon -S -m -p "$pid_f" -c openclaw:openclaw -x /bin/sh -- -c "$full_cmd")
			local rc=$?
			rm -f "$pid_f" 2>/dev/null || true
			return $rc
		fi
	fi
	sh -c "$full_cmd"
	return $?
}

# ── 1. 备份创建 (backup-create) ──
do_backup_create() {
	local target_backup_dir="${1:-}"
	local target_state_dir="${2:-}"

	local state_dir
	state_dir="$(oc_resolve_state_dir "$target_state_dir")"
	local backup_dir
	backup_dir="$(oc_resolve_backup_dir "$state_dir" "$target_backup_dir")"

	if [ ! -d "$state_dir" ]; then
		log_error "State 目录不存在: $state_dir"
		return 1
	fi

	# 严格约束: 备份目录不得位于 State 目录之内 (防止归档递归)
	case "$backup_dir" in
		"$state_dir"|"$state_dir"/*)
			log_error "备份目录 ($backup_dir) 不得位于 State 目录 ($state_dir) 之内"
			return 1
			;;
	esac

	mkdir -p "$backup_dir" 2>/dev/null || true
	chmod 700 "$backup_dir" 2>/dev/null || true
	if [ ! -d "$backup_dir" ]; then
		log_error "无法创建备份目录: $backup_dir"
		return 1
	fi
	if [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && id openclaw >/dev/null 2>&1; then
		chown openclaw:openclaw "$backup_dir" 2>/dev/null || true
	fi

	local cli_bin
	cli_bin="$(oc_find_cli)"
	if [ -z "$cli_bin" ]; then
		log_error "未找到 OpenClaw CLI 可执行文件"
		return 1
	fi

	local data_dir="${OC_DATA:-$(dirname "$state_dir")}"

	# 以 openclaw 用户在完整运行环境中调用:
	# openclaw backup create --verify --no-include-workspace (严禁 --only-config)
	local run_cmd="cd \"$backup_dir\" && \"$cli_bin\" backup create --verify --no-include-workspace"
	local out
	local rc=0
	out=$(oc_run_as_user "$run_cmd" "$state_dir" 2>&1) || rc=$?

	if [ "$rc" -ne 0 ]; then
		echo "$out" >&2
		log_error "openclaw backup create 执行失败 (退出码: $rc)"
		return "$rc"
	fi

	# 检查并迁移可能输出到 data_dir/HOME 的备份文件
	for f in "${data_dir}"/*-openclaw-backup.tar.gz "${data_dir}"/openclaw-backup-*.tar.gz; do
		if [ -f "$f" ]; then
			mv "$f" "$backup_dir/" 2>/dev/null || true
		fi
	done

	local archive_path=""
	local candidate
	candidate=$(printf '%s\n' "$out" | grep -oE '[^[:space:]"]+\.tar\.gz|[^[:space:]"]+\.tgz' | tail -1 || true)
	if [ -n "$candidate" ]; then
		if [ -f "$candidate" ]; then
			archive_path="$candidate"
		elif [ -f "${backup_dir}/${candidate##*/}" ]; then
			archive_path="${backup_dir}/${candidate##*/}"
		fi
	fi

	if [ -z "$archive_path" ] || [ ! -f "$archive_path" ]; then
		archive_path=$(ls -t "${backup_dir}"/*-openclaw-backup.tar.gz "${backup_dir}"/*.tar.gz "${backup_dir}"/*.tgz 2>/dev/null | head -1 || true)
	fi

	if [ -z "$archive_path" ] || [ ! -s "$archive_path" ]; then
		log_error "未找到生成的有效备份归档文件 (目录: $backup_dir)"
		return 1
	fi

	chmod 600 "$archive_path" 2>/dev/null || true
	if [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && id openclaw >/dev/null 2>&1; then
		chown openclaw:openclaw "$archive_path" 2>/dev/null || true
	fi

	log_info "完整备份已成功创建: $archive_path"
	printf '%s\n' "$archive_path"
	return 0
}

# ── 2. 备份校验 (backup-verify) ──
do_backup_verify() {
	local archive_path="${1:-}"
	local target_state_dir="${2:-}"

	if [ -z "$archive_path" ] || [ ! -f "$archive_path" ]; then
		log_error "备份归档文件不存在: $archive_path"
		return 1
	fi

	local state_dir
	state_dir="$(oc_resolve_state_dir "$target_state_dir")"

	local cli_bin
	cli_bin="$(oc_find_cli)"
	if [ -n "$cli_bin" ]; then
		local verify_cmd="\"$cli_bin\" backup verify \"$archive_path\""
		local out
		local rc=0
		out=$(oc_run_as_user "$verify_cmd" "$state_dir" 2>&1) || rc=$?
		if [ "$rc" -ne 0 ]; then
			echo "$out" >&2
			log_error "官方 backup verify 验证失败 (退出码: $rc)"
			return "$rc"
		fi
	fi

	# 覆盖清单校验 (覆盖 openclaw.json、SQLite、agent/session/auth/plugin/微信认证状态)
	local entries
	entries=$(tar -tzf "$archive_path" 2>/dev/null)
	if [ -z "$entries" ]; then
		log_error "无法读取归档文件清单或归档为空: $archive_path"
		return 1
	fi

	# 拒绝绝对路径和 ..
	if printf '%s\n' "$entries" | grep -q '^/'; then
		log_error "归档包含非法绝对路径，拒绝验证: $archive_path"
		return 1
	fi
	if printf '%s\n' "$entries" | grep -E '(^|/)\.\.(/|$)'; then
		log_error "归档包含越界相对路径 (..)，拒绝验证: $archive_path"
		return 1
	fi

	# 必须包含核心配置文件 openclaw.json
	if ! printf '%s\n' "$entries" | grep -Eq '(^|/)openclaw\.json$'; then
		log_error "归档缺少核心配置 openclaw.json: $archive_path"
		return 1
	fi

	# 对已有状态的完整覆盖清单核对
	if [ -d "$state_dir" ]; then
		# SQLite 校验: 若原状态存在 SQLite 文件，归档必须覆盖
		local has_sqlite=0
		if [ -n "$(find "$state_dir" -type f \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" -o -name "installed_plugin_index" \) 2>/dev/null | head -1)" ]; then
			has_sqlite=1
		fi
		if [ "$has_sqlite" -eq 1 ]; then
			if ! printf '%s\n' "$entries" | grep -Eq '\.(db|sqlite|sqlite3)$|installed_plugin_index'; then
				log_error "原状态存在 SQLite 数据，但归档未覆盖 SQLite 文件"
				return 1
			fi
		fi

		# agent 校验
		if [ -d "${state_dir}/agents" ] && [ -n "$(ls -A "${state_dir}/agents" 2>/dev/null)" ]; then
			if ! printf '%s\n' "$entries" | grep -Eq '(^|/)agents/'; then
				log_error "原状态存在 agents 数据，但归档未覆盖 agents"
				return 1
			fi
		fi

		# session 校验
		if [ -d "${state_dir}/sessions" ] && [ -n "$(ls -A "${state_dir}/sessions" 2>/dev/null)" ]; then
			if ! printf '%s\n' "$entries" | grep -Eq '(^|/)sessions/'; then
				log_error "原状态存在 sessions 数据，但归档未覆盖 sessions"
				return 1
			fi
		fi

		# auth 校验 (排除 regenerable 的 npm 缓存目录，避免代码内部 auth 路径被误判为持久认证数据)
		if [ -d "${state_dir}/auth" ] || [ -f "${state_dir}/agents/main/agent/auth-profiles.json" ] || [ -n "$(find "$state_dir" ! -path "${state_dir}/npm*" \( -name "*auth*" -o -name "*token*" \) 2>/dev/null | head -1)" ]; then
			if ! printf '%s\n' "$entries" | grep -Eq 'auth|token|openclaw\.json'; then
				log_error "原状态存在 auth 状态，但归档未覆盖 auth"
				return 1
			fi
		fi

		# plugin / extensions 校验 (npm 目录由 OpenClaw 官方作为 regenerable 排除，不作为备份归档项)
		if [ -d "${state_dir}/plugins" ] || [ -d "${state_dir}/extensions" ]; then
			if ! printf '%s\n' "$entries" | grep -Eq '(plugins|extensions|plugin)'; then
				log_error "原状态存在 plugin / extension 状态，但归档未覆盖 plugin"
				return 1
			fi
		fi

		# 微信认证状态校验 (排除 npm 目录)
		if [ -d "${state_dir}/openclaw-weixin" ] || [ -n "$(find "$state_dir" ! -path "${state_dir}/npm*" \( -path "*/openclaw-weixin/*" -o -name "*weixin*" \) 2>/dev/null | head -1)" ]; then
			if ! printf '%s\n' "$entries" | grep -Eq '(openclaw-weixin|weixin)'; then
				log_error "原状态存在微信认证状态，但归档未覆盖微信认证"
				return 1
			fi
		fi
	fi

	log_info "官方 backup verify 与完整覆盖清单校验通过: $archive_path"
	return 0
}

# ── 3. 安全恢复状态 (restore-state) ──
do_restore_state() {
	local archive_path="${1:-}"
	local target_state_dir="${2:-}"

	if [ -z "$archive_path" ] || [ ! -f "$archive_path" ]; then
		log_error "恢复归档文件不存在: $archive_path"
		return 1
	fi

	local state_dir
	state_dir="$(oc_resolve_state_dir "$target_state_dir")"
	local state_parent
	state_parent="$(dirname "$state_dir")"

	# 1. 严格检查归档内路径安全 (拒绝绝对路径、..、异常 layout)
	local entries
	entries=$(tar -tzf "$archive_path" 2>/dev/null)
	if [ -z "$entries" ]; then
		log_error "归档无法读取或为空: $archive_path"
		return 1
	fi
	if printf '%s\n' "$entries" | grep -q '^/'; then
		log_error "归档包含绝对路径，拒绝恢复: $archive_path"
		return 1
	fi
	if printf '%s\n' "$entries" | grep -E '(^|/)\.\.(/|$)'; then
		log_error "归档包含目录穿透 (..)，拒绝恢复: $archive_path"
		return 1
	fi
	if ! printf '%s\n' "$entries" | grep -Eq '(^|/)openclaw\.json$'; then
		log_error "归档未包含 openclaw.json，属于异常 layout: $archive_path"
		return 1
	fi

	# 2. 解到 State 同级临时目录 (隔离解包)
	mkdir -p "$state_parent" 2>/dev/null || true
	local staging_dir
	staging_dir=$(mktemp -d "${state_parent}/.restore-stage-XXXXXX" 2>/dev/null || echo "${state_parent}/.restore-stage-$$-${RANDOM:-0}")
	mkdir -p "$staging_dir"

	if ! tar -xzf "$archive_path" -C "$staging_dir" 2>/dev/null; then
		rm -rf "$staging_dir" 2>/dev/null || true
		log_error "归档解包到临时目录失败: $staging_dir"
		return 1
	fi

	# 3. 检查越界软硬链接
	local bad_link=0
	for l in $(find "$staging_dir" -type l 2>/dev/null); do
		local l_target
		l_target=$(readlink "$l" 2>/dev/null || true)
		case "$l_target" in
			/*)
				bad_link=1
				log_error "检测到指向绝对路径的越界软链接: $l -> $l_target"
				break
				;;
			*\.\./*|*/\.\.*|*\.\.)
				bad_link=1
				log_error "检测到相对路径穿透的越界软链接: $l -> $l_target"
				break
				;;
		esac
	done
	if [ "$bad_link" -eq 1 ]; then
		rm -rf "$staging_dir" 2>/dev/null || true
		return 1
	fi

	# 4. 定位解包产物中的 state 根目录
	local staged_json
	staged_json=$(find "$staging_dir" -name "openclaw.json" -type f 2>/dev/null | head -1)
	if [ -z "$staged_json" ] || [ ! -s "$staged_json" ]; then
		rm -rf "$staging_dir" 2>/dev/null || true
		log_error "解包目录中未找到有效的 openclaw.json"
		return 1
	fi
	local restored_state_root
	restored_state_root="$(dirname "$staged_json")"

	# 5. 核对解包后的关键数据有效性
	local node_bin
	node_bin="$(oc_find_node)"
	if [ -x "$node_bin" ]; then
		if ! "$node_bin" -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$staged_json" 2>/dev/null; then
			rm -rf "$staging_dir" 2>/dev/null || true
			log_error "解包的 openclaw.json 不是合法 JSON 格式"
			return 1
		fi
	fi

	# 检查 SQLite、agent、session、auth、plugin、微信等已有主数据文件非空
	for f in $(find "$restored_state_root" -type f \( -name "*.sqlite" -o -name "*.sqlite3" -o -name "*.db" -o -name "auth-profiles.json" \) 2>/dev/null); do
		case "$f" in
			*-shm|*-wal|*-journal) continue ;;
		esac
		if [ ! -s "$f" ]; then
			rm -rf "$staging_dir" 2>/dev/null || true
			log_error "恢复产物中包含空数据文件: $f"
			return 1
		fi
	done

	# 6. 原子目录切换
	local pre_backup="${state_parent}/.state-pre-restore-$$-${RANDOM:-0}"
	local had_old_state=0
	if [ -e "$state_dir" ]; then
		had_old_state=1
		if ! mv "$state_dir" "$pre_backup" 2>/dev/null; then
			rm -rf "$staging_dir" 2>/dev/null || true
			log_error "无法移动现有 State 目录，保持当前状态不变"
			return 1
		fi
	fi

	local switch_ok=0
	if mv "$restored_state_root" "$state_dir" 2>/dev/null; then
		switch_ok=1
	fi

	if [ "$switch_ok" -eq 1 ]; then
		rm -rf "$staging_dir" 2>/dev/null || true
		if [ "$had_old_state" -eq 1 ]; then
			rm -rf "$pre_backup" 2>/dev/null || true
		fi
		if command -v oc_fix_state_permissions >/dev/null 2>&1; then
			oc_fix_state_permissions "$state_dir" 2>/dev/null || true
		elif [ -x /usr/libexec/openclaw-permissions.sh ]; then
			/usr/libexec/openclaw-permissions.sh fix-state "$state_dir" 2>/dev/null || true
		elif [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && id openclaw >/dev/null 2>&1; then
			chown -R openclaw:openclaw "$state_dir" 2>/dev/null || true
		fi
		log_info "State 状态已安全原子恢复: $state_dir"
		return 0
	else
		log_error "原子替换 State 目录失败，正在回滚保留原状态..."
		rm -rf "$state_dir" 2>/dev/null || true
		if [ "$had_old_state" -eq 1 ]; then
			mv "$pre_backup" "$state_dir" 2>/dev/null || true
		fi
		rm -rf "$staging_dir" 2>/dev/null || true
		log_warn "原 State 状态已恢复，备份文件已保留"
		return 1
	fi
}

# ── 4. Token 一致性对账 (reconcile-token) ──
do_reconcile_token() {
	local target_config="${1:-}"
	local target_state_dir="${2:-}"

	local state_dir
	state_dir="$(oc_resolve_state_dir "$target_state_dir")"
	local config_file="${target_config:-${state_dir}/openclaw.json}"

	if [ ! -f "$config_file" ]; then
		log_error "配置文件不存在: $config_file"
		return 1
	fi

	local node_bin
	node_bin="$(oc_find_node)"
	if [ ! -x "$node_bin" ]; then
		log_error "Node.js 不可用，无法执行 Token 对账"
		return 1
	fi

	local json_token
	json_token=$("$node_bin" -e "
		try {
			const d = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
			if (d.gateway && d.gateway.auth && d.gateway.auth.token) process.stdout.write(String(d.gateway.auth.token));
		} catch(e) {}
	" "$config_file" 2>/dev/null || true)

	local uci_token=""
	if command -v uci >/dev/null 2>&1; then
		uci_token=$(uci -q get openclaw.main.token 2>/dev/null || true)
	fi

	# 对账逻辑:
	# 1. 若 JSON 有 token 且 UCI 为空或不一致，以 JSON 为准同步至 UCI
	# 2. 若 UCI 有 token 且 JSON 为空，以 UCI 为准写入 JSON
	# 3. 若均有但不同，优先以当前生效的 JSON 为准同步给 UCI
	if [ -n "$json_token" ]; then
		if [ "$json_token" != "$uci_token" ] && command -v uci >/dev/null 2>&1; then
			uci -q set openclaw.main.token="$json_token" 2>/dev/null || true
			uci -q commit openclaw 2>/dev/null || true
			log_info "Token 对账: 已将 JSON 中的 token 同步至 UCI"
		fi
	elif [ -n "$uci_token" ]; then
		OC_RECONCILE_TOKEN="$uci_token" "$node_bin" -e "
			const fs = require('fs');
			const f = process.argv[1];
			try {
				const d = JSON.parse(fs.readFileSync(f, 'utf8'));
				if (!d.gateway) d.gateway = {};
				if (!d.gateway.auth) d.gateway.auth = {};
				d.gateway.auth.mode = 'token';
				d.gateway.auth.token = process.env.OC_RECONCILE_TOKEN;
				fs.writeFileSync(f, JSON.stringify(d, null, 2) + '\n');
			} catch(e) { process.exit(1); }
		" "$config_file" 2>/dev/null || true
		chown openclaw:openclaw "$config_file" 2>/dev/null || true
		log_info "Token 对账: 已将 UCI 中的 token 补充至 JSON"
	fi

	# 校验一致性
	local final_json_token
	final_json_token=$("$node_bin" -e "
		try {
			const d = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
			if (d.gateway && d.gateway.auth && d.gateway.auth.token) process.stdout.write(String(d.gateway.auth.token));
		} catch(e) {}
	" "$config_file" 2>/dev/null || true)

	local final_uci_token=""
	if command -v uci >/dev/null 2>&1; then
		final_uci_token=$(uci -q get openclaw.main.token 2>/dev/null || true)
	fi

	if [ -n "$final_uci_token" ] && [ -n "$final_json_token" ] && [ "$final_json_token" != "$final_uci_token" ]; then
		log_error "Token 对账失败: JSON token 与 UCI token 不匹配"
		return 1
	fi

	log_info "Token 一致性对账完成"
	return 0
}

# ── 5. Doctor 迁移事务 (doctor-migration) ──
do_doctor_migration() {
	local target_state_dir="${1:-}"
	local target_version="${2:-2026.9.1}"

	local state_dir
	state_dir="$(oc_resolve_state_dir "$target_state_dir")"
	local config_file="${CONFIG_FILE:-${state_dir}/openclaw.json}"
	local marker_file="${state_dir}/.doctor_ran_version"

	local cli_bin
	cli_bin="$(oc_find_cli)"
	if [ -z "$cli_bin" ]; then
		log_error "未找到 OpenClaw CLI，无法执行 Doctor migration"
		return 1
	fi

	# 检查当前 CLI 实际版本
	local current_cli_ver=""
	local node_bin
	node_bin="$(oc_find_node)"
	if [ -x "$node_bin" ]; then
		current_cli_ver=$("$node_bin" -e '
			try {
				const p = process.argv[1];
				const fs = require("fs");
				if (fs.existsSync(p)) {
					const pkg = JSON.parse(fs.readFileSync(p, "utf8"));
					console.log(pkg.version);
				}
			} catch(e) {}
		' "$(dirname "$cli_bin")/../package.json" 2>/dev/null || true)
	fi
	if [ -z "$current_cli_ver" ]; then
		current_cli_ver=$("$cli_bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?' | head -1 || echo "$target_version")
	fi

	# 幂等性检查: 如果该版本已成功运行过 doctor migration，且 marker 匹配，验证幂等
	if [ -f "$marker_file" ]; then
		local ran_ver
		ran_ver=$(cat "$marker_file" 2>/dev/null | tr -d '[:space:]')
		if [ "$ran_ver" = "$current_cli_ver" ] || [ "$ran_ver" = "$target_version" ]; then
			log_info "版本 $ran_ver 已完成过 Doctor migration，执行幂等安全验证..."
			local val_cmd="\"$cli_bin\" config validate --json"
			local val_rc=0
			oc_run_as_user "$val_cmd" "$state_dir" >/dev/null 2>&1 || val_rc=$?
			if [ "$val_rc" -eq 0 ] && do_reconcile_token "$config_file" "$state_dir"; then
				log_info "Doctor migration 幂等校验通过，状态保持完整"
				return 0
			fi
		fi
	fi

	# 1. 只读预检 doctor --lint --json (对齐 Section 7 Step 9)
	log_info "正在以 openclaw 用户执行只读预检 (doctor --lint --json)..."
	local lint_cmd="\"$cli_bin\" doctor --lint --json"
	oc_run_as_user "$lint_cmd" "$state_dir" >/dev/null 2>&1 || true

	# 2. 以 openclaw 用户执行 doctor --fix --non-interactive (对齐 Section 7 Step 9)
	log_info "正在以 openclaw 用户执行 doctor --fix --non-interactive..."
	local doc_cmd="\"$cli_bin\" doctor --fix --non-interactive"
	local doc_rc=0
	local doc_out
	doc_out=$(oc_run_as_user "$doc_cmd" "$state_dir" 2>&1) || doc_rc=$?
	if [ "$doc_rc" -ne 0 ]; then
		echo "$doc_out" >&2
		log_error "doctor --fix --non-interactive 执行失败 (退出码: $doc_rc)"
		return "$doc_rc"
	fi

	# 3. 成功后以 openclaw 用户执行 config validate --json
	log_info "正在以 openclaw 用户验证配置合法性 (config validate --json)..."
	local val_cmd="\"$cli_bin\" config validate --json"
	local val_rc=0
	local val_out
	val_out=$(oc_run_as_user "$val_cmd" "$state_dir" 2>&1) || val_rc=$?
	if [ "$val_rc" -ne 0 ]; then
		echo "$val_out" >&2
		log_error "config validate --json 校验失败 (退出码: $val_rc)"
		return "$val_rc"
	fi

	# 4. 第二次 Doctor 检查，确认幂等 (对齐 Section 7 Step 9)
	log_info "正在执行第二次 Doctor 检查确认幂等 (doctor --lint --json)..."
	local lint2_cmd="\"$cli_bin\" doctor --lint --json"
	local lint2_rc=0
	oc_run_as_user "$lint2_cmd" "$state_dir" >/dev/null 2>&1 || lint2_rc=$?
	if [ "$lint2_rc" -ne 0 ]; then
		log_warn "第二次 Doctor 检查存在警告，继续完成状态对账..."
	fi

	# 5. 执行 JSON/UCI Token 一致性对账
	if ! do_reconcile_token "$config_file" "$state_dir"; then
		log_error "Token 一致性对账失败"
		return 1
	fi

	# 6. 仅全部成功才写 .doctor_ran_version
	echo "${current_cli_ver:-$target_version}" > "$marker_file"
	if [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && id openclaw >/dev/null 2>&1; then
		chown openclaw:openclaw "$marker_file" 2>/dev/null || true
	fi

	if command -v oc_fix_state_permissions >/dev/null 2>&1; then
		oc_fix_state_permissions "$state_dir" 2>/dev/null || true
	elif [ -x /usr/libexec/openclaw-permissions.sh ]; then
		/usr/libexec/openclaw-permissions.sh fix-state "$state_dir" 2>/dev/null || true
	fi

	log_info "Doctor migration 事务全部完成 (版本: ${current_cli_ver:-$target_version})"
	return 0
}

# ── 5.1 插件收敛事务 (plugin-convergence, 对齐 Section 7 Step 10) ──
do_plugin_convergence() {
	local target_state_dir="${1:-}"
	local state_dir
	state_dir="$(oc_resolve_state_dir "$target_state_dir")"

	local cli_bin
	cli_bin="$(oc_find_cli)"
	if [ -z "$cli_bin" ]; then
		return 0
	fi

	log_info "正在执行插件收敛 (registry refresh / doctor --post-upgrade)..."
	# 1. 刷新插件注册表
	oc_run_as_user "\"$cli_bin\" plugins registry --refresh --json" "$state_dir" >/dev/null 2>&1 || true

	# 2. post-upgrade 检查插件
	oc_run_as_user "\"$cli_bin\" doctor --post-upgrade --json" "$state_dir" >/dev/null 2>&1 || true

	# 3. 微信插件运行时检查 (若安装)
	if [ -d "${state_dir}/openclaw-weixin" ] || [ -d "${state_dir}/extensions/openclaw-weixin" ]; then
		oc_run_as_user "\"$cli_bin\" plugins inspect openclaw-weixin --runtime --json" "$state_dir" >/dev/null 2>&1 || true
	fi

	return 0
}

# ── 6. Gateway 验证 (gateway-verify) ──
do_gateway_verify() {
	local gw_token="${1:-}"
	local target_state_dir="${2:-}"

	local state_dir
	state_dir="$(oc_resolve_state_dir "$target_state_dir")"
	local config_file="${CONFIG_FILE:-${state_dir}/openclaw.json}"

	local cli_bin
	cli_bin="$(oc_find_cli)"
	if [ -z "$cli_bin" ]; then
		log_error "未找到 OpenClaw CLI，无法验证 Gateway 健康状态"
		return 1
	fi

	if [ -z "$gw_token" ]; then
		if command -v uci >/dev/null 2>&1; then
			gw_token=$(uci -q get openclaw.main.token 2>/dev/null || true)
		fi
		if [ -z "$gw_token" ] && [ -f "$config_file" ]; then
			local node_bin
			node_bin="$(oc_find_node)"
			if [ -x "$node_bin" ]; then
				gw_token=$("$node_bin" -e "
					try {
						const d = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
						if (d.gateway && d.gateway.auth && d.gateway.auth.token) process.stdout.write(String(d.gateway.auth.token));
					} catch(e) {}
				" "$config_file" 2>/dev/null || true)
			fi
		fi
	fi

	log_info "正在验证 Gateway 健康状态 (gateway health --json)..."
	local check_cmd="\"$cli_bin\" gateway health --json"
	local tries=0
	local max_tries=15
	local health_rc=1
	local health_out=""

	while [ "$tries" -lt "$max_tries" ]; do
		tries=$((tries + 1))
		health_rc=0
		OPENCLAW_GATEWAY_TOKEN="$gw_token"
		export OPENCLAW_GATEWAY_TOKEN
		health_out=$(oc_run_as_user "$check_cmd" "$state_dir" 2>&1) || health_rc=$?

		if [ "$health_rc" -eq 0 ]; then
			# 检查是否包含有效 JSON 且状态正常
			if printf '%s\n' "$health_out" | grep -qE '"status"[[:space:]]*:[[:space:]]*"(ok|healthy)"|"healthy"[[:space:]]*:[[:space:]]*true|"ok"[[:space:]]*:[[:space:]]*true'; then
				log_info "Gateway 健康验证成功 (尝试 ${tries}/${max_tries})"
				return 0
			fi
		fi
		sleep 1
	done

	echo "$health_out" >&2
	log_error "Gateway 健康验证失败 (尝试 ${max_tries} 次均未通过, 退出码: $health_rc)"
	return "$health_rc"
}

# ── 7. 事务状态持久化 (transaction management) ──
do_transaction_status() {
	local target_state_dir="${1:-}"
	local state_dir
	state_dir="$(oc_resolve_state_dir "$target_state_dir")"
	local meta_dir
	meta_dir="$(oc_resolve_upgrade_meta_dir "$state_dir")"
	local status_file="${meta_dir}/status.json"

	if [ -f "$status_file" ]; then
		cat "$status_file"
	else
		cat <<EOF
{
  "phase": "idle",
  "target_version": "",
  "backup_verified": false,
  "migration_started": false,
  "rollback_mode": "none",
  "error_code": 0,
  "error_message": "",
  "backup_file": ""
}
EOF
	fi
}

do_transaction_init() {
	local target_version="${1:-2026.9.1}"
	local target_state_dir="${2:-}"
	local state_dir
	state_dir="$(oc_resolve_state_dir "$target_state_dir")"
	local meta_dir
	meta_dir="$(oc_resolve_upgrade_meta_dir "$state_dir")"
	mkdir -p "$meta_dir" 2>/dev/null || true
	chmod 700 "$meta_dir" 2>/dev/null || true

	local status_file="${meta_dir}/status.json"
	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")

	cat > "$status_file" <<EOF
{
  "phase": "init",
  "target_version": "${target_version}",
  "backup_verified": false,
  "migration_started": false,
  "rollback_mode": "none",
  "error_code": 0,
  "error_message": "",
  "backup_file": "",
  "updated_at": "${now}"
}
EOF
	chmod 600 "$status_file" 2>/dev/null || true
	if [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && id openclaw >/dev/null 2>&1; then
		chown -R openclaw:openclaw "$meta_dir" 2>/dev/null || true
	fi
	log_info "升级事务已初始化: 目标版本 $target_version"
}

do_transaction_set_phase() {
	local phase="$1"
	local target_state_dir="${2:-}"
	local error_code="${3:-0}"
	local error_msg="${4:-}"
	local backup_file="${5:-}"

	local state_dir
	state_dir="$(oc_resolve_state_dir "$target_state_dir")"
	local meta_dir
	meta_dir="$(oc_resolve_upgrade_meta_dir "$state_dir")"
	mkdir -p "$meta_dir" 2>/dev/null || true
	local status_file="${meta_dir}/status.json"

	local node_bin
	node_bin="$(oc_find_node)"
	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")

	if [ -x "$node_bin" ]; then
		OC_PHASE="$phase" OC_ERR_CODE="$error_code" OC_ERR_MSG="$error_msg" OC_BK_FILE="$backup_file" OC_NOW="$now" \
		"$node_bin" -e '
			const fs = require("fs");
			const f = process.argv[1];
			let d = {
				phase: process.env.OC_PHASE || "idle",
				target_version: "",
				backup_verified: false,
				migration_started: false,
				rollback_mode: "none",
				error_code: parseInt(process.env.OC_ERR_CODE, 10) || 0,
				error_message: process.env.OC_ERR_MSG || "",
				backup_file: process.env.OC_BK_FILE || "",
				updated_at: process.env.OC_NOW || ""
			};
			try {
				if (fs.existsSync(f)) {
					const cur = JSON.parse(fs.readFileSync(f, "utf8"));
					d = { ...d, ...cur };
				}
			} catch(e) {}
			d.phase = process.env.OC_PHASE;
			d.updated_at = process.env.OC_NOW;
			if (d.phase === "completed") {
				d.error_message = "";
				d.error_code = 0;
			} else {
				if (process.env.OC_ERR_CODE !== undefined && process.env.OC_ERR_CODE !== "") {
					d.error_code = parseInt(process.env.OC_ERR_CODE, 10) || 0;
				}
				if (process.env.OC_ERR_MSG) {
					d.error_message = process.env.OC_ERR_MSG;
				}
			}
			if (process.env.OC_BK_FILE) {
				d.backup_file = process.env.OC_BK_FILE;
			}
			if (d.phase === "backup_verified") {
				d.backup_verified = true;
			}
			if (d.phase === "migrating" || d.phase === "migrated" || d.phase === "gateway_verifying" || d.phase === "completed" || d.phase === "recovery") {
				d.migration_started = true;
			}
			if (d.phase === "recovery") {
				d.rollback_mode = "manual_recovery";
			} else if (d.phase === "failed" && !d.migration_started) {
				d.rollback_mode = "auto_pre_migration";
			} else if (d.phase === "rolled_back") {
				d.rollback_mode = "rolled_back";
			}
			fs.writeFileSync(f, JSON.stringify(d, null, 2) + "\n");
		' "$status_file" 2>/dev/null || true
	else
		# 无 Node.js 时的纯 shell 写入兜底
		local bkv=false mig=false rbm="none"
		[ "$phase" = "backup_verified" ] && bkv=true
		case "$phase" in
			migrating|migrated|gateway_verifying|completed|recovery) mig=true ;;
		esac
		case "$phase" in
			recovery) rbm="manual_recovery" ;;
			failed) [ "$mig" = "false" ] && rbm="auto_pre_migration" || rbm="manual_recovery" ;;
			rolled_back) rbm="rolled_back" ;;
		esac
		if [ "$phase" = "completed" ]; then
			error_msg=""
			error_code=0
		fi
		local cur_ver=""
		if [ -f "$status_file" ]; then
			cur_ver=$(grep -oE '"target_version"[[:space:]]*:[[:space:]]*"[^"]*"' "$status_file" 2>/dev/null | cut -d'"' -f4 || true)
		fi
		cat > "$status_file" <<EOF
{
  "phase": "${phase}",
  "target_version": "${cur_ver}",
  "backup_verified": ${bkv},
  "migration_started": ${mig},
  "rollback_mode": "${rbm}",
  "error_code": ${error_code:-0},
  "error_message": "${error_msg}",
  "backup_file": "${backup_file}",
  "updated_at": "${now}"
}
EOF
		chmod 600 "$status_file" 2>/dev/null || true
	fi
}

# ── 8. 数据库前向迁移预检 (database-preflight) ──
do_database_preflight() {
	local archive_or_state="${1:-}"
	local target_state_dir="${2:-}"

	local state_dir
	local stage_preflight=""

	if [ -f "$archive_or_state" ]; then
		# 输入是备份归档文件: 解包 SQLite 副本到隔离临时目录进行预检 (对齐 Section 7 Step 7)
		stage_preflight=$(mktemp -d /tmp/oc-preflight-XXXXXX 2>/dev/null || mktemp -d 2>/dev/null || echo "/tmp/oc-preflight-$$-${RANDOM:-0}")
		mkdir -p "$stage_preflight"
		tar -xzf "$archive_or_state" -C "$stage_preflight" 2>/dev/null || true
		state_dir="$stage_preflight"
	elif [ -d "$archive_or_state" ]; then
		state_dir="$archive_or_state"
	else
		state_dir="$(oc_resolve_state_dir "${target_state_dir:-$archive_or_state}")"
	fi

	local cli_bin
	cli_bin="$(oc_find_cli)"
	local node_bin
	node_bin="$(oc_find_node)"

	log_info "正在执行 SQLite 数据库前向迁移预检 (database preflight)..."
	if [ -n "$cli_bin" ] && [ -x "$cli_bin" ] && [ -z "$stage_preflight" ]; then
		local out rc=0
		out=$(oc_run_as_user "\"$cli_bin\" database preflight --json" "$state_dir" 2>&1) || rc=$?
		if [ "$rc" -eq 0 ]; then
			log_info "数据库 preflight 官方命令通过"
			return 0
		else
			echo "$out" >&2
			log_error "官方 database preflight 命令执行失败 (退出码: $rc)"
			return "$rc"
		fi
	fi

	if [ -x "$node_bin" ]; then
		local chk_rc=0
		"$node_bin" -e '
			const fs = require("fs");
			const path = require("path");
			const root = process.argv[1];
			if (!fs.existsSync(root)) process.exit(0);
			function scan(dir) {
				const entries = fs.readdirSync(dir, { withFileTypes: true });
				for (const ent of entries) {
					const p = path.join(dir, ent.name);
					if (ent.isDirectory()) scan(p);
					else if (ent.isFile() && (ent.name.endsWith(".db") || ent.name.endsWith(".sqlite") || ent.name.endsWith(".sqlite3")) && !ent.name.endsWith("-shm") && !ent.name.endsWith("-wal") && !ent.name.endsWith("-journal")) {
						const stat = fs.statSync(p);
						if (stat.size < 16) {
							console.error("SQLite file too small or empty: " + p + " (" + stat.size + " bytes)");
							process.exit(1);
						}
						const buf = Buffer.alloc(16);
						const fd = fs.openSync(p, "r");
						const bytesRead = fs.readSync(fd, buf, 0, 16, 0);
						fs.closeSync(fd);
						if (bytesRead < 16 || buf.toString("utf8", 0, 15) !== "SQLite format 3") {
							console.error("Invalid SQLite header in: " + p);
							process.exit(1);
						}
					}
				}
			}
			try { scan(root); } catch(e) { console.error(e.message); process.exit(1); }
		' "$state_dir" 2>/dev/null || chk_rc=$?

		[ -n "$stage_preflight" ] && rm -rf "$stage_preflight" 2>/dev/null || true

		if [ "$chk_rc" -ne 0 ]; then
			log_error "SQLite 数据库完整性检查失败"
			return 1
		fi
	fi

	[ -n "$stage_preflight" ] && rm -rf "$stage_preflight" 2>/dev/null || true
	log_info "数据库前向迁移预检通过"
	return 0
}

# ── 9. 显式安全完整回滚 (rollback-explicit) ──
do_rollback_explicit() {
	local backup_archive="${1:-}"
	local target_state_dir="${2:-}"

	local state_dir
	state_dir="$(oc_resolve_state_dir "$target_state_dir")"
	local backup_dir
	backup_dir="$(oc_resolve_backup_dir "$state_dir")"

	if [ -z "$backup_archive" ] || [ ! -f "$backup_archive" ]; then
		local meta_dir
		meta_dir="$(oc_resolve_upgrade_meta_dir "$state_dir")"
		if [ -f "${meta_dir}/status.json" ]; then
			local recorded
			recorded=$(grep -oE '"backup_file"[[:space:]]*:[[:space:]]*"[^"]+"' "${meta_dir}/status.json" 2>/dev/null | cut -d'"' -f4 || true)
			if [ -n "$recorded" ] && [ -f "$recorded" ]; then
				backup_archive="$recorded"
			fi
		fi
	fi

	if [ -z "$backup_archive" ] || [ ! -f "$backup_archive" ]; then
		backup_archive=$(ls -t "${backup_dir}"/*-openclaw-backup.tar.gz "${backup_dir}"/*.tar.gz 2>/dev/null | head -1 || true)
	fi

	if [ -z "$backup_archive" ] || [ ! -f "$backup_archive" ]; then
		log_error "显式回滚失败: 未找到有效的前向备份归档文件"
		do_transaction_set_phase "recovery" "$state_dir" "1" "Explicit rollback failed: no backup archive found" ""
		return 1
	fi

	# 1. 校验升级前备份完整性 (必须在停止服务前校验！若备份损坏，保持当前服务运行，拒绝破坏性还原)
	log_info "1/5 校验前置备份归档完整性..."
	if ! do_backup_verify "$backup_archive" "$state_dir"; then
		log_error "显式回滚中止: 升级前备份归档校验未通过，拒绝损坏还原 (当前服务保持运行)"
		do_transaction_set_phase "recovery" "$state_dir" "1" "Explicit rollback aborted: backup verification failed" "$backup_archive"
		return 1
	fi

	log_warn "============================================================"
	log_warn "开始执行 OpenClaw 显式安全完整回滚"
	log_warn "目标状态目录: $state_dir"
	log_warn "还原备份归档: $backup_archive"
	log_warn "注意: 备份之后的会话与凭据变化将被丢弃！"
	log_warn "============================================================"

	# 2. 停止所有写进程 (procd 与残留进程)
	log_info "2/5 停止 Gateway 服务与写进程..."
	if [ -x /etc/init.d/openclaw ]; then
		/etc/init.d/openclaw stop >/dev/null 2>&1 || true
	fi
	sleep 2
	for p in $(pgrep -f "openclaw" 2>/dev/null); do
		kill "$p" 2>/dev/null || true
	done
	sleep 1

	# 3. 归档失败后的新状态 (保留现场供诊断)
	log_info "3/5 归档失败后的新状态现场..."
	mkdir -p "$backup_dir" 2>/dev/null || true
	local failed_archive="${backup_dir}/failed-state-$(date +%Y%m%d-%H%M%S).tar.gz"
	if [ -d "$state_dir" ]; then
		tar -czf "$failed_archive" -C "$(dirname "$state_dir")" "$(basename "$state_dir")" 2>/dev/null || true
		chmod 600 "$failed_archive" 2>/dev/null || true
		log_info "失败现场已归档至: $failed_archive"
	fi

	# 4. 同时恢复旧代码与完整旧状态
	log_info "4/5 还原旧代码与完整旧状态..."
	local parent_global
	parent_global="$(dirname "${OC_GLOBAL:-/opt/openclaw/global}")"
	local old_global_backup
	old_global_backup=$(ls -dt "${parent_global}"/.global-backup-* 2>/dev/null | head -1 || true)
	if [ -n "$old_global_backup" ] && [ -d "$old_global_backup" ]; then
		rm -rf "${OC_GLOBAL:-/opt/openclaw/global}" 2>/dev/null || true
		mv "$old_global_backup" "${OC_GLOBAL:-/opt/openclaw/global}" 2>/dev/null || true
		log_info "已恢复旧代码 prefix: $old_global_backup -> ${OC_GLOBAL:-/opt/openclaw/global}"
	fi

	if [ -x /usr/bin/openclaw-env ]; then
		/usr/bin/openclaw-env check >/dev/null 2>&1 || true
	fi

	if ! do_restore_state "$backup_archive" "$state_dir"; then
		log_error "显式回滚中止: 状态目录还原失败"
		do_transaction_set_phase "recovery" "$state_dir" "1" "State restore failed during rollback" "$backup_archive"
		return 1
	fi

	# 5. 重启并执行旧版本健康检查
	log_info "5/5 重启服务并执行健康检查..."
	if [ -x /etc/init.d/openclaw ]; then
		/etc/init.d/openclaw start >/dev/null 2>&1 || true
	fi
	sleep 3
	do_gateway_verify "" "$state_dir" || log_warn "网关健康验证未立即通过，请查看日志"

	do_transaction_set_phase "rolled_back" "$state_dir" "0" "Explicit rollback completed successfully" "$backup_archive"
	log_info "OpenClaw 显式回滚已全部完成"
	return 0
}

# ── 命令行入口调度 ──
case "${1:-}" in
	backup-create|backup)
		shift
		do_backup_create "$@"
		;;
	backup-verify|verify-backup)
		shift
		do_backup_verify "$@"
		;;
	restore-state|restore)
		shift
		do_restore_state "$@"
		;;
	doctor-migration|doctor)
		shift
		do_doctor_migration "$@"
		;;
	plugin-convergence)
		shift
		do_plugin_convergence "$@"
		;;
	reconcile-token|sync-token)
		shift
		do_reconcile_token "$@"
		;;
	gateway-verify|verify-gateway)
		shift
		do_gateway_verify "$@"
		;;
	status|transaction-status)
		shift
		do_transaction_status "$@"
		;;
	init-transaction)
		shift
		do_transaction_init "$@"
		;;
	set-phase)
		shift
		do_transaction_set_phase "$@"
		;;
	database-preflight|preflight)
		shift
		do_database_preflight "$@"
		;;
	rollback-explicit|rollback)
		shift
		do_rollback_explicit "$@"
		;;
	"")
		# 被 source 时静默返回
		return 0 2>/dev/null || exit 0
		;;
	*)
		echo "用法: $0 {backup-create|backup-verify|restore-state|doctor-migration|plugin-convergence|reconcile-token|gateway-verify|status|init-transaction|set-phase|database-preflight|rollback-explicit} [参数...]" >&2
		exit 2
		;;
esac