<#
    Set-Display.ps1 — переключение мониторов из командной строки.
    Вся логика в DisplayCore.ps1, здесь только разбор аргументов и вывод.

        .\Set-Display.ps1 status          что видит система прямо сейчас
        .\Set-Display.ps1 all             включить все подключённые
        .\Set-Display.ps1 "Movie night"   комбинация из настроек, по имени
        .\Set-Display.ps1 work            она же, если названа одним словом
        .\Set-Display.ps1 ULTRAGEAR       только этот монитор (поиск по названию)
        .\Set-Display.ps1 GSM5CBB         только этот монитор (короткий Monitor ID)
        .\Set-Display.ps1 modes           показать ключи всех режимов
        .\Set-Display.ps1 brightness      кто из мониторов слушается по DDC/CI
        .\Set-Display.ps1 stats           дневник: что, где и сколько

    -PrimaryMatch  кого сделать основным, по куску названия
    -KeepMode      не поднимать разрешение и частоту до максимума
    -DryRun        показать команды, ничего не применяя
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Mode = 'status',

    [string]$PrimaryMatch,
    [switch]$KeepMode,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DisplayCore.ps1')
. (Join-Path $PSScriptRoot 'WindowLayout.ps1')
. (Join-Path $PSScriptRoot 'Activity.ps1')

function Resolve-ModeKey {
    param([string]$Text, $Modes, $State)

    # точный ключ
    $hit = $Modes | Where-Object { $_.Key -eq $Text } | Select-Object -First 1
    if ($hit) { return $hit }

    # имя комбинации, как оно записано в настройках (без учёта регистра). Сюда же
    # приходят work.cmd и game.cmd: их 'work' и 'game' были именами ролей, а после
    # переезда ролей стали именами комбинаций («Work», «Game») — сравнение имени
    # регистр не различает, поэтому обёртки продолжают работать без правок.
    $hit = $Modes | Where-Object { $_.Kind -eq 'combo' -and $_.Title -eq $Text } | Select-Object -First 1
    if ($hit) { return $hit }

    # короткий Monitor ID
    $hit = $Modes | Where-Object { $_.Kind -eq 'solo' -and $_.ShortId -eq $Text } | Select-Object -First 1
    if ($hit) { return $hit }

    # часть названия монитора
    $hit = @($Modes | Where-Object { $_.Title -match [regex]::Escape($Text) })
    if ($hit.Count -eq 1) { return $hit[0] }
    if ($hit.Count -gt 1) {
        throw ("'$Text' matches several modes: " + (($hit | ForEach-Object { $_.Key }) -join ', '))
    }
    throw "Unknown mode '$Text'. Run: .\Set-Display.ps1 modes"
}

# Настройки читаются один раз и раздаются дальше: состоянию — ради ролей,
# режимам — ради комбинаций. Иначе каждый потребитель шёл бы на диск сам.
$settings = Get-DisplaySettings
$state = @(Get-DisplayState -Settings $settings)

if ($Mode -eq 'status') {
    Write-Host ''
    Write-Host 'Displays:' -ForegroundColor Cyan
    $state |
        Select-Object Output, Label, ShortId,
                      @{n = 'Current'; e = { '{0}x{1} @ {2}' -f $_.Width, $_.Height, $_.Hz } },
                      @{n = 'Best';    e = {
                            if ($_.BestMode) { '{0}x{1} @ {2}' -f $_.BestMode.Width, $_.BestMode.Height, $_.BestMode.Hz } else { '?' } } },
                      @{n = 'State';   e = { if ($_.Disconnected) { 'unplugged' } elseif ($_.Active) { 'on' } else { 'off' } } },
                      @{n = 'Primary'; e = { if ($_.Primary) { '*' } else { '' } } } |
        Format-Table -AutoSize
    return
}

