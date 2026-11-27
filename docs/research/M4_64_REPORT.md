# M4.64 文件分享：打不开也不要卡死

一句话：手机上没装能打开某种文件的应用时，文件页现在能把文件**分享出去**（微信 / QQ / 文件管理器），不再只有一句「打不开」。

## 之前的问题

| 现象 | 原因 |
| --- | --- |
| 点「用其他应用打开」只弹「手机上没有能打开这种文件的应用」 | 这台手机没装 WPS，`ACTION_VIEW` 没有能处理的 Activity，`FileOpenBridge` 回 `NO_APP` |
| 提示里写着「可以先用「复制」或分享」，但页面里根本没有分享入口 | 「用其他应用打开」是唯一出口，`.docx` 文字预览的底栏、兜底面板、AppBar 都没有分享 |
| 用户只能看着正文，拿不到文件本身 | 文件是从电脑下载的字节流，没有落到用户能取的地方 |

## 改动

| 位置 | 改动 |
| --- | --- |
| `app/lib/services/file_opener.dart` | `FileOpener` 新增 `shareBytes(bytes, fileName, mimeType)`；`MethodChannelFileOpener` 走 `deepseek_remote/files` 的 `shareBytes`；`FakeFileOpener` 记录 `shared` / `shareCalls` / `lastShared`，可注入 `shareResult` |
| `app/android/app/src/main/kotlin/.../FileOpenBridge.kt` | 抽出 `prepareFile(call, dirName, result, action)` 负责校验字节、写缓存、回报错误；新增 `handleShareBytes`：写 `cacheDir/share/files/`，FileProvider 换 `content://`，`Intent.ACTION_SEND` + `EXTRA_STREAM` + `createChooser`；`handleOpenBytes` 复用 `prepareFile` |
| `app/lib/screens/file_viewer_screen.dart` | 新增 `_share()`；AppBar 在拿到字节时显示「分享文件」（`Icons.ios_share_rounded`）；`.docx` 文字预览底栏加「分享」；兜底面板加「分享文件」；打开失败的提示改成指路「点右上角「分享」发给别的应用或设备」 |
| `app/test/file_share_m4_64_test.dart` | 3 例：接收文件可分享、分享失败有提示、`.docx` 文字预览页也能分享 |
| 版本 | App `0.4.59+80`（`0.4.59-m4.59`） |

`file_paths.xml` 早就暴露了 `cache-path name="share" path="share/"`（M2.2 分享卡用的），这次复用同一目录下的 `share/files/`，不需要改 FileProvider 配置。

## 验收

- 定向：`flutter test test/file_share_m4_64_test.dart` → **3/3**。
- 全量：`flutter test` → **536/536**（原 533 + 3）。
- `flutter analyze --no-pub` → **7 issues、0 error**（都是既有遗留）。
- 反证：把 `_share()` 里的 `_opener.shareBytes(...)` 换成直接 `return`，第 1 例立刻失败（`shareCalls` 为 0），恢复后 3/3。

## 交付

| 项 | 值 |
| --- | --- |
| APK | `dist/DeepSeek-Remote-latest.apk` = `dist/DeepSeek-Remote-AI-v0.4.59-m4.59.apk` = 根目录 `DeepSeek Remote AI 手机端 v0.4.59-m4.59.apk` |
| 大小 | **73,361,342 字节** |
| SHA256 | `5A60CE79E561BB07F3D252440D99AF520B7109FACB5A63DED0087605050D7C29` |
| 版本 | `0.4.59-m4.59` / versionCode **80**（debug 签名，可覆盖升级） |
| 发布校验 | `tools/verify-release.mjs` 四项一致；`/api/v1/app/version` 回读 code 80、size、sha256 一致，`notes` 已带上 0.4.59 的更新说明 |
| 更新说明 | `docs/UPDATE_NOTES.md` 顶部新增 0.4.59 段，插件自动带进更新弹窗；同一份说明与 APK 放进 `received/` |

## 限制与下一步

- 分享面板是系统级的：微信 / QQ 是否出现在面板里，取决于对方 App 是否声明接收该 MIME（`.docx` 一般没问题，`.bin` 这类只会出现在「文件管理器」里）。
- 只有拿到字节的文件能分享（工作区文本预览走的是字符串接口，没有字节，暂不显示分享按钮）。
- 仍然不能「保存到手机相册/下载目录」——那是 `ACTION_CREATE_DOCUMENT`，需要处理 `onActivityResult`，下一版再补。
- M4.62 的直播推送帧真机验证、M4.57 接收文件真机点开验收仍挂着。
