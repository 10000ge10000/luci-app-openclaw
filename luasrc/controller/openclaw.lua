-- luci-app-openclaw — LuCI Controller
module("luci.controller.openclaw", package.seeall)

local paths_ok, oc_paths = pcall(require, "openclaw.paths")

local function shellquote(value)
	if paths_ok and oc_paths.shellquote then
		return oc_paths.shellquote(value)
	end
	return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function normalize_install_base(value)
	if paths_ok and oc_paths.normalize_install_path then
		return oc_paths.normalize_install_path(value)
	end
	local raw = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
	if raw == "" then raw = "/opt" end
	if raw:sub(1, 1) ~= "/" then return nil end
	if raw:match("[%s'\"`$;&|<>()]") then return nil end
	local unsafe = { "proc", "sys", "dev", "tmp", "var", "etc", "usr", "bin", "sbin", "lib", "rom", "overlay" }
	if raw == "/" then return nil end
	for _, name in ipairs(unsafe) do
		if raw == "/" .. name or raw:match("^/" .. name .. "/") then return nil end
	end
	if raw:match("/openclaw$") then raw = raw:gsub("/openclaw$", "") end
	return raw ~= "" and raw or nil
end

local function get_path_info(input)
	local uci = require "luci.model.uci".cursor()
	local base = input or uci:get("openclaw", "main", "install_path") or "/opt"
	if paths_ok and oc_paths.derive_paths then
		return oc_paths.derive_paths(base)
	end
	local normalized = normalize_install_base(base) or "/opt"
	local root = normalized .. "/openclaw"
	return {
		install_path = normalized,
		oc_root = root,
		node_base = root .. "/node",
		oc_global = root .. "/global",
		oc_data = root .. "/data",
		config_file = root .. "/data/.openclaw/openclaw.json"
	}
end

local function is_safe_openclaw_root(value)
	if paths_ok and oc_paths.is_safe_openclaw_root then
		return oc_paths.is_safe_openclaw_root(value)
	end
	return value == "/opt/openclaw" or value:match("^/mnt/[^/]+/openclaw$") ~= nil or value:match("^/media/[^/]+/openclaw$") ~= nil
end

local function ensure_openclaw_user(oc_data)
	local sys = require "luci.sys"
	local uid = sys.exec("id -u openclaw 2>/dev/null"):gsub("%s+", "")
	if uid ~= "" then return true end

	local script = [[
OC_UID=1000
while grep -q "^[^:]*:x:${OC_UID}:" /etc/passwd 2>/dev/null; do OC_UID=$((OC_UID + 1)); done
OC_GID=$OC_UID
while grep -q "^[^:]*:x:${OC_GID}:" /etc/group 2>/dev/null; do OC_GID=$((OC_GID + 1)); done
grep -q '^openclaw:' /etc/passwd 2>/dev/null || echo "openclaw:x:${OC_UID}:${OC_GID}:openclaw:${OC_DATA}:/bin/false" >> /etc/passwd
grep -q '^openclaw:' /etc/shadow 2>/dev/null || echo 'openclaw:x:0:0:99999:7:::' >> /etc/shadow
grep -q '^openclaw:' /etc/group 2>/dev/null || echo "openclaw:x:${OC_GID}:" >> /etc/group
]]
	sys.exec("OC_DATA=" .. shellquote(oc_data) .. " sh -c " .. shellquote(script) .. " >/dev/null 2>&1")
	uid = sys.exec("id -u openclaw 2>/dev/null"):gsub("%s+", "")
	return uid ~= ""
end

local function write_wechat_log_and_exit(log_file, exit_file, content, exit_code)
	local f = io.open(log_file, "w")
	if f then
		f:write(content)
		f:close()
	end
	local ef = io.open(exit_file, "w")
	if ef then
		ef:write(tostring(exit_code or 1))
		ef:close()
	end
end

local function find_wechat_plugin_dir(install_path)
	local legacy = install_path .. "/data/.openclaw/extensions/openclaw-weixin"
	if nixio.fs.stat(legacy .. "/openclaw.plugin.json", "type") then return legacy end
	local sys = require "luci.sys"
	local projects = install_path .. "/data/.openclaw/npm/projects"
	local cmd = "find " .. shellquote(projects) .. " -path '*/node_modules/@tencent-weixin/openclaw-weixin/openclaw.plugin.json' -print -quit 2>/dev/null"
	local manifest = (sys.exec(cmd) or ""):gsub("%s+$", "")
	if manifest ~= "" then return manifest:gsub("/openclaw%.plugin%.json$", "") end
	return nil
end

function index()
	-- 主入口: 服务 → OpenClaw (🧠 作为菜单图标)
	local page = entry({"admin", "services", "openclaw"}, alias("admin", "services", "openclaw", "basic"), _("OpenClaw"), 90)
	page.dependent = false

	-- 基本设置 (CBI)
	entry({"admin", "services", "openclaw", "basic"}, cbi("openclaw/basic"), _("基本设置"), 10).leaf = true

	-- 配置管理 (View — 嵌入 oc-config Web 终端)
	entry({"admin", "services", "openclaw", "advanced"}, template("openclaw/advanced"), _("配置管理"), 20).leaf = true

	-- 微信配置 (View — 微信渠道配置向导)
	entry({"admin", "services", "openclaw", "wechat"}, template("openclaw/wechat"), _("微信配置"), 25).leaf = true

	-- Web 控制台 (View — 嵌入 OpenClaw Web UI)
	entry({"admin", "services", "openclaw", "console"}, template("openclaw/console"), _("Web 控制台"), 30).leaf = true

	-- 状态 API (AJAX 接口, 供前端 XHR 调用)
	entry({"admin", "services", "openclaw", "status_api"}, call("action_status"), nil).leaf = true

	-- 服务控制 API
	entry({"admin", "services", "openclaw", "service_ctl"}, call("action_service_ctl"), nil).leaf = true

	-- 安装/升级日志 API (轮询)
	entry({"admin", "services", "openclaw", "setup_log"}, call("action_setup_log"), nil).leaf = true

	-- 版本检查 API (仅检查插件版本)
	entry({"admin", "services", "openclaw", "check_update"}, call("action_check_update"), nil).leaf = true

	-- 卸载运行环境 API
	entry({"admin", "services", "openclaw", "uninstall"}, call("action_uninstall"), nil).leaf = true

	-- 获取网关 Token API (仅认证用户可访问)
	entry({"admin", "services", "openclaw", "get_token"}, call("action_get_token"), nil).leaf = true

	-- 插件升级 API
	entry({"admin", "services", "openclaw", "plugin_upgrade"}, call("action_plugin_upgrade"), nil).leaf = true

	-- 插件升级日志 API (轮询)
	entry({"admin", "services", "openclaw", "plugin_upgrade_log"}, call("action_plugin_upgrade_log"), nil).leaf = true

	-- 配置备份 API (v2026.3.8+: openclaw backup create/verify)
	entry({"admin", "services", "openclaw", "backup"}, call("action_backup"), nil).leaf = true

	-- 系统配置检测 API (安装前检测)
	entry({"admin", "services", "openclaw", "check_system"}, call("action_check_system"), nil).leaf = true

	-- 微信状态 API (检测插件安装和登录状态)
	entry({"admin", "services", "openclaw", "wechat_status"}, call("action_wechat_status"), nil).leaf = true

	-- 微信插件安装 API (后台安装)
	entry({"admin", "services", "openclaw", "wechat_install"}, post("action_wechat_install"), nil).leaf = true

	-- 微信安装日志轮询 API
	entry({"admin", "services", "openclaw", "wechat_install_log"}, call("action_wechat_install_log"), nil).leaf = true

	-- 微信登录 API (启动登录流程)
	entry({"admin", "services", "openclaw", "wechat_login"}, post("action_wechat_login"), nil).leaf = true

	-- 微信登录状态/二维码 API
	entry({"admin", "services", "openclaw", "wechat_login_status"}, call("action_wechat_login_status"), nil).leaf = true

	-- 微信插件卸载 API
	entry({"admin", "services", "openclaw", "wechat_uninstall"}, post("action_wechat_uninstall"), nil).leaf = true

        -- 微信插件检测升级 API
        entry({"admin", "services", "openclaw", "wechat_check_upgrade"}, call("action_wechat_check_upgrade"), nil).leaf = true

        -- 微信插件升级 API
        entry({"admin", "services", "openclaw", "wechat_upgrade_plugin"}, post("action_wechat_upgrade_plugin"), nil).leaf = true

        -- 微信退出/删除账号 API
        entry({"admin", "services", "openclaw", "wechat_logout"}, post("action_wechat_logout"), nil).leaf = true
