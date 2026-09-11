package.path = "./luasrc/?.lua;./luasrc/?/?.lua;" .. package.path

local console = require "openclaw.console"

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
	end
end

assert_equal(console.normalize_https_url(" https://console.example.com/chat/ "), "https://console.example.com/chat", "valid HTTPS URL")
assert_equal(console.normalize_https_url("http://console.example.com"), nil, "HTTP must be rejected")
assert_equal(console.normalize_https_url("https://user@example.com"), nil, "userinfo must be rejected")
assert_equal(console.normalize_https_url("https://example.com/a'b"), nil, "single quote must be rejected")
assert_equal(console.normalize_https_url('https://example.com/a"b'), nil, "double quote must be rejected")
assert_equal(console.normalize_https_url("https://example.com/</script>"), nil, "script delimiter must be rejected")
assert_equal(console.normalize_https_url("https://example.com:70000"), nil, "invalid port must be rejected")
assert_equal(console.normalize_https_url("https://[fd00::1]:8443/ui"), "https://[fd00::1]:8443/ui", "IPv6 URL")
assert_equal(console.html_attr([[&<>"']]), "&amp;&lt;&gt;&quot;&#39;", "HTML attribute escaping")

print("ok")
