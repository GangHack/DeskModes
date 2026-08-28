# --- всплывашки и первый запуск ---------------------------------------------
# Выключенные уведомления глушат фоновые сообщения — и однажды заглушили ответ на
# нажатие: «About ScreenDeck» нажат, и не происходит ничего. Развилка (switch
# -Always) — чистая логика, и проверять её на живом столе незачем.
#
# Первый запуск человек видит ровно один раз, и живьём его не повторить, не удалив
# настройки, — а это единственный путь, который никто не переоткрывает руками.
#
# И Show-Balloon, и тело таймера старта достаём из Displays.ps1 разбором файла:
# дот-сорснуть точку входа нельзя, она поднимает всё приложение, а копия кода в
# тесте разошлась бы с оригиналом (тот же приём, что в 16-restore-on-start).

Write-Host ''
Write-Host 'the balloons and the first run' -ForegroundColor White

# ToolTipIcon — из WinForms: Show-Balloon достаёт из него значок по имени вида.
Add-Type -AssemblyName System.Windows.Forms

$script:TrayAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'Displays.ps1'), [ref]$null, [ref]$null)

$balloon = @($script:TrayAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq 'Show-Balloon' }, $true))
if ($balloon.Count -ne 1) { throw "expected exactly one Show-Balloon in Displays.ps1, found $($balloon.Count)" }
. ([scriptblock]::Create($balloon[0].Extent.Text))

# Тело таймера старта — не функция, а блок, отданный в .add_Tick(). Берём именно
# тик StartupTimer: тиков в файле четыре, и остальные три про другое.
$startupTick = @($script:TrayAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $n.Member.Extent.Text -eq 'add_Tick' }, $true) |
    Where-Object { $_.Expression.Extent.Text -match 'StartupTimer' })
if ($startupTick.Count -ne 1) { throw "expected exactly one StartupTimer tick in Displays.ps1, found $($startupTick.Count)" }
# .EndBlock, а не сам блок: Extent блока — это «{ … }» вместе со скобками, и
# Create собрал бы из него не тело, а литерал скриптблока.
$script:StartupTick = [scriptblock]::Create($startupTick[0].Arguments[0].ScriptBlock.EndBlock.Extent.Text)

# --- окружение, которое эти два куска ожидают вокруг себя --------------------

# Значок трея. Не настоящий NotifyIcon: видимый показал бы всплывашку поверх
# чужого экрана, а невидимый бросил бы исключение на ShowBalloonTip.
$script:tray = New-Object psobject -Property @{
    BalloonTipIcon = $null; BalloonTipTitle = ''; BalloonTipText = ''; Shown = 0
}
$script:tray | Add-Member -MemberType ScriptMethod -Name ShowBalloonTip -Value { $this.Shown++ }

$script:AppName = 'ScreenDeck'
$script:TimerStopped = $false
$script:SettingsOpened = $false
$script:StartupTimer = New-Object psobject
$script:StartupTimer | Add-Member -MemberType ScriptMethod -Name Stop -Value { $script:TimerStopped = $true }

# Соседи тика: сам возврат режима проверен в 16-restore-on-start, здесь он только
# не должен мешать.
function Invoke-StartupRestore { }
function Open-SettingsWindow { $script:SettingsOpened = $true }
function Optimize-TrayMemory { }

function Set-BalloonScene {
    param([bool]$Notifications)
    $s = Get-DefaultSettings
    $s.notifications = $Notifications
    $script:Settings = $s
    $script:tray.Shown = 0
    $script:tray.BalloonTipTitle = ''
}

function Invoke-StartupTick {
    param([bool]$First)
    Set-BalloonScene -Notifications $true
    $script:SettingsOpened = $false
    $script:TimerStopped = $false
    $script:FirstRun = $First
    & $script:StartupTick
}

# --- что глушится, а что нет ------------------------------------------------

Test-Case 'balloon: a background message is silent when notifications are off' {
    Set-BalloonScene -Notifications $false
    Show-Balloon 'Displays switched' 'Both work displays are up.'
    Assert-Equal 0 $script:tray.Shown 'nothing is shown'
}

Test-Case 'balloon: the same message speaks when notifications are on' {
    Set-BalloonScene -Notifications $true
    Show-Balloon 'Displays switched' 'Both work displays are up.'
    Assert-Equal 1 $script:tray.Shown 'shown once'
    Assert-Equal 'Displays switched' $script:tray.BalloonTipTitle 'with its own title'
}

