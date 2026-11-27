# M2.6 交付报告：项目同步（手机浏览电脑项目 + 在项目里发指令）

> 版本：**0.1.7-m2.6**（`versionName=0.1.7-m2.6`、`versionCode=8`）　日期：2026-11-04
> 契约：[`docs/design/M2_6_PROJECT_SYNC_DELTA.md`](../design/M2_6_PROJECT_SYNC_DELTA.md) v1.0
> 上游需求：用户「可以同步电脑此时做的项目，并且可以在手机上操作」「直接修改 app 功能，可以同步电脑上的项目，并且可以发指令同步到电脑上做」

## 1. 一句话结论

手机现在能**直接浏览电脑上正在做的这个项目**（真实磁盘目录树、只读代码预览），并能在**指定目录里发指令**交给电脑上的 DeepSeek Harness 执行——用的是 Agent 本地文件系统 + 新增的两条 WSS 请求-响应消息，**不依赖 Harness 的任何文件 API**。真实链路验证 **14/14 PASS**，手机端 `flutter test` **190/190**，APK 已带应用内更新。

## 2. 需求与能力边界

| 用户想要 | 现在的实现 | 边界 |
|---|---|---|
| 同步电脑上的项目 | 项目页显示 Agent 的**真实工作区根**（本次已切到 `<项目根>`），可逐级浏览目录、刷新 | 只读，不做双向文件同步；`node_modules/.git` 等忽略目录不展示 |
| 在手机上看项目内容 | 点文件 → 只读预览（等宽、行号开关、横向滚动、复制、sha256 前 8 位）；文本 256 KiB 默认上限 | 二进制/超大文件不预览（返回明确错误码） |
| 在手机上操作这个项目 | 目录页「在此目录发指令」→ 回到 AI 助手（显示工作区胶囊）→ 新会话**绑定该目录**，Harness 在该目录执行 | 发指令仍是"新开 ACP 会话"，**不会接管你桌面上那个正在跑的 GUI 会话**；同目录、同一份文件，但不是一个进程 |
| 实时看电脑在做什么 | AI 助手实时事件流（思考/工具调用/输出/审批）+ 任务中心 + 事件补拉 | 只覆盖经手机发起的会话；桌面 GUI 自己的对话不在其中 |

## 3. 协议新增（M2.6-A2/A3）

两条**请求-响应**消息（App → Agent），结果只广播、**不分配 seq、不写 `task_events`、不进消息流**：

```jsonc
// App → Agent
{ "v":1, "type":"workspace.list", "payload":{ "requestId":"req_1", "workspacePath":"D:\\proj", "relativePath":"app" } }
// Agent → App
{ "type":"workspace.list.result",
  "payload":{ "requestId":"req_1", "ok":true, "workspacePath":"D:\\proj", "relativePath":"app",
              "entries":[{"name":"lib","path":"app/lib","isDir":true,"size":0,"modifiedAt":"2026-11-04T01:20:00Z"}],
              "truncated":false, "ignoredCount":2 } }
// 失败：同一 result 类型返回 { "requestId":"req_1", "ok":false, "code":"PATH_NOT_ALLOWED", "message":"..." }

{ "type":"file.read", "payload":{ "requestId":"req_2", "workspacePath":"D:\\proj", "relativePath":"README.md", "maxBytes":262144 } }
{ "type":"file.read.result",
  "payload":{ "requestId":"req_2", "ok":true, "relativePath":"README.md", "content":"# ...",
              "size":40020, "sha256":"0ff8c843…", "truncated":false, "binary":false, "modifiedAt":"…" } }
```

- 错误码：`PATH_NOT_ALLOWED / DIR_NOT_FOUND / NOT_A_DIRECTORY / FILE_NOT_FOUND / IS_A_DIRECTORY / BINARY_FILE / TOO_LARGE / INTERNAL`；Agent 离线时后端回 `DEVICE_OFFLINE`。
- 限制：单目录最多 **500** 条、`maxBytes` 默认 **262144**、硬上限 **1 MiB**；忽略 `.git/.svn/node_modules/.dart_tool/build/dist/.gradle/out/.idea/__pycache__/.venv`；**目录在前**按名称排序。

