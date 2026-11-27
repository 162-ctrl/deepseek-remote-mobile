# M1 中继后端（Java 21 + Spring Boot 3.5.x）

M1-α 链路中的 Java 中继服务：手机 App（Flutter）经 HTTPS/WSS 连到这里，再经 WSS 出站连到电脑 Agent（Node/TS）。
协议唯一契约见仓库内 `docs/design/M1_PROTOCOL.md`（§2 认证 / §3 消息 / §4 后端要求）；
增量契约见 `docs/design/M1_1_DELTA.md`（历史持久化 / REST）、`docs/design/M2_DELTA.md`（token 持久化）、
`docs/design/M2_1_DELTA.md`（task_events 事件表 / 会话级统一 seq / 断线补偿）与
`docs/design/M2_5_UPDATE_DELTA.md`（应用内在线更新：版本接口 + APK 流式下载）。

## 技术栈

- Java 21（`C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1`）
- Spring Boot 3.5.16（`spring-boot-starter-web` + `spring-boot-starter-websocket` + `spring-boot-starter-jdbc`），Jackson
- PostgreSQL 16（`org.postgresql:postgresql`）+ Flyway（`flyway-core` + `flyway-database-postgresql`）做 M1.1/M2.0 持久化
- Gradle 8.14.3（`C:\Users\user\dsh-tools\gradle\gradle-8.14.3`）；Boot 插件与依赖均从 Maven Central 解析
- 无 Lombok；中继状态（连接/会话 busy/device.status 缓存）在内存中，历史（conversations/messages/tasks/audit_logs）、
   事件日志（`task_events`）与配对 token（`auth_tokens`，只存 sha256 哈希）落 PostgreSQL；落库失败只记 `WARN`，绝不影响消息转发，
   也绝不阻塞转发线程（单线程 `m1-persist` 执行器 FIFO 串行写库；token 的 `last_seen_at` 异步刷新失败直接忽略）。
- token 已持久化：**后端重启后 App/Agent 旧 token 仍有效**，无需重新配对（M2 验收 M2-A4）；历史数据重启后仍在（M1.1 P-1）。

M1.1 契约见 `docs/design/M1_1_DELTA.md`，M2.0 见 `docs/design/M2_DELTA.md`，表结构见 `docs/design/DATA_MODEL.md`。

## 构建 / 运行

```powershell
$env:JAVA_HOME='C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1'
$gradle='C:\Users\user\dsh-tools\gradle\gradle-8.14.3\bin\gradle.bat'
Set-Location '<项目根>\backend'

& $gradle build -x test          # 构建（产物：build/libs/backend-0.1.1-m2.jar）
& $gradle bootRun                # 前台启动，监听 8080
```

后台启动（联调用）：

```powershell
Start-Process -FilePath 'cmd.exe' -WorkingDirectory '<项目根>\backend' `
  -ArgumentList '/c', 'set "JAVA_HOME=C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1" && "C:\Users\user\dsh-tools\gradle\gradle-8.14.3\bin\gradle.bat" bootRun --console=plain' `
  -WindowStyle Hidden
```

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `M1_PAIRING_CODE` | `824613` | App/Agent 共享配对码（协议 §2.1） |
| `M1_TOKEN_TTL_DAYS` | `30` | 持久化 token 有效期（天）；重启不失效，到期/`revoked_at` 后鉴权失败 |
| `M1_TOKEN_CACHE_TTL_SECONDS` | `1` | 进程内 token 缓存时间（秒）；极短以保证 `revoked_at` 及时生效，`0` 表示每次查库 |
| `SERVER_PORT` | `8080` | 监听端口 |
| `M1_DB_URL` | `jdbc:postgresql://127.0.0.1:5433/deepseek_remote` | M1.1 PostgreSQL 连接串 |
| `M1_DB_USER` / `M1_DB_PASSWORD` | `postgres` / 空 | 数据库账号（便携 PG 本地 trust，无密码） |
| `M1_DB_MIGRATE` | `true` | 是否在启动时执行 Flyway 迁移 |
| `M1_DB_PERSIST` | `true` | 是否写历史（`false` 时退化为纯内存 M1-α 中继） |
| `M1_EVENTS_DEFAULT_LIMIT` | `200` | `GET /conversations/{id}/events` 的默认 limit |
| `M1_EVENTS_MAX_LIMIT` | `500` | 同上，limit 上限（超出返回 400） |
| `APP_UPDATE_ENABLED` | `true` | M2.5 在线更新开关；`false` 时两个 `/app/*` 接口返回 404 `APP_UPDATE_UNAVAILABLE` |
| `APP_UPDATE_APK_PATH` | `../dist/DeepSeek-Remote-latest.apk` | APK 文件路径（相对 backend 工作目录；可绝对路径） |
| `APP_UPDATE_VERSION_CODE` | `7` | 版本号（整数，App 比较用） |
| `APP_UPDATE_VERSION_NAME` | `0.1.6-m2.5` | 版本名（展示用） |
| `APP_UPDATE_NOTES` | `修复演示数据、界面减法后的在线更新版本` | 更新说明（App 端展示） |

