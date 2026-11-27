# PROJECT STATUS · DeepSeek Remote AI

> 更新：2026-11-23 19:45（Asia/Shanghai）
> 项目定位：手机（Flutter）远程连接自己电脑上的 DeepSeek Harness，实现「对话 + 任务执行 + 必要时的屏幕/控制」。

## 一、总体进度（对照策划案第九章八阶段）

| # | 策划案阶段 | 状态 | 说明 |
|---|---|---|---|
| 1 | 环境与接口调查 | ✅ 完成 | `docs/research/ENVIRONMENT_REPORT.md`、`HARNESS_INTERFACES.md`；ACP 通道已实测闭环 |
| 2 | 项目初始化 | ✅ 基本完成 | 目录与文档体系、`tools/` 构建流水线、`agent/`、`backend/`、`app/` 三个工程已就绪 |
| 3 | 电脑端 Agent | ✅ **M0+M1 relay 完成** | `agent/` ACP 内核（单测 36/36、合同 9/9、E2E 5/5）+ relay 层（自测 24/24、真 ACP 25/25） |
| 4 | Java 后端 | ✅ **M1 + M1.1 + M2 + M2.1 + M2.5 + M2.6 完成** | `backend/` Spring Boot 3.5.16：health/pair/WSS 中继/单 agent 顶号/多 app 广播；**M1.1 接入 PostgreSQL 16.10 + Flyway + 异步落库 + 4 个历史 REST**；**M2 增加 `auth_tokens`（sha256 落库、重启不失效）**；**M2.1 增加 `task_events` 独立事件表、会话级统一 seq、事件补拉 REST**；**M2.5 增加 `GET /api/v1/app/version` 与 `GET|HEAD /api/v1/app/apk` 应用内更新接口**；**M2.6 增加 `workspace.list`/`file.read` 转发白名单与结果广播（不占 seq、不写 task_events）**；health 0.1.1-m2 |
| 5 | Flutter 手机端 | 🟡 **真实链路 + 真实数据 + 后台通知 + 断线补拉 + 手感对齐 + 视觉重构 + 无演示数据 + 应用内更新 + 项目同步 + 文件可写** | AI 助手真实模式（连接/发指令/实时输出/审批/取消）+ M1.1 历史会话弹层、真实任务中心/详情时间线、结构化工具输出；**M2 锁屏审批通知、前台服务保活、401/4401 自动重配对**；**M2.1 按 afterSeq 补拉断线事件、执行/审批中排队自动发送**；**M2.2 完成轮折叠、排队立即发送、分享卡、长按菜单**；**M2.3 六页视觉重做为浅色默认 + 跟随系统深色 + 三选外观**；**M2.4 删除全部演示数据、未连接六页统一空态、界面减法**；**M2.5 我的→关于→检查更新（下载 APK + 系统安装器）**；**M2.6 项目页浏览真实目录、只读预览文件、在指定目录发指令**；**M2.8 项目页新建文件、文件页编辑并保存（保存前确认层、sha256 冲突保护）**（真机观感/安装器/文件页待验） |
| 6 | 远程桌面 | ⬜ 未开始（后置） | 方案已定 L1/L2/L3 分级，编码 H.264（MJPEG 实测不可用） |
| 7 | 整体联调 | 🟡 **M1/M1.1/M2/M2.1/M2.2/M2.3/M2.4/M2.5/M2.6/M2.8 已联调** | 本机 6/6、公网隧道 6/6、手机端人工验证通过；M1.1 重启后端历史不丢（P-1）、M2 重启后端 token 不失效（M2-A4）、M2.1 断流 60s 重连补拉 9/9 seq 唯一（A3）均已实测；M2.2 为纯 UI 层 143/143 单测覆盖；M2.3 为设计系统重写 154/154；M2.4 删除演示数据后真实链路仍 6/6（证据 `evidence/m1/e2e-2026-11-03T09-24-31-458Z.json`）、164/164 单测；M2.5 更新接口本地+公网实测 200、真实链路 6/6（`evidence/m1/e2e-2026-11-03T10-33-10-527Z.json`）、178/178 单测；M2.6 项目同步 WSS 真实链路 **14/14 PASS**（`evidence/m2/project-sync-2026-11-04T01-51-07-111Z.json`）、M1 回归 6/6（`evidence/m1/e2e-2026-11-04T02-19-12-109Z.json`）、190/190 单测；M2.8 文件写入真实链路 **14/14 PASS**（`evidence/m2/file-write-2026-11-05T07-08-10-383Z.json`）、205/205 单测 |
| 8 | 构建发布 | ⬜ 未开始 | 依赖云服务器/域名/TLS/签名证书（未提供） |

## 二、M1-α：全链路打通（本次新增，最重要）

| 项 | 结果 |
|---|---|
| 拓扑 | 手机 App ─HTTPS/WSS 公网→ Java 后端 ←WSS 出站← 电脑 Agent ←stdio JSON-RPC← `dsh --profile acp` |
| 契约 | `docs/design/M1_PROTOCOL.md`（配对码 `824613`、信封、13+ 事件、错误码、关闭码 4401/4409） |
| 后端 | `backend/`（Spring Boot 3.5.16 + Java 21）：`/api/v1/health`、`/api/v1/auth/pair`、`/ws`；单 agent 顶号、多 app 广播；内存态 |
| Agent | `agent/src/relay/` + `scripts/serve.ts`：心跳 30s、指数退避重连、队列 100、审批转发、路径越界拒绝、脱敏 |
| 手机 | `app/lib/services/` + `live_store.dart` + `connect_screen.dart`：真实/演示双模式，审批自动弹 ApprovalSheet |
| 公网 | Cloudflare Quick Tunnel（`tools/bin/cloudflared.exe` 2026.10.7）→ `https://<公网隧道>.trycloudflare.com`；Agent 永远出站，无需公网 IP |
| 自动化 E2E | 本机 **6/6**、公网隧道 **6/6**（设备在线/建会话/真实 prompt/取消/审批批准/审批拒绝） |
| 手机人工验证 | 连接 → 发指令 → 真实回复（工作区 `agent\.m1ws`）→ 审批弹层 → 点「允许一次」→ 电脑真实生成 `m1-phone-ok.txt`（内容 `phone-ok`） |
| 截图 | `docs/mobile/screenshots/09_live_connected.png` … `13_live_result.png` |
| 报告 | `docs/research/M1_E2E_REPORT.md`（含启动三件套、一键脚本、已知限制、M1.1 清单） |
| 一键脚本 | `tools/m1-up.ps1`（后端+隧道+Agent+可选模拟器，自动解析隧道 URL、写 `.m1-state\state.json`）与 `tools/m1-down.ps1`；已实测：拉起后经隧道 `m1-client` **4/4 PASS**，关闭后 8080/cloudflared/模拟器均释放 |

**启动三件套**（详见 M1 报告 §4.1）：① `gradle bootRun` 起后端 ② `cloudflared tunnel --url http://127.0.0.1:8080` 起隧道 ③ `node scripts/serve.ts` 起 Agent；手机填隧道地址 + 配对码。日常用一键脚本即可（§4.2）。

## 三、M1.1：持久化、历史与真实任务页（本次新增）

| 项 | 结果 |
|---|---|
| 数据库 | PostgreSQL 16.10 便携版（`C:\Users\user\dsh-tools\pgsql`，端口 5433，库 `deepseek_remote`）；Flyway v1 核心六表 + v2 种子用户，当前版本 2 |
| 落库 | `PersistenceService` 单线程 FIFO 异步落库，失败只 WARN 不影响转发；`thinking` 不落库；completed 时聚合 assistant 消息（≤8000 字）；`approval.decide` 写 `audit_logs` |
| 历史 REST | `GET /api/v1/conversations`、`/conversations/{id}/messages?afterSeq=`、`/tasks`、`/tasks/{id}`（events 时间线），Bearer 鉴权 |
| 手机端 | 历史会话弹层（时钟图标）、进入会话按 `afterSeq` 回填、实时事件按 `seq` 去重、断线按 `lastSeq` 增量补齐；任务中心/详情接真实数据；工具调用输出结构化（命令/状态/耗时/可折叠输出）；项目页真实 `workspaceRoots` |
| 验证（数据库） | users=1、devices=1、conversations=8、messages=61（无 thinking 行）、tasks=15、audit=6（approved×3/denied×3） |
| 验证（E2E） | `m1-client` **6/6 PASS ×3**（M1.1 前 / 重启后端后 / Lead 回归），证据 `docs/research/evidence/m1/e2e-2026-11-02T05-*.json` |
| 验证（P-1） | 杀后端 → 重启 → 重新 pair：会话/消息/任务仍在，REST 与 psql 一致 → **重启不丢历史** |
| 验证（手机） | `flutter test` **95/95**（原 68 + 新 27）；`flutter build apk --debug` 成功（158.1 MB）；真实 REST 联调无契约偏差 |
| 一键脚本 | `m1-up.ps1` 已支持自动拉起 PostgreSQL（`-SkipDb` 可跳过，`-PgPort=5433`）；`m1-down.ps1` 默认保库，`-StopDb` 连库停 |
| 报告 | `docs/research/M1_1_REPORT.md`；契约 `docs/design/M1_1_DELTA.md` |
| 遗留 | ~~token 仍在内存~~（M2 已解决）、app deviceId 仍 `dev_N`、task events 由消息派生、~~health 版本号 `0.1.0-m1`~~（M2 已改 0.1.1-m2）、M1.1 UI 截图因模拟器环境不稳未补拍 |

## 三·五、M2-α：审批通知、后台保活、token 持久化（本次新增）

| 项 | 结果 |
|---|---|
| 契约 | `docs/design/M2_DELTA.md`（auth_tokens 表、两个通知渠道、M2-A1..A6） |
| 后端 token 持久化 | `V3__auth_tokens.sql` + `TokenStore` 库优先+1s 缓存（sha256 入库、不存明文、异步刷 last_seen_at）；TTL env `M1_TOKEN_TTL_DAYS` 默认 30 天；health **0.1.1-m2** |
| **M2-A4 实测** | pair → 杀后端重启 → **旧 token `GET /conversations` 仍 200**（Lead 复核证据 `docs/research/evidence/m2/m2-a4-lead-check.json`）；Agent 进程未重启即恢复 `agentOnline=true` |
| 手机端通知 | Kotlin 原生桥：`approval_alerts`(HIGH)/`connection_status`(LOW)、审批 tag=approvalId、冷/热启动点击跳转、前台服务（dataSync）；Manifest 权限齐全；零新增 pub 依赖 |
| 手机端逻辑 | 后台才发审批通知（前台仍弹层）；解决/超时/断开取消通知；连接成功启动前台服务+请求通知权限；REST 401/WSS 4401 自动重配对并重连一次 |
| 验证 | `flutter test` **111/111**（M2 新增 16）；`flutter build apk --debug` 成功（158.1 MB）；`gradle build -x test` 成功；`m1-client` **6/6 PASS** |
| 未实测 | 真机通知点击与前台服务存活（本机模拟器被环境回收、`adb devices` 无设备）→ 按 M2_REPORT §7 真机补测一次即可闭环 |
| 遗留 | 不做厂商离线推送、通知内不能直接批准、审批等待仍占该会话执行槽、过期 token 仅在 pair 时清理、M1 旧 token 需升级后重连一次 |
| 报告 | `docs/research/M2_REPORT.md` |

## 三·六、M2.1：可补偿事件、断线演练、执行中排队（本次新增）

| 项 | 结果 |
|---|---|
| 契约 | `docs/design/M2_1_DELTA.md` v1.0（会话级统一 seq、task_events、补拉端点、排队降级；M2.1-A1..A4） |
| 事件表 | `V4__task_events.sql`：`task_events`（ULID 主键、UNIQUE(conversation_id,seq)、双索引）+ `conversations.next_seq` + 存量消息回填 `type='backfill'`（端点不返回） |
| 统一 seq | `RelayHub` 转发前原子分配 seq，信封 `payload.seq`+根 `seq` 与 `task_events` 行同值；`prompt.send` 先取号再落消息；工具/assistant 消息复用事件 seq；thinking 只落事件表；无 App 在线也落库 |
| 补拉端点 | `GET /api/v1/conversations/{id}/events?afterSeq=&limit=`（默认 200/上限 500、seq ASC、nextSeq；afterSeq<0→400、未知会话→404、backfill 不返回）；`/tasks/{id}` 时间线改读 `task_events` |
| **M2.1-A3 断线演练** | **PASS**：断流前 2 条（lastSeq=3）→ 断流 60s → 重连补回 **7 条 seq 4..10**，合并 **9/9 seq 唯一**，**任务终态由补拉恢复**；证据 `docs/research/evidence/m2/catchup-2026-11-02T07-44-27-621Z.json` |
| 数据库不变式 | no_hole_bad=0（每会话 seq 无空洞且 min=1）、msg_without_event_bad=0、event_vs_nextseq_bad=0、thinking_messages_bad=0、payload.seq 不一致=0；库终态 conversations=18 / messages=190 / tasks=49 / task_events=337（backfill 99）/ audit_logs=18 |
| 手机端 | `live_store.dart` lastSeq + `_applyFrame`（seq 去重排序）+ `catchUpEvents()`（重连/回前台/进会话）+ 深度 1 排队（终态自动发、可移除）；`history_api.dart` 增 `events()`；`chat_items.dart` 排队气泡；`assistant_screen.dart` 同步中/失败重试条 |
| 验证 | `flutter test` **124/124**（M2.1 新增 13）；`flutter build apk --debug` 成功（158.1 MB，15:23:55）；`m1-client` **6/6 PASS**（证据 `evidence/m2/m1-client-6of6-2026-11-02T07-45-57-297Z.json`） |
| 演练工具 | `node tools/m2-catchup-test.ts --base http://127.0.0.1:8080 --drop-ms 60000` |
| 遗留 | health 版本号未 bump（仍 0.1.1-m2）、backfill 不回传、排队仅内存、真机 UI 截图未补拍、device.status/error 不入事件表 |
| 报告 | `docs/research/M2_1_REPORT.md` |

## 三·七、M2.2：手机端手感对齐 A 档（本次新增）

| 项 | 结果 |
|---|---|
| 契约 | `docs/design/M2_2_DELTA.md` v1.0（A1 折叠 / A2 立即发送 / A3 6 主题 / A4 分享卡 / A5 长按菜单 / A6 测试；A6 要求 ≥12 测试） |
| A1 完成自动折叠 | `widgets/turn_fold.dart` 的 `groupTurnMessages` 只折叠终态且 `toolCount>0` 的连续 thinking/toolCall/toolResult；`TurnSummaryCard` 显示「已完成 N 步 · 用时 Xs」（失败红/取消橙黄），点击展开；最终回复与执行中不折叠 |
| A2 排队立即发送 | `live_store.dart`：ACP 无 steer → `task.cancel` → 等终态或 `interruptTimeout`(3s) 超时 → 把排队消息作为新 prompt 发出；`_interruptInFlight` 防重；气泡按钮「立即发送 → 正在打断…」 |
| A3 6 套主题 | `AppPalette`（深海蓝/墨黑/暖沙/森林/樱粉/紫夜）+ `ThemeExtension` + `buildAppTheme(id)`；「我的 → 外观」即时切换；Kotlin `deepseek_remote/settings` + SharedPreferences 持久化（`app_theme_id`） |
| A4 分享卡 | `share_card.dart` 最近一轮 QA（脱敏）→ 1080 宽 PNG；`deepseek_remote/share` → `ShareBridge` 写 `cacheDir/share/`，自实现 `ShareFileProvider`（零 androidx）+ `ACTION_SEND`；空对话置灰 |
| A5 长按菜单 | 复制全文 / 重新发送（填入输入框）/ 复制工具输出 |
| 验证 | `flutter test` **143/143**（M2.2 新增 19，既有 124 零回归，Lead 独立复跑 exit 0）；`flutter build apk --debug` 成功（**150.8 MB / 150,797,767 字节**，`aapt dump badging` → `versionName=0.1.3-m2.2`、`versionCode=4`）；APK 已交付根目录 `DeepSeek Remote AI 手机端 v0.1.3-m2.2.apk` |
| 约束 | 零新增 pub 依赖；只改 `app/` 与 `docs/mobile/README.md`；未跑 flutter analyze（中文路径崩溃，沿用 test/build 门禁） |
| 遗留 | 真机未实测（分享面板/主题观感/折叠动画）、仅深色 6 套、`TaskStatus` 等 const 枚举色未全量 token 化、「立即发送」本质是打断 + 改说 |
| 报告 | `docs/research/M2_2_REPORT.md` |

## 三·八、M2.3：视觉重构（本次新增）

用户反馈「UI 太难看」后，按用户选定的方向（**A 的配色 + B 的排版、浅色为主、跟随系统自动切深色**）重做六个页面与全部基础组件。

| 项 | 结果 |
|---|---|
| 契约 | `docs/design/M2_3_UI_DELTA.md` v1.0（颜色 token / 圆角 / 间距字号 / 17 条组件规范 / 六页清单 / A1–A6） |
| 设计系统 | `app/lib/theme/app_theme.dart`（446 行）：浅/深双 `AppPalette`（浅底 `#F6F7F9`、卡片 `#FFFFFF`、主色 `#2563EB`；深底 `#0B1220`、卡片 `#121A2A`、主色 `#5B8DEF`）、`AppRadius`（卡片 20 / 气泡 22·22·8 / 代码 12 / 胶囊 999）、`AppSpace`、`cardShadow`/`accentShadow`、`buildAppTheme(Brightness)` |
| 外观三选 | `AppThemeMode(system/light/dark)` + `storageKey=app_theme_mode`，经 Kotlin `deepseek_remote/settings`（SharedPreferences）持久化；「我的 → 外观」即时切换 |
| 六页重做 | 助手（用户蓝气泡/助手无气泡左侧 3px 竖线/折叠工具卡/胶囊输入）、连接（6 格配对码，当前格蓝边浅蓝底）、任务（统计卡/筛选胶囊/进度条）、电脑（权限列表/紧急停止危险卡）、项目（工作区卡/权限胶囊）、我的（渐变头像/审计/外观三选/关于） |
| 导航 | `root_shell.dart` 自定义底栏：白底 94% + 1px 顶线 + 选中圆点，高 78 + SafeArea（不再用 Material `NavigationBar`） |
| 验证 | Lead 独立 `flutter test` **154/154**（exit 0，既有 143 零回归 + 新增 11）、`flutter build apk --debug` 成功；`aapt dump badging` → **`versionName='0.1.4-m2.3' versionCode='5'`**；APK **150,808,223 字节**，SHA256 `752016BE23160D6ACD079C81D436FD19D800CD406E10A4654B14D9226CF28100` |
| 交付 | 根目录 `DeepSeek Remote AI 手机端 v0.1.4-m2.3.apk`；公网 `https://<公网隧道>.trycloudflare.com/DeepSeek-Remote-v0.1.4-m2.3.apk`；局域网 `http://192.168.1.x:8099/DeepSeek-Remote-v0.1.4-m2.3.apk` |
| 遗留 | 本机无真机/可用模拟器，浅/深色实机截图未补拍；深色对比度为 token 计算值；`flutter analyze` 未跑；分享卡配色跟随主题但系统面板未真机实测 |
| 报告 | `docs/research/M2_3_REPORT.md` |

## 三·九、M2.4：删除演示数据 + 界面减法（本次新增）

用户反馈「太繁琐了，把演示数据删了，简洁一点」后的返工：App 内演示模式与全部假数据清零，未连接时六页统一空态，已连接只保留真实内容。

| 项 | 结果 |
|---|---|
| 契约 | `docs/design/M2_4_SIMPLIFY_DELTA.md` v1.0（删除清单 / 六页减法 / 空态组件 / A1–A6） |
| 删除 | `app/lib/data/demo_store.dart` 整文件；`models.dart` 的 `DemoDevice/WorkspaceEntry/AuditEntry`；`common.dart` 的 `DemoBadge/StoreScope/ModeBadge`；`app.dart` 的 DemoStore/StoreScope；五页 DemoStore 参数；假设备/假会话/假任务/假工作区/假审计/假配对码 `824613`/演示徽标/快捷 chips/统计三卡/权限长列表/演示账号 |
| 新增 | `app/lib/widgets/empty_state.dart`（图标 + 标题 + 一句说明 + 主按钮，五页复用） |
| 六页 | 未连接：统一「连接空态」，点按钮进连接页；已连接：助手一行状态条（圆点+设备名+已连接+会话切换+分享）+ 消息流；任务筛选胶囊+任务卡（无统计三卡）；电脑设备卡+权限摘要弹层+紧急停止；项目只读真实 `workspaceRoots`；我的账号+连接状态+外观+关于；连接页两字段+两按钮+一行步骤 |
| 验证 | `grep -ri "演示" app/lib` **= 0**；Lead 独立 `flutter test` **164/164**（exit 0，既有 154 零回归 + M2.4 新增 10）；真实链路 `m1-client` **6/6 PASS**（`evidence/m1/e2e-2026-11-03T09-24-31-458Z.json`）；`aapt` → **`versionName='0.1.5-m2.4' versionCode='6'`** |
| 交付 | 根目录 `DeepSeek Remote AI 手机端 v0.1.5-m2.4.apk`（**150,758,731 字节**，SHA256 `4BECB7D9…BDC945A`）；公网 `https://<公网隧道>.trycloudflare.com/DeepSeek-Remote-v0.1.5-m2.4.apk`；局域网 `http://192.168.1.x:8099/DeepSeek-Remote-v0.1.5-m2.4.apk` |
| 遗留 | 本机无真机/可用模拟器，空态与已连接界面截图待补拍；未连接时无法体验页面功能（用户要求，预期行为）；项目页文件浏览属 B 档；`flutter analyze` 仍未跑 |
| 报告 | `docs/research/M2_4_REPORT.md` |

## 三·十、M2.5：应用内在线更新（本次新增）

用户问「能不能在线更新」→ 手机端可直接检查更新、下载并调起系统安装器；后端提供版本与 APK 下载接口。**不做静默安装**（Android 平台限制，最后一步由系统安装器确认）。

| 项 | 结果 |
|---|---|
| 契约 | `docs/design/M2_5_UPDATE_DELTA.md` v1.0（后端两接口 / 手机端 A1–A6 / 首次手动装例外） |
| 后端 | `api/AppUpdateController.java`（216 行）：`GET /api/v1/app/version`（无需 Bearer，versionCode/versionName/size/sha256/notes/url/publishedAt）、`GET|HEAD /api/v1/app/apk`（`FileSystemResource` 流式、`application/vnd.android.package-archive`、`Content-Length`）；`application.properties` 新增 `app.update.enabled/apk-path/version-code/version-name/notes`；固定读 `dist/DeepSeek-Remote-latest.apk`，sha256 按 mtime+size 自动重算；缺失返回 404 `APP_UPDATE_UNAVAILABLE` |
| 手机端 | `services/update_service.dart`（检查/流式下载 `.part`→size 校验→rename、进度回调）；`services/update_gateway.dart` + Kotlin `UpdateBridge.kt`（缓存目录 / canInstallPackages / 打开未知来源设置 / content:// + ACTION_VIEW 调安装器）；`ShareFileProvider.kt` 增加 `updates` 目录与 `.apk` MIME；`widgets/update_check_tile.dart`（我的→关于→检查更新：已最新提示 / 新版本弹窗 / 进度框 / 去设置 / 调安装器）；`app_version.dart` + `pubspec 0.1.6+7` + `local.properties 0.1.6/7` + `build.gradle.kts versionName="0.1.6-m2.5"` |
| 测试 | 新增 `update_service_test.dart` 12 项 + `update_check_tile_test.dart` 3 项；Lead 独立 `flutter test` **178/178**（exit 0，既有 164 零回归） |
| 接口实测 | 本地 `GET /version` 200 JSON、`HEAD /apk` 200 / 150,782,707 字节；公网隧道同 JSON 与 HEAD 200；8080 主服务已重启（pid 28512），health `agentOnline=true`；sha256 接口值与文件一致 |
| 回归 | 真实链路 `node tools/m1-client.ts` → **6/6 PASS**（`evidence/m1/e2e-2026-11-03T10-33-10-527Z.json`） |
| 构建/版本 | APK **150,782,707 字节**，`aapt` → **`versionName='0.1.6-m2.5' versionCode='7'`**，SHA256 `349D7C8B…C4781B1` |
| 交付 | 根目录 `DeepSeek Remote AI 手机端 v0.1.6-m2.5.apk`；`dist/DeepSeek-Remote-latest.apk`（后端更新源）；公网 `https://<公网隧道>.trycloudflare.com/DeepSeek-Remote-v0.1.6-m2.5.apk`；局域网 `http://192.168.1.x:8099/DeepSeek-Remote-v0.1.6-m2.5.apk` |
| 遗留 | 首次需手动装 0.1.6（0.1.5 无更新模块）；不能静默安装；下载后仅按 size 校验（sha256 待接入逐块校验）；debug 签名需前后一致；本机无真机，安装器跳转仅编译+单测级验证，需真机点一次 |
| 报告 | `docs/research/M2_5_REPORT.md` |

## 三·十一、M2.6：项目同步（本次新增）

用户「可以同步电脑此时做的项目，并且可以在手机上操作」→ 手机端现在能看电脑上这个项目的**真实磁盘目录**，并在任意目录里发指令让 Harness 在该目录执行。**只读浏览 + 指令执行**，不做手机端写文件（写入仍走 AI 指令 + 审批）。

| 项 | 结果 |
|---|---|
| 契约 | `docs/design/M2_6_PROJECT_SYNC_DELTA.md` v1.0（WSS `workspace.list`/`file.read` 请求-响应、错误码、限制、手机端 A1–A6） |
| Agent | 新增 `agent/src/relay/workspace-fs.ts`（路径校验/忽略目录/500 条上限/256 KiB 预览/1 MiB 硬上限/二进制与 sha256）；`relay-agent.ts` 新增 `handleWorkspaceList`/`handleFileRead`/`sendWorkspaceError`，capabilities 上报 `workspaceList/fileRead=true`；`protocol.ts` 补 `workspaceList?: boolean`；单测 `agent/tests/unit/workspace-fs.test.ts` **9/9 PASS** |
| 后端 | `RelayHub.java`：`APP_FORWARD_TYPES` 增加 `workspace.list`/`file.read`（离线 `DEVICE_OFFLINE`），`AGENT_BROADCAST_TYPES` 增加两个 `.result`；结果只广播、**不分配 seq、不写 task_events** |
| 手机端 | `services/workspace_models.dart`；`live_store.dart` 增加 `workspaceRoots`/`listDirectory`/`readWorkspaceFile`/`setPendingWorkspace`（requestId→Completer、20s 超时、断线失败清理、`createConversation` 带 workspacePath）；`projects_screen.dart` 重写、新增 `project_browser_screen.dart`（面包屑/上级/刷新/重试）与 `file_viewer_screen.dart`（等宽/行号/复制/sha256/截断提示）；`assistant_screen.dart` 工作区胶囊；版本 `0.1.7+8` / `versionName=0.1.7-m2.6` |
| 真实链路验证 | `node tools/verify-project-sync.ts` → **14/14 PASS**（`evidence/m2/project-sync-2026-11-04T01-51-07-111Z.json`）：`workspaceRoots=["<项目根>"]`、根目录 19 条目录在前、子目录前缀、`README.md` 40,020 B + sha256、`FILE_NOT_FOUND`/`PATH_NOT_ALLOWED`、A4 绑定 `docs/research` 后 Harness 输出 `当前工作目录：<项目根>\docs\research` 且 `state=completed` |
| 测试/构建 | Lead 独立 `flutter test` **190/190**（exit 0，新增 12 项 + 既有 178 零回归）；`aapt` → **`versionName='0.1.7-m2.6' versionCode='8'`**；APK **150,820,399 字节**，SHA256 `9B1661E1…A27150177` |
| 回归 | `node tools/m1-client.ts` → **6/6 PASS**（`evidence/m1/e2e-2026-11-04T02-19-12-109Z.json`） |
| 交付 | 根目录 `DeepSeek Remote AI 手机端 v0.1.7-m2.6.apk`；`dist/DeepSeek-Remote-latest.apk` 换新；后端 `app.update.version-code=8`/`version-name=0.1.7-m2.6` 已生效（`GET /api/v1/app/version` 本地+公网返回 8，`HEAD /apk` 200/150,820,399） |
| 遗留 | 手机端**只读**；二进制/超大不可预览；忽略目录不展示；不镜像桌面 GUI 会话（同目录同一份文件，但 ACP 是独立会话）；无真机，页面验证为单测+构建级；文件浏览性能仅小目录实测 |
| 报告 | `docs/research/M2_6_REPORT.md` |

### M2.6.1 多授权根（2026-11-04 补充）

用户「为什么不能同步所有项目，我想做成电脑与手机同步的」→ Agent 支持**同时授权多个根目录**，手机「项目」页一次列出全部授权目录。

| 项 | 结果 |
|---|---|
| 协议/实现 | `M1_WORKSPACE_ROOTS`（分号/换行分隔）优先于 `M1_WORKSPACE_ROOT`，**第一个为默认工作区**；`device.status.workspaceRoots` 返回全部根；`workspace.list`/`file.read`/`conversation.create` 路径校验改为「落在任一授权根内」（否则 `PATH_NOT_ALLOWED`）；`agent/src/relay/workspace-fs.ts` 的 `resolveWorkspacePath` 接受 `string[]` |
| 当前配置 | `D:\Projects` + `C:\Users\user\Desktop` |
| 工具 | `tools/m1-up.ps1` 新增 `-WorkspaceRoots 'D:\根A;C:\根B'`（单根 `-WorkspaceRoot` 仍可用）；新增 `tools/verify-multi-root.ts` 多根验证脚本 |
| 验证 | 真实链路 **6/6 PASS**（`evidence/m2/multi-root-2026-11-04T06-40-41-094Z.json`：两棵根均可列目录、Desktop 29 项、`C:\Windows\Temp` 被拒）；`workspace-fs` 单测 **10/10**；M1 回归 **4/4**（`evidence/m1/e2e-2026-11-04T06-42-03-904Z.json`） |
| 手机端 | 无需改代码：`projects_screen.dart` 已按 `workspaceRoots` 列表渲染多个根 |
| 遗留 | 仍是白名单根内（非整机任意路径）；文件只读；不镜像桌面 GUI 会话 |

## 四、M0.5：手机 App 演示版

| 项 | 结果 |
|---|---|
| 产物 | `app/`（Flutter 3.47.9，Material 3 深色主题） |
| 页面 | AI 助手 / 任务中心（含任务详情时间线）/ 电脑控制（配对、6 级权限、紧急停止）/ 项目管理（工作区授权）/ 个人中心（审计日志） |
| 关键交互 | 高风险授权底部弹层（原始命令 + 10:00 倒计时自动拒绝）、拖动式紧急停止、7 状态任务徽标、思考过程折叠、工具调用步骤 |
| 验证 | 演示模式截图 8 张（01–08）；M1 真实链路截图 5 张（09–13）；`flutter test` **68/68 通过** |
| 文档 | `docs/mobile/README.md`、`docs/mobile/screenshots/` |
| 下一步 | M1.1 把任务/项目页接真实数据，替换演示 Store 剩余部分 |

## 五、M0 里程碑（已完成）

交付内容：`agent/` —— 可运行、可测试的 Harness ACP 适配内核（Node 24 + TypeScript，零运行时依赖，无构建步骤）。

| 验证层 | 结果 | 证据 |
|---|---|---|
| 单元测试 | **36/36 通过**（158ms） | `node --test tests/unit/*.test.ts` |
| 合同测试（真实 Harness） | **9/9 通过**（28.3s） | `agent/evidence/contract-2026-10-31T04-27-46-505Z.jsonl` |
| 端到端冒烟（真实任务） | **5/5 通过**（20s） | `agent/evidence/e2e-2026-10-31T04-28-48-670Z.json` |

跑通的能力：连接 Harness（v0.2.1-rc.5）→ 真实对话/工具执行 → 工作区外写入触发审批（批准执行 / 拒绝不执行）→ 执行中取消（`native`、Harness 明确确认）→ 断线后 `session/resume` 恢复上下文。**能力矩阵诚实上报**：暂停/文件/终端为 `false`，不伪造。

## 六、当前阻塞与待用户决策

### 6.1 待拍板（影响 M1.1 之后的范围与体验，详见构思方案第 7 章）

| 编号 | 决策 | 推荐 | 影响 |
|---|---|---|---|
| D-1 | 部署形态（通信形态已定：只有云中继） | 后端先自托管在自己 PC/NAS + Tailscale，上线迁云 | 影响 M1 联调需要什么资源 |
| D-2 | 云服务器/域名由谁提供 | 用户提供或授权采购 | 阻塞阶段 7–8 |
| D-3 | iOS 交付 | 只交源码 + 构建说明 | 只能先出 Android APK |
| D-4 | 远程桌面范围 | 先 L1（看一眼），L2 后置 | 影响 M4 范围 |
| D-5 | APK 侧载 | 接受 | 影响发布方式 |
| **D-6** | 实时输出口径 | **步骤级实时**（不承诺 token 级） | **建议优先确认**，M0 再次证明 ACP 是提交点粒度 |
| **D-7** | 验收第 14 项「授权后控制电脑」是否纳入 1.0 | 纳入 1.0（+3–4 人日，总 87–88） | **影响验收与排期** |
| **D-8** | 审批通知方案 | 前台服务 + 本地通知（B，1–2 人日） | **不做会卡死长审批**；M1 手机端实测审批弹层可正常收到，但锁屏/后台场景未解决 |
| D-9 | 离线指令语义 | 离线禁止发送，只允许取消排队 | 影响手机端交互 |

### 6.2 环境缺口（不阻塞 M1-α，阻塞后续阶段）

| 缺口 | 等级 | 处理 |
|---|---|---|
| Flutter SDK | ✅ 已解决 | 3.47.9 stable 已装到 `C:\Users\user\dsh-tools\flutter`，APK 已构建并跑通（未加入系统 PATH，脚本里显式设置） |
| Gradle / cloudflared | ✅ 已解决 | Gradle 8.14.3 在 `C:\Users\user\dsh-tools\gradle`；cloudflared 2026.10.7 在 `tools/bin/` |
| PostgreSQL 16 | ✅ 已解决 | 16.10 便携版已装到 `C:\Users\user\dsh-tools\pgsql`，数据目录 `pgdata-deepseek`，端口 5433；`m1-up.ps1` 自动拉起 |
| 云服务器/域名/TLS/安卓签名证书 | P1 | 阶段 7–8 前置；当前用 Cloudflare 临时隧道顶替 |
| Android 真机 | P2 | 可用现有 AVD 先跑 |
| 工作区 ACL（Win32 5） | 已解决 | `npm run acl:fix`（安装器需固化，见 M0 报告 §5.2） |
| 中文路径导致的构建坑 | 已绕过 | `flutter analyze` 在本项目路径下崩溃（跳过，改用 `flutter test`/`build` 校验）；Gradle 需 `android.overridePathCheck=true`；Gradle Wrapper 已指向腾讯云镜像 |

