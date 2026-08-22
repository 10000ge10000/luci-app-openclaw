#!/bin/sh
set -eu

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -q "OC_TESTED_VERSION=\"2026.7.1-2\"" root/usr/bin/openclaw-env || fail "tested OpenClaw version not pinned"
grep -q "NODE_VERSION_V2=\"22.23.0\"" root/usr/bin/openclaw-env || fail "default Node.js version not pinned"
grep -q "OC_NODE_MIN_VERSION=\"\${OC_NODE_MIN_VERSION:-22.22.3}\"" root/usr/bin/openclaw-env || fail "minimum Node.js version not pinned"
grep -q "oc_assert_node_min_version" root/usr/bin/openclaw-env || fail "Node.js minimum version check missing"
grep -q 'oc_node_version_ge "$from_pkg" "$required"' root/usr/bin/openclaw-env || fail "package Node.js requirement must not lower static minimum"
grep -q "install_openclaw_cli_wrapper" root/usr/bin/openclaw-env || fail "OpenClaw CLI wrapper must set runtime env"
grep -q 'export NODE_ICU_DATA="${NODE_BASE}/share/icu"' root/usr/bin/openclaw-env || fail "OpenClaw CLI wrapper must export NODE_ICU_DATA"
grep -q 'rm -f "$OC_GLOBAL/bin/openclaw"' root/usr/bin/openclaw-env || fail "OpenClaw CLI wrapper must unlink npm symlink before writing"
grep -q "Extended_Pictographic" root/usr/bin/openclaw-env || fail "Node runtime must validate Unicode property escapes"
grep -q "uci -q set openclaw.main.enabled='1'" root/usr/share/openclaw/oc-config.sh || fail "traditional config restart must enable gateway after first install"
grep -q "uci -q set openclaw.main.enabled='1'" root/usr/share/openclaw/oc-config-interactive.js || fail "interactive config restart must enable gateway after first install"
if grep -q 'v1_tarball' root/usr/bin/openclaw-env; then
	fail "installer must not silently fall back to legacy Node.js tarball"
fi

grep -q "wechat.htm" Makefile || fail "Makefile must install wechat.htm"
grep -q "luci-app-openclaw.json" Makefile || fail "Makefile must install rpcd ACL"
grep -q "openclaw-permissions.sh" Makefile || fail "Makefile must install permission helper"
grep -q 'openclaw-permissions.sh fix-state "$${OC_DATA}/.openclaw"' Makefile || fail "postinst must repair existing OpenClaw state permissions after reinstall"
grep -q '/etc/init.d/openclaw start >/dev/null 2>&1' Makefile || fail "postinst must restart enabled OpenClaw service after reinstall"
grep -q 'openclaw-permissions.sh fix-state "${OC_DATA}/.openclaw"' scripts/build_ipk.sh || fail "release ipk postinst must repair existing OpenClaw state permissions after reinstall"
grep -q '/etc/init.d/openclaw start >/dev/null 2>&1' scripts/build_ipk.sh || fail "release ipk postinst must restart enabled OpenClaw service after reinstall"
if grep -q "openclaw.zh-cn.lmo" Makefile; then
	fail "main package must not install openclaw.zh-cn.lmo"
fi

if grep -q 'export HOME="$OC_DATA"' root/etc/profile.d/openclaw.sh; then
	fail "profile must not export HOME globally"
fi
grep -q 'HOME="$OC_DATA"' root/etc/profile.d/openclaw.sh || fail "openclaw wrapper must inject HOME locally"

if grep -q "chmod -R 777" luasrc/controller/openclaw.lua; then
	fail "uninstall path must not chmod -R 777"
fi
grep -q "is_safe_openclaw_root" luasrc/controller/openclaw.lua || fail "uninstall safety check missing"
grep -q "local q_install_path = shellquote(install_path)" luasrc/controller/openclaw.lua || fail "uninstall rm must shellquote install_path"
grep -q "rm -rf \" .. q_install_path" luasrc/controller/openclaw.lua || fail "uninstall rm must use quoted install_path"

