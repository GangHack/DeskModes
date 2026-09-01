# --- the diary window -------------------------------------------------------
# Built without being shown, like the other windows here. What is checked is what a person would
# read off the screen: the line under the title, the six cards, the four lists and the height of
# the hour bars — all of it comes out of one report, and the period is what chooses that report.
#
# The store is this file's own rather than the diary group's: -File 37 has to run on its own, and
# a fake borrowed from a neighbour would make that a broken run instead of a green one.

Write-Host ''
Write-Host 'the diary window' -ForegroundColor White

$script:StatsToday = [datetime]'2026-09-01'

function New-WindowDiary {
    # Four days at four distances, so that every pill picks a different set of them: today, three
    # days back (inside a week), twenty (inside a month) and four hundred (only "All" reaches it).
    $store = [ordered]@{ days = [ordered]@{} }
    $plan = @(
        @{ Back = 0;   App = 'chrome'; Display = 'LG ULTRAGEAR'; Mode = 'combo:Work';      Seconds = 3600; Hour = 9;  Time = '09:00' }
        @{ Back = 3;   App = 'Code';   Display = 'LG ULTRAFINE'; Mode = 'all';             Seconds = 7200; Hour = 14; Time = '14:00' }
        @{ Back = 20;  App = 'cs2';    Display = 'XG27AQDMGR';   Mode = 'solo:XG27AQDMGR'; Seconds = 1800; Hour = 21; Time = '21:00' }
        @{ Back = 400; App = 'chrome'; Display = 'LG ULTRAGEAR'; Mode = 'combo:Work';      Seconds = 600;  Hour = 11; Time = '11:00' }
    )
    foreach ($span in $plan) {
        $date = Format-DisplayStamp $script:StatsToday.AddDays(-1 * [int]$span.Back) 'yyyy-MM-dd'
        $day = Get-ActivityDay -Store $store -Date $date
        Add-ActivitySpan -Day $day -Process ([string]$span.App) -Display ([string]$span.Display) `
                         -Mode ([string]$span.Mode) -Seconds ([int]$span.Seconds) `
                         -Time ([string]$span.Time) -Hour ([int]$span.Hour)
        $day.switches = 2
    }
    return $store
}

function New-DiaryUi {
    param([int]$Days = 7, $Store)
    if ($null -eq $Store) { $Store = New-WindowDiary }
    return New-StatsWindow -Store $Store -Days $Days -Today $script:StatsToday
}

# What a person reads off a row: the first cell of its grid.
function Get-DiaryRowName {
    param($Panel, [int]$Index = 0)
    return [string]$Panel.Children[$Index].Children[0].Text
}

# What a card says, big: the first line inside its border.
function Get-DiaryCardValue {
    param($Ui, [int]$Index)
    return [string]$Ui.CardsPanel.Children[$Index].Child.Children[0].Text
}

