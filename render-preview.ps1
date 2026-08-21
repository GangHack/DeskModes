<#
    render-preview.ps1 — снимок окна настроек в PNG, без показа окна.

    Зачем: окно правится часто, а увидеть результат можно было только запустив
    приложение и открыв Settings руками — на живом столе, со всеми мониторами.
    Здесь окно строится тем же New-SettingsWindow, что и в трее, раскладывается
    в памяти и рисуется в файл. Мониторы можно подсунуть выдуманные, поэтому
    картинку видно и для стола, которого рядом нет.

        .\render-preview.ps1                        как сейчас на столе
        .\render-preview.ps1 -Fake                  три придуманных монитора
        .\render-preview.ps1 -Out C:\tmp\ui.png     куда положить

    Тема и акцент берутся системные — как и в самом окне.
#>
[CmdletBinding()]
param(
    [string]$Out = (Join-Path $PSScriptRoot 'preview-settings.png'),
    [switch]$Fake
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
    $state = New-FakeState
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
    # Чтобы на снимке была видна карточка яркости в работе, а не пустая.
    $settings.brightness = [ordered]@{ 'all' = [ordered]@{ 'LG ULTRAFINE' = 25; 'XG27AQDMGR' = 60 } }
}
else {
    $state = @(Get-DisplayState -Settings $settings)
}

$modes = @(Get-DialogModes -State $state -Settings $settings)
$ui = New-SettingsWindow -Modes $modes -Settings $settings -State $state

# На снимке карточка яркости должна показывать тот режим, у которого уровни
# заданы: по умолчанию выбран первый в списке, и он обычно пустой.
if ($Fake) {
    foreach ($item in @($ui.LevelModeBox.Items)) {
        if ([string]$item.Tag -eq 'all') { $ui.LevelModeBox.SelectedItem = $item; break }
    }
}

try {
    $win = $ui.Window
    # Живое окно не выше рабочей области — дальше прокрутка. Снимку прокрутка
    # только мешает: он нужен, чтобы увидеть ВСЁ окно сразу.
    $win.MaxHeight = [double]::PositiveInfinity
    # Окно приходится ПОКАЗАТЬ: размеры дерева элементов считает система, и у
    # непоказанного окна они остаются нулевыми (первая версия этого скрипта
    # падала на нулевой высоте). Показываем за краем экрана и без активации —
    # снимок получается, а на столе оно не мелькает.
    $win.WindowStartupLocation = 'Manual'
    $win.ShowActivated = $false
    $win.ShowInTaskbar = $false
    $win.Left = -10000
    $win.Top = -10000
    $win.Show()
    # Раскладка считается в очереди сообщений, поэтому её надо прокрутить: без
    # этого рисуется наполовину собранное окно.
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void]$win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ContextIdle,
        [action]{ $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $win.UpdateLayout()

    $size = New-Object System.Windows.Size ([double]$win.ActualWidth), ([double]$win.ActualHeight)

    # 192 dpi: на 96 текст в снимке мылится, а окно всё равно смотрят с увеличением.
    $dpi = 192
    $scale = $dpi / 96
    $target = New-Object System.Windows.Media.Imaging.RenderTargetBitmap (
        [int][math]::Ceiling($size.Width * $scale), [int][math]::Ceiling($size.Height * $scale),
        $dpi, $dpi, [System.Windows.Media.PixelFormats]::Pbgra32)
    $target.Render($win)

    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    [void]$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($target))
    $stream = [System.IO.File]::Create($Out)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }

    Write-Host ("written: {0}  ({1} x {2})" -f $Out, $target.PixelWidth, $target.PixelHeight) -ForegroundColor Green
}
finally {
    $ui.Window.Close()
}
