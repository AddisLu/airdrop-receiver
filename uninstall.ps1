#Requires -RunAsAdministrator
# Removes everything install.ps1 set up. Received files and config.json are left alone.
param([int]$Port = 8765)

$TaskName = 'AirDropReceiver'
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Get-Process AirDropReceiver -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$PSScriptRoot*server.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

netsh http delete urlacl url=http://+:$Port/ | Out-Null
Remove-NetFirewallRule -DisplayName 'AirDrop Receiver' -ErrorAction SilentlyContinue
foreach ($dir in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('Programs')) {
    Remove-Item -LiteralPath (Join-Path $dir '傳到電腦.lnk') -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('SendTo')) 'iPhone（傳到電腦）.lnk') -ErrorAction SilentlyContinue
Write-Host '已移除。收到的檔案和 config.json 都保留著。' -ForegroundColor Green
