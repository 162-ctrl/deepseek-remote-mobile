# M4.2 交付报告：AI 助手页打开就是对话 + 手机附件真正能用

- 日期：2026-11-13
- 版本：手机端 **0.4.3-m4.2（versionCode 29）**；DSH 插件 **0.2.11**（需完整退出重开 DSH 生效）
- 状态：代码、单测（267/267）、release APK 已完成并发布；**真机复测尚未进行**（交付时 adb 已掉线，用户选择先不测）

## 1. 一句话结论

用户反馈："AI 助手页不应该是直接对话吗，而且只能对话，干不了其他的事，文件、相册、拍照呢"。M4.2 把三件事一起修掉：
① **首屏就是对话**——删掉「手机 / 电脑」两档切换和整屏欢迎大图，连上电脑后直接显示消息流 + 输入框，空对话只留一行提示和三个建议胶囊；
② **附件入口常驻**——拍照 / 相册 / 文件三个按钮从「+」二级菜单提到输入框上方（与电脑端聊天窗同位置），已选图片带缩略图、显示将存到哪个工作区；
③ **附件真正到得了工作区**——附件上传时带上当前工作区名，电脑端插件把文件落到 `<工作区>/手机附件/`（以前落在 `%USERPROFILE%\.dsh\dsh-plugin-m1\uploads`，电脑端的 AI 根本看不到），发送后弹「已上传到电脑：N 个文件（工作区）」，指令里同时列出每个文件的绝对路径。
手机端 **flutter test 267/267**、`flutter analyze` 20 条（无 error，全是历史 warning/info）；release APK **71,867,762 字节**（`versionCode=29`、`versionName=0.4.3-m4.2`）。

## 2. 起因与范围

| 问题 | 根因 | 修复 |
| --- | --- | --- |
| AI 助手页打开是「手机 / 电脑」胶囊 + 大半屏欢迎语，不像聊天 | `AssistantScreen` 有 `_mode` 状态，默认 `'local'` 直接嵌 `CloudChatScreen`；未连电脑以外的路径都先经过 `_GreetingBlock` | 删除 `_mode` / `_LocalDesktopSwitch` / `_GreetingBlock`；连上即 `_buildMessages` + 输入条；未连接走 `_ConnectEmpty`（云端直连入口保留在这里） |
| 只能聊天，找不到文件 / 相册 / 拍照 | 附件入口在 `_Composer` 的「+」底部弹层里，且附件条只有选中附件后才出现 | `_AttachmentBar` 改为常驻：拍照 / 相册 / 文件三个胶囊按钮 + 已选附件（图片显示缩略图）+ 「附件会存到电脑「X/手机附件」」说明 |
| 附件发了，电脑端 AI 找不到 | `POST /desktop/upload` 落在插件状态目录 `uploads/` | 插件新增 `resolveUploadDir(workspace)`：按工作区名找 `<根>/<名>`，落 `手机附件/`；无工作区时落当前会话 cwd 的 `手机附件/`，最后才退回状态目录 |
| 上传完没有任何可见反馈 | `_send()` 只把路径拼进 prompt 文本 | 新增 SnackBar 回执「已上传到电脑：N 个文件（工作区）」；指令里仍带绝对路径供 AI 读取 |

## 3. 插件端（dsh-plugin-m1 0.2.11）

新增 / 修改文件：
- `dsh-plugin-m1/lib/index.js`
  - `createDesktopWorkspace(name)`：先在所有授权根目录里找同名已存在目录直接复用（幂等），没有才在第一个根下 `mkdir`。
  - 新增 `UPLOAD_DIR_NAME = '手机附件'` 与 `resolveUploadDir(requested)`：`<授权根>/<工作区名>/手机附件` → `<当前会话 cwd>/手机附件` → `<插件状态目录>/uploads`。
  - pageContext 注入 `resolveUploadDir`；`node:fs` 补 `statSync` 导入。
- `dsh-plugin-m1/lib/server.js`：`POST /api/v1/desktop/upload` 接受 body 里的 `workspace`（工作区**名字**），据此选择落盘目录，响应体不变（`{ok,name,path,size}`）。
- `dsh-plugin-m1/package.json`：0.2.10 → **0.2.11**。

没有新增 HTTP 路由；旧手机端（不带 `workspace`）行为完全不变。

## 4. 手机端（0.4.3-m4.2 / versionCode 29）

