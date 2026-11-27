#requires -version 5.1
<#
.SYNOPSIS
    DeepSeek Remote AI — 开发环境只读探测脚本

.DESCRIPTION
    仅做只读探测：打印操作系统、硬件、环境变量、工具链版本、Android SDK 包、
    DSH 安装信息、数据库/中间件、打包链、端口占用、WSL/RDP/代码签名证书、
    外部网络连通性。
    不安装任何软件、不修改系统设置、不写持久化环境变量、不修改 DSH 安装目录。
    唯一副作用：在当前 PowerShell 进程内临时设置 JAVA_HOME / ANDROID_HOME /
    ANDROID_SDK_ROOT，以便调用 sdkmanager/gradle 做探测（进程退出即消失）。

.PARAMETER SkipNetwork
    跳过 TCP 443 连通性测试（离线或快速探测时使用）。

.EXAMPLE
    .\check_env.ps1
    .\check_env.ps1 -SkipNetwork | Out-File -Encoding utf8 .\out\check_env.txt
#>
[CmdletBinding()]
param(
    [switch]$SkipNetwork
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Write-Head([string]$title) {
    Write-Output ""
    Write-Output ("## " + $title)
}
function Write-Pair([string]$label, $value) {
    if ($null -eq $value -or "$value" -eq "") { $value = '(empty)' }
    Write-Output ("  {0,-24} {1}" -f ($label + ':'), $value)
}
function Invoke-Capture([string]$exePath, [string[]]$argList) {
    # 统一用 cmd /c 调用：避免 PowerShell 5.1 把原生 stderr 变成被
    # $ErrorActionPreference='SilentlyContinue' 吞掉的 ErrorRecord（java/dotnet 会因此“无输出”）。
    if ($null -eq $argList) { $argList = @() }
    $cmdLine = '"' + $exePath + '"'
    foreach ($a in $argList) {
        if ($a -match '[\s"]') { $cmdLine += ' "' + ($a -replace '"', '\"') + '"' } else { $cmdLine += ' ' + $a }
    }
    return (cmd /c ($cmdLine + ' 2>&1') | Out-String)
}
function Write-CapturedLines([string]$label, [string]$out, [int]$MaxLines) {
    $lines = @($out -split "`r?`n" | Where-Object { $_.Trim() -ne '' -and $_.Trim() -notmatch '^-{5,}$' } | Select-Object -First $MaxLines)
    if ($lines.Count -eq 0) { Write-Pair $label '(no output)' ; return }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq 0) { Write-Pair $label $lines[$i].Trim() } else { Write-Output ('  ' + (' ' * 24) + $lines[$i].Trim()) }
    }
}
function Probe-Exe([string]$label, [string]$exePath, [string[]]$argList, [int]$MaxLines = 1) {
    if (-not (Test-Path -LiteralPath $exePath)) {
        Write-Pair $label ("MISSING (" + $exePath + ")")
        return
    }
    $out = Invoke-Capture $exePath $argList
    Write-CapturedLines $label $out $MaxLines
}
function Probe-Cmd([string]$label, [string]$name, [string[]]$argList) {
    # 用裸命令名 + cmd 解析 PATH：本机 PATH 含裸 "D:\"，PowerShell 会把 npm/npx
    # 解析为 D:\npm.ps1 / D:\npx.ps1（ExternalScript），直接按路径调用不可靠。
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $c) { Write-Pair $label 'MISSING (not in PATH)'; return }
    if ($null -eq $argList) { $argList = @() }
    $cmdLine = $name
    foreach ($a in $argList) {
        if ($a -match '[\s"]') { $cmdLine += ' "' + ($a -replace '"', '\"') + '"' } else { $cmdLine += ' ' + $a }
    }
    $out = cmd /c ($cmdLine + ' 2>&1') | Out-String
    Write-CapturedLines $label $out 1
}
function Test-TcpPort([string]$hostName, [int]$port, [int]$timeoutMs = 1500) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($hostName, $port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)) {
            $client.EndConnect($iar)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

Write-Output "# DeepSeek Remote AI — 环境探测报告（check_env.ps1，只读）"
Write-Pair 'ProbeTime' ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
Write-Pair 'Computer' $env:COMPUTERNAME
Write-Pair 'User' ($env:USERDOMAIN + '\' + $env:USERNAME)
Write-Pair 'WorkingDir' (Get-Location).Path

# ---------------------------------------------------------------- 1. 系统与硬件
Write-Head '1. System / Hardware'
$os   = Get-CimInstance Win32_OperatingSystem
$cs   = Get-CimInstance Win32_ComputerSystem
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
Write-Pair 'OS' ($os.Caption + ' / version ' + $os.Version + ' build ' + $os.BuildNumber + ' / ' + $os.OSArchitecture)
Write-Pair 'Machine' (($cs.Manufacturer + ' ' + $cs.Model).Trim())
if ($cpu) {
    Write-Pair 'CPU' ($cpu.Name.Trim() + ' / ' + $cpu.NumberOfCores + ' cores / ' + $cpu.NumberOfLogicalProcessors + ' threads')
}
Write-Pair 'RAM' ([string]([math]::Round($cs.TotalPhysicalMemory / 1GB, 2)) + ' GB')
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Pair 'IsAdmin' $isAdmin
Write-Pair 'PowerShell' $PSVersionTable.PSVersion.ToString()
Write-Pair 'LastBoot' $os.LastBootUpTime
foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.DeviceID -eq 'C:' -or $_.DeviceID -eq 'D:' })) {
    Write-Pair ('Disk ' + $d.DeviceID) ([string]([math]::Round($d.Size / 1GB, 1)) + ' GB total / ' + [string]([math]::Round($d.FreeSpace / 1GB, 1)) + ' GB free')
}
$gpu = Get-CimInstance Win32_VideoController
foreach ($g in $gpu) { Write-Pair 'GPU' ($g.Name + ' / driver ' + $g.DriverVersion) }

