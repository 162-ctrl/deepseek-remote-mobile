#requires -Version 5.1
<#
.SYNOPSIS
  M1 一键启动：Java 后端 + Cloudflare 隧道 + 电脑 Agent（可选 Android 模拟器）。

.DESCRIPTION
  按 docs/research/M1_E2E_REPORT.md §4 的三件套顺序启动，并把 PID / 隧道地址写到 .m1-state\state.json。
  重复执行会先检查已在运行的服务：8080 健康则跳过后端，隧道日志里已有地址则复用。

.PARAMETER WithEmulator
  同时启动 Android 模拟器（AVD timebook_test，无窗口）。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-up.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-up.ps1 -WithEmulator
#>
param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [switch]$WithEmulator,
  [int]$Port = 8080,
  [string]$PairingCode = '824613',
  [switch]$SkipDb,
  [string]$PgHome = 'C:\Users\user\dsh-tools\pgsql',
  [string]$PgData = 'C:\Users\user\dsh-tools\pgdata-deepseek',
  [int]$PgPort = 5433,
  [string]$JavaHome = 'C:\Users\user\dsh-tools\jdk\jdk-21.0.12.1+1',
  [string]$GradleBat = 'C:\Users\user\dsh-tools\gradle\gradle-8.14.3\bin\gradle.bat',
  [string]$AndroidHome = 'C:\Users\user\dsh-tools\android-sdk',
  [string]$AvdName = 'timebook_test',
  [string]$WorkspaceRoot = '',
  # 多个授权根（分号分隔），设置后优先于 -WorkspaceRoot；第一个作为默认工作区。
  [string]$WorkspaceRoots = ''
)
$ErrorActionPreference = 'Continue'

if (-not $WorkspaceRoots -and -not $WorkspaceRoot) { $WorkspaceRoot = Join-Path $Root 'agent\.m1ws' }
if (-not $WorkspaceRoots) { $WorkspaceRoots = $WorkspaceRoot } elseif (-not $WorkspaceRoot) { $WorkspaceRoot = ($WorkspaceRoots -split ';')[0] }
$stateDir = Join-Path $Root '.m1-state'
$logDir = Join-Path $stateDir 'logs'
New-Item -ItemType Directory -Force $stateDir, $logDir | Out-Null
$stateFile = Join-Path $stateDir 'state.json'
$cloudflared = Join-Path $Root 'tools\bin\cloudflared.exe'

function Say($msg) { Write-Host "[m1-up] $msg" }

function Test-Health {
  try {
    $h = Invoke-RestMethod "http://127.0.0.1:$Port/api/v1/health" -TimeoutSec 3
    return $h
  } catch { return $null }
}

# ---------- 0) PostgreSQL（便携版，默认不装系统服务） ----------
$dbPid = $null
if (-not $SkipDb) {
  $pgListening = Get-NetTCPConnection -LocalPort $PgPort -State Listen -ErrorAction SilentlyContinue
  if ($pgListening) {
    Say "PostgreSQL 已在运行（port $PgPort）"
  } else {
    $pgExe = Join-Path $PgHome 'bin\postgres.exe'
    if (-not (Test-Path $pgExe)) { throw "找不到便携版 PostgreSQL：$pgExe" }
    Say "启动 PostgreSQL（port $PgPort，数据目录 $PgData）…"
    $pgArgs = @('-D', $PgData, '-p', "$PgPort", '-c', 'listen_addresses=127.0.0.1')
    $p = Start-Process -FilePath $pgExe -ArgumentList $pgArgs -WindowStyle Hidden -PassThru
    $dbPid = $p.Id
    $deadline = (Get-Date).AddSeconds(40)
    $ok = $null
    while (-not $ok -and (Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 1
      $ok = Get-NetTCPConnection -LocalPort $PgPort -State Listen -ErrorAction SilentlyContinue
    }
    if (-not $ok) { throw "PostgreSQL 40s 内未就绪，检查 $PgData 与 5433 端口" }
    Say "PostgreSQL 就绪：127.0.0.1:$PgPort"
  }
}

# ---------- 1) 后端 ----------
$backendPid = $null
$already = Test-Health
if ($already -and $already.status -eq 'ok') {
  Say "后端已在运行（version=$($already.version), agentOnline=$($already.agentOnline)），跳过启动"
} else {
  if (-not (Test-Path $GradleBat)) { throw "找不到 Gradle：$GradleBat" }
  if (-not (Test-Path $JavaHome)) { throw "找不到 JDK：$JavaHome" }
  Say "启动后端（Spring Boot, port $Port）…"
  $beCmd = "`$env:JAVA_HOME='$JavaHome'; Set-Location '$Root\backend'; & '$GradleBat' bootRun --console=plain"
  $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$beCmd) `
        -RedirectStandardOutput (Join-Path $logDir 'backend.out.log') -RedirectStandardError (Join-Path $logDir 'backend.err.log') `
        -WindowStyle Hidden -PassThru
  $backendPid = $p.Id
  $deadline = (Get-Date).AddSeconds(240)
  $h = $null
  while (-not $h -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $h = Test-Health
  }
  if (-not $h) { throw "后端 240s 内未就绪，查看 $logDir\backend.*.log" }
  Say "后端就绪：version=$($h.version)"
}

