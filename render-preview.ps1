#Requires -Version 5.1

<#
.SYNOPSIS
    Renders every window of DeskModes to PNG, without showing one on the desk.

.DESCRIPTION
    A development tool: it builds the windows with the same New-SettingsWindow,
    New-ModeEditorWindow, New-TimerWindow and New-RuleEditorWindow the tray uses, lays them out in memory and draws them to files. So the interface
    can be looked at without starting the app, opening Settings by hand and having a
    real desk in front of you - and with -Fake, for a desk that is not here at all.

    Theme and accent colour come from the system, exactly as in the real window.

    Seven files are written beside <name>.png, which is the Settings window on its
    first page:

        -modes, -rules, -behavior,
        -diary, -about                      the other pages of that window
        -editor                             the mode editor
        -rule                               the rule editor
        -timer                              the shutdown timer popup

    README shows five of them, and six live in docs/images/ (those five and the Modes
    page). The rest are for looking at while working on a window, and are not
    committed.

.PARAMETER Out
    Where to write the Settings window on its first page. The other seven go next to
    it with the suffixes above. Defaults to preview-settings.png beside the scripts.

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
    Every window for an invented desk, written beside the scripts.

.EXAMPLE
    .\render-preview.ps1 -Fake -EditorMode all -Out C:\tmp\ui.png
    Writes C:\tmp\ui.png and its seven neighbours; C:\tmp\ui-editor.png shows the
    editor of "All displays" - the short form, without a name to argue about.
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
if (-not $env:DESKMODES_LOG_FILE) {
    $env:DESKMODES_LOG_FILE = Join-Path $env:TEMP 'deskmodes-render-preview.log'
}

. (Join-Path $PSScriptRoot 'DisplayCore.ps1')
. (Join-Path $PSScriptRoot 'WindowLayout.ps1')
. (Join-Path $PSScriptRoot 'Activity.ps1')
. (Join-Path $PSScriptRoot 'SettingsDialog.ps1')

# A real window is kept inside the work area of its monitor: it must not grow off the bottom
# of the screen. Here the windows are shown at -10000 on purpose, so that nothing flashes on
# the desk while it is photographed - and being pulled back is exactly what would flash.
$script:KeepWindowsInWorkArea = $false

# And the Settings window is photographed at the size its MARKUP gives it, not at the size this
# particular desk happened to leave it: ui-state.json is a note about one machine, and the
# pictures in README must not be a picture of the author's window. Pointed at a file in TEMP
# rather than switched off, so Save-UiState on close still has somewhere harmless to write.
$script:UiStateFile = Join-Path $env:TEMP 'deskmodes-render-preview-ui-state.json'
if (Test-Path $script:UiStateFile) { Remove-Item $script:UiStateFile -Force }

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

# The invented monitors are plugged into nothing, so the registry has never heard of them and
# their EDID cannot be read. Their sizes go straight into the cache the real lookup keeps - and
# they are the point of the picture: the 4K is the SMALLEST panel of the three.
function Set-FakeSizes {
    $script:MonitorSizeCache['fake-ultrafine'] = [pscustomobject]@{ WidthCm = 53; HeightCm = 30; Inches = 24.0 }
    $script:MonitorSizeCache['fake-asus']      = [pscustomobject]@{ WidthCm = 60; HeightCm = 34; Inches = 27.2 }
    $script:MonitorSizeCache['fake-ultragear'] = [pscustomobject]@{ WidthCm = 60; HeightCm = 34; Inches = 27.2 }
}

