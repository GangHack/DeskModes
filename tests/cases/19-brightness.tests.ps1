# --- яркость ----------------------------------------------------------------

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
    # Опечатка в настройках не должна уводить монитор в чёрный.
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
