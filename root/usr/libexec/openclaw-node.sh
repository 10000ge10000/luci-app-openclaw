#!/bin/sh
# Shared OpenClaw Node.js runtime/version helpers.

oc_normalize_node_version() {
	local version="${1:-}"
	local old_ifs

	[ -n "$version" ] || return 1
	case "$version" in
		v*) version="${version#v}" ;;
	esac
	case "$version" in
		''|*[!0-9.]*) return 1 ;;
	esac

	old_ifs="$IFS"
	IFS=.
	set -- $version
	IFS="$old_ifs"

	[ "$#" -eq 3 ] || return 1
	for part in "$1" "$2" "$3"; do
		case "$part" in
			''|*[!0-9]*) return 1 ;;
		esac
	done

	printf '%s.%s.%s\n' "$1" "$2" "$3"
}

oc_node_version_ge() {
	local lhs rhs
	local old_ifs
	local lhs_major lhs_minor lhs_patch
	local rhs_major rhs_minor rhs_patch

	lhs=$(oc_normalize_node_version "${1:-}") || return 1
	rhs=$(oc_normalize_node_version "${2:-}") || return 1

	old_ifs="$IFS"
	IFS=.
	set -- $lhs
	lhs_major="$1"
	lhs_minor="$2"
	lhs_patch="$3"
	set -- $rhs
	rhs_major="$1"
	rhs_minor="$2"
	rhs_patch="$3"
	IFS="$old_ifs"

	[ "$lhs_major" -gt "$rhs_major" ] && return 0
	[ "$lhs_major" -lt "$rhs_major" ] && return 1
	[ "$lhs_minor" -gt "$rhs_minor" ] && return 0
	[ "$lhs_minor" -lt "$rhs_minor" ] && return 1
	[ "$lhs_patch" -ge "$rhs_patch" ]
}

oc_read_node_version() {
	local node_bin="${1:-}"
	local version

	[ -n "$node_bin" ] || return 1
	[ -x "$node_bin" ] || return 1

	version=$("$node_bin" --version 2>/dev/null) || return 1
	oc_normalize_node_version "$version"
}
