# DeepSeek Remote AI · 手机远程控制电脑上的 DeepSeek Harness

> **当前状态（2026-11-14）**：**M0 已完成 + M1-α 全链路已真实跑通 + M1.1 持久化/历史/真实任务页已交付 + M2-α 审批通知/后台保活/token 持久化已交付 + M2.1 可补偿事件/断线演练/执行中排队已交付 + M2.2 手机端手感对齐（折叠/立即发送/6 主题/分享卡/长按菜单）已交付 + M2.3 视觉重构（冷白极简 + 浅/深色跟随系统）已交付 + M2.4 删除演示数据/统一空态/界面减法已交付 + M2.5 应用内在线更新已交付 + M2.6 项目同步（手机浏览电脑项目文件 + 在项目目录里发指令）已交付 + M2.6.1 多授权根（同时授权多个目录）已交付**。
>
> - **M1-α**：手机（模拟器/真机）经 **Cloudflare 公网隧道** 连到本机后端，再经电脑 Agent 驱动**真实 DeepSeek Harness 0.2.1-rc.5**：真实指令、实时输出、高风险审批（手机点「允许一次」→ 电脑真的执行）、取消、断线重连全部验证通过。本机 E2E **6/6**、**公网隧道 E2E 6/6**、手机端 5 张真实链路截图；报告 [M1_E2E_REPORT.md](docs/research/M1_E2E_REPORT.md)。
> - **M1.1**：PostgreSQL 16.10 持久化（重启不丢历史）、历史会话 REST、手机端历史会话弹层 + 真实任务中心/任务详情 + 结构化工具输出。`m1-client` 6/6 三连通过（含重启后端后），手机端 `flutter test` **95/95**；报告 [M1_1_REPORT.md](docs/research/M1_1_REPORT.md)。
> - **M2-α**：**后端 token 落库（重启后端旧 token 仍 200，Agent 无需重启）**；手机端 **锁屏/后台审批通知 + 前台服务保活 + 401/4401 自动重配对**（Kotlin 原生桥，零新增 pub 依赖）。`flutter test` **111/111**、`m1-client` **6/6**、后端 `gradle build` 成功；报告 [M2_REPORT.md](docs/research/M2_REPORT.md)。真机通知链路待补测（模拟器不可用）。
> - **M2.1**：`task_events` 独立事件表 + **会话级统一 seq** + `GET /conversations/{id}/events?afterSeq=` 增量补拉；**真实断流 60 秒演练 PASS**（重连补回 7 条事件、9/9 seq 唯一、终态由补拉恢复）；执行/等待审批中可继续输入，任务结束自动发出（深度 1 队列）。`flutter test` **124/124**（M2.2 后全量 143/143）、`m1-client` **6/6**；报告 [M2_1_REPORT.md](docs/research/M2_1_REPORT.md)。
> - **M2.2**（手感对齐 A 档）：完成轮自动折叠（「已完成 N 步 · 用时 Xs」）、排队消息**「立即发送」（打断 + 改说）**、**6 套主题可持久化**、对话**分享卡 PNG**、长按菜单（复制/重发/复制输出）。`flutter test` **143/143**、`flutter build apk --debug` 成功（150.8 MB，安装器显示 versionName **0.1.3-m2.2**、versionCode 4），**零新增 pub 依赖**；报告 [M2_2_REPORT.md](docs/research/M2_2_REPORT.md)。真机 UI 待补测。
> - **M2.3**（视觉重构）：按用户选型「A 的配色 + B 的排版」重做六页——冷白 `#F6F7F9` + 白卡 + 蓝 `#2563EB`、卡片 20 圆角、助手回复无气泡（左侧 3px 竖线）、用户气泡 22/22/8、底部导航白底+选中圆点、6 格配对码；**浅色默认、跟随系统自动切深色**，另提供「跟随系统/浅色/深色」三选持久化。`flutter test` **154/154**、APK **150,808,223 字节**（`versionName=0.1.4-m2.3`、`versionCode=5`）；报告 [M2_3_REPORT.md](docs/research/M2_3_REPORT.md)。
> - **M2.4**（删演示数据 + 界面减法）：用户反馈「太繁琐」→ **删除 `demo_store.dart` 与全部假设备/假会话/假任务/假工作区/假审计/假配对码/演示徽标**，未连接时六页统一为「连接空态」（图标 + 标题 + 一句说明 + 连接按钮）；已连接只留一行状态条与真实内容，删统计三卡/权限长列表/假按钮/审计块；`grep -ri "演示" app/lib` **= 0**。`flutter test` **164/164**、真实链路回归 **6/6 PASS**、APK **150,758,731 字节**（`versionName=0.1.5-m2.4`、`versionCode=6`）；报告 [M2_4_REPORT.md](docs/research/M2_4_REPORT.md)。
> - **M0**（电脑端 ACP 内核）：单测 **36/36**、合同测试 **9/9**、E2E **5/5**，报告 [M0_FEASIBILITY.md](docs/research/M0_FEASIBILITY.md)。构思方案 **v0.2** 定稿（独立审核 76/100，有条件通过）。
>
> - **M2.5**（在线更新）：手机端「我的 → 关于 → 检查更新」可直接查版本、看更新说明、下载 APK（进度条）并调起系统安装器；**不做静默安装**（Android 限制，最后一步由系统弹窗确认）。后端新增 `GET /api/v1/app/version`、`GET|HEAD /api/v1/app/apk`（固定读 `dist/DeepSeek-Remote-latest.apk`）。`flutter test` **178/178**、真实链路回归 **6/6**、APK **150,782,707 字节**（`versionName=0.1.6-m2.5`、`versionCode=7`）；报告 [M2_5_REPORT.md](docs/research/M2_5_REPORT.md)。
> - **M2.6**（项目同步）：手机「项目」页现在显示 Agent 的**真实工作区根**（本次切到 `<项目根>`），可逐级浏览目录、点文件**只读预览**（等宽/行号/复制/sha256），并在任意目录「在此目录发指令」→ 新会话绑定该目录由 Harness 执行。新增 WSS `workspace.list` / `file.read` 请求-响应（**不占 seq、不进消息流**），Agent 本地文件系统实现（忽略 `.git/node_modules` 等、256 KiB 预览上限）。真实链路 **14/14 PASS**、Agent 单测 **9/9**、`flutter test` **190/190**、M1 回归 **6/6**、APK **150,820,399 字节**（`versionName=0.1.7-m2.6`、`versionCode=8`）；报告 [M2_6_REPORT.md](docs/research/M2_6_REPORT.md)。
> - **M2.6.1**（多授权根，2026-11-04 补充）：用户要求「同步所有项目」→ Agent 新增 `M1_WORKSPACE_ROOTS`（分号分隔多个根，第一个为默认），`device.status.workspaceRoots` 返回全部根，手机「项目」页自动列出全部授权目录（App 无需改代码）；路径校验改为「必须落在任一授权根内」。当前配置 **`D:\Projects` + `C:\Users\user\Desktop`**。实时链路 **6/6 PASS**、`workspace-fs` 单测 **10/10**、M1 回归 **4/4**；证据 [multi-root-2026-11-04T06-40-41-094Z.json](docs/research/evidence/m2/multi-root-2026-11-04T06-40-41-094Z.json)；用法 `tools\m1-up.ps1 -WorkspaceRoots 'D:\根A;C:\根B'`。
> - **M3.6**（2026-11-11，对话/插件/最新）：针对用户三条反馈——①「不要英文、要跟 PC 一样的对话」：插件 `assistant/message` 只取正文 part（`text/markdown/output_text`），**不再把 reasoning 当正文**；②「插件和 PC 不同步、没有插件市场」：插件把 Host 原始结构归一化（原来 214 条空 id/name），并新增 **bundle 分组 + 插件市场**（索引/搜索/安装/卸载/开关，构建脚本二次确认），App 插件页重写为「已安装 / 插件市场」双 Tab；③「打开对话不是最新」：插件按**最后一条事件时间**排序并给同名会话补时间，App 会话卡显示「N 条消息 · 最后时间」、打开即滚到底、回前台强制刷新。插件 0.2.8 单测 **12/12**、App `flutter test` **244/244**、APK **177,899,089 字节**（`0.3.6-m3.6`、versionCode 25）；报告 [M3_6_REPORT.md](docs/research/M3_6_REPORT.md)。**注意：本机插件 HMR 事务锁卡死，需完整退出并重开一次 DSH 桌面应用，0.2.8 才会生效**（重启后跑 `tools\verify-plugin-m3-6.ps1`，应 6/6 PASS）。
> - **M4.0**（2026-11-13，工作区整改 / 手机端新建工作区）：①「工作区」页重做为二级工作台——按最后活动倒序、`等待授权/运行中/失败` 状态徽标、「N 条消息 · 最后时间」、5 秒轮询 + 下拉刷新 + 回前台刷新、AppBar「浏览工作区文件 / 新建会话 / 刷新」、空态一键「在这里新建会话」、底部输入固定发给最新会话；②任务页工作区胶囊**常驻**并新增「＋ 新建工作区」→ 对话框实时预览落盘路径（`POST /api/v1/desktop/workspaces`，在第一个授权根下建一级子目录，非法字符 `\ / : * ? " < > |` → `-`，同名幂等，失败 `400 WORKSPACE_CREATE_FAILED`）；③修掉 **Hub 骨架 `device.status` 清空工作区根** 的 Bug（骨架设备名写死 `DeepSeek Harness`、不带 `workspaceRoots`，现只更新能力位；Agent 真实上报空目录仍照常清空）。插件 **0.2.9**、App **0.4.1+27**、`flutter test` **255/255**、`flutter analyze` 0 error，**release APK 71,621,290 字节**（`0.4.1-m4.0`，versionCode 27，沿用 debug 密钥可覆盖安装）；报告 [M4_0_REPORT.md](docs/research/M4_0_REPORT.md)。
>
> - **M4.1**（2026-11-13，插件页对齐电脑端 / 插件市场索引兜底）：①「插件 → 已安装」顶部新增**「浏览本地插件」**入口 → 新页面按「内置插件配置 / 实验性插件 / 其他插件」分组列出电脑上全部本地插件（名称、两行说明、「实验性」标签、逐项开关，走 `GET /api/v1/desktop/plugins/gallery` + `POST /desktop/plugins/enabled`，与电脑端「设置 → 插件」同源），支持按名称/说明过滤，旧插件（0.2.10 以下）返回 501/404 时提示升级；②修掉**插件市场一直为空**的根因——DSH 的 `pluginMarket.listIndexes()` 只返回「设置里配置过的索引」，本机一个都没配，现在无索引时用 DSH 公开索引 `https://api.dshmarket.com/v1/index.json` 兜底并带 `refresh` 现场拉取（响应带 `defaultIndex`），改用新 Host 的 `search(url,{query:{text,limit,offset,order}})` 签名，0 条时再按 `order:'stars'` 重试；③市场卡片加厚：作者 + 下载量 + 星标（`319万` / `6.9k` 紧凑格式）+ 列表顶部统计行（条数 · 索引来源 · 关键字）。插件 **0.2.10**、App **0.4.2+28**、`flutter test` **263/263**、插件单测 12/12、`flutter analyze` 0 error，**release APK 71,720,030 字节**（`0.4.2-m4.1`，versionCode 28，沿用 debug 密钥可覆盖安装）；报告 [M4_1_REPORT.md](docs/research/M4_1_REPORT.md)。
> - **M4.2**（2026-11-13，助手页直连对话 + 附件真正落地）：用户反馈「ai 助手手机端页面不应该是直接对话吗，而且只能对话，文件、相册、拍照呢」→ ①删掉助手页的「手机 / 电脑」两档切换和整屏品牌欢迎区，**连上电脑打开就是消息流 + 输入框**（空对话只留一行提示 + 3 个建议胶囊）；②**附件入口从「+」二级菜单提到输入框上方常驻**：拍照 / 相册 / 文件 三个胶囊，图片显示缩略图，行下方提示「附件会存到电脑「工作区/手机附件」」；③修掉附件「传了但电脑端 AI 找不到」的根因——上传时带 `workspace`，插件按工作区名落到 `<授权根>/<工作区名>/手机附件/`（以前落在 `%USERPROFILE%\.dsh\dsh-plugin-m1\uploads`），发送后弹「已上传到电脑：N 个文件（工作区）」回执。插件 **0.2.11**、App **0.4.3+29**、`flutter test` **267/267**、插件单测 12/12、`flutter analyze` 0 error，**release APK 71,867,762 字节**（`0.4.3-m4.2`，versionCode 29，沿用 debug 密钥可覆盖安装）；报告 [M4_2_REPORT.md](docs/research/M4_2_REPORT.md)。**真机未复测**（交付时 adb 掉线）。
> - **M4.3**（2026-11-13，直播「已运行」与电脑端对齐）：用户反馈「这个用时不应该和电脑上的统一吗，不是每次打开后开始计时」→ 直播页起点以前是「手机打开页面的时刻」，现在取会话日志里**最新一条 `turn-start` 的事件时间**（电脑上这一轮真正开始的时刻），插件把每条事件的 `time`（毫秒）一并下发，超过 1 小时显示 `H:MM:SS`；旧插件没有时间时依次退回任务行最后活动时间、会话 `updatedAt`。插件 **0.2.12**、App **0.4.3+30**、`flutter test` **277/277**、插件单测 12/12、`flutter analyze` 0 error，**release APK 71,867,762 字节**（`0.4.3-m4.3`，versionCode 30）；报告 [M4_3_REPORT.md](docs/research/M4_3_REPORT.md)。**真机未复测**（adb 无设备）。
> - **M4.4**（2026-11-13，任务完成 / 等待授权通知）：用户反馈「他这做完了或者是要审核没有信息通知」→ 任务**跑完 / 失败 / 取消**、以及停下来**等授权**时手机端都发系统通知；授权那条带「允许 / 拒绝」两个按钮，可在通知栏直接决定（冷热启动都会回传决定）；点「任务完成」通知直接切到工作区页；新增「任务进度」渠道，「我的 → 通知」加两个开关（任务做完提醒、等待授权提醒，默认全开）。只在 App 后台时提醒。插件无需改动（仍 0.2.12）、App **0.4.4+31**、`flutter test` **286/286**、`flutter analyze` 0 error，**release APK 71,933,294 字节**（`0.4.4-m4.4`，versionCode 31）；报告 [M4_4_REPORT.md](docs/research/M4_4_REPORT.md)。**真机未复测**（adb 无设备）。
> - **M4.5**（2026-11-14，更新进度条分帧）：用户反馈「更新时出来的进度条都不动」→ 插件中继跑在本机回环网络上，71.9 MB 的 APK 实测 **0.1 秒**就下完，进度回调只来得及闪一帧就跳去调系统安装器。现在 UpdateService.download() 用 pace() 把响应按 **256 KiB / 30 ms** 分帧回调，进度条会一路走到 100% 再调起安装器（只改上报节奏，文件内容与落盘不变）。flutter test **288/288**、flutter analyze 0 error；release APK **71,933,298 字节**（`versionCode=32`、`0.4.5-m4.5`，沿用 debug 密钥可覆盖安装）。
>
> - **M4.6**（2026-11-14，AI 助手分手机和电脑）：用户要求「ai 助手分手机和电脑」并确认**默认手机档** → 助手页顶栏恢复「手机 / 电脑」两档切换（M4.2 曾整段删掉）：手机档是**云端 API Key 直连**（不经电脑），顶栏胶囊直接显示「云端直连 · 模型名」或「云端直连 · 未设置接口」，点它就打开接口设置；电脑档才是和电脑上的 AI 对话（附件 / 直播 / 通知都在这一档）。两档放在 `IndexedStack` 里**常驻**，来回切**不丢对话**；顺手修了「未连接时切电脑被强行弹回手机档」和「云端页常驻转圈导致页面永不停帧」两个问题。App 291/291 测试、release APK 72,015,286 字节，插件无改动。
> - **M4.7**（2026-11-14，手机档也能发照片 / 文件）：用户反馈「AI 助手手机页面怎么没有上传文件图片拍照的」→ 手机档（内嵌的云端直连页）之前只有输入框和发送键。现在两档共用新的 `lib/widgets/attachment_bar.dart`：**拍照 / 相册 / 文件**三个胶囊在手机档也常驻输入条上方，发送时附件直接进请求——图片按 OpenAI 兼容的 `content: [{type:text},{type:image_url,image_url:{url:"data:image/png;base64,…"}}]` 发给**支持视觉**的模型，文本文件（md/dart/json…）内联成「【附件 名】」段，其它二进制只发文件名；用户气泡里显示缩略图；未配置接口时提示「要发图片，请填支持视觉的接口」。App 301/301 测试、release APK 72,031,674 字节，插件无改动。
> - **M4.8**（2026-11-14，「不用上传」）：用户说「不用上传，就和正常的 ai 一样可以处理各种问题」→ 界面里彻底去掉「上传」字样：电脑档发完附件不再弹「已上传到电脑：N 个文件」，指令里的列表改成「附件：」，附件条上传中显示「正在读取…」。手机档新增 `CaretakerReader` 契约——图片和文本照旧直发云端模型，PDF / Word / Excel 这类手机解析不了的文件由电脑读成文字后随消息发给模型（`POST /api/v1/desktop/file/read`；电脑离线或插件还没实现该接口时静默退回「只发文件名」，不阻塞发送）。手机档首次引导重写：说明「手机档不经过电脑、Key 只存在这台手机上」，并给出「去 platform.deepseek.com 生成 Key → 回来粘贴」两步。App 307/307 测试、release APK 72,113,594 字节，插件无改动。
> - **M4.9**（2026-11-14，工作区文件都能打开）：用户反馈「工作区的有些文件无法预览」→ 原来查看器只认文本，图片/PDF/Office 一点就报「无法预览」。现在按扩展名分流：图片经新增的 `GET /api/v1/desktop/file/raw` 取原始字节后在 App 内放大看；PDF / Word / Excel / PPT 下载到手机缓存，用 `content://`（FileProvider `preview/`）+ `ACTION_VIEW` 交给 WPS 或系统阅读器；插件同时实现 `POST /api/v1/desktop/file/read`（pdf-parse 读 PDF、JSZip 抽 docx/pptx/xlsx），手机档的 PDF/Word 从此能真的读成文字发给云端模型。插件 0.2.13，App 0.4.9+36，315/315 测试，release 72,311,070 字节。
> - **M4.10**（2026-11-15，会话存档）：用户问「为什么又看不到所有的项目了」——DSH 重启后旧会话从列表里整条消失。查下来 **会话文件全在** `C:\Users\user\.dsh\sessions\`（37 个项目目录 / 246 个会话），问题在 DSH 的 JSONL 后端只认「已物化」日志：只剩 header 的会话在 `readGenerationHeader` 处返回 `undefined`，整条 invisible（与插件、手机端、重启都无关）。插件 0.2.14 起自己维护 `session-archive.json`：每 30 秒把运行中的会话吸进来，并扫描磁盘上存档里还没有的会话日志（`zlib.zstdDecompressSync` 只解第一帧，所以按帧扫描再逐帧解压）。手机端在「工作区」页底部新增「以前跑过、电脑上已经看不到的会话（N）」，点开是带「已存档」标记的只读直播（不轮询、无输入条）。新增 `GET/POST /api/v1/desktop/archive/sessions` 与 `GET .../:id`。App 321/321 测试、release APK 72,343,942 字节，插件 0.2.14（15/15 单测）。
> - **M4.11**（2026-11-16，工作区页不再「看起来项目全丢了」）：手机端「工作区」页把电脑端授权过的**每个目录都铺成一张卡**（没有会话时标「暂无会话」，点进去照常新建会话 / 看存档 / 浏览文件），存档分组不再被「进行中 / 完成 / 失败」筛选挡掉；插件 0.2.19 让存档列表挡掉 `agent\.m1ws`、`agent\.workspaces\contract-*` 这类测试临时目录，并补上 `node:fs` 的 `statSync` 导入（缺了会在附件落盘时抛 `statSync is not defined`）。App 0.4.11+38 / 插件 0.2.19，`flutter test` 327/327，插件单测 30/30，release APK 72,343,942 字节。
> - **M4.12**（2026-11-16，对话正文按 Markdown 排版）：用户发来 DeepSeek 官方 App 的对话截图问「你的对话不能做成这样的吗」——差别不在数据链路而在**正文渲染**：我们的助手回复只认 `**加粗**` 和 `` `代码` ``，`###`、`- `、三反引号代码块、`|` 表格全**原样露在屏幕上**。新增零依赖的块级解析器 `app/lib/widgets/markdown_text.dart`（标题 / 段落 / 列表 / 引用 / 分隔线 / 代码块 / 表格，行内加粗、代码、链接各有样式；代码块带语言标签与「复制」；表格有表头底色），电脑档与手机档（云端直连）共用；助手回复去气泡直接排版，底部常驻「复制 + 时间」。没有新增任何 pub 依赖，中文标题用 `w600` 而不是 `w700`（CJK 伪粗体会糊）。App 0.4.12+39 / 插件 0.2.20，`flutter test` **344/344**，插件单测 31/31，release APK **72,589,702 字节**。
> - **M4.13**（2026-11-16，工作区按项目分组）：用户发来手机「工作区」页截图说「按照工作区项目分类，做成和电脑上一样的，可以折叠打开，并且可以新建对话，新的项目区是建立在电脑端"D:/用户/项目"这个文件里面」。原来是**平铺的会话卡**（任务卡 + 空目录卡 + 底部存档组），同目录的多个会话各占一张，看不出归属。现在每个目录一张 **`_ProjectGroupCard`**：头部整行点折叠/展开，会话（含存档）挂在所属项目下，空目录标「空项目」胶囊；新增纯函数 `app/lib/services/project_groups.dart`。胶囊与对话框文案改成「新建项目」，`parentDir` 固定成 `D:\Projects\项目`（授权根里没有时退回第一个授权根并提示）；插件 0.2.20 加 `resolveParentDir()` / `createDesktopWorkspace(name, parentDir)`，`listDesktopWorkspaces()` 每行带 `parent` 与 `isProject`。App 0.4.13+40 / 插件 0.2.20，`flutter test` **353/353**，插件单测 39/39，release APK **72,589,702 字节**。「在项目里新建会话」用户说以后再说，本轮未做。
> - **M4.14**（2026-11-16，直播页不再空手）：两条反馈其实同源——手机在「看起来应该能看见」时什么都没看见，也没人告诉它为什么。①「每次点进去加载不出来对话」：插件首屏只从日志尾部倒取 **80 条事件**，忙会话这 80 条可能全是 tool-call/tool-result（实测 36+35），App 只留 user/assistant → 正文 0 条；带 `afterSeq` 时旧代码**从头往后扫**，积压就永远追不上。现改为 `MIN_CHAT_EVENTS = 12` / `MAX_TAIL_EVENTS = 600` 首屏倒扫凑够对话，增量也改为**从尾部倒扫**。②「授权手机上没有出来也没有提醒」：`WATCH_WINDOW_MS` 2 分钟 → **10 分钟**、`APPROVAL_TIMEOUT_MS` 90 秒 → **2 分钟**，超时先 `log('接管授权超时，已退回电脑：…')` 再退回电脑。手机端顶栏在有授权待答时挂「待应答 N」胶囊，空态区分「真没内容」与「这一屏只有工具调用，点上面的「过程」」。App 0.4.14+41 / 插件 0.2.21，`flutter test` **356/356**，插件单测 **46/46**，release APK **72,589,702 字节**（SHA256 `4FF43608…C9F9D8`）。
> - **M4.15**（2026-11-17，新建项目落点修对）：用户截图「新项目要建立的位置不对」——提示写着「将建在: D:\Projects\课程\上册\计算方法实验」。截图里还藏了第二个问题：标题仍是「新建工作区」（M4.13 已改名「新建项目」），说明手机上装的是旧 APK；但**换新版也会错**，因为 M4.13 用「授权根里有没有 `D:\Projects\项目` 这一项」来判断落点，而电脑端返回的 9 个授权根全是**具体项目**（`…\项目\deepseek手机端` 等），`…\项目` 是它们的父目录、从不在列表里，于是每次都判成「没授权」退回第一个授权根。现改为无条件指名项目根（`_targetParent`），插件 0.2.21 的 `resolveParentDir()` 本来就允许「显式指定且目录真实存在」——现场实测 `POST /desktop/workspaces` 带 `parentDir` 确实建在 `D:\Projects\<名字>`，插件一行未改。App 0.4.15+42，`flutter test` **356/356**，release APK **72,589,702 字节**（SHA256 `3AA815BE…FD2B023`）。
> - **M4.16**（2026-11-17，手机看到的必须是对话、而且一进来就是最新）：用户截图反馈「每个对话里面的内容你不应该放到最新的吗，而且你这英文是什么，我要的是对话」——正文第一条是 Host 注入的 `Time sampled while preparing turn 3, step 24: …`，第二条是模型的英文推理 `Header empty. So where does blue come from?…`。三处一起坏：①`INJECTED_USER_PREFIXES` 缺 `Time sampled while preparing`，而且**存档写入路径 `archiveEvent` 根本没调用过滤**；②`assistantText()` 在没有正文 part 时回退到全部 part，于是纯 reasoning 消息整段被当成回复；③列表靠 `jumpTo(maxScrollExtent)` 兜底，长列表首帧只量到已构建的几屏，打开就停在中段。修法：过滤规则集中到插件 `lib/chat-filter.js`（写入端 + 读取端都滤，老存档按磁盘日志重读，`ARCHIVE_EVENT_SCHEMA = 2`），`assistantText` 不再回退 reasoning，存档详情接口补 `title/cwd/lastTime/messageCount`；App 侧用同一份前缀表兜底、列表改 `reverse: true`，状态条按真实位置说话（「往上是更早的对话 · 点这里回到最新」）。App 0.4.16+43 / 插件 0.2.22，`flutter test` **361/361**，插件单测 **51/51**，release APK **72,655,282 字节**（SHA256 `1BE7856E…389CAB6`）。
> - **M4.17**（2026-11-17，桌面直播的对话排版对齐官方 App）：用户第三次贴官方 App 截图，配文「对话做成这样」。前两轮解决的是**能力**（M4.12 Markdown 排版）与**内容**（M4.16 过滤注入与推理），页面骨架却还是自己的：助手回复外套一层浅底卡片 + 左侧 3px 强调竖条、工具记录写「过程 · N 步（点开看）」、顶部是 Panel 卡片且副标题直接怼 `D:\Projects\…` 绝对路径。现在：回复**就是正文**（`itemBuilder` 直接 `return _EventRow(event: event)`）、工具条写「**已完成 · N 次工具调用**」（完成后对勾 / 进行中转圈 + 向下箭头）、顶部改成 radius 22 胶囊、副标题「**● 本机 · 目录名**」（新增顶层 `desktopFolderName()` 取路径最后一段）；`liveEmptyHint` 里那句「点上面的『过程』」也一并改掉。App 0.4.17+44，`flutter test` **366/366**，release APK **72,655,418 字节**（SHA256 `5403BC36…F6797AC`）。插件无须改动。
> - **M4.18**（2026-11-17，插件市场与电脑端同步）：用户说「插件市场是和电脑上同步的，不要现在这样的」。手机上的市场以前只读电脑端「设置 → 插件市场」里**手动配置**的第三方索引，这台电脑一个索引都没配，所以永远是空的（`indexes=0 entries=0`）——而电脑端自己的市场列着 42 个插件包。现在市场的主来源改成电脑端插件目录：插件 0.2.23 新增 `pluginCatalog()` 与 `GET /api/v1/desktop/plugins/catalog`（读 Host `pluginManager.listBundles()`，映射 `spec`/`official`/`installed`/`removable` 等，`meta` 的三种形状都认），手机端市场页进页面自动读目录、**搜索在本地过滤**、卡片带「官方」胶囊与已安装状态、安装按「包名@精确版本」下发。App 0.4.18+45，插件 `node --test` **57/57**、`flutter test` **369/369**，release APK **72,720,954 字节**（SHA256 `985AA277…15E921`）。
> - **M4.19**（2026-11-17，存档会话也能继续聊）：用户说「已存档的对话手机上也可以对话」。存档页以前底部写着「只能看不能继续发指令」，输入框根本没渲染。两条路都试过并留下证据：①`resolveAgent()` 唤醒旧会话后 `prompt()` 虽然回 `{"ok":true,"accepted":true}`，但日志里只有 `turn/start` → `agent/inbox/spliced {removedCount:1}` → `turn/end {kind:'blocked'}`，消息被吞；②`fork()` 旧会话，小会话能聊，1235 条消息的会话直接报 `outbound body measures ~1,735,026 tokens vs the effective model window 1,048,576 … stopped at the egress fuse`。最终做法：插件 0.2.24 在**原目录新开一条会话**（`sessionController.create({cwd})`），把存档里最近 **12 条**对话、每条截到 **360 字**压成摘要当开场白，返回 `{forked:true, forkedFrom, sessionId}`；手机端存档页也渲染输入条，发完自动 `pushReplacement` 跳进新会话并按直播轮询。App 0.4.19+46，插件 `node --test` **66/66**、`flutter test` **371/371**，release APK **72,720,862 字节**（SHA256 `7D808017…A3EF89C`）。附带产出 `tools/dump-session-log.mjs`（解压任意会话日志看尾部事件）。
> - **M4.20**（2026-11-17，开机后工作区变空）：用户说「每次开启之后工作区里面的内容又没了」，截图里只剩 `user` 和一条正在跑的会话。查下来是三件事叠在一起：①截图那两句话（「暂无会话」「点进去可以在电脑的这个目录里新建会话」）在新代码里已经不存在 → 手机上装的还是 ≤0.4.12 的旧 APK；②插件在 `apply` 里就拉起 Agent，那会儿 async 的 `workspaceRegistry` 还没就绪，只能把 `homedir()` 递进去，而 `RelayAgent` 的目录字段是 `private readonly`，**直到进程重启都不会重读**；③注册表经 `list()` 和 `entities` 两条路吐出同一批目录，`normalizeRoots()` 不去重，Agent 上报了 **18 条**（9 个目录各两遍）。修法：插件 0.2.25 新增只能 Agent 调的 `GET /api/v1/agent/workspaces`，Agent 连上时 + 每 20 秒（`M1_WORKSPACE_REFRESH_MS`，0 关）来取一次真实目录，变了就覆盖并补发 `device.status`；`normalizeRoots()` 按 `canonicalPath()` 去重。实测：模拟开机竞态时先上报 1 条 → 连上瞬间变 10 条；插件 `node --test` **69/69**、Agent `node --test` **60/60**。附带产出 `tools/watch-device-status.mjs`（用手机 token 连 WS 直接看 `workspaceRoots`）。
> - **M4.21**（2026-11-17，手机端也有「N 条排队消息」）：用户发电脑端截图说「这个功能手机上也得有」。电脑端在一轮还在跑的时候，会把后面排着的话列成「4 条排队消息」，每条能改字 / 删除 / 插话，还提示「Cmd/Ctrl+Enter 插话发送全部排队消息」；手机端以前完全没有这个概念。现在直播页底部浮出同一条面板：折叠时只写「4 条排队消息」，展开逐条列出、能改字（弹框）、能删、能单条插话，也能一键「全部插话」立刻送进这一轮。插件 0.2.26 新增 `GET|POST /api/v1/desktop/sessions/<id>/queue`（Host `sessionController.state()` / `updateQueue()`；`QueueAction` 只有 `edit` / `remove` / `steer`——电脑端那个上箭头就是 `steer`）。App 0.4.21+47，插件 `node --test` **76/76**、`flutter test` **377/377**，release APK **72,802,990 字节**（SHA256 `344C8A9E…6B11E125`）。
> - **M4.22**（2026-11-17，输入框里的字不见了）：用户说「输入时搜索框里面不显示」——插件市场的搜索框里敲了 `dsh`，框里只剩一个光标、提示语也不可见，可统计行已经显示「已安装 18 个 · “dsh”」，说明字进去了、过滤也生效了，就是画不出来。根因在主题：`buildAppTheme()` 用 `copyWith(textTheme: …)` 把完整的 Typography **整体替换**成一个只写了 7 条样式的部分主题，没写到的 `bodyLarge` 退化成无颜色的 `englishLike bodyLarge 2021`，而 `TextField` 的正文样式正好取 `bodyLarge` → 打出来的字是透明的（提示语被同一条样式覆盖）。改成 `base.textTheme.merge(...)` 并补上 `bodyLarge` / `labelMedium` 的颜色；新增 `theme_text_field_m4_22_test.dart` 守住「每条正文样式都有颜色」+「真实搜索框的 `EditableText.style.color` 非空」。App 0.4.22+48，`flutter test` **379/379**，release APK **72,802,990 字节**（SHA256 `4BE811E0…C8D85358`）。
> - **M4.23**（2026-11-17，提问卡也能在手机上回答）：用户说「这个需要审核操作的手机上还是没有」。查下来的关键澄清是：截图那张卡（「歌词样式 / 歌词字幕想要什么形式？」+ 三个选项 + 跳过/提交）**不是权限审批**，而是 `ask_user_question` 工具的提问卡——日志里它只是普通 `tool/call`（`session-e2e1f57b` seq 880），Host 侧走 `user-questions/request` waterfall，不落日志；而插件从 M4.4 起只接了 `approval/request`，所以电脑上正等人选项时手机上什么都没有。现在插件 0.2.27 接管这个 waterfall（只在手机看着这个会话时），把问题挂进 `/desktop/sessions/<id>/events` 的 `questions`；手机直播页渲染成卡片（单选/多选 + 可自己写一段 + 跳过/提交），提交走新的 `POST …/questions/<questionId>`；5 分钟无人应答按「跳过」放行、把这一轮交回电脑。App 0.4.23+49，插件 `node --test` **85/85**、`flutter test` **382/382**，release APK **72,836,030 字节**（SHA256 `6D7D19CA…3D0B365D`）。
> - **M4.24**（2026-11-17，存档会话在原对话里继续）：用户说「不是每个对话新开一条对话，是和电脑上一样的在这个对话里面就一直在，可以加载出来」。M4.19 当时绕成「同目录新开会话 + 最近 12 句摘要」，是因为直接唤醒冷会话只会得到 `turn/end {kind:'blocked'}`。这次把 DSH 本体（`resources/app.asar`）当文本检索，找到了真相：agent 主循环在 `preStep` 返回 `{kind:"reject"}` 时写下 `turnEnds = { kind: "blocked" }`，而 `agent/pre-step` 上唯一的拒绝者就是 `ArchivedSessionGate`——源码注释写着「unarchiving lifts the gate for the whole lineage」，也就是说会话只要还在归档里，任何唤醒都不可能有产出。修法：插件 0.2.28 先用 `workspaceController.unarchiveSession({sessionId})` 把门抬起，再往**同一个** `sessionId` 发原话（`{resumed:true}`），删掉摘要与新开会话那套；手机端不再跳转，就地切成直播轮询。实测 `960545fb…` 那条 2 条消息的存档第 2 轮 `turn/end {kind:"completed"}`、助手回「收到」，全程只有一条会话。插件 `node --test` **85/85**、`flutter test` **382/382**，release APK **72,836,030 字节**（SHA256 `74412D78…95EA7877`）。
> - **M4.25**（2026-11-17，账户余额进了「我的」）：「我的」页新增「账户余额」一栏，显示电脑端 DeepSeek 账号的充值余额与赠送余额，右上角可重新读取。凭据只在 Host 进程里（`deepseekAccount` 服务描述：「only Host consumers can obtain a request credential」），所以插件 0.2.29 代理了一次：`GET /api/v1/desktop/account/balance`（app token）→ `getBalance({version, locale, timezoneOffsetSeconds})` → 只回 `{currency, balance}` 钱包数组。手机端 0.4.25+51 新增 `AccountBalance` 模型与 `_BalanceCard`，未连接 / 未登录 / 查询失败 / 插件太旧各有提示。插件 `node --test` **95/95**、`flutter test` **386/386**，release APK **72,836,290 字节**（SHA256 `C1AC2F7E…E7CA7A93`）。注：0.2.29 这次热加载被 `HMR transactions cannot be nested` 挡住，需重开 DSH 生效。
> - **M4.26**（2026-11-17，下载进度条终于会动）：用户发截图说「这个进度条都不动」——弹窗停在 `0% · 0.0 / 69.5 MB`，可同一屏的「检查更新」行已经写着「下载中 1%」。根因很干脆：进度弹窗用 `showDialog` + `StatefulBuilder` 撑起来，`onProgress` 里只调了外层 `setState`，弹窗自己的 `setDialogState` 从来没被调用；弹窗挂在根 Navigator 上，不是 tile 的子树，所以外层刷新影响不到它，条和文字是一次性快照。现在把弹窗的 setState 存进 `_dialogSetState`，每个进度帧两边一起刷，关窗时清空。`flutter test` **387/387**（新增用例先做了反证：删掉那行调用就失败在 `50% · 0.5 /`），release APK **72,836,290 字节**（SHA256 `DC42BF0C…47056AFC`）。插件不变（0.2.29）。
> - **M4.27**（2026-11-17，手机档能新建对话、记录留在侧端）：用户发豆包的侧边栏截图说「手机上的对话可以新建对话，对话保留，可以新建对话，记录留在侧端」。查下来云端直连压根没有存储：`_messages` 只在内存里，`_newChat()` 就是 `_messages.clear()`，`_load()` 只读接口配置。现在新增 `app/lib/services/cloud_conversations.dart`（`CloudChatRecord` / `CloudConversation` / `conversationTitle()` / `CloudConversationStore`，写应用私有目录的 `cloud_conversations.json`，坏文件当空库、最多留 80 条），对话页顶栏那颗「历史」按钮从左侧滑出「对话记录」：新对话、切回任意一条、删除；标题自动取第一句用户消息，按更新时间倒序；发问后立刻落盘（断网也不丢），回复或失败原因再落一次。App 0.4.27+53，`flutter test` **397/397**（新增 10 例），release APK **72,934,594 字节**（SHA256 `2C5768CE…78C711D`）。
> - **M4.28**（2026-11-17，报错文案别误导人）：用户拿着「我的 → 账户余额」的截图问「为什么出现错误」，那条提示是 `读取账户余额失败：请求格式不正确：请确认地址指向 M1 后端（not found）`。查下来地址没错，是**电脑上跑的还是插件 0.2.28**——`/api/v1/desktop/account/balance` 是 0.2.29 才有的路由，热加载又卡在 `HMR transactions cannot be nested`，所以 404。通用 404 文案会把人往「改地址」带，现在 `fetchAccountBalance()` 单独把 404 翻译成「这台电脑上的插件还没有账户余额接口（需要 0.2.29 以上）：请升级插件后完整退出并重开一次 DSH」。App 0.4.28+54，`flutter test` **399/399**。
> - **M4.29**（2026-11-17，下载卡片加取消与后台下载）：用户说「我说的是下载时的那个小卡片上加取消和后台下载」。以前那张卡片只有一根进度条，既停不下来，也不能先收起来。现在：`UpdateService.download()` 接受 `UpdateCancelToken`，每写一帧查一次标记，取消时抛 `UpdateCancelled` 并**先关文件句柄再删**半截 `.part`（Windows 上对着还在写的文件 delete 会失败，这里踩过）；下载从 `UpdateCheckTile` 的 State 搬到 `UpdateDownloadCenter`（全局单例、`ChangeNotifier`），卡片只是它的观察者——点「后台下载」/点遮罩/按返回键都只收窗口，下载继续，回到「检查更新」点一下接着看进度，下完直接调安装器。App 0.4.29+55，`flutter test` **404/404**（新增 5 例：取消删 `.part`、中心进度与产物、中心取消、后台下载后仍安装、取消后不安装）。
> - **M4.30**（2026-11-17，手机档对话自动落到工作区）：用户说「手机上的ai助手对话完没有自动存档」，确认是手机档（云端直连）。查下来对话其实一直在存（0.4.27 起每条写进 `cloud_conversations.json`），但入口只在 AI 助手页右上角那颗时钟的侧栏里，而「工作区」只列电脑端的任务与存档会话——所以工作区顶部现在多了一组「手机对话」：标题、`N 条消息 · 相对时间`、「只存在这台手机上」，最近 5 条，**没连电脑也显示**；点一条会切到手机档并打开它（`CloudChatIntent` 单向广播 → `AssistantScreen` 切档 → `openConversationById()` 读盘选中）。App 0.4.30+56，`flutter test` **409/409**（新增 5 例）。
> - **M4.31**（2026-11-17，手机也能回答「确认需求」）：用户发来电脑端截图，Agent 弹的「确认是哪一档」问题卡手机上什么都没有。根因是接管门槛：`user-questions/request` 里 `isWatching(sessionId)` 为假就直接 `next()` 交回电脑弹窗，而手机没打开那条会话的直播页就永远不满足。插件 0.2.30 把条件放宽成「正在看这条会话 **或** 手机还连着」（`hub.appCount > 0`），并新增 `GET /api/v1/desktop/pending` 回跨会话摘要；手机端 0.4.31+57 在工作区顶部加提示条「确认范围 · 还有 N 个」，点一下进那条会话答题。插件 `node --test` **101/101**、`flutter test` **414/414**，release APK **73,016,578 字节**（SHA256 `CC2B4F34…42A5094C99`，versionCode 57）。
>
>
> - **M4.38**（2026-11-18，经常连接超时）：用户问「经常会出现这个问题是什么原因」，截图是直播页红条「拉取桌面会话失败：连接超时（10 秒）」。实测这条会话首屏要 175~187 KB（为了凑够 12 条对话得回扫 319 条事件，改 limit 也没用），走 Cloudflare 快速隧道一个来回 1~2.4 秒；而手机端原来每 1.5 秒盲发一次 Timer.periodic、不看上一个请求还在途，10 秒超时前已经堆了六七个，彼此抢同一条隧道。现在：在途不重发、失败按 3/6/12/24/30 秒退避、只为「拉桌面会话」放宽到 20 秒超时、idleTimeout 从 5 秒提到 20 秒。
> - **M4.37**（2026-11-18，往上拽一下就开新对话）：手机档对话里把消息列表翻到顶端后继续往下拽超过 130 像素，顶部浮出「松手开始新对话」，松手就新建一条；中途松手回退则作废。只认到达顶端之后的越界量（`OverscrollNotification.overscroll < 0`），正常翻历史不误触；列表加了 `AlwaysScrollableScrollPhysics`，内容不够一屏的短对话里也能拽。App 0.4.37+63，`flutter test` **433/433**，release APK **73,049,346 字节**（SHA256 `F9671561…CA698D6`）。
> - **M4.36**（2026-11-18，提问卡的提交按钮钉住）：用户纠正「有通知，只是划不动提交不了」。M4.35 只是把整块卡片塞进滚动区，按钮仍会跟着选项滚出可视范围——真正的修法是让卡片自己排版：标题行钉住、只有选项区 `Flexible(fit: FlexFit.loose)` + `SingleChildScrollView` 在里面滚，「跳过 / 提交」永远钉在卡片底部；卡片高度按内容自适应（上限仍是屏高 55%），短卡片不再白占半屏。App 0.4.36+62，`flutter test` **430/430**，release APK **73,049,346 字节**（SHA256 `13F0D3AF…24E349A3`）。
> - **M4.35**（2026-11-18，提问卡不再卡死 + 等回答会通知）：用户报「这个页面划不动，而且没有消息通知」。① 桌面直播页把授权卡与提问卡钉在对话列表上方、两张卡自己不滚，两个问题三四个选项就把 `Expanded(ListView)` 挤成 0 高 → 现在这块限高屏高 55%（`ConstrainedBox` + `SingleChildScrollView`），超出在卡内滚动，对话列表始终留得下；② 提问从来没走过通知通道，只有授权才有 → `LiveStore.notePendingQuestions()` 在 5 秒轮询拿到新提问时发「电脑在等你回答 · <标题>」，同一提问不重复发、答完收回，开关沿用「等待授权提醒」。App 0.4.35+61，`flutter test` **430/430**，release APK **73,049,346 字节**（SHA256 `0B496D90…083D38BE2`）。
> - **M4.34**（2026-11-18，手机对话挪到抽屉）：用户纠正「手机对话记录不保存到工作区，保存到这」，配图圈的是抽屉「历史会话」区。工作区里的 `_PhoneChatsSection` 整段删掉（连同 `_phoneChats`、`onOpenCloudConversation`、`conversations` 参数与 import），抽屉在「历史会话」标题上方新增「📱 手机对话 · N」小段（标题 + `N 条消息 · 相对时间`，最多 6 条），点一条关抽屉、切到 AI 助手、打开那一条（`CloudChatIntent`）。`RootShell` 新增可注入的 `conversations`，`AssistantScreen` 把同一份存储透传给内嵌 `CloudChatScreen`，避免 widget 测试里真实读盘挂住。App 0.4.34+60，`flutter test` **423/423**，release APK **73,032,962 字节**（SHA256 `021EC859…9CDBC39E`）。
> - **M4.33**（2026-11-17，余额卡片加「去充值」）：查过 Host `deepseekAccount` 的 13 个方法，**没有任何下单/付款能力**（`getPlatformSession()` 还是 Host-only 凭证），所以只能跳官方充值页。新增 `UrlOpener`（MethodChannel `deepseek_remote/update` 的 `openUrl`，Kotlin 侧只放行 http/https），余额卡片在已连接时右对齐一个「去充值」，失败提示「可以在电脑上充值后再点右侧刷新」。App 0.4.33+59。
> - **M4.32**（2026-11-17，余额卡片排版与数字）：用户发「这对吗」的截图——金额是 `¥12.443675700000000`，左侧标题被挤成每行一个字，赠送余额显示 `$0`。真实返回里钱包是 `USD 0E-16` 与 `CNY 12.4137841000000000`。现在 `formatMoneyAmount()` 统一两位小数（`0E-16` → `0.00`），`AccountBalance.primary` 优先「非零的 CNY」，金额用 `FittedBox` 限宽、标题列 `maxLines: 2` 不再被挤。App 0.4.32+58。
> - **M4.39**（2026-11-18，往上滑新建对话）：用户纠正 M4.37 的手势方向——「不是下划是往上划，有个加载圈，根据上滑的力度」。现在停在最新一条消息上继续往上滑，底部浮出一枚加载圈（进度跟着手走的距离变），滑过 130 像素就补满并显示「松手开始新对话」，松手开新对话；这一手中途滚过列表（含从半路一甩到底）不攒越界量，避免误换对话。新增 3 例（原 3 例删除），全量 437/437。
> - **M4.40**（2026-11-20，从不同角度测试 + 修掉审计抓到的问题）：这一轮不加功能，
从接口契约、存档容错、小屏大字号、运行期四个角度压测。新增 25 例、全量 **462/462**。
抓到并修掉 2 个真 bug：①坏时间戳（`updatedAt:'yesterday'`）以前退回「现在」，
反而顶到侧栏「最近」第一位 → 改退回 1970 沉底；②320x480 + 系统字号 2.0 时桌面直播页
三处 `RenderFlex` 溢出（头部、运行中那一行、底部状态行）→ 上下两块按 body 真实高度封顶并各自可滚，
只在真的放不下时才封顶。插件侧另记 6 条待修（坏 JSON 返 500、`afterSeq` 非法返全量 253 KB、
86 条 token 永不失效等）。App 0.4.40+66，release APK **73,049,346 字节**（SHA256 `8EF276D9…F8F741F`）。
> - **M4.41**（2026-11-20，删掉「电脑」页）：用户说「可以把这个页面删了」。
抽屉从四个入口收缩到三个（AI 助手 / 工作区 / 我的），`control_screen.dart` 整份删除；
那一页唯一独占的**紧急停止**搬进「我的」（连接时才出现，滑动 + 二次确认不变），
Agent / Harness 版本与连接状态本来就在「我的 → 连接与设备」。App 0.4.41+67，
`flutter test` **463/463**，release APK **73,032,914 字节**（SHA256 `5A87F1DF…A5F12A61`）。
> - **M4.48**（2026-11-23，两档改名说清楚）：第二阶段第 ⑨ 条，也是第二阶段的收口。AI 助手页的「手机 / 电脑」改成「本机对话 / 远程电脑」，抽屉与会话中心里 M4.47 叫「本机直连」的分组一并统一成「本机对话」，三处一个叫法。第一次切档时输入框上方挂一条说明：本机对话用自己的 API Key 直连云端、不经过电脑、只能处理手机里的文件；远程电脑连上后能读写工作区、跑任务，危险操作会先问——点「知道了」或 × 收起，`mode_intro_seen_v1` 记住后不再打扰。新增 4 例（含反证），`flutter test` **513/513**；App **0.4.48+74**、APK **73,213,886 字节**（SHA256 `ECD2E0CB…C6F40CAC`）；报告 [M4_48_REPORT.md](docs/research/M4_48_REPORT.md)。
> - **M4.47**（2026-11-23，统一「会话」入口）：第二阶段第 ⑧ 条。会话原来有三个入口（顶栏历史弹层、抽屉「手机对话」、抽屉「历史会话」）、两套数据源。现在只留一页 `SessionCenterScreen`：上半「远程电脑」（桌面会话镜像 + 只在存档里的会话，存档那条标「已存档」，点开进直播），下半「本机直连」（手机本地对话，点一条切回 AI 助手并打开）。抽屉两段合成一段「会话」+「全部会话」入口，AI 助手顶栏历史按钮也进这一页。新增 5 例（含反证），`flutter test` **509/509**；App **0.4.47+73**、APK **73,213,886 字节**（SHA256 `906F8D5E…A266A70B`）；报告 [M4_47_REPORT.md](docs/research/M4_47_REPORT.md)。
> - **M4.46**（2026-11-23，统一轮询协调器）：第二阶段第 ⑦ 条。任务页/工作区页以前各自 `Timer.periodic(5s)`，页面被 `IndexedStack` 保活后「看着别的页也照样每 5 秒请求」，且不看上一个请求是否在途、失败也按原节奏重试 → 新增 `services/poll_coordinator.dart`（一次只跑一个、失败 2 的幂退避封顶 30 秒、成功立刻复位、`refreshNow()` 立刻刷），`RootShell` 变成 `WidgetsBindingObserver` 并把「当前是工作区页 && App 在前台」算成 `active` 传给任务页，工作区页切后台即停。新增 7 例（含反证），`flutter test` **504/504**；App **0.4.46+72**、APK **73,181,078 字节**（SHA256 `D6F63B87…A376FF6B`）；报告 [M4_46_REPORT.md](docs/research/M4_46_REPORT.md)。
> - **M4.45**（2026-11-23，新建的工作区让电脑认下来 + 修掉换签名导致的安装冲突）：手机「新建项目」以前只 `mkdirSync`，没写进 DSH 的 `workspaceRegistry`，所以电脑端列表里看不到 → 插件新增 `registerDesktopWorkspace()`（`registry.create(path, title)`，失败只记日志不挡建目录，复用已存在目录时也幂等补注册）；顺带修上一版换 release 签名后手机报「软件包与现有软件包存在冲突」——`key.properties` 加 `useDebugSigning=true` 开关，本轮用 debug 签名出包以便覆盖升级，正式签名留到卸载重装那一次。插件 **0.2.33**、App **0.4.45+71**、插件测试 **146/146**、`flutter test` **497/497**、APK **73,181,078 字节**（SHA256 `744CE8CE…5BAD4901`）；报告 [M4_45_REPORT.md](docs/research/M4_45_REPORT.md)。
> - **M4.44**（2026-11-23，第一阶段六条安全改动）：紧急停止改成「先请电脑停下 → 确认或 3 秒超时 → 再断开」，返回「任务已停下 / 只断开 / 未确认」三态；审批弹层下滑和返回只算「稍后再答」，只有点「拒绝本次操作」才真的拒绝；API Key 进 `flutter_secure_storage`、插件 `tokens.json` 只存 `sha256` 并收紧 ACL；新增 `NetworkUrlPolicy`（公网必须 https，明文只允许内网并提示）；release 用独立 keystore + `tools/verify-release.mjs` 四项一致性校验；`flutter analyze` 借 ASCII junction 恢复可跑（37 → 30 条，0 error）。

