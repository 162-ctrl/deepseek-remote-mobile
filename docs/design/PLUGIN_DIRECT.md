# PLUGIN_DIRECT · 装一个插件，手机端直接连（局域网 + 公网 + 扫码）

> 版本：M2.7.1（2026-11-05）· 插件 `dsh-plugin-m1`（源码 `0.2.0`）· App `0.1.8-m2.7`（versionCode 9）
> 验收：中继自测 24/24 · 局域网 M1 E2E 6/6 · **公网 M1 E2E 6/6** · App 代码实连 8/8（局域网 + 公网各一遍）· `flutter test` 202/202

## 1. 一句话

以前连手机要起三样东西（Spring Boot 后端 + cloudflared 隧道 + 手工 `serve.ts`），现在只要**在 Harness 里装一个插件**：插件自己监听 8787、自己拉起 Agent、自己开公网隧道、自己给出两个二维码和匹配码；手机 App **扫一下码**（或手输地址 + 匹配码）就连上，局域网、外网都行。

```
手机 App ──HTTP/WS :8787（局域网）──┐
          └─HTTPS/WSS Cloudflare──┤
                                  ▼
                    dsh-plugin-m1（M1 中继 + 配网页 + 二维码 + 隧道）
                                  └─ spawn ─▶ node agent/scripts/serve.ts ─stdio─▶ dsh --profile acp
```

App 侧协议（M1 信封）**一行没改**：插件把 `backend/` 的 `/api/v1/health`、`/api/v1/auth/pair`、`/ws` 与 hub 路由原样复刻，所以同一个 APK 既能连后端，也能连插件。

## 2. 为什么是「插件 + 内置 Agent」，而不是全用插件实现

插件的价值是**免运维**：装完即用、跟着 Harness 启停、自动发现局域网地址、自动起隧道。但 ACP 那一段（`initialize` / `session/new` / `session/prompt` / `session/update` / `session/request_permission`、事件映射、路径白名单、取消与超时）在 `agent/` 里已经跑了 36 个单测、9 个合同测试和多轮 E2E。把它重写进插件只会引入回归，所以：

- 插件内**内置**一份 `agent/`（`dsh-plugin-m1/agent/`，与项目同源），用系统 Node ≥ 22 直接跑 TS（Node 24 原生剥类型）；
- 插件负责中继、门面、隧道，Agent 负责 ACP，二者之间就是原来的 M1 WebSocket 契约，边界仍然清晰、可单独替换。

## 3. 安装

```powershell
# 插件已在 desktop profile 里装好并启用；重装/升级用：
#   插件管理 → install_bundle → 目标目录 <项目根>\dsh-plugin-m1
```

profile 里是 `link:` 依赖 + junction（`node_modules\dsh-plugin-m1` → 工作区），改完源码要 disable→enable 热重载一次。

安装后 Harness 日志会出现：

```
M1 中继已启动：http://127.0.0.1:8787  匹配码 ******
授权目录：<项目根>  ...
手机可用地址：http://192.168.1.x:8787
公网访问：https://<随机名>.trycloudflare.com
配网页（含二维码）：http://127.0.0.1:8787/
```

## 4. 连接（手机端三种姿势）

1. **扫进 App**（主推）：安装 `0.1.8+` 的 APK，打开「连接」页点**「扫码连接电脑」**，扫配网页上的任意一张二维码。二维码内容是 `http(s)://<地址>#c=<匹配码>`，App 一次扫完自动回填地址 + 匹配码，健康检查通过后直接建连。
2. **手输**：地址填 `192.168.1.x:8787`（局域网）或 `https://<公网隧道>.trycloudflare.com`（公网，**局域网才可省略 `http://`**），匹配码填配网页上那 6 位。
3. **扫进浏览器**（dsh-pocket 那条同屏路，与插件无关）：手机相机/浏览器扫同一张码会打开电脑上的 Harness Web UI，需要再输一次 dsh-pocket 的访问密码。

> 局域网地址是 **http 明文**（Android 9+ 已由 `res/xml/network_security_config.xml` 放开 `cleartextTrafficPermitted`），公网隧道是 https。App 的 `normalizeBaseUrl` 按主机名判断：`localhost / 127. / 10. / 192.168. / 172.16–31. / 169.254.` 自动补 `http://`，其余补 `https://`。
>
> 匹配码存在 `$DSH_HOME/dsh-plugin-m1/pairing-code`（权限 0600），配网页点「换一个」立即换码并写回；换码后已配对设备不受影响（token 有效期内仍可连）。

## 5. 公网访问与安全

