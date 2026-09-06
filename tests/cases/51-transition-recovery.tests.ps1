#Requires -Version 5.1

Test-Case 'transition recovery: an unintended subset cannot replace its saved desktop or windows' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings -Combos @{ AB = @('LG ULTRAGEAR', 'LG ULTRAFINE') }
    $solo = New-FakeMonitor -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3' -Id 'path-ug'
    $solo.Primary = $true; $solo.Hz = 75; $solo.RateNum = 75000; $solo.RateDen = 1000
    $baseline = New-DesktopSnapshot -State @($solo)
    $script:SwStore.Snapshots[$baseline.Key] = $baseline
    $script:SwSettled = [pscustomobject]@{ Ok = $false; MissingLabels = @('LG ULTRAFINE'); ExtraLabels = @() }
    function Get-CcdOutput {
        param($DevicePath)
        $live = @($script:SwDesk | Where-Object { $_.Id -eq $DevicePath -and $_.Active })
        if ($live.Count) { return $live[0].Output }
        return ''
    }
    $partial = Switch-DisplayMode -ModeKey 'combo:AB' -Quiet
    Assert-Equal 'partial' $partial.Outcome 'the missing member is reported'
    Assert-True $script:SwStore.UnsafeKeys.ContainsKey($baseline.Key) 'the observed unintended set is guarded immediately'
    $script:SwCalls = @()
    $script:SwSettled = [pscustomobject]@{ Ok = $true; MissingLabels = @(); ExtraLabels = @() }
    $next = Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet
    Assert-True $next.Ok 'another requested destination remains usable'
    Assert-Equal 75000 $script:SwStore.Snapshots[$baseline.Key].Displays[0].RateNum 'the original numerator survives departure'
    Assert-Equal 1000 $script:SwStore.Snapshots[$baseline.Key].Displays[0].RateDen 'the original denominator survives departure'
    Assert-True (-not ($script:SwCalls -contains 'windows:save')) 'displaced source windows are not learned'
}

Test-Case 'transition recovery: a process interrupted on an unintended subset cannot adopt it' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $all = New-DesktopSnapshot -State $script:SwDesk
    $script:SwStore.Snapshots[$all.Key] = $all
    $solo = New-FakeMonitor -Label 'LG ULTRAGEAR' -ShortId 'GSM5BB3' -Id 'path-ug'
    $solo.Primary = $true; $solo.Hz = 75; $solo.RateNum = 75; $solo.RateDen = 1
    $baseline = New-DesktopSnapshot -State @($solo)
    $script:SwStore.Snapshots[$baseline.Key] = $baseline
    $script:SwStore.PendingKey = Get-DesktopSetKey -DevicePaths @('path-ug', 'path-uf')
    foreach ($m in $script:SwDesk) { $m.Active = ($m.Id -eq 'path-ug') }
    $result = Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet
    Assert-True $result.Ok 'a restart can still switch to a known safe destination'
    Assert-Equal 75 $script:SwStore.Snapshots[$baseline.Key].Displays[0].Hz 'the interrupted observation did not replace the baseline'
    Assert-True $script:SwStore.UnsafeKeys.ContainsKey($baseline.Key) 'the actual subset stays guarded after a different success clears pending'
}

Test-Case 'transition recovery: a refused departure preserves source protection and releases pending' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwDesk[0].Hz = 75; $script:SwDesk[0].RateNum = 75; $script:SwDesk[0].RateDen = 1
    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)
    $sourceKey = $script:SwStore.ProtectedKey
    $script:SwFullOk = $false
    $refused = $false
    try { [void](Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet) } catch { $refused = $true }
    Assert-True $refused 'the rejected CCD request remains a failure'
    Assert-Equal $sourceKey $script:SwStore.ProtectedKey 'the unchanged source remains protected'
    Assert-Equal '' $script:SwStore.PendingKey 'a verified unchanged source is no longer an unresolved transition'
    Assert-True (-not $script:SwStore.UnsafeKeys.ContainsKey($sourceKey)) 'the verified source remains usable by its watchdog'
    function Test-FullscreenApp { return $false }
    function Get-CurrentMode {
        param($Output)
        return @($script:SwDesk | Where-Object { $_.Output -eq $Output })[0]
    }
    $script:SwCalls = @(); $script:LastRestore = [datetime]::MinValue
    [void](Restore-BestModes -DebounceMs 0)
    Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'best:*' }).Count 'the watchdog does not maximize the preserved 75 Hz desk'
}