> - **M4.43**（2026-11-23，按 DSH_INSTRUCTIONS 改 8 条）：`历史会话`死链修好（改读桌面会话镜像）、
>   App token 不再明文落盘（`TokenVault` + 系统安全存储，带迁移）、插件 token 只增不减的三层治理、
>   `afterSeq`/`limit` 非法值返回 400、未知路由 code 改 `NOT_FOUND`、`file/raw` 支持 Range、
>   大响应 gzip、删根目录两个 0 字节同名文件并加 `.gitignore`。插件 0.2.31 / App 0.4.43+69。
> - **M4.42**（2026-11-20，新增「功能」页）：「做一个功能页面放到我的上面，先把插件拿出来放到里面」。
抽屉里在「工作区」与「我的」之间多了一页**功能**（`features_screen.dart`），
「插件管理」从「我的 → 关于与更新」搬进这一页；抽屉回到四项：AI 助手 / 工作区 / 功能 / 我的。
App 0.4.42+68，`flutter test` **466/466**，release APK **73,049,398 字节**（SHA256 `9C0B7C8C…E87632C7`）。
> - **M4.49**（2026-11-23，插件热修：便携版 DSH 下 Agent 起不来）：手机端工作区主 Tab 有内容，点右上角文件夹进二级页却是「电脑端还没有配置工作区（M1_WORKSPACE_ROOT）」。查下来是电脑端 Agent 子进程根本没起来——它只找 PATH 的 `dsh.cmd` 和 `%LOCALAPPDATA%` 默认安装位，而这台机器 DSH 是便携版装在 `<DSH 安装目录>`，五条发现路径全落空，每 30 秒报一次「未找到 DeepSeek Harness 安装」。改两条路：插件 `resolveDshInstallRoot()` 从 `process.execPath` 推出安装根并注入 `DSH_INSTALL_ROOT`；agent 侧再加一条兜底 `installRootFromParentExe()`（问父进程 exe，是 `DeepSeek Harness.exe` 就取目录），不依赖插件重载、当场生效。插件测试 **157/157**（新增 11 例 + 反证），Agent 已在 10 秒内自动回来、11 个工作区根全部上报；插件 **0.2.34**；报告 [M4_49_REPORT.md](docs/research/M4_49_REPORT.md)。
> - **M4.50**（2026-11-23，工作区「新会话」改成送去真正的对话框）：用户报「这新建对话没有对话框啊，电脑上也没有显示」。原因是点「新会话」发的是 `conversation.create`，会话由电脑端 Agent 子进程在磁盘上建出来，可手机工作区列表和电脑端会话列表读的都是**电脑端主进程内存里的 `sessions`**，两个进程两套表 → 会话确实存在（磁盘上 `97e99c63-…/session.v4.jsonl.zstd`，22:29:11 落盘），两边却都显示不出来。这轮不再建空会话：工作区页的按钮改成「去对话框发第一条消息」，绑好目录、切到 AI 助手的「远程电脑」档并聚焦输入框，用户发第一条消息时才真正建会话，对话框就是一直在用的那个聊天区；电脑还在忙时只记下目录并提示「等它结束再开新会话」。新增 `RemoteChatIntent` 单例（沿用 `CloudChatIntent` 写法）、`LiveStore.startNewConversation()` 清空旧会话状态。新增 3 例测试 + 反证（注释掉跳转后 2 例失败），`flutter test` **516/516**，`flutter analyze` 0 error（32 条既有告警不变）。App **0.4.50+75**，release APK **73,213,886 字节**（SHA256 `17668D5B…7985EA0`，debug 签名可覆盖）；报告 [M4_50_REPORT.md](docs/research/M4_50_REPORT.md)。
> - **M4.51**（2026-11-24，工作区项目卡默认折叠）：用户发来截图——「deepseek手机端」一个项目 21 条会话全铺在首页，项目名被挤到最上面、想找正在跑的那条要滚很久。改成：项目卡默认收起，只留项目名、目录、`N 个会话 · M 个进行中 · 最后活动…` 摘要；点项目头才摊开，再点收起，各项目独立展开互不影响（`_expanded` 按工作区路径记，页面内存即可，不写设置）。项目头右侧加一个随展开旋转的小箭头，折叠时也有「能点开」的暗示；空项目没有内容可展开，不画箭头。新增 3 例测试（默认折叠 / 展开收起互不影响 / 空项目无箭头）+ 反证（把判定改成 `expanded: true` 后 2 例失败），同时改 5 个依赖「默认展开」的旧断言；`flutter test` **519/519**，`flutter analyze` 0 error（32 条既有告警不变）。App **0.4.51+76**，release APK **73,213,886 字节**（SHA256 `5C873F3C…31DF811`，debug 签名可覆盖）；报告 [M4_51_REPORT.md](docs/research/M4_51_REPORT.md)。
> - **M4.52**（2026-11-24，手机没有 WPS 也能读 .docx 正文）：用户发来截图——在工作区打开 `示例文档.docx`，App 只给一块「用其他应用打开」面板，点了还提示「手机上没有能打开这种文件的应用」。这台手机没装 WPS，于是文档在 App 里彻底读不到。这轮让 App 自己解：新增纯 Dart 的 `office_text.dart`（最小 zip 读取 + `word/document.xml` 抽文字，`stored` 直取、`deflate` 走 `ZLibDecoder(raw: true)`，不新增依赖），文件页对 `.docx` 按文字预览——正文可选中可滚动，顶部标「按文字预览（排版和图片不显示）」，底部保留「用其他应用打开」；抽不出文字（加密、非标准、超过 12MB）时说明原因，不拿空白页骗人。新增 8 例测试 + 反证（把抽取开关改成 `false` 后文件页那例失败），`flutter test` **527/527**，`flutter analyze` 0 error（32 条既有告警不变）。App **0.4.52+77**，release APK **73,230,270 字节**（SHA256 `B1E53C95…358F67`，debug 签名可覆盖）；报告 [M4_52_REPORT.md](docs/research/M4_52_REPORT.md)。
> - **M4.53**（2026-11-24，电脑上的「确认需求」卡回来了）：用户报「电脑上的这个审核怎么没了」——手机上明明挂着「电脑在等你回答（2 个问题）」，电脑那边却一张卡都没有，会话看着像卡死。根因是 M4.31 为了「手机不在直播页也能答」，把提问门禁改成了「手机连着就接管」（`phoneOnline = appCount > 0`），而 `user-questions/request` 是 waterfall：插件一接管，桌面默认问答器就不会被调用，电脑恒不出卡。这轮把门禁收回成与授权一致的 `if (!isWatching(sessionId)) return next();`——**手机正停在这条会话的直播页才接管，其余时候交回电脑弹窗**；插件删掉 `phoneOnline`，注释写清来由与「两端同时显示做不到」（事件目录里只有 waterfall，没有广播事件可以撤掉电脑那张卡）。新增 2 例测试 + 反证（改回旧门禁后用例报 `phoneOnline`），插件测试 **159/159**；插件 **0.2.35** 已热重载生效（health 回读 `version:"0.2.35"`、`agentOnline:true`），手机 App 不用换包（仍 0.4.52+77）；报告 [M4_53_REPORT.md](docs/research/M4_53_REPORT.md)。
> - **M4.54**（2026-11-24，电脑和手机同时出现同一张提问卡）：M4.53 之后用户接着问「怎么才能同时有」。Host 侧只有 waterfall `user-questions/request`，看着只能二选一；但拆开 `resources/app.asar` 读到 GUI 提问卡的实现 `@deepseek-ai/dsh-client-ui-user-questions` 才明白——卡片由「活着的 Host 请求」+「Session 的 `userQuestions` 投影」驱动，多个客户端可同挂同一 pending，**先答者生效、晚到的提交被 gateway 静默丢弃**，投影不再列出该 call 时卡片自己收掉。所以插件接管时先同步 `Promise.resolve(next())` 让电脑照常挂原生卡，手机也挂一张，两边赛跑：电脑先答用电脑的、顺手摘掉手机卡；手机先答用手机的、电脑那张由投影自动关闭。两个 5 分钟 timer 都 `.unref()`，手机卡超时只收手机。改 2 例 + 新增 2 例，插件测试 **161/161**，反证（不叫 `next()` 时 2 例失败）；插件 **0.2.36** 已热载生效（`/api/v1/health` 回读 `version:"0.2.36"`、`agentOnline:true`）。报告 [M4_54_REPORT.md](docs/research/M4_54_REPORT.md)。
> - **M4.55**（2026-11-24，中间步骤，未单独交付）：M4.54 之后用户接着说「手机上还是没有」。先把门禁放宽成 `isWatching || phoneConnected`（手机连着就接管），插件 `0.2.37`，测试 162/162——真机仍然只有电脑出卡。结论：门禁不是根因，问题在「事件根本不到插件」，并入 M4.56。
> - **M4.56**（2026-11-24，手机也能看到并回答提问卡了）：在监听器入口写文件日志实测——`ctx.on('user-questions/request', …)` **一次都没被调用**。查 DSH 的 `docs/subsystems/user-questions.md` 才明白：DSH 的问答工具有两条路，`userQuestions.ask()` 才派发 waterfall，`askTimed()`（「客户端决定」的那条）不派发，`ask_user_question` 走的正是后者。于是插件改从**会话日志**里认提问：`collectLogQuestions()` 找「`tool/call` 是 `ask_user_question` 且没有配对 `tool/result`」的调用，`questionId` 直接用 `callId`；会话详情的 `questions` 与 `/desktop/pending` 都改成「waterfall + 日志」两路合并（按 `questionId` 去重），手机随时能看到卡；回答时先走原 `pendingQuestions`，查不到就用 `agents.get(sessionId)` + `userQuestions.answer(agent, callId, {answers})` 交回，「跳过」按每题空 `selected` 生成完整批次避免 `BAD_ANSWER`。顺手删掉 M4.55 留在插件里的三处临时诊断写盘。新增 4 例（含 `collectLogQuestions` 行为用例：已答/未答/非问答工具/坏 JSON 只挑出 1 条），插件全量 **166/166**，反证（去掉「已回答」判定后行为用例失败 17/1）；另修 `pending.test.js`、`session-events.test.js` 的注入表（此前 9 例 `ReferenceError`）。0.2.40 真机试出「一口气 8 张空卡」——日志里结果事件的 id 在 `toolCallId` 上（`callId` 为空），只认 `callId` 等于所有历史提问都没答过；0.2.41 改成 `toolCallId ?? callId ?? message.source.callId`（反证：只认 `callId` 时 2 例失败）。插件 **0.2.41** 已热重载（`/api/v1/health` 回读 `version:"0.2.41"`、`agentOnline:true`），手机 App 不用换包（仍 0.4.52+77）；报告 [M4_56_REPORT.md](docs/research/M4_56_REPORT.md)。
> - **M4.57**（2026-11-25，功能页新增「接收文件」）：用户说「功能页面可以加一个接收文件，用来我想看做好的文件，我让你发你就发到那，我可以查看」。以前手机上只有「工作区 → 目录 → 浏览文件」这一条路，文件不在授权根里就完全看不到。插件现在多一个 `received/` 目录（`<stateDir>/received`，启动即建），放进去的文件按修改时间倒序列出，接口 `GET /api/v1/received`、`GET|DELETE /api/v1/received/<name>`（要 app token、只取 basename 并拒 `..` 与隐藏名、最多 200 条）；手机「功能」页多一行「接收文件」，点开复用文件预览——图片能放大、`.docx` 按文字读、`.md/.txt` 直接看正文，其它交给系统应用，接收文件只读。新增 App 3 例测试（530/530，analyze 0 error）、插件 10 例测试（176/176，反证：放开 `basename` 后穿越用例失败）。App **0.4.57+78**，release APK **73,295,806 字节**（SHA256 `345535BE…18BFB509`，debug 签名可覆盖）；插件 **0.2.42**（待热载生效）；报告 [M4_57_REPORT.md](docs/research/M4_57_REPORT.md)。
> - **M4.58**（2026-11-25，手机回答提问：先能说清原因，后真正修通）：手机点提问卡的「提交」曾一律显示「接口不存在（HTTP 404）」，因为插件失败时只回 `false`、服务端一律 404。0.2.43 先让失败带上原因（`QUESTION_NOT_FOUND` / `NO_QUESTION_SERVICE` / `NO_AGENT` / `NOT_CONTINUED` / 异常码，路由改回 409 把 `message` 带给手机）；拿到 `NOT_CONTINUED` 后读 DSH 源码弄清：`userQuestions.answer()` 只认 `continued`（超时后）的提问，**open 提问只能靠 waterfall 的返回值来答**，而 waterfall 的 `req` 里没有 `wait.callId`——插件只能用自造 `q_…` 当键，手机传的却是日志里的真实 `call_00_…`，两边对不上。0.2.44 加 `questionContentKey`（会话 + 题面）让两路去重、合并时日志在前（留下带选项的那张卡）、回答时先按内容找 waterfall 挂起项并 `finish()`。真机：卡带选项、`提交` 可点，手机上选的答案真的回到了工具。插件测试 **180/180**（`questions.test.js` 22/22），`node --check` 通过，0.2.44 已热载（`/api/v1/health` 回读 0.2.44）；报告 [M4_58_REPORT.md](docs/research/M4_58_REPORT.md)。
> - **M4.59**（2026-11-26，手机原生回答提问：插件自己当 DSH 的浏览器客户端）：前几轮都卡在同一处——`user-questions/request` 是 **agent 作用域** waterfall，插件从根 `ctx` 注册监听器永远收不到；从会话日志「猜」出来的提问又只能调 `userQuestions.answer()`，它对 open 提问一律返回 false。这一轮把 `app.asar` 里的 `@deepseek-ai/dsh-api-gateway` 解开，还原了远程事件协议（WS `/api/remote.mux` + `$events` 流，回答走 `POST /api/$events/result`），插件自己登录成浏览器客户端去订阅：真机上收到了 `waterfall`，手机点「提交」后 `REPLY … {"ok":true}`，工具拿到的就是手机选的项。**不改 DSH 安装包，手机也不用换 APK。**
> - **M4.60**（2026-11-26，远程客户端收尾）：远程事件客户端原来只由 `stateDir/remote-client.on` 手工开关决定，热载还会留下上一版的 WebSocket，同一提问被两个实例各答一次。现在开关做成配置项（`remoteClient: false` 或 `M1_REMOTE_CLIENT=0` 关，默认开），句柄挂在 `globalThis` 上、新实例启动前先关旧的，并用 `ctx.effect` 在插件卸下时同步关连接。重启一次 DSH 清掉遗留实例后，自检同一 `eventId` 只剩**一条** `REPLY`。
> - **M4.61**（2026-11-26，清理自检脚手架）：把 M4.58c–M4.60 为了查问题留下的 `q-answers.log` 流水日志、`auto-answer.on` 自动抢答、以及那次失败的 `agent/created` 取作用域尝试全部收掉。诊断日志改成 `debug` 开关（插件配置 `debug: true` 或环境变量 `M1_DEBUG=1`），平时不写盘。关掉日志后用脚本模拟手机提交，`200 {"ok":true,"answered":1}`，`ask_user_question` 拿到的就是脚本选的那项。
>
> - **M4.62**（2026-11-27，直播推送，进行中）：手机直播页一直靠 1.5–5 秒轮询，插件的远程事件客户端已经能收到 `api-session/*` 的 `emit`，于是新增一条推送通道：`lib/live-hub.js` 在 `/api/v1/desktop/live` 上做 WebSocket 握手，`server.js` 的 `upgrade` 只处理这个路径、其它路径**直接放行**（同一个 server 上还挂着中继的 `/ws`，第一版写 404 把 agent 掐掉过），`index.js` 把 `emit` 里的 `api-session/*` 广播成 `{type:'session'}`、把 `waterfall`/`cancel` 广播成 `{type:'question',state:'open'|'gone'}`。插件 **0.2.67** 已热载，探针能拿到 `101` + `{"type":"ready"}`，`health.live` 有连接数；但 `session`/`question` 帧还没有在真机上观测到，这一条**未完成**。
> - **M4.64**（2026-11-27，文件分享）：用户反馈「文件不能分享和用其他应用打开」——这台手机没装 WPS，`.docx` 点「用其他应用打开」只弹一句「手机上没有能打开这种文件的应用」，文件页又没有别的出口。现在 `FileOpener` 多了 `shareBytes`：原生侧把字节写进 `cacheDir/share/files/`，用 FileProvider 换成 `content://` 后拉起 `ACTION_SEND` 分享面板（微信 / QQ / 文件管理器都能收）；文件页 AppBar、`.docx` 文字预览底栏、「打不开」兜底面板都补了分享入口，打开失败时也改成指路。App **0.4.59+80**，release APK **73,361,342 字节**（SHA256 `5A60CE79…00D7C29`，debug 签名可覆盖），测试 **536/536**、analyze 0 error，反证（`_share()` 改成直接 return）时「接收的文件可以交给系统分享面板」失败；报告 [M4_64_REPORT.md](docs/research/M4_64_REPORT.md)。
> - **M4.63**（2026-11-27，启动自愈）：用户反馈「手机端 App 怎么一直闪退」，并且**清掉应用数据就能打开**——判定本地存档里某条状态把启动卡死，而应用层没法替用户清数据。新增 `services/boot_guard.dart`：每次冷启动记一次尝试（`boot_attempts` / `boot_last_attempt_at`），画出第一帧后归零；3 分钟内连续 3 次没走到第一帧就判定上次启动失败，`disconnect()` 清掉会话存档再启动，并提示「上次启动没有完成，已清掉本地连接存档，重新扫码即可」。自愈本身出错不会挡住启动。App **0.4.58+79**，release APK **73,295,806 字节**（SHA256 `2D09D8F7…F92F1EDDC`，debug 签名可覆盖），测试 **533/533**、analyze 0 error，反证（把阈值改成 1）时「前两次没走完不会清存档」失败；报告 [M4_63_REPORT.md](docs/research/M4_63_REPORT.md)。
>
- **M4.65 / M4.66**：App 内「充值」页（余额 + 三步 + 官方入口）与功能页「更新日志」（优先读电脑、离线回退随包）。App `0.4.60+81`，插件 `0.2.69`。

