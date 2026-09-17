<#
    WindowLayout.ps1 — windows remember where they sat for every desk layout.

    Changing the set of monitors moves windows around, and Windows never puts
    them back — that is a limitation of the system. Taking a snapshot before the
    desk is rebuilt and restoring it afterwards, however, works fine.

    Dot-sourced from the entry points (Displays.ps1, Set-Display.ps1) and NOT
    from DisplayCore.ps1: core stays "definitions only" and knows nothing about
    windows. Switch-DisplayMode calls these functions only when they are defined,
    which is why core works without this file at all.

    The snapshot key is the DESK layout, not the mode name: the sorted device
    paths of the active monitors, joined with '|'. Two different modes with the
    same set of screens (until the ASUS is plugged in, "both LGs" and "all" are
    one and the same set) have to share one snapshot, or windows would come back
    only every other time.

    The store is window-state.json next to the scripts. HWNDs are valid for one
    Windows logon and are the same for every process, so a snapshot taken from
    the CLI serves the tray and the other way round. On tray startup, entries
    whose processes are all dead are swept out.
#>

$script:WindowStateFile = Join-Path $PSScriptRoot 'window-state.json'

# The desk-layout key from the monitor state (or from a ready list of paths).
function Get-DisplayLayoutKey {
    param($State, [string[]]$DevicePaths)

    $paths = $DevicePaths
    if (-not $paths) {
        $paths = @($State | Where-Object { $_.Active } | ForEach-Object { $_.Id })
    }
    $clean = @($paths | Where-Object { $_ } | Sort-Object)
    if ($clean.Count -eq 0) { return '' }
    return ($clean -join '|')
}

# WINDOWPLACEMENT rectangles use workspace coordinates. Screen bounds and working areas use virtual-screen
# coordinates, and each monitor can have its own appbar offset. The conversion below keeps enough geometry
# to validate a saved placement in the workspace that Windows will use for that monitor.
# How many geometry variants of one topology are worth keeping. Enough that moving between a couple of
# regular resolutions still hits an exact key; small enough that the file, which is parsed and rewritten
# on every switch, cannot accumulate a record for every arrangement the desk has ever been in.
$script:WindowSnapshotVariantCap = 3

function Get-WindowWorkAreas {
    $out = @()
    foreach ($screen in @([System.Windows.Forms.Screen]::AllScreens)) {
        $out += [pscustomobject]@{
            Device     = [string]$screen.DeviceName
            Primary    = [bool]$screen.Primary
            Left       = [int]$screen.Bounds.Left
            Top        = [int]$screen.Bounds.Top
            Right      = [int]$screen.Bounds.Right
            Bottom     = [int]$screen.Bounds.Bottom
            WorkLeft   = [int]$screen.WorkingArea.Left
            WorkTop    = [int]$screen.WorkingArea.Top
            WorkRight  = [int]$screen.WorkingArea.Right
            WorkBottom = [int]$screen.WorkingArea.Bottom
        }
    }
    return $out
}

# The public layout key remains a topology identity. Window snapshots add the current monitor and work-area
# geometry so 2560x1440 and 1024x1024 do not overwrite each other merely because the same panel is active.
function Get-WindowSnapshotKey {
    param([Parameter(Mandatory)][string]$LayoutKey, [Parameter(Mandatory)]$Areas)

    $parts = @($Areas | Sort-Object Device, Left, Top | ForEach-Object {
        '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}' -f [string]$_.Device, [bool]$_.Primary,
            [int]$_.Left, [int]$_.Top, [int]$_.Right, [int]$_.Bottom,
            [int]$_.WorkLeft, [int]$_.WorkTop, [int]$_.WorkRight, [int]$_.WorkBottom
    })
    if ($parts.Count -eq 0) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($parts -join '|'))
        $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
    return ('v2:{0}:{1}' -f $hash.Substring(0, 16), $LayoutKey)
}