grep -q "opkg install python3-light" luasrc/controller/openclaw.lua || fail "wechat install must auto install python3-light"
grep -q "ensure_openclaw_user" luasrc/controller/openclaw.lua || fail "wechat install must ensure openclaw user"
grep -q "NPM_CONFIG_CACHE" luasrc/controller/openclaw.lua || fail "wechat install must set npm cache"
grep -q "openclaw 用户无法写入微信登录目录" luasrc/controller/openclaw.lua || fail "wechat login writable preflight missing"
grep -q "node_modules/@tencent-weixin/openclaw-weixin" luasrc/controller/openclaw.lua || fail "wechat uninstall must remove npm project plugin"
grep -q "dropChannel(d.plugins.installs)" luasrc/controller/openclaw.lua || fail "wechat uninstall must clean plugin installs"
grep -q "openclaw-weixin" root/etc/init.d/openclaw || fail "weixin channel migration missing"
if grep -q "delete d.plugins.entries\\['openclaw-weixin'\\]" root/etc/init.d/openclaw; then
	fail "init must preserve the official plugins.entries enable record"
fi
grep -q "npm/projects" root/etc/init.d/openclaw || fail "npm plugin project ownership fix missing"
grep -q "! -path.*npm/projects" root/usr/libexec/openclaw-permissions.sh || fail "npm plugin projects should be excluded from generic ownership reset"
grep -q "_run_doctor_fix" root/etc/init.d/openclaw || fail "doctor --fix must run through the service-user wrapper"
grep -q "su -s /bin/sh openclaw -c" root/etc/init.d/openclaw || fail "doctor --fix must run as the openclaw service user (2026.7.x plugin ownership check)"
grep -q "oc_doctor_as_openclaw" root/usr/share/openclaw/oc-config.sh || fail "oc-config doctor must run as the openclaw service user"
grep -q "(-\[0-9]+)?" root/etc/init.d/openclaw || fail "doctor version marker must keep the patch suffix (e.g. 2026.7.1-2)"
grep -q "archived-extensions" root/etc/init.d/openclaw || fail "legacy weixin extension archive missing"
grep -q "find_wechat_plugin_dir" luasrc/controller/openclaw.lua || fail "wechat npm plugin detection missing"
grep -q "wechat_openclaw_plugin_install_cmd" luasrc/controller/openclaw.lua || fail "wechat install must use OpenClaw plugin installer"
grep -q "delete d.plugins.installs\\['openclaw-weixin'\\]" luasrc/controller/openclaw.lua || fail "wechat config must remove deprecated authored install records"
grep -q "plugins install --force --pin @tencent-weixin/openclaw-weixin@2.4.6" luasrc/controller/openclaw.lua || fail "wechat install must write the official plugin index"
grep -q "channels\\['openclaw-weixin'\\].enabled = true" luasrc/controller/openclaw.lua || fail "wechat channel enable registration missing"
grep -q "OpenClaw 插件索引注册完成" luasrc/controller/openclaw.lua || fail "wechat install log must confirm index registration"
grep -q "plugins enable openclaw-weixin" luasrc/controller/openclaw.lua || fail "wechat lifecycle must persist the official plugin enable entry"
grep -q "plugins registry --refresh" luasrc/controller/openclaw.lua || fail "wechat lifecycle must refresh the SQLite plugin registry after config changes"
grep -q "plugins inspect openclaw-weixin" luasrc/controller/openclaw.lua || fail "wechat lifecycle must verify the loaded plugin capability"
grep -q "SQLite 注册表已刷新并通过加载验证" luasrc/controller/openclaw.lua || fail "wechat success log must require registry verification"
grep -q "wechat_network_probe_cmd" luasrc/controller/openclaw.lua || fail "wechat network probe helper missing"
grep -q "NODE_ICU_DATA=%s/node/share/icu" luasrc/controller/openclaw.lua || fail "wechat LuCI CLI commands must export NODE_ICU_DATA"
grep -q "openclaw_user_runner_cmd" luasrc/controller/openclaw.lua || fail "wechat commands need user runner compatibility helper"
grep -q "ulimit -v unlimited" luasrc/controller/openclaw.lua || fail "wechat commands must lift LuCI inherited address-space limit before Node CLI"
grep -q "start-stop-daemon -S -m -p" luasrc/controller/openclaw.lua || fail "wechat commands must support OpenWrt without su"
grep -q "command -v curl" luasrc/controller/openclaw.lua || fail "wechat network probe should prefer curl"
grep -q "%%{http_code}" luasrc/controller/openclaw.lua || fail "wechat curl probe percent must be escaped for string.format"
if awk '/function action_wechat_install\(\)/,/function action_wechat_install_log\(\)/' luasrc/controller/openclaw.lua | grep -q "ensure_port_free"; then
	fail "wechat install must not stop gateway before plugin installation"
