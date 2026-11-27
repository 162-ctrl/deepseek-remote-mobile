# DeepSeek Harness 桌面端可编程接口调查报告

> 文档：`docs/research/HARNESS_INTERFACES.md`
> 调查人：harness-scout　调查时间：2026-10-31（Asia/Shanghai）
> 目标：判断「电脑端 Remote Agent 能否合法、官方地驱动本机 DeepSeek Harness 执行 AI 任务，并把流式状态回传手机」
> 环境：DSH 桌面应用 `44.7.0`（runtime `0.2.1-rc.5`，Node `24.21.0`，pnpm `11.28.5`，hostProtocolVersion `4`）；安装目录 `C:\Users\user\AppData\Local\Programs\DeepSeek Harness\`；用户配置 `C:\Users\user\.dsh\`；Web GUI `http://127.0.0.1:62492`；进程 `DeepSeek Harness`（Electron）。
> 证据等级：**【实测】**= 本机真实命令/协议交互输出；**【源码】**= 从 `app.asar` 导出的 `@deepseek-ai/*` 包 `lib/*.js` 逐行确认（未跑通）；**【未验证】**= 有线索未证实；**【不存在】**= 明确没有。
> 只读约束：未修改安装目录/桌面配置；探测进程使用临时 `DSH_HOME` 与临时工作区，结束后已清理（临时目录、凭据副本、自建进程、自动生成的空 profile 均已删除）。

---

## 0. 一句话结论（先看这里）

**DSH 当前版本没有面向外部程序/手机的 HTTP「Remote API」**；它原生提供的外部程序接口是两条 **stdio 进程级官方通道**：`dsh --profile acp`（Agent Client Protocol）与 `dsh --profile sdk`（stdio JSON-RPC），二者**均已本机实测跑通**。桌面实例的 `http://127.0.0.1:62492` 只是「官方 Web 前端 ↔ Host」的内部 RPC 面（launch-token + HttpOnly cookie + Host/Origin 栅栏，仅 loopback、端口随机、协议无文档），**不能**当作对外 API 依赖。

**Remote Agent 首选接入方式 = A 路线中的 ACP**：PC 侧 Remote Agent 以子进程方式启动 `dsh --profile acp`，用 NDJSON over stdio 对话；**对话、流式事件、工具调用、任务状态、取消、审批、多轮续跑、模型/推理强度切换全部实测闭环**，再由 Remote Agent 自己的 WebSocket 把状态推给手机。只有当你必须「附着用户正在运行的桌面实例的 live 会话」时，才需要 B 路线（官方 Cordis 插件桥）。

---

## 1. 调查项①：版本与安装布局【实测】

### 1.1 版本链

| 项 | 值 | 出处 |
|---|---|---|
| 桌面应用版本 | `44.7.0` | `C:\Users\user\AppData\Local\Programs\DeepSeek Harness\resources\version` 文件内容 |
| DSH runtime 版本 | `0.2.1-rc.5` | `resources\app.asar\dsh\package.json`（`name: @deepseek-ai/dsh-desktop-runtime`, `version: 0.2.1-rc.5`, `type: module`） |
| CLI 版本 | `0.2.1-rc.5` | `dsh --version` 实测输出 |
| Node / pnpm | `24.21.0` / `11.28.5` | `resources\runtime\versions.json` = `{schemaVersion:1,node:"24.21.0",pnpm:"11.28.5"}`；运行时 `node.exe` 实测 `v24.21.0` |
| hostProtocolVersion | `4` | `resources\app.asar\dsh\desktop-runtime.json` |
| 更新源 | generic feed，`https://download.deepseek.com/dsh-desk/feeds/win-x64/`，channel `nightly` | `resources\app-update.yml` |

### 1.2 安装布局

```
DeepSeek Harness\
├─ DeepSeek Harness.exe                  Electron 主程序
├─ resources\
│  ├─ app.asar                         182,766,714 B（JS 主体；包含 dsh 运行时 + 307 个 @deepseek-ai 包）
│  ├─ app.asar.unpacked\dsh\node_modules\  仅原生/二进制包（sharp、node-pty、koffi、@vscode/ripgrep、sherpa-onnx、@img 等）
│  ├─ runtime\
│  │  ├─ versions.json / bin\ / cli\ / office-skills\ / primary-runtime\
│  │  └─ cli\{command-manager.js, command-path.ps1, bin\dsh.cmd}
│  ├─ app-update.yml
└─ ...
```

`app.asar` 根目录：`dsh/`、`lib/`、`node_modules/`、`renderer/`、`package.json`。

`resources\runtime\cli\bin\dsh.cmd` 全文（**这是 dsh CLI 的入口定义**）：

```bat
@echo off
setlocal DisableDelayedExpansion
set "ELECTRON_RUN_AS_NODE=1"
"%~dp0..\..\..\..\DeepSeek Harness.exe" --expose-internals "%~dp0..\..\..\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js" %*
exit /b %errorlevel%
```

即：`dsh` = **用桌面版 Electron 的 Node 模式**（`ELECTRON_RUN_AS_NODE=1`）执行 `dsh-desktop-host/lib/cli.js`。这一点很关键——CLI/ACP/SDK/headless 全部复用安装内同一套 runtime，**无需额外安装 Node、无需联网**。

### 1.3 关键包（与路线判断直接相关）

从 `app.asar\dsh\node_modules\@deepseek-ai\` 导出并逐包读取，共 **307** 个包，其中：

| 包 | 作用（来自包内描述/源码） |
|---|---|
| `dsh-headless` | 一次性任务 runner：`Answer one task and exit`（"no Host, HTTP, or browser layer"） |
| `dsh-acp` / `dsh-acp-app` | **官方 ACP Agent 服务端** + `dsh --profile acp` 命令 |
| `dsh-sdk-app` / `dsh-sdk-jsonrpc-server` / `dsh-sdk-protocol` / `dsh-sdk-minimal` | **官方 stdio JSON-RPC SDK** + `dsh --profile sdk` 命令 |
| `dsh-host-webserver` | `node:http` 路由注册 / `registerUpgrade`（WebSocket）/ index 注入 / TLS |
| `dsh-client-connection` | `/api` 鉴权与浏览器信任栅栏、Peer、`/connect` |
| `dsh-api-gateway` | Remote 方法 → HTTP endpoint 网关；`/api/remote.mux` WebSocket 流 |
| `dsh-api-remote-access` | **方法级 Remote 访问控制**（per-Peer 访问快照、`allows(resource)`） |
| `dsh-api-session-controller` / `-job-controller` / `-workspace-controller` / `-workspace-files` / `-terminal-controller` / `-settings-controller` / `-remotes` / `-account-controller` | Host Remote 服务（`session` 命名空间等） |
| `dsh-desktop-host` | Electron 启动 Host 的入口（`lib/cli.js`）；把带 token 的 URL 通过 IPC 报给 Electron 主进程 |
| `dsh-web-app` / `dsh-web-frontend` | `dsh web` 的 Host 应用与前端 |
| `dsh-user-approval` / `dsh-user-questions` / `dsh-permission-presets` | 审批 / 结构化提问 / 权限预设 |
| `dsh-session-persistence-jsonl` / `dsh-session-query-sqlite` | 会话持久化（`~/.dsh/sessions`）与查询 |
| `@agentclientprotocol/sdk` | ACP 官方 SDK（`dist/acp.js` 73KB 等，随 DSH 一起分发） |

`app.asar\dsh\desktop-runtime.json` 还列出 `release {version, hostProtocolVersion, nodeVersion, pnpmVersion}`、`sharedPackages`（305 个 `{name,version,path}`）、`files`（带 sha256）。

---

## 2. 调查项②：CLI【实测】

### 2.1 顶层命令

```
$ dsh --version
0.2.1-rc.5

