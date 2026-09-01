# --- rebuilding the desk under a game ---------------------------------------
# The refresh-rate watchdog backed off before a full-screen application from the start, while the "the
# world changed by itself" path did not, and on 30 August at 19:58 it rebuilt the desk over a full-screen
# Chrome: the monitor put out at that moment took the window with it.
#
# Postponing is half the job; the other half is not forgetting afterwards. Leaving a borderless full
# screen comes with no event, so what was postponed is picked up by the tray's 15-second timer, and both
# ends are tested here.
#
# The functions are pulled out of Displays.ps1 by parsing the file — it cannot be dot-sourced, it brings
# the whole application up (the same trick as in 16-restore-on-start).

Write-Host ''
Write-Host 'rebuilding the desk while a game is on' -ForegroundColor White

$trayAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Displays.ps1'), [ref]$null, [ref]$null)
foreach ($name in 'Get-AvailableMode', 'Invoke-ReapplyMode', 'Invoke-ReapplyCheck') {
    $found = $trayAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }.GetNewClosure(), $true)
    if ($found.Count -ne 1) { throw "expected exactly one $name in Displays.ps1, found $($found.Count)" }
    . ([scriptblock]::Create($found[0].Extent.Text))
}

# The tray environment these functions expect around themselves. Its own rather than inherited from
# earlier files of cases: a test that reads somebody else's scene breaks when that scene is edited.
$script:RfSettings = New-TestSettings @{ Work = @('ULTRAGEAR', 'ULTRAFINE') }
$script:RfState = @()
$script:RfInvoked = $null
$script:RfRefreshed = $false

function Get-ActiveSettings { return $script:RfSettings }
function Get-CachedState { return $script:RfState }
function Update-StateCache { $script:RfRefreshed = $true }
# $script:RfSwitchWent is what the fake reports back through the same field the real Invoke-Mode sets:
# a switch can be refused (a busy mutex answers Skipped) or come to nothing (no monitor woke), and the
# postponed intent has to survive both.
$script:RfSwitchWent = $true
function Invoke-Mode {
    param([string]$Key, [switch]$Auto, [switch]$Silent)
    $script:RfInvoked = [pscustomobject]@{ Key = $Key; Auto = [bool]$Auto; Silent = [bool]$Silent }
    $script:LastSwitchWent = $script:RfSwitchWent
}

# Only the ASUS is on; both monitors from Work are connected but out.
function Set-ReapplyScene {
    $script:RfState = @(
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' 'path-asus'      $true)
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ultragear' $false)
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-ultrafine' $false)
    )
    $script:RfInvoked = $null
    $script:RfRefreshed = $false
    $script:ReapplyPending = $null
    $script:RfSwitchWent = $true
    $script:LastSwitchWent = $true
}

Test-Case 'reapply: a game on screen means the desk is not touched' {
    # Exactly the 30 August case: a configuration change kills a full-screen D3D device, and the monitor
    # goes out along with the window that was on it.
    function Test-FullscreenApp { $script:FullscreenWhy = 'the shell says 3 (QUNS_RUNNING_D3D_FULL_SCREEN)'; return $true }
    Set-ReapplyScene
    Invoke-ReapplyMode -Key 'combo:Work' -Reason 'a display went away'
    Assert-Null $script:RfInvoked 'the displays are left alone'
}

Test-Case 'reapply: what was postponed is remembered, not dropped' {
    # Forgetting would not be safer but worse: a monitor that went away leaves the layout drifted, and a
    # person coming out of a game expects an assembled desk.
    function Test-FullscreenApp { $script:FullscreenWhy = 'a game'; return $true }
    Set-ReapplyScene
    Invoke-ReapplyMode -Key 'combo:Work' -Reason 'a display went away'
    Assert-True ($null -ne $script:ReapplyPending) 'the intent is kept'
    if ($script:ReapplyPending) {
        Assert-Equal 'combo:Work' $script:ReapplyPending.Key 'the mode to assemble'
        Assert-Equal 'a display went away' $script:ReapplyPending.Reason 'and why, so the log still says it later'
    }
}

Test-Case 'reapply: the game closes and the postponed desk is assembled' {
    function Test-FullscreenApp { $script:FullscreenWhy = 'a game'; return $true }
    Set-ReapplyScene
    Invoke-ReapplyMode -Key 'combo:Work' -Reason 'a display went away'

    # The game closed. No configuration-changed event arrives for that — the timer picks it up, and that is
    # the only way to learn about leaving a full screen at all.
    function Test-FullscreenApp { return $false }
    Invoke-ReapplyCheck
    Assert-True ($null -ne $script:RfInvoked) 'the desk is assembled now'
    if ($script:RfInvoked) {
        Assert-Equal 'combo:Work' $script:RfInvoked.Key 'to the postponed mode'
        Assert-True $script:RfInvoked.Auto 'automatically, so the mode is not remembered as his choice'
    }
    Assert-True $script:RfRefreshed 'and the state was refreshed first - it went stale during the game'
    Assert-Null $script:ReapplyPending 'nothing is left pending'
}

Test-Case 'reapply: while the game is still on, the timer keeps its hands off' {
    function Test-FullscreenApp { $script:FullscreenWhy = 'a game'; return $true }
    Set-ReapplyScene
    Invoke-ReapplyMode -Key 'combo:Work' -Reason 'a display went away'
    Invoke-ReapplyCheck
    Assert-Null $script:RfInvoked 'still waiting'
    Assert-True ($null -ne $script:ReapplyPending) 'and still remembered'
}

