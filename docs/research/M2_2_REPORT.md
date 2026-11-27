# M2.2 交付报告：手机端「手感对齐」A 档（折叠 / 立即发送 / 主题 / 分享卡 / 长按菜单）

> 日期：2026-11-03 · 阶段：M2.2（M0/M1/M1.1/M2/M2.1 已交付）· 契约：[`docs/design/M2_2_DELTA.md`](../design/M2_2_DELTA.md) v1.0
> 结论：**M2.2 六项全部达成**——完成轮自动折叠、排队消息「立即发送」、6 套主题可持久化、对话分享卡、长按菜单，以及 19 项新测试；`flutter test` **143/143** 全绿、`flutter build apk --debug` 成功，**零新增 pub 依赖**，既有 124 项测试零回归。

## 1. 一句话结论

手机端的「对话手感」补齐到 dsh-Go 一类客户端的水平：一轮任务结束后，中间的工具调用和思考过程自动收成一行「已完成 N 步 · 用时 Xs」，点开才展开；排队中的消息可以「立即发送」——系统先打断当前任务、等它停下再把你这条指令发出去（ACP 没有 turn 内插话，这是最接近的等价实现）；「我的 → 外观」可切换 6 套深色主题并记住选择；对话可一键生成本地分享卡 PNG；长按任意消息可以复制、重新发送或复制工具输出。所有 UI 逻辑由 19 项新单测覆盖，完整测试集 143/143 通过。

## 2. 交付物

| 层 | 文件 |
|---|---|
| 契约 | `docs/design/M2_2_DELTA.md`（Lead 产出：A1–A6 定义、验收口径、硬约束） |
| 主题 | `lib/theme/theme_controller.dart`、`lib/theme/app_theme.dart`（6 套 `AppPalette` + `ThemeExtension` + `buildAppTheme`）、`lib/services/settings_gateway.dart`、Android `SettingsBridge.kt`（SharedPreferences） |
| 折叠 | `lib/widgets/turn_fold.dart`（`groupTurnMessages` / `TurnSummaryCard`）、`lib/models.dart`（`TurnStats`）、`lib/data/live_store.dart`（轮次统计） |
| 立即发送 | `lib/data/live_store.dart`（`interruptTimeout` / `interruptAndSendQueuedPrompt`）、`lib/widgets/chat_items.dart`（排队气泡按钮）、`lib/screens/assistant_screen.dart` |
| 分享卡 | `lib/services/share_card.dart`、`lib/services/share_gateway.dart`、Android `ShareBridge.kt`、`ShareFileProvider.kt`、`res/xml/file_paths.xml` |
| 长按菜单 | `lib/widgets/chat_items.dart`、`lib/screens/assistant_screen.dart` |
| 接线 | `lib/app.dart`、`lib/root_shell.dart`（ThemeScope / 网关注入）、`MainActivity.kt`（三桥注册）、`AndroidManifest.xml`（provider） |
| 测试 | `app/test/ux_m2_2_test.dart`（19 项） |
| 文档 | `docs/mobile/README.md`（M2.2 增量、能力表、结构、测试数、限制） |

## 3. 六项验收

| 项 | 实现 | 证据 |
|---|---|---|
| **A1 完成自动折叠** | `groupTurnMessages` 只折叠「终态轮次中 toolCount>0 的连续 thinking/toolCall/toolResult」；`TurnSummaryCard` 显示「已完成 N 步 · 用时 Xs」（失败红 / 取消橙黄），点击展开原卡片并显示「收起」。最终回复不折叠、执行中不折叠。 | `ux_m2_2_test.dart` 折叠分组/统计/终态文案用例 |
| **A2 排队「立即发送」** | ACP 无 steer，采用「先 `task.cancel` → 等终态或 `interruptTimeout`(3s) 超时 → 发排队指令」；气泡按钮切换「立即发送 → 正在打断…」，`_interruptInFlight` 防重复；失败/取消也能继续。 | `ux_m2_2_test.dart` 立即发送/超时/防重用例 |
| **A3 6 套主题** | `AppPalette`（深海蓝 / 墨黑 / 暖沙 / 森林 / 樱粉 / 紫夜）+ `ThemeExtension` + `buildAppTheme(id)`；「我的 → 外观」色板弹层即时切换；Kotlin `deepseek_remote/settings` + SharedPreferences 持久化（`app_theme_id`），重启保留。 | 主题切换/持久化用例 + Kotlin 桥 |
| **A4 分享卡** | `share_card.dart` 取最近一轮问答构造卡片数据（1440 逻辑像素宽、脱敏），`share_gateway` 经 `deepseek_remote/share` 交给 Kotlin，`ShareBridge` 写入 `cacheDir/share/` 并用自实现 `ShareFileProvider`（零 androidx）+ `ACTION_SEND` 分享 PNG；空对话时分享按钮置灰。 | 分享卡数据/按钮状态用例；`ShareFileProvider` 只读校验 |
| **A5 长按菜单** | 长按消息：复制全文、重新发送（填入输入框，不自动发）、复制工具输出（仅 tool_result 有输出时）。 | `ux_m2_2_test.dart` 菜单动作用例 |
| **A6 测试与构建** | 新增 19 项，`flutter test` **143/143**；`flutter build apk --debug` 成功。 | 见 §4 |

