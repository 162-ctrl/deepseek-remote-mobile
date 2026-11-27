# M4.24 存档会话在原对话里继续（不再新开一条）

> 一句话结论：手机点开一条「已存档」的会话发话，电脑端**不会再新开一条会话** —— 插件先用
> `workspaceController.unarchiveSession()` 抬起 DSH 的 `ArchivedSessionGate`，再往**同一个
> `sessionId`** 发这句话，手机端就地切成直播轮询。现场实测：`960545fb…` 那条 2 条消息的
> 存档，第 2 轮 `turn/end {kind:'completed'}`、助手回了「收到」，全程只有一条会话。

## 1. 起因

用户（m04651）：

> 不是每个对话新开一条对话，是和电脑上一样的在这个对话里面就一直在，可以加载出来

截图 `2026-11-17T02-51-10-193Z-scaled_1000216920.jpg` 里是工作区页一个项目卡：`16 个会话 ·
1 个进行中 · 最后活动 刚刚`，下面十几条会话全标「已存档」。M4.19 交付的实现是「同目录新开一条
会话 + 把最近 12 句压成摘要当开场」——会话数会越点越多，电脑上多出一堆「接着聊」的新会话，
和电脑端「在同一条对话里一直聊」的体验不一致。

## 2. 排查：`blocked` 到底是谁造成的

M4.19 当时只看到现象：给冷会话 `prompt()` 之后日志里只有

```
23 session/end-seed {}
24 agent/inbox/spliced            （我的 prompt 入队）
25 turn/start {turn:2}
26 agent/inbox/spliced {"removedCount":1,"inserted":[]}
27 turn/end {"turn":2,"reason":{"kind":"blocked"}}
```

一个字都没有，于是绕成「新开会话」。这次直接把 DSH 本体（`resources/app.asar`）当文本检索，
找到了产出 `blocked` 的那段 agent 主循环：

```js
const decision = await this.preStep(target, { turn, step });
if (decision.kind === "reject") {
  turnEnds = { kind: "blocked" };
  return false;
}
```

`preStep` 里唯一能返回 `{kind:'reject'}` 的入口是 waterfall：

```js
const decision = await this.dispatch.waterfall("agent/pre-step", { messages, position, signal, modelSelection }, () => ({ kind: "enter", messages }));
```

再找 `agent/pre-step` 的监听者，命中 `ArchivedSessionGate`：

```js
const ArchivedSessionGate = {
  name: "archived-session-gate",
  inject: ["agents", "sessions", "workspaceRegistry"],
  apply(ctx) {
    ctx.on("agent/pre-step", (payload, next) =>
      underArchivedSession(ctx, payload.agent) ? Promise.resolve({ kind: "reject" }) : next());
  }
};
```

它的注释把话说死了：

> … a late waking delivery to an archived Session … proposes a step the gate rejects, which the
> loop ends as `blocked` without a request; **unarchiving lifts the gate for the whole lineage**.

也就是说：**会话只要还在归档里，任何唤醒都不可能有产出**，跟模型、跟上下文长度都无关。
`underArchivedSession()` 查的是 `ctx.workspaceRegistry.archivedSessionIds`，所以解法是把会话从
归档里放出来，而不是绕开它。

## 3. 改动

### 插件（`dsh-plugin-m1`，0.2.27 → 0.2.28）

`lib/index.js` 里删掉 M4.19 的 `buildArchiveDigest()` / `createSuccessorSession()` 与两个摘要
常量，换成抬门 + 原会话发话：

```js
const resumeArchivedSession = async (sessionId) => {
  const workspaces = ctx.get('workspaceController');
  if (typeof workspaces?.unarchiveSession !== 'function') {
    return { ok: false, code: 'SESSION_UNARCHIVE_UNSUPPORTED' };
  }
  try {
    const result = await workspaces.unarchiveSession({ sessionId });
    const remaining = Array.isArray(result?.archivedSessionIds) ? result.archivedSessionIds : [];
    if (remaining.includes(sessionId)) return { ok: false, code: 'session/still-archived' };
    return { ok: true, code: '' };
  } catch (error) {
    return { ok: false, code: String(error?.code ?? 'session/unarchive-failed') };
  }
};
```

`promptDesktopSession()` 的分支：

