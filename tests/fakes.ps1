<#
    tests\fakes.ps1 — the fakes that more than one group of cases needs.

    The tests must not depend on what is on the desk right now, and must not show any windows.
    Everything that only one group needs lives in that group's file under cases/ — only what is
    shared is here.
#>

# Fictional monitors: the tests must not depend on what is on the desk right now.
# The fields are exactly the ones Get-DisplayState hands back: a fake must not know about fields
# the real state does not have.
function New-FakeMonitor {
    param([string]$Label, [string]$ShortId, [string]$Id = '',
          [bool]$Active = $true, [bool]$Disconnected = $false)
    if (-not $Id) { $Id = 'path-' + $Label + '-' + $ShortId }
    return [pscustomobject]@{
        Output = '\\.\DISPLAY1'; Label = $Label; Model = $Label; ShortId = $ShortId
        Native = $null; Id = $Id; Active = $Active
        Primary = $false; Disconnected = $Disconnected
        Width = 2560; Height = 1440; Hz = 144; BestMode = $null
    }
}

# Settings with combos, in one line: almost every test writes them.
function New-TestSettings {
    param([hashtable]$Combos = @{})
    $s = Get-DefaultSettings
    foreach ($name in $Combos.Keys) {
        $v = $Combos[$name]
        $displays = @()
        $primary = ''
        if ($v -is [array]) { $displays = @($v) }
        elseif ($v -is [hashtable]) { $displays = @($v.displays); $primary = [string]$v.primary }
        else { $displays = @([string]$v) }
        $s.combos[$name] = [ordered]@{ displays = $displays; primary = $primary }
    }
    return $s
}

# A screen for working out the layout: only the fields the positions are computed from.
function New-FakeScreen {
    param([string]$Path, [string]$Label, [int]$Width, [int]$Height)
    return [pscustomobject]@{ DevicePath = $Path; Label = $Label; Width = $Width; Height = $Height }
}

# The default desk for the Settings window and its editors: two monitors, and both are enough for
# all four groups that test the window.
$script:DlgState = @(
    (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
    (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf')
)

function New-DialogUi {
    param($Settings, $State)
    if ($null -eq $State) { $State = $script:DlgState }
    $modes = @(Get-DialogModes -State $State -Settings $Settings)
    return New-SettingsWindow -Modes $modes -Settings $Settings -State $State
}
