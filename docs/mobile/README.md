# 手机端 App（Flutter · 真实连接 + 连接空态）



> **这是什么**：策划案里「手机 App」的可运行实现——五个 Tab、任务状态、高风险授权、紧急停止都能真实点；**AI 助手页已接真实链路**：连上后端后可以真实操控这台电脑上的 DeepSeek Harness（发指令、看实时输出、审批、取消）。

> **M1.1 增量**：真实模式下 AI 助手可看**历史会话并回填历史消息**（断线重连按 `seq` 增量补齐）；**任务中心换成电脑端真实任务**（筛选/统计/刷新、任务详情事件时间线）；**项目管理展示电脑端真实工作区**；工具调用与工具输出**结构化分块渲染**（命令 mono 块、状态、耗时、输出可折叠）。

> **M2-α 增量**：连接期间启动**前台服务保活**（常驻「已连接 <设备> · DeepSeek Remote」，退后台不易被回收）；锁屏/后台收到审批请求时发**高优先级通知**，点通知直达授权弹层（冷/热启动两条路径）；后端重启或 token 失效时**自动重新配对并重连一次**。

> **M2.1 增量**：断线重连或 App 回到前台时，用 `GET /api/v1/conversations/{id}/events?afterSeq=<lastSeq>` **增量补拉断线期间的事件**（按 `seq` 去重/排序，与实时流同一处理入口，不再漏事件）；执行中继续输入会进入**本地排队**（深度 1），气泡提示「已排队，当前任务结束后自动发送」，可随时移除，任务结束/失败/取消后自动发出。

> **M2.2 增量（手感对齐 A 档）**：任务一结束，该轮工具调用与思考自动收成一行摘要（如「已完成 4 步 · 用时 12s」，失败/取消不同配色），点击展开原卡片；排队中的指令可点「立即发送」——先打断当前任务，收到终态或 3 秒超时后自动发出（小字提示「将打断当前任务」）；新增**6 套深色主题**（深海蓝/墨黑/暖沙/森林/樱粉/紫夜），「我的 → 外观」点选立即生效、重启保留（原生 SharedPreferences）；AI 助手页右上「分享」把最近一轮对话渲染成 1080 宽竖版分享卡 PNG 走系统分享（脱敏，不含工具命令/路径/token）；文本气泡长按可复制/重新发送，工具卡片长按可复制输出。

> **M2.3 增量（视觉重构）**：整体从深色改为**冷白底 + 白色卡片 + 蓝色主色**的浅色界面（默认浅色、跟随系统切换深色），排版采用大圆角/大留白/22px 标题、助手正文左侧 3px 浅竖线、底部导航选中圆点；「我的 → 外观」改为**跟随系统 / 浅色 / 深色**三选，立即生效并重启保留；六个页面全部按新 token 重做，版本号 `0.1.4-m2.3`。

> **M2.4 增量（无演示数据 + 界面减法）**：删除全部本地演示数据源（`demo_store.dart`、假设备/假会话/假任务/假工作区/假审计/假配对码），未连接时六个页面统一为**连接空态**（图标 + 标题 + 一行说明 + 「连接电脑」按钮）；已连接只保留真实功能与一行状态条，任务页去掉统计三卡副标题、电脑页合并为设备卡 + 权限摘要、项目页只读真实授权目录、我的页去掉审计与演示账号；连接页步骤压成一行小字，版本号 `0.1.5-m2.4`。

> **M2.5 增量（应用内在线更新）**：「我的 → 关于 → 检查更新」→ 请求后端 `GET /api/v1/app/version` 比对 versionCode → 有新版本弹窗（当前/新版本、大小、更新说明）→ 下载 APK（不可关闭进度框）→ 调起系统安装器（无「安装未知应用」权限时先引导去设置）；不做静默安装。**首次需手动装 0.1.6**（0.1.5 没有更新模块），之后即可应用内更新；版本号 `0.1.6-m2.5`（versionCode 7）。

> **M2.6 增量（项目同步 / 只读浏览）**：「项目」页展示电脑端真实工作区，可逐级浏览目录（目录在前、文件显示大小/修改时间、下拉刷新、面包屑回上级），点开文本文件只读预览（等宽字体、行号开关、横向滚动、sha256 前 8 位、超大截断提示、复制全部）；项目卡或浏览页可「在此项目/目录发指令」→ 自动切到 AI 助手，输入框上方出现「项目：<目录名>」胶囊，新会话自动绑定该工作区。依赖 Agent 的 `workspace.list` / `file.read` WSS 请求-响应能力（按 requestId 配对，不进消息流）；版本号 `0.1.7-m2.6`（versionCode 8）。

> **M3.6 增量（插件双 Tab + 插件市场 + 会话新鲜度）**：「插件」页改为**已安装 / 插件市场**双 Tab——已安装按插件包（bundle）分组，bundle 总开关 + 展开后的子插件开关；旧版电脑端（`/plugins/bundles` 404）自动回退到插件列表，把 Host 内部模块折叠进「系统内置」，并提示升级。插件市场支持搜索、按索引过滤、一键安装（含构建脚本二次确认）与卸载。桌面会话列表按「最后活动时间」倒序并显示消息条数，App 回到前台时重新拉取、首次进入强制滚到最新；版本号 `0.3.6-m3.6`（versionCode 25）。

> **M4.0 增量（工作区整改 + 手机新建工作区）**：任务页底部工作区胶囊**常驻**（不再只在 ≥2 个工作区时出现），末尾固定「＋ 新建工作区」——输入名字即可在电脑第一个授权根目录下建子目录（非法字符自动换成 `-`，同名直接复用），建好自动进入该工作区页。工作区页重做：会话按最后活动排序并显示状态徽标/消息数/时间，AppBar 提供「浏览工作区文件 / 新建会话（可命名）/ 刷新」，空态与底部输入条引导先建会话；同时修掉 Hub 骨架 `device.status` 把工作区目录清空导致「我的 → 工作区」闪空的问题。版本号 `0.4.1-m4.0`（versionCode 27）。

> **M4.1 增量（插件页对齐电脑端 + 市场索引兜底）**：「插件 → 已安装」顶部新增「浏览本地插件」入口，进入**已安装插件画廊**——按「内置插件配置 / 实验性插件 / 其他插件」分组列出电脑上全部本地插件（名称、两行说明、实验性标签、逐项开关，开关与电脑端「设置 → 插件」同源，重启 DSH 后完全生效），支持按名称/说明过滤；旧插件（无 `GET /desktop/plugins/gallery`）返回 404 时提示升级。插件市场卡片加厚：作者 + 下载量 + 星标（`319万` / `6.9k` 紧凑格式），列表顶部一行统计（条目数 + 索引来源 + 关键字）。同时修掉**市场一直为空**的根因：电脑端 DSH 未配置任何插件索引时，插件改用 DSH 公开索引 `https://api.dshmarket.com/v1/index.json` 兜底并带 `refresh` 让 Host 现场拉取（`defaultIndex=true`），结果 0 条时再用 `order:'stars'` 重试一次。版本号 `0.4.2-m4.1`（versionCode 28），电脑端插件需 **0.2.10+**。

> **怎么用**：先按 `docs/research/M1_E2E_REPORT.md` §4 在电脑上起「后端 + 公网隧道 + Agent」，再在 App 里填隧道地址 + 配对码 `824613`，点连接。

> **未连接时**：六个 Tab 展示统一的连接空态（不显示任何假数据），点「连接电脑」进入配对页。



---



## 1. 截图



### 1.1 真实链路（M1，手机 → 公网 → 后端 → Agent → Harness）



| 场景 | 截图 |

| --- | --- |

| 连上真实电脑（设备/版本/真实链路标识） | `docs/mobile/screenshots/09_live_connected.png` |

| 手机发指令 → Harness 真实回复（报出真实工作区路径） | `docs/mobile/screenshots/10_live_output.png` |

| 审批弹层（由 m1-approval-hold 触发的真实请求） | `docs/mobile/screenshots/11_live_approval.png` |

| 手机在对话里请求工作区外写入 → 真实 `pwsh` 命令 + 6 级权限 + 倒计时 | `docs/mobile/screenshots/12_live_approval.png` |

| 点「允许一次」后：工具执行成功、电脑上文件真实生成、任务完成 | `docs/mobile/screenshots/13_live_result.png` |



> M1.1 的「历史会话弹层 / 真实任务列表 / 结构化工具输出」**截图未补拍**：本机 headless 模拟器在 App 完成连接后 1–3 分钟内会被运行环境回收（多种 GPU 模式均失败），判定为环境问题；M1.1 能力由 `flutter test`（当前 366/366 全绿）与真实 REST 联调覆盖，详见 `docs/research/M1_1_REPORT.md` §7 第 9 条。真机或稳定宿主上可直接补拍。M2.3 视觉重构后的浅色界面截图同样待补拍（见 §8 第 14 条）；M2.4 后未连接界面为统一空态，截图同样待补拍（见 §8 第 15 条）。



### 1.2 历史截图（M2.4 前的演示模式界面，现已被空态取代）

| 页面 | 截图 |

| --- | --- |

| AI 助手（默认首页） | `docs/mobile/screenshots/01_assistant.png` |

| 任务中心 | `docs/mobile/screenshots/02_tasks.png` |

| 任务详情（事件时间线） | `docs/mobile/screenshots/03_task_detail.png` |

| 电脑控制（配对 / 权限） | `docs/mobile/screenshots/04_control.png` |

| 项目管理（工作区授权） | `docs/mobile/screenshots/05_projects.png` |

| 个人中心（审计日志） | `docs/mobile/screenshots/06_profile.png` |

| 高风险授权确认（10 分钟倒计时） | `docs/mobile/screenshots/07_approval.png` |

| 紧急停止与开关（控制页下半部） | `docs/mobile/screenshots/08_control_emergency.png` |



## 2. 五个页面做了什么



| Tab | 核心内容 | 与策划案的对应 |

| --- | --- | --- |

| **AI 助手**（默认） | 未连接：连接空态；已连接：发指令、实时输出、思考折叠、工具调用/输出分块、审批弹层、取消、历史会话回填、完成自动折叠、分享卡、长按菜单；一行状态条（设备名 + 已连接 + 会话切换/分享） | 2.3 默认首页＝对话；6.x 会话与消息 |

| **任务中心** | 未连接：连接空态；已连接：筛选胶囊、任务卡（状态徽标/进度/结果/错误码）、详情事件时间线、取消；真实模式下拉刷新（`GET /api/v1/tasks`） | 2.x 任务 7 状态；8.x task.* 事件 |

| **电脑控制** | 未连接：连接空态；已连接：设备卡（设备名/Agent/Harness/在线/最近在线）、权限摘要（一行「当前权限 3 级」+ 查看权限说明弹层）、紧急停止滑块 | 3.4 电脑端 UI；7 章安全；远程桌面分级 |

| **项目管理** | 未连接：连接空态；已连接：真实工作区列表，点卡片进入**逐级目录浏览**，文件点开只读预览（等宽/行号/复制），可在项目或目录内发指令并绑定新会话工作区 | 6.x workspaces / workspace_permissions |

| **个人中心** | 账号行、连接状态（已连接设备 / 未连接 + 连接按钮）、**外观（跟随系统/浅色/深色三选，即时生效+重启保留）**、关于；不再有审计日志/演示账号 | 7.5 审计；12 章交付 |



关键交互：**高风险授权**底部弹层展示工具名 + 原始命令 + 工作区，10 分钟倒计时后自动按「拒绝」处理（真实模式下这些字段来自 ACP 的 `request_permission` 与前置 `tool_call.rawInput`）；**紧急停止**必须拖动滑块才触发，触发后 App 内不提供恢复入口（与概念稿 §2.7 一致）。



## 3. 哪些是真的、哪些是演示



| 部分 | 状态 |

| --- | --- |

| 全部界面、导航、状态机、授权弹层、倒计时、紧急停止滑块 | ✅ 真实可交互 |

| 连接后端 / 测试连接（health）/ 配对 | ✅ **M1 真实**（`dart:io` HttpClient + WebSocket） |

| AI 助手页：发指令、实时输出、思考、工具调用、审批、取消 | ✅ **M1 真实**（经云端中继到电脑 Agent → Harness） |

| 历史会话 / 历史消息回填 / 重连增量补齐 | ✅ **M1.1 真实**（`GET /api/v1/conversations`、`.../messages?afterSeq=`，Bearer token 复用配对 token） |

| 任务中心列表、筛选、任务详情事件时间线 | ✅ **M1.1 真实**（`GET /api/v1/tasks`、`/tasks/{id}`）；未连接时为空态 |

| 工具调用 / 工具输出结构化渲染（命令、状态、耗时、退出码、输出折叠） | ✅ **M1.1**（`tool_call` / `tool_result` 分块；不再显示原始 JSON 片段） |

| 项目管理：真实工作区列表 | ✅ **M1.1 真实**（来自 `device.status.workspaceRoots`，只读） |

| 未连接时的六个页面 | ✅ **M2.4** 统一连接空态（无任何假数据/演示文案），点按钮进连接页 |

| 消息/任务/工作区/审计数据（未连接时） | ✅ **M2.4 已删除**（`demo_store.dart` 移除，不再有本地演示数据） |

| 审批通知 / 锁屏提醒（点击直达授权弹层） | ✅ **M2** 原生通知桥（`approval_alerts` 高优先级，tag=approvalId；冷/热启动都能直达） |

| 后台保活（前台服务常驻「已连接 <设备>」） | ✅ **M2** `ConnectionService`（`dataSync` 前台服务；退后台 5 分钟连接不丢） |

| 后端重启后自动重配对（REST 401 / WSS 4401） | ✅ **M2** 用本地地址+配对码自动 `/api/v1/auth/pair` 一次，成功静默继续 |

| 断线 / 回前台事件增量补拉（不漏事件） | ✅ **M2.1** `GET .../events?afterSeq=` 循环补拉到不足一页；按 `seq` 去重排序，与实时流同一处理入口 |

| 执行中继续输入 → 排队到当前任务结束后自动发送 | ✅ **M2.1** 本地队列（深度 1），「已排队」气泡可移除；task.state 终态后自动发出 |

| 任务结束自动折叠该轮工具/思考为一行摘要（点击展开） | ✅ **M2.2** 摘要含步数与用时；失败红/取消橙黄；助手最终回复不折叠 |

| 排队「立即发送」（先打断当前任务，终态或 3s 超时后发出） | ✅ **M2.2** 按钮下方提示「将打断当前任务」；打断中禁用防重复 |

| 6 套深色主题 + 「我的」外观入口 + 重启保留 | ✅ **M2.2** Kotlin `deepseek_remote/settings` + SharedPreferences |

| 最近一轮对话分享卡（1080 宽 PNG → 系统分享） | ✅ **M2.2** Canvas 渲染脱敏卡；Kotlin `deepseek_remote/share` + 内置 FileProvider |

| 文本气泡长按复制/重新发送、工具卡片长按复制输出 | ✅ **M2.2** 底部操作菜单 |

| 浅色优先 + 跟随系统深色 + 外观三选持久化 | ✅ **M2.3** 冷白底/白卡片/蓝主色；「我的 → 外观」三选立即生效、重启保留（SharedPreferences） |

| 六个页面视觉重做（颜色/圆角/间距/阴影 token 体系） | ✅ **M2.3** 大圆角/大留白/22 标题/导航选中圆点/助手左侧竖线；深色版同一 token 体系 |

| 项目目录浏览（`workspace.list` 请求-响应） | ✅ **M2.6 真实**（WSS 按 requestId 配对，不占消息 seq；目录在前、忽略 `.git`/`node_modules` 等，最多 500 条） |

| 文本文件只读预览（`file.read` 请求-响应） | ✅ **M2.6 真实**（等宽 + 行号开关 + 横向滚动 + 复制；`truncated`/`binary`/`TOO_LARGE` 友好提示，默认请求 256KiB） |

| 项目内发指令（会话绑定 workspacePath） | ✅ **M2.6 真实**（`pendingWorkspacePath` → `conversation.create` 带 `workspacePath`，创建成功自动清除；输入框上方胶囊可移除） |

| 远程推送通知、真实二维码配对 | ⬜ M1.2/M2 后续 |



## 4. 跑起来 / 连接真实电脑



### 4.1 构建与安装



``powershell

$env:JAVA_HOME='C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1'

$env:ANDROID_HOME='C:\Users\user\dsh-tools\android-sdk'

$env:ANDROID_SDK_ROOT=$env:ANDROID_HOME

$env:PATH='C:\Users\user\dsh-tools\flutter\flutter\bin;' + $env:PATH



cd app

flutter pub get

### M4.48 两个档位改叫「本机对话 / 远程电脑」（已改）

「手机 / 电脑」听起来像两台设备，其实是两种对话方式，所以 AI 助手页顶部的切换胶囊现在写「本机对话 / 远程电脑」；抽屉、会话中心里原来叫「本机直连」的分组也一并统一成「本机对话」，三处一个叫法。

第一次切到另一档时，输入框上方会出现一条说明，讲清两件事：

- **本机对话**：用自己的 API Key 直连云端，不经过电脑，只能处理手机里的文件。
- **远程电脑**：连上电脑后能读写工作区、跑任务；危险操作会先问你。

点「知道了」或右上角的 × 收起，之后不再打扰（记在 `mode_intro_seen_v1`）。云端口页的空态文案也改成了「本机对话不经过电脑…」。

### M4.47 会话都收进一页里了（已改）

以前找会话要看三处：AI 助手顶栏的历史按钮、抽屉里的「手机对话」、抽屉里的「历史会话」。现在只留一页「会话」：上半是**远程电脑**（电脑上跑的会话，存档的也在这里，点开就能接着聊），下半是**本机直连**（只存在手机上的对话）。

抽屉里因此只剩一段「会话」，右上角「全部会话」进这一页；每组只显示最近 3 条，多的进去看。

### M4.47 已知限制

- 抽屉里每组只列最近 3 条。
- 本机对话只存在这台手机上，换手机或重装会丢。

### M4.46 轮询只在看得见的时候跑（已改）

以前任务页和工作区页各自每 5 秒请求一次，页面被保活后「用户在看 AI 助手页，程序仍在拉任务」。现在统一交给 `PollCoordinator`：只在页面可见且 App 在前台时轮询，一次只跑一个请求，失败按 2 的幂退避（最长 30 秒），成功立刻回到 5 秒。

用户能感觉到的变化：切到别的页不再有后台请求、弱网时不会再「越刷越慢」、回到工作区会立刻刷新一次。

### M4.46 已知限制

- 桌面直播页有自己的一套退避（规则一样，代码还没合并）。
- 插件没有推送通道，跨页面数据仍是轮询来的。
- ⑨「本机对话 / 远程电脑」改名已在 M4.48 完成。

### M4.45 新建的工作区电脑上看不到（已修）

手机点「新建项目」建出来的目录，以前只存在磁盘上，DSH 的工作区列表来自 `workspaceRegistry` 服务，所以电脑端看不到。现在插件建完目录会顺手注册一次（`registerDesktopWorkspace()`），复用已存在的同名目录时也会幂等补注册。

升级步骤：装 0.4.45 的 APK（debug 签名，可覆盖旧版）→ **完整重开 DSH** 让插件 0.2.33 生效 → 点「新建项目」填之前的同名目录，电脑端就会出现。

### M4.45 已知限制

- 注册失败（老 DSH 没有 `workspaceRegistry`，或 `create` 抛错）时手机端仍提示「已建好」，只有插件日志里有「工作区注册失败（路径）：原因」。
- 这一版仍是 debug 签名。想换成正式签名（`CN=DeepSeek Remote`）需要卸载一次再装，之后升级就不会再冲突。

### M4.44 第一阶段六条安全改动（2026-11-23）

- **紧急停止**：现在会先给电脑发 `task.cancel`，最多等 3 秒等它真正停下，再断开，并按结果提示「任务已停下 / 电脑上没有在跑的任务，只断开了连接 / 电脑 3 秒内没确认停下，已先断开」，不再是「点一下就断线、任务照跑」。
- **审批弹层**：下滑、按返回键、等倒计时结束都只算「稍后再答」，**不会**替你拒绝；真拒绝必须点红色的「拒绝本次操作」。
- **Key 与 token**：手机的 API Key 存在系统安全存储里（`cloud_chat.json` 里不再有 Key）；电脑上的 `tokens.json` 只存 token 的 sha256，老文件会自动迁移，并顺手收紧了文件 ACL。
- **地址策略**：公网地址必须用 `https://`；`http://` 只允许 127.0.0.1 / 局域网 / Tailscale 这类内网地址，并会提示「此连接未加密」。
- **发布**：APK 改用独立 release 证书签名，`node tools/verify-release.mjs` 会校验 versionCode、大小、SHA256、版本名四项与更新接口一致；正式包不再内置任何个人内网地址。
- **静态分析**：`flutter analyze` 现在能跑（走 ASCII junction），0 error；剩 30 条是删页留下的死代码告警。

**M4.44 已知限制**：第二阶段（轮询协调、统一会话入口、模式改名）与第三阶段（拆代码）未开始；插件 0.2.32 需完整重开 DSH 才生效。

### M4.43 按 DSH_INSTRUCTIONS 改 8 条（死链 / 凭据 / Range / gzip）

- **「历史会话」修好了**：以前抽屉里永远写「还没有历史会话」，因为它打的是已停用的老后端接口
  （插件从没实现 `/api/v1/conversations`）。现在数据来自电脑的会话镜像（未归档的 + 只在存档里的），
  点一条直接进直播页。
- **token 不再明文存手机**：以前 `session.json` 里能直接看到 token；现在 token 进系统安全存储
  （Android EncryptedSharedPreferences / iOS Keychain），旧文件第一次启动时自动迁移，json 只留地址与设备信息。
- 电脑端（插件 0.2.31）：`afterSeq` 写错会明确报 400（不再闷声返回全量 253 KB）、未知路径的 code
  统一成 `NOT_FOUND`、下载文件支持断点续传（Range/206）、大响应 gzip、agent 复用同一条 token 而不再每次新签。
- 插件改动要**完整重开 DSH** 才生效；手机端这次是 0.4.43+69，测试 474/474。

### M4.42 新增「功能」页

用户：「做一个功能页面放到我的上面，先把插件拿出来放到里面」。抽屉里在「工作区」和
「我的」之间多了「功能」（`app/lib/screens/features_screen.dart`），「插件管理」从
「我的 → 关于与更新」搬进这一页。抽屉顺序现在是：AI 助手 / 工作区 / 功能 / 我的。

新增 `app/test/features_m4_42_test.dart` 3 例；全量 **466 例**。

### M4.42 已知限制

- 「功能」页现在只有「插件管理」一行，是留着长能力的空架子。
- 「使用文档」仍留在「我的」，没跟着搬。
- 抽屉「历史会话」在插件直连下仍为空（旧接口 `GET /api/v1/conversations` → 404）。
### M4.41 删掉「电脑」页

用户说「可以把这个页面删了」。抽屉从四个入口收缩到三个（AI 助手 / 工作区 / 我的），
`app/lib/screens/control_screen.dart` 整份删除，`IndexedStack` 与通知路由的索引同步调整。

那一页唯一独占的是**紧急停止**，所以它被搬到「我的」页（连接时才出现）：
滑动到轨道 72% 触发二次确认，确认之后才真正 `disconnect()`——这是断连的最后一个去处。

新增 `app/test/emergency_stop_m4_41_test.dart` 3 例；全量 **463 例**。

### M4.41 已知限制

- 权限说明弹层随页面删除；要看权限等级只能在电脑端配置里看。
- 抽屉「历史会话」在插件直连下仍为空（走 M1.1 旧接口 `GET /api/v1/conversations`，实测 404）。
### M4.40 从不同角度测试这个 App（审计）

这一轮不加功能，按四个角度压测，新增 25 例，全量从 437 例涨到 **462 例**：

- **接口契约**：`node tools/api-contract-probe.mjs`、`node tools/api-auth-probe.mjs` 直接打本机 8787。
  鉴权与角色隔离全对；插件侧记下 6 条待修（坏 JSON 返 500、`afterSeq` 非法返全量 253 KB、
  86 条 token 永不失效、工作区名消毒后照建、404 配 `BAD_REQUEST`、APK 不支持 `Range`）。
- **存档容错**：真临时目录里造 0 字节 / 截断 / 类型错乱 / 时间戳坏 / role 写错 / 同 id / 超 80 条，
  全部不崩。**修掉一个真 bug**：坏时间戳以前退回「现在」，坏记录反而排到「最近」第一位。
- **小屏 + 大字号**：320x480 + 系统字号 2.0 下渲染桌面直播页，抓到三处 `RenderFlex` 溢出，
  现在上下两块按 body 真实高度封顶并各自可滚，而且只在真的放不下时才封顶（正常竖屏不受影响）。
