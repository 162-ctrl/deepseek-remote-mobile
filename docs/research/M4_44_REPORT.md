# M4.44 报告：第一阶段（安全与行为正确性）六条全部落地

日期：2026-11-23 · App `0.4.44-m4.44`（versionCode 70）· 插件 `0.2.32`
测试：App **497/497**（基线 483）· 插件 **143/143**（基线 106 → 133 → 143）

## 一句话

三阶段收束计划里第一阶段的六条——紧急停止的真实语义、审批「关闭≠拒绝」、Key 与 token 的安全存储、统一的地址策略、可核验的发布链路、能跑起来的静态分析——全部改完并有测试钉住；第二阶段（轮询协调与信息架构）和第三阶段（拆代码）尚未开始。

## 逐条结果

| 条 | 问题 | 改法 | 证据 |
|---|---|---|---|
| ① 紧急停止 | 原来只是 `disconnect()`，任务还在电脑上跑，用户以为停了 | 新增 `LiveStore.emergencyStop({timeout})`：先发 `task.cancel` → `Completer` 等终态或 3 秒 → 再断开；返回 `taskCancelled / disconnectedOnly / cancelUnconfirmed` 三态，界面原话回显 | `app/test/emergency_stop_m4_44_test.dart` 4 例（确认/超时/无任务/未连接） |
| ② 审批弹层 | 下滑或返回键直接算「拒绝」，误触就杀掉电脑上的操作 | `ApprovalDecision` 改 `approved / denied / later`；下滑、返回、超时都只产生 `later`，不发决定；暂缓的 approvalId 进 `_deferredApprovals`，不再立刻重弹 | `app/test/approval_later_m4_44_test.dart` 5 例（下滑不发、显式拒绝才发、允许、无待审批、超时） |
| ③ Key 与 token 存储 | API Key 明文躺在 `cloud_chat.json`；`tokens.json` 里 244 条原始 token 谁都读得到 | App：`CloudChatStore` 拆两层，`baseUrl/model` 留 JSON，`apiKey` 进 `flutter_secure_storage`，旧文件自动迁移；插件：`tokens.json` 只存 `sha256(token)`，配对时返回一次明文，旧明文文件一次性迁移；新增 `lib/token-acl.js` 收紧 ACL | `session_store_secure_m4_43_test.dart` 4 例、`cloud_key_secure_m4_44_test.dart` 4 例、`token-hygiene.test.js` 7 例、`token-acl.test.js` 7 例；现网 `tokens.json` 285 行全部是 `tokenHash`，明文 0 行 |
| ④ 地址策略 | 只有 `cleartextTrafficPermitted`，公网 http 也能连，用户在裸奔 | 新增 `NetworkUrlPolicy`：公网必须 `https/wss`；`http` 只允许回环与私网并提示「此连接未加密」；接进连接页（发送前拦截 + 输入即提示）、云端对话配置、更新检查与下载 | `network_url_policy_m4_44_test.dart` 7 例、`connect_policy_m4_44_test.dart` 3 例 |
| ⑤ 发布链路 | release 用 debug 签名，版本号靠手抄，内网地址写死在包里 | 独立 keystore（仓库外 `C:\Users\user\dsh-tools\keys\dsh-release.jks`，口令进 `key.properties` 且已 gitignore）；`tools/verify-release.mjs` 校验 versionCode/size/sha256/versionName 四项一致；`defaultServerUrl` 改为 `--dart-define` 注入，正式包不内置任何个人地址 | `apksigner verify` 证书 `CN=DeepSeek Remote`；`verify-release.mjs` 四项全绿 |
| ⑥ 静态分析 | `flutter analyze` 在中文路径下必崩，只能靠测试兜 | 建 ASCII junction `C:\Users\user\dsh-tools\build\deepseek-mobile` 指向 `app`，analyze 79 秒跑完；并清掉 7 条机械告警（死 import、多余 `!`、多余插值花括号） | 37 → 30 条，**0 error**（剩余均为死代码/未用参数告警，见下） |

## 这一轮踩到的两个真坑

1. **ACL 收紧把自己锁在门外**：第一版 `hardenPath` 先 `/inheritance:r` 再授权，结果 `tokens.json` 变成谁都读不了（`icacls`、`takeown`、`Remove-Item` 全 Access denied）。恢复办法是**重命名整个 state 目录**再重建（目录本身还有 Everyone 全权），随后把顺序改成「先授权（账户名 + 当前 SID + SYSTEM + Administrators）→ 再断继承 → 读回并用 `probe` 真读一次 → 读不了就 `/inheritance:e` + `Everyone:(R)` 兜底」。
2. **Flutter 测试的命中区域不等于渲染区域**：`tester.binding.setSurfaceSize` 只改渲染，命中测试仍按 `tester.view` 的 800x600 裁剪，弹层下半截按钮「找得到点不到」；必须改 `tester.view.physicalSize`。

## 剩余与限制

- 第 ⑥ 条还剩 30 条告警，集中在删页留下的死代码（`_TaskCard`、`_ArchivedCard`、`_GreetingBlock`、`_RichText`、`_openCloudChat`），删除属于第三阶段「碰到哪拆哪」，本轮不动。
- 旧 state 目录 `<DSH 数据目录>\dsh-plugin-m1.hold\tokens.json`（62,518 B）仍锁死，需要管理员 `takeown` 才能清理；已不参与运行。
- 插件 0.2.32 要**完整重开 DSH** 才生效（`/api/v1/health` 现在还是 0.2.31）；生效后 `tokens.json` 才会按 `agent:<clientName>` 去重，`node tools/prune-tokens.mjs` 也能一次清掉历史堆积。
- 第二阶段（⑦轮询协调器 ⑧统一会话入口 ⑨模式改名）与第三阶段（拆 LiveStore / desktop_session_screen / assistant_screen）尚未开始。

## 交付

- APK：`dist/DeepSeek-Remote-latest.apk`，**73,181,078 字节**，`versionCode 70`，`0.4.44-m4.44`，SHA256 `333CFEB45262F1D19D398D11BC323AABC5A04D19F9CBDF0F4EFFAAE2F2BDB487`，三处同哈希，`/api/v1/app/version` 回读一致
- 签名：`CN=DeepSeek Remote, OU=Personal, O=Personal, L=Shanghai, ST=Shanghai, C=CN`，证书 SHA-256 `680c35f35e327f305326c8938a68670f6c2350e7d86f4cda64b4d9328dff6c8e`
- 复跑命令：`cd app && flutter test test/`、`cd dsh-plugin-m1 && node --test "test/*.test.js"`、`node tools/verify-release.mjs`、`cd C:\Users\user\dsh-tools\build\deepseek-mobile && flutter analyze`
