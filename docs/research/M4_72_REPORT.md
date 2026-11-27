# M4.72 报告：修好「分享失败」与「打不开」（App 0.4.66+87）

## 一句话
两类失败跟「手机装没装能打开的应用」无关：生成 `content://` 地址时用了错误的组件——拿 androidx 的 `FileProvider.getUriForFile` 去配自写的 `ShareFileProvider`，它会去找 `FILE_PROVIDER_PATHS` 元数据，而 manifest 里没有，于是必然抛异常。

## 之前的问题
| 现象 | 根因 |
| --- | --- |
| 点「分享文件」→「分享失败：没能拉起系统分享面板」 | `handleShareBytes` 里 `FileProvider.getUriForFile(...)` 抛 `IllegalArgumentException: Failed to resolve canonical path`，被 `catch` 成 `SHARE_FAILED` |
| 点「用其他应用打开」→「手机上没有能打开这种文件的应用」 | 同一个异常在 `handleOpenBytes` 里被吞成失败，提示文案又把它误说成「没装应用」 |
| 「检测不到」| 已由 M4.71 修（`<queries>` + `queryIntentActivities`），但真正卡住打开的是上面的 URI 问题 |
| 自写 provider 只认两段路径（`share/x`、`updates/x`）| `FileOpenBridge` 写的是 `cacheDir/preview/x` 与 `cacheDir/share/files/x`，本来也不在支持列表里 |

## 改动
| 文件 | 改动 |
| --- | --- |
| `ShareFileProvider.kt` | 路径解析支持 `share/x`、`share/files/x`、`preview/x`、`updates/x` 四种；新增 `uriForPreview`、`uriForShare`（多段 `Uri.Builder`）；`getType` 按扩展名给全 MIME（png/jpg/webp/gif/pdf/docx/doc/xlsx/xls/pptx/txt/md/apk） |
| `FileOpenBridge.kt` | 两处 `FileProvider.getUriForFile` 改成 `ShareFileProvider.uriForPreview` / `uriForShare`；删掉 androidx import；`OPEN_FAILED` / `SHARE_FAILED` 的 message 改成原生原始原因（不再自己加前缀） |
| `file_opener.dart` | 抽象类加 `String? get lastError`；`MethodChannelFileOpener` 记录 `PlatformException.message`（`MissingPluginException` 记「这台手机没有安装文件通道（可能是旧版本）」）；`FakeFileOpener` 加 `lastErrorValue` |
| `file_viewer_screen.dart` | 分享/打开失败时若有原因就显示「分享失败：<原因>」/「打不开这个文件：<原因>」 |
| 测试 | `file_share_m4_64_test.dart` 新增「M4.72 原生给了原因就照原样报出来」 |
| 版本 | App 四处 → `0.4.66+87`；`app_version.dart` 顶部加 M4.72 说明；版本断言测试同步 |

## 验收
- 文件相关四个测试文件 **19/19**；全量 **554/554**；`flutter analyze --no-pub` 34 issues（其中 1 条是 `test/update_check_tile_test.dart` 既有的 unused parameter warning）、**0 error**。
- `flutter build apk --release` → `√ Built … (70.8MB)`；中途一次 `kernel_snapshot_program` 失败是 `FakeFileOpener` 没实现新 getter（`implements` 不会继承抽象类的默认实现），已补。
- `aapt2 dump badging` → `versionCode='87' versionName='0.4.66-m4.66'`；`verify-release.mjs` 四项一致。

## 交付
- APK **74,217,385 字节**，SHA256 `E6052AE6905E9C9724CFD2A77EEA00E5D7D7E49510951E03B28101785FD31B5E`。
- 四处同哈希（构建产物、`dist/DeepSeek-Remote-AI-v0.4.66-m4.66.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录同名 APK）。
- `UPDATE_NOTES.md` + `app/assets/update_notes.md` 顶部加 0.4.66 段；`received/` 投递 APK、更新说明、本报告。
- 插件未改（仍 0.2.69）。

## 限制与下一步
- 分享面板能起来之后，能不能真的「打开」仍取决于手机有没有对应的阅读器——没有就只显示分享。
- 建议 0.4.66 装上后分别验证：①对 PDF 点「用其他应用打开」（应弹出选择器或直接打开）；②点「分享文件」（应弹系统分享面板）；③若仍失败，提示里会带原生原因，把那条文案发我即可定位。
- 遗留：M4.62 直播推送帧真机验证；M4.57 接收文件真机验收。