### PostgreSQL / Flyway（M1.1 / M2.0 / M2.1）

- 库：`deepseek_remote`（测试库 `deepseek_remote_test`），启动时自动执行 `src/main/resources/db/migration`：
  - `V1__core.sql`：`set_updated_at()` 函数 + `users` / `devices` / `conversations` / `messages` / `tasks` / `audit_logs`
    （字段/约束/索引照 `docs/design/DATA_MODEL.md` 核心表；仅追加列：`users.nickname`、`conversations.workspace_path`）。
  - `V2__seed.sql`：单用户种子 `u_self`（固定 26 位 Crockford Base32 ID，`nickname='自用'`）。
  - `V3__auth_tokens.sql`：`auth_tokens`（M2_DELTA §1.1；`token_hash char(64) UNIQUE` 只存 **sha256**、`role`、`device_id`、
    `client_name`、`issued_at`、`expires_at`、`revoked_at`、`last_seen_at`；索引 `(device_id, role)`、`(expires_at)`）。
  - `V4__task_events.sql`：`task_events`（M2.1_DELTA §2；`UNIQUE(conversation_id, seq)`、`type`、`kind`、`payload jsonb`、
    `task_id` 可空；索引 `(conversation_id, seq)`、`(task_id)`）；给 `conversations` 追加 `next_seq bigint` 并初始化为
    该会话 `max(messages.seq_in_conversation)`；把存量 `messages` 全量回填为 `type='backfill'` 事件（新端点不返回）。
- 业务 ID 统一 26 位大写 Crockford Base32（ULID 风格：10 位毫秒时间戳 + 16 位随机），由后端生成；
  `conversationId` 即 `conversations.id`，deviceId 即 `devices.id`（单用户模式按 device_name 复用，重连不换 ID）。
- 落库规则（DELTA §4，全部在 `PersistenceService` 中异步执行，异常只 `WARN`）：
  - `pair(role=agent)` → `devices` upsert；`device.status` → 更新 agent/harness 版本、最后在线时间；
  - `conversation.created` → `conversations`；`prompt.send` → `messages(role=user)` + `tasks(queued)`；
  - `task.state` → 更新 `tasks`（状态/进度/started_at/finished_at/result/error_*），终态时把聚合的 assistant 文本写成一条 `messages(role=assistant)`；
  - `session.update(kind=output)` → 内存聚合（上限 8000 字）；`tool_call` / `tool_call_update` → `messages(content_type=tool_call/tool_result)`；
  - `thinking` / `usage` 不写 `messages`，但作为事件写入 `task_events`（M2.1）；失败/取消也写已聚合内容并标 `metadata.partial=true`；
  - `approval.decide` → `audit_logs(action_type='approval.decision')`。

### 事件日志与统一 seq（M2.1 DELTA §2）

- 每个会话一个递增 `seq`，**后端是中继路径上唯一的分配者**：`RelayHub` 在转发每条 App 可见事件前同步调用
  `PersistenceService.allocateSeq`（`UPDATE conversations SET next_seq = GREATEST(next_seq, ?) + 1 ... RETURNING next_seq`），
  再 `withSeq` 把同一个 seq 写进转发信封的 `payload.seq` 与根 `seq`，随后异步落 `task_events`。
  因此断线重连后用 `/events?afterSeq=` 补拉时，事件 seq 与实时流严格一致（客户端按 seq 去重）。
- 写入 `task_events` 的事件：`conversation.created`、`prompt.send`、`session.update`（kind=output/thinking/tool_call/tool_call_update/usage）、
  `task.state`、`approval.request`、`approval.resolved`；`device.status`/`error` 不入事件表。
- 同一 seq 同时是消息 seq：`prompt.send` 的 user 消息、`tool_call`/`tool_result` 消息、终态 assistant 消息都复用对应事件的 seq
  （`messages.seq_in_conversation` 与 `task_events.seq` 同一空间），故 `SELECT ... FROM messages m LEFT JOIN task_events te
  ON te.conversation_id=m.conversation_id AND te.seq=m.seq_in_conversation` 可整体对齐。
