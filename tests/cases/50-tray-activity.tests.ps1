# --- the tray feeding the diary ---------------------------------------------
# Activity.ps1 owns session accounting. This checks the caller's side of the off/on boundary without
# sampling the computer or touching activity.json.

Write-Host ''
Write-Host 'the tray feeding the diary' -ForegroundColor White

. (Get-TrayFunctionSource 'Invoke-ActivityTick')

Test-Case 'diary: a disabled tick ends the in-memory session' {
    $script:ActivityRunStart = [datetime]'2026-09-06T10:00:00'
    $script:ActivityRunLast = [datetime]'2026-09-06T10:05:00'
    function Get-ActiveSettings { return [pscustomobject]@{ stats = $false } }
    function Get-ActivitySample { throw 'a disabled tick must not sample the computer' }

    Invoke-ActivityTick

    Assert-Null $script:ActivityRunStart 'the next enabled sample starts a new session'
    Assert-Null $script:ActivityRunLast 'the disabled gap cannot be counted into it'
}
