# M2.5 交付报告：应用内在线更新

> 日期：2026-11-03 · 阶段：M2.5（M1 / M1.1 / M2 / M2.1 / M2.2 / M2.3 / M2.4 已交付）· 契约：[`docs/design/M2_5_UPDATE_DELTA.md`](../design/M2_5_UPDATE_DELTA.md) v1.0
> 结论：**手机端已能在应用内「检查更新 → 下载 APK → 交给系统安装器」，不需要再去浏览器找链接。** 后端 `GET /api/v1/app/version`、`GET|HEAD /api/v1/app/apk` 已上线（本地 + 公网隧道双向验证）；手机端 `flutter test` **178/178** 全绿，APK `versionName=0.1.6-m2.5`、`versionCode=7`；真实链路回归 **6/6 PASS**。

## 1. 用户需求与方案

用户原话：

> 「能不能在线更新」

**实现形态**：应用内更新（in-app update），不做静默安装。

- Android 上非系统应用**无法**在用户无感知的情况下安装 APK：可以自动下载，但最后一步必须由系统安装器弹出确认框、用户点「安装」。
- 因此流程是：**检查更新（不弹窗打扰）→ 有新版本告知大小与说明 → 用户点「立即更新」→ 后台下载带进度 → 调起系统安装器 → 用户确认安装**。
- 首次例外：当前手机里装的是 `0.1.5-m2.4`（没有更新模块），**需要手动装一次 0.1.6**，从那以后就能在「我的 → 关于」里直接检查更新。
- 若系统禁止「安装未知来源应用」，流程会先引导去开启（`ACTION_MANAGE_UNKNOWN_APP_SOURCES`），回来再装。

## 2. 后端：更新接口（`api/AppUpdateController.java`，216 行）

配置在 `backend/src/main/resources/application.properties`（均可用环境变量覆盖）：

| 键 | 默认值 | 说明 |
|---|---|---|
| `app.update.enabled` | `true` | 关闭后两接口都返回 404 |
| `app.update.apk-path` | `../dist/DeepSeek-Remote-latest.apk` | 相对 backend 工作目录 |
| `app.update.version-code` | `7` | 与手机端 `versionCode` 比较 |
| `app.update.version-name` | `0.1.6-m2.5` | 展示用 |
| `app.update.notes` | 「修复演示数据、界面减法后的在线更新版本」 | 中文用 `\uXXXX` 转义（Spring properties 按 ISO-8859-1 解析） |

接口（**无需 Bearer**，与健康检查同级）：

| 接口 | 行为 |
|---|---|
| `GET /api/v1/app/version` | 200：`{versionCode, versionName, size, sha256, notes, url:"/api/v1/app/apk", publishedAt}`；APK 缺失或未启用 → 404 `{"code":"APP_UPDATE_UNAVAILABLE","message":...}` |
| `GET /api/v1/app/apk` | 200：`FileSystemResource` 流式下载，`Content-Type: application/vnd.android.package-archive`、`Content-Length`、`Content-Disposition: attachment; filename="DeepSeek-Remote-latest.apk"` |
| `HEAD /api/v1/app/apk` | 200：只回响应头（手机端可先探测大小） |

细节：sha256 按「文件 mtime + size」进程内缓存（换包自动重算）；下载不读进内存；Range 请求天然返回 206（契约未强制）。

## 3. 手机端实现

