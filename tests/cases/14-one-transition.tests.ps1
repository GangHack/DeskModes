# --- the desk in one transition ---------------------------------------------
# A switch that changed the set of screens used to rebuild the desk three times: the set, then the
# positions, then the refresh rates. Every transition freezes input — the cursor stalled and then
# "shot" forward. What is nailed down here is what the single transition is assembled from: the
# layout is worked out identically for both paths, a target mode is found even for a sleeping
# monitor, and a refusal from the system does not lose the switch.

Write-Host ''
Write-Host 'one desktop transition instead of three' -ForegroundColor White

Test-Case 'layout math: displays line up left to right in the settings order' {
    $screens = @(
        (New-FakeScreen 'p-ug' 'LG ULTRAGEAR' 2560 1440)
        (New-FakeScreen 'p-uf' 'LG ULTRAFINE' 3840 2160)
    )
    # The order is the reverse of the screen list: what has to count is the ORDER, not the shape the
    # system handed the monitors back in.
    $pos = Get-LayoutPositions -Screens $screens -Order @('ULTRAFINE', 'ULTRAGEAR') -PrimaryPath 'p-uf'
    Assert-Equal 0 $pos['p-uf'].X 'primary sits at the origin'
    Assert-Equal 3840 $pos['p-ug'].X 'the next one starts where the first ends'
}

Test-Case 'layout math: the primary display lands at (0,0), whatever its place' {
    # In Windows the primary is not a flag but a place: the top-left corner at the coordinate origin.
    # It stands on the right — so the whole layout goes into the negative.
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
    # Aligned at the top, a strip is left at the bottom of the tall monitor that the cursor cannot
    # cross to the neighbour from — exactly what a person stumbles over with the mouse.
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
    # "UltraGear" has to find "LG ULTRAGEAR": the system knows monitors by shorter names than people
    # do, and this rule is shared by layout, primary and a combo's membership.
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
    # The main case: the monitor is out, EnumDisplaySettings says nothing about it, and without the
    # cache the refresh rate would have to be fixed by a second rebuild of the desk.
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
    # 144 Hz is in the cache and 240 is being asked for — we have no fraction for 240. Asking for
    # "240/1" is not allowed: CCD rejects such a request entirely (validate -> 1610), and the
    # resolution and the layout would be lost along with the refresh rate.
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
    # Mixing specified modes with unspecified ones in one request means guessing what the system will
    # do with the remainder. Such a set goes the old road whole.
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
    # The third "already done" check: skipping the output enumeration and two mode queries per monitor
    # on a repeat press of the shortcut rests on it.
    $m = New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'p-ug'
    $m.BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 144 }
    Assert-True (Test-ModesAlreadyBest @($m)) 'current mode equals the best one'
}

Test-Case 'already best: a lower refresh rate is not "already best"' {
    # Exactly the case the refresh-rate watchdog exists for: the resolution is the same, and Windows
    # dropped the hertz.
    $m = New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'p-ug'
    $m.Hz = 60
    $m.BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 144 }
    Assert-True (-not (Test-ModesAlreadyBest @($m))) 'the rate has to match too'
}

Test-Case 'already best: a display that is off or has no best mode is not' {
    # For a monitor that has just woken, BestMode is still $null — the pass over the modes has to
    # happen, or it will stay at the refresh rate out of the Windows registry.
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
    # On the ASUS a 240 refresh rate is not written at all, and on the ULTRAGEAR over HDMI it does not
    # exist — a refusal over hertz is no reason to lose the resolutions and the layout.
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
    # The failure has to come back up: there the switch goes to the old road of three steps. A silent
    # "yes" would leave a person with a black screen.
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
    # Setting the whole desk means naming coordinates for every screen — and without the order out of
    # the settings we would arrange the monitors alphabetically where nobody asked us to. The old path
    # is more honest in that case: it moves only the primary monitor.
    $script:FullCalls = @()
    function Invoke-CcdFullConfigAttempt {
        param($Targets, [string]$PrimaryPath, [string[]]$Order, [switch]$WithHz)
        $script:FullCalls += [bool]$WithHz
        return $true
    }
    # TWO screens, because that is where the question arises at all: with two of them somebody has to
    # stand on the left, and only the settings know who.
    $targets = @(
        [pscustomobject]@{ DevicePath = 'p-a'; Label = 'A'; Width = 2560; Height = 1440
                           Hz = 144; RateNum = 143999; RateDen = 1000 }
        [pscustomobject]@{ DevicePath = 'p-b'; Label = 'B'; Width = 3840; Height = 2160
                           Hz = 60; RateNum = 59997; RateDen = 1000 })
    Assert-True (-not (Set-CcdFullConfig -Targets $targets -Order @())) 'refused without an order'
    Assert-True (-not (Set-CcdFullConfig -Targets $targets -Order @('', $null))) 'blank names are not an order either'
    Assert-Equal 0 $script:FullCalls.Count 'Windows was never asked'
}

Test-Case 'full config: one display needs no order - its place is the origin' {
    # A solo mode is the mode pressed most often of all, and there is nothing to arrange one screen
    # against: it stands at (0, 0) whatever anybody wrote in the settings. Refusing here sent every desk
    # whose owner has never opened the Settings window down the three-transition road for no reason.
    $script:FullCalls = @()
    function Invoke-CcdFullConfigAttempt {
        param($Targets, [string]$PrimaryPath, [string[]]$Order, [switch]$WithHz)
        $script:FullCalls += [bool]$WithHz
        return $true
    }
    $targets = @([pscustomobject]@{ DevicePath = 'p'; Label = 'A'; Width = 2560; Height = 1440
                                    Hz = 144; RateNum = 143999; RateDen = 1000 })
    Assert-True (Set-CcdFullConfig -Targets $targets -Order @()) 'the one-call road is taken'
    Assert-Equal 1 $script:FullCalls.Count 'and Windows was asked exactly once'
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
    # Otherwise a solo mode would erase the memory of the other monitors, and they would wake up at
    # somebody else's refresh rate again.
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
    # Such records will happen: the monitor may not have given a refresh rate at all. A zero here is
    # more honest than an invention — then the system chooses the rate.
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
    # Otherwise the tray shows a green "Displays switched" while the monitors stand in the wrong order.
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
    # An empty summary happens when not one monitor attached; the text must not begin with a full stop.
    $v = Format-SwitchResult -Summary @() -Failed @('B')
    Assert-True (-not $v.Ok) 'not ok'
    Assert-True ($v.Text -like 'did not come up*') 'starts with the problem, not punctuation'
}

Test-Case 'phases: breakdown keeps switch order and drops the invisible' {
    $t = Format-PhaseTimes ([ordered]@{ state = 0.31; apply = 1.24; settle = 0.01 })
    Assert-Equal 'state 0.3, apply 1.2' $t 'only phases that took time, in the order they ran'
}

Test-Case 'phases: a quiet switch prints nothing at all' {
    # Otherwise every no-op would drag a tail of zeroes into done:.
    Assert-Equal '' ([string](Format-PhaseTimes ([ordered]@{ apply = 0.01 }))) 'all quiet - empty'
    Assert-Equal '' ([string](Format-PhaseTimes $null)) 'no phases at all is fine too'
}
