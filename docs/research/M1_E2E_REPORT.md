# M1-α 端到端交付报告：手机 → 公网 → 后端 → 电脑 Agent → Harness

> 日期：2026-10-31 · 范围：**M1-α（垂直切片）** · 结论：**全链路已真实跑通，手机在任意网络（含 4G）可远程操作这台电脑上的 DeepSeek Harness**
> 契约：[`docs/design/M1_PROTOCOL.md`](../design/M1_PROTOCOL.md) · 证据：[`docs/research/evidence/m1/`](evidence/m1/) · 截图：[`docs/mobile/screenshots/`](../mobile/screenshots/)

---

## 0. 一页纸结论

| 问题 | 结论 | 证据 |
|---|---|---|
| 手机能不能连到这台电脑？ | **能**，经 Cloudflare 公网隧道（无需公网 IP、无需买云服务器） | 隧道地址 health 通；手机截图 `09_live_connected.png` |
| 从手机发一句指令，真的会在电脑上执行吗？ | **会**，手机输入 → 云端中继 → Agent → `dsh --profile acp` → 真实 Harness 执行 | 截图 `10_live_output.png`（真实回复 + 工作区路径 `agent\.m1ws`） |
| 高风险命令会先问手机吗？ | **会**，工作区外写入触发沙箱升级，手机弹出审批（原始命令 + 10 分钟倒计时），点「允许一次」后电脑上真的写入了文件 | 截图 `11/12_live_approval.png`、`13_live_result.png`；文件 `C:\Users\user\AppData\Local\Temp\m1-phone-ok.txt` = `phone-ok` |
| 断线/取消呢？ | 取消：真实任务执行中取消 → `cancelled` 且会话可继续；断线：Agent 指数退避重连 | E2E 证据 A6；relay 自测 B6 |
| 现在能当产品用吗？ | **还不能**——这是"链路打通"的垂直切片：无数据库、无账号体系、无 TLS 自有域名、任务/项目页仍是演示数据 | 见 §7 已知限制 |

**一句话**：M1-α 把 M0 验证过的 ACP 通道，接上了后端、公网和手机 UI；"手机远程指挥电脑上的 AI"这件事，现在可以当场演示。

---

## 1. 交付范围（M1-α）

```
手机 App (Flutter) ── HTTPS/WSS ──> Java 后端 (公网可达) <── WSS 出站 ── 电脑 Agent ── stdio JSON-RPC ──> dsh --profile acp
```

- **只做一条最短闭环**：配对 → 建会话 → 发指令 → 实时输出 → 审批 → 取消 → 断线重连。
- 不在本期：PostgreSQL 持久化、账号/多用户、TLS 自有域名、任务中心/项目页真实数据、远程桌面、推送、APK 签名发布。
- 设计决策：Agent **永远出站**（不监听端口、不暴露内网），公网可达性由后端承担——这样家庭 NAT / 无公网 IP 也能用。

---

## 2. 交付物清单

### 2.1 Java 后端（`backend/`，Spring Boot 3.5.16 + Java 21，Gradle 8.14.3）

| 文件 | 作用 |
|---|---|
| `src/main/java/com/deepseek/remote/RemoteApplication.java` | 启动类 |
| `api/PairingController.java` | `GET /api/v1/health`、`POST /api/v1/auth/pair` |
| `auth/TokenStore.java` | 内存令牌（pair 签发、校验、撤销） |
| `protocol/Envelope.java` / `CloseCodes.java` | §3 信封与关闭码（4401/4409） |
| `ws/WsConfig.java` / `RelayWebSocketHandler.java` / `RelaySession.java` / `RelayHub.java` | WSS 端点、单 agent 顶号、多 app 广播、会话表 |
| `application.properties` / `build.gradle` / `settings.gradle` / `README.md` | 配置、构建、启动说明 |

- 构建：`gradle build -x test` → BUILD SUCCESSFUL（1m10s），可执行 jar 约 22MB。
- 后端自身用临时 Node 客户端跑了 **41/41** 协议检查（pair / 401 / WS 往返 / 广播 / 顶号）。
- 地址：本机 `http://127.0.0.1:8080`；公网由 cloudflared 隧道暴露。

### 2.2 电脑端 Agent relay 层（`agent/`，Node 24 直接运行 .ts，零新增依赖）

