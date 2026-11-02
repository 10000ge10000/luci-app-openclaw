# luci-app-openclaw 2.3.0 发版检查报告（草稿）

检查日期：2026-11-02。分支 `fix/v2.2.4-maintenance`，基于 v2.2.3，改动尚未提交。

**结论：代码和验证已基本就绪，还差你确认后才能发布。** 真机验证查出并修复了 5 个阻断问题，其中 3 个都会让回滚失败。发布前还差微信扫码后的收发确认，以及 CI 上的 ARM64 Node 验证。回滚没有在真机端到端执行，见第 3 节。

## 1. 版本建议

建议 `2.3.0`，而不是 `2.2.4`。默认 OpenClaw 和 Node.js 都换了大版本线，模型菜单整体重写，用户升级核心时的行为也变了。

| 组件 | v2.2.3 | 本次默认 |
|------|--------|----------|
| OpenClaw | 2026.9.1 | 2026.9.36（extended-stable），可选 2026.10.9（latest） |
| Node.js | 22.23.2 | 24.22.2 |

上游状态（2026-11-01 查询）：npm `latest` 2026.10.9，`extended-stable` 2026.9.36。

## 2. 已通过的验证

### 自动化测试（本机 macOS x86_64）

`sh tests/run_all.sh`：36 项全部通过（32 个 Shell、4 个 Lua）。

- 本机没有 Lua 和 xz。Lua 5.1.5 编译在临时目录，xz 用 Python lzma 垫片代替，均未安装到系统。
- 新增 `test_provider_backend`、`test_provider_catalog_contract`、`test_config_fixups`、`test_channel_selection`，并移除被取代的 `test_model_presets_contract`。
- 变异验证：向后端、菜单和 Node 校验注入 13 种缺陷（Key 进 argv、不脱敏、清空已有 Key、不恢复默认模型、不回滚、菜单漂移等），测试全部能抓到。
- 新增 `test_wechat_plugin_convergence`，再注入 9 种缺陷（版本下限回退、安装失败报成功、只看退出码不核对版本等），也全部能抓到。这个测试还抓到一个真问题：版本号校验写得太宽，带 `;` 的字符串能通过并拼进 shell 命令，已修复。
- 新增 `test_state_restore_fidelity`，并为 `test_openclaw_upgrade_state` 增加完整回滚用例，又注入 7 种缺陷，全部能抓到。第一轮漏了一种（旧 workspace 被嵌套进恢复目录），补断言后抓到。
- 新增 `test_config_backup_retention`，注入 5 种缺陷，全部能抓到；清理命令也在设备的 BusyBox 上实测过。
- CI 尚未运行这一版。

### 真实上游 CLI 冒烟（本机隔离目录，假 Key，不发真实模型请求）

2026.9.36 与 2026.10.9 各 20 项，共 40 项全部通过：恢复出厂的 onboard 参数；插件写入的配置键通过 schema 校验；Gateway 真实启动；上游拒绝旧配置，迁移后通过且值不丢；自定义 Provider 新增、追加、冲突；保留默认模型；原地更新 Key；输出不含 Key；不写 `auth-profiles.json`；逐个登出。

### 2026-11-01 运行、未在最终代码上重跑的项目

相关脚本已随临时目录清除。

| 项目 | 结果 | 范围 |
|------|------|------|
| 35 个 auth-choice 与目录核对 | 213 项通过 | 两个版本 |
| 后端真实 CLI 用例 | 30/30 | 两个版本 |
| Shell 菜单端到端 | 10/10 | 两个版本 |
| 交互式菜单 expect 流程 | 通过 | 仅 2026.10.9 |
| 连通性测试真实请求返回可用 | 通过 | 用户提供的测试 API |

### 微信插件加载（本机隔离目录，核心 2026.10.9，未登录微信）

| 插件版本 | 结果 |
|---------|------|
| 2.4.10 | `plugins inspect --runtime` 为 `loaded`，Gateway 正常启动 |
| 2.4.8 | `status: error`，`cannot import openclaw/plugin-sdk/infra-runtime` |

### 打包

| 路径 | 结果 |
|------|------|
| `.ipk` | 本机实际构建，新增文件齐全，与源文件逐字节一致 |
| `.run` | 本机实际构建（`sed -i` 是 GNU 语法，用垫片绕过），归档内文件齐全 |
| feeds / SDK | **只做了静态清单检查，没有实际编译** |

### 其它检查

Shell、JS、Lua、JSON 语法全部通过；改动文件均为 UTF-8、LF；敏感信息扫描未发现 Key、Token 或内网地址；`.gitignore` 未改动；暂存区为空。

