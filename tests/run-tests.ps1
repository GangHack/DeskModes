<#
    tests\run-tests.ps1 — свой мини-раннер, без Pester.

    Почему без Pester: в PowerShell 5.1 предустановлен древний 3.4, а ставить
    новый — против философии проекта («в систему ничего не установлено, папку
    можно просто удалить»). Здесь нужны Assert и ненулевой код возврата, всё
    остальное — лишняя зависимость.

    Тесты трогают ТОЛЬКО чистые функции: ни один не меняет мониторы и ни один не
    пишет в настоящий settings.json ($script:SettingsFile подменяется на файл во
    временной папке). Запуск занимает секунды.

        .\tests\run-tests.ps1            всё
        .\tests\run-tests.ps1 -Only hotkey   только тесты, чьё имя содержит строку

    Код возврата: 0 — все зелёные, 1 — есть провалы.
#>
[CmdletBinding()]
param([string]$Only = '')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# Журнал уводим в сторону ДО дот-сорса: DisplayCore пишет в него уже при загрузке
# (поворот журнала, компиляция типов), и подменять $script:LogFile после было
# поздно — эти строки уезжали в настоящий last-run.log.
$script:LogDir = Join-Path $env:TEMP ('mmt-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:LogDir | Out-Null
$env:MMT_LOG_FILE = Join-Path $script:LogDir 'last-run.log'

# --- крошечный фреймворк -----------------------------------------------------

$script:Total = 0
$script:Failed = 0
$script:CurrentTest = ''
$script:Failures = @()

function Test-Case {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)

    if ($Only -and $Name -notlike "*$Only*") { return }

    $script:CurrentTest = $Name
    $before = $script:Failed
    try {
        & $Body
    }
    catch {
        $script:Failed++
        $script:Failures += "$Name : threw - $($_.Exception.Message)"
        Write-Host ("  x  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("       threw: {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
        return
    }
    if ($script:Failed -eq $before) { Write-Host ("  +  {0}" -f $Name) -ForegroundColor Green }
    else { Write-Host ("  x  {0}" -f $Name) -ForegroundColor Red }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$What = '')
    $script:Total++
    # Массивы сравниваем по содержимому: -eq на них в PowerShell делает не то,
    # что читается (фильтрует, а не сравнивает).
    $same = $false
    if ($Expected -is [array] -or $Actual -is [array]) {
        $e = @($Expected); $a = @($Actual)
        $same = ($e.Count -eq $a.Count)
        if ($same) { for ($i = 0; $i -lt $e.Count; $i++) { if ("$($e[$i])" -ne "$($a[$i])") { $same = $false; break } } }
    }
    else { $same = ($Expected -eq $Actual) }

    if (-not $same) {
        $script:Failed++
        $msg = "$($script:CurrentTest) : $What expected [$($Expected -join ', ')], got [$($Actual -join ', ')]"
        $script:Failures += $msg
        Write-Host ("       $What expected [{0}], got [{1}]" -f ($Expected -join ', '), ($Actual -join ', ')) -ForegroundColor DarkRed
    }
}

function Assert-True {
    param($Condition, [string]$What = '')
    $script:Total++
    if (-not $Condition) {
        $script:Failed++
        $script:Failures += "$($script:CurrentTest) : $What expected true"
        Write-Host ("       $What expected true") -ForegroundColor DarkRed
    }
}

function Assert-Null {
    param($Value, [string]$What = '')
    $script:Total++
    if ($null -ne $Value) {
        $script:Failed++
        $script:Failures += "$($script:CurrentTest) : $What expected null, got [$Value]"
        Write-Host ("       $What expected null, got [{0}]" -f $Value) -ForegroundColor DarkRed
    }
}

# --- подопытный код ----------------------------------------------------------
# Точки входа дот-сорсить нельзя: Displays.ps1 при загрузке поднимает всё
# приложение. Берём core, WindowLayout и диалог, а Resolve-ModeKey из
# Set-Display.ps1 вытаскиваем отдельно (см. ниже).

. (Join-Path $root 'DisplayCore.ps1')
. (Join-Path $root 'WindowLayout.ps1')
. (Join-Path $root 'SettingsDialog.ps1')

# Настоящий settings.json не трогаем НИ В ОДНОМ тесте.
$script:TestDir = $script:LogDir   # он же, создан выше ради журнала
$script:SettingsFile = Join-Path $script:TestDir 'settings.json'
$script:WindowStateFile = Join-Path $script:TestDir 'window-state.json'
$script:LastModeFile = Join-Path $script:TestDir 'last-mode.json'

# Фиктивные мониторы: тесты не должны зависеть от того, что сейчас на столе.
function New-FakeMonitor {
    param([string]$Label, [string]$ShortId, [string]$Role = 'work', [string]$Id = '',
          [bool]$Active = $true, [bool]$Disconnected = $false)
    if (-not $Id) { $Id = 'path-' + $Label + '-' + $ShortId }
    return [pscustomobject]@{
        Output = '\\.\DISPLAY1'; Label = $Label; Model = $Label; ShortId = $ShortId
        Native = $null; Role = $Role; Id = $Id; Active = $Active
        Primary = $false; Disconnected = $Disconnected
        Width = 2560; Height = 1440; Hz = 144; BestMode = $null
    }
}

Write-Host ''
Write-Host 'ScreenDeck - tests' -ForegroundColor Cyan
Write-Host ''

# --- разбор и печать комбинаций клавиш ---------------------------------------

Write-Host 'hotkey strings' -ForegroundColor White

Test-Case 'hotkey: Ctrl+Alt+F1 parses' {
    $r = ConvertFrom-HotkeyString 'Ctrl+Alt+F1'
    Assert-True ($null -ne $r) 'parsed'
    Assert-Equal 3 $r.Modifiers 'modifiers (ctrl 2 | alt 1)'
    Assert-Equal 0x70 $r.Vk 'vk of F1'
    Assert-Equal 'Ctrl+Alt+F1' $r.Text 'round-trip text'
}

Test-Case 'hotkey: every F key from F1 to F24' {
    for ($n = 1; $n -le 24; $n++) {
        $r = ConvertFrom-HotkeyString "Ctrl+F$n"
        Assert-True ($null -ne $r) "F$n parsed"
        if ($r) { Assert-Equal (0x70 + $n - 1) $r.Vk "F$n vk" }
    }
}

Test-Case 'hotkey: F25 is not a key' {
    Assert-Null (ConvertFrom-HotkeyString 'Ctrl+F25') 'F25'
}

Test-Case 'hotkey: needs a modifier' {
    Assert-Null (ConvertFrom-HotkeyString 'F1') 'bare F1'
    Assert-Null (ConvertFrom-HotkeyString 'A') 'bare letter'
}

Test-Case 'hotkey: rubbish is rejected' {
    Assert-Null (ConvertFrom-HotkeyString '') 'empty'
    Assert-Null (ConvertFrom-HotkeyString '   ') 'spaces'
    Assert-Null (ConvertFrom-HotkeyString 'Ctrl+') 'modifier only'
    Assert-Null (ConvertFrom-HotkeyString 'Ctrl+Alt') 'modifiers only'
    Assert-Null (ConvertFrom-HotkeyString 'Ctrl+F0') 'F0'
    Assert-Null (ConvertFrom-HotkeyString 'Ctrl+Enter') 'unsupported key name'
    Assert-Null (ConvertFrom-HotkeyString 'nonsense') 'plain word'
}

Test-Case 'hotkey: letters and digits work' {
    $a = ConvertFrom-HotkeyString 'Win+A'
    Assert-Equal 0x41 $a.Vk 'A'
    Assert-Equal 'Win+A' $a.Text 'A text'
    $d = ConvertFrom-HotkeyString 'Ctrl+Shift+7'
    Assert-Equal 0x37 $d.Vk '7'
    Assert-Equal 'Ctrl+Shift+7' $d.Text '7 text'
}

Test-Case 'hotkey: modifier order is normalised, aliases understood' {
    # Порядок в тексте всегда Ctrl, Alt, Shift, Win — независимо от того, как ввели.
    Assert-Equal 'Ctrl+Alt+F5' (ConvertFrom-HotkeyString 'Alt+Ctrl+F5').Text 'reordered'
    Assert-Equal 'Ctrl+F5' (ConvertFrom-HotkeyString 'CONTROL+f5').Text 'alias and case'
    Assert-Equal 'Ctrl+Alt+Shift+Win+F2' (ConvertFrom-HotkeyString 'win+shift+alt+ctrl+F2').Text 'all four'
}

Test-Case 'hotkey: format and parse round-trip each other' {
    foreach ($text in 'Ctrl+F1', 'Alt+F12', 'Ctrl+Shift+A', 'Win+9', 'Ctrl+Alt+Shift+Win+F24') {
        $p = ConvertFrom-HotkeyString $text
        Assert-True ($null -ne $p) "$text parsed"
        if ($p) {
            Assert-Equal $text (Format-HotkeyString $p.Modifiers $p.Vk) "$text round-trip"
            Assert-Equal $text (ConvertFrom-HotkeyString (Format-HotkeyString $p.Modifiers $p.Vk)).Text "$text twice"
        }
    }
}

Test-Case 'hotkey: unknown vk prints as VKnn instead of throwing' {
    Assert-Equal 'Ctrl+VK13' (Format-HotkeyString 2 13) 'Enter has no name'
}

# --- ключи режимов -----------------------------------------------------------

Write-Host ''
Write-Host 'mode keys' -ForegroundColor White

Test-Case 'modes: ordinary case gets one solo per display plus a group and all' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'work')
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' 'game')
    )
    $keys = @(Get-DisplayModes $state | ForEach-Object { $_.Key })
    Assert-True ($keys -contains 'solo:LG ULTRAGEAR') 'solo ultragear'
    Assert-True ($keys -contains 'solo:LG ULTRAFINE') 'solo ultrafine'
    Assert-True ($keys -contains 'solo:XG27AQDMGR') 'solo asus'
    Assert-True ($keys -contains 'role:work') 'work group (two LG)'
    Assert-True ($keys -contains 'all') 'all'
    # Игровая группа из одного монитора не показывается — для него есть соло.
    Assert-True (-not ($keys -contains 'role:game')) 'no one-monitor game group'
}

