#requires -Version 5.1
<#
.SYNOPSIS
  停止 M1 三件套（后端 / Cloudflare 隧道 / 电脑 Agent），可选保留后端。

.DESCRIPTION
  优先按 .m1-state\state.json 里的 PID 结束进程树；PID 缺失时按端口 8080 与进程名兜底。
  -KeepBackend  只停隧道和 Agent（后端继续跑，便于只换隧道地址）。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-down.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\m1-down.ps1 -KeepBackend
#>
param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [int]$Port = 8080,
  [switch]$KeepBackend,
  [switch]$KeepEmulator,
  [switch]$StopDb,
  [string]$PgHome = 'C:\Users\user\dsh-tools\pgsql'
)
$ErrorActionPreference = 'Continue'
$stateFile = Join-Path $Root '.m1-state\state.json'
function Say($msg) { Write-Host "[m1-down] $msg" }

function Stop-Tree([int]$procId, [string]$label) {
  if (-not $procId) { return }
  try {
    & taskkill.exe /F /T /PID $procId 2>&1 | Out-Null
    Say "已停止 $label (pid=$procId)"
  } catch {
    Say "停止 $label 失败：$($_.Exception.Message)"
  }
}

$state = $null
if (Test-Path $stateFile) {
  try { $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
}

if ($state) {
  Stop-Tree $state.tunnelPid '隧道'
  Stop-Tree $state.agentPid 'Agent'
  if (-not $KeepBackend) { Stop-Tree $state.backendPid '后端' }
  if ($state.emulatorPid -and -not $KeepEmulator) {
    Stop-Tree $state.emulatorPid '模拟器'
  }
}

# 兜底：按名字/端口清理
if (-not $KeepBackend) {
  $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  foreach ($c in $conns) {
    try { & taskkill.exe /F /T /PID $c.OwningProcess 2>&1 | Out-Null; Say "已释放端口 $Port (pid=$($c.OwningProcess))" } catch {}
  }
}
$procs = Get-Process -Name cloudflared -ErrorAction SilentlyContinue
foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force; Say "已停止残留 cloudflared (pid=$($p.Id))" } catch {} }

if (-not $KeepEmulator) {
  $adb = 'C:\Users\user\dsh-tools\android-sdk\platform-tools\adb.exe'
  if (Test-Path $adb) { & $adb emu kill 2>&1 | Out-Null; Say "已请求关闭模拟器" }
}

if ($StopDb) {
  $pgProcs = Get-Process -Name postgres -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$PgHome*" }
  foreach ($p in $pgProcs) { try { Stop-Process -Id $p.Id -Force } catch {} }
  if ($pgProcs) { Say "已停止 PostgreSQL ($($pgProcs.Count) 个进程)" }
}
if (Test-Path $stateFile) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
Say ('已停止（后端=' + (-not $KeepBackend) + ', 模拟器=' + (-not $KeepEmulator) + ', 数据库=' + (-not $StopDb) + '）')
