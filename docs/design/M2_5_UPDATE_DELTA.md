# M2.5 DELTA 契约：应用内在线更新（检查 → 下载 → 安装）

> 版本：v1.0（2026-11-03）· 阶段：M2.5 · 前序：M2.4（无演示数据 + 界面减法）已交付
> 一句话：**手机 App 连上电脑后，可在「我的 → 关于」检查新版本，直接下载并调起系统安装器完成升级；不做静默安装（Android 非系统应用无法绕过用户确认）。**

## 1 背景与边界

- 现状：每次更新都要把 APK 重新用微信/下载链接传到手机再点安装，用户问「能不能在线更新」。
- 能做到：**应用内检查版本 + 应用内下载 APK + 调起系统安装器（用户确认一次「更新/安装」）**。新版 APK 由电脑端后端提供，走同一条隧道，不需要额外下载服务器。
- 做不到（明确不做，写进限制）：静默安装/免确认升级；Google Play 式增量更新（APK 为 debug 签名侧载包）；iOS 侧载更新。
- 首次升级例外：**当前已装的 0.1.5 及更早版本没有更新模块**，需要手动装一次 0.1.6-m2.5；从这一版开始后续都能应用内更新。

## 2 后端（M2.5-B1..B3）

### B1 配置（`backend/src/main/resources/application.properties`）

```properties
# M2.5 app self-update (contract docs/design/M2_5_UPDATE_DELTA.md)
app.update.enabled=${APP_UPDATE_ENABLED:true}
# 相对 backend 工作目录；也可用绝对路径覆盖
app.update.apk-path=${APP_UPDATE_APK_PATH:../dist/DeepSeek-Remote-latest.apk}
app.update.version-code=${APP_UPDATE_VERSION_CODE:7}
app.update.version-name=${APP_UPDATE_VERSION_NAME:0.1.6-m2.5}
app.update.notes=${APP_UPDATE_NOTES:修复演示数据、界面减法后的在线更新版本}
```

### B2 `GET /api/v1/app/version`（无需 Bearer）

200 响应（JSON，字段名固定）：

```json
{
  "versionCode": 7,
  "versionName": "0.1.6-m2.5",
  "size": 150758731,
  "sha256": "<服务端启动或首次请求时计算的十六进制小写>",
  "notes": "…",
  "url": "/api/v1/app/apk",
  "publishedAt": "2026-11-03T17:45:00+08:00"
}
```

- 文件不存在或 `app.update.enabled=false` → **404**，body 沿用现有错误信封 `{"code":"APP_UPDATE_UNAVAILABLE","message":"…"}`。
- `size`/`sha256` 取 APK 文件实际值；`sha256` 允许在进程内缓存（文件大小/修改时间变化时重算）。
- 日志：`app update check versionCode=… size=…`。

### B3 `GET /api/v1/app/apk`（无需 Bearer，支持 HEAD）

- `200` + `Content-Type: application/vnd.android.package-archive` + `Content-Length` + `Content-Disposition: attachment; filename="DeepSeek-Remote-latest.apk"`；用 `FileSystemResource` 直接流式输出（不要整文件读进内存）。
- 文件缺失 → 404 同上错误码。
- 不实现断点续传（Range）也可以，但**必须**返回正确 Content-Length，避免手机端进度条失真。

### 约束

- 只改 `backend/` 内文件；不得破坏既有 REST/WSS 与 M2-A1..A4；`gradle build -x test` 必须成功。
- 验证方式：`SERVER_PORT=8081` 起临时实例 → `curl /api/v1/app/version`、`curl -I /api/v1/app/apk`、`curl -o` 校验大小与 sha256 → 停掉临时实例（**不要动 8080 上正在跑的服务**，Lead 最后统一重启）。
- 测试用 APK 可先用任意 >1MB 的占位文件（Lead 之后会放真实 APK）。

## 3 手机端（M2.5-A1..A6）

### A1 `app/lib/services/update_service.dart`

- `class AppUpdateInfo { final int versionCode; final String versionName; final int size; final String? sha256; final String notes; final String downloadPath; }`
- `class UpdateService { UpdateService({UpdateHttpClient? http}) … }`
  - `Future<AppUpdateInfo?> check({required String baseUrl, required int currentVersionCode, String? token})`：`GET {baseUrl}/api/v1/app/version`；**200 且 versionCode > 当前** 返回信息；`versionCode <= 当前` 返回 null；404/网络错误/JSON 异常返回 null（不抛给 UI）。
  - `Future<File> download(AppUpdateInfo info, {required String baseUrl, required Directory targetDir, void Function(int received, int total)? onProgress, String? token})`：流式写 `{targetDir}/updates/app-update.apk`（先写 `.part` 再 rename）；结束校验 `size`；返回文件。
  - HTTP 走 `dart:io HttpClient`（**零新增 pub 依赖**），并抽 `UpdateHttpClient` 接口便于单测注入 Fake。
