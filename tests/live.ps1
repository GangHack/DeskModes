#Requires -Version 5.1

<#
    tests\live.ps1 — a run against the REAL desk. By hand only, never in CI and never by default.

    Why it exists when there is a whole suite of ordinary cases: all of this project's value is in its
    behaviour on real hardware. P/Invoke signatures, the driver's refusals, the time a monitor takes to
    wake up, the refresh-rate fraction this particular graphics card will accept — not one fake
    reproduces any of that. Open risk number one here reads as "nobody has run this on anything but
    one desk", and a scripted run answers it better than a run from memory.

    This is a checklist and not a second test suite: it goes through every mode in the settings, checks
    the membership, the primary monitor, the layout and the refresh rates after each one, and puts the
    desk back as it was. The screens will blink.

        .\tests\live.ps1 -ReadOnly    the CLI smoke test only, do not touch the monitors
        .\tests\live.ps1                 the full run, with a confirmation
        .\tests\live.ps1 -Yes            the full run without any questions

    There is no need to shut the tray down: its refresh-rate watchdog takes the same mutex as a switch
    and holds it for about a second after every step — which is why the switches here go with a retry
    rather than in one pass.

    The log is NOT redirected: the done: lines in last-run.log ARE the speed measurement, and they have
    to be compared against the past weeks rather than against an empty file.

    Exit code: 0 — everything agreed, 1 — there are discrepancies, 2 — the run never started.
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$ReadOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# This file has no business in CI: there are no monitors there, and no person to see that the desk was
# left in pieces.
if ($env:CI -or $env:GITHUB_ACTIONS -or $env:TF_BUILD) {
    Write-Host 'live.ps1 drives real displays and never runs in CI.' -ForegroundColor Yellow
    exit 2
}

. (Join-Path $root 'DisplayCore.ps1')
. (Join-Path $root 'WindowLayout.ps1')
. (Join-Path $root 'Activity.ps1')

$script:Bad = 0

function Write-LiveCheck {
    param([bool]$Ok, [string]$What, [string]$Detail = '')
    if ($Ok) { Write-Host ("  +  {0}" -f $What) -ForegroundColor Green }
    else {
        $script:Bad++
        Write-Host ("  x  {0}" -f $What) -ForegroundColor Red
        if ($Detail) { Write-Host ("       {0}" -f $Detail) -ForegroundColor DarkRed }
    }
}

# The last done: line is a measurement the switch left behind itself. We read it out of the log rather
# than counting the seconds here: what has to be compared is exactly the number that sits in the file
# for the past weeks.
function Get-LastDoneLine {
    try {
        $tail = @(Get-Content -LiteralPath $script:LogFile -Tail 40 -ErrorAction Stop)
        $line = @($tail | Where-Object { $_ -match '\sdone: ' })[-1]
        if ($line -match '\((\d+[.,]\d+) s') { return $Matches[1] }
    }
    catch { }   # the log may not exist at all — that is no reason to bring the run down
    return ''
}

