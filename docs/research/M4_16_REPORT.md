# M4.16 手机看到的必须是对话，而且一进来就是最新

## 一句话结论

用户打开一个会话，看到的第一条是 Host 的英文运行时注入
（`Time sampled while preparing turn 3, step 24: …`），第二条是模型的英文思考
（`Header empty. So where does blue come from?…`），而真正的对话在更下面 ——
三件事同时坏掉：**注入消息没过滤**、**推理被当成回复**、**列表没停在最新**。
M4.16 把三者一起修掉：过滤规则集中到插件的 `lib/chat-filter.js`（写入端 + 读取端都过滤），
`assistantText` 不再回退到 reasoning，App 侧列表改 `reverse` 让最新一条天然在底部。

## 起因

用户 16:15 发来截图（桌面直播页，标题旁「已存档」，徽标「已结束 · 78 条消息」，过程条「0 步」），
配文：「每个对话里面的内容你不应该放到最新的吗，而且你这英文是什么，我要的是对话」。

截图里两条气泡，一条是注入、一条是推理，都不是「对话」。而底部状态条还写着
「已同步到最新 · 可直接发指令」——它其实一直这么写，与滚动位置无关。

## 根因（三条，都用真实数据验过）

对着 `C:\Users\user\.dsh\dsh-plugin-m1\session-archive.json`（142 条记录）用 node 复现：

| 现象 | 根因 | 位置 |
| --- | --- | --- |
| 英文用户气泡 | `INJECTED_USER_PREFIXES` 缺 `'Time sampled while preparing'`；更糟的是**存档写入路径 `archiveEvent` 根本没调用过滤**（只有直播路径 `mapDesktopEvent` 调） | `dsh-plugin-m1/lib/index.js:1095-1102`、`:484-498` |
| 英文助手气泡 | `assistantText()` 在没有正文 part 时 `const chosen = texts.length > 0 ? texts : others;` **回退到全部 part**，于是只有 `reasoning` 的消息整段被当成回复 | `dsh-plugin-m1/lib/assistant-text.js:33-46` |
| 打开停在中段 | `_scrollToEnd(force: true)` 在 post-frame 里 `jumpTo(position.maxScrollExtent)`，而 `ListView.builder` 首帧的 `maxScrollExtent` 只覆盖已构建的几屏，长列表跳不到真正的底部 | `app/lib/screens/desktop_session_screen.dart:353-365` |

第三条的取证：截图那条会话是 `session-4670a31a-a988-4afc-a91c-537bdd91fe28`
（title「我是一名课程计算机学生，只」，380 条事件、messageCount 495）。按 App 规则过滤后正好
**78 条**（与截图「78 条消息」一致），那条 `Time sampled…turn 3, step 24` 在第 **30** 条，
紧接第 31 条就是「Header empty…」—— 视图停在中段，不是末尾。

附带问题：`GET /api/v1/desktop/archive/sessions/<id>` 只回
`sessionId/running/lastSeq/events`，没有 title/cwd，App 只能回落成「桌面会话 / 电脑上的会话」，
所有存档看起来一模一样。

## 改动

### 电脑端插件 0.2.22

- 新建 `dsh-plugin-m1/lib/chat-filter.js`：注入前缀表（11 条，含 `Time sampled while preparing`）、
  4 条特征串 + 只扫前 160 字符（正文中段提到这些词不算）、`isInjectedUserText()`、
  `chatText = assistantText`（规则只有一份）、`isInjectedEvent()`（供读取端清洗老存档）。
- `assistant-text.js`：删掉 reasoning 回退，**没有正文 part 就返回空串**。
- `index.js`：`archiveEvent` 在写入时过滤注入、assistant 用 `chatText`；
  `mapDesktopEvent` 删掉本地前缀表、改用同一份规则；`getArchivedSession` 在读取时再过滤一遍
  （老存档已含脏数据）；`server.js` 的 archive-one 响应补 `title / cwd / lastTime / messageCount`。
- **老存档按磁盘日志重读**：新增 `ARCHIVE_EVENT_SCHEMA = 2`、`findSessionLogFile(id)`、
  `migrateLegacyArchiveEvents()`。存档事件只剩 `{kind,text,time}`、类型信息已丢，光靠过滤洗不掉
  「英文推理被存成 assistant 文本」；而磁盘日志 `session.vN.jsonl.zstd` 里 part 类型还在，
  所以对「用户事件里含注入」的脏记录重读一遍并替换事件。实测该会话日志 3252 行、
  447 条 assistant 消息里只有 **9 条**有正文 part（438 条纯推理），重读后手机只会看到这 9 条。
- 版本 `dsh-plugin-m1/package.json` → `0.2.22`。

