# M4.19 存档会话也能继续聊

一句话结论：手机上的「已存档」会话不再只能看——发一句话，电脑会在同一个目录里
**新开一条会话**，把存档里最近 12 条对话压成摘要当开场白，之后手机自动跳进这条新会话
接着直播。走「直接唤醒旧会话」和「fork 旧会话」两条路都试过，都被 Harness 挡回来
（前者唤醒后这一轮被 blocked，后者 1235 条消息的会话一 fork 就撑爆上下文窗口），
所以最终选了「新开会话 + 摘要」。

## 起因

用户在手机上打开一个「已存档」的会话，底部写着「这是电脑端存档的会话，只能看不能继续
发指令」，输入框根本没有渲染。用户要求：**已存档的对话手机上也可以对话**。

## 走过的两条死路

| 路线 | 做法 | 实测结果 | 结论 |
| --- | --- | --- | --- |
| A 唤醒旧会话 | `sessionController.resolveAgent(id)` 后直接 `prompt(id)` | `POST /prompt` 返回 `{"ok":true,"accepted":true}`，会话也确实回到 `/desktop/tasks`；但磁盘日志里只有 `turn/start {turn:2}` → `agent/inbox/spliced {removedCount:1, inserted:[]}` → `turn/end {turn:2, reason:{kind:'blocked'}}`，没有 `user/message`、没有 `assistant/message`，消息被吞 | 唤醒只是把会话拉回内存，`session/end-seed` 之后的状态不接受新 prompt，此路不通 |
| B fork 旧会话 | `sessionController.fork({sessionId, allowMigration:true})` 拿一条新 id 再 prompt | 小会话（2 条消息）成功，回复「收到」；**大会话（1235 条消息）失败**：`assistant/attempt` 报 `outbound body measures ~1,735,026 tokens（messages ~153,989 · tools[] ~13,494 · system ~4,560 · other ~1,562,983）vs the effective model window 1,048,576 … the send was stopped at the egress fuse` | fork 会把整段历史搬进新会话，长会话必然超窗，不能作为默认路径 |

顺带产出：`tools/dump-session-log.mjs`（逐帧 zstd 解压任意 session 日志、打印尾部事件，
`node tools/dump-session-log.mjs <sessionId> [tail]`），本次两条死路都是靠它取证的。

## 最终做法

### 电脑端插件（0.2.24）

`dsh-plugin-m1/lib/index.js`

- 新增 `buildArchiveDigest(sessionId, text)`：从存档里取 user/assistant 事件，渲染成
  「用户：…」/「助手：…」两行一条，每条截断到 `ARCHIVE_DIGEST_CHARS = 360` 字，
  只保留最近 `ARCHIVE_DIGEST_MESSAGES = 12` 条；存档里没有对话就直接发原话（不塞空摘要）。
  摘要外面包一层「（接着电脑上的一条存档会话继续聊《标题》，下面是它最近的对话，供你参考）」
  …「（历史到此结束，下面是用户的新消息）」。
- 新增 `createSuccessorSession(sessionId)`：`sessionController.create({ cwd: record.workspace })`
  —— **在原目录里**新开一条会话；Harness 没有 `create` 时返回 `SESSION_CREATE_UNSUPPORTED`。
- `promptDesktopSession` 改成三段：活跃会话直接发；存档里也没有 → `SESSION_NOT_FOUND`；
  否则新开会话 + 发摘要，返回 `{ ...result, forked: true, forkedFrom, sessionId: 新会话 }`。
  错误码区分 `SESSION_NOT_FOUND` / `SESSION_CREATE_UNSUPPORTED` / `SESSION_NOT_RESUMABLE`，
  不把原始堆栈丢给手机。
- `dsh-plugin-m1/lib/server.js`：`POST /api/v1/desktop/sessions/<id>/prompt` 的
  `SESSION_NOT_FOUND` 映射成 404，其余 400 `PROMPT_FAILED`。

### 手机端（0.4.19+46）

- `app/lib/screens/desktop_session_screen.dart`：存档页也有输入条了；说明条改成
  「存档会话 · 发一句话，电脑会把它恢复成一条新会话，接着在这里聊」；
  发送成功后若 `forked` 且 `sessionId` 变了，用 `pushReplacement` 直接跳进新会话页面
  （标题沿用原名），从此按直播轮询。
- `app/lib/services/history_api.dart` / `app/lib/data/live_store.dart`：
  `sendDesktopPrompt` 返回 `DesktopPromptResult { sessionId, forked, forkedFrom }`。

## 验收证据

| 项目 | 结果 |
| --- | --- |
| 插件测试 | `node --test "test/*.test.js"` → **66/66**（M4.19 新增 `session-resume.test.js` 9 例） |
| 手机端测试 | `flutter test test/` → **371/371**（M4.19 新增 `archive_chat_m4_19_test.dart` 2 例） |
| 端到端（真手机 token） | `POST /desktop/sessions/session-4670a31a…/prompt` → `200 {"ok":true,"accepted":true,"forked":true,"forkedFrom":"session-4670a31a-…","sessionId":"session-6d1042d4-973b-4ce1-990d-d05871e678a7"}` |
| 新会话内容 | seq 8 user =「（接着电脑上的一条存档会话继续聊《我是一名课程计算机学生，只》…）用户：先停止 助手：好，先停在这里…」，**seq 17 assistant「收到」**，seq 19 turn-end |
| 失败路径 | 不存在的会话 → `404 {"code":"SESSION_NOT_FOUND","message":"电脑上已经找不到这个会话了（可能被清理或换了目录）"}` |
| 热加载 | `plugin_manager set_bundle` disable→enable 两次 `applied`，`/api/v1/health` → `version 0.2.24` |

## 构建命令

```powershell
robocopy "<项目根>\app" C:\Users\user\dsh-tools\build\dsh-app /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
flutter build apk --release
```

产物：**72,720,862 字节**，SHA256 `7D80801736990E9BA845A0E16C938CEC7235765FD060F7103D8B75D61A3EF89C`，
`versionCode 46 / versionName 0.4.19-m4.19`，minSdk 24 / targetSdk 36。已发三处：
`dist/DeepSeek-Remote-AI-v0.4.19-m4.19.apk`、`dist/DeepSeek-Remote-latest.apk`、
根目录 `DeepSeek Remote AI 手机端 v0.4.19-m4.19.apk`（同哈希）。

## 限制与下一步候选

- **不是「续上同一条会话」**：电脑上会多出一条新会话（标题沿用原名），旧存档仍在存档里。
  这是刻意的：唤醒旧会话会被 blocked、fork 长会话会超窗，摘要开场是唯一稳定的路。
- 摘要只带最近 12 条、每条 360 字：聊得很长的存档，更早的上下文会丢。可以按需调大，
  但别一次塞太多，否则又把窗口顶满。
- 「同一目录里新开会话」依赖 Host 的 `sessionController.create({ cwd })`；老版本 Harness
  没有这个方法，手机会收到「这台电脑的 Harness 太旧」。
- 待做候选：①存档列表里直接给「接着聊」按钮；②新会话标题标一个「续」字，便于在电脑端
  分辨哪条是从存档接过来的；③摘要条数/长度做成可配置。
