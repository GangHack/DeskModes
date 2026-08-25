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

# --- крошечный фреймворк ----------------------------------------------------

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

# --- подопытный код ---------------------------------------------------------
# Точки входа дот-сорсить нельзя: Displays.ps1 при загрузке поднимает всё
# приложение. Берём core, WindowLayout и диалог, а Resolve-ModeKey из
# Set-Display.ps1 вытаскиваем отдельно (см. ниже).

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

# Фиктивные мониторы: тесты не должны зависеть от того, что сейчас на столе.
# Поля ровно те, что отдаёт Get-DisplayState: фальшивка не должна знать о полях,
# которых у настоящего состояния нет.
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

# Настройки с комбинациями, одной строкой: их пишет почти каждый тест.
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

# --- разбор и печать комбинаций клавиш --------------------------------------

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

# --- ключи режимов ----------------------------------------------------------

Write-Host ''
Write-Host 'mode keys' -ForegroundColor White

Test-Case 'modes: a fresh desk gets one mode per display plus all, and nothing else' {
    # Что видит человек, впервые подключивший три монитора: три отдельных режима и
    # «все». Ничего не угадывается: наборы появляются только после того, как он сам
    # их создаст.
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
    # Без нумерации оба соло-режима получили бы ОДИН ключ, и «включить только этот»
    # зажигало бы оба монитора.
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
    # Имя комбинации задаёт человек, поэтому заголовок берётся из ключа как есть.
    Assert-Equal 'Movie night' (Get-ModeTitleFromKey 'combo:Movie night') 'combo'
    Assert-Equal 'All displays' (Get-ModeTitleFromKey 'all') 'all'
    Assert-Equal 'something else' (Get-ModeTitleFromKey 'something else') 'unknown falls through'
}

# --- миграция привязок ------------------------------------------------------

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
    # Название в настройках может быть полным — «ROG STRIX XG27AQDMGR», — а система
    # знает монитор как «XG27AQDMGR». Одно содержится в другом.
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

# --- настройки --------------------------------------------------------------

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
    Assert-Equal 0 @($s.combos.Keys).Count 'combos empty'
    Assert-Equal 0 @($s.rules).Count 'rules empty'
}

Test-Case 'settings: a damaged file falls back to defaults and keeps a copy' {
    Set-Content -Path $script:SettingsFile -Value '{ this is not json' -Encoding UTF8
    $s = Get-DisplaySettings
    Assert-True $s.maximizeRefresh 'fell back to defaults'
    Assert-True (Test-Path ($script:SettingsFile + '.bad')) 'kept settings.json.bad'
    Remove-Item ($script:SettingsFile + '.bad') -Force
    Remove-Item $script:SettingsFile -Force
}

Test-Case 'settings: a half-written reapply keeps the other defaults' {
    # Файл правится руками, в нём легко оказаться половине ключей.
    Set-Content -Path $script:SettingsFile -Value '{ "reapply": { "onResume": false } }' -Encoding UTF8
    $s = Get-DisplaySettings
    Assert-True (-not $s.reapply.onResume) 'onResume read'
    Assert-True $s.reapply.onUnplug 'onUnplug stayed default, not null'
    Assert-Equal '' $s.reapply.onPlug 'onPlug stayed default, not null'
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
    $s.audio['combo:Work'] = 'ULTRAFINE'
    Save-DisplaySettings $s

    $back = Get-DisplaySettings
    Assert-Equal 'Ctrl+Alt+F1' $back.hotkeys['solo:LG ULTRAGEAR'] 'hotkey'
    Assert-Equal @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR') @($back.layout) 'layout with order'
    Assert-Equal 'ULTRAGEAR' $back.primary 'primary'
    Assert-True (-not $back.restoreWindows) 'restoreWindows false survived'
    Assert-Equal 'ULTRAFINE' $back.audio['combo:Work'] 'audio mapping'
    Remove-Item $script:SettingsFile -Force
}


# --- совпадение названий ----------------------------------------------------
# Одно правило на всё, где человек называет монитор словами: layout, primary,
# состав комбинации.

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

# --- комбинации -------------------------------------------------------------
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

# --- выбор основного монитора -----------------------------------------------
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
# --- отрисовка меню трея ----------------------------------------------------
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


