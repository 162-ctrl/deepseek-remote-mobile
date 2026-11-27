# M4.40 审计报告：从四个角度压测这个 App

> 更新：2026-11-20（Asia/Shanghai）
> 交付版本：手机端 `0.4.40+66`（versionName `0.4.40-m4.40`）；插件版本未变，仍是 `0.2.30`。
> 这一轮不加功能，只做测试，并把测试抓出来的真问题修掉。

## 一句话结论

四个角度压下来，**应用层没有致命问题**：错误降级、懒加载、发送幂等、轮询生命周期都站得住；
但抓到 **2 个真 bug 并已修**（坏时间戳污染排序、小屏大字号下三处布局溢出），
另外在**插件侧**记下 **6 条待修问题**，其中三条会直接影响用户体验（坏 JSON 返 500、
`afterSeq` 非法时返回全量 253 KB、86 条配对 token 永不失效）。

## 这一轮怎么测的

| 角度 | 手法 | 产出 |
|---|---|---|
| 接口契约 | 真 token 打本机 `127.0.0.1:8787`，构造边界与坏输入 | `tools/api-contract-probe.mjs`、`tools/api-auth-probe.mjs` |
| 存档容错 | 真实临时目录写坏文件再读 | `app/test/audit_persistence_m4_40_test.dart`（10 例） |
| 小屏 + 大字号 | `320x480` + `textScaleFactor 2.0` 下渲染关键页 | `app/test/audit_small_screen_m4_40_test.dart`（4 例） |
| 运行期 | 500 条消息、连点发送、页面关闭 | `app/test/audit_runtime_m4_40_test.dart`（3 例） |
| 错误降级 | 造 500/HTML、200 非 JSON、401、超时、空 token | `app/test/audit_api_errors_m4_40_test.dart`（8 例） |

新增测试 25 例，全量 `flutter test test/` → **462/462 PASS**。

## 角度一：接口契约（插件侧，6 条待修）

探针发现的问题，按严重度排：

| # | 严重度 | 现象 | 根因 | 建议 |
|---|---|---|---|---|
| 1 | 中 | 坏 JSON 请求体返回 **500 `INTERNAL`**，应是 400 | `dsh-plugin-m1/lib/server.js:588` 的 `const body = await readJsonBody(request);` 写在 `try {` 之前，`HubError('BAD_REQUEST', …, 400)` 逃到 L151 的外层 catch 被统一改成 500 | 把读体移进 try，或让外层 catch 保留 `HubError.status` |
| 2 | 中 | `afterSeq=abc`、`afterSeq=-5` 被当成「没有 afterSeq」，直接返回**全量 253,187 B** | `Number.parseInt` 失败后落到 `null` 分支 | 非法值直接 400，别静默降级 |
| 3 | 中 | `tokens.json` 里 **86 条 token 全部有效**（app 30 / agent 56），配对只增不撤、30 天有效 | 没有撤销/过期清理逻辑 | 同设备重配对时作废旧 token；加定期清理 |
| 4 | 中 | 工作区名 `../../escape-probe` 被消毒成 `..-..-escape-probe` 后**照建目录** | 只做了字符替换，没有「消毒后与原名不一致就拒绝」 | 改名直接 400（探针建的目录已删除） |
| 5 | 低 | 未知路由 404 的 body 是 `{"code":"BAD_REQUEST", …}`，状态码与 code 不一致 | catch-all 复用 BAD_REQUEST | 改用 `NOT_FOUND` |
| 6 | 低 | `GET /api/v1/app/apk` 带 `Range: bytes=0-2` 仍回 200 + 整包 73 MB | 没实现 206 | 支持断点续传，弱网重下能省流量 |

补充实测（不是问题，但值得记住）：

- `/desktop/tasks` 16 ms / 729 B；`events afterSeq=999999999` → 200 + 空 `events`（增量语义正确）。
- `limit` 参数**实际无效**：`limit=80/40/20` 返回完全一样（319 条事件 / 186,948 B / `chat=12`），
  因为 `dsh-plugin-m1/lib/index.js:1583-1584` 的 `MIN_CHAT_EVENTS = 12` / `MAX_TAIL_EVENTS = 600`
  会一直回扫到凑够 12 条对话为止。**首屏体积由会话本身决定，调 limit 没用。**
- 插件没有压缩：`Accept-Encoding: gzip` 时 `Content-Encoding` 为空，188 KB 原样返回
  （`server.js` 只 import `node:http`，依赖只有 `jszip`、`pdf-parse`）。

