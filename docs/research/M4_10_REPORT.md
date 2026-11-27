# M4.10 报告：会话存档——电脑列表里消失的会话，手机端还能看

## 1. 一句话结论

DSH 重启后旧会话从列表里整条消失，用户在手机上「看不到所有的项目了」。查下来**会话文件全在磁盘上**，问题出在 DSH 的 JSONL 后端只认「已物化」的日志；插件 0.2.14 起自己维护一份会话存档（`session-archive.json`），手机端于是能把「以前跑过、电脑上已经看不到」的会话以「已存档」只读直播的形式显示出来（App 0.4.10+37）。

## 2. 起因与根因

| 现象（用户反馈） | 根因 | 修法 |
|---|---|---|
| 「为什么又看不到所有的项目了」：重启后工作区页只剩 1 条会话 | `~/.dsh/sessions/` 下 246 个会话都在，但非当前会话的日志只有一个 227 字节的 header 行；`dsh-session-persistence-jsonl` 的 `list()` → `resolveGenerationInDirectory` → `readGenerationHeader`（`lib/index.js:3147`）在「只有 header、没有事件批次」时返回 `undefined`，整条会话从 `sessions.list()` 里消失 | 不修 DSH（属于 Host 内部行为），插件侧另存一份存档，手机端自己展示 |
| 手机端完全没有兜底 | App 只显示 `GET /desktop/tasks` 的结果，电脑没了就什么都不剩 | 新增存档接口 + 手机端「已存档」分组与只读直播 |
| `GET /desktop/sessions/:id/events` 对旧会话 404 | Host 的 `sessions.get()` 同样看不到未物化会话 | 存档详情接口 `GET /desktop/archive/sessions/:id` 直接读存档，不依赖 Host |
| 压缩日志读不出来 | `zlib.zstdDecompressSync` 只解第一帧（实测 1.4 MB 日志只出 227 字节） | 移植 DSH 的帧扫描（magic `0xFD2FB528` + 帧描述符 + block header），逐帧 `zstdDecompressSync(buffer.subarray(start, end))` |

## 3. 电脑端插件（0.2.14）

- `lib/index.js`
  - 新增 `// ---- M4.10 会话存档 ----` 整段：
    - 常量：`ARCHIVE_FILE = join(stateDir, 'session-archive.json')`、`ARCHIVE_VERSION = 1`、`ARCHIVE_INTERVAL_MS = 30_000`、`ARCHIVE_MAX_EVENTS = 1500`、`ARCHIVE_TEXT_MAX = 4000`、`ARCHIVE_RECORD_MAX = 400`。
    - `archiveEvent(event)`：`user/message` → `contentText(...)`，`assistant/message` → `assistantText(...)`，`turn/start`、`turn/end`（带 `reason`）。
    - `absorbLiveSession(session)`：运行中的会话每轮把日志吸进存档（`source: 'live'`）。
    - `splitZstdFrames(buffer)` / `readSessionLogText(file)` / `archiveFromLogFile(id, file)`：从磁盘 `session.v4.jsonl.zstd` 恢复（`source: 'disk'`），标题回退第一条用户消息前 40 字。
    - `dshSessionsRoot()`：`config.sessionsDir`，否则 `<dshHome>/sessions`。
    - `scanSessionsOnDisk({ force })`：30 秒节流，只补存档里还没有的会话。
    - `refreshSessionArchive({ scan })` / `listArchivedSessions()`（去掉 events，带 `eventCount`）/ `getArchivedSession(id)` / `saveArchivedSession(input)`。
    - `startSessionArchive()`（读文件 → 立即刷新 → `setInterval(30s)`，并 `unref()`）/ `stopSessionArchive()`。
  - 生命周期：`shutdown()` 先 `stopSessionArchive()`；`ctx.effect` 在 supervisor 启动之后 `startSessionArchive()`。
  - pageContext 增加 `archivedSessions`、`archivedSession`、`saveArchivedSession`。
  - `import { zstdDecompressSync } from 'node:zlib'`、`readdirSync`。
- `lib/server.js` 新增三条路由（均 Bearer/?token 鉴权）：
  - `GET /api/v1/desktop/archive/sessions` → `{sessions}`；无能力 501 `ARCHIVE_UNAVAILABLE`，异常 500 `ARCHIVE_FAILED`。
  - `GET /api/v1/desktop/archive/sessions/:id` → `{sessionId, running:false, lastSeq, events}`；没有 404 `ARCHIVE_NOT_FOUND`。
  - `POST /api/v1/desktop/archive/sessions` → `{ok, saved}`；失败 400 `ARCHIVE_SAVE_FAILED`（手机端补传用）。
- `package.json` → **0.2.14**，`node --test 'test/*.test.js'` **15/15**。

## 4. 手机端改动

- `app/lib/services/history_api.dart`
  - 新增 `class ArchivedSession { id, title, workspace, source, createdAt, lastTime, messageCount, eventCount, archivedAt; bool get fromDisk }`。
  - 新增 `archivedSessions(baseUrl, {token})`、`archivedSession(baseUrl, {token, sessionId})`、`postArchivedSession(baseUrl, {token, session, events})`。
