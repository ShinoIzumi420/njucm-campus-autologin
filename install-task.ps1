# 注册计划任务：登录时 + 网络接通时 + 每10分钟，自动执行 login.ps1
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName = 'NJUCM-CampusAutoLogin'

# 通过 VBS 包装静默运行，避免每次触发时弹出控制台窗口
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$dir\run-hidden.vbs`""

# 触发器1：用户登录（延迟15秒等网络起来）
$tLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$tLogon.Delay = 'PT15S'

# 触发器2：接入任意网络时（NetworkProfile EventID 10000，延迟20秒）
$sub = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select></Query></QueryList>'
$cls = Get-CimClass -Namespace ROOT\Microsoft\Windows\TaskScheduler -ClassName MSFT_TaskEventTrigger
$tNet = New-CimInstance -CimClass $cls -ClientOnly -Property @{ Enabled = $true; Delay = 'PT20S'; Subscription = $sub }

# 触发器3：每10分钟兜底（睡眠唤醒 / 掉线重连 / 被踢下线后自动补登）
$tRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($tLogon, $tNet, $tRepeat) -Settings $settings -Principal $principal -Description 'NJUCM campus network auto login (net.njucm.edu.cn)' -Force | Out-Null

Write-Host ("计划任务 '" + $taskName + "' 已注册：用户登录 / 网络接通 / 每10分钟 三个触发点。")
Write-Host '立即试运行一次...'
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 6
$log = Join-Path $dir 'login.log'
if (Test-Path $log) {
    Write-Host '--- login.log 最近几行 ---'
    Get-Content $log -Tail 5 -Encoding UTF8
}
