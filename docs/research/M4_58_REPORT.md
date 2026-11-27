# M4.58 手机回答提问失败时说清原因（插件 0.2.43，待重启生效）

## 一句话

手机点「提交」回答提问时，插件把「答不上」的四种情况（提问已不在、DSH 没有问答服务、Agent 不在、答案不被接受）原样带回手机，并把 HTTP 404 改成 409——手机不再只显示「接口不存在」，而是告诉你到底哪一步没成。

## 之前的问题

| 现象 | 原因 |
| --- | --- |
| 手机提交提问卡，红条写「回答问题失败：接口不存在（HTTP 404）：请确认地址是 M1 后端的根地址」 | 插件 `answerDesktopQuestion()` 失败时只返回 `false`，`server.js` 一律回 404 `QUESTION_NOT_FOUND`；App 对 404 有固定文案「接口不存在」，把真正原因盖掉了 |
| 用诊断 token 直接 POST 同一个接口，也是 404 | 同上：路由存在、鉴权通过，是 `pageContext.desktopQuestion(...) !== true` |
| 本会话（正在运行）自己发一张提问卡、再用 HTTP 回答，同样 404 | 说明不是「会话已结束」的问题，日志路径 `collectLogQuestions` 能认出提问（`/desktop/pending` 与 events 都带着它），失败在后面的 `userQuestions.answer()` 那一步 |

## 改动

| 文件 | 改动 |
| --- | --- |
| `dsh-plugin-m1/lib/index.js` | 新增 `questionAnswerFailure` 与 `fail(code, message)`；失败码 `QUESTION_NOT_FOUND` / `NO_QUESTION_SERVICE` / `NO_AGENT` / `NOT_CONTINUED` / 异常时用 `error.code ?? error.name ?? 'ANSWER_FAILED'`，同时写日志「手机回答提问失败：<会话> · <码> · <说明>」；Agent 查找加 `agents.list()` 兜底；`pageContext` 新增 `desktopQuestionError()` |
| `dsh-plugin-m1/lib/server.js` | `POST /api/v1/desktop/sessions/<id>/questions/<qid>` 失败时回 **409**（原来 404），body 里带插件给的 `code` 与 `message` |
| `dsh-plugin-m1/test/questions.test.js` | 组装函数时补 `questionAnswerFailure` 声明并暴露 `failure()`；新增「回答失败会说明原因」（五种情况逐一断言）与「服务端把失败原因带回手机」两例 |

为什么用 409 而不是继续用 404：App 的 `messageForHttpError` 对 404 只显示「接口不存在」，而 409 会把服务端的 `message` 拼进提示（「请求失败（HTTP 409）：<原因>」）。这样不用改 App、不用重装 APK 就能看到原因。

## 验收

- `test/questions.test.js`：**20/20**（原 18 + 2）。
- 插件全量 `node --test 'test\*.test.js'`：**178/178**。
- `node --check lib/index.js`、`lib/server.js`：都 exit 0。

## 交付与限制

- 插件 `dsh-plugin-m1/package.json`：`0.2.42 → 0.2.43`。
- **尚未生效**：`plugin_manager` 从 2026-11-25 12:56（本地）起一直返回 `HMR transactions cannot be nested`，`set_bundle` 关/开各试数次都失败；`D:\soft\dsh\appdata\dsh-desktop\plugin-operations\operations.jsonl` 里每条都是 `phase:"started"` → `"application":"failed"`。需要**彻底退出并重新打开 DeepSeek Harness** 一次，才会加载 0.2.43（同时把 M4.57 的「接收文件」路由 0.2.42 一起带上）。
- 重启后再点一次「提交」，如果还失败，红条里的原因（HTTP 409 后面的那句话）就是下一步的线索：`NO_AGENT` 表示会话的 Agent 已不在；`NOT_CONTINUED` 表示这条提问已经不在等待回答；`BAD_ANSWER` 等表示答案本身被 DSH 拒了。

## 下一步

1. 重启 DSH，确认 `/api/v1/health` 的 `version` 变成 `0.2.43`，再试手机提交。
2. 按 409 里的原因把回答链路补完（例如 Agent 不在时提示「这条会话已经结束」而不是让用户重试）。
3. 「工作区 → 接收文件」的真机验证（M4.57 的插件部分）。

## 追加：0.2.44 把「答不上」真正修好（2026-11-25 18:50）

