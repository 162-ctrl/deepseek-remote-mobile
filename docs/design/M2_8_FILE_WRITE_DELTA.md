# M2.8 手机端写入（File Write）增量契约 v1.0

> 目标：手机端不再只是「看」项目——可以在授权目录里**新建文件、编辑并保存文本文件**，
> 保存前必须经过手机上的**人工确认（一次性审批）**，电脑端 Agent 再做独立校验。
> 唯一依据；实现方不得偏离本文件的接口名、字段名与错误码。

## 1. 范围

| 编号 | 能力 | 说明 |
|---|---|---|
| W1 | 编辑保存 | 手机打开工作区文本文件 → 编辑 → 确认 → 原子写回电脑 |
| W2 | 新建文件 | 在手机浏览到的目录里新建文本文件（父目录必须已存在） |
| W3 | 冲突保护 | 打开时记住 `sha256`；保存前电脑上的文件若被改动则拒绝写并提示，可重新加载或明确强制覆盖 |
| W4 | 安全边界 | 仅授权根内、拒绝 VCS/依赖/构建目录、单文件 ≤ 512 KiB、二进制拒绝、原子写入、失败即回滚 |
| W5 | 人工审批 | 手机端保存前弹出确认层（路径 / 变更量 / 目标设备 / 冲突状态），确认即一次性授权；App 不缓存授权 |
| W6 | 真实链路回归 | M2.6 只读链路 14/14 仍通过；新增写入往返、冲突、越界、超限的测试 |

**非目标**：删除/重命名/移动文件；二进制或图片写入；文件上传下载；多文件批量写；目录新建；写成后自动执行命令；脱机队列（离线时保存按钮不可用）。

## 2. 审批语义

写入是**人在手机上的主动操作**，不是模型发起的工具调用，因此不经过 ACP 的 `approval.request` 拦截链路。审批由两层组成：

1. **手机确认层（人类审批）**：`WriteConfirmSheet` 展示电脑名、绝对目标目录、文件名、`+N/−M 行`、字节数、原文件 `sha256` 前 8 位、是否覆盖已有文件。用户点「确认写入」才发送 `file.write`；取消则一个字节都不发。每次写入都要重新确认，不提供「记住我的选择」。
2. **电脑端独立校验（纵深防御）**：Agent 不信任手机端，独立执行第 3 节全部规则。即使有人拿到 app token 直接发 `file.write`，也只能：落在授权根内、跳过忽略目录、不超限、且受 `baseSha256` 乐观锁约束（不带 `force` 时不能盲写已有文件）。

审计：Agent 每次写入记一条 `relay.file.write` 日志（`relativePath`、字节数、`sha256`、`created`、`forced`）。不写 `task_events`、不占 conversation `seq`（不是会话事件）。

## 3. WSS 协议（App → 插件/后端 → Agent）

沿用信封 `{v,type,ts,payload}`；`workspace.list`/`file.read` 同款**请求-响应**语义：回包按 `requestId` 配对，不广播进会话消息流、不分配 `seq`、不落 `task_events`。

### 3.1 `file.write`（App → Agent）

```json
{ "v":1, "type":"file.write", "ts":"...",
  "payload": {
    "requestId":"req_1720000000000000_3",
    "workspacePath":"D:\\proj",
    "relativePath":"docs/notes.md",
    "content":"# 记一笔\n",
    "baseSha256":"<64 hex 或省略>",
    "force":false
  } }
```

| 字段 | 必填 | 约束 |
|---|---|---|
| `requestId` | 是 | App 生成，≤64 字符，回包原样带回 |
| `workspacePath` | 否 | 必须是 `device.status.workspaceRoots` 之一；省略时用第一个根 |
| `relativePath` | 是 | 相对工作区根，`/` 或 `\` 分隔；禁止绝对路径、`..` 越界、NUL；不能为空 |
| `content` | 是 | UTF-8 文本；按 UTF-8 编码后 ≤ 524288 字节（512 KiB） |
| `baseSha256` | 否 | 调用方打开文件时拿到的 `sha256`；编辑保存必须带，新建文件不带 |
| `force` | 否 | 默认 `false`；`true` 时跳过存在性/乐观锁检查（仍需满足路径、大小、二进制、忽略目录规则） |

### 3.2 `file.write.result`（Agent → App）

成功：

```json
{ "type":"file.write.result",
  "payload": { "requestId":"req_1720000000000000_3", "ok":true,
    "workspacePath":"D:\\proj", "relativePath":"docs/notes.md",
    "size":18, "sha256":"<新内容 hex>", "created":false,
    "modifiedAt":"2026-11-05T06:10:00.000Z" } }
