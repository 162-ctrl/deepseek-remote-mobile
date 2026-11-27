# M1.1 交付报告：持久化、历史与真实任务页

- **日期**：2026-11-02
- **阶段**：M1.1（M1-α 之后的增量）
- **依据**：`docs/design/M1_1_DELTA.md`（本阶段唯一契约）
- **结论**：M1.1 完成并通过验收——**重启后端不丢历史**（会话/消息/任务/审计落 PostgreSQL 16.10），手机端能拉历史会话、任务中心与任务详情改为真实数据、工具调用输出改为结构化分块渲染。两处已知偏差（app 侧 deviceId 仍 `dev_N`、health 版本号仍 `0.1.0-m1`）已在遗留清单记录。

---

## 1. 一句话结论

> 数据从"内存里跑完就没了"变成"重启还在"：8 个会话、61 条消息、15 个任务、6 条审批审计都在 PostgreSQL 里；手机端新增的历史会话、真实任务列表/详情、结构化工具输出均基于同一套 REST 契约，`flutter test 95/95`、`m1-client 6/6` 全绿。

---

## 2. 交付范围

| 层 | 交付 | 位置 |
|---|---|---|
| 数据库 | PostgreSQL 16.10 便携版 + 库 `deepseek_remote` / `deepseek_remote_test`（端口 5433，trust 本地） | `C:\Users\user\dsh-tools\pgsql`、`C:\Users\user\dsh-tools\pgdata-deepseek` |
| 后端 | Flyway V1 核心六表 + V2 种子用户；异步落库；4 个历史 REST | `backend/` |
| 手机端 | 历史会话弹层、真实任务列表/详情、结构化工具输出、真实项目页 | `app/lib/`、`app/test/` |
| 工具 | 一键脚本新增 PostgreSQL 管理 | `tools/m1-up.ps1`、`tools/m1-down.ps1` |
| 文档 | 契约增量、本报告、README/STATUS/手机端 README 同步 | `docs/design/M1_1_DELTA.md`、本文件 |

---

## 3. 后端实现要点

- **迁移**：`V1__core.sql`（`users` `devices` `conversations` `messages` `tasks` `audit_logs`，按 `DATA_MODEL.md` 核心表，仅追加 `users.nickname`、`conversations.workspace_path`，`set_updated_at` 触发器）；`V2__seed.sql`（种子用户 `u_self`，26 位 Crockford ID `01JSEED0000000000000000000`）。Flyway 当前版本 **2**。
- **ID**：会话/任务/消息统一 26 位 Crockford ULID（`persistence/Ulid.java`）；会话 ID 已从内存序号改为 ULID，旧数据自然隔离。
- **落库**（`persistence/PersistenceService.java`）：单线程 FIFO 异步队列，**落库失败只 WARN、不影响转发**；`@PreDestroy` 最多 flush 5 秒；`task.state=completed` 时把 assistant 文本聚合为一条 `messages`（上限 8000 字）；**thinking 不落库**；`tool_call`/`tool_call_update` 存 `messages(role=tool)`；`approval.decide` 写 `audit_logs`。
- **历史 REST**（`api/HistoryController.java`，Bearer 鉴权，错误体 `{error:{code,message}}`）：
  - `GET /api/v1/conversations?limit=`
  - `GET /api/v1/conversations/{id}/messages?afterSeq=&limit=`
  - `GET /api/v1/tasks?status=&limit=`
  - `GET /api/v1/tasks/{id}`（含 `events` 时间线）
- **配置**：`application.properties` 支持 `M1_DB_URL` / `M1_DB_USER` / `M1_DB_PASSWORD` / `M1_DB_MIGRATE` / `M1_DB_PERSIST` 环境变量覆盖；数据库不可用时后端启动失败（避免"静默无持久化"）。

## 4. 手机端实现要点

- **历史**：连接成功后自动 `GET /conversations`；AI 助手右上角**时钟图标**打开历史会话弹层；进入会话用 `messages?afterSeq=0` 回填，实时事件按 `seq` 追加去重；断线重连按 `afterSeq=lastSeq` 增量补齐。
- **任务中心**：真实模式数据源换成 `GET /tasks`，筛选/统计/下拉刷新基于真实任务；任务详情用 `GET /tasks/{id}` 的 `events` 渲染时间线。
- **工具输出结构化**：`tool_call` / `tool_result` 分块（命令 mono 块、状态图标、耗时、退出码，输出可折叠），不再直接显示原始 JSON 片段；thinking 仍折叠。
- **项目页**：真实模式只读 `device.status.workspaceRoots`，无数据显示空状态（不回落演示数据）。
- **演示模式保留**：未连接时行为与之前一致，界面「演示数据」标记不变。

---

## 5. 验收证据

### 5.1 数据库（psql 实测，2026-11-02）

| 表 | 行数 | 说明 |
|---|---|---|
| `users` | 1 | 种子用户 u_self |
| `devices` | 1 | DESKTOP-XXXXXXX，跨 backend 重启稳定复用 |
| `conversations` | 8 | 多轮 E2E 累计 |
| `messages` | 61 | assistant/text 12、tool/tool_call 17、tool/tool_result 17、user/text 15，**无 thinking 行** |
| `tasks` | 15 | completed / cancelled 混合 |
| `audit_logs` | 6 | approved×3、denied×3 |
| `flyway_schema_history` | v2 | 1=core success、2=seed success |

### 5.2 端到端（m1-client，真实 Harness）

| 场景 | 结果 | 证据 |
|---|---|---|
| M1.1 改造前 6/6 | PASS | `evidence/m1/e2e-2026-11-02T05-18-38-365Z.json` |
| **重启 backend 后 6/6** | PASS | `evidence/m1/e2e-2026-11-02T05-21-36-767Z.json` |
| **Lead 回归 6/6**（M1.1 后端 + 新 app 契约） | PASS | `evidence/m1/e2e-2026-11-02T05-32-32-647Z.json` |

