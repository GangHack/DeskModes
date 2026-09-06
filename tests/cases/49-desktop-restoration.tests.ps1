# --- exact physical desktop restoration ------------------------------------
# A display set is more than which panels are lit. Rotation, coordinates, primary assignment and the
# driver's exact refresh fraction are all observable parts of the desk, and Windows is allowed to change
# every one of them while another set is active.

Write-Host ''
Write-Host 'exact physical desktop restoration' -ForegroundColor White

function New-RestorationDesk {
    $left = New-FakeMonitor 'ACER XV272U' 'ACR1234' 'path-left'
    $left.X = -2560; $left.Y = 120; $left.Primary = $false
    $left.Width = 2560; $left.Height = 1440
    $left.Rotation = 1; $left.RateNum = 143999; $left.RateDen = 1000

    $primary = New-FakeMonitor 'ACER XV272U' 'ACR1234' 'path-primary'
    $primary.X = 0; $primary.Y = 0; $primary.Primary = $true
    $primary.Width = 2560; $primary.Height = 1440
    $primary.Rotation = 1; $primary.RateNum = 165000; $primary.RateDen = 1000

    $portrait = New-FakeMonitor 'SAMSUNG LF22T35' 'SAM5678' 'path-portrait'
    $portrait.X = 2560; $portrait.Y = -180; $portrait.Primary = $false
    $portrait.Width = 1080; $portrait.Height = 1920; $portrait.Hz = 75
    $portrait.Rotation = 4; $portrait.RateNum = 75; $portrait.RateDen = 1
    return @($left, $primary, $portrait)
}

Test-Case 'desktop snapshot: every physical display property survives capture' {
    $snapshot = New-DesktopSnapshot -State (New-RestorationDesk)

    Assert-True ($null -ne $snapshot) 'the complete desk can be captured'
    Assert-Equal 'path-primary' $snapshot.PrimaryId 'primary is an identity, not an output number'
    $samsung = @($snapshot.Displays | Where-Object { $_.Id -eq 'path-portrait' })[0]
    Assert-Equal 2560 $samsung.X 'horizontal coordinate'
    Assert-Equal (-180) $samsung.Y 'vertical coordinate'
    Assert-Equal 4 $samsung.Rotation 'portrait flipped rotation'
    Assert-Equal 1080 $samsung.Width 'portrait width'
    Assert-Equal 1920 $samsung.Height 'portrait height'
    Assert-Equal 75 $samsung.RateNum 'exact refresh numerator'
    Assert-Equal 1 $samsung.RateDen 'exact refresh denominator'
}

Test-Case 'desktop snapshot: an incomplete reading is never accepted as a baseline' {
    $desk = New-RestorationDesk
    $desk[2].RateDen = 0
    Assert-Null (New-DesktopSnapshot -State $desk) 'a missing exact rate rejects the whole snapshot'

    $desk = New-RestorationDesk
    $desk[1].Primary = $false
    Assert-Null (New-DesktopSnapshot -State $desk) 'a desk without one primary is transient, not a baseline'
}

Test-Case 'desktop snapshot store: exact layouts survive disk and damaged bytes are harmless' {
    Remove-Item $script:DesktopSnapshotsFile -Force -ErrorAction SilentlyContinue
    $snapshot = New-DesktopSnapshot -State (New-RestorationDesk)
    $store = New-DesktopSnapshotStore
    $store.Snapshots[$snapshot.Key] = $snapshot
    $store.ProtectedKey = $snapshot.Key
    $store.PendingKey = 'another-set'
    $store.UnsafeKeys['another-set'] = $true
    Write-DesktopSnapshotStore -Store $store

    $back = Read-DesktopSnapshotStore
    Assert-Equal 1 @($back.Snapshots.Keys).Count 'one snapshot returned'
    Assert-Equal $snapshot.Key $back.ProtectedKey 'watchdog protection survived'
    Assert-Equal 'another-set' $back.PendingKey 'an interrupted destination remains guarded'
    Assert-True $back.UnsafeKeys.ContainsKey('another-set') 'failed sets survive independently of the current pending set'
    Assert-Equal 4 $back.Snapshots[$snapshot.Key].Displays[2].Rotation 'rotation survived JSON'

    Set-Content -Path $script:DesktopSnapshotsFile -Value '{not json' -Encoding UTF8
    Assert-Equal 0 @((Read-DesktopSnapshotStore).Snapshots.Keys).Count 'damaged state reads as empty'

    Set-Content -Path $script:DesktopSnapshotsFile -Encoding UTF8 `
        -Value '{"version":1,"snapshots":[{"key":"bad","primaryId":"p","displays":[{"id":"p","x":0,"width":1,"height":1,"hz":60,"rotation":1,"rateNum":60,"rateDen":1}]}]}'
    Assert-Equal 0 @((Read-DesktopSnapshotStore).Snapshots.Keys).Count 'a record missing Y is rejected instead of flattened'
}

Test-Case 'desktop restore plan: a saved desk requests exact positions rotation and rational rates' {
    $snapshot = New-DesktopSnapshot -State (New-RestorationDesk)
    $plan = New-DesktopRestorePlan -Snapshot $snapshot -Wanted (New-RestorationDesk)

    Assert-Equal 'path-primary' $plan.PrimaryPath 'saved primary is restored'
    $samsung = @($plan.Targets | Where-Object { $_.DevicePath -eq 'path-portrait' })[0]
    Assert-Equal 2560 $samsung.X 'saved X is requested'
    Assert-Equal (-180) $samsung.Y 'saved Y is requested'
    Assert-Equal 4 $samsung.Rotation 'saved rotation is requested'
    Assert-Equal 75 $samsung.RateNum 'saved exact numerator is requested'
    Assert-Equal 1 $samsung.RateDen 'saved exact denominator is requested'
}

Test-Case 'desktop restore plan: an explicit primary moves the whole saved geometry together' {
    $snapshot = New-DesktopSnapshot -State (New-RestorationDesk)
    $plan = New-DesktopRestorePlan -Snapshot $snapshot -Wanted (New-RestorationDesk) `
                                   -PrimaryPath 'path-left'

    Assert-Equal 'path-left' $plan.PrimaryPath 'explicit primary wins'
    $left = @($plan.Targets | Where-Object { $_.DevicePath -eq 'path-left' })[0]
    $oldPrimary = @($plan.Targets | Where-Object { $_.DevicePath -eq 'path-primary' })[0]
    Assert-Equal 0 $left.X 'new primary lands at the origin'
    Assert-Equal 0 $left.Y 'both axes are shifted'
    Assert-Equal 2560 $oldPrimary.X 'relative horizontal geometry is preserved'
    Assert-Equal (-120) $oldPrimary.Y 'relative vertical geometry is preserved'
}