```

失败：`{ "requestId":"...", "ok":false, "code":"CONFLICT", "message":"..." }`

| 错误码 | 触发条件 |
|---|---|
| `PATH_NOT_ALLOWED` | 工作区不在授权根内 / 相对路径越界 / 落在忽略目录内 / 无权限 |
| `DIR_NOT_FOUND` | 父目录不存在 |
| `NOT_A_DIRECTORY` | 路径中某一级是文件 |
| `IS_A_DIRECTORY` | 目标是目录 |
| `FILE_NOT_FOUND` | 带了 `baseSha256` 但文件已不存在 |
| `FILE_EXISTS` | 未带 `baseSha256`、未带 `force`，但目标文件已存在 |
| `CONFLICT` | `baseSha256` 与当前文件不一致（电脑上已被改动） |
| `TOO_LARGE` | 内容超过 512 KiB |
| `BINARY_FILE` | 内容前 8 KiB 含 NUL 字节 |
| `INTERNAL` | 其他失败（临时文件清理后返回） |

### 3.3 写入算法

1. 用 `resolveWorkspacePath` 解析并做根内校验（与只读链路同一函数）。
2. 逐段检查 `relativePath`：任一段命中忽略目录集合 → `PATH_NOT_ALLOWED`。
3. `stat` 目标：目录 → `IS_A_DIRECTORY`；父目录不存在 → `DIR_NOT_FOUND`；父路径不是目录 → `NOT_A_DIRECTORY`。
4. 校验 `content` 字节长度与 NUL。
5. 存在性与乐观锁（见 3.1/3.2 表）。
6. 原子写：同目录临时文件 `.<name>.<pid>-<rand>.tmp` → 写入 → `rename` 覆盖目标；任一步失败删除临时文件并返回错误。
7. 返回新内容 `sha256`、`size`、`created`、`modifiedAt`。

### 3.4 中继职责（插件 `lib/hub.js` / Java `RelayHub`）

- `APP_FORWARD_TYPES` 增加 `file.write`；Agent 离线时回 `error{code:"DEVICE_OFFLINE"}`。
- `AGENT_BROADCAST_TYPES` 增加 `file.write.result`；**只广播**，不加 `seq`、不落 `task_events`。
- 其余鉴权/配对/事件补拉逻辑不变。

### 3.5 能力上报

`device.status.capabilities` 增加 `fileWrite:true`。旧客户端忽略该字段不受影响；手机端在没有 `fileWrite` 时隐藏「编辑 / 新建」入口。

## 4. 手机端（Flutter）

### 4.1 LiveStore 新增 API

```dart
Future<WorkspaceWriteResult> writeWorkspaceFile({
  required String workspacePath,
  required String relativePath,
  required String content,
  String? baseSha256,
  bool force = false,
});
```

复用 `_sendWorkspaceRequest`（requestId 配对、20s 超时、断线清理）；失败抛 `WorkspaceRequestException`，码表见 3.2。

### 4.2 页面

| 页面 | 变化 |
|---|---|
| 项目浏览页 | 顶栏「新建文件」；对话框输入文件名（允许 `a/b.md` 形式子路径，禁止 `/` 开头与 `..`）→ 打开编辑页（新建模式） |
| 文件预览页 | 顶栏「编辑」→ 编辑页；保存返回后自动重新读取并刷新大小/sha256；底部提示「只读」改为「可编辑」 |
| 编辑页（新） | 等宽多行输入、行号开关、字数与变更量、未保存返回拦截、保存按钮 → 确认层 |
| 确认层（新） | 目标设备、绝对目录、文件名、`+N/−M 行`、字节数、`覆盖已有文件` 标记、`sha256` 前 8 位；按钮「取消」「确认写入」 |

编辑页保留原文件的换行风格与 BOM：读取时识别 `CRLF`/`LF` 与 UTF-8 BOM，编辑期统一为 `LF`，保存时按原样还原。

### 4.3 冲突处理

收到 `CONFLICT` → 弹窗「电脑上的文件已被改动」：
- 「重新加载」：重新 `file.read`，丢弃本地编辑（二次确认）；
- 「强制覆盖」：带 `force:true` 重发一次（二次确认，明确提示会丢掉别人的改动）；
- 「取消」：留在编辑页，保留本地内容。

`FILE_EXISTS` → 提示「同名文件已存在」，改为编辑该文件时走 `baseSha256` 路径。

## 5. 验收

| 项 | 标准 |
|---|---|
| Agent 单测 | `node --test agent/tests/unit/workspace-fs.test.ts` 覆盖创建/覆盖/冲突/强写/超限/二进制/越界/忽略目录/父目录缺失/原子性 |
| Flutter 单测 | 写入请求字段、成功解析、`CONFLICT`/`FILE_EXISTS` 映射、确认层文案、未保存拦截 |
| 真实链路 | `node tools/verify-file-write.ts`：新建 → 读回校验 sha256 → 编辑保存 → 旧 `baseSha256` 冲突 → 强制覆盖 → 越界拒绝 → 清理，全部 PASS |
| 回归 | M2.6 `verify-project-sync.ts` 14/14、插件 smoke、M1 E2E 6/6 不变 |
