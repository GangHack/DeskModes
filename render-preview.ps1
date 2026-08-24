<#
.SYNOPSIS
    Renders the Settings window and a mode editor to PNG without showing them.

.DESCRIPTION
    A development tool: it builds the windows with the same New-SettingsWindow and
    New-ModeEditorWindow the tray uses, lays them out in memory and draws them to
    files. So the interface can be looked at without starting the app, opening
    Settings by hand and having a real desk in front of you - and with -Fake, for a
    desk that is not here at all.

    Theme and accent colour come from the system, exactly as in the real window.
    Two files are written: the Settings window, and "<name>-mode.png" for the
    editor.

.PARAMETER Out
    Where to write the Settings window. The mode editor goes next to it with a
    "-mode" suffix. Defaults to preview-settings.png beside the scripts.

.PARAMETER Fake
    Invent a three-display desk with combinations, shortcuts and brightness set,
    instead of reading the real one. What the windows look like stops depending on
    which monitors happen to be plugged in.

.PARAMETER EditorMode
    Whose editor to render as the second image, by mode key ("all",
    "solo:LG ULTRAFINE", "combo:Work"). Defaults to the first combination - it is
    the longest window, so it shows the most.

.EXAMPLE
    .\render-preview.ps1 -Fake
    Both windows for an invented desk, written beside the scripts.

.EXAMPLE
    .\render-preview.ps1 -Fake -EditorMode all -Out C:\tmp\ui.png
    Writes C:\tmp\ui.png and C:\tmp\ui-mode.png, the latter showing the editor of
    "All displays" - the short form, without a name or members to argue about.
#>
[CmdletBinding()]
param(
    [string]$Out = (Join-Path $PSScriptRoot 'preview-settings.png'),
    [switch]$Fake,
    # Чей редактор снимать вторым снимком: ключ режима («all», «solo:LG ULTRAFINE»,
    # «combo:Work»). По умолчанию — первая комбинация.
    [string]$EditorMode = ''
)

$ErrorActionPreference = 'Stop'

# Журнал уводим в сторону: это инструмент разработки, и в разборе настоящих
# переключений его следам не место.
if (-not $env:MMT_LOG_FILE) {
    $env:MMT_LOG_FILE = Join-Path $env:TEMP 'screendeck-render-preview.log'
}

. (Join-Path $PSScriptRoot 'DisplayCore.ps1')
. (Join-Path $PSScriptRoot 'WindowLayout.ps1')
. (Join-Path $PSScriptRoot 'Activity.ps1')
. (Join-Path $PSScriptRoot 'SettingsDialog.ps1')

function New-FakeState {
    # Тот стол, для которого всё это писалось: 4K посередине, два 1440p по бокам.
    return @(
        [pscustomobject]@{ Output = '\\.\DISPLAY1'; Label = 'LG ULTRAFINE'; Model = 'LG ULTRAFINE'
                           ShortId = 'GSM5CBC'; Native = [pscustomobject]@{ Width = 3840; Height = 2160 }
                           Id = 'fake-ultrafine'; Active = $true; Primary = $false; Disconnected = $false
                           Width = 3840; Height = 2160; Hz = 60; BestMode = $null }
        [pscustomobject]@{ Output = '\\.\DISPLAY2'; Label = 'XG27AQDMGR'; Model = 'XG27AQDMGR'
                           ShortId = 'AUSAA1D'; Native = [pscustomobject]@{ Width = 2560; Height = 1440 }
                           Id = 'fake-asus'; Active = $true; Primary = $false; Disconnected = $false
                           Width = 2560; Height = 1440; Hz = 240; BestMode = $null }
        [pscustomobject]@{ Output = '\\.\DISPLAY3'; Label = 'LG ULTRAGEAR'; Model = 'LG ULTRAGEAR'
                           ShortId = 'GSM5BB3'; Native = [pscustomobject]@{ Width = 2560; Height = 1440 }
                           Id = 'fake-ultragear'; Active = $true; Primary = $true; Disconnected = $false
                           Width = 2560; Height = 1440; Hz = 144; BestMode = $null }
    )
}

$settings = Get-DisplaySettings
if ($Fake) {
    $state = @(New-FakeState)
    # Настройки под выдуманный стол: иначе карточки встанут по чужой раскладке.
    $settings.layout = @('LG ULTRAFINE', 'XG27AQDMGR', 'LG ULTRAGEAR')
    $settings.primary = 'LG ULTRAGEAR'
    $settings.combos = [ordered]@{
        'Work' = [ordered]@{ displays = @('LG ULTRAFINE', 'LG ULTRAGEAR'); primary = '' }
        'Movie night' = [ordered]@{ displays = @('LG ULTRAFINE'); primary = 'LG ULTRAFINE' }
    }
    $settings.hotkeys = [ordered]@{
        'solo:LG ULTRAFINE' = 'Ctrl+Alt+F1'
        'solo:XG27AQDMGR'   = 'Ctrl+Alt+F2'
        'solo:LG ULTRAGEAR' = 'Ctrl+Alt+F3'
        'combo:Work'        = 'Ctrl+Alt+F4'
        'all'               = 'Ctrl+Alt+F5'
    }
    # Чтобы на снимках яркость была видна в работе, а не пустая: у комбинации —
    # своя на каждый монитор (её и покажет редактор), у «всех» — одно число.
    $settings.brightness = [ordered]@{
        'combo:Work' = [ordered]@{ 'LG ULTRAFINE' = 25; 'LG ULTRAGEAR' = 60 }
        'all'        = 80
    }
}
else {
    $state = @(Get-DisplayState -Settings $settings)
}

