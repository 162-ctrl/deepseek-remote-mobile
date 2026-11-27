# M4.57 功能页新增「接收文件」：电脑端发来的文件，手机上点开就能看

**一句话**：手机「功能」页多了一行「接收文件」，电脑端（或 AI）把做好的文件放进插件的
`received/` 目录，手机就能按修改时间倒序列出来并打开——图片能放大、`.docx` 能按文字读、
`.md/.txt` 直接看正文，其它交给系统应用。App `0.4.57+78`、插件 `0.2.42`。

## 之前的问题

用户要的是「我想看做好的文件，我让你发你就发到那，我可以查看」。原来的路都不顺：

| 情况 | 原来的体验 |
|---|---|
| AI 在某个工作区里写了个文件 | 得自己进「工作区 → 该目录 → 浏览文件」，一层层找 |
| 文件不在任何授权根里（比如临时目录、DSH 自己的目录） | 手机端根本看不到 |
| 聊天里贴路径 | 手机打不开，只能回电脑上找 |
| 我直接发附件 | 附件是「手机 → 电脑」方向，反方向没有通道 |

## 改动

| 位置 | 改动 |
|---|---|
| `dsh-plugin-m1/lib/index.js` | 新增 `receivedDir = <stateDir>/received`（启动时自建）；`listReceivedFiles()` 按 `mtime` 倒序、跳过隐藏文件与子目录、最多 200 条；`resolveReceivedFile(name)` 只取 `basename` 并拒掉 `.`/`..`/隐藏名，防目录穿越；`deleteReceivedFile(name)`；三件事挂进 `pageContext`（`receivedFiles` / `receivedFile` / `deleteReceivedFile`） |
| `dsh-plugin-m1/lib/server.js` | `GET /api/v1/received`（列表）、`GET /api/v1/received/<name>`（字节流，`application/octet-stream`、`no-store`）、`DELETE /api/v1/received/<name>`（清理）；都要 app token，未知文件 404 `NOT_FOUND`，方法不对 405 |
| `app/lib/services/history_api.dart` | 新增 `ReceivedFile{name,size,updatedAt}` 与 `listReceivedFiles()` / `downloadReceivedFile(name)`（沿用 `downloadWorkspaceFile` 的流式下载与错误包装） |
| `app/lib/data/live_store.dart` | `loadReceivedFiles()` / `downloadReceivedFile(name)`，走 `_withAuthRetry` |
| `app/lib/screens/file_viewer_screen.dart` | 新增 `fetchBytes` 来源：设置后不读工作区，字节直接来自回调；`.md/.txt` 等文本在本地按 UTF-8 解；接收文件只读（`_canEdit` 关闭）；`workspacePath`/`relativePath` 改为可选 |
| `app/lib/screens/received_files_screen.dart` | 新页面：列表（图标按扩展名、大小、相对时间）、下拉刷新、点开进文件预览、空态与错误重试 |
| `app/lib/screens/features_screen.dart` | 「功能」页新增一行「接收文件」，副标题按连接状态变化 |

## 怎么「发文件」给它

AI（或用户自己）把文件复制进插件状态目录的 `received/`：

```
<DSH 数据目录>\dsh-plugin-m1\received\
```

手机端下一次打开「功能 → 接收文件」或下拉刷新就能看到。文件名就是手机上的显示名，
中文、空格都可以（下载时会 URL 编码）。

## 验收

- App 新增 `test/received_files_m4_57_test.dart` 3 例：列表按服务端顺序显示、点开进入
  `FileViewerScreen` 并按文本预览（`# 报告 / 正文第一行 / 正文第二行`）、空态一句
  「还没有收到文件」、读不到时显示原因且点「重试」会重新拉取。全量 `flutter test` **530/530**。
- 插件新增 `test/received-files-route.test.js` 6 例（列表、401、下载字节、404、删除、
  `index.js` 的 `pageContext` 接线与 `basename` 防穿越）与 `test/received-files.test.js`
  4 例（倒序+跳过隐藏与子目录、上限 200、解析拒绝 `..`/隐藏/目录、删除只动目标文件）。
  插件全量 `node --test 'test\*.test.js'` **176/176**。
- 反证：把 `resolveReceivedFile` 的 `const safe = basename(...)` 临时换成
  `const safe = String(name ?? '').trim()` → 穿越用例失败；恢复后 10/10。

## 交付

| 项 | 值 |
|---|---|
| App | `0.4.57+78` / `0.4.57-m4.57` |
| APK | `dist/DeepSeek-Remote-latest.apk`（debug 签名，可覆盖安装） |
| 插件 | `0.2.42`（需要热载 / 重开 DSH 才生效） |

## 限制与下一步

- 接收目录是**单向**的：手机只能看、不能删改回写；删除接口留给电脑端清理，App 暂未暴露。
- 只读一层目录，不进子目录；隐藏文件与子目录跳过。
- 文件多到 200 个以后，更早的不会显示——需要时清掉旧文件。
- 老插件（< 0.2.42）没有 `/api/v1/received`，页面会显示「读不到接收文件」并说明原因。
- 提问卡「提交后 404」的排查还没收口（M4.56 遗留），下一步继续。
