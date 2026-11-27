# 《DeepSeek Remote AI》开发环境调查报告（Phase 1）

| 项目 | 内容 |
| --- | --- |
| 项目名称 | DeepSeek Remote AI（手机 App 远程控制电脑上的 DeepSeek Harness 执行任务） |
| 阶段 | Phase 1 — 环境调查（对应策划案 8 阶段中的第 1 阶段） |
| 任务编号 | 团队共享任务 `task-1`（owner：env-scout） |
| 调查时间 | 2026-10-31 11:12 – 11:31（Asia/Shanghai，UTC+8） |
| 调查方式 | Windows PowerShell 5.1 只读命令实测；未安装任何软件、未修改系统配置/环境变量、未改动 DSH 安装目录、未执行 git 操作 |
| 证据存档 | `tools/env/out/check_env_full_20261031_113024.txt`（check_env.ps1 全量输出，197 行） |
| 可复测脚本 | `tools/env/check_env.ps1`（只读探测）、`tools/env/setup_dev_env.ps1`（只打印建议，须用户自行执行） |
| 说明 | 文中「未验证」= 本次未实际跑通或当前权限无法验证，不代表不可行 |

---

## 1. 结论摘要（TL;DR）

**一句话结论：本机是一台「已具备 Java 后端、Windows 桌面端、Android 构建与模拟器、Windows 打包链」的半成品开发机，唯一硬缺口是 Flutter SDK；数据库/缓存/云服务器/代码签名证书属于「采购或用户决策项」，不是技术障碍。**

- **补齐 Flutter SDK（下载约 1.81GB + 解压）后，手机端即可开工**；Java 后端、Remote Agent 今天就能开始编码。
- **JDK 21 + Android SDK + Gradle 8.14.3 + 模拟器（WHPX 加速）全部已存在且实测可用**，只是从未写入环境变量，当前 shell 里 `java`/`adb`/`gradle` 还不可直接调用。
- **远程桌面 MVP 的屏幕采集链路已在真机上实测跑通**：ffmpeg `gdigrab` 抓屏 2560x1600 成功，H.264 / NVENC 编码实测可用（见 §5.4）。但本机没有独立安装 ffmpeg（用的是第三方软件附带的构建），正式分发前需引入官方构建并做 GPL 合规。
- **真正的阻塞项是：Flutter 缺失、PostgreSQL/Redis 缺失、云服务器+域名+TLS 未提供、无代码签名证书、Windows 家庭版无 RDP 主机能力、GitHub 直连不稳定。**
- **排期影响：阶段 2/3 可 0 天阻塞立即开工；阶段 5（Flutter 手机端）预计阻塞 0.5–1 天（等 Flutter 装好）；阶段 4（后端）本地联调阻塞 0.5–1 天（等 PG）；阶段 7（整体联调）取决于云服务器采购，属外部依赖。**

### 1.1 结论表（具备 / 缺依赖 / 不具备）

| # | 模块 / 能力 | 结论 | 关键依据（详见 §3、§5） |
| --- | --- | --- | --- |
| 1 | 系统与硬件（Win11 x64 / 16C24T / 31.7GB / SSD） | **具备** | §2 实测 |
| 2 | Java 后端编码与编译（JDK 21 + Gradle 8.14.3） | **具备** | `java -version` = Temurin 21.0.12.1；`gradle --version` = 8.14.3 |
| 3 | Java 后端本地运行与联调（需数据库） | **缺依赖** | 无 PostgreSQL / Redis 服务，无 psql 客户端 |
| 4 | Flutter 手机端开发 | **缺依赖** | Flutter SDK 未安装（`where flutter` NOT FOUND，C/D 盘无 flutter 目录） |
| 5 | Android APK 构建链 | **缺依赖**（只缺 Flutter） | Android SDK / build-tools 35、36 / platform 36 / JDK 全部就绪 |
| 6 | Android 模拟器运行 | **具备** | `emulator -accel-check` = WHPX usable；headless 启动实测 `sys.boot_completed=1` |
| 7 | Android 真机调试 | **未验证** | `adb devices` 列表为空（当前无手机连接） |
| 8 | iOS 构建 | **不具备** | Windows 平台无 Xcode；只能交付源码 + macOS 构建说明 |
| 9 | Windows Remote Agent 开发（Node/Electron） | **具备** | Node v24.18.1 + npm 11.16.0 + MSVC + Python 3.14 + vswhere |
| 10 | Agent Windows 安装程序（NSIS） | **部分具备** | NSIS 3.11 可用（Tauri 附带）；无代码签名证书 |
| 11 | 远程桌面-屏幕采集 | **具备**（需引入 ffmpeg 二进制） | gdigrab 实测抓屏成功 2560x1600 |
| 12 | 远程桌面-视频编码 | **具备** | H.264 libx264 / h264_nvenc / mjpeg 编码器均存在并实测出帧 |
| 13 | 远程桌面-WebRTC P2P | **不具备** | 无 TURN/STUN 基础设施，无公网服务器；设计文档已把 WebRTC 放 P2 |
| 14 | PostgreSQL（8 张表 + Flyway 迁移） | **不具备**（未安装） | 卸载表无 PostgreSQL，无服务，5432 端口空闲 |
| 15 | Redis 缓存（可选） | **不具备**（未安装） | Windows 无原生 Redis，6379 空闲；MVP 可内存降级 |
| 16 | Docker / WSL2 | **不具备** | WSL 可选功能 InstallState=2（未安装）；Docker 未安装；均需管理员+重启 |
| 17 | 代码签名（安装包/发布） | **不具备** | `Cert:\CurrentUser\My` 无 CodeSigning 证书（0 found） |
| 18 | 云服务器 / 域名 / TLS | **不具备** | 本机家庭 NAT（192.168.1.x），公网出口 IP 未验证；无服务器/域名凭据 |
| 19 | 局域网 / 模拟器联调 | **具备** | 同网段 192.168.1.x；模拟器 `10.0.2.2` 可用；USB 可用 `adb reverse` |
| 20 | DSH 集成（调用真实 Harness） | **具备**（CLI 可用） | DSH 0.2.1-rc.5 运行中；`dsh --version` = 0.2.1-rc.5；Web GUI 62492 返回 401（需鉴权） |
| 21 | Maven 构建 | **缺依赖但非必须** | `mvn` 无；可用 Gradle 或 Maven Wrapper（Maven Central 实测可达） |
| 22 | 外网依赖下载 | **基本具备** | Maven/Gradle/pub/npm 镜像均 OK；GitHub 直连不稳定（曾超时，后续 200） |
| 23 | CI / 自动化流水线 | **不具备** | 未配置 CI；需云服务器或 GitHub Actions（GitHub 不稳定） |
| 24 | 版本控制 Git | **具备**（未配置身份） | Git 2.56.0.windows.2；无全局 `.gitconfig`（无 user.name/email） |

---

## 2. 系统与硬件

