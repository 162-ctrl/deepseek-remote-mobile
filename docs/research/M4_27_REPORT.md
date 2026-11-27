# M4.27 手机档：新建对话、记录留在侧端

## 一句话结论

手机档（云端直连）以前只有一条对话：点「新对话」就是把内存里的消息清空，退出页面就全没了，也没有地方翻历史。现在每条对话单独存进应用私有目录的 `cloud_conversations.json`，顶栏那颗「历史」按钮从左侧滑出「对话记录」——新对话、切回任意一条、删掉不要的；标题自动取第一句话，按更新时间倒序排列。

## 起因

用户发来两张截图：

- 第一张是豆包的侧边栏：置顶一条「图片相关」，下面「最近」里一串历史（用户红圈圈出来的四条），顶部还有「新对话 / 新工作任务…」入口。
- 第二张是我们自己的云端对话页：左上 ≡、中间胶囊「云端直连 · deepseek-chat」、右上时钟图标、下面「手机 / 电脑」分档。

配文：「手机上的对话可以新建对话，对话保留，可以新建对话，记录留在侧端，像豆包这样的」。

## 改动

### 手机端（0.4.27+53 / `0.4.27-m4.27`）

新增 `app/lib/services/cloud_conversations.dart`：

| 类型 | 作用 |
|---|---|
| `CloudChatRecord` | 一条消息（`role` / `text` / `failed`），能存成 JSON |
| `CloudConversation` | 一条对话（`id` / `title` / `createdAt` / `updatedAt` / `messages`）；`displayTitle` 没起名时取第一句用户的话 |
| `conversationTitle(raw, {max = 18})` | 压成单行、去多余空白、超长截断加 `…` |
| `CloudConversationStore` | 读写 `cloud_conversations.json`；坏文件当空库；保存时按更新时间倒序、最多留 80 条 |

`app/lib/screens/cloud_chat_screen.dart`：

- 新增构造参数 `conversations`（可注入存储，测试用）。
- 状态新增 `_conversations` / `_currentConversationId`；`_load()` 先读接口配置让首屏能开，再单独 `_loadConversations()`（读盘慢或文件坏都不拖住页面）。
- `_persist()`：把内存里的消息写回当前对话、补标题、刷 `updatedAt`、存盘。发问后立刻存一次（网络断了也不丢），回复或失败原因落盘后再存一次。
- `_newChat()`：当前这条还空着就复用，否则真的另起一条并落盘。
- `_openHistory()`：`showGeneralDialog` + 从左侧滑入的面板（宽度 82%），列表里显示标题、消息条数、相对时间，当前那条高亮，右侧垃圾桶删除。
- 未内嵌时（独立页）AppBar 也加了「对话记录」入口。

`app/lib/screens/assistant_screen.dart`：手机档顶栏的「历史」按钮接到 `CloudChatController.openHistory()`（以前手机档没传 `onHistory`），tooltip 改「对话记录」。

## 验收证据

| 项目 | 结果 |
|---|---|
| `flutter test test/` | **397/397 PASS**（387 + 10） |
| 新增用例（纯 Dart 存储） | 5 例：存读往返与倒序、无标题取第一句、标题压缩截断、只留最近 N 条、坏文件当空库 |
| 新增用例（widget） | 5 例：打开显示最近那条、侧栏列出并切过去、新对话另起一条且写回、删一条不丢别的、重开后话还在 |
| APK | `dist\DeepSeek-Remote-latest.apk`，**72,934,594 字节**，versionCode **53**，SHA256 `2C5768CE11F772AC…78C711D` |
| 回读 | `GET /api/v1/app/version` → `{"versionCode":53,"versionName":"0.4.27-m4.27","size":72934594,"sha256":"2c5768ce…78c711d"}` |

构建命令（中文路径下 AOT 会炸，必须 robocopy 到 ASCII 目录）：

```powershell
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd C:\Users\user\dsh-tools\build\dsh-app; flutter build apk --release
```

## 限制与下一步

1. **附件不进历史**：只存文字。历史里翻到带图的那条，图片缩略图不会重新出现（图片本来也只发给模型、不落盘）。
2. **只在手机本地**：`cloud_conversations.json` 存应用私有目录，删 App 或清数据就没了；没有云同步，也没有导出。
3. **切换对话不做上下文压缩**：每条对话把全部历史原样发给模型，长对话迟早会撞上下文上限（电脑档那边有压缩，手机档没有）。
4. **标题不能改**：自动取第一句，没有重命名入口；同名对话在侧栏里只能靠时间区分。
5. 踩坑记录：`testWidgets` 跑在 fake-async 里，真实文件读写永远不会完成——widget 测试必须注入内存假存储，纯 Dart 的 `test()` 才能碰真文件；`controller.openHistory()` 要 `unawaited` 调用，否则 `await` 会等到弹窗关闭才返回。
