# --- the switch orchestrator ------------------------------------------------
# Switch-DisplayMode is the most complicated and the most fragile part of the project, and until now
# the only way to test it was to switch real monitors.
#
# It is tested by SHADOWING FUNCTIONS rather than by a seam in the code. Switch-DisplayMode reaches
# hardware and disk only through named functions, and PowerShell looks functions up along the chain of
# CALL scopes. So a `function Set-CcdFullConfig` declaration inside a Test-Case block overrides the real
# one for everything that block calls, and dies with the block: there is nothing to restore, the
# isolation between cases is free, and not one extra call appeared on the path where milliseconds were
# measured. The production code was not changed for these tests at all.
#
# The fakes write their calls into $script:SwCalls — a test checks WHAT was called and in WHAT order,
# not only how it all ended.
#
# The layout's own retry lives a floor below, in Invoke-CcdLayoutAttempt, and is tested in
# 13-layout-retry: here Set-CcdLayout answers at once and in full.

Write-Host ''
Write-Host 'the switch orchestrator' -ForegroundColor White

# The desk for the orchestrator. BestMode is filled in on purpose: without it Get-SwitchTargets hands
# back an empty set, the one-call transition is not even attempted, and half the cases would be testing
# something other than what their names say.
function New-SwitchDesk {
    param([bool]$ThirdActive = $true, [bool]$ThirdDisconnected = $false)

    $desk = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf')
        (New-FakeMonitor 'XG27AQDMGR' 'AUS1234' 'path-xg' $ThirdActive $ThirdDisconnected)
    )
    for ($i = 0; $i -lt $desk.Count; $i++) {
        $desk[$i].Output = '\\.\DISPLAY' + ($i + 1)
        $desk[$i].X = $i * 2560
        $desk[$i].Y = 0
        $desk[$i].Primary = ($i -eq 0)
        $desk[$i].BestMode = [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 144 }
    }
    return $desk
}

function New-SwitchSettings {
    param([hashtable]$Combos = @{})
    $s = New-TestSettings -Combos $Combos
    # The order on the desk is set: without it Set-CcdLayout is not called at all, and there would be
    # nothing to test "the layout is checked anyway" with.
    $s.layout = @('LG ULTRAGEAR', 'LG ULTRAFINE', 'XG27AQDMGR')
    return $s
}

# Every fake in one piece. Dot-sourcing a script block executes it in the scope of WHOEVER called it —
# that is, inside the Test-Case block rather than in the script's scope. That way the functions live for
# exactly one case and do not leak into the next.
$script:SwFakes = {
    $script:SwCalls = @()
    $script:SwFullOk = $true
    $script:SwTopologyOk = $true
    $script:SwSettled = [pscustomobject]@{ Ok = $true; MissingLabels = @(); ExtraLabels = @() }
    $script:SwLayoutOk = $true
    $script:SwLayoutChanged = $false
    # "Nothing moved, and not because everything was already right" — see the case at the end.
    $script:SwLayoutNote = ''
    $script:SwSavedMode = ''
    $script:SwAppliedModes = $null
    $script:SwStore = New-DesktopSnapshotStore
    $script:SwPendingIds = @()
    $script:SwVerifyMismatch = $false

    function Get-DisplaySettings { return $script:SwSettings }
    function Get-DisplayState { return @($script:SwDesk) }

    # The cache of verified modes is shadowed on purpose: the file in the temporary folder is left behind
    # by other groups of cases, and without this the set of targets would depend on the order of the run.
    function Get-ModeCache { return @{} }
    function Read-DesktopSnapshotStore { return $script:SwStore }
    function Write-DesktopSnapshotStore { param($Store) $script:SwStore = $Store }

    function Invoke-ModeHook {
        param($Settings, [string]$ModeKey, [string]$Phase)
        $script:SwCalls += "hook:$Phase"
        return $true
    }

    function Save-WindowLayout { param([string]$Key) $script:SwCalls += 'windows:save' }
    function Restore-WindowLayout { param([string]$Key) $script:SwCalls += 'windows:restore' }

    function Set-CcdFullConfig {
        param($Targets, [string]$PrimaryPath, $Order, [switch]$Exact)
        $script:SwCalls += ('full:' + ((@($Targets) | ForEach-Object { $_.DevicePath }) -join '+'))
        $script:SwFullPrimary = $PrimaryPath
        $script:SwFullTargets = @($Targets)
        $script:SwFullExact = [bool]$Exact
        if ($script:SwFullOk) {
            $ids = @($Targets | ForEach-Object { $_.DevicePath })
            $script:SwPendingIds = $ids
            foreach ($m in @($script:SwDesk)) {
                $m.Primary = ($m.Id -eq $PrimaryPath)
                $t = @($Targets | Where-Object { $_.DevicePath -eq $m.Id } | Select-Object -First 1)
                if ($t.Count -gt 0) {
                    $m.Width = [int]$t[0].Width; $m.Height = [int]$t[0].Height; $m.Hz = [int]$t[0].Hz
                    if ($t[0].PSObject.Properties['X']) { $m.X = [int]$t[0].X; $m.Y = [int]$t[0].Y }
                    if ($t[0].PSObject.Properties['Rotation']) { $m.Rotation = [int]$t[0].Rotation }
                    if ($t[0].PSObject.Properties['RateNum'] -and [int]$t[0].RateDen -gt 0) {
                        $m.RateNum = [int]$t[0].RateNum; $m.RateDen = [int]$t[0].RateDen
                    }
                }
            }
        }
        return $script:SwFullOk
    }

    function Set-CcdTopology {
        param($DevicePaths)
        $script:SwCalls += ('topology:' + (@($DevicePaths) -join '+'))
        if ($script:SwTopologyOk) {
            $script:SwPendingIds = @($DevicePaths)
        }
        return $script:SwTopologyOk
    }

    function Wait-ForTopology {
        param($WantedPaths)
        $script:SwCalls += 'settle'
        foreach ($m in @($script:SwDesk)) {
            $missing = (@($script:SwSettled.MissingLabels) -contains $m.Label)
            $m.Active = (($script:SwPendingIds -contains $m.Id) -and -not $missing)
        }
        if ($script:SwVerifyMismatch) {
            $hit = @($script:SwDesk | Where-Object { $_.Active } | Select-Object -First 1)
            if ($hit.Count -gt 0) { $hit[0].Rotation = $(if ($hit[0].Rotation -eq 1) { 2 } else { 1 }) }
        }
        return $script:SwSettled
    }

    function Set-CcdLayout {
        param([string]$PrimaryPath, $Order)
        $script:SwCalls += 'layout'
        # Who was sent to (0, 0) is remembered separately: "the call happened" and "the taskbar went to
        # the display the settings name" are two different claims, and only the second one is the promise.
        $script:SwLayoutPrimary = $PrimaryPath
        $script:SwLayoutOrder = @($Order)
        return [pscustomobject]@{ Ok = $script:SwLayoutOk; Changed = $script:SwLayoutChanged
                                  Note = $script:SwLayoutNote }
    }

    # Set-WantedModes works for real: only its ends at the hardware are shadowed.
    function Get-CcdTargets {
        return @(@($script:SwDesk) | Where-Object { $_.Active } | ForEach-Object {
            [pscustomobject]@{ DevicePath = $_.Id; Output = $_.Output; Active = $true }
        })
    }
    # A sleeping monitor is not yet visible in Get-CcdTargets: its output name is asked for separately,
    # and here it is waking up at just that moment. That way the branch of Set-WantedModes that waits for
    # latecomers gets tested too.
    function Get-CcdOutput {
        param([string]$DevicePath)
        $m = @($script:SwDesk) | Where-Object { $_.Id -eq $DevicePath } | Select-Object -First 1
        return $(if ($m) { [string]$m.Output } else { '' })
    }

    function Set-BestModeFor {
        param([string]$Output, [string]$Label, [int]$NativeWidth, [int]$NativeHeight, $Best)
        $script:SwCalls += "best:$Label"
        return $true
    }
    function Get-CurrentMode {
        param([string]$Output)
        return [pscustomobject]@{ Width = 2560; Height = 1440; Hz = 144 }
    }

    function Save-LastMode { param([string]$Key) $script:SwCalls += 'lastMode'; $script:SwSavedMode = $Key }
    function Save-AppliedModes { param($Applied) $script:SwCalls += 'applied'; $script:SwAppliedModes = $Applied }

    function Set-DefaultAudioDevice { param([string]$Match) $script:SwCalls += "audio:$Match"; return $true }
    function Set-MonitorLevels {
        param($Targets, $BrightnessSetting, $ContrastSetting, $PictureSetting)
        $script:SwCalls += ('levels:' + ((@($Targets) | ForEach-Object { $_.Label }) -join '+'))
        $script:SwLevelArgs = [pscustomobject]@{
            Brightness = $BrightnessSetting; Contrast = $ContrastSetting; Picture = $PictureSetting
        }
        return $true
    }
}