| 文件 | 作用 |
|---|---|
| `src/relay/protocol.ts`（10.9KB） | 信封 `{v,type,id?,ts?,payload}`、全部上下行 payload、`createEnvelope`/`parseEnvelope` |
| `src/relay/relay-client.ts`（21.8KB） | Node 24 全局 WebSocket；30s 心跳；1s→30s 指数退避+抖动；未连接队列上限 100；4401 自动重新 pair |
| `src/relay/relay-agent.ts`（35.4KB） | 复用 M0 的 `AcpAdapter`（`permissionPolicy='ask'`）：会话映射、工作区越界 `PATH_NOT_ALLOWED`、并发 `SESSION_BUSY`、事件上报（seq 单调）、审批 request/resolved、脱敏 |
| `scripts/serve.ts`（9.3KB） | env 配置 → pair → WSS → `device.status` → 事件循环；SIGINT 优雅退出 |
| `tools/fake-relay-server.ts`（23.5KB） | 零依赖假后端（pair/health/最小 WS 服务端），可独立联调 |
| `tools/relay-selftest.ts`（57.3KB） | A/B/C 三阶段自测，证据写 `agent/evidence/relay-selftest-*.json` |

自测结果：
- `node tools/relay-selftest.ts` → **24/24 PASS**（假 harness/transport：create/越界/busy/completed/cancel/审批 approved/审批超时 expired/failed/redact/seq 单调；真 RelayClient+假后端：pair/401/health/WS 往返/心跳/队列/重连/4401）
- `node tools/relay-selftest.ts --acp-full` → **25/25 PASS**（含真实 ACP：`prompt→output「收到」→completed`；长命令→cancel→cancelled→同会话继续）
- 既有 M0 单测回归：**36/36** pass

### 2.3 手机端真实连接模式（`app/`，Flutter 3.47.9，零新增第三方依赖）

| 文件 | 作用 |
|---|---|
| `lib/services/relay_protocol.dart` | 信封与事件类型 |
| `lib/services/pairing_api.dart` | health 探测 + pair |
| `lib/services/relay_client.dart` | `dart:io` WebSocket、重连、事件流 |
| `lib/data/live_store.dart` | 真实会话状态（消息/任务状态/待审批），与演示 Store 并存 |
| `lib/screens/connect_screen.dart` | 服务器地址 + 配对码、测试连接、连接/断开 |
| `lib/screens/assistant_screen.dart` | 真实模式：发指令、实时输出、审批自动弹层、取消 |
| `lib/app.dart` / `root_shell.dart` / `profile_screen.dart` / 其它 Tab | 注入 LiveScope、模式徽标、真实连接入口 |

- `flutter test` **68/68 全绿**；`flutter build apk --debug` 成功（158MB debug APK）。
- 连接流程（模拟器实测）：AI 助手右上「⇄」→ 填 `https://<隧道地址>` + 配对码 `824613` → 测试连接（显示后端版本/Agent 在线）→ 连接 → 顶部出现「已连接真实电脑」。

### 2.4 联调工具（`tools/`）

| 文件 | 作用 |
|---|---|
| `tools/m1-client.ts` | 独立 E2E 客户端：本机/公网跑 A3–A8，证据写 `docs/research/evidence/m1/` |
| `tools/m1-approval-hold.ts` | 制造真实审批请求并保持挂起（由手机决定），验证手机审批链路 |
| `tools/bin/cloudflared.exe` | Cloudflare 隧道客户端（2026.10.7） |

---

## 3. 验证矩阵

### 3.1 自动化端到端（`tools/m1-client.ts`）

| 用例 | 场景 | 本机 | 公网隧道 |
|---|---|---|---|
| M1-A3 | `device.status` online=true（agent 0.1.0-m1 / harness 0.2.1-rc.5） | ✅ | ✅ |
| M1-A4 | `conversation.create` → `conversation.created` | ✅ | ✅ |
| M1-A5 | 真实 prompt → `output「收到」` → `completed` | ✅ 725ms | ✅ 1246ms |
| M1-A6 | 长命令执行中 `task.cancel` → `cancelled`，会话可继续 | ✅ | ✅ 3229ms |
| M1-A7 | 审批 request → **approved** → 文件生成 → completed | ✅ 5898ms | ✅ 11098ms |
| M1-A8 | 审批 request → **denied** → 文件不生成 → completed（**不是 failed**） | ✅ 4613ms | ✅ 9967ms |

- 本机：4/4（跳过审批）+ **6/6**（含审批）；公网隧道：**6/6**。
- 证据：`evidence/m1/e2e-2026-10-31T05-19-58-698Z.json`（本机 4/4）、`...05-20-37-627Z.json`（本机 6/6）、`...05-21-04-890Z.json`（**公网 6/6**）。

