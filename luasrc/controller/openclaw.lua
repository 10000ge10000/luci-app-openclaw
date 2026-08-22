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
	-- 与 luasrc/openclaw/paths.lua 的白名单保持一致（此处仅作模块加载失败时的兜底）
	if value == "/openclaw" or value == "/opt/openclaw" or value == "/overlay/upper/opt/openclaw" then return true end
	return value:match("^/mnt/[^/]+/openclaw$") ~= nil or value:match("^/media/[^/]+/openclaw$") ~= nil or value:match("^/srv/[^/]+/openclaw$") ~= nil
end

local function compare_versions(a, b)
	local function parts(v)
		local out = {}
		for n in tostring(v or ""):gsub("^v", ""):gmatch("(%d+)") do
			out[#out + 1] = tonumber(n) or 0
		end
		return out
	end
	local aa, bb = parts(a), parts(b)
	local len = math.max(#aa, #bb)
	for i = 1, len do
		local av, bv = aa[i] or 0, bb[i] or 0
		if av > bv then return 1 end
		if av < bv then return -1 end
	end
	return 0
end

local function is_newer_version(latest, current)
	return latest ~= nil and current ~= nil and latest ~= "" and current ~= "" and compare_versions(latest, current) > 0
end

local function fix_openclaw_state_permissions(oc_data)
	local sys = require "luci.sys"
	local state_dir = tostring(oc_data or "") .. "/.openclaw"
	sys.exec("if [ -x /usr/libexec/openclaw-permissions.sh ]; then /usr/libexec/openclaw-permissions.sh fix-state " .. shellquote(state_dir) .. " >/dev/null 2>&1; fi")
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

local function find_wechat_plugin_dir(install_path)
	local sys = require "luci.sys"
	local ext_dir = install_path .. "/data/.openclaw/extensions/openclaw-weixin"
	if nixio.fs.stat(ext_dir .. "/openclaw.plugin.json", "type") then
		return ext_dir
	end
	local npm_projects = install_path .. "/data/.openclaw/npm/projects"
	local cmd = "find " .. shellquote(npm_projects) .. " -path '*/node_modules/@tencent-weixin/openclaw-weixin/openclaw.plugin.json' -type f 2>/dev/null | head -n 1"
	local plugin_json = sys.exec(cmd):match("[^\r\n]+")
	if plugin_json and plugin_json ~= "" then
		return plugin_json:gsub("/openclaw%.plugin%.json$", "")
	end
	return nil
end

local function wechat_enable_plugin_config_cmd(install_path, node_bin, log_file, exit_file)
	exit_file = exit_file or "/tmp/openclaw-wechat-install.exit"
	local oc_data = install_path .. "/data"
	local config_file = oc_data .. "/.openclaw/openclaw.json"
	local register_js = [[
const fs = require('fs');
const path = require('path');
const configPath = process.env.OC_CONFIG;
let d = {};
try {
  d = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
  d = {};
}
if (!d.plugins || typeof d.plugins !== 'object') d.plugins = {};
if (!Array.isArray(d.plugins.allow)) d.plugins.allow = [];
// OpenClaw 2026.6.11 persists install records in its SQLite plugin index.
// Remove the deprecated authored config ledger so later config writes do not
// silently discard the only registration record again.
if (d.plugins.installs) delete d.plugins.installs['openclaw-weixin'];
if (!d.plugins.allow.includes('openclaw-weixin')) d.plugins.allow.push('openclaw-weixin');
if (!d.channels || typeof d.channels !== 'object') d.channels = {};
if (!d.channels['openclaw-weixin'] || typeof d.channels['openclaw-weixin'] !== 'object') {
  d.channels['openclaw-weixin'] = {};
}
d.channels['openclaw-weixin'].enabled = true;
fs.mkdirSync(path.dirname(configPath), { recursive: true });
fs.writeFileSync(configPath, JSON.stringify(d, null, 2) + '\n');
]]
	return "if [ $RC -eq 0 ]; then " ..
		"if [ -x " .. shellquote(node_bin) .. " ]; then " ..
		"OC_CONFIG=" .. shellquote(config_file) .. " " ..
		shellquote(node_bin) .. " -e " .. shellquote(register_js) .. " >> " .. shellquote(log_file) .. " 2>&1; " ..
		"REG_RC=$?; " ..
		"if [ $REG_RC -eq 0 ]; then " ..
		"chown openclaw:openclaw " .. shellquote(config_file) .. " 2>/dev/null; " ..
		"[ -x /usr/libexec/openclaw-permissions.sh ] && /usr/libexec/openclaw-permissions.sh fix-state " .. shellquote(oc_data .. "/.openclaw") .. " >/dev/null 2>&1; " ..
		"echo 'Enabled openclaw-weixin channel in OpenClaw config.' >> " .. shellquote(log_file) .. "; " ..
		"else RC=$REG_RC; echo $RC > " .. shellquote(exit_file) .. "; echo 'Failed to enable openclaw-weixin channel in OpenClaw config.' >> " .. shellquote(log_file) .. "; fi; " ..
		"else RC=127; echo $RC > " .. shellquote(exit_file) .. "; echo 'Node.js not found, cannot enable openclaw-weixin channel.' >> " .. shellquote(log_file) .. "; fi; " ..
		"fi; "
end


local function wechat_network_probe_cmd(node_bin, log_file)
	local target = "https://ilinkai.weixin.qq.com/ilink/bot/getupdates"
	local probe_js = [[
const target = 'https://ilinkai.weixin.qq.com/ilink/bot/getupdates';
const started = Date.now();
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(new Error('timeout')), 10000);
(async () => {
  try {
    const res = await fetch(target, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}',
      signal: controller.signal
    });
    const text = await res.text();
    const sample = text.replace(/\s+/g, ' ').slice(0, 180);
    console.log(`微信接口连通性检查: HTTP ${res.status} ${res.statusText || ''} ${Date.now() - started}ms ${sample}`);
  } catch (e) {
    const code = e && (e.code || (e.cause && e.cause.code) || e.name) || 'ERR';
    const msg = e && e.message ? e.message : String(e);
    console.log(`微信接口连通性检查失败: ${code} ${msg}`);
  } finally {
    clearTimeout(timer);
  }
})();
]]
	return "echo '微信接口连通性检查: https://ilinkai.weixin.qq.com' >> " .. shellquote(log_file) .. "; " ..
		"if command -v curl >/dev/null 2>&1; then " ..
		"_oc_probe_body=/tmp/openclaw-wechat-probe-$$.txt; " ..
		"_oc_probe_code=$(curl -sS -o \"$_oc_probe_body\" -w '%%{http_code}' --connect-timeout 8 --max-time 15 -X POST -H 'content-type: application/json' --data '{}' " .. shellquote(target) .. " 2>> " .. shellquote(log_file) .. "); " ..
		"_oc_probe_rc=$?; " ..
		"if [ $_oc_probe_rc -eq 0 ]; then _oc_probe_sample=$(tr '\\n\\r\\t' '   ' < \"$_oc_probe_body\" 2>/dev/null | cut -c1-180); echo \"微信接口连通性检查: HTTP $_oc_probe_code $_oc_probe_sample\" >> " .. shellquote(log_file) .. "; else echo \"微信接口连通性检查失败: curl exit $_oc_probe_rc\" >> " .. shellquote(log_file) .. "; fi; " ..
		"rm -f \"$_oc_probe_body\"; " ..
		"elif [ -x " .. shellquote(node_bin) .. " ]; then " ..
		"NODE_ICU_DATA=\"${NODE_ICU_DATA:-/opt/openclaw/node/share/icu}\" " .. shellquote(node_bin) .. " -e " .. shellquote(probe_js) .. " >> " .. shellquote(log_file) .. " 2>&1 || true; " ..
		"else echo '⚠️ curl/Node.js 不存在，跳过微信接口连通性检查' >> " .. shellquote(log_file) .. "; fi; "
