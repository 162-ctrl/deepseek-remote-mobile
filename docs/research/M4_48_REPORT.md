# M4.48 两档改名「本机对话 / 远程电脑」+ 首次切换说明（第二阶段第 ⑨ 条）

> 日期：2026-11-23
> App `0.4.48-m4.48`（versionCode 74）· 插件不变（0.2.33）

## 一句话结论

AI 助手页的「手机 / 电脑」两档改名为「本机对话 / 远程电脑」，抽屉与会话中心里原来叫「本机直连」的分组也统一成「本机对话」；第一次切档时在输入框上方挂一条说明讲清两者差别，点「知道了」或 × 收起后用 `mode_intro_seen_v1` 记住，之后不再打扰。

## 之前的问题

| 位置 | 以前的样子 | 问题 |
|---|---|---|
| AI 助手页顶部胶囊 | 「手机」「电脑」 | 听起来像两台设备，实际是两种对话方式（一个用手自己的 Key，一个连电脑） |
| 抽屉 / 会话中心分组 | 「本机直连」 | 与胶囊的叫法不一致，同一个东西两个名字 |
| 切档时 | 什么也不说 | 用户不知道切过去会「用不上 API Key」还是「文件读不了」 |
| 云端口空态 | 「手机档不经过电脑…」 | 仍在用旧档名 |

## 改了什么

| 位置 | 改动 |
|---|---|
| `app/lib/services/mode_intro.dart` | 新增 `ModeIntroCopy`（`title` / `local` / `remote` / `dismiss` 四段文案）；沿用已存在的 `ModeIntroPrefs`（`mode_intro_seen_v1`，`load()` / `markSeen()` / `seen`） |
| `app/lib/screens/assistant_screen.dart` | 构造参数新增可注入的 `modeIntro`；`initState` 读一次标记；切档走新的 `_setMode()`（未看过就挂说明）；新增 `_ModeIntroCard`（主题色 `accentSoft` 底、标题 + 两段说明 + 右上 × + 「知道了」）；胶囊标签改为「本机对话 / 远程电脑」 |
| `app/lib/screens/root_shell.dart` | 抽屉分组 `本机直连` → `本机对话` |
| `app/lib/screens/session_center_screen.dart` | 分组标题、空态文案同步改成「本机对话」 |
| `app/lib/screens/cloud_chat_screen.dart` | 空态改成「本机对话不经过电脑，直接用你自己的 API Key 回答，不连电脑也能用。」 |

`switchModeForTest()` 保持直接切档、不挂说明，老用例不受影响；工作区/会话中心「打开本机对话」的代码路径也不经过用户点胶囊，因此不会弹说明。

## 验收

新增 `app/test/mode_intro_m4_48_test.dart` **4/4**：

1. 两档显示新名字、旧名字 `手机` / `电脑` 找不到，且没切档时不出现说明
2. 第一次切到「远程电脑」出现说明（标题 + 两段正文）；点「知道了」收起并写入 `mode_intro_seen_v1=1`，再切回不再出现
3. 点右上角 × 也能收起并记住
4. 已经说过一次（预置 `mode_intro_seen_v1=1`）时切档既不出现说明、也不重复写存储（`setCalls == 0`）

同一轮把受改名影响的 6 个测试文件同步（`assistant_mode_m4_6`、`attachment_m4_2`、`drawer_phone_chats_m4_34`、`drawer_history_m4_43`、`session_center_m4_47`、`widget_test`）。其中两处踩到「名字撞车」，一律改成在抽屉范围内断言：

- `find.byIcon(Icons.close_rounded)` 会同时匹配到别的关闭按钮 → 说明卡片给 `ValueKey('modeIntroClose')`
- 改名后抽屉分组标题与切换胶囊同名 → 抽屉相关断言改 `find.descendant(of: find.byType(Drawer), …)`

全量 `flutter test test/` → **513/513 PASS**（509 + 4）。

反证：把 `_setMode()` 里的 `if (!_modeIntro.seen) _showModeIntro = true;` 换成空块 → 第 2、3 例失败（说明卡片根本没出现），恢复即绿。

`flutter analyze` → **32 issues / 0 error**；本轮触碰的文件里剩 7 条全部是既有遗留（`assistant_screen.dart` 的 2 个 unused import、`_openCloudChat`、`_GreetingBlock`，`root_shell.dart` 的 `_size` 参数、私类型进公共 API、`RootShellItems` 命名），留到第三阶段拆代码时一起清。

## 交付

- APK **73,213,886 字节**，SHA256 `ECD2E0CBDBDAB35DFF1ABD015F3C3E2010A089CFB63995E73D4254D7C6F40CAC`，`versionCode=74`，`versionName=0.4.48-m4.48`
- 签名：`CN=Android Debug`（与手机已装版本同签名，可直接覆盖升级）
- 三处同哈希 + `/api/v1/app/version` 回读 + `node tools/verify-release.mjs` 四项一致

## 限制与下一步

- 说明只在「用户主动点胶囊切档」时出现；从会话中心打开本机对话属于用户已经选好的目标，不重复教育。
- 本机对话仍只存在手机本地，换机或重装会丢。
- 第二阶段到此收口（①–⑨ 全部完成）。第三阶段：拆 `LiveStore`、`desktop_session_screen.dart`、`assistant_screen.dart`，并清掉剩余 analyze 死代码告警（`_TaskCard`、`_ArchivedCard`、`_GreetingBlock`、`_RichText` 等）。
