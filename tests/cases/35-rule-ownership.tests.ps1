# --- who owns the desk after a rule fires ------------------------------------
# Get-RuleDecision decides what should happen (20-rules); this is the other half — what the tray does
# with the answer. The distinction that matters here is between a switch that HAPPENED and one that was
# refused, and it is not academic: a rule fires on the very events the refresh-rate watchdog wakes on,
# and that one holds Local\DeskModesSwitch for about a second afterwards. "A switch is already in
# progress" is therefore an ordinary answer here, not a breakage.
#
# Claiming the desk after a switch that never happened cost the rule its turn: the next tick saw the
# mode unchanged and let go with "the displays were changed by hand" — about a person who had touched
# nothing — and on a desk matching no known mode the rule stayed owned, without ever having switched,
# until the condition ended. At the other end it was worse: letting go before the way back had gone
# through left the desk in the rule's mode for good, because the condition has ended and nothing comes
# back this way to try again.
#
# The functions come out of Displays.ps1 by parsing it — see Get-TrayFunctionSource in tests\fakes.ps1.

Write-Host ''
Write-Host 'who owns the desk after a rule fires' -ForegroundColor White

. (Get-TrayFunctionSource 'Get-RuleModeMemberIds', 'Test-RuleSwitchHasActiveAnchor', 'New-RuleDeskClaim', 'Get-RuleDeskRelation',
                          'Reset-RuleOwnership', 'Invoke-RulesCheck')
# Invoke-RulesCheck reads this to know when to stop offering the desk back; the tray's own number.
. (Get-TrayVariableSource '$script:AutoRetryLimit', '$script:StateCacheGeneration')

# The tray environment these two expect around themselves. Its own rather than inherited from earlier
# files of cases: a test that reads somebody else's scene breaks when that scene is edited.
$script:RoSettings = Get-DefaultSettings
$script:RoMode = ''
$script:RoInvoked = @()
$script:RoState = @()
$script:RoPartialActive = @()
$script:RoPartialMode = ''
$script:RoRefreshSucceeds = $true
# The answer the fake gives, in the tray's vocabulary: 'done' landed, 'busy' is the mutex the
# refresh-rate watchdog holds for a second after every switch, 'partial' is a display that never woke,
# 'refused' is Windows turning the whole configuration down. All four arrive here in real life.
$script:RoOutcome = 'done'

# The rule's condition is a process that is really running: our own. Get-Process is NOT shadowed for
# this — it is a built-in, and a fake by that name is a trap for whoever reads the next test — so the
# scene names a process that exists (this host) or one that cannot (a name nothing is called).
$script:RoLive = (Get-Process -Id $PID).ProcessName
$script:RoDead = 'deskmodes-no-such-process'

function Get-ActiveSettings { return $script:RoSettings }
function Get-CurrentModeKey { return $script:RoMode }
function Get-CachedState { return $script:RoState }

function Set-RoActiveDesk {
    param([string[]]$Labels, [string]$ModeKey)

    foreach ($display in $script:RoState) { $display.Active = ($Labels -contains [string]$display.Label) }
    $script:RoMode = $ModeKey
}

function Set-RoModeDesk {
    param([string]$ModeKey)

    $mode = @(Get-DisplayModes -State $script:RoState -Settings $script:RoSettings |
              Where-Object { [string]$_.Key -eq $ModeKey } | Select-Object -First 1)[0]
    $ids = @()
    if ($mode) {
        $ids = @(Get-ModeMembers -Mode $mode -State $script:RoState | ForEach-Object { [string]$_.Id })
    }
    foreach ($display in $script:RoState) { $display.Active = ($ids -contains [string]$display.Id) }
    $script:RoMode = $ModeKey
}

# The fake reports back through the same object the real Invoke-Mode leaves behind it.
function Invoke-Mode {
    param([string]$Key, [switch]$Auto, [switch]$Silent)
    $script:RoInvoked += [string]$Key
    Set-FakeSwitchOutcome -Outcome $script:RoOutcome -ModeKey $Key
    if ($script:RoRefreshSucceeds) {
        $script:StateCacheGeneration++
        if ($script:RoOutcome -eq 'done') { Set-RoModeDesk -ModeKey $Key }
        elseif ($script:RoOutcome -eq 'partial') {
            if ($script:RoPartialActive.Count -gt 0) {
                Set-RoActiveDesk -Labels $script:RoPartialActive -ModeKey $script:RoPartialMode
            }
            else { Set-RoModeDesk -ModeKey $Key }
        }
    }
}

