# --- HDR following the mode -------------------------------------------------
# Windows' own switch, hung on a mode. The native call is shadowed here the way the DDC calls are in
# the orchestrator tests: what is tested is the decision - who gets what, and that a display already
# where the mode wants it is not touched, because the toggle blanks the screen for a moment.

Write-Host ''
Write-Host 'HDR following the mode' -ForegroundColor White

Test-Case 'hdr setting: a bool, a word or a map per display, and rubbish is no setting' {
    Assert-Equal $true (ConvertTo-HdrSetting $true) 'true'
    Assert-Equal $false (ConvertTo-HdrSetting 'off') 'off, written by hand'
    Assert-Null (ConvertTo-HdrSetting 'bright') 'a word that is neither'
    Assert-Null (ConvertTo-HdrSetting 7) 'a number is not an answer'
    $map = ConvertTo-HdrSetting ([pscustomobject]@{ ULTRAGEAR = $true; XG27 = 'off'; DELL = 'maybe' })
    Assert-Equal 2 $map.Count 'two readable answers out of three'
    Assert-Equal $false $map['XG27'] 'off is false'
}

Test-Case 'hdr plan: one answer for all, or one each by a piece of the name' {
    $wanted = @(
        [pscustomobject]@{ Label = 'LG ULTRAGEAR'; ShortId = 'GSM5BB3' }
        [pscustomobject]@{ Label = 'XG27AQDMGR'; ShortId = 'AUS1234' }
    )
    $all = Get-HdrPlan -Setting $true -Wanted $wanted
    Assert-Equal 2 $all.Count 'both'
    $each = Get-HdrPlan -Setting ([ordered]@{ ULTRAGEAR = $false }) -Wanted $wanted
    Assert-Equal 1 $each.Count 'only the one named'
    Assert-Equal $false $each['LG ULTRAGEAR'] 'by the whole label it answers for'
    Assert-Equal 0 (Get-HdrPlan -Setting $null -Wanted $wanted).Count 'nothing set, nothing planned'
}

Test-Case 'hdr: a display already where the mode wants it is not touched, the other is switched' {
    $script:HdrCalls = @()
    function Get-CcdTargets {
        return @(
            [pscustomobject]@{ DevicePath = 'path-ug'; Output = '\\.\DISPLAY1'; Active = $true; Label = 'LG ULTRAGEAR' }
            [pscustomobject]@{ DevicePath = 'path-xg'; Output = '\\.\DISPLAY2'; Active = $true; Label = 'XG27AQDMGR' }
        )
    }
    function Get-DisplayHdr {
        param($Target)
        if ($Target.DevicePath -eq 'path-ug') { return [pscustomobject]@{ Supported = $true; Enabled = $true } }
        return [pscustomobject]@{ Supported = $true; Enabled = $false }
    }
    function Set-DisplayHdr { param($Target, [bool]$Enabled) $script:HdrCalls += "$($Target.DevicePath)=$Enabled"; return $true }

    $targets = @(
        [pscustomobject]@{ Device = '\\.\DISPLAY1'; Label = 'LG ULTRAGEAR'; ShortId = 'GSM5BB3' }
        [pscustomobject]@{ Device = '\\.\DISPLAY2'; Label = 'XG27AQDMGR'; ShortId = 'AUS1234' }
    )
    $changed = @(Set-ModeHdr -Setting $true -Targets $targets)
    Assert-Equal @('path-xg=True') $script:HdrCalls 'only the one that was off is asked to turn on'
    Assert-Equal @('XG27AQDMGR') $changed 'and it is the one reported'
}

Test-Case 'hdr: a display that cannot do it is left alone, and so is one that is not on the desk' {
    $script:HdrCalls = @()
    function Get-CcdTargets {
        return @([pscustomobject]@{ DevicePath = 'path-ug'; Output = '\\.\DISPLAY1'; Active = $true; Label = 'LG ULTRAGEAR' })
    }
    function Get-DisplayHdr { param($Target) return [pscustomobject]@{ Supported = $false; Enabled = $false } }
    function Set-DisplayHdr { param($Target, [bool]$Enabled) $script:HdrCalls += 'set'; return $true }

    $targets = @(
        [pscustomobject]@{ Device = '\\.\DISPLAY1'; Label = 'LG ULTRAGEAR'; ShortId = 'GSM5BB3' }
        [pscustomobject]@{ Device = '\\.\DISPLAY9'; Label = 'GHOST'; ShortId = 'X' }
    )
    $changed = @(Set-ModeHdr -Setting $true -Targets $targets)
    Assert-Equal 0 $script:HdrCalls.Count 'nothing was set'
    Assert-Equal 0 $changed.Count 'and nothing claimed'
}

