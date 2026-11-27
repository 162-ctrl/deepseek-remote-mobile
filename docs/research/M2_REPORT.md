# M2-α 交付报告：锁屏审批通知、后台保活、token 持久化

> 日期：2026-11-02｜阶段：M2-α（用户 m02444「确认」）
> 契约：[`docs/design/M2_DELTA.md`](../design/M2_DELTA.md)｜前置：[`M1_1_REPORT.md`](M1_1_REPORT.md)
> 一句话结论：**M2-α 的两件日用痛点都解决了——后端重启不再需要重新配对（已实测旧 token 200），手机在锁屏/后台也能收到审批通知（代码与单测就绪，真机通知待补测）。**

## 1. 这一版解决了什么

| 痛点 | 之前 | 现在 |
|---|---|---|
| 重启后端 | token 只存内存 → 手机、Agent 都要重新配对 | token 的 sha256 落 PostgreSQL（`auth_tokens`）→ **重启后端旧 token 仍有效**，Agent 自动重连不再掉线 |
| 锁屏/后台 | 审批只在 App 前台可见，人一离开手机就错过 | **本地通知**（高优先级审批 / 断开告警）+ **前台服务保活**（后台 WSS 不被回收）；点通知直达对应审批 |
| 后端换 token 后 App | 只能回到连接页手动重连 | 连接层 **401/4401 自动重新 pair 并重连一次**，成功静默继续 |

## 2. 后端交付（task-10）

**改动文件（仅 `backend/`）**

- `src/main/resources/db/migration/V3__auth_tokens.sql`（新增）：`auth_tokens` 表，严格按 M2_DELTA §1.1 —— `id char(26) PK`、`token_hash char(64) UNIQUE`（sha256，**不存明文**）、`role`、`device_id`、`client_name`、`issued_at`、`expires_at`（默认 +30 天）、`revoked_at`、`last_seen_at`；索引 `(device_id, role)`、`(expires_at)`。
- `src/main/java/com/deepseek/remote/auth/TokenStore.java`（重写）：库优先 + 1 秒内存缓存；签发即写哈希行；`validate` = 缓存 → 查库（`token_hash=sha256 AND revoked_at IS NULL AND expires_at > now()`）→ 异步刷新 `last_seen_at`（失败忽略）；DB 写失败回退内存 token 只 WARN；REST Bearer 与 WSS `?token=` 共用同一路径。
- `application.properties`：`M1_TOKEN_TTL_DAYS=30`、`M1_TOKEN_CACHE_TTL_SECONDS=1`、`m1.version=0.1.1-m2`。
- `PairingController.java` / `build.gradle`：版本号 `0.1.1-m2`。
- `README.md`：表结构、env、重启不失效、M2-A4 自测方法。

**验证**

| 项 | 结果 |
|---|---|
| Flyway | `flyway_schema_history = (1 core)(2 seed)(3 auth_tokens)` 全部 success；启动日志 `Current version of schema public: 3` |
| 构建 | `gradle build -x test` BUILD SUCCESSFUL（`backend-0.1.1-m2.jar`） |
| **M2-A4（后端）** | pair → 重启后端 → **重启前 token 直接 `GET /conversations` = 200**（conversations=8，未重新 pair）；Agent pid 12684 全程未重启，health 立即 `agentOnline=true`，后端日志 `agent connected` 无 pair 调用 → WSS 也走库校验 |
| **M2-A4（Lead 复核）** | `docs/research/evidence/m2/m2-a4-lead-check.json`：before=200 → 杀后端重启 → **afterRestartOldTokenHttp=200**，`agentOnlineAfterRestart=true` |
| 撤销语义 | `revoked_at=now()` 后等缓存过期，同 token → 401（不区分原因，不泄露枚举信息） |
| 哈希抽查 | `auth_tokens` 3 行（agent 1 / app 2，其中 1 行 revoked）；token_hash 全部 64 位 hex、`count(distinct)=3`；`sha256(明文)=60e7a833…` 与库中记录相等；用明文子串在库中检索 0 行 |
| 回归 | `node tools/m1-client.ts` **6/6 PASS**（Lead 复核：`e2e-2026-11-02T06-42-22-475Z.json`） |

