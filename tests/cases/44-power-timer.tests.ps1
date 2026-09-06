# The tray script starts the application when dot-sourced, so the power timer tests execute only
# the tick body parsed from Displays.ps1. Every outward effect is shadowed here: these cases can
# never invoke a real shutdown or sleep action.

Write-Host ''
Write-Host 'the promised cancellation minute' -ForegroundColor White

$script:PowerTimerAst = Get-TrayAst
$powerTick = @($script:PowerTimerAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $n.Expression.Extent.Text -eq '$script:PowerTicker' -and
    $n.Member.Value -eq 'add_Tick'
}, $true))
if ($powerTick.Count -ne 1) { throw "expected exactly one PowerTicker tick in Displays.ps1, found $($powerTick.Count)" }
$script:PowerTickBody = [scriptblock]::Create($powerTick[0].Arguments[0].ScriptBlock.EndBlock.Extent.Text)
. (Get-TrayFunctionSource 'Stop-PowerTimer')

function New-FakePowerTicker {
    $ticker = New-Object psobject
    $ticker | Add-Member ScriptMethod Stop { $script:PowerTickerStops++ }
    return $ticker
}

function Invoke-FakePowerTick {
    & $script:PowerTickBody
}

Test-Case 'power timer: an overdue first tick grants the promised cancellation minute' {
    $script:PowerEvents = New-Object System.Collections.ArrayList
    $script:PowerTickerStops = 0
    $script:PowerTicker = New-FakePowerTicker
    $script:PowerWarningAt = $null
    $script:PowerDeadline = (Get-Date).AddMinutes(-2)
    $script:PowerWarned = $false
    $script:PowerAction = 'shutdown'

    function Update-TrayText { }
    function Show-Balloon {
        param($Title, $Text, $Kind)
        $script:PowerWarningAt = Get-Date
        [void]$script:PowerEvents.Add('warning')
    }
    function Invoke-PowerAction { param($Action) [void]$script:PowerEvents.Add('POWER ' + $Action) }
    function Write-DisplayLog { param($Text) }
    function Get-PowerRemaining {
        return [int][math]::Ceiling(($script:PowerDeadline - (Get-Date)).TotalSeconds)
    }

    Invoke-FakePowerTick

    Assert-Equal @('warning') @($script:PowerEvents) 'the late tick warns without acting'
    $grace = ($script:PowerDeadline - $script:PowerWarningAt).TotalSeconds
    Assert-True ($grace -ge 59.9 -and $grace -le 60.1) 'the whole promised minute remains after the warning'
    Assert-Equal 0 $script:PowerTickerStops 'the ticker keeps the cancellation window alive'
}

Test-Case 'power timer: a first final-minute warning grants a whole minute without repeating' {
    $script:PowerEvents = New-Object System.Collections.ArrayList
    $script:PowerTickerStops = 0
    $script:PowerTicker = New-FakePowerTicker
    $script:PowerWarningAt = $null
    $script:PowerDeadline = (Get-Date).AddSeconds(30)
    $script:PowerWarned = $false
    $script:PowerAction = 'sleep'

    function Update-TrayText { }
    function Show-Balloon {
        param($Title, $Text, $Kind)
        $script:PowerWarningAt = Get-Date
        [void]$script:PowerEvents.Add('warning')
    }
    function Invoke-PowerAction { param($Action) [void]$script:PowerEvents.Add('POWER ' + $Action) }
    function Write-DisplayLog { param($Text) }
    function Get-PowerRemaining {
        return [int][math]::Ceiling(($script:PowerDeadline - (Get-Date)).TotalSeconds)
    }

    Invoke-FakePowerTick

    $grace = ($script:PowerDeadline - $script:PowerWarningAt).TotalSeconds
    Assert-True ($grace -ge 59.9 -and $grace -le 60.1) 'the warning starts a whole cancellation minute'
    $warnedDeadline = $script:PowerDeadline

    Invoke-FakePowerTick

    Assert-Equal @('warning') @($script:PowerEvents) 'the warning appears only once'
    Assert-Equal $warnedDeadline $script:PowerDeadline 'later ticks do not extend the grace period'
}

Test-Case 'power timer: a warned timer acts when its cancellation minute expires' {
    $script:PowerEvents = New-Object System.Collections.ArrayList
    $script:PowerTickerStops = 0
    $script:PowerTicker = New-FakePowerTicker
    $script:PowerDeadline = (Get-Date).AddSeconds(-1)
    $script:PowerWarned = $true
    $script:PowerAction = 'shutdown'

    function Update-TrayText { }
    function Show-Balloon { param($Title, $Text, $Kind) [void]$script:PowerEvents.Add('warning') }
    function Invoke-PowerAction { param($Action) [void]$script:PowerEvents.Add('POWER ' + $Action) }
    function Write-DisplayLog { param($Text) }
    function Get-PowerRemaining {
        return [int][math]::Ceiling(($script:PowerDeadline - (Get-Date)).TotalSeconds)
    }

    Invoke-FakePowerTick

    Assert-Equal @('POWER shutdown') @($script:PowerEvents) 'the requested action runs after warning and grace'
    Assert-Null $script:PowerDeadline 'the completed timer is disarmed'
    Assert-Equal 1 $script:PowerTickerStops 'the ticker stops after the action'
}

Test-Case 'power timer: cancellation during the warning minute disarms the action' {
    $script:PowerEvents = New-Object System.Collections.ArrayList
    $script:PowerTickerStops = 0
    $script:PowerTicker = New-FakePowerTicker
    $script:PowerDeadline = (Get-Date).AddSeconds(45)
    $script:PowerWarned = $true
    $script:PowerAction = 'shutdown'

    function Update-TrayText { }
    function Show-Balloon { param($Title, $Text, $Kind) [void]$script:PowerEvents.Add('cancelled') }
    function Invoke-PowerAction { param($Action) [void]$script:PowerEvents.Add('POWER ' + $Action) }
    function Write-DisplayLog { param($Text) }

    Stop-PowerTimer
    Invoke-FakePowerTick

    Assert-Null $script:PowerDeadline 'cancellation disarms the deadline'
    Assert-Equal @('cancelled') @($script:PowerEvents) 'the cancellation is reported without a power action'
    Assert-Equal 2 $script:PowerTickerStops 'cancellation and the following inert tick both stop the ticker'
}
