# M4.18 插件市场与电脑端同步

一句话结论：手机上「插件市场」不再去读电脑端手配的第三方索引（这台电脑一个都没配，
所以永远是空的），改成直接显示电脑端「设置 → 插件市场」里的同一份插件目录——
42 个插件包、官方标记、是否已安装，手机上看到的就是电脑上看到的那份清单。

## 起因

用户在手机上打开「插件 → 插件市场」，看到的只有「输入关键字搜索电脑端插件市场」，
搜索之后也空空如也：

```
GET /api/v1/desktop/plugins/market?query=&limit=5
→ indexes=0 entries=0 source= error=
```

而同一台电脑上，电脑端的插件市场列着 42 个插件包：

```
plugin_manager list_bundles → total: 42
  @deepseek-ai/dsh-base、@deepseek-ai/dsh-web-app、
  @deepseek-ai/dsh-experimental-*、billion-context、dshmarket、dsh-our-free-model …
```

## 根因

| 现象 | 根因 | 位置 |
| --- | --- | --- |
| 手机市场永远是空的 | 手机市场只读 `pluginMarket.listIndexes()`，也就是「设置 → 插件市场」里**手动配置**的第三方索引；这台电脑一个索引都没配 | `dsh-plugin-m1/lib/index.js` `pluginMarket` |
| 电脑端明明有 42 个插件包，手机看不到 | 电脑端的市场列表来自 `pluginManager.listBundles()`（Host Service），手机走的接口完全没有用它 | Host `pluginManager` |
| 没有可安装的官方插件条目 | 手机只能看到索引里发布过的条目，官方目录里的插件不在任何索引里 | 同上 |

## 改动

### 电脑端插件（0.2.23）

- `dsh-plugin-m1/lib/index.js`
  - 新增 `localizedMetaText(meta, field, language)`：`meta` 在 Host 各版本间形状不一致
    （`{name, description}` 平铺 / `{'zh-CN': {...}}` 分语言 / 语言键上直接是字符串），
    按 `zh-CN → zh → en` 依次取，取不到返回空串。
  - 新增 `pluginCatalog({ language })`：`ctx.get('pluginManager').listBundles()` 映射成
    `{ name, title, description, official, availability, spec, version, installed, enabled,
    optional, removable, updatable, listedByDefault, source }`；`pluginManager` 不可用时
    返回 `{ supported: false, bundles: [] }`，让手机能说清「这台电脑不支持」而不是空列表。
- `dsh-plugin-m1/lib/server.js`
  - 新增 `GET /api/v1/desktop/plugins/catalog?language=zh-CN`（需要 App token，
    透传 `pageContext.pluginCatalog`；失败返回 501 `PLUGIN_CATALOG_UNAVAILABLE`）。
  - 顺手把 `plugins/market/install` 那段挤在一行上的 `if (...) { const authHeader = …`
    拆回正常缩进。
- 新增 `dsh-plugin-m1/test/catalog.test.js`（6 例）：多语言 meta 三种形状、
  `spec` 取到「包名@精确版本」、没有 meta 时退回 `description`、没名字的条目被剔掉、
  `pluginManager` 不可用时 `supported:false`。

### 手机端（0.4.18+45）

- `app/lib/services/history_api.dart`
  - `MarketEntry` 增加 `official` / `spec` / `availability` / `removable` / `enabled`
    （目录条目与索引条目共用一个模型，卡片不用分两套）。
  - 新增 `PluginCatalog`（`supported` / `language` / `entries`，空名条目剔除）与
    `HistoryApi.listPluginCatalog(baseUrl, token:, language:)`。
- `app/lib/data/live_store.dart`：新增 `pluginCatalog()`（未连接时抛 `PairingApiException`，
  沿用 `_withAuthRetry`）。
- `app/lib/screens/plugins_screen.dart`
  - 市场页主来源改成电脑端目录：进页面自动读目录，`_marketEntries` 把目录条目与
    第三方索引里多出来的条目（按包名去重，目录优先）合并，**搜索在本地过滤**，
    按钮从「搜索」改成「刷新」。
  - 安装按目录给的 `spec` 下发（没有 spec 的索引条目退回包名）；装完/卸载后重新读目录，
    不用再点搜索。
  - 卡片多一个「官方」小胶囊；概览行改成「N 个插件 · 电脑端插件市场 · 已安装 M 个」。
  - 读不到目录时不再说「输入关键字搜索」，而是给出「读取电脑端插件市场失败」+
    「读取目录」按钮。
- 新增 `app/test/plugin_catalog_m4_18_test.dart`（3 例：目录解析、接口路径与语言参数、
  市场页列出目录并本地过滤）；`app/test/plugin_market_test.dart` 的旧电脑端降级用例
  改成断言新的「读取目录」提示，并给假 store 补上 `pluginCatalog()` 的 404。

## 验收证据

| 项 | 结果 |
| --- | --- |
| 插件单元测试 | `node --test "test/*.test.js"` → **57/57 通过**（原 51 + 新增 6） |
| 手机端测试 | `flutter test test/` → **369/369 通过**（原 366 + 新增 3） |
| 插件版本 | `GET /api/v1/health` → `{"status":"ok","version":"0.2.23",...}`（热加载生效，未重开 DSH） |
| 目录接口 | `GET /api/v1/desktop/plugins/catalog?language=zh-CN` → `supported=true`、**42 个插件包** |
| 官方标记 | 首条 `@deepseek-ai/dsh-experimental-auto-review` → `official=true`、`version=0.2.2-rc.1` |
| 已安装状态 | `dshmarket` / `dsh-our-free-model` / `billion-context` → `installed=true`，卡片显示「已安装 + 卸载」 |

## 构建命令

```powershell
$env:Path = "C:\Users\user\dsh-tools\flutter\flutter\bin;" + $env:Path
$env:JAVA_HOME = "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
$env:ANDROID_HOME = "C:\Users\user\dsh-tools\android-sdk"
robocopy "<项目根>\app" "C:\Users\user\dsh-tools\build\dsh-app" /E /XD build .dart_tool .gradle .idea .cxx /XF *.iml
cd "C:\Users\user\dsh-tools\build\dsh-app"; flutter build apk --release
```

项目路径含中文，AOT 快照在中文路径下会报
`Unable to read file: D:\<乱码>\app\.dart_tool\flutter_build\<hash>\app.dill`，
所以必须先 robocopy 到纯 ASCII 目录再构建（与 M4.16/M4.17 相同）。

## 限制与下一步

- **插件目录没有中文标题**：这台电脑的 `listBundles()` 没给 `meta`，`title` 一律为空，
  卡片上显示的是包名（`@deepseek-ai/dsh-experimental-auto-review` 这种）。等 Host 的
  `meta` 有本地化文案时会自动用上，不需要改手机端。
- **`spec` 目前是纯包名**：Host 未返回 `installTarget`（这些包 `availability` 是
  `profile`/`installation` 但没有精确版本），安装时由电脑端解析最新版本。
- **第三方索引仍是补充来源**：电脑端若以后配了索引，索引导里多出来的条目会接在目录后面。
- **手机需要重新配对**：cloudflared 快速隧道每次重启都换域名，本次是
  `https://<公网隧道>.trycloudflare.com`；用旧二维码/旧地址
  连不上时先在电脑端重新扫码配对。