| 项目 | 实测值 | 证据命令 |
| --- | --- | --- |
| 操作系统 | Microsoft Windows 11 家庭版 中文版，10.0.26300，build 26300，64 位 | `Get-CimInstance Win32_OperatingSystem` |
| 机型 | MECHREVO JIGUANG Series，x64 | `Get-CimInstance Win32_ComputerSystem` |
| CPU | Intel Core i7-14650HX，16 核 / 24 线程，MaxClockSpeed 2200 | `Get-CimInstance Win32_Processor` |
| 内存 | 31.72 GB（调查时点可用 16.76 GB） | `Win32_ComputerSystem.TotalPhysicalMemory` / `Get-CimInstance Win32_OperatingSystem.FreePhysicalMemory` |
| 系统盘 C: | 300.01 GB 总 / **62.4 GB 可用**（NTFS） | `check_env.ps1` §1 |
| 数据盘 D: | 652.87 GB 总 / **82.8 GB 可用**（NTFS） | `check_env.ps1` §1 |
| 物理磁盘 | YMTC PC41Q-1TB-B SSD NVMe，1,024,209,543,168 B，Healthy | `Get-PhysicalDisk` |
| GPU | NVIDIA GeForce RTX 5060 Laptop GPU（驱动 32.0.16.2101）、Intel UHD Graphics（32.0.101.6733）、GameViewer Virtual Display Adapter（15.6.5.199） | `Get-CimInstance Win32_VideoController` |
| 显示 | 物理 2560x1600；Windows 逻辑分辨率 1707x1067（缩放下） | `Win32_VideoController.VideoMode` / ffmpeg gdigrab 抓图 2560x1600 |
| 当前用户权限 | `DESKTOP-XXXXXXX\user`，**非管理员**（IsAdmin=False） | `WindowsPrincipal.IsInRole` |
| 上次启动 | 2026-10-31 09:39:46 | `Win32_OperatingSystem.LastBootUpTime` |
| 网络 | 以太网 IPv4 192.168.1.x，网关/DNS 192.168.1.x；WLAN 192.168.1.x；另有 VMware / VirtualBox 虚拟网卡 | `Get-NetIPConfiguration` |
| 网络位置 | 配置文件 `Xiaomi_125-5G`（接口「以太网」），**NetworkCategory=Public** | `Get-NetConnectionProfile` |
| 代理 | 无 `HTTP_PROXY/HTTPS_PROXY/ALL_PROXY`；WinHTTP = Direct access；IE 代理 `ProxyEnable=0`（`ProxyServer=127.0.0.1:7897` 已禁用）；`com.vortex.helper` 进程监听 :::7897 / :::53 | `netsh winhttp show proxy`、`Get-ItemProperty HKCU:\...\Internet Settings` |
| 防火墙 | Domain/Private/Public 三 Profile 全部启用，默认入站 NotConfigured；已有入站允许规则：`node.exe`（Public x4、Private x2）、`adb.exe`（Public）、`adb41`（Any）；**无 java 规则** | `Get-NetFirewallProfile` / `Get-NetFirewallRule` |
| 杀毒 | Windows Defender，实时保护开启（`DisableRealtimeMonitoring=False`） | `Get-MpComputerStatus` |
| 代码签名证书 | `Cert:\CurrentUser\My` 与 `LocalMachine\My` 均无 CodeSigning 证书 | `Get-ChildItem Cert:\... -CodeSigningCert` |

---

## 3. 工具链版本总表

> 状态说明：**具备** = 已安装且本次实测可用；**具备但未配置** = 已安装但不在 PATH / 无环境变量，当前 shell 无法直接调用；**缺依赖** = 未安装但可补齐；**不具备** = 受平台/权限限制。

