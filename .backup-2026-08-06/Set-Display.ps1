<#
    Set-Display.ps1 — переключение мониторов из командной строки.
    Вся логика в DisplayCore.ps1, здесь только разбор аргументов и вывод.

        .\Set-Display.ps1 status        что видит система прямо сейчас
        .\Set-Display.ps1 all           включить все подключённые
        .\Set-Display.ps1 work          все рабочие мониторы (LG)
        .\Set-Display.ps1 game          игровой монитор (ASUS)
        .\Set-Display.ps1 ULTRAGEAR     только этот монитор (поиск по названию)
        .\Set-Display.ps1 GSM5CBB       только этот монитор (короткий Monitor ID)
        .\Set-Display.ps1 modes         показать ключи всех режимов

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

function Resolve-ModeKey {
    param([string]$Text, $Modes, $State)

    # точный ключ
    $hit = $Modes | Where-Object { $_.Key -eq $Text } | Select-Object -First 1
    if ($hit) { return $hit }

    # короткие имена групп
    $hit = $Modes | Where-Object { $_.Key -eq "role:$Text" } | Select-Object -First 1
    if ($hit) { return $hit }

    # короткий Monitor ID
    $hit = $Modes | Where-Object { $_.Kind -eq 'solo' -and $_.ShortId -eq $Text } | Select-Object -First 1
    if ($hit) { return $hit }

    # Группы из одного монитора в меню не показываются (для него есть соло-режим),
    # но по имени группы всё равно должно находиться: 'game' -> единственный ASUS.
    if ($Text -in 'work', 'game') {
        $byRole = @($State | Where-Object { $_.Role -eq $Text -and -not $_.Disconnected })
        if ($byRole.Count -eq 1) {
            $hit = $Modes | Where-Object { $_.Kind -eq 'solo' -and $_.ShortId -eq $byRole[0].ShortId } | Select-Object -First 1
            if ($hit) { return $hit }
        }
    }

    # часть названия монитора
    $hit = @($Modes | Where-Object { $_.Title -match [regex]::Escape($Text) })
    if ($hit.Count -eq 1) { return $hit[0] }
    if ($hit.Count -gt 1) {
        throw ("'$Text' matches several modes: " + (($hit | ForEach-Object { $_.Key }) -join ', '))
    }
    throw "Unknown mode '$Text'. Run: .\Set-Display.ps1 modes"
}

$state = @(Get-DisplayState)

if ($Mode -eq 'status') {
    Write-Host ''
    Write-Host 'Displays:' -ForegroundColor Cyan
    $state |
        Select-Object Output, Label, ShortId, Role,
                      @{n = 'Current'; e = { '{0}x{1} @ {2}' -f $_.Width, $_.Height, $_.Hz } },
                      @{n = 'Best';    e = {
                            if ($_.BestMode) { '{0}x{1} @ {2}' -f $_.BestMode.Width, $_.BestMode.Height, $_.BestMode.Hz } else { '?' } } },
                      @{n = 'State';   e = { if ($_.Disconnected) { 'unplugged' } elseif ($_.Active) { 'on' } else { 'off' } } },
                      @{n = 'Primary'; e = { if ($_.Primary) { '*' } else { '' } } } |
        Format-Table -AutoSize
    return
}

$modes = @(Get-DisplayModes $state)

if ($Mode -eq 'modes') {
    $settings = Get-DisplaySettings
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
if ($result -and -not $result.Skipped -and $result.Message) {
    Write-Host ''
    Write-Host "Now: $($result.Message)" -ForegroundColor Green
}
