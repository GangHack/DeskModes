# --- the monitors this desk has ever had ------------------------------------
# A monitor switched off at its own button either keeps its CCD target (both LGs here do) or
# leaves the bus outright and stops being enumerated at all (the ASUS does). In the second case
# everything downstream of the state lost it, including the list a rule about it is written from.
# The roster is what puts it back, and these are the four things it has to get right: it learns
# without being asked, it does not rewrite the file for nothing, it forgets a monitor that is
# really gone, and what it hands back reads as an ordinary display that is not connected.

Write-Host ''
Write-Host 'the monitors this desk has ever had' -ForegroundColor White

# Every case here starts from an empty roster: the file is shared between them, and a leftover
# from the case above would make the next one pass for the wrong reason.
function Clear-TestRoster {
    Remove-Item -LiteralPath $script:KnownDisplaysFile -Force -ErrorAction SilentlyContinue
}

# A record straight into the file, with a stamp chosen by the case. The only way to write a date
# in the past: Update-KnownDisplays always stamps today, which is the whole point of it.
function Set-TestRoster {
    param([hashtable]$Entries)

    $flat = [ordered]@{}
    foreach ($name in @($Entries.Keys | Sort-Object)) {
        $flat[[string]$name] = [ordered]@{
            short = 'SHORT1'; id = 'path-' + $name; w = 0; h = 0
            seen  = [string]$Entries[$name]
        }
    }
    Set-Content -Path $script:KnownDisplaysFile -Value ($flat | ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8
}

Test-Case 'roster: a desk is learned once and not written again' {
    Clear-TestRoster
    $desk = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'path-asus')
    )

    Assert-True (Update-KnownDisplays -State $desk) 'the first sight of a desk is written down'
    $known = Get-KnownDisplays
    Assert-Equal 2 @($known.Keys).Count 'both monitors remembered'
    Assert-Equal 'AUSAA1D' ([string]$known['XG27AQDMGR'].ShortId) 'and by name, with its short ID beside it'

    # The tray asks for this on every refresh of its state cache - a right-click on the icon does
    # one. A write per menu open is what the text comparison in Update-KnownDisplays is for.
    Assert-True (-not (Update-KnownDisplays -State $desk)) 'the same desk again changes nothing'
}

Test-Case 'roster: the stamp is ISO whatever the calendar the machine is set to' {
    # A Thai locale makes yyyy a Buddhist year, and this value is written back to the file rather
    # than merely shown - so the next read would compare 2569 against a cut-off in 2026 and throw
    # the monitor away.
    Clear-TestRoster
    $was = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo('th-TH')
        [void](Update-KnownDisplays -State @((New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf')))
        $seen = [string](Get-KnownDisplays)['LG ULTRAFINE'].Seen
        Assert-Equal ((Get-Date).ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)) $seen 'today, in ISO'
    }
    finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $was }
}