Test-Case 'switch: the set is already right, so the topology is not rebuilt' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True $r.Ok 'the switch is a success'
    Assert-True (-not ($script:SwCalls -match '^full')) 'no whole-desk transition was asked for'
    Assert-True (-not ($script:SwCalls -match '^topology')) 'and no topology rebuild either'
    Assert-True (-not ($script:SwCalls -contains 'settle')) 'nothing to wait for'
    Assert-True (-not ($script:SwCalls -contains 'windows:save')) 'windows did not move, so they were not snapshotted'
    Assert-True (-not ($script:SwCalls -contains 'layout')) 'the saved offsets are not flattened into a row'
    Assert-True (-not ($script:SwCalls -match '^best:')) 'maximize refresh does not rewrite the live modes'
    Assert-Equal 'hook:before,lastMode,applied,hook:after' ($script:SwCalls -join ',') 'and that is the whole of it'
}

Test-Case 'switch: all returns to the original physical desk after a solo mode' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwDesk[2].Width = 1080; $script:SwDesk[2].Height = 1920; $script:SwDesk[2].Hz = 75
    $script:SwDesk[2].X = 2560; $script:SwDesk[2].Y = -180
    $script:SwDesk[2].Rotation = 4; $script:SwDesk[2].RateNum = 75; $script:SwDesk[2].RateDen = 1
    $script:SwSettings = New-SwitchSettings

    [void](Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet)
    Assert-Equal 4 $script:SwDesk[2].Rotation 'the first solo switch keeps flipped portrait'
    Assert-Equal 1080 $script:SwDesk[2].Width 'and its portrait resolution'

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)
    Assert-Equal 'path-ug' (@($script:SwDesk | Where-Object { $_.Primary })[0].Id) 'the original primary returned'
    Assert-Equal 2560 $script:SwDesk[2].X 'the original horizontal offset returned'
    Assert-Equal (-180) $script:SwDesk[2].Y 'the original vertical offset returned'
    Assert-Equal 4 $script:SwDesk[2].Rotation 'the original flipped portrait returned'
    Assert-Equal 75 $script:SwDesk[2].RateNum 'the original rational rate returned'

    $before = @($script:SwCalls | Where-Object { $_ -like 'full:*' }).Count
    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)
    Assert-Equal $before @($script:SwCalls | Where-Object { $_ -like 'full:*' }).Count 'repeated All is a physical no-op'
}

Test-Case 'switch: a failed exact restore cannot poison the baseline after restart' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    $baselineDesk = New-SwitchDesk
    $baselineDesk[2].Width = 1080; $baselineDesk[2].Height = 1920; $baselineDesk[2].Hz = 75
    $baselineDesk[2].Rotation = 4; $baselineDesk[2].RateNum = 75; $baselineDesk[2].RateDen = 1
    $baseline = New-DesktopSnapshot -State $baselineDesk
    $script:SwStore.Snapshots[$baseline.Key] = $baseline
    $script:SwStore.PendingKey = $baseline.Key
    $script:SwVerifyMismatch = $true

    $first = Switch-DisplayMode -ModeKey 'all' -Quiet
    Assert-Equal 'partial' $first.Outcome 'the unverified restore is a partial result'
    Assert-Equal 4 $script:SwStore.Snapshots[$baseline.Key].Displays[2].Rotation 'bad observed geometry did not replace the baseline'
    Assert-Equal $baseline.Key $script:SwStore.PendingKey 'the persistent retry guard remains'

    $script:SwVerifyMismatch = $false
    $second = Switch-DisplayMode -ModeKey 'all' -Quiet
    Assert-Equal 'done' $second.Outcome 'the next process can retry the saved baseline'
    Assert-Equal '' $script:SwStore.PendingKey 'verified success clears the guard'
    Assert-Equal 4 $script:SwDesk[2].Rotation 'the saved portrait rotation wins over the failed observation'
}