- **运行期**：500 条消息只建 < 60 个卡片；连点三下发送只发一条；页面关掉后轮询停止。

报告见 [`docs/research/M4_40_TEST_AUDIT.md`](../research/M4_40_TEST_AUDIT.md)。

### M4.40 已知限制

- 插件侧那 6 条问题没修（要改插件并完整退出重开 DSH 才生效），报告里写了根因与建议。
- 真机手感（上滑新建对话与列表滚动的冲突）、弱网丢包、双设备同时连、长时间常驻未测。
### M4.39 手机档「往上滑」新建对话

- 手势方向纠正：停在**最新一条**消息上继续往上滑（M4.37 要人先翻到最老一条再往下拽，反直觉）。
- 滑的过程中底部浮出一枚加载圈，`CircularProgressIndicator(value: 已滑距离 / 130)`，进度跟着手走。
- 滑过 130 像素圈补满，文案变「松手开始新对话」；松手 `_newChat()`，原对话留在侧栏。
- 这一手中途滚过列表（包括从半路一甩到底）不攒越界量，避免翻历史时误换对话。
- 新增 `app/test/cloud_new_chat_pull_m4_39_test.dart` 3 例；原 M4.37 的 3 例随方向反转删除。

### M4.39 已知限制

- 阈值 130 像素是拍的，真机手感偏重/偏轻改 `_newChatPull` 一个常量。
- 只在「已经停在最新一条」时生效；停在历史里要先滑回最新。
- 只有手机档（云端直连）有这个手势，电脑档不做。
### M4.38 直播页「经常连接超时」

电脑上一条忙会话的直播首屏要 175~187 KB —— 为了凑够 12 条对话，插件得往回扫
319 条事件（把 limit 调到 20 也一样）。走 Cloudflare 快速隧道一个来回
1~2.4 秒，手机在 5G + VPN 下更慢。以前手机端每 1.5 秒盲发一次请求、不看上一个
还在途，10 秒超时前已经堆了六七个，彼此抢同一条隧道，于是「经常连接超时」。

现在：在途不重发；失败按 3/6/12/24/30 秒退避，成功立刻回到 1.5 秒；只为
「拉桌面会话」放宽到 20 秒总超时；HttpClient 的 idleTimeout 从 5 秒提到 20 秒
（原来传输中途空转 5 秒就被自己掐断，报出来还是超时）。

### M4.38 已知限制

- 187 KB 还是原样上路：要真变轻得让插件 gzip 压缩响应（那要重开一次 DSH）。
- 快速隧道域名每次重开 DSH 都变，手机存着旧域名时会一直挂到超时（现在退避会把它
  压成 30 秒一次）。
- 手机切后台再回来仍会整段重拉首屏，慢的话还是那一屏 187 KB。

flutter test                 # 497 个测试（含 M3.6 新增 20、M4.0 新增 12、M4.1 新增 8、M4.2 新增 4、M4.3 新增 10、M4.4 新增 9、M4.5 新增 2、M4.6 新增 3、M4.7 新增 10、M4.8 新增 6、M4.9 新增 8、M4.10 新增 6、M4.11 新增 6、M4.12 新增 17、M4.13 新增 9、M4.14 新增 3、M4.16 新增 5、M4.17 新增 5、M4.18 新增 3、M4.19 新增 2、M4.21 新增 6、M4.22 新增 2、M4.25 新增 4、M4.26 新增 1、M4.27 新增 10、M4.28 新增 2、M4.29 新增 5、M4.32 新增 9、M4.33 新增 2、M4.34 新增 3、M4.35 新增 7、M4.36 新增 0、M4.37 新增 3、M4.38 新增 4、M4.39 新增 3、M4.40 新增 25、M4.41 新增 3、M4.42 新增 3、M4.43 新增 8）

flutter build apk --debug    # 产物 build\app\outputs\flutter-apk\app-debug.apk

adb install -r build\app\outputs\flutter-apk\app-debug.apk

adb shell am start -n com.deepseek.remote.deepseek_remote_app/.MainActivity

``



> 构建注意：Flutter 模板的 Gradle Wrapper 默认从 `services.gradle.org` 下载，本机直连超时；已把

> `android/gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl` 指向腾讯云镜像

> `https://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip`。换机器或换网络后可改回官方源。

> 另：工程路径含中文，`flutter analyze` 会崩（`FormatException`），请用 `flutter test` / `flutter build` 校验。



### 4.2 连接真实电脑（三件套 + 手机）



电脑上起后端、隧道、Agent（详细命令见 [`../research/M1_E2E_REPORT.md`](../research/M1_E2E_REPORT.md) §4）：



``powershell

# 1) 后端

$env:JAVA_HOME='C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1'

cd backend; C:\Users\user\dsh-tools\gradle\gradle-8.14.3\bin\gradle.bat bootRun --console=plain



# 2) 公网隧道（记下 https://<公网隧道>.trycloudflare.com）

tools\bin\cloudflared.exe tunnel --url http://127.0.0.1:8080 --no-autoupdate



# 3) Agent

$env:REMOTE_SERVER_URL='http://127.0.0.1:8080'

$env:M1_PAIRING_CODE='824613'

$env:M1_WORKSPACE_ROOT='<项目根>\agent\.m1ws'

cd agent; node scripts/serve.ts

``



手机上：AI 助手页右上角「⇄」→ 服务器地址填 `https://<公网隧道>.trycloudflare.com`、配对码 `824613` → 「测试连接」（应显示后端版本 + 电脑 Agent 在线）→ 「连接」→ 顶部出现「已连接真实电脑」→ 直接发指令。



> **M1.1 起还需要 PostgreSQL**（否则后端会因 Flyway 失败而启动不了）：推荐直接用一键脚本

> `powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-up.ps1`，它会按顺序拉起

> PostgreSQL（5433）→ 后端 → 隧道 → Agent，并把公网地址/配对码打印出来；关闭用 `tools\m1-down.ps1`。



> 隧道地址每次重启都会变；要固定地址需自备域名（见概念稿 D-1/D-2）。



> **M1.1 真实数据入口**：连上后 AI 助手页右上角「时钟」图标打开历史会话（点条目回填消息，断线重连自动按 `seq` 增量补齐）；任务中心自动切换为电脑端真实任务，右上「刷新」或下拉刷新，点任务卡查看事件时间线；项目管理展示电脑端 `M1_WORKSPACE_ROOT` 下的只读工作区。接口不符时以 `docs/design/M1_1_DELTA.md` 为准。



> **M2 起后台与重连**：连接成功后 App 启动前台服务并常驻「已连接 <设备> · DeepSeek Remote」通知（Android 13+ 首次连接会请求通知权限，拒绝不影响连接）；锁屏/切后台收到审批请求时发高优先级通知，点通知直接回到对应授权弹层（已处理/超时则提示「该审批已失效」）；后端重启或 token 失效（HTTP 401 / WebSocket 4401）时，App 会用本地地址+配对码自动重新配对并重连一次，失败才回连接页提示。验收细节以 `docs/design/M2_DELTA.md` 为准。



> **M2.1 起补拉与排队**：重连成功、App 回到前台、进入历史会话后，App 会用 `GET /api/v1/conversations/{id}/events?afterSeq=<lastSeq>` 循环补拉断线期间的事件（每页最多 500、拉到不足一页为止），按 `seq` 去重排序后与实时流走同一处理入口；补拉失败只显示「断线期间的事件同步失败」并可重试，不阻塞实时消息。任务执行中继续发送的指令不会报错，而是进入深度 1 的本地队列并显示「已排队」气泡（可移除），任务结束/失败/取消后自动发出。验收细节以 `docs/design/M2_1_DELTA.md` 为准。



> **M2.2 起手感升级**：任务终态后该轮「工具调用 + 思考」自动收成一行摘要（如 `已完成 4 步 · 用时 12s`，失败/取消换色），点击展开仍按原顺序显示；排队气泡新增「立即发送」——先发 `task.cancel` 打断当前任务，收到终态或 3 秒超时后自动把排队指令作为新 prompt 发出（不是真正的 turn 内插话）；「我的 → 外观」可切 6 套深色主题（原生 SharedPreferences 持久化）；AI 助手页右上「分享」生成 1080 宽竖版 PNG 分享卡（只含用户/助手正文 + 摘要 + 设备名/时间，路径与 token 已脱敏），经系统分享面板发送；气泡长按可复制/重新发送，工具卡片长按可复制输出。验收细节以 `docs/design/M2_2_DELTA.md` 为准。



> **M2.3 起视觉重构**：默认浅色（冷白底 + 白色卡片 + 蓝色主色），系统切深色时自动跟随；「我的 → 外观」提供跟随系统 / 浅色 / 深色三选，点选立即生效并重启保留。全部页面按新 token（颜色/圆角/间距/阴影）重做，版本号 `0.1.4-m2.3`。验收细节以 `docs/design/M2_3_UI_DELTA.md` 为准。



> **M2.4 起无演示数据**：未连接时六个页面统一为连接空态（图标 + 标题 + 一行说明 + 「连接电脑」按钮），不再展示任何假设备/假会话/假任务/假工作区/假审计/假配对码；连接后各页只保留真实功能，电脑页权限改一行摘要 + 弹层、项目页只读真实授权目录、我的页去掉审计与演示账号、连接页步骤压成一行小字。版本号 `0.1.5-m2.4`。验收细节以 `docs/design/M2_4_SIMPLIFY_DELTA.md` 为准。



## 5. 代码结构（M2.4 后）



``text

app/

├── pubspec.yaml                      # 零第三方运行时依赖（dart:io 实现 HTTP/WebSocket）

├── lib/

│   ├── main.dart / app.dart          # ThemeScope + LiveScope + MaterialApp（主题/分享网关注入；无 DemoStore）

│   ├── models.dart                   # 7 状态枚举 / ChatItem（seq/turnId/queued）/ TurnStats / TaskItem / TaskEvent

│   ├── theme/

│   │   ├── app_theme.dart            # M2.3 token 体系：浅/深 AppPalette + ThemeData + ThemeExtension（context.appPalette）+ 圆角/间距 token

│   │   └── theme_controller.dart     # ThemeController（跟随系统/浅色/深色三选 + 持久化）+ ThemeScope

│   ├── services/

│   │   ├── relay_protocol.dart       # 信封与事件类型（对齐 M1_PROTOCOL.md）

│   │   ├── workspace_models.dart     # M2.6 工作区/文件数据类 + 错误码中文映射（WorkspaceRequestException）

│   │   ├── pairing_api.dart          # health 探测 + POST /api/v1/auth/pair

│   │   ├── relay_client.dart         # WebSocket 连接/重连/事件流/发送（4401 → authFailures 流）

│   │   ├── history_api.dart          # M1.1 REST：历史会话/消息/任务；M2.1 事件增量（/events?afterSeq=）

│   │   ├── notification_gateway.dart # M2 通知/前台服务网关（MethodChannel + Fake 可注入）

│   │   ├── notification_prefs.dart   # M4.4 通知开关（任务做完提醒 / 等待授权提醒，SharedPreferences 持久化）
│   │   ├── settings_gateway.dart     # M2.2 设置持久化网关（MethodChannel + Fake）

│   │   ├── share_gateway.dart       # M2.2 系统分享网关（MethodChannel + Fake）

│   │   └── share_card.dart           # M2.2 分享卡数据构造/脱敏/Canvas 渲染 PNG

│   ├── data/

│   │   └── live_store.dart           # 真实会话状态（消息/任务/审批/历史 REST/通知/前台服务/自动重配对/事件补拉/排队/轮次统计/打断立即发送/M2.6 工作区请求-响应）

│   ├── screens/

│   │   ├── root_shell.dart           # 五 Tab 外壳（IndexedStack 保状态）

│   │   ├── connect_screen.dart       # 真实连接设置

│   │   ├── assistant_screen.dart     # 对话页（M4.2 去模式切换：空提示/自动折叠/分享/长按/常驻附件行/待绑定项目胶囊）

│   │   ├── tasks_screen.dart         # 含 LiveTaskDetailScreen 事件时间线

│   │   ├── workspace_screen.dart     # M4.0 工作区二级页（会话排序/新建会话/浏览文件/底部直发）

│   │   ├── plugins_screen.dart       # M3.6 插件双 Tab / 市场；M4.1 已安装 Tab 顶部「浏览本地插件」入口 + 市场卡片加厚

│   │   ├── plugin_gallery_screen.dart # M4.1 已安装插件画廊（内置/实验性/其他分组 + 逐项开关 + 过滤）

│   │   ├── projects_screen.dart      # M2.6 真实工作区根列表（浏览/在此项目发指令）

│   │   ├── project_browser_screen.dart # M2.6 逐级目录浏览（面包屑/下拉刷新/错误重试）

│   │   ├── file_viewer_screen.dart   # M2.6 只读文本预览（等宽/行号/复制/截断提示）

│   │   ├── control_screen.dart / profile_screen.dart（个人中心含外观主题入口与检查更新）

│   └── widgets/

│       ├── common.dart               # Panel / SlideToStop / EmptyHint / LiveScope（M2.3 token 化）

│       ├── empty_state.dart          # M2.4 统一连接空态（图标 + 标题 + 说明 + 连接按钮）

│       ├── chat_items.dart           # 气泡（排队气泡/立即发送/长按菜单）、思考折叠、工具调用/输出分块卡

│       ├── turn_fold.dart            # M2.2 轮次折叠（groupTurnMessages + TurnSummaryCard）

│       ├── timeline.dart             # M1.1 任务事件时间线（类型/工具/时间）

│       ├── workspace_create_dialog.dart # M4.0 新建工作区对话框（名字校验 + 预览路径 + 旧插件提示）

│       └── approval_sheet.dart       # 高风险授权弹层（倒计时 10:00 → 自动拒绝）

├── test/                             # 497 个测试（含 M3.6 新增 20、M4.0 新增 12、M4.1 新增 8、M4.4 新增 9、M4.5 新增 2、M4.6 新增 3、M4.9 新增 8、M4.10 新增 6、M4.11 新增 6、M4.12 新增 17、M4.13 新增 9、M4.14 新增 3、M4.18 新增 3、M4.19 新增 2、M4.21 新增 6、M4.22 新增 2、M4.25 新增 4、M4.26 新增 1、M4.27 新增 10、M4.28 新增 2、M4.29 新增 5、M4.30 新增 5、M4.31 新增 5、M4.32 新增 9、M4.33 新增 2、M4.34 新增 3、M4.35 新增 7、M4.37 新增 3、M4.38 新增 4、M4.39 新增 3，均不联网）

└── android/                          # 壳工程；Kotlin 原生桥：NotificationHelper / NotificationBridge / ConnectionService /

                                      # SettingsBridge（SharedPreferences）/ ShareBridge + ShareFileProvider（分享，share/ 与 updates/）/

                                      # UpdateBridge（系统安装器）

``



## 6. 视觉规范（M2.3）



- **配色**：冷白底 `#F6F7F9` + 白色卡片 `#FFFFFF` + 蓝色主色 `#2563EB`；深色模式同构（底 `#0B1220` / 卡片 `#121A2A` / 主色 `#5B8DEF`）。全部颜色来自 `AppPalette` token，经 `ThemeExtension` 暴露为 `context.appPalette.*`，主界面不再硬编码深色值。

- **形状与留白**：卡片/弹层 20 圆角（底部弹层顶部 24）、输入框/按钮 16、代码块 12、状态胶囊 999；页面左右 20、卡片内边距 16、卡片间距 12；标题 22/w700、卡片标题 14/w600、正文 14.2/1.6、小字 12.5、注释 11。

- **组件**：AppBar 透明底 22 标题；底部导航白底 94% + 顶部 1px 线 + 选中圆点；用户气泡蓝底白字 22/22/8/22，助手正文无气泡、左侧 3px 浅竖线；工具卡片 + 代码块 + 可折叠输出；折叠行/统计卡/筛选 chip/审批 Sheet 均按契约 §3 落地。

- **明暗切换**：浅色默认、跟随系统；「我的 → 外观」三选（跟随系统 / 浅色 / 深色）持久化到 `deepseek_remote/settings`（SharedPreferences），重启保留。

- **截图**：M2.3 浅色界面截图待补拍（本机无模拟器/真机）；旧深色截图见 §1.2。



## 6.1 M2.4：无演示数据 + 空态



- **删除**：`lib/data/demo_store.dart`（整文件）、`models.dart` 的 `DemoDevice/WorkspaceEntry/AuditEntry`、`common.dart` 的 `DemoBadge/StoreScope/ModeBadge`；`app.dart` 不再创建 DemoStore/StoreScope。

- **未连接**：六个 Tab 统一使用 `EmptyState`（图标 32 + 标题 15/w600 + 说明 12.5 + 主按钮「连接电脑」→ `ConnectScreen`）；AI 助手页「还没有连接电脑」、任务「连接后在这里看任务」、电脑「连接后在这里管理这台电脑」、项目「连接电脑后在这里浏览项目」（M2.6 起）；我的页保留账号/连接状态/外观/关于。

- **已连接**：AI 助手顶部只留一行状态条（圆点 + 设备名 + 已连接 + 会话切换 + 分享），对话/历史/审批/取消/折叠/主题/分享/紧急停止全部保留；任务页去掉统计三卡与副标题；电脑页合并为设备卡 + 权限摘要弹层 + 紧急停止；项目页只读真实授权目录；我的页去掉审计日志与演示账号；连接页步骤压成一行小字。

- **验收**：`grep -ri "演示" app/lib` 为 0；`flutter test` 164/164；APK `versionName=0.1.5-m2.4`、`versionCode=6`。



## 6.2 M2.5：应用内在线更新



- **入口**：「我的 → 关于」里新增「检查更新」行；未连接时点击会提示先连接（更新检查要打到电脑上的后端）。

- **流程**：`GET {serverUrl}/api/v1/app/version` → 服务端 `versionCode` 大于当前 `kAppVersionCode` 才提示 → 弹窗显示新版本号/大小 MB/更新说明 → 「立即更新」→ 流式下载到 `cacheDir/updates/app-update.apk`（`.part` 完成后 rename，按 size 校验，进度框不可关闭）→ 无「安装未知应用」权限先跳系统设置 → `content://` + `ACTION_VIEW` 调起系统安装器。

- **不做静默安装**：非系统应用无法绕过系统安装确认，最后一步必须用户点「安装」。

- **首次例外**：当前装机为 0.1.5（无更新模块），需手动安装一次 0.1.6；之后每次发版：替换电脑上 `dist/DeepSeek-Remote-latest.apk` + 改 `app.update.version-code/version-name` → 重启后端 → 手机点「检查更新」。

- **验收**：`flutter test` 178/178；`aapt` → `versionName=0.1.6-m2.5`、`versionCode=7`；接口本地与公网隧道均 200（详见 `docs/research/M2_5_REPORT.md`）。



## 6.3 M2.6：项目同步（只读浏览 + 项目内发指令）



- **协议**：手机端通过 WSS 发 `workspace.list` / `file.read`（payload 带客户端生成的 `requestId`），Agent 用 `workspace.list.result` / `file.read.result` 按 `requestId` 回包；这些回包**不占会话 seq、不进消息流与任务时间线**，只交给 `LiveStore` 的 pending 表（未知 `requestId` 直接丢弃）。失败时同一 result type 返回 `{ok:false, code, message}`，手机端映射为中文可展示文案（`PATH_NOT_ALLOWED`/`DIR_NOT_FOUND`/`FILE_NOT_FOUND`/`BINARY_FILE`/`TOO_LARGE`/`TIMEOUT`/`OFFLINE` 等）。

- **入口**：项目页 → 工作区卡（名称/路径/「浏览」「在此项目发指令」）→ 目录浏览页（面包屑可回上级、目录在前、文件显示大小/修改时间、下拉刷新、错误重试、底部「在此目录发指令」）→ 文件预览页（等宽、行号开关、横向滚动、顶部大小/修改时间/sha256 前 8 位、`truncated` 提示、复制全部；二进制/超大用 `EmptyState`）。

- **项目内发指令**：点「在此项目/目录发指令」→ `LiveStore.setPendingWorkspace(root)` → 自动切到 AI 助手并显示「项目：<目录名>」胶囊（可移除）→ 下一条指令触发 `conversation.create` 时带 `workspacePath`，创建成功后自动清除。

- **代码**：新增 `lib/services/workspace_models.dart`、`lib/screens/project_browser_screen.dart`、`lib/screens/file_viewer_screen.dart`；改写 `lib/screens/projects_screen.dart`；`live_store.dart` 加工作区请求-响应（20s 超时、断线清理 pending）；`relay_protocol.dart` 加 4 个 type 常量；`assistant_screen.dart` 加待绑定项目胶囊；`root_shell.dart` 传入 Tab 切换回调。

- **验收**：`flutter test` 190/190 全绿（新增 `test/project_sync_test.dart` 12 项，纯 fake socket 不联网）；`aapt dump badging` → `versionName=0.1.7-m2.6`、`versionCode=8`；debug APK 150,820,399 bytes。

- **已知限制**：手机端只读（不支持写入/重命名/删除）；二进制与超大文件不可预览（默认请求 256KiB，`truncated` 时仅显示前段）；`.git`/`node_modules` 等忽略目录不展示（`ignoredCount` 计数）；需电脑端 Agent 上报 `capabilities.workspaceList/fileRead`，旧版 Agent 会提示升级。



## 6.4 M3.6：插件双 Tab / 插件市场 + 桌面会话「到最新」



- **协议**（电脑端插件新增，旧版插件 404，App 必须优雅降级）：

  - `GET /api/v1/desktop/plugins/bundles` → `{bundles:[{name,version,description,enabled,installed,removable,plugins:[{id,name,rowId,enabled}]}]}`；子插件 `enabled` 可为 `null`（未知时不显示开关）。

  - `POST /api/v1/desktop/plugins/bundles/enabled` body `{name,enabled}`。

  - `GET /api/v1/desktop/plugins/market?url=&query=` → `{indexes:[{url,title,description}],source,query,entries:[{name,title,version,description,author,tags,installed,installedVersion}],installedBundles,error}`。

  - `POST /api/v1/desktop/plugins/market/install` body `{spec,approvedBuilds?}` → `{ok:true,...}`，可能含 `pendingBuilds`（数组）与 `nextStep`；`POST /api/v1/desktop/plugins/market/remove` body `{name}`。

  - 桌面任务行新增 `lastTime`（**毫秒时间戳 number**，显示时转「HH:mm」/跨天「MM-dd HH:mm」）、`messageCount`、`lastSeq`、`running`；`TaskRecord` 用 `int? lastTime` 解析（兼容数字字符串与 ISO 字符串）。

- **插件页**：`PluginsScreen` 重写为 `TabBar` 双 Tab（「已安装」「插件市场」）。

  - 已安装：优先 bundles，按包分组（名称去掉 `@deepseek-ai/` 前缀）、版本/描述、bundle 级 `Switch`（`setBundleEnabled`）、展开后子插件 + 各自开关（`setPluginEnabled`）；接口 404/失败自动回退 `listPlugins()`，只显示名字含 `dsh-plugin`/`plugin-` 的条目，其余折叠进「系统内置（N）」，顶部浅色提示「当前电脑插件版本较旧，升级后可按插件包分组。」；加载失败可重试，空列表用 `EmptyState`。

  - 插件市场：搜索框（回车/按钮）+ 索引下拉（默认全部）；条目显示标题/版本/作者/两行描述/tags，未安装显示「安装」、已安装显示「已安装 vX」+「卸载」。安装两次确认（第二次展示 `pendingBuilds` 名称与 `nextStep`，同意后带 `approvedBuilds` 重调），成功 SnackBar 并刷新已安装 Tab；市场 404 显示「电脑端插件需要升级到支持插件市场的版本」+ 重试。

  - 所有异步操作有 loading 态与按钮防重复（`_busyKeys`/`_installing`/`_removing`）。

- **桌面会话新鲜度**：`sortDesktopTasks`/`sortDesktopTaskItems`（`lib/services/desktop_sort.dart`，纯函数）：有 `lastTime` 的在前并按时间戳倒序，没有的回退 `updatedAt` 倒序，相等保持原顺序。任务卡显示「N 条消息」与最后活动时间；`DesktopSessionScreen` 加 `WidgetsBindingObserver`，`AppLifecycleState.resumed` 时重新 `_load(initial: true)`；首次加载在 `postFrameCallback` 里强制 `jumpTo(maxScrollExtent)`（即使事件数为 0 或用户不在底部）。

