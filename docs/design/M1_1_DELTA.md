# M1.1 增量契约：持久化 + 历史 + 真实任务列表

> 状态：M1.1 实现基线（2026-11-02）
> 前置：`M1_PROTOCOL.md`（M1-α 契约）不变；本文件只**增加**内容，不修改已有消息/端点语义。
> 目标：把 M1-α 的"内存态、刷新即丢"升级为"重启后历史仍在、任务/项目页是真实数据"。

## 1. 范围

| 做 | 不做（留给 M2） |
|---|---|
| PostgreSQL 持久化：用户/设备/会话/消息/任务/审计 | 账号注册登录、多用户 |
| 历史查询 REST：重连后手机能拉回会话与消息 | 消息全文搜索、分页游标优化 |
| 任务列表/任务详情真实数据（含时间线） | 多设备、远程桌面、推送 |
| 工具输出结构化渲染 | 文件传输 |

## 2. 数据库

- 便携版 PostgreSQL 16.10，数据目录 `C:\Users\user\dsh-tools\pgdata-deepseek`，监听 `127.0.0.1:5433`，用户 `postgres`（trust 本地认证），库 `deepseek_remote` / `deepseek_remote_test`。
- 连接串（后端默认，可由 env 覆盖）：`jdbc:postgresql://127.0.0.1:5433/deepseek_remote`，用户 `postgres`，密码空。
- Spring Flyway 迁移目录 `backend/src/main/resources/db/migration`：
  - `V1__core.sql`：`users`、`devices`、`conversations`、`messages`、`tasks`、`audit_logs`（字段遵循 `DATA_MODEL.md` 的核心表，可精简掉 M2 才用的列，但**不要改名**）。
  - `V2__seed.sql`：插入本机自用用户 `u_self`（26 字符 ID，`nickname='自用'`）。
- 单用户模式：`pair` 成功时把 agent 报名信息 upsert 进 `devices`（`device_id` 由后端生成 26 位 ID 并稳定复用），`user_id` 固定为种子用户。
- ID：统一 26 位大写 Crockford Base32（`ULID` 风格：时间戳 10 位 + 随机 16 位）。手机/Agent 侧不生成业务 ID。

## 3. REST 增量（Bearer token，与 M1 `pair` 拿到的 token 相同）

所有路径前缀 `/api/v1`，响应 JSON；出错沿用 `{error:{code,message}}`。

### 3.1 会话列表

`GET /api/v1/conversations?limit=50`

```json
{ "conversations": [
  { "conversationId":"01J...", "title":"修登录页空指针", "workspacePath":"D:\\...\\agent\\.m1ws",
    "sessionId":"94ac768c-...", "lastMessageAt":"2026-11-02T05:12:31Z", "messageCount":12,
    "createdAt":"2026-11-02T05:10:00Z" }
] }
```

### 3.2 会话消息（历史）

`GET /api/v1/conversations/{conversationId}/messages?afterSeq=0&limit=200`

```json
{ "conversationId":"01J...", "messages":[
  { "messageId":"01J...", "seq":1, "role":"user", "kind":"text", "text":"修一下空指针",
    "toolName":null, "metadata":{}, "createdAt":"2026-11-02T05:10:05Z" },
  { "messageId":"01J...", "seq":2, "role":"tool", "kind":"tool_call",
    "text":"{\"tool\":\"pwsh\",\"input\":\"rg -n ...\"}", "toolName":"pwsh",
    "metadata":{"status":"completed","durationMs":420}, "createdAt":"..." },
  { "messageId":"01J...", "seq":3, "role":"assistant", "kind":"text",
    "text":"已修复……", "toolName":null, "metadata":{}, "createdAt":"..." }
] }
```

- `kind` 取值：`text` | `thinking` | `tool_call` | `tool_result` | `system`（与 `messages.content_type` 映射）。
- 历史按 `seq` 升序；`afterSeq` 用于增量补拉。

### 3.3 任务列表 / 详情

`GET /api/v1/tasks?limit=50&status=running,waiting_approval`

```json
{ "tasks":[
  { "taskId":"01J...", "conversationId":"01J...", "taskName":"修登录页空指针",
    "status":"completed", "progress":100, "workspacePath":"D:\\...",
    "result":{"summary":"已修复 1 处空指针，12 个测试通过"},
    "errorCode":null, "errorMessage":null,
    "createdAt":"...", "startedAt":"...", "finishedAt":"..." } ] }
```