end

local function openclaw_user_runner_cmd()
	return "_oc_raise_openclaw_limits() { " ..
		"ulimit -v unlimited 2>/dev/null || true; " ..
		"ulimit -m unlimited 2>/dev/null || true; " ..
		"ulimit -d unlimited 2>/dev/null || true; " ..
		"}; " ..
		"_oc_as_openclaw() { " ..
		"_oc_raise_openclaw_limits; " ..
		"if command -v su >/dev/null 2>&1; then su -s /bin/sh openclaw -c \"$1\"; " ..
		"elif command -v runuser >/dev/null 2>&1; then runuser -u openclaw -- sh -c \"$1\"; " ..
		"elif command -v start-stop-daemon >/dev/null 2>&1; then _oc_pid=/tmp/openclaw-user-$$.pid; _oc_cwd=$(pwd); rm -f \"$_oc_pid\"; start-stop-daemon -S -m -p \"$_oc_pid\" -c openclaw:openclaw -d \"$_oc_cwd\" -x /bin/sh -- -c \"$1\"; _oc_rc=$?; rm -f \"$_oc_pid\"; return $_oc_rc; " ..
		"else echo '❌ 缺少 su/runuser/start-stop-daemon，无法以 openclaw 用户运行命令' >&2; return 127; fi; " ..
		"}; "
end

local function wechat_openclaw_plugin_install_cmd(install_path, oc_entry, log_file, exit_file)
	return "OC_WECHAT_NODE=" .. shellquote(install_path .. "/node/bin/node") .. "; " ..
		"OC_WECHAT_ENTRY=" .. shellquote(oc_entry) .. "; export OC_WECHAT_NODE OC_WECHAT_ENTRY; " ..
		"echo '使用 OpenClaw 官方插件安装器写入 SQLite 插件索引...' >> " .. shellquote(log_file) .. "; " ..
		"_oc_as_openclaw 'HOME=$OC_WECHAT_DATA OPENCLAW_HOME=$OC_WECHAT_DATA OPENCLAW_STATE_DIR=$OC_WECHAT_DATA/.openclaw OPENCLAW_CONFIG_PATH=$OC_WECHAT_DATA/.openclaw/openclaw.json " ..
		"NODE_ICU_DATA=" .. install_path .. "/node/share/icu NPM_CONFIG_CACHE=$OC_WECHAT_DATA/.npm npm_config_cache=$OC_WECHAT_DATA/.npm TMPDIR=$OC_WECHAT_DATA/.tmp " ..
		"PATH=" .. install_path .. "/node/bin:" .. install_path .. "/global/bin:$PATH " ..
		"\"$OC_WECHAT_NODE\" \"$OC_WECHAT_ENTRY\" plugins install --force --pin @tencent-weixin/openclaw-weixin@2.4.6' >> " .. shellquote(log_file) .. " 2>&1; " ..
		"RC=$?; echo $RC > " .. shellquote(exit_file) .. "; " ..
		"if [ $RC -eq 0 ]; then echo '✅ OpenClaw 插件索引注册完成' >> " .. shellquote(log_file) .. "; else echo '❌ OpenClaw 插件安装失败 (exit: '$RC')' >> " .. shellquote(log_file) .. "; fi; "
end

