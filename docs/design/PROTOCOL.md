# PROTOCOL — DeepSeek Remote AI 通信协议与 API 契约

| 项目 | 内容 |
| --- | --- |
| 文档编号 | DSRA-DESIGN-001 |
| 版本 | 1.0（2026-10-31） |
| 状态 | 设计基线，可据此并行开发云端/手机/Agent |
| 上游依据 | `_docx_dump.txt` 第四章 4.2、第六章（表 3 + 6.1 事件）、第七章 |
| 关联文档 | [DATA_MODEL.md](./DATA_MODEL.md)、[REMOTE_AGENT.md](./REMOTE_AGENT.md)、[MOBILE_UI.md](./MOBILE_UI.md) |
| 协议版本 | REST `v1`；WebSocket 子协议 `dsremote.v1` |

> **重要边界声明**：本文件定义的 REST 与 WebSocket 协议是**本项目自有的**云端接口，不是 DeepSeek Harness 的
> 原生 API。Agent 与 Harness 之间的映射见 [REMOTE_AGENT.md](./REMOTE_AGENT.md) 第 5 节「HarnessAdapter 能力矩阵」。
> 凡引用 Harness 真实能力处，均以 [HARNESS_INTERFACES.md](../research/HARNESS_INTERFACES.md)（2026-10-31 实测）为准；已确认项标注 ✅/证据来源，仍未知项保留「待确认」标注（见 §12）。

---

## 0. 结论速览（先读这 14 条）

1. **两个令牌域**：手机用 JWT（access 15 分钟 + refresh 30 天旋转），Agent 用不透明 `device_token`（长期、可轮换）。
   二者不可互换，网关按 `Authorization` 前缀区分。
2. **统一 envelope**：`{code, message, data, traceId}`。HTTP 状态码只表达传输/网关层语义，客户端**只按 `code==0` 判成功**。
3. 成功统一返回 **HTTP 200**（含创建类接口），`data` 里返回资源；不返回业务 201/204，减少三端分支。
4. **游标分页**，不使用 offset：`?limit=20&cursor=<opaque>`，返回 `{items, nextCursor, hasMore}`。消息/事件持续增长，offset 会漂移。
5. **幂等**：对 `POST /api/tasks`、`POST /api/conversations`、`POST /api/files/upload`、`POST /api/devices/pair`
   **强制**要求 `Idempotency-Key` 头；其余 POST 可选。24 小时内同键同体返回首次响应，同键不同体返回 `409`。
6. WebSocket **不在 URL 带 token**（避免进入代理访问日志）：连接后 5 秒内必须发首帧 `sys.auth`，否则 `4001` 关闭。
7. 服务端→客户端的**所有**业务事件都带同一设备通道内单调递增的 `seq`；这是断线补偿、去重、乱序检测的唯一依据。
8. 断线重连：客户端发 `sys.resume {lastSeq}`，服务端从 `device_events` 回放 `seq > lastSeq`；若已超出保留期，
   回 `sys.replay.gap`，客户端改为 REST 全量刷新。
9. 心跳：手机每 25 秒、Agent 每 20 秒发 `sys.ping`，服务端 60 秒未收到任何帧即 `4008` 关闭；`sys.pong`
   由服务端回，携带服务端时间用于时钟偏差校正。
10. 命令下行（手机→云端→Agent）走 `client.command` → 云端转 `server.command` → Agent 回 `server.command_ack`；
   控制类命令 ack 超时 **10 秒**，超时返回 `50004`。手机端据此显示「指令未送达」而不是假装成功。
11. REST 中需要实时设备数据的接口（设备状态、项目文件列表）由云端用 **`server.command` RPC** 向 Agent 取数，
    10 秒超时；不允许云端直接连 Agent（Agent 只做出站连接）。
12. 审批（`task.waiting_approval`）是一条**带一次性票据**的重型流程：**in-flight** 由 ACP `session/request_permission` 提供官方阻塞点
    （真正执行危险工具前），云端生成 `approvalId` + `action_hash`，手机确认后云端下发 `approval.ticket`，Agent 校验后回
    `optionId=allow-once`；**pre-flight** 作为兜底。票据 120 秒过期、一次性消费；拒绝/超时绝不默认同意，且**不得把「用户拒绝」写成「任务失败」**。
13. 事件类型以策划案 6.1 的 13 个为**必选集**，另定义 6 个扩展事件（`approval.*`、`device.emergency_stopped` 等），
    扩展事件不得让客户端崩溃：客户端必须忽略未知 `type` 并计数上报。
14. 协议演进只做**向后兼容的加法**：未知字段忽略、枚举新增值客户端按 default 处理、事件只增不改不删；
    `dsremote.v2` 才允许破坏性变更。

---

## 1. 传输层与通用约定

### 1.1 端点与环境

| 环境 | Base URL | WebSocket |
| --- | --- | --- |
| 本地开发 | `http://127.0.0.1:8080` | `ws://127.0.0.1:8080/ws/v1/...` |
| 测试 / 生产 | `https://api.<domain>`（仅 HTTPS） | `wss://api.<domain>/ws/v1/...` |

- 仅允许 **TLS 1.2+**，HSTS `max-age=31536000`；HTTP 强制 301 到 HTTPS。
- API 前缀 `/api`，WebSocket 前缀 `/ws/v1`。
- 请求头 `X-Api-Version: 1`（可选，缺省为 1）；服务端在响应头回 `X-Api-Version`。
- 请求 ID：客户端可带 `X-Request-Id`（ULID），服务端回显在 `traceId`；未带则由服务端生成。
- 语言：错误 `message` 默认中文；`Accept-Language: en` 时返回英文（i18n 文案表见 MOBILE_UI §9）。

### 1.2 时间、ID、布尔

| 类型 | 格式 | 示例 |
| --- | --- | --- |
| 时间 | ISO-8601 UTC，毫秒精度，带 `Z` | `"2026-10-31T03:21:14.512Z"` |
| 资源 ID | ULID 26 字符 | `"01JAV3K8Q9W7M2X4B6C8D0E2F4"` |
| 幂等键 / msgId | ULID 26 字符 | 同上 |
| 分页游标 | Base64URL 不透明串（客户端不得解析） | `"djE6Y3JlYXRlZF9hdHwyMDI2LTEwLTMxVDAzOjIxOjE0LjUxMlo"` |
| 文件 ID | ULID | |
| 布尔 | JSON `true/false`，禁止 `"true"` | |

### 1.3 统一响应 envelope

**成功**：

```json
{
  "code": 0,
  "message": "ok",
  "data": { "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F4", "taskStatus": "queued" },
  "traceId": "01JAV3K9A1B2C3D4E5F6G7H8J9"
}
```

**失败**：

```json
{
  "code": 30002,
  "message": "设备当前不在线，指令未送达",
  "data": { "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "lastOnlineAt": "2026-10-31T02:00:11.000Z" },
  "traceId": "01JAV3K9A1B2C3D4E5F6G7H8J9"
}
```

规则：

- `code` 是**唯一**业务判定依据；`0` 成功，非 0 失败。
- `message` 面向用户，可直接展示；**不得**含内部堆栈、SQL、令牌、绝对路径。
- `data` 失败时可为 `null` 或提供可操作上下文（如上例的 `lastOnlineAt`）。
- `traceId` 必填，服务端日志可按它检索全链路（手机端「反馈问题」按钮自动附带它）。
- 空数据用 `data: null`，**不要**返回 `{}` 表示无数据。

### 1.4 HTTP 状态码策略

| HTTP | 何时使用 | 典型 `code` |
| --- | --- | --- |
| 200 | 业务成功（含创建、取消、撤销） | `0` |
| 400 | 参数缺失/格式错误/JSON 解析失败 | `10001`/`10002` |
| 401 | 未携带凭证、JWT 过期、refresh 失效 | `10003`/`10004` |
| 403 | 已认证但无权访问该资源 / 设备已撤销 / 权限级别不足 | `10005`/`30003`/`70001` |
| 404 | 资源不存在（或不属于当前用户，防枚举） | `40001`/`50001` |
| 409 | 幂等键冲突、任务状态冲突、设备重复配对 | `10007`/`50002`/`30004` |
| 413 | 上传文件超限 | `60002` |
| 429 | 限流 | `10006` |
| 500 | 未预期异常 | `90001` |
| 502/504 | Agent/Harness 通道异常或超时 | `50004`/`90002` |

> 客户端实现要求：`401` 时先尝试一次 refresh 再重放请求（不重放非幂等请求，除非带 `Idempotency-Key`）；
> `429` 读 `Retry-After` 退避；`5xx` 指数退避，最多 3 次。

### 1.5 错误码表（全项目唯一权威表）

| 段 | 含义 |
| --- | --- |
| 1xxxx | 通用与认证 |
| 2xxxx | 用户 |
| 3xxxx | 设备与配对 |
| 4xxxx | 会话与消息 |
| 5xxxx | 任务与 Harness 通道 |
| 6xxxx | 文件与项目 |
| 7xxxx | 权限与审批 |
| 9xxxx | 系统 |

| code | 名称 | HTTP | 中文提示 | 客户端动作 |
| --- | --- | --- | --- | --- |
| 0 | OK | 200 | ok | — |
| 10001 | INVALID_PARAM | 400 | 请求参数不合法 | 修正后重试 |
| 10002 | MALFORMED_JSON | 400 | 请求体格式错误 | 修复客户端 |
| 10003 | UNAUTHORIZED | 401 | 请先登录 | 跳登录 |
| 10004 | TOKEN_EXPIRED | 401 | 登录已过期，正在刷新 | 自动 refresh |
| 10005 | FORBIDDEN | 403 | 无权执行该操作 | 提示 |
| 10006 | RATE_LIMITED | 429 | 操作过于频繁，请稍后再试 | 按 Retry-After 退避 |
| 10007 | IDEMPOTENCY_CONFLICT | 409 | 相同幂等键对应不同请求内容 | 换新 key |
| 10008 | UNSUPPORTED_CLIENT_VERSION | 426 | 客户端版本过低，请升级 | 引导升级 |
| 20001 | USER_ALREADY_EXISTS | 409 | 用户名或邮箱已被注册 | 提示换名 |
| 20002 | LOGIN_FAILED | 401 | 用户名或密码错误 | 通用错误，不区分账号是否存在 |
| 20003 | ACCOUNT_LOCKED | 403 | 账号已临时锁定，请稍后再试 | 显示解锁时间 |
| 30001 | PAIRING_INVALID | 400 | 配对码无效或已过期 | 刷新二维码重扫 |
| 30002 | DEVICE_OFFLINE | 409 | 电脑离线，指令未送达 | 显示离线态，重连后重试 |
| 30003 | DEVICE_REVOKED | 403 | 该设备授权已被撤销 | 回到设备列表 |
| 30004 | DEVICE_ALREADY_PAIRED | 409 | 该电脑已绑定其他账号 | 提示先解绑 |
| 30005 | PAIRING_EXPIRED | 400 | 二维码已过期 | 刷新二维码 |
| 30006 | DEVICE_REMOTE_DISABLED | 403 | 设备已被紧急停止，只能在电脑本地恢复 | 提示前往电脑端恢复（§9） |
| 40001 | CONVERSATION_NOT_FOUND | 404 | 会话不存在 | 返回列表 |
| 40002 | CONVERSATION_DEVICE_MISMATCH | 400 | 会话与所选电脑不一致 | 切换设备 |
| 50001 | TASK_NOT_FOUND | 404 | 任务不存在 | 返回列表 |
| 50002 | TASK_STATE_CONFLICT | 409 | 任务当前状态不允许该操作 | 刷新任务详情 |
| 50003 | TASK_CANCEL_UNSUPPORTED | 422 | 当前 Harness 不支持取消，已请求停止采纳输出 | 提示限制（不得伪造已取消） |
| 50004 | DEVICE_CHANNEL_UNAVAILABLE | 502 | 暂时无法连接电脑端 | 重试/查设备状态 |
| 50005 | CAPABILITY_UNSUPPORTED | 422 | 该能力在当前 Harness 版本不可用 | 显示能力矩阵限制 |
| 60001 | WORKSPACE_NOT_AUTHORIZED | 403 | 该目录未授权访问 | 去电脑端授权 |
| 60002 | FILE_TOO_LARGE | 413 | 文件超出大小限制 | 提示上限 |
| 60003 | PATH_NOT_ALLOWED | 400 | 路径不合法或越权 | 拒绝执行并记审计 |
| 60004 | FILE_NOT_FOUND | 404 | 文件不存在 | 刷新目录 |
| 70001 | PERMISSION_LEVEL_REQUIRED | 403 | 需要更高权限级别 | 引导授权 |
| 70002 | APPROVAL_REQUIRED | 409 | 该操作需要二次确认 | 拉起确认弹窗 |
| 70003 | APPROVAL_DENIED | 403 | 确认已拒绝或已超时 | 提示 |
| 70004 | APPROVAL_EXPIRED | 409 | 确认票据已过期，请重新发起 | 重新发起 |
| 70005 | RISKY_OUTPUT_DETECTED | —（WS `sys.error`） | 执行输出命中高风险模式，建议立即停止 | 展示告警并与急停并列 |
| 90001 | INTERNAL_ERROR | 500 | 服务异常，请稍后重试 | 上报 |
| 90002 | UPSTREAM_TIMEOUT | 504 | 电脑端响应超时 | 重试 |
| 90003 | SLOW_CONSUMER | —（WS `sys.error`） | 客户端消费过慢，实时帧已降级 | 重连补偿或降低订阅 |
| 90004 | PROTOCOL_VIOLATION | —（WS `sys.error`） | 非法帧/未知命令 | 记录并上报 |

### 1.6 鉴权

#### 1.6.1 用户令牌（手机）

```http
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjIwMjYtMTAiLCJ0eXAiOiJKV1QifQ.eyJzdWIiOiIwMUpBVjNLOFE5VzdNMlg0QjZDOEQwRTJGNiIsInJvbGUiOiJ1c2VyIiwiaWF0IjoxNzYxODc0NTQ3LCJleHAiOjE3NjE4NzU0NDcsImp0aSI6IjAxSkFWM0s5QTFCMkMzRDRFNVE2RjdHOUgxIn0.k3JkX1NpZ25hdHVyZV9leGFtcGxlX25vdF9yZWFsX3ZhbHVl
```

