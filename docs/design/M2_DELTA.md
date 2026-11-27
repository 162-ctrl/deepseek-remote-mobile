# M2-α 增量契约：审批通知与时效、token 持久化

> 状态：v1.0（2026-11-02）｜前置：M1.1（PostgreSQL 持久化、历史 REST）已验收
> 本文件只写 **M2-α 的增量**，其余仍以 `M1_PROTOCOL.md` + `M1_1_DELTA.md` 为准。

## 0. 目标与范围

**要解决的日用痛点**（用户已确认）：

1. **锁屏/后台收不到审批**：审批只有 App 前台时才可见，人离开手机就会错过（D-8）。
2. **重启后端要手动重连**：token 只存后端内存，后端一重启，手机与 Agent 都得重新配对（M1.1 已知限制第 1 条）。

**范围**

- 后端：token 落库（重启不失效）+ 版本号升到 `0.1.1-m2`。
- 手机端：本地通知（审批/急停）+ 前台服务保活 + 点通知直达审批；连接层 401/4401 自动重配对。
- 不做：厂商推送（离线推送）、通知内直接批准（安全上必须在 App 内看完整参数再确认）。

## 1. 后端增量

### 1.1 表 `auth_tokens`（Flyway `V3__auth_tokens.sql`）

| 列 | 类型 | 说明 |
|---|---|---|
| `id` | `char(26)` PK | ULID |
| `token_hash` | `char(64)` UNIQUE | `sha256(token)` 十六进制；**不存明文** |
| `role` | `varchar(8)` | `app` / `agent` |
| `device_id` | `varchar(32)` | app 侧 `dev_N`；agent 侧 26 位设备 ID |
| `client_name` | `varchar(64)` | 配对时上报 |
| `issued_at` | `timestamptz` | 默认 now() |
| `expires_at` | `timestamptz` | 默认 now() + 30 天（env `M1_TOKEN_TTL_DAYS`，默认 30） |
| `revoked_at` | `timestamptz` | 可空；撤销后鉴权失败 |
| `last_seen_at` | `timestamptz` | 可空；握手/请求时更新（可选，失败不影响主线） |

索引：`(token_hash)` unique、`(device_id, role)`、`(expires_at)`。

### 1.2 行为

- `POST /api/v1/auth/pair`：成功时把 token 的 **sha256** 写入 `auth_tokens`，返回仍是 `{token, role, deviceId, expiresAt}`（对外契约不变）。
- REST Bearer 鉴权与 WSS `?token=` 握手：先查内存缓存，未命中查库（`token_hash = sha256(token)` 且未撤销未过期）；命中即通过并刷新 `last_seen_at`。
- **后端重启后旧 token 仍有效**（这是 M2 的核心验收 M2-A4）。
- 同 role 重复配对：允许，旧 token 保留到过期（多设备场景；M1 单设备也兼容）。
- 401 语义不变；新增 401 时不区分"不存在/过期/撤销"，避免枚举。
- `GET /api/v1/health` 的 `version` 改为 `0.1.1-m2`。

### 1.3 配置

```
M1_TOKEN_TTL_DAYS=30          # 可选
M1_DB_URL / M1_DB_USER / M1_DB_PASSWORD   # 沿用 M1.1
```

## 2. 手机端增量

### 2.1 通知渠道（Android）

| channel id | 名称 | IMPORTANCE | 用途 |
|---|---|---|---|
| `approval_alerts` | 需要授权 | HIGH（响铃+震动+横幅） | `approval.request` 到达且 App 不在前台 |
| `connection_status` | 连接状态 | LOW（静默常驻） | 前台服务常驻提示"已连接 <电脑名>" |

- Android 13+ 需请求 `POST_NOTIFICATIONS` 运行时权限；首次连接成功时请求，拒绝后功能降级但不影响连接。
- Android 14+ 前台服务需声明类型：`dataSync`（`android:foregroundServiceType="dataSync"`），并加权限 `FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC`、`POST_NOTIFICATIONS`。