end-- ═══════════════════════════════════════════
-- 获取安装路径 (唯一权威来源: UCI 配置)
-- ═══════════════════════════════════════════
-- 核心原则: UCI install_path 继续存储公开兼容字段，语义是基础目录。
-- 如果用户误填 /mnt/data/openclaw，这里会规范化为 /mnt/data，再返回真实根目录。
-- ═══════════════════════════════════════════
local function get_install_path()
	return get_path_info().oc_root
end

-- 确保网关端口可用：检测占用并尝试优雅停止或强制杀死占用进程
local function ensure_port_free(port)
	local sys = require "luci.sys"
	if not port or port == "" then return end
	if not tostring(port):match("^%d+$") then return end
	-- 优先尝试使用 openclaw 自身的 stop 命令（如果已安装）
	sys.exec("openclaw gateway stop >/dev/null 2>&1 || true")

	-- 查询占用端口的行
	local check_cmd = ""
	if os.execute("command -v ss >/dev/null 2>&1") == 0 then
		check_cmd = "ss -tulnp 2>/dev/null | grep -E " .. shellquote(":" .. port .. " ") .. " || true"
	else
		check_cmd = "netstat -tulnp 2>/dev/null | grep -E " .. shellquote(":" .. port .. " ") .. " || true"
	end
	local out = sys.exec(check_cmd)
	out = out or ""
	if out:match("%S") then
		-- 尝试解析 pid
		local pid = out:match("pid=(%d+)") or out:match(" (%d+)/") or out:match("/(%d+)")
		pid = pid and pid:gsub("%s+", "") or nil
		if pid and pid ~= "" then
			-- 再次尝试优雅停止
			sys.exec("openclaw gateway stop >/dev/null 2>&1 || true")
			-- 发送 SIGTERM
			sys.exec("kill -TERM " .. pid .. " >/dev/null 2>&1 || true")
			-- 等待释放，最多等待 5 次（每次 1s）
			for i = 1,5 do
				local still = sys.exec(check_cmd) or ""
				if not still:match("%S") then break end
				os.execute("sleep 1")
			end
			-- 如果仍然存在则强杀
			local still2 = sys.exec(check_cmd) or ""
			if still2:match("%S") then
				sys.exec("kill -9 " .. pid .. " >/dev/null 2>&1 || true")
			end
		else
			-- 未能解析 PID，则尝试批量杀死关键进程名
			sys.exec("pgrep -f openclaw-gateway 2>/dev/null | xargs -r kill -TERM 2>/dev/null || true")
			os.execute("sleep 1")
			local still3 = sys.exec(check_cmd) or ""
			if still3:match("%S") then
				sys.exec("pgrep -f openclaw-gateway 2>/dev/null | xargs -r kill -9 2>/dev/null || true")
			end
		end
	end
end