Test-Case 'switch: leaving an unsafe desk preserves its trusted window baseline and still restores the destination' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:WindowMarkers = @{}
    $script:RestoredWindowKeys = @()
    $script:LiveWindows = 'trusted All'
    function Save-WindowLayout {
        param([string]$Key)
        $script:SwCalls += 'windows:save'
        $script:WindowMarkers[$Key] = $script:LiveWindows
    }
    function Restore-WindowLayout {
        param([string]$Key)
        $script:SwCalls += 'windows:restore'
        $script:RestoredWindowKeys += $Key
        if ($script:WindowMarkers.ContainsKey($Key)) { $script:LiveWindows = $script:WindowMarkers[$Key] }
    }

    $allWindowKey = Get-DisplayLayoutKey -State $script:SwDesk
    [void](Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet)
    $soloWindowKey = Get-DisplayLayoutKey -State @($script:SwDesk | Where-Object { $_.Active })
    $script:LiveWindows = 'trusted Solo'
    $script:SwVerifyMismatch = $true
    $failed = Switch-DisplayMode -ModeKey 'all' -Quiet
    Assert-Equal 'partial' $failed.Outcome 'the All restore is guarded as unsafe'

    $script:LiveWindows = 'windows on failed All'
    $script:SwVerifyMismatch = $false
    [void](Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet)

    Assert-Equal 'trusted All' $script:WindowMarkers[$allWindowKey] 'failed All did not replace the good window positions'
    Assert-True ($script:RestoredWindowKeys -contains $soloWindowKey) 'the successful destination still restored its windows in the tail'
}

Test-Case 'switch: a failed first solo restore retries from the trusted larger desk' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwDesk[2].Width = 1080; $script:SwDesk[2].Height = 1920; $script:SwDesk[2].Hz = 75
    $script:SwDesk[2].Rotation = 4; $script:SwDesk[2].RateNum = 75; $script:SwDesk[2].RateDen = 1
    $script:SwSettings = New-SwitchSettings
    $soloKey = Get-DesktopSetKey -DevicePaths @('path-xg')
    $script:SwVerifyMismatch = $true

    $first = Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet
    Assert-Equal 'partial' $first.Outcome 'the first unverified solo is a partial result'
    Assert-True $script:SwStore.UnsafeKeys.ContainsKey($soloKey) 'the unseen subset is guarded'
    Assert-True (-not $script:SwStore.Snapshots.ContainsKey($soloKey)) 'the damaged subset was not learned'

    $script:SwVerifyMismatch = $false
    $second = Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet
    Assert-Equal 'done' $second.Outcome 'the guarded set can be retried'
    Assert-Equal 4 $script:SwDesk[2].Rotation 'the trusted larger desk supplies flipped portrait again'
    Assert-True (-not $script:SwStore.UnsafeKeys.ContainsKey($soloKey)) 'verified retry clears the guard'
}

Test-Case 'switch: automatic reapply restores the saved desk instead of adopting drift' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $baselineDesk = New-SwitchDesk
    $baselineDesk[2].Width = 1080; $baselineDesk[2].Height = 1920; $baselineDesk[2].Hz = 75
    $baselineDesk[2].Rotation = 4; $baselineDesk[2].RateNum = 75; $baselineDesk[2].RateDen = 1
    $baseline = New-DesktopSnapshot -State $baselineDesk
    $script:SwStore.Snapshots[$baseline.Key] = $baseline

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet -Automatic

    Assert-True $r.Ok 'automatic restoration completes'
    Assert-True $script:SwFullExact 'it uses the exact CCD request'
    Assert-Equal 4 $script:SwDesk[2].Rotation 'saved rotation wins over Windows drift'
    Assert-Equal 75 $script:SwDesk[2].Hz 'saved refresh wins over maximize refresh'
}

Test-Case 'switch: a baseline write failure refuses before the desk or hooks change' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    function Write-DesktopSnapshotStore { param($Store) throw 'disk is read-only' }

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'all' -Quiet) } catch { $failed = $_.Exception.Message }

    Assert-True ($failed.Contains((Get-Text -Key 'switch.snapshotWriteFailed'))) 'the safe refusal reaches the caller'
    Assert-Equal 0 $script:SwCalls.Count 'nothing external ran after persistence failed'
}

Test-Case 'switch: an automatic switch does not overwrite the mode the human chose' {
    # 2026-08-28: a reapply on a monitor appearing wrote combo:Work over the chosen solo:XG27AQDMGR, and
    # from then on both onUnplug and the startup restore led past the monitor the person was sitting at.
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet -Automatic

    Assert-True $r.Ok 'the switch itself still happens'
    Assert-True (-not ($script:SwCalls -contains 'lastMode')) 'but the choice is left alone'
    Assert-True ($script:SwCalls -contains 'applied') 'what the monitors actually show is still remembered'
}

Test-Case 'switch: a changing set is one whole-desk call, not three transitions' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True $r.Ok 'the switch is a success'
    Assert-Equal 1 @($script:SwCalls | Where-Object { $_ -like 'full:*' }).Count 'exactly one whole-desk call'
    Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'topology:*' }).Count 'and the three-step road is not touched'
    Assert-Equal 'full:path-ug+path-uf+path-xg' (@($script:SwCalls | Where-Object { $_ -like 'full:*' })[0]) 'all three displays in one call'
    Assert-True ($script:SwCalls -contains 'windows:save') 'window positions were taken before the rebuild'
    Assert-True ($script:SwCalls -contains 'windows:restore') 'and put back after it'
}

Test-Case 'switch: window positions are taken before the desk is rebuilt, not after' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)

    $order = $script:SwCalls -join ','
    Assert-True ($order -match 'windows:save,full:') 'the snapshot comes immediately before the transition'
    Assert-True ($script:SwCalls.IndexOf('windows:restore') -gt $script:SwCalls.IndexOf('layout')) 'and the restore comes after the layout'
}

Test-Case 'switch: a refused whole-desk call falls back to the three-step road' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $script:SwFullOk = $false

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True $r.Ok 'the old road still gets there'
    Assert-Equal 1 @($script:SwCalls | Where-Object { $_ -like 'full:*' }).Count 'the one call was tried first'
    Assert-Equal 1 @($script:SwCalls | Where-Object { $_ -like 'topology:*' }).Count 'and only then the set alone'
    Assert-True ($script:SwCalls -contains 'settle') 'the result is waited for either way'
}

Test-Case 'switch: a generated layout failure stays partial and cannot become a baseline' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $script:SwLayoutOk = $false
    $allKey = Get-DesktopSetKey -DevicePaths @($script:SwDesk | ForEach-Object { $_.Id })

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-Equal 'partial' $r.Outcome 'failure after the generated apply reaches the switch verdict'
    Assert-True $script:SwStore.UnsafeKeys.ContainsKey($allKey) 'the unverified arrangement remains guarded'
    Assert-True (-not $script:SwStore.Snapshots.ContainsKey($allKey)) 'it is not learned as a physical baseline'
    Assert-Equal '' $script:SwStore.ProtectedKey 'the watchdog is not pointed at it'
}

Test-Case 'switch: Windows refusing the configuration is a failure, not a quiet success' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $script:SwFullOk = $false
    $script:SwTopologyOk = $false

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'all' -Quiet) }
    catch { $failed = $_.Exception.Message }

    Assert-True ($failed -like '*Windows refused the display configuration*') 'it says what happened'
    Assert-True ($failed -like '*you keep a picture*') 'and that nothing was lost'
    Assert-True (-not ($script:SwCalls -contains 'lastMode')) 'a switch that did not happen is not remembered'
    Assert-True (-not ($script:SwCalls -contains 'hook:after')) 'and the after command does not run'
}

