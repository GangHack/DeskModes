#Requires -Version 5.1

<#
.SYNOPSIS
    Renders the Settings window, a mode editor and the timer popup to PNG.

.DESCRIPTION
    A development tool: it builds the windows with the same New-SettingsWindow,
    New-ModeEditorWindow and New-TimerWindow the tray uses, lays them out in memory
    and draws them to files. So the interface can be looked at without starting the
    app, opening Settings by hand and having a real desk in front of you - and with
    -Fake, for a desk that is not here at all.

    Theme and accent colour come from the system, exactly as in the real window.
    Three files are written: the Settings window, "<name>-mode.png" for the editor
    and "<name>-timer.png" for the timer popup.

.PARAMETER Out
    Where to write the Settings window. The other two go next to it with "-mode"
    and "-timer" suffixes. Defaults to preview-settings.png beside the scripts.

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
    All three windows for an invented desk, written beside the scripts.

.EXAMPLE
    .\render-preview.ps1 -Fake -EditorMode all -Out C:\tmp\ui.png
    Writes C:\tmp\ui.png and C:\tmp\ui-mode.png, the latter showing the editor of
    "All displays" - the short form, without a name or members to argue about.
#>
[CmdletBinding()]
param(
    [string]$Out = (Join-Path $PSScriptRoot 'preview-settings.png'),
    [switch]$Fake,
    # Whose editor to render as the second image: a mode key ("all",
    # "solo:LG ULTRAFINE", "combo:Work"). Defaults to the first combination.
    [string]$EditorMode = ''
)

$ErrorActionPreference = 'Stop'

# The log goes off to the side: this is a development tool, and its traces have no
# business in the record of real switches.
if (-not $env:SCREENDECK_LOG_FILE) {
    $env:SCREENDECK_LOG_FILE = Join-Path $env:TEMP 'screendeck-render-preview.log'
}

. (Join-Path $PSScriptRoot 'DisplayCore.ps1')
. (Join-Path $PSScriptRoot 'WindowLayout.ps1')
. (Join-Path $PSScriptRoot 'Activity.ps1')
. (Join-Path $PSScriptRoot 'SettingsDialog.ps1')

