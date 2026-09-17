# --- the desk-layout key ----------------------------------------------------

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

# --- what the snapshot is allowed to hold -----------------------------------
# A window title holds the document you have open, the page you are on, the subject of the letter you are
# writing, and the tool promises in three places that titles are never read. They were written into
# window-state.json all the same, and nothing ever read them back — so deleting activity.json, which the
# Settings window offers as "forget everything", left them sitting in the file next to it.

Test-Case 'windows: an older store loses the titles and paths on the next sweep' {
    # Stopping the writing is only half of it: a snapshot is rewritten when its own desk is left, so the
    # layouts a person visits rarely would have kept their titles for as long as the file lived.
    $mine = [int]$PID
    @{
        'path-a|path-b' = @{
            saved   = '2026-08-30T12:00:00'
            windows = @(
                @{ hwnd = 1001; pid = $mine; path = 'C:\Program Files\Thing\thing.exe'
                   title = 'Quarterly review - a document nobody else should read'
                   showCmd = 1; n = @(10, 20, 110, 120); mn = @(-1, -1); mx = @(-1, -1) }
            )
        }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:WindowStateFile -Encoding UTF8

    Remove-DeadWindowLayouts

    $store = Get-WindowStateStore
    Assert-True $store.ContainsKey('path-a|path-b') 'the snapshot itself is kept - its process is alive'
    $w = @($store['path-a|path-b'].windows)[0]
    $fields = @($w.PSObject.Properties.Name)
    Assert-True ($fields -notcontains 'title') 'the title is gone'
    Assert-True ($fields -notcontains 'path') 'and so is the path to the executable'

    # Everything Restore-WindowLayout actually reads has to survive the sweep, or the windows stop coming
    # back and nobody would connect that with a privacy fix.
    Assert-Equal 1001 ([int64]$w.hwnd) 'the window number is kept'
    Assert-Equal $mine ([int]$w.pid) 'and its process'
    Assert-Equal 1 ([int]$w.showCmd) 'and whether it was maximised'
    Assert-Equal @(10, 20, 110, 120) @($w.n) 'and where it sat'
    Assert-Equal '2026-08-30T12:00:00' ([string]$store['path-a|path-b'].saved) 'and when the snapshot was taken'

    Remove-Item -LiteralPath $script:WindowStateFile -Force
}

Test-Case 'windows: a store already clean is left alone' {
    # The sweep runs on every tray start, and it must not rewrite the file for the sake of it.
    $mine = [int]$PID
    @{
        'path-a' = @{
            saved   = '2026-08-30T12:00:00'
            windows = @(@{ hwnd = 7; pid = $mine; showCmd = 3; n = @(0, 0, 100, 100)
                           mn = @(-1, -1); mx = @(-1, -1) })
        }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:WindowStateFile -Encoding UTF8
    $before = [System.IO.File]::ReadAllText($script:WindowStateFile)

    Remove-DeadWindowLayouts

    Assert-Equal $before ([System.IO.File]::ReadAllText($script:WindowStateFile)) 'not a byte touched'
    Remove-Item -LiteralPath $script:WindowStateFile -Force
}

Test-Case 'windows: display geometry gives each resolution its own snapshot key' {
    $wide = @([pscustomobject]@{
        Device = 'DISPLAY1'; Primary = $true
        Left = 0; Top = 0; Right = 2560; Bottom = 1440
        WorkLeft = 0; WorkTop = 0; WorkRight = 2560; WorkBottom = 1400
    })
    $square = @([pscustomobject]@{
        Device = 'DISPLAY1'; Primary = $true
        Left = 0; Top = 0; Right = 1024; Bottom = 1024
        WorkLeft = 0; WorkTop = 0; WorkRight = 1024; WorkBottom = 984
    })

    $wideKey = Get-WindowSnapshotKey -LayoutKey 'path-a' -Areas $wide
    $squareKey = Get-WindowSnapshotKey -LayoutKey 'path-a' -Areas $square

    Assert-True ($wideKey -ne $squareKey) 'the same monitor set no longer aliases incompatible geometry'
    Assert-Equal $wideKey (Get-WindowSnapshotKey -LayoutKey 'path-a' -Areas $wide) 'the key is stable'
}

Test-Case 'windows: an off-screen normal rectangle is moved into the current work area' {
    $areas = @([pscustomobject]@{
        Device = 'DISPLAY1'; Primary = $true
        Left = 0; Top = 0; Right = 1024; Bottom = 1024
        WorkLeft = 0; WorkTop = 0; WorkRight = 1024; WorkBottom = 984
    })
    $saved = [pscustomobject]@{
        showCmd = 2
        n = @(2269, 241, 3291, 1215)
        mn = @(-1, -1)
        mx = @(-1, -1)
    }

    $safe = Get-SafeWindowPlacement -Saved $saved -Areas $areas

    Assert-Equal 2 $safe.ShowCmd 'minimized stays minimized'
    Assert-Equal 2 $safe.Normal[0] 'the full-width window is brought to the visible horizontal range'
    Assert-Equal 10 $safe.Normal[1] 'the bottom edge is lifted above the taskbar'
    Assert-Equal 1024 $safe.Normal[2] 'the original width is preserved'
    Assert-Equal 984 $safe.Normal[3] 'the original height is preserved'
    Assert-True $safe.Adjusted 'the caller can report that this placement was repaired'
}

Test-Case 'windows: valid placement and maximized state survive unchanged' {
    $areas = @([pscustomobject]@{
        Device = 'DISPLAY1'; Primary = $true
        Left = 0; Top = 0; Right = 1920; Bottom = 1080
        WorkLeft = 0; WorkTop = 48; WorkRight = 1920; WorkBottom = 1080
    })
    # WINDOWPLACEMENT uses workspace coordinates. With a top taskbar this rectangle is at screen Y=148,
    # and converting it to screen coordinates for validation and back must not make it creep.
    $saved = [pscustomobject]@{
        showCmd = 3
        n = @(100, 100, 1100, 800)
        mn = @(-1, -1)
        mx = @(-1, -1)
    }

    $safe = Get-SafeWindowPlacement -Saved $saved -Areas $areas

    Assert-Equal 3 $safe.ShowCmd 'maximized stays maximized'
    Assert-Equal @(100, 100, 1100, 800) $safe.Normal 'workspace coordinates round-trip unchanged'
    Assert-Equal $false $safe.Adjusted 'a reachable placement is not rewritten'
}

Test-Case 'windows: malformed rectangles are refused before the native call' {
    $areas = @([pscustomobject]@{
        Device = 'DISPLAY1'; Primary = $true
        Left = 0; Top = 0; Right = 1920; Bottom = 1080
        WorkLeft = 0; WorkTop = 0; WorkRight = 1920; WorkBottom = 1040
    })

    Assert-Null (Get-SafeWindowPlacement -Saved ([pscustomobject]@{
        showCmd = 1; n = @(10, 20, 10, 120); mn = @(-1, -1); mx = @(-1, -1)
    }) -Areas $areas) 'zero-width rectangles never reach SetWindowPlacement'
    Assert-Null (Get-SafeWindowPlacement -Saved ([pscustomobject]@{
        showCmd = 1; n = @(10, 20, 110); mn = @(-1, -1); mx = @(-1, -1)
    }) -Areas $areas) 'incomplete arrays are refused'
    Assert-Null (Get-SafeWindowPlacement -Saved ([pscustomobject]@{
        showCmd = 1; n = @($null, 20, 110, 120); mn = @(-1, -1); mx = @(-1, -1)
    }) -Areas $areas) 'null coordinates are not silently turned into zero'
    Assert-Null (Get-SafeWindowPlacement -Saved ([pscustomobject]@{
        showCmd = 1; n = @($true, 20, 110, 120); mn = @(-1, -1); mx = @(-1, -1)
    }) -Areas $areas) 'boolean coordinates are not silently turned into numbers'
}

Test-Case 'windows: documented non-hiding show states remain available' {
    $areas = @([pscustomobject]@{ Device = 'MAIN'; Primary = $true; Left = 0; Top = 0; Right = 1920; Bottom = 1080
        WorkLeft = 0; WorkTop = 0; WorkRight = 1920; WorkBottom = 1040 })
    $saved = [pscustomobject]@{ showCmd = 7; n = @(100, 100, 900, 700); mn = @(-1, -1); mx = @(-1, -1) }

    Assert-Equal 7 (Get-SafeWindowPlacement -Saved $saved -Areas $areas).ShowCmd `
        'SW_SHOWMINNOACTIVE is preserved like other non-hiding ShowWindow states'
}

Test-Case 'windows: a valid rectangle on a negative-origin monitor is preserved' {
    $areas = @(
        [pscustomobject]@{ Device = 'LEFT'; Primary = $false; Left = -2560; Top = 0; Right = 0; Bottom = 1440
            WorkLeft = -2560; WorkTop = 0; WorkRight = 0; WorkBottom = 1400 }
        [pscustomobject]@{ Device = 'MAIN'; Primary = $true; Left = 0; Top = 0; Right = 2560; Bottom = 1440
            WorkLeft = 0; WorkTop = 0; WorkRight = 2560; WorkBottom = 1400 }
    )
    $saved = [pscustomobject]@{ showCmd = 1; n = @(-2300, 100, -1200, 900); mn = @(-1, -1); mx = @(-1, -1) }

    $safe = Get-SafeWindowPlacement -Saved $saved -Areas $areas

    Assert-Equal @(-2300, 100, -1200, 900) $safe.Normal 'negative virtual-screen coordinates are valid'
    Assert-Equal $false $safe.Adjusted 'the left monitor is not mistaken for an off-screen rectangle'
}

Test-Case 'windows: a secondary taskbar uses that monitor workspace without shifting the window' {
    $areas = @(
        [pscustomobject]@{ Device = 'LEFT'; Primary = $false; Left = -1920; Top = 0; Right = 0; Bottom = 1080
            WorkLeft = -1872; WorkTop = 0; WorkRight = 0; WorkBottom = 1080 }
        [pscustomobject]@{ Device = 'MAIN'; Primary = $true; Left = 0; Top = 0; Right = 1920; Bottom = 1080
            WorkLeft = 0; WorkTop = 0; WorkRight = 1920; WorkBottom = 1040 }
    )
    # GetWindowPlacement reports the left display's work-area edge as workspace X=-1920. Passing that
    # value back lets SetWindowPlacement add this monitor's 48-pixel appbar offset exactly once.
    $saved = [pscustomobject]@{ showCmd = 1; n = @(-1920, 40, -920, 740); mn = @(-1, -1); mx = @(-1, -1) }

    $safe = Get-SafeWindowPlacement -Saved $saved -Areas $areas

    Assert-Equal @(-1920, 40, -920, 740) $safe.Normal 'a secondary appbar does not add the primary offset'
    Assert-Equal $false $safe.Adjusted 'an edge-aligned secondary window remains exact'
}

Test-Case 'windows: a reachable window spanning two monitors remains exact' {
    $areas = @(
        [pscustomobject]@{ Device = 'MAIN'; Primary = $true; Left = 0; Top = 0; Right = 1920; Bottom = 1080
            WorkLeft = 0; WorkTop = 0; WorkRight = 1920; WorkBottom = 1040 }
        [pscustomobject]@{ Device = 'RIGHT'; Primary = $false; Left = 1920; Top = 0; Right = 3840; Bottom = 1080
            WorkLeft = 1920; WorkTop = 0; WorkRight = 3840; WorkBottom = 1080 }
    )
    $saved = [pscustomobject]@{ showCmd = 1; n = @(1400, 100, 2300, 800); mn = @(-1, -1); mx = @(-1, -1) }

    $safe = Get-SafeWindowPlacement -Saved $saved -Areas $areas

    Assert-Equal @(1400, 100, 2300, 800) $safe.Normal 'a visible title bar across the active desk needs no repair'
    Assert-Equal $false $safe.Adjusted 'an intentional spanning placement remains exact'
}

Test-Case 'windows: an oversized rectangle keeps its title at the work-area origin' {
    $areas = @([pscustomobject]@{
        Device = 'MAIN'; Primary = $true; Left = 0; Top = 0; Right = 1024; Bottom = 1024
        WorkLeft = 48; WorkTop = 36; WorkRight = 1024; WorkBottom = 1024
    })
    $saved = [pscustomobject]@{ showCmd = 3; n = @(2000, 2000, 4000, 3500); mn = @(-1, -1); mx = @(-1, -1) }

    $safe = Get-SafeWindowPlacement -Saved $saved -Areas $areas

    # Pinned to the work area itself, in the same virtual-screen frame the saved rectangle is in: the
    # usable band starts at (48,36), and that is where a window too large to fit has to begin.
    Assert-Equal @(48, 36, 2048, 1536) $safe.Normal 'oversized bounds are pinned with the title reachable'
    Assert-Equal 3 $safe.ShowCmd 'repairing normal bounds does not unmaximize the window'
}

Test-Case 'windows: the exact geometry variant wins and legacy data remains a safe fallback' {
    $wide = @([pscustomobject]@{ Device = 'MAIN'; Primary = $true; Left = 0; Top = 0; Right = 2560; Bottom = 1440
        WorkLeft = 0; WorkTop = 0; WorkRight = 2560; WorkBottom = 1400 })
    $square = @([pscustomobject]@{ Device = 'MAIN'; Primary = $true; Left = 0; Top = 0; Right = 1024; Bottom = 1024
        WorkLeft = 0; WorkTop = 0; WorkRight = 1024; WorkBottom = 984 })
    $wideRecord = [pscustomobject]@{ layout = 'path-a'; saved = '2026-09-11T10:00:00'; windows = @('wide') }
    $squareRecord = [pscustomobject]@{ layout = 'path-a'; saved = '2026-09-11T09:00:00'; windows = @('square') }
    $store = @{
        (Get-WindowSnapshotKey -LayoutKey 'path-a' -Areas $wide) = $wideRecord
        (Get-WindowSnapshotKey -LayoutKey 'path-a' -Areas $square) = $squareRecord
    }

    Assert-Equal 'square' (Get-WindowSnapshotRecord -Store $store -LayoutKey 'path-a' -Areas $square).windows[0] `
        'the matching resolution is selected even when another variant is newer'

    $legacy = [pscustomobject]@{ saved = '2026-08-30T12:00:00'; windows = @('legacy') }
    $store['path-a'] = $legacy
    $unknown = @([pscustomobject]@{ Device = 'MAIN'; Primary = $true; Left = 0; Top = 0; Right = 800; Bottom = 600
        WorkLeft = 0; WorkTop = 0; WorkRight = 800; WorkBottom = 560 })
    Assert-Equal 'wide' (Get-WindowSnapshotRecord -Store $store -LayoutKey 'path-a' -Areas $unknown).windows[0] `
        'a snapshot taken since the upgrade outranks the pre-upgrade record'

    Assert-Equal 'legacy' (Get-WindowSnapshotRecord -Store @{ 'path-a' = $legacy } -LayoutKey 'path-a' -Areas $unknown).windows[0] `
        'a pre-upgrade snapshot is still the fallback when nothing newer exists'
}

Test-Case 'windows: saving retires the pre-upgrade record and caps the variants per topology' {
    $areas = @([pscustomobject]@{ Device = 'MAIN'; Primary = $true; Left = 0; Top = 0; Right = 800; Bottom = 600
        WorkLeft = 0; WorkTop = 0; WorkRight = 800; WorkBottom = 560 })
    $store = @{ 'path-a' = [pscustomobject]@{ saved = '2020-01-01T00:00:00'; windows = @('legacy') } }
    for ($i = 0; $i -lt 5; $i++) {
        $key = 'v2:{0:d16}:path-a' -f $i
        $store[$key] = [pscustomobject]@{ layout = 'path-a'; saved = ('2026-09-0{0}T10:00:00' -f ($i + 1)); windows = @("v$i") }
    }
    $store['v2:aaaaaaaaaaaaaaaa:path-b'] = [pscustomobject]@{ layout = 'path-b'; saved = '2026-09-01T10:00:00'; windows = @('other') }
    Set-Content -Path $script:WindowStateFile -Value ($store | ConvertTo-Json -Depth 6) -Encoding UTF8

    function Get-WindowWorkAreas { return $areas }
    function Get-LiveWindows { return @([pscustomobject]@{ Hwnd = [IntPtr]7; Pid = 11; ShowCmd = 1
        NL = 0; NT = 0; NR = 400; NB = 300; MinX = -1; MinY = -1; MaxX = -1; MaxY = -1 }) }
    Save-WindowLayout -Key 'path-a'

    $back = Get-WindowStateStore
    Assert-Equal $false ($back.ContainsKey('path-a')) 'the superseded pre-upgrade record is retired'
    Assert-Equal 3 @($back.Keys | Where-Object { [string]$back[$_].layout -eq 'path-a' }).Count 'only the newest variants survive'
    Assert-True ($back.ContainsKey('v2:aaaaaaaaaaaaaaaa:path-b')) 'another topology is left alone'
    Remove-Item -LiteralPath $script:WindowStateFile -Force
}
