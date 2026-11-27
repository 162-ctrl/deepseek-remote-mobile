# M4.37 报告：手机档「往上拽一下」就开新对话

- 版本：`0.4.37+63`（versionName `0.4.37-m4.37`）
- 插件：不变（0.2.30）
- 交付时间：2026-11-18
- 测试：`flutter test` **433/433**（430 + 3）

## 一句话结论

在手机档（云端直连）的对话里，把消息列表翻到顶端之后**继续往下拽**超过 130 像素，顶部浮出「松手开始新对话」，松手就新建一条。用一句用户原话描述就是「向上滑动就可以新建对话」——手指往下拖，看到的才是更早的内容，所以判定点必须是「已经到顶之后的越界量」。

## 确认过程

原话有歧义，我给了两个选项让用户选：

1. 想要手势：滑一下就新建对话
2. 是 bug：滑动时内容丢了 / 莫名变成新对话（截图里那条只有「你」的空白气泡像是这个）

用户选了 **1（想要手势）**。所以这里只做新增，没有改发送逻辑。

## 改了什么

| 位置 | 改动 |
|---|---|
| `app/lib/screens/cloud_chat_screen.dart` 字段 | `static const double _newChatPull = 130;`、`double _pullDistance`、`bool _pullArmed` |
| 同上，`_onScrollNotification` | 只累加 `OverscrollNotification.overscroll < 0`（到顶之后的越界量）；累计 ≥ 130 时 `_pullArmed = true`；反向拖回（越界量退回到阈值以下）或列表真的开始滚（`ScrollUpdateNotification`）都立刻作废；`ScrollStartNotification` 清零；`ScrollEndNotification` 时若仍 armed 就调 `_newChat()` |
| 同上，`_buildMessages` | `ListView` 套 `NotificationListener`，物理改成 `AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics())`（短对话也能拽）；armed 时在列表顶部叠一颗提示胶囊 |
| 新增 `_NewChatPullHint` | `add_comment_outlined` + 「松手开始新对话」，`accentSoft` 底、pill 圆角，叠在列表上不挤压布局 |

新建仍然走原来的 `_newChat()`：当前这条还空着就复用（不会每拽一次多一条空记录），否则插一条新的并清空输入区，旧对话照旧留在「对话记录」里。

## 验收证据

| 用例（`app/test/cloud_new_chat_pull_m4_37_test.dart`） | 断言 |
|---|---|
| 拽过阈值松手就新建 | 拽 220px 时先出提示且存储仍是 1 条（还没新建）；松手后消息清空、存储变 2 条、旧那条 `id == 'one'` 仍在、新那条 `messages` 为空 |
| 只拽一点点就不会新建 | 拽 60px 不出提示；松手后内容还在、存储仍 1 条 |
| 往上翻历史（不越界）不会触发 | 40 条消息的长对话翻到顶再拽出提示，反向拖回 260px 后松手 → 存储仍 1 条 |

反证：把 `_newChatPull` 改成 100000，前两例立刻失败（`Found 0 widgets with text "松手开始新对话"`），说明用例真的在盯这个阈值，而不是恰好通过。

## 构建

```
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app
flutter build apk --release
```

- APK：**73,049,346 字节**，versionCode **63**，SHA256 `F9671561D5A5641C113B4A5E200F8013063B0E267ADD7A8A74422CF5FCA698D6`
- 三处同哈希：`dist\DeepSeek-Remote-AI-v0.4.37-m4.37.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.37-m4.37.apk`
- `/api/v1/app/version` 回读：`versionCode 63 / 0.4.37-m4.37 / 73,049,346 / f9671561…`

> 字节数连续三个版本都是 73,049,346：同一套依赖、同一压缩率的巧合，请用 `versionCode` 或 SHA256 区分。

## 限制与下一步

- 只有**手机档（云端直连）**有这个手势；「电脑」档是直播会话，新建对话没有意义。
- 阈值写死 130 逻辑像素，不同屏幕密度下手感略有差别，可以改成按屏高比例。
- 拖拽过程中只有提示浮现，没有跟手的位移动画（要做的话得自己实现 overscroll 偏移）。
- 新建不会归档旧对话：旧那条仍在「对话记录」里，条目会越来越多。下一步可以做「自动归档 30 天没动的」。
- 待用户定的老问题还在：抽屉「历史会话」在插件直连下永远是空的（M1.1 旧接口 404）；「电脑」页是修强还是删掉只留紧急停止。