$ dsh --help
Usage: dsh [--profile] <name> [options] [app-args...]
       dsh plugin --profile <name> <pnpm-args...>

Options:
  -V, --version
  --profile <name>
  --from-default-profile <name>   replace a custom profile with a fresh copy of a shipped profile
  --patch <path>                  (repeatable) additional patch overlay
  --dump-config / --dump-config-schema / --dump-default-config
```

`dsh <name>` 是 `dsh --profile <name>` 的缩写；launcher 只解析自己的 flag，**第一个不认识的 token 起全部原样交给被启动的 app**（`app.asar\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js:17-20,129`）。`--profile desktop` 被显式拒绝：`error: profile "desktop" is managed exclusively by the Electron application`（同文件 `rejectElectronProfile`）——即**不能用 CLI 再起一个「桌面」profile**。

### 2.2 可用子命令（shipped profile 模板）【源码+实测】

`dsh-app-boot/lib/index.js:551-557` 的 `PROFILE_TEMPLATES`：

| profile | bundles |
|---|---|
| `headless` | `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-headless` |
| `web` | `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app` |
| `acp` | `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-acp-app` |
| `sdk` | `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-sdk-app` |
| `sdk-minimal` | `@deepseek-ai/dsh-sdk-minimal` |

`loadProfile`（`dsh-app-boot/lib/index.js:1065-1075`）：若 `$DSH_HOME/profiles/<name>/package.json` 不存在且名字在模板表里 → **本地自动初始化**（`initProfile`，只写 3 个模板文件：`package.json`、`cordis.patch.yml`、`pnpm-workspace.yaml`），**不联网、不跑 pnpm**；bundle 从安装锚点 `app.asar` 解析（`:995-1001`），所以新 profile 开箱即用。

`~/.dsh/` 布局（实测）：`profiles\{desktop,web,...}`、`sessions\`、`storages\`、`logs\`、`settings.yaml.imported`、`.credentials.yaml`、`openai-gateway\`、`llm-deepseek\`、`dsh-*\`（各插件数据目录）等。`DSH_HOME` 环境变量可整体覆盖（`dsh-home-paths` 源码 `DSH_HOME_ENV="DSH_HOME"`），**探测/测试可用临时 DSH_HOME 完全隔离**。

### 2.3 `dsh headless`：一次性任务（实测 36 条事件）

`dsh headless --help` 契约：`Answer one task and exit; the answer goes to stdout and diagnostics to stderr.`；参数 `task`（多词 join，`-` 从 stdin 读）；选项 `--json`（逐行 NDJSON 运行事件）、`--session-id <id>`（adopt 已持久化会话）。

**实测 A（成功）**：在临时工作区执行「列出当前目录文件名并说明数量」，`--json`，**exit 0，17.73s，36 条 NDJSON**。事件流（时刻为相对进程启动）：

```
1.36s {"type":"session","sessionId":"session-07e80a62-...","cwd":"D:\\...\\tmp\\ws1"}
1.36s {"type":"status","phase":"turn_start","turn":1}
1.38s {"type":"status","phase":"step_start","turn":1,"step":1}
2.22s {"type":"thinking","text":"..."} / {"type":"tool_call","callId":"...","tool":"pwsh","input":{...}}
2.23s {"type":"tool_result",...} / {"type":"status","phase":"step_end",...}
...
17.70s {"type":"text","text":"..."} / {"type":"status","phase":"turn_end",...} / {"type":"final","text":"...完整答案..."}
```

固定事件类型（源码 `dsh-headless\lib\json-stream-BA-F3lfb.js` `projectJsonRun`）：`session`、`status`（`turn_start`/`step_start`/`step_end`/`turn_end`，`step_end` 可带 `usage{inputTokens,outputTokens,totalTokens,cacheReadTokens,cacheWriteTokens,reasoningTokens}`）、`thinking`、`text`、`tool_call`、`tool_result`（`status:"completed"|"error"`）、`final`。上限：单字符串/键 8KB、单行 32KB，超限保留标量并加 `truncated:true`。

**实测 B（缺凭据，exit 1）**：

```
{"type":"status","phase":"turn_end","turn":1,"reason":{"kind":"error","error":{"message":"llm-deepseek: no API key for provider route \"deepseek-official\"; ...","code":"MISSING_CREDENTIAL"}}}
```

**实测 C（多轮续跑）**：`dsh headless --json --session-id session-07e80a62-... '继续：用一句话说明你上一步做了什么'` → exit 0、3.7s、8 条事件，`turn` 从 2 开始、上下文连续。未知 id 报 `{"type":"error","message":"session \"session-...\" does not exist; omit --session-id to start a new Session"}` + exit 1。

**实测 D（stdin）**：`'只回复两个字：收到' | dsh headless --json '-'` → exit 0、final=`收到`。

**限制（实测+源码）**：
- cwd = **启动进程的工作目录**（没有 `--cwd` 参数；源码 `const cwd = fs === void 0 ? process.cwd() : fs.processPath(await fs.resolve("."))`），事件首行回带 cwd。
- **无取消/超时**：stdin 只在 `task='-'` 时读一次，没有 cancel 协议；只能父进程 kill。
- **无审批通道**：需要升级沙箱时实测报 `Error: sandbox escalation to "danger-full-access" requires approval, but no approval channel is available` → 需要人工确认的操作必然失败。
- 退出码语义：`0` = `outcome.reason.kind === "completed"`，其余 `1`；失败时 stderr 写 `dsh: <message>`，`--json` 模式额外写 `{"type":"error","message":...}`。
- 非 `--json` 模式 stdout **只有最终答案**；reasoning 以 `dsh: reasoning:` 前缀流式写 stderr。

### 2.4 `dsh web`：官方 Web 服务

```
$ dsh web --help
Usage: dsh --profile web [options]
Serve the DeepSeek Harness browser UI.
  --host <host>              must be a concrete IPv4/IPv6 literal of a local interface (wildcard rejected)
  --no-open / --port <port>  (0 = system assigned)
  --public-url <url>         affects advertised/printed URL only, does not grant trust
  --trusted-host <authority...>  extra authority the /api browser-trust fence accepts
  --tls-cert / --tls-key
```

### 2.5 `dsh plugin`

```
$ dsh plugin --help
manage a profile's plugins by forwarding remaining args to pnpm in the profile directory
  --profile <name>