-- ═══════════════════════════════════════════
-- 状态查询 API: 返回 JSON
-- ═══════════════════════════════════════════
function action_status()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()

	local port = uci:get("openclaw", "main", "port") or "18789"
	local pty_port = uci:get("openclaw", "main", "pty_port") or "18793"
	local enabled = uci:get("openclaw", "main", "enabled") or "0"

	-- 使用 get_install_path 获取安装路径 (唯一来源: UCI 配置)
	local install_path = get_install_path()

	-- 验证端口值为纯数字，防止命令注入
	if not port:match("^%d+$") then port = "18789" end
	if not pty_port:match("^%d+$") then pty_port = "18793" end

	local result = {
		enabled = enabled,
		port = port,
		pty_port = pty_port,
		install_path = install_path,
		gateway_running = false,
		gateway_starting = false,
		gateway_failed = false,
		gateway_exit_code = "",
		pty_running = false,
		pid = "",
		memory_kb = 0,
		uptime = "",
		node_version = "",
		oc_version = "",
		plugin_version = "",
		disk_free = "",
	}

	-- 插件版本
	local pvf = io.open("/usr/share/openclaw/VERSION", "r")
	if pvf then
		result.plugin_version = pvf:read("*a"):gsub("%s+", "")
		pvf:close()
	end

	-- 安装方式检测 (离线 / 在线)

	-- 检查 Node.js (使用自定义安装路径)
	local node_bin = install_path .. "/node/bin/node"
	local f = io.open(node_bin, "r")
	if f then
		f:close()
		local node_ver = sys.exec(node_bin .. " --version 2>/dev/null"):gsub("%s+", "")
		result.node_version = node_ver
	end

	-- OpenClaw 版本 (从 package.json 读取，使用自定义安装路径)
	local oc_dirs = {
		install_path .. "/global/lib/node_modules/openclaw",
		install_path .. "/global/node_modules/openclaw",
		install_path .. "/node/lib/node_modules/openclaw",
	}
	for _, d in ipairs(oc_dirs) do
		local pf = io.open(d .. "/package.json", "r")
		if pf then
			local pj = pf:read("*a")
			pf:close()
			local ver = pj:match('"version"%s*:%s*"([^"]+)"')
			if ver and ver ~= "" then
				result.oc_version = ver
				break
			end
		end
	end

	-- 网关端口检查
	local gw_check_cmd = "if command -v ss >/dev/null 2>&1; then ss -tulnp 2>/dev/null | grep -c ':" .. port .. " ' || echo 0; else netstat -tulnp 2>/dev/null | grep -c ':" .. port .. " ' || echo 0; fi"
		local gw_check = sys.exec(gw_check_cmd):gsub("%s+", "")
	result.gateway_running = (tonumber(gw_check) or 0) > 0

	-- 如果端口未监听但 procd 进程存在，说明正在启动中 (gateway 初始化需要数分钟)
	if not result.gateway_running and enabled == "1" then
		local procd_pid = sys.exec("ubus call service list '{\"name\":\"openclaw\"}' 2>/dev/null | jsonfilter -e '$.openclaw.instances.gateway.pid' 2>/dev/null"):gsub("%s+", "")
		local procd_running = sys.exec("ubus call service list '{\"name\":\"openclaw\"}' 2>/dev/null | jsonfilter -e '$.openclaw.instances.gateway.running' 2>/dev/null"):gsub("%s+", "")
		local procd_exit = sys.exec("ubus call service list '{\"name\":\"openclaw\"}' 2>/dev/null | jsonfilter -e '$.openclaw.instances.gateway.exit_code' 2>/dev/null"):gsub("%s+", "")
		result.gateway_exit_code = procd_exit
		if procd_exit ~= "" and tonumber(procd_exit) and tonumber(procd_exit) ~= 0 and procd_running ~= "true" then
			result.gateway_failed = true
		elseif procd_pid ~= "" or procd_running == "true" then
			result.gateway_starting = true
		else
			local fallback_pid = sys.exec("pgrep -f 'openclaw.*gateway' 2>/dev/null | head -1"):gsub("%s+", "")
			if fallback_pid ~= "" then
				result.gateway_starting = true
			end
		end
	end

	-- PTY 端口检查
	local pty_check = sys.exec("netstat -tulnp 2>/dev/null | grep -c ':" .. pty_port .. " ' || echo 0"):gsub("%s+", "")
	result.pty_running = (tonumber(pty_check) or 0) > 0

	-- 读取当前活跃模型 (使用自定义安装路径)
	local config_file = install_path .. "/data/.openclaw/openclaw.json"
	local cf = io.open(config_file, "r")
	if cf then
		local content = cf:read("*a")
		cf:close()
		-- 简单正则提取 "primary": "xxx"
		local model = content:match('"primary"%s*:%s*"([^"]+)"')
		if model and model ~= "" then
			result.active_model = model
		end

		-- 读取已配置的渠道列表
		local channels = {}
		if content:match('"openclaw%-weixin"%s*:%s*{') then
			channels[#channels+1] = "微信"
		end
		if content:match('"qqbot"%s*:%s*{') and content:match('"appId"%s*:%s*"[^"]+"') then
			channels[#channels+1] = "QQ"
		end
		if content:match('"telegram"%s*:%s*{') and content:match('"botToken"%s*:%s*"[^"]+"') then
			channels[#channels+1] = "Telegram"
		end
		if content:match('"discord"%s*:%s*{') then
			channels[#channels+1] = "Discord"
		end
		if content:match('"feishu"%s*:%s*{') then
			channels[#channels+1] = "飞书"
		end
		if content:match('"slack"%s*:%s*{') then
			channels[#channels+1] = "Slack"
		end
		if #channels > 0 then
			result.channels = table.concat(channels, ", ")
		end
	end

	-- PID 和内存
	if result.gateway_running then
		local pid = sys.exec("netstat -tulnp 2>/dev/null | awk '/:" .. port .. " /{split($NF,a,\"/\");print a[1];exit}'"):gsub("%s+", "")
		if pid and pid ~= "" then
			result.pid = pid
			-- 内存 (VmRSS from /proc)
			local rss = sys.exec("awk '/VmRSS/{print $2}' /proc/" .. pid .. "/status 2>/dev/null"):gsub("%s+", "")
			result.memory_kb = tonumber(rss) or 0
			-- 运行时间
			local stat_time = sys.exec("stat -c %Y /proc/" .. pid .. " 2>/dev/null"):gsub("%s+", "")
			local start_ts = tonumber(stat_time) or 0
			if start_ts > 0 then
				local uptime_s = os.time() - start_ts
				local hours = math.floor(uptime_s / 3600)
				local mins = math.floor((uptime_s % 3600) / 60)
				local secs = uptime_s % 60
				if hours > 0 then
					result.uptime = string.format("%dh %dm %ds", hours, mins, secs)
				elseif mins > 0 then
					result.uptime = string.format("%dm %ds", mins, secs)
				else
					result.uptime = string.format("%ds", secs)
				end
			end
		end
	end

	-- 磁盘剩余空间 (检测安装路径所在分区)
	local install_parent = install_path:match("^(.*)/[^/]*$") or "/"
	local df_output = sys.exec("df -h " .. shellquote(install_parent) .. " 2>/dev/null | tail -1 | awk '{print $4}'"):gsub("%s+", "")
	if df_output and df_output ~= "" then
		result.disk_free = df_output
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

-- ═══════════════════════════════════════════
-- 服务控制 API: start/stop/restart/setup
-- ═══════════════════════════════════════════
function action_service_ctl()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local action = http.formvalue("action") or ""

	if action == "start" then
		sys.exec("/etc/init.d/openclaw start >/dev/null 2>&1 &")
	elseif action == "stop" then
		sys.exec("/etc/init.d/openclaw stop >/dev/null 2>&1")
		-- stop 后额外等待确保端口释放
		sys.exec("sleep 2")
	elseif action == "restart" then
		-- 先完整 stop (确保端口释放)，再后台 start
		sys.exec("/etc/init.d/openclaw stop >/dev/null 2>&1")
		sys.exec("sleep 2")
		sys.exec("/etc/init.d/openclaw start >/dev/null 2>&1 &")
	elseif action == "enable" then
		sys.exec("/etc/init.d/openclaw enable 2>/dev/null")
	elseif action == "disable" then
		sys.exec("/etc/init.d/openclaw disable 2>/dev/null")
	elseif action == "setup" then
		-- 先清理旧日志和状态
		sys.exec("rm -f /tmp/openclaw-setup.log /tmp/openclaw-setup.pid /tmp/openclaw-setup.exit")
		-- 获取用户选择的版本 (stable=指定版本, latest=最新版)
		local version = http.formvalue("version") or ""
		-- 获取自定义安装路径 (用户输入的是基础路径，如 /opt 或 /mnt/data)
		local install_path = http.formvalue("install_path") or ""
		local env_prefix = ""
		if version == "stable" then
			-- 稳定版: 读取 openclaw-env 中定义的 OC_TESTED_VERSION
			local tested_ver = sys.exec("grep '^OC_TESTED_VERSION=' /usr/bin/openclaw-env 2>/dev/null | cut -d'\"' -f2"):gsub("%s+", "")
			if tested_ver ~= "" then
				env_prefix = "OC_VERSION=" .. shellquote(tested_ver) .. " "
			end
		elseif version == "latest" then
			env_prefix = "OC_VERSION='latest' "
		elseif version ~= "" and version ~= "latest" then
			-- 校验版本号格式 (仅允许数字、点、横线、字母)
			if version:match("^[%d%.%-a-zA-Z]+$") then
				env_prefix = "OC_VERSION=" .. shellquote(version) .. " "
			end
		end
		-- 处理自定义安装路径
		if install_path ~= "" then
			local normalized = normalize_install_base(install_path)
			if not normalized then
				http.prepare_content("application/json")
				http.write_json({ status = "error", message = "安装路径无效：必须是绝对路径，且不能包含空格、引号或 shell 特殊字符。" })
				return
			end
			-- 保存规范化后的基础路径，公开字段仍为 install_path，避免破坏兼容。
			sys.exec("uci set openclaw.main.install_path=" .. shellquote(normalized) .. "; uci commit openclaw 2>/dev/null")
			env_prefix = env_prefix .. "OC_INSTALL_PATH=" .. shellquote(normalized) .. " "
		end
		-- 后台安装，成功后自动启用并启动服务
		-- 注: openclaw-env 脚本有 set -e，init_openclaw 中的非关键失败不应阻止启动
		sys.exec("( " .. env_prefix .. "/usr/bin/openclaw-env setup > /tmp/openclaw-setup.log 2>&1; RC=$?; echo $RC > /tmp/openclaw-setup.exit; if [ $RC -eq 0 ]; then uci set openclaw.main.enabled=1; uci commit openclaw; /etc/init.d/openclaw enable 2>/dev/null; sleep 1; /etc/init.d/openclaw start >> /tmp/openclaw-setup.log 2>&1; fi ) & echo $! > /tmp/openclaw-setup.pid")
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "安装已启动，请查看安装日志..." })
		return
	else
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "未知操作: " .. action })
		return
	end

	http.prepare_content("application/json")
	http.write_json({ status = "ok", action = action })
end

-- ═══════════════════════════════════════════
-- 安装日志轮询 API
-- ═══════════════════════════════════════════
function action_setup_log()
	local http = require "luci.http"
	local sys = require "luci.sys"

	-- 读取日志内容
	local log = ""
	local f = io.open("/tmp/openclaw-setup.log", "r")
	if f then
		log = f:read("*a") or ""
		f:close()
	end

	-- 检查进程是否还在运行
	local running = false
	local pid_file = io.open("/tmp/openclaw-setup.pid", "r")
	if pid_file then
		local pid = pid_file:read("*a"):gsub("%s+", "")
		pid_file:close()
		if pid ~= "" then
			local check = sys.exec("kill -0 " .. pid .. " 2>/dev/null && echo yes || echo no"):gsub("%s+", "")
			running = (check == "yes")
		end
	end

	-- 读取退出码
	local exit_code = -1
	if not running then
		local exit_file = io.open("/tmp/openclaw-setup.exit", "r")
		if exit_file then
			local code = exit_file:read("*a"):gsub("%s+", "")
			exit_file:close()
			exit_code = tonumber(code) or -1
		end
	end

	-- 判断状态
	local state = "idle"
	if running then
		state = "running"
	elseif exit_code == 0 then
		state = "success"
	elseif exit_code > 0 then
		state = "failed"
	end

	http.prepare_content("application/json")
	http.write_json({
		state = state,
		exit_code = exit_code,
		log = log
	})
end

-- ═══════════════════════════════════════════
-- 版本检查 API
-- ═══════════════════════════════════════════
function action_check_update()
	local http = require "luci.http"
	local sys = require "luci.sys"

	-- 插件版本检查 (从 GitHub API 获取最新 release tag + release notes)
	local plugin_current = ""
	local pf = io.open("/usr/share/openclaw/VERSION", "r")
		or io.open("/root/luci-app-openclaw/VERSION", "r")
	if pf then
		plugin_current = pf:read("*a"):gsub("%s+", "")
		pf:close()
	end

	local plugin_latest = ""
	local release_notes = ""
	local plugin_has_update = false

	-- 使用 GitHub API 获取最新 release (tag + body)
	local gh_json = sys.exec("curl -sf --connect-timeout 5 --max-time 10 'https://api.github.com/repos/10000ge10000/luci-app-openclaw/releases/latest' 2>/dev/null")
	if gh_json and gh_json ~= "" then
		-- 提取 tag_name
		local tag = gh_json:match('"tag_name"%s*:%s*"([^"]+)"')
		if tag and tag ~= "" then
			plugin_latest = tag:gsub("^v", ""):gsub("%s+", "")
		end
		-- 提取 body (release notes), 处理 JSON 转义
		-- 结束引号后可能紧跟 \n、空格、, 或 }，用宽松匹配
		local body = gh_json:match('"body"%s*:%s*"(.-)"[,}%]\n ]')
		if body and body ~= "" then
			-- 还原 JSON 转义: \n \r \" \\
			body = body:gsub("\\n", "\n"):gsub("\\r", ""):gsub('\\"', '"'):gsub("\\\\", "\\")
			release_notes = body
		end
	end

	if plugin_current ~= "" and plugin_latest ~= "" and plugin_current ~= plugin_latest then
		plugin_has_update = true
	end

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		plugin_current = plugin_current,
		plugin_latest = plugin_latest,
		plugin_has_update = plugin_has_update,
		release_notes = release_notes
	})
end