**注意事项**：M1_PROTOCOL §4 写的 `M1_AGENT_TOKEN_TTL`（24h）已被 M2_DELTA §1.3 的 `M1_TOKEN_TTL_DAYS`（默认 30 天）覆盖；本次不改 M1 契约正文，以此处说明为准。**升级到 M2 后，M1 内存时代签发的旧 token 不在库中，需要重连/重 pair 一次**（Agent 已能 4401 自动重 pair；App 端靠自动重配对兜底）。

## 3. 手机端交付（task-11）

**Kotlin 原生桥（零新增 pub 依赖）** —— `app/android/app/src/main/kotlin/com/deepseek/remote/deepseek_remote_app/`

- `NotificationHelper.kt`：渠道 `approval_alerts`（HIGH「需要授权」）/ `connection_status`（LOW「连接状态」）；审批通知 `tag = approvalId` 不堆叠；常驻「已连接 <deviceName> · DeepSeek Remote」；断开高优先级通知「已断开与电脑的连接」。
- `NotificationBridge.kt`：`MethodChannel('deepseek_remote/notifications')` —— `showApproval` / `cancelApproval` / `startForegroundService` / `stopForegroundService` / `requestPermission` / `getInitialApprovalId` / `showDisconnected` / `clearDisconnected`；**冷启动**（`getInitialApprovalId`）与**热启动**（`onNewIntent → onApprovalTapped`）两条点击路径都覆盖。
- `ConnectionService.kt`：前台服务（Q+ `FOREGROUND_SERVICE_TYPE_DATA_SYNC`，`START_STICKY`）；`MainActivity.kt` 注册桥、转发 intent 与权限结果。
- `AndroidManifest.xml`：`INTERNET` / `POST_NOTIFICATIONS` / `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC` + `<service … foregroundServiceType="dataSync"/>`；新增 `res/drawable/ic_stat_remote.xml`。

**Dart 侧**

- 新增 `lib/services/notification_gateway.dart`：接口 + MethodChannel 实现 + Fake（可注入，单测不碰真实通道）。
- `lib/services/relay_client.dart`：新增 `authFailures` 流（WSS 4401）。
- `lib/data/live_store.dart`：审批通知只在**后台**发（前台仍弹 ApprovalSheet）；正文「tool · 命令首行 ≤60 字…」；decide/超时/resolved/断开都取消通知；连接成功请求一次通知权限 + 启动前台服务，断开停止；**REST 401 或 4401 用本地 serverUrl+pairingCode 自动重新 pair 并重连一次**（`_withAuthRetry` 覆盖四个 REST 方法），失败回连接页提示。
- `lib/app.dart`：`WidgetsBindingObserver` 注入 gateway；`assistant_screen.dart`：后台不自动弹层，点通知后按 `approvalToOpenId` 打开对应审批、已过期则提示。

**验证**

| 项 | 结果 |
|---|---|
| 单测 | `flutter test` **111/111 全绿**（M1 68 + M1.1 27 + M2 16；Lead 复核 `TEST_EXIT=0`，`All tests passed!`） |
| 构建 | `flutter build apk --debug` 成功，`app/build/app/outputs/flutter-apk/app-debug.apk`（158.1 MB，2026-11-02 14:39） |
| 通知实测 | **未做**：`adb devices` 无设备，本机 headless 模拟器本阶段 1–3 分钟被环境回收（M1.1 起已记录）。通知渠道/触发/点击逻辑由 16 项单测覆盖，APK 可装真机复验 |

## 4. 验收矩阵（对照 M2_DELTA §3）