Access token 头部与载荷：

```json
{
  "alg": "RS256",
  "typ": "JWT",
  "kid": "2026-10"
}
```

```json
{
  "sub": "01JAV3K8Q9W7M2X4B6C8D0E2F6",
  "role": "user",
  "iat": 1761874547,
  "exp": 1761875447,
  "jti": "01JAV3K9A1B2C3D4E5Q6F7G9H1"
}
```

- 算法 **RS256**（非对称）。理由：后续 WSS 网关与 REST API 可能拆成两个进程，用 JWKS 分发公钥比共享 HS256 密钥更安全；
  `GET /.well-known/jwks.json` 暴露公钥（`kid` 支持轮换，保留上一个 `kid` 24 小时）。
- access token **无状态**，服务端不查库；黑名单仅对「撤销设备后立刻踢下线」生效（Redis `jti` 黑名单，TTL=剩余有效期）。
- refresh token：**不透明随机串**（32 字节 Base64URL），只在 `POST /api/auth/refresh` 的 body 里传输，绝不放 URL。
  服务端只存 SHA-256，旋转式刷新（旧 token 立即失效）；检测到旧 token 复用 → 整族 `family_id` 撤销并返回 `10004`。

#### 1.6.2 设备凭证（Agent）

```http
Authorization: Device 01JAV3K8Q9W7M2X4B6C8D0E2F7.9f2c1a7e4b8d3c6f5a0e2b7c4d9f1a3c5e7b0d2f4a6c8e1b3d5f7a9c0e2b4d6f
```

- 格式 `<deviceId>.<deviceToken>`；服务端查 `devices.device_token_hash` 做 SHA-256(pepper‖token) 比对（常数时间比较）。
- 仅 Agent 使用；用户 API 不接受 `Device` 前缀，Agent API 不接受 `Bearer`。
- 轮换：`POST /api/agent/token/rotate`（补充端点）返回新 token，旧 token 宽限 60 秒。

#### 1.6.3 权限级别与接口的对应

策划案表 4 的六级权限在协议层的落点：

| 级别 | 能力 | 涉及接口/命令 | 判定点 |
| --- | --- | --- | --- |
| L1 查看设备状态 | 设备列表/状态/在线 | `GET /api/devices*`、`sys.auth` | 云端：资源归属 |
| L2 AI 对话与任务 | 会话、消息、任务 | `POST /api/tasks`、`/api/conversations*`、`task.*` 命令 | 云端归属 + Agent 配置允许 |
| L3 授权项目文件访问 | 目录读（写需显式开启） | `GET /api/workspaces*`、`file.*` | 云端 `workspace_permissions` + Agent 本地二次校验 |
| L4 终端操作 | 执行命令 | `task.create{taskType:"terminal"}` | 云端 L4 + Agent 白名单 + 高风险审批 |
| L5 远程桌面控制 | 屏幕查看/输入 | `desktop.*` 命令 | 云端 L5 授权 + Agent 本地确认（首次） |
| L6 高风险操作 | 删除/覆盖/批量/系统配置/装软件 | 任意会触发高风险的动作 | 云端生成 `approvals` + 手机二次确认 + Agent 票据校验 |

**判定顺序（任何一环失败即拒绝，均写 `audit_logs`）**：
`云端资源归属 → 云端 permission_level → Agent 本地授权表（本地为准） → 高风险审批票据（若命中） → 执行`。

### 1.7 分页

统一查询参数：`limit`（默认 20，最大 100）、`cursor`（不透明串，来自上一次响应的 `nextCursor`）。

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "items": [{ "id": "01JAV3K8Q9W7M2X4B6C8D0E2F4", "title": "重构登录模块" }],
    "nextCursor": "djE6Y3JlYXRlZF9hdHwyMDI2LTEwLTMxVDAzOjIxOjE0LjUxMlo",
    "hasMore": true
  },
  "traceId": "01JAV3K9A1B2C3D4E5F6G7H8J9"
}
```

- 游标内涵：`v1:<base64url({"createdAt":"...","id":"..."})>`，服务端按 `(created_at, id)` 复合键倒序切页；
  对 `messages` 用 `(seq_in_conversation)`。
- 客户端**不得**解析游标；换排序即游标作废（服务端返回 `10001`）。
- 不做总数统计（`count(*)` 大表昂贵）；需要时另给 `GET /api/tasks/stats`（补充端点，聚合表）。

### 1.8 幂等

- 请求头：`Idempotency-Key: <ULID>`，必填接口见 §0 第 5 条。
- 服务端流程：
  1. 事务内 `INSERT INTO idempotency_keys(user_id, idem_key, request_hash, status='in_progress')`；
  2. 主键冲突 → 若已有 `completed` 响应且 `request_hash` 相同 → 原样返回并加响应头 `Idempotent-Replay: true`；
     若 `request_hash` 不同 → `10007`；若仍 `in_progress` → 等待最多 3 秒，仍未完成返回 `409 10007`（客户端重试）。
  3. 业务成功/失败后写入 `response_code`/`response_body`，置 `completed`。
- 24 小时后清理；`Idempotency-Key` 长度 8–64，仅 `[A-Za-z0-9_-]`。
- WebSocket 指令幂等：用 `msgId` 作为 `device_commands.id`，主键冲突即视为重复，直接回 `server.command_ack`（不重复执行）。

### 1.9 限流

| 范围 | 限制 | 响应头 |
| --- | --- | --- |
| 登录/注册 | 单 IP 10 次/分钟，单账号 5 次/分钟 | `X-RateLimit-*`、`Retry-After` |
| 配对 | 单用户 10 次/分钟；单 pairingId 5 次（超过即 revoke） | 同上 |
| 创建任务 | 单用户 30 次/分钟；单设备 10 并发任务（超出 429） | 同上 |
| 普通读接口 | 单用户 120 次/分钟 | 同上 |
| WebSocket 连接 | 单用户 5 条并发连接，超出踢最旧 | `4009` 关闭 |
| Agent 上行事件 | 单设备 200 事件/秒；超出则在云端合并 `task.output` | — |

### 1.10 文件传输策略（ADR-PROTO-004）

手机与电脑不在同一网络时无法直连（P2P 需要 TURN 基础设施，见 REMOTE_AGENT ADR-010），因此文件走**云端中继**：

```mermaid
flowchart LR
    Phone[手机] -->|1 multipart 上传| API[云端 API]
    API -->|2 存对象存储| OSS[(对象存储)]
    API -->|3 WSS 命令 file.transfer_ready| Agent[电脑 Agent]
    Agent -->|4 预签名 URL 下载| OSS
    Agent -->|5 写入授权目录| Disk[本地磁盘]
```

- 上限：单文件 100MB，单用户日累计 2GB（可配置）；分片上传作为 P2 增强（预留 `files` 表字段）。
- 下载方向对称：Agent 上传到对象存储 → 云端生成 15 分钟预签名 URL → 手机 `GET /api/files/{id}/download` 取 URL。
- 所有写入必须落在 `workspace_permissions` 授权目录内，Agent 侧做 **realpath 归一化 + 前缀校验**（符号链接/`..` 逃逸一律 `60003`）。

### 1.11 云端 → Agent 的 RPC 模式（REST 实时取数）

REST 接口需要设备实时数据时（如项目文件列表），云端不直连 Agent，而是复用 WSS 下行：

```mermaid
sequenceDiagram
    participant App as 手机
    participant Api as 云端 REST
    participant Agent as 电脑 Agent
    App->>Api: GET /api/workspaces/{id}/files?path=src
    Api->>Api: 鉴权 + 校验 workspace_permissions
    Api->>Agent: WSS server.command request requestId=01JAV... method=workspace.list
    Agent->>Agent: 本地 realpath 校验
    Agent->>Api: WSS server.response requestId ok=true data=[...]
    Api->>App: 200 envelope data.items
```

- 超时 10 秒 → `504 90002`；设备离线 → `409 30002`。
- `requestId` 由云端生成（ULID），Agent 必须在响应中原样带回；同一 `requestId` 重试三遍未响应则放弃。
- 只允许**只读**方法走 RPC；写操作必须建模为 `task`（有状态、可审计、可取消）。

---

## 2. REST API 详解（策划案表 3 的 17 个接口）

### 2.0 总览表

| # | 方法 | 路径 | 鉴权 | 权限级别 | 幂等键 | 典型错误 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | POST | `/api/auth/register` | 无 | — | 可选 | 20001, 10001 |
| 2 | POST | `/api/auth/login` | 无 | — | 可选 | 20002, 20003, 10006 |
| 3 | POST | `/api/devices/pair` | Bearer | L1（绑定设备） | **必填** | 30001/30004/30005, 10007 |
| 4 | GET | `/api/devices` | Bearer | L1 | — | 10003 |
| 5 | GET | `/api/devices/{id}/status` | Bearer | L1 | — | 30002, 90002 |
| 6 | DELETE | `/api/devices/{id}` | Bearer | L1（设备归属） | 可选 | 30003 |
| 7 | GET | `/api/conversations` | Bearer | L2 | — | 10003 |
| 8 | POST | `/api/conversations` | Bearer | L2 | **必填** | 30002, 50005 |
| 9 | GET | `/api/conversations/{id}/messages` | Bearer | L2 | — | 40001 |
| 10 | POST | `/api/tasks` | Bearer | L2（按 taskType 提升到 L3/L4） | **必填** | 30002, 70001, 70002, 50005 |
| 11 | GET | `/api/tasks` | Bearer | L2 | — | — |
| 12 | GET | `/api/tasks/{id}` | Bearer | L2 | — | 50001 |
| 13 | POST | `/api/tasks/{id}/cancel` | Bearer | L2 | 可选（天然幂等） | 50001, 50002, 50003 |
| 14 | GET | `/api/workspaces` | Bearer | L3 | — | 30002 |
| 15 | GET | `/api/workspaces/{id}/files` | Bearer | L3 | — | 60001, 60003, 90002 |
| 16 | POST | `/api/files/upload` | Bearer | L3 | **必填** | 60002, 60001 |
| 17 | GET | `/api/files/{id}/download` | Bearer | L3 | — | 60004 |

> 「权限级别」是访问该接口所需的最低调级别；实际判定还必须通过「资源归属」检查（`user_id` 匹配）。
> 所有接口都要求 HTTPS；所有响应都是 §1.3 的 envelope，下文只列 `data` 内容。

---

### 2.1 `POST /api/auth/register` 用户注册

| 属性 | 值 |
| --- | --- |
| 鉴权 | 无 |
| 限流 | 单 IP 10 次/分钟 |
| 幂等 | 可选（建议带 `Idempotency-Key`，防双击） |

**请求**

```http
POST /api/auth/register
Content-Type: application/json
X-Request-Id: 01JAV3K9A1B2C3D4E5F6G7H8J9

{
  "username": "user",
  "password": "S3cure!Passw0rd",
  "email": "user@example.com",
  "phone": "+8613800000000"
}
```

字段约束：`username` 3–32 位 `[A-Za-z0-9_-]`；`password` 8–64 位且至少含字母与数字（Argon2id 哈希后入库）；
`email`/`phone` 至少给一个用于找回（本期不发送验证码，仅存值，**标注为后续增强**）。

**响应 200**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "userId": "01JAV3K8Q9W7M2X4B6C8D0E2F6",
    "username": "user",
    "accessToken": "eyJhbGciOiJSUzI1NiIsImtpZCI6IjIwMjYtMTAtMDEiLCJ0eXAiOiJKV1QifQ.eyJzdWIiOiIwMUpBVjNLOFE5VzdNMlg0QjZDOEQwRTJGNiIsInJvbGUiOiJ1c2VyIiwiaWF0IjoxNzYxODc0NTQ3LCJleHAiOjE3NjE4NzU0NDd9.k3JkX1NpZ25hdHVyZV9leGFtcGxl",
    "refreshToken": "9LwQ2mT7vXbPnR4sKcY6hJzA8dFgU1iE3oVqB5rN0yMtH2uS",
    "expiresIn": 900,
    "refreshExpiresIn": 2592000
  },
  "traceId": "01JAV3K9A1B2C3D4E5F6G7H8J9"
}
```

**错误**：`20001`（用户名/邮箱已存在，409）、`10001`（格式错误）。

---

### 2.2 `POST /api/auth/login` 用户登录

| 属性 | 值 |
| --- | --- |
| 鉴权 | 无 |
| 限流 | 单 IP 10 次/分钟、单账号 5 次/分钟 |
| 幂等 | 可选 |

**请求**

```json
{
  "username": "user",
  "password": "S3cure!Passw0rd",
  "clientInfo": { "platform": "android", "appVersion": "1.0.0", "model": "Pixel 8" }
}
```

**响应 200**：与 2.1 相同结构，另加 `deviceCredentialsProvided: false`。

**错误**：`20002`（用户名或密码错误，**不区分账号是否存在**，防枚举）、`20003`（锁定，`data.lockedUntil` 给出时间）、
`10006`（限流）。

---

### 2.3 `POST /api/devices/pair` 设备配对

前置：电脑端 Agent 已启动并生成配对二维码（调用**补充端点** `POST /api/agent/pairing-sessions`，
见 §2.18），二维码内容为：

```
dsremote://pair?v=1&pid=01JAV3K8Q9W7M2X4B6C8D0E2F7&tok=9f2c1a7e4b8d3c6f5a0e2b7c4d9f1a3c&api=https%3A%2F%2Fapi.example.com
```

| 属性 | 值 |
| --- | --- |
| 鉴权 | `Authorization: Bearer <user access token>` |
| 权限级别 | L1（把设备绑定到当前账号） |
| 幂等 | **必填** |
| 限流 | 单用户 10 次/分钟；单 pairingId 最多 5 次失败即作废 |

**请求**

```http
POST /api/devices/pair
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
Idempotency-Key: 01JAV3K9B2C3D4E5F6G7H8J9K1
Content-Type: application/json

{
  "pairingId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
  "pairingToken": "9f2c1a7e4b8d3c6f5a0e2b7c4d9f1a3c5e7b0d2f4a6c8e1b3d5f7a9c0e2b4d6f",
  "deviceAlias": "书房的电脑"
}
```

