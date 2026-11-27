# M4.12 报告：对话正文按 Markdown 排版（对齐官方 App 观感）

## 1. 一句话结论

用户发来一张 DeepSeek 官方 App 的对话截图问「你的对话不能做成这样的吗」——差别不在数据链路，而在**正文渲染**：我们的助手回复只认 `**加粗**` 和 `` `代码` ``，`###`、`- `、``` 代码块和 `|` 表格都**原样露在屏幕上**。M4.12 加了一个零依赖的块级 Markdown 解析器，把标题 / 列表 / 引用 / 分隔线 / 代码块 / 表格真正排出来，行内加粗、行内代码、链接各有样式，代码块带语言标签与「复制」，助手回复底部多一行「复制 + 时间」。电脑档与手机档（云端直连）共用同一套排版（App 0.4.12+39，未新增任何 pub 依赖）。

## 2. 起因：截图里的三处差异

| 截图里（官方 App） | 改之前（我们） | 改之后 |
|---|---|---|
| `### 同一个例子，两种结果` 显示为粗体小标题 | 原样显示 `### 同一个例子，两种结果` | 按级别给字号 + 加粗（w600） |
| 代码块有「text / dart」语言标签、右上角「复制」 | 代码块三反引号跟着正文一起露出来 | 顶栏（语言 · 复制）+ 代码区，12 圆角 |
| 「什么时候用哪个」是表格 | `\| 场景 \| 用 \|` 原样显示 | 表头浅底、逐行分隔线的真表格 |
| 段尾一排小按钮（复制 / 点赞 / 重新生成） | 只有长按菜单 | 正文下方常驻「复制 + 时间」，长按菜单仍在 |

## 3. 手机端改动（App 0.4.12+39）

### 3.1 新增 `app/lib/widgets/markdown_text.dart`

一个**零依赖**的块级解析器 + 渲染器（没有引 `flutter_markdown`，遵守项目「零新增 pub 依赖」的惯例）。

