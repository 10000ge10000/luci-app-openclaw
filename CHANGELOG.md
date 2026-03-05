# Changelog

本项目所有重大变更都将记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

## [1.0.7] - 2026-03-06

### 修复依赖包名错误 & 补充 GNU tar 依赖 (感谢 [@esir](https://github.com/esir) 建议)

#### 修复
- **依赖包名修正**: `util-linux-script` 在 OpenWrt/iStoreOS 软件源中不存在，正确的包名是 `script-utils` (提供 `/usr/bin/script` 命令)。此错误会导致通过 iStore/opkg 安装插件时依赖解析失败
- **补充 GNU tar 依赖**: `openclaw-env` 安装脚本使用 `tar --strip-components=1` 解压 Node.js，但 busybox 内置的 tar 不支持该参数。新增 `tar` (GNU tar) 为必需依赖，确保解压操作正常

#### 变更
- `Makefile`: `LUCI_DEPENDS` 中 `+util-linux-script` → `+script-utils +tar`
- `scripts/build_ipk.sh`: 同步更新 Depends 字段
- `scripts/build_run.sh`: 同步更新 Depends 字段

### 修复重启服务时 Gateway crash loop 端口冲突

#### 修复
- **端口冲突 crash loop**: OpenClaw gateway 的架构是主进程 (`openclaw`) fork 出子进程 (`openclaw-gateway`) 监听端口，restart 时 procd 只杀主进程，子进程退出慢导致新实例端口冲突反复崩溃
  - `stop_service()`: 从空函数改为主动清理 `openclaw-gateway` 子进程 + 等待端口释放 (最长 8 秒)
  - `start_service()`: 启动前预检查端口，清理残留进程后再注册 procd 实例
  - `reload_service()`: stop 和 start 之间增加等待确保内核回收端口
  - LuCI controller: restart 改为先同步 stop 等端口释放，再后台 start
  - procd respawn 间隔从 5s → 10s，降低连续端口冲突概率

## [1.0.6] - 2026-03-06

### 修复 Docker 环境下安装失败 "mkdir: can't create directory: Directory not empty"

#### 修复
- **OverlayFS 兼容性**: iStoreOS/OpenWrt 安装 Docker 后，Docker 的 bind mount (`/overlay/upper/opt/docker`) 导致 OverlayFS 合并视图中 `/opt` 目录完全不可写，所有 `mkdir`/`touch`/`ln` 操作均报 "Directory not empty"
  - 新增 `_oc_fix_opt()` 检测函数，自动检测 `/opt` 是否可写
  - 不可写时自动执行 `mount --bind /overlay/upper/opt /opt` 绕过 OverlayFS 冲突
  - 三重保障: `uci-defaults` (首次安装)、`init.d` (每次开机)、`openclaw-env` (手动操作) 均包含修复逻辑
  - 正常系统 (无 Docker) 不受影响，检测到可写后直接跳过
- **openclaw-env**: 新增 `ensure_mkdir()` 安全目录创建函数，替代所有裸 `mkdir -p` 调用

## [1.0.5] - 2026-03-05

### 修复配置管理页面 "spawn script ENOENT" 启动失败 (#3, #4)

#### 修复
- **Web PTY 启动失败**: `web-pty.js` 硬编码依赖 `script` 命令 (来自 `util-linux-script`)，但部分 OpenWrt 固件默认不包含该命令，导致 `spawn script ENOENT` 错误并无限循环重启
  - 新增 `script` 命令自动检测，不存在时回退到 `sh` 直接执行 `oc-config.sh`
  - 新增连续失败计数器 (最多 5 次)，防止启动失败时的无限重试循环
  - 失败时向用户终端显示明确的错误提示和修复命令
- **Makefile 依赖补全**: `LUCI_DEPENDS` 新增 `+util-linux-script`，确保新安装自动拉取 `script` 命令

## [1.0.4] - 2026-03-05

### 适配 OpenClaw 2026.3.2