> - **M4.67**（2026-11-27，充值页能在 App 内付款）：用户追问「dsh 这个充值界面做不到手机上面吗」，说明电脑端的充值其实也是把官方网页嵌进 DSH 窗口，于是手机端照做：新增 `screens/recharge_web_screen.dart`，用 `webview_flutter`（新依赖）在 App 内打开 `platform.deepseek.com` 官方充值页，手机上登录一次就能付款；`alipays://`、`weixin://` 交给系统应用，返回后充值页自动刷新余额，系统浏览器降级成次级入口。App **0.4.61+82**，release APK **74,216,293 字节**（SHA256 `BB8B5544…CC607E`，debug 签名可覆盖），测试 **545/545**、analyze 0 error，反证（去掉内嵌页跳转）时「主按钮进 App 内嵌页」失败；报告 [M4_67_REPORT.md](docs/research/M4_67_REPORT.md)。
>
> - **M4.68**（2026-11-27，充值只保留 App 内入口）：用户看完 0.4.61 后要求「只保留在应用内打开充值页」。充值页删掉「用系统浏览器打开」与 `_openRecharge()`，内嵌页删掉右上角的浏览器出口，`urlOpener` 只留给 `alipays://` / `weixin://`。App **0.4.62+83**，release APK **74,200,081 字节**（SHA256 `D51BD880…A828D5`，debug 签名可覆盖），测试 **545/545**、analyze 0 error（三处断言从「交给浏览器」改成「不应再有这个出口」）；报告 [M4_68_REPORT.md](docs/research/M4_68_REPORT.md)。
>
- **M4.69**：扫描件 .docx 按页看图——用户那份「没读出文字」的 `示例作业.docx` 其实没有文字（`<w:t>` 计数 0），是 4 张扫描照片；文件页现在在抽不出文字时改看 `word/media/` 里的图片（按页竖排、最多 24 张 / 40 MB），手机上不装 WPS 也能看。App 0.4.63+84。
- **M4.70**：打不开的文件不再给按钮——手机没有能处理该类型的应用时，文件页藏掉「用其他应用打开」，兜底改成「这个文件只能在电脑上看」并只留「分享文件」；判断只做 `resolveActivity` 检查、不启动应用。App 0.4.64+85。
- **M4.71**：修好「检测不到能打开的应用」——不是权限问题，是 Android 11+ 包可见性：manifest 的 `<queries>` 只声明了 `PROCESS_TEXT`，`resolveActivity` 对文件一律返回 null。补上 `ACTION_VIEW` / `ACTION_SEND` 声明，检测改用 `queryIntentActivities`，真正打开时改成「先启动、失败再报错」。App 0.4.65+86。
- **M4.72**：修好「分享失败 / 打不开」——根因不是手机没装应用，而是 `content://` 地址生成用错组件（androidx `FileProvider` 配自写 `ShareFileProvider`，缺 `FILE_PROVIDER_PATHS` 必然抛异常）。改成 `ShareFileProvider.uriForPreview/uriForShare` 自己拼 URI，补齐 `preview/`、`share/files/` 路径与 MIME，并让 `FileOpener.lastError` 把原生原因带回提示。App 0.4.66+87。
- **M4.73**：「用其他应用打开」改成每次弹系统选择器（`Intent.createChooser`，标题「用其他应用打开」），用户可以自己挑应用，不再受「默认打开方式」影响。App 0.4.67+88。
> **下一步**：0.4.67+88 已发布（APK 见下表）。接下来 ①装 0.4.67 后对任意文件点「用其他应用打开」，应弹出应用列表；②点「分享文件」应弹系统分享面板，失败时提示会带原生原因；③`示例作业.docx` 应显示 4 页扫描图；④真机验收 M4.57 接收文件；⑤验证 M4.62 直播推送帧。

