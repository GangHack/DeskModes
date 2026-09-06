# --- Resolve-ModeKey out of Set-Display.ps1 ---------------------------------

Write-Host ''
Write-Host 'command line mode resolution' -ForegroundColor White

# Set-Display.ps1 cannot be dot-sourced — it starts working straight away. We pull only the
# function's definition out of it, by parsing the file: that way the test does not depend on a copy
# of the code that would drift apart from the original.
$sdPath = Join-Path $root 'Set-Display.ps1'
$sdAst = [System.Management.Automation.Language.Parser]::ParseFile($sdPath, [ref]$null, [ref]$null)
$fnAst = $sdAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-ModeKey' }, $true)
if ($fnAst.Count -ne 1) { throw "expected exactly one Resolve-ModeKey in Set-Display.ps1, found $($fnAst.Count)" }
. ([scriptblock]::Create($fnAst[0].Extent.Text))

$script:ResolveState = @(
    (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3')
    (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
    (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D')
)
$script:ResolveSettings = New-TestSettings @{
    'Work'        = @('ULTRAGEAR', 'ULTRAFINE')
    'Game'        = @('XG27AQDMGR')
    'Movie night' = @('ULTRAFINE', 'XG27AQDMGR')
}
$script:ResolveModes = @(Get-DisplayModes $script:ResolveState $script:ResolveSettings)

Test-Case 'resolve: an exact key' {
    Assert-Equal 'all' (Resolve-ModeKey 'all' $script:ResolveModes).Key 'all'
    Assert-Equal 'combo:Work' (Resolve-ModeKey 'combo:Work' $script:ResolveModes).Key 'combo key'
}

Test-Case 'resolve: a combination by name, case and spaces aside' {
    Assert-Equal 'combo:Movie night' (Resolve-ModeKey 'movie night' $script:ResolveModes).Key 'lower case, with a space'
}

Test-Case 'resolve: work.cmd and game.cmd find their combinations' {
    # The wrappers call `Set-Display.ps1 work` and `game`, while the combos are named "Work" and
    # "Game": the name comparison ignores case.
    Assert-Equal 'combo:Work' (Resolve-ModeKey 'work' $script:ResolveModes).Key 'work'
    Assert-Equal 'combo:Game' (Resolve-ModeKey 'game' $script:ResolveModes).Key 'game, a set of one'
}

Test-Case 'resolve: a short monitor id' {
    Assert-Equal 'solo:LG ULTRAFINE' (Resolve-ModeKey 'GSM5CBC' $script:ResolveModes).Key 'by short id'
}

Test-Case 'resolve: part of a monitor name' {
    Assert-Equal 'solo:LG ULTRAGEAR' (Resolve-ModeKey 'ULTRAGEAR' $script:ResolveModes).Key 'by name part'
}

Test-Case 'resolve: an ambiguous name is refused, not guessed' {
    $threw = $false
    try { [void](Resolve-ModeKey 'LG' $script:ResolveModes) }
    catch { $threw = $true; Assert-True ($_.Exception.Message -like '*matches several modes*') 'said why' }
    Assert-True $threw 'threw on ambiguity'
}

Test-Case 'resolve: an unknown name is refused with a hint' {
    $threw = $false
    try { [void](Resolve-ModeKey 'nosuchthing' $script:ResolveModes) }
    catch { $threw = $true; Assert-True ($_.Exception.Message -like '*Unknown mode*') 'said unknown' }
    Assert-True $threw 'threw on unknown'
}

Test-Case 'resolve: a shared monitor ID is refused with the exact instance keys' {
    $left = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-a'
    $right = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-b'
    $modes = @(Get-DisplayModes -State @($left, $right) -Settings (New-TestSettings))
    $solo = @($modes | Where-Object { $_.Kind -eq 'solo' })
    $problem = ''
    try { [void](Resolve-ModeKey -Text 'TWN1234' -Modes $modes) }
    catch { $problem = $_.Exception.Message }

    Assert-True ([bool]$problem) 'a shared model ID must not choose the first physical panel'
    foreach ($mode in $solo) {
        Assert-True ($problem.Contains($mode.Key)) 'the error offers an exact key for each possible instance'
        Assert-Equal $mode.Id (Resolve-ModeKey -Text $mode.Key -Modes $modes).Id 'an exact instance key still resolves'
    }
}
