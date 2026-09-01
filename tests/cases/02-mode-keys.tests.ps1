# --- mode keys --------------------------------------------------------------

Write-Host ''
Write-Host 'mode keys' -ForegroundColor White

Test-Case 'modes: a fresh desk gets one mode per display plus all, and nothing else' {
    # What a person sees the first time they plug in three monitors: three separate modes and
    # "all". Nothing is guessed at: sets appear only after they have created them themselves.
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D')
    )
    $modes = @(Get-DisplayModes $state (Get-DefaultSettings))
    $keys = @($modes | ForEach-Object { $_.Key })
    Assert-Equal 4 $modes.Count 'three displays plus all - nothing invented'
    Assert-True ($keys -contains 'solo:LG ULTRAGEAR') 'solo ultragear'
    Assert-True ($keys -contains 'solo:LG ULTRAFINE') 'solo ultrafine'
    Assert-True ($keys -contains 'solo:XG27AQDMGR') 'solo asus'
    Assert-True ($keys -contains 'all') 'all'
    Assert-Equal 0 @($modes | Where-Object { $_.Kind -eq 'combo' }).Count 'no combinations out of thin air'
}

Test-Case 'modes: two identical models get the short id appended' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBB' 'path-a')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-b')
    )
    $keys = @(Get-DisplayModes $state | Where-Object { $_.Kind -eq 'solo' } | ForEach-Object { $_.Key })
    Assert-Equal 2 $keys.Count 'two solo modes'
    Assert-True ($keys -contains 'solo:LG ULTRAFINE GSM5CBB') 'first keyed by short id'
    Assert-True ($keys -contains 'solo:LG ULTRAFINE GSM5CBC') 'second keyed by short id'
}

Test-Case 'modes: full twins get numbered, and the keys stay distinct' {
    # An identical model on an identical input: the short ID is the model, not the instance.
    # Without numbering, both solo modes would get ONE key, and "switch on only this one" would
    # light both monitors.
    $state = @(
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBB' 'path-a')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBB' 'path-b')
    )
    $solo = @(Get-DisplayModes $state | Where-Object { $_.Kind -eq 'solo' })
    Assert-Equal 2 $solo.Count 'two solo modes'
    $keys = @($solo | ForEach-Object { $_.Key })
    Assert-Equal 2 (@($keys | Sort-Object -Unique)).Count 'keys are distinct'
    Assert-True ($keys[0] -like '*#1') 'first numbered'
    Assert-True ($keys[1] -like '*#2') 'second numbered'
    # And each key leads to its own monitor rather than to both.
    Assert-Equal 'path-a' $solo[0].Id 'first points at its own display'
    Assert-Equal 'path-b' $solo[1].Id 'second points at its own display'
}

Test-Case 'modes: a disconnected display still gets a mode, marked unavailable' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' '' $true $false)
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' '' $false $true)
    )
    $modes = @(Get-DisplayModes $state)
    $asus = $modes | Where-Object { $_.Key -eq 'solo:XG27AQDMGR' } | Select-Object -First 1
    Assert-True ($null -ne $asus) 'mode exists'
    Assert-True (-not $asus.Available) 'marked not available'
}

Test-Case 'ModeTitleFromKey: every shape' {
    Assert-Equal 'Only LG ULTRAGEAR' (Get-ModeTitleFromKey 'solo:LG ULTRAGEAR') 'solo'
    Assert-Equal 'Only AUSAA1D' (Get-ModeTitleFromKey 'solo:AUSAA1D') 'solo by short id'
    # A combo's name is set by a person, so the title is taken from the key as it is.
    Assert-Equal 'Movie night' (Get-ModeTitleFromKey 'combo:Movie night') 'combo'
    Assert-Equal 'All displays' (Get-ModeTitleFromKey 'all') 'all'
    Assert-Equal 'something else' (Get-ModeTitleFromKey 'something else') 'unknown falls through'
}