# ---------- 2) 隧道 ----------
$tunnelUrl = $null
$tunnelPid = $null
if (-not (Test-Path $cloudflared)) { throw "找不到 cloudflared：$cloudflared" }
$tunnelLog = Join-Path $logDir 'tunnel.log'
if (Test-Path $tunnelLog) {
  $m = Select-String -Path $tunnelLog -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -List | Select-Object -First 1
  if ($m) { $tunnelUrl = [regex]::Match($m.Line, 'https://[a-z0-9-]+\.trycloudflare\.com').Value }
}
if ($tunnelUrl) {
  # 只有当旧地址真的还能打通时才复用（cloudflared 退出后日志里的地址会失效）
  $alive = $false
  try { $r = Invoke-WebRequest -UseBasicParsing -Uri "$tunnelUrl/api/v1/health" -TimeoutSec 10; if ($r.StatusCode -eq 200) { $alive = $true } } catch { }
  if (-not $alive) { Say "旧隧道地址已失效，重建隧道…"; $tunnelUrl = $null; Remove-Item $tunnelLog -Force -ErrorAction SilentlyContinue }
}
if ($tunnelUrl) {
  $tunnelPid = (Get-Process cloudflared -ErrorAction SilentlyContinue | Select-Object -First 1).Id
  Say "复用已有隧道地址：$tunnelUrl"
} else {
  Say "启动 Cloudflare 隧道…"
  Remove-Item $tunnelLog -Force -ErrorAction SilentlyContinue
  # 用 --logfile 让 cloudflared 自己把（含 URL 的）日志写到文件，避免 stdout 缓冲导致读不到地址
  $p = Start-Process -FilePath $cloudflared `
        -ArgumentList @('tunnel','--url',"http://127.0.0.1:$Port",'--no-autoupdate','--logfile',$tunnelLog,'--loglevel','info') `
        -WindowStyle Hidden -PassThru
  $tunnelPid = $p.Id
  $deadline = (Get-Date).AddSeconds(90)
  while (-not $tunnelUrl -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (Test-Path $tunnelLog) {
      $m = Select-String -Path $tunnelLog -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -List | Select-Object -First 1
      if ($m) { $tunnelUrl = [regex]::Match($m.Line, 'https://[a-z0-9-]+\.trycloudflare\.com').Value }
    }
  }
  if (-not $tunnelUrl) { throw "隧道 90s 内未分配地址，查看 $tunnelLog" }
  Say "隧道地址：$tunnelUrl"
}

