# M2.4 增补契约：删除演示数据 + 界面减法

> 版本：v1.0（2026-11-03）· 唯一契约 · 上游：M2.3 UI 重做（`app/lib/theme/app_theme.dart` 设计系统）
> 用户原话：「太繁琐了，把演示数据删了，简洁一点」

## 0. 目标

1. **演示数据清零**：App 里不再存在任何假设备、假会话、假任务、假工作区、假审计、假配对码、「演示数据/演示模式」字样与演示审批入口。
2. **界面减法**：六页只保留「当前状态 + 一个主动作 + 真实内容」，删掉装饰性卡片、重复说明、demo 快捷 chips、假的统计/审计。
3. **未连接 = 空态引导**：五页统一空态（图标 + 一句标题 + 一句说明 + 「连接电脑」按钮），点了跳「真实连接」页。
4. 连接后的真实功能（对话/历史/任务/审批/通知/折叠/主题/分享/紧急停止）**一个都不能少**。

## 1. 删除清单（必须全部清掉）

| 位置 | 处理 |
|---|---|
| `app/lib/data/demo_store.dart` | **删除整个文件** |
| `app/lib/models.dart` 的 `DemoDevice` | 删除 |
| `app/lib/app.dart` | 删除 `DemoStore` 创建/`StoreScope`/`dispose`，只保留 `LiveScope` + `ThemeScope` |
| `app/lib/screens/root_shell.dart` | 删除 `store` 参数，五页只传 `liveStore`（+ `shareGateway`） |
| `app/lib/widgets/common.dart` | 删除 `DemoBadge`、`StoreScope`；`ModeBadge` 改为只在已连接时显示，或直接删除 |
| `app/lib/screens/assistant_screen.dart` | 删除 `_buildDemoMessages`、`_showApprovalDemo`、demo 审批卡片、快捷提示 chips、demo 模式文案 |
| `app/lib/screens/tasks_screen.dart` | 删除 demo 任务列表与 demo 任务详情（`演示模式任务详情`） |
| `app/lib/screens/control_screen.dart` | 删除 `DemoDevice` 卡片、假配对码 `824613` 展示、demo 权限开关交互；改为真实设备状态 |
| `app/lib/screens/projects_screen.dart` | 删除假工作区列表与假文件树说明 |
| `app/lib/screens/profile_screen.dart` | 删除假审计日志、`user@local · 演示账号`、`演示版不提供退出登录` 等文案 |
| `app/lib/data/live_store.dart` | 删除「未连接 · 演示模式」「演示模式下误点发送」等注释/文案（状态文案见 §3） |
| `app/lib/widgets/timeline.dart` | 删除「演示数据没有 type」注释，回退逻辑保留 |

删完后全仓 `grep -i "演示\|demo" app/lib` 只允许出现：`demo` 作为无关英文（理想为 0），中文「演示」必须为 0。

## 2. 六页减法（具体）

### AI 助手（`assistant_screen.dart`）
- 未连接：**整页空态**（无输入框、无快捷 chips、无设备卡）：图标 32、标题「还没有连接电脑」、说明「连接后在这里和电脑上的 DeepSeek Harness 对话」，按钮「连接你的电脑」→ `ConnectScreen`。
- 已连接：顶部只保留一行状态条（8px 圆点 + 设备名 + 「已连接」+ 会话切换图标 + 分享图标），下面直接是消息流；**删掉**原来的设备大卡、`ModeBadge`、底部「演示版…」说明行。
- 输入区保留胶囊输入框 + 圆形发送键；执行中/排队行为不变。

### 任务（`tasks_screen.dart`）
- 未连接：空态「连接后在这里看任务」+ 按钮。
- 已连接：保留筛选胶囊 + 任务卡（状态、标题、工作区、时间、进度），**删掉**顶部的 2/1/1 统计三卡与副标题。