Test-Case 'roster: what has not been seen for months is dropped, what is on the desk is not' {
    Clear-TestRoster
    Set-TestRoster @{
        'SOLD PANEL'   = (Get-Date).AddDays(-($script:KnownDisplayDays + 1)).ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
        'XG27AQDMGR'   = (Get-Date).AddDays(-3).ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
        # A clock set wrong, or a folder copied off another machine: a monitor the enumeration has
        # just named must survive its own stamp.
        'LG ULTRAGEAR' = '2001-01-01'
        # A record from a version that wrote no date. Dropped rather than kept for ever - one
        # appearance of the monitor puts it straight back.
        'NO STAMP'     = ''
    }
    [void](Update-KnownDisplays -State @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')))

    $known = Get-KnownDisplays
    Assert-True ($known.Contains('LG ULTRAGEAR')) 'the monitor in front of us stays'
    Assert-True ($known.Contains('XG27AQDMGR')) 'and one seen three days ago'
    Assert-True (-not $known.Contains('SOLD PANEL')) 'the one nobody has seen in months is gone'
    Assert-True (-not $known.Contains('NO STAMP')) 'and so is the record with no date'
}

Test-Case 'roster: a damaged file is an empty roster, not a broken window' {
    Set-Content -Path $script:KnownDisplaysFile -Value 'not json at all' -Encoding UTF8
    Assert-Equal 0 @((Get-KnownDisplays).Keys).Count 'nothing remembered, and nothing thrown'
    # And the next desk seen writes a whole file over the rubbish.
    Assert-True (Update-KnownDisplays -State @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug'))) 'written afresh'
    Assert-Equal 1 @((Get-KnownDisplays).Keys).Count 'and readable again'
}

Test-Case 'desk: a remembered monitor comes back as a display that is not connected' {
    Clear-TestRoster
    $asus = New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'path-asus'
    $asus.Native = [pscustomobject]@{ Width = 2560; Height = 1440 }
    [void](Update-KnownDisplays -State @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug'), $asus))

    # The ASUS has left the bus: Windows names the one LG and nothing else.
    $desk = @(Get-DeskDisplays -State @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')))
    Assert-Equal 2 $desk.Count 'the desk is both of them again'

    $back = $desk | Where-Object { $_.Label -eq 'XG27AQDMGR' } | Select-Object -First 1
    Assert-True $back.Disconnected 'and the remembered one says it is not connected'
    Assert-True (-not $back.Active) 'nothing is being shown on it'
    Assert-True (-not $back.Primary) 'and it does not claim the taskbar'
    Assert-Equal 0 ([int]$back.Hz) 'no refresh rate to report'
    Assert-Equal 'path-asus' ([string]$back.Id) 'the device path it was last seen at, for its EDID'
    Assert-Equal 1440 ([int]$back.Native.Height) 'and its panel size, so its card is drawn to scale'

    # The fields are the state record's and nothing more: every consumer reads Disconnected and
    # needs to learn no new field to tell a remembered monitor from an unplugged one.
    $live = @(New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')[0]
    $missing = @(@($live.PSObject.Properties.Name) | Where-Object { @($back.PSObject.Properties.Name) -notcontains $_ })
    Assert-Equal 0 $missing.Count ('nothing missing from the record: ' + ($missing -join ', '))
    $extra = @(@($back.PSObject.Properties.Name) | Where-Object { @($live.PSObject.Properties.Name) -notcontains $_ })
    Assert-Equal 0 $extra.Count ('and nothing invented either: ' + ($extra -join ', '))
}

Test-Case 'desk: a monitor Windows still names is not doubled by the roster' {
    Clear-TestRoster
    $desk = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug'))
    [void](Update-KnownDisplays -State $desk)
    Assert-Equal 1 @(Get-DeskDisplays -State $desk).Count 'one monitor, one record'

    # Including when it is there but switched off: the state already holds it, and that record is
    # the truthful one - it has a resolution and a real output name in it.
    $off = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug' -Active $false))
    $back = @(Get-DeskDisplays -State $off)
    Assert-Equal 1 $back.Count 'still one'
    Assert-True (-not $back[0].Disconnected) 'and the state won, not the roster'
}

Test-Case 'modes: a remembered monitor has a solo mode, and it is unavailable' {
    # This is what the whole roster is for. Without it there is no solo:XG27AQDMGR to point a rule
    # at while the monitor is off - the dropdown in the rule editor is built out of these.
    Clear-TestRoster
    [void](Update-KnownDisplays -State @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'path-asus')
    ))
    $settings = New-TestSettings @{ Work = @('ULTRAGEAR', 'XG27AQDMGR') }
    $desk = @(Get-DeskDisplays -State @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')))
    $modes = @(Get-DisplayModes -State $desk -Settings $settings)

    $solo = $modes | Where-Object { $_.Key -eq 'solo:XG27AQDMGR' } | Select-Object -First 1
    Assert-True ($null -ne $solo) 'the mode exists to be chosen'
    Assert-True (-not $solo.Available) 'and says it cannot be switched to right now'

    # A combo keeps counting as available on one member, the way it always has: it switches on
    # what is there.
    $combo = $modes | Where-Object { $_.Key -eq 'combo:Work' } | Select-Object -First 1
    Assert-True $combo.Available 'a combo with one member present is still available'
    # And a mode nobody can switch to must not be reported as the current one.
    Assert-Equal 'solo:LG ULTRAGEAR' ([string](Get-ActiveModeKey -State $desk -Modes $modes)) 'the desk is the LG alone'
}

Test-Case 'modes: a remembered monitor is not a member to switch on' {
    # Get-ModeMembers is what the switch walks, and it drops whatever is not connected. So "all"
    # with a remembered monitor in the desk still assembles only the monitors that are there.
    Clear-TestRoster
    [void](Update-KnownDisplays -State @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'path-asus')
    ))
    $desk = @(Get-DeskDisplays -State @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')))
    $all = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Primary = $null; Available = $true }
    $members = @(Get-ModeMembers -Mode $all -State $desk)
    Assert-Equal 1 $members.Count 'only the monitor that is actually on the bus'
    Assert-Equal 'LG ULTRAGEAR' ([string]$members[0].Label) 'and it is the LG'
}

Test-Case 'dialog: a combo offers a tick for a display that is not connected' {
    # The reason a combo can be built for the desk you are about to have. Before this the members
    # panel listed the connected monitors only, so the ASUS could be put into a combo exactly
    # while it was switched on - and never while it was not.
    $desk = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'path-asus' -Active $false -Disconnected $true)
    )
    $mode = [pscustomobject]@{ Key = 'combo:Movie'; Title = 'Movie'; Kind = 'combo'; Available = $true }
    $combo = [pscustomobject]@{ Name = 'Movie'; Patterns = @('ULTRAGEAR'); Primary = '' }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $desk -TakenNames @() `
                               -Hotkeys ([ordered]@{}) -Dark $false
    try {
        $byTag = @{}
        foreach ($cb in $ed.Checks) { $byTag[[string]$cb.Tag] = $cb }
        Assert-True ($byTag.ContainsKey('XG27AQDMGR')) 'the display that is away has a row of its own'
        Assert-True ($byTag['XG27AQDMGR'].Content -like '*(not detected)*') 'and it says so'
        Assert-True (-not $byTag['XG27AQDMGR'].IsChecked) 'unticked: the combo does not name it yet'
        # What leaves for settings.json is the name and nothing else - the wording is for the eye.
        Assert-Equal 'XG27AQDMGR' ([string]$byTag['XG27AQDMGR'].Tag) 'the tag is the name that goes to the file'
        Assert-True ($byTag['LG ULTRAGEAR'].Content -notlike '*(not detected)*') 'the connected one is named plainly'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: the desk row keeps a place for a display that is not connected' {
    $settings = New-TestSettings
    $settings.layout = @('LG ULTRAGEAR', 'XG27AQDMGR')
    $desk = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'path-asus' -Active $false -Disconnected $true)
    )
    $ui = New-DialogUi -Settings $settings -State $desk
    try {
        Assert-Equal 2 $ui.DeskPanel.Children.Count 'both cards in the row'
        # The order left to right IS the layout, and it has to survive being saved while one of
        # the monitors is off - otherwise every Save while the ASUS is dark loses its place.
        $read = Read-SettingsFromUi -Ui $ui -Settings $settings -Quiet
        Assert-True $read.Ok 'the window can say what it would write'
        Assert-Equal 'LG ULTRAGEAR, XG27AQDMGR' (@($read.Settings.layout) -join ', ') 'and the row is kept whole'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'rules: a rule can be pointed at a display that is switched off' {
    # The complaint this whole roster answers: "I want a rule for the ASUS, and the ASUS is not in
    # the list, because it is off". A rule fires later by definition, so the target has to be
    # choosable now - marked as away, not withheld.
    $settings = New-TestSettings
    $desk = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'path-asus' -Active $false -Disconnected $true)
    )
    $ui = New-DialogUi -Settings $settings -State $desk
    try {
        $ed = New-RuleEditorWindow -Rule $null -Modes (Get-RuleTargetModes -Ui $ui) -Dark $false
        try {
            $item = @($ed.ModeBox.Items | Where-Object { [string]$_.Tag -eq 'solo:XG27AQDMGR' })[0]
            Assert-True ($null -ne $item) 'the display that is off is offered as a target'
            Assert-True ([string]$item.Content -like '*(not detected)*') 'and says it is not there right now'
            Assert-True $item.IsEnabled 'but it can still be chosen'

            $ed.ProcessBox.Text = 'cs2.exe'
            $ed.ModeBox.SelectedItem = $item
            $got = Read-RuleFromUi -Editor $ed
            Assert-True $got.Ok 'the rule is accepted'
            # The key and not the caption: the wording is for the eye, settings.json gets the key.
            Assert-Equal 'solo:XG27AQDMGR' ([string]$got.Rule['mode']) 'and points at the mode by key'
        }
        finally { $ed.Window.Close(); $script:ActiveRuleUi = $null }
    }
    finally { $ui.Window.Close() }
}

# --- forgetting a monitor ---------------------------------------------------
# A display tried once and then given away sits in every list for ninety days, because "not
# connected" is also what a monitor that is merely switched off looks like and the program cannot
# tell the two apart. The button is the person saying which it was.

Test-Case 'displays table: only a monitor Windows cannot see can be forgotten' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'XG27AQDMGR' 'AUS1234' 'path-xg' $false $true)
    )
    $ui = New-DialogUi -Settings (Get-DefaultSettings) -State $state
    try {
        Update-DisplaysTable -Ui $ui
        $buttons = @($ui.DisplaysTable.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })
        Assert-Equal 1 $buttons.Count 'one button, for the one display that is gone'
        Assert-Equal 'XG27AQDMGR' ([string]$buttons[0].Tag) 'and it names that display'
        Assert-Equal (Get-Text -Key 'table.forget') ([string]$buttons[0].Content) 'it says what it does'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'displays table: forgetting takes the row out of every list in the window' {
    $script:Forgotten = @()
    function Remove-KnownDisplay { param([string]$Label) $script:Forgotten += $Label; return $true }
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'XG27AQDMGR' 'AUS1234' 'path-xg' $false $true)
    )
    $ui = New-DialogUi -Settings (Get-DefaultSettings) -State $state
    try {
        Update-DisplaysTable -Ui $ui
        Assert-Equal 2 @($ui.State).Count 'both are on the desk to begin with'
        $button = @($ui.DisplaysTable.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })[0]
        $button.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))

        Assert-Equal @('XG27AQDMGR') $script:Forgotten 'the roster was told, by name'
        Assert-Equal 1 @($ui.State).Count 'and the window forgot it too'
        Assert-Equal 'LG ULTRAGEAR' ([string]@($ui.State)[0].Label) 'the monitor that is here stays'
        $cells = @($ui.DisplaysTable.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] })
        Assert-True (-not (@($cells | ForEach-Object { [string]$_.Text }) -contains 'XG27AQDMGR')) 'the table lost its row'
        Assert-Equal 0 @($ui.DisplaysTable.Children | Where-Object { $_ -is [System.Windows.Controls.Button] }).Count `
            'and there is nothing left to forget'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'displays table: what was set for a forgotten display is kept as an orphan, not silently dropped' {
    # Nothing in settings.json is touched. The Modes page has had a Remove button for a mode whose
    # display is gone since long before this existed, and that is where the rest of it goes.
    function Remove-KnownDisplay { param([string]$Label) return $true }
    $settings = Get-DefaultSettings
    $settings.hotkeys['solo:XG27AQDMGR'] = 'Ctrl+Alt+F9'
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'XG27AQDMGR' 'AUS1234' 'path-xg' $false $true)
    )
    $ui = New-DialogUi -Settings $settings -State $state
    try {
        Update-DisplaysTable -Ui $ui
        $button = @($ui.DisplaysTable.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })[0]
        $button.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        Assert-Equal 'Ctrl+Alt+F9' ([string]$ui.Hotkeys['solo:XG27AQDMGR']) 'the shortcut is still there to be removed on purpose'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'forget: a name the roster has never heard of is not an error' {
    # The window and the tray hold their own copies of the desk, and either can be a moment out of
    # date - the roster may have aged the record out between the table being drawn and the click.
    $script:KnownDisplaysFile = Join-Path $script:TestDir ('forget-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Assert-Equal $false (Remove-KnownDisplay -Label 'never seen') 'nothing to remove, nothing written'
        Set-Content -Path $script:KnownDisplaysFile -Encoding UTF8 -Value (
            '{"XG27AQDMGR":{"model":"XG27AQDMGR","short":"AUS1234","id":"path-xg","w":2560,"h":1440,"seen":"2026-09-01"}}')
        Assert-True (Remove-KnownDisplay -Label 'XG27AQDMGR') 'a name it knows is removed'
        Assert-Equal 0 (Get-KnownDisplays).Count 'and the roster comes back empty'
        Assert-Equal $false (Remove-KnownDisplay -Label 'XG27AQDMGR') 'asking twice changes nothing'
    }
    finally { Remove-Item -LiteralPath $script:KnownDisplaysFile -ErrorAction SilentlyContinue }
}