## 4. 验收证据

| 项 | 结果 | 证据 |
|---|---|---|
| 完整测试集 | **143/143 通过**（M1 68 + M1.1 27 + M2 16 + M2.1 13 + M2.2 19），Lead 独立复跑 exit 0 | `cd app; flutter test` |
| Debug APK | **成功**，**150.8 MB（150,797,767 字节）**；`aapt dump badging` → `versionName=0.1.3-m2.2`、`versionCode=4`，2026-11-03 12:24 | `app/build/app/outputs/flutter-apk/app-debug.apk` |
| APK 交付 | 已复制到根目录：`DeepSeek Remote AI 手机端 v0.1.3-m2.2.apk`（替换旧 M2.1 包）；下载通道见 §8 更新 | 项目根目录 |
| 依赖约束 | 未新增 pub 依赖；Android 侧仅用平台 API（Notification / SharedPreferences / ContentProvider / Canvas） | `pubspec.yaml`、`build.gradle` 未改依赖 |
| 回归 | M1/M1.1/M2/M2.1 既有 124 项全部保持通过 | 同上 |

## 5. 已知限制

1. **真机未实测**：系统分享面板、主题切换的实际观感、折叠动画未在真机上验收——本机 `adb devices` 无设备、模拟器仍被环境回收。
2. **主题仅深色 6 套**：`TaskStatus` 等 `const` 枚举色仍用默认令牌，个别次要组件未全量 token 化（主题切换后仍可读，但与主色不完全统一）。
3. **「立即发送」是打断 + 改说**：ACP 协议没有 turn 内插话能力；打断后当前任务会被取消，已在 UI 文案「将打断当前任务」中明示。
4. **分享卡**：只含最近一轮问答（用户指令 + AI 最终回复 + 步数/耗时），不含工具细节；渲染在端口层 Canvas，未做多语言/超长文本的极端排版。
5. `flutter analyze` 仍未跑（本机中文路径下崩溃），质量门禁为 `flutter test` + `flutter build apk`。
6. **版本号显示问题已修复（2026-11-03 补丁）**：此前 `pubspec.yaml` 仍是 `0.1.0+1`，导致安装器/系统设置/「我的→关于」都显示 **0.1.0**（根目录文件名里的 v0.1.3-m2.2 只是人工命名）。现已改为 `version: 0.1.3+4`、`build.gradle.kts` 的 `versionName = "0.1.3-m2.2"`，并在「关于」中显示 `手机端 v0.1.3-m2.2 · M2.2 手感版`；重构建后 `aapt dump badging` 验证为 `versionName='0.1.3-m2.2', versionCode='4'`。

## 6. 下一步（M2.3 / M3 候选）

1. **真机验收 M2.2**：装 `v0.1.3-m2.2.apk`，逐项验证折叠/立即发送/主题持久化/分享面板/长按菜单，并补截图进 `docs/mobile/screenshots/`。
2. 亮色主题与主题跟随系统（当前仅深色）。
3. B 档手感：工作区文件浏览与预览、代码块高亮、语音输入、消息内搜索。
4. M3 能力面：多设备/多账号、远程桌面 L1（看一眼）、签名 APK 与安装包。

## 7. 证据索引

| 证据 | 路径 |
|---|---|
| 契约 | `docs/design/M2_2_DELTA.md` |
| 测试 | `app/test/ux_m2_2_test.dart`（19 项）+ 既有 124 项 |
| 构建产物 | `app/build/app/outputs/flutter-apk/app-debug.apk` → 根目录 `DeepSeek Remote AI 手机端 v0.1.3-m2.2.apk` |
| 版本校验 | `aapt dump badging app-debug.apk` → `versionName='0.1.3-m2.2' versionCode='4'` |
| 手机端文档 | `docs/mobile/README.md` |

## 8. 下载通道（2026-11-03 补充）

| 通道 | 地址 | 说明 |
|---|---|---|
| 公网（Cloudflare 临时隧道） | `https://<公网隧道>.trycloudflare.com/DeepSeek-Remote-v0.1.3-m2.2.apk` | 150,797,767 字节；隧道重启即失效，以当场回复的地址为准 |
| 局域网（同一 WiFi） | `http://192.168.1.x:8099/DeepSeek-Remote-v0.1.3-m2.2.apk` | 本机 `python -m http.server 8099`，需电脑与手机同一局域网 |
| 项目根目录 | `DeepSeek Remote AI 手机端 v0.1.3-m2.2.apk` | 直接复制/用微信/QQ 传到手机 |

---

*本报告数字均来自本轮实际运行；未在真机验证的项已在 §5 明确标注。*
