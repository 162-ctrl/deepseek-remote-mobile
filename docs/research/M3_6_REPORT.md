# M3.6 交付报告：对话对齐 PC、插件同源 + 插件市场、打开即最新

- 日期：2026-11-11
- 版本：手机端 **0.3.6-m3.6（versionCode 25）**；DSH 插件 **0.2.8**（需重启 DSH 生效）
- 状态：代码完成、单测/构建全绿；插件侧 **等待重启 DSH 后生效**（本机 HMR 事务锁卡死，无法热更新）

## 1. 一句话结论

用户三条反馈（英文推理混进正文 / 插件和 PC 不同步、没有插件市场 / 打开对话不是最新）**根因全部定位并修复**：
英文是插件把 `assistant/message` 里所有 content part（含 reasoning）拼成了正文；插件不同步是 Host 返回的是原始结构（214 条空 id/name）而插件没归一化；不最新是插件把所有会话 `updatedAt` 都写成启动时刻、手机端也没按最后消息时间排序。
插件端已改到 0.2.8（12/12 单测），手机端已重写插件页（已安装/插件市场双 Tab）、会话卡显示消息数与最后时间、打开即滚到底、回前台强刷（**flutter test 244/244**、APK 177,899,089 字节）。
**唯一待用户操作**：完整退出并重开一次 DSH 桌面应用（本机 HMR 事务锁导致插件无法热加载），重启后跑 `tools\verify-plugin-m3-6.ps1` 应 6/6 PASS。

## 2. 用户反馈与根因

| # | 用户反馈（m04949） | 根因 | 修复 |
|---|---|---|---|
| 1 | 「不要这样的英文，要跟pc端一样的对话」 | `dsh-plugin-m1/lib/index.js` 的 `mapDesktopEvent()` 对 `assistant/message` 用 `contentText(message.content)` 拼接**全部 part**，把 reasoning/thinking 当正文下发 | 新增 `assistant-text.js`：只取 `''/text/markdown/output_text` part，无正文才回退；正文不再被 `stripCodeBlocks` 吞掉 |
| 2 | 「插件也和pc端不同步，而且没有插件市场」 | `/desktop/plugins` 直接返回 Host 原始结构（`entryId/moduleName/meta.title`），App 侧取 `id/name` → 214 条空行；且没有任何市场接口 | 插件归一化为 `{id,name,moduleName,enabled,phase,patchId}` + 新增 bundle/市场接口（`pluginManager.listBundles/installBundle/removeBundle/setBundleEnabled`、`pluginMarket.listIndexes/search`）；App 插件页改「已安装 / 插件市场」双 Tab |
| 3 | 「每次打开对话不是最新的」 | 插件 `listDesktopTasks()` 用 `tracked.updatedAt \|\| Date.now()` → 所有会话同一时间、顺序随机；手机端也不按时间排、打开不置底 | 插件改为 `lastTime`（log 最后一条事件时间）+ 同名标题补 ` · HH:mm` + 倒序；App 加 `desktop_sort.dart`、会话卡显示「N 条消息」、进入/回前台强制刷新并滚到底 |

## 3. 插件端（dsh-plugin-m1 0.2.8）

新增文件：

- `lib/assistant-text.js`：`TEXT_PART_TYPES`、`partText()`、`partType()`、`contentText()`、`assistantText()`（过滤 reasoning，压空行）。
- `lib/task-rows.js`：`HH_MM()`、`labelDuplicateTitles()`、`sortByLastTime()`、`labelAndSortTasks(rows, 50)`。
- `test/assistant-text.test.js`（6 项）、`test/task-rows.test.js`（6 项）→ `node --test` **12/12 PASS**。

修改：

