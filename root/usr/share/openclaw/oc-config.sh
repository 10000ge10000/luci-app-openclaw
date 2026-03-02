#!/bin/sh
# ============================================================================
# OpenClaw 配置管理工具 — OpenWrt 适配版
# 基于原始 oc-config.sh 移植，适配 ash/busybox 环境
# ============================================================================

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── 端口检查兼容函数 (ss 或 netstat) ──
# check_port_listening <port> — 检查端口是否在监听，返回 0/1
check_port_listening() {
	local p="$1"
	if command -v ss >/dev/null 2>&1; then
		ss -ltn 2>/dev/null | grep -q ":${p} "
	else
		netstat -tln 2>/dev/null | grep -q ":${p} "
	fi
}
# get_pid_by_port <port> — 获取监听指定端口的进程 PID
get_pid_by_port() {
	local p="$1"
	if command -v ss >/dev/null 2>&1; then
		ss -tlnp 2>/dev/null | grep ":${p} " | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1
	else
		netstat -tlnp 2>/dev/null | grep ":${p} " | sed -n 's|.* \([0-9]*\)/.*|\1|p' | head -1
	fi
}

# ── 路径 (OpenWrt 适配) ──
NODE_BASE="${NODE_BASE:-/opt/openclaw/node}"
OC_GLOBAL="${OC_GLOBAL:-/opt/openclaw/global}"
OC_DATA="${OC_DATA:-/opt/openclaw/data}"
NODE_BIN="${NODE_BASE}/bin/node"
OC_STATE_DIR="${OC_DATA}/.openclaw"
CONFIG_FILE="${OC_STATE_DIR}/openclaw.json"

export HOME="$OC_DATA"
export OPENCLAW_HOME="$OC_DATA"
export OPENCLAW_STATE_DIR="$OC_STATE_DIR"
export OPENCLAW_CONFIG_PATH="$CONFIG_FILE"
export PATH="${NODE_BASE}/bin:${OC_GLOBAL}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ── 查找 openclaw 入口 ──
OC_PKG_DIR=""
for d in "${OC_GLOBAL}/lib/node_modules/openclaw" "${OC_GLOBAL}/node_modules/openclaw" "${NODE_BASE}/lib/node_modules/openclaw"; do
	if [ -d "$d" ]; then
		OC_PKG_DIR="$d"
		break
	fi
done

OC_ENTRY=""
if [ -n "$OC_PKG_DIR" ]; then
	if [ -f "${OC_PKG_DIR}/openclaw.mjs" ]; then
		OC_ENTRY="${OC_PKG_DIR}/openclaw.mjs"
	elif [ -f "${OC_PKG_DIR}/dist/cli.js" ]; then
		OC_ENTRY="${OC_PKG_DIR}/dist/cli.js"
	fi
fi

oc_cmd() {
	if [ -n "$OC_ENTRY" ] && [ -x "$NODE_BIN" ]; then
		"$NODE_BIN" "$OC_ENTRY" "$@" 2>&1
		local rc=$?
		# 修复权限: oc_cmd 以 root 运行但配置文件应属于 openclaw 用户
		chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
		chown openclaw:openclaw "${CONFIG_FILE}.bak" 2>/dev/null || true
		return $rc
	else
		echo "ERROR: OpenClaw 未安装或 Node.js 不可用"
		return 1
	fi
}

# ── JSON 读写 (使用 Node.js) ──
json_get() {
	if [ ! -f "$CONFIG_FILE" ]; then echo ""; return; fi
	_JS_KEY="$1" "$NODE_BIN" -e "
		const fs=require('fs');
		try{
			const d=JSON.parse(fs.readFileSync('${CONFIG_FILE}','utf8'));
			const ks=process.env._JS_KEY.split('.');let v=d;
			for(const k of ks){v=v[k];if(v===undefined){console.log('');process.exit(0);}}
			if(typeof v==='object')console.log(JSON.stringify(v));else console.log(v);
		}catch(e){console.log('');}
	" 2>/dev/null
}

json_set() {
	local key="$1" value="$2"
	if [ ! -f "$CONFIG_FILE" ]; then
		mkdir -p "$(dirname "$CONFIG_FILE")"
		echo '{}' > "$CONFIG_FILE"
	fi
	_JS_KEY="$key" _JS_VAL="$value" "$NODE_BIN" -e "
		const fs=require('fs');let d={};
		try{d=JSON.parse(fs.readFileSync('${CONFIG_FILE}','utf8'));}catch(e){}
		const ks=process.env._JS_KEY.split('.');let o=d;
		for(let i=0;i<ks.length-1;i++){if(!o[ks[i]]||typeof o[ks[i]]!=='object')o[ks[i]]={};o=o[ks[i]];}
		let v=process.env._JS_VAL;try{v=JSON.parse(v);}catch(e){}
		o[ks[ks.length-1]]=v;
		fs.writeFileSync('${CONFIG_FILE}',JSON.stringify(d,null,2));
	" 2>/dev/null
}

# ── 启用 auth 插件 ──
enable_auth_plugins() {
	[ ! -f "$CONFIG_FILE" ] && return
	"$NODE_BIN" -e "
		const fs=require('fs');
		try{
			const d=JSON.parse(fs.readFileSync('${CONFIG_FILE}','utf8'));
			if(!d.plugins)d.plugins={};if(!d.plugins.entries)d.plugins.entries={};
			const e=d.plugins.entries;
			['qwen-portal-auth','copilot-proxy','google-gemini-cli-auth','minimax-portal-auth'].forEach(p=>{
				if(!e[p])e[p]={};e[p].enabled=true;
			});
			delete e['google-antigravity-auth'];
			fs.writeFileSync('${CONFIG_FILE}',JSON.stringify(d,null,2));
		}catch(e){}
	" 2>/dev/null
}

# ── 辅助函数 ──

