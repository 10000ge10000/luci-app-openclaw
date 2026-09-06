#!/bin/sh
# 模型清单架构契约。
#
# 背景: 两侧实现各自硬编码了一大堆 provider/model ID，且已严重腐坏。
# 实测这些 ID 在 OpenClaw 2026.7.1-2 的 catalog 中已不存在:
#   openai/gpt-5.2、gpt-5-mini、gpt-4.1、o3、o4-mini
#   anthropic/claude-sonnet-4-20250514、claude-opus-4-20250514、claude-sonnet-4.5
#   xai/grok-4、grok-3、deepseek/deepseek-r1、meta-llama/llama-4-maverick
#   01-ai/Yi-1.5-34B-Chat-16K、Qwen/Qwen2.5-*、THUDM/glm-4-9b-chat
#
# 现改为三层架构:
#   1. 精选预设 model-presets.json (shell 与 JS 共读的唯一数据源)
#   2. 动态发现 openclaw models list --provider <id> --plain (带超时, 失败回落)
#   3. 手动输入 (永久保留的兼容出口)
#
# 本测试锁定该架构不被回退成硬编码。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SH_CONFIG="$REPO_ROOT/root/usr/share/openclaw/oc-config.sh"
JS_CONFIG="$REPO_ROOT/root/usr/share/openclaw/oc-config-interactive.js"
PRESETS="$REPO_ROOT/root/usr/share/openclaw/model-presets.json"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

[ -f "$SH_CONFIG" ] || fail "missing $SH_CONFIG"
[ -f "$JS_CONFIG" ] || fail "missing $JS_CONFIG"
[ -f "$PRESETS" ] || fail "missing shared preset file $PRESETS"

# ── 两侧必须共读同一份预设，而不是各自维护列表 ──
grep -Fq 'model-presets.json' "$SH_CONFIG" || fail "shell side must read the shared preset file"
grep -Fq 'model-presets.json' "$JS_CONFIG" || fail "interactive side must read the shared preset file"

# ── 三层机制的关键函数必须存在 ──
grep -Fq 'oc_preset_models()' "$SH_CONFIG" || fail "shell needs a preset reader"
grep -Fq 'oc_discover_models()' "$SH_CONFIG" || fail "shell needs dynamic discovery"
grep -Fq 'oc_pick_model()' "$SH_CONFIG" || fail "shell needs a unified model picker"
grep -Fq 'function loadModelPresets' "$JS_CONFIG" || fail "interactive needs a preset reader"
grep -Fq 'function discoverProviderModels' "$JS_CONFIG" || fail "interactive needs dynamic discovery"
grep -Fq 'function selectProviderModel' "$JS_CONFIG" || fail "interactive needs a unified model picker"

# 动态发现必须按 provider 查询: 上游的 models list --all 不是各 provider 的超集
grep -Fq -- '--provider' "$SH_CONFIG" || fail "discovery must query per provider"
grep -Fq "'--provider'" "$JS_CONFIG" || fail "discovery must query per provider"

# 动态发现必须带超时: OpenWrt 上不能让菜单卡死
grep -Fq 'OC_MODEL_DISCOVERY_TIMEOUT' "$SH_CONFIG" || fail "shell discovery must be bounded by a timeout"
grep -Fq 'MODEL_DISCOVERY_TIMEOUT_MS' "$JS_CONFIG" || fail "interactive discovery must be bounded by a timeout"

# 手动输入出口必须保留
grep -Fq '手动输入模型 ID' "$SH_CONFIG" || fail "shell must keep a manual model entry"
grep -Fq '__custom__' "$JS_CONFIG" || fail "interactive must keep a manual model entry"

