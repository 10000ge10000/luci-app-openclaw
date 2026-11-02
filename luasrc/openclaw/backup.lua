-- luci-app-openclaw — 备份归档校验 helper (#111)
--
-- OpenClaw `backup create` 归档结构:
--   <root>/manifest.json
--   <root>/payload/posix/<源文件绝对路径去掉开头的 />
-- 旧版恢复逻辑把整个 payload/posix/ 解压到 /，归档里有什么路径就写什么路径。
-- 本机创建的备份尚可接受，一旦允许上传，伪造归档即可覆盖任意系统文件。
-- 这里只做纯字符串校验 (不执行命令)，由控制器负责调用 tar。
local M = {}

M.MAX_UPLOAD_BYTES = 20 * 1024 * 1024
M.MAX_CHUNK_B64 = 1024 * 1024
M.UPLOAD_MARKER = "-uploaded"

-- 备份文件名白名单: 只允许字母数字与 . _ + -，且必须以 -openclaw-backup.tar.gz 结尾。
-- 文件名会进入 shell 命令与前端 onclick，宽松匹配会导致命令注入或 XSS。
function M.valid_name(name)
	name = tostring(name or "")
	if #name == 0 or #name > 160 then return nil end
	if not name:match("^[%w][%w%._%+%-]*%-openclaw%-backup%.tar%.gz$") then return nil end
	if name:find("..", 1, true) then return nil end
	return name
end

function M.is_uploaded(name)
	return tostring(name or ""):find(M.UPLOAD_MARKER .. "-openclaw-backup.tar.gz", 1, true) ~= nil
end

-- 2026-03-11T18-28-43.149Z-...  /  2026-11-01T08-25-19.171+08-00-...  -> 2026-03-11 18:28:43
function M.display_time(name)
	local d, h, mi, s = tostring(name or ""):match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d)%-(%d%d)%-(%d%d)")
	if not d then return "" end
	return d .. " " .. h .. ":" .. mi .. ":" .. s
end

-- 上传文件的落盘名: <UTC 时间>-uploaded-openclaw-backup.tar.gz
function M.upload_name(now)
	return os.date("!%Y-%m-%dT%H-%M-%S", now or os.time()) .. ".000Z" .. M.UPLOAD_MARKER .. "-openclaw-backup.tar.gz"
end

function M.valid_upload_id(id)
	id = tostring(id or "")
	if id:match("^[0-9a-f]+$") and #id == 16 then return id end
	return nil
end

local function split_lines(text)
	local out = {}
	for line in tostring(text or ""):gmatch("[^\n]+") do
		line = line:gsub("\r$", "")
		if line ~= "" then out[#out + 1] = line end
	end
	return out
end

local function segments(path)
	local n = 0
	for _ in path:gmatch("[^/]+") do n = n + 1 end
	return n
end

local function starts_with(s, prefix)
	return s:sub(1, #prefix) == prefix
end

-- 校验 `tar -tzf` 列表 (names_text) 与可选的 `tar -tvzf` 列表 (verbose_text)。
-- strict=true 用于上传归档: 只允许普通文件与目录，且所有 payload 必须位于状态目录子树内。
-- 返回 { root, src_rel, member, strip } 或 nil, 错误信息。
-- 恢复时只解压 member (备份中的状态目录子树)，--strip-components=strip 后写入当前状态目录，
-- 因此即使非 strict 模式，子树之外的条目也不会被写到磁盘。
function M.validate_listing(names_text, verbose_text, strict)
	local names = split_lines(names_text)
	if #names == 0 then return nil, "备份文件为空或无法读取" end

	local root
	local payload = {}
	local has_manifest = false
	for _, raw in ipairs(names) do
		local name = raw:gsub("/+$", "")
		if name:sub(1, 1) == "/" then return nil, "备份包含绝对路径条目: " .. raw end
		for seg in name:gmatch("[^/]+") do
			if seg == ".." then return nil, "备份包含路径穿越条目: " .. raw end
		end
		local first = name:match("^([^/]+)")
		if not first then return nil, "备份包含无效条目" end
		root = root or first
		if first ~= root then return nil, "备份包含多个根目录，格式无法识别" end
		if name == root .. "/manifest.json" then
			has_manifest = true
		elseif name ~= root and name ~= root .. "/payload" and name ~= root .. "/payload/posix" then
			local rel = name:match("^" .. root:gsub("%p", "%%%0") .. "/payload/posix/(.+)$")
			if not rel then
				if strict then return nil, "备份包含未知条目: " .. raw end
			else
				payload[#payload + 1] = rel
			end
		end
	end
	if not has_manifest then return nil, "备份缺少 manifest.json，不是 OpenClaw 备份" end

	-- 以层级最浅的 openclaw.json 所在目录作为备份中的状态目录
	local src_rel
	for _, rel in ipairs(payload) do
		local dir = rel:match("^(.+)/openclaw%.json$")
		if dir and (not src_rel or segments(dir) < segments(src_rel)) then src_rel = dir end
	end
	if not src_rel then return nil, "备份中未找到 openclaw.json" end

	if strict then
		for _, rel in ipairs(payload) do
			local inside = rel == src_rel or starts_with(rel, src_rel .. "/")
			local ancestor = starts_with(src_rel, rel .. "/")
			if not inside and not ancestor then
				return nil, "上传的备份包含状态目录之外的文件: /" .. rel
			end
		end
		local lines = split_lines(verbose_text)
		if #lines ~= #names then return nil, "无法校验备份条目类型" end
		for _, line in ipairs(lines) do
			local kind = line:sub(1, 1)
			if kind ~= "-" and kind ~= "d" then
				return nil, "上传的备份包含链接或特殊文件，已拒绝: " .. line
			end
			if line:find(" link to ", 1, true) then
				return nil, "上传的备份包含硬链接，已拒绝: " .. line
			end
		end
	end

	return {
		root = root,
		src_rel = src_rel,
		member = root .. "/payload/posix/" .. src_rel,
		strip = 3 + segments(src_rel),
	}
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64decode_lua(data)
	data = data:gsub("[^%w%+/=]", "")
	if #data % 4 ~= 0 then return nil end
	local map = {}
	for i = 1, #B64 do map[B64:sub(i, i)] = i - 1 end
	local out = {}
	for i = 1, #data, 4 do
		local a, b, c, d = data:byte(i, i + 3)
		a, b = map[string.char(a)], map[string.char(b)]
		local cc, dd = string.char(c), string.char(d)
		if a == nil or b == nil then return nil end
		local n = a * 262144 + b * 4096
		if cc == "=" then
			out[#out + 1] = string.char(math.floor(n / 65536) % 256)
		else
			local cv = map[cc]
			if cv == nil then return nil end
			n = n + cv * 64
			if dd == "=" then
				out[#out + 1] = string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256)
			else
				local dv = map[dd]
				if dv == nil then return nil end
				n = n + dv
				out[#out + 1] = string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
			end
		end
	end
	return table.concat(out)
end

function M.b64decode(data)
	data = tostring(data or "")
	local ok, nixio = pcall(require, "nixio")
	if ok and nixio and nixio.bin and nixio.bin.b64decode then
		local decoded = nixio.bin.b64decode(data)
		if decoded then return decoded end
	end
	return b64decode_lua(data)
end

return M