- **默认开启**：`publicAccess: true` 时插件在 `server.listen` 回调里拉起 `cloudflared tunnel --url http://127.0.0.1:8787`，从输出里抓 `https://*.trycloudflare.com`，配网页右侧卡片实时显示。
- 隧道进程退出会按 `5s × 2^n` 自动重连（最多 5 次）；插件停用时连同进程一起关闭。
- **配网页与匹配码只给本机看**：请求来自回环、且没有 `cf-connecting-ip` 才返回完整页面；通过隧道访问 `/`、`/pair` 只看到「请在电脑上打开这个页面」的说明页，`/api/v1/pair/info` 返回 `restricted: true` 且不含地址与匹配码。公网唯一入口是 App 的 `POST /api/v1/auth/pair`（要码）。
- 配对失败按 IP 限流：60 秒 5 次 → `429 TOO_MANY_ATTEMPTS`（带 `retry-after`）。
- 想固定域名：用 Cloudflare 命名隧道/BT 面板，把 `publicUrl` 配成固定地址（此时插件不再 spawn cloudflared）。
- 不用公网就把 `publicAccess` 设为 `false`，配网页只剩局域网那张码。

## 6. 配置项

| 键 | 默认 | 说明 |
|---|---|---|
| `port` | `8787` | 监听端口；改端口后手机地址跟着变 |
| `host` | `0.0.0.0` | 绑所有网卡，手机才连得上；只想本机调试可改 `127.0.0.1` |
| `pairingCode` | 随机 6 位 | 固定匹配码（4–32 位字母数字）；不配则首次随机生成并落盘 |
| `workspaceRoots` | DSH 工作区注册表 | 允许手机访问的目录，分号分隔；不配就用桌面侧边栏里的项目 |
| `agentDir` | 包内 `agent/` | 指向项目里的 `agent/` 可复用本仓库代码（便于改 ACP 层） |
| `nodePath` | 自动探测 | 指定 Node 可执行文件；探测顺序：配置 → `DSH_NODE` → PATH → Harness 自带 Node |
| `autoStartAgent` | `true` | 关掉后插件只做中继，Agent 由你自己起 |
| `stateDir` | `$DSH_HOME/dsh-plugin-m1` | 匹配码等持久化状态 |
| `publicAccess` | `true` | 是否自动开 Cloudflare 快速隧道 |
| `publicUrl` | 空 | 固定公网地址（自建/命名隧道）；填了就不 spawn cloudflared |
| `cloudflaredPath` | 自动探测 | 显式指定 cloudflared 可执行文件 |
| `appApkPath` | `dist/DeepSeek-Remote-latest.apk` | 应用内更新下发的 APK |
| `appProjectDir` | 插件目录的上一级 | 找 `dist/` 和 `app/pubspec.yaml` 的项目根 |
| `appVersionCode` / `appVersionName` | 自动读 | 覆盖自动识别的版本号 |
| `appNotes` | 空 | 更新说明，随版本接口下发 |

## 7. 端点

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v1/health` | `{status, version, agentOnline, apps, publicUrl}`，与后端同型（多一个 publicUrl） |
| POST | `/api/v1/auth/pair` | `{pairingCode, clientName, role}` → `{token, role, deviceId, expiresAt}`；失败限流 429 |
| GET | `/api/v1/pair/info` | 配网页数据（局域网/公网地址、匹配码、隧道状态）；远端只返回 `restricted` 摘要 |
| POST | `/api/v1/pair/rotate` | 换匹配码（仅本机，或已有 App 在线时） |
| GET | `/`、`/pair` | 深色配网页：局域网 + 公网两张二维码、匹配码、状态、步骤说明 |
| GET | `/assets/qrcode.js` | 浏览器端二维码渲染（qrcode-generator 2.0.4，MIT） |
| WS | `/ws?role=app\|agent&token=…` | M1 信封；鉴权失败 `close(4401)`，Agent 顶号 `close(4409)` |
| GET | `/api/v1/app/version` | 应用内更新：`{versionCode, versionName, size, sha256, notes, url, publishedAt}`；没有 APK 时 404 `APP_UPDATE_UNAVAILABLE` |
| GET/HEAD | `/api/v1/app/apk` | 直接下发 `dist/` 里的 APK（`application/vnd.android.package-archive`），公网隧道同样可用 |

### 7.1 应用内更新（插件即更新源）

`dist/` 里换上新 APK 即可，App 的「检查更新」打到同一个地址就有新版本 —— 不再需要 Java 后端、也不需要另开静态文件服务：

1. 版本号来源：`app/pubspec.yaml` 的 `version: X+N` 与 `app/android/local.properties` 的 `flutter.versionCode`，**取 versionCode 较大者**（后者常是上次构建的残留）。
2. 安装包来源：`appApkPath` → `<stateDir>/app/DeepSeek-Remote-latest.apk` → `<appProjectDir>/dist/DeepSeek-Remote-latest.apk`。
3. `sha256` 按 `mtime + size` 缓存，换包自动失效；`HEAD` 支持，不发全量。
4. 公网隧道同样可下载（实测经 `https://<隧道域名>/api/v1/app/apk`，68.7 MB 全量一致）。

## 8. 验收证据