#### 破坏性变更修复
- **tools.profile 默认值变更**: 2026.3.2 将 `tools.profile` 默认从 `coding` 改为 `messaging`
  - `sync_uci_to_json()` 每次启动强制写入 `tools.profile=coding`
  - `openclaw-env init_openclaw()` onboard 命令添加 `--tools-profile coding`
  - `openclaw-env do_factory_reset()` onboard 命令添加 `--tools-profile coding`
  - `oc-config.sh` 工厂重置 onboard 命令添加 `--tools-profile coding`
  - `oc-config.sh` 工厂重置配置写入新增 `tools.profile=coding`
- **ACP dispatch 默认启用**: 2026.3.2 默认开启 ACP dispatch，路由器内存有限可能导致 OOM
  - `sync_uci_to_json()` 每次启动强制写入 `acp.dispatch.enabled=false`
  - `openclaw-env do_factory_reset()` 配置写入新增 `acp.dispatch.enabled=false`
  - `oc-config.sh` 工厂重置配置写入新增 `acp.dispatch.enabled=false`

#### 新增
- 健康检查集成 `openclaw config validate --json` 官方配置验证命令
- 健康检查新增 `gateway health --json` CLI 深度检查 (v2026.3.2 HTTP `/health` 已被 SPA 接管)

#### 修复
- **Ollama 配置适配**: `api` 从废弃的 `openai-chat-completions` 改为原生 `ollama` API 类型
- **Ollama baseUrl 格式**: 去掉 `/v1` 后缀，使用官方原生地址格式 (`http://host:11434`)
- **Ollama apiKey 对齐**: 从 `ollama` 改为官方默认值 `ollama-local`
- **启动自动迁移**: `sync_uci_to_json` 自动将旧版 Ollama 配置迁移到 v2026.3.2 格式

#### 改进
- 配置管理页面移除「菜单功能说明」信息框，减少视觉干扰
- `OC_TESTED_VERSION` 更新至 `2026.3.2`

## [1.0.3] - 2026-03-05

