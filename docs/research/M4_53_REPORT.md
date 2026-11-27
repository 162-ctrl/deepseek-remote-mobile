# M4.53 插件的提问接管改回「只看手机在看哪条会话」

> 一句话：M4.31 为了「手机不在直播页也能答题」，把 `user-questions/request` 的门禁改成了「手机连着就接管」；结果手机一上线，电脑上的「确认需求」卡就不再出现。这轮把门禁收回成和授权一致的口径——**只有手机正停在这条会话的直播页时才接管**，其余时候交回电脑弹窗。

插件 **0.2.34 → 0.2.35**。手机 App 不用换包（仍是 0.4.52+77 / versionCode 77）。

## 之前的问题

用户在电脑前报「电脑上的这个审核怎么没了」，截图是手机「桌面直播」页：`示例项目A` 会话正挂着「电脑在等你回答（2 个问题）」，三个选项、跳过 / 提交都在，会话也在跑（293 次工具调用）；而电脑上那张同名的「确认需求」卡完全没出现，只看得到会话停在那里。

根因在 `dsh-plugin-m1/lib/index.js` 的提问监听：

```js
const phoneOnline = () => Number(hub?.appCount ?? 0) > 0;
ctx.on('user-questions/request', async function onDesktopQuestion(req, next) {
  const sessionId = ...;
  const watching = isWatching(sessionId);
  if (!watching && !phoneOnline()) return next();   // ← M4.31
```

`user-questions/request` 是 **waterfall**：插件返回一个答案就算接管，桌面的默认问答器（`next()`）根本不会被调用。手机 App 只要求「连着」（`appCount > 0`，前台后台都算），所以插件恒接管、电脑恒不出卡。授权走的是另一条 `approval/request`，它的门禁一直只有 `isWatching`，所以只有提问有这个问题。

顺带查了 Host 的事件目录：只有 waterfall `user-questions/request`，**没有** `user-questions/requested` 这类广播事件。因此「两端同时出卡、任一端都能答」做不到——接管了桌面就不出卡；先 `next()` 让电脑出卡，手机这边再回答也没有通道把电脑那张卡收掉。

## 改动

| 文件 | 改动 |
|---|---|
| `dsh-plugin-m1/lib/index.js` | 提问门禁改成 `if (!isWatching(sessionId)) return next();`；删掉 `phoneOnline`；注释保留 M4.31 的来由，并写明 M4.53 为什么收回、以及「两端同时显示做不到」的原因 |
| `dsh-plugin-m1/test/questions.test.js` | 新增 2 例 |
| `dsh-plugin-m1/package.json` | 版本 `0.2.34 → 0.2.35` |

改后的语义：

- 手机正停在这条会话的「桌面直播」页（5 秒轮询内看过它）→ 手机接管，电脑不出卡；
- 手机没看这条会话、或 App 没连 → 交回电脑，电脑照常弹「确认需求」卡；
- 和授权（`approval/request`）现在是同一条规则，不再有两套口径。

## 验收

- `dsh-plugin-m1/test/questions.test.js` 新增：
  - 「M4.53 手机连着但没看这条会话时，提问仍交回电脑」——`isWatching: () => false` + `phoneOnline: () => true`，断言 `next()` 被调用 1 次、`pendingQuestions` 为空、返回值就是 `next()` 的结果、没有「接管提问」日志；
  - 「M4.53 提问接管只看 isWatching，不再看手机在不在线」——截出 handler 源码前 400 字符，断言不再出现 `phoneOnline`、且门禁是 `if (!isWatching(sessionId)) return next();`。
- 插件全量 `node --test 'test\*.test.js'` → **159/159 通过**（原 157 + 2）。
- 反证：把门禁临时改回 `const watchingTemp = isWatching(sessionId); if (!watchingTemp && !phoneOnline()) return next();`，第二条用例失败（`ERR_ASSERTION`，actual 的函数体里含 `phoneOnline`），恢复后 159/159。
- 生效验证：`plugin_manager` 把 bundle `dsh-plugin-m1` 关掉再打开，`GET /api/v1/health` → `{"status":"ok","version":"0.2.35","agentOnline":true,"apps":1,…}`（旧实例报的是 0.2.34）。

## 交付

- 插件 **0.2.35**，已热重载生效（不需要重开 DSH，也不用换 APK）。
- 测试：插件 159/159；手机 App 未改动，`flutter test` 仍 527/527。

## 限制与下一步

- **重载会丢掉内存里挂起的提问**。这一条是 M4.31 留下的老账：插件把提问挂在 `pendingQuestions` 的 Promise 上，重载会把旧模块连同 Promise 一起丢掉，那条提问只能等到 5 分钟超时按「跳过」放行。本次重载时那条提问已超过 5 分钟、已自行超时，因此没有用户可见影响；以后热重载插件要避开正挂着的提问。
- **手机在看这条会话时，电脑仍然不出卡**。这是 waterfall 的单向接管决定的，不是遗漏；要做到「两端都能答」需要 Host 提供广播型提问事件或「撤销桌面卡片」的接口，当前事件目录里没有。
- 遗留不变：M4.49 的「工作区二级页掉线态」、M4.50 的「电脑端看不到手机新建会话」、M4.51 的「折叠状态不持久」。
