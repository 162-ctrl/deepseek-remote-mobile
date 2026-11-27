# M4.32 余额卡片的排版与数字（2026-11-17）

## 一句话结论

余额卡片的金额不再原样打印 Host 给的浮点串（`12.443675700000000`），统一成两位小数；标题列也不会再被长数字挤成一列单字。

## 起因

用户发来「这对吗」的截图：金额一栏写着 `¥12.443675700000000`，左侧「账户余额 / 电脑端 DeepSeek 账号 · 点右侧刷新」被挤成**每行一个字**，底部「赠送余额」显示 `$0`。

## 根因

`app/lib/screens/profile_screen.dart` 的 `_BalanceCard` 把 `wallet.balance` 原样塞进 `Text`，而 Host 返回的是浮点串（`getBalance()` 直出）：

```json
{"wallets":[{"currency":"USD","balance":"0E-16"},{"currency":"CNY","balance":"12.4137841000000000"}],
 "bonusWallets":[{"currency":"USD","balance":"0"}]}
```

于是三件事同时发生：

1. 金额太长，`Row` 里主标题所在的 `Expanded` 被压到几乎没有宽度 → 每个字单独一行；
2. 第一个钱包是 `USD 0E-16`（金额为 0 的美元），旧逻辑直接取 `wallets.first`，符号就变成了 `$`；
3. `0E-16` 这种科学计数法原样显示。

## 改动

| 位置 | 改动 |
|---|---|
| `app/lib/services/history_api.dart` | 新增顶层 `formatMoneyAmount(String raw)`：空串原样返回；解析不了原样返回；能解析就固定两位小数（`0E-16` → `0.00`，`12.4137841000000000` → `12.41`）。新增 `_parseMoney()`（去逗号兜底）。`AccountWallet` 加 `symbol`（`trim().toUpperCase()`：CNY/RMB → `¥`，USD → `$`）、`display`（`symbol + formatMoneyAmount(balance)`）、`isZero`（`abs() < 0.005`） |
| 同上 | `AccountBalance.primary` 的挑选顺序改成「非零的 CNY」→ 任一非零钱包 → 第一条；`primaryBonus` 全零时返回 null |
| `app/lib/screens/profile_screen.dart` | 金额改 `primary.display`，外面套 `Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: Text(..., maxLines: 1)))`；副标题 `maxLines: 2` + `ellipsis`；赠送行改 `bonus.display`，全零不显示 |

## 验收

- 新增 `app/test/profile_balance_format_m4_32_test.dart` **9/9**：格式化 5 例（含 `0E-16`、带逗号、非数字）、钱包挑选 3 例（跳过 0 美元取人民币、全零取第一条、赠送全零为 null）、1 例给一个 20 位金额断言标题列仍有宽度。
- 版本 `0.4.31+57` → `0.4.32+58`；`flutter test` 全绿后与 M4.33 一起构建发布。

## 限制与下一步

- 金额只做显示层格式化，不做汇率换算：非 CNY 钱包按原币种符号显示。
- Host 若以后改成分（整数）返回，需要同步调整 `formatMoneyAmount`。
- 充值需要另开浏览器（见 M4.33）。
