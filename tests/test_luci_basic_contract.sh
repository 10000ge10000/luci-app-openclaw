#!/bin/sh
# LuCI 基本设置页面渲染与变量拼接契约测试。
# 覆盖:
#   1. service_ctl_url 与 ctl_url 变量定义完整性，避免 nil 拼接崩溃
#   2. XHR post 请求 URL 必须非空且有效
#   3. Lua 解释器环境下实际执行 act.cfgvalue() 渲染无报错
#   4. LF 换行符约束
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BASIC_MODEL="$REPO_ROOT/luasrc/model/cbi/openclaw/basic.lua"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

[ -f "$BASIC_MODEL" ] || fail "missing $BASIC_MODEL"

# ── 1. 变量定义完整性 ──
grep -Fq "local ctl_url =" "$BASIC_MODEL" || fail "basic.lua must define ctl_url"
grep -Fq "local service_ctl_url =" "$BASIC_MODEL" || fail "basic.lua must define service_ctl_url"
grep -Fq 'service_ctl_url' "$BASIC_MODEL" || fail "basic.lua must reference service_ctl_url"

# ── 2. Lua 运行时执行契约 ──
lua_bin=""
for cand in lua5.1 lua; do
	command -v "$cand" >/dev/null 2>&1 && { lua_bin="$cand"; break; }
done

if [ -n "$lua_bin" ]; then
	"$lua_bin" -e '
package.path = "./luasrc/?.lua;" .. package.path
_G.luci = {
  sys = { exec = function() return "" end },
  dispatcher = {
    build_url = function(...) return "/" .. table.concat({...}, "/") end,
    context = { authtoken = "dummy-csrf-token" }
  }
}
package.loaded["luci.sys"] = _G.luci.sys
package.loaded["luci.dispatcher"] = _G.luci.dispatcher
_G.Map = function(...)
  return {
    section = function(...)
      return {
        option = function(self, opt, name)
          local o = {}
          if name == "_actions" then _G.act = o end
          return o
        end
      }
    end
  }
end
_G.SimpleSection = {}
_G.DummyValue = {}

dofile("'"$BASIC_MODEL"'")

if not _G.act or type(_G.act.cfgvalue) ~= "function" then
  error("act.cfgvalue function not exported")
end

local rendered = _G.act.cfgvalue({}, {})
if type(rendered) ~= "string" or #rendered < 1000 then
  error("cfgvalue rendered content too short or invalid type: " .. type(rendered))
end

if not rendered:find("/admin/services/openclaw/service_ctl") then
  error("rendered output missing service_ctl endpoint URL")
end

if rendered:find("post%(\"\",") or rendered:find("post%(undefined,") or rendered:find("post%(null,") then
  error("rendered output has empty or undefined XHR post URL")
end
' || fail "basic.lua failed to execute or render cleanly in Lua"
fi

# ── 3. 换行符约束 (LF only) ──
cr=$(printf '\r')
if LC_ALL=C grep -q "$cr" "$BASIC_MODEL"; then
	fail "$(basename "$BASIC_MODEL") must use LF line endings"
fi

echo "ok"
