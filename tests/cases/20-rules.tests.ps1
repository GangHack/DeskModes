# --- rules ------------------------------------------------------------------
# Live, this is tested by starting a game and waiting twenty minutes, so the decision is separated
# from carrying it out and is tested here in full.

Write-Host ''
Write-Host 'rules' -ForegroundColor White

function New-TestRule {
    param([string]$When = 'process', [string]$Process = '', [int]$Minutes = 0,
          [string]$Mode = 'solo:A', [string]$Back = '', [bool]$Enabled = $true)
    return [ordered]@{ when = $When; process = $Process; minutes = $Minutes
                       mode = $Mode; back = $Back; enabled = $Enabled }
}

function New-TestFacts {
    param($Processes = @(), [int]$IdleSeconds = 0)
    return [pscustomobject]@{ Processes = @($Processes); IdleSeconds = $IdleSeconds }
}

Test-Case 'rule match: a running process' {
    $rule = New-TestRule -Process 'cs2'
    Assert-True (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @('chrome', 'cs2'))) 'running'
    Assert-Equal $false (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @('chrome'))) 'not running'
}

Test-Case 'rule match: the .exe people write out of habit is forgiven' {
    $rule = New-TestRule -Process 'CS2.exe'
    Assert-True (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @('cs2'))) 'suffix and case both'
}

Test-Case 'rule match: a rule that is switched off never matches' {
    $rule = New-TestRule -Process 'cs2' -Enabled $false
    Assert-Equal $false (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @('cs2'))) 'off is off'
}

Test-Case 'rule match: a rule without a mode is not a rule' {
    $rule = New-TestRule -Process 'cs2' -Mode ''
    Assert-Equal $false (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @('cs2'))) 'nowhere to go'
}

Test-Case 'rule match: idle counts in minutes' {
    $rule = New-TestRule -When 'idle' -Minutes 20
    Assert-Equal $false (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @() 1199)) 'a second short'
    Assert-True (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @() 1200)) 'exactly twenty minutes'
}

Test-Case 'rule match: idle without minutes is not a rule' {
    $rule = New-TestRule -When 'idle' -Minutes 0
    Assert-Equal $false (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @() 99999)) 'zero minutes would fire forever'
}

Test-Case 'rule match: a condition we do not know is refused, not assumed' {
    $rule = New-TestRule -When 'fullmoon'
    Assert-Equal $false (Test-RuleMatch -Rule $rule -Facts (New-TestFacts)) 'unknown means no'
}

Test-Case 'rule: the first matching rule wins' {
    $rules = @((New-TestRule -Process 'chrome' -Mode 'solo:A'), (New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('chrome', 'cs2')) -CurrentMode 'all'
    Assert-Equal 'switch' $d.Action 'switching'
    Assert-Equal 'solo:A' $d.Mode 'to the first one'
    Assert-Equal 0 $d.RuleIndex 'and it is remembered by number'
    Assert-Equal 'all' $d.Back 'coming back to where we were'
}

Test-Case 'rule: an explicit "back" beats where we happened to be' {
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B' -Back 'combo:Work'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('cs2')) -CurrentMode 'all'
    Assert-Equal 'combo:Work' $d.Back 'as written in the rule'
}

Test-Case 'rule: already in that mode means there is nothing to take over' {
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('cs2')) -CurrentMode 'solo:B'
    Assert-Equal 'none' $d.Action 'nothing to do, and nothing to give back later'
}

Test-Case 'rule: no way back means we do not go' {
    # The current set of screens matched no mode: leaving is possible, going back is not. This is the
    # case the decision is separated from the action for.
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('cs2')) -CurrentMode ''
    Assert-Equal 'blocked' $d.Action 'refused'
    Assert-True ($d.Reason -like '*no way back*') 'and it says why'
}

Test-Case 'rule: while the condition holds, nothing happens again' {
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('cs2')) -CurrentMode 'solo:B' -OwnedIndex 0 -OwnedBack 'all'
    Assert-Equal 'none' $d.Action 'the fifteen-second timer does not re-switch anything'
}

Test-Case 'rule: the condition ends and we go back' {
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('chrome')) -CurrentMode 'solo:B' -OwnedIndex 0 -OwnedBack 'combo:Work'
    Assert-Equal 'return' $d.Action 'going back'
    Assert-Equal 'combo:Work' $d.Mode 'to where we came from'
}

Test-Case 'rule: switched by hand during the game means we let go' {
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('cs2')) -CurrentMode 'all' -OwnedIndex 0 -OwnedBack 'combo:Work'
    Assert-Equal 'release' $d.Action 'no war with the human'
}

