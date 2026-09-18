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

# --- a shortcut on a row that cannot be clicked -----------------------------
# A menu item with a shortcut is painted by TWO calls to OnRenderItemText, one per rectangle. The
# test that tells those two apart used to sit inside the "enabled" branch, so a mode whose display
# is unplugged - disabled on purpose, and still bound to a key - took the two-tone path for BOTH
# calls. That path strips the Right alignment, which is exactly what puts a shortcut in its own
# column, and "Ctrl+Alt+F2" was drawn on top of "Only LG ULTRAFINE".
#
# A real ContextMenuStrip, laid out by WinForms and drawn into a bitmap without ever being shown:
# the whole bug lives in the rectangles WinForms hands the renderer, and a hand-built event makes
# those up - two earlier attempts at this test did exactly that and passed against the bug.
#
# The two rows carry the SAME text and the SAME shortcut and differ only in Enabled. So what is
# compared is how much ink lands in the shortcut's column, and the enabled row - which goes through
# the base renderer and has always been placed correctly - is the figure the disabled one has to
# match. Nothing here depends on the font, the theme or the DPI; with the bug in place the disabled
# row scored 119 against the enabled row's 424.

function New-ShortcutRowMenu {
    param([string]$Text = 'Only LG ULTRAFINE', [string]$Keys = 'Ctrl+Alt+F2')

    $accent = [System.Drawing.Color]::FromArgb(0x4C, 0xC2, 0xFF)
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Renderer = New-Object ModernMenuRenderer $false, $accent, ([single]1.0)
    $menu.ShowImageMargin = $true
    foreach ($enabled in @($true, $false)) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $Text
        $item.ShortcutKeyDisplayString = $Keys
        $item.Enabled = $enabled
        [void]$menu.Items.Add($item)
    }
    # Its own preferred size: forcing one makes WinForms lay the text out differently, and the
    # rectangles are the thing under test.
    $menu.PerformLayout()
    $menu.Size = $menu.PreferredSize
    return $menu
}

# Pixels that are not the menu's own background, inside a band. The background is the bitmap's
# commonest colour rather than a number written down here: the renderer owns that colour, and a
# copy of it would go red the day the palette moves.
function Measure-MenuBandInk {
    param($Bitmap, [int]$FromX, [int]$FromY, [int]$ToY)

    $counts = @{}
    for ($x = 0; $x -lt $Bitmap.Width; $x++) {
        for ($y = 0; $y -lt $Bitmap.Height; $y++) {
            $v = $Bitmap.GetPixel($x, $y).ToArgb()
            $counts[$v] = 1 + $counts[$v]
        }
    }
    $back = ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key

    $ink = 0
    for ($x = $FromX; $x -lt $Bitmap.Width; $x++) {
        for ($y = $FromY; $y -lt $ToY; $y++) {
            if ($Bitmap.GetPixel($x, $y).ToArgb() -ne $back) { $ink++ }
        }
    }
    return $ink
}

Test-Case 'menu: an unavailable mode draws its shortcut in the shortcut column' {
    $menu = New-ShortcutRowMenu
    $bmp = New-Object System.Drawing.Bitmap $menu.Width, $menu.Height
    try {
        $menu.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $menu.Width, $menu.Height))
        $half = [int]($bmp.Height / 2)
        # The right quarter and a bit: past every name this menu holds, and over the column the
        # base renderer right-aligns a shortcut into.
        $column = [int]($bmp.Width * 0.72)
        $enabled  = Measure-MenuBandInk -Bitmap $bmp -FromX $column -FromY 0 -ToY $half
        $disabled = Measure-MenuBandInk -Bitmap $bmp -FromX $column -FromY $half -ToY $bmp.Height

        Assert-True ($enabled -gt 0) 'the enabled row has its shortcut there to begin with'
        # Same string, same font, same column: the two differ in colour and in nothing else, and
        # the anti-aliasing of one tone against another is the whole of the tolerance.
        $off = [Math]::Abs($enabled - $disabled)
        Assert-True ($off -le ($enabled * 0.1)) `
            "the unavailable row draws it in the same place (enabled $enabled, disabled $disabled)"
    }
    finally { $bmp.Dispose(); $menu.Dispose() }
}