function Save-WindowSnapshot {
    param($Window, [string]$Path)

    # Живое окно не выше рабочей области — дальше прокрутка. Снимку прокрутка
    # только мешает: он нужен, чтобы увидеть ВСЁ окно сразу.
    $Window.MaxHeight = [double]::PositiveInfinity
    # Прокрутку редактора тоже снимаем. Ищем по имени из разметки, а не по дереву
    # элементов: до Show() дерева ещё нет.
    $viewer = $Window.FindName('Scroll')
    if ($viewer) { $viewer.VerticalScrollBarVisibility = 'Disabled' }
    # Окно приходится ПОКАЗАТЬ: размеры дерева элементов считает система, и у
    # непоказанного окна они остаются нулевыми. Показываем за краем экрана и без
    # активации — снимок получается, а на столе оно не мелькает.
    $Window.WindowStartupLocation = 'Manual'
    $Window.ShowActivated = $false
    $Window.ShowInTaskbar = $false
    $Window.Left = -10000
    $Window.Top = -10000
    $Window.Show()
    # Раскладка считается в очереди сообщений, поэтому её надо прокрутить: без
    # этого рисуется наполовину собранное окно.
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void]$Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ContextIdle,
        [action]{ $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $Window.UpdateLayout()

    $size = New-Object System.Windows.Size ([double]$Window.ActualWidth), ([double]$Window.ActualHeight)

    # 192 dpi: на 96 текст в снимке мылится, а окно всё равно смотрят с увеличением.
    $dpi = 192
    $scale = $dpi / 96
    $target = New-Object System.Windows.Media.Imaging.RenderTargetBitmap (
        [int][math]::Ceiling($size.Width * $scale), [int][math]::Ceiling($size.Height * $scale),
        $dpi, $dpi, [System.Windows.Media.PixelFormats]::Pbgra32)
    $target.Render($Window)

    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    [void]$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($target))
    $stream = [System.IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }

    Write-Host ("written: {0}  ({1} x {2})" -f $Path, $target.PixelWidth, $target.PixelHeight) -ForegroundColor Green
}

$modes = @(Get-DialogModes -State $state -Settings $settings)
$ui = New-SettingsWindow -Modes $modes -Settings $settings -State $state

try {
    Save-WindowSnapshot -Window $ui.Window -Path $Out

    # Второе окно — редактор режима: всё про режим настраивается в нём, значит
    # увидеть надо и его. По умолчанию берём комбинацию — она самая длинная, — но
    # снять можно любой режим по его ключу.
    $pick = @()
    if ($EditorMode) { $pick = @($modes | Where-Object { [string]$_.Key -eq $EditorMode } | Select-Object -First 1) }
    if ($pick.Count -eq 0) { $pick = @($modes | Where-Object { [string]$_.Kind -eq 'combo' } | Select-Object -First 1) }
    if ($pick.Count -eq 0) { $pick = @($modes | Select-Object -First 1) }
    if ($pick.Count -gt 0) {
        $mode = $pick[0]
        $combo = $null
        if ([string]$mode.Kind -eq 'combo') {
            $name = ([string]$mode.Key).Substring(6)
            $combo = @($ui.Combos | Where-Object { $_.Name -eq $name } | Select-Object -First 1)[0]
        }
        $level = $null
        if ($ui.Levels.Contains([string]$mode.Key)) { $level = $ui.Levels[[string]$mode.Key] }
        $hotkey = ''
        if ($ui.Hotkeys.Contains([string]$mode.Key)) { $hotkey = [string]$ui.Hotkeys[[string]$mode.Key] }

        $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $state -Level $level `
                                   -Hotkey $hotkey -Dark (Test-DarkTheme)
        try {
            # Рядом с первым снимком, с суффиксом. ChangeExtension($Out, $null) здесь
            # не годится: PowerShell отдаёт вместо $null пустую строку, и точка от
            # расширения остаётся в имени.
            $editorOut = Join-Path (Split-Path -Parent $Out) `
                                   ([System.IO.Path]::GetFileNameWithoutExtension($Out) + '-mode.png')
            Save-WindowSnapshot -Window $ed.Window -Path $editorOut
        }
        finally { $ed.Window.Close() }
    }
}
finally {
    $ui.Window.Close()
}
