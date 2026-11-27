# 代码评审 · DeepSeek Remote AI 手机端

> 评审时间：2026-11-22 20:05（Asia/Shanghai）
> 评审对象：`<项目根>`（App 0.4.42+68 / 插件 0.2.30）
> 评审范围：dsh 会话记录复核 + 代码实读 + 动手验证
> 结论摘要：**基线健康（测试 466/466、插件 106/106），但发现 1 个会导致「会话永久卡死」的真实缺陷，已修复并加测试。**

---

## 一、先说结论

这个项目完成度相当高：文档详尽（1273 行 PROJECT_STATUS）、测试覆盖扎实（App 466 例 / 插件 101 例）、零 TODO 残留、`mounted` 保护 100 处、无硬编码路径、无 `ws` 之类多余依赖（插件自己实现了 RFC 6455）。

`flutter test` 实测 **466/466 通过**，插件实测 **106/106 通过**，基线是干净的。

但测试全绿不代表没有 bug。本轮找到的问题里，最严重的一条**任何单测都测不到**——它只在「agent 在任务进行中断线」这个组合下出现，而现有测试从不模拟断线。

---

## 二、已修复（2 项）

### 2.1 【严重】agent 任务中途掉线 → 会话永久锁死

**现象**：某个会话在跑任务时，电脑端 agent 断线（插件重载、DSH 重启、网络抖动）。之后在这个会话里发任何指令都提示：

> 该会话已有进行中的 turn

而且永远好不了，只能重启插件。

**根因**（`lib/hub.js`）：

`busy` 这个锁只有两个变动点——
- `prompt.send` 时置 `true`（第 316 行）
- 收到 `task.state` 的 `completed`/`failed`/`cancelled` 时置 `false`（第 358 行）

问题在于：**解锁完全依赖 agent 主动发终态事件**。agent 在任务中途断线，终态永远不会来，`busy` 就永久停在 `true`。而 `#attachAgent` 的 `close` 回调（原第 236-241 行）只清了 `#agent` 和 `#agentStatus`，**根本没碰 `#conversations`**。

**证据**：用真实 WebSocket 走完整链路复现（配对 → 建会话 → 发 prompt 置 busy → agent 断线不发终态 → 重连 → 再发 prompt）：

```
步骤3 首次 prompt 已转发给 agent: true
步骤4 agent 断线（未发终态）
步骤5 agent 重连
=== 复现结果 ===
❌ 复现成功：agent 重连后该会话仍被拒绝 → {"code":"SESSION_BUSY","message":"session busy"}
```

**修复**（`lib/hub.js`，+15 行）：

在 `#attachAgent` 的 `close` 回调里调用新增的 `#releaseAllBusy()`，把该 agent 名下所有会话的 `busy` 复位。

**安全性**：不会因此出现两个 turn 同时跑。ACP 侧（`agent/src/harness/acp/acp-adapter.ts:465`）自己还有一道 `state.turn !== null` 的互斥检查，真正的并发冲突仍会被 agent 拒绝。hub 的 `busy` 只是快速拒绝的缓存，放掉它只是解除「僵尸」状态。

**验收**：
- 新增 `test/session-busy-release.test.js` 3 例，全过；
- 反证：回滚修复后第 1 例精确失败于「不应再返回 SESSION_BUSY」，另 2 例仍过（说明用例精准、不误伤）；
- 回归：正常完成流程仍能解锁；`busy` 期间的并发互斥未被削弱。

### 2.2 【中】坏 JSON 请求体返回 500 而不是 400

**现象**：客户端发了个格式错误的请求体，收到的却是「服务器内部错误」，看起来像插件崩了，实际只是请求写错。

**根因**（`lib/server.js`）：

`readJsonBody()` 解析失败时抛的是 `HubError('BAD_REQUEST', …, 400)`，但 5 个路由都是在 `try` **之外** `await` 它的：

```js
const body = await readJsonBody(request);   // ← try 之外
try { … } catch (error) { … }
```

异常直接冒到 `createServer` 的 catch，被一律当 500 回 `INTERNAL`。

**修复**：在全局 catch 里识别 `HubError`，用它自带的 `status`/`code` 回应。一处改动覆盖全部 5 个路由，路由内部无需逐个改。

**验收**：新增 `test/bad-json-400.test.js` 2 例（会话 prompt、新建工作区），均返回 400 `BAD_REQUEST`。

**测试全量**：插件 `node --test "test/*.test.js"` → **106/106 pass**（原 101 + 新增 5）。

