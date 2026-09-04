#Requires -Version 5.1

<#
    tools\trace-displays.ps1 — one timeline out of two logs.

    Our log knows what the switcher DECIDED. Windows knows what happened to the hardware. Apart,
    those two halves answer different questions, and on 28 August an evening went on putting them
    together by hand.

    Windows writes a monitor dropping off here:

        Microsoft-Windows-Kernel-PnP/Device Management, event 1010

    That is the very "the monitor went out by itself": it left the bus — fell asleep on its own
    button, flapped its link, or the driver stopped seeing it. The event arrives a second or two
    EARLIER than the tray notices, so in a shared timeline it is visible what was the cause and
    what was the effect.

        .\tools\trace-displays.ps1              the last twenty-four hours
        .\tools\trace-displays.ps1 -Hours 3     the last three hours
        .\tools\trace-displays.ps1 -All         everything there is in both logs

    It only reads. It changes nothing, on the desk or on the disk.
#>
[CmdletBinding()]
param(
    [int]$Hours = 24,
    [switch]$All
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

# The same answer DisplayCore.ps1 gives itself (see $script:LogFile there): the environment variable wins,
# and the tests set it. Reading last-run.log unconditionally meant that whoever ran this after a test run
# was handed the wrong file with no hint of it.
$logFile = $(if ($env:DESKMODES_LOG_FILE) { $env:DESKMODES_LOG_FILE } else { Join-Path $root 'last-run.log' })

# And its predecessor. The log rotates at half a megabyte, and the rotation renames the file to
# .old — so "the last twenty-four hours" straddles the seam whenever it happens to have just rotated, and
# the hour before the rotation was simply not in the timeline. Oldest first, so the ordinal below still
# counts in the order the lines were written.
$logFiles = @(($logFile + '.old'), $logFile)

$since = $(if ($All) { [datetime]'1970-01-01' } else { (Get-Date).AddHours(-$Hours) })

# --- our log ----------------------------------------------------------------
# Lines of the form "2026-08-28 21:06:43  reapply: ...". Anything that does not start with a date is
# a continuation of the previous line, and it does not go into the timeline.
# Order carries the tie-break. The stamp is only accurate to the second and a single switch writes up to
# nine lines inside one — and Sort-Object in PowerShell 5.1 is NOT stable (there is no -Stable here), so
# sorting on the stamp alone shuffles them: measured on this repo's own log, 925 same-second pairs came
# back out of file order, with "done:" printed above the "--- start" that caused it. The whole tool is the
# claim that a line below another is a reaction to it, so the ordinal is not a nicety.
$ordinal = 0
$ours = @()
foreach ($file in $logFiles) {
    if (-not (Test-Path -LiteralPath $file)) { continue }
    foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
        if ($line -notmatch '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+(.*)$') { continue }
        $when = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss',
                                       [System.Globalization.CultureInfo]::InvariantCulture)
        if ($when -lt $since) { continue }
        $ordinal++
        $ours += [pscustomobject]@{ When = $when; Source = 'deck'; Text = $Matches[2]; Ordinal = $ordinal }
    }
}

# --- the Windows log --------------------------------------------------------
# Filtered by log name rather than walking them all: this one is walked in milliseconds, whereas
# "every enabled one" takes a minute.
$theirs = @()
try {
    $filter = @{ LogName = 'Microsoft-Windows-Kernel-PnP/Device Management'; Id = 1010 }
    if (-not $All) { $filter['StartTime'] = $since }
    foreach ($e in (Get-WinEvent -FilterHashtable $filter -ErrorAction Stop)) {
        if ($e.Message -notmatch 'DISPLAY\\([A-Z0-9_]+)\\') { continue }
        # A negative ordinal keeps Windows' own line above the deck lines it explains when both land
        # in the same second — the cause is what one wants to read first.
        $theirs += [pscustomobject]@{
            When = $e.TimeCreated; Source = 'pnp'
            Text = ('{0} surprise removed - missing on the bus' -f $Matches[1])
            Ordinal = -1
        }
    }
}
catch {
    # Both outcomes arrive as a plain System.Exception, not as EventLogNotFoundException — a typed
    # catch for that never fires. The identifier is what separates them, and it is the identifier we
    # match on, never the message: that text is localised, and on a German or Russian Windows a match
    # on 'No events' fails on the most ordinary run there is — a quiet day with nothing off the bus —
    # and the tool would die instead of printing the deck side.
    switch -Wildcard ($_.FullyQualifiedErrorId) {
        'NoMatchingLogsFound,*'   { Write-Host 'Kernel-PnP log is not there - only the deck side will be shown.' -ForegroundColor Yellow }
        'NoMatchingEventsFound,*' { }   # nothing dropped off in the period: the answer, not an error
        default                   { throw }
    }
}

# --- one timeline -----------------------------------------------------------
# The @() wraps the PIPELINE, not just the operands: Sort-Object emits a bare object when one row
# survives the period, and a bare [pscustomobject] has no .Count in PowerShell 5.1 — the header printed
# "displays, one timeline -  lines" with a hole in it.
$rows = @($ours + $theirs | Sort-Object When, Ordinal)

if ($rows.Count -eq 0) {
    Write-Host 'Nothing in either log for that period.' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host ('displays, one timeline - {0} lines' -f $rows.Count) -ForegroundColor White
Write-Host ''

foreach ($row in $rows) {
    $stamp = $row.When.ToString('yyyy-MM-dd HH:mm:ss',
                                [System.Globalization.CultureInfo]::InvariantCulture)
    if ($row.Source -eq 'pnp') {
        Write-Host ('{0}  WINDOWS  {1}' -f $stamp, $row.Text) -ForegroundColor Yellow
    }
    else {
        # The lines the timeline is assembled for in the first place — the eye has to find them at once.
        $loud = ($row.Text -like 'plug:*' -or $row.Text -like 'reapply:*' -or
                 $row.Text -like 'desk:*' -or $row.Text -like 'ERROR*')
        $colour = $(if ($loud) { 'White' } else { 'DarkGray' })
        Write-Host ('{0}  deck     {1}' -f $stamp, $row.Text) -ForegroundColor $colour
    }
}

Write-Host ''
Write-Host 'WINDOWS lines are the hardware. A deck line under one is a reaction to it.' -ForegroundColor DarkGray
