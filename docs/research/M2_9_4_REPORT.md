# M2.9.4 手机接管：发指令 + 应答授权

日期：2026-11-10
版本：插件 0.2.4 · App 0.2.4+15（`0.2.4-m2.9.4`）

## 目标

M2.9.3 的「桌面直播」只能看。用户在 m03729 明确要写通道：

1. 手机能对电脑上正在跑的会话**继续发指令**（像在旁边接着说）。
2. 电脑弹授权时，**手机能替它点「允许一次 / 拒绝」**，电脑端不用再点。

边界仍是：手机只操作「用户在桌面端自己开着的会话」，不新建会话、不改权限配置。

## 做法

### Host（插件）

| 能力 | 实现 |
|---|---|
| 发指令 | `sessionController.prompt({requestId, sessionId, mode:'queue', content:[{type:'text',text}], clientTimeZone})`；返回 `{accepted:true}` |
| 接管授权 | `ctx.on('approval/request', …)` waterfall：手机 2 分钟内看过该会话（`watchedSessions`）才拦截，否则 `next()` 交给桌面 |
| 授权生命周期 | `pendingApprovals` + `callId` 作为 approvalId；`req.signal` 中断 → `cancelled`；90 秒无应答 → `unavailable` |
| 应答 | `allowed-once` / `rejected` 写回 waterfall 的 resolve 值 |
| 直播流 | 每次 `events` 响应带 `approvals: [{approvalId, toolName, reason, createdAt}]`，并刷新 `watchedSessions` |
| 注入过滤 | `user/message` 若以 `Current runtime context` / `<system-reminder>` / `<hindsight_knowledge>` / `<available_skills>` / `<acp ` / `<user_` 开头则丢弃，只显示人说的话 |

### HTTP 接口（8787，Bearer 配对 token）

- `POST /api/v1/desktop/sessions/:id/prompt`，body `{"text":"…"}` → `{"ok":true,"accepted":true}`；失败 400 `PROMPT_FAILED`。
- `POST /api/v1/desktop/sessions/:id/approvals/:approvalId`，body `{"decision":"approve"|"reject"}` → `{"ok":true}`；未知 id 404 `APPROVAL_NOT_FOUND`。

### App

- `HistoryApi.sendDesktopPrompt` / `decideDesktopApproval`，`LiveStore` 同名包装（自动带 token、401 重试）。
- `DesktopSessionScreen`：
  - 底部输入条「在电脑上继续说点什么…」，发送后清空、SnackBar「已发送到电脑」、立即重拉增量；
  - 直播流里的 `approvals` 渲染成警示卡片：`电脑在等你授权` + 工具名 + 原因 + 拒绝 / 允许一次；
  - 页脚：「实时同步 · 可直接发指令，授权也能在手机上应答」。

## 验证

| 项 | 结果 |
|---|---|
| 单测 | `flutter test` **211/211**（新增「授权随直播流返回」「发指令/应答走 POST」两条） |
| 插件冒烟 | `POST …/prompt` → `{"ok":true,"accepted":true}`；8 秒后该会话 `running=true`，日志出现 `user` 与 `turn-start` |
| 注入过滤 | 过滤后再取 `events?limit=8` 只剩 `turn-end/turn-start/user/assistant/tool-call/tool-result/...`，无 `Current runtime context` 等条目 |
| 模拟器 | 任务页 7 条（进行中 2）；点「测试」→ 直播页底部输入条；手机发 `replyOK` 后会话从「已结束 80 条」变为「直播中」，日志出现 `seq=1048 user text=replyOK`，跑完 87 条 |
| 证据 | `docs/research/evidence/m2/m2_9_4-tasks.png`、`m2_9_4-live-composer.png`、`m2_9_4-after-send.png`、`m2_9_4-feed.png` |

授权拦截的现场触发条件说明：当前权限等级 3（项目文件）下，`pwsh Get-Date` 这类命令会被 Host 直接放行，不会产生 `approval/request`，所以模拟器上没有出现授权卡片；卡片逻辑由单测覆盖，真实触发需遇到 Host 判定为需要审批的工具调用（越界写入、危险命令等）。

## 已知限制

- 手机发指令走 `mode:'queue'`：桌面会话正在跑时，消息排在当前轮之后，不会打断。
- 授权接管只在「手机 2 分钟内看过该会话」时生效；超时 90 秒自动回落到 `unavailable`，桌面仍可处理。
- 只能对已有会话发指令，不能新建会话或切换项目。
- 直播仍是 1.5 秒轮询，不是推送。

## 复现

```powershell
# 1) 插件健康
curl http://127.0.0.1:8787/api/v1/health

# 2) 配对拿 token（示例）
$pair = Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/api/v1/auth/pair `
  -Body '{"pairingCode":"000000","clientName":"probe","role":"app"}' -ContentType application/json
$h = @{ Authorization = "Bearer $($pair.token)" }

# 3) 列会话 → 发指令 → 看事件
Invoke-RestMethod -Uri http://127.0.0.1:8787/api/v1/desktop/tasks -Headers $h
Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8787/api/v1/desktop/sessions/<id>/prompt" `
  -Headers $h -Body '{"text":"reply OK"}' -ContentType application/json
Invoke-RestMethod -Uri "http://127.0.0.1:8787/api/v1/desktop/sessions/<id>/events?limit=10" -Headers $h
```