- **代码**：`services/history_api.dart`（`PluginBundle`/`MarketEntry`/`MarketIndex`/`MarketSearchResult`、5 个新方法、`TaskRecord.lastTime/messageCount/lastSeq`、`PluginInfo` 兼容 `entryId/moduleName` 旧行）；`data/live_store.dart` 透传 + 桌面任务排序；`services/desktop_sort.dart`、`screens/plugins_screen.dart`（重写）、`screens/tasks_screen.dart`、`screens/desktop_session_screen.dart`、`models.dart`（`TaskItem.messageCount/lastTime` + `formatLastTime`）。

- **验收**：`flutter test` 244/244 全绿（新增 `test/plugin_market_test.dart` 10 项、`test/desktop_freshness_test.dart` 10 项，均不联网）；`aapt dump badging` → `versionName=0.3.6-m3.6`、`versionCode=25`；debug APK 177,899,089 bytes。

- **已知限制**：插件市场/插件包分组要求电脑端插件升级到对应版本，旧版只能看扁平列表（已折叠系统模块）；市场安装只透传 Host `installBundle` 结果，构建脚本必须由用户在手机上二次确认；`lastTime` 仅用于展示与排序，不参与服务端查询；工程位于中文路径，`app/android/gradle.properties` 关闭了 Kotlin 增量编译（`kotlin.incremental=false`），否则 `mobile_scanner` 偶发 `Could not close incremental caches` 构建失败。



> **M4.0 工作区**：任务页工作区胶囊常驻并带「＋ 新建工作区」；新建走电脑端 `POST /api/v1/desktop/workspaces`（body `{name}`），在**第一个授权根目录**下建子目录，非法字符替换为 `-`，同名复用；成功后 App 立即把新目录加进 `workspaceRoots` 并跳进工作区页。工作区页列出该目录下的会话（`sortDesktopTaskItems` 倒序 + 状态徽标 + `N 条消息` + 最后活动时间），可下拉刷新（5 秒轮询）、AppBar 新建会话（可命名）/浏览工作区文件/刷新，底部输入条直接把指令发给该工作区**最新会话**。

> **M4.0 骨架修复**：Hub 连上手机时先发一条骨架 `device.status`（设备名写死 `DeepSeek Harness`、不带 `workspaceRoots`），Agent 的完整版随后到达；之前骨架会把 `workspaceRoots` 清空，导致工作区页/新建工作区瞬间变空。现按设备名判断：骨架只更新能力位，不动目录；Agent 真实上报空目录时仍照常清空。



> **M4.1 插件页对齐**（2026-11-13）：电脑端 DSH 的「插件」页有「内置插件配置 / 实验性插件」分组和逐项开关，手机端原来只能看到插件包（bundle），没有同级的本地插件视角。现在「已安装」Tab 顶部加「浏览本地插件」入口 → 新页面 `plugin_gallery_screen.dart`，数据来自插件新增的 `GET /api/v1/desktop/plugins/gallery`（Host `pluginManager.listPlugins()` 的 `meta.title/description/experimental` 中文兜底 + 文件名正则分组），开关仍走 `POST /desktop/plugins/enabled`，与电脑端同源。

> **M4.1 市场为空根因**：电脑端 DSH 的 `pluginMarket.listIndexes()` 只返回「设置里配置过的索引 URL」，本机一个都没配 → 空数组，手机端市场永远只有空索引。插件端在 `indexes.length === 0` 时改用公开索引 `https://api.dshmarket.com/v1/index.json`（`defaultIndex=true`、带 `refresh: true` 让 Host 现场拉取），并用新签名 `search(url, { query: { text, limit, offset, order } })`（旧签名 `{query, limit}` 在新 Host 上会被拒）；0 条时再按 `order:'stars'` 重试。条目新增 `downloads`/`stars`，手机端用 `319万` / `6.9k` 紧凑格式展示。

> **M4.1 验收**：`flutter test` 263/263 全绿（新增 `test/plugin_gallery_test.dart` 8 项）；release APK 71,720,030 bytes、`versionName=0.4.2-m4.1`、`versionCode=28`；`tools/verify-plugin-m4.ps1` 扩到 8 项（新增 gallery 分组、市场索引兜底两项）。

> **M4.1 已知限制**：市场索引兜底依赖外网 `api.dshmarket.com`，离线时市场仍为空（已安装插件画廊不受影响）；画廊分组靠 `moduleName` 正则 + `meta.experimental` 推断，个别插件可能落进「其他插件」；开关改动要重启 DSH 才完全生效（与电脑端一致）。

> **M4.2 AI 助手页 = 对话页 + 附件真正可用**（2026-11-13）：删掉「手机 / 电脑」两档切换和整屏欢迎大图，连上电脑后打开就是消息流 + 输入框；空对话只留一行提示和三个建议胶囊。附件入口从「+」二级菜单提到输入框上方常驻的**拍照 / 相册 / 文件**三个胶囊（`_AttachmentBar` 重写：图片显示缩略图、显示「附件会存到电脑「X/手机附件」」）。关键修复：上传时带 `workspace`（工作区名），电脑端插件 0.2.11 把附件落到 `<授权根>/<工作区名>/手机附件/`（以前落在 `%USERPROFILE%\.dsh\dsh-plugin-m1\uploads`，电脑端 AI 根本找不到），发送后弹「已上传到电脑：N 个文件（工作区）」回执。`flutter test` 267/267；release APK 71,867,762 bytes、`versionName=0.4.3-m4.2`、`versionCode=29`。

> **M4.2 已知限制**：附件只能落到一级工作区目录，深目录工作区退回当前会话 cwd；单文件仍限 20 MiB；云端直连页（不连电脑）仍不带附件；底部输入条固定发最新会话；**交付时 adb 掉线，真机未复测**。

> **M4.3 直播页「已运行」与电脑端对齐**（2026-11-13）：以前直播页的「已运行」从「手机打开页面的时刻」开始数，所以同一个任务在手机上永远从 0:00 起，与电脑端对不上。现在插件把每条会话事件自带的 `time`（毫秒）随事件下发，手机端取日志里**最新一条 `turn-start` 的时间**作为起点（也就是电脑上这一轮真正开始的时刻），超过 1 小时显示 `H:MM:SS`；旧插件没有时间时依次退回任务行最后活动时间、会话 `updatedAt`。`flutter test` 277/277；release APK 71,867,762 bytes、`versionName=0.4.3-m4.3`、`versionCode=30`。
> **M4.3 已知限制**：若某轮日志里没有 `turn-start`，起点退回「最后活动时间」，显示的时长会略短于电脑端；手机与电脑系统时钟不同步时会有同等偏差；本批交付 adb 无设备，真机未复测。
>
> **M4.4 任务完成 / 等待授权通知**（2026-11-13）：以前只有「等待授权」和「断线」两类通知，电脑上的任务跑完手机端**完全没有提示**。现在新增 `task_updates` 通知渠道：任务从「执行中」变成完成 / 失败 / 取消时（REST 任务列表与插件桌面镜像两条路径都覆盖），App 在后台会弹一条「任务已完成：<会话名> · <工作区>」；等待授权时除原有通知外，再发一条带「允许 / 拒绝」按钮的常驻通知，可在通知栏里直接决定（回传 `onApprovalDecision`，与弹窗内决定同一条链路）。点「任务完成」通知会切到「工作区」页；「我的 → 通知」新增「任务做完提醒」「等待授权提醒」两个开关（SharedPreferences 持久化）。前台不打扰；重连后第一轮任务快照只做基线，不会把历史结果当成「刚做完」。`flutter test` 286/286；release APK 71,933,294 bytes、`versionName=0.4.4-m4.4`、`versionCode=31`。
> **M4.4 已知限制**：只在 App 处于后台时提醒（前台不发，避免重复打扰）；App 被系统杀掉后不会有通知，需要前台服务或厂商推送才能补上；通知按钮决定依赖 App 进程存活，进程被杀时点按钮只会打开 App；会话名取历史会话标题，取不到时退回工作区末段目录名。

> **M4.5 更新进度条分帧**（2026-11-13）：插件中继跑在本机回环网络上，71.9 MB 的 APK 实测 0.1 秒就下完，下载弹窗里的进度条只来得及刷一帧就跳去调系统安装器，看起来像「进度条不动」。现在 UpdateService.download() 用 pace() 把响应流按 256 KiB 分帧、两帧至少隔 30 ms 再回调 onProgress，进度条会一路走到 100%（约十几秒）再调起安装器；文件内容与落盘逻辑不变。flutter test 288/288；release APK 71,933,298 bytes、versionName=0.4.5-m4.5、versionCode=32。
> **M4.5 已知限制**：只改上报节奏，实际下载时长仍取决于本地中继速度；极端慢速网络下仍按 chunk 到达节奏走；本批 adb 无设备，进度条观感未真机复测。


> **M4.6 AI 助手分手机和电脑**（2026-11-14）：M4.2 曾把「手机 / 电脑」两档切换去掉，用户要求恢复，且**默认停在手机档**。`assistant_screen.dart` 重新引入 `_ModeSwitch`（IndexedStack 里两档常驻：手机档=内嵌 `CloudChatScreen` 云端直连，电脑档=电脑对话+附件+直播），手机档顶栏胶囊显示「云端直连 · <模型名>」或「云端直连 · 未设置接口」，点它直接打开接口设置弹层（`CloudChatController.editConfig()`）；云端页的加载转圈改成静态文案，避免常驻时页面永不停帧。
> **M4.6 已知限制**：手机档的云端设置走 `CloudChatStore`（地址 + Key 存本机），不会同步给电脑；两档常驻会同时持有两个会话状态（内存占用略增）；本批真机仍未复测（`adb devices` 无设备）。
> **M4.7 手机档也能发照片 / 文件**（2026-11-14）：用户反馈「AI 助手手机页面怎么没有上传文件图片拍照的」——手机档（云端直连）之前只有输入框和发送键。现在两档共用 `lib/widgets/attachment_bar.dart` 里的 `PendingAttachment` / `AttachmentPicker` / `AttachmentBar`：手机档输入条上方同样常驻**拍照 / 相册 / 文件**三个胶囊，选好的附件在发送时直接塞进请求——图片按 OpenAI 兼容的 `content: [{type:text},{type:image_url,image_url:{url:"data:image/png;base64,…"}}]` 发给支持视觉的模型，文本类文件（md/dart/json/csv…）内联成「【附件 文件名】」段，其它二进制只发文件名提示；用户气泡里显示附件缩略图。未配置接口时仍显示设置引导，并补一句「要发图片，请填支持视觉的接口」。`flutter test` 301/301。
> **M4.7 已知限制**：图片走 base64 直接进请求体，原图大时请求会慢（相册/拍照已压到 2400px 以内）；文本文件超过 20000 字会截断；云端接口必须支持视觉才能看图（DeepSeek 对话模型不支持图片输入，会报错）；附件只在当前对话内有效，不落盘、不能重发。

> **M4.8 「不用上传」**（2026-11-14）：用户说「不用上传，就和正常的 ai 一样可以处理各种问题」——界面里彻底去掉「上传」字样：电脑档发完附件不再弹「已上传到电脑：N 个文件」，指令里的列表改成「附件：」，附件条上传中显示「正在读取…」。手机档新增 `CaretakerReader` 契约：图片和文本照旧直发云端模型，PDF / Word / Excel 这类手机解析不了的文件交给电脑读成文字再随消息发（`POST /api/v1/desktop/file/read`，电脑离线或接口不存在时静默退回「只发文件名」，不影响发送）。手机档首次使用引导重写：说明「手机档不经过电脑、Key 只存在这台手机上」，并给出「去开放平台生成 Key → 回来粘贴」两步。`flutter test` 307/307。

> **M4.8 已知限制**：手机端必须用自己生成的 API Key；DeepSeek 官方对话模型不接收图片，要发图需在设置里改成支持视觉的模型（gpt-4o、Kimi vision 等）；电脑端插件尚未实现 `/desktop/file/read`，PDF / Word / Excel 目前仍会退化成「格式不支持在手机上预览」；仍未真机复测（`adb devices` 无设备）。
> **M4.9 工作区文件都能打开了**（2026-11-14）：用户说「工作区的有些文件无法预览」——原来 `FileViewerScreen` 只有文本预览，图片 / PDF / Office 一进去就是「无法预览」（插件按 NUL 字节判二进制直接抛 `BINARY_FILE`）。现在按扩展名分流：图片走新增的 `GET /api/v1/desktop/file/raw` 取原始字节，在 App 内用 `InteractiveViewer` 放大看；PDF / Word / Excel / PPT 同样下载到手机缓存，再用 `content://`（FileProvider `preview/` 路径）+ `ACTION_VIEW` 交给 WPS 或系统阅读器打开；文本文件照旧。插件新增 `POST /api/v1/desktop/file/read`（pdf-parse 读 PDF、JSZip 抽 docx/pptx/xlsx 的 XML 文字，上限 2 MB），手机档把 PDF / Word 交给它读成文字随消息发送。插件 0.2.13，`flutter test` 344/344、`node --test` 15/15。
ode --test 15/15。

> **M4.9 已知限制**：`file/raw` 上限 20 MB、`file/read` 上限 2 MB；`.doc/.xls/.ppt` 旧格式不支持（提示另存为 docx/xlsx/pptx）；图片以外的一切都依赖手机上装了能打开它的 App；需要电脑端插件 0.2.13+（旧版 `file/raw` 返回 404，界面会提示升级插件）；仍未真机复测（`adb devices` 无设备）。
> **M4.10 会话存档：手机端不再「看起来全丢了」**（2026-11-15）：用户说「为什么又看不到所有的项目了」——DSH 重启后旧会话从列表里整条消失。查下来会话文件都还在 `~/.dsh/sessions/`，只是 Host 的 JSONL 后端只认「已物化」的日志（只剩 header 的会话 `readGenerationHeader` 返回 `undefined`，整条 invisible），不是手机端也不是重启杀掉的。插件 0.2.14 起自己维护存档 `session-archive.json`：每 30 秒把运行中的会话吸进来，并扫描磁盘上存档里还没有的会话日志（自己按帧解 zstd，`zlib.zstdDecompressSync` 只解第一帧）。手机端在「工作区」页底部多出一组「以前跑过、电脑上已经看不到的会话」，点开是带「已存档」标记的只读直播（不轮询、没有输入条）。新增 `GET/POST /api/v1/desktop/archive/sessions` 与 `GET .../archive/sessions/:id`。`flutter test` 344/344、`node --test` 15/15。

> **M4.10 已知限制**：存档只是「能看」，不能继续发指令（电脑那边已经没有这条会话）；磁盘扫描只补存档里没有的会话、单会话最多 1500 条事件、正文每段截断 4000 字，最多保留 400 条会话；需要电脑端插件 **0.2.14+**（旧插件存档接口 404，手机端静默不显示这一组）；`session-archive.json` 生成要等 DSH 重开之后（首次最多 30 秒）；仍未真机复测。

> **M4.11 工作区页不再「看起来项目全丢了」**（2026-11-16）：用户说「为什么又看不到所有的项目了」——DSH 重开后电脑端会话列表会被清空/重建，而手机端「工作区」页的卡片是从会话列表派生的，列表一空，电脑端授权的 9 个目录就只剩一两个卡片。现在 `app/lib/screens/tasks_screen.dart` 新增`_idleWorkspaces` 与 `_WorkspaceCard`：授权过的每个目录都占一张卡（没有会话时标「暂无会话」，点进去照常新建会话 / 看存档 / 浏览文件）；存档分组也不再被「进行中 / 等待授权 / 失败」筛选挡掉。插件 0.2.19 让存档列表挡掉 `agent\.m1ws`、`agent\.workspaces\contract-*` 这类测试临时目录（存量记录不删、只是不展示），并补上 `node:fs` 的 `statSync` 导入。

> **M4.11 已知限制**：「暂无会话」卡片只反映当前电脑列表（电脑上真删目录后要等注册表 5 秒缓存 + 手机端 5 秒轮询才消失）；存档仍只能看不能继续发指令；需要插件 0.2.19+ 才没有测试临时目录；仍未真机复测（`adb devices` 无设备）。

> **M4.12 对话正文按 Markdown 排版**（2026-11-16）：用户发来 DeepSeek 官方 App 的对话截图问「你的对话不能做成这样的吗」。差别不在链路而在**正文渲染**——助手回复以前只认 `**加粗**` 和 `` `代码` ``，`###` 标题、`- ` 列表、三反引号代码块、`|` 表格全原样露字。新增零依赖的 `app/lib/widgets/markdown_text.dart`：`MarkdownParser.parse()` 出 `MdBlock`（`heading/paragraph/bullet/ordered/quote/code/table/rule`），`buildInlineSpans()` 处理行内加粗 / 代码 / 删除线 / 链接 / 斜体，`MarkdownText` 负责块间距与缩进；代码块有 34 高的顶栏（语言标签，空语言显示 `text`，右侧「复制」把原始代码写剪贴板），表格是 `Table` + 表头底色 + 0.8 分隔线。`chat_items.dart` 的 `_AssistantText` 改用 `MarkdownText`，底部常驻「复制 + 时间」（`_AnswerActions`）；`cloud_chat_screen.dart` 的 `_Bubble` 去掉 320 宽上限与边框卡片，助手消息无气泡直接排版、用户消息保留右侧气泡；`app_theme.dart` 补 `Noto Sans CJK SC` / `Source Han Sans SC` 回退字体。中文标题用 `FontWeight.w600` 而不是 `w700`（CJK 没真粗体，w700 是伪加粗、小字号下发糊）。App 0.4.12+39、`flutter test` **344/344**（+17）。同批插件 0.2.20：`resolveUploadDir` 先按名字命中工作区列表（`knownWorkspacePaths()` + `findWorkspaceByName()`），修「附件悄悄落回 `%USERPROFILE%\.dsh\dsh-plugin-m1\uploads`」，`node --test` 31/31。
> **M4.13 工作区按项目分组**（2026-11-16）：用户发来手机「工作区」页截图说「按照工作区项目分类，做成和电脑上一样的，可以折叠打开，并且可以新建对话，新的项目区是建立在电脑端"D:/用户/项目"这个文件里面」。原来是**平铺的会话卡**（任务卡 + 空目录卡 + 底部「以前跑过…」存档组），同目录的多个会话各占一张，项目一多就看不出归属。现在每个目录一张 `_ProjectGroupCard`：头部整行点折叠/展开（`_collapsed` 记路径），会话与存档都挂在所属项目下，空目录标「空项目」胶囊；分组逻辑抽成零依赖纯函数 `app/lib/services/project_groups.dart`（`ProjectGroup` / `projectNameOf` / `parentPathOf` / `groupWorkspacesByProject`），`_WorkspaceCard` 删除。胶囊与对话框文案改成「新建项目」，`parentDir` 固定成 `D:\Projects\项目`（授权根里没有它时退回第一个授权根并提示「电脑端没授权 …」）。插件 0.2.20 配套：`resolveParentDir()`（授权根本身/子目录，或目录真实存在）、`projectParentPath()`、`createDesktopWorkspace(name, parentDir)`，`listDesktopWorkspaces()` 每行带 `parent` 与 `isProject`。App 0.4.13+40、`flutter test` **353/353**（+9），插件 `node --test` 39/39（+8）。

> **M4.37 往上拽一下就开新对话**（2026-11-18）：手机档对话里把消息列表翻到顶端后继续往下拽超过 130 像素，顶部浮出「松手开始新对话」，松手就新建一条；中途松手回退则作废。判定只认到达顶端之后的越界量（`OverscrollNotification.overscroll < 0`），反向拖回或列表开始滚动都会作废；列表加了 `AlwaysScrollableScrollPhysics`，短对话里也能拽。App 0.4.37+63。
> **M4.37 已知限制**：只有手机档（云端直连）有这个手势，电脑档是直播会话不适用；阈值写死 130 逻辑像素；拽的过程中没有跟手的位移动画，只有提示浮现；新建后原对话仍保留在「对话记录」里，但不会自动归档。
> **M4.36 提问卡的「提交」钉在卡片底部**（2026-11-18）：M4.35 只是把整块卡片塞进滚动区，按钮仍会跟着选项滚出屏幕——用户的原话是「有通知，只是划不动提交不了」。现在 `_QuestionCard` 自己排版：标题行与「跳过 / 提交」是固定子项，中间选项区 `Flexible(fit: FlexFit.loose)` + `SingleChildScrollView` 在里面滚；卡片高度按内容自适应（上限屏高 55%），一个问题两个选项的短卡片不再白占半屏。App 0.4.36+62。
> **M4.36 已知限制**：选项超过 6 个时要在卡内滚较远（没有折叠）；「发送中…」期间按钮置灰但没有进度；卡片区固定占屏高 55% 是硬编码比例，横屏与小屏没有单独适配。
> **M4.35 提问卡不再把整页卡死 + 等回答会通知**（2026-11-18）：桌面直播页把授权卡与提问卡钉在对话列表上方、两张卡自己不滚，两个问题三四个选项就把 `Expanded(ListView)` 挤成 0 高——看起来就是「划不动」。现在这块限高屏高 55%（`ConstrainedBox` + `SingleChildScrollView`），超出在卡内滚动，对话列表始终留得下；同时提问第一次接上通知：`LiveStore.notePendingQuestions()` 在 5 秒轮询拿到新提问时发「电脑在等你回答 · <标题>」（`showTaskUpdate`，key `question-<questionId>`，重复不重发、答完收回），开关沿用「我的 → 通知 → 等待授权提醒」。App 0.4.35+61。
> **M4.35 已知限制**：通知只在工作区那颗 5 秒定时器里发，手机进程被杀或没连电脑就完全没有；正开着那张卡也会响；点通知只落到工作区，不直达会话；卡片内容超过屏高 55% 时仍需卡内滚动才看得全；真·锁屏推送（前台服务 + 原生通道）仍未做。
> **M4.34 手机对话从工作区挪到抽屉**（2026-11-18）：M4.30 为了「找得到存档」把手机档（云端直连）的对话放进了工作区顶部，用户明确纠正「手机对话记录不保存到工作区，保存到这」——配图红圈是抽屉里的「历史会话」区。现在工作区整段不再出现手机对话（组件、状态、参数、import 一并删掉）；抽屉在「历史会话」标题上方新增「📱 手机对话 · N」小段，列标题与 `N 条消息 · 相对时间`（最多 6 条，全部记录仍在 AI 助手页右上角时钟里），点一条关抽屉 → 切到 AI 助手 → 打开那一条（仍走 `CloudChatIntent` 单向广播）。`RootShell` 新增可注入的 `conversations`，`AssistantScreen` 把同一份存储透传给内嵌 `CloudChatScreen`，这样 widget 测试不会在 fake-async 里真实读盘挂住。App 0.4.34+60。
> **M4.34 已知限制**：抽屉只列最近 6 条；只存文字，附件不进历史；只在这台手机上，没有云同步；「历史会话」（电脑端）与「手机对话」靠两行小标题区分，没有合并成一段统一时间排序。
> **M4.33 余额卡片上的「去充值」**（2026-11-17）：用户问「手机上能做到直接充值吗」。查 Host `deepseekAccount` 的 13 个方法，**没有任何下单或付款接口**，`getPlatformSession()` 还是 Host-only 凭证，所以手机只能跳官方充值页。新增 `UrlOpener`（channel `deepseek_remote/update` 的方法 `openUrl`，Kotlin 侧只放行 http/https），已连接时余额卡片右侧出现「去充值」，打不开则提示「可以在电脑上充值后再点右侧刷新」。App 0.4.33+59。
> **M4.32 余额卡片的排版与数字**（2026-11-17）：用户发「这对吗」的截图——金额写成了 `¥12.443675700000000`，左侧标题被长数字挤成每行一个字，赠送余额显示 `$0`。Host 真实返回是 `[{USD 0E-16}, {CNY 12.4137841000000000}]`。现在 `formatMoneyAmount()` 统一两位小数（`0E-16` → `0.00`），`AccountBalance.primary` 优先「非零的 CNY」，金额用 `FittedBox` 限宽、标题列 `maxLines: 2`，赠送余额全零时整行不显示。App 0.4.32+58。
> **M4.31 手机端也能回答电脑的「确认需求」**（2026-11-17）：提问以前只在「手机正停在那条会话的直播页」时才被手机接管（`isWatching(sessionId)`），所以电脑上弹「确认需求」时手机一无所知。插件 0.2.30 改成「正在看这条会话 **或** 手机还连着」就接管，并新增 `GET /api/v1/desktop/pending` 给跨会话摘要；手机端 0.4.31+57 在工作区顶部显示「确认范围 · 还有 N 个」提示条，点一下进那条会话直接选。插件 `node --test` **101/101**、`flutter test` **414/414**（新增 `pending_question_m4_31_test.dart` 5 例）。
>
> **M4.31 已知限制**：提示条只在工作区顶部，AI 助手页与插件页看不到；只覆盖「提问」，等待授权的权限审批仍走老条件；手机连着就接管，如果人不在手机旁，提问会等 5 分钟超时后按「跳过」放行。**插件 0.2.30 需要完整退出 DSH 再重开**（`HMR transactions cannot be nested` 第三次挡路），重开前 `/desktop/pending` 回 404，App 按「看不到」处理、不弹错。
>
> **M4.30 手机档的对话自动「存档」到工作区**（2026-11-17）：手机档（云端直连）的对话从 0.4.27 起就每条写进应用私有目录的 `cloud_conversations.json`（发问立刻存一次、回复或失败后再存一次），但入口只在 AI 助手页右上角那颗时钟的侧栏里——「工作区」当时只列电脑端的任务与存档会话，所以用户觉得「没存档」。现在工作区顶部多了一组「手机对话」：标题、`N 条消息 · 相对时间`、「只存在这台手机上」，最近 5 条，**没连电脑也显示**；点一条切到手机档并打开它（`CloudChatIntent` 单向广播 → `AssistantScreen` 切档 → `CloudChatScreen.openConversationById()` 读盘选中）。`flutter test` **409/409**（新增 5 例）。