0.2.43 上线后拿到了确切原因：`409 {"code":"NOT_CONTINUED"}`。顺着这条线读 DSH 源码（`D:\soft\dsh\temp\asar-uq\dsh\node_modules\@deepseek-ai\dsh-user-questions\src\index.ts`），弄清了两件事：

1. `userQuestions.answer()` **只认 `continued` 的提问**（`:151` 的 `continued()` 过滤 `state === 'continued'`），还在等回答（open）的提问一律返回 false。open 提问**只能靠 waterfall 的返回值来答**。
2. 水瀑布确实会到插件（`askTimed` 在 `:254` 调 `this.ask({…wait:{callId,timed:true}})`），但 **`req` 里没有 `wait.callId`**，插件只能自己生成 `q_…` 当键；而手机点提交传的是日志里的真实 callId（`call_00_…`），两边对不上 → 查不到挂起项 → 落到 `answer()` → false → 409。

同时发现了第二张卡的来历：`/desktop/pending` 里同一提问会出现两条（日志一条 `call_00_…`、waterfall 一条 `q_…`），而 waterfall 那条只有摘要、没有 `items`，手机就把它渲染成一张没有选项的卡。

**0.2.44 的改法**

| 改动 | 作用 |
| --- | --- |
| 新增 `questionContentKey(entry)`（`sessionId + 题面`），`mergeQuestionEntries` 在按 `questionId` 去重之外再按内容去重 | 同一提问只留一张卡 |
| `listDesktopSessionEvents` 与 `listPendingDesktop` 的合并顺序改成「日志在前、waterfall 在后」 | 留下带 `items`（选项）的那条，卡片能点 |
| `answerDesktopQuestion` 在日志路径之前先按内容找 waterfall 挂起项，找到就 `finish({answers})` | 用日志里的真实 callId 也能把 waterfall 答掉——open 提问唯一走得通的路 |

**验收**：`questions.test.js` **22/22**（新增「手机用日志里的 callId 提交，也能把 waterfall 那条挂起的提问答掉」「同一题面在两路里各有一条时只显示一张卡」）；插件全量 **180/180**；`node --check` 退出码 0；`plugin_manager` 关→开均 `applied`，`/api/v1/health` 回读 `version:"0.2.44"`、`agentOnline:true`。

**真机结果**：自检卡这次带着两个选项、`提交` 可点；手机提交的答案真的回到了工具（`自检3` 收到「忽略」、`自检4` 收到「收到」），卡片在答复后随轮询自己收起。之前那张红条 409 是「同一问题被答过之后再点一次」的残留提示。


## 追加：查到底了——插件收不到这条事件（2026-11-25 19:10）

0.2.46 加了一次性诊断（`traceAnswer` 写 `q-answers.log`），把每次手机提交和 waterfall 的收尾都记下来。结果非常干净：

- 手机上点提交时，确实有 `POST … question=call_00_…  answers=[…]` 这一行，说明请求到了插件的回答接口；
- 但**没有任何一行 `EVENT …`，说明提问监听器一次都没被调用；
- 工具最后收到的答案，是用户在**手机卡的自定义答案框里打字提交**的那一份，而且那条路径上工具的答复正常落地。

再查 DSH 的事件声明（`cordis_inspect_query` 的 Event 目录）：

> `'user-questions/request'(this: Scoped<Agent>, request, next)`
> 描述里写着：*Scope-filtered dispatch (@deepseek-ai/dsh-scope): agent-scoped listeners receive only that agent.*

而 `dsh-user-questions/src/index.ts:344-351` 发射时用的是 `this.ctx.waterfall(scopeTarget(agent, agent), …)`——**目标是那个 Agent 的作用域**。插件把监听器挂在根 `ctx` 上，永远收不到这条事件；至于 `userQuestions.answer()`，它只对「已经 continued（超时过）」的提问有效。

### 现在的取舍

- `0.2.48` 把「answer() 说已经结束」当作成功处理，所以手机上**不再弹红色 409**，卡片也会随轮询收起；
- 但对**还在等回答**的提问，手机选的选项其实传不进那个正在等待的调用——桌面那张卡仍然是唯一能真正结束它的入口。
- 想真正打通，只有两条路：① 手机提交时把选择当作一条用户消息发进那条会话（`promptDesktopSession`，现成能力，立刻可用，但会多一条消息）；② 等 DSH 把 agent 作用域的 answerer 开放给插件。