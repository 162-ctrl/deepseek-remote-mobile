# M4.65 / M4.66：App 内充值页 + 功能页「更新日志」

- **App**：`0.4.60+81`（versionName `0.4.60-m4.60`）
- **插件**：`0.2.69`
- **一句话**：「我的 → 去充值」不再直接跳浏览器，而是进一页把余额、步骤、官方入口和「为什么不能直接付」讲清楚；功能页多了「更新日志」，以后每次发版的内容都收在那里。

## 之前的问题

| 诉求 | 之前的样子 | 问题 |
| --- | --- | --- |
| 用户问「充值页面能不能做」 | 「我的 → 账户余额」卡片右下角一个「去充值」，点了直接开系统浏览器 | 跳走之后与 App 断联；回来要自己找刷新；为什么不能直接付、没到账怎么办都没有地方说 |
| 用户要「功能界面专门放一个更新日志」 | 更新说明只写在 `docs/UPDATE_NOTES.md` 和每次投递的 markdown 里 | 手机上翻不到；每次发版还得记着单独发一份说明 |
| 分享 / 用其他应用打开「还是用不了」 | 0.4.59 才加分享按钮 | 用户装的还是 0.4.58 及更早版本，自然没有入口；「用其他应用打开」在这台没装 WPS 的手机上本来就会失败 |

## 改动

| 文件 | 改动 |
| --- | --- |
| `app/lib/screens/recharge_screen.dart`（新） | 充值页：`_BalancePanel`（充值余额 / 赠送余额 / 状态 / 查过多久 + 「去官方充值」「刷新」）、三步 `_StepRow`、「打开官方充值页」与「已充值，刷新余额」、三张说明卡（为什么不能直接付 / 没到账怎么办 / 赠送额度与发票） |
| `app/lib/screens/profile_screen.dart` | 「去充值」改成 push `RechargeScreen`，返回后自动刷新余额；删掉不再使用的 `_urlOpener` 字段 |
| `app/lib/screens/changelog_screen.dart`（新） | 更新日志页：连电脑时 `loadUpdateNotes()`，失败或为空回退 `assets/update_notes.md`；打包那份会在顶部提示来源 |
| `app/lib/screens/features_screen.dart` | 「插件管理」「接收文件」之外新增「更新日志」一行 |
| `app/lib/services/history_api.dart` | 新增 `UpdateNote` 与 `listUpdateNotes()`（`GET /api/v1/app/notes`） |
| `app/lib/data/live_store.dart` | 新增 `loadUpdateNotes()` |
| `app/assets/update_notes.md` + `app/pubspec.yaml` | 把 `docs/UPDATE_NOTES.md` 随包一份，离线也能看 |
| `dsh-plugin-m1/lib/appupdate.js` | 新增 `readUpdateNoteList(projectDir)`：按 `## ` 把 `UPDATE_NOTES.md` 拆成 `{version, date, title, body}` |
| `dsh-plugin-m1/lib/server.js` | 新增 `GET /api/v1/app/notes`（认 app token，回 `{notes}`） |
| `dsh-plugin-m1/lib/index.js` | `pageContext.appNotes = () => readUpdateNoteList(projectDir)` |

## 验收

- 新增测试：`app/test/recharge_m4_65_test.dart` 3 例、`app/test/changelog_m4_66_test.dart` 2 例、插件 `test/appupdate-notes.test.js` 补 2 例、新 `test/app-notes-route.test.js` 3 例。
- App 全量 **541/541** 通过（536 + 5），`flutter analyze --no-pub` **33 issues、0 error**。
- 插件全量 **187/187** 通过（185 + 2），`node --check` 两个入口 0。
- 改动的既有测试：`profile_balance_format_m4_32_test.dart` 的「点去充值」改成「先进充值页，再点按钮交给浏览器」；`theme_m2_3_test.dart`、`empty_state_test.dart`、`widget_test.dart` 的版本断言升到 0.4.60 / 81。
- 真机接口验证（插件 0.2.69 热载后）：`GET /api/v1/app/version` → `0.4.60-m4.60` / code 81 / size 73543936 / `notes` 360 字；配对后 `GET /api/v1/app/notes` → 8 条，第一条 `0.4.60+81 充值页与更新日志`。

## 交付

| 项 | 值 |
| --- | --- |
| APK | `dist/DeepSeek-Remote-latest.apk`，73,543,936 字节 |
| SHA256 | `FA77CB13CE48DB5A7F131EC44787E5F302BFAC08730CBB28FD44CB2C5BF93625` |
| versionCode / versionName | 81 / `0.4.60-m4.60` |
| 插件 | 0.2.69（已热载） |

## 限制与下一步

- **App 内不能直接付款**：手机端没有商户号，电脑端账户服务也只有读（`getBalance` / `getProfile` / 登录），没有下单、收款、开发票的方法 —— 这是接口边界，不是没做完。
- 更新日志只读 `docs/UPDATE_NOTES.md` 的前 1500 字 / 每段 4000 字，太长的说明会被截断。
- 分享 / 用其他应用打开：需要用户先装 0.4.59+80 及以上；「用其他应用打开」在没装 WPS 的手机上依旧会失败，但失败文案已经指向「分享」。
- 剩余遗留：M4.62 直播推送的 `session`/`question` 帧真机验证、M4.57 接收文件在手机上的真机点开验收。
