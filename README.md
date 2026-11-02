# luci-app-openclaw

[![Bilibili](https://img.shields.io/badge/B%E7%AB%99-59438380-00a1d6?logo=bilibili)](https://space.bilibili.com/59438380)
[![Blog](https://img.shields.io/badge/Blog-910501.xyz-orange)](https://blog.910501.xyz/)
[![Build & Release](https://github.com/10000ge10000/luci-app-openclaw/actions/workflows/build.yml/badge.svg)](https://github.com/10000ge10000/luci-app-openclaw/actions/workflows/build.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

[OpenClaw](https://github.com/openclaw/openclaw) AI 网关的 OpenWrt LuCI 管理插件。

在路由器上运行 OpenClaw，通过 LuCI 管理界面完成安装、配置和服务管理。

<div align="center">
  <img src="docs/images/2.png" alt="OpenClaw LuCI 管理界面" width="800" style="border-radius:8px;" />
</div>

**系统要求**

| 项目 | 要求 |
|------|------|
| 架构 | x86_64 或 aarch64 (ARM64) |
| C 库 | musl（自动检测；离线包仅支持 musl） |
| 依赖 | luci-compat, luci-base, curl, openssl-util, tar, script-utils |
| 存储 | **2GB 以上可用空间** |
| 内存 | 推荐 1GB 及以上 |

**当前适配版本**

| 组件 | 默认版本 | 说明 |
|------|----------|------|
| OpenClaw | `2026.9.36` | 默认通道 `extended-stable`（官方长期维护）。也可选 `latest` 通道（当前已验证 `2026.10.9`）或锁定具体版本，见下方「发布通道与版本」 |
| Node.js | `24.22.2` | 满足上述版本要求的 `>=24.22.1 <25 \|\| >=26.12.1`，也兼容旧版 `2026.9.1`。升级 OpenClaw 时先升级 Node.js；x86_64 与 aarch64 优先从官方、unofficial-builds 及镜像源获取，自托管资产作为兜底；严格校验 `engines.node`，失败即中止 |
| 微信插件 | `@tencent-weixin/openclaw-weixin@2.4.10` | CLI 使用 `@tencent-weixin/openclaw-weixin-cli@2.1.4` |

### 运行时与架构说明

- **x86_64 / aarch64 (musl)**：Node.js v24.22.2 优先通过上游 [unofficial-builds](https://unofficial-builds.nodejs.org/) 及 npmmirror 镜像源获取，安装时自动下载并强校验 `SHASUMS256.txt`。依赖只有系统 musl 和 `libgcc`。Release 中的 `node-bins` 资产是同一文件的兜底镜像，由 `.github/workflows/build-node-musl.yml` 校验哈希后原样转发。

### 发布通道与版本

插件把「上游已发布」和「本插件已验证」分开记录。上游版本通过 npm dist-tags 实时查询；已验证版本写在 `openclaw-compat.json`，包含 `engines`、生命周期脚本和 tarball `integrity`，安装时逐项比对。

| 选项 | 安装什么 |
|------|----------|
| `extended-stable`（默认） | 该通道的已验证版本，只接收修复，适合路由器长期运行 |
| `latest` | 该通道的已验证版本，功能更新快 |
| 锁定版本 | 指定版本，配置项 `openclaw.main.pin_version` |
| 允许安装未验证版本 | 上游最新版或矩阵外的锁定版本。生命周期脚本必须与已验证版本一致，否则仍会拒绝。兼容性由你自行承担 |

上游有更新但插件还没验证时，「检测升级」只提示，不会自动安装。在 LuCI 基本设置里选择，或使用命令行：

```bash
OC_CHANNEL=latest openclaw-env upgrade
OC_VERSION=2026.9.36 openclaw-env upgrade
OC_CHANNEL=latest OC_ALLOW_UNVERIFIED=1 openclaw-env upgrade
```

版本的验证范围记录在 `openclaw-compat.json` 的 `verification` 字段里，`device` 为 `null` 表示还没有真机验证记录。

## 📦 安装

### 方式一：.run 自解压包（推荐）

无需 SDK，适用于已安装好的系统。

```bash
# 下载最新版本（自动获取版本号）
VER=$(curl -sI "https://github.com/10000ge10000/luci-app-openclaw/releases/latest" 2>/dev/null | grep -i "location:" | sed 's/.*tag\/v\{0,1\}//' | tr -d '\r\n')
wget "https://github.com/10000ge10000/luci-app-openclaw/releases/download/v${VER}/luci-app-openclaw_${VER}.run"
sh "luci-app-openclaw_${VER}.run"
```

### 方式二：.ipk 安装

```bash
# 下载最新版本（自动获取版本号）
VER=$(curl -sI "https://github.com/10000ge10000/luci-app-openclaw/releases/latest" 2>/dev/null | grep -i "location:" | sed 's/.*tag\/v\{0,1\}//' | tr -d '\r\n')
wget "https://github.com/10000ge10000/luci-app-openclaw/releases/download/v${VER}/luci-app-openclaw_${VER}-1_all.ipk"
opkg install "luci-app-openclaw_${VER}-1_all.ipk"
```

### 方式三：集成到固件编译

适用于自行编译固件或使用在线编译平台的用户。

```bash
cd /path/to/openwrt

# 添加 feeds
echo "src-git openclaw https://github.com/10000ge10000/luci-app-openclaw.git" >> feeds.conf.default

# 更新安装
./scripts/feeds update -a
./scripts/feeds install -a

# 选择插件
make menuconfig
# LuCI → Applications → luci-app-openclaw

# 编译
make package/luci-app-openclaw/compile V=s
```

使用 OpenWrt SDK 单独编译：

```bash
git clone https://github.com/10000ge10000/luci-app-openclaw.git package/luci-app-openclaw
make defconfig
make package/luci-app-openclaw/compile V=s
find bin/ -name "luci-app-openclaw*.ipk"
```


## 🔰 首次使用

1. 打开 LuCI → 服务 → OpenClaw，点击「安装运行环境」
2. 安装完成后服务会自动启动，点击「刷新页面」查看状态
3. 进入「Web 控制台」，点击「在新窗口打开控制台」添加 AI 模型和 API Key
4. 进入「配置管理」可使用向导配置消息渠道

> OpenClaw 官方控制台响应头固定为 `X-Frame-Options: DENY`，浏览器不允许把它嵌入 LuCI 页面，所以只能在独立窗口中打开。
> 首次打开若提示需要设备配对，回到 LuCI「Web 控制台」页点击「📱 设备配对」批准，再刷新控制台窗口即可。

## 自定义安装路径

UCI 字段仍然是 `openclaw.main.install_path`，语义为基础目录。例如：

```bash
uci set openclaw.main.install_path='/mnt/data'
uci commit openclaw
openclaw-env setup
```

实际运行目录会固定展开为 `/mnt/data/openclaw`。如果误填 `/mnt/data/openclaw`，插件会自动规范化为 `/mnt/data`，不会再拼成 `/mnt/data/openclaw/openclaw`。

安装前会执行写入探针；如果 overlay 已满、只读或外置盘未正确挂载，安装会在下载前失败并给出明确日志。

## 预放置安装（安装时整机重启的设备）

部分采用厂商闭源内核的固件（例如 #113 中 IPQ60xx + Kwrt 的京东云亚瑟）在短时间内大量写盘时会被硬件看门狗复位。在线安装需要下载、解压 Node.js 并安装约 3 万个依赖文件，正好会触发这个问题，表现为安装一半路由器重启。这是内核层面的问题，插件无法从根本上修复。对这类设备，可以在电脑上准备好文件，限速拷贝到路由器，再让插件只做初始化。

**1. 选择存储位置**：优先选独立的 ext4 分区（如 eMMC 上的 `/opt`）。不要选 tmpfs 或 overlay。#113 的实测中，USB 盘上的 ext4 因日志和元数据写放大，反而比 eMMC 更容易触发复位。

**2. 在电脑上准备文件**（以 arm64 musl 设备为例，版本与插件默认版本保持一致。`2026.9.36` 解压后约 390MB，请预留足够空间）：

```bash
# Node.js 运行时：musl 设备使用 unofficial-builds 的 musl 构建
curl -LO https://unofficial-builds.nodejs.org/download/release/v24.22.2/node-v24.22.2-linux-arm64-musl.tar.xz
tar xJf node-v24.22.2-linux-arm64-musl.tar.xz && mv node-v24.22.2-linux-arm64-musl node

# OpenClaw 及其依赖：按目标平台解析依赖树
npm install -g openclaw@2026.9.36 --prefix ./global \
  --os=linux --cpu=arm64 --libc=musl --ignore-scripts --omit=optional
```

**3. 限速拷贝到路由器**：目录结构必须是 `<安装目录>/openclaw/node/bin/node` 和 `<安装目录>/openclaw/global/lib/node_modules/openclaw/openclaw.mjs`（插件按这两个路径识别已安装的运行环境）。拷贝时请限速，例如 `scp -l 16000 -r`（约 2MB/s）；路由器的 SSH 不支持 SFTP 时加 `-O`。不要先拷贝压缩包再到路由器上解压，解压本身就会触发复位。

**4. 在路由器上完成初始化**：

```bash
uci set openclaw.main.install_path='/opt'
uci commit openclaw
openclaw-env setup
```

`setup` 识别到程序文件已就位、但还没有 `openclaw.json` 时，只会创建 `openclaw` 系统用户、校验 Node.js 版本、执行初始化，不下载、不解压任何文件。完成后在 LuCI → 服务 → OpenClaw 中启用服务，首次启动时会生成 `openclaw.json`。

> 限制说明：在线安装会在受控环境中执行经过校验的 OpenClaw `preinstall` / `postinstall` 脚本，预放置时用的是 `--ignore-scripts`，这两步不会执行。#113 的实测组合是 Node.js 22 + OpenClaw 2026.9.1，这个组合 `setup` 仍然接受；上面的新版本组合还没有在这类设备上验证过，请自行确认。`openclaw-env setup-offline <目录>` 是给 `.run` 离线安装器用的，它仍会在路由器上解压压缩包，不适合这类设备。

## 微信插件依赖

官方插件只声明了核心版本下限，旧插件在新核心上能装上但渠道会反复崩溃，所以每个已验证核心要求的最低插件版本记录在 `openclaw-compat.json` 里。`2026.9.x` 要求 `2.4.9` 及以上，`2026.10.9` 要求 `2.4.10` 及以上。升级核心时会自动收敛，结果见升级报告的 `WECHAT:` 一行。

微信渠道安装前会检查：

- `openclaw` 系统用户是否存在，不存在时自动创建
- `python3` 是否已安装；缺失时会自动执行 `opkg update && opkg install python3-light`
- npm cache、tmp、OpenClaw 数据目录是否可由 `openclaw` 用户写入
- 路由器到 `https://ilinkai.weixin.qq.com` 的 TLS/超时状态
- npm 插件是否已写入 `plugins.installs.openclaw-weixin`、`plugins.allow` 和 `channels.openclaw-weixin.enabled`
- 旧渠道名 `weixin` 会迁移为 `openclaw-weixin`

如自动安装失败，可手动安装：

```bash
opkg update
opkg install python3-light
```

微信配对推荐流程：

1. 在 LuCI「微信配置」页点击「安装/重新安装插件」。
2. 插件安装成功后点击「登录账号」。
3. 页面出现链接后，先点击打开链接，再用微信「扫一扫」扫码。
4. 等待页面提示登录成功，网关会重新加载微信账号。
5. 用微信给网关发一条测试消息，确认能触发 AI 回复。

常见失败原因：

- 二维码过期：重新点击「登录账号」生成新链接。
- 微信账号触发安全风控：更换常用设备/常用网络后再扫码，或换账号测试。
- 路由器网络异常：检查日志中的 `微信接口连通性检查`，重点看 TLS、timeout、DNS。
- 插件注册缺失：重新安装插件，启动时也会自动补齐 `openclaw-weixin` 配置。
- 目录权限错误：按页面日志提示修复 OpenClaw 数据目录权限。

## AI 模型配置

LuCI →「配置管理」里的交互式菜单和无 TTY 时的传统 Shell 菜单功能相同，共用同一个后端（`oc-providers.js`）和同一份目录（`provider-catalog.json`）。

| 按键 | 功能 |
|------|------|
| `q` | 常用 Provider 快速配置 |
| `1` | 官方 API（按量付费）：OpenAI、Claude、Gemini、DeepSeek、千问、智谱等 |
| `2` | 订阅套餐、Coding Plan、账号登录：百炼、GLM、Kimi Code、Copilot 等 |
| `3` | 聚合平台与自定义 API：OpenRouter、硅基流动、OpenAI / Anthropic 兼容接口 |
| `4` | 本地与局域网模型：Ollama、vLLM、LM Studio |
| `5` | 查看模型与认证状态（已脱敏） |
| `6` / `7` | 切换默认模型 / 管理备用模型（fallback） |
| `8` | 连通性测试 |
| `9` | 删除凭据或 Provider |
| `w` | 官方完整配置向导 |

选模型时有三个来源，上游发布新模型后通常不必升级插件：

1. **精选模型**：内置在目录里，离线可用，并注明核实时依据的 OpenClaw 版本。
2. **从 OpenClaw 获取完整列表**：调用 `openclaw models list`，失败时依次回落到 `--refresh` 和本地缓存，并显示真实原因。
3. **手动输入模型 ID**：始终保留。

使用时注意：

- **能查到模型不等于账号有权调用。** 列表只代表上游登记过这个模型，要确认账号能否调用请用连通性测试。它会发出真实请求，可能消耗少量 token。Gateway 运行时走 `models.probe`，不会中断服务。
- **凭据不写入 `auth-profiles.json`。** 该文件已被上游退役，Key 由官方 CLI 存入 `state/openclaw.sqlite`。Key 通过环境变量或标准输入传递，不进命令行参数，也不显示在菜单输出里。自定义 Provider 的 Key 按上游设计以明文保存在 `openclaw.json` 的 `models.providers` 下，备份文件里也有，请妥善保管。
- **不会覆盖已有配置。** 新增 Provider 默认保留当前默认模型，已有凭据原地更新。同一 ID 的自定义 Provider 只追加模型，Base URL 不同时拒绝。配置文件损坏时直接中止，原文件不变。
- **部分 Provider 需要官方插件。** 菜单会先询问，同意后才安装 `@openclaw/*-provider`。
- **OAuth 和设备码登录**（Copilot、Codex、MiniMax）只透传官方流程，维护者没有用真实账号验证过，菜单里有标注。

## 备份与恢复

LuCI → 服务 → OpenClaw →「💾 备份/恢复」：

- **创建**：「仅配置文件」只包含 `openclaw.json`（模型、渠道、插件设置）；「配置 + 状态数据」还包含会话等状态数据。
- **下载**：列表中每份备份都可以下载到电脑保存。备份里有 API Key，请妥善保管。
- **上传与恢复**：重装或配置损坏后，上传之前下载的 `*-openclaw-backup.tar.gz`（上限 20MB），再在列表中点「恢复」即可。恢复前，当前配置会另存为 `openclaw.json.pre-restore`。

恢复只会写入 OpenClaw 状态目录（如 `/opt/openclaw/data/.openclaw`）。上传的备份不能包含状态目录之外的文件或链接，否则会被拒绝。

## 已知说明

- OpenClaw 的 diagnostic heartbeat 可能在日志中出现类似周期性探测记录。它不是一次真实用户对话请求；如需降低噪音，优先在 OpenClaw 配置或日志采集侧降低诊断日志级别，不建议直接修改模型调用逻辑。
- 配置管理界面依赖 `oc-config-interactive.js`；若该文件缺失（例如自行裁剪打包清单），
  界面会静默回落到功能较少的传统数字菜单。`tests/test_packaging_parity.sh` 会校验
  三条打包路径的文件清单一致性。
- 当前仓库提供源码、OpenWrt feeds 集成方式、本地 `.run` / `.ipk` 构建脚本入口；推送 `v*` 标签后 CI 会自动构建并发布 Release 产物。

## 📂 目录结构

```
luci-app-openclaw/
├── Makefile                          # OpenWrt 包定义
├── luasrc/
│   ├── controller/openclaw.lua       # LuCI 路由和 API
│   ├── openclaw/paths.lua            # 路径规范化与安全校验
│   ├── model/cbi/openclaw/basic.lua  # 主页面
│   └── view/openclaw/
│       ├── status.htm                # 状态面板
│       ├── advanced.htm              # 配置管理（终端）
│       ├── console.htm               # Web 控制台
│       └── wechat.htm                # 微信渠道向导
├── root/
│   ├── etc/
│   │   ├── config/openclaw           # UCI 配置
│   │   ├── init.d/openclaw           # 服务脚本
│   │   └── uci-defaults/99-openclaw  # 初始化脚本
│   └── usr/
│       ├── libexec/                  # 共享 shell helper
│       ├── bin/openclaw-env          # 环境管理工具
│       └── share/openclaw/
│           ├── oc-config.sh          # 配置管理入口（无 TTY 时的回退菜单）
│           ├── oc-config-interactive.js  # 交互式配置菜单（默认路径）
│           ├── oc-menu-engine.js     # 方向键菜单引擎
│           ├── oc-providers.js       # 模型与凭据配置后端（两套菜单共用）
│           ├── oc-config-fixups.js   # 启动和升级前迁移旧版配置字段
│           ├── provider-catalog.json # Provider 目录与精选模型（唯一数据源）
│           ├── openclaw-compat.json  # 发布通道与已验证版本矩阵
│           ├── openclaw-package-contract.js  # 安装包与运行时契约校验
│           ├── web-pty.js            # Web PTY 服务
│           └── ui/                   # 配置终端前端资源
├── scripts/
│   ├── build_ipk.sh                  # 本地 IPK 构建
│   ├── build_run.sh                  # .run 安装包构建
│   ├── gen-release-body.sh           # Release 说明生成
│   └── build-node-musl.sh            # 转发并校验 Node.js arm64 musl 兜底资产
├── tests/                            # 契约测试（sh tests/run_all.sh）
└── .github/workflows/
    ├── build.yml                     # 在线构建 + 发布
    └── build-node-musl.yml           # Node.js musl 构建
```

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 License

[GPL-3.0](LICENSE)