```

即插件安装 = 在 `$DSH_HOME/profiles/<name>/` 里转发 `pnpm add/remove/why`；也可以走 Harness 内官方 `plugin_manager install_bundle`（见 §5）。

---

## 3. 调查项③：本机 HTTP 服务（127.0.0.1:62492）【实测+源码】

### 3.1 它是什么

- `netstat`：`TCP 127.0.0.1:62492 0.0.0.0:0 LISTENING 22960`；`Get-NetTCPConnection -LocalPort 62492` → `OwningProcess 22960` = 进程 `DeepSeek Harness`，路径 `C:\Users\user\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe`。**HTTP 服务在 Electron 主进程内（不是独立 server 进程）**，只监听 loopback。
- 源码：`dsh-desktop-host/lib/index.js:218-250` 的 `main()` 由 Electron 通过 IPC 启动，参数**硬编码** `["--no-open","--host","127.0.0.1","--port","0"]`；启动后 `:342`：
  ```js
  const url = ctx.connection.authenticatedUrl(`${ctx.webServer.protocol}//127.0.0.1:${String(ctx.webServer.port)}`);
  process.send?.({ type: "ready", url, injections: ctx.webServer.collectIndexInjections() });
  ```
  → 端口由系统分配（**每次启动可能不同**，本次 62492），带 token 的 URL 通过 IPC 交给 Electron 主进程；**不会打印到日志**。`dsh-web-app/lib/index.js:160-165` 在 `dsh web` 模式下才 `console.log("dsh web: <authenticatedUrl>")`。

### 3.2 鉴权与信任栅栏（源码 `dsh-client-connection/lib/index.js`，1072 行）

- **launch token**：每进程 32 随机字节 base64url（`processLaunchToken` WeakMap）；`authenticatedUrl(baseUrl)` 生成 `?token=<launchToken>`；`authorizeIndex`（:458-497）校验 `GET /` 上「恰好一个 token 且匹配」→ `303 Location "./"` + `Set-Cookie`（名 `dsh-auth-<base64url(sha256(authority))>`，`HttpOnly; SameSite=Strict; Path=/`，`Max-Age=cookieMaxAgeDays`，默认 30 天）；否则 401 正文 `dsh web authentication required; reopen the URL printed by dsh web.`
- **`/api` 浏览器信任栅栏** `isTrustedApiRequest`（:240-250）：Host 头必须①loopback（`localhost`/`[::1]`/`127/8`）或②命中 `trustedHosts` 配置或③等于监听 bind IP 字面量；`sec-fetch-site: cross-site` 直接拒；有 `Origin` 时必须与 Host 同 authority（防 DNS rebinding/跨站）。
- **`/api` RPC 信封**（:888-916）：仅 `POST`；`content-type: application/json`（否则 415）；body `{"type":"client-request","rpcId":<string>,"method":<endpoint>,"payload":{...}}`；`method` 必须等于路径 endpoint；响应 `{"type":"server-response","rpcId":...,"result":{"ok":true,"value":...}}` 或 `{"ok":false,"error":{"code","message","details"}}`；未知 endpoint 404；body 上限 `maxRequestBodyBytes` 默认 300MB。
- **`/connect`**（:505-539）：`GET /connect?token=<launchToken>&interactions=answer|none` → `302 Location "./api/remote.mux"` + v2 cookie（payload 含新 Peer id）——**官方「远程 Peer 握手入口」**。
- **`/api/remote.mux`**（`dsh-api-gateway`）：`REMOTE_STREAM_MUX_PATH`；`new WebSocketServer({noServer:true})` + `webServer.registerUpgrade`；所有 Remote 流（含事件流）走这个 WS。帧：请求 `{type:"open",streamId,endpoint,payload}`、`{type:"cancel"|"end"|"item",streamId,...}`；响应 `{type:"item",streamId,value}` / `{type:"end",streamId}` / `{type:"error",streamId,error}`。
- **`dsh-host-webserver`**（538 行）：`register(route {kind:"prefix"|"exact", path, handler})`、`registerUpgrade(route)`、`registerFallback`、index 注入（`tapIndex`/`collectIndexInjections`）、可选 TLS。**插件可直接在 Host 的 webServer 上注册自己的 HTTP/WS 路由**。
- Config（`dsh-client-connection`）：`{recovery, trustedHosts: string[] 默认 [], cookieMaxAgeDays 默认 30, maxRequestBodyBytes 默认 300MB}`，`inject:["credentials"]`。

### 3.3 实测（私有实例：独立临时 DSH_HOME + `dsh --profile web --host 127.0.0.1 --port 3099 --no-open`）

| 请求 | 结果 |
|---|---|
| 启动 stdout | `dsh web: http://127.0.0.1:3099/?token=EimXmcgohaoc0zOy7Pf6wrWxzGwqfXmAuCSPvNJ6nM0`（token 43 字符 = 32 字节 base64url） |
| `GET /`（无 token） | `401` `dsh web authentication required; reopen the URL printed by dsh web.` |
| `GET /api`（无 cookie） | `401` `unauthorized` |
| `GET /?token=<正确>` | `303 Location "./"` + `Set-Cookie: dsh-auth-...; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict` |
| `GET /`（带 cookie） | `200` 官方 SPA HTML（`<base href="./">`） |
| `GET /api`（带 cookie） | `404 not found`（鉴权通过、前缀本身无 handler） |
| `GET /`（正确 cookie 但 `Host: example.com`） | `401`（Host 栅栏生效） |
| `GET /`（正确 cookie + `sec-fetch-site: cross-site`） | `200`（cross-site 拒绝只作用于 `/api` 数据面，静态 index 不拦） |
| `WebSocket /api/remote.mux` 无 cookie | `401`（未升级） |
| `WebSocket /api/remote.mux` 带 cookie | **`101 Switching Protocols`** |
| `GET /connect?token=<正确>&interactions=answer` | `302 Location "./api/remote.mux"` + v2 cookie（可解码出 `{"version":2,"authority":"127.0.0.1:3099","id":"02921f89-...","issuedAt":...,"expiresAt":...}`） |

**真实 Remote 方法（HTTP RPC，实测 200）**：

```http
POST /api/session/modelCatalog
{"type":"client-request","rpcId":"r-session/modelCatalog","method":"session/modelCatalog","payload":{"args":{}}}
→ {"type":"server-response","rpcId":"...","result":{"ok":true,"value":{
     "default":{"provider":"deepseek-official","model":"deepseek-flash"},
     "routableProviders":["deepseek-official","deepseek-account"],
     "groups":[{"id":"deepseek-official","name":"DeepSeek","models":[{"id":"deepseek-flash","name":"DeepSeek-V4.1-Flash",...},...]}]}}}
```

`POST /api/settings/describe {"args":{}}` → `{"ok":true,...namespaces:[session-log-deepseek, agent-default-model, ...]}`。
`POST /api/session/list {"args":{}}` → `{"ok":false,"error":{"code":"gateway/arguments-invalid","message":"typert gateway: session/list: args fields do not match the descriptor: missing \"_request\""}}`（`session/create` 缺 `"request"`）→ 这些方法要求结构化 request 参数，**签名未公开，需逐个从源码还原**。

**WS 事件流（实测）**：Peer cookie 升级 101 后发 `{"type":"open","streamId":"ev1","endpoint":"$events","payload":{"args":{}}}`，收到：

```json
{"type":"item","streamId":"ev1","value":{"type":"ready","clientId":"f5a50a66-...","host":{"home":"C:\\Users\\user"}}}
```

→ 外部客户端确实可以订阅 Host 事件流；但 `$events` 的 payload 语义/过滤条件无文档。

### 3.4 能否远程/跨进程调用？

- 桌面实例：绑定 `127.0.0.1`、端口随机（0 → 系统分配）、launch token 每进程随机且只经 IPC 给 Electron，**没有官方方式让手机/外部进程拿到 token**；协议本身是前端内部 RPC、无文档、无稳定性承诺。→ **不能作为对外 Remote API 依赖**。
- `dsh web` 独立实例：`--host` 可绑**具体本机 IPv4/IPv6**（拒绝通配地址）。实测 `dsh --profile web --host 192.168.1.x --port 3098 --no-open`：
  - 打印 `dsh web: http://192.168.1.x:3098/?token=...`；stderr 警告 `dsh web: listening on 192.168.1.x over plain HTTP; restrict this port to a trusted proxy or network`；
  - 从 LAN IP 访问 `GET /` → 401；`GET /?token=` → 303 + cookie（authority 绑定 `192.168.1.x:3098`）；带 cookie `POST /api/session/modelCatalog` → `200 ok:true`；
  - 该实例只监听指定 LAN IP（`127.0.0.1:3098` ECONNREFUSED）。
  → **官方 Web UI + /api 可以原生对局域网提供**，这是官方唯一「远程访问」形态；但它是**另一个 Host 进程**（独立 live 会话注册表），且是单用户 token 模型、默认明文 HTTP。

