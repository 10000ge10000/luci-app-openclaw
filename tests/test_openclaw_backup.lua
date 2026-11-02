package.path = "./luasrc/?.lua;./luasrc/?/?.lua;" .. package.path

local backup = require "openclaw.backup"

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected=" .. tostring(expected) .. " actual=" .. tostring(actual), 2)
	end
end

local function assert_rejected(names, verbose, strict, needle, message)
	local info, err = backup.validate_listing(names, verbose, strict)
	assert_equal(info, nil, message)
	if needle and not tostring(err):find(needle, 1, true) then
		error(message .. ": unexpected error " .. tostring(err), 2)
	end
end

-- ── 文件名白名单 ──
assert_equal(backup.valid_name("2026-03-11T18-28-43.149Z-openclaw-backup.tar.gz"), "2026-03-11T18-28-43.149Z-openclaw-backup.tar.gz", "UTC backup name")
assert_equal(backup.valid_name("2026-11-01T08-25-19.171+08-00-openclaw-backup.tar.gz"), "2026-11-01T08-25-19.171+08-00-openclaw-backup.tar.gz", "timezone backup name from OpenClaw 2026.6+")
for _, bad in ipairs({
	"", "openclaw-backup.tar.gz", "../x-openclaw-backup.tar.gz", "a/b-openclaw-backup.tar.gz",
	"$(reboot)-openclaw-backup.tar.gz", "a'b-openclaw-backup.tar.gz", "a b-openclaw-backup.tar.gz",
	"a\"b-openclaw-backup.tar.gz", "a;b-openclaw-backup.tar.gz", "-x-openclaw-backup.tar.gz",
	"a..b-openclaw-backup.tar.gz", "a-openclaw-backup.tar.gz.sh", string.rep("a", 200) .. "-openclaw-backup.tar.gz",
}) do
	assert_equal(backup.valid_name(bad), nil, "name must be rejected: " .. bad)
end

-- ── 展示时间 ──
assert_equal(backup.display_time("2026-03-11T18-28-43.149Z-openclaw-backup.tar.gz"), "2026-03-11 18:28:43", "UTC display time")
assert_equal(backup.display_time("2026-11-01T08-25-19.171+08-00-openclaw-backup.tar.gz"), "2026-11-01 08:25:19", "timezone display time")
assert_equal(backup.display_time("weird-openclaw-backup.tar.gz"), "", "unknown display time")

-- ── 上传命名与会话 ID ──
local up = backup.upload_name(0)
assert_equal(up, "1970-01-01T00-00-00.000Z-uploaded-openclaw-backup.tar.gz", "upload name")
assert_equal(backup.valid_name(up), up, "upload name must pass whitelist")
assert_equal(backup.is_uploaded(up), true, "upload marker")
assert_equal(backup.is_uploaded("2026-03-11T18-28-43.149Z-openclaw-backup.tar.gz"), false, "local backups are not uploads")
assert_equal(backup.valid_upload_id("0123456789abcdef"), "0123456789abcdef", "upload id")
assert_equal(backup.valid_upload_id("../../etc/passwd"), nil, "upload id traversal")
assert_equal(backup.valid_upload_id("0123456789ABCDEF"), nil, "upload id must be lowercase hex")

-- ── 归档结构校验: 真机 OpenClaw 2026.6.11 仅配置备份的实际列表 ──
local R = "2026-11-01T08-25-19.171+08-00-openclaw-backup"
local real_names = R .. "/manifest.json\n" .. R .. "/payload/posix/opt/openclaw/data/.openclaw/openclaw.json\n"
local real_verbose =
	"-rw------- 0/0             770 2026-11-01 08:25 " .. R .. "/manifest.json\n" ..
	"-rw------- 0/0            1779 2026-11-01 07:48 " .. R .. "/payload/posix/opt/openclaw/data/.openclaw/openclaw.json\n"
local info, err = backup.validate_listing(real_names, real_verbose, true)
assert_equal(type(info), "table", "real config-only backup must pass strict validation: " .. tostring(err))
assert_equal(info.src_rel, "opt/openclaw/data/.openclaw", "state dir inside backup")
assert_equal(info.member, R .. "/payload/posix/opt/openclaw/data/.openclaw", "extract member")
assert_equal(info.strip, 7, "strip root/payload/posix + 4 state segments")

-- 不同安装路径的备份 (迁移场景) 仍可解析，strip 随之变化
local mig = "r/manifest.json\nr/payload/posix/mnt/data/openclaw/data/.openclaw/openclaw.json\n"
info = backup.validate_listing(mig, "-rw 0/0 1 d t r/manifest.json\n-rw 0/0 1 d t r/payload/posix/mnt/data/openclaw/data/.openclaw/openclaw.json\n", true)
assert_equal(info.strip, 8, "migration strip count")

