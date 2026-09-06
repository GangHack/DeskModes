# --- the mode editor's other settings ---------------------------------------
# Audio, commands and contrast used to live in settings.json and nowhere else: the window
# carried them across a Save and could neither show nor change them. They are edited here now,
# which means the window OWNS them — and everything that owns a mode-keyed setting has to move
# it on a rename, drop it with a deletion and give it an orphan row when its mode is gone.
#
# The device list is deliberately not fetched while a window is being built: enumerating audio
# endpoints goes out to COM, and these tests build editors by the dozen.

Write-Host ''
Write-Host "the mode editor's other settings" -ForegroundColor White

Test-Case 'audio settings: an empty device is not a setting' {
    $out = ConvertTo-AudioSettings -Audio ([ordered]@{ 'all' = 'ROG'; 'combo:Work' = '' })
    Assert-Equal 1 $out.Count 'only the one that names a device'
    Assert-Equal 'ROG' $out['all'] 'and it is what was written'
}

Test-Case 'audio settings: the name is trimmed on the way to the file' {
    # A person types into a box and leaves a space; the switch matches by substring, and a
    # trailing space would quietly match nothing at all.
    $out = ConvertTo-AudioSettings -Audio ([ordered]@{ 'all' = '  ROG  ' })
    Assert-Equal 'ROG' $out['all'] 'trimmed'
    Assert-Equal 0 (ConvertTo-AudioSettings -Audio ([ordered]@{ 'all' = '   ' })).Count 'spaces alone are no device'
}

Test-Case 'hook settings: a pair empty on both sides writes no key' {
    $hooks = [ordered]@{
        'all'        = [ordered]@{ before = ''; after = 'x.cmd' }
        'combo:Work' = [ordered]@{ before = ''; after = '' }
    }
    $out = ConvertTo-HookSettings -Hooks $hooks
    Assert-Equal 1 $out.Count 'only the one that has a command'
    Assert-Equal 'x.cmd' $out['all'].after 'and it kept its command'
}