- `lib/index.js`：接入上面两个模块；`listDesktopTasks()` 输出 `lastTime/messageCount/lastSeq/running` 并倒序；`plugins()`/`pluginBundles()` 归一化；`pluginMarket()` 兼容 `listIndexes()` 异步与 `search(url,{query})` / `search(url,query)` 两种签名；`debugSession()` 增加 `assistantParts`。
- `lib/server.js`：新增 5 条路由（均 Bearer/`?token=` 鉴权）
  - `GET /api/v1/desktop/plugins/bundles`
  - `POST /api/v1/desktop/plugins/bundles/enabled`
  - `GET /api/v1/desktop/plugins/market?url=&query=`
  - `POST /api/v1/desktop/plugins/market/install`
  - `POST /api/v1/desktop/plugins/market/remove`
- `package.json`：`version` → **0.2.8**（`pluginVersion()` 每次读盘，重启后 health 的 version 可判断是否加载新代码）。

Host 能力（`cordis_inspect_query` host/Service 实测）：`pluginManager` 提供 `listBundles/setBundleEnabled/installBundle/waitForInstall/cancelInstall/removeBundle/listVersions/inspect`；`pluginMarket` 提供 `listIndexes/search/entry/readEntryDetail`。插件市场因此可做「浏览索引 → 搜索 → 安装（构建脚本需二次确认）→ 卸载」。

## 4. 手机端（0.3.6-m3.6 / versionCode 25）

- `app/lib/services/history_api.dart`：`TaskRecord` 增 `lastTime`（毫秒）/`messageCount`/`lastSeq`；新增 `PluginBundle`/`MarketIndex`/`MarketEntry`/`MarketSearchResult`；新增 `listPluginBundles()`/`setBundleEnabled()`/`marketSearch()`/`installPlugin()`/`removePlugin()`；`PluginInfo` 兼容旧行 `entryId/moduleName`。
- `app/lib/services/desktop_sort.dart`（新）：`sortDesktopTasks`/`sortDesktopTaskItems`/`compareLastTime`（有 `lastTime` 的在先，倒序；缺失回退 `updatedAt`）。
- `app/lib/data/live_store.dart`：5 个插件方法透传（带 `_withAuthRetry`）；桌面任务用纯函数排序。
- `app/lib/screens/plugins_screen.dart`（1365 行）：**「已安装 / 插件市场」双 Tab**
  - 已安装：按 bundle 分组，包级开关 + 子插件开关；旧插件（无 bundles 接口，404）回退扁平列表，并把内置项折叠进「系统内置（N）」。
  - 市场：索引下拉 + 搜索 + 安装（若 Host 返回 `pendingBuilds`/`nextStep` 则弹二次确认，批准后再装）+ 卸载（确认）；接口 404 时提示「电脑端插件需升级」。
- `app/lib/screens/tasks_screen.dart`：桌面会话卡显示「N 条消息」与「最后消息 HH:mm」，按 `lastTime` 倒序。
- `app/lib/screens/desktop_session_screen.dart`：`WidgetsBindingObserver` 回前台 `_load(initial: true)`；`_scrollToEnd(force: true)` 首次进入与回前台强制置底。
- 版本：`pubspec.yaml 0.3.6+25`、`local.properties 0.3.6/25`、`build.gradle.kts versionName="0.3.6-m3.6"`、`app_version.dart code 25`。
- `app/android/gradle.properties`：`kotlin.incremental=false`（中文路径下 `:mobile_scanner:compileDebugKotlin` 的增量缓存报错规避）。
- `docs/mobile/README.md`：§6.4 M3.6 增量、测试数 244、§8 第 18 条已知限制。

## 5. 验收证据