function New-FakeDiary {
    # Ten days of an invented fortnight. Enough that every section of the diary window has
    # something in it and the hour histogram has a shape rather than one spike — an empty diary
    # renders as an empty window, and an empty window shows nothing about the layout.
    $store = [ordered]@{ days = [ordered]@{} }
    $today = (Get-Date).Date
    $work = @(
        @{ App = 'Code';    Display = 'LG ULTRAFINE'; Mode = 'combo:Work'; Hour = 10; Seconds = 7200 }
        @{ App = 'chrome';  Display = 'LG ULTRAGEAR'; Mode = 'combo:Work'; Hour = 12; Seconds = 3600 }
        @{ App = 'Code';    Display = 'LG ULTRAFINE'; Mode = 'combo:Work'; Hour = 15; Seconds = 5400 }
        @{ App = 'Teams';   Display = 'LG ULTRAGEAR'; Mode = 'combo:Work'; Hour = 17; Seconds = 1800 }
        @{ App = 'cs2';     Display = 'XG27AQDMGR';   Mode = 'solo:XG27AQDMGR'; Hour = 21; Seconds = 4200 }
        @{ App = 'spotify'; Display = 'LG ULTRAGEAR'; Mode = 'all'; Hour = 23; Seconds = 900 }
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
                             -Seconds $seconds -Hour ([int]$span.Hour)
        }
        $day.switches = 6 + ($offset % 3)
        $day.longest = 9000
    }
    return $store
}

$settings = Get-DisplaySettings
if ($Fake) {
    $state = @(New-FakeState)
    Set-FakeSizes
    # The diary page is built by the Settings window out of the real pot. On a machine where the
    # diary has never been turned on that pot is empty, and an empty page shows nothing about the
    # drawing - so the invented one is put where Get-ActivityStore will find it.
    $script:ActivityStore = New-FakeDiary
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
    # The same for everything else a mode can carry. Set on the combo specifically, because that
    # is whose editor gets rendered by default — and because a mode with something set is what
    # opens the editor's fold, so the image shows what is behind it instead of a shut caption.
    $settings.contrast = [ordered]@{ 'combo:Work' = 70; 'combo:Movie night' = 65 }
    $settings.audio = [ordered]@{ 'combo:Work' = 'ULTRAFINE'; 'combo:Movie night' = 'ULTRAFINE' }
    $settings.hooks = [ordered]@{
        'combo:Work' = [ordered]@{ before = ''; after = 'C:\tools\work-lights.cmd' }
        'combo:Movie night' = [ordered]@{ before = ''; after = 'C:\tools\lights-out.cmd' }
    }
    # A remembered picture preset, so the card shows both of its states. Invented, like the desk:
    # no monitor here is real enough to be asked.
    $settings.picture = [ordered]@{ 'combo:Movie night' = [ordered]@{ 'LG ULTRAFINE' = '0x15:45' } }
    # "Movie night" is the combination whose editor gets photographed, and it has ONE display: with
    # two, the editor unfolded is 1460 points tall - taller than a 1440p work area - and a window
    # taller than the screen comes out of the renderer with its last two boxes cut off.
    $settings.brightness['combo:Movie night'] = [ordered]@{ 'LG ULTRAFINE' = 40 }
    # And two rules, so the Rules card is a list rather than its empty line: one of each kind,
    # and one of them switched off — a rule that is off has to look off.
    $settings.rules = @(
        [ordered]@{ when = 'process'; process = 'cs2'; minutes = 0
                    mode = 'solo:XG27AQDMGR'; back = ''; enabled = $true }
        [ordered]@{ when = 'idle'; process = ''; minutes = 30
                    mode = 'combo:Movie night'; back = 'combo:Work'; enabled = $false }
    )
    $settings.reapply.onPlug = 'all'
}
else {
    # The same desk the tray hands the window, roster and all: a monitor switched off at its own
    # button has a card here too, and a picture of the window without it is a picture of a
    # different window (see Get-DeskDisplays).
    $state = @(Get-DeskDisplays -State @(Get-DisplayState))
}

# The name of another image beside the first one: "<out>-about.png".
#
# ChangeExtension($Out, $null) is no good here: PowerShell hands back an empty string instead of
# $null, and the dot from the extension stays in the name. The folder gets a '.' fallback because
# for a bare file name (-Out ui.png) Split-Path -Parent hands back an empty string, and Join-Path
# will not take it - which is how the second image used to die once the first was written.
function Get-OutPath {
    param([string]$Suffix)

    $dir = Split-Path -Parent $Out
    if (-not $dir) { $dir = '.' }
    return Join-Path $dir ([System.IO.Path]::GetFileNameWithoutExtension($Out) + $Suffix + '.png')
}

