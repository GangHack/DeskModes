# --- мир изменился сам ------------------------------------------------------

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
    # Ровно та цена, из-за которой настройку держали пустой: у combo:Work нет
    # ASUS, и без этой проверки включённый кнопкой ASUS гаснул бы через секунду.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug', 'uf') -Now @('ug', 'uf', 'asus') `
                             -LastMode 'combo:Work' -PlugModeMembers @('ug', 'uf')
    Assert-Equal 'none' $d.Action 'the display that came up is not ours, so the desk is left alone'
    Assert-Equal '' $d.Mode ''
}

Test-Case 'reapply: onPlug fires when the display that came up is one of its own' {
    # Стол Егора: всё было выключено, монитор включили кнопкой. Он в combo:Work
    # входит — значит стол собираем мы, а не Windows своей памятью.
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
    # $null — это «не сказали», а не «никто». Иначе первый же вызывающий, который
    # состав не считает, тихо выключил бы настройку целиком.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug') -Now @('ug', 'asus') -LastMode 'combo:Work'
    Assert-Equal 'mode' $d.Action 'applying'
    Assert-Equal 'combo:Work' $d.Mode ''
}

Test-Case 'reapply: a mode with no members left does not fire on a plug' {
    # Пустой список — это «сказали: никого», и это не то же самое, что $null.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug') -Now @('ug', 'asus') `
                             -LastMode 'combo:Work' -PlugModeMembers @()
    Assert-Equal 'none' $d.Action 'nothing to assemble from'
}

Test-Case 'reapply: our own switching never triggers it' {
    # Наши переключения меняют ВКЛЮЧЁННЫЕ мониторы, а сравниваются подключённые:
    # набор тот же — реакции нет. Без этого получался бы бесконечный круг.
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

# --- карантин на эхо --------------------------------------------------------
# Цена этих случаев записана в журнале 2026-08-28. ASUS ушёл с шины в 21:06:43,
# «появился монитор» пришло отдельным событием в 21:06:45 — это Windows зажгла
# то, что осталось. Стол уехал в combo:Work, где ASUS'а нет, и вернуть его было
# нельзя: каждое пробуждение соседнего экрана утверждало Work заново.

Test-Case 'reapply: a display coming up right after another went away is an echo, not a hand' {
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug') -Now @('ug', 'uf') `
                             -LastMode 'solo:asus' -PlugModeMembers @('ug', 'uf') `
                             -VanishedRecently @('asus') -SecondsSinceVanish 2
    Assert-Equal 'none' $d.Action 'the desk is left alone'
    Assert-True ($d.Reason -like '*right after*') 'and the log is told why, or the setting looks broken'
}

Test-Case 'reapply: a display of ours coming back from its own nap is not an echo' {
    # «Выключил кнопкой и включил обратно» — ровно то, ради чего onPlug и заведён.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('uf') -Now @('uf', 'ug') `
                             -LastMode 'combo:Work' -PlugModeMembers @('ug', 'uf') `
                             -VanishedRecently @('ug') -SecondsSinceVanish 2
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
    # Все настоящие вызывающие время передают; пропуск не должен тихо включать
    # карантин навсегда.
    $r = (Get-DefaultSettings).reapply
    $r.onPlug = 'combo:Work'
    $d = Get-ReapplyDecision -Reapply $r -Before @('ug') -Now @('ug', 'uf') `
                             -LastMode 'solo:asus' -PlugModeMembers @('ug', 'uf')
    Assert-Equal 'mode' $d.Action 'applying'
    Assert-Equal 'combo:Work' $d.Mode ''
}

Test-Case 'reapply: the decision names who came up and who went away' {
    # Без имён в журнале видно, какая ветка сработала, но не видно, кто её вызвал.
    $r = (Get-DefaultSettings).reapply
    $d = Get-ReapplyDecision -Reapply $r -Before @('asus', 'ug') -Now @('ug', 'uf') -LastMode 'combo:Work'
    Assert-Equal 'uf' (@($d.Appeared) -join ',') 'so the log can say it by name'
    Assert-Equal 'asus' (@($d.Vanished) -join ',') 'both sides of the change'
}

Test-Case 'desk snapshot: the three states are told apart, because they are not the same thing' {
    # gone — монитора нет на шине (это и есть «погас сам»); off — подключён, но
    # выключен нами; on — показывает. Без этой строки журнал 28 августа говорил
    # «a display went away» и не говорил, какой.
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
    # Это и есть «монитор погас сам»: Windows пишет про него «surprise removed as
    # it is reported as missing on the bus», и в перечислении его больше нет
    # вовсе. Без памяти о прошлых именах журнал сказал бы «a display went away»
    # ровно в том случае, ради которого строка и заведена.
    $state = @((New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf'))
    $known = @{ 'path-uf' = 'LG ULTRAFINE'; 'path-xg' = 'XG27AQDMGR' }

    Assert-Equal 'XG27AQDMGR' (Get-DisplayLabelById -Id 'path-xg' -State $state -Known $known) 'named from memory'
    Assert-Equal 'LG ULTRAFINE' (Get-DisplayLabelById -Id 'path-uf' -State $state -Known $known) 'the desk still wins over memory'
    Assert-Equal 'a display' (Get-DisplayLabelById -Id 'path-never' -State $state -Known $known) 'and one nobody ever saw stays nameless'
}
