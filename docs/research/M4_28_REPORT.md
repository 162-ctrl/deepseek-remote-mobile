# M4.28 「读取账户余额失败：请求格式不正确（not found）」是怎么回事

## 一句话结论

不是地址错了，也不是手机端的 bug：**电脑上跑的还是插件 0.2.28**，`/api/v1/desktop/account/balance` 这条路由 0.2.29 才有，所以手机拿到的是 404。而通用 404 文案（`PairingApi.messageForHttpError` 对 404 的默认说法）是「请求格式不正确：请确认地址指向 M1 后端」，会把人往"改地址"的方向带。这次顺手把这个特定场景翻译清楚。

## 现场证据

| 检查 | 结果 |
|---|---|
| 手机截图 | 「我的」页：`读取账户余额失败：请求格式不正确：请确认地址指向 M1 后端（not found）`，同时「已连接 · DeepSeek Harness（插件直连）」是绿的 |
| `GET /api/v1/health` | `{"status":"ok","version":"0.2.28",...}` —— 运行中的插件是 0.2.28 |
| `node -e "require('./dsh-plugin-m1/package.json').version"` | `0.2.29` —— 源码已经升到 0.2.29 |
| `GET /api/v1/desktop/account/balance`（不带 token） | `404`，body 为空 —— 路由根本不存在 |
| `plugin_manager set_bundle(enabled=false)` | `{"stage":"enable","changed":false,"application":"failed","error":{"code":"operation-error","diagnostic":"HMR transactions cannot be nested"}}` —— 热加载又被卡住 |

## 根因链

1. M4.25 把余额接口做在插件 `0.2.29` 里（`GET /api/v1/desktop/account/balance`，只认手机 app token）。
2. 0.2.29 想靠热加载生效，`plugin_manager` 一直报 `HMR transactions cannot be nested`（M4.18 也遇到过一次）。
3. 于是运行中的 Host 仍是 0.2.28 → 路由不存在 → 404。
4. 手机端 `_requireJson` 的 404 兜底文案是通用的「请确认地址指向 M1 后端」，读起来像配置错误，实际是版本不匹配。

## 改动（0.4.27+53 → 0.4.28+54）

`app/lib/services/history_api.dart` 的 `fetchAccountBalance()` 单独 catch 404，翻译成：

> 这台电脑上的插件还没有账户余额接口（需要 0.2.29 以上）：请升级插件后完整退出并重开一次 DSH，再回来刷新

其它状态码与其它接口的文案都不动（401/403 仍是「token 无效或已过期」）。

## 验收证据

| 项目 | 结果 |
|---|---|
| 新用例 `app/test/account_balance_message_m4_28_test.dart` | 2 例：404 → 文案含「插件还没有账户余额接口」「0.2.29」且**不含**「请确认地址指向」；200 → 钱包照旧解析 |
| `flutter test test/` | **399/399 PASS**（397 + 2） |
| APK | `dist\DeepSeek-Remote-latest.apk`，**72,950,978 字节**，versionCode **54**，SHA256 `97551C01…782F43A` |
| 回读 | `GET /api/v1/app/version` → `{"versionCode":54,"versionName":"0.4.28-m4.28","size":72950978,"sha256":"97551c01…782f43a"}` |

## 真正要让余额出现，得多做一步

插件 0.2.29 必须由用户**完整退出 DSH 再重开**（关窗口不等于退出；托盘/后台进程也要退掉）。重开后：

- `GET /api/v1/health` 的 `version` 应变成 `0.2.29`；
- `GET /api/v1/desktop/account/balance` 带 token 应返回 `{supported:true, signedIn:…, wallets:[…]}`；
- 手机上「我的 → 账户余额」右侧应出现金额，点刷新可重读。

注意：隧道是 cloudflared 快速隧道，DSH 重开后公网域名会变，手机需要重新扫码配对。

## 限制

- 这次只改文案，没有让「旧插件」自动消失：只要插件版本落后于手机端期望，仍会看到这条提示，只是现在它说的是人话。
- HMR 卡住的原因（`HMR transactions cannot be nested`）仍未查清，每次插件改动都要完整重开一次 DSH。
