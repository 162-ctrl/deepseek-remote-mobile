# dsh-plugin-m1

把 **DeepSeek Harness** 变成手机端可以直接连上的中继服务：装一个 DSH 插件，手机 App
（「DeepSeek Remote AI」）**扫码或输入匹配码**就连上，局域网、外网都行——**不再需要
Spring Boot 后端、也不用手工拉起 agent 进程**；公网隧道由插件自己开。

```
手机 App ──HTTP/WS :8787（局域网）──┐
          └─HTTPS/WSS Cloudflare──┤
                                  ▼
                    dsh-plugin-m1（中继 + 配网页 + 二维码 + 隧道）
                                  └─ spawn ─▶ agent/scripts/serve.ts ─stdio─▶ dsh --profile acp
```

插件复刻的是 `backend/` 里那套已经跑通的 M1 契约（`POST /api/v1/auth/pair`、
`GET /api/v1/health`、`/ws?role=app|agent&token=...`、信封 `{v:1,type,id?,ts?,payload}`），
并对 `agent/` 的 ACP 桥接代码做了原样内置，所以**手机端协议零改动**。

## 安装

```powershell
# 在 Harness 会话里（或命令行）
dsh plugin install <项目根>\dsh-plugin-m1
```

启用后插件会：

1. 在 `0.0.0.0:8787` 起 HTTP + WebSocket 中继；
2. 启动内置 agent（配对到本机中继 → 拉起 `dsh --profile acp`）；
3. 生成/复用 6 位匹配码，存在 `$DSH_HOME/dsh-plugin-m1/pairing-code`；
4. 自动开一条 Cloudflare 快速隧道，拿到 `https://<随机名>.trycloudflare.com`。

## 手机连接

1. 电脑打开 <http://127.0.0.1:8787/> —— 页面上是**局域网 + 公网两张二维码**、地址和 6 位匹配码；
2. 手机装 `0.1.8+` 的 App，打开「连接」页点**「扫码连接电脑」**，扫任意一张码即可（二维码 = `地址#c=匹配码`，扫一次两个输入框都填好）；
3. 没有扫码也能手输：局域网填 `192.168.1.x:8787`，公网填 `https://<公网隧道>.trycloudflare.com`，再填匹配码；
4. 连上后即可对话、看执行过程、批准工具调用。

> 局域网是 http 明文，App 已放开 cleartext；公网是 https。缺协议时 App 会对局域网/回环补 `http://`，其余补 `https://`。

## 配置（`cordis.patch.yml` 的 `config`）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `port` | `8787` | 中继监听端口 |
| `host` | `0.0.0.0` | 监听地址，改成 `127.0.0.1` 则只允许本机 |
| `pairingCode` | 自动生成 | 固定匹配码（4–32 位字母数字） |
| `workspaceRoots` | DSH 工作区注册表 | 允许手机访问的工作区根目录，数组或分号分隔 |
| `agentDir` | 包内 `agent/` | 改成项目里的 `agent` 目录即可复用你本地的最新实现 |
| `nodePath` | 自动探测 | 指定 node 可执行文件（需 ≥ 22，能直接跑 .ts） |
| `autoStartAgent` | `true` | 关掉则只提供中继，agent 由你自己拉起 |
| `stateDir` | `$DSH_HOME/dsh-plugin-m1` | 匹配码存放目录 |
| `publicAccess` | `true` | 是否自动开 Cloudflare 快速隧道 |
| `publicUrl` | 空 | 固定公网地址（命名隧道/自建反代）；填了就不再 spawn cloudflared |
| `cloudflaredPath` | 自动探测 | 显式指定 cloudflared 路径 |
| `appApkPath` | `dist/DeepSeek-Remote-latest.apk` | 应用内更新返回的 APK |
| `appProjectDir` | 插件所在项目的上一级 | 用来找 `dist/` 与 `app/pubspec.yaml` 的项目根 |
| `appVersionCode` | 自动读 | 强制指定 `versionCode`（数字） |
| `appVersionName` | 自动读 | 强制指定版本名 |
| `appNotes` | 空 | 更新说明（展示在版本接口里） |

## 应用内更新

插件本身就是 App 的更新源，`dist/` 里换上新 APK 就自动生效，不需要后端、不需要改配置：

```text
GET /api/v1/app/version   → {versionCode, versionName, size, sha256, notes, url, publishedAt}
GET /api/v1/app/apk       → 直接下载（支持 HEAD、Range 无需）
```

- 版本号优先读 `app/pubspec.yaml` 的 `version: X+N`，其次 `app/android/local.properties`，取 `versionCode` 较大者（`local.properties` 常是上一次构建的残留）。
- APK 默认取 `dist/DeepSeek-Remote-latest.apk`；文件变了（`mtime` + 大小）才重算 sha256。
- App 侧走已有的 `UpdateService`：检查 → 下载 → 校验字节数 → 交给系统安装器；公网隧道同样可用。
- 验收：`node tools/probe-update.mjs`（9 项）、`cd app && dart run tool/live_update_check.dart http://127.0.0.1:8787 9`（App 自己的客户端跑一遍真实下载）。

## 安全

- 配网页与匹配码**只对本机可见**：通过隧道访问只会看到「请在电脑上打开这个页面」，`/api/v1/pair/info` 返回 `restricted` 摘要（不含地址与码）。
- 配对接口按 IP 限流：60 秒 5 次失败 → `429 TOO_MANY_ATTEMPTS`。
- 匹配码 6 位、可一键换码；换码不影响已配对设备（token 有效期内）。

## 与 `dsh-pocket` 的区别

| | dsh-pocket | 本插件 |
| --- | --- | --- |
| 手机那一端 | 浏览器打开桌面 UI | 你自己的 Flutter App（M1 协议） |
| 会话 | 与桌面实时同屏 | 独立的 ACP 会话（与后端模式一致） |
| 扫码 | 扫 URL，再输访问密码 | 扫 `地址#c=码`，App 自动填满 |
| 依赖 | qrcode / cloudflared | 零运行时依赖（cloudflared 可选），agent 代码内置 |

两者可以同时启用，互不冲突。

## 第三方代码

- `assets/qrcode.js` —— [qrcode-generator](https://github.com/kazuhikoarase/qrcode-generator) 2.0.4（MIT），
  仅用于在配网页里渲染二维码，浏览器端运行，不参与 Node 侧逻辑。
- `agent/` —— 手机端项目里的 ACP 桥接代码（`agent/src/**` + `agent/scripts/serve.ts`）。
