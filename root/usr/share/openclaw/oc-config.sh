#!/bin/sh
# ============================================================================
# OpenClaw 配置管理工具 — OpenWrt 适配版
# 基于原始 oc-config.sh 移植，适配 ash/busybox 环境
# ============================================================================

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── 交互式菜单引擎路径 ──
OC_MENU_ENGINE="/usr/share/openclaw/oc-menu-engine.js"
OC_INTERACTIVE="/usr/share/openclaw/oc-config-interactive.js"

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

# ── 路径 (OpenWrt 适配，支持自定义安装路径) ──
# 从 UCI 配置读取自定义路径，环境变量可覆盖。
# 注意 OC_INSTALL_PATH 历史上被当作“基础路径”传入，统一解析后再展开到 openclaw 根目录。
[ -r /usr/libexec/openclaw-paths.sh ] && . /usr/libexec/openclaw-paths.sh
OC_CONFIGURED_PATH="${OC_INSTALL_PATH:-$(uci -q get openclaw.main.install_path 2>/dev/null || echo '/opt')}"
if command -v oc_load_paths >/dev/null 2>&1 && oc_load_paths "$OC_CONFIGURED_PATH"; then
	OC_INSTALL_PATH="$OC_ROOT"
else
	OC_BASE_PATH="${OC_CONFIGURED_PATH%/}"
	OC_INSTALL_PATH="${OC_BASE_PATH}/openclaw"
	NODE_BASE="${NODE_BASE:-${OC_INSTALL_PATH}/node}"
	OC_GLOBAL="${OC_GLOBAL:-${OC_INSTALL_PATH}/global}"
	OC_DATA="${OC_DATA:-${OC_INSTALL_PATH}/data}"
	CONFIG_FILE="${OC_DATA}/.openclaw/openclaw.json"
fi
NODE_BASE="${NODE_BASE:-${OC_INSTALL_PATH}/node}"
OC_GLOBAL="${OC_GLOBAL:-${OC_INSTALL_PATH}/global}"
OC_DATA="${OC_DATA:-${OC_INSTALL_PATH}/data}"
NODE_BIN="${NODE_BIN:-${NODE_BASE}/bin/node}"
if [ ! -x "$NODE_BIN" ] && command -v node >/dev/null 2>&1; then
	NODE_BIN="$(command -v node)"
fi
OC_STATE_DIR="${OC_DATA}/.openclaw"
CONFIG_FILE="${OC_STATE_DIR}/openclaw.json"

export HOME="$OC_DATA"
export OPENCLAW_HOME="$OC_DATA"
export OPENCLAW_STATE_DIR="$OC_STATE_DIR"
export OPENCLAW_CONFIG_PATH="$CONFIG_FILE"
export NODE_ICU_DATA="${NODE_BASE}/share/icu"
export PATH="${NODE_BASE}/bin:${OC_GLOBAL}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

fix_openclaw_state_permissions() {
	[ -x /usr/libexec/openclaw-permissions.sh ] && /usr/libexec/openclaw-permissions.sh fix-state "$OC_STATE_DIR"
}

prepare_openclaw_workdirs() {
	[ -x /usr/libexec/openclaw-permissions.sh ] && /usr/libexec/openclaw-permissions.sh prepare-workdirs "$OC_DATA"
}

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
		"$NODE_BIN" "$OC_ENTRY" "$@"
		local rc=$?
		# 修复权限: oc_cmd 以 root 运行但配置文件应属于 openclaw 用户
		fix_openclaw_state_permissions 2>/dev/null || true
		chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
		chown openclaw:openclaw "${CONFIG_FILE}.bak" 2>/dev/null || true
		return $rc
	else
		echo "ERROR: OpenClaw 未安装或 Node.js 不可用"
		return 1
	fi
}

# 以 openclaw 服务用户运行官方诊断。
# OpenClaw 2026.7.x 的插件安全检查按当前进程 uid 校验插件目录属主
# (属主必须等于进程 uid 或为 root)。本脚本在 PTY 中以 root 运行，
# root 身份执行 doctor 会把 openclaw 属主的微信插件目录判为
# suspicious ownership 并自动清理 plugins.allow / channels 配置。
oc_doctor_as_openclaw() {
	if [ -z "$OC_ENTRY" ] || [ ! -x "$NODE_BIN" ]; then
		echo "ERROR: OpenClaw 未安装或 Node.js 不可用"
		return 1
	fi
	if ! id openclaw >/dev/null 2>&1; then
		oc_cmd doctor
		return $?
	fi
	local _doc_cmd="cd \"${OC_DATA}\" && HOME=\"${OC_DATA}\" OPENCLAW_HOME=\"${OC_DATA}\" OPENCLAW_STATE_DIR=\"${OC_DATA}/.openclaw\" OPENCLAW_CONFIG_PATH=\"${CONFIG_FILE}\" NODE_ICU_DATA=\"${NODE_BASE}/share/icu\" \"${NODE_BIN}\" \"${OC_ENTRY}\" doctor"
	if command -v su >/dev/null 2>&1; then
		su -s /bin/sh openclaw -c "${_doc_cmd}" 2>&1
	elif command -v runuser >/dev/null 2>&1; then
		runuser -u openclaw -- sh -c "${_doc_cmd}" 2>&1
	else
		local _doc_pid="/tmp/openclaw-doctor-$$.pid"
		(cd "${OC_DATA}" 2>/dev/null || true; start-stop-daemon -S -m -p "$_doc_pid" -c openclaw:openclaw -x /bin/sh -- -c "${_doc_cmd}" 2>&1)
		local rc=$?
		rm -f "$_doc_pid" 2>/dev/null || true
		return $rc
	fi
}

# ── JSON 读写 (使用 Node.js) ──
json_get() {
	if [ ! -f "$CONFIG_FILE" ]; then echo ""; return; fi
	_OC_JS_KEY="$1" _OC_JS_CONFIG="$CONFIG_FILE" "$NODE_BIN" -e '
		const fs=require("fs");
		try{
			const d=JSON.parse(fs.readFileSync(process.env._OC_JS_CONFIG,"utf8"));
			const ks=process.env._OC_JS_KEY.split(".");let v=d;
			for(const k of ks){v=v[k];if(v===undefined||v===null){console.log("");process.exit(0);}}
			if(typeof v==="object")console.log(JSON.stringify(v));else console.log(v);
		}catch(e){console.log("");}
	' 2>/dev/null
}

# ── 配置写入类型表 ──
# 依据: OpenClaw 官方 schema，基线见 tests/fixtures/openclaw-schema-types.tsv
#
# 上游对配置类型做严格校验: gateway.port 必须是 integer、
# acp.dispatch.enabled / channels.*.enabled 必须是 boolean。
# 写成字符串会导致 openclaw config validate 失败，进而网关拒绝启动
# (实测报错: gateway.port: Invalid input / acp.dispatch.enabled: Invalid input)。
#
# 用集中表而非在每个调用点传类型，保证现有与将来新增的调用点都默认正确。
oc_schema_type_for_key() {
	case "$1" in
		gateway.port|gateway.handshakeTimeoutMs|gateway.channelHealthCheckMinutes)
			echo "number" ;;
		gateway.channelStaleEventThresholdMinutes|gateway.channelMaxRestartsPerHour)
			echo "number" ;;
		acp.dispatch.enabled|update.checkOnStart|plugins.enabled)
			echo "boolean" ;;
		gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback)
			echo "boolean" ;;
		gateway.allowRealIpFallback)
			echo "boolean" ;;
		channels.*.enabled)
			echo "boolean" ;;
		*)
			echo "string" ;;
	esac
}

# 枚举白名单。写入前校验，避免把上游不接受的值(如 gateway.bind=all)落盘。
oc_schema_enum_for_key() {
	case "$1" in
		gateway.bind)      echo "auto lan loopback custom tailnet" ;;
		gateway.mode)      echo "local remote" ;;
		gateway.auth.mode) echo "none token password trusted-proxy" ;;
		logging.level)     echo "silent fatal error warn info debug trace" ;;
		tools.profile)     echo "minimal coding messaging full" ;;
		models.mode)       echo "merge replace" ;;
		*)                 echo "" ;;
	esac
}

json_set() {
	local key="$1" value="$2"
	local _js_err=""

	# 检查是否处于升级事务迁移期间，若是则暂停写入配置
	local _sdir="${OC_STATE_DIR:-${OPENCLAW_STATE_DIR:-${OC_DATA:+$OC_DATA/.openclaw}}}"
	local _pdir="$(dirname "$_sdir")"
	local _rdir="$(dirname "$_pdir")"
	local _status_file="" cand
	for cand in \
		"${_rdir}/.luci-openclaw-upgrade/status.json" \
		"${_pdir}/.luci-openclaw-upgrade/status.json" \
		"${_sdir}/.luci-openclaw-upgrade/status.json" \
		"${OC_DATA:+$OC_DATA/.luci-openclaw-upgrade/status.json}" \
		"${OC_BASE_PATH:-/opt}/openclaw/.luci-openclaw-upgrade/status.json"; do
		if [ -n "$cand" ] && [ -f "$cand" ]; then
			_status_file="$cand"
			break
		fi
	done
	if [ -n "$_status_file" ] && [ -f "$_status_file" ]; then
		local _up_phase
		_up_phase=$(grep -oE '"phase"[[:space:]]*:[[:space:]]*"[^"]+"' "$_status_file" 2>/dev/null | cut -d'"' -f4 || true)
		case "$_up_phase" in
			migrating|gateway_verifying|backing_up)
				echo "WARN: 检测到系统正处于升级事务 (phase: $_up_phase)，暂停写入 openclaw.json" >&2
				return 0
				;;
		esac
	fi

	# 步骤1: 确保配置文件存在
	if [ ! -f "$CONFIG_FILE" ]; then
		# 检查父目录是否可创建
		local parent_dir="$(dirname "$CONFIG_FILE")"
		if ! mkdir -p "$parent_dir" 2>/dev/null; then
			echo "ERROR: 无法创建配置目录 $parent_dir" >&2
			echo "HINT: 请检查 $OC_DATA 是否存在且有写权限" >&2
			return 1
		fi
		
		# 检查目录权限
		if [ ! -w "$parent_dir" ]; then
			echo "ERROR: 配置目录 $parent_dir 不可写" >&2
			echo "HINT: 请运行: chmod 755 $parent_dir" >&2
			return 1
		fi
		
		# 尝试修复所有权
		fix_openclaw_state_permissions 2>/dev/null || true
		
		# 创建空配置文件
		if ! echo '{}' > "$CONFIG_FILE" 2>/dev/null; then
			echo "ERROR: 无法创建配置文件 $CONFIG_FILE" >&2
			echo "HINT: 请检查磁盘空间和文件系统状态" >&2
			return 1
		fi
		
		chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
	fi
	
	# 步骤2: 检查配置文件是否可写
	if [ ! -w "$CONFIG_FILE" ]; then
		echo "ERROR: 配置文件 $CONFIG_FILE 不可写" >&2
		echo "HINT: 请运行: chmod 644 $CONFIG_FILE" >&2
		return 1
	fi
	
	# 步骤3: 检查 Node.js 是否可用
	if [ ! -x "$NODE_BIN" ]; then
		echo "ERROR: Node.js 不可用: $NODE_BIN" >&2
		echo "HINT: 请先运行 openclaw-env setup 安装 Node.js" >&2
		return 1
	fi
	
	# 步骤4: 解析目标类型并校验枚举
	# 第三个参数可显式指定类型 (string/number/boolean/json)，
	# 未指定时按 schema 类型表自动判定。
	local val_type="${3:-}"
	[ -n "$val_type" ] || val_type="$(oc_schema_type_for_key "$key")"

	local allowed
	allowed="$(oc_schema_enum_for_key "$key")"
	if [ -n "$allowed" ]; then
		local matched=0 a
		for a in $allowed; do
			[ "$value" = "$a" ] && { matched=1; break; }
		done
		if [ "$matched" -ne 1 ]; then
			echo "ERROR: $key 的值 '$value' 不被 OpenClaw 接受" >&2
			echo "HINT: 允许的值: $allowed" >&2
			return 1
		fi
	fi

	# 步骤5: 使用临时文件传递值，避免环境变量转义问题
	local tmp_val_file="/tmp/.oc_json_val_$$"
	if ! printf '%s' "$value" > "$tmp_val_file" 2>/dev/null; then
		echo "ERROR: 无法创建临时文件 $tmp_val_file" >&2
		return 1
	fi

	# 步骤6: 执行 JSON 写入
	# 与 JS 侧同样的安全要求:
	#   - 配置存在但解析失败时必须中止，不能用 {} 覆盖 (否则整份配置连同
	#     models.providers 里的 apiKey 一起丢失)
	#   - 按 schema 类型落值，不能一律写成字符串
	#   - 原子写: 临时文件 -> 回读校验 -> rename
	_OC_JS_KEY="$key" _OC_JS_TYPE="$val_type" _OC_JS_VALFILE="$tmp_val_file" \
	_OC_JS_CONFIG="$CONFIG_FILE" _OC_JS_DEBUG="${OC_CONFIG_DEBUG:-0}" "$NODE_BIN" -e '
		const fs=require("fs");
		const debug=process.env._OC_JS_DEBUG==="1";
		const target=process.env._OC_JS_CONFIG;
		let d={};
		let raw="";
		try{ raw=fs.readFileSync(target,"utf8"); }catch(e){ raw=""; }
		if(raw.trim()!==""){
			try{
				d=JSON.parse(raw);
			}catch(e){
				console.error("ERROR: 配置文件不是合法 JSON: "+e.message);
				console.error("HINT: 为避免覆盖后丢失全部配置，本次写入已中止。");
				console.error("HINT: 可尝试 openclaw doctor --fix 或 openclaw config validate 定位问题。");
				process.exit(2);
			}
			if(d===null||typeof d!=="object"||Array.isArray(d)){
				console.error("ERROR: 配置根节点必须是 JSON 对象，本次写入已中止。");
				process.exit(2);
			}
		}
		const rawVal=fs.readFileSync(process.env._OC_JS_VALFILE,"utf8");
		const wantType=process.env._OC_JS_TYPE||"string";
		let v;
		if(wantType==="number"){
			v=Number(rawVal.trim());
			if(!Number.isFinite(v)){
				console.error("ERROR: "+process.env._OC_JS_KEY+" 需要数字，收到: "+rawVal.trim());
				process.exit(3);
			}
		}else if(wantType==="boolean"){
			const t=rawVal.trim().toLowerCase();
			if(t==="true"||t==="1")v=true;
			else if(t==="false"||t==="0")v=false;
			else{
				console.error("ERROR: "+process.env._OC_JS_KEY+" 需要 true/false，收到: "+rawVal.trim());
				process.exit(3);
			}
		}else if(wantType==="json"){
			try{ v=JSON.parse(rawVal); }catch(e){
				console.error("ERROR: "+process.env._OC_JS_KEY+" 需要合法 JSON: "+e.message);
				process.exit(3);
			}
		}else{
			v=rawVal;
		}
		const ks=process.env._OC_JS_KEY.split(".");let o=d;
		for(let i=0;i<ks.length-1;i++){
			if(!o[ks[i]]||typeof o[ks[i]]!=="object"||Array.isArray(o[ks[i]]))o[ks[i]]={};
			o=o[ks[i]];
		}
		o[ks[ks.length-1]]=v;
		let mode=0o644;
		try{ if(fs.existsSync(target)) mode=fs.statSync(target).mode & 0o777; }catch(e){}
		const tmp=target+".tmp-"+process.pid;
		try{
			fs.writeFileSync(tmp,JSON.stringify(d,null,2)+"\n",{mode:0o600});
			JSON.parse(fs.readFileSync(tmp,"utf8"));
			try{ fs.chmodSync(tmp,mode); }catch(e){}
			fs.renameSync(tmp,target);
			if(debug)console.log("JSON saved successfully ("+wantType+")");
		}catch(e){
			try{ if(fs.existsSync(tmp)) fs.unlinkSync(tmp); }catch(e2){}
			console.error("ERROR: Failed to write config: "+e.message);
			process.exit(1);
		}
	' 2>&1
	local _js_rc=$?

	# 清理临时文件
	rm -f "$tmp_val_file" 2>/dev/null

	# 步骤7: 检查执行结果
	if [ $_js_rc -ne 0 ]; then
		echo "ERROR: JSON 写入失败 (exit code: $_js_rc)" >&2
		return 1
	fi

	# 步骤8: 修复文件所有权
	chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true

	return 0
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
			// 启用有效的认证插件
			['copilot-proxy'].forEach(p=>{
				if(!e[p])e[p]={};e[p].enabled=true;
			});
			// 清理已废弃或未安装的插件配置 (v2026.4.9: 这些插件已移除或更名)
			delete e['qwen-portal-auth'];
			delete e['google-gemini-cli-auth'];
			delete e['minimax-portal-auth'];
			delete e['google-antigravity-auth'];
			delete e['openclaw-weixin'];  // 微信插件有独立安装流程，不应在 entries 中
			// 清理过时的 installs 配置
			if(d.plugins && d.plugins.installs){
				delete d.plugins.installs['google-gemini-cli-auth'];
				delete d.plugins.installs['minimax-portal-auth'];
			}
			fs.writeFileSync('${CONFIG_FILE}',JSON.stringify(d,null,2));
		}catch(e){}
	" 2>/dev/null
}

