#requires -version 5.1
<#
.SYNOPSIS
    DeepSeek Remote AI — 用户级开发环境变量配置建议 / 可选手动应用

.DESCRIPTION
    本脚本默认【只打印】建议执行的命令，不做任何修改。
    只有显式传入 -Apply -Force 时，才会写入【当前用户】环境变量
    （HKCU\Environment，无需管理员），不触碰机器级变量、不安装任何软件。

    本机已确认 JDK 与 Android SDK 位于用户目录（2026-10-31 实测）：
      JDK:          C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1   (Temurin 21.0.12.1+1 LTS)
      Android SDK:  C:\Users\user\dsh-tools\android-sdk            (build-tools 35/36, platform android-36)
      Flutter:      【尚未安装】建议解压到 C:\dev\flutter（必须为 ASCII 路径）

.PARAMETER FlutterRoot
    Flutter SDK 解压目录（默认 C:\dev\flutter）。

.PARAMETER JdkHome
    JDK 根目录。

.PARAMETER AndroidSdk
    Android SDK 根目录。

.PARAMETER Apply
    真正写入当前用户环境变量。必须同时提供 -Force。

.PARAMETER Force
    与 -Apply 配合，跳过交互确认。

.EXAMPLE
    .\setup_dev_env.ps1
    .\setup_dev_env.ps1 -Apply -Force      # 需用户知情后自行执行
#>
[CmdletBinding()]
param(
    [string]$FlutterRoot = 'C:\dev\flutter',
    [string]$JdkHome = 'C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1',
    [string]$AndroidSdk = 'C:\Users\user\dsh-tools\android-sdk',
    [switch]$Apply,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Write-Output '# DeepSeek Remote AI — 用户级环境变量建议（setup_dev_env.ps1，默认只打印）'
Write-Output ''
Write-Output '## 1. 探测到的路径状态'
$javaExe = Join-Path $JdkHome 'bin\java.exe'
$adbExe  = Join-Path $AndroidSdk 'platform-tools\adb.exe'
$flutterBat = Join-Path $FlutterRoot 'bin\flutter.bat'
Write-Output ('  JDK (' + $JdkHome + ')            : ' + $(if (Test-Path -LiteralPath $javaExe) { 'OK' } else { 'MISSING' }))
Write-Output ('  Android SDK (' + $AndroidSdk + ')  : ' + $(if (Test-Path -LiteralPath $adbExe) { 'OK' } else { 'MISSING' }))
Write-Output ('  Flutter (' + $FlutterRoot + ')        : ' + $(if (Test-Path -LiteralPath $flutterBat) { 'OK' } else { 'MISSING — 需先下载解压 Flutter SDK（见报告 7.1）' }))

$vars = [ordered]@{
    'JAVA_HOME'         = $JdkHome
    'ANDROID_HOME'      = $AndroidSdk
    'ANDROID_SDK_ROOT'  = $AndroidSdk
}
$pathEntries = @(
    (Join-Path $JdkHome 'bin'),
    (Join-Path $AndroidSdk 'platform-tools'),
    (Join-Path $AndroidSdk 'emulator'),
    (Join-Path $AndroidSdk 'cmdline-tools\latest\bin'),
    (Join-Path $AndroidSdk 'build-tools\36.0.0'),
    (Join-Path $FlutterRoot 'bin')
)

Write-Output ''
Write-Output '## 2. 建议设置的用户级环境变量（当前值 -> 建议值）'
foreach ($k in $vars.Keys) {
    $cur = [Environment]::GetEnvironmentVariable($k, 'User')
    if (-not $cur) { $cur = '(unset)' }
    Write-Output ('  ' + $k.PadRight(18) + ' ' + $cur + '  ->  ' + $vars[$k])
}
Write-Output ''
Write-Output '## 3. 建议追加到【用户 PATH】的条目（不存在才追加）'
foreach ($p in $pathEntries) { Write-Output ('  + ' + $p) }

Write-Output ''
Write-Output '## 4. 等价的 PowerShell 命令（可复制到本机 PowerShell 手动执行）'
foreach ($k in $vars.Keys) {
    Write-Output ('  [Environment]::SetEnvironmentVariable("' + $k + '", "' + $vars[$k] + '", "User")')
}
$appendCode = @'
  $userPath = [Environment]::GetEnvironmentVariable("Path","User")
  $entries = @(
@' + (($pathEntries | ForEach-Object { '      "' + $_ + '"' }) -join ",`r`n") + @'
  )
  $parts = @($userPath -split ';' | Where-Object { $_.Trim() -ne '' })
  foreach ($e in $entries) { if ($parts -notcontains $e) { $parts += $e } }
  [Environment]::SetEnvironmentVariable("Path", ($parts -join ';'), "User")
'@
Write-Output $appendCode

Write-Output ''
Write-Output '## 5. 设置完成后的验证命令（新开一个终端窗口执行）'
Write-Output '  java -version'
Write-Output '  javac -version'
Write-Output '  adb version'
Write-Output '  emulator -list-avds          # 应输出 timebook_test'
Write-Output '  sdkmanager --list_installed'
Write-Output '  flutter --version'
Write-Output '  flutter doctor -v'
Write-Output '  flutter config --android-sdk "' + $AndroidSdk + '"'
Write-Output '  flutter config --jdk-dir "' + $JdkHome + '"'

Write-Output ''
Write-Output '## 6. 不会自动执行的安装项（请用户决策，见今日环境调查报告）'
Write-Output '  - Flutter SDK 3.47.9 stable（Windows zip 1.81GB，解压到 C:\dev\flutter）'
Write-Output '  - PostgreSQL（建议云托管；本机安装需管理员权限）'
Write-Output '  - Redis（可选；MVP 可先用内存降级）'
Write-Output '  - FFmpeg 官方构建（随 Remote Agent 分发，用于屏幕采集）'
Write-Output '  - VS Code Flutter/Dart 扩展'
Write-Output ''

if (-not $Apply) {
    Write-Output '未做任何修改（默认只打印）。确认无误后请用户自行执行，或使用: .\setup_dev_env.ps1 -Apply -Force'
    exit 0
}

if (-not $Force) {
    Write-Error '拒绝执行：-Apply 需要同时提供 -Force，且应仅由用户本人在知情后执行。'
    exit 1
}

Write-Output '## 7. 正在写入当前用户环境变量（不触碰机器级变量）'
foreach ($k in $vars.Keys) {
    [Environment]::SetEnvironmentVariable($k, $vars[$k], 'User')
    Write-Output ('  set ' + $k + ' = ' + $vars[$k])
}
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
$parts = @($userPath -split ';' | Where-Object { $_.Trim() -ne '' })
foreach ($e in $pathEntries) {
    if ($parts -notcontains $e) { $parts += $e }
}
[Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
Write-Output '  user PATH updated'
Write-Output ''
Write-Output '完成。请关闭并重新打开终端（或重新登录）后执行第 5 节验证命令。'