Test-Case 'desktop subset: a portrait display keeps its physical mode on the first solo switch' {
    $desk = New-RestorationDesk
    $source = New-DesktopSnapshot -State $desk
    $store = New-DesktopSnapshotStore
    $store.Snapshots[$source.Key] = $source

    $subset = New-DesktopSubsetSnapshot -Wanted @($desk[2]) -CurrentSnapshot $source -Store $store
    $plan = New-DesktopRestorePlan -Snapshot $subset -Wanted @($desk[2])

    Assert-Equal 1080 $plan.Targets[0].Width 'portrait width is retained'
    Assert-Equal 1920 $plan.Targets[0].Height 'portrait height is retained'
    Assert-Equal 4 $plan.Targets[0].Rotation 'flipped portrait is retained'
    Assert-Equal 75 $plan.Targets[0].RateNum 'its exact rate is retained'
    Assert-Equal 0 $plan.Targets[0].X 'a solo display is translated to the origin'
    Assert-Equal 0 $plan.Targets[0].Y 'on both axes'
}

Test-Case 'desktop verification: rotation and exact rate mismatches are failures' {
    $snapshot = New-DesktopSnapshot -State (New-RestorationDesk)
    Assert-True (Test-DesktopSnapshotMatch -Snapshot $snapshot -State (New-RestorationDesk)) 'the same desk matches'

    $landscape = New-RestorationDesk
    $landscape[2].Rotation = 1
    Assert-True (-not (Test-DesktopSnapshotMatch -Snapshot $snapshot -State $landscape)) 'wrong rotation is detected'

    $rounded = New-RestorationDesk
    $rounded[0].RateNum = 144000
    Assert-True (-not (Test-DesktopSnapshotMatch -Snapshot $snapshot -State $rounded)) 'whole hertz do not replace the driver fraction'

    $equivalent = New-RestorationDesk
    $equivalent[2].RateNum = 75000; $equivalent[2].RateDen = 1000
    Assert-True (Test-DesktopSnapshotMatch -Snapshot $snapshot -State $equivalent) 'an equivalent driver fraction is accepted'
}

Test-Case 'full config: exact restoration never retries with refresh rates discarded' {
    $script:ExactCalls = @()
    function Invoke-CcdFullConfigAttempt {
        param($Targets, [string]$PrimaryPath, [string[]]$Order, [switch]$WithHz, [switch]$Exact)
        $script:ExactCalls += [pscustomobject]@{ WithHz = [bool]$WithHz; Exact = [bool]$Exact }
        return $false
    }
    $snapshot = New-DesktopSnapshot -State (New-RestorationDesk)
    $plan = New-DesktopRestorePlan -Snapshot $snapshot -Wanted (New-RestorationDesk)

    Assert-True (-not (Set-CcdFullConfig -Targets $plan.Targets -PrimaryPath $plan.PrimaryPath -Exact)) 'refusal is reported'
    Assert-Equal 1 $script:ExactCalls.Count 'there is one exact attempt'
    Assert-True $script:ExactCalls[0].WithHz 'the exact refresh fraction is retained'
    Assert-True $script:ExactCalls[0].Exact 'the lower layer knows positions and rotation are exact'
}

Test-Case 'watchdog: a restored physical mode wins over maximize refresh' {
    $desk = New-RestorationDesk
    $snapshot = New-DesktopSnapshot -State $desk
    $desk[2].BestMode = [pscustomobject]@{ Width = 1920; Height = 1080; Hz = 144 }

    $desired = Get-WatchdogMode -Monitor $desk[2] -ProtectedSnapshot $snapshot

    Assert-Equal 1080 $desired.Width 'the portrait width is protected'
    Assert-Equal 1920 $desired.Height 'the portrait height is protected'
    Assert-Equal 75 $desired.Hz 'maximize refresh does not override the saved rate'
}

Test-Case 'verdict: an exact desktop mismatch is never success' {
    $v = Format-SwitchResult -Summary @('SAMSUNG 1080x1920 @ 75 Hz') -RestoreFailed $true
    Assert-True (-not $v.Ok) 'the mismatch makes the switch partial'
    Assert-True ($v.Text -like '*verdict.restore*') 'the restoration-specific reason is included'
}
