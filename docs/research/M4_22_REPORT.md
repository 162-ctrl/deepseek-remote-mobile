# M4.22 · 输入框里打出来的字不见了（文字颜色被主题吃掉）

> 交付：手机端 `0.4.22+48`（`0.4.22-m4.22`）。电脑端插件不变（仍是 `0.2.26`）。
> 一句话结论：`buildAppTheme()` 把 `textTheme` **整体替换**成了一个只写了 7 条样式的部分主题，
> `bodyLarge` 因此变成没有颜色的 `englishLike bodyLarge 2021`；而 `TextField` 的正文样式取的就是
> `bodyLarge` —— 于是「字打进去了、`onChanged` 也收到了、屏幕上只剩下一个光标」。

## 1. 一句话结论

插件市场搜索框里打字不显示，不是输入法、不是焦点、也不是控制器的问题，而是**主题里 `bodyLarge` 没有颜色**。
改成 `base.textTheme.merge(...)` 并补上 `bodyLarge` / `labelMedium` 的颜色后恢复正常；顺带加了一条
「每条正文样式都必须有颜色」的回归测试，防止以后再被主题改动吃掉。

## 2. 起因

用户 09:13 的截图（插件 → 插件市场）：

- 搜索框里**只有一个光标**，提示语「搜索插件名或关键字」也不可见；
- 但统计行写着「39 个插件 · 电脑端插件市场 · 已安装 18 个 · “dsh”」——关键字已经进去了，过滤也生效了；
- 输入法顶部还挂着 `dsn` 候选。

也就是说：**数据和状态全对，只有字画不出来**。

## 3. 排查与根因

| 排查项 | 结果 |
| --- | --- |
| `plugins_screen.dart` 的 `TextField` | 逻辑正常：`_searchController` 是 `final` 字段、`dispose()` 里释放、`onChanged` 写 `_marketQuery`、`_install()` 读 `_searchController.text` |
| 页面结构 | 没有 `Opacity` / `Stack` / `IgnorePointer` / `ClipRect` 包住输入框；`TabBarView` 也无异常 |
| `inputDecorationTheme` | 只设了 `fillColor` 与 `hintStyle`（`p.text3`），不会导致正文透明 |
| **`textTheme`** | **就是这里**：`ThemeData(copyWith(textTheme: TextTheme(...)))` 把完整的 Typography 整体换掉，没写到的样式（`bodyLarge` 首当其冲）退化成无色样式 |

取证方式是临时写了一个 widget 测试，把真实渲染出来的 `EditableText.style` 打出来：

```
EDITABLE style: TextStyle(debugLabel: (englishLike bodyLarge 2021).merge(unknown),
  inherit: false, size: 16.0, …)          ← 整行没有 color:
```

`TextField` 的正文样式来自 `theme.textTheme.bodyLarge`；一个没有 `color` 的样式在
`DefaultTextStyle` 链上最终会以「透明」绘制——看起来就是「什么都没打出来，只剩光标」。
提示语走 `InputDecoration.hintStyle`，也被这条样式覆盖（`hintStyle` 只给了颜色却没给字号/字重，
最终仍按 `bodyLarge` 的尺寸绘制，字是空的）。

## 4. 改动

### 手机端（`app/`，0.4.22+48）

- `app/lib/theme/app_theme.dart`：`textTheme:` 从「整体替换」改成 `base.textTheme.merge(TextTheme(...))`，
  并把 `bodyLarge`（`p.text` / 15 / 1.6）、`labelMedium`（`p.text2` / 12.5）补进这份局部主题；
  注释写明「直接替换会让没写到的样式变成无颜色，`TextField` 正好取 `bodyLarge`」。
- `app/lib/app_version.dart` 顶部新增 M4.22 段；`pubspec.yaml`、`android/local.properties`、
  `android/app/build.gradle.kts` 同步到 `0.4.22+48` / `0.4.22-m4.22`。
- 测试版本号断言同步：`theme_m2_3_test.dart`（用例名改「已升级到 M4.22」+ 6 处断言）、
  `empty_state_test.dart`、`widget_test.dart` 的 `手机端 v0.4.22-m4.22`。

### 新增测试

`app/test/theme_text_field_m4_22_test.dart`（2 例）：

1. 浅色 / 深色主题里 `bodyLarge`、`bodyMedium`、`bodySmall`、`titleLarge`、`titleMedium`、
   `labelMedium`、`labelSmall` 的 `color` 都必须非空；
2. 真实渲染 `PluginsScreen` 的市场 Tab：`EditableText.style.color` 非空，
   `enterText('dsh')` 之后 `find.text('dsh')` 命且 `controller.text == 'dsh'`。

## 5. 验收证据

| 项 | 结果 |
| --- | --- |
| 修前（诊断打印） | `EDITABLE style` 无 `color`；`bodyLarge` 为 `englishLike bodyLarge 2021` |
| 修后（同一打印） | `color: Color(alpha: 1.0, red: 0.0667, green: 0.0745, blue: 0.0941)` ≈ `#111318` |
| Flutter 全量测试 | `flutter test test/` → **379/379 PASS**（377 + 2） |
| 构建 | release APK **72,802,990 字节**，SHA256 `4BE811E0442A29B1C23DF354FBFD0DB2389EFFE63376036670C34223C8D85358` |
| 包信息（aapt2） | `versionCode='48' versionName='0.4.22-m4.22'`，minSdk 24 / targetSdk 36 |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.22-m4.22.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.22-m4.22.apk`（三处同哈希） |
| 回读 | `GET /api/v1/app/version` → `{"versionCode":48,"versionName":"0.4.22-m4.22","size":72802990,"sha256":"4be811e0…c8d85358"}` |
| 真机 | **未复测**（无 adb 设备）；需要用户装新包后确认搜索框有字 |

## 6. 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"   # 注意要指到子目录
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd "C:\Users\user\dsh-tools\build\dsh-app"
flutter build apk --release
```

> 中文路径下 AOT 快照会炸（`Dart snapshot generator failed with exit code 255`），
> 所以必须先 `robocopy` 到 ASCII 目录再构建；`robocopy` 返回 exit=1 表示「复制成功」。

## 7. 限制与下一步

- **真机未复测**：这次是主题层的问题，测试只能守住「样式有颜色」，最终还得靠用户装包看一眼。
- 同类风险：项目里还有别处直接用 `copyWith(textTheme: ...)` 或 `TextStyle()` 而不给颜色的地方，
  本次只补了 `TextTheme`；后续可以加一条 lint 式测试，扫描 `lib/` 里的 `TextStyle(` 是否都带 `color`（误报会多，暂缓）。
- 用户排队里还没做的两条：**审核（授权）操作手机上仍然不出现**、**存档会话不要新开一条、要在同一条对话里继续**。
- 长期遗留：`tools/verify-plugin-m4.ps1` 在 PS 5.1 下解析报 15 个 syntax error 未修；
  隧道域名每次重启都变（现为 `https://<公网隧道>.trycloudflare.com`，手机需重新配对）。
