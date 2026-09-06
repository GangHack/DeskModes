# --- audited engine safety regressions --------------------------------------
# These cases keep failed or deliberately transient desktop state from becoming a new source of truth.
# Every hardware-facing function is shadowed; no case below asks Windows to change a display.

Write-Host ''
Write-Host 'audited engine safety regressions' -ForegroundColor White

Test-Case 'desktop subset: unrelated solo snapshots cannot invent a coherent larger desk' {
    $a = New-FakeMonitor 'A' 'AAA0001' 'path-a'
    $b = New-FakeMonitor 'B' 'BBB0001' 'path-b'
    $a.Primary = $true; $b.Primary = $true
    $store = New-DesktopSnapshotStore
    $sa = New-DesktopSnapshot -State @($a)
    $sb = New-DesktopSnapshot -State @($b)
    $store.Snapshots[$sa.Key] = $sa
    $store.Snapshots[$sb.Key] = $sb

    $subset = New-DesktopSubsetSnapshot -Wanted @($a, $b) -CurrentSnapshot $sb -Store $store

    Assert-Null $subset 'two unrelated origins are not a physical two-display arrangement'
}

Test-Case 'desktop subset: one trusted superset supplies every relative coordinate' {
    $a = New-FakeMonitor 'A' 'AAA0001' 'path-a'
    $b = New-FakeMonitor 'B' 'BBB0001' 'path-b'
    $a.Primary = $true; $a.X = 0
    $b.Primary = $false; $b.X = 1920
    $source = New-DesktopSnapshot -State @($a, $b)
    $store = New-DesktopSnapshotStore
    $store.Snapshots[$source.Key] = $source

    $subset = New-DesktopSubsetSnapshot -Wanted @($b) -CurrentSnapshot $null -Store $store

    Assert-Equal 1920 $subset.Displays[0].X 'the record came from the coherent larger desk'
}

Test-Case 'desktop subset: an unsafe superset is not a source for a new destination' {
    $a = New-FakeMonitor 'A' 'AAA0001' 'path-a'
    $b = New-FakeMonitor 'B' 'BBB0001' 'path-b'
    $a.Primary = $true; $b.Primary = $false; $b.X = 1920
    $desk = @($a, $b)
    $source = New-DesktopSnapshot -State $desk
    $store = New-DesktopSnapshotStore
    $store.Snapshots[$source.Key] = $source
    $store.UnsafeKeys[$source.Key] = $true

    $subset = New-DesktopSubsetSnapshot -Wanted @($desk[1]) -CurrentSnapshot $null -Store $store

    Assert-Null $subset 'unverified geometry is not copied into another set'
}

Test-Case 'watchdog: a pending active desktop is never repaired from BestMode' {
    Remove-Item $script:DesktopSnapshotsFile -Force -ErrorAction SilentlyContinue
    $m = New-FakeMonitor 'A' 'AAA0001' 'path-a'
    $m.Primary = $true
    $m.Hz = 60; $m.RateNum = 60; $m.RateDen = 1
    $m.BestMode = [pscustomobject]@{ Width = $m.Width; Height = $m.Height; Hz = 144 }
    $snapshot = New-DesktopSnapshot -State @($m)
    $store = New-DesktopSnapshotStore
    $store.Snapshots[$snapshot.Key] = $snapshot
    $store.PendingKey = $snapshot.Key
    $store.UnsafeKeys[$snapshot.Key] = $true
    Write-DesktopSnapshotStore -Store $store
    $script:WatchWrites = @()
    $script:LastRestore = [datetime]::MinValue
    function Get-DisplayState { return @($m) }
    function Test-FullscreenApp { return $false }
    function Get-CurrentMode { param([string]$Output) return [pscustomobject]@{ Width = $m.Width; Height = $m.Height; Hz = 60 } }
    function Set-BestModeFor { param($Output, $Label, $NativeWidth, $NativeHeight, $Best) $script:WatchWrites += $Best; return $true }

    [void](Restore-BestModes -DebounceMs 0)

    Assert-Equal 0 $script:WatchWrites.Count 'an unverified exact destination is left untouched'
}

Test-Case 'watchdog: a KeepMode protection snapshot survives disk and prevents a stale baseline repair' {
    Remove-Item $script:DesktopSnapshotsFile -Force -ErrorAction SilentlyContinue
    $m = New-FakeMonitor 'A' 'AAA0001' 'path-a'
    $m.Primary = $true
    $m.Hz = 75; $m.RateNum = 75; $m.RateDen = 1
    $baseline = New-DesktopSnapshot -State @($m)
    $m.Hz = 120; $m.RateNum = 120000; $m.RateDen = 1000
    $actual = New-DesktopSnapshot -State @($m)
    $m.BestMode = [pscustomobject]@{ Width = $m.Width; Height = $m.Height; Hz = 144 }
    $store = New-DesktopSnapshotStore
    $store.Snapshots[$baseline.Key] = $baseline
    $store.ProtectedKey = $baseline.Key
    $store.ProtectedSnapshot = $actual
    Write-DesktopSnapshotStore -Store $store
    $script:WatchWrites = @()
    $script:LastRestore = [datetime]::MinValue
    function Get-DisplayState { return @($m) }
    function Test-FullscreenApp { return $false }
    function Get-CurrentMode { param([string]$Output) return [pscustomobject]@{ Width = $m.Width; Height = $m.Height; Hz = 120 } }
    function Set-BestModeFor { param($Output, $Label, $NativeWidth, $NativeHeight, $Best) $script:WatchWrites += $Best; return $true }

    $back = Read-DesktopSnapshotStore
    [void](Restore-BestModes -DebounceMs 0)

    Assert-Equal 120 $back.ProtectedSnapshot.Displays[0].Hz 'a separate process reads the applied protection'
    Assert-Equal 0 $script:WatchWrites.Count 'the canonical 75 Hz baseline does not undo KeepMode'
}
