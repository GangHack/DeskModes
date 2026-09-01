# --- the desk preview -------------------------------------------------------
# The picture is worked out by the same function the switcher works with (Get-LayoutPositions), so
# there is exactly one thing to test: what goes into it.

Write-Host ''
Write-Host 'the desk preview' -ForegroundColor White

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
