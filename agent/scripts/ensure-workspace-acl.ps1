<#
.SYNOPSIS
  检查/修复 agent 工作区目录的 Windows 权限（M0 实测踩坑的固化修复）。

.DESCRIPTION
  背景（M0 实测于 Windows 11 家庭版中文版）：
  D: 分区新建目录继承到的 ACE 是 "NT AUTHORITY\Authenticated Users:(M)"，
  其中不含 WRITE_OWNER / WRITE_DAC。DeepSeek Harness 的 shell 沙箱在每次执行 pwsh 命令前，
  需要先给工作区目录做一次权限授予（SetNamedSecurityInfoW）。当缺少这两个权限项时，工具会报：

      Error: SetNamedSecurityInfoW failed (Win32 5): grantWrite(<workspace>)

  结果是"在 D: 盘工作区里连只读命令都跑不了"，而非沙箱策略拒绝。

  修复方式：给工作区父目录加一条"继承给当前用户"的完全控制 ACE（一次即可，之后新建的子目录自动继承）：
      icacls <workspaces-parent> /grant "<user>:(OI)(CI)F"

  默认只打印将要执行的命令；加 -Apply 才真正执行。执行后可用 -Verify 检查某个目录的继承权限。
  该修改不改变目录所有者，可随时用 icacls /remove 撤销（脚本会打印撤销命令）。

.PARAMETER Path
  工作区父目录，默认 <agent>\.workspaces。

.PARAMETER Apply
  真正执行授权（默认只预览）。

.PARAMETER Verify
  只检查指定目录当前是否已获得当前用户的完全控制权限。

.EXAMPLE
  pwsh -File scripts\ensure-workspace-acl.ps1
  pwsh -File scripts\ensure-workspace-acl.ps1 -Apply
  pwsh -File scripts\ensure-workspace-acl.ps1 -Path .workspaces\contract-2026-10-31T04-22-15-155Z -Verify
#>
param(
  [string]$Path,
  [switch]$Apply,
  [switch]$Verify
)

$ErrorActionPreference = 'Stop'

$agentRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Join-Path $agentRoot '.workspaces' }
$Path = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$grantRule = "${user}:(OI)(CI)F"

Write-Host "目标目录 : $Path"
Write-Host "当前用户 : $user"

$acl = Get-Acl -LiteralPath $Path
$mine = @($acl.Access | Where-Object { $_.IdentityReference.Value -eq $user -and $_.AccessControlType -eq 'Allow' })
if ($mine.Count -gt 0) {
  Write-Host "现状     : 已有当前用户的 Allow 条目（继承条目也计入）"
  $mine | ForEach-Object {
    Write-Host ("           {0} {1} inherited={2}" -f $_.IdentityReference, $_.FileSystemRights, $_.IsInherited)
  }
} else {
  Write-Host "现状     : 没有当前用户的 Allow 条目（Harness shell 沙箱很可能报 Win32 5）"
}

if ($Verify) {
  $fullControlInherited = @($acl.Access | Where-Object {
      $_.IdentityReference.Value -eq $user -and
      $_.AccessControlType -eq 'Allow' -and
      ($_.FileSystemRights.ToString() -match 'FullControl') -and
      $_.InheritanceFlags -ne 'None'
    }).Count -gt 0
  if ($fullControlInherited) {
    Write-Host "结论     : OK，当前用户对子目录具备继承的完全控制权限"
    exit 0
  }
  Write-Host "结论     : NG，缺少继承给当前用户的完全控制权限"
  exit 1
}

Write-Host ''
Write-Host '修复命令（给父目录加继承 ACE，一次修复，新建子目录自动继承）：'
Write-Host "  icacls `"$Path`" /grant `"$grantRule`""
Write-Host ''
Write-Host '撤销命令（如需回滚）：'
Write-Host "  icacls `"$Path`" /remove `"$user`""

if (-not $Apply) {
  Write-Host ''
  Write-Host '当前为预览模式，未执行任何修改。确认后加 -Apply 执行。'
  exit 0
}

& icacls $Path /grant $grantRule
if ($LASTEXITCODE -ne 0) {
  Write-Error "icacls 失败（exit=$LASTEXITCODE）"
  exit 1
}
$after = Get-Acl -LiteralPath $Path
$ok = @($after.Access | Where-Object {
    $_.IdentityReference.Value -eq $user -and
    $_.AccessControlType -eq 'Allow' -and
    ($_.FileSystemRights.ToString() -match 'FullControl') -and
    $_.InheritanceFlags -ne 'None'
  }).Count -gt 0
if ($ok) {
  Write-Host ''
  Write-Host '修复完成：当前用户已获得继承的完全控制权限。'
  exit 0
}
Write-Host ''
Write-Host '修复命令已执行，但校验未通过，请查看 icacls 输出。'
exit 1