-- ═══════════════════════════════════════════
-- 卸载运行环境 API
-- ═══════════════════════════════════════════
function action_uninstall()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()

	-- 获取并校验安装路径。卸载只能作用于规范化后的 <base>/openclaw。
	local configured_base = uci:get("openclaw", "main", "install_path") or "/opt"
	local normalized_base = normalize_install_base(configured_base)
	if not normalized_base then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "UCI 安装路径无效，已取消卸载: " .. tostring(configured_base) })
		return
	end
	local path_info = get_path_info(normalized_base)
	local install_path = path_info.oc_root
	if not is_safe_openclaw_root(install_path) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "安装路径未通过安全校验，已取消卸载: " .. install_path })
		return
	end
	local q_install_path = shellquote(install_path)

	-- 1. 停止服务 (通过 init.d 正常流程)
	sys.exec("/etc/init.d/openclaw stop >/dev/null 2>&1")
	
	-- 2. 获取配置端口，确保在清理前端口对应的进程都被杀掉
	local port = uci:get("openclaw", "main", "port") or "18789"
	local pty_port = uci:get("openclaw", "main", "pty_port") or "18793"
	
	-- 3. 终极无感化清理僵尸进程
	sys.exec("for p in " .. port .. " " .. pty_port .. "; do pid=$(netstat -tulnp 2>/dev/null | grep \":$p \" | awk '{print $7}' | cut -d'/' -f1); [ -n \"$pid\" ] && kill -9 \"$pid\" 2>/dev/null; done")
	sys.exec("ss -tulnp 2>/dev/null | awk '/:" .. port .. " |:" .. pty_port .. " /{print $NF}' | awk -F',' '{print $2}' | awk -F'=' '{print $2}' | xargs -r kill -9 2>/dev/null")
	sys.exec("pgrep -f 'openclaw-gateway|web-pty.js' 2>/dev/null | xargs -r kill -9 2>/dev/null")
	sys.exec("pgrep -u openclaw 2>/dev/null | xargs -r kill -9 2>/dev/null")

	-- 禁用开机启动
	sys.exec("/etc/init.d/openclaw disable 2>/dev/null")
	-- 设置 UCI enabled=0
	sys.exec("uci set openclaw.main.enabled=0; uci commit openclaw 2>/dev/null")
	-- 删除 Node.js + OpenClaw 运行环境 (包含所有插件: qqbot, 飞书等)
        -- 尝试先解绑可能挂载的目录；失败不阻断后续删除。
        sys.exec("umount " .. q_install_path .. " 2>/dev/null || true")
        -- 删除 Node.js + OpenClaw 运行环境。不要通过全局提权绕过权限问题。
        sys.exec("rm -rf " .. q_install_path)
        -- OverlayFS 兼容: 只清理同一规范化路径在 upper 层的残留。
	local overlay_install_path = "/overlay/upper" .. install_path
        sys.exec("[ -d " .. shellquote(overlay_install_path) .. " ] && rm -rf " .. shellquote(overlay_install_path) .. " 2>/dev/null || true")
	-- 清理临时文件
	sys.exec("rm -f /tmp/openclaw-setup.* /tmp/openclaw-update.log /tmp/openclaw-plugin-upgrade.* /var/run/openclaw*.pid")
	-- 清理 LuCI 缓存
	sys.exec("rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null")
	-- 删除 openclaw 系统用户
	sys.exec("sed -i '/^openclaw:/d' /etc/passwd /etc/shadow /etc/group 2>/dev/null")

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		message = "运行环境已卸载。已清理: Node.js 运行环境 (" .. install_path .. ")、所有插件、临时文件、LuCI 缓存。"
	})
end

-- ═══════════════════════════════════════════
-- 获取 Token API
-- 仅通过 LuCI 认证后可调用，避免 Token 嵌入 HTML 源码
-- 返回网关 Token 和 PTY Token
-- ═══════════════════════════════════════════
function action_get_token()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()
	local token = uci:get("openclaw", "main", "token") or ""
	local pty_token = uci:get("openclaw", "main", "pty_token") or ""
	http.prepare_content("application/json")
	http.write_json({ token = token, pty_token = pty_token })
end

-- ═══════════════════════════════════════════
-- 插件升级 API (后台下载 .run 并执行)
-- 参数: version — 目标版本号 (如 1.0.8)
-- ═══════════════════════════════════════════
function action_plugin_upgrade()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local version = http.formvalue("version") or ""
	if version == "" then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "缺少版本号参数" })
		return
	end

	-- 安全检查: version 只允许数字和点
	if not version:match("^[%d%.]+$") then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "版本号格式无效" })
		return
	end

	-- 清理旧日志和状态
	sys.exec("rm -f /tmp/openclaw-plugin-upgrade.log /tmp/openclaw-plugin-upgrade.pid /tmp/openclaw-plugin-upgrade.exit")

	-- 后台执行: 下载 .run 并执行安装
	local run_url = "https://github.com/10000ge10000/luci-app-openclaw/releases/download/v" .. version .. "/luci-app-openclaw_" .. version .. ".run"
	-- 使用 curl 下载 (-L 跟随重定向), 然后 sh 执行
	sys.exec(string.format(
		"( echo '正在下载插件 v%s ...' > /tmp/openclaw-plugin-upgrade.log; " ..
		"curl -sL --connect-timeout 15 --max-time 120 -o /tmp/luci-app-openclaw-update.run '%s' >> /tmp/openclaw-plugin-upgrade.log 2>&1; " ..
		"RC=$?; " ..
		"if [ $RC -ne 0 ]; then " ..
		"  echo '下载失败 (curl exit: '$RC')' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"  echo '如果无法访问 GitHub，请手动下载: %s' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"  echo $RC > /tmp/openclaw-plugin-upgrade.exit; " ..
		"else " ..
		"  FSIZE=$(wc -c < /tmp/luci-app-openclaw-update.run 2>/dev/null | tr -d ' '); " ..
		"  echo \"下载完成 (${FSIZE} bytes)\" >> /tmp/openclaw-plugin-upgrade.log; " ..
		"  FHEAD=$(head -c 9 /tmp/luci-app-openclaw-update.run 2>/dev/null); " ..
		"  if [ \"$FSIZE\" -lt 10000 ] 2>/dev/null; then " ..
		"    if [ \"$FHEAD\" = 'Not Found' ]; then " ..
		"      echo '❌ GitHub 返回 \"Not Found\"，可能是网络被拦截（GFW）或 Release 资产不存在' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    else " ..
		"      echo '❌ 文件过小，可能 GitHub 访问受限或网络异常' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    fi; " ..
		"    echo '请检查路由器是否能访问 github.com，或手动下载后安装: %s' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    echo 1 > /tmp/openclaw-plugin-upgrade.exit; " ..
		"  else " ..
		"    echo '' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    echo '正在安装...' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    sh /tmp/luci-app-openclaw-update.run >> /tmp/openclaw-plugin-upgrade.log 2>&1; " ..
		"    RC2=$?; echo $RC2 > /tmp/openclaw-plugin-upgrade.exit; " ..
		"    if [ $RC2 -eq 0 ]; then " ..
		"      echo '' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"      echo '✅ 插件升级完成！请刷新浏览器页面。' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    else " ..
		"      echo '安装执行失败 (exit: '$RC2')' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    fi; " ..
		"  fi; " ..
		"  rm -f /tmp/luci-app-openclaw-update.run; " ..
		"fi " ..
		") & echo $! > /tmp/openclaw-plugin-upgrade.pid",
		version, run_url, run_url, run_url
	))

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		message = "插件升级已在后台启动..."
	})
end

-- ═══════════════════════════════════════════
-- 插件升级日志轮询 API
-- ═══════════════════════════════════════════
function action_plugin_upgrade_log()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local log = ""
	local f = io.open("/tmp/openclaw-plugin-upgrade.log", "r")
	if f then
		log = f:read("*a") or ""
		f:close()
	end

	local running = false
	local pid_file = io.open("/tmp/openclaw-plugin-upgrade.pid", "r")
	if pid_file then
		local pid = pid_file:read("*a"):gsub("%s+", "")
		pid_file:close()
		if pid ~= "" then
			local check = sys.exec("kill -0 " .. pid .. " 2>/dev/null && echo yes || echo no"):gsub("%s+", "")
			running = (check == "yes")
		end
	end

	local exit_code = -1
	if not running then
		local exit_file = io.open("/tmp/openclaw-plugin-upgrade.exit", "r")
		if exit_file then
			local code = exit_file:read("*a"):gsub("%s+", "")
			exit_file:close()
			exit_code = tonumber(code) or -1
		end
	end

	local state = "idle"
	if running then
		state = "running"
	elseif exit_code == 0 then
		state = "success"
	elseif exit_code > 0 then
		state = "failed"
	end

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		log = log,
		state = state,
		running = running,
		exit_code = exit_code
	})
end

