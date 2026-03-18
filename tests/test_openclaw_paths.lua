local script_dir = arg[0]:match("^(.*)/[^/]+$")
local repo_root = script_dir:gsub("/tests$", "")

package.path = table.concat({
	repo_root .. "/luasrc/?.lua",
	repo_root .. "/luasrc/?/init.lua",
	repo_root .. "/luasrc/?/?.lua",
	package.path,
}, ";")

local paths = require("openclaw.paths")

local function assert_eq(actual, expected, label)
	if actual ~= expected then
		error(string.format("%s: expected %q, got %q", label, expected, actual), 2)
	end
end

local function check_root(input, expected_root, expected_base)
	local normalized = paths.normalize_install_root(input)
	local derived = paths.derive_paths(input)

	assert_eq(normalized, expected_root, "normalized root")
	assert_eq(derived.install_root, expected_root, "derived install root")
	assert_eq(derived.oc_root, expected_base, "derived OpenClaw root")
	assert_eq(derived.node_base, expected_base .. "/node", "node base")
	assert_eq(derived.oc_global, expected_base .. "/global", "global base")
	assert_eq(derived.oc_data, expected_base .. "/data", "data base")
end

check_root(nil, "/opt", "/opt/openclaw")
check_root("", "/opt", "/opt/openclaw")
check_root("/mnt/emmc/", "/mnt/emmc", "/mnt/emmc/openclaw")
check_root("relative/path", "/opt", "/opt/openclaw")
check_root("/", "/", "/openclaw")

print("ok")