| 层 | 文件 | 内容 |
|---|---|---|
| 检查/下载 | `app/lib/services/update_service.dart`（248 行） | `AppUpdateInfo`、`UpdateException`、可注入的 `UpdateHttpClient`；`check()` 只在 `versionCode >` 当前时返回信息（404/网络/JSON 异常一律返回 null 不抛错）；`download()` 流式写 `{cacheDir}/updates/app-update.apk.part`、按 size 校验后 rename，进度回调 |
| 平台桥 | `app/lib/services/update_gateway.dart`（137 行） | `MethodChannel("deepseek_remote/update")`：缓存目录、能否安装、去设置、调安装器；测试用 `FakeUpdateGateway` |
| Kotlin | `.../UpdateBridge.kt`（新增） | `getCacheDirectory`、`canInstallPackages`（Android 8+ `canRequestPackageInstalls()`）、`openInstallSettings`（`ACTION_MANAGE_UNKNOWN_APP_SOURCES`）、`installApk`（校验文件 → `ShareFileProvider.uriForUpdate` 生成 content:// → `ACTION_VIEW` + `FLAG_GRANT_READ_URI_PERMISSION`） |
| 共享 | `ShareFileProvider.kt`（扩展） | 允许 `cacheDir/share/` 与 `cacheDir/updates/` 两个目录；`.apk` 返回 `application/vnd.android.package-archive` |
| 清单 | `AndroidManifest.xml` + `res/xml/file_paths.xml` | 新增 `REQUEST_INSTALL_PACKAGES` 权限、`<cache-path name="updates" path="updates/" />` |
| UI | `app/lib/widgets/update_check_tile.dart`（330 行） | 「我的 → 关于」里的「检查更新」行：未连接提示先去连接；已最新 → SnackBar；有更新 → 弹窗（当前/新版本、大小 MB、更新说明、稍后/立即更新）；下载中不可关闭的进度框（百分比 + MB）；无安装权限 → 引导去设置；成功后调起安装器 |
| 版本 | `app/lib/app_version.dart` | `kAppVersionCode=7`、`kAppVersionName='0.1.6-m2.5'`、`kAppVersionLabel='手机端 v0.1.6-m2.5'`；`pubspec 0.1.6+7`、`local.properties 0.1.6/7`、`build.gradle.kts versionName="0.1.6-m2.5"` |

## 4. 验收证据（M2.5-A1..A6）

| 编号 | 要求 | 结果 |
|---|---|---|
| A1 | 手机端能检查更新 | ✅ `update_service_test.dart` 12 项：有新版本返回、相同/更旧返回 null、404、非法 JSON、网络异常、缺省字段、下载写盘 + 进度、size 不一致清理、HTTP 500、中断、覆盖旧包 |
| A2 | 下载 APK | ✅ 流式写入 `{cacheDir}/updates/app-update.apk`，`.part` 失败自动清理，按服务端 size 校验 |
| A3 | 调起系统安装器 | ✅ `UpdateBridge.installApk` 生成 content:// 并 `ACTION_VIEW`；无权限时先 `openInstallSettings` 引导 |
| A4 | UI 入口 | ✅ `update_check_tile_test.dart` 3 项 widget：未连接不检查、有新版本弹窗、已最新提示 |
| A5 | 后端接口 | ✅ 本地与公网 `GET /version` 200 同 JSON；`HEAD /apk` 200、`150,782,707` 字节、`application/vnd.android.package-archive` |
| A6 | 测试与构建 | ✅ `flutter test` **178/178**（164 + 12 + 3 新增，旧用例零回归）；`flutter build apk --debug` 成功，`aapt` → `versionName='0.1.6-m2.5' versionCode='7'`，APK **150,782,707 字节** |

## 5. 端点实测（可复核）

```
GET https://<公网隧道>.trycloudflare.com/api/v1/app/version
→ 200 {"versionCode":7,"versionName":"0.1.6-m2.5","size":150782707,
        "sha256":"349d7c8b…c4781b1","notes":"修复演示数据、界面减法后的在线更新版本",
        "url":"/api/v1/app/apk","publishedAt":"2026-11-03T18:08:06+08:00"}

HEAD https://<公网隧道>.trycloudflare.com/api/v1/app/apk
→ 200  content-type: application/vnd.android.package-archive
        content-length: 150782707
```