fi
if awk '/function action_wechat_upgrade_plugin\(\)/,/function action_wechat_uninstall_plugin\(\)/' luasrc/controller/openclaw.lua | grep -q "ensure_port_free"; then
	fail "wechat upgrade must not stop gateway before plugin upgrade"
fi
grep -q "export OC_WECHAT_DATA" luasrc/controller/openclaw.lua || fail "wechat installer must export data dir into openclaw user shell"
grep -q "compare_versions" luasrc/controller/openclaw.lua || fail "semantic version compare helper missing"
grep -q "is_newer_version(plugin_latest, plugin_current)" luasrc/controller/openclaw.lua || fail "plugin update check must not treat newer local versions as upgradeable"
grep -q "is_newer_version(latest_version, current_version)" luasrc/controller/openclaw.lua || fail "wechat update check must use semantic version compare"
grep -q "ilinkai.weixin.qq.com" luasrc/controller/openclaw.lua || fail "wechat network probe endpoint missing"
grep -q "微信接口连通性检查" luasrc/controller/openclaw.lua || fail "wechat network probe log missing"
grep -q "error_detail" luasrc/controller/openclaw.lua || fail "wechat login failure detail response missing"
grep -q "已将此 OpenClaw 连接到微信" luasrc/controller/openclaw.lua || fail "wechat login status must treat saved auth as success"
grep -q "Local login saved auth for openclaw%-weixin" luasrc/controller/openclaw.lua || fail "wechat login status must tolerate channels.start restart warning"
grep -q "/etc/init.d/openclaw restart_gateway >/dev/null 2>&1 &" luasrc/controller/openclaw.lua || fail "wechat login success should use lightweight gateway restart"
grep -q "self_heal_wechat_npm_plugin_config" root/etc/init.d/openclaw || fail "init.d wechat npm plugin self-heal missing"
grep -q "installed_plugin_index" root/etc/init.d/openclaw || fail "init.d wechat self-heal must support the SQLite plugin index"
grep -q "微信插件已迁移到 SQLite installed_plugin_index" root/etc/init.d/openclaw || fail "init.d wechat SQLite self-heal log missing"
grep -q "run_openclaw_cli_as_user" root/etc/init.d/openclaw || fail "init.d plugin registry operations must run as openclaw"
if grep -q "DatabaseSync" root/etc/init.d/openclaw; then
	fail "init.d must not access the SQLite plugin index as root"
