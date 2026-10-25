# 傳到電腦 — AirDrop-style file receiver for Windows (PowerShell 5.1+, no extra installs).
# iPhone (Shortcut / browser) -> POST /upload -> saved straight into Downloads.
# PC -> iPhone: files dropped in data\outbox are listed/fetched with ?action=outbox.
# Clipboard both ways: ?action=clip (iPhone -> PC) and ?action=clipboard (PC -> iPhone,
# answered by the tray app, which is the only part that can read the user's clipboard).
# install.ps1 runs this as a scheduled task at boot; start.cmd runs it in a console.
param(
    [int]$Port = 0,
    [string]$SaveDir = ''
)

$ErrorActionPreference = 'Stop'
$AppDir = $PSScriptRoot
$Version = (Get-Content -LiteralPath (Join-Path $AppDir 'VERSION') -Raw).Trim()
$DataDir = Join-Path $AppDir 'data'
$LogPath = Join-Path $DataDir 'received.log'
$OutboxDir = Join-Path $DataDir 'outbox'
$ClipDir = Join-Path $DataDir 'clip'
New-Item -ItemType Directory -Force -Path $DataDir, $OutboxDir, $ClipDir | Out-Null

Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $AppDir 'Receiver.cs')))
Add-Type -AssemblyName System.Web   # MimeMapping

