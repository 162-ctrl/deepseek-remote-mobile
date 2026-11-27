# M4.20 每次开机后手机「工作区」又空了

一句话结论：Agent 是插件在 DSH 刚启动、工作区注册表还没就绪时拉起来的，那一刻插件
只能把 `homedir()` 递进去；而 Agent 把这些目录在进程启动时定死（`private readonly`），
之后直到进程重启都不会再读一次——所以每次开机，手机上「工作区」就只剩一个
`C:\Users\user`，项目卡和会话全部消失。修法分两半：插件给 Agent 开一条只能 Agent 调的
`GET /api/v1/agent/workspaces`，Agent 连上（以及之后每 20 秒）来取一次真实目录，变了就
覆盖并补发 `device.status`；顺带把授权目录**去重**（注册表会通过 `list()` 和 `entities`
两条路吐出同一批目录，之前上报了 18 条，手机上的项目卡因此会重影）。

## 起因

用户反馈：「每次开启之后工作区里面的内容又没了」，截图里工作区页只剩两张卡——
`user`（`C:\Users\user`，标注「暂无会话」）和正在执行的 `deepseek手机端`。

## 三层证据

| 层 | 取证 | 结果 |
| --- | --- | --- |
| 手机 | 截图里的文案「暂无会话」「点进去可以在电脑的这个目录里新建会话」 | 这两个字符串在 `app/lib` 里**已不存在**（M4.13 换成了「空项目」和项目分组卡）→ 手机上装的还是 ≤0.4.12 的旧 APK，卡片形态本身就是旧的 |
| 插件（HTTP） | 真手机 token 调 `GET /api/v1/desktop/workspaces` | **10 条目录全在**，`/desktop/tasks` 6 条、`/desktop/archive/sessions` 75 条 → 后端数据是好的，坏的是「Agent 上报给手机的目录」 |
| Agent（WS） | 用 app token 连 `ws://127.0.0.1:8787/ws?role=app`，读它收到的 `device.status` | `workspaceRoots(18)`：同一批 9 个目录各出现两遍 → 既印证了「Agent 的这份清单和插件不一致」，也 exposes 了去重缺失 |

## 根因

1. **拉起时机**：`dsh-plugin-m1/lib/index.js` 在 `apply` 里 `supervisor.start()`，此时
   `workspaceRegistry`（async Service）通常还没就绪；`resolveWorkspaceRoots()`
   （`dsh-plugin-m1/lib/index.js:182`）于是退回 `[homedir()]`。
2. **Agent 定死**：`dsh-plugin-m1/agent/scripts/serve.ts` 的 `parseWorkspaceRoots()` 在
   进程启动时把 `M1_WORKSPACE_ROOTS` 解析成常量，`RelayAgent` 里两个字段还是
   `private readonly`，`buildDeviceStatus()` 每次都上报这份旧值。
3. **永远不会自愈**：插件自己的授权目录有 5 秒 TTL 缓存（`workspaceRootsNow()`），
   注册表就绪后它自己会恢复成 10 条；但 Agent 不会重读，于是「插件是对的、Agent 是错的」
   一直保持到进程重启。
4. **去重缺失**：`rootsFromRegistry()` 同时从 `list()` 和 `entities` 读，`normalizeRoots()`
   只过滤空值不去重 → 上报 18 条。

## 改动

### Agent（`agent/`，插件包内另有一份 `dsh-plugin-m1/agent/` 必须同步）

- `agent/src/relay/relay-agent.ts`
  - `workspaceRoot` / `workspaceRoots` 去掉 `readonly`；
  - 新增 `setWorkspaceRoots(next): boolean`：归一化（去空、转绝对路径、Windows 大小写
    不敏感去重）→ 与现值相同直接返回 `false`（避免每 20 秒刷一次手机）→ 变了就覆盖、
    记 `relay.agent.workspace_roots.updated` 日志，并在 `started` 时补发 `device.status`；
  - 新增模块级 `normalizeWorkspaceRoots()` / `sameWorkspaceRoots()`。