> **M4.30 已知限制**：工作区只列最近 5 条（全部记录仍只在 AI 助手侧栏）；只存文字，附件不进历史；只在这台手机上，没有云同步；手机档对话不并入「项目分组」，所以在工作区里单独一组。

> **M4.29 下载卡片上的取消与后台下载**（2026-11-17）

「检查更新」下载 70 MB 时那张卡片以前只有一根进度条：既停不下来，也不能先收起来去做别的事。现在卡片底部有两个按钮：

- **取消下载**：`UpdateService.download()` 现在接受 `UpdateCancelToken`，每写一帧查一次标记（最长 30 ms），取消时抛 `UpdateCancelled`，**先关文件句柄再删**半截 `.part`——Windows 上对着还在写的文件调 `delete` 会失败，这一点在测试里抓出来过（「取消后 `.part` 仍在」）。
- **后台下载**：下载从 `_UpdateCheckTileState` 搬到了 `app/lib/services/update_download_center.dart` 的 `UpdateDownloadCenter`（`ChangeNotifier` + 全局单例）。卡片是这个中心的观察者，所以点「后台下载」、点遮罩、按返回键都只是收窗口，下载照跑；回到「检查更新」点一下可以接着看进度，下完直接调安装器。页面的 `dispose()` 只摘监听，**不取消下载**。

顺带把 M4.26 的坑从根上拔了：进度弹窗现在用 `AnimatedBuilder(animation: _center)` 直接订阅下载中心，不再依赖「外层 setState 顺便刷弹窗」。

副标题会跟着状态走：`下载中 N% · 点开可以看进度或取消` / `已下载好 v… · 点这里安装` / `已取消下载 · 点一次重新开始` / `上次下载失败 · …`。

> **M4.29 已知限制**

- 「后台」是**进程内**的：App 被系统杀掉时下载仍会断（没有走 Android 前台服务下载）。
- 没有断点续传：取消后再点是**从头**下 70 MB。
- 真机还没复测过「下载中切走再回来」的实际手感。

> **M4.27 手机档能新建对话、记录留在侧端**（2026-11-17）

云端直连以前只有一条对话：`_messages` 只活在内存里，`_newChat()` 就是 `_messages.clear()`，退出页面全丢，也没有地方翻历史。现在：

- 新增 `app/lib/services/cloud_conversations.dart`：`CloudChatRecord` / `CloudConversation` / `conversationTitle()` / `CloudConversationStore`，写应用私有目录的 `cloud_conversations.json`（坏文件当空库、按更新时间倒序、最多 80 条）。
- 对话页新增 `conversations` 注入参数与 `_loadConversations()`（与接口配置分开读，读盘慢不拖首屏）、`_persist()`（发问后立刻落盘，断网也不丢；回复或失败原因再落一次）、`_newChat()`（当前空对话复用，否则真另起一条）、`_openHistory()`（`showGeneralDialog` + 从左侧滑入 82% 宽的面板，列出标题、消息条数、相对时间，当前高亮，右侧删除）。
- 首页手机档顶栏那颗「历史」按钮接到 `CloudChatController.openHistory()`（以前手机档没传 `onHistory`），tooltip 改「对话记录」。
- 测试：新增 10 例（存储 5 例：存读往返与倒序、无标题取第一句、标题压缩截断、只留最近 N 条、坏文件当空库；widget 5 例：打开显示最近那条、侧栏列出并切过去、新对话另起一条且写回、删一条不丢别的、重开后话还在），`flutter test test/` **397/397**。App `0.4.27+53`，插件不变（0.2.29）。

> **M4.27 已知限制**：①附件不进历史，只存文字，历史里翻到带图那条不会重现缩略图；②`cloud_conversations.json` 只在手机本地，删 App 或清数据就没了，没有云同步与导出；③切换对话不做上下文压缩，每条对话把全部历史原样发给模型；④标题只能自动取第一句、不能改名；⑤踩坑：`testWidgets` 跑在 fake-async 里，真实文件读写永远不会完成（探测时一条 widget 测试挂了 10 分钟直到超时），所以 widget 测试必须注入内存假存储，真文件只由纯 Dart 的 `test()` 覆盖；`controller.openHistory()` 要用 `unawaited` 调用，否则 `await` 会等到弹窗关闭才返回。

> **M4.26 下载进度条终于会动**（2026-11-17）

用户发截图说「这个进度条都不动」：弹窗「正在下载 v0.4.25-m4.25」停在 `0% · 0.0 / 69.5 MB`，可同一屏的「检查更新」那行已经写着「下载中 1%」——两个数字自相矛盾，说明字节在进来、只是弹窗没画。

根因在 `app/lib/widgets/update_check_tile.dart`：进度弹窗用 `showDialog` + `StatefulBuilder` 撑起来，`onProgress` 里只调了外层 `UpdateCheckTile` 的 `setState`，弹窗自己的 `setDialogState` 一次都没被调用过。弹窗挂在根 Navigator 上，不是 tile 的子树，所以外层刷新影响不到它——进度条与「0% · 0.0 / 69.5 MB」都是打开那一瞬间的快照。

修法：State 里存 `StateSetter? _dialogSetState`，`_showProgressDialog()` 的 builder 首行把它存下来；`onProgress` 末尾调用 `_refreshProgressDialog()` 让弹窗跟着重画；`_closeProgressDialog()` 与 `finally` 里清空它，迟到的回调不会打到已销毁的 State。回归用例先做了反证——临时删掉那行调用，测试就失败在 `Found 0 widgets with text containing 50% · 0.5 /`。`flutter test` **387/387**。

> **M4.26 已知限制**：①只修「弹窗不重画」，下载速度仍受隧道与 `pace()` 节流影响（每 256 KB 一帧、帧间至少 30 ms，上限约 8.5 MB/s）；②没有「取消下载」与断点续传，中途失败会删掉 `.part` 重下；③真机未复测，装 0.4.26 后要实际点一次「立即更新」看数字是否连续增长；④插件 0.2.29 仍卡在 `HMR transactions cannot be nested`，需完整重开 DSH 才生效。

> **M4.25 账户余额进了「我的」**（2026-11-17）

用户说「账户余额放到我的里面」。手机「我的」页此前只有品牌卡、连接与设备、模型与 API Key、通知开关、外观、关于，完全看不到账户里还有多少钱。

余额不能由手机直接查：Host 的 `deepseekAccount` 服务描述写着「Account operations; only Host consumers can obtain a request credential」，凭据只在电脑的 Host 进程里。所以插件 0.2.29 代理了一次——新增 `readAccountBalance()`（调 `getBalance({ version, locale, timezoneOffsetSeconds })`，把 `AccountWallet[]` 压成 `{currency, balance}` 并丢掉空条目，`null` 表示未登录、`status:'failed'` 表示查询失败、没有服务则 `supported:false`）与 `GET /api/v1/desktop/account/balance`（只认手机 app token，401 / 501 `ACCOUNT_BALANCE_UNAVAILABLE` / 200 透传）。

手机端 0.4.25+51 新增 `AccountWallet`（带 `symbol`，CNY→`¥`、USD→`# 手机端 App（Flutter · 真实连接 + 连接空态）



> **这是什么**：策划案里「手机 App」的可运行实现——五个 Tab、任务状态、高风险授权、紧急停止都能真实点；**AI 助手页已接真实链路**：连上后端后可以真实操控这台电脑上的 DeepSeek Harness（发指令、看实时输出、审批、取消）。

> **M1.1 增量**：真实模式下 AI 助手可看**历史会话并回填历史消息**（断线重连按 `seq` 增量补齐）；**任务中心换成电脑端真实任务**（筛选/统计/刷新、任务详情事件时间线）；**项目管理展示电脑端真实工作区**；工具调用与工具输出**结构化分块渲染**（命令 mono 块、状态、耗时、输出可折叠）。

> **M2-α 增量**：连接期间启动**前台服务保活**（常驻「已连接 <设备> · DeepSeek Remote」，退后台不易被回收）；锁屏/后台收到审批请求时发**高优先级通知**，点通知直达授权弹层（冷/热启动两条路径）；后端重启或 token 失效时**自动重新配对并重连一次**。

> **M2.1 增量**：断线重连或 App 回到前台时，用 `GET /api/v1/conversations/{id}/events?afterSeq=<lastSeq>` **增量补拉断线期间的事件**（按 `seq` 去重/排序，与实时流同一处理入口，不再漏事件）；执行中继续输入会进入**本地排队**（深度 1），气泡提示「已排队，当前任务结束后自动发送」，可随时移除，任务结束/失败/取消后自动发出。

> **M2.2 增量（手感对齐 A 档）**：任务一结束，该轮工具调用与思考自动收成一行摘要（如「已完成 4 步 · 用时 12s」，失败/取消不同配色），点击展开原卡片；排队中的指令可点「立即发送」——先打断当前任务，收到终态或 3 秒超时后自动发出（小字提示「将打断当前任务」）；新增**6 套深色主题**（深海蓝/墨黑/暖沙/森林/樱粉/紫夜），「我的 → 外观」点选立即生效、重启保留（原生 SharedPreferences）；AI 助手页右上「分享」把最近一轮对话渲染成 1080 宽竖版分享卡 PNG 走系统分享（脱敏，不含工具命令/路径/token）；文本气泡长按可复制/重新发送，工具卡片长按可复制输出。

> **M2.3 增量（视觉重构）**：整体从深色改为**冷白底 + 白色卡片 + 蓝色主色**的浅色界面（默认浅色、跟随系统切换深色），排版采用大圆角/大留白/22px 标题、助手正文左侧 3px 浅竖线、底部导航选中圆点；「我的 → 外观」改为**跟随系统 / 浅色 / 深色**三选，立即生效并重启保留；六个页面全部按新 token 重做，版本号 `0.1.4-m2.3`。

> **M2.4 增量（无演示数据 + 界面减法）**：删除全部本地演示数据源（`demo_store.dart`、假设备/假会话/假任务/假工作区/假审计/假配对码），未连接时六个页面统一为**连接空态**（图标 + 标题 + 一行说明 + 「连接电脑」按钮）；已连接只保留真实功能与一行状态条，任务页去掉统计三卡副标题、电脑页合并为设备卡 + 权限摘要、项目页只读真实授权目录、我的页去掉审计与演示账号；连接页步骤压成一行小字，版本号 `0.1.5-m2.4`。

> **M2.5 增量（应用内在线更新）**：「我的 → 关于 → 检查更新」→ 请求后端 `GET /api/v1/app/version` 比对 versionCode → 有新版本弹窗（当前/新版本、大小、更新说明）→ 下载 APK（不可关闭进度框）→ 调起系统安装器（无「安装未知应用」权限时先引导去设置）；不做静默安装。**首次需手动装 0.1.6**（0.1.5 没有更新模块），之后即可应用内更新；版本号 `0.1.6-m2.5`（versionCode 7）。

> **M2.6 增量（项目同步 / 只读浏览）**：「项目」页展示电脑端真实工作区，可逐级浏览目录（目录在前、文件显示大小/修改时间、下拉刷新、面包屑回上级），点开文本文件只读预览（等宽字体、行号开关、横向滚动、sha256 前 8 位、超大截断提示、复制全部）；项目卡或浏览页可「在此项目/目录发指令」→ 自动切到 AI 助手，输入框上方出现「项目：<目录名>」胶囊，新会话自动绑定该工作区。依赖 Agent 的 `workspace.list` / `file.read` WSS 请求-响应能力（按 requestId 配对，不进消息流）；版本号 `0.1.7-m2.6`（versionCode 8）。

> **M3.6 增量（插件双 Tab + 插件市场 + 会话新鲜度）**：「插件」页改为**已安装 / 插件市场**双 Tab——已安装按插件包（bundle）分组，bundle 总开关 + 展开后的子插件开关；旧版电脑端（`/plugins/bundles` 404）自动回退到插件列表，把 Host 内部模块折叠进「系统内置」，并提示升级。插件市场支持搜索、按索引过滤、一键安装（含构建脚本二次确认）与卸载。桌面会话列表按「最后活动时间」倒序并显示消息条数，App 回到前台时重新拉取、首次进入强制滚到最新；版本号 `0.3.6-m3.6`（versionCode 25）。

> **M4.0 增量（工作区整改 + 手机新建工作区）**：任务页底部工作区胶囊**常驻**（不再只在 ≥2 个工作区时出现），末尾固定「＋ 新建工作区」——输入名字即可在电脑第一个授权根目录下建子目录（非法字符自动换成 `-`，同名直接复用），建好自动进入该工作区页。工作区页重做：会话按最后活动排序并显示状态徽标/消息数/时间，AppBar 提供「浏览工作区文件 / 新建会话（可命名）/ 刷新」，空态与底部输入条引导先建会话；同时修掉 Hub 骨架 `device.status` 把工作区目录清空导致「我的 → 工作区」闪空的问题。版本号 `0.4.1-m4.0`（versionCode 27）。

> **M4.1 增量（插件页对齐电脑端 + 市场索引兜底）**：「插件 → 已安装」顶部新增「浏览本地插件」入口，进入**已安装插件画廊**——按「内置插件配置 / 实验性插件 / 其他插件」分组列出电脑上全部本地插件（名称、两行说明、实验性标签、逐项开关，开关与电脑端「设置 → 插件」同源，重启 DSH 后完全生效），支持按名称/说明过滤；旧插件（无 `GET /desktop/plugins/gallery`）返回 404 时提示升级。插件市场卡片加厚：作者 + 下载量 + 星标（`319万` / `6.9k` 紧凑格式），列表顶部一行统计（条目数 + 索引来源 + 关键字）。同时修掉**市场一直为空**的根因：电脑端 DSH 未配置任何插件索引时，插件改用 DSH 公开索引 `https://api.dshmarket.com/v1/index.json` 兜底并带 `refresh` 让 Host 现场拉取（`defaultIndex=true`），结果 0 条时再用 `order:'stars'` 重试一次。版本号 `0.4.2-m4.1`（versionCode 28），电脑端插件需 **0.2.10+**。

> **怎么用**：先按 `docs/research/M1_E2E_REPORT.md` §4 在电脑上起「后端 + 公网隧道 + Agent」，再在 App 里填隧道地址 + 配对码 `824613`，点连接。

> **未连接时**：六个 Tab 展示统一的连接空态（不显示任何假数据），点「连接电脑」进入配对页。



---



## 1. 截图



### 1.1 真实链路（M1，手机 → 公网 → 后端 → Agent → Harness）



| 场景 | 截图 |

| --- | --- |

| 连上真实电脑（设备/版本/真实链路标识） | `docs/mobile/screenshots/09_live_connected.png` |

| 手机发指令 → Harness 真实回复（报出真实工作区路径） | `docs/mobile/screenshots/10_live_output.png` |

| 审批弹层（由 m1-approval-hold 触发的真实请求） | `docs/mobile/screenshots/11_live_approval.png` |

| 手机在对话里请求工作区外写入 → 真实 `pwsh` 命令 + 6 级权限 + 倒计时 | `docs/mobile/screenshots/12_live_approval.png` |

| 点「允许一次」后：工具执行成功、电脑上文件真实生成、任务完成 | `docs/mobile/screenshots/13_live_result.png` |



> M1.1 的「历史会话弹层 / 真实任务列表 / 结构化工具输出」**截图未补拍**：本机 headless 模拟器在 App 完成连接后 1–3 分钟内会被运行环境回收（多种 GPU 模式均失败），判定为环境问题；M1.1 能力由 `flutter test`（当前 366/366 全绿）与真实 REST 联调覆盖，详见 `docs/research/M1_1_REPORT.md` §7 第 9 条。真机或稳定宿主上可直接补拍。M2.3 视觉重构后的浅色界面截图同样待补拍（见 §8 第 14 条）；M2.4 后未连接界面为统一空态，截图同样待补拍（见 §8 第 15 条）。



### 1.2 历史截图（M2.4 前的演示模式界面，现已被空态取代）

| 页面 | 截图 |

| --- | --- |

| AI 助手（默认首页） | `docs/mobile/screenshots/01_assistant.png` |

| 任务中心 | `docs/mobile/screenshots/02_tasks.png` |

| 任务详情（事件时间线） | `docs/mobile/screenshots/03_task_detail.png` |

| 电脑控制（配对 / 权限） | `docs/mobile/screenshots/04_control.png` |

| 项目管理（工作区授权） | `docs/mobile/screenshots/05_projects.png` |

| 个人中心（审计日志） | `docs/mobile/screenshots/06_profile.png` |

| 高风险授权确认（10 分钟倒计时） | `docs/mobile/screenshots/07_approval.png` |

| 紧急停止与开关（控制页下半部） | `docs/mobile/screenshots/08_control_emergency.png` |



## 2. 五个页面做了什么



| Tab | 核心内容 | 与策划案的对应 |

| --- | --- | --- |

| **AI 助手**（默认） | 未连接：连接空态；已连接：发指令、实时输出、思考折叠、工具调用/输出分块、审批弹层、取消、历史会话回填、完成自动折叠、分享卡、长按菜单；一行状态条（设备名 + 已连接 + 会话切换/分享） | 2.3 默认首页＝对话；6.x 会话与消息 |

| **任务中心** | 未连接：连接空态；已连接：筛选胶囊、任务卡（状态徽标/进度/结果/错误码）、详情事件时间线、取消；真实模式下拉刷新（`GET /api/v1/tasks`） | 2.x 任务 7 状态；8.x task.* 事件 |

| **电脑控制** | 未连接：连接空态；已连接：设备卡（设备名/Agent/Harness/在线/最近在线）、权限摘要（一行「当前权限 3 级」+ 查看权限说明弹层）、紧急停止滑块 | 3.4 电脑端 UI；7 章安全；远程桌面分级 |

| **项目管理** | 未连接：连接空态；已连接：真实工作区列表，点卡片进入**逐级目录浏览**，文件点开只读预览（等宽/行号/复制），可在项目或目录内发指令并绑定新会话工作区 | 6.x workspaces / workspace_permissions |

| **个人中心** | 账号行、连接状态（已连接设备 / 未连接 + 连接按钮）、**外观（跟随系统/浅色/深色三选，即时生效+重启保留）**、关于；不再有审计日志/演示账号 | 7.5 审计；12 章交付 |



关键交互：**高风险授权**底部弹层展示工具名 + 原始命令 + 工作区，10 分钟倒计时后自动按「拒绝」处理（真实模式下这些字段来自 ACP 的 `request_permission` 与前置 `tool_call.rawInput`）；**紧急停止**必须拖动滑块才触发，触发后 App 内不提供恢复入口（与概念稿 §2.7 一致）。



## 3. 哪些是真的、哪些是演示



| 部分 | 状态 |

| --- | --- |

| 全部界面、导航、状态机、授权弹层、倒计时、紧急停止滑块 | ✅ 真实可交互 |

| 连接后端 / 测试连接（health）/ 配对 | ✅ **M1 真实**（`dart:io` HttpClient + WebSocket） |

| AI 助手页：发指令、实时输出、思考、工具调用、审批、取消 | ✅ **M1 真实**（经云端中继到电脑 Agent → Harness） |

| 历史会话 / 历史消息回填 / 重连增量补齐 | ✅ **M1.1 真实**（`GET /api/v1/conversations`、`.../messages?afterSeq=`，Bearer token 复用配对 token） |

| 任务中心列表、筛选、任务详情事件时间线 | ✅ **M1.1 真实**（`GET /api/v1/tasks`、`/tasks/{id}`）；未连接时为空态 |

| 工具调用 / 工具输出结构化渲染（命令、状态、耗时、退出码、输出折叠） | ✅ **M1.1**（`tool_call` / `tool_result` 分块；不再显示原始 JSON 片段） |

| 项目管理：真实工作区列表 | ✅ **M1.1 真实**（来自 `device.status.workspaceRoots`，只读） |

| 未连接时的六个页面 | ✅ **M2.4** 统一连接空态（无任何假数据/演示文案），点按钮进连接页 |

| 消息/任务/工作区/审计数据（未连接时） | ✅ **M2.4 已删除**（`demo_store.dart` 移除，不再有本地演示数据） |

| 审批通知 / 锁屏提醒（点击直达授权弹层） | ✅ **M2** 原生通知桥（`approval_alerts` 高优先级，tag=approvalId；冷/热启动都能直达） |

| 后台保活（前台服务常驻「已连接 <设备>」） | ✅ **M2** `ConnectionService`（`dataSync` 前台服务；退后台 5 分钟连接不丢） |

| 后端重启后自动重配对（REST 401 / WSS 4401） | ✅ **M2** 用本地地址+配对码自动 `/api/v1/auth/pair` 一次，成功静默继续 |

| 断线 / 回前台事件增量补拉（不漏事件） | ✅ **M2.1** `GET .../events?afterSeq=` 循环补拉到不足一页；按 `seq` 去重排序，与实时流同一处理入口 |

| 执行中继续输入 → 排队到当前任务结束后自动发送 | ✅ **M2.1** 本地队列（深度 1），「已排队」气泡可移除；task.state 终态后自动发出 |

| 任务结束自动折叠该轮工具/思考为一行摘要（点击展开） | ✅ **M2.2** 摘要含步数与用时；失败红/取消橙黄；助手最终回复不折叠 |

| 排队「立即发送」（先打断当前任务，终态或 3s 超时后发出） | ✅ **M2.2** 按钮下方提示「将打断当前任务」；打断中禁用防重复 |

| 6 套深色主题 + 「我的」外观入口 + 重启保留 | ✅ **M2.2** Kotlin `deepseek_remote/settings` + SharedPreferences |

| 最近一轮对话分享卡（1080 宽 PNG → 系统分享） | ✅ **M2.2** Canvas 渲染脱敏卡；Kotlin `deepseek_remote/share` + 内置 FileProvider |

| 文本气泡长按复制/重新发送、工具卡片长按复制输出 | ✅ **M2.2** 底部操作菜单 |

| 浅色优先 + 跟随系统深色 + 外观三选持久化 | ✅ **M2.3** 冷白底/白卡片/蓝主色；「我的 → 外观」三选立即生效、重启保留（SharedPreferences） |

| 六个页面视觉重做（颜色/圆角/间距/阴影 token 体系） | ✅ **M2.3** 大圆角/大留白/22 标题/导航选中圆点/助手左侧竖线；深色版同一 token 体系 |

| 项目目录浏览（`workspace.list` 请求-响应） | ✅ **M2.6 真实**（WSS 按 requestId 配对，不占消息 seq；目录在前、忽略 `.git`/`node_modules` 等，最多 500 条） |

| 文本文件只读预览（`file.read` 请求-响应） | ✅ **M2.6 真实**（等宽 + 行号开关 + 横向滚动 + 复制；`truncated`/`binary`/`TOO_LARGE` 友好提示，默认请求 256KiB） |

| 项目内发指令（会话绑定 workspacePath） | ✅ **M2.6 真实**（`pendingWorkspacePath` → `conversation.create` 带 `workspacePath`，创建成功自动清除；输入框上方胶囊可移除） |

| 远程推送通知、真实二维码配对 | ⬜ M1.2/M2 后续 |



## 4. 跑起来 / 连接真实电脑



### 4.1 构建与安装



``powershell

$env:JAVA_HOME='C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1'

$env:ANDROID_HOME='C:\Users\user\dsh-tools\android-sdk'

$env:ANDROID_SDK_ROOT=$env:ANDROID_HOME

$env:PATH='C:\Users\user\dsh-tools\flutter\flutter\bin;' + $env:PATH



