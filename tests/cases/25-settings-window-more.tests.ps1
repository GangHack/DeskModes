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
        # Through the mode editor, as in the live window: everything keyed to the mode moves at
        # once, along with the edit, and the Save only writes down where it ended up.
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

# Dropping a key goes through a pure function, separately from the window: one of them serves
# every mode-keyed map, and testing it by building a WPF tree is both dearer and murkier. There is
# no rename map here any more - the rename happens in Move-UiModeKey, where the name is changed.

Test-Case 'mode keys: an entry that stays keeps its place in the file' {
    $source = [ordered]@{ 'solo:A' = 10; 'combo:Work' = 80; 'all' = 55 }
    $moved = Move-ModeKeyedEntries -Source $source
    Assert-Equal @('solo:A', 'combo:Work', 'all') @($moved.Keys) 'order untouched'
    Assert-Equal 80 $moved['combo:Work'] 'with its value'
}

Test-Case 'mode keys: a removed combination takes its entry with it' {
    $source = [ordered]@{ 'combo:Work' = 80; 'all' = 55 }
    $moved = Move-ModeKeyedEntries -Source $source -Gone @('combo:Work')
    Assert-Equal @('all') @($moved.Keys) 'the ghost setting is gone'
}

Test-Case 'dialog: deleting a renamed combination leaves the one that took its old name alone' {
    # "Work" is renamed to "Gaming", and a NEW combination claims the freed name. Deleting
    # "Gaming" used to clear the name it had in the file as well - which by then belonged to
    # somebody else, and the new "Work" lost every setting it had while staying in the list.
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.brightness['combo:Work'] = 55
    $ui = New-DialogUi -Settings $settings
    try {
        Set-UiMode -Ui $ui -Mode ([pscustomobject]@{ Key = 'combo:Work'; Kind = 'combo' }) `
                   -Combo $ui.Combos[0] `
                   -Edited ([pscustomobject]@{ Name = 'Gaming'; Patterns = @('LG ULTRAGEAR'); Primary = '' })
        Assert-Equal 55 ([int]$ui.Levels['combo:Gaming'].Value) 'the rename took the brightness along'

        Set-UiMode -Ui $ui -Mode $null -Combo $null `
                   -Edited ([pscustomobject]@{ Name = 'Work'; Patterns = @('LG ULTRAFINE'); Primary = ''
                                               Level = (ConvertTo-LevelModel 30) })
        Assert-Equal 30 ([int]$ui.Levels['combo:Work'].Value) 'the new combination has a brightness of its own'

        $gaming = @($ui.Combos | Where-Object { $_.Name -eq 'Gaming' })[0]
        Remove-UiCombo -Ui $ui -Combo $gaming
        Assert-Equal 30 ([int]$ui.Levels['combo:Work'].Value) 'and it is still there after the other one goes'
        Assert-True (-not $ui.Levels.Contains('combo:Gaming')) 'while the deleted one took its own'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: a mode that is gone drops the rule, and only clears a way back' {
    # The window owns the rules now, so this happens where the combination is deleted rather
    # than in a rename map at Save time. An empty "go back to" is legal - it means "wherever
    # the desk was" - but a rule with nowhere to GO is no longer a rule.
    $settings = New-TestSettings -Combos @{ Work = @('LG ULTRAGEAR') }
    $settings.rules = @(
        [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'combo:Work'; back = ''; enabled = $true }
        [ordered]@{ when = 'idle'; process = ''; minutes = 20; mode = 'all'; back = 'combo:Work'; enabled = $true }
    )
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal 2 @($ui.Rules).Count 'both rules came up'
        Remove-UiCombo -Ui $ui -Combo $ui.Combos[0]
        Assert-Equal 1 @($ui.Rules).Count 'the rule with nowhere to go is dropped'
        Assert-Equal 'all' ([string]$ui.Rules[0]['mode']) 'the other one stays'
        Assert-Equal '' ([string]$ui.Rules[0]['back']) 'with an empty way back - that is legal'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: they arrive as objects out of the file and are brought to one shape' {
    # Out of ConvertFrom-Json the rules arrive as PSCustomObjects, and half their fields may be
    # missing. The tray reads them every fifteen seconds and cannot sort that out there.
    $settings = Get-DefaultSettings
    $settings.rules = @([pscustomobject]@{ when = 'process'; process = 'cs2'; mode = 'combo:Work' })
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal 1 @($ui.Rules).Count 'kept'
        Assert-Equal 'cs2' ([string]$ui.Rules[0]['process']) 'the rest of the rule came along'
        Assert-True ([bool]$ui.Rules[0]['enabled']) 'a rule with no "enabled" is on'
        Assert-Equal 0 ([int]$ui.Rules[0]['minutes']) 'and a missing number is zero, not absent'
    }
    finally { $ui.Window.Close() }
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
        # The window works on its own copies from the moment it opens: editing a rule here must
        # not reach the list the tray is checking every fifteen seconds.
        $ui.Rules[0]['process'] = 'dota2'
        Assert-Equal 'cs2' ([string]$settings.rules[0].process) 'the tray still sees what it had'

        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Office'; Patterns = @('LG ULTRAGEAR'); Primary = '' })
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'combo:Office' ([string]$updated.rules[0].mode) 'the copy moved'
        Assert-Equal 'combo:Work' ([string]$settings.rules[0].mode) 'the original did not'
    }
    finally { $ui.Window.Close() }
}


# --- the wheel over a drop-down ---------------------------------------------
# The turn of the wheel a ComboBox used to take for itself. Raised by hand rather than by a
# mouse: the Preview is what the guard hangs on, and RaiseEvent reaches it on a window that
# was never shown.
function Send-WheelTurn {
    param($Element, [int]$Delta = -120)

    $turn = New-Object System.Windows.Input.MouseWheelEventArgs(
        [System.Windows.Input.Mouse]::PrimaryDevice, 0, $Delta)
    $turn.RoutedEvent = [System.Windows.UIElement]::PreviewMouseWheelEvent
    $Element.RaiseEvent($turn)
    return [bool]$turn.Handled
}

# The other branch - a list that is OPEN keeps the wheel for walking itself - cannot be
# reached from here: WPF coerces IsDropDownOpen back to false on a control that was never
# loaded, so a window nobody showed has no open list to turn the wheel over.
# The page the box stands on: the wheel is only given back if this is what it reaches.
function Get-UiScrollHost {
    param($Element)

    $node = $Element
    while ($node -and $node -isnot [System.Windows.Controls.ScrollViewer]) { $node = $node.Parent }
    return $node
}

Test-Case 'dialog: a shut drop-down hands the wheel to the page instead of changing the pick' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $box = $ui.SleepBox
        $was = [int]$box.SelectedIndex

        # The count lives on the ScrollViewer's own Tag: a handler that closed over a counter
        # of ours would not see it (see the note on .GetNewClosure() in SettingsDialog.ps1),
        # and the sender is the one thing a flat block does get.
        $page = Get-UiScrollHost -Element $box
        Assert-True ($null -ne $page) 'the box stands on a page that scrolls'
        $page.Tag = 0
        # handledEventsToo: the page marks the turn handled the moment it scrolls, and this
        # has to count the turn either way.
        $page.AddHandler([System.Windows.UIElement]::MouseWheelEvent,
            [System.Windows.Input.MouseWheelEventHandler]{ param($sender, $e) $sender.Tag = [int]$sender.Tag + 1 },
            $true)

        Assert-True (Send-WheelTurn -Element $box) 'the box took the turn off WPF'
        Assert-Equal $was ([int]$box.SelectedIndex) 'and the pick is the one that was made'
        Assert-Equal 1 ([int]$page.Tag) 'while the page got the turn to scroll with'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: every drop-down of every window is guarded, not just the ones remembered' {
    # The count comes out of the markup itself: a box added to any of the four windows later
    # is guarded by the walk in Convert-UiXaml, and this is what says the walk still reaches it.
    foreach ($markup in @(
        @{ Name = 'settings';    Xaml = $script:SettingsWindowXaml },
        @{ Name = 'mode editor'; Xaml = $script:ModeEditorXaml },
        @{ Name = 'rule editor'; Xaml = $script:RuleEditorXaml },
        @{ Name = 'timer';       Xaml = $script:TimerWindowXaml })) {

        $declared = @([regex]::Matches([string]$markup.Xaml, '<ComboBox ')).Count
        $win = Convert-UiXaml -Xaml ([string]$markup.Xaml) -Palette (Get-UiPalette -Dark $false)
        try {
            $found = @(Get-UiDropDowns -Root $win)
            Assert-Equal $declared $found.Count ('every box of the ' + $markup.Name + ' window was found')
            foreach ($box in $found) {
                Assert-True (Send-WheelTurn -Element $box) ('a box of the ' + $markup.Name + ' window is guarded')
            }
        }
        finally { $win.Close() }
    }
}
