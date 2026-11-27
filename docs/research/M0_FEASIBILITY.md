# M0 可行性验证与 Harness 适配内核交付报告

> **状态**：M0 已完成（2026-10-31）。
> **一句话结论**：手机远程控制 Harness 的"最后一公里"已被真实跑通——在**真实 DeepSeek Harness 0.2.1-rc.5** 上，`agent/` 内核可以连接 Harness、跑真实任务、在工具执行中取消、在需要时弹出审批并等待真人决定、断线后恢复会话上下文；**单测 36/36、合同测试 9/9、端到端冒烟 5/5 全部通过**，全部有机器可读证据。
> **上一环**：《项目构思方案 v0.2》判断"能接上、但要把 ACP 事件做成可靠的手机体验"。M0 交付的就是这个"可靠的底座"。

---

## 0. 一页纸结论

| 问题 | M0 的回答 | 证据 |
|---|---|---|
| Remote Agent 能不能真正驱动 Harness 干活？ | **能**。ACP 子进程 + JSON-RPC 2.0 over stdio，任务真的在电脑上执行、真的产出文件 | E2E 步骤 2、合同测试 4 |
| 能不能暂停/取消正在跑的任务？ | **取消能**（`session/cancel`，机制 `native`，Harness 明确确认 `stopReason=cancelled`，取消后会话可继续）；**暂停不能**（ACP 无此原语，能力矩阵如实报 `false`） | 合同测试 6、E2E 步骤 4 |
| 危险操作能不能等手机上的真人批准？ | **能**。`session/request_permission` → 转 `ApprovalRequest` → 手机决策 → 回 ACP；**批准会执行、拒绝不执行**，拒绝后任务正常结束而不是失败 | 合同测试 7、8；probe-approval |
| 断网/重连后历史还在吗？ | **在**。`session/resume` 恢复上下文（必须同一 cwd）；不同进程也能 `session/list` 列出持久化会话 | 合同测试 9、E2E 步骤 5 |
| 有没有假装实现的能力？ | **没有**。文件读写/终端/暂停/工作区列表在能力矩阵里明确为 `false`，对应方法抛 `UNSUPPORTED_CAPABILITY`，不伪造 | 合同测试 2 |
| 还剩什么没验证？ | 见 §6：H-13（per-session 权限 preset）、H-14（两进程同时 live 同一 session）、多设备并发、桌面画面 | — |

**对产品决策的影响**：《构思方案 v0.2》第 7 章中 **D-6（实时输出口径）** 建议按"步骤级实时"落定——M0 实测再次确认 ACP 的事件是**提交点粒度**（一次工具调用/一段消息完成后才推送，不是 token 级流）。

---

## 1. M0 目标与范围（来自《构思方案 v0.2》§4）

**目标**：把已实测的 ACP 通道封装成可复用、可测试、可演进的 `HarnessAdapter` 内核，为准入 M1（垂直切片：手机 ↔ 云端 ↔ Agent ↔ Harness 全链路）提供经过验证的地基。

**做**：
- DSH 安装发现与 ACP 进程启动（不硬编码路径、不注入密钥、可跨机器）；
- JSON-RPC 2.0 / NDJSON 传输层（分帧、超时、错误映射、进程退出清理）；
- ACP ↔ 领域事件映射（消息/思考/工具调用/用量）；
- 会话与轮次生命周期（单 ACP 进程、多 session、同会话串行、取消）；
- 审批桥接（ACP `request_permission` ↔ Agent 侧 `ApprovalRequest`/决策，10 分钟超时）；
- 能力矩阵（诚实上报）+ 单元测试 + 合同测试 + E2E 证据。

**不做**（留给 M1+）：云端/WSS 传输、数据库、手机 App、电脑端 UI、安装器、远程桌面、文件传输、多任务调度策略。

---

## 2. 交付物清单

### 2.1 代码（`agent/`，Node 24 原生跑 TypeScript，无构建步骤）

