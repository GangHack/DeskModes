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
    $combo = [pscustomobject]@{ Name = 'Movie'; Patterns = @('ULTRAGEAR', 'GONE PANEL'); Primary = 'ULTRAGEAR' }
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
    # A display's mode says nothing under its title: "Only LG ULTRAFINE" needs no line saying
    # "Display" beneath it. The row is one line high until the mode has something set on it.
    Assert-Equal '' (Get-ModeSubtitle -Mode ([pscustomobject]@{ Kind = 'solo' })) 'a single display'

    $combo = Get-ModeSubtitle -Mode ([pscustomobject]@{
        Kind = 'combo'; Patterns = @('LG ULTRAFINE', 'XG27AQDMGR'); Primary = 'LG ULTRAFINE' }) -State $state
    # No word saying "combination": the Remove button beside the row is what tells them apart,
    # and the caption's room goes to what cannot be seen any other way.
    Assert-True ($combo -notlike '*Combination*') 'it does not say the obvious'
    Assert-True ($combo -like 'LG ULTRAFINE + XG27AQDMGR*') 'it opens with its displays'
    # The star and the name, not the words "taskbar on": the card on the desk page draws that
    # same star for the same fact, and this caption is the first thing on its row to be trimmed.
    Assert-True ($combo -like "*$($script:UiStar) LG ULTRAFINE*") 'and says where the taskbar goes'
    Assert-True ($combo -notlike '*taskbar on*') 'without spending eleven characters saying it'

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
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Audio $ui.Audio -Hooks $ui.Hooks -Dark $false
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