---

## 从这里开始

| 产物 | 说明 | 位置 |
|---|---|---|
| 手机端 APK（M4.67 版，**最新**） | `dist/DeepSeek-Remote-latest.apk` / `dist/DeepSeek-Remote-AI-v0.4.67-m4.67.apk` | 74,217,829 字节 | 0.4.67-m4.67 / versionCode 88 | `EBE3A3BBCF275265ED584DA752E37D823204D9484C7567B2197ADEF3246B212D` |
| **M1 端到端交付报告** | 全链路验证矩阵、手机 5 张真实截图、启动手册、已知限制、证据索引 | [`docs/research/M1_E2E_REPORT.md`](docs/research/M1_E2E_REPORT.md) |
| **M1.1 交付报告** | PostgreSQL 持久化、历史 REST、真实任务页、重启不丢历史证据、遗留清单 | [`docs/research/M1_1_REPORT.md`](docs/research/M1_1_REPORT.md) |
| **M2-α 交付报告** | 锁屏审批通知、前台服务保活、token 持久化（M2-A4 实测）、真机补测步骤 | [`docs/research/M2_REPORT.md`](docs/research/M2_REPORT.md) |
| **M2.1 交付报告** | task_events 独立事件表、会话级统一 seq、事件补拉端点、断线 60s 演练 PASS、执行中排队 | [`docs/research/M2_1_REPORT.md`](docs/research/M2_1_REPORT.md) |
| **M2.2 交付报告** | 完成自动折叠、排队「立即发送」、6 套主题、分享卡 PNG、长按菜单；143/143 测试、APK 构建、限制与真机验收清单 | [`docs/research/M2_2_REPORT.md`](docs/research/M2_2_REPORT.md) |
| **M2.3 交付报告** | 视觉重构：浅/深色 token、六页重做、跟随系统外观、154/154 测试、APK 与下载通道、限制 | [`docs/research/M2_3_REPORT.md`](docs/research/M2_3_REPORT.md) |
| **M2.4 交付报告** | 删除演示数据：删除清单、六页减法、连接空态、164/164 测试、真实链路 6/6、APK 与下载通道、限制 | [`docs/research/M2_4_REPORT.md`](docs/research/M2_4_REPORT.md) |
| **M2.5 交付报告** | 应用内在线更新：检查/下载/系统安装器、后端 version/apk 接口、178/178 测试、接口实测、首次需手动装、限制 | [`docs/research/M2_5_REPORT.md`](docs/research/M2_5_REPORT.md) |
| **M2.6 交付报告** | 项目同步：目录浏览/文件预览/项目内发指令、WSS 请求-响应协议、Agent 本地 FS、14/14 验证、190/190 测试、更新到 0.1.7、限制 | [`docs/research/M2_6_REPORT.md`](docs/research/M2_6_REPORT.md) |
| **M3.6 交付报告** | 对话对齐 PC（过滤 reasoning）、插件归一化 + 插件市场（bundles/market 接口）、会话按最后时间排序并显示消息数、打开即最新；插件 12/12、App 244/244、APK 177,899,089、HMR 锁需重启 DSH | [`docs/research/M3_6_REPORT.md`](docs/research/M3_6_REPORT.md) |
| **M4.0 交付报告** | 工作区页重做（倒序/状态徽标/新建会话/浏览文件）、手机端新建工作区（`POST /desktop/workspaces`）、Hub 骨架 `device.status` 清空工作区根的修复；插件 0.2.9、App 255/255、release APK 71,621,290 字节、自检脚本 `tools\verify-plugin-m4.ps1` | [`docs/research/M4_0_REPORT.md`](docs/research/M4_0_REPORT.md) |
| **M4.1 交付报告** | 已安装插件画廊（内置/实验性分组 + 逐项开关，`GET /desktop/plugins/gallery`）、插件市场索引兜底与 `search` 新签名、卡片下载量/星标；插件 0.2.10、App 263/263、release APK 71,720,030 字节、自检脚本扩到 8 项 | [`docs/research/M4_1_REPORT.md`](docs/research/M4_1_REPORT.md) |
| **M4.2 交付报告** | 助手页直连对话（去模式切换/空欢迎区）、附件入口常驻（拍照/相册/文件 + 缩略图）、附件按工作区落到 `<工作区>\手机附件\` 并回执；插件 0.2.11、App 267/267、release APK 71,867,762 字节、自检脚本扩到 9 项、**真机未复测** | [`docs/research/M4_2_REPORT.md`](docs/research/M4_2_REPORT.md) |
| **M4.4 交付报告** | 任务完成 / 失败 / 取消与等待授权的系统通知、通知栏直接「允许 / 拒绝」、点通知回到工作区页、「我的 → 通知」两个开关；App 286/286、release APK 71,933,294 字节、插件无改动、**真机未复测** | [`docs/research/M4_4_REPORT.md`](docs/research/M4_4_REPORT.md) |
| **M4.5 交付报告** | 更新下载进度条分帧（256 KiB / 30 ms）、回环网络 0.1s 下完的根因、288/288 测试、release APK 71,933,298 字节与限制 | [`docs/research/M4_5_REPORT.md`](docs/research/M4_5_REPORT.md) |
| **M4.6 交付报告** | AI 助手恢复「手机 / 电脑」两档并默认手机档（云端直连 + 顶栏接口胶囊）、IndexedStack 双档常驻、`CloudChatController` 与静态加载态；291/291 测试、release APK 72,015,286 字节、**真机未复测** | [`docs/research/M4_6_REPORT.md`](docs/research/M4_6_REPORT.md) |
| **M4.7 交付报告** | 手机档也能拍照/选相册/发文件：共享 `PendingAttachment`/`AttachmentPicker`/`AttachmentBar`，图片走 `image_url` base64、文本内联、二进制只发名字，气泡缩略图；301/301 测试、release APK 72,031,674 字节、**真机未复测** | [`docs/research/M4_7_REPORT.md`](docs/research/M4_7_REPORT.md) |
| **M4.9 交付报告** | 工作区图片 / PDF / Office 不再「无法预览」：`file/raw` 原始字节 + `FileOpenBridge`（content:// + ACTION_VIEW）+ `file/read`（pdf-parse / JSZip）；315/315 测试、插件 15/15、release APK 72,311,070 字节、**真机未复测** | [`docs/research/M4_9_REPORT.md`](docs/research/M4_9_REPORT.md) |
| **M4.10 交付报告** | 会话存档：DSH 只落 header 导致旧会话 invisible 的根因、zstd 逐帧解压、插件 `session-archive.json`（30 秒刷新）、手机端「已存档」只读直播与存档分组；321/321 测试、插件 15/15、release APK 72,343,942 字节、自检脚本扩到 14 项、**真机未复测** | [`docs/research/M4_10_REPORT.md`](docs/research/M4_10_REPORT.md) |
| M4.11 | 工作区页不再「看起来项目全丢了」（空目录也占卡片、存档分组不受状态筛选影响、插件挡掉测试临时目录） | [M4_11_REPORT.md](docs/research/M4_11_REPORT.md) |
| M4.12 | 对话正文按 Markdown 排版（标题 / 列表 / 引用 / 代码块带语言标签与复制 / 表格），对齐官方 App 观感；插件 0.2.20 修附件落回状态目录 | [M4_12_REPORT.md](docs/research/M4_12_REPORT.md) |
| M4.14 | 直播页首屏凑够 12 条对话（上限 600）、增量从尾部倒扫；授权接管窗口 10 分钟 / 超时 2 分钟并留日志；顶栏「待应答 N」与更准确的空态文案 | [M4_14_REPORT.md](docs/research/M4_14_REPORT.md) |
| M4.15 | 新建项目落点修对：不再按「授权根里有没有项目根」判断，无条件指名 `D:\Projects\项目`；插件侧本就支持显式 `parentDir` | [M4_15_REPORT.md](docs/research/M4_15_REPORT.md) |
| M4.16 | 手机看到的必须是对话：注入不再变用户气泡、推理不再当回复、打开就停在最新（列表 reverse + 存档按磁盘日志重读） | [M4_16_REPORT.md](docs/research/M4_16_REPORT.md) |
| M4.21 | 手机端也有「N 条排队消息」：插件 `/desktop/sessions/<id>/queue` + 面板改字 / 删除 / 单条插话 / 全部插话 | [M4_21_REPORT.md](docs/research/M4_21_REPORT.md) |
| M4.24 | 存档会话在原对话里继续：找到 `ArchivedSessionGate` 才是 `blocked` 的原因，插件先 `unarchiveSession()` 抬门再往同一 sessionId 发话，删掉「新开会话 + 摘要」 | [M4_24_REPORT.md](docs/research/M4_24_REPORT.md) |
| M4.25 | 账户余额进了「我的」：插件 0.2.29 代理 `deepseekAccount.getBalance()`（手机拿不到凭据），手机端新增 `AccountBalance` 与 `_BalanceCard`（充值/赠送分开、四种状态提示、可重读） | [M4_25_REPORT.md](docs/research/M4_25_REPORT.md) |
| M4.26 | 下载进度条不动：进度弹窗用 `StatefulBuilder` 却没调用它自己的 `setDialogState`，只有外层 tile 在刷；改为把弹窗 setState 存下来逐帧刷新，并用反证用例守住 | [M4_26_REPORT.md](docs/research/M4_26_REPORT.md) |
| M4.27 | 手机档多对话：每条对话存进 `cloud_conversations.json`，顶栏「历史」滑出侧栏，可新对话 / 切回 / 删除；标题取第一句、按更新时间倒序 | [M4_27_REPORT.md](docs/research/M4_27_REPORT.md) |
| M4.28 | 余额接口 404 的文案：从「请确认地址指向 M1 后端」改成「插件还没有账户余额接口（需要 0.2.29 以上），升级后完整退出并重开 DSH」 | [M4_28_REPORT.md](docs/research/M4_28_REPORT.md) |
| M4.29 | 下载卡片加「取消下载」「后台下载」：`UpdateCancelToken` + `UpdateCancelled`（取消时先关句柄再删 `.part`），下载搬进 `UpdateDownloadCenter`，关窗/离页都继续 | [M4_29_REPORT.md](docs/research/M4_29_REPORT.md) |
| M4.30 | 手机档对话自动落到工作区：`CloudChatIntent` 单向广播 + 工作区顶部「手机对话」（标题 / 条数 / 时间，最近 5 条，没连电脑也显示），点一条切到手机档并打开 | [M4_30_REPORT.md](docs/research/M4_30_REPORT.md) |
| M4.31 | 手机端也能回答电脑的「确认需求」：接管条件放宽到「手机还连着」，新增 `/api/v1/desktop/pending` 与工作区提示条 | [M4_31_REPORT.md](docs/research/M4_31_REPORT.md) |
| M4.32 | 余额卡片排版与数字：`formatMoneyAmount()` 两位小数（`0E-16` → `0.00`）、`primary` 优先非零 CNY、金额 `FittedBox` 限宽、标题不再被挤成一列 | [M4_32_REPORT.md](docs/research/M4_32_REPORT.md) |
| M4.33 | 余额卡片「去充值」：Host 无付款接口 → `UrlOpener` 跳官方充值页（Kotlin 侧只放行 http/https） | [M4_33_REPORT.md](docs/research/M4_33_REPORT.md) |
| M4.34 | 手机对话从工作区挪到抽屉：删掉工作区的「手机对话」组，抽屉「历史会话」上方新增「📱 手机对话」，点一条切到 AI 助手打开 | [M4_34_REPORT.md](docs/research/M4_34_REPORT.md) |
| M4.35 | 提问卡不再把整页卡死（限高 55% + 卡内滚动）+ 电脑等回答时发系统通知（notePendingQuestions，答完收回） | [M4_35_REPORT.md](docs/research/M4_35_REPORT.md) |
| M4.36 | 提问卡的「跳过 / 提交」钉在卡片底部，只有选项区在卡内滚动；卡片高度按内容自适应 | [M4_36_REPORT.md](docs/research/M4_36_REPORT.md) |
| M4.38 | 直播页「经常连接超时」：在途互斥 + 失败退避 + 首屏 20 秒 / idle 20 秒 | [`docs/research/M4_38_REPORT.md`](docs/research/M4_38_REPORT.md) |
| M4.42 | 新增「功能」页：抽屉四项，「插件管理」搬进去 | [`docs/research/M4_42_REPORT.md`](docs/research/M4_42_REPORT.md) |
| M4.52 | 手机没有 WPS 也能读 .docx 正文：文件页自己解 zip 抽文字，排版/图片不显示，抽不出时说明原因 | [`docs/research/M4_52_REPORT.md`](docs/research/M4_52_REPORT.md) |
| M4.51 | 工作区项目卡默认折叠，点项目头才摊开（摘要行给出会话数 / 进行中 / 最后活动） | [`docs/research/M4_51_REPORT.md`](docs/research/M4_51_REPORT.md) |
| M4.50 | 工作区「新会话」改成绑目录 + 跳去远程对话框（不再建谁都看不见的空会话） | [`docs/research/M4_50_REPORT.md`](docs/research/M4_50_REPORT.md) |
| M4.48 | 两档改名「本机对话 / 远程电脑」+ 首次切换说明（第二阶段收口） | [`docs/research/M4_48_REPORT.md`](docs/research/M4_48_REPORT.md) |
| M4.47 | 统一「会话」入口：远程电脑 / 本机直连一页看完 | [`docs/research/M4_47_REPORT.md`](docs/research/M4_47_REPORT.md) |
| M4.46 | 统一轮询协调器：可见才轮询、一次只跑一个、失败退避 | [`docs/research/M4_46_REPORT.md`](docs/research/M4_46_REPORT.md) |
| M4.45 | 新建的工作区注册进 DSH 的 `workspaceRegistry`；签名开关让老版本能覆盖升级 | [`docs/research/M4_45_REPORT.md`](docs/research/M4_45_REPORT.md) |
| M4.44 | 第一阶段六条安全改动：紧急停止三态、审批不误拒、Key/token 安全存储、地址策略、发布校验、analyze 解阻塞 | [`docs/research/M4_44_REPORT.md`](docs/research/M4_44_REPORT.md) |
| M4.43 | 按 `DSH_INSTRUCTIONS_2026-11-22` 改 8 条：死链、凭据、Range、gzip | [`docs/research/M4_43_REPORT.md`](docs/research/M4_43_REPORT.md) |
| M4.41 | 删掉「电脑」页：抽屉从四个入口变三个，紧急停止搬进「我的」 | [`docs/research/M4_41_REPORT.md`](docs/research/M4_41_REPORT.md) |
| M4.40 | 从四个角度审计（接口契约 / 存档容错 / 小屏大字号 / 运行期）：修掉坏时间戳排序与三处小屏溢出，插件侧记 6 条待修 | [`docs/research/M4_40_TEST_AUDIT.md`](docs/research/M4_40_TEST_AUDIT.md) |
| M4.39 | 手机档「往上滑」新建对话：方向纠正 + 底部加载圈跟手 + 中途滚动不算 | [`docs/research/M4_39_REPORT.md`](docs/research/M4_39_REPORT.md) |
| M4.37 | 手机档对话翻到顶再往下拽（超过 130px）松手就新建一条：越界量判定 + 「松手开始新对话」提示，短对话也能拽 | [M4_37_REPORT.md](docs/research/M4_37_REPORT.md) |
| M4.23 | 电脑端「确认需求」的提问卡手机上也能回答：插件接管 `user-questions/request` waterfall（原先只接了 `approval/request`）+ `/desktop/sessions/<id>/questions/<id>`；手机端渲染选项卡片，5 分钟无人应答按跳过放行 | [M4_23_REPORT.md](docs/research/M4_23_REPORT.md) |
| M4.22 | 输入框里打出来的字不见了：主题把 `textTheme` 整体替换导致 `bodyLarge` 无颜色 → `TextField` 正文透明；改成 merge 到完整 Typography 并补 `bodyLarge`/`labelMedium` 颜色 | [M4_22_REPORT.md](docs/research/M4_22_REPORT.md) |
| M4.20 | 开机后工作区变空：Agent 侧可刷新授权目录（`M1_WORKSPACE_REFRESH_MS`）+ 只给 Agent 的 `/api/v1/agent/workspaces` + `normalizeRoots()` 去重（18 → 10 条） | [M4_20_REPORT.md](docs/research/M4_20_REPORT.md) |
| M4.19 | 存档会话也能继续聊：新开一条会话 + 最近 12 条对话摘要当开场（唤醒旧会话会被 blocked、fork 长会话会超窗，两条死路都留了证据） | [M4_19_REPORT.md](docs/research/M4_19_REPORT.md) |
| M4.18 | 插件市场与电脑端同步：目录来自 Host `pluginManager.listBundles()`（42 个插件包），本地搜索 + 官方标记 + 按 spec 安装 | [M4_18_REPORT.md](docs/research/M4_18_REPORT.md) |
| M4.17 | 桌面直播排版对齐官方 App：回复不套卡片、工具行写「已完成 · N 次工具调用」、顶部胶囊写「本机 · 目录名」 | [M4_17_REPORT.md](docs/research/M4_17_REPORT.md) |
| M4.13 | 工作区按项目分组可折叠、空目录标「空项目」、新建项目固定落 D:\Projects\项目；插件加 parentDir 支持 | [M4_13_REPORT.md](docs/research/M4_13_REPORT.md) |
| **项目构思方案（Word）** | 可直接阅读/打印的正式稿，含封面、目录、架构图与界面图（34 页） | [`DeepSeek Remote AI 项目构思方案 v0.2.docx`](DeepSeek%20Remote%20AI%20项目构思方案%20v0.2.docx) |
| **项目构思方案（Markdown）** | 与 Word 同源，便于评审与 diff | [`docs/concept/项目构思方案_v0.2.md`](docs/concept/项目构思方案_v0.2.md) |
| 总体架构图 | 手机 / 云端 / Remote Agent / Harness 四边界 + 信任模型 | [`docs/concept/architecture.png`](docs/concept/architecture.png) |
| 手机端界面概念图 | AI 助手 / 任务中心 / 高风险授权确认三屏 | [`docs/concept/mobile_ui.png`](docs/concept/mobile_ui.png) |

## M1-α 已交付：手机 → 公网 → 后端 → Agent → Harness（真实链路）

```
手机 App ── HTTPS/WSS ──> Java 后端(公网) <── WSS 出站 ── 电脑 Agent ── stdio JSON-RPC ──> dsh --profile acp
```

| 验证项 | 结果 | 证据 |
|---|---|---|
| 后端 + Agent 本机 E2E | **6/6**（设备在线、建会话、真实 prompt、取消、审批批准、审批拒绝） | `docs/research/evidence/m1/e2e-2026-10-31T05-20-37-627Z.json` |
| **公网隧道 E2E** | **6/6**（同上，经 Cloudflare 隧道） | `.../e2e-2026-10-31T05-21-04-890Z.json` |
| 手机真链路人机验证 | 连接 → 发指令 → 真实回复 → 审批弹层 → 点「允许一次」→ 电脑上文件真实生成 | `docs/mobile/screenshots/09..13_live_*.png` |
| Agent relay 自测 | **24/24**（假后端）+ **25/25**（真 ACP） | `agent/tools/relay-selftest.ts` |
| 手机 App 测试 | **68/68** 全绿 | `cd app; flutter test` |

- 契约：[`docs/design/M1_PROTOCOL.md`](docs/design/M1_PROTOCOL.md)（配对码 `824613`、信封、事件、错误码）
- 后端：`backend/`（Spring Boot 3.5.16 + Java 21，Gradle 8.14.3，内存态）
- Agent：`agent/src/relay/` + `agent/scripts/serve.ts`（Node 24 直接跑 .ts，零新增依赖）
- 手机：`app/lib/services/` + `live_store.dart` + `connect_screen.dart`（真实/演示双模式）
- 启动三件套与手机连接步骤：见 [M1_E2E_REPORT.md](docs/research/M1_E2E_REPORT.md) §4
- **一键启动 / 关闭**（推荐）：
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-up.ps1 -WithEmulator`（后端 + 隧道 + Agent + 模拟器，自动打印公网地址与配对码）
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-down.ps1`（全部关闭）
  - 已实测：一键拉起后经隧道 `m1-client` 4/4 PASS；状态写 `.m1-state\state.json`，日志 `.m1-state\logs\`
  - M1.1 起 `m1-up.ps1` 会**自动拉起 PostgreSQL（5433）**；`m1-down.ps1 -StopDb` 可连数据库一起停

## M1.1 已交付：PostgreSQL 持久化 + 历史 + 真实任务页（2026-11-02）

```
手机「历史会话 / 任务中心」── R E S T ──> Java 后端 ──> PostgreSQL 16.10（持久化）
                                        Agent 事件 ──> PersistenceService（异步落库，失败只 WARN）
