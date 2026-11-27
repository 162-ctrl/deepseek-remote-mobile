# M1 端到端协议（v1，M1-α 单设备垂直切片）

> **状态**：M1 第一版实现契约（2026-10-31）。作用：让 **手机 App / Java 后端 / 电脑 Agent** 三方可以并行开发，接口冻结在这一版。
> **范围**：单设备、单用户、单后端实例；云端不做持久化（内存态）；不做断线续传与多设备路由。
> **不在本版**：多设备、多用户、JWT/账号体系、消息持久化、远程桌面、文件传输、推送通知。
> **部署形态**：后端跑在本机/NAS 或云服务器，公网访问由 Cloudflare Quick Tunnel 等方式提供 https/wss 域名；手机在任何网络下都能连（这正是本版要验证的）。

---

## 1. 拓扑

```
手机 App ──HTTPS/WSS 公网──> Java 后端(Spring Boot) ──WSS 出站──> 电脑 Agent(Node/TS) ──stdio JSON-RPC──> DSH ACP(`dsh --profile acp`)
```

- Agent **永远出站**（主动连后端），不需要公网 IP / 端口映射 / 路由器配置。
- 后端只需要一个公网可达地址（隧道或云服务器）。
- M1 只支持 **1 个 Agent 连接**；多个 App 连接允许（同一用户多端），消息广播给所有 App。

---

## 2. 认证与配对（M1 简化版）

### 2.1 配对码

后端启动时从环境变量 `M1_PAIRING_CODE` 读取配对码，缺省 `824613`。配对码是本次会话内所有客户端共享的简单口令（M2 换成一次性二维码配对 + 设备证书）。

### 2.2 `POST /api/v1/auth/pair`

请求：

```json
{ "pairingCode": "824613", "clientName": "Pixel 8", "role": "app" }
```

- `role`: `"app"`（手机）或 `"agent"`（电脑端）。
- 返回 200：

```json
{ "token": "9f3c…（64 hex）", "role": "app", "deviceId": "dev_1", "expiresAt": "2026-11-01T12:00:00Z" }
```

- 失败：401 `{"code":"AUTH_FAILED","message":"pairing code invalid"}`。

### 2.3 WSS 连接

`wss://<host>/ws?role=app&token=<token>`（本机 http 调试为 `ws://localhost:8080/ws?role=app&token=…`）。

- 后端在握手阶段校验 token 与 role；失败直接关闭连接（close code 4401）。
- M1 用 query 参数传 token 是为了 Flutter 端零依赖实现；M2 改为连接后首帧 `auth` 消息。

### 2.4 `GET /api/v1/health`

返回 `{"status":"ok","version":"0.1.0-m1","agentOnline":true,"apps":1}`（无需认证）。

---

## 3. 消息信封

所有 WSS 文本帧均为一个 JSON 对象：

```json
{ "v": 1, "type": "prompt.send", "id": "msg_ab12", "ts": "2026-10-31T13:00:00.000Z", "payload": { } }
```

- `v` 固定 1；`type` 见下表；`id` 客户端生成的关联 id（可为空）；`ts` 发送方时间。
- `payload` 随 type 定义。

### 3.1 消息目录

| 方向 | type | 用途 |
|---|---|---|
| App → 后端 | `conversation.create` | 请求 Agent 新建一个会话 |
| App → 后端 | `prompt.send` | 向会话发一条用户消息 |
| App → 后端 | `task.cancel` | 取消当前任务 |
| App → 后端 | `approval.decide` | 审批决定 |
| 后端 → App | `device.status` | Agent 在线状态/版本/能力（连上即推，变化再推） |
| 后端 → App | `agent.online` / `agent.offline` | Agent 连接变化 |
| Agent → 后端 → App | `conversation.created` | 会话已创建（含 Harness sessionId） |
| Agent → 后端 → App | `session.update` | 流式事件（输出/思考/工具调用/用量） |
| Agent → 后端 → App | `task.state` | 任务状态机 |
| Agent → 后端 → App | `approval.request` | 请求用户授权 |
| Agent → 后端 → App | `approval.resolved` | 授权已裁决（含超时） |
| 后端 → App | `error` | 错误回执 |

### 3.2 逐条定义

**`conversation.create`**（App→后端）

```json
{ "workspacePath": "<项目根>\\agent\\.m1ws", "title": "修空指针" }
```

