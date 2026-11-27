# M4.38：手机端「经常连接超时」的成因与加固

> 一句话：不是电脑慢，也不是地址错——直播页一次要拉 187 KB，而手机端每 1.5 秒
> 就盲发一个新请求、超时又按 1.5 秒重试，几个请求叠在一条 Cloudflare 快速隧道上
> 互相抢，10 秒的总超时一被打穿就显示「连接超时（10 秒）」。

## 起因

用户发来截图：桌面直播页顶部红条写着

```
拉取桌面会话失败：连接超时（10 秒）：服务器没有响应，请检查地址与网络
```

右上角状态是「已结束 · 0 条」，正文一片空白，并追问「经常会出现这个问题是什么原因」。

## 实测数据（本机 + 同一条隧道）

| 请求 | 本机直连 | 走 Cloudflare 快速隧道 |
|---|---|---|
| `GET /api/v1/health` | 3~8 ms | **938 ms** |
| `GET /desktop/sessions/<id>/events`（首屏） | 3~69 ms，**175 712 B** | **955 / 1 030 / 2 422 ms**，176 967 B |
| 同上，带 `afterSeq`（增量） | 2~12 ms，4 757 B | — |
| `GET /desktop/tasks` | 8~16 ms | — |

关键的一条：把 `limit` 从 80 降到 40、再降到 20，返回**一模一样**——319 条事件、
186 948 B、12 条对话。因为插件的首屏逻辑要求「凑够 12 条对话事件」才停
（`MIN_CHAT_EVENTS = 12`、`MAX_TAIL_EVENTS = 600`），而这条会话有 2711 条消息、
大量 tool-call，往回要扫 319 条才凑够 12 条对话。换言之**这 187 KB 是这个会话
本身决定的，不能靠调 limit 变小**。

另外：插件是裸 `node:http`，没有 gzip（`Accept-Encoding: gzip` 实测无
`Content-Encoding`），187 KB 是原样上路的。

## 根因（三条叠加）

1. **载荷大 + 隧道慢**：一次首屏 187 KB，隧道一个来回 1~2.4 秒；手机在 5G + VPN
   下抖动更大，10 秒被击穿只是时间问题。
2. **在途没有互斥（主因）**：`desktop_session_screen.dart` 原来是
   `Timer.periodic(1500ms, (_) => _load())`，**不看上一个请求是否还挂着**。一个
   请求要 10 秒才超时，这期间会再发 6~7 个，全排在同一条隧道上 —— 越等越慢，
   表现为「经常超时」。
3. **失败后仍按 1.5 秒重试**：网络没恢复时，等于每 1.5 秒往堵住的隧道里再塞一个
   超时请求。

## 改动（都在 App 侧，装 APK 即生效，不需要重开 DSH）

| 文件 | 改动 |
|---|---|
| `app/lib/services/poll_backoff.dart`（新增） | `kDesktopPollInterval = 1500ms`、`kDesktopPollMaxBackoff = 30s`、`desktopPollDelay(failures)`：失败 1/2/3/4 次 → 3/6/12/24 秒，再往后封顶 30 秒 |
| `app/lib/screens/desktop_session_screen.dart` | `bool _inFlight` 互斥，`_load()` 在途直接返回；`int _pollFailures` + `_schedulePoll()` 改成「上一次回来之后再排下一次」；`catch` 里立刻按新退避重排（否则首次失败仍会被 1.5 秒的旧定时器抢先）；接回存档会话（revive）时也走同一条调度，不再另起 `Timer.periodic` |
| `app/lib/services/history_api.dart` | `_get()` 增加 `timeoutOverride`；只为 `desktopSessionEvents` 放宽到 **20 秒**（`desktopFeedTimeout`），其它小请求仍是 10 秒；`_dartIoSender` 的 `idleTimeout` 5 秒 → **20 秒**、`connectionTimeout` 10 秒 → 15 秒 |

## 验收证据

- 新增 `app/test/poll_backoff_m4_38_test.dart` **4/4 PASS**：
  1. 正常节奏仍是 1.5 秒；
  2. 失败退避 3/6/12/24/30 秒（含封顶）；
  3. 第一个请求挂着时，过 6 秒**只发过 1 次**（原来这 6 秒会发 4 次）；
  4. 失败后 2.6 秒仍只有 1 次，3 秒后才重试。
- 反证：把 `if (_inFlight) return;` 改成 `if (false && _inFlight) return;` → 第 3 例
  失败（`Actual: <2>`），改回来即恢复 4/4。
- 全量 `flutter test test` → **437/437 PASS**（433 + 4）。
- 产物：`dist\DeepSeek-Remote-latest.apk`，**73 049 346 字节**，
  versionCode **64**，versionName `0.4.38-m4.38`，
  SHA256 `52244982025C511BF687C8AE957A020CA99942C74A9EA79C438C72A93FF386C7`。
- `GET /api/v1/app/version` 回读：`{"versionCode":64,"versionName":"0.4.38-m4.38",
  "size":73049346,"sha256":"52244982…ff386c7"}`。

## 构建命令

```powershell
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" `
  /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml     # exit=3 表示有增改，正常
cd C:\Users\user\dsh-tools\build\dsh-app
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
flutter build apk --release
```

## 限制与下一步

1. **187 KB 还是原样在路上**。要让首屏真的变轻，得让插件压缩响应（`gzip`：
   这类 JSON 通常能压到 30~40 KB）。那是插件改动，得完整重开一次 DSH 才生效，
   本轮没做——需要就说一声。
2. 快速隧道的域名每次重开 DSH 都会变，手机里存着旧域名时请求会一直挂到超时，
   现在这种情况下退避会把它压成 30 秒一次，不会持续打满。
3. 手机切后台再回来仍会立刻整段重拉（`didChangeAppLifecycleState`），首屏还是 187 KB；
   如果觉得回到前台慢，可以在插件侧做「只补缺失段」。
