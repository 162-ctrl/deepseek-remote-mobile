# M2.6 项目同步（Project Sync）增量契约 v1.0

> 目标：手机端能**看到电脑上正在做的项目文件**（目录树 + 文件内容），并能**把指令发给电脑执行**（在同一项目目录里跑 Harness）。
> 唯一依据；实现方不得偏离本文件的接口名、字段名与错误码。

## 1. 范围

| 编号 | 能力 | 说明 |
|---|---|---|
| A1 | 项目列表 | 手机「项目」页展示 Agent 上报的真实工作区根（`device.status.workspaceRoots`），不再有演示数据 |
| A2 | 目录浏览 | 手机可以逐级浏览工作区内的目录（懒加载），隐藏 VCS/依赖/构建目录 |
| A3 | 文件预览 | 手机可以打开文本文件查看内容（只读、限大小、显示大小与修改时间） |
| A4 | 项目内发指令 | 从项目页可以「在此项目执行指令」，会话绑定该工作区目录，AI 读写的就是电脑上的真实项目 |
| A5 | 真实链路回归 | M1 E2E 6/6 仍通过；新增 WSS 往返时延与错误路径有测试 |

**非目标**：手机端编辑/保存文件（后续 M2.7）；文件上传/下载；二进制预览；桌面 GUI 会话镜像。

## 2. WSS 协议（App ↔ 后端 ↔ Agent）

沿用现有信封 `{v,type,id,ts,payload}`。新增 4 种 type，全部**不参与** conversation seq / task_events 落库（不是会话事件）。

### 2.1 `workspace.list`（App → Agent）

```json
{ "v":1, "type":"workspace.list", "id":"req_...", "ts":"...",
  "payload": { "requestId":"rq_abc", "workspacePath":"D:\\proj", "relativePath":"" } }
```

- `requestId`：App 生成，回包原样带回（字符串，≤64）。
- `workspacePath`：必须是 `device.status.workspaceRoots` 之一，且落在 `M1_WORKSPACE_ROOT` 内；否则 `PATH_NOT_ALLOWED`。
- `relativePath`：相对工作区根的路径，空 = 根目录；不允许绝对路径或 `..` 越界。

### 2.2 `workspace.list.result`（Agent → App）

```json
{ "type":"workspace.list.result",
  "payload": { "requestId":"rq_abc", "ok":true, "workspacePath":"D:\\proj", "relativePath":"app",
    "entries":[ { "name":"lib", "path":"app/lib", "isDir":true, "size":0, "modifiedAt":"2026-11-04T09:00:00.000Z" } ],
    "truncated":false, "ignoredCount":2 } }
```

失败：`{ "requestId":"rq_abc", "ok":false, "code":"PATH_NOT_ALLOWED", "message":"..." }`。
错误码：`PATH_NOT_ALLOWED` / `DIR_NOT_FOUND` / `NOT_A_DIRECTORY` / `INTERNAL`。
排序：目录在前、名称升序（不区分大小写）。最多 500 条，超出置 `truncated=true`。
忽略目录（不返回、计入 `ignoredCount`）：`.git` `.svn` `node_modules` `.dart_tool` `build` `dist` `.gradle` `out` `.idea` `__pycache__` `.venv`。

### 2.3 `file.read`（App → Agent）

```json
{ "type":"file.read", "payload": { "requestId":"rq_def", "workspacePath":"D:\\proj",
  "relativePath":"app/pubspec.yaml", "maxBytes":262144 } }
```

### 2.4 `file.read.result`（Agent → App）

```json
{ "type":"file.read.result",
  "payload": { "requestId":"rq_def", "ok":true, "relativePath":"app/pubspec.yaml",
    "content":"name: deepseek_remote_app\n...", "size":1024, "sha256":"<hex>",
    "truncated":false, "binary":false, "modifiedAt":"..." } }
```

- 默认 `maxBytes` 262144，硬上限 1 MiB；超出截断并 `truncated=true`。
- 二进制文件（前 8KB 含 NUL 字节）返回 `ok:false, code:"BINARY_FILE"`。
- 错误码：`PATH_NOT_ALLOWED` / `FILE_NOT_FOUND` / `IS_A_DIRECTORY` / `BINARY_FILE` / `TOO_LARGE` / `INTERNAL`。

### 2.5 后端职责