## 3. 真机验证

环境：Raspberry Pi 4（1.9GB 内存）、Kwrt 25.12.5、aarch64 musl。这是一台在跑业务的设备，验证前已备份。按授权范围只做一次核心升级，没有跑全量测试，也没有做压力复现。

### 通过

| 项目 | 结果 |
|------|------|
| 插件 2.0.11 → 2.3.0，核心不动 | 配置只有 `allowInsecureAuth` 被移除，Gateway、PTY、微信正常 |
| 注入错误 integrity | Node 24.22.2 下载校验通过；OpenClaw 包被拒绝，核心未变，Gateway 未中断 |
| 核心 2026.6.11 → 2026.9.36，Node 22 → 24 | `RESULT: success`，备份校验、Doctor、Gateway 全部通过，用时 678 秒，无重启 |
| 迁移后的数据 | `config validate` 通过；已配对设备保留；API Key 迁入 `openclaw.sqlite`；Token 哈希不变 |
| 服务启动期间断电 | 重启后服务自动恢复，`openclaw.sqlite` quick_check 为 ok，配置可解析（用户操作电源时碰巧发生） |
| 备份创建与恢复（隔离目录） | 升级前的真实归档校验、恢复通过，907 个文件中 904 个与对照一致，其余差异来自对照副本早生成约 15 分钟；2026.9.36 生成的归档校验、恢复通过 |
| root 运行模型配置 | 自定义 Provider 新增、保留默认模型、真实请求可用；错误 Key 报认证失败；删除后 Provider 列表和默认模型还原；文件属主仍为 `openclaw`；配置与日志中没有 Key |
| 两套菜单（真实终端） | 进入模型菜单、查看状态、提供商列表、返回、退出；内容一致，默认模型和凭据显示正确，配置哈希不变 |
| LuCI 接口与页面 | `status_api`、`check_update`、`wechat_status`、`check_system`、`devices_list` 正常；`basic`、`advanced`、`wechat`、`console` 均返回 200，没有 Lua 错误 |

升级峰值：温度 54°C，负载 4.44，磁盘余量最低约 493MB。

删除临时 Provider 后，配置里多了上游 `onboard` 写入的 `gateway.tailscale: {"mode":"off"}`，`wizard.*` 也更新了。这是默认值，不影响运行，没有改回去。

### 真机查出的问题

**微信渠道崩溃循环（已修复）。** 升级后 Gateway 健康，`plugins list` 显示 `loaded`，渠道却反复退出：`Package subpath './plugin-sdk/channel-runtime' is not defined by "exports"`。旧流程不检查插件版本，报告还写着成功。现在兼容矩阵按核心版本记录最低插件版本，升级时自动收敛并写入报告。

**静态判断曾经出错。** 修复前我根据导入分析认为 2026.10.9 与所有微信插件版本都不兼容。这是误判：2.4.10 里的 `channel-message` 是捕获异常后才用的旧路径常量。查了官方 changelog 又实测加载后才改正，同时发现 2.4.9 修过 2026.9.x 的入站回复错误，所以 2.4.8 也不够。

另外 4 个问题也来自真机，详见 CHANGELOG「修复」：回滚杀死自身（BusyBox 上 `exit=143`）、`2026.9.36` 上备份失败、装过 npm 插件的备份恢复不了、恢复备份删除工作区。前三个的本地和隔离验证已补，真实归档验证通过。交互式菜单退出卡住是额外发现的小问题，也已修复。

### 未通过或未确认

- **微信消息收发。** 插件升到 2.4.10 后渠道能启动，不再崩溃，但服务端返回 token 失效，重启后仍是如此，需要重新扫码才能确认收发。账号文件的修改时间还是 7 月，升级没有动过它。此前 2.4.6 运行的 15 分钟内日志没有这条错误，所以失效是约 20 分钟的渠道中断造成的，还是版本变化造成的，无法区分。这期间 `wechat_status` 仍返回 `logged_in: true`，LuCI 不会提示。
- **真机端到端回滚没有执行。** 按「只做一次升级」的授权，没有制造第二次核心安装。升级成功后代码备份已清理，在这台设备上回滚只会得到新核心加旧状态，没有验证价值。已验证的部分：恢复逻辑用真实归档在隔离目录跑通，完整流程在替身环境跑通。没有覆盖的部分：Doctor 或 Gateway 失败后，真机上恢复代码备份并重启。
- **两次未归类的整机复位。** 11-01（跑完整测试时）和 11-02 约 11:22（设备空闲）的寄存器值已被覆盖。11-02 14:26 的一次已确认是用户操作电源：`PM_RSTS` 为 `0x1000`（上电复位），没有看门狗标志。此后约 47 分钟的采样里 `get_throttled` 始终为 `0x0`，这段时间没有欠压，但不能说明高负载时的情况。这版固件没有 `rpi_volt` 驱动，内核日志不会记录欠压，`get_throttled` 重启后也会清零，排查时不要依赖日志。

