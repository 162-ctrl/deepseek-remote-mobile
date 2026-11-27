# tools/env — 环境调查与配置辅助脚本

本目录是《DeepSeek Remote AI》第 1 阶段「环境调查」的产出。所有脚本均为**只读探测**或**只打印建议命令**，不会安装软件、不会修改系统配置、不会修改 DSH 安装目录。环境调查报告见 [`docs/research/ENVIRONMENT_REPORT.md`](../../docs/research/ENVIRONMENT_REPORT.md)。

## 文件说明

| 文件 | 作用 | 是否修改系统 |
| --- | --- | --- |
| `check_env.ps1` | 只读探测：系统/硬件、环境变量、JDK、Android SDK、Flutter、Node/npm、Gradle、MSVC/Windows SDK/NSIS、FFmpeg、数据库/中间件、WSL、DSH、端口占用、RDP/代码签名证书、网络连通性。输出 Markdown 风格纯文本。 | 否（仅当前进程内临时设置 JAVA_HOME/ANDROID_HOME 供探测） |
| `setup_dev_env.ps1` | 打印本机推荐的**用户级**环境变量与 PATH 设置命令；带 `-Apply -Force` 时可写入当前用户环境变量（无需管理员），但不安装任何软件。 | 默认否；仅显式 `-Apply -Force` 时写 HKCU 环境变量 |
| `out/` | 探测输出存档（用于报告取证，命令与原始输出一一对应）。 | 否 |

## 快速使用

```powershell
# 1) 只读探测，结果同时存档（推荐）
powershell -NoProfile -ExecutionPolicy Bypass -File .\check_env.ps1 `
  | Out-File -Encoding utf8 .\out\check_env_$(Get-Date -Format yyyyMMdd_HHmm).txt

# 2) 快速模式（跳过外网 TCP 探测）
.\check_env.ps1 -SkipNetwork

# 3) 查看环境变量建议（只打印，不修改）
.\setup_dev_env.ps1

# 4) 用户知情后，自行写入用户级环境变量（可选，需显式 -Force）
.\setup_dev_env.ps1 -Apply -Force
```

> Windows PowerShell 5.1 若提示禁止运行脚本，请在本窗口内使用：
> `Set-ExecutionPolicy -Scope Process Bypass`（仅当前窗口生效），或用上面的
> `powershell -NoProfile -ExecutionPolicy Bypass -File` 方式调用。

## 本机关键事实（2026-10-31 实测，详见报告）

- JDK 21（Temurin 21.0.12.1+1 LTS）已存在但未配置：`C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1`
- Android SDK 已存在但未配置：`C:\Users\user\dsh-tools\android-sdk`（build-tools 35/36、platform android-36、AVD `timebook_test`）
- **Flutter SDK 缺失**：需下载 Flutter 3.47.9 stable（Windows zip，约 1.81GB）解压到 ASCII 路径（如 `C:\dev\flutter`）
- `JAVA_HOME`、`ANDROID_HOME`、`ANDROID_SDK_ROOT`、`FLUTTER_ROOT` 均未设置；PATH 里没有 java/adb/gradle/flutter
- 无 PostgreSQL / Redis / Docker / WSL；无代码签名证书
- FFmpeg 无独立安装，但本机第三方 bundle 中可用（gdigrab 抓屏实测成功）；正式分发需自备官方构建
- 模拟器无头启动实测成功（WHPX 加速可用）

## 生成这份数据的命令

见报告附录 A。核心调用：

```powershell
# 后台无头启动模拟器并验证启动完成
Start-Process -FilePath C:\Users\user\dsh-tools\android-sdk\emulator\emulator.exe `
  -ArgumentList '-avd','timebook_test','-no-window','-no-audio','-no-boot-anim','-no-snapshot','-gpu','swiftshader_indirect' -PassThru
adb shell getprop sys.boot_completed   # -> 1
```

## 注意

- 不要在本机直接执行 `winget install` / `choco install` / 安装包等未与用户确认的操作。
- 环境变量配置脚本仅写当前用户（HKCU），不要改写机器级（System）变量。
- 项目目录名含中文（`<项目根>`），实测 Gradle 曾在此类路径完成构建；但 Flutter SDK、构建缓存、临时目录建议使用纯 ASCII 路径以规避工具链兼容问题。
