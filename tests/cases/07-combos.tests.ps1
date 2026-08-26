# --- комбинации -------------------------------------------------------------
# Комбинация — единственный способ сказать «вот эти два и вон тот»: набор
# мониторов под своим именем, с необязательной своей панелью задач. Один монитор
# может входить в любое их число.

Write-Host ''
Write-Host 'combinations' -ForegroundColor White

Test-Case 'combos: settings survive a round-trip, in all three spellings' {
    # Полную форму пишет окно настроек; массив и голую строку — человек рукой.
    $json = '{ "combos": { ' +
            '"Movie night": { "displays": ["ULTRAFINE", "XG27AQDMGR"], "primary": "ULTRAFINE" }, ' +
            '"Side pair": ["ULTRAGEAR", "ULTRAFINE"], ' +
            '"Lone": "XG27AQDMGR" } }'
    Set-Content -Path $script:SettingsFile -Value $json -Encoding UTF8

    $s = Get-DisplaySettings
    Assert-Equal @('Movie night', 'Side pair', 'Lone') @($s.combos.Keys) 'file order kept'
    Assert-Equal @('ULTRAFINE', 'XG27AQDMGR') @($s.combos['Movie night'].displays) 'full form displays'
    Assert-Equal 'ULTRAFINE' $s.combos['Movie night'].primary 'full form primary'
    Assert-Equal @('ULTRAGEAR', 'ULTRAFINE') @($s.combos['Side pair'].displays) 'array shorthand normalised'
    Assert-Equal '' $s.combos['Side pair'].primary 'shorthand means no primary of its own'
    Assert-Equal @('XG27AQDMGR') @($s.combos['Lone'].displays) 'string shorthand normalised'

    Save-DisplaySettings $s
    $back = Get-DisplaySettings
    Assert-Equal @('ULTRAFINE', 'XG27AQDMGR') @($back.combos['Movie night'].displays) 'displays after a save'
    Assert-Equal 'ULTRAFINE' $back.combos['Movie night'].primary 'primary after a save'
    Remove-Item $script:SettingsFile -Force
}

Test-Case 'combos: a combination becomes a mode named exactly as typed' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D')
    )
    $s = Get-DefaultSettings
    $s.combos['Movie night'] = [ordered]@{ displays = @('ULTRAFINE', 'XG27AQDMGR'); primary = 'XG27AQDMGR' }
    $s.combos['Big pair']    = [ordered]@{ displays = @('ULTRAGEAR', 'ULTRAFINE'); primary = '' }

    $modes = @(Get-DisplayModes $state $s)
    $keys = @($modes | ForEach-Object { $_.Key })
    $movie = $modes | Where-Object { $_.Key -eq 'combo:Movie night' } | Select-Object -First 1
    Assert-True ($null -ne $movie) 'the combo mode exists'
    Assert-Equal 'Movie night' $movie.Title 'title is the name as typed'
    Assert-Equal 'combo' $movie.Kind 'kind'
    Assert-Equal 'XG27AQDMGR' $movie.Primary 'carries its own taskbar display'
    Assert-True $movie.Available 'available - its displays are on the desk'

    # Порядок: после режимов отдельных мониторов, перед «все», между собой — как в
    # файле: их порядок выбрал человек, и переставлять его не наше дело.
    $ix = @{}
    for ($i = 0; $i -lt $keys.Count; $i++) { $ix[$keys[$i]] = $i }
    Assert-True ($ix['solo:XG27AQDMGR'] -lt $ix['combo:Movie night']) 'after the single displays'
    Assert-True ($ix['combo:Movie night'] -lt $ix['combo:Big pair']) 'file order kept'
    Assert-True ($ix['combo:Big pair'] -lt $ix['all']) 'before all'
}

Test-Case 'combos: members are the displays its patterns match, connected only' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' '' $false $true)
    )
    $s = Get-DefaultSettings
    $s.combos['Mix'] = [ordered]@{ displays = @('ULTRAFINE', 'XG27AQDMGR'); primary = '' }
    $mix = @(Get-DisplayModes $state $s) | Where-Object { $_.Key -eq 'combo:Mix' } | Select-Object -First 1
    $members = @(Get-ModeMembers $mix $state | ForEach-Object { $_.Label })
    Assert-Equal @('LG ULTRAFINE') $members 'the unplugged display is not a member'
    Assert-True $mix.Available 'still available - one display is enough'
}

Test-Case 'combos: nothing connected means unavailable, not a guess' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    $s = Get-DefaultSettings
    $s.combos['Elsewhere'] = [ordered]@{ displays = @('DELL'); primary = '' }
    $mode = @(Get-DisplayModes $state $s) | Where-Object { $_.Key -eq 'combo:Elsewhere' } | Select-Object -First 1
    Assert-True ($null -ne $mode) 'the mode is still listed - the user made it'
    Assert-True (-not $mode.Available) 'marked unavailable'
}

Test-Case 'combos: no settings passed means no combo modes, not a crash' {
    # Get-DisplayModes сам на диск не ходит никогда: меню зовёт её на каждое
    # открытие. Без настроек комбинаций в списке просто нет.
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    $kinds = @(Get-DisplayModes $state | ForEach-Object { $_.Kind })
    Assert-True (-not ($kinds -contains 'combo')) 'no combos out of thin air'
}

Test-Case 'combos: the current desk is recognised as an active combination' {
    $state = @(
        (New-FakeMonitor 'A' 'AAA1111' 'path-a' $true)
        (New-FakeMonitor 'B' 'BBB2222' 'path-b' $false)
        (New-FakeMonitor 'C' 'CCC3333' 'path-c' $true)
    )
    $s = Get-DefaultSettings
    $s.combos['Edges'] = [ordered]@{ displays = @('A', 'C'); primary = '' }
    $modes = @(Get-DisplayModes $state $s)
    Assert-Equal 'combo:Edges' (Get-ActiveModeKey $state $modes) 'A and C on, B off - that is Edges'
}

Test-Case 'ModeTitleFromKey: a combo key gives the name back as typed' {
    Assert-Equal 'Movie night' (Get-ModeTitleFromKey 'combo:Movie night') 'combo'
}