- 8080 主服务已重启（旧 pid 20296 → 新 pid **28512**，`gradle bootRun`，日志 `.m1-state/logs/backend.*.log`），Agent pid 4000 自动重连，health `agentOnline=true`。
- `dist/DeepSeek-Remote-latest.apk` 已替换为 0.1.6 构建；`sha256` 接口值与本地文件一致。
- 真实链路回归：`node tools/m1-client.ts --base http://127.0.0.1:8080` → **6/6 PASS**，证据 `docs/research/evidence/m1/e2e-2026-11-03T10-33-10-527Z.json`。

## 6. 交付物与下载

| 形态 | 位置 |
|---|---|
| 根目录 APK | `DeepSeek Remote AI 手机端 v0.1.6-m2.5.apk`（150,782,707 字节，SHA256 `349D7C8B00D531051CF9ACA5CDB8C406BF539AFABB9DCB1C5C812EE25C4781B1`） |
| 更新用固定文件名 | `dist/DeepSeek-Remote-latest.apk`（后端 `/api/v1/app/apk` 直接读它，换包即生效） |
| 公网下载 | `https://<公网隧道>.trycloudflare.com/DeepSeek-Remote-v0.1.6-m2.5.apk` |
| 局域网下载 | `http://192.168.1.x:8099/DeepSeek-Remote-v0.1.6-m2.5.apk` |
| 连接隧道（App 内填） | `https://<公网隧道>.trycloudflare.com`，配对码 `824613` |

> 隧道地址是临时的：cloudflared 重启后会变。变地址时手机端在「真实连接」页改服务器地址即可，已配对设备通常仍需重新配对一次（token 绑定服务实例）。

## 7. 已知限制

1. **不能静默安装**：最后一步必须用户点系统安装器的「安装」，这是 Android 平台限制，不是实现取舍。
2. **首次需手动装 0.1.6**：0.1.5 没有更新模块；装完这次之后才能在应用内更新。以后每次发版只需替换 `dist/DeepSeek-Remote-latest.apk` 并改 `app.update.version-code/version-name`。
3. **仅校验文件大小**：`AppUpdateInfo.sha256` 已从服务端带下来，但当前下载后只按 `size` 校验；sha256 逐块校验留待后续（需引 crypto 或在 Kotlin 侧算）。
4. **debug 签名**：APK 是 debug 构建，与后续版本签名一致才能覆盖安装；正式发布要上固定 keystore。
5. **未真机点过安装器**：本机无 Android 设备/稳定模拟器，`UpdateBridge` 的安装器跳转只做了编译与单测级验证，需真机点一次确认。
6. **需要「安装未知应用」权限**：第一次安装时系统会要求允许；忘记开时流程会引导去设置。
7. **更新检查依赖已连接的服务器地址**：未连接时不可检查（这也是契约 A4 的行为）。

## 8. 下一步

- **M3**：审批等待与执行槽解耦、多设备/账号、远程桌面 L1、正式签名与发布流水线（把「替换 dist + 改版本号」做成发布脚本）。
- 真机验收 M2.5：装 0.1.6 → 我的 → 关于 → 检查更新 → 下载 → 允许安装 → 完成；再点一次确认「已是最新版本」。

## 9. 证据索引

| 内容 | 位置 |
|---|---|
| 契约 | `docs/design/M2_5_UPDATE_DELTA.md` |
| 后端实现 | `backend/src/main/java/com/deepseek/remote/api/AppUpdateController.java`、`backend/src/main/resources/application.properties` |
| 手机端实现 | `app/lib/services/update_service.dart`、`update_gateway.dart`、`app/lib/widgets/update_check_tile.dart`、`app/android/.../UpdateBridge.kt`、`ShareFileProvider.kt` |
| 测试 | `app/test/update_service_test.dart`、`app/test/update_check_tile_test.dart` |
| 真实链路回归 | `docs/research/evidence/m1/e2e-2026-11-03T10-33-10-527Z.json` |
| 版本与构建 | `aapt dump badging` 输出（versionCode 7 / versionName 0.1.6-m2.5）；APK SHA256 见 §6 |