# 清理输入: 去除 ANSI 转义序列、不可见字符，只保留 ASCII 可打印字符
sanitize_input() {
	# 1) tr -cd ' -~' : 只保留 ASCII 0x20-0x7E (去除 ESC/控制字符/Unicode 不可见字符)
	# 2) sed : 去除 ESC 被剥离后残余的 CSI 序列 (如 bracketed paste 的 [200~ [201~)
	# 3) sed : 去除首尾空白
	printf '%s' "$1" | tr -cd ' -~' | sed 's/\[[0-9;]*[a-zA-Z~]//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

prompt_with_default() {
	local prompt="$1" default="$2" varname="$3"
	if [ -n "$default" ]; then
		printf "  ${CYAN}${prompt} [${default}]:${NC} " >&2
	else
		printf "  ${CYAN}${prompt}:${NC} " >&2
	fi
	read input
	input=$(sanitize_input "$input")
	local _result="${input:-$default}"
	export "__prompt_result__=$_result"
	eval "$varname=\"\$__prompt_result__\""
	unset __prompt_result__
}

confirm_yes() {
	local ans="$1"
	case "$ans" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

restart_gateway() {
	echo ""
	echo -e "  ${YELLOW}正在重启 Gateway...${NC}"

	# 修复数据目录权限 (root 用户操作可能改变了文件属主)
	chown -R openclaw:openclaw "$OC_DATA" 2>/dev/null || true

	local port
	port=$(json_get gateway.port)
	port=${port:-18789}

	# ── 使用 init.d restart_gateway: 只重启 Gateway 实例，不影响 PTY 终端 ──
	# 发 SIGTERM 给 gateway 进程，procd 自动 respawn，避免 crash loop 计数累积
	/etc/init.d/openclaw restart_gateway >/dev/null 2>&1

	# ── 等待端口监听，最多 45 秒 (Node.js 冷启动需要 10-15 秒) ──
	echo -e "  ${YELLOW}⏳ Gateway 启动中，请稍候...${NC}"
	local waited=0
	while [ $waited -lt 45 ]; do
		sleep 2
		waited=$((waited + 2))
		if check_port_listening "$port"; then
			echo -e "  ${GREEN}✅ Gateway 已重启成功${NC}"
			return 0
		fi
	done

	# ── 超时仍未就绪: 可能是 procd crash loop 保护触发，用 start 解除 ──
	echo -e "  ${YELLOW}⏳ 正在尝试再次启动...${NC}"
	/etc/init.d/openclaw start >/dev/null 2>&1 &
	waited=0
	while [ $waited -lt 20 ]; do
		sleep 2
		waited=$((waited + 2))
		if check_port_listening "$port"; then
			echo -e "  ${GREEN}✅ Gateway 已重启成功${NC}"
			return 0
		fi
	done

	echo -e "  ${RED}❌ Gateway 可能未正常启动${NC}"
	echo -e "  ${CYAN}   查看日志: logread -e openclaw${NC}"
}

ask_restart() {
	prompt_with_default "是否立即重启 Gateway? (y/n)" "y" do_restart
	confirm_yes "$do_restart" && restart_gateway
}

# ── 查看当前配置 ──
show_current_config() {
	echo ""
	echo -e "${GREEN}┌──────────────────────────────────────────────────────────┐${NC}"
	echo -e "${GREEN}│${NC}  📋 ${BOLD}当前配置概览${NC}"
	echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"

	local port=$(json_get gateway.port)
	local bind=$(json_get gateway.bind)
	local mode=$(json_get gateway.mode)
	echo -e "${GREEN}│${NC}  网关端口 ............ ${CYAN}${port:-18789}${NC}"
	echo -e "${GREEN}│${NC}  绑定模式 ............ ${CYAN}${bind:-lan}${NC}"
	echo -e "${GREEN}│${NC}  运行模式 ............ ${CYAN}${mode:-local}${NC}"

	local model=$(json_get agents.defaults.model.primary)
	if [ -n "$model" ]; then
		echo -e "${GREEN}│${NC}  活跃模型 ............ ${CYAN}${model}${NC}"
	else
		echo -e "${GREEN}│${NC}  活跃模型 ............ ${YELLOW}未配置${NC}"
	fi

	echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"
	echo -e "${GREEN}│${NC}  ${BOLD}渠道配置状态${NC}"

	local tg_token=$(json_get channels.telegram.botToken)
	local dc_token=$(json_get channels.discord.botToken)
	local fs_appid=$(json_get channels.feishu.appId)
	local sk_token=$(json_get channels.slack.botToken)

	if [ -n "$tg_token" ]; then
		local tg_short=$(echo "$tg_token" | cut -c1-12)
		echo -e "${GREEN}│${NC}  Telegram ............ ${GREEN}✅ 已配置${NC} (${tg_short}...)"
	else
		echo -e "${GREEN}│${NC}  Telegram ............ ${YELLOW}❌ 未配置${NC}"
	fi
	if [ -n "$dc_token" ]; then
		echo -e "${GREEN}│${NC}  Discord ............. ${GREEN}✅ 已配置${NC}"
	else
		echo -e "${GREEN}│${NC}  Discord ............. ${YELLOW}❌ 未配置${NC}"
	fi
	if [ -n "$fs_appid" ]; then
		local fs_short=$(echo "$fs_appid" | cut -c1-6)
		echo -e "${GREEN}│${NC}  飞书 ................ ${GREEN}✅ 已配置${NC} (AppID: ${fs_short}...)"
	else
		echo -e "${GREEN}│${NC}  飞书 ................ ${YELLOW}❌ 未配置${NC}"
	fi
	if [ -n "$sk_token" ]; then
		echo -e "${GREEN}│${NC}  Slack ............... ${GREEN}✅ 已配置${NC}"
	else
		echo -e "${GREEN}│${NC}  Slack ............... ${YELLOW}❌ 未配置${NC}"
	fi

	echo -e "${GREEN}└──────────────────────────────────────────────────────────┘${NC}"

	echo ""
	echo -e "  ${BOLD}系统信息:${NC}"
	echo -e "  Node.js: $("$NODE_BIN" -v 2>/dev/null || echo '未安装')"
	if [ -n "$OC_ENTRY" ]; then
		echo -e "  OpenClaw: $(oc_cmd --version 2>/dev/null || echo '未知')"
	else
		echo -e "  OpenClaw: 未安装"
	fi
	echo -e "  架构: $(uname -m)"
	local mem_total=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "?")
	echo -e "  内存: ${mem_total} MB"
}

# ══════════════════════════════════════════════════════════════
# 配置 AI 模型
# ══════════════════════════════════════════════════════════════
configure_model() {
	echo ""
	echo -e "  ${BOLD}🤖 配置 AI 模型提供商${NC}"
	echo ""
	echo -e "  ${GREEN}${BOLD}--- 推荐 ---${NC}"
	echo -e "  ${CYAN}1)${NC} 🌟 官方完整模型配置向导  ${GREEN}(推荐，支持所有提供商)${NC}"
	echo ""
	echo -e "  ${BOLD}--- 快速配置 ---${NC}"
	echo -e "  ${CYAN}2)${NC} OpenAI (GPT-5.2, GPT-5 mini, GPT-4.1)"
	echo -e "  ${CYAN}3)${NC} Anthropic (Claude Sonnet 4, Opus 4, Haiku)"
	echo -e "  ${CYAN}4)${NC} Google Gemini (Gemini 2.5 Pro/Flash, Gemini 3)"
	echo -e "  ${CYAN}5)${NC} OpenRouter (聚合多家模型)"
	echo -e "  ${CYAN}6)${NC} DeepSeek (DeepSeek-V3/R1)"
	echo -e "  ${CYAN}7)${NC} GitHub Copilot (需要 Copilot 订阅)"
	echo -e "  ${CYAN}8)${NC} 阿里云通义千问 Qwen (Portal/API)"
	echo -e "  ${CYAN}9)${NC} xAI Grok (Grok-3/3-mini)"
	echo -e "  ${CYAN}10)${NC} Groq (Llama 4, Llama 3.3)"
	echo -e "  ${CYAN}11)${NC} 硅基流动 SiliconFlow"
	echo -e "  ${CYAN}12)${NC} 自定义 OpenAI 兼容 API"
	echo -e "  ${CYAN}0)${NC} 返回"
	echo ""
	prompt_with_default "请选择" "1" choice

	case "$choice" in
		1)
			echo ""
			echo -e "  ${CYAN}启动官方完整模型配置向导...${NC}"
			echo -e "  ${YELLOW}提示: ↑↓ 移动, Tab/空格 选中, 回车 确认${NC}"
			echo ""
			echo -e "  ${CYAN}预启用模型认证插件...${NC}"
			enable_auth_plugins
			echo ""
			# 检查并安装 gemini-cli (官方向导的 Google Gemini OAuth 依赖)
			if ! command -v gemini >/dev/null 2>&1; then
				local npm_bin="${NODE_BASE}/bin/npm"
				if [ -x "$npm_bin" ]; then
					echo -e "  ${CYAN}安装 Gemini CLI (官方向导 Google OAuth 依赖)...${NC}"
					"$npm_bin" install -g @google/gemini-cli --prefix="$OC_GLOBAL" >/dev/null 2>&1 || true
				fi
			fi
			(oc_cmd configure --section model) || echo -e "  ${YELLOW}配置向导已退出${NC}"
			echo ""
			ask_restart
			;;
		2)
			echo ""
			echo -e "  ${BOLD}OpenAI 配置${NC}"
			echo -e "  ${YELLOW}获取 API Key: https://platform.openai.com/api-keys${NC}"
			echo ""
			prompt_with_default "请输入 OpenAI API Key (sk-...)" "" api_key
			if [ -n "$api_key" ]; then
				json_set models.openai.apiKey "$api_key"
				echo ""
				echo -e "  ${CYAN}可用模型:${NC}"
				echo -e "    ${CYAN}a)${NC} gpt-5.2       — 最强编程与代理旗舰 (推荐)"
				echo -e "    ${CYAN}b)${NC} gpt-5-mini    — 高性价比推理"
				echo -e "    ${CYAN}c)${NC} gpt-5-nano    — 极速低成本"
				echo -e "    ${CYAN}d)${NC} gpt-4.1       — 最强非推理模型"
				echo -e "    ${CYAN}e)${NC} o3            — 推理模型"
				echo -e "    ${CYAN}f)${NC} o4-mini       — 推理轻量"
				echo -e "    ${CYAN}g)${NC} 手动输入模型名"
				echo ""
				prompt_with_default "请选择模型" "a" model_choice
				case "$model_choice" in
					a) model_name="gpt-5.2" ;;
					b) model_name="gpt-5-mini" ;;
					c) model_name="gpt-5-nano" ;;
					d) model_name="gpt-4.1" ;;
					e) model_name="o3" ;;
					f) model_name="o4-mini" ;;
					g) prompt_with_default "请输入模型名称" "gpt-5.2" model_name ;;
					*) model_name="gpt-5.2" ;;
				esac
				json_set agents.defaults.model.primary "$model_name"
				echo -e "  ${GREEN}✅ OpenAI 已配置，活跃模型: ${model_name}${NC}"
			fi
			;;
		3)
			echo ""
			echo -e "  ${BOLD}Anthropic 配置${NC}"
			echo -e "  ${YELLOW}获取 API Key: https://console.anthropic.com/settings/keys${NC}"
			echo ""
			prompt_with_default "请输入 Anthropic API Key (sk-ant-...)" "" api_key
			if [ -n "$api_key" ]; then
				json_set models.anthropic.apiKey "$api_key"
				echo ""
				echo -e "  ${CYAN}可用模型:${NC}"
				echo -e "    ${CYAN}a)${NC} claude-sonnet-4-20250514   — Claude Sonnet 4 (推荐)"
				echo -e "    ${CYAN}b)${NC} claude-opus-4-20250514     — Claude Opus 4 顶级推理"
				echo -e "    ${CYAN}c)${NC} claude-haiku-4-20250514    — Claude Haiku 4 轻量快速"
				echo -e "    ${CYAN}d)${NC} 手动输入模型名"
				echo ""
				prompt_with_default "请选择模型" "a" model_choice
				case "$model_choice" in
					a) model_name="claude-sonnet-4-20250514" ;;
					b) model_name="claude-opus-4-20250514" ;;
					c) model_name="claude-haiku-4-20250514" ;;
					d) prompt_with_default "请输入模型名称" "claude-sonnet-4-20250514" model_name ;;
					*) model_name="claude-sonnet-4-20250514" ;;
				esac
				json_set agents.defaults.model.primary "$model_name"
				echo -e "  ${GREEN}✅ Anthropic 已配置，活跃模型: ${model_name}${NC}"
			fi
			;;
		4)
			echo ""
			echo -e "  ${BOLD}Google Gemini 配置${NC}"
			echo -e "  ${YELLOW}获取 API Key: https://aistudio.google.com/apikey${NC}"
			echo ""
			prompt_with_default "请输入 Google AI API Key" "" api_key
			if [ -n "$api_key" ]; then
				json_set models.google.apiKey "$api_key"
				echo ""
				echo -e "  ${CYAN}可用模型:${NC}"
				echo -e "    ${CYAN}a)${NC} gemini-2.5-pro       — 旗舰推理 (推荐)"
				echo -e "    ${CYAN}b)${NC} gemini-2.5-flash     — 快速均衡"
				echo -e "    ${CYAN}c)${NC} gemini-2.5-flash-lite — 极速低成本"
				echo -e "    ${CYAN}d)${NC} gemini-3-flash       — Gemini 3 预览版"
				echo -e "    ${CYAN}e)${NC} 手动输入模型名"
				echo ""
				prompt_with_default "请选择模型" "a" model_choice
				case "$model_choice" in
					a) model_name="gemini-2.5-pro" ;;
					b) model_name="gemini-2.5-flash" ;;
					c) model_name="gemini-2.5-flash-lite" ;;
					d) model_name="gemini-3-flash" ;;
					e) prompt_with_default "请输入模型名称" "gemini-2.5-pro" model_name ;;
					*) model_name="gemini-2.5-pro" ;;
				esac
				json_set agents.defaults.model.primary "$model_name"
				echo -e "  ${GREEN}✅ Google Gemini 已配置，活跃模型: ${model_name}${NC}"
			fi
			;;
		5)
			echo ""
			echo -e "  ${BOLD}OpenRouter 配置${NC}"
			echo -e "  ${YELLOW}获取 API Key: https://openrouter.ai/keys${NC}"
			echo -e "  ${YELLOW}聚合多家模型，一个 Key 可调用所有主流模型${NC}"
			echo ""
			prompt_with_default "请输入 OpenRouter API Key" "" api_key
			if [ -n "$api_key" ]; then
				json_set models.openrouter.apiKey "$api_key"
				echo ""
				echo -e "  ${CYAN}常用模型 (格式: provider/model):${NC}"
				echo -e "    ${CYAN}a)${NC} anthropic/claude-sonnet-4    — Claude Sonnet 4 (推荐)"
				echo -e "    ${CYAN}b)${NC} anthropic/claude-opus-4      — Claude Opus 4"
				echo -e "    ${CYAN}c)${NC} openai/gpt-5.2              — GPT-5.2"
				echo -e "    ${CYAN}d)${NC} google/gemini-2.5-pro        — Gemini 2.5 Pro"
				echo -e "    ${CYAN}e)${NC} deepseek/deepseek-r1         — DeepSeek R1"
				echo -e "    ${CYAN}f)${NC} meta-llama/llama-4-maverick  — Meta Llama 4"
				echo -e "    ${CYAN}g)${NC} 手动输入模型名"
				echo ""
				prompt_with_default "请选择模型" "a" model_choice
				case "$model_choice" in
					a) model_name="anthropic/claude-sonnet-4" ;;
					b) model_name="anthropic/claude-opus-4" ;;
					c) model_name="openai/gpt-5.2" ;;
					d) model_name="google/gemini-2.5-pro" ;;
					e) model_name="deepseek/deepseek-r1" ;;
					f) model_name="meta-llama/llama-4-maverick" ;;
					g) prompt_with_default "请输入模型名称" "anthropic/claude-sonnet-4" model_name ;;
					*) model_name="anthropic/claude-sonnet-4" ;;
				esac
				json_set agents.defaults.model.primary "$model_name"
				echo -e "  ${GREEN}✅ OpenRouter 已配置，活跃模型: ${model_name}${NC}"
			fi
			;;
		6)
			echo ""
			echo -e "  ${BOLD}DeepSeek 配置${NC}"
			echo -e "  ${YELLOW}获取 API Key: https://platform.deepseek.com/api_keys${NC}"
			echo ""
			prompt_with_default "请输入 DeepSeek API Key" "" api_key
			if [ -n "$api_key" ]; then
				json_set models.deepseek.apiKey "$api_key"
				echo ""
				echo -e "  ${CYAN}可用模型:${NC}"
				echo -e "    ${CYAN}a)${NC} deepseek-chat     — DeepSeek-V3 (通用对话)"
				echo -e "    ${CYAN}b)${NC} deepseek-reasoner — DeepSeek-R1 (深度推理)"
				echo -e "    ${CYAN}c)${NC} 手动输入模型名"
				echo ""
				prompt_with_default "请选择模型" "a" model_choice
				case "$model_choice" in
					a) model_name="deepseek-chat" ;;
					b) model_name="deepseek-reasoner" ;;
					c) prompt_with_default "请输入模型名称" "deepseek-chat" model_name ;;
					*) model_name="deepseek-chat" ;;
				esac
				json_set agents.defaults.model.primary "$model_name"
				echo -e "  ${GREEN}✅ DeepSeek 已配置，活跃模型: ${model_name}${NC}"
			fi
			;;
		7)
			echo ""
			echo -e "  ${BOLD}GitHub Copilot 配置${NC}"
			echo -e "  ${YELLOW}需要有效的 GitHub Copilot 订阅${NC}"
			echo -e "  ${YELLOW}获取 Token: https://github.com/settings/tokens (需 copilot 权限)${NC}"
			echo ""
			prompt_with_default "请输入 GitHub Token (ghp_...)" "" api_key
			if [ -n "$api_key" ]; then
				json_set models.github-copilot.apiKey "$api_key"
				echo ""
				echo -e "  ${CYAN}可用模型:${NC}"
				echo -e "    ${CYAN}a)${NC} github-copilot/claude-sonnet-4 — Claude Sonnet 4 (推荐)"
				echo -e "    ${CYAN}b)${NC} github-copilot/gpt-5.2         — GPT-5.2"
				echo -e "    ${CYAN}c)${NC} github-copilot/gemini-2.5-pro  — Gemini 2.5 Pro"
				echo -e "    ${CYAN}d)${NC} github-copilot/o3              — o3"
				echo -e "    ${CYAN}e)${NC} 手动输入模型名"
				echo ""
				prompt_with_default "请选择模型" "a" model_choice
				case "$model_choice" in
					a) model_name="github-copilot/claude-sonnet-4" ;;
					b) model_name="github-copilot/gpt-5.2" ;;
					c) model_name="github-copilot/gemini-2.5-pro" ;;
					d) model_name="github-copilot/o3" ;;
					e) prompt_with_default "请输入模型名称" "github-copilot/claude-sonnet-4" model_name ;;
					*) model_name="github-copilot/claude-sonnet-4" ;;
				esac
				json_set agents.defaults.model.primary "$model_name"
				echo -e "  ${GREEN}✅ GitHub Copilot 已配置，活跃模型: ${model_name}${NC}"
			fi
			;;
		8)
			echo ""
			echo -e "  ${BOLD}阿里云通义千问 Qwen 配置${NC}"
			echo -e "  ${YELLOW}使用 OpenClaw 官方 Qwen Portal 认证插件${NC}"
			echo ""
			echo -e "  ${CYAN}配置方式:${NC}"
			echo -e "    ${CYAN}a)${NC} 通过官方向导配置 (推荐)"
			echo -e "    ${CYAN}b)${NC} 通过 API Key 手动配置 (兼容 OpenAI 格式)"
			echo ""
			prompt_with_default "请选择" "b" qwen_mode
			case "$qwen_mode" in
				a)
					echo ""
					echo -e "  ${CYAN}启用 Qwen Portal Auth 插件...${NC}"
					enable_auth_plugins
					echo -e "  ${CYAN}启动 Qwen OAuth 授权...${NC}"
					oc_cmd models auth login --provider qwen-portal --set-default || echo -e "  ${YELLOW}OAuth 授权已退出${NC}"
					echo ""
					ask_restart
					;;
				b|*)
					echo ""
					echo -e "  ${YELLOW}获取 API Key: https://dashscope.console.aliyun.com/apiKey${NC}"
					echo ""
					prompt_with_default "请输入阿里云 API Key (sk-...)" "" api_key
					if [ -n "$api_key" ]; then
						json_set models.custom.apiKey "$api_key"
						json_set models.custom.baseUrl "https://dashscope.aliyuncs.com/compatible-mode/v1"
						echo ""
						echo -e "  ${CYAN}可用模型:${NC}"
						echo -e "    ${CYAN}a)${NC} qwen-max        — 通义千问旗舰 (推荐)"
						echo -e "    ${CYAN}b)${NC} qwen-plus       — 性价比之选"
						echo -e "    ${CYAN}c)${NC} qwen-turbo      — 快速响应"
						echo -e "    ${CYAN}d)${NC} qwen3-235b-a22b — Qwen3 235B MoE"
						echo -e "    ${CYAN}e)${NC} 手动输入模型名"
						echo ""
						prompt_with_default "请选择模型" "a" model_choice
						case "$model_choice" in
							a) model_name="qwen-max" ;;
							b) model_name="qwen-plus" ;;
							c) model_name="qwen-turbo" ;;
							d) model_name="qwen3-235b-a22b" ;;
							e) prompt_with_default "请输入模型名称" "qwen-max" model_name ;;
							*) model_name="qwen-max" ;;
						esac
						json_set agents.defaults.model.primary "$model_name"
						echo -e "  ${GREEN}✅ 通义千问已配置，活跃模型: ${model_name}${NC}"
					fi
					;;
			esac
			;;
		9)
			echo ""
			echo -e "  ${BOLD}xAI Grok 配置${NC}"
			echo -e "  ${YELLOW}获取 API Key: https://console.x.ai${NC}"
			echo ""
			prompt_with_default "请输入 xAI API Key" "" api_key
			if [ -n "$api_key" ]; then
				json_set models.xai.apiKey "$api_key"
				echo ""
				echo -e "  ${CYAN}可用模型:${NC}"
				echo -e "    ${CYAN}a)${NC} grok-3       — Grok 3 旗舰"
				echo -e "    ${CYAN}b)${NC} grok-3-mini  — Grok 3 Mini"
				echo -e "    ${CYAN}c)${NC} 手动输入模型名"
				echo ""
				prompt_with_default "请选择模型" "a" model_choice
				case "$model_choice" in
					a) model_name="grok-3" ;;
					b) model_name="grok-3-mini" ;;
					c) prompt_with_default "请输入模型名称" "grok-3" model_name ;;
					*) model_name="grok-3" ;;
				esac
				json_set agents.defaults.model.primary "$model_name"
				echo -e "  ${GREEN}✅ xAI Grok 已配置，活跃模型: ${model_name}${NC}"
			fi
			;;
		10)
			echo ""
			echo -e "  ${BOLD}Groq 配置${NC}"
			echo -e "  ${YELLOW}获取 API Key: https://console.groq.com/keys${NC}"
			echo -e "  ${YELLOW}Groq 提供超快推理速度${NC}"
			echo ""
			prompt_with_default "请输入 Groq API Key" "" api_key
			if [ -n "$api_key" ]; then
				json_set models.groq.apiKey "$api_key"
				echo ""
				echo -e "  ${CYAN}可用模型:${NC}"
				echo -e "    ${CYAN}a)${NC} llama-4-maverick-17b-128e  — Llama 4 Maverick (推荐)"
				echo -e "    ${CYAN}b)${NC} llama-3.3-70b-versatile   — Llama 3.3 70B"
				echo -e "    ${CYAN}c)${NC} llama-3.1-8b-instant      — Llama 3.1 8B (极速)"
				echo -e "    ${CYAN}d)${NC} 手动输入模型名"
				echo ""
				prompt_with_default "请选择模型" "a" model_choice
				case "$model_choice" in
					a) model_name="llama-4-maverick-17b-128e" ;;
					b) model_name="llama-3.3-70b-versatile" ;;
					c) model_name="llama-3.1-8b-instant" ;;
					d) prompt_with_default "请输入模型名称" "llama-4-maverick-17b-128e" model_name ;;
					*) model_name="llama-4-maverick-17b-128e" ;;
				esac
				json_set agents.defaults.model.primary "$model_name"
				echo -e "  ${GREEN}✅ Groq 已配置，活跃模型: ${model_name}${NC}"
			fi
			;;
		11)
			echo ""
			echo -e "  ${BOLD}硅基流动 SiliconFlow 配置${NC}"
			echo -e "  ${YELLOW}获取 API Key: https://cloud.siliconflow.cn/account/ak${NC}"
			echo -e "  ${YELLOW}国内推理平台，支持多种开源模型${NC}"
			echo ""
			prompt_with_default "请输入 SiliconFlow API Key" "" api_key
			if [ -n "$api_key" ]; then
				json_set models.custom.apiKey "$api_key"
				json_set models.custom.baseUrl "https://api.siliconflow.cn/v1"
				echo ""
				echo -e "  ${CYAN}可用模型:${NC}"
				echo -e "    ${CYAN}a)${NC} deepseek-ai/DeepSeek-V3      — DeepSeek V3 (推荐)"
				echo -e "    ${CYAN}b)${NC} deepseek-ai/DeepSeek-R1      — DeepSeek R1"
				echo -e "    ${CYAN}c)${NC} Qwen/Qwen3-235B-A22B        — 通义千问 Qwen3 235B"
				echo -e "    ${CYAN}d)${NC} 手动输入模型名"
				echo ""
				prompt_with_default "请选择模型" "a" model_choice
				case "$model_choice" in
					a) model_name="deepseek-ai/DeepSeek-V3" ;;
					b) model_name="deepseek-ai/DeepSeek-R1" ;;
					c) model_name="Qwen/Qwen3-235B-A22B" ;;
					d) prompt_with_default "请输入模型名称" "deepseek-ai/DeepSeek-V3" model_name ;;
					*) model_name="deepseek-ai/DeepSeek-V3" ;;
				esac
				json_set agents.defaults.model.primary "$model_name"
				echo -e "  ${GREEN}✅ SiliconFlow 已配置，活跃模型: ${model_name}${NC}"
			fi
			;;
		12)
			echo ""
			echo -e "  ${BOLD}自定义 OpenAI 兼容 API${NC}"
			echo -e "  ${YELLOW}支持任何兼容 OpenAI API 格式的服务商${NC}"
			echo ""
			prompt_with_default "API Base URL (如 https://api.example.com/v1)" "" base_url
			prompt_with_default "API Key" "" api_key
			prompt_with_default "模型名称" "" model_name
			if [ -n "$base_url" ] && [ -n "$api_key" ] && [ -n "$model_name" ]; then
				json_set models.custom.apiKey "$api_key"
				json_set models.custom.baseUrl "$base_url"
				json_set agents.defaults.model.primary "$model_name"
				echo -e "  ${GREEN}✅ 自定义模型已配置${NC}"
			fi
			;;
		0) return ;;
	esac

	if [ "$choice" != "0" ] && [ "$choice" != "1" ] && [ "$choice" != "8" ]; then
		echo ""
		ask_restart
	fi
}

