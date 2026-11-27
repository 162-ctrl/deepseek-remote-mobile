# M2.1 交付报告：可补偿事件、断线演练、审批等待排队

> 日期：2026-11-02 · 阶段：M2.1（M1/M1.1/M2 已交付）· 契约：[`docs/design/M2_1_DELTA.md`](../design/M2_1_DELTA.md) v1.0
> 结论：**M2.1 四项验收全部达成**——事件独立落库（A1）、增量补拉端点（A2）、真实断流 60 秒后端到端补拉不丢不重不乱序（A3）、执行中排队降级（A4）。M1 全链路回归 6/6 通过，手机端 124/124 测试通过。

## 1. 一句话结论

断线不再是「刷新一下就丢几条输出、任务卡在正在执行」：现在**后端把每条手机可见事件按会话统一编号落库**，手机重连后只带着 `afterSeq` 补拉一次，缺的事件（包括任务终态、审批请求/结果）全部补齐，且不会重复；同一次演练中，断流 60 秒期间产生的 7 条事件一条不少地补回到了客户端。用户在任务执行/等待审批时可以继续打字，消息进入深度 1 的本地队列，任务一结束自动发出，不再被 `SESSION_BUSY` 顶回来。

## 2. 交付物

| 层 | 文件 |
|---|---|
| 契约 | `docs/design/M2_1_DELTA.md`（Lead 产出） |
| 后端 | `db/migration/V4__task_events.sql`、`ws/RelayHub.java`（转发前统一分配 seq + 事件落库）、`persistence/PersistenceService.java`（`task_events` 写入、消息复用事件 seq）、`persistence/Ulid.java`（复用）、`api/HistoryController.java`（`/conversations/{id}/events`、`/tasks/{id}` 改读事件表）、`application.properties`（`m1.events.*`）、`backend/README.md` |
| 手机端 | `lib/services/history_api.dart`（`ConversationEventRecord`/`events()`）、`lib/data/live_store.dart`（`lastSeq`、`_seenSeqs`、`_applyFrame`、`catchUpEvents()`、排队队列）、`lib/models.dart`（`ChatItem.seq/queued`、`TaskEvent.seq`）、`lib/widgets/chat_items.dart`（排队气泡）、`lib/screens/assistant_screen.dart`（同步中/失败重试/排队提示）、`docs/mobile/README.md` |
| 验收工具 | `tools/m2-catchup-test.ts`（真实断流→重连补拉演练，输出证据 JSON） |
| 证据 | `docs/research/evidence/m2/catchup-2026-11-02T07-30-50-131Z.json`、`docs/research/evidence/m1/e2e-2026-11-02T07-32-40-079Z.json` |

## 3. 后端实现要点

1. **`task_events` 表（Flyway V4，已 applied）**：`id CHAR(26)`、`conversation_id`、`task_id NULL`、`seq BIGINT`、`type`、`kind`、`payload JSONB`、`created_at`、`UNIQUE(conversation_id,seq)`、两个索引。`conversations` 增加 `next_seq`，迁移时初始化为 `max(messages.seq_in_conversation)`；历史消息一次性回填为 `type='backfill'`（不返回给客户端）。
2. **会话级统一 seq（M2.1 的基础）**：`conversations.next_seq` 是唯一计数源。`RelayHub` 把每条 App 可见事件（`conversation.created`、`session.update` 全 kind、`task.state`、`approval.request/resolved`）转发前原子 `UPDATE … RETURNING` 取号，转发信封与该 `task_events` 行使用同一 seq；`prompt.send` 的用户消息也先取号再落 `messages`；由事件派生的消息（tool_call/tool_result/assistant 聚合）复用事件的 seq。→ 实时流、消息历史、事件补拉**共用一条编号空间**，客户端可以只靠 `afterSeq` 判断缺了什么。
3. **`GET /api/v1/conversations/{id}/events?afterSeq=&limit=`**：Bearer 鉴权；`limit` 默认 200 / 上限 500；`seq ASC`；`type='backfill'` 不返回；响应 `{events:[{seq,type,kind,payload,createdAt}],nextSeq}`。
4. **`GET /api/v1/tasks/{id}`**：时间线改读 `task_events`（按 `task_id`），输出结构对旧前端兼容。
5. **失败策略**：落库仍走 `PersistenceService` 单线程 FIFO，DB 异常只 WARN，不影响实时转发；补拉读已提交行，客户端靠 seq 去重。