# --- окно настроек ----------------------------------------------------------
# Окно теперь WPF и собирается БЕЗ показа: New-SettingsWindow строит дерево
# элементов, а Read-SettingsFromUi — настоящая ветка Save — читает его. ShowDialog
# в тестах не зовётся вовсе, поэтому непроверенным остаётся только сам показ.
# Жать Save таймером в настоящем показанном окне не нужно: сохранение вынесено в
# чистую функцию, и тесты не мигают окном.

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
    # Ветка сохранения — настоящая функция, и проверяется она сама, а не её пересказ.
    $settings = Get-DefaultSettings
    $settings.hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
    $settings.layout = @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR')
    $settings.primary = 'ULTRAGEAR'
    $settings.audio['combo:Work'] = 'ULTRAFINE'
    $settings.hooks['combo:Work'] = [ordered]@{ before = ''; after = 'x.cmd' }

    $ui = New-DialogUi -Settings $settings
    try {
        Assert-True ($null -ne $ui.WindowsBox) 'the window has the window-memory toggle'
        Assert-True ([bool]$ui.WindowsBox.IsChecked) 'it reflects the default (on)'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-True $got.Ok 'the save was accepted'
        $updated = $got.Settings

        # XG27AQDMGR сейчас не подключён — его место в ряду обязано выжить.
        Assert-Equal @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR') @($updated.layout) 'layout survived, absent display included'
        # Звезда стояла по шаблону ULTRAGEAR — в файл уезжает точное название.
        Assert-Equal 'LG ULTRAGEAR' $updated.primary 'primary written as the exact name'
        Assert-Equal 'ULTRAFINE' $updated.audio['combo:Work'] 'audio survived'
        Assert-Equal 'x.cmd' $updated.hooks['combo:Work'].after 'the command survived'
        Assert-Equal 'Ctrl+Alt+F1' $updated.hotkeys['solo:LG ULTRAGEAR'] 'hotkey came from the box'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: settings tied to modes keep mode order so Save does not shuffle the file' {
    $modes = @(
        [pscustomobject]@{ Key = 'solo:A'; Title = 'Only A'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'solo:B'; Title = 'Only B'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Patterns = @('A', 'B'); Available = $true }
        [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    )
    # Порядок в файле — какой попало: окно обязано выстроить его по режимам.
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $settings.hotkeys['combo:Work'] = 'Ctrl+Alt+F3'
    $settings.hotkeys['solo:A'] = 'Ctrl+Alt+F1'
    $settings.brightness = [ordered]@{ 'all' = 70; 'solo:A' = 90 }

    $ui = New-SettingsWindow -Modes $modes -Settings $settings -State @()
    try {
        Assert-Equal @('solo:A', 'combo:Work', 'all') @($ui.Hotkeys.Keys) 'shortcuts sorted into mode order'
        Assert-Equal @('solo:A', 'all') @($ui.Levels.Keys) 'and so is the brightness'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a duplicate shortcut is refused, with words' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ui.Hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F1'
        $ui.Hotkeys['all'] = 'Ctrl+Alt+F1'
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
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
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
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
        Assert-True ($ui.Hotkeys.Contains('combo:Movie')) 'the combination has a shortcut'
        Remove-UiCombo -Ui $ui -Combo $ui.Combos[0]
        Assert-True (-not $ui.Hotkeys.Contains('combo:Movie')) 'its shortcut went away with it'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
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
        # Ровно то, что возвращает редактор режима по кнопке Save.
        $mode = [pscustomobject]@{ Key = 'combo:Movie'; Title = 'Movie'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Cinema'; Patterns = @('LG ULTRAGEAR', 'LG ULTRAFINE'); Primary = 'LG ULTRAFINE'
            Hotkey = 'Ctrl+Alt+F9' })
        Assert-Equal 'Ctrl+Alt+F9' $ui.Hotkeys['combo:Cinema'] 'the shortcut followed the rename in the window'
        Assert-True (-not $ui.Hotkeys.Contains('combo:Movie')) 'and left the old key behind'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
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

Test-Case 'dialog: the mode editor prefills members, leftovers, taskbar and shortcut' {
    $combo = [pscustomobject]@{ Name = 'Movie'; Patterns = @('ULTRAGEAR', 'GONE PANEL'); Primary = 'ULTRAGEAR'; OriginalName = 'Movie' }
    $mode = [pscustomobject]@{ Key = 'combo:Movie'; Title = 'Movie'; Kind = 'combo'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $script:DlgState -TakenNames @() `
                               -Hotkeys ([ordered]@{ 'combo:Movie' = 'Ctrl+Alt+F9' }) -Dark $false
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
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -TakenNames @() `
                               -Hotkeys ([ordered]@{ 'all' = 'needs Ctrl / Alt / Shift' }) -Dark $false
    try {
        Assert-Equal $script:NoHotkeyText $ed.HotkeyBox.Text 'hint text did not survive as a binding'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: a shortcut can be removed, and the mode row stays' {
    # «Клавиши не убираются» — так это выглядело, когда снять привязку можно было
    # только Backspace'ом по мелкой строчке-подсказке. Теперь она снимается в
    # редакторе режима, и пустой ответ редактора обязан её убрать.
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal 'Ctrl+Alt+F5' $ui.Hotkeys['all'] 'starts bound'
        $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited ([pscustomobject]@{ Hotkey = '' })
        Assert-True (-not $ui.Hotkeys.Contains('all')) 'the window forgot it'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-True $got.Ok 'saved'
        Assert-True (-not $got.Settings.hotkeys.Contains('all')) 'the binding is gone from the file'
        # А сама строка режима осталась: режимы не удаляются здесь, они следуют из
        # мониторов и комбинаций.
        Assert-Equal 3 $ui.ModesPanel.Children.Count 'two displays and all of them are still listed'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: in-progress hint text never becomes a binding' {
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $ui = New-DialogUi -Settings $settings
    try {
        foreach ($junk in $script:PressKeysText, 'needs Ctrl / Alt / Shift', 'unsupported key', '') {
            $ui.Hotkeys['all'] = $junk
            $got = Read-SettingsFromUi -Ui $ui -Settings $settings
            Assert-True (-not $got.Settings.hotkeys.Contains('all')) "'$junk' is not a binding"
        }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a shortcut picked in the mode editor lands on the mode' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        # Ровно то, что возвращает редактор по Save, вместе с клавишей.
        Set-UiMode -Ui $ui -Mode $null -Combo $null -Edited ([pscustomobject]@{
            Name = 'Movie'; Patterns = @('LG ULTRAGEAR'); Primary = ''; Hotkey = 'Ctrl+Alt+F7' })
        Assert-Equal 'Ctrl+Alt+F7' $ui.Hotkeys['combo:Movie'] 'the mode got the keys'
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-Equal 'Ctrl+Alt+F7' $got.Settings.hotkeys['combo:Movie'] 'and they save'

        # Снять клавишу в редакторе — тоже правка, а не «оставить как было».
        $mode = [pscustomobject]@{ Key = 'combo:Movie'; Title = 'Movie'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Movie'; Patterns = @('LG ULTRAGEAR'); Primary = ''; Hotkey = '' })
        Assert-True (-not $ui.Hotkeys.Contains('combo:Movie')) 'cleared back to no shortcut'
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
    Assert-Equal 'Display' (Get-ModeSubtitle -Mode ([pscustomobject]@{ Kind = 'solo' })) 'a single display'

    $combo = Get-ModeSubtitle -Mode ([pscustomobject]@{
        Kind = 'combo'; Patterns = @('LG ULTRAFINE', 'XG27AQDMGR'); Primary = 'LG ULTRAFINE' }) -State $state
    Assert-True ($combo -like 'Combination*') 'a combination says it is a combination'
    Assert-True ($combo -like '*LG ULTRAFINE + XG27AQDMGR*') 'and lists its displays'
    Assert-True ($combo -like '*taskbar on LG ULTRAFINE*') 'and where the taskbar goes'

    Assert-Equal 'Every connected display' (Get-ModeSubtitle -Mode ([pscustomobject]@{ Kind = 'all' })) 'all'
    Assert-True ((Get-ModeSubtitle -Mode ([pscustomobject]@{ Kind = 'orphan' })) -like '*kept until you remove it*') 'orphan'
}

Test-Case 'dialog: every mode is set up in one place, and only combinations can be removed' {
    # На каждый режим одна строка с кнопкой Edit, а Remove есть только у того, что
    # человек завёл сам.
    $settings = Get-DefaultSettings
    $settings.combos['Movie'] = [ordered]@{ displays = @('ULTRAGEAR'); primary = '' }
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Null $ui.Window.FindName('RolesPanel') 'no display-groups panel'
        Assert-Null $ui.Window.FindName('CombosPanel') 'no separate combinations card'
        Assert-Null $ui.Window.FindName('LevelModeBox') 'and no brightness card of its own'
        Assert-True ($null -ne $ui.ModesPanel) 'modes are the one place'
        Assert-True ($null -ne $ui.AddComboBtn) 'with a button to add a combination'

        # solo:UG, solo:UF, combo:Movie, all — у каждой строки Edit, Remove только
        # у комбинации.
        $buttons = @()
        foreach ($row in $ui.ModesPanel.Children) {
            $names = @($row.Children | Where-Object { $_ -is [System.Windows.Controls.Button] } | ForEach-Object { [string]$_.Content })
            $buttons += , $names
        }
        Assert-Equal 4 $buttons.Count 'a row per mode'
        Assert-Equal 4 @($buttons | Where-Object { $_ -contains 'Edit' }).Count 'every mode can be edited'
        Assert-Equal 1 @($buttons | Where-Object { $_ -contains 'Remove' }).Count 'only the combination can be removed'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: the cross clears a shortcut and greys itself out when there is nothing to clear' {
    # Кнопка и поле находят друг друга через .Tag — без этого крестик молча не
    # работал бы (замыкания в обработчиках теряют и функции, и $script:).
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -TakenNames @() `
                               -Hotkeys ([ordered]@{ 'all' = 'Ctrl+Alt+F5' }) -Dark $false
    try {
        $box = $ed.HotkeyBox
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
    finally { $ed.Window.Close() }
}

Test-Case 'mode editor: what it reads, and every refusal' {
    $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $script:DlgState `
                               -TakenNames @('Movie') -Hotkeys ([ordered]@{ 'all' = 'Ctrl+Alt+F5' }) -Dark $false
    try {
        # Пустое имя.
        $got = Read-ModeFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'no name is refused'
        Assert-True ($got.Problem -like '*name*') 'and says so'

        # Имя занято.
        $ed.NameBox.Text = 'movie'
        $got = Read-ModeFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'a taken name is refused, case aside'
        Assert-True ($got.Problem -like "*already exists*") 'and says so'

        # Ни одного монитора.
        $ed.NameBox.Text = 'Cinema'
        $got = Read-ModeFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'no displays is refused'
        Assert-True ($got.Problem -like '*at least one display*') 'and says so'

        # Чужая клавиша.
        $ed.Checks[0].IsChecked = $true
        $ed.HotkeyBox.Text = 'Ctrl+Alt+F5'
        $got = Read-ModeFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'a shortcut owned by another mode is refused'
        Assert-True ($got.Problem -like "*already drives 'All displays'*") 'and names the mode holding it'

        # Всё в порядке.
        $ed.HotkeyBox.Text = 'Ctrl+Alt+F6'
        $got = Read-ModeFromUi -Editor $ed
        Assert-True $got.Ok 'accepted'
        Assert-Equal 'Cinema' $got.Mode.Name 'name trimmed and kept'
        Assert-Equal @('LG ULTRAGEAR') @($got.Mode.Patterns) 'the ticked display'
        Assert-Equal 'Ctrl+Alt+F6' $got.Mode.Hotkey 'the shortcut'
        Assert-Equal '' $got.Mode.Primary 'no taskbar display chosen means the usual rules'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'combo editor: the taskbar display must be one of the ticked ones' {
    $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $script:DlgState -TakenNames @() -Dark $false
    try {
        $ed.NameBox.Text = 'Pair'
        $ed.Checks[0].IsChecked = $true
        $ed.PrimaryBox.SelectedItem = [string]$ed.Checks[1].Tag   # не отмечен
        $got = Read-ModeFromUi -Editor $ed
        Assert-True (-not $got.Ok) 'refused'
        Assert-True ($got.Problem -like '*must be one of the ticked*') 'and says why'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: a mode keeping its own shortcut is not a conflict with itself' {
    $settings = Get-DefaultSettings
    $settings.hotkeys['all'] = 'Ctrl+Alt+F5'
    $settings.combos['Movie'] = [ordered]@{ displays = @('ULTRAGEAR'); primary = '' }
    $settings.hotkeys['combo:Movie'] = 'Ctrl+Alt+F9'
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = [pscustomobject]@{ Key = 'combo:Movie'; Title = 'Movie'; Kind = 'combo'; Available = $true }
        $ed = New-ModeEditorWindow -Mode $mode -Combo $ui.Combos[0] -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark $false
        try {
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'its own binding, left alone, goes through'
            Assert-Equal 'Ctrl+Alt+F9' $got.Mode.Hotkey 'and comes back as it was'

            $ed.HotkeyBox.Text = 'Ctrl+Alt+F5'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True (-not $got.Ok) "another mode's binding is refused"
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a binding without its display still gets a row' {
    $settings = Get-DefaultSettings
    $settings.hotkeys['solo:GONE MONITOR'] = 'Ctrl+Alt+F8'
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-True ($ui.Hotkeys.Contains('solo:GONE MONITOR')) 'orphan binding kept'
        Assert-Equal 'Ctrl+Alt+F8' $ui.Hotkeys['solo:GONE MONITOR'] 'with its combination shown'
        # Строка-сирота есть в списке: снять привязку можно только отсюда.
        Assert-Equal 4 $ui.ModesPanel.Children.Count 'two displays, all of them, and the orphan'
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
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

# --- Resolve-ModeKey из Set-Display.ps1 -------------------------------------

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
    Assert-Equal 'all' (Resolve-ModeKey 'all' $script:ResolveModes).Key 'all'
    Assert-Equal 'combo:Work' (Resolve-ModeKey 'combo:Work' $script:ResolveModes).Key 'combo key'
}

Test-Case 'resolve: a combination by name, case and spaces aside' {
    Assert-Equal 'combo:Movie night' (Resolve-ModeKey 'movie night' $script:ResolveModes).Key 'lower case, with a space'
}

Test-Case 'resolve: work.cmd and game.cmd find their combinations' {
    # Обёртки зовут `Set-Display.ps1 work` и `game`, а комбинации названы «Work» и
    # «Game»: сравнение имени регистр не различает.
    Assert-Equal 'combo:Work' (Resolve-ModeKey 'work' $script:ResolveModes).Key 'work'
    Assert-Equal 'combo:Game' (Resolve-ModeKey 'game' $script:ResolveModes).Key 'game, a set of one'
}

Test-Case 'resolve: a short monitor id' {
    Assert-Equal 'solo:LG ULTRAFINE' (Resolve-ModeKey 'GSM5CBC' $script:ResolveModes).Key 'by short id'
}

Test-Case 'resolve: part of a monitor name' {
    Assert-Equal 'solo:LG ULTRAGEAR' (Resolve-ModeKey 'ULTRAGEAR' $script:ResolveModes).Key 'by name part'
}

Test-Case 'resolve: an ambiguous name is refused, not guessed' {
    $threw = $false
    try { [void](Resolve-ModeKey 'LG' $script:ResolveModes) }
    catch { $threw = $true; Assert-True ($_.Exception.Message -like '*matches several modes*') 'said why' }
    Assert-True $threw 'threw on ambiguity'
}

Test-Case 'resolve: an unknown name is refused with a hint' {
    $threw = $false
    try { [void](Resolve-ModeKey 'nosuchthing' $script:ResolveModes) }
    catch { $threw = $true; Assert-True ($_.Exception.Message -like '*Unknown mode*') 'said unknown' }
    Assert-True $threw 'threw on unknown'
}

# --- ключ раскладки столов --------------------------------------------------

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

# --- ретрай раскладки и вердикт переключения --------------------------------
# Валидация раскладки отвечает 87 сразу после смены топологии. Если единственная
# попытка молча провалится, а переключение отчитается успехом, мониторы до
# следующего хоткея стоят перепутанными. Отсюда два свойства, прибитые тестами:
# раскладка повторяется, провал попадает в вердикт.

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

# --- стол одним переходом ---------------------------------------------------
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
    # нельзя: CCD отвергает такой запрос целиком (validate -> 1610),
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

Test-Case 'already best: every display sitting in its maximum mode' {
    # Третья проверка «уже сделано»: на ней стоит пропуск перечисления выходов и
    # двух запросов режима на каждый монитор при повторном нажатии хоткея.
    $m = New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'p-ug'
    $m.BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 144 }
    Assert-True (Test-ModesAlreadyBest @($m)) 'current mode equals the best one'
}

Test-Case 'already best: a lower refresh rate is not "already best"' {
    # Ровно тот случай, ради которого сторож частоты и существует: разрешение то
    # же, а герцы Windows уронила.
    $m = New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'p-ug'
    $m.Hz = 60
    $m.BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 144 }
    Assert-True (-not (Test-ModesAlreadyBest @($m))) 'the rate has to match too'
}

Test-Case 'already best: a display that is off or has no best mode is not' {
    # У только что проснувшегося монитора BestMode ещё $null — перебор режимов
    # обязан состояться, иначе он останется на частоте из реестра Windows.
    $off = New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'p-xg' $false
    $off.BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 144 }
    Assert-True (-not (Test-ModesAlreadyBest @($off))) 'a dark display proves nothing'

    $woke = New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'p-xg'
    $woke.BestMode = $null
    Assert-True (-not (Test-ModesAlreadyBest @($woke))) 'nothing known about the best mode'
}

Test-Case 'already best: one display out of three is enough to spoil it' {
    $good = New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'p-ug'
    $good.BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 144 }
    $bad = New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'p-uf'
    $bad.Width = 3840; $bad.Height = 2160; $bad.Hz = 30
    $bad.BestMode = [pscustomobject]@{ Width = 3840; Height = 2160; Hz = 60 }
    Assert-True (-not (Test-ModesAlreadyBest @($good, $bad))) 'the whole set has to be right'
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
    # Иначе трей показывает зелёное «Displays switched», хотя мониторы стоят не в
    # том порядке.
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

Test-Case 'phases: breakdown keeps switch order and drops the invisible' {
    $t = Format-PhaseTimes ([ordered]@{ state = 0.31; apply = 1.24; settle = 0.01 })
    Assert-Equal 'state 0.3, apply 1.2' $t 'only phases that took time, in the order they ran'
}

Test-Case 'phases: a quiet switch prints nothing at all' {
    # Иначе каждый no-op тащил бы в done: хвост из нулей.
    Assert-Equal '' ([string](Format-PhaseTimes ([ordered]@{ apply = 0.01 }))) 'all quiet - empty'
    Assert-Equal '' ([string](Format-PhaseTimes $null)) 'no phases at all is fine too'
}

# --- последний выбранный режим ----------------------------------------------

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

# --- возврат режима при старте трея -----------------------------------------
# Живьём это проверяется только перезагрузкой, поэтому решение («возвращать или
# не трогать») тестируем отдельно от самого переключения. Функцию достаём из
# Displays.ps1 разбором файла — дот-сорснуть его нельзя, он поднимает всё
# приложение, а копия кода в тесте разошлась бы с оригиналом (тот же приём, что и
# для Resolve-ModeKey выше).

Write-Host ''
Write-Host 'restoring the mode when the tray starts' -ForegroundColor White

$trayAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Displays.ps1'), [ref]$null, [ref]$null)
foreach ($name in 'Get-AvailableMode', 'Invoke-StartupRestore') {
    $found = $trayAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }.GetNewClosure(), $true)
    if ($found.Count -ne 1) { throw "expected exactly one $name in Displays.ps1, found $($found.Count)" }
    . ([scriptblock]::Create($found[0].Extent.Text))
}

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

# Включён только ASUS, все три монитора подключены.
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

# --- настройки: новые ключи -------------------------------------------------
# Разбор настроек — единственное место, куда попадает написанное рукой, и правил
# сокращённой записи здесь больше, чем кажется: число вместо словаря, строка
# вместо объекта, отсутствие ключа вместо значения по умолчанию.

Write-Host ''
Write-Host 'the new settings keys' -ForegroundColor White

function Set-TestSettingsFile {
    param([string]$Json)
    $Json | Set-Content -Path $script:SettingsFile -Encoding UTF8
}

Test-Case 'settings: defaults for everything new' {
    Remove-Item $script:SettingsFile -Force -ErrorAction SilentlyContinue
    $s = Get-DisplaySettings
    Assert-Equal $false $s.stats 'the diary stays off until asked'
    Assert-Equal $true $s.reapply.onResume 'rebuild the desk after sleep'
    Assert-Equal $true $s.reapply.onUnplug 'rebuild it when a display goes away'
    Assert-Equal '' $s.reapply.onPlug 'nothing is guessed when a display appears'
    Assert-Equal 0 @($s.rules).Count 'no rules invented'
    Assert-Equal 0 $s.hooks.Count 'no commands invented'
    Assert-Equal 0 $s.brightness.Count 'no levels invented'
}

Test-Case 'settings: rules read in file order, with their defaults' {
    Set-TestSettingsFile '{ "rules": [
        { "when": "process", "process": "cs2", "mode": "solo:XG27AQDMGR" },
        { "when": "idle", "minutes": 20, "mode": "solo:LG ULTRAGEAR", "back": "combo:Work", "enabled": false } ] }'
    $s = Get-DisplaySettings
    Assert-Equal 2 @($s.rules).Count 'both rules'
    Assert-Equal 'process' $s.rules[0].when 'first is the process rule'
    Assert-Equal $true $s.rules[0].enabled 'a rule is on unless it says otherwise'
    Assert-Equal 0 $s.rules[0].minutes 'no minutes means zero, not null'
    Assert-Equal 20 $s.rules[1].minutes 'minutes come through as a number'
    Assert-Equal $false $s.rules[1].enabled 'a rule can be switched off without deleting it'
    Assert-Equal 'combo:Work' $s.rules[1].back 'where to go back to'
}

# Разбор каждой формы записи — чистыми функциями, по одной на форму. Файл правят
# руками, поэтому «не разобралось» обязано означать «настройки нет», а не падение.

Test-Case 'parse: a combination in all three spellings comes out the same shape' {
    $full = ConvertTo-ComboSetting ([pscustomobject]@{ displays = @('A', 'B'); primary = 'A' })
    Assert-Equal @('A', 'B') @($full.displays) 'the full form'
    Assert-Equal 'A' $full.primary 'with its taskbar display'

    $short = ConvertTo-ComboSetting @('A', 'B')
    Assert-Equal @('A', 'B') @($short.displays) 'a bare array'
    Assert-Equal '' $short.primary 'and no taskbar display of its own'

    $shorter = ConvertTo-ComboSetting 'A'
    Assert-Equal @('A') @($shorter.displays) 'a bare string is a set of one'
}

Test-Case 'parse: junk in a combination is an empty set, not a crash' {
    $empty = ConvertTo-ComboSetting $null
    Assert-Equal 0 @($empty.displays).Count 'nothing at all'
    $blanks = ConvertTo-ComboSetting @('A', '', $null)
    Assert-Equal @('A') @($blanks.displays) 'empty names are dropped'
}

Test-Case 'parse: a command is a string for after, an object for both' {
    Assert-Equal 'x.cmd' (ConvertTo-HookSetting 'x.cmd').after 'a bare string means after'
    Assert-Equal '' (ConvertTo-HookSetting 'x.cmd').before 'and only after'
    $both = ConvertTo-HookSetting ([pscustomobject]@{ before = 'a'; after = 'b' })
    Assert-Equal 'a' $both.before 'before'
    Assert-Equal 'b' $both.after 'after'
    Assert-Null (ConvertTo-HookSetting ([pscustomobject]@{ })) 'an empty pair is not a setting'
    Assert-Null (ConvertTo-HookSetting $null) 'and neither is nothing'
}

Test-Case 'parse: a level is a number or a map, and junk is neither' {
    Assert-Equal 80 (ConvertTo-LevelSetting 80) 'one number for the whole mode'
    $per = ConvertTo-LevelSetting ([pscustomobject]@{ 'ULTRAFINE' = 25; 'ULTRAGEAR' = 60 })
    Assert-Equal 25 $per['ULTRAFINE'] 'a level for each display'
    Assert-Null (ConvertTo-LevelSetting $null) 'nothing is not a setting'
    Assert-Null (ConvertTo-LevelSetting ([pscustomobject]@{ })) 'and neither is an empty map'
}

Test-Case 'parse: rules always come out as a list, even a list of one' {
    # Функция, вернувшая массив из одного элемента, отдаёт его СКАЛЯРОМ — поэтому
    # вызывающий обязан обернуть её в @(). Иначе $s.rules[0] перестаёт существовать.
    $one = @(ConvertTo-RuleSettings @([pscustomobject]@{ process = 'cs2'; mode = 'all' }))
    Assert-Equal 1 $one.Count 'one rule'
    Assert-Equal 'process' ([string]$one[0].when) 'when defaults to process'
    Assert-Equal $true $one[0].enabled 'and a rule is on unless it says otherwise'
    Assert-Equal 0 $one[0].minutes 'minutes default to zero'

    $none = @(ConvertTo-RuleSettings $null)
    Assert-Equal 0 $none.Count 'nothing in, nothing out'
}

Test-Case 'parse: WHEN is lower-cased so the file can shout' {
    $r = @(ConvertTo-RuleSettings @([pscustomobject]@{ when = 'IDLE'; minutes = 5; mode = 'all' }))
    Assert-Equal 'idle' ([string]$r[0].when) 'compared in lower case downstream'
}

Test-Case 'settings: a rule without "when" is a process rule' {
    Set-TestSettingsFile '{ "rules": [ { "process": "cs2", "mode": "all" } ] }'
    $s = Get-DisplaySettings
    Assert-Equal 'process' $s.rules[0].when 'the common case needs no ceremony'
}

Test-Case 'settings: a command can be a string instead of an object' {
    Set-TestSettingsFile '{ "hooks": {
        "all": "notepad.exe",
        "combo:Work": { "before": "one.cmd", "after": "two.cmd" },
        "solo:X": { } } }'
    $s = Get-DisplaySettings
    Assert-Equal 'notepad.exe' (Get-ModeHook -Settings $s -ModeKey 'all' -Phase 'after') 'a bare string means after'
    Assert-Equal '' (Get-ModeHook -Settings $s -ModeKey 'all' -Phase 'before') 'and only after'
    Assert-Equal 'one.cmd' (Get-ModeHook -Settings $s -ModeKey 'combo:Work' -Phase 'before') 'before'
    Assert-Equal 'two.cmd' (Get-ModeHook -Settings $s -ModeKey 'combo:Work' -Phase 'after') 'after'
    Assert-Equal $false ($s.hooks.Contains('solo:X')) 'an empty pair is not kept at all'
    Assert-Equal '' (Get-ModeHook -Settings $s -ModeKey 'nobody' -Phase 'after') 'a mode with no command'
}

Test-Case 'settings: brightness is either one number or one per display' {
    Set-TestSettingsFile '{ "brightness": { "combo:Work": 80, "all": { "ULTRAFINE": 25, "XG27": 40 } },
                            "contrast": { "combo:Work": 70 } }'
    $s = Get-DisplaySettings
    Assert-Equal 80 $s.brightness['combo:Work'] 'a number for the whole set'
    Assert-Equal 25 $s.brightness['all']['ULTRAFINE'] 'and a dictionary when each differs'
    Assert-Equal 70 $s.contrast['combo:Work'] 'contrast reads the same way'
}