Test-Case 'modes: two identical models get the short id appended' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBB' 'work' 'path-a')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'work' 'path-b')
    )
    $keys = @(Get-DisplayModes $state | Where-Object { $_.Kind -eq 'solo' } | ForEach-Object { $_.Key })
    Assert-Equal 2 $keys.Count 'two solo modes'
    Assert-True ($keys -contains 'solo:LG ULTRAFINE GSM5CBB') 'first keyed by short id'
    Assert-True ($keys -contains 'solo:LG ULTRAFINE GSM5CBC') 'second keyed by short id'
}

Test-Case 'modes: full twins get numbered, and the keys stay distinct' {
    # Одинаковая модель на одинаковом входе: короткий ID это модель, не экземпляр.
    # Раньше оба соло-режима получали ОДИН ключ, и «включить только этот» зажигало
    # оба монитора.
    $state = @(
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBB' 'work' 'path-a')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBB' 'work' 'path-b')
    )
    $solo = @(Get-DisplayModes $state | Where-Object { $_.Kind -eq 'solo' })
    Assert-Equal 2 $solo.Count 'two solo modes'
    $keys = @($solo | ForEach-Object { $_.Key })
    Assert-Equal 2 (@($keys | Sort-Object -Unique)).Count 'keys are distinct'
    Assert-True ($keys[0] -like '*#1') 'first numbered'
    Assert-True ($keys[1] -like '*#2') 'second numbered'
    # И каждый ключ ведёт к своему монитору, а не к обоим.
    Assert-Equal 'path-a' $solo[0].Id 'first points at its own display'
    Assert-Equal 'path-b' $solo[1].Id 'second points at its own display'
}

Test-Case 'modes: a disconnected display still gets a mode, marked unavailable' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work' '' $true $false)
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' 'game' '' $false $true)
    )
    $modes = @(Get-DisplayModes $state)
    $asus = $modes | Where-Object { $_.Key -eq 'solo:XG27AQDMGR' } | Select-Object -First 1
    Assert-True ($null -ne $asus) 'mode exists'
    Assert-True (-not $asus.Available) 'marked not available'
}

