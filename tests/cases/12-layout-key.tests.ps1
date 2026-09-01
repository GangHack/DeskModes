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