```

| 验证项 | 结果 | 证据 |
|---|---|---|
| 重启后端不丢历史（P-1） | 杀掉并重启后端 → 8 个会话 / 61 条消息 / 15 个任务 / 6 条审批审计仍在，REST 与 psql 一致 | 本报告 §5.3 |
| 端到端回归 | `m1-client` **6/6 PASS ×3**（改造前、重启后、Lead 回归） | `docs/research/evidence/m1/e2e-2026-11-02T05-*.json` |
| 手机端 | `flutter test` **95/95**（原 68 + M1.1 新增 27），APK 构建成功（158.1 MB） | `cd app; flutter test` |
| 数据库 | Flyway v1/v2 success；messages 无 thinking 行；audit approved×3 + denied×3 | `psql -h 127.0.0.1 -p 5433 -U postgres -d deepseek_remote` |

- 契约：[`docs/design/M1_1_DELTA.md`](docs/design/M1_1_DELTA.md)；报告：[`docs/research/M1_1_REPORT.md`](docs/research/M1_1_REPORT.md)
- 后端：`backend/src/main/java/com/deepseek/remote/{persistence,api/HistoryController}.java` + `db/migration/V1__core.sql`、`V2__seed.sql`
- 手机端：`app/lib/services/history_api.dart`、`live_store.dart`（历史/seq 去重/增量补齐）、`widgets/timeline.dart`、`chat_items.dart`（结构化工具输出）
- 已知限制：token 仍在内存（重启后端需重连/重 pair）、app deviceId 仍 `dev_N`、task events 由消息派生、health 版本号未更新、模拟器环境不稳导致 M1.1 UI 截图未补拍

| 验证层 | 结果 | 命令 |
|---|---|---|
| 单元测试 | **36/36**（158ms） | `npm run test` |
| 合同测试（真实 Harness） | **9/9**（28.3s）：initialize / 能力矩阵 / session / 真实 turn / 多轮 / 取消 / 审批 allow / 审批 deny / resume | `npm run test:contract` |
| 端到端冒烟 | **5/5**（20s）：连接 → 真执行建文件 → 审批写入 → 执行中取消 → 断线续跑 | `npm run e2e` |

- 报告：[docs/research/M0_FEASIBILITY.md](docs/research/M0_FEASIBILITY.md)（含新发现：审批触发条件、Windows 工作区 ACL 坑、取消机制、能力边界、M1 清单）
- 代码：`agent/src/harness/acp/`（launcher / jsonrpc / mapper / acp-adapter）+ `agent/tests/` + `agent/scripts/e2e-smoke.ts`
- 证据：`agent/evidence/contract-*.jsonl`、`agent/evidence/e2e-*.json`

## M2-α 已交付：锁屏审批通知 + 后台保活 + token 持久化（2026-11-02）

| 验证项 | 结果 | 证据 |
|---|---|---|
| 重启后端 token 仍有效（M2-A4） | pair → 杀后端重启 → **旧 token `GET /conversations` 仍 200**；Agent 全 Python/Node 进程未重启即恢复 `agentOnline=true` | [`docs/research/evidence/m2/m2-a4-lead-check.json`](docs/research/evidence/m2/m2-a4-lead-check.json) |
| 审批通知 / 后台保活 / 自动重配对 | Kotlin 原生通知桥 + 前台服务 + Dart 自动重配对；`flutter test` **111/111**（M2 新增 16） | `app/test/notification_flow_test.dart`、`auto_repair_test.dart` |
| 构建回归 | `flutter build apk --debug` 成功（158.1 MB）；`gradle build -x test` 成功（`backend-0.1.1-m2.jar`）；`m1-client` **6/6 PASS** | `docs/research/evidence/m1/e2e-2026-11-02T06-42-22-475Z.json` |
| 未实测 | 真机通知点击/前台服务存活（本机模拟器被环境回收，`adb devices` 无设备）→ 按报告 §7 步骤用真机补一次即可闭环 | M2_REPORT §6 |

- 契约：[`docs/design/M2_DELTA.md`](docs/design/M2_DELTA.md)（含 `auth_tokens` 表、两个通知渠道、M2-A1..A6 验收）
- 后端：`backend/src/main/java/com/deepseek/remote/auth/TokenStore.java`（库优先 + 1s 缓存）+ `db/migration/V3__auth_tokens.sql`；health 版本 **0.1.1-m2**
- 手机端：`app/android/.../NotificationHelper.kt`、`NotificationBridge.kt`、`ConnectionService.kt`；`app/lib/services/notification_gateway.dart`；`live_store.dart`（后台通知/自动重配对）、`relay_client.dart`（4401 流）
- 已知限制：真机通知未实测、不做厂商离线推送、通知内不能直接批准（安全要求）、审批等待仍占该会话执行槽

## M2.1 已交付：可补偿事件 + 断线演练 + 执行中排队（2026-11-02）

```
每条手机可见事件 ──> backend 统一分配会话级 seq ──> 转发手机 + 落 task_events（PostgreSQL）
手机重连 ── afterSeq=lastSeq ──> GET /conversations/{id}/events ──> 补齐缺失事件（含终态/审批）
```

| 验证项 | 结果 | 证据 |
|---|---|---|
| **断线 60 秒演练（M2.1-A3）** | **PASS**：断流前 2 条（lastSeq=3）→ 断流 60s → 重连补回 **7 条 seq 4..10**，合并后 **9/9 seq 唯一**，任务终态来自补拉 | [`docs/research/evidence/m2/catchup-2026-11-02T07-44-27-621Z.json`](docs/research/evidence/m2/catchup-2026-11-02T07-44-27-621Z.json) |
| 事件独立落库（M2.1-A1） | Flyway v1–v4 success；非 backfill 事件每会话 `max(seq)-min(seq)+1 = count`（no_hole_bad=0）；`/tasks/{id}` events 与 DB 行数一致 | 本报告 §5、psql 断言 |
| 增量补拉端点（M2.1-A2） | `afterSeq=0&limit=50` → 50 条 seq 1..50、nextSeq=51；`afterSeq=-1`→400、`limit=501`→400、未知会话→404；backfill 不返回 | REST 复核 |
| 执行中排队（M2.1-A4） | `flutter test` **124/124**（M2.1 新增 13）；busy 时进深度 1 队列、可移除、终态自动发 | `app/test/catchup_test.dart`、`queued_prompt_test.dart` |
| M1 回归 | `m1-client` **6/6 PASS** | [`evidence/m2/m1-client-6of6-2026-11-02T07-45-57-297Z.json`](docs/research/evidence/m2/m1-client-6of6-2026-11-02T07-45-57-297Z.json) |
| 库终态 | conversations=18、messages=190、tasks=49、task_events=337（backfill 99）、audit_logs=18；thinking 只落事件表 | psql |

- 契约：[`docs/design/M2_1_DELTA.md`](docs/design/M2_1_DELTA.md)；报告：[`docs/research/M2_1_REPORT.md`](docs/research/M2_1_REPORT.md)
- 后端：`db/migration/V4__task_events.sql`、`ws/RelayHub.java`（转发前分配 seq）、`persistence/PersistenceService.java`、`api/HistoryController.java`（`/conversations/{id}/events`）、`application.properties`（`m1.events.*`）
- 手机端：`app/lib/data/live_store.dart`（lastSeq / `_applyFrame` seq 去重 / `catchUpEvents()` / 排队队列）、`services/history_api.dart`、`widgets/chat_items.dart`、`screens/assistant_screen.dart`
- 演练工具：`node tools\m2-catchup-test.ts --base http://127.0.0.1:8080 --drop-ms 60000`
- 已知限制：health 版本号仍 `0.1.1-m2`（数据面升级未 bump）、backfill 不回传、排队仅内存、真机 UI 未截图