Test-Case 'ModeTitleFromKey: every shape' {
    Assert-Equal 'Only LG ULTRAGEAR' (Get-ModeTitleFromKey 'solo:LG ULTRAGEAR') 'solo'
    Assert-Equal 'Only AUSAA1D' (Get-ModeTitleFromKey 'solo:AUSAA1D') 'solo by short id'
    Assert-Equal 'Work displays' (Get-ModeTitleFromKey 'role:work') 'work'
    Assert-Equal 'Game displays' (Get-ModeTitleFromKey 'role:game') 'game'
    # Роли задаёт человек, поэтому имя может быть любым — заголовок строится, а не
    # ищется в списке из двух заранее известных.
    Assert-Equal 'Coding displays' (Get-ModeTitleFromKey 'role:coding') 'a role nobody hardcoded'
    Assert-Equal 'All displays' (Get-ModeTitleFromKey 'all') 'all'
    Assert-Equal 'something else' (Get-ModeTitleFromKey 'something else') 'unknown falls through'
}

# --- миграция привязок -------------------------------------------------------

Write-Host ''
Write-Host 'hotkey migration' -ForegroundColor White

Test-Case 'migration: a binding keyed by the old short id moves to the name key' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:GSM5BB3'] = 'Ctrl+Alt+F1'
    Assert-True (Update-HotkeyKeys $s $state) 'reported a change'
    Assert-True (-not $s.hotkeys.Contains('solo:GSM5BB3')) 'old key gone'
    Assert-Equal 'Ctrl+Alt+F1' $s.hotkeys['solo:LG ULTRAGEAR'] 'moved to the new key'
}

Test-Case 'migration: a longer old name still finds its display' {
    # Раньше название склеивалось из двух полей дампа: «ROG STRIX XG27AQDMGR»,
    # а система знает монитор как «XG27AQDMGR». Одно содержится в другом.
    $state = @((New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'game'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:ROG STRIX XG27AQDMGR'] = 'Ctrl+Alt+F4'
    Assert-True (Update-HotkeyKeys $s $state) 'reported a change'
    Assert-Equal 'Ctrl+Alt+F4' $s.hotkeys['solo:XG27AQDMGR'] 'moved'
}

Test-Case 'migration: an occupied new key is not overwritten' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:GSM5BB3'] = 'Ctrl+Alt+F1'
    $s.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F9'
    [void](Update-HotkeyKeys $s $state)
    Assert-Equal 'Ctrl+Alt+F9' $s.hotkeys['solo:LG ULTRAGEAR'] 'existing binding kept'
    Assert-True $s.hotkeys.Contains('solo:GSM5BB3') 'old one left alone rather than silently dropped'
}

Test-Case 'migration: a binding for an absent display is left untouched' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:AUSAA1D'] = 'Ctrl+Alt+F4'
    Assert-True (-not (Update-HotkeyKeys $s $state)) 'nothing changed'
    Assert-Equal 'Ctrl+Alt+F4' $s.hotkeys['solo:AUSAA1D'] 'still there'
}

Test-Case 'migration: already-current keys are left alone' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
    Assert-True (-not (Update-HotkeyKeys $s $state)) 'no change reported'
}

Test-Case 'migration: empty settings do not blow up' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work'))
    Assert-True (-not (Update-HotkeyKeys $null $state)) 'null settings'
    Assert-True (-not (Update-HotkeyKeys (Get-DefaultSettings) $state)) 'no hotkeys'
}

# --- настройки ---------------------------------------------------------------

Write-Host ''
Write-Host 'settings' -ForegroundColor White

Test-Case 'settings: defaults have the shape the rest of the code expects' {
    $s = Get-DefaultSettings
    Assert-True $s.maximizeRefresh 'maximizeRefresh on'
    Assert-True $s.notifications 'notifications on'
    Assert-True $s.restoreWindows 'restoreWindows on by default'
    Assert-True $s.restoreLastMode 'restoreLastMode on by default'
    Assert-Equal 0 @($s.layout).Count 'layout empty'
    Assert-Equal '' $s.primary 'primary empty'
    Assert-Equal 0 @($s.roles.Keys).Count 'roles empty - no guessing by brand'
    Assert-True (-not $s.autoGame.enabled) 'autoGame off by default'
}

Test-Case 'settings: a damaged file falls back to defaults and keeps a copy' {
    Set-Content -Path $script:SettingsFile -Value '{ this is not json' -Encoding UTF8
    $s = Get-DisplaySettings
    Assert-True $s.maximizeRefresh 'fell back to defaults'
    Assert-True (Test-Path ($script:SettingsFile + '.bad')) 'kept settings.json.bad'
    Remove-Item ($script:SettingsFile + '.bad') -Force
    Remove-Item $script:SettingsFile -Force
}

Test-Case 'settings: a half-written autoGame keeps the other defaults' {
    # Файл правится руками, в нём легко оказаться половине ключей.
    $json = '{ "autoGame": { "enabled": true, "process": "cs2" } }'
    Set-Content -Path $script:SettingsFile -Value $json -Encoding UTF8
    $s = Get-DisplaySettings
    Assert-True $s.autoGame.enabled 'enabled read'
    Assert-Equal 'cs2' $s.autoGame.process 'process read'
    Assert-Equal '' $s.autoGame.gameMode 'gameMode stayed default, not null'
    Assert-Equal '' $s.autoGame.backMode 'backMode stayed default, not null'
    Remove-Item $script:SettingsFile -Force
}

Test-Case 'settings: restoreLastMode survives a round-trip when turned off' {
    # Отсутствие ключа означает «по умолчанию», то есть включено, — а вот честный
    # false обязан доехать. На этой паре уже ломался restoreWindows.
    Set-Content -Path $script:SettingsFile -Value '{ "restoreLastMode": false }' -Encoding UTF8
    $s = Get-DisplaySettings
    Assert-True (-not $s.restoreLastMode) 'false read from the file'
    Remove-Item $script:SettingsFile -Force

    Assert-True (Get-DisplaySettings).restoreLastMode 'no file at all means the default, on'
}