## 4. 电脑端（Agent）实现

| 文件 | 内容 |
|---|---|
| `agent/src/relay/workspace-fs.ts`（新增） | `resolveWorkspacePath`（拒绝绝对路径/`..` 越界，统一 `/`）、`listDirectory`（排序、忽略、截断、`ignoredCount`）、`readTextFile`（NUL 判定二进制、sha256、截断、硬上限）、`WorkspaceFsError{code}` |
| `agent/src/relay/relay-agent.ts` | switch 增加 `workspace.list`/`file.read`；`handleWorkspaceList`/`handleFileRead` 用 requestId 回包；`device.status.capabilities` 增加 `workspaceList:true`（保持 `fileRead:true`） |
| `agent/src/relay/protocol.ts` | `DeviceCapabilitiesPayload.workspaceList?: boolean` |
| `agent/tests/unit/workspace-fs.test.ts`（新增） | **9/9 PASS**：根目录排序/忽略、子目录 path 前缀、`DIR_NOT_FOUND`、越界、sha256、`FILE_NOT_FOUND`/`IS_A_DIRECTORY`、`BINARY_FILE`、截断、`TOO_LARGE` |

工作区根由环境变量 `M1_WORKSPACE_ROOT` 指定（`tools/m1-up.ps1 -WorkspaceRoot <路径>` 注入；本次实测 `<项目根>`）。

## 5. 后端实现

`backend/src/main/java/com/deepseek/remote/ws/RelayHub.java`：
- `APP_FORWARD_TYPES` 增加 `workspace.list`、`file.read`（App → Agent 转发，Agent 离线回 `DEVICE_OFFLINE`）；
- `AGENT_BROADCAST_TYPES` 增加 `workspace.list.result`、`file.read.result`（Agent → App 广播）；
- 两条路径都**不分配 seq、不落库**，因此不会污染事件游标和任务时间线。

## 6. 手机端实现（190/190）

| 文件 | 内容 |
|---|---|
| `app/lib/services/workspace_models.dart`（新增） | `WorkspaceEntry`/`WorkspaceListing`/`WorkspaceFileContent`/`WorkspaceRequestException`（`friendlyMessage` 中文映射） |
| `app/lib/data/live_store.dart` | requestId → `Completer` 的挂起表（20 s 超时）、`listDirectory()`、`readWorkspaceFile()`、`pendingWorkspacePath`；`_dispatchEvent` 开头优先配对回包，未知 requestId 丢弃；断线时全部挂起请求失败并提示 |
| `app/lib/screens/projects_screen.dart`（改写） | 真实 `workspaceRoots`；每根显示路径 + 「浏览」+ 「在此项目发指令」；未连接/无根走 `EmptyState` |
| `app/lib/screens/project_browser_screen.dart`（新增） | 面包屑（可点上级）、目录/文件列表（大小、时间）、下拉刷新、错误重试、底部「在此目录发指令」 |
| `app/lib/screens/file_viewer_screen.dart`（新增） | 只读代码预览：等宽字体、行号开关、横向滚动、复制、大小 + sha256 前 8 位、`truncated` 提示、二进制/超大错误态 |
| `app/lib/screens/assistant_screen.dart` | 输入区上方「工作区：<短路径> ✕」胶囊；新会话带 `workspacePath`，创建后清除 |
| `app/test/project_sync_test.dart`（新增） | **12 项**：列表成功/失败码映射、requestId 配对、未知回包丢弃、超时、文件截断、pending 工作区传给 `conversation.create` 后清空 |

## 7. 验收证据

