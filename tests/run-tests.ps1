#Requires -Version 5.1

<#
    tests\run-tests.ps1 — точка входа набора тестов. Своя, без Pester.

    Почему без Pester: в PowerShell 5.1 предустановлен древний 3.4, а ставить
    новый — против философии проекта («в систему ничего не установлено, папку
    можно просто удалить»). Здесь нужны Assert и ненулевой код возврата, всё
    остальное — лишняя зависимость.

    Этот файл только собирает прогон: уводит журнал, дот-сорсит подопытный код,
    обходит cases/ и печатает итог. Сами проверки живут рядом:

        framework.ps1          Test-Case и утверждения
        fakes.ps1              подделки, нужные больше чем одной группе
        cases/NN-имя.tests.ps1 по файлу на группу; префикс держит порядок вывода

    Тесты трогают ТОЛЬКО чистые функции: ни один не меняет мониторы и ни один не
    пишет в настоящий settings.json, журнал или дневник — все пути подменены на
    файлы во временной папке. Запуск занимает секунды.

        .\tests\run-tests.ps1                 всё
        .\tests\run-tests.ps1 -Only hotkey    только тесты, чьё имя содержит строку
        .\tests\run-tests.ps1 -File 12        только этот файл случаев

    Код возврата: 0 — все зелёные, 1 — есть провалы.
#>
[CmdletBinding()]
param(
    [string]$Only = '',
    [string]$File = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# Журнал уводим в сторону ДО дот-сорса: DisplayCore пишет в него уже при загрузке
# (поворот журнала, компиляция типов), и подменять $script:LogFile после было
# поздно — эти строки уезжали в настоящий last-run.log.
$script:LogDir = Join-Path $env:TEMP ('screendeck-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:LogDir | Out-Null
$env:SCREENDECK_LOG_FILE = Join-Path $script:LogDir 'last-run.log'

# Фреймворк — до подопытного кода: Test-Case и утверждения нужны всем, и
# дот-сорс кладёт их в область ЭТОГО файла, где лежат счётчики и $Only.
. (Join-Path $PSScriptRoot 'framework.ps1')

# Точки входа дот-сорсить нельзя: Displays.ps1 при загрузке поднимает всё
# приложение. Берём core, WindowLayout и диалог, а Resolve-ModeKey из
# Set-Display.ps1 вытаскивает себе тот файл случаев, которому он нужен
# (cases/11-cli-mode-key.tests.ps1).

. (Join-Path $root 'DisplayCore.ps1')
. (Join-Path $root 'WindowLayout.ps1')
. (Join-Path $root 'Activity.ps1')
. (Join-Path $root 'SettingsDialog.ps1')

# Настоящий settings.json не трогаем НИ В ОДНОМ тесте.
$script:TestDir = $script:LogDir   # он же, создан выше ради журнала
$script:SettingsFile = Join-Path $script:TestDir 'settings.json'
$script:WindowStateFile = Join-Path $script:TestDir 'window-state.json'
$script:LastModeFile = Join-Path $script:TestDir 'last-mode.json'
$script:ModeCacheFile = Join-Path $script:TestDir 'display-modes.json'
# Настоящий дневник тесты тоже не трогают: он про человека, и подмешивать в него
# выдуманные дни нельзя.
$script:ActivityFile = Join-Path $script:TestDir 'activity.json'

# Подделки — после подопытного кода: New-TestSettings строится на
# Get-DefaultSettings, а $script:DlgState — на настоящем Get-DialogModes.
. (Join-Path $PSScriptRoot 'fakes.ps1')

Write-Host ''
Write-Host 'ScreenDeck - tests' -ForegroundColor Cyan
Write-Host ''

# --- случаи -----------------------------------------------------------------
# Порядок вывода держит числовой префикс имени файла, а не порядок обхода
# файловой системы: сортировка по имени явная, чтобы прогон читался одинаково
# на любой машине.

$cases = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'cases') -Filter '*.tests.ps1' |
           Sort-Object Name)
if ($File) { $cases = @($cases | Where-Object { $_.Name -like "*$File*" }) }
if ($cases.Count -eq 0) {
    Write-Host ("No case files matched '{0}'." -f $File) -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

foreach ($case in $cases) { . $case.FullName }

# --- итог -------------------------------------------------------------------

Remove-Item -LiteralPath $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\SCREENDECK_LOG_FILE -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failed -eq 0) {
    Write-Host ("All good: {0} assertions passed." -f $script:Total) -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host ("FAILED: {0} of {1} assertions." -f $script:Failed, $script:Total) -ForegroundColor Red
Write-Host ''
foreach ($f in $script:Failures) { Write-Host "  $f" -ForegroundColor Red }
Write-Host ''
exit 1