**响应 200**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
    "deviceName": "书房的电脑",
    "operatingSystem": "Windows 11 23H2 (22631.4169)",
    "agentVersion": "0.4.1",
    "harnessVersion": "待探测",
    "deviceStatus": "active",
    "pairedAt": "2026-10-31T03:21:14.512Z"
  },
  "traceId": "01JAV3K9B2C3D4E5F6G7H8J9K1"
}
```

**服务端副作用**：`device_pairings.status='used'`、`used_at`、`user_id` 写入；`devices.user_id` 绑定、
`device_status='active'`、生成 `device_token` 并通过配对 WS 通道一次性下发给 Agent（Agent 存 DPAPI 后连接
`/ws/v1/agent`）；写 `audit_logs(action_type='device.pair', action_result='success')`。

**错误**：`30001`（配对码不存在/已被使用）、`30005`（过期）、`30004`（设备已属他人）、`10007`（幂等冲突）。

**配对时序**（完整流程与安全分析见 [REMOTE_AGENT.md](./REMOTE_AGENT.md) §7.1）：

```mermaid
sequenceDiagram
    autonumber
    participant Agent as 电脑 Agent
    participant Api as 云端 API
    participant Phone as 手机 App
    Agent->>Api: POST /api/agent/pairing-sessions 提交设备元数据
    Api-->>Agent: pairingId pairingToken qrPayload expiresAt
    Agent->>Agent: 本地 UI 展示二维码
    Agent->>Api: WSS /ws/v1/pairing 首帧 sys.auth pairingId 加 pairingToken
    Api-->>Agent: sys.auth.ok 进入等待配对
    Phone->>Phone: 扫码解析 dsremote 链接
    Phone->>Api: POST /api/devices/pair 携带用户 JWT 与配对令牌
    Api->>Api: 校验配对会话 有效期 未使用 绑定 user_id
    Api->>Agent: WSS sys.pairing.approved deviceId deviceToken
    Agent->>Agent: DPAPI 加密保存 deviceToken
    Agent->>Api: WSS /ws/v1/agent 首帧 sys.auth 设备凭证
    Api-->>Phone: 200 配对成功 设备信息
    Agent->>Api: WSS device.online 事件
```

---

### 2.4 `GET /api/devices` 设备列表

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L1 |

**请求**

```http
GET /api/devices?limit=20&cursor= HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

**响应 200**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "items": [
      {
        "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
        "deviceName": "书房的电脑",
        "operatingSystem": "Windows 11 23H2",
        "agentVersion": "0.4.1",
        "harnessVersion": "待探测",
        "deviceStatus": "active",
        "online": true,
        "lastOnlineAt": "2026-10-31T03:21:10.000Z",
        "capabilities": { "chat": true, "streaming": true, "cancel": true, "terminal": false, "desktop": true, "fileWrite": true },
        "activeTask": { "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9", "taskName": "重构登录模块", "taskStatus": "running", "progress": 42 }
      }
    ],
    "nextCursor": null,
    "hasMore": false
  },
  "traceId": "01JAV3K9C3D4E5F6G7H8J9K1L2"
}
```

说明：`online` 是服务端合成字段（`device_status='active'` 且 90 秒内有心跳，或 Redis presence 存在），
见 DATA_MODEL ADR-006；`capabilities` 来自最近一次 Agent 上报的能力矩阵。

---

### 2.5 `GET /api/devices/{id}/status` 设备状态

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L1 |
| 查询参数 | `live=true` 时云端向 Agent 发 RPC 取实时值，否则 5 秒缓存 |

**请求**

```http
GET /api/devices/01JAV3K8Q9W7M2X4B6C8D0E2F7/status?live=true HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

**响应 200（实时）**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
    "online": true,
    "deviceStatus": "active",
    "agent": { "version": "0.4.1", "uptimeSec": 83421, "remoteEnabled": true, "emergencyStopped": false },
    "harness": { "running": true, "version": "待探测", "reachable": true, "lastProbeAt": "2026-10-31T03:21:09.000Z" },
    "os": { "name": "Windows 11", "build": "22631.4169", "arch": "x64" },
    "metrics": { "cpuPercent": 12.5, "memoryUsedMb": 812, "activeTasks": 1 },
    "network": { "latencyMs": 38, "connectionState": "connected" },
    "currentTaskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "permissions": { "maxLevel": 5, "desktopControl": true, "terminal": false }
  },
  "traceId": "01JAV3K9C3D4E5F6G7H8J9K1L2"
}
```

**错误**：`30002`（离线，`data.lastOnlineAt`）、`90002`（RPC 超时，`live=true` 且 Agent 未回 10 秒）。

> `harness.*` 字段的真实来源：`dsh --version` / ACP `initialize.agentInfo` / 能力探测结果（见
> [HARNESS_INTERFACES.md](../research/HARNESS_INTERFACES.md) 与 REMOTE_AGENT §4.2），**不臆造 Harness 未提供的字段**。

---

### 2.6 `DELETE /api/devices/{id}` 撤销或删除设备授权

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer（必须是设备所属用户） |
| 权限级别 | L1 |
| 副作用 | 立即拒绝该设备新操作；踢掉其 WSS；写审计 `critical` |

**请求**

```http
DELETE /api/devices/01JAV3K8Q9W7M2X4B6C8D0E2F7 HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

**响应 200**

```json
{ "code": 0, "message": "ok", "data": { "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "deviceStatus": "revoked", "revokedAt": "2026-10-31T03:30:00.000Z" }, "traceId": "01JAV3K9D4E5F6G7H8J9K1L2M3" }
```

**行为细节**：`devices.device_status='revoked'`、`revoked_at=now()`、`device_token_hash=NULL`；
`device_pairings` 中 pending 记录置 `revoked`；向 Agent 推送 `device.revoked` 后关闭连接（10 秒后强制）；
Agent 收到后清除本地凭证并停止一切远程能力。**撤销后重新配对必须走全新二维码**。

---

### 2.7 `GET /api/conversations` 会话列表

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L2 |
| 查询参数 | `deviceId`（可选）、`archived`（默认 false）、`limit`、`cursor` |

**请求**

```http
GET /api/conversations?deviceId=01JAV3K8Q9W7M2X4B6C8D0E2F7&limit=20 HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

**响应 200**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "items": [
      {
        "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
        "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
        "title": "重构登录模块",
        "harnessSessionId": null,
        "lastMessageAt": "2026-10-31T03:22:01.000Z",
        "messageCount": 12,
        "lastMessagePreview": "已生成新的 JWT 校验逻辑，需要我继续补测试吗？",
        "activeTaskId": null
      }
    ],
    "nextCursor": "djE6Y3JlYXRlZF9hdHwyMDI2LTEwLTMxVDAzOjIyOjAxLjAwMFo",
    "hasMore": true
  },
  "traceId": "01JAV3K9E5F6G7H8J9K1L2M3N4"
}
```

---

### 2.8 `POST /api/conversations` 创建会话

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L2 |
| 幂等 | **必填** |

**请求**

```json
{
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
  "title": "重构登录模块"
}
```

**响应 200**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
    "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
    "title": "重构登录模块",
    "harnessSessionId": null,
    "sessionState": "active",
    "createdAt": "2026-10-31T03:20:00.000Z"
  },
  "traceId": "01JAV3K9F6G7H8J9K1L2M3N4P5"
}
```

说明：云端先建本地会话；若 HarnessAdapter 支持 `createSession()`，Agent 在首个任务执行时创建 Harness 侧会话并回填
`harness_session_id`（通过 `session.created` 事件）。不支持时 `harnessSessionId` 恒为 `null`，会话是**纯本项目概念**——
这一点必须在 UI 上如实呈现（MOBILE_UI §4.2）。设备离线时创建会话**允许成功**（会话是云端资源），但首个任务会失败。

---

### 2.9 `GET /api/conversations/{id}/messages` 会话消息

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L2 |
| 分页 | `limit`（默认 30，最大 100）、`cursor`；支持 `afterSeq` 增量拉取 |
| 排序 | 时间升序返回（聊天界面语义），`nextCursor` 指向更早消息 |

**请求**

```http
GET /api/conversations/01JAV3K8Q9W7M2X4B6C8D0E2F8/messages?limit=30&beforeCursor= HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

**响应 200**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "items": [
      {
        "messageId": "01JAV3K8Q9W7M2X4B6C8D0E2FA",
        "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
        "role": "user",
        "content": "帮我把登录模块改成 JWT 校验",
        "contentType": "text",
        "seqInConversation": 1,
        "clientMsgId": "01JAV3K8Q9W7M2X4B6C8D0E2FB",
        "createdAt": "2026-10-31T03:20:30.000Z"
      },
      {
        "messageId": "01JAV3K8Q9W7M2X4B6C8D0E2FC",
        "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
        "role": "assistant",
        "content": "已修改 `AuthController.java`，主要变更：\n\n1. 新增 `JwtFilter`\n2. 移除 Session 校验\n\n需要我继续补单元测试吗？",
        "contentType": "markdown",
        "seqInConversation": 2,
        "metadata": { "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9", "durationMs": 48213, "fileRefs": [] },
        "createdAt": "2026-10-31T03:21:18.000Z"
      }
    ],
    "nextCursor": "djE6c2VxX2luX2NvbnZlcnNhdGlvbnwyMDE",
    "hasMore": true
  },
  "traceId": "01JAV3K9G7H8J9K1L2M3N4P5Q6"
}
```

**增量同步**：`?afterSeq=2` 返回 `seq_in_conversation > 2` 的消息（升序，不返回 `nextCursor` 语义），用于重连补偿。

---

### 2.10 `POST /api/tasks` 创建任务

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L2 起，按 `taskType` 提升：`file_operation`→L3、`terminal`→L4、`desktop`→L5；命中高风险再加 L6 审批 |
| 幂等 | **必填** |
| 限流 | 单用户 30 次/分钟；单设备并发任务上限 10 |

**请求**

```json
{
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
  "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
  "taskName": "重构登录模块为 JWT 校验",
  "taskType": "code_analysis",
  "prompt": "帮我把登录模块改成 JWT 校验，并补充单元测试",
  "attachments": [
    { "fileId": "01JAV3K8Q9W7M2X4B6C8D0E2FD", "kind": "file" }
  ],
  "workspacePermissionId": "01JAV3K8Q9W7M2X4B6C8D0E2FE",
  "options": { "timeoutSec": 900, "model": "default" }
}
```

**响应 200（已下发 Agent）**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "taskStatus": "queued",
    "taskName": "重构登录模块为 JWT 校验",
    "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
    "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
    "permissionLevel": 2,
    "requiresApproval": false,
    "createdAt": "2026-10-31T03:20:31.000Z"
  },
  "traceId": "01JAV3K9H8J9K1L2M3N4P5Q6R7"
}
```

**可能要求审批（HTTP 409）**

```json
{
  "code": 70002,
  "message": "该操作需要二次确认",
  "data": {
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "approvalId": "01JAV3K8Q9W7M2X4B6C8D0E2FF",
    "approvalType": "terminal_command",
    "actionSummary": "执行命令：del /s /q D:\\work\\proj-a\\dist",
    "riskLevel": "critical",
    "expiresAt": "2026-10-31T03:22:31.000Z"
  },
  "traceId": "01JAV3K9H8J9K1L2M3N4P5Q6R7"
}
```

> 语义：任务行已创建为 `waiting_approval`，但**指令未下发**；手机确认后走 §8 审批流程，Agent 收到票据才执行。
> 未确认超时（120 秒）→ 任务自动 `failed`，`errorCode=70003`。

**错误**：`30002`（设备离线，指令未送达，`data.lastOnlineAt`）、`70001`（权限级别不足）、`70002`（需审批，见上）、
`50005`（能力不可用，`data.capability` 指出具体能力）、`10006`（并发超限）、`50002`（状态冲突，如设备处于紧急停止）。

**任务下发到 Agent 的命令**（§7.3 定义）：`server.command{command:"task.create", commandId=<手机 msgId>}`。

---

### 2.11 `GET /api/tasks` 任务列表

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L2 |
| 查询参数 | `status`（可重复，逗号分隔）、`deviceId`、`conversationId`、`limit`、`cursor`、`updatedAfter`（ISO 时间，用于轮询补数） |

**请求**

```http
GET /api/tasks?status=running,waiting_approval&deviceId=01JAV3K8Q9W7M2X4B6C8D0E2F7&limit=20 HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

**响应 200**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "items": [
      {
        "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
        "taskName": "重构登录模块为 JWT 校验",
        "taskType": "code_analysis",
        "taskStatus": "running",
        "progress": 42,
        "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
        "deviceName": "书房的电脑",
        "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
        "permissionLevel": 2,
        "startedAt": "2026-10-31T03:20:35.000Z",
        "finishedAt": null,
        "errorCode": null,
        "errorMessage": null,
        "createdAt": "2026-10-31T03:20:31.000Z",
        "updatedAt": "2026-10-31T03:21:10.000Z"
      }
    ],
    "nextCursor": null,
    "hasMore": false,
    "serverTime": "2026-10-31T03:21:15.000Z"
  },
  "traceId": "01JAV3K9J9K1L2M3N4P5Q6R7S8"
}
```

`serverTime` 用于手机端校正倒计时（审批剩余时间、任务超时）。

---

### 2.12 `GET /api/tasks/{id}` 任务详情

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L2 |
| 查询参数 | `includeEvents=true&afterSeq=120&eventLimit=200`（可选，用于断线后补齐执行日志） |

**请求**

