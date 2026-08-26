# --- правила ----------------------------------------------------------------
# Живьём это проверяется запуском игры и двадцатиминутным ожиданием, поэтому
# решение отделено от исполнения и проверяется здесь целиком.

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
    # Текущий набор экранов не совпал ни с одним режимом: уйти можно, вернуться
    # некуда. Это тот случай, ради которого решение отделено от действия.
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