- 版本比较只看 `versionCode`。

### A2 Kotlin `UpdateBridge.kt`（MethodChannel `deepseek_remote/update`）

- `installApk(path)`: 校验文件存在 → 生成 `content://` URI → `Intent(ACTION_VIEW)` + `FLAG_GRANT_READ_URI_PERMISSION` + `application/vnd.android.package-archive` → `startActivity`；返回 `{started: true}` 或抛 `PlatformException`（含 message）。
- `canInstallPackages()`: `Build.VERSION.SDK_INT >= 26` 时 `packageManager.canRequestPackageInstalls()`；低于 26 返回 true。
- `openInstallSettings()`: `Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES`（带 `package:` 数据）。
- **复用现有 content provider**：`file_paths.xml` 增加 `<cache-path name="updates" path="updates/" />`；`ShareFileProvider` 的 `resolveFile` 需支持 `updates/` 与 `share/` 两个目录（URI 形态 `content://<authority>/updates/app-update.apk`）。若改动 `ShareFileProvider`，必须保证既有 `share/` 行为与 `share_m2_2_test` 不受影响。
- `MainActivity` 注册 `updateBridge`（参考 notification/settings/share），`onDestroy` 里 dispose；`AndroidManifest.xml` 加 `<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />`。

### A3 UI（`app/lib/screens/profile_screen.dart` + 新组件）

- 「我的」页「关于」区：显示当前版本（保留现有文案）+ 新增一行「检查更新」，右侧显示状态（`当前已是最新` / `发现新版本 0.1.6-m2.5` / `检查中…`）。
- 点击检查：无更新 → SnackBar「已是最新版本」；有更新 → `AlertDialog`：
  - 标题 `发现新版本 <versionName>`，正文：版本号、大小（MB，保留 1 位小数）、更新说明、一行小字「下载后需在系统安装器点一次「更新」确认」；
  - 按钮：`稍后` / `立即更新`。
- 立即更新：对话框换成进度条（`LinearProgressIndicator` + `x.x MB / y.y MB`）；完成后调 `canInstallPackages()`：
  - false → 弹「需要允许安装未知应用」+「去设置」按钮（`openInstallSettings`）；
  - true → `installApk(path)`；失败 SnackBar 提示。
- 连接成功进入 App 后**静默检查一次**（仅当已连接且用户设置未关闭；失败不打扰），发现新版时把「检查更新」行状态置为「发现新版本」并在「我的」Tab 加小红点（可简单用状态文字，不强制红点）。
- 检查/下载使用当前已配置的 `baseUrl`（`LiveStore` 里已有），不要新增服务器地址输入。

### A4 版本

`app/pubspec.yaml` → `version: 0.1.6+7`；`local.properties` → `flutter.versionName=0.1.6` / `flutter.versionCode=7`；`build.gradle.kts` → `versionName = "0.1.6-m2.5"`；关于页文案 `手机端 v0.1.6-m2.5`。

### A5 测试（新增 ≥12 项，总计 ≥176）

- `app/test/update_service_test.dart`：版本比较（更新/相同/更旧）、URL 拼接、404/网络异常返回 null、下载进度回调、size 不匹配报错、`.part` → 最终文件。
- `app/test/update_ui_test.dart`：检查更新行渲染、点「立即更新」出现进度态、bridge 缺失时优雅降级。
- 既有 164 项零回归；`flutter test` 全绿。

### A6 构建

`flutter build apk --debug` 成功；APK 150MB 量级；`aapt dump badging` → `versionName='0.1.6-m2.5' versionCode='7'`。

## 4 验收（M2.5-A/B 汇总）

| 编号 | 要求 |
|---|---|
| A1 | `GET /api/v1/app/version` 返回 versionCode/versionName/size/sha256/url，无 Bearer 也可访问 |
| A2 | `GET /api/v1/app/apk` 流式返回 APK，Content-Length 正确，HEAD 200 |
| A3 | App 我的页可检查更新；有新版本时弹出版本/大小/说明；可下载并显示进度 |
| A4 | 下载完成能调起系统安装器（`canInstallPackages=false` 时引导去设置） |
| A5 | 164 既有测试零回归，新增 ≥12 项通过 |
| A6 | APK 版本 0.1.6-m2.5 / versionCode 7；后端 `gradle build` 成功 |

## 5 约束

- 手机端只改 `app/` 与 `docs/mobile/README.md`；后端只改 `backend/`；都不动 `agent/`、`tools/`。
- 零新增 pub 依赖；不引入 androidx（`ShareFileProvider` 自实现路线保持）。
- 禁止 `flutter analyze`（中文路径崩溃），门禁用 `flutter test` + `flutter build apk --debug` + `aapt`。
- 不打印/回传 token、密码；下载与安装失败只提示，不崩溃。