- 不变式（实测断言）：每会话 `max(seq)-min(seq)+1 = count(*)` 且 `min(seq)=1`（无空洞，事件被广播前先分配）；`conversations.next_seq`
  等于该会话 `max(task_events.seq)`；`thinking` 有事件但无 `messages` 行。
- 存量回填按消息时间窗把 `task_id` 归属到任务；早于任务创建的用户消息可能归不到任务，因此**少量历史任务 events 为空**，
  新任务（M2.1 之后）每条都有 `prompt.send` 事件归属，完整可查。

## HTTP API（协议 §2）

- `GET /api/v1/health` → `{"status":"ok","version":"0.1.1-m2","agentOnline":bool,"apps":int}`（无需认证）
- `POST /api/v1/auth/pair`
  - 请求：`{"pairingCode":"824613","clientName":"Pixel 8","role":"app"}`，`role ∈ app|agent`
  - 200：`{"token":"<64 hex>","role":"app","deviceId":"dev_1","expiresAt":"2026-12-02T06:32:17Z"}`；token 的 sha256 持久化到 `auth_tokens`，默认 30 天有效
  - `role=agent` 时 `deviceId` 为 26 位 ULID（`devices.id`，重连稳定复用）；`role=app` 仍为 `dev_N`（App 不建 device 行）
  - 失败：401 `{"code":"AUTH_FAILED","message":"..."}`（配对码错误 / role 非法）；请求体非法 JSON 返回 400 `BAD_REQUEST`

## 历史 / 任务 REST（M1.1 DELTA §3）

全部需要 `Authorization: Bearer <pair 返回的 token>`；错误统一 `{"error":{"code":"...","message":"..."}}`（401 AUTH_FAILED / 404 / 400 / 500 INTERNAL）。

- `GET /api/v1/conversations?limit=50` → `{"conversations":[{conversationId,title,workspacePath,sessionId,lastMessageAt,messageCount,createdAt}]}`（最近活跃在前）
- `GET /api/v1/conversations/{conversationId}/messages?afterSeq=0&limit=200` → `{"conversationId","messages":[{messageId,seq,role,kind,text,toolName,metadata,createdAt}]}`
  - `kind` 与 `messages.content_type` 对应：`text|markdown|code|image|file|audio|json|tool_call|tool_result`；按 `seq` 升序；`afterSeq` 用于增量拉取
- `GET /api/v1/conversations/{conversationId}/events?afterSeq=0&limit=200`（M2.1）→
  `{"events":[{seq,type,kind,payload,createdAt}],"nextSeq":N}`
  - 按 `seq` 升序返回已提交事件；`afterSeq` 缺省 0；`limit` 缺省 200、上限 500（越界/负数 → 400 BAD_REQUEST）；
    `type='backfill'` 的历史回填行不返回；会话不存在 → 404 CONVERSATION_NOT_FOUND
  - 客户端断线重连时以最后收到的 `seq` 为 `afterSeq` 循环拉取，直到 `events` 不足一页或 `seq` 追上实时流
- `GET /api/v1/tasks?limit=50&status=running,waiting_approval` → `{"tasks":[{taskId,conversationId,taskName,status,progress,workspacePath,result:{summary},errorCode,errorMessage,createdAt,startedAt,finishedAt}]}`
- `GET /api/v1/tasks/{taskId}` → 上述字段 + `events:[{seq,type,title,tool,detail,createdAt,at}]`
  - events 直接读 `task_events`（M2.1，`WHERE task_id=? ORDER BY seq ASC LIMIT 500`），由 `kind`/`payload` 映射中文 `title`/`detail`；
    含「用户指令（prompt.send）」「思考」「上下文用量」「工具调用（tool title=tool 名）」「工具结果」「审批请求」「审批结果」「输出」「任务完成/失败/已取消」

## M2.5 在线更新接口（M2.5 DELTA §2 B1–B3）

两个接口**均无需 Bearer**：App 在 token 失效或未配对时也必须能检查更新、下载 APK（APK 本身非机密）。

- `GET /api/v1/app/version` →
  `{"versionCode":7,"versionName":"0.1.6-m2.5","size":1572864,"sha256":"<64 位小写 hex>","notes":"...","url":"/api/v1/app/apk","publishedAt":"2026-11-03T17:35:27+08:00"}`
  - `sha256` 按文件 `mtime+size` 进程内缓存，替换 APK 后自动重算；`publishedAt` 取 APK 文件 mtime（系统时区，形如 `+08:00`）
  - 文件缺失或 `APP_UPDATE_ENABLED=false` → 404 `{"code":"APP_UPDATE_UNAVAILABLE","message":"..."}`（平铺错误信封，与 pair 一致）
  - 每次检查打一行 `app update check versionCode=… size=…`