---

## 4. 调查项④：会话 / 工作区 / 任务 / 事件模型

### 4.1 Host Service 契约（`cordis_inspect_query(platform=host, provider=Service, method=listService)`）

服务目录（节选，均为真实注册的 Host 服务）：

| Service | 关键方法（签名节选） |
|---|---|
| `agents` | `create` / `resume` / `get` / `list` / `roots` / `announce` |
| `agentLoop` | `create` / `createAgent` / `resume` |
| `sessions` / `sessionQuery` | 会话持久化与查询（`.flush(session)` 等） |
| `workingDirectory` | 工作目录解析/set |
| `workspaceRegistry` / `workspaceController` / `workspaceFiles` / `workspaceChanges` | 工作区注册、文件、变更 |
| `approval` | `setPolicy(agent, policy)`；`request(req: ApprovalRequest): Promise<ApprovalOutcome>`；`overrideOf` |
| `userQuestions` | `@Remote answer(agent, callId, answer)`；`@Remote({mode:'stream'}) attachWait` |
| `tools` | `register` / `get` / `schemas` / `execute` / `guard` / `restrict` |
| `fs` | `resolve` / `readText` / `streamText` / `writeText` / `editText` / `listDir` / `watch` |
| `webServer` | `getOrigin()` / `register(WebRoute)` / `registerUpgrade(WebUpgradeRoute)` / `registerFallback` / `tapIndex` / `applyIndexTaps` / `collectIndexInjections` / `renderIndex` |
| `webApp` | `getAdvertisedUrl()` |
| `connection` | `createSharedFetchHandler('/api')` / `requestRejection` / `admit` / `createPeer({principal, interactions})` / `admitConnection` / `authorizeIndex` / `authenticatedUrl(baseUrl)` / `allowsRemoteAuthorities` |
| `typertGateway` | `invoke(InvokeRemoteRequest): Promise<unknown>` / `stream(...): Promise<AsyncIterable<unknown>>` / `registerRemoteEvents` / `hasLiveClient` |
| `remoteAccess` | 方法级 Remote 访问控制：`allows(resource)`、per-Peer 访问快照、`REMOTE_ACCESS_SNAPSHOT_KEY` |

大量方法带 `@Remote` 装饰器 = **Host Remote 方法，可通过 HTTP `/api` 或 WS mux 从 Host 外部调用**；`@Remote({mode:'stream'})` = 流式方法。

### 4.2 Remote 端点命名与方法表【源码】

规则：`endpoint = <namespace>/<Remote 方法名>`。`dsh-api-session-controller/lib/index.js:2650,2952` 定义 `super(ctx, "sessionController", { namespace: "session" })`，其 `@Remote` 方法（:2676-2700）：

`list`、`search`、`create`、`selectModel`、`modelCatalog`、`openWorkspacePath`、`workspacePathApplications`、`rename`、`fork`、`prompt`、`attachment`、`updateQueue`、`cancel`、`page`、`follow`、`projections`、`control`（`mode:"stream"`）。

→ 即 HTTP 面存在 `POST /api/session/prompt`、`/api/session/cancel`、`/api/session/follow` 等（**未逐个实测**，`modelCatalog`/`settings/describe` 已实测 200）。

### 4.3 事件模型（`cordis_inspect_query(platform=host, provider=Event, method=listEvents)`，79 个事件）

与外部接入最相关的（均为真实契约，含签名）：

| 事件 | 模式 | 说明/签名（节选） |
|---|---|---|
| `agent/assistant-stream` | emit | `(this: Scoped<Agent>, payload:{agent, frame: AssistantStreamFrame})` —— **进程内 token 级流**（插件可订阅；外部协议不转发） |
| `agent/status` | emit | `(payload:{agent, status: AgentStatus})` —— `idle ⇄ running` |
| `agent/error` | emit | `(payload:{agent, turn, step, error})` |
| `session/event` | emit | `(session, event: SessionEvent)` —— **提交后的 durable 会话事件append feed**（SDK/ACP 都基于它） |
| `session/created` / `session/disposed` / `session/flush` | emit/parallel | 会话生命周期/落盘 |
| `approval/request` | **waterfall** | `(req: ApprovalRequestEvent, next) => Promise<ApprovalOutcome>` —— **插件可应答/覆盖审批** |
| `user-questions/request` | waterfall | 结构化用户提问 |
| `tools/pre-execute` | waterfall | "Allow, deny, cancel, or ask before dispatch" |
| `tools/execute` / `tools/post-execute` / `tools/result` | waterfall/emit | 工具执行包装与结果观察 |
| `api-session/added` / `removed` / `status` / `activity` / `error` | emit | 会话列表/活动/运行状态（带 `SessionSummary`） |
| `connection/request` | waterfall | 包装已认证的 `/api` 请求（含 body transfer） |
| `llm/stream` | waterfall | 包裹每次模型流式调用（重试/路由/透传） |
| `subagent/start` / `subagent/end` / `workflow/*` | emit | 子代理与 workflow 运行 |
| `webserver/index-inject` | emit | index 注入表 |
| `schedule/changed`、`goal/*` | emit | 任务/目标 |

**结论（问题答案）**：
- **插件可以订阅流式输出/工具调用/审批**：`agent/assistant-stream`（token 级）、`session/event`（durable）、`tools/*`、`approval/request`、`user-questions/request` 全部存在，且审批是 **waterfall**（可自定义应答者）。
- **插件可以作为「外部入口」接收外部消息并投递给 Agent/会话**：可以。插件可在 `webServer` 上 `register`/`registerUpgrade` 自己的 HTTP/WS 路由（或复用 `/api` 挂 `connection.rpc` handler），再调用 `agents.create/resume` + `agent.followup(createUserMessage(...))`；`dsh-sdk-jsonrpc-server`、`dsh-acp` 本身就是「外部入口插件」的官方实现。

### 4.4 会话/工作区持久化【实测】

- `~/.dsh/sessions/` 下按 **cwd 编码**目录（如 `--D-~4E07~660A~6797-~9879~76EE-deepseek~624B~673A~7AEF-tools-harness_probe-tmp-ws1--`），headless 与桌面共用同一 store；会话与工作区绑定。
- `headless --session-id` 要求：session 已持久化、非 subagent、cwd 与当前进程相同、无 agent preset、且不在**本进程** live（源码 `dsh-headless/lib/index.js` `resolveAgent`）。**跨进程同时 live 同一会话的行为未验证**（桌面实例正持有它时，另一个 Host 进程能否 resume 未测）。

---

## 5. 调查项⑤：插件与扩展机制

### 5.1 官方机制

- **Cordis 插件树 + profile bundle + patch**：profile 的 `package.json` 用 `dsh.profile.bundles` 声明 bundle 列表，`cordis.yml` 为空数组（树由 bundles patches 组合）；`cordis.patch.yml` 是用户补丁层（insert / 按 id 覆盖 / group / disabled / isolate）；`--patch <path>` 可追加 overlay。
- **安装/启用**：
  - CLI：`dsh plugin --profile <name> add <pkg>`（转发 pnpm 到 profile 目录）；
  - Harness 内：`plugin_manager` 的 `install_bundle`（官方推荐；需要 danger-full-access 或审批；安装到当前 profile 并持久化）。
