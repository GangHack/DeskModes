<#
    SettingsDialog.ps1 — окно настроек Multi-Monitor Tool.

    Вынесено из Displays.ps1 отдельным файлом, чтобы окно можно было собрать и
    проверить в изоляции: в трее исключение при построении формы видно только как
    системное окно с ошибкой, без подробностей.

        New-SettingsForm     собрать форму, вернуть её и элементы (проверяемо)
        Show-SettingsDialog  показать и вернуть изменённые настройки или $null
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-SettingsForm {
    param(
        $Modes,
        $Settings,
        [System.Drawing.Icon]$Icon
    )

    $font = New-Object System.Drawing.Font 'Segoe UI', 9
    $grey = [System.Drawing.Color]::FromArgb(255, 110, 110, 110)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Multi-Monitor Tool - Settings'
    $form.Font = $font
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = [System.Drawing.Color]::White
    $form.AutoSize = $true
    $form.AutoSizeMode = 'GrowAndShrink'
    $form.Padding = New-Object System.Windows.Forms.Padding 18
    if ($Icon) { $form.Icon = $Icon }

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.AutoSize = $true
    $root.AutoSizeMode = 'GrowAndShrink'
    $root.ColumnCount = 1
    $root.GrowStyle = 'AddRows'
    $root.Location = New-Object System.Drawing.Point 18, 18
    [void]$form.Controls.Add($root)

    $heading = New-Object System.Windows.Forms.Label
    $heading.Text = 'Keyboard shortcuts'
    $heading.Font = New-Object System.Drawing.Font 'Segoe UI Semibold', 10
    $heading.AutoSize = $true
    $heading.Margin = New-Object System.Windows.Forms.Padding 0, 0, 0, 4
    [void]$root.Controls.Add($heading)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "Click a box and press the combination you want." + [Environment]::NewLine +
                 "It needs Ctrl, Alt, Shift or Win. Backspace clears it."
    $hint.ForeColor = $grey
    $hint.AutoSize = $true
    $hint.Margin = New-Object System.Windows.Forms.Padding 0, 0, 0, 12
    [void]$root.Controls.Add($hint)

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.AutoSize = $true
    $grid.AutoSizeMode = 'GrowAndShrink'
    $grid.ColumnCount = 2
    $grid.GrowStyle = 'AddRows'
    $grid.Margin = New-Object System.Windows.Forms.Padding 0, 0, 0, 16
    [void]$root.Controls.Add($grid)

    # Именно [ordered]: из этого словаря Show-SettingsDialog собирает hotkeys для
    # записи на диск, а обычный @{} перечисляется в непредсказуемом порядке — и
    # каждый Save переставлял привязки в settings.json местами. Файл под git, и
    # такая перетасовка выглядела в diff'е изменением, которого никто не делал.
    $boxes = [ordered]@{}
    foreach ($mode in $Modes) {
        $label = New-Object System.Windows.Forms.Label
        $label.AutoSize = $true
        # 'Left', не 'West': у AnchorStyles нет сторон компаса. Именно на этом
        # окно настроек падало с системной ошибкой.
        $label.Anchor = 'Left'
        $label.Margin = New-Object System.Windows.Forms.Padding 0, 7, 20, 7
        $label.Text = $mode.Title
        if (-not $mode.Available) {
            $label.Text = $mode.Title + '   (not connected)'
            $label.ForeColor = $grey
        }
        [void]$grid.Controls.Add($label)

        $box = New-Object System.Windows.Forms.TextBox
        $box.Width = 170
        $box.ReadOnly = $true
        $box.BackColor = [System.Drawing.Color]::FromArgb(255, 247, 248, 250)
        $box.TextAlign = 'Center'
        $box.Cursor = [System.Windows.Forms.Cursors]::Hand
        $box.Margin = New-Object System.Windows.Forms.Padding 0, 4, 0, 4
        $box.Tag = $mode.Key

        $existing = $null
        if ($Settings.hotkeys.Contains($mode.Key)) { $existing = $Settings.hotkeys[$mode.Key] }
        if ($existing) { $box.Text = $existing } else { $box.Text = '(none)' }

        # Комбинацию ловим на KeyDown: там видны и модификаторы, и сама клавиша.
        $box.add_KeyDown({
            param($sender, $e)
            $e.SuppressKeyPress = $true

            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Back -or
                $e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
                $sender.Text = '(none)'
                return
            }
            # Одни модификаторы — ещё не комбинация, ждём основную клавишу.
            $bare = @([System.Windows.Forms.Keys]::ControlKey, [System.Windows.Forms.Keys]::Menu,
                      [System.Windows.Forms.Keys]::ShiftKey, [System.Windows.Forms.Keys]::LWin,
                      [System.Windows.Forms.Keys]::RWin)
            if ($bare -contains $e.KeyCode) { return }

            $mods = 0
            if ($e.Control) { $mods = $mods -bor 0x2 }
            if ($e.Alt)     { $mods = $mods -bor 0x1 }
            if ($e.Shift)   { $mods = $mods -bor 0x4 }
            if ($mods -eq 0) {
                $sender.Text = 'needs Ctrl / Alt / Shift'
                return
            }

            $text = Format-HotkeyString $mods ([int]$e.KeyCode)
            if (ConvertFrom-HotkeyString $text) { $sender.Text = $text }
            else { $sender.Text = 'unsupported key' }
        })
        [void]$grid.Controls.Add($box)
        $boxes[$mode.Key] = $box
    }

    $startupBox = New-Object System.Windows.Forms.CheckBox
    $startupBox.Text = 'Start with Windows'
    $startupBox.AutoSize = $true
    $startupBox.Margin = New-Object System.Windows.Forms.Padding 0, 3, 0, 3
    [void]$root.Controls.Add($startupBox)

    $refreshBox = New-Object System.Windows.Forms.CheckBox
    $refreshBox.Text = 'Restore each display to its maximum refresh rate'
    $refreshBox.AutoSize = $true
    $refreshBox.Margin = New-Object System.Windows.Forms.Padding 0, 3, 0, 3
    $refreshBox.Checked = [bool]$Settings.maximizeRefresh
    [void]$root.Controls.Add($refreshBox)

    $notifyBox = New-Object System.Windows.Forms.CheckBox
    $notifyBox.Text = 'Show a notification after switching'
    $notifyBox.AutoSize = $true
    $notifyBox.Margin = New-Object System.Windows.Forms.Padding 0, 3, 0, 3
    $notifyBox.Checked = [bool]$Settings.notifications
    [void]$root.Controls.Add($notifyBox)

    $windowsBox = New-Object System.Windows.Forms.CheckBox
    $windowsBox.Text = 'Remember window positions per display layout'
    $windowsBox.AutoSize = $true
    $windowsBox.Margin = New-Object System.Windows.Forms.Padding 0, 3, 0, 3
    # Значение по умолчанию — включено, поэтому отсутствие поля читается как $true,
    # а не как «выключено»: у старого settings.json этого ключа нет.
    $windowsBox.Checked = ($null -eq $Settings.restoreWindows -or [bool]$Settings.restoreWindows)
    [void]$root.Controls.Add($windowsBox)

    $lastModeBox = New-Object System.Windows.Forms.CheckBox
    $lastModeBox.Text = 'Restore the last mode after turning the computer on'
    $lastModeBox.AutoSize = $true
    $lastModeBox.Margin = New-Object System.Windows.Forms.Padding 0, 3, 0, 18
    # Как и у соседа: ключа в старом settings.json нет, и его отсутствие означает
    # «по умолчанию», то есть включено.
    $lastModeBox.Checked = ($null -eq $Settings.restoreLastMode -or [bool]$Settings.restoreLastMode)
    [void]$root.Controls.Add($lastModeBox)

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.FlowDirection = 'RightToLeft'
    $buttons.AutoSize = $true
    $buttons.AutoSizeMode = 'GrowAndShrink'
    $buttons.Anchor = 'Right'
    $buttons.Margin = New-Object System.Windows.Forms.Padding 0
    [void]$root.Controls.Add($buttons)

    $save = New-Object System.Windows.Forms.Button
    $save.Text = 'Save'
    $save.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $save.Size = New-Object System.Drawing.Size 92, 30
    [void]$buttons.Controls.Add($save)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Size = New-Object System.Drawing.Size 92, 30
    $cancel.Margin = New-Object System.Windows.Forms.Padding 10, 0, 0, 0
    [void]$buttons.Controls.Add($cancel)

    $form.AcceptButton = $save
    $form.CancelButton = $cancel

    return [pscustomobject]@{
        Form        = $form
        Boxes       = $boxes
        StartupBox  = $startupBox
        RefreshBox  = $refreshBox
        NotifyBox   = $notifyBox
        WindowsBox  = $windowsBox
        LastModeBox = $lastModeBox
    }
}