Test-Case 'hook fingerprint: no command reads as empty, and the two sides are told apart' {
    Assert-Equal '' (Get-HookFingerprint -Before '' -After '') 'nothing set'
    Assert-Equal '' (Get-HookFingerprint -Before '  ' -After '  ') 'spaces are nothing set'
    Assert-True ((Get-HookFingerprint -Before 'a' -After '') -ne (Get-HookFingerprint -Before '' -After 'a')) `
        'before and after are not the same pair'
}

Test-Case 'level models: a whole section becomes models and comes back unchanged' {
    $section = [ordered]@{ 'all' = 80; 'combo:Work' = [ordered]@{ 'ULTRAFINE' = 25 }; 'solo:X' = 'junk' }
    $models = ConvertTo-LevelModels -Section $section
    Assert-Equal 2 $models.Count 'the unreadable one is not a setting'
    $back = ConvertFrom-LevelModels -Models $models
    Assert-Equal 80 $back['all'] 'the number stayed a number'
    Assert-Equal 25 $back['combo:Work']['ULTRAFINE'] 'and the dictionary a dictionary'
}

Test-Case 'level kinds: the form list names the setting it belongs to' {
    # "Leave the brightness alone" standing under the Contrast heading is the kind of thing
    # nobody notices until they have set the wrong one.
    Assert-Equal 'leave the brightness alone' (Get-LevelKindTitle -Kind 'none' -Noun 'brightness') 'brightness'
    Assert-Equal 'leave the contrast alone' (Get-LevelKindTitle -Kind 'none' -Noun 'contrast') 'contrast'
}

Test-Case 'mode editor: contrast is a card of its own, on every kind of mode' {
    foreach ($mode in @(
        [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
        [pscustomobject]@{ Key = 'solo:LG ULTRAGEAR'; Title = 'Only LG ULTRAGEAR'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
    )) {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
        try {
            Assert-Equal 3 $ed.Contrast.KindBox.Items.Count "three forms for $($mode.Key)"
            Assert-Equal 'none' ([string]$ed.Contrast.Model.Kind) 'nothing set until asked'
            Assert-True ($ed.Brightness.KindBox -ne $ed.Contrast.KindBox) 'and it is not the brightness card twice'
        }
        finally { $ed.Window.Close() }
    }
}

Test-Case 'mode editor: what is already set is what the editor opens on' {
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false `
                               -Contrast ([ordered]@{ 'all' = (ConvertTo-LevelModel 70) }) `
                               -Audio ([ordered]@{ 'all' = 'ROG' }) `
                               -Hooks ([ordered]@{ 'all' = [ordered]@{ before = 'b.cmd'; after = 'a.cmd' } })
    try {
        Assert-Equal 70 ([int]$ed.Contrast.Model.Value) 'the contrast came up'
        Assert-Equal 'one' ([string]$ed.Contrast.Model.Kind) 'in the shape it was written in'
        Assert-Equal 'ROG' ([string]$ed.AudioBox.Text) 'the device came up'
        Assert-Equal 'b.cmd' ([string]$ed.HookBeforeBox.Text) 'the before command came up'
        Assert-Equal 'a.cmd' ([string]$ed.HookAfterBox.Text) 'the after command came up'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'mode editor: building a window never asks the audio service' {
    # The list costs a walk out to COM. It is fetched when the dropdown is first opened and at no
    # other time - otherwise every click on Edit would pay for it, and these tests would talk to
    # the machine's real sound devices.
    function Get-AudioDevices { throw 'the editor must not enumerate devices while it is being built' }

    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
    try {
        Assert-Equal 0 $ed.AudioBox.Items.Count 'the list is empty until it is opened'
        Assert-Equal $false ([bool]$ed.AudioListed) 'and it knows it has not asked yet'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'mode editor: opening the list fills it once, and only once' {
    $script:AudioCalls = 0
    function Get-AudioDevices {
        $script:AudioCalls++
        return @([pscustomobject]@{ Id = '1'; Name = 'Speakers (Realtek)'; IsDefault = $true }
                 [pscustomobject]@{ Id = '2'; Name = 'ROG Swift'; IsDefault = $false })
    }

    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
    try {
        Add-AudioDeviceItems -Editor $ed
        Assert-Equal 2 $ed.AudioBox.Items.Count 'both devices are offered'
        Assert-Equal 'ROG Swift' ([string]$ed.AudioBox.Items[1]) 'by their full names'
        Add-AudioDeviceItems -Editor $ed
        Assert-Equal 1 $script:AudioCalls 'and the bus is walked once, not on every opening'
        Assert-Equal 2 $ed.AudioBox.Items.Count 'so the list is not doubled'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'mode editor: an audio service that will not answer costs the list, not the editor' {
    function Get-AudioDevices { throw 'the audio service is not running' }

    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
    try {
        $ed.AudioBox.Text = 'ROG'
        Add-AudioDeviceItems -Editor $ed
        Assert-Equal 0 $ed.AudioBox.Items.Count 'nothing to offer'
        Assert-Equal 'ROG' ([string]$ed.AudioBox.Text) 'but what was typed is untouched'
        $got = Read-ModeFromUi -Editor $ed
        Assert-True $got.Ok 'and Save still goes through'
        Assert-Equal 'ROG' ([string]$got.Mode.Audio) 'with the device that was typed'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'mode editor: all three land in the settings through a Save' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Dark $false `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Audio $ui.Audio -Hooks $ui.Hooks
        try {
            # The way a person does it: pick the form, move the slider, type the rest, Save.
            $ed.Contrast.KindBox.SelectedIndex = 1
            $ed.Contrast.OneSlider.Value = 65
            $ed.AudioBox.Text = 'ROG'
            $ed.HookBeforeBox.Text = 'before.cmd'
            $ed.HookAfterBox.Text = 'after.cmd'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 65 $updated.contrast['all'] 'the contrast landed'
        Assert-Equal 'ROG' $updated.audio['all'] 'the device landed'
        Assert-Equal 'before.cmd' $updated.hooks['all'].before 'the before command landed'
        Assert-Equal 'after.cmd' $updated.hooks['all'].after 'the after command landed'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: emptying a box clears the setting rather than leaving it' {
    # The whole point of putting these in a window: a setting you cannot turn off is not edited,
    # it is only added to.
    $settings = Get-DefaultSettings
    $settings.audio['all'] = 'ROG'
    $settings.hooks['all'] = [ordered]@{ before = ''; after = 'x.cmd' }
    $settings.contrast['all'] = 70
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Dark $false `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Audio $ui.Audio -Hooks $ui.Hooks
        try {
            Assert-Equal 'ROG' ([string]$ed.AudioBox.Text) 'it opened on what was set'
            $ed.AudioBox.Text = ''
            $ed.HookAfterBox.Text = ''
            $ed.Contrast.KindBox.SelectedIndex = 0
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ($updated.audio.Contains('all')) 'the device is gone from the file'
        Assert-Equal $false ($updated.hooks.Contains('all')) 'the command too'
        Assert-Equal $false ($updated.contrast.Contains('all')) 'and the contrast'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: a rename carries all of them, even the ones nobody touched' {
    # A property missing from an edit means "not touched" everywhere in this window. A rename
    # must not be the one place it means "throw it away" - that was a real defect: the editor's
    # answer was applied over a cleared key, and anything the answer did not mention was lost.
    $settings = Get-DefaultSettings
    $settings.combos['Movie'] = [ordered]@{ displays = @('ULTRAGEAR'); primary = '' }
    $settings.audio['combo:Movie'] = 'ROG'
    $settings.contrast['combo:Movie'] = 70
    $settings.hooks['combo:Movie'] = [ordered]@{ before = ''; after = 'x.cmd' }

    $ui = New-DialogUi -Settings $settings
    try {
        $mode = [pscustomobject]@{ Key = 'combo:Movie'; Title = 'Movie'; Kind = 'combo'; Available = $true }
        # An edit that mentions the name and nothing else, exactly as a caller that only renames
        # would hand it over.
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Cinema'; Patterns = @('LG ULTRAGEAR'); Primary = '' })

        Assert-Equal 'ROG' ([string]$ui.Audio['combo:Cinema']) 'the device moved with the name'
        Assert-Equal 70 ([int]$ui.Contrast['combo:Cinema'].Value) 'the contrast moved with it'
        Assert-Equal 'x.cmd' ([string]$ui.Hooks['combo:Cinema'].after) 'and the command'
        Assert-True (-not $ui.Audio.Contains('combo:Movie')) 'nothing left under the old name'

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'ROG' $updated.audio['combo:Cinema'] 'and that is what reaches the file'
        Assert-Equal 70 $updated.contrast['combo:Cinema'] 'contrast too'
        Assert-Equal 'x.cmd' $updated.hooks['combo:Cinema'].after 'command too'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: deleting a combination takes all of them with it' {
    $settings = Get-DefaultSettings
    $settings.combos['Movie'] = [ordered]@{ displays = @('ULTRAGEAR'); primary = '' }
    $settings.audio['combo:Movie'] = 'ROG'
    $settings.audio['all'] = 'SPEAKERS'
    $settings.contrast['combo:Movie'] = 70
    $settings.hooks['combo:Movie'] = [ordered]@{ before = ''; after = 'x.cmd' }

    $ui = New-DialogUi -Settings $settings
    try {
        Remove-UiCombo -Ui $ui -Combo $ui.Combos[0]
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ($updated.audio.Contains('combo:Movie')) 'its device died with it'
        Assert-Equal $false ($updated.contrast.Contains('combo:Movie')) 'its contrast too'
        Assert-Equal $false ($updated.hooks.Contains('combo:Movie')) 'its command too'
        Assert-Equal 'SPEAKERS' $updated.audio['all'] 'and nobody else was touched'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a device set for a mode that no longer exists gets its own row' {
    # Before there was a window for this, such an entry was invisible and unremovable: no mode
    # owned it, and nothing in the window looked at the audio map at all.
    $settings = Get-DefaultSettings
    $settings.audio['solo:GONE MONITOR'] = 'ROG'
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal 4 $ui.ModesPanel.Children.Count 'two displays, all, and the orphan'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'ROG' $updated.audio['solo:GONE MONITOR'] 'untouched by a plain Save'

        Remove-UiOrphan -Ui $ui -Key 'solo:GONE MONITOR'
        Assert-Equal 3 $ui.ModesPanel.Children.Count 'the row went away'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ($updated.audio.Contains('solo:GONE MONITOR')) 'and so did the setting'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a command left over from a departed mode gets a row too' {
    $settings = Get-DefaultSettings
    $settings.hooks['combo:Gone'] = [ordered]@{ before = ''; after = 'x.cmd' }
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal 4 $ui.ModesPanel.Children.Count 'the command without a mode is listed'
    }
    finally { $ui.Window.Close() }
}

Test-Case "dialog: a mode's row says which of its settings are set" {
    # A setting hidden behind an Edit button is invisible until every mode has been opened in
    # turn. One word each, and no device name: the row must not wrap.
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = 80
    $settings.contrast['all'] = 65
    $settings.audio['all'] = 'ROG'
    $settings.hooks['all'] = [ordered]@{ before = ''; after = 'x.cmd' }
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = @($ui.Modes | Where-Object { $_.Key -eq 'all' })[0]
        $sub = Get-ModeRowSubtitle -Ui $ui -Mode $mode
        Assert-True ($sub -like '*brightness 80*') 'the brightness is named'
        Assert-True ($sub -like '*contrast 65*') 'the contrast is named'
        Assert-True ($sub -like '*audio*') 'the sound is named'
        Assert-True ($sub -like '*command*') 'the command is named'
        Assert-True ($sub -notlike '*ROG*') "but not the device's name - that is what makes the row wrap"
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: contrast per display builds a row for each, like the brightness does' {
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
    try {
        $ed.Contrast.KindBox.SelectedIndex = 2
        Assert-Equal 2 $ed.Contrast.RowsPanel.Children.Count 'a row per display'
        Assert-Equal 0 $ed.Brightness.RowsPanel.Children.Count 'and the brightness card is left alone'
        $names = @($ed.Contrast.RowsPanel.Children | ForEach-Object { [string]$_.Children[0].Content })
        Assert-Equal @('LG ULTRAGEAR', 'LG ULTRAFINE') $names 'named after the displays'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'mode editor: the two cards do not read each other' {
    # They are one set of functions over two group objects now. The failure that would make is a
    # slider moving both settings at once, and it would be found by a person and not by a test.
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
    try {
        $ed.Brightness.KindBox.SelectedIndex = 1
        $ed.Brightness.OneSlider.Value = 30
        $ed.Contrast.KindBox.SelectedIndex = 1
        $ed.Contrast.OneSlider.Value = 90
        Assert-Equal 30 ([int]$ed.Brightness.Model.Value) 'the brightness kept its own number'
        Assert-Equal 90 ([int]$ed.Contrast.Model.Value) 'and the contrast its own'

        $got = Read-ModeFromUi -Editor $ed
        Assert-Equal 30 ([int]$got.Mode.Level.Value) 'and Save tells them apart'
        Assert-Equal 90 ([int]$got.Mode.Contrast.Value) 'both ways round'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'orphan: a new combination is shown the device and the command it inherits' {
    # The key `combo:Movie` still carries settings from the name's earlier life. They have to be
    # VISIBLE, or an empty box would silently erase something the person never saw.
    $settings = Get-DefaultSettings
    $settings.audio['combo:Movie'] = 'ROG'
    $settings.hooks['combo:Movie'] = [ordered]@{ before = ''; after = 'x.cmd' }
    $settings.contrast['combo:Movie'] = 70

    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State -Dark $false `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Audio $ui.Audio -Hooks $ui.Hooks
        try {
            Assert-Equal '' ([string]$ed.AudioBox.Text) 'a new combination starts empty'
            $ed.NameBox.Text = 'Movie'
            Assert-Equal 'ROG' ([string]$ed.AudioBox.Text) 'and typing the name brings the device back'
            Assert-Equal 'x.cmd' ([string]$ed.HookAfterBox.Text) 'the command with it'
            Assert-Equal 70 ([int]$ed.Contrast.Model.Value) 'and the contrast'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: what the person typed himself beats what the name would bring' {
    $settings = Get-DefaultSettings
    $settings.audio['combo:Movie'] = 'ROG'
    $settings.hooks['combo:Movie'] = [ordered]@{ before = ''; after = 'x.cmd' }

    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State -Dark $false `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Audio $ui.Audio -Hooks $ui.Hooks
        try {
            # His own device and his own command first, and only then the name.
            $ed.AudioBox.Text = 'SPEAKERS'
            $ed.HookAfterBox.Text = 'mine.cmd'
            $ed.NameBox.Text = 'Movie'
            Assert-Equal 'SPEAKERS' ([string]$ed.AudioBox.Text) 'his device stayed'
            Assert-Equal 'mine.cmd' ([string]$ed.HookAfterBox.Text) 'and his command'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: a plain mode opens with the hardware half folded away' {
    # What a mode IS stays in sight; what it does to the hardware is four settings that all mean
    # "leave it alone" until asked, and unfolded they made the editor a window and a half tall.
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
    try {
        Assert-Equal 'Collapsed' ([string]$ed.MorePanel.Visibility) 'nothing set, so nothing to show'
        Assert-True ([string]$ed.MoreBtn.Content -like '*Brightness, sound and commands*') `
            'and the caption says what is behind it'
        Assert-Equal $false ([bool]$ed.MoreOpen) 'the editor knows it is shut'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'mode editor: the fold opens by itself for a mode that has something set' {
    # A setting folded out of sight is invisible, and Save reads those fields - an empty one
    # erases. So anything already set has to be on screen without being hunted for.
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    foreach ($given in @(
        @{ What = 'a brightness'; Extra = @{ Levels = ([ordered]@{ 'all' = (ConvertTo-LevelModel 80) }) } }
        @{ What = 'a contrast';   Extra = @{ Contrast = ([ordered]@{ 'all' = (ConvertTo-LevelModel 70) }) } }
        @{ What = 'a device';     Extra = @{ Audio = ([ordered]@{ 'all' = 'ROG' }) } }
        @{ What = 'a command';    Extra = @{ Hooks = ([ordered]@{ 'all' = [ordered]@{ before = ''; after = 'x.cmd' } }) } }
    )) {
        # Splatted from a variable, which is the only shape that splats: @($given.Extra) builds an
        # array and hands it over as one positional argument, so nothing arrives at all.
        $extra = $given.Extra
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false @extra
        try {
            Assert-Equal 'Visible' ([string]$ed.MorePanel.Visibility) "$($given.What) opens the fold"
        }
        finally { $ed.Window.Close() }
    }
}

Test-Case 'mode editor: inheriting a setting from a typed name opens the fold too' {
    # The orphan case. Inheriting a command out of sight would be worse than not inheriting it:
    # the person never sees it, and their empty box erases it on Save.
    $settings = Get-DefaultSettings
    $settings.audio['combo:Movie'] = 'ROG'
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State -Dark $false `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Audio $ui.Audio -Hooks $ui.Hooks
        try {
            Assert-Equal 'Collapsed' ([string]$ed.MorePanel.Visibility) 'a new combination starts folded'
            $ed.NameBox.Text = 'Movie'
            Assert-Equal 'ROG' ([string]$ed.AudioBox.Text) 'the device came back with the name'
            Assert-Equal 'Visible' ([string]$ed.MorePanel.Visibility) 'and the fold opened so it can be seen'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: shutting the fold by hand outranks opening it by itself' {
    # Without this, shutting it while a brightness is set would spring it open again on the very
    # next keystroke in the name box.
    $combo = [pscustomobject]@{ Name = 'Work'; Patterns = @('LG ULTRAFINE'); Primary = '' }
    $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $script:DlgState -Dark $false `
                               -Levels ([ordered]@{ 'combo:Work' = (ConvertTo-LevelModel 80) })
    try {
        Assert-Equal 'Visible' ([string]$ed.MorePanel.Visibility) 'the brightness opened it'
        $ed.MoreTouched = $true
        $ed.MoreOpen = $false
        Set-EditorMoreVisible -Editor $ed -Open $false
        $ed.NameBox.Text = 'Work rearranged'
        Assert-Equal 'Collapsed' ([string]$ed.MorePanel.Visibility) 'and it stays shut while the name is typed'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'mode editor: a folded setting is still read on Save' {
    # Folded away is not switched off.
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Dark $false `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Audio $ui.Audio -Hooks $ui.Hooks
        try {
            Assert-Equal 'Collapsed' ([string]$ed.MorePanel.Visibility) 'still folded'
            $ed.AudioBox.Text = 'ROG'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'ROG' $updated.audio['all'] 'and what was typed behind the fold was saved'
    }
    finally { $ui.Window.Close() }
}

Test-Case "dialog: a display's row is one line until it has something set on it" {
    # The kind of a mode is already in its title, so the caption is only ever about settings.
    # Two lines per display, on a desk of three or four, is what pushed this window into a
    # scrollbar.
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = @($ui.Modes | Where-Object { $_.Kind -eq 'solo' })[0]
        Assert-Equal '' (Get-ModeRowSubtitle -Ui $ui -Mode $mode) 'nothing set, so nothing to say'
    }
    finally { $ui.Window.Close() }

    $settings.brightness[[string]@(Get-DialogModes -State $script:DlgState -Settings $settings |
                                   Where-Object { $_.Kind -eq 'solo' })[0].Key] = 55
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = @($ui.Modes | Where-Object { $_.Kind -eq 'solo' })[0]
        Assert-Equal 'brightness 55' (Get-ModeRowSubtitle -Ui $ui -Mode $mode) 'and the setting alone when there is one'
    }
    finally { $ui.Window.Close() }
}

# --- the monitor's picture preset --------------------------------------------
# A row per display with one button. What is remembered is a register and a number read off the
# monitor at that moment; nothing here knows a preset's NAME, and nothing asks the bus while a
# window is merely being built - these tests build editors by the dozen and no monitor is on.

Test-Case 'picture: building an editor asks no monitor anything' {
    $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $script:DlgState -Dark $false
    try {
        Assert-Equal 0 $ed.Picture.Count 'nothing is remembered for a mode that has nothing'
        Assert-Equal '' ([string]$ed.PictureNote.Text) 'and nothing was said about the bus'
    }
    finally { $ed.Window.Close(); $script:ActiveEditor = $null }
}

Test-Case 'picture: a row is drawn for every display of the mode, and says what it knows' {
    # "All displays" is the mode with both of the fake desk's monitors in it.
    $picture = [ordered]@{ 'all' = [ordered]@{ 'LG ULTRAFINE' = '0x15:45' } }
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Picture $picture -Dark $false
    try {
        Assert-Equal 2 $ed.PicturePanel.Children.Count 'a row for each display of the mode'
        $row = @($ed.PicturePanel.Children | Where-Object { [string]$_.Children[0].Children[0].Text -eq 'LG ULTRAFINE' })[0]
        Assert-Equal 'Remembered' ([string]$row.Children[0].Children[1].Text) 'it knows a preset'
        # The number is on hover and in settings.json, never in the row itself.
        Assert-Equal '0x15:45' ([string]$row.Children[0].Children[1].ToolTip) 'with the number behind it'
        Assert-Equal 'Update' ([string]$row.Children[1].Children[0].Content) 'the button offers to replace it'
        Assert-Equal 2 $row.Children[1].Children.Count 'and there is a way to forget it'

        $other = @($ed.PicturePanel.Children | Where-Object { [string]$_.Children[0].Children[0].Text -eq 'LG ULTRAGEAR' })[0]
        Assert-Equal 'Not remembered' ([string]$other.Children[0].Children[1].Text) 'the other display knows none'
        Assert-Equal 'Remember' ([string]$other.Children[1].Children[0].Content) 'and is only offered the one button'
    }
    finally { $ed.Window.Close(); $script:ActiveEditor = $null }
}

Test-Case 'picture: what is remembered lands in the settings, and only for displays the mode has' {
    $settings = New-TestSettings -Combos @{ 'Work' = @('LG ULTRAFINE') }
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = @($ui.Modes | Where-Object { $_.Key -eq 'combo:Work' } | Select-Object -First 1)[0]
        $combo = Get-UiCombo -Ui $ui -Key 'combo:Work'
        $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $script:DlgState -Dark $false
        try {
            # Remembered by hand, the way the button would have written it - the bus is not asked
            # in a test, and what is under test is what happens to the answer afterwards.
            $ed.Picture['LG ULTRAFINE'] = '0x15:45'
            $ed.Picture['LG ULTRAGEAR'] = '0xDC:6'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'the edit is accepted'
            Assert-Equal 1 $got.Mode.Picture.Count 'only the display the combination actually has'
            Assert-Equal '0x15:45' ([string]$got.Mode.Picture['LG ULTRAFINE']) 'with its own number'

            Set-UiMode -Ui $ui -Mode $mode -Combo $combo -Edited $got.Mode
            $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
            Assert-Equal '0x15:45' ([string]$updated.picture['combo:Work']['LG ULTRAFINE']) 'and it reaches settings.json'
        }
        finally { $ed.Window.Close(); $script:ActiveEditor = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'picture: a preset written as a piece of a name is shown and kept' {
    # settings.json keys a preset by A PIECE of a display's name - that is what the switch matches
    # by, and what the CLI tells a person to write. Looked up by the whole label it was found by
    # nobody: the row said "Not remembered" and Save handed back a map without it, so opening the
    # editor and pressing Save was enough to lose it.
    $settings = New-TestSettings -Combos @{ 'Work' = @('LG ULTRAFINE') }
    $settings.picture = [ordered]@{ 'combo:Work' = [ordered]@{ 'ULTRAFINE' = '0x15:45' } }
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = @($ui.Modes | Where-Object { $_.Key -eq 'combo:Work' } | Select-Object -First 1)[0]
        $combo = Get-UiCombo -Ui $ui -Key 'combo:Work'
        $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $script:DlgState `
                                   -Picture $ui.Picture -Dark $false
        try {
            Assert-Equal 'ULTRAFINE' (Get-PictureKeyFor -Editor $ed -Name 'LG ULTRAFINE') 'the row finds it'
            Assert-Equal 'Remembered' (Get-PictureRowText -Setting $ed.Picture['ULTRAFINE']) 'and says so'

            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'the edit is accepted'
            Assert-Equal '0x15:45' ([string]$got.Mode.Picture['ULTRAFINE']) 'it survives, under the key it was written with'

            Set-UiMode -Ui $ui -Mode $mode -Combo $combo -Edited $got.Mode
            $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
            Assert-Equal '0x15:45' ([string]$updated.picture['combo:Work']['ULTRAFINE']) 'and it is still in the file'
        }
        finally { $ed.Window.Close(); $script:ActiveEditor = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'picture: a preset written by Monitor ID survives the editor and settings Save' {
    $settings = New-TestSettings
    $settings.picture = [ordered]@{ 'all' = [ordered]@{ 'GSM5BB3' = '0x15:45' } }
    $ui = New-DialogUi -Settings $settings -State $script:DlgState
    try {
        $mode = @($ui.Modes | Where-Object { $_.Key -eq 'all' })[0]
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState `
                                   -Picture $ui.Picture -Dark $false
        try {
            Assert-Equal 'GSM5BB3' (Get-PictureKeyFor -Editor $ed -Name 'LG ULTRAGEAR') 'the row finds the Monitor ID'
            $got = Read-ModeFromUi -Editor $ed
            Assert-Equal '0x15:45' ([string]$got.Mode.Picture['GSM5BB3']) 'the editor keeps its key and value'

            Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited $got.Mode
            $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
            Assert-Equal '0x15:45' ([string]$updated.picture['all']['GSM5BB3']) 'the settings Save keeps it too'
        }
        finally { $ed.Window.Close(); $script:ActiveEditor = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'picture: a rename carries the presets, and a deletion takes them away' {
    $settings = New-TestSettings -Combos @{ 'Work' = @('LG ULTRAFINE') }
    $settings.picture = [ordered]@{ 'combo:Work' = [ordered]@{ 'LG ULTRAFINE' = '0x15:45' } }
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-True $ui.Picture.Contains('combo:Work') 'the window read it in'
        Move-UiModeKey -Ui $ui -From 'combo:Work' -To 'combo:Evening'
        Assert-True $ui.Picture.Contains('combo:Evening') 'a rename carries it'
        Assert-Equal $false $ui.Picture.Contains('combo:Work') 'and leaves nothing behind'

        Remove-UiModeKey -Ui $ui -Key 'combo:Evening'
        Assert-Equal $false $ui.Picture.Contains('combo:Evening') 'a deletion takes it with it'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'picture: a display that is off keeps the preset remembered for it' {
    # The mode you open while the monitor is asleep is exactly the mode that turns it on. Its
    # display is Disconnected, Get-ModeMembers drops those, and the card is handed back WHOLE on
    # Save - so without Get-EditorPictureNames an untouched Save erased the preset it was opened
    # to look at. Brightness never had this: Get-LevelRowNames keeps a name its map holds.
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'path-asus' $false $true)
    )
    $settings = New-TestSettings
    $settings.picture = [ordered]@{ 'solo:XG27AQDMGR' = [ordered]@{ 'XG27AQDMGR' = '0xDC:6' } }
    $ui = New-DialogUi -Settings $settings -State $state
    try {
        $mode = @($ui.Modes | Where-Object { $_.Key -eq 'solo:XG27AQDMGR' })[0]
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $state -Picture $ui.Picture -Dark $false
        try {
            Assert-Equal 1 $ed.PicturePanel.Children.Count 'the display that is away still gets its row'
            $got = Read-ModeFromUi -Editor $ed
            Assert-Equal '0xDC:6' ([string]$got.Mode.Picture['XG27AQDMGR']) 'and an untouched Save hands it back'

            Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited $got.Mode
            Assert-Equal '0xDC:6' ([string]$ui.Picture['solo:XG27AQDMGR']['XG27AQDMGR']) 'so the window keeps it'
        }
        finally { $ed.Window.Close(); $script:ActiveEditor = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'picture: a typed name inherits the presets standing under its key' {
    # The same rule the shortcut, the levels, the device and the commands live by: a card the
    # person never saw must not erase what the name it names already owns.
    $settings = New-TestSettings
    $settings.picture = [ordered]@{ 'combo:Games' = [ordered]@{ 'LG ULTRAFINE' = '0x15:45' } }
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $script:DlgState `
                                   -Picture $ui.Picture -Dark $false
        try {
            Assert-Equal 0 $ed.Picture.Count 'a new combination starts with nothing remembered'
            $ed.NameBox.Text = 'Games'
            Sync-EditorInheritance -Editor $ed
            Assert-Equal '0x15:45' ([string]$ed.Picture['LG ULTRAFINE']) 'the name brings the preset with it'

            foreach ($cb in $ed.Checks) { if ([string]$cb.Tag -eq 'LG ULTRAFINE') { $cb.IsChecked = $true } }
            $got = Read-ModeFromUi -Editor $ed
            Set-UiMode -Ui $ui -Mode $null -Combo $null -Edited $got.Mode
            Assert-Equal '0x15:45' ([string]$ui.Picture['combo:Games']['LG ULTRAFINE']) 'and Save does not erase it'
        }
        finally { $ed.Window.Close(); $script:ActiveEditor = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'picture fingerprint: nothing remembered reads as empty, and the order does not matter' {
    Assert-Equal '' (Get-PictureFingerprint -Map ([ordered]@{})) 'nothing set'
    $one = Get-PictureFingerprint -Map ([ordered]@{ 'A' = '0x15:1'; 'B' = '0xDC:6' })
    $two = Get-PictureFingerprint -Map ([ordered]@{ 'B' = '0xDC:6'; 'A' = '0x15:1' })
    Assert-Equal $one $two 'the order the rows were pressed in is not part of the answer'
    Assert-True ($one -ne (Get-PictureFingerprint -Map ([ordered]@{ 'A' = '0x15:2'; 'B' = '0xDC:6' }))) `
                'a different number is a different card'
}

Test-Case 'picture: an unreadable entry in the file is dropped rather than written back out' {
    # settings.json is edited by hand. A line the window cannot read must not be carried through a
    # Save as though somebody had meant it - and must not reach a monitor either.
    $settings = New-TestSettings -Combos @{ 'Work' = @('LG ULTRAFINE') }
    $settings.picture = [ordered]@{ 'combo:Work' = [ordered]@{ 'LG ULTRAFINE' = 'reader'; 'LG ULTRAGEAR' = '0x15:6' } }
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal 1 $ui.Picture['combo:Work'].Count 'only the one that parses came in'
        Assert-Equal '0x15:6' ([string]$ui.Picture['combo:Work']['LG ULTRAGEAR']) 'and it is the right one'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'picture: a mode row says a preset is set on it' {
    $settings = New-TestSettings -Combos @{ 'Work' = @('LG ULTRAFINE') }
    $settings.picture = [ordered]@{ 'combo:Work' = [ordered]@{ 'LG ULTRAFINE' = '0x15:45' } }
    $ui = New-DialogUi -Settings $settings
    try {
        # "picture" and not "picture preset": this caption is the one thing on a mode's row that
        # gets trimmed, and "preset" is eight characters naming the section it came from.
        Assert-True ((Get-ModeRowSubtitle -Ui $ui -Mode ([pscustomobject]@{ Key = 'combo:Work'; Kind = 'combo' })) -like '*picture*') `
                    'a setting behind an Edit button is not invisible'
    }
    finally { $ui.Window.Close() }
}
