# --- the Settings window ----------------------------------------------------
# The window is WPF now and is built WITHOUT being shown: New-SettingsWindow builds the element
# tree, and Read-SettingsFromUi — the real Save branch — reads it. ShowDialog is not called in the
# tests at all, so the only thing left untested is the showing itself. There is no need to press
# Save on a timer in a real shown window: the saving is lifted into a pure function, and the tests
# do not flash a window.

Write-Host ''
Write-Host 'the settings window' -ForegroundColor White

Test-Case 'dialog: Save keeps layout, primary and every non-UI field' {
    # The save branch is the real function, and it is what gets tested rather than a retelling of it.
    $settings = Get-DefaultSettings
    $settings.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
    $settings.layout = @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR')
    $settings.primary = 'ULTRAGEAR'
    $settings.audio['combo:Work'] = 'ULTRAFINE'
    $settings.hooks['combo:Work'] = [ordered]@{ before = ''; after = 'x.cmd' }

    $ui = New-DialogUi -Settings $settings
    try {
        Assert-True ($null -ne $ui.WindowsBox) 'the window has the window-memory toggle'
        Assert-True ([bool]$ui.WindowsBox.IsChecked) 'it reflects the default (on)'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-True $got.Ok 'the save was accepted'
        $updated = $got.Settings

        # The XG27AQDMGR is not connected right now — its place in the row has to survive.
        Assert-Equal @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR') @($updated.layout) 'layout survived, absent display included'
        # The star was set by the ULTRAGEAR pattern — the exact name is what leaves for the file.
        Assert-Equal 'LG ULTRAGEAR' $updated.primary 'primary written as the exact name'
        Assert-Equal 'ULTRAFINE' $updated.audio['combo:Work'] 'audio survived'
        Assert-Equal 'x.cmd' $updated.hooks['combo:Work'].after 'the command survived'
        Assert-Equal 'Ctrl+Alt+F1' $updated.hotkeys['solo:LG ULTRAGEAR'] 'hotkey came from the box'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: settings tied to modes keep mode order so Save does not shuffle the file' {
    $modes = @(
        [pscustomobject]@{ Key = 'solo:A'; Title = 'Only A'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'solo:B'; Title = 'Only B'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Patterns = @('A', 'B'); Available = $true }
        [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    )
    # The order in the file is any old order: the window has to line it up by the modes.
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $settings.hotkeys['combo:Work'] = 'Ctrl+Alt+F3'
    $settings.hotkeys['solo:A'] = 'Ctrl+Alt+F1'
    $settings.brightness = [ordered]@{ 'all' = 70; 'solo:A' = 90 }

    $ui = New-SettingsWindow -Modes $modes -Settings $settings -State @()
    try {
        Assert-Equal @('solo:A', 'combo:Work', 'all') @($ui.Hotkeys.Keys) 'shortcuts sorted into mode order'
        Assert-Equal @('solo:A', 'all') @($ui.Levels.Keys) 'and so is the brightness'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a duplicate shortcut is refused, with words' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ui.Hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
        $ui.Hotkeys['all'] = 'Ctrl+Alt+F1'
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-True (-not $got.Ok) 'refused'
        Assert-True ($got.Problem -like '*assigned twice*') 'said why'
        Assert-Null $got.Settings 'nothing half-saved'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: moving a desk card changes the saved order' {
    $settings = Get-DefaultSettings
    $settings.layout = @('LG ULTRAGEAR', 'LG ULTRAFINE')
    $ui = New-DialogUi -Settings $settings
    try {
        $first = $ui.DeskPanel.Children[0]
        Move-DeskCard -Panel $ui.DeskPanel -Card $first -Delta 1
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-Equal @('LG ULTRAFINE', 'LG ULTRAGEAR') @($got.Settings.layout) 'the card really moved'

        # A card does not move past the end of the row and does not get lost.
        Move-DeskCard -Panel $ui.DeskPanel -Card $first -Delta 5
        Assert-Equal 2 $ui.DeskPanel.Children.Count 'nothing lost at the edge'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: removing a combination takes its shortcut and audio along' {
    $settings = Get-DefaultSettings
    $settings.combos['Movie'] = [ordered]@{ displays = @('ULTRAGEAR', 'ULTRAFINE'); primary = '' }
    $settings.hotkeys['combo:Movie'] = 'Ctrl+Alt+F9'
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $settings.audio['combo:Movie'] = 'ROG'
    $settings.audio['all'] = 'SPEAKERS'

    $ui = New-DialogUi -Settings $settings
    try {
        Assert-True ($ui.Hotkeys.Contains('combo:Movie')) 'the combination has a shortcut'
        Remove-UiCombo -Ui $ui -Combo $ui.Combos[0]
        Assert-True (-not $ui.Hotkeys.Contains('combo:Movie')) 'its shortcut went away with it'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-True $got.Ok 'saved'
        Assert-Equal 0 @($got.Settings.combos.Keys).Count 'the combination is gone'
        Assert-True (-not $got.Settings.hotkeys.Contains('combo:Movie')) 'its shortcut died with it'
        Assert-True (-not $got.Settings.audio.Contains('combo:Movie')) 'its audio died with it'
        Assert-Equal 'Ctrl+Alt+F5' $got.Settings.hotkeys['all'] 'other shortcuts kept'
        Assert-Equal 'SPEAKERS' $got.Settings.audio['all'] 'other audio kept'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: renaming a combination carries its shortcut and audio' {
    $settings = Get-DefaultSettings
    $settings.combos['Movie'] = [ordered]@{ displays = @('ULTRAGEAR'); primary = '' }
    $settings.hotkeys['combo:Movie'] = 'Ctrl+Alt+F9'
    $settings.audio['combo:Movie'] = 'ROG'

    $ui = New-DialogUi -Settings $settings
    try {
        # Exactly what the mode editor hands back from its Save button.
        $mode = [pscustomobject]@{ Key = 'combo:Movie'; Title = 'Movie'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Cinema'; Patterns = @('LG ULTRAGEAR', 'LG ULTRAFINE'); Primary = 'LG ULTRAFINE'
            Hotkey = 'Ctrl+Alt+F9' })
        Assert-Equal 'Ctrl+Alt+F9' $ui.Hotkeys['combo:Cinema'] 'the shortcut followed the rename in the window'
        Assert-True (-not $ui.Hotkeys.Contains('combo:Movie')) 'and left the old key behind'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-True $got.Ok 'saved'
        Assert-True (-not $got.Settings.combos.Contains('Movie')) 'old name gone'
        Assert-Equal @('LG ULTRAGEAR', 'LG ULTRAFINE') @($got.Settings.combos['Cinema'].displays) 'displays updated'
        Assert-Equal 'LG ULTRAFINE' $got.Settings.combos['Cinema'].primary 'its own taskbar display saved'
        Assert-Equal 'Ctrl+Alt+F9' $got.Settings.hotkeys['combo:Cinema'] 'shortcut moved to the new key'
        Assert-True (-not $got.Settings.hotkeys.Contains('combo:Movie')) 'and left the old one'
        Assert-Equal 'ROG' $got.Settings.audio['combo:Cinema'] 'audio moved too'
        Assert-True (-not $got.Settings.audio.Contains('combo:Movie')) 'audio left the old key'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: the mode editor prefills members, leftovers, taskbar and shortcut' {
    $combo = [pscustomobject]@{ Name = 'Movie'; Patterns = @('ULTRAGEAR', 'GONE PANEL'); Primary = 'ULTRAGEAR'; OriginalName = 'Movie' }
    $mode = [pscustomobject]@{ Key = 'combo:Movie'; Title = 'Movie'; Kind = 'combo'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $script:DlgState -TakenNames @() `
                               -Hotkeys ([ordered]@{ 'combo:Movie' = 'Ctrl+Alt+F9' }) -Dark $false
    try {
        Assert-Equal 'Movie' $ed.NameBox.Text 'name prefilled'
        Assert-Equal 3 @($ed.Checks).Count 'two live displays plus the leftover pattern'
        $byTag = @{}
        foreach ($cb in $ed.Checks) { $byTag[[string]$cb.Tag] = [bool]$cb.IsChecked }
        Assert-True $byTag['LG ULTRAGEAR'] 'matched display ticked'
        Assert-True (-not $byTag['LG ULTRAFINE']) 'unrelated display not ticked'
        # The monitor was taken away, but throwing it out of the combo silently is not allowed.
        Assert-True $byTag['GONE PANEL'] 'a pattern with no display kept as its own ticked row'
        Assert-Equal 'LG ULTRAGEAR' ([string]$ed.PrimaryBox.SelectedItem) 'taskbar pick found by pattern'
        Assert-Equal 'Ctrl+Alt+F9' $ed.HotkeyBox.Text 'shortcut prefilled'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: the editor shows no-shortcut for rubbish instead of pretending it is one' {
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -TakenNames @() `
                               -Hotkeys ([ordered]@{ 'all' = 'needs Ctrl / Alt / Shift' }) -Dark $false
    try {
        Assert-Equal $script:NoHotkeyText $ed.HotkeyBox.Text 'hint text did not survive as a binding'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: a shortcut can be removed, and the mode row stays' {
    # "The shortcuts will not come off" — that is how it looked when a binding could only be cleared
    # with Backspace on a tiny hint line. Now it comes off in the mode editor, and an empty answer
    # from the editor has to remove it.
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal 'Ctrl+Alt+F5' $ui.Hotkeys['all'] 'starts bound'
        $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited ([pscustomobject]@{ Hotkey = '' })
        Assert-True (-not $ui.Hotkeys.Contains('all')) 'the window forgot it'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-True $got.Ok 'saved'
        Assert-True (-not $got.Settings.hotkeys.Contains('all')) 'the binding is gone from the file'
        # And the mode's row itself stayed: modes are not deleted here, they follow from the monitors
        # and the combos.
        Assert-Equal 3 $ui.ModesPanel.Children.Count 'two displays and all of them are still listed'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: in-progress hint text never becomes a binding' {
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $ui = New-DialogUi -Settings $settings
    try {
        foreach ($junk in $script:PressKeysText, 'needs Ctrl / Alt / Shift', 'unsupported key', '') {
            $ui.Hotkeys['all'] = $junk
            $got = Read-SettingsFromUi -Ui $ui -Settings $settings
            Assert-True (-not $got.Settings.hotkeys.Contains('all')) "'$junk' is not a binding"
        }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a shortcut picked in the mode editor lands on the mode' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        # Exactly what the editor hands back on Save, together with the shortcut.
        Set-UiMode -Ui $ui -Mode $null -Combo $null -Edited ([pscustomobject]@{
            Name = 'Movie'; Patterns = @('LG ULTRAGEAR'); Primary = ''; Hotkey = 'Ctrl+Alt+F7' })
        Assert-Equal 'Ctrl+Alt+F7' $ui.Hotkeys['combo:Movie'] 'the mode got the keys'
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-Equal 'Ctrl+Alt+F7' $got.Settings.hotkeys['combo:Movie'] 'and they save'

        # Clearing a shortcut in the editor is an edit too, not "leave it as it was".
        $mode = [pscustomobject]@{ Key = 'combo:Movie'; Title = 'Movie'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Movie'; Patterns = @('LG ULTRAGEAR'); Primary = ''; Hotkey = '' })
        Assert-True (-not $ui.Hotkeys.Contains('combo:Movie')) 'cleared back to no shortcut'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: every mode row says what kind of mode it is' {
    # The caption answers the question of why one row has a Remove and another does not: a monitor
    # mode and "all" appear by themselves, a combo is something you create.
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
    )
    Assert-Equal 'Display' (Get-ModeSubtitle -Mode ([pscustomobject]@{ Kind = 'solo' })) 'a single display'

    $combo = Get-ModeSubtitle -Mode ([pscustomobject]@{
        Kind = 'combo'; Patterns = @('LG ULTRAFINE', 'XG27AQDMGR'); Primary = 'LG ULTRAFINE' }) -State $state
    Assert-True ($combo -like 'Combination*') 'a combination says it is a combination'
    Assert-True ($combo -like '*LG ULTRAFINE + XG27AQDMGR*') 'and lists its displays'
    Assert-True ($combo -like '*taskbar on LG ULTRAFINE*') 'and where the taskbar goes'

    Assert-Equal 'Every connected display' (Get-ModeSubtitle -Mode ([pscustomobject]@{ Kind = 'all' })) 'all'
    Assert-True ((Get-ModeSubtitle -Mode ([pscustomobject]@{ Kind = 'orphan' })) -like '*kept until you remove it*') 'orphan'
}

Test-Case 'dialog: every mode is set up in one place, and only combinations can be removed' {
    # One row per mode with an Edit button, and a Remove only on what a person created themselves.
    $settings = Get-DefaultSettings
    $settings.combos['Movie'] = [ordered]@{ displays = @('ULTRAGEAR'); primary = '' }
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Null $ui.Window.FindName('RolesPanel') 'no display-groups panel'
        Assert-Null $ui.Window.FindName('CombosPanel') 'no separate combinations card'
        Assert-Null $ui.Window.FindName('LevelModeBox') 'and no brightness card of its own'
        Assert-True ($null -ne $ui.ModesPanel) 'modes are the one place'
        Assert-True ($null -ne $ui.AddComboBtn) 'with a button to add a combination'

        # solo:UG, solo:UF, combo:Movie, all — every row has an Edit, and a Remove only on the combo.
        $buttons = @()
        foreach ($row in $ui.ModesPanel.Children) {
            $names = @($row.Children | Where-Object { $_ -is [System.Windows.Controls.Button] } | ForEach-Object { [string]$_.Content })
            $buttons += , $names
        }
        Assert-Equal 4 $buttons.Count 'a row per mode'
        Assert-Equal 4 @($buttons | Where-Object { $_ -contains 'Edit' }).Count 'every mode can be edited'
        Assert-Equal 1 @($buttons | Where-Object { $_ -contains 'Remove' }).Count 'only the combination can be removed'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: the cross clears a shortcut and greys itself out when there is nothing to clear' {
    # The button and the field find each other through .Tag — without that the cross would silently
    # not work (closures in handlers lose both functions and $script:).
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -TakenNames @() `
                               -Hotkeys ([ordered]@{ 'all' = 'Ctrl+Alt+F5' }) -Dark $false
    try {
        $box = $ed.HotkeyBox
        $clear = $box.Tag
        Assert-True ($null -ne $clear) 'the box knows its cross'
        Assert-True $clear.IsEnabled 'enabled while a shortcut is set'

        $clear.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        Assert-Equal $script:NoHotkeyText $box.Text 'the click cleared the box'
        Assert-True (-not $clear.IsEnabled) 'and greyed itself out'

        # Assigned again — the cross is alive again (it follows the field, not the clicks).
        $box.Text = 'Ctrl+Alt+F8'
        Assert-True $clear.IsEnabled 'awake again'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'mode editor: what it reads, and every refusal' {
    $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $script:DlgState `
                               -TakenNames @('Movie') -Hotkeys ([ordered]@{ 'all' = 'Ctrl+Alt+F5' }) -Dark $false
    try {
        # An empty name.
        $got = Read-ModeFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'no name is refused'
        Assert-True ($got.Problem -like '*name*') 'and says so'

        # The name is taken.
        $ed.NameBox.Text = 'movie'
        $got = Read-ModeFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'a taken name is refused, case aside'
        Assert-True ($got.Problem -like "*already exists*") 'and says so'

        # Not a single monitor.
        $ed.NameBox.Text = 'Cinema'
        $got = Read-ModeFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'no displays is refused'
        Assert-True ($got.Problem -like '*at least one display*') 'and says so'

        # Somebody else's shortcut.
        $ed.Checks[0].IsChecked = $true
        $ed.HotkeyBox.Text = 'Ctrl+Alt+F5'
        $got = Read-ModeFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'a shortcut owned by another mode is refused'
        Assert-True ($got.Problem -like "*already drives 'All displays'*") 'and names the mode holding it'

        # Everything in order.
        $ed.HotkeyBox.Text = 'Ctrl+Alt+F6'
        $got = Read-ModeFromUi -Editor $ed
        Assert-True $got.Ok 'accepted'
        Assert-Equal 'Cinema' $got.Mode.Name 'name trimmed and kept'
        Assert-Equal @('LG ULTRAGEAR') @($got.Mode.Patterns) 'the ticked display'
        Assert-Equal 'Ctrl+Alt+F6' $got.Mode.Hotkey 'the shortcut'
        Assert-Equal '' $got.Mode.Primary 'no taskbar display chosen means the usual rules'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'combo editor: the taskbar display must be one of the ticked ones' {
    $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $script:DlgState -TakenNames @() -Dark $false
    try {
        $ed.NameBox.Text = 'Pair'
        $ed.Checks[0].IsChecked = $true
        $ed.PrimaryBox.SelectedItem = [string]$ed.Checks[1].Tag   # not ticked
        $got = Read-ModeFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'refused'
        Assert-True ($got.Problem -like '*must be one of the ticked*') 'and says why'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: a mode keeping its own shortcut is not a conflict with itself' {
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $settings.combos['Movie'] = [ordered]@{ displays = @('ULTRAGEAR'); primary = '' }
    $settings.hotkeys['combo:Movie'] = 'Ctrl+Alt+F9'
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = [pscustomobject]@{ Key = 'combo:Movie'; Title = 'Movie'; Kind = 'combo'; Available = $true }
        $ed = New-ModeEditorWindow -Mode $mode -Combo $ui.Combos[0] -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark $false
        try {
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'its own binding, left alone, goes through'
            Assert-Equal 'Ctrl+Alt+F9' $got.Mode.Hotkey 'and comes back as it was'

            $ed.HotkeyBox.Text = 'Ctrl+Alt+F5'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True (-not $got.Ok) "another mode's binding is refused"
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a binding without its display still gets a row' {
    $settings = Get-DefaultSettings
    $settings.hotkeys['solo:GONE MONITOR'] = 'Ctrl+Alt+F8'
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-True ($ui.Hotkeys.Contains('solo:GONE MONITOR')) 'orphan binding kept'
        Assert-Equal 'Ctrl+Alt+F8' $ui.Hotkeys['solo:GONE MONITOR'] 'with its combination shown'
        # The orphan row is in the list: the binding can only be cleared from here.
        Assert-Equal 4 $ui.ModesPanel.Children.Count 'two displays, all of them, and the orphan'
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-Equal 'Ctrl+Alt+F8' $got.Settings.hotkeys['solo:GONE MONITOR'] 'and it survives a save'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: WPF modifier bits equal the RegisterHotKey bits' {
    # Register-HotkeyCapture hands [Keyboard]::Modifiers straight to Format-HotkeyString, with no
    # re-encoding — which is only legitimate as long as the bit numbers coincide.
    Initialize-WpfRuntime
    Assert-Equal 1 ([int][System.Windows.Input.ModifierKeys]::Alt) 'Alt'
    Assert-Equal 2 ([int][System.Windows.Input.ModifierKeys]::Control) 'Ctrl'
    Assert-Equal 4 ([int][System.Windows.Input.ModifierKeys]::Shift) 'Shift'
    Assert-Equal 8 ([int][System.Windows.Input.ModifierKeys]::Windows) 'Win'
    Assert-Equal 0x70 ([System.Windows.Input.KeyInterop]::VirtualKeyFromKey([System.Windows.Input.Key]::F1)) 'F1 virtual key'
}