Test-Case 'switch: the before command runs only once the switch can no longer refuse' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)

    Assert-Equal 'hook:before' $script:SwCalls[0] 'before is the first thing that touches the outside world'
    Assert-Equal 'hook:after' $script:SwCalls[-1] 'and after is the very last'
    Assert-True ($script:SwCalls.IndexOf('hook:before') -lt $script:SwCalls.IndexOf('windows:save')) 'before runs ahead of the snapshot'
}

Test-Case 'switch: a mode that cannot be reached never starts the before command' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    try { [void](Switch-DisplayMode -ModeKey 'solo:Nothing Like This' -Quiet) } catch { }

    Assert-Equal 0 $script:SwCalls.Count 'nothing was run under a mode that will not be'
}

Test-Case 'switch: a display that is not plugged in is said in human words' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'solo:Some Other Screen' -Quiet) }
    catch { $failed = $_.Exception.Message }

    Assert-Equal 'That display is not connected right now.' $failed 'no key names, no stack, a sentence'
}

Test-Case 'switch: a combination deleted in the settings is named, not numbered' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'combo:Movie night' -Quiet) }
    catch { $failed = $_.Exception.Message }

    Assert-Equal "The combination 'Movie night' no longer exists in the settings." $failed 'the name comes back as typed'
}

Test-Case 'switch: a mode nobody knows is refused by its key' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'nonsense' -Quiet) }
    catch { $failed = $_.Exception.Message }

    Assert-Equal "Unknown mode 'nonsense'." $failed 'and the key is quoted so it can be found in the settings'
}

Test-Case 'switch: a combination whose displays are all unplugged keeps the picture' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false -ThirdDisconnected $true
    $script:SwSettings = New-SwitchSettings -Combos @{ 'Movie' = @('XG27AQDMGR') }

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'combo:Movie' -Quiet) }
    catch { $failed = $_.Exception.Message }

    Assert-True ($failed -like "*Mode 'Movie'*") 'the mode is named'
    Assert-True ($failed -like '*Nothing was turned off*') 'and nothing was turned off to find that out'
    Assert-Equal 0 $script:SwCalls.Count 'not a single call went out'
}

Test-Case 'switch: a saved desktop that does not verify is not reported as success' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwSettings.primary = 'ULTRAFINE'
    $script:SwSettings.primaryOverride = $true
    $script:SwVerifyMismatch = $true

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True (-not $r.Ok) 'a silent success on mismatched physical state is not allowed'
    Assert-True ($r.Message.Contains((Get-Text -Key 'verdict.restore'))) 'the exact-restore failure reaches the verdict'
    # A person's choice is remembered even so: they asked for this mode specifically.
    Assert-True ($script:SwCalls -contains 'lastMode') 'and the choice is still remembered'
    Assert-Equal 'all' $script:SwSavedMode 'as the mode he asked for'
}

Test-Case 'switch: displays Windows would not turn off land in the verdict' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $script:SwSettled = [pscustomobject]@{ Ok = $false; MissingLabels = @(); ExtraLabels = @('XG27AQDMGR') }

    $r = Switch-DisplayMode -ModeKey 'solo:LG ULTRAGEAR' -Quiet

    Assert-Equal @('XG27AQDMGR') @($r.Refused) 'the display that stayed on is named'
    Assert-True (-not $r.Ok) 'and that is not a success'
    Assert-True ($r.Message -like '*Still on: XG27AQDMGR*') 'the summary says so in words'
}

Test-Case 'switch: a dry run changes nothing and remembers nothing' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    $r = Switch-DisplayMode -ModeKey 'all' -DryRun -Quiet 6> $null

    Assert-Equal 'dry run' $r.Message 'it says what it was'
    Assert-True $r.Ok 'and a dry run does not fail'
    Assert-Equal 0 $script:SwCalls.Count 'not one call to the system or the disk'
}

Test-Case 'switch: KeepMode refuses incomplete generated modes before topology-only fallback' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    $refused = $false
    try { [void](Switch-DisplayMode -ModeKey 'all' -KeepMode -Quiet) }
    catch { $refused = $true }

    Assert-True $refused 'the unreadable sleeping mode cannot justify discarding active modes'
    Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'best:*' }).Count 'nobody was pushed to its best mode'
    Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'full:*' }).Count 'the incomplete request is not attempted'
    Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'topology:*' }).Count 'topology-only fallback would discard active modes'
}
Test-Case 'switch: KeepMode restores saved geometry with the live mode and keeps both truths durable' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwDesk[0].Hz = 75; $script:SwDesk[0].RateNum = 75; $script:SwDesk[0].RateDen = 1
    $allKey = Get-DesktopSetKey -DevicePaths @($script:SwDesk | ForEach-Object { $_.Id })

    [void](Switch-DisplayMode -ModeKey 'solo:LG ULTRAGEAR' -Quiet)
    $script:SwDesk[0].Width = 1920; $script:SwDesk[0].Height = 1080
    $script:SwDesk[0].Hz = 120; $script:SwDesk[0].RateNum = 120000; $script:SwDesk[0].RateDen = 1000
    $kept = Switch-DisplayMode -ModeKey 'all' -KeepMode -Quiet

    Assert-True $kept.Ok 'the exact All restore completed'
    $activeTarget = @($script:SwFullTargets | Where-Object { $_.DevicePath -eq 'path-ug' })[0]
    Assert-Equal 1920 $activeTarget.Width 'the live active resolution was requested'
    Assert-Equal 120000 $activeTarget.RateNum 'with its exact live refresh fraction'
    Assert-Equal 1 $activeTarget.Rotation 'while the saved rotation was restored'
    $baseline = @($script:SwStore.Snapshots[$allKey].Displays | Where-Object { $_.Id -eq 'path-ug' })[0]
    Assert-Equal 75 $baseline.Hz 'the canonical All baseline remains unchanged'
    $protected = @($script:SwStore.ProtectedSnapshot.Displays | Where-Object { $_.Id -eq 'path-ug' })[0]
    Assert-Equal 120 $protected.Hz 'the watchdog separately protects what KeepMode actually applied'

    $beforeRepeat = @($script:SwCalls | Where-Object { $_ -like 'full:*' }).Count
    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)
    Assert-Equal 120 $script:SwDesk[0].Hz 'a manual repeat All preserves the live complete desk'
    Assert-Equal $beforeRepeat @($script:SwCalls | Where-Object { $_ -like 'full:*' }).Count 'the repeat does not rebuild it'
    Assert-Equal 120 $script:SwStore.Snapshots[$allKey].Displays[0].Hz 'that explicit repeat promotes the successful live desk'
    Assert-Null $script:SwStore.ProtectedSnapshot 'the manual adoption clears the one-shot automatic protection'
}

