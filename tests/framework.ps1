<#
    tests\framework.ps1 — Test-Case and the assertions.

    Without Pester: PowerShell 5.1 comes with an ancient 3.4 preinstalled, and installing a newer one
    goes against the promise that "nothing is installed on your system, the folder can just be
    deleted". What is needed is Assert and a non-zero exit code; everything else is a dependency we
    do not want.

    Dot-sourced from run-tests.ps1, which is why $script:Total, $script:Failed and $Only resolve in
    THAT file's scope: the counters and the filter belong where the entry point prints them.
#>


$script:Total = 0
$script:Failed = 0
$script:CurrentTest = ''
$script:Failures = @()

function Test-Case {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)

    if ($Only -and $Name -notlike "*$Only*") { return }

    $script:CurrentTest = $Name
    $before = $script:Failed
    try {
        & $Body
    }
    catch {
        $script:Failed++
        $script:Failures += "$Name : threw - $($_.Exception.Message)"
        Write-Host ("  x  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("       threw: {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
        return
    }
    if ($script:Failed -eq $before) { Write-Host ("  +  {0}" -f $Name) -ForegroundColor Green }
    else { Write-Host ("  x  {0}" -f $Name) -ForegroundColor Red }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$What = '')
    $script:Total++
    # Arrays are compared by content: -eq on them in PowerShell does not do what it reads like (it
    # filters rather than compares).
    $same = $false
    if ($Expected -is [array] -or $Actual -is [array]) {
        $e = @($Expected); $a = @($Actual)
        $same = ($e.Count -eq $a.Count)
        if ($same) { for ($i = 0; $i -lt $e.Count; $i++) { if ("$($e[$i])" -ne "$($a[$i])") { $same = $false; break } } }
    }
    else { $same = ($Expected -eq $Actual) }

    if (-not $same) {
        $script:Failed++
        $msg = "$($script:CurrentTest) : $What expected [$($Expected -join ', ')], got [$($Actual -join ', ')]"
        $script:Failures += $msg
        Write-Host ("       $What expected [{0}], got [{1}]" -f ($Expected -join ', '), ($Actual -join ', ')) -ForegroundColor DarkRed
    }
}

function Assert-True {
    param($Condition, [string]$What = '')
    $script:Total++
    if (-not $Condition) {
        $script:Failed++
        $script:Failures += "$($script:CurrentTest) : $What expected true"
        Write-Host ("       $What expected true") -ForegroundColor DarkRed
    }
}

function Assert-Null {
    param($Value, [string]$What = '')
    $script:Total++
    if ($null -ne $Value) {
        $script:Failed++
        $script:Failures += "$($script:CurrentTest) : $What expected null, got [$Value]"
        Write-Host ("       $What expected null, got [{0}]" -f $Value) -ForegroundColor DarkRed
    }
}