# ---------------------------------------------------------------- 2. 环境变量
Write-Head '2. Environment variables'
foreach ($n in @('JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'FLUTTER_ROOT', 'GRADLE_HOME', 'MAVEN_HOME', 'M2_HOME', 'PNPM_HOME', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'PUB_HOSTED_URL', 'FLUTTER_STORAGE_BASE_URL')) {
    $v = [Environment]::GetEnvironmentVariable($n, 'Process')
    if (-not $v) { $v = '(unset)' }
    Write-Pair $n $v
}
Write-Output '  PATH entries:'
foreach ($p in ($env:Path -split ';')) {
    if ($p.Trim() -ne '') { Write-Output ('    ' + $p.Trim()) }
}

# ---------------------------------------------------------------- 3. Java
Write-Head '3. Java / JDK'
$jdkCandidates = @()
if ($env:JAVA_HOME) { $jdkCandidates += $env:JAVA_HOME }
$jdkCandidates += @(Get-ChildItem -LiteralPath 'C:\Users\user\dsh-tools\jdk' -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object { $_.FullName })
$jdk = $null
foreach ($candidate in $jdkCandidates) {
    if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'bin\java.exe'))) { $jdk = $candidate; break }
}
if ($jdk) {
    $env:JAVA_HOME = $jdk   # 仅当前进程
    Write-Pair 'JDK root' $jdk
    Probe-Exe 'java' (Join-Path $jdk 'bin\java.exe') @('-version') -MaxLines 3
    Probe-Exe 'javac' (Join-Path $jdk 'bin\javac.exe') @('-version') -MaxLines 1
} else {
    Write-Pair 'JDK' 'NOT FOUND (no JAVA_HOME, no C:\Users\user\dsh-tools\jdk\*)'
}
Probe-Cmd 'mvn' 'mvn' @('-version')

