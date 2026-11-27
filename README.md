# DeepSeek Remote · 手机端

用手机远程操控电脑上的 **DeepSeek Harness（DSH）**：在手机上看电脑在干什么、发指令、批准危险操作、回答它提的问题、打开工作区文件、接收电脑做好的文件。

这个仓库是完整实现存档：Flutter 手机 App、Go/Java 后端、电脑端 Agent、DSH 插件，以及逐版本的开发记录、协议说明与测试。

## 目录

| 目录 | 是什么 |
| --- | --- |
| `app/` | Flutter 手机 App（Android），`lib/screens` 是各页面，`lib/data/live_store.dart` 是与电脑同步的状态中心 |
| `backend/` | 配对与中继服务（账号、设备、二维码配对、离线消息） |
| `agent/` | 电脑端 Agent：把 DSH 的 ACP 接口包成远程协议 |
| `dsh-plugin-m1/` | DSH 插件：在电脑上起 Agent、提供 HTTP/WebSocket 接口、把提问与授权转给手机 |
| `tools/` | 版本校验、发布、抓包与诊断脚本 |
| `docs/` | 设计、协议、各里程碑报告、手机端说明（`docs/research/` 是按时间写的实现记录） |
| `apk/` | 可直接安装的 APK |

## 装上就能用（手机）

1. 下载 `apk/DeepSeek-Remote-v0.4.67-m4.67.apk`（Android 8.0+，debug 签名，可覆盖升级）。
2. 电脑上装好 DSH 并启用本仓库的 `dsh-plugin-m1` 插件，插件会在 `http://127.0.0.1:8787` 起服务并显示一个二维码。
3. 手机打开 App → 扫码（或手填电脑地址 + 配对码）→ 连上后进入「工作区」，就能看到电脑上的项目、会话与正在跑的任务。
4. 底部四个页签：**工作区**（项目与会话）、**桌面直播**（实时看电脑跑任务、批准授权、回答提问、发指令）、**功能**（插件管理、接收文件、更新日志、充值）、**我的**（连接状态、余额、设置）。

> 同一局域网直接填 `电脑 IP:8787` 最快；不在同一网络时优先用 **Tailscale**（见下），都没有再用插件给出的公网隧道地址。

## 三种连法：局域网 / Tailscale / 公网隧道

插件同时支持三种网络形态，App 里任选一种，地址和配对码都填同一个：

| 方式 | 适用场景 | 地址长什么样 | 额外依赖 |
| --- | --- | --- | --- |
| 局域网 | 手机和电脑连同一个 Wi-Fi / 交换机 | `192.168.x.x:8787`、`10.x.x.x:8787` | 无 |
| **Tailscale** | 不在同一网络，但想要低延迟、不经过第三方隧道 | `100.x.x.x:8787`（电脑的 Tailscale 地址） | 两端各装一次 Tailscale，登录同一个 Tailnet |
| 公网隧道 | 什么都没装、临时远程看一眼 | `https://xxx.trycloudflare.com` | 插件自带 cloudflared，自动开 |

用 Tailscale 的具体做法：

1. 电脑装 Tailscale 并 `tailscale up`，手机上装 Tailscale、登录**同一个账号**（同一 Tailnet）；
2. 电脑上 `tailscale ip -4` 或看插件配网页会直接列出 `100.x` 那条地址（插件会把 Tailscale 地址排在第一位）；
3. 手机 App「连接」页手填 `100.x.x.x:8787` + 配对码，或直接扫配网页上的二维码；
4. 之后手机在任何网络下都能连（4G/5G 也行），延迟通常比 Cloudflare 快速隧道低，也不受隧道域名每次重启就变的影响。

> 插件侧已经实现：`lanAddresses()` 把 `100.64.0.0/10` 判为 `tailscale` 并排在最前，`GET /api/v1/pair/info` 返回 `tailscaleUrls`，配网页单独列一条「Tailscale（同一 Tailnet，跨网络可用）」。App 的地址策略也允许 `100.64/10` 走明文 HTTP（判为内网并提示「此连接未加密」）。

## 自己编译

```bash
# 手机端
cd app
flutter pub get
flutter test                 # 550+ 用例
flutter build apk --release  # 产物在 build/app/outputs/flutter-apk/

# 电脑端 Agent
cd agent && npm ci && npm test

# DSH 插件（先装依赖，再装插件）
cd dsh-plugin-m1 && npm install && node --test 'test\*.test.js'
```

Flutter 3.x（Dart 3.5+）、Node 24+（插件内置的 agent 直接跑 TS）、JDK 21、Android SDK 35+。构建时把 `JAVA_HOME`、`ANDROID_HOME` 指好即可；项目里不含任何签名密钥（`key.properties` 用 debug 签名占位）。

装插件：先 `cd dsh-plugin-m1 && npm install`（`jszip`、`pdf-parse` 只用于 pdf/docx 预览），再执行 `dsh plugin install <项目根>\dsh-plugin-m1`，重启会话后插件会在 `127.0.0.1:8787` 起服务。

## 它是怎么工作的

```
手机 App ──HTTP/WS──► 插件（电脑 127.0.0.1:8787）──► DSH 的 WebSocket 事件流
   ▲                      │
   └── 配对/中继 ──────────┘（跨网络时经 backend + 公网隧道）
```

- 插件在电脑上启动 `agent/`，Agent 通过 ACP 与 DSH 通信，把会话、工具调用、审批、提问转成手机能懂的 JSON。
- 手机的「桌面直播」页用 WebSocket 收实时事件；提问与授权走同一套协议，两端都能答，谁先答用谁。
- 文件浏览、接收文件、更新说明都走插件提供的 HTTP 接口，手机端只读。

更细的协议在 `docs/design/PROTOCOL.md`，实现过程按里程碑记在 `docs/research/`，每个版本改了什么在 `docs/UPDATE_NOTES.md`。

## 已实现

- 扫码 / 手填地址配对，局域网与公网隧道两种连法
- 工作区浏览、文件预览（文本 / 图片 / PDF 交给系统应用 / 扫描件 docx 按页看图 / 文本 docx 抽正文）
- 桌面直播：实时事件流、工具调用、停止任务、审批卡、提问卡（电脑与手机同时出卡，任一端可答）
- 会话中心：本机对话与远程会话分组、历史会话、归档
- 功能页：插件管理、接收文件（电脑放进去，手机点开看、分享、用其他应用打开）、更新日志
- 账户余额展示与 App 内嵌官方充值页
- 启动自愈：连续启动失败自动清本地连接存档，避免卡在闪退

## 已知限制

- 手机端只能看文件，不能改电脑上的文件。
- 电脑端会话列表看不到「只在手机端新建、还没发消息」的空会话（两边是不同的会话表）。
- 分享 / 用其他应用打开依赖手机是否装了对应阅读器；没有就只能分享。
- 更新检查只比对插件提供的版本接口，不做后台下载。

## 说明

- 本仓库为个人项目的实现存档，按现状提供，不含任何账号、令牌、密钥或个人路径。
- 截图与真实会话内容未入库；文档中的 IP、域名、令牌均为占位或示例。
