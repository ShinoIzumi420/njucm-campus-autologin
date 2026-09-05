Unregister-ScheduledTask -TaskName 'NJUCM-CampusAutoLogin' -Confirm:$false
Write-Host '计划任务已卸载。如需彻底清除，可整个删除 campus-auth 文件夹。'
