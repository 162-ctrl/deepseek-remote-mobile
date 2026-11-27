# M4.23 · 电脑端「确认需求」的提问卡，手机上也能回答

> 交付：电脑端插件 `0.2.27`、手机端 `0.4.23+49`（`0.4.23-m4.23`）。
> 一句话结论：用户说的「审核操作」不是权限审批，而是 `ask_user_question` 工具弹的**提问卡**；
> 它走 Host 的 `user-questions/request` waterfall，而插件以前只接了 `approval/request`——
> 于是电脑上正等着人选项，手机上什么都没有。

## 1. 一句话结论

插件新增 `user-questions/request` 接管：手机正在看这个会话时，把问题挂在
`GET /desktop/sessions/<id>/events` 的 `questions` 字段里下发；手机渲染成可选项卡片，
选一项（或自己写一段）后 `POST /desktop/sessions/<id>/questions/<questionId>` 把
`{answers}` 交回 Host；点「跳过」发空答案；5 分钟没人应答按跳过放行、并把这一轮交回电脑。

## 2. 起因

用户排队里的一句话：「这个需要审核操作的手机上还是没有」，附一张电脑端截图：

- 会话「示例项目E」，卡片标题「**歌词样式**」，问「歌词字幕想要什么形式？」；
- 三个选项：手写体 / 衬线字（推荐）、干净的无衬线白字 + 细描边、竖排歌词；
- 下面有「输入你的答案」，右下角「跳过 / 提交」，右上角「**2/2**」翻页。

这张卡不是审批（没有「允许一次 / 拒绝」），而是 `ask_user_question` 工具在等人选。

## 3. 排查与根因

| 排查项 | 结果 |
| --- | --- |
| 会话日志里有没有提问事件 | 没有。`ask_user_question` 在日志里只是普通 `tool/call`（`session-e2e1f57b` 的 seq 880，`"name":"ask_user_question"`），紧接着 seq 881 就是 `tool/result` |
| 那手机从哪拿问题 | 拿不到——Host 把它做成了一次 waterfall 事件，不落日志 |
| Host 事件表 | `user-questions/request`（waterfall）：「Ask composed answerers for structured user input. Return an answer to claim the request or call `next()` to delegate.」 |
| 插件已有的接管 | 只有 `ctx.on('approval/request', …)`（M4.4 起），所以提问一律走 `next()` 交回桌面弹窗 |

关键类型（`cordis_inspect_query` 于 `Event` provider）：

```ts
AskUserQuestionRequestEvent {
  questions: AskUserQuestionItem[];
  agent?: Agent;
  signal?: AbortSignal;
  wait?: { callId: ToolCallId; timed?: boolean };
}
AskUserQuestionItem { id; question; detail?; header?; options?; multiSelect?; intent? }
AskUserQuestionOption { label; description? }
AskUserQuestionAnswer { answers: AskUserQuestionAnswerItem[] }
AskUserQuestionAnswerItem { id; selected: string[]; custom?: string }
```

## 4. 改动

### 电脑端插件 0.2.27（`dsh-plugin-m1/`）

- `lib/index.js`
  - `QUESTION_TIMEOUT_MS = 5 * 60 * 1000`、`pendingQuestions`（`questionId → { sessionId, questions, finish }`）。
  - `ctx.on('user-questions/request', async function onDesktopQuestion(req, next) {...})`：
    取 `sessionId = req.agent.id`（兜底 `this.agent.id`）；**只在手机看着这个会话时**接管
    （`isWatching`，和授权同一条 10 分钟窗口），否则 `next()` 交回桌面；
    `questionId` 优先用 `req.wait.callId`（和工具调用对得上），没有就自己生成；
    超时与 `signal` 中断都按「跳过」放行，日志写明原因。
  - `answerDesktopQuestion(sessionId, questionId, rawAnswers)`：会话不匹配或 id 不存在返回 `false`；
    `normalizeQuestionAnswers()` 丢掉空项、`selected` 去空白、`custom` 去空格——两者都空则不回答这一项。
  - `listDesktopSessionEvents()` 多回一个 `questions` 数组（`finish` 是函数，不下发）。
- `lib/server.js`：`POST /api/v1/desktop/sessions/<id>/questions/<questionId>`，
  body `{ answers: [{ id, selected, custom? }] }`；成功 `{ ok: true, answered: N }`，
  未知 id → 404 `QUESTION_NOT_FOUND`，非 App token → 401。

### 手机端 0.4.23+49（`app/`）

- `services/history_api.dart`：`DesktopQuestionOption` / `DesktopQuestionItem` /
  `DesktopQuestion` / `DesktopQuestionAnswer`，`DesktopSessionFeed.questions`，以及
  `answerDesktopQuestion(...)`。
- `data/live_store.dart`：`answerDesktopQuestion(sessionId, questionId, answers: …)`。
- `screens/desktop_session_screen.dart`：
  - `_questions` 与 `_load()` 同步；`_answerQuestion()` 提交后摘掉这张卡、toast、重拉；
  - 标题栏徽标从「待应答 N」扩展成「待回答 N」（提问也会拦住电脑上的这一轮）；
  - 新增 `_QuestionCard`：问题、`detail`、单/多选项行、可选的自定义输入框，
    底部「跳过 / 提交」（没选也没写字时提交禁用，发送中显示「发送中…」）；
  - 卡片位置在「过程 · N 次工具调用」条之前——和电脑端一样，卡在这一轮正文之上。

## 5. 验收证据

| 项目 | 结果 |
| --- | --- |
| 插件 `node --check lib/index.js` / `lib/server.js` | 通过 |
| 插件 `node --test "test/*.test.js"` | **85/85 PASS**（新增 `test/questions.test.js` 9 例：答案压缩、跳过、别人的会话答不了、`finish` 不下发、只有看着才接管、接管后能解开挂起的 Promise、无 `callId` 时自造不重样） |
| 手机端 `flutter test test/` | **382/382 PASS**（新增 `test/desktop_question_m4_23_test.dart` 3 例） |
| 线上 `GET /desktop/sessions/<id>/events` | 响应键为 `sessionId,title,cwd,running,lastSeq,events,approvals,questions`，`questions` 为空数组（此刻没有待答问题） |
| 线上 `POST …/questions/nope` | `404 {"code":"QUESTION_NOT_FOUND","message":"question not found"}` |
| 线上回答不带 token | `401` |
| `/api/v1/health` | `"version":"0.2.27"`（热加载生效，无需重开 DSH） |

## 6. 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd "C:\Users\user\dsh-tools\build\dsh-app"; flutter build apk --release
```

> 路径里有中文，直接在 `app/` 里构建会在 AOT 快照那一步失败（`Unable to read file: D:\<乱码>\…app.dill`），
> 所以必须先 robocopy 到纯 ASCII 目录。

## 7. 限制与下一步

- **真机还没跑过一次真实提问**：`ask_user_question` 要由电脑上的那一轮触发，而我这轮没法在
  自己的会话里触发它（会把自己挂住）。线上验证的是字段与接口边界（上面第 5 节），
  卡片本身的渲染由 widget 测试覆盖。等下一次电脑端弹「确认需求」，手机上应出现同一张卡。
- 卡片不翻页：电脑端右上角是「1/2」，手机上一屏把几页顺着列出来。
- 没做「多选 + 自定义同时提交」以外的富交互（比如选项里的 `intent: approval` 分支），
  目前一律按普通选项处理。
- 手机端仍是「看着才接管」：页面一关（10 分钟窗口过后）提问就回到电脑弹窗，没有推送通知。
