#Requires -Version 5.1

<#
.SYNOPSIS
    Draws the DeskModes icon: white monitors on a blue tile.

.DESCRIPTION
    Writes a real multi-size .ico (PNG inside, the Vista+ format) plus a preview
    sheet showing every size on a light and a dark background.

    Each size is drawn separately rather than scaled from one: at 16-20 px the
    second monitor turns to mush, so there it is left out and the silhouette stays
    readable. System.Drawing cannot save a multi-size .ico, so the header and the
    directory are assembled by hand.

.PARAMETER IcoPath
    Where to write the icon. Defaults to app.ico beside the scripts - the file the
    tray, the Start menu shortcut and the startup shortcut all use.

.PARAMETER PreviewPath
    Where to write the preview sheet. Defaults to preview.png beside the scripts.

.EXAMPLE
    .\Make-Icon.ps1
    Redraws app.ico and preview.png in place.
#>
param(
    [string]$IcoPath = (Join-Path $PSScriptRoot 'app.ico'),
    [string]$PreviewPath = (Join-Path $PSScriptRoot 'preview.png')
)

Add-Type -AssemblyName System.Drawing

function New-RoundedPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($R -le 0.01) { $p.AddRectangle((New-Object System.Drawing.RectangleF $X, $Y, $W, $H)); return $p }
    $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-IconBitmap {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $s = [single]$Size
    # the tile, with its gradient
    $tile = New-RoundedPath 0 0 $s $s ($s * 0.22)
    $rect = New-Object System.Drawing.RectangleF 0, 0, $s, $s
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(255, 96, 156, 255),
        [System.Drawing.Color]::FromArgb(255, 28, 88, 214),
        [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal)
    $g.FillPath($grad, $tile)

    $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $hint  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 255, 255, 255))
    # an outline in the tile's own colour — it separates the front monitor from the back one
    $sep = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 46, 104, 224)), ([single]([Math]::Max(1.0, $s * 0.055)))

    # The second monitor as a hint only. At 16-20 px it turns to mush, so there only
    # one screen is left — that way the silhouette reads.
    $twoScreens = $Size -ge 24
    if ($twoScreens) {
        $back = New-RoundedPath ($s*0.52) ($s*0.13) ($s*0.35) ($s*0.28) ($s*0.05)
        $g.FillPath($hint, $back)
        $back.Dispose()
    }

    # the front monitor
    $scr = New-RoundedPath ($s*0.13) ($s*0.24) ($s*0.58) ($s*0.38) ($s*0.06)
    if ($twoScreens) { $g.DrawPath($sep, $scr) }
    $g.FillPath($white, $scr)
    $scr.Dispose()

    # the stand and its foot
    $g.FillRectangle($white, ($s*0.375), ($s*0.62), ($s*0.10), ($s*0.09))
    $base = New-RoundedPath ($s*0.26) ($s*0.70) ($s*0.34) ($s*0.08) ($s*0.035)
    $g.FillPath($white, $base)
    $base.Dispose()

    $tile.Dispose(); $grad.Dispose(); $white.Dispose(); $hint.Dispose(); $sep.Dispose(); $g.Dispose()
    return $bmp
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$images = @()
foreach ($sz in $sizes) {
    $bmp = New-IconBitmap $sz
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $images += [pscustomobject]@{ Size = $sz; Bytes = $ms.ToArray(); Bitmap = $bmp }
    $ms.Dispose()
}

# --- assembling the .ico ----------------------------------------------------
$fs = New-Object System.IO.FileStream $IcoPath, ([System.IO.FileMode]::Create)
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([uint16]0)               # reserved
$bw.Write([uint16]1)               # type: icon
$bw.Write([uint16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($im in $images) {
    $dim = if ($im.Size -ge 256) { 0 } else { $im.Size }
    $bw.Write([byte]$dim)          # width
    $bw.Write([byte]$dim)          # height
    $bw.Write([byte]0)             # palette
    $bw.Write([byte]0)             # reserved
    $bw.Write([uint16]1)           # planes
    $bw.Write([uint16]32)          # bpp
    $bw.Write([uint32]$im.Bytes.Length)
    $bw.Write([uint32]$offset)
    $offset += $im.Bytes.Length
}
foreach ($im in $images) { $bw.Write($im.Bytes) }
$bw.Flush(); $bw.Dispose(); $fs.Dispose()
"ico written: $IcoPath  ($((Get-Item $IcoPath).Length) bytes, $($images.Count) sizes)"

# --- preview: the same sizes on a light and on a dark background -------------
$show = 16, 24, 32, 48, 128
$pad = 16
$w = [int]($pad + ($show | ForEach-Object { $_ + $pad } | Measure-Object -Sum).Sum)
$h = [int](128 + $pad * 3 + 128)
$pv = New-Object System.Drawing.Bitmap $w, $h
$pg = [System.Drawing.Graphics]::FromImage($pv)
$pg.Clear([System.Drawing.Color]::White)
$pg.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,32,32,32))),
                  0, [int]($h/2), $w, [int]($h/2))
$x = $pad
foreach ($sz in $show) {
    $im = $images | Where-Object { $_.Size -eq $sz } | Select-Object -First 1
    $pg.DrawImage($im.Bitmap, $x, [int](($h/2 - $sz)/2), $sz, $sz)
    $pg.DrawImage($im.Bitmap, $x, [int]($h/2 + ($h/2 - $sz)/2), $sz, $sz)
    $x += $sz + $pad
}
$pg.Dispose()
$pv.Save($PreviewPath, [System.Drawing.Imaging.ImageFormat]::Png)
$pv.Dispose()
foreach ($im in $images) { $im.Bitmap.Dispose() }
"preview: $PreviewPath"
