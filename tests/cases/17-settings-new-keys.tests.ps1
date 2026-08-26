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
