# M4.3 交付报告：直播页「已运行」与电脑端对齐

- 日期：2026-11-13
- 版本：手机端 **0.4.3-m4.3（versionCode 30）**；DSH 插件 **0.2.12**（需完整退出重开 DSH 生效）
- 状态：代码、单测（277/277）、静态检查（0 error）、release APK 已完成并发布；**真机复测未做**（交付时 adb 无设备）

## 1. 一句话结论

用户反馈：「这个用时不应该和电脑上的统一吗，不是每次打开后开始计时」。原因是直播页只拿得到 `running=true/false`，起点写死成「手机这次打开页面的时刻」（`_runStart ??= DateTime.now()`，且离开页面就丢），所以手机上的「已运行 0:24」和电脑端那一轮的时长永远对不上。M4.3 改成：**起点取会话日志里最新一条 `turn-start` 的时间**——也就是电脑上这一轮真正开始的时刻；插件把每条事件自带的 `time` 下发（以前映射时就丢了这个字段），手机端据此算时长，超过 1 小时显示 `H:MM:SS`。旧插件（0.2.11 及以下）不下发时间时，退回任务行的最后活动时间，再退回会话 `updatedAt`，不会再从 0:00 起算。

## 2. 起因与根因

| 现象 | 根因 | 修复 |
| --- | --- | --- |
| 手机「已运行」每次打开页面都从 0:00 开始，和电脑端两个数 | `desktop_session_screen._runStart ??= DateTime.now()`：起点是「本机打开页面的时刻」，离开页面 `dispose` 后丢失，下次再打开重新计时 | 起点改为 `resolveRunStart()`：取日志里最新一条带时间的 `turn-start` |
| 手机上算不出电脑端的真实起点 | 插件 `mapDesktopEvent` 映射事件时只保留 `seq`，**把 Host 事件自带的 `time` 丢了**，`DesktopSessionEvent` 也没有该字段 | 插件事件统一带 `time`（毫秒）；App `DesktopSessionEvent.time` 解析并随 `withText` 保留 |
| 长任务显示成 `120:31` 不好读 | 时长格式只有 `M:SS` | `formatElapsed()`：≥1 小时为 `H:MM:SS`，负数按 0 |
| 旧插件没有时间字段时仍可能从 0 起算 | 无兜底 | `resolveRunStart()` 依次退回 `lastTime`（任务行最后活动）→ 会话 `updatedAt` → `now` |

## 3. 插件端（dsh-plugin-m1 0.2.12）

- `lib/index.js`：`mapDesktopEvent()` 已经算出 `const time = Number(event?.time) || 0`，但每个分支只返回 `{seq, kind, ...}`。0.2.12 在每个分支补上 `time`（`user` / `assistant` / `tool-call` / `tool-result` / `turn-start` / `turn-end` / `approval`），`listDesktopSessionEvents()` 无需其它改动即随事件下发。
- `package.json`：0.2.11 → **0.2.12**。
- 没有新增路由；旧手机端忽略多出来的 `time` 字段，行为不变。

## 4. 手机端（0.4.3-m4.3 / versionCode 30）

- `app/lib/services/desktop_sort.dart`：新增两个纯函数
  - `DateTime resolveRunStart({required Iterable<DesktopSessionEvent> events, int? lastTime, DateTime? updatedAt, DateTime? now})`：取 `kind == 'turn-start'` 且 `time > 0` 的最新一条 → `lastTime` → `updatedAt` → `now`。
  - `String formatElapsed(Duration elapsed)`：`M:SS` / `H:MM:SS`，负数归零。
- `app/lib/services/history_api.dart`：`DesktopSessionEvent` 新增 `final int time`（毫秒，缺省 0），`fromJson` 读 `time`，`withText()` 一并保留（否则相邻助手消息合并时会把时间丢掉）。
- `app/lib/screens/desktop_session_screen.dart`：
  - `_load()` 里原来「`if (running) _runStart ??= DateTime.now()`」整段替换为 `_runStart = feed.running ? resolveRunStart(events: _events, lastTime: widget.lastTime, updatedAt: _sessionUpdatedAt) : null;`，每个事件到达后都会用最新日志重算（新的一轮 `turn-start` 出现时自动跳到新起点）。
  - `_elapsedLabel()` 改用 `formatElapsed()`。
  - 新增可选参数 `int? lastTime`（任务行最后活动时刻）+ 内部 `_sessionUpdatedAt` 作为旧插件兜底。
