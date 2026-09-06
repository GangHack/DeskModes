#Requires -Version 5.1

<#
.SYNOPSIS
    DeskModes: the tray icon that switches the displays on your desk.

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
[CmdletBinding()]
param([switch]$NoHotkeys)

$ErrorActionPreference = 'Stop'

# Started before everything else: what falls inside it is the compilation (or the load
# from cache) of the native types, the building of the form, and the first state query.
# The total goes to the log as "tray: started in N ms" — a permanent watch on how fast
# the shortcuts become usable after logging in to Windows.
$script:StartWatch = [System.Diagnostics.Stopwatch]::StartNew()

. (Join-Path $PSScriptRoot 'DisplayCore.ps1')
. (Join-Path $PSScriptRoot 'Diagnostics.ps1')
. (Join-Path $PSScriptRoot 'WindowLayout.ps1')
. (Join-Path $PSScriptRoot 'Activity.ps1')
. (Join-Path $PSScriptRoot 'SettingsDialog.ps1')

# The zone mark. Windows marks everything downloaded with a Zone.Identifier stream.
# That does not break startup by itself — the .cmd calls powershell with
# -ExecutionPolicy Bypass, and Bypass does not look at the zone — but the mark stays on
# the files and gets in the way later: the attachment manager asks about Displays.cmd on
# every run, and whoever calls .\Set-Display.ps1 from their own console runs into "not
# digitally signed" under their own policy. The check costs one stream lookup and in
# ordinary life is false; when it is true, the mark comes off all our scripts at once.
#
# The tell is not one file but any of ours: whoever Windows complained about specifically
# for Displays.ps1 takes the mark off that one file (Properties -> Unblock), and the
# folder would have stayed marked — while the tell is already gone. And Unblock-File with
# -ErrorAction Continue: under $ErrorActionPreference = 'Stop' one stubborn file would cut
# the pipeline short, and there will be no second time.
try {
    $marked = $false
    foreach ($name in 'Displays.ps1', 'Displays.cmd', 'DisplayCore.ps1', 'Set-Display.ps1', 'SettingsDialog.ps1') {
        if (Get-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) {
            $marked = $true
            break
        }
    }
    if ($marked) {
        # Only our own .ps1 and .cmd. Unblock-File takes the mark off ANY kind of file,
        # and on an .exe, a .docx or an .xlsm that mark is SmartScreen, the attachment
        # manager and Protected View: by clearing it across the whole folder the tool
        # would silently disarm somebody else's download that happened to sit there (the
        # folder gets put into a shared Tools\, and an update gets unpacked over it). The
        # mark gets in the way of exactly two kinds: .ps1 runs into the signing policy,
        # .cmd into the attachment manager; app.ico and README never needed unblocking.
        #
        # Where-Object, not -Include: with -LiteralPath that one is silently ignored and
        # everything gets unblocked — measured, and the mistake makes no sound.
        Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File |
            Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.cmd' } |
            Unblock-File -ErrorAction Continue
        Write-DisplayLog 'startup: removed Mark-of-the-Web from the scripts'
    }
}
catch { Write-DisplayLog "startup: could not remove Mark-of-the-Web - $($_.Exception.Message)" }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppName = 'DeskModes'

# One instance: otherwise only the first would claim the shortcuts, and the second would
# hang there as a useless icon.
$script:AppMutex = New-Object System.Threading.Mutex($false, 'Local\DeskModesTray')
if (-not $script:AppMutex.WaitOne(0)) {
    [System.Windows.Forms.MessageBox]::Show(
        "$script:AppName is already running - look for its icon in the notification area.",
        $script:AppName, 'OK', 'Information') | Out-Null
    return
}

$script:Settings = Get-DisplaySettings
# Before the first menu, the first balloon and the first window: everything below asks Get-Text,
# and Get-Text with nobody having said otherwise follows Windows rather than the setting.
[void](Initialize-Language -Code $script:Settings.language)

# Settings are reached only through these functions. Event handlers are created with
# .GetNewClosure() inside other blocks, and a $script:Settings reference inside them
# resolves not to the script's variable but to nothing — which is how the Settings window
# got $null and died. A function, on the other hand, always runs in script scope, no
# matter who called it.
function Get-ActiveSettings {
    if (-not $script:Settings) { $script:Settings = Get-DisplaySettings }
    return $script:Settings
}

function Set-ActiveSettings {
    param($NewSettings)
    $script:Settings = $NewSettings
}

# --- the state cache --------------------------------------------------------
# The menu has to open instantly. A slow query right inside the Opening handler breaks
# an ordinary right-click on the icon: Windows decides the menu never showed and closes
# it. A query through CCD costs tens of milliseconds, but the cache is needed anyway —
# the menu opens without a single request to the system, and it is refreshed on the
# configuration-changed event.

$script:StateCache = $null
# A successful refresh advances this even when the desk itself is unchanged. Rule ownership reads
# it across Invoke-Mode so a failed refresh cannot pass the old source desk off as the switch result.
$script:StateCacheGeneration = 0

# Device path -> name, everything seen during this run. Needed to name a monitor that is
# ALREADY GONE from the state: one the driver removed from the bus vanishes from the
# enumeration entirely, and asking for its name at the moment it goes is too late.
#
# Declared here, beside the cache it is an index over, because it is filled from the same
# walk — and so that the very first refresh at startup already fills it. Filling it from
# the desk snapshot instead left it empty until the run's first configuration change, which
# is precisely the event that needs it: a monitor dropping off the bus overnight was logged
# as the nameless "a display".
$script:KnownLabels = @{}

# The desk as the INTERFACE shows it: the state plus the monitors the roster remembers (see
# Get-DeskDisplays). Cached beside the state and rebuilt with it, because building it reads
# known-displays.json off the disk — and the menu's Opening handler is the one place here that
# must not go to disk at all, which is what the state cache exists for.
$script:DeskCache = $null

function Update-StateCache {
    try {
        $script:StateCache = @(Get-DisplayState)
        # Who is CONNECTED (not who is on): a change in this set is what shows a monitor
        # was plugged in or pulled out, and that is the only thing worth reacting to —
        # the ones that are on we change ourselves on every switch (see Get-ReapplyDecision).
        $script:PresentIds = @($script:StateCache | Where-Object { -not $_.Disconnected } |
                               ForEach-Object { [string]$_.Id } | Sort-Object)

        # The names are remembered ALWAYS, on every refresh: the next disappearance will name
        # the monitor from right here, and by then it is out of the enumeration.
        foreach ($m in $script:StateCache) {
            if ($m.Id) { $script:KnownLabels[[string]$m.Id] = [string]$m.Label }
        }

        # And the same thing written down, so the NEXT run knows a monitor that is off the bus
        # before it has ever seen it (Get-KnownDisplays). Here rather than in Get-DisplayState:
        # that one is on the switch path, where every millisecond is measured and printed. The
        # file is only rewritten when it would actually change, which is about once a day.
        [void](Update-KnownDisplays -State $script:StateCache)

        # The roster has just been read and brought up to date, so this is the moment to build
        # the desk out of it: everybody who asks later (the menu, the Settings window, the
        # startup migration) gets it without going near the disk again.
        $script:DeskCache = @(Get-DeskDisplays -State $script:StateCache)
        $script:StateCacheGeneration++
    }
    catch {
        Write-DisplayLog "cache: could not refresh display state - $($_.Exception.Message)"
    }
}

# Output name -> monitor name, for the diary: it gets "\\.\DISPLAY1" from the system,
# and a person needs "LG ULTRAGEAR".
function Get-DisplayNameMap {
    $map = @{}
    foreach ($m in @(Get-CachedState)) {
        if ($m.Active -and $m.Output) { $map[[string]$m.Output] = [string]$m.Label }
    }
    return $map
}

# The key of the mode the desk is in right now, or an empty string. Both the rules and
# the diary need it; the state comes from the cache, the disk is not read.
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

# The same, with the remembered monitors in it — what every window and menu shows. An empty
# array and not $null when the refresh failed: the callers hand this straight to Get-DisplayModes
# and to the Settings window, and @($null) is an array holding one nothing.
function Get-CachedDesk {
    if ($null -eq $script:DeskCache) { Update-StateCache }
    if ($null -eq $script:DeskCache) { return @() }
    return $script:DeskCache
}

# Putting the refresh rate back after the system dropped it. A function of its own rather
# than code inside the handler: a handler is a block, and $script: inside blocks created
# with .GetNewClosure() does not resolve (see Get-ActiveSettings).
function Invoke-ModeWatch {
    if (-not (Get-ActiveSettings).maximizeRefresh) { return }
    try {
        $fixed = @(Restore-BestModes)
        if ($fixed.Count -gt 0) {
            Update-StateCache
            Show-Balloon (Get-Text -Key 'balloon.refresh') (Get-Text -Key 'balloon.refresh.body' -Values @(($fixed -join ', ')))
        }
    }
    catch {
        Write-DisplayLog "watch: failed - $($_.Exception.Message)"
    }
}

# --- rules ------------------------------------------------------------------
# "When this happens, become that": all the logic is in Get-RuleDecision (DisplayCore.ps1),
# a pure function and under tests. Here there is only fact-gathering and carrying it out.
#
# The polling lives in the tray's existing 15-second timer: no timer of its own is needed,
# and Get-Process costs single-digit milliseconds.
#
# "We were the ones who switched" is remembered separately from the current mode.
# Otherwise, after a switch by hand during a game, leaving the game would drag the screens
# somewhere the person never asked to see them.

