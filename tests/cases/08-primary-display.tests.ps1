# --- выбор основного монитора -----------------------------------------------
# Лестница из шести ступеней в Select-PrimaryDisplay. Внутри Switch-DisplayMode
# она была непроверяемой; с собственным primary у комбинаций это стало
# недопустимо — семантика «жёсткий/мягкий» держится только на этих тестах.

Write-Host ''
Write-Host 'choosing the primary display' -ForegroundColor White

$script:PrimState = @(
    (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf')
    (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' 'path-xg')
    (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
)

Test-Case 'primary: -PrimaryMatch wins, and a typo in it is an error, not a guess' {
    $hit = Select-PrimaryDisplay -Wanted $script:PrimState -PrimaryMatch 'ULTRAFINE' `
                                 -ModePrimary 'ULTRAGEAR' -SettingsPrimary 'XG' -Layout @()
    Assert-Equal 'LG ULTRAFINE' $hit.Label 'the explicit choice beats everything'

    $threw = $false
    try { [void](Select-PrimaryDisplay -Wanted $script:PrimState -PrimaryMatch 'NOSUCH' -ModeTitle 'Movie') }
    catch { $threw = $true; Assert-True ($_.Exception.Message -like "*NOSUCH*") 'named the typo' }
    Assert-True $threw 'threw instead of silently picking another display'
}

Test-Case 'primary: the combination speaks next, softly' {
    $hit = Select-PrimaryDisplay -Wanted $script:PrimState -ModePrimary 'XG27' `
                                 -SettingsPrimary 'ULTRAGEAR' -Layout @()
    Assert-Equal 'XG27AQDMGR' $hit.Label 'combo primary beats the settings preference'

    # Монитора из primary комбинации нет среди включаемых — молча идём дальше:
    # комбинация обязана работать и без него, это не опечатка человека.
    $without = @($script:PrimState | Where-Object { $_.Label -ne 'XG27AQDMGR' })
    $hit = Select-PrimaryDisplay -Wanted $without -ModePrimary 'XG27' `
                                 -SettingsPrimary 'ULTRAGEAR' -Layout @()
    Assert-Equal 'LG ULTRAGEAR' $hit.Label 'fell through to the settings preference'
}

Test-Case 'primary: current one, then rightmost by layout, then the first' {
    $wanted = @(
        (New-FakeMonitor 'A' 'AAA1111' 'pa')
        (New-FakeMonitor 'B' 'BBB2222' 'pb')
    )
    $wanted[1].Primary = $true
    Assert-Equal 'B' (Select-PrimaryDisplay -Wanted $wanted -Layout @()).Label 'who is primary now stays primary'

    $wanted[1].Primary = $false
    Assert-Equal 'B' (Select-PrimaryDisplay -Wanted $wanted -Layout @('A', 'B')).Label 'rightmost by layout'
    Assert-Equal 'A' (Select-PrimaryDisplay -Wanted $wanted -Layout @()).Label 'first as the last resort'
}
