# --- the tray menu's DPI ---------------------------------------------------
# The process runs in PER_MONITOR_AWARE_V2, so WinForms no longer stretches the menu for us. We test the
# scale number and the renderer's final pixels separately: that way the tests depend neither on the fonts
# nor on where the monitors really are.

Write-Host ''
Write-Host 'the tray menu at every DPI' -ForegroundColor White

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-DpiMenuRenderer {
    param([double]$Scale, [switch]$Legacy)
    $accent = [System.Drawing.Color]::FromArgb(0x4C, 0xC2, 0xFF)
    if ($Legacy) { return New-Object ModernMenuRenderer $false, $accent }
    return New-Object ModernMenuRenderer $false, $accent, ([single]$Scale)
}

function Get-MenuSeparatorBitmap {
    param($Renderer, [int]$Width = 64)
    $bmp = New-Object System.Drawing.Bitmap $Width, 9
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $strip = New-Object System.Windows.Forms.ToolStrip
    $separator = New-Object System.Windows.Forms.ToolStripSeparator
    $separator.AutoSize = $false
    $separator.Size = New-Object System.Drawing.Size $Width, 9
    [void]$strip.Items.Add($separator)
    $separator.Size = New-Object System.Drawing.Size $Width, 9
    try {
        $g.Clear([System.Drawing.Color]::White)
        $ev = New-Object System.Windows.Forms.ToolStripSeparatorRenderEventArgs (
            $g, $separator, $false)
        $Renderer.DrawSeparator($ev)
    }
    finally {
        $g.Dispose()
        $strip.Dispose()
    }
    return $bmp
}

function Get-MenuCheckBitmap {
    param($Renderer, [int]$Size)
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $item = New-Object System.Windows.Forms.ToolStripMenuItem 'Current'
    try {
        $g.Clear([System.Drawing.Color]::White)
        $rect = New-Object System.Drawing.Rectangle 0, 0, $Size, $Size
        $ev = New-Object System.Windows.Forms.ToolStripItemImageRenderEventArgs (
            $g, $item, $null, $rect)
        $Renderer.DrawItemCheck($ev)
    }
    finally {
        $g.Dispose()
        $item.Dispose()
    }
    return $bmp
}

function Measure-DifferentPixels {
    param($Left, $Right)
    $different = 0
    for ($y = 0; $y -lt $Left.Height; $y++) {
        for ($x = 0; $x -lt $Left.Width; $x++) {
            if ($Left.GetPixel($x, $y).ToArgb() -ne $Right.GetPixel($x, $y).ToArgb()) {
                $different++
            }
        }
    }
    return $different
}

function Measure-AccentPixels {
    param($Bitmap)
    $count = 0
    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $c = $Bitmap.GetPixel($x, $y)
            if ([int]$c.B - [Math]::Max([int]$c.R, [int]$c.G) -gt 20) { $count++ }
        }
    }
    return $count
}

Test-Case 'menu DPI: the scale follows the requested DPI and never shrinks' {
    Assert-Equal 1.0 (Get-UiScale -Dpi 96) '96 dpi'
    Assert-Equal 1.25 (Get-UiScale -Dpi 120) '120 dpi'
    Assert-Equal 1.5 (Get-UiScale -Dpi 144) '144 dpi'
    Assert-Equal 2.0 (Get-UiScale -Dpi 192) '192 dpi'
    Assert-Equal 1.0 (Get-UiScale -Dpi 72) 'below 96 dpi'
}

Test-Case 'menu DPI: the old renderer constructor is exactly scale one' {
    $legacy = Get-MenuSeparatorBitmap (New-DpiMenuRenderer -Scale 1 -Legacy)
    $scaled = Get-MenuSeparatorBitmap (New-DpiMenuRenderer -Scale 1)
    try { Assert-Equal 0 (Measure-DifferentPixels -Left $legacy -Right $scaled) 'different pixels' }
    finally { $legacy.Dispose(); $scaled.Dispose() }
}

Test-Case 'menu DPI: a double-scale separator has a double inset' {
    $normal = Get-MenuSeparatorBitmap (New-DpiMenuRenderer -Scale 1)
    $double = Get-MenuSeparatorBitmap (New-DpiMenuRenderer -Scale 2)
    try {
        $white = [System.Drawing.Color]::White.ToArgb()
        Assert-True ($normal.GetPixel(12, 4).ToArgb() -ne $white) 'scale one reaches x=12'
        Assert-Equal $white $double.GetPixel(5, 4).ToArgb() 'scale two leaves x=5 alone'
        Assert-Equal $white $double.GetPixel(12, 4).ToArgb() 'scale two leaves x=12 alone'
        Assert-True ($double.GetPixel(24, 4).ToArgb() -ne $white) 'scale two reaches x=24'
    }
    finally { $normal.Dispose(); $double.Dispose() }
}

Test-Case 'menu DPI: a double-scale check has a visibly heavier stroke' {
    $normal = Get-MenuCheckBitmap -Renderer (New-DpiMenuRenderer -Scale 1) -Size 16
    $double = Get-MenuCheckBitmap -Renderer (New-DpiMenuRenderer -Scale 2) -Size 32
    try {
        $normalPixels = Measure-AccentPixels $normal
        $doublePixels = Measure-AccentPixels $double
        Assert-True ($doublePixels -gt ($normalPixels * 2.5)) "accent pixels grow ($normalPixels -> $doublePixels)"
    }
    finally { $normal.Dispose(); $double.Dispose() }
}
