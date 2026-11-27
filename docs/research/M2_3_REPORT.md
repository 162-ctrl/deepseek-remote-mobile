# M2.3 交付报告：手机端视觉重构（冷白极简 + 跟随系统深色）

> 日期：2026-11-03 · 契约：[`docs/design/M2_3_UI_DELTA.md`](../design/M2_3_UI_DELTA.md) v1.0 · 效果图：`docs/design/mockups/ui_a.png`（配色）/ `ui_b.png`（排版）
> 结论：**用户反馈「UI 太难看」已处理**——六页全部按「A 的配色 + B 的排版」重做，浅色为默认、跟随系统切深色，并新增「跟随系统/浅色/深色」三选持久化。`flutter test` **154/154** 全绿，APK **150,808,223 字节**，`versionName='0.1.4-m2.3' versionCode='5'`。

## 1. 一句话结论

视觉从「深色 + 重边框卡片」换成**冷白底、白色卡片、蓝色主色的干净界面**：大圆角、大留白、22px 标题、助手回复去掉气泡改左侧细竖线、用户气泡改 22/22/8 不对称圆角、底部导航改白底 + 选中圆点、输入框改胶囊 + 圆形发送键；深色模式用同一套 token 自动跟随系统。功能、文案与既有交互（折叠/排队/立即发送/分享/审批/紧急停止）全部保留。

## 2. 选型与设计系统

- **配色（A）**：底色 `#F6F7F9`、卡片 `#FFFFFF`、主色 `#2563EB`、正文 `#0F172A`、次要 `#475569`、弱文本 `#94A3B8`、线 `#E8EBF0`。
- **排版（B）**：卡片圆角 20、气泡 22/8 不对称、弹层顶部 24、输入/按钮 16、代码块 12、间距 20/16/12 的 4pt 网格、标题 22/w700。
- **深色**：底 `#0B1220`、卡片 `#121A2A`、主色 `#5B8DEF`，阴影几乎取消、靠明度与 1px 线分层。
- **外观**：`AppThemeMode(system/light/dark)`，`storageKey=app_theme_mode`，经既有 Kotlin `SettingsBridge`（SharedPreferences `deepseek_remote`）持久化；不再展示 6 套深色主题。

## 3. 改动清单

| 层 | 文件 | 说明 |
|---|---|---|
| 主题 | `app/lib/theme/app_theme.dart`（重写 446 行） | 浅/深双 `AppPalette`（§2 全部色值）、`AppRadius`/`AppSpace`/`cardShadow`/`accentShadow`、`buildAppTheme(Brightness)`、`context.appPalette`；旧 `AppColors` 仅保留给 `TaskStatus` 语义色 |
| 主题控制 | `app/lib/theme/theme_controller.dart` | 三选模式、load/select、持久化 |
| 外壳 | `app/lib/app.dart`、`screens/root_shell.dart` | `theme`/`darkTheme`/`themeMode`；自定义底部导航（白底 94% + 1px 线 + 选中圆点，高 78 + SafeArea） |
| 六页 | `screens/assistant_screen.dart`、`connect_screen.dart`、`tasks_screen.dart`、`control_screen.dart`、`projects_screen.dart`、`profile_screen.dart` | 全部 token 化 + 布局重排（见 §4） |
| 组件 | `widgets/common.dart`、`chat_items.dart`、`turn_fold.dart`、`approval_sheet.dart`、`timeline.dart` | 气泡/助手竖线/折叠行/工具卡/代码块/胶囊/面板/时间线/审批弹层重做 |
| 版本 | `pubspec.yaml`、`android/local.properties`、`build.gradle.kts` | `0.1.4+5`、`versionName=0.1.4`/`versionCode=5`、`versionName="0.1.4-m2.3"` |
| 测试 | 新增 `app/test/theme_m2_3_test.dart`（11 项）；更新 `ux_m2_2_test.dart` 主题组、`widget_test.dart` 设备名断言 | 154/154 |
| 文档 | `docs/mobile/README.md` | 新增「视觉规范（M2.3）」与能力表/结构/限制 |

## 4. 六页具体变化