| 编号 | 验收项 | 状态 | 证据 |
|---|---|---|---|
| M2-A1 | 锁屏/后台收到审批通知 | 🟡 代码+单测就绪，真机待补测 | `notification_flow_test.dart`；APK |
| M2-A2 | 点通知直达审批 | 🟡 冷/热启动两条路径已实现并有单测 | `notification_flow_test.dart` |
| M2-A3 | 后台保活 5 分钟 | 🟡 前台服务已实现，真机待补测 | `ConnectionService.kt` |
| M2-A4 | 重启后端 token 仍有效 | ✅ **已实测两次**（后端自测 + Lead 复核） | `docs/research/evidence/m2/m2-a4-lead-check.json` |
| M2-A5 | 自动重配对 | 🟡 单测覆盖（401/4401 路径），真机待补测 | `auto_repair_test.dart` |
| M2-A6 | 回归 | ✅ `flutter test` 111/111、`flutter build` 成功、`gradle build` 成功、`m1-client` 6/6 | 本报告 §2/§3、`evidence/m1/e2e-2026-11-02T06-42-22-475Z.json` |

## 5. 当前环境（交回用户时）

| 组件 | 状态 |
|---|---|
| PostgreSQL | 16.10 便携版，`127.0.0.1:5433`，库 `deepseek_remote`（Flyway v3） |
| 后端 | `http://127.0.0.1:8080`，version **0.1.1-m2**，`agentOnline=true` |
| 公网隧道 | `https://<公网隧道>.trycloudflare.com` |
| Agent | `node scripts/serve.ts` 在线（不需要重启后手动重配对） |
| 手机 APK | 根目录 `DeepSeek Remote AI 手机端 v0.1.1-m2.apk`（165,797,632 字节） |
| 一键启停 | `tools\m1-up.ps1` / `tools\m1-down.ps1`（M2 无需改脚本：env 有默认值） |

## 6. 已知限制与遗留

1. **真机通知链路未实测**：本机模拟器不可用，`M2-A1/A2/A3/A5` 只有单测与代码证据；建议装 APK 到真机，连接后锁屏触发一次审批即可闭环（步骤见 §7）。
2. **不做厂商推送**：App 被系统杀掉后收不到审批（前台服务只能降低概率）；彻底解决需接入 FCM/国内厂商通道（约 3–5 人日），未在 M2-α 范围。
3. **通知内不能直接批准**：安全上必须回 App 看完整原始命令再确认；通知只负责"提醒 + 跳转"。
4. **审批等待仍占会话执行槽**：ACP 同一 session 只允许一个 in-flight prompt，审批等待期间该会话不能跑下一条；跨会话并发（默认 2）不受影响。彻底解耦需 M2.1 设计。
5. **后端 token 清理**：过期行只在 pair 时清理；revoked 行保留备查，后续可加定时清理。
6. **app deviceId 仍 `dev_N`**：未改成 26 位稳定 ID（M1.1 遗留），不影响功能。
7. **M1 时代旧 token 需重连一次**（升级一次性成本）。

## 7. 真机补测步骤（给用户）

1. 电脑上：`powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-up.ps1`（或用当前已在跑的服务，记下隧道地址）。
2. 手机装根目录 `DeepSeek Remote AI 手机端 v0.1.1-m2.apk`；打开 → 右上链形图标 → 填隧道地址 + 配对码 `824613` → 测试连接 → 连接 → 允许通知权限。
3. 按 Home 键退到后台（或锁屏）。
4. 电脑上触发一个真实审批：`node tools/m1-approval-hold.ts --base <隧道地址>`（或直接在微信/聊天里让 Harness 做需要授权的写操作）。
5. 预期：手机通知栏出现「有一项操作需要授权」；点通知回到 App 自动弹出审批弹层；点「允许一次」后电脑上文件生成。
6. 保活检查：App 后台 5 分钟后 `curl http://127.0.0.1:8080/api/v1/health` 的 `apps` 仍为 1。

## 8. 下一步（M2 剩余 → M3）

- **M2.1**：`task_events` 独立表 + 断线补偿演练（手机断网 5 分钟，重连后事件不丢不乱序）；审批等待与会话槽解耦。
- 多设备/账号语义、`devices.operating_system` 上报、审计分区、远程桌面 L1。
- 真机联调 + M1.1/M2 UI 截图补齐；后续签名与发布流程。
