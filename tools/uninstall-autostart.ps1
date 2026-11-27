# 卸载「登录时自动拉起 M1 服务栈」的计划任务
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tools\uninstall-autostart.ps1

param(
    [string]$TaskName = 'DeepSeekRemoteM1'
)

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Host "[autostart] 没有找到任务 $TaskName，无需卸载"
    return
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "[autostart] 已删除计划任务 $TaskName（前台服务不受影响，可用 tools\m1-down.ps1 停止）"
