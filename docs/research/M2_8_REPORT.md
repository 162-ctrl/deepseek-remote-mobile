# M2.8 手机端写文件 · 交付报告

> 2026-11-05 · App v0.1.9-m2.8（versionCode 10）· 插件 0.2.0

## 一、目标

补齐 M2.6 的「手机端只读」短板：在手机上新建、编辑、保存电脑工作区里的文本文件，并且每次写入都要经过手机端确认、电脑端独立校验。

## 二、做法

- **协议**：WSS 新增 `file.write` → `file.write.result`，与 `workspace.list`/`file.read` 同为请求-响应（不占 seq、不落 `task_events`）；`device.status.capabilities` 增加 `fileWrite`。详见 `docs/design/M2_8_FILE_WRITE_DELTA.md`。
- **双层审批**：
  1. 手机端保存前弹 `WriteConfirmSheet`（路径、新建/覆盖、大小、行数、± 行数、「仅授权工作区内」）；
  2. Agent 端独立校验：授权根内、忽略目录拒绝、≤ 512 KiB、含 NUL 视为二进制拒绝、必须 UTF-8、缺失字段 `BAD_REQUEST`。
- **冲突保护**：打开文件时的 sha256 作为 `baseSha256` 回传；磁盘内容已变 → `CONFLICT`，App 提供「重新加载 / 强制覆盖 / 取消」；新建撞名 → `FILE_EXISTS`。
- **原子写**：同目录临时文件 + `rename`，失败清理；返回实际写入字节的 sha256。
- **App**：文件页「编辑并保存」→ 全屏等宽编辑器（新建/已修改/一致状态条、行数、离开确认、CRLF+BOM 保存还原、截断文件只读）；项目页「新建文件」→ 路径校验 → 编辑器；保存成功返回并刷新。
- **中继**：插件 `lib/hub.js` 与 Java `RelayHub` 白名单各加两个类型；修正插件握手用骨架 `device.status` 覆盖 `workspaceRoots` 的问题（缓存并重放 Agent 状态）。

## 三、验证

| 项 | 结果 |
|---|---|
| Agent 单测 | `node --test agent/tests/unit/workspace-fs.test.ts` → **20/20**（新增 10 项：新建、撞名、正确/陈旧 base、被删文件、force、越权、父目录缺失与 `..`、目标是目录、超限/二进制且无临时残留） |
| App 单测 | `flutter test` → **205/205**（新增 3 项：file.write 报文与解析、新建不带 base/force、CONFLICT 中文提示） |
| 真实链路 | `node tools/verify-file-write.ts --base http://127.0.0.1:8787 --code <码>` → **14/14 PASS**；证据 `docs/research/evidence/m2/file-write-2026-11-05T07-08-10-383Z.json` |
| 构建 | `dist/DeepSeek-Remote-AI-v0.1.9-m2.8.apk`（68,716,932 字节，`versionCode=10`，`versionName=0.1.9-m2.8`） |

真实链路覆盖：工作区根下发、`fileWrite` 能力、新建并校验 sha256/磁盘/回读、无 base 覆盖 → `FILE_EXISTS`、陈旧 base → `CONFLICT` 且磁盘未变、正确 base 覆盖 `created=false`、`../` 越界 → `PATH_NOT_ALLOWED`。

## 四、已知限制

- 仅文本、≤ 512 KiB；预览截断（>1 MiB）或二进制文件不开放编辑。
- 编辑器无撤销/重做、无语法高亮；暂不支持删除/重命名/移动。
- 快速隧道地址随插件重载变化；手机需安装 0.1.9 才能看到编辑入口。

## 五、复现

```powershell
node tools\verify-file-write.ts --base http://127.0.0.1:8787 --code <匹配码>
node --test agent/tests/unit/workspace-fs.test.ts
cd app; flutter test
```
