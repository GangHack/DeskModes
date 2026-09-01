# --- the guard against "the game sets its own mode" --------------------------
# The refresh-rate watchdog does not interfere while a full-screen application is on the screen: a mode
# change under one kills a full-screen D3D device. Test-FullscreenApp decides, and over the log's history
# it said "a game" a hundred and fifty times where there was no game.
#
# The culprit was found by measurement: TextInputHost — the system input window, EXACTLY the size of the
# monitor, visible by IsWindowVisible and cloaked by DWM. The testable part of the decision is lifted out
# into Get-GhostWindowReason: in Test-FullscreenApp itself every input comes from Windows, and
# [NativeForeground] is a type rather than a function, so there is nothing to shadow it with.

Write-Host ''
Write-Host 'the full-screen guard' -ForegroundColor White

Test-Case 'ghost: an ordinary visible window is a real window' {
    $why = Get-GhostWindowReason -Visible $true -Cloaked $false -Minimised $false -ToolWindow $false
    Assert-Equal '' $why 'nothing to hold against it'
}

Test-Case 'ghost: a window DWM cloaked is not on the desk, whatever its size' {
    # Exactly the TextInputHost case: IsWindowVisible says yes, and it is not on the screen.
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
    # The NVIDIA Overlay fell ONE pixel short of the old check, that is, it would have passed on the very
    # first change. A game does not set WS_EX_TOOLWINDOW on itself; an overlay does.
    $why = Get-GhostWindowReason -Visible $true -Cloaked $false -Minimised $false -ToolWindow $true
    Assert-Equal 'the window is a tool window' $why ''
}

Test-Case 'ghost: the reason is the first thing that disqualifies it, not a list' {
    $why = Get-GhostWindowReason -Visible $false -Cloaked $true -Minimised $true -ToolWindow $true
    Assert-Equal 'the window is not visible' $why 'one sentence, so the log stays readable'
}

Test-Case 'fullscreen state names: the log gets a name, not just a number' {
    # "state=2" in a bug report says nothing, QUNS_BUSY says everything.
    Assert-Equal 'QUNS_BUSY' $script:NotificationStateNames[2] ''
    Assert-Equal 'QUNS_RUNNING_D3D_FULL_SCREEN' $script:NotificationStateNames[3] ''
    Assert-Equal 'QUNS_ACCEPTS_NOTIFICATIONS' $script:NotificationStateNames[5] 'the quiet one, which is not full screen'
    # All four values the watchdog backs off on have to have a name: without one the log line degenerates
    # into "the shell says 7 (unknown)".
    foreach ($code in @(2, 3, 4, 7)) {
        Assert-True ([bool]$script:NotificationStateNames[$code]) "state $code has a name"
    }
}
