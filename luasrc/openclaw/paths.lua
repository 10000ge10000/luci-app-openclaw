local M = {}

local DEFAULT_INSTALL_ROOT = "/opt"

function M.normalize_install_root(path)
	if type(path) ~= "string" or path == "" then
		return DEFAULT_INSTALL_ROOT
	end

	if path:sub(1, 1) ~= "/" then
		return DEFAULT_INSTALL_ROOT
	end

	path = path:gsub("/+$", "")
	if path == "" then
		path = "/"
	end

	return path
end

function M.derive_paths(path)
	local install_root = M.normalize_install_root(path)
	local oc_root = (install_root == "/") and "/openclaw" or (install_root .. "/openclaw")

	return {
		install_root = install_root,
		oc_root = oc_root,
		node_base = oc_root .. "/node",
		oc_global = oc_root .. "/global",
		oc_data = oc_root .. "/data",
	}
end

return M