- `APP_FORWARD_TYPES` 增加 `workspace.list`、`file.read`；Agent 离线时回 `error{code:"DEVICE_OFFLINE"}`。
- `AGENT_BROADCAST_TYPES` 增加 `workspace.list.result`、`file.read.result`；**只广播，不分配 seq、不写 task_events**。
- 其他逻辑不变（鉴权、配对、M2.1 事件表）。

### 2.6 Agent 能力上报

`device.status.capabilities` 增加 `workspaceList:true`、`fileRead:true`（`fileWrite` 仍为 false）。旧客户端不识别新字段时不受影响。

## 3. 手机端（Flutter）

### 3.1 LiveStore 新增 API（供页面调用）

```dart
List<String> get workspaceRoots;              // 来自 device.status
Future<WorkspaceListing> listDirectory(String workspacePath, String relativePath);
Future<WorkspaceFileContent> readWorkspaceFile(String workspacePath, String relativePath);
void setPendingWorkspace(String? workspacePath); // 下一个新会话绑定到该工作区
String? get pendingWorkspacePath;
```

- 请求：单条 WSS `send(type,payload)` + `requestId`，15s 超时 → 抛 `WorkspaceRequestException(code, message)`；未连接抛 `code="OFFLINE"`。
- 数据类：`WorkspaceEntry{name,path,isDir,size,modifiedAt}`、`WorkspaceListing{entries,truncated,ignoredCount}`、`WorkspaceFileContent{content,size,sha256,truncated,binary}`。
- `createConversation` 若 `pendingWorkspacePath != null` 则 payload 带 `workspacePath`，成功后清空。
- `_dispatchEvent` 中把 `workspace.list.result` / `file.read.result` 交给 pending request 表（按 `requestId`），不进入消息流/任务时间线。

### 3.2 页面

- `projects_screen.dart`（重写）：标题「项目」；无连接 → `EmptyState`（引导连接）；已连接 → 每个 workspaceRoot 一张卡（路径、Agent/权限摘要可选），点击进入浏览页；卡片右侧「在此项目执行指令」按钮（见 A4）。
- 新增 `project_browser_screen.dart`：面包屑（相对路径分段，可点回上级）+ 目录列表（目录在前，图标/大小/修改时间）+ 文件点击进入预览 + 下拉刷新 + 错误态与重试。
- 新增 `file_viewer_screen.dart`：只读文本视图（等宽、可横向滚动、行内不折行）+ 顶部文件名/大小/修改时间 + 复制全部 + `binary`/`truncated` 提示。
- A4 交互：项目卡或浏览页内「让 AI 在此项目执行指令」→ 调 `setPendingWorkspace(root)` → 切到「AI 助手」Tab → 输入框上方显示可移除的「项目：<目录名>」胶囊，发送时新会话带该工作区。

### 3.3 约束

- 只改 `app/`、`agent/`、`backend/` 与 `docs/`；零新增 pub 依赖；不引入代码高亮库（纯等宽文本）；禁用 `flutter analyze`（中文路径）。
- 文案中文；错误提示要可行动（例如「电脑端未连接」「没有权限访问该路径」）。

## 4. 验收

| 编号 | 验收方式 |
|---|---|
| A1 | 手机连接后项目页显示 `<项目根>`；无演示数据 |
| A2 | WSS 实测 `workspace.list` 根/子目录返回真实条目（含 `app`、`backend`、`agent`） |
| A3 | WSS 实测 `file.read app/pubspec.yaml` 返回 `version: 0.1.6+7` 且 sha256 与本地一致 |
| A4 | 从项目页发起会话后，`conversation.created.workspacePath` = 该项目目录；prompt 能读写该项目（实测） |
| A5 | `node tools/m1-client.ts` 6/6 PASS；新增 `tools/verify-project-sync.ts` PASS；`flutter test` 全绿；后端 `gradle build` 成功 |

## 5. 交付物

- `agent/src/relay/workspace-fs.ts` + relay 消息处理 + 单测
- `backend/.../ws/RelayHub.java` 白名单/广播改动
- `app/lib/services/relay_client.dart`（请求/响应）、`app/lib/data/live_store.dart`、三页 UI、测试
- `tools/verify-project-sync.ts`、`docs/research/M2_6_REPORT.md`、README/PROJECT_STATUS 更新
- APK `0.1.7+8` / `versionName 0.1.7-m2.6`
