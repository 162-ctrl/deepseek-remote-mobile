# M4.29 下载卡片上的「取消下载」与「后台下载」

## 一句话结论

手机端更新下载的那张进度卡片，现在底部有两个按钮：**取消下载**（停下来、删掉半截文件）和**后台下载**（只收起卡片，下载继续，下完自动调起安装器）。下载动作从 `_UpdateCheckTileState` 搬进了独立的 `UpdateDownloadCenter`，所以关掉弹窗、甚至离开「我的」页，下载都不会断。

## 起因

用户发了下载进度卡片的截图（`正在下载 v0.4.28-m4.28 · 98% · 68.0 / 69.6 MB`），配文「加一个取消和后台下载」，随后又补一句「我说的是下载时的那个小卡片上加取消和后台下载」——确认要动的是那张卡片本身，不是「检查更新」列表行。

改之前这张卡片只有一个进度条和一行百分比：`_showProgressDialog()` 用 `StatefulBuilder` 建 dialog，`barrierDismissible: false`，没有 actions；`_downloadAndInstall()` 在 tile 的 State 里 `await _service.download(...)`，一旦页面被销毁就没有任何句柄能停下它，也没法「先收起来」。

## 改了什么

| 文件 | 改动 |
|---|---|
| `app/lib/services/update_service.dart` | 新增 `UpdateCancelToken`（`isCancelled` / `cancel()`）与 `UpdateCancelled extends UpdateException`（文案「已取消下载」）；`download()` 新增 `UpdateCancelToken? cancel` 入参，每写一帧查一次；命中后**先 `sink.close()` 再删 `.part`**（Windows 上删开着的文件会失败，这是第一版测试红的原因） |
| `app/lib/services/update_download_center.dart`（新增） | `UpdateDownloadCenter extends ChangeNotifier`：`start({info, baseUrl, token, cacheDirectory})` 把整段下载与进度都收进来；`cancel()`；`reset()`；状态位 `running / cancelled / error / file / received / total / ratio`，用 `notifyListeners()` 推 |
| `app/lib/widgets/update_check_tile.dart` | tile 只保留「要不要开始」；弹窗改用 `AnimatedBuilder(animation: _center)`，`barrierDismissible: true`（收起来 ≠ 取消），底部两个按钮：「取消下载」→ `_center.cancel()`，「后台下载」→ `Navigator.pop`；副标题按 `running/cancelled/error/file` 四态给文案；`_install()` 前先 `_center.reset()` |

## 验收证据

| 项 | 结果 |
|---|---|
| 单测（新增） | `app/test/update_cancel_m4_29_test.dart` **5/5**：真 `UpdateService` 取消抛 `UpdateCancelled` 且 `.part` 已删；`UpdateDownloadCenter` 进度 0→1 并留住产物；中心取消后 future 返回 null 且 `cancelled == true`；widget「后台下载只收卡片、下载继续并安装」；widget「取消下载会停下并提示已取消」 |
| 全量 | `flutter test test/` **404/404 PASS**（399 + 5） |
| APK | 72,950,978 字节，`0.4.29-m4.29` / versionCode **55**，SHA256 `21CB77AF0B3618BA483FA93D2CDDAB23511C6C31013E9C9D5305CAA7F6D82C8C`；`dist\DeepSeek-Remote-latest.apk`、`dist\DeepSeek-Remote-AI-v0.4.29-m4.29.apk`、根目录同名 APK 三处一致；`GET /api/v1/app/version` 回读 `versionCode 55` |
| 插件 | 未改动（仍 0.2.29，待用户完整重开 DSH 生效） |

## 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
$env:JAVA_HOME  = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app; flutter build apk --release
```

（`robocopy` 返回 1~3 都是正常的「有拷贝」；中文路径下 AOT 快照会炸，所以必须先拷到 ASCII 目录再编。）

## 限制与下一步

- 「后台下载」是**进程内后台**：App 被系统杀掉或用户手动划掉，下载就没了；真要跨进程存活得走原生下载服务（WorkManager / DownloadManager），这一轮没做。
- **没有断点续传**：取消后再点一次是从 0 开始，`.part` 已被删掉。
- 进度弹窗关掉之后没有常驻通知，只能回「我的 → 检查更新」那行看「下载中 N%」。
- 下载速度仍受 `pace()` 限制（每 256 KB 一帧、帧间 ≥30 ms）与隧道带宽影响。
- `UpdateDownloadCenter.instance` 这个静态单例目前没被用到（tile 自己 new 一个），下轮要么用起来（跨页面共享进度）要么删掉。