local function wechat_finalize_plugin_registry_cmd(install_path, oc_entry, log_file, exit_file)
	exit_file = exit_file or "/tmp/openclaw-wechat-install.exit"
	local oc_data = install_path .. "/data"
	local node_bin = install_path .. "/node/bin/node"
	local cli_env = "HOME=" .. oc_data .. " OPENCLAW_HOME=" .. oc_data ..
		" OPENCLAW_STATE_DIR=" .. oc_data .. "/.openclaw" ..
		" OPENCLAW_CONFIG_PATH=" .. oc_data .. "/.openclaw/openclaw.json" ..
		" NODE_ICU_DATA=" .. install_path .. "/node/share/icu" ..
		" NPM_CONFIG_CACHE=" .. oc_data .. "/.npm TMPDIR=" .. oc_data .. "/.tmp" ..
		" PATH=" .. install_path .. "/node/bin:" .. install_path .. "/global/bin:$PATH "
	local cli = cli_env .. node_bin .. " " .. oc_entry

	return "if [ $RC -eq 0 ]; then " ..
		"echo '正在写入微信插件启用状态...' >> " .. shellquote(log_file) .. "; " ..
		"_oc_as_openclaw '" .. cli .. " plugins enable openclaw-weixin' >> " .. shellquote(log_file) .. " 2>&1; " ..
		"FINAL_RC=$?; " ..
		"if [ $FINAL_RC -eq 0 ]; then " ..
		"echo '正在刷新 SQLite 插件注册表...' >> " .. shellquote(log_file) .. "; " ..
		"_oc_as_openclaw '" .. cli .. " plugins registry --refresh' >> " .. shellquote(log_file) .. " 2>&1; " ..
		"FINAL_RC=$?; fi; " ..
		"if [ $FINAL_RC -eq 0 ]; then " ..
		"_OC_WECHAT_INSPECT=/tmp/openclaw-wechat-inspect-$$.log; " ..
		"_oc_as_openclaw '" .. cli .. " plugins inspect openclaw-weixin' > \"$_OC_WECHAT_INSPECT\" 2>&1; " ..
		"VERIFY_RC=$?; cat \"$_OC_WECHAT_INSPECT\" >> " .. shellquote(log_file) .. "; " ..
		"if [ $VERIFY_RC -ne 0 ] || ! grep -q '^Status: loaded$' \"$_OC_WECHAT_INSPECT\" || ! grep -q '^channel: openclaw-weixin$' \"$_OC_WECHAT_INSPECT\"; then FINAL_RC=1; fi; " ..
		"rm -f \"$_OC_WECHAT_INSPECT\"; fi; " ..
		"if [ $FINAL_RC -eq 0 ]; then " ..
		"echo '✅ 微信插件已启用，SQLite 注册表已刷新并通过加载验证' >> " .. shellquote(log_file) .. "; " ..
		"else RC=$FINAL_RC; echo $RC > " .. shellquote(exit_file) .. "; " ..
		"echo '❌ 微信插件启用或注册表验证失败' >> " .. shellquote(log_file) .. "; fi; " ..
		"fi; "
end

