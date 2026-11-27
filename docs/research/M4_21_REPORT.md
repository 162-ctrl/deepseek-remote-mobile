# M4.21 手机端也要有「N 条排队消息」

一句话结论：电脑端在一轮还在跑的时候，会把后面排着的话列成「4 条排队消息」，每条能
改字、能删、能插话（Cmd/Ctrl+Enter 是全部插话）；手机端以前完全没有这个概念——排队的话
只能等它自己轮到，想改一个字都没法子。现在直播页底部也浮出同一条面板：折叠时写「4 条
排队消息」，展开后逐条列出，能改字（弹框）、能删、能单条插话，也能一键「全部插话」把它们
立刻送进这一轮。数据全部来自 Host 的 `sessionController.state()` / `updateQueue()`，
插件 0.2.26 只做形状转换与错误码翻译。

## 起因

用户截图（电脑端 DSH 对话页）后说：「这个功能手机上也得有」——截图里一条用户消息下面
跟着「4 条排队消息」折叠面板，四行排队内容右侧各三个图标：编辑 / 删除 / 上移，面板下方
提示「Cmd/Ctrl+Enter 插话发送全部排队消息」。

顺带这次读到用户自己排队的四条（`session-55cdd3b7…` 的队列），其中三条是还没处理的诉求：

1. 「输入时搜索框里面不显示」——手机上搜索框输入时没有候选/提示。
2. 「这个需要审核操作的手机上还是没有」——授权（审核）操作手机上仍然不出现。
3. 「不是每个对话新开一条对话，是和电脑上一样的在这个对话里面就一直在，可以加载出来」
   —— 存档会话不要新开一条，要像电脑端那样在同一条对话里继续。

## 契约取证

`cordis_inspect_query(host, provider='Service', method='listService', input={service:'sessionController'})`：

| 成员 | 形状 | 关键点 |
| --- | --- | --- |
| `state(request, signal)` | `SessionStateRequest { sessionId }` → `SessionState { cursor; active; running; queue; pendingInput }` | **`signal` 必填**，内部会 `signal.throwIfAborted()`；漏传就报 `Cannot read properties of undefined (reading 'throwIfAborted')` |
| `queue[]` | `SessionQueuedItem { id; placement: 'queued' \| 'steering' \| 'context'; rpcId?; content: readonly JsonValue[] }` | 只有 `placement === 'queued'` 的还能改 |
| `updateQueue(request)` | `{ sessionId; itemId; action: QueueAction }` → `{ accepted: true }` | 描述是「Mutate one still-pending queue occurrence, resuming a cold Agent first」 |
| `QueueAction` | `{ kind: 'edit'; content: TextBlock[] } \| { kind: 'remove' } \| { kind: 'steer' }` | **没有 moveUp**：电脑端那个上箭头就是 `steer`（插话） |

## 改动

### 插件（`dsh-plugin-m1/`，0.2.25 → 0.2.26）

- `lib/index.js`
  - `queueItemText(item)`：把 `content` 里的文本拼起来；有非文本 part 时补「（另有 N 个附件）」，
    纯附件消息也不会显示成空白（实测队列里三条都带截图附件）。
  - `readDesktopQueue(sessionId)` → `{ supported, running, active, items: [{id, placement, text}], error }`；
    Host 没有 `state` 时 `supported: false`，Host 抛错时把错误码收进 `error` 而不往手机端抛。
  - `mutateDesktopQueue(sessionId, itemId, action, text)`：`remove` / `steer` / `edit` 翻成
    `QueueAction`，空 id、改空内容、未知操作一律 `QUEUE_BAD_REQUEST`，没有 `updateQueue`
    则是 `QUEUE_UNSUPPORTED`，成功后回读一次队列给手机。
  - `pageContext` 增加 `desktopQueue` / `desktopQueueUpdate`，并删掉 M4.19 遗留的
    `desktopFork: (sessionId) => forkDesktopSession(sessionId)`（函数早已删除，属于潜在的
    `ReferenceError`）。
- `lib/server.js`：`GET|POST /api/v1/desktop/sessions/<id>/queue`，GET 读队列、POST 读
  `{ itemId, action, text }` 改队列，都要 App token；`QUEUE_BAD_REQUEST` → 400，其余 500。
- `test/queue.test.js` 新增 7 例：队列压形状、附件文案、`signal` 不能漏、无能力 / Host 报错 /
  三种 action 翻译 / 空 id 与空内容与未知操作 / 错误码透传。插件全套 **76/76**。

### 手机端（`app/`，0.4.19+46 → 0.4.21+47）

- `lib/services/history_api.dart`：`DesktopQueueItem { id, placement, text, pending }`、
  `DesktopQueue { items, running, supported, error }`、`fetchDesktopQueue()` / `updateDesktopQueue()`。
- `lib/data/live_store.dart`：两个同名包装，未连接时给中文提示。
- `lib/screens/desktop_session_screen.dart`：
  - `_load()` 尾部非存档会话时读队列；`_queue` / `_queueOpen` / `_queueBusy` 三个状态。
  - `_applyQueueAction()` 改完用返回的队列刷新，失败弹 SnackBar；`_editQueueItem()` 用
    `AlertDialog` + `TextField` 改字；`_steerAllQueue()` 对 `pending` 项顺序插话。
  - `_QueuePanel`（折叠行 + 「全部插话」+ 提示「插话＝立刻送进这一轮（电脑端是
    Cmd/Ctrl+Enter）」）、`_QueueRow`（非 pending 显示「插话中」）、`_QueueIconButton`。
- `test/desktop_queue_m4_21_test.dart` 新增 6 例：展开列条目与 4 组 tooltip、删除后剩 3 条、
  改字用新内容、单条插话、全部插话按顺序、空队列不显示面板。`flutter test` **377/377**。

## 验收证据

| 项 | 命令 / 动作 | 结果 |
| --- | --- | --- |
| 插件单测 | `node --test "test/*.test.js"` | 76/76 PASS |
| 手机端测试 | `flutter test test/` | 377/377 PASS |
| 端到端读队列 | 真手机 token `GET /api/v1/desktop/sessions/session-55cdd3b7…/queue` | 200，`supported: true`，4 条 `queued`（含附件文案） |
| 鉴权 | 不带 token 调同一路径 | 401 |
| 空队列 | 另一条 running 会话 | 200，`items: 0`（面板不显示） |
| 热加载 | `plugin_manager set_bundle enabled=false→true` | 两次 `applied`，`/api/v1/health` → `0.2.26` |

## 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd "C:\Users\user\dsh-tools\build\dsh-app"
flutter build apk --release
```

> 项目路径含中文，AOT 快照会崩在 `app\.dart_tool\flutter_build\<hash>\app.dill`，
> 必须先复制到纯 ASCII 目录再构建。

## 限制与下一步

- 队列只在**直播页**读；手机端没有本地队列，所有改动都即时打到 Host（断网会直接报错）。
- 改队列没有并发保护：两端同时改同一条，后到的覆盖先到的（Host 侧没有版本号）。
- `<id>` 队列面板每 1.5 秒随直播轮询刷新，展开时如果队列变短，展开状态保留、行数跟着变。
- 用户排队里的另外三条诉求（搜索框输入无提示、审核操作手机上缺失、存档会话不要新开会话）
  本轮没做，需要各自单独设计。
