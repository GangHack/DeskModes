# --- предпросмотр стола -----------------------------------------------------
# Картинка считается той же функцией, которой считает переключатель
# (Get-LayoutPositions), поэтому проверять надо ровно одно: что в неё попадает.

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
    # Карточка-памятка от выдернутого монитора: размера у неё нет, но место в
    # ряду она занимает — иначе предпросмотр показывал бы не тот стол.
    $cards = @([pscustomobject]@{ Label = 'XG27AQDMGR'; Width = 0; Height = 0; Connected = $false; Primary = $false })
    $screens = @(ConvertTo-PreviewScreens -Cards $cards)
    Assert-Equal 1 $screens.Count 'still there'
    Assert-Equal 1920 $screens[0].Width 'a plain 16:9 stands in'
    Assert-Equal 1080 $screens[0].Height 'both ways'
}

Test-Case 'preview: what it draws is what the switcher will do' {
    # Экраны разной высоты выравниваются по центру, и именно это должно быть
    # видно на картинке: 2160 и 1440 дают отступ (2160-1440)/2 = 360.
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
    # Регрессия: с пустым Order у всех экранов одинаковый ранг, и раскладка
    # сортировалась по названию. Картинка показывала ULTRAFINE, ULTRAGEAR,
    # XG27AQDMGR, а карточки стояли ULTRAFINE, XG27AQDMGR, ULTRAGEAR — то есть
    # предпросмотр обещал не тот стол, который получится.
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
    # Основным Windows делает того, чей левый верхний угол лежит в (0,0) — и
    # картинка обязана показывать это так же, иначе она рисует чужую раскладку.
    $cards = @(
        [pscustomobject]@{ Label = 'LG ULTRAFINE'; Width = 3840; Height = 2160; Connected = $true; Primary = $false }
        [pscustomobject]@{ Label = 'LG ULTRAGEAR'; Width = 2560; Height = 1440; Connected = $true; Primary = $true }
    )
    $pos = Get-PreviewPlacement -Screens @(ConvertTo-PreviewScreens -Cards $cards)
    Assert-Equal 0 $pos['preview-1'].X 'the taskbar display sits at zero'
    Assert-Equal 0 $pos['preview-1'].Y 'both ways'
    Assert-Equal -3840 $pos['preview-0'].X 'and the other one is to the left of it'
}
