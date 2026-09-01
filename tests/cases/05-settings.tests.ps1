# --- the settings -----------------------------------------------------------

Write-Host ''
Write-Host 'settings' -ForegroundColor White

Test-Case 'settings: defaults have the shape the rest of the code expects' {
    $s = Get-DefaultSettings
    Assert-True $s.maximizeRefresh 'maximizeRefresh on'
    Assert-True $s.notifications 'notifications on'
    Assert-True $s.restoreWindows 'restoreWindows on by default'
    Assert-True $s.restoreLastMode 'restoreLastMode on by default'
    Assert-Equal 0 @($s.layout).Count 'layout empty'
    Assert-Equal '' $s.primary 'primary empty'
    Assert-Equal 0 @($s.combos.Keys).Count 'combos empty'
    Assert-Equal 0 @($s.rules).Count 'rules empty'
}

Test-Case 'settings: a damaged file falls back to defaults and keeps a copy' {
    Set-Content -Path $script:SettingsFile -Value '{ this is not json' -Encoding UTF8
    $s = Get-DisplaySettings
    Assert-True $s.maximizeRefresh 'fell back to defaults'
    Assert-True (Test-Path ($script:SettingsFile + '.bad')) 'kept settings.json.bad'
    Remove-Item ($script:SettingsFile + '.bad') -Force
    Remove-Item $script:SettingsFile -Force
}

Test-Case 'settings: a half-written reapply keeps the other defaults' {
    # The file gets edited by hand, and it easily ends up holding half the keys.
    Set-Content -Path $script:SettingsFile -Value '{ "reapply": { "onResume": false } }' -Encoding UTF8
    $s = Get-DisplaySettings
    Assert-True (-not $s.reapply.onResume) 'onResume read'
    Assert-True $s.reapply.onUnplug 'onUnplug stayed default, not null'
    Assert-Equal '' $s.reapply.onPlug 'onPlug stayed default, not null'
    Remove-Item $script:SettingsFile -Force
}

Test-Case 'settings: restoreLastMode survives a round-trip when turned off' {
    # A missing key means "the default", that is, on — whereas an honest false has to make it
    # through. restoreWindows has already broken on this pair.
    Set-Content -Path $script:SettingsFile -Value '{ "restoreLastMode": false }' -Encoding UTF8
    $s = Get-DisplaySettings
    Assert-True (-not $s.restoreLastMode) 'false read from the file'
    Remove-Item $script:SettingsFile -Force

    Assert-True (Get-DisplaySettings).restoreLastMode 'no file at all means the default, on'
}

Test-Case 'settings: round-trip through disk preserves everything' {
    $s = Get-DefaultSettings
    $s.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
    $s.layout = @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR')
    $s.primary = 'ULTRAGEAR'
    $s.restoreWindows = $false
    $s.audio['combo:Work'] = 'ULTRAFINE'
    Save-DisplaySettings $s

    $back = Get-DisplaySettings
    Assert-Equal 'Ctrl+Alt+F1' $back.hotkeys['solo:LG ULTRAGEAR'] 'hotkey'
    Assert-Equal @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR') @($back.layout) 'layout with order'
    Assert-Equal 'ULTRAGEAR' $back.primary 'primary'
    Assert-True (-not $back.restoreWindows) 'restoreWindows false survived'
    Assert-Equal 'ULTRAFINE' $back.audio['combo:Work'] 'audio mapping'
    Remove-Item $script:SettingsFile -Force
}

Test-Case 'settings: a file that cannot be written is a false answer, not an exception' {
    # The tray saves at the TOP LEVEL of its startup - before the message loop, with the console hidden.
    # A folder without write rights (a shared Tools\, a read-only share, an editor holding the file open)
    # used to take the whole application down there: no window, no line in the log, nothing to go on.
    # A directory in place of the file is the cheapest refusal there is.
    $was = $script:SettingsFile
    try {
        $script:SettingsFile = $script:TestDir
        Assert-True (-not (Save-DisplaySettings (Get-DefaultSettings))) 'answered no instead of throwing'
    }
    finally { $script:SettingsFile = $was }
}

Test-Case 'settings: a write that went through answers yes' {
    Assert-True (Save-DisplaySettings (Get-DefaultSettings)) 'answered yes'
    Assert-True (Test-Path $script:SettingsFile) 'and the file is there'
    Remove-Item $script:SettingsFile -Force
}
