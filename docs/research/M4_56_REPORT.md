# M4.56 从会话日志认提问，手机终于能看到并回答

一句话：手机上看不到提问卡，不是门禁没放宽，而是**那条事件根本到不了插件**——DSH 的问答工具走的是「客户端决定」的路径，不派发 `user-questions/request`。改成从会话日志里认「还没结果的 `ask_user_question` 调用」，再用官方的 `userQuestions.answer()` 交回答案，手机侧就通了。

## 之前的问题

- 用户先说「电脑上的这个审核怎么没了」（M4.53），又说「怎么才能同时有」（M4.54），再报「手机上还是没有」（M4.55）。
- M4.53 把门禁从「手机连着就接管」收成「手机正看着这条会话才接管」，电脑的卡回来了、手机没了。
- M4.54 改成双端赛跑（先 `next()` 让电脑出卡，同时给手机挂一张），但真机验证仍然是「电脑上有，手机上没有」。
- M4.55 把门禁放宽成「手机连着就接管」（`isWatching || phoneConnected`），理论上手机该收到了——**真机仍然没有**。

## 追查：事件根本没到插件

- 在监听器入口和门禁前后各写一行文件日志（`qdebug.log`），等一次真实提问：**只有 `watch` 行，没有 `event` 行**——`ctx.on('user-questions/request', …)` 一次都没被调用。
- 插件版本号读的是 `package.json`（每次 `readFileSync`），`/api/v1/health` 显示新版本**不能**证明代码已加载；这次靠 `boot.log` 的 apply 标记确认热载确实换了代码，所以不是「没生效」，而是「没事件」。
- 查 DSH 源码文档 `docs/subsystems/user-questions.md`：提问有两条路——
  - `userQuestions.ask()`：scoped answerer waterfall，会派发 `user-questions/request`；
  - `userQuestions.askTimed(request, callId, timeoutMs)`：「Foreground wait whose first settlement the Client decides」，GUI 的卡片走这条，**不派发 waterfall**。
- `ask_user_question` 走的是后者。插件以 waterfall 参与的那条路，对这类提问永远收不到。

## 改动（`dsh-plugin-m1/lib/index.js`）

| 改动 | 说明 |
|---|---|
| `collectLogQuestions(sessionId)` | 读 `getDesktopSession(id).log`：先收集所有 `tool/result` 的 **`toolCallId`**（实测结果事件用的是这个字段，`callId` 是空的）为「已回答」，再找 `tool/call` 且 `name === 'ask_user_question'`、callId 未回答的项；`JSON.parse(arguments).questions` 拿到题面，`questionId` 直接用 `callId` |
| `serializeQuestionItems()` | 把题面压成下发给手机的 `{id, header, question, detail, multiSelect, options}`，两路共用 |
| `mergeQuestionEntries()` | waterfall 来的 + 日志里认出来的，按 `questionId` 去重（先到先得） |
| 会话详情负载 | `questions` 从「只读 `pendingQuestions`」改成两路合并，手机打开会话就能看到卡 |
| `listPendingDesktop()` | 同样合并所有 live 会话的日志提问，「工作区」的待回答横幅也能出现 |
| `answerDesktopQuestion()` | 先走原来的 `pendingQuestions` 路径；查不到时认日志提问，取 `agents.get(sessionId)` 拿 Agent，用 `userQuestions.answer(agent, callId, { answers })` 交回；「跳过」按每题 `{id, selected: []}` 生成完整批次，避免 `BAD_ANSWER` |
| 清理 | 去掉 M4.55 留在 `index.js` 里的三处临时诊断写盘（`boot.log`、两处 `qdebug.log`） |

保留原 waterfall 监听：老路径（`userQuestions.ask()`）仍会用到它。

## 验收

- `dsh-plugin-m1/test/questions.test.js`：**18/18**（新增 4 例：日志路径回答、日志路径跳过、日志识别源码断言、`collectLogQuestions` 行为用例——同时给已答/未答/非问答工具/坏 JSON 四种输入，只挑出 1 条）。
- 插件全量 `node --test 'test\*.test.js'`：**166/166**（原 162 + 4），进程正常退出。
- 反证：把 `if (!callId || settled.has(callId)) continue;` 临时改成 `if (!callId) continue;`（等于把「已回答」也算成待答）→ 行为用例失败（`17 pass / 1 fail`），改回后 18/18。
- 连带修复：`test/pending.test.js`、`test/session-events.test.js` 的源码注入表补上 `ctx / collectLogQuestions / mergeQuestionEntries / serializeQuestionItems`，此前 9 例因 `ReferenceError` 失败。

## 交付

- 插件 `0.2.41`（`package.json`），`plugin_manager` 关再开 bundle `dsh-plugin-m1` 两次返回 `application: "applied"`；`GET http://127.0.0.1:8787/api/v1/health` → `{"version":"0.2.41","agentOnline":true}`。
- 0.2.40 真机试了一次，手机上一口气冒出 8 张空卡：结果事件的 `callId` 是空的、真正的 id 在 `toolCallId`，所以「已回答」的判定全落空，这条会话里所有历史提问都被当成待答。0.2.41 修成 `toolCallId ?? callId ?? message.source.callId`，并把测试样本改成真实形状（反证：只认 `callId` 时两条用例失败）。
- 手机 App 未改动，仍是 **0.4.52+77**；不需要换 APK。
- 热载会重启公网隧道、`publicUrl` 会变，手机需要重新连一下（同局域网时它连的是 LAN 地址，不受影响）。

## 限制与下一步

- 手机看到卡的前提是手机连着插件（`apps > 0`），并且会话是「电脑上还活着」的 live 会话；已归档会话的日志不在 `sessions.list()` 里，暂时认不到。
- 手机先答后电脑那张卡仍靠 Session 投影自动收掉；电脑刚答完、手机还没刷新那一两秒里在手机上点提交会看到「回答失败」（结果不受影响）。
- M4.55 的 `isWatching || phoneConnected` 门禁保留在原 waterfall 路径上，对走 `askTimed` 的提问不起作用，但留作老路径的兼容。
- 遗留仍没做：M4.49 工作区掉线态、M4.50 电脑端看不到手机新会话、M4.51 折叠状态不持久。
