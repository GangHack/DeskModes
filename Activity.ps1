<#
    Activity.ps1 — the diary: what, where, and for how long.

    Every few seconds we look at which application is in the foreground, which
    monitor it is on and which desk mode is current, and add the seconds to a
    per-day pot. The report — for the console and for HTML — is built from the pot.

    Three decisions that matter more here than the code does:

      * WINDOW TITLES ARE NEVER READ. A window title holds the document's name,
        the page address and the subject of an email; for "how much time in what"
        the process name is enough. What is not in the file cannot leak out of it.
      * A sum is accumulated, not events. The file holds the day's totals
        ("chrome — 3600 seconds"), not a stream of "at 14:03:10 it was chrome".
        The file stays tiny forever, and it cannot be used to reconstruct what
        somebody was doing on Thursday at three in the afternoon.
      * Off by default (settings.stats). This is data about a person, and it is
        not ours to turn on for them.

    The file is activity.json next to the scripts, and it can be deleted at any moment.
#>

$script:ActivityFile = Join-Path $PSScriptRoot 'activity.json'

# Idle for longer than this and there is nobody at the computer, so no seconds are
# collected. A minute and a half rather than five: at a 10-second poll that is three
# empty samples, and a lunch break will not end up in "time at the computer".
$script:ActivityIdleLimit = 90

# The pot, in memory. It goes to disk rarely (see Save-ActivityStore): a diary is not
# the sort of thing worth waking an SSD for every ten seconds.
$script:ActivityStore = $null
$script:ActivityDirty = $false

# The unfinished stretch of continuous work: the "longest session" is counted from it.
# It lives in memory only — after the tray restarts the stretch begins again, and that
# is honest: we do not know what happened while we were not there.
$script:ActivityRunStart = $null
$script:ActivityRunLast = $null

function Get-ActivityStore {
    if ($null -ne $script:ActivityStore) { return $script:ActivityStore }

    $store = [ordered]@{ days = [ordered]@{} }
    if (Test-Path $script:ActivityFile) {
        try {
            $raw = Get-Content $script:ActivityFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($raw.days) {
                foreach ($d in $raw.days.PSObject.Properties) {
                    $store.days[$d.Name] = ConvertTo-ActivityDay $d.Value
                }
            }
        }
        catch {
            # A diary is not the settings: losing it is no disaster, and taking the
            # app's startup down over it even less warranted.
            Write-DisplayLog "stats: activity.json is damaged, starting a new one - $($_.Exception.Message)"
            $store = [ordered]@{ days = [ordered]@{} }
        }
    }
    $script:ActivityStore = $store
    return $store
}

# From what ConvertFrom-Json handed back (objects) into what the code works with
# (dictionaries). It fills in missing sections along the way: the file could have been
# written by an older version, and "no such key" must not turn into a dead report.
function ConvertTo-ActivityDay {
    param($Raw)

    $day = New-ActivityDay
    if (-not $Raw) { return $day }
    foreach ($section in 'modes', 'apps', 'displays', 'pairs', 'hours') {
        if (-not $Raw.$section) { continue }
        foreach ($p in $Raw.$section.PSObject.Properties) {
            if ($p.Name) { $day[$section][$p.Name] = [int]$p.Value }
        }
    }
    foreach ($field in 'active', 'switches', 'longest') {
        if ($null -ne $Raw.$field) { $day[$field] = [int]$Raw.$field }
    }
    # A file written before 2026-09-04 also carries "first" and "last" - the clock time of
    # the day's first and last activity. Nothing reads them any more (see Get-UsualDay), so
    # they are not carried over, and the first save of that day drops them.
    return $day
}

function New-ActivityDay {
    return [ordered]@{
        active   = 0            # seconds at the computer (idle excluded)
        switches = 0            # mode switches
        longest  = 0            # the longest unbroken stretch, in seconds
        modes    = [ordered]@{} # mode key -> seconds
        apps     = [ordered]@{} # process name -> seconds
        displays = [ordered]@{} # monitor name -> seconds
        pairs    = [ordered]@{} # "process|monitor" -> seconds
        hours    = [ordered]@{} # hour of the day (00..23) -> seconds
    }
}

function Get-ActivityDay {
    param($Store, [string]$Date)

    if (-not $Store.days.Contains($Date)) { $Store.days[$Date] = New-ActivityDay }
    return $Store.days[$Date]
}