后端分配 `conversationId` 并转发给 Agent（payload 增加 `conversationId`）。`workspacePath` 必须是 Agent 允许的根目录（`M1_WORKSPACE_ROOT`）下的子路径或自身，否则 `error.code=PATH_NOT_ALLOWED`。

**`conversation.created`**（Agent→App）

```json
{ "conversationId": "conv_7f3a91", "sessionId": "da0eb06a-…", "workspacePath": "…", "title": "修空指针" }
```

**`prompt.send`**（App→后端）

```json
{ "conversationId": "conv_7f3a91", "text": "只回复两个字：收到" }
```

后端转发给 Agent；Agent 调 `session/prompt`。若该会话已有 turn 在跑 → 后端回 `error{code:"SESSION_BUSY"}`；若 Agent 不在线 → `error{code:"DEVICE_OFFLINE"}`。

**`session.update`**（Agent→App）

```json
{ "conversationId": "conv_7f3a91", "seq": 12, "kind": "output", "text": "收到" }
```

`kind`：

| kind | 附加字段 | 来源（ACP） |
|---|---|---|
| `output` | `text` | `agent_message_chunk` |
| `thinking` | `text` | `agent_thought_chunk` |
| `tool_call` | `callId`, `tool`, `input` | `tool_call`（`rawInput` 全量） |
| `tool_call_update` | `callId`, `status`, `resultExcerpt` | `tool_call_update` |
| `usage` | `contextUsed`, `contextSize` | `usage_update` |

`seq` 在单个 conversation 内从 1 递增，App 用它排序/去重。

**`task.state`**（Agent→App）

```json
{ "conversationId": "conv_7f3a91", "state": "running" }
```

`state` ∈ `queued | running | completed | failed | cancelled`；`failed` 带 `detail{code,message}`。终态后同一 conversation 仍可继续 `prompt.send`（多轮）。

**`approval.request`**（Agent→App）

```json
{
  "conversationId": "conv_7f3a91",
  "approvalId": "apr_mvvwag94_1",
  "tool": "pwsh",
  "input": { "command": "Set-Content -Path 'C:\\…\\x.txt' …" },
  "workspace": "…",
  "options": [ { "kind": "allow_once", "label": "允许一次" }, { "kind": "reject_once", "label": "拒绝" } ],
  "permissionLevel": 6,
  "riskLevel": "high",
  "expiresAt": "2026-10-31T13:10:00.000Z"
}
```

**`approval.decide`**（App→后端）

```json
{ "conversationId": "conv_7f3a91", "approvalId": "apr_mvvwag94_1", "decision": "approved" }
```

`decision` ∈ `approved | denied`。超时由 Agent 侧判定（默认 10 分钟），Agent 发 `approval.resolved{decision:"expired"}`，并按"拒绝"语义处理：工具不执行、模型解释、turn 以 `end_turn` 结束、任务不算失败（见主方案 §8.3 审批终态权威表）。

**`approval.resolved`**（Agent→App）

```json
{ "conversationId": "conv_7f3a91", "approvalId": "apr_mvvwag94_1", "decision": "approved", "decidedBy": "phone" }
```

`decidedBy` ∈ `phone | timeout | policy`。

**`device.status`**（后端→App）

```json
{
  "online": true,
  "deviceName": "DESKTOP-XXXXXXX",
  "agentVersion": "0.1.0-m1",
  "harnessVersion": "0.2.1-rc.5",
  "capabilities": { "chat": true, "cancel": true, "approvalIntercept": true, "sessionResume": true, "fileRead": false },
  "workspaceRoots": ["<项目根>\\agent\\.m1ws"],
  "lastSeen": "2026-10-31T13:00:00.000Z"
}
```

**`error`**（后端→App）

```json
{ "code": "DEVICE_OFFLINE", "message": "agent is not connected", "conversationId": "conv_7f3a91" }
```

错误码：`AUTH_FAILED | BAD_REQUEST | DEVICE_OFFLINE | CONVERSATION_NOT_FOUND | SESSION_BUSY | PATH_NOT_ALLOWED | INTERNAL`。

---

## 4. 后端实现要求（Java / Spring Boot）