- **插件形态**：`dsh.bundle.patch` 指向自己的 `cordis.patch.yml`；`dsh.client.inject` + `dsh.client.platform=web` 让插件向 Harness Web UI 注入前端模块（Slot/UI 扩展）。
- **插件进程归属**：Host 插件运行在 **Host 进程内**（桌面端 = Electron 主进程派生的 Host；CLI 端 = dsh 进程）；Client 插件运行在 **Web 页面**。因此 Host 插件可直接拿到所有 Host Service、注册 HTTP/WS 路由、订阅全部事件。
- 当前 desktop profile 已启用 bundle：`@deepseek-ai/dsh-base`、`@deepseek-ai/dsh-web-app`、`@deepseek-ai/dsh-experimental-auto-review`、`@deepseek-ai/dsh-experimental-agent-team-profile`、`dsh-pet`、`dshmarket`、`dsh-our-free-model`、`billion-context`、`@vectorize-io/hindsight-coding-agents`、`@openviking/dsh-memory-plugin`、`@liustack/modlens`、`dsh-vision-router`、`dsh-pocket`（在 `cordis.patch.yml` 里被 `- id: dsh-pocket / disabled: true` 禁用）。

### 5.2 第三方先例：dsh-pocket（已安装、被禁用）

`~/.dsh/profiles/desktop/node_modules/dsh-pocket`（v2.12.0，GPL-2.0，repo `https://github.com/shaobeichen/dsh-pocket`，README 实测读到）：

- 「把 DeepSeek Harness 装进你的口袋：手机扫码即同步访问电脑上的 DSH（局域网 + 公网，实时同屏）」；
- 架构：`lib/index.js`（起代理 + 注册 RPC + 访问密码）、`lib/proxy.mjs`（**改头反向代理：Host/Origin → loopback，HTTP + WebSocket 全透传 + polyfill 注入 + gzip/brotli + 按 Host 区分令牌鉴权**）、`lib/tunnel.mjs`（cloudflared 公网隧道）、`lib/web-rpc.js`（loopback RPC：status/tunnel.start/tunnel.stop/lan.setEnabled/version/update/restart）、`client/` 设置页 + 移动端适配；
- 默认代理端口 3081；公网 8 位随机密码（`$DSH_HOME/dsh-pocket/token`）、局域网独立密码（`token-lan`）、登录限速（同 IP 错误 5 次锁 60s）；
- 说明**第三方插件确实拥有「注册 Host 路由/代理 + 注入客户端 UI」的完整官方扩展点**，并且证明了「反代 + WS 全透传 + 密码鉴权」这条路在桌面版可行（README 提示 desktop 的 advanced 模式手机访问会白屏，需 compatibility 模式）。
- 合规提示：**GPL-2.0**，若直接复用/修改需评估传染性；它是「手机看官方 UI」路线（C 变体）最直接的参考实现。

---

## 6. 调查项⑥：权限与安全

### 6.1 DSH 自身权限模型【源码+实测】

权限预设（`~/.dsh/profiles/desktop/cordis.patch.yml` 定义）：

| preset | sandbox | approval |
|---|---|---|
| `read-only` | read-only | ask |
| `workspace-write` | workspace-write | ask |
| `danger-full-access` | danger-full-access | never |

desktop profile `defaultPreset=danger-full-access`（用户当前配置）；headless/SDK 实测默认 `permission/preset=workspace-write`、`sandbox/mode=workspace-write`、`approval/policy=ask`。

- 审批流：`approval/request`（waterfall）→ 组合出的回答者；工具调用前还会经过 `tools/pre-execute` waterfall（可 allow/deny/cancel/ask）。
- **不同接入方式决定审批是否可用**：
  - `headless`：无审批应答者 → 升级沙箱必然失败（实测错误见 §2.3）。
  - `sdk`：无审批方法（源码方法表无审批）→ 同类限制（**未实测工具审批场景，源码推断**）。
  - `acp`：**有** `session/request_permission` 客户端请求，实测「批准 → 工具执行 → 写文件成功」闭环。
- 本机环境已知问题：D: 工作区沙箱 ACL provisioning 失败（`Error: SetNamedSecurityInfoW failed (Win32 5): grantWrite(<cwd>)`），与接口无关，但会让写操作先失败、再触发 danger-full-access 审批。

### 6.2 外部调用是否需要用户授权 / 哪些行为被禁止

- **桌面实例 `/api`**：需要用户操作产生的 launch token（打开打印的 URL）→ HttpOnly cookie；Host 栅栏限制 authority。**无官方方式让外部进程自动取得 token**（token 不落盘、只经 IPC/URL 出现）。绕过它等于破解前端内部通道，非官方。
- **`dsh web` 独立实例**：启动即打印带 token 的 URL（谁拿到谁能用，单用户模型）；`--public-url` 只影响打印、不授予信任；`--trusted-host` 明确扩展 `/api` 栅栏白名单；默认明文 HTTP（stderr 警告「restrict this port to a trusted proxy or network」）。
- **插件**：安装/启用需要用户批准（`plugin_manager` 需 danger-full-access 或逐次审批）；插件运行在 Host 进程内 = 与 Host 同权限，**无额外沙箱**。
- **Remote 访问控制**：`dsh-api-remote-access` 提供方法级、per-Peer 的访问快照与 `allows(resource)`；`connection.createPeer({principal, interactions})` 可创建受限 Peer（`interactions: "answer" | "none"`）。`/connect?interactions=answer` 产生的 Peer 才具备交互能力（审批/提问应答）。
- 被禁止/不支持：桌面 profile 不能由 CLI 启动（`rejectElectronProfile`）；`dsh web --host` 拒绝通配地址；headless 不支持人工审批/取消。

---

## 7. 未验证清单与风险

| # | 未验证/未决 | 影响 |
|---|---|---|
| 1 | HTTP `/api/session/{list,create,prompt,cancel,follow}` 的确切参数结构（typert descriptor，报错提示缺 `_request`/`request`） | 若要直接复用 `/api` 需逆向源码，工作量大且无稳定性承诺 |
| 2 | 两个 Host 进程同时操作同一 session 的行为（桌面实例 live 中，另一进程 resume） | 影响「CLI/ACP 与桌面实例共享同一会话」的可行性 |
| 3 | `$events` WS 流的事件负载与过滤条件 | 影响外部客户端订阅事件流 |
| 4 | `--trusted-host` + `--public-url` 在真实反向代理/隧道下的实际行为（仅读 help，未跑） | 影响手机经隧道访问官方 UI 的配置 |
| 5 | ACP 在**默认** `DSH_HOME` 下的行为（本次用临时 DSH_HOME；预期与实测一致） | 低风险；默认 home 下会自动创建 `profiles/acp` |
| 6 | SDK 场景下工具审批行为（源码推断无法应答） | 需实测确认 |
| 7 | 桌面主进程 launch token 是否有官方读取途径（IPC/日志） | 结论：当前无；即使有也属内部协议 |
| 8 | ACP 会话 id 是裸 UUID（非 `session-` 前缀），与 `~/.dsh/sessions` 目录的映射关系未细查 | 影响会话管理实现 |
| 9 | 本机 D: 盘沙箱 ACL 缺陷（Win32 5） | 会影响工具写文件与审批触发，属环境问题 |

> 注：#5、#6 之外另有若干「并发/审批拒绝/取消续跑/事件粒度/启动参数/稳定性」问题，已在 §7.1 第二轮追加实测中确认，可直接引用。

## 7.1 第二轮追加实测（并发 / 审批拒绝 / 取消续跑 / 事件粒度 / 启动参数 / 稳定性）

> 证据：`tools/harness_probe/probe_acp4.mjs`，原始输出 `tools/harness_probe/evidence/acp-probe4.log.json`（临时 `DSH_HOME`，cwd=`tmp/ws-acp4`，**同一个** `dsh --profile acp` 进程内 2 个 session）。标注【实测】= 本机真实协议输出；【源码】= asar 导出源码行号。