# ── 修复插件配置中的插件名称不匹配问题 ──
# v2026.3.13: OpenClaw 加强了配置验证，plugins.allow 中的名称必须与实际插件名完全匹配
# 问题: 旧版本写入的是 "openclaw-qqbot"，但实际插件名是 "@tencent-connect/openclaw-qqbot"
# 此函数会自动检测并修正不匹配的插件名称
fix_plugin_config() {
	[ ! -f "$CONFIG_FILE" ] && return
	[ ! -x "$NODE_BIN" ] && return
	
	# 检查是否存在 qqbot 插件目录
	local qqbot_ext_dir="${OC_STATE_DIR}/extensions/openclaw-qqbot"
	[ ! -d "$qqbot_ext_dir" ] && return
	
	# 读取并修复 plugins.allow 中的插件名称
	local fixed=0
	"$NODE_BIN" -e "
		const fs=require('fs');
		try{
			const d=JSON.parse(fs.readFileSync('${CONFIG_FILE}','utf8'));
			if(!d.plugins)d.plugins={};
			
			// 修复 plugins.allow 数组中的插件名称
			if(Array.isArray(d.plugins.allow)){
				const oldName='openclaw-qqbot';
				const newName='@tencent-connect/openclaw-qqbot';
				const idx=d.plugins.allow.indexOf(oldName);
				if(idx!==-1){
					// 检查是否已有正确的名称
					if(!d.plugins.allow.includes(newName)){
						d.plugins.allow[idx]=newName;
						console.log('FIXED');
					}else{
						// 已有正确名称，删除错误的
						d.plugins.allow.splice(idx,1);
						console.log('REMOVED_DUPLICATE');
					}
					fs.writeFileSync('${CONFIG_FILE}',JSON.stringify(d,null,2));
				}
			}
			
			// 同时修复 plugins.entries 中的键名
			if(d.plugins.entries && d.plugins.entries['openclaw-qqbot']){
				if(!d.plugins.entries['@tencent-connect/openclaw-qqbot']){
					d.plugins.entries['@tencent-connect/openclaw-qqbot']=d.plugins.entries['openclaw-qqbot'];
				}
				delete d.plugins.entries['openclaw-qqbot'];
				fs.writeFileSync('${CONFIG_FILE}',JSON.stringify(d,null,2));
				console.log('FIXED_ENTRIES');
			}
		}catch(e){}
	" 2>/dev/null | while read line; do
		case "$line" in
			FIXED|REMOVED_DUPLICATE|FIXED_ENTRIES)
				echo -e "  ${GREEN}✅ 已修复插件配置名称: openclaw-qqbot → @tencent-connect/openclaw-qqbot${NC}"
				fixed=1
				;;
		esac
	done
	
	# 确保配置文件权限正确
	chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
	
	return $fixed
}

# ── 确保 qqbot 插件在 plugins.allow 中 ──
ensure_qqbot_plugin_allowed() {
	[ ! -f "$CONFIG_FILE" ] && return
	[ ! -x "$NODE_BIN" ] && return
	
	"$NODE_BIN" -e "
		const fs=require('fs');
		try{
			const d=JSON.parse(fs.readFileSync('${CONFIG_FILE}','utf8'));
			if(!d.plugins)d.plugins={};
			if(!Array.isArray(d.plugins.allow))d.plugins.allow=[];
			
			const correctName='@tencent-connect/openclaw-qqbot';
			const oldName='openclaw-qqbot';
			
			// 移除旧的不正确名称
			d.plugins.allow=d.plugins.allow.filter(n=>n!==oldName);
			
			// 添加正确的名称（如果不存在）
			if(!d.plugins.allow.includes(correctName)){
				d.plugins.allow.push(correctName);
				fs.writeFileSync('${CONFIG_FILE}',JSON.stringify(d,null,2));
				console.log('ADDED');
			}
		}catch(e){}
	" 2>/dev/null
	
	chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
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
	fix_openclaw_state_permissions 2>/dev/null || true

	# 首次安装后 UCI 默认保持 disabled。用户在配置向导中确认“立即重启”
	# 即表示希望当前配置生效，这里同步启用服务，避免提示重启但实际仍为“已禁用”。
	if [ "$(uci -q get openclaw.main.enabled 2>/dev/null || echo 0)" != "1" ]; then
		echo -e "  ${CYAN}检测到 Gateway 未启用，正在启用服务...${NC}"
		uci -q set openclaw.main.enabled='1' 2>/dev/null || true
		uci -q commit openclaw 2>/dev/null || true
		/etc/init.d/openclaw enable >/dev/null 2>&1 || true
	fi

	local port
	port=$(json_get gateway.port)
	port=${port:-18789}

	# ── kill gateway 进程，让 procd respawn ──
	/etc/init.d/openclaw restart_gateway >/dev/null 2>&1
	/etc/init.d/openclaw start >/dev/null 2>&1

	# ── 等待端口恢复 (最多 30 秒，含端口释放 + Node.js 冷启动) ──
	echo -e "  ${YELLOW}⏳ Gateway 启动中，请稍候 (约 15-30 秒)...${NC}"
	local waited=0
	while [ $waited -lt 30 ]; do
		sleep 3
		waited=$((waited + 3))
		if check_port_listening "$port"; then
			echo -e "  ${GREEN}✅ Gateway 已重启成功 (${waited}秒)${NC}"
			return 0
		fi
	done

	# 30 秒内没就绪，提示用户但不继续阻塞
	echo -e "  ${YELLOW}⏳ Gateway 仍在启动中，请稍后确认${NC}"
	echo -e "  ${CYAN}   查看日志: logread -e openclaw${NC}"
	echo ""
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

	# 检测微信渠道
	local wechat_ext_dir="${OC_STATE_DIR}/extensions/openclaw-weixin"
	local wechat_npm_plugin=""
	if [ -d "${OC_STATE_DIR}/npm/projects" ]; then
		wechat_npm_plugin=$(find "${OC_STATE_DIR}/npm/projects" -path "*/node_modules/@tencent-weixin/openclaw-weixin/openclaw.plugin.json" -type f 2>/dev/null | head -n 1)
	fi
	if { [ -d "$wechat_ext_dir" ] && [ -f "${wechat_ext_dir}/openclaw.plugin.json" ]; } || [ -n "$wechat_npm_plugin" ]; then
		echo -e "${GREEN}│${NC}  微信 .............. ${GREEN}✅ 已配置${NC}"
	else
		echo -e "${GREEN}│${NC}  微信 .............. ${YELLOW}❌ 未配置${NC}"
	fi

	local tg_token=$(json_get channels.telegram.botToken)
	local dc_token=$(json_get channels.discord.token)
	[ -n "$dc_token" ] || dc_token=$(json_get channels.discord.botToken)
	local fs_appid=$(json_get channels.feishu.appId)
	local sk_token=$(json_get channels.slack.botToken)
	local qq_appid=$(json_get channels.qqbot.appId)

	if [ -n "$qq_appid" ]; then
		local qq_short=$(echo "$qq_appid" | cut -c1-8)
		echo -e "${GREEN}│${NC}  QQ (qqbot) ......... ${GREEN}✅ 已配置${NC} (AppID: ${qq_short}...)"
	else
		echo -e "${GREEN}│${NC}  QQ (qqbot) ......... ${YELLOW}❌ 未配置${NC}"
	fi
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

# ══════════════════════════════════════════════════════════════════════════
# AI 模型配置 (传统菜单)
#
# 业务逻辑全部在 oc-providers.js，与交互式菜单共用同一后端和同一份
# provider-catalog.json；本节只做文本菜单。菜单项、按键与流程和
# oc-config-interactive.js 的 showModelMenu / handleModelConfig 一一对应。
# Key 通过管道 (printf 为 shell 内建，不产生进程参数) 交给后端，不进入 argv。
# ══════════════════════════════════════════════════════════════════════════

OC_PROVIDERS_JS="${OC_PROVIDERS_JS:-/usr/share/openclaw/oc-providers.js}"

ocp() {
	OC_ENTRY="$OC_ENTRY" NODE_BIN="$NODE_BIN" NODE_BASE="$NODE_BASE" OC_GLOBAL="$OC_GLOBAL" OC_DATA="$OC_DATA" \
		OPENCLAW_STATE_DIR="$OC_STATE_DIR" OPENCLAW_CONFIG_PATH="$CONFIG_FILE" \
		"$NODE_BIN" "$OC_PROVIDERS_JS" "$@"
}

# 取 TSV 输出中某个键的值: ocp_field <输出> <键>
ocp_field() {
	printf '%s\n' "$1" | awk -F '\t' -v k="$2" '$1==k { sub(/^[^\t]*\t/, ""); print; exit }'
}

# 打印后端结果 (OK / ERROR / NOTE / PRIMARY)，成功返回 0
ocp_report() {
	local out="$1" ok_msg="$2"
	if printf '%s\n' "$out" | grep -q '^OK'; then
		[ -n "$ok_msg" ] && echo -e "  ${GREEN}✅ ${ok_msg}${NC}"
		printf '%s\n' "$out" | awk -F '\t' '$1=="NOTE" { print "     " $2 }'
		return 0
	fi
	local reason
	reason=$(ocp_field "$out" ERROR)
	echo -e "  ${RED}❌ 失败: ${reason:-未知错误}${NC}"
	return 1
}

# 读取密钥 (不回显)，结果写入 OC_SECRET
oc_read_secret() {
	printf "  ${CYAN}%s:${NC} " "$1" >&2
	stty -echo 2>/dev/null
	IFS= read -r OC_SECRET
	stty echo 2>/dev/null
	echo "" >&2
	OC_SECRET=$(printf '%s' "$OC_SECRET" | tr -cd ' -~' | sed 's/\[[0-9;]*[a-zA-Z~]//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
}

oc_current_model() {
	json_get agents.defaults.model.primary 2>/dev/null
}

# 从列表中按序号选择: oc_pick_from_list <多行列表> <标题>，结果写入 OC_PICKED (取消为空)
oc_pick_from_list() {
	local list="$1" title="$2" idx=1 line choice
	OC_PICKED=""
	echo ""
	[ -n "$title" ] && echo -e "  ${BOLD}${title}${NC}"
	printf '%s\n' "$list" | while IFS= read -r line; do
		[ -n "$line" ] || continue
		echo -e "  ${CYAN}${idx})${NC} ${line}"
		idx=$((idx + 1))
	done
	echo -e "  ${CYAN}0)${NC} 返回"
	echo ""
	prompt_with_default "请选择" "0" choice
	case "$choice" in
		''|0|*[!0-9]*) return 1 ;;
	esac
	OC_PICKED=$(printf '%s\n' "$list" | sed '/^$/d' | sed -n "${choice}p")
	[ -n "$OC_PICKED" ]
}

oc_verify_line() {
	local out installed verified with
	out=$(ocp verify 2>/dev/null)
	installed=$(ocp_field "$out" installed)
	verified=$(ocp_field "$out" verified)
	with=$(ocp_field "$out" verifiedWith)
	if [ -z "$installed" ]; then
		echo -e "  ${YELLOW}OpenClaw 未安装${NC}"
	elif [ "$verified" = "1" ]; then
		echo -e "  ${DIM}OpenClaw ${installed} — provider 目录已在此版本核实${NC}"
	else
		echo -e "  ${YELLOW}OpenClaw ${installed} 不在 provider 目录核实范围 (${with})，配置项可能有出入${NC}"
	fi
}

# 选择接入方式: oc_pick_method <group|quick>，结果写入 OC_REF
oc_pick_method() {
	local group="$1" rows labels
	OC_REF=""
	if [ "$group" = "quick" ]; then
		rows=$(ocp quick 2>/dev/null)
		labels=$(printf '%s\n' "$rows" | awk -F '\t' '{ print $2 }')
		oc_pick_from_list "$labels" "常用 Provider 快速配置" || return 1
		OC_REF=$(printf '%s\n' "$rows" | awk -F '\t' -v l="$OC_PICKED" '$2==l { print $1; exit }')
	else
		rows=$(ocp menu 2>/dev/null | awk -F '\t' -v g="$group" '$1==g')
		labels=$(printf '%s\n' "$rows" | awk -F '\t' '{ print $4 ($6 != "" ? "  (需官方插件)" : "") }')
		oc_pick_from_list "$labels" "$(printf '%s\n' "$rows" | head -1 | cut -f2)" || return 1
		OC_REF=$(printf '%s\n' "$rows" | awk -F '\t' -v l="$OC_PICKED" '($4 ($6 != "" ? "  (需官方插件)" : ""))==l { print $3; exit }')
	fi
	[ -n "$OC_REF" ]
}

# 模型选择 (精选 + 动态发现 + 手动 + 保持当前)，结果写入 OC_PICKED_MODEL；
# 返回 0 选中 / 1 取消 / 2 保持当前默认
oc_pick_provider_model() {
	local ref="$1" provider="$2" out discover="" rows choice cur
	cur=$(oc_current_model)
	OC_PICKED_MODEL=""
	while true; do
		out=$(ocp models "$ref" $discover 2>/dev/null)
		rows=$(printf '%s\n' "$out" | awk -F '\t' '$1=="M" { printf "%s\t%s\n", $2, $4 }')
		echo ""
		echo -e "  ${BOLD}将哪个 ${provider} 模型设为默认?${NC}"
		local idx=1
		printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r mid mdesc; do
			[ -n "$mid" ] || continue
			echo -e "  ${CYAN}${idx})${NC} ${mid}${mdesc:+  ${DIM}${mdesc}${NC}}"
			idx=$((idx + 1))
		done
		if [ -n "$discover" ]; then
			local disc hint reason
			disc=$(printf '%s\n' "$out" | awk -F '\t' '$1=="DISCOVERY" { print $2 }')
			hint=$(printf '%s\n' "$out" | awk -F '\t' '$1=="DISCOVERY" { print $3 }')
			reason=$(printf '%s\n' "$out" | awk -F '\t' '$1=="DISCOVERY" { print $4 }')
			[ "$disc" = "none" ] && echo -e "  ${YELLOW}未获取到模型列表${reason:+: ${reason}}${NC}"
			case "$hint" in *auth-rejected*) echo -e "  ${YELLOW}⚠️  上游报告该 Provider 的认证被拒绝: Key 可能无效或无权限${NC}" ;; esac
			echo -e "  ${DIM}注意: 列表只代表上游登记的模型，不代表账号有权调用；请用「连通性测试」确认${NC}"
		else
			echo -e "  ${CYAN}r)${NC} 从 OpenClaw 获取完整模型列表"
		fi
		echo -e "  ${CYAN}z)${NC} 手动输入模型 ID"
		[ -n "$cur" ] && echo -e "  ${CYAN}k)${NC} 保持当前默认模型不变 (${cur})"
		echo -e "  ${CYAN}0)${NC} 取消"
		echo ""
		prompt_with_default "请选择" "k" choice
		case "$choice" in
			r|R) echo -e "  ${CYAN}正在获取模型列表 (路由器上可能需要 10~60 秒)...${NC}"; discover="--discover"; continue ;;
			z|Z) prompt_with_default "请输入模型 ID (不含 provider/ 前缀)" "$(ocp_field "$out" DEFAULT)" OC_PICKED_MODEL; [ -n "$OC_PICKED_MODEL" ] && return 0; continue ;;
			k|K) [ -n "$cur" ] && return 2; continue ;;
			0|'') return 1 ;;
			*[!0-9]*) continue ;;
			*) OC_PICKED_MODEL=$(printf '%s\n' "$rows" | sed '/^$/d' | sed -n "${choice}p" | cut -f1); [ -n "$OC_PICKED_MODEL" ] && return 0 ;;
		esac
	done
}

