# M4.4 报告：任务完成 / 等待授权通知（手机端）

> 更新：2026-11-13 · 手机端 0.4.4-m4.4（versionCode 31）· 插件 0.2.12（本轮无插件改动）

## 1. 一句话结论

电脑上的任务跑完、失败、被取消，或者停下来等授权时，手机端现在都会发系统通知；等待授权那条通知带「允许 / 拒绝」两个按钮，可以在通知栏里直接决定，点「任务完成」通知会直接切到工作区页。

## 2. 起因与根因

| # | 现象（用户反馈） | 根因 | 修复 |
| --- | --- | --- | --- |
| 1 | 「他这做完了……没有信息通知」 | 只有 `_applyApprovalRequest` / `_notifyDisconnected` 两处会发通知，任务终态只 `_addSystemNotice`（页内提示） | 新增 `task_updates` 通知渠道 + `showTaskUpdate`，任务从 busy 变终态时发 |
| 2 | 任务状态可能来自两条路径 | REST 任务列表（`loadTasks`）和插件桌面镜像（`_loadDesktopTasks`）各自更新 `_tasks` | 两条路径都调用 `_notifyFinishedTasks()`，用 `_taskBusyByKey` / `_taskStatusByKey` 前后对比 |
| 3 | 「……或者是要审核没有信息通知」 | 授权通知没有动作按钮，必须进 App 才能决定 | 新增带「允许 / 拒绝」的常驻通知（`showApprovalAction`），按钮回传 `onApprovalDecision` |
| 4 | 点击通知没有落点 | 通知 Intent 只有 `EXTRA_APPROVAL_ID`，任务通知没有路由信息 | 新增 `EXTRA_NOTIFICATION_ROUTE`（`ROUTE_TASKS` / `ROUTE_APPROVAL`），RootShell 消费后切页 |
| 5 | 重连后可能误报 | 第一次快照没有基线，历史完成态看起来像「刚做完」 | `primeTaskNotifications()` 在连接副作用里把 `_tasksSnapshotPrimed` 复位，首轮只记录基线 |

## 3. 插件端

本轮无改动（保持 0.2.12）。通知完全走 App 原生侧，不需要电脑参与。

## 4. 手机端

### 4.1 Dart

- `lib/models.dart`：新增 `notificationExcerpt(text, {max = 60})`（压空白 + 截断加 `…`）。
- `lib/services/notification_gateway.dart`
  - 新增 `ApprovalDecisionResult{approvalId, approved}`。
  - `NotificationGateway` 新增 `approvalDecisions` 流与 `showTaskUpdate` / `showApprovalAction` / `cancelTaskUpdate`；`MethodChannelNotificationGateway` 处理 `onApprovalDecision` 回调；`FakeNotificationGateway` 记录 `taskUpdates` / `approvalActionShows` / `canceledTaskUpdates` 并提供 `emitDecision`。
- `lib/services/notification_prefs.dart`（新增）：`NotificationPrefs` 读写 `notify_task_done` / `notify_approval_action`（默认全开）。
- `lib/data/live_store.dart`
  - `attachNotificationPrefs` / `notificationPrefs` / `setTaskDoneNotifications` / `setApprovalNotifications`。
  - `_notifyFinishedTasks()`：后台时对「由 busy 变终态」的会话发 `showTaskUpdate`（标题 `任务已完成：<会话名> · <工作区>` / `任务失败了：…` / `任务已取消：…`）。
  - `_showApprovalActionNotice()` / `_cancelApprovalNotice()`：授权通知（id `approval-<approvalId>`），在授权解决、任务终态、断线、回到前台时撤销。
  - `_handleNotificationDecision()`：通知栏按钮的决定与弹窗内决定走同一条 `decideApproval` 链路。
  - `_pendingNotificationRoute`：点任务通知后置 `'tasks'`，RootShell 消费后清空。
- `lib/app.dart`：复用同一个 `MethodChannelSettingsGateway` 给主题与通知开关。
- `lib/screens/root_shell.dart`：监听 `pendingNotificationRoute`，切到工作区页。
- `lib/screens/profile_screen.dart`：「通知」分区新增「任务做完提醒」「等待授权提醒」两个开关；「外观模式」移到新的「外观」分区。

