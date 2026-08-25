<#
.SYNOPSIS
    ScreenDeck: the tray icon that switches the displays on your desk.

.DESCRIPTION
    Runs until you pick Exit. Right-click the icon for a menu with the current
    state of every display and the modes you can switch to; the shortcuts are
    registered by this process itself (RegisterHotKey), so they work whether or not
    Explorer picked up any Start-menu shortcuts, and they are edited in the
    Settings window rather than in the code.

    Also watches the desk while it runs: it puts back a refresh rate Windows
    silently dropped, rebuilds the desk after sleep or a hotplug, applies your
    rules, keeps the diary, and runs the shutdown timer.

    Start it with Displays.cmd to leave no console window behind. Only one instance
    runs at a time - a second one would find every shortcut already taken.

.PARAMETER NoHotkeys
    Do not register global shortcuts. For running a second copy alongside the real
    one while poking at the menu or the Settings window.

.EXAMPLE
    .\Displays.cmd
    The normal way in: starts the tray icon with no console window.

.EXAMPLE
    powershell -File .\Displays.ps1 -NoHotkeys
    Starts a copy that claims no shortcuts, so it can coexist with a running one.

.LINK
    README.md
#>
# Интерфейс и журнал английские, комментарии русские — см. docs/notes.ru.md.
[CmdletBinding()]
param([switch]$NoHotkeys)

$ErrorActionPreference = 'Stop'

# Заводим до всего остального: в это время попадает и компиляция (или загрузка из
# кэша) нативных типов, и сборка формы, и первый опрос состояния. Итог уходит в
# журнал строкой «tray: started in N ms» — постоянный контроль того, как быстро
# клавиши становятся рабочими после входа в Windows.
$script:StartWatch = [System.Diagnostics.Stopwatch]::StartNew()