# ---------- 3) Agent ----------
$agentPid = $null
$existingAgent = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*serve.ts*' } | Select-Object -First 1
if ($existingAgent) {
  Say "Agent 已在运行（pid=$($existingAgent.ProcessId)），跳过启动"
} else {
  Say "启动电脑 Agent（relay）…"
  $agCmd = @(
    "`$env:REMOTE_SERVER_URL='http://127.0.0.1:$Port'",
    "`$env:M1_PAIRING_CODE='$PairingCode'",
    "`$env:DEVICE_NAME='$env:COMPUTERNAME'",
    "`$env:M1_WORKSPACE_ROOT='$WorkspaceRoot'",
    "`$env:M1_WORKSPACE_ROOTS='$WorkspaceRoots'",
    "`$env:DSH_HOME='$env:USERPROFILE\.dsh'",
    "`$env:LOG_LEVEL='info'",
    "Set-Location '$Root\agent'",
    "& node scripts/serve.ts"
  ) -join '; '
  $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$agCmd) `
        -RedirectStandardOutput (Join-Path $logDir 'agent.out.log') -RedirectStandardError (Join-Path $logDir 'agent.err.log') `
        -WindowStyle Hidden -PassThru
  $agentPid = $p.Id
  $deadline = (Get-Date).AddSeconds(90)
  $online = $false
  while (-not $online -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $h = Test-Health
    if ($h -and $h.agentOnline) { $online = $true }
  }
  if (-not $online) { throw "Agent 90s 内未上线，查看 $logDir\agent.*.log" }
  Say "Agent 已连上后端"
}

# ---------- 4) 模拟器（可选） ----------
$emulatorPid = $null
if ($WithEmulator) {
  $adb = Join-Path $AndroidHome 'platform-tools\adb.exe'
  $emuExe = Join-Path $AndroidHome 'emulator\emulator.exe'
  $devices = & $adb devices 2>$null | Select-String 'emulator-\d+\s+device'
  if ($devices) {
    Say "模拟器已在线，跳过启动"
  } else {
    Say "启动 Android 模拟器 $AvdName（无窗口）…"
    $p = Start-Process -FilePath $emuExe -ArgumentList @('-avd',$AvdName,'-no-window','-no-audio','-no-boot-anim','-gpu','swiftshader_indirect','-no-snapshot-save') `
          -RedirectStandardOutput (Join-Path $logDir 'emulator.out.log') -RedirectStandardError (Join-Path $logDir 'emulator.err.log') `
          -WindowStyle Hidden -PassThru
    $emulatorPid = $p.Id
    $deadline = (Get-Date).AddSeconds(240)
    $boot = ''
    while ($boot -ne '1' -and (Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 5
      $bootRaw = & $adb shell getprop sys.boot_completed 2>$null
      $boot = if ($bootRaw) { ([string]$bootRaw).Trim() } else { '' }
    }
    if ($boot -ne '1') { Say "模拟器 240s 内未完成启动（可稍后用 adb devices 检查）" } else { Say "模拟器已启动（emulator-5554）" }
  }
}

# ---------- 状态文件 ----------
$state = [ordered]@{
  startedAt   = (Get-Date).ToString('o')
  port        = $Port
  tunnelUrl   = $tunnelUrl
  pairingCode = $PairingCode
  pgPort      = $PgPort
  dbPid       = $dbPid
  backendPid  = $backendPid
  tunnelPid   = $tunnelPid
  agentPid    = $agentPid
  emulatorPid = $emulatorPid
  workspace   = $WorkspaceRoot
  logDir      = $logDir
}
$state | ConvertTo-Json -Depth 3 | Set-Content -Path $stateFile -Encoding UTF8

# ---------- 汇总 ----------
$h = Test-Health
Say '================ 就绪 ================'
Say "数据库    127.0.0.1:$PgPort (PostgreSQL 16.10，持久化)"
Say "后端      http://127.0.0.1:$Port  (version=$($h.version))"
Say "隧道      $tunnelUrl"
Say "Agent     agentOnline=$($h.agentOnline)"
Say "配对码    $PairingCode"
Say "手机       服务器地址填上面的隧道 URL + 配对码；AI 助手右上角 ⇄"
Say "状态文件  $stateFile"
Say "日志目录  $logDir"
Say "停止服务  powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-down.ps1"