$script:RuleOwnedIndex = -1
$script:RuleOwnedBack = ''
# WHO holds the desk, as against where they sit in the list. Rules get added and deleted — by hand and
# from the Settings window — while one of them is holding the desk, and an index on its own then points at
# whoever slid into that slot: the desk would go back to a stranger's "back". See Get-RuleSignature.
$script:RuleOwnedSig = ''
# Whether the switch that was to take the desk actually went through. A claim is kept even after a refusal
# that asking again will not cure — otherwise the rule fires on every tick and every tick is a balloon —
# and this is what keeps the state honest while it is kept: the desk is nobody's, so the next tick must
# not read it as "the displays were changed by hand" and say so about a person who touched nothing.
$script:RuleOwnedTaken = $false
# The physical desk left by our switch. Mode keys are names and can alias the same set; a partial
# switch can also leave a subset of the target or a source display that refused to turn off. The
# claim records both facts so the next tick can tell those results from a person's different desk.
$script:RuleOwnedDesk = $null
# How many times the way back has been tried. The way back is the one path that has to keep asking: the
# condition has ended, so nothing comes through here again later, and a desk left standing in the rule's
# mode stays there for good. Bounded all the same — see $script:AutoRetryLimit.
$script:RuleReturnTries = 0
# The last "there will be nowhere to go back to" complaint: without this it would go to
# the log every fifteen seconds for as long as the game is open.
$script:RuleLastBlocked = ''

function Reset-RuleOwnership {
    $script:RuleOwnedIndex = -1
    $script:RuleOwnedBack = ''
    $script:RuleOwnedSig = ''
    $script:RuleOwnedTaken = $false
    $script:RuleOwnedDesk = $null
    $script:RuleReturnTries = 0
}

# Device IDs requested by a mode, captured before switching while the complete source state is still
# available. Capturing a mode key afterwards is too late: the active-mode lookup may call a partial
# result a solo mode, or pick another combination with the same members.
function Get-RuleModeMemberIds {
    param([string]$ModeKey, $State)

    if (-not $ModeKey -or -not $State) { return @() }
    $mode = @(Get-DisplayModes -State $State -Settings (Get-ActiveSettings) |
              Where-Object { [string]$_.Key -eq $ModeKey } | Select-Object -First 1)[0]
    if (-not $mode) { return @() }
    return @(Get-ModeMembers -Mode $mode -State $State |
             ForEach-Object { [string]$_.Id } | Where-Object { $_ } | Sort-Object -Unique)
}

# A claim has anchors that our switch actually put in the requested set, and an allowed envelope made
# from the requested set plus displays initially left on. This accepts A -> AB as B wakes, and ABC ->
# AB as C finally goes out, without accepting A -> B or a newly introduced D. Known false means the
# cache could not prove what the switch left; uncertainty must not be called a manual override.
function New-RuleDeskClaim {
    param($RequestedIds, $State, [bool]$Fresh, [int]$Generation = 0)

    $requested = @($RequestedIds | Where-Object { $_ } | Sort-Object -Unique)
    $observed = @($State | Where-Object { $_ -and $_.Active } |
                  ForEach-Object { [string]$_.Id } | Where-Object { $_ } | Sort-Object -Unique)
    $allowed = @($observed + $requested | Sort-Object -Unique)
    $unknown = [pscustomobject]@{
        Known = $false; Requested = $requested; Anchors = @(); Allowed = $allowed
        Generation = $Generation
    }
    if (-not $Fresh -or $observed.Count -eq 0) { return $unknown }
    $anchors = @($observed | Where-Object { $requested -contains $_ })
    if ($anchors.Count -eq 0) { return $unknown }
    return [pscustomobject]@{
        Known = $true; Requested = $requested; Anchors = $anchors; Allowed = $allowed
        Generation = $Generation
    }
}

function Get-RuleDeskRelation {
    param($Claim, $State, [int]$Generation = 0)

    if (-not $Claim) { return '' }
    if (-not $State) { return 'unknown' }
    $active = @($State | Where-Object { $_ -and $_.Active } |
                ForEach-Object { [string]$_.Id } | Where-Object { $_ } | Sort-Object -Unique)
    if ($active.Count -eq 0) { return 'unknown' }
    if (-not $Claim.Known) {
        # A failed post-switch refresh leaves the source cache in place. Wait for a later successful
        # cache generation before resolving it, then require both a requested anchor and the source plus
        # target envelope captured at the switch. The stale source itself proves neither fact.
        if ($Generation -le [int]$Claim.Generation) { return 'unknown' }
        foreach ($id in $active) {
            if (@($Claim.Allowed) -notcontains [string]$id) { return 'different' }
        }
        $anchors = @($active | Where-Object { @($Claim.Requested) -contains $_ })
        if ($anchors.Count -eq 0) { return 'different' }
        $Claim.Anchors = $anchors
        $Claim.Known = $true
        $Claim.Generation = $Generation
    }
    foreach ($id in @($Claim.Anchors)) { if ($active -notcontains [string]$id) { return 'different' } }
    foreach ($id in $active) { if (@($Claim.Allowed) -notcontains [string]$id) { return 'different' } }
    return 'same'
}