---

## 三、待处理（按建议优先级）

### P1 —— 会影响用户，但属特性/改动较大

| 项 | 现状 | 说明 |
|---|---|---|
| **抽屉「历史会话」是死入口** | App 调 `GET /api/v1/conversations`（M1.1 老接口），插件**已无此路由** → 必然 404 → 永远显示「还没有历史会话」 | dsh 早已发现但一直没定「修还是删」。修法：改用插件已有的 `GET /api/v1/desktop/archive/sessions`（App 里 `history_api.dart:1368` 已经在用这个了，只是抽屉没接） |
| **token 全量永不过期** | `~/.dsh/dsh-plugin-m1/tokens.json` 实测 **187 条全部有效**（app 34 / agent 153） | 签发 TTL 30 天，但每次配对只新增不清理，也没有 revoke 端点。dsh 当时记的是 86 条，现在翻了一倍多。建议加：同一 deviceId 只保留最新一条 + 一个 `POST /api/v1/auth/revoke` |
| **App 侧 token 明文落盘** | `session_store.dart` 把 token 明文写进 `getApplicationSupportDirectory()/session.json` | 未用 `flutter_secure_storage`。Android 上应用私有目录虽受沙箱保护，但 root 或备份提取可读。dsh 全程未提这一条 |

### P2 —— 已知且低危，看要不要顺手做

| 项 | 说明 |
|---|---|
| `afterSeq=abc` / `-5` 静默当无参数，返回全量（≈253 KB） | `lib/index.js:1586` 的 `Number.isFinite` 判断。App 侧只传整数，所以只影响外部调用方。建议非法值直接 400 |
| catch-all 404 配 `code: BAD_REQUEST` | `lib/server.js:1035`，语义不准，应为 `NOT_FOUND` |
| `file/raw` 不支持 `Range`/206 | 大文件无法续传（`lib/server.js:928`） |
| `pnpm add` 会撞 `UNEXPECTED_VIRTUAL_STORE` | 与本次无关，属 DSH 环境问题（`.dsh` 是 junction），我上一轮已单独给过分析 |
| 项目根两个 0 字节残留 | `client.js`、`pubspec.yaml`（项目根，不是 `app/` 里的）。容易让人误以为项目坏了，建议删 |
| 41 处 `catch (_)` 静默吞异常 | 多数是「存不下来不影响主流程」的有意为之，但难以排查。可加统一日志 |

### 不建议做

- **App 内直接充值**：`deepseekAccount` 13 个方法里没有下单/付款能力（M4.33 已论证）
- **在 App 内编辑电脑端配置**：改错无法回滚，插件也没有事务

---

## 四、dsh 遗留待办的一致性核对

dsh 最后给自己留了这些「未做」，我逐条核对了代码现状：

| dsh 的说法 | 核对结果 |
|---|---|
| 停在 0.4.42+68，无未完成改动 | ✅ 属实，`pubspec.yaml` 版本一致，测试全绿 |
| 抽屉历史会话仍是空的 | ✅ 属实（老接口 404） |
| `tokens.json` 86 条全有效 | ⚠️ 数字过时，现为 **187 条** |
| 坏 JSON 返 500 | ✅ 属实，已修 |
| `afterSeq` 非法返全量 | ✅ 属实，未修 |
| 404 配 `BAD_REQUEST` | ✅ 属实，未修 |
| `file/raw` 无 Range | ✅ 属实，未修 |
| 插件 gzip（187KB→30KB）未做 | ✅ 属实，`lib/*.js` 里没有任何 gzip 响应逻辑 |

dsh 没提到的：**会话僵尸锁**（本轮修复）、**App side token 明文**、**项目根空文件**。

---

## 五、本轮改动的文件

```
dsh-plugin-m1/lib/hub.js                       +15 行（#releaseAllBusy + close 回调调用）
dsh-plugin-m1/lib/server.js                    +14 行（全局 catch 识别 HubError）
dsh-plugin-m1/test/session-busy-release.test.js  新增（3 例）
dsh-plugin-m1/test/bad-json-400.test.js          新增（2 例）
```

未改动任何 App 代码，未改动插件版本号（仍是 0.2.30）。插件改动要生效需**完整重开一次 DSH**。

---

## 六、复现方式

```powershell
cd <项目根>\dsh-plugin-m1
node --test "test/*.test.js"          # 全量 106 例
node --test test/session-busy-release.test.js   # 只看僵尸锁的 3 例
```