# One rule: while that process is running, the desk belongs to the game display.
function Set-RuleScene {
    param([string]$Outcome = 'done', [string]$Mode = 'combo:Work', [bool]$Running = $true,
          [string]$Back = '', [bool]$TargetReady = $true)

    $script:RoSettings = Get-DefaultSettings
    $script:RoSettings.combos['Work'] = [ordered]@{ displays = @('WORK'); primary = '' }
    $script:RoSettings.rules = @([ordered]@{
        when = 'process'; minutes = 0
        process = $(if ($Running) { $script:RoLive } else { $script:RoDead })
        mode = 'solo:GAME'; back = $Back; enabled = $true })
    $script:RoState = @(
        (New-FakeMonitor 'GAME' 'GAME' 'game' $false)
        (New-FakeMonitor 'WORK' 'WORK' 'work' $false)
        (New-FakeMonitor 'OTHER' 'OTHER' 'other' $false)
    )
    Set-RoModeDesk -ModeKey $Mode
    if ($TargetReady) { @($script:RoState | Where-Object Label -eq 'GAME')[0].Active = $true }
    $script:RoInvoked = @()
    $script:RoOutcome = $Outcome
    $script:RoPartialActive = @()
    $script:RoPartialMode = ''
    $script:RoRefreshSucceeds = $true
    Reset-RuleOwnership
}

# The rule has taken the desk and holds it: what the tray looks like on the tick after a switch that
# landed. Set by hand rather than by running a tick, so that a test about the way back does not depend on
# the way there.
function Set-RuleOwned {
    $script:RuleOwnedIndex = 0
    $script:RuleOwnedBack = 'combo:Work'
    $script:RuleOwnedSig = Get-RuleSignature -Rule $script:RoSettings.rules[0]
    $script:RuleOwnedTaken = $true
    $script:RuleReturnTries = 0
}

Test-Case 'rule: an inactive destination cannot take away every active display' {
    Set-RuleScene -TargetReady:$false
    Invoke-RulesCheck

    Assert-Equal 0 $script:RoInvoked.Count 'the rule leaves the working display alone'
    Assert-Equal -1 $script:RuleOwnedIndex 'the rule claims no desk it did not switch'
}

Test-Case 'rule: a switch that happened takes the desk' {
    Set-RuleScene
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME' ($script:RoInvoked -join ',') 'switched once, to the mode the rule names'
    Assert-Equal 0 $script:RuleOwnedIndex 'and the rule owns the desk from now on'
    Assert-Equal 'combo:Work' $script:RuleOwnedBack 'remembering where to give it back'
    Assert-True $script:RuleOwnedTaken 'and the desk really is its own'
    Assert-True ($script:RuleOwnedSig -ne '') 'remembered by identity, not by its place in the list'
}

Test-Case 'rule: a switch refused by a busy mutex claims nothing, and the next tick asks again' {
    Set-RuleScene -Outcome 'busy'
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME' ($script:RoInvoked -join ',') 'it tried'
    Assert-Equal -1 $script:RuleOwnedIndex 'but owns nothing - the desk never moved'

    # Fifteen seconds later, and this time the mutex is free.
    $script:RoOutcome = 'done'
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME,solo:GAME' ($script:RoInvoked -join ',') 'asked again instead of letting go'
    Assert-Equal 0 $script:RuleOwnedIndex 'and now it owns the desk'
}

Test-Case 'rule: a desk matching no known mode does not trap a rule that never switched' {
    # The worst of the two. With an empty current mode the release branch does not fire either - it only
    # fires on a mode that DIFFERS - so the claim the rule never earned used to hold until the game was
    # closed. The way back has to be written into the rule here: without one, a desk matching no mode is
    # 'blocked' and the rule does not fire at all (see Get-RuleDecision).
    Set-RuleScene -Outcome 'busy' -Mode '' -Back 'combo:Work'
    Invoke-RulesCheck
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME,solo:GAME' ($script:RoInvoked -join ',') 'tried on both ticks'
    Assert-Equal -1 $script:RuleOwnedIndex 'and never claimed what it did not take'
}

