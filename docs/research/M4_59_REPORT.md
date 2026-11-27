# M4.59 手机原生回答提问（DSH Web 客户端协议）

## 一句话结论

插件现在自己就是 DSH 的一个「浏览器客户端」：Host 派发的提问 `waterfall` 事件它能收到，手机提交的答案经它用 `$events/result` 回给 Host，实测 `{"ok":true}`，工具立刻拿到用户在手机上选的选项。**不改 DSH 安装包，也不需要手机说新的协议。**

## 之前的问题

| 现象 | 根因 |
| --- | --- |
| 电脑上有提问卡，手机上什么都看不到（M4.55 前） | 插件根 `ctx` 的监听器收不到 `user-questions/request`：它是 agent 作用域事件，DSH 用 `ctx.waterfall(scopeTarget(agent, agent), …)` 发射 |
| 手机上能看到卡，但提交后答案不生效（M4.56–M4.58） | 插件只能从会话日志里「猜」待答提问，再调 `userQuestions.answer()`；而它只对 `continued`（超时之后）的提问有效，open 提问直接返回 false |
| 卡片没有选项、提交置灰 | 日志路与 waterfall 路各生成一条摘要，手机按摘要渲染，`items` 为空 |
| 提交后弹 `HTTP 409 这条提问已经不在等待回答` | 电脑先答了，插件再调 `answer()` 失败；0.2.48 之后改成「按成功处理」，但答案是丢的 |

## 关键发现（协议来自 DSH 自己的源码）

从 `<DSH 安装目录>\resources\app.asar` 解出 `@deepseek-ai/dsh-api-gateway`：

- 通道：WebSocket `/api/remote.mux`；客户端发
  `{ "type": "open", "streamId": "…", "endpoint": "$events", "payload": { "args": {} } }`
- 下行：`{type:'item', streamId, value}`，`value` 是 `ready` / `emit` / **`waterfall`** / `cancel`
- 回答：`POST /api/$events/result`
  ```json
  { "type": "client-request", "rpcId": "…", "method": "$events/result",
    "payload": { "args": { "clientId": "…", "eventId": "…",
      "outcome": { "kind": "result", "value": { "answers": [ … ] } } } } }
  ```
  注意 `payload` 必须恰好只有一个 `args` 字段，否则报
  `typert gateway: Remote event result requires exactly one plain-object args field`。
- 认证：回环地址也不白名单，`GET /?token=…` 302/303 + `Set-Cookie`；插件用
  `ctx.get('connection').authenticatedUrl()` 自己签一个就能登进去。
- 连接会被服务端 5 秒左右关掉，除非回 WebSocket ping：必须回 pong。

## 改动表

| 文件 | 改动 |
| --- | --- |
| `dsh-plugin-m1/lib/remote-events.js`（新） | 登录 → 手写 WebSocket 升级 → 发 `open` → 解帧 → `handle.answer()` 回 `$events/result`；补 pong 心跳、ping/pong 帧、关闭帧处理、连接失败重试 |
| `dsh-plugin-m1/lib/index.js` | `remoteQuestions` 存远程提问；`remoteQuestionEntries()` 合并进 `/desktop/pending` 与会话详情的 `questions`；`answerDesktopQuestion()` 优先走远程路径（`handle.answer`），并把答案以 waterfall 返回值交回 Host；连接失败按 3 秒退避重试 60 次 |
| `dsh-plugin-m1/test/questions.test.js`、`pending.test.js`、`session-events.test.js` | 注入表补 `remoteQuestions` / `dropRemoteQuestion` / `remoteQuestionEntries`，源码断言跟着改 |

## 验收（真机）

插件 `0.2.60` 热载后，本会话发起一张提问卡，用户在**手机**上作答：

```
REMOTE waterfall user-questions/request eventId=6b1b552e-05a9-40b7-a5d7-0f075ff5fae2
WATERFALL keys=questions session=session-bd6f7b64-… items=1
POST session=session-bd6f7b64-… question=6b1b552e-… answers=[{"id":"phone1","selected":["手机上提交成功"]}]
REPLY 6b1b552e-… → HTTP 200 {"result":{"ok":true}}
```

- `ask_user_question` 返回的就是用户在手机上点的选项
- 插件全量测试 **182/182** 通过，`node --check` 两个入口文件均 0
- 手机端不需要换 APK（仍用 0.4.57），因为卡片的列表与提交都走既有接口

## 限制与下一步

- 远程客户端只在 `<DSH 数据目录>\dsh-plugin-m1\remote-client.on` 存在时启动（现在是开着的）；诊断日志写在 `q-answers.log`
- `WATERFALL` 的 `request` 只有 `questions` 字段，`sessionId` 是从帧的 `agentId` 兜回来的
- 每次热载可能留下上一版实例（日志里同一 eventId 出现两条 REPLY），需要在热载前主动关闭旧连接
- 手机端仍是「轮询 + 卡片」的形态，还不是真正的推送；下一步可以把 `emit` 里的会话活动接进直播页，减少轮询