cd app

flutter pub get

flutter test                 # 497 个测试（含 M3.6 新增 20、M4.0 新增 12、M4.1 新增 8、M4.2 新增 4、M4.3 新增 10、M4.4 新增 9、M4.5 新增 2、M4.6 新增 3、M4.7 新增 10、M4.8 新增 6、M4.9 新增 8、M4.10 新增 6、M4.11 新增 6、M4.12 新增 17、M4.13 新增 9、M4.14 新增 3、M4.16 新增 5、M4.17 新增 5、M4.18 新增 3、M4.19 新增 2、M4.21 新增 6、M4.22 新增 2、M4.25 新增 4、M4.26 新增 1、M4.27 新增 10、M4.28 新增 2、M4.29 新增 5）

flutter build apk --debug    # 产物 build\app\outputs\flutter-apk\app-debug.apk

adb install -r build\app\outputs\flutter-apk\app-debug.apk

adb shell am start -n com.deepseek.remote.deepseek_remote_app/.MainActivity

``



> 构建注意：Flutter 模板的 Gradle Wrapper 默认从 `services.gradle.org` 下载，本机直连超时；已把

> `android/gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl` 指向腾讯云镜像

> `https://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip`。换机器或换网络后可改回官方源。

> 另：工程路径含中文，`flutter analyze` 会崩（`FormatException`），请用 `flutter test` / `flutter build` 校验。



### 4.2 连接真实电脑（三件套 + 手机）



电脑上起后端、隧道、Agent（详细命令见 [`../research/M1_E2E_REPORT.md`](../research/M1_E2E_REPORT.md) §4）：



``powershell

# 1) 后端

$env:JAVA_HOME='C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1'

cd backend; C:\Users\user\dsh-tools\gradle\gradle-8.14.3\bin\gradle.bat bootRun --console=plain



# 2) 公网隧道（记下 https://<公网隧道>.trycloudflare.com）

tools\bin\cloudflared.exe tunnel --url http://127.0.0.1:8080 --no-autoupdate



# 3) Agent

$env:REMOTE_SERVER_URL='http://127.0.0.1:8080'

$env:M1_PAIRING_CODE='824613'

$env:M1_WORKSPACE_ROOT='<项目根>\agent\.m1ws'

cd agent; node scripts/serve.ts

``



手机上：AI 助手页右上角「⇄」→ 服务器地址填 `https://<公网隧道>.trycloudflare.com`、配对码 `824613` → 「测试连接」（应显示后端版本 + 电脑 Agent 在线）→ 「连接」→ 顶部出现「已连接真实电脑」→ 直接发指令。



> **M1.1 起还需要 PostgreSQL**（否则后端会因 Flyway 失败而启动不了）：推荐直接用一键脚本

> `powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-up.ps1`，它会按顺序拉起

> PostgreSQL（5433）→ 后端 → 隧道 → Agent，并把公网地址/配对码打印出来；关闭用 `tools\m1-down.ps1`。



> 隧道地址每次重启都会变；要固定地址需自备域名（见概念稿 D-1/D-2）。



> **M1.1 真实数据入口**：连上后 AI 助手页右上角「时钟」图标打开历史会话（点条目回填消息，断线重连自动按 `seq` 增量补齐）；任务中心自动切换为电脑端真实任务，右上「刷新」或下拉刷新，点任务卡查看事件时间线；项目管理展示电脑端 `M1_WORKSPACE_ROOT` 下的只读工作区。接口不符时以 `docs/design/M1_1_DELTA.md` 为准。



> **M2 起后台与重连**：连接成功后 App 启动前台服务并常驻「已连接 <设备> · DeepSeek Remote」通知（Android 13+ 首次连接会请求通知权限，拒绝不影响连接）；锁屏/切后台收到审批请求时发高优先级通知，点通知直接回到对应授权弹层（已处理/超时则提示「该审批已失效」）；后端重启或 token 失效（HTTP 401 / WebSocket 4401）时，App 会用本地地址+配对码自动重新配对并重连一次，失败才回连接页提示。验收细节以 `docs/design/M2_DELTA.md` 为准。



> **M2.1 起补拉与排队**：重连成功、App 回到前台、进入历史会话后，App 会用 `GET /api/v1/conversations/{id}/events?afterSeq=<lastSeq>` 循环补拉断线期间的事件（每页最多 500、拉到不足一页为止），按 `seq` 去重排序后与实时流走同一处理入口；补拉失败只显示「断线期间的事件同步失败」并可重试，不阻塞实时消息。任务执行中继续发送的指令不会报错，而是进入深度 1 的本地队列并显示「已排队」气泡（可移除），任务结束/失败/取消后自动发出。验收细节以 `docs/design/M2_1_DELTA.md` 为准。



> **M2.2 起手感升级**：任务终态后该轮「工具调用 + 思考」自动收成一行摘要（如 `已完成 4 步 · 用时 12s`，失败/取消换色），点击展开仍按原顺序显示；排队气泡新增「立即发送」——先发 `task.cancel` 打断当前任务，收到终态或 3 秒超时后自动把排队指令作为新 prompt 发出（不是真正的 turn 内插话）；「我的 → 外观」可切 6 套深色主题（原生 SharedPreferences 持久化）；AI 助手页右上「分享」生成 1080 宽竖版 PNG 分享卡（只含用户/助手正文 + 摘要 + 设备名/时间，路径与 token 已脱敏），经系统分享面板发送；气泡长按可复制/重新发送，工具卡片长按可复制输出。验收细节以 `docs/design/M2_2_DELTA.md` 为准。



> **M2.3 起视觉重构**：默认浅色（冷白底 + 白色卡片 + 蓝色主色），系统切深色时自动跟随；「我的 → 外观」提供跟随系统 / 浅色 / 深色三选，点选立即生效并重启保留。全部页面按新 token（颜色/圆角/间距/阴影）重做，版本号 `0.1.4-m2.3`。验收细节以 `docs/design/M2_3_UI_DELTA.md` 为准。



> **M2.4 起无演示数据**：未连接时六个页面统一为连接空态（图标 + 标题 + 一行说明 + 「连接电脑」按钮），不再展示任何假设备/假会话/假任务/假工作区/假审计/假配对码；连接后各页只保留真实功能，电脑页权限改一行摘要 + 弹层、项目页只读真实授权目录、我的页去掉审计与演示账号、连接页步骤压成一行小字。版本号 `0.1.5-m2.4`。验收细节以 `docs/design/M2_4_SIMPLIFY_DELTA.md` 为准。



## 5. 代码结构（M2.4 后）



``text

app/

├── pubspec.yaml                      # 零第三方运行时依赖（dart:io 实现 HTTP/WebSocket）

├── lib/

│   ├── main.dart / app.dart          # ThemeScope + LiveScope + MaterialApp（主题/分享网关注入；无 DemoStore）

│   ├── models.dart                   # 7 状态枚举 / ChatItem（seq/turnId/queued）/ TurnStats / TaskItem / TaskEvent

│   ├── theme/

│   │   ├── app_theme.dart            # M2.3 token 体系：浅/深 AppPalette + ThemeData + ThemeExtension（context.appPalette）+ 圆角/间距 token

│   │   └── theme_controller.dart     # ThemeController（跟随系统/浅色/深色三选 + 持久化）+ ThemeScope

│   ├── services/

│   │   ├── relay_protocol.dart       # 信封与事件类型（对齐 M1_PROTOCOL.md）

│   │   ├── workspace_models.dart     # M2.6 工作区/文件数据类 + 错误码中文映射（WorkspaceRequestException）

│   │   ├── pairing_api.dart          # health 探测 + POST /api/v1/auth/pair

│   │   ├── relay_client.dart         # WebSocket 连接/重连/事件流/发送（4401 → authFailures 流）

│   │   ├── history_api.dart          # M1.1 REST：历史会话/消息/任务；M2.1 事件增量（/events?afterSeq=）

│   │   ├── notification_gateway.dart # M2 通知/前台服务网关（MethodChannel + Fake 可注入）

│   │   ├── notification_prefs.dart   # M4.4 通知开关（任务做完提醒 / 等待授权提醒，SharedPreferences 持久化）
│   │   ├── settings_gateway.dart     # M2.2 设置持久化网关（MethodChannel + Fake）

│   │   ├── share_gateway.dart       # M2.2 系统分享网关（MethodChannel + Fake）

│   │   └── share_card.dart           # M2.2 分享卡数据构造/脱敏/Canvas 渲染 PNG

│   ├── data/

│   │   └── live_store.dart           # 真实会话状态（消息/任务/审批/历史 REST/通知/前台服务/自动重配对/事件补拉/排队/轮次统计/打断立即发送/M2.6 工作区请求-响应）

│   ├── screens/

│   │   ├── root_shell.dart           # 五 Tab 外壳（IndexedStack 保状态）

│   │   ├── connect_screen.dart       # 真实连接设置

│   │   ├── assistant_screen.dart     # 对话页（M4.2 去模式切换：空提示/自动折叠/分享/长按/常驻附件行/待绑定项目胶囊）

│   │   ├── tasks_screen.dart         # 含 LiveTaskDetailScreen 事件时间线

│   │   ├── workspace_screen.dart     # M4.0 工作区二级页（会话排序/新建会话/浏览文件/底部直发）

│   │   ├── plugins_screen.dart       # M3.6 插件双 Tab / 市场；M4.1 已安装 Tab 顶部「浏览本地插件」入口 + 市场卡片加厚

│   │   ├── plugin_gallery_screen.dart # M4.1 已安装插件画廊（内置/实验性/其他分组 + 逐项开关 + 过滤）

│   │   ├── projects_screen.dart      # M2.6 真实工作区根列表（浏览/在此项目发指令）

│   │   ├── project_browser_screen.dart # M2.6 逐级目录浏览（面包屑/下拉刷新/错误重试）

│   │   ├── file_viewer_screen.dart   # M2.6 只读文本预览（等宽/行号/复制/截断提示）

│   │   ├── control_screen.dart / profile_screen.dart（个人中心含外观主题入口与检查更新）

│   └── widgets/

│       ├── common.dart               # Panel / SlideToStop / EmptyHint / LiveScope（M2.3 token 化）

│       ├── empty_state.dart          # M2.4 统一连接空态（图标 + 标题 + 说明 + 连接按钮）

│       ├── chat_items.dart           # 气泡（排队气泡/立即发送/长按菜单）、思考折叠、工具调用/输出分块卡

│       ├── turn_fold.dart            # M2.2 轮次折叠（groupTurnMessages + TurnSummaryCard）

│       ├── timeline.dart             # M1.1 任务事件时间线（类型/工具/时间）

│       ├── workspace_create_dialog.dart # M4.0 新建工作区对话框（名字校验 + 预览路径 + 旧插件提示）

│       └── approval_sheet.dart       # 高风险授权弹层（倒计时 10:00 → 自动拒绝）

├── test/                             # 497 个测试（含 M3.6 新增 20、M4.0 新增 12、M4.1 新增 8、M4.4 新增 9、M4.5 新增 2、M4.6 新增 3、M4.9 新增 8、M4.10 新增 6、M4.11 新增 6、M4.12 新增 17、M4.13 新增 9、M4.14 新增 3、M4.18 新增 3、M4.19 新增 2、M4.21 新增 6、M4.22 新增 2、M4.25 新增 4、M4.26 新增 1、M4.27 新增 10、M4.28 新增 2、M4.29 新增 5，均不联网）

└── android/                          # 壳工程；Kotlin 原生桥：NotificationHelper / NotificationBridge / ConnectionService /

                                      # SettingsBridge（SharedPreferences）/ ShareBridge + ShareFileProvider（分享，share/ 与 updates/）/

                                      # UpdateBridge（系统安装器）

``



## 6. 视觉规范（M2.3）



- **配色**：冷白底 `#F6F7F9` + 白色卡片 `#FFFFFF` + 蓝色主色 `#2563EB`；深色模式同构（底 `#0B1220` / 卡片 `#121A2A` / 主色 `#5B8DEF`）。全部颜色来自 `AppPalette` token，经 `ThemeExtension` 暴露为 `context.appPalette.*`，主界面不再硬编码深色值。

- **形状与留白**：卡片/弹层 20 圆角（底部弹层顶部 24）、输入框/按钮 16、代码块 12、状态胶囊 999；页面左右 20、卡片内边距 16、卡片间距 12；标题 22/w700、卡片标题 14/w600、正文 14.2/1.6、小字 12.5、注释 11。

- **组件**：AppBar 透明底 22 标题；底部导航白底 94% + 顶部 1px 线 + 选中圆点；用户气泡蓝底白字 22/22/8/22，助手正文无气泡、左侧 3px 浅竖线；工具卡片 + 代码块 + 可折叠输出；折叠行/统计卡/筛选 chip/审批 Sheet 均按契约 §3 落地。

- **明暗切换**：浅色默认、跟随系统；「我的 → 外观」三选（跟随系统 / 浅色 / 深色）持久化到 `deepseek_remote/settings`（SharedPreferences），重启保留。

- **截图**：M2.3 浅色界面截图待补拍（本机无模拟器/真机）；旧深色截图见 §1.2。



## 6.1 M2.4：无演示数据 + 空态



- **删除**：`lib/data/demo_store.dart`（整文件）、`models.dart` 的 `DemoDevice/WorkspaceEntry/AuditEntry`、`common.dart` 的 `DemoBadge/StoreScope/ModeBadge`；`app.dart` 不再创建 DemoStore/StoreScope。

- **未连接**：六个 Tab 统一使用 `EmptyState`（图标 32 + 标题 15/w600 + 说明 12.5 + 主按钮「连接电脑」→ `ConnectScreen`）；AI 助手页「还没有连接电脑」、任务「连接后在这里看任务」、电脑「连接后在这里管理这台电脑」、项目「连接电脑后在这里浏览项目」（M2.6 起）；我的页保留账号/连接状态/外观/关于。

- **已连接**：AI 助手顶部只留一行状态条（圆点 + 设备名 + 已连接 + 会话切换 + 分享），对话/历史/审批/取消/折叠/主题/分享/紧急停止全部保留；任务页去掉统计三卡与副标题；电脑页合并为设备卡 + 权限摘要弹层 + 紧急停止；项目页只读真实授权目录；我的页去掉审计日志与演示账号；连接页步骤压成一行小字。

- **验收**：`grep -ri "演示" app/lib` 为 0；`flutter test` 164/164；APK `versionName=0.1.5-m2.4`、`versionCode=6`。



## 6.2 M2.5：应用内在线更新



- **入口**：「我的 → 关于」里新增「检查更新」行；未连接时点击会提示先连接（更新检查要打到电脑上的后端）。

- **流程**：`GET {serverUrl}/api/v1/app/version` → 服务端 `versionCode` 大于当前 `kAppVersionCode` 才提示 → 弹窗显示新版本号/大小 MB/更新说明 → 「立即更新」→ 流式下载到 `cacheDir/updates/app-update.apk`（`.part` 完成后 rename，按 size 校验，进度框不可关闭）→ 无「安装未知应用」权限先跳系统设置 → `content://` + `ACTION_VIEW` 调起系统安装器。

- **不做静默安装**：非系统应用无法绕过系统安装确认，最后一步必须用户点「安装」。

- **首次例外**：当前装机为 0.1.5（无更新模块），需手动安装一次 0.1.6；之后每次发版：替换电脑上 `dist/DeepSeek-Remote-latest.apk` + 改 `app.update.version-code/version-name` → 重启后端 → 手机点「检查更新」。

- **验收**：`flutter test` 178/178；`aapt` → `versionName=0.1.6-m2.5`、`versionCode=7`；接口本地与公网隧道均 200（详见 `docs/research/M2_5_REPORT.md`）。



## 6.3 M2.6：项目同步（只读浏览 + 项目内发指令）



- **协议**：手机端通过 WSS 发 `workspace.list` / `file.read`（payload 带客户端生成的 `requestId`），Agent 用 `workspace.list.result` / `file.read.result` 按 `requestId` 回包；这些回包**不占会话 seq、不进消息流与任务时间线**，只交给 `LiveStore` 的 pending 表（未知 `requestId` 直接丢弃）。失败时同一 result type 返回 `{ok:false, code, message}`，手机端映射为中文可展示文案（`PATH_NOT_ALLOWED`/`DIR_NOT_FOUND`/`FILE_NOT_FOUND`/`BINARY_FILE`/`TOO_LARGE`/`TIMEOUT`/`OFFLINE` 等）。

- **入口**：项目页 → 工作区卡（名称/路径/「浏览」「在此项目发指令」）→ 目录浏览页（面包屑可回上级、目录在前、文件显示大小/修改时间、下拉刷新、错误重试、底部「在此目录发指令」）→ 文件预览页（等宽、行号开关、横向滚动、顶部大小/修改时间/sha256 前 8 位、`truncated` 提示、复制全部；二进制/超大用 `EmptyState`）。

- **项目内发指令**：点「在此项目/目录发指令」→ `LiveStore.setPendingWorkspace(root)` → 自动切到 AI 助手并显示「项目：<目录名>」胶囊（可移除）→ 下一条指令触发 `conversation.create` 时带 `workspacePath`，创建成功后自动清除。

- **代码**：新增 `lib/services/workspace_models.dart`、`lib/screens/project_browser_screen.dart`、`lib/screens/file_viewer_screen.dart`；改写 `lib/screens/projects_screen.dart`；`live_store.dart` 加工作区请求-响应（20s 超时、断线清理 pending）；`relay_protocol.dart` 加 4 个 type 常量；`assistant_screen.dart` 加待绑定项目胶囊；`root_shell.dart` 传入 Tab 切换回调。

- **验收**：`flutter test` 190/190 全绿（新增 `test/project_sync_test.dart` 12 项，纯 fake socket 不联网）；`aapt dump badging` → `versionName=0.1.7-m2.6`、`versionCode=8`；debug APK 150,820,399 bytes。

- **已知限制**：手机端只读（不支持写入/重命名/删除）；二进制与超大文件不可预览（默认请求 256KiB，`truncated` 时仅显示前段）；`.git`/`node_modules` 等忽略目录不展示（`ignoredCount` 计数）；需电脑端 Agent 上报 `capabilities.workspaceList/fileRead`，旧版 Agent 会提示升级。



## 6.4 M3.6：插件双 Tab / 插件市场 + 桌面会话「到最新」



- **协议**（电脑端插件新增，旧版插件 404，App 必须优雅降级）：

  - `GET /api/v1/desktop/plugins/bundles` → `{bundles:[{name,version,description,enabled,installed,removable,plugins:[{id,name,rowId,enabled}]}]}`；子插件 `enabled` 可为 `null`（未知时不显示开关）。

  - `POST /api/v1/desktop/plugins/bundles/enabled` body `{name,enabled}`。

  - `GET /api/v1/desktop/plugins/market?url=&query=` → `{indexes:[{url,title,description}],source,query,entries:[{name,title,version,description,author,tags,installed,installedVersion}],installedBundles,error}`。

  - `POST /api/v1/desktop/plugins/market/install` body `{spec,approvedBuilds?}` → `{ok:true,...}`，可能含 `pendingBuilds`（数组）与 `nextStep`；`POST /api/v1/desktop/plugins/market/remove` body `{name}`。

  - 桌面任务行新增 `lastTime`（**毫秒时间戳 number**，显示时转「HH:mm」/跨天「MM-dd HH:mm」）、`messageCount`、`lastSeq`、`running`；`TaskRecord` 用 `int? lastTime` 解析（兼容数字字符串与 ISO 字符串）。

- **插件页**：`PluginsScreen` 重写为 `TabBar` 双 Tab（「已安装」「插件市场」）。

  - 已安装：优先 bundles，按包分组（名称去掉 `@deepseek-ai/` 前缀）、版本/描述、bundle 级 `Switch`（`setBundleEnabled`）、展开后子插件 + 各自开关（`setPluginEnabled`）；接口 404/失败自动回退 `listPlugins()`，只显示名字含 `dsh-plugin`/`plugin-` 的条目，其余折叠进「系统内置（N）」，顶部浅色提示「当前电脑插件版本较旧，升级后可按插件包分组。」；加载失败可重试，空列表用 `EmptyState`。

  - 插件市场：搜索框（回车/按钮）+ 索引下拉（默认全部）；条目显示标题/版本/作者/两行描述/tags，未安装显示「安装」、已安装显示「已安装 vX」+「卸载」。安装两次确认（第二次展示 `pendingBuilds` 名称与 `nextStep`，同意后带 `approvedBuilds` 重调），成功 SnackBar 并刷新已安装 Tab；市场 404 显示「电脑端插件需要升级到支持插件市场的版本」+ 重试。

  - 所有异步操作有 loading 态与按钮防重复（`_busyKeys`/`_installing`/`_removing`）。

- **桌面会话新鲜度**：`sortDesktopTasks`/`sortDesktopTaskItems`（`lib/services/desktop_sort.dart`，纯函数）：有 `lastTime` 的在前并按时间戳倒序，没有的回退 `updatedAt` 倒序，相等保持原顺序。任务卡显示「N 条消息」与最后活动时间；`DesktopSessionScreen` 加 `WidgetsBindingObserver`，`AppLifecycleState.resumed` 时重新 `_load(initial: true)`；首次加载在 `postFrameCallback` 里强制 `jumpTo(maxScrollExtent)`（即使事件数为 0 或用户不在底部）。

- **代码**：`services/history_api.dart`（`PluginBundle`/`MarketEntry`/`MarketIndex`/`MarketSearchResult`、5 个新方法、`TaskRecord.lastTime/messageCount/lastSeq`、`PluginInfo` 兼容 `entryId/moduleName` 旧行）；`data/live_store.dart` 透传 + 桌面任务排序；`services/desktop_sort.dart`、`screens/plugins_screen.dart`（重写）、`screens/tasks_screen.dart`、`screens/desktop_session_screen.dart`、`models.dart`（`TaskItem.messageCount/lastTime` + `formatLastTime`）。

- **验收**：`flutter test` 244/244 全绿（新增 `test/plugin_market_test.dart` 10 项、`test/desktop_freshness_test.dart` 10 项，均不联网）；`aapt dump badging` → `versionName=0.3.6-m3.6`、`versionCode=25`；debug APK 177,899,089 bytes。

- **已知限制**：插件市场/插件包分组要求电脑端插件升级到对应版本，旧版只能看扁平列表（已折叠系统模块）；市场安装只透传 Host `installBundle` 结果，构建脚本必须由用户在手机上二次确认；`lastTime` 仅用于展示与排序，不参与服务端查询；工程位于中文路径，`app/android/gradle.properties` 关闭了 Kotlin 增量编译（`kotlin.incremental=false`），否则 `mobile_scanner` 偶发 `Could not close incremental caches` 构建失败。



> **M4.0 工作区**：任务页工作区胶囊常驻并带「＋ 新建工作区」；新建走电脑端 `POST /api/v1/desktop/workspaces`（body `{name}`），在**第一个授权根目录**下建子目录，非法字符替换为 `-`，同名复用；成功后 App 立即把新目录加进 `workspaceRoots` 并跳进工作区页。工作区页列出该目录下的会话（`sortDesktopTaskItems` 倒序 + 状态徽标 + `N 条消息` + 最后活动时间），可下拉刷新（5 秒轮询）、AppBar 新建会话（可命名）/浏览工作区文件/刷新，底部输入条直接把指令发给该工作区**最新会话**。

> **M4.0 骨架修复**：Hub 连上手机时先发一条骨架 `device.status`（设备名写死 `DeepSeek Harness`、不带 `workspaceRoots`），Agent 的完整版随后到达；之前骨架会把 `workspaceRoots` 清空，导致工作区页/新建工作区瞬间变空。现按设备名判断：骨架只更新能力位，不动目录；Agent 真实上报空目录时仍照常清空。



> **M4.1 插件页对齐**（2026-11-13）：电脑端 DSH 的「插件」页有「内置插件配置 / 实验性插件」分组和逐项开关，手机端原来只能看到插件包（bundle），没有同级的本地插件视角。现在「已安装」Tab 顶部加「浏览本地插件」入口 → 新页面 `plugin_gallery_screen.dart`，数据来自插件新增的 `GET /api/v1/desktop/plugins/gallery`（Host `pluginManager.listPlugins()` 的 `meta.title/description/experimental` 中文兜底 + 文件名正则分组），开关仍走 `POST /desktop/plugins/enabled`，与电脑端同源。

