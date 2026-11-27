# M4.34 手机对话挪到抽屉（2026-11-18）

## 一句话结论

手机档（云端直连）的对话不再出现在「工作区」，改为列在抽屉的「历史会话」区域上方；点一条就切回 AI 助手页打开它，存储仍是同一份 `cloud_conversations.json`。

## 起因

M4.30 为了让用户「找得到存档」，把手机对话放进了工作区顶部。用户看到后明确纠正：

> 手机对话记录不保存到工作区，保存到这

配图是抽屉截图，红圈画在「历史会话 → 还没有历史会话」下方的空白处。诉求有两层：工作区里别出现，抽屉里要列出来。

## 改了什么

| 位置 | 改动 |
|---|---|
| `app/lib/screens/tasks_screen.dart` | 删掉 `_PhoneChatsSection` / `_PhoneChatRow` 两个组件、`_chatStore` / `_phoneChats` / `_loadPhoneChats()`、两个插入点，以及 `onOpenCloudConversation` / `conversations` 两个构造参数与 `cloud_conversations.dart` 的 import；「未连接」空态回到原来的单个空态提示 |
| `app/lib/screens/root_shell.dart` | `RootShell` 新增 `conversations`（`CloudConversationStore?`，测试注入内存版）；State 新增 `_phoneChats` 与 `_loadPhoneChats()`（只留有内容的，最多 6 条），`initState` 读一次、每次 `_openDrawer()` 前再读一次（新聊过的马上能看见）；新增 `_openPhoneChat(id)`：关抽屉 → 切到 AI 助手（index 0）→ `CloudChatIntent.instance.open(id)` |
| 同上（抽屉 UI） | `_AppDrawer` 新增 `phoneChats` / `onOpenPhoneChat`；在「历史会话」标题之前插入「📱 手机对话 · N」小标题与列表，新增 `_PhoneChatDrawerTile`（标题 + `N 条消息 · 相对时间`，单行省略） |
| `app/lib/screens/assistant_screen.dart` | 新增 `conversations` 参数并透传给内嵌的 `CloudChatScreen(conversations: …)`——这样抽屉点开对话时用的是同一份存储，测试也能注入内存版（否则 widget 测试里真实读盘会挂住） |
| 版本 | `0.4.33+59` → **`0.4.34+60`**（`app_version.dart` 顶部新增 M4.34 说明段） |

## 验收证据

| 项 | 结果 |
|---|---|
| 新增 `app/test/drawer_phone_chats_m4_34_test.dart` | **3/3**：抽屉列出手机对话（标题、`4 条消息`、两组条目）；切到工作区后 `手机对话` 与对话标题都消失；点一条后抽屉关闭、离开工作区（助手页出现「手机 / 电脑」分档）；没有记录时整段不出现 |
| 删除 `app/test/workspace_phone_chats_m4_30_test.dart` | 旧行为（工作区显示手机对话）已被推翻，测试随之删除（5 例） |
| `app/test/pending_question_m4_31_test.dart` | `TasksScreen` 少了 `conversations` 参数，构造处同步删掉，**5/5 仍过** |
| 全量 `flutter test test/` | **423/423 PASS**（425 − 5 + 3） |
| 内存假存储 | `_FakeConversationStore extends CloudConversationStore` 覆写 `load` / `save`，避免 fake-async 里真实读盘悬住（M4.27 踩过：10 分钟超时） |
| 抽屉打开方式 | `tester.dragFrom(Offset(2, 300), Offset(320, 0))`——`RootShell` 的 `Scaffold` 抽屉用边缘拖拽最稳，不依赖菜单按钮的 tooltip |

## 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app
flutter build apk --release
```

（中文路径下 AOT 快照会炸，必须先 robocopy 到 ASCII 目录再构建；robocopy 退出码 1/3 都算成功。）

## 限制与下一步

- 抽屉里只列最近 **6** 条，全部记录仍在 AI 助手页右上角时钟里。
- 只存文字：附件不进历史（沿用 M4.27 的限制）。
- 工作区彻底不显示手机对话了——如果以后想在项目里看到，需要新加「手机对话」分组而不是恢复旧插入点。
- 「历史会话」（电脑端会话）的标题仍是「历史会话」，两段在视觉上靠小标题区分；要不要合并成一段统一时间排序，等用户反馈。
- 抽屉数据在打开时读盘（同步 6 条），没有监听文件变化；在 AI 助手页聊完、回抽屉前 `_openDrawer()` 会重读一次，所以能看到最新。