## 七、已交付文档与证据

| 类别 | 产物 |
|---|---|
| 构思方案 | `DeepSeek Remote AI 项目构思方案 v0.2.docx`（34 页）+ `docs/concept/项目构思方案_v0.2.md` + 架构图 + 界面图 |
| 详细设计 | `docs/design/` 5 份分册（PROTOCOL / DATA_MODEL / REMOTE_AGENT / MOBILE_UI / MVP_AND_ROADMAP）+ 契约 `M1_PROTOCOL.md`、`M1_1_DELTA.md`、`M2_DELTA.md`、`M2_1_DELTA.md`、`M2_2_DELTA.md`、`M2_3_UI_DELTA.md`、`M2_4_SIMPLIFY_DELTA.md`、`M2_5_UPDATE_DELTA.md`、`M2_6_PROJECT_SYNC_DELTA.md` + `mockups/`（ui_a/ui_b 效果图） |
| 调研/交付报告 | `docs/research/`: `ENVIRONMENT_REPORT.md`、`HARNESS_INTERFACES.md`、`M0_FEASIBILITY.md`、`M1_E2E_REPORT.md`、`M1_1_REPORT.md`、`M2_REPORT.md`、`M2_1_REPORT.md`、`M2_2_REPORT.md`、`M2_3_REPORT.md`、`M2_4_REPORT.md`、`M2_5_REPORT.md`、**`M2_6_REPORT.md`（本次新增）** |
| 独立审核 | `docs/review/REVIEW_REPORT.md`（76/100 有条件通过，3 P0 / 12 P1 / 18 P2） |
| 代码 | `agent/`（ACP 内核 + relay 层 + 工作区只读文件系统）、`backend/`（Spring Boot 中继 + PostgreSQL 持久化 + 事件表 + 更新接口）、`app/`（Flutter 单真实模式 + 应用内更新 + 项目浏览）、`tools/`（E2E 客户端、断线演练、项目同步验证、隧道、构建流水线） |
| 手机端 | `docs/mobile/README.md` + 13 张截图（01–08 演示历史 / 09–13 真实链路）+ `DeepSeek Remote AI 手机端 v0.1.7-m2.6.apk` |
| 证据 | `agent/evidence/`、`docs/research/evidence/m1/`（本机+公网 E2E、手机审批）、`docs/research/evidence/m2/`（token 持久化、断线补拉、工作区切换、项目同步 14/14） |

## 八、下一步（M3 → …）

**M2.2 ✅ 已完成（2026-11-03）**：完成轮折叠 + 排队「立即发送」+ 6 套主题持久化 + 分享卡 + 长按菜单；`flutter test` 143/143、APK 150.8 MB（安装器显示 v0.1.3-m2.2）；详见 §三·七 与 `docs/research/M2_2_REPORT.md`。

**M2.3 ✅ 已完成（2026-11-03）**：视觉重构（冷白极简 + 浅/深色跟随系统 + 外观三选），六页与全部组件重做；`flutter test` 154/154、APK 150,808,223 字节（安装器显示 **v0.1.4-m2.3**、versionCode 5）；详见 §三·八 与 `docs/research/M2_3_REPORT.md`。

**M2.4 ✅ 已完成（2026-11-03）**：删除全部演示数据（`demo_store.dart` 与假设备/假会话/假任务/假工作区/假审计/假配对码/演示徽标），未连接时六页统一连接空态，已连接只留真实内容；`flutter test` **164/164**、真实链路 6/6、APK **150,758,731 字节**（**v0.1.5-m2.4**、versionCode 6）；详见 §三·九 与 `docs/research/M2_4_REPORT.md`。

**M2.5 ✅ 已完成（2026-11-03）**：应用内在线更新——手机端「我的→关于→检查更新」→ 新版本弹窗 → 下载进度 → 系统安装器；后端 `GET /api/v1/app/version` + `GET|HEAD /api/v1/app/apk`（读 `dist/DeepSeek-Remote-latest.apk`）；`flutter test` **178/178**、真实链路 6/6、APK **150,782,707 字节**（**v0.1.6-m2.5**、versionCode 7）；首次需手动装 0.1.6，之后可应用内更新。详见 §三·十 与 `docs/research/M2_5_REPORT.md`。

**M2.6 ✅ 已完成（2026-11-04）**：项目同步——Agent 工作区切到 `<项目根>`，手机「项目」页可浏览真实目录、只读预览文件、在指定目录发指令；WSS 新增 `workspace.list`/`file.read`（不占 seq）；真实链路 **14/14 PASS**、Agent 单测 9/9、`flutter test` **190/190**、M1 回归 6/6、APK **150,820,399 字节**（**v0.1.7-m2.6**、versionCode 8），应用内更新已指向 0.1.7。详见 §三·十一 与 `docs/research/M2_6_REPORT.md`。

**M3 候选（按建议优先级）**
1. **真机验收**：装 `v0.1.7-m2.6.apk` → 项目页浏览 `docs/` → 打开 `README.md` → 「在此目录发指令」→ 看 AI 助手工作区胶囊与实际执行目录；再走一次「我的→关于→检查更新」（应提示已是最新）；截图反馈逐页微调（本机模拟器被环境回收，`adb devices` 常为空）。
2. **审批等待与执行槽解耦**：当前审批等待占用该会话执行槽（全局并发 2），评估是否允许其它会话并发 / 审批期间释放槽的降级策略。
3. ~~手机端写文件（带审批的 `file.write`）~~（**M2.8 已交付**）；剩余：文件搜索/最近打开、代码高亮。
4. 多设备/账号、`devices.operating_system` 上报、app deviceId 稳定为 26 位 ULID、`audit_logs` 月分区。
5. 远程桌面 L1（只读看一眼，ffmpeg + H.264，2–3Mbps）、签名 APK / Agent Windows 安装包。
6. 云服务器/域名/TLS 采购（阶段 7–8 前置）与 18 项验收正式测试记录。

## 八·五、M2.7：插件直连（本次新增，免三件套）

| 项 | 结果 |
|---|---|
| 动机 | 原来手机要连电脑得起三样：Spring Boot 后端 + cloudflared 隧道 + 手工 `serve.ts`。改成在 Harness 里装一个 DSH 插件，装完即用、跟着 Harness 启停 |
| 产物 | `dsh-plugin-m1@0.1.0`（`dsh-plugin-m1/`，已装进 desktop profile 并启用）；设计文档 `docs/design/PLUGIN_DIRECT.md` |
| 拓扑 | 手机 App ─HTTP/WS :8787→ 插件（M1 中继 + 配网页 + 二维码）─spawn→ 内置 `agent/scripts/serve.ts` ─stdio→ `dsh --profile acp` |
| 契约 | 原样复刻后端：`GET /api/v1/health`、`POST /api/v1/auth/pair`、`/ws?role=&token=`；hub 路由/seq/忙闲/4401/4409 与 `RelayHub` 一致，**App 协议零改动** |
| 配网页 | `http://127.0.0.1:8787/` 深色页面：二维码（内容 `http://<ip>:8787#c=<匹配码>`）+ 局域网地址 + 6 位匹配码 +「换一个」 |
| 验收 | 中继自测 **24/24**、M1 E2E **6/6 PASS**（`evidence/m1/e2e-2026-11-04T09-37-16-838Z.json`：建会话 109ms、真实 prompt 1282ms、取消 2243ms、审批批准 6564ms、审批拒绝 7181ms）、二维码解码校验通过 |
| 修掉的坑 | ① 默认授权根误用 `process.cwd()` → `PATH_NOT_ALLOWED`，改为接 `workspaceRegistry`；② hub 自造 conversationId 与 Agent 回传的 ACP sessionId 不一致 → 连环 `CONVERSATION_NOT_FOUND`，改为采纳回传 id + 在线时宽松登记 |
| App 侧 | `normalizeBaseUrl` 现在按主机判断：局域网/回环补 `http://`，公网仍 `https://`（否则 `192.168.x.x:8787` 会被当 https 连不上） |
| 遗留 | App 尚无扫码控件（需引入 `mobile_scanner`）；插件不开公网隧道；装插件时 pnpm 把 `dsh-our-free-model` 2.8.0→2.7.3 |

### M2.7.1 公网隧道 + App 扫码（2026-11-05 补充）

用户「不是要我用别人做的，是你自己适配这段手机端 App 的插件，公网和局域网都能用，手机端也能扫码」→ 补齐两块：插件自带公网隧道、App 内生扫码。

| 项 | 结果 |
|---|---|
| 插件公网 | 新增 `dsh-plugin-m1/lib/tunnel.js`：`resolveCloudflared()`（配置 → `DSH_CLOUDFLARED` → PATH → `~/dsh-tools/cloudflared/`）+ `CloudflaredTunnel`（spawn `cloudflared tunnel --url http://127.0.0.1:8787 --no-autoupdate --protocol http2`，正则抓 `https://*.trycloudflare.com`，退出按 `5s*2^n` 重连 ≤5 次）；`publicAccess`（默认 true）/`publicUrl`（固定域名）/`cloudflaredPath` 三个配置 |
| 安全闸 | 配网页与匹配码只给本机（回环且无 `cf-connecting-ip`）；隧道访问 `/`、`/pair` 只见「请在电脑上打开这个页面」，`/api/v1/pair/info` 返回 `restricted:true` 无地址无码；配对失败按 IP 限流 60s/5 次 → `429 TOO_MANY_ATTEMPTS` |
| 配网页 | 双卡片：局域网码 + 公网码（均为 `地址#c=<匹配码>`），3s 轮询刷新公网地址与隧道状态，显示「中继在线 / 插件版本」 |
| App 扫码 | 新增 `app/lib/services/pairing_link.dart`（解析 `地址#c=码`/`?c=`/`dshremote://`，拒绝非配对码）与 `app/lib/screens/scanner_screen.dart`（`mobile_scanner 7.5.0`，仅 QR，取景框/补光灯/权限降级）；连接页加「扫码连接电脑」卡片，扫完自动回填 + 健康检查 + 建连；粘整串 `地址#c=码` 也会被拆开 |
| 局域网明文 | 新增 `app/android/.../res/xml/network_security_config.xml`（`cleartextTrafficPermitted=true`）+ Manifest `CAMERA` 权限与 `android:networkSecurityConfig` |
| 版本 | App `0.1.8+9` / `versionName=0.1.8-m2.7`；插件源码 `0.2.0`（运行实例待下次重载后显示） |
| 验收 | 公网 M1 E2E **6/6 PASS**（`evidence/m1/e2e-2026-11-05T04-15-05-661Z.json`：建会话 636ms、prompt 1591ms、取消 3455ms、审批批准 6787ms、审批拒绝 7402ms）；App 自有网络层实连 **8/8 PASS**（局域网 `http://127.0.0.1:8787`、公网隧道各一遍，`app/tool/live_pair_check.dart`）；`flutter test` **202/202** |
| 构建 | `dist/DeepSeek-Remote-AI-v0.1.8-m2.7.apk`（68,585,532 字节，versionCode 9，release 用 debug 签名）；中文路径下 AOT 失败 → 拷到 `C:\Users\user\dsh-build\app-remote` 构建后回拷 |
| 遗留 | 快速隧道地址随重启变化（要固定得配 `publicUrl` 命名隧道）；依赖本机 `cloudflared`；`dsh-our-free-model` 仍被 pnpm 降到 2.7.3 |

### M2.7.2 插件即更新源（2026-11-05 补充）

M2.8 交付后，"App 要更新"仍指向 Java 后端。这一步把 `GET /api/v1/app/version` 与 `GET|HEAD /api/v1/app/apk` 搬到插件里 —— 插件装好之后，**对话、审批、看项目、写文件、升级**全部只依赖它一个。

| 项 | 结果 |
|---|---|
| 新增模块 | `dsh-plugin-m1/lib/appupdate.js`：`resolveApkPath()`（配置 → `stateDir/app/` → `appProjectDir/dist/` → `cwd/dist/`）、`readProjectVersion()`（`pubspec.yaml` 的 `version: X+N` 与 `local.properties` 的 `flutter.versionCode` **取版本号较大者**）、`AppUpdate`（`mtime+size` 缓存 sha256、`versionPayload()`、`streamApk()` 支持 HEAD） |
| 路由 | `GET /api/v1/app/version`（无包 404 `APP_UPDATE_UNAVAILABLE`）、`GET\|HEAD /api/v1/app/apk`（`application/vnd.android.package-archive`）；公网隧道同样可用 |
| 配置 | `appApkPath` / `appProjectDir` / `appVersionCode` / `appVersionName` / `appNotes`；默认 `appProjectDir = dirname(bundleRoot)`（profile 里是 junction，Node 解析到真实项目根） |
| 运行实例 | 重载后插件 **v0.2.0**，公网地址每次重载都会变（当前 `https://<公网隧道>.trycloudflare.com`），`/api/v1/app/version` → `versionCode=10 versionName=0.1.9-m2.8 size=68,716,932 sha256=620cb8bf…` |
| 验收 | 中继侧 `node tools/probe-update.mjs` **9/9 PASS**；App 自己的 `UpdateService` 实跑 **PASS**（`app/tool/live_update_check.dart http://127.0.0.1:8787 9`：检查到 0.1.9/code 10 → 下载 68,716,932 字节，与服务器 size 一致）；公网 `version` + `HEAD apk` 均 200 |
| 版本同步（顺手修） | `app/lib/app_version.dart` 与 `app/android/local.properties` 仍是 0.1.8/9（M2.8 只改了 `pubspec.yaml` 与 gradle），App「关于」会显示旧版本、更新比较也用旧码 → 已改成 `10` / `0.1.9-m2.8`，三处断言同步，`flutter test` **205/205 PASS**；APK 已按修正后的源码重打：`dist/DeepSeek-Remote-AI-v0.1.9-m2.8.apk`（68,716,932 字节，sha256 `979f9eb5…`，`aapt` 复核 versionCode 10 / versionName 0.1.9-m2.8） |
| 回归 | 重载后 M1 全链路再跑一遍 **6/6 PASS**（`evidence/m1/e2e-2026-11-05T07-52-22-462Z.json`）；配网页截图 `evidence/m1/pair-page-v020-2026-11-05.png`（插件 v0.2.0、双码、当前隧道地址） |
| 插件管理经验 | `set_plugin(target="include:dsh-plugin-m1")` 报 `unaddressable`、`install_bundle` 重装报 `ambiguous-install` 且会顺带升依赖；**热重载用 `set_bundle(target="dsh-plugin-m1", enabled=false→true)`**，两次都 `applied` |

### M2.8 手机端写文件（2026-11-05 补充）

用户「继续」→ 选择「手机端写文件（新建/编辑/保存，走审批）」：补齐 M2.6「手机端只读」的短板。

| 项 | 结果 |
|---|---|
| 契约 | `docs/design/M2_8_FILE_WRITE_DELTA.md` v1.0；WSS 新增 `file.write` → `file.write.result`，与 `workspace.list`/`file.read` 同为请求-响应（不占 seq、不写 `task_events`）；`device.status.capabilities` 新增 `fileWrite` |
| 双层审批 | ① 手机端每次保存弹确认层：目标路径、新建/覆盖、字节数、行数、± 行数、仅授权工作区提示；② Agent 独立校验，不信任手机：授权根内、忽略目录拒绝、≤512 KiB、含 NUL 视为二进制拒绝、缺失字段 `BAD_REQUEST` |
| 冲突保护 | 打开文件时的 `sha256` 随保存回传 `baseSha256`；与磁盘不符 → `CONFLICT`，App 弹「重新加载 / 强制覆盖 / 取消」；新建撞名 → `FILE_EXISTS`；覆盖要求正确 base 或显式 `force` |
| 原子写 | 先写同目录临时文件 `.<name>.<pid>-<rand>.tmp` 再 `rename`，失败清理临时文件；sha256 按实际写入字节复算返回 |
| App | 文件页新增「编辑并保存」→ 全屏等宽编辑器（状态条 新建/已修改/与电脑一致、行数、离开确认、CRLF+BOM 保存时还原、截断文件只读）；项目页新增「新建文件」→ 文件名/子路径校验 → 编辑器；保存成功回退并刷新列表 |
| Agent | `workspace-fs.ts` 新增 `writeTextFile()`/`MAX_WRITE_BYTES`；`relay-agent.ts` 新增 `handleFileWrite`；单测 **20/20**（新增 10 项：新建、无 base 撞名、正确/陈旧 base、被删文件、force、越权、父目录缺失/`..` 逃逸、目标是目录、超限与二进制且无临时残留） |
| 中继 | 插件 `lib/hub.js` 与 Java `RelayHub` 白名单各加 `file.write`/`file.write.result`；顺手修掉插件握手用骨架 `device.status` 覆盖 `workspaceRoots` 的问题（缓存并重放 Agent 完整状态），否则手机项目页会变空 |
| 验收 | 真实链路 `tools/verify-file-write.ts` **14/14 PASS**（新建→sha/磁盘/回读→撞名→陈旧 base 冲突且磁盘未变→正确 base 覆盖→`../` 越界拒绝；`evidence/m2/file-write-2026-11-05T07-08-10-383Z.json`）；`flutter test` **205/205**；插件 0.2.0 已生效（`health.version`） |
| 构建 | `dist/DeepSeek-Remote-AI-v0.1.9-m2.8.apk`（68,716,932 字节，versionCode 10，`versionName=0.1.9-m2.8`）；`DeepSeek-Remote-latest.apk` 同步替换 |
| 遗留 | 超 1 MiB 或已截断的文件不开放编辑；编辑器无撤销/重做、无语法高亮；未做删除/重命名/移动；写入仍限文本 |

### M2.9 Kimi 风格重构（2026-11-09 补充）

用户发来两张真实 Kimi 截图，要求「做成他那样的风格」。按截图重做首页与导航，不改功能与链路。

| 项 | 结果 |
|---|---|
| 首页 | 去掉 AppBar 与底部导航：顶栏改为 圆形菜单 + 中间设备胶囊（状态点 + 设备名 + 展开）+ 历史/分享圆钮；中间品牌标记（蓝紫渐变圆 + 两只眼睛）+「嗨，今天要和 DeepSeek 一起做点什么」+ 已连接胶囊 |
| 输入条 | 上方一排快捷胶囊（全部项目 / 总结这次改动 / 跑通构建和测试）；输入条为大圆角白胶囊（描边 + 轻阴影），左侧「+」打开底部菜单（全部项目/任务中心/连接设置），右侧发送钮空输入置灰、有字变强调色；下方「内容由 AI 生成」小字 |
| 抽屉 | 86% 宽、右上下圆角；头部品牌标记 + 设备名 + 连接状态 + 「+」；五个入口（AI 助手/任务/电脑/项目/我的，选中浅紫底）；历史会话列表；底部版本号 |
| 其它页 | 任务/电脑/项目/我的 统一换成 `KimiAppBar`：白底无阴影、26px 大标题、左侧 40px 圆形菜单（`DrawerMenuButton`）、右侧圆形操作；内容顶部留白 10px |
| 空态 | `EmptyState` 改为 64px 浅灰圆底图标 + 18px 标题 + 13px 说明 + 胶囊按钮；列表内 `EmptyHint` 保持克制风格 |
| 插件直连修复 | 插件模式没有任务 REST 接口，任务页曾弹「拉取任务列表失败（not found）」；`LiveStore` 新增 `_tasksRestUnavailable`，404 后静默并由 WSS `task.state` 维护任务，任务详情同理 |
| 设计令牌 | 白底 `#FFFFFF`、强调 `#4C5CFF`、浅灰 `#F4F5F8`；radius card 18 / sheetTop 28 / bubble 20 / input 24；阴影单层 4% |
| 细节修复 | 首页 body 套 `SafeArea`（否则顶栏压状态栏）；`FilledButton` 主题的 `minimumSize: Size.fromHeight(48)` 会让空态按钮变全宽 → 覆盖为 `Size(0,44)`；长设备名在顶栏/问候语里截短 |
| 测试 | `flutter test` **207/207**（新增「插件直连任务接口 404 静默」；widget_test / empty_state_test 改为先拉抽屉再点入口） |
| 构建 | `dist/DeepSeek-Remote-AI-v0.2.1-m2.9.apk`（68,848,232 字节，versionCode 12，versionName 0.2.1-m2.9） |
| 截图 | `docs/research/evidence/m2/m2_9-kimi-home.png` / `-drawer.png` / `-chat.png`；四页见 `-tasks.png` / `-control.png` / `-projects.png` / `-profile.png` |
| 更新源 | 插件 `appupdate.js` 改为每次取快照都重读版本号（原来只在构造时读一次，换包后仍报旧版本）；插件包升 **0.2.1**；`/api/v1/app/version` → `12 / 0.2.1-m2.9 / 68,848,232 B`，`HEAD /api/v1/app/apk` 200；App 内「检查更新」实测「已是最新版本 v0.2.1-m2.9」 |
| 设置页入口 | 插件新增 Client 半（`client.js` + `dsh.client`），注册到 `settings.section`：设置里出现「DeepSeek 手机端」页，显示中继状态、配对码（可复制）、手机可用地址/公网地址、授权目录、手机端安装包版本；数据来自 Host 同源路由 `GET /deepseek-remote/api/status`（5 秒轮询）。插件包升 **0.2.2**。修过一次时序问题：插件 apply 早于浏览器半启动，直接 `ctx.get('webServer')` 得到 `undefined`，路由静默未注册（重启后设置页只剩「中继未运行」）；改用 `ctx.inject(['webServer'], scoped => …)`，服务可用后再挂路由 |
| 未做 | 语音、新建项目、插件市场等 Kimi 专属功能未接；深色模式沿用同一套令牌未逐页校准 |

### M2.9.2 桌面任务同步（2026-11-10 补充）

用户反馈「电脑上发起的任务，手机任务页完全看不到」。根因是插件只转发 relay agent 自己的事件，桌面 GUI 里的会话不经过它；而手机任务页只认后端 REST，插件模式下 404 就静默为空。

| 项 | 结果 |
|---|---|
| 插件只读镜像 | `GET /api/v1/desktop/tasks`（8787，Bearer = 配对 token）：从 Host 的 `sessions.list()` 取会话，标题取 `header.title`（缺省用目录名），状态由 `api-session/status` / `api-session/activity` / `api-session/error` 事件维护，最多 50 条 |
| 鉴权 | `M1Hub.authorizeToken(token, role='app')` 复用配对 token 表与过期时间；未带/失效返回 401 |
| App 回退 | `LiveStore.loadTasks`：REST `/api/v1/tasks` 404 → `_tasksRestUnavailable`，立即改调 `HistoryApi.desktopTasks`，映射成 `TaskRecord` → `TaskItem`；任务页 5 秒轮询 + 下拉刷新，列表卡片显示目录与状态 |
| 版本 | 插件 **0.2.3**（health/设置页版本改成每次从 `package.json` 重读，避免 ESM 缓存旧值）；App **0.2.2+13 / 0.2.2-m2.9.2** |
| 测试 | `flutter test` **208/208**（新增「任务 REST 404 后改走桌面镜像并映射状态」） |
| 构建 | `dist/DeepSeek-Remote-AI-v0.2.2-m2.9.2.apk`（68,848,236 字节，versionCode 13，sha256 前缀 `BE9DAC11D1EE2226`） |
| 实测 | 模拟器任务页列出电脑上的 3 个会话（deepseek手机端 / 示例项目B / 示例项目C），带目录与「已完成」状态；截图 `docs/research/evidence/m2/m2_9_2-desktop-tasks.png` |
| 已知限制 | 只读：点进去看不了桌面会话的时间线，也不能接管/继续；时间戳目前取事件发生时间，未接会话自身的 updatedAt |

### M2.9.3 桌面会话直播（2026-11-10 补充）

用户要「共享屏幕的感觉」：不只是任务列表，而是能看到电脑上那个会话正在做什么。按选定范围实现为**实时内容镜像**（不做像素推流）。

| 项 | 结果 |
|---|---|
| Host 事件流 | 插件读 `session.log`（Host 会话事件日志，按 `seq` 递增），把 `user/message`、`assistant/message`、`tool/call`、`tool/result`、`turn/start`、`turn/end`、`approval/*` 翻成手机可直接渲染的条目；`time-context` 快照与 `step/*` 等噪声跳过 |
| 接口 | `GET /api/v1/desktop/sessions/:id/events?afterSeq=&limit=`（8787，Bearer 配对 token）：不带 `afterSeq` 取尾部一屏，带则只回增量；响应含 `title/cwd/running/lastSeq` |
| App | 新增 `DesktopSessionScreen`：1.5 秒增量轮询、自动滚到底、用户气泡/助手正文/工具卡（可展开命令）/结果行/轮次分隔/等待授权卡片；任务页点桌面任务直接进直播页（不走 REST 详情） |
| 连接方式 | 无需新协议；仍走 8787 局域网或 trycloudflare 公网地址，WSS 不变 |
| 版本 | 插件 **0.2.4**；App **0.2.3+14 / 0.2.3-m2.9.3** |
| 测试 | `flutter test` **209/209**（新增「桌面会话直播按 seq 增量拉取并映射事件」） |
| 构建 | `dist/DeepSeek-Remote-AI-v0.2.3-m2.9.3.apk`（versionCode 14） |
| 实测 | 任务页「进行中 1 / 已完成 3」，运行中的卡片带进度条；点进直播页显示「直播中」，能实时看到助手正文、工具调用与结果；截图 `docs/research/evidence/m2/m2_9_3-tasks-running.png`、`m2_9_3-live-running.png`、`m2_9_3-live-finished.png`；报告 `docs/research/M2_9_3_REPORT.md` |
| 已知限制 | 只读：手机不能插话、不能替电脑审批；1.5 秒轮询有轻微延迟；`approval/*` 事件是否落日志取决于 Host 版本，未落时可从任务状态看出「运行中」 |

### M2.9.4 手机接管：发指令 + 应答授权（2026-11-10 补充）

在 M2.9.3 的直播页上补了写通道：手机能对着电脑上正在跑的会话继续说，也能替电脑点「允许一次 / 拒绝」。

| 项 | 结果 |
|---|---|
| 发指令 | `POST /api/v1/desktop/sessions/:id/prompt`（8787，Bearer 配对 token）：`sessionController.prompt({mode:'queue', content:[{type:'text'}]})`，返回 `{ok,accepted}`；手机端输入框发送后原地刷新直播流 |
| 接管授权 | Host 的 `approval/request` waterfall：只有「手机在 2 分钟内看过该会话」才拦下（`isWatching`），否则原样 `next()` 让桌面弹窗；拦下后建 pending，90 秒无应答返回 `unavailable`，`signal` 中断返回 `cancelled` |
| 应答 | `POST /api/v1/desktop/sessions/:id/approvals/:approvalId`，body `{decision:'approve'|'reject'}` → `allowed-once` / `rejected`；失败 404 `APPROVAL_NOT_FOUND`；直播流响应带 `approvals[]`，手机端渲染成警示卡片（工具名 + 原因 + 两个按钮） |
| App | 直播页底部加输入条（发送后 SnackBar「已发送到电脑」），授权卡片支持「拒绝 / 允许一次」；页脚改为「实时同步 · 可直接发指令，授权也能在手机上应答」 |
| 注入过滤 | 直播流里跳过 Host 注入的 `Current runtime context…` / `<system-reminder>` / `<hindsight_knowledge>` 等 user 事件，只显示人真正说的话 |
| 版本 | 插件 **0.2.4**；App **0.2.4+15 / 0.2.4-m2.9.4** |
| 测试 | `flutter test` **211/211**（新增「授权随直播流返回」「发指令与应答授权走 POST」） |
| 构建 | `dist/DeepSeek-Remote-AI-v0.2.4-m2.9.4.apk`（68,865,092 字节，versionCode 15，sha256 前缀 `BADA8BC217491E72`） |
| 实测 | 模拟器：任务页 7 条（进行中 2）→ 点「测试」进直播页，底部输入条发 `replyOK`，会话由「已结束 80 条」变「直播中」，日志出现 `seq=1048 user text=replyOK`，跑完 87 条；截图 `docs/research/evidence/m2/m2_9_4-tasks.png`、`m2_9_4-live-composer.png`、`m2_9_4-after-send.png`、`m2_9_4-feed.png`；报告 `docs/research/M2_9_4_REPORT.md` |
| 已知限制 | 发指令用 `mode:'queue'`，不打断当前轮；授权接管仅在手机 2 分钟内看过该会话时生效，90 秒无应答回落到 `unavailable`；只能对已有会话发指令，不能新建/切项目；直播仍是 1.5 秒轮询 |

### M2.9.5 对话视图：只同步聊天内容（2026-11-10 补充）

用户反馈「要同步和电脑对话框一样的内容，不要这些过程」。直播页改为**只保留用户消息与助手回复**：工具调用、工具结果、轮次分隔、思考标记全部在前端过滤，相邻的助手片段合并成一段；授权卡片仍保留（那是要操作的，不是过程）。标题计数改成「N 条消息」。

| 项 | 结果 |
|---|---|
| 过滤 | `DesktopSessionScreen._messages`：只取 `kind == 'user' \| 'assistant'`，助手片段按顺序用空行拼接；`tool-call` / `tool-result` / `turn-start` / `turn-end` 不渲染 |
| 计数 | 头部胶囊显示「直播中 · N 条消息 / 已结束 · N 条消息」，N 只算可见消息 |
| 版本 | App **0.2.5+16 / 0.2.5-m2.9.5**（插件仍 0.2.4） |
| 构建 | `dist/DeepSeek-Remote-AI-v0.2.5-m2.9.5.apk`（68,865,092 字节，versionCode 16） |
| 实测 | 模拟器打开「示例项目B」直播页：只剩助手正文段落，没有工具卡/结果行/轮次分隔；头部显示「直播中 · 3 条消息」；截图 `docs/research/evidence/m2/m2_9_5-chat-only.png` |
| 测试 | `flutter test` **211/211** |

### M2.9.6 自动续连：不用每次重新配对（2026-11-10 补充）

用户反馈「每次打开手机都要重连，不行」。根因有两层：电脑端 Hub 的 token 只存在内存里，插件一重载/重启就全失效；手机端也没把地址和 token 存下来，冷启动必然回到连接页。两端各补一层持久化。

| 项 | 结果 |
|---|---|
| 插件 token 存档 | `dsh-plugin-m1/lib/hub.js` 新增 `#tokenStore` / `#restoreTokens()` / `#persistTokens()`，`pair()` 成功即落盘，构造时恢复；`lib/index.js` 在 `stateDir` 用 `tokens.json` 读写（实际文件 `C:\Users\user\.dsh\dsh-plugin-m1\tokens.json`） |
| App 会话存档 | 新增 `app/lib/services/session_store.dart`：`SavedSession{serverUrl, token, deviceId, savedAt}`，写到 `getApplicationSupportDirectory()/session.json`；`LiveStore` 连接成功保存、主动断开清除，新增 `restoreSession()` |
| 冷启动 | `app/lib/app.dart` 启动时 `unawaited(_liveStore.restoreSession())`：有存档直接用旧 token 连回，不进连接页；续连失败才清存档回连接页 |
| 设置页二维码 | 状态口新增 `qr.lan` / `qr.public`（Host 用 `assets/qrcode.js` 在 vm 里生成 SVG），设置页直接内嵌「扫码连接」卡，手机首页扫码即可自动填地址+配对码（插件 0.2.6） |
| 版本 | 插件 **0.2.6**；App **0.2.6+17 / 0.2.6-m2.9.6** |
| 测试 | `flutter test` **215/215**（新增 4 条：冷启动续连不重配对、配对后落盘、续连失败清存档、主动断开清存档） |
| 实测 | 同一 token 连续 3 次插件重载后仍可访问 `/api/v1/desktop/tasks`（4 条）；tokens.json 405→566 字节；模拟器装 0.2.6 连一次后 `am force-stop` 再启动，直接回到已连接的首页（截图 `docs/research/evidence/m2/m2_9_6-auto-reconnect.png`） |
| 构建 | `dist/DeepSeek-Remote-AI-v0.2.6-m2.9.6.apk`（**69,603,190 字节**，versionCode 17） |

### M2.9.7 扫码页支持从相册选图（2026-11-11 补充）

用户反馈「app 上扫码没有从相册里选取的功能」。扫码页补了「从相册选择」：相机不好对焦、或者二维码在电脑截图里时，直接从相册挑一张图识别。

| 项 | 结果 |
|---|---|
| 依赖 | `image_picker: ^1.2.0`（系统相册选择器，Android 13+ 走 Photo Picker，无需额外存储权限） |
| 实现 | `app/lib/screens/scanner_screen.dart`：新增 `_pickFromGallery()` → `ImagePicker().pickImage(source: gallery, maxWidth: 2400)` → `MobileScannerController.analyzeImage(path)`，复用同一个 `_tryBarcodes()` 解析；识别不到给「这张图片里没有识别到配对二维码」提示；相机打不开的错误页也带这个入口 |
| 版本 | App **0.2.7+18 / 0.2.7-m2.9.7**（插件仍 0.2.6） |
| 测试 | `flutter test` **215/215** |
| 实测 | 模拟器推送一张二维码 GIF 到相册 → 扫码页点「从相册选择」→ 选中 → 自动返回连接页并填好 `http://192.168.1.x:8787` + `000000`，直接重连成功（截图 `docs/research/evidence/m2/m2_9_7-gallery-scan.png`） |
| 构建 | `dist/DeepSeek-Remote-AI-v0.2.7-m2.9.7.apk`（**69,691,722 字节**，versionCode 18） |

### M3.0 对话折叠 + 附件上传 + 云端直连（2026-11-11 补充）

用户提了三件事：对话页不要露出英文命令（过程折叠或干脆不显示）、输入条能发照片和文件、首页要有不依赖电脑的 API 对话。

