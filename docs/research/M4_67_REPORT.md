# M4.67 充值页能在 App 内付款（0.4.61+82）

**一句话**：手机端「充值」不再只是把官方页丢给系统浏览器——现在用 App 内嵌的 WebView 打开
`platform.deepseek.com` 官方充值页，在手机上登录一次就能付款，付完回到充值页自动刷新余额。

## 之前的问题

| 现象 | 原因 |
| --- | --- |
| 「去充值」跳系统浏览器，回来还得自己找刷新 | 0.4.60 只做了引导页，付款必须离开 App |
| 用户问「dsh 这个充值界面做不到手机上面吗」 | 电脑端 DSH 的充值其实是把官方网页嵌进自己窗口（`@deepseek-ai/dsh-client-ui-settings-account` 里 `showPage(openPlatformPage, 'top-up')`），付款表单从来不在 DSH 里；手机端没有等价的内嵌页 |
| 登录态没法复用到手机 | DSH 的登录会话存在电脑的 Electron 会话里，手机 App 拿不到 |

## 改动

| 位置 | 改动 |
| --- | --- |
| `app/pubspec.yaml` | 新增依赖 `webview_flutter: ^4.14.1`（项目第一次引入原生 WebView） |
| `app/lib/screens/recharge_web_screen.dart`（新） | `RechargeWebScreen`：WebView 打开官方页，顶部进度条、刷新、用系统浏览器打开；底部说明 +「我已完成，回去刷新」；返回键统一 `pop(true)` |
| 同上 | `NavigationDelegate.onNavigationRequest`：`http(s)` 放行；`alipays://`、`weixin://` 等协议交给系统应用，装了客户端就用客户端付 |
| 同上 | `onWebResourceError` 只在主框架失败时报整页错误，避免一条广告脚本把支付页判死 |
| `app/lib/screens/recharge_screen.dart` | 主按钮改「在 App 内打开充值页」→ 推 `RechargeWebScreen`，返回后 `_load()` 刷新；系统浏览器降级为次级文字按钮；步骤说明同步改写 |
| `app/lib/app_version.dart` / `pubspec` / `local.properties` / `build.gradle.kts` | 版本 → `0.4.61+82`（`0.4.61-m4.61`） |
| `docs/UPDATE_NOTES.md` + `app/assets/update_notes.md` | 新增 0.4.61 段；随包资源同步 |

## 验收

- 新增 `app/test/recharge_web_m4_67_test.dart` 3 例：内嵌页接到官方地址、点「我已完成」返回 `true`、返回箭头也返回 `true`、系统浏览器按钮仍把地址交给 `UrlOpener`。
- 改 `app/test/recharge_m4_65_test.dart`：主按钮进内嵌页（注入 `webViewBuilder` 占位，断言 `fake-webview:<url>`）、返回后余额刷新两次、次级入口调 `FakeUrlOpener`。
- 改 `app/test/profile_balance_format_m4_32_test.dart`：「去充值」先到充值页，再点「用系统浏览器打开」才交给浏览器。
- 全量 `flutter test` **545/545**；`flutter analyze --no-pub` **0 error**（新增告警仅 1 条 `prefer_final_fields`，已改掉）。
- 反证：把 `_openRechargeInApp` 的 `Navigator.push` 去掉后，`recharge_m4_65` 那条用例失败；恢复后通过。
- 踩坑：不确定进度条（`value: null`）会让 `pumpAndSettle` 永远等不到稳定，测试整片超时；改成确定值进度条即可。
- 踩坑：`Row` 里直接放 `FilledButton` 在测试环境会拿到无限宽约束（`BoxConstraints forces an infinite width`），底栏改成 `Column`、次级按钮改成 `Wrap`。

## 交付

| 项 | 值 |
| --- | --- |
| APK | `dist/DeepSeek-Remote-latest.apk` = `dist/DeepSeek-Remote-AI-v0.4.61-m4.61.apk` = 根目录 `DeepSeek Remote AI 手机端 v0.4.61-m4.61.apk` |
| 大小 | 74,216,293 字节 |
| SHA256 | `BB8B5544AAF0E485B617ACDBB9A7C1706EAF128124A0006B7CDF935B47CC607E` |
| 版本 | `versionCode 82` / `versionName 0.4.61-m4.61` |
| 校验 | `tools/verify-release.mjs` 四项一致（本地 APK、接口版本、大小、sha256） |
| 插件 | 无需改动（仍 0.2.69） |

## 限制

- 付款仍然发生在 `platform.deepseek.com` 的官方页面里，App 只提供窗口，不接触卡号、验证码和支付凭据——这是官方没有开放下单/付款接口决定的，不是实现取舍。
- 支付宝 / 微信若要「客户端支付」，需要手机上装了对应 App 并且系统把 `alipays://` / `weixin://` 路由过来；没装时会退化成网页支付或直接失败。
- 登录态存在 WebView 的 cookie 里，清除 App 数据或 WebView 数据后需要重新登录。
- 没有订单列表、发票入口和到账通知：这些官方页面上有，App 里不重复做。
- WebView 需要网络；离线时页面会显示「官方页面打不开」，可以点重试或改用系统浏览器。

## 下一步

- 用户装上 0.4.61 后在真机上走一遍：登录 → 充值 → 回充值页看余额是否刷新。
- M4.62 直播推送的 `session` / `question` 帧还没在真机观测到，需要补验证。
- M4.57「功能 → 接收文件」的真机验收仍未走完。
