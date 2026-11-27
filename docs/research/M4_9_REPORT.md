# M4.9 报告：工作区里的图片 / PDF / Office 不再「无法预览」

## 1. 一句话结论

工作区文件查看器原来只认文本：图片、PDF、Word、Excel 一点就是「无法预览」。现在按扩展名分流——图片在 App 内放大看，PDF / Office 下载到手机后交给 WPS 或系统阅读器打开，插件同时补上 `GET /desktop/file/raw` 与 `POST /desktop/file/read` 两条通道（插件 0.2.13，App 0.4.9+36）。

## 2. 起因与根因

| 现象（用户反馈） | 根因 | 修法 |
|---|---|---|
| 「工作区的有些文件无法预览」 | `FileViewerScreen` 只走 `readWorkspaceFile`（文本接口），`content.binary` 为真时直接 `workspaceErrorLabel('BINARY_FILE')` | 按扩展名判断：图片 / PDF / Office 改走原始字节下载 |
| 插件把二进制一刀切拒掉 | `workspace-fs.ts` 嗅到 NUL 字节就抛 `BINARY_FILE: 这是二进制文件，暂不支持在手机上预览` | 新增 `readWorkspaceFileBytes`（校验授权根 + 禁止 `..`，上限 20 MB），路由 `GET /api/v1/desktop/file/raw` 直接回流 |
| 手机打不开 PDF / Word | 手机上没有解析库，App 也没有「交给系统应用」的通道 | 新增 `FileOpenBridge`（Kotlin）：字节写 `cacheDir/preview/` → `FileProvider.getUriForFile` → `ACTION_VIEW`；`file_paths.xml` 加 `preview/` |
| 手机档发 PDF 给云端模型没用 | M4.8 的 `CaretakerReader` 调的是 `/desktop/file/read`，插件一直没实现，只能静默退回「只发文件名」 | 插件实现 `readDesktopFileText`：文本按 UTF-8；`.pdf` 用 `pdf-parse`；`.docx/.pptx/.xlsx` 用 `JSZip` 抽 XML 文字；`.doc/.xls/.ppt` 明确提示另存 |

## 3. 电脑端插件（0.2.13）

- `lib/index.js`
  - `resolveWorkspaceFile(workspacePath, relativePath)`：工作区必须是 `workspaceRoots` 之一，相对路径不许含 `..`。
  - `readWorkspaceFileBytes(...)`：上限 `MAX_WORKSPACE_FILE_BYTES = 20 MB`。
  - `readDesktopFileText({name, data})`：上限 `MAX_READ_BYTES = 2 MB`；`TEXT_EXTENSIONS` 直接 UTF-8；`extractText` 处理 pdf / docx / pptx / xlsx；去掉控制字符。
  - pageContext 增加 `readWorkspaceFileBytes`、`readDesktopFileText`、`resolveWorkspaceFile`。
  - `import { join, dirname, basename, extname } from 'node:path'`（补 `extname`）。
- `lib/server.js`
  - `GET /api/v1/desktop/file/raw?workspace=&path=`：Bearer/?token 鉴权，200 回流二进制，`contentTypeOf()` 按扩展名给出 content-type；失败 400 `FILE_READ_FAILED`。
  - `POST /api/v1/desktop/file/read`：`{name, data}` → `{ok, name, text}`；失败 400 `FILE_READ_FAILED`，无此能力 501 `FILE_READ_UNAVAILABLE`。
- `package.json`：`dependencies` 新增 `jszip ^3.10.1`、`pdf-parse ^1.1.1`（`npm install --omit=dev`，15 个包）。
- 新增 `test/file-extract.test.js`（3 例）：docx 段落抽取、pptx 多页拼接、xlsx 共享字符串；`node --test 'test/*.test.js'` **15/15 通过**。

## 4. 手机端改动

- `app/lib/services/history_api.dart`：`downloadWorkspaceFile(baseUrl, {token, workspacePath, relativePath})` 用 `dart:io HttpClient` 直连取字节；错误体用新增的 `_bodyMessage()` 抠 `{code,message}`。
- `app/lib/data/live_store.dart`：`downloadWorkspaceFile({workspacePath, relativePath})`，未连接时抛 `还未连接电脑，无法打开这个文件`。
- 新增 `app/lib/services/file_opener.dart`：`FileOpener` 抽象 + `MethodChannelFileOpener`（channel `deepseek_remote/files`，方法 `openBytes`）+ 测试用 `FakeFileOpener`。
- 新增 `app/android/.../FileOpenBridge.kt`：校验大小（≤40 MB）、清洗文件名、写 `cacheDir/preview/`、`FileProvider` + `ACTION_VIEW` + `FLAG_GRANT_READ_URI_PERMISSION`；没有能处理的应用时回 `NO_APP`。`MainActivity.kt` 注册。
- `app/android/app/src/main/res/xml/file_paths.xml`：新增 `<cache-path name="preview" path="preview/" />`。
- `app/lib/screens/file_viewer_screen.dart`：
  - 新增 `enum FilePreviewKind { text, image, pdf, office, other }` 与 `FilePreviewKind previewKindOf(String fileName)`。
  - `_load()` 分流：图片/PDF/Office 走 `_loadBytes()`（下载原始字节）；文本接口返回 `binary: true` 时也自动改走下载。
  - 图片：`InteractiveViewer(minScale:0.8, maxScale:6)` + `Image.memory`，失败时显示「用其他应用打开」兜底。
  - PDF / Office / 其它二进制：`_BinaryFallback` 面板 + `FilledButton('用其他应用打开')`。
  - AppBar 在二进制模式下换成「用其他应用打开」「刷新」两个按钮；404 时提示「电脑端插件版本过低……升级插件（0.2.13+）」。
