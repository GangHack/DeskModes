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

Test-Case 'desktop subset: the trusted current desk wins over a smaller stale superset' {
    $current = @(
        (New-FakeMonitor 'A' 'AAA0001' 'path-a')
        (New-FakeMonitor 'B' 'BBB0001' 'path-b')
        (New-FakeMonitor 'C' 'CCC0001' 'path-c')
    )
    for ($i = 0; $i -lt $current.Count; $i++) {
        $current[$i].Primary = ($i -eq 0)
        $current[$i].X = $i * 1920
    }
    $current[0].Width = 1080; $current[0].Height = 1920; $current[0].Rotation = 4
    $current[0].Hz = 75; $current[0].RateNum = 75; $current[0].RateDen = 1
    $currentSnapshot = New-DesktopSnapshot -State $current
    $stale = @(
        (New-FakeMonitor 'A' 'AAA0001' 'path-a')
        (New-FakeMonitor 'B' 'BBB0001' 'path-b')
    )
    $stale[0].Primary = $true; $stale[1].Primary = $false; $stale[1].X = 1920
    $store = New-DesktopSnapshotStore
    $saved = New-DesktopSnapshot -State $stale
    $store.Snapshots[$saved.Key] = $saved

    $subset = New-DesktopSubsetSnapshot -Wanted @($current[0]) -CurrentSnapshot $currentSnapshot -Store $store

    Assert-Equal 4 $subset.Displays[0].Rotation 'the recent portrait observation wins'
    Assert-Equal 75 $subset.Displays[0].Hz 'and so does its recent physical rate'
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

Test-Case 'full config: duplicate requested paths are refused before an attempt can mutate Windows' {
    $script:FullCalls = 0
    function Invoke-CcdFullConfigAttempt { param($Targets, $PrimaryPath, $Order, [switch]$WithHz, [switch]$Exact) $script:FullCalls++; return $true }
    $targets = @(
        [pscustomobject]@{ DevicePath = 'path-a'; Label = 'A'; Width = 1920; Height = 1080; Hz = 60; RateNum = 60; RateDen = 1; Rotation = 1; X = 0; Y = 0 }
        [pscustomobject]@{ DevicePath = 'path-a'; Label = 'A again'; Width = 1920; Height = 1080; Hz = 60; RateNum = 60; RateDen = 1; Rotation = 1; X = 1920; Y = 0 }
    )

    Assert-True (-not (Set-CcdFullConfig -Targets $targets -PrimaryPath 'path-a' -Exact)) 'an incomplete unique set is rejected'
    Assert-Equal 0 $script:FullCalls 'the lower apply layer was never reached'
}

Test-Case 'rule match: overlapping names find a unique assignment in either pattern order' {
    $connected = @(
        [pscustomobject]@{ Label = 'LG ULTRAGEAR'; ShortId = 'GSM1111' }
        [pscustomobject]@{ Label = 'LG ULTRAFINE'; ShortId = 'GSM2222' }
    )

    Assert-True (Test-DisplaySetMatch -Patterns @('LG', 'ULTRAGEAR') -Connected $connected) 'the broad pattern can move to the other display'
    Assert-True (Test-DisplaySetMatch -Patterns @('ULTRAGEAR', 'LG') -Connected $connected) 'pattern order does not change the result'
}

Test-Case 'native boundary: incomplete CCD and unsettled layout requests never report success' {
    $fixture = Join-Path (Split-Path $PSScriptRoot -Parent) 'native-engine-fixture.ps1'
    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixture 2>&1)

    Assert-Equal 0 $LASTEXITCODE 'the isolated fake-native process passed'
    Assert-True (($output -join "`n") -like '*native engine fixture passed*') 'the boundary assertions all ran'
}