# The window has to be SHOWN: the system is what measures the element tree, and for a window that
# was never shown those measurements stay zero. It goes up off the edge of the desk and without
# being activated - the image comes out, and nothing flashes on the screen.
function Show-WindowOffscreen {
    param($Window)

    # A window that sizes itself to its content is never taller than the work area - past that it
    # scrolls. For an image scrolling only gets in the way: it exists to show the WHOLE window at
    # once. The Settings window is not one of those any more and takes the size its markup gives.
    $Window.MaxHeight = [double]::PositiveInfinity
    # The editor's scrollbar comes off too - Hidden and not Disabled. Disabled makes the viewer
    # measure its content against the room it HAS, which is the one thing wanted here: the content
    # then reports the size it was squeezed into, SizeToContent believes it, and the image comes out
    # with the last two boxes of the editor cut off. Hidden leaves the measurement honest and only
    # takes the bar away.
    $viewer = $Window.FindName('Scroll')
    if ($viewer) { $viewer.VerticalScrollBarVisibility = 'Hidden' }
    $Window.WindowStartupLocation = 'Manual'
    $Window.ShowActivated = $false
    $Window.ShowInTaskbar = $false
    $Window.Left = -10000
    $Window.Top = -10000
    $Window.Show()
}

# One image of a window that is already up. Separate from showing it, because the Settings window
# is photographed five times over - once per page - and showing it again would be a second window.
function Save-WindowImage {
    param($Window, [string]$Path)

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

function Save-WindowSnapshot {
    param($Window, [string]$Path)

    Show-WindowOffscreen -Window $Window
    Save-WindowImage -Window $Window -Path $Path
}

$modes = @(Get-DialogModes -State $state -Settings $settings)
$ui = New-SettingsWindow -Modes $modes -Settings $settings -State $state

try {
    # The Settings window is five images, one per page: the pane is the window's shape now, and a
    # single picture of it would show one fifth of what there is.
    Show-WindowOffscreen -Window $ui.Window
    foreach ($page in $script:UiPages) {
        Set-UiPage -Ui $ui -Page $page
        Save-WindowImage -Window $ui.Window -Path $(if ($page -eq 'desk') { $Out } else { Get-OutPath ('-' + $page) })
    }
    Set-UiPage -Ui $ui -Page 'desk'

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
                                   -Hotkeys $ui.Hotkeys -Levels $ui.Levels -Contrast $ui.Contrast `
                                   -Picture $ui.Picture -Audio $ui.Audio -Hooks $ui.Hooks `
                                   -Dark (Test-DarkTheme)
        try {
            # "-editor" and not "-mode": the Modes PAGE is "-modes", and two names a letter
            # apart are two files nobody can tell apart in a folder.
            Save-WindowSnapshot -Window $ed.Window -Path (Get-OutPath '-editor')
        }
        finally { $ed.Window.Close() }
    }

    # The third window is the timer. Small, but its own: the slider, the pills and the
    # time on the clock can only be seen in an image, not in the markup.
    $timerOut = Get-OutPath '-timer'
    $timer = New-TimerWindow -Action 'sleep' -Minutes 90
    try { Save-WindowSnapshot -Window $timer.Window -Path $timerOut }
    finally { $timer.Window.Close(); $script:ActiveTimerUi = $null }

    # The fifth is the rule editor. An invented rule rather than the first real one: it has to
    # show a condition, a target and a way back all filled in, and a desk with no rules on it
    # would render three empty dropdowns.
    $ruleOut = Get-OutPath '-rule'
    $rule = [ordered]@{ when = 'process'; process = 'cs2'; minutes = 20
                        mode = [string]@($modes)[0].Key; back = ''; enabled = $true }
    $ruleEd = New-RuleEditorWindow -Rule $rule -Modes (Get-RuleTargetModes -Ui $ui) -Dark (Test-DarkTheme)
    try { Save-WindowSnapshot -Window $ruleEd.Window -Path $ruleOut }
    finally { $ruleEd.Window.Close(); $script:ActiveRuleUi = $null }
}
finally {
    $ui.Window.Close()
}
