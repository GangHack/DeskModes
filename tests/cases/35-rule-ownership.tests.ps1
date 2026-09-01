# --- who owns the desk after a rule fires ------------------------------------
# Get-RuleDecision decides what should happen (20-rules); this is the other half — what the tray does
# with the answer. The distinction that matters here is between a switch that HAPPENED and one that was
# refused, and it is not academic: a rule fires on the very events the refresh-rate watchdog wakes on,
# and that one holds Local\ScreenDeckSwitch for about a second afterwards. "A switch is already in
# progress" is therefore an ordinary answer here, not a breakage.
#
# Claiming the desk after a switch that never happened cost the rule its turn: the next tick saw the
# mode unchanged and let go with "the displays were changed by hand" — about a person who had touched
# nothing — and on a desk matching no known mode the rule stayed owned, without ever having switched,
# until the condition ended. At the other end it was worse: letting go before the way back had gone
# through left the desk in the rule's mode for good, because the condition has ended and nothing comes
# back this way to try again.
#
# The functions are pulled out of Displays.ps1 by parsing the file — it cannot be dot-sourced, it brings
# the whole application up (the same trick as in 16-restore-on-start).

Write-Host ''
Write-Host 'who owns the desk after a rule fires' -ForegroundColor White

$trayAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Displays.ps1'), [ref]$null, [ref]$null)
foreach ($name in 'Reset-RuleOwnership', 'Invoke-RulesCheck') {
    $found = $trayAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }.GetNewClosure(), $true)
    if ($found.Count -ne 1) { throw "expected exactly one $name in Displays.ps1, found $($found.Count)" }
    . ([scriptblock]::Create($found[0].Extent.Text))
}

# The tray environment these two expect around themselves. Its own rather than inherited from earlier
# files of cases: a test that reads somebody else's scene breaks when that scene is edited.
$script:RoSettings = Get-DefaultSettings
$script:RoMode = ''
$script:RoInvoked = @()
$script:RoWent = $true
$script:RoSkipped = $false

# The rule's condition is a process that is really running: our own. Get-Process is NOT shadowed for
# this — it is a built-in, and a fake by that name is a trap for whoever reads the next test — so the
# scene names a process that exists (this host) or one that cannot (a name nothing is called).
$script:RoLive = (Get-Process -Id $PID).ProcessName
$script:RoDead = 'screendeck-no-such-process'

function Get-ActiveSettings { return $script:RoSettings }
function Get-CurrentModeKey { return $script:RoMode }
# The fake reports back through the same two fields the real Invoke-Mode sets.
function Invoke-Mode {
    param([string]$Key, [switch]$Auto, [switch]$Silent)
    $script:RoInvoked += [string]$Key
    $script:LastSwitchWent = $script:RoWent
    $script:LastSwitchSkipped = $script:RoSkipped
}

# One rule: while that process is running, the desk belongs to the game display.
function Set-RuleScene {
    param([bool]$Skipped = $false, [string]$Mode = 'combo:Work', [bool]$Running = $true,
          [string]$Back = '')

    $script:RoSettings = Get-DefaultSettings
    $script:RoSettings.rules = @([ordered]@{
        when = 'process'; minutes = 0
        process = $(if ($Running) { $script:RoLive } else { $script:RoDead })
        mode = 'solo:GAME'; back = $Back; enabled = $true })
    $script:RoMode = $Mode
    $script:RoInvoked = @()
    $script:RoWent = (-not $Skipped)
    $script:RoSkipped = $Skipped
    Reset-RuleOwnership
}

Test-Case 'rule: a switch that happened takes the desk' {
    Set-RuleScene
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME' ($script:RoInvoked -join ',') 'switched once, to the mode the rule names'
    Assert-Equal 0 $script:RuleOwnedIndex 'and the rule owns the desk from now on'
    Assert-Equal 'combo:Work' $script:RuleOwnedBack 'remembering where to give it back'
}

Test-Case 'rule: a switch refused by a busy mutex claims nothing, and the next tick asks again' {
    Set-RuleScene -Skipped $true
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME' ($script:RoInvoked -join ',') 'it tried'
    Assert-Equal -1 $script:RuleOwnedIndex 'but owns nothing - the desk never moved'

    # Fifteen seconds later, and this time the mutex is free.
    $script:RoWent = $true
    $script:RoSkipped = $false
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME,solo:GAME' ($script:RoInvoked -join ',') 'asked again instead of letting go'
    Assert-Equal 0 $script:RuleOwnedIndex 'and now it owns the desk'
}

Test-Case 'rule: a desk matching no known mode does not trap a rule that never switched' {
    # The worst of the two. With an empty current mode the release branch does not fire either - it only
    # fires on a mode that DIFFERS - so the claim the rule never earned used to hold until the game was
    # closed. The way back has to be written into the rule here: without one, a desk matching no mode is
    # 'blocked' and the rule does not fire at all (see Get-RuleDecision).
    Set-RuleScene -Skipped $true -Mode '' -Back 'combo:Work'
    Invoke-RulesCheck
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME,solo:GAME' ($script:RoInvoked -join ',') 'tried on both ticks'
    Assert-Equal -1 $script:RuleOwnedIndex 'and never claimed what it did not take'
}

Test-Case 'rule: a switch that failed for another reason keeps the claim, so as not to nag' {
    # "That display is not connected" will not come right by being asked again fifteen seconds later,
    # and a retry loop there is a balloon every fifteen seconds. Only a busy mutex means "ask again".
    Set-RuleScene
    $script:RoWent = $false
    $script:RoSkipped = $false
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME' ($script:RoInvoked -join ',') 'it tried once'
    Assert-Equal 0 $script:RuleOwnedIndex 'and the claim stands - the next tick will let go quietly'
}

Test-Case 'rule: the way back is not let go of until the desk really came back' {
    # The game is closed, the rule owns the desk, and the switch back is refused. Letting go here left
    # the person on the game display for good: the condition has ended, so this way is never taken again.
    Set-RuleScene -Skipped $true -Mode 'solo:GAME' -Running $false
    $script:RuleOwnedIndex = 0
    $script:RuleOwnedBack = 'combo:Work'
    Invoke-RulesCheck

    Assert-Equal 'combo:Work' ($script:RoInvoked -join ',') 'it tried to hand the desk back'
    Assert-Equal 0 $script:RuleOwnedIndex 'and held on to it, because the switch did not go through'

    # The next tick, with the mutex free.
    $script:RoWent = $true
    $script:RoSkipped = $false
    Invoke-RulesCheck

    Assert-Equal 'combo:Work,combo:Work' ($script:RoInvoked -join ',') 'tried again'
    Assert-Equal -1 $script:RuleOwnedIndex 'and only now let go'
}

Test-Case 'rule: a way back that goes through is let go of at once' {
    Set-RuleScene -Mode 'solo:GAME' -Running $false
    $script:RuleOwnedIndex = 0
    $script:RuleOwnedBack = 'combo:Work'
    Invoke-RulesCheck

    Assert-Equal 'combo:Work' ($script:RoInvoked -join ',') 'handed the desk back'
    Assert-Equal -1 $script:RuleOwnedIndex 'and owns nothing any more'
}
