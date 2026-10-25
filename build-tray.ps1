# Compiles Tray.cs into AirDropReceiver.exe using the C# compiler that ships with Windows (.NET Framework 4.x).
$ErrorActionPreference = 'Stop'
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$out = Join-Path $PSScriptRoot 'AirDropReceiver.exe'

$version = (Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
# Stamp the VERSION file into the exe (shown in the tray, reported to the server).
$info = Join-Path $env:TEMP 'AirDropReceiver.AssemblyInfo.cs'
[IO.File]::WriteAllText($info, @"
using System.Reflection;
[assembly: AssemblyTitle("傳到電腦")]
[assembly: AssemblyProduct("傳到電腦")]
[assembly: AssemblyInformationalVersion("$version")]
[assembly: AssemblyFileVersion("$version.0")]
[assembly: AssemblyVersion("$version.0")]
"@, (New-Object Text.UTF8Encoding($true)))

Get-Process AirDropReceiver -ErrorAction SilentlyContinue | Stop-Process -Force
& $csc /nologo /target:winexe /optimize+ /codepage:65001 `
    "/win32icon:$(Join-Path $PSScriptRoot 'assets\app.ico')" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll `
    /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll `
    "/out:$out" (Join-Path $PSScriptRoot 'Tray.cs') $info
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
Write-Host "Built $out (v$version)"