### 4.2 Android 原生

- `NotificationHelper.kt`：新增 `CHANNEL_TASK = "task_updates"`（HIGH，「任务进度」）、`showTaskUpdate`（tag=key，失败用 `CATEGORY_ERROR`）、`cancelTaskUpdate`、`showApprovalAction`（常驻 + 「允许」「拒绝」两个 `PendingIntent`）。
- `NotificationBridge.kt`：新增 `showTaskUpdate` / `showApprovalAction` / `cancelTaskUpdate` 方法；`ACTION_APPROVE` / `ACTION_REJECT` 冷启动与热启动都回传 `onApprovalDecision`；新增 `EXTRA_NOTIFICATION_ROUTE`。

## 5. 验收证据

| 项 | 结果 |
| --- | --- |
| 新增单测 `test/notification_m4_4_test.dart` | 9/9 通过（开关持久化、后台完成通知、前台不发、失败标题、开关关闭不发、授权可操作通知、通知栏允许、文案截断） |
| `flutter test` 全量 | **286/286 通过**（M4.3 277 + 新增 9） |
| `flutter analyze` | 20 issues，无 error（均为历史 warning/info） |
| 回归修正 | `empty_state_test` / `widget_test` 的「我的页」用例因新增两类分区需要滚动，改为 `scrollUntilVisible` 断言 |
| release APK | 71,933,294 bytes，SHA256 `225F9D5F3E1ED19A7E49A7E9AC2E2440FA0CDBAD0A583CCCF9B4DFC8D9000C90` |
| APK 版本 | `versionCode=31`、`versionName=0.4.4-m4.4`、minSdk 24、targetSdk 36 |
| APK 签名 | `CN=Android Debug`，SHA-256 `341ef83b95f452bb50b5a6821aa2044334826971e27910d428abc5dab33f70d6`（与旧包一致，可覆盖安装） |

## 6. 生效步骤

1. 直接安装 `dist/DeepSeek-Remote-latest.apk`（可覆盖旧版）。
2. 首次安装后允许通知权限（App 连接成功时会请求一次）。
3. 把 App 切到后台，在电脑上让一个任务跑完 → 手机通知栏出现「任务已完成：…」。
4. 在电脑上触发一次需要授权的操作 → 通知栏出现带「允许 / 拒绝」的通知，点按钮即可决定。
5. 不需要提醒时到「我的 → 通知」关掉对应开关。

## 7. 已知限制

1. 只在 App 处于**后台**时提醒；前台不发，避免和页面内的状态提示重复打扰。
2. 通知栏按钮的决定依赖 App 进程存活；若进程已被系统杀掉，点按钮只会打开 App。
3. App 被厂商省电策略彻底清理后不会再有通知（厂商推送未接入，对应决策 D-8 的后续）。
4. 会话名取历史会话标题，取不到时退回工作区末段目录名；任务标题在通知里会被截断到 60 字。
5. **本批仍未真机复测**（`adb devices` 无设备），通知渠道、按钮 PendingIntent 与切页行为需要在真机上点一遍。

## 8. 下一步

- 真机复测 M4.2 / M4.3 / M4.4 三条链路（附件落盘、直播计时、通知与通知栏决定）。
- 若需要 App 被杀也能收到通知，考虑接入厂商推送或在插件侧加一个本地 Web Push 中继。
- 任务通知可以进一步带上「完成摘要」（助手最后一条回复的首行），让用户不打开 App 也能知道结果。

## 9. 证据索引

- 单测：`app/test/notification_m4_4_test.dart`、`app/test/notification_flow_test.dart`（M2 原有）
- 原生：`app/android/app/src/main/kotlin/com/deepseek/remote/deepseek_remote_app/NotificationHelper.kt`、`NotificationBridge.kt`
- 构建产物：`dist/DeepSeek-Remote-AI-v0.4.4-m4.4.apk`、`dist/DeepSeek-Remote-latest.apk`、`DeepSeek Remote AI 手机端 v0.4.4-m4.4.apk`