# A pure function: add a stretch to a day. Everything that knows the shape of the pot
# is gathered here — which is why it is tested without a single monitor.
function Add-ActivitySpan {
    param($Day, [string]$Process, [string]$Display, [string]$Mode, [int]$Seconds, [int]$Hour = -1)

    if ($Seconds -le 0) { return }

    $Day.active += $Seconds
    if ($Hour -ge 0) {
        $key = '{0:00}' -f $Hour
        $Day.hours[$key] = [int]$Day.hours[$key] + $Seconds
    }
    if ($Process) {
        $Day.apps[$Process] = [int]$Day.apps[$Process] + $Seconds
        if ($Display) { $Day.pairs[($Process + '|' + $Display)] = [int]$Day.pairs[($Process + '|' + $Display)] + $Seconds }
    }
    if ($Display) { $Day.displays[$Display] = [int]$Day.displays[$Display] + $Seconds }
    if ($Mode)    { $Day.modes[$Mode] = [int]$Day.modes[$Mode] + $Seconds }
}

function Save-ActivityStore {
    param([switch]$Force)

    if ($null -eq $script:ActivityStore) { return }
    if (-not $script:ActivityDirty -and -not $Force) { return }
    try {
        # Days older than a year are thrown away: a yearly report is already all
        # anyone will read, and the file must stay small without anybody's help.
        $limit = Format-DisplayStamp ((Get-Date).AddDays(-400)) 'yyyy-MM-dd'
        foreach ($key in @($script:ActivityStore.days.Keys)) {
            if ($key -lt $limit) { $script:ActivityStore.days.Remove($key) }
        }
        # -ErrorAction Stop: a refusal from Set-Content is a NON-terminating error, so without it the
        # catch below never fires — and the line after this one would declare the store clean over a
        # write that did not happen, throwing the day's seconds away for good. With it, the sample stays
        # dirty and the next tick tries again.
        $script:ActivityStore | ConvertTo-Json -Depth 6 -Compress |
            Set-Content -Path $script:ActivityFile -Encoding UTF8 -ErrorAction Stop
        $script:ActivityDirty = $false
    }
    catch { Write-DisplayLog "stats: could not save activity.json - $($_.Exception.Message)" }
}

# The cheap half of a sample: who is at the computer. Separated from the recording so
# that the caller does not have to prepare a monitor map and a mode key for a sample
# that is about to be thrown away: at night and over lunch most ticks are like that,
# and recomputing the modes is a millisecond every ten seconds. $null — nobody is there.
function Get-ActivitySample {
    $sample = $null
    try { $sample = [NativeActivity]::Sample() }
    catch { return $null }
    if (-not $sample) { return $null }

    # Nobody at the computer — the stretch of continuous work has ended.
    if ($sample.IdleSeconds -gt $script:ActivityIdleLimit) {
        $script:ActivityRunStart = $null
        $script:ActivityRunLast = $null
        return $null
    }
    return $sample
}