# Возвращает изменённые настройки, либо $null если отменили или ввод не принят.
function Show-SettingsDialog {
    param(
        $State,
        $Settings,
        [System.Drawing.Icon]$Icon
    )

    # Страховка: если настройки не доехали, читаем их с диска, а не падаем на
    # обращении к $null. Именно так это и сломалось в первый раз.
    if (-not $Settings -or -not $Settings.hotkeys) {
        Write-DisplayLog 'settings dialog: settings arrived empty, reading them from disk'
        $Settings = Get-DisplaySettings
    }

    $modes = @(Get-DisplayModes $State)

    # Привязки к мониторам, которых сейчас нет в системе, тоже показываем строкой.
    # Иначе получалось глухо: клавиша занята глобально (RegisterHotKey работает
    # независимо от наличия монитора), а увидеть её или снять из окна нельзя —
    # строки для неё просто нет. Заодно попадает в проверку на дубликаты.
    $known = @($modes | ForEach-Object { $_.Key })
    foreach ($key in @($Settings.hotkeys.Keys)) {
        if ($known -contains $key) { continue }
        $modes += [pscustomobject]@{
            Key       = $key
            Title     = Get-ModeTitleFromKey $key
            Kind      = 'orphan'
            Available = $false
        }
    }

    $ui = New-SettingsForm -Modes $modes -Settings $Settings -Icon $Icon

    # Галочку автозагрузки читаем из факта наличия ярлыка, а не из настроек:
    # ярлык могли удалить руками.
    $ui.StartupBox.Checked = (Test-RunAtStartup)

    try {
        if ($ui.Form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

        # Привязки для мониторов, которых сейчас нет в системе, сохраняются сами:
        # для каждого такого ключа выше создаётся строка-сирота, а значит и поле
        # ввода. Раньше здесь стоял ещё и цикл «добавить ключи без поля» — он не
        # мог сработать ни разу и остался от первой попытки решить ту же задачу.
        $newHotkeys = [ordered]@{}

        $seen = @{}
        foreach ($key in $ui.Boxes.Keys) {
            $parsed = ConvertFrom-HotkeyString $ui.Boxes[$key].Text
            if (-not $parsed) { continue }
            if ($seen.ContainsKey($parsed.Text)) {
                Write-DisplayLog "settings dialog: rejected save - $($parsed.Text) is assigned to both $($seen[$parsed.Text]) and $key"
                [System.Windows.Forms.MessageBox]::Show(
                    "$($parsed.Text) is assigned twice. Each combination can only drive one mode.",
                    'Multi-Monitor Tool', 'OK', 'Warning') | Out-Null
                return $null
            }
            $seen[$parsed.Text] = $key
            $newHotkeys[$key] = $parsed.Text
        }

        # Сохраняем в КОПИЮ, а не в переданный объект. $Settings — это тот же
        # словарь, с которым живёт трей; при правке на месте неудачная запись на
        # диск оставляла три разные версии настроек: изменённую в памяти, старую
        # на диске и старую же в зарегистрированных клавишах.
        $updated = Get-DefaultSettings
        $updated.hotkeys = $newHotkeys
        $updated.maximizeRefresh = $ui.RefreshBox.Checked
        $updated.notifications = $ui.NotifyBox.Checked
        $updated.restoreWindows = $ui.WindowsBox.Checked
        $updated.restoreLastMode = $ui.LastModeBox.Checked

        # Окно правит только то, что в нём есть; остальные поля обязаны проехать
        # насквозь. Начинали с Get-DefaultSettings — значит всё, чего в форме нет,
        # уезжало на диск ДЕФОЛТНЫМ. Первый же Save стирал layout (@()) и primary
        # (''): мониторы снова вставали как попало, панель задач ездила.
        #
        # Переносим не список «не забыть layout и primary», а всё, кроме полей с
        # элементами формы. Иначе каждая новая настройка без своего элемента
        # (autoGame, audio) заводила бы этот баг заново, и заметить это можно было
        # бы только по развалившейся раскладке.
        $fromForm = @('hotkeys', 'maximizeRefresh', 'notifications', 'restoreWindows', 'restoreLastMode')
        foreach ($k in @($Settings.Keys)) {
            if ($fromForm -contains $k) { continue }
            $updated[$k] = $Settings[$k]
        }
        # У этих двух тип важен: они приезжают из JSON и уезжают в него обратно.
        $updated.layout  = @($Settings.layout | ForEach-Object { [string]$_ })
        $updated.primary = [string]$Settings.primary

        Save-DisplaySettings $updated
        Set-RunAtStartup $ui.StartupBox.Checked
        return $updated
    }
    finally {
        $ui.Form.Dispose()
    }
}
