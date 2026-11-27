# M4.49 便携版 DSH 下 Agent 起不来 → 手机端「工作区怎么没有了」

**一句话**：电脑端 Agent 子进程要 spawn `dsh --profile acp`，但它只认「PATH 里的 dsh.cmd」「`%LOCALAPPDATA%\Programs\DeepSeek Harness`」这类常规安装位；这台机器是**便携版** `<DSH 安装目录>`，五条发现路径全落空 → Agent 每次启动都报「未找到 DeepSeek Harness 安装」→ 手机端 `device.status` 里没有工作区目录，二级页就只剩一句「电脑端还没有配置工作区（M1_WORKSPACE_ROOT）」。

## 之前的样子（2026-11-23 22:13 用户截图）

- 工作区**主 Tab** 一切正常：两份项目卡（`D:\Projects\示例项目A`、`<项目根>`）、会话、直播中都在。
- 点右上角文件夹进「工作区」二级页，却是空态：「电脑端还没有配置工作区（M1_WORKSPACE_ROOT）」。同一台电脑上两处说法互相矛盾。
- 现场数据：`GET /api/v1/pair/info` → `agentOnline:false`；进程表里没有任何 `agent/scripts/serve.ts`；手动跑同一个入口复现
  `ERROR serve m1.agent.fatal message="未找到 DeepSeek Harness 安装（可通过 DSH_INSTALL_ROOT 指定）"`。
- agent 的发现顺序（`agent/src/harness/acp/launcher.ts` `discoverDshInstall`）：显式参数 → `DSH_EXE`+`DSH_CLI` → `DSH_INSTALL_ROOT` → PATH 的 `dsh.cmd` → `%LOCALAPPDATA%\Programs\DeepSeek Harness`。实测：`DSH_INSTALL_ROOT`/`DSH_EXE` 为空、PATH 里没有 `dsh.cmd`、`%LOCALAPPDATA%\Programs\DeepSeek Harness` 不存在。
- 带 `DSH_INSTALL_ROOT=<DSH 安装目录>` 手动跑一次：`acp.connected version=0.2.2-rc.5`、`agentOnline:true`、11 个工作区根全部刷出来 —— 根因确认。

## 改动

| 文件 | 改动 |
|---|---|
| `dsh-plugin-m1/lib/dsh-install.js`（新增） | `resolveDshInstallRoot()`：显式 `DSH_INSTALL_ROOT` → `dirname(process.execPath)`（Electron 主进程就是 `DeepSeek Harness.exe`），要求目录下有 `resources/app.asar`；用 `node` 起的开发态不乱猜，返回空串交给 agent 自己发现 |
| `dsh-plugin-m1/lib/supervisor.js` | 构造参数加 `dshInstallRoot`；子进程环境里带 `DSH_INSTALL_ROOT`；首次启动多打一行「DSH 安装目录：…」/「没从进程路径推出…」，下次出问题看日志就能定位 |
| `dsh-plugin-m1/lib/index.js` | `apply` 里 `dshInstallRoot: resolveDshInstallRoot()` |
| `agent/src/harness/acp/launcher.ts`（`dsh-plugin-m1/agent` 与项目根 `agent/` 两份副本同步） | 新增 `installRootFromParentExe()`：Windows 下用 `Get-CimInstance Win32_Process` 问父进程的可执行文件，名字是 `DeepSeek Harness.exe` 就取 `dirname`；排在第五位兜底，失败/超时/非 Windows 一律返回 null，不影响原有顺序 |
| `dsh-plugin-m1/package.json` | 0.2.33 → 0.2.34 |
| `dsh-plugin-m1/test/dsh-install-root.test.js`（新增 7 例） | 便携版路径推导 / 开发态不乱猜 / 没有 `app.asar` 返回空 / 显式 env 优先且不校验目录 / supervisor 真的把变量塞进子进程 / index.js 真的调了解析 |
| `dsh-plugin-m1/test/agent-parent-discover.test.js`（新增 4 例） | 父进程不是 Harness 时返回 null、非 Windows 返回 null、非法 PID 不探测、兜底调用排在抛错之前 |

**为什么改两条路**：插件侧注入环境变量是主路径，但改完要重载插件才生效；agent 侧兜底不依赖重载——supervisor 失败后会指数退避（最长 30s）重启，每次重启都重新读盘上的 `launcher.ts`，所以热修能当场生效。这次就是靠 agent 侧兜底在 10 秒内救回来的。

## 验收

- 插件测试 **157/157 通过**（原 146 + 新增 11）。
- 反证：把 `resolveDshInstallRoot()` 在显式 env 判断之后立刻 `return ''`，用例「从 Electron 主进程路径推出安装根（便携版 <DSH 安装目录>）」失败；恢复后通过。
- 现场证据（修复后、未重载插件）：supervisor 下一次重试成功 → `serve.ts` pid 33512，父进程 `DeepSeek Harness.exe` pid 24532；`GET /api/v1/health` → `agentOnline:true`；agent 日志 `relay.agent.workspace_roots.updated` 刷成 11 个根（含两个项目目录、课程作业课程目录、示例项目D、示例项目C、示例项目E、示例项目B）。
- 手机侧：重开 App / 让 WS 重连一次即可拿到新的 `device.status`，工作区列表恢复。

## 限制与下一步

- 手机端「工作区」二级页在 **已连上但 Agent 掉线** 时仍然显示「电脑端还没有配置工作区（M1_WORKSPACE_ROOT）」，没有告诉用户「是没连上」——这是这次让人以为「工作区没了」的直接原因，下次改成掉线态 + 重试入口（`liveStore.deviceOnline` 已经有这个信号，`ProjectsScreen` 还没用）。
- `/api/v1/health` 里的插件版本要重载插件才更新（0.2.34 会在下次重启后显示）。
- 项目根 `agent/` 与 `dsh-plugin-m1/agent/` 是两份副本，这次只同步了 `launcher.ts`；以后改 agent 记得两边一起改。