function Get-WindowSnapshotRecord {
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$LayoutKey,
          [Parameter(Mandatory)]$Areas)

    $exactKey = Get-WindowSnapshotKey -LayoutKey $LayoutKey -Areas $Areas
    if ($exactKey -and $Store.ContainsKey($exactKey)) { return $Store[$exactKey] }
    # On the first visit to a new resolution, use the newest variant for this topology as a starting
    # point. It cannot be applied raw: Get-SafeWindowPlacement below clamps every rectangle first.
    $variants = @($Store.Values | Where-Object { [string]$_.layout -eq $LayoutKey } |
                  Sort-Object { try { [datetime]$_.saved } catch { [datetime]::MinValue } } -Descending)
    if ($variants.Count -gt 0) { return $variants[0] }
    # Last: a pre-geometry record, which carries no layout field and so can never appear among the
    # variants above. It is only ever a starting point for the first switch after upgrading, and
    # Save-WindowLayout retires it on the next save - it must not outrank a snapshot taken since.
    if ($Store.ContainsKey($LayoutKey)) { return $Store[$LayoutKey] }
    return $null
}

# Validate one stored WINDOWPLACEMENT and make its normal rectangle reachable in the current work area.
# The show state is deliberately retained: a window minimized by its owner stays minimized, while its
# normal rectangle becomes usable when the owner restores it from the taskbar.
function Get-SafeWindowPlacement {
    param([Parameter(Mandatory)]$Saved, [Parameter(Mandatory)]$Areas)

    # Every work area, as Get-WindowWorkAreas reports it: virtual-screen coordinates, the same frame the
    # saved rectangles are in. An earlier version subtracted each monitor's own appbar inset here, which
    # cancels to the monitor's screen origin carrying the work area's size - correct only where there is
    # no left or top appbar, and off by the taskbar's thickness everywhere else.
    $areasList = @($Areas | Where-Object {
        [int]$_.WorkRight -gt [int]$_.WorkLeft -and [int]$_.WorkBottom -gt [int]$_.WorkTop
    } | ForEach-Object {
        [pscustomobject]@{
            Left   = [int]$_.WorkLeft
            Top    = [int]$_.WorkTop
            Right  = [int]$_.WorkRight
            Bottom = [int]$_.WorkBottom
        }
    })
    $n = @($Saved.n); $mn = @($Saved.mn); $mx = @($Saved.mx)
    if ($areasList.Count -eq 0 -or $n.Count -ne 4 -or $mn.Count -ne 2 -or $mx.Count -ne 2) { return $null }
    $parsed = @()
    foreach ($value in @($Saved.showCmd) + $n + $mn + $mx) {
        if ($null -eq $value -or $value -is [bool] -or $value -is [array]) { return $null }
        $number = 0
        if (-not [int]::TryParse([string]$value, [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
        $parsed += $number
    }
    $show = $parsed[0]
    $left = $parsed[1]; $top = $parsed[2]; $right = $parsed[3]; $bottom = $parsed[4]
    $minX = $parsed[5]; $minY = $parsed[6]; $maxX = $parsed[7]; $maxY = $parsed[8]
    # SW_HIDE cannot be captured from the visible windows we enumerate. The other documented ShowWindow
    # values remain valid input to SetWindowPlacement, including the non-activating minimized variants.
    if ($show -lt 1 -or $show -gt 11 -or $right -le $left -or $bottom -le $top) { return $null }

    $width = $right - $left; $height = $bottom - $top
    $titleWidth = [Math]::Min(64, $width)
    $titleHeight = [Math]::Min(32, $height)
    foreach ($area in $areasList) {
        $titleOverlapWidth = [Math]::Max(0, [Math]::Min($right, [int]$area.Right) -
                                              [Math]::Max($left, [int]$area.Left))
        $titleOverlapHeight = [Math]::Max(0, [Math]::Min($top + $titleHeight, [int]$area.Bottom) -
                                               [Math]::Max($top, [int]$area.Top))
        if ($titleOverlapWidth -ge $titleWidth -and $titleOverlapHeight -ge $titleHeight) {
            return [pscustomobject]@{
                ShowCmd = $show; Normal = @($left, $top, $right, $bottom)
                Min = @($minX, $minY); Max = @($maxX, $maxY); Adjusted = $false
            }
        }
    }

    $best = $null; $bestOverlap = -1L; $bestDistance = [double]::PositiveInfinity
    $cx = ([double]$left + [double]$right) / 2
    $cy = ([double]$top + [double]$bottom) / 2
    foreach ($area in $areasList) {
        $iw = [Math]::Max(0, [Math]::Min($right, [int]$area.Right) -
                              [Math]::Max($left, [int]$area.Left))
        $ih = [Math]::Max(0, [Math]::Min($bottom, [int]$area.Bottom) -
                              [Math]::Max($top, [int]$area.Top))
        $overlap = [int64]$iw * [int64]$ih
        $ax = ([double][int]$area.Left + [double][int]$area.Right) / 2
        $ay = ([double][int]$area.Top + [double][int]$area.Bottom) / 2
        $distance = (($cx - $ax) * ($cx - $ax)) + (($cy - $ay) * ($cy - $ay))
        if ($overlap -gt $bestOverlap -or ($overlap -eq $bestOverlap -and $distance -lt $bestDistance)) {
            $best = $area; $bestOverlap = $overlap; $bestDistance = $distance
        }
    }
    if (-not $best) { return $null }

    $workWidth = [int]$best.Right - [int]$best.Left
    $workHeight = [int]$best.Bottom - [int]$best.Top
    $safeLeft = $(if ($width -ge $workWidth) { [int]$best.Left } else {
        [Math]::Min([Math]::Max($left, [int]$best.Left), [int]$best.Right - $width) })
    $safeTop = $(if ($height -ge $workHeight) { [int]$best.Top } else {
        [Math]::Min([Math]::Max($top, [int]$best.Top), [int]$best.Bottom - $height) })
    $adjusted = ($safeLeft -ne $left -or $safeTop -ne $top)

    return [pscustomobject]@{
        ShowCmd = $show
        Normal  = @($safeLeft, $safeTop, ($safeLeft + $width), ($safeTop + $height))
        Min     = @($minX, $minY)
        Max     = @($maxX, $maxY)
        Adjusted = $adjusted
    }
}

function Get-WindowStateStore {
    if (-not (Test-Path $script:WindowStateFile)) { return @{} }
    try {
        $raw = Get-Content $script:WindowStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $store = @{}
        foreach ($p in $raw.PSObject.Properties) { $store[$p.Name] = $p.Value }
        return $store
    }
    catch {
        # A damaged file is a nuisance, not a breakage: the snapshots build up
        # again over one switch. Settings keep a copy in this situation; here
        # that is not needed.
        Write-DisplayLog "windows: state file is damaged, starting over - $($_.Exception.Message)"
        return @{}
    }
}

function Save-WindowStateStore {
    param($Store)
    try {
        # -ErrorAction Stop because a refusal from Set-Content is a NON-terminating error: without it the
        # catch never fires, this returns $true, and the caller writes "windows: saved 34" about a file
        # that was not written. It is not covered by the entry points setting $ErrorActionPreference to
        # Stop either — the next caller of this file need not do that, and core deliberately does not.
        $Store | ConvertTo-Json -Depth 6 -Compress |
            Set-Content -Path $script:WindowStateFile -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch {
        Write-DisplayLog "warn: windows - could not write the state file: $($_.Exception.Message)"
        return $false
    }
}

# Snapshot where every ordinary window sits and remember it under the layout key.
function Save-WindowLayout {
    param([Parameter(Mandatory)][string]$Key)

    if (-not $Key) { Write-DisplayLog 'warn: windows - no layout key, nothing saved'; return }

    try {
        $wins = @([NativeWindows]::Enumerate())
    }
    catch {
        Write-DisplayLog "warn: windows - could not enumerate: $($_.Exception.Message)"
        return
    }
    if ($wins.Count -eq 0) { Write-DisplayLog 'windows: nothing to save, no ordinary windows on the desktop'; return }

    # Exactly what Restore-WindowLayout reads back and not a field more. A window title and the full path
    # to its executable used to be written here as well, and nothing ever read them: the store is not a
    # diary, and a title holds the document you have open. The gathering is gone too (see WinInfo in
    # DisplayCore.ps1) — a promise that titles are never read is kept where the read would be.
    $list = @()
    foreach ($w in $wins) {
        $list += [ordered]@{
            hwnd    = [int64]$w.Hwnd
            pid     = $w.Pid
            showCmd = $w.ShowCmd
            n       = @($w.NL, $w.NT, $w.NR, $w.NB)
            mn      = @($w.MinX, $w.MinY)
            mx      = @($w.MaxX, $w.MaxY)
        }
    }

    $areas = @(Get-WindowWorkAreas)
    $snapshotKey = Get-WindowSnapshotKey -LayoutKey $Key -Areas $areas
    if (-not $snapshotKey) { Write-DisplayLog 'warn: windows - no work areas, nothing saved'; return }
    $store = Get-WindowStateStore
    $store[$snapshotKey] = [ordered]@{
        layout  = $Key
        saved   = (Get-Date).ToString('s')
        windows = $list
    }
    # The pre-geometry record for this topology has now been superseded by a real one. Leaving it would
    # keep a months-old arrangement as the permanent fallback for every geometry this desk ever visits.
    if ($store.ContainsKey($Key)) { [void]$store.Remove($Key) }
    # One record per geometry means a new one for every resolution, scaling or taskbar change, and the
    # only other sweep drops an entry solely when every pid in it is dead - which inside one logon
    # session is never. Keep the few newest for this topology so the file cannot grow without end.
    $mine = @($store.Keys | Where-Object { [string]$store[$_].layout -eq $Key } |
              Sort-Object { try { [datetime]$store[$_].saved } catch { [datetime]::MinValue } } -Descending)
    if ($mine.Count -gt $script:WindowSnapshotVariantCap) {
        foreach ($stale in @($mine | Select-Object -Skip $script:WindowSnapshotVariantCap)) {
            [void]$store.Remove($stale)
        }
    }
    if (Save-WindowStateStore $store) {
        Write-DisplayLog ("windows: saved {0} for {1}" -f $list.Count, (Format-LayoutKey $Key))
    }
}

# Put the windows back where this layout remembered them.
function Restore-WindowLayout {
    param([Parameter(Mandatory)][string]$Key)

    if (-not $Key) { Write-DisplayLog 'warn: windows - no layout key, nothing restored'; return }

    $areas = @(Get-WindowWorkAreas)
    $store = Get-WindowStateStore
    $snapshot = Get-WindowSnapshotRecord -Store $store -LayoutKey $Key -Areas $areas
    if (-not $snapshot) {
        # Not an error: this layout has not been seen yet. The snapshot appears
        # when the desk is left for another one.
        Write-DisplayLog ("windows: no snapshot for {0} yet" -f (Format-LayoutKey $Key))
        return
    }

    $saved = @($snapshot.windows)
    if ($saved.Count -eq 0) { Write-DisplayLog 'windows: snapshot is empty'; return }

    $done = 0
    $gone = 0
    $refused = 0
    $adjusted = 0
    foreach ($w in $saved) {
        # One damaged JSON row must not abort restoration of every healthy window behind it.
        $handle = 0L; $processId = 0
        if ($null -eq $w.hwnd -or $null -eq $w.pid -or $w.hwnd -is [bool] -or $w.pid -is [bool] -or
            -not [int64]::TryParse([string]$w.hwnd, [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$handle) -or
            -not [int]::TryParse([string]$w.pid, [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$processId) -or
            $handle -le 0 -or $processId -le 0) { $refused++; continue }
        $h = [IntPtr]$handle
        # Is the window alive, and is it the same window. HWNDs get reused: the
        # system can hand a closed window's number to another one, so IsWindow
        # alone is not enough — we check the process too. Otherwise a Firefox
        # snapshot would one day move a stranger's window that landed on that number.
        if (-not [NativeWindows]::IsWindow($h)) { $gone++; continue }
        if ([NativeWindows]::PidOfWindow($h) -ne $processId) { $gone++; continue }

        $safe = Get-SafeWindowPlacement -Saved $w -Areas $areas
        if (-not $safe) { $refused++; continue }
        $n = @($safe.Normal); $mn = @($safe.Min); $mx = @($safe.Max)
        $ok = $false
        try {
            $ok = [NativeWindows]::ApplyPlacement($h, [int]$safe.ShowCmd,
                    [int]$n[0], [int]$n[1], [int]$n[2], [int]$n[3],
                    [int]$mn[0], [int]$mn[1], [int]$mx[0], [int]$mx[1])
        }
        catch { $ok = $false }
        if ($ok) { $done++; if ($safe.Adjusted) { $adjusted++ } } else { $refused++ }
    }

    # Count honestly: how many came back out of how many, and how many windows are
    # gone. Refusals (the window is alive but SetWindowPlacement would not let us
    # move it — that happens to windows with rights above ours) are shown separately,
    # so it does not read as "vanished".
    $line = "windows: restored {0} of {1}" -f $done, $saved.Count
    $tail = @()
    if ($gone -gt 0)    { $tail += "$gone gone" }
    if ($refused -gt 0) { $tail += "$refused refused" }
    if ($adjusted -gt 0) { $tail += "$adjusted moved into a work area" }
    if ($tail.Count -gt 0) { $line += ' (' + ($tail -join ', ') + ')' }
    Write-DisplayLog $line
}

# The key in the log is three long device paths; unreadable. For the log we shorten
# it to the number of screens — the key itself is in the json anyway.
function Format-LayoutKey {
    param([string]$Key)
    if (-not $Key) { return '(none)' }
    $n = @($Key -split '\|').Count
    return ("a {0}-display layout" -f $n)
}

# Entries whose every process is already dead are worth nothing: an HWND from a
# previous Windows logon means nothing. Called on tray startup.
#
# The same pass throws out the window titles and executable paths an older version wrote here. It is not
# enough to stop writing them: a snapshot is only rewritten when its own desk is left, so the layouts a
# person visits rarely would have kept their titles for as long as the file lived — and the tool promises
# that titles are not kept. One sweep, on the first start after the upgrade, and they are gone.
function Remove-DeadWindowLayouts {
    if (-not (Test-Path $script:WindowStateFile)) { return }

    $store = Get-WindowStateStore
    if ($store.Count -eq 0) { return }

    $alive = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $alive[$p.Id] = $true }

    $dropped = 0
    $scrubbed = 0
    foreach ($key in @($store.Keys)) {
        $wins = @($store[$key].windows)
        $live = @($wins | Where-Object { $alive.ContainsKey([int]$_.pid) })
        if ($live.Count -eq 0) { $store.Remove($key); $dropped++; continue }

        # Fields we no longer write. Rebuilt rather than edited in place: what comes back from
        # ConvertFrom-Json is a PSCustomObject, and the store is written straight back out as it stands.
        $old = @($wins | Where-Object { $_.PSObject.Properties.Name -contains 'title' -or
                                        $_.PSObject.Properties.Name -contains 'path' })
        if ($old.Count -eq 0) { continue }
        $clean = [ordered]@{}
        foreach ($field in 'layout', 'saved') {
            if ($store[$key].PSObject.Properties.Name -contains $field) { $clean[$field] = $store[$key].$field }
        }
        $clean.windows = @($wins | ForEach-Object {
                [ordered]@{
                    hwnd    = [int64]$_.hwnd
                    pid     = [int]$_.pid
                    showCmd = [int]$_.showCmd
                    n       = @($_.n)
                    mn      = @($_.mn)
                    mx      = @($_.mx)
                }
            })
        $store[$key] = $clean
        $scrubbed++
    }
    if ($dropped -gt 0 -or $scrubbed -gt 0) {
        [void](Save-WindowStateStore $store)
        if ($dropped -gt 0) {
            Write-DisplayLog ("windows: dropped {0} stale snapshot(s) from a previous session" -f $dropped)
        }
        if ($scrubbed -gt 0) {
            Write-DisplayLog ("windows: cleared window titles an older version left in {0} snapshot(s)" -f $scrubbed)
        }
    }
}