local function wechat_tail_detail(text, max_lines)
	if not text or text == "" then
		return ""
	end
	local lines = {}
	for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		if line and line ~= "" then
			line = line:gsub("\27%[[0-9;]*m", "")
			if not line:match("^%s*$") then
				table.insert(lines, line)
			end
		end
	end
	local start = math.max(1, #lines - (max_lines or 30) + 1)
	local out = {}
	for i = start, #lines do
		table.insert(out, lines[i])
	end
	return table.concat(out, "\n")
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

local function wechat_python3_bootstrap_cmd(log_file)
	return "if ! command -v python3 >/dev/null 2>&1; then " ..
		"echo '未检测到 python3，正在尝试安装 python3-light...' >> " .. shellquote(log_file) .. "; " ..
		"(opkg update && opkg install python3-light) >> " .. shellquote(log_file) .. " 2>&1 || true; " ..
		"fi; " ..
		"if ! command -v python3 >/dev/null 2>&1; then " ..
		"echo '❌ python3-light 自动安装失败，请手动执行: opkg update && opkg install python3-light' >> " .. shellquote(log_file) .. "; " ..
		"echo 127 > /tmp/openclaw-wechat-install.exit; exit 0; " ..
		"fi; "
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
-- 优雅停止必须走安装目录里的 CLI wrapper 全路径：uhttpd 进程不加载
-- /etc/profile.d，裸 `openclaw` 在 LuCI 环境下必然 PATH 不可达。
local function gateway_graceful_stop_cmd()
	local oc_cli = get_install_path() .. "/global/bin/openclaw"
	return "if [ -x " .. shellquote(oc_cli) .. " ]; then " .. shellquote(oc_cli) .. " gateway stop >/dev/null 2>&1 || true; fi"
end

local function ensure_port_free(port)
	local sys = require "luci.sys"
	if not port or port == "" then return end
	if not tostring(port):match("^%d+$") then return end
	-- 优先尝试使用 openclaw 自身的 stop 命令（如果已安装）
	sys.exec(gateway_graceful_stop_cmd())

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
			sys.exec(gateway_graceful_stop_cmd())
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

	-- 如果端口未监听，结合 procd 与真实进程判断状态。
	-- 不能只看 pid 字段或 pidfile：procd crash-loop / stale pidfile 会让 LuCI 误显示“正在启动”。
	if not result.gateway_running and enabled == "1" then
		local procd_pid = sys.exec("ubus call service list '{\"name\":\"openclaw\"}' 2>/dev/null | jsonfilter -e '$.openclaw.instances.gateway.pid' 2>/dev/null"):gsub("%s+", "")
		local procd_running = sys.exec("ubus call service list '{\"name\":\"openclaw\"}' 2>/dev/null | jsonfilter -e '$.openclaw.instances.gateway.running' 2>/dev/null"):gsub("%s+", "")
		local procd_exit = sys.exec("ubus call service list '{\"name\":\"openclaw\"}' 2>/dev/null | jsonfilter -e '$.openclaw.instances.gateway.exit_code' 2>/dev/null"):gsub("%s+", "")
		if procd_pid == "null" or not procd_pid:match("^%d+$") then procd_pid = "" end
		if procd_exit == "null" then procd_exit = "" end
		result.gateway_exit_code = procd_exit

		local procd_pid_alive = false
		if procd_pid ~= "" then
			procd_pid_alive = (sys.exec("[ -d /proc/" .. procd_pid .. " ] && echo 1 || echo 0"):gsub("%s+", "") == "1")
		end
		local pidfile_pid = sys.exec("cat /var/run/openclaw.pid 2>/dev/null || true"):gsub("%s+", "")
		local pidfile_stale = false
		if pidfile_pid ~= "" and pidfile_pid:match("^%d+$") then
			pidfile_stale = (sys.exec("[ -d /proc/" .. pidfile_pid .. " ] && echo 0 || echo 1"):gsub("%s+", "") == "1")
		end
		local crash_loop = sys.exec("logread 2>/dev/null | grep -E 'Instance openclaw::gateway.*crash loop' | tail -1"):gsub("^%s+", ""):gsub("%s+$", "")

		if procd_exit ~= "" and tonumber(procd_exit) and tonumber(procd_exit) ~= 0 and procd_running ~= "true" then
			result.gateway_failed = true
		elseif crash_loop ~= "" and pidfile_stale and procd_running ~= "true" and not procd_pid_alive then
			result.gateway_failed = true
			result.gateway_crash_loop = true
			if result.gateway_exit_code == "" then result.gateway_exit_code = "crash-loop" end
		elseif procd_running == "true" or procd_pid_alive then
			result.gateway_starting = true
			result.pid = procd_pid
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
		-- 常规“重启”只重启 Gateway，不重启 Web PTY，避免 stop+start 带来的长时间等待。
		-- 如果 procd 没有 gateway 实例，再回退到 start。
		local procd_running = sys.exec("ubus call service list '{\"name\":\"openclaw\"}' 2>/dev/null | jsonfilter -e '$.openclaw.instances.gateway.running' 2>/dev/null"):gsub("%s+", "")
		if procd_running == "true" then
			sys.exec("/etc/init.d/openclaw restart_gateway >/dev/null 2>&1 &")
		else
			sys.exec("/etc/init.d/openclaw start >/dev/null 2>&1 &")
		end
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

	if is_newer_version(plugin_latest, plugin_current) then
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

	-- 使用统一路径 helper，兼容用户误填 /mnt/data/openclaw 的场景。
	local install_path = get_install_path()
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
		fix_openclaw_state_permissions(oc_data_dir)

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
        local wechat_package_json = wechat_ext_dir and (wechat_ext_dir .. "/package.json") or ""

        if nixio.fs.stat(wechat_plugin_json, "type") then
                result.plugin_installed = true
                -- 尝试读取版本号
                if nixio.fs.stat(wechat_package_json, "type") then
                        local pf = io.open(wechat_package_json, "r")
                        if pf then
                                local p_content = pf:read("*a")
                                pf:close()
                                local ver = p_content:match('"version"%s*:%s*"([^"]+)"')
                                if ver then
                                        result.plugin_version = ver
                                end
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
                                table.insert(result.accounts, {name = acc})
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
	local uci = require "luci.model.uci".cursor()

	-- 使用统一的路径获取函数 (唯一来源: UCI 配置)
	local install_path = get_install_path()
	local node_bin = install_path .. "/node/bin/node"
	local npx_bin = install_path .. "/node/bin/npx"
	local oc_data = install_path .. "/data"
	local oc_entry = ""
	for _, d in ipairs({
		install_path .. "/global/lib/node_modules/openclaw",
		install_path .. "/global/node_modules/openclaw",
		install_path .. "/node/lib/node_modules/openclaw",
	}) do
		if nixio.fs.stat(d .. "/openclaw.mjs", "type") then
			oc_entry = d .. "/openclaw.mjs"
			break
		elseif nixio.fs.stat(d .. "/dist/cli.js", "type") then
			oc_entry = d .. "/dist/cli.js"
			break
		end
	end

	-- 清理旧日志和状态
	sys.exec("rm -f /tmp/openclaw-wechat-install.log /tmp/openclaw-wechat-install.pid /tmp/openclaw-wechat-install.exit")

	-- 官方插件安装器必须通过当前 OpenClaw CLI 写入 SQLite 安装索引。
	if not nixio.fs.stat(node_bin, "type") or oc_entry == "" then
		local log_content = "开始安装微信插件...\n" ..
			"安装路径: " .. install_path .. "\n" ..
			"❌ 错误: Node.js 或 OpenClaw CLI 不存在。\n" ..
			"请先在「基本设置」页面安装运行环境。\n" ..
			"UCI install_path=" .. (uci:get("openclaw", "main", "install_path") or "未设置")
		local f = io.open("/tmp/openclaw-wechat-install.log", "w")
		if f then
			f:write(log_content)
			f:close()
		end
		local ef = io.open("/tmp/openclaw-wechat-install.exit", "w")
		if ef then
			ef:write("127")
			ef:close()
		end
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "微信插件安装已在后台启动..." })
		return
	end
	if not ensure_openclaw_user(oc_data) then
		write_wechat_log_and_exit(
			"/tmp/openclaw-wechat-install.log",
			"/tmp/openclaw-wechat-install.exit",
			"开始安装微信插件...\n安装路径: " .. install_path .. "\n❌ 错误: 无法创建或读取 openclaw 系统用户。\n请检查 /etc/passwd、/etc/group 是否可写。\n",
			1
		)
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "微信插件安装已在后台启动..." })
		return
	end

	-- 后台执行安装。注意：插件安装不需要释放 Gateway 端口，避免误停正在运行的 Gateway 触发 procd crash-loop。
	-- 微信插件安装目录路径 (用于安装后权限修复)
	local extensions_dir = install_path .. "/data/.openclaw/extensions"
	local install_cmd = string.format(
		"( " ..
		openclaw_user_runner_cmd() ..
		"echo '开始安装微信插件...' > /tmp/openclaw-wechat-install.log; " ..
		"echo '安装路径: %s' >> /tmp/openclaw-wechat-install.log; " ..
		"echo 'npx 路径: %s' >> /tmp/openclaw-wechat-install.log; " ..
		"echo 'Node 版本:' $(%s -v 2>/dev/null || echo 未检测到) >> /tmp/openclaw-wechat-install.log; " ..
		wechat_network_probe_cmd(node_bin, "/tmp/openclaw-wechat-install.log") ..
		wechat_python3_bootstrap_cmd("/tmp/openclaw-wechat-install.log") ..
		"OC_WECHAT_DATA=%s; export OC_WECHAT_DATA; " ..
		"if [ -x /usr/libexec/openclaw-permissions.sh ]; then /usr/libexec/openclaw-permissions.sh prepare-workdirs \"$OC_WECHAT_DATA\" >/dev/null 2>&1; " ..
		"else mkdir -p \"$OC_WECHAT_DATA/.npm\" \"$OC_WECHAT_DATA/.tmp\" \"$OC_WECHAT_DATA/.openclaw/extensions\"; chown -R openclaw:openclaw \"$OC_WECHAT_DATA/.npm\" \"$OC_WECHAT_DATA/.tmp\" 2>/dev/null; chown openclaw:openclaw \"$OC_WECHAT_DATA/.openclaw\" 2>/dev/null; fi; " ..
		"if [ ! -w %s/.npm ] || [ ! -w %s/.tmp ]; then echo '❌ npm cache/tmp 目录不可写' >> /tmp/openclaw-wechat-install.log; echo 1 > /tmp/openclaw-wechat-install.exit; exit 0; fi; " ..
		"_oc_as_openclaw 'test -w %s/.npm && test -w %s/.tmp && test -w %s/.openclaw' || { echo '❌ openclaw 用户无法写入 npm cache/tmp/data 目录' >> /tmp/openclaw-wechat-install.log; echo 1 > /tmp/openclaw-wechat-install.exit; exit 0; }; " ..
		wechat_openclaw_plugin_install_cmd(install_path, oc_entry, "/tmp/openclaw-wechat-install.log", "/tmp/openclaw-wechat-install.exit") ..
		wechat_enable_plugin_config_cmd(install_path, node_bin, "/tmp/openclaw-wechat-install.log") ..
		wechat_finalize_plugin_registry_cmd(install_path, oc_entry, "/tmp/openclaw-wechat-install.log", "/tmp/openclaw-wechat-install.exit") ..
		-- 关键修复: 安装完成后强制修复插件目录权限 (确保 Gateway 可读取插件)
		-- 原因: npx/npm 以 root 身份创建目录，默认权限 700 导致其他用户无法读取
		-- 官方 npm generation 由 openclaw 用户维护，必须允许后续升级清理。
		"[ -x /usr/libexec/openclaw-permissions.sh ] && /usr/libexec/openclaw-permissions.sh fix-state %s/.openclaw >/dev/null 2>&1; " ..
		"if [ $RC -eq 0 ]; then echo '✅ 微信插件安装成功！' >> /tmp/openclaw-wechat-install.log; " ..
		"else echo '❌ 安装失败 (exit: '$RC')' >> /tmp/openclaw-wechat-install.log; fi " ..
		") & echo $! > /tmp/openclaw-wechat-install.pid",
		install_path, npx_bin, node_bin,
		shellquote(oc_data),
		oc_data, oc_data,
		oc_data, oc_data, oc_data,
		install_path, oc_data, oc_data, oc_data,
		oc_data
	)
	sys.exec(install_cmd)

	http.prepare_content("application/json")
	http.write_json({ status = "ok", message = "微信插件安装已在后台启动..." })