### 电脑（`control_screen.dart`）
- 未连接：空态「连接后在这里管理这台电脑」+ 按钮。
- 已连接：两张卡——①设备卡（设备名、Agent 版本、Harness 版本、在线状态、最近在线）；②权限卡（6 级权限压缩为一行摘要「当前权限 3 级 · 项目文件」+「查看权限说明」展开弹层）；③紧急停止（保留危险色滑块 + 一行说明）。
- **删除**假配对码展示（配对码由电脑端 Agent 启动时打印，不在手机展示假码）。

### 项目（`projects_screen.dart`）
- 未连接：空态「连接后在这里管理授权目录」+ 按钮。
- 已连接：只列真实 `workspaceRoots`（一行一个路径 + 当前会话工作区高亮），顶部一行说明「AI 只能看到你授权的目录」；删除假的 128/42/9 文件数卡片、假的「授权新目录」假按钮。

### 我的（`profile_screen.dart`）
- 保留：账号行（本地设备名/版本即可）、连接状态行（已连接设备或「未连接」+ 连接按钮）、外观（跟随系统/浅色/深色）、关于（版本号）。
- **删除**：审计日志整块、演示账号邮箱、`演示版不提供退出登录`、重复的「我的设备」大卡（并入连接状态行）。

### 连接（`connect_screen.dart`）
- 字段只留：服务器地址（含粘贴/清空）、配对码 6 格、主按钮「连接」+ 次按钮「测试连接」。
- 连接步骤压成一行小字：「电脑端运行 Agent → 填地址与配对码 → 连接」；删除「演示模式」chip、「未连接时保持演示数据」文案、重复的步骤清单长文。
- 成功/失败提示保留。

## 3. 状态文案

| 状态 | 文案 |
|---|---|
| 未连接 | `未连接` |
| 连接中 | `正在连接…` |
| 已连接 | `已连接 · {deviceName}` |
| 重连中 | `正在重连…` |
| 失败 | `连接失败`（附一行原因） |

## 4. 空态组件（新增 `app/lib/widgets/empty_state.dart`）

`EmptyState(icon, title, description, actionLabel, onAction)`：
- 居中，垂直位置约屏高 38%；图标 32 / `text3`；标题 15/600；说明 12.5/`text2`/行高 1.5；按钮为 primary 胶囊（高 44，左右 24）。
- 五页复用；不在空态里放大段说明。

## 5. 验收（M2.4）

| 编号 | 验收 |
|---|---|
| M2.4-A1 | `grep -ri "演示" app/lib` 为 0；`demo_store.dart` 不存在；`DemoDevice`/`DemoBadge`/`StoreScope` 无引用 |
| M2.4-A2 | 未连接时五 Tab 均显示空态（助手/任务/电脑/项目），我的页显示未连接 + 连接入口；无任何假数据 |
| M2.4-A3 | 点空态按钮进入连接页；填地址 + 配对码可连接（真实链路仍 4/4 PASS 行为不变） |
| M2.4-A4 | 已连接时：对话/历史/任务/审批/取消/折叠/主题/分享/紧急停止均保留可操作 |
| M2.4-A5 | `flutter test` 全绿（既有 154 中 demo 断言改写；新增 `empty_state_test.dart` ≥8；总数 ≥150） |
| M2.4-A6 | 版本 `0.1.5+6` / `versionName = "0.1.5-m2.4"`；`flutter build apk --debug` 成功；`aapt` 校验 `versionName='0.1.5-m2.4' versionCode='6'` |

## 6. 约束

- 只改 `app/` 与 `docs/mobile/README.md`；不动 `backend/`、`agent/`、`tools/`、`docs/design/`（本文件除外）。
- 零新增 pub 依赖；不使用 `flutter analyze`（中文路径崩溃），用 `flutter test` + `flutter build apk` 作为门禁。
- 视觉 token 全部来自 `app/lib/theme/app_theme.dart`，不得新增硬编码颜色。
- 每页改动后同步 `docs/mobile/README.md`（新增「M2.4：无演示数据 + 空态」小节）。
- 完成后汇报：删除清单、每页变化、`flutter test` 数字、APK 大小与 `aapt` 输出、仍需真机确认项。
