# M4.30 手机档的对话自动「存档」到工作区

## 一句话结论

手机档（云端直连）的对话其实从 0.4.27 起就在自动存了，但入口只藏在 AI 助手页右上角那颗时钟里；现在**「工作区」顶部多了一组「手机对话」**，列出标题、消息条数、最近时间，点一条直接切到手机档并打开它——用户找「存档」时看的就是这一页。

## 起因

用户消息：「手机上的ai助手对话完没有自动存档」；追问后确认是**手机档（云端直连，没连电脑）**。

查下来两件事：

1. `app/lib/services/cloud_conversations.dart` + `CloudChatScreen._persist()` 从 0.4.27 起就把每条对话写进 `cloud_conversations.json`（发问立刻存一次、回复或失败后再存一次），所以「没存」不成立。
2. 但这条记录**只有 AI 助手页的侧边栏能看到**（顶栏那颗历史图标 → `_openHistory()`），而「工作区」只列电脑端的任务与存档会话——手机档的对话在工作区里完全不可见，用户自然觉得「没存档」。

## 改了什么

| 文件 | 改动 |
|---|---|
| `app/lib/services/cloud_chat_intent.dart`（新增） | `CloudChatIntent extends ChangeNotifier` 单例：`open(id)` 写入、`take()` 取走一次。工作区与 AI 助手页在 `RootShell` 的 `IndexedStack` 里并排常驻，没有父子关系，用一个极小广播把「切手机档 + 选中这条」传过去 |
| `app/lib/screens/tasks_screen.dart` | 新增可选参数 `onOpenCloudConversation` 与 `conversations`（测试注入）；`_loadPhoneChats()` 读同一份存储（只取有消息的、最近 5 条）；新增 `_PhoneChatsSection` / `_PhoneChatRow`：标题「手机对话」+ 右侧「只存在这台手机上」，每行 `displayTitle` + `N 条消息 · 相对时间`；**没连电脑时也显示**（手机档本来就不需要电脑） |
| `app/lib/screens/cloud_chat_screen.dart` | `CloudChatController.openConversation(id)` + `_CloudChatScreenState.openConversationById(id)`：内存里没有就先读一次盘，再 `_switchConversation(id)` |
| `app/lib/screens/assistant_screen.dart` | `initState` 监听 `CloudChatIntent`，`_onCloudIntent()` 里 `setState(_mode = 'phone')` 再 `_cloudController.openConversation(id)`；`dispose` 里摘监听 |
| `app/lib/screens/root_shell.dart` | `TasksScreen(onOpenCloudConversation: (id) { CloudChatIntent.instance.open(id); _select(0); })` |

## 验收证据

| 项 | 结果 |
|---|---|
| 新增测试 | `app/test/workspace_phone_chats_m4_30_test.dart` **5/5**：没连电脑也能看到「手机对话」与「4 条消息」、空对话不占行、点一条回调 `['c1']`、意图只被读走一次、空白 id 不产生意图 |
| 全量 | `flutter test test/` **409/409 PASS**（404 + 5） |
| APK | 72,951,042 字节，`0.4.30-m4.30` / versionCode **56**，SHA256 `549D9759F7BC6B8E5EE63414773EDF85253596265B218F67C784F6F8047DEDDA`；三处同哈希；`GET /api/v1/app/version` 回读一致 |
| 插件 | 未改动（仍 0.2.29，待用户完整重开 DSH） |

## 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
$env:JAVA_HOME  = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app; flutter build apk --release
```

## 限制与下一步

- 工作区只列**最近 5 条**；要看全部还是进 AI 助手页的侧栏。
- 仍然只存文字：附件不进历史（M4.27 起的限制没变）。
- 只在这台手机上，没有云同步；换手机或清数据就没了。
- 手机档对话不参与电脑端的「项目分组」，所以工作区里是单独一组，不挂在某个项目下。
- `CloudChatIntent` 是进程内单例，多标签/多窗口场景没考虑（目前单实例 App）。
