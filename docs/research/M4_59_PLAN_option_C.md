# 方案 ③：让手机 App 直接说 DSH 的 Web 客户端协议（预研与实施计划）

> 目标：手机变成「第二个浏览器客户端」——GUI 那张提问卡怎么来的，手机就怎么来；
> 电脑和手机同时有卡，任一端答完，另一端随投影自己收掉。
>
> 这份是**预研 + 施工计划**，不是已完成的功能。

## 一、为什么值得做

现在的插件是「旁路」：自己的 HTTP 接口（8787）+ 自己的待答清单 + 自己的轮询。
DSH 的提问事件是 agent 作用域派发的，插件从根 ctx 注册收不到（见 M4_58 报告），
所以手机永远差一层。

浏览器客户端不一样：它本身就长在那套 remote 协议里，`ctx.remote.$on('user-questions/request')`
能收到，`answer` 能回传。手机如果按同一套协议连上来，就天然是「第二个客户端」，
不需要 DSH 改任何东西。

## 二、已经查实的协议事实（都有出处）

| 事实 | 出处 |
| --- | --- |
| GUI 那张卡就是客户端订阅 `ctx.remote.$on('user-questions/request', …)`，回调里 `answerQuestion(ctx, this, request, next, cards)` | `@deepseek-ai/dsh-client-ui-user-questions/src/client/index.ts:400-402`（asar 解出） |
| 客户端走 WebSocket 承载事件流，`openConnectionWebSocket(path, factory, baseUrl)` 把 `/channel/endpoint` 变成 `ws(s)://…` | `dsh-client-connection/src/client/socket.ts:56-66` |
| 一元调用是 HTTP：`POST /<channel>/<endpoint>`，body `{ type:'client-request', rpcId, method: endpoint, payload }`，响应 `{ type:'server-response', … }` | `dsh-client-connection/src/client/rpc.ts:44-70`、`src/rpc.ts:81-95` |
| 认证是 cookie（`dsh-auth-*`），由启动令牌在 `/connect` 换取 | `dsh-client-connection/src/browser-auth.ts:15-19`、`src/connect-protocol.ts:7` |
| **但 loopback 请求可以免令牌过浏览器信任栅栏**：Host 是回环名（127.0.0.1 / localhost）即通过，非浏览器与远程客户端也走这条 | `dsh-client-connection/src/api-request-trust.ts` 文件头注释 + `isLoopbackHostname` |
| 提问请求带 `wait: { callId, timed: true }`，超时后转 `continued` 才认 `answer()` | `dsh-user-questions/src/index.ts:237-260`、`docs/subsystems/user-questions.md:204` |

还差的一块（施工第一步就要补）：**事件流的帧格式**（`server-event` / 流的打开与取消）。
它在 `@deepseek-ai/dsh-typert-protocol` 里，还没解出来——第一步就是把它和其它
`dsh-*` 包一起从 `app.asar` 解出来读，半小时内能补全。

## 三、架构：插件当「反代」，手机只说一套协议

```
Flutter App ──(已配对的 8787, Bearer token)──> dsh-plugin-m1 ──(loopback)──> DSH Web 服务 127.0.0.1:<gui-port>
   │                                             │
   └── /api/v1/gw/* ──────────────────────────────┘  反代 HTTP + WebSocket 升级
```

为什么不让手机直连 DSH 的 Web 端口：

1. DSH 的 web 服务只听回环，手机根本连不上；
2. 直连就要另做一套认证（`/connect` 换 cookie），和现有的扫码配对是两套凭据；
3. 插件里做反代，手机继续用**已有的配对 token**，端口、隧道、鉴权全部复用，改动面最小。

反代实现要点：

- HTTP：`/api/v1/gw/<channel>/<endpoint>` → `http://127.0.0.1:<gui-port>/<channel>/<endpoint>`，
  原样转发 body 与 `content-type`，Host 头写成 `127.0.0.1:<port>`（回环即过信任栅栏）。
- WebSocket：在插件的 `node:http` server 上监听 `upgrade` 事件，对 `/api/v1/gw/*` 的升级请求
  用 `net.connect` 连本机 web 端口、手写 101 转发、双向 pipe（标准 ws 反代，约 60 行）。
- 通道白名单：只放行需要的（`/typert/…` 之类），避免把整个 GUI API 暴露给手机。

## 四、Flutter 侧要写什么

新增 `app/lib/services/dsh_remote/`：

1. `rpc_client.dart`：HTTP 一元调用（帧就是上面那三个字段），带 rpcId 关联与超时。
2. `event_stream.dart`：`WebSocket`（`dart:io` 自带）连接 `/api/v1/gw/…`，解析事件、
   断线指数退避重连、重连后重新订阅。
3. `user_questions.dart`：订阅 `user-questions/request`，把请求转成现有的卡片模型
   （字段对齐 `AskUserQuestionRequestEvent`：`questions[].id/header/question/options/multiSelect`、
   `wait.callId`），提交时调 `answer` 一元方法。
4. 与现有 UI 合流：`desktop_session_screen` 的卡片、`tasks_screen` 的横幅都从这份订阅来，
   原来的轮询可以保留做兜底。

## 五、分四步走，每步都能单独验收

| 步骤 | 做什么 | 验收 |
| --- | --- | --- |
| ① 解协议 | 从 asar 解出 `dsh-typert-protocol` 等包，补全事件流帧格式与 `answer` 的通道名 | 写一页协议笔记，能照着发一条请求并收到响应 |
| ② 反代 | 插件加 `/api/v1/gw/*`（HTTP + WS 升级） | `curl` 经手机同一个地址、同一个 token 能打通 GUI 的某个只读接口 |
| ③ 手机订阅 | Flutter 里打通「订阅 → 日志里打印收到提问事件」 | 我提一个问题，手机 App 日志出现该事件 |
| ④ 接线 UI | 事件 → 现有卡片；提交 → `answer` | 电脑和手机同时有卡；任一端答完，另一端自己消失 |

## 六、工作量与风险

- ① 半天（纯读代码）；② 半天到一天（WS 反代最容易踩坑：升级握手、背压、关闭码）；
  ③ 一天（重连与订阅恢复）；④ 半天（现有 UI 已经写好了，只是换数据源）。
  **合计约三天**，中间任何一步卡住都不影响现有功能（插件旁路还在）。
- 风险 1：DSH 升级可能改事件流帧格式 → 反代只做透传，不解析帧，升级影响面小；
  解析集中在 `event_stream.dart` 一处。
- 风险 2：手机端长连接耗电与断网重连 → 已有 `PollCoordinator` 的退避思路可复用。
- 风险 3：反代把 GUI API 暴露给手机 → 通道白名单 + 复用配对 token（未配对仍 401）。

## 七、和另外三条路的关系

- ①（提交转成用户消息）：一小时的临时解，先做也不冲突，之后可以留着做兜底。
- ②（自建提问工具）：不依赖 DSH 协议，但要让模型改用我们的工具，侵入 agent 侧。
- ④（只读镜像）：③ 做完就没必要了。

**结论**：③ 是唯一能「双端同卡、任一端都能答、不改 DSH 本体」的路；
按上面四步做，第一天就能看到手机收到真实提问事件。
