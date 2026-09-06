#Requires -Version 5.1

<#
.SYNOPSIS
    Switches the displays on your desk from the command line.

.DESCRIPTION
    Turns on the displays a mode names and puts the rest into standby, arranged in
    the order you gave them, with the taskbar where you asked for it. Also reports
    what Windows sees right now, without changing anything.

    All the logic lives in DisplayCore.ps1; this script only parses arguments and
    prints. Exit code 0 on success, 2 when another switch is already running, 1 on
    failure - so .cmd wrappers can tell the difference.

.PARAMETER Mode
    What to switch to, or what to report. Resolved in this order: an exact mode key
    ("solo:LG ULTRAGEAR", "combo:Work", "all"), a combination name from the
    settings, a display's short Monitor ID, then part of a display's name.
    "back" is the mode that was left last, whoever switched away from it.

    These names report instead of switching:
      status      what the system shows right now (read-only, the default)
      modes       every mode key with its shortcut
      diagnostics a shareable JSON snapshot without settings, paths, hooks or diary
      brightness  which displays answer over DDC/CI, at what level, and on which
                  picture preset
      hdr         which displays can do HDR, and whether it is on right now
      audio       playback device names, for the "audio" setting
      stats       the diary: what, where and for how long

.PARAMETER PrimaryMatch
    Which display keeps the taskbar, by part of its name. Unlike the "primary"
    setting this one is strict: matching nothing is an error, not a silent fallback.

.PARAMETER KeepMode
    Leave resolution and refresh rate alone instead of raising them to the maximum.

.PARAMETER DryRun
    Print what would be done and change nothing.

.EXAMPLE
    .\Set-Display.ps1
    Reports the displays, their current and best modes, and which one is primary.

.EXAMPLE
    .\Set-Display.ps1 "Movie night"
    Switches to the combination named "Movie night" in the settings.

.EXAMPLE
    .\Set-Display.ps1 ULTRAGEAR -PrimaryMatch ULTRAGEAR
    Leaves only the display whose name contains "ULTRAGEAR" on, with the taskbar
    on it.

.EXAMPLE
    .\Set-Display.ps1 all -DryRun
    Shows what switching to every connected display would do.

.LINK
    README.md
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Mode = 'status',

    [string]$PrimaryMatch,
    [switch]$KeepMode,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DisplayCore.ps1')
. (Join-Path $PSScriptRoot 'Diagnostics.ps1')
. (Join-Path $PSScriptRoot 'WindowLayout.ps1')
. (Join-Path $PSScriptRoot 'Activity.ps1')

function Resolve-ModeKey {
    param([string]$Text, $Modes)

    # the mode before the current one - whatever was left last, by this tool, from anywhere
    if ($Text -eq $script:BackHotkeyName) {
        $Text = [string](Get-PreviousModeKey)
        if (-not $Text) { throw 'Nothing to go back to yet - no mode has been left from this folder.' }
    }

    # the exact key
    $hit = $Modes | Where-Object { $_.Key -eq $Text } | Select-Object -First 1
    if ($hit) { return $hit }

    # a combo name as it is written in the settings; case does not matter, so that
    # wrappers like work.cmd find the "Work" combo.
    $hit = $Modes | Where-Object { $_.Kind -eq 'combo' -and $_.Title -eq $Text } | Select-Object -First 1
    if ($hit) { return $hit }

    # the short Monitor ID
    $hit = @($Modes | Where-Object { $_.Kind -eq 'solo' -and $_.ShortId -eq $Text })
    if ($hit.Count -eq 1) { return $hit[0] }
    if ($hit.Count -gt 1) {
        throw ("'$Text' matches several modes: " + (($hit | ForEach-Object { $_.Key }) -join ', '))
    }

    # part of a monitor's name
    $hit = @($Modes | Where-Object { $_.Kind -eq 'solo' -and (Test-DisplayNameMatch -Pattern $Text -Label $_.Label -ShortId '') })
    if ($hit.Count -eq 1) { return $hit[0] }
    if ($hit.Count -gt 1) {
        throw ("'$Text' matches several modes: " + (($hit | ForEach-Object { $_.Key }) -join ', '))
    }
    throw "Unknown mode '$Text'. Run: .\Set-Display.ps1 modes"
}