function Invoke-RulesCheck {
    $rules = @((Get-ActiveSettings).rules)
    # No rules and nothing claimed: the ordinary case, and the cheapest way out of it. Not while a rule
    # is holding the desk, though — deleting the last rule while it holds one is exactly when the desk has
    # to be handed back, and Get-RuleDecision has an answer for that which this used to jump straight over.
    if ($rules.Count -eq 0 -and $script:RuleOwnedIndex -lt 0) { return }

    # Processes are asked for in ONE call for all the rules: Get-Process without a name
    # costs the same as with one, and there can be a dozen rules.
    $needProcesses = $false
    foreach ($r in $rules) { if ([string]$r.when -eq 'process') { $needProcesses = $true; break } }
    $processes = @()
    if ($needProcesses) {
        $processes = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName })
    }

    # The connected displays out of the cache, never a fresh query: this runs every fifteen seconds,
    # and the cache was refreshed by the very event a plug or unplug raises.
    $state = @(Get-CachedState)
    $connected = @($state | Where-Object { $_ -and -not $_.Disconnected } |
                   ForEach-Object { [pscustomobject]@{ Label = [string]$_.Label; ShortId = [string]$_.ShortId } })

    $facts = [pscustomobject]@{
        Processes   = $processes
        IdleSeconds = $(try { [NativeActivity]::IdleSeconds() } catch { 0 })
        Connected   = $connected
    }

    $deskRelation = Get-RuleDeskRelation -Claim $script:RuleOwnedDesk -State $state `
                                                -Generation $script:StateCacheGeneration
    $decision = Get-RuleDecision -Rules $rules -Facts $facts -CurrentMode (Get-CurrentModeKey) `
                                 -OwnedIndex $script:RuleOwnedIndex -OwnedBack $script:RuleOwnedBack `
                                 -OwnedSignature $script:RuleOwnedSig -OwnedTaken $script:RuleOwnedTaken `
                                 -OwnedDeskRelation $deskRelation -ReturnTries $script:RuleReturnTries

    switch ($decision.Action) {
        'switch' {
            $script:RuleOwnedIndex = [int]$decision.RuleIndex
            $script:RuleOwnedBack = [string]$decision.Back
            $script:RuleOwnedSig = Get-RuleSignature -Rule $rules[[int]$decision.RuleIndex]
            $script:RuleOwnedTaken = $false
            $script:RuleReturnTries = 0
            $script:RuleLastBlocked = ''
            $requestedIds = @(Get-RuleModeMemberIds -ModeKey ([string]$decision.Mode) -State $state)
            $generationBefore = $script:StateCacheGeneration
            Write-DisplayLog ("rule: {0} -> {1}" -f $decision.Reason, $decision.Mode)
            Invoke-Mode $decision.Mode -Auto

            # Three different answers, three different claims to make.
            if ($script:LastSwitch.Outcome -eq 'busy') {
                # Not an answer at all, but "ask again in a moment" — and an ordinary one here: a rule
                # fires on the very events the refresh-rate watchdog wakes on, and that one holds
                # Local\DeskModesSwitch for about a second afterwards. Owning a desk we never took cost
                # the rule its whole turn, so we claim nothing and the next tick fires the rule again.
                Reset-RuleOwnership
            }
            elseif ($script:LastSwitch.Outcome -eq 'refused') {
                # It will not come right by being asked again fifteen seconds later, and a retry loop
                # there is a balloon every fifteen seconds. So the claim stands and stops the rule from
                # firing again — but -Taken false, so nothing anywhere takes the desk for ours.
                $script:RuleOwnedTaken = $false
            }
            else {
                # 'done' or 'partial'. The desk moved, so it is the rule's now: a display that did not
                # come up does not undo the ones that did.
                $script:RuleOwnedTaken = $true
                $fresh = ($script:StateCacheGeneration -gt $generationBefore)
                $script:RuleOwnedDesk = New-RuleDeskClaim -RequestedIds $requestedIds `
                    -State @(Get-CachedState) -Fresh $fresh -Generation $script:StateCacheGeneration
            }
        }
        'return' {
            if (-not $decision.Mode) { Reset-RuleOwnership }
            else {
                Write-DisplayLog ("rule: {0} -> back to {1}" -f $decision.Reason, $decision.Mode)
                Invoke-Mode $decision.Mode -Auto
                $script:RuleReturnTries++
                # The same question at the other end, and it matters more here: letting go before the way
                # back has gone through leaves the desk in the rule's mode for good, because the
                # condition has ended and nothing comes back this way to try again. The test used to be
                # "was it a busy mutex" — and a throw is not one, so Windows refusing the configuration
                # once was enough to strand a person on the game display. Now it is the only test that
                # answers the question asked: did the desk really come back.
                if ($script:LastSwitch.Ok) { Reset-RuleOwnership }
                elseif ($script:RuleReturnTries -ge $script:AutoRetryLimit) {
                    # And it does stop asking. Four goes over about a minute cover a busy mutex and a
                    # display still waking; past that the reason is not going away, and a desk is
                    # something a person can move themselves — a warning balloon every fifteen seconds
                    # for the rest of the day is not.
                    Write-DisplayLog ("rule: gave up handing the desk back to {0} after {1} attempts" -f `
                        $decision.Mode, $script:RuleReturnTries)
                    Reset-RuleOwnership
                }
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

# --- the icon ---------------------------------------------------------------
# One app.ico file for everything: the tray, the Start-menu shortcut and the startup one.
# Our own icon rather than a system one: in the Start menu it must not blend into the
# Windows icons.
# The size is the one the system asks for small icons (at 150% scale that is no longer
# 16 px), and the .ico hands back a fitting one out of the nine prepared — stretched from
# a single size it would look like mush. To redraw: .\Make-Icon.ps1

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

# --- how the menu looks -----------------------------------------------------
# Drawn by ModernMenuRenderer (DisplayCore.ps1): a flat background matching the system
# theme, rounded highlight, a check mark in the accent colour. The stock System renderer
# is stuck in Windows 7, and a menu drawn with it looks like it came from XP.

# The menu fonts, with a cache. Segoe UI Variable arrived in Windows 11; on Windows 10 it
# is not there, and GDI+ silently substitutes Microsoft Sans Serif for a name it does not
# know — which is why the family is checked against the list of installed ones.
$script:UiFonts = @{}

function Get-UiFont {
    param([single]$Size = 9.75, [double]$Scale = 1.0, [switch]$Semibold)

    $effectiveSize = [single]($Size * $Scale)
    $key = '{0}|{1}' -f $effectiveSize, [bool]$Semibold
    if ($script:UiFonts.Contains($key)) { return $script:UiFonts[$key] }

    $names = $(if ($Semibold) { @('Segoe UI Variable Text Semibold', 'Segoe UI Semibold') }
               else           { @('Segoe UI Variable Text', 'Segoe UI') })
    $installed = [System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name }
    $pick = 'Segoe UI'
    foreach ($name in $names) {
        if ($installed -contains $name) { $pick = $name; break }
    }

    $font = New-Object System.Drawing.Font $pick, $effectiveSize
    $script:UiFonts[$key] = $font
    return $font
}

# The monitor status dots: green — on and at its maximum, amber — the rate is below the
# maximum, grey — off, an outline — not connected. The text says the same in words; the
# dot gives it in one glance. One is drawn per kind, and they live until the process ends.
$script:StatusDots = @{}

function Get-StatusDot {
    param([string]$Kind, [double]$Scale = 1.0)

    $px = Get-ScaledPx -Value 16 -Scale $Scale
    $key = '{0}|{1}' -f $Kind, $px
    if ($script:StatusDots.Contains($key)) { return $script:StatusDots[$key] }

    $bmp = New-Object System.Drawing.Bitmap $px, $px
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $k = $px / 16.0
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        switch ($Kind) {
            'on'    { $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(63, 185, 80))
                      $g.FillEllipse($b, 4.5 * $k, 4.5 * $k, 7.0 * $k, 7.0 * $k); $b.Dispose() }
            'below' { $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(210, 153, 34))
                      $g.FillEllipse($b, 4.5 * $k, 4.5 * $k, 7.0 * $k, 7.0 * $k); $b.Dispose() }
            'off'   { $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(138, 138, 138))
                      $g.FillEllipse($b, 4.5 * $k, 4.5 * $k, 7.0 * $k, 7.0 * $k); $b.Dispose() }
            default { $p = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(138, 138, 138)), ([single](1.4 * $k))
                      $g.DrawEllipse($p, 5.0 * $k, 5.0 * $k, 6.0 * $k, 6.0 * $k); $p.Dispose() }
        }
    }
    finally { $g.Dispose() }

    $script:StatusDots[$key] = $bmp
    return $bmp
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Font = Get-UiFont
$menu.ShowImageMargin = $true
$menu.ImageScalingSize = New-Object System.Drawing.Size 16, 16
$menu.Padding = New-Object System.Windows.Forms.Padding 4, 6, 4, 6
$tray.ContextMenuStrip = $menu

# A tray menu is dismissed by a click ELSEWHERE through one route only: WM_ACTIVATEAPP, which
# Windows sends when our process stops being the foreground application. NotifyIcon asks to
# become that one — SetForegroundWindow on its own hidden window — before it shows the menu,
# and Windows is free to refuse: the foreground belongs to whoever the person was last typing
# into. On a refusal the menu is drawn while nothing of ours is active, no deactivation ever
# arrives, and the menu stands there until it is clicked. That is the "the menu will not close"
# report, and it leaves no other trace: nothing throws and the next open usually works.
#
# So an open that finds somebody else holding the foreground writes down who. One line, on the
# anomaly only — the healthy case is our own process and says nothing.
function Write-MenuForegroundNote {
    try {
        $fg = [NativeForeground]::GetForegroundWindow()
        if ($fg -eq [IntPtr]::Zero) {
            Write-DisplayLog 'menu: opened with no foreground window at all - a click outside may not close it'
            return
        }
        $owner = [uint32]0
        [void][NativeWindows]::GetWindowThreadProcessId($fg, [ref]$owner)
        if ($owner -eq $PID) { return }
        $who = $(try { (Get-Process -Id $owner -ErrorAction Stop).ProcessName } catch { "pid $owner" })
        Write-DisplayLog ("menu: opened while {0} holds the foreground - a click outside may not close it" -f $who)
    }
    catch { }   # a note about the menu must never be the reason the menu itself fails
}

# Only DWM can round the corners of the menu window (and only on Windows 11; on 10 the
# call silently does nothing). A handle exists only for an open menu — which is why this
# is here rather than at creation.
$menu.add_Opened({
    try { [NativeTheme]::TryRoundCorners($menu.Handle, $true) } catch { }   # not Windows 11 — the corners stay square
    Write-MenuForegroundNote
})

function Show-Balloon {
    # Always — for answering an explicit action by a person. Notifications turned off mute
    # Info, and "About DeskModes" went silent because of it: the menu item is clicked and
    # nothing happens. A click must always answer; background messages need not.
    param([string]$Title, [string]$Text, [string]$Kind = 'Info', [switch]$Always)
    # Through the function, not $script:Settings: see Get-ActiveSettings. One way of reading the settings
    # for the whole file — the three places that went straight to the variable worked only because they
    # happen to be functions, and the next one copied from them might not be.
    if (-not $Always -and -not (Get-ActiveSettings).notifications -and $Kind -eq 'Info') { return }
    $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::$Kind
    $tray.BalloonTipTitle = $Title
    $tray.BalloonTipText = $Text
    $tray.ShowBalloonTip(4000)
}

# Whether this run of the tray has seen a single switch. The startup mode restore needs it:
# a person manages to press a shortcut before our timer fires, and their choice is newer
# than ours.
$script:SwitchedOnce = $false

# What the LAST call to Invoke-Mode answered, in the vocabulary New-SwitchResult lays down
# (DisplayCore.ps1): Ok is "the desk is in that mode now", Retry is "asking again in a moment can change
# this", Outcome is the same answer as a word. Invoke-Mode replies to every outcome with a balloon and
# nothing else, so the two callers that have to know what to do next read it here — the rules, deciding
# whether the desk is theirs, and the postponed rebuild, deciding whether to keep its intent.
#
# A field rather than a return value: five of the six call sites are event handlers that ignore the
# answer, and a returned object would leak into their output.
#
# ONE field, where two loose booleans used to stand. They were read apart from each other, and the two
# readers built opposite retry policies out of the same answer — see the comment on New-SwitchResult for
# what that cost at both ends.
$script:LastSwitch = New-SwitchFailure -ModeKey '' -Message 'no switch in this run yet'

# How many times an automatic path asks again after a switch that did not go through. The tray's timer
# ticks every fifteen seconds, so four attempts is about a minute: long enough for a display that is
# still waking, or for the refresh-rate watchdog to let go of Local\DeskModesSwitch, and short enough
# that a refusal which will not come right is not a warning balloon every fifteen seconds until bedtime.
$script:AutoRetryLimit = 4