# A switch with a retry, and the retry here is not belt and braces.
#
# The refresh-rate watchdog in a live tray (Restore-BestModes) takes THE SAME named mutex
# Local\ScreenDeckSwitch and holds it while it gathers state — by its own comment, about a second. It
# gets the DisplaySettingsChanged event from OUR switch, so the busy window opens right after every
# successful step. A run that fires modes off with no pause lands in that window every time: the first
# step goes through and all the rest get a skip. Verified 2026-08-26 — that is exactly what happened.
#
# Shutting the tray down for the run's sake is wrong: the tray being running is the machine's NORMAL
# state, and that is what has to be tested. A person pressing shortcuts lands in the same second and
# simply presses again.
function Invoke-LiveSwitch {
    param([Parameter(Mandatory)][string]$Key, [int]$Attempts = 5, [int]$WaitMs = 1500)

    for ($i = 1; $i -le $Attempts; $i++) {
        try { $r = Switch-DisplayMode -ModeKey $Key -Quiet }
        catch {
            Write-LiveCheck $false 'the switch itself went through' $_.Exception.Message
            return $null
        }
        if (-not $r.Skipped) {
            if ($i -gt 1) {
                Write-Host ("       took {0} attempts - the tray watchdog held the mutex" -f $i) -ForegroundColor DarkGray
            }
            return $r
        }
        Start-Sleep -Milliseconds $WaitMs
    }

    Write-LiveCheck $false 'the switch got its turn' `
        ("skipped $Attempts times - something holds Local\ScreenDeckSwitch far longer than the watchdog does")
    return $null
}

function Invoke-Cli {
    param([string[]]$CliArgs)

    # 'Continue' is mandatory here, and it is not belt and braces. The child powershell.exe writes its
    # refusal to stderr, and `2>&1` turns that into an error record; with $ErrorActionPreference = 'Stop'
    # such a record from a NON-PowerShell command is terminating, and the run used to die on exactly the
    # case that checks for exit code 1. The assignment is local: outside the function the preference is
    # the same.
    $ErrorActionPreference = 'Continue'

    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Set-Display.ps1') @CliArgs 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n") }
}

# --- the command-line smoke test: it changes nothing -------------------------

Write-Host ''
Write-Host 'ScreenDeck - live' -ForegroundColor Cyan
Write-Host ''
Write-Host 'the command line (read-only)' -ForegroundColor White

$r = Invoke-Cli @('status')
Write-LiveCheck ($r.Code -eq 0) 'status exits 0' "exit $($r.Code)"
Write-LiveCheck ($r.Text -match 'primary') 'status says which display is primary' $r.Text

$r = Invoke-Cli @('modes')
Write-LiveCheck ($r.Code -eq 0) 'modes exits 0' "exit $($r.Code)"
Write-LiveCheck ($r.Text -match 'Modes:') 'modes prints the list' $r.Text

$r = Invoke-Cli @('brightness')
Write-LiveCheck ($r.Code -eq 0) 'brightness exits 0 even when nothing answers over DDC' "exit $($r.Code)"

# An unknown name is an error with code 1 rather than a silent success: the .cmd wrappers judge by the
# code specifically.
$r = Invoke-Cli @('no-such-display-anywhere')
Write-LiveCheck ($r.Code -eq 1) 'an unknown name exits 1' "exit $($r.Code)"

$before = @(Get-DisplayState | Where-Object { $_.Active } | ForEach-Object { $_.Id } | Sort-Object)
$r = Invoke-Cli @('all', '-DryRun')
$after = @(Get-DisplayState | Where-Object { $_.Active } | ForEach-Object { $_.Id } | Sort-Object)
Write-LiveCheck ($r.Code -eq 0) '-DryRun exits 0' "exit $($r.Code)"
Write-LiveCheck (-not (Compare-Object $before $after)) '-DryRun changed nothing on the desk'

if ($ReadOnly) {
    Write-Host ''
    Write-Host ('Read-only part done. ' + $(if ($script:Bad -eq 0) { 'All good.' } else { "$($script:Bad) problem(s)." }))
    Write-Host ''
    exit $(if ($script:Bad -eq 0) { 0 } else { 1 })
}

# --- the full run over the modes ---------------------------------------------

$settings = Get-DisplaySettings
$state = @(Get-DisplayState)
$modes = @(Get-DisplayModes -State $state -Settings $settings)
$available = @($modes | Where-Object { $_.Available })
$wasKey = Get-ActiveModeKey -State $state -Modes $modes

Write-Host ''
Write-Host ('About to switch through {0} mode(s): {1}' -f $available.Count, ((@($available | ForEach-Object { $_.Title })) -join ', '))
Write-Host ('The desk will be put back to: {0}' -f $(if ($wasKey) { $wasKey } else { 'all (nothing matched what is on now)' }))
Write-Host 'Screens will blink. Close anything you would hate to see moved.' -ForegroundColor Yellow

if (-not $Yes) {
    $answer = Read-Host 'Type yes to go ahead'
    if ($answer -ne 'yes') {
        Write-Host 'Nothing was done.' -ForegroundColor Yellow
        exit 2
    }
}

foreach ($mode in $available) {
    Write-Host ''
    Write-Host $mode.Title -ForegroundColor White

    $switched = Invoke-LiveSwitch -Key $mode.Key
    if (-not $switched) { continue }

    $now = @(Get-DisplayState)
    $nowModes = @(Get-DisplayModes -State $now -Settings $settings)
    $thisMode = @($nowModes | Where-Object { $_.Key -eq $mode.Key })[0]
    if (-not $thisMode) { $thisMode = $mode }

    # The membership. We compare against what the mode asks of the CURRENT desk: a monitor could have
    # dropped off mid-run, and then the honest answer is the new membership rather than the old one.
    $want = @(Get-ModeMembers -Mode $thisMode -State $now | ForEach-Object { $_.Id } | Sort-Object)
    $on = @($now | Where-Object { $_.Active } | ForEach-Object { $_.Id } | Sort-Object)
    Write-LiveCheck (-not (Compare-Object $want $on)) 'the set on the desk is the set the mode names' `
        ("wanted [{0}], got [{1}]" -f ($want -join ', '), ($on -join ', '))

    # The primary monitor — the same ladder of choice as in a switch.
    $primary = Select-PrimaryDisplay -Wanted @($now | Where-Object { $_.Active }) -PrimaryMatch '' `
                                     -ModePrimary ([string]$thisMode.Primary) `
                                     -SettingsPrimary ([string]$settings.primary) `
                                     -Layout @($settings.layout) -ModeTitle $thisMode.Title
    $isPrimary = @($now | Where-Object { $_.Primary } | ForEach-Object { $_.Id })
    Write-LiveCheck ($isPrimary -contains $primary.Id) 'the taskbar is on the display the settings ask for' `
        ("wanted [{0}], got [{1}]" -f $primary.Label, ($isPrimary -join ', '))

    # The layout: the X coordinates have to match the same arithmetic they were set by. A discrepancy
    # here means the monitors have drifted apart.
    if (@($settings.layout).Count -gt 0) {
        $screens = @($now | Where-Object { $_.Active } | ForEach-Object {
            [pscustomobject]@{ DevicePath = $_.Id; Label = $_.Label; Width = $_.Width; Height = $_.Height }
        })
        $expect = Get-LayoutPositions -Screens $screens -Order @($settings.layout) -PrimaryPath $primary.Id
        $actual = Get-CcdSourcePositions
        $off = @()
        foreach ($p in @($expect.Keys)) {
            if (-not $actual.ContainsKey($p)) { $off += "$p missing"; continue }
            if ($actual[$p].X -ne $expect[$p].X -or $actual[$p].Y -ne $expect[$p].Y) {
                $off += ("{0}: wanted {1},{2} got {3},{4}" -f $p, $expect[$p].X, $expect[$p].Y, $actual[$p].X, $actual[$p].Y)
            }
        }
        Write-LiveCheck ($off.Count -eq 0) 'the displays stand where the layout says' ($off -join '; ')
    }

    # The refresh rates: without -KeepMode a switch has to bring every monitor up to its maximum. That
    # is precisely what Windows drops by itself most often.
    $lower = @($now | Where-Object { $_.Active -and $_.BestMode } | Where-Object {
        $_.Width -ne $_.BestMode.Width -or $_.Height -ne $_.BestMode.Height -or $_.Hz -ne $_.BestMode.Hz
    } | ForEach-Object { "$($_.Label) $($_.Width)x$($_.Height)@$($_.Hz) (best $($_.BestMode.Width)x$($_.BestMode.Height)@$($_.BestMode.Hz))" })
    Write-LiveCheck ($lower.Count -eq 0) 'every display sits in its best mode' ($lower -join '; ')

    $took = Get-LastDoneLine
    if ($took) { Write-Host ("       took {0} s (compare with the weeks before it in last-run.log)" -f $took) -ForegroundColor DarkGray }
}

# --- put it back as it was ---------------------------------------------------

Write-Host ''
Write-Host 'putting the desk back' -ForegroundColor White

$backTo = $(if ($wasKey) { $wasKey } else { 'all' })
if (Invoke-LiveSwitch -Key $backTo) { Write-LiveCheck $true "back to $backTo" }

Write-Host ''
if ($script:Bad -eq 0) {
    Write-Host 'Live run: everything matched.' -ForegroundColor Green
    Write-Host ''
    exit 0
}
Write-Host ("Live run: {0} problem(s) - see the red lines above and last-run.log." -f $script:Bad) -ForegroundColor Red
Write-Host ''
exit 1