oc_choose_default_after_auth() {
	local ref="$1" provider="$2" rc
	oc_pick_provider_model "$ref" "$provider"; rc=$?
	if [ $rc -eq 0 ]; then
		ocp_report "$(ocp set-default "${provider}/${OC_PICKED_MODEL}")" "默认模型已设为 ${provider}/${OC_PICKED_MODEL}"
	else
		echo -e "  ${DIM}默认模型保持为 $(oc_current_model)${NC}"
	fi
}

oc_configure_method() {
	local ref="$1" info type label plugin provider out ps
	info=$(ocp info "$ref" 2>/dev/null)
	type=$(ocp_field "$info" type)
	label=$(ocp_field "$info" label)
	provider=$(ocp_field "$info" provider)
	plugin=$(ocp_field "$info" plugin)
	[ -n "$type" ] || { echo -e "  ${RED}未知的接入方式: ${ref}${NC}"; return 1; }

	echo ""
	echo -e "  ${BOLD}${label} — $(ocp_field "$info" method)${NC}"
	[ -n "$(ocp_field "$info" keyUrl)" ] && echo -e "  ${YELLOW}获取 Key: $(ocp_field "$info" keyUrl)${NC}"
	[ -n "$(ocp_field "$info" docs)" ] && echo -e "  ${DIM}文档: $(ocp_field "$info" docs)${NC}"
	[ -n "$(ocp_field "$info" baseUrl)" ] && echo -e "  ${DIM}Base URL: $(ocp_field "$info" baseUrl)${NC}"
	[ -n "$(ocp_field "$info" note)" ] && echo -e "  ${CYAN}说明: $(ocp_field "$info" note)${NC}"
	[ -n "$(ocp_field "$info" keyHint)" ] && echo -e "  ${CYAN}提示: $(ocp_field "$info" keyHint)${NC}"
	[ -n "$(ocp_field "$info" unverified)" ] && echo -e "  ${YELLOW}未实测: $(ocp_field "$info" unverified)${NC}"
	echo ""

	case "$type" in
		api-key)
			if [ -n "$plugin" ]; then
				echo -e "  ${CYAN}检查官方插件 ${plugin}...${NC}"
				ps=$(ocp plugin-status "$ref" 2>/dev/null)
				if printf '%s\n' "$ps" | grep -q '^MISSING'; then
					echo -e "  ${YELLOW}该 Provider 需要 OpenClaw 官方插件 ${plugin}，将通过 npm 下载安装 (版本与当前 OpenClaw 匹配)。${NC}"
					prompt_with_default "是否安装该插件? (yes/no)" "yes" _yn
					[ "$_yn" = "yes" ] || { echo -e "  ${YELLOW}已取消${NC}"; return 1; }
					echo -e "  ${CYAN}正在安装 ${plugin} (可能需要 1~3 分钟)...${NC}"
					ocp_report "$(ocp install-plugin "$ref")" "插件已安装" || return 1
				elif printf '%s\n' "$ps" | grep -q '^ERROR'; then
					echo -e "  ${YELLOW}插件状态查询失败: $(ocp_field "$ps" ERROR)${NC}"
				fi
			fi
			oc_read_secret "请输入 ${label} API Key (输入不回显)"
			[ -n "$OC_SECRET" ] || { echo -e "  ${YELLOW}已取消${NC}"; return 1; }
			echo -e "  ${CYAN}正在写入凭据 (通过 OpenClaw 官方命令，Key 保存在认证库，不写入 openclaw.json)...${NC}"
			out=$(printf '%s\n' "$OC_SECRET" | ocp apply-key "$ref" --keep-default --install-plugin)
			OC_SECRET=""
			ocp_report "$out" "${label} 凭据已保存" || return 1
			oc_choose_default_after_auth "$ref" "$provider"
			return 0
			;;
		custom)
			local cid curl cmodel cimg cdef compat extra=""
			compat=$(ocp_field "$info" compatibility)
			local def_id="custom"; [ "$compat" = "anthropic" ] && def_id="custom-anthropic"
			[ -n "$provider" ] && def_id="$provider"
			prompt_with_default "Provider ID (小写字母/数字/连字符)" "$def_id" cid
			prompt_with_default "API Base URL" "$(ocp_field "$info" baseUrl)" curl
			[ -n "$curl" ] || { echo -e "  ${YELLOW}已取消${NC}"; return 1; }
			prompt_with_default "模型 ID$( [ -n "$(ocp_field "$info" defaultModel)" ] && echo " (如 $(ocp_field "$info" defaultModel))")" "" cmodel
			[ -n "$cmodel" ] || { echo -e "  ${YELLOW}已取消${NC}"; return 1; }
			prompt_with_default "该模型支持图片输入吗? (yes/no)" "no" cimg
			[ "$cimg" = "yes" ] && extra="--image"
			oc_read_secret "API Key (输入不回显，可留空: Provider 已存在时沿用原 Key)"
			prompt_with_default "设为默认模型? (yes/no)" "yes" cdef
			[ "$cdef" = "yes" ] && extra="$extra --set-default"
			echo -e "  ${CYAN}正在写入...${NC}"
			out=$(printf '%s\n' "$OC_SECRET" | ocp apply-custom --id "$cid" --base-url "$curl" --model "$cmodel" --compat "$compat" --key-optional $extra)
			OC_SECRET=""
			ocp_report "$out" "自定义 Provider 已保存: ${cid}/${cmodel}" || return 1
			echo -e "  ${DIM}注意: 按上游设计，自定义 Provider 的 Key 明文保存在 openclaw.json${NC}"
			echo -e "  ${DIM}当前默认模型: $(oc_current_model)${NC}"
			return 0
			;;
		local)
			local ourl omodel odef tags
			prompt_with_default "Ollama 地址" "$(ocp_field "$info" baseUrl)" ourl
			case "$ourl" in http://*|https://*) ;; *) ourl="http://${ourl}" ;; esac
			ourl="${ourl%/}"; ourl="${ourl%/v1}"
			tags=$(curl -sf --connect-timeout 3 --max-time 6 "${ourl}/api/tags" 2>/dev/null | "$NODE_BIN" -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{for(const m of JSON.parse(s).models||[])if(m.name)console.log(m.name)}catch{}})' 2>/dev/null)
			if [ -n "$tags" ]; then
				echo -e "  ${GREEN}✅ Ollama 已连接${NC}"
				if oc_pick_from_list "$tags" "已安装的模型 (0 返回后可手动输入)"; then omodel="$OC_PICKED"; fi
			else
				echo -e "  ${YELLOW}⚠️  无法连接 ${ourl}，上游写入时也会检测，不可达将被拒绝${NC}"
			fi
			[ -n "$omodel" ] || prompt_with_default "模型名" "" omodel
			[ -n "$omodel" ] || { echo -e "  ${YELLOW}已取消${NC}"; return 1; }
			prompt_with_default "设为默认模型? (yes/no)" "yes" odef
			echo -e "  ${CYAN}正在写入...${NC}"
			if [ "$odef" = "yes" ]; then out=$(ocp apply-ollama --base-url "$ourl" --model "$omodel" --set-default)
			else out=$(ocp apply-ollama --base-url "$ourl" --model "$omodel"); fi
			ocp_report "$out" "Ollama 已配置" || return 1
			echo -e "  ${DIM}当前默认模型: $(oc_current_model)${NC}"
			return 0
			;;
		oauth)
			echo -e "  ${CYAN}即将启动 OpenClaw 官方登录流程，请按屏幕提示在浏览器中完成授权。${NC}"
			prompt_with_default "开始登录? (yes/no)" "yes" _yn
			[ "$_yn" = "yes" ] || return 1
			# 不能接管道: 登录流程需要直接使用终端
			ocp login "$ref" || { echo -e "  ${YELLOW}登录未完成${NC}"; return 1; }
			echo -e "  ${GREEN}✅ 登录完成${NC}"
			oc_choose_default_after_auth "$ref" "$provider"
			return 0
			;;
	esac
	echo -e "  ${RED}不支持的接入类型: ${type}${NC}"
	return 1
}

