# M4.25 账户余额放到「我的」里面

## 一句话结论

手机「我的」页新增「账户余额」一栏：显示电脑端 DeepSeek 账号的充值余额与赠送余额，右侧可以重新读取；没连接、没登录、查询失败、插件太旧各有各的说明。插件 **0.2.29** 新增只给手机用的 `GET /api/v1/desktop/account/balance`，手机端 **0.4.25+51**。

## 起因

用户原话：「账户余额放到我的里面」。

「我的」页（`app/lib/screens/profile_screen.dart`）此前只有：品牌卡、连接与设备（连接状态 / 后台保活）、模型与 API Key、通知两个开关、外观、关于与更新。**没有任何和「花了多少钱」有关的东西**，而电脑端本身是知道的——Host 的 `deepseekAccount` 服务能查 Platform 钱包。

## 为什么必须由插件代理

Host 服务 `deepseekAccount`（`cordis_inspect_query` 取证）里写得很明确：

```ts
abstract getBalance(client: AccountClientMetadata): Promise<AccountDetails['balance'] | null>;
// "Query Platform recharge and bonus wallet balances independently of profile data."
// service description: "Account operations; only Host consumers can obtain a request credential."
```

也就是说：凭据只在 Host 进程里，手机（App）拿不到，也不该拿到。所以链路是

```
手机「我的」→ 插件 GET /api/v1/desktop/account/balance（App token 校验）
            → ctx.get('deepseekAccount').getBalance({ version, locale, timezoneOffsetSeconds })
            → 只把 Money 数字回给手机（不含任何 token / 凭据）
```

钱包类型（Host 的 zod schema）：

```ts
export interface AccountWallet { readonly currency: 'CNY' | 'USD'; readonly balance: string; }
export interface AccountDetails {
  readonly balance: { readonly status: 'ready'; readonly value: readonly AccountWallet[];
                      readonly bonusWallets: readonly AccountWallet[] }
                 | { readonly status: 'failed' };
}
```

`balance` 是**字符串**（`"12.34"`），手机端原样保留、不做浮点换算，避免 `12.34 → 12.339999` 这种显示事故。

## 改动

### 插件（`dsh-plugin-m1/`，0.2.28 → 0.2.29）

| 位置 | 改动 |
|---|---|
| `lib/index.js` | 新增 `readAccountBalance()`：无 `deepseekAccount.getBalance` → `supported:false`；返回 `null`（未登录）→ `supported:true, signedIn:false`；`status:'failed'` → `failed:true`；`ready` → `wallets` / `bonusWallets` 各压成 `{ currency, balance }`，空条目丢掉；抛异常 → `error` 带 Host 的错误码 |
| `lib/index.js` | `pageContext` 新增 `accountBalance: () => readAccountBalance()` |
| `lib/server.js` | 新增 `GET /api/v1/desktop/account/balance`：只认 app token（401），插件不支持时 501 `ACCOUNT_BALANCE_UNAVAILABLE`，否则 200 透传 |

### 手机端（`app/`，0.4.24+50 → 0.4.25+51 / `0.4.25-m4.25`）

| 位置 | 改动 |
|---|---|
| `lib/services/history_api.dart` | 新增 `AccountWallet`（含 `symbol`）、`AccountBalance`（`supported/signedIn/failed/wallets/bonusWallets/error`，`primary` / `primaryBonus` 优先 CNY）；`fetchAccountBalance()` 打新路由 |
| `lib/data/live_store.dart` | 新增 `fetchAccountBalance()`（未连接抛「还未连接电脑，读不到账户余额」，走 `_withAuthRetry`） |
| `lib/screens/profile_screen.dart` | 新增「账户余额」分区 + `_BalanceCard`（StatefulWidget）：连接后自动读取、监听连接状态变化、右上是金额与「重新读取」按钮；`赠送余额` 有值时在下面单独一行；副标题按四种状态给文案（未连接 / 未登录 / 查询失败 / 插件太旧） |

## 验收证据

| 项目 | 结果 |
|---|---|
| 插件单测（`node --test "test/*.test.js"`） | **95/95 PASS**（含新增 `account-balance.test.js` 6 例、`account-balance-route.test.js` 4 例） |
| 手机端测试（`flutter test test/`） | **386/386 PASS**（新增 `profile_balance_m4_25_test.dart` 4 例） |
| 路由边界 | 无 token → 401；agent token → 401；插件不支持 → 501 `ACCOUNT_BALANCE_UNAVAILABLE` |
| 钱包映射 | `ready` → `[{CNY,12.34},{USD,0.00}]` 原样；空条目丢弃；`null` → 未登录；`failed` → 失败文案 |
| 界面四种版面 | 有余额（¥12.34 + 赠送 ¥3.00）、未登录、查询失败（可重试）、未连接（不请求） |

## 构建命令

```powershell
robocopy "<项目根>\app" C:\Users\user\dsh-tools\build\dsh-app /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
cd C:\Users\user\dsh-tools\build\dsh-app; flutter build apk --release
```

（必须 robocopy 到 ASCII 路径再构建：项目路径含中文会让 AOT 快照器读不出 `app.dill`。）

## 限制与下一步

1. **插件 0.2.29 需要一次 DSH 重启才生效**：这次热加载被 `HMR transactions cannot be nested` 挡住了（`plugin_manager set_bundle` 连试三次都是这个诊断），运行中的插件仍是 0.2.28，所以线上 `GET /api/v1/desktop/account/balance` 现在还回 404。重开 DSH 后该路由才会出现；手机端会先显示「这台电脑的插件版本太旧，读不到余额」。
2. 余额只是快照，没有自动刷新（进页面读一次、点右上角再读一次）。要「每分钟自动刷」得再加重试与节流。
3. 只有 CNY/USD 两种符号；没做千分位与两位小数补齐（Host 返回什么就显示什么）。
4. 真机没复测：手机装上 0.4.25 后需要在有登录态的电脑上看一眼金额是否与电脑端一致。