- **技术栈**：Java 21 + Spring Boot 3.5.x（`spring-boot-starter-web` + `spring-boot-starter-websocket`），Jackson，Gradle 8.14.3（`C:\Users\user\dsh-tools\gradle\gradle-8.14.3`，需设 `JAVA_HOME=C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1`）。**不要用 Lombok**（避免注解处理器问题），用 record/普通类。
- **端口**：8080（`server.port` 可配）。
- **目录**：`<项目根>\backend\`（独立 Gradle 项目；包名 `com.deepseek.remote`）。
- **核心类建议**：`RemoteApplication`、`PairingController`（/api/v1/auth/pair、/api/v1/health）、`WsConfig`（注册 handler + 允许跨域来源）、`RelaySession`（一个连接）、`RelayHub`（单例：agent 连接、app 连接集合、conversation 表、广播/路由）、`Envelope`（record）。
- **行为**：
  1. 启动读取 `M1_PAIRING_CODE`（默认 824613）、`M1_AGENT_TOKEN_TTL`（默认 24h）。
  2. `/ws?role=agent&token=` 校验 token 角色；同一时刻只保留 1 个 agent 连接（新连接顶掉旧的），记录 device.status 信息。
  3. `/ws?role=app&token=` 校验；连上立即推送 `device.status`（无 agent 则 `online:false`）。
  4. App 的 `conversation.create / prompt.send / task.cancel / approval.decide` 转发给 agent（附加 `conversationId` 或原样），agent 不在线回 `error DEVICE_OFFLINE`。
  5. Agent 的 `conversation.created / session.update / task.state / approval.request / approval.resolved / device.status` 广播给所有 app 连接，并缓存 device.status。
  6. 全部收发打日志（`log.info`：type、conversationId、字节数），不记录消息正文以外的密钥。
  7. 异常：非法 JSON 回 `error BAD_REQUEST`；未知 type 忽略并记 warn。
- **测试**：`curl -s localhost:8080/api/v1/health`；用 `websocat`/Node 客户端连 `/ws` 验证配对与广播（后端自测可用 Node 临时脚本，不要写进 App/Agent 目录）。
- **构建验收**：`gradle build -x test` 成功；`gradle bootRun` 启动成功后 `/api/v1/health` 返回 JSON。

---

## 5. Agent 端实现要求（`agent/`，Node 24 + TS，node 原生跑 .ts）

复用已有 `AcpAdapter`（`agent/src/harness/acp/acp-adapter.ts`，M0 已完成，合同测试 9/9、E2E 5/5）。

- **新增**：
  - `agent/src/relay/protocol.ts`：信封与消息 TypeScript 类型（与本文档一致）。
  - `agent/src/relay/relay-client.ts`：WSS 客户端。用 Node 24 内置全局 `WebSocket`（无第三方依赖）。职责：连接 `wss://host/ws?role=agent&token=`、心跳（30s 发 `{"v":1,"type":"ping"}`，后端回 `pong`，M1 可只记日志）、断线指数退避重连（1s→2s→…→30s 封顶）、发送队列（未连时缓存最近 100 条）、`onMessage(cb)`。
  - `agent/src/relay/relay-agent.ts`：业务编排。持有 `AcpAdapter`；`conversationId → { sessionId, workspacePath, busy, seq }`；处理 `conversation.create`（建 session）、`prompt.send`（适配器 startTurn；on 事件→`session.update`；settle→`task.state`）、`task.cancel`（adapter.cancelTask）、`approval.decide`（adapter.decideApproval）；订阅 adapter 的 approval_request 事件→发 `approval.request`；转发前做 `redact`（`agent/src/infra/redact.ts`）。
  - `agent/scripts/serve.ts`：CLI 入口。env：`REMOTE_SERVER_URL`（如 `https://<公网隧道>.trycloudflare.com`）、`M1_PAIRING_CODE`、`DEVICE_NAME`、`M1_WORKSPACE_ROOT`（默认 `agent/.m1ws`，自动创建）、`LOG_LEVEL`。流程：pair（POST /api/v1/auth/pair role=agent）→ 连 WSS → 发 `device.status` → 处理消息；优雅退出（SIGINT → adapter.disconnect → ws.close）。
  - `agent/package.json` 增加 `"serve": "node scripts/serve.ts"`。
- **约束**：不改 `src/harness/**`（M0 已验证代码）；若发现必须改，先只加不改接口；路径必须在 `M1_WORKSPACE_ROOT` 内（用 `path.resolve` 校验，越界回 error）。
- **验收**：`node scripts/serve.ts` 能在后端在线时连上；收到 `prompt.send` 后真实 ACP 输出以 `session.update` 回传；`task.cancel` 生效；审批请求与裁决闭环。

---

## 6. App 端实现要求（`app/`，Flutter 3.47.9）

