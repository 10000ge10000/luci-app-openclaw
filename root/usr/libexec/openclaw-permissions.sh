#!/bin/sh
# OpenClaw state permission helper.
# Keep runtime state and managed npm plugin generations writable by the
# openclaw user. OpenClaw 2026.6.11 installs and retires these generations
# itself, so root-owned files under npm/projects break later cleanup.

oc_perm_state_dir() {
	if [ -n "${1:-}" ]; then
		printf '%s\n' "$1"
	elif [ -n "${OPENCLAW_STATE_DIR:-}" ]; then
		printf '%s\n' "$OPENCLAW_STATE_DIR"
	elif [ -n "${OC_DATA:-}" ]; then
		printf '%s/.openclaw\n' "$OC_DATA"
	else
		printf '/opt/openclaw/data/.openclaw\n'
	fi
}

oc_perm_data_dir_from_state() {
	local state_dir="$1"
	case "$state_dir" in
		*/.openclaw) printf '%s\n' "${state_dir%/.openclaw}" ;;
		*) printf '%s\n' "${OC_DATA:-/opt/openclaw/data}" ;;
	esac
}

oc_fix_npm_projects_permissions() {
	local state_dir npm_projects
	state_dir="$(oc_perm_state_dir "${1:-}")"
	npm_projects="${state_dir}/npm/projects"
	[ -d "$npm_projects" ] || return 0

	# The official plugin installer runs as openclaw and the Gateway removes
	# retired generations asynchronously. Keep the complete tree writable by
	# that user, including plugin source files.
	chown -R openclaw:openclaw "$npm_projects" 2>/dev/null || true
	chmod -R u+rwX,go+rX "$npm_projects" 2>/dev/null || true
}

oc_fix_state_permissions() {
	local state_dir data_dir ext_dir archive_dir config_file agent_dir
	state_dir="$(oc_perm_state_dir "${1:-}")"
	data_dir="$(oc_perm_data_dir_from_state "$state_dir")"
	ext_dir="${state_dir}/extensions"
	archive_dir="${state_dir}/archived-extensions"
	config_file="${state_dir}/openclaw.json"

	[ -d "$data_dir" ] && chown openclaw:openclaw "$data_dir" 2>/dev/null || true
	[ -d "$state_dir" ] || mkdir -p "$state_dir" 2>/dev/null || true
	[ -d "$state_dir" ] && chown openclaw:openclaw "$state_dir" 2>/dev/null || true
	[ -d "$state_dir" ] && chmod 755 "$state_dir" 2>/dev/null || true

	if [ -d "$state_dir" ]; then
		find "$state_dir" -user root \
			! -path "${archive_dir}*" \
			! -path "${state_dir}/npm/projects*" \
			-exec chown openclaw:openclaw {} \; 2>/dev/null || true
	fi

	[ -f "$config_file" ] && chown openclaw:openclaw "$config_file" 2>/dev/null || true
	[ -f "${config_file}.bak" ] && chown openclaw:openclaw "${config_file}.bak" 2>/dev/null || true

	agent_dir="${state_dir}/agents/main/agent"
	if [ -d "$agent_dir" ]; then
		chown openclaw:openclaw "$agent_dir" 2>/dev/null || true
		chmod 755 "$agent_dir" 2>/dev/null || true
	fi

	if [ -d "$ext_dir" ]; then
		chown -R openclaw:openclaw "$ext_dir" 2>/dev/null || true
		chmod -R 755 "$ext_dir" 2>/dev/null || true
	fi
	if [ -d "$archive_dir" ]; then
		chown -R root:root "$archive_dir" 2>/dev/null || true
		chmod -R 755 "$archive_dir" 2>/dev/null || true
	fi

	oc_fix_npm_projects_permissions "$state_dir"
}

oc_prepare_openclaw_workdirs() {
	local data_dir state_dir npm_dir
	data_dir="${1:-${OC_DATA:-/opt/openclaw/data}}"
	state_dir="${data_dir}/.openclaw"
	npm_dir="${state_dir}/npm/projects"

	mkdir -p "${data_dir}/.npm" "${data_dir}/.tmp" "$npm_dir" "${state_dir}/extensions" 2>/dev/null || true
	chown -R openclaw:openclaw "${data_dir}/.npm" "${data_dir}/.tmp" 2>/dev/null || true
	chown openclaw:openclaw "$data_dir" "$state_dir" "${state_dir}/npm" "$npm_dir" 2>/dev/null || true
	[ -d "${state_dir}/extensions" ] && chown -R openclaw:openclaw "${state_dir}/extensions" 2>/dev/null || true
	[ -d "${state_dir}/extensions" ] && chmod -R 755 "${state_dir}/extensions" 2>/dev/null || true
	chmod u+rwx,go+rx "${data_dir}/.npm" "${data_dir}/.tmp" "$state_dir" "${state_dir}/npm" "$npm_dir" "${state_dir}/extensions" 2>/dev/null || true

	# During install/upgrade, allow openclaw to update npm generations.
	[ -d "$npm_dir" ] && chown -R openclaw:openclaw "$npm_dir" 2>/dev/null || true
}

oc_patch_control_ui_security_headers() {
	local global_dir="${1:-${OC_GLOBAL:-/opt/openclaw/global}}"
	local dist_dir=""
	for d in "${global_dir}/lib/node_modules/openclaw/dist" "${global_dir}/node_modules/openclaw/dist" "/opt/openclaw/global/lib/node_modules/openclaw/dist" "/opt/openclaw/node/lib/node_modules/openclaw/dist"; do
		if [ -d "$d" ]; then
			dist_dir="$d"
			break
		fi
	done
	[ -n "$dist_dir" ] || return 0
	# 允许 LuCI 界面以 iframe 内嵌官方 Web 控制台 (Control UI / WebChat)
	# 移除 X-Frame-Options: DENY 并将 frame-ancestors 放宽
	for f in "$dist_dir"/control-ui-*.js; do
		[ -f "$f" ] || continue
		if grep -q 'res.setHeader("X-Frame-Options", "DENY");' "$f" 2>/dev/null; then
			sed -i 's/res.setHeader("X-Frame-Options", "DENY");//g' "$f" 2>/dev/null || true
		fi
		if grep -q '"frame-ancestors '\''none'\''"' "$f" 2>/dev/null; then
			sed -i "s/\"frame-ancestors 'none'\"/\"frame-ancestors *\"/g" "$f" 2>/dev/null || true
		fi
	done
}

if [ "${OPENCLAW_PERMISSIONS_SOURCED:-0}" = "1" ]; then
	return 0
fi

case "${1:-fix-state}" in
	fix-state)
		shift || true
		oc_fix_state_permissions "${1:-}"
		;;
	fix-npm-projects)
		shift || true
		oc_fix_npm_projects_permissions "${1:-}"
		;;
	prepare-workdirs)
		shift || true
		oc_prepare_openclaw_workdirs "${1:-}"
		;;
	patch-control-ui)
		shift || true
		oc_patch_control_ui_security_headers "${1:-}"
		;;
	*)
		echo "Usage: $0 {fix-state [state_dir]|fix-npm-projects [state_dir]|prepare-workdirs [data_dir]|patch-control-ui [global_dir]}" >&2
		exit 2
		;;
esac