### 7.1.1 并发模型【实测】
- 同一 ACP 进程内可同时存在多个 session（两次 `session/new` 得到两个裸 UUID）；**跨 session 的 turn 并行执行**：A、B 同在 1.69s 发起 `session/prompt`，短任务 B 在 2.19s 返回 `end_turn`，长任务 A 在 5.58s 返回 `end_turn`（总耗时≈max 而非 sum）→ 不需要「每任务一进程」。
- 同一 session 同时只允许一个 in-flight turn：第二个 `session/prompt` 返回 JSON-RPC 错误 `{"code":-32602,"message":"Invalid params: a prompt is already in flight for this session"}`（实测第 5.67s）。
- 建议实现：**单 ACP 进程 + 每任务一个 session**（或每会话一个 session，prompt 串行入队），手机端并发会话互不阻塞。
- 权限/沙箱是进程级或会话级？本次两 session 都继承同一 Host 默认（workspace-write/ask），未见 per-session 差异；**未验证** per-session preset 覆盖。

### 7.1.2 审批精确契约【实测+源码】
- 触发：服务器 → 客户端 JSON-RPC **请求**（需回包）`method:"session/request_permission"`，实测 payload：
  `{"sessionId":"…","toolCall":{"toolCallId":"call_00_…"},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}`（源码 `dsh-acp/lib/index.js:1158-1181` 完全一致）。
  - **options 只有 allow-once / reject-once 两种，没有 allow-always**；`toolCall` 里只有 `toolCallId`，标题/命令不在这里。
  - 客户端应答：`{"outcome":{"outcome":"selected","optionId":"allow-once" 或 "reject-once"}}`，或 `{"outcome":{"outcome":"cancelled"}}`。
  - 服务端映射（源码 :1177-1180）：`cancelled`→`"cancelled"`；`optionId==="allow-once"`→`"allowed-once"`；其它→`"rejected"`。
- **手机展示审批所需的参数在请求前已单独推送**：bridge 先 `record.drainUpdates()` 再发 request_permission（源码 :1162），因此客户端一定已收到对应 `tool_call`（`status:"in_progress"`，`rawInput` 含完整命令/参数）与 `tool_call_update`，可用 `toolCallId` 关联展示。实测时间线：`tool_call(in_progress)`@22243ms → `request_permission`@22245ms。
- **拒绝后的行为【实测】**：回 `reject-once` → 工具 `tool_call_update` `status:"failed"`，正文 `Error: the user rejected escalating this command to "danger-full-access"; it stays denied, so stop and explain instead o…`；Agent 按提示「停止并解释」，最终给出说明性回答，prompt 以 **`stopReason:"end_turn"`** 结束（不是错误、不是 cancelled）；随后同一 session 再发 prompt 正常 `end_turn` → **拒绝不会终止会话**。
- 对照（无审批通道时的 headless 实测）：`sandbox escalation … requires approval, but no approval channel is available` → 工具直接失败。

### 7.1.3 文件能力【源码+实测】
- ACP 服务端注册的请求方法只有：`initialize`、`authenticate`、`session/new`、`session/list`、`session/resume`、`session/close`、`session/set_config_option`、`session/prompt`；通知只有 `session/cancel`（源码 `onRequest`/`onNotification` 链，grep 全文）。
- **没有 `fs/read_text_file`、`fs/write_text_file`、terminal 类客户端方法**（grep 无命中）→ 文件读写只能由 Agent 自己的工具（`fs`/`pwsh` 等）完成，客户端不直接读写文件；工作目录在 `session/new {cwd}` 固定，`session/resume` 必须传相同 cwd。
- 需要远端上传/下载或自定义能力时：`session/new {mcpServers}` 挂 MCP server（`agentCapabilities.mcpCapabilities.http=true`），或走 Remote Agent 自己的通道。

### 7.1.4 session 生命周期【实测】
- `session/list` 返回**已持久化**会话（上一进程创建、本进程未 live 的也会列出）；`session/resume {sessionId, cwd}` 恢复上下文成功（实测 prompt 能复述上一轮回答）；`session/close` 后仍可 resume。
- **取消后 session 可继续**：`session/cancel` → 当前 prompt `stopReason:"cancelled"`；随后再 `session/prompt` → `end_turn`（实测）。
- ACP sessionId 是裸 UUID（无 `session-` 前缀），跨进程续跑依赖 `~/.dsh/sessions` 持久化 + cwd 匹配（与 headless 共用同一存储，目录按 cwd 编码）。

### 7.1.5 启动参数【源码+实测】
- `dsh --profile acp` 的 app 命令**零选项**（`dsh-acp-app/lib/index.js` 全文 40 行：只有 name/description/action）→ 没有 `--cwd/--model/--preset` 之类 app 参数；工作目录由每次 `session/new` 的 `cwd` 决定，与启动进程 cwd 无关。
- 模型/推理强度：bundle patch 默认 `provider: deepseek-official, model: deepseek-v4-flash`（`dsh-acp-app/cordis.patch.yml`）；会话内用 `session/set_config_option` 切换 model（分组 deepseek-official / deepseek-account，含 deepseek-v4-flash / deepseek-v4-pro 等）与 reasoning_effort（off/low/high/max），实测成功。
- 改默认 provider/model 或权限 preset：用 launcher 全局 `--patch <file>`，或写 profile 自己的 `~/.dsh/profiles/acp/cordis.patch.yml`；沙箱/审批 preset 与桌面同源（settings + patch，本机默认 danger-full-access）；危险升级（→danger-full-access）走 `request_permission`（实测），拒绝即失败并解释。

### 7.1.6 事件粒度【实测+源码】
- `session/update` 的 `agent_message_chunk` 是**提交点粒度**（一个 committed block 一个 chunk，非 token 级）：实测 250 字中文回答只产生 **1 个** `agent_message_chunk`（+1 个 `agent_thought_chunk`），在 turn 末尾一次性到达。
- `tool_call` 带 `rawInput`（完整命令）；`tool_call_update` 带 `status`（completed/failed）与结果内容；`usage_update` 带 `{used,size}`（实测 size=1000000）；`agent_thought_chunk` 是整段思考。
- 若必须逐字流式：只有 B 路线（Host 进程内 `agent/assistant-stream` 事件）能拿 token 级；A 路线只能做到「步骤级实时」（每个 step/工具完成即推）。

### 7.1.7 稳定性与协议版本【源码 + npm registry】
- ACP 是**官方 shipped profile**（`@deepseek-ai/dsh-acp-app` 在 `PROFILE_TEMPLATES` 中）、MIT；npm 公开可查：`@deepseek-ai/dsh-acp-app` 的 dist-tags `latest=0.1.2-alpha.2`、`next=0.2.1-rc.5`、`alpha=0.2.2-alpha.2`，与本机 runtime `0.2.1-rc.5` 同系列；发布从 2026-08-30 持续到 2026-10-29。
- **ACP 协议版本 = `@agentclientprotocol/sdk` 的 `PROTOCOL_VERSION`，实测 `initialize` 返回 `protocolVersion: 1`**；`hostProtocolVersion: 4` 是 DSH Host/桌面 IPC 协议版本（`desktop-runtime.json`），**与 ACP 无关**。
- 结论：官方、公开、版本化，但整体仍处 rc（0.2.1-rc.5）+ 无随包公开 README/API 文档，按「官方 RC 契约」对待：锁版本、未知 `session/update` 类型忽略、JSON-RPC error 统一映射、每次升级跑回归探测脚本。

---

# 路线推荐

