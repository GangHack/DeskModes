# --- the diary --------------------------------------------------------------

Write-Host ''
Write-Host 'the diary' -ForegroundColor White

function New-TestDiary {
    # Four days in a row, three activities a day. The numbers are round on purpose: both the
    # percentages and the averages have to add up in the report.
    $store = [ordered]@{ days = [ordered]@{} }
    foreach ($offset in 0..3) {
        # The day's key is assembled by the same function the code uses: on a locale with a different
        # calendar, ToString without a culture would give the year 2569, and the report would be looking
        # for days that are not in the pot (see Format-DisplayStamp).
        $date = Format-DisplayStamp ([datetime]'2026-08-21').AddDays(-$offset) 'yyyy-MM-dd'
        $day = Get-ActivityDay -Store $store -Date $date
        Add-ActivitySpan -Day $day -Process 'chrome' -Display 'LG ULTRAGEAR' -Mode 'combo:Work' -Seconds 3600 -Time '09:00' -Hour 9
        Add-ActivitySpan -Day $day -Process 'Code' -Display 'LG ULTRAFINE' -Mode 'combo:Work' -Seconds 5400 -Time '13:00' -Hour 13
        Add-ActivitySpan -Day $day -Process 'cs2' -Display 'XG27AQDMGR' -Mode 'solo:XG27AQDMGR' -Seconds 1800 -Time '21:00' -Hour 21
        $day.switches = 7
        $day.longest = 4200
    }
    return $store
}

Test-Case 'diary: a span lands in every bucket at once' {
    $day = New-ActivityDay
    Add-ActivitySpan -Day $day -Process 'chrome' -Display 'LG ULTRAGEAR' -Mode 'all' -Seconds 60 -Time '10:15' -Hour 10
    Assert-Equal 60 $day.active 'time at the computer'
    Assert-Equal 60 $day.apps['chrome'] 'the app'
    Assert-Equal 60 $day.displays['LG ULTRAGEAR'] 'the display'
    Assert-Equal 60 $day.modes['all'] 'the mode'
    Assert-Equal 60 $day.pairs['chrome|LG ULTRAGEAR'] 'and the pair of app and display'
    Assert-Equal 60 $day.hours['10'] 'the hour of the day'
    Assert-Equal '10:15' $day.first 'when the day started'
}

Test-Case 'diary: spans add up, and the first time stays the first' {
    $day = New-ActivityDay
    Add-ActivitySpan -Day $day -Process 'chrome' -Display 'A' -Mode 'all' -Seconds 60 -Time '09:00' -Hour 9
    Add-ActivitySpan -Day $day -Process 'chrome' -Display 'A' -Mode 'all' -Seconds 30 -Time '17:40' -Hour 17
    Assert-Equal 90 $day.apps['chrome'] 'summed'
    Assert-Equal '09:00' $day.first 'the morning'
    Assert-Equal '17:40' $day.last 'and the evening'
}

Test-Case 'diary: an empty span changes nothing' {
    $day = New-ActivityDay
    Add-ActivitySpan -Day $day -Process 'chrome' -Display 'A' -Mode 'all' -Seconds 0 -Time '09:00' -Hour 9
    Assert-Equal 0 $day.active 'nothing counted'
    Assert-Equal '' $day.first 'and the day has not started'
}

Test-Case 'diary: a window on no known display still counts as time' {
    # The monitor could have been pulled out between the sample and the cache refresh.
    $day = New-ActivityDay
    Add-ActivitySpan -Day $day -Process 'chrome' -Display '' -Mode 'all' -Seconds 60 -Hour 9
    Assert-Equal 60 $day.active 'the time is real'
    Assert-Equal 60 $day.apps['chrome'] 'and so is the app'
    Assert-Equal 0 $day.pairs.Count 'but there is no pair to record'
}

