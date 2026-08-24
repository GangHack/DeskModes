<#
.SYNOPSIS
    Switches the displays on your desk from the command line.

.DESCRIPTION
    Turns on the displays a mode names and puts the rest into standby, arranged in
    the order you gave them, with the taskbar where you asked for it. Also reports
    what Windows sees right now, without changing anything.

    All the logic lives in DisplayCore.ps1; this script only parses arguments and
    prints. Exit code 0 on success, 2 when another switch is already running, 1 on
    failure - so .cmd wrappers can tell the difference.

.PARAMETER Mode
    What to switch to, or what to report. Resolved in this order: an exact mode key
    ("solo:LG ULTRAGEAR", "combo:Work", "all"), a combination name from the
    settings, a display's short Monitor ID, then part of a display's name.

    These names report instead of switching:
      status      what the system shows right now (read-only, the default)
      modes       every mode key with its shortcut
      brightness  which displays answer over DDC/CI, and at what level
      audio       playback device names, for the "audio" setting
      stats       the diary: what, where and for how long

.PARAMETER PrimaryMatch
    Which display keeps the taskbar, by part of its name. Unlike the "primary"
    setting this one is strict: matching nothing is an error, not a silent fallback.

.PARAMETER KeepMode
    Leave resolution and refresh rate alone instead of raising them to the maximum.

.PARAMETER DryRun
    Print what would be done and change nothing.

.EXAMPLE
    .\Set-Display.ps1
    Reports the displays, their current and best modes, and which one is primary.

.EXAMPLE
    .\Set-Display.ps1 "Movie night"
    Switches to the combination named "Movie night" in the settings.

.EXAMPLE
    .\Set-Display.ps1 ULTRAGEAR -PrimaryMatch ULTRAGEAR
    Leaves only the display whose name contains "ULTRAGEAR" on, with the taskbar
    on it.

.EXAMPLE
    .\Set-Display.ps1 all -DryRun
    Shows what switching to every connected display would do.

.LINK
    README.md
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
    param([string]$Text, $Modes)

    # точный ключ
    $hit = $Modes | Where-Object { $_.Key -eq $Text } | Select-Object -First 1
    if ($hit) { return $hit }

    # имя комбинации, как оно записано в настройках; регистр не важен, поэтому
    # обёртки вида work.cmd находят комбинацию «Work».
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

# Настройки читаются один раз и раздаются дальше: и состоянию, и режимам нужен
# состав комбинаций. Иначе каждый потребитель шёл бы на диск сам.
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
    Write-Host '    "audio": { "combo:Work": "ULTRAFINE", "solo:XG27AQDMGR": "ROG" }' -ForegroundColor DarkGray
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

$modes = @(Get-DisplayModes -State $state -Settings $settings)

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

$resolved = Resolve-ModeKey -Text $Mode -Modes $modes
$result = Switch-DisplayMode -ModeKey $resolved.Key -PrimaryMatch $PrimaryMatch -KeepMode:$KeepMode -DryRun:$DryRun

# Код возврата важнее текста: при полном провале сообщение пустое, и .cmd-файлы
# рапортовали бы успех молча и с кодом 0.
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
