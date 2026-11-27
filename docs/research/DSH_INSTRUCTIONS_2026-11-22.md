# 交给 dsh 的修改指令（2026-11-22 代码复查后）

> 每一条都是**自包含**的：文件路径、当前现状、要改成什么、怎么算做完。
> 可以一条一条发给 dsh，不必一次全发。
>
> 基线（改动前先跑一遍确认）：
> - 插件：`cd dsh-plugin-m1 && node --test "test/*.test.js"` → **106 / 106 pass**
> - App：`cd app && flutter test test/` → **466 / 466 pass**
>
> 任何一条改完，这两个数字都只能**变大或不变**，不能变小。

---

## 第 0 条（前置）：先重启一次 DSH，把已经改好的两处 bug 生效

**这条不用改代码，只是操作。**

`dsh-plugin-m1/lib/hub.js` 和 `dsh-plugin-m1/lib/server.js` 已经修了两个 bug（见文末附录），
但插件还跑在旧进程里，**必须完整重启 DSH 才会加载新代码**。

操作：

1. 完全退出 DSH（不是关窗口，是退出进程），重新启动。
2. 重启后确认插件版本仍是 `0.2.30`（`GET /api/v1/health`）。
3. 顺手验证两个修复都在：
   - 会话进行中把 agent 杀掉 → 同一个会话还能继续发消息（不再永久返回 `SESSION_BUSY`）
   - `curl -X POST /api/v1/desktop/sessions/s1/prompt -d '{坏json'` → 回 **400 `BAD_REQUEST`**（不再是 500 `INTERNAL`）

**这一条没做，后面的手测都测不出真实效果。**

---

## 第 1 条（P0）：抽屉和顶栏的「历史会话」是死链，永远空白

### 现状（已核实）

- `app/lib/data/live_store.dart:615` 调 `_historyApi.conversations(...)`
- `app/lib/services/history_api.dart:1169` → `static const String conversationsPath = '/api/v1/conversations';`
- 但插件**从来没实现过这个路由**。在 `dsh-plugin-m1/lib/` 和 `agent/src/` 里
  搜 `api/v1/conversations` 是**零命中**（那是 `backend/` 这个已停用的 Spring Boot 老后端的接口）。
- 结果：手机端每次拉都 404 → `liveStore.conversations` 永远是空数组。

两个入口都受这个影响：

| 位置 | 代码 | 症状 |
|---|---|---|
| 抽屉「历史会话」 | `app/lib/screens/root_shell.dart:300-321` | 永远显示「还没有历史会话」 |
| AI 助手页顶栏「历史」按钮 | `app/lib/screens/assistant_screen.dart:266 _showHistory()`，按钮在 `:627-633` | 点开空弹层 |

`PROJECT_STATUS.md` 里 M4.41 / M4.42 的「未做」栏已经自己记了这条（「待定修它还是删它」），现在决定：**修，不删**。

### 改法

**数据源换成插件真实存在的接口**，也就是桌面会话镜像 + 存档，这两个页面里已经在用了：

- `app/lib/screens/workspace_screen.dart:86`（`_openArchived`）和 `:141`（`_openSession`）
- `app/lib/screens/tasks_screen.dart:186 / 388 / 401`

具体：

1. **抽屉「历史会话」**（`root_shell.dart`）
   - 不再用 `liveStore.conversations`，改用一个新 getter，比如
     `List<DesktopSessionOption> get recentDesktopSessions`（放在 `live_store.dart` 里）：
     - 取 `live.tasks`（桌面会话/任务镜像，字段有 `id` / `title` / `lastTime` / `workspace`）
     - 再并上 `live.hiddenArchivedSessions`（`live_store.dart:296`，已经写好，是「存档里有、当前列表里没有」的那些）
     - 按 `lastTime` 倒序，最多 12 条（现在 UI 也是截 12 条）
   - 点击 → `Navigator.push` 到 `DesktopSessionScreen`：
     - 活会话：`DesktopSessionScreen(liveStore: ..., sessionId: task.id, title: task.title, lastTime: task.lastTime)`
     - 存档会话：多加 `archived: true`（照 `workspace_screen.dart:86-95` 的写法抄）
   - 空态文案：连上了但没有会话 → 「电脑上还没有会话」；没连 → 「连接电脑后显示历史会话」
   - 注意 `root_shell.dart:292` 那个数字角标也要一起改成新数据源的长度

