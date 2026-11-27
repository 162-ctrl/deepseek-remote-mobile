# M4.0 插件端自检（重启 DSH 后运行）
#
# 用法（PowerShell）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-plugin-m4.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-plugin-m4.ps1 -NoCreate
#
# 前置：DSH 桌面应用已重启（插件 dsh-plugin-m1 >= 0.2.20 已加载），
#       中继监听 http://127.0.0.1:8787 ，且手机已配对过至少一次。
#
# 注意：默认会真的在电脑第一个授权根目录下建一个 `.m4-selftest-<时间戳>` 子目录
#       （空目录，验证后保留，可手动删）。加 -NoCreate 只做只读检查。

param(
  [switch]$NoCreate
)

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

Check '插件版本 >= 0.2.20' {
  $health = Invoke-RestMethod -Uri "$base/api/v1/health" -UseBasicParsing -TimeoutSec 8
  if ([version]$health.version -lt [version]'0.2.20') { throw "仍是旧版本 $($health.version)，说明新插件代码未加载" }
  "version=$($health.version) agentOnline=$($health.agentOnline)"
}

Check 'GET /desktop/workspaces 返回根目录与计数' {
  # M4.10：接口返回的是 { workspaces: [...] }，直接 @(Invoke-RestMethod) 会把整个对象包成 1 行。
  $payload = Invoke-RestMethod -Uri "$base/api/v1/desktop/workspaces" -Headers $headers -UseBasicParsing -TimeoutSec 15
  $rows = @($payload.workspaces)
  if ($rows.Count -eq 0) { throw '工作区列表为空（Agent 未上报 workspaceRoots）' }
  # 会话 cwd 作为工作区出现时 name 可能为空，这里只校验 path。
  $blank = @($rows | Where-Object { -not $_.path })
  if ($blank.Count -gt 0) { throw "有 $($blank.Count) 行 path 为空" }
  "roots=$($rows.Count) first=$($rows[0].path) sessions=$($rows[0].sessions) running=$($rows[0].running)"
}

Check 'POST /desktop/workspaces 鉴权失败返回 401' {
  try {
    Invoke-RestMethod -Uri "$base/api/v1/desktop/workspaces" -Method Post -ContentType 'application/json' `
      -Body '{"name":"x"}' -Headers @{ Authorization = 'Bearer invalid-token' } -UseBasicParsing -TimeoutSec 10 | Out-Null
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 401) { throw "期望 401，实际 $code（旧插件会落到 404）" }
    return 'status=401'
  }
  throw '无效 token 竟然创建成功了'
}

Check 'POST /desktop/workspaces 空名字被拒绝（400 WORKSPACE_CREATE_FAILED）' {
  try {
    Invoke-RestMethod -Uri "$base/api/v1/desktop/workspaces" -Method Post -ContentType 'application/json' `
      -Body '{"name":"   "}' -Headers $headers -UseBasicParsing -TimeoutSec 10 | Out-Null
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 400) { throw "期望 400，实际 $code" }
    $payload = $null
    try {
      $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $payload = $reader.ReadToEnd() | ConvertFrom-Json
    } catch { }
    if ($payload -and $payload.code -ne 'WORKSPACE_CREATE_FAILED') { throw "错误码不对：$($payload.code)" }
    return "status=400 code=$($payload.code)"
  }
  throw '空名字竟然创建成功了'
}