Test-Case 'settings: a damaged file still gives working defaults for the new keys' {
    Set-TestSettingsFile '{ "rules": [ { "when": '
    $s = Get-DisplaySettings
    Assert-Equal 0 @($s.rules).Count 'no rules'
    Assert-Equal $true $s.reapply.onResume 'and the rest of the defaults are intact'
}

Test-Case 'hotkeys: a display on a new input takes its levels and commands with it' {
    # Тот же случай, что и с клавишей: монитор переехал на другой вход, ключ
    # режима сменился. Яркость обязана переехать вместе с ним, иначе одна
    # настройка разъедется на две половины.
    $s = Get-DefaultSettings
    $s.hotkeys = [ordered]@{ 'solo:GSM5BB3' = 'Ctrl+Alt+F1' }
    $s.brightness = [ordered]@{ 'solo:GSM5BB3' = 55 }
    $s.hooks = [ordered]@{ 'solo:GSM5BB3' = [ordered]@{ before = ''; after = 'x.cmd' } }
    $s.rules = @([ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'solo:GSM5BB3'; back = ''; enabled = $true })
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ultragear'))
    [void](Update-HotkeyKeys $s $state)
    Assert-True ($s.hotkeys.Contains('solo:LG ULTRAGEAR')) 'the shortcut moved'
    Assert-True ($s.brightness.Contains('solo:LG ULTRAGEAR')) 'the brightness moved with it'
    Assert-True ($s.hooks.Contains('solo:LG ULTRAGEAR')) 'the command too'
    Assert-Equal 'solo:LG ULTRAGEAR' $s.rules[0].mode 'and the rule points at the display, still'
}

# --- команды вокруг переключения --------------------------------------------

Write-Host ''
Write-Host 'the commands around a switch' -ForegroundColor White

Test-Case 'hook: a plain command goes through cmd' {
    $launch = Get-HookLaunch -Command 'taskkill /im slack.exe'
    Assert-True ($launch.File -like '*cmd.exe') 'cmd.exe'
    Assert-Equal '/c taskkill /im slack.exe' $launch.Arguments 'the command as written'
}

Test-Case 'hook: a .ps1 goes through powershell, with the policy bypassed' {
    $launch = Get-HookLaunch -Command 'C:\tools\lights.ps1'
    Assert-True ($launch.File -like '*powershell.exe') 'powershell'
    Assert-True ($launch.Arguments -like '*-ExecutionPolicy Bypass*') 'own scripts must run without ceremony'
    Assert-True ($launch.Arguments -like '*-File "C:\tools\lights.ps1"*') 'the script path is quoted'
}

Test-Case 'hook: a quoted path with spaces survives, and so do its arguments' {
    $launch = Get-HookLaunch -Command '"C:\my tools\lights.ps1" -Room bedroom'
    Assert-True ($launch.Arguments -like '*-File "C:\my tools\lights.ps1" -Room bedroom*') 'path and arguments both'
}

Test-Case 'hook: nothing to run means nothing is returned' {
    Assert-Null (Get-HookLaunch -Command '') 'empty'
    Assert-Null (Get-HookLaunch -Command '   ') 'spaces only'
}

# --- яркость ----------------------------------------------------------------

Write-Host ''
Write-Host 'brightness and contrast as part of a mode' -ForegroundColor White

$script:LevelWanted = @(
    (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC')
    (New-FakeMonitor 'XG27AQDMGR'   'AUSAA1D')
)

Test-Case 'levels: one number goes to every display of the mode' {
    $plan = Get-LevelPlan -Setting 80 -Wanted $script:LevelWanted
    Assert-Equal 2 $plan.Count 'both displays'
    Assert-Equal 80 $plan['LG ULTRAFINE'] 'the 4K panel'
    Assert-Equal 80 $plan['XG27AQDMGR'] 'and the ASUS'
}

Test-Case 'levels: a dictionary matches displays by part of the name' {
    $plan = Get-LevelPlan -Setting ([ordered]@{ 'ULTRAFINE' = 25 }) -Wanted $script:LevelWanted
    Assert-Equal 1 $plan.Count 'only the one named'
    Assert-Equal 25 $plan['LG ULTRAFINE'] 'found by a piece of its name'
}

Test-Case 'levels: a display named by its short id is found too' {
    $plan = Get-LevelPlan -Setting ([ordered]@{ 'AUSAA1D' = 40 }) -Wanted $script:LevelWanted
    Assert-Equal 40 $plan['XG27AQDMGR'] 'the short monitor id works as a name'
}

Test-Case 'levels: numbers outside 0..100 are clamped, not obeyed' {
    # Опечатка в настройках не должна уводить монитор в чёрный.
    $plan = Get-LevelPlan -Setting 500 -Wanted $script:LevelWanted
    Assert-Equal 100 $plan['XG27AQDMGR'] 'above the range'
    $plan = Get-LevelPlan -Setting -20 -Wanted $script:LevelWanted
    Assert-Equal 0 $plan['XG27AQDMGR'] 'below the range'
}

Test-Case 'levels: zero is a legal brightness and is kept' {
    $plan = Get-LevelPlan -Setting 0 -Wanted $script:LevelWanted
    Assert-Equal 2 $plan.Count 'zero is a value, not a missing one'
    Assert-Equal 0 $plan['LG ULTRAFINE'] 'and it is zero'
}

Test-Case 'levels: junk in the settings is ignored, not guessed at' {
    $plan = Get-LevelPlan -Setting 'bright' -Wanted $script:LevelWanted
    Assert-Equal 0 $plan.Count 'nothing to do'
    $plan = Get-LevelPlan -Setting $null -Wanted $script:LevelWanted
    Assert-Equal 0 $plan.Count 'nothing set at all'
}

# --- правила ----------------------------------------------------------------
# Живьём это проверяется запуском игры и двадцатиминутным ожиданием, поэтому
# решение отделено от исполнения и проверяется здесь целиком.

Write-Host ''
Write-Host 'rules' -ForegroundColor White

function New-TestRule {
    param([string]$When = 'process', [string]$Process = '', [int]$Minutes = 0,
          [string]$Mode = 'solo:A', [string]$Back = '', [bool]$Enabled = $true)
    return [ordered]@{ when = $When; process = $Process; minutes = $Minutes
                       mode = $Mode; back = $Back; enabled = $Enabled }
}

function New-TestFacts {
    param($Processes = @(), [int]$IdleSeconds = 0)
    return [pscustomobject]@{ Processes = @($Processes); IdleSeconds = $IdleSeconds }
}

Test-Case 'rule match: a running process' {
    $rule = New-TestRule -Process 'cs2'
    Assert-True (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @('chrome', 'cs2'))) 'running'
    Assert-Equal $false (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @('chrome'))) 'not running'
}

