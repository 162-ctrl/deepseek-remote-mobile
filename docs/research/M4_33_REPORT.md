# M4.33 余额卡片上的「去充值」（2026-11-17）

## 一句话结论

手机端**没法直接充值**——Host 的账户服务只读不写，只能跳官方充值页；卡片上加了一个「去充值」，点它打开 `platform.deepseek.com/top_up`。

## 起因

用户问「手机上能做到直接充值吗」。

## 取证

`cordis_inspect_query(platform='host', provider='Service', method='listService', input={service:'deepseekAccount'})` 列出全部 13 个方法：

```
getState / getProfile / getBalance / getUnnotifiedBonuses / ackBonusNotified
startSignIn / cancelSignIn / signOut / watch
getPlatformSession / getDeviceIdentity / resolveToken / rejectToken
```

没有任何下单、创建订单、支付相关的接口；`getPlatformSession()` 的注释还写着「only Host consumers can obtain a request credential」，也就是说**连会话凭证都拿不到手机侧**。结论：支付只能走官方网页。

## 改动

| 位置 | 改动 |
|---|---|
| `app/lib/services/url_opener.dart`（新增） | `abstract class UrlOpener { Future<bool> open(String url); }`、`MethodChannelUrlOpener`（channel `deepseek_remote/update`，方法 `openUrl`）、`FakeUrlOpener`（记录 `opened`，供测试） |
| `app/android/app/src/main/kotlin/com/deepseek/remote/deepseek_remote_app/UpdateBridge.kt` | 新增 `"openUrl" -> result.success(openUrl(call))` 与 `private fun openUrl(call: MethodCall): Boolean`：只放行 `http` / `https`，用 `FLAG_ACTIVITY_NEW_TASK` 起 `ACTION_VIEW`，异常返回 false |
| `app/lib/screens/profile_screen.dart` | 新增 `const String kBalanceRechargeUrl = 'https://platform.deepseek.com/top_up';`、`ProfileScreen({… this.urlOpener})`、`_BalanceCard({required liveStore, this.urlOpener})`、`late final UrlOpener _urlOpener = widget.urlOpener ?? MethodChannelUrlOpener();`、`Future<void> _openRecharge()`（失败 SnackBar：「打不开浏览器，可以在电脑上充值后再点右侧刷新」）；已连接时卡片右上角右对齐一个 `TextButton.icon(Icons.open_in_new_rounded, '去充值')` |

## 验收

- 新增 2 例：点「去充值」把 `kBalanceRechargeUrl` 交给 `FakeUrlOpener`；没连接时不显示这个按钮。
- 版本 `0.4.32+58` → `0.4.33+59`；`flutter test` **425/425**；APK **73,049,346 字节**，SHA256 `1EE489C3A8B4ABB205AB0DD556A535C024E649DA11B4DAFA1AF1057497B5FACC`，`versionCode=59`，三处发布并回读 `/api/v1/app/version` 一致。

## 限制与下一步

- 跳过去是网页登录态，手机浏览器里可能还要登录一次；登录后的充值页与电脑端一致。
- 没有做「充值完自动刷新」——用户回到 App 后点卡片右侧的刷新即可（余额接口是实时读的）。
- 若以后 Host 开放下单能力，可以把这条链路改成应用内支付。
