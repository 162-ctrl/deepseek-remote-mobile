# M2.1 契约增量：可补偿事件、断线演练、审批等待与执行槽解耦

> 版本：v1.0（2026-11-02）· 上游：`M1_PROTOCOL.md`、`M1_1_DELTA.md`、`M2_DELTA.md`
> 本文是 M2.1 的**唯一契约依据**。**不得破坏 M1/M1.1/M2 已验收的行为**；新增字段/端点向后兼容。

## 1. 目标与范围

| # | 目标 | 验收 |
|---|---|---|
| M2.1-A1 | 事件独立落库：新增 `task_events` 表，替换"任务时间线由 messages 派生" | `GET /api/v1/tasks/{id}` 的 `events` 来自 `task_events`；psql 行数与时间线一致 |
| M2.1-A2 | 事件补拉端点：`GET /api/v1/conversations/{id}/events?afterSeq=&limit=` | 返回按 seq 升序的事件流，`afterSeq` 增量语义与消息一致 |
| M2.1-A3 | **断线补偿端到端**：App 断网/断 WS 期间后端产生的事件，重连后通过补拉不丢、不重、不乱序 | `tools/m2-catchup-test.ts` 全绿：断流期间输出事件数 > 0，重连补拉后 seq 连续且终态 completed |
| M2.1-A4 | 审批等待不再"占死"执行槽：同一会话在 `waiting_approval` 期间允许用户继续输入，由手机端排队并在空闲后自动重发 | Flutter 单测覆盖：排队→空闲自动发送；用户可见「已排队」提示；协议不新增必选字段 |

**不做**：远程桌面、厂商推送、多用户账号、ACP 协议内真正并发（ACP 单会话只允许一个 in-flight，这是上游约束，M2.1 用队列降级而非绕过）。

## 2. 后端：`task_events` 表（Flyway V4）

```sql
CREATE TABLE task_events (
  id              CHAR(26) PRIMARY KEY,          -- ULID
  conversation_id CHAR(26) NOT NULL REFERENCES conversations(id),
  task_id         CHAR(26) NULL REFERENCES tasks(id),
  seq             BIGINT NOT NULL,               -- 每会话单调递增，与实时转发 seq 同源
  type            VARCHAR(48) NOT NULL,          -- session.update / task.state / approval.request / approval.resolved / conversation.created
  kind            VARCHAR(32) NULL,              -- session.update 的 kind：output/thinking/tool_call/tool_call_update/usage
  payload         JSONB NOT NULL DEFAULT '{}',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (conversation_id, seq)
);
CREATE INDEX idx_task_events_conv_seq ON task_events(conversation_id, seq);
CREATE INDEX idx_task_events_task ON task_events(task_id);
```

- **seq 来源必须与实时转发一致**：`ws/RelayHub.java` 为每个会话维护的 seq 计数器是唯一来源；每转发一条 App 可见事件，就用同一个 seq 落一行 `task_events`（思考 thinking 也落，方便补拉后客户端自己折叠）。
- 落库复用 `PersistenceService` 的单线程 FIFO，失败只 WARN，不影响转发；补拉读的是**已提交**的行，因此客户端需容忍"重连瞬间最后一两条尚未 commit"→ 客户端补拉后再跟随实时流，并按 seq 去重（见 §4）。
- `approval.request` 的 payload：`{approvalId, tool, input, workspace, options, permissionLevel, riskLevel, expiresAt}`；`approval.resolved`：`{approvalId, decision, decidedBy}`。两者都落库（断线时用户重连后仍能看到"已超时/已处理"）。
- 历史回填（一次性，V4 后执行）：把已有 `messages`（role=user/assistant/tool）按 `seq` 写入 `task_events`，`type='backfill'`；新 endpoint 不返回 `type='backfill'`（客户端只用它做时间线兜底，不参与实时补拉）。若实现成本高，可只回填最近 30 天；报告中注明。

## 3. 后端 REST

### 3.1 `GET /api/v1/conversations/{id}/events?afterSeq=<long>&limit=<int ≤500>`