-- ═══════════════════════════════════════════
-- 配置备份 API (v2026.3.8+)
-- action=create: 创建配置备份
-- action=verify:  验证最新备份
-- action=list:    列出现有备份(含类型/大小)
-- action=delete:  删除指定备份文件
-- ═══════════════════════════════════════════
function action_backup()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()
	local action = http.formvalue("action") or "create"

	-- 获取安装路径
	local install_path_uci = uci:get("openclaw", "main", "install_path") or "/opt"
	-- 实际安装路径
	local install_path = install_path_uci .. "/openclaw"
	local node_bin = install_path .. "/node/bin/node"
	local oc_entry = ""

	-- 查找 openclaw 入口 (使用自定义安装路径)
	local search_dirs = {
		install_path .. "/global/lib/node_modules/openclaw",
		install_path .. "/global/node_modules/openclaw",
		install_path .. "/node/lib/node_modules/openclaw",
	}
	for _, d in ipairs(search_dirs) do
		if nixio.fs.stat(d .. "/openclaw.mjs", "type") then
			oc_entry = d .. "/openclaw.mjs"
			break
		elseif nixio.fs.stat(d .. "/dist/cli.js", "type") then
			oc_entry = d .. "/dist/cli.js"
			break
		end
	end

	if oc_entry == "" then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "OpenClaw 未安装，无法执行备份操作" })
		return
	end

	local env_prefix = string.format(
		"HOME=%s/data OPENCLAW_HOME=%s/data " ..
		"OPENCLAW_STATE_DIR=%s/data/.openclaw " ..
		"OPENCLAW_CONFIG_PATH=%s/data/.openclaw/openclaw.json " ..
		"PATH=%s/node/bin:%s/global/bin:$PATH ",
		install_path, install_path, install_path, install_path, install_path, install_path
	)

	-- 备份目录 (openclaw backup create 输出到 CWD，需要 cd)
	local backup_dir = install_path .. "/data/.openclaw/backups"
	local cd_prefix = "mkdir -p " .. backup_dir .. " && cd " .. backup_dir .. " && "

	-- ── 辅助: 解析单个备份文件的 manifest 信息 ──
	local function parse_backup_info(filepath)
		local filename = filepath:match("([^/]+)$") or filepath
		-- 文件大小
		local st = nixio.fs.stat(filepath)
		local size = st and st.size or 0
		-- 从文件名提取时间戳: 2026-03-11T18-28-43.149Z-openclaw-backup.tar.gz
		local ts = filename:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d%-%d%d%-%d%d%.%d+Z)")
		local display_time = ""
		if ts then
			-- 2026-03-11T18-28-43.149Z -> 2026-03-11 18:28:43
			display_time = ts:gsub("T", " "):gsub("(%d%d)%-(%d%d)%-(%d%d)%.%d+Z", "%1:%2:%3")
		end
		-- 读取 manifest.json 判断备份类型
		local backup_type = "unknown"
		local manifest_json = sys.exec(
			"tar --wildcards -xzf " .. filepath .. " '*/manifest.json' -O 2>/dev/null"
		)
		if manifest_json and manifest_json ~= "" then
			-- 简单字符串匹配，避免依赖 JSON 库
			if manifest_json:match('"onlyConfig"%s*:%s*true') then
				backup_type = "config"
			elseif manifest_json:match('"onlyConfig"%s*:%s*false') then
				backup_type = "full"
			end
		else
			-- 无法读取 manifest，通过文件大小推断
			if size < 50000 then
				backup_type = "config"
			else
				backup_type = "full"
			end
		end
		-- 格式化大小
		local size_str
		if size >= 1073741824 then
			size_str = string.format("%.1f GB", size / 1073741824)
		elseif size >= 1048576 then
			size_str = string.format("%.1f MB", size / 1048576)
		elseif size >= 1024 then
			size_str = string.format("%.1f KB", size / 1024)
		else
			size_str = tostring(size) .. " B"
		end
		return {
			filename = filename,
			filepath = filepath,
			size = size,
			size_str = size_str,
			time = display_time,
			backup_type = backup_type
		}
	end

	if action == "create" then
		local only_config = http.formvalue("only_config") or "1"
		local backup_cmd
		if only_config == "1" then
			backup_cmd = cd_prefix .. env_prefix .. node_bin .. " " .. oc_entry .. " backup create --only-config --no-include-workspace 2>&1"
		else
			backup_cmd = cd_prefix .. "HOME=" .. backup_dir .. " " .. env_prefix .. node_bin .. " " .. oc_entry .. " backup create --no-include-workspace 2>&1"
		end
		local output = sys.exec(backup_cmd)
		-- 完整备份可能输出到 HOME，移动到 backup_dir
		sys.exec("mv " .. install_path .. "/data/*-openclaw-backup.tar.gz " .. backup_dir .. "/ 2>/dev/null")
		-- 提取备份文件路径
		local backup_path = output:match("([%S]+%.tar%.gz)")
		http.prepare_content("application/json")
		http.write_json({
			status = "ok",
			action = "create",
			output = output,
			backup_path = backup_path or ""
		})
	elseif action == "verify" then
		-- 找到最新的备份文件
		local latest = sys.exec("ls -t " .. backup_dir .. "/*-openclaw-backup.tar.gz 2>/dev/null | head -1"):gsub("%s+", "")
		if latest == "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "未找到备份文件，请先创建备份" })
			return
		end
		local output = sys.exec(env_prefix .. node_bin .. " " .. oc_entry .. " backup verify " .. latest .. " 2>&1")
		http.prepare_content("application/json")
		http.write_json({
			status = "ok",
			action = "verify",
			output = output,
			backup_path = latest
		})
	elseif action == "restore" then
		-- 支持指定文件名，不指定则用最新
		local target_file = http.formvalue("file") or ""
		local restore_path = ""
		if target_file ~= "" then
			-- 安全: 只允许文件名，不允许路径穿越
			target_file = target_file:match("([^/]+)$") or ""
			if target_file:match("%-openclaw%-backup%.tar%.gz$") then
				restore_path = backup_dir .. "/" .. target_file
			end
		end
		if restore_path == "" or not nixio.fs.stat(restore_path, "type") then
			-- fallback 到最新
			restore_path = sys.exec("ls -t " .. backup_dir .. "/*-openclaw-backup.tar.gz 2>/dev/null | head -1"):gsub("%s+", "")
		end
		if restore_path == "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "未找到备份文件，请先创建备份" })
			return
		end
		local oc_data_dir = install_path .. "/data/.openclaw"
		local config_path = oc_data_dir .. "/openclaw.json"

		-- 1) 先验证备份中的 openclaw.json 是否有效
		local check_cmd = "tar -xzf " .. restore_path .. " --wildcards '*/openclaw.json' -O 2>/dev/null"
		local json_content = sys.exec(check_cmd)
		if not json_content or json_content == "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "备份文件中未找到 openclaw.json" })
			return
		end
		-- 写入临时文件并用 node 验证
		local tmpfile = "/tmp/oc-restore-check.json"
		local f = io.open(tmpfile, "w")
		if f then f:write(json_content); f:close() end
		local check = sys.exec(node_bin .. " -e \"try{JSON.parse(require('fs').readFileSync('" .. tmpfile .. "','utf8'));console.log('OK')}catch(e){console.log('FAIL')}\" 2>/dev/null"):gsub("%s+", "")
		os.remove(tmpfile)
		if check ~= "OK" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "备份文件中的配置无效，恢复已取消" })
			return
		end

		-- 2) 备份当前配置
		sys.exec("cp -f " .. config_path .. " " .. config_path .. ".pre-restore 2>/dev/null")

		-- 3) 获取备份名前缀 (如: 2026-03-11T18-21-17.209Z-openclaw-backup)
		--    备份结构: <backup_name>/payload/posix/<绝对路径>
		local first_entry = sys.exec("tar -tzf " .. restore_path .. " 2>/dev/null | head -1"):gsub("%s+", "")
		local backup_name = first_entry:match("^([^/]+)/") or ""
		if backup_name == "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "备份文件格式无法识别" })
			return
		end
		local payload_prefix = backup_name .. "/payload/posix/"
		-- strip 3 层: <backup_name> / payload / posix
		local strip_count = 3

		-- 4) 停止服务
		sys.exec("/etc/init.d/openclaw stop >/dev/null 2>&1")
		-- 等待端口释放
		sys.exec("sleep 2")

		-- 5) 提取 payload 文件到根目录 (还原到原始绝对路径)
		--    注: --wildcards 与 --strip-components 组合在某些 tar 版本不兼容
		--    使用精确路径前缀代替 wildcards
		local extract_cmd = string.format(
			"tar -xzf %s --strip-components=%d -C / '%s' 2>&1",
			restore_path, strip_count, payload_prefix
		)
		local extract_out = sys.exec(extract_cmd)

		-- 6) 修复权限
		sys.exec("chown -R openclaw:openclaw " .. oc_data_dir .. " 2>/dev/null")

		-- 7) 重启服务
		sys.exec("/etc/init.d/openclaw start >/dev/null 2>&1 &")

		http.prepare_content("application/json")
		http.write_json({
			status = "ok",
			action = "restore",
			message = "已从备份完整恢复所有配置和数据，服务正在重启。原配置已保存为 openclaw.json.pre-restore",
			backup_path = restore_path,
			extract_output = extract_out or ""
		})
	elseif action == "list" then
		-- 返回结构化的备份文件列表(含类型/大小/时间)
		local files_raw = sys.exec("ls -t " .. backup_dir .. "/*-openclaw-backup.tar.gz 2>/dev/null"):gsub("%s+$", "")
		local backups = {}
		if files_raw ~= "" then
			for fpath in files_raw:gmatch("[^\n]+") do
				fpath = fpath:gsub("%s+", "")
				if fpath ~= "" then
					backups[#backups + 1] = parse_backup_info(fpath)
				end
				-- 最多返回 20 条
				if #backups >= 20 then break end
			end
		end
		http.prepare_content("application/json")
		http.write_json({
			status = "ok",
			action = "list",
			backups = backups
		})
	elseif action == "delete" then
		local target_file = http.formvalue("file") or ""
		-- 安全: 只允许文件名，不允许路径穿越
		target_file = target_file:match("([^/]+)$") or ""
		if target_file == "" or not target_file:match("%-openclaw%-backup%.tar%.gz$") then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "无效的备份文件名" })
			return
		end
		local del_path = backup_dir .. "/" .. target_file
		if not nixio.fs.stat(del_path, "type") then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "备份文件不存在" })
			return
		end
		os.remove(del_path)
		http.prepare_content("application/json")
		http.write_json({
			status = "ok",
			action = "delete",
			message = "已删除备份: " .. target_file
		})
	else
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "未知备份操作: " .. action })
	end
