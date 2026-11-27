# M4.70 报告：打不开的文件不再给按钮（App 0.4.64+85）

## 一句话
这台手机没有能打开 `.docx` 的应用，「用其他应用打开」点了必然失败；现在文件页先问一句有没有可用的应用，没有就藏掉按钮、只留分享，不再让人点进死胡同。

## 之前的问题
| 现象 | 原因 |
| --- | --- |
| 用户装上 0.4.63 后仍说「还是不行」，截图是 toast「手机上没有能打开这种文件的应用…」 | 用户点的是「用其他应用打开」；这台手机没装 WPS/Office 阅读器，`Intent.ACTION_VIEW` 的 `resolveActivity` 返回 null，必然失败 |
| 页面上那个按钮看起来是可用的 | 之前只在点击后才知道打不开，属于「假入口」 |

## 改动
| 文件 | 改动 |
| --- | --- |
| `app/lib/services/file_opener.dart` | `FileOpener` 新增 `Future<bool> canOpenBytes(String fileName, {String? mimeType})`；`MethodChannelFileOpener` 走 `canOpenBytes`，`MissingPluginException` / `PlatformException` 一律按 `true`（宁可多给按钮，也不误藏）；`FakeFileOpener` 加 `canOpen` / `canOpenCalls` |
| `app/android/.../FileOpenBridge.kt` | `onMethodCall` 增加 `canOpenBytes` → `handleCanOpenBytes`：用 `Intent(ACTION_VIEW).setDataAndType(...)` 只做 `resolveActivity` 判断，不启动应用；异常按可打开处理 |
| `app/lib/screens/file_viewer_screen.dart` | 新增 `_canOpenExternal`；`_loadBytes()` 之后 `unawaited(_probeOpenable())` 问一次（文本类型跳过）；`_OfficePreviewFooter` / `_BinaryFallback` 加 `showOpen`，为 false 时不渲染「用其他应用打开」；兜底标题改成「这个文件只能在电脑上看」、正文指向「分享文件」；扫描件底栏补一句「这台手机没有能打开它的应用，可以分享出去看」 |
| `app/test/file_open_hidden_m4_70_test.dart` | 新增 3 例：扫描件预览无应用可开时藏按钮 + 提示 → 分享仍在 / 二进制兜底改文案 / 有应用时按钮照旧可点 |

## 验收
- 定向 5 个文件（`file_open_hidden_m4_70`、`office_text_m4_52`、`file_preview_m4_9`、`file_share_m4_64`、`docx_pages_m4_69`）→ **27/27**。
- 全量 `flutter test` → **553/553**（550 + 3）。
- `flutter analyze --no-pub` → 33 issues、**0 error**。
- 反证：把 `_probeOpenable` 的 `if (openable != _canOpenExternal)` 临时改成 `if (false)` → 两条「藏按钮」用例失败，恢复后 3/3。

## 交付
- App `0.4.64+85`（`0.4.64-m4.64`），APK **74,217,001 字节**，SHA256 `9C3F2A978B5AD905A7960884241F33B352B938F1100919B7EC9A29A9B58C4CF7`，`versionCode 85`。
- 四处同哈希（构建产物、`dist/DeepSeek-Remote-AI-v0.4.64-m4.64.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录同名 APK）。
- `tools/verify-release.mjs` 四项一致；`/api/v1/app/version` 的 `notes` 自动带 0.4.64 段。
- `docs/UPDATE_NOTES.md` 与 `app/assets/update_notes.md` 顶部已加 0.4.64 段；`received/` 投递 APK、更新说明、本报告。
- 插件未改（仍 0.2.69）。

## 限制与下一步
- 判断只看 MIME 有没有应用能接；有些应用会「接了但打不开」（例如只认 `.doc` 的旧阅读器），那种情况仍需点开才知道。
- 真正的解决办法仍然是装一个阅读器；App 能做的是「不让你点进必然失败的按钮」，并把分享入口摆在最显眼处。
- 遗留：M4.62 直播推送帧真机验证；M4.57 接收文件真机验收。