```
agent/
├── package.json              # 脚本：test / test:contract / e2e / probe:* / acl:* / typecheck
├── tsconfig.json             # strict + noUncheckedIndexedAccess（类型检查用，运行不依赖）
├── .gitignore
├── src/
│   ├── index.ts              # 统一导出
│   ├── infra/logger.ts       # 结构化日志（脱敏、内存 sink 便于测试）
│   ├── infra/redact.ts       # 密钥/令牌脱敏、文本截断
│   ├── harness/adapter.ts    # HarnessAdapter v1 接口 + 领域类型（与 REMOTE_AGENT.md §4.1 一致）
│   ├── harness/errors.ts     # 11 种错误码 + JSON-RPC 错误映射
│   └── harness/acp/
│       ├── acp-adapter.ts    # HarnessAdapter 的 ACP 实现（核心，约 900 行）
│       ├── jsonrpc.ts        # NDJSON 分帧 + JSON-RPC peer（请求/通知/服务端请求/超时）
│       ├── launcher.ts       # DSH 安装发现、环境构造、ACP 子进程启动、版本探测
│       └── mapper.ts         # ACP session/update → HarnessEvent
├── scripts/
│   ├── probe.ts              # 冒烟探针：连接 + 一次真实对话
│   ├── probe-approval.ts     # 审批定向探针（allow / reject）
│   ├── probe-cancel.ts       # 取消定向探针
│   ├── probe-reject-trigger.ts # 审批触发条件探针（工作区外写 / 外网 / 计划任务）
│   ├── e2e-smoke.ts          # 端到端冒烟（5 步，产出证据 JSON）
│   └── ensure-workspace-acl.ps1 # Windows 工作区权限检查/修复（生产安装器需固化）
├── tests/
│   ├── unit/                 # 36 个单测（jsonrpc/mapper/launcher/errors）
│   └── contract/             # 9 个合同测试（对真实 Harness）
├── evidence/                 # 机器可读证据（jsonl/json）
└── .workspaces/              # 测试用工作区（已 gitignore）
```

规模：约 **2,891 行**（其中 `src/` 1,665 行、测试与脚本 1,226 行），20 个文件，零运行时依赖。

### 2.2 证据（`agent/evidence/`）

| 文件 | 内容 |
|---|---|
| `probe-*.jsonl` | 真实对话探针事件流（output/usage/completed） |
| `contract-2026-10-31T04-27-46-505Z.jsonl` | **最终合同测试 9/9 通过**的完整事件流（34,913B） |
| `e2e-2026-10-31T04-28-48-670Z.json` | **最终 E2E 冒烟 5/5 通过**的结构化报告（每步 ok/detail/耗时 + 事件计数） |
| `probe-approval-*.json`、`probe-cancel-*.json`、`probe-reject-trigger-*.json` | 审批/取消/触发条件的定向探测记录 |

---

## 3. 关键实现

### 3.1 启动 Harness：不硬编码、不碰密钥

Harness 的 ACP 入口不是普通可执行文件，而是 Electron 应用内的 `cli.js`：

```
DeepSeek Harness.exe --expose-internals <安装目录>\resources\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js --profile acp
（环境变量 ELECTRON_RUN_AS_NODE=1）
```

`launcher.ts` 的处理：
- **安装发现**按优先级：显式参数 → `DSH_EXE`/`DSH_CLI` 环境变量 → `DSH_INSTALL_ROOT` → PATH 中的 `dsh.cmd` 上溯 → `%LOCALAPPDATA%\Programs\DeepSeek Harness`。
- **asar 陷阱**：`cli.js` 在 `app.asar` 归档内，Node 的 `fs.existsSync` 对归档内条目返回 false。`pathExists()` 遇到 `.asar` 段时改为校验归档文件本身存在，否则会误报"Harness 未安装"。
- **环境白名单**：只透传 PATH/HOME/TEMP/APPDATA/DSH_HOME 等必要变量，设 `ELECTRON_RUN_AS_NODE=1`、`NO_COLOR=1`；**不注入任何 API Key**（凭据留在用户自己的 `~/.dsh/.credentials.yaml`，由 Harness 自己读）。
- 版本探测：`DeepSeek Harness.exe ... --version` → `0.2.1-rc.5`（带缓存，避免每次轮询都起进程）。

### 3.2 传输层：NDJSON + JSON-RPC 2.0

`jsonrpc.ts` 提供两个部件：
- `NdjsonDecoder`：按 `\n` 分帧，兼容 CRLF、跨 chunk 切分、超长行保护（默认 1MB）。
- `JsonRpcPeer`：`sendRequest`（自增 id + 超时 + pending 关联）、`sendNotification`、服务端请求分发（`session/request_permission` 等；未知方法回 `-32601`）、错误对象转换、进程退出时拒绝所有 pending。