## M2.2 已交付：手机端手感对齐 A 档（2026-11-03）

```
一轮任务结束 ──> 工具/思考自动收成「已完成 N 步 · 用时 Xs」（点击展开，最终回复不动）
排队消息     ──> 「立即发送」＝ task.cancel → 等终态/3s 超时 → 把排队指令作为新 prompt 发出
「我的→外观」──> 6 套深色主题（深海蓝/墨黑/暖沙/森林/樱粉/紫夜），SharedPreferences 持久化
对话分享     ──> 最近一轮 QA 渲染 1080 宽 PNG（脱敏）→ 系统分享面板
```

| 验证项 | 结果 | 证据 |
|---|---|---|
| A1 完成自动折叠 | 只折叠终态且 toolCount>0 的连续 thinking/toolCall/toolResult；摘要含步数/耗时/终态配色；点击展开收合；执行中与最终回复不折叠 | `app/lib/widgets/turn_fold.dart`、`ux_m2_2_test.dart` |
| A2 排队「立即发送」 | 先 `task.cancel` 再发排队指令；`interruptTimeout=3s` 兜底；`_interruptInFlight` 防重复；气泡按钮「立即发送 → 正在打断…」 | `live_store.dart`、`ux_m2_2_test.dart` |
| A3 6 套主题 | `AppPalette` + `ThemeExtension` + `buildAppTheme(id)`；`deepseek_remote/settings` + SharedPreferences 持久化，重启保留 | `theme_controller.dart`、`SettingsBridge.kt` |
| A4 分享卡 | 最近一轮问答 → 1080 宽竖版 PNG（脱敏）→ 自实现 `ShareFileProvider`（零 androidx）+ `ACTION_SEND`；空对话置灰 | `share_card.dart`、`ShareBridge.kt`、`ShareFileProvider.kt` |
| A5 长按菜单 | 复制全文 / 重新发送（填入输入框）/ 复制工具输出 | `chat_items.dart`、`ux_m2_2_test.dart` |
| A6 测试与构建 | `flutter test` **143/143**（M2.2 新增 19，既有 124 零回归）；debug APK **150.8 MB**（150,797,767 字节），`aapt dump badging` 校验 `versionName=0.1.3-m2.2`、`versionCode=4` | `cd app; flutter test && flutter build apk --debug` |

