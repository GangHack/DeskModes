# --- оркестратор переключения -----------------------------------------------
# Switch-DisplayMode — самая сложная и самая ломкая часть проекта, и до сих пор
# единственным способом её проверить было переключить настоящие мониторы.
#
# Проверяется она ПОДМЕНОЙ ФУНКЦИЙ, а не швом в коде. К железу и к диску
# Switch-DisplayMode ходит только через именованные функции, а PowerShell ищет
# функции по цепочке областей ВЫЗОВА. Значит объявление `function Set-CcdFullConfig`
# внутри блока Test-Case перекрывает настоящую для всего, что этот блок позовёт, и
# умирает вместе с блоком: восстанавливать нечего, изоляция между случаями
# бесплатная, а на пути, где мерялись миллисекунды, не появилось ни одного лишнего
# вызова. Производственный код для этих тестов не менялся вообще.
#
# Подделки пишут вызовы в $script:SwCalls — тест проверяет ЧТО и в КАКОМ порядке
# позвали, а не только чем всё кончилось.
#
# Ретрай самой раскладки живёт этажом ниже, в Invoke-CcdLayoutAttempt, и проверен
# в 13-layout-retry: здесь Set-CcdLayout отвечает сразу и целиком.

Write-Host ''
Write-Host 'the switch orchestrator' -ForegroundColor White

# Стол для оркестратора. BestMode заполнен нарочно: без него Get-SwitchTargets
# отдаёт пустой набор, переход одним вызовом даже не пробуется, и половина
# случаев проверяла бы не то, что написано в их названии.
function New-SwitchDesk {
    param([bool]$ThirdActive = $true, [bool]$ThirdDisconnected = $false)

    $desk = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf')
        (New-FakeMonitor 'XG27AQDMGR' 'AUS1234' 'path-xg' $ThirdActive $ThirdDisconnected)
    )
    for ($i = 0; $i -lt $desk.Count; $i++) {
        $desk[$i].Output = '\\.\DISPLAY' + ($i + 1)
        $desk[$i].BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 144 }
    }
    return $desk
}

function New-SwitchSettings {
    param([hashtable]$Combos = @{})
    $s = New-TestSettings -Combos $Combos
    # Порядок на столе задан: без него Set-CcdLayout не зовётся вообще, и
    # проверять «раскладка всё равно проверяется» было бы нечем.
    $s.layout = @('LG ULTRAGEAR', 'LG ULTRAFINE', 'XG27AQDMGR')
    return $s
}

