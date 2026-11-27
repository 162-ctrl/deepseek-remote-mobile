# M4.6 报告：AI 助手恢复「手机 / 电脑」两档（默认手机）

> 更新：2026-11-14 · 手机端 0.4.6-m4.6（versionCode 33）· 插件 0.2.12（本轮无插件改动）

## 1. 一句话结论

AI 助手页顶栏恢复「手机 / 电脑」两档切换，**打开默认停在手机档**（云端 API Key 直连，不经电脑），点「电脑」才进和电脑上的 AI 对话；手机档顶栏胶囊直接显示云端接口状态并可一点改设置，两档常驻、来回切不丢对话。

## 2. 起因与根因

| # | 现象（用户反馈） | 根因 | 修复 |
| --- | --- | --- | --- |
| 1 | 「ai助手分手机和电脑」 | M4.2 为了「打开就是对话」把 M2.9 的 `_LocalDesktopSwitch` 整段删了，手机档（云端直连）只剩未连接页里的一个按钮 | `assistant_screen.dart` 重新引入 `_mode` 与 `_ModeSwitch`，默认 `'phone'` |
| 2 | 切档会丢云端对话 | 若按 mode 二选一渲染，切回手机档时 `CloudChatScreen` 会被重建，历史和输入清空 | 两档都放进 `IndexedStack`（`index: phone ? 0 : 1`），常驻同一棵子树 |
| 3 | 手机档没有任何设置入口 | 内嵌的 `CloudChatScreen(embedded: true)` 不画 AppBar，`_editConfig` 够不到 | 新增 `CloudChatController`（`editConfig()` / `isConfigured` / `modelName`），顶栏胶囊点击即 `controller.editConfig()` |
| 4 | 测试里 `pumpAndSettle` 超时（页面永不停帧） | 内嵌云端页常驻后，未配置时一直转 `CircularProgressIndicator`；另一个原因是被 IndexedStack 藏起来的子树里的转圈仍算作「有帧调度」 | 云端页加载态改成静态文案；另修 `_phoneMode` 不再强制把未连接时钉在手机档（否则用户切「电脑」会被弹回） |

## 3. 插件端

本轮无改动（保持 0.2.12），`tools\verify-plugin-m4.ps1` 仍 11 项。

## 4. 手机端

- `lib/screens/assistant_screen.dart`
  - 新增 `String _mode = 'phone'`（默认手机档）与 `bool get _phoneMode => _mode == 'phone'`。
  - 新增 `_ModeSwitch({mode, onChanged})`：38 高胶囊，两项「手机」（`Icons.smartphone_rounded`）/「电脑」（`Icons.computer_rounded`），选中项用 `palette.card` 底 + `w600`。
  - `build()`：正文改为 `IndexedStack(index: phone ? 0 : 1, children: [CloudChatScreen(embedded: true, controller: _cloudController, onChanged: _onCloudChanged), 原来的电脑档 Column / _ConnectEmpty])`。
  - `_HomeHeader` 新增 `cloudMode` / `cloudModel` / `cloudConfigured`：手机档胶囊显示「云端直连 · <模型名>」或「云端直连 · 未设置接口」，点击 `_openCloudSettings()` → `_cloudController.editConfig()`；手机档不显示「历史会话/分享」以外的电脑按钮。
  - `switchModeForTest(String mode)`（`@visibleForTesting`）：测试直接切档，避免被其他页面的同名文字干扰。
- `lib/screens/cloud_chat_screen.dart`
  - 新增 `CloudChatController`（`_state` 弱引用、`notifyChanged`、`isConfigured`、`modelName`、`editConfig()`）。
  - `CloudChatScreen` 新增 `controller` 与 `onChanged` 参数，`initState` / `didUpdateWidget` / `dispose` 维护绑定。
  - 加载态从 `CircularProgressIndicator` 改为「正在读取云端接口设置…」静态文案（常驻时不再永不停帧）。
  - 配置读取与保存后都回调 `notifyChanged` + `widget.onChanged`，首页顶栏的接口状态实时更新。