2. **顶栏「历史」按钮**（`assistant_screen.dart:266 _showHistory()`）
   - 把里面的 `await live.loadConversations()` 改成 `await live.loadTasks()`（会顺带补 `loadArchivedSessions`）
   - 弹层里的 `live.conversations` 换成同一个新 getter，`ListView` 每一项的点击改成 push `DesktopSessionScreen`
   - `:630` 的 `live.conversationsLoading` 换成 `live.tasksLoading`
   - 或者更省事：`_showHistory()` 直接改成 `_select(1)` 切到「工作区」页——但**必须二选一做完，不能留空函数**

3. **不要删 `loadConversations` / `conversationsPath`**：留着，但加注释说明它是老后端的接口，
   插件直连下必然 404，不要再用。`live_store.dart:604 loadConversations()` 目前还被
   `ensureLiveData()`（`:1285`）和 `_refreshAfterReconnect()`（`:1299`）调着，会白打一次 404 请求，
   **把这两处调用去掉**。

### 验收

新增 `app/test/drawer_history_m4_43_test.dart`：

1. 注入一个已连接、带 2 条 `TaskItem` 的 liveStore → 打开抽屉，「历史会话」下面出现这 2 条的标题，
   **不出现**「还没有历史会话」
2. 点其中一条 → push 出 `DesktopSessionScreen`
3. 未连接 → 显示「连接电脑后显示历史会话」
4. 反证：把 getter 改回返回空列表，第 1 例必须失败

跑完 `flutter test test/` 全绿。

---

## 第 2 条（P0）：token 无限累积，已经攒了 223 条且全部长期有效

### 现状（已实测）

```
tokens.json 位置：D:/soft/dsh/.dsh/dsh-plugin-m1/tokens.json
总条数 223 | 未过期 223 | 已过期 0
按角色：{ agent: 189, app: 34 }
不同 deviceId：195 个
```

**正常情况 agent token 只该有 1 条**（一个电脑一个 agent）。现在有 189 条。

### 根因链（已逐层核实）

1. `dsh-plugin-m1/lib/supervisor.js:101-108`：agent 进程退出后自动重启，
   `Math.min(30_000, 1000 * 2 ** Math.min(this.#attempts, 5))` 指数退避，**没有次数上限**。
2. `dsh-plugin-m1/lib/supervisor.js:63-75`：启动 agent 时 env 里只给
   `REMOTE_SERVER_URL` 和 `M1_PAIRING_CODE`，**从来不给 token**。
3. `dsh-plugin-m1/agent/scripts/serve.ts:113 pairAgent()`：每次启动都
   `POST /api/v1/auth/pair`（`role: 'agent'`）换一个新 token。