Test-Case 'rule match: the .exe people write out of habit is forgiven' {
    $rule = New-TestRule -Process 'CS2.exe'
    Assert-True (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @('cs2'))) 'suffix and case both'
}

Test-Case 'rule match: a rule that is switched off never matches' {
    $rule = New-TestRule -Process 'cs2' -Enabled $false
    Assert-Equal $false (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @('cs2'))) 'off is off'
}

Test-Case 'rule match: a rule without a mode is not a rule' {
    $rule = New-TestRule -Process 'cs2' -Mode ''
    Assert-Equal $false (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @('cs2'))) 'nowhere to go'
}

Test-Case 'rule match: idle counts in minutes' {
    $rule = New-TestRule -When 'idle' -Minutes 20
    Assert-Equal $false (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @() 1199)) 'a second short'
    Assert-True (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @() 1200)) 'exactly twenty minutes'
}

Test-Case 'rule match: idle without minutes is not a rule' {
    $rule = New-TestRule -When 'idle' -Minutes 0
    Assert-Equal $false (Test-RuleMatch -Rule $rule -Facts (New-TestFacts @() 99999)) 'zero minutes would fire forever'
}

Test-Case 'rule match: a condition we do not know is refused, not assumed' {
    $rule = New-TestRule -When 'fullmoon'
    Assert-Equal $false (Test-RuleMatch -Rule $rule -Facts (New-TestFacts)) 'unknown means no'
}

Test-Case 'rule: the first matching rule wins' {
    $rules = @((New-TestRule -Process 'chrome' -Mode 'solo:A'), (New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('chrome', 'cs2')) -CurrentMode 'all'
    Assert-Equal 'switch' $d.Action 'switching'
    Assert-Equal 'solo:A' $d.Mode 'to the first one'
    Assert-Equal 0 $d.RuleIndex 'and it is remembered by number'
    Assert-Equal 'all' $d.Back 'coming back to where we were'
}

Test-Case 'rule: an explicit "back" beats where we happened to be' {
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B' -Back 'combo:Work'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('cs2')) -CurrentMode 'all'
    Assert-Equal 'combo:Work' $d.Back 'as written in the rule'
}

Test-Case 'rule: already in that mode means there is nothing to take over' {
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('cs2')) -CurrentMode 'solo:B'
    Assert-Equal 'none' $d.Action 'nothing to do, and nothing to give back later'
}

Test-Case 'rule: no way back means we do not go' {
    # Текущий набор экранов не совпал ни с одним режимом: уйти можно, вернуться
    # некуда. Это тот случай, ради которого решение отделено от действия.
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('cs2')) -CurrentMode ''
    Assert-Equal 'blocked' $d.Action 'refused'
    Assert-True ($d.Reason -like '*no way back*') 'and it says why'
}

Test-Case 'rule: while the condition holds, nothing happens again' {
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('cs2')) -CurrentMode 'solo:B' -OwnedIndex 0 -OwnedBack 'all'
    Assert-Equal 'none' $d.Action 'the fifteen-second timer does not re-switch anything'
}

Test-Case 'rule: the condition ends and we go back' {
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('chrome')) -CurrentMode 'solo:B' -OwnedIndex 0 -OwnedBack 'combo:Work'
    Assert-Equal 'return' $d.Action 'going back'
    Assert-Equal 'combo:Work' $d.Mode 'to where we came from'
}

Test-Case 'rule: switched by hand during the game means we let go' {
    $rules = @((New-TestRule -Process 'cs2' -Mode 'solo:B'))
    $d = Get-RuleDecision -Rules $rules -Facts (New-TestFacts @('cs2')) -CurrentMode 'all' -OwnedIndex 0 -OwnedBack 'combo:Work'
    Assert-Equal 'release' $d.Action 'no war with the human'
}

Test-Case 'rule: a rule deleted while it held the desk still gives the desk back' {
    $d = Get-RuleDecision -Rules @() -Facts (New-TestFacts) -CurrentMode 'solo:B' -OwnedIndex 0 -OwnedBack 'combo:Work'
    Assert-Equal 'return' $d.Action 'back'
    Assert-Equal 'combo:Work' $d.Mode 'to where we came from'
}

Test-Case 'rule: no rules at all is a quiet no' {
    $d = Get-RuleDecision -Rules @() -Facts (New-TestFacts @('cs2')) -CurrentMode 'all'
    Assert-Equal 'none' $d.Action 'nothing'
}

Test-Case 'rule reason: reads like a sentence in the log' {
    Assert-Equal 'cs2 is running' (Format-RuleReason (New-TestRule -Process 'cs2'))
    Assert-Equal 'idle for 20 min' (Format-RuleReason (New-TestRule -When 'idle' -Minutes 20))
}

# --- мир изменился сам ------------------------------------------------------

Write-Host ''
Write-Host 'rebuilding the desk when the world changed' -ForegroundColor White

Test-Case 'reapply: a display went away and the last mode is rebuilt' {
    $r = (Get-DefaultSettings).reapply
    $d = Get-ReapplyDecision -Reapply $r -Before @('a', 'b') -Now @('a') -LastMode 'combo:Work'
    Assert-Equal 'mode' $d.Action 'rebuilding'
    Assert-Equal 'combo:Work' $d.Mode 'the last chosen mode'
    Assert-True ($d.Reason -like '*went away*') 'and it says why'
}

Test-Case 'reapply: a display appeared and nothing happens unless asked' {
    $r = (Get-DefaultSettings).reapply
    $d = Get-ReapplyDecision -Reapply $r -Before @('a') -Now @('a', 'b') -LastMode 'combo:Work'
    Assert-Equal 'none' $d.Action 'turning off what the human just turned on would be a war'
}

Test-Case 'reapply: a display appeared and the named mode is applied' {
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'all'
    $d = Get-ReapplyDecision -Reapply $r -Before @('a') -Now @('a', 'b') -LastMode 'combo:Work'
    Assert-Equal 'mode' $d.Action 'applying'
    Assert-Equal 'all' $d.Mode 'the mode named in the settings'
}

Test-Case 'reapply: our own switching never triggers it' {
    # Наши переключения меняют ВКЛЮЧЁННЫЕ мониторы, а сравниваются подключённые:
    # набор тот же — реакции нет. Без этого получался бы бесконечный круг.
    $r = (Get-DefaultSettings).reapply
    $d = Get-ReapplyDecision -Reapply $r -Before @('a', 'b') -Now @('b', 'a') -LastMode 'combo:Work'
    Assert-Equal 'none' $d.Action 'same set, different order'
}

Test-Case 'reapply: turned off in the settings means nothing happens' {
    $r = (Get-DefaultSettings).reapply
    $r.onUnplug = $false
    $d = Get-ReapplyDecision -Reapply $r -Before @('a', 'b') -Now @('a') -LastMode 'combo:Work'
    Assert-Equal 'none' $d.Action 'his choice'
}

Test-Case 'reapply: nothing remembered means nothing to rebuild' {
    $r = (Get-DefaultSettings).reapply
    $d = Get-ReapplyDecision -Reapply $r -Before @('a', 'b') -Now @('a') -LastMode ''
    Assert-Equal 'none' $d.Action 'no last mode'
}

Test-Case 'reapply: the first look at the desk is not a change' {
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'all'
    $d = Get-ReapplyDecision -Reapply $r -Before @() -Now @('a', 'b') -LastMode 'combo:Work'
    Assert-Equal 'none' $d.Action 'the tray just started - there is nothing to compare with'
}

Test-Case 'reapply: a cable swapped for another display prefers the plug rule' {
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'all'
    $d = Get-ReapplyDecision -Reapply $r -Before @('a') -Now @('b') -LastMode 'combo:Work'
    Assert-Equal 'all' $d.Mode 'the new display is the news here'
}

# --- таймер выключения ------------------------------------------------------

Write-Host ''
Write-Host 'the shutdown timer' -ForegroundColor White

Test-Case 'duration: plain minutes' {
    Assert-Equal 30 (ConvertFrom-DurationText '30')
    Assert-Equal 45 (ConvertFrom-DurationText ' 45 ')
    Assert-Equal 90 (ConvertFrom-DurationText '90m')
    Assert-Equal 90 (ConvertFrom-DurationText '90 min')
}

Test-Case 'duration: hours, with and without minutes' {
    Assert-Equal 60 (ConvertFrom-DurationText '1h')
    Assert-Equal 120 (ConvertFrom-DurationText '2 hours')
    Assert-Equal 90 (ConvertFrom-DurationText '1h30')
    Assert-Equal 90 (ConvertFrom-DurationText '1h 30m')
    Assert-Equal 90 (ConvertFrom-DurationText '1:30')
}

Test-Case 'duration: what we do not understand is zero, not a guess' {
    Assert-Equal 0 (ConvertFrom-DurationText 'soon')
    Assert-Equal 0 (ConvertFrom-DurationText '')
    Assert-Equal 0 (ConvertFrom-DurationText 'tomorrow at five')
}

Test-Case 'duration: reads back as a human would say it' {
    Assert-Equal '30 s' (Format-Duration 30)
    Assert-Equal '45 min' (Format-Duration 2700)
    Assert-Equal '1 h 00 min' (Format-Duration 3600)
    Assert-Equal '1 h 30 min' (Format-Duration 5400)
    Assert-Equal '0 s' (Format-Duration -5)
}

Test-Case 'duration: the short form drops the empty zero' {
    Assert-Equal '45 min' (Format-DurationShort 45)
    Assert-Equal '1 h' (Format-DurationShort 60)
    Assert-Equal '1 h 30 min' (Format-DurationShort 90)
    Assert-Equal '12 h' (Format-DurationShort 720)
}

Test-Case 'duration: what the timer window shows, it can read back' {
    # Поле в окне таймера — одно и то же и на запись, и на чтение: ползунок пишет
    # в него Format-DurationShort, а разбирает написанное ConvertFrom-DurationText.
    # Разойдись эти двое — и ползунок сбрасывал бы собственное значение.
    foreach ($minutes in (Get-TimerSteps)) {
        Assert-Equal $minutes (ConvertFrom-DurationText (Format-DurationShort $minutes)) "round trip of $minutes"
    }
}

Test-Case 'timer steps: the slider lands on the nearest one, not the one below' {
    $steps = Get-TimerSteps
    Assert-Equal 5 $steps[0] 'the shortest step'
    Assert-Equal 720 $steps[$steps.Count - 1] 'the longest step'
    Assert-Equal 5 (Get-TimerStepMinutes -Index (Get-TimerStepIndex -Minutes 6))
    Assert-Equal 90 (Get-TimerStepMinutes -Index (Get-TimerStepIndex -Minutes 89))
    Assert-Equal 720 (Get-TimerStepMinutes -Index (Get-TimerStepIndex -Minutes 5000)) 'beyond the last step'
    Assert-Equal 5 (Get-TimerStepMinutes -Index -3) 'below the first index'
    Assert-Equal 720 (Get-TimerStepMinutes -Index 999) 'above the last index'
}

Test-Case 'timer nudge: five minutes, on the five-minute grid' {
    Assert-Equal 50 (Get-TimerNudge -Minutes 45 -Step 5)
    Assert-Equal 40 (Get-TimerNudge -Minutes 45 -Step -5)
    # С неровного значения первый щелчок притягивает к сетке, а не половинит шаг.
    Assert-Equal 50 (Get-TimerNudge -Minutes 47 -Step 5)
    Assert-Equal 45 (Get-TimerNudge -Minutes 47 -Step -5)
    Assert-Equal 5 (Get-TimerNudge -Minutes 5 -Step -5) 'no shorter than five minutes'
    Assert-Equal 720 (Get-TimerNudge -Minutes 720 -Step 5) 'no longer than twelve hours'
}

