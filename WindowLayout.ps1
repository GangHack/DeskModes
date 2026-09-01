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
        $Store | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $script:WindowStateFile -Encoding UTF8
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

    $list = @()
    foreach ($w in $wins) {
        $list += [ordered]@{
            hwnd    = [int64]$w.Hwnd
            pid     = $w.Pid
            path    = $w.Path
            title   = $w.Title
            showCmd = $w.ShowCmd
            n       = @($w.NL, $w.NT, $w.NR, $w.NB)
            mn      = @($w.MinX, $w.MinY)
            mx      = @($w.MaxX, $w.MaxY)
        }
    }

    $store = Get-WindowStateStore
    $store[$Key] = [ordered]@{
        saved   = (Get-Date).ToString('s')
        windows = $list
    }
    if (Save-WindowStateStore $store) {
        Write-DisplayLog ("windows: saved {0} for {1}" -f $list.Count, (Format-LayoutKey $Key))
    }
}

# Put the windows back where this layout remembered them.
function Restore-WindowLayout {
    param([Parameter(Mandatory)][string]$Key)

    if (-not $Key) { Write-DisplayLog 'warn: windows - no layout key, nothing restored'; return }

    $store = Get-WindowStateStore
    if (-not $store.ContainsKey($Key)) {
        # Not an error: this layout has not been seen yet. The snapshot appears
        # when the desk is left for another one.
        Write-DisplayLog ("windows: no snapshot for {0} yet" -f (Format-LayoutKey $Key))
        return
    }

    $saved = @($store[$Key].windows)
    if ($saved.Count -eq 0) { Write-DisplayLog 'windows: snapshot is empty'; return }

    $done = 0
    $gone = 0
    $refused = 0
    foreach ($w in $saved) {
        $h = [IntPtr][int64]$w.hwnd
        # Is the window alive, and is it the same window. HWNDs get reused: the
        # system can hand a closed window's number to another one, so IsWindow
        # alone is not enough — we check the process too. Otherwise a Firefox
        # snapshot would one day move a stranger's window that landed on that number.
        if (-not [NativeWindows]::IsWindow($h)) { $gone++; continue }
        if ([NativeWindows]::PidOfWindow($h) -ne [int]$w.pid) { $gone++; continue }

        $n = @($w.n); $mn = @($w.mn); $mx = @($w.mx)
        $ok = $false
        try {
            $ok = [NativeWindows]::ApplyPlacement($h, [int]$w.showCmd,
                    [int]$n[0], [int]$n[1], [int]$n[2], [int]$n[3],
                    [int]$mn[0], [int]$mn[1], [int]$mx[0], [int]$mx[1])
        }
        catch { $ok = $false }
        if ($ok) { $done++ } else { $refused++ }
    }

    # Count honestly: how many came back out of how many, and how many windows are
    # gone. Refusals (the window is alive but SetWindowPlacement would not let us
    # move it — that happens to windows with rights above ours) are shown separately,
    # so it does not read as "vanished".
    $line = "windows: restored {0} of {1}" -f $done, $saved.Count
    $tail = @()
    if ($gone -gt 0)    { $tail += "$gone gone" }
    if ($refused -gt 0) { $tail += "$refused refused" }
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
function Remove-DeadWindowLayouts {
    if (-not (Test-Path $script:WindowStateFile)) { return }

    $store = Get-WindowStateStore
    if ($store.Count -eq 0) { return }

    $alive = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $alive[$p.Id] = $true }

    $dropped = 0
    foreach ($key in @($store.Keys)) {
        $wins = @($store[$key].windows)
        $live = @($wins | Where-Object { $alive.ContainsKey([int]$_.pid) })
        if ($live.Count -eq 0) { $store.Remove($key); $dropped++ }
    }
    if ($dropped -gt 0) {
        [void](Save-WindowStateStore $store)
        Write-DisplayLog ("windows: dropped {0} stale snapshot(s) from a previous session" -f $dropped)
    }
}
