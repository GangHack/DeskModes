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
$script:ModeCacheFile = Join-Path $script:TestDir 'display-modes.json'

# Фиктивные мониторы: тесты не должны зависеть от того, что сейчас на столе.
# Поля ровно те, что отдаёт Get-DisplayState: роли из состояния ушли вместе с
# самим понятием (роли переехали в комбинации), и фальшивка не должна знать о
# полях, которых у настоящего состояния нет.
function New-FakeMonitor {
    param([string]$Label, [string]$ShortId, [string]$Id = '',
          [bool]$Active = $true, [bool]$Disconnected = $false)
    if (-not $Id) { $Id = 'path-' + $Label + '-' + $ShortId }
    return [pscustomobject]@{
        Output = '\\.\DISPLAY1'; Label = $Label; Model = $Label; ShortId = $ShortId
        Native = $null; Id = $Id; Active = $Active
        Primary = $false; Disconnected = $Disconnected
        Width = 2560; Height = 1440; Hz = 144; BestMode = $null
    }
}

# Настройки с комбинациями, одной строкой: раньше почти каждый тест писал роли.
function New-TestSettings {
    param([hashtable]$Combos = @{})
    $s = Get-DefaultSettings
    foreach ($name in $Combos.Keys) {
        $v = $Combos[$name]
        $displays = @()
        $primary = ''
        if ($v -is [array]) { $displays = @($v) }
        elseif ($v -is [hashtable]) { $displays = @($v.displays); $primary = [string]$v.primary }
        else { $displays = @([string]$v) }
        $s.combos[$name] = [ordered]@{ displays = $displays; primary = $primary }
    }
    return $s
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

Test-Case 'modes: a fresh desk gets one mode per display plus all, and nothing else' {
    # Что видит человек, впервые подключивший три монитора: три отдельных режима и
    # «все». Ничего не угадывается — ни групп, ни наборов; они появляются только
    # после того, как он сам их создаст.
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D')
    )
    $modes = @(Get-DisplayModes $state (Get-DefaultSettings))
    $keys = @($modes | ForEach-Object { $_.Key })
    Assert-Equal 4 $modes.Count 'three displays plus all - nothing invented'
    Assert-True ($keys -contains 'solo:LG ULTRAGEAR') 'solo ultragear'
    Assert-True ($keys -contains 'solo:LG ULTRAFINE') 'solo ultrafine'
    Assert-True ($keys -contains 'solo:XG27AQDMGR') 'solo asus'
    Assert-True ($keys -contains 'all') 'all'
    Assert-Equal 0 @($modes | Where-Object { $_.Kind -eq 'combo' }).Count 'no combinations out of thin air'
}

Test-Case 'modes: two identical models get the short id appended' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBB' 'path-a')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-b')
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
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBB' 'path-a')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBB' 'path-b')
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
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' '' $true $false)
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' '' $false $true)
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
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:GSM5BB3'] = 'Ctrl+Alt+F1'
    Assert-True (Update-HotkeyKeys $s $state) 'reported a change'
    Assert-True (-not $s.hotkeys.Contains('solo:GSM5BB3')) 'old key gone'
    Assert-Equal 'Ctrl+Alt+F1' $s.hotkeys['solo:LG ULTRAGEAR'] 'moved to the new key'
}

Test-Case 'migration: a longer old name still finds its display' {
    # Раньше название склеивалось из двух полей дампа: «ROG STRIX XG27AQDMGR»,
    # а система знает монитор как «XG27AQDMGR». Одно содержится в другом.
    $state = @((New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:ROG STRIX XG27AQDMGR'] = 'Ctrl+Alt+F4'
    Assert-True (Update-HotkeyKeys $s $state) 'reported a change'
    Assert-Equal 'Ctrl+Alt+F4' $s.hotkeys['solo:XG27AQDMGR'] 'moved'
}

Test-Case 'migration: an occupied new key is not overwritten' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:GSM5BB3'] = 'Ctrl+Alt+F1'
    $s.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F9'
    [void](Update-HotkeyKeys $s $state)
    Assert-Equal 'Ctrl+Alt+F9' $s.hotkeys['solo:LG ULTRAGEAR'] 'existing binding kept'
    Assert-True $s.hotkeys.Contains('solo:GSM5BB3') 'old one left alone rather than silently dropped'
}

Test-Case 'migration: a binding for an absent display is left untouched' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:AUSAA1D'] = 'Ctrl+Alt+F4'
    Assert-True (-not (Update-HotkeyKeys $s $state)) 'nothing changed'
    Assert-Equal 'Ctrl+Alt+F4' $s.hotkeys['solo:AUSAA1D'] 'still there'
}

Test-Case 'migration: already-current keys are left alone' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    $s = Get-DefaultSettings
    $s.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
    Assert-True (-not (Update-HotkeyKeys $s $state)) 'no change reported'
}

Test-Case 'migration: empty settings do not blow up' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
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


# --- совпадение названий -------------------------------------------------------
# Одно правило на всё, где человек называет монитор словами: layout, primary,
# состав комбинации. Раньше называлось Test-RolePatternMatch и жило ради ролей.

Write-Host ''
Write-Host 'display name matching' -ForegroundColor White