Test-Case 'rule: a display that did not come up still means the desk moved' {
    # 'partial' is a switch that RAN: the topology went over, one display did not attach. The desk is the
    # rule's — a screen that stayed dark does not undo the ones that lit — and pretending otherwise would
    # have the rule fire again on the very next tick, with a warning balloon each time.
    Set-RuleScene -Outcome 'partial'
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME' ($script:RoInvoked -join ',') 'switched once'
    Assert-Equal 0 $script:RuleOwnedIndex 'and holds the desk'
    Assert-True $script:RuleOwnedTaken 'as its own'
}

Test-Case 'rule: a partial switch stays owned until the condition ends and returns to the original desk' {
    $script:RoSettings = Get-DefaultSettings
    $script:RoSettings.combos['AB'] = [ordered]@{ displays = @('A', 'B'); primary = '' }
    $script:RoSettings.rules = @([ordered]@{
        when = 'process'; minutes = 0; process = 'audit-game'
        mode = 'combo:AB'; back = ''; enabled = $true })
    $script:RoState = @(
        (New-FakeMonitor 'A' 'A' 'a')
        (New-FakeMonitor 'B' 'B' 'b')
        (New-FakeMonitor 'C' 'C' 'c')
    )
    $script:RoMode = 'all'
    $script:RoInvoked = @()
    $script:RoOutcome = 'partial'
    $script:RoPartialActive = @('A')
    $script:RoPartialMode = 'solo:A'
    $script:RoProcesses = @([pscustomobject]@{ ProcessName = 'audit-game' })
    function Get-Process {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped process fake drives a condition across rule ticks.')]
        param([string]$ErrorAction)
        return $script:RoProcesses
    }
    Reset-RuleOwnership

    Invoke-RulesCheck
    Invoke-RulesCheck
    $script:RoProcesses = @()
    $script:RoOutcome = 'done'
    Invoke-RulesCheck

    Assert-Equal 'combo:AB,all' ($script:RoInvoked -join ',') 'the partial desk is held and then returned to All'
    Assert-Equal -1 $script:RuleOwnedIndex 'the claim ends only after the return goes through'
}

Test-Case 'rule: an equivalent combination name is still the desk the rule switched to' {
    $script:RoSettings = Get-DefaultSettings
    $script:RoSettings.combos['AB'] = [ordered]@{ displays = @('A', 'B'); primary = '' }
    $script:RoSettings.combos['Alias'] = [ordered]@{ displays = @('A', 'B'); primary = '' }
    $script:RoSettings.rules = @([ordered]@{
        when = 'process'; minutes = 0; process = 'audit-game'
        mode = 'combo:AB'; back = ''; enabled = $true })
    $script:RoState = @(
        (New-FakeMonitor 'A' 'A' 'a')
        (New-FakeMonitor 'B' 'B' 'b')
        (New-FakeMonitor 'C' 'C' 'c')
    )
    $script:RoMode = 'all'
    $script:RoInvoked = @()
    $script:RoOutcome = 'done'
    $script:RoPartialActive = @()
    $script:RoPartialMode = ''
    $script:RoProcesses = @([pscustomobject]@{ ProcessName = 'audit-game' })
    function Get-Process {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped process fake drives a condition across rule ticks.')]
        param([string]$ErrorAction)
        return $script:RoProcesses
    }
    Reset-RuleOwnership

    Invoke-RulesCheck
    $script:RoMode = 'combo:Alias'
    Invoke-RulesCheck
    $script:RoProcesses = @()
    Invoke-RulesCheck

    Assert-Equal 'combo:AB,all' ($script:RoInvoked -join ',') 'an alias neither releases nor loses the original way back'
}

