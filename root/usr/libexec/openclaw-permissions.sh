#!/bin/sh
# OpenClaw state permission helper.
# Keep runtime state and managed npm plugin generations writable by the
# openclaw user. OpenClaw 2026.6.33 installs and retires these generations
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

oc_perm_chown_tree() {
	local root="$1" owner="$2"
	[ -d "$root" ] && [ ! -L "$root" ] || return 0
	find "$root" -xdev ! -type l -print0 2>/dev/null | xargs -0 chown -h "$owner" 2>/dev/null || true
}

oc_perm_chmod_tree() {
	local root="$1" mode="$2"
	[ -d "$root" ] && [ ! -L "$root" ] || return 0
	find "$root" -xdev ! -type l -print0 2>/dev/null | xargs -0 chmod "$mode" 2>/dev/null || true
}

oc_fix_npm_projects_permissions() {
	local state_dir npm_projects
	state_dir="$(oc_perm_state_dir "${1:-}")"
	npm_projects="${state_dir}/npm/projects"
	[ -d "$npm_projects" ] || return 0

	# The official plugin installer runs as openclaw and the Gateway removes
	# retired generations asynchronously. Keep the complete tree writable by
	# that user, including plugin source files.
	oc_perm_chown_tree "$npm_projects" openclaw:openclaw
	oc_perm_chmod_tree "$npm_projects" u+rwX,go+rX
}

oc_fix_state_permissions() {
	local state_dir data_dir ext_dir archive_dir config_file agent_dir
	state_dir="$(oc_perm_state_dir "${1:-}")"
	data_dir="$(oc_perm_data_dir_from_state "$state_dir")"
	ext_dir="${state_dir}/extensions"
	archive_dir="${state_dir}/archived-extensions"
	config_file="${state_dir}/openclaw.json"

		[ -d "$data_dir" ] && [ ! -L "$data_dir" ] && chown -h openclaw:openclaw "$data_dir" 2>/dev/null || true
	[ -d "$state_dir" ] || mkdir -p "$state_dir" 2>/dev/null || true
		[ -d "$state_dir" ] && [ ! -L "$state_dir" ] && chown -h openclaw:openclaw "$state_dir" 2>/dev/null || true
	[ -d "$state_dir" ] && chmod 755 "$state_dir" 2>/dev/null || true

	if [ -d "$state_dir" ]; then
		find "$state_dir" -xdev -user root ! -type l \
			! -path "${ext_dir}*" \
			! -path "${archive_dir}*" \
			! -path "${state_dir}/npm/projects*" \
				-print0 2>/dev/null | xargs -0 chown -h openclaw:openclaw 2>/dev/null || true
	fi

		[ -f "$config_file" ] && chown -h openclaw:openclaw "$config_file" 2>/dev/null || true
		[ -f "$config_file" ] && chmod 0600 "$config_file" 2>/dev/null || true
		[ -f "${config_file}.bak" ] && chown -h openclaw:openclaw "${config_file}.bak" 2>/dev/null || true
		[ -f "${config_file}.bak" ] && chmod 0600 "${config_file}.bak" 2>/dev/null || true

	agent_dir="${state_dir}/agents/main/agent"
		if [ -d "$agent_dir" ]; then
				chown -h openclaw:openclaw "$agent_dir" 2>/dev/null || true
			chmod 755 "$agent_dir" 2>/dev/null || true
			if [ -f "${agent_dir}/auth-profiles.json" ]; then
				chown -h openclaw:openclaw "${agent_dir}/auth-profiles.json" 2>/dev/null || true
				chmod 0600 "${agent_dir}/auth-profiles.json" 2>/dev/null || true
			fi
		fi

	if [ -d "$ext_dir" ]; then
		oc_perm_chown_tree "$ext_dir" root:root
		oc_perm_chmod_tree "$ext_dir" 755
	fi
	if [ -d "$archive_dir" ]; then
		oc_perm_chown_tree "$archive_dir" root:root
		oc_perm_chmod_tree "$archive_dir" 700
	fi

	oc_fix_npm_projects_permissions "$state_dir"
}

oc_prepare_openclaw_workdirs() {
	local data_dir state_dir npm_dir
	data_dir="${1:-${OC_DATA:-/opt/openclaw/data}}"
	state_dir="${data_dir}/.openclaw"
	npm_dir="${state_dir}/npm/projects"

	mkdir -p "${data_dir}/.npm" "${data_dir}/.tmp" "$npm_dir" "${state_dir}/extensions" 2>/dev/null || true
	oc_perm_chown_tree "${data_dir}/.npm" openclaw:openclaw
	oc_perm_chown_tree "${data_dir}/.tmp" openclaw:openclaw
	for dir in "$data_dir" "$state_dir" "${state_dir}/npm" "$npm_dir"; do
			[ -d "$dir" ] && [ ! -L "$dir" ] && chown -h openclaw:openclaw "$dir" 2>/dev/null || true
	done
	chmod u+rwx,go+rx "${data_dir}/.npm" "${data_dir}/.tmp" "$state_dir" "${state_dir}/npm" "$npm_dir" 2>/dev/null || true

	# During install/upgrade, allow openclaw to update npm generations.
	oc_perm_chown_tree "$npm_dir" openclaw:openclaw
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
	*)
		echo "Usage: $0 {fix-state [state_dir]|fix-npm-projects [state_dir]|prepare-workdirs [data_dir]}" >&2
		exit 2
		;;
esac