if ($NoCreate) {
  [void]$results.Add([pscustomobject]@{ Check = 'POST /desktop/workspaces 真实创建（已跳过）'; Result = 'PASS'; Detail = '-NoCreate' })
} else {
  Check 'POST /desktop/workspaces 真实创建子目录' {
    $name = '.m4-selftest-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $created = Invoke-RestMethod -Uri "$base/api/v1/desktop/workspaces" -Method Post -ContentType 'application/json' `
      -Body (@{ name = $name } | ConvertTo-Json -Compress) -Headers $headers -UseBasicParsing -TimeoutSec 20
    if (-not $created.ok) { throw '返回 ok 不为 true' }
    if ([string]::IsNullOrWhiteSpace($created.path)) { throw '返回里没有 path' }
    if (-not (Test-Path -LiteralPath $created.path -PathType Container)) { throw "目录不存在：$($created.path)" }
    $leaf = Split-Path -Leaf $created.path
    if ($leaf -ne $name) { throw "目录名不符：$leaf ≠ $name" }
    $rootRows = @((Invoke-RestMethod -Uri "$base/api/v1/desktop/workspaces" -Headers $headers -UseBasicParsing -TimeoutSec 15).workspaces)
    $hit = @($rootRows | Where-Object { $_.path -ieq $created.path })
    $absent = '列表暂未包含新目录（Agent 下次上报后出现，App 端会本地追加）'
    if ($hit.Count -gt 0) { $absent = '列表已包含新目录' }
    "path=$($created.path) · $absent"
  }

  Check 'POST /desktop/workspaces 非法字符被替换为 -' {
    $raw = 'm4:bad/name*' + (Get-Date -Format 'HHmmss')
    $created = Invoke-RestMethod -Uri "$base/api/v1/desktop/workspaces" -Method Post -ContentType 'application/json' `
      -Body (@{ name = $raw } | ConvertTo-Json -Compress) -Headers $headers -UseBasicParsing -TimeoutSec 20
    $leaf = Split-Path -Leaf $created.path
    if ($leaf -match '[\\/:*?"<>|]') { throw "目录名仍含非法字符：$leaf" }
    "raw=$raw -> leaf=$leaf"
  }
}

Check 'GET /desktop/tasks 仍有 lastTime（M3.6 能力未回退）' {
  $data = Invoke-RestMethod -Uri "$base/api/v1/desktop/tasks" -Headers $headers -UseBasicParsing -TimeoutSec 15
  $rows = @($data.tasks)
  if ($rows.Count -eq 0) { throw '任务/会话列表为空' }
  $stamped = @($rows | Where-Object { [double]$_.lastTime -gt 0 })
  if ($stamped.Count -eq 0) { throw '所有行 lastTime 仍为 0' }
  "rows=$($rows.Count) top=$($rows[0].title)"
}

Check 'GET /desktop/plugins/gallery 返回分组与开关状态（M4.1）' {
  $gallery = Invoke-RestMethod -Uri "$base/api/v1/desktop/plugins/gallery" -Headers $headers -UseBasicParsing -TimeoutSec 20
  $groups = @($gallery.groups)
  if ($groups.Count -eq 0) { throw '没有返回任何分组' }
  $rows = @($groups | ForEach-Object { $_.plugins })
  if ($rows.Count -eq 0) { throw '分组里没有插件行' }
  $missing = @($rows | Where-Object { -not $_.name })
  if ($missing.Count -gt 0) { throw "$($missing.Count) 行缺少名称" }
  $experimental = @($rows | Where-Object { $_.experimental -eq $true }).Count
  "groups=$($groups.Count) rows=$($rows.Count) experimental=$experimental"
}

Check 'GET /desktop/plugins/market 有索引兜底（M4.1）' {
  $market = Invoke-RestMethod -Uri "$base/api/v1/desktop/plugins/market" -Headers $headers -UseBasicParsing -TimeoutSec 120
  $bundles = @($market.installedBundles).Count
  $indexes = @($market.indexes)
  if ($indexes.Count -eq 0) {
    # DSH 的 pluginMarket 没有默认索引源（listIndexes 只回 Settings 里配的 URL）。
    # 没配索引时手机端市场是空的，但这是电脑端设置的问题，不是插件故障：给提示而不是判失败。
    $tip = '提示：电脑端「插件 → 发现 → 索引源」还没配，手机端市场会是空的。' +
      '可在 profile 的 cordis.patch.yml 里给 plugin-market 配 indexes，例如 https://cdn.jsdelivr.net/npm/dsh-plugin-catalog/index.json'
    "indexes=0 entries=0 installedBundles=$bundles · $tip"
    return
  }
  "indexes=$($indexes.Count) source=$($market.source) entries=$(@($market.entries).Count) defaultIndex=$($market.defaultIndex)"
}
Check 'POST /desktop/upload 按工作区落盘（M4.2）' {
  $ws = @((Invoke-RestMethod -Uri "$base/api/v1/desktop/workspaces" -Headers $headers -UseBasicParsing -TimeoutSec 15).workspaces)
  # M4.11：手机端传的是工作区名（路径末段）或完整路径，插件都认；这里照 App 的做法传末段名。
  # M4.12：优先选「末段名 == path 末段」的工作区。授权根在 DSH 刚重开时只认得主目录，
  # 传一个只在「工作区列表」里的名字（例如 课程设计）会回退到状态目录 —— 那是配置态而不是
  # 插件故障，拿它当验收项会让自检在插件可用时也报 FAIL。
  $name = ($ws | Where-Object { $_.name -and $_.path -and ([System.IO.Path]::GetFileName($_.path) -eq $_.name) } | Select-Object -First 1).name
  if (-not $name) { $name = ($ws | Where-Object { $_.name } | Select-Object -First 1).name }
  if (-not $name) { throw '没有可用工作区名' }
  $payload = @{
    name = 'm4-selftest.txt'
    workspace = $name
    data = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('dsh selftest'))
  } | ConvertTo-Json -Compress
  $uploaded = Invoke-RestMethod -Uri "$base/api/v1/desktop/upload" -Method Post -ContentType 'application/json' -Headers $headers -Body $payload -UseBasicParsing -TimeoutSec 20
  if (-not (Test-Path -LiteralPath $uploaded.path)) { throw "文件没落盘：$($uploaded.path)" }
  if ($uploaded.path -notlike "*$name*") { throw "附件没有落到工作区「$name」下：$($uploaded.path)" }
  if ($uploaded.path -notlike '*手机附件*') { throw "附件没有落进「手机附件」目录：$($uploaded.path)" }
  Remove-Item $uploaded.path -ErrorAction SilentlyContinue
  "workspace=$name -> $($uploaded.path)"
}

Check 'GET /desktop/sessions/:id/events 事件带 time（M4.3）' {
  $tasks = Invoke-RestMethod -Uri "$base/api/v1/desktop/tasks" -Headers $headers -TimeoutSec 10
  # M4.10：/desktop/tasks 的字段名是 tasks（旧脚本误用 rows，导致永远取不到会话）。
  $first = @($tasks.tasks | Where-Object { $_.id }) | Select-Object -First 1
  if (-not $first) { throw '没有可检查的桌面会话' }
  $feed = Invoke-RestMethod -Uri "$base/api/v1/desktop/sessions/$([uri]::EscapeDataString($first.id))/events?limit=20" -Headers $headers -TimeoutSec 10
  $events = @($feed.events | Where-Object { $_.kind -eq 'turn-start' -or $_.kind -eq 'assistant' })
  if ($events.Count -eq 0) { throw '会话事件里没有 turn-start/assistant，无法确认' }
  $withTime = @($events | Where-Object { [double]$_.time -gt 0 })
  if ($withTime.Count -eq 0) { throw "$($events.Count) 条事件都没有 time 字段（旧插件）" }
  "events=$($events.Count) withTime=$($withTime.Count) newest=$([DateTimeOffset]::FromUnixTimeMilliseconds([long]$withTime[-1].time).ToLocalTime().ToString('HH:mm:ss'))"
}

Check 'GET /desktop/file/raw 能取工作区文件原始字节（M4.9）' {
  $ws = Invoke-RestMethod -Uri "$base/api/v1/desktop/workspaces" -Headers $headers -TimeoutSec 10
  $root = @($ws.workspaces | Where-Object { $_.path } )[0]
  if (-not $root) { throw '没有授权根目录' }
  $target = Get-ChildItem -LiteralPath $root.path -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -gt 0 -and $_.Length -lt 5MB } | Select-Object -First 1
  if (-not $target) { throw '授权根目录里没有可读文件' }
  $rel = $target.FullName.Substring($root.path.Length).TrimStart('\', '/')
  $uri = "$base/api/v1/desktop/file/raw?workspace=$([uri]::EscapeDataString($root.path))&path=$([uri]::EscapeDataString($rel))"
  $response = Invoke-WebRequest -Uri $uri -Headers $headers -TimeoutSec 20 -UseBasicParsing
  if ($response.StatusCode -ne 200) { throw "期望 200 实际 $($response.StatusCode)" }
  if ($response.RawContentLength -ne $target.Length) {
    throw "字节数不一致：$($response.RawContentLength) / $($target.Length)"
  }
  $unauth = $null
  try { Invoke-WebRequest -Uri $uri -TimeoutSec 10 -UseBasicParsing | Out-Null } catch { $unauth = $_.Exception.Response.StatusCode.value__ }
  if ($unauth -ne 401) { throw "无 token 时期望 401 实际 $unauth" }
  "file=$($target.Name) bytes=$($target.Length) type=$($response.Headers['Content-Type']) unauth=$unauth"
}

Check 'POST /desktop/file/read 把 docx/文本读成文字（M4.9）' {
  $payload = @{ name = 'selftest.txt'; data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('手机端自检 hello')) } | ConvertTo-Json
  $read = Invoke-RestMethod -Uri "$base/api/v1/desktop/file/read" -Method Post -Headers $headers -ContentType 'application/json' -Body $payload -TimeoutSec 20
  if ($read.text -notmatch '手机端自检 hello') { throw "读回内容不对：$($read.text)" }
  "text=$($read.text.Trim()) len=$($read.text.Length)"
}
Check 'GET /desktop/archive/sessions 有会话存档（M4.10）' {
  $list = Invoke-RestMethod -Uri "$base/api/v1/desktop/archive/sessions" -Headers $headers -UseBasicParsing -TimeoutSec 30
  $rows = @($list.sessions)
  if ($rows.Count -lt 1) { throw '存档为空：插件的 session-archive.json 还没生成任何记录' }
  $first = $rows | Select-Object -First 1
  $detail = Invoke-RestMethod -Uri "$base/api/v1/desktop/archive/sessions/$([uri]::EscapeDataString($first.id))" -Headers $headers -UseBasicParsing -TimeoutSec 20
  $events = @($detail.events)
  if ($events.Count -lt 1) { throw "会话 $($first.id) 存档没有事件" }
  "sessions=$($rows.Count) first=$($first.id) events=$($events.Count) source=$($first.source)"
}

$results | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' })
if ($failed.Count -gt 0) {
  Write-Host "M4.0 插件自检：$($results.Count - $failed.Count)/$($results.Count) PASS" -ForegroundColor Yellow
  exit 1
}
Write-Host "M4.0 插件自检：$($results.Count)/$($results.Count) PASS" -ForegroundColor Green
exit 0