. (Join-Path $PSScriptRoot 'DisplayCore.ps1')
. (Join-Path $PSScriptRoot 'WindowLayout.ps1')
. (Join-Path $PSScriptRoot 'Activity.ps1')
. (Join-Path $PSScriptRoot 'SettingsDialog.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppName = 'ScreenDeck'

# Один экземпляр: иначе горячие клавиши займёт только первый, а второй провисит
# бесполезным значком.
$script:AppMutex = New-Object System.Threading.Mutex($false, 'Local\ScreenDeckTray')
if (-not $script:AppMutex.WaitOne(0)) {
    [System.Windows.Forms.MessageBox]::Show(
        "$script:AppName is already running - look for its icon in the notification area.",
        $script:AppName, 'OK', 'Information') | Out-Null
    return
}

$script:Settings = Get-DisplaySettings

# Доступ к настройкам только через эти функции. Обработчики событий создаются
# через .GetNewClosure() внутри других блоков, и обращение вида $script:Settings
# внутри них разрешается не в переменную скрипта, а в пустоту — окно настроек
# из-за этого получало $null и падало. Функция же всегда исполняется в области
# скрипта, независимо от того, откуда её вызвали.
function Get-ActiveSettings {
    if (-not $script:Settings) { $script:Settings = Get-DisplaySettings }
    return $script:Settings
}

function Set-ActiveSettings {
    param($NewSettings)
    $script:Settings = $NewSettings
}

# --- кэш состояния ----------------------------------------------------------
# Меню обязано открываться мгновенно. Медленный опрос прямо в обработчике Opening
# ломает штатный правый клик по значку: Windows решает, что меню не показалось, и
# закрывает его. Опрос через CCD стоит десятки миллисекунд, но кэш всё равно нужен
# — меню открывается без единого запроса к системе, а обновляется он по событию о
# смене конфигурации.

$script:StateCache = $null

function Update-StateCache {
    try {
        $script:StateCache = @(Get-DisplayState)
        # Кто ПОДКЛЮЧЁН (а не включён): по изменению этого набора видно, что
        # монитор воткнули или выдернули, и только на это стоит реагировать —
        # включённые меняем мы сами на каждом переключении (см. Get-ReapplyDecision).
        $script:PresentIds = @($script:StateCache | Where-Object { -not $_.Disconnected } |
                               ForEach-Object { [string]$_.Id } | Sort-Object)
    }
    catch {
        Write-DisplayLog "cache: could not refresh display state - $($_.Exception.Message)"
    }
}

# Имя выхода -> название монитора, для дневника: он получает от системы
# «\\.\DISPLAY1», а человеку нужно «LG ULTRAGEAR».
function Get-DisplayNameMap {
    $map = @{}
    foreach ($m in @(Get-CachedState)) {
        if ($m.Active -and $m.Output) { $map[[string]$m.Output] = [string]$m.Label }
    }
    return $map
}

# Ключ режима, в котором стол находится сейчас, или пустая строка. Нужен и
# правилам, и дневнику; состояние берётся из кэша, диск не читается.
function Get-CurrentModeKey {
    $state = Get-CachedState
    if (-not $state) { return '' }
    $key = Get-ActiveModeKey -State $state -Modes @(Get-DisplayModes -State $state -Settings (Get-ActiveSettings))
    return [string]$key
}

function Get-CachedState {
    if ($null -eq $script:StateCache) { Update-StateCache }
    return $script:StateCache
}

# Возврат частоты после того, как её сбросила система. Отдельной функцией, а не
# кодом внутри обработчика: обработчик — блок, а $script: внутри блоков,
# созданных через .GetNewClosure(), не разрешается (см. Get-ActiveSettings).
function Invoke-ModeWatch {
    if (-not (Get-ActiveSettings).maximizeRefresh) { return }
    try {
        $fixed = @(Restore-BestModes)
        if ($fixed.Count -gt 0) {
            Update-StateCache
            Show-Balloon 'Refresh rate restored' (($fixed -join ', ') + ' - Windows had dropped it.')
        }
    }
    catch {
        Write-DisplayLog "watch: failed - $($_.Exception.Message)"
    }
}

# --- правила ----------------------------------------------------------------
# «Случилось это — стань таким»: вся логика в Get-RuleDecision (DisplayCore.ps1),
# чистой функцией и под тестами. Здесь только сбор фактов и исполнение решения.
#
# Опрос живёт в уже существующем 15-секундном таймере трея: своего не надо, а
# Get-Process стоит единицы миллисекунд.
#
# «Переключались мы» помнится отдельно от текущего режима. Иначе после ручного
# переключения во время игры выход из неё уносил бы экраны туда, где человек их
# видеть не просил.

$script:RuleOwnedIndex = -1
$script:RuleOwnedBack = ''
# Последняя жалоба «возвращаться будет некуда»: без этого она уходила бы в журнал
# каждые пятнадцать секунд, пока игра открыта.
$script:RuleLastBlocked = ''

function Reset-RuleOwnership {
    $script:RuleOwnedIndex = -1
    $script:RuleOwnedBack = ''
}

function Invoke-RulesCheck {
    $rules = @((Get-ActiveSettings).rules)
    if ($rules.Count -eq 0) { return }

    # Процессы спрашиваем ОДНИМ вызовом на все правила: Get-Process без имени
    # стоит столько же, сколько с именем, а правил может быть десяток.
    $needProcesses = $false
    foreach ($r in $rules) { if ([string]$r.when -eq 'process') { $needProcesses = $true; break } }
    $processes = @()
    if ($needProcesses) {
        $processes = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName })
    }

    $facts = [pscustomobject]@{
        Processes   = $processes
        IdleSeconds = $(try { [NativeActivity]::IdleSeconds() } catch { 0 })
    }

    $decision = Get-RuleDecision -Rules $rules -Facts $facts -CurrentMode (Get-CurrentModeKey) `
                                 -OwnedIndex $script:RuleOwnedIndex -OwnedBack $script:RuleOwnedBack

    switch ($decision.Action) {
        'switch' {
            $script:RuleOwnedIndex = [int]$decision.RuleIndex
            $script:RuleOwnedBack = [string]$decision.Back
            $script:RuleLastBlocked = ''
            Write-DisplayLog ("rule: {0} -> {1}" -f $decision.Reason, $decision.Mode)
            Invoke-Mode $decision.Mode -Auto
        }
        'return' {
            Reset-RuleOwnership
            if ($decision.Mode) {
                Write-DisplayLog ("rule: {0} -> back to {1}" -f $decision.Reason, $decision.Mode)
                Invoke-Mode $decision.Mode -Auto
            }
        }
        'release' {
            Write-DisplayLog ('rule: {0}, letting go' -f $decision.Reason)
            Reset-RuleOwnership
        }
        'blocked' {
            $note = '{0}|{1}' -f $decision.Mode, $decision.Reason
            if ($note -ne $script:RuleLastBlocked) {
                Write-DisplayLog ("rule: not switching to {0} - {1}" -f $decision.Mode, $decision.Reason)
                $script:RuleLastBlocked = $note
            }
        }
    }
}

# --- значок -----------------------------------------------------------------
# Один файл app.ico на всё: трей, ярлыки в Пуске и в автозагрузке. Своя иконка, а
# не системная: в Пуске она не должна сливаться со значками Windows.
# Размер берём тот, который система просит для мелких значков (при масштабе
# 150% это уже не 16 px), и .ico отдаёт подходящую из девяти заготовленных —
# растянутая из одной выглядела бы мылом. Перерисовать: .\Make-Icon.ps1

$script:IconFile = Join-Path $PSScriptRoot 'app.ico'

function New-TrayIcon {
    if (Test-Path $script:IconFile) {
        try {
            return New-Object System.Drawing.Icon ($script:IconFile, [System.Windows.Forms.SystemInformation]::SmallIconSize)
        }
        catch {
            Write-DisplayLog "tray: could not load app.ico - $($_.Exception.Message)"
        }
    }
    else {
        Write-DisplayLog 'tray: app.ico is missing, falling back to the system icon'
    }
    return [System.Drawing.SystemIcons]::Application
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$tray.Text = $script:AppName
$tray.Visible = $true

# --- оформление меню --------------------------------------------------------
# Рисует ModernMenuRenderer (DisplayCore.ps1): плоский фон под системную тему,
# скруглённая подсветка, галочка в цвет акцента. Штатный System-отрисовщик застрял
# в Windows 7, и меню с ним выглядит как из XP.

# Шрифты меню, с кэшем. Segoe UI Variable появился в Windows 11; на Windows 10
# его нет, а GDI+ при неизвестном имени молча подставляет Microsoft Sans Serif —
# поэтому наличие семейства проверяется по списку установленных.
$script:UiFonts = @{}

function Get-UiFont {
    param([single]$Size = 9.75, [switch]$Semibold)

    $key = '{0}|{1}' -f $Size, [bool]$Semibold
    if ($script:UiFonts.Contains($key)) { return $script:UiFonts[$key] }

    $names = $(if ($Semibold) { @('Segoe UI Variable Text Semibold', 'Segoe UI Semibold') }
               else           { @('Segoe UI Variable Text', 'Segoe UI') })
    $installed = [System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name }
    $pick = 'Segoe UI'
    foreach ($name in $names) {
        if ($installed -contains $name) { $pick = $name; break }
    }

    $font = New-Object System.Drawing.Font $pick, $Size
    $script:UiFonts[$key] = $font
    return $font
}

# Точки состояния мониторов: зелёная — включён и на максимуме, янтарная — частота
# ниже максимальной, серая — выключен, контурная — не подключён. Текст говорит то
# же словами; точка отдаёт это одним взглядом. Рисуются по одной на вид и живут
# до конца процесса.
$script:StatusDots = @{}

function Get-StatusDot {
    param([string]$Kind)

    if ($script:StatusDots.Contains($Kind)) { return $script:StatusDots[$Kind] }

    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        switch ($Kind) {
            'on'    { $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(63, 185, 80))
                      $g.FillEllipse($b, 4.5, 4.5, 7.0, 7.0); $b.Dispose() }
            'below' { $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(210, 153, 34))
                      $g.FillEllipse($b, 4.5, 4.5, 7.0, 7.0); $b.Dispose() }
            'off'   { $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(138, 138, 138))
                      $g.FillEllipse($b, 4.5, 4.5, 7.0, 7.0); $b.Dispose() }
            default { $p = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(138, 138, 138)), 1.4
                      $g.DrawEllipse($p, 5.0, 5.0, 6.0, 6.0); $p.Dispose() }
        }
    }
    finally { $g.Dispose() }

    $script:StatusDots[$Kind] = $bmp
    return $bmp
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Font = Get-UiFont
$menu.ShowImageMargin = $true
$menu.ImageScalingSize = New-Object System.Drawing.Size 16, 16
$menu.Padding = New-Object System.Windows.Forms.Padding 4, 6, 4, 6
$tray.ContextMenuStrip = $menu

# Скруглить углы окна меню умеет только DWM (и только на Windows 11; на десятке
# вызов молча не сработает). Хэндл существует лишь у открытого меню — поэтому
# здесь, а не при создании.
$menu.add_Opened({
    try { [NativeTheme]::TryRoundCorners($menu.Handle, $true) } catch { }   # не Windows 11 — углы останутся прямыми
})

function Show-Balloon {
    param([string]$Title, [string]$Text, [string]$Kind = 'Info')
    if (-not $script:Settings.notifications -and $Kind -eq 'Info') { return }
    $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::$Kind
    $tray.BalloonTipTitle = $Title
    $tray.BalloonTipText = $Text
    $tray.ShowBalloonTip(4000)
}

# Было ли в этом запуске трея хоть одно переключение. Нужно возврату режима при
# старте: человек успевает нажать хоткей раньше, чем срабатывает наш таймер, и его
# выбор новее нашего.
$script:SwitchedOnce = $false

function Invoke-Mode {
    param([string]$Key, [switch]$Auto, [switch]$Silent)

    $script:SwitchedOnce = $true

    # Человек переключил сам — значит правило больше не хозяин положения и
    # возвращать ничего не должно. С людьми не воюем: если во время игры руками
    # выбрали другой набор экранов, это осознанное решение.
    if (-not $Auto) { Reset-RuleOwnership }

    $tray.Text = "$script:AppName - switching..."
    # Переключение состоялось. Не «нас попросили»: провал уходит исключением, а
    # занятый мьютекс — Skipped, и считать их за переключение нельзя (см. дневник
    # ниже). Зажатый хоткей давал очередь пропусков, и каждый попадал в отчёт.
    $switched = $false
    try {
        $keep = -not $script:Settings.maximizeRefresh
        $result = Switch-DisplayMode -ModeKey $Key -KeepMode:$keep -Quiet
        $switched = -not $result.Skipped
        if ($result.Skipped) {
            Show-Balloon 'Skipped' $result.Message 'Warning'
        }
        elseif ($result.Message -and $result.Ok) {
            # -Silent: набор экранов и так был правильный, чинили разве что
            # раскладку. Всплывашка «Displays switched» на каждом включении
            # компьютера сообщала бы о работе, которой не было.
            if (-not $Silent) { Show-Balloon 'Displays switched' $result.Message }
        }
        elseif ($result.Message) {
            # Частичный провал — тоже провал: монитор, который не поднялся, из
            # зелёной сводки выпадал бы молча.
            Show-Balloon 'Switched with problems' $result.Message 'Warning'
        }
        else {
            # Пустая сводка означает, что нужный монитор так и не прицепился.
            Show-Balloon 'Nothing came up' "None of that mode's displays responded. Check the cable and Deep Sleep Mode in the monitor's menu." 'Warning'
        }
    }
    catch {
        Show-Balloon 'Failed' $_.Exception.Message 'Error'
    }
    finally {
        Update-TrayText
        Update-StateCache
        # Дневник считает переключения — по ним видно, сколько раз в день человек
        # вообще трогает стол. Отдельным событием, потому что всё остальное в
        # дневнике — это суммы секунд. Только состоявшиеся: отчёт, в котором
        # переключений больше, чем их было, не отчёт.
        if ($switched -and (Get-ActiveSettings).stats) {
            try { Add-ActivitySwitch -Mode $Key } catch { }   # дневник не смеет мешать переключению
        }
    }
}

# --- возврат режима после включения компьютера ------------------------------
# Windows после включения поднимает свой набор экранов, а не тот, который был
# выбран перед выключением. Режим помнит Save-LastMode (DisplayCore.ps1), здесь мы
# его возвращаем.
#
# Почему не сравниваем текущий набор с запомненным и не выходим, если он совпал:
# Switch-DisplayMode сам пропускает то, что уже сделано — топология, раскладка и
# режимы проверяются по отдельности, поэтому вызов на уже правильном столе стоит
# 0.2-0.3 с и ничем не моргает. Зато лечится случай, когда экраны те же, а
# раскладка или основной монитор после загрузки разъехались: панель задач
# приезжала на другой монитор при том же наборе.
#
# Отдельной функцией, а не кодом в обработчике таймера: см. Get-ActiveSettings.

# Режим по ключу, если он сейчас достижим. $null означает, что ни одного его
# монитора на столе нет: гасить ради него остальные нельзя — останется чёрный
# экран, а это ровно та цена ошибки, из-за которой здесь проверка.
function Get-AvailableMode {
    param([string]$Key, $State)

    $mode = @(Get-DisplayModes -State $State -Settings (Get-ActiveSettings)) |
                Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if ($mode -and $mode.Available) { return $mode }
    return $null
}

function Invoke-StartupRestore {
    if (-not (Get-ActiveSettings).restoreLastMode) { return }

    if ($script:SwitchedOnce) {
        Write-DisplayLog 'startup: a mode was already chosen by hand, not restoring'
        return
    }

    $last = Get-LastMode
    if (-not $last) { return }

    # Тот же сеанс работы машины — значит трей просто перезапустили. Экраны в этом
    # случае не трогаем: набор мог сменить сам человек мимо приложения, через
    # Win+P или параметры Windows, и возвращать его назад мы не в праве.
    if ($last.Session -and $last.Session -eq (Get-SystemSessionId)) {
        Write-DisplayLog 'startup: same session as the last switch, leaving the displays alone'
        return
    }

    $state = Get-CachedState
    $mode = Get-AvailableMode -Key $last.Key -State $state
    if (-not $mode) {
        Write-DisplayLog ("startup: '{0}' is not available right now, leaving the displays as Windows set them" -f `
            (Get-ModeTitleFromKey $last.Key))
        return
    }

    Write-DisplayLog ("startup: restoring '{0}', chosen at {1}" -f $mode.Title, $last.When)
    Invoke-Mode $last.Key -Auto -Silent:(Test-DeskMatchesMode -Mode $mode -State $state)
}

