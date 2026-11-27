# M3.6 插件端自检（重启 DSH 后运行）
#
# 用法（PowerShell）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-plugin-m3-6.ps1
#
# 前置：DSH 桌面应用已重启，手机端插件（dsh-plugin-m1）已加载新代码，
#       中继监听 http://127.0.0.1:8787 。

$ErrorActionPreference = 'Stop'
$tokenFile = '<DSH 数据目录>\dsh-plugin-m1\tokens.json'
if (-not (Test-Path $tokenFile)) { $tokenFile = Join-Path $env:USERPROFILE '.dsh\dsh-plugin-m1\tokens.json' }
if (-not (Test-Path $tokenFile)) { throw "找不到 tokens.json：$tokenFile" }

$tokens = [System.IO.File]::ReadAllText($tokenFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$app = $tokens | Where-Object { $_.role -eq 'app' } | Select-Object -Last 1
if (-not $app) { throw 'tokens.json 里没有 role=app 的 token，请先用手机配对一次' }
$headers = @{ Authorization = "Bearer $($app.token)" }
$base = 'http://127.0.0.1:8787'

$results = New-Object System.Collections.ArrayList
function Check($name, [scriptblock]$probe) {
  try {
    $detail = & $probe
    [void]$results.Add([pscustomobject]@{ Check = $name; Result = 'PASS'; Detail = $detail })
  } catch {
    [void]$results.Add([pscustomobject]@{ Check = $name; Result = 'FAIL'; Detail = $_.Exception.Message })
  }
}

Check '插件版本 >= 0.2.8' {
  $health = Invoke-RestMethod -Uri "$base/api/v1/health" -UseBasicParsing -TimeoutSec 8
  if ([version]$health.version -lt [version]'0.2.8') { throw "仍是旧版本 $($health.version)，说明新插件代码未加载" }
  "version=$($health.version) agentOnline=$($health.agentOnline)"
}

Check 'GET /desktop/plugins 归一化（id/name 非空）' {
  $data = Invoke-RestMethod -Uri "$base/api/v1/desktop/plugins" -Headers $headers -UseBasicParsing -TimeoutSec 15
  $rows = @($data.plugins)
  $blank = @($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.id) -or [string]::IsNullOrWhiteSpace($_.name) })
  if ($rows.Count -eq 0) { throw '插件列表为空' }
  if ($blank.Count -gt 0) { throw "有 $($blank.Count) 行 id/name 为空（旧插件行为）" }
  "count=$($rows.Count) sample=$($rows[0].name)"
}

Check 'GET /desktop/plugins/bundles（插件包分组）' {
  $data = Invoke-RestMethod -Uri "$base/api/v1/desktop/plugins/bundles" -Headers $headers -UseBasicParsing -TimeoutSec 15
  $bundles = @($data.bundles)
  if ($bundles.Count -eq 0) { throw 'bundles 为空' }
  $withRows = @($bundles | Where-Object { @($_.plugins).Count -gt 0 })
  "bundles=$($bundles.Count) 有子插件的包=$($withRows.Count) sample=$($bundles[0].name)@$($bundles[0].version)"
}

Check 'GET /desktop/plugins/market（插件市场索引/搜索）' {
  $data = Invoke-RestMethod -Uri "$base/api/v1/desktop/plugins/market" -Headers $headers -UseBasicParsing -TimeoutSec 25
  $indexes = @($data.indexes)
  $entries = @($data.entries)
  if ($indexes.Count -eq 0) { throw '没有可用市场索引（Host pluginMarket.listIndexes 为空）' }
  "indexes=$($indexes.Count) entries=$($entries.Count) source=$($data.source) error=$($data.error)"
}

Check 'GET /desktop/tasks lastTime/messageCount 生效' {
  $data = Invoke-RestMethod -Uri "$base/api/v1/desktop/tasks" -Headers $headers -UseBasicParsing -TimeoutSec 15
  $rows = @($data.tasks)
  if ($rows.Count -eq 0) { throw '任务/会话列表为空' }
  $stamped = @($rows | Where-Object { [double]$_.lastTime -gt 0 })
  if ($stamped.Count -eq 0) { throw '所有行 lastTime 仍为 0（旧插件行为）' }
  $sorted = $true
  for ($i = 1; $i -lt $rows.Count; $i += 1) {
    if ([double]$rows[$i - 1].lastTime -lt [double]$rows[$i].lastTime) { $sorted = $false; break }
  }
  if (-not $sorted) { throw '会话没有按 lastTime 倒序（最新对话不在最上面）' }
  "rows=$($rows.Count) top=$($rows[0].title) lastTime=$($rows[0].lastTime) msgs=$($rows[0].messageCount)"
}

Check 'GET /desktop/_debug 含 assistantParts（正文 part 诊断）' {
  $data = Invoke-RestMethod -Uri "$base/api/v1/desktop/_debug" -UseBasicParsing -TimeoutSec 10
  if (-not ($data.PSObject.Properties.Name -contains 'assistantParts')) { throw '缺少 assistantParts 字段（旧插件行为）' }
  $parts = @($data.assistantParts)
  $types = ($parts | ForEach-Object { $_.type }) -join ','
  "parts=$($parts.Count) types=$types"
}

$results | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' })
if ($failed.Count -gt 0) {
  Write-Host "M3.6 插件自检：$($results.Count - $failed.Count)/$($results.Count) PASS" -ForegroundColor Yellow
  exit 1
}
Write-Host "M3.6 插件自检：$($results.Count)/$($results.Count) PASS" -ForegroundColor Green
exit 0
