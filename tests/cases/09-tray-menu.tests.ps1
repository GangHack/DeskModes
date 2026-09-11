# --- drawing the tray menu --------------------------------------------------
# Two bugs in a row were invisible in the code and visible only in the pixels: for a DISABLED item
# the base ToolStripRenderer substitutes the system GrayText for our text colour, and runs the image
# through DrawImageDisabled. The rows of the DISPLAYS section are disabled deliberately
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

# Exercise the real WinForms layout without starting the tray or switching a display.
. (Get-TrayFunctionSource 'Update-TrayMenuWorkingArea')

Test-Case 'menu: completed rows fit above the taskbar after growing on open' {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    try {
        $area = New-Object System.Drawing.Rectangle 0, 0, 1280, 720
        $menu.Location = New-Object System.Drawing.Point 1100, 680
        foreach ($number in 1..24) {
            $item = New-Object System.Windows.Forms.ToolStripMenuItem "Mode $number"
            $item.Padding = New-Object System.Windows.Forms.Padding 0, 4, 0, 4
            [void]$menu.Items.Add($item)
        }
        Update-TrayMenuWorkingArea -Menu $menu -WorkingArea $area
        Assert-True ($area.Contains($menu.Bounds)) 'every edge is inside the working area'
        Assert-Equal 24 $menu.Items.Count 'no commands are removed to fit'
    }
    finally { $menu.Dispose() }
}

Test-Case 'menu: a tall menu scrolls and can grow again on a larger display' {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    # These rectangles model two screen sizes. A top-level popup is also clamped to the
    # host screen by WinForms, so a small CI desktop cannot represent the larger one.
    # Native top-level placement is covered by the ShowInTaskbar case below.
    $menu.TopLevel = $false
    try {
        foreach ($number in 1..40) { [void]$menu.Items.Add("Mode $number") }
        $small = New-Object System.Drawing.Rectangle 0, 0, 1000, 300
        Update-TrayMenuWorkingArea -Menu $menu -WorkingArea $small
        Assert-True ($small.Contains($menu.Bounds)) 'the menu fits the shorter display'
        # ToolStripDropDownMenu uses its own scroll buttons, not Control.AutoScroll.
        $flags = [System.Reflection.BindingFlags]'Instance,NonPublic'
        $scroll = [System.Windows.Forms.ToolStripDropDownMenu].GetProperty('RequiresScrollButtons', $flags)
        Assert-True ([bool]$scroll.GetValue($menu, $null)) 'overflow commands have scroll buttons'
        $shortHeight = $menu.Height

        $large = New-Object System.Drawing.Rectangle 0, 0, 1600, 1200
        Update-TrayMenuWorkingArea -Menu $menu -WorkingArea $large
        Assert-True ($menu.Height -gt $shortHeight) 'a previous small screen does not pin the height'
        Assert-True ($large.Contains($menu.Bounds)) 'the expanded menu still fits'
        Assert-True (-not [bool]$scroll.GetValue($menu, $null)) 'scroll buttons disappear when all rows fit'
    }
    finally { $menu.Dispose() }
}

Test-Case 'menu: fitting honors taskbars at the top or left' {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    try {
        [void]$menu.Items.Add('Settings')
        $area = New-Object System.Drawing.Rectangle 80, 60, 1000, 650
        $menu.Location = New-Object System.Drawing.Point 0, 0
        Update-TrayMenuWorkingArea -Menu $menu -WorkingArea $area
        Assert-True ($area.Contains($menu.Bounds)) 'offset working area contains the menu'
        Assert-Equal $area.Left $menu.Left 'left taskbar is excluded'
        Assert-Equal $area.Top $menu.Top 'top taskbar is excluded'
    }
    finally { $menu.Dispose() }
}

