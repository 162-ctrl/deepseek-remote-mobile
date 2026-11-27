# M4.50 工作区「新会话」：不再建一个谁都看不见的会话，直接送去对话框

**一句话**：以前点「新会话」是让电脑端 Agent 子进程在磁盘上建一个空会话——它落在 Agent 进程里，电脑端主进程的会话表没有它，手机工作区页又只列电脑端主进程的表，于是**两头都看不见**；现在改成「绑目录 + 切到 AI 助手的『远程电脑』+ 聚焦输入框」，用户发第一条消息时才真正建会话。

## 之前的样子（2026-11-23 22:29 用户截图）

- 工作区详情页「示例项目C」：空态「这个工作区还没有会话」+「点「新会话」让电脑在这个目录里开一个…」+ 主按钮「在这里新建会话」，底部输入条灰着，提示「这个工作区还没有会话，先新建一个会话」。
- 点「在这里新建会话」只弹一句「已请电脑在「示例项目C」里新建会话」，页面照旧空态，输入框照旧灰着。
- 电脑端「会话」列表里也没有这一条。
- 磁盘上其实**建出来了**：`<DSH 数据目录>\sessions\--D-~4E07~660A~6797-~9879~76EE-~4EBA~751F~8BB0~5F55~7CFB~7EDF--\97e99c63-b2cc-4ebf-8394-09451e3ffa73\session.v4.jsonl.zstd`（343 字节，22:29:12 改写），解出来只有一行 header：

  ```json
  {"type":"session","version":4,"id":"97e99c63-b2cc-4ebf-8394-09451e3ffa73","createdAt":1795444151747,"cwd":"D:\\Projects\\示例项目C","isSeeded":false,"delegationDepth":0}
  ```

## 为什么两头都看不到

```
手机「新会话」→ conversation.create
   → 插件 hub 转发给 Agent
      → Agent 的 ACP 子进程 session/new → 磁盘落一个空会话（在 Agent 进程里）
手机工作区列表 ← GET /api/v1/desktop/tasks ← 电脑端主进程内存里的 sessions
电脑端会话列表 ← 同一份主进程内存
```

- 插件 `dsh-plugin-m1/lib/index.js:1516 listDesktopTasks()` 读的是 `ctx.get('sessions').list()`；`getDesktopSession()` 也只查 live 会话。
- DSH 的 `sessions` 服务自述：「In-memory session store… Persistence is intentionally not implemented here — a session published outside that lifecycle persists nothing」。
- 所以：Agent 进程里有的会话，电脑端主进程不认；手机只问主进程，两边都看不到。**不是没创建，是创建的会话没有归宿。**
- DSH 另有一个 `sessionQuery` 服务（「live-preferred」）能同时看到活会话与磁盘会话，但那是查询层；要让手机新建的会话出现在电脑端列表，得把它镜像进主进程的 `sessions`——会和 ACP 子进程抢同一个会话文件，风险高，这轮不做。

## 改动

| 文件 | 改动 |
|---|---|
| `app/lib/services/remote_chat_intent.dart`（新增） | `RemoteChatRequest{workspacePath}` + `RemoteChatIntent` 单例（`open()` / `pending` / `take()`），沿用 `CloudChatIntent` 的单例广播写法 |
| `app/lib/data/live_store.dart` | 新增 `startNewConversation({workspacePath})`：绑目录并清空旧会话状态（`_conversationId` / `_sessionId` / `_messages` / `_taskState` / `_queuedPrompt` / `_conversationRequested`…），下一次 `sendPrompt` 才 `createConversation()` |
| `app/lib/screens/workspace_screen.dart` | 删掉 `_bindAndHint` / `_createSession` / `_renameSession`（都是发完即忘、不跳转），合并成 `_startNewChat()` = 绑目录 + 广播意图 + `Navigator.pop`；AppBar「新建会话」、空态主按钮、文字链、FAB、输入条 `onTap` 全指向它；空态文案改「点下面的按钮去 AI 助手的『远程电脑』里发第一条消息」；输入条由 `enabled: hasTask` 改 `readOnly: !hasTask`（点一下也去对话框） |
| `app/lib/screens/tasks_screen.dart` | 新增 `onOpenAssistant` 并透传给 `WorkspaceScreen` |
| `app/lib/screens/root_shell.dart` | `TasksScreen(onOpenAssistant: () => _select(0))`：切回 AI 助手 Tab |
| `app/lib/screens/assistant_screen.dart` | 监听 `RemoteChatIntent` → 切「远程电脑」档 + `startNewConversation()` + 聚焦输入框；电脑还在忙时只记目录并提示「电脑还在忙这一条，等它结束再开新会话」；新增 `@visibleForTesting modeForTest` |

## 验收

- 新增 `app/test/new_chat_m4_50_test.dart` **3/3**：
  1. 意图进来后模式从 `phone` 变 `desktop`、`startNewConversation` 收到目标目录、不弹「两档差别」的说明；
  2. 电脑忙时不新开会话，只记下目录并提示；
  3. 意图只消费一次。
- 改 `app/test/workspace_m4_test.dart`（「没有会话时引导去对话框，输入条只读」：断言 `readOnly`、点按钮后回调 1 次、绑了目录、意图带路径）与 `app/test/tasks_m4_11_test.dart`（点空工作区卡 → 工作区页 → 点「去对话框发第一条消息」→ 已 pop、目录已绑、意图已发）。
- 反证：把 `_startNewChat()` 里的 `RemoteChatIntent.instance.open(...)` 注释掉 → 上面两例失败（`Expected: 'D:\Projects\示例项目B'`、`Expected: 'D:\work\demo'`），恢复后 23/23 通过。
- 全量 `flutter test` = **516/516 全通过**（原 513 + 新增 3）。
- `flutter analyze --no-pub` = **32 issues、0 error**（与改前同数，全是既有告警）。

## 交付

| 项 | 值 |
|---|---|
| App 版本 | `0.4.50+75`（`versionName 0.4.50-m4.50`） |
| APK | **73,213,886 字节** |
| SHA256 | `17668D5BED32266A61E2A3B10AD8573BA9FBB4D55B5DFA00ECA4C3D447985EA0` |
| 签名 | debug（`C=US, O=Android, CN=Android Debug`），可直接覆盖已装版本 |
| 同哈希四处 | 构建产物、`dist/DeepSeek-Remote-AI-v0.4.50-m4.50.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.50-m4.50.apk` |
| 发布校验 | `tools/verify-release.mjs` 四项一致（applicationId / versionCode 75 / versionName / size + sha256 与接口回读一致） |
| 接口回读 | `/api/v1/app/version` → versionCode 75、`0.4.50-m4.50`、size 73213886、sha256 `17668d5b…` |

## 限制与下一步

- **电脑端仍看不到手机新建的会话**：手机上现在发第一条消息时会走 `sendPrompt` → `createConversation()` → Agent 建会话，仍然落在 Agent 进程；电脑端那份内存表还是不知道它。要彻底修得让 Agent 建完会话后把 id 报回电脑端并登记（`sessionPersistence` / `workspaceRegistry`），再决定谁写日志——涉及并发写同一个会话文件，要先设计再动。
- 工作区二级页在「已连上但 Agent 掉线」时仍显示「电脑端还没有配置工作区（M1_WORKSPACE_ROOT）」（M4.49 遗留），下一步改成掉线态 + 重试。
- 本机没有真机，这轮只有 `flutter test` 与 APK 构建级验证；「点新会话 → 跳过去 → 发第一条消息」的真机链路待补测。
