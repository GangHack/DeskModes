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