```http
GET /api/tasks/01JAV3K8Q9W7M2X4B6C8D0E2F9?includeEvents=true&afterSeq=0&eventLimit=100 HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

**响应 200**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "task": {
      "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
      "taskName": "重构登录模块为 JWT 校验",
      "taskType": "code_analysis",
      "taskStatus": "running",
      "progress": 42,
      "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
      "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
      "prompt": "帮我把登录模块改成 JWT 校验，并补充单元测试",
      "permissionLevel": 2,
      "result": null,
      "errorCode": null,
      "errorMessage": null,
      "startedAt": "2026-10-31T03:20:35.000Z",
      "finishedAt": null,
      "lastEventSeq": 131,
      "createdAt": "2026-10-31T03:20:31.000Z",
      "updatedAt": "2026-10-31T03:21:10.000Z"
    },
    "events": [
      { "seq": 120, "type": "task.progress", "ts": "2026-10-31T03:20:40.000Z", "payload": { "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9", "progress": 40 } },
      { "seq": 131, "type": "task.output", "ts": "2026-10-31T03:21:09.000Z", "payload": { "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9", "stream": "answer", "delta": "正在分析 AuthController.java ...", "offset": 2048 } }
    ],
    "eventsHasMore": true
  },
  "traceId": "01JAV3K9K1L2M3N4P5Q6R7S8T9"
}
```

**错误**：`50001`（不存在或不属于当前用户，统一 404 防枚举）。

---

### 2.13 `POST /api/tasks/{id}/cancel` 取消任务

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L2 |
| 幂等 | 天然幂等（重复取消返回当前状态） |

**请求**

```json
{ "reason": "user_cancel" }
```

**响应 200（已受理，等待 Agent 确认）**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "taskStatus": "running",
    "cancelRequested": true,
    "cancelRequestedAt": "2026-10-31T03:21:30.000Z"
  },
  "traceId": "01JAV3K9L2M3N4P5Q6R7S8T9U1"
}
```

语义说明（**诚实原则**）：

- 云端立即 `cancel_requested_at=now()` 并转发 `task.cancel` 命令；任务状态**不立刻**改成 `cancelled`，
  必须等 Agent 确认（`task.cancelled` 事件，含 `harnessAck` 字段）。
- **ACP 原生取消**：Agent 发 `session/cancel`，实测 2.5 秒内收到 `stopReason=cancelled`，此时返回
  `task.cancelled{harnessAck:true, mechanism:"native"}`；10 秒未回则 Agent kill 整个 ACP 进程，返回
  `task.cancelled{harnessAck:true, mechanism:"signal_kill"}`（以实际机制为准）。
- **降级 headless**（无 cancel 协议）：只能杀进程，Agent 返回 `task.cancelled{harnessAck:false, mechanism:"signal_term"|"signal_kill"}`，UI 必须显示
  「已停止采纳输出，Harness 进程可能仍在运行」——不得显示为完全取消。
- 取消后手机端立即停止渲染该任务的新 `task.output`（按 taskId 过滤），这是产品侧第一道防线。

**错误**：`50001`、`50002`（任务已终态）、`30002`（设备离线：此时返回 409 `30002`，但云端仍标记
`cancel_requested`，等 Agent 上线后补发——这是唯一允许的「离线排队」语义，因为取消是安全操作）。

---

### 2.14 `GET /api/workspaces` 授权项目列表

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L3 |
| 数据来源 | `workspace_permissions`（云端权威）+ 可选 `live=true` 让 Agent 补 git/大小信息 |

**请求**

```http
GET /api/workspaces?deviceId=01JAV3K8Q9W7M2X4B6C8D0E2F7&live=true HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

**响应 200**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "items": [
      {
        "workspacePermissionId": "01JAV3K8Q9W7M2X4B6C8D0E2FE",
        "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
        "name": "proj-a",
        "workspacePath": "D:\\work\\proj-a",
        "permissionLevel": 4,
        "canRead": true,
        "canWrite": true,
        "git": { "isRepo": true, "branch": "feature/jwt", "dirty": true, "ahead": 2, "behind": 0 },
        "lastModifiedAt": "2026-10-31T02:58:00.000Z",
        "sizeBytes": 104857600
      }
    ],
    "nextCursor": null,
    "hasMore": false
  },
  "traceId": "01JAV3K9M3N4P5Q6R7S8T9U1V2"
}
```

**错误**：`30002`（`live=true` 且设备离线）、`90002`（Agent RPC 超时）。
`git` 字段为**可选能力**：HarnessAdapter 无法获取时返回 `null`，UI 显示「不可用」而不是空白。

---

### 2.15 `GET /api/workspaces/{id}/files` 项目文件列表

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L3（写操作另行要求 `canWrite`） |
| 查询参数 | `path`（相对授权根目录，缺省为根）、`limit`（默认 100，最大 500）、`cursor` |
| 数据来源 | 云端 RPC 到 Agent（§1.11） |

**请求**

```http
GET /api/workspaces/01JAV3K8Q9W7M2X4B6C8D0E2FE/files?path=src%2Fmain%2Fjava HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

**响应 200**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "workspacePermissionId": "01JAV3K8Q9W7M2X4B6C8D0E2FE",
    "path": "src/main/java",
    "items": [
      { "name": "AuthController.java", "type": "file", "sizeBytes": 8421, "modifiedAt": "2026-10-30T09:11:00.000Z", "etag": "sha256:7f83b1657ff1fc53" },
      { "name": "config", "type": "directory", "sizeBytes": 0, "modifiedAt": "2026-10-29T12:00:00.000Z", "etag": null }
    ],
    "nextCursor": null,
    "hasMore": false,
    "truncated": false
  },
  "traceId": "01JAV3K9N4P5Q6R7S8T9U1V2W3"
}
```

**错误**：`60001`（目录未授权）、`60003`（路径含 `..`/越界/指向授权目录外）、`60004`（不存在）、
`30002`（设备离线）、`90002`（RPC 超时）。`truncated=true` 表示目录项过多被截断，需用 `cursor` 翻页。

---

### 2.16 `POST /api/files/upload` 文件上传

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L3（写入目录需 `canWrite=true`） |
| 幂等 | **必填** |
| Content-Type | `multipart/form-data` |
| 大小 | 单文件 100MB（可配置），超限 `413 60002` |

**请求**

```http
POST /api/files/upload HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
Idempotency-Key: 01JAV3K9P5Q6R7S8T9U1V2W3X4
Content-Type: multipart/form-data; boundary=----DSRABoundary

------DSRABoundary
Content-Disposition: form-data; name="meta"
Content-Type: application/json

{"deviceId":"01JAV3K8Q9W7M2X4B6C8D0E2F7","workspacePermissionId":"01JAV3K8Q9W7M2X4B6C8D0E2FE","relativePath":"docs/需求说明.pdf","direction":"up"}
------DSRABoundary
Content-Disposition: form-data; name="file"; filename="需求说明.pdf"
Content-Type: application/pdf

<binary>
------DSRABoundary--
```

**响应 200**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "fileId": "01JAV3K8Q9W7M2X4B6C8D0E2FD",
    "fileName": "需求说明.pdf",
    "sizeBytes": 348122,
    "sha256": "5d41402abc4b2a76b9719d911017c5928f0e3b1b3c1f5d0f0d3f4b2a1c9e8d7f",
    "mimeType": "application/pdf",
    "status": "available",
    "transferState": "pending_agent",
    "expiresAt": "2026-11-07T03:21:14.512Z"
  },
  "traceId": "01JAV3K9P5Q6R7S8T9U1V2W3X4"
}
```

`transferState`：`pending_agent`（已存云端，等待 Agent 拉取写入）→ 收到 Agent 确认后置 `available`；
Phone 通过 `file.transfer_ready` / `file.transfer_completed` 事件得知最终状态。设备离线时文件留在云端，
上线后 Agent 拉取（这是文件方向**唯一**允许的离线暂存）。

**错误**：`60002`（超限）、`60001`（目录未授权）、`60003`（路径非法）、`10007`（幂等冲突）。

---

### 2.17 `GET /api/files/{id}/download` 文件下载

| 属性 | 值 |
| --- | --- |
| 鉴权 | Bearer |
| 权限级别 | L3 |
| 返回 | 15 分钟有效的预签名 URL（**不直接返回二进制**，便于手机后台下载/断点续传） |

**请求**

```http
GET /api/files/01JAV3K8Q9W7M2X4B6C8D0E2FD/download HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

**响应 200**

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "fileId": "01JAV3K8Q9W7M2X4B6C8D0E2FD",
    "fileName": "需求说明.pdf",
    "sizeBytes": 348122,
    "sha256": "5d41402abc4b2a76b9719d911017c5928f0e3b1b3c1f5d0f0d3f4b2a1c9e8d7f",
    "downloadUrl": "https://oss.example.com/dsra-files/01JAV3K8Q9W7M2X4B6C8D0E2FD?X-Amz-Expires=900&X-Amz-Signature=7b4c2f1e9a8d6c5b4a3f2e1d0c9b8a7f",
    "urlExpiresAt": "2026-10-31T03:36:14.512Z",
    "source": "agent"
  },
  "traceId": "01JAV3K9Q6R7S8T9U1V2W3X4Y5"
}
```

说明：`source` 为 `agent` 表示该文件由电脑产生（策划案 2.5「下载项目文件」）；若文件尚在 Agent 侧未上传，
响应可能是 **202 语义的 `60004`/`50004` 组合**：推荐做法是手机先发 `file.request` 命令（§7.3），Agent 上传完成后
云端再生成 URL 并推送 `file.transfer_ready`，手机随后再调本接口。**不要**让本接口长时间阻塞等待 Agent。

**错误**：`60004`（文件不存在/已过期）、`60001`（越权）、`30003`（设备已撤销）。

---

### 2.18 补充端点（表 3 之外，实现必需）

| 方法 | 路径 | 鉴权 | 说明 | 幂等 |
| --- | --- | --- | --- | --- |
| POST | `/api/auth/refresh` | refresh token（body） | 旋转刷新 access token | 天然 |
| POST | `/api/auth/logout` | Bearer | 撤销当前 refresh 家族 | 是 |
| GET | `/api/auth/me` | Bearer | 当前用户资料（个人中心） | — |
| POST | `/api/agent/pairing-sessions` | 无（限流 + 5 分钟 TTL） | Agent 创建配对会话，返回二维码内容 | 可选 |
| DELETE | `/api/agent/pairing-sessions/{id}` | Pairing 凭证 | Agent 取消配对会话 | 是 |
| POST | `/api/agent/token/rotate` | Device | 轮换设备凭证（旧 token 60 秒宽限） | 是 |
| GET | `/api/approvals` | Bearer | 待确认审批列表（WS 断线时的兜底） | — |
| POST | `/api/approvals/{id}/decide` | Bearer | 提交审批决定（`approve`/`deny`），需手机生物识别二次验证 | 是 |
| GET | `/api/tasks/stats` | Bearer | 任务聚合统计（任务中心顶部卡片） | — |
| GET | `/api/health` | 无 | 存活探针（`{status:"UP",version:...}`） | — |
| GET | `/.well-known/jwks.json` | 无 | JWT 公钥集 | — |

`POST /api/approvals/{id}/decide` 示例：

```json
{ "decision": "approve", "verifiedBy": "biometric", "clientSignedAt": "2026-10-31T03:21:40.120Z" }
```

响应：

```json
{ "code": 0, "message": "ok", "data": { "approvalId": "01JAV3K8Q9W7M2X4B6C8D0E2FF", "status": "approved", "decidedAt": "2026-10-31T03:21:40.200Z" }, "traceId": "01JAV3K9R7S8T9U1V2W3X4Y5Z6" }
```

> `verifiedBy` 只是**声明**，真实保障来自「手机已通过 `local_auth` 生物识别/PIN 才能拿到该请求」这一客户端流程；
> 服务端不做生物识别校验（不可能），但会校验 `approvalId` 归属、未过期、未消费，并对同一 `approvalId` 只接受一次决定。

---

## 3. WebSocket：连接、握手与认证

### 3.1 三个连接端点

| 端点 | 使用者 | 认证方式 | 生命周期 |
| --- | --- | --- | --- |
| `wss://api.<domain>/ws/v1/app` | 手机 App | 首帧 `sys.auth` + 用户 JWT | 长期，随 App 前后台切换 |
| `wss://api.<domain>/ws/v1/agent` | 电脑 Agent | 首帧 `sys.auth` + 设备凭证 | 长期（Agent 运行期），断线自动重连 |
| `wss://api.<domain>/ws/v1/pairing` | 电脑 Agent（配对期） | 首帧 `sys.auth` + 配对令牌 | 最长 5 分钟，配对完成即关 |

- 子协议：握手时 `Sec-WebSocket-Protocol: dsremote.v1`，服务端回显 `dsremote.v1`；版本不符 → `4001`。
- 帧类型：文本帧（JSON，UTF-8）；二进制帧**仅**用于 `desktop.frame` 媒体分片（见 §7.3）。
- 压缩：`permessage-deflate` 可选开启；手机端首包延迟敏感，默认**关闭**。

### 3.2 首帧认证（ADR-PROTO-003）

连接建立后 **5 秒内**必须发送 `sys.auth`。认证前服务端只接受 `sys.auth`，其它帧一律忽略并计数；超时 → `4001`。

**手机认证帧**

```json
{
  "msgId": "01JAV3K9V1V2W3X4Y5Z6A7B8C9",
  "type": "sys.auth",
  "ts": "2026-10-31T03:21:14.512Z",
  "payload": {
    "client": "app",
    "token": "eyJhbGciOiJSUzI1NiIsImtpZCI6IjIwMjYtMTAtMDEiLCJ0eXAiOiJKV1QifQ.eyJzdWIiOiIwMUpBVjNLOFE5VzdNMlg0QjZDOEQwRTJGNiIsInJvbGUiOiJ1c2VyIiwiaWF0IjoxNzYxODc0NTQ3LCJleHAiOjE3NjE4NzU0NDd9.k3JkX1NpZ25hdHVyZV9leGFtcGxl",
    "appVersion": "1.0.0",
    "platform": "android",
    "protocolVersion": 1,
    "resume": {
      "devices": [
        { "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "lastSeq": 131 }
      ]
    }
  }
}
```

**Agent 认证帧**

```json
{
  "msgId": "01JAV3K9W1V2W3X4Y5Z6A7B8C9D0",
  "type": "sys.auth",
  "ts": "2026-10-31T03:21:15.000Z",
  "payload": {
    "client": "agent",
    "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
    "deviceToken": "9f2c1a7e4b8d3c6f5a0e2b7c4d9f1a3c5e7b0d2f4a6c8e1b3d5f7a9c0e2b4d6f",
    "agentVersion": "0.4.1",
    "protocolVersion": 1,
    "harness": { "running": true, "version": "待探测", "lastProbeAt": "2026-10-31T03:21:09.000Z" },
    "capabilities": {
      "chat": true, "streaming": true, "cancel": true, "pause": false,
      "sessions": false, "sessionResume": false,
      "fileRead": true, "fileWrite": true, "terminal": false,
      "desktopCapture": true, "desktopInput": false, "approvalIntercept": false
    }
  }
}
```