Test-Case 'rule: a source display left on by a partial switch may go out without losing ownership' {
    $script:RoSettings = Get-DefaultSettings
    $script:RoSettings.combos['AB'] = [ordered]@{ displays = @('A', 'B'); primary = '' }
    $script:RoSettings.rules = @([ordered]@{
        when = 'process'; minutes = 0; process = 'audit-game'
        mode = 'combo:AB'; back = ''; enabled = $true })
    $script:RoState = @(
        (New-FakeMonitor 'A' 'A' 'a')
        (New-FakeMonitor 'B' 'B' 'b')
        (New-FakeMonitor 'C' 'C' 'c')
    )
    $script:RoMode = 'all'
    $script:RoInvoked = @()
    $script:RoOutcome = 'partial'
    $script:RoPartialActive = @('A', 'B', 'C')
    $script:RoPartialMode = 'all'
    $script:RoProcesses = @([pscustomobject]@{ ProcessName = 'audit-game' })
    function Get-Process {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped process fake drives a condition across rule ticks.')]
        param([string]$ErrorAction)
        return $script:RoProcesses
    }
    Reset-RuleOwnership

    Invoke-RulesCheck
    Set-RoActiveDesk -Labels @('A', 'B') -ModeKey 'combo:AB'
    Invoke-RulesCheck
    $script:RoProcesses = @()
    $script:RoOutcome = 'done'
    Invoke-RulesCheck

    Assert-Equal 'combo:AB,all' ($script:RoInvoked -join ',') 'the late departure is accepted and the original desk returns'
}

Test-Case 'rule: a newly introduced display is a manual change and releases the claim' {
    $script:RoSettings = Get-DefaultSettings
    $script:RoSettings.combos['AB'] = [ordered]@{ displays = @('A', 'B'); primary = '' }
    $script:RoSettings.rules = @([ordered]@{
        when = 'process'; minutes = 0; process = 'audit-game'
        mode = 'combo:AB'; back = ''; enabled = $true })
    $script:RoState = @(
        (New-FakeMonitor 'A' 'A' 'a')
        (New-FakeMonitor 'B' 'B' 'b')
        (New-FakeMonitor 'C' 'C' 'c')
        (New-FakeMonitor 'D' 'D' 'd' $false)
    )
    $script:RoMode = 'all'
    $script:RoInvoked = @()
    $script:RoOutcome = 'done'
    $script:RoPartialActive = @()
    $script:RoPartialMode = ''
    $script:RoProcesses = @([pscustomobject]@{ ProcessName = 'audit-game' })
    function Get-Process {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped process fake drives a condition across rule ticks.')]
        param([string]$ErrorAction)
        return $script:RoProcesses
    }
    Reset-RuleOwnership

    Invoke-RulesCheck
    Set-RoActiveDesk -Labels @('A', 'B', 'D') -ModeKey ''
    Invoke-RulesCheck

    Assert-Equal 'combo:AB' ($script:RoInvoked -join ',') 'the rule does not fight the different desk'
    Assert-Equal -1 $script:RuleOwnedIndex 'and releases its claim'
}

Test-Case 'rule: a failed post-switch cache refresh defers judgment and preserves the way back' {
    $script:RoSettings = Get-DefaultSettings
    $script:RoSettings.combos['AB'] = [ordered]@{ displays = @('A', 'B'); primary = '' }
    $script:RoSettings.rules = @([ordered]@{
        when = 'process'; minutes = 0; process = 'audit-game'
        mode = 'combo:AB'; back = ''; enabled = $true })
    $script:RoState = @(
        (New-FakeMonitor 'A' 'A' 'a')
        (New-FakeMonitor 'B' 'B' 'b')
        (New-FakeMonitor 'C' 'C' 'c')
    )
    $script:RoMode = 'all'
    $script:RoInvoked = @()
    $script:RoOutcome = 'done'
    $script:RoRefreshSucceeds = $false
    $script:RoProcesses = @([pscustomobject]@{ ProcessName = 'audit-game' })
    function Get-Process {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped process fake drives a condition across rule ticks.')]
        param([string]$ErrorAction)
        return $script:RoProcesses
    }
    Reset-RuleOwnership

    Invoke-RulesCheck
    Assert-True (-not $script:RuleOwnedDesk.Known) 'the stale source cache is not recorded as the result'
    Invoke-RulesCheck
    $script:RoProcesses = @()
    $script:RoRefreshSucceeds = $true
    Invoke-RulesCheck

    Assert-Equal 'combo:AB,all' ($script:RoInvoked -join ',') 'uncertainty neither releases early nor loses the original desk'
}

