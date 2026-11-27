# M2.2 契约：手机端手感对齐（A 档：远程体验）

> 日期：2026-11-03 · 状态：已拍板（用户选 A）· 作者：Lead
> 目标：在不改架构、不引第三方 pub 依赖的前提下，把手机端从“功能可用”打磨到“顺手”，对标社区 dsh-Go 的移动交互。**只改 app/，后端/Agent 协议零改动。**

## 0. 背景与边界

- 用户已选 **A**：保持远程控制方向，对齐“顺手”的体验（插话/排队立即发送、完成自动折叠、主题、分享卡），不做手机本地 PRoot 运行 DSH、不做无障碍手机操控、不做加密回放链接（需要额外后端+web，后置）。
- 硬约束：
  1. **零新增 pub 依赖**（与 M2 一致）：主题持久化、分享卡、剪贴板都走现有 Kotlin MethodChannel 或 Flutter 内置能力。
  2. 不改 `backend/`、`agent/`、`docs/design/`（本文件除外）。
  3. 不破坏 M1/M1.1/M2/M2.1 现有行为：真实连接、审批、任务、断线补拉、排队自动发送全部保留。
  4. 项目路径含中文：**不要用 `flutter analyze`**（会崩），用 `flutter test` + `flutter build apk --debug` 校验。
  5. 中文 UI、深色主题、Material 3 风格保持一致。

## 1. 验收项（M2.2-A1..A6）

### M2.2-A1 完成自动折叠（最关键的手感项）

- 一轮任务结束（`task.state` = completed / failed / cancelled）后，该轮内**所有**工具调用卡片（`ChatItemKind.toolCall` / `toolResult`）与思考过程自动折叠为一**行摘要**：
  - 文案：`已完成 4 步 · 用时 12s`（失败：`失败 · 3 步 · 用时 8s`，红色；取消：`已取消 · 2 步 · 用时 5s`，橙黄色）；计算“步数”= 该轮 toolCall 卡片数，“用时”= 该轮首条工具事件到终态的毫秒差（无数据时省略用时）。
  - 摘要行点击展开/收起；展开时保持原卡片外观与顺序。
  - 助手最终文本回复**不**折叠，始终可见。
  - 实时执行中不折叠（只有任务终态后折叠一次；用户手动展开后不再自动收起）。
- 数据：`ChatItem` 已有 `kind`、`time`；需要能按“轮”分组（同一任务 `taskId` 或从最近一条 user 消息到终态）。实现上建议在 `LiveStore` 或 `assistant_screen` 构造消息列表时按 taskId/turn 分组并给 `_ToolGroup` 组件传汇总信息；不要改后端协议。

### M2.2-A2 排队「立即发送」（插话的现实实现）

- ACP 每会话只允许一个 in-flight turn（无 steer 原语，已实测），所以“插话”的落地语义是：**排队消息可一键打断当前任务并立即发送**。
- 排队气泡（`_QueuedBubble`）增加两个动作：
  - `立即发送`：先发 `task.cancel`（复用现有 cancel 路径）→ 收到该任务终态（completed/failed/cancelled）或 3s 超时 → 把排队消息作为新 prompt 发出；发送成功后移除排队气泡。
  - `移除`：保留现有行为。
- 交互文案：按钮下方小字 `将打断当前任务`；点击后按钮变 `正在打断…` 并禁用，防重复点击。
- 已知限制（写进报告）：不是真正的“turn 内插话”，而是“打断 + 改说这句”；真正的 steer 需要 Harness 提供能力。

### M2.2-A3 主题 6 套 + 持久化

- 在现有 `docs/concept/mobile_ui.png` 的深色风格基础上提供 6 套主题：
  1. `深海蓝`（默认，现 `AppColors` 值）
  2. `墨黑`（背景 #05070B、主色 #9AA7FF）
  3. `暖沙`（背景 #14100C、主色 #E8A15C）
  4. `森林`（背景 #08110D、主色 #46C08A）
  5. `樱粉`（背景 #140A10、主色 #F07FA6）
  6. `紫夜`（背景 #0B0814、主色 #A78BFA）
- 每套提供 bg / surface / surfaceHigh / stroke / primary / primarySoft / text / textMuted 8 个色值，其余语义色（success/warning/danger/teal）沿用；`buildAppTheme()` 改接受主题 ID。
- 「我的」页新增「外观」入口：底部弹层展示 6 个色板（名称 + 3 个色点预览），点选立即生效；**重启保留**（持久化走 Kotlin MethodChannel，见 §2）。
- 演示模式/真实模式都生效。

### M2.2-A4 分享卡（图片分享）

