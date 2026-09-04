# --- the diary page ---------------------------------------------------------
# Built without being shown, like everything else here. What is checked is what a person would
# read off the screen: the line under the title, the six cards, the four lists and the height of
# the hour bars — all of it comes out of one report, and the period is what chooses that report.
#
# The diary is a page of the Settings window now, so a test builds that window and asks for the
# page over it. Nothing is shown, which means every height is nought - and that is the case the
# fallbacks exist for.
#
# The store is this file's own rather than the diary group's: -File 37 has to run on its own, and
# a fake borrowed from a neighbour would make that a broken run instead of a green one.

Write-Host ''
Write-Host 'the diary page' -ForegroundColor White

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

# The page and the window that carries it. The window is handed back too, because it is what has
# to be closed at the end of a test.
function New-DiaryUi {
    param([int]$Days = 7, $Store)
    if ($null -eq $Store) { $Store = New-WindowDiary }
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    $stats = New-StatsUi -Window $ui.Window -Store $Store -Days $Days -Today $script:StatsToday
    Add-Member -InputObject $stats -NotePropertyName Dialog -NotePropertyValue $ui -Force
    return $stats
}

# What a person reads off a row: the name on its first floor.
function Get-DiaryRowName {
    param($Panel, [int]$Index = 0)
    return [string]$Panel.Children[$Index].Children[0].Children[0].Text
}

# What a card says, big: the first line inside its border.
function Get-DiaryCardValue {
    param($Ui, [int]$Index)
    return [string]$Ui.CardsPanel.Children[$Index].Child.Children[0].Text
}