end

-- ═══════════════════════════════════════════
-- 系统配置检测 API (安装前检测)
-- 检测内存和磁盘空间是否满足最低要求
-- 要求: 内存 > 1GB, 磁盘可用空间 > 2GB (OpenClaw v2026.3.28+ 包体积约 200MB)
-- 支持自定义安装路径，检测对应路径的磁盘空间
-- ═══════════════════════════════════════════
function action_check_system()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()

	-- 获取自定义安装路径 (用户输入的是基础路径，如 /opt 或 /mnt/data)
	local raw_install_path = http.formvalue("install_path") or uci:get("openclaw", "main", "install_path") or "/opt"
	local install_path = normalize_install_base(raw_install_path)

	-- 最低要求配置 (v2026.3.28: 包体积 ~200MB, 建议 2GB 可用空间)
	local MIN_MEMORY_MB = 1024      -- 1GB
	local MIN_DISK_MB = 2048        -- 2GB

	local result = {
		memory_mb = 0,
		memory_ok = false,
		disk_mb = 0,
		disk_ok = false,
		disk_path = "",
		install_path = install_path or tostring(raw_install_path or ""),
		path_valid = install_path ~= nil,
		writable_ok = false,
		disk_free_str = "",
		pass = false,
		message = ""
	}

	if not install_path then
		result.message = "安装路径无效：必须是绝对路径，且不能包含空格、引号或 shell 特殊字符。"
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	-- 检测总内存 (从 /proc/meminfo 读取 MemTotal)
	local meminfo = io.open("/proc/meminfo", "r")
	if meminfo then
		for line in meminfo:lines() do
			local mem_total = line:match("MemTotal:%s+(%d+)%s+kB")
			if mem_total then
				result.memory_mb = math.floor(tonumber(mem_total) / 1024)
				break
			end
		end
		meminfo:close()
	end
	result.memory_ok = result.memory_mb >= MIN_MEMORY_MB

	-- 检测磁盘可用空间
	-- 策略: 从目标路径开始，逐级向上找到存在的挂载点进行检测
	-- 例如: /mnt/data -> /mnt/data (若存在) -> /mnt (若存在) -> /
	local function find_mount_point(path)
		-- 如果路径存在，直接返回
		if nixio.fs.stat(path, "type") then
			return path
		end
		-- 逐级向上查找
		while path ~= "/" and path ~= "" do
			path = path:match("^(.*)/[^/]*$") or "/"
			if path == "" then path = "/" end
			if nixio.fs.stat(path, "type") then
				return path
			end
		end
		return "/"
	end

	local disk_check_path = find_mount_point(install_path)

	-- 使用 df 检测磁盘空间
	local df_output = sys.exec("df -m " .. shellquote(disk_check_path) .. " 2>/dev/null | tail -1 | awk '{print $4}'"):gsub("%s+", "")
	if df_output and df_output ~= "" and tonumber(df_output) then
		result.disk_mb = tonumber(df_output)
		result.disk_path = disk_check_path
		-- 获取可读的磁盘空间格式
		result.disk_free_str = sys.exec("df -h " .. shellquote(disk_check_path) .. " 2>/dev/null | tail -1 | awk '{print $4}'"):gsub("%s+", "")
	else
		-- 如果检测失败，尝试检测根分区
		df_output = sys.exec("df -m / 2>/dev/null | tail -1 | awk '{print $4}'"):gsub("%s+", "")
		if df_output and df_output ~= "" and tonumber(df_output) then
			result.disk_mb = tonumber(df_output)
			result.disk_path = "/"
			result.disk_free_str = sys.exec("df -h / 2>/dev/null | tail -1 | awk '{print $4}'"):gsub("%s+", "")
		end
	end
	result.disk_ok = result.disk_mb >= MIN_DISK_MB

	-- 安装前写入探针：先在实际存在的父目录创建临时目录。
	-- 这能明确识别 overlay 满、只读挂载、路径挂载点不可写等问题，避免下载完才失败。
	local probe_dir = disk_check_path .. "/.openclaw-write-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
	local probe_rc = os.execute("mkdir " .. shellquote(probe_dir) .. " >/dev/null 2>&1")
	if probe_rc == 0 or probe_rc == true then
		result.writable_ok = true
		os.execute("rmdir " .. shellquote(probe_dir) .. " >/dev/null 2>&1")
	else
		result.writable_ok = false
	end

	-- 综合判断
	result.pass = result.memory_ok and result.disk_ok and result.writable_ok

	-- 生成提示信息
	if result.pass then
		result.message = "系统配置检测通过"
	else
		local issues = {}
		if not result.memory_ok then
			table.insert(issues, string.format("内存不足: 当前 %d MB，需要至少 %d MB", result.memory_mb, MIN_MEMORY_MB))
		end
		if not result.disk_ok then
			table.insert(issues, string.format("磁盘空间不足: 当前 %d MB 可用，需要至少 %d MB", result.disk_mb, MIN_DISK_MB))
		end
		if not result.writable_ok then
			table.insert(issues, "安装路径所在挂载点不可写，可能是 overlay 已满、只读或外置盘未正确挂载")
		end
		result.message = table.concat(issues, "；")
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

-- ═══════════════════════════════════════════
-- 微信状态 API: 检测插件安装和登录状态
-- ═══════════════════════════════════════════
function action_wechat_status()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()

	-- 使用统一的路径获取函数 (唯一来源: UCI 配置)
	local install_path = get_install_path()

	local result = {
		plugin_installed = false,
		logged_in = false,
		accounts = {},
		install_path = install_path
	}

	-- 检测微信插件是否已安装
	local wechat_ext_dir = find_wechat_plugin_dir(install_path)
        local wechat_plugin_json = wechat_ext_dir and (wechat_ext_dir .. "/openclaw.plugin.json") or ""
        if nixio.fs.stat(wechat_plugin_json, "type") then
                result.plugin_installed = true
                for _, filename in ipairs({"package.json", "openclaw.plugin.json"}) do
                        local pf = io.open(wechat_ext_dir .. "/" .. filename, "r")
                        if pf then
                                local content = pf:read("*a") or ""
                                pf:close()
                                result.plugin_version = content:match('"version"%s*:%s*"([^"]+)"')
                                if result.plugin_version then break end
                        end
                end
        end        -- 从 openclaw.json 和 accounts.json 读取微信账号配置
        local config_file = install_path .. "/data/.openclaw/openclaw.json"
        local accounts_file = install_path .. "/data/.openclaw/openclaw-weixin/accounts.json"
        
        -- 新版 OpenClaw WeChat 插件状态读取
        if nixio.fs.stat(accounts_file, "type") then
                local af = io.open(accounts_file, "r")
                if af then
                        local content = af:read("*a")
                        af:close()
                        local count = 0
                        for acc in content:gmatch('"([^"]+)"') do
                                count = count + 1
                                table.insert(result.accounts, {id = acc, name = acc})
                        end
                        if count > 0 then
                                result.logged_in = true
                        end
                end
        end

        local cf = io.open(config_file, "r")
        if cf then
                local content = cf:read("*a")
                cf:close()

                if content:match('"openclaw%-weixin"%s*:%s*{') then
                        -- 兼容旧版
                        local accounts_str = content:match('"accounts"%s*:%s*%[([^%]]*)%]')
                        if accounts_str and accounts_str ~= "" then
                                local count = 0
                                for _ in accounts_str:gmatch('"wxid') do count = count + 1 end
                                for _ in accounts_str:gmatch('"nickName"') do count = count + 1 end
                                if count > 0 and not result.logged_in then
                                        result.logged_in = true
                                        result.accounts = {{name = "微信账号"}}
                                end
                        end

                        if content:match('"credential"%s*:%s*{') and not result.logged_in then
                                result.logged_in = true
                                result.accounts = {{name = "微信账号"}}
                        end
                end
        end	http.prepare_content("application/json")
	http.write_json(result)