Test-Case 'diary window: opens on the period it was given and says which days it covers' {
    $ui = New-DiaryUi -Days 1
    try {
        Assert-Equal '2026-09-01' $ui.RangeText.Text 'one day needs no range'
        Assert-Equal '1 h 00 min' (Get-DiaryCardValue -Ui $ui -Index 0) 'the time at the computer'
        Assert-Equal 1 $ui.DisplayRows.Children.Count 'one display was used'
        Assert-Equal 'LG ULTRAGEAR' (Get-DiaryRowName $ui.DisplayRows) 'and it is named'
    }
    finally { $ui.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary window: a pill rebuilds the whole window for its period' {
    $ui = New-DiaryUi -Days 1
    try {
        # Through the pill itself, not through Set-StatsPeriod: what is being checked is the wiring
        # — the handler finds the window in $script:ActiveStatsUi and takes the period off the Tag.
        $week = @($ui.Chips | Where-Object { [int]$_.Tag -eq 7 })[0]
        $week.RaiseEvent((New-Object System.Windows.RoutedEventArgs (
            [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))

        Assert-Equal 7 $ui.Days 'the window is on the week now'
        Assert-Equal '3 h 00 min' (Get-DiaryCardValue -Ui $ui -Index 0) 'and the week has both days in it'
        Assert-Equal 2 $ui.DisplayRows.Children.Count 'two displays over the week'
        Assert-True ($ui.RangeText.Text -like '*..*2 days*') 'and the range says so'
    }
    finally { $ui.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary window: the chosen pill is the filled one, and only it' {
    $ui = New-DiaryUi -Days 30
    try {
        $on = @($ui.Chips | Where-Object { $_.Style -eq $ui.Window.FindResource('ChipOn') })
        Assert-Equal 1 $on.Count 'exactly one is chosen'
        Assert-Equal 30 ([int]$on[0].Tag) 'and it is the period the window is showing'
    }
    finally { $ui.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary window: "All" reaches a day no other period does' {
    $ui = New-DiaryUi -Days 30
    try {
        Assert-Equal 3 $ui.Report.DaysRecorded 'a month holds three of the four days'
        Set-StatsPeriod -Ui $ui -Days 0
        Assert-Equal 4 $ui.Report.DaysRecorded 'and "All" holds the day from last year too'
    }
    finally { $ui.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary window: modes are named the way they are named everywhere else' {
    $ui = New-DiaryUi -Days 1
    try {
        # The diary keeps keys ("combo:Work"); a window shows titles. Nobody has a mode called
        # "combo:Work" — that is a name for a file, not for a person.
        Assert-Equal 'Work' (Get-DiaryRowName $ui.ModeRows) 'the combination by its name'
        Assert-Equal 'chrome on LG ULTRAGEAR' (Get-DiaryRowName $ui.PairRows) 'and a pair reads as a sentence'
    }
    finally { $ui.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary window: an empty period says so instead of drawing zeroes' {
    $ui = New-DiaryUi -Days 1 -Store ([ordered]@{ days = [ordered]@{} })
    try {
        Assert-Equal 'Nothing counted for this period yet.' $ui.RangeText.Text 'the line under the title'
        Assert-Equal 1 $ui.AppRows.Children.Count 'and one line in place of a list'
        Assert-Equal 'nothing yet' ([string]$ui.AppRows.Children[0].Text) 'which says as much'
        Assert-Equal 24 $ui.HoursPanel.Children.Count 'the day is still a whole day'
    }
    finally { $ui.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary window: the hour bars fit the panel, and the busiest one is the full height' {
    $ui = New-DiaryUi -Days 1
    try {
        $room = [double]$ui.HoursPanel.Height
        $bars = @($ui.HoursPanel.Children)
        Assert-Equal 24 $bars.Count 'every hour is drawn'
        # 09:00 is the only hour with anything in it on that day, so it is the peak.
        Assert-Equal $room ([double]$bars[9].Height) 'the busiest hour fills the panel'
        Assert-Equal 1.0 ([double]$bars[9].Opacity) 'and stands at full strength'
        Assert-Equal 2.0 ([double]$bars[0].Height) 'an empty hour keeps a tick of a bar'
        Assert-True ([double]$bars[0].Opacity -lt 1.0) 'faded, so the peak is the one that is read'
    }
    finally { $ui.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary window: a share above a hundred does not draw past its track' {
    # One application on two monitors: the pairs add up to more than the time at the computer, and
    # a share is worked out against that time (see ConvertTo-ActivityRows). The bar has to stop at
    # the end of its track rather than run over the percentage next to it.
    $ui = New-DiaryUi -Days 1
    try {
        $row = New-StatsRow -Window $ui.Window -Row ([pscustomobject]@{
            Name = 'chrome'; Seconds = 3600; Share = 140.0 }) -BarWidth 100
        $track = $row.Children[2]
        Assert-Equal 100.0 ([double]$track.Width) 'the track is the width it was given'
        Assert-Equal 100.0 ([double]$track.Child.Width) 'and what is filled in stops there'
    }
    finally { $ui.Window.Close(); $script:ActiveStatsUi = $null }
}
