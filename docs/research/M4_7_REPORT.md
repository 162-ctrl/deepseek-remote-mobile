# M4.7 报告：AI 助手「手机」档也能发照片 / 文件

更新：2026-11-14 · 手机端 `0.4.7+34`（`0.4.7-m4.7`）· 电脑端插件不变（`0.2.12`）

## 1. 一句话结论

用户反馈「AI 助手手机页面怎么没有上传文件图片拍照的」——原因是 M4.6 恢复的「手机」档
= 内嵌的云端直连页，它只有输入框和发送键，附件入口只在「电脑」档有。本次把附件能力
抽成两档共用的组件，手机档同样常驻**拍照 / 相册 / 文件**，并把附件真正送进云端模型
（图片走 OpenAI 兼容的 `image_url` 视觉段，文本文件内联）。

## 2. 起因与根因

| 现象 | 根因 | 修复 |
| --- | --- | --- |
| 手机档没有拍照 / 相册 / 文件 | `cloud_chat_screen.dart` 的 `_CloudComposer` 只有 TextField + 发送键 | `_CloudComposer` 上方接入 `AttachmentBar`（常驻三个入口） |
| 手机档附件无处可去 | 云端请求只发 `{role, content: <String>}` | `CloudMessage.attachments` + `buildUserContent()` 拼成 `[{type:text},{type:image_url}]` |
| 两档附件代码重复 | 电脑档的 `_PendingAttachment`/`_AttachmentBar` 是 `assistant_screen.dart` 里的私有类 | 抽到 `lib/widgets/attachment_bar.dart`（`PendingAttachment` / `AttachmentPicker` / `AttachmentBar` / `AttachmentThumbnails`） |
| 用户不知道手机档能发图 | 未配置接口时只提示「填一个 API Key」 | 设置引导补一句「要发图片，请填支持视觉的接口」 |

## 3. 电脑端插件

无改动（仍是 `0.2.12`）。手机档的附件**不经过电脑**，直接进云端 API 请求。

## 4. 手机端改动

| 文件 | 改动 |
| --- | --- |
| `lib/widgets/attachment_bar.dart`（新） | `PendingAttachment`（后缀→MIME、文本判定、大小文案）、`AttachmentPicker`（拍照/相册/文件，平台实现惰性获取）、`AttachmentBar`（三胶囊 + 已选附件条 + 去向提示）、`AttachmentThumbnails`（气泡里的缩略图） |
| `lib/services/cloud_chat.dart` | `CloudMessage.attachments`；`buildUserContent()` 纯函数：图片→`image_url` base64，文本文件→`【附件 x】` 内联（超 2 万字截断），其它→只提示文件名；`complete()` 的 messages 改成 `Map<String,dynamic>` |
| `lib/screens/cloud_chat_screen.dart` | `_attachments` 状态与拍照/相册/文件方法；`_CloudComposer` 接入 `AttachmentBar`；发送时带附件并清空；`_Bubble` 显示缩略图；空态与设置引导补文案；`attachForTest` / `sendForTest` |
| `lib/screens/assistant_screen.dart` | 改用共享的 `PendingAttachment` / `AttachmentPicker` / `AttachmentBar`，删掉文件末尾 285 行旧的私有实现 |

## 5. 验收证据

| 项 | 结果 |
| --- | --- |
| `flutter test` | **301/301 通过**（M4.6 291 + M4.7 新增 10） |
| 新增测试 | `app/test/cloud_attachment_m4_7_test.dart`：附件分类 3 例、`buildUserContent` 4 例、云端页 3 例（未配置不显示入口 / 已配置常驻三入口 / 附件进请求体且气泡显示缩略图） |
| `flutter analyze` | 23 issues、**0 error**（其余为历史 warning/info） |
| release APK | `Dist/DeepSeek-Remote-AI-v0.4.7-m4.7.apk`，**72,031,674 字节**，SHA256 `30BE13B6ABAE75FAE99F874A333F815BBC060304ABF86D005B7A940C3110CEDD` |
| 版本信息 | `aapt2 dump badging` → `versionCode='34' versionName='0.4.7-m4.7'`，minSdk 24 / targetSdk 36 |
| APK 签名 | `CN=Android Debug`，证书 SHA-256 `341ef83b…70f6`，与之前版本一致 → 可覆盖安装 |
| 版本接口 | `GET /api/v1/app/version` 已返回 `{"versionCode":34,"versionName":"0.4.7-m4.7","size":72031674,…}` |

## 6. 生效步骤

1. 装 `dist\DeepSeek-Remote-latest.apk`（覆盖安装即可，签名未变）。
2. 电脑端插件不用重启（仍是 0.2.12）。
3. 打开 App → AI 助手默认停在「手机」档：点顶栏胶囊「云端直连 · …」填一个**支持视觉**的
   接口（如 OpenAI `gpt-4o`、Kimi 的 vision 模型），本机 DeepSeek 对话模型不支持看图。
4. 输入条上方出现「拍照 / 相册 / 文件」，选好后点发送；气泡里能看到缩略图。

## 7. 已知限制

1. 图片以 base64 直接进请求体，原图大时请求慢（拍照/相册已压到 2400px 内）。
2. 文本文件超过 20000 字会截断，只发前半段。
3. 接口必须支持视觉；DeepSeek 的对话模型收到图片会报错（属于接口能力，不是 App 问题）。
4. 附件只在当前对话内有效，不落盘、不能重发。
5. 本批仍未真机复测（`adb devices` 无设备）。

## 8. 下一步

1. 云端附件支持从历史消息里重发 / 存到系统下载目录。
2. 「手机」档顶栏显示当前接口是否支持视觉（读模型名白名单）。
3. 等待用户提供「桌面直播加载不了之前的对话」的截屏，继续定位。

## 9. 证据索引

- 源码：`app/lib/widgets/attachment_bar.dart`、`app/lib/services/cloud_chat.dart`、`app/lib/screens/cloud_chat_screen.dart`、`app/lib/screens/assistant_screen.dart`
- 测试：`app/test/cloud_attachment_m4_7_test.dart`
- 产物：`dist/DeepSeek-Remote-AI-v0.4.7-m4.7.apk`、`dist/DeepSeek-Remote-latest.apk`、`DeepSeek Remote AI 手机端 v0.4.7-m4.7.apk`