# ---------------------------------------------------------------- 4. Android SDK
Write-Head '4. Android SDK / Emulator'
$sdkCandidates = @()
if ($env:ANDROID_HOME) { $sdkCandidates += $env:ANDROID_HOME }
if ($env:ANDROID_SDK_ROOT) { $sdkCandidates += $env:ANDROID_SDK_ROOT }
$sdkCandidates += 'C:\Users\user\dsh-tools\android-sdk'
$sdk = $null
foreach ($candidate in $sdkCandidates) {
    if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'platform-tools\adb.exe'))) { $sdk = $candidate; break }
}
if ($sdk) {
    $env:ANDROID_HOME = $sdk         # 仅当前进程
    $env:ANDROID_SDK_ROOT = $sdk     # 仅当前进程
    Write-Pair 'Android SDK root' $sdk
    Probe-Exe 'adb' (Join-Path $sdk 'platform-tools\adb.exe') @('version')
    Probe-Exe 'emulator version' (Join-Path $sdk 'emulator\emulator.exe') @('-version')
    Probe-Exe 'emulator accel' (Join-Path $sdk 'emulator\emulator.exe') @('-accel-check') -MaxLines 5
    $avdList = & (Join-Path $sdk 'emulator\emulator.exe') '-list-avds' 2>&1 | Out-String
    $avds = @($avdList -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    Write-Pair 'AVDs' (($avds -join ', '))
    $sdkManager = Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
    if (Test-Path -LiteralPath $sdkManager) {
        $smRaw = & $sdkManager '--list_installed' 2>&1 | Out-String
        $smLines = @($smRaw -split "`r?`n" | Where-Object { $_ -match '\S' })
        Write-Output '  Installed packages (sdkmanager --list_installed):'
        foreach ($l in ($smLines | Select-Object -First 20)) { Write-Output ('    ' + $l.Trim()) }
    } else {
        Write-Pair 'sdkmanager' 'MISSING'
    }
} else {
    Write-Pair 'Android SDK' 'NOT FOUND'
}
Probe-Cmd 'flutter' 'flutter' @('--version')

# ---------------------------------------------------------------- 5. 其他开发工具
Write-Head '5. Other dev toolchains'
Probe-Cmd 'node' 'node' @('--version')
Probe-Cmd 'npm' 'npm' @('--version')
Probe-Cmd 'npx' 'npx' @('--version')
Probe-Cmd 'corepack' 'corepack' @('--version')
Probe-Cmd 'pnpm' 'pnpm' @('--version')
Probe-Cmd 'git' 'git' @('--version')
Probe-Cmd 'python' 'python' @('--version')
Probe-Cmd 'pip' 'pip' @('--version')
Probe-Cmd 'cargo' 'cargo' @('--version')
Probe-Cmd 'rustc' 'rustc' @('--version')
Probe-Cmd 'dotnet runtimes' 'dotnet' @('--list-runtimes')

Write-Output '  dotnet SDKs:'
$dotnetSdks = & dotnet --list-sdks 2>&1 | Out-String
if ($dotnetSdks.Trim() -eq '') { Write-Output '    (none)' } else { $dotnetSdks.Trim() -split "`r?`n" | ForEach-Object { Write-Output ('    ' + $_) } }
Probe-Cmd 'winget' 'winget' @('--version')
$cloudflared = (Get-Command 'cloudflared' -ErrorAction SilentlyContinue).Source
if (-not $cloudflared -and (Test-Path -LiteralPath 'C:\Users\user\dsh-tools\cloudflared.exe')) { $cloudflared = 'C:\Users\user\dsh-tools\cloudflared.exe' }
if ($cloudflared) { Probe-Exe 'cloudflared' $cloudflared @('--version') -MaxLines 2 } else { Write-Pair 'cloudflared' 'MISSING' }

# ---------------------------------------------------------------- 6. Gradle
Write-Head '6. Gradle'
$gradleBat = Get-ChildItem -LiteralPath 'C:\Users\user\.gradle\wrapper\dists' -Recurse -Filter 'gradle.bat' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($gradleBat) {
    Probe-Exe 'gradle' $gradleBat.FullName @('--version') -MaxLines 8
} else {
    Write-Pair 'gradle' 'MISSING (no wrapper dist found under C:\Users\user\.gradle\wrapper\dists)'
}

# ---------------------------------------------------------------- 7. C/C++ 打包链
Write-Head '7. Windows build / packaging chain'
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path -LiteralPath $vswhere) {
    $vsPath = (& $vswhere -latest -products * -property installationPath 2>&1 | Out-String).Trim()
    Write-Pair 'VS BuildTools' $vsPath
    if ($vsPath) {
        $msbuild = Join-Path $vsPath 'MSBuild\Current\Bin\MSBuild.exe'
        Probe-Exe 'MSBuild' $msbuild @('-version', '-nologo')
        $cl = Get-ChildItem -LiteralPath (Join-Path $vsPath 'VC\Tools\MSVC') -Recurse -Filter 'cl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cl) { Write-Pair 'MSVC cl.exe' $cl.FullName } else { Write-Pair 'MSVC cl.exe' 'MISSING' }
    }
} else {
    Write-Pair 'vswhere' 'MISSING'
}
$winSdkRoot = 'C:\Program Files (x86)\Windows Kits\10'
if (Test-Path -LiteralPath $winSdkRoot) {
    $kitVer = @(Get-ChildItem -LiteralPath (Join-Path $winSdkRoot 'Include') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object { $_.Name })
    Write-Pair 'Windows SDK' ('root ' + $winSdkRoot + ' / newest Include ' + ($kitVer -join ''))
    $signtool = Get-ChildItem -LiteralPath (Join-Path $winSdkRoot 'bin') -Recurse -Filter 'signtool.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($signtool) { Write-Pair 'signtool' $signtool.FullName } else { Write-Pair 'signtool' 'MISSING' }
} else {
    Write-Pair 'Windows SDK' 'MISSING'
}
$nsis = 'C:\Users\user\AppData\Local\tauri\NSIS\makensis.exe'
if (Test-Path -LiteralPath $nsis) {
    Probe-Exe 'NSIS makensis' $nsis @('/VERSION')
} else {
    Write-Pair 'NSIS makensis' 'MISSING'
}
Probe-Cmd 'cmake' 'cmake' @('--version')
if (Test-Path -LiteralPath 'D:\soft\7za.exe') { Probe-Exe '7-Zip' 'D:\soft\7za.exe' @('i') -MaxLines 3 } else { Probe-Cmd '7-Zip' '7z' @('i') }