oc_model_status() {
	local out
	echo -e "  ${CYAN}正在读取模型与认证状态...${NC}"
	out=$(ocp status 2>/dev/null)
	printf '%s\n' "$out" | grep -q '^ERROR' && echo -e "  ${RED}读取失败: $(ocp_field "$out" ERROR)${NC}"
	echo ""
	echo -e "  ${BOLD}默认模型:${NC} $(ocp_field "$out" DEFAULT)"
	echo -e "  ${BOLD}备用模型:${NC} $(printf '%s\n' "$out" | awk -F '\t' '$1=="FALLBACK" { printf "%s%s", sep, $2; sep=", " }')"
	echo ""
	echo -e "  ${BOLD}已保存的凭据:${NC}"
	printf '%s\n' "$out" | awk -F '\t' '$1=="PROFILE" { printf "    • %s  (%s, %s)\n", $2, $3, $4; n++ } END { if (!n) print "    无" }'
	echo ""
	echo -e "  ${BOLD}Provider 配置:${NC}"
	printf '%s\n' "$out" | awk -F '\t' '$1=="PROVIDER" { printf "    • %s  %s %s%s\n", $2, $3, $4, ($5=="key" ? " [配置内含 Key]" : ""); if ($6 != "") printf "      模型: %s\n", $6; n++ } END { if (!n) print "    无" }'
	if printf '%s\n' "$out" | grep -q '^ISSUE'; then
		echo ""
		echo -e "  ${YELLOW}${BOLD}发现问题:${NC}"
		printf '%s\n' "$out" | awk -F '\t' '$1=="ISSUE" { print "    • " $2 }'
	fi
	echo ""
	echo -e "  ${DIM}以上是本地凭据状态，不代表调用一定成功；请用「连通性测试」确认。${NC}"
	prompt_with_default "按回车继续" "" _
}

# 从已登记模型中选择 (或手动输入)，结果写入 OC_PICKED
oc_pick_configured_model() {
	local list
	list=$(ocp configured-models 2>/dev/null)
	list=$(printf '%s\n%s\n' "$list" "[手动输入 provider/model]" | sed '/^$/d')
	oc_pick_from_list "$list" "$1" || return 1
	if [ "$OC_PICKED" = "[手动输入 provider/model]" ]; then
		prompt_with_default "模型引用 (provider/model)" "" OC_PICKED
	fi
	[ -n "$OC_PICKED" ]
}

set_active_model() {
	echo ""
	echo -e "  ${BOLD}切换默认模型${NC}  当前: ${GREEN}$(oc_current_model)${NC}"
	oc_pick_configured_model "选择默认模型" || return 1
	ocp_report "$(ocp set-default "$OC_PICKED")" "默认模型已切换为 ${OC_PICKED}" && ask_restart
}

oc_manage_fallbacks() {
	local out list choice changed=0
	while true; do
		out=$(ocp fallbacks list 2>/dev/null)
		list=$(printf '%s\n' "$out" | awk -F '\t' '$1=="F" { print $2 }')
		echo ""
		echo -e "  ${BOLD}管理备用模型 (fallback)${NC}"
		echo -e "  ${DIM}默认模型不可用时按顺序尝试: $(printf '%s\n' "$list" | sed '/^$/d' | awk '{ printf "%s%s", sep, $0; sep=" → " } END { if (!NR) printf "无" }')${NC}"
		echo -e "  ${CYAN}1)${NC} 添加备用模型"
		echo -e "  ${CYAN}2)${NC} 移除备用模型"
		echo -e "  ${CYAN}3)${NC} 清空备用模型"
		echo -e "  ${CYAN}0)${NC} 返回"
		prompt_with_default "请选择" "0" choice
		case "$choice" in
			1) oc_pick_configured_model "选择要添加的备用模型" && ocp_report "$(ocp fallbacks add "$OC_PICKED")" "已更新" && changed=1 ;;
			2) oc_pick_from_list "$list" "移除哪个?" && ocp_report "$(ocp fallbacks remove "$OC_PICKED")" "已更新" && changed=1 ;;
			3) prompt_with_default "确认清空所有备用模型? (yes/no)" "no" _yn; [ "$_yn" = "yes" ] && ocp_report "$(ocp fallbacks clear)" "已清空" && changed=1 ;;
			*) [ $changed -eq 1 ] && ask_restart; return 0 ;;
		esac
	done
}

oc_model_probe() {
	local out ids
	echo -e "  ${CYAN}正在读取已配置的 Provider...${NC}"
	out=$(ocp status 2>/dev/null)
	ids=$(printf '%s\n' "$out" | awk -F '\t' '$1=="PROFILE" { print $3 } $1=="PROVIDER" { print $2 }' | sort -u)
	[ -n "$ids" ] || { echo -e "  ${YELLOW}尚未配置任何 Provider${NC}"; return 1; }
	oc_pick_from_list "$ids" "测试哪个 Provider?" || return 1
	echo -e "  ${YELLOW}连通性测试会向 ${OC_PICKED} 发送真实请求 (每个模型约 8 个 token)，可能产生少量费用或触发限流。${NC}"
	prompt_with_default "继续? (yes/no)" "yes" _yn
	[ "$_yn" = "yes" ] || return 1
	echo -e "  ${CYAN}测试中 (约 5~60 秒)...${NC}"
	out=$(ocp probe "$OC_PICKED" 2>/dev/null)
	if printf '%s\n' "$out" | grep -q '^OK'; then
		printf '%s\n' "$out" | awk -F '\t' '$1=="R" { mark = ($3=="ok") ? "✅" : "❌"; printf "    %s %s  %s%s\n", mark, $2, $4, ($5 > 0 ? " (" $5 " ms)" : ""); if ($6 != "") printf "       %s\n", $6 }'
	else
		echo -e "  ${RED}❌ 无法完成测试: $(ocp_field "$out" ERROR)${NC}"
	fi
	prompt_with_default "按回车继续" "" _
}

oc_model_remove() {
	local out list kind id
	out=$(ocp status 2>/dev/null)
	list=$(printf '%s\n' "$out" | awk -F '\t' '$1=="PROFILE" { print "删除凭据 " $2 } $1=="PROVIDER" { print "删除 Provider 配置 " $2 }')
	[ -n "$list" ] || { echo -e "  ${YELLOW}没有可删除的凭据或 Provider${NC}"; return 1; }
	oc_pick_from_list "$list" "删除凭据 / Provider" || return 1
	id="${OC_PICKED##* }"
	case "$OC_PICKED" in 删除凭据*) kind=auth ;; *) kind=prov ;; esac
	echo -e "  ${RED}将删除 ${id}，此操作不可撤销。${NC}"
	prompt_with_default "确认删除? (yes/no)" "no" _yn
	[ "$_yn" = "yes" ] || { echo -e "  ${CYAN}已取消${NC}"; return 1; }
	if [ "$kind" = "auth" ]; then ocp_report "$(ocp remove-auth "$id")" "已删除"
	else ocp_report "$(ocp remove-provider "$id")" "已删除"; fi
}

configure_model() {
	local choice changed
	while true; do
		changed=0
		echo ""
		echo -e "  ${BOLD}🤖 AI 模型配置${NC}"
		local cur; cur=$(oc_current_model)
		if [ -n "$cur" ]; then echo -e "  ${GREEN}当前默认模型: ${cur}${NC}"; else echo -e "  ${YELLOW}尚未设置默认模型${NC}"; fi
		oc_verify_line
		echo ""
		echo -e "  ${GREEN}${BOLD}── 快速配置 ──${NC}"
		echo -e "  ${CYAN}q)${NC} 常用 Provider 快速配置  ${GREEN}(推荐)${NC}"
		echo -e "  ${BOLD}── 按类别添加 ──${NC}"
		echo -e "  ${CYAN}1)${NC} 官方 API (按量付费)"
		echo -e "  ${CYAN}2)${NC} 订阅套餐 / Coding Plan / 账号登录"
		echo -e "  ${CYAN}3)${NC} 聚合平台 / 自定义 API"
		echo -e "  ${CYAN}4)${NC} 本地 / 局域网模型"
		echo -e "  ${BOLD}── 模型管理 ──${NC}"
		echo -e "  ${CYAN}5)${NC} 查看模型与认证状态"
		echo -e "  ${CYAN}6)${NC} 切换默认模型"
		echo -e "  ${CYAN}7)${NC} 管理备用模型 (fallback)"
		echo -e "  ${CYAN}8)${NC} 连通性测试 (真实请求，验证账号能否调用)"
		echo -e "  ${CYAN}9)${NC} 删除凭据 / Provider"
		echo -e "  ${BOLD}── 其他 ──${NC}"
		echo -e "  ${CYAN}w)${NC} 官方完整配置向导 (openclaw configure --section model)"
		echo -e "  ${CYAN}0)${NC} 返回"
		echo ""
		prompt_with_default "请选择" "q" choice
		case "$choice" in
			q|Q) oc_pick_method quick && oc_configure_method "$OC_REF" && changed=1 ;;
			1) oc_pick_method official && oc_configure_method "$OC_REF" && changed=1 ;;
			2) oc_pick_method plan && oc_configure_method "$OC_REF" && changed=1 ;;
			3) oc_pick_method aggregator && oc_configure_method "$OC_REF" && changed=1 ;;
			4) oc_pick_method local && oc_configure_method "$OC_REF" && changed=1 ;;
			5) oc_model_status ;;
			6) set_active_model ;;
			7) oc_manage_fallbacks ;;
			8) oc_model_probe ;;
			9) oc_model_remove && changed=1 ;;
			w|W)
				echo ""
				echo -e "  ${CYAN}启动官方完整模型配置向导...${NC}"
				echo -e "  ${YELLOW}提示: ↑↓ 移动, Tab/空格 选中, 回车 确认${NC}"
				enable_auth_plugins
				oc_cmd configure --section model && changed=1
				;;
			0) return 0 ;;
			*) echo -e "  ${YELLOW}无效选择${NC}" ;;
		esac
		[ $changed -eq 1 ] && ask_restart
	done
}