if ($Mode -eq 'audio') {
    # Нужно, чтобы знать, какой кусок названия писать в settings.json -> audio.
    # Окна для этой настройки нет намеренно, а угадывать названия устройств
    # по памяти невозможно.
    Write-Host ''
    Write-Host 'Playback devices:' -ForegroundColor Cyan
    $devs = @(Get-AudioDevices)
    if ($devs.Count -eq 0) { Write-Host '  (none found)'; return }
    $devs |
        Select-Object @{n = 'Default'; e = { if ($_.IsDefault) { '*' } else { '' } } },
                      @{n = 'Name';    e = { $_.Name } } |
        Format-Table -AutoSize
    Write-Host 'Put a distinctive part of a name into settings.json, for example:' -ForegroundColor DarkGray
    Write-Host '    "audio": { "role:work": "ULTRAFINE", "solo:XG27AQDMGR": "ROG" }' -ForegroundColor DarkGray
    return
}

if ($Mode -eq 'brightness') {
    # Нужно, чтобы знать две вещи перед тем, как что-то писать в settings.json:
    # слушается ли монитор по DDC/CI вообще и какая яркость стоит сейчас. Спящие
    # мониторы в списке не появятся — они на запросы не отвечают.
    Write-Host ''
    Write-Host 'Monitors that answer over DDC/CI:' -ForegroundColor Cyan
    $levels = @(Get-MonitorLevels)
    if ($levels.Count -eq 0) {
        Write-Host '  (none answered - only displays that are ON can be asked)'
        return
    }
    # Название монитора берём из состояния: DDC отдаёт «Generic PnP Monitor» всем
    # подряд, и по такому списку выбрать нужный невозможно.
    $byOutput = @{}
    foreach ($m in $state) { if ($m.Output) { $byOutput[[string]$m.Output] = [string]$m.Label } }
    $levels |
        Select-Object @{n = 'Display';    e = { if ($byOutput.Contains([string]$_.Device)) { $byOutput[[string]$_.Device] } else { $_.Device } } },
                      @{n = 'Brightness'; e = { if ($_.CanBrightness) { '{0} ({1}..{2})' -f $_.Brightness, $_.BrightnessMin, $_.BrightnessMax } else { 'not supported' } } },
                      @{n = 'Contrast';   e = { if ($_.CanContrast) { [string]$_.Contrast } else { 'not supported' } } } |
        Format-Table -AutoSize
    Write-Host 'Put the levels you want into settings.json, for example:' -ForegroundColor DarkGray
    Write-Host '    "brightness": { "combo:Work": 80, "combo:Movie night": { "ULTRAFINE": 25 } }' -ForegroundColor DarkGray
    return
}

if ($Mode -eq 'stats') {
    if (-not $settings.stats) {
        Write-Host ''
        Write-Host 'The diary is off. Turn on "Keep a diary" in Settings (or set "stats": true).' -ForegroundColor Yellow
    }
    Format-ActivityReport -Report (Get-ActivityReport -Store (Get-ActivityStore) -Days 30) |
        ForEach-Object { Write-Host $_ }
    return
}

$modes = @(Get-DisplayModes $state $settings)

if ($Mode -eq 'modes') {
    Write-Host ''
    Write-Host 'Modes:' -ForegroundColor Cyan
    $modes |
        Select-Object Key, Title,
                      @{n = 'Hotkey';    e = { $settings.hotkeys[$_.Key] } },
                      @{n = 'Available'; e = { if ($_.Available) { 'yes' } else { 'no' } } } |
        Format-Table -AutoSize
    return
}

$resolved = Resolve-ModeKey $Mode $modes $state
$result = Switch-DisplayMode -ModeKey $resolved.Key -PrimaryMatch $PrimaryMatch -KeepMode:$KeepMode -DryRun:$DryRun

# Раньше здесь было только «если есть сообщение — напечатать». При полном
# провале сообщение пустое, и .cmd-файлы рапортовали успех молча и с кодом 0.
if (-not $result) { exit 1 }
if ($result.Skipped) {
    Write-Host ''
    Write-Host $result.Message -ForegroundColor Yellow
    exit 2
}

Write-Host ''
if ($result.Ok) {
    Write-Host "Now: $($result.Message)" -ForegroundColor Green
    exit 0
}

$text = $result.Message
if (-not $text) { $text = 'nothing came up - the displays did not attach' }
Write-Host "Problem: $text" -ForegroundColor Red
exit 1