Test-Case 'names: a pattern is found inside the display name' {
    Assert-True (Test-DisplayNameMatch -Pattern 'ULTRAGEAR' -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3') 'part of the name'
}

Test-Case 'names: a pattern longer than the name still matches' {
    # Система знает монитор как XG27AQDMGR, а человек пишет так, как написано на
    # коробке. Совпадение проверяется в обе стороны.
    Assert-True (Test-DisplayNameMatch -Pattern 'ROG STRIX XG27AQDMGR' -Label 'XG27AQDMGR' -ShortId 'AUSAA1D') 'contains the other way round'
}

Test-Case 'names: case does not matter, and the short id works too' {
    Assert-True (Test-DisplayNameMatch -Pattern 'ultrafine' -Label 'LG ULTRAFINE' -ShortId 'GSM5CBC') 'lower case pattern'
    Assert-True (Test-DisplayNameMatch -Pattern 'AUSAA1D' -Label 'XG27AQDMGR' -ShortId 'AUSAA1D') 'by short id'
}

Test-Case 'names: an empty pattern matches nothing' {
    # Пустая строка как шаблон означала бы «подходит всем»: -like '**' истинно.
    Assert-True (-not (Test-DisplayNameMatch -Pattern '' -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3')) 'blank matches nothing'
}

Test-Case 'names: an unrelated name does not match' {
    Assert-True (-not (Test-DisplayNameMatch -Pattern 'DELL' -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3')) 'no false positive'
}

# --- переезд ролей в комбинации ------------------------------------------------
# Роли были вторым, более слабым способом сказать то же, что говорит комбинация:
# одна на монитор, без своей панели задач, и удалялась не там, где показана.
# Старый settings.json обязан переехать сам, вместе с клавишами, звуком и
# авто-игровым режимом, — иначе переезд выглядит как «настройки сбросились».

Write-Host ''
Write-Host 'legacy display groups moving into combinations' -ForegroundColor White

Test-Case 'migration: a shared role becomes a combination named after it' {
    $s = Get-DefaultSettings
    $s.roles['LG ULTRAFINE'] = 'work'
    $s.roles['LG ULTRAGEAR'] = 'work'
    Assert-True (Convert-RoleSettingsToCombos $s) 'reported a change'
    Assert-Equal @('Work') @($s.combos.Keys) 'one combination, name capitalised'
    Assert-Equal @('LG ULTRAFINE', 'LG ULTRAGEAR') @($s.combos['Work'].displays) 'both displays, in file order'
    Assert-Equal '' $s.combos['Work'].primary 'a role had no taskbar display of its own'
    Assert-Equal 0 @($s.roles.Keys).Count 'roles emptied'
}

Test-Case 'migration: a role on a single display becomes a combination too' {
    # У ролей режим появлялся только на двоих, поэтому одиночная роль не давала
    # ничего, кроме имени для командной строки. Теперь она честно становится
    # набором из одного монитора - и game.cmd продолжает работать.
    $s = Get-DefaultSettings
    $s.roles['XG27AQDMGR'] = 'game'
    Assert-True (Convert-RoleSettingsToCombos $s) 'changed'
    Assert-Equal @('XG27AQDMGR') @($s.combos['Game'].displays) 'the one display'
}

Test-Case 'migration: shortcuts, audio and auto-game follow their role' {
    $s = Get-DefaultSettings
    $s.roles['LG ULTRAFINE'] = 'work'
    $s.roles['LG ULTRAGEAR'] = 'work'
    $s.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
    $s.hotkeys['role:work'] = 'Ctrl+Alt+F3'
    $s.hotkeys['all'] = 'Ctrl+Alt+F5'
    $s.audio['role:work'] = 'ULTRAFINE'
    $s.autoGame.gameMode = 'role:work'
    $s.autoGame.backMode = 'all'

    [void](Convert-RoleSettingsToCombos $s)
    Assert-Equal 'Ctrl+Alt+F3' $s.hotkeys['combo:Work'] 'the shortcut moved to the new key'
    Assert-True (-not $s.hotkeys.Contains('role:work')) 'and left the old one'
    # Порядок ключей сохраняется: settings.json под git, и перетасовка выглядела бы
    # правкой, которой никто не делал.
    Assert-Equal @('solo:LG ULTRAGEAR', 'combo:Work', 'all') @($s.hotkeys.Keys) 'order kept, key renamed in place'
    Assert-Equal 'ULTRAFINE' $s.audio['combo:Work'] 'audio moved'
    Assert-Equal 'combo:Work' $s.autoGame.gameMode 'auto-game target moved'
    Assert-Equal 'all' $s.autoGame.backMode 'and what it did not name is left alone'
}

Test-Case 'migration: a name already taken by a combination is not overwritten' {
    $s = Get-DefaultSettings
    $s.combos['Work'] = [ordered]@{ displays = @('DELL'); primary = 'DELL' }
    $s.roles['LG ULTRAFINE'] = 'work'
    $s.roles['LG ULTRAGEAR'] = 'work'
    [void](Convert-RoleSettingsToCombos $s)
    Assert-Equal @('DELL') @($s.combos['Work'].displays) 'the existing combination kept its displays'
    Assert-Equal @('LG ULTRAFINE', 'LG ULTRAGEAR') @($s.combos['Work (group)'].displays) 'the role took a free name'
    Assert-Equal 'combo:Work (group)' 'combo:Work (group)' 'and its key follows that name'
}

Test-Case 'migration: runs once and is idempotent' {
    $s = Get-DefaultSettings
    $s.roles['LG ULTRAGEAR'] = 'work'
    Assert-True (Convert-RoleSettingsToCombos $s) 'first pass changed things'
    Assert-True (-not (Convert-RoleSettingsToCombos $s)) 'second pass has nothing to do'
    Assert-Equal 1 @($s.combos.Keys).Count 'no duplicate combination'
}

Test-Case 'migration: nothing to migrate is not a change, and not a crash' {
    Assert-True (-not (Convert-RoleSettingsToCombos (Get-DefaultSettings))) 'no roles'
    Assert-True (-not (Convert-RoleSettingsToCombos $null)) 'no settings at all'
}

Test-Case 'migration: a blank role name is dropped, not turned into a combination' {
    # Комбинации из этого не выйдет — имени нет; но запись всё равно уходит из
    # файла, и это изменение, о котором надо сказать: иначе мусор в settings.json
    # оставался бы там навсегда.
    $s = Get-DefaultSettings
    $s.roles['LG ULTRAGEAR'] = '   '
    Assert-True (Convert-RoleSettingsToCombos $s) 'the junk entry is a change worth saving'
    Assert-Equal 0 @($s.combos.Keys).Count 'no combination made up out of a blank name'
    Assert-Equal 0 @($s.roles.Keys).Count 'and the entry is gone'
}

Test-Case 'migration: happens on read, so the rest of the code never sees a role' {
    $json = '{ "roles": { "LG ULTRAFINE": "work", "LG ULTRAGEAR": "work" }, ' +
            '"hotkeys": { "role:work": "Ctrl+Alt+F3" } }'
    Set-Content -Path $script:SettingsFile -Value $json -Encoding UTF8

    $s = Get-DisplaySettings
    Assert-Equal 0 @($s.roles.Keys).Count 'roles are gone by the time settings are handed out'
    Assert-Equal @('LG ULTRAFINE', 'LG ULTRAGEAR') @($s.combos['Work'].displays) 'they arrived as a combination'
    Assert-Equal 'Ctrl+Alt+F3' $s.hotkeys['combo:Work'] 'with the shortcut'
    Assert-True $script:LegacyRolesOnDisk 'and the file is flagged for a rewrite'

    # А режимы, построенные из этих настроек, знают только комбинацию.
    $state = @(
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3')
    )
    $kinds = @(Get-DisplayModes $state $s | ForEach-Object { $_.Kind })
    Assert-True (-not ($kinds -contains 'role')) 'no group modes anywhere'
    Assert-True ($kinds -contains 'combo') 'the combination is there'

    # Перезаписали файл — флаг гаснет, второй раз прибирать нечего.
    Save-DisplaySettings $s
    [void](Get-DisplaySettings)
    Assert-True (-not $script:LegacyRolesOnDisk) 'nothing left to migrate after a save'
    Remove-Item $script:SettingsFile -Force
}

# --- комбинации ----------------------------------------------------------------
# Комбинация — единственный способ сказать «вот эти два и вон тот»: набор
# мониторов под своим именем, с необязательной своей панелью задач. Один монитор
# может входить в любое их число.

Write-Host ''
Write-Host 'combinations' -ForegroundColor White

Test-Case 'combos: settings survive a round-trip, in all three spellings' {
    # Полную форму пишет окно настроек; массив и голую строку — человек рукой.
    $json = '{ "combos": { ' +
            '"Movie night": { "displays": ["ULTRAFINE", "XG27AQDMGR"], "primary": "ULTRAFINE" }, ' +
            '"Side pair": ["ULTRAGEAR", "ULTRAFINE"], ' +
            '"Lone": "XG27AQDMGR" } }'
    Set-Content -Path $script:SettingsFile -Value $json -Encoding UTF8

    $s = Get-DisplaySettings
    Assert-Equal @('Movie night', 'Side pair', 'Lone') @($s.combos.Keys) 'file order kept'
    Assert-Equal @('ULTRAFINE', 'XG27AQDMGR') @($s.combos['Movie night'].displays) 'full form displays'
    Assert-Equal 'ULTRAFINE' $s.combos['Movie night'].primary 'full form primary'
    Assert-Equal @('ULTRAGEAR', 'ULTRAFINE') @($s.combos['Side pair'].displays) 'array shorthand normalised'
    Assert-Equal '' $s.combos['Side pair'].primary 'shorthand means no primary of its own'
    Assert-Equal @('XG27AQDMGR') @($s.combos['Lone'].displays) 'string shorthand normalised'

    Save-DisplaySettings $s
    $back = Get-DisplaySettings
    Assert-Equal @('ULTRAFINE', 'XG27AQDMGR') @($back.combos['Movie night'].displays) 'displays after a save'
    Assert-Equal 'ULTRAFINE' $back.combos['Movie night'].primary 'primary after a save'
    Remove-Item $script:SettingsFile -Force
}

Test-Case 'combos: a combination becomes a mode named exactly as typed' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D')
    )
    $s = Get-DefaultSettings
    $s.combos['Movie night'] = [ordered]@{ displays = @('ULTRAFINE', 'XG27AQDMGR'); primary = 'XG27AQDMGR' }
    $s.combos['Big pair']    = [ordered]@{ displays = @('ULTRAGEAR', 'ULTRAFINE'); primary = '' }

    $modes = @(Get-DisplayModes $state $s)
    $keys = @($modes | ForEach-Object { $_.Key })
    $movie = $modes | Where-Object { $_.Key -eq 'combo:Movie night' } | Select-Object -First 1
    Assert-True ($null -ne $movie) 'the combo mode exists'
    Assert-Equal 'Movie night' $movie.Title 'title is the name as typed'
    Assert-Equal 'combo' $movie.Kind 'kind'
    Assert-Equal 'XG27AQDMGR' $movie.Primary 'carries its own taskbar display'
    Assert-True $movie.Available 'available - its displays are on the desk'

    # Порядок: после режимов отдельных мониторов, перед «все», между собой — как в
    # файле: их порядок выбрал человек, и переставлять его не наше дело.
    $ix = @{}
    for ($i = 0; $i -lt $keys.Count; $i++) { $ix[$keys[$i]] = $i }
    Assert-True ($ix['solo:XG27AQDMGR'] -lt $ix['combo:Movie night']) 'after the single displays'
    Assert-True ($ix['combo:Movie night'] -lt $ix['combo:Big pair']) 'file order kept'
    Assert-True ($ix['combo:Big pair'] -lt $ix['all']) 'before all'
}

Test-Case 'combos: members are the displays its patterns match, connected only' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' '' $false $true)
    )
    $s = Get-DefaultSettings
    $s.combos['Mix'] = [ordered]@{ displays = @('ULTRAFINE', 'XG27AQDMGR'); primary = '' }
    $mix = @(Get-DisplayModes $state $s) | Where-Object { $_.Key -eq 'combo:Mix' } | Select-Object -First 1
    $members = @(Get-ModeMembers $mix $state | ForEach-Object { $_.Label })
    Assert-Equal @('LG ULTRAFINE') $members 'the unplugged display is not a member'
    Assert-True $mix.Available 'still available - one display is enough'
}

Test-Case 'combos: nothing connected means unavailable, not a guess' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    $s = Get-DefaultSettings
    $s.combos['Elsewhere'] = [ordered]@{ displays = @('DELL'); primary = '' }
    $mode = @(Get-DisplayModes $state $s) | Where-Object { $_.Key -eq 'combo:Elsewhere' } | Select-Object -First 1
    Assert-True ($null -ne $mode) 'the mode is still listed - the user made it'
    Assert-True (-not $mode.Available) 'marked unavailable'
}