Test-Case 'balloon: an answer to a press speaks even with notifications off' {
    Set-BalloonScene -Notifications $false
    Show-Balloon 'ScreenDeck' 'ScreenDeck 1.0.0 - Windows 26200, PowerShell 5.1' -Always
    Assert-Equal 1 $script:tray.Shown 'a press always answers'
}

Test-Case 'balloon: a failure is never silenced' {
    Set-BalloonScene -Notifications $false
    Show-Balloon 'Failed' 'Windows refused the configuration.' 'Error'
    Assert-Equal 1 $script:tray.Shown 'shown'
}

Test-Case 'balloon: -Always is a licence for that one message, not for the rest' {
    # Если условие перевернуть, обычные «переключено» полезут при выключенных
    # уведомлениях — а это ровно то, что человек и выключал.
    Set-BalloonScene -Notifications $false
    Show-Balloon 'Displays switched' 'Both work displays are up.'
    Show-Balloon 'ScreenDeck' 'ScreenDeck 1.0.0' -Always
    Show-Balloon 'Displays switched' 'Both work displays are up.'
    Assert-Equal 1 $script:tray.Shown 'only the answer to the press got through'
}

# Правило, а не пример: «нажал, и ничего не произошло» в коде не видно, и один раз
# так и уехало. Смотрим все Show-Balloon прямо в обработчиках add_Click — у каждого
# обязан быть -Always или свой Kind, который не глушится.
Test-Case 'balloon: no answer to a menu click can be silenced' {
    $handlers = @($script:TrayAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member.Extent.Text -eq 'add_Click' }, $true))
    Assert-True ($handlers.Count -gt 0) 'the menu has click handlers at all'

    $silent = @()
    foreach ($h in $handlers) {
        $calls = @($h.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Show-Balloon' }, $true))
        foreach ($c in $calls) {
            if ($c.Extent.Text -notmatch '-Always' -and $c.Extent.Text -notmatch "'(Warning|Error)'") {
                $silent += $c.Extent.Text
            }
        }
    }
    Assert-Equal 0 $silent.Count ('silenced answers: ' + ($silent -join ' | '))
}

# --- первый запуск ----------------------------------------------------------

Test-Case 'startup: the welcome belongs to the run that had to create the settings' {
    # Признак — ОТСУТСТВИЕ файла настроек: пустой список клавиш им не является,
    # иначе человек, снявший все привязки, получал бы приглашение каждый раз.
    Assert-True ($script:TrayAst.Extent.Text -match '(?m)^\$script:FirstRun\s*=\s*\$false') 'the flag is off by default'

    $ifs = @($script:TrayAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))
    $creates = @($ifs | Where-Object { $_.Clauses[0].Item1.Extent.Text -match 'Test-Path \$script:SettingsFile' })
    Assert-Equal 1 $creates.Count 'one block decides that this is a first run'
    if ($creates.Count -eq 1) {
        Assert-True ($creates[0].Extent.Text -match '\$script:FirstRun\s*=\s*\$true') 'and it is the one that raises the flag'
    }
}

Test-Case 'startup: the first run says where the menu is and opens Settings itself' {
    # Приглашение показывается из таймера старта, когда цикл сообщений уже
    # крутится: до него всплывашка не появляется вовсе, а окно настроек встало бы
    # поперёк старта. Поэтому тик и гоняется целиком, а не читается глазами.
    Invoke-StartupTick -First $true
    Assert-True $script:TimerStopped 'the one-shot timer stopped itself'
    Assert-Equal 1 $script:tray.Shown 'one balloon'
    Assert-True ($script:tray.BalloonTipText -like '*Right-click*') 'which says where the menu is'
    Assert-True $script:SettingsOpened 'and the window opened by itself'
}

Test-Case 'startup: every later start is silent' {
    # Окно настроек, открывающееся на каждом входе в Windows, — это то, за что
    # инструмент удаляют.
    Invoke-StartupTick -First $false
    Assert-Equal 0 $script:tray.Shown 'no welcome'
    Assert-True (-not $script:SettingsOpened) 'no window'
    Assert-True $script:TimerStopped 'the timer still stops'
}

Test-Case 'startup: a Settings window that will not open does not take the start down' {
    # Всё, что трей делает на старте, идёт до Application.Run: исключение отсюда —
    # это значок, который не появился вообще.
    function Open-SettingsWindow { throw 'no display device' }
    Invoke-StartupTick -First $true
    Assert-Equal 1 $script:tray.Shown 'the balloon still went out'
    Assert-True $script:TimerStopped 'and the start finished'
}