> 说明：A = 官方 CLI/SDK；B = 官方插件桥（进程内/本地 WS）；C = 本地 HTTP/桌面自动化。
> 能力图例：✅ 完整可用　⚠️ 有限/需绕行　❌ 不支持

## 8.1 能力覆盖矩阵

| 能力 | A 官方 CLI/SDK（**ACP**） | A2（SDK/headless） | B 官方插件桥 | C1 直连桌面 `/api` | C2 独立 `dsh web` | C3 桌面 UI 自动化 |
|---|---|---|---|---|---|---|
| 对话/多轮 | ✅ 实测（session/new、prompt、resume） | ✅ headless 一次性 + `--session-id` 续跑；SDK `session/prompt` 实测 | ✅（agents/followup） | ⚠️ 需逆 signature | ✅ 官方 UI | ⚠️ 模拟输入 |
| 流式状态 | ⚠️ **提交点粒度**（`agent_message_chunk`/`tool_call`/`usage_update` 实时到达，非 token 级） | headless `--json` NDJSON（提交点粒度）；SDK `session.event` | ✅ **token 级**（`agent/assistant-stream`） | ⚠️ 同官方 UI | ⚠️ 同 ACP 粒度 | ✅（读屏） |
| 任务状态 | ✅ `agent/status`、`session/update`、`usage_update`、`stopReason` | ✅ status 事件/`session/wait` | ✅ | ⚠️ | ✅ | ⚠️ |
| 取消 | ✅ 实测 `session/cancel` → `stopReason:"cancelled"` | ❌ headless 无；❌ SDK 无 | ✅（`agents`/`agent.cancel`） | ⚠️ | ✅ 官方 UI | ⚠️ 模拟点击 |
| 文件 | ✅（agent 自带工具读写，实测写文件成功；客户端无文件 API） | ✅（agent 工具） | ✅（`fs` 服务 + `workspaceFiles`） | ⚠️ | ✅ | ⚠️ |
| 工作区 | ✅（cwd 由 `session/new {cwd}` 固定；**无**客户端改 cwd/fs 方法） | ✅（进程 cwd；SDK `working-directory set` 实测） | ✅（`workingDirectory`/`workspaceController`） | ⚠️ | ✅ | ⚠️ |
| 审批 | ✅ 实测 `session/request_permission`（allow-once → 工具执行） | ❌ headless/SDK 无审批通道 | ✅（`approval/request` waterfall） | ⚠️ | ✅ 官方 UI 审批 | ⚠️ 点按钮 |
| 附着桌面 live 会话 | ❌（独立 Host 进程） | ❌ | ✅ **唯一官方方式** | ⚠️ 需 token+反代 | ❌（独立 Host） | ✅（同一 UI） |

## 8.2 A 路线：官方 CLI/SDK（首选：ACP）

- **形态**：PC 端 Remote Agent 以子进程启动 `dsh --profile acp`（推荐直接用 `DeepSeek Harness.exe --expose-internals "<install>\resources\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js" --profile acp`，或 `resources\runtime\cli\bin\dsh.cmd --profile acp`），**NDJSON JSON-RPC 2.0 over stdio**；Agent Client Protocol（`@agentclientprotocol/sdk` 随 DSH 分发）。**单进程可并发多 session**（每 session 串行一个 turn，跨 session 并行，见 §7.1.1）。
- **实测证据**：`initialize`（agentInfo `deepseek-harness-acp` v0.0.1，protocolVersion 1，`sessionCapabilities{close,list,resume}`）→ `session/new {cwd}` 返回 sessionId + configOptions（模型分组、`reasoning_effort`: off/low/high/max）→ `session/prompt` 收到 `agent_message_chunk` / `agent_thought_chunk` / `tool_call` / `tool_call_update` / `usage_update` → **审批** `session/request_permission`（回 `{"outcome":{"outcome":"selected","optionId":"allow-once"}}` 后工具执行、文件写入成功；回 `reject-once` 则工具 failed、Agent 停止并解释、turn 正常 `end_turn`，见 §7.1.2）→ **取消** `session/cancel` → `{"stopReason":"cancelled"}`，取消后同一 session 可继续 → `session/list` / `session/close` / `session/resume` 后上下文连续 → stdin EOF 干净退出（exit 0）。
- **能力覆盖**：对话 ✅、流式 ⚠️（提交点粒度：250 字回答仅 1 个 chunk，实测见 §7.1.6；手机端体验为「步骤级实时」）、任务状态 ✅、取消 ✅、文件 ✅/⚠️（agent 工具读写，客户端**无** fs 方法，见 §7.1.3）、工作区 ✅（cwd 由 session/new 固定）、审批 ✅。
- **实现难度：低**。官方协议 + 官方 SDK（npm `@agentclientprotocol/sdk`，DSH 内已带 `dist/acp.js`、示例 `http-server.js`/`ws-client.js`）；NDJSON 也可手写几十行。
- **稳定性：中高**。官方 shipped profile、npm 公开包（`next=0.2.1-rc.5`，与 runtime 同版本）、版本化协议（ACP protocolVersion 1）；但 runtime 仍是 rc.5 且无随包公开 API 文档，按官方 RC 契约对待（锁版本 + 忽略未知 update 类型 + 回归脚本），详见 §7.1.7。
- **合规风险：低**。官方协议与官方 profile；不修改安装目录/桌面配置；首次使用会在 `~/.dsh/profiles/acp` 自动生成空 profile（官方行为）。注意：它是**独立 Host 进程**，看不到桌面实例 live 会话（会话按 cwd 持久化，磁盘层可续跑，同时 live 未验证）。
- **推荐度：★★★★★（Remote Agent 的默认接入方式）**
- 备选：`headless`（一次性批任务、`--json` NDJSON、退出码语义清晰；但无取消/审批/超时）；`sdk`（stdio JSON-RPC，`initialize` 需显式 `{provider,model}`，实测 `session/prompt`→`messageId`、`session.event` 全量事件、`session/wait`、`working-directory/get`；无取消/审批）。

## 8.3 B 路线：官方插件桥（附着桌面实例的唯一官方方式）

- **形态**：写一个 Cordis Host 插件（bundle + patch + `dsh.client.inject` 可选），随 desktop profile 启用；插件在 **Host 进程内**：
  - 用 `webServer.register` / `registerUpgrade` 暴露自有 HTTP/WS（或挂 `connection.rpc` handler）；
  - 用 `agents` / `sessions` / `agentLoop` 直接驱动用户桌面实例的 live 会话（`agent.followup`），订阅 `agent/assistant-stream`（**token 级**）、`session/event`、`agent/status`、`tools/*`；
  - 用 `approval/request` waterfall 或 `approval.request()` **替手机应答审批**；`userQuestions` 同理；
  - 可用 `connection.authenticatedUrl()` 拿到带 token 的官方 URL，或自建鉴权（dsh-pocket 模式：反代 + 密码 + WS 全透传）。
- **可行性证据**：所有扩展点均为真实 Host Service/Event（§4）；第三方插件 `dsh-pocket` 2.12.0 已实现同类能力（反代 3081 + WS 全透传 + 双密码 + cloudflared 隧道 + 设置页/移动端 UI 注入）。
- **能力覆盖**：全部 ✅（含 token 级流式、live 会话、审批应答、文件/工作区/任务）。
- **实现难度：中高**。需打包插件（bundle manifest/patch/locale/icon、可选 client UI）、遵守 Cordis Slot/Client 契约、桌面 profile 由 Electron 独占管理（安装走 `plugin_manager install_bundle` 或 `dsh plugin`）、需测试 UI 白屏/移动端适配（pocket README 提到 desktop advanced 模式白屏需 compatibility）。
- **稳定性：中**。Host Service/Event 是官方扩展机制但**无公开 API 文档**，`hostProtocolVersion=4` 说明协议会演进；插件崩溃影响 Host 进程；升级可能破坏内部调用。
- **合规风险：中低**。官方插件机制（合法），但插件拥有 Host 全权限、需用户批准安装；若分发需注意许可证（pocket 为 GPL-2.0，直接借用代码有传染性）。
- **推荐度：★★★☆（当且仅当产品需求是「手机操作电脑上正在运行的 DSH 会话」时采用；否则 A 更轻）**