| 组件 | 版本 | 路径 / 来源 | 状态 |
| --- | --- | --- | --- |
| Windows PowerShell | 5.1.26100.9711（Desktop） | `C:\Windows\System32\WindowsPowerShell\v1.0` | 具备 |
| Node.js | **v24.18.1** | `D:\node.exe`（PATH 含裸 `D:\`，node 实际解析到此处；另有 `D:\npm.ps1`、`D:\npm.cmd`、`D:\corepack.cmd`） | 具备 |
| npm / npx | **11.16.0** / 11.16.0 | 经 PATH（cmd 下为 `D:\npm.cmd`；PowerShell 解析为 `D:\npm.ps1`） | 具备 |
| corepack | 0.35.0 | `D:\corepack.cmd` | 具备 |
| pnpm | 12.16.1（`corepack pnpm --version` 首次运行自动下载） | 不在 PATH | 缺依赖（可用 corepack） |
| Git | **2.56.0.windows.2** | `D:\soft\Git\cmd\git.exe` | 具备（无全局 user.name/email，无 ssh key） |
| Python | 3.14.3 | `C:\Users\user\AppData\Local\Programs\Python\Python314\python.exe` | 具备 |
| pip | 25.3（index-url = 清华源） | 同上 | 具备 |
| Rust | cargo/rustc 1.99.0 | `C:\Users\user\.cargo\bin` | 具备 |
| .NET | 运行时 8.0.14（NETCore.App + WindowsDesktop.App），**无 SDK** | `C:\Program Files\dotnet` | 缺 .NET SDK（非必须） |
| **JDK** | **Eclipse Temurin 21.0.12.1+1 LTS**（build 21.0.12.1+1-LTS） | `C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1`（2026/10/23 安装，约 0.32GB） | **具备但未配置**（无 JAVA_HOME、不在 PATH） |
| **Gradle** | **8.14.3**（Kotlin 2.0.21 / Groovy 3.0.24 / Ant 1.10.15 / Launcher JVM 21.0.12.1） | `C:\Users\user\.gradle\wrapper\dists\gradle-8.14.3-all\cbf6zifq8xavouihta8md72jo\gradle-8.14.3\bin\gradle.bat` | **具备但未配置** |
| Maven | — | 未安装 | 缺依赖（可用 Gradle / mvnw） |
| **Android SDK** | cmdline-tools/latest、build-tools **35.0.0 / 36.0.0**、platforms **android-36**（rev 2）、platform-tools **37.0.1**、emulator **37.2.12**、system-images android-34 google_apis x86_64（rev 14） | `C:\Users\user\dsh-tools\android-sdk`（2026/10/23 安装，约 5.74GB，8 个 license 已接受） | **具备但未配置** |
| adb | 1.0.41 / Version 37.0.1-15733141 | `...\android-sdk\platform-tools\adb.exe` | 具备（不在 PATH） |
| Android Emulator | 37.2.12.0 (build_id 16428233) | `...\android-sdk\emulator\emulator.exe` | 具备；WHPX 加速可用 |
| AVD | `timebook_test`（pixel_6 / x86_64 / API 34 / 2GB RAM / GPU off） | `C:\Users\user\.android\avd\timebook_test.avd` | 具备 |
| **Flutter** | 未安装（官方当前 stable = **3.47.9**，Dart 3.13.7，Windows zip 1,939,451,626 B = 1.81GB） | — | **缺依赖（P0 阻塞项）** |
| Android Studio | 未安装 | — | 缺（非必须，Flutter CLI 即可） |
| VS Build Tools 2022 | 17.14.41（isComplete=true） | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` | 具备 |
| MSBuild | 17.14.60.43110 | `...\BuildTools\MSBuild\Current\Bin\MSBuild.exe` | 具备（不在 PATH） |
| MSVC 工具集 | 14.44.35207，`cl.exe`/`link.exe` 齐全（Hostx64\x64 等 4 套） | `...\VC\Tools\MSVC\14.44.35207\bin\` | 具备 |
| Windows SDK | 10.0.26100.0（另有 14393/15063/16299/17134 的 Include） | `C:\Program Files (x86)\Windows Kits\10` | 具备 |
| signtool.exe | 10.0.26100.0 | `...\Windows Kits\10\bin\10.0.26100.0\{x64,arm64,x86}\signtool.exe` | 具备（无证书可签） |
| NSIS | **v3.11**（`makensis /VERSION` 实测输出 v3.11） | `C:\Users\user\AppData\Local\tauri\NSIS\makensis.exe` | 具备（未在系统 PATH） |
| Inno Setup / WiX / CMake | — | 未安装 | 缺（非必须） |
| 7-Zip | 23.01 (x64) | `D:\soft\7za.exe` | 具备（不在 PATH） |
| **FFmpeg** | 6.1.1-essentials_build-www.gyan.dev（第三方 bundle，GPL build） | `D:\soft\MiniMax Design\current\resources\ffmpeg\ffmpeg.exe`（82,807,744 B）；无独立安装 | **可用但需正式引入** |
| VS Code | 1.143.1（已装扩展仅 claude-code、中文语言包） | `C:\Users\user\AppData\Local\Programs\Microsoft VS Code` | 具备（Flutter/Dart 扩展未装） |
| **DSH（DeepSeek Harness）** | **0.2.1-rc.5**（ProductVersion 0.2.1.0） | `C:\Users\user\AppData\Local\Programs\DeepSeek Harness\`；`resources\version` 文件为 44.7.0（Electron 版本，非 DSH 版本） | 具备（运行中，10+ 进程） |
| dsh CLI | 0.2.1-rc.5 | `...\resources\runtime\cli\bin\dsh.cmd`（已在 PATH） | 具备 |
| cloudflared | 2026.10.3（built 2026-10-21） | `C:\Users\user\dsh-tools\cloudflared.exe` | 具备（临时内网穿透候选，未验证） |
| winget | v1.29.380 | `C:\Users\user\AppData\Local\Microsoft\WindowsApps\winget.exe` | 具备（仅作为用户自行安装途径） |
| PostgreSQL | — | 未安装（无 psql / 无服务 / 5432 空闲） | 缺 |
| Redis | — | 未安装（6379 空闲） | 缺 |
| MySQL / MariaDB | — | 未安装 | 缺（不推荐，策划案用 PG） |
| Docker | — | 未安装 | 缺 |
| WSL2 | 可选功能 `Microsoft-Windows-Subsystem-Linux` InstallState=2（未安装） | `wsl.exe` 存在但提示「未安装用于 Linux 的 Windows 子系统」 | 缺（需管理员 + 重启） |

---

## 4. 环境变量与 PATH 现状

**现状：所有开发相关的环境变量都是空的，PATH 里没有任何 java / adb / gradle / flutter 入口。** 这是「JDK/SDK 装了却用不了」的直接原因。

| 变量 | 当前值 | 建议值 | 影响 |
| --- | --- | --- | --- |
| `JAVA_HOME` | （unset） | `C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1` | Gradle / AGP / Spring Boot 启动、`sdkmanager` 均依赖 |
| `ANDROID_HOME` | （unset） | `C:\Users\user\dsh-tools\android-sdk` | Flutter / Gradle Android 插件 / sdkmanager 依赖 |
| `ANDROID_SDK_ROOT` | （unset） | 同上 | 兼容旧版工具 |
| `FLUTTER_ROOT` | （unset） | 可选（PATH 加 `C:\dev\flutter\bin` 即可） | Flutter 一般不需要显式设置 |
| `GRADLE_HOME` | （unset） | 可选 | 用 wrapper 的 `gradle.bat` 或下载独立 Gradle 即可 |
| `MAVEN_HOME` / `M2_HOME` | （unset） | 不需要 | 用 Gradle 或 mvnw |
| `PNPM_HOME` | （unset） | 需要时 `corepack enable` | 非必须 |
| `HTTP(S)_PROXY` | 全部 unset | 保持直连；GitHub 下载不稳时临时用本机 `127.0.0.1:7897` | 依赖下载 |
| PATH | 缺少 `%JAVA_HOME%\bin`、platform-tools、emulator、cmdline-tools、gradle、flutter | 追加 6 条（见 `tools/env/setup_dev_env.ps1`） | 日常命令可用性 |

**⚠ PATH 异常（重要）：** 机器 PATH 中存在**裸目录 `D:\`**，且 `D:\npm.ps1`、`D:\npx.ps1`、`D:\npm.cmd`、`D:\corepack.cmd` 都位于该目录。实测后果：

- Windows PowerShell 中 `Get-Command npm` 解析为 `D:\npm.ps1`（ExternalScript，而不是 `npm.cmd`）；
- 在受限执行策略的终端里可能出现「无法加载 npm.ps1」类问题；
- 本报告所用 PowerShell 会话为 `-ExecutionPolicy Bypass`，未受影响。

建议：用户后续整理 PATH 时，**清理裸 `D:\` 条目**，改为显式 `D:\nodejs\`（或保留现状但已知悉风险）。本报告不修改 PATH。

---

## 5. 分模块就绪度分析

### 5.1 Flutter 手机端（结论：缺依赖 —— 唯一硬缺口）

- **Flutter SDK 不存在**：`where flutter` → NOT FOUND；对 `C:\`、`D:\` 根做 depth 3 目录名搜索（`flutter`/`dart-sdk`/`android-studio`/`gradle` 等）仅在 `C:\Users\user\dsh-tools` 命中 `android-sdk`、`jdk`；对常用目录 depth 6 搜 `flutter.bat`/`dart.exe` 也无命中（仅命中 Tauri 自带 NSIS 与旧 android 项目的 gradlew.bat）。
- **`flutter --version` / `flutter doctor -v` 未执行**：SDK 未安装，无法执行（此项标「未验证」；装上 SDK 后必须补跑）。
- **Android 侧已就绪**：JDK 21 LTS + Android SDK（build-tools 35/36、platform android-36、platform-tools、emulator、system image android-34、license 已接受）+ Gradle 8.14.3（与 JDK 21 实测兼容）+ WHPX 模拟器加速可用。
- **版本选择建议：Flutter 3.47.9 stable（Dart 3.13.7）**。官方 Windows 版本清单实测可访问（HTTP 200，271,531 B），对应 zip 的 HEAD 请求返回 HTTP 200、`Content-Length=1,939,451,626`（1.81GB）。
- **Gradle / JDK 兼容性**：本机 Gradle 8.14.3 与 JDK 21 组合已实测（`gradle --version` 输出 Launcher JVM 21.0.12.1）；Flutter 生成的 Android 工程会用其模板指定的 Gradle wrapper / AGP 版本，首次构建时会从 `services.gradle.org`/Maven 下载（实测可达）。**Flutter + AGP 在本项目上的实际构建未验证**（未安装 Flutter）。
- **Android SDK 包缺口**：当前仅装 `platforms;android-36`。若 Flutter 模板或插件要求 compileSdk 35，可用 `sdkmanager "platforms;android-35"` 补装（网络可达、license 已接受；未验证是否必需）。
- **iOS**：Windows 无法构建，仅能交付 Flutter 源码 + iOS 构建说明（需 macOS + Xcode 验收）；验收标准需与用户确认。

### 5.2 Java 后端（结论：编码/编译具备；本地运行缺 DB）

- JDK 21 LTS 可用（`java -version` 实测）；Gradle 8.14.3 可用（`gradle --version` 实测，需 `JAVA_HOME`）。**Maven 未安装**，但可用 Gradle 或 Maven Wrapper（`mvnw` 首次运行时自动下载 Maven，Maven Central 实测可达）。
- Spring Boot 版本：Maven Central `spring-boot` 元数据实测 HTTP 200，共 297 个版本，最新 4.2.0-RC1；**3.5.x 线最新为 3.5.16**。策划案要求「Spring Boot 3.x 或兼容稳定版」→ **建议锁 3.5.16**（与策划案一致，避免 4.x 迁移风险）。
- **数据库缺失**：PostgreSQL 未安装（无 psql、无服务、5432 空闲）。后端可先写代码 + H2/内存过渡跑接口，但 **Flyway PostgreSQL 方言迁移脚本必须在真实 PG 上验证**。
- **Redis 可选**：未安装。若设计中的「令牌黑名单 / presence / 任务进度缓存」可用内存实现降级，MVP 可暂不接 Redis；若必须，选云 Redis 或 Memurai（未验证）。
- 端口：`8080` 空闲（与 `docs/design/PROTOCOL.md` L52 本地开发约定 `http://127.0.0.1:8080` 一致）；8443、5432、6379 均空闲。