Test-Case 'timer target: says when it happens, and when that is tomorrow' {
    $now = [datetime]'2026-08-25 21:00:00'
    Assert-Equal 'at 22:30' (Get-TimerTargetText -Minutes 90 -Now $now)
    Assert-Equal 'at 00:30 tomorrow' (Get-TimerTargetText -Minutes 210 -Now $now)
    # Полночь ровно — уже завтра: «в 00:00» без пометки читалось бы как «сегодня».
    Assert-Equal 'at 00:00 tomorrow' (Get-TimerTargetText -Minutes 180 -Now $now)
}

Test-Case 'popup: opens above the cursor and stays on the screen' {
    # Значок в трее — правый нижний угол: окно обязано уйти вверх и влево, целиком.
    $p = Get-PopupPlacement -X 1900 -Y 1030 -Width 330 -Height 236 `
                            -Left 0 -Top 0 -Right 1920 -Bottom 1040
    Assert-Equal 1590 $p.X 'pushed back from the right edge'
    Assert-Equal 782 $p.Y 'above the cursor'

    # Панель задач сверху — идти вверх некуда, окно уходит вниз.
    $p = Get-PopupPlacement -X 900 -Y 60 -Width 330 -Height 236 `
                            -Left 0 -Top 48 -Right 1920 -Bottom 1080
    Assert-Equal 735 $p.X 'centred under the cursor'
    Assert-Equal 72 $p.Y 'below the cursor'
}

# --- окно таймера -----------------------------------------------------------
# Собирается без показа, как и окно настроек: обработчики поля и ползунка — это и
# есть вся работа окна, и они срабатывают от простого присваивания.

Write-Host ''
Write-Host 'the timer window' -ForegroundColor White

Test-Case 'timer window: opens on the value it was given' {
    $ui = New-TimerWindow -Action 'sleep' -Minutes 90
    try {
        Assert-Equal 90 $ui.Minutes 'the value it opened with'
        Assert-Equal '1 h 30 min' $ui.ValueBox.Text 'the field'
        Assert-Equal 90 (Get-TimerStepMinutes -Index ([int]$ui.Dial.Value)) 'the slider'
        Assert-True $ui.StartBtn.IsEnabled 'the button is ready'
        Assert-True ($ui.TargetText.Text -like 'at *') 'it says when that is'
    }
    finally { $ui.Window.Close(); $script:ActiveTimerUi = $null }
}

Test-Case 'timer window: typing moves the slider, the slider rewrites the field' {
    $ui = New-TimerWindow -Action 'shutdown' -Minutes 45
    try {
        $ui.ValueBox.Text = '1h30'
        Assert-Equal 90 $ui.Minutes 'what was typed'
        Assert-Equal '1h30' $ui.ValueBox.Text 'the text is left as typed'
        Assert-Equal 90 (Get-TimerStepMinutes -Index ([int]$ui.Dial.Value)) 'the slider followed'

        $ui.Dial.Value = Get-TimerStepIndex -Minutes 120
        Assert-Equal 120 $ui.Minutes 'what the slider says'
        Assert-Equal '2 h' $ui.ValueBox.Text 'and the field says the same'
    }
    finally { $ui.Window.Close(); $script:ActiveTimerUi = $null }
}

