#!/bin/sh
set -eu

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -q "OC_TESTED_VERSION=\"2026.6.1\"" root/usr/bin/openclaw-env || fail "tested OpenClaw version not pinned"
grep -q "NODE_VERSION_V2=\"22.19.0\"" root/usr/bin/openclaw-env || fail "default Node.js version not pinned"
grep -q "oc_assert_node_min_version" root/usr/bin/openclaw-env || fail "Node.js minimum version check missing"

grep -q "wechat.htm" Makefile || fail "Makefile must install wechat.htm"
grep -q "luci-app-openclaw.json" Makefile || fail "Makefile must install rpcd ACL"
if grep -q "openclaw.zh-cn.lmo" Makefile; then
	fail "main package must not install openclaw.zh-cn.lmo"
fi

grep -q 'export HOME="$OC_DATA"' root/usr/bin/openclaw || fail "openclaw wrapper must inject HOME locally"
grep -q 'exec /usr/bin/zsh -f' root/usr/bin/openclaw-shell || fail "temporary shell must use isolated zsh"
if grep -q 'profile.d/openclaw.sh' Makefile scripts/build_ipk.sh scripts/build_run.sh; then
	fail "package must not inject OpenClaw environment through profile.d"
fi
grep -q 'local target_pkg="openclaw@latest"' root/usr/bin/openclaw-env || fail "upgrade must target npm latest"

if grep -q "chmod -R 777" luasrc/controller/openclaw.lua; then
	fail "uninstall path must not chmod -R 777"
fi
grep -q "is_safe_openclaw_root" luasrc/controller/openclaw.lua || fail "uninstall safety check missing"
grep -q "local q_install_path = shellquote(install_path)" luasrc/controller/openclaw.lua || fail "uninstall rm must shellquote install_path"
grep -q "rm -rf \" .. q_install_path" luasrc/controller/openclaw.lua || fail "uninstall rm must use quoted install_path"

grep -q "openclaw-weixin-cli@latest install" luasrc/controller/openclaw.lua || fail "wechat install must use official Weixin latest CLI"
grep -q "ensure_openclaw_user" luasrc/controller/openclaw.lua || fail "wechat install must ensure openclaw user"
grep -q "npm/projects" luasrc/controller/openclaw.lua || fail "wechat install must support managed npm project path"
grep -q 'clearWeixinAccount' luasrc/controller/openclaw.lua || fail "wechat logout must clear plugin account state"
grep -q 'OC_ACCOUNT_ID' luasrc/controller/openclaw.lua || fail "wechat logout must pass the selected account id safely"
grep -q 'rc ~= 0 or remaining' luasrc/controller/openclaw.lua || fail "wechat logout must report cleanup failures"
grep -q 'ocLogoutWechatAccount.*this' luasrc/view/openclaw/wechat.htm || fail "wechat logout button must pass its button element"
grep -q "openclaw-weixin" root/etc/init.d/openclaw || fail "weixin channel migration missing"

grep -q "var url = 'http://'" luasrc/view/openclaw/console.htm || fail "console must force HTTP gateway URL"
grep -q "existing.src" luasrc/view/openclaw/console.htm || fail "console iframe must refresh token URL"
grep -q 'btn-refresh-status' luasrc/view/openclaw/wechat.htm || fail "wechat refresh button must expose visible refresh state"
grep -q 'addCacheBuster(wechatStatusUrl)' luasrc/view/openclaw/wechat.htm || fail "wechat refresh must bypass cached status responses"
grep -q 'markWechatStatusError' luasrc/view/openclaw/wechat.htm || fail "wechat refresh must show API failures"
grep -Fq 'control-ui-*.js' root/etc/init.d/openclaw || fail "iframe patch must cover current control-ui bundles"
if grep -Fq 'ALLOW-FROM *' root/etc/init.d/openclaw; then
	fail "iframe patch must remove X-Frame-Options instead of using unsupported ALLOW-FROM"
fi

grep -q "root/usr/libexec" scripts/build_ipk.sh || fail "ipk script must package shell helpers"
grep -q "root/usr/libexec" scripts/build_run.sh || fail "run script must package shell helpers"

echo "ok"