- `app/lib/screens/assistant_screen.dart`
  - 删除 `_mode`、`_LocalDesktopSwitch`、`_GreetingBlock`；`build()` 里连上即进入对话页。
  - 空对话改为一行 `直接说想做什么，电脑上的 AI 会在这里跑起来` + 三个建议胶囊（看这张图里的报错 / 整理这个目录 / 跑通构建和测试）。
  - `_send()`：上传时带 `workspace: _uploadWorkspace`，成功后 `_toast('已上传到电脑：N 个文件（工作区）')`；`_uploadWorkspace` 取 `live.pendingWorkspacePath` 的末段，否则取当前会话标题 `名字 · HH:mm` 的名字部分。
  - `_AttachmentBar` 重写为常驻附件行（`_AttachAction` 胶囊 + `_PendingAttachmentChip` 图片缩略图 / 文件图标）；`_Composer` 的快捷胶囊行在上传可用时改为 拍照 / 相册 / 文件，保证是**同一行**（避免溢出）。
  - 新增 `@visibleForTesting attachForTest / sendForTest` 供 widget 测试走真实发送路径。
- `app/lib/data/live_store.dart`：`uploadDesktopFile({name, bytes, workspace})` 透传工作区名。
- `app/lib/services/history_api.dart`：`uploadDesktopFile(baseUrl, {token, name, bytes, workspace})`，非空时写入 `workspace` 字段。
- `app/lib/app_version.dart` / `pubspec.yaml` / `android/local.properties` / `android/app/build.gradle.kts`：0.4.3+29 / `0.4.3-m4.2`。
- 新增测试 `app/test/attachment_m4_2_test.dart`（4 个用例）：workspace 写入请求体（去空格）、无工作区时不带字段、助手页无「手机/电脑」切换且附件按钮可见、发送附件时带上工作区且指令里含落盘路径。

## 5. 验收证据

| 项 | 结果 |
| --- | --- |
| `flutter test` | **267/267 通过**（M4.1 的 263 + 新增 4） |
| `flutter analyze` | 20 条，**无 error**（历史 warning/info） |
| 插件单测 | `node --test 'test/*.test.js'` **12/12 通过**；`node --check lib/index.js lib/server.js` 通过 |
| 现网接口（插件仍 0.2.8） | `POST /api/v1/desktop/upload` 返回 `C:\Users\user\.dsh\dsh-plugin-m1\uploads\...probe-cn.txt`——证明旧行为确实落在状态目录 |
| release APK | **71,867,762 字节**，SHA256 `E32F25E2BB09F4FA905E21C3CDB5E153E5A2728A3A0E654992662C685103A25E` |
| APK 版本 | aapt2：`versionCode='29' versionName='0.4.3-m4.2'`，minSdk 24 / targetSdk 36 |
| APK 签名 | `CN=Android Debug`，SHA-256 `341ef83b95f452bb50b5a6821aa2044334826971e27910d428abc5dab33f70d6`（与 0.4.2-m4.1 一致，可直接覆盖安装） |
| 真机复测 | **未做**（交付时 adb `no devices`，用户选择先不测） |

## 6. 生效步骤（必须做）

1. **完整退出 DSH 桌面应用并重开**（插件 0.2.11 才会加载）。
2. 跑自检：`pwsh -File tools\verify-plugin-m4.ps1`，期望 **9/9 PASS**（M4.2 新增「upload 按工作区落盘」检查，另把版本门槛升到 0.2.11）。
3. 安装 `dist\DeepSeek-Remote-latest.apk`（或根目录 `DeepSeek Remote AI 手机端 v0.4.3-m4.2.apk`），**重新配对**（插件 token 在重启后保留，但 App 内需确认已连接）。
4. 真机点一遍：AI 助手页首屏是否直接是对话 → 点「拍照」或「相册」选一张 → 输入一句话 → 发送 → 看回执与电脑端 `<工作区>\手机附件\` 目录。

## 7. 已知限制

- 附件只能落到**一级**工作区目录（`<授权根>/<工作区名>/手机附件`）；工作区在更深层时退回当前会话 cwd。
- 单文件上限仍是 20 MiB（`MAX_UPLOAD_BYTES`），超大视频会被拒。
- 发送前不压缩图片；一张 20 MB 原图会占用整条请求。
- 底部输入条固定发给**最新会话**；要发给别的会话需先在工作区页点进去。
- 未连接电脑时附件按钮不可用（云端直连页 `CloudChatScreen` 仍不带附件能力）。
- 真机未复测（见第 5 节）。

## 8. 下一步

- 真机复测 M4.2 首屏与附件链路（等设备接回 USB）。
- 考虑在工作区页显示「手机附件」目录里的最近文件，作为「电脑收到了什么」的可视凭据。
- 云端直连页（`CloudChatScreen`）补附件能力，避免「不连电脑就不能发图」。

## 9. 证据索引

- 报告：`docs/research/M4_1_REPORT.md`（上一轮）、本文件
- 自检脚本：`tools/verify-plugin-m4.ps1`（9 项）
- 测试：`app/test/attachment_m4_2_test.dart`、`app/test/plugin_gallery_test.dart`、`app/test/workspace_m4_test.dart`
- 构建产物：`dist/DeepSeek-Remote-AI-v0.4.3-m4.2.apk`、`dist/DeepSeek-Remote-latest.apk`、`DeepSeek Remote AI 手机端 v0.4.3-m4.2.apk`
