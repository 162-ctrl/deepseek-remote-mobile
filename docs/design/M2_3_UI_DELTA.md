# M2.3 视觉重构契约（A 配色 + B 排版）

> 版本 v1.0 · 2026-11-03 · 唯一依据：本文件 + `docs/design/mockups/ui_a.png` / `docs/design/mockups/ui_b.png`（两版效果图，选型 A 的配色 + B 的排版）
> 目标：把「能用」的深色界面改成**干净、留白、浅色优先、跟随系统深色**的成品级界面；功能、文案、测试保持不变或只做必要更新。

## 1. 选型与总体原则

- **配色**：冷白底 + 白色卡片 + 蓝色主色（= A 效果图）。
- **排版/形状**：大圆角、大留白、22px 标题、22/8 非对称气泡、助手正文左侧 3px 浅色竖线、导航选中项下方 5px 圆点（= B 效果图的排版语言）。
- **浅色为默认，跟随系统切换深色**；「我的 → 外观」提供 跟随系统 / 浅色 / 深色 三选，持久化（复用 `deepseek_remote/settings`）。
- 不再使用「6 套深色主题」选择器；旧的 `AppThemeId`/`AppPalette` API 若被测试引用可保留为 deprecated，但 UI 不再展示。
- 干净优先：**去掉一切不必要的边框、渐变、发光**；层次靠留白、字号、字重、极淡的 1px 线；阴影只用两层极淡投影。

## 2. Design Tokens

### 2.1 颜色

| token | 浅色 | 深色 | 用途 |
|---|---|---|---|
| bg | `#F6F7F9` | `#0B1220` | 页面底色 |
| card | `#FFFFFF` | `#121A2A` | 卡片/输入框/气泡底 |
| line | `#E8EBF0` | `#1F2A3D` | 1px 分割线与卡片描边 |
| lineSoft | `#F0F2F5` | `#182234` | 更淡的分割/进度槽 |
| text | `#0F172A` | `#E8EEF8` | 主文本 |
| text2 | `#475569` | `#A8B6CC` | 次要文本 |
| text3 | `#94A3B8` | `#6B7C96` | 弱文本/占位 |
| accent | `#2563EB` | `#5B8DEF` | 主色/选中/发送 |
| accentSoft | `#EAF1FE` | `#17243B` | 主色浅底/选中胶囊 |
| onAccent | `#FFFFFF` | `#FFFFFF` | 主色上的文字 |
| bubbleUser | `#2563EB` | `#2F6FE0` | 用户气泡底 |
| bubbleUserText | `#FFFFFF` | `#FFFFFF` | 用户气泡文字 |
| codeBg | `#F8FAFC` | `#0E1626` | 代码块底 |
| codeText | `#334155` | `#C7D2E0` | 代码文字 |
| success | `#12B76A` | `#3DD68C` | 成功/在线 |
| warn | `#F79009` | `#FFB020` | 等待授权/演示标记 |
| danger | `#F04438` | `#FF5A5F` | 失败/紧急停止 |
| successSoft / warnSoft / dangerSoft | 各自 10–14% alpha | 同 | 状态胶囊底 |

### 2.2 圆角

- 卡片/弹层：**20**；底部弹层顶部：**24**
- 用户气泡：`22 22 8 22`；工具卡片内代码块：**12**
- 输入框/按钮：**16**；导航选中胶囊：**12**；状态胶囊/筛选 chip：**999**

### 2.3 间距与字号

- 页面左右内边距 **20**；卡片内边距 **16**；卡片间距 **12**；分组标题上 **22** 下 **10**。
- 标题 22 / w700 / ls 0.3；页面副标题 11.5 / text3；卡片标题 14 / w600；正文 14.2 / 行高 1.6；小字 12.5；注释 11。
- 导航栏高 **78**（含底部安全区按 `MediaQuery` 处理），图标 24，标签 10.5。

### 2.4 阴影（浅色）

- `0 1px 2px rgba(15,23,42,.04)` + `0 10px 30px rgba(15,23,42,.06)`
- 深色下阴影几乎不可见，用 `card` 与 `bg` 的明度差 + `line` 表达层次，阴影 alpha 降到 30%。

## 3. 组件规范