### 3.2 手机端人工验证（AVD timebook_test，1080×2400）

| # | 截图 | 验证内容 |
|---|---|---|
| 09 | `09_live_connected.png` | 手机连上公网后端：「已连接真实电脑」+ 设备名/Agent 版本/Harness 版本 |
| 10 | `10_live_output.png` | 手机发送 `OK` → 真实 Harness 思考 + 回复，回复里正确报出工作区 `<项目根>\agent\.m1ws`，随后「任务已完成」 |
| 11 | `11_live_approval.png` | 由 `m1-approval-hold.ts` 触发的真实审批请求弹层（工作区外写入） |
| 12 | `12_live_approval.png` | 手机自己在对话里请求写工作区外文件 → 真实 `pwsh` 命令 + `高风险 · 6 级权限` + 09:40 倒计时 |
| 13 | `13_live_result.png` | 点「允许一次」后：工具调用变绿、显示实际执行命令与输出、「任务已完成」 |

**端到端因果证据**（不是截图自证）：
- 手机点「允许一次」→ 电脑上 `C:\Users\user\AppData\Local\Temp\m1-phone-ok.txt` 出现，内容 = `phone-ok`。
- 审批证据 JSON：`evidence/m1/approval-phone-2026-10-31T05-26-11-987Z.json`，其中 `resolved.decidedBy = "phone"`、`approval.permissionLevel = 6`、`fileExists = true`、`content = "m1-app-ok"`。

### 3.3 回归（M0 能力不退化）

| 项 | 结果 |
|---|---|
| 单测 36 | ✅ 全绿 |
| 合同测试 9（真实 Harness） | ✅ 全绿（取消/审批/续跑均保持） |
| M0 E2E 5 步 | ✅ 全绿 |

---

## 4. 启动手册（三件套 + 手机）

> 前置：本机已装 DeepSeek Harness（0.2.1-rc.5）并登录；Node 24 / JDK 21 / Gradle 8.14.3 已就绪。

### 4.1 手动三件套（三个窗口）

```powershell
# 0) 一次性：准备工作区权限（Windows 沙箱需要 WRITE_OWNER，否则 shell 工具报 Win32 5）
cd "<项目根>\agent"; npm run acl:check   # 首次报错再 npm run acl:fix

# 1) 后端（窗口 1）
$env:JAVA_HOME='C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1'
cd "<项目根>\backend"
C:\Users\user\dsh-tools\gradle\gradle-8.14.3\bin\gradle.bat bootRun --console=plain

# 2) 公网隧道（窗口 2）→ 记下输出的 https://<公网隧道>.trycloudflare.com
cd "<项目根>"
tools\bin\cloudflared.exe tunnel --url http://127.0.0.1:8080 --no-autoupdate

# 3) 电脑 Agent（窗口 3）→ 连上后端
$env:REMOTE_SERVER_URL='http://127.0.0.1:8080'
$env:M1_PAIRING_CODE='824613'
$env:DEVICE_NAME=$env:COMPUTERNAME
$env:M1_WORKSPACE_ROOT='<项目根>\agent\.m1ws'
cd "<项目根>\agent"; node scripts/serve.ts
```

手机端：装 `DeepSeek Remote AI 手机端 v0.1.0-m1.apk` → AI 助手右上「⇄」→ 填隧道地址 + 配对码 `824613` → 测试连接 → 连接 → 发指令。

> ⚠ Quick Tunnel 地址**每次重启都会变**；要固定地址需自备域名走 B 方案（见构思方案 §7 D-1）。

### 4.2 一键启动 / 关闭（推荐日常使用）

```powershell
$root = "<项目根>"

# 启动全部：后端 + 公网隧道 + Agent（+ 可选 Android 模拟器）
powershell -NoProfile -ExecutionPolicy Bypass -File "$root\tools\m1-up.ps1" -WithEmulator

# 关闭全部
powershell -NoProfile -ExecutionPolicy Bypass -File "$root\tools\m1-down.ps1"
```

