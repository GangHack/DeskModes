# --- имя комбинации — это её ключ -------------------------------------------
# Комбинацию можно стереть из файла рукой, а её клавишу, яркость, звук и команды
# оставить: они лежат под ключом `combo:<имя>`, и окно показывает их строкой-
# сиротой. Завести комбинацию с тем же именем — значит занять тот самый ключ.
# Звук и команды достаются ей в любом случае, поэтому клавиша с яркостью обязаны
# и достаться, и БЫТЬ ВИДНЫ: пустые поля редактора молча стирали две настройки из
# четырёх, а сохранённая клавиша сироты вдобавок считалась чужой.

Write-Host ''
Write-Host 'a name that was already used once' -ForegroundColor White

# Настройки-сироты: комбинации Movie нет, а всё, что к ней было привязано, есть.
function New-OrphanSettings {
    $s = Get-DefaultSettings
    $s.brightness['combo:Movie'] = 55
    $s.hotkeys['combo:Movie'] = 'Ctrl+Alt+F4'
    $s.audio['combo:Movie'] = 'ROG'
    return $s
}

Test-Case 'orphan: a new combination with that name is shown what it inherits' {
    $settings = New-OrphanSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark $false
        try {
            Assert-Equal $script:NoHotkeyText $ed.HotkeyBox.Text 'nothing to inherit until there is a name'
            Assert-Equal 'none' ([string]$ed.Level.Kind) 'and no brightness either'

            $ed.NameBox.Text = 'Movie'
            Assert-Equal 'Ctrl+Alt+F4' $ed.HotkeyBox.Text 'the shortcut left under that name is shown, not hidden'
            Assert-Equal 55 ([int]$ed.Level.Value) 'and so is the brightness'
            Assert-Equal 'one' ([string]$ed.Level.Kind) 'in the shape it was written in'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: its own shortcut is not somebody else - the editor takes it' {
    # Так это и ломалось: клавиша сироты считалась занятой, и редактор ссылался на
    # режим, которого в окне нет и открыть который нельзя. Выйти можно было только
    # удалив строку-сироту.
    $settings = New-OrphanSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark $false
        try {
            $ed.NameBox.Text = 'Movie'
            $ed.Checks[0].IsChecked = $true
            $ed.HotkeyBox.Text = 'Ctrl+Alt+F4'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'the shortcut of the name it takes over is its own'
            Assert-Equal 'Ctrl+Alt+F4' $got.Mode.Hotkey 'and comes back as the mode shortcut'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: all four settings come back, none of them quietly killed' {
    $settings = New-OrphanSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark $false
        try {
            $ed.NameBox.Text = 'Movie'
            $ed.Checks[0].IsChecked = $true
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Set-UiMode -Ui $ui -Mode $null -Combo $null -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'Ctrl+Alt+F4' $updated.hotkeys['combo:Movie'] 'the shortcut survived'
        Assert-Equal 55 $updated.brightness['combo:Movie'] 'the brightness survived'
        Assert-Equal 'ROG' $updated.audio['combo:Movie'] 'the sound was never in danger'
        Assert-True ($updated.combos.Contains('Movie')) 'and the combination itself is there'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: what the person set himself beats what the name would bring' {
    $settings = New-OrphanSettings
    $ui = New-DialogUi -Settings $settings
    try {
        $ed = New-ModeEditorWindow -Mode $null -Combo $null -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark $false
        try {
            # Сначала своя клавиша и своя яркость, и только потом имя.
            $ed.HotkeyBox.Text = 'Ctrl+Alt+F7'
            $ed.LevelKindBox.SelectedIndex = 1
            $ed.LevelOneSlider.Value = 20
            $ed.NameBox.Text = 'Movie'
            Assert-Equal 'Ctrl+Alt+F7' $ed.HotkeyBox.Text 'his shortcut stayed'
            Assert-Equal 20 ([int]$ed.Level.Value) 'and his brightness too'
        }
        finally { $ed.Window.Close() }
    }
    finally { $ui.Window.Close() }
}

Test-Case 'orphan: renaming a combination onto that name does not wipe the shortcut' {
    # Тот же путь с другой стороны: у комбинации своей клавиши нет, а у имени, в
    # которое её переименовали, — есть. Пустое поле редактора не должно её снять.
    $settings = New-OrphanSettings
    $settings.hotkeys.Remove('combo:Movie')
    $settings.combos['Work'] = [ordered]@{ displays = @('LG ULTRAGEAR'); primary = '' }
    $settings.hotkeys['combo:Movie'] = 'Ctrl+Alt+F4'
    $ui = New-DialogUi -Settings $settings
    try {
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        $ed = New-ModeEditorWindow -Mode $mode -Combo $ui.Combos[0] -State $ui.State `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark $false
        try {
            Assert-Equal $script:NoHotkeyText $ed.HotkeyBox.Text 'Work has no shortcut of its own'
            $ed.NameBox.Text = 'Movie'
            Assert-Equal 'Ctrl+Alt+F4' $ed.HotkeyBox.Text 'the shortcut of the name it moves into is shown'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True $got.Ok 'accepted'
            Set-UiMode -Ui $ui -Mode $mode -Combo $ui.Combos[0] -Edited $got.Mode
        }
        finally { $ed.Window.Close() }

        $updated = (Read-SettingsFromUi -Ui $ui -Settings $settings).Settings
        Assert-Equal 'Ctrl+Alt+F4' $updated.hotkeys['combo:Movie'] 'and it is still there after Save'
        Assert-True (-not $updated.hotkeys.Contains('combo:Work')) 'nothing left under the old name'
    }
    finally { $ui.Window.Close() }
}
