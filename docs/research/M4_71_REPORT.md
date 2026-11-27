# M4.71 报告：修好「检测不到能打开的应用」（App 0.4.65+86）

## 一句话
不是权限问题，是 Android 11+ 的包可见性：manifest 只声明了 `PROCESS_TEXT` 的 `<queries>`，`resolveActivity` 对任何文件类型都返回 null，于是「有没有应用能打开」永远被判成没有。

## 之前的问题
| 现象 | 原因 |
| --- | --- |
| 用户问「还是不行，是检测不到吗，需要什么权限吗」 | 不是运行时权限；Android 11（API 30）起，App 默认只能看见自己与少数系统应用，查询其它包必须先在 manifest 用 `<queries>` 声明要交互的 intent |
| `FileOpenBridge.handleOpenBytes` 里 `intent.resolveActivity(...)` 判空 | 同样的包可见性问题会让它一直为 null，即使装了 WPS 也报 `NO_APP` |
| 0.4.64 的「没应用就藏按钮」把按钮藏掉的判断也可能失真 | 依赖的正是 `resolveActivity` |

## 改动
| 文件 | 改动 |
| --- | --- |
| `app/android/app/src/main/AndroidManifest.xml` | `<queries>` 增加 `ACTION_VIEW` + `mimeType="*/*"` 与 `ACTION_SEND` + `*/*`，让系统把能处理文件的候选应用暴露给本 App |
| `app/android/.../FileOpenBridge.kt` | `handleCanOpenBytes` 改用 `context.packageManager.queryIntentActivities(intent, 0)`（候选取并集，再兜底 `resolveActivity`）；`handleOpenBytes` 去掉「先判空再启动」，改成 `try { startActivity } catch (ActivityNotFoundException)` 报 `NO_APP`；新增 `import android.content.ActivityNotFoundException` |
| 版本 | App 四处 → `0.4.65+86`；`app_version.dart` 顶部加 M4.71 说明；版本断言测试同步 |

## 验收
- `flutter test test/theme_m2_3_test.dart`、`test/empty_state_test.dart` → 通过（版本断言已同步）。
- `flutter build apk --release` → `√ Built … (70.8MB)`；中途一次 Kotlin 编译失败是 `intent.queryIntentActivities(...)` 写错接收者（应为 `context.packageManager`），已修。
- `aapt2 dump badging` → `versionCode='86' versionName='0.4.65-m4.65'`。
- `tools/verify-release.mjs` → 四项一致（size 74,217,069 / sha256 `571c9140…`）。
- 0.4.64 的 3 例「藏按钮」测试仍全过（Dart 侧行为未变，只改了原生判定来源）。

## 交付
- App `0.4.65+86`，APK **74,217,069 字节**，SHA256 `571C9140D27C33F6C9466FBE056CC4D50D647A293565ABAEFC01F08D5CA881A4`。
- 四处同哈希；`UPDATE_NOTES.md` 与 `app/assets/update_notes.md` 顶部已加 0.4.65 段；`received/` 投递 APK、更新说明、本报告。
- 插件未改（仍 0.2.69）。

## 限制与下一步
- `<queries>` 只能看见「声明了对应 intent 的应用」；如果某个阅读器用私有 intent 接收文件，仍可能查不到——但 `startActivity` 的 try/catch 兜底会保证真的能开就开。
- 建议用户装 0.4.65 后在「关于」确认版本，再打开 `示例作业.docx`：应该看到 4 页扫描图；若仍显示「这个文件只能在电脑上看」，说明这台手机确实没有任何 docx 阅读器，分享到电脑是唯一路径。
- 遗留：M4.62 直播推送帧真机验证；M4.57 接收文件真机验收。
