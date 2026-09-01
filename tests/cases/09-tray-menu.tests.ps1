# --- drawing the tray menu --------------------------------------------------
# Two bugs in a row were invisible in the code and visible only in the pixels: for a DISABLED item
# the base ToolStripRenderer substitutes the system GrayText for our text colour, and runs the image
# through DrawImageDisabled. The rows of the CONNECTED DISPLAYS section are disabled deliberately
# (they cannot be clicked) — and the whole section faded out: the text was barely readable, and the
# green/amber/grey status dots turned into three identical grey smudges.
#
# What we check is not "the code is in place" but the result: we draw with the real renderer into a
# Bitmap through the public DrawItemText/DrawItemImage (no window needed) and look at the pixels.
# Put base back and the tests turn red.

Write-Host ''
Write-Host 'the tray menu renderer' -ForegroundColor White

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-DisabledInfoItem {
    param([string]$Text = 'LG ULTRAGEAR    2560 x 1440 @ 144 Hz')
    $strip = New-Object System.Windows.Forms.ToolStrip
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $Text
    $item.Enabled = $false
    $item.Tag = 'info'
    [void]$strip.Items.Add($item)
    return $item
}

# The brightest and the most colourful pixel — those are what we judge by.
function Measure-Bitmap {
    param($Bitmap)
    $maxLum = 0; $bestGreen = -999
    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $c = $Bitmap.GetPixel($x, $y)
            $lum = [int](0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B)
            if ($lum -gt $maxLum) { $maxLum = $lum }
            $green = [int]$c.G - [Math]::Max([int]$c.R, [int]$c.B)
            if ($green -gt $bestGreen) { $bestGreen = $green }
        }
    }
    return [pscustomobject]@{ MaxLuminance = $maxLum; Greenness = $bestGreen }
}

Test-Case 'menu: a disabled display row is drawn in our bright colour, not system grey' {
    $renderer = New-Object ModernMenuRenderer $true, ([System.Drawing.Color]::FromArgb(0x4C, 0xC2, 0xFF))
    $item = New-DisabledInfoItem
    $bmp = New-Object System.Drawing.Bitmap 320, 20
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::FromArgb(0x2C, 0x2C, 0x2C))
        $rect = New-Object System.Drawing.Rectangle 0, 0, 320, 20
        $font = New-Object System.Drawing.Font 'Segoe UI', 9.75
        $ev = New-Object System.Windows.Forms.ToolStripItemTextRenderEventArgs (
            $g, $item, $item.Text, $rect, [System.Drawing.Color]::Red, $font,
            [System.Windows.Forms.TextFormatFlags]::VerticalCenter)
        $renderer.DrawItemText($ev)

        $seen = Measure-Bitmap $bmp
        # SystemColors.GrayText, which base draws with, gives a brightness of about 110.
        # Our _text (#F2F2F2) is above 200. The threshold between them has plenty of room.
        Assert-True ($seen.MaxLuminance -gt 170) "display name is bright (saw $($seen.MaxLuminance))"
        $font.Dispose()
    }
    finally { $g.Dispose(); $bmp.Dispose() }
}

Test-Case 'menu: a status dot keeps its colour on a disabled row' {
    $renderer = New-Object ModernMenuRenderer $true, ([System.Drawing.Color]::FromArgb(0x4C, 0xC2, 0xFF))
    $item = New-DisabledInfoItem
    $dot = New-Object System.Drawing.Bitmap 16, 16
    $dg = [System.Drawing.Graphics]::FromImage($dot)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0x3F, 0xB9, 0x50))
    $dg.FillEllipse($brush, 4, 4, 8, 8)
    $brush.Dispose(); $dg.Dispose()

    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::FromArgb(0x2C, 0x2C, 0x2C))
        $ev = New-Object System.Windows.Forms.ToolStripItemImageRenderEventArgs (
            $g, $item, $dot, (New-Object System.Drawing.Rectangle 0, 0, 16, 16))
        $renderer.DrawItemImage($ev)

        $seen = Measure-Bitmap $bmp
        # DrawImageDisabled, which base draws with, hands back grey: the green goes to 0.
        Assert-True ($seen.Greenness -gt 40) "the dot is still green (saw $($seen.Greenness))"
    }
    finally { $g.Dispose(); $bmp.Dispose(); $dot.Dispose() }
}

Test-Case 'menu: an unavailable mode stays readable too, just quieter' {
    # An unavailable mode ("not connected") is disabled too, but it is not an info line: it is drawn
    # in a dimmed tone - and still not in the system grey.
    $renderer = New-Object ModernMenuRenderer $true, ([System.Drawing.Color]::FromArgb(0x4C, 0xC2, 0xFF))
    $strip = New-Object System.Windows.Forms.ToolStrip
    $item = New-Object System.Windows.Forms.ToolStripMenuItem 'Only DELL U2720Q   (not connected)'
    $item.Enabled = $false
    [void]$strip.Items.Add($item)

    $bmp = New-Object System.Drawing.Bitmap 320, 20
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::FromArgb(0x2C, 0x2C, 0x2C))
        $font = New-Object System.Drawing.Font 'Segoe UI', 9.75
        $ev = New-Object System.Windows.Forms.ToolStripItemTextRenderEventArgs (
            $g, $item, $item.Text, (New-Object System.Drawing.Rectangle 0, 0, 320, 20),
            [System.Drawing.Color]::Red, $font, [System.Windows.Forms.TextFormatFlags]::VerticalCenter)
        $renderer.DrawItemText($ev)
        $seen = Measure-Bitmap $bmp
        Assert-True ($seen.MaxLuminance -gt 130) "dim but legible (saw $($seen.MaxLuminance))"
        Assert-True ($seen.MaxLuminance -lt 200) 'and quieter than a live row'
        $font.Dispose()
    }
    finally { $g.Dispose(); $bmp.Dispose() }
}
