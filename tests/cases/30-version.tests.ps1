# --- версия -----------------------------------------------------------------
# Строку версии читают двое — `Set-Display.ps1 status` и пункт About в меню трея —
# и собирает её одна функция. Проверяется здесь именно это: не «текст красивый», а
# что версия есть, что она разбирается как версия и что в строку попало то, чем
# человек начинает отчёт об ошибке.

Write-Host ''
Write-Host 'the version' -ForegroundColor White

Test-Case 'version: it is there and reads as a version' {
    Assert-True ([bool]$script:Version) 'the version is set at all'
    Assert-True ($script:Version -match '^\d+\.\d+\.\d+$') "three numbers, nothing else (got '$script:Version')"
    # Version, а не строка: сравнение строками объявило бы 1.10.0 младше 1.9.0.
    Assert-True ([bool]([version]$script:Version)) 'and .NET parses it as one'
}

Test-Case 'version: the line names the tool, the version, Windows and PowerShell' {
    $line = Get-VersionLine

    Assert-True ($line -like 'ScreenDeck *') 'it starts with the name, so a pasted line is self-explaining'
    Assert-True ($line -like "*$script:Version*") 'the version itself is in there'
    Assert-True ($line -like '*Windows *') 'and the Windows build - most refusals here are a build plus a driver'
    Assert-True ($line -like '*PowerShell *') 'and which PowerShell ran it'
}