错误映射（`errors.ts`）把 ACP/JSON-RPC 的原始错误翻译成 Agent 的 11 种领域错误码，例如：`-32602` + "already in flight" → `SESSION_BUSY`；登录/凭据相关 → `HARNESS_NOT_LOGGED_IN`；"not found" → `SESSION_NOT_FOUND`。这样上层（未来的云端/手机）拿到的永远是可枚举、可解释的错误，而不是裸 JSON-RPC 文本。

### 3.3 事件映射：ACP 的 update → 手机的"看得懂"

`mapper.ts` 把 `session/update` 的 6 种 `sessionUpdate` 映射为 `HarnessEvent`：

| ACP `sessionUpdate` | 领域事件 | 说明 |
|---|---|---|
| `agent_message_chunk` | `output` / `answer` | **提交点粒度**：一段回答完成时才到，非 token 级 |
| `agent_thought_chunk` | `thinking` | 代理的思考过程，手机端默认折叠 |
| `tool_call` | `tool_call` | 含 `callId`、工具名、**完整 `rawInput`（含命令行）**——审批展示原始参数就靠它 |
| `tool_call_update` | `tool_call`（状态更新） | 状态归一化 + 结果摘要截断 2,000 字符 |
| `usage_update` | `usage` | 上下文用量（实测 `6425/1000000`） |
| 未知类型 | 忽略 | 为 rc 版本演进留容错 |

### 3.4 会话与轮次：单进程、多会话、串行

- **一个常驻 ACP 进程**，`session/new` 为每个任务建独立 session（工作目录由 `cwd` 固定）。
- 同一 session 的第二个 `prompt` 会收到 `-32602`——`AcpAdapter` 在客户端先抛 `SESSION_BUSY`，并用每会话的 `seq` 环形缓冲记录事件（默认 1,000 条，支撑断线补发）。
- 轮次结束用 `stopReason` 判定：`end_turn` → `completed`；`cancelled` → 取消结算；其它 → `failed`。
- `cancelTask`：发 `session/cancel` 通知并等 Harness 结算；正常时返回 `{ accepted: true, harnessAck: true, mechanism: 'native', detail: 'stopReason=cancelled' }`；10 秒未确认则断开进程并返回 `mechanism: 'signal_kill', harnessAck: false`（避免"取消假成功"）。

### 3.5 审批桥接：把 Harness 的权限请求变成手机上的"要不要允许"

```
Harness 发起 session/request_permission
  → AcpAdapter 构造 ApprovalRequest（approvalId、工具名、原始参数、风险等级、10 分钟后过期）
  → subscribe 把 approval_request 事件推给上层（未来的云端 → 手机）
  → 上层调用 decideApproval(approved / denied / expired)
  → AcpAdapter 回 ACP：{ outcome: { outcome: 'selected', optionId: 'allow-once' | 'reject-once' } }
```

要点：
- ACP 只给 **allow-once / reject-once**（没有"永久允许"），所以产品上不存在"记住这个选择"，每次都是明确的一次性授权。
- 拒绝**不会**把任务标成失败：工具不执行，模型解释后以 `end_turn` 正常结束——与 v0.2 §8.3 的《审批终态权威表》一致。
- 10 分钟超时回 `cancelled`，上层记为 `expired`，符合"超时按拒绝处理"的契约。

### 3.6 能力矩阵：宁可报 false，也不假装

`getCapabilities()` 返回 16 项能力，全部有实测依据：

| 能力 | 值 | 依据 |
|---|---|---|
| chat / streaming / structuredResult / cancel / continue / sessions / sessionResume / toolCallDetail / approvalIntercept / modelSwitch / usageReport | ✅ true | 合同测试与 E2E 逐项验证 |
| pause | ❌ false | ACP 协议无暂停原语；产品上不做"假暂停" |
| workspaceList / fileRead / fileWrite / terminal | ❌ false | ACP 无对应客户端方法；文件能力由 Agent 本地实现（v0.2 §2.3 L0 层），M0 不冒充 |

---

## 4. 验证结果

### 4.1 单元测试（36/36）

```
node --test tests/unit/*.test.ts
→ tests 36 / suites 11 / pass 36 / fail 0 / duration 158ms
```

