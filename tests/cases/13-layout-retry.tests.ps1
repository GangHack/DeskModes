# --- the layout retry and a switch's verdict --------------------------------
# Layout validation answers 87 right after a topology change. If the one attempt fails silently and
# the switch reports success, the monitors stand muddled up until the next shortcut. Hence two
# properties nailed down by tests: the layout is retried, and a failure reaches the verdict.

Write-Host ''
Write-Host 'layout retry and the switch verdict' -ForegroundColor White

Test-Case 'layout retry: a transient failure is retried until it succeeds' {
    # That very day: two failures in a row, and then the system comes to its senses.
    $script:LayoutCalls = 0
    function Invoke-CcdLayoutAttempt {
        param([string]$PrimaryPath, [string[]]$Order, [int]$Attempt, [int]$Attempts)
        $script:LayoutCalls++
        if ($script:LayoutCalls -lt 3) { return (New-LayoutResult -Ok $false -Changed $false) }
        return (New-LayoutResult -Ok $true -Changed $true)
    }
    $r = Set-CcdLayout -PrimaryPath 'p' -Order @('A') -RetryDelayMs 0
    Assert-Equal 3 $script:LayoutCalls 'took three attempts'
    Assert-True $r.Ok 'succeeded in the end'
    Assert-True $r.Changed 'and reported the arranging'
}

Test-Case 'layout retry: gives up after three attempts and reports the failure' {
    $script:LayoutCalls = 0
    $script:SeenAttempts = @()
    function Invoke-CcdLayoutAttempt {
        param([string]$PrimaryPath, [string[]]$Order, [int]$Attempt, [int]$Attempts)
        $script:LayoutCalls++
        $script:SeenAttempts += $Attempt
        return (New-LayoutResult -Ok $false -Changed $false)
    }
    $r = Set-CcdLayout -PrimaryPath 'p' -Order @('A') -RetryDelayMs 0
    Assert-Equal 3 $script:LayoutCalls 'stopped at three'
    Assert-Equal @(1, 2, 3) $script:SeenAttempts 'attempts numbered for the log'
    Assert-True (-not $r.Ok) 'reported the failure instead of pretending'
    Assert-True (-not $r.Changed) 'nothing was arranged'
}

Test-Case 'layout retry: success on the first try is not retried' {
    # "Already stands as it should" is the most frequent case; extra attempts would cost extra
    # re-reads of CCD on every switch.
    $script:LayoutCalls = 0
    function Invoke-CcdLayoutAttempt {
        param([string]$PrimaryPath, [string[]]$Order, [int]$Attempt, [int]$Attempts)
        $script:LayoutCalls++
        return (New-LayoutResult -Ok $true -Changed $false)
    }
    $r = Set-CcdLayout -PrimaryPath 'p' -Order @('A') -RetryDelayMs 0
    Assert-Equal 1 $script:LayoutCalls 'one call was enough'
    Assert-True $r.Ok 'ok'
    Assert-True (-not $r.Changed) 'already correct passes through'
}
