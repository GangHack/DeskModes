# --- карточка яркости -------------------------------------------------------
# Две формы записи (число и словарь) окно обязано уметь и НЕ превращать одну в
# другую само: развернув число по мониторам, которые сейчас на столе, оно
# потеряло бы яркость выдернутого и изменило бы смысл «all» для монитора,
# который появится завтра.

Write-Host ''
Write-Host 'the brightness card' -ForegroundColor White

Test-Case 'level model: nothing set reads as "leave it alone"' {
    $m = ConvertTo-LevelModel $null
    Assert-Equal 'none' $m.Kind 'nothing to do'
    Assert-Null (ConvertFrom-LevelModel $m) 'and nothing is written back'
}

Test-Case 'level model: a number is one level for the whole mode' {
    $m = ConvertTo-LevelModel 80
    Assert-Equal 'one' $m.Kind 'one level'
    Assert-Equal 80 $m.Value 'as written'
    Assert-Equal 80 (ConvertFrom-LevelModel $m) 'and it goes back as a number, not as a dictionary'
}

Test-Case 'level model: a dictionary is a level for each display' {
    $m = ConvertTo-LevelModel ([ordered]@{ 'ULTRAFINE' = 25; 'XG27' = 40 })
    Assert-Equal 'each' $m.Kind 'each display'
    Assert-Equal 25 $m.Map['ULTRAFINE'] 'the first'
    Assert-Equal 40 $m.Map['XG27'] 'the second'
    $back = ConvertFrom-LevelModel $m
    Assert-Equal 25 $back['ULTRAFINE'] 'and it comes back the same way'
    Assert-Equal @('ULTRAFINE', 'XG27') @($back.Keys) 'in the same order'
}

Test-Case 'level model: numbers outside 0..100 are clamped on the way in' {
    Assert-Equal 100 (ConvertTo-LevelModel 500).Value 'above'
    Assert-Equal 0 (ConvertTo-LevelModel -7).Value 'below'
    Assert-Equal 100 (ConvertTo-LevelModel ([ordered]@{ 'A' = 900 })).Map['A'] 'in a dictionary too'
}

Test-Case 'level model: junk is not a setting' {
    $m = ConvertTo-LevelModel 'bright'
    Assert-Equal 'none' $m.Kind 'unreadable means nothing set'
    Assert-Equal 'none' (ConvertTo-LevelModel ([ordered]@{})).Kind 'an empty dictionary is nothing set'
}

Test-Case 'level model: an empty per-display map writes no key at all' {
    $m = ConvertTo-LevelModel ([ordered]@{ 'A' = 50 })
    $m.Map.Remove('A')
    Assert-Null (ConvertFrom-LevelModel $m) 'unticking the last display removes the setting'
}

Test-Case 'level settings: modes without brightness stay out of the file' {
    $levels = [ordered]@{
        'all'        = (ConvertTo-LevelModel 80)
        'combo:Work' = (ConvertTo-LevelModel $null)
    }
    $out = ConvertTo-BrightnessSettings -Levels $levels
    Assert-Equal 1 $out.Count 'only the one that has a level'
    Assert-Equal 80 $out['all'] 'and it is the number as written'
}

