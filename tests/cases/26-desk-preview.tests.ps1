# --- the desk drawn into its cards ------------------------------------------
# The cards ARE the picture of the desk: the same displays, the same order, the same taskbar, with
# no second drawing under them to disagree with. What "to scale" means here is the size of the
# PANEL and not its resolution - drawing by pixels gave a 24-inch 4K half again as much width as
# the 27-inch 1440p beside it, which is the opposite of what is on the desk.
#
# The inches come out of the EDID, and reading one is pure: bytes in, centimetres out.

Write-Host ''
Write-Host 'the desk drawn into its cards' -ForegroundColor White

# The size the cards will be drawn to, seeded the way render-preview.ps1 seeds an invented desk:
# these monitors are plugged into nothing and the registry has never heard of them.
function Set-TestInches {
    param([string]$Id, [double]$Inches)
    $script:MonitorSizeCache[$Id] = $(if ($Inches -gt 0) {
        [pscustomobject]@{ WidthCm = 0; HeightCm = 0; Inches = $Inches }
    } else { $null })
}

Test-Case 'edid: the panel size is two bytes of the base block, in centimetres' {
    # A real block off this desk: 60 x 34 cm is a 27-inch 16:9.
    $edid = New-Object byte[] 128
    $edid[21] = 60; $edid[22] = 34
    $size = ConvertFrom-EdidSize -Edid $edid
    Assert-Equal 60 $size.WidthCm 'the width as written'
    Assert-Equal 27.2 $size.Inches 'and the diagonal of it'

    # A 24-inch 4K: a smaller panel with more pixels in it than the 27 above.
    $edid[21] = 53; $edid[22] = 30
    Assert-Equal 24 (ConvertFrom-EdidSize -Edid $edid).Inches 'the small one'
}

Test-Case 'edid: zeros are "not said", not a tiny monitor' {
    # Projectors and network displays write nothing there, and a television writes its aspect
    # ratio into those bytes instead of a size.
    $edid = New-Object byte[] 128
    Assert-Null (ConvertFrom-EdidSize -Edid $edid) 'nothing said'
    Assert-Null (ConvertFrom-EdidSize -Edid ([byte[]]@(1, 2, 3))) 'and a block too short to hold it'
    Assert-Null (ConvertFrom-EdidSize -Edid $null) 'and no block at all'
}