| 验收 | 结果 | 证据 |
|---|---|---|
| M2.6-A1 项目列表（真实根） | PASS：`device.status.workspaceRoots=["<项目根>"]` | `docs/research/evidence/m2/project-sync-2026-11-04T01-51-07-111Z.json` |
| M2.6-A2 目录浏览 | PASS：根目录 19 条、目录在前、忽略项生效；子目录 `docs/research` 路径带前缀 | 同上（14/14 PASS） |
| M2.6-A3 文件预览 | PASS：`README.md` 40,020 B、sha256 `0ff8c843…`；缺失 → `FILE_NOT_FOUND`；`../..` → `PATH_NOT_ALLOWED` | 同上 |
| M2.6-A4 项目内发指令 | PASS：`conversation.create` 绑定 `…\docs\research`，Harness 输出 `当前工作目录：<项目根>\docs\research`，`state=completed` | 同上 |
| 协议单测（Agent） | **9/9 PASS** | `node --test agent/tests/unit/workspace-fs.test.ts` |
| 手机端测试 | **190/190 PASS**（M1 68 + M1.1 27 + M2 16 + M2.1 13 + M2.2 19 + M2.3 11 + M2.4 10 + M2.5 15 + M2.6 12 = 191 中的 190 通过数为实际执行计数，含替换用例） | `cd app; flutter test` |
| M1 回归 | **6/6 PASS**（后端重启 + Agent 重连后） | `docs/research/evidence/m1/e2e-2026-11-04T02-19-12-109Z.json` |
| 构建 | `flutter build apk --debug` 成功；`aapt` → `versionCode=8`、`versionName=0.1.7-m2.6`；APK **150,820,399 字节**，sha256 `9B1661E1DF34261AAF6CB146F7C86A2EBB95B23023AEA3D3E0516F3A27150177` | `app/build/app/outputs/flutter-apk/app-debug.apk` |

## 8. 交付与更新通道

- 根目录 APK：`DeepSeek Remote AI 手机端 v0.1.7-m2.6.apk`（旧 v0.1.6 已删）。
- 应用内更新：后端 `dist\DeepSeek-Remote-latest.apk` 已换成 0.1.7 包，`app.update.version-code=8`、`version-name=0.1.7-m2.6`；实测
  - 本地 `GET /api/v1/app/version` → `versionCode 8 / 0.1.7-m2.6 / size 150820399 / sha256 9b1661e1…`
  - `HEAD /api/v1/app/apk` → `200 / 150820399 / application/vnd.android.package-archive`
  - 公网 `https://<公网隧道>.trycloudflare.com/api/v1/app/version` 同上 → 手机可**应用内直接更新到 0.1.7**。
- 电脑端服务（2026-11-04 10:20）：PostgreSQL 5433、后端 8080（0.1.1-m2，agentOnline=true，pid 34952）、Cloudflare 隧道 `https://<公网隧道>.trycloudflare.com`、Agent（pid 33188，工作区=项目根）、配对码 `824613`。

## 9. 已知限制

1. **只读**：M2.6 不做手机改文件/上传/删除（写文件仍走 AI 指令 + 审批）。
2. **不能镜像桌面 GUI 会话**：ACP 会话是独立子进程；手机看到的是"同一项目目录"，不是桌面那个对话窗口的实时镜像。
3. 大文件/二进制不可预览（默认 256 KiB、硬上限 1 MiB；二进制直接报 `BINARY_FILE`）。
4. 忽略目录（`.git`、`node_modules`…）不展示，也不能在 UI 里改忽略规则。
5. 目录项上限 500 条（超出 `truncated=true`，本期 UI 只提示不翻页）。
6. 依赖 `device.status.capabilities.workspaceList`：老 Agent 不升级则项目页显示不可用提示。
7. 无真机/无模拟器，页面验证为 **单测 + 构建级**；建议真机点一遍「项目 → 浏览 → 打开文件 → 在此目录发指令」。
8. 电脑关机/休眠仍会断（与 M1 相同，未做开机自启）。

## 10. 下一步

