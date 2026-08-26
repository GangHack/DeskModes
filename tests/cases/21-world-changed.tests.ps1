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
