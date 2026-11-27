# DeepSeek 手机端 · 接口契约（v0.4.10，M4.10）

所有接口由 `dsh-plugin-m1` 插件在 `:8787` 提供，手机与电脑需在同一 Tailscale 网络（或同一局域网）。

## 鉴权

- `POST /api/v1/auth/pair` body `{"pairingCode":"000000","clientName":"..."}` → `{"token":"...","expiresAt":"..."}`
- 其余接口二选一携带 token：
  - `Authorization: Bearer <token>`
  - `?token=<token>`
- 失败：`401 {"code":"AUTH_FAILED","message":"unauthorized"}`

## 设备与任务

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/health` | `{status, version, agentOnline, apps, publicUrl}` |
| GET | `/api/v1/desktop/tasks` | `{tasks:[{id,title,workspace,status,progress,updatedAt}], workspaces:[{path,count,running}]}` |
| GET | `/api/v1/desktop/workspaces` | `[{path,name,sessions,running}]` |
| GET | `/api/v1/desktop/sessions?workspace=<path>` | 该工作区下的会话列表 |
| POST | `/api/v1/desktop/workspaces` | v0.4.1 起。body `{"name":"新项目"}` → `{"ok":true,"name":"新项目","path":"<第一个授权根目录>\新项目"}`；非法字符 `\ / : * ? " < > |` 替换成 `-`；失败 `400 {"code":"WORKSPACE_CREATE_FAILED","message":"..."}` |
| GET | `/api/v1/desktop/sessions/:id/events?afterSeq=&limit=` | `{sessionId,title,cwd,running,lastSeq,events:[{seq,kind,text,name,args,callId,ok,reason,time}],approvals:[...]}`；v0.4.3 起每条事件带 `time`（毫秒时间戳，插件 0.2.12+，旧版本缺省 0）——手机端用它取最新一条 `turn-start` 的时间作为「已运行」起点，与电脑端一致 |

## 写通道（需手机确认）

| 方法 | 路径 | body |
|---|---|---|
| POST | `/api/v1/desktop/sessions/:id/prompt` | `{"text":"..."}` → `{"ok":true,"accepted":true}` |
| POST | `/api/v1/desktop/sessions/:id/approvals/:approvalId` | `{"decision":"approve"|"reject"}` |
| POST | `/api/v1/desktop/upload` | `{"name":"a.png","data":"<base64>","workspace":"项目名"}` → `{ok,name,path,size}`；上限 20 MiB。v0.4.3 起可选 `workspace`（工作区**名字**）：插件 0.2.11+ 把它落到 `<授权根>/<工作区名>/手机附件/`，没给就落当前会话目录的 `手机附件/`，最后退回插件状态目录 `uploads/`（旧插件忽略该字段） |

说明：`POST /desktop/workspaces` 只在已有授权根目录下 `mkdir` 一个子目录，不删除任何内容；同名目录存在时直接复用（幂等）。

## 读文件（M4.9，插件 0.2.13+）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/desktop/file/raw?workspace=<授权根绝对路径>&path=<相对路径>` | 直接回原始字节（200），`content-type` 按扩展名（png/jpg/webp/pdf/txt/md/json，其它 `application/octet-stream`）。`workspace` 必须是 `device.status.workspaceRoots` 之一，`path` 不许含 `..`；单文件上限 20 MB；失败 400 `{code:"FILE_READ_FAILED",message}`，无 token 401 |
| POST | `/api/v1/desktop/file/read` | `{"name":"报告.docx","data":"<base64>"}` → `{ok,name,text}`。文本/代码按 UTF-8 解码，`.pdf` 用 pdf-parse，`.docx/.pptx/.xlsx` 从 zip 里抽 XML 文字；上限 2 MB；`.doc/.xls/.ppt` 旧格式返回 400 提示另存为新格式 |