# --- config -----------------------------------------------------------------
function Get-DownloadsPath {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $raw = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
    if ($raw) { return [Environment]::ExpandEnvironmentVariables($raw) }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

$configPath = Join-Path $AppDir 'config.json'
$config = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
function New-RandomString([int]$length) {
    $chars = 'abcdefghjkmnpqrstuvwxyz23456789'.ToCharArray()
    $bytes = New-Object byte[] $length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

$changed = $false
if (-not $config.token) { $config | Add-Member -Force token (New-RandomString 12); $changed = $true }
# ntfy push for PC -> iPhone. Topics are public by name, so it must be unguessable.
if (-not $config.ntfyTopic) { $config | Add-Member -Force ntfyTopic ('airdrop-pc-' + (New-RandomString 16)); $changed = $true }
if (-not $config.ntfyServer) { $config | Add-Member -Force ntfyServer 'https://ntfy.sh'; $changed = $true }
if (-not $config.port) { $config | Add-Member -Force port 8765; $changed = $true }
if (-not $config.saveDir) { $config | Add-Member -Force saveDir (Get-DownloadsPath); $changed = $true }
if ($changed) { $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8 }

$Token = $config.token
$NtfyTopic = $config.ntfyTopic
$NtfyServer = $config.ntfyServer.TrimEnd('/')
if ($Port -eq 0) { $Port = [int]$config.port }
if (-not $SaveDir) { $SaveDir = $config.saveDir }
New-Item -ItemType Directory -Force -Path $SaveDir | Out-Null
$TextLogPath = Join-Path $SaveDir '傳到電腦-文字.txt'

# --- helpers ----------------------------------------------------------------
$Utf8 = New-Object Text.UTF8Encoding($false)

function Send-Bytes($ctx, [int]$status, [byte[]]$bytes, [string]$contentType) {
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = $contentType
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}

function Send-Text($ctx, [int]$status, [string]$body, [string]$contentType = 'text/plain; charset=utf-8') {
    Send-Bytes $ctx $status $Utf8.GetBytes($body) $contentType
}

function Send-Json($ctx, $obj) {
    Send-Text $ctx 200 (ConvertTo-Json $obj -Depth 5 -Compress) 'application/json; charset=utf-8'
}

function Test-Token($req) {
    $given = $req.Headers['X-Token']
    if (-not $given) { $given = $req.QueryString['token'] }
    return ($given -ceq $Token)
}

# One JSON line per received item; the tray app tails this file for notifications.
function Write-Event([hashtable]$evt) {
    $evt.time = (Get-Date).ToString('o')
    [IO.File]::AppendAllText($LogPath, (ConvertTo-Json $evt -Compress) + "`n", $Utf8)
}

function Add-ReceivedFile($req, [string]$path, [string]$clipText) {
    $item = Get-Item -LiteralPath $path
    Write-Host ('[{0}] {1} <- {2}  ({3:N1} KB)' -f (Get-Date -Format 'HH:mm:ss'), $item.Name, $req.RemoteEndPoint.Address, ($item.Length / 1KB)) -ForegroundColor Green
    $evt = @{ kind = 'file'; name = $item.Name; path = $item.FullName; size = $item.Length; from = "$($req.RemoteEndPoint.Address)" }
    if ($clipText) { $evt.text = $clipText }
    Write-Event $evt
    return $item.Name
}

function Add-ReceivedText($req, [string]$text) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [IO.File]::AppendAllText($TextLogPath, "[$stamp]`r`n$text`r`n`r`n", (New-Object Text.UTF8Encoding($true)))
    Write-Host ('[{0}] 文字 <- {1}  ({2} 字)' -f (Get-Date -Format 'HH:mm:ss'), $req.RemoteEndPoint.Address, $text.Length) -ForegroundColor Green
    Write-Event @{ kind = 'text'; text = $text; from = "$($req.RemoteEndPoint.Address)" }
}

function Receive-Upload($ctx) {
    $req = $ctx.Request
    $saved = @()
    if ($req.ContentType -like 'multipart/form-data*') {
        # iPhone Shortcut "表單" body: filename comes from the form part itself.
        $fields = @{}
        foreach ($part in [Receiver]::SaveMultipart($req.InputStream, $req.ContentType, $SaveDir)) {
            if (-not $part.IsFile -and $part.Text -and $part.Name -in 'url', 'text') {
                $fields[$part.Name] = $part.Text.Trim()
                continue
            }
            if ($part.IsFile) {
                $clip = $null
                if ($part.ContentType -like 'text/plain*' -and $part.Size -le 64KB) {
                    $clip = [IO.File]::ReadAllText($part.Path, $Utf8)
                    # Some apps share a link as plain text: treat it as a link, not a .txt file.
                    if ($clip.Trim() -match '^https?://\S+$') {
                        Remove-Item -LiteralPath $part.Path -Force
                        Add-ReceivedText $req $clip.Trim()
                        $saved += '(連結)'
                        continue
                    }
                }
                $saved += Add-ReceivedFile $req $part.Path $clip
            } elseif ($part.Text) {
                Add-ReceivedText $req $part.Text
                $saved += '(文字)'
            }
        }
        $saved += Add-LinkOrText $req $fields
    } elseif ($req.ContentType -like 'application/x-www-form-urlencoded*') {
        # Shortcut "表單" with only text fields (the link branch) arrives url-encoded.
        $saved += Add-LinkOrText $req (Read-UrlEncodedForm $req)
    } else {
        $raw = $req.Headers['X-Filename']
        $name = ''
        if ($raw) { try { $name = [Uri]::UnescapeDataString($raw) } catch { $name = $raw } }
        $path = [Receiver]::SaveStream($req.InputStream, $SaveDir, [Receiver]::SafeName($name, $req.ContentType))
        $saved += Add-ReceivedFile $req $path $null
    }
    Send-Text $ctx 200 ("OK " + ($saved -join ', '))
}

# Shortcut link branch sends the item "as URL" (optionally a "text" field too). A bare
# link is opened on the PC; a message that merely contains a link stays text.
function Add-LinkOrText($req, [hashtable]$fields) {
    $url = if ($fields.url) { ($fields.url -split '\s+')[0] } else { $null }
    $text = $fields.text
    if ($url -and (-not $text -or $text -eq $url -or -not $text.Contains($url))) {
        Add-ReceivedText $req $url
        return '(連結)'
    }
    if ($text) {
        Add-ReceivedText $req $text
        return '(文字)'
    }
    return @()
}

function Read-UrlEncodedForm($req) {
    $body = (New-Object IO.StreamReader($req.InputStream, $Utf8)).ReadToEnd()
    $fields = @{}
    foreach ($pair in $body -split '&') {
        $kv = $pair -split '=', 2
        if ($kv.Count -eq 2) {
            $fields[[Uri]::UnescapeDataString($kv[0].Replace('+', ' '))] = [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')).Trim()
        }
    }
    return $fields
}

# --- PC -> iPhone outbox ------------------------------------------------------
# One folder per item: data\outbox\<id>\<file>. Writers create "<id>.tmp" and rename it
# when complete; a ".delivered" marker is added once the iPhone has fetched the file.
$MediaExt = '.jpg', '.jpeg', '.png', '.heic', '.heif', '.gif', '.webp', '.mov', '.mp4', '.m4v'

function Get-OutboxItems([switch]$IncludeDelivered) {
    foreach ($d in Get-ChildItem -LiteralPath $OutboxDir -Directory | Where-Object Name -notlike '*.tmp' | Sort-Object Name) {
        $file = Get-ChildItem -LiteralPath $d.FullName -File | Where-Object Name -ne '.delivered' | Select-Object -First 1
        $marker = Join-Path $d.FullName '.delivered'
        $delivered = Test-Path -LiteralPath $marker
        # Housekeeping: fetched more than a day ago, or never fetched within a week.
        if (-not $file -or ($delivered -and (Get-Item -LiteralPath $marker).LastWriteTime -lt (Get-Date).AddDays(-1)) -or
            $d.CreationTime -lt (Get-Date).AddDays(-7)) {
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }
        if ($delivered -and -not $IncludeDelivered) { continue }
        [pscustomobject]@{
            id = $d.Name; name = $file.Name; size = $file.Length; path = $file.FullName; delivered = $delivered
            kind = if ($MediaExt -contains $file.Extension.ToLower()) { 'media' } else { 'file' }
        }
    }
}

function Add-OutboxFile($ctx) {
    $req = $ctx.Request
    $raw = $req.Headers['X-Filename']
    $name = ''
    if ($raw) { try { $name = [Uri]::UnescapeDataString($raw) } catch { $name = $raw } }
    $id = (Get-Date -Format 'yyyyMMddHHmmssfff') + '-' + (Get-Random -Maximum 9999)
    $tmp = New-Item -ItemType Directory -Path (Join-Path $OutboxDir "$id.tmp")
    try {
        $path = [Receiver]::SaveStream($req.InputStream, $tmp.FullName, [Receiver]::SafeName($name, $req.ContentType))
        Rename-Item -LiteralPath $tmp.FullName -NewName $id
    } catch {
        Remove-Item -LiteralPath $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    Send-Push @(Split-Path $path -Leaf)
    Send-Text $ctx 200 ("OK " + (Split-Path $path -Leaf))
}

# Push "the PC has files for you" through ntfy. Carries file names only: tapping opens the
# shortcut (its menu → 從電腦接收檔案) or the phone page, which already holds the token.
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Http = New-Object System.Net.Http.HttpClient
$Http.Timeout = [TimeSpan]::FromSeconds(20)
# Push tickets: the notification passes "<address>/?ticket=…" to the 「從電腦接收」 shortcut,
# so it needs no setup. A ticket only lists/fetches the outbox and expires after 3 days;
# the real token never goes through ntfy.
$TicketsPath = Join-Path $DataDir 'tickets.json'
$Tickets = @{}
if (Test-Path -LiteralPath $TicketsPath) {
    (Get-Content -LiteralPath $TicketsPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $Tickets[$_.Name] = [datetime]$_.Value }
}

function New-Ticket {
    foreach ($k in @($Tickets.Keys)) { if ($Tickets[$k] -lt (Get-Date)) { $Tickets.Remove($k) } }
    $ticket = New-RandomString 20
    $Tickets[$ticket] = (Get-Date).AddDays(3)
    $saved = @{}
    foreach ($k in $Tickets.Keys) { $saved[$k] = $Tickets[$k].ToString('o') }
    $saved | ConvertTo-Json | Set-Content -LiteralPath $TicketsPath -Encoding UTF8
    return $ticket
}

function Test-Ticket($req) {
    $t = $req.QueryString['ticket']
    return ($t -and $Tickets.ContainsKey($t) -and $Tickets[$t] -gt (Get-Date))
}

# Address the iPhone uses from a push: config "pushAddress" (e.g. the Tailscale IP), else the LAN.
function Get-PushBase {
    if ($config.pushAddress) { return "http://$($config.pushAddress):$Port" }
    $lan = Get-Addresses | Where-Object { $_.label -notlike '*Tailscale*' } | Select-Object -First 1
    if (-not $lan) { $lan = Get-Addresses | Select-Object -First 1 }
    if ($lan) { return ([Uri]$lan.url).GetLeftPart([UriPartial]::Authority) }
}

function Send-Push([string[]]$names) {
    if (-not $NtfyTopic -or -not $names) { return }
    $base = Get-PushBase
    $receiveUrl = "$base/?ticket=$(New-Ticket)"
    $click = 'shortcuts://run-shortcut?name=' + [Uri]::EscapeDataString('從電腦接收') +
             '&input=text&text=' + [Uri]::EscapeDataString($receiveUrl)
    $actions = @(@{ action = 'view'; label = '開網頁下載'; url = "$base/?inbox" })
    $title = if ($names.Count -eq 1) { '電腦傳來 1 個檔案' } else { "電腦傳來 $($names.Count) 個檔案" }
    $body = @{
        topic = $NtfyTopic; title = $title; message = ((($names | Select-Object -First 10) -join "`n") + "`n點一下自動接收")
        tags = @('inbox_tray'); click = $click; actions = $actions
    } | ConvertTo-Json -Depth 4 -Compress
    try {
        $content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, 'application/json')
        [void]$Http.PostAsync($NtfyServer, $content)   # fire and forget: never block the listener
    } catch {
        Write-Host "推播失敗: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Send-OutboxList($ctx) {
    $base = "http://$($ctx.Request.Url.Authority)"
    # Download links carry whichever credential the list was fetched with.
    $ticket = $ctx.Request.QueryString['ticket']
    $cred = if ($ticket -and (Test-Ticket $ctx.Request)) { "ticket=$ticket" } else { "token=$Token" }
    $items = @(Get-OutboxItems | ForEach-Object {
        @{ id = $_.id; name = $_.name; size = $_.size; kind = $_.kind
           url = "$base/outbox/$($_.id)/$([Uri]::EscapeDataString($_.name))?$cred"
           done = "$base/?action=done&id=$($_.id)&$cred" }
    })
    $message = if ($items.Count) { "已接收 $($items.Count) 個檔案" } else { '電腦沒有要傳給你的檔案' }
    # Pre-split so the shortcut needs no "If" (iOS loses the comparison text of an If on a
    # dictionary value): one loop saves "media" to Photos, the other saves "files".
    Send-Json $ctx @{
        items = $items; message = $message
        media = @($items | Where-Object { $_.kind -eq 'media' })
        files = @($items | Where-Object { $_.kind -ne 'media' })
    }
}

# $markDelivered: token downloads (web page, 傳到電腦 menu) count as received right away;
# push-ticket downloads (從電腦接收) wait for ?action=done after the iPhone saved the file,
# so a failed save leaves the item in the outbox for the next tap.
function Send-OutboxFile($ctx, [string]$id, [bool]$markDelivered) {
    $item = Get-OutboxItems -IncludeDelivered | Where-Object id -eq $id
    if (-not $item) { Send-Text $ctx 404 'Gone'; return }
    $res = $ctx.Response
    $res.ContentType = [System.Web.MimeMapping]::GetMimeMapping($item.name)
    $disposition = if ($item.kind -eq 'media') { 'inline' } else { 'attachment' }
    $res.AddHeader('Content-Disposition', "$disposition; filename*=UTF-8''" + [Uri]::EscapeDataString($item.name))
    $fs = [IO.File]::OpenRead($item.path)
    try {
        $res.ContentLength64 = $fs.Length
        $fs.CopyTo($res.OutputStream, 1MB)
    } finally { $fs.Dispose() }
    $res.Close()
    Write-Host ('[{0}] {1} -> {2}' -f (Get-Date -Format 'HH:mm:ss'), $item.name, $ctx.Request.RemoteEndPoint.Address) -ForegroundColor Cyan
    if ($markDelivered) { Set-OutboxDelivered $ctx $item }
}

function Set-OutboxDelivered($ctx, $item) {
    if ($item.delivered) { return }
    [IO.File]::WriteAllText((Join-Path (Split-Path $item.path) '.delivered'), (Get-Date).ToString('o'))
    Write-Event @{ kind = 'sent'; name = $item.name; size = $item.size; from = "$($ctx.Request.RemoteEndPoint.Address)" }
}

function Complete-OutboxItem($ctx) {
    $item = Get-OutboxItems -IncludeDelivered | Where-Object id -eq $ctx.Request.QueryString['id']
    if (-not $item) { Send-Text $ctx 404 'Gone'; return }
    Set-OutboxDelivered $ctx $item
    Send-Text $ctx 200 'OK'
}

# --- versions -------------------------------------------------------------------
# The shortcuts append &sc=<main|recv>&sv=<version> to every request, the tray sends ?v= with
# its heartbeat, so the PC page can show what is really running and flag old copies.
$ClientsPath = Join-Path $DataDir 'clients.json'
$Clients = @{}
if (Test-Path -LiteralPath $ClientsPath) {
    (Get-Content -LiteralPath $ClientsPath -Raw | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $Clients[$_.Name] = @{ version = $_.Value.version; time = $_.Value.time } }
}
$script:TrayVersion = $null

function Register-Client($req) {
    $sc = $req.QueryString['sc']; $sv = $req.QueryString['sv']
    if ($sc -notin 'main', 'recv' -or -not $sv -or $sv.Length -gt 20) { return }
    $Clients[$sc] = @{ version = $sv; time = (Get-Date).ToString('o') }
    $Clients | ConvertTo-Json | Set-Content -LiteralPath $ClientsPath -Encoding UTF8
}

# --- clipboard ----------------------------------------------------------------
# PC -> iPhone: the request is parked until the tray app (polling /api/clip-wanted)
# posts the clipboard, so the PC clipboard is read only when the iPhone asks for it.
$ClipWaiters = New-Object System.Collections.ArrayList
$script:TrayLastSeen = [datetime]::MinValue

function Request-PcClipboard($ctx) {
    if (((Get-Date) - $script:TrayLastSeen).TotalSeconds -gt 5) {
        Send-Text $ctx 503 '電腦尚未登入，或系統匣的「傳到電腦」沒有執行'
        return
    }
    [void]$ClipWaiters.Add(@{ ctx = $ctx; at = Get-Date })
}

function Complete-ClipWaiters([int]$status, [byte[]]$bytes, [string]$type) {
    foreach ($w in @($ClipWaiters)) { try { Send-Bytes $w.ctx $status $bytes $type } catch { } }
    $ClipWaiters.Clear()
}

function Remove-ExpiredClipWaiters {
    foreach ($w in @($ClipWaiters)) {
        if (((Get-Date) - $w.at).TotalSeconds -gt 6) {
            try { Send-Text $w.ctx 504 '電腦沒有回應' } catch { }
            $ClipWaiters.Remove($w)
        }
    }
}

function Receive-ClipProvide($ctx) {
    $ms = New-Object IO.MemoryStream
    $ctx.Request.InputStream.CopyTo($ms)
    $type = if ($ctx.Request.ContentType) { $ctx.Request.ContentType } else { 'text/plain; charset=utf-8' }
    Complete-ClipWaiters 200 $ms.ToArray() $type
    Send-Text $ctx 200 'OK'
}

# iPhone -> PC: "clip" (file field, carries images) and/or "cliptext" (plain text).
# Saved under data\clip, never Downloads; the tray puts it on the clipboard.
function Receive-Clip($ctx) {
    $req = $ctx.Request
    $incoming = Join-Path $ClipDir 'incoming'
    New-Item -ItemType Directory -Force -Path $incoming | Out-Null
    Get-ChildItem -LiteralPath $ClipDir -File | Remove-Item -Force
    $text = $null; $image = $null; $dest = $null
    if ($req.ContentType -like 'multipart/form-data*') {
        $parts = @([Receiver]::SaveMultipart($req.InputStream, $req.ContentType, $incoming))
        $image = $parts | Where-Object { $_.IsFile -and $_.ContentType -like 'image/*' } | Select-Object -First 1
        $text = ($parts | Where-Object { -not $_.IsFile -and $_.Name -eq 'cliptext' } | Select-Object -First 1).Text
        if (-not $text) {
            $tf = $parts | Where-Object { $_.IsFile -and $_.ContentType -like 'text/plain*' } | Select-Object -First 1
            if ($tf) { $text = [IO.File]::ReadAllText($tf.Path, $Utf8) }
        }
    } elseif ($req.ContentType -like 'application/x-www-form-urlencoded*') {
        $text = (Read-UrlEncodedForm $req).cliptext
    } else {
        $text = (New-Object IO.StreamReader($req.InputStream, $Utf8)).ReadToEnd()
    }

    if ($image) {
        $dest = Join-Path $ClipDir ('clip' + [IO.Path]::GetExtension($image.Path))
        Move-Item -LiteralPath $image.Path -Destination $dest -Force
    } elseif ($text) {
        $dest = Join-Path $ClipDir 'clip.txt'
        [IO.File]::WriteAllText($dest, $text, $Utf8)
    }
    Remove-Item -LiteralPath $incoming -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $dest) { Send-Text $ctx 400 '剪貼簿是空的'; return }

    Write-Host ('[{0}] 剪貼簿 <- {1}' -f (Get-Date -Format 'HH:mm:ss'), $req.RemoteEndPoint.Address) -ForegroundColor Green
    # The log only points at the file, so clipboard contents (passwords…) aren't kept in history.
    Write-Event @{ kind = 'clip'; path = $dest; image = [bool]$image; from = "$($req.RemoteEndPoint.Address)" }
    Send-Text $ctx 200 'OK'
}

function Receive-Text($ctx) {
    $reader = New-Object IO.StreamReader($ctx.Request.InputStream, $Utf8)
    $text = $reader.ReadToEnd().Trim()
    if (-not $text) { Send-Text $ctx 400 'Empty'; return }
    Add-ReceivedText $ctx.Request $text
    Send-Text $ctx 200 'OK'
}

function Get-Addresses {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notlike 'vEthernet*' } |
        Sort-Object InterfaceAlias |
        ForEach-Object { @{ label = $_.InterfaceAlias; url = "http://$($_.IPAddress):$Port/?token=$Token" } }
}

function Get-Recent {
    if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
    $lines = @(Get-Content -LiteralPath $LogPath -Tail 30 -Encoding UTF8)
    [array]::Reverse($lines)
    foreach ($line in $lines) { try { $line | ConvertFrom-Json } catch { } }
}

$StaticFiles = @{
    '/app-icon.png'     = @{ path = 'assets\app-icon.png'; type = 'image/png' }
    '/apple-touch-icon.png' = @{ path = 'assets\app-icon.png'; type = 'image/png' }
    '/favicon.ico'      = @{ path = 'assets\app.ico'; type = 'image/x-icon' }
    '/qrcode.min.js'    = @{ path = 'vendor\qrcode.min.js'; type = 'text/javascript' }
    # Generic signed shortcut (no address/token inside), built by sign-shortcut.ps1
    '/shortcut'         = @{ path = 'shortcut\傳到電腦.shortcut'; type = 'application/octet-stream'
                             download = "attachment; filename=`"SendToPC.shortcut`"; filename*=UTF-8''%E5%82%B3%E5%88%B0%E9%9B%BB%E8%85%A6.shortcut" }
    '/shortcut-receive' = @{ path = 'shortcut\從電腦接收.shortcut'; type = 'application/octet-stream'
                             download = "attachment; filename=`"ReceiveFromPC.shortcut`"; filename*=UTF-8''%E5%BE%9E%E9%9B%BB%E8%85%A6%E6%8E%A5%E6%94%B6.shortcut" }
}

# --- listener ---------------------------------------------------------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
$localOnly = $false
try {
    $listener.Start()
} catch {
    # No URL ACL yet (install.ps1 not run): fall back to localhost so it still works for testing.
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
    $localOnly = $true
}

$indexHtml = [IO.File]::ReadAllText((Join-Path $AppDir 'index.html'), $Utf8)

Write-Host ''
Write-Host "  傳到電腦 v$Version 已啟動" -ForegroundColor Cyan
Write-Host "  儲存位置: $SaveDir"
Write-Host "  Token   : $Token" -ForegroundColor Yellow
if ($localOnly) {
    Write-Host "  只聽 localhost — 其他裝置連不到。請先以系統管理員身分執行 install.ps1" -ForegroundColor Red
} else {
    foreach ($a in Get-Addresses) { Write-Host ('  {0,-14} {1}' -f $a.label, $a.url) }
}
Write-Host '  按 Ctrl+C 停止'
Write-Host ''

try {
    while ($listener.IsListening) {
        $task = $listener.GetContextAsync()
        # Short waits keep Ctrl+C responsive and let parked clipboard requests time out.
        while (-not $task.AsyncWaitHandle.WaitOne(500)) { if ($ClipWaiters.Count) { Remove-ExpiredClipWaiters } }
        $ctx = $task.GetAwaiter().GetResult()
        try {
            $req = $ctx.Request
            $path = $req.Url.AbsolutePath
            $method = $req.HttpMethod
            # Every iPhone feature hangs off the one address the shortcut was given
            # (…/upload?token=… or …/?token=…), selected with &action=…
            $action = $req.QueryString['action']
            # Access log for troubleshooting the iPhone side: path and action only, never the token/ticket.
            if (-not $req.IsLocal) {
                $auth = if ($req.QueryString['ticket']) { 'ticket' } elseif ($req.QueryString['token'] -or $req.Headers['X-Token']) { 'token' } else { '-' }
                [IO.File]::AppendAllText((Join-Path $DataDir 'access.log'),
                    ('{0} {1} {2} {3} action={4} auth={5} sc={6} sv={7}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $req.RemoteEndPoint.Address,
                        $method, $path, $action, $auth, $req.QueryString['sc'], $req.QueryString['sv']) + "`r`n", $Utf8)
            }
            if ($req.QueryString['sv'] -and ((Test-Token $req) -or (Test-Ticket $req))) { Register-Client $req }
            if ($method -eq 'GET' -and $path -eq '/' -and -not $action) {
                Send-Text $ctx 200 $indexHtml 'text/html; charset=utf-8'
            } elseif ($method -eq 'GET' -and $StaticFiles.ContainsKey($path)) {
                $f = $StaticFiles[$path]
                $full = Join-Path $AppDir $f.path
                if ($f.download) { $ctx.Response.AddHeader('Content-Disposition', $f.download) }
                if (Test-Path -LiteralPath $full) { Send-Bytes $ctx 200 ([IO.File]::ReadAllBytes($full)) $f.type }
                else { Send-Text $ctx 404 'Not found' }
            } elseif ($method -eq 'GET' -and $path -eq '/api/health') {
                Send-Text $ctx 200 'OK'
            } elseif ($method -eq 'GET' -and $path -eq '/api/info' -and $req.IsLocal) {
                # PC-side page only: exposes the token, so never to other devices.
                Send-Json $ctx @{
                    name = $env:COMPUTERNAME; port = $Port; token = $Token; saveDir = $SaveDir
                    localOnly = $localOnly; addresses = @(Get-Addresses); recent = @(Get-Recent)
                    outbox = @(Get-OutboxItems -IncludeDelivered | ForEach-Object { @{ id = $_.id; name = $_.name; size = $_.size; delivered = $_.delivered } })
                    trayRunning = ((Get-Date) - $script:TrayLastSeen).TotalSeconds -le 5
                    ntfyTopic = $NtfyTopic; ntfyServer = $NtfyServer
                    version = $Version; trayVersion = $script:TrayVersion; clients = $Clients
                }
            } elseif ($method -eq 'GET' -and $path -eq '/api/clip-wanted' -and $req.IsLocal) {
                # Tray heartbeat; "1" means an iPhone is waiting for the PC clipboard.
                $script:TrayLastSeen = Get-Date
                if ($req.QueryString['v']) { $script:TrayVersion = $req.QueryString['v'] }
                if ($ClipWaiters.Count) { Send-Text $ctx 200 '1' } else { Send-Text $ctx 200 '0' }
            } elseif ($method -eq 'POST' -and $path -eq '/api/clip-provide' -and $req.IsLocal) {
                Receive-ClipProvide $ctx
            } elseif ($method -eq 'POST' -and $path -eq '/api/outbox' -and $req.IsLocal) {
                Add-OutboxFile $ctx
            } elseif ($method -eq 'POST' -and $path -eq '/api/outbox-added' -and $req.IsLocal) {
                # The tray queued files itself (Explorer 傳送到): one name per line.
                $names = (New-Object IO.StreamReader($req.InputStream, $Utf8)).ReadToEnd() -split "`n" | Where-Object { $_.Trim() }
                Send-Push @($names)
                Send-Text $ctx 200 'OK'
            } elseif ($method -eq 'GET' -and $path -in '/upload', '/' -and $action -eq 'outbox' -and (Test-Ticket $req)) {
                Send-OutboxList $ctx          # push ticket: outbox only
            } elseif ($method -eq 'GET' -and $path -like '/outbox/*' -and (Test-Ticket $req)) {
                Send-OutboxFile $ctx ($path.Split('/')[2]) $false
            } elseif ($method -eq 'GET' -and $path -in '/upload', '/' -and $action -eq 'done' -and (Test-Ticket $req)) {
                Complete-OutboxItem $ctx
            } elseif (-not (Test-Token $req)) {
                Send-Text $ctx 401 'Bad token'
            } elseif ($method -eq 'GET' -and $path -eq '/api/ping') {
                Send-Json $ctx @{ name = $env:COMPUTERNAME; ntfyTopic = $NtfyTopic; ntfyServer = $NtfyServer; version = $Version }
            } elseif ($method -eq 'GET' -and $path -in '/upload', '/' -and $action -eq 'outbox') {
                Send-OutboxList $ctx
            } elseif ($method -eq 'GET' -and $path -in '/upload', '/' -and $action -eq 'clipboard') {
                Request-PcClipboard $ctx      # answered later, when the tray posts the clipboard
            } elseif ($method -eq 'GET' -and $path -like '/outbox/*') {
                Send-OutboxFile $ctx ($path.Split('/')[2]) $true
            } elseif ($method -eq 'GET' -and $path -in '/upload', '/' -and $action -eq 'done') {
                Complete-OutboxItem $ctx
            } elseif ($method -eq 'POST' -and $path -in '/upload', '/' -and $action -eq 'clip') {
                Receive-Clip $ctx
            } elseif ($method -eq 'POST' -and $path -in '/upload', '/') {
                # "/" too: pasting the page address (…:8765/?token=…) into the shortcut also works.
                Receive-Upload $ctx
            } elseif ($method -eq 'POST' -and $path -eq '/text') {
                Receive-Text $ctx
            } else {
                Send-Text $ctx 404 'Not found'
            }
        } catch {
            Write-Host "錯誤: $($_.Exception.Message)" -ForegroundColor Red
            try { Send-Text $ctx 500 'Error' } catch { }
        }
        if ($ClipWaiters.Count) { Remove-ExpiredClipWaiters }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