- **零新增第三方依赖**：配对用 `dart:io HttpClient`；WSS 用 `dart:io WebSocket.connect('wss://…/ws?role=app&token=…')`；继续不用 Riverpod。
- **新增**：
  - `lib/services/relay_protocol.dart`：消息模型（`RelayEvent` + 各 payload 解析）。
  - `lib/services/pairing_api.dart`：`pair(baseUrl, pairingCode, clientName)` → `{token, deviceId}`；`health(baseUrl)`。
  - `lib/services/relay_client.dart`：连接、自动重连、事件流（`Stream<RelayEvent>`）、`send(type, payload)`。
  - `lib/data/live_store.dart`：`ChangeNotifier`。字段：`connectionState(idle/connecting/connected/error)`、`serverUrl`、`device`（真实 `DemoDevice` 复用模型）、`messages`（复用 `ChatItem`）、`taskState`、`pendingApproval`、`errorText`。方法：`connect(serverUrl, pairingCode)`、`disconnect()`、`createConversation()`、`sendPrompt(text)`、`cancel()`、`decideApproval(approved)`；把 `session.update` 转成 `ChatItem`（output→assistant text、thinking→thinking、tool_call→toolCall step、task.state→状态提示）；`approval.request`→存 pendingApproval 供 UI 弹 `ApprovalSheet`。
  - `lib/screens/connect_screen.dart`：服务器地址（默认 `https://`，提示可填 Cloudflare 隧道地址）、配对码（默认 824613）、连接/断开按钮、状态与错误显示、`health` 探测结果、成功后返回。
  - AppBar 或"我的"页增加入口进入连接页；连接成功后 AI 助手页顶部显示 `已连接真实电脑` 徽标（替代演示徽标），发送消息走 `liveStore`；审批弹层复用 `ApprovalSheet`；取消按钮调 `liveStore.cancel()`。
  - 未连接时保持现有演示数据行为（默认），并在页面说明"演示模式"。
- **兼容约束**：现有 3 个 widget 测试必须继续通过（可改测试以匹配新模式，但需覆盖"演示模式"与"连接页"）；不要动 `lib/data/demo_store.dart` 的公开行为；其它 Tab 可继续演示数据，但页面需显示模式徽标。
- **验收**：`flutter test` 3/3+ 通过；`flutter build apk --debug` 成功；用真实后端地址连接后能发消息、看到流式输出、收到审批并裁决、取消任务生效。

---

## 7. 验收清单（M1-α）

| # | 验收项 | 判定 |
|---|---|---|
| M1-A1 | 后端 `/api/v1/health` 返回 ok | curl |
| M1-A2 | 配对（app/agent 两种 role）返回 token | curl |
| M1-A3 | App 连上即收到 `device.status`（online=true, harnessVersion=0.2.1-rc.5） | E2E 客户端 |
| M1-A4 | `conversation.create` → `conversation.created` | E2E |
| M1-A5 | 真实 prompt → `session.update(output)` 含"收到" → `task.state completed` | E2E |
| M1-A6 | 长命令中 `task.cancel` → `task.state cancelled`，同会话可继续 | E2E |
| M1-A7 | 工作区外写入触发 `approval.request` → approve → 文件生成 → completed | E2E |
| M1-A8 | 拒绝审批 → 工具不执行 → completed（非 failed） | E2E |
| M1-B1 | **公网**：cloudflared 隧道地址下全部 A3–A7 通过（模拟 4G 场景） | E2E over https |
| M1-C1 | App 真机/模拟器连接真实后端，发消息看到真实输出与审批 | 截图 |
| M1-C2 | 断开后端 → App 显示断线并可重连 | 截图/录像 |

证据统一写 `docs/research/evidence/m1/`（JSON/日志）与 `docs/mobile/screenshots/`（截图）。

---

## 8. 时间与分工（并行）

- **后端**（独立）：按 §4 实现，产出 `backend/`，自测 health/pair/WS 往返。
- **Agent**（独立）：按 §5 实现，用本地 ws 后端自测（可用假后端脚本 `tools/m1-fake-server.ts` 或直接等后端就绪）。
- **App**（独立）：按 §6 实现 UI 与客户端，用 `tools/m1-mock-server.ts`（可选）或后端就绪后联调。
- **集成**：Lead 写 E2E 客户端 `tools/m1-client.ts`（模拟 App），负责本机链路、cloudflared 公网链路、最终联调与报告 `docs/research/M1_E2E_REPORT.md`。

> 本文件是 M1-α 唯一契约来源；三方实现如与本文档冲突，以本文档为准并同步回来。
