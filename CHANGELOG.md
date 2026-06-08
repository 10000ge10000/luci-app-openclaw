# Changelog

本项目所有重大变更都将记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。
## [2.0.6] - 2026-06-08

### 适配版本

- 默认 Node.js 更新为 `22.19.0`。
- OpenClaw 维护者验证稳定版更新为 `2026.6.1`。

### 修复命令行环境

- 新增独立 `/usr/bin/openclaw` 包装器，只对子进程设置 OpenClaw HOME 和 PATH，不污染父级 zsh。
- 新增 `openclaw-shell`，进入一次性隔离 zsh，退出后恢复原环境。
- README 增加 `openclaw`、`openclaw-shell`、`openclaw-env check/upgrade/node` 使用示例。
- 停止通过 `/etc/profile.d/openclaw.sh` 注入 OpenClaw 环境。

### 修复升级策略

- `openclaw-env upgrade` 始终安装 npm 正式 `latest` 标签。
- 安装入口仅接受 `stable` 和 `latest`，拒绝 beta、rc、next 等测试版本。
- `latest` 安装失败时不回退到脚本固定版本。

### 修复微信插件

- 使用 OpenClaw 官方 `plugins install/uninstall` 命令管理微信插件。
- 支持新版 `.openclaw/npm/projects/*/node_modules/@tencent-weixin/openclaw-weixin` 安装路径。
- 修复 npm 管理插件所有权，避免被新版 OpenClaw 判定为 blocked plugin candidate。
- 微信版本检测改用 `npm view`，扫码登录不再重置整个插件目录所有权。
- 修复 OpenClaw 2026.6.1 中 Web 控制台因 `control-ui-*.js` 安全头而拒绝 iframe 嵌入。
- 微信状态页支持 managed npm project 路径，刷新按钮增加加载状态、缓存绕过和失败提示。
- 增加微信登录二维码弹窗可用高度，避免二维码内容显示不完整。
- 修复微信账号退出：按插件账号存储格式清理凭据、同步缓存和账号索引，并返回真实执行结果。


## [2.0.5] - 2026-05-15

### 适配 OpenClaw v2026.5.12

- `OC_TESTED_VERSION` 更新为 `2026.5.12`，默认稳定版固定到 npm `latest` 稳定标签。
- 保持 Node.js 默认运行时 `22.16.0`，安装后按 OpenClaw `engines.node` 最低要求执行强校验；版本过低会直接失败并输出明确日志。
- 文档补充 `2026.5.14-beta.2` 不作为默认稳定版的说明。

### 修复权限与路径问题

- 保留公开 UCI 字段 `openclaw.main.install_path`，新增统一路径规范化逻辑。
- 兼容用户误填 `/mnt/data/openclaw`，避免实际路径变成 `/mnt/data/openclaw/openclaw`。
- 拒绝相对路径、空白字符、shell 特殊字符和 `/tmp`、`/usr`、`/overlay` 等危险根目录。
- `profile.d/openclaw.sh` 不再全局 `export HOME="$OC_DATA"`，仅在 `openclaw` 命令包装器内注入 HOME，避免影响 SSH/zsh/oh-my-zsh。
- 卸载逻辑移除 `chmod -R 777`，并将 `rm -rf` 限定到规范化后的 OpenClaw 运行根目录。
- 安装前新增写入探针，提前识别 overlay 已满、只读挂载或目标挂载点不可写。

### 修复微信插件链路

- 微信插件安装和升级前检查 `python3`、`openclaw` 系统用户、npm cache/tmp/data 写权限。
- 统一以 `openclaw` 用户运行微信插件 CLI，并显式传入 `OPENCLAW_CONFIG_PATH`、`NPM_CONFIG_CACHE`、`TMPDIR`。
- 自动迁移旧渠道名 `weixin` 到 `openclaw-weixin`。
- 保留 Web PTY `cmd=wechat` 初始化能力，微信向导入口不被破坏。

### 修复 LuCI 与打包

- 状态页区分“启动中”和“启动失败”，并显示 procd gateway 退出码。
- Web 控制台每次加载前重新读取 token，强制使用正确的 HTTP Gateway URL，避免旧 token 或 HTTPS 混用。
- `Makefile`、`.run`、`.ipk` 打包清单补齐 `wechat.htm`、rpcd ACL、共享 shell/Lua helper。
- 主包不再直接生成 `openclaw.zh-cn.lmo`，避免与 `luci-i18n-openclaw-zh-cn` 文件冲突。

### 测试

- 新增路径规范化、卸载保护、profile HOME、Node 版本比较、打包清单、微信安装预检和控制台 token URL 的契约测试入口。

### 致谢

感谢以下用户通过 Issue 或 PR 提供问题反馈、复现信息和修复思路：

