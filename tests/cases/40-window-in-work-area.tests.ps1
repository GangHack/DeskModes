# --- a window that does not run off the bottom of the screen ----------------
# The mode editor is SizeToContent: unfolding "Brightness, sound and commands" takes it from
# 620 points to 1342, and all of that growth used to go DOWNWARDS from wherever the window
# already stood. Opened on the lower half of a screen, it put Save under the taskbar.
#
# The arithmetic is pure and is what is checked here; what has to be asked of Windows — which
# monitor the window is on, and at what scale — has no fake and is checked by hand.

Write-Host ''
Write-Host 'windows stay in the work area' -ForegroundColor White

Test-Case 'window shift: a window that fits is not moved at all' {
    $p = Get-WindowShift -Left 760 -Top 380 -Width 400 -Height 620 `
                         -AreaLeft 0 -AreaTop 0 -AreaRight 1920 -AreaBottom 1040
    Assert-Equal 760 $p.X 'left as it was'
    Assert-Equal 380 $p.Y 'top as it was'
}

Test-Case 'window shift: growing downwards past the edge lifts the window' {
    # The fold opened: 620 points became 900, and the bottom went 240 past the taskbar.
    $p = Get-WindowShift -Left 760 -Top 380 -Width 400 -Height 900 `
                         -AreaLeft 0 -AreaTop 0 -AreaRight 1920 -AreaBottom 1040
    Assert-Equal 760 $p.X 'sideways it has not moved'
    Assert-Equal 140 $p.Y 'lifted by exactly what did not fit'
}

Test-Case 'window shift: taller than the work area is pinned to the top' {
    # 1342 points on a 1040-point work area. Pinned to the TOP, not the bottom: the title and
    # the first question stay reachable, and the rest is reached by the scrollbar.
    $p = Get-WindowShift -Left 760 -Top 380 -Width 400 -Height 1342 `
                         -AreaLeft 0 -AreaTop 0 -AreaRight 1920 -AreaBottom 1040
    Assert-Equal 0 $p.Y 'against the top edge'
}

Test-Case 'window shift: a work area that does not start at zero is where it stays' {
    # The second monitor of the desk: x from 1920 to 5760, and a taskbar at the top of it.
    $p = Get-WindowShift -Left 5500 -Top 900 -Width 400 -Height 300 `
                         -AreaLeft 1920 -AreaTop 48 -AreaRight 5760 -AreaBottom 1080
    Assert-Equal 5360 $p.X 'pushed back from the right edge of that monitor'
    Assert-Equal 780 $p.Y 'lifted onto that monitor, not onto the primary one'

    # Wider than the monitor: the left edge wins, so what is cut off is the right one.
    $p = Get-WindowShift -Left 1900 -Top 100 -Width 4000 -Height 300 `
                         -AreaLeft 1920 -AreaTop 48 -AreaRight 5760 -AreaBottom 1080
    Assert-Equal 1920 $p.X 'against the left edge'
}

Test-Case 'window shift: a window is never left overlapping the taskbar it started under' {
    # Both edges at once: standing too low AND too far right.
    $p = Get-WindowShift -Left 1800 -Top 1000 -Width 400 -Height 620 `
                         -AreaLeft 0 -AreaTop 0 -AreaRight 1920 -AreaBottom 1040
    Assert-Equal 1520 $p.X 'inside on the right'
    Assert-Equal 420 $p.Y 'inside at the bottom'
}

Test-Case 'window shift: an editor that was never shown is left alone' {
    # A window with no HWND stands nowhere: its Top is NaN, and assigning NaN back would throw.
    # This is the case every test in this suite is in, and the render tool as well.
    $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $script:DlgState -Dark $false
    try {
        Move-WindowIntoWorkArea -Window $ed.Window
        Assert-True ([double]::IsNaN($ed.Window.Top)) 'the window was not placed'
        Assert-Null (Get-WindowWorkArea -Window $ed.Window) 'and it is on no monitor yet'
    }
    finally { $ed.Window.Close(); $script:ActiveEditor = $null }
}

Test-Case 'window height: with nobody to measure by, the primary monitor answers' {
    # An editor is built with its owner's monitor in mind; in the tests there is no owner, and
    # the fallback has to be a number rather than a crash.
    $h = Get-WorkAreaHeight -Window $null
    Assert-True ($h -gt 0) 'a height came back'
    Assert-Equal ([double][System.Windows.SystemParameters]::WorkArea.Height) $h 'the primary work area'
}
