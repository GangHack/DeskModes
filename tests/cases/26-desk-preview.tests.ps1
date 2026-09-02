# --- the desk drawn into its cards ------------------------------------------
# There used to be a second picture under the row of cards saying the same thing twice: the same
# displays, the same order, the same taskbar. The cards ARE the picture now - each card's screen
# is sized and offset by Get-LayoutPositions, the function the switcher itself uses - so the row
# shows what will come out, and there is no drawing left to disagree with it.
#
# What goes INTO that calculation is still the thing worth testing, and it is still pure.

Write-Host ''
Write-Host 'the desk drawn into its cards' -ForegroundColor White

Test-Case 'preview: pixel sizes come from the cards' {
    $cards = @(
        [pscustomobject]@{ Label = 'LG ULTRAFINE'; Width = 3840; Height = 2160; Connected = $true; Primary = $false }
        [pscustomobject]@{ Label = 'LG ULTRAGEAR'; Width = 2560; Height = 1440; Connected = $true; Primary = $true }
    )
    $screens = @(ConvertTo-PreviewScreens -Cards $cards)
    Assert-Equal 2 $screens.Count 'both'
    Assert-Equal 3840 $screens[0].Width 'the 4K panel'
    Assert-Equal 1440 $screens[1].Height 'and the 1440p one'
    Assert-True $screens[1].Primary 'the taskbar star came through'
}

Test-Case 'preview: a display of unknown size still takes its place in the row' {
    # A reminder card from a monitor that was pulled out: it has no size, but it does take up its place
    # in the row — otherwise the preview would show a different desk.
    $cards = @([pscustomobject]@{ Label = 'XG27AQDMGR'; Width = 0; Height = 0; Connected = $false; Primary = $false })
    $screens = @(ConvertTo-PreviewScreens -Cards $cards)
    Assert-Equal 1 $screens.Count 'still there'
    Assert-Equal 1920 $screens[0].Width 'a plain 16:9 stands in'
    Assert-Equal 1080 $screens[0].Height 'both ways'
}

Test-Case 'preview: what it draws is what the switcher will do' {
    # Screens of different heights are aligned centred, and that is exactly what has to be visible in
    # the picture: 2160 and 1440 give an offset of (2160-1440)/2 = 360.
    $cards = @(
        [pscustomobject]@{ Label = 'LG ULTRAFINE'; Width = 3840; Height = 2160; Connected = $true; Primary = $true }
        [pscustomobject]@{ Label = 'LG ULTRAGEAR'; Width = 2560; Height = 1440; Connected = $true; Primary = $false }
    )
    $pos = Get-PreviewPlacement -Screens @(ConvertTo-PreviewScreens -Cards $cards)
    Assert-Equal 0 $pos['preview-0'].X 'the first sits at zero'
    Assert-Equal 3840 $pos['preview-1'].X 'the second right after it'
    Assert-Equal 360 $pos['preview-1'].Y 'and lower by half the difference in height'
}

Test-Case 'preview: the cards decide the order, not the alphabet' {
    # A regression: with an empty Order every screen has the same rank, and the layout was sorted by
    # name. The picture showed ULTRAFINE, ULTRAGEAR, XG27AQDMGR while the cards stood ULTRAFINE,
    # XG27AQDMGR, ULTRAGEAR — that is, the preview promised a desk other than the one that would come out.
    $cards = @(
        [pscustomobject]@{ Label = 'LG ULTRAFINE'; Width = 3840; Height = 2160; Connected = $true; Primary = $false }
        [pscustomobject]@{ Label = 'XG27AQDMGR';   Width = 2560; Height = 1440; Connected = $true; Primary = $true }
        [pscustomobject]@{ Label = 'LG ULTRAGEAR'; Width = 2560; Height = 1440; Connected = $true; Primary = $false }
    )
    $pos = Get-PreviewPlacement -Screens @(ConvertTo-PreviewScreens -Cards $cards)
    Assert-True ($pos['preview-0'].X -lt $pos['preview-1'].X) 'the first card is left of the second'
    Assert-True ($pos['preview-1'].X -lt $pos['preview-2'].X) 'and the second is left of the third'
}

Test-Case 'preview: the taskbar display is where the coordinates start' {
    # Windows makes primary whoever's top-left corner lies at (0,0) — and the picture has to show it the
    # same way, or it is drawing somebody else's layout.
    $cards = @(
        [pscustomobject]@{ Label = 'LG ULTRAFINE'; Width = 3840; Height = 2160; Connected = $true; Primary = $false }
        [pscustomobject]@{ Label = 'LG ULTRAGEAR'; Width = 2560; Height = 1440; Connected = $true; Primary = $true }
    )
    $pos = Get-PreviewPlacement -Screens @(ConvertTo-PreviewScreens -Cards $cards)
    Assert-Equal 0 $pos['preview-1'].X 'the taskbar display sits at zero'
    Assert-Equal 0 $pos['preview-1'].Y 'both ways'
    Assert-Equal -3840 $pos['preview-0'].X 'and the other one is to the left of it'
}

Test-Case 'desk: a card carries a screen drawn to the desk scale' {
    # The point of the merge: a 4K panel has to LOOK bigger than the 1440p one beside it, and be
    # drawn at the offset the switcher will really give it.
    $state = @(
        (New-FakeMonitor 'BIG 4K' 'S1' 'p1')
        (New-FakeMonitor 'SMALL QHD' 'S2' 'p2')
    )
    $state[0].Width = 3840; $state[0].Height = 2160
    $state[1].Width = 2560; $state[1].Height = 1440
    $settings = Get-DefaultSettings
    $settings.layout = @('BIG 4K', 'SMALL QHD')
    $ui = New-DialogUi -Settings $settings -State $state
    try {
        $big = $ui.DeskPanel.Children[0].Tag
        $small = $ui.DeskPanel.Children[1].Tag
        Assert-True ($big.Mini.Width -gt $small.Mini.Width) 'the 4K panel is drawn wider'
        Assert-True ($big.Mini.Height -gt $small.Mini.Height) 'and taller'
        # 16:9 both, so the shapes must keep their proportion within a pixel of rounding.
        Assert-True ([math]::Abs($big.Mini.Width / $big.Mini.Height - 16.0 / 9.0) -lt 0.1) 'the shape is the display'
        # Centred vertically: (2160-1440)/2 = 360 of desk, so the smaller one sits lower.
        Assert-Equal 0 ([int]$big.Mini.Margin.Top) 'the tallest starts at the top of the band'
        Assert-True ([int]$small.Mini.Margin.Top -gt 0) 'and the shorter one is pushed down, as it will be'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'desk: no card is drawn wider than the card it sits in' {
    # One scale for the whole desk, and the card is the tighter of the two limits. Without that a
    # 4K panel is drawn past its own border and over its neighbour.
    $state = @((New-FakeMonitor 'HUGE' 'S1' 'p1'))
    $state[0].Width = 7680; $state[0].Height = 2160
    $ui = New-DialogUi -Settings (Get-DefaultSettings) -State $state
    try {
        $info = $ui.DeskPanel.Children[0].Tag
        Assert-True ($info.Mini.Width -le $info.Inner) 'it stays inside the card'
        Assert-True ($info.Mini.Height -le [double]$info.Band.Height) 'and inside the band'
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