function Invoke-Mode {
    param([string]$Key, [switch]$Auto, [switch]$Silent)

    # "back" is a name for whichever mode was left last, resolved here and nowhere later: the switch
    # itself only knows modes. Nothing left yet is an answer, not a failure - the desk has not moved.
    if ($Key -eq $script:BackHotkeyName) {
        $Key = [string](Get-PreviousModeKey)
        if (-not $Key) {
            Show-Balloon (Get-Text -Key 'balloon.noBack') (Get-Text -Key 'balloon.noBack.body') 'Warning'
            return
        }
    }

    # Only a person's press counts as "a mode was already chosen by hand". The startup restore reads this
    # to stand down, and an automatic switch inside its 1500 ms window — a monitor finishing its wake-up,
    # a rule, a reapply — used to set it, so the restore skipped the boot and the log blamed a person who
    # had touched nothing. Same distinction as -Automatic below, and it has to be drawn in both places.
    if (-not $Auto) { $script:SwitchedOnce = $true }

    # The person switched by hand — so the rule is no longer master of the situation and
    # must put nothing back. We do not fight people: if another set of screens was chosen
    # by hand during a game, that was a deliberate decision.
    #
    # A postponed "assemble the desk" is cancelled for the same reason: it was waiting for
    # the game to end, and in the meantime the person said what they wanted — laying a
    # half-hour-old decision over their choice would be the same fight.
    if (-not $Auto) {
        Reset-RuleOwnership
        $script:ReapplyPending = $null
    }

    $tray.Text = "$script:AppName - " + (Get-Text -Key 'tray.switching')
    # The answer, in one variable and in one vocabulary. A refusal leaves Switch-DisplayMode as an
    # exception, so the catch below turns that into the same shape (New-SwitchFailure): whoever reads the
    # outcome afterwards must not have to know which of the two roads it arrived by.
    #
    # $null until the switch answers, and the catch tells the two cases apart by that: a balloon that
    # will not show — the shell does refuse a tip now and then — must not turn a switch that landed into
    # a refusal, or the diary would lose it and a rule would take a desk it is holding for nobody's.
    $result = $null
    try {
        $keep = -not (Get-ActiveSettings).maximizeRefresh
        # -Automatic travels with -Auto: only a person overwrites the chosen mode. Every
        # automatic path (rules, startup, reapply) calls us with -Auto, so there is no need
        # to list them here one by one.
        $result = Switch-DisplayMode -ModeKey $Key -KeepMode:$keep -Quiet -Automatic:$Auto
        if ($result.Skipped) {
            Show-Balloon (Get-Text -Key 'balloon.skipped') $result.Message 'Warning'
        }
        elseif ($result.Message -and $result.Ok) {
            # -Silent: the set of screens was right anyway, and the layout was all that got
            # fixed. A "Displays switched" balloon on every power-on would be announcing
            # work that never happened.
            if (-not $Silent) { Show-Balloon (Get-Text -Key 'balloon.switched') $result.Message }
        }
        elseif ($result.Message) {
            # A partial failure is a failure too: a monitor that never came up would drop
            # out of the green summary silently.
            Show-Balloon (Get-Text -Key 'balloon.partial') $result.Message 'Warning'
        }
        else {
            # An empty summary means the monitor we wanted never attached at all.
            Show-Balloon (Get-Text -Key 'balloon.nothingUp') (Get-Text -Key 'balloon.nothingUp.body') 'Warning'
        }
    }
    catch {
        # The message was written for a person to read ("That display is not connected right now"), which
        # is why it goes into the balloon whole and into the result beside it. Only when the switch itself
        # is what threw, though — see $result above.
        if ($null -eq $result) { $result = New-SwitchFailure -ModeKey $Key -Message $_.Exception.Message }
        Show-Balloon (Get-Text -Key 'balloon.failed') $_.Exception.Message 'Error'
    }
    finally {
        # Nothing at all came back: Switch-DisplayMode always answers, so this is belt and braces, and the
        # readers below must never be left looking at the answer before last.
        if ($null -eq $result) { $result = New-SwitchFailure -ModeKey $Key -Message 'the switch did not report back' }
        $script:LastSwitch = $result
        Update-TrayText
        Update-StateCache
        # The diary counts switches — they show how many times a day a person touches the
        # desk at all. As a separate event, because everything else in the diary is a sum of
        # seconds. Only the ones that happened: a report with more switches in it than there
        # were is not a report.
        #
        # "Happened" here is "moved the desk", which is not the same as Ok: a display that did not come
        # up does not undo the ones that did, so 'partial' counts. 'busy' never started and 'refused'
        # threw — a held-down shortcut used to produce a queue of skips, and every one of them reached
        # the report.
        $moved = @('done', 'partial') -contains $result.Outcome
        if ($moved -and (Get-ActiveSettings).stats) {
            try { Add-ActivitySwitch -Mode $Key } catch { }   # the diary must not get in a switch's way
        }
    }
}

# --- restoring the mode after the computer is turned on ---------------------
# After power-on Windows brings up its own set of screens, not the one that was chosen
# before shutdown. Save-LastMode (DisplayCore.ps1) remembers the mode; here we put it back.
#
# Why we do not compare the current set with the remembered one and bail out when they
# match: Switch-DisplayMode already skips whatever is done — topology, layout and modes are
# each checked separately, so a call on an already-correct desk costs 0.2-0.3 s and blinks
# nothing. What it does cure is the case where the screens are the same but the layout or
# the primary monitor drifted after boot: the taskbar used to arrive on a different monitor
# with the very same set.
#
# A function of its own rather than code in the timer handler: see Get-ActiveSettings.

# The mode for a key, if it is reachable right now. $null means not one of its monitors is
# on the desk: the rest must not be put out for its sake — that would leave a black screen,
# and that is exactly the price of being wrong that this check exists for.
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

    # The same machine session — so the tray was merely restarted. The screens are left
    # alone in that case: the set could have been changed by the person themselves, past
    # the app, through Win+P or Windows settings, and putting it back is not ours to do.
    if ($last.Session -and (Test-SameSession -Saved $last.Session)) {
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

    Write-DisplayLog ("startup: restoring '{0}', chosen at {1}" -f $mode.Key, $last.When)
    Invoke-Mode $last.Key -Auto -Silent:(Test-DeskMatchesMode -Mode $mode -State $state)
}

# --- the world changed by itself --------------------------------------------
# A monitor was plugged in or pulled out, the computer woke from sleep — in these cases
# Windows arranges the screens as it sees fit: the layout drifts, the taskbar moves, the
# refresh rate drops. Get-ReapplyDecision makes the decision (a pure function in
# DisplayCore.ps1, under tests); here it is only carried out.

# A postponed "assemble the desk": the mode key and the reason it is being assembled.
# In memory only, and only one: events arrive without limit, but the desk has to be
# assembled for the latest one — by then the earlier ones are no longer true.
$script:ReapplyPending = $null

function Invoke-ReapplyMode {
    param([string]$Key, [string]$Reason)

    if (-not $Key) { return }

    # Attempts already spent on THIS intent. A newer event about a different mode starts the count over:
    # the old intent is no longer true, so neither are its attempts.
    $tries = 0
    if ($script:ReapplyPending -and $script:ReapplyPending.Key -eq $Key) {
        $tries = [int]$script:ReapplyPending.Tries
    }

    # Under a game the desk is not touched — for the same reason the refresh-rate watchdog
    # backs off (see Restore-BestModes): a configuration change kills a full-screen D3D
    # device. The watchdog could do this from the start, this path could not, and on
    # 30 August at 19:58 it rebuilt the desk over a full-screen Chrome.
    #
    # Postponed, precisely, and not forgotten: a monitor that went away leaves the layout
    # drifted, and a person coming out of a game expects an assembled desk, not the one
    # Windows left them.
    if (Test-FullscreenApp) {
        if (-not $script:ReapplyPending -or $script:ReapplyPending.Key -ne $Key) {
            Write-DisplayLog ("reapply: postponed - full screen: {0}" -f $script:FullscreenWhy)
        }
        # Waiting for a game to end is not an attempt, so the count is carried over untouched: $tries is
        # this intent's own, and zero for one we have not tried yet.
        $script:ReapplyPending = [pscustomobject]@{ Key = $Key; Reason = $Reason; Tries = $tries }
        return
    }

    # From here on the desk is assembled right now, and what was postponed is no longer
    # needed: the fresh event about it IS that same "assemble again", only newer.
    #
    # Kept in hand until the switch reports back, though. Invoke-Mode answers a busy mutex with
    # 'busy' and a monitor that never woke with 'partial' — neither leaves the desk assembled, and
    # both are ordinary here: the game exiting is itself a configuration change, so the
    # refresh-rate watchdog is holding Local\DeskModesSwitch for about a second exactly when this
    # runs. Dropping the intent there left the desk drifted for good, because nothing re-arms it
    # short of the next hotplug.
    $pending = [pscustomobject]@{ Key = $Key; Reason = $Reason; Tries = ($tries + 1) }
    $script:ReapplyPending = $null

    $state = Get-CachedState
    $mode = Get-AvailableMode -Key $Key -State $state
    if (-not $mode) {
        Write-DisplayLog ("reapply: '{0}' is not available right now, leaving the displays alone" -f `
            (Get-ModeTitleFromKey $Key))
        return
    }

    Write-DisplayLog ("reapply: {0} -> '{1}'" -f $Reason, $mode.Key)
    Invoke-Mode $Key -Auto -Silent:(Test-DeskMatchesMode -Mode $mode -State $state)

    # The desk is assembled — nothing to keep. The test used to be "did it move at all", and a monitor
    # that had not woken yet passed it: the intent went in the bin while the desk was still drifted.
    if ($script:LastSwitch.Ok) { return }

    # It did not, and only a temporary reason earns another go. A busy mutex clears in a second and a
    # display still waking attaches a moment later; Windows refusing the configuration outright does not
    # change its mind in fifteen seconds, and putting the intent back there meant an error balloon every
    # fifteen seconds — each one a whole switch attempt on the tray's single thread.
    if (-not $script:LastSwitch.Retry) { return }

    if ($pending.Tries -ge $script:AutoRetryLimit) {
        Write-DisplayLog ("reapply: gave up assembling '{0}' after {1} attempts" -f `
            (Get-ModeTitleFromKey $Key), $pending.Tries)
        return
    }
    # Put back, not logged loudly: Invoke-Mode has already said why in a balloon and in the log,
    # and the 15-second timer will bring us back here.
    $script:ReapplyPending = $pending
}