# ---------------------------------------------------------------- 8. ffmpeg
Write-Head '8. FFmpeg (remote desktop / screen capture)'
$ffmpeg = $null
$knownFfmpeg = @(
    'D:\soft\MiniMax Design\current\resources\ffmpeg\ffmpeg.exe',
    'D:\soft\steam\steamapps\common\A Dance of Fire and Ice\ffmpeg\ffmpeg.exe',
    "$env:APPDATA\bilibili\ffmpeg\ffmpeg.exe"
)
$cmd = Get-Command 'ffmpeg' -ErrorAction SilentlyContinue
if ($cmd) { $ffmpeg = $cmd.Source }
if (-not $ffmpeg) {
    foreach ($k in $knownFfmpeg) { if (Test-Path -LiteralPath $k) { $ffmpeg = $k; break } }
}
if ($ffmpeg) {
    Write-Pair 'ffmpeg path' $ffmpeg
    Probe-Exe 'ffmpeg version' $ffmpeg @('-hide_banner', '-version')
    $devOut = & $ffmpeg '-hide_banner' '-devices' 2>&1 | Out-String
    $hasGdi = ($devOut -match 'gdigrab')
    Write-Pair 'gdigrab device' $hasGdi
    $encOut = & $ffmpeg '-hide_banner' '-encoders' 2>&1 | Out-String
    Write-Pair 'libx264 encoder' ([bool]($encOut -match 'libx264'))
    Write-Pair 'h264_nvenc encoder' ([bool]($encOut -match 'h264_nvenc'))
    Write-Pair 'mjpeg encoder' ([bool]($encOut -match '\bmjpeg\b'))
} else {
    Write-Pair 'ffmpeg' 'NOT FOUND (no PATH entry, no known bundle path)'
}

