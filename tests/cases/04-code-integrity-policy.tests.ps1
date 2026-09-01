# --- the code integrity policy refusing us ----------------------------------
# Smart App Control (or a WDAC policy) can refuse to load our assembly: it is not signed by a
# trusted publisher. The refusal cannot be produced live on demand, so what a test pins down is the
# recogniser — whether the code deletes the rejected file rather than getting the same refusal on
# every start depends on it.

Write-Host ''
Write-Host 'the code integrity policy refusing our assembly' -ForegroundColor White

function New-FakeError {
    param([int]$HResult, [string]$Message = 'blocked', $Inner = $null)

    $e = New-Object System.IO.FileLoadException $Message, $Inner
    # An exception's HResult is read-only — we set it through the private field, the way .NET does
    # itself. The test needs the code specifically, because the code is what the decision is made by.
    $field = [System.Exception].GetField('_HResult', 'Instance,NonPublic')
    $field.SetValue($e, $HResult)
    return New-Object System.Management.Automation.ErrorRecord $e, 'x', 'NotSpecified', $null
}

Test-Case 'policy: 0x800711C7 is recognised as a refusal' {
    Assert-True (Test-BlockedByPolicy (New-FakeError -HResult 0x800711C7)) 'the code Windows returns for a blocked file'
}

Test-Case 'policy: any other failure is not a refusal' {
    # A read-only folder, a file in use, a broken assembly — those have to be written to the log as
    # they are, and the file left alone.
    Assert-True (-not (Test-BlockedByPolicy (New-FakeError -HResult 0x80070005))) 'access denied is something else'
    Assert-True (-not (Test-BlockedByPolicy (New-FakeError -HResult 0x80131018))) 'a bad image is something else'
}

Test-Case 'policy: the refusal is found however deep it is wrapped' {
    # PowerShell wraps exceptions freely, and checking only the top one is not enough.
    $inner = (New-FakeError -HResult 0x800711C7).Exception
    $outer = New-FakeError -HResult 0x80004005 -Message 'wrapped' -Inner $inner
    Assert-True (Test-BlockedByPolicy $outer) 'walked down to the real cause'
}