- `agent/scripts/serve.ts`
  - 新增环境变量 `M1_WORKSPACE_REFRESH_MS`（默认 20000，`0` 关闭）与 `parseRefreshInterval()`；
  - `main()` 里 `await agent.start()` 之后定义 `refreshWorkspaceRoots()`：带 agent token
    去 `GET ${SERVER_URL}/api/v1/agent/workspaces`，取 `workspaces[].path` 交给
    `agent.setWorkspaceRoots()`；失败只打 `debug`，不影响主链路；
  - `client.onOpen()` 里立刻调一次（重连后马上对齐），再起一个 `setInterval` 每 20 秒一次；
    `shutdown()` 里 `clearInterval`。
- `agent/tests/unit/workspace-roots.test.ts`（新增 4 例）：覆盖 homedir→真实目录并补发
  status、目录没变不重复上报、空数组不覆盖、大小写去重。
- `agent/package.json` 的 `test` 脚本改为 `node --test "tests/unit/*.test.ts"`（原来只列了
  4 个文件，`workspace-fs.test.ts` 和新增的这个都没被跑到）。

### 插件（`dsh-plugin-m1/`，0.2.24 → 0.2.25）

- `lib/server.js` 新增 `GET /api/v1/agent/workspaces`：`hub.authorizeToken(token, 'agent')`
  才放行，返回和手机端同一份 `workspaces`。手机 token 调它 401，Agent token 调
  `/api/v1/desktop/workspaces` 也仍然 401（两个角色互不越界）。
- `lib/index.js` 的 `normalizeRoots()` 加去重（按 `canonicalPath()`，保留首次出现顺序，
  首个仍是默认工作区）。
- `test/agent-workspaces.test.js`（新增 3 例，真起一个 http server）：agent token 读得到、
  app token/匿名 401、手机端 `/desktop/workspaces` 行为不变。

## 验收

| 项目 | 结果 |
| --- | --- |
| Agent 单测 | `node --test "tests/unit/*.test.ts"` → **60/60 PASS** |
| 插件单测 | `node --test "test/*.test.js"` → **69/69 PASS**（66 + 3） |
| 去重效果 | 热加载前 `device.status.workspaceRoots` **18 条**（9 个目录各两遍）→ 热加载后 **10 条**（无重复） |
| 竞态自愈 | 临时把插件拉起 Agent 时的目录改成 `[homedir()]` 模拟开机竞态：Agent 起来时上报 **1 条**（`C:\Users\user`），`client.onOpen` 的那次刷新立刻把它改成 **10 条**；探针日志显示每 20 秒一次 `rows=10 paths=10` |
| 鉴权边界 | `agent → /agent/workspaces` 200；`agent → /desktop/workspaces` 401；`app → /agent/workspaces` 401；`app → /desktop/workspaces` 200 |
| 线上版本 | `GET /api/v1/health` → `{"status":"ok","version":"0.2.25","agentOnline":true}` |

## 踩坑（重要）

- **`dsh-plugin-m1/agent/` 是运行时真正跑的那一份**：`dsh-plugin-m1` 在 profile 里是指向
  项目目录的 **junction**，但插件里 `agentDir = join(bundleRoot, 'agent')` 指向
  `dsh-plugin-m1/agent/`（项目根那个 `agent/` 只是 14 个运行时文件的来源副本之外的另一份）。
  这次先只改了根目录的 `agent/`，热加载后日志证明「刷新那段根本没跑到」——**改 Agent 代码
  必须同时落到 `dsh-plugin-m1/agent/`**。
- 定位手段：`tools/watch-device-status.mjs`（用手机 token 连 WS，打印 `device.status` 里
  的 `workspaceRoots`）比读日志快得多；Agent 的 stdout 被 supervisor 吞进 DSH 控制台，
  磁盘上没有日志文件。

## 下一步候选

- 手机端「工作区」在 `workspaceRoots` 变化时给个轻提示（现在会静默长出卡片）。
- 把 `M1_WORKSPACE_REFRESH_MS` 暴露成插件配置项，方便排障时关掉。
- `tools/verify-project-sync.ts` 里加一条「`agent/` 与 `dsh-plugin-m1/agent/` 同名文件哈希一致」的检查，避免这次的坑再踩一次。
