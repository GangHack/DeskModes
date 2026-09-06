#Requires -Version 5.1

<#
.SYNOPSIS
    Draws the DeskModes icon: two monitors on a graphite tile, the back one dim.

.DESCRIPTION
    Writes a real multi-size .ico (PNG inside, the Vista+ format) plus a preview
    sheet showing every size on a light and a dark background.

    Each size is drawn separately rather than scaled from one, so that the stroke
    widths and the ring can be tuned per size and the smallest stays readable.
    System.Drawing cannot save a multi-size .ico, so the header and the directory
    are assembled by hand.

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
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $s = [single]$Size
    # The tile is graphite rather than a colour so the icon sits with the system's own
    # monochrome tray glyphs instead of shouting among them, and it is opaque on purpose:
    # a white glyph with no backing vanishes on a light taskbar. The gradient is what keeps
    # it from reading as a flat black square, the faint ring is what separates it from a
    # dark taskbar.
    $tile = New-RoundedPath 0 0 $s $s ($s * 0.22)
    $rect = New-Object System.Drawing.RectangleF 0, 0, $s, $s
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(255, 58, 58, 64),
        [System.Drawing.Color]::FromArgb(255, 24, 24, 28),
        [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillPath($grad, $tile)
    $rw = [single][Math]::Max(1.0, $s * 0.03)
    $ring = New-RoundedPath ($rw / 2) ($rw / 2) ($s - $rw) ($s - $rw) ($s * 0.22 - $rw / 2)
    # At tray size the tile is a few dark pixels on a dark taskbar and the ring is all that
    # says where it ends, so there it is twice as bright as on the big sizes.
    $ringAlpha = if ($Size -le 20) { 80 } else { 40 }
    $ringPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb($ringAlpha, 255, 255, 255)), $rw
    $g.DrawPath($ringPen, $ring)
    $ring.Dispose(); $ringPen.Dispose()

    $lit = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $dim = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(130, 255, 255, 255))

    # The second monitor as a hint behind the first: a switch between displays, which is
    # the whole program in one picture. The FRONT monitor, stand included, sits at the
    # tile's centre: the eye takes the white shape for the picture and reads the icon as
    # lopsided when that shape is off-centre, however balanced the bounding box. The back
    # monitor is drawn at every size, 16 px included: the tray shows the 16 and the taskbar
    # button the 24, side by side on one screen, and a picture that changes between them
    # reads as two different programs.
    $back = New-RoundedPath ($s * 0.46) ($s * 0.14) ($s * 0.38) ($s * 0.28) ($s * 0.05)
    $g.FillPath($dim, $back)
    $back.Dispose()

    # the front monitor, with a gap in the tile's colour so it stands off the back one
    $sep = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 24, 24, 28)), ([single][Math]::Max(1.0, $s * 0.06))
    $scr = New-RoundedPath ($s * 0.25) ($s * 0.26) ($s * 0.50) ($s * 0.36) ($s * 0.06)
    $g.DrawPath($sep, $scr)
    $g.FillPath($lit, $scr)
    $scr.Dispose(); $sep.Dispose()

    # the stand and its foot
    $g.FillRectangle($lit, ($s * 0.46), ($s * 0.62), ($s * 0.08), ($s * 0.08))
    $base = New-RoundedPath ($s * 0.36) ($s * 0.70) ($s * 0.28) ($s * 0.07) ($s * 0.035)
    $g.FillPath($lit, $base)
    $base.Dispose()

    $tile.Dispose(); $grad.Dispose(); $lit.Dispose(); $dim.Dispose(); $g.Dispose()
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
