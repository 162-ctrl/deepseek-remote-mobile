# M4.8 报告：「不用上传」，手机档和正常 AI 一样处理各种问题

更新：2026-11-14 · 手机端 `0.4.8+35`（`0.4.8-m4.8`）· 电脑端插件不变（`0.2.12`）

## 1. 一句话结论

用户说「不用上传，就和正常的 ai 一样可以处理各种问题」。M4.7 虽然把附件塞进了云端请求，
但电脑档的解释文本还写着「已上传到电脑 / 已保存到电脑」，手机档遇到 PDF、Word、Excel
这类只有图片和纯文本以外的文件也只能丢一句「格式不支持」。本次：

- 界面里**不再出现「上传」**：电脑档发完附件不再弹「已上传到电脑：N 个文件」，指令里的
  列表从「附件（已保存到电脑）」改成「附件：」，附件条上传中显示「正在读取…」。
- 手机档把**非图片文件交给电脑读成文字**再随消息发出（`POST /api/v1/desktop/file/read`），
  读不到时退回「只告诉模型文件名」——用户不用再关心格式。
- 手机档首次使用的引导重写：说明「手机档不经过电脑、Key 只存在手机上」，并给出
  去开放平台生成 Key → 回来粘贴的两步。

## 2. 起因与根因

| 现象 | 根因 | 修复 |
| --- | --- | --- |
| 发完附件弹「已上传到电脑：N 个文件」 | `assistant_screen.dart` `_send()` 里 M4.2 加的 `_toast` 回执 | 删掉该回执 |
| 指令里写「附件（已保存到电脑）」 | 同上，`listing` 文案 | 改成「附件：」 |
| 附件条写「正在上传…」 | `widgets/attachment_bar.dart` 的 `uploading ? '正在上传…'` | 改成「正在读取…」 |
| 手机档收不了 PDF / Word / Excel | 手机端没有解析库，云端模型只吃图片和文本 | 新增 `CaretakerReader` 契约 + `POST /api/v1/desktop/file/read`：借电脑把文件读成文字 |
| 用户不知道 Key 去哪弄 | 设置引导只有一句「填一个 API Key 就能用」 | 重写为：手机档不经电脑 + 两步说明（开放平台生成 → 粘贴） |

## 3. 电脑端插件

无改动要求（仍是 `0.2.12`，不需要重启 DSH）。

`POST /api/v1/desktop/file/read` 是**新增的候选接口**：手机档要读 PDF / Word / Excel 时调用它，
由电脑上的 Agent 读文件、返回正文，手机端把它内联进发给云端模型的 prompt。电脑不在线、
插件没有这个接口、或读不出来时，手机端自动降级为「只发文件名」，不影响发送。

> 当前版本的实现里，手机端这条链路在电脑离线 / 接口不存在时静默降级（`_DesktopCaretaker`
> 捕获异常返回 null），所以**没有这个接口也不会报错**——只是 PDF 会退回到「已附带文件」提示。
> 插件侧接入见 §7「下一步」。

## 4. 手机端改动

| 文件 | 改动 |
| --- | --- |
| `lib/services/cloud_chat.dart` | 新增 `abstract class CaretakerReader { Future<String?> read(PendingAttachment) }`；`CloudMessage.buildContent({caretaker})` 与 `CloudMessage.buildUserContent(text, attachments, {caretaker})` 改为异步，非文本非图片附件先问 caretaker，失败才退到文件名提示；`CloudChatClient.complete({caretaker})` 透传，messages 逐条 `await` |
| `lib/services/history_api.dart` | 新增 `readDesktopFile(baseUrl, {token, name, bytes})` → `POST /api/v1/desktop/file/read`，空内容抛 `PairingApiException('电脑没能读出这个文件的内容')` |
| `lib/data/live_store.dart` | 新增 `readDesktopFile({name, bytes})`（未连接抛异常，`_withAuthRetry` 复用） |
| `lib/screens/assistant_screen.dart` | 新增 `_DesktopCaretaker implements CaretakerReader`（把 LiveStore 包成读文件能力，异常吞掉返回 null）；`CloudChatScreen(caretaker: _DesktopCaretaker(live))`；电脑档 `_send()` 去掉「已上传到电脑」回执、指令列表改「附件：」 |
| `lib/screens/cloud_chat_screen.dart` | `CloudChatScreen.caretaker` 参数，传给 `_client.complete`；附件条提示改「图片和文本直接发给模型」；`_SetupHint` 重写 + 新增 `_StepsBlock` 两步引导 |
| `lib/widgets/attachment_bar.dart` | `uploading` 时文案「正在上传…」→「正在读取…」 |

## 5. 验收证据

| 项 | 结果 |
| --- | --- |
| `flutter test` | **307/307 通过**（M4.7 的 301 + M4.8 新增 6） |
| 新增测试 | `app/test/attachment_m4_8_test.dart`：PDF 经 caretaker 内联、读不到时退回文件名、caretaker 抛异常不影响发送、图片不调 caretaker、文本文件不调 caretaker、多段 content 可 `jsonEncode` |
| 同步修改的测试 | `app/test/cloud_attachment_m4_7_test.dart`（`buildContent` 变异步 → 用例改 `async` + `await`；`_FakeClient.complete` 补 `CaretakerReader? caretaker`；设置引导断言改 `textContaining('要发图片')`）、`theme_m2_3_test.dart` / `empty_state_test.dart` / `widget_test.dart`（版本号 → `0.4.8+35` / `手机端 v0.4.8-m4.8`） |
| `flutter analyze` | 23 issues、**0 error**（其余为历史 warning/info） |

## 6. 生效步骤

1. 安装 `dist\DeepSeek-Remote-latest.apk`（`0.4.8-m4.8`，versionCode 35，可直接覆盖安装）。
2. 打开 AI 助手 → 「手机」档 → 点顶栏胶囊 → 去 `platform.deepseek.com` 生成一个 API Key
   → 回来粘贴、保存（接口地址与模型保持默认即可）。
3. 「电脑」档发附件不再出现「上传」字样，文件仍落在 `<工作区>\手机附件\`，AI 直接读。
4. 电脑端插件无需重启（仍是 `0.2.12`）。

## 7. 已知限制与下一步

- 手机端**必须用自己生成的 API Key**：DeepSeek 官方对话模型（`deepseek-chat`）不接收图片，
  要发图请在设置里改成支持视觉的模型（如 `gpt-4o`、Kimi vision）。
- `POST /api/v1/desktop/file/read` 尚未在插件侧实现（见 §3）：现在 PDF / Word / Excel 会
  退化成「已附带文件：xxx，格式不支持在手机上预览」。下一步在插件里用本机能力把文件抽成
  文本（Word/Excel 解 zip+XML、PDF 抽文本），手机端无需再改。
- 本次仍未真机复测：`adb devices` 一直无设备（USB 未连或未授权），需要插线后验证一遍。

## 8. 证据索引

- 代码：`app/lib/services/cloud_chat.dart`、`app/lib/screens/cloud_chat_screen.dart`、
  `app/lib/screens/assistant_screen.dart`、`app/lib/services/history_api.dart`、
  `app/lib/data/live_store.dart`、`app/lib/widgets/attachment_bar.dart`
- 测试：`app/test/attachment_m4_8_test.dart`、`app/test/cloud_attachment_m4_7_test.dart`
- APK：`dist\DeepSeek-Remote-AI-v0.4.8-m4.8.apk`（= `dist\DeepSeek-Remote-latest.apk` = 根目录
  `DeepSeek Remote AI 手机端 v0.4.8-m4.8.apk`）