### 5.3 Windows Remote Agent（结论：具备）

- Node v24.18.1、npm 11.16.0、corepack 0.35.0 可用；**Electron 相关二进制需从 npm/CDN 下载**：npm registry 已配置 `https://registry.npmmirror.com`（实测可达）。Electron 默认从 GitHub Releases 下载，而 **GitHub 直连不稳定**（TCP 443 曾超时，后续 Invoke-WebRequest 200）→ 建议设置 `ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/`（镜像站点可达，具体版本可用性**未验证**）。
- 原生模块编译：VS Build Tools 2022（MSVC 14.44）、Windows SDK、`vswhere.exe` 均就绪，node-gyp 12.3.0 可用；Python 3.14.3 存在。**Python 3.14 + node-gyp 实际编译未验证**（3.12+ 移除 distutils，若遇到原生模块编译错误，可用户级安装 Python 3.12/3.13 兜底）。
- **Agent 与 DSH 同机**：DSH 0.2.1-rc.5 正在运行，CLI `dsh` 在 PATH；Web GUI `127.0.0.1:62492` 只监听 loopback 且请求返回 **HTTP 401**（需鉴权）。因此：
  - Agent 通过**子进程调用 dsh CLI** 是当前最稳妥的集成方式（具体 headless 调用方式属另一任务 `tools/harness_probe/` 的验证范围）；
  - 不要依赖 62492 端口对手机/公网暴露（设计文档也明确禁止）。
- **只出站 WSS**：本机出站 443 连通正常，家庭 NAT 后可用，无需公网 IP；防火墙不需要入站放行。`cloudflared 2026.10.3` 可作为临时隧道候选（未验证）。

### 5.4 远程桌面（结论：采集/编码可行；WebRTC 不具备）

**实测结论：MVP 方案（ffmpeg gdigrab → 帧 → WSS）的采集与编码在本机完全可行，已用真机屏幕跑通。**

| 实测项 | 命令 | 结果 |
| --- | --- | --- |
| 抓屏单帧 | `ffmpeg -f gdigrab -i desktop -frames:v 1 out.png` | 成功，PNG 3,905,973 B，**2560x1600** |
| 单帧 JPEG q8 | `-c:v mjpeg -q:v 8 -frames:v 1` | 379,507 B / 帧（全分辨率） |
| H.264（libx264） | `-framerate 10 -t 1 -vf scale=1280:-2 -c:v libx264 -preset ultrafast` | 378,472 B/秒，**约 3.0 Mbps**，墙钟 1,281 ms |
| MJPEG | `-framerate 10 -t 1 -vf scale=1280:-2 -c:v mjpeg -q:v 6` | 1,492,376 B/秒，**约 13.3 Mbps**，墙钟 1,308 ms |
| H.264（NVENC 硬编） | `-c:v h264_nvenc -preset p4 -tune ll` | 198,404 B/秒，**约 1.76 Mbps**，墙钟 1,296 ms |

- 编码器齐全：`libx264`、`h264_nvenc`、`mjpeg`、`libx265`、`hevc_nvenc`、`av1_nvenc`；采集设备 `gdigrab`/`dshow`/`lavfi` 均在。
- **带宽结论（重要）**：设计文档 ADR-PROTO-010 的 MVP 是「MJPEG over WSS 12fps 自适应」。实测 MJPEG 在 1280 宽/10fps 已约 13 Mbps，全分辨率单帧 379KB（12fps ≈ 36 Mbps），**公网/4G 不可接受**。建议：**优先 H.264（软编约 3 Mbps / NVENC 约 1.8 Mbps）**，或 MJPEG 仅用于局域网/演示并大幅降分辨率、降帧率、降质量；该结论需回写设计文档复核。
- 采集端开销：1 秒 10fps 片段墙钟约 1.3 秒（≈0.8x 实时），说明 gdigrab 抓屏是主要瓶颈之一，长时稳定性/多显示器/DPI 缩放（逻辑 1707x1067 vs 物理 2560x1600）**未验证**。
- **无独立 ffmpeg**：本机只有第三方软件附带的构建。正式交付需引入官方 Windows 构建（gyan.dev / BtbN），锁定版本并注意 **GPL 合规**（`--enable-gpl` 构建随 Agent 分发时需评估许可证义务）；本报告仅把它作为「可行性验证工具」。
- **Windows RDP 不可用**：家庭版无 RDP 主机能力；`TermService` Stopped/Manual、`fDenyTSConnections=1` → 证实不能依赖系统 RDP，必须走自研截图/Video 通道。
- **WebRTC P2P 不具备**：无 TURN/STUN 服务与公网服务器；设计文档已把 WebRTC 放 P2（与现状一致）。