- `m1-up.ps1` 依次：检查/拉起后端（最多等 240s）→ 起 Cloudflare 隧道并**从 `--logfile` 解析出公网 URL**（避免 stdout 缓冲读不到）→ 起 Agent（等 `agentOnline=true`）→ 可选起模拟器（等 `sys.boot_completed=1`）→ 把 PID、隧道地址、配对码写进 `.m1-state\state.json`，日志在 `.m1-state\logs\`，最后打印手机该怎么填。
- `m1-down.ps1` 按 `state.json` 的 PID 关闭；兜底清 8080 端口、`cloudflared` 进程与 `adb emu kill`；支持 `-KeepBackend` / `-KeepEmulator`。
- **已验证**（2026-10-31 14:18）：一次启动成功，隧道 `https://<公网隧道>.trycloudflare.com`；随后 `node tools/m1-client.ts --base <该隧道> --skip-approval` **4/4 PASS**；`m1-down.ps1` 后 health 不可达、8080/cloudflared/模拟器均释放。
- 注意：隧道地址每次重启都会变，手机端要重新填；重启前先 `m1-down.ps1`，避免 Agent 重复连接顶号。

---

## 5. 契约实现要点（与 `M1_PROTOCOL.md` 对照）

| 契约点 | 实现 | 备注 |
|---|---|---|
| 信封 `{v,type,id?,ts?,payload}` | 三端一致 | |
| `pair` 两种 role | ✅ | 配对码 `M1_PAIRING_CODE`，默认 `824613` |
| 单 agent、多 app | ✅ RelayHub 新顶旧（4409） | app 多连广播 |
| `conversation.create/prompt.send/task.cancel/approval.decide` | ✅ | |
| `session.update` 的 seq | Agent 侧从 1 单调递增 | 手机端只做顺序渲染，重连靠 `task.state` 兜底 |
| 审批超时 | 10 分钟（与服务端一致） | 超时按拒绝处理（不把用户没点当成系统失败） |
| 错误码 | AUTH_FAILED/BAD_REQUEST/DEVICE_OFFLINE/CONVERSATION_NOT_FOUND/SESSION_BUSY/PATH_NOT_ALLOWED/INTERNAL | |
| 心跳/重连 | 30s ping；1s→30s 退避+抖动；队列 100 丢最旧 | |

---

## 6. 本期新发现

1. **公网链路延迟可接受**：隧道下真实 turn 1.2s 完成（本机 0.7s）；审批类 10–11s（含模型决策与重试），与远端体验预期一致。
2. **审批是唯一的"卡住"风险点**：模型未必每次都走需要审批的工具；E2E 里用"先尝试 → 被沙箱拒绝 → 提示申请提升"的策略，才稳定触发（本机 attempt 2、公网 attempt 2）。→ 产品上必须做 **pre-flight 审批兜底**（远程 Agent 在执行前主动申报高风险动作）。
3. **拒绝≠失败**：denied 后 Harness 以 `end_turn` 正常结束、任务 completed，这一语义在三端保持一致（A8 用例专门验证）。
4. **手机 UI 需要继续打磨**：工具输出目前以原始 JSON 片段展示（`[{"type":"content",...}]`），M1.1 要做结构化渲染（命令/输出/退出码）。
5. **Mock 与真实必须物理隔离**：手机端保留演示 Store，但连接真实后 AI 助手页整体切换 LiveStore；任务/项目页仍是演示数据——下期要统一。

---

## 7. 已知限制（诚实清单）

| # | 限制 | 影响 | 计划 |
|---|---|---|---|
| 1 | **无数据库**：后端全内存，重启即丢会话/令牌 | 不能长期运行 | M1.1 接 PostgreSQL（8 核心表已有 DDL） |
| 2 | **无账号体系**：配对码单一、无用户/设备表 | 只能自用 | M1.1 auth + devices 表 |
| 3 | **隧道是临时地址**：Quick Tunnel 地址随机且重启变 | 每次要重新填 | 迁云或固定隧道（D-1/D-2） |
| 4 | **无自有 TLS 域名**：当前靠 trycloudflare 终结 TLS | 生产要自有域名 | 同上 |
| 5 | **任务/项目/个人页仍是演示数据**（AI 助手页已是真实链路） | 界面不一致 | M1.1 真实任务列表 |
| 6 | **无消息持久化**：手机重开 App 看不到历史 | 体验缺口 | M1.1 后端存 conversations/messages |
| 7 | **无后台保活/推送**：锁屏后审批可能看不到 | 高风险，对应 D-8 | M1.1/M2 前台服务+本地通知 |
| 8 | **debug APK 未签名**（158MB） | 不能上架 | M2 release 构建 + 签名 |
| 9 | **单电脑/单 Agent** | 多设备要改 RelayHub | M2 多设备 |
| 10 | **flutter analyze 在本项目路径崩溃**（中文路径） | 工具链缺口 | 用 test/build 校验；或换纯 ASCII 路径 |
| 11 | **工作区 ACL**：新目录需继承 FullControl | 否则 Win32 5 | `npm run acl:check/fix`；安装器固化 |
| 12 | **headless 模拟器会被运行环境回收**（实测约 20–25 分钟后 `adb` 掉线，日志见 `adb protocol fault`） | 仅影响本机截图演示，不影响后端/Agent/隧道与真实手机 | 需要时重跑 `m1-up.ps1 -WithEmulator`；正式演示用真机或有窗口模拟器 |