### 5.3 P-1：重启不丢历史（Lead 实测）

1. 杀掉 8080 端口后端进程（java，pid 6404）；
2. `gradle bootRun` 重新拉起，health 恢复；
3. 重新 `POST /auth/pair` 拿新 token；
4. `GET /conversations?limit=10` → **会话仍在**（conversationId/标题/workspace/messageCount/lastMessageAt 完整）；
5. `GET /conversations/{id}/messages?afterSeq=0` → 19 条按 `seq` 升序返回；
6. `GET /tasks?limit=50` → 15 个任务；psql 计数与 REST 一致。

> 结论：**数据持久化生效**。注意 token 仍在后端内存，后端重启后**手机/Agent 需重新连接（重新 pair）**，见遗留项 1。

### 5.4 手机端

| 项目 | 结果 |
|---|---|
| `flutter test` | **95/95 全绿**（原 68 + M1.1 新增 27，全部离线、FakeSocket） |
| `flutter build apk --debug` | 成功，`app/build/app/outputs/flutter-apk/app-debug.apk`（158.1 MB，2026-11-02 13:22） |
| 真实 REST 联调（app-dev 临时探针） | 配对→conversations→messages?afterSeq→tasks→tasks/{id} 全链路解析正确，无契约偏差 |
| 真机 UI 截图 | **未补拍**（见 §7 环境限制）；M1 阶段 09–13 截图仍有效，M1.1 新增能力由 95 项测试与 REST 联调覆盖 |

### 5.5 关于"中文乱码"的判定（重要）

用 PowerShell 5.1 打印 REST 返回的中文（如会话标题）会显示 `M1 E2E ä¼è¯`，这是 **PowerShell 对无 `charset` 的 `application/json` 按 ISO-8859-1 解码** 导致的显示问题，不是数据问题：

- 数据库实测：`select encode(convert_to(title,'UTF8'),'hex')` = `4d312045324520e4bc9ae8af9d`，即 UTF-8 的 `M1 E2E 会话`；`char_length(title)=9`；
- App 解码：`app/lib/services/history_api.dart` 用 `response.transform(utf8.decoder)` 显式按 UTF-8 解码，不受响应头 charset 影响。

---

## 6. 启动与复现

```powershell
# 一键（自动拉起 PostgreSQL → 后端 → 隧道 → Agent；-WithEmulator 可选）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-up.ps1 -WithEmulator

# 回归（本机）
cd agent; node tools\\..\\tools\\m1-client.ts --base http://127.0.0.1:8080   # 实际路径：node tools/m1-client.ts
# 或对公网隧道
node tools/m1-client.ts --base https://<tunnel-url>

# 手机端
cd app; flutter test; flutter build apk --debug

# 停止（默认保数据库；-StopDb 连同 PostgreSQL 一起停）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-down.ps1
```

数据库连接（本地）：`psql -h 127.0.0.1 -p 5433 -U postgres -d deepseek_remote`。

---

## 7. 已知限制与遗留

1. **Token 仍在后端内存**：后端重启后旧 token 全部失效，Agent 与手机需重新连接/重新 pair（数据不受影响）。M2 建议做 token 持久化或 Agent 自动重配对。
2. **app 侧 deviceId 仍为 `dev_N`**：DELTA 约定 26 位稳定 ID，目前只有 agent 侧设备行（`devices`）为 26 位；app 不建 device 行。
3. `devices.operating_system='unknown'`：pair 请求未带 OS 字段，M2 由 Agent 上报。
4. **task events 为消息时间窗派生**，没有独立 `task_events` 表；`tasks` 表字段足以支撑当前 UI。
5. `audit_logs` 未做月分区（`DATA_MODEL.md` 的 M2 项）。
6. **health 版本号仍 `0.1.0-m1`**（M1.1 未改版本号，属展示问题）。
7. PostgreSQL 不可用时后端启动会因 Flyway 失败而失败（有意为之，避免静默降级）。
8. App 历史不在本地缓存，重开 App 需重新连接后拉取。
9. **模拟器环境不稳定（本阶段 UI 截图未补拍的原因）**：headless AVD（timebook_test，1080×2400）在 App 完成连接后的 1–3 分钟内会被环境回收/退出；`-gpu swiftshader_indirect` 反复退出、`-gpu off` 下 Flutter 启动即崩、`-gpu host` 无法完成启动。M1 阶段同环境曾稳定跑 20–25 分钟，判定为环境问题而非应用问题；建议改用真机或稳定宿主补拍 M1.1 UI 截图。

---

## 8. 下一步（M2 候选，按优先级）

1. **Token 持久化 / 自动重配对**（消除"重启后端需手动重连"）。
2. **M2 任务实时性**：`task_events` 独立表、断线补偿端到端演练、进度与步骤级事件口径。
3. **审批通知与时效**（D-8）：手机后台/锁屏时的审批与急停通知路径。
4. 多设备与 workspace 类型、审计日志分区、`devices.operating_system` 上报。
5. 真机联调 + M1.1 UI 截图补齐。

---

## 9. 证据索引

- E2E JSON：`docs/research/evidence/m1/e2e-2026-11-02T05-18-38-365Z.json`、`e2e-2026-11-02T05-21-36-767Z.json`、`e2e-2026-11-02T05-32-32-647Z.json`
- M1 阶段报告：`docs/research/M1_E2E_REPORT.md`
- 契约：`docs/design/M1_1_DELTA.md`
- 后端迁移：`backend/src/main/resources/db/migration/V1__core.sql`、`V2__seed.sql`
- 手机端历史客户端：`app/lib/services/history_api.dart`