### 手机端 0.4.16+43

- 新建 `app/lib/services/chat_filter.dart`（与插件同一份前缀表），`_messages` 的 user 分支
  先 `looksInjectedUserText(event.text)` 再决定要不要显示 —— 旧插件/旧缓存也能兜住。
- 列表改 `reverse: true`，`itemBuilder` 取 `messages[messages.length - 1 - index]`；
  `_scrollToEnd` 改成 `jumpTo(0)` / `animateTo(0)`；新增 `_atLatest` + `_onScroll`
  （`pixels < 160` 视为在最新）。
- `_LiveFooter` 文案三态：运行中「实时同步…」、在最新「已同步到最新…」、
  往上翻时 **「往上是更早的对话 · 点这里回到最新」**（可点，回到 offset 0）。
- 版本：`app_version.dart`（`kAppVersionCode = 43`）、`pubspec.yaml`、`android/local.properties`、
  `android/app/build.gradle.kts:31`。

### 测试

- 插件新增 `dsh-plugin-m1/test/chat-filter.test.js`（5 例：注入识别、人话不误杀、`chatText` 只取正文、
  `isInjectedEvent` 清洗、前缀表含 Time sampled）；`assistant-text.test.js` 的旧用例
  「没有正文 part 时回退」改成断言空串。
- App 新增 `app/test/chat_filter_m4_16_test.dart`（5 例），并用源码断言锁住
  `reverse: true`、`messages[messages.length - 1 - index]`、状态条新文案、`pixels < 160`、
  以及「不再出现 `jumpTo(position.maxScrollExtent)`」。

## 验收证据

| 项 | 结果 |
| --- | --- |
| `node --test "test/*.test.js"`（插件） | **51/51 PASS** |
| `flutter test test/`（全量） | **361/361 PASS** |
| 存档离线复核 | 该会话 380 → 342 条事件，`Time sampled` / `Current runtime context` / `<system-reminder` 全部消失 |
| 磁盘日志复核 | 3252 行；447 条 assistant 中 9 条有正文、438 条纯推理 → 重读后只剩真实回复 |
| 产物字节数 | 72,655,282 |
| SHA256 | `1BE7856E9B16281CAA4F0A09BC55F5806345E05F861C25483C357300B389CAB6` |
| aapt2 badging | `versionCode='43' versionName='0.4.16-m4.16'`，targetSdk 36 |
| 三处发布 | `dist\DeepSeek-Remote-AI-v0.4.16-m4.16.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.16-m4.16.apk` 同哈希 |
| `GET /api/v1/app/version` | `{"versionCode":43,"versionName":"0.4.16-m4.16","size":72655282,"sha256":"1be7856e…"}` |

## 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"   # 是它下面的子目录
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"

# 中文路径下 AOT 快照会挂，先复制到 ASCII 目录；robocopy exit=1 = 已复制文件 = 成功
robocopy "<项目根>\app" C:\Users\user\dsh-tools\build\dsh-app `
  /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml

cd C:\Users\user\dsh-tools\build\dsh-app
flutter build apk --release
```

## 限制与下一步候选

- **插件 0.2.22 要完整退出重开 DSH 才生效**。这次 `plugin_manager set_bundle(enabled=false)`
  连试两次都被拒：`HMR transactions cannot be nested`；`/api/v1/health` 至今仍是 `0.2.21`。
  在重开之前，手机端只能靠 App 自己的过滤兜底（注入不会显示，但旧存档里的英文推理还在）。
- 手机端 43 版 APK 装好后**要重新配对**：cloudflared 是快速隧道，域名每次重启都变
  （当前 `https://<公网隧道>.trycloudflare.com`，配对码见 `/api/v1/pair/info`）。
  长期方案仍是给插件配固定 `config.publicUrl`。
- 存档里「推理被存成 assistant 文本」这件事，只能靠重读磁盘日志解决；日志被系统清理掉的
  老会话洗不回来，会保留少量英文片段。
- 真机锁屏/后台的授权提醒仍未做（M4.14 只做到「待应答 N 胶囊 + 接管窗口 10 分钟」）。
- `tools\verify-plugin-m4.ps1` 在 Windows PowerShell 5.1 下仍解析报 15 个 syntax error，未重写。
- 「在项目里新建会话」仍是用户 M4.13 时说的「以后再说」。
- 本次踩坑记录：不要用 `(Get-Content -Raw) -replace … | Set-Content` 改含中文的 UTF-8 文件 ——
  PS 5.1 按 GBK 解码会双编码乱码，还会吞掉行尾换行（`pubspec.yaml` 的 `publish_to`、
  `package.json` 的 description 收尾引号就是这样坏的）。要么用 read/edit/write 工具，要么用 node。
