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

# --- reaching into the tray -------------------------------------------------
# Displays.ps1 cannot be dot-sourced by a test: it brings the whole application up — a tray icon, timers,
# global hotkeys. So the functions under test are cut out of it by parsing the file. Copying them into a
# test instead would let the copy drift away from the original in silence, which is the one thing a test
# like this must not do.
#
# Three groups of cases do this, and until now each carried its own seven lines of it.

# Parsed once and kept: the file is a hundred kilobytes and nothing in it changes mid-run.
$script:TrayAstCache = $null

function Get-TrayAst {
    if (-not $script:TrayAstCache) {
        $script:TrayAstCache = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root 'Displays.ps1'), [ref]$null, [ref]$null)
    }
    return $script:TrayAstCache
}

# The source of the named tray functions, as one scriptblock for the caller to DOT-SOURCE:
#
#     . (Get-TrayFunctionSource 'Get-AvailableMode', 'Invoke-ReapplyMode')
#
# The dot-source has to be the caller's: done inside here it would define them in this function's scope,
# and they would die with the call. "Exactly one of that name" is asserted rather than hoped for — a
# second definition means the test exercises whichever came first, and it would go on passing while the
# tray ran the other one.
function Get-TrayFunctionSource {
    param([Parameter(Mandatory)][string[]]$Name)

    $ast = Get-TrayAst
    $parts = @()
    foreach ($wanted in $Name) {
        $found = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq $wanted }.GetNewClosure(), $true)
        if ($found.Count -ne 1) { throw "expected exactly one $wanted in Displays.ps1, found $($found.Count)" }
        $parts += $found[0].Extent.Text
    }
    return [scriptblock]::Create($parts -join "`r`n")
}

# The source of a top-level assignment in Displays.ps1, likewise for the caller to dot-source:
#
#     . (Get-TrayVariableSource '$script:AutoRetryLimit')
#
# The extracted functions read the tray's own script-scope values, so those have to exist in the scope
# the functions are dot-sourced into — and taking the number from the file rather than writing a copy of
# it here is the point: a test carrying its own 4 goes on passing after the tray stops using 4.
function Get-TrayVariableSource {
    param([Parameter(Mandatory)][string[]]$Name)

    $ast = Get-TrayAst
    $parts = @()
    foreach ($wanted in $Name) {
        $found = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq $wanted }.GetNewClosure(), $true)
        if ($found.Count -ne 1) { throw "expected exactly one assignment to $wanted in Displays.ps1, found $($found.Count)" }
        $parts += $found[0].Extent.Text
    }
    return [scriptblock]::Create($parts -join "`r`n")
}

# What a fake Invoke-Mode has to publish: the real one leaves $script:LastSwitch behind it and its two
# readers — the rules and the postponed rebuild — decide what to do next out of that one object. A fake
# that set a boolean of its own would be testing a vocabulary the tray does not speak.
function Set-FakeSwitchOutcome {
    param([Parameter(Mandatory)][string]$Outcome, [string]$ModeKey = '', [string]$Message = 'from a fake')

    $script:LastSwitch = New-SwitchResult -ModeKey $ModeKey -Outcome $Outcome -Message $Message
}
