# --- the world changed by itself --------------------------------------------

Write-Host ''
Write-Host 'rebuilding the desk when the world changed' -ForegroundColor White

Test-Case 'reapply: a display went away and the last mode is rebuilt' {
    $r = (Get-DefaultSettings).reapply
    $d = Get-ReapplyDecision -Reapply $r -Before @('a', 'b') -Now @('a') -LastMode 'combo:Work'
    Assert-Equal 'mode' $d.Action 'rebuilding'
    Assert-Equal 'combo:Work' $d.Mode 'the last chosen mode'
    Assert-True ($d.Reason -like '*went away*') 'and it says why'
}

Test-Case 'reapply: a display appeared and nothing happens unless asked' {
    $r = (Get-DefaultSettings).reapply
    $d = Get-ReapplyDecision -Reapply $r -Before @('a') -Now @('a', 'b') -LastMode 'combo:Work'
    Assert-Equal 'none' $d.Action 'turning off what the human just turned on would be a war'
}

Test-Case 'reapply: a display appeared and the named mode is applied' {
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'all'
    $d = Get-ReapplyDecision -Reapply $r -Before @('a') -Now @('a', 'b') -LastMode 'combo:Work'
    Assert-Equal 'mode' $d.Action 'applying'
    Assert-Equal 'all' $d.Mode 'the mode named in the settings'
}

Test-Case 'reapply: onPlug only fires for a display the mode actually includes' {
    # Exactly the price the setting was kept empty over: combo:Work has no ASUS in it, and without this
    # check an ASUS switched on with the button would go out a second later.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug', 'uf') -Now @('ug', 'uf', 'asus') `
                             -LastMode 'combo:Work' -PlugModeMembers @('ug', 'uf')
    Assert-Equal 'none' $d.Action 'the display that came up is not ours, so the desk is left alone'
    Assert-Equal '' $d.Mode ''
}

Test-Case 'reapply: onPlug fires when the display that came up is one of its own' {
    # The real desk: everything was off and a monitor was switched on with the button. It belongs to
    # combo:Work — so it is us who assembles the desk, not Windows out of its own memory.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @() -Now @('ug') `
                             -LastMode 'combo:Work' -PlugModeMembers @('ug', 'uf')
    Assert-Equal 'none' $d.Action 'but an empty before is the first look, not a change'

    $d = Get-ReapplyDecision -Reapply $r -Before @('uf') -Now @('uf', 'ug') `
                             -LastMode 'combo:Work' -PlugModeMembers @('ug', 'uf')
    Assert-Equal 'mode' $d.Action 'a member came back, so the desk is assembled'
    Assert-Equal 'combo:Work' $d.Mode ''
    Assert-Equal 'a display was plugged in' $d.Reason 'and the log says why'
}

Test-Case 'reapply: with all, every display is its own, so the check changes nothing' {
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'all'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug') -Now @('ug', 'asus') `
                             -LastMode 'combo:Work' -PlugModeMembers @('ug', 'asus')
    Assert-Equal 'mode' $d.Action 'applying'
    Assert-Equal 'all' $d.Mode ''
}

Test-Case 'reapply: not being told who belongs to the mode keeps the old behaviour' {
    # $null is "we were not told" and not "nobody". Otherwise the very first caller that does not work
    # out the membership would quietly switch the setting off altogether.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug') -Now @('ug', 'asus') -LastMode 'combo:Work'
    Assert-Equal 'mode' $d.Action 'applying'
    Assert-Equal 'combo:Work' $d.Mode ''
}

Test-Case 'reapply: a mode with no members left does not fire on a plug' {
    # An empty list is "we were told: nobody", and that is not the same thing as $null.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug') -Now @('ug', 'asus') `
                             -LastMode 'combo:Work' -PlugModeMembers @()
    Assert-Equal 'none' $d.Action 'nothing to assemble from'
}

Test-Case 'reapply: our own switching never triggers it' {
    # Our switches change the monitors that are ON, while it is the connected ones that get compared:
    # the set is the same — no reaction. Without this it would go round in an endless circle.
    $r = (Get-DefaultSettings).reapply
    $d = Get-ReapplyDecision -Reapply $r -Before @('a', 'b') -Now @('b', 'a') -LastMode 'combo:Work'
    Assert-Equal 'none' $d.Action 'same set, different order'
}

Test-Case 'reapply: turned off in the settings means nothing happens' {
    $r = (Get-DefaultSettings).reapply
    $r.onUnplug = $false
    $d = Get-ReapplyDecision -Reapply $r -Before @('a', 'b') -Now @('a') -LastMode 'combo:Work'
    Assert-Equal 'none' $d.Action 'his choice'
}