# What was postponed under a game is picked up here. Leaving a borderless full screen comes
# with no DisplaySettingsChanged event, so there is nothing to wait for — we ask ourselves,
# from the existing 15-second timer (the same trick the refresh-rate watchdog uses; no timer
# of our own is started for this).
function Invoke-ReapplyCheck {
    if (-not $script:ReapplyPending) { return }
    if (Test-FullscreenApp) { return }

    $pending = $script:ReapplyPending
    # The state went stale over the course of the game: a monitor could have been pulled out
    # and plugged back in, and "is the mode reachable" has to be decided on today's desk.
    Update-StateCache
    Invoke-ReapplyMode -Key $pending.Key -Reason $pending.Reason
}

# The whole desk goes to the log, but only when it is a DIFFERENT one. The
# configuration-changed event arrives on our own switches too, several times in a row, and
# repeating one and the same line would drown everything else in it.
#
# Idle time goes on the same line: if a monitor leaves the bus exactly N minutes into the
# silence, that is the screen being put out on a power timeout rather than a breakage, and
# the only way to see it is right next to the fact.
function Write-DeskSnapshot {
    $state = Get-CachedState
    $now = Format-DeskSnapshot -State $state
    if ($now -eq $script:LastDeskLine) { return }
    $script:LastDeskLine = $now

    $idle = $(try { [int][NativeActivity]::IdleSeconds() } catch { -1 })
    if ($idle -ge 0) { Write-DisplayLog ('desk: {0} (idle {1} s)' -f $now, $idle) }
    else             { Write-DisplayLog ('desk: {0}' -f $now) }
}

# The configuration-changed event arrives on our own switches too, which is why it is the
# CONNECTED monitors that get compared: their set changes only when a cable was plugged in
# or pulled out (or a monitor was put out with its own button).
function Invoke-PlugCheck {
    param($Before)

    $settings = Get-ActiveSettings
    $last = Get-LastMode
    # The state cache was refreshed one line above us (see $script:DisplayChanged), so both
    # a monitor that appeared and one that went away are already visible here.
    $state = Get-CachedState

    # The membership of the onPlug mode: the pure function decides, but only whoever holds
    # the desk can know who belongs to a mode.
    $plugMembers = $null
    $plugKey = [string]$settings.reapply.onPlug
    if ($plugKey) {
        $plugMode = @(Get-DisplayModes -State $state -Settings $settings) |
                        Where-Object { $_.Key -eq $plugKey } | Select-Object -First 1
        if ($plugMode) {
            $plugMembers = @(Get-ModeMembers -Mode $plugMode -State $state |
                             ForEach-Object { [string]$_.Id })
        }
    }

    # The clock for the quarantine is kept here: the pure function makes the decision, while
    # "how long ago" and "who went away then" are the tray's state.
    $since = $null
    if ($script:LastVanishAt) { $since = ((Get-Date) - $script:LastVanishAt).TotalSeconds }

    $decision = Get-ReapplyDecision -Reapply $settings.reapply -Before $Before -Now $script:PresentIds `
                                    -LastMode $(if ($last) { [string]$last.Key } else { '' }) `
                                    -PlugModeMembers $plugMembers `
                                    -VanishedRecently $script:LastVanishIds -SecondsSinceVanish $since

    # The names go to the log, and before any decision. Without them it is visible which
    # branch fired but not what set it off: working out the 28 August case went entirely on
    # inferring that indirectly.
    foreach ($id in @($decision.Vanished)) {
        Write-DisplayLog ('plug: {0} went away' -f (Get-DisplayLabelById -Id $id -State $state -Known $script:KnownLabels))
    }
    foreach ($id in @($decision.Appeared)) {
        Write-DisplayLog ('plug: {0} came up' -f (Get-DisplayLabelById -Id $id -State $state -Known $script:KnownLabels))
    }

    if (@($decision.Vanished).Count -gt 0) {
        $script:LastVanishAt = Get-Date
        $script:LastVanishIds = @($decision.Vanished)
    }

    if ($decision.Action -ne 'mode') {
        # "We do nothing" has only one possible reason — the quarantine — and staying quiet
        # about it is not allowed: otherwise the onPlug setting looks broken.
        if ($decision.Reason) {
            Write-DisplayLog ('reapply: {0} - leaving the displays alone' -f $decision.Reason)
        }
        return
    }
    Invoke-ReapplyMode -Key $decision.Mode -Reason $decision.Reason
}

# Waking from sleep. We put back the last CHOSEN mode rather than whatever the system
# brought up itself: it brings up its own set, and this is the same case as after power-on
# (see Invoke-StartupRestore), only the session is the same one.
#
# Not straight away but after a delay: right after waking the monitors are still coming up,
# and a state query at that moment answers about a half-assembled desk.
#
# The delay itself lives in the existing 15-second timer rather than one of its own: the
# system raises the wake event NOT on the application's thread, and starting a WinForms
# timer from there means touching somebody else's thread. A timestamp is just an assignment,
# and that is enough.
$script:ResumeDueAt = $null

function Invoke-ResumeCheck {
    if (-not $script:ResumeDueAt) { return }
    if ((Get-Date) -lt $script:ResumeDueAt) { return }
    $script:ResumeDueAt = $null
    Update-StateCache
    $last = Get-LastMode
    if ($last) { Invoke-ReapplyMode -Key ([string]$last.Key) -Reason 'woke up from sleep' }
}

# --- the shutdown timer -----------------------------------------------------
# "Turn the computer off in an hour." The countdown lives only in the tray's memory: a
# computer that turns itself off a day after being asked to is scarier than any usefulness,
# so this is not written to disk and does not come back to life after a restart.
#
# The one-minute warning is a required part, not a convenience: between "set a timer and
# forgot" and "lost unsaved work" stands exactly that.

$script:PowerDeadline = $null
$script:PowerAction = 'shutdown'
$script:PowerWarned = $false

function Get-PowerRemaining {
    if (-not $script:PowerDeadline) { return -1 }
    return [int][math]::Ceiling(($script:PowerDeadline - (Get-Date)).TotalSeconds)
}

# The icon's tooltip: a countdown when there is one, and just the name when there is not.
# We ask for the DEADLINE itself, not the remainder: a deadline in the past is still a timer
# that was set, and the tooltip has to show it (Format-Duration will show "0 s").
function Update-TrayText {
    if ($script:PowerDeadline) {
        # A key per action rather than the action's word dropped into a hole: "shutdown" and
        # "sleep" are verbs, and a language that declines them cannot take them ready-made.
        $tray.Text = '{0} - {1}' -f $script:AppName,
                     (Get-Text -Key ('tray.timer.' + $script:PowerAction) -Values @((Format-Duration (Get-PowerRemaining))))
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
    Show-Balloon (Get-Text -Key 'timer.set') (Get-Text -Key ('timer.set.' + $Action) `
                 -Values @((Format-DurationShort $Minutes), (Get-TimerTargetText -Minutes $Minutes))) -Always
}

function Stop-PowerTimer {
    param([switch]$Quiet)

    if (-not $script:PowerDeadline) { return }
    $script:PowerDeadline = $null
    $script:PowerTicker.Stop()
    Write-DisplayLog 'power: timer cancelled'
    Update-TrayText
    if (-not $Quiet) { Show-Balloon (Get-Text -Key 'timer.cancelled') (Get-Text -Key 'timer.cancelled.body') -Always }
}