### 5.5 数据库 / 中间件（结论：缺）

- **PostgreSQL：未安装**（卸载表无、服务无、psql 无、5432 空闲）。落地方式见 §7。
- **Redis：未安装**（Windows 无官方支持；6379 空闲）。
- **Docker：未安装**；**WSL2：可选功能未启用**（`Microsoft-Windows-Subsystem-Linux` InstallState=2；`VirtualMachinePlatform`=1 已启用）。启用 WSL2/Docker 需要**管理员权限 + 重启**，且本机为非管理员会话 → 不建议为了 MVP 现在安装。
- MySQL/MariaDB：未安装；与策划案（PostgreSQL）不一致，不推荐。
- 现有 8 张表设计（users/devices/device_pairings/conversations/messages/tasks/audit_logs/workspace_permissions）与 Flyway 迁移可在 PG 就绪后直接落地；Flyway 作为 Gradle 插件可从 Maven Central 下载（未验证具体版本）。

### 5.6 打包与发布（结论：部分具备）

- **NSIS 3.11 可用**（`makensis /VERSION` → v3.11，Tauri 附带，非系统 PATH），可生成 Windows 安装程序；**未实际打包验证**。
- Inno Setup / WiX / CMake 未安装（非必须，NSIS 足够；CMake 仅在需要编译某些 C++ 依赖时才会用到）。
- MSVC + Windows SDK 齐全：可编译原生依赖、可用 `signtool`（但**无代码签名证书**）。
- **无代码签名证书**：安装包/IPA 无法签名 → Windows SmartScreen 会告警、企业分发受限。需用户购买（OV/EV 证书）或接受未签名。
- Android 打包：APK 构建需 Flutter + keystore（**未生成**，属发布阶段用户决策）；`adb`/`bundletool` 链具备（无 Android Studio 不影响 CLI 构建）。
- iOS：本机不可构建。

### 5.7 DSH 集成环境（结论：具备）

- DSH 0.2.1-rc.5 安装于 `C:\Users\user\AppData\Local\Programs\DeepSeek Harness\`（`FileVersion 0.2.1-rc.5`，`ProductVersion 0.2.1.0`，CompanyName GitHub, Inc.）；`resources\version` 内容为 `44.7.0`（Electron 版本，属正常现象）。
- CLI：`dsh --version` → `0.2.1-rc.5`；`dsh.cmd` 所在目录已在 PATH → Agent 可直接 `spawn('dsh', ...)`。
- 运行状态：调查时点有 10+ 个 `DeepSeek Harness` 进程；`127.0.0.1:62492`（PID 22960）监听，`Invoke-WebRequest` 返回 **HTTP 401**（需鉴权），同 PID 另有 `127.0.0.1:8326`。
- 另有旧版独立应用 `DSH Desktop 0.10.0`（`C:\Users\user\AppData\Local\Programs\DSH Desktop\`）与备份目录 `DeepSeek Harness.bak-rc2-20261031-103905`；**不要修改/删除安装目录**。
- 风险：0.2.1-rc.5 为 RC 版本，CLI/GUI 接口可能变动；Agent 集成层需做版本探测与容错。

---

## 6. 缺失清单与安装方案（只给方案，本次未执行任何安装）

> 所有命令仅供参考，**没有一条在本机执行过安装**。标注「需管理员」的操作必须由用户在管理员终端自行执行；本会话（非管理员）不做，也不请求提权。

| 优先级 | 缺失项 | 影响 | 推荐方案（供用户决策） | 需管理员 | 预计耗时 / 空间 |
| --- | --- | --- | --- | --- | --- |
| **P0** | **Flutter SDK 3.47.9 stable** | Flutter 手机端全部工作 | 下载官方 Windows zip → 解压到 `C:\dev\flutter`（ASCII 路径）→ PATH 加 `C:\dev\flutter\bin` → `flutter doctor -v` | 否 | ~1.81GB 下载 + 解压/缓存约 3–5GB；10–60 分钟（**网速未测**） |
| **P0** | **用户级环境变量 / PATH** | `java`/`adb`/`gradle`/`flutter` 不可用 | 运行 `tools/env/setup_dev_env.ps1`（默认只打印）；或用户手动执行其打印出的 `[Environment]::SetEnvironmentVariable(...,'User')` 命令 | 否 | 1 分钟 |
| **P1** | **PostgreSQL** | 后端本地联调、Flyway 迁移验证 | 方案 A（推荐）：云 PG（阿里云/腾讯云 RDS）或轻量云服务器自建；方案 B：本机安装 `winget install PostgreSQL.PostgreSQL.17`（包名/源可用性**未验证**）或 EDB 官方 zip（免安装，放用户目录） | 方案 B 需管理员 | 云：采购/配置 0.5–1 天；本地：~300MB，0.5 天 |
| **P1** | **代码签名证书** | 发布安装包/安装体验 | 向 CA 购买 OV/EV 代码签名证书（用户决策，成本外部） | 是（导入证书） | 采购周期 1–5 工作日 |
| **P1** | **云服务器 + 域名 + TLS 证书** | 阶段 7 联调/上线；公网访问 | 用户提供；建议 2C4G 起步（策划案估算 ¥60–120/月，见概念方案 L146）；HTTPS/WSS 需域名+证书（Let's Encrypt 可用） | 外部 | 采购/备案（若需）数天 |
| **P1** | **FFmpeg 官方构建** | 远程桌面正式交付 | 下载 gyan.dev 或 BtbN 官方 Windows release，放 `tools/bin/ffmpeg/` 并锁定版本；随 Agent 分发需评估 GPL 合规 | 否 | ~100MB，0.5 小时 |
| **P2** | **Redis**（可选） | 缓存/令牌黑名单/presence | 云 Redis；或 Memurai（未验证）；或 MVP 先内存实现降级 | 云：否；本机：是 | 采购/0.5 天 |
| **P2** | VS Code Flutter/Dart 扩展 | 手机端编码体验 | 在 VS Code 扩展市场安装（marketplace 实测可达） | 否 | 5 分钟 |
| **P2** | Android 真机测试设备 | 真机联调/验收 | 用户连接一台 Android 手机（开启 USB 调试）；当前 `adb devices` 为空 | 否 | 用户提供 |
| **P3** | Docker / WSL2 | 容器化/本地 Linux 环境 | 非 MVP 必需；需要时管理员执行 `wsl --install` + 重启 | 是 | 30–60 分钟 + 重启 |
| **P3** | .NET SDK / CMake / Maven / Inno Setup / WiX / Android Studio | 非必需 | 不做；Flutter CLI + Gradle + NSIS 已够 | — | — |

### 6.1 Flutter 安装步骤（建议由用户执行）

```powershell
# 1) 下载（实测该 URL HEAD 返回 200，Content-Length 1,939,451,626）
#    https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.9-stable.zip
# 2) 解压到纯 ASCII 路径（不要放中文目录）
Expand-Archive -Path .\flutter_windows_3.47.9-stable.zip -DestinationPath C:\dev
# 3) 用户级 PATH 追加 C:\dev\flutter\bin（可用 tools/env/setup_dev_env.ps1 -Apply -Force）
# 4) 新开终端验证
flutter --version
flutter config --android-sdk "C:\Users\user\dsh-tools\android-sdk"
flutter config --jdk-dir "C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1"
flutter doctor -v
flutter precache --android
```

- 若官方源下载慢：可设 `PUB_HOSTED_URL=https://pub.flutter-io.cn`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`（`pub.flutter-io.cn` API 实测 200；`storage.flutter-io.cn` 仅根路径 403，**实际制品下载未验证**）。
- Flutter 官方 zip 自带 `.git` 元数据，需要 Git（已具备 2.56.0）。
- **不要**用 `winget install Flutter` 之类未验证包名的方式；官方 zip 是本次唯一实测可达的渠道。