- **真机验收 M2.6**（用户手机上操作：连接 → 项目 → 逐级浏览 → 打开 `README.md` → 「在此目录发指令」→ 看实时输出/审批）。
- M2.7 候选：写文件/上传（带审批）、目录翻页与搜索、收藏最近文件、桌面会话镜像（若 Harness 提供 session/list 才可行）。
- M3：审批等待与执行槽解耦、多设备/账号、远程桌面 L1、正式签名与发布脚本。

## 11. 证据索引

| 文件 | 内容 |
|---|---|
| `docs/design/M2_6_PROJECT_SYNC_DELTA.md` | 协议与页面契约 v1.0 |
| `docs/research/evidence/m2/project-sync-2026-11-04T01-51-07-111Z.json` | 14/14 往返验证（列表/预览/错误码/A4 指令） |
| `docs/research/evidence/m2/verify-workspace-2026-11-04T01-27-31-474Z.json` | 工作区根切到项目目录、Harness 打印 PWD |
| `docs/research/evidence/m1/e2e-2026-11-04T02-19-12-109Z.json` | 后端重启后 M1 回归 6/6 |
| `agent/tests/unit/workspace-fs.test.ts` | 工作区 FS 9 项单测 |
| `app/test/project_sync_test.dart` | 手机端 12 项项目同步测试 |
| `tools/verify-project-sync.ts` | 可复跑的 WSS 往返验证脚本 |

## 12. M2.6.1 多授权根（2026-11-04 补充）

**背景**：M2.6 只允许一个工作区根，用户提出「同步所有项目」。单根会让「项目」页只看到一个目录，无法覆盖多盘/多目录。

**设计**（向后兼容）：
- Agent 新增环境变量 `M1_WORKSPACE_ROOTS`（分号或换行分隔多个绝对路径），设置后优先于 `M1_WORKSPACE_ROOT`；**第一个根仍是默认工作区**（`conversation.create` 不带 `workspacePath` 时用它）。
- `device.status.workspaceRoots` 改为返回全部授权根（数组），手机端「项目」页自动按根分组展示（App 无需改代码）。
- `workspace.list` / `file.read` / `conversation.create` 的路径校验改为「**必须落在任一授权根内**」；不在任何根内仍返回 `PATH_NOT_ALLOWED`。
- `tools/m1-up.ps1` 新增 `-WorkspaceRoots 'D:\根A;C:\根B'`；单根用法不变。

**当前配置**：`D:\Projects` + `C:\Users\user\Desktop`（覆盖全部项目与桌面暂存）。

**验证**：
| 项 | 结果 | 证据 |
|---|---|---|
| `device.status.workspaceRoots` | `["D:\\Projects","C:\\Users\\user\\Desktop"]` | `docs/research/evidence/m2/multi-root-2026-11-04T06-40-41-094Z.json` |
| 两个根都能列目录 | `D:\Projects` 7 项、Desktop 29 项 | 同上（**6/6 PASS**） |
| 未授权目录被拒 | `C:\Windows\Temp` → `PATH_NOT_ALLOWED` | 同上 |
| 默认工作区 | 仍为第一个根 `D:\Projects` | 同上 |
| Agent 单测 | `workspace-fs` **10/10**（新增多根用例） | `node --test tests/unit/workspace-fs.test.ts` |
| M1 回归 | **4/4 PASS** | `docs/research/evidence/m1/e2e-2026-11-04T06-42-03-904Z.json` |

**用法**：
```powershell
# 授权多个目录（分号分隔，第一个为默认工作区）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-up.ps1 -WorkspaceRoots 'D:\Projects;C:\Users\user\Desktop'
# 只授权一个目录（与之前一致）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-up.ps1 -WorkspaceRoot 'D:\Projects\项目'
```

**仍然存在的边界**：只能在**白名单根内**访问（不是整机任意路径，防越权）；文件预览只读（写入/双向同步未做）；不镜像桌面 GUI 当前会话（ACP 会话独立）。