# Move a timer that is already set instead of setting it again: "another fifteen minutes"
# is a shift of the deadline, not a fresh countdown from zero, and the difference shows
# precisely when the third "add some" in a row is asked for.
function Add-PowerTime {
    param([int]$Minutes)

    if (-not $script:PowerDeadline) { return }
    $when = $script:PowerDeadline.AddMinutes($Minutes)

    # Less than a minute is never left, whatever is taken off: the one-minute warning is
    # part of the bargain, and a timer without it would turn the computer off in silence.
    $floor = (Get-Date).AddMinutes(1)
    if ($when -lt $floor) { $when = $floor }
    $script:PowerDeadline = $when

    $left = Get-PowerRemaining
    # The warning is in force again if more than a minute is left after the shift: otherwise
    # the added time would pass without one.
    if ($left -gt 60) { $script:PowerWarned = $false }

    Write-DisplayLog ("power: {0} moved by {1} min, {2} left" -f $script:PowerAction, $Minutes, (Format-Duration $left))
    Update-TrayText
    Show-Balloon (Get-Text -Key 'timer.moved') (Get-Text -Key ('timer.moved.' + $script:PowerAction) `
                 -Values @((Format-Duration $left), (Get-TimerTargetText -Minutes ([int][math]::Round($left / 60.0))))) -Always
}

# Where the picker opens from: from what is left, if this timer is already set (the person
# is going to edit it), and from forty-five minutes if it is not.
function Get-PowerPrefill {
    param([string]$Action)

    if ($script:PowerDeadline -and $script:PowerAction -eq $Action) {
        $left = [int][math]::Ceiling((Get-PowerRemaining) / 60.0)
        if ($left -gt 0) { return $left }
    }
    return 45
}

$script:PowerTicker = New-Object System.Windows.Forms.Timer
# Once every five seconds: the countdown is shown in minutes, and more often is pointless.
$script:PowerTicker.Interval = 5000
$script:PowerTicker.add_Tick({
    # The exit condition is the ABSENCE of a deadline, not a negative remainder. A WinForms
    # timer is always late and never early, over a hundred ticks the lateness piles up, and
    # the tick that should have caught the deadline arrives past it. A deadline in the past
    # means "time's up", not "there is no timer".
    if (-not $script:PowerDeadline) { $script:PowerTicker.Stop(); return }
    $left = Get-PowerRemaining
    Update-TrayText

    if (-not $script:PowerWarned -and $left -le 60) {
        $script:PowerWarned = $true
        Show-Balloon (Get-Text -Key 'timer.lastMinute') (Get-Text -Key ('timer.lastMinute.' + $script:PowerAction)) 'Warning'
        # Timer ticks are late by nature, and sleep can make them much later. The warning promises
        # a minute to cancel, so its first appearance starts that whole minute from here.
        $script:PowerDeadline = (Get-Date).AddMinutes(1)
        $left = Get-PowerRemaining
        Update-TrayText
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

# --- the diary --------------------------------------------------------------
# A sample every ten seconds: any less often and switching between windows gets lost, any
# more often and this is surveillance at a precision nobody needs. A sample costs
# microseconds (three system calls); the pot goes to disk once every two minutes.

$script:ActivityTicks = 0

function Invoke-ActivityTick {
    if (-not (Get-ActiveSettings).stats) {
        # Turning the diary off ends the in-memory run as surely as idling does. Otherwise turning it
        # on later joins both sides of the gap into one session even though nothing between was kept.
        $script:ActivityRunStart = $null
        $script:ActivityRunLast = $null
        return
    }
    try {
        # First "is anybody at the computer", and only then the monitor map and the mode
        # key: at night every tick ends on the very first question, and recomputing the
        # combos for it is pointless.
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

# --- memory -----------------------------------------------------------------
# Trimming the working set: after startup the process holds ~75 MB, of which about ten is
# live and the rest is the traces of compilation and of building the menu for the first
# time. Pulled once after startup and after the Settings window is closed (WPF leaves the
# most behind), and not on a timer: trimming pages that are in use is pointless — they come
# straight back.
function Optimize-TrayMemory {
    try {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        [NativeMemory]::Trim()
    }
    catch { Write-DisplayLog "memory: trim failed - $($_.Exception.Message)" }
}

# The trim at startup is a one-off: over a few minutes of work the .NET heap builds its
# budget back up and the working set returns to the old ~70 MB. So the main trim is this
# one: the person stepped away, the pages went cold, and now is the time to give them back.
# Once per break, with a five-minute threshold: a short pause for tea is no reason to shuffle
# pages back and forth.
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

# --- registering the global shortcuts ---------------------------------------

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
    # Through the function, not $script:Settings: see Get-ActiveSettings.
    foreach ($p in (Get-ActiveSettings).hotkeys.GetEnumerator()) {
        $combo = ConvertFrom-HotkeyString $p.Value
        if (-not $combo) { continue }
        $id = $script:Hotkeys.Register(($combo.Modifiers -bor $script:ModNoRepeat), $combo.Vk)
        if ($id -lt 0) { $failed += $combo.Text } else { $script:HotkeyMap[$id] = $p.Key }
    }

    if ($failed.Count -gt 0) {
        Write-DisplayLog ('tray: could not claim ' + ($failed -join ', '))
        Show-Balloon (Get-Text -Key 'balloon.hotkeysTaken') (Get-Text -Key 'balloon.hotkeysTaken.body' -Values @(($failed -join ', '))) 'Warning'
    }
    Write-DisplayLog ('tray: shortcuts registered: ' + $script:HotkeyMap.Count)
}

# Two things open the Settings window: the menu item and the first run. The body lives here
# rather than in the handler for exactly that reason: a function runs in script scope no
# matter who called it, and $script:AppName resolves inside it. Inside .GetNewClosure() it
# would resolve to nothing — the name used to be copied into a local for that very reason.
function Open-SettingsWindow {
    # -Page is what the About item passes: the same window, opened on the page that answers
    # "what version is this and where do I report it".
    param([string]$Page = '')

    # An error while building a WinForms window is shown as a nameless system window with no
    # detail. We catch it ourselves and write it to the log — there is no debugging it otherwise.
    try {
        # The remembered monitors travel into the window: a rule, a combo or a place in the row
        # is most often written for the display you are NOT looking at right now.
        $positions = @{}
        try { $positions = Get-CcdSourcePositions }
        catch { Write-DisplayLog "settings dialog: could not read the live desk positions - $($_.Exception.Message)" }
        $updated = Show-SettingsDialog -State (Get-CachedDesk) `
                       -Settings (Get-ActiveSettings) -Positions $positions -Page $Page
        if ($updated) {
            Set-ActiveSettings $updated
            # The menu is built on every open and the balloon below is about to be shown, so both
            # land in the new language at once. The window itself does not: it is still up, in the
            # language it was built in, and that is what the row's caption says will happen.
            [void](Initialize-Language -Code $updated.language)
            Register-Hotkeys
            Show-Balloon (Get-Text -Key 'balloon.saved') (Get-Text -Key 'balloon.saved.body')
        }
    }
    catch {
        Write-DisplayLog "settings dialog ERROR: $($_.Exception.Message) | $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
        [System.Windows.Forms.MessageBox]::Show(
            "Could not open Settings:`n`n$($_.Exception.Message)`n`nDetails are in the log.",
            $script:AppName, 'OK', 'Error') | Out-Null
    }
    # The Settings window is WPF, and it leaves the most rubbish behind.
    Optimize-TrayMemory
}

# --- the menu ---------------------------------------------------------------
# Rebuilt on every open: the set of connected monitors changes, and the item for one that
# was pulled out has to be visible as unavailable rather than lying.

function Add-MenuHeader {
    param([string]$Text, [double]$Scale = 1.0)
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $Text
    $item.Enabled = $false
    # By Tag the renderer tells a section header (dim it) from an information line (ordinary
    # text colour) — Enabled is false on both, so that neither catches clicks.
    $item.Tag = 'header'
    $item.Font = Get-UiFont -Size 8.5 -Scale $Scale -Semibold
    $top = Get-ScaledPx -Value 3 -Scale $Scale
    $bottom = Get-ScaledPx -Value 1 -Scale $Scale
    $item.Padding = New-Object System.Windows.Forms.Padding 0, $top, 0, $bottom
    [void]$menu.Items.Add($item)
}