4. `dsh-plugin-m1/lib/hub.js:165-186 pair()`：
   ```js
   const token = randomBytes(24).toString('hex');
   const expiresAt = new Date(Date.now() + 30 * 24 * 3600_000);   // 30 天
   const deviceId = role === 'agent' ? ulid() : `dev_${this.#nextDeviceId++}`;  // ← 每次都新
   this.#tokens.set(token, record);
   this.#persistTokens();
   ```
   **无条件生成新 token，从不清理旧的**，而且 agent 的 `deviceId` 每次都是新的 `ulid()`，
   连「同一个电脑」都认不出来。
5. `hub.js:110-129 #restoreTokens()`：启动时**会跳过**已过期的 token（`:118`），
   但**不会把剔除后的结果写回盘**，所以文件里过期的也永远留着。

净效果：agent 重启 189 次 → 189 条永不失效的 token。文件里任何一条泄漏出去都是完整的 app/agent 权限。

### 改法（三层，建议全做；只做第 2 层也能止血）

**第 1 层 · 让 agent 复用 token（治本，少打一次 pair）**

- `supervisor.js`：启动 agent 前，从 stateDir 读 `agent-token.json`
  （和 `tokens.json` 同目录，`lib/index.js:285` 那个 `stateDir`），存在就放进 env：
  ```js
  env.M1_AGENT_TOKEN = savedToken
  ```
- `serve.ts`：模块顶部读 `process.env.M1_AGENT_TOKEN`。
  `main()` 里如果它非空就**跳过** `pairWithRetry()`，直接用。
- `serve.ts`：给 `RelayClient` 注入 `urlRefresher`（`relay-client.ts:84` 有这个选项，
  `:338 / :435` 已经在 token 失效时回调它，只是现在没注入）：
  - 回调里重新 `pairAgent()` → 把新 token 写回 `agent-token.json` → 返回新 ws url
  - 这样一个 token 能用 30 天，失效了才换一次

**第 2 层 · hub 侧按设备去重（关键，即使第 1 层没做也不会再涨）**

`hub.js:165 pair()`：

1. agent 的 `deviceId` 改成**稳定值**，不要再 `ulid()`：
   ```js
   const stableKey = String(clientName ?? '').trim() || 'agent';
   const deviceId = role === 'agent' ? `agent:${stableKey}` : `dev_${this.#nextDeviceId++}`;
   ```
   （`clientName` 由 `serve.ts:48` 传入，值是 `hostname()`，同一台机器稳定）

2. 生成新 token **之后**，清理同一 `role + deviceId` 的旧记录，只留最新 2 条
   （留 2 条是为了容错：旧连接还没断时新 token 已经在用了）：
   ```js
   // 同一设备只保留最新 2 条 token：老连接可能还在用上一条，
   // 但更早的必然已经废弃，留着只是把 tokens.json 变成 token 垃圾场
   const sameDevice = [...this.#tokens]
     .filter(([, r]) => r.role === role && r.deviceId === deviceId)
     .sort((a, b) => b[1].expiresAt - a.expiresAt);
   for (const [oldToken] of sameDevice.slice(2)) this.#tokens.delete(oldToken);
   ```
   放在 `#persistTokens()` 之前。

**第 3 层 · 卫生：过期清理 + 主动撤销**

1. `hub.js #restoreTokens()`：记录有没有剔除过行，剔过就 `#persistTokens()` 回写，
   别让过期记录永远躺在文件里。
2. 新增 `revokeToken(token)` 方法（`hub.js` 里，照 `authorizeToken` 的位置放）：
   ```js
   /** 主动撤销一个 token（用户「断开这台设备」时调用）。 */
   revokeToken(token) {
     const key = String(token ?? '');
     if (!this.#tokens.has(key)) return false;
     this.#tokens.delete(key);
     this.#persistTokens();
     return true;
   }
   ```
3. 新增路由 `POST /api/v1/auth/revoke`（`lib/server.js`，放在 `pair` 附近 `:185` 一带）：
   - 从 `authorization: Bearer <token>` 取 token
   - 调 `hub.revokeToken(token)`，成功回 `200 {ok:true}`，不存在回 `404 {code:'TOKEN_NOT_FOUND'}`
   - 不需要额外鉴权——能拿出这个 token 本身就有权撤销它
4. **一次性清理现存 223 条**：写个 `dsh-plugin-m1/tools/prune-tokens.mjs`，
   读 `tokens.json`，保留每个 `role+deviceId` 最新 2 条 + 所有未过期的 app token，其余删掉，
   写回前先备份成 `tokens.json.bak-<时间戳>`。**跑之前把备份路径打出来给用户确认。**

### 验收

新增 `dsh-plugin-m1/test/token-hygiene.test.js`（用现成的 `M1Hub` 直接测，不用起服务）：

1. 同 `role='agent'` + 同 `clientName` 连 pair 5 次 → `tokens.json` 里 agent 记录 **≤ 2 条**
2. 两个不同 `clientName` 各 pair 3 次 → 各自 ≤ 2 条，互不影响
3. 过期记录在 `#restoreTokens()` 后被写回盘（构造一条 `expiresAt` 是昨天的，存盘、新建 hub、再读文件，那条不在了）
4. `revokeToken` 后 `authorizeToken` 立刻返回 false

另外 `prune-tokens.mjs` 先在**备份副本**上跑一遍，打印 before/after 条数。

---

## 第 3 条（P1）：手机端 token 明文存在 App 私有目录

### 现状

`app/lib/services/session_store.dart`：

- `:53` `final dir = await getApplicationSupportDirectory();`
- `:45` `SessionStore({this.fileName = 'session.json'});`
- `:72` `Future<void> save(SavedSession session)` 把 `serverUrl` / `token` / `deviceId` / `savedAt` 一起明文写进 `<support>/session.json`

`app/pubspec.yaml` 里**没有** `flutter_secure_storage`，只有 `path_provider`。

App 私有目录不是加密的：root 过的机器、`adb backup`、厂商云备份都能把它带走，
而 token 是 30 天有效的完整控制权（配合第 2 条，现在还能拿到 223 条里的任意一条）。

### 改法

1. `app/pubspec.yaml` 加依赖：
   ```yaml
   flutter_secure_storage: ^9.2.2
   ```
2. `session_store.dart` 拆成两层：
   - **敏感字段**（只有 `token`）→ `FlutterSecureStorage`，key 用 `'session_token'`
   - **非敏感元数据**（`serverUrl` / `deviceId` / `savedAt`）→ 继续写 `session.json`
   - `load()`：从 secure storage 读 token，从 json 读其余；**任何一边缺了就当没登录**（返回 null）
   - `save()`：token 写 secure storage，其余写 json
   - `clear()`：两边都清
3. **迁移**：`load()` 时如果 json 里还有旧 `token` 字段：
   - 读出来 → 写进 secure storage → **从 json 里删掉 token 字段重写一次**
   - 这样老用户升级后不用重新配对
4. Android 的 `minSdkVersion` 检查一下（secure_storage 9.x 要求 18+，正常都满足）；
   `flutter_secure_storage` 在 Android 上默认用 EncryptedSharedPreferences，首次运行要有一点点 IO 延迟，
   `load()` 别放在 build 里同步调（现在也不是，OK）。

### 验收

新增 `app/test/session_store_secure_m4_43_test.dart`：

1. `save()` 之后，`session.json` 文件**文本里搜不到那个 token 字符串**
2. `load()` 能完整恢复 `serverUrl` / `token` / `deviceId`
3. 老格式（json 里有明文 token）能被 `load()` 迁移出来，迁移后 json 里 token 字段没了
4. 反证：把 token 也写回 json，第 1 例必须失败

> 测试里 `FlutterSecureStorage` 需要 mock（用 `TestDefaultBinaryMessengerBinding` 拦 channel），
> 或者把存储抽成一个 `TokenVault` 接口，测试注入内存实现——**推荐后者，干净**。

---

## 第 4 条（P1）：`afterSeq` 传非法值静默返回全量数据

### 现状

`dsh-plugin-m1/lib/server.js:282-288`：

```js
const afterSeq = url.searchParams.get('afterSeq');
const feed = pageContext.desktopSessionEvents(sessionId, {
  afterSeq: afterSeq === null ? undefined : Number(afterSeq),   // 'abc' → NaN, '-5' → -5
  limit: Number(url.searchParams.get('limit') ?? 80),           // 'abc' → NaN
});
```

`dsh-plugin-m1/lib/index.js:1586-1597`：

```js
const afterSeq = Number(options.afterSeq);
if (Number.isFinite(afterSeq) && afterSeq >= 0) { /* 增量 */ }
else { /* 走全量尾部回扫，MAX_TAIL_EVENTS = 600 */ }
```

于是 `?afterSeq=abc` 或 `?afterSeq=-5` 会被当成「没传」，返回最多 600 条 / 实测 253 KB。
调用方以为自己在做增量补齐，实际拿到一整包——弱网下直接超时。

### 改法

在 `server.js` 里**校验并拒绝**，别让它静默降级：

```js
const rawAfterSeq = url.searchParams.get('afterSeq');
let afterSeq;
if (rawAfterSeq !== null) {
  const parsed = Number(rawAfterSeq);
  if (!Number.isInteger(parsed) || parsed < 0) {
    sendJson(response, 400, {
      code: 'BAD_REQUEST',
      message: `afterSeq 必须是非负整数，收到：${rawAfterSeq}`,
    });
    return;
  }
  afterSeq = parsed;
}
```
`limit` 同样处理：非正整数 → 400（或夹到 `1..600`，二选一，但不要让它变 NaN）。

放在 `authorizeToken` 之后、调 `desktopSessionEvents` 之前。

> App 侧传的都是整数：`history_api.dart:1216`（messages）、`:1245`（events）、
> `:1351`（桌面会话直播，`if (afterSeq != null)` 包了一层，不传就不带这个参数），
> 所以这个改动**不影响 App**，只拦外部/异常调用。

### 验收

新增 `dsh-plugin-m1/test/after-seq-validation.test.js`（照 `bad-json-400.test.js` 的 `stubHub` 写法）：

1. `?afterSeq=abc` → 400 `BAD_REQUEST`
2. `?afterSeq=-5` → 400 `BAD_REQUEST`
3. `?afterSeq=1.5` → 400（非整数）
4. `?afterSeq=0` 和 `?afterSeq=100` → 200，正常
5. 不带 `afterSeq` → 200（全量尾部，老行为不变）

---

## 第 5 条（P2）：未知路由回 404 却配 `code: 'BAD_REQUEST'`

### 现状

`dsh-plugin-m1/lib/server.js:1048`：

```js
sendJson(response, 404, { code: 'BAD_REQUEST', message: 'not found' });
```

状态码是 404，但 code 说「请求写错了」。客户端如果按 code 分流，会把「这个接口不存在」
误判成「我的参数有问题」，从而重试而不降级。

### 改法

```js
sendJson(response, 404, { code: 'NOT_FOUND', message: 'not found' });
```

**只改 code，别动 404 状态码**——App 里有多处按 `statusCode == 404` 做降级的逻辑
（`live_store.dart:749` 的 `_tasksRestUnavailable`、`:783`、`:810` 的 `_archiveUnavailable`），
它们看的是状态码，不受影响。

### 验收

新增一条测试（可以塞进 `bad-json-400.test.js`）：
`GET /api/v1/nope` → 404 且 `code === 'NOT_FOUND'`。

---

## 第 6 条（P2）：`file/raw` 不支持 Range，大文件没法断点续传/拖动播放

### 现状

`dsh-plugin-m1/lib/server.js:961-966`：

```js
response.writeHead(200, {
  'content-type': contentTypeOf(file.absPath),
  'content-length': file.size,
  'cache-control': 'no-store',
});
response.end(file.buffer);
```

无条件 200 + 全量。手机端在工作区里预览图片/PDF（`desktop/file/raw`，M4.9）时，
弱网下大文件只能整包重下；PDF 阅读器想跳页也没法发 Range 请求。

> 注意：`/api/v1/app/apk`（`lib/appupdate.js:125`）**有意**不支持 Range，注释写着
> 「不实现 Range，App 每次都整包拉取」，那是设计决策，**不要动它**。

### 改法

只改 `file/raw` 这一处：

```js
const range = request.headers.range;
if (typeof range === 'string' && range.startsWith('bytes=')) {
  const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
  if (match) {
    const size = file.size;
    let start = match[1] === '' ? NaN : Number(match[1]);
    let end = match[2] === '' ? NaN : Number(match[2]);
    if (Number.isNaN(start) && Number.isNaN(end)) {
      /* 两个都空：当没传 Range */
    } else {
      if (Number.isNaN(start)) { start = Math.max(0, size - end); end = size - 1; }  // bytes=-500
      if (Number.isNaN(end)) end = size - 1;                                          // bytes=0-
      if (start < 0 || start >= size || end < start) {
        response.writeHead(416, { 'content-range': `bytes */${size}` });
        response.end();
        return;
      }
      end = Math.min(end, size - 1);
      const chunk = file.buffer.subarray(start, end + 1);
      response.writeHead(206, {
        'content-type': contentTypeOf(file.absPath),
        'content-length': chunk.length,
        'content-range': `bytes ${start}-${end}/${size}`,
        'accept-ranges': 'bytes',
        'cache-control': 'no-store',
      });
      response.end(chunk);
      return;
    }
  }
}
// 无 Range 或 Range 无法解析：老行为，整包 200，但补上 accept-ranges
response.writeHead(200, {
  'content-type': contentTypeOf(file.absPath),
  'content-length': file.size,
  'accept-ranges': 'bytes',
  'cache-control': 'no-store',
});
response.end(file.buffer);
```

### 验收

新增 `dsh-plugin-m1/test/file-raw-range.test.js`（`pageContext.readWorkspaceFileBytes` 返回一个构造好的 buffer）：

1. `Range: bytes=0-9` → 206，body 10 字节，`content-range: bytes 0-9/<size>`
2. `Range: bytes=10-` → 206，body 是 `size-10` 字节
3. `Range: bytes=-5` → 206，body 是最后 5 字节
4. `Range: bytes=99999-`（超出）→ 416 + `content-range: bytes */<size>`
5. 不带 `Range` → 200，全量，带 `accept-ranges: bytes`
6. `Range: 离谱字符串` → 退回 200 全量（不能 500）

---

## 第 7 条（P2）：会话直播一次传 187~253 KB 明文，建议加 gzip

### 现状

`M4.38`（`PROJECT_STATUS.md`）实测：`GET /api/v1/desktop/sessions/:id/events` 首屏
**175 712 B**，最坏 **253 187 B**，走隧道往返 1~2.4 秒，是「直播页经常连接超时」的主因之一。
当轮只做了 App 侧的互斥+退避，**插件侧 gzip 明确记为「未做」**。

`dsh-plugin-m1/lib/server.js:63-72 sendJson()` 无条件明文：

```js
function sendJson(response, status, payload, extraHeaders = {}) {
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': body.length,
    ...
  });
  response.end(body);
}
```

### 改法

**只给大响应加**，小响应（几百字节的）压缩纯属浪费 CPU 且可能更大：

```js
import { gzipSync } from 'node:zlib';

function sendJson(response, status, payload, extraHeaders = {}, request = null) {
  let body = Buffer.from(JSON.stringify(payload), 'utf8');
  const acceptsGzip =
    typeof request?.headers?.['accept-encoding'] === 'string' &&
    request.headers['accept-encoding'].includes('gzip');
  // 只有大响应值得压：几十字节的东西 gzip 后可能更大，白烧 CPU
  if (acceptsGzip && body.length >= 4096) {
    const zipped = gzipSync(body, { level: 6 });
    if (zipped.length < body.length) {
      body = zipped;
      response.writeHead(status, {
        'content-type': 'application/json; charset=utf-8',
        'content-length': body.length,
        'content-encoding': 'gzip',
        vary: 'accept-encoding',
        'cache-control': 'no-store',
        ...extraHeaders,
      });
      response.end(body);
      return;
    }
  }
  /* 老行为 */
}
```

然后给需要的大响应路由传 `request`。**至少要覆盖这两条**（都是几百 KB 级）：

- `GET /api/v1/desktop/sessions/:id/events`（`server.js:271-296`，`sendJson(response, 200, feed)`）
- `GET /api/v1/desktop/archive/sessions/:id`（`server.js:850-862`，带全量 `events`）

`sendJson` 的签名变了，其它 30 来个调用点**不用改**（`request` 是最后一个可选参数，不传就是老行为）。

> App 侧不用动：Dart `HttpClient.autoUncompress` 默认 true，会自动解 gzip 并摘掉
> `content-encoding`。但 App 的 `_get` 现在是显式 `accept-encoding` 吗？如果自己设了
> 头，确认设的是 `gzip` 而不是空。

### 验收

新增 `dsh-plugin-m1/test/gzip-response.test.js`：

1. 构造一个 200 KB 的假 feed（`pageContext.desktopSessionEvents` 返回大量事件），
   带 `Accept-Encoding: gzip` → 响应头有 `content-encoding: gzip`，
   且**响应字节数 < 明文的一半**
2. 同一请求不带 `Accept-Encoding` → 无 `content-encoding`，body 是明文 JSON，能 `JSON.parse`
3. 小响应（比如 `/api/v1/health`）即使带 `Accept-Encoding: gzip` 也**不压缩**
   （验证 4096 字节阈值生效）
4. 解压后的内容和明文逐字节相同（用 `gunzipSync` 比对）

---

## 第 8 条（杂项）：删掉项目根目录两个 0 字节的误建文件

### 现状

```
D:/用户/项目/deepseek手机端/client.js        ← 0 字节
D:/用户/项目/deepseek手机端/pubspec.yaml     ← 0 字节
```

**都是 2026-11-12 / 11-13 误建的**。真正的文件在子目录里，都在，别删错：

| 文件 | 大小 | 状态 |
|---|---|---|
| `dsh-plugin-m1/client.js` | 18 765 B | **正常，保留** |
| `app/pubspec.yaml` | 681 B | **正常，保留** |
| 根目录 `client.js` | **0 B** | 删 |
| 根目录 `pubspec.yaml` | **0 B** | 删 |

### 改法

1. 删除这两个 0 字节文件。
2. 在仓库根 `.gitignore` 加一条注释说明为什么不能有它们（防止以后又被误建）：
   ```
   # 项目根目录不应有 client.js / pubspec.yaml：它们属于 dsh-plugin-m1/ 和 app/
   /client.js
   /pubspec.yaml
   ```
3. 删之前 `stat` 一下确认还是 0 字节（万一是有人后来填了内容）。

### 验收

`ls -la` 根目录不再有这两个文件；`node --test` 和 `flutter test` 都不受影响（本来就是空文件）。

---

## 附：已经修好的两处（不用再改，仅供了解）

这两条是本次复查中直接改掉的，代码已落盘，**只等第 0 条重启生效**：

### A. 会话永久锁死（`SESSION_BUSY` 死锁）

`dsh-plugin-m1/lib/hub.js`

- 病因：`conversation.busy = true` 只在 `prompt.send` 时置位（`:332`，以及 `task.state` 的
  `queued/running` 分支 `:373`），而 `busy = false` **只**靠 `task.state` 终态事件解锁（`:374`）。
  agent 在任务中途掉线就永远收不到终态 → 该会话永久返回 `SESSION_BUSY`（`:328-329`），
  用户发什么都发不出去，只能重启插件。
- 修法：`#attachAgent` 的 `peer.on('close')` 里调新增的 `#releaseAllBusy()`（`:242 / :251-262`），
  agent 断线时把它名下所有会话的 busy 全部放行。
- 安全性：ACP 侧 `agent/src/harness/acp/acp-adapter.ts:460-475` 还有第二层互斥
  （`state.turn !== null` 就抛 `SESSION_BUSY`），hub 少锁一次不会导致真并发。
- 测试：`test/session-busy-release.test.js` 3 例（真 WebSocket 端到端复现）。

### B. 坏 JSON 请求体回 500 而非 400

`dsh-plugin-m1/lib/server.js:158-166`

- 病因：`readJsonBody` 解析失败抛 `HubError('BAD_REQUEST', …, 400)`（`:42 / :56`），
  但大多数路由是在 `try` **之外** `await` 它的（`:197 / :331 / :355 / :404 / :504 / :537 /
  :568 / :601 / :636 / :664 / :879 / :904 / :987`），异常直接冒到 `createServer` 的全局 catch，
  被一律当成 500 回 `INTERNAL`。客户端把「我发错了」看成「服务器炸了」。
- 修法：在全局 catch 里按 `error instanceof HubError` 用它自己的 `status` / `code` 回包（`:158-166`），
  上列路由一个都不用改。
- 测试：`test/bad-json-400.test.js` 2 例。

---

## 建议执行顺序

| 顺序 | 条目 | 理由 |
|---|---|---|
| 0 | 第 0 条 重启 | 否则测不出真实行为 |
| 1 | 第 2 条 token | 安全问题最重，且数据库里已经积了 223 条 |
| 2 | 第 1 条 死链 | 用户可见的功能缺失，抽屉和按钮都是空的 |
| 3 | 第 5 条 404 code | 一行改动，顺手 |
| 4 | 第 4 条 afterSeq | 一行改动 + 测试，防弱网超时 |
| 5 | 第 3 条 token 加密 | 涉及加依赖，改动面大一些 |
| 6 | 第 6 条 Range | 独立，不碰别的 |
| 7 | 第 7 条 gzip | 收益大但要动 `sendJson` 签名，放后面 |
| 8 | 第 8 条 删空文件 | 随时可做 |

**不建议放进本轮的**（需要单独讨论，别硬做）：

- `resolveParentDir`（`lib/index.js:1235-1239`）里 `if (existsSync(wanted) && statSync(wanted).isDirectory()) return wanted;`
  这一句让**任意已存在目录**都能当工作区父目录，是真正放宽权限模型的地方。
  但它是 M4.13 为了让「项目根不在授权列表里也能用」故意开的，收紧会影响现有用户的使用习惯，
  得先想清楚产品上要不要这么宽，再改。
- 工作区名消毒（`lib/index.js:1250`）把 `[\\/:*?"<>|]` 换成 `-`，
  `../../escape-probe` 会变成 `..-..-escape-probe`，只是个普通目录名，**其实没有逃逸**
  （`:` 也被替换，`C:` 这类盘符同样失效）。
  `PROJECT_STATUS.md` M4.40 里那句「被消毒后照建目录」容易读成漏洞，实际是安全的，不用改。