Test-Case 'diary page: opens on the period it was given and says which days it covers' {
    $ui = New-DiaryUi -Days 1
    try {
        Assert-Equal '2026-09-01' $ui.RangeText.Text 'one day needs no range'
        Assert-Equal '1 h 00 min' (Get-DiaryCardValue -Ui $ui -Index 0) 'the time at the computer'
        Assert-Equal 1 $ui.DisplayRows.Children.Count 'one display was used'
        Assert-Equal 'LG ULTRAGEAR' (Get-DiaryRowName $ui.DisplayRows) 'and it is named'
    }
    finally { $ui.Dialog.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary page: a pill rebuilds the whole window for its period' {
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
    finally { $ui.Dialog.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary page: the chosen pill is the filled one, and only it' {
    $ui = New-DiaryUi -Days 30
    try {
        $on = @($ui.Chips | Where-Object { $_.Style -eq $ui.Window.FindResource('ChipOn') })
        Assert-Equal 1 $on.Count 'exactly one is chosen'
        Assert-Equal 30 ([int]$on[0].Tag) 'and it is the period the window is showing'
    }
    finally { $ui.Dialog.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary page: "All" reaches a day no other period does' {
    $ui = New-DiaryUi -Days 30
    try {
        Assert-Equal 3 $ui.Report.DaysRecorded 'a month holds three of the four days'
        Set-StatsPeriod -Ui $ui -Days 0
        Assert-Equal 4 $ui.Report.DaysRecorded 'and "All" holds the day from last year too'
    }
    finally { $ui.Dialog.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary page: modes are named the way they are named everywhere else' {
    $ui = New-DiaryUi -Days 1
    try {
        # The diary keeps keys ("combo:Work"); a window shows titles. Nobody has a mode called
        # "combo:Work" — that is a name for a file, not for a person.
        Assert-Equal 'Work' (Get-DiaryRowName $ui.ModeRows) 'the combination by its name'
        Assert-Equal 'chrome on LG ULTRAGEAR' (Get-DiaryRowName $ui.PairRows) 'and a pair reads as a sentence'
    }
    finally { $ui.Dialog.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary page: an empty period says so instead of drawing zeroes' {
    $ui = New-DiaryUi -Days 1 -Store ([ordered]@{ days = [ordered]@{} })
    try {
        Assert-Equal 'Nothing counted for this period yet.' $ui.RangeText.Text 'the line under the title'
        Assert-Equal 1 $ui.AppRows.Children.Count 'and one line in place of a list'
        Assert-Equal 'nothing yet' ([string]$ui.AppRows.Children[0].Text) 'which says as much'
        Assert-Equal 24 $ui.HoursPanel.Children.Count 'the day is still a whole day'
    }
    finally { $ui.Dialog.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary page: the hour bars fit the panel, and the busiest one is the full height' {
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
    finally { $ui.Dialog.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary page: a share above a hundred does not draw past its track' {
    # One application on two monitors: the pairs add up to more than the time at the computer, and
    # a share is worked out against that time (see ConvertTo-ActivityRows). The bar is two star
    # columns - what is filled in and what is left - so it cannot run over the percentage beside
    # it whatever the number says.
    $ui = New-DiaryUi -Days 1
    try {
        # Children[1] is the track itself now. The percentage moved up beside the time, so the
        # bar has the bottom floor to itself and there is no grid between the two.
        $split = (New-StatsRow -Window $ui.Window -Row ([pscustomobject]@{
            Name = 'chrome'; Seconds = 3600; Share = 140.0 })).Children[1].Child
        Assert-Equal 100.0 ([double]$split.ColumnDefinitions[0].Width.Value) 'filled to the end'
        Assert-Equal 0.0 ([double]$split.ColumnDefinitions[1].Width.Value) 'and nothing is left over'

        $half = (New-StatsRow -Window $ui.Window -Row ([pscustomobject]@{
            Name = 'chrome'; Seconds = 3600; Share = 25.0 })).Children[1].Child
        Assert-Equal 25.0 ([double]$half.ColumnDefinitions[0].Width.Value) 'a quarter is a quarter'
        Assert-Equal 75.0 ([double]$half.ColumnDefinitions[1].Width.Value) 'at any width of window'
    }
    finally { $ui.Dialog.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary page: a long name is not trimmed, and keeps its tooltip' {
    # "chrome on LG ULTRA..." is what the 880-point window did to a forty-character pair. The row
    # is two floors now, and the name has the whole width of the section to itself.
    $ui = New-DiaryUi -Days 1
    try {
        $long = 'chromium-browser|LG ULTRAFINE 4K 27 inch'
        $name = (New-StatsRow -Window $ui.Window -Row ([pscustomobject]@{
            Name = $long; Seconds = 3600; Share = 50.0 })).Children[0].Children[0]
        Assert-Equal 'chromium-browser on LG ULTRAFINE 4K 27 inch' ([string]$name.Text) 'read as a pair'
        Assert-Equal 'None' ([string]$name.TextTrimming) 'nothing is cut off'
        Assert-Equal ([string]$name.Text) ([string]$name.ToolTip) 'and the whole of it is on hover'
    }
    finally { $ui.Dialog.Window.Close(); $script:ActiveStatsUi = $null }
}

Test-Case 'diary page: a section stops at five rows, and says so out of one place' {
    # Four sections share a page: the sixth row is height nobody has, and the tail of a top list
    # is noise. "As many as fit" was tried and taken out - see the comment on StatsTopRows.
    $store = [ordered]@{ days = [ordered]@{} }
    $day = Get-ActivityDay -Store $store -Date (Format-DisplayStamp $script:StatsToday 'yyyy-MM-dd')
    foreach ($app in @('a', 'b', 'c', 'd', 'e', 'f', 'g')) {
        Add-ActivitySpan -Day $day -Process $app -Display 'LG ULTRAFINE' -Mode 'all' `
                         -Seconds 600 -Hour 10
    }
    $ui = New-DiaryUi -Days 1 -Store $store
    try {
        Assert-Equal 7 @($ui.Report.Apps).Count 'seven applications were counted'
        Assert-Equal $script:StatsTopRows $ui.AppRows.Children.Count 'and the section shows five of them'
    }
    finally { $ui.Dialog.Window.Close(); $script:ActiveStatsUi = $null }
}