end

-- ═══════════════════════════════════════════
-- 微信安装日志轮询 API
-- ═══════════════════════════════════════════
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
        sys.exec("rm -f /tmp/openclaw-wechat-qrcode.txt /tmp/openclaw-wechat-login.pid /tmp/openclaw-wechat-login.exit /tmp/openclaw-wechat-restarted")

        local wechat_plugin_dir = find_wechat_plugin_dir(install_path)
        if not wechat_plugin_dir then
                write_wechat_log_and_exit(
                        "/tmp/openclaw-wechat-qrcode.txt",
                        "/tmp/openclaw-wechat-login.exit",
                        "微信插件未安装...\n安装路径: " .. install_path .. "\n未找到包含 openclaw.plugin.json 的微信插件目录。\n请先安装插件或重新安装插件。\n",
                        1
                )
                http.prepare_content("application/json")
                http.write_json({ status = "error", message = "微信插件未安装或未找到，请先安装/重新安装插件" })
                return
        end

        -- 后台启动登录流程，将二维码输出到文件
        local login_cmd = string.format(
                "( " ..
                openclaw_user_runner_cmd() ..
                "echo '正在启动微信登录...' > /tmp/openclaw-wechat-qrcode.txt; " ..
                "echo '安装路径: %s' >> /tmp/openclaw-wechat-qrcode.txt; " ..
                "echo 'OpenClaw 入口: %s' >> /tmp/openclaw-wechat-qrcode.txt; " ..
                "echo '微信插件目录: %s' >> /tmp/openclaw-wechat-qrcode.txt; " ..
                "echo 'Node 版本:' $(%s -v 2>/dev/null || echo 未检测到) >> /tmp/openclaw-wechat-qrcode.txt; " ..
                "if command -v python3 >/dev/null 2>&1; then echo 'python3: 已安装' >> /tmp/openclaw-wechat-qrcode.txt; else echo '⚠️ python3: 未安装，微信插件可能无法完成配对' >> /tmp/openclaw-wechat-qrcode.txt; fi; " ..
                wechat_network_probe_cmd(node_bin, "/tmp/openclaw-wechat-qrcode.txt") ..
                "mkdir -p %s/.npm %s/.tmp %s/.openclaw/openclaw-weixin; " ..
                "touch %s/.openclaw/openclaw.json 2>/dev/null || true; " ..
                "chown -R openclaw:openclaw %s/.npm %s/.tmp %s/.openclaw/openclaw-weixin 2>/dev/null; " ..
                "chown openclaw:openclaw %s/.openclaw %s/.openclaw/openclaw.json 2>/dev/null; " ..
                "_oc_as_openclaw 'test -w %s/.npm && test -w %s/.tmp && test -w %s/.openclaw && test -w %s/.openclaw/openclaw-weixin && test -w %s/.openclaw/openclaw.json' || { echo '❌ openclaw 用户无法写入微信登录目录，请检查数据目录权限' >> /tmp/openclaw-wechat-qrcode.txt; echo 1 > /tmp/openclaw-wechat-login.exit; exit 0; }; " ..
                "RC=0; " ..
                wechat_enable_plugin_config_cmd(install_path, node_bin, "/tmp/openclaw-wechat-qrcode.txt", "/tmp/openclaw-wechat-login.exit") ..
		wechat_finalize_plugin_registry_cmd(install_path, oc_entry, "/tmp/openclaw-wechat-qrcode.txt", "/tmp/openclaw-wechat-login.exit") ..
                "if [ $RC -ne 0 ]; then echo '❌ 微信插件注册失败，无法登录' >> /tmp/openclaw-wechat-qrcode.txt; exit 0; fi; " ..
                "cd %s && " ..
                "_oc_as_openclaw 'HOME=%s OPENCLAW_HOME=%s OPENCLAW_STATE_DIR=%s/.openclaw OPENCLAW_CONFIG_PATH=%s/.openclaw/openclaw.json " ..
                "NODE_ICU_DATA=%s/node/share/icu " ..
                "NPM_CONFIG_CACHE=%s/.npm npm_config_cache=%s/.npm TMPDIR=%s/.tmp PATH=%s/node/bin:%s/global/bin:$PATH " ..
                "%s %s channels login --channel openclaw-weixin' >> /tmp/openclaw-wechat-qrcode.txt 2>&1; " ..
                "echo $? > /tmp/openclaw-wechat-login.exit; " ..
                ") >/dev/null 2>&1 & echo $! > /tmp/openclaw-wechat-login.pid",
                install_path, oc_entry, wechat_plugin_dir, node_bin,
                oc_data, oc_data, oc_data,
                oc_data,
                oc_data, oc_data, oc_data,
                oc_data, oc_data,
                oc_data, oc_data, oc_data, oc_data, oc_data,
                install_path,
                oc_data, oc_data, oc_data, oc_data,
                install_path,
                oc_data, oc_data, oc_data,
                install_path, install_path,
                node_bin, oc_entry
        )
        sys.exec(login_cmd)

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

        -- 提取最后生成的二维码 URL；排除前置网络探测中的接口 URL，避免页面误导用户扫码错误链接
        local qrcode_url = ""
        for url in qrcode:gmatch("https?://[^%s%]%)}\"'<>]+") do
                if url:match("liteapp%.weixin%.qq%.com/q/") or url:match("weixin%.qq%.com/q/") then
                        qrcode_url = url
                end
        end
        if qrcode_url == "" then
                for url in qrcode:gmatch("https?://[^%s%]%)}\"'<>]+") do
                        if not url:match("ilinkai%.weixin%.qq%.com") then
                                qrcode_url = url
                        end
                end
        end
	-- 检查是否登录成功。微信插件在 OpenClaw 2026.6.11 中可能已经保存认证，
	-- 但随后通过 Gateway 动态启动渠道时报 "invalid channels.start channel" 并返回
	-- 非 0；这种情况账号已配对成功，LuCI 不应误判为失败。
	local logged_in = qrcode:find("登录成功") ~= nil
		or qrcode:find("成功登录") ~= nil
		or qrcode:find("Login success") ~= nil
		or qrcode:find("Logged in") ~= nil
		or qrcode:find("已将此 OpenClaw 连接到微信") ~= nil
		or qrcode:find("Local login saved auth for openclaw%-weixin") ~= nil

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

        local error_detail = ""
        local message = ""
        if state == "failed" then
                error_detail = wechat_tail_detail(qrcode, 35)
                if error_detail ~= "" then
                        message = "登录失败，下面是最近日志，请按提示处理"
                else
                        message = "登录失败，请查看 /tmp/openclaw-wechat-qrcode.txt"
                end
        end

        -- 如果刚登录成功，触发一次轻量重启，确保主进程加载微信账号。
        -- 不使用完整 /etc/init.d/openclaw restart，避免同时重启 Web PTY 和拉长等待时间。
        if state == "success" and not nixio.fs.stat("/tmp/openclaw-wechat-restarted", "type") then
                sys.exec("touch /tmp/openclaw-wechat-restarted")
                sys.exec("/etc/init.d/openclaw restart_gateway >/dev/null 2>&1 &")
                message = "微信登录成功，正在重新加载微信账号"
        end
	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		state = state,
		qrcode = qrcode,
		qrcode_url = qrcode_url,
		running = running,
		exit_code = exit_code,
		logged_in = logged_in,
		message = message,
		error_detail = error_detail
	})