覆盖：跨 chunk/CRLF/超长行分帧、请求 id 关联与超时、错误映射、通知订阅/退订、服务端请求回包、未知方法 `-32601`、进程退出清理、安装发现（含 asar 校验）、密钥不透传、错误码 retryable 语义。

### 4.2 合同测试（9/9，对真实 Harness）

```
node --test tests/contract/acp-contract.test.ts
→ tests 9 / pass 9 / fail 0 / duration 28,292ms
```

| # | 用例 | 耗时 | 结论 |
|---|---|---|---|
| 1 | `initialize` 返回 `protocolVersion=1` | 1.1ms | 协议版本锁定 |
| 2 | 能力矩阵诚实上报 | 0.6ms | 文件/终端为 false |
| 3 | `session/list` 可用、`session/new` 固定 cwd | 216ms | 工作目录正确 |
| 4 | 真实 turn：prompt → output → completed | 789ms | 真实执行 |
| 5 | 同 session 多轮上下文连续 | 664ms | 多轮对话成立 |
| 6 | 工具执行中 `session/cancel` → `cancelled`，会话可继续 | 2,559ms | 取消可用 |
| 7 | 审批 allow-once：批准 → 命令执行 → 文件写入 | 9,180ms | 审批链路通 |
| 8 | 审批 reject-once：拒绝 → 工具不执行 → `end_turn` | 9,719ms | 拒绝≠失败 |
| 9 | 断开重连 `session/resume` 上下文仍在 | 3,209ms | 断线可恢复 |

> 用例 7/8 的确定性做法：让模型用 **pwsh 写"工作区外"路径**触发沙箱权限升级 → 必出审批；再按决策回 `allow-once` / `reject-once`。这是本轮排查出的关键工程经验（见 §5.1）。

### 4.3 端到端冒烟（5/5，结构与手机端将收到的体验一致）

```
node scripts/e2e-smoke.ts
→ E2E PASS，证据：agent/evidence/e2e-2026-10-31T04-28-48-670Z.json
```

| 步骤 | 内容 | 耗时 | 结果 |
|---|---|---|---|
| 1 | 连接 Harness（ACP initialize） | 1.6s | version=0.2.1-rc.5 |
| 2 | 真执行：Harness 在工作区创建 `hello.txt` | 1.8s | 内容 `hello from e2e`，`end_turn` |
| 3 | 审批：工作区外写入 → 请求审批 → 批准 | 8.6s | 文件写入 `e2e-ok` |
| 4 | 取消：长命令执行中 `session/cancel` | 2.8s | `native`、`harnessAck=true`、会话正常 |
| 5 | 续跑：断开重连 + `session/resume` | 2.6s | 上下文命中 `hello.txt` |

事件计数：`usage×8、tool_call×4、tool_call_update×4、output×4、completed×4、thinking×4、approval_request×1`。

---

## 5. 实测新发现（对《构思方案 v0.2》的增量）

### 5.1 审批不是"想触发就能触发"——这直接影响产品设计

- **工作区内的普通写操作会被沙箱自动放行，不触发审批**（模型直接 `write` 或 `pwsh Set-Content` 就完成了）。只读命令（`whoami` 等）同样自动放行。
- **能稳定触发审批的是"工作区外写入"**（沙箱权限升级）：此时 Harness 发 `session/request_permission`，`options=["allow-once","reject-once"]`，审批里带着真实命令行参数。
- **模型行为不确定**：被沙箱拒绝后，模型可能直接放弃并解释"没有权限"，而不是主动申请升级。因此 Agent 侧对"等待审批"必须：① 允许审批与"轮次已结束"竞争；② 超时兜底；③ 不把"模型没申请审批"误判成系统故障。
- **对产品的含义**：v0.2 §2.7 的"六道闸门"里，**风险分级不能只依赖 Harness 自己的审批**——凡"工作区外"或高危动作，Remote Agent 应在下发前做 pre-flight 拦截并主动请求手机授权，而不是"等 Harness 弹审批"。这与 v0.2 §8.3 的"in-flight 为主 + pre-flight 兜底"一致，M0 为 pre-flight 提供了必要性证据。

### 5.2 Windows 工作区权限：一个会"静默废掉 shell 工具"的环境坑

