# --- отказ политики целостности кода ----------------------------------------
# Smart App Control (или политика WDAC) может отказаться грузить нашу сборку: она
# не подписана доверенным издателем. Отказ живьём по требованию не вызвать,
# поэтому тестом закреплён распознаватель — от него зависит, удалит ли код
# отвергнутый файл вместо того, чтобы получать тот же отказ каждый старт.

Write-Host ''
Write-Host 'the code integrity policy refusing our assembly' -ForegroundColor White

function New-FakeError {
    param([int]$HResult, [string]$Message = 'blocked', $Inner = $null)

    $e = New-Object System.IO.FileLoadException $Message, $Inner
    # HResult у исключения только для чтения — ставим через приватное поле, как это
    # делает сам .NET. Тесту нужен именно код, потому что по нему код и решает.
    $field = [System.Exception].GetField('_HResult', 'Instance,NonPublic')
    $field.SetValue($e, $HResult)
    return New-Object System.Management.Automation.ErrorRecord $e, 'x', 'NotSpecified', $null
}

Test-Case 'policy: 0x800711C7 is recognised as a refusal' {
    Assert-True (Test-BlockedByPolicy (New-FakeError -HResult 0x800711C7)) 'the code Windows returns for a blocked file'
}

Test-Case 'policy: any other failure is not a refusal' {
    # Папка только для чтения, занятый файл, битая сборка — их надо писать в
    # журнал как есть, а файл не трогать.
    Assert-True (-not (Test-BlockedByPolicy (New-FakeError -HResult 0x80070005))) 'access denied is something else'
    Assert-True (-not (Test-BlockedByPolicy (New-FakeError -HResult 0x80131018))) 'a bad image is something else'
}

Test-Case 'policy: the refusal is found however deep it is wrapped' {
    # PowerShell охотно оборачивает исключения, и проверять только верхнее нельзя.
    $inner = (New-FakeError -HResult 0x800711C7).Exception
    $outer = New-FakeError -HResult 0x80004005 -Message 'wrapped' -Inner $inner
    Assert-True (Test-BlockedByPolicy $outer) 'walked down to the real cause'
}