- AI 助手页 AppBar 增加分享图标：把最近一轮对话（用户最后一条 + 助手最终回复 + 完成摘要行 + 会话标题/设备名 + 时间）渲染成一张竖版卡片（宽 1080、内边距 48、深色主题取当前主题主色），**不包含**工具原始命令、路径、token 等敏感内容（只显示摘要与正文）。
- 生成 PNG 后用系统分享面板分享（`Intent.ACTION_SEND`，`image/png`，通过 Kotlin MethodChannel + FileProvider）；分享失败给 SnackBar 提示，不崩溃。
- 没有可分享内容时按钮置灰。

### M2.2-A5 消息长按菜单

- 任意助手/用户文本气泡长按：`复制`（Clipboard 内置）、`重新发送`（把该用户文本写入输入框，不自动发）。
- 工具卡片长按：`复制输出`（取 `toolResult` 文本）。
- 仅真实/演示文本气泡；排队气泡不参与。

### M2.2-A6 测试与构建

- 新增测试 ≥ 12 个（建议 `app/test/ux_m2_2_test.dart`）：
  - 折叠：终态后生成摘要行、展开/收起、失败/取消配色、最终回复不被折叠；
  - 立即发送：cancel 先于 prompt、终态后发出、3s 超时兜底、防重复点击；
  - 主题：6 套加载成功、选择后 ThemeData 主色变化、持久化读写（Fake SettingsBridge）；
  - 分享卡：内容构造含用户/助手/摘要、脱敏（无工具命令）、空内容禁用；
  - 长按复制/重新发送回调。
- `flutter test` 全绿（现有 **124** 项不得回归），`flutter build apk --debug` 成功（记录 APK 大小）。

## 2. 技术约定

### 2.1 Kotlin MethodChannel（零 pub 依赖）

在 `app/android/app/src/main/kotlin/com/deepseek/remote/deepseek_remote_app/` 增加：

- `SettingsBridge.kt` → channel `deepseek_remote/settings`
  - `getString(key)` → `SharedPreferences`（`deepseek_remote`）读，缺省 `null` 或空串
  - `setString(key, value)` → 写
- `ShareBridge.kt` → channel `deepseek_remote/share`
  - `shareImage(bytes: ByteArray, fileName: String, chooserTitle: String)`：写入 `cacheDir/share/{fileName}`，用 `FileProvider.getUriForFile`（authority `${applicationId}.fileprovider`）启动 `Intent.createChooser(ACTION_SEND, image/png, EXTRA_STREAM)`，返回 `true/false`。
  - FileProvider：`AndroidManifest.xml` 加 `<provider>`，`res/xml/file_paths.xml` 声明 `cache-path name="share" path="share/"`。
  - 注意：`FileProvider` 用 AndroidX 的 `androidx.core.content.FileProvider`（Flutter 模板已带 androidx.core 依赖）；若编译报错，改用 `MediaStore.Images` 写入相册再分享（备选，需说明）。
- 在 `MainActivity.kt` 注册两个 channel；Dart 侧 `lib/services/settings_gateway.dart`、`lib/services/share_gateway.dart`（接口 + MethodChannel 实现 + Fake，便于测试注入）。

### 2.2 文件范围（仅 app/）

- 允许改：`app/lib/**`、`app/test/**`、`app/android/**`、`app/pubspec.yaml`（**不新增依赖**）、`docs/mobile/README.md`。
- 禁止改：`backend/`、`agent/`、`tools/`、`docs/design/`、根目录文档。
- 关键现有文件（必读再改）：
  - `app/lib/models.dart`（ChatItem/TaskEvent/queued/seq）
  - `app/lib/data/live_store.dart`（发送/取消/排队/终态事件）
  - `app/lib/screens/assistant_screen.dart`（AppBar、列表、composer）
  - `app/lib/widgets/chat_items.dart`（消息卡片/排队气泡）
  - `app/lib/theme/app_theme.dart`（主题）
  - `app/lib/screens/profile_screen.dart`（「我的」页）
  - `app/android/app/src/main/kotlin/.../MainActivity.kt`、`NotificationBridge.kt`（channel 注册方式参考）

## 3. 交付物

1. 代码（如上范围）+ `docs/mobile/README.md` 更新（外观入口、分享卡、立即发送、折叠行为、限制）。
2. `flutter test` 输出（全绿，数量）+ APK 路径/大小。
3. 汇报（≤30 行）：改动文件、测试与构建结果、已知限制（无真机/模拟器不稳导致 UI 截图缺失）。

## 4. 里程碑（建议顺序）

1. A1 折叠 + A2 立即发送（核心手感，先做，可独立验收）
2. A3 主题（Kotlin SettingsBridge + 6 套 ThemeData）
3. A5 长按菜单（快）
4. A4 分享卡（Kotlin ShareBridge + FileProvider，最易出编译问题，放最后）
5. A6 测试补齐 + 构建 + 文档