`GET /api/v1/tasks/{taskId}` 在上面的字段外增加 `events`：

```json
{ "events":[
  { "seq":1, "at":"...", "type":"tool_call", "title":"搜索代码", "tool":"pwsh",
    "detail":"rg -n \"NullPointerException\" app/lib" },
  { "seq":2, "at":"...", "type":"completed", "title":"任务完成", "tool":null, "detail":"12 个测试通过" } ] }
```

## 4. 事件与持久化规则（后端）

后端在转发的同时落库，**转发逻辑不变**（不阻塞、失败只记日志）：

| 时机 | 落库 |
|---|---|
| `pair` role=agent 成功 | `devices` upsert（name/os/agent_version/harness_version/last_seen_at） |
| App `conversation.create` → Agent 回 `conversation.created` | 插 `conversations` 行（title 默认取 workspace 目录名） |
| App `prompt.send` | 插 `messages`(role=user, seq=increment) + 插 `tasks`(status=queued, task_name=prompt 前 40 字) |
| Agent `task.state`(running/waiting_approval/completed/failed/cancelled) | 更新 `tasks.task_status/progress/started_at/finished_at/result/error_*`；`completed` 时把该任务期间聚合的 assistant 文本写成一条 `messages`(role=assistant) |
| Agent `session.update` kind=output | 追加到"当前任务输出聚合器"（内存），任务完成时一次性写库（上限 8000 字） |
| Agent `session.update` kind=tool_call | 插 `messages`(role=tool, content_type=tool_call, content=`{"tool":..,"input":..}`) |
| Agent `session.update` kind=tool_call_update | 更新对应 tool 消息的 `metadata.status/durationMs`；若为 `failed/completed` 且带输出，再插一条 `role=tool, content_type=tool_result` |
| `approval.decide` | 插 `audit_logs`(action='approval.decision', detail=approvalId+decision) |
| Agent `session.update` kind=thinking | **不落库**（避免膨胀），M2 再议 |

聚合器按 `conversationId` 维护；任务中断（失败/取消）也要把已聚合内容写库（`metadata.partial=true`）。

## 5. 手机端（M1.1）

- 连接成功后：`GET /conversations` 填充会话侧栏/最近对话；当前会话用 `GET /messages` 回填聊天记录，再接收实时事件。
- 任务中心：`GET /tasks` 为数据源（替换 `DemoStore.tasks`）；任务详情用 `GET /tasks/{id}` 的 `events` 画时间线。
- 工具输出结构化：tool_call/tool_result 分开渲染（命令块 + 状态 + 耗时 + 输出折叠），不再显示原始 JSON 片段。
- 断网重连：重连后拉 `messages?afterSeq=lastSeq` 补齐。
- 演示模式保留（未连接时仍可看），真实模式 badge 不变。

## 6. 启动与配置

- 后端 `application.properties` 增加：
  ```
  spring.datasource.url=${M1_DB_URL:jdbc:postgresql://127.0.0.1:5433/deepseek_remote}
  spring.datasource.username=${M1_DB_USER:postgres}
  spring.datasource.password=${M1_DB_PASSWORD:}
  spring.flyway.enabled=true
  ```
- `tools/m1-up.ps1` 增加一步：5433 未监听则用便携版 PG 拉起（`Start-Process postgres.exe -D ... -p 5433`），并等待可连接。
- `tools/m1-down.ps1` 默认**不关** PostgreSQL（`-StopDb` 才关），避免每次重启冷启动。

## 7. 验收（M1.1）

| 编号 | 场景 | 判定 |
|---|---|---|
| P-1 | 起后端 → 跑一次真实任务 → 停后端 → 再起 → 手机（或 `m1-client`）拉历史 | 会话与消息仍在，内容一致 |
| P-2 | 手机任务中心 | 显示真实任务，状态/时间/工作区正确 |
| P-3 | 任务详情时间线 | 由 `tasks/{id}.events` 渲染，含工具调用与完成 |
| P-4 | 审批决策 | `audit_logs` 有记录（SQL 可查） |
| P-5 | 回归 | M1-α 契约 6/6 仍通过（本机与隧道） |