| 项 | 结果 |
|---|---|
| 过程折叠 | `app/lib/widgets/turn_fold.dart` 改为「连续的工具/思考一律折叠」，执行中也折叠，不再等轮次结束；摘要用 `TurnStats.summaryLabel`，没有统计时退回「执行过程 · N 步」/「思考过程」；展开才看到原来的命令与输出 |
| 附件上传（电脑端） | 插件新增 `POST /api/v1/desktop/upload`（Bearer/`?token=`），body `{name, data(base64)}`，上限 20 MiB，落盘到 `stateDir/uploads/<ISO时间>-<安全文件名>`，返回 `{ok, name, path, size}`；`pageContext.uploadDir` 注入 |
| 附件上传（手机端） | `image_picker` 选照片（多选）、`file_picker` 选文档（多选）；输入条上方显示附件 chips（图标/文件名/大小/删除），发送时先上传，再把 `附件（已保存到电脑）：- <绝对路径>` 追加到指令后面；无文字只发附件也能发 |
| 云端直连 | 新增 `app/lib/services/cloud_chat.dart`（OpenAI 兼容 `/chat/completions`，SSE 流式）+ `app/lib/screens/cloud_chat_screen.dart`（配置地址/模型/Key，Key 只存本机 `cloud_chat.json`；气泡列表、停止生成、新对话）；首页未连接时按钮下方多一个「用 API Key 直接对话」入口 |
| 版本 | App **0.3.0+19 / 0.3.0-m3.0**；插件 **0.2.7** |
| 测试 | `flutter test` **219/219**（新增 4 条云端配置/存档用例；折叠相关两条断言改为「执行中也折叠」） |
| 构建 | `dist/DeepSeek-Remote-AI-v0.3.0-m3.0.apk`（**70,292,878 字节**，versionCode 19） |
| 实测 | 模拟器装 v0.3.0：对话里工具过程折成「执行中 4 步 · 展开」，附件上传后提示词里带 `C:\Users\user\.dsh\dsh-plugin-m1\uploads\2026-11-11T02-25-29-889Z-scaled_1000000094.gif`；断开后首页出现「用 API Key 直接对话」，进入云端页显示「填一个 API Key 就能用」（截图 `m3_0-fold-and-attachment.png`、`m3_0-home-cloud-entry.png`、`m3_0-cloud-chat.png`） |

### M3.1 连接稳定：心跳 + 无限重连（2026-11-11 补充）

用户反馈「连接容易断」。根因有三处：插件中继没有空闲超时、Cloudflare 隧道重启会换 URL、App 重连 8 次后退避到 30 秒就放弃且没有心跳。

| 项 | 结果 |
|---|---|
| 心跳 | `app/lib/services/relay_client.dart` 每 20 秒发一次 `ping`；插件回的 `pong` 与任何消息都会刷新 `_lastInboundAt`；超过 55 秒没有任何消息即判定连接已死，置错误文案并立即重连 |
| 无限重连 | `maxRetries` 默认 0（0 = 不限次数），只有显式设成正数才会在次数用尽后报「多次重连失败」；退避仍按 1s→30s 增长，但加了 ±20% 抖动，避免多端同时重连 |
| 回前台补一刀 | `LiveStore.ensureReconnected()`：已连接直接返回；无 token 用存档续连；有 token 就用内存地址重连，失败不清 token，交给中继后台继续重试；`app/lib/app.dart` 在 `AppLifecycleState.resumed` 时调用 |
| 仍存在的限制 | 公网地址是 Quick Tunnel，插件每次重启都会换新 URL，手机旧地址必然连不上；要稳定公网需 Named Tunnel 或云服务器（M3 候选里的第 6 条） |
| 版本 | App **0.3.1+20 / 0.3.1-m3.1**（插件仍 0.2.7） |
| 测试 | `flutter test` **221/221**（新增心跳超时重连、回前台续连两条） |
| 构建 | `dist/DeepSeek-Remote-AI-v0.3.1-m3.1.apk`（**70,309,262 字节**，versionCode 20） |
| 实测 | 模拟器装 v0.3.1：杀进程重开自动连回；停掉插件再启用，页面自动从「未连接」恢复成「已连接」，只提示一次「连接已恢复。」（截图 `m3_1-auto-reconnect.png`） |

### M3.2 桌面直播：只看结论 + 也能发附件（2026-11-11 补充）

用户要求：桌面直播页不要把代码和英文过程铺满，只看结果对话；并且这个输入框也要能发照片/文件。

| 项 | 结果 |
|---|---|
| 隐藏代码 | 插件 `mapDesktopEvent` 的 `assistant/message` 分支加 `stripCodeBlocks()`，把 ``` 围栏代码整段替换成「〔代码已省略〕」并压缩多余空行；工具调用/结果在 App 侧只保留 `user`/`assistant` 两类事件，本来就不渲染 |
| 直播页附件 | `app/lib/screens/desktop_session_screen.dart` 新增待发附件列表、相册多选（`image_picker`）、文件多选（`file_picker`）、输入条「+」菜单、附件 chips 与删除；发送时先 `uploadDesktopFile`，再把「附件（已保存到电脑）：- <路径>」拼进指令，纯附件也能发 |
| 版本 | App **0.3.2+21 / 0.3.2-m3.2**；插件仍 0.2.7 |
| 测试 | `flutter test` **221/221** |
| 构建 | `dist/DeepSeek-Remote-AI-v0.3.2-m3.2.apk`（**70,325,646 字节**，versionCode 21） |
| 实测 | 模拟器 v0.3.2：直播页只剩对话文字（工具卡不再出现），“+”菜单出现「照片/文件」 |

### M3.3 附件消息不再露路径（2026-11-11 补充）

用户截图反馈：发完附件，对话气泡里出现「附件（已保存到电脑）：- C:\...」一大段路径。

| 项 | 结果 |
|---|---|
| 根因 | 为了让电脑上的模型拿到文件，发送时把绝对路径拼进了正文；手机端把整段原文直接显示在气泡里 |
| 修法 | 新增 `app/lib/services/message_text.dart`（`parseUserText` / `attachmentFileName`）：把「正文 + 附件清单」拆开；`_UserBubble` 只显示用户真正打的字，附件以下方「📎 文件名」小字列出；只发附件时连自动补的「我发了一些附件，请看一下：」也隐藏 |
| 直播页 | 桌面直播里同样把该段收起来，显示成「发了 N 个附件」 |
| 版本 | App **0.3.3+22 / 0.3.3-m3.3** |
| 测试 | `flutter test` **226/226**（新增 `message_text_test.dart` 3 条 + `attachment_bubble_test.dart` 2 条断言：气泡不含「附件（已保存到电脑）」与绝对路径） |
| 构建 | `dist/DeepSeek-Remote-AI-v0.3.3-m3.3.apk`（**70,325,642 字节**，versionCode 22） |

### M3.4 桌面对话：过程折叠 + 拍照（2026-11-11 补充）

| 项 | 结果 |
|---|---|
| 过程折叠 | 桌面直播只显示对话正文；工具调用/结果/轮次标记收进列表上方的「过程 · N 步（点开看）」，点开是半屏抽屉，按时间列出每一步命令与结果 |
| 拍照 | 首页输入条与桌面直播输入条的「+」菜单都新增「拍照」，直接调相机，拍完作为附件走同一套上传流程 |
| 版本 | App **0.3.4+23 / 0.3.4-m3.4** |
| 测试 | `flutter test` **226/226** |
| 构建 | `dist/DeepSeek-Remote-AI-v0.3.4-m3.4.apk`（**70,505,938 字节**，versionCode 23） |

## 九、复现与自检

```powershell
# M0 + M1 电脑端自检
cd "<项目根>\agent"
npm run acl:check        # 工作区权限自检（首次建议 acl:fix）
npm run test             # 36 单测
npm run test:contract    # 9 合同测试（真实 Harness，约 30s）
npm run e2e              # 5 步端到端冒烟（约 20s）
npm run selftest:relay   # M1 relay 自测（假后端，24 项）

# M1 全链路（推荐：一键拉起后端+隧道+Agent[+模拟器]）
cd "<项目根>"
powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-up.ps1 -WithEmulator
powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-down.ps1   # 关闭

# M1 全链路（手动：需先起后端+Agent；公网再加隧道）
node tools\m1-client.ts --base http://127.0.0.1:8080
node tools\m1-client.ts --base https://<你的隧道地址>

# M2.1 断线补偿演练（真实断流 60s → 重连 afterSeq 补拉）
node tools\m2-catchup-test.ts --base http://127.0.0.1:8080 --drop-ms 60000

# M2.5 在线更新接口（本地 / 公网隧道都可用）
Invoke-RestMethod -Uri "http://127.0.0.1:8080/api/v1/app/version" -UseBasicParsing | Format-List
Invoke-WebRequest -Method Head -Uri "http://127.0.0.1:8080/api/v1/app/apk" -UseBasicParsing | Select-Object StatusCode,Headers
# 换包：替换 dist\DeepSeek-Remote-latest.apk + 改 app.update.version-code/version-name → 重启后端 → 手机点检查更新

# M2.6 项目同步（真实链路 14/14：目录浏览 + 文件预览 + 项目内发指令）
node tools\verify-project-sync.ts --base http://127.0.0.1:8080
node --test agent/tests/unit/workspace-fs.test.ts
# 工作区根由 M1_WORKSPACE_ROOT 指定（m1-up.ps1 -WorkspaceRoot <目录>），默认 agent\.m1ws

# M2.7 插件直连（不再需要后端/隧道：插件自己监听 8787 并拉起 Agent）
cd dsh-plugin-m1
node tools\smoke.mjs                                   # 中继自测 24/24
node tools\probe-create.mjs --code <匹配码> --workspace "<项目根>\agent\.m1ws"
cd ..
node tools\m1-client.ts --base http://127.0.0.1:8787   # M1 E2E 6/6（带 --code <匹配码>）
# 配网页（二维码 + 匹配码）：http://127.0.0.1:8787/
# 匹配码文件：C:\Users\user\.dsh\dsh-plugin-m1\pairing-code

# M2.8 手机端写文件（真实链路 14/14：新建/sha 校验/撞名/冲突/覆盖/越界）
node tools\verify-file-write.ts --base http://127.0.0.1:8787 --code <匹配码>
node --test agent/tests/unit/workspace-fs.test.ts      # 20/20
# 改 agent 代码后需同步进插件内置副本，并让 supervisor 重启 agent 子进程：
#   copy agent\src\relay\*.ts dsh-plugin-m1\agent\src\relay\ -Force
#   结束命令行含 dsh-plugin-m1 ... serve.ts 的 node 进程（自动拉起，无需重载插件）
# 改 hub.js / 插件入口才需要整插件重载：
#   plugin_manager set_bundle dsh-plugin-m1 enabled=false → enabled=true（会换新隧道地址）

# M2.9.2 桌面任务镜像（先本机配对拿 token，再查列表）
$pair = Invoke-RestMethod -Uri http://127.0.0.1:8787/api/v1/auth/pair -Method Post -ContentType application/json -Body '{"pairingCode":"<匹配码>","clientName":"probe","role":"app"}'
Invoke-RestMethod -Uri http://127.0.0.1:8787/api/v1/desktop/tasks -Headers @{ Authorization = "Bearer $($pair.token)" } | ConvertTo-Json -Depth 4

# M2.1 数据面复核（事件表无空洞、thinking 不落消息）
psql -h 127.0.0.1 -p 5433 -U postgres -d deepseek_remote -c "select count(*) from task_events; select type, count(*) from task_events group by type order by 2 desc;"

# 手机 App
cd app; flutter test; flutter build apk --debug