| 情况 | 行为 | 返回 / 错误码 |
|---|---|---|
| 会话在电脑列表里 | 直接发，不碰归档门 | `{accepted:true}` |
| 只在存档里 | `unarchiveSession` → 往**同一个** id 发原话 | `{accepted:true, resumed:true, resumedFrom, sessionId}` |
| 抬门返回仍在归档 | 不发话 | `SESSION_NOT_RESUMABLE`「这条存档会话现在接不上：…」 |
| 老 Harness 没有 `unarchiveSession` | 不发话 | `SESSION_UNARCHIVE_UNSUPPORTED`「这台电脑的 Harness 太旧…」 |
| 存档里也没有 | 不发话 | `SESSION_NOT_FOUND`「电脑上已经找不到这个会话了…」 |

`GET/POST /desktop/sessions/<id>/queue`、提问卡、审批等接口都不受影响；`server.js` 的错误映射
沿用 `SESSION_NOT_FOUND → 404`、其余 `→ 400`。

### 手机端（0.4.23+49 → 0.4.24+50）

- `DesktopPromptResult` 新增 `resumed`（`json['resumed'] == true`），`forked` / `forkedFrom`
  保留只为兼容老电脑。
- 存档页说明条改成「存档会话 · 发一句话，电脑会把它接回原来那条对话，接着说」；发送成功后
  不再 `pushReplacement` 跳新会话，而是 `_revived = true` + 就地开直播轮询，toast 改成
  「已把这条会话接回原对话」。
- 工作区页本来就有去重（`_hiddenArchived` 会把「电脑列表里还在的会话」从存档列表里排除），
  所以会话被放出来之后不会一条变两条。

## 4. 验收证据

| 项 | 结果 |
|---|---|
| 插件单测 | `node --test "test/*.test.js"` → **85/85 PASS**（`session-resume.test.js` 整篇重写为 9 例：活跃会话不碰门 / 存档先抬门再原会话发话 / 仍在归档 → `SESSION_NOT_RESUMABLE` / 无 `unarchiveSession` → `SESSION_UNARCHIVE_UNSUPPORTED` / 抛异常 → 不丢堆栈 / 存档没有 → `SESSION_NOT_FOUND` / 空文本先拦 / 无 `prompt` → 不可用 / 结果原样带回） |
| 手机端测试 | `flutter test test/` → **382/382 PASS**；`archive_chat_m4_19_test.dart` 换成 `archive_chat_m4_24_test.dart`（发话后 `liveFetched.first == 'session-499ef7ec'`、`已存档` 消失、回复渲染出来；失败时不假装已恢复） |
| 插件热加载 | `enabled=false → true` 两次 `applied`，`GET /api/v1/health` → `version: 0.2.28` |
| 线上真机接口 | `POST /api/v1/desktop/sessions/960545fb…/prompt` → `200 {"ok":true,"accepted":true,"resumed":true,"resumedFrom":"960545fb…","sessionId":"960545fb…"}` |
| 会话日志（同一会话） | seq 76 `user/message`「M4.24 验证：只回复「收到」两个字。」→ seq 84 `assistant/message`「收到」→ seq 86 `turn/end {"turn":2,"reason":{"kind":"completed"}}`；**没有**新 sessionId |
| 电脑端会话列表 | `/api/v1/desktop/tasks` 里出现 `课程设计 · 14:14 · completed · msgs=17`（9 条任务） |
| APK | 72,836,030 字节，`versionCode=50`、`versionName=0.4.24-m4.24`，SHA256 `74412D78…95EA7877` |

## 5. 构建命令

```powershell
robocopy "<项目根>\app" C:\Users\user\dsh-tools\build\dsh-app /E `
  /XD build .dart_tool .gradle .idea .cxx /XF *.iml   # exit=1 即复制成功
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
cd C:\Users\user\dsh-tools\build\dsh-app; flutter build apk --release
```

（项目路径含中文，AOT 快照会 `Unable to read file …app.dill`，所以必须在 ASCII 目录里构建。）

## 6. 限制与下一步

- 手机端的存档列表（插件自己的 `session-archive.json`）里那条记录还在，只是被「电脑列表里
  也在」的去重挡住不显示；如果用户想看「哪些会话曾被归档」，还得有独立入口。
- `unarchiveSession` 之后该会话就回到电脑的会话列表里，长期下来电脑端会攒回一批会话；
  是否需要「聊完再归档」的选项留给后面。
- 抬门是全局动作：如果同一条会话正在电脑上跑，手机发话仍然走 `mode:'queue'` 排队，不会打断。
- 真机还没复测过一次完整的「点存档 → 发话 → 就地看到回复」流程（接口与日志已证）。
- 遗留：`tools/verify-plugin-m4.ps1` 在 PS 5.1 下仍解析报 15 个 syntax error；锁屏推送提醒未做。