手机端用法：图片走 `file/raw` 后在 App 内放大看；PDF / Office 走 `file/raw` 下载到手机缓存，再用 `content://` + `ACTION_VIEW` 交给 WPS / 系统阅读器；手机档（云端直连）把附件交给 `file/read` 读成文字再随消息发给模型。

## 会话存档（M4.10，插件 0.2.14+）

DSH 重启后旧会话可能从 `sessions.list()` 里消失（Host 的 JSONL 后端只认已物化日志，只剩 header 的会话整条 invisible）。插件自己维护一份存档，手机端于是还能看到「以前跑过、电脑列表里已经没有」的会话。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/desktop/archive/sessions` | `{sessions:[{id,title,workspace,source,createdAt,lastTime,messageCount,eventCount,archivedAt}]}`；按 `lastTime` 倒序，最多 400 条。`source`：`live` 运行时存档 / `disk` 从 DSH 磁盘日志恢复 / `imported` 手机端补传；失败 500 `{code:"ARCHIVE_FAILED"}`，无能力 501 `ARCHIVE_UNAVAILABLE` |
| GET | `/api/v1/desktop/archive/sessions/:id` | 完整记录（含 `events:[{seq,kind,text,reason,time}]`），结构同直播接口，`running` 恒为 `false`；没有 404 `{code:"ARCHIVE_NOT_FOUND"}` |
| POST | `/api/v1/desktop/archive/sessions` | body 同上（id/title/workspace/source/createdAt/lastTime/events）→ `{ok,saved}`；手机端补传用，失败 400 `{code:"ARCHIVE_SAVE_FAILED"}` |

存档文件：插件状态目录下的 `session-archive.json`（`<stateDir>/session-archive.json`）。每 30 秒刷新一次：把运行中的会话日志吸进存档，并扫描 `~/.dsh/sessions/` 下「存档里还没有」的会话日志（zstd 多帧解压）。手机端把电脑列表里已经没有的存档显示为「已存档」，点开是只读直播（没有输入条）。

## 插件管理

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/desktop/plugins` | 内核插件条目（entryId/moduleName/enabled/fiberPhase） |
| POST | `/api/v1/desktop/plugins/enabled` | `{"entryId":"...","enabled":true}` |
| GET | `/api/v1/desktop/plugins/bundles` | 已安装 bundle |
| POST | `/api/v1/desktop/plugins/bundles/enabled` | `{"name":"...","enabled":true}` |
| GET | `/api/v1/desktop/plugins/gallery` | v0.4.2 起（插件 0.2.10+）。本地插件画廊，对应电脑端「设置 → 插件 → 已安装」：`{total, groups:[{key,title,plugins:[{id,name,description,experimental,enabled,configurable,version}]}]}`；分组 `builtin`（内置插件配置）/`experimental`（实验性插件）/`other`；开关走 `POST /desktop/plugins/enabled`；旧插件返回 `501 {"code":"PLUGIN_GALLERY_UNAVAILABLE"}` |
| GET | `/api/v1/desktop/plugins/market` | 市场目录 `{indexes,source,query,entries,installedBundles,error,defaultIndex}`；v0.4.2 起条目带 `downloads`/`stars`，`defaultIndex=true` 表示电脑端没配索引、插件用了 DSH 公开索引 `https://api.dshmarket.com/v1/index.json` 兜底 |
| POST | `/api/v1/desktop/plugins/market/install` | `{"spec":"..."}` |
| POST | `/api/v1/desktop/plugins/market/remove` | `{"name":"..."}` |

## 应用更新

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/app/version` | `{versionCode,versionName,size,sha256}` |
| GET | `/api/v1/app/apk` | APK 流 |

## 实时通道

WSS `/ws`：`conversation.create` / `prompt.send` / `task.cancel` / `approval.decide` / `workspace.list` / `file.read` / `file.write` 为请求-响应；`task.state` / `approval.request` / `device.status` 等为服务端广播。
