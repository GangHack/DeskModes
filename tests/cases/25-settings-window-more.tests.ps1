# --- the Settings window: what is new ---------------------------------------

Write-Host ''
Write-Host 'the settings window, the new parts' -ForegroundColor White

Test-Case 'dialog: the diary toggle goes both ways' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal $false ([bool]$ui.StatsBox.IsChecked) 'off, as it is in the settings'
        $ui.StatsBox.IsChecked = $true
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-True $got.Settings.stats 'turning it on is saved'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: commands and levels survive a save like everything else' {
    $settings = Get-DefaultSettings
    $settings.hooks['all'] = [ordered]@{ before = ''; after = 'notepad.exe' }
    $settings.brightness['all'] = 80
    $settings.contrast['all'] = 70
    $settings.rules = @([ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'all'; back = ''; enabled = $true })
    $settings.reapply.onPlug = 'all'
    $ui = New-DialogUi -Settings $settings
    try {
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'notepad.exe' $updated.hooks['all'].after 'the command'
        Assert-Equal 80 $updated.brightness['all'] 'the brightness'
        Assert-Equal 70 $updated.contrast['all'] 'the contrast'
        Assert-Equal 'cs2' $updated.rules[0].process 'the rule'
        Assert-Equal 'all' $updated.reapply.onPlug 'and what to do when a display appears'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: renaming a combination carries its command and brightness' {
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.hooks['combo:Work'] = [ordered]@{ before = ''; after = 'x.cmd' }
    $settings.brightness['combo:Work'] = 55
    $ui = New-DialogUi -Settings $settings
    try {
        # Through the mode editor, as in the live window: the command moves on Save by the rename map,
        # while the brightness moves at once, along with the edit.
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Office'; Patterns = @('LG ULTRAGEAR'); Primary = ''
            Level = $ui.Levels['combo:Work'] })
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-True ($updated.hooks.Contains('combo:Office')) 'the command followed the new name'
        Assert-Equal $false ($updated.hooks.Contains('combo:Work')) 'and left no ghost behind'
        Assert-Equal 55 $updated.brightness['combo:Office'] 'so did the brightness'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: removing a combination takes its command and brightness along' {
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.hooks['combo:Work'] = [ordered]@{ before = ''; after = 'x.cmd' }
    $settings.brightness['combo:Work'] = 55
    $ui = New-DialogUi -Settings $settings
    try {
        Remove-UiCombo -Ui $ui -Combo $ui.Combos[0]
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ($updated.hooks.Contains('combo:Work')) 'no command left for a mode that is gone'
        Assert-Equal $false ($updated.brightness.Contains('combo:Work')) 'and no brightness either'
    }
    finally { $ui.Window.Close() }
}

# The key moving itself goes through pure functions, separately from the window: there are three of
# them for four settings, and testing them by building a WPF tree is both dearer and murkier.

Test-Case 'mode keys: a rename moves the entry and keeps the file order' {
    $renames = Get-ComboRenames -Combos @(
        [pscustomobject]@{ Name = 'Office'; OriginalName = 'Work' }
        [pscustomobject]@{ Name = 'Movie night'; OriginalName = 'Movie night' }
    )
    Assert-Equal @('combo:Work') @($renames.Keys) 'only the renamed one is in the map'

    $source = [ordered]@{ 'solo:A' = 10; 'combo:Work' = 80; 'all' = 55 }
    $moved = Move-ModeKeyedEntries -Source $source -Renames $renames
    Assert-Equal @('solo:A', 'combo:Office', 'all') @($moved.Keys) 'moved in place, order untouched'
    Assert-Equal 80 $moved['combo:Office'] 'with its value'
}

Test-Case 'mode keys: a removed combination takes its entry with it' {
    $source = [ordered]@{ 'combo:Work' = 80; 'all' = 55 }
    $moved = Move-ModeKeyedEntries -Source $source -Renames @{} -Gone @('combo:Work')
    Assert-Equal @('all') @($moved.Keys) 'the ghost setting is gone'
}

Test-Case 'mode keys: an occupied new key keeps its own value' {
    # A value of its own on a taken key matters more than the one moving: silently throwing one of the
    # two away is worse than keeping what is already there.
    $renames = Get-ComboRenames -Combos @([pscustomobject]@{ Name = 'B'; OriginalName = 'A' })
    $moved = Move-ModeKeyedEntries -Source ([ordered]@{ 'combo:A' = 1; 'combo:B' = 2 }) -Renames $renames
    Assert-Equal 2 $moved['combo:B'] 'the value that was already there'
    Assert-True (-not $moved.Contains('combo:A')) 'and the old key is gone either way'
}