# M2.7.1 公网 + 扫码自检（App 自己的网络层，各 8 项 PASS）
cd app; dart run tool\live_pair_check.dart http://127.0.0.1:8787 <匹配码>
cd app; dart run tool\live_pair_check.dart https://<公网隧道域名> <匹配码>
# 公网 E2E（插件隧道）：
node tools\m1-client.ts --base https://<公网隧道域名> --code <匹配码>
# APK（项目路径含中文，AOT 会失败 → 拷到 ASCII 路径构建后回拷）：
#   robocopy app C:\Users\user\dsh-build\app-remote /E /XD build .dart_tool android\.gradle
#   $env:ANDROID_HOME='C:\Users\user\dsh-tools\android-sdk'; $env:JAVA_HOME='C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1'
#   cd C:\Users\user\dsh-build\app-remote; flutter build apk --release
# M2.7.2 应用内更新（插件当更新源）
node dsh-plugin-m1\tools\probe-update.mjs
cd app; dart run tool\live_update_check.dart http://127.0.0.1:8787 <当前 versionCode>
```

> ⚠ 本机 headless 模拟器（`-no-window`）实测跑约 20–25 分钟后会被运行环境回收（`adb` 掉线、日志出现 `adb protocol fault`），重跑 `m1-up.ps1 -WithEmulator` 即可；后端/Agent/隧道不受影响。

任何时候 Harness 升级后，先跑 `npm run test:contract` 与 `node tools\m1-client.ts`——它们是适配层与全链路的回归门。

### M3.5 手机端插件与工作区（2026-11-11 补充）

| 项 | 结果 |
|---|---|
| 插件接口 | 插件新增 `GET /api/v1/desktop/plugins`、`POST /api/v1/desktop/plugins/enabled`，数据来自 Host `pluginManager` |
| 插件页 | 抽屉新增「插件」：列出电脑上 214 个插件，可启停（只读项禁用开关），按启用状态排序 |
| 工作区筛选 | 任务页新增工作区胶囊（全部工作区 + 各目录），与状态筛选叠加 |
| 版本 | App **0.3.5+24 / 0.3.5-m3.5**；插件 0.2.7 |
| 测试 | `flutter test` **226/226** |
| 构建 | `dist/DeepSeek-Remote-AI-v0.3.5-m3.5.apk`（**70,735,622 字节**，versionCode 24） |

### M3.6 对话对齐 PC / 插件市场 / 打开即最新（2026-11-11 补充）

| 项 | 结果 |
|---|---|
| 用户反馈 | ① 桌面直播里出现英文推理正文；② 插件与 PC 不同步、没有插件市场；③ 每次打开对话不是最新 |
| 根因 | ① 插件把 `assistant/message` 的所有 content part（含 reasoning）拼成正文；② 插件直接下发 Host 原始插件结构（`entryId/moduleName/meta.title`，App 取 `id/name` → 214 条空行），且无市场接口；③ 插件 `listDesktopTasks()` 用 `tracked.updatedAt \|\| Date.now()`，所有会话同一时刻 |
| 插件端 | 新增 `lib/assistant-text.js`（只取 `''/text/markdown/output_text` part）、`lib/task-rows.js`（`lastTime` 倒序、同名补 `HH:mm`）、`lib/server.js` 5 条路由（plugins/bundles、bundles/enabled、market、market/install、market/remove）、`plugins()`/`pluginBundles()`/`pluginMarket()` 归一化、`debugSession()` 增 `assistantParts`；`package.json` → **0.2.8**；单测 `test/assistant-text.test.js` + `test/task-rows.test.js` **12/12** |
| 手机端 | `history_api.dart` 增 `lastTime/messageCount/lastSeq`、`PluginBundle/MarketIndex/MarketEntry/MarketSearchResult` 与 5 个方法；新增 `services/desktop_sort.dart`；`plugins_screen.dart` 重写为「已安装 / 插件市场」双 Tab（bundle 分组、市场搜索/安装二次确认/卸载、旧插件 404 回退「系统内置」）；`tasks_screen.dart` 会话卡显示消息数与最后时间并按时间倒序；`desktop_session_screen.dart` 回前台强刷 + 打开滚到底 |
| 版本 | App **0.3.6+25 / 0.3.6-m3.6**；插件 **0.2.8** |
| 测试 | `flutter test` **244/244**（新增 20，既有 224 零回归，Lead 独立复跑 exit 0）；插件单测 **12/12** |
| 构建 | debug APK **177,899,089 字节**（`versionCode=25`、`versionName=0.3.6-m3.6`，SHA256 `3853FA87…25F6B1`）；根目录与 `dist/` 已更新。注：`--release` 在本机中文路径下报 `Unable to read file: …app.dill`（Flutter AOT + 非 ASCII 路径已知问题），故交付 debug 包 |
| 生效前置 | 本机 **HMR 事务锁**（`HMR transactions cannot be nested`）导致插件无法热加载 0.2.8 → **需完整退出并重开一次 DSH**；重启后跑 `tools\verify-plugin-m3-6.ps1`（期望 6/6 PASS），手机需按新地址重新配对 |
| 报告 | `docs/research/M3_6_REPORT.md` |
### M4.0 工作区整改 / 手机端新建工作区（2026-11-13 补充）

| 项 | 结果 |
|---|---|
| 用户诉求 | 继续上一步改造：把「工作区」从只读列表做成可用入口（新建工作区、会话排序与状态、新建会话、浏览文件） |
| 插件端 | `POST /api/v1/desktop/workspaces`（Bearer/`?token=`；body `{name}` → `{ok,name,path}`；失败 `400 WORKSPACE_CREATE_FAILED`），`createDesktopWorkspace()` 在第一个授权根目录下 `mkdir`，非法字符 `[\\/:*?"<>|]` → `-`，同名幂等；`package.json` → **0.2.9** |
| 手机端 | 新增 `DesktopWorkspaceCreated` + `HistoryApi.createDesktopWorkspace()` + `LiveStore.createDesktopWorkspace()`（成功后把目录追加进 `workspaceRoots`）；新增 `widgets/workspace_create_dialog.dart`（名字校验 + 预览路径 + 旧插件 404 提示）；`workspace_screen.dart` 重写（5s 轮询/下拉刷新/回前台刷新、`sortDesktopTaskItems` 倒序、状态徽标、`N 条消息 · 最后活动`、AppBar 浏览文件/新建会话/刷新、FAB 新会话、空态引导、底部输入固定发最新会话）；`tasks_screen.dart` 工作区胶囊常驻 + 「＋ 新建工作区」 |
| Bug 修复 | Hub 骨架 `device.status`（设备名 `DeepSeek Harness`、无 `workspaceRoots`）此前会清空 `_workspaceRoots` → 工作区页/新建工作区瞬间变空；现按设备名判定，骨架只更新能力位，Agent 真实空目录仍照常清空 |
| 版本 | App **0.4.1+27 / 0.4.1-m4.0**；插件 **0.2.9** |
| 测试 | `flutter test` **255/255**（新增 `test/workspace_m4_test.dart` 12 项；既有 243 项零回归，其中 `project_sync_test.dart` 的 device.status 用例一度回归已随骨架判定修复，`theme_m2_3_test.dart`/`empty_state_test.dart`/`widget_test.dart` 的版本断言已同步到 0.4.1+27） |
| 静态检查 | `flutter analyze` 18 issues、**无 error**（中文路径下 analyzer 会崩，改在 `C:\Users\user\dsh-build\app-remote` 镜像目录跑） |
| 构建 | **release APK 71,621,290 字节**（`versionCode=27`、`versionName=0.4.1-m4.0`，SHA256 `8ED1483C…1DFD62`，签名沿用 debug 密钥可覆盖安装）；根目录 `DeepSeek Remote AI 手机端 v0.4.1-m4.0.apk` 与 `dist/DeepSeek-Remote-AI-v0.4.1-m4.0.apk`、`dist/DeepSeek-Remote-latest.apk` 已更新；在 ASCII 镜像目录 `C:\Users\user\dsh-build\app-remote` 里 `flutter build apk --release` 成功（中文路径下仍会失败） |
| 插件自检 | 旧版基线 `tools\verify-plugin-m4.ps1 -NoCreate` → **2/6 PASS**（0.2.8 / POST 404）；重启 DSH 后期望 **6/6 PASS** |
| 文档 | `docs/mobile/API_CONTRACT.md`（补 `POST /desktop/workspaces`，标题 v0.4.1）、`docs/mobile/SIGNING.md`（测试数 255）、`docs/mobile/README.md`（§6.4 M4.0、§8 第 19 条）、`docs/research/M4_0_REPORT.md` |
| 生效前置 | 插件 0.2.9 需**完整退出并重开一次 DSH**；重启后隧道地址/配对码可能变化，手机需重新配对 |

### M4.1 插件页对齐电脑端 / 插件市场索引兜底（2026-11-13 补充）

| 项 | 结果 |
|---|---|
| 用户诉求 | 贴电脑端 DSH「插件」页截图（已安装的内置/实验性分组、插件市场卡片）要求手机端「要这样的」 |
| 根因 | ① 手机端只有 bundle（插件包）视角，没有 `pluginManager.listPlugins()` 级别的本地插件视图；② 市场永远为空是因为 DSH `pluginMarket.listIndexes()` 只返回设置里配置的索引 URL，本机未配置 → 空数组（M3.6 起自检一直 FAIL）；③ 新 Host 的 `search(url, query)` 要求 `query` 为 `{text,limit,offset,order}` 对象，旧 `{query,limit}` 签名会失败 |
| 插件端 | 新增 `GET /api/v1/desktop/plugins/gallery`（`pluginGallery()` 读 `listPlugins()`，按 `builtin`/`experimental`/`other` 分组，带 `enabled/configurable/version`；失败 `501 PLUGIN_GALLERY_UNAVAILABLE`）；`pluginMarket()` 无索引时兜底 `https://api.dshmarket.com/v1/index.json` 并 `refresh:true`（返回 `defaultIndex`），改用新签名并在 0 条时按 `order:'stars'` 重试，条目补 `downloads/stars`；`package.json` → **0.2.10** |
| 手机端 | `history_api.dart`：`MarketEntry.downloads/stars` + `downloadsLabel/starsLabel`（万/k 紧凑）、`MarketSearchResult.defaultIndex`、`PluginGallery/PluginGalleryGroup/PluginGalleryItem` + `pluginGallery()`；`live_store.dart` 透传；新增 `screens/plugin_gallery_screen.dart`（分组 + 实验性标签 + 逐项开关 + 过滤 + 旧插件提示）；`plugins_screen.dart` 已安装 Tab 顶部「浏览本地插件」入口、市场卡片加下载量/星标、列表顶部统计行 |
| 版本 | App **0.4.2+28 / 0.4.2-m4.1**；插件 **0.2.10** |
| 测试 | `flutter test` **263/263**（新增 `test/plugin_gallery_test.dart` 8 项；既有 255 项零回归，`theme_m2_3_test.dart`/`empty_state_test.dart`/`widget_test.dart` 版本断言同步到 0.4.2+28）；插件 `node --test 'test/*.test.js'` **12/12** |
| 静态检查 | `flutter analyze` 19 issues、**无 error**（在 `C:\Users\user\dsh-build\app-remote` 镜像目录跑） |
| 构建 | **release APK 71,720,030 字节**（`versionCode=28`、`versionName=0.4.2-m4.1`，SHA256 `D93C1756…02CEB6`，签名沿用 debug 密钥可覆盖安装）；根目录 `DeepSeek Remote AI 手机端 v0.4.2-m4.1.apk`、`dist/DeepSeek-Remote-AI-v0.4.2-m4.1.apk`、`dist/DeepSeek-Remote-latest.apk` 已更新 |
| 插件自检 | `tools\verify-plugin-m4.ps1` 扩到 **8 项**（版本门槛 0.2.10 + 新增 gallery 分组、市场索引兜底两项）；重启 DSH 后期望 **8/8 PASS** |
| 文档 | `docs/mobile/API_CONTRACT.md`（补 `GET /desktop/plugins/gallery`、market 的 `defaultIndex/downloads/stars`，标题 v0.4.2）、`docs/mobile/SIGNING.md`（测试数 263）、`docs/mobile/README.md`（M4.1 增量、§6.4 M4.1 小节、§8 第 20 条、文件树、测试数）、`docs/research/M4_1_REPORT.md` |
| 生效前置 | 插件 0.2.10 需**完整退出并重开一次 DSH**；重启后跑 `tools\verify-plugin-m4.ps1`（期望 8/8），手机装 0.4.2-m4.1 后重新配对；市场索引兜底依赖外网 `api.dshmarket.com` |
### M4.2 助手页直连对话 + 附件真正落地（2026-11-13 补充）

| 项 | 结果 |
|---|---|
| 用户诉求 | 「ai助手手机端手机页面不应该是直接对话吗，而且你这只能对话，干不了其他的事，文件，相册，拍照呢」 |
| 根因 | ① 助手页默认 `_mode='local'`，打开先是整屏品牌欢迎区 + 「手机 / 电脑」两档胶囊，还要再点一次才看到对话；② 附件上传一直落在插件状态目录 `C:\Users\user\.dsh\dsh-plugin-m1\uploads`，电脑端 AI 的工作区里根本看不到（AI 只拿到一个陌生绝对路径）；③ 附件入口藏在输入条左侧「+」的二级底部弹层里 |
| 插件端 | `lib/index.js` 新增 `UPLOAD_DIR_NAME='手机附件'` 与 `resolveUploadDir(requested)`：优先 `<授权根>/<工作区名>/手机附件`，其次当前会话 `header.cwd/手机附件`，最后退回状态目录 `uploads`；`createDesktopWorkspace` 改为同名目录已存在时直接复用（幂等）；`server.js` upload 路由按 `body.workspace` 选目录；`package.json` → **0.2.11** |
| 手机端 | `screens/assistant_screen.dart`：删 `_mode` 与 `_LocalDesktopSwitch`（打开即对话，空对话只留一行提示 + 3 个建议胶囊）、`_send()` 上传带 `workspace` 并弹出「已上传到电脑：N 个文件（工作区）」回执、`_AttachmentBar` 重写为常驻的 拍照 / 相册 / 文件 三个胶囊 + 图片缩略图 + 落盘目录提示、`_removeAttachment`；`history_api.dart` / `live_store.dart` 的 `uploadDesktopFile` 增加 `workspace` 参数 |
| 测试 | `flutter test` **267/267**（新增 `test/attachment_m4_2_test.dart` 4 项；版本断言同步到 0.4.3+29）；插件 `node --test 'test/*.test.js'` **12/12** |
| 静态检查 | `flutter analyze` 20 issues、**无 error**；`node --check` 通过 |
| 版本 | App **0.4.3+29 / 0.4.3-m4.2**；插件 **0.2.11** |
| 构建 | **release APK 71,867,762 字节**（`versionCode=29`、`versionName=0.4.3-m4.2`，SHA256 `E32F25E2…5103A25E`，签名沿用 debug 密钥可覆盖安装）；根目录 `DeepSeek Remote AI 手机端 v0.4.3-m4.2.apk`、`dist/DeepSeek-Remote-AI-v0.4.3-m4.2.apk`、`dist/DeepSeek-Remote-latest.apk` 已更新 |
| 插件自检 | `tools\verify-plugin-m4.ps1` 扩到 **9 项**（版本门槛升到 0.2.11 + 新增「upload 按工作区落盘」检查）；需重启 DSH 后跑，期望 **9/9 PASS** |
| 真机 | **未复测**：交付时 `adb devices` 为空（此前的 `10AF8R0ECH002HA` 掉线），用户答复「先不测，我把文档收尾」；首屏 / 拍照上传 / 回执 / 电脑端落盘目录需下次插线验证 |
| 文档 | `docs/mobile/API_CONTRACT.md`（标题 v0.4.3、upload 增加 `workspace` 字段）、`docs/mobile/SIGNING.md`（267）、`docs/mobile/README.md`（M4.2 增量、§8 第 21 条、文件树、测试数）、`docs/research/M4_2_REPORT.md` |
| 生效前置 | 插件 0.2.11 需**完整退出并重开一次 DSH** → 跑 `tools\verify-plugin-m4.ps1`（期望 9/9）→ 手机装 0.4.3-m4.2 并重新配对 |
### M4.3 直播「已运行」与电脑端对齐（2026-11-13 补充）

| 项 | 结果 |
|---|---|
| 用户诉求 | 「这个用时不应该和电脑上的统一吗，不是每次打开后开始计时」 |
| 根因 | 直播页只拿得到 `running` 布尔值，起点写死成 `_runStart ??= DateTime.now()`（打开页面那一刻），离开页面就丢；插件 `mapDesktopEvent` 映射事件时只保留 `seq`，把 Host 事件自带的 `time` 丢了 |
| 插件端 | `lib/index.js`：`mapDesktopEvent` 每个分支补 `time`（毫秒）；`package.json` → **0.2.12**；无新增路由 |
| 手机端 | `services/desktop_sort.dart` 新增纯函数 `resolveRunStart()`（取最新一条带时间的 `turn-start`，缺失时退回 `lastTime` → `updatedAt` → `now`）与 `formatElapsed()`（`M:SS` / `H:MM:SS`，负数归零）；`DesktopSessionEvent` 新增 `time` 并在 `withText` 中保留；`desktop_session_screen.dart` 每次拉取后按日志重算起点、去掉 `DateTime.now()` 起点；工作区页/任务页打开直播时传 `task.lastTime` |
| 测试 | `flutter test` **277/277**（新增 `test/desktop_run_timer_test.dart` 10 项）；插件 `node --test 'test/*.test.js'` **12/12** |
| 静态检查 | `flutter analyze` **0 error**（历史 warning/info 保留） |
| 版本 | App **0.4.3+30 / 0.4.3-m4.3**；插件 **0.2.12** |
| 构建 | **release APK 71,867,762 字节**（`versionCode=30`，SHA256 `F18663C6…43F8EFB1`，签名沿用 debug 密钥可覆盖安装）；已发布 `dist/DeepSeek-Remote-AI-v0.4.3-m4.3.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.3-m4.3.apk` |
| 插件自检 | `tools\verify-plugin-m4.ps1` 扩到 **11 项**（版本门槛 0.2.12 + 新增「会话事件带 time」检查）；需重启 DSH 后跑，期望 **11/11 PASS** |
| 真机 | **未复测**：`adb devices` 无设备（USB 未连接/未授权），长任务对照需下次插线 |
| 文档 | `docs/mobile/API_CONTRACT.md`（事件补 `time` 字段说明）、`docs/mobile/SIGNING.md`（277）、`docs/mobile/README.md`（M4.3 增量、§8 第 22 条、测试数）、`docs/research/M4_3_REPORT.md` |
| 生效前置 | 插件 0.2.12 需**完整退出并重开一次 DSH** → 跑 `tools\verify-plugin-m4.ps1`（期望 11/11）→ 手机装 0.4.3-m4.3 并重新配对 |
### M4.4 任务完成 / 等待授权通知（2026-11-13 补充）

| 项 | 结果 |
|---|---|
| 用户诉求 | 「他这做完了或者是要审核没有信息通知」 |
| 根因 | 只有等待授权与断线会发通知（且授权通知没有按钮）；任务在 `_applyTaskState` 里进入完成/失败/取消只写页内提示；任务列表与插件桌面镜像两条路径都不同步通知 |
| 插件端 | 本轮无改动（保持 0.2.12），通知全部走 App 原生侧 |
| 手机端 | `services/notification_prefs.dart`（新增，两个开关持久化）；`services/notification_gateway.dart`（新增 `approvalDecisions` 流 + `showTaskUpdate`/`showApprovalAction`/`cancelTaskUpdate`）；`data/live_store.dart`（`_notifyFinishedTasks` 前后对比 busy 标志、`_showApprovalActionNotice`、`_handleNotificationDecision`、`_pendingNotificationRoute`）；`screens/profile_screen.dart`（「通知」分区两个开关，「外观模式」移到「外观」分区）；`screens/root_shell.dart`（消费通知路由切到工作区页）；`models.dart`（`notificationExcerpt`） |
| 原生 | `NotificationHelper.kt`（`task_updates` 渠道 HIGH、任务通知、带「允许/拒绝」的常驻授权通知）；`NotificationBridge.kt`（`ACTION_APPROVE`/`ACTION_REJECT` 冷热启动都回传 `onApprovalDecision`、`EXTRA_NOTIFICATION_ROUTE`） |
| 测试 | `flutter test` **286/286**（M4.3 277 + 新增 `test/notification_m4_4_test.dart` 9 项）；插件未改动（`node --test` 仍 12/12） |
| 静态检查 | `flutter analyze` **0 error**（20 条历史 warning/info） |
| 版本 | App **0.4.4+31 / 0.4.4-m4.4**；插件 **0.2.12**（不变） |
| 构建 | **release APK 71,933,294 字节**（`versionCode=31`，SHA256 `225F9D5F…8D9000C90`，签名沿用 debug 密钥可覆盖安装）；已发布 `dist/DeepSeek-Remote-AI-v0.4.4-m4.4.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.4-m4.4.apk` |
| 插件自检 | `tools\verify-plugin-m4.ps1` 仍 11 项（本轮无插件改动），需重启 DSH 后跑，期望 11/11 PASS |
| 真机 | **未复测**：`adb devices` 无设备；通知渠道、按钮 PendingIntent、点击切页需插线点一遍 |
| 文档 | `docs/mobile/SIGNING.md`（286）、`docs/mobile/README.md`（M4.4 增量、§8 第 23 条、代码树、测试数）、`docs/research/M4_4_REPORT.md` |
| 生效前置 | 手机装 0.4.4-m4.4 并允许通知权限；插件无需重启。提醒只在 App 后台时发出，开关在「我的 → 通知」 |

### M4.5 更新下载进度条分帧（2026-11-13 补充）

| 项 | 结果 |
|---|---|
| 用户诉求 | 「更新时出来的进度条都不动」 |
| 根因 | 插件中继在 `127.0.0.1:8787` 回环网络上，实测 71.9 MB 的 APK **0.1 秒**就下完；`onProgress` 只在每个网络 chunk 到达时回调，等于几十毫秒内闪一帧就跳去调安装器 |
| 插件端 | 本轮无改动（保持 0.2.12）。`GET /api/v1/app/version` 从 `dist/DeepSeek-Remote-latest.apk` 读取版本，替换 latest 后手机端检查更新即可看到 32 |
| 手机端 | `services/update_service.dart`：新增 `progressInterval = 30ms` / `progressChunkSize = 256 KiB` / `Stream<List<int>> pace(...)` + 私有 `_paced(...)`（`BytesBuilder` 按字节切片分帧、`Stopwatch` 节流，超长 chunk 切成多帧）；`download()` 改为 `await for (final chunk in pace(response.stream))`；补 `dart:typed_data` 导入 |
| 测试 | `flutter test` **288/288**（M4.4 286 + `test/update_service_test.dart` 新增 2 项：1 MiB 至少 4 帧且字节一致、小响应原样透传）；插件未改动（`node --test` 仍 12/12） |
| 静态检查 | `flutter analyze` **0 error**（21 条历史 warning/info） |
| 版本 | App **0.4.5+32 / 0.4.5-m4.5**；插件 **0.2.12**（不变） |
| 构建 | **release APK 71,933,298 字节**（`versionCode=32`，SHA256 `E5A80045…BF444AF1`，签名沿用 debug 密钥可覆盖安装）；已发布 `dist/DeepSeek-Remote-AI-v0.4.5-m4.5.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.5-m4.5.apk` |
| 插件自检 | `tools\verify-plugin-m4.ps1` 仍 11 项（本轮无插件改动） |
| 真机 | **未复测**：`adb devices` 无设备；进度条观感与安装器调起时机需插线看一遍 |
| 文档 | `docs/mobile/SIGNING.md`（288）、`docs/mobile/README.md`（M4.5 增量、§8 第 24 条、测试数）、`docs/research/M4_5_REPORT.md` |
| 生效前置 | 手机装 0.4.5-m4.5（或旧版点「检查更新」自动拿到 32）。分帧只改上报节奏，下载总时长仍是本地中继真实速度 |

### M4.6 AI 助手分手机和电脑（2026-11-14 补充）

| 项 | 结果 |
| --- | --- |
| 用户诉求 | 「ai助手分手机和电脑」；确认后要求**默认停在手机档**，并保留 M4.2 之后的附件入口、桌面直播、通知、进度条分帧 |
| 根因 | M4.2 为「打开就是对话」把 M2.9 的 `_LocalDesktopSwitch` 整段删掉，手机档（云端直连）只剩未连接页里的一个按钮；内嵌 `CloudChatScreen` 不画 AppBar，也够不到接口设置 |
| 手机端 | `assistant_screen.dart`：恢复 `String _mode = 'phone'`（默认手机档）+ `bool get _phoneMode => _mode == 'phone'`；新增 `_ModeSwitch`（38 高，手机 / 电脑两项）；正文改 `IndexedStack(index: phone ? 0 : 1, children: [CloudChatScreen(embedded: true, controller: _cloudController), 电脑档 Column / _ConnectEmpty])`；`_HomeHeader` 新增 `cloudMode / cloudModel / cloudConfigured`，手机档胶囊显示「云端直连 · <模型>」或「云端直连 · 未设置接口」并一点打开设置；新增 `switchModeForTest` |
| 手机端 | `cloud_chat_screen.dart`：新增 `CloudChatController`（`editConfig()` / `isConfigured` / `modelName` / `notifyChanged`），`CloudChatScreen` 新增 `controller` 与 `onChanged` 参数并在 initState/didUpdateWidget/dispose 维护绑定；加载态改静态文案「正在读取云端接口设置…」（常驻时不再让页面永不停帧） |
| Bug 修复 | `_phoneMode` 早期写成 `!_isLive \|\| _mode == 'phone'`，未连接时切「电脑」会被强行弹回手机档 → 改为纯 `_mode == 'phone'`；IndexedStack 里被隐藏的子树转圈仍计入帧调度，导致 `pumpAndSettle` 超时 → 云端页转圈改静态文字 |
| 测试 | `flutter test` **291/291**（M4.5 288 + `test/assistant_mode_m4_6_test.dart` 新增 3 项：默认手机档与顶栏文案、切电脑档再切回云端页仍在、未配置云端页不转圈）；`attachment_m4_2_test.dart`、`empty_state_test.dart`、`widget_test.dart`、`theme_m2_3_test.dart` 的档位与版本断言同步 |
| 静态检查 | `flutter analyze` **0 error**（22 条历史 warning/info，含 `_openCloudChat` 未被引用） |
| 版本 | App **0.4.6+33 / 0.4.6-m4.6**；插件 **0.2.12**（不变） |
| 构建 | **release APK 72,015,286 字节**（`versionCode=33`，SHA256 `29443BE3…04E5812`，签名沿用 debug 密钥可覆盖安装）；已发布 `dist/DeepSeek-Remote-AI-v0.4.6-m4.6.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.6-m4.6.apk` |
| 插件自检 | `tools\verify-plugin-m4.ps1` 仍 11 项（本轮无插件改动，无需重启 DSH） |
| 真机 | **未复测**：`adb devices` 无设备；两档切换手感、顶栏胶囊点击、云端页键盘遮挡需插线看一遍 |
| 文档 | `docs/mobile/SIGNING.md`（291）、`docs/mobile/README.md`（M4.6 增量与已知限制、§8 第 25 条、测试数）、`docs/research/M4_6_REPORT.md`、根 `README.md` |
| 已知限制 | 手机档云端设置存手机本机（`CloudChatStore`），不同步给电脑；两档常驻内存略增；冷启动回到手机档（不记忆上次选择）；附件 / 直播 / 通知只在电脑档生效 |

### M4.7 手机档也能发照片 / 文件（2026-11-14 补充）

| 项 | 结果 |
| --- | --- |
| 用户诉求 | 「这不对呀，你这ai助手手机页面怎么没有上传文件图片拍照的」；确认后要求手机档（云端直连）也能拍照/相册/文件，并真正发给云端模型，默认档仍停在手机 |
| 根因 | 「手机」档是内嵌的 `CloudChatScreen`（M4.6 恢复），其 `_CloudComposer` 只有输入框 + 发送键；附件入口（M4.2 加的 `_AttachmentBar`）只存在于电脑档，且是 `assistant_screen.dart` 里的私有类，云端页用不上 |
| 手机端 | 新增 `lib/widgets/attachment_bar.dart`：`PendingAttachment`（后缀→MIME、文本判定、大小文案）、`AttachmentPicker`（拍照/相册/文件，平台实现惰性获取，避免 widget 测试里 file_picker 未注册就 LateInitializationError）、`AttachmentBar`（三胶囊 + 已选附件 + 去向提示）、`AttachmentThumbnails`（气泡缩略图） |
| 手机端 | `assistant_screen.dart` 改用共享组件，删掉末尾 285 行旧的 `_PendingAttachment` / `_AttachmentBar` / `_AttachAction` / `_PendingAttachmentChip`（文件从 2131 行降到 1846 行） |
| 手机端 | `cloud_chat_screen.dart`：`_attachments` 状态 + `_pickCamera/_pickPhotos/_pickFiles/_removeAttachment`；`_CloudComposer` 顶部接入 `AttachmentBar`；发送时把附件带进 `CloudMessage.user` 并清空；`_Bubble` 显示缩略图；空态与设置引导补「要发图片，请填支持视觉的接口」；新增 `attachForTest` / `sendForTest` / `pendingAttachmentsForTest` |
| 手机端 | `cloud_chat.dart`：`CloudMessage.attachments` + `buildUserContent()` 纯函数 —— 图片→`{type:image_url, image_url:{url:"data:<mime>;base64,…"}}`，文本文件→内联「【附件 名】」段（超 20000 字截断），其它→只提示文件名；`complete()` 的 messages 改为 `Map<String,dynamic>` |
| 测试 | `flutter test` **301/301**（M4.6 291 + `test/cloud_attachment_m4_7_test.dart` 新增 10 项：附件分类 3、`buildUserContent` 4、云端页 3） |
| 静态检查 | `flutter analyze` **0 error**（23 条历史 warning/info） |
| 版本 | App **0.4.7+34 / 0.4.7-m4.7**；插件 **0.2.12**（不变） |
| 构建 | **release APK 72,031,674 字节**（`versionCode=34`，SHA256 `30BE13B6…C3110CEDD`，签名沿用 debug 密钥可覆盖安装）；已发布 `dist/DeepSeek-Remote-AI-v0.4.7-m4.7.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.7-m4.7.apk`；`GET /api/v1/app/version` 已返回 34 |
| 插件自检 | `tools\verify-plugin-m4.ps1` 仍 11 项（本轮无插件改动，无需重启 DSH） |
| 真机 | **未复测**：`adb devices` 无设备；拍照/相册/文件三条系统入口、视觉模型看图效果需插线看一遍 |
| 文档 | `docs/mobile/SIGNING.md`（301）、`docs/mobile/README.md`（M4.7 增量与已知限制、§8 第 26 条、测试数）、`docs/research/M4_7_REPORT.md`、根 `README.md` |
| 已知限制 | 图片以 base64 进请求体（已压到 2400px）；文本超 2 万字截断；接口须支持视觉（DeepSeek 对话模型看不了图）；附件不落盘、不能重发；手机档附件不经过电脑 |

### M4.8 「不用上传」：手机档和正常 AI 一样处理各种问题（2026-11-14 补充）

| 项 | 结果 |
| --- | --- |
| 用户诉求 | 「不用上传，就和正常的 ai 一样可以处理各种问题」 |
| 界面文案 | 电脑档去掉「已上传到电脑：N 个文件」回执；指令列表「附件（已保存到电脑）」→「附件：」；附件条「正在上传…」→「正在读取…」 |
| 手机档读文件 | 新增 `CaretakerReader` 契约 + `POST /api/v1/desktop/file/read`（`HistoryApi.readDesktopFile` / `LiveStore.readDesktopFile`）；PDF/Word/Excel 由电脑读成文字内联进 prompt，读不到静默退回文件名提示 |
| 首次引导 | `_SetupHint` 重写 + `_StepsBlock`：手机档不经电脑、Key 只存手机；去 platform.deepseek.com 生成 → 回来粘贴 |
| 版本 | App **0.4.8+35 / 0.4.8-m4.8**；插件 **0.2.12**（不变，无需重启 DSH） |
| 测试 | `flutter test` **307/307**（301 + M4.8 新增 6：`app/test/attachment_m4_8_test.dart`） |
| 静态检查 | `flutter analyze` 23 issues、**0 error** |
| 构建 | **release APK 72,113,594 字节**（`versionCode=35`，SHA256 `72B89314…B244A876`，签名沿用 debug 密钥可覆盖安装）；已发布 `dist/DeepSeek-Remote-AI-v0.4.8-m4.8.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.8-m4.8.apk`；`GET /api/v1/app/version` 已返回 35 |
| 真机 | **未复测**：`adb devices` 无设备（USB 未连/未授权） |
| 已知限制 | 手机端须自备 API Key；DeepSeek 对话模型看不了图（要视觉模型）；插件未实现 `/desktop/file/read`，PDF/Word/Excel 目前仍提示「格式不支持」 |
| 文档 | `docs/research/M4_8_REPORT.md`、`docs/mobile/SIGNING.md`（307）、`docs/mobile/README.md`（M4.8 增量与已知限制、测试数）、根 `README.md` |

### M4.9 工作区里的图片 / PDF / Office 不再「无法预览」（2026-11-14 补充）

| 项 | 结果 |
| --- | --- |
| 用户诉求 | 「工作区的有些文件无法预览」→ 追问确认：图片（jpg/png）与 PDF / Word / Excel 打不开，希望「手机里直接看图 + 系统应用打开」 |
| 根因 | `FileViewerScreen` 只有文本预览，`content.binary` 为真直接报「无法预览」；插件 `workspace-fs.ts` 嗅到 NUL 字节就抛 `BINARY_FILE` |
| 插件端 | **0.2.13**：新增 `GET /api/v1/desktop/file/raw`（授权根校验 + 禁 `..`，上限 20 MB，直接回流字节）、`POST /api/v1/desktop/file/read`（文本 UTF-8 / `pdf-parse` 读 PDF / `JSZip` 抽 docx-pptx-xlsx，上限 2 MB）；新增依赖 `jszip`、`pdf-parse`；新增 `test/file-extract.test.js` |
| 手机端 | `FilePreviewKind` + `previewKindOf()` 按扩展名分流；图片用 `InteractiveViewer` + `Image.memory` 在 App 内放大；PDF/Office 下载后经新增 `FileOpenBridge.kt`（`cacheDir/preview/` + FileProvider `content://` + `ACTION_VIEW`）交给 WPS/系统阅读器；`HistoryApi.downloadWorkspaceFile` / `LiveStore.downloadWorkspaceFile`；`file_paths.xml` 加 `preview/` |
| 手机档附件 | M4.8 的 `CaretakerReader` 终于有真实实现：PDF/Word 交给电脑读成文字随消息发给云端模型 |
| 版本 | App **0.4.9+36 / 0.4.9-m4.9**；插件 **0.2.13** |
| 测试 | `flutter test` **315/315**（307 + M4.9 新增 8：`app/test/file_preview_m4_9_test.dart`）；插件 `node --test` **15/15** |
| 静态检查 | `flutter analyze` 23 issues、**0 error** |
| 构建 | **release APK 72,311,070 字节**（`versionCode=36`，SHA256 `A355AD1A…0194F71A`，签名沿用 debug 密钥可覆盖安装）；已发布 `dist\DeepSeek-Remote-AI-v0.4.9-m4.9.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.9-m4.9.apk` |
| 插件自检 | `tools\verify-plugin-m4.ps1` 门槛升到 0.2.13，新增 `file/raw`（取字节 + 401）与 `file/read`（读回文本）两项，共 **13 项**；重启前基线未跑 |
| 真机 | **未复测**：`adb devices` 无设备；`ACTION_VIEW` / FileProvider 授权 / WPS 拉起需在手机上点一遍 |
| 已知限制 | `file/raw` ≤20 MB、`file/read` ≤2 MB；`.doc/.xls/.ppt` 旧格式不支持；图片以外依赖手机上装了能打开它的 App；需插件 0.2.13+（旧版 404 会提示升级） |
| 文档 | `docs/research/M4_9_REPORT.md`、`docs/mobile/API_CONTRACT.md`（v0.4.9 新增「读文件」一节）、`docs/mobile/SIGNING.md`（315）、`docs/mobile/README.md`（M4.9 增量与已知限制、测试数）、根 `README.md` |

> **下一步**：完整退出 DSH 重开（加载插件 0.2.13）→ `tools\verify-plugin-m4.ps1` 期望 13/13 → 装 `dist\DeepSeek-Remote-latest.apk` 重新配对 → 手机上点开一张图 / 一个 PDF / 一个 docx 验证。

### M4.10 会话存档：电脑列表里消失的会话，手机端还能看（2026-11-15 补充）

| 项 | 结果 |
|---|---|
| 用户诉求 | 「为什么又看不到所有的项目了」：DSH 重启后工作区页只剩 1 条会话 → 连同「找回旧会话」「手机端存档」两件事用户都要 |
| 根因 | 会话文件都在 `C:\Users\user\.dsh\sessions\`（37 个项目目录 / 246 个会话），但不是当前会话的日志只有 227 字节 header；DSH 的 `dsh-session-persistence-jsonl` 在 `readGenerationHeader` 判定未物化时返回 `undefined`，整条会话从 `sessions.list()` 消失（与插件、手机端、重启均无关）。`zlib.zstdDecompressSync` 又只解第一帧，需要自己按帧扫描 |
| 插件端 | **0.2.14**：新增会话存档 `session-archive.json`（`ARCHIVE_INTERVAL_MS = 30s`、`ARCHIVE_MAX_EVENTS = 1500`、`ARCHIVE_TEXT_MAX = 4000`、`ARCHIVE_RECORD_MAX = 400`），`absorbLiveSession` 吸运行中会话、`splitZstdFrames` + `readSessionLogText` 从磁盘逐帧解压恢复、`scanSessionsOnDisk` 只补缺失会话；路由 `GET/POST /api/v1/desktop/archive/sessions`、`GET /api/v1/desktop/archive/sessions/:id` |
| 手机端 | `ArchivedSession` + `archivedSessions/archivedSession/postArchivedSession`；`LiveStore` 的 `loadArchivedSessions`（404/501 静默降级）、`hiddenArchivedSessions`、`fetchArchivedSession`、`uploadArchivedSession`；直播页新增 `archived`（不轮询、底部换只读说明条、标题加「已存档」）；任务页/工作区页底部新增「以前跑过、电脑上已经看不到的会话（N）」分组 |
| 版本 | App **0.4.10+37 / 0.4.10-m4.10**；插件 **0.2.14** |
| 测试 | `flutter test` **321/321**（315 + M4.10 新增 6：`app/test/archive_m4_10_test.dart`）；插件 `node --test` **15/15** |
| 静态检查 | `flutter analyze` 23 issues、**0 error** |
| 构建 | **release APK 72,343,942 字节**（`versionCode=37`，SHA256 `29153E7E…657A03D5`，签名沿用 debug 密钥可覆盖安装）；已发布 `dist\DeepSeek-Remote-AI-v0.4.10-m4.10.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.10-m4.10.apk` |
| 插件自检 | `tools\verify-plugin-m4.ps1` 门槛升到 0.2.14，新增「GET /desktop/archive/sessions 有会话存档」，共 **14 项**；现网仍是 0.2.13（DSH 未重开），存档接口 404，重启前基线未跑 |
| 真机 | **未复测**：`adb devices` 无设备；存档分组与只读直播仅单测覆盖 |
| 已知限制 | 存档只能看不能继续发指令；扫描只补缺失会话，单会话最多 1500 条事件、正文每段 4000 字、最多 400 条会话；需插件 0.2.14+（旧插件 404 时手机端不显示该组）；`session-archive.json` 在 DSH 重开后由 30 秒定时器生成 |
| 文档 | `docs/research/M4_10_REPORT.md`、`docs/mobile/API_CONTRACT.md`（v0.4.10 新增「会话存档」一节）、`docs/mobile/SIGNING.md`（321）、`docs/mobile/README.md`（M4.10 两段 + §8 第 27 条），根 `README.md` 已同步 |

> **下一步**：完整退出 DSH 重开（加载插件 0.2.14，约 30 秒后生成 `session-archive.json`）→ `tools\verify-plugin-m4.ps1` 期望 14/14 → 装 `dist\DeepSeek-Remote-latest.apk`（0.4.10-m4.10）重新配对 → 工作区页滚到底应看到「以前跑过、电脑上已经看不到的会话」。

### M4.11 工作区页不再「看起来项目全丢了」（2026-11-16 补充）

| 项 | 结果 |
| --- | --- |
| 用户诉求 | 「为什么又看不到所有的项目了」——重启后工作区页只剩 1 个卡片 |
| 根因 | 工作区卡片只从 `GET /desktop/tasks` 派生；DSH 重开后 Host 只列出已物化的会话，列表一空，授权的目录就只剩顶部胶囊 |
| 手机端 | `tasks_screen.dart` 新增 `_idleWorkspaces` + `_WorkspaceCard`：没有会话/存档的授权目录也占一张「暂无会话」卡，点进去可新建会话 / 看存档 / 浏览文件；`_hiddenArchived` 不再只在「已完成」筛选下显示 |
| 插件端 | 0.2.19：`isScratchWorkspace()` 让 `agent\.m1ws`、`agent\.workspaces\contract-*` 等测试目录不进存档列表（存量记录不删、只是不展示）；`node:fs` 导入补 `statSync`（`resolveUploadDir` 用它，缺了会在运行期抛 `statSync is not defined`） |
| 版本 | App **0.4.11+38**（`0.4.11-m4.11`）；插件 **0.2.19** |
| 测试 | `flutter test` **327/327**（321 + 新增 6：`app/test/tasks_m4_11_test.dart`）；插件 `node --test` **30/30**（26 + 新增 4：`test/archive-scratch.test.js`） |
| 静态检查 | `flutter analyze` **24 issues、0 error**；`node --check lib/index.js lib/server.js` 通过 |
| 构建 | release APK **72,343,942 字节**，SHA256 `6B4CB2FC0F0A8C5915F3A305AE1F6206F77375A317A83232F9B7DB4ADE9CB361`；aapt2 `versionCode='38' versionName='0.4.11-m4.11'`；签名 `CN=Android Debug`（SHA-256 `341ef83b…70d6`，可覆盖安装） |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.11-m4.11.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.11-m4.11.apk`；`GET /api/v1/app/version` 已返回 38 / `0.4.11-m4.11` |
| 插件自检 | `tools/verify-plugin-m4.ps1` 门槛升到 0.2.19，仍 14 项（需重开 DSH 加载 0.2.19 后复跑，期望 14/14） |
| 真机 | 未复测（`adb devices` 无设备），页面行为由 widget 测试覆盖 |
| 文档 | `docs/research/M4_11_REPORT.md`、`docs/mobile/README.md`、`docs/mobile/SIGNING.md`、本文件、根 `README.md` |

> **下一步**：完整退出 DSH 重开（加载插件 0.2.19）→ 跑 `tools\verify-plugin-m4.ps1` 期望 14/14 → 手机装 `dist\DeepSeek-Remote-latest.apk` → 「工作区」页应当每个授权目录都有卡片。

### M4.12 对话正文按 Markdown 排版（2026-11-16 补充）

| 项 | 结果 |
| --- | --- |
| 用户诉求 | 发来官方 App 对话截图问「你的对话不能做成这样的吗」；选项确认后定为「只改渲染样式，电脑档 + 云端对话都生效」 |
| 根因 | 数据链路没问题，问题在正文渲染：助手回复只认 `**加粗**` 与 `` `代码` ``，`###` 标题、`- ` 列表、三反引号代码块、`|` 表格全部**原样露字** |
| 手机端 | 新增 **`app/lib/widgets/markdown_text.dart`**（零 pub 依赖）：`MarkdownParser.parse()` → `MdBlock`（`heading/paragraph/bullet/ordered/quote/code/table/rule`）、`buildInlineSpans()` 行内加粗/代码/删除线/链接/斜体、`MarkdownText` 块级排版、`_MarkdownCodeBlock`（语言标签 + 「复制」）、`_MarkdownTable`（表头底色 + 分隔线）。`chat_items.dart` 的 `_AssistantText` 改用 `MarkdownText`，时间并入新增 `_AnswerActions`（复制 + 时间）；`cloud_chat_screen.dart` 的 `_Bubble` 去掉 320 宽上限与边框卡片，助手消息无气泡直接排版、用户消息保留气泡；`app_theme.dart` 的 `fontFamilyFallback` 补 `Noto Sans CJK SC` / `Source Han Sans SC` |
| 设计取舍 | 不引 `flutter_markdown`（项目惯例零新增 pub 依赖）；中文标题/加粗用 `FontWeight.w600` 而非 `w700`（CJK 没有真粗体，w700 是系统伪加粗，手机上发糊） |
| 插件端 | 0.2.20：`knownWorkspacePaths()` + `findWorkspaceByName()`，`resolveUploadDir` 改为先按名字命中**工作区列表**（`listDesktopWorkspaces()`）再找授权根，修「附件悄悄落回 `%USERPROFILE%\.dsh\dsh-plugin-m1\uploads`」 |
| 版本 | App **0.4.12+39**（`0.4.12-m4.12`）；插件 **0.2.20** |
| 测试 | `flutter test` **344/344**（327 + 新增 17：`app/test/chat_markdown_m4_12_test.dart`）；插件 `node --test` **31/31**（30 + 新增 1：`test/upload-dir.test.js` 第 3 例） |
| 静态检查 | `flutter analyze` **本机不可用**（中文路径导致 analysis server 崩在 `FormatException: Unterminated string`），以 `flutter test` 全量编译代替；`node --check lib/index.js lib/server.js` 通过 |
| 构建 | release APK **72,589,702 字节**，SHA256 `A261B70E713C71D8A712111F37C65A32D42BBBC0E0B5B7E3B39C588F8CCCB4DB`；aapt2 `versionCode='39' versionName='0.4.12-m4.12'`；`apksigner` 签名 `CN=Android Debug`（SHA-256 `341ef83b…70d6`，可覆盖安装） |
| 构建坑 | 本机中文路径下 AOT 快照必挂：`Error: Unable to read file: D:\<乱码>\app\.dart_tool\flutter_build\<hash>\app.dill` / `AOT snapshotter exited with code 255`。解法：`robocopy app C:\Users\user\dsh-tools\build\dsh-app /E /XD build .dart_tool .gradle .idea .cxx` 后在该 ASCII 目录构建（与 analyzer 崩是同一个中文路径根因） |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.12-m4.12.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.12-m4.12.apk`；`GET /api/v1/app/version` 已返回 `versionCode 39 / 0.4.12-m4.12 / size 72589702` |
| 插件自检 | `tools/verify-plugin-m4.ps1` 门槛升到 0.2.20（3 处），上传检查改为优先选「路径末段 = 工作区名」的工作区；**该脚本在 PowerShell 5.1 下自身解析报错（15 个 syntax error），本轮未能跑 14/14**，自检改用直接调 REST 接口核对 |
| 真机 | **未复测**（`adb devices` 无设备），排版由 widget 测试覆盖 |
| 文档 | `docs/research/M4_12_REPORT.md`、本文件、根 `README.md` |

> **下一步**：完整退出重开 DSH（加载插件 0.2.20）→ 修好 `tools\verify-plugin-m4.ps1` 的 PS 5.1 解析问题后跑 14/14 → 手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.12-m4.12）→ 电脑档问一个带代码块/表格的问题，核对排版。

### M4.13 工作区按项目分组 + 新建项目固定落 `D:\Projects\项目`（2026-11-16 补充）

| 项 | 结果 |
| --- | --- |
| 用户诉求 | 「按照工作区项目分类，做成和电脑上一样的，可以折叠打开，并且可以新建对话，新的项目区是建立在电脑端"D:/用户/项目"这个文件里面」；追问后定：「先只做新建项目，新建对话以后再说」+「固定建在 `D:\Projects\项目`」 |
| 根因 | 工作区页是**平铺的会话卡**：任务卡 + 空目录卡 + 底部「以前跑过、电脑上已经看不到的会话」存档组，三摊各排各的，同目录的多个会话各占一张，完全看不出归属 |
| 手机端 | 新增 **`app/lib/services/project_groups.dart`**（零依赖纯函数：`ProjectGroup`、`projectNameOf`、`parentPathOf`、`groupWorkspacesByProject`）；`tasks_screen.dart` 把三摊列表换成 `_ProjectGroupCard` 列表（头部整行点折叠/展开，`_collapsed` 记路径；展开后 `_SessionRow` 左侧 3×16 竖线按 等待授权/运行中/其他 着色），**删除 `_WorkspaceCard`**；空目录标「空项目」胶囊；胶囊文案 `新建工作区` → `新建项目`；`workspace_create_dialog.dart` 新增 `kDefaultProjectParent = r'D:\Projects\项目'`，授权根包含项目根时 `parentDir` 固定成它，否则退回第一个授权根并提示 |
| 插件端 | 0.2.20 内置：`DEFAULT_PROJECT_PARENT`、`resolveParentDir()`（授权根本身/子目录，或目录真实存在）、`projectParentPath()`；`createDesktopWorkspace(name, parentDir)`；`listDesktopWorkspaces()` 每行加 `parent` 与 `isProject`；`server.js:307-330` 透传 `body.parentDir` |
| 版本 | App **0.4.13+40**（`0.4.13-m4.13`）；插件 **0.2.20** |
| 测试 | `flutter test` **353/353**（344 + 新增 7：`app/test/project_groups_m4_13_test.dart`，+ `workspace_m4_test.dart` 新增 2 例）；插件 `node --test` **39/39**（31 + 新增 8：`test/workspace-create.test.js`） |
| 测试适配 | `tasks_m4_11_test.dart` 的 `暂无会话` 断言改 `空项目`、「以前跑过…」存档组断言改按项目卡断言；`archive_m4_10_test.dart` 的存档组断言改「挂在所属项目卡里」；`workspace_m4_test.dart` 折叠用例改点 `find.text('demo').last` + `pumpAndSettle`；版本断言改 0.4.13+40 |
| 构建 | release APK **72,589,702 字节**，SHA256 `111DFFA562204C96A6874CF51A9A24266F3C901D4171BBA4654394D1144FDEB0`；aapt2 `versionCode='40' versionName='0.4.13-m4.13'`，minSdk 24 / targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.13-m4.13.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.13-m4.13.apk`；`GET /api/v1/app/version` 返回 `versionCode 40 / 0.4.13-m4.13 / size 72589702` |
| 插件安装副本 | `lib/index.js`、`lib/server.js`、`package.json` 三方哈希与源码树一致、version 0.2.20（`Copy-Item` 报「正由另一进程使用」，实际已同步） |
| 真机 | **未复测**（`adb devices` 无设备），分组/折叠/新建由 widget 测试覆盖 |
| 文档 | `docs/research/M4_13_REPORT.md`、本文件、根 `README.md`、`docs/mobile/README.md` |

> **下一步**：**完整退出 DSH 重开**（加载插件 0.2.20，`GET /api/v1/health` 的 `version` 应变成 `0.2.20`）→ 手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.13-m4.13，versionCode 40，可覆盖安装）→ 工作区页应看到按目录折叠的项目卡，点「新建项目」应真的建在 `D:\Projects\` 下。之后再谈「在项目里新建会话」。

### M4.14 直播页不再空手：首屏拉够正文 + 授权窗口放宽（2026-11-16 补充）

| 项 | 结果 |
| --- | --- |
| 用户诉求 | 两条反馈：「每次点进去加载不出来对话」（截图：直播中 · 0 条消息 + 过程 41 步 + 空态）、「这个需求的选择手机上没有出来也没有提醒」（截图：电脑端「确认需求」卡已用时 15 分 8 秒） |
| 根因 ① | 插件 `listDesktopSessionEvents` 首屏只从日志尾部倒取 **80 条已映射事件**；忙会话这 80 条可能全是 `tool-call`/`tool-result`（实测 36+35），App 只留 user/assistant → 正文 0 条 → 空态。带 `afterSeq` 时旧代码**从头往后扫**并 `break`，积压时只回最早几条（实测 `afterSeq=0&limit=80` 只回 seq=8、20），增量永远追不上 |
| 根因 ② | `WATCH_WINDOW_MS = 2min`：App 切后台/锁屏后 1.5 秒轮询停止，「不算在看」→ 授权一律交回桌面弹窗；`APPROVAL_TIMEOUT_MS = 90s` 超时 `finish('unavailable')` **不写日志**，手机上不留任何痕迹 |
| 插件端 | 0.2.21：`MIN_CHAT_EVENTS = 12` / `MAX_TAIL_EVENTS = 600` / `CHAT_KINDS`，首屏倒扫到「够 12 条对话或 600 条」再 `reverse()`；增量改为**从尾部倒扫** `if ((Number(log[i]?.seq) || 0) <= afterSeq) break;`；`WATCH_WINDOW_MS = 10 * 60 * 1000`、`APPROVAL_TIMEOUT_MS = 2 * 60 * 1000`；超时先 `log('接管授权超时，已退回电脑：…')` 再 `finish('unavailable')` |
| 手机端 | `desktop_session_screen.dart`：顶栏在 `_approvals` 非空时挂「待应答 N」红底胶囊（正文滚下去也看得见）；空态文案抽成 `liveEmptyHint({required bool hasEvents})`，区分「这个会话还没有可展示的内容」与「这一屏只有工具调用，点上面的「过程」看完整记录」 |
| 版本 | App **0.4.14+41**（`0.4.14-m4.14`）；插件 **0.2.21** |
| 测试 | 插件 `node --test` **46/46**（39 + 新增 7：`test/session-events.test.js`）；`flutter test` **356/356**（353 + 新增 3：`app/test/desktop_live_m4_14_test.dart`） |
| 构建 | release APK **72,589,702 字节**，SHA256 `4FF436085E9F918E98924481E3C6563EBFD4D1D5615D7829D5472B3470C9F9D8`；aapt2 `versionCode='41' versionName='0.4.14-m4.14'`，minSdk 24 / targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.14-m4.14.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.14-m4.14.apk`（三处同哈希） |
| 插件安装副本 | `lib/index.js`、`lib/server.js`、`package.json` 哈希与源码树一致、version 0.2.21（`Copy-Item` 报「正由另一进程使用」，实际已同步） |
| 未能核对 | 交付时 `127.0.0.1:8787` **未监听**（Host 已退出/重启中），`GET /api/v1/app/version` 与 `/api/v1/health` 都连不上，故本轮没能用接口回读版本号；APK 三处哈希已用 `Get-FileHash` 本地核对 |
| 真机 | **未复测**（`adb devices` 无设备） |
| 文档 | `docs/research/M4_14_REPORT.md`、本文件、根 `README.md`、`docs/mobile/README.md` |

> **下一步**：**完整退出 DSH 重开**（加载插件 0.2.21，`GET /api/v1/health` 的 `version` 应为 `0.2.21`）→ 手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.14-m4.14，versionCode 41，可覆盖安装）→ 点进一个正在跑的会话，正文应真的有内容（不再是 0 条）→ 电脑上触发一次授权，若手机停在该会话的直播页，应看到授权卡与顶栏「待应答 1」。若手机被系统冻结导致没接管，则属于「真正的推送提醒」范畴（需走 M4.4 通知通道），列为后续独立一轮。

### M4.14.1 插件掉线（8787 不监听）的排查与恢复（2026-11-16 补充）

| 项 | 结果 |
| --- | --- |
| 现象 | 用户反馈「插件怎么没了，连不上了」：`127.0.0.1:8787` 不监听，手机连不上 |
| 根因 | **不是代码坏了**：profile `C:\Users\user\.dsh\profiles\desktop\package.json` 的 `dsh.profile.bundles` 里没有 `dsh-plugin-m1`（`plugin_manager` 回报该 bundle `enabled: false`），所以那次 DSH 启动根本没加载插件。`C:\Users\user\.dsh\profiles\desktop\package.json` 的 mtime 是 15:35:24，与本会话的改动时间不重合，具体是谁把它摘掉的没有留下日志（`.plugin-manager\logs` 最后一条操作是 10:22） |
| 恢复 | `plugin_manager` `set_bundle(target=dsh-plugin-m1, enabled=true)` → `applied`，**热加载生效，不用重开 DSH**；`GET /api/v1/health` 立刻回到 `{"status":"ok","version":"0.2.21","agentOnline":true}`，说明 M4.14 的插件改动已经真的在跑 |
| 连带问题 | cloudflared **快速隧道**每次重启都会换一个随机域名（本次 `https://<公网隧道>.trycloudflare.com`），手机里存的是旧地址 → 光把插件起来还是连不上，**手机要重新配对** |
| 重新配对 | 浏览器打开 `http://127.0.0.1:8787/pair`（页面已确认含新公网地址），配对码 `000000`；同 Wi-Fi 也可用局域网地址 `http://192.168.1.x:8787`（不随隧道重启而变） |
| 线上验证 | 用真实手机 token 复测：`GET /desktop/tasks` 正常；`GET /desktop/sessions/<id>/events`（无 `afterSeq`）→ `events=80`、**`chat=17`**（M4.14 前同条件是 0 条正文）；`afterSeq=lastSeq-40` → 返回 `13` 条、`seq` 落在 `4513…4550`（最新一段，不再是积压时的最早几条） |
| 待跟进 | ①`dsh.profile.bundles` 里的 `dsh-plugin-m1` 为什么会消失，需要盯一次下次重启是否复现；②隧道地址每次重启都变，长期应配 `config.publicUrl`（自建固定域名/named tunnel），否则每次重启都要重新配对 |

### M4.15 新建项目落点修对（2026-11-17 补充）

| 项 | 结果 |
| --- | --- |
| 现象 | 用户 16:14 截图反馈「新项目要建立的位置不对」：新建对话框提示「将建在: D:\Projects\课程\上册\计算方法实验」 |
| 截图里的第二个问题 | 标题仍是「新建工作区」、label 仍是「工作区名称」→ 手机上装的还是 M4.13 之前的旧 APK（M4.13 已改成「新建项目 / 项目名称」）。所以「装新版就好」不成立，落点逻辑本身也错 |
| 根因 | `app/lib/widgets/workspace_create_dialog.dart` 的 `_usesProjectParent` 要求 `liveStore.workspaceRoots` 里**恰好有一项等于** `D:\Projects\项目`；但 `GET /desktop/workspaces` 返回的 9 条全是具体项目（`…\项目\deepseek手机端` 等），`…\项目` 是它们的**父目录**，从不在列表里 → 判成「没授权」→ `parentDir: null` → 插件 `resolveParentDir(null)` 退回第一个授权根（本例 `…\计算方法实验`） |
| 插件端 | **一行未改**：现场用手机 token 实测 `POST /desktop/workspaces` `{"name":"m4-14-probe-161524","parentDir":"D:\\Projects\\项目"}` → `{"ok":true,"path":"D:\\Projects\\m4-14-probe-161524","parent":"D:\\Projects\\项目"}`，`…\计算方法实验\m4-14-probe-161524` 不存在，探针目录事后已删。0.2.21 的 `resolveParentDir()` 本来就是「显式指定且目录真实存在就放行」，M4.13 只需要把 `parentDir` 传对 |
| 手机端 | 删掉 `_rootHint` / `_usesProjectParent`，改为 `String get _targetParent => kDefaultProjectParent`（去尾反斜杠），`_submit` 无条件 `parentDir: _targetParent`；提示文案统一成 `'将建在：$_targetParent\\$_preview'`（全角冒号），删除「电脑端还没授权根目录」「先建在第一个授权目录下」两个已不存在的分支 |
| 测试 | `app/test/workspace_m4_test.dart` 的「成功创建后关闭并返回结果」改断言 `find.textContaining(kDefaultProjectParent)`、`store.parents == <String?>[kDefaultProjectParent]`、`result?.path == '$kDefaultProjectParent\\新项目'`；该 fake store 只授权 `D:\work`，正是「授权根里没有项目根」的真实场景，构成回归保护 |
| 版本 | App **0.4.15+42**（`0.4.15-m4.15`）；插件仍 **0.2.21** |
| 测试结果 | `flutter test test/workspace_m4_test.dart` 14/14；全量 `flutter test test/` **356/356 PASS** |
| 构建 | release APK **72,589,702 字节**，SHA256 `3AA815BE6D58D4C1AC21C7FFAB8CA8E7A12DC475BE72DBC9B79142B64FD2B023`；aapt2 `versionCode='42' versionName='0.4.15-m4.15'`，minSdk 24 / targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.15-m4.15.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.15-m4.15.apk`（三处同哈希 `3AA815BE6D58D4C1`） |
| 回读 | `GET /api/v1/app/version` → `{"versionCode":42,"versionName":"0.4.15-m4.15","size":72589702,"sha256":"3aa815be…","publishedAt":"2026-11-16T08:23:39.274Z"}`；`GET /api/v1/health` → `{"status":"ok","version":"0.2.21","agentOnline":true,"apps":2,"publicUrl":"https://<公网隧道>.trycloudflare.com"}` |
| 真机 | **未复测**（无 adb 设备） |
| 文档 | `docs/research/M4_15_REPORT.md`、本文件、根 `README.md`、`docs/mobile/README.md` |

> **下一步**：手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.15-m4.15，versionCode 42，可覆盖安装）→ 新建对话框应显示「新建项目 / 项目名称」且提示「将建在：D:\Projects\<名字>」→ 建完到电脑 `D:\Projects\<名字>` 确认目录真的在那儿。若仍显示「新建工作区」，说明手机没装上（覆盖安装失败），需先卸载旧版。手机若连不上，先看 `GET /api/v1/pair/info` 的当前公网地址与配对码（快速隧道每次重启都变）。

### M4.16 手机看到的必须是对话，而且一进来就是最新（2026-11-17 补充）

| 项 | 结果 |
| --- | --- |
| 现象 | 用户 16:15 截图（桌面直播页 · 已存档 · 已结束 78 条消息 · 过程 0 步）反馈「每个对话里面的内容你不应该放到最新的吗，而且你这英文是什么，我要的是对话」；正文第一条是 `Time sampled while preparing turn 3, step 24: …`（Host 注入），第二条是 `Header empty. So where does blue come from?…`（模型推理） |
| 根因 ① | 注入没过滤：`INJECTED_USER_PREFIXES` 缺 `'Time sampled while preparing'`，且**存档写入路径 `archiveEvent` 根本没调用过滤**（只有直播路径 `mapDesktopEvent` 调）——`lib/index.js:1095-1102` / `:484-498` |
| 根因 ② | 推理当回复：`assistantText()` 在没有正文 part 时 `const chosen = texts.length > 0 ? texts : others;` 回退到全部 part ——`lib/assistant-text.js:33-46` |
| 根因 ③ | 没停在最新：`_scrollToEnd(force: true)` 用 `jumpTo(position.maxScrollExtent)`，而 `ListView.builder` 首帧 `maxScrollExtent` 只覆盖已构建的几屏，长列表跳不到真正底部 ——`desktop_session_screen.dart:353-365` |
| 取证 | 截图会话 = `session-4670a31a-a988-4afc-a91c-537bdd91fe28`（380 事件、messageCount 495）；按 App 规则过滤后正好 **78 条**（与截图一致），`Time sampled…turn 3, step 24` 在第 **30** 条、紧接第 31 条就是「Header empty…」→ 视图停在中段 |
| 附带问题 | `GET /desktop/archive/sessions/<id>` 只回 `sessionId/running/lastSeq/events`，无 title/cwd，App 回落成「桌面会话 / 电脑上的会话」，所有存档长得一样 |
| 插件端 0.2.22 | 新建 `lib/chat-filter.js`（11 条注入前缀含 `Time sampled while preparing`、4 条特征串、只扫前 160 字符、`isInjectedUserText`/`chatText`/`isInjectedEvent`）；`assistantText` 删掉 reasoning 回退（无正文返空串）；`archiveEvent` 写入时过滤、`mapDesktopEvent` 改用同一份规则、`getArchivedSession` 读取时再滤一遍；archive-one 补 `title/cwd/lastTime/messageCount`；新增 `ARCHIVE_EVENT_SCHEMA = 2` + `findSessionLogFile()` + `migrateLegacyArchiveEvents()`（对含注入的老记录按磁盘日志重读） |
| 迁移取证 | 该会话存档过滤后 380 → **342** 条事件（`Time sampled` / `Current runtime context` / `<system-reminder` 全消失）；磁盘日志 3252 行、447 条 assistant 里只有 **9 条**有正文（438 条纯推理）→ 重读后手机只剩真实回复 |
| 手机端 0.4.16+43 | 新建 `lib/services/chat_filter.dart`（同一份前缀表）+ `_messages` 的 user 分支先过滤；列表改 `reverse: true`、`messages[messages.length - 1 - index]`、`_scrollToEnd` 改 `jumpTo(0)`/`animateTo(0)`；`_atLatest` + `_onScroll`（`pixels < 160`）；`_LiveFooter` 三态文案（含「往上是更早的对话 · 点这里回到最新」可点） |
| 测试 | 插件 `node --test "test/*.test.js"` **51/51 PASS**（46 + `test/chat-filter.test.js` 5 例；`assistant-text.test.js` 旧「回退」用例改断言空串）；`flutter test test/` **361/361 PASS**（356 + `app/test/chat_filter_m4_16_test.dart` 5 例） |
| 构建 | release APK **72,655,282 字节**，SHA256 `1BE7856E9B16281CAA4F0A09BC55F5806345E05F861C25483C357300B389CAB6`；aapt2 `versionCode='43' versionName='0.4.16-m4.16'`，targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.16-m4.16.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.16-m4.16.apk`（三处同哈希） |
| 回读 | `GET /api/v1/app/version` → `{"versionCode":43,"versionName":"0.4.16-m4.16","size":72655282,"sha256":"1be7856e…","publishedAt":"2026-11-16T09:10:37.749Z"}`；`GET /api/v1/health` 仍 `version 0.2.21`（插件未重载） |
| 插件重载受阻 | `plugin_manager set_bundle(target=dsh-plugin-m1, enabled=false)` 连试两次均 `{"application":"failed","error":{"diagnostic":"HMR transactions cannot be nested"}}`；安装副本五文件哈希已与源码树一致，**但必须完整退出重开 DSH** 才跑 0.2.22 |
| 踩坑 | 不要用 `(Get-Content -Raw) -replace … \| Set-Content` 改含中文的 UTF-8 文件：PS 5.1 按 GBK 解码会双编码乱码并吞掉行尾换行（`pubspec.yaml` 的 `publish_to` / `open_filex`、`package.json` 的 description 收尾引号就是这样坏的）。已从 `C:\Users\user\dsh-tools\build\dsh-app` 的 ASCII 副本还原三个配置文件，并去掉 BOM |
| 真机 | **未复测**（无 adb 设备） |
| 文档 | `docs/research/M4_16_REPORT.md`、本文件、根 `README.md`、`docs/mobile/README.md` |

> **下一步**：**完整退出 DSH 重开**（加载插件 0.2.22，`GET /api/v1/health` 的 `version` 应为 `0.2.22`；启动日志应出现「会话存档已按新规则重读：…」）→ 手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.16-m4.16，versionCode 43，可覆盖安装；若隧道域名变了要重新配对）→ 点进任意会话：正文只应有人说的话与模型的回复，一进来就停在最新一条，往上翻时底部提示能点回最新。若旧存档里仍夹着英文片段，说明该会话的磁盘日志已被清理、洗不回来了。

### M4.17 桌面直播的对话排版对齐官方 App（2026-11-17 补充）

| 项 | 结果 |
| --- | --- |
| 现象 | 用户 17:27 再贴官方 App 对话截图，配文「对话做成这样」。M4.12 给了 Markdown 排版、M4.16 洗了正文，但页面骨架仍是自己的：助手回复套着浅底卡片 + 左侧 3px 强调竖条、工具记录写「过程 · N 步（点开看）」、顶部是一张 Panel 卡片且副标题直接怼 `D:\Projects\…` 绝对路径 |
| 手机端 0.4.17+44 | `desktop_session_screen.dart`：`itemBuilder` 去掉助手回复的卡片包装（`return _EventRow(event: event);`）；工具条改 `'${_running ? '进行中' : '已完成'} · ${_toolCallCount} 次工具调用'` + `Icons.autorenew_rounded`/`Icons.check_circle_outline_rounded` + `Icons.expand_more_rounded`，圆角 12；`_LiveHeader` 改 radius 22 胶囊（`palette.card` 底 + `palette.line` 边框），副标题 `'本机 · $folder'`；新增顶层 `desktopFolderName(String cwd)` 取路径最后一段；`liveEmptyHint` 的提示语从「点上面的『过程』」改成「点上面那条看完整记录」 |
| 测试 | `flutter test test/` **366/366 PASS**（361 + 新增 `app/test/desktop_live_m4_17_test.dart` 5 例）；`desktop_live_m4_14_test.dart` 的空态断言改用「工具调用」 |
| 构建 | release APK **72,655,418 字节**，SHA256 `5403BC368E0238586D610358A44E949067682D62BDA606FE5A97137E3F6797AC`；aapt2 `versionCode='44' versionName='0.4.17-m4.17'`，minSdk 24 / targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.17-m4.17.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.17-m4.17.apk`（三处同哈希） |
| 回读 | `GET /api/v1/app/version` → `{"versionCode":44,"versionName":"0.4.17-m4.17","size":72655418,"sha256":"5403bc36…","publishedAt":"2026-11-16T23:43:32.764Z"}`；`GET /api/v1/health` → `version 0.2.22`（插件已随 DSH 重开生效，`apps:2`） |
| 插件端 | 不需要改 |
| 真机 | **未复测**（无 adb 设备） |
| 文档 | `docs/research/M4_17_REPORT.md`、本文件、根 `README.md`、`docs/mobile/README.md` |

> **下一步**：手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.17-m4.17，versionCode 44；隧道域名已变为 `https://<公网隧道>.trycloudflare.com`，`GET /api/v1/pair/info` 取配对码重新配对）→ 进任意会话确认三处：回复没有边框卡片、工具那行写「已完成 · N 次工具调用」、顶部写「● 本机 · 目录名」。仍与官方有差距的三处（回复底部只有复制、直播页无头像、步骤条点开是半屏面板而非内联展开）记在 M4.17 报告的「限制与下一步候选」。

### M4.18 插件市场与电脑端同步（2026-11-17 补充）

| 项 | 结果 |
| --- | --- |
| 现象 | 用户 07:49：「插件市场是和电脑上同步的，不要现在这样的」。手机市场页只有「输入关键字搜索电脑端插件市场」，搜完仍是空；同一台电脑的电脑端市场列着 42 个插件包 |
| 根因 | 手机市场只读 Host `pluginMarket.listIndexes()`，也就是「设置 → 插件市场」里**手动配置**的第三方索引——这台电脑一个都没配，于是 `indexes=0 entries=0`；电脑端自己的市场来自 `pluginManager.listBundles()`，手机走的接口完全没用它 |
| 电脑端插件 0.2.23 | 新增 `localizedMetaText(meta, field, language)`（`meta` 平铺 / 按语言分键 / 语言键直接是字符串三种形状都认，`zh-CN → zh → en` 依次退）；新增 `pluginCatalog({language})` 映射 `listBundles()`（`spec`/`official`/`installed`/`removable`/`availability`/`listedByDefault` 等），`pluginManager` 不可用时返回 `{supported:false,bundles:[]}`；`server.js` 新增 `GET /api/v1/desktop/plugins/catalog?language=zh-CN`（走 App token，失败 501 `PLUGIN_CATALOG_UNAVAILABLE`） |
| 手机端 0.4.18+45 | `MarketEntry` 加 `official`/`spec`/`availability`/`removable`/`enabled`；新增 `PluginCatalog` 与 `HistoryApi.listPluginCatalog`、`LiveStore.pluginCatalog()`；市场页主来源改目录（进页面自动读、搜索在本地过滤、按钮「刷新」），安装按目录的 `spec` 下发，装/卸后重读目录；卡片加「官方」胶囊，概览行「N 个插件 · 电脑端插件市场 · 已安装 M 个」 |
| 测试 | 插件 `node --test "test/*.test.js"` **57/57 PASS**（51 + 新增 `test/catalog.test.js` 6 例）；`flutter test test/` **369/369 PASS**（366 + 新增 `app/test/plugin_catalog_m4_18_test.dart` 3 例；`plugin_market_test.dart` 旧电脑端降级用例改断言新的「读取目录」提示） |
| 线上接口 | `GET /api/v1/desktop/plugins/catalog?language=zh-CN` → `supported=true`、**42 个插件包**；`@deepseek-ai/dsh-experimental-auto-review` `official=true`；`dshmarket`/`dsh-our-free-model`/`billion-context` `installed=true` |
| 插件生效方式 | `plugin_manager set_bundle` 停用再启用，两次都 `application:"applied"` → `GET /api/v1/health` 变成 `version 0.2.23`（**本次热加载成功，不需要重开 DSH**；M4.16 那次失败是因为 HMR 事务嵌套） |
| 构建 | release APK **72,720,954 字节**，SHA256 `985AA277A631D82D07A9A8A68F7AD2C1B9C51BD6B8B65B8A401E556B6115E921`；aapt2 `versionCode='45' versionName='0.4.18-m4.18'`，minSdk 24 / targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.18-m4.18.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.18-m4.18.apk`（三处同哈希） |
| 回读 | `GET /api/v1/app/version` → `{"versionCode":45,"versionName":"0.4.18-m4.18","size":72720954,"sha256":"985aa277…","publishedAt":"2026-11-17T00:12:57.517Z"}`；`GET /api/v1/health` → `version 0.2.23` |
| 真机 | **未复测**（无 adb 设备） |
| 文档 | `docs/research/M4_18_REPORT.md`、本文件、根 `README.md`、`docs/mobile/README.md` |

> **下一步**：手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.18-m4.18，versionCode 45，可覆盖安装；隧道域名又变了，现为 `https://<公网隧道>.trycloudflare.com`，先在电脑端重新扫码配对）→ 打开「插件 → 插件市场」，应直接列出电脑上的 42 个插件包（带「官方」标记与已安装状态），搜索是本地过滤，装完回来能看到「已安装 + 卸载」。目录里的中文标题依赖 Host 返回 `meta`，这台电脑目前没有，所以标题显示为包名——等 Host 补上本地化文案会自动生效。

### M4.19 存档会话也能继续聊（2026-11-17 补充）

| 项 | 结果 |
| --- | --- |
| 现象 | 用户 08:17：「已存档的对话手机上也可以对话」。存档页底部写着「这是电脑端存档的会话，只能看不能继续发指令」，输入框根本没渲染 |
| 死路 A（唤醒旧会话） | `sessionController.resolveAgent(id)` 后直接 `prompt(id)`：接口返回 `{"ok":true,"accepted":true}`、会话回到 `/desktop/tasks`，但磁盘日志只有 `turn/start {turn:2}` → `agent/inbox/spliced {removedCount:1, inserted:[]}` → `turn/end {reason:{kind:'blocked'}}`，没有 `user/message`、没有 `assistant/message` → 消息被吞 |
| 死路 B（fork 旧会话） | `sessionController.fork({sessionId, allowMigration:true})` 再 prompt：小会话（2 条消息）成功回复「收到」；大会话（1235 条消息）被挡在出口：`outbound body measures ~1,735,026 tokens（messages ~153,989 · tools[] ~13,494 · system ~4,560 · other ~1,562,983）vs the effective model window 1,048,576 … stopped at the egress fuse` → 长会话必然超窗 |
| 最终做法（插件 0.2.24） | `lib/index.js` 新增 `buildArchiveDigest()`（存档里最近 `ARCHIVE_DIGEST_MESSAGES=12` 条、每条截到 `ARCHIVE_DIGEST_CHARS=360` 字，包成「接着…继续聊《标题》」+「（历史到此结束，下面是用户的新消息）」）与 `createSuccessorSession()`（`sessionController.create({ cwd: record.workspace })` **原目录新开一条**）；`promptDesktopSession` 三段：活跃直接发 / 存档里也没有 → `SESSION_NOT_FOUND` / 否则新开会话 + 发摘要，返回 `{forked:true, forkedFrom, sessionId}`；错误码区分 `SESSION_NOT_FOUND` / `SESSION_CREATE_UNSUPPORTED` / `SESSION_NOT_RESUMABLE`；`server.js` 把 `SESSION_NOT_FOUND` 映射成 404 |
| 手机端 0.4.19+46 | 存档页也渲染输入条；说明条改「存档会话 · 发一句话，电脑会把它恢复成一条新会话，接着在这里聊」；`sendDesktopPrompt` 返回 `DesktopPromptResult { sessionId, forked, forkedFrom }`，`forked` 且 id 变了就用 `pushReplacement` 跳进新会话并开始直播轮询 |
| 测试 | 插件 `node --test "test/*.test.js"` **66/66 PASS**（57 + 重写的 `test/session-resume.test.js` 9 例）；`flutter test test/` **371/371 PASS**（369 + `archive_chat_m4_19_test.dart` 2 例；`archive_m4_10_test.dart` 断言改「电脑会把它恢复成一条新会话」） |
| 端到端（真手机 token） | `POST /desktop/sessions/session-4670a31a…/prompt` → `200 {"ok":true,"accepted":true,"forked":true,"forkedFrom":"session-4670a31a-…","sessionId":"session-6d1042d4-973b-4ce1-990d-d05871e678a7"}`；新会话 seq 8 是带摘要的开场、**seq 17 assistant「收到」**、seq 19 turn-end。失败路径：不存在的会话 → 404 `SESSION_NOT_FOUND` |
| 插件生效方式 | `plugin_manager set_bundle` 停用再启用，两次都 `applied` → `GET /api/v1/health` 变成 `version 0.2.24`（热加载成功，不用重开 DSH） |
| 构建 | release APK **72,720,862 字节**，SHA256 `7D80801736990E9BA845A0E16C938CEC7235765FD060F7103D8B75D61A3EF89C`；aapt2 `versionCode='46' versionName='0.4.19-m4.19'`，minSdk 24 / targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.19-m4.19.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.19-m4.19.apk`（三处同哈希） |
| 回读 | `GET /api/v1/app/version` → `{"versionCode":46,"versionName":"0.4.19-m4.19","size":72720862,"sha256":"7d808017…","publishedAt":"2026-11-17T00:53:36.753Z"}` |
| 附带产出 | `tools/dump-session-log.mjs`：逐帧 zstd 解压任意 session 日志并打印尾部事件（`node tools/dump-session-log.mjs <sessionId> [tail]`），两条死路都是靠它取证的 |
| 真机 | **未复测**（无 adb 设备） |
| 文档 | `docs/research/M4_19_REPORT.md`、本文件、根 `README.md`、`docs/mobile/README.md` |

> **下一步**：手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.19-m4.19，versionCode 46，可覆盖安装；隧道域名又变了，现为 `https://<公网隧道>.trycloudflare.com`，先在电脑端重新扫码配对）→ 打开一个「已存档」的会话，底部应有输入条，发一句话后应跳到一条新会话并看到回复。注意它不会续写原来那条会话：电脑上会**新开一条**（标题沿用原名、目录不变），最近 12 条对话会作为摘要一起带过去。

### M4.20 每次开机后手机「工作区」又空了（2026-11-17 补充）

| 项 | 结果 |
| --- | --- |
| 现象 | 用户 09:06：「每次开启之后工作区里面的内容又没了」。截图里工作区只剩 `user`（`C:\Users\user`，标「暂无会话」）和正在执行的 `deepseek手机端` |
| 手机侧取证 | 截图里的「暂无会话」「点进去可以在电脑的这个目录里新建会话」在 `app/lib` 里**已不存在**（M4.13 换成了「空项目」和项目分组卡）→ 手机上装的仍是 ≤0.4.12 的旧 APK |
| 插件侧取证 | 真手机 token 调 `GET /api/v1/desktop/workspaces` → **10 条目录全在**；`/desktop/tasks` 6 条、`/desktop/archive/sessions` 75 条 → 后端是好的 |
| Agent 侧取证 | app token 连 WS 读 `device.status` → `workspaceRoots(18)`：9 个目录各出现两遍（既证明 Agent 的清单和插件不一致，也暴露去重缺失） |
| 根因 | 插件在 `apply` 里就 `supervisor.start()`，此时 async 的 `workspaceRegistry` 还没就绪 → `resolveWorkspaceRoots()` 退回 `[homedir()]`；`RelayAgent` 的两个目录字段是 `private readonly`，`buildDeviceStatus()` 永远上报这份旧值；插件自己的 5 秒 TTL 缓存会自愈，但 Agent 不会重读 → 每次开机都要重走一次竞态 |
| Agent 改动 | `relay-agent.ts`：字段去 `readonly`，新增 `setWorkspaceRoots()`（归一化+去重、没变返回 false、变了补发 `device.status`）与 `normalizeWorkspaceRoots()`/`sameWorkspaceRoots()`；`serve.ts`：新增 `M1_WORKSPACE_REFRESH_MS`（默认 20000，0 关闭）与 `refreshWorkspaceRoots()`（带 agent token 取 `GET /api/v1/agent/workspaces`），`client.onOpen` 立刻刷一次 + 每 20 秒一次，`shutdown` 里 `clearInterval` |
| 插件改动（0.2.25） | `server.js` 新增 `GET /api/v1/agent/workspaces`（`hub.authorizeToken(token, 'agent')` 才放行）；`index.js` 的 `normalizeRoots()` 按 `canonicalPath()` 去重（保留首次顺序，首个仍是默认工作区） |
| 测试 | Agent `node --test "tests/unit/*.test.ts"` **60/60 PASS**（新增 `workspace-roots.test.ts` 4 例；`package.json` 的 test 脚本改成跑全部 unit 用例）；插件 `node --test "test/*.test.js"` **69/69 PASS**（66 + `agent-workspaces.test.js` 3 例，真起 http server） |
| 去重效果 | 热加载前 `workspaceRoots` **18 条** → 热加载后 **10 条** |
| 竞态自愈实测 | 临时把拉起 Agent 时的目录改成 `[homedir()]` 模拟开机竞态：Agent 起来先上报 **1 条**，`client.onOpen` 的那次刷新立刻改成 **10 条**；探针日志每 20 秒一次 `rows=10 paths=10` |
| 鉴权边界 | `agent → /agent/workspaces` 200；`agent → /desktop/workspaces` 401；`app → /agent/workspaces` 401；`app → /desktop/workspaces` 200 |
| 插件生效方式 | `plugin_manager set_bundle` 停用再启用（两次 `applied`）→ `GET /api/v1/health` 变成 `version 0.2.25` |
| 附带产出 | `tools/watch-device-status.mjs`：用手机 token 连 WS 打印 `device.status.workspaceRoots`（排障比读日志快） |
| 踩坑 | **`dsh-plugin-m1/agent/` 才是运行时真正跑的那份**：插件里 `agentDir = join(bundleRoot, 'agent')`。这次先只改了根目录的 `agent/`，热加载后刷新的探针日志根本没出现——**改 Agent 代码必须同时落到 `dsh-plugin-m1/agent/`** |
| 真机 | **未复测**（无 adb 设备） |
| 文档 | `docs/research/M4_20_REPORT.md`、本文件、根 `README.md`、`docs/mobile/README.md` |

> **下一步**：手机先装 `dist\DeepSeek-Remote-latest.apk`（0.4.19-m4.19，versionCode 46；截图里的旧版卡片形态就是 ≤0.4.12 的证据），再用新配对码重新配对（隧道现为 `https://<公网隧道>.trycloudflare.com`）→ 工作区应一次列出 10 个项目、每个都能展开。往后每次重启 DSH，Agent 会在 20 秒内自动把目录校正回来，不需要手动重开。

### M4.21 手机端也要有「N 条排队消息」（2026-11-17 补充）

| 项 | 结果 |
| --- | --- |
| 现象 | 用户 10:35 发电脑端截图：「这个功能手机上也得有」——电脑端在一轮还在跑时会把后面排着的话列成「4 条排队消息」，每行右侧三个图标（编辑 / 删除 / 上移=插话），面板下方提示「Cmd/Ctrl+Enter 插话发送全部排队消息」；手机端完全没有这个概念 |
| 契约取证 | Host `sessionController.state(request, signal)` 的 **signal 必填**（内部 `signal.throwIfAborted()`），返回 `{ cursor, active, running, queue, pendingInput }`；`queue[]` 是 `{ id, placement: 'queued'|'steering'|'context', content }`；改动走 `updateQueue({ sessionId, itemId, action })`，`QueueAction = { kind:'edit', content } | { kind:'remove' } | { kind:'steer' }`——**没有 moveUp**，电脑端那个上箭头就是 `steer` |
| 插件改动（0.2.26） | `lib/index.js` 新增 `queueItemText()`（文本拼接，非文本 part 补「（另有 N 个附件）」）、`readDesktopQueue()`（无 `state` 能力 → `supported:false`，Host 抛错收进 `error` 不往上抛）、`mutateDesktopQueue()`（三种 action 翻译；空 id / 改空内容 / 未知操作 → `QUEUE_BAD_REQUEST`，无 `updateQueue` → `QUEUE_UNSUPPORTED`）；`pageContext` 增 `desktopQueue` / `desktopQueueUpdate` 并删掉 M4.19 遗留的 `desktopFork`（函数早已删除，属潜在 ReferenceError）。`lib/server.js` 新增 `GET|POST /api/v1/desktop/sessions/<id>/queue`，都要 App token，`QUEUE_BAD_REQUEST`→400、其余 500 |
| 手机端改动（0.4.21+47） | `history_api.dart` 增 `DesktopQueueItem` / `DesktopQueue` / `fetchDesktopQueue` / `updateDesktopQueue`；`live_store.dart` 两个包装；`desktop_session_screen.dart` 增 `_queue` / `_queueOpen` / `_queueBusy`、`_loadQueue()` / `_applyQueueAction()` / `_editQueueItem()`（AlertDialog 改字）/ `_steerAllQueue()`，以及 `_QueuePanel`（折叠行「N 条排队消息」+「全部插话」+ 提示「插话＝立刻送进这一轮（电脑端是 Cmd/Ctrl+Enter）」）、`_QueueRow`、`_QueueIconButton` |
| 测试 | 插件 `node --test "test/*.test.js"` **76/76 PASS**（69 + 新增 `test/queue.test.js` 7 例，含「state 的 signal 不能漏」这条踩坑）；`flutter test test/` **377/377 PASS**（371 + `desktop_queue_m4_21_test.dart` 6 例） |
| 端到端（真手机 token） | `GET /api/v1/desktop/sessions/session-55cdd3b7…/queue` → 200 `supported:true`、**4 条 `queued`**（「输入时搜索框里面不显示」+附件、「继续」、「这个需要审核操作的手机上还是没有」+附件、「不是每个对话新开一条对话…」+附件）；另一条 running 会话 `items: 0`（面板不显示）；不带 token → 401 |
| 插件生效方式 | `plugin_manager set_bundle` 停用再启用（两次 `applied`）→ `GET /api/v1/health` 变成 `version 0.2.26`（热加载，不需要重开 DSH） |
| 构建 | release APK **72,802,990 字节**，SHA256 `344C8A9EF450F5A7E066057314AD5DE35479B91CFC54A324101E18FF6B11E125`；aapt2 `versionCode='47' versionName='0.4.21-m4.21'`，minSdk 24 / targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.21-m4.21.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.21-m4.21.apk`（三处同哈希） |
| 回读 | `GET /api/v1/app/version` → `{"versionCode":47,"versionName":"0.4.21-m4.21","size":72802990,"sha256":"344c8a9e…11e125","publishedAt":"2026-11-17T03:57:38.595Z"}` |
| 踩坑 | ①`state()` 第一次漏传 `signal`，线上直接 `Cannot read properties of undefined (reading 'throwIfAborted')`；②`edit` 工具两次误删行（`DesktopSessionFeed` 构造行、`_pickPhotos()` 签名行），原因都是 `old_string` 多带一行而 `new_string` 只留一行 |
| 真机 | **未复测**（无 adb 设备） |
| 文档 | `docs/research/M4_21_REPORT.md`、本文件、根 `README.md`、`docs/mobile/README.md` |

> **下一步**：手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.21-m4.21，versionCode 47；隧道现为 `https://<公网隧道>.trycloudflare.com`，需重新扫码配对）→ 在一条正在跑的会话里，底部应出现「N 条排队消息」，展开能改字 / 删除 / 单条插话 / 全部插话。用户排在这里的另外三条诉求还没做：**搜索框输入时没有提示**、**审核（授权）操作手机上仍然不出现**、**存档会话不要新开一条、要在同一条对话里继续**。
### M4.22 输入框里打出来的字不见了（2026-11-17 补充）

| 项 | 结果 |
| --- | --- |
| 现象 | 用户 09:13 截图：插件 → 插件市场，搜索框里敲了 `dsh`，框内只剩一个光标、提示语也不可见，但统计行显示「39 个插件 · 电脑端插件市场 · 已安装 18 个 · “dsh”」——说明 `onChanged` 收到、过滤生效，纯粹是字画不出来 |
| 根因 | `buildAppTheme()` 把 `textTheme` **整体替换**成一个只写了 7 条样式的部分 `TextTheme`，没写到的 `bodyLarge` 退化成无颜色的 `englishLike bodyLarge 2021`；`TextField` 的正文样式取的就是 `theme.textTheme.bodyLarge` → 打出来的字是透明的（提示语同样被覆盖） |
| 取证方式 | 临时 widget 测试把真实 `EditableText.style` 打出来：修前整行没有 `color:`；修后 `color: Color(alpha: 1.0, red: 0.0667, green: 0.0745, blue: 0.0941)` ≈ `#111318` |
| 修法（0.4.22+48） | `app/lib/theme/app_theme.dart`：`textTheme: base.textTheme.merge(TextTheme(...))`（merge 到完整 Typography 上），并补 `bodyLarge: p.text / 15 / 1.6`、`labelMedium: p.text2 / 12.5`；注释写明原因 |
| 新增测试 | `app/test/theme_text_field_m4_22_test.dart` 2 例：浅/深色主题下 7 条正文样式都必须有颜色；真实 `PluginsScreen` 市场 Tab 的 `EditableText.style.color` 非空、`enterText('dsh')` 后 `find.text('dsh')` 命中 |
| 测试总数 | `flutter test test/` → **379/379 PASS**（377 + 2）；插件不变（0.2.26，`node --test` 76/76） |
| 构建 | release APK **72,802,990 字节**，SHA256 `4BE811E0442A29B1C23DF354FBFD0DB2389EFFE63376036670C34223C8D85358`；aapt2 `versionCode='48' versionName='0.4.22-m4.22'`，minSdk 24 / targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.22-m4.22.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.22-m4.22.apk`（三处同哈希） |
| 回读 | `GET /api/v1/app/version` → `{"versionCode":48,"versionName":"0.4.22-m4.22","size":72802990,"sha256":"4be811e0…c8d85358","publishedAt":"2026-11-17T04:35:46.372Z"}` |
| 真机 | **未复测**（无 adb 设备） |
| 文档 | `docs/research/M4_22_REPORT.md`、本文件、根 `README.md`、`docs/mobile/README.md` |

> **下一步**：手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.22-m4.22，versionCode 48；隧道现为 `https://<公网隧道>.trycloudflare.com`，需重新扫码配对）→ 插件 → 插件市场 → 搜索框打字应能看到字与提示语。用户排队里还剩两条没做：**审核（授权）操作手机上仍然不出现**、**存档会话不要新开一条、要在同一条对话里继续**。

### M4.23 电脑端「确认需求」的提问卡，手机上也能回答（2026-11-17 补充）

| 项 | 结果 |
| --- | --- |
| 用户反馈 | 「这个需要审核操作的手机上还是没有」，附电脑端截图：会话「示例项目E」弹「歌词样式 / 歌词字幕想要什么形式？」三个选项 + 输入框 + 跳过/提交 + 右上「2/2」 |
| 关键澄清 | 那不是权限审批，是 `ask_user_question` 工具弹的**提问卡**：日志里只是普通 `tool/call`（`session-e2e1f57b` seq 880），Host 侧走 `user-questions/request` waterfall，不落日志 |
| 根因 | 插件只接了 `approval/request`（M4.4 起），提问一律 `next()` 交回桌面弹窗，所以手机上什么都没有 |
| 插件改动（0.2.26 → 0.2.27） | `ctx.on('user-questions/request')` 接管（仅当手机正在看这个会话）；`pendingQuestions` 挂起 Promise；5 分钟无人应答按「跳过」放行；`listDesktopSessionEvents()` 多回 `questions`；新增 `POST /api/v1/desktop/sessions/<id>/questions/<questionId>` |
| 手机端改动（0.4.22+48 → 0.4.23+49） | `DesktopQuestion*` 模型与 `answerDesktopQuestion()`；直播页 `_QuestionCard`（单选/多选 + 自定义输入 + 跳过/提交）；标题栏徽标扩展成「待回答 N」 |
| 验收证据 | 插件 `node --check` 通过、`node --test` **85/85**；`flutter test` **382/382**；线上 `/desktop/sessions/<id>/events` 响应含 `approvals,questions`；`POST …/questions/nope` → 404 `QUESTION_NOT_FOUND`；不带 token → 401；`/api/v1/health` = 0.2.27（热加载生效） |
| 产物 | `dist\DeepSeek-Remote-AI-v0.4.23-m4.23.apk` / `dist\DeepSeek-Remote-latest.apk` / 根目录同名 APK，**72,836,030 字节**，SHA256 `6D7D19CA…3D0B365D`，versionCode 49 |
| 限制 | 真机还没跑过一次真实提问（`ask_user_question` 要由电脑上的那一轮触发，我这轮无法在不挂住自己的前提下触发），卡片渲染由 widget 测试覆盖 |
| 下一步 | 装 0.4.23 APK + 重新配对（隧道现为 `https://<公网隧道>.trycloudflare.com`）→ 电脑端弹「确认需求」时应出现在手机上；还剩「存档会话要在同一条对话里继续」 |

### M4.24 存档会话在原对话里继续（2026-11-17 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户：「不是每个对话新开一条对话，是和电脑上一样的在这个对话里面就一直在，可以加载出来」。M4.19 是「同目录新开会话 + 最近 12 句摘要」，会越点越多 |
| 根因 | 把 DSH 本体（`resources/app.asar`）当文本检索，找到 agent 主循环 `if (decision.kind === "reject") { turnEnds = { kind: "blocked" } }`；唯一返回 `{kind:"reject"}` 的监听者是 `ArchivedSessionGate`（`agent/pre-step`），源码注释写明「unarchiving lifts the gate for the whole lineage」→ 会话只要还在归档里，任何唤醒都不可能有产出 |
| 插件改动（0.2.27 → 0.2.28） | 删掉 `buildArchiveDigest()` / `createSuccessorSession()`；新增 `resumeArchivedSession()`（`workspaceController.unarchiveSession({sessionId})`，返回的 `archivedSessionIds` 仍含它 → `session/still-archived`）；`promptDesktopSession()` 抬门后往**同一个** `sessionId` 发原话，返回 `{accepted, resumed:true, resumedFrom, sessionId}`；错误码 `SESSION_UNARCHIVE_UNSUPPORTED` / `SESSION_NOT_RESUMABLE` / `SESSION_NOT_FOUND` |
| 手机端改动（0.4.23+49 → 0.4.24+50） | `DesktopPromptResult.resumed`；存档页说明条改「电脑会把它接回原来那条对话，接着说」；发送成功后不再 `pushReplacement`，就地 `_revived = true` + 直播轮询，toast「已把这条会话接回原对话」 |
| 验收证据 | 插件 `node --check` 通过、`node --test` **85/85**（`session-resume.test.js` 重写为 9 例）；`flutter test` **382/382**（`archive_chat_m4_19_test.dart` → `archive_chat_m4_24_test.dart`）；`/api/v1/health` = 0.2.28（热加载）；`POST /api/v1/desktop/sessions/960545fb…/prompt` → `200 {"resumed":true,"sessionId":"960545fb…"}`；该会话日志 seq 76 user → seq 84 assistant「收到」→ seq 86 `turn/end {kind:"completed"}`，**没有新 sessionId**；`/desktop/tasks` 里出现「课程设计 · 14:14 · completed · msgs=17」 |
| 产物 | `dist\DeepSeek-Remote-AI-v0.4.24-m4.24.apk` / `dist\DeepSeek-Remote-latest.apk` / 根目录同名 APK，**72,836,030 字节**，SHA256 `74412D78…95EA7877`，versionCode 50 |
| 限制 | 手机存档列表里那条记录仍在（被「电脑列表里也在」去重挡住）；会话恢复后回到电脑会话列表，长期会攒回来；真机未复测完整流程 |
| 下一步 | 装 0.4.24 APK + 重新配对（隧道现为 `https://<公网隧道>.trycloudflare.com`）→ 点一条「已存档」会话发话，应就地看到回复、电脑上不多出新会话 |

### M4.25 账户余额放到「我的」里面（2026-11-17 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户：「账户余额放到我的里面」。「我的」页此前只有品牌卡、连接与设备、模型与 API Key、通知开关、外观、关于，完全看不到账户里还有多少钱 |
| 为什么必须插件代理 | Host 的 `deepseekAccount` 服务描述写明「Account operations; only Host consumers can obtain a request credential」——凭据只在 Host 进程里。手机走插件的新路由，插件调 `getBalance({ version, locale, timezoneOffsetSeconds })`，只把钱包数字交给手机，不下发任何 token |
| 插件改动（0.2.28 → 0.2.29） | `readAccountBalance()`：无 `getBalance` → `supported:false`；`null`（未登录）→ `supported:true, signedIn:false`；`status:"failed"` → `failed:true`；`ready` → `wallets`/`bonusWallets` 压成 `{currency, balance}` 并丢空条目；异常带 Host 错误码。`pageContext.accountBalance`；`GET /api/v1/desktop/account/balance`（app token，401 / 501 `ACCOUNT_BALANCE_UNAVAILABLE` / 200 透传） |
| 手机端改动（0.4.24+50 → 0.4.25+51） | `history_api.dart` 新增 `AccountWallet`（带 `symbol`）与 `AccountBalance`（`primary` 优先 CNY）+ `fetchAccountBalance()`；`live_store.dart` 新增同名方法（未连接抛「还未连接电脑，读不到账户余额」）；「我的」页新增「账户余额」分区与 `_BalanceCard`：连接后自动读取、监听连接变化、右上金额 +「重新读取」，有赠送钱包时单列一行，未连接/未登录/查询失败/插件太旧各有副标题 |
| 验收证据 | 插件 `node --test "test/*.test.js"` **95/95**（新增 `account-balance.test.js` 6 例、`account-balance-route.test.js` 4 例）；`flutter test test/` **386/386**（新增 `profile_balance_m4_25_test.dart` 4 例）；路由边界：无 token 401、agent token 401、插件不支持 501 |
| 产物 | `dist\DeepSeek-Remote-AI-v0.4.25-m4.25.apk` / `dist\DeepSeek-Remote-latest.apk` / 根目录同名 APK，**72,836,290 字节**，SHA256 `C1AC2F7E…E7CA7A93`，versionCode 51 |
| 限制 | 插件 0.2.29 这次**没能热加载**（`plugin_manager set_bundle` 连试三次都返回 `HMR transactions cannot be nested`），运行中的插件仍是 0.2.28，所以线上 `/api/v1/desktop/account/balance` 目前还是 404，重开 DSH 后才会出现；手机端此时显示「这台电脑的插件版本太旧，读不到余额」 |
| 下一步 | 重开 DSH（插件 0.2.29 生效，隧道域名会变）→ 手机装 0.4.25 APK 并重新配对 → 「我的」页应显示与电脑端一致的余额；真机未复测 |

### M4.26 「这个进度条都不动」（2026-11-17 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户发截图：「这个进度条都不动」。弹窗「正在下载 v0.4.25-m4.25」停在 `0% · 0.0 / 69.5 MB`，可同一屏「检查更新」那行写着「下载中 1%」——两处数字自相矛盾 |
| 根因 | 进度弹窗用 `showDialog` + `StatefulBuilder` 撑起来，`onProgress` 里只调了外层 `UpdateCheckTile` 的 `setState`，弹窗自己的 `setDialogState` **一次都没被调用**。弹窗挂在根 Navigator 上，不是 tile 的子树，外层 setState 不会让它重建 → 条和文字是一次性快照，字节其实一直在进来 |
| 改动（手机端 0.4.25+51 → 0.4.26+52） | `app/lib/widgets/update_check_tile.dart`：新增 `StateSetter? _dialogSetState;`；`_showProgressDialog()` 的 builder 首行存下 `setDialogState`；`onProgress` 末尾调用新的 `_refreshProgressDialog()`；`_closeProgressDialog()` 与 `finally` 里清空它，迟到的回调不会打到已销毁的 State。插件不变（0.2.29） |
| 验收证据 | 反证：临时删掉 `_refreshProgressDialog();` → 新用例失败 `Found 0 widgets with text containing 50% · 0.5 /`，恢复后通过；新用例 `app/test/update_check_tile_test.dart`「下载进度回调要同时刷新弹窗里的百分比与已下载字节」；`flutter test test/` **387/387** |
| 产物 | `dist\DeepSeek-Remote-AI-v0.4.26-m4.26.apk` / `dist\DeepSeek-Remote-latest.apk` / 根目录同名 APK，**72,836,290 字节**，SHA256 `DC42BF0C…47056AFC`，versionCode 52 |
| 限制 | 只修「弹窗不重画」；下载速度仍受隧道与 `pace()` 节流（256 KB/帧、帧间 ≥30 ms，上限约 8.5 MB/s）；没有取消与断点续传；真机未复测 |
| 下一步 | 装 0.4.26 APK → 「我的 → 检查更新 → 立即更新」，弹窗里的百分比与 MB 应连续增长；插件 0.2.29 仍需完整重开 DSH 才生效（M4.25 遗留） |

### M4.27 手机档能新建对话、记录留在侧端（2026-11-17 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户发豆包的侧边栏截图（置顶 + 最近两组历史）配文「手机上的对话可以新建对话，对话保留，可以新建对话，记录留在侧端，像豆包这样的」 |
| 根因 | 云端直连没有存储：`app/lib/screens/cloud_chat_screen.dart` 的 `_messages` 只在内存里，`_newChat()` 就是 `setState(_messages.clear())`，`_load()` 只读接口配置（`cloud_chat.json`），所以退出页面说过的话全丢、也没有历史入口 |
| 改动（手机端 0.4.26+52 → 0.4.27+53） | 新增 `app/lib/services/cloud_conversations.dart`：`CloudChatRecord`（角色/正文/失败标记）、`CloudConversation`（id/标题/创建与更新时间/消息）、`conversationTitle()`（压单行、截 18 字）、`CloudConversationStore`（应用私有目录 `cloud_conversations.json`，坏文件当空库，保存时按更新时间倒序、最多 80 条）。对话页新增 `conversations` 注入参数、`_loadConversations()`（与接口配置分开读，读盘慢不拖首屏）、`_persist()`（发问后立刻落盘、回复或失败再落一次）、`_newChat()`（当前空对话复用，否则真另起一条）、`_openHistory()`（`showGeneralDialog` + 从左侧滑入的面板，82% 宽，标题/条数/相对时间/删除），未内嵌时 AppBar 也加了「对话记录」；首页手机档顶栏「历史」接到 `CloudChatController.openHistory()`。插件不变（0.2.29） |
| 验收证据 | `flutter test test/` **397/397**（新增 10 例：存储 5 例含坏文件与裁剪、widget 5 例含侧栏切换/新对话落盘/删除/重开后还在）；`node --source` 无；APK 已回读 |
| 产物 | `dist\DeepSeek-Remote-AI-v0.4.27-m4.27.apk` / `dist\DeepSeek-Remote-latest.apk` / 根目录同名 APK，**72,934,594 字节**，SHA256 `2C5768CE…78C711D`，versionCode 53；`GET /api/v1/app/version` 回读 `0.4.27-m4.27 / 53 / 72934594` 一致 |
| 限制 | 附件不进历史（只存文字）；`cloud_conversations.json` 只在手机本地，删 App 就没了；切换对话不做上下文压缩；标题只能自动取第一句、不能改 |
| 下一步 | 装 0.4.27 APK → 手机档点「历史」应滑出对话记录，「新对话」另起一条、发话后退出再进来还在；插件 0.2.29 仍需完整重开 DSH 才生效（M4.25 遗留） |

### M4.28 余额接口的 404 别再指向「地址不对」（2026-11-17 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户拿着「我的 → 账户余额」的截图问「为什么出现错误」：`读取账户余额失败：请求格式不正确：请确认地址指向 M1 后端（not found）` |
| 根因 | `/api/v1/desktop/account/balance` 是插件 0.2.29 才有的路由；运行中的 Host 仍是 0.2.28（热加载卡在 `HMR transactions cannot be nested`），所以 404。而 `PairingApi.messageForHttpError` 对 404 的通用文案是「请确认地址指向 M1 后端」，在地址确实没错时纯属误导 |
| 改动（0.4.27+53 → 0.4.28+54） | `app/lib/services/history_api.dart` 的 `fetchAccountBalance()` 单独 catch 404，改成「这台电脑上的插件还没有账户余额接口（需要 0.2.29 以上）：请升级插件后完整退出并重开一次 DSH，再回来刷新」；其它状态码与其它接口的文案不动 |
| 验收证据 | 新增 `app/test/account_balance_message_m4_28_test.dart` 2 例（404 → 文案含「插件还没有账户余额接口」「0.2.29」且不含「请确认地址指向」；200 → 钱包照旧解析）；`flutter test` **399/399**；APK 72,950,978 字节 / versionCode 54 / SHA256 `97551C01…782F43A` |
| 限制 | 只改文案，旧插件不会因为换了措辞就有接口；`HMR transactions cannot be nested` 的原因仍未查清，每次改插件都得完整重开一次 DSH |

### M4.29 下载卡片上的取消与后台下载（2026-11-17 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户说「加一个取消和后台下载」，随后补充「我说的是下载时的那个小卡片上加取消和后台下载」——截图里那张「正在下载 v0.4.28-m4.28 / 98% · 68.0 / 69.6 MB」的卡片只有一个进度条 |
| 根因 | 下载由 `_UpdateCheckTileState` 直接 `await`：①没有取消标记，`await for` 停不下来；②进度只在 `_progressOpen` 为真时有意义，卡片一关就再也看不到，页面销毁后连「下完了」都无从呈现 |
| 改动（手机端 0.4.28+54 → 0.4.29+55） | `app/lib/services/update_service.dart`：新增 `UpdateCancelToken`（`cancel()` / `isCancelled`）与 `UpdateCancelled extends UpdateException`；`download()` 增加 `UpdateCancelToken? cancel`，每写一帧查一次标记，取消时**先 `sink.close()` 再删 `.part`**（Windows 上删开着的文件会失败） |
| | 新增 `app/lib/services/update_download_center.dart`：`UpdateDownloadCenter extends ChangeNotifier`（全局单例 `instance`）持有 `info / running / received / total / ratio / cancelled / error / file` 与 `start()`、`cancel()`、`reset()`；同一版本号重复点不会开两条流 |
| | `app/lib/widgets/update_check_tile.dart`：下载改走下载中心，`dispose` 只摘监听**不取消下载**；进度弹窗用 `AnimatedBuilder(animation: _center)` 直接订阅（顺带彻底解决 M4.26 那个「弹窗不重画」的坑）；卡片底部两个按钮「取消下载」「后台下载」，`barrierDismissible: true`（收起来不算取消）；副标题按状态显示「下载中 N% · 点开可以看进度或取消」「已下载好 v… · 点这里安装」「已取消下载 · 点一次重新开始」「上次下载失败 · …」 |
| 验收证据 | 新增 `app/test/update_cancel_m4_29_test.dart` **5/5**：取消后抛 `UpdateCancelled` 且 `.part` 不存在（真文件、真 `UpdateService`）；下载中心把 0→1 的进度换算成百分比并留住产物；中心取消后 `await future == null` 且 `cancelled == true`；点「后台下载」卡片消失、副标题仍写「下载中」、放行后仍调起安装器（`installedPaths == [apk]`）；点「取消下载」弹窗关闭、`seenCancel.isCancelled == true`、不安装、提示「已取消下载」 |
| | `flutter test test/` → **404/404 PASS**（399 + 5）；APK 72,950,978 字节，versionCode **55**，SHA256 `21CB77AF…D82C8C` |
| 限制 | 只修「卡片上的按钮」与「进程内后台」：App 被系统**杀掉**时下载仍会断（没走 Android 前台服务下载）；也没有断点续传，取消后再点是从头下 |

### M4.30 待办（下一步候选）

- 真机复测 M4.29：下载中点「后台下载」→ 离开「我的」页 → 回来点「检查更新」应看到同一进度；点「取消下载」后缓存目录里不该留下 `.part`。
- 插件 0.2.29 仍需用户**完整退出 DSH 再重开**才生效（`HMR transactions cannot be nested`），生效后「我的 → 账户余额」才会出现金额。
- 长期遗留：`tools\verify-plugin-m4.ps1` 在 PS 5.1 下解析报 15 个 syntax error；锁屏推送提醒未做；隧道域名每次重启都变。

### M4.30 手机档的对话自动「存档」到工作区（2026-11-17 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户说「手机上的ai助手对话完没有自动存档」；追问确认是手机档（云端直连，没连电脑） |
| 排查 | 存档其实从 0.4.27 起就有：`CloudChatScreen._persist()` 把每条对话写进 `cloud_conversations.json`（发问立刻存、回复或失败后再存）。问题在**可见性**：这份记录只在 AI 助手页右上角那颗时钟的侧栏里，「工作区」只列电脑端的任务与存档会话 |
| 改动（0.4.29+55 → 0.4.30+56） | 新增 `app/lib/services/cloud_chat_intent.dart`（`CloudChatIntent` 单向意图广播）；`TasksScreen` 新增 `onOpenCloudConversation` / `conversations` 与 `_PhoneChatsSection`（工作区顶部「手机对话」：标题、`N 条消息 · 相对时间`、「只存在这台手机上」，最近 5 条，没连电脑也显示）；`CloudChatController.openConversation()` + `openConversationById()`（内存没有就先读盘再切）；`AssistantScreen` 监听意图，切到手机档并打开那一条；`RootShell` 把两侧接起来 |
| 验收证据 | 新增 `app/test/workspace_phone_chats_m4_30_test.dart` **5/5**；`flutter test` **409/409**；APK 72,951,042 字节 / versionCode 56 / SHA256 `549D9759…047DEDDA` |
| 限制 | 工作区只列最近 5 条（全部在 AI 助手侧栏）；只存文字、附件不进历史；只在手机本地、无云同步；手机档对话不并入项目分组 |

### M4.31 手机端也能回答电脑的「确认需求」（2026-11-17 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户发来电脑端截图：Agent 用 `ask_user_question` 弹了「确认是哪一档」的问题卡，配文「这个要要审核选择的功能手机上没有」 |
| 根因 | `dsh-plugin-m1/lib/index.js` 的 `user-questions/request` 第一句是 `if (!sessionId \|\| !isWatching(sessionId)) return next();`——手机没在 10 分钟内拉过这条会话的事件，就直接交回电脑弹窗，手机端连「有提问」都不知道 |
| 改动（插件 0.2.29 → 0.2.30） | 新增 `phoneOnline()`（`hub.appCount > 0`），接管条件放宽成「正在看这条会话 **或** 手机还连着」；新增 `GET /api/v1/desktop/pending` 回跨会话摘要（会话 id、标题、问题数、第一条 header/question），完整选项仍走 `/sessions/<id>/events` |
| 改动（手机端 0.4.30+56 → 0.4.31+57） | `DesktopPendingQuestion` / `DesktopPending` 模型 + `fetchDesktopPending()`（404/501 降级成 `answerable: false`）；工作区顶部 `_PendingQuestionBanner`（header + 问题 + 「还有 N 个」，点一下进那条会话），`_loadPending()` 挂在已有的 5 秒轮询上 |
| 验收 | 插件 `node --test` **101/101**（新增 `pending.test.js` 6 例）；`flutter test` **414/414**（新增 `pending_question_m4_31_test.dart` 5 例） |
| 产物 | `73,016,578` 字节 / `0.4.31-m4.31` / versionCode 57 / SHA256 `CC2B4F34…42A5094C99`，`/api/v1/app/version` 已回读一致 |
| 卡点 | 插件热加载第三次撞上 `HMR transactions cannot be nested`，0.2.30 需**完整退出 DSH 再重开**才生效；重开前 `/desktop/pending` 回 404，App 按「看不到」处理、不弹错 |

**下一步**：①完整重开 DSH → `version` 应为 0.2.30 → 装 0.4.31 → 重新扫码配对；②在电脑上触发一次 `ask_user_question`，工作区顶部应出现提示条、点进去能选；③提示条目前只在工作区，是否做全局横幅待定；④等待授权（权限审批）仍走老条件，未与提问统一。

### M4.34 手机对话从工作区挪到抽屉（2026-11-18 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户纠正 M4.30：「手机对话记录不保存到工作区，保存到这」，配图红圈画在抽屉「历史会话 → 还没有历史会话」下方 |
| 改动（App 0.4.33+59 → 0.4.34+60） | `tasks_screen.dart` 删掉 `_PhoneChatsSection` / `_PhoneChatRow` / `_phoneChats` / `_loadPhoneChats()` / `onOpenCloudConversation` / `conversations` 参数与 import；`root_shell.dart` 的 `RootShell` 新增 `conversations`（可注入）、`_phoneChats` + `_loadPhoneChats()`（有内容的，最多 6 条）、`_openPhoneChat()`、`_openDrawer()` 前重读；`_AppDrawer` 新增 `phoneChats` / `onOpenPhoneChat` 与 `_PhoneChatDrawerTile`，插在「历史会话」标题之前；`assistant_screen.dart` 新增 `conversations` 并透传给内嵌 `CloudChatScreen`（同一份存储，测试可注入内存版） |
| 验收 | 新增 `app/test/drawer_phone_chats_m4_34_test.dart` 3 例全过（抽屉列出 / 工作区不再有 / 点一条切页）；删掉 `workspace_phone_chats_m4_30_test.dart`（5 例，行为已被推翻）；`pending_question_m4_31_test.dart` 去掉失效参数后 5/5；全量 `flutter test` **423/423** |
| 产物 | release APK **73,032,962 字节**，SHA256 `021EC859A669921681CF533BAFEC90C2B2352276579535556C1AEE969CDBC39E`，`versionCode 60` / `0.4.34-m4.34` |

### M4.33 余额卡片上的「去充值」（2026-11-17 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户问「手机上能做到直接充值吗」 |
| 取证 | `deepseekAccount` 只有 13 个方法（`getState/getProfile/getBalance/getUnnotifiedBonuses/ackBonusNotified/startSignIn/cancelSignIn/signOut/watch/getPlatformSession/getDeviceIdentity/resolveToken/rejectToken`），**没有任何下单或付款接口**；`getPlatformSession()` 是 Host-only 凭证 |
| 改动（App 0.4.32+58 → 0.4.33+59） | 新增 `app/lib/services/url_opener.dart`（`UrlOpener` / `MethodChannelUrlOpener`（channel `deepseek_remote/update`，方法 `openUrl`）/ `FakeUrlOpener`）；`UpdateBridge.kt` 加 `openUrl`（只放行 http/https，`FLAG_ACTIVITY_NEW_TASK`）；`profile_screen.dart` 加 `kBalanceRechargeUrl = 'https://platform.deepseek.com/top_up'` 与 `_openRecharge()`，已连接时右对齐「去充值」，失败提示「打不开浏览器，可以在电脑上充值后再点右侧刷新」 |
| 验收 | 新增 2 例（点按钮把官方页交给浏览器 / 没连接不显示），`flutter test` **425/425**（M4.34 删掉旧 5 例后为 423） |

### M4.32 余额卡片的排版与数字（2026-11-17 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户发「这对吗」：金额 `¥12.443675700000000`、标题被挤成每行一个字、赠送余额 `$0` |
| 真实返回 | `wallets: [{USD 0E-16}, {CNY 12.4137841000000000}]`，`bonusWallets: [{USD 0}]` —— Host 给的是浮点串，且第一个钱包是 0 美元 |
| 改动（App 0.4.31+57 → 0.4.32+58） | `history_api.dart` 新增 `formatMoneyAmount()`（两位小数、`0E-16` → `0.00`、解析不了原样返回）与 `_parseMoney()`；`AccountWallet` 加 `symbol`（CNY/RMB→¥、USD→$）、`display`、`isZero`；`AccountBalance.primary` 优先「非零的 CNY」→ 任一无零钱包 → 第一条；`primaryBonus` 全零返回 null；`_BalanceCard` 金额用 `FittedBox` 限宽、副标题 `maxLines: 2` |
| 验收 | 新增 `app/test/profile_balance_format_m4_32_test.dart` 9 例（格式化 5 / 钱包挑选 3 / 超长金额不挤标题 1） |

### M4.35 提问卡不再卡死 + 等回答会通知（2026-11-18 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户发截图 + 「这个页面划不动，而且没有消息通知」：桌面直播页顶部一张「电脑在等你回答（2 个问题）」卡片一直排到屏幕底，下面的对话一个字都看不到、整页也拖不动 |
| 根因 1（划不动） | `desktop_session_screen.dart` 的 build 是 `Column`：标题栏 → 错误条 → 授权卡 → 提问卡 → 过程条 → `Expanded(ListView)`。两张卡是定高的普通子组件、自己不滚，卡片一长就先把 `Expanded` 挤到 0，于是列表拖不动、卡片也不滚 |
| 根因 2（没通知） | `live_store.dart` 只有 `_showApprovalActionNotice()`（等待授权）与 `_notifyTaskFinished()`（任务做完）两条通知路径；M4.23 的提问卡走 `user-questions/request`，没有任何一处调用通知网关 |
| 改动（App 0.4.34+60 → 0.4.35+61） | ① 授权卡与提问卡合并到最大高度 = 屏高 55% 的区域（`ConstrainedBox` + `SingleChildScrollView`），超出在卡内滚动；② `LiveStore.notePendingQuestions()`（key `question-<questionId>`，标题「电脑在等你回答 · <标题>」，`status: 'waiting'`，带 `sessionId`，重复不重发、答完 `cancelTaskUpdate` 收回，开关沿用「等待授权提醒」）；③ `tasks_screen.dart` 的 5 秒轮询在 `_loadPending()` 里调用它 |
| 验收 | 新增 `desktop_question_scroll_m4_35_test.dart` 2 例（列表高度 > 120 / 卡内拖动后最后那个选项可点）与 `question_notice_m4_35_test.dart` 5 例；反证：把卡片区放大到屏高 1.2 倍，两例立刻报 `Actual: <0.0>`；`flutter test` **430/430**（423 + 7） |
| 连带改动 | 高度比例 42% → 55% 后「提交」按钮重新可见，`desktop_question_m4_23_test.dart` 2 例恢复；`desktop_live_m4_14_test.dart` 的源码断言改成 `if (_approvals.isNotEmpty || _questions.isNotEmpty)` |
| 产物 | release APK **73,049,346 字节**，versionCode **61**，SHA256 `0B496D9014131B5C3250CDB1261A3080EE86E0605022C47E21623A9083D38BE2`；三处同哈希；`/api/v1/app/version` 回读一致 |
| 限制 | 只在工作区 5 秒轮询里发（进程被杀或没连电脑就没有）；正开着那张卡也会响；点通知只落到工作区；卡片超长仍需卡内滚动 |

### M4.36 提问卡的「提交」被顶出屏幕（2026-11-18 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户纠正上一轮的判断：「有通知，只是划不动提交不了」——通知本来就是好的，卡住的是提交按钮 |
| 根因 | M4.35 把整块卡片塞进一个 `SingleChildScrollView`：按钮虽然是卡片的一部分，仍会跟着选项一起滚出可视范围；而且卡片被 `Flexible` 拉满，短提问也白占半屏 |
| 改动（App 0.4.35+61 → 0.4.36+62） | `_QuestionCard` 自己排版：根 `Column(mainAxisSize: MainAxisSize.min)` 里「标题行」与「跳过 / 提交」是固定子项，中间选项区包 `Flexible(fit: FlexFit.loose)` + `SingleChildScrollView`；父层 `ConstrainedBox(屏高 55%)` + `Column(min)` + `Flexible(fit: loose)`，卡片按内容自适应、超出才滚 |
| 验收 | `desktop_question_scroll_m4_35_test.dart` 第二例改成钉三件事：`提交` 一开始就 `hitTestable`、最后一个选项一开始看不到、卡内拖 420 后能看到且 `提交` 仍可点；反证：把上限放大到屏高 1.2 倍，列表高度回 `0.0`、`提交` 直接找不到（`Found 0 widgets with type "FilledButton"`），正是用户遇到的症状；`flutter test` **430/430** |
| 产物 | release APK **73,049,346 字节**，versionCode **62**，SHA256 `13F0D3AF69E6B7247A8B7F65E659E93E4F23E242A9479BAF95D6BAFA24E349A3`；三处同哈希；`/api/v1/app/version` 回读一致 |
| 限制 | 选项区滚到底需要手指在卡内拖动；一个问题内选项超过 6 个时要把卡内列表滚很远（没有折叠）；提交后卡片消失前的那一段仍是「发送中…」 |

### M4.37 手机档往上拽一下就开新对话（2026-11-18 补充）

| 项 | 结果 |
|---|---|
| 起因 | 用户原话「手机ai对话对话框向上滑动长时间就可以新建对话」；用选项确认过，属于**想要手势**而不是 bug（另一个候选解释是「滑动时内容丢了」） |
| 做法 | `cloud_chat_screen.dart` 给消息列表套 `NotificationListener<ScrollNotification>`：只统计到达顶端之后的越界量（`OverscrollNotification.overscroll < 0`），累计 ≥ 130px 时顶部浮出「松手开始新对话」；`ScrollEndNotification` 时若仍处于 armed 状态就调 `_newChat()`。反向拖回（越界量退回阈值以下）或列表真的开始滚（`ScrollUpdateNotification`）都会作废 |
| 细节 | 列表加 `AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics())`，内容不够一屏的短对话里也能拽；提示是一颗胶囊（`add_comment_outlined` + 文案，accentSoft 底），叠在列表顶部不挤压布局；新建仍走原来的 `_newChat()`（当前对话空着则复用，不产生空记录） |
| 验收 | 新增 `app/test/cloud_new_chat_pull_m4_37_test.dart` 3 例：①拽 220px 时先出提示、`items.length` 仍是 1，松手后消息清空且存储变 2 条（旧那条还在）；②只拽 60px 不出提示、不新建；③长对话往上翻到顶再拽出提示、反向拖回后松手不新建。反证：阈值改成 100000 后两例立刻失败（`Found 0 widgets with text "松手开始新对话"`）。`flutter test` **433/433** |
| 产物 | release APK **73,049,346 字节**，versionCode **63**，SHA256 `F9671561D5A5641C113B4A5E200F8013063B0E267ADD7A8A74422CF5FCA698D6`；三处同哈希；`/api/v1/app/version` 回读一致 |
| 限制 | 只有手机档（云端直连）有这个手势，电脑档是直播会话、不适用；阈值写死 130px，不同屏幕密度下体感略有差别；拽的时候没有跟手的位移动画（只有提示浮现） |

### M4.38 直播页「经常连接超时」：在途互斥 + 失败退避

| 项 | 内容 |
|---|---|
| 现象 | 直播页红条「拉取桌面会话失败：连接超时（10 秒）：服务器没有响应」，状态「已结束 · 0 条」 |
| 实测 | 首屏 175 712 B（本机 3~69 ms）；同一请求走隧道 955 / 1 030 / 2 422 ms；limit 80/40/20 返回完全相同（319 条事件、186 948 B、12 条对话），因为 MIN_CHAT_EVENTS = 12 要回扫到第 319 条 |
| 根因 | ①载荷 187 KB + 隧道往返 1~2.4 秒；②Timer.periodic(1500ms) 不看上一个是否在途，10 秒超时前堆六七个请求；③失败后仍按 1.5 秒重试 |
| 改动 | 新增 app/lib/services/poll_backoff.dart；desktop_session_screen.dart 加 _inFlight / _pollFailures / _schedulePoll()；history_api.dart 的 _get 支持 timeoutOverride（拉会话 20 秒）、idleTimeout 5→20 秒、connectionTimeout 10→15 秒 |
| 验收 | 新增 4 例全过；反证（禁用 _inFlight）第 3 例报 Actual: <2>；全量 437/437；APK 73,049,346 字节 / versionCode 64 / SHA256 52244982…9FF386C7 |
| 未做 | 插件侧 gzip（187 KB → 约 30~40 KB）需要重开 DSH，本轮未动 |

### M4.39 手机档「往上滑」新建对话（手势方向纠正 + 加载圈）

| 项 | 内容 |
|---|---|
| 现象 | M4.37 的新建对话手势要先把列表翻到最老一条再往下拽，用户直接纠正：「不是下划是往上划，有个加载圈，根据上滑的力度」 |
| 根因 | 方向判断反了：`OverscrollNotification.overscroll < 0` 才是「手指往下、越过最老一条」那一侧，而用户要的是停在最新一条上继续往上滑 |
| 改动 | desktop 之外只在 `app/lib/screens/cloud_chat_screen.dart`：只认 overscroll > 0、每一点位移都 setState（圈跟手）、新增 `_movedInGesture` 防「一甩到底」误触、`_NewChatPullHint` 换成 `CircularProgressIndicator(value:)` 并挪到底部 |
| 验收 | 新增 3 例（原 3 例删除）；反证（去掉 `_movedInGesture`）第三例报 Found 1 widget with text 松手开始新对话；全量 437/437；APK 73,049,346 字节 / versionCode 65 / SHA256 F4D5834E…D29C4FE8 |
| 未做 | 阈值 130 像素待真机手感验证；只有手机档有这个手势 |

### M4.40 从不同角度测试这个 App（审计 + 修掉审计问题）

| 项 | 内容 |
|---|---|
| 起因 | 用户：「请从不同的角度测试此应用」——不加功能，做一次四面压测 |
| 角度 | ① 接口契约（真 token 打本机 8787）② 存档容错（真临时目录写坏文件）③ 小屏 + 大字号（320x480 + textScale 2.0）④ 运行期（500 条消息 / 连点发送 / 关页轮询） |
| 修掉的真 bug | ① `CloudConversation.fromJson` 坏时间戳退回 `DateTime.now()`，`updatedAt:'yesterday'` 反而排到「最近」第一 → 改退回 1970 沉底；② 小屏大字号下 `desktop_session_screen.dart` 三处 `RenderFlex` 溢出（body Column、运行中 Row、`_LiveFooter` Row）→ body 改 `LayoutBuilder`，只在 `maxHeight < 520` 时把上下两块各封顶 45% 并各自可滚；运行中行与状态行加 `Expanded/Flexible` + `maxLines: 2` |
| 插件侧待修（6 条） | 坏 JSON 体返 500 而非 400（`server.js:588` 读体在 try 之前）；`afterSeq=abc/-5` 静默当无参数、返回全量 253,187 B；`tokens.json` 86 条 token 全部有效（app 30 / agent 56）、永不撤销；`workspaces` 名 `../../escape-probe` 被消毒后照建目录；catch-all 404 配 `code: BAD_REQUEST`；`/api/v1/app/apk` 不支持 `Range`/206 |
| 已验证正常 | 鉴权与角色隔离（坏/空/agent token 打 app 路由全 401；app token 打 agent 路由 401）；`afterSeq=999999999` 返回空增量；500 条消息只建 < 60 个 `ChatItemView`；连点三下发送只发一条；关页后轮询停止；错误降级文案（500+HTML / 非 JSON / 401 / 超时 / 空 token）全部给人话 |
| 验收 | 新增 25 例（`audit_api_errors_m4_40_test.dart` 8、`audit_persistence_m4_40_test.dart` 10、`audit_small_screen_m4_40_test.dart` 4、`audit_runtime_m4_40_test.dart` 3）；全量 `flutter test test/` **462/462 PASS** |
| 产物 | App **0.4.40+66**，APK 73,049,346 字节，`versionCode 66`，SHA256 `8EF276D9F74449FEC46A375F779FC2D8528B5618C993A67D4EC399934F8F741F`，三处同哈希 + `/api/v1/app/version` 已回读一致；插件未改（仍 0.2.30） |
| 未覆盖 | 真机手势手感、弱网丢包模拟、双设备同时连、8 小时以上常驻内存/电量 |

### M4.41 删掉「电脑」页（紧急停止搬进「我的」）

| 项 | 内容 |
|---|---|
| 起因 | 用户：「可以把这个页面删了」+ 「电脑」页截图 |
| 判断 | 该页四处内容里只有「紧急停止」是独占的：Agent / Harness 版本与连接状态「我的 → 连接与设备」已有；权限说明弹层与未连接空态随页删除 |
| 改动 | `root_shell.dart`：删 `control_screen.dart` 的 import、`IndexedStack` 从 4 页收缩到 3 页、`RootShellItems` 去掉「电脑」、`_openProjects`/`_openTasks` 与通知路由 tasks 的索引 2→1、清掉未使用的 `projects_screen.dart` import；`profile_screen.dart`：新增「紧急停止」块（`if (connected)`）+ `_emergencyStop()`；`control_screen.dart` 整份删除（401 行） |
| 测试 | 新增 `app/test/emergency_stop_m4_41_test.dart` 3 例（滑动前不断开、确认后才断、未连接不显示、抽屉只剩三项）；`widget_test.dart` 抽屉断言改三项并新增「抽屉里不能再出现电脑」；`empty_state_test.dart` 删掉电脑页空态用例；全量 **463/463** |
| 产物 | App **0.4.41+67**，APK 73,032,914 字节，`versionCode 67`，SHA256 `5A87F1DF00E36036BDCD15141F4652900DD444511C1D01BA3C63EA27A5F12A61`，三处同哈希 + `/api/v1/app/version` 回读一致；插件未改（0.2.30） |
| 未做 | 权限说明弹层随页删除；抽屉「历史会话」在插件直连下仍为空（旧接口 404），待定「修它还是删它」 |

### M4.42 新增「功能」页（插件管理先搬进去）

| 项 | 内容 |
|---|---|
| 起因 | 用户：「做一个功能页面放到我的上面，先把插件拿出来放到里面」 |
| 改动 | 新增 `app/lib/screens/features_screen.dart`（「功能」页，扩展分组 + 插件管理一行，点击 push `PluginsScreen`，未连接时副标题提示先连电脑）；`profile_screen.dart` 删掉「插件管理」`_ListRow` 与 `plugins_screen.dart` import；`root_shell.dart` 的 `IndexedStack` 插 `FeaturesScreen`、`RootShellItems` 插入「功能」（顺序 AI 助手 / 工作区 / 功能 / 我的） |
| 测试 | 新增 `app/test/features_m4_42_test.dart` 3 例（功能排在「我的」上面、功能页能进插件管理、我的页不再有插件管理）；`emergency_stop_m4_41_test.dart` 的抽屉断言从三项改成四项；全量 **466/466** |
| 产物 | App **0.4.42+68**，APK 73,049,398 字节，`versionCode 68`，SHA256 `9C0B7C8C6A45EE83834A1529B6B74E17D2F48C3DFA0E195F0CABDBE1E87632C7`，三处同哈希 + `/api/v1/app/version` 回读一致；插件未改（0.2.30） |
| 未做 | 「使用文档」仍在「我的」；「功能」页目前只有一行，后续放定时任务 / 技能等；抽屉「历史会话」在插件直连下仍为空（待定修或删） |

### M4.43（待做）复查后遗留问题：已整理成给 dsh 的指令

| 项 | 内容 |
|---|---|
| 起因 | 用户：「我已经用dsh做完了，帮我看看还有没有需要改进的地方」→「有什么需要做修改的，你生成指令，我发给dsh做」 |
| 交付 | `docs/research/DSH_INSTRUCTIONS_2026-11-22.md`（601 行，8 条可独立执行的指令 + 2 条已修说明） |
| 本轮已直接修掉 2 个 bug | ① `hub.js` 会话永久锁死（`SESSION_BUSY` 死锁）：agent 中途掉线收不到终态事件，`busy` 永不放行，新增 `#releaseAllBusy()`（`:242 / :251-262`），配 `test/session-busy-release.test.js` 3 例；② `server.js` 坏 JSON 体回 500：全局 catch 按 `HubError` 自身 status 回包（`:158-166`），配 `test/bad-json-400.test.js` 2 例 |
| 基线 | 插件 `node --test "test/*.test.js"` **106/106 PASS**；App `flutter test test/` **466/466 PASS** |
| 待做（已写成指令） | P0：抽屉/顶栏「历史会话」死链（App 调 `/api/v1/conversations`，插件从未实现，是 `backend/` 老后端接口）；P0：token 无限累积（实测 **223 条全部未过期**，agent 189 条，根因 `supervisor.js` 无上限重启 + `serve.ts` 每次启动重新 pair + `hub.js pair()` 无条件发新 token 且 agent deviceId 每次新 `ulid()`）；P1：App token 明文落盘；P1：`afterSeq` 非法值静默返回全量；P2：404 配 `BAD_REQUEST`；P2：`file/raw` 无 Range；P2：会话直播 187~253 KB 无 gzip；P2：根目录两个 0 字节误建文件 |
| 重要提醒 | 本轮修的两个 bug **需要完整重启 DSH 才生效**（插件仍 0.2.30，进程里还是旧代码） |
| 明确不放进本轮 | `resolveParentDir`（`lib/index.js:1235-1239`）放行任意已存在目录——是 M4.13 故意开的，收紧需先定产品口径；工作区名 `../../escape-probe` **其实没有逃逸**（`lib/index.js:1250` 消毒连盘符冒号一起替换），M4.40 里那句容易被读成漏洞 |
| 环境限制 | 本机 `flutter analyze` 崩溃（`analysis server exited with code 255`），只能靠 `flutter test` + 人工读代码，无法静态分析 |

### M4.44 第一阶段六条（安全与行为正确性）

| 条 | 现象 | 根因 / 改法 | 验收 |
|---|---|---|---|
| ① 紧急停止 | 点了「紧急停止」，电脑上的任务还在跑 | 原来只 `disconnect()`；新增 `emergencyStop()`：`task.cancel` → 等终态或 3 秒 → 再断开，返回三态并原话回显 | `emergency_stop_m4_44_test.dart` 4 例 |
| ② 审批弹层 | 下滑/返回键直接把操作拒了 | `ApprovalDecision` 改 `approved/denied/later`，关闭只产生 `later` 且不重弹 | `approval_later_m4_44_test.dart` 5 例 |
| ③ 凭据存储 | API Key 明文在 JSON、token 明文在 tokens.json | Key 进 secure storage + 旧文件迁移；token 只存 sha256 + 旧文件迁移；新增 ACL 收紧与代清理工具 | 4 + 4 + 7 + 7 例；现网 285 行全为 tokenHash |
| ④ 地址策略 | 公网 http 也能连 | `NetworkUrlPolicy`：公网必须 https/wss，明文只允许回环与私网并提示 | 7 + 3 例 |
| ⑤ 发布链路 | debug 签名、版本靠手抄、内网地址内置 | 独立 keystore（仓库外）+ `tools/verify-release.mjs` 四项校验 + `--dart-define` 注入默认地址 | apksigner 证书 CN=DeepSeek Remote；四项全绿 |
| ⑥ 静态分析 | 中文路径下 analyze 必崩 | ASCII junction `C:\Users\user\dsh-tools\build\deepseek-mobile`；并清 7 条机械告警 | 37 → 30 条，0 error |

未做：第二阶段（轮询协调器 / 统一会话入口 / 模式改名）与第三阶段（拆 LiveStore、desktop_session_screen、assistant_screen）。剩余 30 条 analyze 告警全是删页留下的死代码，随第三阶段一起清。

### M4.45 新建的工作区让电脑认下来 + 换签名导致的安装冲突

| 项 | 内容 |
|---|---|
| 用户反馈 | 「新建工作区后电脑dsh端没有显示」；随后手机安装报「软件包与现有软件包存在冲突 / 开发者签名有异常」 |
| 根因 ① | `createDesktopWorkspace()` 只 `mkdirSync`，没调 `workspaceRegistry.create(path, title)`；DSH 的工作区列表来自注册表而不是扫盘 |
| 根因 ② | M4.44 换成了独立 release keystore（`CN=DeepSeek Remote`），手机里已装的是 Flutter 默认 debug 签名（`CN=Android Debug`），Android 不允许跨签名覆盖安装 |
| 改动 | 插件新增 `registerDesktopWorkspace()` 并在两个返回分支调用（`registered` 布尔返回，复用目录也幂等补注册）；`key.properties` 加 `useDebugSigning` 开关，本轮用 debug 签名 |
| 验收 | 插件 **146/146**；App **497/497**；APK 73,181,078 字节 / versionCode 71；`apksigner` 证书 CN=Android Debug（与已装版本同签名）；`/api/v1/app/version` 与 `tools/verify-release.mjs` 四项一致 |
| 未做 | 手机端没把 `registered=false` 显示出来（注册失败时仍提示「已建好」）；正式签名切换仍需卸载重装一次 |

### M4.46 统一轮询协调器（第二阶段第 ⑦ 条）

| 项 | 内容 |
|---|---|
| 问题 | 任务页/工作区页各自 `Timer.periodic(5s)`；`IndexedStack` 保活导致「看着 AI 助手页也照样每 5 秒请求」；定时器不看请求是否在途，弱网时请求叠起来；失败也不改节奏 |
| 改动 | 新增 `app/lib/services/poll_coordinator.dart`（`pollBackoffDelay` + `PollCoordinator`：一次只跑一个、失败 2 的幂退避封顶 30 秒、成功复位、`refreshNow()`）；`TasksScreen` 新增 `active` 参数并由 `RootShell` 用「当前页 + App 前台」计算；`WorkspaceScreen` 切后台即停、回前台立刻补一次 |
| 验收 | 新增 `app/test/poll_coordinator_m4_46_test.dart` **7/7**（退避数学、激活/停用、在途闸门、失败退避与复位、`refreshNow`、页面级「可见→切走→切回」）；反证：把 `active` 强制 true → 该例失败（`Expected: <1> Actual: <3>`）；全量 **504/504** |
| 交付 | APK 73,181,078 字节 / versionCode 72 / SHA256 `D6F63B87…A376FF6B`；debug 签名（可覆盖升级）；三处同哈希 + 接口回读 + `verify-release.mjs` 四项一致 |
| 未做 | 桌面直播页仍用 M4.38 的独立退避（规则相同、代码还没并）；插件没有推送通道；⑧ 统一会话入口、⑨ 模式改名仍待做 |

### M4.47 统一「会话」入口（第二阶段第 ⑧ 条）

| 项 | 内容 |
|---|---|
| 问题 | 会话有三个入口（AI 助手顶栏历史弹层、抽屉「手机对话」、抽屉「历史会话」）、两套数据源、两种交互；用户得记「要找的那条在哪个入口」 |
| 改动 | 新增 `app/lib/screens/session_center_screen.dart`（远程电脑 / 本机直连两组，存档会话标「已存档」，点本机对话关页并回调 id）；抽屉两段合成一段「会话」+「全部会话」入口（每组最多 3 条）；`assistant_screen.dart` 的顶栏历史按钮改为 push 会话中心 |
| 验收 | 新增 `app/test/session_center_m4_47_test.dart` **5/5**（两组同列 / 点远程进直播 / 点本机关页并回调 / 抽屉只剩一段「会话」并能进中心 / 两个来源都空给人话）；反证：把「全部会话」的 onPressed 改 null → 第 4 例失败；全量 **509/509** |
| 交付 | APK 73,213,886 字节 / versionCode 73 / SHA256 `906F8D5E…A266A70B`；debug 签名可覆盖升级；三处同哈希 + 接口回读 + `verify-release.mjs` 四项一致 |
| 未做 | 抽屉每组只显示最近 3 条（第 4 条起进中心，有意）；本机对话仍只在本机 |

### M4.48 两档改名 + 首次切换说明（第二阶段第 ⑨ 条，第二阶段收口）

| 项 | 内容 |
|---|---|
| 问题 | 「手机 / 电脑」听起来像两台设备，其实是两种对话方式；切过去会发生什么（要不要自己的 Key、能不能读写工作区）没有任何一句说明；抽屉里同一件事还叫「本机直连」 |
| 改动 | `mode_intro.dart` 新增 `ModeIntroCopy`（标题 + 本机/远程两段 + 「知道了」）；`assistant_screen.dart` 胶囊改名「本机对话 / 远程电脑」、新增可注入 `modeIntro`、`_setMode()` 在未看过时挂 `_ModeIntroCard`（`accentSoft` 卡片、右上 `ValueKey('modeIntroClose')`、点「知道了」写 `mode_intro_seen_v1`）；`root_shell.dart`、`session_center_screen.dart` 的「本机直连」统一成「本机对话」；`cloud_chat_screen.dart` 空态改口 |
| 验收 | 新增 `app/test/mode_intro_m4_48_test.dart` **4/4**（新名与旧名 / 首次出现并记住 / × 也能收起 / 已看过不再打扰且不重写存储）；反证：把 `_setMode()` 里的 `if (!_modeIntro.seen) _showModeIntro = true;` 换成空块 → 第 2、3 例失败；6 个受改名影响的测试同步；全量 **513/513** |
| 踩坑 | `find.byIcon(Icons.close_rounded)` 撞到别的关闭按钮 → 加 `ValueKey`；改名后抽屉分组标题与胶囊同名导致 `findsOneWidget` 变 2 → 抽屉断言一律 `descendant(of: find.byType(Drawer))` |
| 交付 | APK **73,213,886 字节** / versionCode 74 / SHA256 `ECD2E0CB…C6F40CAC`；debug 签名可覆盖升级；三处同哈希 + 接口回读 + `verify-release.mjs` 四项一致；`flutter analyze` 32 条、0 error |
| 未做 | 说明只在用户点胶囊切档时出现（从会话中心打开本机对话不重复教育，有意）；第三阶段拆 `LiveStore` / `desktop_session_screen.dart` / `assistant_screen.dart`，顺带清剩余死代码告警 |

### M4.49 插件热修：便携版 DSH 下 Agent 起不来（「工作区怎么没有了」）

| 项 | 内容 |
|---|---|
| 问题 | 手机端工作区主 Tab 有内容，点右上角文件夹进二级页却是「电脑端还没有配置工作区（M1_WORKSPACE_ROOT）」。现场 `agentOnline:false`、没有 `serve.ts` 进程；手动跑入口报 `未找到 DeepSeek Harness 安装（可通过 DSH_INSTALL_ROOT 指定）`。根因：agent 只找 PATH 的 `dsh.cmd` / `%LOCALAPPDATA%` 默认安装位，而 DSH 是便携版装在 `<DSH 安装目录>` |
| 改动 | 新增 `dsh-plugin-m1/lib/dsh-install.js` `resolveDshInstallRoot()`（显式 env → `dirname(process.execPath)`，要求 `resources/app.asar` 在）；`supervisor.js` 加 `dshInstallRoot` 参数并注入 `DSH_INSTALL_ROOT`、首次启动多打一行安装目录；`index.js` apply 时传解析结果；`agent/src/harness/acp/launcher.ts`（插件副本 + 项目根 `agent/` 同步）新增 `installRootFromParentExe()`（Windows 问父进程 exe，是 `DeepSeek Harness.exe` 就取 dirname），排在抛错之前兜底；插件版本 0.2.33 → **0.2.34** |
| 验收 | 插件测试 **157/157**（原 146 + 新增 `test/dsh-install-root.test.js` 7 例、`test/agent-parent-discover.test.js` 4 例）；反证：把 `resolveDshInstallRoot()` 在显式 env 后立刻 `return ''` → 便携版推导用例失败；现场证据：修复后 supervisor 下一次重试成功（`serve.ts` pid 33512、父进程 `DeepSeek Harness.exe` pid 24532），`/api/v1/health` `agentOnline:true`，agent 刷出 11 个工作区根 |
| 踩坑 | `HARNESS_NOT_INSTALLED` 在文件顶部注释里也出现，`indexOf` 拿到的是注释 → 测试改成匹配 `throw new HarnessError('HARNESS_NOT_INSTALLED'`；插件版本在 health 里要重载插件才更新 |
| 未做 | 手机端「已连上但 Agent 掉线」时仍显示「还没有配置工作区」，没说明是没连上（`liveStore.deviceOnline` 已有信号，`ProjectsScreen` 没用）→ 下一步做掉线态文案 + 重试 |
| 报告 | [docs/research/M4_49_REPORT.md](docs/research/M4_49_REPORT.md) |

### M4.50 工作区「新会话」改成送去真正的对话框（「新建对话没有对话框」）

| 项 | 内容 |
|---|---|
| 问题 | 工作区详情页点「在这里新建会话」只弹一句「已请电脑在「示例项目C」里新建会话」，页面照旧空态、输入框照旧灰着；电脑端会话列表也没有。磁盘上其实建出来了：`…\sessions\--D-~4E07…--\97e99c63-…\session.v4.jsonl.zstd`（22:29:11，header `cwd=D:\Projects\示例项目C`）。根因是**两条进程两套会话表**：手机发 `conversation.create`，会话由电脑端 Agent 的 ACP 子进程在磁盘上建；而手机工作区列表与电脑端列表都读电脑端主进程内存里的 `sessions`（`lib/index.js:1516 listDesktopTasks()` → `ctx.get('sessions').list()`，DSH 的 `sessions` 服务自述 "In-memory session store… Persistence is intentionally not implemented here"） |
| 改动 | 不再建空会话。新增 `app/lib/services/remote_chat_intent.dart`（`RemoteChatRequest` + `RemoteChatIntent` 单例，open/pending/take）；`LiveStore.startNewConversation()` 绑目录并清空旧会话状态（`_conversationId`/`_messages`/`_taskState`…），下一次 `sendPrompt` 才真正 `createConversation()`；`workspace_screen.dart` 三个「发完即忘」的方法（`_bindAndHint`/`_createSession`/`_renameSession`）合并成 `_startNewChat()` = 绑目录 + 广播意图 + pop；AppBar / 空态按钮 / 文字链 / FAB / 输入条 `onTap` 全指向它；空态文案改「点下面的按钮去 AI 助手的「远程电脑」里发第一条消息」，输入条由 `enabled: hasTask` 改 `readOnly: !hasTask`；`tasks_screen.dart` + `root_shell.dart` 透传 `onOpenAssistant`（切回 AI 助手 Tab）；`assistant_screen.dart` 监听意图 → 切「远程电脑」档 + `startNewConversation()` + 聚焦输入框（`live.isBusy` 时只记目录 + 提示），新增 `modeForTest` 便于测试 |
| 验收 | 新增 `app/test/new_chat_m4_50_test.dart` **3/3**（切档 + 目录交给新会话 / 忙时不打断只记目录 / 意图只消费一次）；改 `workspace_m4_test.dart`、`tasks_m4_11_test.dart` 两例旧断言；反证：注释掉 `RemoteChatIntent.instance.open(...)` → 这两例失败（`Expected: 'D:\\Projects\\示例项目B'`、`Expected: 'D:\\work\\demo'`），恢复后 23/23；全量 **516/516**；`flutter analyze` 32 条、0 error |
| 踩坑 | 改 `enabled` 为 `readOnly` 后旧测试 `field.enabled` 断言失效，改断 `readOnly`；`tasks_m4_11` 的 fake store 需要补 `pendingWorkspaceCalls` + `setPendingWorkspace` 覆写 |
| 交付 | App **0.4.50+75**；APK **73,213,886 字节** / SHA256 `17668D5BED32266A61E2A3B10AD8573BA9FBB4D55B5DFA00ECA4C3D447985EA0`；debug 签名可覆盖升级；构建产物 + `dist/DeepSeek-Remote-AI-v0.4.50-m4.50.apk` + `dist/DeepSeek-Remote-latest.apk` + 根目录同名 APK 四处同哈希；`verify-release.mjs` 四项一致；`/api/v1/app/version` 回读 code 75 / `0.4.50-m4.50` / size 与 sha 一致 |
| 未做 | 电脑端仍看不到手机新建的会话（两条进程各一套会话表）。要彻底修需把 Agent 建的会话登记进电脑端（会与 ACP 子进程抢同一个会话文件），方案未定；工作区二级页的「已连接但 Agent 掉线」文案也仍未改 |
| 报告 | [docs/research/M4_50_REPORT.md](docs/research/M4_50_REPORT.md) |
### M4.51 工作区项目卡默认折叠（一个项目 21 条会话铺满首页）

| 项 | 内容 |
|---|---|
| 问题 | 用户截图（工作区主 Tab）：`deepseek手机端` 一个项目 21 条会话全部展开，项目卡一路拖出屏幕，想找那条「直播中」的会话要先翻过十几条「已存档」。M4.13 引入分组折叠时默认是**全展开**（`_collapsed` 为空），当时一个项目只有几条会话；跑久了就变成「首页只剩一个项目」。 |
| 改动 | `app/lib/screens/tasks_screen.dart`：`Set<String> _collapsed`（空 = 全展开）换成 `Set<String> _expanded`（空 = 全折叠）；`_ProjectGroupCard.expanded` 改 `_expanded.contains(group.path)`；`_toggleGroup()` 在 `_expanded` 上加/删；项目头右侧加 `AnimatedRotation` 小箭头（`Icons.expand_more_rounded`，展开转 180°），只在有会话时出现，空项目不画。折叠状态只存页面内存（与 IndexedStack 保活一致），不写设置、不跨重启，各项目独立。 |
| 验收 | 新增 `app/test/workspace_fold_m4_51_test.dart` **3/3**（默认折叠 + 摘要给会话数 / 点开收起且互不影响 / 空项目无箭头）；反证：把 `expanded: _expanded.contains(group.path)` 改成 `expanded: true` → 2 例失败（`+1 -2`），恢复后 3/3；连带改 5 个旧断言（`workspace_m4_test.dart` 的 M4.13 用例改「默认折叠、可点开」，`archive_m4_10_test.dart` 两例、`tasks_m4_11_test.dart` 三例先点开 `poetry` 项目）；全量 **519/519**；`flutter analyze` 32 条 0 error（与 M4.50 同数，无新增）。 |
| 踩坑 | 改名项目头为「默认折叠」后，旧断言全部假定会话已可见 → 依次在断言前补「点项目头」（`find.text('poetry').last`，因为胶囊行也有同名项目，`.last` 才是项目卡）；存档页那例一开始只匹配到 2 个 `poetry`，加 `.last` 解决。 |
| 交付 | App **0.4.51+76**（`0.4.51-m4.51`）；APK **73,213,886 字节** / SHA256 `5C873F3C93F6F2DA0F13524ECE0EAE10D087E1CC0E3D942FE890B609731DF811`；debug 签名可覆盖；构建产物 + `dist/DeepSeek-Remote-AI-v0.4.51-m4.51.apk` + `dist/DeepSeek-Remote-latest.apk` + 根目录同名 APK 四处同哈希；`verify-release.mjs` 四项一致；`/api/v1/app/version` 回读 code 76 / size / sha 一致。 |
| 未做 | 折叠状态不持久（重启回默认折叠）；筛「进行中 / 等待授权」时结果仍收在卡里（摘要会写「N 个进行中」），要不要筛选时自动摊开未定；M4.49/M4.50 遗留不变——工作区二级页的 Agent 掉线态文案、电脑端看不到手机新建会话的架构问题。 |
| 报告 | [docs/research/M4_51_REPORT.md](docs/research/M4_51_REPORT.md) |

### M4.52 手机没有 WPS 也能读 .docx 正文（文件页文字预览）

| 项 | 内容 |
|---|---|
| 问题 | 用户截图：工作区里打开 `示例文档.docx`，页面只有「用其他应用打开」兜底面板；点按钮后提示「手机上没有能打开这种文件的应用」。这台手机没装 WPS，于是 `.docx` 在 App 里彻底读不到——App 不预览、外部也没人接。旧实现把 `doc/docx/xls/xlsx/ppt/pptx/csv/tsv` 一律当二进制（`previewKindOf()` → `FilePreviewKind.office`），且有 `FileOpener` 把所有 `PlatformException` 吞成 `false`，`NO_APP` 和 `OPEN_FAILED` 在 UI 上是同一句话 |
| 改动 | 新增 `app/lib/services/office_text.dart`（纯 Dart 最小 zip 读取 + docx 正文抽取：EOCD/中央目录/本地头，`stored` 直取、`deflate` 走 `ZLibDecoder(raw: true)`，`docxXmlToText()` 把 `<w:tab/>`、`<w:br/>`、`</w:p>`、`</w:tc>` 等转成制表/换行并还原实体，`isDocxFileName()` 只认 `.docx`，zip64 返回 null）；`file_viewer_screen.dart` 增 `_officePreview` + `_maxDocxBytes = 12MB`，`_loadBytes()` 抽正文，`_buildBinaryBody()` 命中时显示「按文字预览（排版和图片不显示）」+ `SelectableText` + 新 `_OfficePreviewFooter`（右侧仍可「用其他应用打开」），抽取失败时文案改成「这份 .docx 里没读出文字（可能加密或不是标准格式），交给手机上的 WPS 打开试试。」 |
| 验收 | 新增 `app/test/office_text_m4_52_test.dart` **8/8**（stored/deflate zip、缺条目/坏 zip、XML→文字含制表换行实体、超长截断、`isDocxFileName` 边界、文件页显示正文且仍能调外部应用、坏 docx 提示没读出文字）；反证：`final officePreview = false && …` → 文件页那例失败（`+6 -1`），恢复后 8/8；全量 `flutter test` **527/527**；`flutter analyze --no-pub` 32 条、0 error |
| 踩坑 | pwsh 命令行里带中文字面量做 `.Replace` 会把「手」写成「机」，污染了 `empty_state_test.dart` / `widget_test.dart`（出现「AI 助机」「机机端」），首跑全量挂 1 例——改用 edit 工具逐处修回，并定下规矩：**中文改动只用 edit/write 工具，不放进 pwsh 命令** |
| 交付 | App **0.4.52+77**（`0.4.52-m4.52`）；APK **73,230,270 字节** / SHA256 `B1E53C95BA3BEDE01E6DF11288453FDD4DFD20493200082EB54CBF2665358F67`；debug 签名可覆盖；构建产物 + `dist/DeepSeek-Remote-AI-v0.4.52-m4.52.apk` + `dist/DeepSeek-Remote-latest.apk` + 根目录同名 APK 四处同哈希；`verify-release.mjs` 四项一致；`/api/v1/app/version` 回读 code 77 / size / sha 一致 |
| 未做 | 不支持 `.doc`（97-2003 二进制）、`.xlsx` / `.pptx` 也不再进 App 内预览，仍交给外部应用；排版/图片/表格线不显示（只抽文字）；`FileOpener` 仍分不清「没装应用」与「打开失败」；M4.49/M4.50/M4.51 遗留不变（工作区掉线态文案、电脑端看不到手机新会话的架构问题、折叠状态不持久） |
| 报告 | [docs/research/M4_52_REPORT.md](docs/research/M4_52_REPORT.md) |

### M4.53 插件的提问接管改回「只看手机在看哪条会话」（电脑上的「确认需求」卡回来了）

| 项 | 内容 |
|---|---|
| 问题 | 用户报「电脑上的这个审核怎么没了」，截图里手机「桌面直播」页挂着「电脑在等你回答（2 个问题）」，电脑上却没有那张「确认需求」卡，会话看起来是卡住的。根因：`dsh-plugin-m1/lib/index.js` 的 `ctx.on('user-questions/request', …)` 门禁是 M4.31 加的 `if (!watching && !phoneOnline()) return next();`，`phoneOnline = () => Number(hub?.appCount ?? 0) > 0`——手机只要连着（前台后台都算），插件就恒接管提问，而 waterfall 一旦接管，桌面默认问答器（`next()`）就不再被调用，电脑自然不出卡。授权走另一条 `approval/request`，门禁一直只有 `isWatching`，所以只有提问有这个 Regression |
| 改动 | 门禁收回成 `if (!isWatching(sessionId)) return next();`，删掉 `phoneOnline`；注释保留 M4.31 来由并写明为什么收回。语义回到与授权一致：**手机正停在这条会话的直播页才接管，其余时候电脑照常弹卡**。插件版本 `0.2.34 → 0.2.35` |
| 验收 | 新增 2 例——「M4.53 手机连着但没看这条会话时，提问仍交回电脑」（`isWatching:false` + `phoneOnline:true`，断言 `next()` 被调 1 次、无挂起项、无「接管提问」日志）、「M4.53 提问接管只看 isWatching，不再看手机在不在线」（截 handler 源码断言无 `phoneOnline`、门禁是 `if (!isWatching(sessionId)) return next();`）；插件全量 `node --test 'test\*.test.js'` **159/159**（原 157 + 2）；反证：门禁临时改回旧写法后第二条用例失败（`ERR_ASSERTION`，actual 含 `phoneOnline`），恢复后 159/159；重载 bundle 后 `/api/v1/health` → `version:"0.2.35"`、`agentOnline:true`、`apps:1` |
| 踩坑 | ①Host 事件目录里只有 waterfall `user-questions/request`，没有 `user-questions/requested` 广播事件，所以「两端同时出卡」做不到：接管后桌面不出卡，先 `next()` 出卡又没有通道把电脑那张卡收掉——这条只能二选一；②插件里挂起的提问是内存 Promise，热重载会把旧模块连同 Promise 丢掉，那条提问只能等 5 分钟超时（本次重载时它已超时，没有可见影响） |
| 交付 | 插件 **0.2.35**，已热重载生效（`plugin_manager` 关再开 bundle `dsh-plugin-m1`）；手机 App 未改动，仍是 **0.4.52+77** / APK 73,230,270 字节 / SHA256 `B1E53C95…358F67`；插件测试 159/159，App `flutter test` 仍 527/527 |
| 未做 | 手机正盯着这条会话的直播页时，电脑仍不会出卡（waterfall 单向接管决定，需要 Host 侧广播或撤销接口才能双端）；M4.49 工作区掉线态、M4.50 电脑端看不到手机新会话、M4.51 折叠状态不持久仍未做 |
| 报告 | [docs/research/M4_53_REPORT.md](docs/research/M4_53_REPORT.md) |

### M4.54 电脑和手机同时出现同一张提问卡（双端赛跑）

| 项 | 内容 |
|---|---|
| 问题 | M4.53 把提问接管收成「手机正看着这条会话才接管、其余交给电脑」，用户接着要「两边同时都有」。Host 事件目录里只有 waterfall `user-questions/request`，没有广播事件、也没有撤销桌面卡片的接口，看上去只能二选一 |
| 关键发现 | 拆开 `resources/app.asar` 找到 GUI 提问卡的实现 `@deepseek-ai/dsh-client-ui-user-questions`，其 README 说明：卡片由「活着的 Host 请求」+「Session 的 `userQuestions` 投影」驱动，多个客户端可同挂同一 pending，**先答者生效、晚到的提交被 gateway 静默丢弃**，投影不再列出该 call 时卡片自己收掉。所以只要桌面问答器真的被调用，两边就能同时出卡；手机先答后电脑那张由投影自动关闭 |
| 改动 | `dsh-plugin-m1/lib/index.js`：接管时先同步 `Promise.resolve(next())` 让电脑挂原生卡（异常兜 `{answers: []}`），`desktopAnswer.then(finish)` 让电脑的答案收掉这次提问；两个 5 分钟 timer 都 `.unref?.()`，手机卡超时只收手机、不碰电脑那张；注释写明四种走向。`questions.test.js` 改 2 例 + 新增 2 例。插件 `0.2.35 → 0.2.36` |
| 验收 | 插件全量 `node --test 'test\*.test.js'` **161/161**（原 159 + 2，进程正常退出 5.85s）；反证：把 `Promise.resolve(next())` 改成 `Promise.resolve({ answers: [] })` → 新增 2 例失败（`11 pass / 2 fail`），恢复后 13/13、全量 161/161 |
| 踩坑 | ①两个 5 分钟 timer 把 `node --test` 进程吊住，用 `process.getActiveResourcesInfo()` 看到两个 `Timeout` 后加 `.unref?.()`；②`Promise.resolve().then(() => next())` 让 `next()` 晚一个微任务，同步断言 `delegated === 1` 拿到 0，改成同步 `Promise.resolve(next())`；③又用 pwsh 拼中文 JS 写乱码——中文改动只用 edit/write 工具 |
| 交付 | 插件 **0.2.36**，已热载生效（`plugin_manager` 关再开 bundle `dsh-plugin-m1` 两次均 `applied`，`/api/v1/health` 回读 `version:"0.2.36"`、`agentOnline:true`、`apps:1`；期间几次 `HMR transactions cannot be nested` 是遗留未关闭事务，等待后自行恢复）。插件测试 161/161；手机 App 未改动（0.4.52+77） |
| 未做 | 两端无优先级（谁先答用谁），要电脑永远优先需另定规则；手机那张卡的收掉依赖手机端轮询/事件刷新（1.5–5 秒），不是瞬间消失；电脑刚答完、手机还没刷新那一两秒里在手机上点提交会看到「回答失败」（插件按 `QUESTION_NOT_FOUND` 处理，结果不受影响），要抹平需改手机 App；M4.49/M4.50/M4.51 遗留不变 |
| 报告 | [docs/research/M4_54_REPORT.md](docs/research/M4_54_REPORT.md) |

### M4.55 门禁放宽成「手机连着就接管」（中间步骤，未单独交付）

| 项 | 内容 |
|---|---|
| 问题 | 用户报「手机上还是没有」：电脑有卡，手机没有 |
| 改动 | `lib/index.js` 新增 `phoneConnected()`，门禁改成 `if (!isWatching(sessionId) && !phoneConnected()) return next();`；`questions.test.js` 改 3 例；插件 `0.2.36 → 0.2.37` |
| 验收 | 插件 162/162；真机仍只有电脑出卡 |
| 结论 | 门禁不是根因，问题在「事件根本不到插件」，并入 M4.56 一起解决 |
| 报告 | 见 M4.56 |

### M4.56 从会话日志认提问，手机能看到并回答（插件 0.2.40）

| 项 | 内容 |
|---|---|
| 问题 | M4.55 放宽门禁后手机仍无卡。写文件日志实测：`ctx.on('user-questions/request', …)` 一次都没被调用——DSH 的问答工具走 `userQuestions.askTimed()`（客户端决定），不派发 waterfall；插件的监听器收不到 |
| 改动 | `lib/index.js`：新增 `collectLogQuestions()`（从 live 会话日志里找「没有 `tool/result` 的 `ask_user_question` 调用」）、`serializeQuestionItems()`、`mergeQuestionEntries()`；会话详情 `questions` 与 `listPendingDesktop()` 都改为两路合并；`answerDesktopQuestion()` 新增日志路径——用 `agents.get(sessionId)` + `userQuestions.answer(agent, callId, {answers})` 交回，跳过时按每题空 `selected` 生成完整批次；删除 M4.55 遗留的三处临时诊断写盘 |
| 验收 | `questions.test.js` 18/18（新增 4 例，含 `collectLogQuestions` 行为用例）；插件全量 **166/166**；反证：把「已回答」判定去掉 → 行为用例失败（17/1），恢复后 18/18；另修 `pending.test.js`、`session-events.test.js` 的注入表（此前 9 例 `ReferenceError`） |
| 踩坑 | ①`/api/v1/health` 的 `version` 读的是 `package.json` 即时值，**不能**证明代码已加载，要另找标记；②`node --test` 必须给 glob；③临时诊断写盘验证完要删干净 |
| 交付 | 插件 **0.2.41**（0.2.40 真机试出「8 张空卡」：结果事件 id 在 `toolCallId` 上，只认 `callId` 会让历史提问全被当成待答，0.2.41 改成 `toolCallId ?? callId ?? message.source.callId`），`plugin_manager` 关再开 `applied`，`/api/v1/health` → `version:"0.2.41"`、`agentOnline:true`；手机 App 未改动（仍是 0.4.52+77），不用换 APK |
| 未做 | 只认 live 会话的日志（已归档会话认不到）；手机看到卡依赖手机连着插件；电脑先答、手机未刷新那一两秒提交会显示「回答失败」（结果不受影响）；M4.49/M4.50/M4.51 遗留不变 |
| 报告 | [docs/research/M4_56_REPORT.md](docs/research/M4_56_REPORT.md) |
### M4.57 功能页新增「接收文件」（App 0.4.57+78 / 插件 0.2.42）

| 项 | 内容 |
|---|---|
| 问题 | 用户要「我想看做好的文件，我让你发你就发到那，我可以查看」。原来手机上只能进「工作区 → 目录 → 浏览文件」一层层翻；不在授权根里的文件根本看不到；附件只有「手机 → 电脑」方向 |
| 改动 | 插件：`receivedDir`（`<stateDir>/received`，启动自建）、`listReceivedFiles()`（mtime 倒序、跳过隐藏与子目录、上限 200）、`resolveReceivedFile()`（只认 `basename`，拒 `.`/`..`/隐藏名）、`deleteReceivedFile()`，并挂进 `pageContext`；`server.js` 加 `GET /api/v1/received`、`GET/DELETE /api/v1/received/<name>`（app token、`application/octet-stream`、404 `NOT_FOUND`、405）。App：`history_api` 加 `ReceivedFile` + `listReceivedFiles`/`downloadReceivedFile`；`live_store` 两个封装；`file_viewer_screen` 新增 `fetchBytes` 来源（不读工作区、文本本地 UTF-8 解码、接收文件只读）；新页 `received_files_screen.dart`；「功能」页新增入口 |
| 验收 | App `received_files_m4_57_test.dart` 3 例；全量 **530/530**；插件 `received-files-route.test.js` 6 例 + `received-files.test.js` 4 例；全量 **176/176**；反证：把 `basename` 换成原样字符串 → 穿越用例失败，恢复后 10/10；`flutter analyze --no-pub` **32 issues、0 error** |
| 踩坑 | ①`EmptyState` 的四个参数全是必填，空态要同时给 `actionLabel`/`onAction`；②接收文件不是工作区文件，`FileViewerScreen` 必须绕开工作区接口并把「编辑」关掉；③文件名可能含中文与空格，路由用 `decodeURIComponent`、App 侧 `Uri.encodeComponent` |
| 交付 | App **0.4.57+78**（`0.4.57-m4.57`），APK 见 [README](../README.md) 的「从这里开始」；插件 **0.2.42**（`plugin_manager` 热载生效后 `/api/v1/health` 回读） |
| 未做 | 接收目录单向只读（App 不删不改）；不进子目录；超过 200 个更早的不显示；老插件（< 0.2.42）页面显示「读不到接收文件」；M4.56 的提问卡提交 404 仍待查 |
| 报告 | [docs/research/M4_57_REPORT.md](docs/research/M4_57_REPORT.md) |

### M4.58 手机回答提问：说清原因 + 真正修通（插件 0.2.43 → 0.2.44）

| 项 | 内容 |
| --- | --- |
| 问题 | 手机点提问卡的「提交」，红条一律是「回答问题失败：接口不存在（HTTP 404）：请确认地址是 M1 后端的根地址」；插件失败时只返回 `false`，`server.js` 一律回 404 `QUESTION_NOT_FOUND`，App 对 404 又有固定文案，真正原因被盖住 |
| 改动 | 插件：`questionAnswerFailure` + `fail(code, message)`，失败码 `QUESTION_NOT_FOUND` / `NO_QUESTION_SERVICE` / `NO_AGENT` / `NOT_CONTINUED` / 异常码，并写日志；Agent 查找加 `agents.list()` 兜底；`pageContext.desktopQuestionError()`；`server.js` 失败改回 **409** 并带上 `message`（App 对 409 会把原因拼进提示，不用重装） |
| 验收 | `questions.test.js` **20/20**（新增「回答失败会说明原因」五种情况、「服务端把失败原因带回手机」）；插件全量 **178/178**；`node --check` 两个文件 exit 0 |
| 踩坑 | ①2026-11-25 12:56 起 `plugin_manager` 一直报 `HMR transactions cannot be nested`，`operations.jsonl` 里全是 `started → failed`，0.2.42/0.2.43 都无法热载，只能彻底重启 DSH；②诊断发现「日志路径回答」对任何会话都 404（连正在运行的会话自己发卡也一样），排除了「会话已结束」这个假设 |
| 追加 | 0.2.43 上线拿到 `409 NOT_CONTINUED`：读 DSH 源码确认 `userQuestions.answer()` 只认 `continued` 提问，open 提问只能靠 waterfall 返回值；而 waterfall 的 `req` 没有 `wait.callId`，插件用自造 `q_…` 当键、手机传真实 `call_00_…`，对不上。0.2.44 加 `questionContentKey`（会话+题面）两路去重、日志在前 waterfall 在后（留下带选项的那条）、回答时先按内容找 waterfall 挂起项并 `finish()`。真机：卡片带选项、可提交，答案回到工具 |
| 交付 | 插件 **0.2.44**（`package.json`，已热载 `applied`，`/api/v1/health` 回读 0.2.44）；App 无改动（仍是 0.4.57+78） |
| 未做 | 「电脑上已经答过、手机上还留着旧卡」时再点提交会看到 409（信息准确，但不是错误）；M4.57 接收文件路由已随这次重启生效，尚未真机验收 |
| 报告 | [docs/research/M4_58_REPORT.md](docs/research/M4_58_REPORT.md) |
### M4.59 手机原生回答提问：插件自己当 DSH 的浏览器客户端（插件 0.2.60）

| 项 | 内容 |
| --- | --- |
| 问题 | 手机上看不到提问卡（M4.55 前），或看得到但提交不生效（M4.56–M4.58）。根因：`user-questions/request` 是 **agent 作用域** waterfall，插件注册在根 `ctx` 上收不到；而从会话日志「猜」出来的提问只能用 `userQuestions.answer()` 交答案，它对 open 提问一律返回 false |
| 突破 | 从 `app.asar` 解出 `@deepseek-ai/dsh-api-gateway`，还原远程事件协议：WS `/api/remote.mux` + `$events` 流（`ready`/`emit`/`waterfall`/`cancel`），回答走 `POST /api/$events/result` 的 `client-request`，`payload` 必须恰好一个 `args` 字段；回环也要 cookie（`connection.authenticatedUrl()`）；不回 pong 会被关连接 |
| 改动 | 新 `lib/remote-events.js`：登录 → WS 升级 → 发 `open` → 解帧 → `handle.answer()`；补 pong 心跳与 3 秒退避重连。`lib/index.js`：`remoteQuestions` 收集远程提问，`remoteQuestionEntries()` 合并进 `/desktop/pending` 与会话详情 `questions`，`answerDesktopQuestion()` 优先走远程路径把答案作为 waterfall 返回值交回 Host |
| 验收 | 真机：`REMOTE waterfall … eventId=6b1b552e` → `WATERFALL keys=questions session=session-bd6f7b64 items=1` → 手机提交 `POST … answers=[{id:phone1,selected:["手机上提交成功"]}]` → `REPLY … {"ok":true}`，`ask_user_question` 拿到的就是手机上选的项；插件全量 **182/182**；`node --check` 两个入口 0 |
| 踩坑 | ①不回 WebSocket pong 会被服务端约 5 秒断开，表现为「拿到 ready 后再无任何帧」；②`$events/result` 的 `payload` 少包一层 `args` 会报 `requires exactly one plain-object args field`；③`/connect?token=` 能拿 cookie 但 WS 升级挂住，必须用 `/?token=`；④热载会留旧实例，同一 eventId 出现两条 REPLY |
| 交付 | 插件 **0.2.60**（已热载 `applied`，`/api/v1/health` 回读 0.2.60）；App 无改动（仍 0.4.57+78），因为卡片列表与提交都走既有接口 |
| 未做 | 热载前主动关闭旧远程客户端；把 `emit` 的会话活动接进直播页以替代轮询；`remote-client.on` 仍是手工开关 |
| 报告 | [docs/research/M4_59_REPORT.md](docs/research/M4_59_REPORT.md) |
### M4.60 远程客户端收尾：开关做成配置项 + 热载自动关旧连接（插件 0.2.61 → 0.2.62）

| 项 | 内容 |
| --- | --- |
| 问题 | 远程事件客户端只由 `stateDir/remote-client.on` 手工开关决定；每次热载都会留下上一版建立的 WebSocket，同一提问被两个实例各答一次（日志里同一 `eventId` 出现两条 `REPLY`） |
| 改动 | `lib/index.js`：开关改成 `config.remoteClient !== false`（默认开），`M1_REMOTE_CLIENT=0/1` 可强制关/开；句柄挂在 `globalThis.__m1RemoteClient`，新实例启动前先 `close()` 上一个；`ctx.effect` 注册卸载回调，插件被卸下时同步关连接 |
| 验收 | 插件 **182/182**；热载 0.2.61/0.2.62 后 `/api/v1/health` 回读版本、单条 `LOGIN` + `REMOTE ready`；`auto-answer` 自检两轮均 `REPLY … {"ok":true}` |
| 已知遗留 | 0.2.60 之前的实例没有登记句柄，无法被新代码关闭；自检仍看到两条 `REPLY`，**重启一次 DSH 即可清掉**，之后每次热载都会自动关旧连接 |
| 交付 | 插件 **0.2.62**（已热载 `applied`）；App 无改动 |
**M4.60 重启后验收（2026-11-26 22:52）**：`/api/v1/health` = `{"version":"0.2.62","agentOnline":true,"apps":4}`；远程客户端日志只有一条 `LOGIN status=303` + `REMOTE ready`（没有遗留实例）；`auto-answer` 自检 `eventId=e03140f4-2b10-40e2-b465-32f00f94e283` 只出现**一条** `REPLY … {"ok":true}`，工具拿到的就是自动选的那项 —— 重启把 0.2.60 之前的僵尸连接清掉了。顺带验收 M4.57：`GET /api/v1/received` 返回 1 个文件 `M4.57 接收文件说明.md`（4606 字节），`GET /api/v1/received/<name>` 200、`application/octet-stream`、4606 字节。
### M4.61 清理自检脚手架：诊断日志改成 `debug` 开关（插件 0.2.63）

| 项 | 内容 |
| --- | --- |
| 问题 | M4.58c–M4.60 期间为了定位「手机答不上提问」留了三类脚手架：每次请求都往 `<stateDir>/q-answers.log` 追加日志、`stateDir/auto-answer.on` 触发的自动抢答、以及一次失败的「`agent/created` 里取作用域」尝试 |
| 改动 | `lib/index.js`：`traceAnswer` 增加 `const debugEnabled = process.env.M1_DEBUG === '1' \|\| config.debug === true;`，默认直接 return、不写盘；删掉 `auto-answer.on` 自动抢答段；删掉 `agent/created` 注册块（实测 `this` 是 undefined，注册不进去）；相关注释改成现状描述 |
| 验收 | `node --check` 0；插件 **182/182**；热载 0.2.63 后 `/api/v1/health` 回读 `0.2.63`、`agentOnline:true`，运行数分钟 `q-answers.log` **不再生成**；用 `probe-m463.mjs` 模拟手机 HTTP 提交（`POST /api/v1/desktop/sessions/<sid>/questions/<qid>`）→ `200 {"ok":true,"answered":1}`，`ask_user_question` 收到的正是脚本选的那项 |
| 交付 | 插件 **0.2.63**（已热载 `applied`）；排查时仍可 `M1_DEBUG=1` 或插件配置 `debug: true` 打开同一份日志 |

### M4.62 直播推送（进行中，插件 0.2.67）

| 项 | 内容 |
| --- | --- |
| 问题 | 手机直播页靠 1.5–5 秒轮询，插件明明已经从远程事件客户端拿到 `api-session/*` 的 `emit`，却没有推给手机 |
| 改动 | 新增 `lib/live-hub.js`（`/api/v1/desktop/live` 的 WebSocket 握手、文本帧广播、ping/pong、`size`/`sent`）；`server.js` 的 `upgrade` 只处理该路径、其它**直接放行**；`index.js` 把 `emit(api-session/*)` 广播成 `{type:'session'}`、`waterfall`/`cancel` 广播成 `{type:'question',state}`，hub 挂在 `globalThis.__m1LiveHub` 上避免热载后「收连接的是旧 hub、广播的是新 hub」 |
| 踩坑 | ①第一版对非直播路径的升级写 404 并 `destroy()`，把中继的 `/ws` 掐掉（health `agentOnline:false`）→ 改成直接 return；②中继对同一个 socket 又握了一次手，连接被丢弃（`live:0`）→ 用 `request.__m1Live` 标记跳过 |
| 验收 | 插件 **182/182**；0.2.64–0.2.67 逐版热载 `applied`；探针 `probe-live.mjs` 拿到 `HTTP/1.1 101` + `{"type":"ready"}`，`health.live` 有连接数 |
| 未完成 | `session`/`question` 广播帧还没在真机上观测到（`session-frames 0`），推送链路尚未证明打通 |

### M4.63 启动自愈（App 0.4.58+79）

| 项 | 内容 |
| --- | --- |
| 问题 | 用户反馈「手机端 App 一直闪退」，清掉应用数据后能打开——本地存档把启动卡死，应用层没有自救手段 |
| 改动 | 新增 `services/boot_guard.dart`（`boot_attempts` / `boot_last_attempt_at`、`maxAttempts=3`、`window=3 分钟`）；`app.dart` 的 `initState` 改成 `_bootstrap()`：命中 `shouldReset()` 就 `disconnect()` 清存档并弹提示，再 `markAttempt()`，`restoreSession()` 之后在第一帧回调里 `markFirstFrame()`；自愈失败不影响启动 |
| 验收 | 新增 3 例（前两次不复位 / 连续三次复位 / 第一帧归零，含「隔 30 分钟不算连续」）；全量 **533/533**；analyze **32 issues、0 error**；反证（阈值临时改 1）→ 1 例失败，恢复后 3/3 |
| 交付 | App **0.4.58+79**；APK **73,295,806 字节**，SHA256 `2D09D8F7A7C31E986B57843257639A1EF7B09DDD9177EF279E91DDFF92F1EDDC`，四处同哈希，`verify-release.mjs` 四项一致；报告 `docs/research/M4_63_REPORT.md` |
| 未做 | 只兜启动期崩溃（第一帧之后崩溃不计数）；崩溃根因未定位（缺 `adb logcat` 崩溃栈） |

### M4.63b 更新说明自动发布 + 接收文件投递（插件 0.2.68）

| 项 | 内容 |
| --- | --- |
| 需求 | 用户要求「以后更新附上更新说明」，并希望做好的文件走「接收文件」发到手机 |
| 改动 | 新增 `docs/UPDATE_NOTES.md`（每次发版在顶部加一段 `## <版本号> — <标题>`）；`lib/appupdate.js` 新增 `readReleaseNotes()`：`notes` 未显式配置时按版本名前两段匹配该文件、截 1500 字，带进 `/api/v1/app/version` 的 `notes` 字段（App 的更新弹窗本来就展示 `info.notes`）；缓存键加上 `notes.length` 以免改了说明不刷新 |
| 验收 | 新增 `test/appupdate-notes.test.js` 3 例（按版本段抽取且不串段、无对应版本时为空、显式配置优先）；插件全量 **185/185**；热载 0.2.68 后 `/api/v1/app/version` 返回 `notesLen=250`，内容是 0.4.58 那段 |
| 投递 | `<DSH 数据目录>\dsh-plugin-m1\received\` 已放入 `DeepSeek-Remote-AI-v0.4.58-m4.58.apk`、`更新说明-0.4.58-m4.58.md`、`M4.63-启动自愈-报告.md`；`GET /api/v1/received` 四项、下载 200 |

### M4.64 文件分享（App 0.4.59+80）

| 项 | 内容 |
| --- | --- |
| 问题 | 用户反馈「文件不能分享和用其他应用打开」：这台手机没装 WPS，`.docx` 点「用其他应用打开」只弹「手机上没有能打开这种文件的应用」，而文件页没有别的出口，文档只好卡在那儿 |
| 改动 | `FileOpener` 新增 `shareBytes`（`MethodChannelFileOpener` 走 `deepseek_remote/files` 的 `shareBytes`，`FakeFileOpener` 记录 `shared`/`shareCalls`/`lastShared`）；`FileOpenBridge.kt` 抽 `prepareFile()` 统一校验与落盘，新增 `handleShareBytes`（写 `cacheDir/share/files/` → FileProvider `content://` → `ACTION_SEND` + `EXTRA_STREAM` + `createChooser`）；文件页 AppBar 增「分享文件」，`.docx` 文字预览底栏与「打不开」兜底面板都补「分享」，打开失败提示改成指路 |
| 验收 | 新增 `test/file_share_m4_64_test.dart` 3 例（接收文件可分享 / 分享失败有提示 / `.docx` 文字预览也能分享）；全量 **536/536**；analyze **7 issues、0 error**；反证（`_share()` 改成直接 return）→ 第 1 例失败，恢复后 3/3 |
| 交付 | App **0.4.59+80**；APK **73,361,342 字节**，SHA256 `5A60CE79E561BB07F3D252440D99AF520B7109FACB5A63DED0087605050D7C29`，四处同哈希，`verify-release.mjs` 四项一致；`/api/v1/app/version` 的 `notes` 已带 0.4.59 说明；报告 `docs/research/M4_64_REPORT.md` |
| 未做 | 只有拿到字节的文件能分享（工作区文本预览走字符串接口）；还没有「保存到手机」（`ACTION_CREATE_DOCUMENT` + `onActivityResult`） |
### M4.65 + M4.66 App 内充值页 + 功能页「更新日志」（App 0.4.60+81 / 插件 0.2.69）

| 项 | 内容 |
| --- | --- |
| 需求 | 用户问「充值页面能不能做」，随后要求「做」；同时要求「在功能界面专门放一个更新日志，每次更新日志都放在那里面」，并再次反馈「刚做的分享和用其他应用打开还是用不了」 |
| 改动（App） | 新页 `screens/recharge_screen.dart`（余额面板 + 三步流程 + 「打开官方充值页」/「已充值，刷新余额」+ 三张说明卡）；`profile_screen.dart` 的「去充值」改成 push 该页、返回后刷新余额；新页 `screens/changelog_screen.dart`（连电脑读插件，没连时回退 `assets/update_notes.md` 并在顶部说明来源）；`features_screen.dart` 新增「更新日志」行；`history_api.dart` 新增 `UpdateNote` 与 `listUpdateNotes()`，`live_store.dart` 新增 `loadUpdateNotes()`；`app/assets/update_notes.md` 随包一份并在 `pubspec.yaml` 声明 |
| 改动（插件） | `appupdate.js` 新增 `readUpdateNoteList(projectDir)`（按 `## ` 拆成 `{version, date, title, body}`）；`server.js` 新增 `GET /api/v1/app/notes`（认 app token）；`index.js` 挂 `pageContext.appNotes` |
| 验收 | App 新增 `test/recharge_m4_65_test.dart` 3 例、`test/changelog_m4_66_test.dart` 2 例，全量 **541/541**，analyze **33 issues、0 error**；插件新增 `test/app-notes-route.test.js` 3 例 + `appupdate-notes.test.js` 2 例，全量 **187/187**；热载 0.2.69 后 `/api/v1/app/notes` 返回 8 条、第一条 `0.4.60+81 充值页与更新日志` |
| 交付 | App **0.4.60+81**；APK **73,543,936 字节**，SHA256 `FA77CB13CE48DB5A7F131EC44787E5F302BFAC08730CBB28FD44CB2C5BF93625`，四处同哈希；`verify-release.mjs` 四项一致；插件 **0.2.69** 已热载；报告 `docs/research/M4_65_M4_66_REPORT.md` |
| 未做 | App 内不能直接付款（没有商户号，电脑端账户服务也只有读）；「用其他应用打开」在没装 WPS 的手机上仍会失败（已改成指向分享）；分享需用户先装 0.4.59+80 |

### M4.67 充值页能在 App 内付款（App 0.4.61+82）

| 项 | 内容 |
| --- | --- |
| 需求 | 用户问「充值页面还是实现不了吗」「dsh 这个充值界面做不到手机上面吗」，随后问「手机上登录成功怎么操作」并让继续做 |
| 关键事实 | 电脑端 DSH 的充值同样是嵌官方网页（`@deepseek-ai/dsh-client-ui-settings-account` 里 `showPage(openPlatformPage, 'top-up')`），付款表单从来不在 DSH 里；登录态存在电脑 Electron 会话，无法搬到手机 |
| 改动 | 新增 `app/lib/screens/recharge_web_screen.dart`（WebView 打开官方页、顶部确定值进度条、刷新、系统浏览器、`onNavigationRequest` 把 `alipays://`/`weixin://` 交给系统、主框架失败才报错、底部「我已完成，回去刷新」、`PopScope` 统一 `pop(true)`）；`recharge_screen.dart` 主按钮改「在 App 内打开充值页」并返回后刷新，系统浏览器降级为次级入口，步骤说明同步改写；`pubspec.yaml` 新增 `webview_flutter: ^4.14.1`；四处版本 → `0.4.61+82`；`docs/UPDATE_NOTES.md` 与 `app/assets/update_notes.md` 新增 0.4.61 段 |
| 验收 | 新增 `test/recharge_web_m4_67_test.dart` 3 例；改 `test/recharge_m4_65_test.dart`（主按钮进内嵌页、返回后刷新两次、次级入口调 `FakeUrlOpener`）与 `test/profile_balance_format_m4_32_test.dart`；全量 **545/545**、analyze **0 error**；反证（`_openRechargeInApp` 里直接 return）→「主按钮进 App 内嵌页」失败（3 pass / 1 fail），恢复后 4/4 |
| 交付 | APK **74,216,293 字节**，SHA256 `BB8B5544AAF0E485B617ACDBB9A7C1706EAF128124A0006B7CDF935B47CC607E`，`versionCode 82` / `0.4.61-m4.61`；四处同哈希；`verify-release.mjs` 四项一致；插件未改（仍 0.2.69）；报告 `docs/research/M4_67_REPORT.md` |
| 未做 | 付款仍在官方页面完成（官方没有下单接口）；支付宝/微信客户端支付依赖手机上装了对应 App；没有订单列表、发票与到账通知；WebView 登录态清数据后要重登 |

### M4.68 充值只保留 App 内入口（App 0.4.62+83）

| 项 | 内容 |
| --- | --- |
| 需求 | 用户看完 0.4.61 后说「只保留在应用内打开充值页」 |
| 改动 | `recharge_screen.dart` 删「用系统浏览器打开」按钮与 `_openRecharge()`、移除多余的 `_urlOpener` 字段，底部只剩「已充值，刷新余额」，注释/步骤说明改成「唯一入口」；`recharge_web_screen.dart` 删 AppBar 的浏览器按钮与 `_openExternal()`，`urlOpener` 只在 `onNavigationRequest` 里处理 `alipays://` / `weixin://`；四处版本 → `0.4.62+83`；`UPDATE_NOTES.md` 与 `app/assets/update_notes.md` 新增 0.4.62 段 |
| 验收 | `recharge_m4_65_test.dart` 的「次级入口交给浏览器」改成「只保留 App 内入口」（有主按钮、无浏览器按钮、`FakeUrlOpener` 未被调用）；`recharge_web_m4_67_test.dart` 的浏览器按钮用例改成「不再提供浏览器出口」（`byTooltip('用系统浏览器打开')` 为空）；`profile_balance_format_m4_32_test.dart` 加同样断言；全量 **545/545**、analyze **33 issues、0 error** |
| 交付 | APK **74,200,081 字节**，SHA256 `D51BD880818857AD4652B978A96437696DDC7078EFB71073B4415BD567A828D5`，`versionCode 83` / `0.4.62-m4.62`；四处同哈希；`verify-release.mjs` 四项一致；插件未改（仍 0.2.69）；报告 `docs/research/M4_68_REPORT.md` |
| 未做 | 没有浏览器降级后，官方页若在 WebView 里加载失败只剩「重试」；真机付款流程仍待用户验收 |

### M4.69 扫描件 .docx 按页看图（App 0.4.63+84）

| 项 | 内容 |
| --- | --- |
| 问题 | 用户发来「示例作业.docx」（5.39 MB）说「还是不让我打开」：文件页只显示「这份 .docx 里没读出文字」，而这台手机又没装能打开 .docx 的应用 |
| 根因 | 那份文档 `word/document.xml` 里 `<w:t>` 计数为 0（纯图片），文字抽取必然为空；它实际是 `word/media/image1..4.jpeg` 四张扫描照片（最大一张 5.2 MB）。文件页当时没有别的显示方式 |
| 改动 | `office_text.dart` 抽出 `_listEntries()` 复用中央目录解析，新增 `docxImagePages()`（只取 `word/media/` 图片、按文件名数字排序、上限 24 张 / 40 MB）；`file_viewer_screen.dart` 在 docx 无文字时渲染竖排图片预览，底栏说明改成「这份文档没有可选文字（多半是扫描件）」 |
| 验收 | 新增 `docx_pages_m4_69_test.dart` 5 例（有文字不误判 / 取图片 / 数字顺序 / 张数上限 / 文件页渲染）；全量 **550/550**、analyze **33 issues、0 error**；反证（去掉 `word/media/` 前缀判断）失败后恢复；真文件探针 `pages=4`、尺寸与 media 一一对应 |
| 交付 | APK **74,216,761 字节**，SHA256 `5B6DF297FE4D81E48BDC095A34CE2AB0B2431FBD20E461869A12B8A7CCF04B60`，`versionCode 84` / `0.4.63-m4.63`；四处同哈希；`verify-release.mjs` 四项一致；`UPDATE_NOTES.md` 与 `app/assets/update_notes.md` 已加 0.4.63 段；`received/` 投递 APK + 更新说明 + 报告 |
| 未做 | 不还原 Word 版式/页眉/表格线；纯图片文档没有可选文字；超过 24 张或 40 MB 的尾部不显示；`.doc`（OLE）仍只能分享或交给外部应用 |

### M4.70 打不开的文件不再给按钮（App 0.4.64+85）

| 项 | 内容 |
| --- | --- |
| 问题 | 用户装上 0.4.63 后仍报「还是不行」，截图是「用其他应用打开」失败后的 toast——这台手机没装能处理 .docx 的应用，点了必然失败 |
| 改动 | `FileOpener` 新增 `canOpenBytes()`（`MethodChannelFileOpener` 走原生 `canOpenBytes`，异常按 true）；`FileOpenBridge.kt` 只做 `resolveActivity` 判断、不启动应用；文件页 `_loadBytes()` 后 `_probeOpenable()`，`_canOpenExternal=false` 时藏掉「用其他应用打开」，兜底改「这个文件只能在电脑上看」并引导分享；扫描件底栏补一句「这台手机没有能打开它的应用，可以分享出去看」 |
| 验收 | 新增 `file_open_hidden_m4_70_test.dart` 3 例；定向 5 文件 **27/27**；全量 **553/553**；analyze **33 issues、0 error**；反证（`_probeOpenable` 强制不更新）失败后恢复 |
| 交付 | APK **74,217,001 字节**，SHA256 `9C3F2A978B5AD905A7960884241F33B352B938F1100919B7EC9A29A9B58C4CF7`，`versionCode 85` / `0.4.64-m4.64`；四处同哈希；`verify-release.mjs` 四项一致；`UPDATE_NOTES.md` 与 `app/assets/update_notes.md` 已加 0.4.64 段；`received/` 投递 APK + 更新说明 + 报告 |
| 未做 | 只看 MIME 有没有应用能接，接了但打不开（只认 .doc 的旧阅读器）仍需用户点一次才知道；根治仍要靠装阅读器 |

### M4.71 修好「检测不到能打开的应用」（App 0.4.65+86）

| 项 | 内容 |
| --- | --- |
| 问题 | 用户装上 0.4.64 后追问「还是不行，是检测不到吗，需要什么权限吗」。这不是运行时权限问题，是 Android 11+ 的包可见性 |
| 根因 | `AndroidManifest.xml` 的 `<queries>` 只声明了 `PROCESS_TEXT`，没有 `ACTION_VIEW`；系统不把候选应用暴露给本 App，`resolveActivity` 对任何文件类型都返回 null，于是「有没有应用能打开」永远判成没有，连装了 WPS 也会报 `NO_APP` |
| 改动 | manifest 的 `<queries>` 补 `ACTION_VIEW`/`ACTION_SEND`（`mimeType="*/*"`）；`handleCanOpenBytes` 改用 `context.packageManager.queryIntentActivities(intent, 0)` 取候选（再兜底 `resolveActivity`）；`handleOpenBytes` 去掉预检，改成 `try { startActivity } catch (ActivityNotFoundException)` 才报 `NO_APP` |
| 验收 | 版本断言测试通过；`flutter build apk --release` 成功（中途一次 Kotlin 编译错误：`queryIntentActivities` 接收者写错，已改成 `context.packageManager`）；`aapt2 dump badging` → versionCode 86 / `0.4.65-m4.65`；`verify-release.mjs` 四项一致 |
| 交付 | APK **74,217,069 字节**，SHA256 `571C9140D27C33F6C9466FBE056CC4D50D647A293565ABAEFC01F08D5CA881A4`，versionCode 86；四处同哈希；`UPDATE_NOTES.md` 与 `app/assets/update_notes.md` 已加 0.4.65 段；`received/` 投递 APK + 更新说明 + 报告 |
| 未做 | `<queries>` 只能看见声明了对应 intent 的应用；若某阅读器用私有 intent 接收文件仍可能查不到（此时 `startActivity` 的 try/catch 兜底仍能开）；真机验证待用户 |

### M4.72 修好「分享失败」与「打不开」（App 0.4.66+87）

| 项 | 内容 |
| --- | --- |
| 问题 | 用户对一份 PDF 点「分享文件」得到「分享失败：没能拉起系统分享面板」，对 docx 点「用其他应用打开」得到「手机上没有能打开这种文件的应用」；M4.70/M4.71 的判断修正都没能改变结果 |
| 根因 | `FileOpenBridge` 用 androidx 的 `FileProvider.getUriForFile`，但 manifest 注册的 provider 是自写的 `ShareFileProvider`（没有 `FILE_PROVIDER_PATHS` 元数据）→ 解析路径必然抛 `IllegalArgumentException: Failed to resolve canonical path`，被 catch 成 `SHARE_FAILED` / `OPEN_FAILED`；且自写 provider 只认两段路径（`share/x`、`updates/x`），`preview/x`、`share/files/x` 本来就不支持 |
| 改动 | `ShareFileProvider` 支持 `share/x`、`share/files/x`、`preview/x`、`updates/x`，新增 `uriForPreview`/`uriForShare`，`getType` 按扩展名给全 MIME；`FileOpenBridge` 改用这两个方法拼 URI 并删掉 androidx import；`FileOpener.lastError` 记录原生原因，界面提示里显示具体原因（不再是笼统的「没装应用」） |
| 验收 | 文件相关测试 19/19；全量 **554/554**；analyze 34 issues / 0 error；`flutter build apk --release` 成功（中途一次 `kernel_snapshot_program` 失败是 `FakeFileOpener` 未实现新增 getter，已补）；`aapt2 dump badging` → versionCode 87 / `0.4.66-m4.66`；`verify-release.mjs` 四项一致 |
| 交付 | APK **74,217,385 字节**，SHA256 `E6052AE6905E9C9724CFD2A77EEA00E5D7D7E49510951E03B28101785FD31B5E`，versionCode 87；四处同哈希；`UPDATE_NOTES.md` / `app/assets/update_notes.md` 加 0.4.66 段；`received/` 投递 APK + 更新说明 + 报告 |
| 未做 | 分享出去后能否真正打开仍取决于手机是否装了对应阅读器；真机验证待用户 |

### M4.73 「用其他应用打开」可选择（App 0.4.67+88）

| 项 | 内容 |
| --- | --- |
| 问题 | 用户问「用其他应用打开不能选吗」——原来直接 `ACTION_VIEW`，只有没设默认打开方式时才弹列表 |
| 改动 | `FileOpenBridge.handleOpenBytes` 改成 `Intent.createChooser(view, "用其他应用打开")`，每次都列候选应用 |
| 验收 | 版本断言测试通过；`flutter build apk --release` 成功；`aapt2 dump badging` → versionCode 88 / `0.4.67-m4.67`；`verify-release.mjs` 四项一致 |
| 交付 | APK **74,217,829 字节**，SHA256 `EBE3A3BBCF275265ED584DA752E37D823204D9484C7567B2197ADEF3246B212D`；四处同哈希；`UPDATE_NOTES.md` / `app/assets/update_notes.md` 加 0.4.67 段；`received/` 投递 |
