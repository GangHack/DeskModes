# --- brightness -------------------------------------------------------------

Write-Host ''
Write-Host 'brightness and contrast as part of a mode' -ForegroundColor White

$script:LevelWanted = @(
    (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
    (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D')
)

Test-Case 'levels: one number goes to every display of the mode' {
    $plan = Get-LevelPlan -Setting 80 -Wanted $script:LevelWanted
    Assert-Equal 2 $plan.Count 'both displays'
    Assert-Equal 80 $plan['LG ULTRAFINE'] 'the 4K panel'
    Assert-Equal 80 $plan['XG27AQDMGR'] 'and the ASUS'
}

Test-Case 'levels: a dictionary matches displays by part of the name' {
    $plan = Get-LevelPlan -Setting ([ordered]@{ 'ULTRAFINE' = 25 }) -Wanted $script:LevelWanted
    Assert-Equal 1 $plan.Count 'only the one named'
    Assert-Equal 25 $plan['LG ULTRAFINE'] 'found by a piece of its name'
}

Test-Case 'levels: a display named by its short id is found too' {
    $plan = Get-LevelPlan -Setting ([ordered]@{ 'AUSAA1D' = 40 }) -Wanted $script:LevelWanted
    Assert-Equal 40 $plan['XG27AQDMGR'] 'the short monitor id works as a name'
}

Test-Case 'levels: numbers outside 0..100 are clamped, not obeyed' {
    # A typo in the settings must not take a monitor to black.
    $plan = Get-LevelPlan -Setting 500 -Wanted $script:LevelWanted
    Assert-Equal 100 $plan['XG27AQDMGR'] 'above the range'
    $plan = Get-LevelPlan -Setting -20 -Wanted $script:LevelWanted
    Assert-Equal 0 $plan['XG27AQDMGR'] 'below the range'
}

Test-Case 'levels: zero is a legal brightness and is kept' {
    $plan = Get-LevelPlan -Setting 0 -Wanted $script:LevelWanted
    Assert-Equal 2 $plan.Count 'zero is a value, not a missing one'
    Assert-Equal 0 $plan['LG ULTRAFINE'] 'and it is zero'
}

Test-Case 'levels: junk in the settings is ignored, not guessed at' {
    $plan = Get-LevelPlan -Setting 'bright' -Wanted $script:LevelWanted
    Assert-Equal 0 $plan.Count 'nothing to do'
    $plan = Get-LevelPlan -Setting $null -Wanted $script:LevelWanted
    Assert-Equal 0 $plan.Count 'nothing set at all'
}

# --- the monitor's picture preset --------------------------------------------
# Reader, FPS, sRGB - what the monitor's own menu calls them. DeskModes never learns the NAMES:
# probed on this desk on 2026-09-03, the LG UltraGear calls both 6 and 45 "Gamer 1" and they look
# different. What is remembered is the number the monitor is holding, and the register it answered
# on - monitors disagree about that too (0xDC by the standard, 0x15 on both LGs here).

Test-Case 'picture: a register and a number are read in either notation' {
    $one = ConvertFrom-PictureSetting '0x15:45'
    Assert-Equal 21 $one.Code 'the register, in hex as the documentation writes it'
    Assert-Equal 45 $one.Value 'and the number'

    $same = ConvertFrom-PictureSetting '21:45'
    Assert-Equal 21 $same.Code 'plain decimal is the same register'
    Assert-Equal 45 $same.Value 'and the same number'

    $spaced = ConvertFrom-PictureSetting ' 0xDC : 6 '
    Assert-Equal 220 $spaced.Code 'spaces do not matter'
    Assert-Equal 6 $spaced.Value 'on either side'
}

Test-Case 'picture: what is not a register and a number is refused, not guessed at' {
    # settings.json is edited by hand, and a typo there must cost a line in the log rather than a
    # number written to a monitor.
    Assert-Null (ConvertFrom-PictureSetting '') 'nothing'
    Assert-Null (ConvertFrom-PictureSetting '45') 'a number with no register'
    Assert-Null (ConvertFrom-PictureSetting 'reader') 'a name is not a setting'
    Assert-Null (ConvertFrom-PictureSetting '0x15:45:6') 'three parts are not two'
    Assert-Null (ConvertFrom-PictureSetting '0x15:x') 'and neither half may be rubbish'
    Assert-Null (ConvertFrom-PictureSetting '0x1FF:4') 'a register outside a byte'
    Assert-Null (ConvertFrom-PictureSetting '0x15:300') 'and a value outside one'
}

Test-Case 'picture: the plan says who gets which register and number' {
    $plan = Get-PicturePlan -Setting ([ordered]@{ 'ULTRAFINE' = '0x15:45'; 'AUSAA1D' = '0xDC:6' }) `
                            -Wanted $script:LevelWanted
    Assert-Equal 2 $plan.Count 'both displays'
    Assert-Equal 21 $plan['LG ULTRAFINE'].Code 'the LG answers on its own register'
    Assert-Equal 45 $plan['LG ULTRAFINE'].Value 'with the number that was remembered'
    # The ASUS is named by its short id here, the way a display can be named anywhere else.
    Assert-Equal 220 $plan['XG27AQDMGR'].Code 'and the ASUS on the standard one'
    Assert-Equal 6 $plan['XG27AQDMGR'].Value 'with its own number'
}

Test-Case 'picture: a number alone is not a setting for everybody' {
    # Brightness 80 means the same thing on every monitor there is; preset 6 does not - it is
    # "Gamer 1" on one and "Color Weakness" on another. So there is no "one number for the set".
    Assert-Equal 0 (Get-PicturePlan -Setting 45 -Wanted $script:LevelWanted).Count 'a bare number sets nothing'
    Assert-Equal 0 (Get-PicturePlan -Setting $null -Wanted $script:LevelWanted).Count 'and nothing sets nothing'
    Assert-Equal 0 (Get-PicturePlan -Setting ([ordered]@{ 'ULTRAFINE' = 'nonsense' }) -Wanted $script:LevelWanted).Count `
                'rubbish is skipped rather than written to a monitor'
}

Test-Case 'picture: a setting is written the way a person can edit it' {
    Assert-Equal '0x15:45' (Format-PictureSetting -Code 21 -Value 45) 'hex register, plain number'
    Assert-Equal '0xDC:6' (Format-PictureSetting -Code 220 -Value 6) 'and two digits of register always'
}
