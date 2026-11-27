# M4.1 交付报告：手机端插件页对齐电脑端 + 插件市场索引兜底

- 日期：2026-11-13
- 版本：手机端 **0.4.2-m4.1（versionCode 28）**；DSH 插件 **0.2.10**（需完整退出重开 DSH 生效）
- 状态：代码与单测完成、release APK 已构建并发布；插件侧 **等待重启 DSH 后生效**（运行中的 8787 仍是 0.2.8）

## 1. 一句话结论

用户对比电脑端 DSH「插件」页后要求手机端"要这样的"，M4.1 补上两块：
① **已安装插件画廊**——手机端「插件 → 已安装」顶部新增「浏览本地插件」，按「内置插件配置 / 实验性插件 / 其他插件」分组列出电脑上全部本地插件并逐项开关（与电脑端同源，走 `POST /desktop/plugins/enabled`）；
② **插件市场不再为空**——根因是 DSH 的 `pluginMarket.listIndexes()` 只返回「设置里配置过的索引」，本机一个都没配；插件端改为在无索引时用 DSH 公开索引 `https://api.dshmarket.com/v1/index.json` 兜底（`defaultIndex=true` + `refresh`），并改用新 Host 的 `search(url,{query:{text,limit,offset,order}})` 签名；市场卡片加厚（作者 + 下载量 + 星标 + 顶部统计行）。
手机端 **flutter test 263/263**，release APK **71,720,030 字节**（`versionCode=28`、`versionName=0.4.2-m4.1`）。

## 2. 起因与范围

用户贴了两张电脑端 DSH Web「插件」页截图（「已安装」Tab 的内置/实验性分组、插件市场 Tab 的发现/收藏/已安装/已屏蔽/高级与插件卡片），要求手机端对齐。手机端当时的现状：插件页只有「已安装（按 bundle 分组）/ 插件市场」两个 Tab，没有本地插件视角；市场接口返回 `indexes=0 / entries=0`，页面永远是空的（M3.6 起自检就一直 FAIL，但当时判为 Host 侧问题）。

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 1 | 手机端看不到电脑端「设置 → 插件」里的内置/实验性插件与开关 | 只暴露 bundle（插件包）视角，没有 `pluginManager.listPlugins()` 级别的接口 | 插件新增 `GET /api/v1/desktop/plugins/gallery`（`pluginGallery()`）；App 新增 `PluginGalleryScreen` + 「已安装」Tab 顶部入口 |
| 2 | 插件市场永远 0 条 | DSH `pluginMarket.listIndexes()` 只返回设置里配置的索引 URL，本机未配置 → 空数组 | 无索引时兜底公开索引 `defaultIndexUrl` + `refresh:true`；0 条再按 `order:'stars'` 重试 |
| 3 | 即便有索引也可能搜索失败 | 新 Host 的 `search(url, query)` 要求 `query` 为对象 `{text,limit,offset,order}`，旧写法 `{query,limit}` 不被接受 | 改为新签名（`text/limit:200/offset:0`） |
| 4 | 市场卡片信息太薄，看不出热度 | 只有名称/作者/描述/版本 | 解析 `downloads`/`stars` 并紧凑格式（`319万`、`6.9k`）；列表顶部加统计行（条数 + 索引来源 + 关键字） |

## 3. 插件端（dsh-plugin-m1 0.2.10）

- `lib/index.js`
  - `pluginMarket()`：`readIndexes()` 保留每条索引的 `error`；`indexes.length === 0 && defaultIndexUrl` 时用 `[{url: defaultIndexUrl, title:'', description:'', error:''}]` 兜底并置 `defaultIndex = true`；`runSearch(text)` 用新签名 `search(url, { query: { text, limit: 200, offset: 0 }, ...(defaultIndex ? { refresh: true } : {}) })`，空结果再试 `order: 'stars'`，异常时若是默认索引再 `refresh` 重试一次；条目映射补 `meta` 兜底、`title` 的 zh/en 对象、`installed`、`downloads`、`stars`；返回值新增 `defaultIndex`。
  - **新增 `pluginGallery()`**：`pluginManager.listPlugins()` → 用 `meta.title/description`（中文字段优先）出名称与说明，`meta.experimental === true || /experimental/.test(moduleName)` 判实验性，`/^(?:@deepseek-ai\/)?dsh-(?:ui-|client-ui-|agent-|permission|sandbox|tool-|web-|base|core)/` 判内置，分 `builtin`/`experimental`/`other` 三组并按名称排序、空组丢弃，返回 `{ groups:[{key,title,plugins:[{id,name,description,experimental,enabled,configurable,version}]}], total }`。
