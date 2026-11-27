# M4.26 · 「这个进度条都不动」——下载进度弹窗不重画

更新：2026-11-17（Asia/Shanghai）
交付：手机端 **0.4.26+52**（`0.4.26-m4.26`）；电脑端插件不变（0.2.29）

## 1. 一句话结论

「正在下载 v0.4.25-m4.25」那个弹窗用 `StatefulBuilder` 撑起来，可 `onProgress` 里只叫了**外层** `setState`，弹窗自己的 `setDialogState` 一次都没被调用——字节一直在进来（下面「检查更新」那行确实写着「下载中 1%」），弹窗却始终停在 `0% · 0.0 / 69.5 MB`。现在把弹窗的 setState 存进 `_dialogSetState`，每个进度帧两边一起刷。

## 2. 起因

用户发来截图说「这个进度条都不动」：

- 弹窗「正在下载 v0.4.25-m4.25」，进度条空、文字 `0% · 0.0 / 69.5 MB`；
- 同一屏的「检查更新」行却写着「下载中 **1%** · 完成后会调起系统安装器」。

这两处数字互相矛盾，正好指明了病灶：**外层状态在变，弹窗没重画**。

## 3. 根因

`app/lib/widgets/update_check_tile.dart` 里：

- `_downloadAndInstall()` 的 `onProgress` 只做了 `setState(() { _received = ...; _total = ...; })`；
- 进度弹窗由 `_showProgressDialog()` 用 `showDialog` + `StatefulBuilder` 创建，builder 里本来有一个 `setDialogState`，但**没有任何地方调用它**。

`showDialog` 的 builder 挂在根 Navigator 上，不是 `UpdateCheckTile` 的子树，所以外层的 `setState` 不会让它重建。结果就是：下载在走、文件在写、外层百分比在涨，弹窗里那根条和那行字是「一次性快照」。

## 4. 改动

`app/lib/widgets/update_check_tile.dart`：

| 位置 | 改动 |
|---|---|
| State 字段 | 新增 `StateSetter? _dialogSetState;`（附 M4.26 注释说明为什么） |
| `_showProgressDialog()` 的 builder | 首行 `_dialogSetState = setDialogState;` 把弹窗的 setState 存下来 |
| `onProgress` | 外层 `setState` 之后调用 `_refreshProgressDialog()` |
| 新增 `_refreshProgressDialog()` | `if (!_progressOpen) return; final refresh = _dialogSetState; if (refresh == null) return; refresh(() {});` |
| `_closeProgressDialog()` / `finally` | 关窗时 `_dialogSetState = null;`，迟到的进度回调不会打到已销毁的 State |

## 5. 验收证据

| 项 | 结果 |
|---|---|
| 反证（先证明用例能抓住 bug） | 临时删掉 `onProgress` 里的 `_refreshProgressDialog();` → 新用例失败：`Actual: _TextContainingWidgetFinder:<Found 0 widgets with text containing 50% · 0.5 /: []>`；恢复后通过 |
| 新回归用例 | `app/test/update_check_tile_test.dart` 新增「下载进度回调要同时刷新弹窗里的百分比与已下载字节」：假服务先报 `0/1MB`、弹窗建起来断言 `0% · 0.0 /`，放行后报 `512KB/1MB` → 断言 `50% · 0.5 /` 出现、`0% · 0.0 /` 消失，最后抛错收尾并断言弹窗关掉、提示出现 |
| 全量测试 | `flutter test test/` → **387/387 PASS**（386 + 1） |
| 构建 | `robocopy app → C:\Users\user\dsh-tools\build\dsh-app`（exit 3 = 有增改，正常）→ `flutter build apk --release` → `√ Built … (69.5MB)` |
| 产物 | `dist\DeepSeek-Remote-AI-v0.4.26-m4.26.apk` / `dist\DeepSeek-Remote-latest.apk` / 根目录同名 APK，**72,836,290 字节**，SHA256 `DC42BF0C…47056AFC`，aapt2 `versionCode='52' versionName='0.4.26-m4.26'`，minSdk 24 / targetSdk 36 |
| 通道回读 | `GET /api/v1/app/version` → `{"versionCode":52,"versionName":"0.4.26-m4.26","size":72836290,"sha256":"dc42bf0c…47056afc","publishedAt":"2026-11-17T07:34:24.216Z"}` |

## 6. 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd "C:\Users\user\dsh-tools\build\dsh-app"; flutter build apk --release
```

（项目路径含中文，AOT snapshotter 会报 `Unable to read file … app.dill`，所以必须走 ASCII 目录。）

## 7. 限制与下一步

- 本次只修「弹窗不重画」；**下载速度**仍受隧道与 `pace()` 节流影响（每 256 KB 一帧、帧间至少 30 ms，理论上限约 8.5 MB/s），69.5 MB 至少要几秒到几十秒，取决于隧道。
- 没有做「取消下载」与断点续传；中途失败只提示重试（`.part` 会被删掉重下）。
- 真机未复测：装 0.4.26 后点「检查更新 → 立即更新」，弹窗里的百分比与 MB 应连续增长，到 100% 后调起系统安装器。
- 编辑 `pubspec.yaml` / `build.gradle.kts` 时踩到一个 PowerShell 坑：单元素 `pairs = @(@('a','b'))` 会被展平成字符串，`$pair[0]` 变成首字符 `v`、`$pair[1]` 变成 `e`，于是全文 `v→e`，把 `version` 写成 `eersion`、`environment` 写成 `eneironment`。修法是从 ASCII 构建副本还原这两个文件，再用 edit 改版本；单元素必须写成 `pairs = ,@('a','b')`。
