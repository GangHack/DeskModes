# --- ретрай раскладки и вердикт переключения --------------------------------
# Валидация раскладки отвечает 87 сразу после смены топологии. Если единственная
# попытка молча провалится, а переключение отчитается успехом, мониторы до
# следующего хоткея стоят перепутанными. Отсюда два свойства, прибитые тестами:
# раскладка повторяется, провал попадает в вердикт.

Write-Host ''
Write-Host 'layout retry and the switch verdict' -ForegroundColor White

Test-Case 'layout retry: a transient failure is retried until it succeeds' {
    # Тот самый день: две неудачи подряд, потом система приходит в себя.
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
    # «Уже стоит как надо» — самый частый случай; лишние попытки стоили бы
    # лишних перечитываний CCD на каждом переключении.
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
