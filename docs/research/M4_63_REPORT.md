# M4.63 启动自愈（App 0.4.58+79）

## 一句话

有用户反馈「打开 App 就闪退，清掉应用数据才能开」——应用层没法替用户清数据，于是加了一层保险：**连续几次没走到第一帧，就自动清掉本地连接存档再启动**。

## 之前的问题

| 现象 | 原因推断 |
| --- | --- |
| 旧版 App 某天开始一打开就退出 | 本地存档（`session.json` + 安全存储里的 token）里有东西把启动卡死；具体是哪一条没有崩溃栈，无法确认 |
| 清除应用数据后恢复正常 | 存档被清掉，启动路径重新走通——符合「存档坏了」这一判断 |
| 用户只能自己去系统设置里清数据 | App 启动失败时没有任何自救手段 |

## 改动

| 文件 | 改动 |
| --- | --- |
| `app/lib/services/boot_guard.dart`（新） | `BootGuard`：`boot_attempts`（启动尝试次数）、`boot_last_attempt_at`（上次尝试时间）、`maxAttempts = 3`、`window = 3 分钟`；`attempts()` / `lastAttemptAt()` / `shouldReset()` / `markAttempt()` / `markFirstFrame()` |
| `app/lib/app.dart` | `initState` 改成 `unawaited(_bootstrap(settings))`：先 `shouldReset()`，命中就 `await _liveStore.disconnect()`（清 token 与地址）并弹一条「上次启动没有完成，已清掉本地连接存档，重新扫码即可」；再 `markAttempt()`；`restoreSession()` 之后在第一帧回调里 `markFirstFrame()` 归零。自愈本身出错不影响启动 |
| `app/lib/app.dart` | `MaterialApp` 增加 `scaffoldMessengerKey: _messengerKey`，用于提示 |
| 版本号 | `0.4.58+79`（`pubspec.yaml` / `app_version.dart` / `build.gradle.kts` / `local.properties`），`kAppVersionName = '0.4.58-m4.58'` |

## 为什么不直接在启动处 try/catch

启动路径里每一步本来就有各自的兜底（存档读取失败返回 null、连接失败清 token、通知初始化失败忽略）。用户遇到的是**进程直接退出**，Dart 层的 try/catch 不起作用，只能靠「下次启动时检查上一次有没有走完」这种跨进程的办法。

## 验收

- 新增 `app/test/boot_guard_m4_63_test.dart` 3 例：前两次不触发复位 / 连续三次触发 / 第一帧后归零（含「隔 30 分钟再启动不算连续」）。
- 定向：3/3 通过。
- 全量 `flutter test`：**533/533**（原 530 + 3）。
- `flutter analyze --no-pub`：**32 issues、0 error**（与改前同数）。
- 反证：把 `shouldReset()` 里的 `count < maxAttempts` 临时改成 `count < 1` → 「前两次没走完不会清存档」失败；恢复后 3/3。

## 交付

| 项 | 值 |
| --- | --- |
| 版本 | `0.4.58+79` / `0.4.58-m4.58` |
| APK | 73,295,806 字节 |
| SHA256 | `2D09D8F7A7C31E986B57843257639A1EF7B09DDD9177EF279E91DDFF92F1EDDC` |
| 同哈希四份 | 构建产物、`dist/DeepSeek-Remote-AI-v0.4.58-m4.58.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录同名 APK |
| 校验 | `tools/verify-release.mjs` 四项一致（versionCode 79 / size / sha256 / versionName） |
| 签名 | debug（与之前同密钥，可覆盖安装） |

## 限制与下一步

- 只能兜住「启动阶段崩溃」；如果崩溃发生在第一帧之后，计数已经归零，不会触发自愈。
- 崩溃根因没找到（没有崩溃栈、清数据即恢复），这次是「坏了也能自己爬起来」，不是「修好了为什么坏」。
- 想真正定位，需要拿到 Android 的崩溃日志（`adb logcat` 或系统「应用信息 → 崩溃报告」）；用户目前拿不到。
- M4.62 的直播推送（插件 0.2.64–0.2.67）已能握手并收到 `ready`，但 `session`/`question` 广播帧还没在真机上观测到，需要再验一轮。