Test-Case 'transition recovery: a direct geometry retry restores windows without overwriting them' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:RecoveryWindows = @{}; $script:RecoveryLiveWindows = 'trusted All windows'
    function Save-WindowLayout { param($Key) $script:RecoveryWindows[$Key] = $script:RecoveryLiveWindows }
    function Restore-WindowLayout { param($Key) $script:RecoveryLiveWindows = $script:RecoveryWindows[$Key] }
    [void](Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet)
    $script:SwVerifyMismatch = $true
    $failed = Switch-DisplayMode -ModeKey 'all' -Quiet
    Assert-Equal 'partial' $failed.Outcome 'the first All result has wrong geometry'
    $script:RecoveryLiveWindows = 'displaced windows'; $script:SwVerifyMismatch = $false
    $retried = Switch-DisplayMode -ModeKey 'all' -Quiet
    Assert-True $retried.Ok 'the direct retry repairs geometry'
    Assert-Equal 'trusted All windows' $script:RecoveryLiveWindows 'the same-set retry restores the good window baseline'
}

Test-Case 'transition recovery: asynchronously settled geometry still restores pending destination windows' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:RecoveryWindows = @{}; $script:RecoveryLiveWindows = 'trusted All windows'
    function Save-WindowLayout { param($Key) $script:RecoveryWindows[$Key] = $script:RecoveryLiveWindows }
    function Restore-WindowLayout { param($Key) $script:RecoveryLiveWindows = $script:RecoveryWindows[$Key] }
    [void](Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet)
    $script:SwVerifyMismatch = $true
    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)
    $script:RecoveryLiveWindows = 'displaced windows'; $script:SwVerifyMismatch = $false
    $script:SwDesk[0].Rotation = 1
    $script:SwCalls = @()
    $retried = Switch-DisplayMode -ModeKey 'all' -Quiet
    Assert-True $retried.Ok 'the already settled geometry verifies'
    Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'full:*' }).Count 'there is no extra physical apply'
    Assert-Equal 'trusted All windows' $script:RecoveryLiveWindows 'windows still recover when physical apply is unnecessary'
}

Test-Case 'transition recovery: a crash before apply preserves an identified unchanged portrait source' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwDesk[2].Width = 1440; $script:SwDesk[2].Height = 2560; $script:SwDesk[2].Rotation = 4
    $source = New-DesktopSnapshot -State $script:SwDesk
    $script:SwStore.Snapshots[$source.Key] = $source
    $script:SwStore.PendingKey = Get-DesktopSetKey -DevicePaths @('path-ug')
    $script:SwStore | Add-Member NoteProperty PendingSourceKey $source.Key -Force
    $result = Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet
    Assert-True $result.Ok 'the next first solo can use the identified source'
    Assert-True $script:SwFullExact 'the interrupted source still supplies an exact subset'
    Assert-Equal 4 $script:SwDesk[2].Rotation 'the portrait source does not fall through generated landscape modes'
    Assert-True ($script:SwCalls -contains 'windows:save') 'unchanged trustworthy source windows can be saved before the real departure'
}

Test-Case 'transition recovery: pending source identity survives storage and older records remain readable' {
    $originalFile = $script:DesktopSnapshotsFile
    $script:DesktopSnapshotsFile = Join-Path $script:TestDir 'pending-source-roundtrip.json'
    try {
        $source = New-DesktopSnapshot -State (New-SwitchDesk)
        $store = New-DesktopSnapshotStore
        $store.Snapshots[$source.Key] = $source
        $store.PendingKey = Get-DesktopSetKey -DevicePaths @('path-xg')
        $store.PendingSourceKey = $source.Key
        Write-DesktopSnapshotStore -Store $store
        $loaded = Read-DesktopSnapshotStore
        Assert-Equal $source.Key $loaded.PendingSourceKey 'a new process can identify the real pre-apply source'
        Assert-Equal $store.PendingKey $loaded.PendingKey 'the requested destination remains distinct'
        $legacy = Get-Content -LiteralPath $script:DesktopSnapshotsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $legacy.PSObject.Properties.Remove('pendingSourceKey')
        [IO.File]::WriteAllText($script:DesktopSnapshotsFile, ($legacy | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $true))
        $loaded = Read-DesktopSnapshotStore
        Assert-Equal '' $loaded.PendingSourceKey 'older snapshots do not invent a trusted source'
        Assert-Equal $source.Key $loaded.Snapshots[$source.Key].Key 'the older complete snapshot remains available'
    }
    finally { $script:DesktopSnapshotsFile = $originalFile }
}