# Все подделки одним куском. Дот-сорс скриптблока исполняет его в области ТОГО,
# кто позвал, — то есть внутри блока Test-Case, а не в области скрипта. Так
# функции живут ровно один случай и не протекают в следующий.
$script:SwFakes = {
    $script:SwCalls = @()
    $script:SwFullOk = $true
    $script:SwTopologyOk = $true
    $script:SwSettled = [pscustomobject]@{ Ok = $true; MissingLabels = @(); ExtraLabels = @() }
    $script:SwLayoutOk = $true
    $script:SwLayoutChanged = $false
    $script:SwSavedMode = ''
    $script:SwAppliedModes = $null

    function Get-DisplaySettings { return $script:SwSettings }
    function Get-DisplayState { return @($script:SwDesk) }

    # Кэш проверенных режимов подменён нарочно: файл во временной папке остаётся
    # после других групп случаев, и без этого набор целей зависел бы от порядка
    # прогона.
    function Get-ModeCache { return @{} }

    function Invoke-ModeHook {
        param($Settings, [string]$ModeKey, [string]$Phase)
        $script:SwCalls += "hook:$Phase"
        return $true
    }

    function Save-WindowLayout { param([string]$Key) $script:SwCalls += 'windows:save' }
    function Restore-WindowLayout { param([string]$Key) $script:SwCalls += 'windows:restore' }

    function Set-CcdFullConfig {
        param($Targets, [string]$PrimaryPath, $Order)
        $script:SwCalls += ('full:' + ((@($Targets) | ForEach-Object { $_.DevicePath }) -join '+'))
        $script:SwFullPrimary = $PrimaryPath
        return $script:SwFullOk
    }

    function Set-CcdTopology {
        param($DevicePaths)
        $script:SwCalls += ('topology:' + (@($DevicePaths) -join '+'))
        return $script:SwTopologyOk
    }

    function Wait-ForTopology {
        param($WantedPaths)
        $script:SwCalls += 'settle'
        return $script:SwSettled
    }

    function Set-CcdLayout {
        param([string]$PrimaryPath, $Order)
        $script:SwCalls += 'layout'
        return [pscustomobject]@{ Ok = $script:SwLayoutOk; Changed = $script:SwLayoutChanged }
    }

    # Set-WantedModes работает по-настоящему: подменены только его концы у железа.
    function Get-CcdTargets {
        return @(@($script:SwDesk) | Where-Object { $_.Active } | ForEach-Object {
            [pscustomobject]@{ DevicePath = $_.Id; Output = $_.Output; Active = $true }
        })
    }
    # Спящий монитор в Get-CcdTargets ещё не виден: имя выхода за ним идут
    # спрашивать отдельно, и здесь он как раз просыпается. Так проверяется и та
    # ветка Set-WantedModes, которая ждёт опоздавших.
    function Get-CcdOutput {
        param([string]$DevicePath)
        $m = @($script:SwDesk) | Where-Object { $_.Id -eq $DevicePath } | Select-Object -First 1
        return $(if ($m) { [string]$m.Output } else { '' })
    }

    function Set-BestModeFor {
        param([string]$Output, [string]$Label, [int]$NativeWidth, [int]$NativeHeight, $Best)
        $script:SwCalls += "best:$Label"
        return $true
    }
    function Get-CurrentMode {
        param([string]$Output)
        return [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 144 }
    }

    function Save-LastMode { param([string]$Key) $script:SwCalls += 'lastMode'; $script:SwSavedMode = $Key }
    function Save-AppliedModes { param($Applied) $script:SwCalls += 'applied'; $script:SwAppliedModes = $Applied }

    function Set-DefaultAudioDevice { param([string]$Match) $script:SwCalls += "audio:$Match"; return $true }
    function Set-MonitorLevels {
        param($Targets, $BrightnessSetting, $ContrastSetting)
        $script:SwCalls += ('levels:' + ((@($Targets) | ForEach-Object { $_.Label }) -join '+'))
        return $true
    }
}

Test-Case 'switch: the set is already right, so the topology is not rebuilt' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True $r.Ok 'the switch is a success'
    Assert-True (-not ($script:SwCalls -match '^full')) 'no whole-desk transition was asked for'
    Assert-True (-not ($script:SwCalls -match '^topology')) 'and no topology rebuild either'
    Assert-True (-not ($script:SwCalls -contains 'settle')) 'nothing to wait for'
    Assert-True (-not ($script:SwCalls -contains 'windows:save')) 'windows did not move, so they were not snapshotted'
    # Раскладка и режимы всё равно проверяются: набор может совпадать, а стол быть
    # развален — например после DisplaySwitch /extend.
    Assert-True ($script:SwCalls -contains 'layout') 'the layout is still checked'
    Assert-Equal 'hook:before,layout,lastMode,applied,hook:after' ($script:SwCalls -join ',') 'and that is the whole of it'
}

Test-Case 'switch: a changing set is one whole-desk call, not three transitions' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True $r.Ok 'the switch is a success'
    Assert-Equal 1 @($script:SwCalls | Where-Object { $_ -like 'full:*' }).Count 'exactly one whole-desk call'
    Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'topology:*' }).Count 'and the three-step road is not touched'
    Assert-Equal 'full:path-ug+path-uf+path-xg' (@($script:SwCalls | Where-Object { $_ -like 'full:*' })[0]) 'all three displays in one call'
    Assert-True ($script:SwCalls -contains 'windows:save') 'window positions were taken before the rebuild'
    Assert-True ($script:SwCalls -contains 'windows:restore') 'and put back after it'
}

Test-Case 'switch: window positions are taken before the desk is rebuilt, not after' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)

    $order = $script:SwCalls -join ','
    Assert-True ($order -match 'windows:save,full:') 'the snapshot comes immediately before the transition'
    Assert-True ($script:SwCalls.IndexOf('windows:restore') -gt $script:SwCalls.IndexOf('layout')) 'and the restore comes after the layout'
}

