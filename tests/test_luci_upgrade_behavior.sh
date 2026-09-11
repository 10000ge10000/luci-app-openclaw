#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BASIC_MODEL="$REPO_ROOT/luasrc/model/cbi/openclaw/basic.lua"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
RENDERED="$TMP_DIR/basic.html"

lua_bin=""
for cand in lua5.1 lua; do
	command -v "$cand" >/dev/null 2>&1 && { lua_bin="$cand"; break; }
done
[ -n "$lua_bin" ] || { echo "SKIP: Lua interpreter unavailable"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: Node.js unavailable"; exit 0; }

"$lua_bin" - "$BASIC_MODEL" > "$RENDERED" <<'LUA'
local model = arg[1]
_G.luci = {
  sys = { exec = function() return "" end },
  dispatcher = {
    build_url = function(...) return "/" .. table.concat({...}, "/") end,
    context = { authtoken = "dummy-csrf-token" }
  }
}
package.loaded["luci.sys"] = _G.luci.sys
package.loaded["luci.dispatcher"] = _G.luci.dispatcher
_G.Map = function()
  return { section = function()
    return { option = function(_, _, name)
      local option = {}
      if name == "_actions" then _G.act = option end
      return option
    end }
  end }
end
_G.SimpleSection = {}
_G.DummyValue = {}
dofile(model)
io.write(assert(_G.act.cfgvalue({}, {})))
LUA

node - "$RENDERED" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/gi)].map((m) => m[1]);
if (!scripts.length) throw new Error('rendered CBI page has no script');

const elements = new Map();
function element(id) {
  if (!elements.has(id)) elements.set(id, {
    id, disabled: false, textContent: '', innerHTML: '', style: {},
    scrollHeight: 0, scrollTop: 0, clientHeight: 0,
    addEventListener() {}, getAttribute() { return ''; }
  });
  return elements.get(id);
}

let postCallback = null;
let getCallback = null;
let intervals = [];
function XHR() {}
XHR.prototype.post = function(url, data, callback) { postCallback = callback; };
XHR.prototype.get = function(url, data, callback) { getCallback = callback; };

const sandbox = {
  console: { log() {} },
  window: { _coreLatestVer: '2026.9.1', _pluginLatestVer: '2.2.2' },
  document: {
    getElementById: element,
    getElementsByName() { return []; }
  },
  XHR,
  confirm() { return true; },
  alert() {},
  location: { reload() {} },
  encodeURIComponent,
  JSON,
  setInterval(fn) { intervals.push(fn); return intervals.length; },
  clearInterval() {},
  setTimeout() { return 1; },
  clearTimeout() {}
};
vm.createContext(sandbox);
for (const script of scripts) vm.runInContext(script, sandbox);

sandbox.ocOpenclawCoreUpgrade();
if (typeof postCallback !== 'function') throw new Error('core upgrade did not issue POST');
postCallback({ status: 403, responseText: '{"status":"error","message":"forbidden"}' });
if (intervals.length !== 0) throw new Error('HTTP 403 incorrectly started polling');
if (element('btn-core-upgrade').disabled) throw new Error('HTTP 403 did not restore core upgrade button');

postCallback = null;
sandbox.ocOpenclawCoreUpgrade();
postCallback({ status: 200, responseText: '{"status":"ok"}' });
if (intervals.length !== 1) throw new Error('accepted core upgrade did not start polling');
for (let i = 0; i < 3; i++) {
  intervals[0]();
  if (typeof getCallback !== 'function') throw new Error('poll did not issue GET');
  getCallback({ status: 200, responseText: 'not-json' });
}
if (element('btn-core-upgrade').disabled) throw new Error('three poll errors did not restore core button');
if (!element('setup-log-status').textContent.includes('后台任务可能仍在运行')) throw new Error('unknown-state warning missing');

postCallback = null;
sandbox.ocPluginUpgrade();
if (typeof postCallback !== 'function') throw new Error('plugin upgrade did not issue POST');
postCallback({ status: 500, responseText: '{"status":"error","message":"failed"}' });
if (element('btn-plugin-upgrade').disabled) throw new Error('plugin HTTP failure did not restore button');

console.log('ok');
NODE
