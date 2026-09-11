local M = {}

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function is_array(value)
	if type(value) ~= "table" then return false end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
		count = count + 1
	end
	return count == #value
end

function M.sanitize_output(value, limit)
	local text = tostring(value or "")
	text = text:gsub("\27%[[%d;?]*[ -/]*[@-~]", "")
	text = text:gsub("([Tt][Oo][Kk][Ee][Nn]%s*[:=]%s*)[^%s,;]+", "%1[REDACTED]")
	text = text:gsub("([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]%s*[:=]%s*)[^%s,;]+", "%1[REDACTED]")
	text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "")
	return trim(text):sub(1, limit or 300)
end

local function extract_json_object(text)
	local start_at = text:find("{", 1, true)
	while start_at do
		local depth, in_string, escaped = 0, false, false
		for i = start_at, #text do
			local char = text:sub(i, i)
			if in_string then
				if escaped then
					escaped = false
				elseif char == "\\" then
					escaped = true
				elseif char == '"' then
					in_string = false
				end
			elseif char == '"' then
				in_string = true
			elseif char == "{" then
				depth = depth + 1
			elseif char == "}" then
				depth = depth - 1
				if depth == 0 then return text:sub(start_at, i) end
			end
		end
		start_at = text:find("{", start_at + 1, true)
	end
	return nil
end

function M.valid_request_id(value)
	return type(value) == "string" and value ~= "" and value:match("^[a-zA-Z0-9_-]+$") ~= nil
end

function M.parse_list(output, decode)
	if type(output) ~= "string" or trim(output) == "" then
		return nil, "DEVICES_EMPTY_OUTPUT", "设备列表命令没有返回数据"
	end
	local json_text = extract_json_object(output)
	if not json_text then
		return nil, "DEVICES_INVALID_JSON", "设备列表不是有效 JSON"
	end
	local ok, data = pcall(decode, json_text)
	if not ok or type(data) ~= "table" then
		return nil, "DEVICES_INVALID_JSON", "设备列表 JSON 解析失败"
	end
	if not is_array(data.pending) or not is_array(data.paired) then
		return nil, "DEVICES_SCHEMA_MISMATCH", "设备列表缺少 pending/paired 数组"
	end
	for _, item in ipairs(data.pending) do
		if type(item) ~= "table" or not M.valid_request_id(item.requestId) then
			return nil, "DEVICES_SCHEMA_MISMATCH", "待配对设备包含无效的 requestId"
		end
		if type(item.deviceId) ~= "string" or item.deviceId == "" then
			return nil, "DEVICES_SCHEMA_MISMATCH", "待配对设备包含无效的 deviceId"
		end
	end
	for _, item in ipairs(data.paired) do
		if type(item) ~= "table" then
			return nil, "DEVICES_SCHEMA_MISMATCH", "已配对设备包含无效条目"
		end
	end
	return data
end

function M.find_pending(data, request_id)
	for _, item in ipairs(data and data.pending or {}) do
		if item.requestId == request_id then return item end
	end
	return nil
end

-- luci.jsonc 会把普通的空 Lua table 编码成 {}。解析一个真正的 JSON 数组
-- 可取得其内部数组标记，确保 API 的空列表稳定输出为 []。
function M.json_array(value, parse_json)
	if type(value) == "table" and next(value) ~= nil then
		return value
	end
	if type(parse_json) == "function" then
		local ok, parsed = pcall(parse_json, "[]")
		if ok and type(parsed) == "table" then return parsed end
	end
	return type(value) == "table" and value or {}
end

function M.confirm_approval(before_item, after_data)
	if type(before_item) ~= "table" or type(after_data) ~= "table" then return false end
	local device_id = before_item.deviceId
	if type(device_id) ~= "string" or device_id == "" then return false end
	for _, item in ipairs(after_data.paired or {}) do
		if type(item) == "table" and item.deviceId == device_id then return true end
	end
	return false
end

function M.evaluate_approval(exit_code, before_item, after_data, after_error, detail)
	if exit_code ~= 0 then
		return "error", exit_code == 124 and "APPROVAL_TIMEOUT" or "APPROVAL_CLI_FAILED", detail ~= "" and detail or "批准失败"
	end
	if not after_data then
		return "unconfirmed", after_error or "APPROVAL_UNCONFIRMED", "批准命令已完成，但无法确认设备状态"
	end
	if M.confirm_approval(before_item, after_data) then
		return "ok", nil, detail ~= "" and detail or "设备配对已确认"
	end
	if M.find_pending(after_data, before_item.requestId) then
		return "error", "APPROVAL_NOT_APPLIED", "批准命令未使设备进入已配对列表"
	end
	return "unconfirmed", "APPROVAL_UNCONFIRMED", "请求已不在待批准列表，但无法确认对应设备已配对"
end

return M
