#!/bin/sh
# Shared OpenClaw install-root and derived-path helpers.

OPENCLAW_DEFAULT_INSTALL_ROOT="${OPENCLAW_DEFAULT_INSTALL_ROOT:-/opt}"
OPENCLAW_OPT_COMPAT_ROOT="${OPENCLAW_OPT_COMPAT_ROOT:-/opt}"

oc_normalize_install_root() {
	local path="$1"

	if [ -z "$path" ]; then
		path="$OPENCLAW_DEFAULT_INSTALL_ROOT"
	fi

	case "$path" in
		/*) ;;
		*) path="$OPENCLAW_DEFAULT_INSTALL_ROOT" ;;
	esac

	while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
		path="${path%/}"
	done

	[ -n "$path" ] || path="/"
	printf '%s\n' "$path"
}

oc_read_install_root_from_uci() {
	if command -v uci >/dev/null 2>&1; then
		uci -q get openclaw.main.install_root 2>/dev/null
	fi
}

oc_load_paths() {
	local requested_root="$1"
	local install_root="$requested_root"

	[ -n "$install_root" ] || install_root="${OPENCLAW_INSTALL_ROOT:-}"
	[ -n "$install_root" ] || install_root="$(oc_read_install_root_from_uci)"

	OPENCLAW_INSTALL_ROOT="$(oc_normalize_install_root "$install_root")"
	if [ "$OPENCLAW_INSTALL_ROOT" = "/" ]; then
		OC_ROOT="/openclaw"
	else
		OC_ROOT="${OPENCLAW_INSTALL_ROOT}/openclaw"
	fi

	NODE_BASE="${OC_ROOT}/node"
	OC_GLOBAL="${OC_ROOT}/global"
	OC_DATA="${OC_ROOT}/data"

	export OPENCLAW_INSTALL_ROOT OC_ROOT NODE_BASE OC_GLOBAL OC_DATA
}

oc_find_existing_path() {
	local path
	path="$(oc_normalize_install_root "$1")"

	while [ "$path" != "/" ] && [ ! -e "$path" ]; do
		path="${path%/*}"
		[ -n "$path" ] || path="/"
	done

	printf '%s\n' "$path"
}

oc_install_root_uses_opt_workaround() {
	[ "$(oc_normalize_install_root "${1:-$OPENCLAW_INSTALL_ROOT}")" = "/opt" ]
}

oc_ensure_opt_compat_link() {
	local target_root="$1"
	local compat_root compat_link current_target

	target_root="$(oc_normalize_install_root "$target_root")"
	[ "$target_root" = "/opt" ] && return 0

	compat_root="$(oc_normalize_install_root "$OPENCLAW_OPT_COMPAT_ROOT")"
	compat_link="${compat_root}/openclaw"

	if [ -L "$compat_link" ]; then
		current_target="$(readlink "$compat_link" 2>/dev/null || true)"
		[ "$current_target" = "$target_root" ] && return 0
		return 1
	fi

	if [ -e "$compat_link" ]; then
		return 1
	fi

	mkdir -p "$compat_root"
	ln -s "$target_root" "$compat_link"
}

oc_print_env() {
	oc_load_paths "$1"
	cat <<EOF
OPENCLAW_INSTALL_ROOT=$OPENCLAW_INSTALL_ROOT
OC_ROOT=$OC_ROOT
NODE_BASE=$NODE_BASE
OC_GLOBAL=$OC_GLOBAL
OC_DATA=$OC_DATA
OPENCLAW_OPT_COMPAT_ROOT=$OPENCLAW_OPT_COMPAT_ROOT
EOF
}