$menu.add_Opening({
    $scale = Get-UiScale
    $iconPx = Get-ScaledPx -Value 16 -Scale $scale
    $sidePad = Get-ScaledPx -Value 4 -Scale $scale
    $topPad = Get-ScaledPx -Value 6 -Scale $scale
    $itemPad = Get-ScaledPx -Value 4 -Scale $scale

    $menu.Items.Clear()
    $menu.Font = Get-UiFont -Scale $scale
    $menu.ImageScalingSize = New-Object System.Drawing.Size $iconPx, $iconPx
    $menu.Padding = New-Object System.Windows.Forms.Padding $sidePad, $topPad, $sidePad, $topPad

    # The renderer is recreated on every open: the theme and the accent could have changed
    # while the tray was alive, and the object is cheap. An error dressing the menu must not
    # leave us without the menu itself — hence the fall back to the system look.
    try {
        $dark = Test-DarkTheme
        $accent = [System.Drawing.ColorTranslator]::FromHtml((Get-AccentColor -ForDarkTheme:$dark))
        $menu.Renderer = New-Object ModernMenuRenderer $dark, $accent, ([single]$scale)
    }
    catch {
        Write-DisplayLog "tray: menu renderer failed, using the system one - $($_.Exception.Message)"
        $menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System
    }

    # The desk with the remembered monitors in it, not the bare state: a display that is off at
    # its own button and gone from the bus still gets its line here and its own greyed mode
    # below, instead of vanishing out of the menu altogether (see Get-DeskDisplays).
    $state = @(Get-CachedDesk)

    if ($state) {
        Add-MenuHeader -Text (Get-Text -Key 'menu.displays') -Scale $scale
        foreach ($m in $state) {
            $dot = 'unplugged'
            if ($m.Disconnected)  { $what = Get-Text -Key 'display.notConnected' }
            elseif ($m.Active)    { $what = Get-Text -Key 'display.resolution' -Values @($m.Width, $m.Height, $m.Hz); $dot = 'on' }
            else                  { $what = Get-Text -Key 'display.off'; $dot = 'off' }
            $suffix = ''
            if ($m.Primary) { $suffix = '   - ' + (Get-Text -Key 'menu.primary') }

            $line = New-Object System.Windows.Forms.ToolStripMenuItem ('{0}    {1}{2}' -f (Get-DisplayTitle -Label ([string]$m.Label)), $what, $suffix)
            $line.Enabled = $false
            $line.Tag = 'info'
            $line.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
            # A disagreement with the best mode is worth seeing at once: usually it is a
            # DisplayPort link that degraded, not a setting.
            if ($m.Active -and $m.BestMode -and $m.Hz -lt $m.BestMode.Hz) {
                $line.Text += '   ' + (Get-Text -Key 'menu.belowHz' -Values @($m.BestMode.Hz))
                $dot = 'below'
            }
            $line.Image = Get-StatusDot -Kind $dot -Scale $scale
            [void]$menu.Items.Add($line)
        }
        # The rows above name the displays; this shows which is which. Only when something is on -
        # a badge needs a screen to lie on.
        if (@($state | Where-Object { $_.Active }).Count -gt 0) {
            $whichItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text -Key 'menu.whichIsWhich')
            $whichItem.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
            $whichItem.add_Click({
                try { Show-DisplayBadges -State (Get-CachedState) }
                catch { Write-DisplayLog "tray: could not show the badges - $($_.Exception.Message)" }
            })
            [void]$menu.Items.Add($whichItem)
        }
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }

    # The settings are here for the combos' sake: without them Get-DisplayModes would hand
    # back only the solos and "all". Through the function, not $script:Settings (see Get-ActiveSettings).
    $modes = @(Get-DisplayModes -State $state -Settings (Get-ActiveSettings))
    $activeKey = $null
    if ($state) { $activeKey = Get-ActiveModeKey -State $state -Modes $modes }

    Add-MenuHeader -Text (Get-Text -Key 'menu.switchTo') -Scale $scale
    foreach ($mode in $modes) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = $mode.Title
        $item.Tag = $mode.Key
        $item.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad

        # Through the function, not $script:Settings: see Get-ActiveSettings.
        $combo = (Get-ActiveSettings).hotkeys[$mode.Key]
        if ($combo) { $item.ShortcutKeyDisplayString = $combo }

        if (-not $mode.Available) {
            $item.Enabled = $false
            $item.Text += '   ' + (Get-Text -Key 'menu.notConnected')
        }
        if ($mode.Key -eq $activeKey) {
            $item.Checked = $true
            $item.Font = Get-UiFont -Scale $scale -Semibold
        }

        $item.add_Click({ Invoke-Mode $this.Tag }.GetNewClosure())
        [void]$menu.Items.Add($item)
    }

    # Back to the mode before this one. Named, so the item says where it goes; greyed when that
    # mode's displays are not all here, the way the list above greys such a mode. Absent until a
    # mode has been left at all.
    $previousKey = [string](Get-PreviousModeKey)
    if ($previousKey) {
        $previous = @($modes | Where-Object { $_.Key -eq $previousKey })
        $backItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $backItem.Text = Get-Text -Key 'menu.backTo' -Values @(
            $(if ($previous.Count -gt 0) { $previous[0].Title } else { Get-ModeTitleFromKey $previousKey }))
        $backItem.Tag = $script:BackHotkeyName
        $backItem.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
        $backCombo = (Get-ActiveSettings).hotkeys[$script:BackHotkeyName]
        if ($backCombo) { $backItem.ShortcutKeyDisplayString = $backCombo }
        if ($previous.Count -eq 0 -or -not $previous[0].Available) {
            $backItem.Enabled = $false
            $backItem.Text += '   ' + (Get-Text -Key 'menu.notConnected')
        }
        $backItem.add_Click({ Invoke-Mode $this.Tag }.GetNewClosure())
        [void]$menu.Items.Add($backItem)
    }

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # The timer: "turn off in an hour", "sleep in twenty minutes". The countdown is visible
    # both here and in the icon's tooltip — a timer you cannot find out about is a frightening
    # one. Next to every amount is the time on the clock: "in two hours" is something a person
    # checks against their own plans not in minutes but in "what time will that be".
    # No Title beside the action any more: what the item says is a key per action, because
    # "Shut down in 20 min" is one sentence in a language that declines its verbs.
    foreach ($spec in @(@{ Action = 'shutdown' }, @{ Action = 'sleep' })) {
        $action = [string]$spec.Action
        $armed = ($script:PowerDeadline -and $script:PowerAction -eq $action)
        $left = $(if ($armed) { Get-PowerRemaining } else { 0 })
        $parent = New-Object System.Windows.Forms.ToolStripMenuItem
        $parent.Text = $(if ($armed) { Get-Text -Key ('menu.timer.armed.' + $action) -Values @((Format-Duration $left)) }
                         else { Get-Text -Key ('menu.timer.in.' + $action) })
        $parent.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
        if ($armed) {
            $parent.Checked = $true
            $parent.Font = Get-UiFont -Scale $scale -Semibold
            $parent.ShortcutKeyDisplayString = Get-TimerTargetText -Minutes ([int][math]::Round($left / 60.0))

            # A timer that is set gets moved more often than cancelled: "another fifteen
            # minutes" is what people usually come back to it for.
            #
            # Everything below carries $itemPad like the items on the top level. Without it the whole
            # timer submenu sat tighter than the menu it drops out of — invisible at 100%, plain at
            # 150%, where four pixels of padding are six.
            foreach ($shift in 15, -15) {
                $move = New-Object System.Windows.Forms.ToolStripMenuItem
                $move.Text = $(if ($shift -gt 0) { Get-PluralText -Key 'menu.timer.add' -Count $shift }
                               else { Get-PluralText -Key 'menu.timer.take' -Count ([math]::Abs($shift)) })
                $move.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
                $move.Tag = $shift
                # There is nothing to take off when less than that is left: the timer must not
                # be able to turn the computer off right now, past the one-minute warning.
                $move.Enabled = ($shift -gt 0 -or $left -gt ([math]::Abs($shift) + 1) * 60)
                $move.add_Click({ Add-PowerTime -Minutes ([int]$this.Tag) }.GetNewClosure())
                [void]$parent.DropDownItems.Add($move)
            }

            $cancel = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text -Key 'menu.timer.cancel')
            $cancel.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
            $cancel.add_Click({ Stop-PowerTimer })
            [void]$parent.DropDownItems.Add($cancel)
            [void]$parent.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        }
        foreach ($minutes in 15, 30, 60, 120) {
            $item = New-Object System.Windows.Forms.ToolStripMenuItem (Format-DurationShort $minutes)
            $item.ShortcutKeyDisplayString = Get-TimerTargetText -Minutes $minutes
            $item.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
            $item.Tag = '{0}|{1}' -f $action, $minutes
            $item.add_Click({
                $parts = ([string]$this.Tag) -split '\|'
                Start-PowerTimer -Minutes ([int]$parts[1]) -Action $parts[0]
            }.GetNewClosure())
            [void]$parent.DropDownItems.Add($item)
        }
        [void]$parent.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        # Your own time gets a window (Show-TimerDialog in SettingsDialog.ps1): a slider,
        # pills, the wheel and the same time on the clock as the ready-made amounts have. A
        # zero from there means "changed my mind", and then there is nothing to set.
        $custom = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text -Key 'menu.timer.pick')
        $custom.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
        $custom.Tag = $action
        $custom.add_Click({
            $act = [string]$this.Tag
            # An error while building a WinForms window is shown as a nameless system window
            # with no detail. We catch it ourselves and write it to the log.
            try {
                $minutes = Show-TimerDialog -Action $act -Minutes (Get-PowerPrefill -Action $act)
                if ($minutes -gt 0) { Start-PowerTimer -Minutes $minutes -Action $act }
            }
            catch {
                Write-DisplayLog "timer dialog ERROR: $($_.Exception.Message) | $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
                Show-Balloon (Get-Text -Key 'balloon.timerFailed') (Get-Text -Key 'balloon.seeLog') 'Warning'
            }
            # A WPF window, like the settings one, leaves a working set behind it.
            Optimize-TrayMemory
        }.GetNewClosure())
        [void]$parent.DropDownItems.Add($custom)
        [void]$menu.Items.Add($parent)
    }

    $statsItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text -Key 'menu.statistics')
    $statsItem.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
    if (-not (Get-ActiveSettings).stats) {
        # The diary is off — the item is visible, but it explains why it is empty instead of
        # opening a page full of zeroes.
        $statsItem.Text = Get-Text -Key 'menu.statisticsOff'
        $statsItem.add_Click({
            Show-Balloon (Get-Text -Key 'balloon.diaryOff') (Get-Text -Key 'balloon.diaryOff.body') 'Warning'
        })
    }
    else {
        $statsItem.add_Click({
            try {
                # The pot is written to disk before the window: the last few minutes live in
                # memory, and without this the report would lag two minutes behind life.
                Save-ActivityStore -Force
                Open-SettingsWindow -Page 'diary'
            }
            catch {
                Write-DisplayLog "stats: the diary window failed - $($_.Exception.Message)"
                Show-Balloon (Get-Text -Key 'balloon.diaryFailed') $_.Exception.Message 'Error'
            }
            # A WPF window, like the settings one, leaves a working set behind it.
            Optimize-TrayMemory
        })
    }
    [void]$menu.Items.Add($statsItem)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $settingsItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text -Key 'menu.settings')
    $settingsItem.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
    $settingsItem.add_Click({ Open-SettingsWindow })
    [void]$menu.Items.Add($settingsItem)

    $logItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text -Key 'menu.openLog')
    $logItem.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
    $logItem.add_Click({
        if (Test-Path $script:LogFile) { Start-Process notepad.exe $script:LogFile }
        else { Show-Balloon (Get-Text -Key 'balloon.noLog') (Get-Text -Key 'balloon.noLog.body') -Always }
    })
    [void]$menu.Items.Add($logItem)

    $folderItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text -Key 'menu.openFolder')
    $folderItem.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
    $folderItem.add_Click({ Start-Process explorer.exe $script:ToolRoot })
    [void]$menu.Items.Add($folderItem)

    # It used to be a balloon with the version line in it. The Settings window has an About page
    # now - the version, the project, the log, the folder - so the item opens the window there.
    # The name comes from $script:AppName rather than being spelled out: the same name is in
    # the icon's tooltip, in error captions and in the first-run greeting, and a name that
    # drifted is the first thing a person notices in a bug report.
    $aboutItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text -Key 'menu.about' -Values @($script:AppName))
    $aboutItem.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
    $aboutItem.add_Click({ Open-SettingsWindow -Page 'about' })
    [void]$menu.Items.Add($aboutItem)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-Text -Key 'menu.exit')
    $exitItem.Padding = New-Object System.Windows.Forms.Padding 0, $itemPad, 0, $itemPad
    $exitItem.add_Click({ [System.Windows.Forms.Application]::Exit() })
    [void]$menu.Items.Add($exitItem)
})