| 项 | 结果 | 证据 |
|---|---|---|
| 插件单测 | **12/12 PASS** | `node --test dsh-plugin-m1/test/assistant-text.test.js dsh-plugin-m1/test/task-rows.test.js` |
| 插件语法 | `node --check lib/index.js` exit 0 | 同上命令 |
| 手机端测试 | **244/244 All tests passed（exit 0）** | `cd app; flutter test`（Lead 独立复跑） |
| APK 构建 | 成功，**177,899,089 字节**，SHA256 `3853FA8715FD35D5D3691DD20BC1020E798DA8076775375FB6C414C60325F6B1` | `flutter build apk --debug` |
| APK 版本 | `versionCode='25' versionName='0.3.6-m3.6'` | `aapt dump badging` |
| 插件旧版基线 | 自检 **0/6**（0.2.7 / 214 条空 id / bundles 404 / market 404 / lastTime 全 0 / 无 assistantParts） | `tools\verify-plugin-m3-6.ps1` |
| 插件新版（待重启后） | 期望 **6/6 PASS** | 重启 DSH 后再跑同一脚本 |

## 6. 生效步骤（必须做）

本机 DSH 的插件 HMR 事务锁已被卡死：`plugin_manager` 对**任何** bundle 的 `set_bundle` 都返回 `HMR transactions cannot be nested`，因此 0.2.8 的插件代码无法热加载（8787 端口仍由 DSH 主进程跑旧模块）。

1. **完整退出 DSH 桌面应用**（关窗口后确认进程已退出；托盘退出或任务管理器结束 `DeepSeek Harness`）。
2. 重新打开 DSH（插件会自启中继，默认 8787）。
3. 看插件面板/日志拿到**新的公网地址 + 配对码**，手机 App 重新扫码或手填地址配对（重启后隧道 URL 会变）。
4. 本机自检：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-plugin-m3-6.ps1
   ```
   期望 **6/6 PASS**（health version ≥ 0.2.8）。
5. 手机装新 APK：根目录 `DeepSeek Remote AI 手机端 v0.3.6-m3.6.apk`（或 `dist\DeepSeek-Remote-latest.apk`）。

## 7. 已知限制

1. 插件包分组与插件市场**只有重启后新版插件才提供**；旧插件下 App 会自动回退到扁平插件列表并提示升级。
2. 市场安装若涉及 npm 构建脚本，必须由用户在二次确认里批准（Host 返回 `pendingBuilds`）；不同 Host 版本的 `pluginMarket.search` 签名差异已做兼容，但仍可能返回空索引。
3. 会话「最后时间」取的是插件日志里最后一条事件时间；若 DSH 端会话未产生事件（长时间空闲），显示会停留旧时间，属预期。
4. 本次无真机，UI 验证限于单测与构建；插件市场内「安装/卸载」未在真实索引上端到端点过（需重启后补测）。
5. 中文路径下 Android 构建需 `kotlin.incremental=false`（已写入 `gradle.properties`）。
6. `flutter build apk --release` 在本机中文路径下失败（`Unable to read file: …app.dill`，Flutter AOT 与非 ASCII 路径的已知问题），本次交付 debug APK（177,899,089 字节）；如需更小的 release 包，可把 `app/` 复制到纯 ASCII 路径再构建。

## 8. 下一步

- 重启 DSH → 跑自检 → 真机点一遍：① 桌面直播里是否只剩中文正文；② 插件页是否按包分组、市场能否搜索；③ 打开对话是否停在最新一条。
- 若通过：把这套 6 项自检接入日常回归；再评估 dsh-Go 借鉴清单里剩余项（连接管理、图片预览、通知栏直接审批、语音输入）。

## 9. 证据索引

- 插件：`dsh-plugin-m1/lib/index.js`、`lib/server.js`、`lib/assistant-text.js`、`lib/task-rows.js`、`test/assistant-text.test.js`、`test/task-rows.test.js`、`package.json`
- 手机端：`app/lib/services/history_api.dart`、`app/lib/services/desktop_sort.dart`、`app/lib/data/live_store.dart`、`app/lib/screens/plugins_screen.dart`、`app/lib/screens/tasks_screen.dart`、`app/lib/screens/desktop_session_screen.dart`、`app/test/plugin_market_test.dart`、`app/test/desktop_freshness_test.dart`
- 工具：`tools/verify-plugin-m3-6.ps1`
- APK：`DeepSeek Remote AI 手机端 v0.3.6-m3.6.apk`
