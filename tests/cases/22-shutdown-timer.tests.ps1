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