- 契约：[`docs/design/M2_2_DELTA.md`](docs/design/M2_2_DELTA.md)；报告：[`docs/research/M2_2_REPORT.md`](docs/research/M2_2_REPORT.md)
- 已知限制：真机未实测（分享面板/主题观感/折叠动画）、仅深色 6 套、`TaskStatus` 等 const 枚举色未全量 token 化、「立即发送」本质是打断 + 改说（ACP 无 turn 内插话）

## M2.3 已交付：视觉重构（冷白极简 + 跟随系统，2026-11-03）

用户反馈「UI 太难看」后，按用户选定的方向（**A 的配色 + B 的排版、浅色为主、跟随系统自动切深色**）把六个页面全部重做：

```
浅色（默认）  #F6F7F9 底 + #FFFFFF 卡片 + #2563EB 主色 + #0F172A 正文
深色（跟随）  #0B1220 底 + #121A2A 卡片 + #5B8DEF 主色
形状          卡片 20 圆角 / 气泡 22·22·8 / 输入与按钮 16 / 代码块 12 / 胶囊全圆
版式          页边距 20、标题 22/w700、正文 14.2/1.6、4pt 网格、极淡两层阴影
导航          白底 94% + 1px 顶线 + 选中圆点（不再用 Material NavigationBar）
```

| 验证项 | 结果 | 证据 |
|---|---|---|
| A1 浅色默认 | `buildAppTheme(Brightness.light)` 为默认；六页与组件全量使用 `context.appPalette` token（旧 `AppColors` 只剩 TaskStatus 语义色） | `app/lib/theme/app_theme.dart`、grep |
| A2 跟随系统 + 三选 | `AppThemeMode(system/light/dark)`；`我的→外观` 三选；`storageKey=app_theme_mode` 经 Kotlin `SettingsBridge` 持久化 | `theme_controller.dart`、`SettingsBridge.kt`、`theme_m2_3_test.dart` |
| A3 六页重做 | 助手（用户气泡/助手竖线/折叠工具卡/胶囊输入）、连接（6 格配对码）、任务（统计卡/筛选胶囊）、电脑（权限列表/紧急停止）、项目（工作区卡）、我的（外观三选/关于版本） | `app/lib/screens/*.dart`、`widgets/*.dart` |
| A4 深色版 | 同一 token 体系自动翻转；对比度单测：正文 ≥7:1、次要文本 ≥4.5:1 | `theme_m2_3_test.dart` |
| A5 测试 | `flutter test` **154/154**（既有 143 零回归 + M2.3 新增 11） | `cd app; flutter test` |
| A6 构建与版本 | debug APK **150,808,223 字节**（143.8 MiB），`aapt dump badging` → **`versionName='0.1.4-m2.3' versionCode='5'`**，SHA256 `752016BE…6CF28100` | `flutter build apk --debug`、`aapt` |

- 契约：[`docs/design/M2_3_UI_DELTA.md`](docs/design/M2_3_UI_DELTA.md)；报告：[`docs/research/M2_3_REPORT.md`](docs/research/M2_3_REPORT.md)
- 效果图（选型来源）：[`docs/design/mockups/ui_a.png`](docs/design/mockups/ui_a.png)（配色）、[`docs/design/mockups/ui_b.png`](docs/design/mockups/ui_b.png)（排版）
- 已知限制：本机无真机/可用模拟器，浅/深色**实机截图未补拍**；深色对比度为 token 计算值；`flutter analyze` 仍未跑（中文路径崩溃）；装到手机后欢迎逐页截图反馈继续微调。

## M2.5 已交付：应用内在线更新（2026-11-03）

用户问「能不能在线更新」→ **能，但不是静默更新**（Android 上非系统应用最后一步必须由系统安装器弹窗确认）：

- **手机端流程**：我的 → 关于 → **检查更新** → 有新版本时弹窗（版本号 / 大小 MB / 更新说明）→ **立即更新** → 进度条下载到 `cacheDir/updates/` → 自动调起系统安装器 → 用户点「安装」。没有「安装未知应用」权限时先引导去设置。
- **后端**：新增 `GET /api/v1/app/version`（无需 Bearer，返回 versionCode/versionName/size/sha256/notes/url/publishedAt）与 `GET|HEAD /api/v1/app/apk`（流式下载、`Content-Length`、`application/vnd.android.package-archive`）；固定读 `dist/DeepSeek-Remote-latest.apk`，**换包即生效**（sha256 按文件 mtime+size 自动重算）。
- **首次例外**：手机现在装的是 0.1.5（没有更新模块），需要**手动装一次 0.1.6**；装完之后每次发版只换 `dist/DeepSeek-Remote-latest.apk` + 改 `app.update.version-code/version-name`，手机端点一次「检查更新」即可。

| 验证项 | 结果 | 证据 |
|---|---|---|
| A1 检查更新 | `update_service.dart` `versionCode >` 当前才返回；404/网络/JSON 异常一律「已是最新/不打扰」 | `update_service_test.dart` 12 项 |
| A2 下载 APK | 流式写 `.part` → 按 size 校验 → rename 成 `app-update.apk`，进度回调驱动 UI | 同上 |
| A3 调起安装器 | `UpdateBridge` content:// + `ACTION_VIEW` + `FLAG_GRANT_READ_URI_PERMISSION`；无权限先跳设置 | `UpdateBridge.kt`、`ShareFileProvider.kt` |
| A4 UI 入口 | `update_check_tile_test.dart` 3 项：未连接不检查 / 有新版本弹窗 / 已最新提示 | `app/test/` |
| A5 后端接口 | 公网 `GET /version` 200 JSON；`HEAD /apk` 200、`150,782,707` 字节、package-archive | 本地 + 隧道实测（报告 §5） |
| A6 测试/构建 | `flutter test` **178/178**；`versionName='0.1.6-m2.5' versionCode='7'`；APK 150,782,707 字节 | `cd app; flutter test`、`aapt` |

- 契约：[`docs/design/M2_5_UPDATE_DELTA.md`](docs/design/M2_5_UPDATE_DELTA.md)；报告：[`docs/research/M2_5_REPORT.md`](docs/research/M2_5_REPORT.md)
- 已知限制：不能静默安装；首次需手动装 0.1.6；下载后仅按 size 校验（sha256 已随接口下发、逐块校验待补）；debug 签名需前后一致；本机无真机，安装器跳转只做了编译+单测级验证（需真机点一次）。

## M2.6 已交付：项目同步（手机浏览电脑项目 + 在项目里发指令，2026-11-04）

用户「可以同步电脑此时做的项目，并且可以在手机上操作」→ 手机现在能直接看电脑上这个项目的**真实磁盘目录**，并在任意目录发指令让 Harness 在该目录执行：

- **项目页**：显示 Agent 的真实工作区根（`M1_WORKSPACE_ROOT`，本次切到 `<项目根>`）；点「浏览」进入目录树（面包屑/返回上级/下拉刷新/错误重试），点文件进入**只读代码预览**（等宽、行号开关、横向滚动、复制、大小 + sha256 前 8 位、截断提示）。
- **在此目录发指令**：目录页底部按钮 → 回到 AI 助手（输入区上方显示工作区胶囊）→ 新会话自动带 `workspacePath`，Harness 就在该目录里干活。
- **协议**：新增 WSS `workspace.list` / `file.read` 请求-响应（`requestId` 配对，结果只广播，**不分配 seq、不写 task_events、不进消息流**）；错误码 `PATH_NOT_ALLOWED/DIR_NOT_FOUND/FILE_NOT_FOUND/IS_A_DIRECTORY/BINARY_FILE/TOO_LARGE/INTERNAL`；目录 500 条上限、预览默认 256 KiB、硬上限 1 MiB、忽略 `.git/node_modules/.dart_tool/build/dist/...`。
- **实现位置**：Agent `agent/src/relay/workspace-fs.ts` + `relay-agent.ts`；后端 `RelayHub.java` 两条白名单；手机 `workspace_models.dart`、`live_store.dart`、`projects_screen.dart`、`project_browser_screen.dart`、`file_viewer_screen.dart`。

| 验证项 | 结果 | 证据 |
|---|---|---|
| A1 项目列表 | `device.status.workspaceRoots=["<项目根>"]`、`capabilities.workspaceList=true` | `docs/research/evidence/m2/project-sync-2026-11-04T01-51-07-111Z.json` |
| A2 目录浏览 | 根目录 19 条、目录在前、忽略项生效；子目录路径带前缀 | 同上（14/14 PASS） |
| A3 文件预览 | `README.md` 40,020 B + sha256；缺失 → `FILE_NOT_FOUND`；`../..` → `PATH_NOT_ALLOWED` | 同上 |
| A4 项目内发指令 | `conversation.create` 绑定 `…\docs\research`，Harness 输出 `当前工作目录：<项目根>\docs\research`，`state=completed` | 同上 |
| A5 回归 | M1 E2E **6/6 PASS**（后端重启后）；Agent 单测 **9/9** | `evidence/m1/e2e-2026-11-04T02-19-12-109Z.json` |
| A6 测试/构建 | `flutter test` **190/190**；`versionName='0.1.7-m2.6' versionCode='8'`；APK **150,820,399 字节** | `cd app; flutter test`、`aapt` |

- 契约：[`docs/design/M2_6_PROJECT_SYNC_DELTA.md`](docs/design/M2_6_PROJECT_SYNC_DELTA.md)；报告：[`docs/research/M2_6_REPORT.md`](docs/research/M2_6_REPORT.md)；验证脚本：`tools/verify-project-sync.ts`
- 已知限制：**只读**（写文件仍走 AI 指令 + 审批）；**不镜像桌面 GUI 会话**（同目录同一份文件，但不是桌面那个对话进程）；二进制/超大不可预览；无真机/无模拟器，页面验证为单测 + 构建级。
- 应用内更新：后端 `app.update.version-code=8`、`dist\DeepSeek-Remote-latest.apk` 已换 0.1.7 包，手机「我的 → 关于 → 检查更新」可直接升到 0.1.7-m2.6。

## M2.4 已交付：删除演示数据 + 界面减法（2026-11-03）

用户反馈「太繁琐了，把演示数据删了，简洁一点」后的返工：

- **演示数据清零**：删除 `app/lib/data/demo_store.dart`、`DemoDevice/WorkspaceEntry/AuditEntry`、`DemoBadge/StoreScope/ModeBadge`；`app.dart` 只保留 `LiveScope`+`ThemeScope`；`grep -ri "演示" app/lib` **= 0**。
- **未连接 = 六页统一空态**：新增 `EmptyState`（图标 + 标题 + 一句说明 + 「连接电脑」按钮），点击进入连接页；不再显示任何假设备/假会话/假任务/假工作区/假审计/假配对码。
- **已连接 = 只留真实内容**：助手页顶部只剩一行状态条（圆点 + 设备名 + 已连接 + 会话切换 + 分享），下面直接是消息流；任务页删统计三卡与副标题；电脑页合并为设备卡 + 权限摘要弹层 + 紧急停止；项目页只读真实 `workspaceRoots`；我的页删审计、演示账号与退出登录；连接页步骤压成一行小字。

| 验证项 | 结果 | 证据 |
|---|---|---|
| A1 演示清零 | `grep -ri "演示" app/lib` = 0；demo 相关类无引用 | `app/lib/` |
| A2 空态 | `empty_state_test.dart` 9 项 + 重写 `widget_test.dart` 4 项覆盖五页空态/连接入口 | `app/test/` |
| A3 连接链路不变 | `node tools/m1-client.ts` → **6/6 PASS** | `evidence/m1/e2e-2026-11-03T09-24-31-458Z.json` |
| A4 真实功能保留 | 对话/历史/任务/审批/取消/折叠/主题/分享/紧急停止路径保留，既有 154 项单测零回归 | `app/test/` |
| A5 测试 | `flutter test` **164/164** | `cd app; flutter test` |
| A6 版本/构建 | `versionName='0.1.5-m2.4' versionCode='6'`；APK **150,758,731 字节** | `aapt dump badging`、`flutter build apk --debug` |

- 契约：[`docs/design/M2_4_SIMPLIFY_DELTA.md`](docs/design/M2_4_SIMPLIFY_DELTA.md)；报告：[`docs/research/M2_4_REPORT.md`](docs/research/M2_4_REPORT.md)
- 已知限制：本机无真机/可用模拟器，**空态与已连接界面截图待补拍**；未连接时无法体验页面功能（用户明确要求）；项目页文件浏览属后续 B 档。

## 手机 App（`app/`，Flutter）