### 6.2 PostgreSQL 安装方案（二选一，建议 A）

- **方案 A（推荐）：云托管 PG** —— 与云服务器同期采购；本机零安装，团队直接联调。缺点：需要网络稳定（本机访问云 PG 的 5432 出站未被防火墙默认阻止，未验证）。
- **方案 B：本机安装** —— 需管理员权限（`winget install PostgreSQL.PostgreSQL.17` 或 EDB installer），或下载 EDB 官方「zip 二进制包」解压到用户目录后手动 `initdb`（免管理员，**未验证**）。装好后：`createdb deepseek_remote`，端口 5432。
- 无论哪种，**Flyway 迁移脚本必须在真实 PG 上跑一遍**再进入联调。

---

## 7. 端口与联调网络方案

### 7.1 当前端口占用（实测）

| 端口 | 状态 | 占用进程 |
| --- | --- | --- |
| 62492 | **占用**（127.0.0.1） | PID 22960 `DeepSeek Harness`（Web GUI，HTTP 401 需鉴权） |
| 8326 | **占用**（127.0.0.1） | PID 22960 `DeepSeek Harness` |
| 7897 | **占用**（:::） | PID 23144 `com.vortex.helper` |
| 53 | **占用**（:::） | PID 23144 `com.vortex.helper` |
| 18787 | **占用**（127.0.0.1） | PID 8208 `node` |
| 8080 / 8081 / 8443 / 5432 / 6379 / 3306 / 27017 / 3000 / 5173 / 9229 / 8765 | **空闲** | — |

### 7.2 建议端口分配（与设计文档对齐）

| 用途 | 端口 | 说明 |
| --- | --- | --- |
| Java 后端 HTTP | 8080 | `PROTOCOL.md` L52 本地开发已约定 `http://127.0.0.1:8080`，实测空闲 |
| WSS 事件通道 | 8080（同端口 `/ws/v1/...`） | 与后端同端口，减少端口暴露 |
| 后端 HTTPS（联调/生产） | 8443 | 空闲；生产由 Nginx/Caddy 反代 443 |
| PostgreSQL | 5432 | 空闲 |
| Redis | 6379 | 空闲 |
| DSH Web GUI | 62492 | **仅 loopback，不要暴露**；只允许本机 Agent 通过 CLI 访问 |
| Agent 本地控制口（如需要） | 建议不要开；或 127.0.0.1 随机端口 | 设计文档要求 Agent 只出站 WSS、不开入站 |

### 7.3 手机端联调网络路径（按优先级）

1. **Android 模拟器 → 本机后端**：模拟器内访问 `http://10.0.2.2:8080`（无需防火墙、无需管理员）。模拟器启动与加速已实测通过。
2. **USB 真机 → 本机后端**：`adb reverse tcp:8080 tcp:8080` 后手机访问 `http://127.0.0.1:8080`（无需防火墙；需先连上手机并授权 USB 调试）。
3. **同局域网真机 → 本机后端**：`http://192.168.1.x:8080`。注意当前网络位置为 **Public** 配置文件，Windows 防火墙默认入站更严格；`node.exe`/`adb.exe` 已有允许规则但**没有 java 规则** → 需为用户执行 `netsh advfirewall` 放行（**需管理员**），或改用方案 1/2。
4. **公网演示/远程联调**：云服务器反向代理（推荐）；或 `cloudflared` 临时隧道（2026.10.3 已装，**未验证**）。家庭宽带 NAT + 公网 IP 未验证，不能假设可做端口映射。

---

## 8. 风险与限制