- `MarkdownParser.parse(String)` → `List<MdBlock>`，块类型常量在 `MdBlockKind`：
  - `heading`（`#`~`######`，带级别）、`paragraph`（多行合并，空行分段）、
    `bullet`（`- * +`，按缩进算 `indent`）、`ordered`（`1.` / `1)`，`level` 存原始序号）、
    `quote`（`>` 连续行）、`code`（``` 围栏，带 `language`；未闭合时吃到文末并保留内容）、
    `table`（表头 + `| --- |` 分隔行才算，空单元格保留）、`rule`（`---` / `***` / `___`）。
  - `blockKinds(String)` 给单测断言块序列。
- `buildInlineSpans(text, base)` → `List<TextSpan>`：`` `代码` ``、`**加粗**` / `__加粗__`、`~~删除~~`、`[文字](链接)`（无 `onLinkTap` 时不注册识别器）、`*斜体*`。正则带负向断言，`a * b * c` 这类中文里的孤立星号不会被当成斜体吃掉。
- `MdInlineText`：一行带行内样式的 `SelectableText.rich`（标题 / 列表项 / 引用 / 表格单元格共用）。
- `MarkdownText`：块级排版，块间距按类型给（标题上方 14、代码块/表格 14、同类型列表 6）。
- `_MarkdownCodeBlock`：34 高的顶栏（左侧语言，空语言显示 `text`；右侧「复制」把**原始代码**写进剪贴板），内容用 `SelectableText` + `kMono`。
- `_MarkdownTable`：`Table` + `FlexColumnWidth`，表头 `lineSoft` 底色、`w600`，横向纵向 0.8 分隔线，行数不齐时补空单元格。

### 3.2 `app/lib/widgets/chat_items.dart`

- `_AssistantText` 正文从 `_RichText` 换成 `MarkdownText`；时间不再单独一行，和新增的 `_AnswerActions`（复制按钮 + 时间）并成底部一行。
- `_RichText` 保留，继续服务用户气泡 / 思考 / 工具卡这类单行文本（行为不变）。

### 3.3 `app/lib/screens/cloud_chat_screen.dart`

- `_Bubble` 不再整体用 `Align` + 带边框的卡片包住：助手消息去气泡直接排版（`MarkdownText`），用户消息保留右侧浅底气泡；原先 320 的宽度上限去掉（手机上本来就窄，限制宽度的结果只是右边一大片空白）。

### 3.4 `app/lib/theme/app_theme.dart`

- `fontFamilyFallback` 追加 `Noto Sans CJK SC` / `Source Han Sans SC`，让国内机型少走一次字体回退。

### 3.5 版本

`kAppVersionCode = 39`、`kAppVersionName = '0.4.12-m4.12'`（`pubspec.yaml`、`android/local.properties`、`android/app/build.gradle.kts` 同步）。

## 4. 电脑端插件（0.2.20）

与「对话样式」无关的另一件事，同批交付（根因见 M4.11 报告第 4 节）：`resolveUploadDir` 以前只认**当前授权根**，附件偶尔会悄悄落到 `%USERPROFILE%\.dsh\dsh-plugin-m1\uploads`，用户以为传进项目了。

- `lib/index.js`：新增 `knownWorkspacePaths()`（先 `listDesktopWorkspaces()` 的 path，再 `workspaceRootsNow()`，去重）与 `findWorkspaceByName(wanted)`（`canonicalPath` 全路径相等、`basename` 相等，或 `statSync(join(path, wanted)).isDirectory()` 命中子目录）；`resolveUploadDir` 改为 `const hit = findWorkspaceByName(wanted);`。
- `test/upload-dir.test.js` 改写为 3 例（新增「findWorkspaceByName 优先认工作区列表」），`node --test 'test/*.test.js'` **31/31**。
- `package.json` → **0.2.20**；`tools/verify-plugin-m4.ps1` 门槛同步 0.2.20（3 处），上传检查改为**优先选路径末段与工作区名一致**的工作区（以前永远取第一个，正好是授权根顺序漂移时最容易失配的那个）。
- ⚠️ 运行中的 DSH 仍加载着 0.2.19 的代码，**需完整退出重开**让 0.2.20 生效。
- ⚠️ `tools/verify-plugin-m4.ps1` 本身在本机 PowerShell 5.1 下解析报错（15 个 syntax error，详见 M4.11 报告遗留问题），修好后才能跑 14/14 自检；本轮 M4.12 的自检改用直接调用 REST 接口核对。

## 5. 验收证据

| 项 | 结果 |
|---|---|
| `flutter test` | **344/344 全部通过**（327 + M4.12 新增 17） |
| 新增测试 | `app/test/chat_markdown_m4_12_test.dart` 17 例：解析器 9 例（块序列、标题级别、代码块语言与原始内容、「```」未闭合、表格空单元格、竖线文本不算表格、有序列表 / 分隔线 / 缩进、多行段落合并、空串）、渲染 4 例（标题不含 `###`、代码块语言标签 + 复制、`Table` 与单元格、列表圆点且正文不含 `- `）、电脑档正文 1 例、行内 3 例（加粗/代码/链接、无回调不注册识别器、孤立星号） |
| 插件单测 | `node --test 'test/*.test.js'` **31/31**（30 + 1） |
| 构建 | release APK（见第 6 节） |
| 真机 | **未复测**（`adb devices` 无设备）；排版由 widget 测试覆盖 |

## 6. 构建与发布

- 构建命令（本机 `flutter` / `java` 都不在 PATH，需要显式给）：

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk"
cd app; flutter build apk --release
```

- 产物：`app/build/app/outputs/flutter-apk/app-release.apk` → 发布为 `dist\DeepSeek-Remote-AI-v0.4.12-m4.12.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.12-m4.12.apk`（沿用 debug 密钥，可覆盖安装）。

## 7. 已知限制与下一步候选

- Markdown 支持到「块级 + 行内」这一层：**不做**嵌套列表、脚注、HTML、图片语法（`![](url)` 会被当普通文本），表格单元格里不解析块级元素。
- 代码块没有语法高亮（官方 App 有）；语言标签只是文本。
- 链接点击暂不处理（`onLinkTap` 留了接口，接上系统浏览器是一行的事）。
- 段尾操作只有「复制 + 时间」，官方 App 还有「重新生成 / 点赞」，前者要接云端重发、后者要先有反馈通道，留到后续。
- 下一步候选：①工作区卡片显示「N 个存档会话」与最近活动时间；②存档「恢复成新会话」；③把 plugin-market 索引源写进 profile（M4.11 §7 未完成的候选）。