Test-Case 'settings: round-trip through disk preserves everything' {
    $s = Get-DefaultSettings
    $s.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
    $s.layout = @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR')
    $s.primary = 'ULTRAGEAR'
    $s.restoreWindows = $false
    $s.audio['role:work'] = 'ULTRAFINE'
    Save-DisplaySettings $s

    $back = Get-DisplaySettings
    Assert-Equal 'Ctrl+Alt+F1' $back.hotkeys['solo:LG ULTRAGEAR'] 'hotkey'
    Assert-Equal @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR') @($back.layout) 'layout with order'
    Assert-Equal 'ULTRAGEAR' $back.primary 'primary'
    Assert-True (-not $back.restoreWindows) 'restoreWindows false survived'
    Assert-Equal 'ULTRAFINE' $back.audio['role:work'] 'audio mapping'
    Remove-Item $script:SettingsFile -Force
}

Test-Case 'settings: roles survive a round-trip through disk' {
    $s = Get-DefaultSettings
    $s.roles['LG ULTRAGEAR'] = 'work'
    $s.roles['XG27AQDMGR'] = 'game'
    Save-DisplaySettings $s

    $back = Get-DisplaySettings
    Assert-Equal 'work' $back.roles['LG ULTRAGEAR'] 'first role'
    Assert-Equal 'game' $back.roles['XG27AQDMGR'] 'second role'
    Assert-Equal @('LG ULTRAGEAR', 'XG27AQDMGR') @($back.roles.Keys) 'order kept - first match wins, so it matters'
    Remove-Item $script:SettingsFile -Force
}

# --- роли мониторов ----------------------------------------------------------
# Роль монитора — решение человека, а не свойство железа. Раньше она угадывалась
# по бренду прямо в коде (AUS/ROG/XG -> game, GSM/LG -> work), то есть описывала
# один конкретный стол: у соседа LG UltraGear — игровой монитор, и никакая
# эвристика этого не узнает. Теперь роли живут в settings.json.

Write-Host ''
Write-Host 'display roles' -ForegroundColor White