- 现象：工作区内所有 `pwsh` 命令失败，报 `Error: SetNamedSecurityInfoW failed (Win32 5): grantWrite(<workspace>)`，但模型对话、文件写入正常。
- 根因：DSH 的 shell 沙箱在**每次执行命令前**要对该工作区目录做一次 ACL 授权（`SetNamedSecurityInfoW`）；目录 ACE 只有 `Authenticated Users:(I)(M)`，缺 `WRITE_OWNER/WRITE_DAC`，于是授权被拒。
- 修复：对工作区父目录加**可继承的** FullControl：`icacls "<workspaces>" /grant "<user>:(OI)(CI)F"`，之后新建子目录自动继承，命令恢复正常。
- **对生产的含义**：① Remote Agent 安装/首次启动时应对"工作区根目录"做权限检查与修复（已固化为 `scripts/ensure-workspace-acl.ps1`，支持 `-Verify`/`-Apply`）；② 工作区建议放在用户目录（如 `C:\Users\<user>\.deepseek-remote\workspaces`），避免把项目盘符的权限继承问题带进来；③ 安装器应把这一步做成"一键修复"而不是让用户看 Win32 5 报错。

### 5.3 取消是"真取消"

`session/cancel` 由 Harness 原生处理（`mechanism=native`），返回 `stopReason=cancelled`，且**取消后同一会话可以继续对话**。这消解了 v0.2 里"取消只能杀进程"的担忧；杀进程只作为 10 秒未确认时的兜底。

### 5.4 其他

- **模型/推理强度可切换**：`session/new` 返回 `configOptions`（`model` 当前 `["deepseek-official","deepseek-v4-flash"]`、`reasoning_effort` 当前 `high`，可选 `off/low/high/max`），并用 `session/set_config_option` 生效 → 手机端"换模型/调推理强度"有真实接口依据。
- **会话是裸 UUID**，`session/resume` 要求 cwd 与创建时一致；`session/list` 可跨进程列出持久化会话（存储位置 `~/.dsh/sessions`）。
- **ACP 进程 stderr 有模型列表等诊断日志**（`loaded 2 model(s)`）：生产采集需按 v0.2 §7 的脱敏规范过滤，避免把账号信息带出去。
- **事件是提交点粒度**：一次工具调用/一段消息完成后才推送。生产上不要承诺"逐字实时"，应宣传"**步骤级实时**"（与 D-6 建议一致）。

---

## 6. 能力边界与遗留问题

### 6.1 仍缺、且 M0 明确不假装的

| 缺口 | 现状 | 计划 |
|---|---|---|
| 暂停/恢复任务 | ACP 无原语 | 产品上明示不支持（v0.2 G-4）；若要"暂停"，只能在 Agent 侧排队而非冻结执行 |
| 文件读写/终端 | ACP 无客户端方法 | Agent 本地实现（L0 层），带路径白名单；M4 |
| 工作区列表 | ACP 无方法 | Agent 本地扫描 + 白名单（v0.2 §2.3） |
| token 级流式 | ACP 提交点粒度 | 不承诺；步骤级实时（D-6） |
| 桌面画面 | 未接 | M4（ffmpeg + H.264 + WebRTC/自定义传输） |

### 6.2 未验证项（M1 需继续探）

| 编号 | 问题 | 计划 |
|---|---|---|
| H-13 | per-session 权限 preset 能否随 `session/new` 传入 | M1 探针（影响"低风险自动允许"的产品形态） |
| H-14 | 两个进程同时 live 同一 session 会怎样 | M3 双进程实验（影响"桌面在用时手机接入"） |
| — | 多设备并发（手机 + 电脑同时操作） | M2/M3 |
| — | ACP rc 版本升级的回归 | CI 合同测试作为回归门（已可一键跑） |
| — | 审批 10 分钟超时的产品默认值 | 待 D-8 拍板后调整 |

### 6.3 M0 内部的小妥协（已记录，不隐藏）

- 模型行为不确定性导致合同测试 7/8 用"3 次尝试 + 竞争等待"的写法；这是**测试的鲁棒性措施**，不改变生产语义（生产中等待审批是真实的人在操作）。
- probe 脚本与合同测试用了本机真实 Harness 安装与真实账号（`~/.dsh/.credentials.yaml`），没有伪造任何响应。
- `typecheck` 需要先 `npm install` 装 devDeps（typescript/@types/node），M0 未安装、未跑全量类型检查——运行时已知类型一致（Node 类型剥离只删类型不检查）。M1 建议纳入。