end

-- ═══════════════════════════════════════════
-- 微信插件安装 API (后台安装)
-- ═══════════════════════════════════════════
function action_wechat_install()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local path_info = get_path_info()
	local base_q = shellquote(path_info.install_path)
	local data_q = shellquote(path_info.oc_data)
	local npx_bin = path_info.node_base .. "/bin/npx"
	local install_env = "HOME=" .. data_q ..
		" OPENCLAW_HOME=" .. data_q ..
		" OPENCLAW_STATE_DIR=" .. shellquote(path_info.oc_data .. "/.openclaw") ..
		" OPENCLAW_CONFIG_PATH=" .. shellquote(path_info.config_file) ..
		" NPM_CONFIG_CACHE=" .. shellquote(path_info.oc_data .. "/.npm") ..
		" TMPDIR=" .. shellquote(path_info.oc_data .. "/.tmp") ..
		" PATH=" .. shellquote(path_info.node_base .. "/bin:" .. path_info.oc_global .. "/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	local install_command = install_env .. " " .. shellquote(npx_bin) ..
		" -y @tencent-weixin/openclaw-weixin-cli@latest install"
	local projects_q = shellquote(path_info.oc_data .. "/.openclaw/npm/projects")

	sys.exec("rm -f /tmp/openclaw-wechat-install.log /tmp/openclaw-wechat-install.pid /tmp/openclaw-wechat-install.exit")
	if not nixio.fs.stat(npx_bin, "type") or not nixio.fs.stat("/usr/bin/openclaw", "type") then
		write_wechat_log_and_exit("/tmp/openclaw-wechat-install.log", "/tmp/openclaw-wechat-install.exit", "npx 或 OpenClaw CLI 不可用，请先安装运行环境。\n", 127)
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "OpenClaw CLI 不可用" })
		return
	end
	if not ensure_openclaw_user(path_info.oc_data) then
		write_wechat_log_and_exit("/tmp/openclaw-wechat-install.log", "/tmp/openclaw-wechat-install.exit", "无法创建或读取 openclaw 系统用户。\n", 1)
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "openclaw 系统用户不可用" })
		return
	end

	local command = "( " ..
		"echo '正在通过微信官方 CLI 安装微信插件...' > /tmp/openclaw-wechat-install.log; " ..
		"/etc/init.d/openclaw stop >/dev/null 2>&1; " ..
		"mkdir -p " .. shellquote(path_info.oc_data .. "/.npm") .. " " .. shellquote(path_info.oc_data .. "/.tmp") .. " " .. shellquote(path_info.oc_data .. "/.openclaw") .. "; " ..
		"chown -R openclaw:openclaw " .. shellquote(path_info.oc_data .. "/.npm") .. " " .. shellquote(path_info.oc_data .. "/.tmp") .. " " .. shellquote(path_info.oc_data .. "/.openclaw") .. " 2>/dev/null; " ..
		"su -s /bin/sh openclaw -c " .. shellquote(install_command) .. " >> /tmp/openclaw-wechat-install.log 2>&1; " ..
		"RC=$?; if [ $RC -eq 0 ]; then " ..
			"OPENCLAW_INSTALL_PATH=" .. base_q .. " /usr/bin/openclaw config set plugins.entries.openclaw-weixin.enabled true >> /tmp/openclaw-wechat-install.log 2>&1 || RC=$?; " ..
			"chown -R openclaw:openclaw " .. data_q .. " 2>/dev/null; " ..
			"chown openclaw:openclaw " .. shellquote(path_info.config_file) .. " 2>/dev/null; " ..
		"fi; " ..
		"if [ -d " .. projects_q .. " ]; then for manifest in $(find " .. projects_q .. " -path '*/node_modules/*/openclaw.plugin.json' -type f 2>/dev/null); do plugin_dir=${manifest%/*}; chown -R root:root \"$plugin_dir\"; chmod -R a+rX \"$plugin_dir\"; done; fi; " ..
		"/etc/init.d/openclaw start >> /tmp/openclaw-wechat-install.log 2>&1; " ..
		"echo $RC > /tmp/openclaw-wechat-install.exit; " ..
		"[ $RC -eq 0 ] && echo '微信插件安装完成。' >> /tmp/openclaw-wechat-install.log || echo '微信插件安装失败。' >> /tmp/openclaw-wechat-install.log " ..
		") & echo $! > /tmp/openclaw-wechat-install.pid"
	sys.exec(command)

	http.prepare_content("application/json")
	http.write_json({ status = "ok", message = "微信插件安装已启动" })
end
function action_wechat_install_log()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local log = ""
	local f = io.open("/tmp/openclaw-wechat-install.log", "r")
	if f then
		log = f:read("*a") or ""
		f:close()
	end

	local running = false
	local pid_file = io.open("/tmp/openclaw-wechat-install.pid", "r")
	if pid_file then
		local pid = pid_file:read("*a"):gsub("%s+", "")
		pid_file:close()
		if pid ~= "" then
			local check = sys.exec("kill -0 " .. pid .. " 2>/dev/null && echo yes || echo no"):gsub("%s+", "")
			running = (check == "yes")
		end
	end

	local exit_code = -1
	if not running then
		local exit_file = io.open("/tmp/openclaw-wechat-install.exit", "r")
		if exit_file then
			local code = exit_file:read("*a"):gsub("%s+", "")
			exit_file:close()
			exit_code = tonumber(code) or -1
		end
	end

	local state = "idle"
	if running then
		state = "running"
	elseif exit_code == 0 then
		state = "success"
	elseif exit_code > 0 then
		state = "failed"
	end

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		log = log,
		state = state,
		running = running,
		exit_code = exit_code
	})
end

-- ═══════════════════════════════════════════
-- 微信登录 API (启动登录流程并获取二维码)
-- ═══════════════════════════════════════════
function action_wechat_login()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local install_path = get_install_path()
	local node_bin = install_path .. "/node/bin/node"
	local oc_data = install_path .. "/data"
	local oc_entry = ""

	-- 查找 openclaw 入口
	local search_dirs = {
		install_path .. "/global/lib/node_modules/openclaw",
		install_path .. "/global/node_modules/openclaw",
		install_path .. "/node/lib/node_modules/openclaw",
	}
	for _, d in ipairs(search_dirs) do
		if nixio.fs.stat(d .. "/openclaw.mjs", "type") then
			oc_entry = d .. "/openclaw.mjs"
			break
		elseif nixio.fs.stat(d .. "/dist/cli.js", "type") then
			oc_entry = d .. "/dist/cli.js"
			break
		end
	end

        if oc_entry == "" then
                http.prepare_content("application/json")
                http.write_json({ status = "error", message = "OpenClaw 未安装" })
                return
        end
	if not ensure_openclaw_user(oc_data) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "无法创建或读取 openclaw 系统用户，请检查 /etc/passwd、/etc/group 是否可写" })
		return
	end

        -- 清理旧状态和可能的残留进程
        sys.exec("kill -9 $(cat /tmp/openclaw-wechat-login.pid 2>/dev/null) 2>/dev/null")
        sys.exec("pkill -f 'channels login --channel openclaw-weixin' 2>/dev/null")
        sys.exec("rm -f /tmp/openclaw-wechat-qrcode.txt /tmp/openclaw-wechat-login.pid /tmp/openclaw-wechat-login.exit /tmp/openclaw-wechat-restarted")	-- 后台启动登录流程，将二维码输出到文件
        local login_cmd = string.format(
                "( " ..
                "echo '正在启动微信登录...' > /tmp/openclaw-wechat-qrcode.txt; " ..
                "echo '安装路径: %s' >> /tmp/openclaw-wechat-qrcode.txt; " ..
                "mkdir -p %s/.npm %s/.tmp %s/.openclaw/openclaw-weixin; chown -R openclaw:openclaw %s/.npm %s/.tmp %s/.openclaw/openclaw-weixin 2>/dev/null; " ..
                "cd %s && " ..
                "su -s /bin/sh openclaw -c 'HOME=%s OPENCLAW_HOME=%s OPENCLAW_STATE_DIR=%s/.openclaw OPENCLAW_CONFIG_PATH=%s/.openclaw/openclaw.json " ..
                "NPM_CONFIG_CACHE=%s/.npm npm_config_cache=%s/.npm TMPDIR=%s/.tmp PATH=%s/node/bin:%s/global/bin:$PATH " ..
                "%s %s channels login --channel openclaw-weixin' >> /tmp/openclaw-wechat-qrcode.txt 2>&1; " ..
                "echo $? > /tmp/openclaw-wechat-login.exit; " ..
                ") >/dev/null 2>&1 & echo $! > /tmp/openclaw-wechat-login.pid",
                install_path,
                oc_data, oc_data, oc_data, oc_data, oc_data, oc_data,
                oc_data, oc_data, oc_data, oc_data, oc_data,
                oc_data, oc_data, oc_data, install_path, install_path, node_bin, oc_entry
        )	sys.exec(login_cmd)

	http.prepare_content("application/json")
	http.write_json({ status = "ok", message = "微信登录流程已启动" })