Test-Case 'mode keys: a chain of renames is applied in the order of the list' {
    # "A" was renamed to "B", and "B" to "C". The order of application matters here, which is why the
    # rename dictionary is ordered rather than a hash table.
    $renames = Get-ComboRenames -Combos @(
        [pscustomobject]@{ Name = 'C'; OriginalName = 'B' }
        [pscustomobject]@{ Name = 'B'; OriginalName = 'A' }
    )
    $moved = Move-ModeKeyedEntries -Source ([ordered]@{ 'combo:A' = 1; 'combo:B' = 2 }) -Renames $renames
    Assert-Equal 2 $moved['combo:C'] 'B moved on to C first'
    Assert-Equal 1 $moved['combo:B'] 'and only then A took the freed name'
}

Test-Case 'mode keys: a rule whose mode is gone is dropped, a way back is only cleared' {
    $rules = @(
        [ordered]@{ when = 'process'; process = 'cs2'; mode = 'combo:Work'; back = ''; enabled = $true }
        [ordered]@{ when = 'idle'; minutes = 20; mode = 'all'; back = 'combo:Work'; enabled = $true }
    )
    $left = @(Move-RuleModeKeys -Rules $rules -Renames @{} -Gone @('combo:Work'))
    Assert-Equal 1 $left.Count 'the rule with nowhere to go is dropped'
    Assert-Equal 'all' ([string]$left[0].mode) 'the other one stays'
    Assert-Equal '' ([string]$left[0].back) 'with an empty way back - that is legal'
}

Test-Case 'mode keys: rules survive as objects, not just dictionaries' {
    # Out of ConvertFrom-Json the rules arrive as PSCustomObjects.
    $rules = @([pscustomobject]@{ when = 'process'; process = 'cs2'; mode = 'combo:Work'; back = 'all' })
    $renames = Get-ComboRenames -Combos @([pscustomobject]@{ Name = 'Office'; OriginalName = 'Work' })
    $left = @(Move-RuleModeKeys -Rules $rules -Renames $renames)
    Assert-Equal 1 $left.Count 'kept'
    Assert-Equal 'combo:Office' ([string]$left[0].mode) 'and renamed'
    Assert-Equal 'cs2' ([string]$left[0].process) 'the rest of the rule came along'
}

# The rules and "a monitor came up" hold the same mode keys, and a rename in the window has to reach
# them too. Otherwise a rule would head every fifteen seconds for a mode that no longer exists, and a
# switch would answer "combination no longer exists" — the same place Update-HotkeyKeys makes this
# same move for.

Test-Case 'dialog: renaming a combination carries its rules along' {
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.rules = @(
        [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'combo:Work'; back = ''; enabled = $true }
        [ordered]@{ when = 'idle'; process = ''; minutes = 20; mode = 'all'; back = 'combo:Work'; enabled = $true }
    )
    $settings.reapply.onPlug = 'combo:Work'
    $ui = New-DialogUi -Settings $settings
    try {
        # Renamed the way the window renames — through the editor's answer. "A display was
        # plugged in" is carried by that path now rather than by a rename map at Save time, so a
        # test that reached into the combo list directly would be testing a door nobody uses.
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Office'; Patterns = @('LG ULTRAGEAR'); Primary = '' })
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 2 @($updated.rules).Count 'both rules are still there'
        Assert-Equal 'combo:Office' ([string]$updated.rules[0].mode) 'the rule follows the new name'
        Assert-Equal 'combo:Office' ([string]$updated.rules[1].back) 'and so does the way back'
        Assert-Equal 'combo:Office' ([string]$updated.reapply.onPlug) 'and "when a display appears"'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: removing a combination takes its rules along' {
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.rules = @(
        [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'combo:Work'; back = ''; enabled = $true }
        [ordered]@{ when = 'idle'; process = ''; minutes = 20; mode = 'all'; back = 'combo:Work'; enabled = $true }
    )
    $settings.reapply.onPlug = 'combo:Work'
    $ui = New-DialogUi -Settings $settings
    try {
        Remove-UiCombo -Ui $ui -Combo $ui.Combos[0]
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        # The first rule has nowhere to go — it is no longer a rule. The second lost only its return,
        # and an empty return is legitimate: "to wherever the desk was before".
        Assert-Equal 1 @($updated.rules).Count 'the rule with nowhere to go is gone'
        Assert-Equal 'all' ([string]$updated.rules[0].mode) 'the other one stayed'
        Assert-Equal '' ([string]$updated.rules[0].back) 'without its way back'
        Assert-Equal '' ([string]$updated.reapply.onPlug) 'and nothing to do when a display appears'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a save leaves the rules the tray is living with alone' {
    # $updated is a copy: a failed write to disk must not leave three different versions of the
    # settings (in memory, on disk, and in the registered shortcuts).
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.rules = @([ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'combo:Work'; back = ''; enabled = $true })
    $ui = New-DialogUi -Settings $settings
    try {
        $ui.Combos[0].Name = 'Office'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'combo:Office' ([string]$updated.rules[0].mode) 'the copy moved'
        Assert-Equal 'combo:Work' ([string]$settings.rules[0].mode) 'the original did not'
    }
    finally { $ui.Window.Close() }
}