# ══════════════════════════════════════════════════════════════
# 设定当前活跃模型
# ══════════════════════════════════════════════════════════════
set_active_model() {
	echo ""
	echo -e "  ${BOLD}🔄 设定当前活跃模型${NC}"
	echo ""

	local current_model=$(json_get agents.defaults.model.primary)
	echo -e "  当前活跃模型: ${GREEN}${BOLD}${current_model:-未设置}${NC}"
	echo ""

	local models_json=""
	models_json=$(oc_cmd models list --json 2>/dev/null || echo "")
	local model_count=0
	if [ -n "$models_json" ]; then
		model_count=$("$NODE_BIN" -e "
			try{const d=JSON.parse(process.argv[1]);console.log((d.models||[]).length);}catch(e){console.log(0);}
		" "$models_json" 2>/dev/null || echo "0")
	fi

	if [ "$model_count" -gt 0 ] 2>/dev/null; then
		echo -e "  ${CYAN}已配置的模型:${NC}"
		echo ""
		"$NODE_BIN" -e "
			const d=JSON.parse(process.argv[1]);
			(d.models||[]).forEach((m,i)=>{
				const mark=m.key===process.argv[2]?' ← 当前活跃':'';
				const n=m.name&&m.name!==m.key?' ('+m.name+')':'';
				console.log('    '+(i+1)+') '+m.key+n+mark);
			});
		" "$models_json" "$current_model" 2>/dev/null
		echo ""
		echo -e "    ${CYAN}m)${NC} 手动输入模型 ID"
		echo -e "    ${CYAN}0)${NC} 返回"
		echo ""
		prompt_with_default "请选择" "0" model_sel

		if [ "$model_sel" = "0" ]; then
			return
		elif [ "$model_sel" = "m" ]; then
			prompt_with_default "请输入模型 ID (如 openai/gpt-4o)" "${current_model:-}" manual_model
			if [ -n "$manual_model" ]; then
				json_set agents.defaults.model.primary "$manual_model"
				echo -e "  ${GREEN}✅ 活跃模型已设为: ${manual_model}${NC}"
				ask_restart
			fi
		elif echo "$model_sel" | grep -qE '^[0-9]+$'; then
			local selected=$("$NODE_BIN" -e "
				const d=JSON.parse(process.argv[1]);
				const m=(d.models||[])[parseInt(process.argv[2])-1];
				console.log(m?m.key:'');
			" "$models_json" "$model_sel" 2>/dev/null)
			if [ -n "$selected" ]; then
				json_set agents.defaults.model.primary "$selected"
				echo -e "  ${GREEN}✅ 活跃模型已切换为: ${selected}${NC}"
				ask_restart
			else
				echo -e "  ${YELLOW}无效选择${NC}"
			fi
		fi
	else
		echo -e "  ${YELLOW}尚未配置任何模型。${NC}"
		echo -e "  ${YELLOW}请先通过「配置 AI 模型提供商」(菜单 2) 添加模型。${NC}"
		echo ""
		prompt_with_default "直接输入模型 ID 设置? (留空返回)" "" manual_model
		if [ -n "$manual_model" ]; then
			json_set agents.defaults.model.primary "$manual_model"
			echo -e "  ${GREEN}✅ 活跃模型已设为: ${manual_model}${NC}"
			ask_restart
		fi
	fi
}

# ══════════════════════════════════════════════════════════════
# 配置 Telegram
# ══════════════════════════════════════════════════════════════
configure_telegram() {
	echo ""
	echo -e "  ${BOLD}📱 Telegram Bot 配置${NC}"
	echo ""
	echo -e "  ${YELLOW}获取 Bot Token 步骤:${NC}"
	echo -e "  1. 打开 Telegram → 搜索 ${CYAN}@BotFather${NC}"
	echo -e "  2. 发送 ${CYAN}/newbot${NC} → 按提示创建"
	echo -e "  3. 复制生成的 Token"
	echo ""

	local current_token=$(json_get channels.telegram.botToken)
	if [ -n "$current_token" ]; then
		local ct_short=$(echo "$current_token" | cut -c1-12)
		echo -e "  ${GREEN}当前已配置 Token: ${ct_short}...${NC}"
	fi

	prompt_with_default "请输入 Telegram Bot Token" "" tg_token

	if [ -n "$tg_token" ]; then
		# ── 强力清洗: 先用 sanitize_input 去除 ANSI 转义序列，再白名单过滤 ──
		tg_token=$(sanitize_input "$tg_token")
		tg_token=$(printf '%s' "$tg_token" | tr -cd 'A-Za-z0-9:_-')

		# ── 格式验证: 使用 grep 正则匹配 "数字:字母数字" ──
		if ! printf '%s' "$tg_token" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$'; then
			echo -e "  ${RED}❌ Token 格式错误${NC}"
			echo -e "  ${YELLOW}   正确格式: 123456789:ABCdefGHIjklMNOpqr${NC}"
			echo -e "  ${YELLOW}   请检查粘贴是否完整，重试。${NC}"
			return
		fi

		echo -e "  ${CYAN}验证 Token...${NC}"
		local verify=""
		verify=$(curl -s --connect-timeout 5 --max-time 10 "https://api.telegram.org/bot${tg_token}/getMe" 2>/dev/null || echo '{"ok":false}')
		if echo "$verify" | grep -q '"ok":true'; then
			local bot_name=$(echo "$verify" | grep -o '"username":"[^"]*"' | head -1 | cut -d'"' -f4)
			echo -e "  ${GREEN}✅ Token 验证成功 — @${bot_name}${NC}"
		else
			echo -e "  ${RED}❌ Token 验证失败${NC}"
			echo -e "  ${YELLOW}   可能原因: Token 不正确 或 无法连接 Telegram API${NC}"
			prompt_with_default "是否仍然保存此 Token? (y/n)" "n" force_save
			if ! confirm_yes "$force_save"; then
				echo -e "  ${YELLOW}已取消，Token 未保存。${NC}"
				return
			fi
		fi

		# ── 使用 json_set 直接写入 (避免 oc_cmd CLI 参数解析问题) ──
		json_set channels.telegram.botToken "$tg_token"
		chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
		chown openclaw:openclaw "${CONFIG_FILE}.bak" 2>/dev/null || true

		# ── 保存后验证: 读回检查 Token 是否完整 ──
		local saved_token=$(json_get channels.telegram.botToken)
		if [ "$saved_token" != "$tg_token" ]; then
			echo -e "  ${RED}❌ Token 保存异常! 已保存的值与输入不一致${NC}"
			echo -e "  ${YELLOW}   期望: ${tg_token}${NC}"
			echo -e "  ${YELLOW}   实际: ${saved_token}${NC}"
			echo -e "  ${YELLOW}   请重新配置。${NC}"
			return
		fi
		echo -e "  ${GREEN}✅ Telegram Bot Token 已保存${NC}"

		# 重启 Gateway 使 Token 生效
		ask_restart

		# Token 保存且 Gateway 重启后，自动进入配对流程
		echo ""
		echo -e "  ${CYAN}接下来进行 Telegram 配对，让 Bot 关联您的账号。${NC}"
		prompt_with_default "是否现在进行配对? (y/n)" "y" do_pair
		if confirm_yes "$do_pair"; then
			telegram_pairing
		fi
	else
		echo -e "  ${YELLOW}未输入 Token，已取消。${NC}"
	fi
}

# ── 配置 Discord ──
configure_discord() {
	echo ""
	echo -e "  ${BOLD}🎮 Discord Bot 配置${NC}"
	echo ""
	echo -e "  ${YELLOW}获取 Bot Token:${NC} ${CYAN}https://discord.com/developers/applications${NC}"
	echo ""
	prompt_with_default "请输入 Discord Bot Token" "" dc_token
	dc_token=$(sanitize_input "$dc_token" | tr -d '[:space:]')
	if [ -n "$dc_token" ]; then
		json_set channels.discord.botToken "$dc_token"
		chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
		echo -e "  ${GREEN}✅ Discord Bot Token 已保存${NC}"
		ask_restart
	fi
}

# ── 配置飞书 ──
configure_feishu() {
	echo ""
	echo -e "  ${BOLD}🐦 飞书 Bot 配置${NC}"
	echo ""
	echo -e "  ${YELLOW}获取凭据: ${CYAN}https://open.feishu.cn${NC} → 创建企业自建应用"
	echo ""

	local current_appid=$(json_get channels.feishu.appId)
	if [ -n "$current_appid" ]; then
		echo -e "  ${GREEN}当前 App ID: ${current_appid}${NC}"
	fi

	prompt_with_default "请输入飞书 App ID" "" fs_appid
	prompt_with_default "请输入飞书 App Secret" "" fs_secret
	fs_appid=$(sanitize_input "$fs_appid" | tr -d '[:space:]')
	fs_secret=$(sanitize_input "$fs_secret" | tr -d '[:space:]')

	if [ -n "$fs_appid" ] && [ -n "$fs_secret" ]; then
		json_set channels.feishu.appId "$fs_appid"
		json_set channels.feishu.appSecret "$fs_secret"
		chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
		echo -e "  ${GREEN}✅ 飞书配置已保存${NC}"
		ask_restart
	else
		echo -e "  ${YELLOW}信息不完整，已取消。${NC}"
	fi
}

# ── 配置 Slack ──
configure_slack() {
	echo ""
	echo -e "  ${BOLD}💬 Slack Bot 配置${NC}"
	echo ""
	echo -e "  ${YELLOW}获取 Bot Token:${NC} ${CYAN}https://api.slack.com/apps${NC} → Create App"
	echo ""
	prompt_with_default "请输入 Slack Bot Token (xoxb-...)" "" sk_token
	sk_token=$(sanitize_input "$sk_token" | tr -d '[:space:]')
	if [ -n "$sk_token" ]; then
		json_set channels.slack.botToken "$sk_token"
		chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
		echo -e "  ${GREEN}✅ Slack Bot Token 已保存${NC}"
		ask_restart
	fi
}

# ══════════════════════════════════════════════════════════════
# Telegram 配对助手
# ══════════════════════════════════════════════════════════════
telegram_pairing() {
	echo ""
	echo -e "  ${BOLD}🤝 Telegram 配对助手${NC}"
	echo ""

	local tg_token=$(json_get channels.telegram.botToken)
	if [ -z "$tg_token" ]; then
		echo -e "  ${YELLOW}未检测到 Telegram Bot Token，请先配置 Telegram。${NC}"
		return
	fi

	echo -e "  ${CYAN}诊断 Telegram API 连通性...${NC}"
	local verify=""
	verify=$(curl -s --connect-timeout 5 --max-time 10 "https://api.telegram.org/bot${tg_token}/getMe" 2>/dev/null || echo '{"ok":false}')
	if echo "$verify" | grep -q '"ok":true'; then
		local bot_name=$(echo "$verify" | grep -o '"username":"[^"]*"' | head -1 | cut -d'"' -f4)
		echo -e "  ${GREEN}✅ Telegram API 连通正常 — @${bot_name}${NC}"
	else
		echo -e "  ${RED}❌ Telegram API 连通检测未通过${NC}"
		echo -e "  ${YELLOW}   可能原因: Token 不正确、网络不通 或 Telegram 被屏蔽${NC}"
		echo -e "  ${CYAN}   建议: 返回重新配置 Token 或检查代理/网络设置${NC}"
		return
	fi

	echo ""
	echo -e "  ${GREEN}╔══════════════════════════════════════════════════╗${NC}"
	echo -e "  ${GREEN}║  请在 Telegram 中向 Bot 发送 /start             ║${NC}"
	echo -e "  ${GREEN}║  然后回到这里按回车，脚本自动检测配对请求        ║${NC}"
	echo -e "  ${GREEN}╚══════════════════════════════════════════════════╝${NC}"
	echo ""
	echo -e "  ${YELLOW}发送 /start 后按回车继续 (输入 q 退出)...${NC}"
	read _wait
	case "$_wait" in q|Q) return ;; esac

	local paired=0
	local attempt=1
	while [ $attempt -le 3 ]; do
		echo -e "  ${CYAN}检测配对请求... (第 ${attempt}/3 轮)${NC}"
		local pair_json=$(oc_cmd pairing list telegram --json 2>/dev/null || echo "")
		local codes=""
		if [ -n "$pair_json" ]; then
			codes=$(echo "$pair_json" | grep -o '"code"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
		fi

		if [ -n "$codes" ]; then
			# ash 不支持 <<<, 使用 echo | while
			echo "$codes" | while IFS= read -r code; do
				[ -z "$code" ] && continue
				echo -e "  ${CYAN}发现配对请求: ${code}${NC}"
				local approve=$(oc_cmd pairing approve telegram "$code" 2>&1)
				if echo "$approve" | grep -qi "approved\|success\|ok"; then
					echo ""
					echo -e "  ${GREEN}${BOLD}🎉 Telegram 配对成功！${NC}"
				fi
			done
			# 检查是否还有待配对的
			local re_check=$(oc_cmd pairing list telegram --json 2>/dev/null || echo "")
			local re_codes=$(echo "$re_check" | grep -o '"code"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
			if [ -z "$re_codes" ]; then
				paired=1
				break
			fi
		fi

		if [ $attempt -lt 3 ] && [ $paired -eq 0 ]; then
			echo -e "  ${YELLOW}未检测到，等待 8 秒后重试...${NC}"
			sleep 8
		fi
		attempt=$((attempt + 1))
	done

	if [ "$paired" -eq 0 ]; then
		echo ""
		echo -e "  ${YELLOW}未自动检测到配对请求。${NC}"
		echo -e "  ${CYAN}如果 Bot 已回复配对码，请手动输入 (回车跳过):${NC}"
		prompt_with_default "配对码" "" manual_code
		if [ -n "$manual_code" ]; then
			local approve=$(oc_cmd pairing approve telegram "$manual_code" 2>&1)
			if echo "$approve" | grep -qi "approved\|success\|ok"; then
				echo -e "  ${GREEN}${BOLD}🎉 Telegram 配对成功！${NC}"
			else
				echo -e "  ${YELLOW}配对失败: $approve${NC}"
			fi
		fi
	fi
}

# ══════════════════════════════════════════════════════════════
# 配置渠道子菜单
# ══════════════════════════════════════════════════════════════
configure_channels() {
	while true; do
		echo ""
		echo -e "  ${BOLD}📡 配置消息渠道${NC}"
		echo ""
		echo -e "  ${CYAN}1)${NC} Telegram  ${GREEN}(最常用，推荐)${NC}"
		echo -e "  ${CYAN}2)${NC} Discord"
		echo -e "  ${CYAN}3)${NC} 飞书 (Feishu)"
		echo -e "  ${CYAN}4)${NC} Slack"
		echo -e "  ${CYAN}5)${NC} WhatsApp  ${YELLOW}(需通过 Web 控制台扫码)${NC}"
		echo -e "  ${CYAN}6)${NC} Telegram 配对助手"
		echo -e "  ${CYAN}7)${NC} 官方完整渠道配置向导"
		echo -e "  ${CYAN}0)${NC} 返回主菜单"
		echo ""
		prompt_with_default "请选择" "1" ch_choice

		case "$ch_choice" in
			1) configure_telegram ;;
			2) configure_discord ;;
			3) configure_feishu ;;
			4) configure_slack ;;
			5)
				echo ""
				echo -e "  ${YELLOW}WhatsApp 需要通过 Web 控制台扫码配对:${NC}"
				local gw_token=$(json_get gateway.auth.token)
				local gw_port=$(json_get gateway.port)
				gw_port=${gw_port:-18789}
				echo -e "  ${CYAN}http://<你的路由器IP>:${gw_port}/?token=${gw_token}${NC}"
				echo -e "  打开后进入 Channels → WhatsApp 扫码即可。"
				;;
			6) telegram_pairing ;;
			7)
				echo ""
				echo -e "  ${CYAN}启动官方渠道配置向导...${NC}"
				(oc_cmd configure --section channels) || echo -e "  ${YELLOW}配置向导已退出${NC}"
				;;
			0) return ;;
			*) echo -e "  ${YELLOW}无效选择${NC}" ;;
		esac
	done
}