-- 目录条目 (GNU tar 列出父目录) 允许，但不在解压范围内
local with_dirs = "r/\nr/manifest.json\nr/payload/\nr/payload/posix/\nr/payload/posix/opt/\nr/payload/posix/opt/s/\nr/payload/posix/opt/s/openclaw.json\nr/payload/posix/opt/s/agents/a.json\n"
local with_dirs_v = "drwx 0/0 0 d t r/\n-rw 0/0 1 d t r/manifest.json\ndrwx 0/0 0 d t r/payload/\ndrwx 0/0 0 d t r/payload/posix/\ndrwx 0/0 0 d t r/payload/posix/opt/\ndrwx 0/0 0 d t r/payload/posix/opt/s/\n-rw 0/0 1 d t r/payload/posix/opt/s/openclaw.json\n-rw 0/0 1 d t r/payload/posix/opt/s/agents/a.json\n"
info, err = backup.validate_listing(with_dirs, with_dirs_v, true)
assert_equal(type(info), "table", "directory entries must be accepted: " .. tostring(err))
assert_equal(info.src_rel, "opt/s", "state dir with directory entries")

-- ── 必须拒绝的归档 ──
assert_rejected("", "", true, "为空", "empty listing")
assert_rejected("/etc/passwd\n", "-rw 0/0 1 d t /etc/passwd\n", true, "绝对路径", "absolute entry")
assert_rejected("r/manifest.json\nr/payload/posix/opt/s/openclaw.json\nr/../../etc/shadow\n", nil, false, "路径穿越", "dotdot entry even in non-strict mode")
assert_rejected("r/manifest.json\nx/payload/posix/opt/s/openclaw.json\n", nil, false, "多个根目录", "multiple roots")
assert_rejected("r/payload/posix/opt/s/openclaw.json\n", nil, false, "manifest", "missing manifest")
assert_rejected("r/manifest.json\nr/payload/posix/opt/s/other.json\n", nil, false, "openclaw.json", "missing openclaw.json")

-- 上传归档: 状态目录之外的文件 (如 /etc/init.d) 必须拒绝
local escape = "r/manifest.json\nr/payload/posix/opt/s/openclaw.json\nr/payload/posix/etc/init.d/evil\n"
assert_rejected(escape, "-rw 0/0 1 d t r/manifest.json\n-rw 0/0 1 d t r/payload/posix/opt/s/openclaw.json\n-rwx 0/0 1 d t r/payload/posix/etc/init.d/evil\n", true, "状态目录之外", "strict escape")
-- 非 strict (本机备份) 不拒绝，但解压 member 只覆盖状态目录子树
info = backup.validate_listing(escape, nil, false)
assert_equal(info.member, "r/payload/posix/opt/s", "non-strict restores only the state subtree")

-- 上传归档: 符号链接 / 硬链接 / 设备文件必须拒绝
local base_names = "r/manifest.json\nr/payload/posix/opt/s/openclaw.json\nr/payload/posix/opt/s/link\n"
assert_rejected(base_names, "-rw 0/0 1 d t r/manifest.json\n-rw 0/0 1 d t r/payload/posix/opt/s/openclaw.json\nlrwxrwxrwx 0/0 0 d t r/payload/posix/opt/s/link -> /etc\n", true, "链接", "symlink")
assert_rejected(base_names, "-rw 0/0 1 d t r/manifest.json\n-rw 0/0 1 d t r/payload/posix/opt/s/openclaw.json\nhrw-r--r-- 0/0 0 d t r/payload/posix/opt/s/link link to r/manifest.json\n", true, "链接", "hardlink (h type)")
assert_rejected(base_names, "-rw 0/0 1 d t r/manifest.json\n-rw 0/0 1 d t r/payload/posix/opt/s/openclaw.json\n-rw-r--r-- 0/0 0 d t r/payload/posix/opt/s/link link to r/manifest.json\n", true, "硬链接", "hardlink (GNU listing)")
assert_rejected(base_names, "-rw 0/0 1 d t r/manifest.json\n-rw 0/0 1 d t r/payload/posix/opt/s/openclaw.json\ncrw 0/0 0 d t r/payload/posix/opt/s/link\n", true, "特殊文件", "char device")
assert_rejected(base_names, "-rw 0/0 1 d t r/manifest.json\n", true, "无法校验", "verbose listing mismatch")

-- ── base64 解码 (纯 Lua 回退路径与 nixio 结果一致) ──
assert_equal(backup.b64decode("aGVsbG8="), "hello", "b64 one pad")
assert_equal(backup.b64decode("aGk="), "hi", "b64 pad")
assert_equal(backup.b64decode("aGVsbG8gd29ybGQh"), "hello world!", "b64 no pad")
assert_equal(backup.b64decode("AP8Q"), "\0\255\16", "b64 binary")
assert_equal(backup.b64decode(""), "", "b64 empty")

print("ok")