end

-- ═══════════════════════════════════════════
-- 微信登录状态/二维码 API
-- ═══════════════════════════════════════════
function action_wechat_login_status()
	local http = require "luci.http"
	local sys = require "luci.sys"

	-- 读取二维码输出
	local qrcode = ""
	local f = io.open("/tmp/openclaw-wechat-qrcode.txt", "r")
	if f then
		qrcode = f:read("*a") or ""
		f:close()
	end

	-- 检查进程状态
	local running = false
	local pid_file = io.open("/tmp/openclaw-wechat-login.pid", "r")
	if pid_file then
		local pid = pid_file:read("*a"):gsub("%s+", "")
		pid_file:close()
		if pid ~= "" then
			local check = sys.exec("kill -0 " .. pid .. " 2>/dev/null && echo yes || echo no"):gsub("%s+", "")
			running = (check == "yes")
		end
	end

	local exit_code = -1
	if not running then
		local exit_file = io.open("/tmp/openclaw-wechat-login.exit", "r")
		if exit_file then
			local code = exit_file:read("*a"):gsub("%s+", "")
			exit_file:close()
			exit_code = tonumber(code) or -1
		end
	end

        -- 提取最后生成的二维码 URL
        local qrcode_url = ""
        for url in qrcode:gmatch("https?://[^\n\r]+") do
                qrcode_url = url
        end	-- 检查是否登录成功
	local logged_in = qrcode:find("登录成功") ~= nil or qrcode:find("成功登录") ~= nil or qrcode:find("Login success") ~= nil or qrcode:find("Logged in") ~= nil

        local state = "idle"
        if logged_in then
                state = "success"
        elseif running and qrcode_url ~= "" then
                state = "qrcode"
        elseif running then
                state = "starting"
        elseif exit_code == 0 then
                state = "success"
        elseif exit_code > 0 then
                state = "failed"
        end

        -- 如果刚登录成功，触发一次重启，确保主进程加载微信
        if state == "success" and not nixio.fs.stat("/tmp/openclaw-wechat-restarted", "type") then
                sys.exec("touch /tmp/openclaw-wechat-restarted")
                sys.exec("/etc/init.d/openclaw restart &")
        end	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		state = state,
		qrcode = qrcode,
		qrcode_url = qrcode_url,
		running = running,
		exit_code = exit_code,
		logged_in = logged_in
	})
end

-- ═══════════════════════════════════════════
-- 微信插件卸载 API
-- ═══════════════════════════════════════════
function action_wechat_uninstall()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local path_info = get_path_info()
	local base_q = shellquote(path_info.install_path)

	sys.exec("/etc/init.d/openclaw stop >/dev/null 2>&1")
	local output = sys.exec("OPENCLAW_INSTALL_PATH=" .. base_q .. " /usr/bin/openclaw plugins uninstall --force openclaw-weixin 2>&1")
	sys.exec("chown -R openclaw:openclaw " .. shellquote(path_info.oc_data) .. " 2>/dev/null")
	sys.exec("/etc/init.d/openclaw start >/dev/null 2>&1 &")
	sys.exec("rm -f /tmp/openclaw-wechat-*.log /tmp/openclaw-wechat-*.pid /tmp/openclaw-wechat-*.exit /tmp/openclaw-wechat-qrcode.txt")

	http.prepare_content("application/json")
	http.write_json({ status = "ok", message = "微信插件已卸载", output = output or "" })
end
function action_wechat_check_upgrade()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local install_path = get_install_path()
	local npm_bin = install_path .. "/node/bin/npm"
	local oc_data = install_path .. "/data"

	-- 获取当前已安装版本
	local current_version = ""
	local wechat_ext_dir = find_wechat_plugin_dir(install_path)
	if wechat_ext_dir then
		local pf = io.open(wechat_ext_dir .. "/package.json", "r")
		if not pf then pf = io.open(wechat_ext_dir .. "/openclaw.plugin.json", "r") end
		if pf then
			local content = pf:read("*a") or ""
			pf:close()
			current_version = content:match('"version"%s*:%s*"([^"]+)"') or ""
		end
	end

	-- 检测最新版本 (通过 npm view)
	local latest_version = ""
	local env_prefix = string.format(
		"HOME=%s PATH=%s/node/bin:%s/global/bin:$PATH",
		oc_data, install_path, install_path
	)
	local check_cmd = string.format(
		"%s %s view @tencent-weixin/openclaw-weixin version 2>/dev/null",
		env_prefix, npm_bin
	)
	latest_version = sys.exec(check_cmd):gsub("%s+", "")

	local has_upgrade = false
	if current_version ~= "" and latest_version ~= "" and current_version ~= latest_version then
		has_upgrade = true
	end

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		current_version = current_version,
		latest_version = latest_version,
		has_upgrade = has_upgrade
	})
end

-- ═══════════════════════════════════════════
-- 微信插件升级 API (后台执行安装命令)
-- ═══════════════════════════════════════════
function action_wechat_upgrade_plugin()
	return action_wechat_install()
end
function action_wechat_logout()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local account_id = http.formvalue("account")

	if not account_id or account_id == "" then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "参数错误：未提供账号 ID" })
		return
	end
	if not account_id:match("^[%w_.%-]+$") then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "账号 ID 包含非法字符" })
		return
	end

	local path_info = get_path_info()
	local state_dir = path_info.oc_data .. "/.openclaw"
	local node_bin = path_info.node_base .. "/bin/node"
	if not nixio.fs.stat(node_bin, "type") then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "Node.js 不可用" })
		return
	end

	-- 插件当前未实现 OpenClaw channel logout 回调，按插件 clearWeixinAccount 的范围清理本地登录态。
	sys.exec("/etc/init.d/openclaw stop >/dev/null 2>&1")
	local cleanup_script = [[
const fs=require("fs"),path=require("path");
const state=process.env.OC_STATE_DIR, id=process.env.OC_ACCOUNT_ID;
const wx=path.join(state,"openclaw-weixin");
const index=path.join(wx,"accounts.json");
let accounts=[];
try{const value=JSON.parse(fs.readFileSync(index,"utf8"));if(Array.isArray(value))accounts=value.filter(x=>typeof x==="string");}catch(e){}
if(!accounts.includes(id)){console.error("账号不存在: "+id);process.exit(2);}
for(const suffix of [".json",".sync.json",".context-tokens.json"]){
	try{fs.unlinkSync(path.join(wx,"accounts",id+suffix));}catch(e){if(e.code!=="ENOENT")throw e;}
}
try{fs.unlinkSync(path.join(state,"credentials","openclaw-weixin-"+id+"-allowFrom.json"));}catch(e){if(e.code!=="ENOENT")throw e;}
accounts=accounts.filter(x=>x!==id);
fs.writeFileSync(index,JSON.stringify(accounts,null,2)+"\n");
]]
	local cleanup_cmd = "OC_STATE_DIR=" .. shellquote(state_dir) ..
		" OC_ACCOUNT_ID=" .. shellquote(account_id) ..
		" " .. shellquote(node_bin) .. " -e " .. shellquote(cleanup_script)
	local cleanup_log = "/tmp/openclaw-wechat-logout.log"
	local rc = sys.call(cleanup_cmd .. " >" .. shellquote(cleanup_log) .. " 2>&1")
	local output = sys.exec("cat " .. shellquote(cleanup_log) .. " 2>/dev/null")
	sys.exec("rm -f " .. shellquote(cleanup_log))
	local remaining = false
	local index_file = io.open(state_dir .. "/openclaw-weixin/accounts.json", "r")
	if index_file then
		local content = index_file:read("*a") or ""
		index_file:close()
		for id in content:gmatch('"([^"]+)"') do
			if id == account_id then remaining = true break end
		end
	end

	sys.exec("chown -R openclaw:openclaw " .. shellquote(state_dir .. "/openclaw-weixin") .. " 2>/dev/null")
	sys.exec("/etc/init.d/openclaw start >/dev/null 2>&1 &")

	http.prepare_content("application/json")
	if rc ~= 0 or remaining then
		http.write_json({ status = "error", message = "退出账号失败", output = output or "" })
	else
		http.write_json({ status = "ok", message = "已退出账号: " .. account_id })
	end
end