- @svgr110 (#89)、@Cuscito (#88)、@ayysama (#87)、@Jameslau-tech (#86, #66)
- @hotwa (#85, #83, #63)、@hwliu11 (#84)、@alan9771 (#82, #65)、@zhuxf8 (#81)
- @yiyibuguai (#80, #75)、@nbagui (#79)、@sam528300-lab (#78)、@392377870 (#77)
- @ouyangmland (#76, #68, #67)、@lucian521 (#74)、@jiangxiaoqiang-cloud (#73)、@LuckyMai (#72, #62)
- @xuguoliang189 (#71, #64)、@ampcwin (#70)、@natserver (#69)、@jh620026 (#61)、@okareyouok (#60)

---

## [2.0.4] - 2026-04-10

### 适配 OpenClaw v2026.4.9

本次更新适配 OpenClaw 最新稳定版本 (2026.4.9)，包含多项破坏性配置变更处理和安全策略适配。

#### 版本变更
- **OC_TESTED_VERSION**: 从 2026.3.28 更新到 2026.4.9 (跨 12 个版本)
- **Node.js 版本**: 保持 22.16.0 (v2026.4.x 最低要求 >= 22.14.0)

#### 更新日志 UI 深度优化

参照 GitHub Releases 和 App Store 更新页面的设计规范，重构「检测升级」按钮触发的更新日志显示区域：

- **Markdown 渲染引擎重构** (`ocMarkdownToHtml` 函数):
  - 中英文混排字体栈优化：`PingFang SC` / `Microsoft YaHei` / `Noto Sans SC` + 系统字体回退
  - 字体渲染增强：`text-rendering: optimizeLegibility` + 抗锯齿平滑
  - 标题层级比例重构：一级标题 (20px) → 二级 (17px) → 三级 (15px) → 四级 (14px)
  - 代码块样式：圆角边框 + 等宽字体栈 (`SF Mono`, Consolas, Menlo)
  - 链接悬停效果：底部边框渐显动画
  - 列表标记美化：统一的 `list-style-position: inside` + 行高优化 (1.75)

- **版本状态徽章设计**:
  - 「有新版本」状态：渐变金色背景 + 橙色边框
  - 「已是最新」状态：渐变绿色背景 + 绿色边框
  - 「无法检查」状态：灰色背景 + 中性边框
  - 版本号使用等宽字体徽章样式，增强可读性

- **更新日志容器设计**:
  - 卡片式布局：圆角 + 微阴影 + 白色背景
  - 版本标题栏：渐变背景 + 蓝色版本徽章 + GitHub 跳转链接
  - 内容区滚动条美化：`scrollbar-width: thin` + 自定义颜色
  - 操作按钮区：分组设计 + 阴影增强

- **视觉细节优化**:
  - 段落间距：12px 统一间距
  - 行高优化：中文场景 1.75-1.8
  - 字间距微调：标题 `-0.02em`，正文 `0.01em`
  - 颜色层级：主标题 `#1f2328` → 正文 `#32383f` → 次要文本 `#656d76`

#### 破坏性变更处理 (v2026.4.5)

OpenClaw v2026.4.5 移除了多项旧版配置别名，本版本新增自动清理逻辑：

- **已废弃配置清理**: `sync_uci_to_json()` 新增清理以下废弃字段
  - `talk.voiceId` / `talk.apiKey` — 语音功能配置迁移
  - `browser.ssrfPolicy.allowPrivateNetwork` — SSRF 策略重构
  - `hooks.internal.handlers` — 内部钩子迁移
  - `channel.*.allow` / `group.*.allow` / `room.*.allow` — 迁移到 `enabled` 字段
  - `agents.defaults.cliBackends` — CLI 后端配置废弃

- **配置迁移工具集成**: 服务启动时自动调用 `openclaw doctor --fix` 迁移遗留配置

#### 权限模型适配 (v2026.4.7/4.9)

OpenClaw 新增了严格的环境变量安全检查，阻止危险环境变量覆盖：

- **环境变量安全审计**: `start_service()` 注入环境变量前进行路径安全验证
  - 阻止包含特殊字符 (`$`, `` ` ``, `|`, `&`) 的路径
  - 阻止 `/proc/*`, `/sys/*`, `/dev/*` 等危险目录
  - 确保 `JAVA_HOME`, `RUST_*`, `GIT_*`, `KUBECONFIG`, `AWS_*` 等危险变量不被意外注入

- **命令授权策略更新**: 适配 v2026.4.7 的权限收紧
  - `/allowlist add/remove` 现需要所有者授权 (LuCI 会话验证已满足)
  - `gateway config.apply` 阻止修改 exec 审批路径

#### 安全更新

- **依赖安全**: `basic-ftp` 强制升级到 5.2.1 (修复 CRLF 命令注入漏洞 CVE)
- **浏览器 SSRF**: 新增安全策略配置选项 (默认不启用内网访问白名单)

#### 改进

- **配置验证增强**: 服务启动时先执行配置 schema 验证，失败时自动尝试修复
- **iframe 安全头修补**: 适配 v2026.4.x 新的安全头位置
  - v2026.4.x 将 `X-Frame-Options` 和 `frame-ancestors` 设置从 `gateway-cli-*.js` 迁移到 `server.impl-*.js`
  - `patch_iframe_headers()` 函数现已支持两个位置的安全头修补
  - 解决 Web 控制台 iframe 嵌入被阻止的问题
- **错误提示优化**: 配置迁移失败时输出详细的诊断信息
- **移除 Gemini CLI 安装**: OpenClaw v2026.4.x 已废弃 `google-gemini-cli-auth` 插件
  - 节省约 155MB 磁盘空间
  - 减少安装时间约 30~60 秒
  - 用户配置 Google Gemini 请使用 API Key 方式 (推荐)
- **修复微信插件加载失败**: 清理 jiti 缓存目录解决权限冲突
  - jiti 编译 TypeScript 时在 `/tmp/jiti` 创建缓存
  - 服务启动前自动清理，避免 openclaw 用户无法写入

#### 修复 (2026-04-10)

- **权限修复 EACCES 错误**: `doctor --fix` 以 root 运行后创建的文件导致 Gateway 无法写入
  - 根因: `doctor --fix` 在服务启动时以 root 身份执行，可能创建 root 所有的配置文件
  - 症状: `EACCES: permission denied, open '.../agents/main/agent/models.json.xxx.tmp'`
  - 修复: `init.d/openclaw` 在 `doctor --fix` 后自动修复非 extensions 目录权限
  - 同时修复 `openclaw-env factory-reset` 后的权限问题

- **OpenWrt 兼容性**: 无 `ss` 命令时 Gateway 重启检测失败
  - 根因: `oc-config-interactive.js` 直接调用 `ss` 命令，部分精简固件未安装
  - 修复: 优先使用 `ss`，不存在时回退到 `netstat`

- **新增交互式菜单引擎**: `oc-menu-engine.js`
  - 方向键导航、搜索过滤、粘贴支持 (Bracketed Paste Mode)
  - 纯 Node.js 实现，零外部依赖
  - 用于 SSH 命令行配置体验优化

#### 技术细节

**新增函数**:
- `_validate_path()`: 环境变量路径安全验证
- `_run_config_migration()`: 执行 OpenClaw 官方配置迁移工具

**修改文件**:
- `root/etc/init.d/openclaw`: 配置同步逻辑、环境变量注入、权限修复
- `root/usr/bin/openclaw-env`: OC_TESTED_VERSION 版本号、factory-reset 权限修复
- `root/usr/share/openclaw/oc-config-interactive.js`: ss/netstat 兼容性
- `root/usr/share/openclaw/oc-menu-engine.js`: 新增交互式菜单引擎

---

## [2.0.3] - 2026-04-03

### 修复

- **微信插件安装失败 (exit: 127)**: 当 Gateway 未运行或路径检测失败时，`npx` 命令指向不存在的路径导致安装失败
  - 根因: `get_actual_install_path()` 依赖 Gateway 进程运行时返回正确路径，Gateway 未启动时返回默认值 `/opt/openclaw`，但实际安装路径可能是 `/mnt/data/openclaw` 等自定义路径
  - 修复: `action_wechat_install()` 和 `action_wechat_upgrade_plugin()` 新增多层路径校验逻辑：
    1. 先检查默认检测到的 `npx` 是否存在
    2. 不存在时回退到 UCI 配置的 `install_path`
    3. 最后遍历常见备用路径 (`/mnt/data/openclaw`, `/opt/openclaw`, `/overlay/upper/opt/openclaw`)
    4. 所有路径都无效时返回明确的错误提示，而非模糊的 exit 127

---

## [2.0.2] - 2026-03-31

### 新增功能

#### 适配微信通道插件 (openclaw-weixin)

- **多账号操作面板**: 新增完善的多账号登录登出功能机制，重构 Lua API (`login_cmd`/`logout_cmd`/`install_cmd`/`upgrade_cmd`) 使其支持精细化的多实例运行调度。
- **登录交互优化**: 解决由于未完成登录流程导致的环境锁定问题，后台新增自愈能力 (`pkill -f 'channels login.*openclaw-weixin'`)。
- **安全沙箱无缝衔接**: 修复了 Web 触发命令时的 `blocked plugin candidate: suspicious ownership` 安全警告，完整平滑降权至 `openclaw` 用户组执行。

**💡 微信通道使用细节提醒：**
1. **多开隔离**：所有上号的微信机器人互不干扰，尽管在 Web 控制台大盘上聊天日志看起来像在一起，但由于后端存在独立的 `BotID / AccountID / Session` 多元结构体鉴权区分，他们在底层是**绝对隔离**的记忆！
2. **退出登录**：遇到登录卡死或想强制下线，点击界面对应微信号的“退出登录”即可强制切除对应后端通道进程。

#### 支持自定义安装路径

- **功能描述**: 用户现在可以将 OpenClaw 运行环境安装到自定义路径（如第二块硬盘 `/mnt/data`）
- **LuCI 界面**: 安装对话框增加自定义路径输入框，支持实时检测目标路径的可用空间
- **系统检测**: 安装前系统配置检测会检测自定义路径的磁盘空间，而非默认的 `/opt`
- **服务状态**: 状态 API 返回当前安装路径信息
- **最小空间提示**: 安装界面提示最小需要 2GB 可用空间

#### 技术实现

- 新增 UCI 配置项 `openclaw.main.install_path`，默认值为 `/opt`
- 程序会在用户指定路径下自动创建 `openclaw` 目录进行安装
  - 例如：用户输入 `/mnt/data`，实际安装路径为 `/mnt/data/openclaw`
- 所有脚本和配置文件支持从 UCI 读取自定义路径：
  - `openclaw-env`: 通过 `OC_INSTALL_PATH` 环境变量或 UCI 配置
  - `init.d/openclaw`: 启动时从 UCI 读取路径
  - `oc-config.sh`: 支持自定义路径的环境变量
  - `profile.d/openclaw.sh`: SSH 环境变量支持
  - `uci-defaults/99-openclaw`: 首次安装初始化支持


### 感谢

感谢 @hotwa 提供的修改思路和建议。

---

## [2.0.1] - 2026-03-30

### 适配 OpenClaw v2026.3.28

#### 版本变更
- **OC_TESTED_VERSION**: 从 2026.3.13 更新到 2026.3.28
- **磁盘空间要求**: 从 1.5GB 提升到 2GB (OpenClaw v2026.3.28 包体积约 200MB)

#### 兼容性分析
- **Node.js 版本**: v2026.3.28 要求 >= 22.14.0 (降低了要求，从 v2026.3.13 的 >= 22.16.0)
- **入口文件**: 无变化，仍为 `openclaw.mjs`
- **配置 Schema**: 向后兼容，无需迁移
- **API**: 向后兼容

#### 包体积变化
- v2026.3.13: ~94MB (4,730 文件)
- v2026.3.28: ~200MB (19,887 文件)
- 文件数量增加 4x+，包体积增加 2x+

#### 新增 Plugin SDK 导出 (20+)

新增 AI 提供商原生支持 SDK:
- `plugin-sdk/xai` — xAI (Grok) API 支持
- `plugin-sdk/vllm` — vLLM 高性能推理引擎支持
- `plugin-sdk/ollama` — Ollama 本地模型原生 SDK
- `plugin-sdk/openai` — OpenAI 原生 SDK
- `plugin-sdk/sglang` — SGLang 推理引擎支持
- `plugin-sdk/chutes` — Chutes AI 平台支持
- `plugin-sdk/google` — Google AI SDK
- `plugin-sdk/nvidia` — NVIDIA NIM API 支持
- `plugin-sdk/venice` — Venice AI 支持
- `plugin-sdk/minimax` — MiniMax API 原生 SDK
- `plugin-sdk/mistral` — Mistral AI 原生 SDK
- `plugin-sdk/qianfan` — 百度千帆大模型 SDK

新增功能模块 SDK:
- `plugin-sdk/zod` — Zod schema 验证支持
- `plugin-sdk/setup` — 安装配置向导 SDK
- `plugin-sdk/routing` — 模型路由配置 SDK
- `plugin-sdk/speech` — 语音处理 SDK
- `plugin-sdk/browser` — 浏览器自动化 SDK

新增顶级导出:
- `extension-api` — 扩展 API 入口 (用于插件开发)

#### 移除的依赖

以下渠道依赖被移除 (功能整合到核心或不再维护):
- `grammy` — Telegram Bot 框架 (改用内置实现)
- `@grammyjs/runner` — Telegram 运行器
- `@grammyjs/transformer-throttler` — Telegram 限流器
- `@whiskeysockets/baileys` — WhatsApp Web API (改用 matrix-js-sdk)

#### 新增依赖

核心依赖:
- `uuid@^13.0.0` — UUID 生成
- `gaxios@7.1.4` — Google API HTTP 客户端
- `matrix-js-sdk@41.2.0` — Matrix 协议支持 (替代 WhatsApp)
- `@anthropic-ai/vertex-sdk@^0.14.4` — Anthropic Vertex AI 支持

#### 依赖版本升级

核心依赖:
- `ws`: 8.19.0 → 8.20.0
- `hono`: 4.12.7 → 4.12.9
- `file-type`: 21.3.2 → 22.0.0
- `undici`: 7.24.1 → 7.24.6
- `sqlite-vec`: 0.1.7-alpha.2 → 0.1.7

AI/ML 依赖:
- `@mariozechner/pi-ai`: 0.58.0 → 0.63.1
- `@mariozechner/pi-tui`: 0.58.0 → 0.63.1
- `@mariozechner/pi-agent-core`: 0.58.0 → 0.63.1
- `@mariozechner/pi-coding-agent`: 0.58.0 → 0.63.1
- `@modelcontextprotocol/sdk`: 1.27.1 → 1.28.0
- `@agentclientprotocol/sdk`: 0.16.1 → 0.17.0
- `@aws-sdk/client-bedrock`: 3.1009.0 → 3.1019.0

#### pnpm 配置变更

新增 `ignoredBuiltDependencies`:
- `@discordjs/opus` — 跳过构建
- `koffi` — 跳过构建

新增 `onlyBuiltDependencies`:
- `@tloncorp/tlon-skill` — 需要构建

#### 中间版本变更 (v2026.3.22 ~ v2026.3.24)

v2026.3.22:
- Node.js 最低版本从 22.16.0 降低到 22.14.0
- 大量 plugin-sdk 模块重构

v2026.3.23:
- 修复版本发布问题
- 稳定性改进

v2026.3.24:
- 依赖安全更新
- 性能优化

#### 升级建议

1. **磁盘空间**: 确保至少 2GB 可用空间
2. **Node.js**: v22.16.0 完全兼容，无需降级
3. **配置迁移**: 现有配置向后兼容，无需手动干预
4. **备份**: 升级前建议执行 `openclaw backup create --only-config`

## [2.0.0] - 2026-03-16

### 重大变更
- **配置管理菜单重构**: 主菜单采用分组样式，更清晰的导航结构
  - AI 模型配置：配置 AI 模型和提供商、设置活动模型
  - 消息渠道：配置消息渠道 (电报/QQ/飞书)
  - 系统管理：健康检查与状态、查看日志、重启 Gateway
  - 高级选项：高级配置、重置配置、显示当前配置概览
- **新增高级配置菜单**: 独立的高级配置入口，包含：
  - Gateway 端口/绑定地址/运行模式配置
  - 日志级别设置
  - ACP Dispatch 开关
  - 官方完整配置向导入口
  - 原始 JSON 查看/编辑
  - 配置备份导出/导入

### 修复
- **QQ 机器人插件配置名称不匹配** (#XX): OpenClaw v2026.3.13 加强了配置验证，`plugins.allow` 中的插件名称必须与实际安装的插件名完全匹配
  - 问题：旧版本写入的是 `openclaw-qqbot`，但实际插件名是 `@tencent-connect/openclaw-qqbot`
  - 影响：配置验证失败导致 Gateway 启动后立即退出，procd 进入 crash loop 保护
  - 修复：新增 `fix_plugin_config` 函数自动检测并修正不匹配的插件名称
  - 修复：`configure_qq` 安装插件后调用 `ensure_qqbot_plugin_allowed` 确保正确的插件名写入配置
  - 修复：`init.d` 服务启动前自动修复配置中的插件名称
- **安装运行环境报错** (#28): 部分系统缺少 `libstdcpp6` 导致 Node.js 无法运行，安装 pnpm 时卡住
  - 依赖声明新增 `libstdcpp6`，安装时自动拉取 C++ 标准库
  - Node.js 验证逻辑改进：检测到运行失败时提示缺失的库并给出修复命令
- **环境变量路径混乱** (#42): 用户通过 SSH 直接运行 `openclaw` 命令时，CLI 使用默认 `HOME=/root` 导致配置文件和 skills 散落在 `/root/.openclaw/` 而非正确的 `/opt/openclaw/data/.openclaw/`
  - 新增 `/etc/profile.d/openclaw.sh` 全局环境变量脚本，SSH 登录后自动设置正确的 PATH、OPENCLAW_HOME 等变量
  - 升级时自动迁移 `/root/.openclaw/` 下的 skills、sessions、openclaw.json 到正确路径
  - 用户现在可以直接运行 `npm`、`npx`、`openclaw config` 等命令

### 新增
- **全局环境变量**: `/etc/profile.d/openclaw.sh` 为 SSH 用户提供：
  - PATH 包含 Node.js 和 OpenClaw bin 目录
  - OPENCLAW_HOME、OPENCLAW_STATE_DIR、OPENCLAW_CONFIG_PATH 正确指向安装路径
  - `openclaw` 命令别名（当全局安装时）
- **查看日志功能**: 主菜单新增「查看日志」选项，显示最近 100 条 OpenClaw 日志

### 变更
- Makefile 新增 `/etc/profile.d/openclaw.sh` 安装步骤
- 依赖声明新增 `libstdcpp6`
- **飞书 Bot 配置流程优化**: 参考 QQ Bot 实现，大幅简化配置步骤
  - 新增 App ID 格式验证（`cli_xxx` 格式）
  - 新增 App Secret 长度检查
  - 使用 OpenClaw CLI 一键配置（`oc_cmd channels add --channel feishu`）
  - 配置保存后自动验证
  - 新增详细的事件订阅、权限配置、插件安装指引

### 适配 OpenClaw v2026.3.13

#### 升级说明
- **Node.js 版本升级**: 从 22.15.1 升级到 22.16.0 (OpenClaw v2026.3.11+ 最低要求)
- **OpenClaw 版本升级**: 从 v2026.3.8 升级到 v2026.3.13

#### 重要安全修复
- WebSocket 跨站劫持漏洞修复 (GHSA-5wcw-8jjv-m286)
- 设备配对安全增强：切换到短期引导令牌 (GHSA-99qw-6mr3-36qr)
- 命令审批安全加固：Unicode 不可见字符转义、执行检测规范化
- 多渠道 Webhook 安全增强：飞书/LINE/Zalo 签名验证强化

#### 新功能支持
- **Fast Mode**: OpenAI/Anthropic 快速响应模式支持
- **Control UI 重构**: 新版 Dashboard-v2 模块化界面
- **Ollama 本地向导**: 支持本地或云端+本地混合模式
- **Kubernetes 部署**: 新增 K8s 部署清单和文档
- **Docker 时区**: 新增 `OPENCLAW_TZ` 环境变量支持

#### 破坏性变更处理
- **Cron 主动投递收紧**: 升级后建议运行 `openclaw doctor --fix` 迁移旧版 cron 存储
- **插件安全策略**: 禁用隐式工作区插件自动加载，需显式信任决策
- **Node.js 最低版本**: 要求 >= 22.16.0 (已在 openclaw-env 中更新)

#### 配置兼容性
- 现有配置文件完全兼容，无需手动迁移
- 已预设 `gateway.controlUi.dangerouslyDisableDeviceAuth=true` 禁用设备认证
- 已预设 `gateway.controlUi.allowInsecureAuth=true` 允许不安全认证

## [1.0.15] - 2026-03-13

### 修复
- **QQBot 插件 3 层死锁修复**: 解决插件安装后因 uid 权限→安全策略阻止→配置校验失败的连锁问题
  - 自动检测插件 blocked/loaded/目录存在 3 种状态
  - 插件安装后自动 `chown root:root` 修复权限
  - 安装失败但目录存在时不再阻断配置流程

### 新增
- **覆盖安装防护**: 离线安装器在覆盖安装前先停止已有服务，避免文件被占用
- **离线 .run 安装包**: 构建包含 Node.js + OpenClaw + LuCI 插件的全合一自解压包，用户**无需联网**即可完成安装
- **musl 架构支持**: 离线包支持 x86_64-musl、aarch64-musl 两种架构 (OpenWrt/iStoreOS 均使用 musl)
- **依赖预下载脚本** (`scripts/download_deps.sh`): 在构建机上预下载所有离线依赖
- **node_modules 精简**: 自动删除文档、测试、TypeScript 源码等非必要文件，减小 30%+ 体积
- **磁盘空间预检查**: 安装前检测可用空间是否满足 500MB 最低要求
- **架构/libc 自动检测**: 安装时自动校验当前设备是否匹配安装包架构

### 文档
- **README**: 添加离线安装方式（无需联网），更新目录结构

### 变更
- **离线包不依赖 curl/openssl/git**: 离线安装模式下 opkg 注册的依赖简化为 luci-compat + luci-base

## [1.0.14] - 2026-03-12

### 备份管理增强 & QQ 机器人支持

#### 新增
- **备份列表可视化**: LuCI「💾 备份/恢复」对话框现在展示所有备份的结构化列表：
  - 📄 仅配置 / 📦 完整备份 类型标签（从 manifest.json 读取 `onlyConfig` 字段精确判断）
  - 备份时间、文件大小
  - 每个备份支持**单独恢复**和**删除**操作
  - 创建/删除备份后列表自动刷新
- **备份删除 API**: Controller 新增 `action=delete` 操作（含路径穿越安全校验）
- **QQ 机器人配置**: `oc-config.sh` 渠道菜单新增「QQ 机器人」选项（选项 1，推荐国内用户），支持：
  - 自动安装 `@tencent-connect/openclaw-qqbot` 插件
  - App ID / App Secret 输入校验
  - 通过 `openclaw channels add` CLI 一键配置
- **消息渠道状态显示**: 状态面板新增「消息渠道」行，自动检测已配置的渠道（QQ、Telegram、Discord、飞书、Slack）

#### 变更
- **备份恢复**: 从"从最新备份恢复"改为在列表中选择任意备份进行恢复
- **描述文本**: 各页面描述新增"QQ"渠道说明

#### 修复
- **JS 语法错误导致所有按钮失效**: 备份对话框 HTML 被错误地插入 `<script>` 标签内部，导致 JavaScript 语法错误。修复: 在对话框 HTML 前后正确分割 `<script>` 标签

## [1.0.13] - 2026-03-12

### 适配 OpenClaw v2026.3.8 & 新增备份/恢复功能

#### 新增
- **配置备份/恢复**: LuCI 基本设置页「💾 备份/恢复」按钮，弹出对话框支持：
  - 📄 仅配置文件备份（~2KB，包含模型、渠道、插件设置）
  - 📦 完整备份（配置 + 状态数据）
  - 🔄 从最新备份恢复配置（自动重启服务）
- **Shell 备份菜单**: `oc-config.sh` 主菜单新增「8) 💾 备份/还原配置」，支持：
  - 创建仅配置 / 完整备份
  - 验证备份完整性 (`openclaw backup verify`)
  - 列出已有备份文件
  - 从最新备份恢复配置（交互确认 + 自动重启）
- **命令行备份**: `oc-config.sh --backup` 快捷参数，适合 cron 定时任务
- **OpenClaw 版本显示**: 状态面板新增 OpenClaw 版本行（从 package.json 读取）

#### 修复
- **备份文件路径**: 备份文件统一保存到 `~/.openclaw/backups/` 目录（OpenClaw CLI 默认输出到 CWD）
- **完整备份失败**: 含未注册插件的 channel ID 时，`backup create` 因 config invalid 失败；改用 `--no-include-workspace` 跳过工作区发现

#### 变更
- **OC_TESTED_VERSION**: 2026.3.2 → 2026.3.8
- **Control UI iframe 资源查找**: `patch_iframe_headers()` 扩展搜索路径，覆盖 `$NODE_BASE/lib/node_modules`、pnpm 全局存储，并使用 `readlink -f` 解析 v2026.3.8 新增的符号链接资源路径
- **Gateway 入口查找**: `get_oc_entry()` 新增 `readlink -f` 符号链接解析，兼容 v2026.3.8 的 bundled 插件优先级调整
- **配置同步清理**: `sync_uci_to_json()` 自动删除 v2026.3.7/3.8 已废弃的配置字段：
  - `gateway.controlUi.dangerouslyAllowCors`
  - `gateway.controlUi.dangerouslyAllowRemoteConnections`
  - `commands.ownerDisplay`

#### 兼容性说明
- **v2026.3.7 BREAKING CHANGE**: `gateway.auth.mode` 必须显式指定（不再有默认值）。本插件已在 v1.0.3 起始终写入 `"mode": "token"`，无需用户操作
- **v2026.3.8**: Control UI 资源分发改为符号链接方式，本版本已完整适配

## [1.0.12] - 2026-03-11

### 移除 OpenClaw 版本检测 & 修复 BusyBox tar 兼容性

#### 变更
- **「检测升级」按钮**: 不再检查 OpenClaw (npm) 版本，仅检查插件 (luci-app-openclaw) 是否有新版本
- **「检测升级」显示更新内容**: 检测到新插件版本时，直接展示该版本的 Release Notes，告知用户升级了什么
- **状态面板**: 移除「OpenClaw」版本显示行，保留 Node.js 和插件版本
- **内部清理**: 移除 `get_openclaw_version()` 函数、`action_do_update`、`action_upgrade_log` 等已废弃后端 API

#### 修复
- **BusyBox tar 兼容性** (#18, #30): `openclaw-env` 安装 Node.js 时的解压命令优先使用 GNU tar `--strip-components=1`；若不支持则自动回退到 BusyBox tar 兼容方式（解压到临时目录后移动），无需用户手动安装 `tar`
- **插件升级网络错误提示**: 下载后检测文件内容，若 GitHub 返回 `Not Found`（GFW 拦截等情况）则显示明确提示，并附手动下载链接

## [1.0.11] - 2026-03-09

### 修复 Telegram 配对后无法使用的严重 Bug

#### 修复
- **Telegram 配置流程**: Token 保存后强制重启网关（不再可选），确保 Bot Token 立即生效后再进入配对流程
- **Telegram 配对流程**: 配对成功后自动重启网关，确保配对关系立即生效，用户可以直接开始对话

## [1.0.10] - 2026-03-08

### 新增腾讯云大模型 Coding Plan 套餐支持

#### 新增
- **腾讯云 Coding Plan 套餐**: 新增菜单选项 13，支持一键配置腾讯云大模型 Coding Plan 套餐
  - Base URL: `https://api.lkeap.cloud.tencent.com/coding/v3`，Provider: `lkeap`
  - 支持全部 8 个套餐模型: tc-code-latest (智能路由)、hunyuan-t1、hunyuan-turbos、hunyuan-2.0-thinking、hunyuan-2.0-instruct、glm-5、kimi-k2.5、minimax-m2.5
  - 按类别分组展示: 智能推荐 / 推理模型 / 旗舰模型 / 第三方模型

#### 修复
- **Coding Plan 配置信息修正**: 订阅地址更正为官方页面，移除不必要的 Base URL 显示

## [1.0.9] - 2026-03-08

### 插件一键升级 & 百炼模型列表扩充

#### 新增
- **插件一键升级**: LuCI 界面"检测升级"发现新版后，可直接点击"⬆️ 升级插件"按钮完成在线升级
  - 后台自动从 GitHub Releases 下载 `.run` 安装包并执行
  - 实时升级日志显示，带容错处理 (安装过程替换 LuCI 文件导致 API 暂时不可用时自动判定成功)
  - 同时保留"📥 手动下载"链接作为备选
- **百炼按量付费模型列表扩充**: 从 4 个模型扩充至 16 个，按类别分组显示
  - 千问商业版: qwen-max、qwen-plus (Qwen3.5)、qwen-flash (Qwen3.5)、qwen-turbo、qwen-long (1000万Token上下文)
  - 千问Coder: qwen3-coder-plus (100万上下文)、qwen3-coder-flash
  - 推理模型: qwq-plus
  - 千问开源版: qwen3-235b-a22b、qwen3-32b、qwen3-30b-a3b
  - 第三方模型: deepseek-r1、deepseek-v3、kimi-k2.5、glm-5、MiniMax-M2.5

#### 修复
- **CBI 底部按钮未隐藏**: "保存并应用/保存/复位"按钮在基本设置页仍然显示
  - 根因: `m.submit = false` 和 `m.reset = false` 不被 CBI 框架识别
  - 修复: 改为 `m.pageaction = false` (dispatcher.lua 第 294 行检查的正确属性)
- **插件升级后配置管理无法连接**: 升级后 PTY WebSocket 一直转圈 "等待服务就绪"
  - 根因: `.run` 安装器覆盖 `/etc/config/openclaw` 导致 `pty_token` 丢失，PTY 认证失败
  - 修复: 升级时保留用户 UCI 配置 (仅首次安装部署默认配置)；安装后自动重启 PTY 服务

## [1.0.8] - 2026-03-07

### 修复第三方模型配置导致 Gateway 崩溃 & 新增 Coding Plan 套餐支持

#### 修复
- **EACCES 权限错误** (#8): Web PTY 以 root 运行，创建的目录 (`sessions/`, `auth-profiles.json` 等) 归 root 所有，Gateway 以 `openclaw` 用户运行时无法写入，报 `EACCES: permission denied, mkdir`
  - `oc-config.sh`: `auth_set_apikey`、`json_set`、备份目录创建后均执行 `chown openclaw:openclaw`
  - `web-pty.js`: 子进程退出时自动 `chown -R openclaw:openclaw` 整个数据目录
- **第三方模型 404/405 错误** (#11, #13, #14, #15): DeepSeek、xAI Grok、Groq 等 OpenAI 兼容提供商配置后返回 404/405
  - 根因: 这些提供商缺少 `register_custom_provider` 调用，未写入 `baseUrl` 导致 Gateway 请求发到错误地址
  - 修复: 为 DeepSeek、xAI、Groq 快速配置补充 `register_custom_provider` 调用
- **API 类型错误导致 Gateway 崩溃**: `register_custom_provider` 中 `api` 值设为 `openai-chat-completions`，但该值在 OpenClaw v2026.3.2 中不存在
  - 正确值为 `openai-completions`，错误值会导致 Gateway 启动时 JSON schema 校验失败，进入 crash loop
  - 有效 api 类型: `openai-completions` | `openai-responses` | `openai-codex-responses` | `anthropic-messages` | `google-generative-ai` | `github-copilot` | `bedrock-converse-stream` | `ollama`

#### 新增
- **阿里云 Coding Plan 套餐快速配置**: 千问配置菜单新增 Coding Plan 选项 (选项 c，默认推荐)
  - Provider: `bailian`，Base URL: `https://coding.dashscope.aliyuncs.com/v1`
  - 一键注册套餐内全部模型: qwen3.5-plus、qwen3-coder-plus、qwen3-coder-next、qwen3-max、MiniMax-M2.5、glm-5、glm-4.7、kimi-k2.5
  - contextWindow / maxTokens 按阿里云官方文档设定 (最大 100万上下文)
  - 参考: [阿里云 Coding Plan 文档](https://help.aliyun.com/zh/model-studio/openclaw-coding-plan)

#### 变更
- **千问配置菜单重构**: 从 2 种模式扩展为 3 种
  - `a)` Qwen Portal OAuth (官方向导)
  - `b)` 百炼按量付费 API Key (`sk-xxx` + `dashscope.aliyuncs.com`)
  - `c)` Coding Plan 套餐 (`sk-sp-xxx` + `coding.dashscope.aliyuncs.com`) ★ 默认推荐
  - 明确提示两套 API Key / Base URL 不互通
- **`register_custom_provider` 增强**: 新增可选参数 `context_window` (默认 128000) 和 `max_tokens` (默认 32000)

## [1.0.7] - 2026-03-06

### 修复依赖包名错误 & 补充 GNU tar 依赖 (感谢 [@esir](https://github.com/esirplayground) 建议)

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