# The settings are read once and handed on: the modes need to know what the combos
# are made of. Otherwise every consumer would go to disk on its own.
$settings = Get-DisplaySettings
$state = @(Get-DisplayState)

# The roster is learned and read here as well as in the tray, because the command line is a whole
# way of using this on its own: without it `status` and `modes` would hide a display that is
# merely switched off, and asking for one by name would answer "Unknown mode" instead of the
# sentence that says what is actually wrong. It costs one small read; the switch below asks
# Windows for the state again itself, so nothing on the measured path changed.
[void](Update-KnownDisplays -State $state)
$state = @(Get-DeskDisplays -State $state)

if ($Mode -eq 'diagnostics') {
    Format-DisplayDiagnostics -State $state
    return
}

if ($Mode -eq 'status') {
    Write-Host ''
    # The version on the first line: status is what a person copies into a bug
    # report, and without it the report has to be asked about twice.
    Write-Host (Get-VersionLine) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Displays:' -ForegroundColor Cyan
    $state |
        Select-Object Output, Label, ShortId,
                      @{n = 'Current'; e = { '{0}x{1} @ {2}' -f $_.Width, $_.Height, $_.Hz } },
                      @{n = 'Best';    e = {
                            if ($_.BestMode) { '{0}x{1} @ {2}' -f $_.BestMode.Width, $_.BestMode.Height, $_.BestMode.Hz } else { '?' } } },
                      @{n = 'State';   e = { if ($_.Disconnected) { 'unplugged' } elseif ($_.Active) { 'on' } else { 'off' } } },
                      @{n = 'Primary'; e = { if ($_.Primary) { '*' } else { '' } } } |
        Format-Table -AutoSize
    return
}

if ($Mode -eq 'audio') {
    # Needed to know which part of a name to write into settings.json -> audio.
    # There is deliberately no window for this setting, and guessing device names
    # from memory is impossible.
    Write-Host ''
    Write-Host 'Playback devices:' -ForegroundColor Cyan
    $devs = @(Get-AudioDevices)
    if ($devs.Count -eq 0) { Write-Host '  (none found)'; return }
    $devs |
        Select-Object @{n = 'Default'; e = { if ($_.IsDefault) { '*' } else { '' } } },
                      @{n = 'Name';    e = { $_.Name } } |
        Format-Table -AutoSize
    Write-Host 'Put a distinctive part of a name into settings.json, for example:' -ForegroundColor DarkGray
    Write-Host '    "audio": { "combo:Work": "ULTRAFINE", "solo:XG27AQDMGR": "ROG" }' -ForegroundColor DarkGray
    return
}

if ($Mode -eq 'brightness') {
    # Needed to know two things before writing anything into settings.json: whether
    # the monitor listens over DDC/CI at all, and what its brightness is right now.
    # Sleeping monitors will not show up in the list — they answer nothing.
    Write-Host ''
    Write-Host 'Monitors that answer over DDC/CI:' -ForegroundColor Cyan
    $levels = @(Get-MonitorLevels)
    if ($levels.Count -eq 0) {
        Write-Host '  (none answered - only displays that are ON can be asked)'
        return
    }
    # The monitor name comes from the state: DDC hands out "Generic PnP Monitor" to
    # everything, and picking the right one out of such a list is impossible.
    $byOutput = @{}
    foreach ($m in $state) { if ($m.Output) { $byOutput[[string]$m.Output] = [string]$m.Label } }
    # And the picture preset each monitor is holding, in the form settings.json takes it: this is
    # the number to start from when writing that setting by hand, and the Settings window's
    # Remember button is the other way of learning it.
    $presets = @{}
    foreach ($one in @(Get-MonitorPictures)) {
        if ($one.Answered) { $presets[[string]$one.Device] = Format-PictureSetting -Code ([int]$one.Code) -Value ([int]$one.Value) }
    }
    $levels |
        Select-Object @{n = 'Display';    e = { if ($byOutput.Contains([string]$_.Device)) { $byOutput[[string]$_.Device] } else { $_.Device } } },
                      @{n = 'Brightness'; e = { if ($_.CanBrightness) { '{0} ({1}..{2})' -f $_.Brightness, $_.BrightnessMin, $_.BrightnessMax } else { 'not supported' } } },
                      @{n = 'Contrast';   e = { if ($_.CanContrast) { [string]$_.Contrast } else { 'not supported' } } },
                      @{n = 'Preset';     e = { if ($presets.Contains([string]$_.Device)) { $presets[[string]$_.Device] } else { 'no answer' } } } |
        Format-Table -AutoSize
    Write-Host 'Put the levels you want into settings.json, for example:' -ForegroundColor DarkGray
    Write-Host '    "brightness": { "combo:Work": 80, "combo:Movie night": { "ULTRAFINE": 25 } }' -ForegroundColor DarkGray
    Write-Host 'The Preset column is a register and a number, and it goes in the same shape:' -ForegroundColor DarkGray
    Write-Host '    "picture": { "combo:Work": { "ULTRAFINE": "0x15:45" } }' -ForegroundColor DarkGray
    return
}

