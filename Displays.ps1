<#
    Displays.ps1 — Multi-Monitor Tool, значок в области уведомлений.

    Интерфейс на английском (просьба пользователя), комментарии на русском.

    Что даёт по сравнению с ярлыками:
      * клик по значку — меню с текущим состоянием и режимами;
      * горячие клавиши регистрирует сам процесс (RegisterHotKey), поэтому они
        не зависят от того, подхватил ли Explorer ярлыки из Пуска;
      * клавиши настраиваются из окна Settings и живут в settings.json.
#>
[CmdletBinding()]
param([switch]$NoHotkeys)

$ErrorActionPreference = 'Stop'

# Заводим до всего остального: в это время попадает и компиляция (или загрузка из
# кэша) нативных типов, и сборка формы, и первый опрос состояния. Итог уходит в
# журнал строкой «tray: started in N ms» — постоянный контроль того, как быстро
# клавиши становятся рабочими после входа в Windows.
$script:StartWatch = [System.Diagnostics.Stopwatch]::StartNew()

. (Join-Path $PSScriptRoot 'DisplayCore.ps1')
. (Join-Path $PSScriptRoot 'SettingsDialog.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppName = 'Multi-Monitor Tool'

# Один экземпляр: иначе горячие клавиши займёт только первый, а второй провисит
# бесполезным значком.
$script:AppMutex = New-Object System.Threading.Mutex($false, 'Local\SuperDisplayTray')
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
# Меню обязано открываться мгновенно. Опрос состояния запускает
# MultiMonitorTool.exe (~1.5 с), и если делать это в обработчике Opening, штатный
# правый клик по значку не успевает: Windows решает, что меню не показалось, и
# закрывает его — открывался только левый, который мы вызываем принудительно.
# Поэтому состояние держим в кэше и обновляем по событию системы.

$script:StateCache = $null

function Update-StateCache {
    try {
        $script:StateCache = @(Get-DisplayState)
    }
    catch {
        Write-DisplayLog "cache: could not refresh display state - $($_.Exception.Message)"
    }
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

# Приёмник горячих клавиш (класс HotkeyWindow) переехал в общий исходник в
# DisplayCore.ps1: там все нативные типы компилируются одним вызовом и кладутся в
# кэш-сборку. Здесь он был четвёртой отдельной компиляцией на каждый старт трея.

# --- значок -----------------------------------------------------------------
# Один файл app.ico на всё: трей, ярлыки в Пуске и в автозагрузке. Иконка
# DisplaySwitch.exe, которая стояла раньше, в Пуске сливалась с системными.
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

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System
$menu.Font = New-Object System.Drawing.Font 'Segoe UI', 9
$menu.ShowImageMargin = $true
$menu.ImageScalingSize = New-Object System.Drawing.Size 16, 16
$tray.ContextMenuStrip = $menu

function Show-Balloon {
    param([string]$Title, [string]$Text, [string]$Kind = 'Info')
    if (-not $script:Settings.notifications -and $Kind -eq 'Info') { return }
    $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::$Kind
    $tray.BalloonTipTitle = $Title
    $tray.BalloonTipText = $Text
    $tray.ShowBalloonTip(4000)
}

function Invoke-Mode {
    param([string]$Key)

    $tray.Text = "$script:AppName - switching..."
    try {
        $keep = -not $script:Settings.maximizeRefresh
        $result = Switch-DisplayMode -ModeKey $Key -KeepMode:$keep -Quiet
        if ($result.Skipped) {
            Show-Balloon 'Skipped' $result.Message 'Warning'
        }
        elseif ($result.Message -and $result.Ok) {
            Show-Balloon 'Displays switched' $result.Message
        }
        elseif ($result.Message) {
            # Частичный провал — тоже провал. Раньше он показывался зелёной
            # сводкой, потому что монитор, который не поднялся, из неё выпадал.
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
        $tray.Text = $script:AppName
        Update-StateCache
    }
}

# Окно настроек живёт в SettingsDialog.ps1 — его можно собрать и проверить
# в изоляции, что и вскрыло падение на недопустимом Anchor = 'West'.

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
    $item.Font = New-Object System.Drawing.Font 'Segoe UI Semibold', 8.5
    [void]$menu.Items.Add($item)
}

$menu.add_Opening({
    $menu.Items.Clear()

    $state = Get-CachedState

    if ($state) {
        Add-MenuHeader 'CONNECTED DISPLAYS'
        foreach ($m in $state) {
            if ($m.Disconnected)  { $what = 'not connected' }
            elseif ($m.Active)    { $what = '{0} x {1} @ {2} Hz' -f $m.Width, $m.Height, $m.Hz }
            else                  { $what = 'off' }
            $suffix = ''
            if ($m.Primary) { $suffix = '   - primary' }

            $line = New-Object System.Windows.Forms.ToolStripMenuItem ('{0}    {1}{2}' -f $m.Label, $what, $suffix)
            $line.Enabled = $false
            # Расхождение с максимальным режимом стоит видеть сразу: обычно это
            # деградировавшая линия DisplayPort, а не настройка.
            if ($m.Active -and $m.BestMode -and $m.Hz -lt $m.BestMode.Hz) {
                $line.Text += ('   (below {0} Hz)' -f $m.BestMode.Hz)
            }
            [void]$menu.Items.Add($line)
        }
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }

    $modes = @(Get-DisplayModes $state)
    $activeKey = $null
    if ($state) { $activeKey = Get-ActiveModeKey $state $modes }

    Add-MenuHeader 'SWITCH TO'
    foreach ($mode in $modes) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = $mode.Title
        $item.Tag = $mode.Key

        # Через функцию, а не $script:Settings: см. комментарий у Get-ActiveSettings.
        # Здесь та же ловушка не падала, а просто молча не показывала комбинации.
        $combo = (Get-ActiveSettings).hotkeys[$mode.Key]
        if ($combo) { $item.ShortcutKeyDisplayString = $combo }

        if (-not $mode.Available) {
            $item.Enabled = $false
            $item.Text += '   (not connected)'
        }
        if ($mode.Key -eq $activeKey) {
            $item.Checked = $true
            $item.Font = New-Object System.Drawing.Font 'Segoe UI Semibold', 9
        }

        $item.add_Click({ Invoke-Mode $this.Tag }.GetNewClosure())
        [void]$menu.Items.Add($item)
    }

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $settingsItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Settings...'
    # Имя приложения кладём в локальную переменную: замыкание её захватит, а вот
    # $script:AppName внутри .GetNewClosure() разрешается в пустоту — заголовок
    # окна с ошибкой из-за этого был пустым.
    $appName = $script:AppName
    $settingsItem.add_Click({
        # Ошибку в построении окна WinForms показывает безымянным системным окном,
        # без подробностей. Ловим сами и пишем в журнал — иначе такое не отладить.
        try {
            $updated = Show-SettingsDialog -State (Get-CachedState) -Settings (Get-ActiveSettings) -Icon $tray.Icon
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
    }.GetNewClosure())
    [void]$menu.Items.Add($settingsItem)

    $logItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open log'
    $logItem.add_Click({
        if (Test-Path $script:LogFile) { Start-Process notepad.exe $script:LogFile }
        else { Show-Balloon 'No log yet' 'It appears after the first switch.' }
    })
    [void]$menu.Items.Add($logItem)

    $folderItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open folder'
    $folderItem.add_Click({ Start-Process explorer.exe $script:ToolRoot })
    [void]$menu.Items.Add($folderItem)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
    $exitItem.add_Click({ [System.Windows.Forms.Application]::Exit() })
    [void]$menu.Items.Add($exitItem)
})

# Меню открывается только правой кнопкой — это делает сам NotifyIcon, раз ему
# назначен ContextMenuStrip. Обработчик левого клика тут был и убран по просьбе:
# левым он открывался через приватный ShowContextMenu, и это сбивало с толку.

# --- первый запуск ----------------------------------------------------------
# Клавиши по умолчанию раскладываются один раз: соло-режимы получают F1, F2, …,
# затем группы. Дальше их правит пользователь, и мы больше не вмешиваемся.

Update-StateCache   # чтобы первое открытие меню было таким же быстрым, как остальные

# Кэш обновляем по событию системы: монитор могли включить, выключить или
# переподключить и мимо нашего приложения.
$script:DisplayChanged = { Update-StateCache; Invoke-ModeWatch }
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($script:DisplayChanged)

# Пока открыта игра, сторож откладывает возврат частоты (см. Test-FullscreenApp).
# Выход из безрамочного полного экрана событием DisplaySettingsChanged не
# сопровождается, поэтому отложенное добираем таймером. Блок обычный, не
# .GetNewClosure() — иначе $script: внутри не разрешится.
$script:WatchTimer = New-Object System.Windows.Forms.Timer
$script:WatchTimer.Interval = 15000
$script:WatchTimer.add_Tick({
    if (-not $script:RestorePending) { return }
    if (Test-FullscreenApp) { return }
    Update-StateCache
    Invoke-ModeWatch
})
$script:WatchTimer.Start()

# Монитор мог переехать на другой вход, пока приложение не работало — тогда
# привязка сама переезжает на новый ключ. Делаем это до регистрации клавиш.
if (Update-HotkeyKeys $script:Settings (Get-CachedState)) {
    Save-DisplaySettings $script:Settings
}

# Признак первого запуска — ОТСУТСТВИЕ файла настроек, а не пустой список
# клавиш. Пустой список — это законный выбор: человек снял все привязки в окне
# настроек, а на следующем старте они возвращались сами, потому что приложение
# принимало это за первый запуск. Комментарий выше при этом обещал обратное.
# По той же причине испорченный settings.json затирался значениями по умолчанию:
# разбор падал, список получался пустой, и вот эта ветка дописывала поверх.
if (-not (Test-Path $script:SettingsFile)) {
    $state = Get-CachedState
    $i = 1
    foreach ($mode in @(Get-DisplayModes $state)) {
        if ($i -gt 8) { break }
        $script:Settings.hotkeys[$mode.Key] = "Ctrl+Alt+F$i"
        $i++
    }
    Save-DisplaySettings $script:Settings
    Write-DisplayLog 'settings: first run - assigned the default shortcuts'
}

Register-Hotkeys
Write-DisplayLog ("tray: started in {0} ms" -f [int]$script:StartWatch.ElapsedMilliseconds)

try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    Write-DisplayLog 'tray: stopped'
    if ($script:WatchTimer) { $script:WatchTimer.Stop(); $script:WatchTimer.Dispose() }
    if ($script:DisplayChanged) {
        [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($script:DisplayChanged)
    }
    $tray.Visible = $false
    $tray.Dispose()
    if ($script:Hotkeys) { $script:Hotkeys.Dispose() }
    $script:AppMutex.ReleaseMutex()
    $script:AppMutex.Dispose()
}