## 8.4 C 路线：本地 HTTP / 桌面自动化

- **C1 直连桌面实例 `http://127.0.0.1:62492` 的 `/api`**：协议真实存在（实测 RPC/WS 均可调），但：
  - token 每进程 32B 随机、只经 IPC 交给 Electron、不落盘；端口 `--port 0` 随机；绑定仅 loopback；`/api` 是前端内部协议、无文档、无版本承诺。
  - 外部程序要拿到 token+端口，只能读 Electron IPC/日志/内存或注入 → **非官方**；即使拿到，也要处理 Host 栅栏与 30 天 cookie。
  - 结论：**不作为推荐路线**；若一定要「手机看桌面同一 UI」，正确做法是 B（插件桥）或参考 dsh-pocket 的第三方反代（C1+，GPL 注意）。
  - 难度：高；稳定性：低；合规：中低（绕过内部协议）；推荐度：★☆。
- **C2 独立 `dsh web` 实例（官方支持 LAN）**：
  - `dsh --profile web --host <LAN-IP> --port <p> --no-open` **实测**：打印带 token URL、手机可访问官方完整 Web UI（LAN authority 的 cookie 正常签发、`/api` 200、含审批/文件/流式的全部官方 UI 能力）；stderr 警告明文 HTTP。
  - 局限：**另一个 Host 进程**（独立 live 会话注册表；磁盘会话可续跑，但看不到桌面实例 live 会话）；单用户 token、无多设备会话隔离、无 TLS（需自备反代/隧道，配合 `--trusted-host`/`--public-url`）；token URL 需扫码/转发。
  - 适合：快速可用/兜底方案；也适合让用户「在手机上用官方 UI 干一次活」。
  - 难度：**低**（一条命令 + 二维码）；稳定性：中高（官方 web profile，但单进程、无守护/重连语义）；合规：**高**（官方 CLI）；推荐度：★★☆。
- **C3 桌面 UI 自动化（CDP/UIA/Win32 消息/坐标点击）**：能力「看起来全」，但**非官方、脆弱**（渲染层改版即失效）、无法可靠取回流式文本/审批语义、可能点错风险操作。
  - 难度：中；稳定性：低；合规：低（等同代替用户操作）；推荐度：✗ 不推荐。

## 8.5 一句话总推荐

**电脑端 Remote Agent 用 `dsh --profile acp` 子进程 + ACP（NDJSON/stdio）全双工驱动 DSH（对话、步骤级流式事件、工具调用、取消、审批、多轮续跑均已实测），把 ACP 事件经 Remote Agent 自己的 WebSocket 回传手机；DSH 没有面向外部程序的 HTTP Remote API——桌面实例 62492 的 `/api` 只是官方 Web 前端内部 RPC（launch-token + cookie + Host 栅栏、仅 loopback、端口随机），不要依赖；仅当必须附着用户正在运行的桌面 live 会话时，才采用 B 官方 Cordis 插件桥（可参考 dsh-pocket 的「反代 + WS 全透传 + 密码」先例，注意 GPL-2.0）。**

---

## 附录 A：证据文件与探测脚本

- 探测脚本（均在 `tools/harness_probe/`，只读、临时 DSH_HOME、已清理）：
  - `probe_headless.ps1` —— headless `--json` 事件到达时刻/退出码/凭据注入；
  - `probe_acp.mjs` —— ACP 全流程（initialize/session-new/prompt/审批/取消/list/close/resume/set-config）；
  - `probe_acp4.mjs` —— ACP 第二轮：多 session 并发、同 session 双 prompt、`request_permission` 拒绝后的行为、取消后续跑、事件粒度、长回答 chunk 计数（输出 `evidence/acp-probe4.log.json`）；
  - `probe_sdk.mjs` —— SDK stdio JSON-RPC（initialize/prompt/wait/working-directory）；
  - `probe_web.mjs` / `probe_web2.mjs` / `probe_web3.mjs` —— `dsh web` 鉴权、cookie、Host 栅栏、HTTP RPC、WS mux、`$events`、LAN 绑定；
  - `extract_key.mjs` / `list_asar.mjs` / `read_meta*.mjs` —— 用 `ELECTRON_RUN_AS_NODE=1` 读 `app.asar` 并导出关键包（`fs.cpSync` 不适用，需手工 `readdirSync`+`readFileSync`）。
- 原始输出：`tools/harness_probe/evidence/*.log.json`（ACP/SDK/web 探测结果、headless 事件样本）。
- 源码引用（均在 `C:\Users\user\AppData\Local\Programs\DeepSeek Harness\resources\app.asar\dsh\node_modules\@deepseek-ai\` 下）：
  - `dsh-headless/lib/index.js`、`dsh-headless/lib/json-stream-BA-F3lfb.js`
  - `dsh-acp/lib/index.js`（ACP 服务端；NDJSON 传输 :1361，审批 :1158-1181，cancel :1355-1356）
  - `dsh-acp-app/lib/index.js`、`dsh-sdk-app/lib/index.js`
  - `dsh-sdk-jsonrpc-server/lib/index.js`（方法表 :275-301，session.event 通知 :68 起）
  - `dsh-client-connection/lib/index.js`（信任栅栏 :240-250，BrowserAuth :414-578，/api 路由 :1044-1058，RPC 信封 :888-916）
  - `dsh-host-webserver/lib/index.js`（`:102-107` 自述）
  - `dsh-api-gateway/lib/types/stream-protocol.js:4`（`REMOTE_STREAM_MUX_PATH="/api/remote.mux"`）
  - `dsh-api-session-controller/lib/index.js:2676-2700,2952`（session 命名空间 @Remote 方法）
  - `dsh-app-boot/lib/index.js:551-557,611-627,995-1001,1065-1075`（profile 模板/初始化/解析）
  - `dsh-desktop-host/lib/index.js:218-250,342`（桌面 Host 启动参数与 URL 上报）
  - `dsh/lib/bin.js:17-20,129`（CLI launcher 语义）
  - `dsh/desktop-runtime.json`（release/sharedPackages/files）
  - `resources/runtime/cli/bin/dsh.cmd`、`resources/version`、`resources/runtime/versions.json`
  - 用户侧：`~/.dsh/profiles/desktop/package.json`、`~/.dsh/profiles/desktop/cordis.patch.yml`、`~/.dsh/.credentials.yaml`（仅读取 refs 用于注入，未输出密钥）、`~/.dsh/profiles/desktop/node_modules/dsh-pocket/*`

## 附录 B：清理与副作用声明

- 探测进程全部用临时 `DSH_HOME`（`tools/harness_probe/tmp/*-home`）与临时工作区，结束后已删除（含 `.credentials.yaml` 副本）。
- 唯一副作用：首次 headless 探测（默认 DSH_HOME）自动生成了空 profile `~/.dsh/profiles/headless` 与 2 个 probe 会话目录，**已删除还原**；`~/.dsh/profiles/web` 为调查前已存在（未改动内容），`desktop` profile 未作任何修改。
- 未修改 DSH 安装目录、未安装/卸载任何软件、未写注册表/服务、未 kill 用户进程。
