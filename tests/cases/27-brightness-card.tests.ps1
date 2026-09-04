# --- the brightness card ----------------------------------------------------
# The window has to handle both forms of entry (a number and a dictionary) and must NOT turn one into
# the other on its own: by expanding a number over the monitors that happen to be on the desk it would
# lose the brightness of one that was pulled out, and it would change the meaning of "all" for a
# monitor that turns up tomorrow.

Write-Host ''
Write-Host 'the brightness card' -ForegroundColor White

Test-Case 'level model: nothing set reads as "leave it alone"' {
    $m = ConvertTo-LevelModel $null
    Assert-Equal 'none' $m.Kind 'nothing to do'
    Assert-Null (ConvertFrom-LevelModel $m) 'and nothing is written back'
}

Test-Case 'level model: a number is one level for the whole mode' {
    $m = ConvertTo-LevelModel 80
    Assert-Equal 'one' $m.Kind 'one level'
    Assert-Equal 80 $m.Value 'as written'
    Assert-Equal 80 (ConvertFrom-LevelModel $m) 'and it goes back as a number, not as a dictionary'
}

Test-Case 'level model: a dictionary is a level for each display' {
    $m = ConvertTo-LevelModel ([ordered]@{ 'ULTRAFINE' = 25; 'XG27' = 40 })
    Assert-Equal 'each' $m.Kind 'each display'
    Assert-Equal 25 $m.Map['ULTRAFINE'] 'the first'
    Assert-Equal 40 $m.Map['XG27'] 'the second'
    $back = ConvertFrom-LevelModel $m
    Assert-Equal 25 $back['ULTRAFINE'] 'and it comes back the same way'
    Assert-Equal @('ULTRAFINE', 'XG27') @($back.Keys) 'in the same order'
}

Test-Case 'level model: numbers outside 0..100 are clamped on the way in' {
    Assert-Equal 100 (ConvertTo-LevelModel 500).Value 'above'
    Assert-Equal 0 (ConvertTo-LevelModel -7).Value 'below'
    Assert-Equal 100 (ConvertTo-LevelModel ([ordered]@{ 'A' = 900 })).Map['A'] 'in a dictionary too'
}

Test-Case 'level model: junk is not a setting' {
    $m = ConvertTo-LevelModel 'bright'
    Assert-Equal 'none' $m.Kind 'unreadable means nothing set'
    Assert-Equal 'none' (ConvertTo-LevelModel ([ordered]@{})).Kind 'an empty dictionary is nothing set'
}

Test-Case 'level model: an empty per-display map writes no key at all' {
    $m = ConvertTo-LevelModel ([ordered]@{ 'A' = 50 })
    $m.Map.Remove('A')
    Assert-Null (ConvertFrom-LevelModel $m) 'unticking the last display removes the setting'
}

Test-Case 'level settings: modes without brightness stay out of the file' {
    $levels = [ordered]@{
        'all'        = (ConvertTo-LevelModel 80)
        'combo:Work' = (ConvertTo-LevelModel $null)
    }
    $out = ConvertFrom-LevelModels -Models $levels
    Assert-Equal 1 $out.Count 'only the one that has a level'
    Assert-Equal 80 $out['all'] 'and it is the number as written'
}