- `GET /api/v1/app/apk`（支持 `HEAD`）→ `FileSystemResource` 流式输出（不整文件读入内存）：
  `Content-Type: application/vnd.android.package-archive`、正确 `Content-Length`、
  `Content-Disposition: attachment; filename="DeepSeek-Remote-latest.apk"`；文件缺失 404 同上。
  `HEAD` 返回同样的头（含 `Content-Length`），便于 App 先探测大小再决定是否下载。

```powershell
# 用 8081 起临时实例验证（8080 是联调服务，不要动）
$env:SERVER_PORT='8081'
& $gradle bootRun

curl.exe -s http://127.0.0.1:8081/api/v1/app/version
curl.exe -s -I http://127.0.0.1:8081/api/v1/app/apk
curl.exe -s -o downloaded.apk http://127.0.0.1:8081/api/v1/app/apk
Get-FileHash downloaded.apk -Algorithm SHA256   # 应与 version.sha256 完全一致
```

APK 放置：默认 `../dist/DeepSeek-Remote-latest.apk`（相对 backend 工作目录）；真实 APK 由发布流程覆盖，
先用任意 >1MB 占位文件即可联调。

## WebSocket（协议 §2.3 / §4）

- 连接：`ws://<host>:8080/ws?role=app|agent&token=<token>`
- 握手阶段校验 token 与 role：先查进程内缓存、未命中查 `auth_tokens`
  （`sha256(token)` 且 `revoked_at IS NULL AND expires_at > now()`），通过后异步刷新 `last_seen_at`；失败 close code **4401**。
  与 REST Bearer 走同一 `TokenStore.validate` 路径，401 语义不变（不区分不存在/过期/撤销）。
- 单 Agent：新 agent 连接会关闭旧连接（close code **4409**）。
- 多 App：所有 app 连接都收到 agent 上行消息广播；新 app 连上立即收到 `device.status`。
- 心跳：收到 `{"v":1,"type":"ping"}` 回 `{"v":1,"type":"pong","ts":"..."}`。

### 转发规则

| 方向 | type | 后端行为 |
|---|---|---|
| app → agent | `conversation.create` | 分配 26 位 ULID `conversationId`，写入 `payload.conversationId` 后转发；登记会话 |
| app → agent | `prompt.send` | 校验会话存在（否则 `CONVERSATION_NOT_FOUND`）、agent 在线（`DEVICE_OFFLINE`）、无进行中 turn（`SESSION_BUSY`）；先分配会话级 `seq` 写入信封，再原样转发；成功后落 `messages(user)`(seq) + `tasks(queued)` + `task_events(prompt.send)` |
| app → agent | `task.cancel` / `approval.decide` | agent 在线则原样转发；`approval.decide` 成功后写 `audit_logs` |
| agent → app | `conversation.created` / `session.update` / `approval.request` / `approval.resolved` | 先分配会话级 `seq`（写入信封 `payload.seq`、根 `seq`）并落 `task_events`，再广播所有 app（无 app 时也落库，供重连补拉） |
| agent → app | `task.state` | 同上分配 seq + 落 `task_events` 后广播；并按 state 维护会话 busy（`queued/running` → busy，终态 → idle） |
| agent → app | `device.status` | 缓存快照 + 广播（不入事件表、不分配 seq） |
| agent → app | `error` | 广播（用于 Agent 侧 `PATH_NOT_ALLOWED` 等错误回执；不分配 seq） |
| 后端 → app | `device.status` / `agent.online` / `agent.offline` / `error` | agent 连接/断开时推送状态变化；非法 JSON 回 `BAD_REQUEST` |

错误码：`AUTH_FAILED | BAD_REQUEST | DEVICE_OFFLINE | CONVERSATION_NOT_FOUND | SESSION_BUSY | PATH_NOT_ALLOWED | INTERNAL`。
未知消息 type 记 warn 并忽略（不关闭连接）。

## 日志

每个进出消息记录 `role/type/conversationId/bytes`（`log.info`），token 与消息正文不落日志。

## 目录