- 测试
  - 新增 `test/assistant_mode_m4_6_test.dart`（3 用例）：默认手机档且顶栏显示「云端直连 · 未设置接口」；切电脑档顶栏换成设备名、切回手机档云端页仍在；未配置的云端页 `pumpAndSettle` 能返回且没有转圈。
  - `test/attachment_m4_2_test.dart`：两档切换恢复后，附件用例先 `switchModeForTest('desktop')` 再断言（M4.2 那条「没有模式切换」的断言改成「电脑档附件入口常驻」）。
  - `test/empty_state_test.dart`、`test/widget_test.dart`：默认档改成手机档后，空态与连接入口断言前先切到电脑档；启动测试先断言顶栏是云端直连。
  - 版本断言（`theme_m2_3_test.dart` 测试名「M4.6」、`empty_state_test.dart`、`widget_test.dart`）→ `0.4.6+33` / `0.4.6-m4.6`。
- 版本：`0.4.6+33` / `0.4.6-m4.6`（`pubspec.yaml`、`local.properties`、`build.gradle.kts`、`app_version.dart` 同步）。

## 5. 验收证据

| 项 | 结果 |
| --- | --- |
| `test/assistant_mode_m4_6_test.dart` | 3/3 通过 |
| `flutter test` 全量 | **291/291 通过**（M4.5 288 + 新增 3） |
| `flutter analyze` | 22 issues，无 error（历史 warning/info，本轮无新增 error） |
| release APK | 72,015,286 字节，SHA256 `29443BE3C6F739D2AB8EC80C7B15F640D7FDA007E11D37FA78903C5FB04E5812` |
| APK 版本 | `versionCode=33`、`versionName=0.4.6-m4.6`、minSdk 24、targetSdk 36 |
| APK 签名 | `CN=Android Debug`，SHA-256 `341ef83b95f452bb50b5a6821aa2044334826971e27910d428abc5dab33f70d6`（与旧包一致，可覆盖安装） |
| 版本接口 | `GET /api/v1/app/version` → `{"versionCode":33,"versionName":"0.4.6-m4.6","size":72015286}`（插件从 `dist/DeepSeek-Remote-latest.apk` 读取，无需重启 DSH） |
| 发布物 | `dist/DeepSeek-Remote-AI-v0.4.6-m4.6.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.6-m4.6.apk`（三者同源） |

## 6. 生效步骤

1. 手机装 `dist/DeepSeek-Remote-latest.apk`（或「我的 → 检查更新」直接拿到 33）。
2. 打开 App：AI 助手页默认在「手机」档，顶栏是「云端直连 · 未设置接口」，点它填服务地址 / Key / 模型。
3. 点「电脑」：进和电脑的对话（附件、直播、通知都在这一档）；再点「手机」回到云端对话，历史还在。
4. 插件无需重启（本轮无插件改动）。

## 7. 已知限制

1. 手机档的云端设置存在手机本机（`CloudChatStore`），不会同步给电脑。
2. 两档常驻，会同时持有云端对话与电脑对话的状态，内存占用比单档略高。
3. 未连接电脑时「电脑」档显示「还没有连接电脑」空态（不再自动弹回手机档），这是刻意保留的用户选择。
4. 本批 `adb devices` 无设备，**真机未复测**：两档切换手感、顶栏胶囊点击、云端页键盘遮挡需插线再看一遍。

## 8. 下一步

- 真机复测 M4.6 + 之前挂着的 M4.2 / M4.3 / M4.4 观感项。
- 考虑把手机档的接口设置做成可导入/导出，方便多台设备共用。
- 两档记忆上次选择（本轮只保留进程内状态，冷启动回到手机档）。

## 9. 证据索引

- 报告：`docs/research/M4_6_REPORT.md`（本文件）
- 代码：`app/lib/screens/assistant_screen.dart`、`app/lib/screens/cloud_chat_screen.dart`
- 测试：`app/test/assistant_mode_m4_6_test.dart`、`app/test/attachment_m4_2_test.dart`、`app/test/empty_state_test.dart`、`app/test/widget_test.dart`
- 构建：`flutter build apk --release`（`C:\Users\user\dsh-build\app-remote`，requires `JAVA_HOME` + `ANDROID_HOME`）