Test-Case 'level rows: "all displays" lists what is connected' {
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
    try {
        Assert-Equal @('LG ULTRAGEAR', 'LG ULTRAFINE') @(Get-EditorDisplayNames -Editor $ed) 'both connected displays'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'level rows: a combination lists its displays by their real names' {
    # В файле шаблон, а в строке должно стоять полное название монитора: обе
    # записи совпадают, но точнее — то, что видит человек.
    $combo = [pscustomobject]@{ Name = 'Work'; Patterns = @('ULTRAFINE'); Primary = ''; OriginalName = 'Work' }
    $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $script:DlgState -Dark $false
    try {
        Assert-Equal @('LG ULTRAFINE') @(Get-EditorDisplayNames -Editor $ed) 'resolved to the display name'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'level rows: a display mode names the display, not its key' {
    # У двух одинаковых моделей в ключе стоит короткий ID («solo:DELL U2723 ABC123»),
    # и разбор ключа дал бы строку ползунка с именем, которого нет ни на одном
    # мониторе. Состав режима знает Get-ModeMembers — он и отвечает.
    $state = @(
        (New-FakeMonitor 'DELL U2723' 'ABC123' 'path-1')
        (New-FakeMonitor 'DELL U2723' 'ABC124' 'path-2')
    )
    $mode = @(Get-DisplayModes -State $state | Where-Object { $_.Id -eq 'path-1' })[0]
    Assert-Equal 'solo:DELL U2723 ABC123' ([string]$mode.Key) 'the key carries the short id, as it must'
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $state -Dark $false
    try {
        Assert-Equal @('DELL U2723') @(Get-EditorDisplayNames -Editor $ed) 'but the row is named after the display'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'level rows: a level for a display that is gone is still shown' {
    # Иначе такую настройку нельзя ни увидеть, ни снять — тем же правилом живут
    # привязки клавиш к отсутствующим мониторам.
    $names = @(Get-LevelRowNames -Displays @('LG ULTRAGEAR') -Map ([ordered]@{ 'XG27AQDMGR' = 40 }))
    Assert-True ($names -contains 'XG27AQDMGR') 'the orphan row is there'
    Assert-True ($names -contains 'LG ULTRAGEAR') 'next to the display that is here'
}

Test-Case 'mode editor: brightness is offered for every kind of mode' {
    # Яркость живёт в редакторе режима — и обязана быть в редакторе любого режима,
    # не только комбинации.
    foreach ($mode in @(
        [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
        [pscustomobject]@{ Key = 'solo:LG ULTRAGEAR'; Title = 'Only LG ULTRAGEAR'; Kind = 'solo'; Available = $true }
        [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
    )) {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
        try {
            Assert-Equal 3 $ed.LevelKindBox.Items.Count "leave alone / one level / each display for $($mode.Key)"
            Assert-Equal 'none' ([string]$ed.Level.Kind) 'nothing set until asked'
        }
        finally { $ed.Window.Close() }
    }
}

Test-Case 'mode editor: a display mode has no name, members or taskbar to argue about' {
    $mode = [pscustomobject]@{ Key = 'solo:LG ULTRAGEAR'; Title = 'Only LG ULTRAGEAR'; Kind = 'solo'; Available = $true }
    $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $script:DlgState -Dark $false
    try {
        Assert-Equal 'Collapsed' ([string]$ed.Window.FindName('ComboPart').Visibility) 'the combination part is out of the way'
        Assert-Equal 'Only LG ULTRAGEAR' ([string]$ed.Window.FindName('HeadTitle').Text) 'the mode names itself'
        # Пустое имя у комбинации — отказ; у режима монитора имени нет вовсе, и
        # Save обязан пройти.
        $got = Read-ModeFromUi -Editor $ed
        Assert-True $got.Ok 'saving asks nothing of it'
        Assert-Null $got.Mode.PSObject.Properties['Name'] 'and it carries no name back'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: a brightness set for a mode that no longer exists gets its own row' {
    $settings = Get-DefaultSettings
    $settings.brightness['solo:GONE MONITOR'] = 55
    $ui = New-DialogUi -Settings $settings
    try {
        # Два монитора, «все» и строка-сирота: увидеть и снять настройку можно
        # только отсюда.
        Assert-Equal 4 $ui.ModesPanel.Children.Count 'the setting without a mode is listed'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 55 $updated.brightness['solo:GONE MONITOR'] 'and untouched by a plain Save'

        # Remove у такой строки снимает именно её.
        Remove-UiOrphan -Ui $ui -Key 'solo:GONE MONITOR'
        Assert-Equal 3 $ui.ModesPanel.Children.Count 'the row went away'
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ($updated.brightness.Contains('solo:GONE MONITOR')) 'and so did the setting'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a hand-written number survives a Save untouched' {
    # Регрессия, которую здесь и стерегут: разворачивать число в словарь по
    # текущим мониторам нельзя — «all: 80» относится и к тому монитору, который
    # воткнут не сейчас.
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = 80
    $ui = New-DialogUi -Settings $settings
    try {
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 80 $updated.brightness['all'] 'still a number'
        Assert-Equal $false ($updated.brightness['all'] -is [System.Collections.IDictionary]) 'and not a dictionary'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: moving the one-level slider is what gets saved' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Dark $false
        try {
            # Как это делает человек: выбрать форму, подвинуть ползунок, Save.
            $ed.LevelKindBox.SelectedIndex = 1
            $ed.LevelOneSlider.Value = 35
            Assert-Equal 'Visible' ([string]$ed.LevelOnePanel.Visibility) 'the slider showed up'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 35 $updated.brightness['all'] 'the level landed in the settings'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: Cancel leaves the brightness the window already had' {
    # Редактор правит КОПИЮ модели: иначе «подвигал и передумал» уже изменило бы
    # настройку, и Cancel врал бы.
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = 70
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Levels $ui.Levels -Dark $false
        try {
            $ed.LevelOneSlider.Value = 20
            Assert-Equal 20 ([int]$ed.Level.Value) 'the editor moved'
        }
        finally { $ed.Window.Close() }
        # Ответ редактора не применяли — окно обязано остаться при своих.
        Assert-Equal 70 ([int]$ui.Levels['all'].Value) 'the window did not'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: unticking every display removes the setting instead of writing zeros' {
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = [ordered]@{ 'LG ULTRAGEAR' = 60 }
    $ui = New-DialogUi -Settings $settings
    try {
        $ui.Levels['all'].Map.Remove('LG ULTRAGEAR')
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal $false ($updated.brightness.Contains('all')) 'the key is gone, not zeroed'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: switching to per-display seeds it from the level it had' {
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = 70
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Levels $ui.Levels -Dark $false
        try {
            Assert-Equal 'one' ([string]$ed.Level.Kind) 'started as one level'
            # Человек видел 70 и должен править от семидесяти, а не от пустого списка.
            $ed.LevelKindBox.SelectedIndex = 2
            $got = Read-ModeFromUi -Editor $ed
            Set-UiMode -Ui $ui -Mode $mode -Combo $null -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 70 $updated.brightness['all']['LG ULTRAGEAR'] 'seeded with what was shown'
        Assert-Equal 70 $updated.brightness['all']['LG ULTRAFINE'] 'for every display of the mode'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: the per-display rows are really built' {
    # Тест на построение, а не на модель: первая версия строк звала
    # [GridLength]::Parse, которого не существует, и переход на «каждому своё»
    # падал в живом окне. Модель при этом была в полном порядке — поймал снимок
    # окна, а не тест, поэтому теперь строки строятся здесь.
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = [ordered]@{ 'LG ULTRAGEAR' = 60; 'LG ULTRAFINE' = 25 }
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Levels $ui.Levels -Dark $false
        try {
            Assert-Equal 'Collapsed' ([string]$ed.LevelOnePanel.Visibility) 'the single slider is out of the way'
            Assert-Equal 2 $ed.LevelRowsPanel.Children.Count 'a row per display'
            # Первый столбец строки — галочка «задано», она же подписана названием.
            $first = $ed.LevelRowsPanel.Children[0]
            Assert-Equal 'LG ULTRAGEAR' ([string]$first.Children[0].Content) 'named after the display'
            Assert-True ([bool]$first.Children[0].IsChecked) 'ticked, because a level is set'
            Assert-Equal 60 ([int]$first.Children[1].Value) 'and the slider stands where the setting says'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: a display with no level gets an unticked, disabled row' {
    $settings = Get-DefaultSettings
    $settings.brightness['all'] = [ordered]@{ 'LG ULTRAGEAR' = 60 }
    $ui = New-DialogUi -Settings $settings
    $mode = [pscustomobject]@{ Key = 'all'; Title = 'All displays'; Kind = 'all'; Available = $true }
    try {
        $ed = New-ModeEditorWindow -Mode $mode -Combo $null -State $ui.State -Levels $ui.Levels -Dark $false
        try {
            $rows = @($ed.LevelRowsPanel.Children)
            $off = @($rows | Where-Object { [string]$_.Children[0].Content -eq 'LG ULTRAFINE' })
            Assert-Equal 1 $off.Count 'the display without a level still has a row'
            Assert-Equal $false ([bool]$off[0].Children[0].IsChecked) 'unticked'
            Assert-Equal $false ([bool]$off[0].Children[1].IsEnabled) 'and its slider is out of action'
            Assert-Equal 'off' ([string]$off[0].Children[2].Text) 'and it says off, not zero'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'mode editor: unticking a display drops its brightness row with it' {
    # Иначе под комбинацией остался бы ползунок монитора, которого в ней уже нет.
    $combo = [pscustomobject]@{ Name = 'Work'; Patterns = @('LG ULTRAGEAR', 'LG ULTRAFINE'); Primary = ''; OriginalName = 'Work' }
    $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
    $level = ConvertTo-LevelModel ([ordered]@{ 'LG ULTRAGEAR' = 60; 'LG ULTRAFINE' = 25 })
    $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $script:DlgState `
                               -Levels ([ordered]@{ 'combo:Work' = $level }) -Dark $false
    try {
        Assert-Equal 2 $ed.LevelRowsPanel.Children.Count 'both displays have a row'
        $uf = @($ed.Checks | Where-Object { [string]$_.Tag -eq 'LG ULTRAFINE' })[0]
        $uf.IsChecked = $false
        $uf.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        $names = @($ed.LevelRowsPanel.Children | ForEach-Object { [string]$_.Children[0].Content })
        # Строка остаётся, но уже как сирота: значение задано, и снять его можно
        # только видя его.
        Assert-True ($names -contains 'LG ULTRAGEAR') 'the display that stayed keeps its row'
        $got = Read-ModeFromUi -Editor $ed
        Assert-Equal @('LG ULTRAGEAR') @($got.Mode.Patterns) 'and the combination lost the display'
    }
    finally { $ed.Window.Close() }
}

Test-Case 'dialog: renaming a combination carries the sliders too' {
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.brightness['combo:Work'] = 45
    $ui = New-DialogUi -Settings $settings
    try {
        # Через ту же дверь, что и живое окно: имя меняет редактор режима, а не
        # рука в списке комбинаций.
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Office'; Patterns = @('LG ULTRAGEAR'); Primary = ''
            Level = $ui.Levels['combo:Work'] })
        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 45 $updated.brightness['combo:Office'] 'followed the new name'
        Assert-Equal $false ($updated.brightness.Contains('combo:Work')) 'and left no ghost'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'dialog: a new combination taking a freed name keeps its own brightness' {
    # Яркость Set-UiMode перекладывает на новый ключ сразу, поэтому на Save её
    # переименовывать НЕ надо: иначе новая комбинация, занявшая освободившееся
    # имя, совпадает с источником переименования и молча теряет свою яркость.
    $settings = Get-DefaultSettings
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.brightness['combo:Work'] = 30
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited ([pscustomobject]@{
            Name = 'Play'; Patterns = @('LG ULTRAGEAR'); Primary = ''
            Level = $ui.Levels['combo:Work'] })
        # И тут же заводим новую «Work» — имя освободилось.
        Set-UiMode -Ui $ui -Mode $null -Combo $null -Edited ([pscustomobject]@{
            Name = 'Work'; Patterns = @('LG ULTRAFINE'); Primary = ''
            Level = [pscustomobject]@{ Kind = 'one'; Value = 70; Map = [ordered]@{} } })

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 30 $updated.brightness['combo:Play'] 'the renamed one kept its level'
        Assert-Equal 70 $updated.brightness['combo:Work'] 'and the new one kept its own'
    }
    finally { $ui.Window.Close() }
}