fi
grep -q "plugins enable openclaw-weixin" root/etc/init.d/openclaw || fail "init.d must restore the official plugin enable entry"
grep -q "plugins registry --refresh" root/etc/init.d/openclaw || fail "init.d must refresh the plugin registry before gateway start"
grep -q "plugins inspect openclaw-weixin" root/etc/init.d/openclaw || fail "init.d must verify the wechat plugin before gateway start"
grep -q "微信插件 SQLite 注册表已刷新并通过加载验证" root/etc/init.d/openclaw || fail "init.d registry verification success log missing"
grep -q "微信插件注册状态已有效，跳过重复刷新" root/etc/init.d/openclaw || fail "init.d must avoid repeated registry rebuilds after successful repair"
grep -q "d.plugins.entries\['openclaw-weixin'\].enabled===true" root/etc/init.d/openclaw || fail "init.d fast path must require the official enable entry"
grep -q "openclaw-permissions.sh" root/etc/init.d/openclaw || fail "init.d must use permission helper"
grep -q "fix_openclaw_state_permissions" root/etc/init.d/openclaw || fail "init.d final permission helper call missing"
grep -q 'NODE_ICU_DATA=\\"${NODE_BASE}/share/icu\\"' root/etc/init.d/openclaw || fail "doctor migration must run with Node ICU data"
grep -q "Token 同步 (doctor 后): UCI -> JSON" root/etc/init.d/openclaw || fail "doctor must restore missing JSON token from UCI"
grep -q 'OPENCLAW_GATEWAY_TOKEN="$gw_token"' root/etc/init.d/openclaw || fail "gateway must receive token env fallback"
grep -q "clear_jiti_cache_on_start" root/etc/init.d/openclaw || fail "JITI cache cleanup must be opt-in to avoid slow startup"
grep -q "procd_set_param term_timeout 2" root/etc/init.d/openclaw || fail "procd term timeout must be bounded for faster restart"
grep -q "procd_set_param respawn 5 1 -1" root/etc/init.d/openclaw || fail "gateway respawn must avoid procd crash throttling during manual restart_gateway"
grep -q "openclaw-restart-gateway.lock" root/etc/init.d/openclaw || fail "restart_gateway must guard concurrent restart requests"
grep -q "kill -USR1" root/etc/init.d/openclaw || fail "restart_gateway must prefer OpenClaw SIGUSR1 in-process restart"
grep -q "SIGUSR1 请求 Gateway 快速重载" root/etc/init.d/openclaw || fail "restart_gateway SIGUSR1 fast reload log missing"
grep -q "patch_webchat_session_conflict" root/etc/init.d/openclaw || fail "WebChat session conflict patch helper missing"
grep -q 'ctx.Provider === "webchat"' root/etc/init.d/openclaw || fail "WebChat patch must skip terminal transcript rollover for webchat"
grep -q "let sessionEntryInput = params.sessionEntry" root/etc/init.d/openclaw || fail "WebChat patch must merge same-session stale guarded writes"
grep -q "WebChat 二次发送会话初始化冲突" root/etc/init.d/openclaw || fail "WebChat patch must run before gateway start"
grep -q 'openclaw.main.clear_jiti_cache_on_start' root/etc/init.d/openclaw || fail "JITI cleanup must be guarded by UCI flag"
grep -q "openclaw-node-compile-cache" root/etc/init.d/openclaw || fail "Node compile cache must be enabled for faster warm restarts"
grep -q 'NODE_COMPILE_CACHE="$node_compile_cache"' root/etc/init.d/openclaw || fail "gateway and pty must receive Node compile cache env"
grep -q "通常 20~40 秒" root/etc/init.d/openclaw luasrc/view/openclaw/status.htm luasrc/view/openclaw/console.htm || fail "startup hint must match measured OpenWrt timing"
grep -q "restart_gateway >/dev/null 2>&1 &" luasrc/controller/openclaw.lua || fail "LuCI restart action should use lightweight gateway restart"
grep -q "oc_fix_npm_projects_permissions" root/usr/libexec/openclaw-permissions.sh || fail "npm projects permission helper missing"
grep -q 'chown -R openclaw:openclaw "$npm_projects"' root/usr/libexec/openclaw-permissions.sh || fail "npm projects generation must be writable by openclaw"
if grep -q 'chown -R root:root.*npm_projects' root/usr/libexec/openclaw-permissions.sh; then
	fail "managed npm plugin generations must not be made root-owned"
fi
if grep -q 'chown -R openclaw:openclaw "$OC_DATA"' root/etc/init.d/openclaw root/usr/share/openclaw/oc-config.sh root/usr/share/openclaw/web-pty.js; then
	fail "must not recursively chown the whole OC_DATA to openclaw"
fi
if grep -q 'chown -R openclaw:openclaw "$OC_STATE_DIR"' root/usr/share/openclaw/oc-config.sh; then
	fail "must not recursively chown the whole OC_STATE_DIR to openclaw"
fi
if grep -q 'find "$OC_STATE_DIR" -user root ! -path "*/extensions*"' root/usr/share/openclaw/oc-config.sh root/usr/share/openclaw/oc-config-interactive.js; then
	fail "state permission reset must also exclude npm/projects and archived-extensions"
fi
grep -q "extractWechatLoginUrl" luasrc/view/openclaw/wechat.htm || fail "wechat page must filter login URLs"
grep -q "oc-error-detail" luasrc/view/openclaw/wechat.htm || fail "wechat page must show real login failure detail"
grep -q "点击打开链接，然后用微信扫码" luasrc/view/openclaw/wechat.htm || fail "wechat page must tell users to open link and scan with WeChat"
grep -q "@tencent-weixin/openclaw-weixin/openclaw.plugin.json" root/usr/share/openclaw/oc-config.sh || fail "oc-config wechat npm detection missing"
grep -q "fix_openclaw_state_permissions" root/usr/share/openclaw/oc-config.sh || fail "oc-config must use permission helper"
grep -q "fixStatePermissions" root/usr/share/openclaw/oc-config-interactive.js || fail "interactive config must use permission helper"
grep -q "fixStatePermissions" root/usr/share/openclaw/web-pty.js || fail "web pty must use permission helper"