Test-Case 'reapply: nothing postponed means the timer does nothing at all' {
    # The tick arrives every 15 seconds for the whole life of the tray, and in the vast majority of cases
    # it has nothing to do here.
    function Test-FullscreenApp { throw 'the guard must not even be asked when there is nothing to do' }
    Set-ReapplyScene
    Invoke-ReapplyCheck
    Assert-Null $script:RfInvoked 'no switch'
    Assert-True (-not $script:RfRefreshed) 'and not even a state refresh'
}

Test-Case 'reapply: a newer event replaces what was postponed' {
    # Two events in a row under one game: the desk has to be assembled for the latest one, everything else
    # is no longer true by that point.
    function Test-FullscreenApp { $script:FullscreenWhy = 'a game'; return $true }
    Set-ReapplyScene
    Invoke-ReapplyMode -Key 'combo:Work' -Reason 'a display went away'
    Invoke-ReapplyMode -Key 'all' -Reason 'a display was plugged in'
    Assert-Equal 'all' $script:ReapplyPending.Key 'the last one wins'
    Assert-Equal 'a display was plugged in' $script:ReapplyPending.Reason 'with its own reason'
}

Test-Case 'reapply: assembling the desk clears what was pending' {
    function Test-FullscreenApp { $script:FullscreenWhy = 'a game'; return $true }
    Set-ReapplyScene
    Invoke-ReapplyMode -Key 'combo:Work' -Reason 'a display went away'

    function Test-FullscreenApp { return $false }
    Invoke-ReapplyMode -Key 'all' -Reason 'a display was plugged in'
    Assert-Null $script:ReapplyPending 'a fresh event that ran is newer than anything waiting'
}

Test-Case 'reapply: a switch that did not go through keeps what was postponed' {
    # The game ending is itself a configuration change, so the refresh-rate watchdog is holding the mutex
    # for about a second exactly when the timer drains this — and a monitor still in deep sleep answers
    # nothing at all. Dropping the intent on either left the desk drifted for good.
    function Test-FullscreenApp { return $false }
    Set-ReapplyScene
    $script:RfSwitchWent = $false

    Invoke-ReapplyMode -Key 'combo:Work' -Reason 'a display went away'
    Assert-True ($null -ne $script:RfInvoked) 'the switch was attempted'
    Assert-True ($null -ne $script:ReapplyPending) 'and what was postponed is still waiting'
    Assert-Equal 'combo:Work' $script:ReapplyPending.Key 'with the same mode'
    Assert-Equal 'a display went away' $script:ReapplyPending.Reason 'and the same reason'
}

Test-Case 'reapply: the retry after a refused switch clears it once it goes through' {
    function Test-FullscreenApp { return $false }
    Set-ReapplyScene
    $script:RfSwitchWent = $false
    Invoke-ReapplyMode -Key 'combo:Work' -Reason 'a display went away'

    $script:RfSwitchWent = $true
    Invoke-ReapplyCheck
    Assert-Null $script:ReapplyPending 'the desk is assembled, nothing is left waiting'
}

Test-Case 'reapply: a mode that is not available is not postponed forever' {
    # Otherwise an intention that will never be carried out would survive every game and every tick of the
    # timer.
    function Test-FullscreenApp { return $false }
    Set-ReapplyScene
    Invoke-ReapplyMode -Key 'solo:SOME OLD MONITOR' -Reason 'a display went away'
    Assert-Null $script:RfInvoked 'nothing was switched'
    Assert-Null $script:ReapplyPending 'and nothing is left waiting'
}

# --- what is only testable by its text --------------------------------------
# Two links live in places that cannot be executed whole: the timer's body brings the application up, and
# Invoke-Mode reaches into the icon, the balloons and Switch-DisplayMode. Both are mandatory all the same:
# without the first what was postponed is never picked up, and without the second it lands on top of what
# a person chose by hand.

Test-Case 'reapply: the tray timer really calls the postponed check' {
    $timer = $trayAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $n.Member.Value -eq 'add_Tick' }, $true)
    Assert-True ($timer.Count -ge 1) 'the tick handler is there'
    $ticks = @($timer | ForEach-Object { $_.Parent.Extent.Text }) -join "`n"
    Assert-True ($ticks -match 'Invoke-ReapplyCheck') 'and it drains what the full-screen guard postponed'
}

Test-Case 'reapply: switching by hand cancels what was postponed' {
    $fn = $trayAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Mode' }, $true)
    Assert-Equal 1 $fn.Count 'Invoke-Mode is where a hand on the hotkey arrives'

    # In the "a person switched" branch specifically: a reset in the shared body would also cancel what an
    # automatic path had only just postponed.
    $byHand = $fn[0].Body.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.IfStatementAst] -and
        $n.Clauses[0].Item1.Extent.Text -match '-not\s+\$Auto' }, $true)
    Assert-True ($byHand.Count -ge 1) 'the branch for a switch made by hand exists'
    $body = @($byHand | ForEach-Object { $_.Extent.Text }) -join "`n"
    Assert-True ($body -match '\$script:ReapplyPending\s*=\s*\$null') 'and it drops the postponed intent'
}