1. **AppBar**：透明底、无 elevation、标题 22/w700 左对齐；副标题 11.5/text3；右侧图标按钮 20，点击区 40。
2. **BottomNav**（`root_shell.dart`）：白底 94% + 顶部 1px line；选中项图标/文字用 accent，图标下方 5px 圆点；未选中 text3；图标用 Material 线性图标（outlined），选中用 rounded。
3. **卡片**（`SectionCard` 等）：card 底 + line 1px 描边 + 20 圆角 + 阴影；标题 14/w600，正文 12.5/text2。
4. **状态胶囊**（`TaskStatusBadge`/`DeviceStatusChip`）：高 22、圆角 999、底为状态色 12% alpha、文字状态色 11/w600、无描边。
5. **按钮**：primary = accent 填充、16 圆角、高 48、白字 14/w600、阴影 accent 26% 10/22；ghost = card 底 + line 描边。
6. **输入框**：card 底、line 描边、16 圆角、内边距 13/14、焦点 accent 1.6；占位 text3。
7. **对话气泡**：用户右对齐、bubbleUser 填充、白字 14/1.55、22/22/8/22 圆角、下方右侧 10.5 时间；助手**无气泡**、正文 14.2/1.6、左侧 3px accentSoft 竖线（`padding-left 13`）。
8. **工具卡片**：card 底 + line + 20 圆角；头部图标+标题 12.5/w600，右侧步数 10.5/text3；步骤行 tick 16（successSoft 底 + success ✓）、标题 12.8、耗时 11/text3；代码块 codeBg + 12 圆角 + mono 11.6/1.6，缩进 25；底部 `已完成 N 步 · 用时 Xs` 上方 dashed line（用 `CustomPaint` 或 1px lineSoft 即可），右侧「展开 ∨」。
9. **折叠行**：card 底 + line + 14 圆角、高 40、左侧 19 圆圈 accentSoft 内 ✦、文字 12.5/text2、右侧 ⌄。
10. **Composer**：card 底胶囊（28 圆角）+ line + 阴影，左 18 内边距，右侧发送按钮 36 圆角圆形 accent（白 ↑）；上方快捷建议 chip 横向滚动（12px、card 底、line、999）。
11. **审批 Sheet**：顶部 24 圆角；high-risk 标签 999 胶囊（warn 14% + #B54708），标题 17/w700，「拒绝」ghost + 「允许一次」primary 并排，均高 48。
12. **任务卡**：card + 20 圆角 + 阴影；标题 14/w600；元信息 11/text3 带 ▢ 图标；进度条高 5、lineSoft 槽、accent 填充、99 圆角；结果行 11.8/text2 或状态色。
13. **统计卡**：三张等宽 card，数字 20/w700 分别 accent/success/danger，标签 10.8/text3。
14. **筛选 chip**：未选中 card+line，选中 accent 底白字（或深色下 text 底白字）。
15. **空态**：居中图标 40/text3 + 标题 14/w600 + 说明 12.5/text3 + 可选 primary 按钮。
16. **弹层/Sheet**：白底、顶部 24 圆角、顶部 36×4 拖动条 lineSoft。
17. **深色模式**：所有组件改用 token，禁止残留硬编码深色值（`AppColors.xxx` 常量逐步替换为 `context.appPalette.xxx`）。

## 4. 页面清单

- **AI 助手**（`screens/assistant_screen.dart` + `widgets/chat_items.dart`）：顶部标题+设备副标题、连接状态条（在线圆点+设备名+版本）、消息流（气泡/助手正文/折叠行/工具卡）、排队气泡、快捷 chips、composer、后台审批提示。
- **连接电脑**（`screens/connect_screen.dart`）：标题栏（返回+演示模式标签）、说明卡、服务器地址输入、配对码 6 格（active accent 边框+accentSoft 底）、测试连接/连接按钮、状态绿卡、连接步骤卡。
- **任务中心/详情**（`screens/tasks_screen.dart`）：统计卡三张、筛选 chips、任务卡（状态胶囊/进度/结果）、详情时间线（左侧竖线 + 圆点 + 工具 chips）。
- **电脑控制**（`screens/control_screen.dart`）：设备卡（在线圆点/版本/最近在线）、配对码卡、权限等级列表（选中行 accentSoft 底 + accent 圆点）、开关卡、远程桌面 P1 占位、紧急停止卡（dangerSoft 底 + 滑块）。
- **项目管理**（`screens/projects_screen.dart`）：说明条、工作区卡列表（文件夹图标+路径+文件数+权限胶囊+已授权）、授权新目录按钮。
- **我的**（`screens/profile_screen.dart`）：用户卡（渐变圆头像 accent→teal）、设备卡、审计日志卡、外观（三选模式）、关于（v0.1.4-m2.3）。

## 5. 实施约束

- 只改 `app/` 与 `docs/mobile/README.md`；**零新增 pub 依赖**；不动 `backend/`、`agent/`、`tools/`。
- 保留所有现有功能与文案语义；测试若断言旧颜色/旧主题名，可按新设计更新断言，但**测试总数不得少于 143 且全绿**。
- 版本号：`pubspec.yaml` → `version: 0.1.4+5`；`android/local.properties` → `flutter.versionName=0.1.4`、`flutter.versionCode=5`；`build.gradle.kts` → `versionName = "0.1.4-m2.3"`；「我的→关于」显示 `手机端 v0.1.4-m2.3 · 视觉重构版`。
- 禁用 `flutter analyze`（中文路径崩溃），验收用 `flutter test` + `flutter build apk --debug`。

## 6. 验收标准

- **M2.3-A1 浅色主题**：进入 App 即浅色（系统浅色时），所有页面无深色残留（`AppColors.bg/surface/stroke/text` 硬编码不再用于主界面）。
- **M2.3-A2 跟随系统**：系统切深色后 App 自动切深色；「我的→外观」三选立即生效并重启保留（SettingsBridge 持久化）。
- **M2.3-A3 关键页重做**：AI 助手、连接、任务中心、电脑控制、项目、我的六页按 §3/§4 落地；对话页含气泡/助手竖线/折叠行/工具卡/代码块/composer。
- **M2.3-A4 深色版**：同一 token 体系出深色，对比度合格（正文与底 ≥ 7:1，次要文本 ≥ 4.5:1）。
- **M2.3-A5 测试**：`flutter test` 全绿且 ≥143；新增/更新测试覆盖主题切换与关键组件（≥8 项）。
- **M2.3-A6 构建**：`flutter build apk --debug` 成功；`aapt dump badging` 显示 `versionName='0.1.4-m2.3'`、`versionCode='5'`。

## 7. 交付物

- 代码改动（theme/widgets/screens/root_shell/app/theme_controller/tests）。
- 更新 `docs/mobile/README.md`（新增「视觉规范」小节 + 页面截图待补说明）。
- 汇报（≤30 行）：改动文件、验收 A1–A6 证据、测试数、APK 大小、已知限制。
