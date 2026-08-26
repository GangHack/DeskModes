# --- стол одним переходом ---------------------------------------------------
# Переключение с изменением набора экранов перестраивало стол трижды: набор,
# потом позиции, потом частоты. Каждый переход замораживает ввод — курсор замирал
# и «выстреливал» вперёд. Здесь прибито то, из чего собран единый переход:
# раскладка считается одинаково для обоих путей, целевой режим находится даже для
# спящего монитора, а отказ системы не теряет переключение.

Write-Host ''
Write-Host 'one desktop transition instead of three' -ForegroundColor White

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
