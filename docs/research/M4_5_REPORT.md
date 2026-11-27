# M4.5 报告：更新下载进度条「不动」（手机端）

> 更新：2026-11-13 · 手机端 0.4.5-m4.5（versionCode 32）· 插件 0.2.12（本轮无插件改动）

## 1. 一句话结论

更新弹窗里的进度条从「只刷新一帧就直接跳去装包」改成按 256 KiB / 30 ms 分帧上报，本地中继十几秒才能把 70 MB 的包下完，进度条会一路走到 100% 再调起安装器。

## 2. 起因与根因

| # | 现象（用户反馈） | 根因 | 修复 |
| --- | --- | --- | --- |
| 1 | 「更新时出来的进度条都不动」 | 插件中继跑在 `127.0.0.1:8787` 回环网络上，实测 71.9 MB 的 APK **0.1 秒**推完；`onProgress` 只在每个网络 chunk 到达时回调，等于几十毫秒内闪一帧 | `UpdateService.download()` 用 `pace()` 包住响应流：攒满 256 KiB 发一帧，两帧至少隔 30 ms |
| 2 | 整块大 chunk 会让分帧失效 | 第一版按「网络 chunk」计数，测试里 512 KiB 的 chunk 一次就 ≥ 阈值，仍只出 2 帧 | 改成**按字节切片**：`BytesBuilder` + `sublist` 把超长 chunk 切成多帧 |
| 3 | 进度比例可能有误 | `total` 取 `info.size > 0 ? info.size : contentLength`，两个都没给时是 0 | 不变（`ratio == null` 时显示「下载中…」的不确定进度条），本轮不涉及 |

## 3. 插件端

本轮无改动（保持 0.2.12）。`GET /api/v1/app/version` 继续从 `dist/DeepSeek-Remote-latest.apk` 读取版本，替换 latest 之后手机端「检查更新」就能看到 32。

## 4. 手机端

- `lib/services/update_service.dart`
  - 新增 `progressInterval = 30ms` / `progressChunkSize = 256 KiB` / `Stream<List<int>> pace(...)` 与私有 `_paced(...)`（字节切片分帧 + `Stopwatch` 节流，末尾不足一块的尾巴也节流后发出）。
  - `download()` 的写入循环改为 `await for (final chunk in pace(response.stream))`；下载完整性与 `.part` → `.apk` 的落盘逻辑不变。
  - `import 'dart:typed_data';`（`BytesBuilder`）。
- `test/update_service_test.dart`：新增 2 个用例（1 MiB 至少 4 帧且字节完全一致；小响应原样透传）。
- 版本：`0.4.5+32` / `0.4.5-m4.5`（`pubspec.yaml`、`local.properties`、`build.gradle.kts`、`app_version.dart` 同步）。

## 5. 验收证据

| 项 | 结果 |
| --- | --- |
| `test/update_service_test.dart` | 13/13 通过（原 11 + 新增 2） |
| `flutter test` 全量 | **288/288 通过**（M4.4 286 + 新增 2） |
| `flutter analyze` | 21 issues，无 error（均为历史 warning/info） |
| 复现数据 | 现网 `/api/v1/app/apk` 71,933,294 字节，loopback 实测 0.1 秒下完（SHA256 与版本接口一致） |
| release APK | 71,933,298 bytes，SHA256 `E5A800453346DF22DEB4B2D6F30D1A8F9DA5F4B98FD51C10453B7A02BF444AF1` |
| APK 版本 | `versionCode=32`、`versionName=0.4.5-m4.5`、minSdk 24、targetSdk 36 |
| APK 签名 | `CN=Android Debug`，SHA-256 `341ef83b95f452bb50b5a6821aa2044334826971e27910d428abc5dab33f70d6`（与旧包一致，可覆盖安装） |

## 6. 生效步骤

1. 安装 `dist/DeepSeek-Remote-latest.apk`（versionCode 32，可覆盖旧版）。
2. 打开「我的 → 检查更新」，下载弹窗里的进度条会一步步走完（约十几秒）再调起系统安装器。
3. 若手机上已是 32，再点检查更新只会提示「已是最新版本」。

## 7. 已知限制

1. 分帧只改「上报节奏」，总下载时长仍是本地中继的真实速度（≈ 70 MB / 10–20 秒量级），并不下载得更快。
2. 分帧靠 `Future.delayed` 节流，极端慢速网络下仍然按 chunk 到达节奏走，不会额外变慢。
3. 仍未真机复测进度条观感（`adb devices` 无设备）。

## 8. 下一步

- 真机确认进度条观感与安装器调起时机。
- 若希望「更快」，可考虑插件端直接 `Content-Length` + 压缩传输外的直连下载（当前 loopback 已经是上限）。
- 桌面直播「加载不了之前的对话」仍需用户提供直播页截屏；接口侧已确认 7 个会话的 events 均 200。

## 9. 证据索引

- 代码：`app/lib/services/update_service.dart`（`pace` / `_paced`）、`app/lib/widgets/update_check_tile.dart`（弹窗 UI 未改）
- 单测：`app/test/update_service_test.dart`
- 构建产物：`dist/DeepSeek-Remote-AI-v0.4.5-m4.5.apk`、`dist/DeepSeek-Remote-latest.apk`、`DeepSeek Remote AI 手机端 v0.4.5-m4.5.apk`