---

## 8. 下一步（M1.1 → M2）

**M1.1（1–1.5 周，把"能演示"变"能日用"）**
1. PostgreSQL + Flyway：conversations/messages/tasks/audit（用 `DATA_MODEL.md` DDL）；
2. 后端持久化 + 手机拉历史；重连后恢复会话列表；
3. 手机任务中心接真实任务（`task.state` 驱动），项目页接真实 workspace 列表；
4. 工具输出结构化渲染（命令/输出/退出码/耗时）；
5. 审批：pre-flight 兜底 + 前台服务本地通知（D-8 B 方案）；
6. ~~启动器脚本（一条命令拉起后端+Agent+隧道）~~ ✅ **已完成**：`tools/m1-up.ps1` / `m1-down.ps1`（已实测，见 §4.2）；M1.1 可补状态页/桌面托盘。

**M2**：多设备、账号、远程桌面 L1（H.264 低帧率）、安装包（Agent NSIS + APK 签名）。

---

## 9. 证据索引

| 产物 | 位置 |
|---|---|
| 契约 | `docs/design/M1_PROTOCOL.md` |
| 本机 E2E 4/4 | `docs/research/evidence/m1/e2e-2026-10-31T05-19-58-698Z.json` |
| 本机 E2E 6/6（含审批） | `docs/research/evidence/m1/e2e-2026-10-31T05-20-37-627Z.json` |
| **公网隧道 E2E 6/6** | `docs/research/evidence/m1/e2e-2026-10-31T05-21-04-890Z.json` |
| 手机审批（decidedBy=phone） | `docs/research/evidence/m1/approval-phone-2026-10-31T05-26-11-987Z.json` |
| 手机截图 | `docs/mobile/screenshots/09_live_connected.png` … `13_live_result.png` |
| **一键启动后经新隧道 E2E 4/4** | `docs/research/evidence/m1/e2e-2026-10-31T06-19-34-008Z.json`（隧道 `https://<公网隧道>.trycloudflare.com`） |
| relay 自测 | `agent/evidence/relay-selftest-*.json` |
| M0 报告（前置） | `docs/research/M0_FEASIBILITY.md` |

---

## 10. 复现命令

```powershell
# 0) 一键启动 / 关闭（推荐；会自动打印隧道地址与配对码）
cd "<项目根>"
powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-up.ps1 -WithEmulator
powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-down.ps1

# 1) 端到端（本机后端）
cd "<项目根>"
node tools/m1-client.ts --base http://127.0.0.1:8080 --skip-approval
node tools/m1-client.ts --base http://127.0.0.1:8080

# 2) 端到端（公网隧道）
node tools/m1-client.ts --base https://<你的隧道地址>

# 3) 手机审批联调（保持挂起，等手机点）
node tools/m1-approval-hold.ts --base https://<你的隧道地址> --timeout-ms 180000

# 4) Agent relay 自测（不依赖后端）
cd agent
node tools/relay-selftest.ts
node tools/relay-selftest.ts --acp-full
```

---

## 附：M1.1 增量（2026-11-02）

M1-α 之后已交付 M1.1：PostgreSQL 16.10 持久化（重启不丢历史）、历史会话 REST、手机端历史会话/真实任务中心/任务详情时间线/结构化工具输出、一键脚本自动管理 PostgreSQL。

- 报告：`docs/research/M1_1_REPORT.md`
- 契约：`docs/design/M1_1_DELTA.md`
- 结论：`m1-client` 6/6 ×3（含重启后端后）、`flutter test` 95/95、P-1「重启不丢历史」已实测
- 新增已知限制：token 仍在后端内存（重启后端需重连）、app deviceId 仍 `dev_N`、task events 由消息派生、模拟器环境不稳导致 M1.1 UI 截图未补拍