Test-Case 'diary: the report adds the days up' {
    $rep = Get-ActivityReport -Store (New-TestDiary) -Days 30 -Today ([datetime]'2026-08-21')
    Assert-Equal 4 $rep.DaysRecorded 'four days'
    Assert-Equal 43200 $rep.Active 'twelve hours in total'
    Assert-Equal 10800 $rep.AverageDay 'three hours a day'
    Assert-Equal 28 $rep.Switches 'seven switches a day'
    Assert-Equal 4200 $rep.Longest 'the longest session of any day'
    Assert-Equal '2026-08-18' $rep.From 'from'
    Assert-Equal '2026-08-21' $rep.To 'to'
}

Test-Case 'diary: shares are of the time at the computer' {
    $rep = Get-ActivityReport -Store (New-TestDiary) -Days 30 -Today ([datetime]'2026-08-21')
    Assert-Equal 'Code' $rep.Apps[0].Name 'the app with the most time first'
    Assert-Equal 50 $rep.Apps[0].Share 'half the time'
    Assert-Equal 'LG ULTRAFINE' $rep.Displays[0].Name 'and the display with the most time'
}

Test-Case 'diary: the busiest hour is the tallest bar, and all 24 are there' {
    $rep = Get-ActivityReport -Store (New-TestDiary) -Days 30 -Today ([datetime]'2026-08-21')
    Assert-Equal 24 @($rep.Hours).Count 'a bar for every hour, empty ones included'
    Assert-Equal 13 $rep.BusiestHour 'the afternoon'
    Assert-Equal 100 (@($rep.Hours | Where-Object { $_.Name -eq '13' })[0].Share) 'the tallest bar is full height'
}

Test-Case 'diary: the usual day is the average of its ends' {
    $rep = Get-ActivityReport -Store (New-TestDiary) -Days 30 -Today ([datetime]'2026-08-21')
    Assert-Equal '09:00' $rep.AverageStart 'sat down'
    Assert-Equal '21:00' $rep.AverageEnd 'got up'
}

Test-Case 'diary: days in a row stop at the first gap' {
    $today = [datetime]'2026-08-21'
    Assert-Equal 4 (Get-ActivityStreak -Dates @('2026-08-18', '2026-08-19', '2026-08-20', '2026-08-21') -Today $today) 'four in a row'
    Assert-Equal 2 (Get-ActivityStreak -Dates @('2026-08-18', '2026-08-20', '2026-08-21') -Today $today) 'a missed day ends the streak'
    Assert-Equal 0 (Get-ActivityStreak -Dates @('2026-08-19') -Today $today) 'nothing today means no streak at all'
}

Test-Case 'diary: only the asked-for days are counted' {
    $rep = Get-ActivityReport -Store (New-TestDiary) -Days 2 -Today ([datetime]'2026-08-21')
    Assert-Equal 2 $rep.DaysRecorded 'two days'
    Assert-Equal 21600 $rep.Active 'and their time only'
}

Test-Case 'diary: an empty diary reads as empty, not as a crash' {
    $rep = Get-ActivityReport -Store ([ordered]@{ days = [ordered]@{} }) -Days 30
    Assert-Equal 0 $rep.DaysRecorded 'nothing recorded'
    Assert-Equal 0 $rep.Active 'no time'
    $lines = @(Format-ActivityReport -Report $rep)
    Assert-Equal 1 $lines.Count 'one line of explanation'
    Assert-True ($lines[0] -like '*Nothing in the diary yet*') 'and it says why'
    # There must be no "turn the diary on" advice here: with the diary already on it would be a lie,
    # and only the caller knows about that.
    Assert-Equal $false ($lines[0] -like '*Turn stats on*') 'and does not advise what it cannot know'
}

Test-Case 'diary: the report reads like a report' {
    $text = (Format-ActivityReport -Report (Get-ActivityReport -Store (New-TestDiary) -Days 30 -Today ([datetime]'2026-08-21'))) -join "`n"
    Assert-True ($text -like '*at the computer*12 h 00 min*') 'the total'
    Assert-True ($text -like '*Code*6 h 00 min*') 'the top app with its time'
    Assert-True ($text -like '*chrome on LG ULTRAGEAR*') 'and which display it was on'
}