> **M4.1 市场为空根因**：电脑端 DSH 的 `pluginMarket.listIndexes()` 只返回「设置里配置过的索引 URL」，本机一个都没配 → 空数组，手机端市场永远只有空索引。插件端在 `indexes.length === 0` 时改用公开索引 `https://api.dshmarket.com/v1/index.json`（`defaultIndex=true`、带 `refresh: true` 让 Host 现场拉取），并用新签名 `search(url, { query: { text, limit, offset, order } })`（旧签名 `{query, limit}` 在新 Host 上会被拒）；0 条时再按 `order:'stars'` 重试。条目新增 `downloads`/`stars`，手机端用 `319万` / `6.9k` 紧凑格式展示。

> **M4.1 验收**：`flutter test` 263/263 全绿（新增 `test/plugin_gallery_test.dart` 8 项）；release APK 71,720,030 bytes、`versionName=0.4.2-m4.1`、`versionCode=28`；`tools/verify-plugin-m4.ps1` 扩到 8 项（新增 gallery 分组、市场索引兜底两项）。

> **M4.1 已知限制**：市场索引兜底依赖外网 `api.dshmarket.com`，离线时市场仍为空（已安装插件画廊不受影响）；画廊分组靠 `moduleName` 正则 + `meta.experimental` 推断，个别插件可能落进「其他插件」；开关改动要重启 DSH 才完全生效（与电脑端一致）。

> **M4.2 AI 助手页 = 对话页 + 附件真正可用**（2026-11-13）：删掉「手机 / 电脑」两档切换和整屏欢迎大图，连上电脑后打开就是消息流 + 输入框；空对话只留一行提示和三个建议胶囊。附件入口从「+」二级菜单提到输入框上方常驻的**拍照 / 相册 / 文件**三个胶囊（`_AttachmentBar` 重写：图片显示缩略图、显示「附件会存到电脑「X/手机附件」」）。关键修复：上传时带 `workspace`（工作区名），电脑端插件 0.2.11 把附件落到 `<授权根>/<工作区名>/手机附件/`（以前落在 `%USERPROFILE%\.dsh\dsh-plugin-m1\uploads`，电脑端 AI 根本找不到），发送后弹「已上传到电脑：N 个文件（工作区）」回执。`flutter test` 267/267；release APK 71,867,762 bytes、`versionName=0.4.3-m4.2`、`versionCode=29`。

> **M4.2 已知限制**：附件只能落到一级工作区目录，深目录工作区退回当前会话 cwd；单文件仍限 20 MiB；云端直连页（不连电脑）仍不带附件；底部输入条固定发最新会话；**交付时 adb 掉线，真机未复测**。

> **M4.3 直播页「已运行」与电脑端对齐**（2026-11-13）：以前直播页的「已运行」从「手机打开页面的时刻」开始数，所以同一个任务在手机上永远从 0:00 起，与电脑端对不上。现在插件把每条会话事件自带的 `time`（毫秒）随事件下发，手机端取日志里**最新一条 `turn-start` 的时间**作为起点（也就是电脑上这一轮真正开始的时刻），超过 1 小时显示 `H:MM:SS`；旧插件没有时间时依次退回任务行最后活动时间、会话 `updatedAt`。`flutter test` 277/277；release APK 71,867,762 bytes、`versionName=0.4.3-m4.3`、`versionCode=30`。
> **M4.3 已知限制**：若某轮日志里没有 `turn-start`，起点退回「最后活动时间」，显示的时长会略短于电脑端；手机与电脑系统时钟不同步时会有同等偏差；本批交付 adb 无设备，真机未复测。
>
> **M4.4 任务完成 / 等待授权通知**（2026-11-13）：以前只有「等待授权」和「断线」两类通知，电脑上的任务跑完手机端**完全没有提示**。现在新增 `task_updates` 通知渠道：任务从「执行中」变成完成 / 失败 / 取消时（REST 任务列表与插件桌面镜像两条路径都覆盖），App 在后台会弹一条「任务已完成：<会话名> · <工作区>」；等待授权时除原有通知外，再发一条带「允许 / 拒绝」按钮的常驻通知，可在通知栏里直接决定（回传 `onApprovalDecision`，与弹窗内决定同一条链路）。点「任务完成」通知会切到「工作区」页；「我的 → 通知」新增「任务做完提醒」「等待授权提醒」两个开关（SharedPreferences 持久化）。前台不打扰；重连后第一轮任务快照只做基线，不会把历史结果当成「刚做完」。`flutter test` 286/286；release APK 71,933,294 bytes、`versionName=0.4.4-m4.4`、`versionCode=31`。
> **M4.4 已知限制**：只在 App 处于后台时提醒（前台不发，避免重复打扰）；App 被系统杀掉后不会有通知，需要前台服务或厂商推送才能补上；通知按钮决定依赖 App 进程存活，进程被杀时点按钮只会打开 App；会话名取历史会话标题，取不到时退回工作区末段目录名。

> **M4.5 更新进度条分帧**（2026-11-13）：插件中继跑在本机回环网络上，71.9 MB 的 APK 实测 0.1 秒就下完，下载弹窗里的进度条只来得及刷一帧就跳去调系统安装器，看起来像「进度条不动」。现在 UpdateService.download() 用 pace() 把响应流按 256 KiB 分帧、两帧至少隔 30 ms 再回调 onProgress，进度条会一路走到 100%（约十几秒）再调起安装器；文件内容与落盘逻辑不变。flutter test 288/288；release APK 71,933,298 bytes、versionName=0.4.5-m4.5、versionCode=32。
> **M4.5 已知限制**：只改上报节奏，实际下载时长仍取决于本地中继速度；极端慢速网络下仍按 chunk 到达节奏走；本批 adb 无设备，进度条观感未真机复测。


> **M4.6 AI 助手分手机和电脑**（2026-11-14）：M4.2 曾把「手机 / 电脑」两档切换去掉，用户要求恢复，且**默认停在手机档**。`assistant_screen.dart` 重新引入 `_ModeSwitch`（IndexedStack 里两档常驻：手机档=内嵌 `CloudChatScreen` 云端直连，电脑档=电脑对话+附件+直播），手机档顶栏胶囊显示「云端直连 · <模型名>」或「云端直连 · 未设置接口」，点它直接打开接口设置弹层（`CloudChatController.editConfig()`）；云端页的加载转圈改成静态文案，避免常驻时页面永不停帧。
> **M4.6 已知限制**：手机档的云端设置走 `CloudChatStore`（地址 + Key 存本机），不会同步给电脑；两档常驻会同时持有两个会话状态（内存占用略增）；本批真机仍未复测（`adb devices` 无设备）。
> **M4.7 手机档也能发照片 / 文件**（2026-11-14）：用户反馈「AI 助手手机页面怎么没有上传文件图片拍照的」——手机档（云端直连）之前只有输入框和发送键。现在两档共用 `lib/widgets/attachment_bar.dart` 里的 `PendingAttachment` / `AttachmentPicker` / `AttachmentBar`：手机档输入条上方同样常驻**拍照 / 相册 / 文件**三个胶囊，选好的附件在发送时直接塞进请求——图片按 OpenAI 兼容的 `content: [{type:text},{type:image_url,image_url:{url:"data:image/png;base64,…"}}]` 发给支持视觉的模型，文本类文件（md/dart/json/csv…）内联成「【附件 文件名】」段，其它二进制只发文件名提示；用户气泡里显示附件缩略图。未配置接口时仍显示设置引导，并补一句「要发图片，请填支持视觉的接口」。`flutter test` 301/301。
> **M4.7 已知限制**：图片走 base64 直接进请求体，原图大时请求会慢（相册/拍照已压到 2400px 以内）；文本文件超过 20000 字会截断；云端接口必须支持视觉才能看图（DeepSeek 对话模型不支持图片输入，会报错）；附件只在当前对话内有效，不落盘、不能重发。

> **M4.8 「不用上传」**（2026-11-14）：用户说「不用上传，就和正常的 ai 一样可以处理各种问题」——界面里彻底去掉「上传」字样：电脑档发完附件不再弹「已上传到电脑：N 个文件」，指令里的列表改成「附件：」，附件条上传中显示「正在读取…」。手机档新增 `CaretakerReader` 契约：图片和文本照旧直发云端模型，PDF / Word / Excel 这类手机解析不了的文件交给电脑读成文字再随消息发（`POST /api/v1/desktop/file/read`，电脑离线或接口不存在时静默退回「只发文件名」，不影响发送）。手机档首次使用引导重写：说明「手机档不经过电脑、Key 只存在这台手机上」，并给出「去开放平台生成 Key → 回来粘贴」两步。`flutter test` 307/307。

> **M4.8 已知限制**：手机端必须用自己生成的 API Key；DeepSeek 官方对话模型不接收图片，要发图需在设置里改成支持视觉的模型（gpt-4o、Kimi vision 等）；电脑端插件尚未实现 `/desktop/file/read`，PDF / Word / Excel 目前仍会退化成「格式不支持在手机上预览」；仍未真机复测（`adb devices` 无设备）。
> **M4.9 工作区文件都能打开了**（2026-11-14）：用户说「工作区的有些文件无法预览」——原来 `FileViewerScreen` 只有文本预览，图片 / PDF / Office 一进去就是「无法预览」（插件按 NUL 字节判二进制直接抛 `BINARY_FILE`）。现在按扩展名分流：图片走新增的 `GET /api/v1/desktop/file/raw` 取原始字节，在 App 内用 `InteractiveViewer` 放大看；PDF / Word / Excel / PPT 同样下载到手机缓存，再用 `content://`（FileProvider `preview/` 路径）+ `ACTION_VIEW` 交给 WPS 或系统阅读器打开；文本文件照旧。插件新增 `POST /api/v1/desktop/file/read`（pdf-parse 读 PDF、JSZip 抽 docx/pptx/xlsx 的 XML 文字，上限 2 MB），手机档把 PDF / Word 交给它读成文字随消息发送。插件 0.2.13，`flutter test` 344/344、`node --test` 15/15。
ode --test 15/15。

> **M4.9 已知限制**：`file/raw` 上限 20 MB、`file/read` 上限 2 MB；`.doc/.xls/.ppt` 旧格式不支持（提示另存为 docx/xlsx/pptx）；图片以外的一切都依赖手机上装了能打开它的 App；需要电脑端插件 0.2.13+（旧版 `file/raw` 返回 404，界面会提示升级插件）；仍未真机复测（`adb devices` 无设备）。
> **M4.10 会话存档：手机端不再「看起来全丢了」**（2026-11-15）：用户说「为什么又看不到所有的项目了」——DSH 重启后旧会话从列表里整条消失。查下来会话文件都还在 `~/.dsh/sessions/`，只是 Host 的 JSONL 后端只认「已物化」的日志（只剩 header 的会话 `readGenerationHeader` 返回 `undefined`，整条 invisible），不是手机端也不是重启杀掉的。插件 0.2.14 起自己维护存档 `session-archive.json`：每 30 秒把运行中的会话吸进来，并扫描磁盘上存档里还没有的会话日志（自己按帧解 zstd，`zlib.zstdDecompressSync` 只解第一帧）。手机端在「工作区」页底部多出一组「以前跑过、电脑上已经看不到的会话」，点开是带「已存档」标记的只读直播（不轮询、没有输入条）。新增 `GET/POST /api/v1/desktop/archive/sessions` 与 `GET .../archive/sessions/:id`。`flutter test` 344/344、`node --test` 15/15。

> **M4.10 已知限制**：存档只是「能看」，不能继续发指令（电脑那边已经没有这条会话）；磁盘扫描只补存档里没有的会话、单会话最多 1500 条事件、正文每段截断 4000 字，最多保留 400 条会话；需要电脑端插件 **0.2.14+**（旧插件存档接口 404，手机端静默不显示这一组）；`session-archive.json` 生成要等 DSH 重开之后（首次最多 30 秒）；仍未真机复测。

> **M4.11 工作区页不再「看起来项目全丢了」**（2026-11-16）：用户说「为什么又看不到所有的项目了」——DSH 重开后电脑端会话列表会被清空/重建，而手机端「工作区」页的卡片是从会话列表派生的，列表一空，电脑端授权的 9 个目录就只剩一两个卡片。现在 `app/lib/screens/tasks_screen.dart` 新增`_idleWorkspaces` 与 `_WorkspaceCard`：授权过的每个目录都占一张卡（没有会话时标「暂无会话」，点进去照常新建会话 / 看存档 / 浏览文件）；存档分组也不再被「进行中 / 等待授权 / 失败」筛选挡掉。插件 0.2.19 让存档列表挡掉 `agent\.m1ws`、`agent\.workspaces\contract-*` 这类测试临时目录（存量记录不删、只是不展示），并补上 `node:fs` 的 `statSync` 导入。

> **M4.11 已知限制**：「暂无会话」卡片只反映当前电脑列表（电脑上真删目录后要等注册表 5 秒缓存 + 手机端 5 秒轮询才消失）；存档仍只能看不能继续发指令；需要插件 0.2.19+ 才没有测试临时目录；仍未真机复测（`adb devices` 无设备）。

> **M4.12 对话正文按 Markdown 排版**（2026-11-16）：用户发来 DeepSeek 官方 App 的对话截图问「你的对话不能做成这样的吗」。差别不在链路而在**正文渲染**——助手回复以前只认 `**加粗**` 和 `` `代码` ``，`###` 标题、`- ` 列表、三反引号代码块、`|` 表格全原样露字。新增零依赖的 `app/lib/widgets/markdown_text.dart`：`MarkdownParser.parse()` 出 `MdBlock`（`heading/paragraph/bullet/ordered/quote/code/table/rule`），`buildInlineSpans()` 处理行内加粗 / 代码 / 删除线 / 链接 / 斜体，`MarkdownText` 负责块间距与缩进；代码块有 34 高的顶栏（语言标签，空语言显示 `text`，右侧「复制」把原始代码写剪贴板），表格是 `Table` + 表头底色 + 0.8 分隔线。`chat_items.dart` 的 `_AssistantText` 改用 `MarkdownText`，底部常驻「复制 + 时间」（`_AnswerActions`）；`cloud_chat_screen.dart` 的 `_Bubble` 去掉 320 宽上限与边框卡片，助手消息无气泡直接排版、用户消息保留右侧气泡；`app_theme.dart` 补 `Noto Sans CJK SC` / `Source Han Sans SC` 回退字体。中文标题用 `FontWeight.w600` 而不是 `w700`（CJK 没真粗体，w700 是伪加粗、小字号下发糊）。App 0.4.12+39、`flutter test` **344/344**（+17）。同批插件 0.2.20：`resolveUploadDir` 先按名字命中工作区列表（`knownWorkspacePaths()` + `findWorkspaceByName()`），修「附件悄悄落回 `%USERPROFILE%\.dsh\dsh-plugin-m1\uploads`」，`node --test` 31/31。
> **M4.13 工作区按项目分组**（2026-11-16）：用户发来手机「工作区」页截图说「按照工作区项目分类，做成和电脑上一样的，可以折叠打开，并且可以新建对话，新的项目区是建立在电脑端"D:/用户/项目"这个文件里面」。原来是**平铺的会话卡**（任务卡 + 空目录卡 + 底部「以前跑过…」存档组），同目录的多个会话各占一张，项目一多就看不出归属。现在每个目录一张 `_ProjectGroupCard`：头部整行点折叠/展开（`_collapsed` 记路径），会话与存档都挂在所属项目下，空目录标「空项目」胶囊；分组逻辑抽成零依赖纯函数 `app/lib/services/project_groups.dart`（`ProjectGroup` / `projectNameOf` / `parentPathOf` / `groupWorkspacesByProject`），`_WorkspaceCard` 删除。胶囊与对话框文案改成「新建项目」，`parentDir` 固定成 `D:\Projects\项目`（授权根里没有它时退回第一个授权根并提示「电脑端没授权 …」）。插件 0.2.20 配套：`resolveParentDir()`（授权根本身/子目录，或目录真实存在）、`projectParentPath()`、`createDesktopWorkspace(name, parentDir)`，`listDesktopWorkspaces()` 每行带 `parent` 与 `isProject`。App 0.4.13+40、`flutter test` **353/353**（+9），插件 `node --test` 39/39（+8）。

）与 `AccountBalance` 模型、`live_store.fetchAccountBalance()`，以及「我的」页的「账户余额」分区与 `_BalanceCard`：连接后自动读取、监听连接变化、右上角金额 +「重新读取」，有赠送钱包时单独一行；未连接 / 未登录 / 查询失败 / 插件太旧各有副标题。插件 `node --test` **95/95**（新增 6 + 4 例）、`flutter test` **386/386**（新增 4 例）。

> **M4.25 已知限制**：①插件 0.2.29 这次热加载失败（`plugin_manager set_bundle` 三次都返回 `HMR transactions cannot be nested`），运行中的仍是 0.2.28，所以线上路由暂时 404、手机显示「这台电脑的插件版本太旧，读不到余额」，**需完整重开 DSH** 才生效（重开后隧道域名会变，手机要重新配对）；②余额是快照，不自动刷新（进页面读一次、点「重新读取」再读一次）；③只处理 CNY/USD 符号，不做千分位与两位小数补齐；④真机未复测，装 0.4.25 后需与电脑端金额对照一次。

> **M4.24 存档会话在原对话里继续**（2026-11-17）

用户说「不是每个对话新开一条对话，是和电脑上一样的在这个对话里面就一直在，可以加载出来」。M4.19 的做法是「同目录新开一条会话 + 把最近 12 句压成摘要当开场」——因为当时直接唤醒冷会话只会拿到 `turn/end {kind:'blocked'}`，一个字都没有。

这次把 DSH 本体（`resources/app.asar`）当文本检索，找到 `blocked` 的来源：agent 主循环里 `const decision = await this.preStep(target, { turn, step }); if (decision.kind === "reject") { turnEnds = { kind: "blocked" }; return false; }`，而 `agent/pre-step` waterfall 上唯一会拒绝的监听者是 `ArchivedSessionGate`（`underArchivedSession()` 查 `workspaceRegistry.archivedSessionIds`）。它的注释写得很直白：「… proposes a step the gate rejects, which the loop ends as `blocked` without a request; **unarchiving lifts the gate for the whole lineage**」。

所以改法是把门抬起来，而不是绕开：插件 0.2.28 新增 `resumeArchivedSession()`（`workspaceController.unarchiveSession({ sessionId })`，返回的 `archivedSessionIds` 里还有它就报 `session/still-archived`），`promptDesktopSession()` 在会话不在电脑列表里时先抬门、再往**同一个 sessionId** 发原话，返回 `{ accepted, resumed: true, resumedFrom, sessionId }`；`buildArchiveDigest()` 与 `createSuccessorSession()` 整段删除。手机端 `DesktopPromptResult` 多一个 `resumed`，存档页说明条改成「电脑会把它接回原来那条对话，接着说」，发送成功后不再 `pushReplacement` 跳新会话，而是就地 `_revived = true` 开直播轮询。

实测：`POST /api/v1/desktop/sessions/960545fb…/prompt` → `200 {"resumed":true,"sessionId":"960545fb…"}`，该会话日志 seq 76 user → seq 84 assistant「收到」→ seq 86 `turn/end {kind:"completed"}`，没有新 sessionId；电脑 `/desktop/tasks` 里出现「课程设计 · 14:14 · completed · msgs=17」。插件 `node --test` **85/85**（`session-resume.test.js` 重写为 9 例），`flutter test` **382/382**（`archive_chat_m4_19_test.dart` 换成 `archive_chat_m4_24_test.dart`，测试数不变）。

> **M4.24 已知限制**

- 手机端的存档列表（插件自己的 `session-archive.json`）里那条记录还在，只是被「电脑列表里也在」的去重挡住不显示。
- 会话被放出来之后就回到电脑的会话列表，长期会攒回一批；「聊完再归档」的选项留到后面。
- 真机还没复测过一次完整的「点存档 → 发话 → 就地看到回复」。

> **M4.23 提问卡也能在手机上回答**（2026-11-17）

用户说「这个需要审核操作的手机上还是没有」。截图里那张卡（「歌词样式 / 歌词字幕想要什么形式？」+ 三个选项 + 输入框 + 跳过/提交 + 右上「2/2」）**不是权限审批，而是 `ask_user_question` 工具的提问卡**：在会话日志里它只是一次普通 `tool/call`（`session-e2e1f57b` 的 seq 880，`"name":"ask_user_question"`），Host 把它做成了一次 waterfall 事件 `user-questions/request`，不落日志。插件从 M4.4 起只接了 `approval/request`，所以电脑上正等人选项时手机上什么都没有。

修法：插件 0.2.27 监听 `user-questions/request`，只在手机正在看这个会话时接管（和授权同一条 10 分钟窗口），把问题挂进 `GET /desktop/sessions/<id>/events` 的 `questions` 字段；手机直播页在「过程」条之前渲染 `_QuestionCard`（单选/多选 + 可自己写一段 + 跳过/提交），提交走 `POST /desktop/sessions/<id>/questions/<questionId>`，body `{answers:[{id, selected, custom?}]}`；5 分钟无人应答按「跳过」放行（`{answers: []}`），把这一轮交回电脑。标题栏徽标跟着扩展成「待回答 N」。

新增 `app/test/desktop_question_m4_23_test.dart`（卡片出现 / 选一项提交后答案带 `selected` 发回、卡片消失 / 没选时提交禁用 / 跳过发空答案）与插件 `test/questions.test.js`（9 例：答案压缩、跳过、别人的会话答不了、`finish` 不下发、只有看着才接管、接管后能解开挂起的 Promise、无 `callId` 时自造不重样）。插件 `node --test` **85/85**，`flutter test` **382/382**。

> **M4.23 已知限制**

- 真机还没跑过一次真实提问：`ask_user_question` 要由电脑上的那一轮触发，无法在不挂住自己的前提下触发；线上验证的是字段与接口边界（`questions` 空数组、未知 id → 404、无 token → 401），卡片渲染由 widget 测试覆盖。
- 卡片不翻页：电脑端右上角是「1/2」，手机上一屏把几页顺着列出来。
- 仍是「看着才接管」：页面关掉、10 分钟窗口过后，提问就回到电脑弹窗，没有推送通知。
- 隧道域名每次重启都变（本次 `https://<公网隧道>.trycloudflare.com`），装完包要重新扫码配对。

> **M4.22 输入框里打出来的字不见了**

插件 → 插件市场的搜索框里打字不显示：框里只剩一个光标（提示语也看不见），可统计行已经显示「已安装 18 个 · “dsh”」——说明 `onChanged` 收到了、过滤也生效了，纯粹是字画不出来。

根因在主题。`buildAppTheme()` 里 `textTheme:` 是**整体替换**成一个只写了 7 条样式的部分 `TextTheme`，没写到的 `bodyLarge` 就退化成没有颜色的 `englishLike bodyLarge 2021`；而 `TextField` 的正文样式取的就是 `theme.textTheme.bodyLarge`，于是打出来的字是透明的（提示语走 `InputDecoration.hintStyle`，同样被这条样式覆盖）。

修法：`textTheme: base.textTheme.merge(TextTheme(...))`——merge 到 `ThemeData` 已经算好的完整 Typography 上，并补上 `bodyLarge`（`p.text` / 15 / 1.6）与 `labelMedium`（`p.text2` / 12.5）的颜色。

新增 `app/test/theme_text_field_m4_22_test.dart`（浅/深色主题下 7 条正文样式都必须有颜色；真实搜索框的 `EditableText.style.color` 非空，`enterText('dsh')` 后 `find.text('dsh')` 命中）。`flutter test` **379/379**。

> **M4.22 已知限制**

