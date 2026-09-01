# --- migrating the bindings -------------------------------------------------

Write-Host ''
Write-Host 'hotkey migration' -ForegroundColor White

Test-Case 'migration: a binding keyed by the old short id moves to the name key' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:GSM5BB3'] = 'Ctrl+Alt+F1'
    Assert-True (Update-HotkeyKeys $s $state) 'reported a change'
    Assert-True (-not $s.hotkeys.Contains('solo:GSM5BB3')) 'old key gone'
    Assert-Equal 'Ctrl+Alt+F1' $s.hotkeys['solo:LG ULTRAGEAR'] 'moved to the new key'
}

Test-Case 'migration: a longer old name still finds its display' {
    # A name in the settings may be the full one — "ROG STRIX XG27AQDMGR" — while the system knows
    # the monitor as "XG27AQDMGR". One is contained in the other.
    $state = @((New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:ROG STRIX XG27AQDMGR'] = 'Ctrl+Alt+F4'
    Assert-True (Update-HotkeyKeys $s $state) 'reported a change'
    Assert-Equal 'Ctrl+Alt+F4' $s.hotkeys['solo:XG27AQDMGR'] 'moved'
}

Test-Case 'migration: an occupied new key is not overwritten' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:GSM5BB3'] = 'Ctrl+Alt+F1'
    $s.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F9'
    [void](Update-HotkeyKeys $s $state)
    Assert-Equal 'Ctrl+Alt+F9' $s.hotkeys['solo:LG ULTRAGEAR'] 'existing binding kept'
    Assert-True $s.hotkeys.Contains('solo:GSM5BB3') 'old one left alone rather than silently dropped'
}

Test-Case 'migration: a binding for an absent display is left untouched' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:AUSAA1D'] = 'Ctrl+Alt+F4'
    Assert-True (-not (Update-HotkeyKeys $s $state)) 'nothing changed'
    Assert-Equal 'Ctrl+Alt+F4' $s.hotkeys['solo:AUSAA1D'] 'still there'
}

Test-Case 'migration: already-current keys are left alone' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
    Assert-True (-not (Update-HotkeyKeys $s $state)) 'no change reported'
}

Test-Case 'migration: empty settings do not blow up' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    Assert-True (-not (Update-HotkeyKeys $null $state)) 'null settings'
    Assert-True (-not (Update-HotkeyKeys (Get-DefaultSettings) $state)) 'no hotkeys'
}