Test-Case 'reapply: nothing remembered means nothing to rebuild' {
    $r = (Get-DefaultSettings).reapply
    $d = Get-ReapplyDecision -Reapply $r -Before @('a', 'b') -Now @('a') -LastMode ''
    Assert-Equal 'none' $d.Action 'no last mode'
}

Test-Case 'reapply: the first look at the desk is not a change' {
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'all'
    $d = Get-ReapplyDecision -Reapply $r -Before @() -Now @('a', 'b') -LastMode 'combo:Work'
    Assert-Equal 'none' $d.Action 'the tray just started - there is nothing to compare with'
}

Test-Case 'reapply: a cable swapped for another display prefers the plug rule' {
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'all'
    $d = Get-ReapplyDecision -Reapply $r -Before @('a') -Now @('b') -LastMode 'combo:Work'
    Assert-Equal 'all' $d.Mode 'the new display is the news here'
}

Test-Case 'reapply: a cable swap is still the news with the quarantine armed' {
    # The exemption has to hold when the clock is running, not only when it happens to be unarmed:
    # one unrelated flap a second earlier used to send the swap down the unplug branch instead.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'all'
    $d = Get-ReapplyDecision -Reapply $r -Before @('a') -Now @('b') -LastMode 'combo:Work' `
                             -VanishedRecently @('z') -SecondsSinceVanish 1
    Assert-Equal 'all' $d.Mode 'a vanish and an appearance in ONE event is a hand on a cable'
}

# --- the quarantine against echoes ------------------------------------------
# The price of these cases is written down in the log for 2026-08-28. The ASUS left the bus at
# 21:06:43, and "a monitor came up" arrived as a separate event at 21:06:45 — that was Windows lighting
# what was left. The desk went off to combo:Work, which has no ASUS in it, and there was no bringing it
# back: every waking of the neighbouring screen affirmed Work all over again.

Test-Case 'reapply: a display coming up right after another went away is an echo, not a hand' {
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug') -Now @('ug', 'uf') `
                             -LastMode 'solo:asus' -PlugModeMembers @('ug', 'uf') `
                             -VanishedRecently @('asus') -SecondsSinceVanish 2
    Assert-Equal 'none' $d.Action 'the desk is left alone'
    Assert-True ($d.Reason -like '*right after*') 'and the log is told why, or the setting looks broken'
}

Test-Case 'reapply: a display back a second after its own vanish is the monitor napping' {
    # Twice in the evening of 2026-08-30 (19:58 and 23:47): a ULTRAGEAR that had been put out by a mode
    # left the bus by itself and came back a SECOND later, onPlug applied combo:Work and put the ASUS out
    # in the middle of a full-screen window. It looks like a hand on a button, but it is the monitor's
    # deep sleep — only the timing tells them apart (see the case below).
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('uf') -Now @('uf', 'ug') `
                             -LastMode 'combo:Work' -PlugModeMembers @('ug', 'uf') `
                             -VanishedRecently @('ug') -SecondsSinceVanish 1
    Assert-Equal 'none' $d.Action 'the desk is left alone'
    Assert-True ($d.Reason -like '*right after*') 'and the log is told why, or the setting looks broken'
}

Test-Case 'reapply: a clock that stepped backwards does not arm the quarantine' {
    # The gap comes off the wall clock, which jumps back on the autumn hour and on any NTP correction.
    # A negative gap is "less than QuietSeconds" too, so without a lower bound every real press of a
    # button would be dismissed as an echo for as long as the jump lasted.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug') -Now @('ug', 'uf') `
                             -LastMode 'solo:asus' -PlugModeMembers @('ug', 'uf') `
                             -VanishedRecently @('asus') -SecondsSinceVanish -3600
    Assert-Equal 'combo:Work' $d.Mode 'an hour in the wrong direction is not "right after"'
}

Test-Case 'reapply: the same display back long after is a hand on its button' {
    # "Switched off with the button and switched back on" is exactly what onPlug exists for, and the
    # quarantine has to let it through. In the log these two cases are not neighbours but different
    # worlds: its own flap is 1 s, a real switch-on is 17335 s and 35256 s.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('uf') -Now @('uf', 'ug') `
                             -LastMode 'combo:Work' -PlugModeMembers @('ug', 'uf') `
                             -VanishedRecently @('ug') -SecondsSinceVanish 60
    Assert-Equal 'mode' $d.Action 'the same display came back, so the desk is assembled'
    Assert-Equal 'combo:Work' $d.Mode ''
}

Test-Case 'reapply: the quarantine runs out and a later plug is honoured again' {
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug') -Now @('ug', 'uf') `
                             -LastMode 'solo:asus' -PlugModeMembers @('ug', 'uf') `
                             -VanishedRecently @('asus') -SecondsSinceVanish 60
    Assert-Equal 'mode' $d.Action 'a minute later nobody is reshuffling the desk any more'
    Assert-Equal 'combo:Work' $d.Mode ''
}

Test-Case 'reapply: never being told about a past vanish keeps the old behaviour' {
    # Every real caller passes the time; leaving it out must not quietly switch the quarantine on forever.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug') -Now @('ug', 'uf') `
                             -LastMode 'solo:asus' -PlugModeMembers @('ug', 'uf')
    Assert-Equal 'mode' $d.Action 'applying'
    Assert-Equal 'combo:Work' $d.Mode ''
}

