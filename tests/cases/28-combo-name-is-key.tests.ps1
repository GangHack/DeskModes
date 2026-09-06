# --- a combo's name IS its key ----------------------------------------------
# A combo can be wiped out of the file by hand while its shortcut, brightness, audio and commands are
# left behind: they sit under the key `combo:<name>`, and the window shows them as an orphan row.
# Creating a combo with the same name means claiming that very key. The audio and the commands go to it
# in any case, so the shortcut and the brightness have both to go to it and to BE VISIBLE: empty editor
# fields used to erase two settings out of four silently, and a saved orphan's shortcut was counted as
# somebody else's on top of that.

Write-Host ''
Write-Host 'a name that was already used once' -ForegroundColor White

# Orphan settings: there is no Movie combo, but everything that was tied to it is there.
function New-OrphanSettings {
    $s = Get-DefaultSettings
    $s.brightness['combo:Movie'] = 55
    $s.hotkeys['combo:Movie'] = 'Ctrl+Alt+F4'
    $s.audio['combo:Movie'] = 'ROG'
    return $s
}

Test-Case 'orphan: a new combination with that name is shown what it inherits' {
    $settings = New-OrphanSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Audio $ui.Audio -Hooks $ui.Hooks -Dark $false
        try {
            Assert-Equal (Get-NoHotkeyText) $ed.HotkeyBox.Text 'nothing to inherit until there is a name'
            Assert-Equal 'none' ([string]$ed.Brightness.Model.Kind) 'and no brightness either'

            $ed.NameBox.Text = 'Movie'
            Assert-Equal 'Ctrl+Alt+F4' $ed.HotkeyBox.Text 'the shortcut left under that name is shown, not hidden'
            Assert-Equal 55 ([int]$ed.Brightness.Model.Value) 'and so is the brightness'
            Assert-Equal 'one' ([string]$ed.Brightness.Model.Kind) 'in the shape it was written in'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: its own shortcut is not somebody else - the editor takes it' {
    # This is how it used to break: an orphan's shortcut was counted as taken, and the editor referred to
    # a mode that is not in the window and cannot be opened. The only way out was to delete the orphan row.
    $settings = New-OrphanSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Audio $ui.Audio -Hooks $ui.Hooks -Dark $false
        try {
            $ed.NameBox.Text = 'Movie'
            $ed.Checks[0].IsChecked = $true
            $ed.HotkeyBox.Text = 'Ctrl+Alt+F4'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'the shortcut of the name it takes over is its own'
            Assert-Equal 'Ctrl+Alt+F4' $got.Mode.Hotkey 'and comes back as the mode shortcut'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: all four settings come back, none of them quietly killed' {
    $settings = New-OrphanSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Audio $ui.Audio -Hooks $ui.Hooks -Dark $false
        try {
            $ed.NameBox.Text = 'Movie'
            $ed.Checks[0].IsChecked = $true
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Set-UiMode -Ui $ui -Mode $null -Combo $null -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'Ctrl+Alt+F4' $updated.hotkeys['combo:Movie'] 'the shortcut survived'
        Assert-Equal 55 $updated.brightness['combo:Movie'] 'the brightness survived'
        Assert-Equal 'ROG' $updated.audio['combo:Movie'] 'the sound was never in danger'
        Assert-True ($updated.combos.Contains('Movie')) 'and the combination itself is there'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: what the person set himself beats what the name would bring' {
    $settings = New-OrphanSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Audio $ui.Audio -Hooks $ui.Hooks -Dark $false
        try {
            # First its own shortcut and its own brightness, and only then the name.
            $ed.HotkeyBox.Text = 'Ctrl+Alt+F7'
            $ed.Brightness.KindBox.SelectedIndex = 1
            $ed.Brightness.OneSlider.Value = 20
            $ed.NameBox.Text = 'Movie'
            Assert-Equal 'Ctrl+Alt+F7' $ed.HotkeyBox.Text 'his shortcut stayed'
            Assert-Equal 20 ([int]$ed.Brightness.Model.Value) 'and his brightness too'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: renaming a combination onto that name does not wipe the shortcut' {
    # The same path from the other side: the combo has no shortcut of its own, while the name it was
    # renamed to does. An empty editor field must not clear it.
    $settings = New-OrphanSettings
    $settings.hotkeys.Remove('combo:Movie')
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.hotkeys['combo:Movie'] = 'Ctrl+Alt+F4'
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        $ed = New-ModeEditorWindow -Mode $mode -Combo $ui.Combos[0] -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Audio $ui.Audio -Hooks $ui.Hooks -Dark $false
        try {
            Assert-Equal (Get-NoHotkeyText) $ed.HotkeyBox.Text 'Work has no shortcut of its own'
            $ed.NameBox.Text = 'Movie'
            Assert-Equal 'Ctrl+Alt+F4' $ed.HotkeyBox.Text 'the shortcut of the name it moves into is shown'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'Ctrl+Alt+F4' $updated.hotkeys['combo:Movie'] 'and it is still there after Save'
        Assert-True (-not $updated.hotkeys.Contains('combo:Work')) 'nothing left under the old name'
    }
    finally { $ui.Window.Close() }
}
