# M4.54 电脑和手机同时出现同一张提问卡

> 一句话：上一轮为了把电脑上的「确认需求」卡救回来，把提问接管收成「只有手机正看着这条会话才接管」；用户接着要的是**两边同时都有**。翻完 DSH 客户端源码发现根本不用改安装包、也不用写客户端插件——`user-questions/request` 接管时先把 `next()` 叫起来让电脑照常挂原生卡，手机这边也挂一张，两边赛跑：谁先答用谁，另一端自己收掉。

插件 **0.2.35 → 0.2.36**。手机 App 不用换包（仍是 0.4.52+77 / versionCode 77）。

## 之前的问题

M4.53 之后规则是「手机正停在这条会话的直播页 → 手机接管，电脑不出卡；其余时候交回电脑」。用户接着问「怎么才能同时有」——他希望坐在电脑前也能看到卡，同时手机上也能答，而不是二选一。

查 Host 事件目录确认：`user-questions/request` 是 waterfall，只有这一个事件，没有 `user-questions/requested` 之类的广播，也没有「撤销桌面卡片」的接口。所以只从 Host 代码看，这确实像「只能二选一」。

## 关键发现：客户端本来就支持多端同挂一张卡

我把 `<DSH 安装目录>\resources\app.asar` 拆开（自写 asar 读取器：头是 `u32(4) + headerSize + jsonLen + jsonOffset`，JSON 从 offset 16 开始、文件数据基址 `16 + headerSize - 4`），把路径含 `dsh-client` 的 2337 个文件解出来，找到 GUI 那张卡的实现 `@deepseek-ai/dsh-client-ui-user-questions`。它的 README 写得很直白：

- 卡片有两个来源：**活着的 Host 请求**（会转发给每个客户端）+ **Session 的 `userQuestions` 投影**；
- 「Card removal follows the projection」——投影不再列出这个 call，卡片自己收掉（`pending.close()`）；
- 多个客户端可以同时持有同一个 pending 请求：「A browser that reconnects while the tool call is open receives the pending request again」「Another browser … can still settle the shared request」；
- **晚到的答案被静默丢弃**：「when another browser settled the same request first, the gateway drops the late outcome silently」。

也就是说：只要桌面默认问答器 **真的被调用**，电脑就会出卡；而只要手机先答、工具调用结束，Session 投影里不再有这个 call，电脑那张卡会自己消失。两边同时存在完全成立，不需要 DSH 侧的新接口。

## 改动

| 文件 | 改动 |
|---|---|
| `dsh-plugin-m1/lib/index.js` | 提问接管时先 `next()` 让电脑挂原生卡（`Promise.resolve(next())`，同步调用，异常兜 `{ answers: [] }`），桌面答案 `desktopAnswer.then(finish)` 直接收掉这次提问；两个 5 分钟 timer 都 `.unref()`，手机那张卡超时只收手机、不碰电脑那张；注释写明四种走向 |
| `dsh-plugin-m1/test/questions.test.js` | 改 2 例 + 新增 2 例 |
| `dsh-plugin-m1/package.json` | 版本 `0.2.35 → 0.2.36` |

改后的行为：

- 手机正看着这条会话的直播页 → 电脑和手机**同时**出现这张提问卡；
- 电脑先答 → 用电脑的答案，手机那张同时摘掉；
- 手机先答 → 用手机的答案，工具调用结束，电脑那张由投影关闭自动消失（晚到的电脑提交被 gateway 静默丢弃）；
- 手机那张超时（5 分钟）→ 只收手机那张，电脑那张还能继续答；
- 两边都没人答 → 到 5 分钟按「跳过」放行，不让会话挂死；
- 手机没看这条会话 → 和 M4.53 一样，直接交回电脑，不挂手机卡。

## 验收

- `dsh-plugin-m1/test/questions.test.js`（现 13 例）：
  - 「接管后把问题交给手机，回答能解开挂起的 Promise」——`next` 换成可控 promise，断言 `delegated === 1`（电脑卡确实挂出去了），手机 `finish` 后拿到手机答案；
  - 新增「M4.54 电脑先答：用电脑的答案，同时把手机上那张卡摘掉」；
  - 新增「M4.54 手机先答：用手机的答案，电脑那边之后再答也不影响」。
- 插件全量 `node --test 'test\*.test.js'` → **161/161 通过**（原 159 + 2），进程正常退出（5.85s）。
- 反证：把 `desktopPending = Promise.resolve(next())` 临时改成 `Promise.resolve({ answers: [] })`（不再叫桌面）→ 两条新增用例失败（`11 pass / 2 fail`，`deepStrictEqual` 拿到空答案）；恢复后 **13/13**、全量 161/161。
- 踩坑：①两个 5 分钟 timer 会把 `node --test` 进程吊住不退出，用 `process.getActiveResourcesInfo()` 探针看到两个 `Timeout` 后加 `.unref?.()` 解决；②`Promise.resolve().then(() => next())` 会让 `next()` 晚一个微任务才被调用，测试里同步断言 `delegated === 1` 会拿到 0，改成同步 `Promise.resolve(next())`；③排查时又用 pwsh 拼过中文 JS，写乱码——**改文件只用 edit/write 工具**。

## 交付

- 插件代码与测试：**0.2.36**，测试 161/161。
- **已热载生效**：`plugin_manager` 把 bundle `dsh-plugin-m1` 关掉再打开（两次都返回 `application:"applied"`，前几次报的 `HMR transactions cannot be nested` 是之前遗留的未关闭事务，等了一会儿后自行恢复），重载后 `GET /api/v1/health` → `{"version":"0.2.36","agentOnline":true,"apps":1,…}`。
- 手机 App 未改动。

## 限制与下一步

- 两端没有优先级：谁先答用谁，取决于人手速度；如果希望电脑永远优先，需要另做规则。
- 手机那张卡的收掉依赖手机端的轮询/事件刷新（每 1.5–5 秒一次），不是瞬间消失；电脑那张由 Session 投影关闭，通常在同一次刷新里一起消失。
- 窄窗口内的手快：电脑刚答完、手机还没刷新到的那一两秒里，如果在手机上点「提交」，插件会把这次提问当不存在（`QUESTION_NOT_FOUND`），手机上会看到一句「回答失败」。不影响结果（答案是电脑那份），只是提示不好看；要抹平需要改手机 App（接受 404 时提示「这条已经在电脑上答过了」），留到下一次 App 版本一起做。
- 遗留不变：M4.49 的「工作区二级页掉线态」、M4.50 的「电脑端看不到手机新建会话」、M4.51 的「折叠状态不持久」。
