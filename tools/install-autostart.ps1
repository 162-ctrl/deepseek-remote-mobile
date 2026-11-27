# 安装「登录时自动拉起 M1 服务栈」的计划任务
#
# 作用：Windows 开机登录后自动执行 tools\m1-up.ps1（PostgreSQL + 后端 + 隧道 + Agent），
#      之后手机就能直接连，不需要每次手动跑脚本。
#
# 用法（普通权限即可，不需要管理员）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-autostart.ps1
# 卸载：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\uninstall-autostart.ps1
#
# 说明：
# - 这是「用户主动配置」的开机启动，脚本不会自己偷偷设置；卸载会删掉该任务。
# - 隧道地址（trycloudflare 临时域名）每次重启电脑都会变，手机端需要在「真实连接」页更新地址；
#   如果手机和电脑在同一个 Wi-Fi，建议直接用局域网地址 http://<电脑IP>:8080（不随重启变化）。

param(
    [string]$TaskName = 'DeepSeekRemoteM1'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$upScript = Join-Path $root 'tools\m1-up.ps1'
if (-not (Test-Path $upScript)) {
    throw "找不到 $upScript"
}

$pwsh = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

$action = New-ScheduledTaskAction -Execute $pwsh `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$upScript`"" `
    -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "[autostart] 已存在任务 $TaskName，先删除再重建"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description '登录后自动拉起 DeepSeek Remote 的 PostgreSQL + 后端 + 隧道 + Agent（tools\m1-up.ps1）' | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName
Write-Host "[autostart] 已安装计划任务：$($task.TaskName)（状态 $($task.State)）"
Write-Host "[autostart] 触发：用户登录时；动作：powershell -File $upScript"
Write-Host "[autostart] 卸载：powershell -NoProfile -ExecutionPolicy Bypass -File tools\uninstall-autostart.ps1"
Write-Host "[autostart] 立即试跑一次：Start-ScheduledTask -TaskName $TaskName"
