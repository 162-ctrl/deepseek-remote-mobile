# M4.46 统一轮询协调器（第二阶段第 ⑦ 条）

> 日期：2026-11-23
> App `0.4.46-m4.46`（versionCode 72）· 插件不变（0.2.33）

## 一句话结论

把「任务页 / 工作区页各自开 `Timer.periodic(5s)`」换成一处可控的轮询：**只在页面可见且 App 在前台时跑，一次只跑一个请求，失败按 2 的幂退避、封顶 30 秒，成功立刻复位**。

## 之前哪里不对

| 毛病 | 原因 |
|---|---|
| 用户看着 AI 助手页，程序仍在拉任务 | `RootShell` 用 `IndexedStack` 保活四个页面，工作区页从没被销毁，`Timer.periodic` 一直转 |
| 弱网时越等越慢 | 定时器到点就发，不看上一个请求还在途；5 秒一次、每次几十 KB，隧道慢时请求会叠起来 |
| 电脑刚拒过仍然按原节奏打 | 失败不改变节奏，等于持续加压 |

## 改了什么

| 位置 | 改动 |
|---|---|
| `app/lib/services/poll_coordinator.dart`（新） | `pollBackoffDelay(base, failures, {maxBackoff})`：`base * 2^min(failures,5)`，封顶默认 30 秒；`PollCoordinator`：`active` 开关、`_inFlight` 闸门、`failures`/`runs`/`nextDelay` 可观测、`refreshNow()` 立刻跑一次、`dispose()` 彻底停 |
| `app/lib/screens/tasks_screen.dart` | 去掉 `Timer.periodic`；新增 `active` 参数（默认 `true` 保持老行为）与 `didUpdateWidget` 同步；轮询体 `_pollOnce()` = 任务镜像 + 待回答摘要 |
| `app/lib/screens/root_shell.dart` | 变成 `WidgetsBindingObserver`，新增 `_foreground`；传 `active: _index == 1 && _foreground` |
| `app/lib/screens/workspace_screen.dart` | 同一套协调器：`resumed` → 开并立刻刷一次，其余生命周期 → 停 |

## 验收

- 新增 `app/test/poll_coordinator_m4_46_test.dart` **7/7**：
  - 退避数学：5s 基准 → 10s / 20s / 封顶 30s，自定义上限也生效
  - 没激活时 120ms 内 0 次；激活后按节奏跑；停掉后次数不再涨
  - 上一个请求挂住时 150ms 内只发 1 次，放开后继续
  - 失败一次后 `nextDelay == 40ms`（20ms 基准），成功后回到 20ms
  - `refreshNow()` 立刻跑一次并复位失败计数
  - **页面级**：可见时 6 秒内至少 1 次 → 切走（`active:false`）再等 12 秒次数不变 → 切回 100ms 内立刻补 1 次
- 反证：把 `didUpdateWidget` 里的 `_poller.active = widget.active` 改成恒 `true` → 该用例失败（`Expected: <1> Actual: <3>`），恢复即绿
- 全量 `flutter test test/` → **504/504 PASS**（497 + 7）

## 交付

- APK **73,181,078 字节**，SHA256 `D6F63B87D9393493CD72BD8DE9123E0D3E5E2B56640C91FFB2D98344A376FF6B`，`versionCode=72`，`versionName=0.4.46-m4.46`
- 签名：`CN=Android Debug`（与手机已装版本同签名，可直接覆盖升级）
- 三处同哈希 + `/api/v1/app/version` 回读 + `node tools/verify-release.mjs` 四项一致

## 限制与下一步

- 桌面直播页仍用自己的退避节奏（M4.38 的 `desktopPollDelay`），没有并入 `PollCoordinator`——两者规则一致，但代码还分着；下次拆 `desktop_session_screen` 时一起收。
- 插件侧还没有推送通道（WebSocket 事件流），轮询仍是唯一手段；计划里「中长期改推送」还没做。
- 第二阶段剩余：⑧ 统一「会话」入口（抽屉只留一个「会话」区，分「远程电脑 / 本机直连」，顶栏历史、抽屉历史、工作区会话列表都进同一套会话中心）；⑨ 「手机 / 电脑」改名「本机对话 / 远程电脑」并加首次切换说明。