# --- мир изменился сам ------------------------------------------------------
# Монитор воткнули или выдернули, компьютер вышел из сна — Windows в этих случаях
# расставляет экраны по своему усмотрению: раскладка разъезжается, панель задач
# уезжает, частота падает. Решение принимает Get-ReapplyDecision (чистая функция
# в DisplayCore.ps1, под тестами), здесь оно только исполняется.

function Invoke-ReapplyMode {
    param([string]$Key, [string]$Reason)

    if (-not $Key) { return }
    $state = Get-CachedState
    $mode = Get-AvailableMode -Key $Key -State $state
    if (-not $mode) {
        Write-DisplayLog ("reapply: '{0}' is not available right now, leaving the displays alone" -f `
            (Get-ModeTitleFromKey $Key))
        return
    }

    Write-DisplayLog ("reapply: {0} -> '{1}'" -f $Reason, $mode.Title)
    Invoke-Mode $Key -Auto -Silent:(Test-DeskMatchesMode -Mode $mode -State $state)
}

# Событие о смене конфигурации приходит и на наши собственные переключения,
# поэтому сравниваются ПОДКЛЮЧЁННЫЕ мониторы: их набор меняется только когда
# кабель воткнули или выдернули (или монитор погасили его собственной кнопкой).
function Invoke-PlugCheck {
    param($Before)

    $settings = Get-ActiveSettings
    $last = Get-LastMode
    $decision = Get-ReapplyDecision -Reapply $settings.reapply -Before $Before -Now $script:PresentIds `
                                    -LastMode $(if ($last) { [string]$last.Key } else { '' })
    if ($decision.Action -ne 'mode') { return }
    Invoke-ReapplyMode -Key $decision.Mode -Reason $decision.Reason
}

# Выход из сна. Возвращаем последний ВЫБРАННЫЙ режим, а не то, что система
# подняла сама: она поднимает свой набор, и это тот же случай, что после
# включения компьютера (см. Invoke-StartupRestore), только сессия та же.
#
# Не сразу, а с задержкой: сразу после пробуждения мониторы ещё поднимаются, и
# запрос состояния в этот момент отвечает про наполовину собранный стол.
#
# Сама задержка живёт в уже существующем 15-секундном таймере, а не в своём:
# событие о пробуждении система поднимает НЕ в потоке приложения, а заводить
# оттуда таймер WinForms — значит трогать чужой поток. Отметка времени — это
# просто присваивание, и его достаточно.
$script:ResumeDueAt = $null

function Invoke-ResumeCheck {
    if (-not $script:ResumeDueAt) { return }
    if ((Get-Date) -lt $script:ResumeDueAt) { return }
    $script:ResumeDueAt = $null
    Update-StateCache
    $last = Get-LastMode
    if ($last) { Invoke-ReapplyMode -Key ([string]$last.Key) -Reason 'woke up from sleep' }
}

# --- таймер выключения ------------------------------------------------------
# «Выключи компьютер через час». Отсчёт живёт только в памяти трея: компьютер,
# который выключается сам через сутки после того, как об этом попросили, страшнее
# любой пользы, поэтому на диск это не пишется и после перезапуска не оживает.
#
# Предупреждение за минуту — обязательная часть, а не удобство: между «поставил
# таймер и забыл» и «потерял несохранённое» стоит ровно оно.

$script:PowerDeadline = $null
$script:PowerAction = 'shutdown'
$script:PowerWarned = $false

function Get-PowerRemaining {
    if (-not $script:PowerDeadline) { return -1 }
    return [int][math]::Ceiling(($script:PowerDeadline - (Get-Date)).TotalSeconds)
}

# Подсказка значка: обратный отсчёт, когда он есть, и просто имя, когда нет.
# Спрашиваем САМ срок, а не остаток: срок в прошлом — это всё ещё заведённый
# таймер, и подсказка обязана его показывать (Format-Duration покажет «0 s»).
function Update-TrayText {
    if ($script:PowerDeadline) {
        $tray.Text = '{0} - {1} in {2}' -f $script:AppName, $script:PowerAction, (Format-Duration (Get-PowerRemaining))
    }
    else { $tray.Text = $script:AppName }
}

function Start-PowerTimer {
    param([int]$Minutes, [string]$Action = 'shutdown')

    if ($Minutes -le 0) { return }
    $script:PowerAction = $Action
    $script:PowerDeadline = (Get-Date).AddMinutes($Minutes)
    $script:PowerWarned = $false
    $script:PowerTicker.Start()
    Write-DisplayLog ("power: {0} scheduled in {1} min" -f $Action, $Minutes)
    Update-TrayText
    Show-Balloon 'Timer set' ('The computer will {0} in {1}, {2}. Cancel it from this menu.' -f $Action,
                              (Format-DurationShort $Minutes), (Get-TimerTargetText -Minutes $Minutes))
}

function Stop-PowerTimer {
    param([switch]$Quiet)

    if (-not $script:PowerDeadline) { return }
    $script:PowerDeadline = $null
    $script:PowerTicker.Stop()
    Write-DisplayLog 'power: timer cancelled'
    Update-TrayText
    if (-not $Quiet) { Show-Balloon 'Timer cancelled' 'The computer stays on.' }
}

# Подвинуть заведённый таймер, не заводя его заново: «ещё пятнадцать минут» — это
# сдвиг срока, а не новый отсчёт от нуля, и разница видна как раз тогда, когда
# просят добавить в третий раз подряд.
function Add-PowerTime {
    param([int]$Minutes)

    if (-not $script:PowerDeadline) { return }
    $when = $script:PowerDeadline.AddMinutes($Minutes)

    # Меньше минуты не оставляем ни при каком убавлении: предупреждение за минуту —
    # часть уговора, и таймер без него выключил бы компьютер молча.
    $floor = (Get-Date).AddMinutes(1)
    if ($when -lt $floor) { $when = $floor }
    $script:PowerDeadline = $when

    $left = Get-PowerRemaining
    # Предупреждение снова в силе, если после сдвига до срока больше минуты:
    # иначе добавленное время прошло бы без него.
    if ($left -gt 60) { $script:PowerWarned = $false }

    Write-DisplayLog ("power: {0} moved by {1} min, {2} left" -f $script:PowerAction, $Minutes, (Format-Duration $left))
    Update-TrayText
    Show-Balloon 'Timer moved' ('The computer will {0} in {1}, {2}.' -f $script:PowerAction,
                                (Format-Duration $left), (Get-TimerTargetText -Minutes ([int][math]::Round($left / 60.0))))
}

# С чего открывать окно выбора: с остатка, если этот таймер уже заведён (человек
# идёт его править), и с сорока пяти минут, если нет.
function Get-PowerPrefill {
    param([string]$Action)

    if ($script:PowerDeadline -and $script:PowerAction -eq $Action) {
        $left = [int][math]::Ceiling((Get-PowerRemaining) / 60.0)
        if ($left -gt 0) { return $left }
    }
    return 45
}

$script:PowerTicker = New-Object System.Windows.Forms.Timer
# Раз в пять секунд: обратный отсчёт показывается в минутах, и чаще незачем.
$script:PowerTicker.Interval = 5000
$script:PowerTicker.add_Tick({
    # Условие выхода — ОТСУТСТВИЕ срока, а не отрицательный остаток. Таймер WinForms
    # всегда опаздывает и никогда не спешит, за сотню тиков опоздание накапливается,
    # и тик, который должен был поймать срок, приходит уже за ним. Срок в прошлом
    # означает «пора», а не «таймера нет».
    if (-not $script:PowerDeadline) { $script:PowerTicker.Stop(); return }
    $left = Get-PowerRemaining
    Update-TrayText

    if (-not $script:PowerWarned -and $left -le 60) {
        $script:PowerWarned = $true
        Show-Balloon 'One minute left' ('The computer will {0} in a minute. Cancel it from the tray menu.' -f $script:PowerAction) 'Warning'
    }
    if ($left -le 0) {
        $action = $script:PowerAction
        $script:PowerDeadline = $null
        $script:PowerTicker.Stop()
        Update-TrayText
        try { Invoke-PowerAction -Action $action }
        catch { Write-DisplayLog "power: failed - $($_.Exception.Message)" }
    }
})

# --- дневник ----------------------------------------------------------------
# Замер раз в десять секунд: реже — и переключение между окнами теряется, чаще —
# и это уже слежка с точностью, которая никому не нужна. Стоит замер микросекунды
# (три системных вызова), на диск копилка уходит раз в две минуты.

$script:ActivityTicks = 0

function Invoke-ActivityTick {
    if (-not (Get-ActiveSettings).stats) { return }
    try {
        # Сначала «есть ли кто за компьютером», и только потом карта мониторов и
        # ключ режима: ночью каждый тик кончается на первом же вопросе, и
        # пересчитывать для него комбинации незачем.
        $sample = Get-ActivitySample
        if ($sample) {
            Add-ActivitySample -Sample $sample -DisplayMap (Get-DisplayNameMap) -Mode (Get-CurrentModeKey) -IntervalSeconds 10
        }
        $script:ActivityTicks++
        if ($script:ActivityTicks % 12 -eq 0) { Save-ActivityStore }
    }
    catch { Write-DisplayLog "stats: sample failed - $($_.Exception.Message)" }
}

$script:ActivityTimer = New-Object System.Windows.Forms.Timer
$script:ActivityTimer.Interval = 10000
$script:ActivityTimer.add_Tick({ Invoke-ActivityTick })

# --- память -----------------------------------------------------------------
# Обрезка рабочего набора: после старта процесс держит ~75 МБ, из них живого около
# десяти, остальное — следы компиляции и первого построения меню. Дёргается один
# раз после запуска и после закрытия окна настроек (WPF оставляет за собой больше
# всех), а не по таймеру: страницы, которыми пользуются, обрезать бессмысленно —
# они тут же вернутся.
function Optimize-TrayMemory {
    try {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        [NativeMemory]::Trim()
    }
    catch { Write-DisplayLog "memory: trim failed - $($_.Exception.Message)" }
}

# Обрезка на старте — разовая: за несколько минут работы куча .NET заново набирает
# свой бюджет, и рабочий набор возвращается к прежним ~70 МБ. Поэтому главная
# обрезка — эта: человек отошёл, страницы остыли, самое время их отдать. Один раз на каждый перерыв, порог — пять минут: короткая пауза за
# чаем не повод гонять страницы туда-обратно.
$script:AwayTrimDone = $false

function Invoke-AwayTrim {
    $idle = $(try { [NativeActivity]::IdleSeconds() } catch { 0 })
    if ($idle -ge 300) {
        if (-not $script:AwayTrimDone) {
            $script:AwayTrimDone = $true
            Optimize-TrayMemory
        }
    }
    elseif ($script:AwayTrimDone) { $script:AwayTrimDone = $false }
}

# --- регистрация горячих клавиш ---------------------------------------------

$script:Hotkeys = $null
$script:HotkeyMap = @{}

function Register-Hotkeys {
    if ($NoHotkeys) { return }
    if (-not $script:Hotkeys) {
        $script:Hotkeys = New-Object HotkeyWindow
        $script:Hotkeys.add_HotkeyPressed({
            param($sender, $id)
            $name = $script:HotkeyMap[$id]
            if ($name) { Invoke-Mode $name }
        })
    }

    $script:Hotkeys.UnregisterAll()
    $script:HotkeyMap = @{}

    $failed = @()
    foreach ($p in $script:Settings.hotkeys.GetEnumerator()) {
        $combo = ConvertFrom-HotkeyString $p.Value
        if (-not $combo) { continue }
        $id = $script:Hotkeys.Register(($combo.Modifiers -bor $script:ModNoRepeat), $combo.Vk)
        if ($id -lt 0) { $failed += $combo.Text } else { $script:HotkeyMap[$id] = $p.Key }
    }

    if ($failed.Count -gt 0) {
        Write-DisplayLog ('tray: could not claim ' + ($failed -join ', '))
        Show-Balloon 'Some shortcuts are taken' (($failed -join ', ') + " - another program already holds these. Those modes still work from the tray menu.") 'Warning'
    }
    Write-DisplayLog ('tray: shortcuts registered: ' + $script:HotkeyMap.Count)
}

# --- меню -------------------------------------------------------------------
# Собирается заново при каждом открытии: набор подключённых мониторов меняется,
# и пункт для выдернутого должен быть виден как недоступный, а не врать.

function Add-MenuHeader {
    param([string]$Text)
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $Text
    $item.Enabled = $false
    # По Tag отрисовщик отличает заголовок раздела (приглушить) от информационной
    # строки (обычный цвет текста) — Enabled у обоих false, чтобы не ловить клики.
    $item.Tag = 'header'
    $item.Font = Get-UiFont -Size 8.5 -Semibold
    $item.Padding = New-Object System.Windows.Forms.Padding 0, 3, 0, 1
    [void]$menu.Items.Add($item)
}

$menu.add_Opening({
    $menu.Items.Clear()

    # Отрисовщик пересоздаётся на каждое открытие: тема и акцент могли смениться,
    # пока трей жил, а объект дешёвый. Ошибка оформления меню не должна оставлять
    # без самого меню — тогда откат на системный вид.
    try {
        $dark = Test-DarkTheme
        $accent = [System.Drawing.ColorTranslator]::FromHtml((Get-AccentColor -ForDarkTheme:$dark))
        $menu.Renderer = New-Object ModernMenuRenderer $dark, $accent
    }
    catch {
        Write-DisplayLog "tray: menu renderer failed, using the system one - $($_.Exception.Message)"
        $menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System
    }

    $state = Get-CachedState

    if ($state) {
        Add-MenuHeader 'CONNECTED DISPLAYS'
        foreach ($m in $state) {
            $dot = 'unplugged'
            if ($m.Disconnected)  { $what = 'not connected' }
            elseif ($m.Active)    { $what = '{0} x {1} @ {2} Hz' -f $m.Width, $m.Height, $m.Hz; $dot = 'on' }
            else                  { $what = 'off'; $dot = 'off' }
            $suffix = ''
            if ($m.Primary) { $suffix = '   - primary' }

            $line = New-Object System.Windows.Forms.ToolStripMenuItem ('{0}    {1}{2}' -f $m.Label, $what, $suffix)
            $line.Enabled = $false
            $line.Tag = 'info'
            $line.Padding = New-Object System.Windows.Forms.Padding 0, 4, 0, 4
            # Расхождение с максимальным режимом стоит видеть сразу: обычно это
            # деградировавшая линия DisplayPort, а не настройка.
            if ($m.Active -and $m.BestMode -and $m.Hz -lt $m.BestMode.Hz) {
                $line.Text += ('   (below {0} Hz)' -f $m.BestMode.Hz)
                $dot = 'below'
            }
            $line.Image = Get-StatusDot $dot
            [void]$menu.Items.Add($line)
        }
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }

    # Настройки — ради комбинаций: без них Get-DisplayModes отдал бы только соло и
    # «все». Через функцию, а не $script:Settings (см. Get-ActiveSettings).
    $modes = @(Get-DisplayModes -State $state -Settings (Get-ActiveSettings))
    $activeKey = $null
    if ($state) { $activeKey = Get-ActiveModeKey -State $state -Modes $modes }

    Add-MenuHeader 'SWITCH TO'
    foreach ($mode in $modes) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = $mode.Title
        $item.Tag = $mode.Key
        $item.Padding = New-Object System.Windows.Forms.Padding 0, 4, 0, 4

        # Через функцию, а не $script:Settings: см. Get-ActiveSettings.
        $combo = (Get-ActiveSettings).hotkeys[$mode.Key]
        if ($combo) { $item.ShortcutKeyDisplayString = $combo }

        if (-not $mode.Available) {
            $item.Enabled = $false
            $item.Text += '   (not connected)'
        }
        if ($mode.Key -eq $activeKey) {
            $item.Checked = $true
            $item.Font = Get-UiFont -Semibold
        }

        $item.add_Click({ Invoke-Mode $this.Tag }.GetNewClosure())
        [void]$menu.Items.Add($item)
    }

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # Таймер: «выключи через час», «усни через двадцать минут». Отсчёт видно и
    # здесь, и в подсказке значка — таймер, о котором нельзя узнать, страшный.
    # Рядом с каждой величиной — время на часах: «через два часа» человек сверяет
    # с собственными планами не в минутах, а в «во сколько это будет».
    foreach ($spec in @(@{ Action = 'shutdown'; Title = 'Shut down' }, @{ Action = 'sleep'; Title = 'Sleep' })) {
        $action = [string]$spec.Action
        $armed = ($script:PowerDeadline -and $script:PowerAction -eq $action)
        $left = $(if ($armed) { Get-PowerRemaining } else { 0 })
        $parent = New-Object System.Windows.Forms.ToolStripMenuItem
        $parent.Text = $(if ($armed) { '{0} in {1}' -f $spec.Title, (Format-Duration $left) }
                         else { '{0} in...' -f $spec.Title })
        $parent.Padding = New-Object System.Windows.Forms.Padding 0, 4, 0, 4
        if ($armed) {
            $parent.Checked = $true
            $parent.Font = Get-UiFont -Semibold
            $parent.ShortcutKeyDisplayString = Get-TimerTargetText -Minutes ([int][math]::Round($left / 60.0))

            # Заведённый таймер чаще двигают, чем отменяют: «ещё пятнадцать минут»
            # — это то, ради чего к нему обычно и возвращаются.
            foreach ($shift in 15, -15) {
                $move = New-Object System.Windows.Forms.ToolStripMenuItem
                $move.Text = $(if ($shift -gt 0) { 'Add {0} minutes' -f $shift }
                               else { 'Take {0} minutes off' -f [math]::Abs($shift) })
                $move.Tag = $shift
                # Убавлять нечего, когда осталось меньше: таймер не должен уметь
                # выключить компьютер прямо сейчас, мимо предупреждения за минуту.
                $move.Enabled = ($shift -gt 0 -or $left -gt ([math]::Abs($shift) + 1) * 60)
                $move.add_Click({ Add-PowerTime -Minutes ([int]$this.Tag) }.GetNewClosure())
                [void]$parent.DropDownItems.Add($move)
            }

            $cancel = New-Object System.Windows.Forms.ToolStripMenuItem 'Cancel the timer'
            $cancel.add_Click({ Stop-PowerTimer })
            [void]$parent.DropDownItems.Add($cancel)
            [void]$parent.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        }
        foreach ($minutes in 15, 30, 60, 120) {
            $item = New-Object System.Windows.Forms.ToolStripMenuItem (Format-DurationShort $minutes)
            $item.ShortcutKeyDisplayString = Get-TimerTargetText -Minutes $minutes
            $item.Tag = '{0}|{1}' -f $action, $minutes
            $item.add_Click({
                $parts = ([string]$this.Tag) -split '\|'
                Start-PowerTimer -Minutes ([int]$parts[1]) -Action $parts[0]
            }.GetNewClosure())
            [void]$parent.DropDownItems.Add($item)
        }
        [void]$parent.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        # Своё время — окном (Show-TimerDialog в SettingsDialog.ps1): ползунок,
        # таблетки, колесо и то же время на часах, что и у готовых величин. Ноль
        # оттуда означает «передумал», и заводить тогда нечего.
        $custom = New-Object System.Windows.Forms.ToolStripMenuItem 'Pick a time...'
        $custom.Tag = $action
        $custom.add_Click({
            $act = [string]$this.Tag
            # Ошибку в построении окна WinForms показывает безымянным системным
            # окном, без подробностей. Ловим сами и пишем в журнал.
            try {
                $minutes = Show-TimerDialog -Action $act -Minutes (Get-PowerPrefill -Action $act)
                if ($minutes -gt 0) { Start-PowerTimer -Minutes $minutes -Action $act }
            }
            catch {
                Write-DisplayLog "timer dialog ERROR: $($_.Exception.Message) | $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
                Show-Balloon 'Could not open the timer' 'Details are in the log.' 'Warning'
            }
            # Окно WPF, как и настройки, оставляет за собой рабочий набор.
            Optimize-TrayMemory
        }.GetNewClosure())
        [void]$parent.DropDownItems.Add($custom)
        [void]$menu.Items.Add($parent)
    }

    $statsItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Statistics...'
    $statsItem.Padding = New-Object System.Windows.Forms.Padding 0, 4, 0, 4
    if (-not (Get-ActiveSettings).stats) {
        # Дневник выключен — пункт видно, но он объясняет, почему пуст, вместо
        # того чтобы открыть страницу с нулями.
        $statsItem.Text = 'Statistics (diary is off)'
        $statsItem.add_Click({
            Show-Balloon 'The diary is off' 'Turn on "Keep a diary" in Settings, and statistics appear as the day goes.' 'Warning'
        })
    }
    else {
        $statsItem.add_Click({
            try {
                # Пишем копилку на диск перед отчётом: последние минуты живут в
                # памяти, и без этого отчёт отставал бы от жизни на две минуты.
                Save-ActivityStore -Force
                [void](Show-ActivityReport -Days 30)
            }
            catch {
                Write-DisplayLog "stats: report failed - $($_.Exception.Message)"
                Show-Balloon 'Could not build the report' $_.Exception.Message 'Error'
            }
        })
    }
    [void]$menu.Items.Add($statsItem)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $settingsItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Settings...'
    $settingsItem.Padding = New-Object System.Windows.Forms.Padding 0, 4, 0, 4
    # Имя приложения кладём в локальную переменную: замыкание её захватит, а вот
    # $script:AppName внутри .GetNewClosure() разрешается в пустоту, и заголовок окна
    # с ошибкой оказался бы пустым.
    $appName = $script:AppName
    $settingsItem.add_Click({
        # Ошибку в построении окна WinForms показывает безымянным системным окном,
        # без подробностей. Ловим сами и пишем в журнал — иначе такое не отладить.
        try {
            $updated = Show-SettingsDialog -State (Get-CachedState) -Settings (Get-ActiveSettings)
            if ($updated) {
                Set-ActiveSettings $updated
                Register-Hotkeys
                Show-Balloon 'Settings saved' 'Shortcuts reloaded.'
            }
        }
        catch {
            Write-DisplayLog "settings dialog ERROR: $($_.Exception.Message) | $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
            [System.Windows.Forms.MessageBox]::Show(
                "Could not open Settings:`n`n$($_.Exception.Message)`n`nDetails are in the log.",
                $appName, 'OK', 'Error') | Out-Null
        }
        # Окно настроек — WPF, и после него остаётся больше всего мусора.
        Optimize-TrayMemory
    }.GetNewClosure())
    [void]$menu.Items.Add($settingsItem)

    $logItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open log'
    $logItem.Padding = New-Object System.Windows.Forms.Padding 0, 4, 0, 4
    $logItem.add_Click({
        if (Test-Path $script:LogFile) { Start-Process notepad.exe $script:LogFile }
        else { Show-Balloon 'No log yet' 'It appears after the first switch.' }
    })
    [void]$menu.Items.Add($logItem)

    $folderItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open folder'
    $folderItem.Padding = New-Object System.Windows.Forms.Padding 0, 4, 0, 4
    $folderItem.add_Click({ Start-Process explorer.exe $script:ToolRoot })
    [void]$menu.Items.Add($folderItem)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
    $exitItem.Padding = New-Object System.Windows.Forms.Padding 0, 4, 0, 4
    $exitItem.add_Click({ [System.Windows.Forms.Application]::Exit() })
    [void]$menu.Items.Add($exitItem)
})

# Меню открывается только правой кнопкой — это делает сам NotifyIcon, раз ему
# назначен ContextMenuStrip. Открывать его ещё и левым кликом (через приватный
# ShowContextMenu) намеренно не стали: это сбивает с толку.

# --- первый запуск ----------------------------------------------------------
# Клавиши по умолчанию раскладываются один раз: соло-режимы получают F1, F2, …,
# затем комбинации. Дальше их правит пользователь, и мы больше не вмешиваемся.

# Набор ПОДКЛЮЧЁННЫХ мониторов заполняется первым же обновлением кэша, поэтому
# объявлен ДО него: присваивание после затирало бы то, что уже узнали, и первое
# подключение монитора за запуск проходило бы незамеченным.
$script:PresentIds = @()

Update-StateCache   # чтобы первое открытие меню было таким же быстрым, как остальные

# Кэш обновляем по событию системы: монитор могли включить, выключить или
# переподключить и мимо нашего приложения.
#
# $script:PresentIds — набор ПОДКЛЮЧЁННЫХ мониторов до обновления кэша: по его
# изменению видно, воткнули монитор или выдернули (см. Invoke-PlugCheck). Наши
# собственные переключения его не меняют, поэтому реакции на собственную работу
# здесь быть не может.
$script:DisplayChanged = {
    $before = @($script:PresentIds)
    Update-StateCache
    Invoke-ModeWatch
    try { Invoke-PlugCheck -Before $before }
    catch { Write-DisplayLog "reapply: plug check failed - $($_.Exception.Message)" }
}
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($script:DisplayChanged)

# Выход из сна. Настройку проверяем здесь, а не в таймере: событие приходит и на
# засыпание тоже, и заводить отсчёт на него нечего.
$script:PowerModeChanged = {
    param($sender, $e)
    if ($e.Mode -ne [Microsoft.Win32.PowerModes]::Resume) { return }
    if (-not (Get-ActiveSettings).reapply.onResume) { return }
    Write-DisplayLog 'reapply: the computer woke up, waiting for the displays to settle'
    $script:ResumeDueAt = (Get-Date).AddSeconds(5)
}
[Microsoft.Win32.SystemEvents]::add_PowerModeChanged($script:PowerModeChanged)

# Пока открыта игра, сторож откладывает возврат частоты (см. Test-FullscreenApp).
# Выход из безрамочного полного экрана событием DisplaySettingsChanged не
# сопровождается, поэтому отложенное добираем таймером. Блок обычный, не
# .GetNewClosure() — иначе $script: внутри не разрешится.
$script:WatchTimer = New-Object System.Windows.Forms.Timer
$script:WatchTimer.Interval = 15000
$script:WatchTimer.add_Tick({
    # Порядок здесь осмысленный. Пробуждение — первым: пока стол не собран
    # заново, всё остальное про него врёт. Правила — вторыми: заметить запуск
    # игры важнее, чем добрать отложенный возврат частоты, и одно с другим не
    # связано.
    try { Invoke-ResumeCheck }
    catch { Write-DisplayLog "reapply: after sleep failed - $($_.Exception.Message)" }

    try { Invoke-RulesCheck }
    catch { Write-DisplayLog "rule: check failed - $($_.Exception.Message)" }

    try { Invoke-AwayTrim }
    catch { Write-DisplayLog "memory: away trim failed - $($_.Exception.Message)" }

    if (-not $script:RestorePending) { return }
    if (Test-FullscreenApp) { return }
    Update-StateCache
    Invoke-ModeWatch
})
$script:WatchTimer.Start()

# Дневник. Таймер крутится всегда, а вот замер делается только когда настройка
# включена: проверка внутри стоит одно обращение к словарю, а таймер, который
# приходится заводить и останавливать при каждом сохранении настроек, — это
# лишнее состояние, которое рано или поздно разойдётся с настройкой.
$script:ActivityTimer.Start()

# Снимки позиций окон из прошлого входа в Windows бесполезны: HWND действительны
# только в рамках одной logon-сессии, а после перезагрузки те же номера достанутся
# другим окнам. Чистим записи, все процессы которых уже мертвы.
try { Remove-DeadWindowLayouts }
catch { Write-DisplayLog "windows: could not clean stale snapshots - $($_.Exception.Message)" }

# Монитор мог переехать на другой вход, пока приложение не работало — тогда
# привязка сама переезжает на новый ключ. Делаем это до регистрации клавиш.
if (Update-HotkeyKeys -Settings $script:Settings -State (Get-CachedState)) {
    Save-DisplaySettings $script:Settings
}

# Признак первого запуска — ОТСУТСТВИЕ файла настроек, а не пустой список клавиш.
# Пустой список — законный выбор: человек снял все привязки в окне настроек, и
# возвращать их на следующем старте нельзя. По ключу «файл есть» испорченный
# settings.json тоже не затирается значениями по умолчанию.
if (-not (Test-Path $script:SettingsFile)) {
    $state = Get-CachedState
    $i = 1
    foreach ($mode in @(Get-DisplayModes -State $state -Settings (Get-ActiveSettings))) {
        if ($i -gt 8) { break }
        $script:Settings.hotkeys[$mode.Key] = "Ctrl+Alt+F$i"
        $i++
    }
    Save-DisplaySettings $script:Settings
    Write-DisplayLog 'settings: first run - assigned the default shortcuts'
}

Register-Hotkeys
Write-DisplayLog ("tray: started in {0} ms" -f [int]$script:StartWatch.ElapsedMilliseconds)

# Возврат последнего режима — не здесь, а через одноразовый таймер: цикл сообщений
# должен уже крутиться, иначе на несколько секунд переключения не открывается меню
# и не показываются всплывашки. Полторы секунды — чтобы стол после входа в Windows
# устоялся; человек к этому моменту обычно ещё смотрит на рабочий стол.
#
# После «tray: started» намеренно: строка меряет, как быстро становятся рабочими
# клавиши, и переключение экранов не должно попадать в этот замер.
$script:StartupTimer = New-Object System.Windows.Forms.Timer
$script:StartupTimer.Interval = 1500
$script:StartupTimer.add_Tick({
    $script:StartupTimer.Stop()
    try { Invoke-StartupRestore }
    catch { Write-DisplayLog "startup: could not restore the last mode - $($_.Exception.Message)" }
    # Старт закончился — вернуть системе то, что было нужно только на старте.
    Optimize-TrayMemory
})
$script:StartupTimer.Start()

try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    Write-DisplayLog 'tray: stopped'
    # Копилку дневника — на диск: последние минуты живут в памяти, и выход из
    # приложения не повод их терять.
    try { Save-ActivityStore } catch { }   # на выходе ронять уже нечего
    foreach ($timer in $script:WatchTimer, $script:StartupTimer, $script:ActivityTimer,
                       $script:PowerTicker) {
        if ($timer) { $timer.Stop(); $timer.Dispose() }
    }
    if ($script:DisplayChanged) {
        [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($script:DisplayChanged)
    }
    if ($script:PowerModeChanged) {
        [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($script:PowerModeChanged)
    }
    $tray.Visible = $false
    $tray.Dispose()
    if ($script:Hotkeys) { $script:Hotkeys.Dispose() }
    $script:AppMutex.ReleaseMutex()
    $script:AppMutex.Dispose()
}