# ══════════════════════════════════════════════════════════════
# 配置 QQ 机器人 (通过 qqbot 插件 @tencent-connect/openclaw-qqbot)
# ══════════════════════════════════════════════════════════════
configure_qq() {
	echo ""
	echo -e "  ${BOLD}🐧 QQ 机器人配置${NC}"
	echo ""

	# 检查 qqbot 插件是否已安装并正常加载
	local plugin_installed=0
	local plugin_blocked=0
	local qqbot_ext_dir="${OC_STATE_DIR}/extensions/openclaw-qqbot"
	if [ -n "$OC_ENTRY" ] && [ -x "$NODE_BIN" ]; then
		local plugin_list=$(oc_cmd plugins list 2>&1)
		# 在表格输出中查找含 qqbot 的行是否也包含 loaded
		if echo "$plugin_list" | grep -i "qqbot" | grep -qi "loaded"; then
			plugin_installed=1
			echo -e "  ${GREEN}✅ qqbot 插件已安装并加载${NC}"
		elif echo "$plugin_list" | grep -qi "plugin not found.*openclaw-qqbot\|suspicious ownership"; then
			# 插件目录存在但被阻止 (权限问题或 stale config)
			if [ -d "$qqbot_ext_dir" ]; then
				plugin_blocked=1
				echo -e "  ${YELLOW}⚠️  qqbot 插件已安装但未能正常加载${NC}"
				echo -e "  ${CYAN}正在修复插件目录权限...${NC}"
				chown -R openclaw:openclaw "$qqbot_ext_dir" 2>/dev/null
				chmod -R 755 "$qqbot_ext_dir" 2>/dev/null
				echo -e "  ${GREEN}✅ 权限已修复，重启 Gateway 后生效${NC}"
				plugin_installed=1
			fi
		elif [ -d "$qqbot_ext_dir" ] && [ -f "${qqbot_ext_dir}/openclaw.plugin.json" ]; then
			# 目录存在、有 plugin.json 但未出现在插件列表 — 修复权限
			echo -e "  ${YELLOW}⚠️  qqbot 插件目录存在但未能加载${NC}"
			echo -e "  ${CYAN}正在修复插件目录权限...${NC}"
			chown -R openclaw:openclaw "$qqbot_ext_dir" 2>/dev/null
			chmod -R 755 "$qqbot_ext_dir" 2>/dev/null
			echo -e "  ${GREEN}✅ 权限已修复${NC}"
			plugin_installed=1
		fi
	fi

	if [ "$plugin_installed" -eq 0 ]; then
		echo -e "  ${YELLOW}⚠️  qqbot 插件尚未安装${NC}"
		echo -e "  QQ 渠道需要先安装 qqbot 插件才能使用。"
		echo ""
		prompt_with_default "是否立即安装 qqbot 插件? (y/n)" "y" install_qqbot
		if confirm_yes "$install_qqbot"; then
			echo -e "  ${CYAN}正在安装 @tencent-connect/openclaw-qqbot ...${NC}"
			echo -e "  ${DIM}(首次安装可能需要几分钟)${NC}"
			local install_out
			install_out=$(oc_cmd plugins install @tencent-connect/openclaw-qqbot@latest 2>&1)
			local install_rc=$?

			# 关键: 保持插件目录权限为 openclaw:openclaw (755)，符合 OpenClaw 上游 discovery 安全校验规则
			# 同时修复权限模式为 755，确保 Gateway 可读取插件
			if [ -d "$qqbot_ext_dir" ]; then
				chown -R openclaw:openclaw "$qqbot_ext_dir" 2>/dev/null
				chmod -R 755 "$qqbot_ext_dir" 2>/dev/null
			fi

			if [ $install_rc -eq 0 ]; then
				echo -e "  ${GREEN}✅ qqbot 插件安装成功${NC}"
				plugin_installed=1
			else
				# 安装命令返回非零，可能是因为 config invalid (死锁)
				# 检查插件目录是否实际已存在 (说明下载成功但校验报错)
				if [ -d "$qqbot_ext_dir" ] && [ -f "${qqbot_ext_dir}/openclaw.plugin.json" ]; then
					echo -e "  ${YELLOW}⚠️  插件已下载但加载校验未通过 (exit: $install_rc)${NC}"
					echo -e "  ${CYAN}这通常是因为配置中已有 qqbot 设置但插件未被信任。${NC}"
					echo -e "  ${CYAN}已自动修复权限，重启 Gateway 后应能正常加载。${NC}"
					plugin_installed=1
				else
					echo -e "  ${RED}❌ 插件安装失败 (exit: $install_rc)${NC}"
					echo -e "  ${DIM}${install_out}${NC}" | tail -5
					echo ""
					echo -e "  ${YELLOW}插件安装失败，但你仍然可以先配置 QQ 机器人参数。${NC}"
					echo -e "  ${YELLOW}稍后可手动安装: openclaw plugins install @tencent-connect/openclaw-qqbot@latest${NC}"
				fi
				echo ""
			fi
			
			# v2026.3.13: 确保插件名称正确写入 plugins.allow
			# OpenClaw 要求 plugins.allow 中的名称必须与实际插件名完全匹配
			if [ "$plugin_installed" -eq 1 ]; then
				ensure_qqbot_plugin_allowed
			fi
		else
			echo -e "  ${YELLOW}已跳过插件安装，继续配置 QQ 机器人参数。${NC}"
			echo -e "  ${CYAN}稍后安装命令: openclaw plugins install @tencent-connect/openclaw-qqbot@latest${NC}"
			echo ""
		fi
	fi

	echo ""
	echo -e "  ${YELLOW}获取 App ID 和 App Secret 步骤:${NC}"
	echo -e "  1. 前往 ${CYAN}QQ 开放平台${NC}: ${CYAN}https://q.qq.com/qqbot/openclaw/login.html${NC}"
	echo -e "  2. 用手机 QQ 扫码注册/登录"
	echo -e "  3. 进入 QQ 机器人页面 → 点击「创建机器人」"
	echo -e "  4. 创建完成后，复制页面中的 ${CYAN}App ID${NC} 和 ${CYAN}App Secret${NC}"
	echo ""
	echo -e "  ${RED}⚠️  注意: App Secret 不支持二次查看（会强制重置），请妥善保存！${NC}"
	echo ""

	local current_appid=$(json_get channels.qqbot.appId)
	if [ -n "$current_appid" ]; then
		echo -e "  ${GREEN}当前已配置 App ID: ${current_appid}${NC}"
	fi

	prompt_with_default "请输入 QQ 机器人 App ID" "" qq_appid
	prompt_with_default "请输入 QQ 机器人 App Secret" "" qq_secret
	qq_appid=$(sanitize_input "$qq_appid" | tr -d '[:space:]')
	qq_secret=$(sanitize_input "$qq_secret" | tr -d '[:space:]')

	if [ -n "$qq_appid" ] && [ -n "$qq_secret" ]; then
		# App ID 应为纯数字
		if ! printf '%s' "$qq_appid" | grep -qE '^[0-9]+$'; then
			echo -e "  ${RED}❌ App ID 格式错误，应为纯数字${NC}"
			return
		fi

		# App Secret 基本格式检查 (非空即可，长度通常 32 位)
		if [ ${#qq_secret} -lt 10 ]; then
			echo -e "  ${YELLOW}⚠️  App Secret 长度过短（${#qq_secret} 字符），请确认是否完整粘贴。${NC}"
			prompt_with_default "是否仍然保存? (y/n)" "n" force_save
			if ! confirm_yes "$force_save"; then
				echo -e "  ${YELLOW}已取消，配置未保存。${NC}"
				return
			fi
		fi

		# 使用 openclaw CLI 一键配置 (推荐方式)
		echo -e "  ${CYAN}正在配置 qqbot 渠道...${NC}"
		local add_out
		add_out=$(oc_cmd channels add --channel qqbot --token "${qq_appid}:${qq_secret}" 2>&1)
		local add_rc=$?

		if [ $add_rc -ne 0 ]; then
			echo -e "  ${YELLOW}CLI 配置未成功，尝试直接写入配置文件...${NC}"
			# 回退: 直接写入 JSON 配置
			json_set channels.qqbot.enabled true
			json_set channels.qqbot.appId "$qq_appid"
			json_set channels.qqbot.clientSecret "$qq_secret"
			chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
		fi

		# 保存后验证
		local saved_appid=$(json_get channels.qqbot.appId)
		if [ -z "$saved_appid" ]; then
			echo -e "  ${RED}❌ 配置保存异常! 请检查配置文件${NC}"
			return
		fi

		echo -e "  ${GREEN}✅ QQ 机器人配置已保存${NC}"
		echo -e "  ${CYAN}   App ID: ${qq_appid}${NC}"
		echo ""
		echo -e "  ${YELLOW}提示:${NC}"
		echo -e "  • 配置完成后需重启 Gateway 使配置生效"
		echo -e "  • 如果机器人回复「该机器人去火星了」，请检查 App ID 和 App Secret 是否正确"
		echo -e "  • 当前不建议将 QQ 机器人添加进 QQ 群聊"
		echo -e "  • 插件升级: ${CYAN}openclaw plugins update openclaw-qqbot${NC}"
		echo ""

		# 重启 Gateway 使配置生效
		ask_restart
	else
		echo -e "  ${YELLOW}信息不完整，已取消。${NC}"
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

		# 重启 Gateway 使 Token 生效 (必须重启，否则 Bot 无法连接 Telegram)
		echo -e "  ${CYAN}正在重启 Gateway 使 Token 生效...${NC}"
		restart_gateway

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
		json_set channels.discord.token "$dc_token"
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

	# 检查 Node.js 是否可用
	if [ ! -x "$NODE_BIN" ]; then
		echo -e "  ${RED}❌ Node.js 不可用，请先安装运行环境${NC}"
		return 1
	fi

	# 检查并安装 Python 3 (飞书插件依赖)
	if ! command -v python3 >/dev/null 2>&1; then
		echo -e "  ${YELLOW}⚠️  飞书插件需要 Python 3 支持${NC}"
		echo -e "  ${CYAN}正在尝试安装 python3-light...${NC}"
		opkg update >/dev/null 2>&1
		# 使用 python3-light 减少安装体积 (约 2MB vs 完整版 30MB+)
		opkg install python3-light 2>&1 | tail -5 || true
		if command -v python3 >/dev/null 2>&1; then
			echo -e "  ${GREEN}✅ Python 3 安装成功${NC}"
		else
			echo -e "  ${RED}❌ Python 3 安装失败${NC}"
			echo -e "  ${YELLOW}请手动安装: opkg install python3-light${NC}"
			echo ""
			prompt_with_default "是否继续尝试安装飞书? (y/n)" "n" continue_install
			if ! confirm_yes "$continue_install"; then
				return 1
			fi
		fi
	fi

	echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
	echo -e "  ${CYAN}飞书官方安装向导${NC}"
	echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
	echo ""
	echo -e "  ${YELLOW}即将执行飞书官方安装命令:${NC}"
	echo -e "  ${CYAN}npx -y @larksuite/openclaw-lark-tools install${NC}"
	echo ""
	echo -e "  ${DIM}安装过程中可以:${NC}"
	echo -e "  ${DIM}  • 新建机器人: 扫描二维码一键创建${NC}"
	echo -e "  ${DIM}  • 关联已有机器人: 输入 App ID 和 App Secret${NC}"
	echo ""
	echo -e "  ${YELLOW}提示: 若命令行出错，可在命令前增加 sudo 重新执行${NC}"
	echo ""

	prompt_with_default "是否开始安装? (y/n)" "y" do_install
	if ! confirm_yes "$do_install"; then
		echo -e "  ${YELLOW}已取消安装${NC}"
		return
	fi

	echo ""
	echo -e "  ${CYAN}正在启动飞书安装向导...${NC}"
	echo ""

	# 执行官方安装命令
	cd "$OC_DATA"
	NPX_BIN="${NODE_BASE}/bin/npx"
	local install_rc=0
	if [ -x "$NPX_BIN" ]; then
		"$NPX_BIN" -y @larksuite/openclaw-lark-tools install || install_rc=$?
	else
		# 如果 npx 不存在，使用 node 运行
		"$NODE_BIN" "$NODE_BASE/lib/node_modules/npm/bin/npx-cli.js" -y @larksuite/openclaw-lark-tools install || install_rc=$?
	fi

	echo ""
	if [ $install_rc -eq 0 ]; then
		echo -e "  ${GREEN}✅ 飞书安装完成！${NC}"
		echo ""
		echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
		echo -e "  ${YELLOW}下一步:${NC}"
		echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
		echo ""
		echo -e "  1. 在飞书中向机器人发送任意消息，即可开始对话"
		echo -e "  2. 发送 ${CYAN}/feishu auth${NC} 完成批量授权"
		echo -e "  3. 发送 ${CYAN}/feishu start${NC} 验证安装是否成功"
		echo -e "  4. 发送 ${CYAN}学习一下我安装的新飞书插件，列出有哪些能力${NC}"
		echo ""
	else
		echo -e "  ${YELLOW}⚠️ 安装向导退出 (exit: $install_rc)${NC}"
		echo ""
		echo -e "  ${CYAN}手动安装命令:${NC}"
		echo -e "  ${CYAN}npx -y @larksuite/openclaw-lark-tools install${NC}"
		echo ""
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
	echo -e "  ${GREEN}║  请在 Telegram 中向 Bot 发送 /start              ║${NC}"
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
			# 逐个处理配对码 (避免管道子 shell 变量丢失问题)
			local _codes_tmp="/tmp/oc_pair_codes_$$"
			echo "$codes" > "$_codes_tmp"
			while IFS= read -r code; do
				[ -z "$code" ] && continue
				echo -e "  ${CYAN}发现配对请求: ${code}${NC}"
				local approve=$(oc_cmd pairing approve telegram "$code" 2>&1)
				if echo "$approve" | grep -qi "approved\|success\|ok"; then
					echo ""
					echo -e "  ${GREEN}${BOLD}🎉 Telegram 配对成功！${NC}"
				fi
			done < "$_codes_tmp"
			rm -f "$_codes_tmp"
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
				paired=1
			else
				echo -e "  ${YELLOW}配对失败: $approve${NC}"
			fi
		fi
	fi

	# 配对成功后重启网关，使配对关系立即生效
	if [ "$paired" -eq 1 ]; then
		echo ""
		echo -e "  ${CYAN}正在重启 Gateway 使配对生效...${NC}"
		restart_gateway
		echo -e "  ${GREEN}✅ 现在可以在 Telegram 中与 Bot 对话了！${NC}"
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
		echo -e "  ${CYAN}提示: 微信配置请使用 LuCI 界面「微信配置」菜单${NC}"
		echo ""
		echo -e "  ${CYAN}1)${NC} QQ 机器人  ${GREEN}(腾讯QQ)${NC}"
		echo -e "  ${CYAN}2)${NC} Telegram  ${GREEN}(最常用)${NC}"
		echo -e "  ${CYAN}3)${NC} Discord"
		echo -e "  ${CYAN}4)${NC} 飞书 (Feishu)"
		echo -e "  ${CYAN}5)${NC} Slack"
		echo -e "  ${CYAN}6)${NC} WhatsApp  ${YELLOW}(需通过 Web 控制台扫码)${NC}"
		echo -e "  ${CYAN}7)${NC} Telegram 配对助手"
		echo -e "  ${CYAN}8)${NC} 官方完整渠道配置向导"
		echo -e "  ${CYAN}0)${NC} 返回主菜单"
		echo ""
		prompt_with_default "请选择" "1" ch_choice

		case "$ch_choice" in
			1) configure_qq ;;
			2) configure_telegram ;;
			3) configure_discord ;;
			4) configure_feishu ;;
			5) configure_slack ;;
			6)
				echo ""
				echo -e "  ${YELLOW}WhatsApp 需要通过 Web 控制台扫码配对:${NC}"
				local gw_token=$(json_get gateway.auth.token)
				local gw_port=$(json_get gateway.port)
				gw_port=${gw_port:-18789}
				echo -e "  ${CYAN}http://<你的路由器IP>:${gw_port}/?token=${gw_token}${NC}"
				echo -e "  打开后进入 Channels → WhatsApp 扫码即可。"
				;;
			7) telegram_pairing ;;
			8)
				echo ""
				echo -e "  ${CYAN}启动官方渠道配置向导...${NC}"
				echo -e "  ${YELLOW}提示: ↑↓ 移动, Tab/空格 选中, 回车 确认${NC}"
				echo ""
				enable_auth_plugins
				if oc_cmd configure --section channels; then
					echo ""
					ask_restart
				else
					echo -e "  ${YELLOW}配置向导已退出${NC}"
				fi
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

	# ── v2026.3.2: 使用官方 config validate 验证配置 ──
	if command -v openclaw >/dev/null 2>&1 || [ -n "$OC_ENTRY" ]; then
		echo -e "  ${CYAN}验证配置文件格式...${NC}"
		local validate_out=""
		validate_out=$(oc_cmd config validate --json 2>/dev/null) || true
		if [ -n "$validate_out" ]; then
			local has_errors=$("$NODE_BIN" -e "
				try{const r=JSON.parse(process.argv[1]);
				if(r.valid===true){console.log('OK');}
				else if(r.errors&&r.errors.length>0){r.errors.forEach(e=>console.log('ERR:'+e.message));}
				else{console.log('OK');}}catch(e){console.log('SKIP');}
			" "$validate_out" 2>/dev/null)
			if [ "$has_errors" = "OK" ]; then
				echo -e "  ${GREEN}✅ 配置文件格式有效${NC}"
			elif [ "$has_errors" = "SKIP" ]; then
				echo -e "  ${YELLOW}⚠️  无法解析验证结果，跳过${NC}"
			else
				echo -e "  ${RED}❌ 配置文件存在错误:${NC}"
				echo "$has_errors" | while IFS= read -r line; do
					echo -e "     ${YELLOW}• ${line#ERR:}${NC}"
				done
			fi
		else
			echo -e "  ${YELLOW}⚠️  config validate 不可用，跳过格式验证${NC}"
		fi
		echo ""
	fi

	# ── 自动修复: 移除旧版错误写入的顶层 models.xxx 无效键 ──
	if [ -f "$CONFIG_FILE" ]; then
		local has_bad_models=$("$NODE_BIN" -e "
			const d=JSON.parse(require('fs').readFileSync('${CONFIG_FILE}','utf8'));
			const m=d.models;
			if(m&&typeof m==='object'){
				const bad=Object.keys(m).filter(k=>['openai','anthropic','google','openrouter','deepseek','github-copilot','dashscope','xai','groq','siliconflow','custom'].includes(k));
				if(bad.length>0){console.log(bad.join(','));}
			}
		" 2>/dev/null)
		if [ -n "$has_bad_models" ]; then
			echo -e "  ${YELLOW}⚠️  检测到旧版配置错误: 顶层 models 包含无效键 (${has_bad_models})${NC}"
			echo -e "  ${CYAN}正在自动修复...${NC}"
			"$NODE_BIN" -e "
				const fs=require('fs');
				const d=JSON.parse(fs.readFileSync('${CONFIG_FILE}','utf8'));
				const bad=['openai','anthropic','google','openrouter','deepseek','github-copilot','dashscope','xai','groq','siliconflow','custom'];
				if(d.models&&typeof d.models==='object'){
					bad.forEach(k=>delete d.models[k]);
					if(Object.keys(d.models).length===0||(Object.keys(d.models).length===1&&d.models.providers)){}
					else if(Object.keys(d.models).filter(k=>k!=='mode'&&k!=='providers').length===0){}
					if(!d.models.providers&&Object.keys(d.models).every(k=>bad.includes(k)||k==='mode'))delete d.models;
				}
				fs.writeFileSync('${CONFIG_FILE}',JSON.stringify(d,null,2));
			" 2>/dev/null
			chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
			echo -e "  ${GREEN}✅ 已移除无效的 models 配置键${NC}"
			echo ""
		fi
	fi

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

	# v2026.3.2: 使用 gateway health --json 做深度健康检查 (HTTP /health 已被 SPA 接管)
	local health_resp=$(oc_cmd gateway health --json 2>/dev/null)
	if [ -n "$health_resp" ]; then
		local health_ok=$("$NODE_BIN" -e "try{const h=JSON.parse(process.argv[1]);console.log(h.ok?'ok':'fail');}catch(e){console.log('parse_error');}" "$health_resp" 2>/dev/null)
		if [ "$health_ok" = "ok" ]; then
			echo -e "  ${GREEN}✅ Gateway 健康检查正常${NC}"
		elif [ "$health_ok" = "parse_error" ]; then
			echo -e "  ${YELLOW}⚠️  Gateway 健康检查响应无法解析${NC}"
		else
			echo -e "  ${YELLOW}⚠️  Gateway 健康检查异常${NC}"
		fi
	fi

	if [ -f "$CONFIG_FILE" ]; then
		echo -e "  ${GREEN}✅ 配置文件存在${NC}"
	else
		echo -e "  ${RED}❌ 配置文件不存在${NC}"
	fi

	echo ""
	echo -e "  ${CYAN}运行官方诊断...${NC}"
	oc_doctor_as_openclaw 2>/dev/null || true

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
				# 凭据保存在上游认证库 (state/openclaw.sqlite)，通过官方 logout 逐条注销；
				# auth-profiles.json 已在 2026.9.x 退役，不再读写
				ocp status 2>/dev/null | awk -F '\t' '$1=="PROFILE" { print $2 }' | while read -r _pid; do
					[ -n "$_pid" ] || continue
					ocp remove-auth "$_pid" | grep -q '^OK' || echo -e "  ${YELLOW}凭据 ${_pid} 未能注销${NC}"
				done
				echo -e "  ${GREEN}✅ 模型配置已清除${NC}"
				echo -e "  ${YELLOW}请通过菜单 [1] 重新配置 AI 模型${NC}"
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
				# 清除 openclaw.json 中的 channels 配置
				oc_cmd config unset channels >/dev/null 2>&1 || true
				
				# v2026.3.14: 同时清除 plugins 中与渠道相关的配置
				# 防止重置后插件配置残留导致状态不一致
				if [ -f "$CONFIG_FILE" ] && [ -x "$NODE_BIN" ]; then
					"$NODE_BIN" -e "
						const fs=require('fs');
						try{
							const d=JSON.parse(fs.readFileSync('${CONFIG_FILE}','utf8'));
							let modified=false;
							
							// 清除 plugins.entries 中与消息渠道相关的插件
							if(d.plugins && d.plugins.entries){
								const channelPlugins=['openclaw-qqbot','@tencent-connect/openclaw-qqbot','openclaw-lark','@larksuite/openclaw-lark'];
								channelPlugins.forEach(p=>{
									if(d.plugins.entries[p]){
										delete d.plugins.entries[p];
										modified=true;
									}
								});
							}
							
							// 清除 plugins.allow 中的渠道插件
							if(Array.isArray(d.plugins && d.plugins.allow)){
								const beforeLen=d.plugins.allow.length;
								d.plugins.allow=d.plugins.allow.filter(p=>
									!p.includes('qqbot') && 
									!p.includes('lark') && 
									!p.includes('telegram') &&
									!p.includes('discord') &&
									!p.includes('slack') &&
									!p.includes('whatsapp')
								);
								if(d.plugins.allow.length!==beforeLen)modified=true;
							}
							
							if(modified){
								fs.writeFileSync('${CONFIG_FILE}',JSON.stringify(d,null,2));
								console.log('CLEANED');
							}
						}catch(e){}
					" 2>/dev/null
					chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
				fi
				
				# 清除飞书扩展目录中的敏感数据 (保留插件本体)
				local feishu_ext_dir="${OC_STATE_DIR}/extensions/openclaw-lark"
				if [ -d "$feishu_ext_dir" ]; then
					# 只清除配置文件，保留插件代码
					rm -f "${feishu_ext_dir}/.credentials"* 2>/dev/null
					rm -f "${feishu_ext_dir}/config.json" 2>/dev/null
					rm -rf "${feishu_ext_dir}/.cache" 2>/dev/null
					echo -e "  ${CYAN}已清理飞书插件缓存数据${NC}"
				fi
				
				# 清除 QQ 机器人扩展目录中的敏感数据
				local qqbot_ext_dir="${OC_STATE_DIR}/extensions/openclaw-qqbot"
				if [ -d "$qqbot_ext_dir" ]; then
					rm -f "${qqbot_ext_dir}/credentials"* 2>/dev/null
					rm -f "${qqbot_ext_dir}/config.json" 2>/dev/null
				fi
				
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
				chown openclaw:openclaw "$backup_dir" 2>/dev/null || true
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
				# 尝试 onboard (非交互、跳过认证与渠道)，带超时避免阻塞
				local _ob_args="--non-interactive --accept-risk --mode local --auth-choice skip --gateway-bind lan --gateway-port 18789 --skip-daemon --skip-health --skip-channels --skip-skills --skip-search --skip-hooks"
				local _node_bin
				_node_bin=$(which node 2>/dev/null || echo "$NODE_BIN")
				if command -v timeout >/dev/null 2>&1; then
					timeout 60 "$_node_bin" "$OC_ENTRY" onboard $_ob_args >/dev/null 2>&1 || true
				else
					"$_node_bin" "$OC_ENTRY" onboard $_ob_args >/dev/null 2>&1 &
					local _ob_pid=$!
					sleep 10
					kill "$_ob_pid" 2>/dev/null || true
					wait "$_ob_pid" 2>/dev/null || true
				fi
				echo -e "  ${GREEN}   初始化完成${NC}"

				echo -e "  ${CYAN}[5/5] 应用 OpenWrt 适配配置...${NC}"
				local new_token
				new_token=$(head -c 24 /dev/urandom | hexdump -e '24/1 "%02x"' 2>/dev/null || dd if=/dev/urandom bs=24 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 48)
				json_set gateway.port 18789
				json_set gateway.bind lan
				json_set gateway.mode local
				json_set gateway.auth.mode token
				json_set gateway.auth.token "$new_token"
				json_set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true
				json_set gateway.tailscale.mode off
				json_set acp.dispatch.enabled false
				json_set tools.profile coding

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
# ══════════════════════════════════════════════════════════════
# 备份/还原配置菜单 (v2026.3.8+ openclaw backup create/verify)
# ══════════════════════════════════════════════════════════════
backup_restore_menu() {
	echo ""
	echo -e "  ${BOLD}💾 备份/还原配置${NC}"
	echo ""
	echo -e "  ${CYAN}1)${NC} 创建配置备份 (仅配置文件)"
	echo -e "  ${CYAN}2)${NC} 创建完整备份 (配置 + 状态数据)"
	echo -e "  ${CYAN}3)${NC} 验证最新备份"
	echo -e "  ${CYAN}4)${NC} 查看备份列表"
	echo -e "  ${CYAN}5)${NC} 从最新备份恢复配置"
	echo -e "  ${CYAN}0)${NC} 返回主菜单"
	echo ""
	prompt_with_default "请选择" "1" backup_choice

	# 备份目录 (必须位于 State 目录之外，避免归档递归)
	local backup_dir="${OPENCLAW_BACKUP_DIR:-${OC_DATA}/backups}"
	mkdir -p "$backup_dir" 2>/dev/null

	local state_helper="/usr/libexec/openclaw-upgrade-state.sh"
	[ -x "$state_helper" ] || state_helper="${_script_dir}/../libexec/openclaw-upgrade-state.sh"
	[ -x "$state_helper" ] || state_helper="./root/usr/libexec/openclaw-upgrade-state.sh"

	case "$backup_choice" in
		1)
			echo -e "  ${CYAN}正在创建配置备份...${NC}"
			local out
			out=$(cd "$backup_dir" && oc_cmd backup create --only-config --no-include-workspace 2>&1)
			local rc=$?
			echo "$out"
			if [ $rc -eq 0 ] && echo "$out" | grep -q "\.tar\.gz"; then
				echo -e "  ${GREEN}✅ 配置备份已创建${NC}"
			else
				echo -e "  ${YELLOW}⚠️  备份功能需要 OpenClaw v2026.3.8+${NC}"
				echo -e "  ${DIM}如果备份命令不可用，可手动备份: cp ${CONFIG_FILE} ${CONFIG_FILE}.bak${NC}"
			fi
			;;
		2)
			echo -e "  ${CYAN}正在创建完整备份...${NC}"
			echo -e "  ${DIM}(包含配置和状态数据，可能需要较长时间)${NC}"
			local out rc=0
			if [ -x "$state_helper" ]; then
				out=$("$state_helper" backup-create "$backup_dir" "$OC_STATE_DIR" 2>&1) || rc=$?
			else
				out=$(cd "$backup_dir" && HOME="$backup_dir" oc_cmd backup create --no-include-workspace 2>&1) || rc=$?
				for f in "${OC_DATA}"/*-openclaw-backup.tar.gz; do
					[ -f "$f" ] && mv "$f" "$backup_dir/" 2>/dev/null
				done
			fi
			echo "$out"
			if [ $rc -eq 0 ] && echo "$out" | grep -q "\.tar\.gz"; then
				echo -e "  ${GREEN}✅ 完整备份已创建${NC}"
			else
				echo -e "  ${YELLOW}⚠️  备份失败${NC}"
				echo -e "  ${DIM}提示: 如果配置文件有校验警告，完整备份可能受限。请使用选项 1 (仅配置文件) 备份${NC}"
			fi
			;;
		3)
			local latest=$(ls -t "${backup_dir}"/*-openclaw-backup.tar.gz "${backup_dir}"/*.tar.gz 2>/dev/null | head -1)
			if [ -z "$latest" ]; then
				# 也检查旧位置
				latest=$(ls -t "${OC_STATE_DIR}/backups"/*-openclaw-backup.tar.gz "${OC_STATE_DIR}"/*-openclaw-backup.tar.gz "${OC_DATA}"/*-openclaw-backup.tar.gz 2>/dev/null | head -1)
			fi
			if [ -z "$latest" ]; then
				echo -e "  ${YELLOW}未找到备份文件，请先创建备份${NC}"
			else
				echo -e "  ${CYAN}验证备份: ${latest}${NC}"
				if [ -x "$state_helper" ]; then
					"$state_helper" backup-verify "$latest" "$OC_STATE_DIR" 2>&1
				else
					oc_cmd backup verify "$latest" 2>&1
				fi
			fi
			;;
		4)
			echo ""
			if [ -d "$backup_dir" ]; then
				local count=$(ls "${backup_dir}"/*-openclaw-backup.tar.gz "${backup_dir}"/*.tar.gz 2>/dev/null | wc -l)
				if [ "$count" -gt 0 ] 2>/dev/null; then
					echo -e "  ${BOLD}备份文件列表:${NC}"
					ls -lh "${backup_dir}"/*-openclaw-backup.tar.gz "${backup_dir}"/*.tar.gz 2>/dev/null | while read line; do
						echo -e "  ${DIM}${line}${NC}"
					done
				else
					echo -e "  ${YELLOW}暂无备份文件${NC}"
				fi
			else
				echo -e "  ${YELLOW}暂无备份文件${NC}"
			fi
			echo ""
			echo -e "  ${DIM}备份目录: ${backup_dir}${NC}"
			;;
		5)
			local latest=$(ls -t "${backup_dir}"/*-openclaw-backup.tar.gz "${backup_dir}"/*.tar.gz 2>/dev/null | head -1)
			if [ -z "$latest" ]; then
				echo -e "  ${YELLOW}未找到备份文件，请先创建备份${NC}"
			else
				echo -e "  ${CYAN}将从以下备份恢复:${NC}"
				echo -e "  ${DIM}${latest}${NC}"
				echo ""
				echo -e "  ${YELLOW}⚠️  这会还原备份中的所有配置和数据文件到原路径！${NC}"
				prompt_with_default "确认恢复? (y/N)" "N" confirm_restore
				if [ "$confirm_restore" = "y" ] || [ "$confirm_restore" = "Y" ]; then
					echo -e "  ${DIM}正在安全还原 State 状态...${NC}"
					/etc/init.d/openclaw stop >/dev/null 2>&1 || true
					sleep 2
					local restore_ok=0
					if [ -x "$state_helper" ]; then
						if "$state_helper" restore-state "$latest" "$OC_STATE_DIR" 2>&1; then
							restore_ok=1
						fi
					else
						# 兜底旧逻辑
						local backup_name=$(tar -tzf "$latest" 2>/dev/null | head -1 | cut -d/ -f1)
						if [ -n "$backup_name" ]; then
							tar -xzf "$latest" --strip-components=3 -C / "${backup_name}/payload/posix/" 2>&1 && restore_ok=1
						fi
					fi
					if [ "$restore_ok" -eq 1 ]; then
						fix_openclaw_state_permissions 2>/dev/null || true
						echo -e "  ${GREEN}✅ 配置和数据已完整恢复！${NC}"
						echo ""
						prompt_with_default "是否重启服务使配置生效? (Y/n)" "Y" do_restart
						if [ "$do_restart" != "n" ] && [ "$do_restart" != "N" ]; then
							restart_gateway
						fi
					else
						echo -e "  ${RED}❌ 恢复失败，已安全保留原状态与备份${NC}"
					fi
				else
					echo -e "  ${DIM}已取消${NC}"
				fi
			fi
			;;
		0|"") return ;;
		*) echo -e "  ${YELLOW}无效选择${NC}" ;;
	esac
}

# ══════════════════════════════════════════════════════════════════════════
# 交互式菜单 (方向键导航)
# ══════════════════════════════════════════════════════════════════════════

# 检测是否支持交互模式 (需要 Node.js + TTY 终端)
can_use_interactive() {
	[ -x "$NODE_BIN" ] || return 1
	[ -f "$OC_INTERACTIVE" ] || return 1
	[ -f "$OC_MENU_ENGINE" ] || return 1
	# 检测是否为真实 TTY (排除某些非交互环境)
	[ -t 0 ] && [ -t 1 ] || return 1
	return 0
}

# 启动交互式菜单 (方向键导航版本)
launch_interactive_menu() {
	if ! can_use_interactive; then
		echo -e "  ${YELLOW}⚠️ 当前环境不支持交互模式，使用传统菜单${NC}"
		return 1
	fi

	# 调用 Node.js 交互式前端
	"$NODE_BIN" "$OC_INTERACTIVE" 2>&1
	local rc=$?

	fix_openclaw_state_permissions 2>/dev/null || true
	# 返回后刷新配置权限
	chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
	return $rc
}

# 启动交互式模型配置
launch_interactive_model_config() {
	if ! can_use_interactive; then
		echo -e "  ${YELLOW}⚠️ 当前环境不支持交互模式，使用传统菜单${NC}"
		configure_model  # 回退到传统菜单
		return $?
	fi

	# 调用 Node.js 交互式前端的模型配置模块
	"$NODE_BIN" "$OC_INTERACTIVE" model 2>&1
	local rc=$?

	fix_openclaw_state_permissions 2>/dev/null || true
	chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
	return $rc
}

# ── 设备配对管理 (Control UI / 浏览器配对审批) ──
devices_pairing_menu() {
	while true; do
		echo ""
		echo -e "  ${BOLD}📱 设备配对管理 (Control UI / 浏览器配对审批)${NC}"
		echo ""
		echo -e "  ${YELLOW}⚠️  风险提示：${NC}"
		echo -e "  ${YELLOW}   批准设备配对后，该浏览器/客户端将获得 OpenClaw 网关的完全控制权限。${NC}"
		echo -e "  ${YELLOW}   请确保在受信任的局域网环境，并仅在您本人正在连接时批准！${NC}"
		echo ""

		local list_json
		list_json=$(oc_cmd devices list --json 2>/dev/null || echo "")
		local pending_count=0
		local parsed=""

		if [ -n "$list_json" ] && [ -x "$NODE_BIN" ]; then
			parsed=$("$NODE_BIN" -e '
				let data = null;
				try {
					data = JSON.parse(process.argv[1]);
				} catch (_) {
					const m = (process.argv[1] || "").match(/(\{[\s\S]*"pending"[\s\S]*\})/);
					if (m) {
						try { data = JSON.parse(m[1]); } catch (_) {}
					}
				}
				const pending = (data && Array.isArray(data.pending)) ? data.pending : [];
				console.log("COUNT=" + pending.length);
				pending.forEach((item) => {
					const rid = item.requestId || "";
					const ip = item.remoteIp || item.ip || "未知IP";
					const client = item.clientId || item.clientMode || "webchat";
					const plat = item.platform || "";
					const role = item.role || (item.roles && item.roles.join(",")) || "operator";
					console.log("ITEM\t" + rid + "\t" + ip + "\t" + client + "\t" + plat + "\t" + role);
				});
			' "$list_json" 2>/dev/null || echo "COUNT=0")
			pending_count=$(echo "$parsed" | grep '^COUNT=' | cut -d= -f2)
			pending_count=${pending_count:-0}
		fi

		if [ "$pending_count" -gt 0 ]; then
			echo -e "  ${GREEN}🔔 当前检测到 ${pending_count} 个待配对请求：${NC}"
			echo ""
			local idx=1
			echo "$parsed" | grep '^ITEM' | while IFS="$(printf '\t')" read -r _ rid ip client plat role; do
				echo -e "    ${CYAN}[$idx]${NC} 请求 ID: ${BOLD}${rid}${NC}"
				echo -e "        来源 IP: ${GREEN}${ip}${NC} | 客户端: ${client} (${plat}) | 角色: ${role}"
				idx=$((idx + 1))
			done
			echo ""
			echo -e "  ${CYAN}1)${NC} ⚡ 一键批准所有待配对请求"
			echo -e "  ${CYAN}2)${NC} 🔍 选择指定请求批准"
			echo -e "  ${CYAN}3)${NC} 🔄 刷新待配对列表"
			echo -e "  ${CYAN}0)${NC} 返回上级菜单"
			echo ""
			prompt_with_default "请选择" "1" dev_choice

			case "$dev_choice" in
				1)
					echo ""
					echo -e "  ${CYAN}正在批准所有设备配对请求...${NC}"
					echo "$parsed" | grep '^ITEM' | cut -f2 | tr -d '\r' | while read -r rid; do
						if [ -n "$rid" ]; then
							local out
							out=$(oc_cmd devices approve "$rid" 2>&1)
							if echo "$out" | grep -qiE 'approved|success'; then
								echo -e "  ${GREEN}✅ 已批准: ${rid}${NC}"
							else
								echo -e "  ${YELLOW}⚠️ 批准结果: ${out}${NC}"
							fi
						fi
					done
					fix_openclaw_state_permissions
					echo ""
					prompt_with_default "按回车继续" "" _
					;;
				2)
					echo ""
					prompt_with_default "请输入要批准的请求编号 (1-${pending_count}) 或直接输入 Request ID" "1" pick_val
					local target_id=""
					case "$pick_val" in
						''|0|*[!0-9]*) target_id="$pick_val" ;;
						*)
							if [ "$pick_val" -ge 1 ] 2>/dev/null && [ "$pick_val" -le "$pending_count" ] 2>/dev/null; then
								target_id=$(echo "$parsed" | grep '^ITEM' | sed -n "${pick_val}p" | cut -f2 | tr -d '\r')
							else
								target_id="$pick_val"
							fi
							;;
					esac
					if [ -n "$target_id" ]; then
						echo ""
						echo -e "  ${CYAN}正在批准请求: ${target_id}...${NC}"
						local out
						out=$(oc_cmd devices approve "$target_id" 2>&1)
						if echo "$out" | grep -qiE 'approved|success'; then
							echo -e "  ${GREEN}✅ 批准成功: ${target_id}${NC}"
						else
							echo -e "  ${YELLOW}⚠️ 批准结果: ${out}${NC}"
						fi
						fix_openclaw_state_permissions
					else
						echo -e "  ${YELLOW}未找到对应请求${NC}"
					fi
					echo ""
					prompt_with_default "按回车继续" "" _
					;;
				3) ;;
				0) return 0 ;;
				*) echo -e "  ${YELLOW}无效选择${NC}" ;;
			esac
		else
			echo -e "  ${DIM}当前无待配对设备请求。${NC}"
			echo -e "  ${DIM}(在浏览器访问 OpenClaw Web 控制台时若提示「需要设备配对」，在此处刷新即可发现)${NC}"
			echo ""
			echo -e "  ${CYAN}1)${NC} 🔄 刷新待配对列表"
			echo -e "  ${CYAN}2)${NC} ⌨️ 手动输入 Request ID 批准"
			echo -e "  ${CYAN}3)${NC} 📋 查看完整设备列表 (含已配对)"
			echo -e "  ${CYAN}0)${NC} 返回上级菜单"
			echo ""
			prompt_with_default "请选择" "1" dev_choice

			case "$dev_choice" in
				1) ;;
				2)
					echo ""
					prompt_with_default "请输入待批准的 Request ID" "" manual_rid
					if [ -n "$manual_rid" ]; then
						echo ""
						local out
						out=$(oc_cmd devices approve "$manual_rid" 2>&1)
						if echo "$out" | grep -qiE 'approved|success'; then
							echo -e "  ${GREEN}✅ 批准成功: ${manual_rid}${NC}"
						else
							echo -e "  ${YELLOW}⚠️ 批准结果: ${out}${NC}"
						fi
						fix_openclaw_state_permissions
						echo ""
						prompt_with_default "按回车继续" "" _
					fi
					;;
				3)
					echo ""
					echo -e "  ${CYAN}=== 设备列表 ===${NC}"
					oc_cmd devices list 2>&1 || echo "  (无法获取设备列表)"
					echo ""
					prompt_with_default "按回车继续" "" _
					;;
				0) return 0 ;;
				*) echo -e "  ${YELLOW}无效选择${NC}" ;;
			esac
		fi
	done
}

main_menu() {
	# 直接启动交互模式 (如果支持)
	if can_use_interactive && [ "${OC_FORCE_TRADITIONAL:-0}" != "1" ]; then
		launch_interactive_menu
		return $?
	fi

	# 传统菜单 (回退方案)
	while true; do
		echo ""
		echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
		echo -e "${GREEN}║${NC}           ${BOLD}OpenClaw AI Gateway — OpenWrt 配置管理${NC}             ${GREEN}║${NC}"
		echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
		echo ""
		echo -e "  ${DIM}━━━ AI 模型配置 ━━━${NC}"
		echo -e "  ${CYAN}1)${NC} 🤖 配置 AI 模型和提供商"
		echo -e "  ${CYAN}2)${NC} 🎯 设置活动模型"
		echo ""
		echo -e "  ${DIM}━━━ 消息渠道 ━━━${NC}"
		echo -e "  ${CYAN}3)${NC} 📡 配置消息渠道 (电报/QQ/飞书)"
		echo ""
		echo -e "  ${DIM}━━━ 系统管理 ━━━${NC}"
		echo -e "  ${CYAN}4)${NC} 🩺 健康检查与状态"
		echo -e "  ${CYAN}5)${NC} 📋 查看日志"
		echo -e "  ${CYAN}6)${NC} 🔄 重启 Gateway"
		echo -e "  ${CYAN}7)${NC} 📱 设备配对管理 (Control UI 审批)"
		echo ""
		echo -e "  ${DIM}━━━ 高级选项 ━━━${NC}"
		echo -e "  ${CYAN}8)${NC} 🔧 高级配置"
		echo -e "  ${CYAN}9)${NC} ♻️ 重置配置"
		echo -e "  ${CYAN}10)${NC} 📊 显示当前配置概览"
		echo ""
		echo -e "  ${CYAN}0)${NC} 退出"
		echo ""
		prompt_with_default "请选择" "1" menu_choice

		case "$menu_choice" in
			1) configure_model ;;
			2) set_active_model ;;
			3) configure_channels ;;
			4) health_check ;;
			5)
				echo ""
				echo -e "  ${CYAN}=== OpenClaw 日志 ===${NC}"
				echo ""
				logread -e openclaw 2>/dev/null | tail -100 || echo "  (无法读取日志)"
				echo ""
				prompt_with_default "按回车继续" "" _
				;;
			6) restart_gateway ;;
			7) devices_pairing_menu ;;
			8) advanced_menu ;;
			9) reset_to_defaults ;;
			10) show_current_config ;;
			0)
				echo -e "  ${GREEN}再见！${NC}"
				exit 0
				;;
			*) echo -e "  ${YELLOW}无效选择${NC}" ;;
		esac
	done
}

# ── 高级配置菜单 ──
advanced_menu() {
	while true; do
		local gw_port gw_bind gw_mode log_level acp_dispatch
		gw_port=$(json_get "gateway.port" 2>/dev/null || echo "18789")
		gw_bind=$(json_get "gateway.bind" 2>/dev/null || echo "lan")
		gw_mode=$(json_get "gateway.mode" 2>/dev/null || echo "local")
		# 读 logging.level (正确键)；兼容旧配置里残留的 gateway.logLevel 以便显示
		log_level=$(json_get "logging.level" 2>/dev/null || echo "")
		[ -n "$log_level" ] || log_level=$(json_get "gateway.logLevel" 2>/dev/null || echo "")
		acp_dispatch=$(json_get "acp.dispatch.enabled" 2>/dev/null || echo "false")

		echo ""
		echo -e "  ${BOLD}🔧 高级配置${NC}"
		echo ""
		echo -e "  ${CYAN}1)${NC} Gateway 端口  ${DIM}(当前: ${gw_port})${NC}"
		echo -e "  ${CYAN}2)${NC} Gateway 绑定地址  ${DIM}(当前: ${gw_bind})${NC}"
		echo -e "  ${CYAN}3)${NC} Gateway 运行模式  ${DIM}(当前: ${gw_mode})${NC}"
		echo -e "  ${CYAN}4)${NC} 日志级别  ${DIM}(当前: ${log_level:-未设置})${NC}"
		echo -e "  ${CYAN}5)${NC} ACP Dispatch 设置  ${DIM}(当前: ${acp_dispatch})${NC}"
		echo -e "  ${CYAN}6)${NC} 官方完整配置向导  ${DIM}(oc configure)${NC}"
		echo -e "  ${CYAN}7)${NC} 查看原始配置 JSON"
		echo -e "  ${CYAN}8)${NC} 编辑配置文件  ${DIM}(vi / nano)${NC}"
		echo -e "  ${CYAN}9)${NC} 导出配置备份"
		echo -e "  ${CYAN}10)${NC} 导入配置"
		echo -e "  ${CYAN}11)${NC} 📱 设备配对管理"
		echo -e "  ${CYAN}0)${NC} 返回主菜单"
		echo ""
		prompt_with_default "请选择" "0" adv_choice

		case "$adv_choice" in
			1)
				echo ""
				prompt_with_default "请输入 Gateway 端口" "$gw_port" new_port
				if [ -n "$new_port" ] && [ "$new_port" != "$gw_port" ]; then
					# 端口必须是 1-65535 的整数，先自行校验再写入，
					# 避免把非法值交给 json_set 后只得到一条底层报错。
					case "$new_port" in
						''|*[!0-9]*)
							echo -e "  ${YELLOW}无效端口: 必须是数字${NC}"
							;;
						*)
							if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
								echo -e "  ${YELLOW}无效端口: 需在 1-65535 之间${NC}"
							elif json_set "gateway.port" "$new_port"; then
								# 仅在 JSON 写入成功后才同步 UCI，避免两边不一致
								uci set openclaw.main.port="$new_port" 2>/dev/null
								uci commit openclaw 2>/dev/null
								echo -e "  ${GREEN}✅ 端口已设置为 ${new_port}${NC}"
								ask_restart
							fi
							;;
					esac
				fi
				;;
			2)
				echo ""
				# 取值必须与 OpenClaw schema 的 gateway.bind 枚举一致:
				# auto/lan/loopback/custom/tailnet。历史上这里提供的 all
				# 不被上游接受 (实测: gateway.bind: Invalid input)，
				# 想监听所有接口应使用 custom + customBindHost。
				echo -e "  ${CYAN}绑定地址选项:${NC}"
				echo "    lan      - 仅 LAN 接口 (推荐)"
				echo "    loopback - 仅本机访问"
				echo "    auto     - 自动选择"
				echo "    custom   - 自定义地址 (可配合 0.0.0.0 监听所有接口)"
				echo "    tailnet  - Tailscale 网络"
				echo ""
				prompt_with_default "请输入绑定地址" "$gw_bind" new_bind
				if [ -n "$new_bind" ]; then
					# 兼容旧值: 用户/旧配置里的 all 等价于 custom + 0.0.0.0
					if [ "$new_bind" = "all" ]; then
						echo -e "  ${YELLOW}提示: OpenClaw 已不接受 all，已改用 custom + 0.0.0.0${NC}"
						new_bind="custom"
						json_set "gateway.customBindHost" "0.0.0.0" || true
					fi
					case "$new_bind" in
						auto|lan|loopback|custom|tailnet)
							if json_set "gateway.bind" "$new_bind"; then
								uci set openclaw.main.bind="$new_bind" 2>/dev/null
								uci commit openclaw 2>/dev/null
								echo -e "  ${GREEN}✅ 绑定地址已设置为 ${new_bind}${NC}"
								ask_restart
							fi
							;;
						*) echo -e "  ${YELLOW}无效选项 (允许: auto/lan/loopback/custom/tailnet)${NC}" ;;
					esac
				fi
				;;
			3)
				echo ""
				echo -e "  ${CYAN}运行模式选项:${NC}"
				echo "    local  - 本地模式 (推荐)"
				echo "    remote - 远程模式"
				echo ""
				prompt_with_default "请输入运行模式" "$gw_mode" new_mode
				if [ -n "$new_mode" ] && [ "$new_mode" != "$gw_mode" ]; then
					if json_set "gateway.mode" "$new_mode"; then
						echo -e "  ${GREEN}✅ 运行模式已设置为 ${new_mode}${NC}"
						ask_restart
					fi
				fi
				;;
			4)
				echo ""
				# 正确键是顶层 logging.level。gateway.logLevel 不存在于
				# OpenClaw schema (gateway.additionalProperties=false)，
				# 实测 config set 报 Unrecognized key，手写进文件则被静默忽略，
				# 表现为"界面显示已设置但从未生效"。
				echo -e "  ${CYAN}日志级别选项:${NC}"
				echo "    silent, fatal, error, warn, info, debug, trace"
				echo ""
				prompt_with_default "请输入日志级别" "${log_level:-info}" new_level
				if [ -n "$new_level" ]; then
					if json_set "logging.level" "$new_level"; then
						echo -e "  ${GREEN}✅ 日志级别已设置为 ${new_level}${NC}"
						ask_restart
					fi
				fi
				;;
			5)
				echo ""
				echo -e "  ${CYAN}ACP Dispatch 选项:${NC}"
				echo "    true  - 启用 (可能占用大量内存)"
				echo "    false - 禁用 (推荐路由器使用)"
				echo ""
				prompt_with_default "请输入设置" "$acp_dispatch" new_acp
				case "$new_acp" in
					true|false)
						if json_set "acp.dispatch.enabled" "$new_acp"; then
							echo -e "  ${GREEN}✅ ACP Dispatch 已设置为 ${new_acp}${NC}"
							ask_restart
						fi
						;;
					*) echo -e "  ${YELLOW}无效选项 (只接受 true / false)${NC}" ;;
				esac
				;;
			6)
				echo ""
				echo -e "  ${CYAN}启动官方配置向导...${NC}"
				echo -e "  ${YELLOW}提示: ↑↓ 移动, Tab/空格 选中, 回车 确认${NC}"
				echo ""
				enable_auth_plugins
				if oc_cmd configure; then
					echo ""
					ask_restart
				else
					echo -e "  ${YELLOW}配置向导已退出${NC}"
				fi
				;;
			7)
				echo ""
				echo -e "  ${CYAN}配置文件路径: ${CONFIG_FILE}${NC}"
				echo ""
				if [ -f "$CONFIG_FILE" ]; then
					"$NODE_BIN" -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync('${CONFIG_FILE}','utf8')),null,2))" 2>/dev/null || cat "$CONFIG_FILE"
				else
					echo "  (配置文件不存在)"
				fi
				echo ""
				prompt_with_default "按回车继续" "" _
				;;
			8)
				echo ""
				if [ -f "$CONFIG_FILE" ]; then
					vi "$CONFIG_FILE"
					ask_restart
				else
					echo -e "  ${YELLOW}配置文件不存在${NC}"
				fi
				;;
			9) backup_restore_menu ;;
			10)
				echo ""
				echo -e "  ${CYAN}导入配置${NC}"
				echo ""
				local backup_dir="${OC_STATE_DIR}/backups"
				if [ -d "$backup_dir" ]; then
					echo "  可用备份:"
					ls -lt "$backup_dir"/*.json 2>/dev/null | head -5 | while read -r line; do
						echo "    $(echo "$line" | awk '{print $NF}')"
					done
				fi
				echo ""
				prompt_with_default "请输入备份文件路径" "" import_path
				if [ -n "$import_path" ] && [ -f "$import_path" ]; then
					cp "$import_path" "$CONFIG_FILE"
					chown openclaw:openclaw "$CONFIG_FILE"
					echo -e "  ${GREEN}✅ 配置已导入${NC}"
					ask_restart
				else
					echo -e "  ${YELLOW}文件不存在${NC}"
				fi
				;;
			11) devices_pairing_menu ;;
			0) return ;;
			*) echo -e "  ${YELLOW}无效选择${NC}" ;;
		esac
	done
}

# ── 支持命令行参数 ──
case "${1:-}" in
	--tui|--interactive)
		# 强制启动交互式菜单 (方向键导航)
		if can_use_interactive; then
			launch_interactive_menu
		else
			echo -e "${YELLOW}⚠️ 当前环境不支持交互模式${NC}"
			echo "需要: Node.js + TTY 终端"
			exit 1
		fi
		;;
	--traditional)
		# 强制使用传统菜单
		export OC_FORCE_TRADITIONAL=1
		main_menu
		;;
	--model)
		# 直接进入模型配置
		if can_use_interactive; then
			launch_interactive_model_config
		else
			configure_model
		fi
		;;
	--set)
		if [ -n "${2:-}" ] && [ -n "${3:-}" ]; then
			# 必须检查 json_set 的返回码: 类型/枚举校验失败或配置损坏时
			# 写入会被拒绝，此时不能再报告成功 (否则就是"界面显示已设置、
			# 实际未生效"的假成功)。
			if json_set "$2" "$3"; then
				chown openclaw:openclaw "$CONFIG_FILE" 2>/dev/null || true
				echo -e "${GREEN}✅ 已设置 $2${NC}"
			else
				echo -e "${RED}❌ 设置失败: $2${NC}" >&2
				exit 1
			fi
		else
			echo "用法: oc-config.sh --set <key> <value> [类型]"
			echo "类型可选: string | number | boolean | json (默认按 schema 自动判定)"
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
	--backup)
		bk_dir="${OPENCLAW_BACKUP_DIR:-${OC_DATA}/backups}"
		mkdir -p "$bk_dir" 2>/dev/null
		echo -e "${CYAN}正在创建配置备份...${NC}"
		cd "$bk_dir" && oc_cmd backup create --only-config --no-include-workspace 2>&1
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
		echo "  oc-config.sh              # 进入交互式菜单 (自动检测)"
		echo "  oc-config.sh --tui        # 强制使用方向键交互模式"
		echo "  oc-config.sh --traditional # 强制使用传统数字菜单"
		echo "  oc-config.sh --model      # 直接进入模型配置"
		echo "  oc-config.sh --set K V    # 设置配置项"
		echo "  oc-config.sh --get K      # 读取配置项"
		echo "  oc-config.sh --restart    # 重启 Gateway"
		echo "  oc-config.sh --status     # 查看状态"
		echo ""
		echo "交互模式快捷键:"
		echo "  ↑↓      导航选项"
		echo "  回车    确认选择"
		echo "  ESC/q   返回上级"
		echo "  字符    搜索过滤"
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
