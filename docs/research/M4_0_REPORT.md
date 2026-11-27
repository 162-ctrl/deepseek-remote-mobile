# M4.0 交付报告：工作区整改 + 手机端新建工作区

- 日期：2026-11-13
- 版本：手机端 **0.4.1-m4.0（versionCode 27）**；DSH 插件 **0.2.9**（需重启 DSH 生效）
- 状态：代码与单测完成、APK 已构建；插件侧 **等待重启 DSH 后生效**（运行中的 8787 仍是 0.2.8）

## 1. 一句话结论

M4.0 把「工作区」从只读列表做成了可用的一级入口：任务页工作区胶囊常驻并在末尾提供**新建工作区**（走电脑端 `POST /api/v1/desktop/workspaces`，在第一个授权根目录下建子目录），工作区页重做（会话按最后活跃倒序 + 状态徽标 + 消息数/时间、AppBar 新建会话/浏览文件/刷新、空态与输入条引导先建会话）；
同时修掉一个会让「我的 → 工作区」突然变空的隐性 bug：Hub 连上手机时先发的**骨架 `device.status`**（不带 `workspaceRoots`）会把 Agent 上报的目录清空。
手机端 **flutter test 255/255**，release APK **71,621,290 字节**（`versionCode=27`、`versionName=0.4.1-m4.0`）。

## 2. 起因与范围

用户此前要求「继续上一步改造」：仓库里插件端已经加了新建工作区接口（`server.js` 的 `POST /api/v1/desktop/workspaces` 与 `index.js` 的 `createDesktopWorkspace()`），但 App 从未调用；`workspace_screen.dart` 还是 M3.6 之前的旧版（只读列表、状态一律显示「正在执行 / 已完成」、底部发送只能发到列表第一项且无任何提示）。M4.0 补齐这条链路并顺带修掉工作区目录被骨架状态清空的问题。

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 1 | 手机端无法建工作区 | App 没有调用插件已有的 `POST /api/v1/desktop/workspaces` | `history_api.createDesktopWorkspace()` + `live_store.createDesktopWorkspace()` + 新建对话框 + 任务页「＋ 新建工作区」胶囊 |
| 2 | 工作区页信息不全 | 旧页只判断 `running`，无消息数/时间/排序；没有新建会话与浏览文件入口 | 重写 `workspace_screen.dart`：`sortDesktopTaskItems` 倒序、`TaskStatusBadge`、`N 条消息 · 最后活动时间`、AppBar 三个动作、FAB「新会话」、空态引导 |
| 3 | 工作区胶囊只在 ≥2 个工作区时出现，且必须已有会话 | 旧 `_buildWorkspaceChips()` 只从 `live.tasks` 收集且 `paths.length < 2` 时整块隐藏 | 先收 `live.workspaceRoots` 再收任务里的 workspace，胶囊常驻；「全部工作区」只在 ≥2 时出现 |
| 4 | 「我的 → 工作区」偶发变空、新建工作区后列表又消失 | Hub 在 `#attachApp` 时先发骨架 `device.status`（设备名写死 `DeepSeek Harness`、**没有** `workspaceRoots`），`_applyDeviceStatus` 无条件覆盖 | 按设备名判定骨架：骨架只更新能力位不动目录；Agent 真实上报空目录时仍照常清空 |

## 3. 插件端（dsh-plugin-m1 0.2.9）

- `lib/server.js`：`POST /api/v1/desktop/workspaces`（Bearer/`?token=` 鉴权；body `{name}`；成功 `200 {ok,name,path}`；失败 `400 {code:'WORKSPACE_CREATE_FAILED',message}`）——本阶段之前已加入，本次只随版本升到 0.2.9。
- `lib/index.js`：`createDesktopWorkspace(name)` 清洗非法字符 `[\\/:*?"<>|]` → `-`，空名/`.`/`..` 抛 `invalid workspace name`，无授权根目录抛 `no workspace root`，`mkdirSync({recursive:true})`，同名幂等复用。
- `package.json`：`version` → **0.2.9**（`pluginVersion()` 每次读盘，重启后 `GET /api/v1/health` 的 version 可判断是否加载新代码）。
- 新增自检脚本 `tools/verify-plugin-m4.ps1`（6 项：版本 ≥0.2.9 / workspaces 列表 / 401 鉴权 / 400 空名字 / 真实建目录 / 非法字符清洗 + tasks 回归；`-NoCreate` 只做只读检查）。

## 4. 手机端（0.4.1-m4.0 / versionCode 27）

- `app/lib/services/history_api.dart`：新增 `DesktopWorkspaceCreated{name,path}` 与 `createDesktopWorkspace(baseUrl,{token,name})`（空名直接抛「请先填写工作区名称」；非 2xx 统一 `新建工作区失败` 前缀；没有 `path` 视为失败）。
- `app/lib/data/live_store.dart`：`createDesktopWorkspace(name)`（未连接抛错，成功后把新目录追加进 `_workspaceRoots`）；`_applyDeviceStatus()` 骨架判定。
- `app/lib/screens/workspace_screen.dart`（重写，约 470 行）：5 秒轮询 + 下拉刷新 + 回前台刷新；会话倒序、状态徽标、消息数/时间；AppBar「浏览工作区文件 / 新建会话（可命名）/ 刷新」；FAB「新会话」；空态「在这里新建会话」/「或在 AI 助手里发指令」；底部输入条固定发往该工作区最新会话，无会话时禁用并提示。
- `app/lib/widgets/workspace_create_dialog.dart`（新）：名字校验 + 实时预览「将建在：<根目录>/<名字>」；旧插件 404 → 「电脑端插件版本过低，还不能新建工作区；升级插件后重试。」
- `app/lib/screens/tasks_screen.dart`：工作区胶囊常驻（根目录 + 任务里出现的目录）+ 末尾「＋ 新建工作区」；创建成功 SnackBar 后直接进入新工作区页。
- 版本：`pubspec.yaml 0.4.1+27`、`local.properties 0.4.1/27`、`build.gradle.kts versionName="0.4.1-m4.0"`、`app_version.dart` code 27。
- 文档：`docs/mobile/API_CONTRACT.md`（补 `POST /desktop/workspaces`，标题 v0.4.1）、`docs/mobile/SIGNING.md`（测试数 243 → 255）、`docs/mobile/README.md`（§6.4 M4.0、§8 第 19 条、测试数与文件树）。