Test-Case 'rule: a rule deleted while it held the desk still gives the desk back' {
    $d = Get-RuleDecision -Rules @() -Facts (New-TestFacts) -CurrentMode 'solo:B' -OwnedIndex 0 -OwnedBack 'combo:Work'
    Assert-Equal 'return' $d.Action 'back'
    Assert-Equal 'combo:Work' $d.Mode 'to where we came from'
}

Test-Case 'rule: no rules at all is a quiet no' {
    $d = Get-RuleDecision -Rules @() -Facts (New-TestFacts @('cs2')) -CurrentMode 'all'
    Assert-Equal 'none' $d.Action 'nothing'
}

Test-Case 'rule reason: reads like a sentence in the log' {
    Assert-Equal 'cs2 is running' (Format-RuleReason (New-TestRule -Process 'cs2'))
    Assert-Equal 'idle for 20 min' (Format-RuleReason (New-TestRule -When 'idle' -Minutes 20))
}

# --- who the claim is against -----------------------------------------------
# A claim used to be the index and nothing else, and the list is edited — by hand and from the Settings
# window — while a rule is holding the desk.

Test-Case 'rule signature: two rules are the same one only when all four fields match' {
    $a = New-TestRule -Process 'cs2' -Mode 'solo:B'
    Assert-Equal (Get-RuleSignature -Rule $a) (Get-RuleSignature -Rule (New-TestRule -Process 'cs2' -Mode 'solo:B')) 'the same rule twice'
    Assert-True ((Get-RuleSignature -Rule $a) -ne (Get-RuleSignature -Rule (New-TestRule -Process 'dota2' -Mode 'solo:B'))) 'another process is another rule'
    Assert-True ((Get-RuleSignature -Rule $a) -ne (Get-RuleSignature -Rule (New-TestRule -Process 'cs2' -Mode 'solo:C'))) 'another mode is another rule'
    Assert-Equal '' (Get-RuleSignature -Rule $null) 'and nothing at all signs as nothing'
}

Test-Case 'rule: the holder is found by who it is, not by where it sits' {
    # The rule that took the desk was second; the first one is deleted and it becomes first. By index
    # alone the claim would now be read against a rule the person never triggered — its condition, its
    # mode, its way back.
    $game = New-TestRule -Process 'cs2' -Mode 'solo:B'
    $d = Get-RuleDecision -Rules @($game) -Facts (New-TestFacts @('cs2')) -CurrentMode 'solo:B' `
                          -OwnedIndex 1 -OwnedBack 'combo:Work' -OwnedSignature (Get-RuleSignature -Rule $game)
    Assert-Equal 'none' $d.Action 'the holder is still there and still matching, so nothing happens'
}

Test-Case 'rule: a claim whose rule really is gone gives the desk back' {
    $other = New-TestRule -Process 'dota2' -Mode 'solo:C'
    $d = Get-RuleDecision -Rules @($other) -Facts (New-TestFacts @('dota2')) -CurrentMode 'solo:B' `
                          -OwnedIndex 0 -OwnedBack 'combo:Work' `
                          -OwnedSignature (Get-RuleSignature -Rule (New-TestRule -Process 'cs2' -Mode 'solo:B'))
    Assert-Equal 'return' $d.Action 'the rule at that index is a stranger, and ours is nowhere'
    Assert-Equal 'combo:Work' $d.Mode 'so the desk goes back where it came from'
}

# --- a claim held by a rule that never got the desk -------------------------
# The tray keeps one after a refusal that asking again will not cure, so as not to fire the rule — and a
# balloon with it — every fifteen seconds. The state has to stay honest while it does.

Test-Case 'rule: a claim never taken sits out the condition instead of blaming a person' {
    # The tick that used to lie: the desk had not moved, and the release branch called that "the displays
    # were changed by hand" about somebody who had touched nothing.
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('cs2')) -CurrentMode 'combo:Work' `
                          -OwnedIndex 0 -OwnedBack 'combo:Work' -OwnedTaken $false
    Assert-Equal 'none' $d.Action 'nothing to do and nothing to say'
}

Test-Case 'rule: a claim never taken is let go of when the condition ends, without a switch' {
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('chrome')) -CurrentMode 'combo:Work' `
                          -OwnedIndex 0 -OwnedBack 'combo:Work' -OwnedTaken $false
    Assert-Equal 'release' $d.Action 'it lets go'
    Assert-Equal '' $d.Mode 'and moves nothing: the desk never left the person'
}

Test-Case 'rule: a claim never taken whose rule is deleted moves nothing either' {
    $d = Get-RuleDecision -Rules @() -Facts (New-TestFacts) -CurrentMode 'combo:Work' `
                          -OwnedIndex 0 -OwnedBack 'combo:Work' -OwnedTaken $false
    Assert-Equal 'release' $d.Action 'nothing to give back'
    Assert-Equal '' $d.Mode "and no switch on nobody's say-so"
}