- `lib/server.js`：新增 `GET /api/v1/desktop/plugins/gallery`（Bearer/`?token=` 鉴权，失败 `501 {code:'PLUGIN_GALLERY_UNAVAILABLE'}`）。
- `package.json`：`version` → **0.2.10**（0.2.9 已在本机加载过，换版本号才能在重启后确认新代码生效）。
- `node --check` 通过；`node --test 'test/*.test.js'` → **12/12 pass**。
- `tools/verify-plugin-m4.ps1`：版本门槛 0.2.9 → **0.2.10**，末尾新增两项——`GET /desktop/plugins/gallery` 返回分组与开关状态、`GET /desktop/plugins/market` 有索引兜底；共 **8 项**（`-NoCreate` 跳过真实建目录）。

## 4. 手机端（0.4.2-m4.1 / versionCode 28）

- `app/lib/services/history_api.dart`：`MarketEntry` 增 `downloads/stars` 与 `downloadsLabel/starsLabel`（`>=1e8` 亿、`>=1e4` 万、`>=1000` k）；`MarketSearchResult` 增 `defaultIndex`；新增 `PluginGalleryItem`/`PluginGalleryGroup`/`PluginGallery` 与 `pluginGallery(baseUrl,{token})`。
- `app/lib/data/live_store.dart`：新增 `pluginGallery()`（未连接抛「还未连接电脑，无法读取已安装插件」，走 `_withAuthRetry`）。
- `app/lib/screens/plugin_gallery_screen.dart`（新）：搜索过滤（名称/说明/id）、统计行「N 个插件 · 开关与电脑端『设置 → 插件』同源，重启 DSH 后完全生效」、分组标题「内置插件配置 · 2」、每行图标 + 名称 + 「实验性」标签 + 两行说明 + `Switch`（切换中显示进度圈）；404/501 提示升级电脑端插件；空态与无匹配提示。
- `app/lib/screens/plugins_screen.dart`：「已安装」Tab 顶部「浏览本地插件」入口卡（带插件包数量），返回后刷新；市场卡片作者行加下载量与星标；市场列表顶部统计行（`N 个插件 · 索引标签/DSH 默认索引 · “关键字”`）。
- 版本：`pubspec.yaml 0.4.2+28`、`local.properties 0.4.2/28`、`build.gradle.kts versionName="0.4.2-m4.1"`、`app_version.dart` code 28；`theme_m2_3_test.dart`、`empty_state_test.dart`、`widget_test.dart` 的版本断言同步。

## 5. 验收证据

| 项 | 结果 | 证据 |
|---|---|---|
| 手机端测试 | **263/263 All tests passed**（新增 `test/plugin_gallery_test.dart` 8 项：gallery JSON 解析、`/desktop/plugins/gallery` + Bearer、下载量/星标紧凑格式、`defaultIndex`、分组渲染与开关切换、搜索过滤、404 升级提示、插件页入口） | `flutter test`（ASCII 镜像目录 `C:\Users\user\dsh-build\app-remote`） |
| 静态检查 | 19 issues，**无 error**（均为历史 warning/info） | `flutter analyze`（中文路径会崩，改在镜像目录跑） |
| 插件端 | `node --check` 两个文件通过；`node --test 'test/*.test.js'` **12/12 pass** | 同上 |
| APK 构建 | **release 成功**：**71,720,030 字节**（68.4 MB），SHA256 `D93C17566E8DDDEDFB34783658A77E119AD231C63E2317338654C66A9A02CEB6` | `flutter build apk --release`（镜像目录，需同时设 `JAVA_HOME` 与 `ANDROID_HOME`） |
| APK 版本 | `versionCode='28' versionName='0.4.2-m4.1'`，`targetSdkVersion 36` | `aapt2 dump badging` |
| APK 签名 | signer `CN=Android Debug`，SHA-256 `341ef83b…70d6`（与 0.4.1/0.4.0 包一致，可覆盖安装） | `apksigner verify --print-certs` |
| 插件自检（旧版基线） | 重启前跑会 FAIL（版本仍是 0.2.8、gallery 404、market 无索引） | `tools\verify-plugin-m4.ps1 -NoCreate` |
| 插件自检（重启后） | 期望 **8/8 PASS** | 重启 DSH 后再跑同一脚本 |