end

-- ═══════════════════════════════════════════
-- 微信插件卸载 API
-- ═══════════════════════════════════════════
function action_wechat_uninstall()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local install_path = get_install_path()
	local node_bin = install_path .. "/node/bin/node"
	local oc_data = install_path .. "/data"

	-- 删除微信插件目录和账号状态。所有路径都限制在当前 OpenClaw 数据目录下。
	local wechat_ext_dir = oc_data .. "/.openclaw/extensions/openclaw-weixin"
	local wechat_state_dir = oc_data .. "/.openclaw/openclaw-weixin"
	local npm_projects = oc_data .. "/.openclaw/npm/projects"
	sys.exec("rm -rf " .. shellquote(wechat_ext_dir) .. " " .. shellquote(wechat_state_dir) .. " 2>/dev/null")
	if nixio.fs.stat(npm_projects, "type") then
		sys.exec("find " .. shellquote(npm_projects) .. " -path '*/node_modules/@tencent-weixin/openclaw-weixin' -type d -prune -exec rm -rf {} + 2>/dev/null")
		sys.exec("find " .. shellquote(npm_projects) .. " -path '*/node_modules/@tencent-weixin/openclaw-weixin-cli' -type d -prune -exec rm -rf {} + 2>/dev/null")
	end

	-- 从配置中删除微信相关配置
	local config_file = oc_data .. "/.openclaw/openclaw.json"
	if nixio.fs.stat(config_file, "type") then
		local cleanup_js = [[
const fs = require('fs');
const p = process.env.OC_CONFIG;
let d = {};
try { d = JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) { process.exit(0); }
function drop(o, k) { if (o && typeof o === 'object') delete o[k]; }
function dropChannel(o) { drop(o, 'openclaw-weixin'); drop(o, 'weixin'); }
if (d.plugins && Array.isArray(d.plugins.allow)) {
  d.plugins.allow = d.plugins.allow.filter((x) => x !== 'openclaw-weixin' && x !== 'weixin');
}
if (d.plugins) {
  dropChannel(d.plugins.installs);
  dropChannel(d.plugins.entries);
}
dropChannel(d.channels);
dropChannel(d.channel);
dropChannel(d);
fs.writeFileSync(p, JSON.stringify(d, null, 2));
]]
		if nixio.fs.stat(node_bin, "type") then
			sys.exec("OC_CONFIG=" .. shellquote(config_file) .. " " .. shellquote(node_bin) .. " -e " .. shellquote(cleanup_js) .. " 2>/dev/null")
		else
			local cf = io.open(config_file, "r")
			local content = ""
			if cf then
				content = cf:read("*a") or ""
				cf:close()
			end
			content = content:gsub(',?%s*"openclaw%-weixin"%s*:%s*%b{}', "")
			content = content:gsub('"openclaw%-weixin"%s*:%s*%b{}%s*,?', "")
			local wf = io.open(config_file, "w")
			if wf then
				wf:write(content)
				wf:close()
			end
		end
		sys.exec("chown openclaw:openclaw " .. shellquote(config_file) .. " 2>/dev/null")
	end

	-- 清理临时文件
	sys.exec("rm -f /tmp/openclaw-wechat-*.log /tmp/openclaw-wechat-*.pid /tmp/openclaw-wechat-*.exit /tmp/openclaw-wechat-qrcode.txt")

	http.prepare_content("application/json")
	http.write_json({ status = "ok", message = "微信插件已卸载" })