### 还没做

1. 浏览器里的实际显示（通道选择、升级提示）。接口和 HTML 已验证，版式需要你看一眼
2. 菜单内的写入操作。写入逻辑走同一后端，真机上验证的是后端，菜单只做了查看
3. `--omit=optional` 在 musl 上是否影响新版功能

## 4. 其它未验证项

- **`BUILD_MODE=unofficial`**：本机没有 Docker，只验证了下载、SHA256 匹配和 ELF 依赖（只需 musl 与 libgcc），容器内运行步骤要等 CI。
- **x86_64 Linux（glibc 与 musl）**：没有实际设备或容器验证。
- **OAuth 与设备码登录**：没有真实账号，菜单已标注未验证。
- **目录中大多数 Provider 的真实调用**：只核对了 auth-choice、环境变量和配置结果，没有各家的真实 Key。真实调用只验证过一个 OpenAI 兼容接口。
- **#113 类设备**：新版本组合未验证。
- **#108 中的「全新部署难以启动」**：报告者的具体环境没有复现，不能断言已解决，请不要据此关闭。

## 5. 主要风险

| 风险 | 影响 | 缓解 |
|------|------|------|
| 新版体积变大（9.36 解压约 390MB） | 小容量设备空间不足，低端设备升级更慢 | 安装前有磁盘检查，升级失败保留原安装；需真机确认 |
| 上游未来再改 schema | 新版本可能拒绝启动 | 默认只装已验证版本 |
| Fixups 在所有版本上运行 | 旧配置字段被改写 | 只改三个路径，解析失败不写入，已测 |
| 自定义 Provider 的 Key 明文存于配置 | 备份外泄即泄露 | 上游设计，README 已说明 |
| 升级中途断电或复位 | 事务可能停在中间状态 | 启动期断电已实测恢复；升级事务中途断电未测 |
| 用户升级后微信需要重新扫码 | 渠道收不到消息 | 尚不确定是否必现，需要重新扫码后观察 |

## 6. 发布前待办

需要你确认后才执行：

- [ ] 重新扫码后确认微信收发
- [x] 这台设备保留新版本（用户 2026-11-02 确认）。正式发布后再升级到正式包，因为当前是 Mac 上构建的测试包
- [ ] 决定是否找一台没有业务的设备，执行端到端回滚
- [ ] 手动运行 `build-node-musl.yml`，把 `node-v24.22.2-linux-arm64-musl.tar.xz` 发布到 `node-bins`，否则 unofficial-builds 和 npmmirror 都不可达时没有兜底
- [ ] 提交并推送分支，确认 CI 通过（含 `BUILD_MODE=unofficial`）
- [ ] 把 CHANGELOG 的 `[Unreleased]` 改为 `[2.3.0] - 日期`。`build.yml` 按此标题提取发布说明，未改名会显示「暂无更新日志」
- [ ] 剩余验证完成后再更新一次 CHANGELOG「已知限制」和 `verification.device`
- [ ] 合并 main、打 tag、发布
- [ ] 回复并关闭相关 Issue。发布说明里的 `@用户名` 会通知到对应用户
- [ ] 删除 #109 中重复的评论（待你批准）

## 7. 社区致谢核对

Issue 作者均通过 GitHub API 核实（2026-11-02）。

| Issue | 作者 | 状态 |
|-------|------|------|
| [#108](https://github.com/10000ge10000/luci-app-openclaw/issues/108) | pbclaodentm | open |
| [#109](https://github.com/10000ge10000/luci-app-openclaw/issues/109) | LittleRabbit2023 | open |
| [#110](https://github.com/10000ge10000/luci-app-openclaw/issues/110) | qwedsazxcce | open |
| [#111](https://github.com/10000ge10000/luci-app-openclaw/issues/111) | keyboydg | open |
| [#113](https://github.com/10000ge10000/luci-app-openclaw/issues/113) | KotobaWakusei | open |

- v2.2.3 之后没有已合并的 PR。[#104](https://github.com/10000ge10000/luci-app-openclaw/pull/104)（gershwin97）的修复在 v2.2.3 之前已整合，#107 也已随 v2.2.3 发布，均未列入本次致谢。
- qibaoxiaotai-beep 在 #108 的评论是使用建议，不涉及本次改动，未列入。如需致谢请告诉我。
