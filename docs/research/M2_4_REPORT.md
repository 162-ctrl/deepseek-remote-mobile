# M2.4 交付报告：删除演示数据 + 界面减法

> 日期：2026-11-03 · 阶段：M2.4（M1 / M1.1 / M2 / M2.1 / M2.2 / M2.3 已交付）· 契约：[`docs/design/M2_4_SIMPLIFY_DELTA.md`](../design/M2_4_SIMPLIFY_DELTA.md) v1.0
> 结论：**演示数据已全部删除，未连接时六个页面统一为「连接空态」；界面按「状态 + 一个主动作 + 真实内容」做减法。** `flutter test` **164/164** 全绿，真实链路回归 **6/6 PASS**，APK `versionName=0.1.5-m2.4`。

## 1. 用户反馈与目标

用户看过 M2.3 视觉重构版后的两轮反馈：

> 「太繁琐了，把演示数据删了，简洁一点」

旧版的问题很具体：
- 未连接时五个页面展示的是**本地假数据**（假设备 `DESKTOP-XXXXXXX`、假会话、假任务、假工作区 128/42/9 个文件、假审计日志、假配对码 `824613`），只在角落挂一个「演示数据」徽标；
- 页面上堆了**统计三卡、权限六级长列表、设备大卡、授权新目录假按钮、四步连接说明、审计列表**等大量元素，信息密度高但没有一件能真正操作；
- 用户装上后看到的是「演示版」的样子，而不是「自己的电脑」。

M2.4 的目标：**假数据清零、界面减到最少、未连接就明确引导去连接。**

## 2. 删除清单（全部已完成）

| 删除项 | 说明 |
|---|---|
| `app/lib/data/demo_store.dart` | 整个文件删除（原 17KB 演示数据源） |
| `models.dart` 的 `DemoDevice` / `WorkspaceEntry` / `AuditEntry` | 随演示数据一起移除 |
| `common.dart` 的 `DemoBadge` / `StoreScope` / `ModeBadge` | 演示徽标、演示 Store 作用域 |
| `app.dart` 的 DemoStore / StoreScope | 只保留 `ThemeScope` + `LiveScope` |
| `root_shell.dart` 与五页的 `DemoStore` 参数 | 六页只依赖真实 `LiveStore` |
| 助手页 | 演示消息列表、演示审批入口、快捷提示 chips、设备大卡、底部「演示版…」说明 |
| 任务页 | 演示任务列表/详情、顶部统计三卡、副标题 |
| 电脑页 | 假设备卡、假配对码、六级权限长列表（改一行摘要 + 弹层）、演示开关 |
| 项目页 | 假工作区卡片（128/42/9 文件）、假「授权新目录」按钮、假文件树说明 |
| 我的页 | 假审计日志、`user@local · 演示账号`、`演示版不提供退出登录`、重复设备大卡 |
| 连接页 | 「演示模式」chip、「未连接时保持演示数据」文案、四步清单长文（压成一行小字） |

**验证**：`Select-String -Path app/lib/**/*.dart -Pattern '演示|DemoStore|DemoBadge|DemoDevice|demo_store'` → **0 处**。

## 3. 六页变化

| 页面 | M2.4 之后 |
|---|---|
| **AI 助手** | 未连接：整页空态（图标 +「还没有连接电脑」+ 一行说明 +「连接你的电脑」）。已连接：顶部只留**一行状态条**（圆点 + 设备名 + 已连接 + 会话切换 + 分享），下面直接是消息流；输入区为胶囊输入框 + 圆形发送 |
| **任务** | 未连接：空态「连接后在这里看任务」。已连接：筛选胶囊 + 任务卡（状态/标题/工作区/时间/进度），无统计三卡、无副标题 |
| **电脑** | 未连接：空态「连接后在这里管理这台电脑」。已连接：设备卡（设备名/Agent/Harness/在线/最近在线）+ 权限一行摘要（点开弹层看 3 级与高风险说明）+ 紧急停止 |
| **项目** | 未连接：空态「连接后在这里管理授权目录」。已连接：只列真实 `workspaceRoots`（当前会话工作区高亮）+ 一行「AI 只能看到你授权的目录」 |
| **我的** | 账号行 + 连接状态行（未连接给连接按钮）+ 外观三选（跟随系统/浅色/深色）+ 关于（版本号） |
| **连接** | 服务器地址、6 格配对码、「测试连接」/「连接」两个按钮 + 一行步骤小字 |

