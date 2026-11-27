# M4.14 直播页不再空手：首屏拉够正文 + 授权窗口放宽

- 日期：2026-11-16
- 版本：App **0.4.14+41**（`0.4.14-m4.14`）、电脑端插件 **0.2.21**
- 关联：M2.9.3 桌面直播、M2.9.4 手机应答授权

## 一句话结论

两条用户反馈其实是同一类毛病——**手机在「看起来应该能看见」的时候什么都没看见，而且没人告诉它为什么**：直播页正文 0 条（拉取窗口只够到一屏工具调用），授权请求不出现也不提醒（「在看」判据 2 分钟就过期、接管超时 90 秒静默放弃）。这一版把窗口、判据、说明文字都补齐了。

## 起因

| 反馈 | 原话 | 截图事实 |
| --- | --- | --- |
| 直播页空白 | 「每次点进去加载不出来对话」 | 徽标「直播中 · 0 条消息」、过程条「过程 · 41 步（点开看）」、正文空态「这个会话还没有可展示的内容」 |
| 授权不响 | 「这个需求的选择手机上没有出来也没有提醒」 | 电脑端弹出「确认需求」卡（选项 1/2、跳过、下一题）并「用时 15 分 8 秒」，手机端无对应提示 |

## 现状与差距

用真实手机 token 打 `GET /api/v1/desktop/sessions/<id>/events` 实测（会话 `session-55cdd3b7-…`，396 条消息、41 步工具）：

| 环节 | 实测 | 结论 |
| --- | --- | --- |
| 后端数据 | 无 `afterSeq` 时返回 80 条事件：tool-result 36、tool-call 35、assistant 5、turn-start/end 各 1、user 1 | **数据是全的**，正文确实在更早的位置 |
| App 过滤 | `_messages` 只留 user/assistant，同轮只留最后一段，代码块替换成「〔代码已省略〕」→ 80 条里抽不出正文 | 首屏窗口太窄才是根因 |
| 增量 | `afterSeq=0&limit=80` 只回 seq=8、20 两条 | 旧代码带 `afterSeq` 时**从头往后扫**，积压时永远追不上 |
| 授权 | `WATCH_WINDOW_MS = 2min`、`APPROVAL_TIMEOUT_MS = 90s`，超时 `finish('unavailable')` 且**不写日志** | 用户离开页面 2 分钟后再来的授权一定交回电脑，且手机上留不下任何痕迹 |

## 插件端改动（0.2.21）

### `listDesktopSessionEvents()` 重写取窗逻辑

```js
const MIN_CHAT_EVENTS = 12;
const MAX_TAIL_EVENTS = 600;
const CHAT_KINDS = new Set(['user', 'assistant']);
```

- 首屏（不带 `afterSeq`）：**从尾部倒扫**，直到 `events.length >= limit && chat >= MIN_CHAT_EVENTS`，或触及 `MAX_TAIL_EVENTS` 硬上限，然后 `reverse()` 回正序。忙会话哪怕连着一屏工具调用，也会继续往前捞到至少 12 条对话。
- 带 `afterSeq`：同样从尾部倒扫，`if ((Number(log[i]?.seq) || 0) <= afterSeq) break;` 后 `reverse()`。积压时手机拿到的是**最新一段**，而不是最早的几条（追不上就一直落后）。

### 授权接管窗口

```js
const WATCH_WINDOW_MS = 10 * 60 * 1000;   // 原 2 分钟
const APPROVAL_TIMEOUT_MS = 2 * 60 * 1000; // 原 90 秒
```

- 「在看」由直播页轮询（1.5 秒）刷新，前台时一直是新的；放宽到 10 分钟是给「切后台/锁屏再回来」留余量。
- 接管超时不再静默：先 `log('接管授权超时，已退回电脑：<sessionId> · <tool>')` 再 `finish('unavailable')`，至少在日志里能查到「这条授权手机接管过但没答」。

## 手机端改动

| 文件 | 改动 |
| --- | --- |
| `app/lib/screens/desktop_session_screen.dart` | ①顶栏在 `_approvals` 非空时挂「待应答 N」红底胶囊（正文滚下去也看得见）；②空态文案抽成 `liveEmptyHint({required bool hasEvents})`：无事件时「这个会话还没有可展示的内容」，有事件但抽不出正文时「这一屏只有工具调用，点上面的「过程」看完整记录」 |
| `app/test/desktop_live_m4_14_test.dart` | 新增 3 例：空态两种文案、空态不再复用「还没有可展示的内容」的措辞、顶栏胶囊存在且受 `_approvals.isNotEmpty` 约束 |

`app/lib/widgets/markdown_text.dart`（M4.12）不动；`_messages` 的抽取规则也不动（只留 user/assistant 是为了手机上读起来像对话，不是日志）。

## 验收证据

| 项 | 结果 |
| --- | --- |
| 插件语法 | `node --check lib/index.js` / `node --check lib/server.js` 通过 |
| 插件测试 | `node --test "test/*.test.js"` → **46/46 PASS**（39 + 新增 7：`test/session-events.test.js`） |
| 新增插件用例 | 首屏带回正文、硬上限 600、凑够 12 条对话就停（312 条事件：每段 2 对话 + 50 工具）、增量取最新（seq 491–500）、无新闻返回空、打开页面会记账 watching、常量与超时日志断言 |
| App 测试 | `flutter test test/` → **356/356 PASS**（353 + 新增 3） |
| 版本核对 | `app/lib/app_version.dart` 41 / `0.4.14-m4.14`；`pubspec.yaml` `0.4.14+41`；`local.properties` 0.4.14 / 41；`build.gradle.kts:31` `versionName = "0.4.14-m4.14"` |
| 构建 | release APK **72,589,702 字节**，SHA256 `4FF436085E9F918E98924481E3C6563EBFD4D1D5615D7829D5472B3470C9F9D8`；aapt2 `versionCode='41' versionName='0.4.14-m4.14'`，minSdk 24 / targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.14-m4.14.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.14-m4.14.apk`（三处同哈希） |
| 插件安装副本 | `lib/index.js` / `lib/server.js` / `package.json` 哈希与源码树一致、version 0.2.21 |
| 真机 | **未复测**（`adb devices` 无设备），行为由插件单测 + widget 测试覆盖 |

## 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"   # 注意是子目录
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"

# 中文路径下 AOT 快照会挂（Unable to read file … app.dill），必须先复制到 ASCII 目录
robocopy "<项目根>\app" C:\Users\user\dsh-tools\build\dsh-app /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app
flutter build apk --release
```

## 限制与下一步候选

1. **没有真正的推送提醒**。这一版只做到「打开直播页就能看见待应答」；App 被系统冻结时轮询停止，授权仍然会先落到电脑弹窗。要做「手机响了」，得走 M4.4 的通知通道（本地通知 + 前台服务），属于独立一轮工作。
2. 接管窗口放宽到 10 分钟后，存在「用户早已离开，授权仍被手机接走、2 分钟后才退回电脑」的窗口，最坏让电脑等 2 分钟。若实测觉得吵，可改成「最近一次轮询在 60 秒内才接管」。
3. 「在项目里新建会话」仍按用户要求没做（m00891：「新建对话以后再说」）。
4. `tools/verify-plugin-m4.ps1` 在 PowerShell 5.1 下自身解析报 15 个 syntax error，14/14 自检仍未跑通。