Test-Case 'switch: automatic reapply restores and retains the durable KeepMode protection' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwDesk[0].Hz = 75; $script:SwDesk[0].RateNum = 75; $script:SwDesk[0].RateDen = 1
    $allKey = Get-DesktopSetKey -DevicePaths @($script:SwDesk | ForEach-Object { $_.Id })
    [void](Switch-DisplayMode -ModeKey 'solo:LG ULTRAGEAR' -Quiet)
    $script:SwDesk[0].Hz = 120; $script:SwDesk[0].RateNum = 120000; $script:SwDesk[0].RateDen = 1000
    [void](Switch-DisplayMode -ModeKey 'all' -KeepMode -Quiet)

    # Windows drops only the active monitor's rate. Automatic reapply must use the verified KeepMode
    # state rather than the older canonical All snapshot.
    $script:SwDesk[0].Hz = 60; $script:SwDesk[0].RateNum = 60; $script:SwDesk[0].RateDen = 1
    $script:SwCalls = @()
    $r = Switch-DisplayMode -ModeKey 'all' -Automatic -Quiet

    Assert-True $r.Ok 'the automatic repair completes'
    Assert-Equal 120 $script:SwDesk[0].Hz 'the applied KeepMode rate is restored'
    Assert-Equal 75 $script:SwStore.Snapshots[$allKey].Displays[0].Hz 'the one-shot repair still does not rewrite the canonical desk'
    Assert-Equal 120 $script:SwStore.ProtectedSnapshot.Displays[0].Hz 'the durable protection survives automatic reapply'
}