Test-Case 'menu: tray placement keeps the final rebuilt menu above the real taskbar' {
    # NotifyIcon uses a different path from ContextMenuStrip.Show: it positions again
    # after Opened. Exercise that exact path and the production handler, then drain the
    # queued fit. This creates only a disposable test menu, never the real tray process.
    $opened = (Get-TrayAst).FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Expression.Extent.Text -eq '$menu' -and $n.Member.Value -eq 'add_Opened'
    }, $true)
    Assert-Equal 1 $opened.Count 'one production Opened handler'
    $openedBody = [scriptblock]::Create($opened[0].Arguments[0].ScriptBlock.EndBlock.Extent.Text)
    function Write-MenuForegroundNote { }
    $script:MenuDismissTimer = New-Object System.Windows.Forms.Timer
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.AutoClose = $false   # The probe does not claim foreground activation from the user.
    [void]$menu.Items.Add('Previous layout')   # Opening replaces this smaller cached layout.
    try {
        $menu.add_Opening({
            $menu.Items.Clear()
            foreach ($number in 1..$script:TrayMenuTestRows) {
                $item = New-Object System.Windows.Forms.ToolStripMenuItem "Mode $number"
                $item.Padding = New-Object System.Windows.Forms.Padding 0, 4, 0, 4
                [void]$menu.Items.Add($item)
            }
        })
        $menu.add_Opened($openedBody)
        $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
        $show = $menu.GetType().GetMethod('ShowInTaskbar', [System.Reflection.BindingFlags]'Instance,NonPublic')
        foreach ($rowCount in 24, 80, 24) {
            $script:TrayMenuTestRows = $rowCount
            [void]$show.Invoke($menu, @([int]($screen.Bounds.Right - 100), [int]($screen.Bounds.Bottom - 15)))
            [System.Windows.Forms.Application]::DoEvents()
            Assert-True ($screen.WorkingArea.Contains($menu.Bounds)) "$rowCount rows fit after native placement"
            Assert-Equal $rowCount $menu.Items.Count 'all rebuilt commands remain present'
            $key = $menu.GetType().GetMethod('ProcessDialogKey', [System.Reflection.BindingFlags]'Instance,NonPublic')
            [void]$key.Invoke($menu, @([System.Windows.Forms.Keys]::End))
            $last = $menu.Items[$menu.Items.Count - 1]
            Assert-True $last.Selected 'the last command can be reached by keyboard'
            Assert-True ($last.Bounds.Bottom -le $menu.Height) 'the last command scrolls into view'
            $menu.Close()
        }
    }
    finally { $menu.Dispose(); $script:MenuDismissTimer.Dispose() }
}

. (Get-TrayFunctionSource 'Test-TrayMenuContainsPoint')
. (Get-TrayFunctionSource 'Update-TrayMenuDismissal')

Test-Case 'menu: an unactivated menu closes on a fresh outside click or Escape' {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.AutoClose = $false
    [void]$menu.Items.Add('Settings')
    $state = @{ Menu = $menu; MouseDown = $true; EscapeDown = $false }
    $outside = New-Object System.Drawing.Point -30000, -30000
    try {
        $menu.Show(100, 100)
        Update-TrayMenuDismissal -State $state -Point $outside -MouseDown $true -EscapeDown $false
        Assert-True $menu.Visible 'the held opening click is ignored'
        Update-TrayMenuDismissal -State $state -Point $outside -MouseDown $false -EscapeDown $false
        Assert-True $menu.Visible 'moving outside without clicking keeps the menu open'
        Update-TrayMenuDismissal -State $state -Point $outside -MouseDown $true -EscapeDown $false
        Assert-True (-not $menu.Visible) 'a fresh outside click closes even without activation'
        $menu.Show(100, 100)
        Update-TrayMenuDismissal -State $state -Point $outside -MouseDown $false -EscapeDown $true
        Assert-True (-not $menu.Visible) 'Escape closes even without activation'
    }
    finally { $menu.Dispose() }
}

Test-Case 'menu: clicks in the menu and its timer submenu do not dismiss it' {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.AutoClose = $false
    $parent = New-Object System.Windows.Forms.ToolStripMenuItem 'Timer'
    [void]$parent.DropDownItems.Add('In an hour')
    $parent.DropDown.AutoClose = $false
    [void]$menu.Items.Add($parent)
    $state = @{ Menu = $menu; MouseDown = $false; EscapeDown = $false }
    try {
        $menu.Show(100, 100)
        $inside = New-Object System.Drawing.Point ($menu.Left + 8), ($menu.Top + 8)
        Update-TrayMenuDismissal -State $state -Point $inside -MouseDown $true -EscapeDown $false
        Assert-True $menu.Visible 'a menu click is handled by the normal item events'
        $parent.ShowDropDown()
        $sub = $parent.DropDown
        $inside = New-Object System.Drawing.Point ($sub.Left + 8), ($sub.Top + 8)
        Update-TrayMenuDismissal -State $state -Point $inside -MouseDown $false -EscapeDown $false
        Update-TrayMenuDismissal -State $state -Point $inside -MouseDown $true -EscapeDown $false
        Assert-True $menu.Visible 'a submenu click is inside the menu tree'
        Assert-True $sub.Visible 'the timer options remain available'
    }
    finally { $menu.Dispose() }
}