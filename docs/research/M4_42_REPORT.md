# M4.42 报告：抽屉新增「功能」页，「插件管理」先搬进去

日期：2026-11-20
版本：手机端 `0.4.42+68`（versionName `0.4.42-m4.42`），插件不变（`0.2.30`）

## 一句话结论

抽屉里在「工作区」和「我的」之间多了一页**功能**；「插件管理」从「我的 → 关于与更新」
搬进了这一页，位置从「系统设置」变成「能力入口」，以后加新能力都往这里放。

## 起因

用户原话：

> 做一个功能页面放到我的上面，先把插件拿出来放到里面

配的截图是当前抽屉（AI 助手 / 工作区 / 我的 + 手机对话 + 历史会话）。

## 改了什么

| 文件 | 改动 |
|---|---|
| `app/lib/screens/features_screen.dart`（新增） | 「功能」页：`KimiAppBar(title: '功能')` + 「扩展」分组 + 一行「插件管理」（图标块 + 标题 + 副标题 + chevron）→ 点击 push `PluginsScreen`；未连接时副标题变成「连接电脑后可以查看与开关插件」；底部一行灰字说明「这里放电脑端提供的能力入口」 |
| `app/lib/screens/profile_screen.dart` | 删掉「插件管理」`_ListRow` 与 `import 'plugins_screen.dart';`（736→约 720 行处的那一段），「关于与更新」里只留检查更新与「使用文档」 |
| `app/lib/screens/root_shell.dart` | `import 'features_screen.dart';`；`IndexedStack` 在 `TasksScreen` 与 `ProfileScreen` 之间插入 `FeaturesScreen(liveStore: liveStore, onOpenMenu: _openDrawer)`；`RootShellItems` 插入 `_NavItem('功能', Icons.widgets_outlined, Icons.widgets_rounded)`（顺序：AI 助手 / 工作区 / 功能 / 我的）；类注释「三个入口」改「四个入口」 |

索引影响：通知路由 `'tasks'` 仍是 1（工作区没动），「我的」从 2 变 3——`_index` 只由
`RootShellItems` 的位置驱动，没有硬编码 2 的地方（M4.41 已把这类硬编码改成 1）。

## 验收证据

新增 `app/test/features_m4_42_test.dart` **3 例**：

1. 抽屉里「功能」排在「我的」上面——`RootShellItems` 标签序列等于
   `['AI 助手', '工作区', '功能', '我的']`，且抽屉里「功能」的 y 坐标小于「我的」。
2. 功能页里能进插件管理——出现「插件管理」「查看与开关电脑上的插件」，点击后
   `find.byType(PluginsScreen)` 命中。
3. 「我的」里不再有插件管理——滚完整页后 `find.text('插件管理')` 与副标题都是 `findsNothing`。

同时把 M4.41 那条抽屉断言从「三个入口」改成「四个入口」
（`app/test/emergency_stop_m4_41_test.dart`）。

全量 `flutter test test/` → **466/466 PASS**（463 + 3）。

## 构建与发布

```powershell
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app
flutter build apk --release
```

- 产物：**73,049,398 字节**，SHA256 `9C0B7C8C6A45EE83834A1529B6B74E17D2F48C3DFA0E195F0CABDBE1E87632C7`
- aapt2：`versionCode='68' versionName='0.4.42-m4.42'`（minSdk 24 / targetSdk 36）
- 三处同哈希：`dist\DeepSeek-Remote-AI-v0.4.42-m4.42.apk`、`dist\DeepSeek-Remote-latest.apk`、
  根目录 `DeepSeek Remote AI 手机端 v0.4.42-m4.42.apk`
- `/api/v1/app/version` 回读：`{"versionCode":68,"versionName":"0.4.42-m4.42","size":73049398,"sha256":"9c0b7c8c…7632c7"}`

## 限制与下一步

- 「功能」页现在只有一行「插件管理」，是空架子；下一步可放定时任务、技能、设备文件等。
- 「使用文档」还在「我的」，没搬；要不要一起搬进「功能」待定。
- 抽屉「历史会话」在插件直连下仍为空（旧接口 `GET /api/v1/conversations` → 404），
  「修它还是删它」仍待用户定（M4.41 遗留）。
- M4.40 审计报告的 6 条插件问题未修（要改插件 + 完整退出重开 DSH）。