**配对认证帧**

```json
{
  "msgId": "01JAV3K9X1V2W3X4Y5Z6A7B8C9D0E1",
  "type": "sys.auth",
  "ts": "2026-10-31T03:21:15.100Z",
  "payload": {
    "client": "pairing",
    "pairingId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
    "pairingToken": "9f2c1a7e4b8d3c6f5a0e2b7c4d9f1a3c5e7b0d2f4a6c8e1b3d5f7a9c0e2b4d6f",
    "deviceName": "书房的电脑",
    "operatingSystem": "Windows 11 23H2",
    "agentVersion": "0.4.1",
    "capabilities": { "chat": true, "streaming": true, "cancel": true, "desktopCapture": true }
  }
}
```

**认证成功响应**

```json
{
  "msgId": "01JAV3K9Y1V2W3X4Y5Z6A7B8C9D0E2",
  "type": "sys.auth.ok",
  "ts": "2026-10-31T03:21:14.700Z",
  "payload": {
    "connId": "01JAV3K9Z1V2W3X4Y5Z6A7B8C9D0E3",
    "userId": "01JAV3K8Q9W7M2X4B6C8D0E2F6",
    "serverTime": "2026-10-31T03:21:14.700Z",
    "heartbeatIntervalMs": 25000,
    "idleTimeoutMs": 60000,
    "protocolVersion": 1,
    "features": ["replay", "approval", "desktop", "file", "rpc"]
  }
}
```

认证失败：

```json
{
  "msgId": "01JAV3K9Y1V2W3X4Y5Z6A7B8C9D0E4",
  "type": "sys.auth.fail",
  "ts": "2026-10-31T03:21:14.700Z",
  "payload": { "code": 10004, "message": "登录已过期，正在刷新", "retryable": true }
}
```

随后服务端以 `4002`（Token 过期）或 `4001`（认证失败）关闭连接。**手机收到 `10004` 应立即 refresh 并重连一次**；
连续两次失败则跳登录页。

---

## 4. 消息格式

### 4.1 服务端 → 客户端事件信封（必选字段）

```json
{
  "msgId": "01JAV3KAA2B3C4D5E6F7G8H9J1",
  "type": "task.progress",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
  "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
  "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
  "seq": 132,
  "ts": "2026-10-31T03:21:09.500Z",
  "v": 1,
  "payload": { "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9", "progress": 42, "stage": "editing_files", "message": "正在修改 AuthController.java" }
}
```

| 字段 | 类型 | 必选 | 说明 |
| --- | --- | --- | --- |
| `msgId` | string(26) | ✅ | 服务端生成的 ULID；**消息幂等键**（重复投递时客户端去重） |
| `type` | string(48) | ✅ | 事件类型（§6 或 §7 目录） |
| `deviceId` | string(26) | 设备域事件必选 | 事件归属设备；`sys.*` 可为空 |
| `conversationId` | string(26) | 条件必选 | `session.*`、对话相关任务事件必选 |
| `taskId` | string(26) | 条件必选 | `task.*` 必选 |
| `seq` | int64 | ✅ | **每设备单调递增**；断线补偿游标；`sys.*` 帧不带 `seq` |
| `ts` | string(ISO-8601) | ✅ | 事件**发生**时间（非投递时间），用于 UI 排序与超时计算 |
| `v` | int | 可选 | payload schema 版本，缺省 1 |
| `payload` | object | ✅ | 见 §6 各事件 schema |

**为什么序号放在设备通道而不是任务上**：手机同时只关注少量设备，但重连补偿需要「一条连续河道」；
按任务编号会退化为逐任务补偿（N 个游标）。按设备编号只需 1 个游标，且天然覆盖会话/桌面/设备事件。

### 4.2 客户端 → 服务端帧

客户端帧**不带 `seq`**（序号由服务端在自己写事件时分配），带 `msgId` 作为命令幂等键：

```json
{
  "msgId": "01JAV3K9T9U1V2W3X4Y5Z6A7B8",
  "type": "client.command",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
  "ts": "2026-10-31T03:21:30.000Z",
  "payload": { "command": "task.cancel", "params": { "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9", "reason": "user_cancel" } }
}
```

### 4.3 `sys.*` 控制帧一览

| type | 方向 | 用途 | 带 seq |
| --- | --- | --- | --- |
| `sys.auth` | C→S | 首帧认证 | ❌ |
| `sys.auth.ok` / `sys.auth.fail` | S→C | 认证结果 | ❌ |
| `sys.ping` / `sys.pong` | 双向 | 心跳（C→S ping，S→C pong） | ❌ |
| `sys.ack` | C→S | 累计确认已处理到的 `seq` | ❌ |
| `sys.resume` | C→S | 请求回放（通常已随 auth 携带，断线补偿也可单独发） | ❌ |
| `sys.replay.start` / `sys.replay.end` | S→C | 回放批次的起止标记 | ❌ |
| `sys.replay.gap` | S→C | 回放区间已超出保留期，要求全量刷新 | ❌ |
| `sys.resync` | C→S | 检测到 seq 空洞，请求从 `lastSeq` 重放 | ❌ |
| `sys.error` | S→C | 帧级错误（非业务错误） | ❌ |
| `sys.pairing.approved` | S→C | 配对成功，下发设备凭证（仅 pairing 通道） | ❌ |

---

## 5. 可靠性机制

### 5.1 心跳与超时

- **手机**：连接建立后每 25 秒发一次 `sys.ping`；`sys.pong` 带回 `serverTime`，客户端用它计算时钟偏差
  （审批倒计时、任务超时都以服务端时间为准）。
- **Agent**：每 20 秒发 `sys.ping`，`payload` 顺带 Harness 状态（见下），服务端据此更新 `devices.last_online_at`（30 秒节流落库）。
- 服务端 **60 秒**未收到任何帧 → 关闭 `4008`；客户端看到 `4008` 或本地 45 秒无 `pong` → 主动重连。
- 手机进入后台：系统可能挂起连接；回到前台时先做**连接健康检查**（`sys.ping` 超时 3 秒）再决定是否重连，
  避免「假在线」导致用户指令丢失。

```json
{
  "msgId": "01JAV3KAB3C4D5E6F7G8H9J1K2",
  "type": "sys.ping",
  "ts": "2026-10-31T03:22:00.000Z",
  "payload": {
    "client": "agent",
    "lastSeqByDevice": { "01JAV3K8Q9W7M2X4B6C8D0E2F7": 131 },
    "harness": { "running": true, "version": "待探测", "busy": true },
    "metrics": { "cpuPercent": 12.5, "memoryUsedMb": 812, "activeTasks": 1 }
  }
}
```

### 5.2 确认（at-least-once + 客户端去重）

- 服务端对每个事件至少投递一次；客户端**必须**幂等处理（按 `msgId` 去重 + 按 `seq` 单调丢弃旧帧）。
- 客户端处理完一个批次后发累计 `sys.ack`：

```json
{ "msgId": "01JAV3KAC4D5E6F7G8H9J1K2L3", "type": "sys.ack", "ts": "2026-10-31T03:21:10.000Z",
  "payload": { "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "seq": 132 } }
```

- `sys.ack` 是**累计**语义：`seq=132` 表示 ≤132 全部处理完毕。服务端据此清理发送队列与 Redis 中的待确认游标。
- 不 ack 不影响业务（事件已落 `device_events`），只影响实时队列与流量。

### 5.3 重连与断线补偿

连接断开 → 指数退避重连：`1s, 2s, 4s, 8s, 16s, 30s...`（上限 30 秒，±20% 抖动）；连续失败 10 次后
降级为每 60 秒一次。重连成功后：

1. 认证帧携带 `resume.devices[{deviceId, lastSeq}]`；
2. 服务端对每个设备从 `device_events` 读 `seq > lastSeq`，按批推送 `sys.replay.start` → 事件 → `sys.replay.end`；
3. 若 `lastSeq` 早于该设备保留期内的最早 `seq`（分区已归档/删除），回 `sys.replay.gap`；
4. 客户端收到 gap 后走 REST 全量刷新（会话消息、任务列表、事件详情），并把本地游标重置为新值。

```json
{ "msgId": "01JAV3KAD5E6F7G8H9J1K2L3M4", "type": "sys.replay.start", "ts": "2026-10-31T03:21:20.000Z",
  "payload": { "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "fromSeq": 132, "toSeq": 187, "count": 56 } }
```

```json
{ "msgId": "01JAV3KAE6F7G8H9J1K2L3M4N5", "type": "sys.replay.gap", "ts": "2026-10-31T03:21:20.000Z",
  "payload": { "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "requestedFrom": 132, "oldestAvailableSeq": 89442, "action": "full_refresh" } }
```

- 回放限流：每批最多 200 条或 512KB，先到先断；`sys.replay.end` 携带 `replayed` 与 `hasMore`。
- 手机侧本地游标存储：`shared_preferences`/`drift` 表 `device_cursor(deviceId, lastSeq, updatedAt)`，进程重启仍可补偿。

### 5.4 去重与乱序

| 场景 | 处理 |
| --- | --- |
| 同一 `msgId` 重复到达 | 客户端按 `msgId` LRU（保留最近 1000 条）去重后丢弃 |
| `seq <= lastAppliedSeq` | 直接丢弃（旧帧） |
| `seq == lastAppliedSeq + 1` | 正常处理并推进游标 |
| 缺失 `seq`（空洞） | 缓冲最多 **3 秒 / 50 条**；期间若补齐则依次处理，否则清空缓冲、发 `sys.resync{deviceId,lastSeq}` 并等待回放 |
| 服务端乱序 | **不会发生**：单设备事件由同一投递协程串行发送（ADR-PROTO-005）；若发现，视为缺陷并告警 |
| 客户端上行重复命令 | 云端以 `msgId` 为 `device_commands.id` 主键去重；重复即回同一个 `server.command_ack` |

### 5.5 背压

- 服务端每连接维护发送队列；队列 > 512 条且该连接仍是慢消费者时：
  - `task.output` 实时帧可丢弃（事件已落库，客户端重连后可回放补齐）；
  - 状态类事件（`task.created/started/waiting_approval/completed/failed/cancelled`、`device.*`、`desktop.*`）
    **绝不丢弃**；
  - 发送 `sys.error{code:90003, message:"slow consumer"}` 提示客户端。
- Agent 上行：`task.output` 由 Agent 端按 2 秒/4KB 合并后才发（与 DATA_MODEL §8.1 一致），避免打爆云端。

### 5.6 手机端「最后一条消息」一致性

聊天界面的正确性依赖两路数据：WebSocket 实时事件 + REST 历史消息。规则：

1. 进入会话：`GET /messages?limit=30` 拉最新一页并记录 `maxSeqInConversation`；
2. 同时根据本地 `lastSeq` 请求回放；
3. 合并时以 `messages.seq_in_conversation` 去重，**REST 优先**（REST 是落库后的权威数据）；
4. 若某条 `session.message` 的 `seqInConversation` 已存在于 REST 结果，跳过；
5. 流式输出阶段（任务未完成）不写 `messages`，只有 `task.output` 事件；任务完成时才出现 `session.message`
   ——因此**聊天记录里不会出现半截回答**（除非用户取消，那时以 `task.cancelled` 落一条带「已停止」标记的 assistant 消息）。

---

## 6. 事件目录（服务端 → 客户端）

### 6.0 策划案 6.1 对照

| 策划案 6.1 事件 | 本协议类型 | 是否必选 | 备注 |
| --- | --- | --- | --- |
| device.online | `device.online` | ✅ | Agent 连接成功时推送 |
| device.offline | `device.offline` | ✅ | 断连/心跳超时/撤销 |
| task.created | `task.created` | ✅ | |
| task.started | `task.started` | ✅ | |
| task.progress | `task.progress` | ✅ | |
| task.output | `task.output` | ✅ | 流式增量，2 秒合并 |
| task.waiting_approval | `task.waiting_approval` | ✅ | 需配合 §8 |
| task.completed | `task.completed` | ✅ | |
| task.failed | `task.failed` | ✅ | |
| task.cancelled | `task.cancelled` | ✅ | 含 `harnessAck` |
| session.message | `session.message` | ✅ | 一轮对话完成后 |
| desktop.connected | `desktop.connected` | ✅ | |
| desktop.disconnected | `desktop.disconnected` | ✅ | |
| — | `approval.requested` / `approval.decided` | 扩展 | 审批 UI 需要独立事件 |
| — | `device.emergency_stopped` / `device.revoked` / `device.capabilities_updated` | 扩展 | 安全与控制 |
| — | `file.transfer_ready` / `file.transfer_completed` | 扩展 | 文件中继 |

> 客户端**必须**对未知 `type` 做容错：记录日志 + 上报（不弹错、不断连）。扩展事件是协议演进的唯一手段。

### 6.1 `device.online`

```json
{
  "msgId": "01JAV3KAF7G8H9J1K2L3M4N5P6", "type": "device.online",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "seq": 1, "ts": "2026-10-31T02:00:00.000Z",
  "payload": {
    "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
    "deviceName": "书房的电脑",
    "onlineAt": "2026-10-31T02:00:00.000Z",
    "agentVersion": "0.4.1",
    "harness": { "running": true, "version": "待探测" },
    "capabilities": { "chat": true, "streaming": true, "cancel": true, "desktopCapture": true, "desktopInput": false, "fileWrite": true, "terminal": false }
  }
}
```

### 6.2 `device.offline`

```json
{
  "msgId": "01JAV3KAG8H9J1K2L3M4N5P6Q7", "type": "device.offline",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "seq": 2, "ts": "2026-10-31T02:05:00.000Z",
  "payload": {
    "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
    "offlineAt": "2026-10-31T02:05:00.000Z",
    "lastOnlineAt": "2026-10-31T02:00:00.000Z",
    "reason": "heartbeat_timeout"
  }
}
```

