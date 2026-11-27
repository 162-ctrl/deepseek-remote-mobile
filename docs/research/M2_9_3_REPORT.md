# M2.9.3 · 桌面会话直播（共享屏幕感）

更新：2026-11-10 · 插件 0.2.4 / App 0.2.3+14（`0.2.3-m2.9.3`）

## 目标

用户要的是「共享屏幕的感觉」：手机里能实时看到电脑上那个会话正在做什么 —— 助手说了什么、调了哪个工具、命令输出是什么、是不是在等授权 —— 而不是只有一个任务列表。

按选定范围做成**实时内容镜像**，不做像素级推流：数据来自 Host 的会话事件日志，手机端按秒增量拉取并渲染。

## 数据来源

Host 的 `Session` 对象里有 `log`（Array 子类，按 `seq` 递增的事件日志）和 `header`（`id/cwd/createdAt/...`）。事件形如：

```json
{ "type": "tool/call", "seq": 123, "time": 1762..., "data": { "turn": 3, "step": 1, "callId": "call_...", "name": "pwsh", "arguments": "{\"command\":\"...\"}" } }
```

插件把它翻成手机可直接渲染的条目，跳过 `time-context` 快照与 `step/*`、`job/*` 等噪声。

## 接口

```
GET /api/v1/desktop/sessions/:id/events?afterSeq=&limit=
Authorization: Bearer <配对 token>   （也支持 ?token=）
```

响应：

```json
{
  "sessionId": "s_...",
  "title": "deepseek手机端",
  "cwd": "<项目根>",
  "running": true,
  "lastSeq": 14832,
  "events": [
    { "seq": 14820, "kind": "assistant", "text": "..." },
    { "seq": 14825, "kind": "tool-call", "name": "pwsh", "args": "{\"command\":\"...\"}" },
    { "seq": 14830, "kind": "tool-result", "ok": true, "text": "..." }
  ]
}
```

- 不带 `afterSeq`：返回尾部一屏（用于首屏）。
- 带 `afterSeq`：只返回 `seq > afterSeq` 的增量（用于 1.5 秒轮询）。
- 鉴权复用配对 token（`hub.authorizeToken`），失效 401；会话不存在 404 `SESSION_NOT_FOUND`。

「运行中」判定：`api-session/status` 事件显式为准；插件重载后内存状态丢失，则用日志兜底 —— 最后一条不是 `turn/end` 且发生在 10 分钟内视为运行中。

## App

新增 `DesktopSessionScreen`（`app/lib/screens/desktop_session_screen.dart`）：

- 头部卡：状态点、会话标题、mono 路径、「直播中 / 已结束 · N 条」。
- 消息流：用户右侧浅紫气泡；助手正文 14.5/1.65；工具卡（终端图标 + 工具名 + 可展开的参数，等宽字体）；结果行（绿勾/红叉 + 最多 4 行）；`turn-end` 分隔线；`turn-start` 小标题；授权事件黄色卡片。
- 1.5 秒增量轮询，按 `seq` 去重追加，自动滚到底；下拉可重载尾部。
- 底部固定说明：「实时同步 · 只读，手机端不能插话或审批」。

任务页（`app/lib/screens/tasks_screen.dart`）：插件直连模式下点会议任务卡直接进直播页，不再走 REST 详情。

## 验证

| 项 | 结果 |
|---|---|
| 单测 | `flutter test` **209/209**（新增「桌面会话直播按 seq 增量拉取并映射事件」） |
| 接口 | `?limit=4` 返回 `kinds=assistant,tool-call,tool-result,turn-end`；`afterSeq` 增量正确 |
| 构建 | `dist/DeepSeek-Remote-AI-v0.2.3-m2.9.3.apk`（versionCode 14） |
| 模拟器 | 任务页「进行中 1 / 已完成 3」，运行中的卡片有进度条；点进直播页显示「直播中」与实时工具调用 |
| 截图 | `docs/research/evidence/m2/m2_9_3-tasks-running.png`、`m2_9_3-live-running.png`、`m2_9_3-live-finished.png` |

## 已知限制

- 只读：手机不能插话、不能替电脑审批 —— 这是刻意的安全边界。
- 1.5 秒轮询，不是 WebSocket 推送，弱网下会有秒级延迟；后续可换成 WSS 订阅。
- 工具参数默认折叠，长输出截断到 600 字（避免拖垮手机渲染）。
- 授权事件是否出现在直播流里取决于 Host 是否把 `approval/*` 落进会话日志；没落时仍能从任务状态判断「在等授权」。

## 复现

```powershell
# 1) 插件健康与版本
Invoke-RestMethod http://127.0.0.1:8787/api/v1/health | ConvertTo-Json -Compress

# 2) 拿 token
$pair = Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/api/v1/auth/pair `
  -Body (@{ pairingCode='000000'; clientName='probe'; role='app' } | ConvertTo-Json) -ContentType 'application/json'
$t = $pair.token

# 3) 任务列表 → 取一个 sessionId → 看直播流
$tasks = Invoke-RestMethod http://127.0.0.1:8787/api/v1/desktop/tasks -Headers @{ Authorization = "Bearer $t" }
$id = $tasks.tasks[0].id
Invoke-RestMethod "http://127.0.0.1:8787/api/v1/desktop/sessions/$id/events?limit=20" -Headers @{ Authorization = "Bearer $t" } |
  Select-Object title, running, lastSeq
```