```
backend/
├── build.gradle / settings.gradle / gradle.properties
└── src/main/
    ├── java/com/deepseek/remote/
    │   ├── RemoteApplication.java
    │   ├── api/PairingController.java      # /api/v1/health、/api/v1/auth/pair
    │   ├── api/HistoryController.java      # M1.1/M2.1 历史/任务/事件 REST（Bearer 鉴权）
    │   ├── api/AppUpdateController.java    # M2.5 /api/v1/app/version、/api/v1/app/apk（无鉴权、APK 流式下载）
    │   ├── auth/TokenStore.java            # token 库优先+短缓存；auth_tokens 只存 sha256，重启不失效
    │   ├── persistence/Ulid.java           # 26 位 Crockford Base32 ID
    │   ├── persistence/PersistenceService.java  # 异步落库（task_events/seq 分配；失败只 WARN）
    │   ├── protocol/Envelope.java          # 信封构造
    │   ├── protocol/CloseCodes.java        # 4401 / 4409
    │   └── ws/
    │       ├── WsConfig.java               # 注册 /ws、帧大小
    │       ├── RelayWebSocketHandler.java  # 鉴权、解析、ping/pong
    │       ├── RelaySession.java           # 单个连接
    │       └── RelayHub.java               # 单 agent/多 app/会话表/seq 分配/广播/device.status 缓存
    └── resources/
        ├── application.properties
        └── db/migration/V1__core.sql、V2__seed.sql、V3__auth_tokens.sql、V4__task_events.sql
```

## 自测

M1-α 端到端（需先起 backend 与 agent）：`node tools/m1-client.ts --base http://127.0.0.1:8080`，预期 6/6 PASS（`--skip-approval` 只跑 4 项）。
M1.1 验收（`docs/design/M1_1_DELTA.md` §7）：重启 backend 后 `GET /api/v1/conversations` 历史仍在（P-1）、任务详情含 `events`（P-3）、
`select action_type, action_result, action_detail from audit_logs;` 可查审批（P-4）、m1-client 6/6（P-5）。
M2-A4 验收（`docs/design/M2_DELTA.md` §3）：pair 拿 app token → 重启 backend → 用**重启前**的 token 调 `GET /api/v1/conversations`
应返回 200（不重新 pair），且 Agent 不重启自动恢复 `agentOnline=true`。抽查：
`select role, count(*), count(last_seen_at), bool_and(token_hash ~ '^[0-9a-f]{64}$') from auth_tokens group by role;`（确认只存哈希）。
M2.1-A3 断线补偿验收（`docs/design/M2_1_DELTA.md` §5）：起 backend + agent 后
`node tools/m2-catchup-test.ts --base http://127.0.0.1:8080 --drop-ms 60000`，预期打印 `M2.1 CATCHUP PASS`
（断流前记录最后 seq，断流 60s 期间的事件在重连后经 `/events` 补拉，seq 连续且唯一、终态可取），证据写
`docs/research/evidence/m2/catchup-<stamp>.json`。命令后的不变式 psql 断言：

```sql
-- 每会话 seq 无空洞，且从 1 开始
select conversation_id, count(*), max(seq)-min(seq)+1 from task_events group by conversation_id
  having count(*) <> max(seq)-min(seq)+1 or min(seq) <> 1;   -- 应 0 行
-- messages 与 task_events 的 seq 空间对齐（每条消息都有同 seq 事件）
select count(*) from messages m where not exists (
  select 1 from task_events te where te.conversation_id = m.conversation_id
    and te.seq = m.seq_in_conversation);                     -- 应 0
-- thinking 只落事件不落消息
select count(*) from messages where content_type='thinking';  -- 应 0
```

M2.5 在线更新验收（`docs/design/M2_5_UPDATE_DELTA.md` §5）：`SERVER_PORT=8081` 起临时实例（勿动 8080 联调服务），
`curl.exe -s http://127.0.0.1:8081/api/v1/app/version` 返回 versionCode/size/sha256/notes/url/publishedAt；
`curl.exe -s -I http://127.0.0.1:8081/api/v1/app/apk` 返回 200 + `Content-Type: application/vnd.android.package-archive` + 正确 `Content-Length`；
`curl.exe -s -o downloaded.apk ...` 下载后 `Get-FileHash downloaded.apk -Algorithm SHA256` 应与 `version.sha256` 一致；
临时重命名/删除 APK 后两个接口均返回 404 `APP_UPDATE_UNAVAILABLE`；验证结束停掉 8081 临时实例。

后端自测脚本放在仓库外临时目录（例如 `%TEMP%\m1ws\e2e.mjs`，Node 24 内置 `fetch` + `WebSocket`，无依赖），
覆盖：health、配对成功/失败、WS 鉴权 4401、conversation 往返、prompt 转发与 `SESSION_BUSY`/`CONVERSATION_NOT_FOUND`/`DEVICE_OFFLINE`、
session.update/task.state/approval 广播、agent 顶号 4409、agent.online/offline、device.status 缓存、ping/pong、非法 JSON。