| 项 | 说明 |
|---|---|
| 形态 | Android debug APK；最新版在项目根目录：`DeepSeek Remote AI 手机端 v0.1.7-m2.6.apk` |
| 模式 | M2.4 起**只有真实模式**：连后端后五页走真实链路（发指令、实时输出、审批弹层、取消、历史、任务、紧急停止）；未连接时五页为连接空态，点击进入「真实连接」页配对 |
| 内容 | 五 Tab（AI 助手 / 任务中心 / 电脑控制 / 项目管理 / 个人中心）+ 高风险授权弹层（10 分钟倒计时）+ 拖动紧急停止；M1.1 起支持历史会话、真实任务列表/详情、结构化工具输出；M2 起支持锁屏审批通知、前台服务保活、自动重配对；M2.2 起支持完成轮折叠、排队立即发送、分享卡、长按菜单；M2.3 起为浅色默认 + 跟随系统深色 + 三选外观；M2.4 起删除全部演示数据、未连接统一空态、六页减法；M2.5 起「我的 → 关于」支持**应用内检查更新/下载/安装**；M2.6 起「项目」页支持**浏览电脑项目目录、只读预览文件、在指定目录发指令** |
| 截图 | [docs/mobile/screenshots/](docs/mobile/screenshots/)：01–08 演示版（历史）；**09–13 真实链路**（M1.1/M2/M2.3/M2.4/M2.5 UI 截图因模拟器环境不稳未补拍，见各报告 §7） |
| 文档 | [docs/mobile/README.md](docs/mobile/README.md)（功能地图、连接步骤、构建命令、限制、M2.4 无演示数据说明、M2.5 更新流程） |
| 验证 | `flutter test` **190/190 通过**（M1 68 + M1.1 27 + M2 16 + M2.1 13 + M2.2 19 + M2.3 11 + M2.4 10 + M2.5 15 + M2.6 12，部分用例替换后总数 190）；debug APK 150,820,399 字节，安装器/设置里显示版本 **0.1.7-m2.6**（versionCode 8） |
| 下一步 | 真机验收 M2.6（项目 → 浏览 → 打开文件 → 在此目录发指令）；应用内更新到 0.1.7；M3：审批等待与执行槽解耦、远程桌面 L1、正式签名与发布脚本 |

## 详细设计（5 份分册）

| 分册 | 内容 |
|---|---|
| [PROTOCOL.md](docs/design/PROTOCOL.md) | REST 17 接口 + 11 个实现必需端点、WSS 三端握手、信封/事件/seq 补偿、配对/取消/断网时序图 |
| [DATA_MODEL.md](docs/design/DATA_MODEL.md) | 8 核心表 + 8 支撑表、PostgreSQL DDL、分区、枚举、写放大估算 |
| [REMOTE_AGENT.md](docs/design/REMOTE_AGENT.md) | 选型 ADR、六层架构、HarnessAdapter（ACP 为主）、执行引擎、审批、DPAPI/六级/急停 |
| [MOBILE_UI.md](docs/design/MOBILE_UI.md) | 五 Tab、任务状态机、组件与目录、Riverpod 选型 |
| [MVP_AND_ROADMAP.md](docs/design/MVP_AND_ROADMAP.md) | M0–M5 切片、验收标准、人日、依赖、风险 |

## 调研与证据（可复核）

| 报告 | 内容 |
|---|---|
| [HARNESS_INTERFACES.md](docs/research/HARNESS_INTERFACES.md) | 7 项调查 + A/B/C 三路线评级：**A 路线 ACP ★★★★★（默认）**、B 插件桥 ★★★☆（仅 live 会话）、C 兜底 ★★☆ |
| [ENVIRONMENT_REPORT.md](docs/research/ENVIRONMENT_REPORT.md) | 428 行实机扫描：版本表、24 项结论、P0–P3 缺失清单、风险 R1–R13 |
| [M0_FEASIBILITY.md](docs/research/M0_FEASIBILITY.md) | **M0 交付报告**：ACP 内核实现、单测/合同/E2E 结果、实测新发现、遗留问题、M1 清单 |
| [M1_E2E_REPORT.md](docs/research/M1_E2E_REPORT.md) | **M1 交付报告**：契约、后端/Agent/App 交付、本机+公网 E2E 矩阵、手机真实截图、启动手册、已知限制 |
| [M1_1_REPORT.md](docs/research/M1_1_REPORT.md) | **M1.1 交付报告**：PostgreSQL 持久化、历史 REST、真实任务页、重启不丢历史（P-1）证据、遗留清单 |
| [M2_REPORT.md](docs/research/M2_REPORT.md) | **M2-α 交付报告**：auth_tokens 持久化与 M2-A4 实测、锁屏审批通知/前台服务/自动重配对、真机补测步骤、遗留 |
| [REVIEW_REPORT.md](docs/review/REVIEW_REPORT.md) | 独立审核 604 行：108 条需求追溯、V-1..V-9 真实性核验、3 P0 / 12 P1 / 18 P2、冻结前 checklist |

## 关键实测结论（TL;DR）

1. **能接上**：`dsh --profile acp` 子进程 + NDJSON JSON-RPC over stdio，`initialize` 返回 `protocolVersion: 1`；对话、流式事件、工具调用、取消、审批（`session/request_permission`：allow-once 执行、reject-once 解释后正常结束）、`session/resume` 全部实测闭环。
2. **没有外部 Remote API**：`127.0.0.1:62492` 的 `/api` 是官方 Web 前端内部 RPC（launch-token + cookie + Host 栅栏、仅 loopback、端口随机），**不可依赖**；Remote Agent 必须同机部署、出站连接。
3. **`dsh headless` 不够用**：有 `--json` NDJSON 固定事件，但**无取消、无审批通道**，只适合一次性批任务。
4. **能力边界要诚实**：ACP 事件是**提交点粒度**（非 token 级）；**无文件读写方法**（需 Agent 本地实现）；**无暂停原语**（明确显示不支持）；同会话并发 prompt 返回 `-32602`。
5. **环境基本齐备**：Node 24.18 / JDK 21 + Gradle 8.14 / Android SDK + AVD / VS BuildTools + NSIS / ffmpeg 6.1.1 均在；Flutter 3.47.9 已装到 `C:\Users\user\dsh-tools\flutter`（本机可直接打 APK）；另缺 PostgreSQL 与云资源。
6. **远程桌面必须 H.264**：1280 宽 10fps 实测 H.264≈3.0Mbps、NVENC≈1.76Mbps、**MJPEG≈13.3Mbps（公网不可用）**。
7. **不需要买云服务器也能公网用**：Agent 永远出站 → 只需后端有公网地址；Cloudflare Quick Tunnel 实测打通手机 4G 场景（本报告 §3.1），地址可配，之后迁云只改一个 URL。
8. **手机点一下，电脑真的动**：手机审批弹层点「允许一次」→ 电脑上真实生成文件（`m1-phone-ok.txt` = `phone-ok`），审批证据里 `decidedBy=phone`。
9. **重启不丢历史**：会话/消息/任务/审计落 PostgreSQL 16.10，杀掉后端重启后重新 pair 仍是 8 个会话、61 条消息、15 个任务；REST `messages?afterSeq=` 增量返回正常（M1.1 报告 §5.3）。
10. **任务页不再是假数据**：任务中心/任务详情时间线/项目工作区都来自后端真实数据；工具输出改成"命令 + 状态 + 耗时 + 可折叠输出"的结构化分块。
11. **重启后端不用重新配对**：token 的 sha256 落 `auth_tokens` 表，杀后端重启后旧 token 请求仍 200，Agent 自动重连不再需要人工介入（M2-A4，证据 `evidence/m2/`）。
12. **锁屏也能收到审批**：Android 前台服务保活 + 高优先级本地通知，审批到达时即使 App 在后台/锁屏也会提醒，点通知直达审批弹层（代码+单测就绪，真机待补测）。
13. **断线不丢事件**：每条手机可见事件由后端统一分配会话级 seq 并落 `task_events`；断流 60 秒后重连 `afterSeq` 补拉，7 条事件全补齐、seq 9/9 唯一、任务终态由补拉恢复（M2.1-A3 实测）。
14. **执行中也能继续打字**：任务运行/等待审批时发送的消息进深度 1 本地队列，任务终态后自动发出，不再被 `SESSION_BUSY` 顶回（M2.1-A4）。
15. **一轮结束自动收拢**：完成轮的工具调用与思考自动折成「已完成 N 步 · 用时 Xs」一行，点击展开；最终回复始终可见（M2.2-A1）。
16. **排队消息可立即发送**：点排队气泡上的「立即发送」，先取消当前任务再把你这条指令发出（3s 超时兜底），不用等任务自己结束；另有 6 套主题、分享卡与长按菜单（M2.2-A2/A3/A4/A5，143/143 测试）。
17. **界面重做了一遍**：用户反馈「UI 太难看」→ 按选定方向（冷白配色 + 暖调排版）六页全量重做，浅色默认、跟随系统切深色，另可手动三选；154/154 测试、`versionName=0.1.4-m2.3`（M2.3）。
18. **安装器版本号对上了**：`versionName` 由 `pubspec`/`build.gradle.kts` 统一写入（M2.4 为 `0.1.5-m2.4`、`versionCode=6`），不再出现「文件名新、设置里还是 0.1.0」的问题。
19. **演示数据已删干净**：用户反馈「太繁琐」→ `demo_store.dart` 与全部假设备/假会话/假任务/假工作区/假审计/假配对码/演示徽标删除，`grep -ri "演示" app/lib` = 0；未连接时六页统一为连接空态，连接后只显示真实内容（M2.4）。
20. **界面做了减法**：助手页只剩一行状态条 + 消息流；任务页删统计三卡；电脑页权限压成一行摘要 + 弹层；项目页只读真实授权目录；我的页删审计与演示账号；连接页步骤压成一行小字（M2.4）。
21. **能在线更新了**：手机端「我的 → 关于 → 检查更新」直接查版本、看说明、下载并调起系统安装器；不做静默安装（Android 限制，最后一步系统弹窗确认）；当前装机版本 0.1.5 需手动装一次 0.1.6，之后即可应用内更新（M2.5，178/178）。
22. **更新接口是后端自带的**：`GET /api/v1/app/version` + `GET|HEAD /api/v1/app/apk` 固定读 `dist/DeepSeek-Remote-latest.apk`，换包自动重算 sha256、无需改代码；本地与公网隧道均实测 200（M2.5 报告 §5）。
23. **手机能看电脑上的项目了**：项目页显示 Agent 真实工作区根，逐级浏览磁盘目录、只读预览代码（行号/复制/sha256/截断提示），并在任意目录「在此目录发指令」——新会话绑定该目录，Harness 就在项目目录里干活（M2.6，真实链路 14/14 PASS）。
24. **项目同步不挤占对话时间线**：`workspace.list` / `file.read` 是请求-响应消息，按 `requestId` 配对，结果只广播、不分配 seq、不写 `task_events`，所以浏览文件不会污染事件游标、断线补拉与任务时间线（M2.6）。

## 工作量与里程碑

- 设计分册口径：**84 人日**（M0 3 / M1 19 / M2 15 / M3 14 / M4 20 / M5 13），含 20% 缓冲为 **101**；关键路径 77 人日。
- 3 人全职约 **9–10 周**；2 人约 **15–16 周**。
- 若拍板"验收第 14 项输入控制（L3）纳入 1.0"：M4 20→23–24，总计 **87–88（含缓冲 105–106）**。

## 待拍板（详见构思方案第 7 章）

D-1 部署形态（推荐：后端先自托管在自己 PC/NAS + Tailscale 组网，上线迁云）· D-2 云资源由谁提供 · D-3 iOS 只交源码 · D-4 远程桌面先 L1 · D-5 APK 侧载 · D-6 实时口径（步骤级）· D-7 第 14 项 L3 是否进 1.0 · D-8 审批通知方案（推荐前台服务+本地通知）· D-9 离线指令语义（推荐禁止发送）。

## 复核方式

```powershell
# 环境类结论（只读检测，不改系统）
pwsh -File tools\env\check_env.ps1 -Full

# Harness 接入结论（需要本机 DSH 安装）
node tools\harness_probe\probe_acp.mjs

# M0 内核自测（三步全绿才算可用）
cd agent
npm run acl:check        # 首次或报 Win32 5 时先 npm run acl:fix
npm run test             # 36 单测
npm run test:contract    # 9 合同测试（真实 Harness，约 30s）
npm run e2e              # 5 步 E2E 冒烟（约 20s）
npm run selftest:relay   # M1 relay 自测（假后端，24 项）
cd ..

# M1 端到端（需先起 PostgreSQL+后端+Agent；公网则再加隧道）
node tools\m1-client.ts --base http://127.0.0.1:8080
node tools\m1-client.ts --base https://<你的隧道地址>
node tools\m1-approval-hold.ts --base https://<你的隧道地址>   # 手机审批联调

# M1.1 数据面复核（重启不丢历史）
psql -h 127.0.0.1 -p 5433 -U postgres -d deepseek_remote -c "select count(*) from conversations; select count(*) from messages; select count(*) from tasks;"
# 再用 m1-up/后端重启后 pair 一次，GET /api/v1/conversations 仍在即通过

# M2-α 复核（token 持久化；重启后端后旧 token 仍是 200）
psql -h 127.0.0.1 -p 5433 -U postgres -d deepseek_remote -c "select role, count(*), count(*) filter (where revoked_at is null) from auth_tokens group by role;"
# 先 pair 拿 token → 杀 8080 重启 → 用同一 token GET /api/v1/conversations?limit=5（-UseBasicParsing）

# M2.1 复核（事件表 + 断线补拉）
psql -h 127.0.0.1 -p 5433 -U postgres -d deepseek_remote -c "select count(*) from task_events; select type, count(*) from task_events group by type order by 2 desc;"
node tools\m2-catchup-test.ts --base http://127.0.0.1:8080 --drop-ms 60000   # 真实断流 60s → 重连补拉（约 90s）

# M2.5 复核（应用内更新；手机端 178/178）
pwsh -Command "$u='http://127.0.0.1:8080'; (Invoke-RestMethod -Uri \"$u/api/v1/app/version\" -UseBasicParsing) | Format-List"
pwsh -Command "$h=Invoke-WebRequest -Method Head -Uri 'http://127.0.0.1:8080/api/v1/app/apk' -UseBasicParsing; $h.StatusCode; $h.Headers['Content-Type']; $h.Headers['Content-Length']"
# 换包流程：替换 dist\DeepSeek-Remote-latest.apk → 改 backend application.properties 的 app.update.version-code/version-name → 重启后端 → 手机「我的→关于→检查更新」

# M2.6 复核（项目同步；真实链路 14/14）
node tools\verify-project-sync.ts --base http://127.0.0.1:8080
node --test agent/tests/unit/workspace-fs.test.ts
# 手机端：项目 → 浏览 → 打开 README.md → 「在此目录发指令」

# M4.0 / M4.1 / M4.2 / M4.3 复核（插件工作区接口 + 插件画廊 + 市场索引 + 附件落工作区 + 事件时间戳；需先完整退出重开 DSH 加载插件 0.2.12，期望 11/11 PASS）
pwsh -File tools\verify-plugin-m4.ps1              # 含在授权根下真实建目录 .m4-selftest-<时间戳>
# 手机 App 测试（M4.44 起为 497/497；本机中文路径下 analyzer 会崩，可先 robocopy 到 ASCII 目录再跑；release 构建也必须走 ASCII 路径，否则 AOT snapshotter 报 `Unable to read file … app.dill`）

# 手机 App 测试（M4.6 起为 291/291；本机中文路径下 analyzer 会崩，可先 robocopy 到 ASCII 目录再跑）
cd app; flutter test; flutter build apk --release
# 构建前务必同时设 JAVA_HOME=C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1 与 ANDROID_HOME=C:\Users\user\dsh-tools\android-sdk
cd ..

# 重新生成 Word 文档（封面/目录页码/表格/图片，自动收敛）
pwsh -File tools\build_docx.ps1
```

## 目录结构

```
docs/concept/    主构思方案 v0.2（md/docx）+ 架构图 + 界面图 + 渲染源 HTML
docs/design/     5 份详细设计分册 + M1_PROTOCOL.md（M1 契约）+ M1_1_DELTA.md（M1.1 契约）+ M2_DELTA.md（M2 契约）+ M2_1_DELTA.md（M2.1 契约）+ M2_2_DELTA.md（M2.2 契约）+ M2_3_UI_DELTA.md（M2.3 契约）+ M2_4_SIMPLIFY_DELTA.md（M2.4 契约）+ M2_5_UPDATE_DELTA.md（M2.5 契约）+ M2_6_PROJECT_SYNC_DELTA.md（M2.6 契约）+ mockups/（两版效果图）
docs/research/   环境实测 + Harness 接口 + M0/M1/M1.1/M2/M2.1/M2.2/M2.3/M2.4/M2.5/M2.6/M3.x/M4.0…M4.44 交付报告 + evidence/m1/、evidence/m2/ 证据
docs/review/     独立审核报告
docs/mobile/     手机 App 说明 + 13 张模拟器截图（01–08 演示历史 / 09–13 真实链路）
app/             手机 App（Flutter，单真实模式；M2.4 起无演示数据；M2.5 起应用内检查更新；M2.6 起项目浏览/文件预览）
agent/           ACP 适配内核 + relay 层 + 工作区只读文件系统（src/ tests/ scripts/ tools/ evidence/）
backend/         Java 中继后端（Spring Boot 3.5.16 + PostgreSQL 16.10 持久化 + 更新分发）
tools/           环境检测、Harness 探针、M1 E2E 客户端、项目同步验证、M4 插件自检（verify-plugin-m4.ps1）、cloudflared、Markdown→Word 流水线
PROJECT_STATUS.md  项目进度与待决策（每周更新）
```