Test-Case 'switch: a refused whole-desk call falls back to the three-step road' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $script:SwFullOk = $false

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True $r.Ok 'the old road still gets there'
    Assert-Equal 1 @($script:SwCalls | Where-Object { $_ -like 'full:*' }).Count 'the one call was tried first'
    Assert-Equal 1 @($script:SwCalls | Where-Object { $_ -like 'topology:*' }).Count 'and only then the set alone'
    Assert-True ($script:SwCalls -contains 'settle') 'the result is waited for either way'
}

Test-Case 'switch: Windows refusing the configuration is a failure, not a quiet success' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $script:SwFullOk = $false
    $script:SwTopologyOk = $false

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'all' -Quiet) }
    catch { $failed = $_.Exception.Message }

    Assert-True ($failed -like '*Windows refused the display configuration*') 'it says what happened'
    Assert-True ($failed -like '*you keep a picture*') 'and that nothing was lost'
    Assert-True (-not ($script:SwCalls -contains 'lastMode')) 'a switch that did not happen is not remembered'
    Assert-True (-not ($script:SwCalls -contains 'hook:after')) 'and the after command does not run'
}

Test-Case 'switch: the before command runs only once the switch can no longer refuse' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)

    Assert-Equal 'hook:before' $script:SwCalls[0] 'before is the first thing that touches the outside world'
    Assert-Equal 'hook:after' $script:SwCalls[-1] 'and after is the very last'
    Assert-True ($script:SwCalls.IndexOf('hook:before') -lt $script:SwCalls.IndexOf('windows:save')) 'before runs ahead of the snapshot'
}

Test-Case 'switch: a mode that cannot be reached never starts the before command' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    try { [void](Switch-DisplayMode -ModeKey 'solo:Nothing Like This' -Quiet) } catch { }

    Assert-Equal 0 $script:SwCalls.Count 'nothing was run under a mode that will not be'
}

Test-Case 'switch: a display that is not plugged in is said in human words' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'solo:Some Other Screen' -Quiet) }
    catch { $failed = $_.Exception.Message }

    Assert-Equal 'That display is not connected right now.' $failed 'no key names, no stack, a sentence'
}

Test-Case 'switch: a combination deleted in the settings is named, not numbered' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'combo:Movie night' -Quiet) }
    catch { $failed = $_.Exception.Message }

    Assert-Equal "The combination 'Movie night' no longer exists in the settings." $failed 'the name comes back as typed'
}

Test-Case 'switch: a mode nobody knows is refused by its key' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'nonsense' -Quiet) }
    catch { $failed = $_.Exception.Message }

    Assert-Equal "Unknown mode 'nonsense'." $failed 'and the key is quoted so it can be found in the settings'
}

Test-Case 'switch: a combination whose displays are all unplugged keeps the picture' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false -ThirdDisconnected $true
    $script:SwSettings = New-SwitchSettings -Combos @{ 'Movie' = @('XG27AQDMGR') }

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'combo:Movie' -Quiet) }
    catch { $failed = $_.Exception.Message }

    Assert-True ($failed -like "*Mode 'Movie'*") 'the mode is named'
    Assert-True ($failed -like '*Nothing was turned off*') 'and nothing was turned off to find that out'
    Assert-Equal 0 $script:SwCalls.Count 'not a single call went out'
}

Test-Case 'switch: a layout that would not lie down is not reported as success' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwLayoutOk = $false

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True (-not $r.Ok) 'a silent success on scrambled displays is the worst possible message'
    Assert-True ($r.Message -like '*positions not arranged*') 'the text says what to do about it'
    # Выбор человека запоминается даже так: он просил именно этот режим.
    Assert-True ($script:SwCalls -contains 'lastMode') 'and the choice is still remembered'
    Assert-Equal 'all' $script:SwSavedMode 'as the mode he asked for'
}

Test-Case 'switch: displays Windows would not turn off land in the verdict' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $script:SwSettled = [pscustomobject]@{ Ok = $false; MissingLabels = @(); ExtraLabels = @('XG27AQDMGR') }

    $r = Switch-DisplayMode -ModeKey 'solo:LG ULTRAGEAR' -Quiet

    Assert-Equal @('XG27AQDMGR') @($r.Refused) 'the display that stayed on is named'
    Assert-True (-not $r.Ok) 'and that is not a success'
    Assert-True ($r.Message -like '*Still on: XG27AQDMGR*') 'the summary says so in words'
}