Test-Case 'reapply: the decision names who came up and who went away' {
    # Without the names, the log shows which branch fired but not what set it off.
    $r = (Get-DefaultSettings).reapply
    $d = Get-ReapplyDecision -Reapply $r -Before @('asus', 'ug') -Now @('ug', 'uf') -LastMode 'combo:Work'
    Assert-Equal 'uf' (@($d.Appeared) -join ',') 'so the log can say it by name'
    Assert-Equal 'asus' (@($d.Vanished) -join ',') 'both sides of the change'
}

Test-Case 'desk snapshot: the three states are told apart, because they are not the same thing' {
    # gone — the monitor is not on the bus (that is "it went out by itself"); off — connected but
    # switched off by us; on — showing. Without this line the log of 28 August said "a display went away"
    # and did not say which.
    $on = New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug'
    $off = New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf' $false
    $gone = New-FakeMonitor 'XG27AQDMGR' 'AUSAA1D' 'path-xg' $false $true

    $line = Format-DeskSnapshot -State @($gone, $on, $off)
    Assert-Equal 'XG27AQDMGR gone, LG ULTRAGEAR on 2560x1440@144, LG ULTRAFINE off' $line 'the whole desk in one line'
}

Test-Case 'desk snapshot: an empty desk says so instead of an empty line' {
    Assert-Equal 'nothing at all' (Format-DeskSnapshot -State @()) 'a blank line in the log would read as a bug'
}

Test-Case 'reapply: a display is named from the state, and an unplugged cable leaves nothing to name' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'XG27AQDMGR' 'AUS1234' 'path-xg' $true $true)
    )
    Assert-Equal 'LG ULTRAGEAR' (Get-DisplayLabelById -Id 'path-ug' -State $state) 'the one still on the desk'
    Assert-Equal 'XG27AQDMGR' (Get-DisplayLabelById -Id 'path-xg' -State $state) 'and the one that only went to sleep'
    Assert-Equal 'a display' (Get-DisplayLabelById -Id 'path-gone' -State $state) 'a pulled cable takes the name with it'
}

Test-Case 'reapply: a display the driver took off the bus is still named, from what we saw before' {
    # This is what "the monitor went out by itself" is: Windows writes about it as "surprise removed as
    # it is reported as missing on the bus", and it is no longer in the enumeration at all. Without a
    # memory of the earlier names the log would have said "a display went away" in exactly the case the
    # line was created for.
    $state = @((New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf'))
    $known = @{ 'path-uf' = 'LG ULTRAFINE'; 'path-xg' = 'XG27AQDMGR' }

    Assert-Equal 'XG27AQDMGR' (Get-DisplayLabelById -Id 'path-xg' -State $state -Known $known) 'named from memory'
    Assert-Equal 'LG ULTRAFINE' (Get-DisplayLabelById -Id 'path-uf' -State $state -Known $known) 'the desk still wins over memory'
    Assert-Equal 'a display' (Get-DisplayLabelById -Id 'path-never' -State $state -Known $known) 'and one nobody ever saw stays nameless'
}

Test-Case 'reapply: a display nobody remembers is still named, from its own path' {
    # 31 August, 20:10: neither the desk nor the memory of earlier names had the ASUS that had just left
    # the bus, and the log wrote the anonymous "a display". That build filled the memory from the desk
    # snapshot, which runs after the refresh and so is empty on a run's first event; it is filled from
    # Update-StateCache now, and the two can no longer disagree. This is the road below both of them,
    # kept because the job here is that the log never says "somebody": the path IS the identifier, and
    # the monitor's own id sits inside it.
    $state = @((New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf'))
    $gone = '\?\DISPLAY#GSM5BB3#5&2a1f4e2&0&UID4353#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}'

    Assert-Equal 'GSM5BB3' (Get-DisplayLabelById -Id $gone -State $state) 'named from the path'
    Assert-Equal 'GSM5BB3' (Get-MonitorIdFromPath -Id $gone) 'the id comes out of the path'
    Assert-Equal '' (Get-MonitorIdFromPath -Id 'path-xg') 'a path of another shape invents nothing'
    Assert-Equal 'a display' (Get-DisplayLabelById -Id 'path-xg' -State $state) 'and then the honest answer stands'
}