end

-- ═══════════════════════════════════════════
-- 微信插件检测升级 API
-- ═══════════════════════════════════════════
function action_wechat_check_upgrade()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local install_path = get_install_path()
	local npx_bin = install_path .. "/node/bin/npx"
	local oc_data = install_path .. "/data"

	-- 获取当前已安装版本
	local current_version = ""
	local wechat_ext_dir = find_wechat_plugin_dir(install_path) or (install_path .. "/data/.openclaw/extensions/openclaw-weixin")
	local plugin_json = wechat_ext_dir .. "/openclaw.plugin.json"
	local pf = io.open(plugin_json, "r")
	if pf then
		local content = pf:read("*a") or ""
		pf:close()
		current_version = content:match('"version"%s*:%s*"([^"]+)"') or ""
	end

	-- 检测最新版本 (通过 npm view)
	local latest_version = ""
	local env_prefix = string.format(
		"HOME=%s PATH=%s/node/bin:%s/global/bin:$PATH",
		oc_data, install_path, install_path
	)
	local check_cmd = string.format(
		"%s %s view @tencent-weixin/openclaw-weixin version 2>/dev/null",
		env_prefix, npx_bin
	)
	latest_version = sys.exec(check_cmd):gsub("%s+", "")

	local has_upgrade = false
	if is_newer_version(latest_version, current_version) then
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
	local http = require "luci.http"
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()

	-- 使用统一的路径获取函数 (唯一来源: UCI 配置)
	local install_path = get_install_path()
	local node_bin = install_path .. "/node/bin/node"
	local npx_bin = install_path .. "/node/bin/npx"
	local oc_data = install_path .. "/data"
	local oc_entry = ""
	for _, d in ipairs({
		install_path .. "/global/lib/node_modules/openclaw",
		install_path .. "/global/node_modules/openclaw",
		install_path .. "/node/lib/node_modules/openclaw",
	}) do
		if nixio.fs.stat(d .. "/openclaw.mjs", "type") then
			oc_entry = d .. "/openclaw.mjs"
			break
		elseif nixio.fs.stat(d .. "/dist/cli.js", "type") then
			oc_entry = d .. "/dist/cli.js"
			break
		end
	end

	-- 清理旧日志和状态
	sys.exec("rm -f /tmp/openclaw-wechat-install.log /tmp/openclaw-wechat-install.pid /tmp/openclaw-wechat-install.exit")

	-- 升级也必须由官方 CLI 更新 SQLite 插件索引。
	if not nixio.fs.stat(node_bin, "type") or oc_entry == "" then
		local log_content = "正在升级微信插件...\n" ..
			"安装路径: " .. install_path .. "\n" ..
			"❌ 错误: Node.js 或 OpenClaw CLI 不存在。\n" ..
			"请先检查运行环境是否正常安装。\n" ..
			"UCI install_path=" .. (uci:get("openclaw", "main", "install_path") or "未设置")
		local f = io.open("/tmp/openclaw-wechat-install.log", "w")
		if f then
			f:write(log_content)
			f:close()
		end
		local ef = io.open("/tmp/openclaw-wechat-install.exit", "w")
		if ef then
			ef:write("127")
			ef:close()
		end
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "微信插件升级已在后台启动..." })
		return
	end
	if not ensure_openclaw_user(oc_data) then
		write_wechat_log_and_exit(
			"/tmp/openclaw-wechat-install.log",
			"/tmp/openclaw-wechat-install.exit",
			"正在升级微信插件...\n安装路径: " .. install_path .. "\n❌ 错误: 无法创建或读取 openclaw 系统用户。\n请检查 /etc/passwd、/etc/group 是否可写。\n",
			1
		)
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "微信插件升级已在后台启动..." })
		return
	end

	-- 后台执行升级 (其实就是重新安装最新版)。不要释放 Gateway 端口，避免误停正在运行的 Gateway。
	-- 微信插件安装目录路径 (用于升级后权限修复)
	local extensions_dir = install_path .. "/data/.openclaw/extensions"
	local upgrade_cmd = string.format(
		"( " ..
		openclaw_user_runner_cmd() ..
		"echo '正在升级微信插件...' > /tmp/openclaw-wechat-install.log; " ..
		"echo '安装路径: %s' >> /tmp/openclaw-wechat-install.log; " ..
		"echo 'npx 路径: %s' >> /tmp/openclaw-wechat-install.log; " ..
		"echo 'Node 版本:' $(%s -v 2>/dev/null || echo 未检测到) >> /tmp/openclaw-wechat-install.log; " ..
		wechat_network_probe_cmd(node_bin, "/tmp/openclaw-wechat-install.log") ..
		wechat_python3_bootstrap_cmd("/tmp/openclaw-wechat-install.log") ..
		"OC_WECHAT_DATA=%s; export OC_WECHAT_DATA; " ..
		"if [ -x /usr/libexec/openclaw-permissions.sh ]; then /usr/libexec/openclaw-permissions.sh prepare-workdirs \"$OC_WECHAT_DATA\" >/dev/null 2>&1; " ..
		"else mkdir -p \"$OC_WECHAT_DATA/.npm\" \"$OC_WECHAT_DATA/.tmp\" \"$OC_WECHAT_DATA/.openclaw/extensions\"; chown -R openclaw:openclaw \"$OC_WECHAT_DATA/.npm\" \"$OC_WECHAT_DATA/.tmp\" 2>/dev/null; chown openclaw:openclaw \"$OC_WECHAT_DATA/.openclaw\" 2>/dev/null; fi; " ..
		"if [ ! -w %s/.npm ] || [ ! -w %s/.tmp ]; then echo '❌ npm cache/tmp 目录不可写' >> /tmp/openclaw-wechat-install.log; echo 1 > /tmp/openclaw-wechat-install.exit; exit 0; fi; " ..
		"_oc_as_openclaw 'test -w %s/.npm && test -w %s/.tmp && test -w %s/.openclaw' || { echo '❌ openclaw 用户无法写入 npm cache/tmp/data 目录' >> /tmp/openclaw-wechat-install.log; echo 1 > /tmp/openclaw-wechat-install.exit; exit 0; }; " ..
		wechat_openclaw_plugin_install_cmd(install_path, oc_entry, "/tmp/openclaw-wechat-install.log", "/tmp/openclaw-wechat-install.exit") ..
		wechat_enable_plugin_config_cmd(install_path, node_bin, "/tmp/openclaw-wechat-install.log") ..
		wechat_finalize_plugin_registry_cmd(install_path, oc_entry, "/tmp/openclaw-wechat-install.log", "/tmp/openclaw-wechat-install.exit") ..
		-- 关键修复: 升级完成后强制修复插件目录权限 (确保 Gateway 可读取插件)
		-- 官方 npm generation 由 openclaw 用户维护，必须允许后续升级清理。
		"[ -x /usr/libexec/openclaw-permissions.sh ] && /usr/libexec/openclaw-permissions.sh fix-state %s/.openclaw >/dev/null 2>&1; " ..
		"if [ $RC -eq 0 ]; then echo '✅ 微信插件升级成功！' >> /tmp/openclaw-wechat-install.log; " ..
		"else echo '❌ 升级失败 (exit: '$RC')' >> /tmp/openclaw-wechat-install.log; fi " ..
		") & echo $! > /tmp/openclaw-wechat-install.pid",
		install_path, npx_bin, node_bin,
		shellquote(oc_data),
		oc_data, oc_data,
		oc_data, oc_data, oc_data,
		install_path, oc_data, oc_data, oc_data,
		oc_data
	)
	sys.exec(upgrade_cmd)

	http.prepare_content("application/json")
	http.write_json({ status = "ok", message = "微信插件升级已在后台启动..." })