`reason` 枚举：`heartbeat_timeout` | `connection_closed` | `user_disconnect` | `agent_shutdown` | `revoked`。
**离线不等于失败**：正在执行的任务若 Agent 持续断连，云端在 90 秒后把任务置 `failed`（`errorCode=30002`），
并在 `task.failed.payload.reason="device_lost"` 中说明（手机端显示「电脑掉线，任务中断」而不是「执行失败」）。

### 6.3 `task.created`

```json
{
  "msgId": "01JAV3KAH9J1K2L3M4N5P6Q7R8", "type": "task.created",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
  "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9", "seq": 3, "ts": "2026-10-31T03:20:31.000Z",
  "payload": {
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "taskName": "重构登录模块为 JWT 校验",
    "taskType": "code_analysis",
    "taskStatus": "queued",
    "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
    "permissionLevel": 2,
    "createdAt": "2026-10-31T03:20:31.000Z"
  }
}
```

### 6.4 `task.started`

```json
{
  "msgId": "01JAV3KAI1K2L3M4N5P6Q7R8S9", "type": "task.started",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
  "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9", "seq": 4, "ts": "2026-10-31T03:20:35.000Z",
  "payload": {
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "taskStatus": "running",
    "startedAt": "2026-10-31T03:20:35.000Z",
    "harnessTaskRef": null
  }
}
```

`harnessTaskRef`：Harness 侧可引用的任务/会话标识，若无（CLI 一次性进程）则为 `null`——**不编造**。

### 6.5 `task.progress`

```json
{
  "msgId": "01JAV3KAJ2L3M4N5P6Q7R8S9T1", "type": "task.progress",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
  "seq": 5, "ts": "2026-10-31T03:20:40.000Z",
  "payload": {
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "progress": 42,
    "stage": "editing_files",
    "message": "正在修改 AuthController.java"
  }
}
```

进度为**估算值**（无法从 CLI 拿到真实百分比时，Agent 用阶段权重推进：收到首个输出 10、每 N 字节 +5、收尾 95），
必须标注为估算，不允许伪造精确进度。`stage` 枚举由 Agent 定义（`connecting`/`thinking`/`editing_files`/`running_tests`/`finalizing`）。

### 6.6 `task.output`

```json
{
  "msgId": "01JAV3KAK3M4N5P6Q7R8S9T1U2", "type": "task.output",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
  "seq": 6, "ts": "2026-10-31T03:20:42.000Z",
  "payload": {
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "stream": "answer",
    "delta": "已定位到 AuthController.java 的登录逻辑，准备改为 JWT 校验。\n",
    "offset": 0,
    "contentType": "text/markdown"
  }
}
```

| 字段 | 说明 |
| --- | --- |
| `stream` | `answer`（给用户看的回答）/ `stdout`（命令输出）/ `stderr` / `log`（Agent 内部日志） |
| `delta` | 增量文本，允许为空字符串（心跳式占位） |
| `offset` | `delta` 在**该 stream 全文**中的起始字符偏移；客户端按 offset 拼接，缺失即判定空洞 |
| `contentType` | `text/plain` / `text/markdown` / `application/json`（`stream=stdout` 时常为 plain） |

合并规则：Agent 每 2 秒或 4KB 合并一次；`offset` 必须连续（丢帧不应导致 offset 跳变，若跳变客户端请求回放）。

### 6.7 `task.waiting_approval`

```json
{
  "msgId": "01JAV3KAL4N5P6Q7R8S9T1U2V3", "type": "task.waiting_approval",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
  "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9", "seq": 7, "ts": "2026-10-31T03:20:50.000Z",
  "payload": {
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "approvalId": "01JAV3K8Q9W7M2X4B6C8D0E2FF",
    "source": "preflight_rule",
    "approvalType": "terminal_command",
    "permissionLevel": 4,
    "riskLevel": "critical",
    "actionSummary": "执行命令：del /s /q D:\\work\\proj-a\\dist",
    "payload": {
      "tool": "terminal",
      "rawInput": { "command": "del /s /q D:\\work\\proj-a\\dist" },
      "workspacePath": "D:\\work\\proj-a"
    },
    "options": [
      { "optionId": "allow-once", "label": "允许本次", "kind": "allow_once" },
      { "optionId": "reject-once", "label": "拒绝", "kind": "reject_once" }
    ],
    "expiresAt": "2026-10-31T03:22:50.000Z"
  }
}
```

- `source=preflight_rule`：任务开始前由 RiskEngine 拦截（此时**指令未下发**）；`source=acp_permission`：执行中被 ACP
  `session/request_permission` 拦截（此时**工具尚未执行**，会额外带 `toolCallId`）。
- **没有「记住本次选择」**：ACP 只提供 `allow-once` / `reject-once`，不存在 allow-always；`options` 恒为这两项，
  手机端不得渲染「本任务内不再询问」。

### 6.8 `task.completed`

```json
{
  "msgId": "01JAV3KAM5P6Q7R8S9T1U2V3W4", "type": "task.completed",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
  "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9", "seq": 8, "ts": "2026-10-31T03:21:18.000Z",
  "payload": {
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "taskStatus": "completed",
    "finishedAt": "2026-10-31T03:21:18.000Z",
    "durationMs": 43000,
    "progress": 100,
    "result": {
      "summary": "已将登录校验改为 JWT，并补充 6 个单元测试，全部通过。",
      "files": [
        { "path": "src/main/java/com/example/security/JwtFilter.java", "change": "created" },
        { "path": "src/main/java/com/example/web/AuthController.java", "change": "modified" }
      ],
      "messageId": "01JAV3K8Q9W7M2X4B6C8D0E2FC"
    }
  }
}
```

`result.files` 是**引用**（路径 + 变更类型），不是文件内容；下载需走文件接口。

### 6.9 `task.failed`

```json
{
  "msgId": "01JAV3KAN6Q7R8S9T1U2V3W4X5", "type": "task.failed",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
  "seq": 9, "ts": "2026-10-31T03:22:00.000Z",
  "payload": {
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "taskStatus": "failed",
    "finishedAt": "2026-10-31T03:22:00.000Z",
    "errorCode": "50005",
    "errorMessage": "Harness 当前版本不支持取消，任务已中断",
    "reason": "harness_error",
    "retryable": false
  }
}
```

`reason` 枚举：`harness_error` | `device_lost` | `approval_denied` | `approval_timeout` | `timeout` | `internal` | `capability_unsupported`。

### 6.10 `task.cancelled`

```json
{
  "msgId": "01JAV3KAO7R8S9T1U2V3W4X5Y6", "type": "task.cancelled",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
  "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9", "seq": 10, "ts": "2026-10-31T03:21:31.000Z",
  "payload": {
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "taskStatus": "cancelled",
    "cancelledAt": "2026-10-31T03:21:31.000Z",
    "reason": "user_cancel",
    "harnessAck": true,
    "cancelledAtOffset": 2048
  }
}
```

- `harnessAck=true`：Harness 确认已中止；`false`：Agent 仅停止采纳输出（真实进程可能仍在跑，UI 必须区分）。
- `cancelledAtOffset`：取消时刻已输出到的字符偏移，Agent 用它把「半截回答」落成一条带「已停止」标记的消息。

### 6.11 `session.message`

```json
{
  "msgId": "01JAV3KAP8S9T1U2V3W4X5Y6Z7", "type": "session.message",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
  "seq": 11, "ts": "2026-10-31T03:21:18.500Z",
  "payload": {
    "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
    "messageId": "01JAV3K8Q9W7M2X4B6C8D0E2FC",
    "role": "assistant",
    "content": "已将登录校验改为 JWT……",
    "contentType": "markdown",
    "seqInConversation": 2,
    "clientMsgId": null,
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "createdAt": "2026-10-31T03:21:18.500Z"
  }
}
```

### 6.12 `desktop.connected` / `desktop.disconnected`

```json
{
  "msgId": "01JAV3KAQ9T1U2V3W4X5Y6Z7A8", "type": "desktop.connected",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "seq": 12, "ts": "2026-10-31T03:30:00.000Z",
  "payload": {
    "sessionId": "01JAV3KAR1U2V3W4X5Y6Z7A8B9",
    "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
    "mode": "view",
    "transport": "wss_media",
    "startedAt": "2026-10-31T03:30:00.000Z",
    "resolution": { "width": 1920, "height": 1080, "scaleFactor": 1.0 },
    "fps": 12,
    "codec": "h264",
    "targetBitrateKbps": 2500,
    "inputEnabled": false
  }
}
```

```json
{
  "msgId": "01JAV3KAS2V3W4X5Y6Z7A8B9C1", "type": "desktop.disconnected",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7", "seq": 48, "ts": "2026-10-31T03:40:00.000Z",
  "payload": {
    "sessionId": "01JAV3KAR1U2V3W4X5Y6Z7A8B9",
    "endedAt": "2026-10-31T03:40:00.000Z",
    "endReason": "user_stop",
    "bytesSent": 48231424,
    "framesDropped": 132
  }
}
```

`endReason`：`user_stop` | `agent_stop` | `estop` | `timeout` | `error` | `device_offline`。

### 6.13 扩展事件

| type | payload 要点 |
| --- | --- |
| `approval.requested` | `{approvalId, taskId, source, toolCallId?, approvalType, permissionLevel, riskLevel, actionSummary, payload, options, expiresAt}`（供任务中心红点/通知；`source=acp_permission` 时任务状态仍为 `running`） |
| `approval.decided` | `{approvalId, status:"approved"|"denied"|"expired", decidedVia, decidedAt}` |
| `device.emergency_stopped` | `{deviceId, stoppedAt, stoppedBy:"app"|"agent_local"|"server", cancelledTaskIds:[...], desktopSessionClosed:true}` |
| `device.revoked` | `{deviceId, revokedAt, reason}`（只发给被撤销设备的 Agent 与其他在线手机） |
| `device.capabilities_updated` | `{deviceId, capabilities:{...}, harness:{running,version}}` |
| `file.transfer_ready` | `{fileId, direction, fileName, sizeBytes, sha256, relativePath, expiresAt}` |
| `file.transfer_completed` | `{fileId, direction, state:"written"|"downloaded"|"failed", errorCode}` |
| `sys.pairing.approved` | 仅配对通道：`{deviceId, deviceToken, pairedAt}` |

---

## 7. 下行命令（手机 → 云端 → Agent）

### 7.1 命令信封

手机发出（`client.command`）→ 云端校验权限/归属/审批 → 转为（`server.command`）→ Agent 执行 → 回 `server.command_ack`。

```json
{
  "msgId": "01JAV3KAT3W4X5Y6Z7A8B9C1D2",
  "type": "client.command",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
  "ts": "2026-10-31T03:20:31.000Z",
  "payload": {
    "command": "task.create",
    "params": { "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9" },
    "permissionLevel": 2,
    "approvalId": null
  }
}
```

```json
{
  "msgId": "01JAV3KAU4X5Y6Z7A8B9C1D2E3",
  "type": "server.command",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
  "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
  "ts": "2026-10-31T03:20:31.050Z",
  "payload": {
    "command": "task.create",
    "commandId": "01JAV3KAT3W4X5Y6Z7A8B9C1D2",
    "params": {
      "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
      "conversationId": "01JAV3K8Q9W7M2X4B6C8D0E2F8",
      "taskType": "code_analysis",
      "prompt": "帮我把登录模块改成 JWT 校验，并补充单元测试",
      "workspacePath": "D:\\work\\proj-a",
      "attachments": [],
      "options": { "timeoutSec": 900 }
    },
    "approvalTicket": null,
    "deadlineAt": "2026-10-31T03:20:41.050Z"
  }
}
```

```json
{
  "msgId": "01JAV3KAV5Y6Z7A8B9C1D2E3F4",
  "type": "server.command_ack",
  "deviceId": "01JAV3K8Q9W7M2X4B6C8D0E2F7",
  "ts": "2026-10-31T03:20:31.120Z",
  "payload": {
    "commandId": "01JAV3KAT3W4X5Y6Z7A8B9C1D2",
    "accepted": true,
    "taskId": "01JAV3K8Q9W7M2X4B6C8D0E2F9",
    "reasonCode": null,
    "message": null
  }
}
```

拒绝时 `accepted:false` + `reasonCode`（如 `50005 CAPABILITY_UNSUPPORTED`），云端据此把任务置 `failed` 并推 `task.failed`。

### 7.2 命令目录

| command | 方向 | 最低权限 | 参数 | 关键结果事件 | ack 超时 |
| --- | --- | --- | --- | --- | --- |
| `task.create` | C→A | L2（按 taskType 升至 L3/L4/L5） | `taskId, conversationId, taskType, prompt, workspacePath?, attachments[], options{timeoutSec}, approvalTicket?` | `task.started` → `task.output` → `task.completed`/`failed` | 10s |
| `task.cancel` | C→A | L2 | `taskId, reason` | `task.cancelled` | 5s |
| `task.continue` | C→A | L2 | `taskId, message, clientMsgId` | 同 `task.create` 后续 | 10s |
| `task.pause` / `task.resume` | C→A | L2 | `taskId` | `task.progress{stage:"paused"}` | 5s |
| `approval.ticket` | C→A | —（仅云端生成） | `approvalId, actionHash, ticket, expiresAt` | `task.started`（继续）/`task.failed` | 5s |
| `file.fetch` | C→A | L3 | `fileId, downloadUrl, relativePath, workspacePermissionId, sha256, sizeBytes` | `file.transfer_completed` | 10s |
| `file.push` | C→A | L3 | `fileId, uploadUrl, relativePath, workspacePermissionId` | `file.transfer_completed` | 10s |
| `desktop.start` | C→A | L5 | `sessionId, mode:"view"|"control", maxFps, quality, codec?("h264"|"mjpeg",默认 h264)` | `desktop.connected` + 媒体帧 | 10s |
| `desktop.stop` | C→A | L5 | `sessionId, reason` | `desktop.disconnected` | 5s |
| `desktop.input` | C→A | L5 | `sessionId, events[{type,x,y,button,key,delta}]` | 无（失败用 `sys.error`） | 不适用（UDP 式，允许丢） |
| `emergency.stop` | C→A | L1（**免审批**） | `scope:"all", reason` | `device.emergency_stopped` | 3s |
| `rpc` | C→A | 视 method | `requestId, method, params` | `server.response` | 10s |