- `app/lib/data/live_store.dart`
  - 状态：`_archivedSessions`、`_archiveLoading`、`_archiveError`、`_archiveUnavailable`。
  - getter：`archivedSessions`、`hiddenArchivedSessions`（电脑列表里已经没有的那些）、`archiveLoading`、`archiveError`。
  - 方法：`loadArchivedSessions()`（404/501 静默降级，旧插件不报错）、`fetchArchivedSession()`、`uploadArchivedSession()`。
- `app/lib/screens/desktop_session_screen.dart`
  - 新增 `archived` 参数：存档页**不轮询**，`_load()` 走 `fetchArchivedSession`。
  - AppBar 标题旁加「已存档」标记；底部把输入条/附件条换成一行说明「这是电脑端存档的会话，只能看不能继续发指令」。
- `app/lib/screens/tasks_screen.dart` / `workspace_screen.dart`
  - 列表底部新增分组「以前跑过、电脑上已经看不到的会话（N）」，卡片带「已存档」与「最后活动 X」。
  - 工作区页下拉刷新同时刷新任务与存档。
- 新增 `app/test/archive_m4_10_test.dart`（6 例）：存档列表解析、存档详情事件、POST body 形状、任务页能看到存档组并点进只读直播、同 id 不重复显示、存档页不轮询且没有输入框。

## 5. 验收证据

| 项 | 结果 |
|---|---|
| `flutter test` | **321/321 全部通过**（315 + M4.10 新增 6） |
| `flutter analyze` | **23 issues，0 error**（均为历史 warning/info） |
| 插件单测 | `node --test 'test/*.test.js'` **15/15** |
| 语法检查 | `node --check lib/index.js`、`lib/server.js` 均通过 |
| release APK | **72,343,942 字节**，SHA256 `29153E7E779615B1CFA68515DF726C3435DEEE86FDFEBA1D8A54C65C657A03D5` |
| APK 版本 | aapt2：`versionCode='37' versionName='0.4.10-m4.10'`，minSdk 24、targetSdk 36 |
| APK 签名 | `CN=Android Debug`，SHA-256 `341ef83b95f452bb50b5a6821aa2044334826971e27910d428abc5dab33f70d6`（与旧包一致，可覆盖安装） |
| 发布 | `dist\DeepSeek-Remote-AI-v0.4.10-m4.10.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.10-m4.10.apk`（三者同源） |
| 更新接口 | `GET /api/v1/app/version` → `{"versionCode":37,"versionName":"0.4.10-m4.10","size":72343942,...}` |
| 验证脚本 | `tools/verify-plugin-m4.ps1` 门槛升到 0.2.14，新增「GET /desktop/archive/sessions 有会话存档（M4.10）」，共 **14 项** |

## 6. 生效步骤

1. **完整退出 DSH 桌面应用再打开**（加载插件 0.2.14）。重开后插件会在 30 秒内生成 `C:\Users\user\.dsh\dsh-plugin-m1\session-archive.json`，并把磁盘上缺失的会话补进来。
2. 跑自检：`powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-plugin-m4.ps1`，期望 **14/14 PASS**（`-NoCreate` 只跑只读项）。
3. 手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.10-m4.10 / versionCode 37，可覆盖安装），重新配对。
4. 打开「工作区」页，滚到底应看到「以前跑过、电脑上已经看不到的会话」，点开是只读直播。
5. （可选）把磁盘上另外导出的一份历史补进存档：`node C:\Users\user\dsh-build\session-restore.js --upload`。

## 7. 已知限制与下一步

- 存档**只能看不能继续发指令**：电脑那边已经没有这条会话，回复不了。
- 磁盘扫描只补存档里没有的会话；单会话最多 1500 条事件、正文每段截断 4000 字，最多保留 400 条会话。
- 需要电脑端插件 **0.2.14+**；旧插件存档接口 404，手机端静默不显示这一组（不报错）。
- `session-archive.json` 要等 DSH 重开之后才会生成（首次最多 30 秒）。
- 本次仍未真机复测（`adb devices` 无设备），只读直播页与存档分组由单测覆盖。
- 下一步候选：① 存档「恢复成新会话」（把存档内容作为上下文开一个新会话接着聊）；② 存档按工作区分页加载（现在一次全拉）；③ 在「我的」页显示存档占用与清理入口。

## 8. 证据索引