# ---------------------------------------------------------------- 9. 数据库与中间件
Write-Head '9. Database / Middleware'
Probe-Cmd 'psql' 'psql' @('--version')
Probe-Cmd 'mysql' 'mysql' @('--version')
Probe-Cmd 'redis-server' 'redis-server' @('--version')
Probe-Cmd 'docker' 'docker' @('--version')
$wslExe = 'C:\Windows\System32\wsl.exe'
if (Test-Path -LiteralPath $wslExe) {
    Write-Output '  wsl --status: 输出为 UTF-16，管道读取会乱码；以 Win32_OptionalFeature 的 InstallState 为准（见下）'
} else {
    Write-Pair 'wsl.exe' 'MISSING'
}
foreach ($svc in @('postgresql*', 'mysql*', 'redis*', 'memurai*', 'docker*', 'com.docker*', 'vmms')) {
    $found = Get-Service -Name $svc -ErrorAction SilentlyContinue
    foreach ($s in $found) { Write-Pair ('Service ' + $s.Name) ($s.Status.ToString() + ' / ' + $s.StartType.ToString()) }
}
foreach ($feat in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform', 'Microsoft-Hyper-V-All')) {
    $f = Get-CimInstance Win32_OptionalFeature -Filter ("Name='" + $feat + "'") -ErrorAction SilentlyContinue
    if ($f) { Write-Pair ('Feature ' + $feat) ('InstallState=' + $f.InstallState) }
}

# ---------------------------------------------------------------- 10. DSH
Write-Head '10. DeepSeek Harness (DSH)'
$dshExe = 'C:\Users\user\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe'
if (Test-Path -LiteralPath $dshExe) {
    $vi = (Get-Item -LiteralPath $dshExe).VersionInfo
    Write-Pair 'DSH exe' ($dshExe)
    Write-Pair 'FileVersion' $vi.FileVersion
    Write-Pair 'ProductVersion' $vi.ProductVersion
    Write-Pair 'CompanyName' $vi.CompanyName
    $verFile = Join-Path (Split-Path $dshExe) 'resources\version'
    if (Test-Path -LiteralPath $verFile) { Write-Pair 'resources\version' ((Get-Content -LiteralPath $verFile -Raw).Trim()) }
} else {
    Write-Pair 'DSH exe' 'MISSING'
}
Probe-Cmd 'dsh CLI' 'dsh' @('--version')
$dshProcs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
Write-Pair 'DSH processes' ($dshProcs.Count.ToString())

# ---------------------------------------------------------------- 11. 端口占用
Write-Head '11. Port usage (listen)'
$watchPorts = @(62492, 8326, 8080, 8081, 8443, 5432, 6379, 3306, 27017, 3000, 5173, 9229, 8765, 18787, 7897, 53)
$listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue
foreach ($p in $watchPorts) {
    $hit = @($listeners | Where-Object { $_.LocalPort -eq $p })
    if ($hit.Count -eq 0) {
        Write-Pair ('port ' + $p) 'FREE'
    } else {
        $descs = @()
        foreach ($h in ($hit | Select-Object -First 3)) {
            $procName = ''
            $pr = Get-Process -Id $h.OwningProcess -ErrorAction SilentlyContinue
            if ($pr) { $procName = $pr.ProcessName }
            $descs += ($h.LocalAddress + ':' + $h.LocalPort + ' <- pid ' + $h.OwningProcess + ' (' + $procName + ')')
        }
        Write-Pair ('port ' + $p) ('LISTEN ' + ($descs -join ' ; '))
    }
}

