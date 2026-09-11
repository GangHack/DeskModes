# --- the settings -----------------------------------------------------------

Write-Host ''
Write-Host 'settings' -ForegroundColor White

Test-Case 'settings: defaults have the shape the rest of the code expects' {
    $s = Get-DefaultSettings
    Assert-True $s.maximizeRefresh 'maximizeRefresh on'
    Assert-True $s.notifications 'notifications on'
    Assert-True $s.restoreWindows 'restoreWindows on by default'
    Assert-True (-not $s.restoreLastMode) 'restoreLastMode off by default'
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

Test-Case 'settings: restoreLastMode preserves explicit values and defaults off when absent' {
    foreach ($value in $false, $true) {
        $s = Get-DefaultSettings
        $s.restoreLastMode = $value
        Assert-True (Save-DisplaySettings -Settings $s) "saved explicit $value"
        Assert-Equal $value ([bool](Get-DisplaySettings).restoreLastMode) "explicit $value survived a round-trip"
        Remove-Item $script:SettingsFile -Force
        if (Test-Path ($script:SettingsFile + '.bak')) { Remove-Item ($script:SettingsFile + '.bak') -Force }
    }

    Set-Content -Path $script:SettingsFile -Value '{ "notifications": true }' -Encoding UTF8
    Assert-True (-not (Get-DisplaySettings).restoreLastMode) 'a file missing the key uses the off default'
    Remove-Item $script:SettingsFile -Force
    Assert-True (-not (Get-DisplaySettings).restoreLastMode) 'no file at all uses the off default'
}

Test-Case 'settings: round-trip through disk preserves everything' {
    $s = Get-DefaultSettings
    $s.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
    $s.layout = @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR')
    $s.primary = 'ULTRAGEAR'
    $s.restoreWindows = $false
    $s.audio['combo:Work'] = 'ULTRAFINE'
    # [void]: the answer is a boolean, and a bare call prints it into the test output as a stray True.
    [void](Save-DisplaySettings $s)

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