# Record a sample. $Sample comes from Get-ActivitySample; $DisplayMap is
# "\\.\DISPLAY1" -> monitor name, and the caller supplies it: the tray already holds
# the desk state, and there is no point asking the system twice for the diary's sake.
function Add-ActivitySample {
    param($Sample, $DisplayMap, [string]$Mode, [int]$IntervalSeconds = 10)

    $sample = $Sample
    if (-not $sample) { return }

    $now = Get-Date

    # How much time has passed since the last sample — by the clock, not by the timer's
    # step: the tray timer can be late (the system was busy, the computer slept). But the
    # gap cannot be trusted whole either, so it is capped at three steps: a minute the
    # computer slept through must not be credited to whatever app happened to be on screen.
    #
    # The first sample after a break is exactly one step: how long the person had been
    # sitting there before it, we do not know, and there is nothing to invent here.
    $seconds = $IntervalSeconds
    if ($script:ActivityRunLast) {
        $gap = [int]($now - $script:ActivityRunLast).TotalSeconds
        if ($gap -le 0) { return }
        $seconds = [math]::Min($gap, $IntervalSeconds * 3)
    }

    $display = ''
    if ($sample.Device -and $DisplayMap -and $DisplayMap.Contains([string]$sample.Device)) {
        $display = [string]$DisplayMap[[string]$sample.Device]
    }

    $day = Get-ActivityDay -Store (Get-ActivityStore) -Date (Format-DisplayStamp $now 'yyyy-MM-dd')
    Add-ActivitySpan -Day $day -Process ([string]$sample.Process) -Display $display -Mode $Mode `
                     -Seconds $seconds -Hour $now.Hour

    # The longest unbroken stretch. Counted on the fly so the file need not hold a
    # stream of events: the current stretch's length is "now minus where it started".
    if (-not $script:ActivityRunStart) { $script:ActivityRunStart = $now }
    $script:ActivityRunLast = $now
    $run = [int]($now - $script:ActivityRunStart).TotalSeconds
    if ($run -gt [int]$day.longest) { $day.longest = $run }

    $script:ActivityDirty = $true
}

# A mode switch is the only event the diary writes down separately: everything else it
# sums up.
function Add-ActivitySwitch {
    param([string]$Mode)

    if (-not $Mode) { return }
    $day = Get-ActivityDay -Store (Get-ActivityStore) -Date (Format-DisplayStamp (Get-Date) 'yyyy-MM-dd')
    $day.switches = [int]$day.switches + 1
    $script:ActivityDirty = $true
}

# --- the report -------------------------------------------------------------
# A pure function over the pot: it adds the days up, sorts, and works out the shares.
# It reads nothing and writes nowhere — which is why it is tested end to end.

function Get-ActivityReport {
    param($Store, [int]$Days = 30, [datetime]$Today = (Get-Date))

    $report = [ordered]@{
        From = ''; To = ''; DaysRecorded = 0
        Active = 0; Switches = 0; Longest = 0
        Apps = @(); Displays = @(); Modes = @(); Pairs = @(); Hours = @()
        BusiestHour = -1; AverageDay = 0; UsualStart = ''; UsualEnd = ''
        BestDay = ''; BestDayActive = 0; Streak = 0
    }
    if (-not $Store -or -not $Store.days) { return $report }

    # Nought days is "everything there is" — what the window's "All" asks for. An empty
    # boundary lets every date through, so the whole pot is read without anybody having to
    # invent a big enough number of days.
    $since = ''
    if ($Days -gt 0) { $since = Format-DisplayStamp ($Today.AddDays(-1 * ($Days - 1))) 'yyyy-MM-dd' }
    $dates = @($Store.days.Keys | Where-Object { [string]$_ -ge $since } | Sort-Object)
    if ($dates.Count -eq 0) { return $report }

    $apps = @{}; $displays = @{}; $modes = @{}; $pairs = @{}; $hours = @{}

    foreach ($date in $dates) {
        $day = $Store.days[$date]
        $report.DaysRecorded++
        $report.Active += [int]$day.active
        $report.Switches += [int]$day.switches
        if ([int]$day.longest -gt $report.Longest) { $report.Longest = [int]$day.longest }
        if ([int]$day.active -gt $report.BestDayActive) {
            $report.BestDayActive = [int]$day.active
            $report.BestDay = [string]$date
        }
        foreach ($pair in @{ apps = $apps; displays = $displays; modes = $modes; pairs = $pairs; hours = $hours }.GetEnumerator()) {
            $section = $day[$pair.Key]
            if (-not $section) { continue }
            foreach ($k in @($section.Keys)) { $pair.Value[$k] = [int]$pair.Value[$k] + [int]$section[$k] }
        }
    }

    $report.From = [string]$dates[0]
    $report.To = [string]$dates[-1]
    if ($report.DaysRecorded -gt 0) { $report.AverageDay = [int]($report.Active / $report.DaysRecorded) }

    $report.Apps = @(ConvertTo-ActivityRows -Map $apps -Total $report.Active)
    $report.Displays = @(ConvertTo-ActivityRows -Map $displays -Total $report.Active)
    $report.Modes = @(ConvertTo-ActivityRows -Map $modes -Total $report.Active)
    $report.Pairs = @(ConvertTo-ActivityRows -Map $pairs -Total $report.Active)

    # All twenty-four hours are handed back, empty ones included: a histogram with a
    # dip at lunchtime is exactly what it gets looked at for.
    $peak = 0
    $rows = @()
    for ($h = 0; $h -lt 24; $h++) {
        $key = '{0:00}' -f $h
        $value = [int]$hours[$key]
        if ($value -gt $peak) { $peak = $value; $report.BusiestHour = $h }
        $rows += [pscustomobject]@{ Name = $key; Seconds = $value; Share = 0 }
    }
    if ($peak -gt 0) {
        foreach ($r in $rows) { $r.Share = [math]::Round(100 * $r.Seconds / $peak, 1) }
    }
    $report.Hours = @($rows)

    # After the histogram, because that is what it is read off (see Get-UsualDay).
    $usual = @(Get-UsualDay -Hours $report.Hours)
    $report.UsualStart = $usual[0]
    $report.UsualEnd = $usual[1]
    $report.Streak = Get-ActivityStreak -Dates $dates -Today $Today

    return $report
}

# A "name -> seconds" dictionary into a sorted list with shares. The share is worked
# out against the total time, not against the sum of the rows: one application can sit
# on two monitors, and the sum of the pairs is larger than the time at the computer.
function ConvertTo-ActivityRows {
    param($Map, [int]$Total)

    $rows = @()
    foreach ($k in @($Map.Keys)) {
        $rows += [pscustomobject]@{
            Name    = [string]$k
            Seconds = [int]$Map[$k]
            Share   = $(if ($Total -gt 0) { [math]::Round(100 * [int]$Map[$k] / $Total, 1) } else { 0 })
        }
    }
    return @($rows | Sort-Object -Property Seconds -Descending)
}

# The diary writes a mode down by its key — "combo:Work", "solo:XG27AQDMGR" — because that is
# what a switch is recorded as and a key is the only thing that stays the same shape for a year.
# A report is read by a person, though, and a key is not what any of those modes is called
# anywhere else in the app. Every place the diary is shown goes through this: the window, the
# page and the console.
function ConvertTo-ModeTitleRows {
    param($Rows)

    $out = @()
    foreach ($row in @($Rows)) {
        $out += [pscustomobject]@{
            Name    = Get-ModeTitleFromKey -Key ([string]$row.Name)
            Seconds = [int]$row.Seconds
            Share   = [double]$row.Share
        }
    }
    return @($out)
}

# When the day begins and ends - "10:00", "04:00" - read off the hour histogram and not
# out of the days' own stamps of first and last activity. Midnight cuts through a day that
# runs past it: the calendar date it lands on gets its first activity written down at 00:00,
# a minute nobody sat down at, and the average over such dates put the start of this desk's
# day at 02:30 for somebody who sits down at eleven (measured 2026-09-04). The histogram has
# no such seam - it is a circle - so the day is what is left of the circle once the longest
# quiet stretch is cut out of it, and midnight is nothing special on it.
#
# The price is the hour: 09:00 rather than 09:07. That is the honest precision of a bucket
# an hour wide, and the card is called "usual day" rather than "sat down at".
function Get-UsualDay {
    param($Hours)

    # An hour counts as part of the day when it holds at least a twentieth of the busiest
    # one. Without a floor a single sample at five in the morning - one night, one year ago -
    # would stretch the day to dawn for good.
    $peak = 0
    foreach ($row in @($Hours)) { if ([int]$row.Seconds -gt $peak) { $peak = [int]$row.Seconds } }
    if ($peak -le 0) { return @('', '') }
    $floor = $peak / 20

    $busy = New-Object 'bool[]' 24
    $count = 0
    foreach ($row in @($Hours)) {
        $h = [int]$row.Name
        if ($h -lt 0 -or $h -gt 23) { continue }
        if ([int]$row.Seconds -ge $floor) { $busy[$h] = $true; $count++ }
    }
    # Somebody at the computer in all twenty-four hours has no day to name, and neither has
    # an empty diary. Both leave the card showing a dash rather than a made-up pair of hours.
    if ($count -eq 0 -or $count -eq 24) { return @('', '') }

    # The longest quiet stretch is looked for round the clock rather than along it: a night
    # owl's quiet hours lie across midnight, and along a flat 0..23 that one stretch reads
    # as two short ones.
    $best = 0; $bestAt = -1
    for ($start = 0; $start -lt 24; $start++) {
        if ($busy[$start]) { continue }
        if (-not $busy[($start + 23) % 24]) { continue }   # not where a stretch begins
        $len = 0
        while (-not $busy[($start + $len) % 24]) { $len++ }
        if ($len -gt $best) { $best = $len; $bestAt = $start }
    }
    if ($bestAt -lt 0) { return @('', '') }

    # The day starts where the quiet ends and ends where the quiet begins, so the last busy
    # hour is counted whole: busy until 03 reads as a day that ends at 04:00.
    return @(('{0:00}:00' -f (($bestAt + $best) % 24)), ('{0:00}:00' -f $bestAt))
}

# How many days in a row, counting back from today, the computer was used. A gap of one
# day breaks the count — otherwise it is not "in a row".
function Get-ActivityStreak {
    param($Dates, [datetime]$Today = (Get-Date))

    $set = @{}
    foreach ($d in @($Dates)) { $set[[string]$d] = $true }
    $streak = 0
    $cursor = $Today.Date
    while ($set.Contains((Format-DisplayStamp $cursor 'yyyy-MM-dd'))) {
        $streak++
        $cursor = $cursor.AddDays(-1)
    }
    return $streak
}

# "3 h 20 min" — for the report. Its own, not Format-Duration from DisplayCore: there
# the seconds are needed for a countdown, here they only get in the way.
function Format-ActivitySpan {
    param([int]$Seconds)

    if ($Seconds -le 0) { return '-' }
    $minutes = [int][math]::Round($Seconds / 60)
    if ($minutes -lt 60) { return ('{0} min' -f $minutes) }
    return ('{0} h {1:00} min' -f [int][math]::Floor($minutes / 60), ($minutes % 60))
}

# The console report. A pure function: it hands back an array of lines and prints
# nothing — that is how it can be tested.
function Format-ActivityReport {
    param($Report, [int]$Top = 8)

    $out = @()
    if (-not $Report -or $Report.DaysRecorded -eq 0) {
        # We do not say "turn the diary on" here: this function does not know the
        # settings, and with the diary already on that advice would be a lie — an empty
        # report only means nobody has worked at the computer yet. Whoever does know the
        # diary is off is the one who says so (see Set-Display.ps1).
        return @('Nothing in the diary yet - it fills up while you use the computer.')
    }

    $out += ''
    $out += ('Diary  {0} .. {1}   {2} day(s) recorded' -f $Report.From, $Report.To, $Report.DaysRecorded)
    $out += ''
    $out += ('  at the computer   {0}   ({1} a day on average)' -f (Format-ActivitySpan $Report.Active), (Format-ActivitySpan $Report.AverageDay))
    $out += ('  longest session   {0}' -f (Format-ActivitySpan $Report.Longest))
    $out += ('  mode switches     {0}' -f $Report.Switches)
    if ($Report.UsualStart) { $out += ('  usual day         {0} .. {1}' -f $Report.UsualStart, $Report.UsualEnd) }
    if ($Report.BusiestHour -ge 0) { $out += ('  busiest hour      {0:00}:00' -f $Report.BusiestHour) }
    if ($Report.BestDay) { $out += ('  longest day       {0}   {1}' -f $Report.BestDay, (Format-ActivitySpan $Report.BestDayActive)) }
    $out += ('  days in a row     {0}' -f $Report.Streak)

    foreach ($section in @(
        @{ Title = 'Displays'; Rows = $Report.Displays },
        @{ Title = 'Modes';    Rows = (ConvertTo-ModeTitleRows $Report.Modes) },
        @{ Title = 'Apps';     Rows = $Report.Apps },
        @{ Title = 'App on display'; Rows = $Report.Pairs })) {

        $rows = @($section.Rows | Select-Object -First $Top)
        if ($rows.Count -eq 0) { continue }
        $out += ''
        $out += $section.Title
        foreach ($r in $rows) {
            $name = [string]$r.Name -replace '\|', ' on '
            # A bar of hashes: twenty marks to a hundred percent. In a console without
            # colour this is the only way to see a proportion without reading the digits.
            $bar = '#' * [int][math]::Round($r.Share / 5)
            # The width of the time column fits "12 h 00 min" whole: at ten marks the
            # three-hour rows slid out of line against the two-digit ones.
            $out += ('  {0,-28} {1,11}  {2,5}%  {3}' -f $name, (Format-ActivitySpan $r.Seconds), (Format-ActivityPercent $r.Share), $bar)
        }
    }

    $out += ''
    return $out
}

# --- the report as a page ---------------------------------------------------
# The same report as a file: bars, the theme's colours, and nothing else. Since 2026-09-01
# the everyday way to read the diary is the Diary page (New-StatsUi in SettingsDialog.ps1)
# — a browser tab is a detour when the question is "where did today go". The page stayed
# for the other half of the job: it is a FILE, so it can be kept, sent, or opened on a
# machine that has never heard of this tool. The button at the bottom of the window writes
# it, and `Set-Display.ps1 stats` prints the same numbers into the console.
#
# There is not one external reference inside it — no font, no script: the file has to open
# on a machine with no internet and must not invite anybody in.

function Format-ActivityHtmlRows {
    param($Rows, [int]$Top = 10)

    $html = ''
    foreach ($r in @($Rows | Select-Object -First $Top)) {
        # Escaped BEFORE our own markup is added: the process name and the monitor name
        # come from outside (the name straight out of EDID, where the manufacturer writes
        # whatever it likes), which is why a "process|monitor" pair is handled as two
        # separate strings rather than as one with the separator swapped out.
        $name = (@([string]$r.Name -split '\|') | ForEach-Object { Format-HtmlText $_ }) -join
                ' <span class="dim">on</span> '
        $html += ('<tr><td class="name">{0}</td><td class="time">{1}</td>' -f
                  $name, (Format-ActivitySpan $r.Seconds))
        $html += ('<td class="bar"><span style="width:{0}%"></span></td><td class="share">{1}%</td></tr>' -f
                  (Format-ActivityPercent ([math]::Min(100, [double]$r.Share))), (Format-ActivityPercent $r.Share))
    }
    if (-not $html) { $html = '<tr><td colspan="4" class="dim">nothing yet</td></tr>' }
    return $html
}

# Everything that came from the system reaches the markup only through this function.
# The monitor name is read out of EDID, where the manufacturer writes whatever it likes
# — breaking the page with an angle bracket in a monitor's name must not be possible.
function Format-HtmlText {
    param([string]$Text)

    return ([string]$Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

# A number into the markup — ALWAYS with a dot. `-f` takes the separator from the
# current locale, and on a Russian one "width:12,5%" is not twelve and a half percent
# but a thrown-away CSS rule: the bar is drawn zero wide, the hour histogram goes flat,
# and the diary is what looks guilty rather than the comma. Percentages here are worked
# out to one decimal place (see ConvertTo-ActivityRows), so the format is exactly that.
function Format-ActivityPercent {
    param([double]$Value)

    return $Value.ToString('0.#', [cultureinfo]::InvariantCulture)
}

function New-ActivityHtml {
    param($Report, [string]$Accent = '#4CC2FF', [switch]$Dark)

    $hours = ''
    foreach ($h in @($Report.Hours)) {
        $cls = $(if ([int]$h.Name -eq [int]$Report.BusiestHour) { ' peak' } else { '' })
        $hours += ('<div class="hour{0}"><span style="height:{1}%"></span><em>{2}</em></div>' -f
                   $cls, (Format-ActivityPercent ([math]::Max(2, [double]$h.Share))), $h.Name)
    }

    $facts = @(
        @{ K = 'at the computer'; V = (Format-ActivitySpan $Report.Active) }
        @{ K = 'a day on average'; V = (Format-ActivitySpan $Report.AverageDay) }
        @{ K = 'longest session'; V = (Format-ActivitySpan $Report.Longest) }
        @{ K = 'mode switches'; V = [string]$Report.Switches }
        @{ K = 'usual day'; V = $(if ($Report.UsualStart) { $Report.UsualStart + ' .. ' + $Report.UsualEnd } else { '-' }) }
        @{ K = 'days in a row'; V = [string]$Report.Streak }
    )
    $cards = ''
    foreach ($f in $facts) {
        $cards += ('<div class="card"><b>{0}</b><span>{1}</span></div>' -f $f.V, $f.K)
    }

    $bg     = $(if ($Dark) { '#1b1b1b' } else { '#f6f6f6' })
    $panel  = $(if ($Dark) { '#262626' } else { '#ffffff' })
    $ink    = $(if ($Dark) { '#f0f0f0' } else { '#1a1a1a' })
    $dim    = $(if ($Dark) { '#9a9a9a' } else { '#6a6a6a' })
    $track  = $(if ($Dark) { '#333333' } else { '#ebebeb' })

    $title = 'DeskModes - diary'
    $range = '{0} .. {1}, {2} day(s)' -f $Report.From, $Report.To, $Report.DaysRecorded

    return @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>$title</title>
<style>
 :root { --bg:$bg; --panel:$panel; --ink:$ink; --dim:$dim; --track:$track; --accent:$Accent; }
 * { box-sizing: border-box; }
 body { margin:0; padding:32px; background:var(--bg); color:var(--ink);
        font:14px/1.5 'Segoe UI Variable Text','Segoe UI',system-ui,sans-serif; }
 h1 { font-size:22px; font-weight:600; margin:0 0 2px; }
 h2 { font-size:13px; font-weight:600; text-transform:uppercase; letter-spacing:.08em;
      color:var(--dim); margin:0 0 12px; }
 .range { color:var(--dim); margin-bottom:24px; }
 .wrap { max-width:1000px; margin:0 auto; }
 .cards { display:flex; flex-wrap:wrap; gap:12px; margin-bottom:24px; }
 .card { background:var(--panel); border-radius:10px; padding:16px 20px; min-width:150px; flex:1; }
 .card b { display:block; font-size:22px; font-weight:600; }
 .card span { color:var(--dim); font-size:12px; }
 section { background:var(--panel); border-radius:10px; padding:20px 24px; margin-bottom:16px; }
 table { width:100%; border-collapse:collapse; }
 td { padding:5px 0; vertical-align:middle; }
 td.name { width:34%; }
 td.time { width:15%; color:var(--dim); font-variant-numeric:tabular-nums; }
 td.share { width:8%; text-align:right; color:var(--dim); font-variant-numeric:tabular-nums; }
 td.bar { padding-right:12px; }
 td.bar span { display:block; height:8px; border-radius:4px; background:var(--accent); min-width:2px; }
 td.bar { background:linear-gradient(var(--track),var(--track)) no-repeat center/100% 8px; border-radius:4px; }
 .dim { color:var(--dim); }
 .hours { display:flex; align-items:flex-end; gap:4px; height:130px; }
 .hour { flex:1; display:flex; flex-direction:column; justify-content:flex-end; align-items:center; height:100%; }
 .hour span { width:100%; background:var(--track); border-radius:3px 3px 0 0; }
 .hour.peak span { background:var(--accent); }
 .hour em { font-style:normal; font-size:10px; color:var(--dim); margin-top:6px; }
 footer { color:var(--dim); font-size:12px; text-align:center; margin-top:24px; }
</style></head><body><div class="wrap">
<h1>$title</h1>
<div class="range">$range</div>
<div class="cards">$cards</div>
<section><h2>Time of day</h2><div class="hours">$hours</div></section>
<section><h2>Displays</h2><table>$(Format-ActivityHtmlRows $Report.Displays)</table></section>
<section><h2>Modes</h2><table>$(Format-ActivityHtmlRows (ConvertTo-ModeTitleRows $Report.Modes))</table></section>
<section><h2>Apps</h2><table>$(Format-ActivityHtmlRows $Report.Apps 12)</table></section>
<section><h2>App on display</h2><table>$(Format-ActivityHtmlRows $Report.Pairs 12)</table></section>
<footer>Window titles are never recorded - only process names. Delete activity.json to forget everything.</footer>
</div></body></html>
"@
}

# Build the report, put it next to the scripts and open it in the browser. The file is
# overwritten every time: this is not an archive, it is a look at right now.
function Show-ActivityReport {
    param([int]$Days = 30)

    $report = Get-ActivityReport -Store (Get-ActivityStore) -Days $Days
    $dark = Test-DarkTheme
    $html = New-ActivityHtml -Report $report -Accent (Get-AccentColor -ForDarkTheme:$dark) -Dark:$dark
    $path = Join-Path $script:ToolRoot 'stats.html'
    # -ErrorAction Stop, or a folder we may not write to gives a non-terminating error, the two lines
    # below report a report that is not there, and the browser opens yesterday's page — or nothing at
    # all. The only caller answers a throw with a balloon naming the reason.
    Set-Content -Path $path -Value $html -Encoding UTF8 -ErrorAction Stop
    Write-DisplayLog "stats: report written to stats.html"
    Start-Process $path | Out-Null
    return $path
}
