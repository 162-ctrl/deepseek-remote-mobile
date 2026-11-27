# M4.35 报告：提问卡不再把整页卡死，等回答时手机也会响一声

- 版本：`0.4.35+61`（versionName `0.4.35-m4.35`）
- 插件：不变（0.2.30）
- 交付时间：2026-11-18
- 测试：`flutter test` **430/430**（423 + 7）

## 一句话结论

两个毛病同一个来源：**「电脑停下来等你」这件事，手机端既排不好版，也不出声**。提问卡钉在对话列表上方又不自己滚，两个问题三四个选项就把列表挤成 0 高，看起来就是「划不动」；通知栏那边，提问从来没走过通知通道，只有授权才有。

## 起因

用户原话（m06904）：

> 这个页面划不动，而且没有消息通知

截图是手机上的「桌面直播」页：一条 12 条消息的会话，顶部「待回答 1」，下面是「电脑在等你回答（2 个问题）」——时长方案三选项 + 配乐三选项，卡片一直排到屏幕底部，后面的对话内容一个字都看不到。

## 根因

### 划不动

`app/lib/screens/desktop_session_screen.dart` 的 build 是一个 `Column`：标题栏 → 错误条 → 授权卡 → 提问卡 → 「过程」条 → `Expanded(ListView)`。授权卡与提问卡是**定高的普通子组件**，自己不滚，于是：

- 卡片内容一长（2 个问题 ≈ 900 逻辑像素），`Column` 先把 `Expanded` 挤到 0；
- 列表高度 0 → 页面拖不动，卡片也不会滚，中间那段内容直接不可见。

反证：把卡片区高度放大到屏高 1.2 倍，回归用例立刻报 `Actual: <0.0>`（列表高度 0），与截图症状一致。

### 没有通知

`app/lib/data/live_store.dart` 只有两条通知路径：`_showApprovalActionNotice()`（等待授权）和 `_notifyTaskFinished()`（任务做完）。M4.23 加的提问卡走的是 `user-questions/request`，**没有任何一处调用通知网关**——所以电脑停下来等回答时，手机锁屏、放口袋里都不会响。

## 改了什么

| 文件 | 改动 |
|---|---|
| `app/lib/screens/desktop_session_screen.dart` | 授权卡与提问卡合并到一块最大高度 = 屏高 **55%** 的区域（`ConstrainedBox` + `SingleChildScrollView`），超出在卡内滚动；对话列表永远保留可用高度 |
| `app/lib/data/live_store.dart` | 新增 `notePendingQuestions(Iterable<DesktopPendingQuestion>)`：新提问发一条通知（`showTaskUpdate`，key `question-<questionId>`，标题「电脑在等你回答 · <标题>」，正文是问题首行，`status: 'waiting'`，带 `sessionId`），同一提问不重复发，答完（列表里没了）把通知收回；开关沿用「我的 → 通知 → 等待授权提醒」 |
| `app/lib/screens/tasks_screen.dart` | 5 秒轮询的 `_loadPending()` 拿到待回答摘要后调 `live.notePendingQuestions(pending.questions)` |

为什么用 `showTaskUpdate` 而不是新开一个原生通道：它已经是「有结果要告诉你」那条通道（`task_updates`），点击落到「工作区」，而工作区顶部正好是 M4.31 加的那条提示条，再点一下就进会话里的提问卡。这样不用改 Kotlin，也不用新增权限。

## 验收证据

| 项 | 结果 |
|---|---|
| 新增 `app/test/desktop_question_scroll_m4_35_test.dart` | 2 例：长卡片下对话列表高度 > 120；最后那个选项一开始点不到、卡内拖 260 像素后可以点到 |
| 反证（把卡片区放大到屏高 1.2 倍） | 两例都失败，`Actual: <0.0>` —— 与线上症状一致，说明用例真的在盯这个 bug |
| 新增 `app/test/question_notice_m4_35_test.dart` | 5 例：发通知且标题点明「在等你回答」/ 不重复发 / 答完收回 / 开关关掉一条不发 / 两个会话各一条 |
| `flutter test test/` | **430/430 PASS** |
| 受影响的老用例 | `desktop_question_m4_23_test.dart`（2 例）与 `desktop_live_m4_14_test.dart`（1 例，断言源码含 `if (_approvals.isNotEmpty)`）跟着改：高度比例从 42% 调到 55% 后，「提交」按钮重新落在可见区内，源码断言改成新的合并条件 |

## 构建

```
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app
flutter build apk --release
```

- 环境：`JAVA_HOME=C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1`、`ANDROID_HOME=C:\Users\user\dsh-tools\android-sdk`
- APK：**73,049,346 字节**，versionCode **61**，SHA256 `0B496D9014131B5C3250CDB1261A3080EE86E0605022C47E21623A9083D38BE2`
- 三处同哈希：`dist\DeepSeek-Remote-AI-v0.4.35-m4.35.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.35-m4.35.apk`
- `/api/v1/app/version` 回读：`versionCode 61 / 0.4.35-m4.35 / 73,049,346 / 0b496d90…`

## 限制与下一步

- **只在轮询到的时候发**（工作区页那颗 5 秒定时器）。手机进程被系统杀掉、或者没连上电脑时不会有任何通知——真正的「锁屏推送」还要前台服务常驻 + 原生通道，那是另一件事。
- 通知只要出现就发，**哪怕你正开着那张卡**。没有做「正在看就不响」的判断，嫌吵可以关掉「等待授权提醒」。
- 卡片区高度是屏高的 55%：超长卡片（4 个问题以上）仍然要在卡内滚动才看得全，按钮也在滚动区里。
- 通知点击只落到「工作区」，不会直接打开那条会话——会话 id 已经带在通知里（`sessionId`），下一步可以让它直达。
- 留着的坑：抽屉「历史会话」在插件直连下永远是空的（走 M1.1 旧接口 `GET /api/v1/conversations` → 404），修它还是把「电脑」页做强，等你定；`HMR transactions cannot be nested` 让插件改动每次都得完整重开 DSH。