Test-Case 'transition recovery: an exception after a changed apply guards the actual subset' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $actualKey = Get-DesktopSetKey -DevicePaths @('path-ug')
    function Set-CcdFullConfig {
        param($Targets, $PrimaryPath, $Order, [switch]$Exact)
        foreach ($m in $script:SwDesk) { $m.Active = ($m.Id -eq 'path-ug'); $m.Primary = $m.Active }
        throw 'driver response was lost after apply'
    }
    $errorText = ''
    try { [void](Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet) } catch { $errorText = $_.Exception.Message }
    Assert-Equal 'driver response was lost after apply' $errorText 'failure bookkeeping preserves the original error'
    Assert-True $script:SwStore.UnsafeKeys.ContainsKey($actualKey) 'the exception path guards what is actually active'
    Assert-Equal (Get-DesktopSetKey -DevicePaths @('path-xg')) $script:SwStore.PendingKey 'the requested destination remains retryable'
}

Test-Case 'transition recovery: a refused departure retains a transient KeepMode fraction' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    [void](Switch-DisplayMode -ModeKey 'solo:LG ULTRAGEAR' -Quiet)
    $script:SwDesk[0].Hz = 120; $script:SwDesk[0].RateNum = 119999; $script:SwDesk[0].RateDen = 1000
    [void](Switch-DisplayMode -ModeKey 'all' -KeepMode -Quiet)
    $sourceKey = $script:SwStore.ProtectedKey
    $script:SwFullOk = $false
    try { [void](Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet) } catch { }
    Assert-Equal $sourceKey $script:SwStore.ProtectedKey 'the unchanged transient desk remains protected'
    Assert-Equal 119999 $script:SwStore.ProtectedSnapshot.Displays[0].RateNum 'the protected numerator survives the failed departure'
    Assert-Equal 1000 $script:SwStore.ProtectedSnapshot.Displays[0].RateDen 'the protected denominator survives the failed departure'
    Assert-Equal '' $script:SwStore.PendingKey 'future watchdog repairs are not blocked by a refused destination'
}

Test-Case 'transition recovery: explicit adoption resolves a different failed destination' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    foreach ($m in $script:SwDesk) { $m.Active = ($m.Id -eq 'path-ug') }
    $script:SwDesk[0].Hz = 75; $script:SwDesk[0].RateNum = 75; $script:SwDesk[0].RateDen = 1
    $activeKey = Get-DesktopSetKey -DevicePaths @('path-ug')
    $script:SwStore.PendingKey = Get-DesktopSetKey -DevicePaths @('path-ug', 'path-uf')
    $script:SwStore.PendingSourceKey = Get-DesktopSetKey -DevicePaths @('path-ug', 'path-uf', 'path-xg')
    $script:SwStore.UnsafeKeys[$activeKey] = $true
    Assert-True (Save-CurrentDesktopSnapshot) 'the explicit current desk is adopted'
    Assert-Equal '' $script:SwStore.PendingKey 'a failed different destination no longer blocks the watchdog'
    Assert-Equal '' $script:SwStore.PendingSourceKey 'the stale source marker is cleared too'
    Assert-Equal $activeKey $script:SwStore.ProtectedKey 'the adopted current set is protected'
    Assert-True (-not $script:SwStore.UnsafeKeys.ContainsKey($activeKey)) 'the adopted set is safe'
    $script:SwDesk[0].Hz = 60; $script:SwDesk[0].RateNum = 60
    function Test-FullscreenApp { return $false }
    function Get-CurrentMode { param($Output) return $script:SwDesk[0] }
    $script:RecoveryRequestedHz = @()
    function Set-BestModeFor {
        param($Output, $Label, $NativeWidth, $NativeHeight, $Best)
        $script:RecoveryRequestedHz += $Best.Hz
        return $true
    }
    $script:LastRestore = [datetime]::MinValue
    [void](Restore-BestModes -DebounceMs 0)
    Assert-Equal '75' ($script:RecoveryRequestedHz -join ',') 'a later drift is repaired to the adopted rate'
}
