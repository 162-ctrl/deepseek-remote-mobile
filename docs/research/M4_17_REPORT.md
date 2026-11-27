# M4.17 桌面直播的对话排版对齐官方 App

## 一句话结论

用户第三次贴出官方 App 的对话截图（「对话做成这样」）。前两次改的是**排版能力**
（M4.12 引入 Markdown）与**内容干净**（M4.16 过滤注入与推理），但页面骨架还是我们自己的：
助手回复外面套着一层浅底卡片 + 左侧强调竖条，工具记录写成「过程 · 24 步（点开看）」，
顶部是一张 Panel 卡片、副标题直接怼一串 `D:\Projects\…` 绝对路径。
M4.17 把这三处改成官方写法：**回复就是正文**、**「已完成 · N 次工具调用」**、
**顶部一条胶囊 + 「本机 · 目录名」**。

## 对照

| 位置 | 之前（我们） | 现在（对齐官方） |
| --- | --- | --- |
| 助手回复 | `Container` 浅底 + 左边 3px accent 竖条 + 圆角 16，像一张消息卡 | 直接 `MarkdownText` 正文 + 底部动作行，不套容器 |
| 工具记录 | `⏱ 过程 · 24 步（点开看）` | `✓ 已完成 · 24 次工具调用` / `⟳ 进行中 · …`，右侧向下箭头 |
| 顶部 | Panel 卡片：标题 + `monospace` 绝对路径 + 「直播中 · N 条消息」 | 胶囊：标题 + `● 本机 · deepseek手机端` + 「直播中 · N 条」 |

## 改动（手机端 `0.4.17+44`）

- `app/lib/screens/desktop_session_screen.dart`
  - 列表 `itemBuilder` 去掉助手回复的卡片包装，`return _EventRow(event: event);`
    （`ChatItemView` 的 assistant 分支本来就是纯 `MarkdownText` + `_AnswerActions`，
    只是被外面那层容器裹成了卡片）。
  - 工具条改成 `'${_running ? '进行中' : '已完成'} · ${_toolCallCount} 次工具调用'`，
    图标 `Icons.autorenew_rounded`（进行中）/ `Icons.check_circle_outline_rounded`（已完成），
    圆角 12，仍点开半屏「过程」。
  - `_LiveHeader` 从 `Panel` 换成 radius 22 胶囊，底色 `palette.card` + `palette.line` 边框；
    副标题 `'本机 · $folder'`，`folder` 由新增的顶层函数 `desktopFolderName(cwd)` 取最后一段
    （取不到就只写「本机」）。
  - `liveEmptyHint(hasEvents: true)` 文案跟着改成「点上面那条看完整记录」——旧文案还在说「过程」，
    而屏幕上已经没有「过程」这个词了。

## 验收证据

| 项 | 结果 |
| --- | --- |
| `flutter test test/` | **366/366 PASS**（361 + 新增 5） |
| 新增 `app/test/desktop_live_m4_17_test.dart` | 5 例：回复不套卡片（源码不再有 `left: BorderSide(color: palette.accent`）、工具条文案与图标、胶囊副标题、`desktopFolderName()` 四个入参 |
| 受影响的旧测试 | `app/test/desktop_live_m4_14_test.dart` 的空态断言改用「工具调用」而不是「过程」 |
| 版本三件套 | `pubspec.yaml` `0.4.17+44`、`local.properties` `0.4.17/44`、`build.gradle.kts` `0.4.17-m4.17`、`app_version.dart` `kAppVersionCode = 44` |
| APK | **72,655,418 字节**，SHA256 `5403BC368E0238586D610358A44E949067682D62BDA606FE5A97137E3F6797AC`，`aapt2`：`versionCode='44' versionName='0.4.17-m4.17'`，minSdk 24 / targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.17-m4.17.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.17-m4.17.apk`（三处同哈希） |
| 接口回读 | `GET /api/v1/app/version` → `versionCode 44 / 0.4.17-m4.17 / size 72655418 / sha256 5403bc36…` |
| 电脑端插件 | 不用改（0.2.22 已生效，`/api/v1/health` 报 `version: 0.2.22`） |

## 构建命令（中文路径下 AOT 会炸，必须换 ASCII 目录）

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"   # 不是 jdk 根目录
robocopy "<项目根>\app" C:\Users\user\dsh-tools\build\dsh-app /E `
  /XD build .dart_tool .gradle .idea .cxx /XF *.iml            # exit=1 就是复制成功
cd C:\Users\user\dsh-tools\build\dsh-app; flutter build apk --release
```

## 限制与下一步候选

- 官方回复底部那排动作是「复制 / 分享 / 重新生成 / 更多」，我们目前只有「复制 + 时间」；
  **重新生成**需要插件支持重放一轮，属于新能力，不是排版。
- 官方每条回复左侧有头像（我们的 `ChatItemView` 在首页有，直播页 `_EventRow` 没走头像分支），
  真要一致得给直播页也加一列头像。
- 官方的「已完成 · N 次工具调用」是**内联展开**（点开在对话流里就地铺开步骤），
  我们点开是底部半屏「过程」面板 —— 信息一样，手感不同。
- 对话里的「已存档」徽标、底部「只能看不能继续发指令」提示仍是我们自己的形态，官方没有对应物。
- 手机需重新配对：隧道域名又变了（`https://<公网隧道>.trycloudflare.com`），
  `GET /api/v1/pair/info` 取当前配对码即可。