Test-Case 'dialog: rebuilding the desk is three controls, and they start where the file left them' {
    # Until they were in the window, these three could only be changed by editing the file - and
    # two of them default to ON, so "I never asked for this" had no answer anywhere in the app.
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-True ([bool]$ui.ResumeBox.IsChecked) 'waking from sleep rebuilds, as the defaults have it'
        Assert-True ([bool]$ui.UnplugBox.IsChecked) 'so does a display going away'
        Assert-Equal 0 $ui.PlugModeBox.SelectedIndex 'and a display arriving does nothing'
        Assert-Equal '' ([string]$ui.PlugModeBox.SelectedItem.Tag) 'which is what the empty key means'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a half-written reapply does not read as the other half turned off' {
    # The file gets edited by hand, and a section with one key in it is normal. Reading a missing
    # key as $false would silently turn off a rebuild the person never asked to lose.
    $settings = Get-DefaultSettings
    $settings.reapply = [ordered]@{ onUnplug = $false }
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-True ([bool]$ui.ResumeBox.IsChecked) 'the key that is absent keeps its default'
        Assert-Equal $false ([bool]$ui.UnplugBox.IsChecked) 'and the one that is written is obeyed'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: the two rebuild toggles survive a Save' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ui.ResumeBox.IsChecked = $false
        $ui.UnplugBox.IsChecked = $false
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ([bool]$updated.reapply.onResume) 'sleep is off'
        Assert-Equal $false ([bool]$updated.reapply.onUnplug) 'unplug is off'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: "when a display is plugged in" offers every mode and saves the key' {
    $settings = New-TestSettings -Combos @{ Work = @('LG ULTRAGEAR') }
    $ui = New-DialogUi -Settings $settings
    try {
        # "do nothing", two displays, all, and the combination.
        Assert-Equal 5 $ui.PlugModeBox.Items.Count 'nothing plus every mode'
        $pick = @($ui.PlugModeBox.Items | Where-Object { [string]$_.Tag -eq 'combo:Work' })[0]
        Assert-True ($null -ne $pick) 'the combination is offered'
        Assert-Equal 'Work' ([string]$pick.Content) 'by its title, not its key'

        $ui.PlugModeBox.SelectedItem = $pick
        Assert-Equal 'combo:Work' ([string]$ui.OnPlugKey) 'picking it is remembered as a key'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'combo:Work' ([string]$updated.reapply.onPlug) 'and that is what reaches the file'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: an orphan row is not offered as somewhere to switch to' {
    # A key with no mode behind it can be seen and cleared in the mode list. Offering it here as
    # a destination would let a person choose a mode the switch cannot reach.
    $settings = Get-DefaultSettings
    $settings.hotkeys['combo:Gone'] = 'Ctrl+Alt+F8'
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal 4 $ui.ModesPanel.Children.Count 'the orphan has its row'
        Assert-Equal 4 $ui.PlugModeBox.Items.Count 'but the dropdown is nothing plus the three real modes'
        Assert-Equal 0 @($ui.PlugModeBox.Items | Where-Object { [string]$_.Tag -eq 'combo:Gone' }).Count `
            'and it is not among them'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a stored destination whose mode is not here keeps its place' {
    # The mode may belong to a monitor that is unplugged right now. Clearing the choice because
    # its display is asleep is losing a decision the person never cancelled.
    $settings = Get-DefaultSettings
    $settings.reapply.onPlug = 'solo:GONE MONITOR'
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal 'solo:GONE MONITOR' ([string]$ui.PlugModeBox.SelectedItem.Tag) 'it is still the choice'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'solo:GONE MONITOR' ([string]$updated.reapply.onPlug) 'and a plain Save leaves it alone'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: renaming a combination moves the plug destination with it' {
    $settings = New-TestSettings -Combos @{ Work = @('LG ULTRAGEAR') }
    $settings.reapply.onPlug = 'combo:Work'
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Office'; Patterns = @('LG ULTRAGEAR'); Primary = '' })
        Assert-Equal 'combo:Office' ([string]$ui.OnPlugKey) 'the destination followed the rename'
        Assert-Equal 'combo:Office' ([string]$ui.PlugModeBox.SelectedItem.Tag) 'and the dropdown shows it'
        Assert-Equal 'Office' ([string]$ui.PlugModeBox.SelectedItem.Content) 'under the new name'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'combo:Office' ([string]$updated.reapply.onPlug) 'and that is what is saved'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: deleting the combination it pointed at clears the plug destination' {
    $settings = New-TestSettings -Combos @{ Work = @('LG ULTRAGEAR') }
    $settings.reapply.onPlug = 'combo:Work'
    $ui = New-DialogUi -Settings $settings
    try {
        Remove-UiCombo -Ui $ui -Combo $ui.Combos[0]
        Assert-Equal '' ([string]$ui.OnPlugKey) 'nowhere to switch to any more'
        Assert-Equal 0 $ui.PlugModeBox.SelectedIndex 'the dropdown says so'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal '' ([string]$updated.reapply.onPlug) 'and the file agrees'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a key the window does not edit survives inside reapply' {
    # The window owns three of the keys in that section and not the section itself.
    $settings = Get-DefaultSettings
    $settings.reapply['somethingElse'] = 'keep me'
    $ui = New-DialogUi -Settings $settings
    try {
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'keep me' ([string]$updated.reapply['somethingElse']) 'carried through untouched'
        Assert-True ([bool]$updated.reapply.onResume) 'and the ones it does own are still written'
    }
    finally { $ui.Window.Close() }
}

# --- the pane, the pages and where the window stood --------------------------
# The window is an application now: five pages behind a pane instead of one column of cards. What
# a test can hold on to is that the pages exist, that switching between them changes nothing but
# what is visible, and that a remembered rectangle is refused when it is off every screen.

Test-Case 'dialog: the pane opens on the desk, and every page it names exists' {
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    try {
        Assert-Equal 'desk' ([string]$ui.Page) 'the first page is the desk'
        Assert-Equal 6 $ui.Pages.Count 'six pages'
        foreach ($name in @($ui.Pages.Keys)) {
            Assert-True ($null -ne $ui.Pages[$name]) "the page '$name' is in the markup"
        }
        Assert-Equal 'Visible' ([string]$ui.Pages['desk'].Visibility) 'the desk is up'
        Assert-Equal 'Collapsed' ([string]$ui.Pages['about'].Visibility) 'and About is not'
        Assert-Equal 'desk' ([string]$ui.NavList.SelectedItem.Tag) 'the pane marks where we are'
        Assert-Null $ui.NavAbout.SelectedItem 'and the bottom list is not marked as well'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: switching pages changes what is visible and nothing else' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ui.NotifyBox.IsChecked = $true
        $ui.LastModeBox.IsChecked = $false

        Set-UiPage -Ui $ui -Page 'about'
        Assert-Equal 'about' ([string]$ui.Page) 'we are on About'
        Assert-Equal 'Visible' ([string]$ui.Pages['about'].Visibility) 'the page is up'
        Assert-Equal 'Collapsed' ([string]$ui.Pages['desk'].Visibility) 'and the desk is away'
        # About lives in the pane's second list, and only one of the two may look chosen.
        Assert-Equal 'about' ([string]$ui.NavAbout.SelectedItem.Tag) 'marked at the bottom'
        Assert-Null $ui.NavList.SelectedItem 'and unmarked at the top'

        # A page nobody has: back to the first one rather than to a blank window.
        Set-UiPage -Ui $ui -Page 'nowhere'
        Assert-Equal 'desk' ([string]$ui.Page) 'an unknown page falls back to the desk'

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-True ([bool]$updated.notifications) 'what was set on another page is still set'
        Assert-Equal $false ([bool]$updated.restoreLastMode) 'both ways round'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: the seldom-needed settings are a card of their own, and still saved' {
    # They used to be folded away to keep the window inside a 1440p screen. The page has the room,
    # so the fold is gone - and being visible must not change what a Save writes.
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Null $ui.Window.FindName('MoreBtn') 'the fold button is gone'
        Assert-Null $ui.Window.FindName('MorePanel') 'and so is the panel it hid'
        $ui.RefreshBox.IsChecked = $true
        $ui.ResumeBox.IsChecked = $false
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-True ([bool]$updated.maximizeRefresh) 'the watchdog setting was read'
        Assert-Equal $false ([bool]$updated.reapply.onResume) 'and so was the one below it'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: About says the same version line the command line does' {
    # On two lines here and one on the command line, and the two halves have to add up to that
    # one line exactly: it is what a bug report opens with, and a version the window and the
    # console disagree about is worse than no version at all.
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    try {
        Assert-Equal (Get-VersionLine) ([string]$ui.VersionText.Text + ' - ' + [string]$ui.VersionHost.Text) `
                     'the same line, word for word'
        Assert-True ([string]$ui.VersionText.Text -like "*$script:Version*") 'the version is the readable half'
        Assert-True ([string]$ui.VersionHost.Text -like '*Windows *') 'and the build is the quiet one'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: with no address the whole Support section is gone, not a dead button' {
    # A disabled BtnAccent is a grey-blue plate the size of the page's primary action, and it
    # read as the one button on the page that had come out broken. The button stays disabled
    # underneath as the second lock - a future address brings the section back with one variable.
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    try {
        if ($script:DonateUrl) {
            Assert-Equal 'Visible' ([string]$ui.SupportCard.Visibility) 'there is an address, so there is a section'
            Assert-True $ui.DonateBtn.IsEnabled 'and the button works'
        }
        else {
            Assert-Equal 'Collapsed' ([string]$ui.SupportCard.Visibility) 'no address, no section'
            Assert-Equal $false ([bool]$ui.DonateBtn.IsEnabled) 'and no button either'
            Assert-True ([string]$ui.DonateHint.Text -like '*no address*') 'which says so in words when it comes back'
        }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: the Displays table names every display and its Monitor ID' {
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    try {
        $texts = @($ui.DisplaysTable.Children |
                   Where-Object { $_ -is [System.Windows.Controls.TextBlock] } |
                   ForEach-Object { [string]$_.Text })
        Assert-True ($texts -contains 'Monitor ID') 'the column that settings.json is written in'
        Assert-True ($texts -contains 'LG ULTRAFINE') 'a display by name'
        Assert-True ($texts -contains 'GSM5CBC') 'and by the id the log calls it'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'window rect: a remembered window is refused when it is off every screen' {
    # Monitors come and go. A window put back onto one that is no longer there cannot be reached,
    # moved or closed - so a rectangle is only used when the title bar lands on something.
    $screens = @([pscustomobject]@{ Left = 0; Top = 0; Right = 1920; Bottom = 1040 })

    Assert-True (Test-WindowRectVisible -Left 100 -Top 100 -Width 980 -Height 660 -Screens $screens) `
                'wholly on the screen'
    Assert-True (Test-WindowRectVisible -Left 1700 -Top 900 -Width 980 -Height 660 -Screens $screens) `
                'a corner with enough of the title bar on it still counts'
    Assert-Equal $false (Test-WindowRectVisible -Left 2200 -Top 100 -Width 980 -Height 660 -Screens $screens) `
                'the second monitor is gone'
    Assert-Equal $false (Test-WindowRectVisible -Left 100 -Top 1100 -Width 980 -Height 660 -Screens $screens) `
                'below the taskbar, title bar and all'
    Assert-Equal $false (Test-WindowRectVisible -Left 1880 -Top 100 -Width 980 -Height 660 -Screens $screens) `
                'forty points of it showing is not something to grab'
    Assert-Equal $false (Test-WindowRectVisible -Left -9000 -Top -9000 -Width 980 -Height 660 -Screens $screens) `
                'nowhere near any screen at all'
    Assert-Equal $false (Test-WindowRectVisible -Left 100 -Top 100 -Width 0 -Height 0 -Screens $screens) `
                'a window with no size was never shown'
    Assert-Equal $false (Test-WindowRectVisible -Left 100 -Top 100 -Width 980 -Height 660 -Screens @()) `
                'and with no screens at all, nothing is visible'
}

Test-Case 'window rect: the second monitor is a place to open on' {
    $screens = @(
        [pscustomobject]@{ Left = 0; Top = 0; Right = 1920; Bottom = 1040 }
        [pscustomobject]@{ Left = 1920; Top = -400; Right = 5760; Bottom = 1760 }
    )
    Assert-True (Test-WindowRectVisible -Left 3000 -Top -200 -Width 980 -Height 660 -Screens $screens) `
                'on the one to the right, above the primary'
}

# --- how long until the displays go dark -------------------------------------
# Windows' own setting, shown on the desk page and written back on Save. Nothing here touches the
# real power scheme: what is tested is the list, the naming and the rule about writing.

Test-Case 'sleep: a timeout is named the way a person would say it' {
    Assert-Equal 'Never' (Get-SleepChoiceTitle 0) 'nought is not "0 min"'
    Assert-Equal 'Never' (Get-SleepChoiceTitle -5) 'and neither is anything below it'
    Assert-Equal '15 min' (Get-SleepChoiceTitle 15) 'minutes as minutes'
    Assert-Equal '1 h' (Get-SleepChoiceTitle 60) 'an hour as an hour'
    Assert-Equal '1 h 30 min' (Get-SleepChoiceTitle 90) 'and the odd one in both'
}

Test-Case 'sleep: a value set in Windows itself keeps its place in the list' {
    # The ready answers are not the only ones there are: Windows offers more in its own dialog,
    # and a person who set thirteen minutes there must not have it rounded to fifteen by opening
    # this window.
    $ready = @(Get-SleepChoices)
    Assert-Equal 0 $ready[0] '"never" stands first'
    Assert-True ($ready -contains 60) 'an hour is offered'

    $odd = @(Get-SleepChoices -Current 13)
    Assert-Equal ($ready.Count + 1) $odd.Count 'the odd value is added'
    Assert-True ($odd -contains 13) 'and it is there'
    Assert-Equal @($odd | Sort-Object) $odd 'in its place, not at the end'

    Assert-Equal $ready.Count @(Get-SleepChoices -Current 15).Count 'one that is already there is not doubled'
}

Test-Case 'dialog: the sleep row offers the timeout Windows reports' {
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    try {
        Set-UiSleepMinutes -Ui $ui -Minutes 13
        Assert-True $ui.SleepBox.IsEnabled 'the row can be used'
        Assert-Equal 13 (Get-UiSleepMinutes -Ui $ui) 'and it opens on what Windows said'
        Assert-Equal '13 min' ([string]$ui.SleepBox.SelectedItem.Content) 'in words'
        Assert-Equal (@(Get-SleepChoices -Current 13).Count) $ui.SleepBox.Items.Count 'the ready answers and that one'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a timeout Windows would not report leaves the row alone' {
    # -1 is not nought. A dropdown saying "Never" over a setting nobody could read is a lie a
    # person would act on.
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    try {
        Set-UiSleepMinutes -Ui $ui -Minutes -1
        Assert-Equal $false ([bool]$ui.SleepBox.IsEnabled) 'it cannot be used'
        Assert-Equal 0 $ui.SleepBox.Items.Count 'and offers nothing'
        Assert-Equal -1 (Get-UiSleepMinutes -Ui $ui) 'which is what a Save would be told'
        Assert-True ([string]$ui.SleepHint.Text -like '*would not say*') 'the row says why'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: Edit stands in the same place on every row of the mode list' {
    # Edit is on every row and Remove only on a combination and an orphan. With Edit in the third
    # column its place depended on whether the fourth was occupied, so it sat 72 points further
    # right on a display's mode than on the combination under it - and the eye had to find it
    # again on every row. Edit is the LAST column now, so its right edge is the row's right edge.
    $settings = Get-DefaultSettings
    $settings.combos['Movie'] = [ordered]@{ displays = @('ULTRAGEAR'); primary = '' }
    $ui = New-DialogUi -Settings $settings
    try {
        $columns = @{}
        foreach ($row in @($ui.ModesPanel.Children)) {
            foreach ($button in @($row.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })) {
                $label = [string]$button.Content
                # Not @($columns[$label]) + ...: a key that is not there yet answers $null, and
                # @($null) is an array holding one $null - which would make every list start with
                # a nought and turn the assertions below into a check on nothing.
                if (-not $columns.ContainsKey($label)) { $columns[$label] = @() }
                $columns[$label] += [System.Windows.Controls.Grid]::GetColumn($button)
            }
            # And every row is the same height, one line of text or two: without that the shortcut
            # and the buttons stepped up and down the list.
            Assert-Equal 40 ([double]$row.MinHeight) 'one height for every row'
        }
        Assert-Equal 1 (@($columns['Edit'] | Sort-Object -Unique).Count) 'Edit is in one column, always the same one'
        Assert-Equal 3 ([int]@($columns['Edit'])[0]) 'and it is the last of the four'
        Assert-Equal 2 ([int]@($columns['Remove'])[0]) 'Remove comes before it, so an absent one moves nobody'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: the footer says Close where there is nothing to save, and Cancel once there is' {
    # The Diary and the About page hold no setting of their own. With nothing edited anywhere
    # either, a Save that would rewrite the file unchanged and a Cancel offering to throw away
    # nothing are two questions to answer on a page somebody opened to read.
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    try {
        foreach ($page in 'diary', 'about') {
            Set-UiPage -Ui $ui -Page $page
            Assert-Equal 'Collapsed' ([string]$ui.SaveBtn.Visibility) "$page has nothing to save"
            Assert-Equal 'Close' ([string]$ui.CancelBtn.Content) "and nothing to cancel either"
        }
        foreach ($page in 'desk', 'modes', 'rules', 'behavior') {
            Set-UiPage -Ui $ui -Page $page
            Assert-Equal 'Visible' ([string]$ui.SaveBtn.Visibility) "$page is a page of settings"
            Assert-Equal 'Cancel' ([string]$ui.CancelBtn.Content) 'so both buttons mean something'
        }

        # And the pair comes back the moment anything is edited: the footer belongs to the WINDOW,
        # and hiding Save with edits standing behind it would strand them on a page that cannot save.
        $ui.NotifyBox.IsChecked = -not $ui.NotifyBox.IsChecked
        Set-UiPage -Ui $ui -Page 'about'
        Assert-Equal 'Visible' ([string]$ui.SaveBtn.Visibility) 'there is something to save now'
        Assert-Equal 'Cancel' ([string]$ui.CancelBtn.Content) 'and something to throw away'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a window nobody has touched reads as unedited, however its file was written' {
    # The comparison is against the window as it OPENED and not against settings.json: the file is
    # edited by hand and may be missing half its keys, so what the window would write does not
    # equal the file even untouched - and every page would say "Cancel" for ever.
    $settings = Get-DefaultSettings
    $settings.Remove('notifications')
    $settings.Remove('layout')
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal $false (Test-UiEdited -Ui $ui) 'a half-written file is not an edit'
        $ui.StatsBox.IsChecked = -not $ui.StatsBox.IsChecked
        Assert-True (Test-UiEdited -Ui $ui) 'and a switch thrown is'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: asking what would be saved does not write "rejected save" into the log' {
    # The footer asks Read-SettingsFromUi what the window WOULD write, several times per window.
    # Two modes on one key make that answer "it cannot", and without -Quiet the log filled with a
    # line about a save nobody had attempted.
    $settings = Get-DefaultSettings
    $settings.combos['Movie'] = [ordered]@{ displays = @('LG ULTRAFINE'); primary = '' }
    $settings.hotkeys = [ordered]@{ 'all' = 'Ctrl+Alt+F5'; 'combo:Movie' = 'Ctrl+Alt+F5' }
    $ui = New-DialogUi -Settings $settings
    try {
        $before = @(Get-Content $script:LogFile -ErrorAction SilentlyContinue).Count
        Assert-True (Test-UiEdited -Ui $ui) 'a window that cannot be saved never matches how it opened'
        $after = @(Get-Content $script:LogFile -ErrorAction SilentlyContinue).Count
        Assert-Equal $before $after 'and it said nothing about it in the log'

        # Save itself still does say so: that refusal is a thing that happened.
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-Equal $false $got.Ok 'the duplicate is still refused'
        Assert-True (@(Get-Content $script:LogFile).Count -gt $after) 'and a real refusal is written down'
    }
    finally { $ui.Window.Close() }
}

# --- the way-back shortcut and the desk copied from Windows ------------------

Test-Case 'dialog: the way-back shortcut is set on the Behavior page and saved beside the modes' {
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $settings.hotkeys[$script:BackHotkeyName] = 'Ctrl+Alt+F9'
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal 'Ctrl+Alt+F9' $ui.BackHotkeyBox.Text 'shown in its own field'
        Assert-True (-not $ui.Hotkeys.Contains($script:BackHotkeyName)) 'and not in the map of modes'
        $rows = @($ui.ModesPanel.Children | Where-Object { $_.Tag -and [string]$_.Tag -eq $script:BackHotkeyName })
        Assert-Equal 0 $rows.Count 'so there is no orphan row called back'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-True $got.Ok 'saved'
        Assert-Equal 'Ctrl+Alt+F9' ([string]$got.Settings.hotkeys[$script:BackHotkeyName]) 'under its own name in the file'
        Assert-Equal 'Ctrl+Alt+F5' ([string]$got.Settings.hotkeys['all']) 'next to the modes'

        # The same key as a mode is the same refusal a duplicate between two modes gets.
        $ui.BackHotkeyBox.Text = 'Ctrl+Alt+F5'
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-Equal $false $got.Ok 'refused'
        Assert-True ($got.Problem -like '*assigned twice*') 'with words'

        # Cleared, it leaves the file.
        $ui.BackHotkeyBox.Text = $script:NoHotkeyText
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-True (-not $got.Settings.hotkeys.Contains($script:BackHotkeyName)) 'gone'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: the mode list never grows a row for the way back' {
    $settings = Get-DefaultSettings
    $settings.hotkeys[$script:BackHotkeyName] = 'Ctrl+Alt+F9'
    $modes = @(Get-DialogModes -State $script:DlgState -Settings $settings)
    Assert-Equal 0 @($modes | Where-Object { $_.Kind -eq 'orphan' }).Count 'no orphan for it'
}

Test-Case 'desk: copy from Windows orders the cards by position and stars the taskbar display' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf')
        (New-FakeMonitor 'XG27AQDMGR' 'AUS1234' 'path-xg' $false)
    )
    $state[1].Primary = $true
    # The UltraFine stands left of the UltraGear in Windows; the ASUS is off and has no position.
    $positions = @{ 'path-ug' = [pscustomobject]@{ X = 2560; Y = 0 }; 'path-uf' = [pscustomobject]@{ X = 0; Y = 200 } }
    $read = Get-DeskReadOrder -State $state -Positions $positions
    Assert-Equal @('LG ULTRAFINE', 'LG ULTRAGEAR') @($read.Order) 'left to right as Windows has them'
    Assert-Equal 'LG ULTRAFINE' $read.Primary 'and the one with the taskbar'

    $settings = Get-DefaultSettings
    $settings.layout = @('XG27AQDMGR', 'LG ULTRAGEAR', 'LG ULTRAFINE')
    $settings.primary = 'ULTRAGEAR'
    $ui = New-DialogUi -Settings $settings -State $state
    try {
        # Under $script: on purpose: the fake is called from inside Invoke-DeskRead, whose own
        # (empty) $positions is the nearest one a plain name would find.
        $script:TestReadPositions = $positions
        function Get-CcdSourcePositions { return $script:TestReadPositions }
        Invoke-DeskRead -Ui $ui
        $got = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal @('LG ULTRAFINE', 'LG ULTRAGEAR', 'XG27AQDMGR') @($got.layout) 'the two that are on lead, the off one keeps its card behind them'
        Assert-Equal 'LG ULTRAFINE' ([string]$got.primary) 'and the star moved'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'desk: a new combination opens on the displays that are on, with the taskbar chosen' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf' $false)
    )
    $state[0].Primary = $true
    $template = New-DeskTemplate -State $state
    Assert-Equal @('LG ULTRAGEAR') @($template.Patterns) 'only what is on'
    Assert-Equal 'LG ULTRAGEAR' $template.Primary 'and its taskbar'
    Assert-Equal '' $template.Name 'no name yet - that is the one thing a person has to type'

    $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $state -Dark $false -Template $template
    try {
        Assert-Equal 'New combination' $ed.Window.FindName('HeadTitle').Text 'still a new one'
        $ticked = @($ed.Checks | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
        Assert-Equal @('LG ULTRAGEAR') $ticked 'the display that is on is ticked'
        Assert-Equal 'LG ULTRAGEAR' ([string]$ed.PrimaryBox.SelectedItem) 'and chosen for the taskbar'
    }
    finally { $ed.Window.Close(); $script:ActiveEditor = $null }
}

Test-Case 'badges: a badge names the display and says what it shows' {
    $m = New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug'
    $m.Primary = $true
    $text = Get-BadgeText -Display $m
    Assert-Equal 'LG ULTRAGEAR' $text.Title 'the name, large'
    Assert-Equal ('GSM5BB3' + $script:UiDot + '2560 x 1440 @ 144 Hz' + $script:UiDot + 'taskbar') $text.Line 'the ID, the mode and the taskbar under it'

    $win = New-DisplayBadge -Display $m -Rect ([pscustomobject]@{ Left = 1000; Top = 0; Right = 3560; Bottom = 1440 })
    try {
        Assert-Equal 2050 ([int]$win.Left) 'centred on that screen, not at the origin'
        Assert-True $win.Topmost 'on top of whatever is there'
        Assert-True (-not $win.ShowActivated) 'and it takes no focus from what a person is doing'
    }
    finally { $win.Close() }
}