- `app/pubspec.yaml`：新增 `open_filex`（实测内容自带 `file_picker`/`image_picker`/`path_provider`；原生打开走自己的 Kotlin 桥，不依赖它）。
- 新增 `app/test/file_preview_m4_9_test.dart`（8 例）：扩展名分流 3 例 + 查看器 5 例（图片内联 + 交系统应用、PDF 提示文案 + 调起、文本接口说二进制时回退下载、404 可读提示、文本仍走原文预览）。

## 5. 验收证据

| 项 | 结果 |
|---|---|
| `flutter test` | **315/315 全部通过**（307 + M4.9 新增 8） |
| `flutter analyze` | **23 issues，0 error**（均为历史 warning/info） |
| 插件单测 | `node --test 'test/*.test.js'` **15/15** |
| 语法检查 | `node --check lib/index.js`、`lib/server.js` 均通过 |
| release APK | `build\app\outputs\flutter-apk\app-release.apk`，**72,311,070 字节**，SHA256 `A355AD1AC2727180A80DE1CCA77399D833B463FF3740C0E6640286100194F71A` |
| APK 版本 | aapt2：`versionCode='36' versionName='0.4.9-m4.9'`，minSdk 24、targetSdk 36 |
| APK 签名 | `CN=Android Debug`，SHA-256 `341ef83b95f452bb50b5a6821aa2044334826971e27910d428abc5dab33f70d6`（与旧包一致，可覆盖安装） |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.9-m4.9.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.9-m4.9.apk`（三者同源） |
| 更新接口 | `GET /api/v1/app/version` → `{"versionCode":36,"versionName":"0.4.9-m4.9","size":72311070,...}` |
| 验证脚本 | `tools/verify-plugin-m4.ps1` 门槛升到 0.2.13，新增 2 项检查（`file/raw` 取字节并校验 401、`file/read` 读回文本），共 13 项 |

## 6. 生效步骤

1. **完整退出 DSH 桌面应用再打开**（让插件 0.2.13 与新增的 `pdf-parse`/`jszip` 依赖被加载）；插件没加载时报 `file/raw` 404。
2. 跑自检：`powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-plugin-m4.ps1`，期望 **13/13 PASS**（`-NoCreate` 只跑只读项）。
3. 手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.9-m4.9 / versionCode 36，可覆盖安装），重新配对。
4. 手机上打开工作区 → 点一张 .jpg、一个 .pdf、一个 .docx：图片应在 App 内显示；PDF/Word 显示「用其他应用打开」，点了由 WPS/系统阅读器打开。

## 7. 已知限制与下一步

- `file/raw` 单文件上限 20 MB、`file/read` 上限 2 MB；超出会报错。
- `.doc / .xls / .ppt` 旧二进制格式不支持解析，会提示在电脑上另存为 docx/xlsx/pptx。
- 图片以外的格式依赖手机上装了能打开它的 App（PDF 需 WPS 或系统 PDF 阅读器）。
- 图片预览不解码超大图（如 8000px 长图），可能较慢；后续可加缩略图。
- 仍未真机复测（`adb devices` 无设备）：`ACTION_VIEW`、`FileProvider` 的 `content://` 授权、WPS 实际拉起这三步都需要在手机上点一遍。
- 下一步候选：`file/raw` 支持 `Range` 断点续传与缩略图；把 `/desktop/file/read` 的结果缓存到手机，避免同一文件重复解析。

## 8. 证据索引

- 插件：`dsh-plugin-m1/lib/index.js`（`resolveWorkspaceFile` / `readWorkspaceFileBytes` / `readDesktopFileText` / `extractText`）、`dsh-plugin-m1/lib/server.js`（两条路由 + `contentTypeOf`）、`dsh-plugin-m1/test/file-extract.test.js`、`dsh-plugin-m1/package.json`（0.2.13 + 依赖）。
- 手机端：`app/lib/screens/file_viewer_screen.dart`、`app/lib/services/file_opener.dart`、`app/lib/services/history_api.dart`、`app/lib/data/live_store.dart`、`app/test/file_preview_m4_9_test.dart`、`app/android/.../FileOpenBridge.kt`、`MainActivity.kt`、`res/xml/file_paths.xml`、`app/pubspec.yaml`。
- 验收：`flutter test` 315/315、`flutter analyze` 23 issues/0 error、`node --test` 15/15、`tools/verify-plugin-m4.ps1`（13 项）。
- 产物：`dist/DeepSeek-Remote-AI-v0.4.9-m4.9.apk`（72,311,070 字节）。