Test-Case 'rule: a provisional claim resolves on a later fresh target and then detects a new display' {
    $script:RoSettings = Get-DefaultSettings
    $script:RoSettings.combos['AB'] = [ordered]@{ displays = @('A', 'B'); primary = '' }
    $script:RoSettings.rules = @([ordered]@{
        when = 'process'; minutes = 0; process = 'audit-game'
        mode = 'combo:AB'; back = ''; enabled = $true })
    $script:RoState = @(
        (New-FakeMonitor 'A' 'A' 'a')
        (New-FakeMonitor 'B' 'B' 'b' $false)
        (New-FakeMonitor 'C' 'C' 'c' $false)
    )
    $script:RoMode = 'solo:A'
    $script:RoInvoked = @()
    $script:RoOutcome = 'done'
    $script:RoRefreshSucceeds = $false
    $script:RoProcesses = @([pscustomobject]@{ ProcessName = 'audit-game' })
    function Get-Process {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped process fake drives a condition across rule ticks.')]
        param([string]$ErrorAction)
        return $script:RoProcesses
    }
    Reset-RuleOwnership

    Invoke-RulesCheck
    Assert-True (-not $script:RuleOwnedDesk.Known) 'the failed refresh leaves a provisional claim'
    Set-RoActiveDesk -Labels @('A', 'B') -ModeKey 'combo:AB'
    $script:StateCacheGeneration++
    Invoke-RulesCheck
    Assert-True $script:RuleOwnedDesk.Known 'a newer successful observation resolves the claim'

    Set-RoActiveDesk -Labels @('A', 'B', 'C') -ModeKey ''
    $script:StateCacheGeneration++
    Invoke-RulesCheck

    Assert-Equal 'combo:AB' ($script:RoInvoked -join ',') 'the rule does not fight the later different desk'
    Assert-Equal -1 $script:RuleOwnedIndex 'the new display releases the resolved claim'
}

Test-Case 'rule: a provisional claim releases when its first fresh observation is unrelated' {
    $script:RoSettings = Get-DefaultSettings
    $script:RoSettings.combos['AB'] = [ordered]@{ displays = @('A', 'B'); primary = '' }
    $script:RoSettings.rules = @([ordered]@{
        when = 'process'; minutes = 0; process = 'audit-game'
        mode = 'combo:AB'; back = ''; enabled = $true })
    $script:RoState = @(
        (New-FakeMonitor 'A' 'A' 'a')
        (New-FakeMonitor 'B' 'B' 'b' $false)
        (New-FakeMonitor 'C' 'C' 'c' $false)
    )
    $script:RoMode = 'solo:A'
    $script:RoInvoked = @()
    $script:RoOutcome = 'done'
    $script:RoRefreshSucceeds = $false
    $script:RoProcesses = @([pscustomobject]@{ ProcessName = 'audit-game' })
    function Get-Process {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped process fake drives a condition across rule ticks.')]
        param([string]$ErrorAction)
        return $script:RoProcesses
    }
    Reset-RuleOwnership

    Invoke-RulesCheck
    Set-RoActiveDesk -Labels @('C') -ModeKey 'solo:C'
    $script:StateCacheGeneration++
    Invoke-RulesCheck

    Assert-Equal 'combo:AB' ($script:RoInvoked -join ',') 'the rule makes no corrective switch'
    Assert-Equal -1 $script:RuleOwnedIndex 'the first fresh unrelated desk releases the claim'
}

Test-Case 'rule: a manual display change wins when the condition ends on the same tick' {
    Set-RuleScene -Mode 'combo:Work'
    $script:RoProcesses = @([pscustomobject]@{ ProcessName = $script:RoLive })
    function Get-Process {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped process fake ends a condition without editing its rule signature.')]
        param([string]$ErrorAction)
        return $script:RoProcesses
    }
    Invoke-RulesCheck
    Set-RoActiveDesk -Labels @('GAME', 'OTHER') -ModeKey ''
    $script:StateCacheGeneration++
    $script:RoProcesses = @()
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME' ($script:RoInvoked -join ',') 'the ended rule does not restore over a manual desk'
    Assert-Equal -1 $script:RuleOwnedIndex 'the manual desk releases the claim'
}