## 4. 手机端实现要点

1. **增量补拉**：`live_store.dart` 为每个会话维护 `lastSeq` 与 `_seenSeqs`；重连成功、App 回前台、进入会话后调用 `catchUpEvents()`（循环 `afterSeq=lastSeq` 直到不足一页）。实时帧与补拉事件都进同一个 `_applyFrame`，按 seq 去重后交给同一个 `_dispatchEvent`；补拉失败写 `catchUpError`，UI 显示「正在同步断线期间的事件…／同步失败，点击重试」，不阻塞实时输出。
2. **执行中排队（M2.1-A4 降级）**：会话 busy 时发送 → 进深度 1 本地队列，显示「已排队 · 当前任务结束后自动发送」气泡（可移除）；收到 `task.state` completed/failed/cancelled 后自动发出；审批等待期间同样适用（审批结束 → turn 结束 → 自动发下一条）。
3. **去重细节**：旧协议帧缺省 `seq=0`，去重只认 `seq > 0`，避免把无序号的历史帧误判为重复丢弃（修了 3 个回归测试）。

## 5. 验收证据

| 项 | 结果 | 证据 |
|---|---|---|
| **M2.1-A1** 事件独立落库 | Flyway `(1 core)(2 seed)(3 auth tokens)(4 task events)` 全 success；非 backfill 事件按会话 `max(seq)-min(seq)+1 = count`（无空洞，如 51/51、10/10）；`GET /tasks/{id}` events=13 行，与 `task_events` 该任务行数一致 | 本报告 §3 + psql 输出 |
| **M2.1-A2** 补拉端点 | `afterSeq=0&limit=5` → 5 条（seq 1..5，nextSeq=6）；`afterSeq=48` → seq 49,50,51；backfill 不返回 | 人工 REST 复核 |
| **M2.1-A3** 断线补偿端到端 | **PASS**（Lead 与 backend-dev2 各跑一次）：断流前 2 条事件（lastSeq=3）→ 断流 60000ms → 重连补拉 **7 条事件，seq 4..10**，与断流前/重连后实时事件合并后 **9/9 seq 唯一**，任务终态 completed **来自补拉** | `docs/research/evidence/m2/catchup-2026-11-02T07-30-50-131Z.json`、`docs/research/evidence/m2/catchup-2026-11-02T07-44-27-621Z.json` |
| **M2.1-A4** 排队降级 | `flutter test` **124/124**（M2.1 新增 13：catchup 6 + queued 7），覆盖「busy 不直接发、深度 1、可移除、终态自动发、resolved 后仍等 turn 结束」 | `app/test/catchup_test.dart`、`app/test/queued_prompt_test.dart` |
| M1 回归 | `node tools/m1-client.ts` → **6/6 PASS**（A3 device.status、A4 conversation、A5 真实输出 1063ms、A6 cancel 2083ms、A7 审批 approved 5980ms、A8 审批 denied 5997ms；backend-dev2 复跑一次同样 6/6） | `docs/research/evidence/m1/e2e-2026-11-02T07-32-40-079Z.json`、`docs/research/evidence/m2/m1-client-6of6-2026-11-02T07-45-57-297Z.json` |
| 数据库不变式 | `no_hole_bad=0`（每会话 seq 无空洞且 min=1）、`msg_without_event_bad=0`（messages↔task_events seq 对齐）、`event_vs_nextseq_bad=0`、`thinking_events=30` 且 `thinking_messages_bad=0`、`payload.seq` 与行 seq 不一致=0；库终态 conversations=18 / messages=190 / tasks=49 / task_events=337（backfill 99）/ audit_logs=18 | psql 断言 + `backend/README.md` |
| 手机端构建 | `flutter test` 124/124；`flutter build apk --debug` 成功（158.1 MB，2026-11-02 15:23:55） | `app/build/app/outputs/flutter-apk/app-debug.apk` |

