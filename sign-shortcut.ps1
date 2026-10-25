# Builds and signs the iPhone shortcuts with RoutineHub's HubSign service (iOS only imports
# signed shortcut files, and Apple's own signer needs a Mac). The plists are generic: they
# hold no address or token, so nothing private leaves this PC.
# Output: shortcut\傳到電腦.shortcut, shortcut\從電腦接收.shortcut
param([string[]]$Names = @('傳到電腦', '從電腦接收'))
$ErrorActionPreference = 'Stop'
$dir = Join-Path $PSScriptRoot 'shortcut'
& (Join-Path $dir 'build-shortcut.ps1')

function Invoke-HubSign([string]$name, [string]$plist) {
    $payload = @{ shortcutName = $name; shortcut = $plist } | ConvertTo-Json -Compress
    $body = [IO.Path]::GetTempFileName()
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($body, $payload, (New-Object Text.UTF8Encoding($false)))
        # curl.exe rather than Invoke-WebRequest: the service's CDN rejects the latter with 403.
        $status = curl.exe -sS -o $tmp -w '%{http_code}' -X POST 'https://hubsign.routinehub.services/sign' `
            -H 'Content-Type: application/json' --data-binary "@$body" --max-time 60
        $bytes = [IO.File]::ReadAllBytes($tmp)
    } finally { Remove-Item $body, $tmp -ErrorAction SilentlyContinue }
    if ($bytes.Length -ge 4 -and [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq 'AEA1') { return , $bytes }
    Write-Host "HubSign 回傳的不是已簽署的捷徑（HTTP $status，$($bytes.Length) bytes）" -ForegroundColor Yellow
    return $null
}

foreach ($name in $Names) {
    $plist = [IO.File]::ReadAllText((Join-Path $dir "$name.plist"), [Text.Encoding]::UTF8)
    $bytes = $null
    for ($attempt = 1; $attempt -le 4 -and -not $bytes; $attempt++) {   # HubSign fails intermittently
        if ($attempt -gt 1) { Start-Sleep 10 }
        $bytes = Invoke-HubSign $name $plist
    }
    if (-not $bytes) { throw "簽署 $name 失敗" }
    $out = Join-Path $dir "$name.shortcut"
    [IO.File]::WriteAllBytes($out, $bytes)
    Write-Host "已簽署：$out ($($bytes.Length) bytes)" -ForegroundColor Green
}