- 只能守住「样式有颜色」，最终观感仍需真机确认（本次无 adb 设备）。
- 项目里别处若也用 `copyWith(textTheme: ...)` 或随手 `TextStyle()` 不给颜色，同样会出这类问题；暂未加全文 lint。
- 用户排队里还剩两条没做：**审核（授权）操作手机上仍然不出现**、**存档会话不要新开一条、要在同一条对话里继续**。
- 隧道域名每次重启都变（本次 `https://<公网隧道>.trycloudflare.com`），装完包要重新扫码配对。
> **M4.21 手机端也有「N 条排队消息」**（2026-11-17）：用户发电脑端截图说「这个功能手机上也得有」。电脑端在一轮还在跑的时候，会把后面排着的话列成「4 条排队消息」——每条能改字、能删、能插话（那个上箭头就是插话，`Cmd/Ctrl+Enter` 是全部插话）。手机端以前完全没有这个概念：排队的话只能等它自己轮到。现在直播页底部浮出同一条面板：折叠时写「4 条排队消息」，展开逐条列出、能改字（弹框）、能删、能单条插话，也能一键「全部插话」。数据全在 Host 上：插件 0.2.26 新增 `GET|POST /api/v1/desktop/sessions/<id>/queue`，往里调 `sessionController.state()`（第二个参数 `signal` 必填，漏了会 `throwIfAborted`）与 `updateQueue()`（`QueueAction` 只有 `edit` / `remove` / `steer`，**没有 moveUp**）。队列里带附件的消息会显示成「（另有 1 个附件）」，不会是空白。插件 `node --test` **76/76**，`flutter test` **377/377**。
>
> **M4.21 已知限制**：队列只在直播页读，手机端不存本地队列，改动都即时打到 Host（断网直接报错）；两端同时改同一条没有版本号，后到的覆盖先到的；面板靠 1.5 秒轮询刷新，展开时队列变短会直接少行；**真机未复测**（无 adb 设备）。用户排在这里的另外三条诉求这轮没做：搜索框输入时没有提示、审核（授权）操作手机上仍然不出现、存档会话不要新开一条而要在同一条对话里继续。
> **M4.20 每次开机后工作区又空了**（2026-11-17）：用户说「每次开启之后工作区里面的内容又没了」，截图里工作区只剩 `user`（`C:\Users\user`，标「暂无会话」）和一条正在跑的会话。查下来是三件事叠在一起：①截图里那两句话（「暂无会话」「点进去可以在电脑的这个目录里新建会话」）在 `app/lib` 里**已经不存在**（M4.13 换成了「空项目」和项目分组卡）→ 手机上跑的仍是 ≤0.4.12 的旧 APK；②插件在 `apply` 里就 `supervisor.start()`，那会儿 async 的 `workspaceRegistry` 还没就绪，只好把 `homedir()` 递进去，而 `RelayAgent` 的 `workspaceRoot`/`workspaceRoots` 是 `private readonly`，**直到 Agent 进程重启都不会重读**，`buildDeviceStatus()` 因此永远只报一条；③`rootsFromRegistry()` 同时读注册表的 `list()` 与 `entities`，`normalizeRoots()` 又不去重，Agent 上报的是 **18 条**（9 个目录各两遍）。修法：插件 0.2.25 新增 `GET /api/v1/agent/workspaces`（必须 agent token，`hub.authorizeToken(token, 'agent')`；手机 token 调它 401、agent token 调 `/desktop/workspaces` 也 401），`index.js` 的 `normalizeRoots()` 改成按 `canonicalPath()` 用 `Set` 去重（保住首次顺序，首个仍是默认工作区）；Agent 侧新增 `RelayAgent.setWorkspaceRoots()`（归一化 + 去重、没变返回 false、变了补发 `device.status`，配 `normalizeWorkspaceRoots()` / `sameWorkspaceRoots()`）与 `agent/scripts/serve.ts` 的 `refreshWorkspaceRoots()`（`client.onOpen` 立刻刷一次 + 每 `M1_WORKSPACE_REFRESH_MS`（默认 20000，0 关闭）一次，`shutdown` 里 `clearInterval`）。Agent `node --test` **60/60**（新增 `agent/tests/unit/workspace-roots.test.ts` 4 例；`package.json` 的 test 脚本改成跑全部 unit 用例），插件 0.2.25、`node --test` **69/69**（+3，`test/agent-workspaces.test.js` 真起 http server 验角色边界）。实测：热加载后 Agent 上报从 **18 条变 10 条**；把拉起参数临时改成 `[homedir()]` 模拟开机竞态 → Agent 先报 **1 条**、`client.onOpen` 那次刷新立刻变 **10 条**，探针日志每 20 秒一次 `rows=10 paths=10 changed=false`。附带产出 `tools/watch-device-status.mjs`（用手机 token 连 WS 直接打印 `device.status.workspaceRoots`，比翻日志快）。

> **M4.20 已知限制**：这次改的是「开机能自愈」，不是「不再有竞态」——插件那侧仍是先拉起 Agent 再等注册表，所以开机后最多有 20 秒（`M1_WORKSPACE_REFRESH_MS`）手机上看到的是旧目录，期间点进某个已消失的项目会报错；要彻底消除得让插件等注册表就绪再拉 Agent（会拖慢 DSH 启动）。改 Agent 代码必须同时落到 `dsh-plugin-m1/agent/`：插件里 `agentDir = join(bundleRoot, 'agent')`，根目录那份 `agent/` 只是源码（这次就因为只改了根目录那份，热加载后探针日志一直不出现）。仍未真机复测（adb 无设备）；手机侧真正的成因是**装着旧 APK**，装 0.4.19 之后才会看到项目分组卡。

> **M4.19 存档会话也能继续聊**（2026-11-17）：用户说「已存档的对话手机上也可以对话」。存档页以前底部写着「这是电脑端存档的会话，只能看不能继续发指令」，`if (!widget.archived)` 把 `_LiveComposer` 整个挡住了。两条路都试过、都留了证据：①**唤醒旧会话**——`sessionController.resolveAgent(id)` 后 `prompt(id)` 接口回 `{"ok":true,"accepted":true}`、会话也确实回到 `/desktop/tasks`，但磁盘日志只有 `turn/start {turn:2}` → `agent/inbox/spliced {removedCount:1, inserted:[]}` → `turn/end {turn:2, reason:{kind:'blocked'}}`，没有 `user/message`、没有 `assistant/message`，消息被吞；②**fork 旧会话**——`fork({sessionId, allowMigration:true})` 小会话（2 条消息）能聊，1235 条消息的大会话直接被出口熔断：`outbound body measures ~1,735,026 tokens（messages ~153,989 · tools[] ~13,494 · system ~4,560 · other ~1,562,983）vs the effective model window 1,048,576 … stopped at the egress fuse`。最终做法：插件 0.2.24 用 `sessionController.create({ cwd: record.workspace })` 在**原目录新开一条会话**，再用 `buildArchiveDigest()` 把存档里最近 `ARCHIVE_DIGEST_MESSAGES = 12` 条、每条截到 `ARCHIVE_DIGEST_CHARS = 360` 字的对话压成「（接着电脑上的一条存档会话继续聊《标题》…）用户：… 助手：…（历史到此结束，下面是用户的新消息）」当开场白发过去；`promptDesktopSession` 返回 `{forked:true, forkedFrom, sessionId}`，错误码区分 `SESSION_NOT_FOUND`（404）/ `SESSION_CREATE_UNSUPPORTED` / `SESSION_NOT_RESUMABLE`。手机端 `desktop_session_screen.dart` 让存档页也渲染输入条、说明条改「存档会话 · 发一句话，电脑会把它恢复成一条新会话，接着在这里聊」，`sendDesktopPrompt` 回 `DesktopPromptResult { sessionId, forked, forkedFrom }`，`forked` 且 id 变了就 `pushReplacement` 跳进新会话并开始直播轮询。App 0.4.19+46、`flutter test` **371/371**（+2，`app/test/archive_chat_m4_19_test.dart`），插件 0.2.24、`node --test` **66/66**（重写 `test/session-resume.test.js` 9 例），release APK 72,720,862 字节（SHA256 `7D80801736990E9BA845A0E16C938CEC7235765FD060F7103D8B75D61A3EF89C`）。端到端实测：`POST /desktop/sessions/session-4670a31a…/prompt` → `{"forked":true,"sessionId":"session-6d1042d4-…"}`，新会话 seq 8 是带摘要的开场、seq 17 assistant「收到」。附带产出 `tools/dump-session-log.mjs`（逐帧 zstd 解压任意会话日志、打印尾部事件），两条死路都是靠它取证的。

> **M4.19 已知限制**：不是「续上同一条会话」——电脑上会**多出一条新会话**（标题沿用原名、目录不变），旧存档仍在存档里；这是刻意的，唤醒会被 blocked、fork 长会话会超窗。摘要只带最近 12 条、每条 360 字，聊得很长的存档更早的上下文会丢（可调大，但别塞太多以免顶满窗口）。「同目录新开会话」依赖 Host 的 `sessionController.create({ cwd })`，老版本 Harness 没有这个方法，手机会收到「这台电脑的 Harness 太旧」。仍未真机复测。

> **M4.18 插件市场与电脑端同步**（2026-11-17）：用户说「插件市场是和电脑上同步的，不要现在这样的」。手机上的插件市场以前只读电脑端「设置 → 插件市场」里**手动配置**的第三方索引（`pluginMarket.listIndexes()`），这台电脑一个索引都没配，所以永远是空的（`indexes=0 entries=0`）——可电脑端自己的市场来自 Host `pluginManager.listBundles()`，列着 42 个插件包，手机一条都看不到。现在市场的主来源改成电脑端目录：插件 0.2.23 新增 `localizedMetaText(meta, field, language)`（`meta` 平铺 / 按语言分键 / 语言键直接是字符串三种形状都认，`zh-CN → zh → en` 依次退）与 `pluginCatalog({language})`（映射 `name/title/description/official/availability/spec/version/installed/enabled/removable/updatable/listedByDefault/source`，`pluginManager` 不可用时返回 `{supported:false,bundles:[]}`），`server.js` 新增 `GET /api/v1/desktop/plugins/catalog?language=zh-CN`（走 App token，失败 501 `PLUGIN_CATALOG_UNAVAILABLE`）。手机端 `MarketEntry` 加 `official/spec/availability/removable/enabled`，新增 `PluginCatalog` 模型、`HistoryApi.listPluginCatalog`、`LiveStore.pluginCatalog()`；市场页进页面自动读目录，`_marketEntries` 把目录条目与第三方索引里多出来的条目按包名去重合并（目录优先），**搜索改成在本地过滤**，按钮从「搜索」改成「刷新」，卡片多一个「官方」胶囊，概览行「N 个插件 · 电脑端插件市场 · 已安装 M 个」，安装按目录给的 `spec`（`包名@精确版本`）下发、装/卸完重新读目录，读不到目录时给出「读取目录」按钮而不是「输入关键字搜索」。App 0.4.18+45、`flutter test` **369/369**（+3，`app/test/plugin_catalog_m4_18_test.dart`），插件 0.2.23、`node --test` **57/57**（+6，`test/catalog.test.js`），release APK 72,720,954 字节（SHA256 `985AA277A631D82D07A9A8A68F7AD2C1B9C51BD6B8B65B8A401E556B6115E921`）。这次插件是 `plugin_manager set_bundle` 停用→启用后**热加载直接生效**（`/api/v1/health` 变 0.2.23），不必重开 DSH；现场 `GET /desktop/plugins/catalog` 回 42 个插件包。

> **M4.18 已知限制**：目录里的中文标题依赖 Host 在 `listBundles()` 里给 `meta`，这台电脑目前没给，所以卡片标题显示的是包名（`@deepseek-ai/dsh-experimental-auto-review` 这种）；`spec` 目前多是纯包名（Host 未返回 `installTarget` 精确版本），安装时由电脑端解析最新版本；「官方」标记直接沿用 Host 的 `official`，`dsh-base`/`dsh-web-app` 这类返回 `official:false` 的会显示成普通条目；目录只读，手机上仍不能「启用/停用单个插件」（那在「已安装」页）。仍未真机复测。

> **M4.17 桌面直播排版对齐官方 App**（2026-11-17）：用户第三次贴官方 App 截图，配文「对话做成这样」。前两轮解决的是**能力**（M4.12 的 Markdown 排版）与**内容**（M4.16 的注入/推理过滤），页面骨架却还是自己的：助手回复外套一层 `lineSoft` 浅底卡片 + 左侧 3px accent 竖条 + 圆角 16，工具记录写「过程 · N 步（点开看）」，顶部是一张 `Panel` 卡片、副标题直接把 `D:\Projects\…` 绝对路径用 `monospace` 怼出来。现在：列表 `itemBuilder` 直接 `return _EventRow(event: event)`（`ChatItemView` 的 assistant 分支本来就是纯 `MarkdownText` + `_AnswerActions`，只是被外面那层容器裹成卡片）；工具条改 `'${_running ? '进行中' : '已完成'} · ${_toolCallCount} 次工具调用'`，图标 `Icons.autorenew_rounded` / `Icons.check_circle_outline_rounded` + 右侧 `Icons.expand_more_rounded`，圆角 12，仍点开半屏「过程」；`_LiveHeader` 改 radius 22 胶囊（`palette.card` 底 + `palette.line` 边框），副标题 `'本机 · $folder'`，`folder` 由新增顶层 `desktopFolderName(String cwd)` 取路径最后一段（取不到只写「本机」）；`liveEmptyHint` 里「点上面的『过程』」跟着改成「点上面那条看完整记录」。App 0.4.17+44、`flutter test` **366/366**（+5，`app/test/desktop_live_m4_17_test.dart`），release APK 72,655,418 字节（SHA256 `5403BC368E0238586D610358A44E949067682D62BDA606FE5A97137E3F6797AC`）。插件无须改动。

> **M4.16 手机看到的必须是对话，而且一进来就是最新**（2026-11-17）：用户截图反馈「每个对话里面的内容你不应该放到最新的吗，而且你这英文是什么，我要的是对话」——正文第一条是 Host 注入的 `Time sampled while preparing turn 3, step 24: …`，第二条是模型的英文推理 `Header empty. So where does blue come from?…`，真正的对话在更下面。三处同时坏：①`INJECTED_USER_PREFIXES` 缺 `'Time sampled while preparing'`，而且**存档写入路径 `archiveEvent` 根本没调用过滤**（只有直播路径 `mapDesktopEvent` 调）；②`assistantText()` 在没有正文 part 时 `const chosen = texts.length > 0 ? texts : others;` 回退到全部 part，纯 reasoning 消息整段被当成回复；③`_scrollToEnd(force: true)` 用 `jumpTo(position.maxScrollExtent)`，而 `ListView.builder` 首帧的 `maxScrollExtent` 只覆盖已构建的几屏，长列表跳不到真正底部。修法：插件新增 `lib/chat-filter.js`（11 条注入前缀、4 条特征串、只扫前 160 字符、`isInjectedUserText` / `chatText` / `isInjectedEvent`），`assistantText` 删掉 reasoning 回退、无正文返回空串，`archiveEvent` 写入时过滤、`mapDesktopEvent` 改用同一份规则、`getArchivedSession` 读取时再滤一遍，archive-one 补 `title/cwd/lastTime/messageCount`；另加 `ARCHIVE_EVENT_SCHEMA = 2` + `findSessionLogFile()` + `migrateLegacyArchiveEvents()`（含注入的老记录按磁盘日志重读，现场实测该会话 380 → 342 条事件、`Time sampled` 等全消失）。App 侧 `lib/services/chat_filter.dart` 同一份前缀表兜底，`_messages` 的 user 分支先过滤；列表改 `reverse: true` 让最新一条天然在底部，`_scrollToEnd` 改 `jumpTo(0)`/`animateTo(0)`；`_LiveFooter` 三态文案（往上翻时「往上是更早的对话 · 点这里回到最新」可点回）。App 0.4.16+43、`flutter test` **361/361**（+5），插件 0.2.22、`node --test` **51/51**（+5）。踩坑：不要用 `(Get-Content -Raw) -replace … | Set-Content` 改含中文的 UTF-8 文件——PS 5.1 按 GBK 解码会双编码乱码并吞掉行尾换行。

> **M4.15 新建项目落点修对**（2026-11-17）：用户截图反馈「新项目要建立的位置不对」，提示写着「将建在: D:\Projects\课程\上册\计算方法实验」。截图里另有线索：标题还是「新建工作区」（M4.13 已改名「新建项目」），说明手机上装的是旧 APK；但**换新版也会错**——M4.13 用「授权根里有没有 `D:\Projects\项目` 这一项」判断落点，而电脑端返回的 9 个授权根全是具体项目（`…\项目\deepseek手机端` 等），`…\项目` 是它们的父目录、从不在列表里，于是每次都判成「没授权」退回第一个授权根。现改为无条件指名项目根（`String get _targetParent => kDefaultProjectParent`），提示统一成「将建在：D:\Projects\<名字>」；插件 0.2.21 的 `resolveParentDir()` 本来就允许「显式指定且目录真实存在」，现场带 `parentDir` 实测确实建在 `D:\Projects\<名字>`，插件一行未改。App 0.4.15+42，`flutter test` **356/356**，release APK 72,589,702 字节（SHA256 `3AA815BE6D58D4C1AC21C7FFAB8CA8E7A12DC475BE72DBC9B79142B64FD2B023`）。

> **M4.14 直播页不再空手**（2026-11-16）：两条反馈同源——手机在「看起来应该能看见」时什么都没看见，也没人告诉它为什么。①「每次点进去加载不出来对话」：插件 `listDesktopSessionEvents` 首屏只从日志尾部倒取 **80 条已映射事件**，忙会话这 80 条可能全是 `tool-call`/`tool-result`（实测 36+35），App 只留 user/assistant → 正文 0 条 → 显示空态；带 `afterSeq` 时旧代码**从头往后扫**并 `break`，积压就永远追不上。现在首屏从尾部倒扫到「够 12 条对话（`MIN_CHAT_EVENTS`）或 600 条（`MAX_TAIL_EVENTS`）」，增量也改为**从尾部倒扫**（拿到最新一段）。②「授权手机上没有出来也没有提醒」：`WATCH_WINDOW_MS` 2 分钟 → **10 分钟**（App 切后台/锁屏时轮询停，「不算在看」就一律交回桌面弹窗）、`APPROVAL_TIMEOUT_MS` 90 秒 → **2 分钟**，超时先 `log('接管授权超时，已退回电脑：…')` 再退回电脑（以前一声不响）。手机端 `desktop_session_screen.dart`：有 `_approvals` 时顶栏挂「待应答 N」红底胶囊，空态文案抽成 `liveEmptyHint({required bool hasEvents})` 区分「这个会话还没有可展示的内容」与「这一屏只有工具调用，点上面的「过程」看完整记录」。App 0.4.14+41、`flutter test` **356/356**（+3），插件 0.2.21、`node --test` **46/46**（+7）。

> **M4.14 已知限制**：这一版只做到「打开直播页就能看见待应答」，**没有真正的推送提醒**——App 被系统冻结时轮询停止，授权仍会先落到电脑弹窗；要做「手机响了」得走 M4.4 的通知通道（本地通知 + 前台服务），属于独立一轮。接管窗口放宽到 10 分钟后，最坏情况是用户早已离开、授权仍被手机接走、2 分钟后才退回电脑；若实测觉得吵，可改成「最近一次轮询在 60 秒内才接管」。仍未真机复测。

> **M4.15 已知限制**：落点对错只在「新建」这一刻可见，桌面端没有把「项目根」这个概念暴露给手机（`GET /desktop/workspaces` 只给具体项目），所以手机端只能硬编码 `kDefaultProjectParent`；哪天电脑端的项目根换了位置，App 要跟着升版本。仍未真机复测（`adb devices` 无设备）。

> **M4.16 已知限制**：过滤是**按文本形状**判的（前缀 + 前 160 字符特征串），Host 以后换一句运行时注入的措辞，手机上就又会冒出一条英文气泡，得回来补表；老存档只有「磁盘日志还在」时才能洗回来（`migrateLegacyArchiveEvents()` 依赖 `findSessionLogFile()` 找到 `session.v*.jsonl`），日志被清过的会话保留原样；`ARCHIVE_EVENT_SCHEMA = 2` 之前的记录需要 DSH 重开跑一次迁移，迁移前打开仍是旧的脏正文。仍未真机复测。

> **M4.17 已知限制**：官方回复底部那排是「复制 / 分享 / 重新生成 / 更多」，我们只有「复制 + 时间」——**重新生成**要插件支持重放一轮，属于新能力；官方每条回复左侧有头像，直播页 `_EventRow` 没走头像分支；官方的「已完成 · N 次工具调用」是**内联展开**（点开在对话流里就地铺开步骤），我们点开仍是底部半屏「过程」面板；「已存档」徽标与「只能看不能继续发指令」提示是我们自己的形态。仍未真机复测。

> **M4.13 已知限制**：「在项目里新建会话」（新建对话）按用户要求**本轮没做**，项目卡里只有「进直播」和「进工作区页」两个入口；项目卡头部还没显示「最后活动 1 小时前」这类副标题；`parentDir` 要插件 0.2.20 真被加载才生效，否则 App 退回第一个授权根；仍未真机复测。

> **M4.12 已知限制**：Markdown 只做到「块级 + 行内」，不做嵌套列表 / 脚注 / HTML / 图片语法（`![](url)` 当普通文本），表格单元格不解析块级元素；代码块**没有语法高亮**；链接点击未接（`onLinkTap` 留了接口）；段尾只有「复制 + 时间」，官方 App 的「重新生成 / 点赞」要接云端重发与反馈通道，留到后续；仍未真机复测。

> **M4.12 构建注意**：本机项目路径含中文时 release 构建必挂（`Error: Unable to read file: …\app\.dart_tool\flutter_build\<hash>\app.dill` → `AOT snapshotter exited with code 255`，与 `flutter analyze` 崩在同一个中文路径根因）。做法：`robocopy app C:\Users\user\dsh-tools\build\dsh-app /E /XD build .dart_tool .gradle .idea .cxx`，在 ASCII 目录里 `flutter build apk --release`，再把 `app-release.apk` 拷回 `dist\`。

## 7. 设计依据



- 信息架构与交互：`docs/design/MOBILE_UI.md`（五 Tab、状态机、审批 Bottom Sheet）

- 真实链路契约：`docs/design/M1_PROTOCOL.md`

- M1.1 增量契约：`docs/design/M1_1_DELTA.md`（历史会话/消息、任务 REST、工具输出结构化）

- M2-α 增量契约：`docs/design/M2_DELTA.md`（审批通知、前台服务保活、自动重配对）

- M2.1 增量契约：`docs/design/M2_1_DELTA.md`（事件增量补拉、审批等待排队降级）

- M2.2 增量契约：`docs/design/M2_2_DELTA.md`（完成自动折叠、排队立即发送、6 套主题、分享卡、长按菜单）

- M2.3 视觉契约：`docs/design/M2_3_UI_DELTA.md` + `docs/design/mockups/ui_a.png` / `ui_b.png`（A 配色 + B 排版：浅色优先、跟随系统深色、六页重做）

- M2.4 简化契约：`docs/design/M2_4_SIMPLIFY_DELTA.md`（删除演示数据、六页减法、统一空态）

- M2.5 更新契约：`docs/design/M2_5_UPDATE_DELTA.md`（应用内检查更新/下载/系统安装器、后端版本与 APK 接口）

- M2.6 项目同步契约：`docs/design/M2_6_PROJECT_SYNC_DELTA.md`（workspace.list / file.read 请求-响应、项目浏览、只读预览、会话工作区绑定）

- M3.6 增量（手机侧）：见本文 §6.4（插件双 Tab / 插件市场、桌面会话排序与自动到最新、版本号）

- 产品与视觉方向：`docs/concept/项目构思方案_v0.2.md` §1.3 与 `docs/concept/mobile_ui.png`

- 安全交互口径：概念稿 §2.7（六道闸门、三段式急停、审批只给「允许一次」）



## 8. 已知限制与下一步



1. M2.4 起无演示数据：未连接时六页均为连接空态；真实审计记录尚未在后端落地（M1.2/M2），电脑控制页只展示真实连接信息。

2. 工具输出已结构化（M1.1）：`tool_call` 命令 mono 块、`tool_result` 输出可折叠，带状态/耗时/退出码，不再显示原始 JSON 片段。

3. 历史已由后端 REST 持久化（M1.1）：会话/消息/任务可回填；M2.1 起断线/回前台按 `seq` 从 `/events` 增量补拉，与实时流同一入口去重，补拉失败会提示并可重试。App 本地仍不缓存实时流，冷启动需重新连接再拉取。

4. 后台保活已由前台服务（M2）覆盖；锁屏审批通知依赖系统通知权限与厂商省电策略，部分机型长期后台仍可能被清理（远程推送未做，对应决策 D-8 的后续）。

5. 无状态管理库：`ChangeNotifier` + `ListenableBuilder`；接真实数据规模变大时按设计分册换 Riverpod。

6. 远程桌面、文件浏览、二维码配对、推送通知是占位或演示，按 M4/M2 排期补。

7. iOS 未构建（Windows 上不可编译），只交 Flutter 源码与说明；debug APK 未签名，签名与正式打包属于 M5。

8. **后端重启**：M2 起后端 token 落库（backend 侧），手机端在 401/4401 时会自动重新配对并重连一次；若配对码也变了则需回连接页手动配对。

9. 本机 headless 模拟器不可用（本次 `adb devices` 无设备），M1.1/M2 的 UI 截图未补拍；M2 通知/前台服务行为已由 16 个单测与 APK 构建覆盖，建议真机安装后用 `adb shell dumpsys notification` 复核渠道与通知。

10. M2.1 的排队指令只存在内存（不落本地存储）：进程被杀会丢失，且只保留最近一条（深度 1，避免误发过期指令）；事件补拉只在「已连接 + 有会话」时触发，离线期间的事件依赖后端 `task_events` 落库，重连后补拉。

11. M2.2 分享卡：PNG 由 Canvas 在 Dart 侧渲染（1080 宽、脱敏，不含工具命令/路径/token），Android 侧写 `cacheDir/share` 后经自实现最小 `ShareFileProvider`（不引 androidx，保持零新增依赖）+ 系统分享面板发出；本机无模拟器/真机，系统分享面板未实测，建议真机装 APK 后点一次「分享」确认 chooser 正常。

12. M2.3 主题：浅色默认 + 跟随系统深色，「我的 → 外观」三选持久化；颜色/圆角/间距由 token 统一，主界面已无硬编码深色值；`TaskStatus` 等 const 枚举内置色仍是固定语义色（状态色），不随明暗切换（对比度已按 token 校验）。

13. M2.2「立即发送」是打断 + 改说而非 turn 内插话：先发 `task.cancel`，收到终态或 3 秒超时后把排队指令作为新 prompt 发出；若后端仍处于 SESSION_BUSY，会显示系统提示而不会静默丢消息。

14. M2.3 视觉重构：本机无模拟器/真机，浅色六页截图未补拍；深色模式对比度按 `AppPalette` token 手工校验（正文与底 ≥7:1、次要文本 ≥4.5:1），建议真机复核；`flutter analyze` 因中文路径仍不可用，验收用 `flutter test`（164/164）与 `flutter build apk --debug` + `aapt dump badging`（versionName=`0.1.4-m2.3`、versionCode=`5` 为上一版；M2.4 为 `0.1.5-m2.4` / `6`）。

15. M2.4 删除演示数据后：未连接状态无法体验任何页面功能（只能查看空态并通过「连接电脑」进入配对页），属预期；已连接功能（对话/历史/任务/审批/取消/折叠/主题/分享/紧急停止）保留并由 `flutter test` 覆盖；空态与已连接界面的真机截图待补拍。

16. M2.5 在线更新：不做静默安装（Android 平台限制，最后一步由系统安装器确认）；首次需手动装 0.1.6；下载后只按 `size` 校验（接口已下发 sha256，逐块校验待补）；debug 签名要求前后版本签名一致才能覆盖安装；本机无真机，安装器跳转只做了编译+单测级验证，建议真机点一次并观察「我的 → 关于」版本号变为 `0.1.6-m2.5`。

17. M2.6 项目同步：手机端只读（不做写入/重命名/删除）；二进制与大文件（默认请求 256KiB、服务端硬上限 1MiB）不可预览，`truncated` 时仅显示前段；`.git`/`node_modules` 等忽略目录不展示（仅 `ignoredCount` 计数）；需要电脑端 Agent 上报 `capabilities.workspaceList/fileRead`，旧版 Agent 会提示升级；`workspace.list`/`file.read` 结果不进会话消息流与任务时间线；本机无真机，项目浏览/预览页面仅单测与 APK 构建级验证。

18. M3.6 插件市场/会话新鲜度：插件包分组与市场接口需要电脑端插件升级后生效，旧版（运行中的 8787 未热重载）只走扁平列表回退；安装的构建脚本确认依赖 Host 返回的 `pendingBuilds`/`nextStep`，Host 不返回时会直接完成；`lastTime` 为毫秒时间戳，跨天显示 `MM-dd HH:mm`，不做本地化时区切换；本机无真机，插件页与桌面会话到最新仅单测/构建级验证，建议真机连一次新版插件复查。

19. M4.0 工作区：新建工作区只在**第一个授权根目录**下建子目录（不支持相对多级路径，名字里的 `\ / : * ? " < > |` 会被换成 `-`，同名目录直接复用而不是新建空目录）；需要电脑端插件 **0.2.9+**，旧插件返回 404 时对话框提示「电脑端插件版本过低」。工作区页的「最新会话」取自桌面任务镜像（`GET /api/v1/desktop/tasks`），该接口只返回最近 50 条任务，因此更早的历史会话不会出现在工作区页；底部输入条固定发给排在最前（最后活动）的那个会话，想发给别的会话请点进会话再发。本机无真机，工作区页/新建对话框仅单测 + APK 构建级验证。