- 鉴权：Bearer（与 M1 历史 REST 一致）；conversation 不属于当前 user → 404。
- 响应：`{"events":[{"seq":12,"type":"session.update","kind":"output","payload":{...},"createdAt":"2026-11-02T07:00:00Z"}],"nextSeq":13}`
- 排序：`seq ASC`；`afterSeq` 缺省 0；`limit` 缺省 200，上限 500；超出范围 400 错误信封（沿用 M1_PROTOCOL §5）。

### 3.2 `GET /api/v1/tasks/{id}`（修改）

- `events` 字段改读 `task_events`（`WHERE task_id=? ORDER BY seq ASC LIMIT 500`），输出结构不变：`{seq,type,title,detail,tool,createdAt}` 由 `kind`/`payload` 映射（如 tool_call → title=tool 名、detail=command 摘要；task.state → title=状态；approval.* → title=审批请求/结果）。旧前端不受影响。

## 4. 手机端

### 4.1 重连补拉（替代当前"靠 messages 兜底"）

- 记忆 `lastSeq`（每会话，来自实时事件 `seq` 与补拉结果的最大值）；连接恢复（重连成功、App 回前台）时：
  1. `GET /api/v1/conversations/{id}/events?afterSeq=lastSeq&limit=500` 循环拉到空/不足 limit；
  2. 事件按现有映射（kind→ChatItem/TaskEvent）与实时流**共用同一个处理入口**，按 seq 去重；
  3. 若补拉期间实时流也在跑，允许先合并后排序，最终以 seq 单调为准；
  4. 补拉失败不阻塞 UI，显示"同步中/同步失败，点击重试"。
- 与消息 REST 的关系：`messages` 仍用于首次进入会话的历史渲染；`events` 用于增量补偿。两条路径都写同一份内存模型，按 seq 去重。

### 4.2 审批等待排队（M2.1-A4 降级实现）

- 现状：会话有 in-flight turn（含等待审批）时，发下一条指令会被后端返回 `SESSION_BUSY`。
- 新行为（仅手机端，不改协议）：
  1. 用户点击发送且当前会话 busy → 不报错，进本地**队列（深度 1）**，气泡显示「已排队，当前任务结束后自动发送」；
  2. 监听 `task.state` 变为 completed/failed/cancelled（或审批 resolved 且 turn 结束）后自动发出排队的 prompt；
  3. 队列中的消息可点「移除」；用户可看到队列状态；断线/重连不丢队列（仅内存，进程被杀丢失，报告中注明）；
  4. 同时把「正在执行，可继续输入排队」提示替换为真实排队状态。

## 5. 验收与证据

| 项 | 方法 | 证据 |
|---|---|---|
| M2.1-A1 | `psql: select count(*), min(seq), max(seq) from task_events where conversation_id=...` + `GET /tasks/{id}` events 数 | `docs/research/evidence/m2/` |
| M2.1-A2 | curl/psql 对照：断流后 `afterSeq` 补拉返回 seq 连续 | 同上 |
| M2.1-A3 | `node tools/m2-catchup-test.ts --base http://127.0.0.1:8080 --drop-ms 60000` | `docs/research/evidence/m2/m2-catchup-<stamp>.json` |
| M2.1-A4 | `flutter test` 新增队列测试全绿 | `app/test/queued_prompt_test.dart` |

## 6. 交付物

- 后端：`db/migration/V4__task_events.sql`、`persistence/TaskEventStore.java`（或并入 PersistenceService）、`api/HistoryController.java` 新端点 + tasks/{id} 改表、`ws/RelayHub.java` 落库接线、`backend/README.md`。
- 手机端：`app/lib/data/live_store.dart`（events 补拉、seq 去重、队列）、`app/lib/services/history_api.dart`（events API）、`app/lib/screens/assistant_screen.dart`（排队提示/移除）、测试 `app/test/queued_prompt_test.dart`、`app/test/catchup_test.dart`、`docs/mobile/README.md`。
- Lead：`tools/m2-catchup-test.ts`、验收证据、`docs/research/M2_1_REPORT.md`、README/PROJECT_STATUS 更新。