## 5. 验收证据

| 项 | 结果 | 证据 |
|---|---|---|
| 手机端测试 | **255/255 All tests passed**（新增 `test/workspace_m4_test.dart` 12 项：REST 契约/名字预览/对话框/工作区页倒序与空态/任务页入口）；`theme_m2_3_test.dart`、`empty_state_test.dart`、`widget_test.dart` 中内置的版本号断言同步为 `0.4.1+27` / `0.4.1-m4.0` | `cd app; flutter test`（ASCII 镜像目录运行） |
| 静态检查 | 18 issues，**无 error**（均为历史 warning/info） | `flutter analyze`（中文路径会崩，改在 `C:\Users\user\dsh-build\app-remote` 跑） |
| APK 构建 | **release 成功**：**71,621,290 字节**（68.3 MB），SHA256 `8ED1483C1BC964F0136B3B44BB667B4E9DF0C6C3637C2801BEEEDC13FF1DFD62`（源码未变时重打包哈希可能不同，以 dist 实际文件为准）；debug 版 177,928,945 字节（备查） | `flutter build apk --release`（在 `C:\Users\user\dsh-build\app-remote` 镜像目录） |
| APK 签名 | release 包 signer 证书与 debug 一致（`CN=Android Debug`，SHA-256 `341ef83b…70d6`），可覆盖安装现有版本 | `apksigner verify --print-certs` |
| APK 版本 | `versionCode='27' versionName='0.4.1-m4.0'` | `aapt2 dump badging` |
| 插件自检（旧版基线） | **2/6 PASS**（0.2.8、workspaces 行 path 为空、两处 POST 404） | `tools\verify-plugin-m4.ps1 -NoCreate` |
| 插件自检（重启后） | 期望 **6/6 PASS** | 重启 DSH 后再跑同一脚本 |

## 6. 生效步骤（必须做）

1. **完整退出 DSH 桌面应用**（关窗口后确认进程退出；托盘退出或任务管理器结束 `DeepSeek Harness`）。
2. 重新打开 DSH（插件自启中继，默认 8787）。
3. 跑自检：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-plugin-m4.ps1
   ```
   期望 **6/6 PASS**；会在第一个授权根目录下留下 `.m4-selftest-*` 空目录，可手动删。
4. 手机装新 APK：根目录 `DeepSeek Remote AI 手机端 v0.4.1-m4.0.apk`（或 `dist\DeepSeek-Remote-latest.apk`）；重启后隧道地址/配对码可能变化，按新地址重新配对。

## 7. 已知限制

1. 新建工作区只在**第一个授权根目录**下建一级子目录（不支持 `a/b` 多级或绝对路径）；同名目录直接复用（不报错、也不清空内容）。
2. 工作区页的会话来自桌面任务镜像（最近 50 条任务），更早的历史会话不出现在工作区页；底部输入条固定发给排最前（最后活跃）的会话，要发给别的会话需点进会话再发。
3. 骨架 `device.status` 的判定依赖设备名 `DeepSeek Harness`（Hub 写死）；若今后 Hub 改用其他设备名，需同步调整 `_applyDeviceStatus`。
4. 插件 0.2.9 需重启 DSH 才生效；未重启时新建工作区会得到 404，App 会提示「电脑端插件版本过低」。
5. 本机无真机/模拟器，工作区页与新建对话框仅单测 + 构建级验证；release 包是**沿用 debug 密钥签名的**（`android/app/build.gradle.kts` 的 release 配置仍用 signingConfigs.debug），正式发布前需按 `docs/mobile/SIGNING.md` 换正式 keystore。

## 8. 下一步

- 重启 DSH → 跑 `verify-plugin-m4.ps1` → 真机点一遍：任务页「＋ 新建工作区」→ 进入新工作区页 → 「新会话」→ 发一条指令 → 回电脑端确认目录与会话都在。
- 把 6 项插件自检纳入日常回归；考虑把工作区会话来源从「最近 50 条任务」改为 `GET /desktop/sessions?workspace=`（插件已有此接口，M4.1 候选）。

## 9. 证据索引

- 插件：`dsh-plugin-m1/lib/server.js`、`lib/index.js`、`package.json`、`tools/verify-plugin-m4.ps1`
- 手机端：`app/lib/services/history_api.dart`、`app/lib/data/live_store.dart`、`app/lib/screens/workspace_screen.dart`、`app/lib/widgets/workspace_create_dialog.dart`、`app/lib/screens/tasks_screen.dart`、`app/test/workspace_m4_test.dart`
- 文档：`docs/mobile/API_CONTRACT.md`、`docs/mobile/SIGNING.md`、`docs/mobile/README.md`、`PROJECT_STATUS.md`、根 `README.md`
- APK：`DeepSeek Remote AI 手机端 v0.4.1-m4.0.apk`、`dist/DeepSeek-Remote-AI-v0.4.1-m4.0.apk`、`dist/DeepSeek-Remote-latest.apk`