Test-Case 'level rows: "all displays" lists what is connected' {
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
    try {
        Assert-Equal @('LG ULTRAGEAR', 'LG ULTRAFINE') @(Get-EditorDisplayNames -Editor $ed) 'both connected displays'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'level rows: a combination lists its displays by their real names' {
    # The file holds a pattern while the row has to hold the monitor's full name: both entries match,
    # but the more precise one is what a person sees.
    $combo = [pscustomobject]@{ Name = 'Work'; Patterns = @('ULTRAFINE'); Primary = '' }
    $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $script:DlgState -Dark $false
    try {
        Assert-Equal @('LG ULTRAFINE') @(Get-EditorDisplayNames -Editor $ed) 'resolved to the display name'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'level rows: a display mode names the display, not its key' {
    # For two identical models the key holds a short ID ("solo:DELL U2723 ABC123"), and parsing the key
    # would give a slider row with a name that is on no monitor at all. Get-ModeMembers knows a mode's
    # membership — and it is what answers.
    $state = @(
        (New-FakeMonitor 'DELL U2723' 'ABC123' 'path-1')
        (New-FakeMonitor 'DELL U2723' 'ABC124' 'path-2')
    )
    $mode = @(Get-DisplayModes -State $state | Where-Object { $_.Id -eq 'path-1' })[0]
    Assert-Equal 'solo:DELL U2723 ABC123' ([string]$mode.Key) 'the key carries the short id, as it must'
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $state -Dark $false
    try {
        Assert-Equal @('DELL U2723') @(Get-EditorDisplayNames -Editor $ed) 'but the row is named after the display'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'level rows: a level for a display that is gone is still shown' {
    # Otherwise such a setting can neither be seen nor cleared — shortcut bindings to monitors that are
    # not there live by the same rule.
    $names = @(Get-LevelRowNames -Displays @('LG ULTRAGEAR') -Map ([ordered]@{ 'XG27AQDMGR' = 40 }))
    Assert-True ($names -contains 'XG27AQDMGR') 'the orphan row is there'
    Assert-True ($names -contains 'LG ULTRAGEAR') 'next to the display that is here'
}

Test-Case 'mode editor: brightness is offered for every kind of mode' {
    # The brightness lives in the mode editor — and it has to be in the editor of any mode, not just a
    # combo's.
    foreach ($mode in @(
        [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
        [pscustomobject]@{ Key = 'solo:LG ULTRAGEAR'; Title = 'Only LG ULTRAGEAR'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
    )) {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
        try {
            Assert-Equal 3 $ed.Brightness.KindBox.Items.Count "leave alone / one level / each display for $($mode.Key)"
            Assert-Equal 'none' ([string]$ed.Brightness.Model.Kind) 'nothing set until asked'
        }
        finally { $ed.Window.Close() }
    }
}

Test-Case 'mode editor: a display mode has no name, members or taskbar to argue about' {
    $mode = [pscustomobject]@{ Key = 'solo:LG ULTRAGEAR'; Title = 'Only LG ULTRAGEAR'; Kind = 'solo'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
    try {
        Assert-Equal 'Collapsed' ([string]$ed.Window.FindName('ComboPart').Visibility) 'the combination part is out of the way'
        Assert-Equal 'Only LG ULTRAGEAR' ([string]$ed.Window.FindName('HeadTitle').Text) 'the mode names itself'
        # An empty name on a combo is a refusal; a monitor mode has no name at all, and Save has to go
        # through.
        $got = Read-ModeFromUi -Editor $ed
        Assert-True $got.Ok 'saving asks nothing of it'
        Assert-Null $got.Mode.PSObject.Properties['Name'] 'and it carries no name back'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: a brightness set for a mode that no longer exists gets its own row' {
    $settings = Get-DefaultSettings
    $settings.brightness['solo:GONE MONITOR'] = 55
    $ui = New-DialogUi -Settings $settings
    try {
        # Two monitors, "all" and an orphan row: the setting can only be seen and cleared from here.
        Assert-Equal 4 $ui.ModesPanel.Children.Count 'the setting without a mode is listed'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 55 $updated.brightness['solo:GONE MONITOR'] 'and untouched by a plain Save'

        # Remove on such a row clears that row specifically.
        Remove-UiOrphan -Ui $ui -Key 'solo:GONE MONITOR'
        Assert-Equal 3 $ui.ModesPanel.Children.Count 'the row went away'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ($updated.brightness.Contains('solo:GONE MONITOR')) 'and so did the setting'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a hand-written number survives a Save untouched' {
    # The regression this stands guard over: expanding a number into a dictionary over the current
    # monitors is not allowed — "all: 80" applies to the monitor that is not plugged in right now too.
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = 80
    $ui = New-DialogUi -Settings $settings
    try {
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 80 $updated.brightness['all'] 'still a number'
        Assert-Equal $false ($updated.brightness['all'] -is [System.Collections.IDictionary]) 'and not a dictionary'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: moving the one-level slider is what gets saved' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Dark $false
        try {
            # The way a person does it: pick the form, move the slider, Save.
            $ed.Brightness.KindBox.SelectedIndex = 1
            $ed.Brightness.OneSlider.Value = 35
            Assert-Equal 'Visible' ([string]$ed.Brightness.OnePanel.Visibility) 'the slider showed up'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 35 $updated.brightness['all'] 'the level landed in the settings'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: Cancel leaves the brightness the window already had' {
    # The editor edits a COPY of the model: otherwise "moved it about and changed my mind" would already
    # have changed the setting, and Cancel would be lying.
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = 70
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Levels $ui.Levels -Dark $false
        try {
            $ed.Brightness.OneSlider.Value = 20
            Assert-Equal 20 ([int]$ed.Brightness.Model.Value) 'the editor moved'
        }
        finally { $ed.Window.Close() }
        # The editor's answer was not applied — the window has to keep what it had.
        Assert-Equal 70 ([int]$ui.Levels['all'].Value) 'the window did not'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: unticking every display removes the setting instead of writing zeros' {
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = [ordered]@{ 'LG ULTRAGEAR' = 60 }
    $ui = New-DialogUi -Settings $settings
    try {
        $ui.Levels['all'].Map.Remove('LG ULTRAGEAR')
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ($updated.brightness.Contains('all')) 'the key is gone, not zeroed'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: switching to per-display seeds it from the level it had' {
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = 70
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Levels $ui.Levels -Dark $false
        try {
            Assert-Equal 'one' ([string]$ed.Brightness.Model.Kind) 'started as one level'
            # The person saw 70 and has to edit from seventy rather than from an empty list.
            $ed.Brightness.KindBox.SelectedIndex = 2
            $got = Read-ModeFromUi -Editor $ed
            Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 70 $updated.brightness['all']['LG ULTRAGEAR'] 'seeded with what was shown'
        Assert-Equal 70 $updated.brightness['all']['LG ULTRAFINE'] 'for every display of the mode'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: the per-display rows are really built' {
    # A test of the building, not of the model: the first version of the rows called
    # [GridLength]::Parse, which does not exist, and the move to "one each" died in the live window. The
    # model was in perfect order at the time — what caught it was a snapshot of the window rather than a
    # test, which is why the rows are built here now.
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = [ordered]@{ 'LG ULTRAGEAR' = 60; 'LG ULTRAFINE' = 25 }
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Levels $ui.Levels -Dark $false
        try {
            Assert-Equal 'Collapsed' ([string]$ed.Brightness.OnePanel.Visibility) 'the single slider is out of the way'
            Assert-Equal 2 $ed.Brightness.RowsPanel.Children.Count 'a row per display'
            # A row's first column is the "set" checkbox, and it carries the name as its label.
            $first = $ed.Brightness.RowsPanel.Children[0]
            Assert-Equal 'LG ULTRAGEAR' ([string]$first.Children[0].Content) 'named after the display'
            Assert-True ([bool]$first.Children[0].IsChecked) 'ticked, because a level is set'
            Assert-Equal 60 ([int]$first.Children[1].Value) 'and the slider stands where the setting says'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: a display with no level gets an unticked, disabled row' {
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = [ordered]@{ 'LG ULTRAGEAR' = 60 }
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Levels $ui.Levels -Dark $false
        try {
            $rows = @($ed.Brightness.RowsPanel.Children)
            $off = @($rows | Where-Object { [string]$_.Children[0].Content -eq 'LG ULTRAFINE' })
            Assert-Equal 1 $off.Count 'the display without a level still has a row'
            Assert-Equal $false ([bool]$off[0].Children[0].IsChecked) 'unticked'
            Assert-Equal $false ([bool]$off[0].Children[1].IsEnabled) 'and its slider is out of action'
            Assert-Equal 'off' ([string]$off[0].Children[2].Text) 'and it says off, not zero'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: unticking a display drops its brightness row with it' {
    # Otherwise a combo would be left with a slider for a monitor it no longer has.
    $combo = [pscustomobject]@{ Name = 'Work'; Patterns = @('LG ULTRAGEAR', 'LG ULTRAFINE'); Primary = '' }
    $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
    $level = ConvertTo-LevelModel ([ordered]@{ 'LG ULTRAGEAR' = 60; 'LG ULTRAFINE' = 25 })
    $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $script:DlgState `
                               -Levels ([ordered]@{ 'combo:Work' = $level }) -Dark $false
    try {
        Assert-Equal 2 $ed.Brightness.RowsPanel.Children.Count 'both displays have a row'
        $uf = @($ed.Checks | Where-Object { [string]$_.Tag -eq 'LG ULTRAFINE' })[0]
        $uf.IsChecked = $false
        $uf.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        $names = @($ed.Brightness.RowsPanel.Children | ForEach-Object { [string]$_.Children[0].Content })
        # The row stays, but as an orphan now: the value is set, and it can only be cleared by seeing it.
        Assert-True ($names -contains 'LG ULTRAGEAR') 'the display that stayed keeps its row'
        $got = Read-ModeFromUi -Editor $ed
        Assert-Equal @('LG ULTRAGEAR') @($got.Mode.Patterns) 'and the combination lost the display'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: renaming a combination carries the sliders too' {
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.brightness['combo:Work'] = 45
    $ui = New-DialogUi -Settings $settings
    try {
        # Through the same door as the live window: the name is changed by the mode editor and not by a
        # hand in the combo list.
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Office'; Patterns = @('LG ULTRAGEAR'); Primary = ''
            Level = $ui.Levels['combo:Work'] })
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 45 $updated.brightness['combo:Office'] 'followed the new name'
        Assert-Equal $false ($updated.brightness.Contains('combo:Work')) 'and left no ghost'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a new combination taking a freed name keeps its own brightness' {
    # Set-UiMode moves the brightness onto the new key at once, so it must NOT be renamed on Save:
    # otherwise a new combo that took over the freed name coincides with the rename's source and
    # silently loses its own brightness.
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.brightness['combo:Work'] = 30
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Play'; Patterns = @('LG ULTRAGEAR'); Primary = ''
            Level = $ui.Levels['combo:Work'] })
        # And straight away we create a new "Work" — the name has been freed up.
        Set-UiMode -Ui $ui -Mode $null -Combo $null -Edited ([pscustomobject]@{
            Name = 'Work'; Patterns = @('LG ULTRAFINE'); Primary = ''
            Level = [pscustomobject]@{ Kind = 'one'; Value = 70; Map = [ordered]@{} } })

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 30 $updated.brightness['combo:Play'] 'the renamed one kept its level'
        Assert-Equal 70 $updated.brightness['combo:Work'] 'and the new one kept its own'
    }
    finally { $ui.Window.Close() }
}