Test-Case 'roles: a pattern is found inside the display name' {
    $roles = [ordered]@{ 'ULTRAGEAR' = 'work' }
    Assert-Equal 'work' (Get-MonitorRole -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3' -Roles $roles) 'part of the name'
}

Test-Case 'roles: a pattern longer than the name still matches' {
    # Система знает монитор как XG27AQDMGR, а человек пишет так, как написано на
    # коробке. То же правило, что у layout и primary.
    $roles = [ordered]@{ 'ROG STRIX XG27AQDMGR' = 'game' }
    Assert-Equal 'game' (Get-MonitorRole -Label 'XG27AQDMGR' -ShortId 'AUSAA1D' -Roles $roles) 'contains the other way round'
}

Test-Case 'roles: case does not matter, and the short id works too' {
    Assert-Equal 'work' (Get-MonitorRole -Label 'LG ULTRAFINE' -ShortId 'GSM5CBC' -Roles ([ordered]@{ 'ultrafine' = 'work' })) 'lower case pattern'
    Assert-Equal 'game' (Get-MonitorRole -Label 'XG27AQDMGR' -ShortId 'AUSAA1D' -Roles ([ordered]@{ 'AUSAA1D' = 'game' })) 'by short id'
}

Test-Case 'roles: no settings means no role, not a guess' {
    # Ровно то, что делала старая эвристика: ASUS объявлялся игровым сам.
    Assert-Equal '' (Get-MonitorRole -Label 'ROG STRIX XG27AQDMGR' -ShortId 'AUSAA1D' -Roles ([ordered]@{})) 'empty settings'
    Assert-Equal '' (Get-MonitorRole -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3' -Roles $null) 'null settings'
}

Test-Case 'roles: the first matching pattern wins' {
    # Порядок в файле и есть порядок разбора — поэтому словарь [ordered].
    $roles = [ordered]@{ 'LG' = 'work'; 'LG ULTRAGEAR' = 'game' }
    Assert-Equal 'work' (Get-MonitorRole -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3' -Roles $roles) 'earlier entry'
}

Test-Case 'roles: an empty pattern matches nothing' {
    # Пустая строка как ключ означала бы «подходит всем»: -like '**' истинно.
    Assert-Equal '' (Get-MonitorRole -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3' -Roles ([ordered]@{ '' = 'work' })) 'blank key ignored'
}

Test-Case 'roles: a group mode appears for any role name, not just work and game' {
    $state = @(
        (New-FakeMonitor 'DELL U2720Q'  'DEL1234' 'coding')
        (New-FakeMonitor 'DELL U2419H'  'DEL5678' 'coding')
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'game')
    )
    $keys = @(Get-DisplayModes $state | ForEach-Object { $_.Key })
    Assert-True ($keys -contains 'role:coding') 'the group the user invented'
    Assert-True (-not ($keys -contains 'role:game')) 'still no group for a single display'
    $coding = Get-DisplayModes $state | Where-Object { $_.Key -eq 'role:coding' } | Select-Object -First 1
    Assert-Equal 'Coding displays' $coding.Title 'title built from the role name'
}

Test-Case 'roles: displays without a role produce no groups at all' {
    # Первый запуск на чужой машине: настроек нет, роли пустые. Должны остаться
    # соло-режимы и «все» — и ничего не должно упасть.
    $state = @(
        (New-FakeMonitor 'DELL U2720Q' 'DEL1234' '')
        (New-FakeMonitor 'DELL U2419H' 'DEL5678' '')
    )
    $modes = @(Get-DisplayModes $state)
    $keys = @($modes | ForEach-Object { $_.Key })
    Assert-Equal 0 @($modes | Where-Object { $_.Kind -eq 'role' }).Count 'no group modes'
    Assert-True ($keys -contains 'solo:DELL U2720Q') 'solo modes are still there'
    Assert-True ($keys -contains 'all') 'and all'
}

Test-Case 'roles: group modes come out sorted, so the menu does not reshuffle itself' {
    # Порядок мониторов в перечислении CCD меняется от переподключения кабеля.
    $state = @(
        (New-FakeMonitor 'A1' 'AAA1111' 'zebra')
        (New-FakeMonitor 'A2' 'AAA2222' 'zebra')
        (New-FakeMonitor 'B1' 'BBB1111' 'alpha')
        (New-FakeMonitor 'B2' 'BBB2222' 'alpha')
    )
    $roleKeys = @(Get-DisplayModes $state | Where-Object { $_.Kind -eq 'role' } | ForEach-Object { $_.Key })
    Assert-Equal @('role:alpha', 'role:zebra') $roleKeys 'alphabetical, not enumeration order'
}

Test-Case 'merge: a role for a display that is not on the desk is kept' {
    # Окно настроек показывает только подключённые мониторы. Если сохранять из
    # формы «как есть», записи для остальных исчезали бы на каждом Save — ровно
    # так этот проект однажды терял layout и primary.
    $existing = [ordered]@{ 'LG ULTRAGEAR' = 'work'; 'SOME OTHER MONITOR' = 'game' }
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work'))
    $assigned = [ordered]@{ 'LG ULTRAGEAR' = 'work' }

    $merged = Merge-RoleSettings -Existing $existing -Assigned $assigned -State $state
    Assert-Equal 'game' $merged['SOME OTHER MONITOR'] 'the absent display kept its role'
    Assert-Equal 'work' $merged['LG ULTRAGEAR'] 'the connected one came from the form'
}

Test-Case 'merge: clearing the box removes the role' {
    $existing = [ordered]@{ 'LG ULTRAGEAR' = 'work' }
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work'))
    $merged = Merge-RoleSettings -Existing $existing -Assigned ([ordered]@{ 'LG ULTRAGEAR' = '   ' }) -State $state
    Assert-Equal 0 @($merged.Keys).Count 'blank means no role'
}

Test-Case 'merge: a wildcard pattern is replaced by the exact name it covered' {
    # Человек написал руками "LG" на оба монитора, потом поправил роль одного в
    # окне. Оставить обе записи нельзя: шаблон продолжал бы навязывать роль.
    $existing = [ordered]@{ 'LG' = 'work' }
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'work')
    )
    $assigned = [ordered]@{ 'LG ULTRAGEAR' = 'game'; 'LG ULTRAFINE' = 'work' }
    $merged = Merge-RoleSettings -Existing $existing -Assigned $assigned -State $state
    Assert-True (-not $merged.Contains('LG')) 'the pattern is gone'
    Assert-Equal 'game' $merged['LG ULTRAGEAR'] 'new role stuck'
    Assert-Equal 'work' $merged['LG ULTRAFINE'] 'the other one kept its own'
}

Test-Case 'merge: nothing configured anywhere is an empty map, not a crash' {
    $merged = Merge-RoleSettings -Existing $null -Assigned $null -State @()
    Assert-Equal 0 @($merged.Keys).Count 'empty'
}

# --- регрессия бага этапа 1 --------------------------------------------------

Write-Host ''
Write-Host 'stage 1 regression: Save must not eat non-UI settings' -ForegroundColor White

Test-Case 'regression: the Save branch keeps layout, primary and every non-UI field' {
    # Собираем форму БЕЗ показа и повторяем ветку сохранения так, как её проходит
    # Show-SettingsDialog. Полный путь с ShowDialog проверяется живьём, здесь
    # важно, что поля не теряются.
    $modes = @(
        [pscustomobject]@{ Key = 'solo:LG ULTRAGEAR'; Title = 'Only LG ULTRAGEAR'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    )
    $settings = Get-DefaultSettings
    $settings.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
    $settings.layout = @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR')
    $settings.primary = 'ULTRAGEAR'
    $settings.audio['role:work'] = 'ULTRAFINE'
    $settings.autoGame.enabled = $true
    $settings.autoGame.process = 'cs2'

    $ui = New-SettingsForm -Modes $modes -Settings $settings
    try {
        Assert-True ($null -ne $ui.WindowsBox) 'the form has the window-memory checkbox'
        Assert-True $ui.WindowsBox.Checked 'it reflects the default (on)'

        # Ровно то, что делает Show-SettingsDialog после OK.
        $newHotkeys = [ordered]@{}
        foreach ($key in $ui.Boxes.Keys) {
            $parsed = ConvertFrom-HotkeyString $ui.Boxes[$key].Text
            if ($parsed) { $newHotkeys[$key] = $parsed.Text }
        }
        $updated = Get-DefaultSettings
        $updated.hotkeys = $newHotkeys
        $updated.maximizeRefresh = $ui.RefreshBox.Checked
        $updated.notifications = $ui.NotifyBox.Checked
        $updated.restoreWindows = $ui.WindowsBox.Checked
        $updated.restoreLastMode = $ui.LastModeBox.Checked
        $fromForm = @('hotkeys', 'maximizeRefresh', 'notifications', 'restoreWindows', 'restoreLastMode')
        foreach ($k in @($settings.Keys)) {
            if ($fromForm -contains $k) { continue }
            $updated[$k] = $settings[$k]
        }
        $updated.layout = @($settings.layout | ForEach-Object { [string]$_ })
        $updated.primary = [string]$settings.primary

        Assert-Equal @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR') @($updated.layout) 'layout survived'
        Assert-Equal 'ULTRAGEAR' $updated.primary 'primary survived'
        Assert-Equal 'ULTRAFINE' $updated.audio['role:work'] 'audio survived'
        Assert-True $updated.autoGame.enabled 'autoGame survived'
        Assert-Equal 'cs2' $updated.autoGame.process 'autoGame process survived'
        Assert-Equal 'Ctrl+Alt+F1' $updated.hotkeys['solo:LG ULTRAGEAR'] 'hotkey came from the form'
    }
    finally { $ui.Form.Dispose() }
}

Test-Case 'regression: the REAL Save path keeps layout and primary' {
    # Тест выше повторяет логику сохранения — значит он проверяет замысел, но не
    # сам код: сломай Show-SettingsDialog, и он останется зелёным. Поэтому здесь
    # вызывается настоящая функция, а таймер жмёт Save по уже показанной форме.
    # Именно этот тест краснеет, если фикс этапа 1 откатить.
    #
    # Таймером можно закрывать обычную форму; наглухо вешается только MessageBox,
    # а он тут не появляется — дублей комбинаций нет.
    $modes = @(
        [pscustomobject]@{ Key = 'solo:LG ULTRAGEAR'; Title = 'Only LG ULTRAGEAR'; Kind = 'solo'; Available = $true }
    )
    $settings = Get-DefaultSettings
    $settings.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
    $settings.layout = @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR')
    $settings.primary = 'ULTRAGEAR'

    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work'))

    # Ярлык автозагрузки — не дело тестов. Функция ищется по имени в момент
    # вызова, поэтому определение здесь перекрывает то, что в DisplayCore.
    function Set-RunAtStartup { param([bool]$Enabled) }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 700
    $timer.add_Tick({
        $timer.Stop()
        $f = [System.Windows.Forms.Application]::OpenForms |
             Where-Object { $_.Text -like '*Settings*' } | Select-Object -First 1
        if ($f) { $f.DialogResult = [System.Windows.Forms.DialogResult]::OK; $f.Close() }
    })
    $timer.Start()
    $updated = Show-SettingsDialog -State $state -Settings $settings
    $timer.Dispose()

    Assert-True ($null -ne $updated) 'Save returned settings'
    if ($updated) {
        Assert-Equal @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR') @($updated.layout) 'layout survived the real Save'
        Assert-Equal 'ULTRAGEAR' $updated.primary 'primary survived the real Save'
        Assert-Equal 'Ctrl+Alt+F1' $updated.hotkeys['solo:LG ULTRAGEAR'] 'hotkey kept'
        # Роль монитора приехала из строки в окне, а не из угадывания по бренду.
        Assert-Equal 'work' $updated.roles['LG ULTRAGEAR'] 'the role box was saved'
    }
    # И на диске тоже — писали в подменённый файл, не в настоящий.
    Assert-True (Test-Path $script:SettingsFile) 'wrote the settings file'
    if (Test-Path $script:SettingsFile) {
        $disk = Get-Content $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal 3 @($disk.layout).Count 'layout on disk'
        Assert-Equal 'ULTRAGEAR' ([string]$disk.primary) 'primary on disk'
        Remove-Item $script:SettingsFile -Force
    }
}

Test-Case 'regression: the box dictionary is ordered so Save does not shuffle the file' {
    $modes = @(
        [pscustomobject]@{ Key = 'solo:A'; Title = 'Only A'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'solo:B'; Title = 'Only B'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'role:work'; Title = 'Work displays'; Kind = 'role'; Available = $true }
        [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    )
    $ui = New-SettingsForm -Modes $modes -Settings (Get-DefaultSettings)
    try {
        Assert-Equal @('solo:A', 'solo:B', 'role:work', 'all') @($ui.Boxes.Keys) 'boxes keep mode order'
    }
    finally { $ui.Form.Dispose() }
}

# --- Resolve-ModeKey из Set-Display.ps1 --------------------------------------

Write-Host ''
Write-Host 'command line mode resolution' -ForegroundColor White

# Set-Display.ps1 дот-сорснуть нельзя — он сразу начинает работать. Достаём из
# него только определение функции, по разбору файла: так тест не зависит от
# копии кода, которая разошлась бы с оригиналом.
$sdPath = Join-Path $root 'Set-Display.ps1'
$sdAst = [System.Management.Automation.Language.Parser]::ParseFile($sdPath, [ref]$null, [ref]$null)
$fnAst = $sdAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-ModeKey' }, $true)
if ($fnAst.Count -ne 1) { throw "expected exactly one Resolve-ModeKey in Set-Display.ps1, found $($fnAst.Count)" }
. ([scriptblock]::Create($fnAst[0].Extent.Text))

$script:ResolveState = @(
    (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work')
    (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'work')
    (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' 'game')
)
$script:ResolveModes = @(Get-DisplayModes $script:ResolveState)

Test-Case 'resolve: an exact key' {
    Assert-Equal 'all' (Resolve-ModeKey 'all' $script:ResolveModes $script:ResolveState).Key 'all'
    Assert-Equal 'role:work' (Resolve-ModeKey 'role:work' $script:ResolveModes $script:ResolveState).Key 'role:work'
}

Test-Case 'resolve: a short group name' {
    Assert-Equal 'role:work' (Resolve-ModeKey 'work' $script:ResolveModes $script:ResolveState).Key 'work'
}

Test-Case 'resolve: a short monitor id' {
    Assert-Equal 'solo:LG ULTRAFINE' (Resolve-ModeKey 'GSM5CBC' $script:ResolveModes $script:ResolveState).Key 'by short id'
}

Test-Case 'resolve: part of a monitor name' {
    Assert-Equal 'solo:LG ULTRAGEAR' (Resolve-ModeKey 'ULTRAGEAR' $script:ResolveModes $script:ResolveState).Key 'by name part'
}

Test-Case 'resolve: game with a single gaming display lands on its solo mode' {
    # Группа из одного монитора в меню не показывается, но по имени находиться
    # обязана.
    Assert-Equal 'solo:XG27AQDMGR' (Resolve-ModeKey 'game' $script:ResolveModes $script:ResolveState).Key 'game'
}

Test-Case 'resolve: a role name the user invented resolves too' {
    # Список 'work', 'game' в Resolve-ModeKey был жёстким; роли теперь свои.
    $state = @(
        (New-FakeMonitor 'DELL U2720Q'  'DEL1234' 'coding')
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'streaming')
    )
    $modes = @(Get-DisplayModes $state)
    Assert-Equal 'solo:DELL U2720Q' (Resolve-ModeKey 'coding' $modes $state).Key 'single-member role lands on its solo mode'
}

Test-Case 'resolve: an ambiguous name is refused, not guessed' {
    $threw = $false
    try { [void](Resolve-ModeKey 'LG' $script:ResolveModes $script:ResolveState) }
    catch { $threw = $true; Assert-True ($_.Exception.Message -like '*matches several modes*') 'said why' }
    Assert-True $threw 'threw on ambiguity'
}

Test-Case 'resolve: an unknown name is refused with a hint' {
    $threw = $false
    try { [void](Resolve-ModeKey 'nosuchthing' $script:ResolveModes $script:ResolveState) }
    catch { $threw = $true; Assert-True ($_.Exception.Message -like '*Unknown mode*') 'said unknown' }
    Assert-True $threw 'threw on unknown'
}

# --- ключ раскладки столов ---------------------------------------------------

Write-Host ''
Write-Host 'window layout keys' -ForegroundColor White

Test-Case 'layout key: same set in any order gives the same key' {
    $k1 = Get-DisplayLayoutKey -DevicePaths @('b', 'a', 'c')
    $k2 = Get-DisplayLayoutKey -DevicePaths @('c', 'b', 'a')
    Assert-Equal $k1 $k2 'order does not matter'
    Assert-Equal 'a|b|c' $k1 'sorted and joined'
}

Test-Case 'layout key: different sets give different keys' {
    $two = Get-DisplayLayoutKey -DevicePaths @('a', 'b')
    $three = Get-DisplayLayoutKey -DevicePaths @('a', 'b', 'c')
    Assert-True ($two -ne $three) 'two displays differ from three'
}

Test-Case 'layout key: built from state uses only active displays' {
    $state = @(
        (New-FakeMonitor 'A' 'AAA1111' 'work' 'path-a' $true)
        (New-FakeMonitor 'B' 'BBB2222' 'work' 'path-b' $false)
    )
    Assert-Equal 'path-a' (Get-DisplayLayoutKey -State $state) 'only the active one'
}

Test-Case 'layout key: nothing active gives an empty key, not a crash' {
    $state = @((New-FakeMonitor 'A' 'AAA1111' 'work' 'path-a' $false))
    Assert-Equal '' (Get-DisplayLayoutKey -State $state) 'empty'
}

Test-Case 'layout key: empty and blank paths are ignored' {
    Assert-Equal 'a' (Get-DisplayLayoutKey -DevicePaths @('a', '', $null)) 'blanks dropped'
}

# --- ретрай раскладки и вердикт переключения ----------------------------------
# 17 августа 2026: валидация раскладки вернула 87 сразу после смены топологии,
# единственная попытка молча провалилась, а переключение отчиталось успехом — и
# мониторы до следующего хоткея стояли перепутанными. Отсюда два свойства,
# которые здесь прибиты тестами: раскладка повторяется, провал попадает в вердикт.

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

Test-Case 'verdict: clean success' {
    $v = Format-SwitchResult -Summary @('A 1x1 @ 1 Hz', 'B 2x2 @ 2 Hz')
    Assert-True $v.Ok 'ok'
    Assert-Equal 'A 1x1 @ 1 Hz, B 2x2 @ 2 Hz' $v.Text 'plain summary'
}

Test-Case 'verdict: a failed layout is not a success' {
    # Регрессия 17 августа: трей показал зелёное «Displays switched», хотя
    # мониторы стояли не в том порядке.
    $v = Format-SwitchResult -Summary @('A') -LayoutFailed $true
    Assert-True (-not $v.Ok) 'not ok'
    Assert-True ($v.Text -like '*positions not arranged*') 'says what went wrong'
    Assert-True ($v.Text -like '*press the hotkey*') 'and what to do about it'
}

Test-Case 'verdict: every problem lands in the text' {
    $v = Format-SwitchResult -Summary @('A') -Failed @('B') -Refused @('C') -LayoutFailed $true
    Assert-True (-not $v.Ok) 'not ok'
    Assert-True ($v.Text -like 'A*') 'summary first'
    Assert-True ($v.Text -like '*did not come up: B*') 'the display that failed'
    Assert-True ($v.Text -like '*Still on: C*') 'the display that refused to turn off'
    Assert-True ($v.Text -like '*positions not arranged*') 'the layout'
}

Test-Case 'verdict: problems without a summary still read as a sentence' {
    # Пустая сводка бывает, когда ни один монитор не прицепился; текст не должен
    # начинаться с точки.
    $v = Format-SwitchResult -Summary @() -Failed @('B')
    Assert-True (-not $v.Ok) 'not ok'
    Assert-True ($v.Text -like 'did not come up*') 'starts with the problem, not punctuation'
}

# --- последний выбранный режим -----------------------------------------------

Write-Host ''
Write-Host 'the remembered mode' -ForegroundColor White

Test-Case 'last mode: nothing remembered yet gives null, not a crash' {
    if (Test-Path $script:LastModeFile) { Remove-Item $script:LastModeFile -Force }
    Assert-Null (Get-LastMode) 'no file, no mode'
}

Test-Case 'last mode: a saved mode comes back with its session stamp' {
    Save-LastMode -Key 'solo:XG27AQDMGR'
    $last = Get-LastMode
    Assert-Equal 'solo:XG27AQDMGR' $last.Key 'key'
    Assert-Equal (Get-SystemSessionId) $last.Session 'stamped with the current session'
    Assert-True ([bool]$last.When) 'remembered when it happened'
    Remove-Item $script:LastModeFile -Force
}

Test-Case 'last mode: a damaged file reads as nothing remembered' {
    Set-Content -Path $script:LastModeFile -Value '{ broken' -Encoding UTF8
    Assert-Null (Get-LastMode) 'unreadable file is not a mode'
    Remove-Item $script:LastModeFile -Force
}

Test-Case 'last mode: a file without a key reads as nothing remembered' {
    # Так выглядел бы файл, дописанный до конца не полностью.
    Set-Content -Path $script:LastModeFile -Value '{"session":"x","when":"y"}' -Encoding UTF8
    Assert-Null (Get-LastMode) 'no key, no mode'
    Remove-Item $script:LastModeFile -Force
}

# --- возврат режима при старте трея ------------------------------------------
# Живьём это проверяется только перезагрузкой, поэтому решение («возвращать или
# не трогать») тестируем отдельно от самого переключения. Функцию достаём из
# Displays.ps1 разбором файла — дот-сорснуть его нельзя, он поднимает всё
# приложение, а копия кода в тесте разошлась бы с оригиналом (тот же приём, что и
# для Resolve-ModeKey выше).

Write-Host ''
Write-Host 'restoring the mode when the tray starts' -ForegroundColor White

$trayAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Displays.ps1'), [ref]$null, [ref]$null)
$srAst = $trayAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-StartupRestore' }, $true)
if ($srAst.Count -ne 1) { throw "expected exactly one Invoke-StartupRestore in Displays.ps1, found $($srAst.Count)" }
. ([scriptblock]::Create($srAst[0].Extent.Text))

# Окружение трея, которое эта функция вокруг себя ожидает.
$script:TestSettings = Get-DefaultSettings
$script:TestState = @()
$script:Invoked = $null
$script:SwitchedOnce = $false

function Get-ActiveSettings { return $script:TestSettings }
function Get-CachedState { return $script:TestState }
function Invoke-Mode {
    param([string]$Key, [switch]$Auto, [switch]$Silent)
    $script:Invoked = [pscustomobject]@{ Key = $Key; Auto = [bool]$Auto; Silent = [bool]$Silent }
}

# Включён только ASUS, все три монитора подключены — то же, что было на столе
# 12 августа.
function Set-RestoreScene {
    param([bool]$UltraGearConnected = $true)
    $script:TestState = @(
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' 'game' 'path-asus'      $true)
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work' 'path-ultragear' $false (-not $UltraGearConnected))
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'work' 'path-ultrafine' $false)
    )
    $script:Invoked = $null
    $script:SwitchedOnce = $false
    $script:TestSettings = Get-DefaultSettings
}

# Запомненный режим из ПРОШЛОГО включения машины: сессия чужая.
function Set-RememberedMode {
    param([string]$Key, [string]$Session = 'a-previous-boot')
    ([ordered]@{ key = $Key; session = $Session; when = '2026-08-12T15:28:25' } | ConvertTo-Json -Compress) |
        Set-Content -Path $script:LastModeFile -Encoding UTF8
}

Test-Case 'startup: a mode chosen before the last shutdown comes back' {
    Set-RestoreScene
    Set-RememberedMode 'solo:LG ULTRAGEAR'
    Invoke-StartupRestore
    Assert-True ($null -ne $script:Invoked) 'switched'
    if ($script:Invoked) {
        Assert-Equal 'solo:LG ULTRAGEAR' $script:Invoked.Key 'to the remembered mode'
        Assert-True (-not $script:Invoked.Silent) 'the set really changes, so say so in a balloon'
    }
}

Test-Case 'startup: the same session means the tray was restarted - do not touch the displays' {
    # Иначе перезапуск трея отменял бы Win+P или ручную правку в параметрах Windows.
    Set-RestoreScene
    Set-RememberedMode 'solo:LG ULTRAGEAR' (Get-SystemSessionId)
    Invoke-StartupRestore
    Assert-Null $script:Invoked 'left alone'
}

Test-Case 'startup: the right set already on means no balloon, only a layout check' {
    Set-RestoreScene
    Set-RememberedMode 'solo:XG27AQDMGR'
    Invoke-StartupRestore
    Assert-True ($null -ne $script:Invoked) 'still called - layout and primary may have drifted'
    if ($script:Invoked) { Assert-True $script:Invoked.Silent 'but silently' }
}

Test-Case 'startup: all-vs-work with the ASUS unplugged is the same desk, so no balloon' {
    # Ключи режимов разные, а стол один: сравнение по ключам объявило бы
    # переключением то, чего не происходит.
    $script:TestState = @(
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' 'game' 'path-asus'      $false $true)
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'work' 'path-ultragear' $true)
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'work' 'path-ultrafine' $true)
    )
    $script:Invoked = $null
    $script:SwitchedOnce = $false
    $script:TestSettings = Get-DefaultSettings
    Set-RememberedMode 'all'
    Invoke-StartupRestore
    Assert-True ($null -ne $script:Invoked) 'still checks the layout'
    if ($script:Invoked) { Assert-True $script:Invoked.Silent 'but silently - the same displays are on' }
}

Test-Case 'startup: a display that is not there is never restored to' {
    # Самая дорогая ошибка из возможных: погасить работающий монитор ради того,
    # которого нет, — это чёрный стол после включения компьютера.
    Set-RestoreScene -UltraGearConnected $false
    Set-RememberedMode 'solo:LG ULTRAGEAR'
    Invoke-StartupRestore
    Assert-Null $script:Invoked 'nothing was turned off'
}

Test-Case 'startup: a mode key that no longer exists is not a crash' {
    Set-RestoreScene
    Set-RememberedMode 'solo:SOME OLD MONITOR'
    Invoke-StartupRestore
    Assert-Null $script:Invoked 'skipped'
}

Test-Case 'startup: a hotkey pressed first wins - his choice is newer than ours' {
    Set-RestoreScene
    Set-RememberedMode 'solo:LG ULTRAGEAR'
    $script:SwitchedOnce = $true
    Invoke-StartupRestore
    Assert-Null $script:Invoked 'we stay out of it'
}

Test-Case 'startup: turned off in settings means nothing happens' {
    Set-RestoreScene
    Set-RememberedMode 'solo:LG ULTRAGEAR'
    $script:TestSettings.restoreLastMode = $false
    Invoke-StartupRestore
    Assert-Null $script:Invoked 'off is off'
}

Test-Case 'startup: nothing remembered at all means nothing happens' {
    Set-RestoreScene
    if (Test-Path $script:LastModeFile) { Remove-Item $script:LastModeFile -Force }
    Invoke-StartupRestore
    Assert-Null $script:Invoked 'first run ever'
}

Test-Case 'session id: the same within one run, and not empty' {
    # Ровно на этом равенстве держится «трей перезапустили, экраны не трогаем».
    $a = Get-SystemSessionId
    $b = Get-SystemSessionId
    Assert-Equal $a $b 'stable inside one process'
    Assert-True ($a.Length -gt 0) 'not empty'
    Assert-True ($a -like '*/*') 'built from both sources'
}

# --- итог --------------------------------------------------------------------

Remove-Item -LiteralPath $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\MMT_LOG_FILE -ErrorAction SilentlyContinue

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