Test-Case 'rule: a manual display change wins when the owning rule is removed on the same tick' {
    Set-RuleScene -Mode 'combo:Work'
    Invoke-RulesCheck
    Set-RoActiveDesk -Labels @('GAME', 'OTHER') -ModeKey ''
    $script:StateCacheGeneration++
    $script:RoSettings.rules = @()
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME' ($script:RoInvoked -join ',') 'the removed rule does not restore over a manual desk'
    Assert-Equal -1 $script:RuleOwnedIndex 'the manual desk releases the orphaned claim'
}

Test-Case 'rule: its own partial return is retried instead of mistaken for a manual desk' {
    Set-RuleScene -Mode 'combo:Work'
    Invoke-RulesCheck
    $script:RoSettings.rules[0].process = $script:RoDead
    $script:RoOutcome = 'partial'
    $script:RoPartialActive = @('OTHER')
    $script:RoPartialMode = 'solo:OTHER'
    Invoke-RulesCheck
    Assert-Equal 1 $script:RuleReturnTries 'the partial return remains pending'

    $script:RoOutcome = 'done'
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME,combo:Work,combo:Work' ($script:RoInvoked -join ',') 'the next tick retries the return'
    Assert-Equal -1 $script:RuleOwnedIndex 'the successful retry ends ownership'
}

Test-Case 'rule: an empty or unrelated observation establishes no physical claim' {
    $empty = New-RuleDeskClaim -RequestedIds @('a') -State @() -Fresh $true
    Assert-True (-not $empty.Known) 'an empty cache proves nothing'
    Assert-Equal 'unknown' (Get-RuleDeskRelation -Claim $empty -State @()) 'and remains unknown on comparison'

    $state = @((New-FakeMonitor 'C' 'C' 'c'))
    $unrelated = New-RuleDeskClaim -RequestedIds @('a', 'b') -State $state -Fresh $true
    Assert-True (-not $unrelated.Known) 'a partial result with no requested display establishes no claim'
}

Test-Case 'rule: a switch Windows refused keeps the claim, but not as a desk of its own' {
    # "That display is not connected" will not come right by being asked again fifteen seconds later, and
    # a retry loop there is a balloon every fifteen seconds. So the claim is kept to keep the rule quiet —
    # and marked as never taken, which is what stops the next tick lying about it.
    Set-RuleScene -Outcome 'refused'
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME' ($script:RoInvoked -join ',') 'it tried once'
    Assert-Equal 0 $script:RuleOwnedIndex 'and the claim stands, so the rule does not fire again'
    Assert-True (-not $script:RuleOwnedTaken) "but the desk is nobody's, and the state says so"
}

Test-Case 'rule: a claim never taken waits out the condition in silence' {
    # This is the tick that used to lie. The claim stood, the desk had not moved, and the release branch
    # fired with "the displays were changed by hand" - about a person who had touched nothing. Then the
    # rule fired again, failed again, and the pair repeated every thirty seconds for as long as the
    # condition lasted.
    Set-RuleScene -Outcome 'refused'
    Invoke-RulesCheck
    Invoke-RulesCheck
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME' ($script:RoInvoked -join ',') 'one attempt in all, not one per tick'
    Assert-Equal 0 $script:RuleOwnedIndex 'the claim is still held'
    Assert-True (-not $script:RuleOwnedTaken) 'and still says the desk was never taken'
}

Test-Case 'rule: a claim never taken lets go without moving a screen' {
    # The same state, with the condition over. There is nothing to give back — the desk never left the
    # person — and switching "back" here would move the screens for the first time on the way OUT of a
    # rule, which is the one thing a rule that failed must not manage to do.
    Set-RuleScene -Running $false
    $script:RuleOwnedIndex = 0
    $script:RuleOwnedBack = 'combo:Work'
    $script:RuleOwnedSig = Get-RuleSignature -Rule $script:RoSettings.rules[0]
    $script:RuleOwnedTaken = $false
    Invoke-RulesCheck

    Assert-Equal '' ($script:RoInvoked -join ',') 'not a single switch'
    Assert-Equal -1 $script:RuleOwnedIndex 'and it let go'
}