Test-Case 'desk: the bigger panel is drawn wider, but not by as much as it is bigger' {
    # 24 against 27 inches: the square root damps 89 % down to 94 %. Visible, and neither of them
    # a thumbnail - which is what the row of cards is for.
    $state = @(
        (New-FakeMonitor 'SMALL 4K' 'S1' 'inch-24')
        (New-FakeMonitor 'BIG QHD' 'S2' 'inch-27')
    )
    $state[0].Width = 3840; $state[0].Height = 2160
    Set-TestInches -Id 'inch-24' -Inches 24.0
    Set-TestInches -Id 'inch-27' -Inches 27.2
    $settings = Get-DefaultSettings
    $settings.layout = @('SMALL 4K', 'BIG QHD')
    $ui = New-DialogUi -Settings $settings -State $state
    try {
        $small = $ui.DeskPanel.Children[0].Tag
        $big = $ui.DeskPanel.Children[1].Tag
        Assert-True ($big.Mini.Width -gt $small.Mini.Width) 'the 27-inch panel is the wider one'
        $ratio = [double]$small.Mini.Width / [double]$big.Mini.Width
        Assert-True ($ratio -gt 0.9 -and $ratio -lt 0.98) "damped, not proportional (came out $ratio)"
        # And the drawing by resolution is gone: the 4K one used to be half again as wide.
        Assert-True ($small.Mini.Width -lt $big.Mini.Width) 'pixels no longer decide the size'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'desk: a monitor whose EDID says no size is drawn like its neighbours' {
    $state = @(
        (New-FakeMonitor 'KNOWN' 'S1' 'inch-27b')
        (New-FakeMonitor 'SILENT' 'S2' 'inch-none')
    )
    Set-TestInches -Id 'inch-27b' -Inches 27.2
    Set-TestInches -Id 'inch-none' -Inches 0
    $settings = Get-DefaultSettings
    $settings.layout = @('KNOWN', 'SILENT')
    $ui = New-DialogUi -Settings $settings -State $state
    try {
        $known = $ui.DeskPanel.Children[0].Tag
        $silent = $ui.DeskPanel.Children[1].Tag
        Assert-Equal 0 ([double]$silent.Inches) 'nothing is known about it'
        Assert-Equal ([double]$known.Mini.Width) ([double]$silent.Mini.Width) 'and it is drawn like the one that is'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'desk: the shape of the screen is still the resolution' {
    # The size comes from the inches, the proportion from the pixels: a 21:9 panel stays a long
    # one, and it is not stretched to the shape of the card.
    $state = @((New-FakeMonitor 'ULTRAWIDE' 'S1' 'inch-uw'))
    $state[0].Width = 3440; $state[0].Height = 1440
    Set-TestInches -Id 'inch-uw' -Inches 34.0
    $ui = New-DialogUi -Settings (Get-DefaultSettings) -State $state
    try {
        $info = $ui.DeskPanel.Children[0].Tag
        $shape = [double]$info.Mini.Width / [double]$info.Mini.Height
        Assert-True ([math]::Abs($shape - 3440.0 / 1440.0) -lt 0.15) "the shape is the display's ($shape)"
        Assert-True ($info.Mini.Width -le $info.Inner) 'and it stays inside its card'
        Assert-True ($info.Mini.Height -le [double]$info.Band.Height) 'and inside the band'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'desk: no card is drawn wider than the card it sits in' {
    # A 32:9 panel drawn to the full width of its card would still be short enough for the band,
    # but a 4:3 one would not - and the whole row shrinks together rather than one card alone.
    $state = @(
        (New-FakeMonitor 'SQUARE' 'S1' 'inch-sq')
        (New-FakeMonitor 'WIDE' 'S2' 'inch-wide')
    )
    $state[0].Width = 1600; $state[0].Height = 1200
    $state[1].Width = 3840; $state[1].Height = 1080
    Set-TestInches -Id 'inch-sq' -Inches 21.0
    Set-TestInches -Id 'inch-wide' -Inches 49.0
    $settings = Get-DefaultSettings
    $settings.layout = @('SQUARE', 'WIDE')
    $ui = New-DialogUi -Settings $settings -State $state
    try {
        foreach ($child in @($ui.DeskPanel.Children)) {
            $info = $child.Tag
            Assert-True ($info.Mini.Width -le $info.Inner) 'inside the card'
            Assert-True ($info.Mini.Height -le [double]$info.Band.Height) 'and inside the band'
        }
        # The bigger panel is still the bigger drawing after the shrink.
        Assert-True ($ui.DeskPanel.Children[1].Tag.Mini.Width -gt $ui.DeskPanel.Children[0].Tag.Mini.Width) `
                    'the 49-inch one is still the wider'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'desk: the taskbar display is the one outlined' {
    $settings = Get-DefaultSettings
    $settings.primary = 'LG ULTRAGEAR'
    $ui = New-DialogUi -Settings $settings
    try {
        $picked = @($ui.DeskPanel.Children | Where-Object { $_.Tag.Radio.IsChecked })
        Assert-Equal 1 $picked.Count 'exactly one star is set'
        Assert-Equal 'LG ULTRAGEAR' ([string]$picked[0].Tag.Label) 'and it is the one from the settings'
        Assert-Equal 2 ([int]$picked[0].Tag.Mini.BorderThickness.Top) 'its screen is outlined'
        $others = @($ui.DeskPanel.Children | Where-Object { -not $_.Tag.Radio.IsChecked })
        Assert-Equal 1 ([int]$others[0].Tag.Mini.BorderThickness.Top) 'and nobody else is'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'desk: there is no second picture left to disagree with the cards' {
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    try {
        Assert-Null $ui.Window.FindName('PreviewCanvas') 'the canvas is gone'
        Assert-Null $ui.Window.FindName('PreviewBox') 'and so is the box it sat in'
    }
    finally { $ui.Window.Close() }
}