Test-Case 'switch: failed automatic KeepMode repairs retain their durable target across retries' {
    # Use the production serializer in this orchestrator case. Every switch reads the file again, so the
    # second attempt cannot accidentally inherit an object that survived only in this PowerShell process.
    $script:RetryRealReadDesktopStore = ${function:Read-DesktopSnapshotStore}
    $script:RetryRealWriteDesktopStore = ${function:Write-DesktopSnapshotStore}
    . $script:SwFakes
    function Read-DesktopSnapshotStore { & $script:RetryRealReadDesktopStore }
    function Write-DesktopSnapshotStore { param($Store) & $script:RetryRealWriteDesktopStore -Store $Store }
    function Test-FullscreenApp { return $false }

    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwDesk[0].Hz = 75; $script:SwDesk[0].RateNum = 75; $script:SwDesk[0].RateDen = 1
    $allKey = Get-DesktopSetKey -DevicePaths @($script:SwDesk | ForEach-Object { $_.Id })
    $oldStoreFile = $script:DesktopSnapshotsFile
    $script:DesktopSnapshotsFile = Join-Path $script:TestDir 'retry-desktop-layouts.json'
    try {
        [void](Switch-DisplayMode -ModeKey 'solo:LG ULTRAGEAR' -Quiet)
        $script:SwDesk[0].Hz = 120; $script:SwDesk[0].RateNum = 120000; $script:SwDesk[0].RateDen = 1000
        [void](Switch-DisplayMode -ModeKey 'all' -KeepMode -Quiet)

        foreach ($attempt in 1, 2) {
            # Simulate the driver dropping the active panel to 60 Hz, then accepting the requested mode
            # while returning a wrong rotation. The failed verification must leave 120 Hz as the durable
            # automatic target even though this display set is now pending and unsafe.
            $script:SwDesk[0].Hz = 60; $script:SwDesk[0].RateNum = 60; $script:SwDesk[0].RateDen = 1
            $script:SwVerifyMismatch = $true
            $failed = Switch-DisplayMode -ModeKey 'all' -Automatic -Quiet
            $roundTrip = Read-DesktopSnapshotStore

            Assert-Equal 'partial' $failed.Outcome "failed automatic attempt $attempt stays partial"
            Assert-Equal 120 $script:SwFullTargets[0].Hz "attempt $attempt still requests the protected rate"
            Assert-Equal 120000 $script:SwFullTargets[0].RateNum "attempt $attempt requests its exact numerator"
            Assert-Equal 1000 $script:SwFullTargets[0].RateDen "attempt $attempt requests its exact denominator"
            Assert-Equal 120 $roundTrip.ProtectedSnapshot.Displays[0].Hz "attempt $attempt keeps that rate after a disk round trip"
            Assert-Equal 120000 $roundTrip.ProtectedSnapshot.Displays[0].RateNum `
                "attempt $attempt keeps the exact numerator after a disk round trip"
            Assert-Equal 1000 $roundTrip.ProtectedSnapshot.Displays[0].RateDen `
                "attempt $attempt keeps the exact denominator after a disk round trip"
            Assert-Equal $allKey $roundTrip.PendingKey "attempt $attempt remains pending"
            Assert-True $roundTrip.UnsafeKeys.ContainsKey($allKey) "attempt $attempt remains guarded"

            $script:SwCalls = @()
            $script:LastRestore = [datetime]::MinValue
            [void](Restore-BestModes -DebounceMs 0)
            Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'best:*' }).Count `
                "the watchdog does not write between attempt $attempt and its retry"
        }

        $script:SwVerifyMismatch = $false
        $recovered = Switch-DisplayMode -ModeKey 'all' -Automatic -Quiet
        $complete = Read-DesktopSnapshotStore
        Assert-True $recovered.Ok 'a later automatic retry can complete'
        Assert-Equal 120 $script:SwDesk[0].Hz 'the retry restores the protected rate instead of the canonical baseline'
        Assert-Equal 75 $complete.Snapshots[$allKey].Displays[0].Hz 'the canonical baseline was never substituted during retries'
        Assert-Equal 120 $complete.ProtectedSnapshot.Displays[0].Hz 'the verified automatic target remains protected'
        Assert-Equal '' $complete.PendingKey 'successful verification clears pending state'
        Assert-True (-not $complete.UnsafeKeys.ContainsKey($allKey)) 'successful verification clears the guard'
    }
    finally {
        $script:DesktopSnapshotsFile = $oldStoreFile
    }
}

Test-Case 'switch: KeepMode refuses a live size that overlaps saved sleeping geometry' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwDesk[0].Width = 1920; $script:SwDesk[0].Height = 1080
    $script:SwDesk[1].X = 1920
    [void](Switch-DisplayMode -ModeKey 'solo:LG ULTRAGEAR' -Quiet)
    $script:SwDesk[0].Width = 2560
    $script:SwCalls = @()

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'all' -KeepMode -Quiet) } catch { $failed = $_.Exception.Message }

    Assert-True ($failed -like '*Windows refused the display configuration*') 'the conflict is refused in the existing switch vocabulary'
    Assert-Equal 0 $script:SwCalls.Count 'nothing external ran after the conflict was found'
}

Test-Case 'switch: KeepMode refuses live dimensions observed under a different rotation' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwDesk[0].Width = 1080; $script:SwDesk[0].Height = 1920; $script:SwDesk[0].Rotation = 4
    [void](Switch-DisplayMode -ModeKey 'solo:LG ULTRAGEAR' -Quiet)
    $script:SwDesk[0].Width = 1920; $script:SwDesk[0].Height = 1080; $script:SwDesk[0].Rotation = 1
    $script:SwCalls = @()

    $failed = ''
    try { [void](Switch-DisplayMode -ModeKey 'all' -KeepMode -Quiet) } catch { $failed = $_.Exception.Message }

    Assert-True ($failed -like '*Windows refused the display configuration*') 'one request cannot keep the landscape source and restore portrait rotation'
    Assert-Equal 0 $script:SwCalls.Count 'the conflict has no topology or mode fallback'
}

Test-Case 'switch: modes are only pushed when the desk actually moved' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)

    # The desk was rebuilt, so "already at its maximum" is no good and the modes get brought up.
    Assert-Equal 3 @($script:SwCalls | Where-Object { $_ -like 'best:*' }).Count 'all three displays got their mode'
    Assert-True ($script:SwCalls -contains 'applied') 'and what they showed was written down'
}

Test-Case 'switch: sound and brightness follow the mode, and only when asked for' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwSettings.audio['all'] = 'ULTRAFINE'
    $script:SwSettings.brightness['all'] = 40

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)

    Assert-True ($script:SwCalls -contains 'audio:ULTRAFINE') 'the playback device was switched'
    Assert-True ($script:SwCalls -match '^levels:') 'and the levels went out over DDC'
    # The order is deliberate: both of them after the mode has happened, and the "after" command at the
    # very end, so it catches a finished state.
    Assert-True ($script:SwCalls.IndexOf('hook:after') -gt $script:SwCalls.IndexOf('audio:ULTRAFINE')) 'after the sound'
}

Test-Case 'switch: nothing set means no slow bus is touched at all' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)

    Assert-True (-not ($script:SwCalls -match '^audio:')) 'no audio device was enumerated'
    Assert-True (-not ($script:SwCalls -match '^levels:')) 'and not a single DDC request went out'
}

Test-Case 'switch: a switch already in progress is skipped, not queued behind it' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    # A mutex belongs to a THREAD rather than to an object: a repeat WaitOne from one's own thread goes
    # straight through, and holding it from the test itself is useless — it would be testing nothing. So a
    # separate thread holds it, and the synchronisation is on named events with a bounded wait: the test
    # has no right to hang, whatever the outcome of the grab.
    $held = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\DeskModesTestHeld')
    $go = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\DeskModesTestGo')
    $holder = [powershell]::Create()
    [void]$holder.AddScript({
        $m = New-Object System.Threading.Mutex($false, 'Local\DeskModesSwitch')
        $got = $m.WaitOne(0)
        # We only signal on a successful grab: if a live tray has taken the mutex, the wait in the test
        # will expire, and the failure will be readable rather than mysterious.
        if ($got) {
            $flag = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\DeskModesTestHeld')
            [void]$flag.Set()
            $wait = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\DeskModesTestGo')
            [void]$wait.WaitOne(10000)
            $m.ReleaseMutex()
        }
        $m.Dispose()
    })
    $task = $holder.BeginInvoke()
    try {
        Assert-True ($held.WaitOne(5000)) 'another thread really holds the switch mutex'

        $r = Switch-DisplayMode -ModeKey 'all' -Quiet

        Assert-True $r.Skipped 'the second switch stands aside'
        Assert-Equal 'all' $r.Mode 'and says which one it was'
        Assert-Equal 'A switch is already in progress.' $r.Message 'in words a person can read'
        Assert-Equal 0 $script:SwCalls.Count 'nothing was done twice'
    }
    finally {
        [void]$go.Set()
        [void]$holder.EndInvoke($task)
        $holder.Dispose()
        $held.Dispose()
        $go.Dispose()
    }
}

Test-Case 'switch: the taskbar is placed even when the settings say nothing about the order' {
    # "Primary" in Windows is not a flag but the place (0, 0), and Set-CcdLayout is the only thing in the
    # whole application that moves anybody there. Behind the `if ($order.Count -gt 0)` that used to guard
    # this call, a desk with no `layout` in the settings - which is every desk until its owner opens the
    # Settings window once - never had its taskbar moved at all: the `primary` setting, a combo's own
    # primary and -PrimaryMatch from the command line were all silently doing nothing, while README and
    # the diary both said the old road "moves only the primary monitor and leaves the rest standing".
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $script:SwSettings.layout = @()
    $script:SwSettings.primary = 'ULTRAFINE'
    $script:SwSettings.primaryOverride = $true
    $script:SwLayoutPrimary = ''

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True $r.Ok 'the switch is a success'
    Assert-True ($script:SwCalls -match '^full:') 'the exact request includes the primary'
    Assert-Equal 'path-uf' $script:SwFullPrimary 'and uses the display the settings explicitly name'
}

Test-Case 'switch: nothing to anchor is not "already correct"' {
    # The display that was to hold the taskbar never came up, so the layout moved nobody. There is a
    # difference between "nothing moved because everything was already right" and "nothing moved because
    # there was nobody to anchor", and the log used to print the first over the second — while the line
    # above it named the display that was not there as the one the taskbar had gone to. The floor below
    # is where the second case is decided (Invoke-CcdLayoutAttempt); here it has to reach the log.
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $script:SwLayoutChanged = $false
    $script:SwLayoutNote = 'layout: the display that was to be primary is not on the desk - nobody moved'

    # Only this switch's own lines are read: the log is one file for the whole run.
    $mark = '--- case: nothing to anchor'
    Write-DisplayLog $mark
    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True $r.Ok 'the layout did not refuse - there was simply nobody to move'
    $log = [System.IO.File]::ReadAllText($script:LogFile)
    $mine = $log.Substring($log.LastIndexOf($mark))
    Assert-True ($mine -like "*$script:SwLayoutNote*") 'the log says why nothing moved'
    Assert-True ($mine -notlike '*layout: already correct*') 'instead of claiming the desk was checked and right'
}

Test-Case 'switch: with an order, the layout gets it whole' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $script:SwSettings.primary = 'ULTRAFINE'
    $script:SwSettings.primaryOverride = $true
    $script:SwSettings.layoutOverride = $true

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)

    Assert-Equal 'path-uf' $script:SwFullPrimary 'the taskbar display'
    Assert-True (-not $script:SwFullExact) 'a display never observed active still takes the verified fallback road'
}

# --- the answer a switch gives ----------------------------------------------
# Two callers in the tray read this and used to derive opposite retry policies out of the pieces: the way
# back from a rule let the desk go on any failure and left a person on the game display for good, while
# the postponed rebuild threw its intent away when a display had not woken and put it back when Windows
# had refused outright. One vocabulary, and it is tested rather than described.

Test-Case 'result: a switch that landed is a success and there is nothing to ask again' {
    $r = New-SwitchResult -ModeKey 'all' -Outcome 'done' -Message 'three displays'
    Assert-True $r.Ok 'Ok'
    Assert-True (-not $r.Retry) 'nothing to retry'
    Assert-True (-not $r.Skipped) 'and it was not skipped'
    Assert-Equal 'all' $r.Mode 'the mode it was about'
}

Test-Case 'result: a display that did not come up is not a success, and is worth another go' {
    # It RAN: the topology went over, the summary is there, the desk moved. And a display still waking up
    # attaches a moment later, which is what the fifteen-second timer is for.
    $r = New-SwitchResult -ModeKey 'combo:Work' -Outcome 'partial' -Message 'did not come up: LG ULTRAFINE'
    Assert-True (-not $r.Ok) 'not a success'
    Assert-True $r.Retry 'but asking again can change it'
    Assert-True (-not $r.Skipped) 'it was not skipped - it happened, partly'
}

Test-Case 'result: a busy mutex is a skip, and the one answer that clears by itself' {
    # The refresh-rate watchdog holds Local\DeskModesSwitch for about a second after every switch,
    # including ours, so this is an ordinary answer on every automatic path.
    $r = New-SwitchResult -ModeKey 'all' -Outcome 'busy' -Message 'A switch is already in progress.'
    Assert-True $r.Skipped 'the command line exits 2 by this'
    Assert-True $r.Retry 'and a second later it is free'
    Assert-True (-not $r.Ok) 'nothing moved'
}

Test-Case 'result: a refusal is final, and reads the same as any other answer' {
    # Switch-DisplayMode reports a refusal by throwing — the message is written for a person and belongs
    # in a balloon — and whoever catches it still has to tell the rules what happened.
    $r = New-SwitchFailure -ModeKey 'solo:GAME' -Message 'That display is not connected right now.'
    Assert-Equal 'refused' $r.Outcome 'a word for it'
    Assert-True (-not $r.Ok) 'not a success'
    Assert-True (-not $r.Retry) 'and fifteen seconds will not change it'
    Assert-True (-not $r.Skipped) 'it did not stand aside either - it tried'
    Assert-Equal 'That display is not connected right now.' $r.Message 'the sentence a person reads'
}

Test-Case 'result: a dry run is a success that touched nothing' {
    $r = New-SwitchResult -ModeKey 'all' -Outcome 'dryrun' -Message 'dry run'
    Assert-True $r.Ok 'the command line exits 0'
    Assert-True (-not $r.Retry) 'and there is nothing to come back for'
}

Test-Case 'result: an outcome nobody defined is refused rather than guessed at' {
    # The set is closed on purpose: a typo in an outcome would otherwise arrive as "not Ok, no retry",
    # which is a policy, silently chosen.
    $threw = $false
    try { [void](New-SwitchResult -ModeKey 'all' -Outcome 'probably') } catch { $threw = $true }
    Assert-True $threw 'the vocabulary is closed'
}

Test-Case 'switch: a mode carrying a picture preset takes it to the bus with the levels' {
    # One walk over the monitors for all three, and the preset is part of it: a second walk would
    # cost another open and destroy of every handle on a bus where one request is tens of
    # milliseconds.
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwSettings.picture = [ordered]@{ 'all' = [ordered]@{ 'ULTRAFINE' = '0x15:45' } }
    $script:SwLevelArgs = $null

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True $r.Ok 'the switch is a success'
    Assert-True (($script:SwCalls -join ',') -match 'levels:') 'the levels step ran'
    Assert-True ($null -ne $script:SwLevelArgs) 'and it was told what to set'
    Assert-Equal '0x15:45' ([string]$script:SwLevelArgs.Picture['ULTRAFINE']) 'the preset came through as written'
}

Test-Case 'switch: a mode with nothing to set on the bus does not go near it' {
    # The dictionaries are empty by default, and then not one request leaves over the slow bus.
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)
    Assert-True (-not (($script:SwCalls -join ',') -match 'levels:')) 'nothing was asked of the monitors'
}

Test-Case 'switch: when none of the wanted displays comes up, the previous set is put back' {
    # A black desk is the one failure a shortcut cannot mend: the person cannot see the menu to try again
    # from. So the set that was on before the switch goes back on, and the switch is a refusal.
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $script:SwSettled = [pscustomobject]@{ Ok = $false; MissingLabels = @('XG27AQDMGR'); ExtraLabels = @() }
    # The ASUS is asked for alone; it never attaches - Get-CcdOutput finds nothing for it.
    function Get-CcdOutput { param([string]$DevicePath) return '' }

    $threw = ''
    try { [void](Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet) } catch { $threw = $_.Exception.Message }

    Assert-True ($threw -like '*previous set was put back*') 'the switch says what it did'
    Assert-Equal 'full:path-ug+path-uf' (@($script:SwCalls | Where-Object { $_ -like 'full:*' })[-1]) 'and the complete previous physical desk is asked for again'
    Assert-True (-not ($script:SwCalls -contains 'lastMode')) 'a mode that never came up is not remembered as the choice'
}

Test-Case 'switch: a topology-only rollback cannot replace the source baseline' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $source = New-DesktopSnapshot -State $script:SwDesk
    $script:RollbackExactAttempts = 0
    $script:SwSettled = [pscustomobject]@{ Ok = $false; MissingLabels = @('XG27AQDMGR'); ExtraLabels = @() }
    function Get-CcdOutput { param([string]$DevicePath) return '' }
    function Set-CcdFullConfig {
        param($Targets, [string]$PrimaryPath, $Order, [switch]$Exact)
        $script:SwCalls += ('full:' + ((@($Targets) | ForEach-Object { $_.DevicePath }) -join '+'))
        if (@($Targets).Count -gt 1) {
            $script:RollbackExactAttempts++
            if ($script:RollbackExactAttempts -eq 1) { return $false }
            $ids = @($Targets | ForEach-Object { $_.DevicePath })
            foreach ($m in @($script:SwDesk)) {
                $m.Active = ($ids -contains $m.Id)
                $m.Primary = ($m.Id -eq $PrimaryPath)
                $t = @($Targets | Where-Object { $_.DevicePath -eq $m.Id } | Select-Object -First 1)
                if ($t.Count -gt 0) {
                    $m.X = [int]$t[0].X; $m.Y = [int]$t[0].Y
                    $m.Rotation = [int]$t[0].Rotation
                }
            }
            return $true
        }
        $script:SwPendingIds = @($Targets | ForEach-Object { $_.DevicePath })
        return $true
    }

    try { [void](Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet) } catch { }

    Assert-True ($script:SwCalls -contains 'topology:path-ug+path-uf') 'the emergency fallback restored only the source set'
    Assert-True $script:SwStore.UnsafeKeys.ContainsKey($source.Key) 'its unverified geometry remains guarded'
    Assert-Equal $source.PrimaryId $script:SwStore.Snapshots[$source.Key].PrimaryId 'the complete source baseline remains intact'

    $script:SwDesk[0].Active = $true; $script:SwDesk[1].Active = $true
    $script:SwDesk[0].X = 777; $script:SwDesk[1].X = 3337
    try { [void](Switch-DisplayMode -ModeKey 'solo:XG27AQDMGR' -Quiet) } catch { }

    Assert-Equal 0 $script:SwDesk[0].X 'the next exact rollback uses the trusted source geometry'
    Assert-True (-not $script:SwStore.UnsafeKeys.ContainsKey($source.Key)) 'only that verified baseline clears the source guard'
}

Test-Case 'switch: one display that came up is kept - a partial verdict, not a revert' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings
    $script:SwSettled = [pscustomobject]@{ Ok = $false; MissingLabels = @('XG27AQDMGR'); ExtraLabels = @() }
    # Only the ASUS stays silent; the two LGs answer as before.
    function Get-CcdOutput {
        param([string]$DevicePath)
        if ($DevicePath -eq 'path-xg') { return '' }
        $m = @($script:SwDesk) | Where-Object { $_.Id -eq $DevicePath } | Select-Object -First 1
        return $(if ($m) { [string]$m.Output } else { '' })
    }

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-Equal 'partial' $r.Outcome 'the desk moved, one display did not follow'
    Assert-True (-not ($script:SwCalls -match '^topology')) 'nothing was put back'
}

Test-Case 'recheck primary: overlapping labels restore the saved physical identity' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwDesk = @($script:SwDesk[0], $script:SwDesk[1])
    $script:SwDesk[0].Label = 'Panel'; $script:SwDesk[1].Label = 'Panel Pro'
    $script:SwSettings = New-SwitchSettings
    Assert-True (Switch-DisplayMode -ModeKey all -Quiet).Ok 'initial All'
    Assert-True (Switch-DisplayMode -ModeKey 'solo:Panel Pro' -Quiet).Ok 'solo'
    Assert-True (Switch-DisplayMode -ModeKey all -Quiet).Ok 'restored All'
    Assert-Equal 'path-ug' (@($script:SwDesk | Where-Object Primary)[0].Id) 'saved identity wins over ambiguous label'
    Assert-Equal 0 $script:SwDesk[0].X 'saved origin is retained'
}

Test-Case 'recheck KeepMode: generated first All preserves the live exact rate without cache' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwDesk[1].Active = $false
    foreach ($m in $script:SwDesk) { $m.Native = [pscustomobject]@{ Width = 2560; Height = 1440 } }
    function Set-WantedModes {
        param($Wanted, [switch]$KeepMode, [switch]$AlreadyBest)
        # Only newly awakened targets have an unspecified mode. The fake driver selects a valid default
        # for them; an already active panel must retain the exact request and is checked separately.
        foreach ($m in $script:SwDesk) {
            if ($m.Hz -eq 0) { $m.Hz = 60; $m.RateNum = 60; $m.RateDen = 1 }
            if ($m.Rotation -eq 0) { $m.Rotation = 1 }
        }
        return [pscustomobject]@{ Summary = @('fake modes'); Failed = @(); Applied = @{}; LevelTargets = @() }
    }
    $script:SwSettings = New-SwitchSettings
    $r = Switch-DisplayMode -ModeKey all -KeepMode -Quiet
    Assert-True $r.Ok 'generated request succeeds'
    Assert-True (-not $script:SwFullExact) 'the destination has no coherent snapshot'
    Assert-Equal 143999 $script:SwFullTargets[0].RateNum 'live numerator is requested'
    Assert-Equal 1000 $script:SwFullTargets[0].RateDen 'live denominator is requested'
}

Test-Case 'recheck KeepMode: generated refusal never falls back to topology-only modes' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwDesk[1].Active = $false
    foreach ($m in $script:SwDesk) { $m.Native = [pscustomobject]@{ Width = 2560; Height = 1440 } }
    function Set-WantedModes {
        param($Wanted, [switch]$KeepMode, [switch]$AlreadyBest)
        # Only newly awakened targets have an unspecified mode. The fake driver selects a valid default
        # for them; an already active panel must retain the exact request and is checked separately.
        foreach ($m in $script:SwDesk) {
            if ($m.Hz -eq 0) { $m.Hz = 60; $m.RateNum = 60; $m.RateDen = 1 }
            if ($m.Rotation -eq 0) { $m.Rotation = 1 }
        }
        return [pscustomobject]@{ Summary = @('fake modes'); Failed = @(); Applied = @{}; LevelTargets = @() }
    }
    $script:SwSettings = New-SwitchSettings
    $script:SwFullOk = $false
    $refused = $false
    try { [void](Switch-DisplayMode -ModeKey all -KeepMode -Quiet) }
    catch { $refused = $true }
    Assert-True $refused 'refusal remains a refusal'
    Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'topology:*' }).Count 'no lossy topology fallback'
}

Test-Case 'recheck KeepMode: generated driver drift is rejected before learning the result' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwDesk[1].Active = $false
    foreach ($m in $script:SwDesk) { $m.Native = [pscustomobject]@{ Width = 2560; Height = 1440 } }
    function Set-WantedModes {
        param($Wanted, [switch]$KeepMode, [switch]$AlreadyBest)
        # Only newly awakened targets have an unspecified mode. The fake driver selects a valid default
        # for them; an already active panel must retain the exact request and is checked separately.
        foreach ($m in $script:SwDesk) {
            if ($m.Hz -eq 0) { $m.Hz = 60; $m.RateNum = 60; $m.RateDen = 1 }
            if ($m.Rotation -eq 0) { $m.Rotation = 1 }
        }
        return [pscustomobject]@{ Summary = @('fake modes'); Failed = @(); Applied = @{}; LevelTargets = @() }
    }
    $script:SwSettings = New-SwitchSettings
    function Wait-ForTopology {
        param($WantedPaths)
        foreach ($m in $script:SwDesk) { $m.Active = $true }
        $script:SwDesk[0].RateNum = 60; $script:SwDesk[0].RateDen = 1
        return $script:SwSettled
    }
    $r = Switch-DisplayMode -ModeKey all -KeepMode -Quiet
    Assert-True (-not $r.Ok) 'a changed live refresh fraction fails verification'
    $key = Get-DesktopSetKey -DevicePaths @($script:SwDesk | ForEach-Object Id)
    Assert-True (-not $script:SwStore.Snapshots.ContainsKey($key)) 'the drift is not learned'
}