# NotifyIcon owns the right button and opens its ContextMenuStrip. The left button is the
# direct route into Settings; filtering the button here keeps a right click from also opening a
# window behind its menu.
$tray.add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Open-SettingsWindow }
})

# --- the first run ----------------------------------------------------------
# The default shortcuts are laid out once: the solo modes get F1, F2, …, then the combos.
# After that the user edits them, and we never interfere again.

# The set of CONNECTED monitors is filled by the very first cache refresh, which is why it
# is declared BEFORE it: an assignment afterwards would wipe what we already learned, and
# the first monitor plugged in during a run would go unnoticed.
$script:PresentIds = @()

# When, and who, last went off the bus. The quarantine in Invoke-PlugCheck needs it: a
# monitor that appears a second after somebody else's disappearance is Windows rearranging
# the desk, not a person plugging a cable in. Deliberately not written to disk: after the
# tray restarts there is no quarantine, and that is right — a disappearance remembered since
# yesterday would forbid a real plug-in.
$script:LastVanishAt = $null
$script:LastVanishIds = @()

# The last desk line written — so as not to repeat it on every event.
$script:LastDeskLine = ''

Update-StateCache   # so the first menu open is as fast as all the others, and the names are known

# The cache is refreshed on the system's event: a monitor could have been switched on, off
# or reconnected past our application too.
#
# $script:PresentIds is the set of CONNECTED monitors before the cache refresh: a change in
# it shows whether a monitor was plugged in or pulled out (see Invoke-PlugCheck). Our own
# switches do not change it, so there can be no reaction to our own work here.
$script:DisplayChanged = {
    $before = @($script:PresentIds)
    Update-StateCache
    # The desk snapshot first: everything else in this handler changes it, and a snapshot
    # written after them would be answering a different question.
    try { Write-DeskSnapshot }
    catch { Write-DisplayLog "desk: snapshot failed - $($_.Exception.Message)" }
    Invoke-ModeWatch
    try { Invoke-PlugCheck -Before $before }
    catch { Write-DisplayLog "reapply: plug check failed - $($_.Exception.Message)" }
}
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($script:DisplayChanged)

# Waking from sleep. The setting is checked here rather than in the timer: the event arrives
# on going to sleep too, and there is nothing to start a countdown for on that.
$script:PowerModeChanged = {
    param($sender, $e)
    if ($e.Mode -ne [Microsoft.Win32.PowerModes]::Resume) { return }
    if (-not (Get-ActiveSettings).reapply.onResume) { return }
    Write-DisplayLog 'reapply: the computer woke up, waiting for the displays to settle'
    $script:ResumeDueAt = (Get-Date).AddSeconds(5)
}
[Microsoft.Win32.SystemEvents]::add_PowerModeChanged($script:PowerModeChanged)

# While a game is open the watchdog postpones putting the refresh rate back (see
# Test-FullscreenApp). Leaving a borderless full screen comes with no DisplaySettingsChanged
# event, so what was postponed is picked up by the timer. An ordinary block, not
# .GetNewClosure() — otherwise $script: inside it will not resolve.
$script:WatchTimer = New-Object System.Windows.Forms.Timer
$script:WatchTimer.Interval = 15000
$script:WatchTimer.add_Tick({
    # The order here is deliberate. Waking first: until the desk has been assembled again,
    # everything else about it lies. Then the desk that was postponed because of a game: that
    # is the same "assemble again", and the rules below need it already assembled. The rules
    # third: noticing that a game started matters more than picking up a postponed
    # refresh-rate restore, and the two are unrelated.
    try { Invoke-ResumeCheck }
    catch { Write-DisplayLog "reapply: after sleep failed - $($_.Exception.Message)" }

    try { Invoke-ReapplyCheck }
    catch { Write-DisplayLog "reapply: postponed check failed - $($_.Exception.Message)" }

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

# The diary. The timer always runs, but a sample is only taken while the setting is on: the
# check inside costs one dictionary lookup, whereas a timer that has to be started and
# stopped on every settings save is extra state that sooner or later drifts apart from the
# setting.
$script:ActivityTimer.Start()

# Window-position snapshots from a previous Windows logon are useless: HWNDs are valid only
# within one logon session, and after a reboot the same numbers go to other windows. We
# clean out entries whose every process is already dead.
try { Remove-DeadWindowLayouts }
catch { Write-DisplayLog "windows: could not clean stale snapshots - $($_.Exception.Message)" }

# A monitor could have moved to another input while the application was not running — then
# the binding moves to the new key by itself. We do this before registering the shortcuts.
# The remembered monitors are handed in as well, and that is the point: without them a solo key
# for a display that is merely switched off matches no mode, and the name-guessing rung inside
# would go looking for another monitor to carry the binding to.
if (Update-HotkeyKeys -Settings $script:Settings -State (Get-CachedDesk)) {
    # [void]: Save-DisplaySettings answers whether the file was written, and here there is nothing to be
    # done about a "no" — the migration lives on in memory for this run, the log says why, and the tray
    # starts either way. Which is the point: this line runs before the message loop, and a refusal used
    # to take the whole application down without a word.
    [void](Save-DisplaySettings $script:Settings)
}

# The tell of a first run is the ABSENCE of the settings file, not an empty shortcut list.
# An empty list is a legitimate choice: the person cleared every binding in the Settings
# window, and putting them back on the next start is not allowed. Keying on "the file
# exists" also keeps a damaged settings.json from being overwritten with the defaults.
$script:FirstRun = $false
if (-not (Test-Path $script:SettingsFile)) {
    $script:FirstRun = $true
    $state = Get-CachedState
    $i = 1
    foreach ($mode in @(Get-DisplayModes -State $state -Settings (Get-ActiveSettings))) {
        if ($i -gt 8) { break }
        $script:Settings.hotkeys[$mode.Key] = "Ctrl+Alt+F$i"
        $i++
    }
    # The answer is read, unlike above: here it decides whether the log tells the truth. A folder we may
    # not write to (Program Files, a read-only share) gave "assigned the default shortcuts" over a file
    # that was never created — and since a first run is told by the ABSENCE of that file, every start
    # after it was a first run again, welcome balloon and Settings window included, for good.
    if (Save-DisplaySettings $script:Settings) {
        Write-DisplayLog 'settings: first run - assigned the default shortcuts'
    }
    else {
        # Save-DisplaySettings has already logged the reason. The shortcuts work this run — they live in
        # memory — and the next start will meet a first run again; both halves have to be said.
        Write-DisplayLog 'settings: first run - the default shortcuts work for this run, but could not be saved'
    }
}

Register-Hotkeys
Write-DisplayLog ("tray: started in {0} ms" -f [int]$script:StartWatch.ElapsedMilliseconds)

# Restoring the last mode does not happen here but through a one-shot timer: the message
# loop has to be running already, otherwise for a few seconds the menu does not open and no
# balloons show. A second and a half — so the desk settles after logging in to Windows; by
# then a person is usually still looking at the desktop.
#
# After "tray: started" deliberately: that line measures how fast the shortcuts become
# usable, and switching the screens must not land inside that measurement.
$script:StartupTimer = New-Object System.Windows.Forms.Timer
$script:StartupTimer.Interval = 1500
$script:StartupTimer.add_Tick({
    $script:StartupTimer.Stop()
    try { Invoke-StartupRestore }
    catch { Write-DisplayLog "startup: could not restore the last mode - $($_.Exception.Message)" }

    # The first run is the only time a person does not yet know the icon has appeared at all,
    # or that its menu is the right-hand one. Here rather than right after the settings are
    # created: by this point the message loop is running, and before it a balloon does not
    # show, while the Settings window would have stood across the startup.
    if ($script:FirstRun) {
        try {
            Show-Balloon $script:AppName (Get-Text -Key 'balloon.firstRun')
            Open-SettingsWindow
        }
        catch { Write-DisplayLog "startup: first-run welcome failed - $($_.Exception.Message)" }
    }

    # Startup is over — give the system back what was only needed during it.
    Optimize-TrayMemory
})
$script:StartupTimer.Start()

try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    Write-DisplayLog 'tray: stopped'
    # The diary's pot goes to disk: the last few minutes live in memory, and quitting the
    # application is no reason to lose them.
    try { Save-ActivityStore } catch { }   # on the way out there is nothing left to drop
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
