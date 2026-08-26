# --- защита от «игра сама ставит режим» -------------------------------------
# Сторож частоты не вмешивается, пока на экране полноэкранное приложение: смена
# режима под ним роняет полноэкранное устройство D3D. Решает Test-FullscreenApp, и
# она полтораста раз за историю журнала говорила «игра» там, где игры не было.
#
# Виновник найден замером: TextInputHost — системное окно ввода размером РОВНО в
# монитор, видимое по IsWindowVisible и закрытое DWM. Проверяемая часть решения
# вынесена в Get-GhostWindowReason: у самой Test-FullscreenApp все входы приходят
# от Windows, а [NativeForeground] — тип, а не функция, и подменить его нечем.

Write-Host ''
Write-Host 'the full-screen guard' -ForegroundColor White

Test-Case 'ghost: an ordinary visible window is a real window' {
    $why = Get-GhostWindowReason -Visible $true -Cloaked $false -Minimised $false -ToolWindow $false
    Assert-Equal '' $why 'nothing to hold against it'
}

Test-Case 'ghost: a window DWM cloaked is not on the desk, whatever its size' {
    # Ровно случай TextInputHost: IsWindowVisible говорит «да», на экране его нет.
    $why = Get-GhostWindowReason -Visible $true -Cloaked $true -Minimised $false -ToolWindow $false
    Assert-Equal 'the window is cloaked by DWM' $why 'and the reason names DWM, not the window'
}

Test-Case 'ghost: an invisible window is not a full-screen app' {
    $why = Get-GhostWindowReason -Visible $false -Cloaked $false -Minimised $false -ToolWindow $false
    Assert-Equal 'the window is not visible' $why ''
}

Test-Case 'ghost: a minimised window cannot own the screen' {
    $why = Get-GhostWindowReason -Visible $true -Cloaked $false -Minimised $true -ToolWindow $false
    Assert-Equal 'the window is minimised' $why ''
}

Test-Case 'ghost: an overlay without a taskbar button is not a game' {
    # NVIDIA Overlay не дотягивал до прежней проверки ОДИН пиксель, то есть прошёл
    # бы при первом же изменении. Игра себе WS_EX_TOOLWINDOW не ставит, накладка —
    # ставит.
    $why = Get-GhostWindowReason -Visible $true -Cloaked $false -Minimised $false -ToolWindow $true
    Assert-Equal 'the window is a tool window' $why ''
}

Test-Case 'ghost: the reason is the first thing that disqualifies it, not a list' {
    $why = Get-GhostWindowReason -Visible $false -Cloaked $true -Minimised $true -ToolWindow $true
    Assert-Equal 'the window is not visible' $why 'one sentence, so the log stays readable'
}

Test-Case 'fullscreen state names: the log gets a name, not just a number' {
    # «state=2» в отчёте об ошибке не говорит ничего, QUNS_BUSY говорит всё.
    Assert-Equal 'QUNS_BUSY' $script:NotificationStateNames[2] ''
    Assert-Equal 'QUNS_RUNNING_D3D_FULL_SCREEN' $script:NotificationStateNames[3] ''
    Assert-Equal 'QUNS_ACCEPTS_NOTIFICATIONS' $script:NotificationStateNames[5] 'the quiet one, which is not full screen'
    # Все четыре значения, на которые сторож отступает, обязаны иметь имя: без него
    # строка журнала выродится в «the shell says 7 (unknown)».
    foreach ($code in @(2, 3, 4, 7)) {
        Assert-True ([bool]$script:NotificationStateNames[$code]) "state $code has a name"
    }
}
