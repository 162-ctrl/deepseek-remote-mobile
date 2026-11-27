# M4.39 交付报告 · 手机档「往上滑」新建对话（手势方向纠正 + 加载圈）

## 一句话

上一版把方向做反了（要先翻到最老一条再往下拽）；这一版改成**停在最新一条上继续往上滑**，底部浮出一枚加载圈、圈里的进度跟着手走的距离变，滑够 130 就补满并显示「松手开始新对话」，松手开新对话。

## 起因

用户看完 0.4.37 的效果后直接纠正：

> 不是下划是往上划，有个加载圈，根据上滑的力度

M4.37 的实现要人先把列表翻到最老的那一条，再往下拽——既反直觉，也把「翻历史」和「新建对话」挤在同一个方向上。用户要的是：已经停在新消息处，手指往上滑，底部出现加载圈。

## 改动

| 文件 | 改动 |
|---|---|
| `app/lib/screens/cloud_chat_screen.dart` | `_onScrollNotification` 只认 `overscroll > 0`（往上滑越过最新一条）；`_pullDistance` 每一点都 `setState`，圈的进度实时跟手；新增 `_movedInGesture`：这一手中途滚过列表（含「从半路一甩到底」）就不攒越界量，避免把对话误换掉 |
| 同上 | `_NewChatPullHint` 换成加载圈：`CircularProgressIndicator(value: progress)` + 文案「继续上滑新建对话 / 松手开始新对话」，位置从顶部挪到**底部**（手指所在处） |
| 同上 | 列表物理保持 `AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics())`，短对话也能拽 |
| `app/test/cloud_new_chat_pull_m4_39_test.dart` | 新增 3 例（原 M4.37 的 3 例删除，方向已反转） |

阈值仍是 130 像素（`_newChatPull`）。

## 验收证据

| 用例 | 断言 |
|---|---|
| 往上滑过阈值松手就新建 | 滑 220 出现「松手开始新对话」且此时只有 1 条对话；松手后消息清空、存储变成 2 条、旧的 `id == 'one'` 还在 |
| 滑一点点只出圈不新建 | 滑 60 只出现「继续上滑新建对话」，不出现「松手…」；松手后仍是 1 条 |
| 翻历史/一甩到底都不误触 | 手指往下翻 260 不出圈；从半路一甩到底（-4000）也不出圈；停在最新处单独上滑 220 才出圈；反向拖回 260 后松手不新建 |

- 反证：把 `!_movedInGesture` 判断去掉 → 第三例「一甩到底」立刻变成 `Found 1 widget with text "松手开始新对话"`，说明这条守卫确实在防误触。
- 全量 `flutter test test` → **437/437 PASS**。
- 构建：robocopy 到 `C:\Users\user\dsh-tools\build\dsh-app`（exit=3）→ `flutter build apk --release` → `√ Built (69.7MB)`，62.4s。
- 产物：`73,049,346` 字节，SHA256 `F4D5834E60F67518D3689D2F3098C6B35B2379C8AE06C3DA29D19106D29C4FE8`，aapt2 `versionCode='65' versionName='0.4.39-m4.39'`。
- 发布：`dist\DeepSeek-Remote-AI-v0.4.39-m4.39.apk`、`dist\DeepSeek-Remote-latest.apk`、根目录 `DeepSeek Remote AI 手机端 v0.4.39-m4.39.apk` 三处同哈希；`GET /api/v1/app/version` 回读 `versionCode 65 / 0.4.39-m4.39 / 73049346 / f4d5834e…`。

## 限制与下一步

1. 只有手机档（云端直连）有这个手势，电脑档的会话由电脑端决定，不做。
2. 阈值 130 像素是拍的，真机手感如果偏重/偏轻，改 `_newChatPull` 一个常量即可。
3. 手势只在「已经停在最新一条」时生效；如果停在历史里，需要先滑回最新（这是刻意的，否则翻历史会误建对话）。
4. 已知遗留（与本次无关）：插件侧 gzip 未做（首屏 187 KB → 约 30~40 KB，需重开 DSH）；`HMR transactions cannot be nested` 每次改插件都必须完整重开 DSH；`tools\verify-plugin-m4.ps1` 在 PS 5.1 下仍有 15 个 syntax error。