`rpc` 只读方法白名单：`workspace.list`、`workspace.git`、`device.status.probe`、`file.checksum`。写操作一律建模为 task。

### 7.3 远程桌面媒体帧（独立于 JSON 事件流）

- 通道：**同一条 WSS 连接上的二进制帧**，首字节为帧类型：
  - `0x01` 视频关键帧（**H.264 IDR**；MJPEG 降级档时为完整 JPEG）`[type(1)][codec(1)][sessionIdHash(4)][frameIndex(4)][timestampMs(8)][payload]`
  - `0x02` 视频增量帧（H.264 P/B 帧；MJPEG 档不使用）
  - `0x03` 输入事件回执
- **编码默认 H.264**（`h264_nvenc` 优先、`libx264` 兜底），`codec` 字节：`1=H.264`、`2=MJPEG`；MJPEG 仅局域网/演示降级档（实测 1280 宽 10fps 已约 13.3 Mbps，公网不可接受；H.264 约 1.8–3.0 Mbps，见 [ENVIRONMENT_REPORT.md](../research/ENVIRONMENT_REPORT.md) §5.4）。
- 手机端收到 `desktop.connected` 后开始接收；每 5 秒发 `desktop.input` 之外的控制帧 `desktop.stats`（可选）；
- 关键帧请求：`client.command{command:"desktop.request_keyframe"}`（允许丢包后快速恢复）；
- 带宽自适应：Agent 依据 1 秒内未发送成功的字节数降级，顺序为 **码率 → 帧率 → 分辨率 → 最后才切 MJPEG**；手机端可显式指定 `quality: "low"|"auto"|"high"`（目标码率 1/2.5/4 Mbps），`desktop.start.codec` 可强制 MJPEG 用于局域网演示。
- 输入控制必须由 `desktop.start{mode:"control"}` 打开，且 `desktop_sessions.mode='control'` 落库；
  `mode:"view"` 下 Agent **忽略**一切 `desktop.input`（这是策划案 4.3「屏幕共享和输入控制分别授权」的落点）。

---

## 8. 审批（六级权限）在协议中的完整链路

这是产品差异点，单独展开。目标：**高风险操作在执行前必须被手机上的人明确确认，且确认不可伪造、不可重放、超时即失效。**

### 8.1 两次审批时机（ADR-PROTO-009 修订，已被 HARNESS_INTERFACES 实测确认）

| 路线 | 拦截时机 | 可行性（本机实测） | 说明 |
| --- | --- | --- | --- |
| **in-flight（主路线）** | Harness 执行中、危险工具调用**真正执行前** | ✅ ACP `session/request_permission` 实测：allow-once 批准后工具才执行并写文件 | Agent 收到 permission 请求 → 云部落 `approvals` → 手机确认 → 下发一次性 ticket → Agent 回 `optionId=allow-once`。**只有 allow-once / reject-once 两个选项，没有 allow-always** |
| **pre-flight（兜底）** | Agent 调用 Harness **之前** | ✅ 不依赖任何 Harness 能力 | 用本地风险规则对 `task.create` 的 prompt/命令/目标路径做静态判定，命中高风险先审批再执行；**headless 模式下这是唯一形态** |
| **输出监控（事后）** | 执行中输出命中危险模式 | ✅ 不依赖 Harness | 只告警 + 审计，**不作为审批**（`sys.error 70005`） |

**结论**：ACP 可用时审批走 **in-flight 动作级**（拦截真实工具调用），pre-flight 作为纵深兜底；headless 降级时必须由手机端
明确显示「当前接入方式无法执行中确认」，**不得在 UI 上承诺运行中拦截**。两种模式的共同底线：**超时一律按拒绝（回 `cancelled`），绝不默认同意**；
**拒绝回 `reject-once`，且不得把「用户拒绝」写成「任务失败」**——实测拒绝后任务仍以 `stopReason=end_turn` 结束。

### 8.2 协议时序

```mermaid
sequenceDiagram
    autonumber
    participant ACP as dsh --profile acp（Harness）
    participant Agent as 电脑 Agent
    participant Api as 云端
    participant Phone as 手机 App
    ACP->>Agent: session/update tool_call(status=in_progress, rawInput=完整命令)
    ACP->>Agent: session/request_permission {toolCall:{toolCallId}, options:[allow-once,reject-once]}
    Agent->>Agent: 风险规则复核（白名单/权限级别/参数越界直接拒绝）
    Agent->>Api: WSS server.approval_request approvalType actionHash actionSummary payload(toolCallId/rawInput)
    Api->>Api: 写入 approvals 状态 pending 生成 approvalId
    Api-->>Phone: WSS task.waiting_approval 与 approval.requested
    Phone->>Phone: 展示工具名/真实命令/路径 要求生物识别确认
    Phone->>Api: POST /api/approvals/id/decide decision approve verifiedBy biometric
    Api->>Api: 校验归属 未过期 未消费 生成一次性 ticket
    Api->>Agent: WSS server.command approval.ticket approvalId actionHash ticket expiresAt
    Agent->>Agent: 校验 actionHash 与 toolCallId 绑定一致 且 ticket 未过期
    Agent->>ACP: result.outcome=selected optionId=allow-once
    ACP->>ACP: 工具执行（此刻才真正执行）
    Agent->>Api: WSS approval.consumed 与 task.output
    Api-->>Phone: WSS approval.decided status consumed 任务继续
    opt 手机拒绝 / 120 秒超时 / 手机离线
        Agent->>ACP: outcome=selected optionId=reject-once（超时回 outcome=cancelled）
        ACP-->>Agent: tool_call_update status=failed（用户拒绝说明），turn 仍以 end_turn 结束
        Agent->>Api: WSS approval.decided status denied/expired；任务终态按真实 stopReason 上报
    end
```

### 8.3 规则

1. **actionHash**：`SHA-256(规范化 JSON{taskId, actionType, targets[], params, toolCallId})`（in-flight 必含 `toolCallId`，
   否则同一任务内两个同类动作会争用同一张票）。云端与 Agent 用**同一套规范化规则**（键排序、路径统一小写、去除空白），
   否则票据永远校验失败。实现前先写契约测试。
2. **一次性**：`approvals.status` 从 `approved` → `consumed`；Agent 本地也记录已消费 `approvalId` + `toolCallId`（防云端重复下发、
   防同一工具调用被二次放行）。
3. **超时**：`expires_at = requested_at + 120s`。超时后云端置 `expired`，推 `approval.decided{status:"expired"}`，
   并向 Agent 下 `approval.ticket{cancelled:true}` 或直接由 Agent 回 `outcome=cancelled`；手机端显示「确认超时，动作未执行」。
   **任务不因审批超时被伪装成「执行失败」**：ACP 下 Agent 会停止解释、turn 通常仍 `end_turn`，任务终态按真实 `stopReason` 上报。
4. **拒绝**：手机 `decision:"deny"` → 云端置 `denied`，通知 Agent 回 `optionId=reject-once`，工具不执行、模型收到拒绝并停止解释；
   任务按真实结果上报（通常 `completed` 且附「因用户拒绝未执行 X」，**不是** `failed{70003}`）。
   `pre-flight` 路线下拒绝才是「任务未启动 → `failed{errorCode:70003}`」。
5. **防重放**：ticket 为 32 字节随机串，云端只存哈希；Agent 只接受 `commandId` 未见过且 `actionHash` 匹配 **且 `toolCallId`
   与当前 permission 请求一致**的票据。
6. **手机侧二次验证**：`verifiedBy` 取 `pin`/`biometric`；Flutter 用 `local_auth` 拉起系统验证，失败 3 次要求重新登录。
   服务端无法校验生物识别，因此**审批的有效性边界是「手机未丢失、被解锁、用户在场」**——这条写进安全假设，不隐瞒。
7. **审计**：`audit_logs` 记 `approval.request`（Agent 上报时）、`approval.decide`（手机决定时）、
   `approval.consume`（Agent 回传 optionId 时）三行，`severity='critical'`，保留 180 天以上；
   `payload` 中必须含 `source`（`acp_permission`/`preflight_rule`）、`toolCallId`、`optionKind`、`verifiedBy`。

### 8.4 高风险动作清单（与策划案 7.3 对齐，Agent 本地规则库）

| 类别 | 判定信号（pre-flight） | approval_type | risk_level |
| --- | --- | --- | --- |
| 删除文件 | 指令含 `del`/`rm`/`Remove-Item`/`rmdir` 或 Harness 计划删除 | `file_delete` | critical |
| 覆盖文件 | 目标文件已存在且命令为写操作 | `file_overwrite` | high |
| 批量修改 | 单任务涉及文件数 > 10 | `high_risk_operation` | high |
| 高风险命令 | 命中命令白名单外 / 含 `format`、`diskpart`、`reg add`、`shutdown`、`netsh` | `terminal_command` | critical |
| 修改系统配置 | 目标路径在 `%WINDIR%`、`Program Files`、注册表 | `system_config` | critical |
| 安装软件 | 指令含 `winget install`/`choco install`/`msiexec` | `install_software` | high |
| 访问未授权目录 | realpath 不在任何 `workspace_permissions` 前缀内 | `unlisted_directory` | critical |
| 首次远程桌面控制 | `desktop.start{mode:"control"}` 且该设备未授权过 | `desktop_control` | medium |

> 规则库尽量保守（宁可多问）。**误报代价是一次点击，漏报代价是数据丢失。**

---

## 9. 紧急停止（Emergency Stop）

### 9.1 触发源（三处，任意一处生效即全局生效）

| 触发源 | 机制 | 强制度 |
| --- | --- | --- |
| 手机 App | `client.command{command:"emergency.stop"}`（**最高优先级，跳过队列**，免审批） | 必选 |
| 电脑本地 UI | Agent 托盘/窗口红色按钮；全局热键 `Ctrl+Alt+Shift+F12` | 必选 |
| 服务端风控 | 检测异常（如 1 分钟内 100 次高风险审批）自动触发 | P2 |

### 9.2 状态语义

- `devices.remote_enabled=false` + `devices.emergency_stopped_at=now()`；
- 云端拒绝该设备**一切**新的 `client.command`（`emergency.stop` 与 `device.revoke` 除外）→ `403 30006 DEVICE_REMOTE_DISABLED`；
- Agent 本地也有独立 `ESTOP` 标志（**本地权威**，即使云端被打穿也不能恢复远程能力）；
- 解除：**只能在电脑本地**操作（本地 UI 按钮 + 本地 PIN/Windows Hello），恢复后写审计 `emergency.resume`；
- 重启 Agent 进程不清除 ESTOP（持久化在 DPAPI 保护的配置中），必须显式本地解除。

### 9.3 停止时的动作链（顺序不可颠倒）

```mermaid
sequenceDiagram
    autonumber
    participant Phone as 手机 App
    participant Api as 云端
    participant Agent as 电脑 Agent
    participant DSH as Harness 进程
    Phone->>Api: client.command emergency.stop scope all
    Api->>Api: devices.remote_enabled=false 写审计 critical
    Api->>Agent: server.command emergency.stop 最高优先级
    Agent->>Agent: 置本地 ESTOP 标志 拒绝后续所有远程指令
    Agent->>DSH: 终止当前任务 或 停止采纳输出
    Agent->>Agent: 断开桌面输入通道 关闭桌面会话
    Agent->>Api: device.emergency_stopped 事件
    Api-->>Phone: WSS device.emergency_stopped 并更新任务为 cancelled
    Phone->>Phone: UI 全屏红色状态 提示只能电脑本地恢复
```

细节：

1. 先置标志（防止停止过程中又有新指令进来），再中断执行，最后回收资源——顺序颠倒会留下竞态窗口；
2. 正在执行的任务：`cancel_requested_at=now()` → Agent 尝试 `cancelTask`；若无能力则 kill 子进程（CLI headless 场景
   `SIGTERM` → 5 秒后 `SIGKILL`），任务置 `cancelled`，`harnessAck` 如实填写；
3. 桌面会话：立即停止采集、丢弃输入队列、`desktop_sessions` 置 `ended`，`end_reason='estop'`；
4. 审批票据：所有 `pending` 审批置 `expired`，不再下发；
5. 审计：`action_type='emergency.stop'`，`severity='critical'`，含触发源与受影响任务列表；
6. 手机端 UI 保持红色「已停止」态直到电脑本地恢复；期间禁止显示「重试」按钮误导用户。

---

## 10. 端到端时序图

### 10.1 手机指令 → 云端 → Agent → Harness → 流式回传

```mermaid
sequenceDiagram
    autonumber
    participant Phone as 手机 App
    participant Api as 云端 Java
    participant Agent as 电脑 Agent
    participant CLI as dsh --profile acp 常驻进程
    Phone->>Api: POST /api/tasks 幂等键 创建任务
    Api->>Api: 鉴权 权限判定 写 tasks queued 与 outbox
    Api-->>Phone: 200 taskId queued
    Api->>Agent: WSS server.command task.create
    Agent->>Agent: pre-flight 风险预检 无高风险 入队占并发槽
    Agent-->>Api: server.command_ack accepted
    Agent-->>Api: WSS 事件 task.started
    Api-->>Phone: WSS 事件 task.started
    Agent->>CLI: session/new {cwd} → sessionId
    Agent->>CLI: session/prompt（sessionId）
    loop 步骤级事件 2 秒或 4KB 合并（非逐 token）
        CLI-->>Agent: agent_message_chunk / tool_call / usage_update
        Agent-->>Api: WSS 事件 task.output delta offset
        Api->>Api: 写 device_events 分配 seq
        Api-->>Phone: WSS 事件 task.output seq
    end
    CLI-->>Agent: stopReason=end_turn
    Agent->>Agent: git 快照对比 得出变更文件列表
    Agent-->>Api: WSS 事件 task.completed
    Api->>Api: 更新 tasks completed 写 messages 会话消息
    Api-->>Phone: WSS task.completed 与 session.message
    Phone->>Api: sys.ack 累计确认 seq
```