| 项 | 结果 | 证据 |
|---|---|---|
| 中继自测（hub 路由/鉴权/seq/忙闲/配网页/静态资源） | **24/24 PASS** | `dsh-plugin-m1/tools/smoke.mjs` |
| 最短链路探针 | conversation.created 415ms，输出「连接成功」，completed 1s | `dsh-plugin-m1/tools/probe-create.mjs` |
| 局域网 M1 全链路 E2E | **6/6 PASS**（在线 / 建会话 109ms / prompt 1282ms / 取消 2243ms / 审批批准 6564ms / 审批拒绝 7181ms） | `docs/research/evidence/m1/e2e-2026-11-04T09-37-16-838Z.json` |
| **公网 M1 全链路 E2E**（经 Cloudflare 隧道） | **6/6 PASS**（建会话 636ms / prompt 1591ms / 取消 3455ms / 审批批准 6787ms / 审批拒绝 7402ms） | `docs/research/evidence/m1/e2e-2026-11-05T04-15-05-661Z.json` |
| App 代码实连（局域网） | 8/8：扫码解析 → health → pair → WS → device.status → 建会话 → 「连接成功」→ 断开 | `cd app; dart run tool/live_pair_check.dart http://127.0.0.1:8787 <码>` |
| App 代码实连（公网） | 8/8：同上，走 `https://<隧道域名>` | `cd app; dart run tool/live_pair_check.dart https://…trycloudflare.com <码>` |
| App 单元测试 | **205/205 PASS**（含 `pairing_link_test.dart` 11 项） | `cd app; flutter test` |
| 配网页二维码 | 解码等于 `http://192.168.1.x:8787#c=<匹配码>` / 公网地址同构 | `docs/research/evidence/m1/pair-qr-8787.png` |
| 应用内更新（中继侧） | **9/9 PASS**：version 200、versionCode、size、sha256、HEAD、content-type、GET 全文 `PK` | `dsh-plugin-m1/tools/probe-update.mjs` |
| 应用内更新（App 客户端实跑） | **PASS**：`current=9` → 检查到 0.1.9-m2.8/code 10、下载 68,716,932 字节；`current=10` → 「已是最新」 | `cd app; dart run tool/live_update_check.dart http://127.0.0.1:8787 <9\|10>` |
| 重载后 M1 回归 | **6/6 PASS** | `docs/research/evidence/m1/e2e-2026-11-05T07-52-22-462Z.json` |

## 9. 手机端（APK 0.1.9-m2.8）

- 新增 `app/lib/services/pairing_link.dart`：解析 `地址#c=码` / `?c=` / `dshremote://` 等形态，拒绝非配对二维码。
- 新增 `app/lib/screens/scanner_screen.dart`：`mobile_scanner 7.5.0`，只认 QR，带取景框压暗、补光灯、权限/不支持相机的降级文案。
- 「连接」页新增「扫码连接电脑」卡片；扫到后自动回填、健康检查、直接建连；地址框直接粘整串 `地址#c=码` 也会被拆开。
- `AndroidManifest.xml`：`CAMERA` 权限 + `android:networkSecurityConfig`；新增 `res/xml/network_security_config.xml` 允许局域网明文。
- 版本：`0.1.9+10` / `versionName=0.1.9-m2.8`（M2.8 写文件功能并入；`app_version.dart` 与 `local.properties` 已同步，之前只有 `pubspec.yaml` 与 gradle 改过）。
- 构建：`flutter build apk --release` → `dist/DeepSeek-Remote-AI-v0.1.9-m2.8.apk`（versionCode 10，release 用 debug 签名）。

## 10. 已知限制与下一步

- **公网地址是随机的，每次重启/重连会变**（Cloudflare 快速隧道特性）。要固定就配 `publicUrl` + 命名隧道；否则每次重新扫码即可。
- 需要本机有 `cloudflared`（本机 `C:\Users\user\dsh-tools\cloudflared\cloudflared.exe`）。没有时插件会自动降级为只开局域网，配网页公网卡片显示不可用。
- 公网链路依赖 Cloudflare 的可用性；国内网络访问 `trycloudflare.com` 可能不稳，长稳场景建议自建反代或命名隧道。
- **项目路径含中文时 `flutter build apk` 的 AOT 会失败**（`Unable to read file … \app.dill`）。目前做法是把 `app/` 拷到 ASCII 路径（`C:\Users\user\dsh-build\app-remote`）构建，再把 APK 拷回 `dist/`；`flutter test` / `dart run` 不受影响。
- 装插件时 pnpm 顺带把 `dsh-our-free-model` 从 2.8.0 降到了 2.7.3（profile 依赖解析结果），与插件功能无关，需要时在插件管理里升回。
- 插件源码版本已到 `0.2.0`，运行中的实例还报 `0.1.0`（改了 `package.json` 但没重载）；下次 Harness 重启即显示 `0.2.0`。
- `dsh-plugin-m1` 尚未发布到 npm，目前以本地目录（`link:`）安装。