# ══════════════════════════════════════════════════════════════
# 健康检查
# ══════════════════════════════════════════════════════════════
health_check() {
	echo ""
	echo -e "  ${BOLD}🔍 健康检查${NC}"
	echo ""

	local gw_port=$(json_get gateway.port)
	gw_port=${gw_port:-18789}

	if check_port_listening "$gw_port"; then
		echo -e "  ${GREEN}✅ Gateway 端口 ${gw_port} 正在监听${NC}"
	else
		echo -e "  ${RED}❌ Gateway 端口 ${gw_port} 未监听${NC}"
	fi

	local http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://127.0.0.1:${gw_port}/" 2>/dev/null || echo "000")
	if [ "$http_code" = "200" ] || [ "$http_code" = "302" ] || [ "$http_code" = "401" ]; then
		echo -e "  ${GREEN}✅ HTTP 响应正常 (${http_code})${NC}"
	else
		echo -e "  ${RED}❌ HTTP 响应异常 (${http_code})${NC}"
	fi

	if [ -f "$CONFIG_FILE" ]; then
		echo -e "  ${GREEN}✅ 配置文件存在${NC}"
	else
		echo -e "  ${RED}❌ 配置文件不存在${NC}"
	fi

	echo ""
	echo -e "  ${CYAN}运行官方诊断...${NC}"
	oc_cmd doctor 2>/dev/null || true

	echo ""
	echo -e "  ${CYAN}最近日志 (最后 10 行):${NC}"
	logread -e openclaw 2>/dev/null | tail -10 || echo "  (无日志)"
}