### 修复
- **P0** 配置管理写入错误的 JSON 路径导致 Gateway 崩溃且无法恢复 (#1)
  - `json_set models.openai.apiKey` 在 `openclaw.json` 创建了非法的顶层 `models` 键
  - OpenClaw 2026.3.1 严格校验配置 schema，拒绝启动并报 `Unknown config keys: models.openai`
  - 修复: API Key 改写入 `auth-profiles.json`，模型注册到 `agents.defaults.models`
  - 影响: 所有 11 个供应商的快速配置 (OpenAI/Anthropic/Gemini/OpenRouter/DeepSeek/GitHub Copilot/Qwen/xAI/Groq/SiliconFlow/自定义)
- **P0** 恢复默认配置 → "清除模型配置" 未清理 `auth-profiles.json` 认证信息
- **P1** 健康检查新增自动修复: 检测并移除旧版错误写入的顶层 `models` 无效键
- **P1** `set_active_model` 手动切换模型时未注册到 `agents.defaults.models`

### 新增
- **Ollama 本地模型支持**: 快速配置菜单新增 Ollama 选项 (12)，支持 localhost/局域网连接、自动检测连通性、自动列出已安装模型、兼容 OpenAI chat completions 格式
- `openclaw-env factory-reset` 非交互式恢复出厂设置命令
- `auth_set_apikey` 函数: 正确写入 API Key 到 `auth-profiles.json`
- `register_and_set_model` 函数: 注册模型到 `agents.defaults.models` 并设为默认
- `register_custom_provider` 函数: 为需要 `baseUrl` 的 OpenAI 兼容供应商注册 `models.providers`
- 「检测升级」同时检查 OpenClaw 和**插件版本** (通过 GitHub API 获取最新 release)
- 页面加载时自动静默检查更新，有新版本时「检测升级」按钮显示橙色小红点提醒
- 状态面板显示当前安装的插件版本号
- 构建/安装流程部署 `VERSION` 文件到 `/usr/share/openclaw/VERSION`
- `openclaw-env setup` 安装环境时自动安装 Gemini CLI (Google OAuth 依赖)

### 改进
- 使用指南顺序调整: ② 配置管理 → ③ Web 控制台 (首次使用更合理的引导顺序)
- Gemini CLI 安装从配置向导选项 1 移至环境安装阶段，避免进入向导时临时等待

## [1.0.2] - 2026-03-02

### 修复
- **P0** ARM64 musl: Gateway 崩溃循环 — `process.execPath` 返回 musl 链接器路径导致 `child_process.fork()` 失败
  - 使用 `patchelf` 直接修改 node ELF 二进制的 interpreter 和 rpath，替代 ld-musl wrapper 方案
  - 子进程通过 `process.execPath` fork 时可正确找到 node 二进制
- **P0** ARM64 musl: Unicode property escapes 正则失败 (`\p{Emoji_Presentation}`) — 缺少 `NODE_ICU_DATA` 环境变量
  - init.d、openclaw-env、oc-config.sh 所有入口均添加 `NODE_ICU_DATA` 环境变量

### 改进
- `build-node-musl.sh` 构建验证阶段新增 `process.execPath` 输出检查

## [1.0.1] - 2026-03-02

### 修复
- **P0** web-pty.js `loadAuthToken` 读取错误的 UCI key `luci_token` → `pty_token`
- **P0** init.d `get_oc_entry()` 管道子 shell 导致返回值丢失，改用临时文件重定向
- **P1** Gateway procd respawn 无限重试 (`3600 5 0`) → 限制最多 5 次 (`3600 5 5`)
- **P1** Telegram 配对流程管道子 shell 变量丢失，改用临时文件避免子 shell
- **P1** `openclaw.lua` PID 提取 `sed` 正则不可靠，改用 `awk` + `split`
- **P2** init.d 和 uci-defaults 弱 token fallback (`echo "auto_$(date +%s)"`) → `dd if=/dev/urandom`
- **P2** `oc-config.sh` 恢复出厂 `timeout` 命令可能不存在，添加 `command -v` 检查和降级方案
- **P2** web-pty.js SIGTERM 不清理 HTTPS server，统一 `shutdown()` 函数

### 新增
- GitHub Copilot 配置新增 OAuth 授权登录方式 (通过 `copilot-proxy` 插件)
- `uci-defaults` 首次安装时自动生成 `pty_token`
- Web 控制台和状态面板显示当前活跃模型名称

### 改进
- Qwen 使用 `models.dashscope` 键名、SiliconFlow 使用 `models.siliconflow`，避免 `models.custom` 键冲突
- `get_openclaw_version()` 从 `package.json` 读取版本号，不再每次启动 Node.js 进程
- PTY 终端 WebSocket 重连策略改为无限重连 (`MAX_RETRY=Infinity`)
- Makefile `PKG_VERSION` 从 `VERSION` 文件动态读取

## [1.0.0] - 2026-03-02

### 新增
- LuCI 管理界面：基本设置、配置管理（Web 终端）、Web 控制台
- 一键安装 Node.js + OpenClaw 运行环境
- 支持 x86_64 和 aarch64 架构，glibc / musl 自动检测
- 支持 12+ AI 模型提供商配置向导
- 支持 Telegram / Discord / 飞书 / Slack 消息渠道
- `.run` 自解压包和 `.ipk` 安装包两种分发方式
- OpenWrt SDK feeds 集成支持
- GitHub Actions 自动构建与发布

### 安全
- WebSocket PTY 服务添加 token 认证
- WebSocket 最大并发会话限制（默认 5）
- PTY 服务默认绑定 127.0.0.1，不对外暴露
- Token 不再嵌入 HTML 源码，改为 AJAX 动态获取
- sync_uci_to_json 通过环境变量传递 token，避免 ps 泄露
- 所有渠道 Token 输入统一 sanitize_input 清洗

### 修复
- Telegram Bot Token 粘贴时被 bracketed paste 转义序列污染
- Web PTY 终端粘贴包含 ANSI 转义序列问题
- 恢复出厂配置流程异常退出
- Gemini CLI OAuth 登录在 OpenWrt 上失败
- init.d status_service() 在无 netstat 的系统上报错
- Makefile 损坏导致 OpenWrt SDK 编译失败

### 改进
- 所有 AI 提供商模型列表更新到最新版本
- UID/GID 动态分配，避免与已有系统用户冲突
- 版本号统一由 VERSION 文件管理
- README.md 完善安装说明、FAQ 和项目结构