end

-- ═══════════════════════════════════════════
-- 微信退出/删除账号 API
-- ═══════════════════════════════════════════
function action_wechat_logout()
        local http = require "luci.http"
        local sys = require "luci.sys"
        local account_id = http.formvalue("account")

	        if not account_id or account_id == "" then
	                http.prepare_content("application/json")
	                http.write_json({ status = "error", message = "参数错误：未提供账号 ID" })
	                return
	        end
		if account_id:match("[`$;&|<>\"']") then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "账号 ID 包含非法字符" })
			return
		end

        local install_path = get_install_path()
        local node_bin = install_path .. "/node/bin/node"
        local oc_data = install_path .. "/data"
        local oc_entry = ""

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
			http.write_json({ status = "error", message = "无法创建或读取 openclaw 系统用户" })
			return
		end

	        -- 在后台执行 logout
        local logout_cmd = string.format(
                openclaw_user_runner_cmd() .. "cd %s && _oc_as_openclaw 'HOME=%s OPENCLAW_HOME=%s OPENCLAW_STATE_DIR=%s/.openclaw OPENCLAW_CONFIG_PATH=%s/.openclaw/openclaw.json NODE_ICU_DATA=%s/node/share/icu " ..
                "PATH=%s/node/bin:%s/global/bin:$PATH " ..
                "%s %s channels logout --channel openclaw-weixin --account \"%s\"'",
                oc_data, oc_data, oc_data, oc_data, oc_data, install_path, install_path, install_path, node_bin, oc_entry, account_id
        )

        sys.exec(logout_cmd .. " >/dev/null 2>&1")
        
        -- 重启服务
        sys.exec("/etc/init.d/openclaw restart &")

        http.prepare_content("application/json")
        http.write_json({ status = "ok", message = "已下线账号: " .. account_id })
end