| # | 风险 / 限制 | 影响 | 缓解措施 |
| --- | --- | --- | --- |
| R1 | **非管理员会话**：不能装服务、改防火墙、启用 WSL、导入证书 | P1/P3 安装项全部需用户执行 | 用户级完成 Flutter/环境变量；系统级操作列入用户任务清单 |
| R2 | **GitHub 直连不稳定**（TCP 曾超时，后 200） | Electron/部分依赖下载失败 | 用 npmmirror、`ELECTRON_MIRROR`、Maven/pub 镜像；避免从 GitHub 拉大文件 |
| R3 | **项目路径含中文**（`<项目根>`） | 个别工具链对非 ASCII 路径敏感 | SDK/缓存/临时目录放 ASCII 路径；项目路径暂不动（历史 Gradle 构建曾在中文路径跑通，未逐项验证） |
| R4 | **Windows 家庭版无 RDP 主机**（TermService stopped、fDenyTSConnections=1） | 不能走系统 RDP 方案 | 已确定走自研截图/视频通道（与设计一致） |
| R5 | **无代码签名证书** | 安装包 SmartScreen 告警、分发受限 | 用户购买证书或明确接受未签名发布 |
| R6 | **Public 防火墙 + 家庭 NAT** | 手机直连 PC 受限 | 模拟器 10.0.2.2 / adb reverse / 云服务器反代 |
| R7 | Defender 实时保护开启 | 构建/下载可能变慢、被扫描 | 可接受；不建议关闭 |
| R8 | Python 3.14 + node-gyp 12.3.0 | 原生模块编译可能失败（未验证） | 遇错则用户级安装 Python 3.12/3.13 或改用预编译包 |
| R9 | DSH 为 RC 版本（0.2.1-rc.5） | CLI/GUI 行为可能变动 | 固定版本、集成层做版本探测与降级 |
| R10 | 磁盘余量 C 62.4GB / D 82.8GB | Flutter+Gradle+AGP+pub 缓存预计新增 5–10GB，仍够但需关注 | 安装前清理；Flutter 放 C（余量更大） |
| R11 | 家庭网络代理历史配置（IE 代理指向 7897 但已禁用；vortex helper 占用 7897/53） | 部分工具可能读取系统代理导致异常 | 已确认 WinHTTP direct、npm/pip 无代理；如需代理由用户显式设置 |
| R12 | PATH 裸 `D:\` 导致 npm/npx 解析为 `.ps1` | 受限执行策略下可能报错 | 建议用户整理 PATH（清理裸目录），或统一用 `cmd /c npm` |
| R13 | 无公网 IP（家庭 NAT；`api.ipify.org` 请求失败，公网出口未验证） | 无法直接对外提供服务 | 云服务器是唯一稳妥路径；cloudflared 仅临时 |

---

## 9. 未验证清单（本次已明确标注，不在报告的结论中冒充已验证）

- ❌ `flutter doctor -v`、`flutter --version`（Flutter 未安装，无法执行）
- ❌ Flutter + Android Gradle 实际构建（AGP/Gradle/JDK 组合在本项目未跑过）
- ❌ Android 真机调试（`adb devices` 为空，无设备连接）
- ❌ PostgreSQL 安装/连接/Flyway 迁移（未安装）
- ❌ Redis 运行（未安装）
- ❌ NSIS 实际生成安装包（版本可查，未打包）
- ❌ 代码签名流程（无证书）
- ❌ cloudflared 隧道实际连通（仅确认二进制版本）
- ❌ 公网出口 IP / 外网可达性（`api.ipify.org` 请求失败）
- ❌ WebRTC（无 TURN/公网服务器）
- ❌ FFmpeg 多显示器 / DPI 缩放 / 长时稳定性 / WSS 传输 / 端到端带宽（仅本地 1 秒片段离线测试）
- ❌ NVENC 多路/高负载稳定性（仅 1 秒单路测试）
- ❌ Electron 打包与安装（未安装 Electron 依赖）
- ❌ Python 3.14 + node-gyp 原生模块编译
- ❌ winget 安装 PostgreSQL 的包名/源可用性
- ❌ 镜像源实际制品下载（pub.flutter-io.cn / ELECTRON_MIRROR / storage.flutter-io.cn）
- ❌ iOS 构建（平台限制，永久不可在本机验证）

---

## 10. 对项目排期的直接影响

| 阶段（策划案 8 阶段） | 结论 | 预计影响 |
| --- | --- | --- |
| P1 环境调查 | ✅ 本报告完成 | 0 天 |
| P2 项目初始化 | ✅ 可立即开工：Java 后端脚手架、Agent 骨架、Flutter 工程结构（Flutter 工程创建需 SDK，可先写目录/配置或等安装） | **0 天阻塞** |
| P3 电脑端 Remote Agent | ✅ 可立即开工；打包链（NSIS）具备；FFmpeg 需引入官方构建 | **0 天阻塞** |
| P4 Java 后端 | 🟡 编码可立即开工；本地运行/联调需 PG | **0.5–1 天阻塞**（可并行采购云 PG） |
| P5 Flutter 手机端 | 🟡 需先安装 Flutter SDK | **0.5–1 天阻塞**（取决于 1.81GB 下载速度与首次构建） |
| P6 远程桌面 | 🟡 采集/编码链路已验证可行；传输联调需后端+Agent；WebRTC P2 需云服务器 | 部分阻塞（取决于云服务器） |
| P7 整体联调 | 🔴 依赖云服务器 + 域名 + TLS（用户决策/采购） | **外部依赖阻塞** |
| P8 构建发布 | 🟡 APK 需 keystore（用户决策）；Windows 安装包可 NSIS 生成但无签名；iOS 仅源码+说明 | 质量/验收受限 |

**关键路径：Flutter SDK 安装 → 手机端开发 → App↔Agent 联调；云服务器采购 → 公网联调。** 建议顺序：

1. **用户今天即可执行**：下载解压 Flutter 3.47.9 → 运行 `tools/env/setup_dev_env.ps1`（或手动写用户环境变量）→ `flutter doctor -v` → 把输出发回。
2. **团队并行开工（0 阻塞）**：Spring Boot 3.5.16 后端骨架（Gradle）、Remote Agent 骨架 + FFmpeg 采集验证程序、数据库 schema/Flyway 脚本。
3. **需要用户拍板的 5 件事**（概念方案 L48）：部署形态、iOS 交付方式、远程桌面优先级、APK 侧载策略、云服务器与域名提供方。
4. **需用户提供/采购**：云服务器 + 域名 + TLS、PostgreSQL 方案（云 or 本机）、代码签名证书（发布前）。

---

## 附录 A：实测命令与输出摘录（关键证据）

> 完整输出见 `tools/env/out/check_env_full_20261031_113024.txt`；以下为报告结论对应的核心命令。

```text
# 系统
PS> Get-CimInstance Win32_OperatingSystem | Select Caption,Version,BuildNumber,OSArchitecture
Caption: Microsoft Windows 11 家庭版 中文版
Version: 10.0.26300   BuildNumber: 26300   OSArchitecture: 64 位