1. **AI 助手**：顶部「AI 助手」22px + 设备副标题；连接状态条（在线圆点 + 设备名 + Agent/Harness 版本）；用户气泡蓝底白字；助手回复**无气泡**、左侧 3px accentSoft 竖线；思考过程 14 圆角折叠行；工具调用统一白色卡片（头部图标+标题+步数、tick 步骤行、浅灰代码块、`已完成 N 步 · 用时 Xs` 摘要）；排队气泡保留「立即发送/移除」；输入区改胶囊 + 圆形发送键 + 横向快捷 chips。
2. **连接电脑**：说明卡、地址输入（焦点蓝）、**6 格配对码**（当前格蓝边+浅蓝底）、测试/连接双按钮、绿色状态卡、连接步骤卡。
3. **任务中心/详情**：三张统计卡（进行中/已完成/失败）、筛选胶囊（选中蓝底白字）、任务卡（标题/状态胶囊/工作区/进度条/结果行）、详情时间线改竖线 + 圆点 + 工具胶囊。
4. **电脑控制**：设备卡、配对码卡、6 级权限列表（选中行浅蓝底 + 蓝点）、开关卡、远程桌面 P1 占位、紧急停止改危险色卡 + 滑块。
5. **项目管理**：安全说明条、工作区卡（图标/路径/文件数/权限胶囊/已授权）、授权新目录按钮。
6. **我的**：渐变圆头像、设备卡、审计日志卡、**外观三选**（跟随系统/浅色/深色）、关于 `v0.1.4-m2.3`。

## 5. 验收证据

| 项 | 结果 | 证据 |
|---|---|---|
| **A1 浅色默认** | `buildAppTheme(Brightness.light)` 为默认；主界面无 `AppColors.bg/surface/stroke/text` 硬编码（grep 仅剩 `models.dart` 的 TaskStatus 语义色） | 代码 + `flutter test` |
| **A2 跟随系统 + 三选持久化** | `ThemeController` load/select 单测（FakeSettingsGateway 写回）、MaterialApp 换色 widget 测试通过 | `app/test/theme_m2_3_test.dart` |
| **A3 六页重做** | 见 §4；助手竖线/气泡/折叠行/工具卡/6 格配对码/统计卡/权限列表/外观三选均落地 | 代码 |
| **A4 深色版** | 同一 token 体系；对比度单测：正文 ≥7:1、次要文本 ≥4.5:1 | `theme_m2_3_test.dart` |
| **A5 测试** | Lead 独立复跑 `flutter test` → **154/154 All tests passed（exit 0）**（143 旧 + 11 新） | 终端输出 |
| **A6 构建/版本** | Lead 独立 `flutter build apk --debug` 成功；`aapt dump badging` → **`versionCode='5' versionName='0.1.4-m2.3'`**；APK 150,808,223 字节（143.8 MiB），SHA256 `752016BE23160D6ACD079C81D436FD19D800CD406E10A4654B14D9226CF28100` | `aapt` 输出 |

## 6. 交付与下载

| 通道 | 地址 |
|---|---|
| 项目根目录 | `DeepSeek Remote AI 手机端 v0.1.4-m2.3.apk` |
| 公网（Cloudflare 临时隧道） | `https://<公网隧道>.trycloudflare.com/DeepSeek-Remote-v0.1.4-m2.3.apk`（HEAD 200，150,808,223 字节） |
| 局域网 | `http://192.168.1.x:8099/DeepSeek-Remote-v0.1.4-m2.3.apk`（HEAD 200） |

安装后确认：Android 设置→应用→DeepSeek Remote 应显示 `0.1.4-m2.3`；App「我的→关于」显示 `手机端 v0.1.4-m2.3 · 视觉重构版`。

## 7. 已知限制

1. 本机无真机/可用模拟器（adb 无设备、headless 模拟器不稳），**六页浅色/深色实机截图未补拍**；设计由 154 项测试 + 代码校验保证，最终观感以真机为准。
2. 深色对比度为单测按 token 计算，未做 Pixel 实机校色。
3. 分享卡（M2.2）仍按旧深色配色渲染？—— 本轮已一并 token 化，跟随当前主题；系统分享面板仍未真机实测。
4. `flutter analyze` 未跑（中文路径崩溃），质量门禁为 `flutter test` + `build apk`。
5. `team_task_*` 工具在本会话不可用，任务状态以本报告为准。

## 8. 下一步（候选）

1. 真机装上后用截图反馈逐页微调（间距/字号/图标），必要时出 M2.3.1。
2. 深色模式的实机对比度检查与状态色校准。
3. M3 功能线：远程桌面 L1、审计分区、多设备/OS 上报。

## 9. 证据索引

| 证据 | 路径 |
|---|---|
| 契约 | `docs/design/M2_3_UI_DELTA.md` |
| 效果图（选型来源） | `docs/design/mockups/ui_a.png`、`docs/design/mockups/ui_b.png` |
| 新增测试 | `app/test/theme_m2_3_test.dart` |
| 构建产物 | `app/build/app/outputs/flutter-apk/app-debug.apk` → 根目录 APK |
| 版本校验 | `aapt dump badging`：`versionCode='5' versionName='0.1.4-m2.3'` |
