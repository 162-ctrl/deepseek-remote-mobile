# M4.31 手机端也要能回答电脑的「确认需求」

> 更新：2026-11-17 18:30（Asia/Shanghai）
> 版本：手机端 `0.4.31+57`（`0.4.31-m4.31`）· 插件 `0.2.30`

## 一句话结论

提问以前只在「手机正停在那条会话的直播页」时才被手机接管，所以电脑上弹出「确认需求」时手机端一无所知。现在只要手机 App 还连着，就由手机接管，工作区顶部还会提前显示「确认范围 · 还有 N 个」，点进去就是那张带选项的卡片。

## 起因

用户发来电脑端截图：Agent 用 `ask_user_question` 弹了「确认是哪一档」的问题卡（三个选项 + 跳过/提交），配文「这个要要审核选择的功能手机上没有」。注意这不是权限审批，是问答卡片——M4.23 已经做过手机端的卡片，但当时留了一道门槛。

## 根因

`dsh-plugin-m1/lib/index.js` 的 `user-questions/request` 监听器第一句是：

```js
if (!sessionId || !isWatching(sessionId)) return next();
```

`isWatching()` 要求「这条会话在 10 分钟内被手机拉过事件」。用户在电脑上聊天、手机没打开那条会话，`isWatching` 就是 false → 直接 `next()` 交回电脑弹窗 → 手机端连「有提问」都不知道。M4.23 做的是「接管之后的界面」，这道门槛让接管根本不发生。

## 改了什么

| 位置 | 改动 |
|---|---|
| 插件接管条件 | 新增 `phoneOnline()`（`hub.appCount > 0`）；条件改成「正在看这条会话 **或** 手机还连着」，只有手机彻底断开才交回电脑弹窗 |
| 插件新接口 | `GET /api/v1/desktop/pending` → `{questions: [{sessionId, questionId, count, header, question, title, createdAt}], approvals: [...]}`，只给标题级摘要，完整选项仍走 `/sessions/<id>/events` 的 `questions` |
| 手机端模型 | `DesktopPendingQuestion` / `DesktopPending`（`fetchDesktopPending()`，404/501 降级成 `answerable: false` 而不是弹错） |
| 手机端界面 | 工作区顶部 `_PendingQuestionBanner`：header + 问题正文 + 「还有 N 个」，点一下进那条会话；`_loadPending()` 挂在已有的 5 秒轮询上 |

## 验收证据

| 项 | 结果 |
|---|---|
| 插件 `node --test` | **101/101**（新增 `pending.test.js` 6 例：摘要映射、空 id 过滤、空数组、路由 200/401/501） |
| `flutter test` | **414/414**（新增 `pending_question_m4_31_test.dart` 5 例：提示条显示、点击进会话、无提问不显示、404 降级、解析标题） |
| 真机接口 | 运行中的插件仍是 0.2.28 → `/api/v1/desktop/pending` 回 404，App 按「看不到」处理，不弹错 |
| 插件热加载 | `HMR transactions cannot be nested`（第三次复现），**0.2.30 需完整退出 DSH 再重开** |

## 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app
flutter build apk --release
```

产物：`73,016,578` 字节，SHA256 `CC2B4F3403FCB214C8F70FC08F6E7C6614E205A84BE9CC0C6BB5FA42A5094C99`，`versionCode 57`，minSdk 24 / targetSdk 36。

## 限制与下一步

- **必须先完整重开 DSH**：跑着的还是 0.2.28，没有 `/desktop/pending`，也没有放宽的接管条件。重开后 `GET /api/v1/health` 的 `version` 应为 `0.2.30`。
- 提示条只在**工作区**顶部；在 AI 助手页、插件页看不到。要不要做成全局横幅（底部/顶部悬浮）另说。
- 只提示**提问**；等待授权的（权限审批）仍按老条件接管，还没统一。
- 手机连着就接管：如果手机在旁边但人不在，提问会等到 5 分钟超时按「跳过」放行，电脑端的卡片那时候已经让位了。要不要改成「电脑也保留一份只读镜像」得再想。
