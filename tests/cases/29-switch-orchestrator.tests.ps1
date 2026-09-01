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

    function Get-DisplaySettings { return $script:SwSettings }
    function Get-DisplayState { return @($script:SwDesk) }

    # The cache of verified modes is shadowed on purpose: the file in the temporary folder is left behind
    # by other groups of cases, and without this the set of targets would depend on the order of the run.
    function Get-ModeCache { return @{} }

    function Invoke-ModeHook {
        param($Settings, [string]$ModeKey, [string]$Phase)
        $script:SwCalls += "hook:$Phase"
        return $true
    }

    function Save-WindowLayout { param([string]$Key) $script:SwCalls += 'windows:save' }
    function Restore-WindowLayout { param([string]$Key) $script:SwCalls += 'windows:restore' }

    function Set-CcdFullConfig {
        param($Targets, [string]$PrimaryPath, $Order)
        $script:SwCalls += ('full:' + ((@($Targets) | ForEach-Object { $_.DevicePath }) -join '+'))
        $script:SwFullPrimary = $PrimaryPath
        return $script:SwFullOk
    }

    function Set-CcdTopology {
        param($DevicePaths)
        $script:SwCalls += ('topology:' + (@($DevicePaths) -join '+'))
        return $script:SwTopologyOk
    }

    function Wait-ForTopology {
        param($WantedPaths)
        $script:SwCalls += 'settle'
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
        param($Targets, $BrightnessSetting, $ContrastSetting)
        $script:SwCalls += ('levels:' + ((@($Targets) | ForEach-Object { $_.Label }) -join '+'))
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
    # The layout and the modes are checked anyway: the set can match while the desk is in pieces — after
    # DisplaySwitch /extend, for instance.
    Assert-True ($script:SwCalls -contains 'layout') 'the layout is still checked'
    Assert-Equal 'hook:before,layout,lastMode,applied,hook:after' ($script:SwCalls -join ',') 'and that is the whole of it'
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

Test-Case 'switch: a layout that would not lie down is not reported as success' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk
    $script:SwSettings = New-SwitchSettings
    $script:SwLayoutOk = $false

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True (-not $r.Ok) 'a silent success on scrambled displays is the worst possible message'
    Assert-True ($r.Message -like '*positions not arranged*') 'the text says what to do about it'
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

Test-Case 'switch: -KeepMode leaves resolution and refresh rate alone' {
    . $script:SwFakes
    $script:SwDesk = New-SwitchDesk -ThirdActive $false
    $script:SwSettings = New-SwitchSettings

    $r = Switch-DisplayMode -ModeKey 'all' -KeepMode -Quiet

    Assert-True $r.Ok 'the switch still lands'
    Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'best:*' }).Count 'nobody was pushed to its best mode'
    # And another thing: for a sleeping monitor there is no "leave it as it is" — it has no current mode.
    # The set goes to the old road whole, and that is not a breakage but the only honest answer: mixing
    # specified sizes with unspecified ones in one request means guessing what the system will do with the
    # remainder.
    Assert-Equal 0 @($script:SwCalls | Where-Object { $_ -like 'full:*' }).Count 'the one-call road needs modes, so it is not even tried'
    Assert-Equal 1 @($script:SwCalls | Where-Object { $_ -like 'topology:*' }).Count 'the set alone is asked for instead'
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
    $held = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\ScreenDeckTestHeld')
    $go = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\ScreenDeckTestGo')
    $holder = [powershell]::Create()
    [void]$holder.AddScript({
        $m = New-Object System.Threading.Mutex($false, 'Local\ScreenDeckSwitch')
        $got = $m.WaitOne(0)
        # We only signal on a successful grab: if a live tray has taken the mutex, the wait in the test
        # will expire, and the failure will be readable rather than mysterious.
        if ($got) {
            $flag = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\ScreenDeckTestHeld')
            [void]$flag.Set()
            $wait = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\ScreenDeckTestGo')
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
    $script:SwLayoutPrimary = ''

    $r = Switch-DisplayMode -ModeKey 'all' -Quiet

    Assert-True $r.Ok 'the switch is a success'
    Assert-True ($script:SwCalls -contains 'layout') 'the desk was still asked to place the taskbar'
    Assert-Equal 'path-uf' $script:SwLayoutPrimary 'and on the display the settings name'
    Assert-Equal 0 $script:SwLayoutOrder.Count 'with no order to arrange by - only the primary moves'
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

    [void](Switch-DisplayMode -ModeKey 'all' -Quiet)

    Assert-Equal 'path-uf' $script:SwLayoutPrimary 'the taskbar display'
    Assert-Equal 3 $script:SwLayoutOrder.Count 'and all three names, in the order from the settings'
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
    # The refresh-rate watchdog holds Local\ScreenDeckSwitch for about a second after every switch,
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