- `app/lib/screens/workspace_screen.dart`、`app/lib/screens/tasks_screen.dart`：打开直播页时把 `task.lastTime` 传进去。
- `app/lib/app_version.dart` / `pubspec.yaml` / `android/local.properties` / `android/app/build.gradle.kts`：0.4.3+30 / `0.4.3-m4.3`。
- 新增测试 `app/test/desktop_run_timer_test.dart`（10 个用例）：`time` 解析与 `withText` 保留、取最新 `turn-start`、手机中途打开也对得上电脑起点、旧插件退回 `lastTime`/`updatedAt`/`now`、`formatElapsed` 的 `M:SS` 与 `H:MM:SS` 及负数。

## 5. 验收证据

| 项 | 结果 |
| --- | --- |
| `flutter test` | **277/277 通过**（M4.2 的 267 + 新增 10） |
| `flutter analyze` | **0 error**（历史 warning/info 若干） |
| 插件单测 | `node --test 'test/*.test.js'` **12/12 通过**；`node --check lib/index.js` 通过 |
| release APK | **71,867,762 字节**，SHA256 `F18663C63925F7325ABA9C102B3FDA2B5DF01A21E3CFD31C9028C3BE43F8EFB1` |
| APK 版本 | aapt2：`versionCode='30' versionName='0.4.3-m4.3'` |
| APK 签名 | `CN=Android Debug`，SHA-256 `341ef83b95f452bb50b5a6821aa2044334826971e27910d428abc5dab33f70d6`（与上一版一致，可直接覆盖安装） |
| 真机复测 | **未做**：`adb devices` 为空（USB 未连接/未授权调试） |

## 6. 生效步骤（必须做）

1. **完整退出 DSH 桌面应用并重开**（加载插件 0.2.12）。
2. 跑自检：`pwsh -File tools\verify-plugin-m4.ps1`，期望 **11/11 PASS**；其中「`GET /desktop/sessions/:id/events` 事件带 time」这一项就是 M4.3 的验收点（应输出 `withTime=N`）。
3. 安装 `dist\DeepSeek-Remote-latest.apk`（或根目录 `DeepSeek Remote AI 手机端 v0.4.3-m4.3.apk`），重新配对。
4. 真机对照：电脑上跑一个长任务，手机从任务页/工作区页点进直播页，比较手机「已运行 X:XX」与电脑端同一轮的时长（应当一致，而不是从 0:00 起）。

## 7. 已知限制

- 起点依赖 Host 事件日志里的 `turn-start` 时间；若某轮在日志里没有 `turn-start`（极旧会话或日志被裁剪），会退回任务行 `lastTime`（最后活动时间）——此时显示的时长会比电脑端短一些（近似「空闲至今」，一轮内活动很密时几乎一致）。
- 手机系统时钟与电脑不同步时，时长会有同等偏差（目前不校时，也没有 NTP）。
- `flutter analyze` 仍有历史 warning/info（本次新增代码已清理干净，如无必要不动老文件）。

## 8. 下一步

- 真机复测（等 USB 接回）：长任务下手机与电脑「已运行」是否一致、离开页面再回来是否连续。
- 同源问题：助手页/任务页的「X 分钟前」用的是任务行 `lastTime`，与直播页口径目前一致；以后若 Host 提供 `turn-start` 汇总，可统一到同一来源。

## 9. 证据索引

- 报告：`docs/research/M4_2_REPORT.md`（上一轮）、本文件
- 自检脚本：`tools/verify-plugin-m4.ps1`（11 项，含事件 `time` 检查）
- 测试：`app/test/desktop_run_timer_test.dart`
- 构建产物：`dist/DeepSeek-Remote-AI-v0.4.3-m4.3.apk`、`dist/DeepSeek-Remote-latest.apk`、`DeepSeek Remote AI 手机端 v0.4.3-m4.3.apk`