Test-Case 'hdr: the switch tail applies it only when the mode says something' {
    $script:HdrTailCalls = @()
    function Set-ModeHdr { param($Setting, $Targets) $script:HdrTailCalls += 'hdr'; return @() }
    function Restore-WindowLayout { param([string]$Key) }
    function Invoke-ModeHook { param($Settings, [string]$ModeKey, [string]$Phase) return $true }
    $targets = @([pscustomobject]@{ Device = '\\.\DISPLAY1'; Label = 'LG ULTRAGEAR'; ShortId = 'GSM5BB3' })

    $settings = Get-DefaultSettings
    Invoke-SwitchTail -Settings $settings -ModeKey 'all' -RestoreWindows $false -LevelTargets $targets
    Assert-Equal 0 $script:HdrTailCalls.Count 'nothing in the dictionary, nothing asked'

    $settings.hdr['all'] = $true
    Invoke-SwitchTail -Settings $settings -ModeKey 'all' -RestoreWindows $false -LevelTargets $targets
    Assert-Equal 1 $script:HdrTailCalls.Count 'one entry, one call'
}

Test-Case 'hdr: settings.json carries it in and the window carries it out per display' {
    $settings = Get-DefaultSettings
    $settings.combos['Game'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.hdr['combo:Game'] = $true
    $settings.hdr['all'] = [ordered]@{ ULTRAFINE = $false }
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal 2 $ui.Hdr.Count 'both modes came in'
        Assert-True ((Get-ModeRowSubtitle -Ui $ui -Mode ([pscustomobject]@{ Key = 'combo:Game'; Kind = 'combo'; Title = 'Game' })) -like '*HDR*') 'and its caption says HDR'

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $true $updated.hdr['combo:Game'] 'a bare answer stays bare'
        Assert-Equal $false $updated.hdr['all']['ULTRAFINE'] 'and a per-display one stays per display'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'hdr: the editor shows a row per display, and a choice lands in the mode' {
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $hdr = [ordered]@{ 'all' = [ordered]@{ ULTRAGEAR = $true } }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Hdr $hdr -Dark $false
    try {
        $boxes = @($ed.HdrPanel.Children | ForEach-Object { @($_.Children | Where-Object { $_ -is [System.Windows.Controls.ComboBox] })[0] })
        Assert-Equal 2 $boxes.Count 'two displays, two rows'
        Assert-Equal 1 $boxes[0].SelectedIndex 'the UltraGear opens on On, found by a piece of its name'
        Assert-Equal 0 $boxes[1].SelectedIndex 'the UltraFine on Leave alone'

        $boxes[1].SelectedIndex = 2
        $got = Read-ModeFromUi -Editor $ed
        Assert-True $got.Ok 'accepted'
        Assert-Equal $true $got.Mode.Hdr['ULTRAGEAR'] 'kept under the key it was written by'
        Assert-Equal $false $got.Mode.Hdr['LG ULTRAFINE'] 'and the new answer under the whole name'

        $boxes[0].SelectedIndex = 0
        $got = Read-ModeFromUi -Editor $ed
        Assert-True (-not $got.Mode.Hdr.Contains('ULTRAGEAR')) 'leave alone takes the entry away'
    }
    finally { $ed.Window.Close(); $script:ActiveEditor = $null }
}

Test-Case 'hdr: a per-display answer written by Monitor ID survives both Saves' {
    $settings = Get-DefaultSettings
    $settings.hdr['all'] = [ordered]@{ 'GSM5BB3' = $false }
    $ui = New-DialogUi -Settings $settings -State $script:DlgState
    try {
        $mode = @($ui.Modes | Where-Object { $_.Key -eq 'all' })[0]
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Hdr $ui.Hdr -Dark $false
        try {
            Assert-Equal 'GSM5BB3' (Get-HdrKeyFor -Editor $ed -Name 'LG ULTRAGEAR') 'the row finds the Monitor ID'
            $got = Read-ModeFromUi -Editor $ed
            Assert-Equal $false ([bool]$got.Mode.Hdr['GSM5BB3']) 'the editor keeps the answer under that ID'

            Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited $got.Mode
            $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
            Assert-Equal $false ([bool]$updated.hdr['all']['GSM5BB3']) 'the settings Save keeps it too'
        }
        finally { $ed.Window.Close(); $script:ActiveEditor = $null }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'hdr: a combination renamed takes its HDR along, and one removed takes it away' {
    $settings = Get-DefaultSettings
    $settings.combos['Game'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.hdr['combo:Game'] = $true
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = [pscustomobject]@{ Key = 'combo:Game'; Title = 'Game'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Play'; Patterns = @('LG ULTRAGEAR'); Primary = ''
        })
        Assert-True $ui.Hdr.Contains('combo:Play') 'moved with the name'
        Assert-True (-not $ui.Hdr.Contains('combo:Game')) 'and not left behind'

        Remove-UiCombo -Ui $ui -Combo $ui.Combos[0]
        Assert-Equal 0 $ui.Hdr.Count 'gone with the combination'
    }
    finally { $ui.Window.Close() }
}
