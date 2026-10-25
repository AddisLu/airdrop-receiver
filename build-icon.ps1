# Renders the app icon (arrow dropping into a tray) to assets\app.ico and assets\app-icon.png.
# Geometry matches the Claude Design icon artboard: 512-unit grid, thicker strokes at small sizes.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$assets = Join-Path $PSScriptRoot 'assets'
New-Item -ItemType Directory -Force -Path $assets | Out-Null
$accent = [Drawing.Color]::FromArgb(0x1F, 0x5E, 0xFF)

function New-IconBitmap([int]$size, [bool]$rounded = $true) {
    $bmp = New-Object Drawing.Bitmap($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.ScaleTransform($size / 512, $size / 512)

    $bg = New-Object Drawing.Drawing2D.GraphicsPath
    if ($rounded) {
        $r = 224   # corner diameter (rx 112)
        $bg.AddArc(0, 0, $r, $r, 180, 90); $bg.AddArc(512 - $r, 0, $r, $r, 270, 90)
        $bg.AddArc(512 - $r, 512 - $r, $r, $r, 0, 90); $bg.AddArc(0, 512 - $r, $r, $r, 90, 90)
        $bg.CloseFigure()
    } else {
        $bg.AddRectangle((New-Object Drawing.RectangleF(0, 0, 512, 512)))   # iOS rounds it itself
    }
    $g.FillPath((New-Object Drawing.SolidBrush($accent)), $bg)

    $stroke = if ($size -le 16) { 56 } elseif ($size -le 32) { 48 } else { 40 }
    $pen = New-Object Drawing.Pen([Drawing.Color]::White, $stroke)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'

    $g.DrawLine($pen, 256, 112, 256, 296)
    $g.DrawLines($pen, [Drawing.PointF[]]@(
        (New-Object Drawing.PointF(184, 228)), (New-Object Drawing.PointF(256, 300)), (New-Object Drawing.PointF(328, 228))))

    $tray = New-Object Drawing.Drawing2D.GraphicsPath
    $tray.AddLine(128, 284, 128, 352)
    $tray.AddArc(128, 324, 56, 56, 180, -90)
    $tray.AddLine(156, 380, 356, 380)
    $tray.AddArc(328, 324, 56, 56, 90, -90)
    $tray.AddLine(384, 352, 384, 284)
    $g.DrawPath($pen, $tray)

    $g.Dispose()
    return $bmp
}

function Get-PngBytes($bmp) {
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    return , $ms.ToArray()   # comma keeps the byte[] from being unrolled
}

# .ico with PNG-compressed entries (supported since Windows Vista)
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$images = foreach ($s in $sizes) { , (Get-PngBytes (New-IconBitmap $s)) }
$ms = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter($ms)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$images[$i].Length); $w.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($img in $images) { $w.Write($img) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $assets 'app.ico'), $ms.ToArray())

# 180px square for iPhone "加入主畫面"
[IO.File]::WriteAllBytes((Join-Path $assets 'app-icon.png'), (Get-PngBytes (New-IconBitmap 180 $false)))
# Large preview
[IO.File]::WriteAllBytes((Join-Path $assets 'app-icon-512.png'), (Get-PngBytes (New-IconBitmap 512)))

Write-Host "Icon written to $assets"