### 2.2 前台服务保活

- 连接建立后启动前台服务（Kotlin `Service`，常驻 `connection_status` 通知，内容：`已连接 <deviceName> · DeepSeek Remote`）。
- 连接断开/用户主动断开时停止服务。
- 目的：App 退到后台后 WSS 不被系统回收，审批与任务事件仍能收到（后台 5 分钟内 `health.apps` 保持 1）。

### 2.3 审批通知与点击跳转

- `approval.request` 到达时：
  - App 在前台 → 仍弹 ApprovalSheet（现状不变）；
  - App 在后台/锁屏 → 发 `approval_alerts` 通知：标题「有一项操作需要授权」，正文 `tool · <命令首行截断 60 字>`，`tag = approvalId`（同一审批不重复堆叠）。
- 点击通知 → 启动/回到 App，携带 `approvalId`；App 若该审批仍挂起则自动打开 ApprovalSheet，若已过期则提示「该审批已失效」。
- 审批被解决/超时：取消对应 tag 的通知。
- 急停触发（`emergencyStop` 或连接被动断开）→ 发 `approval_alerts` 高优先级通知「已断开与电脑的连接」。

### 2.4 自动重配对

- 连接层收到 `401`（REST）或 WSS 握手关闭码 `4401` 时：若本地存有 `serverUrl + pairingCode`，自动重新 `POST /auth/pair`（role=app）并重连一次；成功后静默继续，失败才回到连接页并提示。
- Agent 侧已有 4401 自动重 pair（M1 实现），本次只验不改。

### 2.5 实现约束

- 优先**零 pub 依赖**：用 Kotlin 原生实现通知 + 前台服务，通过 `MethodChannel('deepseek_remote/notifications')` 暴露给 Dart（`showApproval`, `cancelApproval`, `startForeground`, `stopForeground`, `requestPermission`, `getInitialApprovalId`）。
- 如确需新增 pub 包，必须 `flutter pub get` 可联网成功且 `flutter build apk --debug` 通过。
- Dart 侧必须可测：通知调用走可注入的 `NotificationGateway` 接口，单测用 fake，不触碰真实 channel。

## 3. 验收（必须真实执行）

| 编号 | 验收项 | 判定方式 |
|---|---|---|
| M2-A1 | 锁屏/后台收到审批通知 | 手机连接后触发真实审批，App 退后台，`adb shell dumpsys notification` 或截图出现 `approval_alerts` 通知（若模拟器不可用，记录环境限制并在真机补做） |
| M2-A2 | 点通知直达审批 | 点击通知后 App 打开且对应 `approvalId` 的 ApprovalSheet 自动弹出（截图/日志） |
| M2-A3 | 后台保活 | App 退后台 5 分钟，`GET /health` 的 `apps` 仍为 1，期间任务事件未丢 |
| M2-A4 | 后端重启 token 仍有效 | 重启后端后，用重启前的 app token 调 `GET /conversations` 返回 200；Agent 无需重启即恢复 `agentOnline=true` |
| M2-A5 | 自动重配对 | 手动把库里该 token 置 `revoked_at=now()`，触发一次请求，App 自动重新配对并成功（日志/截图） |
| M2-A6 | 回归 | `flutter test` 全绿 + `flutter build apk --debug` 成功；`gradle build -x test` 成功；`node tools/m1-client.ts` 6/6 PASS |

## 4. 交付物

- 后端：`V3__auth_tokens.sql`、`TokenStore` 改为库优先、`HealthController` 版本号、README 更新。
- 手机端：`NotificationGateway`（Dart）、Kotlin `NotificationBridge/NotificationHelper/ConnectionService`、`AndroidManifest.xml` 权限与服务声明、`LiveStore`/`main.dart` 接线、单测。
- 文档：本文件、`docs/research/M2_REPORT.md`、README/PROJECT_STATUS 更新。