## 6. 生效步骤（必须做）

1. **完整退出 DSH 桌面应用**（托盘退出或任务管理器结束 `DeepSeek Harness`），重新打开（插件自启中继，默认 8787）。
2. 跑自检：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-plugin-m4.ps1
   ```
   期望 **8/8 PASS**（会留下 `.m4-selftest-*` 空目录，可手动删）。
3. 手机装新 APK：根目录 `DeepSeek Remote AI 手机端 v0.4.2-m4.1.apk`（或 `dist\DeepSeek-Remote-latest.apk`）；重启后隧道地址/配对码可能变化，需重新配对。
4. 打开「插件」页：已安装 Tab 顶部「浏览本地插件」应看到内置插件配置 / 实验性插件分组并可开关；插件市场应出现条目与下载量/星标。

## 7. 已知限制

1. 市场索引兜底依赖外网 `https://api.dshmarket.com/v1/index.json`；离线或 Host 拒绝刷新时市场仍为空（已安装插件画廊不受影响）。
2. 画廊分组靠 `moduleName` 正则 + `meta.experimental` 推断；Host 未提供 `meta.title/description` 时退回模块名，个别插件可能落进「其他插件」。
3. 开关改动与电脑端一致，需重启 DSH 才完全生效。
4. 插件市场暂未实现电脑端的「最近收录」「收藏」「已屏蔽」「主题」「高级」「全部更新」等子 Tab 与分类胶囊；本轮是「本地插件视角 + 卡片信息 + 索引兜底」的对齐。
5. 本机无真机/模拟器，画廊页与市场卡片仅 `flutter test` + release APK 构建级验证；release 包沿用 debug 密钥，正式发布前需按 `docs/mobile/SIGNING.md` 换正式 keystore。

## 8. 下一步

- 重启 DSH → 跑 `verify-plugin-m4.ps1`（期望 8/8）→ 真机点一遍：插件页 →「浏览本地插件」→ 开关一个实验性插件 → 插件市场搜索「mcp」→ 看下载量/星标是否显示。
- 用重启后的 gallery 接口确认「子智能体 / 网页搜索 / Agent 循环 / 终端」确实落在 `builtin` 组、「智能体团队 / 语音输入 / 自定义插件索引 / 自动授权审查」落在 `experimental` 组；不符合就微调正则。
- 可继续对齐电脑端市场：分类胶囊（按 `keywords` 聚类）、「最近收录」横滑区、已安装/未安装筛选、插件详情页（评论与截图）。

## 9. 证据索引

- 插件：`dsh-plugin-m1/lib/index.js`（`pluginMarket`/`pluginGallery`）、`lib/server.js`、`package.json`、`tools/verify-plugin-m4.ps1`
- 手机端：`app/lib/services/history_api.dart`、`app/lib/data/live_store.dart`、`app/lib/screens/plugin_gallery_screen.dart`、`app/lib/screens/plugins_screen.dart`、`app/test/plugin_gallery_test.dart`
- 文档：`docs/mobile/API_CONTRACT.md`、`docs/mobile/SIGNING.md`、`docs/mobile/README.md`、`PROJECT_STATUS.md`、根 `README.md`
- APK：`DeepSeek Remote AI 手机端 v0.4.2-m4.1.apk`、`dist/DeepSeek-Remote-AI-v0.4.2-m4.1.apk`、`dist/DeepSeek-Remote-latest.apk`