---

## 7. 对 v0.2 计划的修正建议

1. **M0 工作量估算**：v0.2 写"3 人日工程化封装"。本轮完成的是**内核 + 测试 + 证据**（约 2,900 行、20 文件），尚未包含 Electron 壳/安装器/单实例/自启/电脑端 UI/日志上报。结论：**3 人日对"内核+测试"是合理甚至偏保守的**，但"可交付给普通用户的电脑端 Agent"仍需 M4/M5 的打包工作——建议在 MVP 计划里把"安装器 + 首次运行引导（含 ACL 修复）+ 崩溃恢复"明确列为 M5 交付项。
2. **D-6（实时口径）**：建议按"步骤级实时"拍板，不承诺 token 级。
3. **D-8（审批通知）**：M0 证明审批等待可长达数分钟（模型规划 + 执行前等待），手机锁屏/后台收不到通知会直接卡死任务——**建议采纳 B 方案（前台服务 + 本地通知）**，这是体验可用性的硬需求，不是优化项。
4. **工作区权限**：把 `ensure-workspace-acl.ps1` 的逻辑并入安装器/M1 启动自检；工作区默认放用户目录。
5. **审批模型**：产品上要区分"Harness 自己会放行的工作区内操作"与"需要手机确认的高风险操作"，pre-flight 拦截不是可选项。

---

## 8. M1 开工清单（建议顺序）

**M1 目标（来自 MVP_AND_ROADMAP.md）**：垂直切片——手机（或模拟客户端）→ Java 云端 → Remote Agent → Harness，全链路跑通一次真实任务，含实时事件与取消。

| # | 任务 | 产出 | 验收 |
|---|---|---|---|
| 1 | Transport 抽象 + WSS 客户端骨架（本机回环） | `src/transport/*`（wss-client、backoff、send-queue、frame-codec） | 与本地回显服务互发信封、断线自动重连 |
| 2 | 协议信封编解码 + `conversationId/taskId/seq/v` + at-least-once 去重 | `src/protocol/*` | 单测：重复/乱序/缺号补偿 |
| 3 | AcpSessionManager：单进程多会话、队列、并发 2、`SESSION_BUSY` 映射 | `src/domain/task-service.ts` | 两任务并发、第三任务排队；同会话串行 |
| 4 | 任务状态机 7 态 + 事件上报（output/tool_call/approval/completed/failed/cancelled） | 同上 + `src/protocol/events.ts` | 状态迁移单测 + 合同测试复用 |
| 5 | 审批桥接（in-flight 5 态权威表）+ 超时 + 急停骨架 | `src/domain/approval-service.ts`、`estop-service.ts` | 审批 allow/deny/timeout 三路 |
| 6 | 日志脱敏 + 诊断包（版本、能力、最近错误） | `src/infra/*` | 扫描无密钥/无路径泄露 |
| 7 | 契约测试扩展（信封/重连/补偿）+ CI 脚本 | tests | `npm run test:all` 一键全绿 |
| 8 | Java 云端最小骨架（auth + device + ws 路由）+ Flutter 只读首页 | 另建 `server/`、`app/` | 手机看到任务状态与输出 |

**M1 完成后 M0 合同测试即为 Harness 适配层的回归门**：任何 ACP 升级先跑 `npm run test:contract`，红则阻断发布。

---

## 9. 复现命令

```powershell
cd "<项目根>\agent"

# 0) 工作区权限自检/修复（首次或报 Win32 5 时）
npm run acl:check
npm run acl:fix

# 1) 单元测试（不依赖 Harness）
node --test tests/unit/jsonrpc.test.ts tests/unit/mapper.test.ts tests/unit/launcher.test.ts tests/unit/errors.test.ts

# 2) 合同测试（对真实 Harness，约 30 秒）
node --test tests/contract/acp-contract.test.ts

# 3) 端到端冒烟（真实任务 + 审批 + 取消 + 续跑，约 20 秒）
node scripts/e2e-smoke.ts

# 4) 只连接并跑一句对话
node scripts/probe.ts
```

前提：本机已安装并登录 DeepSeek Harness（`dsh --version` 可得 `0.2.1-rc.5`），Node ≥ 24。

---

*本报告的证据均在 `agent/evidence/`，可独立复核；结论以实测为准，未验证项已在 §6.2 显式列出。*
