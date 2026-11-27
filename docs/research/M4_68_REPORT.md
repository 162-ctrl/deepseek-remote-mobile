# M4.68 充值只保留 App 内入口（0.4.62+83）

**一句话**：用户看完 0.4.61 后要求「只保留在应用内打开充值页」，于是把「用系统浏览器打开」
从充值页和内嵌页都撤掉——付款既然能在 App 里完成，就不该再留一个跳走就断联的出口。

## 之前的问题

| 现象 | 原因 |
| --- | --- |
| 充值页除主按钮外还有「用系统浏览器打开」 | 0.4.61 保留了降级路径，用户认为多余 |
| 内嵌页右上角也有浏览器出口 | 同一个降级被复制到了 WebView 页 |

## 改动

| 位置 | 改动 |
| --- | --- |
| `app/lib/screens/recharge_screen.dart` | 删掉「用系统浏览器打开」按钮与 `_openRecharge()`；`_urlOpener` 字段随之移除（只保留 `widget.urlOpener` 传给内嵌页）；底部只剩右对齐的「已充值，刷新余额」 |
| 同上 | 类注释与步骤说明改成「唯一入口」，不再提浏览器 |
| `app/lib/screens/recharge_web_screen.dart` | 删掉 AppBar 的「用系统浏览器打开」与 `_openExternal()`；`_urlOpener` 只保留给 `onNavigationRequest` 拉起 `alipays://` / `weixin://` |
| `app/lib/app_version.dart` / `pubspec` / `local.properties` / `build.gradle.kts` | 版本 → `0.4.62+83`（`0.4.62-m4.62`） |
| `docs/UPDATE_NOTES.md` + `app/assets/update_notes.md` | 新增 0.4.62 段；随包资源同步 |

## 验收

- `app/test/recharge_m4_65_test.dart`：原「次级入口交给浏览器」用例改成「只保留 App 内入口」——断言有「在 App 内打开充值页」、没有「用系统浏览器打开」、`FakeUrlOpener` 没被调用。
- `app/test/recharge_web_m4_67_test.dart`：原「系统浏览器按钮交给 UrlOpener」用例改成「不再提供浏览器出口」——断言 `byTooltip('用系统浏览器打开')` 为空、`byTooltip('刷新')` 存在。
- `app/test/profile_balance_format_m4_32_test.dart`：进充值页后断言只有 App 内入口，浏览器没有被拉起。
- 全量 `flutter test` **545/545**；`flutter analyze --no-pub` **33 issues、0 error**。
- 反证沿用 M4.67 的做法已覆盖主按钮跳转；本版只删入口，靠上面三条「不应再有这个出口」的断言守住不回退。

## 交付

| 项 | 值 |
| --- | --- |
| APK | `dist/DeepSeek-Remote-latest.apk` = `dist/DeepSeek-Remote-AI-v0.4.62-m4.62.apk` = 根目录 `DeepSeek Remote AI 手机端 v0.4.62-m4.62.apk` |
| 大小 | 74,200,081 字节 |
| SHA256 | `D51BD880818857AD4652B978A96437696DDC7078EFB71073B4415BD567A828D5` |
| 版本 | `versionCode 83` / `versionName 0.4.62-m4.62` |
| 校验 | `tools/verify-release.mjs` 四项一致（本地 APK、接口版本、大小、sha256） |
| 插件 | 无需改动（仍 0.2.69） |

## 限制

- 官方页面若在 WebView 里被判定为「不允许嵌入」，只剩错误页 + 重试，没有浏览器降级了——这是「只保留 App 内」的代价，需要真机确认官方页能正常加载。
- 支付宝 / 微信客户端协议仍然交给系统，行为不变。

## 下一步

- 手机装 0.4.62 走一遍「我的 → 去充值 → 在 App 内登录 → 付款 → 回来刷新」。
- 若官方页在 WebView 里加载失败（例如被 `X-Frame-Options` 拦住只在 iframe 生效、WebView 一般不受影响），再考虑是否恢复浏览器出口。