function New-FakeState {
    # The desk all of this was written for: 4K in the middle, two 1440p on the sides.
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

function New-FakeDiary {
    # Ten days of an invented fortnight. Enough that every section of the diary window has
    # something in it and the hour histogram has a shape rather than one spike — an empty diary
    # renders as an empty window, and an empty window shows nothing about the layout.
    $store = [ordered]@{ days = [ordered]@{} }
    $today = (Get-Date).Date
    $work = @(
        @{ App = 'Code';    Display = 'LG ULTRAFINE'; Mode = 'combo:Work'; Hour = 10; Seconds = 7200; Time = '09:40' }
        @{ App = 'chrome';  Display = 'LG ULTRAGEAR'; Mode = 'combo:Work'; Hour = 12; Seconds = 3600; Time = '12:10' }
        @{ App = 'Code';    Display = 'LG ULTRAFINE'; Mode = 'combo:Work'; Hour = 15; Seconds = 5400; Time = '15:05' }
        @{ App = 'Teams';   Display = 'LG ULTRAGEAR'; Mode = 'combo:Work'; Hour = 17; Seconds = 1800; Time = '17:20' }
        @{ App = 'cs2';     Display = 'XG27AQDMGR';   Mode = 'solo:XG27AQDMGR'; Hour = 21; Seconds = 4200; Time = '21:30' }
        @{ App = 'spotify'; Display = 'LG ULTRAGEAR'; Mode = 'all'; Hour = 23; Seconds = 900; Time = '23:15' }
    )
    foreach ($offset in 0..9) {
        # The key is assembled by the same function the code uses: on a calendar other than the
        # Gregorian one, ToString without a culture writes a year the report would then look for
        # in vain (see Format-DisplayStamp).
        $date = Format-DisplayStamp $today.AddDays(-$offset) 'yyyy-MM-dd'
        $day = Get-ActivityDay -Store $store -Date $date
        foreach ($span in $work) {
            # The days are not identical: a diary where every bar is the same height says nothing
            # about whether the drawing works.
            $seconds = [int]([int]$span.Seconds * (1.0 - 0.05 * ($offset % 4)))
            Add-ActivitySpan -Day $day -Process $span.App -Display $span.Display -Mode $span.Mode `
                             -Seconds $seconds -Time ([string]$span.Time) -Hour ([int]$span.Hour)
        }
        $day.switches = 6 + ($offset % 3)
        $day.longest = 9000
    }
    return $store
}

$settings = Get-DisplaySettings
if ($Fake) {
    $state = @(New-FakeState)
    # Settings to match the invented desk: otherwise the cards line up by someone else's layout.
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
    # So that brightness shows up in the images doing its job rather than empty: the
    # combo has one per monitor (which is what the editor shows), "all" has a single number.
    $settings.brightness = [ordered]@{
        'combo:Work' = [ordered]@{ 'LG ULTRAFINE' = 25; 'LG ULTRAGEAR' = 60 }
        'all'        = 80
    }
}
else {
    $state = @(Get-DisplayState)
}

function Save-WindowSnapshot {
    param($Window, [string]$Path)

    # A live window is never taller than the work area — past that it scrolls. For an
    # image scrolling only gets in the way: it exists to show the WHOLE window at once.
    $Window.MaxHeight = [double]::PositiveInfinity
    # The editor's scrolling comes off too. We look it up by the name from the markup,
    # not through the element tree: before Show() there is no tree yet.
    $viewer = $Window.FindName('Scroll')
    if ($viewer) { $viewer.VerticalScrollBarVisibility = 'Disabled' }
    # The window has to be SHOWN: the system is what measures the element tree, and for
    # a window that was never shown those measurements stay zero. We show it off the edge
    # of the screen and without activating it — the image comes out, and nothing flashes on the desk.
    $Window.WindowStartupLocation = 'Manual'
    $Window.ShowActivated = $false
    $Window.ShowInTaskbar = $false
    $Window.Left = -10000
    $Window.Top = -10000
    $Window.Show()
    # Layout is computed on the message queue, so the queue has to be pumped: without
    # this a half-assembled window gets drawn.
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void]$Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ContextIdle,
        [action]{ $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $Window.UpdateLayout()

    $size = New-Object System.Windows.Size ([double]$Window.ActualWidth), ([double]$Window.ActualHeight)

    # 192 dpi: at 96 the text in the image goes soft, and the window gets looked at zoomed in anyway.
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

    # The second window is the mode editor: everything about a mode is set up in there,
    # so it has to be seen too. By default we take a combination — it is the longest one
    # — but any mode can be rendered by its key.
    $pick = @()
    if ($EditorMode) { $pick = @($modes | Where-Object { [string]$_.Key -eq $EditorMode } | Select-Object -First 1) }
    if ($pick.Count -eq 0) { $pick = @($modes | Where-Object { [string]$_.Kind -eq 'combo' } | Select-Object -First 1) }
    if ($pick.Count -eq 0) { $pick = @($modes | Select-Object -First 1) }
    if ($pick.Count -gt 0) {
        $mode = $pick[0]
        $combo = Get-UiCombo -Ui $ui -Key ([string]$mode.Key)

        $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $state `
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Dark (Test-DarkTheme)
        try {
            # Next to the first image, with a suffix. ChangeExtension($Out, $null) is no
            # good here: PowerShell hands back an empty string instead of $null, and the
            # dot from the extension stays in the name.
            #
            # The folder is taken with a '.' fallback: for a bare file name (-Out ui.png)
            # Split-Path -Parent hands back an empty string, and Join-Path will not take it
            # — so the second image used to die once the first was already written.
            $editorDir = Split-Path -Parent $Out
            if (-not $editorDir) { $editorDir = '.' }
            $editorOut = Join-Path $editorDir `
                                   ([System.IO.Path]::GetFileNameWithoutExtension($Out) + '-mode.png')
            Save-WindowSnapshot -Window $ed.Window -Path $editorOut
        }
        finally { $ed.Window.Close() }
    }

    # The third window is the timer. Small, but its own: the slider, the pills and the
    # time on the clock can only be seen in an image, not in the markup.
    $timerDir = Split-Path -Parent $Out
    if (-not $timerDir) { $timerDir = '.' }
    $timerOut = Join-Path $timerDir ([System.IO.Path]::GetFileNameWithoutExtension($Out) + '-timer.png')
    $timer = New-TimerWindow -Action 'sleep' -Minutes 90
    try { Save-WindowSnapshot -Window $timer.Window -Path $timerOut }
    finally { $timer.Window.Close(); $script:ActiveTimerUi = $null }

    # The fourth window is the diary. With -Fake it gets an invented pot: on a machine where the
    # diary has never been turned on the real one is empty, and an empty window shows nothing.
    $statsOut = Join-Path $timerDir ([System.IO.Path]::GetFileNameWithoutExtension($Out) + '-stats.png')
    $stats = New-StatsWindow -Store $(if ($Fake) { New-FakeDiary } else { Get-ActivityStore }) -Days 7
    try { Save-WindowSnapshot -Window $stats.Window -Path $statsOut }
    finally { $stats.Window.Close(); $script:ActiveStatsUi = $null }
}
finally {
    $ui.Window.Close()
}