# ══════════════════════════════════════════════════════════════
# 恢复默认配置
# ══════════════════════════════════════════════════════════════
reset_to_defaults() {
	echo ""
	echo -e "  ${BOLD}⚠️  恢复默认配置${NC}"
	echo ""
	echo -e "  ${YELLOW}请选择恢复级别:${NC}"
	echo ""
	echo -e "  ${CYAN}1)${NC} 🔧 仅重置网关设置 (端口/绑定/模式恢复默认，保留模型和渠道)"
	echo -e "  ${CYAN}2)${NC} 🤖 清除模型配置   (移除所有 AI 模型和 API Key)"
	echo -e "  ${CYAN}3)${NC} 📡 清除渠道配置   (移除所有消息渠道配置)"
	echo -e "  ${CYAN}4)${NC} 🔄 完全恢复出厂   (删除所有配置，重新初始化)"
	echo -e "  ${CYAN}0)${NC} 返回"
	echo ""
	prompt_with_default "请选择" "0" reset_choice

	case "$reset_choice" in
		1)
			echo ""
			echo -e "  ${YELLOW}将重置: 网关端口→18789, 绑定→lan, 模式→local${NC}"
			echo -e "  ${YELLOW}保留: 认证令牌、模型配置、消息渠道${NC}"
			prompt_with_default "确认恢复网关默认设置? (yes/no)" "no" confirm
			if [ "$confirm" = "yes" ]; then
				echo ""
				echo -e "  ${CYAN}正在重置网关设置...${NC}"
				json_set gateway.port 18789 2>&1
				json_set gateway.bind lan 2>&1
				json_set gateway.mode local 2>&1
				json_set gateway.controlUi.allowInsecureAuth true 2>&1
				json_set gateway.controlUi.dangerouslyDisableDeviceAuth true 2>&1
				json_set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true 2>&1
				json_set gateway.tailscale.mode off 2>&1
				echo -e "  ${GREEN}✅ 网关设置已恢复默认${NC}"
				ask_restart
			else
				echo -e "  ${CYAN}已取消${NC}"
			fi
			;;
		2)
			echo ""
			echo -e "  ${RED}⚠️  将清除: 所有模型配置、API Key、活跃模型设置${NC}"
			prompt_with_default "确认清除所有模型配置? (yes/no)" "no" confirm
			if [ "$confirm" = "yes" ]; then
				echo ""
				echo -e "  ${CYAN}正在清除模型配置...${NC}"
				oc_cmd config unset models >/dev/null 2>&1 || true
				oc_cmd config unset agents.defaults.model >/dev/null 2>&1 || true
				oc_cmd config unset agents.defaults.models >/dev/null 2>&1 || true
				echo -e "  ${GREEN}✅ 模型配置已清除${NC}"
				echo -e "  ${YELLOW}请通过菜单 [2] 重新配置 AI 模型${NC}"
				ask_restart
			else
				echo -e "  ${CYAN}已取消${NC}"
			fi
			;;
		3)
			echo ""
			echo -e "  ${RED}⚠️  将清除: 所有消息渠道配置 (Telegram/Discord/飞书等)${NC}"
			prompt_with_default "确认清除所有渠道配置? (yes/no)" "no" confirm
			if [ "$confirm" = "yes" ]; then
				echo ""
				echo -e "  ${CYAN}正在清除渠道配置...${NC}"
				oc_cmd config unset channels >/dev/null 2>&1 || true
				echo -e "  ${GREEN}✅ 渠道配置已清除${NC}"
				echo -e "  ${YELLOW}请通过菜单 [4] 重新配置消息渠道${NC}"
				ask_restart
			else
				echo -e "  ${CYAN}已取消${NC}"
			fi
			;;
		4)
			echo ""
			echo -e "  ${RED}╔══════════════════════════════════════════════════════╗${NC}"
			echo -e "  ${RED}║  ⚠️  完全恢复出厂设置                               ║${NC}"
			echo -e "  ${RED}║  此操作将删除所有配置并重新初始化                    ║${NC}"
			echo -e "  ${RED}╚══════════════════════════════════════════════════════╝${NC}"
			echo ""
			echo -e "  ${RED}此操作不可撤销！${NC}"
			prompt_with_default "输入 RESET 确认恢复出厂设置" "" confirm
			if [ "$confirm" = "RESET" ]; then
				echo ""
				echo -e "  ${CYAN}[1/5] 停止 Gateway...${NC}"
				# 只停止 gateway 实例, 不能停 pty (否则会断开当前终端连接)
				local gw_pid=""
				gw_pid=$(ubus call service list '{"name":"openclaw"}' 2>/dev/null | jsonfilter -e '$.openclaw.instances.gateway.pid' 2>/dev/null) || true
				if [ -n "$gw_pid" ] && kill -0 "$gw_pid" 2>/dev/null; then
					kill "$gw_pid" 2>/dev/null || true
					sleep 2
				else
					# 按端口查找 gateway 进程
					local gw_port_cur=$(json_get gateway.port)
					gw_port_cur=${gw_port_cur:-18789}
					local gw_pid2=$(get_pid_by_port "$gw_port_cur")
					if [ -n "$gw_pid2" ]; then
						kill "$gw_pid2" 2>/dev/null || true
						sleep 2
					fi
				fi
				echo -e "  ${GREEN}   Gateway 已停止${NC}"

				echo -e "  ${CYAN}[2/5] 备份当前配置...${NC}"
				local backup_dir="${OC_STATE_DIR}/backups"
				local backup_ts=$(date +%Y%m%d_%H%M%S)
				mkdir -p "$backup_dir"
				if [ -f "$CONFIG_FILE" ]; then
					cp "$CONFIG_FILE" "${backup_dir}/openclaw_${backup_ts}.json"
					echo -e "  ${GREEN}   备份已保存: backups/openclaw_${backup_ts}.json${NC}"
				fi

				echo -e "  ${CYAN}[3/5] 重置配置...${NC}"
				# 直接删除配置文件 (避免 oc_cmd reset 可能的交互式阻塞)
				rm -f "$CONFIG_FILE" 2>/dev/null || true
				rm -f "${CONFIG_FILE}.bak" 2>/dev/null || true
				echo '{}' > "$CONFIG_FILE"
				chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
				echo -e "  ${GREEN}   配置已清除${NC}"

				echo -e "  ${CYAN}[4/5] 重新初始化...${NC}"
				# 尝试 onboard，超时 10 秒避免阻塞
				timeout 10 sh -c "$(which node 2>/dev/null || echo "$NODE_BIN") \"$OC_ENTRY\" onboard --non-interactive --accept-risk" >/dev/null 2>&1 || true
				echo -e "  ${GREEN}   初始化完成${NC}"

				echo -e "  ${CYAN}[5/5] 应用 OpenWrt 适配配置...${NC}"
				local new_token
				new_token=$(head -c 24 /dev/urandom | hexdump -e '24/1 "%02x"' 2>/dev/null || dd if=/dev/urandom bs=24 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 48)
				json_set gateway.port 18789
				json_set gateway.bind lan
				json_set gateway.mode local
				json_set gateway.auth.mode token
				json_set gateway.auth.token "$new_token"
				json_set gateway.controlUi.allowInsecureAuth true
				json_set gateway.controlUi.dangerouslyDisableDeviceAuth true
				json_set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true
				json_set gateway.tailscale.mode off

				# 同步 token 到 UCI
				. /lib/functions.sh 2>/dev/null || true
				uci set openclaw.main.token="$new_token" 2>/dev/null
				uci commit openclaw 2>/dev/null

				echo ""
				echo -e "  ${GREEN}✅ 出厂设置已恢复！${NC}"
				echo ""
				echo -e "  ${CYAN}新认证令牌: ${new_token}${NC}"
				echo ""

				# 重启 gateway (通过 procd reload, 这样不会杀 pty)
				/etc/init.d/openclaw start >/dev/null 2>&1 &
				echo -e "  ${YELLOW}⏳ Gateway 启动中，请稍候...${NC}"
				local gw_port=18789
				local waited=0
				while [ $waited -lt 15 ]; do
					sleep 2
					waited=$((waited + 2))
					if check_port_listening "$gw_port"; then
						echo -e "  ${GREEN}✅ Gateway 已重新启动${NC}"
						break
					fi
				done
				if [ $waited -ge 15 ]; then
					echo -e "  ${YELLOW}⏳ Gateway 可能仍在启动中，请稍后检查${NC}"
				fi
			else
				echo -e "  ${CYAN}已取消${NC}"
			fi
			;;
		0|"") return ;;
		*) echo -e "  ${YELLOW}无效选择${NC}" ;;
	esac
}

