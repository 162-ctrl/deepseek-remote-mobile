# M4.11 报告：工作区页不再「看起来项目全丢了」

## 1. 一句话结论

DSH 重开后电脑端会话列表会被清空/重建（见 M4.10 第 2 节：非当前会话的日志只有 header，Host 列表里看不到），而手机端「工作区」页的卡片是**从会话列表派生的**——列表一空，9 个授权目录里只剩一两个卡片，用户看到的就是「为什么又看不到所有的项目了」。M4.11 让**每个授权目录自己占一张卡**（没有会话时标「暂无会话」，点进去照常新建会话 / 看存档 / 浏览文件），并让存档分组在任何状态筛选下都能找到（App 0.4.11+38）；电脑端插件 0.2.19 顺手挡掉存档里的测试临时目录，并修掉一个会让插件启动失败的 `statSync` 未导入问题。

## 2. 起因与根因

| 现象（用户反馈） | 根因 | 修法 |
|---|---|---|
| 「为什么又看不到所有的项目了」：工作区页只剩「全部 1」和一两个卡片 | `TasksScreen` / `WorkspaceScreen` 的卡片只来自 `live.tasks`（`GET /desktop/tasks`）。DSH 重开后 Host 只列出「已物化」的会话，列表一空，目录就只剩顶部胶囊，卡片区空白 | 新增 `_idleWorkspaces` + `_WorkspaceCard`：电脑端授权的每个目录，只要当前没有会话/存档，就铺一张「暂无会话」卡 |
| 点「进行中 / 等待授权 / 失败」后，刚消失的会话找不到 | M4.10 的存档分组只在筛「已完成」或不筛时显示 | 去掉这一限制：状态筛选描述的是**电脑上正在跑**的会话，存档组标题自己已写明「电脑上已经看不到」，不该被状态筛选挡掉 |
| 存档列表里混进几百条测试会话（`agent\.m1ws`、`agent\.workspaces\contract-*`） | `scanSessionsOnDisk` 无差别吸收磁盘上的所有会话目录 | 新增 `isScratchWorkspace()`：路径分段命中 `.m1ws` / `.workspaces` / `.e2e` / `.tmp` 等，或目录名以 `contract-` / `e2e-` / `probe-` 开头 → 不吸进存档、也不出现在列表里（存量记录不删，只是不展示） |
| 插件有概率启动失败 `statSync is not defined` | M4.11 的 `resolveUploadDir` 用到了 `statSync`，`lib/index.js` 的 `node:fs` 导入行里没有它 | 导入行补 `statSync`（`node --check` 抓不到，只有运行到该分支才抛） |

## 3. 手机端改动（App 0.4.11+38）

- `app/lib/screens/tasks_screen.dart`
  - 新增 `List<String> get _idleWorkspaces`：`live.workspaceRoots` 里、当前筛选工作区内**既没有会话也没有存档**的目录；筛「进行中 / 等待授权 / 失败」时返回空（那是会话状态筛选）。
  - 列表在任务卡片之前先铺这些目录的 `_WorkspaceCard`（图标 + 目录名 + `暂无会话` 徽标 + 完整路径 + 「点进去可以在电脑的这个目录里新建会话」），点击进入 `WorkspaceScreen`。
  - 空态判断改为 `tasks.isEmpty && _idleWorkspaces.isEmpty && _hiddenArchived.isEmpty` 才显示「这个筛选下还没有任务」。
  - `_hiddenArchived` 去掉「只有已完成筛选才显示」的限制。
- 新增 `app/test/tasks_m4_11_test.dart`（6 例）：电脑列表为空时每个授权目录占一张卡、点空卡进工作区页并能新建会话、有会话的目录不重复铺空卡、只有存档的目录算「有内容」、筛「进行中」不列空目录、筛「进行中」时已消失的存档仍列出来。

## 4. 电脑端插件（0.2.19）

- `lib/index.js`
  - 新增 `ARCHIVE_SKIP_SEGMENTS`（`.m1ws`、`.workspaces`、`.e2e`、`.tmp`、`.cache`、`node_modules`、`.dart_tool`）与 `ARCHIVE_SKIP_PREFIXES`（`contract-`、`e2e-`、`probe-`、`reject-trigger-`），以及 `isScratchWorkspace(path)`（按 `[\\/]` 分段比较，不误伤名字里带这些字样的正常项目）。
  - `scanSessionsOnDisk()` 吸收磁盘会话前判 `isScratchWorkspace(record.workspace)`；`listArchivedSessions()` 再挡一层（存量记录已写进 `session-archive.json` 的也不展示）。
  - `resolveUploadDir` 依赖的 `statSync` 补进 `node:fs` 导入。
- 新增 `dsh-plugin-m1/test/archive-scratch.test.js`（4 例）：`isScratchWorkspace` 的 10 个临时目录、12 个真实工作区（含 `D:\Projects\测试`、`C:\Users\user`、`D:\Projects\照片`）、空值不抛异常、扫描与列表都接上了过滤（源码层面断言）。
- `package.json` → **0.2.19**；`tools/verify-plugin-m4.ps1` 门槛同步 0.2.19（3 处）。

## 5. 验收证据

| 项 | 结果 |
|---|---|
| `flutter test` | **327/327 全部通过**（321 + M4.11 新增 6） |
| `flutter analyze` | **24 issues，0 error**（均为历史 warning/info） |
| 插件单测 | `node --test 'test/*.test.js'` **30/30**（26 + 4） |
| 语法检查 | `node --check lib/index.js`、`lib/server.js` 均通过 |
| release APK | 见下方「产物」 |
| 版本 | App `0.4.11+38`（versionCode 38）；插件 `0.2.19` |
| 自检脚本 | `tools/verify-plugin-m4.ps1` 门槛升到 0.2.19，仍为 **14 项** |

## 6. 生效步骤

1. **完整退出 DSH 桌面应用再打开**（加载插件 0.2.19）。存档列表里的测试临时目录会立刻消失（文件里的存量记录不删，只是不展示）。
2. 跑自检：`powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-plugin-m4.ps1`，期望 **14/14 PASS**（`-NoCreate` 只跑只读项）。
3. 手机装 `dist\DeepSeek-Remote-latest.apk`（0.4.11-m4.11 / versionCode 38，可覆盖安装）。
4. 打开「工作区」页：电脑端授权过的每个目录都应有卡片，标「暂无会话」的点进去可以直接新建会话。

## 7. 已知限制与下一步

- 「暂无会话」卡片只反映**当前**电脑列表；电脑上真删掉目录后，要等 `GET /desktop/workspaces` 刷新才会消失（5 秒 TTL 的注册表缓存 + 手机端 5 秒轮询）。
- 存档只能看不能继续发指令（M4.10 的既定行为）。
- 本次仍未真机复测（`adb devices` 无设备），页面行为由 widget 测试覆盖。
- 下一步候选：① 工作区卡片显示「N 个存档会话」与最近活动时间；② 存档「恢复成新会话」；③ 把 `plugin-market` 的索引源写进 profile，让手机端插件市场有内容。