Test-Case 'rule: the way back is not let go of until the desk really came back' {
    # The game is closed, the rule owns the desk, and the switch back is refused. Letting go here left
    # the person on the game display for good: the condition has ended, so this way is never taken again.
    # The old test was "was it a busy mutex" — so Windows refusing the configuration once was enough to
    # strand them, which is why 'refused' is what this drives it with.
    Set-RuleScene -Outcome 'refused' -Mode 'solo:GAME' -Running $false
    Set-RuleOwned
    Invoke-RulesCheck

    Assert-Equal 'combo:Work' ($script:RoInvoked -join ',') 'it tried to hand the desk back'
    Assert-Equal 0 $script:RuleOwnedIndex 'and held on to it, because the switch did not go through'

    # The next tick, and this time it goes through.
    $script:RoOutcome = 'done'
    Invoke-RulesCheck

    Assert-Equal 'combo:Work,combo:Work' ($script:RoInvoked -join ',') 'tried again'
    Assert-Equal -1 $script:RuleOwnedIndex 'and only now let go'
}

Test-Case 'rule: offering the desk back is bounded, and then it stops asking' {
    # The other half of the same decision. Holding on for ever is a warning balloon every fifteen seconds
    # until bedtime; the desk is something a person can move themselves, a balloon storm is not.
    Set-RuleScene -Outcome 'refused' -Mode 'solo:GAME' -Running $false
    Set-RuleOwned

    for ($i = 1; $i -le $script:AutoRetryLimit; $i++) { Invoke-RulesCheck }

    Assert-Equal $script:AutoRetryLimit $script:RoInvoked.Count 'it tried the way back as many times as allowed'
    Assert-Equal -1 $script:RuleOwnedIndex 'and let go rather than keep asking'

    Invoke-RulesCheck
    Assert-Equal $script:AutoRetryLimit $script:RoInvoked.Count 'the tick after changes nothing'
}

Test-Case 'rule: a way back that goes through is let go of at once' {
    Set-RuleScene -Mode 'solo:GAME' -Running $false
    Set-RuleOwned
    Invoke-RulesCheck

    Assert-Equal 'combo:Work' ($script:RoInvoked -join ',') 'handed the desk back'
    Assert-Equal -1 $script:RuleOwnedIndex 'and owns nothing any more'
}

# --- who the claim belongs to -----------------------------------------------
# The claim used to be an index and nothing else, and the list is edited while a rule is holding the desk.

Test-Case 'rule: deleting another rule does not move the claim onto a stranger' {
    # Two rules; the second one takes the desk. Then the first is deleted — from the Settings window, or
    # by hand in the file — and index 1 becomes index 0. By index alone the claim would now be held
    # against a rule the person never triggered: its condition, its way back, its mode.
    Set-RuleScene -Mode 'combo:Work'
    $live = $script:RoSettings.rules[0]
    $script:RoSettings.rules = @(
        [ordered]@{ when = 'process'; minutes = 0; process = $script:RoDead
                    mode = 'solo:OTHER'; back = 'combo:Other'; enabled = $true }
        $live
    )
    Invoke-RulesCheck
    Assert-Equal 'solo:GAME' ($script:RoInvoked -join ',') 'the running rule fired'
    Assert-Equal 1 $script:RuleOwnedIndex 'and it is the second one that holds the desk'

    # The rule above it is deleted. The holder is still there, still matching, so nothing should happen.
    $script:RoSettings.rules = @($live)
    $script:RoMode = 'solo:GAME'
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME' ($script:RoInvoked -join ',') 'no second switch: the same rule still holds the desk'
    Assert-True ($script:RuleOwnedIndex -ge 0) 'and it has not let go of it either'
    Assert-Equal 'combo:Work' $script:RuleOwnedBack 'the way back is still the one it came from'
}

Test-Case 'rule: the holder itself being deleted hands the desk back' {
    Set-RuleScene -Mode 'combo:Work'
    Invoke-RulesCheck
    Assert-Equal 0 $script:RuleOwnedIndex 'the rule holds the desk'

    $script:RoMode = 'solo:GAME'
    $script:RoSettings.rules = @()
    Invoke-RulesCheck

    Assert-Equal 'solo:GAME,combo:Work' ($script:RoInvoked -join ',') 'the desk goes back where it came from'
    Assert-Equal -1 $script:RuleOwnedIndex 'and nobody holds it'
}
