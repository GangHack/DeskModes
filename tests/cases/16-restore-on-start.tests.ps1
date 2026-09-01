# --- restoring the mode when the tray starts --------------------------------
# Live, this can only be tested by rebooting, so the decision ("put it back or leave it alone") is
# tested separately from the switch itself. We pull the function out of Displays.ps1 by parsing the
# file — it cannot be dot-sourced, it brings the whole application up, and a copy of the code in the
# test would drift apart from the original (the same trick as for Resolve-ModeKey above).

Write-Host ''
Write-Host 'restoring the mode when the tray starts' -ForegroundColor White

$trayAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Displays.ps1'), [ref]$null, [ref]$null)
foreach ($name in 'Get-AvailableMode', 'Invoke-StartupRestore') {
    $found = $trayAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }.GetNewClosure(), $true)
    if ($found.Count -ne 1) { throw "expected exactly one $name in Displays.ps1, found $($found.Count)" }
    . ([scriptblock]::Create($found[0].Extent.Text))
}

# The tray environment this function expects around itself.
$script:TestSettings = Get-DefaultSettings
$script:TestState = @()
$script:Invoked = $null
$script:SwitchedOnce = $false

function Get-ActiveSettings { return $script:TestSettings }
function Get-CachedState { return $script:TestState }
function Invoke-Mode {
    param([string]$Key, [switch]$Auto, [switch]$Silent)
    $script:Invoked = [pscustomobject]@{ Key = $Key; Auto = [bool]$Auto; Silent = [bool]$Silent }
}

# Only the ASUS is on, and all three monitors are connected.
function Set-RestoreScene {
    param([bool]$UltraGearConnected = $true)
    $script:TestState = @(
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' 'path-asus'      $true)
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ultragear' $false (-not $UltraGearConnected))
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-ultrafine' $false)
    )
    $script:Invoked = $null
    $script:SwitchedOnce = $false
    $script:TestSettings = Get-DefaultSettings
}

# A remembered mode from the PREVIOUS power-on of the machine: the session is not ours.
function Set-RememberedMode {
    param([string]$Key, [string]$Session = 'a-previous-boot')
    ([ordered]@{ key = $Key; session = $Session; when = '2026-08-12T15:28:25' } | ConvertTo-Json -Compress) |
        Set-Content -Path $script:LastModeFile -Encoding UTF8
}

Test-Case 'startup: a mode chosen before the last shutdown comes back' {
    Set-RestoreScene
    Set-RememberedMode 'solo:LG ULTRAGEAR'
    Invoke-StartupRestore
    Assert-True ($null -ne $script:Invoked) 'switched'
    if ($script:Invoked) {
        Assert-Equal 'solo:LG ULTRAGEAR' $script:Invoked.Key 'to the remembered mode'
        Assert-True (-not $script:Invoked.Silent) 'the set really changes, so say so in a balloon'
    }
}

Test-Case 'startup: the same session means the tray was restarted - do not touch the displays' {
    # Otherwise restarting the tray would undo Win+P or an edit made by hand in Windows settings.
    Set-RestoreScene
    Set-RememberedMode 'solo:LG ULTRAGEAR' (Get-SystemSessionId)
    Invoke-StartupRestore
    Assert-Null $script:Invoked 'left alone'
}

Test-Case 'startup: the right set already on means no balloon, only a layout check' {
    Set-RestoreScene
    Set-RememberedMode 'solo:XG27AQDMGR'
    Invoke-StartupRestore
    Assert-True ($null -ne $script:Invoked) 'still called - layout and primary may have drifted'
    if ($script:Invoked) { Assert-True $script:Invoked.Silent 'but silently' }
}

Test-Case 'startup: all-vs-work with the ASUS unplugged is the same desk, so no balloon' {
    # The mode keys differ while the desk is one: comparing by keys would declare a switch out of
    # something that is not happening.
    $script:TestState = @(
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' 'path-asus'      $false $true)
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ultragear' $true)
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-ultrafine' $true)
    )
    $script:Invoked = $null
    $script:SwitchedOnce = $false
    $script:TestSettings = Get-DefaultSettings
    Set-RememberedMode 'all'
    Invoke-StartupRestore
    Assert-True ($null -ne $script:Invoked) 'still checks the layout'
    if ($script:Invoked) { Assert-True $script:Invoked.Silent 'but silently - the same displays are on' }
}

Test-Case 'startup: a display that is not there is never restored to' {
    # The most expensive mistake there is: putting out a working monitor for the sake of one that is
    # not there is a black desk after the computer is turned on.
    Set-RestoreScene -UltraGearConnected $false
    Set-RememberedMode 'solo:LG ULTRAGEAR'
    Invoke-StartupRestore
    Assert-Null $script:Invoked 'nothing was turned off'
}

Test-Case 'startup: a mode key that no longer exists is not a crash' {
    Set-RestoreScene
    Set-RememberedMode 'solo:SOME OLD MONITOR'
    Invoke-StartupRestore
    Assert-Null $script:Invoked 'skipped'
}

Test-Case 'startup: a hotkey pressed first wins - his choice is newer than ours' {
    Set-RestoreScene
    Set-RememberedMode 'solo:LG ULTRAGEAR'
    $script:SwitchedOnce = $true
    Invoke-StartupRestore
    Assert-Null $script:Invoked 'we stay out of it'
}

Test-Case 'startup: turned off in settings means nothing happens' {
    Set-RestoreScene
    Set-RememberedMode 'solo:LG ULTRAGEAR'
    $script:TestSettings.restoreLastMode = $false
    Invoke-StartupRestore
    Assert-Null $script:Invoked 'off is off'
}

Test-Case 'startup: nothing remembered at all means nothing happens' {
    Set-RestoreScene
    if (Test-Path $script:LastModeFile) { Remove-Item $script:LastModeFile -Force }
    Invoke-StartupRestore
    Assert-Null $script:Invoked 'first run ever'
}

Test-Case 'session id: the same within one run, and not empty' {
    # "The tray was restarted, we leave the screens alone" rests on exactly this equality.
    $a = Get-SystemSessionId
    $b = Get-SystemSessionId
    Assert-Equal $a $b 'stable inside one process'
    Assert-True ($a.Length -gt 0) 'not empty'
    Assert-True ($a -like '*/*') 'built from both sources'
}