Test-Case 'switch: a dry run changes nothing and remembers nothing' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    $r = Switch-DisplayMode -ModeKey 'all' -DryRun -Quiet 6> $null

    Assert-Equal 'dry run' $r.Message 'it says what it was'
    Assert-True $r.Ok 'and a dry run does not fail'
    Assert-Equal 0 $script:SwCalls.Count 'not one call to the system or the disk'
}

Test-Case 'switch: -KeepMode leaves resolution and refresh rate alone' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    $r = Switch-DisplayMode -ModeKey 'all' -KeepMode -Quiet

    Assert-True $r.Ok 'the switch still lands'
    Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'best:*' }).Count 'nobody was pushed to its best mode'
    # А ещё: у спящего монитора «оставить как есть» нечего — текущего режима у
    # него нет. Набор целиком уходит на старую дорогу, и это не поломка, а
    # единственный честный ответ: смешивать заданные размеры с незаданными в
    # одном запросе значит гадать, что система сделает с остатком.
    Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'full:*' }).Count 'the one-call road needs modes, so it is not even tried'
    Assert-Equal 1 @($script:SwCalls | Where-Object { $_ -like 'topology:*' }).Count 'the set alone is asked for instead'
}

Test-Case 'switch: modes are only pushed when the desk actually moved' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)

    # Стол перестраивался, значит «уже в максимуме» не годится и режимы доводятся.
    Assert-Equal 3 @($script:SwCalls | Where-Object { $_ -like 'best:*' }).Count 'all three displays got their mode'
    Assert-True ($script:SwCalls -contains 'applied') 'and what they showed was written down'
}

Test-Case 'switch: sound and brightness follow the mode, and only when asked for' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwSettings.audio['all'] = 'ULTRAFINE'
    $script:SwSettings.brightness['all'] = 40

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)

    Assert-True ($script:SwCalls -contains 'audio:ULTRAFINE') 'the playback device was switched'
    Assert-True ($script:SwCalls -match '^levels:') 'and the levels went out over DDC'
    # Порядок осмысленный: и то и другое после того, как режим состоялся, а
    # команда «после» — в самом конце, чтобы застать готовое состояние.
    Assert-True ($script:SwCalls.IndexOf('hook:after') -gt $script:SwCalls.IndexOf('audio:ULTRAFINE')) 'after the sound'
}

Test-Case 'switch: nothing set means no slow bus is touched at all' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)

    Assert-True (-not ($script:SwCalls -match '^audio:')) 'no audio device was enumerated'
    Assert-True (-not ($script:SwCalls -match '^levels:')) 'and not a single DDC request went out'
}

Test-Case 'switch: a switch already in progress is skipped, not queued behind it' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    # Мьютекс принадлежит ПОТОКУ, а не объекту: повторный WaitOne из своего же
    # потока проходит насквозь, и держать его из самого теста бесполезно —
    # проверялось бы ничто. Поэтому держит отдельный поток, а синхронизация на
    # именованных событиях, с ограниченным ожиданием: тест не имеет права
    # подвиснуть, чем бы ни кончился захват.
    $held = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\ScreenDeckTestHeld')
    $go = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\ScreenDeckTestGo')
    $holder = [powershell]::Create()
    [void]$holder.AddScript({
        $m = New-Object System.Threading.Mutex($false, 'Local\ScreenDeckSwitch')
        $got = $m.WaitOne(0)
        # Сигналим только на удачном захвате: если мьютекс занял живой трей,
        # ожидание в тесте истечёт, и провал будет читаемым, а не загадочным.
        if ($got) {
            $flag = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\ScreenDeckTestHeld')
            [void]$flag.Set()
            $wait = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\ScreenDeckTestGo')
            [void]$wait.WaitOne(10000)
            $m.ReleaseMutex()
        }
        $m.Dispose()
    })
    $task = $holder.BeginInvoke()
    try {
        Assert-True ($held.WaitOne(5000)) 'another thread really holds the switch mutex'

        $r = Switch-DisplayMode -ModeKey 'all' -Quiet

        Assert-True $r.Skipped 'the second switch stands aside'
        Assert-Equal 'all' $r.Mode 'and says which one it was'
        Assert-Equal 'A switch is already in progress.' $r.Message 'in words a person can read'
        Assert-Equal 0 $script:SwCalls.Count 'nothing was done twice'
    }
    finally {
        [void]$go.Set()
        [void]$holder.EndInvoke($task)
        $holder.Dispose()
        $held.Dispose()
        $go.Dispose()
    }
}