20. M4.1 插件画廊/市场：已安装插件画廊需要电脑端插件 **0.2.10+**（`GET /desktop/plugins/gallery`，旧插件返回 501，页面提示升级）；分组靠 `moduleName` 正则 + `meta.experimental` 推断，Host 未提供 `meta.title/description` 时退回模块名，个别插件可能落进「其他插件」。市场索引兜底依赖外网 `https://api.dshmarket.com/v1/index.json`，离线或 Host 拒绝刷新时市场仍为空（已安装插件画廊不受影响，手机端只提示「DSH 默认索引」与 0 条）。开关改动与电脑端一样需重启 DSH 才完全生效。本机无真机，画廊页/市场卡片仅 `flutter test`（267/267）+ release APK 构建级验证。





---



维护约定：改动 `app/` 后跑 `flutter test`，并在本文与根 `README.md`、`PROJECT_STATUS.md` 同步状态。

21. M4.2 手机附件与助手首屏：AI 助手页连上电脑后直接是对话页（无「手机/电脑」切换）；附件按钮常驻（拍照/相册/文件）。附件按工作区名落到 `<工作区>\手机附件\`，要求工作区是一级目录（更深时退回当前会话 cwd），单文件限 20 MiB；云端直连页（不连电脑）仍不支持附件；底部输入条固定发给最新会话；本批交付时 adb 掉线，M4.2 真机链路（首屏/拍照上传/回执/电脑端落盘目录）**尚未复测**。

22. M4.3 直播「已运行」：起点取会话日志里最新 `turn-start` 的事件时间（需电脑端插件 0.2.12+，旧插件退回任务行最后活动时间，显示的时长会略短）；时长依赖两端系统时钟一致。

23. M4.4 通知：任务完成/失败/取消只在 App 处于**后台**时提醒（前台不发）；通知栏的「允许 / 拒绝」按钮决定依赖 App 进程存活，进程被杀时点按钮只会打开 App；App 被系统彻底杀掉后不会再有通知（厂商推送未接入）。开关在「我的 → 通知」，默认全开。
24. M4.5 更新进度条：分帧只改变 onProgress 的上报节奏（256 KiB / 30 ms），不会让下载变快；本地中继已是速度上限。若手机在不同子网，下载速度受 WiFi 影响，帧数会自然减少。
25. M4.6 / M4.48 AI 助手两档：**本机对话**是云端 API Key 直连（不经过电脑），**远程电脑**才是电脑上的 AI；两档状态互不影响，附件/直播/通知只在远程电脑档生效。





26. M4.7 本机对话附件：图片按 base64 `image_url` 直发云端模型（不经电脑、不落盘），文本文件内联，二进制只发文件名；远程电脑档仍落到 `<工作区>/手机附件/`。
27. M4.10 会话存档：存档只能看不能继续发指令；扫描只补存档里缺失的会话，日志事件上限 1500 条、正文每段 4000 字、最多 400 条会话；需要插件 0.2.14+（旧插件接口 404 时手机端不显示这一组）；`session-archive.json` 在 DSH 重开后由 30 秒定时器生成。
28. 「工作区」页的「暂无会话」卡片只反映当前电脑列表：电脑上真删掉目录后，要等注册表 5 秒缓存 + 手机端 5 秒轮询才消失；存档仍然只能看不能继续发指令；需要插件 0.2.19+ 存档列表才不含测试临时目录。
29. M4.49 插件热修（便携版 DSH）：电脑端 Agent 只找 PATH 的 `dsh.cmd` 与 `%LOCALAPPDATA%\Programs\DeepSeek Harness`，便携版装在 `<DSH 安装目录>` 时五条发现路径全落空，每 30 秒报「未找到 DeepSeek Harness 安装」，手机端于是看到空的「工作区」二级页。插件 0.2.34 起从 `process.execPath` 推出安装根并注入 `DSH_INSTALL_ROOT`，agent 侧再加一条「问父进程 exe」的兜底（不依赖插件重载）。**仍然没做**：Agent 掉线时二级页照旧显示「电脑端还没有配置工作区（M1_WORKSPACE_ROOT）」，没有说明是没连上（`liveStore.deviceOnline` 已有信号，`ProjectsScreen` 没用），下次改成掉线态 + 重试。
30. M4.50 工作区「新会话」：以前点「新会话」是让 Agent 子进程在磁盘上建一个空会话，而手机工作区列表和电脑端列表读的都是**电脑端主进程内存里的 `sessions`**（两条进程两套表），所以会话建出来了、两头都看不见。现在不再建空会话：按钮改成「去对话框发第一条消息」，绑好目录、切到 AI 助手的「远程电脑」档并聚焦输入框，用户发第一条消息时才真的建会话（那时才有对话可显示）；电脑还在忙时只记下目录并提示。**仍有限制**：电脑端「会话」列表还是看不到手机发起的会话（同一份磁盘会话被 Agent 进程持有），要改需要把会话登记进电脑端并解决并发写同一个日志文件的问题，方案待定。

31. M4.51 工作区项目卡默认折叠：以前（M4.13）项目分组默认全展开，一个项目攒到二十几条会话后，首页只剩这一个项目的会话列表，想找「直播中」那条要先翻过一堆「已存档」。现在项目卡默认收起，只留项目名、目录、`N 个会话 · M 个进行中 · 最后活动…` 摘要；点项目头才摊开，再点收起，各项目独立（`_expanded` 按工作区路径记，只在页面内存里，不写设置、重启回默认）。折叠时项目头右侧有一个可旋转的小箭头作提示，空项目不画箭头。**注意**：折叠后筛「进行中 / 等待授权」，结果仍收在项目卡里，需要再点一下项目头；卡片摘要会写「N 个进行中」，不至于以为筛选没生效。

32. M4.52 手机没有 WPS 也能读 .docx：以前文件页把 `.doc` / `.docx` / `.xls` / `.ppt` 一类全当二进制，只给一块「用其他应用打开」面板；手机上没装 WPS 或阅读器时点了只会提示「手机上没有能打开这种文件的应用」，文档彻底看不到。现在 `.docx` 由 App 自己解：`app/lib/services/office_text.dart` 用纯 Dart 读 zip、取 `word/document.xml` 抽正文（不新增任何依赖），文件页显示成可选中、可滚动的文字，标题行标「按文字预览（排版和图片不显示）」，底部仍保留「用其他应用打开」以便看真版式。**限制**：排版、字体、图片、表格线、页眉页脚都不显示；`.doc`（97-2003 二进制）、`.xlsx`、`.pptx` 仍交给外部应用；加密 docx、非标准 zip、超过 12MB 的 docx 抽不出文字，会明确说「没读出文字」而不是显示空白；「没装应用」与「打开失败」目前仍是同一句提示（`FileOpener` 把两者都吞成 false）。

33. M4.53 提问只在「手机正看着这条会话」时接管：M4.31 起插件只要发现手机连着（`hub.appCount > 0`）就把 `user-questions/request` 接下来，于是人坐在电脑前时电脑不弹「确认需求」卡、只看到会话停住。插件 0.2.35 起门禁和授权一致——**手机正停在这条会话的「桌面直播」页（5 秒轮询内看过它）才由手机接**，其余时候交回电脑弹窗。**仍有限制**：手机正盯着这条会话时，电脑那边依旧不会出卡（Host 只有 waterfall 事件，没有能撤掉电脑那张卡的广播接口，双端同显做不到）；插件热重载会丢掉内存里挂起的提问，那条提问只能等 5 分钟按「跳过」放行，重载要避开正挂着的提问。

34. M4.54 电脑和手机同时出现同一张提问卡：DSH 的 Web 客户端本来就支持多个客户端同挂一个 pending 提问（先答者生效、晚到的提交被 gateway 静默丢弃，卡片由会话的 `userQuestions` 投影决定去留），所以插件 0.2.36 接管提问时先把 `next()` 叫起来让电脑照常弹卡，手机这边也挂一张，两边赛跑：电脑先答 → 用电脑的答案并摘掉手机卡；手机先答 → 用手机的答案，电脑那张随投影关闭自己消失。手机卡 5 分钟没人答只收手机那张，电脑那张还能继续答；两边都没人答才按「跳过」放行。**注意**：两端没有优先级（谁先答用谁）；插件 0.2.36 已热载生效（`/api/v1/health` 回读 `version:"0.2.36"`）。

35. M4.55 → M4.56 手机终于能看到并回答提问：M4.54 之后真机仍是「电脑上有、手机没有」。M4.55 先把门禁放宽成「手机连着就接管」（插件 0.2.37，测试 162/162），手机上还是没有——在监听器入口写文件日志才看清：`ctx.on('user-questions/request', …)` **一次都没被调用**。原因是 DSH 的问答工具有两条路：`userQuestions.ask()` 才派发 waterfall，`askTimed()`（「前端等，客户端先答就算数」那条）不派发，`ask_user_question` 走的正是后者，所以插件那条监听器对这类提问永远收不到。M4.56 改从**会话日志**认：`collectLogQuestions()` 找「`tool/call` 名是 `ask_user_question`、却没有配对 `tool/result`」的调用，`questionId` 直接用 `callId`；会话详情的 `questions` 与 `/desktop/pending` 都是「waterfall + 日志」两路合并（按 `questionId` 去重），所以手机无论停在哪一页，「工作区」的待回答横幅都能出现，打开会话能看到卡。回答时先走原来的 `pendingQuestions`，查不到就用 `agents.get(sessionId)` 拿到 Agent、`userQuestions.answer(agent, callId, { answers })` 交回；「跳过」按每题空 `selected` 生成完整批次，避免 `BAD_ANSWER`。插件 **0.2.41** 已热载（`/api/v1/health` 回读 `version:"0.2.41"`、`agentOnline:true`），手机 App 不用换包。**注意**：0.2.40 曾把结果事件的 id 认成 `callId`（实际在 `toolCallId` 上），导致历史提问全被当成待答、手机一口气列出 8 张空卡；0.2.41 已修（`toolCallId ?? callId ?? message.source.callId`）。**限制**：只认「电脑上还活着」的 live 会话（已归档会话的日志不在 `sessions.list()` 里，认不到）；手机要连着插件（`apps > 0`）才看得到；电脑先答、手机还没刷新那一两秒里在手机上点提交会提示「回答失败」（结果不受影响，因为晚到的提交本来就被丢弃）。
36. M4.57 功能页新增「接收文件」：电脑端（或 AI）把做好的文件放进插件状态目录的 `received/`（这台机器是 `<DSH 数据目录>\dsh-plugin-m1\received\`），手机「功能 → 接收文件」按修改时间倒序列出，点开复用文件预览——图片能放大、`.docx` 按文字读（M4.52）、`.md`/`.txt` 在 App 里直接看正文，其它交给系统应用。接口是 `GET /api/v1/received`（列表）、`GET|DELETE /api/v1/received/<name>`（需要 app token；文件名只取最后一段，`..`/隐藏名一律拒绝）。**限制**：单向只读（App 不删不改、不写回电脑）；只列一层，不进子目录，跳过隐藏文件；最多 200 条；需要插件 0.2.42+，旧插件页面会显示「读不到接收文件」。

37. M4.58 回答失败要说清原因：手机点提问卡的「提交」以前一律显示「接口不存在（HTTP 404）」，因为插件失败时只回 `false`、服务端一律 404 `QUESTION_NOT_FOUND`，而 App 对 404 有固定文案。现在插件会记录失败原因（`QUESTION_NOT_FOUND` / `NO_QUESTION_SERVICE` / `NO_AGENT` / `NOT_CONTINUED` / 异常码），服务端改回 **409** 并把原因带进 `message`——手机端收到 409 会显示「请求失败（HTTP 409）：<原因>」，不用重装 App 就能看到。插件 0.2.43，测试 178/178；仍然受 `HMR transactions cannot be nested` 影响，需要彻底重启 DSH 才生效。0.2.44 接着把它真正修通：DSH 里 `userQuestions.answer()` 只认 `continued`（超时后）的提问，还在等回答的（open）提问只能靠 waterfall 的返回值来答；而 waterfall 拿到的 `req` 没有 `wait.callId`，插件只能用自造 `q_…` 当键、手机传的却是会话日志里的真实 `call_00_…`，两边对不上。现在加了「会话 + 题面」的内容键：两路去重只留一张带选项的卡，回答时先按内容找到 waterfall 的挂起项并 `finish()`。真机上手机选的答案能回到工具，卡片随后自己收起；插件 0.2.44（测试 180/180）。
38. M4.59 手机原生回答提问：前几轮都卡在同一处——`user-questions/request` 是 agent 作用域 waterfall，插件从根 `ctx` 注册监听器收不到；从会话日志猜出来的提问又只能调 `userQuestions.answer()`，它对 `open` 提问一律返回 false。这一轮把 `app.asar` 里的 `@deepseek-ai/dsh-api-gateway` 解开，还原出远程事件协议：WS `/api/remote.mux` 发 `{type:'open', endpoint:'$events', payload:{args:{}}}`，下行 `ready`/`emit`/`waterfall`/`cancel`，回答走 `POST /api/$events/result` 的 `client-request`（`payload` 必须恰好一个 `args` 字段）。插件自己用 `connection.authenticatedUrl()` 登录成浏览器客户端订阅这条流，收到 `waterfall` 后存进 `remoteQuestions`，手机提交时把答案作为 waterfall 返回值回给 Host。真机 `REPLY … {"ok":true}`，工具拿到的就是手机上选的项；插件 0.2.60，测试 182/182，手机端不用换包。坑：不回 WebSocket pong 会被关连接（表现为拿到 `ready` 后再无帧）；`/connect?token=` 不适合 WS，要用 `/?token=`。
39. M4.62 直播推送（进行中）：插件已经有远程事件流（`emit` `api-session/*`），于是在 `/api/v1/desktop/live` 上开了个 WebSocket 广播：`emit` → `{type:'session'}`，`waterfall`/`cancel` → `{type:'question', state:'open'|'gone'}`。`server.js` 的 `upgrade` 只处理这个路径、其它路径直接放行（第一版写 404 把中继自己的 `/ws` 掐掉，agent 直接掉线）；中继还会对同一 socket 二次握手，用 `request.__m1Live` 标记跳过。插件 0.2.67，探针能拿到 `101` + `ready`，但 `session`/`question` 帧还没在真机上观测到。
40. M4.63 App 启动自愈：有用户「打开就闪退、清数据才好」，判定本地存档把启动卡死。`services/boot_guard.dart` 记启动尝试（3 分钟内连续 3 次没走到第一帧就判定失败），命中就 `disconnect()` 清会话存档并提示「重新扫码即可」，第一帧画出后计数归零。只兜启动期崩溃；崩溃根因仍未定位（缺 `adb logcat` 崩溃栈）。App 0.4.58+79，测试 533/533。
41. M4.63b 更新说明自动发布：「以后更新附上更新说明」——每次发版在 `docs/UPDATE_NOTES.md` 顶部加一段 `## <版本号> — <标题>`，插件 `lib/appupdate.js` 的 `readReleaseNotes()` 按版本名前两段抽出来塞进 `/api/v1/app/version` 的 `notes`，App 更新弹窗直接显示；显式配置 `appNotes` 仍优先。插件 0.2.68，测试 185/185。同一份说明与 APK 也放进 `received/`，手机「功能 → 接收文件」可见。42. M4.64 文件能分享出去：手机上没装能打开某种文件的应用时（这台机器是没装 WPS 的 `.docx`），以前只能看着「用其他应用打开」弹一句「没有能打开这种文件的应用」，文件页也没有别的出口。现在 `FileOpener` 多了 `shareBytes`：原生侧把字节写进 `cacheDir/share/files/`，用 FileProvider 换成 `content://` 后拉起系统分享面板（`ACTION_SEND`，微信 / QQ / 文件管理器都能收）；文件页右上角、`.docx` 文字预览底栏、「打不开」兜底面板都补了分享入口，打开失败时也改成指路「点右上角分享」。App 0.4.59+80，测试 536/536。**限制**：只有拿到字节的文件能分享（工作区文本预览走字符串接口，没有分享按钮）；还没有「保存到手机」（要补 `ACTION_CREATE_DOCUMENT` + `onActivityResult`）。

42. M4.65 App 内「充值」页：以前「我的 → 去充值」直接拉系统浏览器跳官方页，跳走就断联，回来还得自己找刷新。现在点「去充值」先进 App 内的「充值」页——充值余额 / 赠送余额、查过多久、三步流程、「打开官方充值页」（`MethodChannelUrlOpener`，仍交给浏览器）与「已充值，刷新余额」，再加上三张说明卡（为什么 App 里不能直接付钱 / 没到账怎么办 / 赠送额度与发票）。**仍然不能真付款**：手机端没有商户号，电脑端账户服务也只有读余额与登录登出，没有下单、收款、开发票的方法；这一页是引导，不是收银台。App 0.4.60+81。

43. M4.66 功能页「更新日志」：用户要求「每次更新日志都放在那里面」。插件 0.2.69 新增 `GET /api/v1/app/notes`，`lib/appupdate.js` 的 `readUpdateNoteList()` 把 `docs/UPDATE_NOTES.md` 按 `## ` 拆成 `{version, date, title, body}`；App 的 `screens/changelog_screen.dart` 优先读电脑这份，没连电脑或读取失败时回退随包的 `assets/update_notes.md`（并在顶部注明这是打包版本）。以后每次发版只要在 `docs/UPDATE_NOTES.md` 顶部加一段，手机这一页跟着更新，不用再单独发说明。


44. M4.67 充值页能在 App 内付款：用户追问「dsh 这个充值界面做不到手机上面吗」——电脑端的充值同样是嵌官方网页（`showPage(openPlatformPage, 'top-up')`），付款表单从来不在 DSH 里。手机端照做：新增 `screens/recharge_web_screen.dart`，用 `webview_flutter`（项目第一个原生 WebView 依赖）在 App 内打开 `platform.deepseek.com` 官方充值页，手机上登录一次就能付款；`alipays://`、`weixin://` 交给系统应用，返回后充值页自动刷新余额，系统浏览器降级成次级入口。0.4.61+82。踩坑：不确定进度条（`value: null`）会让 `pumpAndSettle` 永远等不到稳定；`Row` 里直接放 `FilledButton` 在测试环境会拿到无限宽约束。

45. M4.68 充值只保留 App 内入口：用户要求「只保留在应用内打开充值页」。充值页删掉「用系统浏览器打开」与 `_openRecharge()`（连 `_urlOpener` 字段一起去掉），内嵌页删掉右上角浏览器出口，`urlOpener` 只在 `onNavigationRequest` 里把 `alipays://` / `weixin://` 交给系统。0.4.62+83，测试 545/545、analyze 0 error。

46. M4.69 扫描件 .docx 按页看图：用户那份「没读出文字」的 `示例作业.docx` 其实没有文字（`<w:t>` 计数 0），是四张扫描照片。`office_text.dart` 新增 `docxImagePages()`（`word/media/` 图片、按数字排序、上限 24 张 / 40 MB），文件页在抽不出文字时改渲染竖排图片预览，底栏说明改成「这份文档没有可选文字（多半是扫描件）」。0.4.63+84，测试 550/550、analyze 0 error。

47. M4.70 打不开的文件不再给按钮：用户装上 0.4.63 后仍说「还是不行」，截图里那条 toast 其实是「用其他应用打开」失败了——这台手机没有能处理 .docx 的应用。`FileOpener` 新增 `canOpenBytes()`（原生 `resolveActivity` 只查不启动），文件页据此藏掉按钮、兜底改「这个文件只能在电脑上看」并引导分享。0.4.64+85，测试 553/553、analyze 0 error。

48. M4.71 修好「检测不到能打开的应用」：用户问「是检测不到吗，需要什么权限吗」。根因是 Android 11+ 包可见性——manifest 的 `<queries>` 只声明了 `PROCESS_TEXT`，`resolveActivity` 对文件一律 null。补 `ACTION_VIEW`/`ACTION_SEND` 声明，检测改 `queryIntentActivities`，真正打开改成「先启动、失败再报错」。0.4.65+86。

49. M4.72 修好「分享失败 / 打不开」：根因是 `content://` 地址生成用错组件（androidx `FileProvider` 配自写 `ShareFileProvider`，缺 `FILE_PROVIDER_PATHS` 必抛异常）；改成 `ShareFileProvider.uriForPreview/uriForShare`，补齐 `preview/`、`share/files/` 与 MIME，并把原生原因带回提示。0.4.66+87。

50. M4.73「用其他应用打开」改成 `Intent.createChooser`，每次弹候选应用列表（标题「用其他应用打开」），不再受默认打开方式影响。0.4.67+88。