# ── 已确认在上游不存在的 ID 不得再出现在可选菜单里 ──
# 允许出现在注释中 (记录为何废弃)，因此这里排除注释行。
STALE_IDS="gpt-5-mini gpt-5-nano claude-sonnet-4-20250514 claude-opus-4-20250514 claude-sonnet-4.5 grok-4-fast grok-3-mini deepseek-r1 llama-4-maverick Yi-1.5-34B-Chat-16K Qwen2.5-72B-Instruct glm-4-9b-chat ernie-3.5-8k ernie-speed-8k"
for id in $STALE_IDS; do
	# shell: 排除以 # 开头的注释行
	if grep -F -- "$id" "$SH_CONFIG" | grep -v '^[[:space:]]*#' | grep -q .; then
		fail "oc-config.sh still offers stale model id: $id"
	fi
	# js: 排除 // 与 * 开头的注释行
	if grep -F -- "$id" "$JS_CONFIG" | grep -v '^[[:space:]]*//' | grep -v '^[[:space:]]*\*' | grep -q .; then
		fail "oc-config-interactive.js still offers stale model id: $id"
	fi
done

# ── 菜单项模型简化契约：顶级模型提供商菜单不得罗列过时具体模型名称 ──
for name in "GPT-5.2" "GPT-4.1" "GPT-5 mini" "Sonnet 4" "Opus 4" "Gemini 2.5" "Gemini 3" "Grok-4" "HY T1" "ERNIE-4.0" "GLM-5.1"; do
	if grep -F -- "$name" "$SH_CONFIG" | grep -v '^[[:space:]]*#' | grep -q .; then
		fail "oc-config.sh model menu still lists stale model name: $name"
	fi
	if grep -F -- "$name" "$JS_CONFIG" | grep -v '^[[:space:]]*//' | grep -v '^[[:space:]]*\*' | grep -q .; then
		fail "oc-config-interactive.js model menu still lists stale model name: $name"
	fi
done

# ── 预设文件自身校验 (需要 node) ──
NODE_BIN=""
for cand in node nodejs /opt/openclaw/node/bin/node; do
	if command -v "$cand" >/dev/null 2>&1; then NODE_BIN=$(command -v "$cand"); break; fi
	[ -x "$cand" ] && { NODE_BIN="$cand"; break; }
done
if [ -z "$NODE_BIN" ]; then
	echo "ok (static only: no node interpreter available)"
	exit 0
fi

"$NODE_BIN" -e '
const fs = require("fs");
const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const errs = [];

if (!j.providers || typeof j.providers !== "object") errs.push("missing providers map");
if (!j.verified || !j.verified.date || !j.verified.openclawVersion) {
  errs.push("missing verified metadata (date + openclawVersion)");
}

const stale = [
  "gpt-5.2", "gpt-5-mini", "gpt-5-nano", "gpt-4.1", "gpt-4o", "o3", "o4-mini",
  "claude-sonnet-4-20250514", "claude-opus-4-20250514", "claude-sonnet-4.5",
  "grok-4", "grok-3", "deepseek-r1", "glm-4.5",
];

for (const [id, p] of Object.entries(j.providers || {})) {
  if (!p.label) errs.push(id + ": missing label");
  if (!["builtin", "plugin"].includes(p.catalogSource)) {
    errs.push(id + ": catalogSource must be builtin or plugin");
  }
  if (!Array.isArray(p.models) || p.models.length === 0) {
    errs.push(id + ": needs at least one preset model");
    continue;
  }
  const seen = new Set();
  for (const m of p.models) {
    if (!m.model) { errs.push(id + ": preset entry missing model id"); continue; }
    // 预设必须是裸模型 ID, 不带 provider 前缀 (openrouter 的上游前缀除外)
    if (id !== "openrouter" && m.model.startsWith(id + "/")) {
      errs.push(id + "/" + m.model + ": preset must not repeat the provider prefix");
    }
    if (seen.has(m.model)) errs.push(id + ": duplicate preset " + m.model);
    seen.add(m.model);
    if (stale.includes(m.model)) {
      errs.push(id + ": preset uses a model id confirmed absent upstream: " + m.model);
    }
  }
}

if (errs.length) { console.error(errs.join("\n")); process.exit(1); }
' "$PRESETS" || fail "model-presets.json failed validation"

echo "ok"
