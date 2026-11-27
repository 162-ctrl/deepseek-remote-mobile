# M2.9.6 报告：自动续连

日期：2026-11-11 · App 0.2.6+17（`0.2.6-m2.9.6`）· 插件 0.2.5

## 1. 目标

用户反馈「每次打开手机都要重连，不行」。目标是：配对一次之后，手机冷启动、进程被杀、插件重载，都不需要再扫码/输配对码。

## 2. 根因

| 层 | 问题 |
|---|---|
| 插件 | 配对 token 只存在 `M1Hub.#tokens` 内存里，插件重载/重启后全部失效，手机拿旧 token 会被 401 |
| App | 没有持久化 `serverUrl` / `token`，冷启动只能回到连接页 |

## 3. 做法

### 插件侧

- `lib/hub.js`：构造函数接受可选 `tokenStore`（`{load(): Record<string, record>|null, save(map)}`），新增 `#restoreTokens()` 与 `#persistTokens()`；`pair()` 成功后立即落盘，Hub 启动时恢复。
- `lib/index.js`：在 `stateDir`（`C:\Users\user\.dsh\dsh-plugin-m1`）维护 `tokens.json`，读写包一层 JSON 异常保护，传给 `new M1Hub({ tokenStore })`。
- 版本升 `0.2.5`。

### App 侧

- 新增 `app/lib/services/session_store.dart`：
  - `SavedSession{serverUrl, token, deviceId, savedAt}`；
  - `SessionStore.load()` / `save()` / `clear()`，写入 `getApplicationSupportDirectory()/session.json`；
  - 文件损坏或字段缺失时返回 `null`，不阻塞启动。
- `app/lib/data/live_store.dart`：
  - 构造注入 `SessionStore? sessionStore`；
  - 连接成功（配对或续连）后保存；
  - `disconnect()` 清存档；
  - 新增 `Future<bool> restoreSession()`：有存档则直接 `_relay.connect(serverUrl, token: ...)`，失败清档并回到未连接。
- `app/lib/app.dart`：`initState` 里 `unawaited(_liveStore.restoreSession())`，首帧先显示首页空态/连接中，成功后直接进已连接状态。

## 4. 验证

| 项 | 结果 |
|---|---|
| 单测 | `flutter test` **215/215**（新增 4 条：冷启动续连不重配对、配对后落盘、续连失败清存档、主动断开清存档） |
| token 存活 | 同一个 token 连续 3 次插件重载（`set_bundle false→true`）后，`GET /api/v1/desktop/tasks` 仍返回 200 / 4 条 |
| 落盘 | `C:\Users\user\.dsh\dsh-plugin-m1\tokens.json` 存在，配对后 405→566 字节 |
| 端到端 | 模拟器装 0.2.6，配对一次后 `am force-stop` 再启动 → 直接显示「已连接 · DeepSeek Harness」，不出现连接页；截图 `docs/research/evidence/m2/m2_9_6-auto-reconnect.png` |
| 构建 | `dist/DeepSeek-Remote-AI-v0.2.6-m2.9.6.apk`（69,603,190 字节，versionCode 17） |

## 5. 已知限制

- 公网 Quick Tunnel 地址每次插件重启都会变，存档里的 `serverUrl` 会失效；此时 App 会清档回连接页（局域网固定地址不受影响）。要彻底解决需 Named Tunnel 或固定域名。
- token 存档有效期由 Hub 的 `expiresAt` 决定（当前 7 天），过期后需重新配对。
- 手机换设备/清数据后需重新配对一次。

## 6. 复现

```powershell
# 1) 看插件 token 存档
Get-Content "$env:USERPROFILE\.dsh\dsh-plugin-m1\tokens.json"

# 2) 重载插件后验证旧 token
$t = (Get-Content C:\Users\user\dsh-build\persist-token.txt -Raw)
Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/v1/desktop/tasks' -Headers @{ Authorization = "Bearer $t" }

# 3) 模拟器冷启动验证
adb shell am force-stop com.deepseek.remote.deepseek_remote_app
adb shell monkey -p com.deepseek.remote.deepseek_remote_app -c android.intent.category.LAUNCHER 1
```