- 插件：`dsh-plugin-m1/lib/index.js`（会话存档整段：`archiveEvent` / `absorbLiveSession` / `splitZstdFrames` / `readSessionLogText` / `archiveFromLogFile` / `scanSessionsOnDisk` / `startSessionArchive` / `saveArchivedSession`）、`dsh-plugin-m1/lib/server.js`（三条 `/desktop/archive/sessions` 路由）、`dsh-plugin-m1/package.json`（0.2.14）。
- 手机端：`app/lib/services/history_api.dart`（`ArchivedSession` + 3 个方法）、`app/lib/data/live_store.dart`（`archivedSessions` / `hiddenArchivedSessions` / `loadArchivedSessions`）、`app/lib/screens/desktop_session_screen.dart`（`archived`）、`app/lib/screens/tasks_screen.dart`（`_ArchivedCard`）、`app/lib/screens/workspace_screen.dart`（`_ArchivedSessionCard`）、`app/test/archive_m4_10_test.dart`。
- 取证脚本（不随项目交付）：`C:\Users\user\dsh-build\zstd-frames.js`、`session-index.js`、`session-restore.js`、`grep-asar.js`、`read-asar.js`。
- 验收：`flutter test` 321/321、`flutter analyze` 23 issues/0 error、`node --test` 15/15、`tools/verify-plugin-m4.ps1`（14 项）。
- 产物：`dist/DeepSeek-Remote-AI-v0.4.10-m4.10.apk`（72,343,942 字节）。

## 9. M4.11 补丁：授权根懒解析 + 附件落盘目录

M4.10 交付后发现两处「列表里有、真去用却没有」的问题，在 0.2.17 / 0.2.18 里修掉（App 无需改动）。

### 9.1 `file/raw` 报 `workspace not authorized`

- 根因：`const workspaceRoots = resolveWorkspaceRoots(config, ctx)` 在插件 `apply` 阶段执行一次就永久缓存。`workspaceRegistry` 是异步 Service（`[Service.init]` 之后才 active），挂载时取不到 → 退回 `[homedir()]`。手机端列表来自 `listDesktopWorkspaces()`（授权根 ∪ 会话 cwd），于是「列表里有 `<项目根>`，点开却说没授权」。
- 修法：`workspaceRootsNow()` 带 5 秒 TTL 的懒解析，所有读取点改用它；`rootsFromRegistry()` 兼容 `list()/all()/snapshot()`、数组 / `{workspaces}` / `entities` Map、字符串或 `path/cwd` 字段；`resolveWorkspaceFile()` 用 `canonicalPath()` 归一化比较，并额外接受当前会话 cwd 与注册表目录。
- 实测：重启后 `GET /desktop/file/raw?workspace=<项目根>&path=README.md` → **200 / 63158 字节**（此前恒 400）。
- 回归测试：`test/workspace-roots.test.js`（6 例）、`test/workspace-roots-lazy.test.js`（3 例，断言顶层不再缓存、读取点全走 `workspaceRootsNow()`）。

### 9.2 附件没有落到工作区

- 现象：`POST /desktop/upload` 带了 `workspace`，文件仍落在插件状态目录 `C:\Users\user\.dsh\dsh-plugin-m1\uploads\`。
- 根因：手机端传的是**工作区名**（路径末段，`assistant_screen.dart` 的 `_uploadWorkspace` → `_leafName`），而 `resolveUploadDir` 只在 `join(root, 名字)` 是同名子目录时才认。工作区恰好就是授权根本身时（`deepseek手机端` == `<项目根>`），这个子目录不存在 → 退回状态目录。
- 修法：`resolveUploadDir` 依次认「完整路径（归一化比较）」「末段名 == 授权根目录名」「root 下的同名子目录」，命中后 `mkdirSync(<工作区>\手机附件, { recursive: true })`；都认不出才退回会话 cwd，再退回状态目录。
- 回归测试：`test/upload-dir.test.js`（2 例，从源码截出函数体注入假 roots，用真实临时目录验证 7 种写法 + 断言不再退回状态目录）。

### 9.3 自检脚本判据修正

`tools/verify-plugin-m4.ps1` 之前 **9/13**，其中 3 项是脚本自己取值取错（不是插件坏）：`/desktop/workspaces` 返回的是 `{workspaces:[...]}` 却当成数组、`/desktop/tasks` 返回的是 `{tasks:[...]}` 却读 `.rows`。修正后 **12/13**，最后 1 项（附件落盘）即 9.2，已在 0.2.18 修掉。

「插件市场有索引兜底」改为**提示不判失败**：DSH 的 `pluginMarket` 没有 `defaultIndexUrl` API，`listIndexes()` 只回 Settings 里配的 URL。想在手机上看市场，需要在 profile 里给 `plugin-market` 配 `indexes`，例如：

```yaml
- id: plugin-market
  name: "@deepseek-ai/dsh-plugin-market"
  config:
    indexes:
      - https://cdn.jsdelivr.net/npm/dsh-plugin-catalog/index.json
```

### 9.4 版本与验收

| 项 | 结果 |
| --- | --- |
| 插件版本 | 0.2.17（授权根懒解析）→ **0.2.18**（附件落盘目录） |
| 插件单测 | `node --test 'test/*.test.js'` **26/26**（15 + 6 + 3 + 2） |
| 语法检查 | `node --check lib/index.js lib/server.js` 通过 |
| 现场验证 | `health` 0.2.17 / `workspaces` 9 个全部带 path / `file/raw` 200 / `archive` 141 条 0 空记录 |
| 自检脚本 | 判据修正后 12/13；附件一项待重开 DSH 加载 0.2.18 后复跑，期望 **13/13** |

