local M = {}

function M.normalize_https_url(value)
	local url = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if url == "" or url:match("[%z\1-\32\127'\"\\<>]") then return nil end
	if not url:match("^https://[a-zA-Z0-9%-%._~:/?#%[%]@!$&()*+,;=]+$") then return nil end
	local authority = url:match("^https://([^/%?#]+)")
	if not authority or authority:find("@", 1, true) then return nil end

	local host, port
	if authority:sub(1, 1) == "[" then
		host, port = authority:match("^(%[[0-9a-fA-F:%.]+%]):?(%d*)$")
	else
		host, port = authority:match("^([a-zA-Z0-9][a-zA-Z0-9%.%-]*):?(%d*)$")
	end
	if not host or host == "" then return nil end
	if port and port ~= "" then
		local number = tonumber(port)
		if not number or number < 1 or number > 65535 then return nil end
	end
	return url:gsub("/+$", "")
end

function M.html_attr(value)
	return tostring(value or "")
		:gsub("&", "&amp;")
		:gsub("<", "&lt;")
		:gsub(">", "&gt;")
		:gsub('"', "&quot;")
		:gsub("'", "&#39;")
end

return M