Test-Case 'combos: no settings passed means no combo modes, not a crash' {
    # Get-DisplayModes сам на диск не ходит никогда: меню зовёт её на каждое
    # открытие. Без настроек комбинаций в списке просто нет.
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3'))
    $kinds = @(Get-DisplayModes $state | ForEach-Object { $_.Kind })
    Assert-True (-not ($kinds -contains 'combo')) 'no combos out of thin air'
}

Test-Case 'combos: the current desk is recognised as an active combination' {
    $state = @(
        (New-FakeMonitor 'A' 'AAA1111' 'path-a' $true)
        (New-FakeMonitor 'B' 'BBB2222' 'path-b' $false)
        (New-FakeMonitor 'C' 'CCC3333' 'path-c' $true)
    )
    $s = Get-DefaultSettings
    $s.combos['Edges'] = [ordered]@{ displays = @('A', 'C'); primary = '' }
    $modes = @(Get-DisplayModes $state $s)
    Assert-Equal 'combo:Edges' (Get-ActiveModeKey $state $modes) 'A and C on, B off - that is Edges'
}

Test-Case 'ModeTitleFromKey: a combo key gives the name back as typed' {
    Assert-Equal 'Movie night' (Get-ModeTitleFromKey 'combo:Movie night') 'combo'
}

# --- выбор основного монитора -----------------------------------------------------
# Лестница из шести ступеней в Select-PrimaryDisplay. Внутри Switch-DisplayMode
# она была непроверяемой; с собственным primary у комбинаций это стало
# недопустимо — семантика «жёсткий/мягкий» держится только на этих тестах.

Write-Host ''
Write-Host 'choosing the primary display' -ForegroundColor White