## 6. 启动方式（不变）

```powershell
# 一键：PostgreSQL + 后端 + 隧道 + Agent（+ 模拟器）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-up.ps1 -WithEmulator
# 查看隧道地址/配对码
Get-Content .m1-state\state.json
# 本次断线演练（会真实等待，默认 60s；--drop-ms 300000 可模拟 5 分钟）
node tools\m2-catchup-test.ts --base http://127.0.0.1:8080 --drop-ms 60000
# M1 回归
node tools\m1-client.ts --base http://127.0.0.1:8080
```

## 7. 已知限制

1. `health.version` 仍为 `0.1.1-m2`（M2.1 未改版本号，仅数据面升级）；M2.1 验收以本报告为准。
2. `task_events` 的 `type='backfill'` 不回传给客户端：首次进会话仍用 `messages` REST 渲染历史，增量用事件补拉，两条路径共用内存模型但来源不同（已按 seq 去重）。
3. 队列只在手机内存：App 被杀/手机重启会丢排队消息（契约设计如此，避免自动重放误执行）。
4. 事件补拉依赖后端已提交行：重连瞬间最后一两条可能尚未 commit，客户端会因“补拉后实时 seq 继续增大”而自然追平，无需特殊处理；但极端情况下若客户端在 commit 前收到实时帧，会先显示再由补拉补全（已按 seq 去重）。
5. 本机模拟器仍不稳定（`adb devices` 常为空），M2.1 的 UI 补拉/排队界面**未做真机截图**；逻辑由 13 项新单测覆盖。
6. thinking 事件落 `task_events` 但不落 `messages`；补拉后客户端自己折叠（与在线时一致）。
7. 审批请求/结果也落事件表，断线重连后能看到「已超时/已处理」状态，但不会重放已解决的审批弹层。

## 8. 下一步（M2.2 / M3 候选）

1. **真机联调**：装 `DeepSeek Remote AI 手机端 v0.1.2-m2.1.apk`，验证锁屏审批通知 + 断网重连补拉 UI（本机模拟器不可用）。
2. 审批时效与等待槽：审批等待期间是否允许其它会话并发（当前全局并发 2，校验审批占槽影响）。
3. `audit_logs` 月分区、`devices.operating_system` 上报、app deviceId 稳定化（26 位 ULID）。
4. 远程桌面 L1（H.264 看一眼）、Agent 安装包与签名 APK。
5. 移动端后台保活策略在真机厂商 ROM 上的实测（小米/华为/OPPO 等）。

## 9. 证据索引

| 证据 | 路径 |
|---|---|
| 断线补偿演练（Lead） | `docs/research/evidence/m2/catchup-2026-11-02T07-30-50-131Z.json` |
| 断线补偿演练（backend-dev2） | `docs/research/evidence/m2/catchup-2026-11-02T07-44-27-621Z.json` |
| M1 全链路回归（M2.1 后） | `docs/research/evidence/m1/e2e-2026-11-02T07-32-40-079Z.json`、`docs/research/evidence/m2/m1-client-6of6-2026-11-02T07-45-57-297Z.json` |
| 手机端测试 | `app/test/catchup_test.dart`、`app/test/queued_prompt_test.dart`（124/124） |
| 契约 | `docs/design/M2_1_DELTA.md` |
| 验收工具 | `tools/m2-catchup-test.ts` |
| 后端规则与自测 SQL | `backend/README.md`（seq 规则、不变式、events 端点） |

---

*本报告中的数字均来自本轮实际运行；未验证项已在 §7 明确标注。*
