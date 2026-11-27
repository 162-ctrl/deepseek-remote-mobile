# Probe: run `dsh headless --json` as an external caller would, capture NDJSON stdout/stderr,
# exit code, and inter-line timings (streaming evidence).
param(
  [string]$Task = '只列出当前目录的文件名，不要执行其它操作',
  [string]$OutName = 'run1'
)
$ErrorActionPreference = 'Continue'
$base = 'C:\Users\user\AppData\Local\Programs\DeepSeek Harness'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$tmp  = Join-Path $root 'tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$sessDir = Join-Path $env:USERPROFILE '.dsh\sessions'
$beforeSessions = @()
if (Test-Path $sessDir) { $beforeSessions = Get-ChildItem $sessDir | Select-Object -ExpandProperty Name }

# Emulate a clean external invocation: do not inherit the desktop host's profile/web/session vars.
$env:ELECTRON_RUN_AS_NODE = '1'
foreach ($v in 'DSH_PROFILE','DSH_PROFILE_DIR','DSH_SESSION_ID','DSH_WEB_URL','DSH_SHELL') {
  Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}

$stdout = Join-Path $tmp "$OutName.stdout.txt"
$stderr = Join-Path $tmp "$OutName.stderr.txt"
Remove-Item $stdout,$stderr -ErrorAction SilentlyContinue
$dsh = Join-Path $base 'resources\runtime\cli\bin\dsh.cmd'

$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath $dsh -ArgumentList @('headless','--json',$Task) `
      -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
      -WorkingDirectory $tmp -PassThru -WindowStyle Hidden

# Poll the stdout file so we can timestamp when each chunk lands (true streaming check).
$marks = New-Object System.Collections.ArrayList
$lastLen = 0
while (-not $p.HasExited) {
  Start-Sleep -Milliseconds 120
  if (Test-Path $stdout) {
    $len = (Get-Item $stdout).Length
    if ($len -ne $lastLen) { [void]$marks.Add(("{0:F2}s {1}B" -f $sw.Elapsed.TotalSeconds, $len)); $lastLen = $len }
  }
  if ($sw.Elapsed.TotalSeconds -gt 150) { Write-Output 'TIMEOUT >150s'; try { $p.Kill($true) } catch {}; break }
}
$p.WaitForExit()
# final flush of the polled length
if (Test-Path $stdout) { $len=(Get-Item $stdout).Length; if ($len -ne $lastLen) { [void]$marks.Add(("{0:F2}s {1}B (final)" -f $sw.Elapsed.TotalSeconds, $len)) } }
$sw.Stop()
$code = $p.ExitCode

$afterSessions = @()
if (Test-Path $sessDir) { $afterSessions = Get-ChildItem $sessDir | Select-Object -ExpandProperty Name }
$newSessions = @($afterSessions | Where-Object { $beforeSessions -notcontains $_ })

$report = [ordered]@{
  task              = $Task
  command           = 'dsh headless --json "<task>"  (cwd=' + $tmp + ')'
  exitCode          = $code
  elapsedSeconds    = [math]::Round($sw.Elapsed.TotalSeconds, 2)
  stdoutBytes       = if (Test-Path $stdout) { (Get-Item $stdout).Length } else { -1 }
  stderrBytes       = if (Test-Path $stderr) { (Get-Item $stderr).Length } else { -1 }
  stdoutGrowthMarks = $marks
  newSessionEntries = $newSessions
  stdoutPreview     = if (Test-Path $stdout) { (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) } else { '' }
  stderrPreview     = if (Test-Path $stderr) { (Get-Content $stderr -Raw -ErrorAction SilentlyContinue) } else { '' }
}
$json = $report | ConvertTo-Json -Depth 6
$json | Set-Content (Join-Path $tmp "$OutName.report.json") -Encoding utf8
Write-Output $json
