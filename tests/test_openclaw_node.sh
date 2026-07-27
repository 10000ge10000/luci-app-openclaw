#!/bin/sh
set -eu

. ./root/usr/libexec/openclaw-node.sh

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

[ "$(oc_normalize_node_version v22.23.1)" = "22.23.1" ] || fail "normalize v"
oc_node_version_ge 22.19.0 22.19.0 || fail "exact version"
oc_node_version_ge 22.19.1 22.19.0 || fail "patch version"
oc_node_version_ge 22.23.1 22.19.0 || fail "supported LTS version"
if oc_node_version_ge 22.18.1 22.19.0; then
	fail "older minor accepted"
fi

echo "ok"
