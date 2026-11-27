# M4.51 交付报告：工作区项目卡默认折叠

**一句话**：「工作区」页的项目卡从「默认全展开」改成「默认折叠、点项目头才摊开」，一个项目里二十几条会话不再把首页铺满。

- 版本：App **0.4.51+76**（versionName `0.4.51-m4.51`）
- 时间：2026-11-24
- 涉及：`app/lib/screens/tasks_screen.dart`（唯一改动源码）+ 6 个测试文件

## 之前的问题

用户截图（22:13，工作区主 Tab）：「deepseek手机端」一个项目 21 条会话全部展开，卡片一路拖到屏幕外——项目名、目录、`21 个会话 · 1 个进行中` 被顶到最上面，想找那条「直播中」的会话要先翻过一堆「已存档」。

M4.13 引入按项目分组 + 可折叠时，默认是**全部展开**（`Set<String> _collapsed` 为空 = 都不折叠）。那时一个项目只有几条会话；跑久了会话攒到二十几条，默认展开就变成了「首页只剩一个项目」。

## 改动

| 位置 | 改动 |
|---|---|
| `app/lib/screens/tasks_screen.dart` | `Set<String> _collapsed`（默认空 = 全展开）换成 `Set<String> _expanded`（默认空 = 全折叠，M4.51 注释）；`_ProjectGroupCard` 的 `expanded` 改为 `_expanded.contains(group.path)`；`_toggleGroup()` 改成在 `_expanded` 上加/删；项目头右侧加 `AnimatedRotation` 小箭头（`Icons.expand_more_rounded`，展开时转 180°），只在 `items.isNotEmpty` 时出现 |
| 折叠状态 | 只存在 `_TasksScreenState` 内存里（和 IndexedStack 保活一致），不写 `SettingsGateway`，不跨重启；各项目独立，互不影响 |
| 空项目 | 没有会话可摊开，不画箭头，仍保留「空项目」小标 |

## 验收

- 新增 `app/test/workspace_fold_m4_51_test.dart` **3/3**：
  1. 默认折叠：三条会话一条都不露，项目卡摘要仍给出 `2 个会话` / `1 个会话`。
  2. 点项目头展开、再点收起；同页另一个项目单独展开，收起一个不影响另一个。
  3. 空项目不画展开箭头（`find.byIcon(Icons.expand_more_rounded)` 为空）。
- 反证：把 `expanded: _expanded.contains(group.path)` 临时改成 `expanded: true` → 新测试「默认折叠」「展开收起互不影响」「空项目无箭头」中 2 例失败（`+1 -2`），恢复后 3/3。
- 连带修正 5 个依赖「默认展开」的旧断言：
  - `app/test/workspace_m4_test.dart`：M4.13 用例改名为「同项目的会话挂在项目卡里，项目默认折叠、可点开」，先断言三条会话都不在，再点开 `demo` 看 A/B（C 仍折叠），再点一次收起。
  - `app/test/archive_m4_10_test.dart`：两例在断言存档行之前先点开 `poetry` 项目（`find.text('poetry').last`，胶囊里也有同名项目）。
  - `app/test/tasks_m4_11_test.dart`：三例先点开 `poetry` 再断言会话行 / 已存档标。
- 全量 `flutter test`：**519/519**（516 + 新增 3）。
- `flutter analyze --no-pub`：**32 issues、0 error**，与 M4.50 同数，无新增。

## 交付

| 项 | 值 |
|---|---|
| versionCode / versionName | 76 / `0.4.51-m4.51` |
| APK 字节 | 73,213,886 |
| SHA256 | `5C873F3C93F6F2DA0F13524ECE0EAE10D087E1CC0E3D942FE890B609731DF811` |
| 签名 | `C=US, O=Android, CN=Android Debug`（同 debug 密钥，可覆盖已装 0.4.50） |
| 同哈希四处 | 构建产物、`dist/DeepSeek-Remote-AI-v0.4.51-m4.51.apk`、`dist/DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.51-m4.51.apk` |
| 发布校验 | `tools/verify-release.mjs` 四项一致；`GET /api/v1/app/version` 回读 code 76 / `0.4.51-m4.51` / size 73213886 / sha256 `5c873f3c…` / publishedAt `2026-11-24T00:39:16.829Z` |

## 限制与下一步

- 折叠状态不持久：杀进程或重启 App 后回到「全部折叠」的默认值。目前按「同一页面会话内记住」处理，没写设置。
- 折叠后筛「进行中 / 等待授权」时，结果仍收在项目卡里，需要再点一下项目头——项目卡摘要会写「N 个进行中」，不会让人以为筛选没生效。要不要在筛选时自动摊开，留作后续体验决策。
- 仍欠的前两轮遗留不变：「工作区」二级页的 Agent 掉线态文案（`liveStore.deviceOnline` 已有信号，`ProjectsScreen` 没用）；电脑端看不到手机新建会话的架构问题待定方案。