# ---------------------------------------------------------------- 12. RDP / 证书
Write-Head '12. RDP / code-signing certificate'
$ts = Get-Service -Name TermService -ErrorAction SilentlyContinue
if ($ts) { Write-Pair 'TermService' ($ts.Status.ToString() + ' / ' + $ts.StartType.ToString()) }
$rdpDeny = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue
if ($rdpDeny) { Write-Pair 'fDenyTSConnections' $rdpDeny.fDenyTSConnections }
$certs = @(Get-ChildItem -Path 'Cert:\CurrentUser\My' -CodeSigningCert -ErrorAction SilentlyContinue)
Write-Pair 'CodeSigning cert (CurrentUser)' ($certs.Count.ToString() + ' found')

# ---------------------------------------------------------------- 13. 网络
Write-Head '13. Network / proxy'
$winhttp = & netsh winhttp show proxy 2>&1 | Out-String
Write-Output ('  winhttp proxy: ' + (($winhttp -split "`r?`n" | Where-Object { $_.Trim() -ne '' }) -join ' | '))
Probe-Cmd 'git config proxy' 'git' @('config', '--global', '--get', 'http.proxy')
$npmProxy = & npm config get proxy 2>&1 | Out-String
$npmHttps = & npm config get https-proxy 2>&1 | Out-String
Write-Pair 'npm proxy' $npmProxy.Trim()
Write-Pair 'npm https-proxy' $npmHttps.Trim()
$npmReg = & npm config get registry 2>&1 | Out-String
Write-Pair 'npm registry' $npmReg.Trim()
$pipCfg = & pip config get global.index-url 2>&1 | Out-String
Write-Pair 'pip index-url' $pipCfg.Trim()
if (-not $SkipNetwork) {
    Write-Output '  TCP 443 reachability:'
    foreach ($h in @('repo.maven.apache.org', 'services.gradle.org', 'dl.google.com', 'storage.googleapis.com', 'pub.dev', 'registry.npmjs.org', 'registry.npmmirror.com', 'github.com', 'start.spring.io', 'marketplace.visualstudio.com')) {
        $ok = Test-TcpPort -hostName $h -port 443
        Write-Output ('    {0,-32} {1}' -f $h, $(if ($ok) { 'OK' } else { 'FAIL' }))
    }
}

# ---------------------------------------------------------------- 14. 缺口摘要
Write-Head '14. Key gaps (auto-detected)'
$gap = @()
if (-not (Get-Command 'flutter' -ErrorAction SilentlyContinue)) { $gap += 'Flutter SDK: MISSING' } else { $gap += 'Flutter SDK: present' }
if (-not $env:JAVA_HOME) { $gap += 'JAVA_HOME: unset (JDK detected: ' + [bool]$jdk + ')' }
if (-not $env:ANDROID_HOME) { $gap += 'ANDROID_HOME: unset (SDK detected: ' + [bool]$sdk + ')' }
if (-not (Get-Command 'psql' -ErrorAction SilentlyContinue)) { $gap += 'PostgreSQL: no psql client' }
if (-not (Get-Command 'redis-server' -ErrorAction SilentlyContinue)) { $gap += 'Redis: no redis-server' }
if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) { $gap += 'Docker: MISSING' }
$wslFeat = Get-CimInstance Win32_OptionalFeature -Filter "Name='Microsoft-Windows-Subsystem-Linux'" -ErrorAction SilentlyContinue
if ($wslFeat) { $gap += ('WSL feature InstallState=' + $wslFeat.InstallState) }
if ($certs.Count -eq 0) { $gap += 'Code-signing cert: NONE' }
if (-not (Get-Command 'cmake' -ErrorAction SilentlyContinue)) { $gap += 'CMake: MISSING' }
if (-not (Get-Command 'mvn' -ErrorAction SilentlyContinue)) { $gap += 'Maven: MISSING (use Gradle or mvnw)' }
foreach ($g in $gap) { Write-Output ('  - ' + $g) }

Write-Output ''
Write-Output '# End of report (read-only probe; nothing was installed or persisted)'
