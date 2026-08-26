# --- окно таймера -----------------------------------------------------------
# Собирается без показа, как и окно настроек: обработчики поля и ползунка — это и
# есть вся работа окна, и они срабатывают от простого присваивания.

Write-Host ''
Write-Host 'the timer window' -ForegroundColor White

Test-Case 'timer window: opens on the value it was given' {
    $ui = New-TimerWindow -Action 'sleep' -Minutes 90
    try {
        Assert-Equal 90 $ui.Minutes 'the value it opened with'
        Assert-Equal '1 h 30 min' $ui.ValueBox.Text 'the field'
        Assert-Equal 90 (Get-TimerStepMinutes -Index ([int]$ui.Dial.Value)) 'the slider'
        Assert-True $ui.StartBtn.IsEnabled 'the button is ready'
        Assert-True ($ui.TargetText.Text -like 'at *') 'it says when that is'
    }
    finally { $ui.Window.Close(); $script:ActiveTimerUi = $null }
}

Test-Case 'timer window: typing moves the slider, the slider rewrites the field' {
    $ui = New-TimerWindow -Action 'shutdown' -Minutes 45
    try {
        $ui.ValueBox.Text = '1h30'
        Assert-Equal 90 $ui.Minutes 'what was typed'
        Assert-Equal '1h30' $ui.ValueBox.Text 'the text is left as typed'
        Assert-Equal 90 (Get-TimerStepMinutes -Index ([int]$ui.Dial.Value)) 'the slider followed'

        $ui.Dial.Value = Get-TimerStepIndex -Minutes 120
        Assert-Equal 120 $ui.Minutes 'what the slider says'
        Assert-Equal '2 h' $ui.ValueBox.Text 'and the field says the same'
    }
    finally { $ui.Window.Close(); $script:ActiveTimerUi = $null }
}

Test-Case 'timer window: the button hands the value back, Enter and Esc reach it' {
    $ui = New-TimerWindow -Action 'sleep' -Minutes 45
    try {
        # Клавиатурный уговор окна: Enter — на кнопку, Esc — на отмену. Проверяем
        # его на самих кнопках: нажатия в непоказанном окне взять негде.
        Assert-True $ui.StartBtn.IsDefault 'Enter goes to the button'
        Assert-True $ui.CancelBtn.IsCancel 'Esc cancels'

        $ui.ValueBox.Text = '2h'
        # Обработчик кнопки кладёт значение и закрывает окно. Закрыть непоказанное
        # окно нельзя (WPF отвечает отказом на DialogResult) — значение к этому
        # моменту уже отдано, и проверяем именно его.
        try { $ui.StartBtn.RaiseEvent(
                (New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        catch { }
        Assert-Equal 120 $ui.Result 'the minutes it hands back'
    }
    finally { $ui.Window.Close(); $script:ActiveTimerUi = $null }
}

Test-Case 'timer window: nothing is armed on what we cannot read' {
    $ui = New-TimerWindow -Action 'sleep' -Minutes 45
    try {
        $ui.ValueBox.Text = 'soon'
        Assert-Equal 0 $ui.Minutes 'no value'
        Assert-True (-not $ui.StartBtn.IsEnabled) 'the button is off'
        Assert-True ($ui.TargetText.Text -like '*1h30*') 'and it says what we do read'

        # Потолок — те же двенадцать часов, что и последняя ступень ползунка.
        $ui.ValueBox.Text = '20h'
        Assert-Equal 0 $ui.Minutes 'beyond the ceiling is not a value either'

        $ui.ValueBox.Text = '20'
        Assert-Equal 20 $ui.Minutes 'and it comes back to life'
        Assert-True $ui.StartBtn.IsEnabled 'with the button back on'
    }
    finally { $ui.Window.Close(); $script:ActiveTimerUi = $null }
}