grep -q "一万AI分享 粉丝专享 API" root/usr/share/openclaw/oc-config-interactive.js || fail "interactive menu missing Yiwan AI fan API"
grep -q "configureYiwanAIFanAPI" root/usr/share/openclaw/oc-config-interactive.js || fail "interactive Yiwan AI configure handler missing"
grep -q "yiwanai-fan" root/usr/share/openclaw/oc-config-interactive.js || fail "interactive Yiwan AI menu value missing"
grep -q "一万AI分享 粉丝专享 API" root/usr/share/openclaw/oc-config.sh || fail "shell menu missing Yiwan AI fan API"
grep -q "https://api.910501.xyz/v1" root/usr/share/openclaw/oc-config-interactive.js || fail "interactive Yiwan AI base URL missing"
grep -q "https://api.910501.xyz/v1" root/usr/share/openclaw/oc-config.sh || fail "shell Yiwan AI base URL missing"
grep -q "gpt-5.5" root/usr/share/openclaw/oc-config-interactive.js || fail "interactive Yiwan AI model missing"
grep -q "gpt-5.5" root/usr/share/openclaw/oc-config.sh || fail "shell Yiwan AI model missing"
grep -q "authSetApikey(providerName, apiKey,.*fan" root/usr/share/openclaw/oc-config-interactive.js || fail "interactive Yiwan AI auth profile missing"
grep -q 'auth_set_apikey yiwanai "$api_key" "yiwanai:fan"' root/usr/share/openclaw/oc-config.sh || fail "shell Yiwan AI auth profile missing"
grep -q "registerCustomProvider(providerName, baseUrl, apiKey, modelName, modelName, 1000000, 32000)" root/usr/share/openclaw/oc-config-interactive.js || fail "interactive Yiwan AI 1M context registration missing"
grep -q 'register_custom_provider yiwanai "https://api.910501.xyz/v1" "$api_key" "gpt-5.5" "gpt-5.5" 1000000 32000' root/usr/share/openclaw/oc-config.sh || fail "shell Yiwan AI 1M context registration missing"
grep -q 'registerAndSetModel(`${providerName}/${modelName}`)' root/usr/share/openclaw/oc-config-interactive.js || fail "interactive Yiwan AI active model missing"
grep -q "provider.models\[0\].reasoning = true" root/usr/share/openclaw/oc-config-interactive.js || fail "interactive Yiwan AI reasoning flag missing"
grep -q "p.models\[0\].reasoning=true" root/usr/share/openclaw/oc-config.sh || fail "shell Yiwan AI reasoning flag missing"
grep -q "yiwanai/gpt-5.5" root/usr/share/openclaw/oc-config.sh || fail "shell Yiwan AI active model missing"
grep -q "anthropic-compatible" root/usr/share/openclaw/oc-config.sh || fail "shell custom Anthropic provider missing"
grep -q "anthropic-messages" root/usr/share/openclaw/oc-config.sh || fail "shell custom Anthropic provider mode missing"

grep -q "var url = 'http://'" luasrc/view/openclaw/console.htm || fail "console must force HTTP gateway URL"
grep -q "新窗口打开" luasrc/view/openclaw/console.htm || fail "console must expose a new-window entry"
if grep -q "document.createElement('iframe')" luasrc/view/openclaw/console.htm; then
	fail "console must not embed OpenClaw in an iframe"
fi

grep -q "root/usr/libexec" scripts/build_ipk.sh || fail "ipk script must package shell helpers"
grep -q "root/usr/libexec" scripts/build_run.sh || fail "run script must package shell helpers"
grep -q "for dep in luci-compat luci-base curl openssl-util script-utils tar libstdcpp6" scripts/build_run.sh || fail ".run installer must install runtime dependencies"
grep -q -- "--owner=0 --group=0 --numeric-owner" scripts/build_run.sh || fail ".run payload must normalize file ownership to root"
grep -q -- "--owner=0 --group=0 --numeric-owner" scripts/build_ipk.sh || fail ".ipk payload must normalize file ownership to root"
grep -q "chown -R root:root" scripts/build_run.sh || fail ".run installer must repair root-owned system files after extraction"
grep -q "chown -R root:root" scripts/build_ipk.sh || fail ".ipk postinst must repair root-owned system files after extraction"
grep -q "先解压到临时目录并确认完整，再替换 NODE_BASE" root/usr/bin/openclaw-env || fail "Node install must not delete existing runtime before extraction succeeds"
grep -q "OC_SETUP_FRESH_ROOT" root/usr/bin/openclaw-env || fail "setup cleanup must preserve existing runtime roots"

echo "ok"
