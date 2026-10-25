#Requires -RunAsAdministrator
# One-time install (run as Administrator; re-run any time to repair or update):
#  - receiver runs as a scheduled task at boot, before anyone logs in (S4U, your account)
#  - tray app starts at logon from the Startup folder
#  - port opened to the LAN and Tailscale only; files go straight into Downloads
param([int]$Port = 8765)

$ErrorActionPreference = 'Stop'
$AppDir = $PSScriptRoot
$TaskName = 'AirDropReceiver'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$sid = $identity.User.Value
$userName = $identity.Name

# --- config ---
$configPath = Join-Path $AppDir 'config.json'
$config = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
$shellFolders = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$downloads = [Environment]::ExpandEnvironmentVariables($shellFolders.'{374DE290-123F-4565-9164-39C4925E467B}')
if (-not $downloads) { $downloads = Join-Path $env:USERPROFILE 'Downloads' }
$config | Add-Member -Force port $Port
$config | Add-Member -Force saveDir $downloads
$config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

# --- stop anything already running ---
Write-Host '停止舊的執行個體…'
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $TaskName }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$AppDir*server.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process AirDropReceiver -ErrorAction SilentlyContinue | Stop-Process -Force

# --- network access ---
Write-Host '設定網路權限與防火牆…'
$url = "http://+:$Port/"
netsh http delete urlacl url=$url 2>$null | Out-Null
netsh http add urlacl url=$url "sddl=D:(A;;GX;;;$sid)" | Out-Null
Remove-NetFirewallRule -DisplayName 'AirDrop Receiver' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'AirDrop Receiver' -Direction Inbound -Protocol TCP -LocalPort $Port `
    -Action Allow -Profile Any -RemoteAddress LocalSubnet, 100.64.0.0/10 | Out-Null

# --- icon + tray app ---
Write-Host '建立圖示與系統匣程式…'
& (Join-Path $AppDir 'build-icon.ps1') | Out-Null
& (Join-Path $AppDir 'build-tray.ps1') | Out-Null
$trayExe = Join-Path $AppDir 'AirDropReceiver.exe'

# --- boot-time receiver task ---
Write-Host '註冊開機自動接收…'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $AppDir `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $AppDir 'server.ps1')`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description '傳到電腦：接收 iPhone 傳來的檔案' -Force | Out-Null

# Let the (non-admin) tray app restart the task from its menu.
try {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $task = $svc.GetFolder('\').GetTask($TaskName)
    $sd = $task.GetSecurityDescriptor(4)
    if ($sd -notmatch [regex]::Escape($sid)) { $task.SetSecurityDescriptor($sd + "(A;;GA;;;$sid)", 0) }
} catch { Write-Host "（略過工作權限設定：$($_.Exception.Message)）" -ForegroundColor DarkYellow }

Start-ScheduledTask -TaskName $TaskName

# --- shortcuts ---
$shell = New-Object -ComObject WScript.Shell
foreach ($dir in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('Programs')) {
    $lnk = $shell.CreateShortcut((Join-Path $dir '傳到電腦.lnk'))
    $lnk.TargetPath = $trayExe
    $lnk.WorkingDirectory = $AppDir
    $lnk.IconLocation = "$trayExe,0"
    $lnk.Description = '傳到電腦'
    $lnk.Save()
}
# Explorer right-click → 傳送到 → iPhone（傳到電腦）: queues the selected files for the iPhone.
$lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('SendTo')) 'iPhone（傳到電腦）.lnk'))
$lnk.TargetPath = $trayExe
$lnk.Arguments = '--send'
$lnk.WorkingDirectory = $AppDir
$lnk.IconLocation = "$trayExe,0"
$lnk.Description = '傳到 iPhone'
$lnk.Save()

# Start the tray un-elevated (via Explorer) so it runs like it will at logon.
Start-Process explorer.exe -ArgumentList "`"$trayExe`""

# --- wait for the receiver ---
$ok = $false
for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
    Start-Sleep -Milliseconds 500
    try { $ok = (Invoke-WebRequest "http://localhost:$Port/api/health" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } catch { }
}

Write-Host ''
if ($ok) {
    Write-Host "安裝完成！（v$((Get-Content (Join-Path $AppDir 'VERSION') -Raw).Trim())）" -ForegroundColor Green
    Write-Host "  開機就會自動接收，檔案存到：$downloads"
    Write-Host '  系統匣出現藍色圖示；按兩下開啟設定頁（有 QR Code 給 iPhone 掃）。'
    Start-Process "http://localhost:$Port/"
} else {
    Write-Host '已安裝，但接收服務還沒回應。請稍等一分鐘，或查看「工作排程器」中的 AirDropReceiver。' -ForegroundColor Yellow
}