鉴权专项全部正确：坏 token / 空 token / agent token 打 app 路由 → 401；
app token 打 `/api/v1/agent/workspaces` → 401（角色隔离没漏）。

## 角度二：存档容错（抓到 1 个真 bug，已修）

`app/test/audit_persistence_m4_40_test.dart` 覆盖：文件不存在、0 字节、截断 JSON、
顶层是数字/字符串/null、列表里混 null 与字符串、时间字段坏掉、role 写错、
同 id 出现两次、超过 80 条、emoji 与超长文本往返。

**修掉的 bug**：`app/lib/services/cloud_conversations.dart` 的 `CloudConversation.fromJson`
原来写 `createdAt: created ?? DateTime.now()`、`updatedAt: updated ?? created ?? DateTime.now()`
—— 时间戳坏掉时退回「现在」，于是一条 `updatedAt:'yesterday'` 的坏记录反而顶到侧栏「最近」的第一位，
把真正最新的那条挤下去。现在退回 `DateTime.fromMillisecondsSinceEpoch(0)`，坏记录沉底。

## 角度三：小屏 + 大字号（抓到 3 处溢出，已修）

在 `320x480` + 系统字号 2.0 下渲染桌面直播页，一屏报了三个 `RenderFlex overflowed`：
body 的 Column、运行中那一行 Row、底部 `_LiveFooter` 的 Row。

修法（`app/lib/screens/desktop_session_screen.dart`）：

- `body` 外层改成 `LayoutBuilder`，用 body 的**真实高度**判断 `cramped = maxHeight < 520`；
  只有 cramped 时才把上下两块各封顶到 `45%`，正常竖屏完全不封（试过无条件封顶，
  会把 420x760 下提问卡的「提交」挤出屏幕，直接弄挂 M4.35 的用例）。
- 顶部那块（标题 + 提示条 + 授权/提问卡 + 过程条）与底部那块（运行中 → 输入框）
  各自包 `ConstrainedBox > SingleChildScrollView > Column(min)`，实在放不下就自己滚。
- 运行中那行与底部状态行改 `Expanded/Flexible` + `maxLines: 2` + ellipsis。

诊断手法值得留档：Flutter 的溢出错误默认只说「溢出 N 像素」不报位置；
在用例里临时装 `FlutterError.onError = (d) => debugPrint(d.toString())`，
就能打印出 `The relevant error-causing widget was: Column … desktop_session_screen.dart:806:13`。

## 角度四：运行期（3 例全过）

| 检查 | 结果 |
|---|---|
| 500 条消息渲染 | 只建了 < 60 个 `ChatItemView`（`ListView.builder` 懒加载生效） |
| 连点三下「发送」 | 只发出一条（`sending` 期间按钮 `onPressed: null`） |
| 页面关掉之后 | `fetchDesktopSession` 调用次数不再增长（轮询确实停了） |

## 这一轮没覆盖的角度

- **真机**：手势冲突（上滑新建对话 vs 列表滚动）只在 widget 测试里验证，没在真机上过手感。
- **弱网**：M4.38 已量过隧道 RTT（events 955~2422 ms），但没有做丢包/半连接模拟。
- **多设备同时连**：只验证了角色隔离，没验证两台手机同时发指令。
- **长时间挂机**：前台服务常驻 8 小时以上的内存/电量没测。

## 复现命令

```powershell
# 接口契约 + 鉴权
node tools/api-contract-probe.mjs
node tools/api-auth-probe.mjs

# 四组审计用例
cd app
flutter test test/audit_api_errors_m4_40_test.dart
flutter test test/audit_persistence_m4_40_test.dart
flutter test test/audit_small_screen_m4_40_test.dart
flutter test test/audit_runtime_m4_40_test.dart
```

## 交付

- 手机端 **0.4.40+66**：73,049,346 字节，versionCode **66**，
  SHA256 `8EF276D9F74449FEC46A375F779FC2D8528B5618C993A67D4EC399934F8F741F`
  （`dist\DeepSeek-Remote-latest.apk`、`dist\DeepSeek-Remote-AI-v0.4.40-m4.40.apk`、
  根目录 `DeepSeek Remote AI 手机端 v0.4.40-m4.40.apk` 三处同哈希，`/api/v1/app/version` 已回读一致）。
- 插件未改，仍是 `0.2.30`；上面 6 条插件问题需要改插件并**完整退出重开 DSH**才生效。