> 图中「步骤级事件」是**实测事实**：ACP `agent_message_chunk` 为提交点粒度（250 字中文回答只产生 1 个 chunk，常在 turn 末到达），
> 因此协议上的 `task.output` 是「步骤级实时 + 2 秒/4KB 合并」，**不承诺逐 token 流式**；token 级只有 B 路线 Host 插件桥具备
> （见 REMOTE_AGENT ADR-AGENT-013）。手机端按「每步/每工具完成即刷新」呈现。

### 10.2 取消任务

```mermaid
sequenceDiagram
    autonumber
    participant Phone as 手机 App
    participant Api as 云端
    participant Agent as 电脑 Agent
    participant CLI as dsh --profile acp
    Phone->>Api: POST /api/tasks/id/cancel
    Api->>Api: cancel_requested_at=now 写审计
    Api-->>Phone: 200 cancelRequested true
    Api->>Agent: WSS server.command task.cancel
    Agent->>CLI: session/cancel（ACP 原生取消）
    alt 10 秒内返回 stopReason=cancelled（实测 2.5s）
        Agent-->>Api: task.cancelled harnessAck true
    else 超时 / 进程异常
        Agent->>CLI: kill 整个 ACP 进程（连带所有 session）
        Agent-->>Api: task.cancelled harnessAck false
    end
    Api-->>Phone: WSS task.cancelled
    Phone->>Phone: 停止渲染并显示已取消 或 部分停止提示
```

取消是**安全操作**：即使设备离线，云端也保留 `cancel_requested_at` 并在 Agent 重连后补发（§2.13）。

### 10.3 断网恢复

```mermaid
sequenceDiagram
    autonumber
    participant Phone as 手机 App
    participant Api as 云端
    participant Agent as 电脑 Agent
    Note over Phone: 网络中断 期间任务继续执行
    Agent-->>Api: WSS 事件持续写入 device_events 含 seq 1 到 42
    Phone->>Phone: 本地游标停在 seq 17
    Phone->>Api: TCP 断开 指数退避重连
    Phone->>Api: 新连接 sys.auth 携带 resume lastSeq 17
    Api->>Api: 查询 device_events seq 大于 17
    Api-->>Phone: sys.replay.start fromSeq 18 toSeq 42 count 25
    Api-->>Phone: 重放 task.progress 与 task.output 事件
    Api-->>Phone: sys.replay.end
    Phone->>Phone: 按 seq 去重 合并本地状态
    Phone->>Api: sys.ack seq 42
    Phone->>Api: GET /api/tasks/id 校验最终状态 兜底
```

若中断超过 30 天（分区已归档）：

```mermaid
sequenceDiagram
    participant Phone as 手机 App
    participant Api as 云端
    Phone->>Api: sys.auth resume lastSeq 17
    Api-->>Phone: sys.replay.gap oldestAvailableSeq 89442
    Phone->>Api: GET /api/tasks 与 GET /api/conversations/id/messages 全量刷新
    Phone->>Phone: 重置本地游标为刷新结果的最大 seq
```

---

## 11. 版本演进与兼容性

| 变更类型 | 规则 |
| --- | --- |
| 新增可选字段 | 允许，客户端忽略未知字段 |
| 新增枚举值 | 允许，客户端必须有 default 分支（按「未知」展示，不得崩溃） |
| 新增事件类型 | 允许，客户端忽略并上报 |
| 删除/改名字段或事件 | **禁止**，只能标记 `deprecated` 并在下一个大版本移除 |
| 修改字段语义 | **禁止**，必须新字段 + 双写过渡 |
| -breaking 变更 | 升 `dsremote.v2` / `/api/v2`，服务端并行支持 v1 ≥ 6 个月 |
| 废弃流程 | 响应头 `Deprecation: true` + `Sunset: <HTTP-date>`；提前 3 个月公告 |

- 客户端在 `sys.auth.payload.protocolVersion` 上报版本；服务端 `sys.auth.ok.features` 下发能力开关，
  手机端据此隐藏不可用功能（例如 Harness 不支持取消时，不显示「取消」按钮而是「停止采纳输出」，文案见 MOBILE_UI §5）。
- 服务端拒绝过旧客户端：`10008 UNSUPPORTED_CLIENT_VERSION`（HTTP 426）。

---

## 12. 待验证项（Harness 相关，一律不编造）

| 编号 | 待验证问题 | 影响协议处 | 当前处理 | 依据来源（2026-10-31） |
| --- | --- | --- | --- | --- |
| H-01 | ACP / headless 的输出契约、退出码、结构化结果 | `task.output`/`task.completed.result`/`50004` | ✅ ACP 事件与 stopReason 已实测；headless `--json` NDJSON 已实测；`result` 以文本 + git 快照为准 | HARNESS_INTERFACES §2–§3/§7.1【实测】 |
| H-02 | 是否支持**流式增量**输出 | `task.output` 的 delta 语义、进度估算 | ✅ 只有步骤级：ACP `agent_message_chunk` 为提交点粒度（250 字→1 chunk）；协议按「步骤级实时 + 2s/4KB 合并」，不承诺逐 token | HARNESS_INTERFACES §7.1【实测】 |
| H-03 | 是否支持多轮会话、会话标识能否外部引用 | `conversations.harness_session_id`、`session.message` | ✅ ACP `session/list`/`resume`/同 sessionId 续 prompt 实测；`harness_session_id` 为 ACP 裸 UUID；headless 可用 `--session-id` | HARNESS_INTERFACES §7.1【实测】 |
| H-04 | 是否可编程取消正在执行的任务 | `task.cancel`、`harnessAck` | ✅ ACP `session/cancel` 实测 2.5s 回 `stopReason=cancelled`；headless 只能 kill | HARNESS_INTERFACES §7.1【实测】 |
| H-05 | 是否有钩子可在执行中拦截危险动作 | 审批 in-flight 路线 | ✅ ACP `session/request_permission` 实测 allow-once 后工具才执行；headless 无审批通道 | HARNESS_INTERFACES §7.1【实测+源码】 |
| H-06 | 是否能列举 workspace/读写文件（官方接口而非文件系统直读） | `/api/workspaces*`、`file.*` | ✅ 已确认 Harness **无** `fs/*` 客户端方法；`/api/workspaces*` 由 Agent 本地 fs 实现（能力矩阵标「本地文件系统」） | HARNESS_INTERFACES §7.1【源码】 |
| H-07 | 同一台机器能否并发多个调用、是否共享登录态 | 单设备并发上限、`rate limit` | ✅ 单 ACP 进程可并发多 session（同 session prompt 串行）；`server.command` 层仍按设备串行入队、队列 10 | HARNESS_INTERFACES §7.1【实测】 |
| H-08 | 62492 端口仅为 loopback，是否有可复用的本地 HTTP API | 云端直连 Harness 的可行性 | ✅ 不是接入面（端口随机、token+cookie 栅栏、协议无文档）；必须经 Agent | HARNESS_INTERFACES §1【实测+源码】 |
| H-09 | 屏幕采集与编码方案（ffmpeg gdigrab / Windows Graphics Capture） | `desktop.*` 媒体帧 | ⚠️ **Windows 已实测**：gdigrab 抓屏 2560×1600 + H.264/NVENC/MJPEG 出帧，MJPEG 约 13.3 Mbps 不可用 → 定 H.264 为主（约 1.8–3.0 Mbps，[ENVIRONMENT_REPORT.md](../research/ENVIRONMENT_REPORT.md) §5.4）；macOS/Linux 未验证 | REMOTE_AGENT §2.6 |
| H-13 | ACP per-session 权限 preset 能否按任务限权 | 六级权限的本地复核粒度 | ⚠️ 未验证；当前由 Agent PermissionGate 兜底 | HARNESS_INTERFACES §7.1【未验证】 |
| H-14 | 跨进程同时 live 同一 session 的冲突语义 | `device_lost` 后 resume 行为 | ⚠️ 未验证；协议层按「云端权威 + 不自动恢复旧 session」处理 | HARNESS_INTERFACES §7.1【未验证】 |

---

## 13. ADR 索引（协议相关）

| ADR | 决策 | 理由 | 替代方案与代价 |
| --- | --- | --- | --- |
| ADR-PROTO-001 | 统一 envelope + `code` 判定、HTTP 200 统一成功 | 三端（Java/Flutter/Node）只维护一套判定逻辑；HTTP 状态仅作传输语义 | 纯 HTTP 语义（201/204）：三端分支多、Flutter 拦截器复杂 |
| ADR-PROTO-002 | JWT 用 RS256 + 不透明 refresh 旋转 | 网关/API 可能拆分，公钥分发优于共享密钥；refresh 可撤销、可检测复用 | 单服务 HS256：简单但无法撤销、密钥泄漏影响大 |
| ADR-PROTO-003 | WS 首帧认证，token 不放 URL | 避免 token 进入代理/CDN/浏览器日志；子协议传 token（K8s 风格）可读性差、长度受限 | query 参数：实现最简，但日志泄漏风险不可接受 |
| ADR-PROTO-004 | 文件走云端中继而非 P2P | 零新增基础设施（无 TURN/SFU）；弱网可续传；审计集中 | P2P/WebRTC：省带宽但需 TURN + NAT 穿透，MVP 不可接受 |
| ADR-PROTO-005 | 每设备单写者分配 `seq` | 无全局序列瓶颈；同设备严格有序；断线补偿单游标 | 全局序号：跨设备阻塞；时间戳：同毫秒歧义 |
| ADR-PROTO-006 | 事件类型扁平命名（`task.progress` 直接作 `type`） | 分发简单、日志可读、抓包可读；避免 `{type:"event", eventType:...}` 双层解包 | 双层封装：扩展性好但三端都多一层胶水 |
| ADR-PROTO-007 | 命令必须 ack，超时即失败 | 不让手机端「假装成功」；策划案要求不伪造执行结果 | 仅靠事件流：无法区分「未送达」与「执行失败」 |
| ADR-PROTO-008 | 只读实时数据用 `server.command` RPC，写操作建模为 task | 写操作需要状态/审计/取消；读操作要低延迟 | 全部 REST 阻塞：Agent 离线时 REST 全部超时不可用 |
| ADR-PROTO-009 | 审批 **in-flight 为主（ACP `session/request_permission`），pre-flight 兜底**；超时回 `cancelled`、拒绝回 `reject-once` 且不伪造任务失败 | 实测 allow-once 批准后工具才执行；只有两个选项（无 allow-always）；拒绝后 turn 仍 end_turn | 只用 pre-flight：执行中危险动作无法拦截，等于假功能；把拒绝写成失败：违反「不展示伪造结果」 |
| ADR-PROTO-010 | 远程桌面媒体走 WSS 二进制帧（MVP），**H.264 编码为主、MJPEG 仅降级** | 复用现有通道，零新增基础设施；实测 H.264 约 1.8–3.0 Mbps 可用、MJPEG 约 13.3 Mbps 公网不可接受（ENVIRONMENT_REPORT §5.4） | WebRTC：延迟更低但需 TURN/SFU（见 REMOTE_AGENT ADR-AGENT-006） |

---

## 14. 与策划案章节对照

| 策划案要求 | 本文落点 | 状态 |
| --- | --- | --- |
| 4.2 手机↔云端↔Agent 通信架构 | §1、§3（HTTPS + WSS 出站） | ✅ |
| 4.2 断线重连和心跳检测 | §5.1、§5.3 | ✅ |
| 4.2 消息确认与去重 | §5.2、§5.4 | ✅ |
| 4.2 任务状态恢复 | §5.3、§5.6 | ✅ |
| 4.2 连接超时和网络异常提示 | §1.4、§5.1 | ✅ |
| 4.2 设备撤销后立即拒绝新操作 | §2.6、§9.2（每帧校验） | ✅ |
| 6 章 17 个 REST API | §2.1–§2.17 | ✅ |
| 6 章 统一响应/错误码/分页/鉴权/幂等 | §1.3–§1.9 | ✅ |
| 6.1 全部 13 个事件 | §6 | ✅ |
| 6.1 消息 ID/类型/设备/任务/时间戳/数据体 | §4.1 | ✅ |
| 6.1 重复投递、乱序、断线补偿 | §5.3、§5.4 | ✅ |
| 7.2 六级权限 | §1.6.3、§8 | ✅ |
| 7.3 高风险操作需确认 + 审计 | §8.2–§8.4 | ✅ |
| 7.4 紧急停止 | §9 | ✅ |
| 4.3 屏幕共享与输入控制分别授权 | §6.12、§7.3 | ✅ |
| 4.3 远程桌面不可用时其他功能独立 | §7.1（命令独立通道）、REMOTE_AGENT 分层 | ✅ |

---

## 15. 变更记录

| 版本 | 日期 | 变更 | 作者 |
| --- | --- | --- | --- |
| 1.0 | 2026-10-31 | 初版：17 REST API + WS 协议 + 13 事件 + 审批/急停/4 张以上时序图 | protocol-architect |
| 1.1 | 2026-10-31 | 依据 HARNESS_INTERFACES 实测（DSH 0.2.1-rc.5，ACP）：§8 审批改为 in-flight 为主 + pre-flight 兜底，规则补 toolCallId 绑定与「拒绝≠失败、超时不伪装失败」；§10.1 时序改为 ACP 常驻进程 + 步骤级事件；§10.2 取消改 `session/cancel`；§12 待验证表按实测更新（H-01–H-08 ✅、H-09/H-13/H-14 ⚠️）；§13 ADR-PROTO-009 修订 | protocol-architect |
| 1.2 | 2026-10-31 | 依据 [ENVIRONMENT_REPORT.md](../research/ENVIRONMENT_REPORT.md) §5.4 实测：§7.3 媒体帧改 **H.264 为主、MJPEG 仅降级**（MJPEG 1280×10fps ≈13.3 Mbps 公网不可接受、H.264 ≈1.8–3.0 Mbps），帧头加 codec 字节、自适应顺序改为「码率→帧率→分辨率→MJPEG」；§7.2 `desktop.start` 增 `codec?`；§6.12 `desktop.connected` 增 `codec/targetBitrateKbps`；§13 ADR-PROTO-010 与 §12 H-09 同步更新 | protocol-architect |