新增统一组件 `app/lib/widgets/empty_state.dart`（`EmptyState`：图标 32 / 标题 15 / 说明 12.5 / 胶囊主按钮，居中约屏高 38%），五页复用。

## 4. 验收证据（M2.4-A1..A6）

| 编号 | 要求 | 结果 |
|---|---|---|
| A1 | 演示数据清零 | ✅ `grep -ri "演示" app/lib` = 0；`demo_store.dart` 不存在；`DemoBadge`/`StoreScope`/`DemoDevice` 无引用 |
| A2 | 未连接显示空态 | ✅ `empty_state_test.dart` 9 项 + 重写的 `widget_test.dart` 4 项覆盖五页空态与连接入口 |
| A3 | 连接链路不变 | ✅ 真实链路回归 `node tools/m1-client.ts` → **6/6 PASS**，证据 `docs/research/evidence/m1/e2e-2026-11-03T09-24-31-458Z.json` |
| A4 | 已连接功能保留 | ✅ 对话/历史/任务/审批/取消/折叠/主题/分享/紧急停止代码路径保留（既有 154 项单测零回归） |
| A5 | 测试 | ✅ `flutter test` **164/164**（M1 68 + M1.1 27 + M2 16 + M2.1 13 + M2.2 19 + M2.3 11 + M2.4 10） |
| A6 | 版本与构建 | ✅ `versionName='0.1.5-m2.4' versionCode='6'`（aapt）；`pubspec 0.1.5+6`、`build.gradle.kts` 显式 versionName；`flutter build apk --debug` 成功 |

## 5. 交付

| 项 | 值 |
|---|---|
| APK | `DeepSeek Remote AI 手机端 v0.1.5-m2.4.apk`（150,758,731 字节，143.8 MiB） |
| SHA256 | `4BECB7D97D0719CEEF45A3492EE3C8C474CD74DC911B507CC201C9A86BDC945A` |
| 版本 | 安装器/系统设置显示 **0.1.5-m2.4**（versionCode 6）；关于页 `手机端 v0.1.5-m2.4` |
| 公网下载 | `https://<公网隧道>.trycloudflare.com/DeepSeek-Remote-v0.1.5-m2.4.apk` |
| 局域网下载 | `http://192.168.1.x:8099/DeepSeek-Remote-v0.1.5-m2.4.apk` |
| 电脑端连接 | 隧道 `https://<公网隧道>.trycloudflare.com`、配对码 `824613` |

## 6. 已知限制

1. 本机无可用模拟器/真机（`adb devices` 为空、headless 模拟器被环境回收），**空态与已连接界面的真机截图未补拍**；布局由 164 项单测与 `flutter build` 覆盖。
2. 删除演示数据后，**未连接时无法体验任何页面功能**（只能看空态并进入连接页）——这是用户明确要求的预期行为。
3. 项目页暂只展示后端下发的 `workspaceRoots`；授权新目录、文件浏览属后续 B 档能力。
4. 电脑页权限摘要为手机端只读展示，实际权限由电脑端 Agent 配置决定。
5. `flutter analyze` 因中文路径崩溃未跑，门禁仍为 `flutter test` + `flutter build apk` + `aapt`。

## 7. 下一步（M2.5 / M3 候选）

1. **真机验收 M2.4 观感**：装新 APK → 先看未连接空态是否「足够干净」→ 连接后看六页信息密度 → 截图逐页反馈继续微调。
2. 真实数据补位：项目页文件浏览（B 档）、审计日志后端落地后替换「我的」里的占位。
3. 审批等待与执行槽解耦、多设备/账号、远程桌面 L1、签名 APK / Agent 安装包。
4. 云服务器/域名/TLS 采购（阶段 7–8 前置）与 18 项验收正式记录。

## 8. 证据索引

| 证据 | 路径 |
|---|---|
| 契约 | `docs/design/M2_4_SIMPLIFY_DELTA.md` |
| 测试 | `app/test/empty_state_test.dart`（9）、`app/test/widget_test.dart`（重写 4）；整体 164/164 |
| 构建 | `app/build/app/outputs/flutter-apk/app-debug.apk`（150,758,731 字节） |
| 版本校验 | `aapt dump badging` → `versionCode='6' versionName='0.1.5-m2.4'` |
| 真实链路回归 | `docs/research/evidence/m1/e2e-2026-11-03T09-24-31-458Z.json`（6/6 PASS） |
| 手机端文档 | `docs/mobile/README.md`（M2.4 增量、§6.1 无演示数据 + 空态） |