Test-Case 'diary: time reads as hours and minutes' {
    Assert-Equal '-' (Format-ActivitySpan 0)
    Assert-Equal '30 min' (Format-ActivitySpan 1800)
    Assert-Equal '2 h 00 min' (Format-ActivitySpan 7200)
    Assert-Equal '1 h 01 min' (Format-ActivitySpan 3660)
}

Test-Case 'diary: what is written is what comes back' {
    $script:ActivityFile = Join-Path $script:TestDir 'activity.json'
    $script:ActivityStore = New-TestDiary
    $script:ActivityDirty = $true
    Save-ActivityStore
    $script:ActivityStore = $null
    $back = Get-ActivityStore
    Assert-Equal 4 @($back.days.Keys).Count 'four days came back'
    $rep = Get-ActivityReport -Store $back -Days 30 -Today ([datetime]'2026-08-21')
    Assert-Equal 43200 $rep.Active 'with their time'
    Assert-Equal 28 $rep.Switches 'and their switches'
    Assert-Equal 'Code' $rep.Apps[0].Name 'and their apps'
}

Test-Case 'diary: a damaged file is a new diary, not a crash' {
    $script:ActivityFile = Join-Path $script:TestDir 'activity-bad.json'
    'not json at all' | Set-Content -Path $script:ActivityFile -Encoding UTF8
    $script:ActivityStore = $null
    $store = Get-ActivityStore
    Assert-Equal 0 @($store.days.Keys).Count 'empty and working'
}

Test-Case 'diary: a day written by an older version reads without its missing parts' {
    $raw = '{"active":600,"apps":{"chrome":600}}' | ConvertFrom-Json
    $day = ConvertTo-ActivityDay $raw
    Assert-Equal 600 $day.active 'what was there'
    Assert-Equal 600 $day.apps['chrome'] 'and what it held'
    Assert-Equal 0 $day.pairs.Count 'what was not there is empty, not missing'
    Assert-Equal 0 $day.switches 'and numbers are zero'
}

Test-Case 'diary: the page cannot be broken by a monitor name' {
    # A monitor's name comes from EDID, and the manufacturer writes whatever it likes in there.
    $store = [ordered]@{ days = [ordered]@{} }
    $day = Get-ActivityDay -Store $store -Date '2026-08-21'
    Add-ActivitySpan -Day $day -Process 'chrome' -Display '<script>bad</script>' -Mode 'all' -Seconds 60 -Hour 9
    $html = New-ActivityHtml -Report (Get-ActivityReport -Store $store -Days 30 -Today ([datetime]'2026-08-21'))
    Assert-True ($html -like '*&lt;script&gt;bad&lt;/script&gt;*') 'escaped'
    Assert-Equal $false ($html -like '*<script>bad*') 'and not left as markup'
}

Test-Case 'diary: the page holds the numbers and calls nobody' {
    $html = New-ActivityHtml -Report (Get-ActivityReport -Store (New-TestDiary) -Days 30 -Today ([datetime]'2026-08-21'))
    Assert-True ($html -like '*12 h 00 min*') 'the total is there'
    Assert-True ($html -like '*LG ULTRAFINE*') 'and the displays'
    # The project's promise: nothing is installed and nobody is invited in.
    Assert-Equal $false ($html -like '*http://*') 'no outside links'
    Assert-Equal $false ($html -like '*https://*') 'none at all'
    # Percentages in CSS take a dot only. "width:12,5%" the browser throws away entirely, and the bars
    # go to zero width and the histogram flat: on a Russian locale the report would be an empty picture
    # (see Format-ActivityPercent). The fractional shares in the pot are there on purpose — otherwise
    # there would be nothing to test.
    Assert-True ($html -like '*width:33.3%*') 'a fractional share keeps its decimal point'
    Assert-Equal $false ($html -match '(width|height):[0-9]+,') 'and no locale comma anywhere in the CSS'
}