Test-Case 'timer window: the button hands the value back, Enter and Esc reach it' {
    $ui = New-TimerWindow -Action 'sleep' -Minutes 45
    try {
        # Клавиатурный уговор окна: Enter — на кнопку, Esc — на отмену. Проверяем
        # его на самих кнопках: нажатия в непоказанном окне взять негде.
        Assert-True $ui.StartBtn.IsDefault 'Enter goes to the button'
        Assert-True $ui.CancelBtn.IsCancel 'Esc cancels'

        $ui.ValueBox.Text = '2h'
        # Обработчик кнопки кладёт значение и закрывает окно. Закрыть непоказанное
        # окно нельзя (WPF отвечает отказом на DialogResult) — значение к этому
        # моменту уже отдано, и проверяем именно его.
        try { $ui.StartBtn.RaiseEvent(
                (New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        catch { }
        Assert-Equal 120 $ui.Result 'the minutes it hands back'
    }
    finally { $ui.Window.Close(); $script:ActiveTimerUi = $null }
}

Test-Case 'timer window: nothing is armed on what we cannot read' {
    $ui = New-TimerWindow -Action 'sleep' -Minutes 45
    try {
        $ui.ValueBox.Text = 'soon'
        Assert-Equal 0 $ui.Minutes 'no value'
        Assert-True (-not $ui.StartBtn.IsEnabled) 'the button is off'
        Assert-True ($ui.TargetText.Text -like '*1h30*') 'and it says what we do read'

        # Потолок — те же двенадцать часов, что и последняя ступень ползунка.
        $ui.ValueBox.Text = '20h'
        Assert-Equal 0 $ui.Minutes 'beyond the ceiling is not a value either'

        $ui.ValueBox.Text = '20'
        Assert-Equal 20 $ui.Minutes 'and it comes back to life'
        Assert-True $ui.StartBtn.IsEnabled 'with the button back on'
    }
    finally { $ui.Window.Close(); $script:ActiveTimerUi = $null }
}

# --- дневник ----------------------------------------------------------------

Write-Host ''
Write-Host 'the diary' -ForegroundColor White

function New-TestDiary {
    # Четыре дня подряд, по три занятия в день. Числа круглые нарочно: в отчёте
    # должны сойтись и проценты, и средние.
    $store = [ordered]@{ days = [ordered]@{} }
    foreach ($offset in 0..3) {
        # Ключ дня собираем той же функцией, что и код: на локали с другим
        # календарём ToString без культуры дал бы 2569 год, и отчёт искал бы дни,
        # которых в копилке нет (см. Format-DisplayStamp).
        $date = Format-DisplayStamp ([datetime]'2026-08-21').AddDays(-$offset) 'yyyy-MM-dd'
        $day = Get-ActivityDay -Store $store -Date $date
        Add-ActivitySpan -Day $day -Process 'chrome' -Display 'LG ULTRAGEAR' -Mode 'combo:Work' -Seconds 3600 -Time '09:00' -Hour 9
        Add-ActivitySpan -Day $day -Process 'Code' -Display 'LG ULTRAFINE' -Mode 'combo:Work' -Seconds 5400 -Time '13:00' -Hour 13
        Add-ActivitySpan -Day $day -Process 'cs2' -Display 'XG27AQDMGR' -Mode 'solo:XG27AQDMGR' -Seconds 1800 -Time '21:00' -Hour 21
        $day.switches = 7
        $day.longest = 4200
    }
    return $store
}

Test-Case 'diary: a span lands in every bucket at once' {
    $day = New-ActivityDay
    Add-ActivitySpan -Day $day -Process 'chrome' -Display 'LG ULTRAGEAR' -Mode 'all' -Seconds 60 -Time '10:15' -Hour 10
    Assert-Equal 60 $day.active 'time at the computer'
    Assert-Equal 60 $day.apps['chrome'] 'the app'
    Assert-Equal 60 $day.displays['LG ULTRAGEAR'] 'the display'
    Assert-Equal 60 $day.modes['all'] 'the mode'
    Assert-Equal 60 $day.pairs['chrome|LG ULTRAGEAR'] 'and the pair of app and display'
    Assert-Equal 60 $day.hours['10'] 'the hour of the day'
    Assert-Equal '10:15' $day.first 'when the day started'
}

Test-Case 'diary: spans add up, and the first time stays the first' {
    $day = New-ActivityDay
    Add-ActivitySpan -Day $day -Process 'chrome' -Display 'A' -Mode 'all' -Seconds 60 -Time '09:00' -Hour 9
    Add-ActivitySpan -Day $day -Process 'chrome' -Display 'A' -Mode 'all' -Seconds 30 -Time '17:40' -Hour 17
    Assert-Equal 90 $day.apps['chrome'] 'summed'
    Assert-Equal '09:00' $day.first 'the morning'
    Assert-Equal '17:40' $day.last 'and the evening'
}

Test-Case 'diary: an empty span changes nothing' {
    $day = New-ActivityDay
    Add-ActivitySpan -Day $day -Process 'chrome' -Display 'A' -Mode 'all' -Seconds 0 -Time '09:00' -Hour 9
    Assert-Equal 0 $day.active 'nothing counted'
    Assert-Equal '' $day.first 'and the day has not started'
}

Test-Case 'diary: a window on no known display still counts as time' {
    # Монитор мог быть выдернут между замером и обновлением кэша.
    $day = New-ActivityDay
    Add-ActivitySpan -Day $day -Process 'chrome' -Display '' -Mode 'all' -Seconds 60 -Hour 9
    Assert-Equal 60 $day.active 'the time is real'
    Assert-Equal 60 $day.apps['chrome'] 'and so is the app'
    Assert-Equal 0 $day.pairs.Count 'but there is no pair to record'
}

Test-Case 'diary: the report adds the days up' {
    $rep = Get-ActivityReport -Store (New-TestDiary) -Days 30 -Today ([datetime]'2026-08-21')
    Assert-Equal 4 $rep.DaysRecorded 'four days'
    Assert-Equal 43200 $rep.Active 'twelve hours in total'
    Assert-Equal 10800 $rep.AverageDay 'three hours a day'
    Assert-Equal 28 $rep.Switches 'seven switches a day'
    Assert-Equal 4200 $rep.Longest 'the longest session of any day'
    Assert-Equal '2026-08-18' $rep.From 'from'
    Assert-Equal '2026-08-21' $rep.To 'to'
}

Test-Case 'diary: shares are of the time at the computer' {
    $rep = Get-ActivityReport -Store (New-TestDiary) -Days 30 -Today ([datetime]'2026-08-21')
    Assert-Equal 'Code' $rep.Apps[0].Name 'the app with the most time first'
    Assert-Equal 50 $rep.Apps[0].Share 'half the time'
    Assert-Equal 'LG ULTRAFINE' $rep.Displays[0].Name 'and the display with the most time'
}

Test-Case 'diary: the busiest hour is the tallest bar, and all 24 are there' {
    $rep = Get-ActivityReport -Store (New-TestDiary) -Days 30 -Today ([datetime]'2026-08-21')
    Assert-Equal 24 @($rep.Hours).Count 'a bar for every hour, empty ones included'
    Assert-Equal 13 $rep.BusiestHour 'the afternoon'
    Assert-Equal 100 (@($rep.Hours | Where-Object { $_.Name -eq '13' })[0].Share) 'the tallest bar is full height'
}

Test-Case 'diary: the usual day is the average of its ends' {
    $rep = Get-ActivityReport -Store (New-TestDiary) -Days 30 -Today ([datetime]'2026-08-21')
    Assert-Equal '09:00' $rep.AverageStart 'sat down'
    Assert-Equal '21:00' $rep.AverageEnd 'got up'
}

Test-Case 'diary: days in a row stop at the first gap' {
    $today = [datetime]'2026-08-21'
    Assert-Equal 4 (Get-ActivityStreak -Dates @('2026-08-18', '2026-08-19', '2026-08-20', '2026-08-21') -Today $today) 'four in a row'
    Assert-Equal 2 (Get-ActivityStreak -Dates @('2026-08-18', '2026-08-20', '2026-08-21') -Today $today) 'a missed day ends the streak'
    Assert-Equal 0 (Get-ActivityStreak -Dates @('2026-08-19') -Today $today) 'nothing today means no streak at all'
}

Test-Case 'diary: only the asked-for days are counted' {
    $rep = Get-ActivityReport -Store (New-TestDiary) -Days 2 -Today ([datetime]'2026-08-21')
    Assert-Equal 2 $rep.DaysRecorded 'two days'
    Assert-Equal 21600 $rep.Active 'and their time only'
}

Test-Case 'diary: an empty diary reads as empty, not as a crash' {
    $rep = Get-ActivityReport -Store ([ordered]@{ days = [ordered]@{} }) -Days 30
    Assert-Equal 0 $rep.DaysRecorded 'nothing recorded'
    Assert-Equal 0 $rep.Active 'no time'
    $lines = @(Format-ActivityReport -Report $rep)
    Assert-Equal 1 $lines.Count 'one line of explanation'
    Assert-True ($lines[0] -like '*Nothing in the diary yet*') 'and it says why'
    # Совета «включите дневник» здесь быть не должно: с включённым дневником он
    # был бы неправдой, а знает об этом только вызывающий.
    Assert-Equal $false ($lines[0] -like '*Turn stats on*') 'and does not advise what it cannot know'
}

Test-Case 'diary: the report reads like a report' {
    $text = (Format-ActivityReport -Report (Get-ActivityReport -Store (New-TestDiary) -Days 30 -Today ([datetime]'2026-08-21'))) -join "`n"
    Assert-True ($text -like '*at the computer*12 h 00 min*') 'the total'
    Assert-True ($text -like '*Code*6 h 00 min*') 'the top app with its time'
    Assert-True ($text -like '*chrome on LG ULTRAGEAR*') 'and which display it was on'
}

Test-Case 'diary: time reads as hours and minutes' {
    Assert-Equal '-' (Format-ActivitySpan 0)
    Assert-Equal '30 min' (Format-ActivitySpan 1800)
    Assert-Equal '2 h 00 min' (Format-ActivitySpan 7200)
    Assert-Equal '1 h 01 min' (Format-ActivitySpan 3660)
}

Test-Case 'diary: what is written is what comes back' {
    $script:ActivityFile = Join-Path $script:TestDir 'activity.json'
    $script:ActivityStore = New-TestDiary
    $script:ActivityDirty = $true
    Save-ActivityStore
    $script:ActivityStore = $null
    $back = Get-ActivityStore
    Assert-Equal 4 @($back.days.Keys).Count 'four days came back'
    $rep = Get-ActivityReport -Store $back -Days 30 -Today ([datetime]'2026-08-21')
    Assert-Equal 43200 $rep.Active 'with their time'
    Assert-Equal 28 $rep.Switches 'and their switches'
    Assert-Equal 'Code' $rep.Apps[0].Name 'and their apps'
}

Test-Case 'diary: a damaged file is a new diary, not a crash' {
    $script:ActivityFile = Join-Path $script:TestDir 'activity-bad.json'
    'not json at all' | Set-Content -Path $script:ActivityFile -Encoding UTF8
    $script:ActivityStore = $null
    $store = Get-ActivityStore
    Assert-Equal 0 @($store.days.Keys).Count 'empty and working'
}

Test-Case 'diary: a day written by an older version reads without its missing parts' {
    $raw = '{"active":600,"apps":{"chrome":600}}' | ConvertFrom-Json
    $day = ConvertTo-ActivityDay $raw
    Assert-Equal 600 $day.active 'what was there'
    Assert-Equal 600 $day.apps['chrome'] 'and what it held'
    Assert-Equal 0 $day.pairs.Count 'what was not there is empty, not missing'
    Assert-Equal 0 $day.switches 'and numbers are zero'
}

Test-Case 'diary: the page cannot be broken by a monitor name' {
    # Название монитора приходит из EDID, а туда производитель пишет что угодно.
    $store = [ordered]@{ days = [ordered]@{} }
    $day = Get-ActivityDay -Store $store -Date '2026-08-21'
    Add-ActivitySpan -Day $day -Process 'chrome' -Display '<script>bad</script>' -Mode 'all' -Seconds 60 -Hour 9
    $html = New-ActivityHtml -Report (Get-ActivityReport -Store $store -Days 30 -Today ([datetime]'2026-08-21'))
    Assert-True ($html -like '*&lt;script&gt;bad&lt;/script&gt;*') 'escaped'
    Assert-Equal $false ($html -like '*<script>bad*') 'and not left as markup'
}

Test-Case 'diary: the page holds the numbers and calls nobody' {
    $html = New-ActivityHtml -Report (Get-ActivityReport -Store (New-TestDiary) -Days 30 -Today ([datetime]'2026-08-21'))
    Assert-True ($html -like '*12 h 00 min*') 'the total is there'
    Assert-True ($html -like '*LG ULTRAFINE*') 'and the displays'
    # Обещание проекта: ничего не устанавливается и никто не зовётся в гости.
    Assert-Equal $false ($html -like '*http://*') 'no outside links'
    Assert-Equal $false ($html -like '*https://*') 'none at all'
    # Проценты в CSS — только с точкой. «width:12,5%» браузер выбрасывает целиком,
    # и полоски становятся нулевыми, а гистограмма плоской: на русской локали
    # отчёт был бы пустой картинкой (см. Format-ActivityPercent). Дробные доли в
    # копилке заведены нарочно — иначе проверять было бы нечего.
    Assert-True ($html -like '*width:33.3%*') 'a fractional share keeps its decimal point'
    Assert-Equal $false ($html -match '(width|height):[0-9]+,') 'and no locale comma anywhere in the CSS'
}

# --- окно настроек: новое ---------------------------------------------------

Write-Host ''
Write-Host 'the settings window, the new parts' -ForegroundColor White

Test-Case 'dialog: the diary toggle goes both ways' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal $false ([bool]$ui.StatsBox.IsChecked) 'off, as it is in the settings'
        $ui.StatsBox.IsChecked = $true
        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-True $got.Settings.stats 'turning it on is saved'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: commands and levels survive a save like everything else' {
    $settings = Get-DefaultSettings
    $settings.hooks['all'] = [ordered]@{ before = ''; after = 'notepad.exe' }
    $settings.brightness['all'] = 80
    $settings.contrast['all'] = 70
    $settings.rules = @([ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'all'; back = ''; enabled = $true })
    $settings.reapply.onPlug = 'all'
    $ui = New-DialogUi -Settings $settings
    try {
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'notepad.exe' $updated.hooks['all'].after 'the command'
        Assert-Equal 80 $updated.brightness['all'] 'the brightness'
        Assert-Equal 70 $updated.contrast['all'] 'the contrast'
        Assert-Equal 'cs2' $updated.rules[0].process 'the rule'
        Assert-Equal 'all' $updated.reapply.onPlug 'and what to do when a display appears'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: renaming a combination carries its command and brightness' {
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.hooks['combo:Work'] = [ordered]@{ before = ''; after = 'x.cmd' }
    $settings.brightness['combo:Work'] = 55
    $ui = New-DialogUi -Settings $settings
    try {
        # Через редактор режима, как в живом окне: команда переезжает на Save по
        # карте переименований, а яркость — сразу, вместе с правкой.
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Office'; Patterns = @('LG ULTRAGEAR'); Primary = ''
            Level = $ui.Levels['combo:Work'] })
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-True ($updated.hooks.Contains('combo:Office')) 'the command followed the new name'
        Assert-Equal $false ($updated.hooks.Contains('combo:Work')) 'and left no ghost behind'
        Assert-Equal 55 $updated.brightness['combo:Office'] 'so did the brightness'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: removing a combination takes its command and brightness along' {
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.hooks['combo:Work'] = [ordered]@{ before = ''; after = 'x.cmd' }
    $settings.brightness['combo:Work'] = 55
    $ui = New-DialogUi -Settings $settings
    try {
        Remove-UiCombo -Ui $ui -Combo $ui.Combos[0]
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ($updated.hooks.Contains('combo:Work')) 'no command left for a mode that is gone'
        Assert-Equal $false ($updated.brightness.Contains('combo:Work')) 'and no brightness either'
    }
    finally { $ui.Window.Close() }
}

# Сам переезд ключей — чистыми функциями, отдельно от окна: их три штуки на
# четыре настройки, и проверять их через сборку WPF-дерева дороже и мутнее.

Test-Case 'mode keys: a rename moves the entry and keeps the file order' {
    $renames = Get-ComboRenames -Combos @(
        [pscustomobject]@{ Name = 'Office'; OriginalName = 'Work' }
        [pscustomobject]@{ Name = 'Movie night'; OriginalName = 'Movie night' }
    )
    Assert-Equal @('combo:Work') @($renames.Keys) 'only the renamed one is in the map'

    $source = [ordered]@{ 'solo:A' = 10; 'combo:Work' = 80; 'all' = 55 }
    $moved = Move-ModeKeyedEntries -Source $source -Renames $renames
    Assert-Equal @('solo:A', 'combo:Office', 'all') @($moved.Keys) 'moved in place, order untouched'
    Assert-Equal 80 $moved['combo:Office'] 'with its value'
}

Test-Case 'mode keys: a removed combination takes its entry with it' {
    $source = [ordered]@{ 'combo:Work' = 80; 'all' = 55 }
    $moved = Move-ModeKeyedEntries -Source $source -Renames @{} -Gone @('combo:Work')
    Assert-Equal @('all') @($moved.Keys) 'the ghost setting is gone'
}

Test-Case 'mode keys: an occupied new key keeps its own value' {
    # Своё значение у занятого ключа важнее переезжающего: молча выбросить одно из
    # двух хуже, чем оставить то, что уже там.
    $renames = Get-ComboRenames -Combos @([pscustomobject]@{ Name = 'B'; OriginalName = 'A' })
    $moved = Move-ModeKeyedEntries -Source ([ordered]@{ 'combo:A' = 1; 'combo:B' = 2 }) -Renames $renames
    Assert-Equal 2 $moved['combo:B'] 'the value that was already there'
    Assert-True (-not $moved.Contains('combo:A')) 'and the old key is gone either way'
}

Test-Case 'mode keys: a chain of renames is applied in the order of the list' {
    # «A» переименовали в «B», а «B» — в «C». Порядок применения тут значим,
    # поэтому словарь переименований упорядоченный, а не хэш-таблица.
    $renames = Get-ComboRenames -Combos @(
        [pscustomobject]@{ Name = 'C'; OriginalName = 'B' }
        [pscustomobject]@{ Name = 'B'; OriginalName = 'A' }
    )
    $moved = Move-ModeKeyedEntries -Source ([ordered]@{ 'combo:A' = 1; 'combo:B' = 2 }) -Renames $renames
    Assert-Equal 2 $moved['combo:C'] 'B moved on to C first'
    Assert-Equal 1 $moved['combo:B'] 'and only then A took the freed name'
}

Test-Case 'mode keys: a rule whose mode is gone is dropped, a way back is only cleared' {
    $rules = @(
        [ordered]@{ when = 'process'; process = 'cs2'; mode = 'combo:Work'; back = ''; enabled = $true }
        [ordered]@{ when = 'idle'; minutes = 20; mode = 'all'; back = 'combo:Work'; enabled = $true }
    )
    $left = @(Move-RuleModeKeys -Rules $rules -Renames @{} -Gone @('combo:Work'))
    Assert-Equal 1 $left.Count 'the rule with nowhere to go is dropped'
    Assert-Equal 'all' ([string]$left[0].mode) 'the other one stays'
    Assert-Equal '' ([string]$left[0].back) 'with an empty way back - that is legal'
}

Test-Case 'mode keys: rules survive as objects, not just dictionaries' {
    # Из ConvertFrom-Json правила приезжают PSCustomObject'ами.
    $rules = @([pscustomobject]@{ when = 'process'; process = 'cs2'; mode = 'combo:Work'; back = 'all' })
    $renames = Get-ComboRenames -Combos @([pscustomobject]@{ Name = 'Office'; OriginalName = 'Work' })
    $left = @(Move-RuleModeKeys -Rules $rules -Renames $renames)
    Assert-Equal 1 $left.Count 'kept'
    Assert-Equal 'combo:Office' ([string]$left[0].mode) 'and renamed'
    Assert-Equal 'cs2' ([string]$left[0].process) 'the rest of the rule came along'
}

# Правила и «монитор появился» держат те же ключи режимов, и переименование в
# окне обязано доехать и до них. Иначе правило каждые пятнадцать секунд уходило
# бы в режим, которого больше нет, а переключение отвечало бы «combination no
# longer exists» — то же место, из-за которого этот переезд делает и
# Update-HotkeyKeys.

Test-Case 'dialog: renaming a combination carries its rules along' {
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.rules = @(
        [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'combo:Work'; back = ''; enabled = $true }
        [ordered]@{ when = 'idle'; process = ''; minutes = 20; mode = 'all'; back = 'combo:Work'; enabled = $true }
    )
    $settings.reapply.onPlug = 'combo:Work'
    $ui = New-DialogUi -Settings $settings
    try {
        $ui.Combos[0].Name = 'Office'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 2 @($updated.rules).Count 'both rules are still there'
        Assert-Equal 'combo:Office' ([string]$updated.rules[0].mode) 'the rule follows the new name'
        Assert-Equal 'combo:Office' ([string]$updated.rules[1].back) 'and so does the way back'
        Assert-Equal 'combo:Office' ([string]$updated.reapply.onPlug) 'and "when a display appears"'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: removing a combination takes its rules along' {
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.rules = @(
        [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'combo:Work'; back = ''; enabled = $true }
        [ordered]@{ when = 'idle'; process = ''; minutes = 20; mode = 'all'; back = 'combo:Work'; enabled = $true }
    )
    $settings.reapply.onPlug = 'combo:Work'
    $ui = New-DialogUi -Settings $settings
    try {
        Remove-UiCombo -Ui $ui -Combo $ui.Combos[0]
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        # Первое правило уходить некуда — оно больше не правило. Второму пропал
        # только возврат, и пустой возврат законен: «туда, где стол был до».
        Assert-Equal 1 @($updated.rules).Count 'the rule with nowhere to go is gone'
        Assert-Equal 'all' ([string]$updated.rules[0].mode) 'the other one stayed'
        Assert-Equal '' ([string]$updated.rules[0].back) 'without its way back'
        Assert-Equal '' ([string]$updated.reapply.onPlug) 'and nothing to do when a display appears'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a save leaves the rules the tray is living with alone' {
    # $updated — копия: неудачная запись на диск не должна оставлять три разные
    # версии настроек (в памяти, на диске и в зарегистрированных клавишах).
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.rules = @([ordered]@{ when = 'process'; process = 'cs2'; minutes = 0; mode = 'combo:Work'; back = ''; enabled = $true })
    $ui = New-DialogUi -Settings $settings
    try {
        $ui.Combos[0].Name = 'Office'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'combo:Office' ([string]$updated.rules[0].mode) 'the copy moved'
        Assert-Equal 'combo:Work' ([string]$settings.rules[0].mode) 'the original did not'
    }
    finally { $ui.Window.Close() }
}

# --- предпросмотр стола -----------------------------------------------------
# Картинка считается той же функцией, которой считает переключатель
# (Get-LayoutPositions), поэтому проверять надо ровно одно: что в неё попадает.

Write-Host ''
Write-Host 'the desk preview' -ForegroundColor White

Test-Case 'preview: pixel sizes come from the cards' {
    $cards = @(
        [pscustomobject]@{ Label = 'LG ULTRAFINE'; Width = 3840; Height = 2160; Connected = $true; Primary = $false }
        [pscustomobject]@{ Label = 'LG ULTRAGEAR'; Width = 2560; Height = 1440; Connected = $true; Primary = $true }
    )
    $screens = @(ConvertTo-PreviewScreens -Cards $cards)
    Assert-Equal 2 $screens.Count 'both'
    Assert-Equal 3840 $screens[0].Width 'the 4K panel'
    Assert-Equal 1440 $screens[1].Height 'and the 1440p one'
    Assert-True $screens[1].Primary 'the taskbar star came through'
}

Test-Case 'preview: a display of unknown size still takes its place in the row' {
    # Карточка-памятка от выдернутого монитора: размера у неё нет, но место в
    # ряду она занимает — иначе предпросмотр показывал бы не тот стол.
    $cards = @([pscustomobject]@{ Label = 'XG27AQDMGR'; Width = 0; Height = 0; Connected = $false; Primary = $false })
    $screens = @(ConvertTo-PreviewScreens -Cards $cards)
    Assert-Equal 1 $screens.Count 'still there'
    Assert-Equal 1920 $screens[0].Width 'a plain 16:9 stands in'
    Assert-Equal 1080 $screens[0].Height 'both ways'
}

Test-Case 'preview: what it draws is what the switcher will do' {
    # Экраны разной высоты выравниваются по центру, и именно это должно быть
    # видно на картинке: 2160 и 1440 дают отступ (2160-1440)/2 = 360.
    $cards = @(
        [pscustomobject]@{ Label = 'LG ULTRAFINE'; Width = 3840; Height = 2160; Connected = $true; Primary = $true }
        [pscustomobject]@{ Label = 'LG ULTRAGEAR'; Width = 2560; Height = 1440; Connected = $true; Primary = $false }
    )
    $pos = Get-PreviewPlacement -Screens @(ConvertTo-PreviewScreens -Cards $cards)
    Assert-Equal 0 $pos['preview-0'].X 'the first sits at zero'
    Assert-Equal 3840 $pos['preview-1'].X 'the second right after it'
    Assert-Equal 360 $pos['preview-1'].Y 'and lower by half the difference in height'
}

Test-Case 'preview: the cards decide the order, not the alphabet' {
    # Регрессия: с пустым Order у всех экранов одинаковый ранг, и раскладка
    # сортировалась по названию. Картинка показывала ULTRAFINE, ULTRAGEAR,
    # XG27AQDMGR, а карточки стояли ULTRAFINE, XG27AQDMGR, ULTRAGEAR — то есть
    # предпросмотр обещал не тот стол, который получится.
    $cards = @(
        [pscustomobject]@{ Label = 'LG ULTRAFINE'; Width = 3840; Height = 2160; Connected = $true; Primary = $false }
        [pscustomobject]@{ Label = 'XG27AQDMGR';   Width = 2560; Height = 1440; Connected = $true; Primary = $true }
        [pscustomobject]@{ Label = 'LG ULTRAGEAR'; Width = 2560; Height = 1440; Connected = $true; Primary = $false }
    )
    $pos = Get-PreviewPlacement -Screens @(ConvertTo-PreviewScreens -Cards $cards)
    Assert-True ($pos['preview-0'].X -lt $pos['preview-1'].X) 'the first card is left of the second'
    Assert-True ($pos['preview-1'].X -lt $pos['preview-2'].X) 'and the second is left of the third'
}

Test-Case 'preview: the taskbar display is where the coordinates start' {
    # Основным Windows делает того, чей левый верхний угол лежит в (0,0) — и
    # картинка обязана показывать это так же, иначе она рисует чужую раскладку.
    $cards = @(
        [pscustomobject]@{ Label = 'LG ULTRAFINE'; Width = 3840; Height = 2160; Connected = $true; Primary = $false }
        [pscustomobject]@{ Label = 'LG ULTRAGEAR'; Width = 2560; Height = 1440; Connected = $true; Primary = $true }
    )
    $pos = Get-PreviewPlacement -Screens @(ConvertTo-PreviewScreens -Cards $cards)
    Assert-Equal 0 $pos['preview-1'].X 'the taskbar display sits at zero'
    Assert-Equal 0 $pos['preview-1'].Y 'both ways'
    Assert-Equal -3840 $pos['preview-0'].X 'and the other one is to the left of it'
}

# --- карточка яркости -------------------------------------------------------
# Две формы записи (число и словарь) окно обязано уметь и НЕ превращать одну в
# другую само: развернув число по мониторам, которые сейчас на столе, оно
# потеряло бы яркость выдернутого и изменило бы смысл «all» для монитора,
# который появится завтра.

Write-Host ''
Write-Host 'the brightness card' -ForegroundColor White

Test-Case 'level model: nothing set reads as "leave it alone"' {
    $m = ConvertTo-LevelModel $null
    Assert-Equal 'none' $m.Kind 'nothing to do'
    Assert-Null (ConvertFrom-LevelModel $m) 'and nothing is written back'
}

Test-Case 'level model: a number is one level for the whole mode' {
    $m = ConvertTo-LevelModel 80
    Assert-Equal 'one' $m.Kind 'one level'
    Assert-Equal 80 $m.Value 'as written'
    Assert-Equal 80 (ConvertFrom-LevelModel $m) 'and it goes back as a number, not as a dictionary'
}

Test-Case 'level model: a dictionary is a level for each display' {
    $m = ConvertTo-LevelModel ([ordered]@{ 'ULTRAFINE' = 25; 'XG27' = 40 })
    Assert-Equal 'each' $m.Kind 'each display'
    Assert-Equal 25 $m.Map['ULTRAFINE'] 'the first'
    Assert-Equal 40 $m.Map['XG27'] 'the second'
    $back = ConvertFrom-LevelModel $m
    Assert-Equal 25 $back['ULTRAFINE'] 'and it comes back the same way'
    Assert-Equal @('ULTRAFINE', 'XG27') @($back.Keys) 'in the same order'
}

Test-Case 'level model: numbers outside 0..100 are clamped on the way in' {
    Assert-Equal 100 (ConvertTo-LevelModel 500).Value 'above'
    Assert-Equal 0 (ConvertTo-LevelModel -7).Value 'below'
    Assert-Equal 100 (ConvertTo-LevelModel ([ordered]@{ 'A' = 900 })).Map['A'] 'in a dictionary too'
}

Test-Case 'level model: junk is not a setting' {
    $m = ConvertTo-LevelModel 'bright'
    Assert-Equal 'none' $m.Kind 'unreadable means nothing set'
    Assert-Equal 'none' (ConvertTo-LevelModel ([ordered]@{})).Kind 'an empty dictionary is nothing set'
}

Test-Case 'level model: an empty per-display map writes no key at all' {
    $m = ConvertTo-LevelModel ([ordered]@{ 'A' = 50 })
    $m.Map.Remove('A')
    Assert-Null (ConvertFrom-LevelModel $m) 'unticking the last display removes the setting'
}

Test-Case 'level settings: modes without brightness stay out of the file' {
    $levels = [ordered]@{
        'all'        = (ConvertTo-LevelModel 80)
        'combo:Work' = (ConvertTo-LevelModel $null)
    }
    $out = ConvertTo-BrightnessSettings -Levels $levels
    Assert-Equal 1 $out.Count 'only the one that has a level'
    Assert-Equal 80 $out['all'] 'and it is the number as written'
}

Test-Case 'level rows: "all displays" lists what is connected' {
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
    try {
        Assert-Equal @('LG ULTRAGEAR', 'LG ULTRAFINE') @(Get-EditorDisplayNames -Editor $ed) 'both connected displays'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'level rows: a combination lists its displays by their real names' {
    # В файле шаблон, а в строке должно стоять полное название монитора: обе
    # записи совпадают, но точнее — то, что видит человек.
    $combo = [pscustomobject]@{ Name = 'Work'; Patterns = @('ULTRAFINE'); Primary = ''; OriginalName = 'Work' }
    $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $script:DlgState -Dark $false
    try {
        Assert-Equal @('LG ULTRAFINE') @(Get-EditorDisplayNames -Editor $ed) 'resolved to the display name'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'level rows: a display mode names the display, not its key' {
    # У двух одинаковых моделей в ключе стоит короткий ID («solo:DELL U2723 ABC123»),
    # и разбор ключа дал бы строку ползунка с именем, которого нет ни на одном
    # мониторе. Состав режима знает Get-ModeMembers — он и отвечает.
    $state = @(
        (New-FakeMonitor 'DELL U2723' 'ABC123' 'path-1')
        (New-FakeMonitor 'DELL U2723' 'ABC124' 'path-2')
    )
    $mode = @(Get-DisplayModes -State $state | Where-Object { $_.Id -eq 'path-1' })[0]
    Assert-Equal 'solo:DELL U2723 ABC123' ([string]$mode.Key) 'the key carries the short id, as it must'
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $state -Dark $false
    try {
        Assert-Equal @('DELL U2723') @(Get-EditorDisplayNames -Editor $ed) 'but the row is named after the display'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'level rows: a level for a display that is gone is still shown' {
    # Иначе такую настройку нельзя ни увидеть, ни снять — тем же правилом живут
    # привязки клавиш к отсутствующим мониторам.
    $names = @(Get-LevelRowNames -Displays @('LG ULTRAGEAR') -Map ([ordered]@{ 'XG27AQDMGR' = 40 }))
    Assert-True ($names -contains 'XG27AQDMGR') 'the orphan row is there'
    Assert-True ($names -contains 'LG ULTRAGEAR') 'next to the display that is here'
}

Test-Case 'mode editor: brightness is offered for every kind of mode' {
    # Яркость живёт в редакторе режима — и обязана быть в редакторе любого режима,
    # не только комбинации.
    foreach ($mode in @(
        [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
        [pscustomobject]@{ Key = 'solo:LG ULTRAGEAR'; Title = 'Only LG ULTRAGEAR'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
    )) {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
        try {
            Assert-Equal 3 $ed.LevelKindBox.Items.Count "leave alone / one level / each display for $($mode.Key)"
            Assert-Equal 'none' ([string]$ed.Level.Kind) 'nothing set until asked'
        }
        finally { $ed.Window.Close() }
    }
}

Test-Case 'mode editor: a display mode has no name, members or taskbar to argue about' {
    $mode = [pscustomobject]@{ Key = 'solo:LG ULTRAGEAR'; Title = 'Only LG ULTRAGEAR'; Kind = 'solo'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
    try {
        Assert-Equal 'Collapsed' ([string]$ed.Window.FindName('ComboPart').Visibility) 'the combination part is out of the way'
        Assert-Equal 'Only LG ULTRAGEAR' ([string]$ed.Window.FindName('HeadTitle').Text) 'the mode names itself'
        # Пустое имя у комбинации — отказ; у режима монитора имени нет вовсе, и
        # Save обязан пройти.
        $got = Read-ModeFromUi -Editor $ed
        Assert-True $got.Ok 'saving asks nothing of it'
        Assert-Null $got.Mode.PSObject.Properties['Name'] 'and it carries no name back'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: a brightness set for a mode that no longer exists gets its own row' {
    $settings = Get-DefaultSettings
    $settings.brightness['solo:GONE MONITOR'] = 55
    $ui = New-DialogUi -Settings $settings
    try {
        # Два монитора, «все» и строка-сирота: увидеть и снять настройку можно
        # только отсюда.
        Assert-Equal 4 $ui.ModesPanel.Children.Count 'the setting without a mode is listed'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 55 $updated.brightness['solo:GONE MONITOR'] 'and untouched by a plain Save'

        # Remove у такой строки снимает именно её.
        Remove-UiOrphan -Ui $ui -Key 'solo:GONE MONITOR'
        Assert-Equal 3 $ui.ModesPanel.Children.Count 'the row went away'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ($updated.brightness.Contains('solo:GONE MONITOR')) 'and so did the setting'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a hand-written number survives a Save untouched' {
    # Регрессия, которую здесь и стерегут: разворачивать число в словарь по
    # текущим мониторам нельзя — «all: 80» относится и к тому монитору, который
    # воткнут не сейчас.
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = 80
    $ui = New-DialogUi -Settings $settings
    try {
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 80 $updated.brightness['all'] 'still a number'
        Assert-Equal $false ($updated.brightness['all'] -is [System.Collections.IDictionary]) 'and not a dictionary'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: moving the one-level slider is what gets saved' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Dark $false
        try {
            # Как это делает человек: выбрать форму, подвинуть ползунок, Save.
            $ed.LevelKindBox.SelectedIndex = 1
            $ed.LevelOneSlider.Value = 35
            Assert-Equal 'Visible' ([string]$ed.LevelOnePanel.Visibility) 'the slider showed up'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 35 $updated.brightness['all'] 'the level landed in the settings'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: Cancel leaves the brightness the window already had' {
    # Редактор правит КОПИЮ модели: иначе «подвигал и передумал» уже изменило бы
    # настройку, и Cancel врал бы.
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = 70
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Levels $ui.Levels -Dark $false
        try {
            $ed.LevelOneSlider.Value = 20
            Assert-Equal 20 ([int]$ed.Level.Value) 'the editor moved'
        }
        finally { $ed.Window.Close() }
        # Ответ редактора не применяли — окно обязано остаться при своих.
        Assert-Equal 70 ([int]$ui.Levels['all'].Value) 'the window did not'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: unticking every display removes the setting instead of writing zeros' {
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = [ordered]@{ 'LG ULTRAGEAR' = 60 }
    $ui = New-DialogUi -Settings $settings
    try {
        $ui.Levels['all'].Map.Remove('LG ULTRAGEAR')
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ($updated.brightness.Contains('all')) 'the key is gone, not zeroed'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: switching to per-display seeds it from the level it had' {
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = 70
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Levels $ui.Levels -Dark $false
        try {
            Assert-Equal 'one' ([string]$ed.Level.Kind) 'started as one level'
            # Человек видел 70 и должен править от семидесяти, а не от пустого списка.
            $ed.LevelKindBox.SelectedIndex = 2
            $got = Read-ModeFromUi -Editor $ed
            Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 70 $updated.brightness['all']['LG ULTRAGEAR'] 'seeded with what was shown'
        Assert-Equal 70 $updated.brightness['all']['LG ULTRAFINE'] 'for every display of the mode'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: the per-display rows are really built' {
    # Тест на построение, а не на модель: первая версия строк звала
    # [GridLength]::Parse, которого не существует, и переход на «каждому своё»
    # падал в живом окне. Модель при этом была в полном порядке — поймал снимок
    # окна, а не тест, поэтому теперь строки строятся здесь.
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = [ordered]@{ 'LG ULTRAGEAR' = 60; 'LG ULTRAFINE' = 25 }
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Levels $ui.Levels -Dark $false
        try {
            Assert-Equal 'Collapsed' ([string]$ed.LevelOnePanel.Visibility) 'the single slider is out of the way'
            Assert-Equal 2 $ed.LevelRowsPanel.Children.Count 'a row per display'
            # Первый столбец строки — галочка «задано», она же подписана названием.
            $first = $ed.LevelRowsPanel.Children[0]
            Assert-Equal 'LG ULTRAGEAR' ([string]$first.Children[0].Content) 'named after the display'
            Assert-True ([bool]$first.Children[0].IsChecked) 'ticked, because a level is set'
            Assert-Equal 60 ([int]$first.Children[1].Value) 'and the slider stands where the setting says'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: a display with no level gets an unticked, disabled row' {
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = [ordered]@{ 'LG ULTRAGEAR' = 60 }
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Levels $ui.Levels -Dark $false
        try {
            $rows = @($ed.LevelRowsPanel.Children)
            $off = @($rows | Where-Object { [string]$_.Children[0].Content -eq 'LG ULTRAFINE' })
            Assert-Equal 1 $off.Count 'the display without a level still has a row'
            Assert-Equal $false ([bool]$off[0].Children[0].IsChecked) 'unticked'
            Assert-Equal $false ([bool]$off[0].Children[1].IsEnabled) 'and its slider is out of action'
            Assert-Equal 'off' ([string]$off[0].Children[2].Text) 'and it says off, not zero'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: unticking a display drops its brightness row with it' {
    # Иначе под комбинацией остался бы ползунок монитора, которого в ней уже нет.
    $combo = [pscustomobject]@{ Name = 'Work'; Patterns = @('LG ULTRAGEAR', 'LG ULTRAFINE'); Primary = ''; OriginalName = 'Work' }
    $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
    $level = ConvertTo-LevelModel ([ordered]@{ 'LG ULTRAGEAR' = 60; 'LG ULTRAFINE' = 25 })
    $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $script:DlgState `
                               -Levels ([ordered]@{ 'combo:Work' = $level }) -Dark $false
    try {
        Assert-Equal 2 $ed.LevelRowsPanel.Children.Count 'both displays have a row'
        $uf = @($ed.Checks | Where-Object { [string]$_.Tag -eq 'LG ULTRAFINE' })[0]
        $uf.IsChecked = $false
        $uf.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        $names = @($ed.LevelRowsPanel.Children | ForEach-Object { [string]$_.Children[0].Content })
        # Строка остаётся, но уже как сирота: значение задано, и снять его можно
        # только видя его.
        Assert-True ($names -contains 'LG ULTRAGEAR') 'the display that stayed keeps its row'
        $got = Read-ModeFromUi -Editor $ed
        Assert-Equal @('LG ULTRAGEAR') @($got.Mode.Patterns) 'and the combination lost the display'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: renaming a combination carries the sliders too' {
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.brightness['combo:Work'] = 45
    $ui = New-DialogUi -Settings $settings
    try {
        # Через ту же дверь, что и живое окно: имя меняет редактор режима, а не
        # рука в списке комбинаций.
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Office'; Patterns = @('LG ULTRAGEAR'); Primary = ''
            Level = $ui.Levels['combo:Work'] })
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 45 $updated.brightness['combo:Office'] 'followed the new name'
        Assert-Equal $false ($updated.brightness.Contains('combo:Work')) 'and left no ghost'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a new combination taking a freed name keeps its own brightness' {
    # Яркость Set-UiMode перекладывает на новый ключ сразу, поэтому на Save её
    # переименовывать НЕ надо: иначе новая комбинация, занявшая освободившееся
    # имя, совпадает с источником переименования и молча теряет свою яркость.
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.brightness['combo:Work'] = 30
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Play'; Patterns = @('LG ULTRAGEAR'); Primary = ''
            Level = $ui.Levels['combo:Work'] })
        # И тут же заводим новую «Work» — имя освободилось.
        Set-UiMode -Ui $ui -Mode $null -Combo $null -Edited ([pscustomobject]@{
            Name = 'Work'; Patterns = @('LG ULTRAFINE'); Primary = ''
            Level = [pscustomobject]@{ Kind = 'one'; Value = 70; Map = [ordered]@{} } })

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 30 $updated.brightness['combo:Play'] 'the renamed one kept its level'
        Assert-Equal 70 $updated.brightness['combo:Work'] 'and the new one kept its own'
    }
    finally { $ui.Window.Close() }
}

# --- имя комбинации — это её ключ -------------------------------------------
# Комбинацию можно стереть из файла рукой, а её клавишу, яркость, звук и команды
# оставить: они лежат под ключом `combo:<имя>`, и окно показывает их строкой-
# сиротой. Завести комбинацию с тем же именем — значит занять тот самый ключ.
# Звук и команды достаются ей в любом случае, поэтому клавиша с яркостью обязаны
# и достаться, и БЫТЬ ВИДНЫ: пустые поля редактора молча стирали две настройки из
# четырёх, а сохранённая клавиша сироты вдобавок считалась чужой.

Write-Host ''
Write-Host 'a name that was already used once' -ForegroundColor White

# Настройки-сироты: комбинации Movie нет, а всё, что к ней было привязано, есть.
function New-OrphanSettings {
    $s = Get-DefaultSettings
    $s.brightness['combo:Movie'] = 55
    $s.hotkeys['combo:Movie'] = 'Ctrl+Alt+F4'
    $s.audio['combo:Movie'] = 'ROG'
    return $s
}

Test-Case 'orphan: a new combination with that name is shown what it inherits' {
    $settings = New-OrphanSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark $false
        try {
            Assert-Equal $script:NoHotkeyText $ed.HotkeyBox.Text 'nothing to inherit until there is a name'
            Assert-Equal 'none' ([string]$ed.Level.Kind) 'and no brightness either'

            $ed.NameBox.Text = 'Movie'
            Assert-Equal 'Ctrl+Alt+F4' $ed.HotkeyBox.Text 'the shortcut left under that name is shown, not hidden'
            Assert-Equal 55 ([int]$ed.Level.Value) 'and so is the brightness'
            Assert-Equal 'one' ([string]$ed.Level.Kind) 'in the shape it was written in'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: its own shortcut is not somebody else - the editor takes it' {
    # Так это и ломалось: клавиша сироты считалась занятой, и редактор ссылался на
    # режим, которого в окне нет и открыть который нельзя. Выйти можно было только
    # удалив строку-сироту.
    $settings = New-OrphanSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark $false
        try {
            $ed.NameBox.Text = 'Movie'
            $ed.Checks[0].IsChecked = $true
            $ed.HotkeyBox.Text = 'Ctrl+Alt+F4'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'the shortcut of the name it takes over is its own'
            Assert-Equal 'Ctrl+Alt+F4' $got.Mode.Hotkey 'and comes back as the mode shortcut'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: all four settings come back, none of them quietly killed' {
    $settings = New-OrphanSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark $false
        try {
            $ed.NameBox.Text = 'Movie'
            $ed.Checks[0].IsChecked = $true
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Set-UiMode -Ui $ui -Mode $null -Combo $null -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'Ctrl+Alt+F4' $updated.hotkeys['combo:Movie'] 'the shortcut survived'
        Assert-Equal 55 $updated.brightness['combo:Movie'] 'the brightness survived'
        Assert-Equal 'ROG' $updated.audio['combo:Movie'] 'the sound was never in danger'
        Assert-True ($updated.combos.Contains('Movie')) 'and the combination itself is there'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: what the person set himself beats what the name would bring' {
    $settings = New-OrphanSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark $false
        try {
            # Сначала своя клавиша и своя яркость, и только потом имя.
            $ed.HotkeyBox.Text = 'Ctrl+Alt+F7'
            $ed.LevelKindBox.SelectedIndex = 1
            $ed.LevelOneSlider.Value = 20
            $ed.NameBox.Text = 'Movie'
            Assert-Equal 'Ctrl+Alt+F7' $ed.HotkeyBox.Text 'his shortcut stayed'
            Assert-Equal 20 ([int]$ed.Level.Value) 'and his brightness too'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: renaming a combination onto that name does not wipe the shortcut' {
    # Тот же путь с другой стороны: у комбинации своей клавиши нет, а у имени, в
    # которое её переименовали, — есть. Пустое поле редактора не должно её снять.
    $settings = New-OrphanSettings
    $settings.hotkeys.Remove('combo:Movie')
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.hotkeys['combo:Movie'] = 'Ctrl+Alt+F4'
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        $ed = New-ModeEditorWindow -Mode $mode -Combo $ui.Combos[0] -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark $false
        try {
            Assert-Equal $script:NoHotkeyText $ed.HotkeyBox.Text 'Work has no shortcut of its own'
            $ed.NameBox.Text = 'Movie'
            Assert-Equal 'Ctrl+Alt+F4' $ed.HotkeyBox.Text 'the shortcut of the name it moves into is shown'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'Ctrl+Alt+F4' $updated.hotkeys['combo:Movie'] 'and it is still there after Save'
        Assert-True (-not $updated.hotkeys.Contains('combo:Work')) 'nothing left under the old name'
    }
    finally { $ui.Window.Close() }
}

# --- итог -------------------------------------------------------------------

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