if ($Mode -eq 'hdr') {
    # What to expect before writing an "hdr" entry: a display that cannot do it is left alone by the
    # switch, and the log says so - this is where to see it up front.
    Write-Host ''
    Write-Host 'HDR:' -ForegroundColor Cyan
    $rows = @()
    foreach ($t in @(Get-CcdTargets | Where-Object { $_.Active })) {
        $hdr = Get-DisplayHdr -Target $t
        $rows += [pscustomobject]@{
            Display   = $t.Label
            Supported = $(if (-not $hdr) { '?' } elseif ($hdr.Supported) { 'yes' } else { 'no' })
            On        = $(if (-not $hdr) { '?' } elseif ($hdr.Enabled) { 'yes' } else { 'no' })
        }
    }
    if ($rows.Count -eq 0) { Write-Host '  (no display is on)'; return }
    $rows | Format-Table -AutoSize
    Write-Host 'Put it into settings.json as part of a mode, for example:' -ForegroundColor DarkGray
    Write-Host '    "hdr": { "combo:Game": true, "combo:Work": { "ULTRAGEAR": false } }' -ForegroundColor DarkGray
    return
}

if ($Mode -eq 'stats') {
    if (-not $settings.stats) {
        Write-Host ''
        Write-Host 'The diary is off. Turn on "Keep a diary" in Settings (or set "stats": true).' -ForegroundColor Yellow
    }
    Format-ActivityReport -Report (Get-ActivityReport -Store (Get-ActivityStore) -Days 30) |
        ForEach-Object { Write-Host $_ }
    return
}

$modes = @(Get-DisplayModes -State $state -Settings $settings)

if ($Mode -eq 'modes') {
    Write-Host ''
    Write-Host 'Modes:' -ForegroundColor Cyan
    $modes |
        Select-Object Key, Title,
                      @{n = 'Hotkey';    e = { $settings.hotkeys[$_.Key] } },
                      @{n = 'Available'; e = { if ($_.Available) { 'yes' } else { 'no' } } } |
        Format-Table -AutoSize
    return
}

# A refusal here is a sentence, not a stack trace. Every one of these messages is written for a person
# ("Unknown mode 'work'", "That display is not connected right now"), and under
# $ErrorActionPreference = 'Stop' they used to arrive as a red wall of PowerShell internals — in a window
# that closes the instant it appears, since the .cmd wrappers only pause on a failure.
try {
    $resolved = Resolve-ModeKey -Text $Mode -Modes $modes
    $result = Switch-DisplayMode -ModeKey $resolved.Key -PrimaryMatch $PrimaryMatch -KeepMode:$KeepMode -DryRun:$DryRun
}
catch {
    Write-Host ''
    Write-Host ("Problem: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

# The exit code matters more than the text: on a complete failure the message is
# empty, and the .cmd files would report success silently and with code 0.
if (-not $result) { exit 1 }
if ($result.Skipped) {
    Write-Host ''
    Write-Host $result.Message -ForegroundColor Yellow
    exit 2
}

Write-Host ''
if ($result.Ok) {
    Write-Host "Now: $($result.Message)" -ForegroundColor Green
    exit 0
}

$text = $result.Message
if (-not $text) { $text = 'nothing came up - the displays did not attach' }
Write-Host "Problem: $text" -ForegroundColor Red
exit 1