# ══════════════════════════════════════════════════════════════
# 主菜单
# ══════════════════════════════════════════════════════════════
main_menu() {
	while true; do
		echo ""
		echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
		echo -e "${GREEN}║${NC}           ${BOLD}OpenClaw AI Gateway — OpenWrt 配置管理${NC}            ${GREEN}║${NC}"
		echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
		echo ""
		echo -e "  ${CYAN}1)${NC} 📋 查看当前配置"
		echo -e "  ${CYAN}2)${NC} 🤖 配置 AI 模型提供商"
		echo -e "  ${CYAN}3)${NC} 🔄 设定当前活跃模型"
		echo -e "  ${CYAN}4)${NC} 📡 配置消息渠道 (Telegram/Discord/飞书/Slack)"
		echo -e "  ${CYAN}5)${NC} 🤝 Telegram 配对助手"
		echo -e "  ${CYAN}6)${NC} 🔍 健康检查 / 诊断"
		echo -e "  ${CYAN}7)${NC} 🔄 重启 Gateway"
		echo -e "  ${CYAN}8)${NC} 📝 查看原始配置文件"
		echo -e "  ${CYAN}9)${NC} ⚠️  恢复默认配置"
		echo -e "  ${CYAN}0)${NC} 退出"
		echo ""
		prompt_with_default "请选择" "1" menu_choice

		case "$menu_choice" in
			1) show_current_config ;;
			2) configure_model ;;
			3) set_active_model ;;
			4) configure_channels ;;
			5) telegram_pairing ;;
			6) health_check ;;
			7) restart_gateway ;;
			8)
				echo ""
				echo -e "  ${CYAN}配置文件路径: ${CONFIG_FILE}${NC}"
				echo ""
				if [ -f "$CONFIG_FILE" ]; then
					"$NODE_BIN" -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync('${CONFIG_FILE}','utf8')),null,2))" 2>/dev/null || cat "$CONFIG_FILE"
				else
					echo "  (配置文件不存在)"
				fi
				echo ""
				prompt_with_default "是否用 vi 编辑? (y/n)" "n" do_edit
				if confirm_yes "$do_edit"; then
					vi "$CONFIG_FILE"
					ask_restart
				fi
				;;
			9) reset_to_defaults ;;
			0)
				echo -e "  ${GREEN}再见！${NC}"
				exit 0
				;;
			*) echo -e "  ${YELLOW}无效选择${NC}" ;;
		esac
	done
}

# ── 支持命令行参数 ──
case "${1:-}" in
	--set)
		if [ -n "${2:-}" ] && [ -n "${3:-}" ]; then
			json_set "$2" "$3"
			chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
			echo -e "${GREEN}✅ 已设置 $2${NC}"
		else
			echo "用法: oc-config.sh --set <key> <value>"
		fi
		;;
	--get)
		if [ -n "${2:-}" ]; then
			oc_cmd config get "$2"
		else
			echo "用法: oc-config.sh --get <key>"
		fi
		;;
	--restart)
		restart_gateway
		;;
	--status)
		show_current_config
		health_check
		;;
	--help|-h)
		echo ""
		echo "OpenClaw AI Gateway — OpenWrt 配置管理工具"
		echo ""
		echo "用法:"
		echo "  oc-config.sh              # 进入交互式菜单"
		echo "  oc-config.sh --set K V    # 设置配置项"
		echo "  oc-config.sh --get K      # 读取配置项"
		echo "  oc-config.sh --restart    # 重启 Gateway"
		echo "  oc-config.sh --status     # 查看状态"
		echo ""
		;;
	"")
		main_menu
		;;
	*)
		echo "未知参数: $1  (使用 --help 查看帮助)"
		exit 1
		;;
esac