$script:PrimState = @(
    (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf')
    (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' 'path-xg')
    (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
)

Test-Case 'primary: -PrimaryMatch wins, and a typo in it is an error, not a guess' {
    $hit = Select-PrimaryDisplay -Wanted $script:PrimState -PrimaryMatch 'ULTRAFINE' `
                                 -ModePrimary 'ULTRAGEAR' -SettingsPrimary 'XG' -Layout @()
    Assert-Equal 'LG ULTRAFINE' $hit.Label 'the explicit choice beats everything'

    $threw = $false
    try { [void](Select-PrimaryDisplay -Wanted $script:PrimState -PrimaryMatch 'NOSUCH' -ModeTitle 'Movie') }
    catch { $threw = $true; Assert-True ($_.Exception.Message -like "*NOSUCH*") 'named the typo' }
    Assert-True $threw 'threw instead of silently picking another display'
}

Test-Case 'primary: the combination speaks next, softly' {
    $hit = Select-PrimaryDisplay -Wanted $script:PrimState -ModePrimary 'XG27' `
                                 -SettingsPrimary 'ULTRAGEAR' -Layout @()
    Assert-Equal 'XG27AQDMGR' $hit.Label 'combo primary beats the settings preference'

    # Монитора из primary комбинации нет среди включаемых — молча идём дальше:
    # комбинация обязана работать и без него, это не опечатка человека.
    $without = @($script:PrimState | Where-Object { $_.Label -ne 'XG27AQDMGR' })
    $hit = Select-PrimaryDisplay -Wanted $without -ModePrimary 'XG27' `
                                 -SettingsPrimary 'ULTRAGEAR' -Layout @()
    Assert-Equal 'LG ULTRAGEAR' $hit.Label 'fell through to the settings preference'
}

Test-Case 'primary: current one, then rightmost by layout, then the first' {
    $wanted = @(
        (New-FakeMonitor 'A' 'AAA1111' 'pa')
        (New-FakeMonitor 'B' 'BBB2222' 'pb')
    )
    $wanted[1].Primary = $true
    Assert-Equal 'B' (Select-PrimaryDisplay -Wanted $wanted -Layout @()).Label 'who is primary now stays primary'

    $wanted[1].Primary = $false
    Assert-Equal 'B' (Select-PrimaryDisplay -Wanted $wanted -Layout @('A', 'B')).Label 'rightmost by layout'
    Assert-Equal 'A' (Select-PrimaryDisplay -Wanted $wanted -Layout @()).Label 'first as the last resort'
}
# --- отрисовка меню трея -------------------------------------------------------
# Два бага подряд были невидимы в коде и видны только в пикселях: базовый
# ToolStripRenderer для ВЫКЛЮЧЕННОГО пункта подменяет наш цвет текста системным
# GrayText, а картинку прогоняет через DrawImageDisabled. Строки раздела CONNECTED
# DISPLAYS выключены намеренно (по ним нельзя щёлкать) — и весь раздел выцветал:
# текст еле читался, а зелёная/янтарная/серая точки состояния превращались в три
# одинаковых серых пятна.
#
# Проверяем не «код на месте», а результат: рисуем настоящим отрисовщиком в
# Bitmap через публичные DrawItemText/DrawItemImage (окна не нужно) и смотрим
# пиксели. Верни base — тесты покраснеют.

Write-Host ''
Write-Host 'the tray menu renderer' -ForegroundColor White

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-DisabledInfoItem {
    param([string]$Text = 'LG ULTRAGEAR    2560 x 1440 @ 144 Hz')
    $strip = New-Object System.Windows.Forms.ToolStrip
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $Text
    $item.Enabled = $false
    $item.Tag = 'info'
    [void]$strip.Items.Add($item)
    return $item
}

# Самый яркий и самый цветной пиксель — по ним и судим.
function Measure-Bitmap {
    param($Bitmap)
    $maxLum = 0; $bestGreen = -999
    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $c = $Bitmap.GetPixel($x, $y)
            $lum = [int](0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B)
            if ($lum -gt $maxLum) { $maxLum = $lum }
            $green = [int]$c.G - [Math]::Max([int]$c.R, [int]$c.B)
            if ($green -gt $bestGreen) { $bestGreen = $green }
        }
    }
    return [pscustomobject]@{ MaxLuminance = $maxLum; Greenness = $bestGreen }
}

Test-Case 'menu: a disabled display row is drawn in our bright colour, not system grey' {
    $renderer = New-Object ModernMenuRenderer $true, ([System.Drawing.Color]::FromArgb(0x4C, 0xC2, 0xFF))
    $item = New-DisabledInfoItem
    $bmp = New-Object System.Drawing.Bitmap 320, 20
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::FromArgb(0x2C, 0x2C, 0x2C))
        $rect = New-Object System.Drawing.Rectangle 0, 0, 320, 20
        $font = New-Object System.Drawing.Font 'Segoe UI', 9.75
        $args = New-Object System.Windows.Forms.ToolStripItemTextRenderEventArgs (
            $g, $item, $item.Text, $rect, [System.Drawing.Color]::Red, $font,
            [System.Windows.Forms.TextFormatFlags]::VerticalCenter)
        $renderer.DrawItemText($args)

        $seen = Measure-Bitmap $bmp
        # SystemColors.GrayText, которым рисует base, даёт яркость около 110.
        # Наш _text (#F2F2F2) - выше 200. Порог между ними с большим запасом.
        Assert-True ($seen.MaxLuminance -gt 170) "display name is bright (saw $($seen.MaxLuminance))"
        $font.Dispose()
    }
    finally { $g.Dispose(); $bmp.Dispose() }
}

Test-Case 'menu: a status dot keeps its colour on a disabled row' {
    $renderer = New-Object ModernMenuRenderer $true, ([System.Drawing.Color]::FromArgb(0x4C, 0xC2, 0xFF))
    $item = New-DisabledInfoItem
    $dot = New-Object System.Drawing.Bitmap 16, 16
    $dg = [System.Drawing.Graphics]::FromImage($dot)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0x3F, 0xB9, 0x50))
    $dg.FillEllipse($brush, 4, 4, 8, 8)
    $brush.Dispose(); $dg.Dispose()

    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::FromArgb(0x2C, 0x2C, 0x2C))
        $args = New-Object System.Windows.Forms.ToolStripItemImageRenderEventArgs (
            $g, $item, $dot, (New-Object System.Drawing.Rectangle 0, 0, 16, 16))
        $renderer.DrawItemImage($args)

        $seen = Measure-Bitmap $bmp
        # DrawImageDisabled, которым рисует base, отдаёт серое: зелень уходит в 0.
        Assert-True ($seen.Greenness -gt 40) "the dot is still green (saw $($seen.Greenness))"
    }
    finally { $g.Dispose(); $bmp.Dispose(); $dot.Dispose() }
}

Test-Case 'menu: an unavailable mode stays readable too, just quieter' {
    # Недоступный режим («not connected») тоже выключен, но он не info-строка:
    # рисуется приглушённым тоном - и всё же не системным серым.
    $renderer = New-Object ModernMenuRenderer $true, ([System.Drawing.Color]::FromArgb(0x4C, 0xC2, 0xFF))
    $strip = New-Object System.Windows.Forms.ToolStrip
    $item = New-Object System.Windows.Forms.ToolStripMenuItem 'Only DELL U2720Q   (not connected)'
    $item.Enabled = $false
    [void]$strip.Items.Add($item)

    $bmp = New-Object System.Drawing.Bitmap 320, 20
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::FromArgb(0x2C, 0x2C, 0x2C))
        $font = New-Object System.Drawing.Font 'Segoe UI', 9.75
        $args = New-Object System.Windows.Forms.ToolStripItemTextRenderEventArgs (
            $g, $item, $item.Text, (New-Object System.Drawing.Rectangle 0, 0, 320, 20),
            [System.Drawing.Color]::Red, $font, [System.Windows.Forms.TextFormatFlags]::VerticalCenter)
        $renderer.DrawItemText($args)
        $seen = Measure-Bitmap $bmp
        Assert-True ($seen.MaxLuminance -gt 130) "dim but legible (saw $($seen.MaxLuminance))"
        Assert-True ($seen.MaxLuminance -lt 200) 'and quieter than a live row'
        $font.Dispose()
    }
    finally { $g.Dispose(); $bmp.Dispose() }
}


# --- окно настроек -------------------------------------------------------------
# Окно теперь WPF и собирается БЕЗ показа: New-SettingsWindow строит дерево
# элементов, а Read-SettingsFromUi — настоящая ветка Save — читает его. ShowDialog
# в тестах не зовётся вовсе, поэтому непроверенным остаётся только сам показ.
# Раньше здесь таймер жал Save в настоящем показанном окне — с выносом сохранения
# в чистую функцию это стало не нужно, и тесты перестали мигать окном.

Write-Host ''
Write-Host 'the settings window' -ForegroundColor White

$script:DlgState = @(
    (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
    (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf')
)

function New-DialogUi {
    param($Settings, $State)
    if ($null -eq $State) { $State = $script:DlgState }
    $modes = @(Get-DialogModes -State $State -Settings $Settings)
    return New-SettingsWindow -Modes $modes -Settings $Settings -State $State
}

Test-Case 'dialog: Save keeps layout, primary and every non-UI field' {
    # Регрессия этапа 1: первый же Save стирал layout и primary. Теперь ветка
    # сохранения — настоящая функция, и проверяется она сама, а не её пересказ.
    $settings = Get-DefaultSettings
    $settings.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
    $settings.layout = @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR')
    $settings.primary = 'ULTRAGEAR'
    $settings.audio['combo:Work'] = 'ULTRAFINE'
    $settings.autoGame.enabled = $true
    $settings.autoGame.process = 'cs2'

    $ui = New-DialogUi -Settings $settings
    try {
        Assert-True ($null -ne $ui.WindowsBox) 'the window has the window-memory toggle'
        Assert-True ([bool]$ui.WindowsBox.IsChecked) 'it reflects the default (on)'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings -State $ui.State
        Assert-True $got.Ok 'the save was accepted'
        $updated = $got.Settings

        # XG27AQDMGR сейчас не подключён — его место в ряду обязано выжить.
        Assert-Equal @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR') @($updated.layout) 'layout survived, absent display included'
        # Звезда стояла по шаблону ULTRAGEAR — в файл уезжает точное название.
        Assert-Equal 'LG ULTRAGEAR' $updated.primary 'primary written as the exact name'
        Assert-Equal 'ULTRAFINE' $updated.audio['combo:Work'] 'audio survived'
        Assert-True $updated.autoGame.enabled 'autoGame survived'
        Assert-Equal 'cs2' $updated.autoGame.process 'autoGame process survived'
        Assert-Equal 'Ctrl+Alt+F1' $updated.hotkeys['solo:LG ULTRAGEAR'] 'hotkey came from the box'
        # Роли окно больше не пишет: их место заняли комбинации.
        Assert-Equal 0 @($updated.roles.Keys).Count 'no roles written back'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: the shortcut boxes keep mode order so Save does not shuffle the file' {
    $modes = @(
        [pscustomobject]@{ Key = 'solo:A'; Title = 'Only A'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'solo:B'; Title = 'Only B'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Patterns = @('A', 'B'); Available = $true }
        [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    )
    $ui = New-SettingsWindow -Modes $modes -Settings (Get-DefaultSettings) -State @()
    try {
        Assert-Equal @('solo:A', 'solo:B', 'combo:Work', 'all') @($ui.Boxes.Keys) 'boxes keep mode order'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a duplicate shortcut is refused, with words' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $keys = @($ui.Boxes.Keys)
        $ui.Boxes[$keys[0]].Text = 'Ctrl+Alt+F1'
        $ui.Boxes[$keys[1]].Text = 'Ctrl+Alt+F1'
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings -State $ui.State
        Assert-True (-not $got.Ok) 'refused'
        Assert-True ($got.Problem -like '*assigned twice*') 'said why'
        Assert-Null $got.Settings 'nothing half-saved'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: moving a desk card changes the saved order' {
    $settings = Get-DefaultSettings
    $settings.layout = @('LG ULTRAGEAR', 'LG ULTRAFINE')
    $ui = New-DialogUi -Settings $settings
    try {
        $first = $ui.DeskPanel.Children[0]
        Move-DeskCard -Panel $ui.DeskPanel -Card $first -Delta 1
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings -State $ui.State
        Assert-Equal @('LG ULTRAFINE', 'LG ULTRAGEAR') @($got.Settings.layout) 'the card really moved'

        # За край ряда карточка не двигается и не теряется.
        Move-DeskCard -Panel $ui.DeskPanel -Card $first -Delta 5
        Assert-Equal 2 $ui.DeskPanel.Children.Count 'nothing lost at the edge'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: removing a combination takes its shortcut and audio along' {
    $settings = Get-DefaultSettings
    $settings.combos['Movie'] = [ordered]@{ displays = @('ULTRAGEAR', 'ULTRAFINE'); primary = '' }
    $settings.hotkeys['combo:Movie'] = 'Ctrl+Alt+F9'
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $settings.audio['combo:Movie'] = 'ROG'
    $settings.audio['all'] = 'SPEAKERS'

    $ui = New-DialogUi -Settings $settings
    try {
        Assert-True ($ui.Boxes.Contains('combo:Movie')) 'the combination has a shortcut row'
        Remove-UiCombo -Ui $ui -Combo $ui.Combos[0]
        Assert-True (-not $ui.Boxes.Contains('combo:Movie')) 'its row went away with it'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings -State $ui.State
        Assert-True $got.Ok 'saved'
        Assert-Equal 0 @($got.Settings.combos.Keys).Count 'the combination is gone'
        Assert-True (-not $got.Settings.hotkeys.Contains('combo:Movie')) 'its shortcut died with it'
        Assert-True (-not $got.Settings.audio.Contains('combo:Movie')) 'its audio died with it'
        Assert-Equal 'Ctrl+Alt+F5' $got.Settings.hotkeys['all'] 'other shortcuts kept'
        Assert-Equal 'SPEAKERS' $got.Settings.audio['all'] 'other audio kept'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: renaming a combination carries its shortcut and audio' {
    $settings = Get-DefaultSettings
    $settings.combos['Movie'] = [ordered]@{ displays = @('ULTRAGEAR'); primary = '' }
    $settings.hotkeys['combo:Movie'] = 'Ctrl+Alt+F9'
    $settings.audio['combo:Movie'] = 'ROG'

    $ui = New-DialogUi -Settings $settings
    try {
        # Ровно то, что возвращает редактор комбинации по кнопке Save.
        Set-UiCombo -Ui $ui -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Cinema'; Patterns = @('LG ULTRAGEAR', 'LG ULTRAFINE'); Primary = 'LG ULTRAFINE' })
        Assert-Equal 'Ctrl+Alt+F9' $ui.Boxes['combo:Cinema'].Text 'the shortcut followed the rename in the window'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings -State $ui.State
        Assert-True $got.Ok 'saved'
        Assert-True (-not $got.Settings.combos.Contains('Movie')) 'old name gone'
        Assert-Equal @('LG ULTRAGEAR', 'LG ULTRAFINE') @($got.Settings.combos['Cinema'].displays) 'displays updated'
        Assert-Equal 'LG ULTRAFINE' $got.Settings.combos['Cinema'].primary 'its own taskbar display saved'
        Assert-Equal 'Ctrl+Alt+F9' $got.Settings.hotkeys['combo:Cinema'] 'shortcut moved to the new key'
        Assert-True (-not $got.Settings.hotkeys.Contains('combo:Movie')) 'and left the old one'
        Assert-Equal 'ROG' $got.Settings.audio['combo:Cinema'] 'audio moved too'
        Assert-True (-not $got.Settings.audio.Contains('combo:Movie')) 'audio left the old key'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: the combination editor prefills members, leftovers, taskbar and shortcut' {
    $combo = [pscustomobject]@{ Name = 'Movie'; Patterns = @('ULTRAGEAR', 'GONE PANEL'); Primary = 'ULTRAGEAR'; OriginalName = 'Movie' }
    $ed = New-ComboEditorWindow -Combo $combo -State $script:DlgState -TakenNames @() -Hotkey 'Ctrl+Alt+F9' -Dark $false
    try {
        Assert-Equal 'Movie' $ed.NameBox.Text 'name prefilled'
        Assert-Equal 3 @($ed.Checks).Count 'two live displays plus the leftover pattern'
        $byTag = @{}
        foreach ($cb in $ed.Checks) { $byTag[[string]$cb.Tag] = [bool]$cb.IsChecked }
        Assert-True $byTag['LG ULTRAGEAR'] 'matched display ticked'
        Assert-True (-not $byTag['LG ULTRAFINE']) 'unrelated display not ticked'
        # Монитор увезли, но выбрасывать его из комбинации молча нельзя.
        Assert-True $byTag['GONE PANEL'] 'a pattern with no display kept as its own ticked row'
        Assert-Equal 'LG ULTRAGEAR' ([string]$ed.PrimaryBox.SelectedItem) 'taskbar pick found by pattern'
        Assert-Equal 'Ctrl+Alt+F9' $ed.HotkeyBox.Text 'shortcut prefilled'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: the editor shows no-shortcut for rubbish instead of pretending it is one' {
    $ed = New-ComboEditorWindow -Combo $null -State $script:DlgState -TakenNames @() -Hotkey 'needs Ctrl / Alt / Shift' -Dark $false
    try {
        Assert-Equal $script:NoHotkeyText $ed.HotkeyBox.Text 'hint text did not survive as a binding'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: a shortcut can be removed, and the empty text saves as no binding' {
    # «Клавиши не убираются» — так это выглядело, когда снять привязку можно было
    # только Backspace'ом по мелкой строчке-подсказке. Проверяем сам путь снятия.
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal 'Ctrl+Alt+F5' $ui.Boxes['all'].Text 'starts bound'
        $ui.Boxes['all'].Text = $script:NoHotkeyText
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings -State $ui.State
        Assert-True $got.Ok 'saved'
        Assert-True (-not $got.Settings.hotkeys.Contains('all')) 'the binding is gone from the file'
        # А сама строка режима осталась: режимы не удаляются здесь, они следуют из
        # мониторов, групп и комбинаций.
        Assert-True ($ui.Boxes.Contains('all')) 'the mode row is still there'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: in-progress hint text never becomes a binding' {
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $ui = New-DialogUi -Settings $settings
    try {
        foreach ($junk in $script:PressKeysText, 'needs Ctrl / Alt / Shift', 'unsupported key', '') {
            $ui.Boxes['all'].Text = $junk
            $got = Read-SettingsFromUi -Ui $ui -Settings $settings -State $ui.State
            Assert-True (-not $got.Settings.hotkeys.Contains('all')) "'$junk' is not a binding"
        }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a shortcut picked in the combination editor lands in the shortcut rows' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        # Ровно то, что возвращает редактор по Save, вместе с клавишей.
        Set-UiCombo -Ui $ui -Combo $null -Edited ([pscustomobject]@{
            Name = 'Movie'; Patterns = @('LG ULTRAGEAR'); Primary = ''; Hotkey = 'Ctrl+Alt+F7' })
        Assert-Equal 'Ctrl+Alt+F7' $ui.Boxes['combo:Movie'].Text 'the shortcut row got the keys'
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings -State $ui.State
        Assert-Equal 'Ctrl+Alt+F7' $got.Settings.hotkeys['combo:Movie'] 'and they save'

        # Снять клавишу в редакторе — тоже правка, а не «оставить как было».
        Set-UiCombo -Ui $ui -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Movie'; Patterns = @('LG ULTRAGEAR'); Primary = ''; Hotkey = '' })
        Assert-Equal $script:NoHotkeyText $ui.Boxes['combo:Movie'].Text 'cleared back to no shortcut'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: every mode row says what kind of mode it is' {
    # Подпись отвечает на вопрос, почему у одной строки есть Remove, а у другой
    # нет: режим монитора и «все» появляются сами, комбинацию создаёшь ты.
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
    )
    Assert-Equal 'Display' (Get-ModeSubtitle -Mode ([pscustomobject]@{ Kind = 'solo' }) -State $state) 'a single display'

    $combo = Get-ModeSubtitle -Mode ([pscustomobject]@{
        Kind = 'combo'; Patterns = @('LG ULTRAFINE', 'XG27AQDMGR'); Primary = 'LG ULTRAFINE' }) -State $state
    Assert-True ($combo -like 'Combination*') 'a combination says it is a combination'
    Assert-True ($combo -like '*LG ULTRAFINE + XG27AQDMGR*') 'and lists its displays'
    Assert-True ($combo -like '*taskbar on LG ULTRAFINE*') 'and where the taskbar goes'

    Assert-Equal 'Every connected display' (Get-ModeSubtitle -Mode ([pscustomobject]@{ Kind = 'all' }) -State $state) 'all'
    Assert-True ((Get-ModeSubtitle -Mode ([pscustomobject]@{ Kind = 'orphan' }) -State $state) -like '*shortcut stays reserved*') 'orphan'
}

Test-Case 'dialog: there is exactly one place that makes a named set of displays' {
    # Раньше их было две — карточка групп и карточка комбинаций, — и «Work
    # displays» нельзя было удалить там, где она показана. Групп в окне больше нет.
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    try {
        Assert-Null $ui.Window.FindName('RolesPanel') 'no display-groups panel'
        Assert-Null $ui.Window.FindName('RolesHint') 'and no groups hint'
        Assert-True ($null -ne $ui.CombosPanel) 'combinations are the one place'
        Assert-True ($null -ne $ui.AddComboBtn) 'with a button to add one'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: the cross clears a shortcut and greys itself out when there is nothing to clear' {
    # Кнопка и поле находят друг друга через .Tag — без этого крестик молча не
    # работал бы (замыкания в обработчиках теряют и функции, и $script:).
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $ui = New-DialogUi -Settings $settings
    try {
        $box = $ui.Boxes['all']
        $clear = $box.Tag
        Assert-True ($null -ne $clear) 'the box knows its cross'
        Assert-True $clear.IsEnabled 'enabled while a shortcut is set'

        $clear.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        Assert-Equal $script:NoHotkeyText $box.Text 'the click cleared the box'
        Assert-True (-not $clear.IsEnabled) 'and greyed itself out'

        # Назначили снова — крестик снова живой (следит за полем, а не за кликами).
        $box.Text = 'Ctrl+Alt+F8'
        Assert-True $clear.IsEnabled 'awake again'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'combo editor: what it reads, and every refusal' {
    $ed = New-ComboEditorWindow -Combo $null -State $script:DlgState `
                                -TakenNames @('Movie') -TakenHotkeys @('Ctrl+Alt+F5') -Dark $false
    try {
        # Пустое имя.
        $got = Read-ComboFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'no name is refused'
        Assert-True ($got.Problem -like '*name*') 'and says so'

        # Имя занято.
        $ed.NameBox.Text = 'movie'
        $got = Read-ComboFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'a taken name is refused, case aside'
        Assert-True ($got.Problem -like "*already exists*") 'and says so'

        # Ни одного монитора.
        $ed.NameBox.Text = 'Cinema'
        $got = Read-ComboFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'no displays is refused'
        Assert-True ($got.Problem -like '*at least one display*') 'and says so'

        # Чужая клавиша.
        $ed.Checks[0].IsChecked = $true
        $ed.HotkeyBox.Text = 'Ctrl+Alt+F5'
        $got = Read-ComboFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'a shortcut owned by another mode is refused'
        Assert-True ($got.Problem -like '*already drives another mode*') 'and says so'

        # Всё в порядке.
        $ed.HotkeyBox.Text = 'Ctrl+Alt+F6'
        $got = Read-ComboFromUi -Editor $ed
        Assert-True $got.Ok 'accepted'
        Assert-Equal 'Cinema' $got.Combo.Name 'name trimmed and kept'
        Assert-Equal @('LG ULTRAGEAR') @($got.Combo.Patterns) 'the ticked display'
        Assert-Equal 'Ctrl+Alt+F6' $got.Combo.Hotkey 'the shortcut'
        Assert-Equal '' $got.Combo.Primary 'no taskbar display chosen means the usual rules'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'combo editor: the taskbar display must be one of the ticked ones' {
    $ed = New-ComboEditorWindow -Combo $null -State $script:DlgState -TakenNames @() -Dark $false
    try {
        $ed.NameBox.Text = 'Pair'
        $ed.Checks[0].IsChecked = $true
        $ed.PrimaryBox.SelectedItem = [string]$ed.Checks[1].Tag   # не отмечен
        $got = Read-ComboFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'refused'
        Assert-True ($got.Problem -like '*must be one of the ticked*') 'and says why'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: taken shortcuts are gathered minus the mode being edited' {
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $settings.combos['Movie'] = [ordered]@{ displays = @('ULTRAGEAR'); primary = '' }
    $settings.hotkeys['combo:Movie'] = 'Ctrl+Alt+F9'
    $ui = New-DialogUi -Settings $settings
    try {
        $taken = @(Get-TakenHotkeys -Ui $ui -ExceptKey 'combo:Movie')
        Assert-True ($taken -contains 'Ctrl+Alt+F5') 'other bindings count as taken'
        Assert-True (-not ($taken -contains 'Ctrl+Alt+F9')) 'its own binding is not a conflict'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a binding without its display still gets a row' {
    $settings = Get-DefaultSettings
    $settings.hotkeys['solo:GONE MONITOR'] = 'Ctrl+Alt+F8'
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-True ($ui.Boxes.Contains('solo:GONE MONITOR')) 'orphan row exists'
        Assert-Equal 'Ctrl+Alt+F8' $ui.Boxes['solo:GONE MONITOR'].Text 'with its combination shown'
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings -State $ui.State
        Assert-Equal 'Ctrl+Alt+F8' $got.Settings.hotkeys['solo:GONE MONITOR'] 'and it survives a save'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: WPF modifier bits equal the RegisterHotKey bits' {
    # Register-HotkeyCapture отдаёт [Keyboard]::Modifiers прямо в Format-HotkeyString,
    # без перекодировки — это законно только пока номера битов совпадают.
    Initialize-WpfRuntime
    Assert-Equal 1 ([int][System.Windows.Input.ModifierKeys]::Alt) 'Alt'
    Assert-Equal 2 ([int][System.Windows.Input.ModifierKeys]::Control) 'Ctrl'
    Assert-Equal 4 ([int][System.Windows.Input.ModifierKeys]::Shift) 'Shift'
    Assert-Equal 8 ([int][System.Windows.Input.ModifierKeys]::Windows) 'Win'
    Assert-Equal 0x70 ([System.Windows.Input.KeyInterop]::VirtualKeyFromKey([System.Windows.Input.Key]::F1)) 'F1 virtual key'
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
    (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3')
    (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
    (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D')
)
$script:ResolveSettings = New-TestSettings @{
    'Work'        = @('ULTRAGEAR', 'ULTRAFINE')
    'Game'        = @('XG27AQDMGR')
    'Movie night' = @('ULTRAFINE', 'XG27AQDMGR')
}
$script:ResolveModes = @(Get-DisplayModes $script:ResolveState $script:ResolveSettings)

Test-Case 'resolve: an exact key' {
    Assert-Equal 'all' (Resolve-ModeKey 'all' $script:ResolveModes $script:ResolveState).Key 'all'
    Assert-Equal 'combo:Work' (Resolve-ModeKey 'combo:Work' $script:ResolveModes $script:ResolveState).Key 'combo key'
}

Test-Case 'resolve: a combination by name, case and spaces aside' {
    Assert-Equal 'combo:Movie night' (Resolve-ModeKey 'movie night' $script:ResolveModes $script:ResolveState).Key 'lower case, with a space'
}

Test-Case 'resolve: work.cmd and game.cmd keep working after the groups moved' {
    # Обёртки зовут `Set-Display.ps1 work` и `game`. Это были имена ролей; после
    # переезда они стали именами комбинаций («Work», «Game»), и сравнение имени
    # регистр не различает — значит .cmd-файлы править не пришлось.
    Assert-Equal 'combo:Work' (Resolve-ModeKey 'work' $script:ResolveModes $script:ResolveState).Key 'work'
    Assert-Equal 'combo:Game' (Resolve-ModeKey 'game' $script:ResolveModes $script:ResolveState).Key 'game, a set of one'
}

Test-Case 'resolve: a short monitor id' {
    Assert-Equal 'solo:LG ULTRAFINE' (Resolve-ModeKey 'GSM5CBC' $script:ResolveModes $script:ResolveState).Key 'by short id'
}

Test-Case 'resolve: part of a monitor name' {
    Assert-Equal 'solo:LG ULTRAGEAR' (Resolve-ModeKey 'ULTRAGEAR' $script:ResolveModes $script:ResolveState).Key 'by name part'
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
        (New-FakeMonitor 'A' 'AAA1111' 'path-a' $true)
        (New-FakeMonitor 'B' 'BBB2222' 'path-b' $false)
    )
    Assert-Equal 'path-a' (Get-DisplayLayoutKey -State $state) 'only the active one'
}

Test-Case 'layout key: nothing active gives an empty key, not a crash' {
    $state = @((New-FakeMonitor 'A' 'AAA1111' 'path-a' $false))
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

# --- стол одним переходом -----------------------------------------------------
# Переключение с изменением набора экранов перестраивало стол трижды: набор,
# потом позиции, потом частоты. Каждый переход замораживает ввод — курсор замирал
# и «выстреливал» вперёд. Здесь прибито то, из чего собран единый переход:
# раскладка считается одинаково для обоих путей, целевой режим находится даже для
# спящего монитора, а отказ системы не теряет переключение.

Write-Host ''
Write-Host 'one desktop transition instead of three' -ForegroundColor White

function New-FakeScreen {
    param([string]$Path, [string]$Label, [int]$Width, [int]$Height)
    return [pscustomobject]@{ DevicePath = $Path; Label = $Label; Width = $Width; Height = $Height }
}

Test-Case 'layout math: displays line up left to right in the settings order' {
    $screens = @(
        (New-FakeScreen 'p-ug' 'LG ULTRAGEAR' 2560 1440)
        (New-FakeScreen 'p-uf' 'LG ULTRAFINE' 3840 2160)
    )
    # Порядок обратный списку экранов: считаться должен ПОРЯДОК, а не то, в каком
    # виде мониторы отдала система.
    $pos = Get-LayoutPositions -Screens $screens -Order @('ULTRAFINE', 'ULTRAGEAR') -PrimaryPath 'p-uf'
    Assert-Equal 0 $pos['p-uf'].X 'primary sits at the origin'
    Assert-Equal 3840 $pos['p-ug'].X 'the next one starts where the first ends'
}

Test-Case 'layout math: the primary display lands at (0,0), whatever its place' {
    # Основной в Windows — не флаг, а место: левый верхний угол в начале
    # координат. Стоит он справа — значит вся раскладка уезжает в минус.
    $screens = @(
        (New-FakeScreen 'p-uf' 'LG ULTRAFINE' 3840 2160)
        (New-FakeScreen 'p-ug' 'LG ULTRAGEAR' 2560 1440)
    )
    $pos = Get-LayoutPositions -Screens $screens -Order @('ULTRAFINE', 'ULTRAGEAR') -PrimaryPath 'p-ug'
    Assert-Equal 0 $pos['p-ug'].X 'primary at the origin'
    Assert-Equal 0 $pos['p-ug'].Y 'and at the top of it'
    Assert-Equal (-3840) $pos['p-uf'].X 'its neighbour goes negative'
}

Test-Case 'layout math: different heights are centred, not top-aligned' {
    # По верху внизу высокого монитора остаётся полоса, из которой курсор не может
    # перейти на соседний — ровно то, обо что человек спотыкается мышкой.
    $screens = @(
        (New-FakeScreen 'p-tall'  'TALL'  1000 2000)
        (New-FakeScreen 'p-short' 'SHORT' 1000 1000)
    )
    $pos = Get-LayoutPositions -Screens $screens -Order @('TALL', 'SHORT') -PrimaryPath 'p-tall'
    Assert-Equal 0 $pos['p-tall'].Y 'the tallest one keeps the top'
    Assert-Equal 500 $pos['p-short'].Y 'the shorter one is centred against it'
}

Test-Case 'layout math: a display missing from the order goes last' {
    $screens = @(
        (New-FakeScreen 'p-new' 'BRAND NEW' 1920 1080)
        (New-FakeScreen 'p-ug'  'LG ULTRAGEAR' 2560 1440)
    )
    $pos = Get-LayoutPositions -Screens $screens -Order @('ULTRAGEAR') -PrimaryPath 'p-ug'
    Assert-Equal 0 $pos['p-ug'].X 'the known one comes first'
    Assert-Equal 2560 $pos['p-new'].X 'the unknown one follows it'
}

Test-Case 'layout math: partial names match, as everywhere else in the settings' {
    # «UltraGear» обязан находить «LG ULTRAGEAR»: система знает мониторы короче,
    # чем люди, и это правило общее для layout, primary и состава комбинаций.
    $screens = @(
        (New-FakeScreen 'p-ug' 'LG ULTRAGEAR' 2560 1440)
        (New-FakeScreen 'p-xg' 'XG27AQDMGR'   2560 1440)
    )
    $pos = Get-LayoutPositions -Screens $screens -Order @('UltraGear', 'XG27') -PrimaryPath 'p-ug'
    Assert-Equal 0 $pos['p-ug'].X 'matched by a part of the name'
    Assert-Equal 2560 $pos['p-xg'].X 'and so was the second one'
}

Test-Case 'targets: an active display goes to its best mode' {
    $m = New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'p-ug'
    $m.BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 240 }
    $t = @(Get-SwitchTargets -Wanted @($m))
    Assert-Equal 1 $t.Count 'one target'
    Assert-Equal 240 $t[0].Hz 'the best refresh rate, not the current one'
    Assert-Equal 2560 $t[0].Width 'and its resolution'
}

Test-Case 'targets: a sleeping display takes its mode from the cache' {
    # Главный случай: монитор погашен, EnumDisplaySettings по нему молчит, и без
    # кэша частоту пришлось бы править вторым перестроением стола.
    $m = New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'p-xg' $false
    $m.BestMode = $null
    $cache = @{ 'p-xg' = [pscustomobject]@{
        Width = 2560; Height = 1440; Hz = 240; RateNum = 239998; RateDen = 1000 } }
    $t = @(Get-SwitchTargets -Wanted @($m) -Cache $cache)
    Assert-Equal 2560 $t[0].Width 'resolution from the cache'
    Assert-Equal 240 $t[0].Hz 'refresh rate too'
    Assert-Equal 239998 $t[0].RateNum 'and the exact fraction CCD demands'
    Assert-Equal 1000 $t[0].RateDen 'both halves of it'
}

Test-Case 'targets: an exact rate is asked for only when it belongs to that mode' {
    # 144 Гц в кэше и просят 240 — дроби для 240 у нас нет. Просить «240/1»
    # нельзя: CCD отвергает такой запрос целиком (validate -> 1610, 20 августа),
    # и вместе с частотой терялись бы разрешение и раскладка.
    $m = New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'p-ug'
    $m.BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 240 }
    $cache = @{ 'p-ug' = [pscustomobject]@{
        Width = 2560; Height = 1440; Hz = 144; RateNum = 143999; RateDen = 1000 } }
    $t = @(Get-SwitchTargets -Wanted @($m) -Cache $cache)
    Assert-Equal 240 $t[0].Hz 'still aiming at the best mode'
    Assert-Equal 0 $t[0].RateDen 'but no fraction is claimed for it'
}

Test-Case 'targets: the cached fraction is reused when the mode matches' {
    $m = New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'p-ug'
    $m.BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 144 }
    $cache = @{ 'p-ug' = [pscustomobject]@{
        Width = 2560; Height = 1440; Hz = 144; RateNum = 143999; RateDen = 1000 } }
    $t = @(Get-SwitchTargets -Wanted @($m) -Cache $cache)
    Assert-Equal 143999 $t[0].RateNum 'the fraction Windows actually accepts'
}

Test-Case 'targets: without a cache a sleeping display falls back to its EDID size' {
    $m = New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'p-xg' $false
    $m.BestMode = $null
    $m.Native = [pscustomobject]@{ Width = 2560; Height = 1440 }
    $t = @(Get-SwitchTargets -Wanted @($m))
    Assert-Equal 2560 $t[0].Width 'native resolution'
    Assert-Equal 0 $t[0].Hz 'and no refresh rate demanded - Windows picks one'
}

Test-Case 'targets: nothing known about a display drops the whole set' {
    # Мешать заданные режимы с незаданными в одном запросе значит гадать, что
    # система сделает с остатком. Такой набор целиком уходит старой дорогой.
    $known = New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'p-ug'
    $known.BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 240 }
    $blank = New-FakeMonitor 'MYSTERY' 'XXX0000' 'p-x' $false
    $blank.BestMode = $null
    $blank.Native = $null
    Assert-Equal 0 @(Get-SwitchTargets -Wanted @($known, $blank)).Count 'no targets at all'
}

Test-Case 'targets: -KeepMode leaves the mode alone' {
    $m = New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'p-ug'
    $m.BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 240 }
    $t = @(Get-SwitchTargets -Wanted @($m) -KeepMode)
    Assert-Equal 144 $t[0].Hz 'the rate it is on now, not the best one'
}

Test-Case 'full config: the refresh rate is dropped before the whole switch is' {
    # У ASUS частота 240 не записывается вообще, у ULTRAGEAR по HDMI её нет —
    # отказ по герцам не повод терять разрешения и раскладку.
    $script:FullCalls = @()
    function Invoke-CcdFullConfigAttempt {
        param($Targets, [string]$PrimaryPath, [string[]]$Order, [switch]$WithHz)
        $script:FullCalls += [bool]$WithHz
        return (-not $WithHz)
    }
    $targets = @([pscustomobject]@{ DevicePath = 'p'; Label = 'A'; Width = 2560; Height = 1440
                                    Hz = 240; RateNum = 239998; RateDen = 1000 })
    Assert-True (Set-CcdFullConfig -Targets $targets -Order @('A')) 'succeeded on the simpler request'
    Assert-Equal @($true, $false) $script:FullCalls 'asked with rates first, then without'
}

Test-Case 'full config: success with rates is not retried' {
    $script:FullCalls = @()
    function Invoke-CcdFullConfigAttempt {
        param($Targets, [string]$PrimaryPath, [string[]]$Order, [switch]$WithHz)
        $script:FullCalls += [bool]$WithHz
        return $true
    }
    $targets = @([pscustomobject]@{ DevicePath = 'p'; Label = 'A'; Width = 2560; Height = 1440
                                    Hz = 240; RateNum = 239998; RateDen = 1000 })
    Assert-True (Set-CcdFullConfig -Targets $targets -Order @('A')) 'ok'
    Assert-Equal 1 $script:FullCalls.Count 'one attempt was enough'
}

Test-Case 'full config: no exact rate means no pointless first attempt' {
    $script:FullCalls = @()
    function Invoke-CcdFullConfigAttempt {
        param($Targets, [string]$PrimaryPath, [string[]]$Order, [switch]$WithHz)
        $script:FullCalls += [bool]$WithHz
        return $true
    }
    $targets = @([pscustomobject]@{ DevicePath = 'p'; Label = 'A'; Width = 2560; Height = 1440
                                    Hz = 240; RateNum = 0; RateDen = 0 })
    Assert-True (Set-CcdFullConfig -Targets $targets -Order @('A')) 'ok'
    Assert-Equal @($false) $script:FullCalls 'went straight to the request without rates'
}

Test-Case 'full config: a refused transition is reported, not swallowed' {
    # Провал обязан вернуться наверх: там переключение уходит на старую дорогу из
    # трёх шагов. Молчаливое «да» оставило бы человека с чёрным экраном.
    function Invoke-CcdFullConfigAttempt {
        param($Targets, [string]$PrimaryPath, [string[]]$Order, [switch]$WithHz)
        return $false
    }
    $targets = @([pscustomobject]@{ DevicePath = 'p'; Label = 'A'; Width = 2560; Height = 1440; Hz = 240 })
    Assert-True (-not (Set-CcdFullConfig -Targets $targets)) 'said no'
}

Test-Case 'full config: a target without a size is refused before Windows sees it' {
    $targets = @([pscustomobject]@{ DevicePath = 'p'; Label = 'A'; Width = 0; Height = 0; Hz = 60 })
    Assert-True (-not (Set-CcdFullConfig -Targets $targets)) 'refused'
}

Test-Case 'full config: no display order in the settings means the long way round' {
    # Задавая стол целиком, координаты приходится назвать каждому экрану — и без
    # порядка из настроек мы расставили бы мониторы по алфавиту там, где человек
    # об этом не просил. Старый путь в этом случае честнее: он двигает только
    # основной монитор.
    $script:FullCalls = @()
    function Invoke-CcdFullConfigAttempt {
        param($Targets, [string]$PrimaryPath, [string[]]$Order, [switch]$WithHz)
        $script:FullCalls += [bool]$WithHz
        return $true
    }
    $targets = @([pscustomobject]@{ DevicePath = 'p'; Label = 'A'; Width = 2560; Height = 1440
                                    Hz = 144; RateNum = 143999; RateDen = 1000 })
    Assert-True (-not (Set-CcdFullConfig -Targets $targets -Order @())) 'refused without an order'
    Assert-True (-not (Set-CcdFullConfig -Targets $targets -Order @('', $null))) 'blank names are not an order either'
    Assert-Equal 0 $script:FullCalls.Count 'Windows was never asked'
}

Test-Case 'mode cache: what a display showed comes back next time' {
    Remove-Item $script:ModeCacheFile -Force -ErrorAction SilentlyContinue
    Save-ModeCache -Modes @{ 'p-ug' = [pscustomobject]@{
        Width = 2560; Height = 1440; Hz = 144; RateNum = 143999; RateDen = 1000 } }
    $back = Get-ModeCache
    Assert-Equal 2560 $back['p-ug'].Width 'resolution'
    Assert-Equal 144 $back['p-ug'].Hz 'refresh rate'
    Assert-Equal 143999 $back['p-ug'].RateNum 'the exact fraction survived the trip through disk'
    Assert-Equal 1000 $back['p-ug'].RateDen 'both halves'
}

Test-Case 'mode cache: a display absent from this switch keeps its entry' {
    # Иначе соло-режим стирал бы память об остальных мониторах, и они снова
    # просыпались бы на чужой частоте.
    Remove-Item $script:ModeCacheFile -Force -ErrorAction SilentlyContinue
    Save-ModeCache -Modes @{ 'p-ug' = [pscustomobject]@{
        Width = 2560; Height = 1440; Hz = 144; RateNum = 143999; RateDen = 1000 } }
    Save-ModeCache -Modes @{ 'p-uf' = [pscustomobject]@{
        Width = 3840; Height = 2160; Hz = 60; RateNum = 59997; RateDen = 1000 } }
    $back = Get-ModeCache
    Assert-Equal 144 $back['p-ug'].Hz 'the old entry survived'
    Assert-Equal 60 $back['p-uf'].Hz 'and the new one is there'
}

Test-Case 'mode cache: an entry without a fraction reads as no fraction, not as junk' {
    # Такие записи будут: монитор мог не отдать частоту вовсе. Ноль здесь честнее
    # выдумки — тогда частоту выбирает система.
    Set-Content -Path $script:ModeCacheFile -Encoding UTF8 `
        -Value '{"p-ug":{"w":2560,"h":1440,"hz":144}}'
    $back = Get-ModeCache
    Assert-Equal 144 $back['p-ug'].Hz 'the mode is there'
    Assert-Equal 0 $back['p-ug'].RateDen 'and no fraction is invented'
}

Test-Case 'mode cache: a damaged file is not a crash' {
    Set-Content -Path $script:ModeCacheFile -Value '{ this is not json' -Encoding UTF8
    Assert-Equal 0 @((Get-ModeCache).Keys).Count 'empty, and nothing threw'
}

Test-Case 'mode cache: junk sizes are ignored, not requested from Windows' {
    Set-Content -Path $script:ModeCacheFile -Encoding UTF8 `
        -Value '{"p-ug":{"w":0,"h":0,"hz":144},"p-uf":{"w":3840,"h":2160,"hz":60}}'
    $back = Get-ModeCache
    Assert-True (-not $back.ContainsKey('p-ug')) 'the impossible entry is gone'
    Assert-Equal 3840 $back['p-uf'].Width 'the sane one stayed'
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
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' 'path-asus'      $true)
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ultragear' $false (-not $UltraGearConnected))
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-ultrafine' $false)
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
        (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D' 'path-asus'      $false $true)
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ultragear' $true)
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-ultrafine' $true)
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