# 权限
PS> (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole('Administrators')
False

# JDK（存在但未配置）
PS> C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1\bin\java.exe -version
openjdk version "21.0.12.1" 2026-08-18 LTS
OpenJDK Runtime Environment Temurin-21.0.12.1+1 (build 21.0.12.1+1-LTS)
OpenJDK 64-Bit Server VM Temurin-21.0.12.1+1 (build 21.0.12.1+1-LTS, mixed mode, sharing)
PS> javac -version
javac 21.0.12.1

# 环境变量（均为空）
PS> [Environment]::GetEnvironmentVariable('JAVA_HOME','Process')   -> (empty)
PS> [Environment]::GetEnvironmentVariable('ANDROID_HOME','Process') -> (empty)

# Gradle（进程内临时 JAVA_HOME 后实测）
PS> C:\Users\user\.gradle\wrapper\dists\gradle-8.14.3-all\...\gradle-8.14.3\bin\gradle.bat --version
Gradle 8.14.3
Launcher JVM: 21.0.12.1 (Eclipse Adoptium 21.0.12.1+1-LTS)
Daemon JVM:   C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1
（未设 JAVA_HOME 时：ERROR: JAVA_HOME is not set and no 'java' command could be found in your PATH.）

# Android SDK 已安装包
PS> sdkmanager.bat --list_installed
build-tools;35.0.0 | 35.0.0
build-tools;36.0.0 | 36.0.0
emulator | 37.2.12
platform-tools | 37.0.1
platforms;android-36 | 2
system-images;android-34;google_apis;x86_64 | 14

# 模拟器加速 + AVD
PS> emulator.exe -accel-check
accel:
0
WHPX(10.0.26300) is installed and usable.
accel
PS> emulator.exe -list-avds
timebook_test

# 模拟器无头启动实测
PS> Start-Process emulator.exe -ArgumentList '-avd','timebook_test','-no-window','-no-audio','-no-boot-anim','-no-snapshot','-gpu','swiftshader_indirect' -PassThru
PS> adb shell getprop sys.boot_completed
1
PS> adb shell wm size
Physical size: 1080x2400
PS> adb shell getprop ro.build.version.sdk
34

# Flutter 缺失
PS> where.exe flutter
INFO: Could not find files for the given pattern(s).

# MSVC / Windows SDK / NSIS
PS> MSBuild.exe -version -nologo
17.14.60.43110
PS> cl.exe (Hostx64\x64) 存在：...\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\cl.exe
PS> signtool.exe 存在：...\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe
PS> makensis.exe /VERSION
v3.11

# FFmpeg（第三方 bundle）
PS> ffmpeg.exe -version
ffmpeg version 6.1.1-essentials_build-www.gyan.dev
PS> ffmpeg.exe -devices | findstr gdigrab
 D  gdigrab         GDI API Windows frame grabber
PS> ffmpeg.exe -f gdigrab -framerate 1 -i desktop -frames:v 1 out.png
frame= 1 ... video:3814kB    → 输出 2560x1600 PNG，3,905,973 B

# 端口
PS> Get-NetTCPConnection -State Listen | ? LocalPort -in 62492,8326,8080,5432,6379
62492 127.0.0.1 PID 22960 (DeepSeek Harness)
8326  127.0.0.1 PID 22960 (DeepSeek Harness)
8080/5432/6379 -> 无监听（空闲）

# DSH
PS> (Get-Item 'C:\Users\user\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe').VersionInfo
FileVersion: 0.2.1-rc.5   ProductVersion: 0.2.1.0
PS> dsh --version
0.2.1-rc.5
PS> Invoke-WebRequest http://127.0.0.1:62492/
HTTP 401（服务在跑，需鉴权）

# WSL / RDP / 证书
PS> Get-CimInstance Win32_OptionalFeature -Filter "Name='Microsoft-Windows-Subsystem-Linux'"
InstallState=2（未安装）
PS> Get-Service TermService | Select Status,StartType
Stopped / Manual
PS> Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections
fDenyTSConnections=1
PS> (Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert).Count
0

# 网络
PS> netsh winhttp show proxy
Direct access (no proxy server).
PS> TCP 443: repo.maven.apache.org / services.gradle.org / dl.google.com / pub.dev /
           registry.npmjs.org / registry.npmmirror.com / start.spring.io / marketplace.visualstudio.com = OK
           github.com = 曾 TIMEOUT，后续 HTTPS 直连 200（不稳定）

# Flutter 官方 Windows 清单（HTTP 200，271,531 B）
PS> Invoke-RestMethod https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json
current stable = 3.47.9 / dart 3.13.7 / archive = stable/windows/flutter_windows_3.47.9-stable.zip
PS> HEAD 该 zip -> 200, Content-Length=1,939,451,626

# Maven Central（HTTP 200）
spring-boot maven-metadata.xml: latest=4.2.0-RC1；3.5.x 最新=3.5.16
```

---

## 附录 B：本次产出物与复测方法

| 产出物 | 说明 |
| --- | --- |
| `docs/research/ENVIRONMENT_REPORT.md` | 本报告 |
| `tools/env/check_env.ps1` | 只读环境探测脚本（本次运行 20.7 秒，exit 0） |
| `tools/env/setup_dev_env.ps1` | 用户级环境变量建议脚本（默认只打印；`-Apply -Force` 才写 HKCU） |
| `tools/env/README.md` | 脚本使用说明与安全边界 |
| `tools/env/out/check_env_full_20261031_113024.txt` | 本次全量探测原始输出（197 行），报告证据来源 |

**调查副作用声明（如实记录）：**

- `corepack pnpm --version` 首次运行在 corepack 缓存目录下载了 pnpm 12.16.1（仅写入用户缓存，**未修改系统配置/环境变量**；本机原本无 pnpm 独立安装）。此为探测命令的自动行为，特此披露。
- 模拟器启动测试使用 headless 方式，验证完成后已停止进程并执行 `adb kill-server`；FFmpeg 抓屏/编码测试的临时文件位于 `%TEMP%`，测试后已删除。
- `check_env.ps1` 仅在**当前进程内**临时设置 `JAVA_HOME`/`ANDROID_HOME`/`ANDROID_SDK_ROOT` 供 sdkmanager/gradle 探测，进程退出即失效；不写注册表、不改 PATH、不装软件。

**复测方法：**

```powershell
# 只读复测（推荐）：输出到 tools/env/out/
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\env\check_env.ps1 `
  | Out-File -Encoding utf8 .\tools\env\out\check_env_$(Get-Date -Format yyyyMMdd_HHmmss).txt

# 快速复测（跳过外网）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\env\check_env.ps1 -SkipNetwork
```

> 注意：这些脚本只在**当前进程内**临时设置 `JAVA_HOME`/`ANDROID_HOME` 供探测，进程退出即消失；不会写注册表、不装软件、不改 PATH。

---

## 附录 C：与已产出设计文档的对齐 / 需要回写的事项

| 设计文档 | 内容 | 本机实测 | 结论 / 建议 |
| --- | --- | --- | --- |
| `docs/design/PROTOCOL.md` L52 | 本地开发 `http://127.0.0.1:8080`、`ws://127.0.0.1:8080/ws/v1/...` | 8080 空闲 | ✅ 一致，可直接用 |
| `docs/design/REMOTE_AGENT.md` L22 | Agent 与 Harness 同机、只出站 WSS、不开入站端口 | DSH 62492 仅 loopback；出站 443 通；家庭 NAT | ✅ 与现状一致 |
| `docs/design/REMOTE_AGENT.md` L29 / ADR-PROTO-010 | 屏幕采集 MVP：ffmpeg gdigrab → MJPEG → WSS 二进制帧 12fps 自适应 | gdigrab 可用；**MJPEG 1280 宽 10fps 实测约 13 Mbps，全帧 12fps 约 36 Mbps**；H.264 约 3 Mbps、NVENC 约 1.8 Mbps | ⚠ 建议复核：公网/4G 下 MJPEG 带宽不可接受，优先 H.264/自适应，MJPEG 仅 LAN/演示 |
| `docs/design/DATA_MODEL.md` L40 | Flyway 迁移、V{版本}__{描述}.sql、PG 枚举 VARCHAR+CHECK | PG 未安装；Flyway 未验证 | ⚠ 需 PG 就绪后验证迁移脚本 |
| `docs/design/REMOTE_AGENT.md` L71 / ADR-PROTO-004 | PostgreSQL / Redis；文件走云端中继非 P2P（不做 TURN） | PG/Redis 均未装；无 TURN | 🟡 与现状一致（缺 DB）；WebRTC P2 顺延 |
| `docs/concept/项目构思方案_v0.1.md` L48 | 需用户拍板 5 件事 | 均未拍板 | 🔴 阻塞阶段 5–7，建议本周确认 |
| `docs/concept/项目构思方案_v0.1.md` L146 | 云服务器估 ¥60–120/月（2C4G 1M） | 无云资源 | 外部采购项 |
| 全项目 | 真实调用 Harness、不模拟 | DSH 0.2.1-rc.5 运行中、CLI 可用 | ✅ 集成路径通（headless 调用方式由 `tools/harness_probe/` 任务验证） |

---

*报告结束。本报告所有「具备」结论均来自 2026-10-31 的实测命令输出；所有「未验证」项已显式标注，未做任何安装或系统修改。*
