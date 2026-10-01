# --- rules in the Settings window -------------------------------------------
# The rules were the last thing in settings.json with no window at all: you could see the desk
# switch by itself and have nowhere to look at why, let alone turn it off.
#
# The window owns the list now, which means a rename or a deletion has to reach it the same way
# it reaches every other mode-keyed setting — while the window is open, not in a rename map
# applied at Save time. And the tray identifies the rule holding the desk by its SIGNATURE and
# not by its place in the list, so reordering must not be able to hand the desk to a stranger.

Write-Host ''
Write-Host 'rules in the Settings window' -ForegroundColor White

function New-RuleUi {
    param($Rules = @(), [hashtable]$Combos = @{})
    $settings = New-TestSettings -Combos $Combos
    $settings.rules = @($Rules)
    return (New-DialogUi -Settings $settings), $settings
}

Test-Case 'rules: the list comes up as rows, one per rule' {
    $ui, $settings = New-RuleUi -Rules @(
        [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'all'; back = ''; enabled = $true }
        [ordered]@{ when = 'idle'; process = ''; minutes = 20; mode = 'solo:LG ULTRAGEAR'; back = 'all'; enabled = $false }
    )
    try {
        Assert-Equal 2 $ui.RulesPanel.Children.Count 'a row each'
        Assert-Equal 2 @($ui.Rules).Count 'and the window is holding both'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: an empty list says so instead of standing blank' {
    # A blank space above a button reads like something that failed to load.
    $ui, $settings = New-RuleUi
    try {
        Assert-Equal 1 $ui.RulesPanel.Children.Count 'one line where the rows would be'
        Assert-True ([string]$ui.RulesPanel.Children[0].Text -like '*Nothing yet*') 'and it says the list is empty'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: a row is named in words, and modes by their titles' {
    # A real arrow and not "->": the desk cards two pages away move by that very character, and
    # two spellings of one arrow in one window read as two different things.
    $rule = [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'combo:Work'; back = 'all'; enabled = $true }
    Assert-Equal "cs2 is running$($script:UiArrow)Work" (Get-RuleRowTitle -Rule $rule) 'the condition and where it goes'
    Assert-Equal 'back to All displays' (Get-RuleRowSubtitle -Rule $rule) 'and where it comes back to'

    $idle = [ordered]@{ when = 'idle'; process = ''; minutes = 20; mode = 'all'; back = ''; enabled = $true }
    # The window's phrasing, not the log's: Get-RuleRowTitle goes through Get-RuleReasonText.
    Assert-Equal "nobody at the computer for 20 min$($script:UiArrow)All displays" (Get-RuleRowTitle -Rule $idle) 'the other condition'
    Assert-Equal 'back to the previous mode' (Get-RuleRowSubtitle -Rule $idle) 'the default return is visible too'
}

Test-Case 'rule group: add, edit and remove games through the editor' {
    $ui, $settings = New-RuleUi
    try {
        $ed = New-RuleEditorWindow -Rule $null -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false
        try {
            $ed.ProcessBox.Text = 'cs2.exe'
            $ed.ModeBox.SelectedIndex = 0
            $ed.Window.FindName('AddProcessBtn').RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
            Assert-Equal 2 $ed.ProcessBoxes.Count 'one more program field'
            $ed.ProcessBoxes[1].Text = 'dota2'
            $got = Read-RuleFromUi -Editor $ed
            Assert-True $got.Ok 'a group is accepted'
            Assert-Equal @('cs2.exe', 'dota2') @($got.Rule.processes) 'both programs are saved'
            $ed.WhenBox.SelectedItem = @($ed.WhenBox.Items | Where-Object { [string]$_.Tag -eq 'idle' })[0]
            $ed.WhenBox.SelectedItem = @($ed.WhenBox.Items | Where-Object { [string]$_.Tag -eq 'process' })[0]
            Assert-Equal @('cs2.exe', 'dota2') @((Read-RuleFromUi -Editor $ed).Rule.processes) 'trying another condition preserves the games'
            Assert-True ((Get-RuleRowTitle -Rule $got.Rule) -like 'one of cs2.exe, dota2 is running*') 'the row explains any game'
            [void]$ui.Rules.Add($got.Rule)
            $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
            Assert-Equal @('cs2.exe', 'dota2') @($updated.rules[0].processes) 'the Settings footer keeps the group'
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }
        $ed = New-RuleEditorWindow -Rule $updated.rules[0] -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false
        try {
            Assert-Equal 'cs2.exe' $ed.ProcessBox.Text 'the first game reopens'
            Assert-Equal 'dota2' $ed.ProcessBoxes[1].Text 'the second game reopens'
            $remove = @($ed.ProcessRows.Children[0].Children | Where-Object { $_ -is [System.Windows.Controls.Button] })[0]
            $remove.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
            $got = Read-RuleFromUi -Editor $ed
            Assert-Equal 'cs2.exe' $got.Rule.process 'removing the extra game leaves a single-program rule'
            Assert-Equal 0 @($got.Rule.processes).Count 'no stale game remains'
            $ed.ProcessBox.Text = ' '
            Assert-Equal $false (Read-RuleFromUi -Editor $ed).Ok 'removing every game cannot save an empty rule'
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: the enable toggle goes both ways and reaches the file' {
    $ui, $settings = New-RuleUi -Rules @(
        [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'all'; back = ''; enabled = $true }
    )
    try {
        $row = $ui.RulesPanel.Children[0]
        $toggle = @($row.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })[0]
        Assert-True ([bool]$toggle.IsChecked) 'it comes up on'
        # What a click does, without a click: the handler is one line and the state is the point.
        $ui.Rules[0]['enabled'] = $false
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ([bool]$updated.rules[0].enabled) 'switched off and saved'
        Assert-Equal 'cs2' ([string]$updated.rules[0].process) 'and the rule itself is still there'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: a rule added in the editor lands in the settings' {
    $ui, $settings = New-RuleUi
    try {
        $ed = New-RuleEditorWindow -Rule $null -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false
        try {
            $ed.ProcessBox.Text = 'cs2.exe'
            $ed.ModeBox.SelectedItem = @($ed.ModeBox.Items | Where-Object { [string]$_.Tag -eq 'all' })[0]
            $got = Read-RuleFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            [void]$ui.Rules.Add($got.Rule)
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }

        Update-RulesPanel -Ui $ui
        Assert-Equal 1 $ui.RulesPanel.Children.Count 'the row is there'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 1 @($updated.rules).Count 'and so is the rule'
        Assert-Equal 'cs2.exe' ([string]$updated.rules[0].process) 'with the program as typed'
        Assert-Equal 'all' ([string]$updated.rules[0].mode) 'and the mode it was pointed at'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: the editor refuses a rule with nowhere to go' {
    $ui, $settings = New-RuleUi
    try {
        $ed = New-RuleEditorWindow -Rule $null -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false
        try {
            $ed.ProcessBox.Text = 'cs2'
            $ed.ModeBox.SelectedIndex = -1
            $got = Read-RuleFromUi -Editor $ed
            Assert-Equal $false $got.Ok 'refused'
            Assert-True ($got.Problem -like '*mode this rule switches to*') 'and it says what is missing'
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: a program rule needs a program, an idle rule needs minutes' {
    $ui, $settings = New-RuleUi
    try {
        $ed = New-RuleEditorWindow -Rule $null -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false
        try {
            $ed.ModeBox.SelectedItem = @($ed.ModeBox.Items | Where-Object { [string]$_.Tag -eq 'all' })[0]
            $ed.ProcessBox.Text = '   '
            $got = Read-RuleFromUi -Editor $ed
            Assert-Equal $false $got.Ok 'a program rule with no program is refused'
            Assert-True ($got.Problem -like '*program*') 'and it says so'

            # Over to the other condition: only one panel is up at a time.
            $ed.WhenBox.SelectedItem = @($ed.WhenBox.Items | Where-Object { [string]$_.Tag -eq 'idle' })[0]
            Assert-Equal 'Collapsed' ([string]$ed.ProcessPanel.Visibility) 'the program box went away'
            Assert-Equal 'Visible' ([string]$ed.IdlePanel.Visibility) 'and the minutes came up'

            $ed.MinutesBox.Text = '0'
            $got = Read-RuleFromUi -Editor $ed
            Assert-Equal $false $got.Ok 'zero minutes is not an idle rule'
            $ed.MinutesBox.Text = 'soon'
            $got = Read-RuleFromUi -Editor $ed
            Assert-Equal $false $got.Ok 'and neither is a word'
            $ed.MinutesBox.Text = '20'
            $got = Read-RuleFromUi -Editor $ed
            Assert-True $got.Ok 'twenty minutes is'
            Assert-Equal 20 ([int]$got.Rule['minutes']) 'as a number'
            Assert-Equal 'idle' ([string]$got.Rule['when']) 'of the idle kind'
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: a rule cannot go back to the mode it switches to' {
    # It would undo itself the moment the condition ended and fire again straight after: a desk
    # that flickers every fifteen seconds.
    $ui, $settings = New-RuleUi
    try {
        $ed = New-RuleEditorWindow -Rule $null -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false
        try {
            $ed.ProcessBox.Text = 'cs2'
            $ed.ModeBox.SelectedItem = @($ed.ModeBox.Items | Where-Object { [string]$_.Tag -eq 'all' })[0]
            $ed.BackBox.SelectedItem = @($ed.BackBox.Items | Where-Object { [string]$_.Tag -eq 'all' })[0]
            $got = Read-RuleFromUi -Editor $ed
            Assert-Equal $false $got.Ok 'refused'
            Assert-True ($got.Problem -like '*cannot go back*') 'and it says why'
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: the editor opens on the rule it was given' {
    $rule = [ordered]@{ when = 'idle'; process = 'cs2'; minutes = 45; mode = 'all'; back = 'solo:LG ULTRAGEAR'; enabled = $false }
    $ui, $settings = New-RuleUi -Rules @($rule)
    try {
        $ed = New-RuleEditorWindow -Rule $ui.Rules[0] -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false
        try {
            Assert-Equal 'idle' ([string]$ed.WhenBox.SelectedItem.Tag) 'the condition'
            Assert-Equal '45' ([string]$ed.MinutesBox.Text) 'the minutes'
            Assert-Equal 'all' ([string]$ed.ModeBox.SelectedItem.Tag) 'where it goes'
            Assert-Equal 'solo:LG ULTRAGEAR' ([string]$ed.BackBox.SelectedItem.Tag) 'and where it comes back to'
            Assert-Equal 'Visible' ([string]$ed.IdlePanel.Visibility) 'showing the question its condition asks'

            # A rule that is off stays off through an edit: the toggle is in the list, not here.
            $got = Read-RuleFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Assert-Equal $false ([bool]$got.Rule['enabled']) 'and it is still switched off'
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: an edited rule keeps its place in the list' {
    # The order IS the order the tray checks them in, and the first that fits wins. Removing and
    # appending would quietly move an edited rule to the bottom of that order.
    $ui, $settings = New-RuleUi -Rules @(
        [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'all'; back = ''; enabled = $true }
        [ordered]@{ when = 'process'; process = 'dota2'; minutes = 0; mode = 'all'; back = ''; enabled = $true }
        [ordered]@{ when = 'idle'; process = ''; minutes = 20; mode = 'all'; back = ''; enabled = $true }
    )
    try {
        $first = $ui.Rules[0]
        $ed = New-RuleEditorWindow -Rule $first -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false
        try {
            $ed.ProcessBox.Text = 'valorant'
            $got = Read-RuleFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            foreach ($field in @($got.Rule.Keys)) { $first[$field] = $got.Rule[$field] }
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal @('valorant', 'dota2', '') @($updated.rules | ForEach-Object { [string]$_.process }) `
            'the edited one is still first'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: renaming a combination moves the rules that point at it' {
    $ui, $settings = New-RuleUi -Combos @{ Work = @('LG ULTRAGEAR') } -Rules @(
        [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'combo:Work'; back = ''; enabled = $true }
        [ordered]@{ when = 'idle'; process = ''; minutes = 20; mode = 'all'; back = 'combo:Work'; enabled = $true }
    )
    try {
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Office'; Patterns = @('LG ULTRAGEAR'); Primary = '' })

        Assert-Equal 'combo:Office' ([string]$ui.Rules[0]['mode']) 'the target followed the rename'
        Assert-Equal 'combo:Office' ([string]$ui.Rules[1]['back']) 'and so did the way back'
        Assert-True ((Get-RuleRowTitle -Rule $ui.Rules[0]) -like '*Office*') 'the row shows the new name'

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'combo:Office' ([string]$updated.rules[0].mode) 'and that is what is saved'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: deleting a combination drops the rules that needed it' {
    $ui, $settings = New-RuleUi -Combos @{ Work = @('LG ULTRAGEAR') } -Rules @(
        [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'combo:Work'; back = ''; enabled = $true }
        [ordered]@{ when = 'idle'; process = ''; minutes = 20; mode = 'all'; back = 'combo:Work'; enabled = $true }
    )
    try {
        Remove-UiCombo -Ui $ui -Combo $ui.Combos[0]
        Assert-Equal 1 @($ui.Rules).Count 'the one with nowhere to go is gone'
        Assert-Equal '' ([string]$ui.Rules[0]['back']) 'and the other kept its rule, losing only the way back'
        Assert-Equal 1 $ui.RulesPanel.Children.Count 'the panel agrees'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: the editor offers real modes, never an orphan row' {
    # An orphan is a key nobody can switch to. Offering it would build a rule that fails every
    # time it fires.
    $settings = Get-DefaultSettings
    $settings.hotkeys['combo:Gone'] = 'Ctrl+Alt+F8'
    $ui = New-DialogUi -Settings $settings
    try {
        $targets = @(Get-RuleTargetModes -Ui $ui)
        Assert-Equal 0 @($targets | Where-Object { [string]$_.Key -eq 'combo:Gone' }).Count 'not on offer'
        Assert-Equal 3 $targets.Count 'two displays and "all", which are the real ones'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: a target whose display is unplugged keeps its place in the dropdown' {
    # A cable out is not a reason to silently retarget somebody's rule.
    $ui, $settings = New-RuleUi -Rules @(
        [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'solo:GONE MONITOR'; back = ''; enabled = $true }
    )
    try {
        $ed = New-RuleEditorWindow -Rule $ui.Rules[0] -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false
        try {
            Assert-Equal 'solo:GONE MONITOR' ([string]$ed.ModeBox.SelectedItem.Tag) 'still the choice'
            Assert-True ([string]$ed.ModeBox.SelectedItem.Content -like '*not detected*') 'and it says why it is odd'
            $got = Read-RuleFromUi -Editor $ed
            Assert-True $got.Ok 'saving it changes nothing about it'
            Assert-Equal 'solo:GONE MONITOR' ([string]$got.Rule['mode']) 'the target is untouched'
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: reordering the list without editing keeps the desk with its holder' {
    # The tray finds the rule holding the desk by Get-RuleSignature, not by its index. This is
    # the guard on that: the Settings window can move rules about, and moving them must not hand
    # the desk to whoever slides into the vacated slot.
    $a = [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'all'; back = ''; enabled = $true }
    $b = [ordered]@{ when = 'idle'; process = ''; minutes = 20; mode = 'solo:LG ULTRAGEAR'; back = ''; enabled = $true }
    $held = Get-RuleSignature -Rule $b

    # The same list, the other way round - which is all a reorder is.
    $reordered = @($b, $a)
    Assert-Equal $held (Get-RuleSignature -Rule $reordered[0]) 'the holder is the same rule wherever it stands'
    Assert-Equal 1 @(@($reordered) | Where-Object { (Get-RuleSignature -Rule $_) -eq $held }).Count `
        'and exactly one rule answers to it'

    # And the decision agrees: asked with a stale index, it finds the holder by signature.
    $facts = [pscustomobject]@{ Processes = @(); IdleSeconds = 0 }
    $decision = Get-RuleDecision -Rules $reordered -Facts $facts -CurrentMode 'solo:LG ULTRAGEAR' `
                                 -OwnedIndex 1 -OwnedBack 'all' -OwnedSignature $held -OwnedTaken $true
    Assert-Equal 'return' ([string]$decision.Action) 'the condition ended, so the desk goes back'
    Assert-Equal 'all' ([string]$decision.Mode) 'to where it came from, not to a stranger'
}

Test-Case 'rules: editing the holding rule changes its signature, and the desk comes back' {
    # The designed behaviour, written down so it is not mistaken for a defect: a rule edited
    # while it holds the desk is a different rule, and the desk is handed back on the next tick.
    $before = [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'all'; back = ''; enabled = $true }
    $held = Get-RuleSignature -Rule $before
    $after = [ordered]@{ when = 'process'; process = 'dota2'; minutes = 0; mode = 'all'; back = ''; enabled = $true }
    Assert-True ($held -ne (Get-RuleSignature -Rule $after)) 'an edit makes it another rule'

    $facts = [pscustomobject]@{ Processes = @('cs2'); IdleSeconds = 0 }
    $decision = Get-RuleDecision -Rules @($after) -Facts $facts -CurrentMode 'all' `
                                 -OwnedIndex 0 -OwnedBack 'solo:LG ULTRAGEAR' -OwnedSignature $held -OwnedTaken $true
    Assert-Equal 'return' ([string]$decision.Action) 'the rule that held the desk is no longer there'
    Assert-Equal 'solo:LG ULTRAGEAR' ([string]$decision.Mode) 'so the desk goes back where it came from'
}

Test-Case 'rules: the program is offered from a list, and typed by hand just as well' {
    $ui, $settings = New-RuleUi
    try {
        $ed = New-RuleEditorWindow -Rule $null -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false
        try {
            # Building the window must not walk every process on the machine: the editor is built
            # by the dozen in these tests, and by every person who opens Add a rule.
            Assert-Equal 0 $ed.ProcessBox.Items.Count 'the list is empty until it is opened'
            Assert-True (-not $ed.ProcessListed) 'and nobody has gathered it'

            # Opening it fills it once. What is there depends on what is running, so what is
            # checked is the shape: names, no .exe, no repeats, in order.
            Add-ProcessItems -Editor $ed
            Add-ProcessItems -Editor $ed
            $names = @($ed.ProcessBox.Items)
            Assert-True $ed.ProcessListed 'gathered'
            Assert-Equal 0 @($names | Where-Object { $_ -like '*.exe' }).Count 'stored the way a rule stores it'
            Assert-Equal @($names | Sort-Object -Unique).Count $names.Count 'once each, and in order'

            # Typing is still typing: a program that is neither running nor in the diary.
            $ed.ProcessBox.Text = 'some-game.exe'
            $ed.ModeBox.SelectedIndex = 0
            $got = Read-RuleFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Assert-Equal 'some-game.exe' ([string]$got.Rule.process) 'exactly what was typed'
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: the displays condition offers a tick per display of the desk, the off one included' {
    $desk = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf')
        (New-FakeMonitor 'XG27AQDMGR' 'AUS1234' 'path-xg' $false $true)
    )
    $ui, $settings = New-RuleUi
    try {
        $ed = New-RuleEditorWindow -Rule $null -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false -Displays $desk
        try {
            Assert-Equal 3 @($ed.DisplayChecks).Count 'three ticks for three displays'
            Assert-True ([string]$ed.DisplayChecks[2].Content -like '*not detected*') 'the display Windows cannot see says so'

            $ed.WhenBox.SelectedItem = @($ed.WhenBox.Items | Where-Object { [string]$_.Tag -eq 'displays' })[0]
            Assert-Equal 'Visible' ([string]$ed.DisplaysPanel.Visibility) 'the ticks come up'
            Assert-Equal 'Collapsed' ([string]$ed.ProcessPanel.Visibility) 'and the program box goes'
            $ed.ModeBox.SelectedItem = @($ed.ModeBox.Items | Where-Object { [string]$_.Tag -eq 'all' })[0]

            $got = Read-RuleFromUi -Editor $ed
            Assert-Equal $false $got.Ok 'no display ticked is refused'
            Assert-True ($got.Problem -like '*Tick the displays*') 'and it says what to do'

            $ed.DisplayChecks[0].IsChecked = $true
            $ed.DisplayChecks[2].IsChecked = $true
            $got = Read-RuleFromUi -Editor $ed
            Assert-True $got.Ok 'two ticks make a desk'
            Assert-Equal 'displays' ([string]$got.Rule['when']) 'of the displays kind'
            Assert-Equal 'LG ULTRAGEAR|XG27AQDMGR' (@($got.Rule['displays']) -join '|') 'naming the ticked ones, the off one too'
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: a displays rule opens with its desk ticked, and a row names the desk' {
    $rule = [ordered]@{ when = 'displays'; process = ''; minutes = 0; displays = @('ULTRAFINE', 'DELL U2720Q'); mode = 'all'; back = ''; enabled = $true }
    $ui, $settings = New-RuleUi -Rules @($rule)
    try {
        Assert-Equal "ULTRAFINE, DELL U2720Q are connected$($script:UiArrow)All displays" (Get-RuleRowTitle -Rule $ui.Rules[0]) 'the row'
        $ed = New-RuleEditorWindow -Rule $ui.Rules[0] -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false -Displays $script:DlgState
        try {
            Assert-Equal 'displays' ([string]$ed.WhenBox.SelectedItem.Tag) 'the condition'
            $ticked = @($ed.DisplayChecks | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
            Assert-Equal 'LG ULTRAFINE|DELL U2720Q' ($ticked -join '|') 'the desk it names: the ULTRAFINE by its piece of a name, the DELL kept as a tick of its own'
            Assert-True ([string]$ed.DisplayChecks[-1].Content -like 'DELL U2720Q*not detected*') 'and the DELL, which this desk has never seen, says so'
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }
    }
    finally { $ui.Window.Close() }
}
