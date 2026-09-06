<#
    DisplayCore.ps1 — the shared logic for switching monitors.

    Definitions only, no actions on load. The entry points:
        Displays.ps1      the tray icon
        Set-Display.ps1   the command line

    Everything is done through the Windows API directly, with no third-party utilities: the state is
    read in ~90 ms, a monitor that has gone out keeps its name and its identifier (otherwise there
    would be nothing to switch it back on with), and the layout is written with the call that
    actually works on this machine.
#>

# Windows PowerShell 5.1, and #Requires cannot say that: it takes a MINIMUM, so PowerShell 7 walks
# straight past it and dies two thousand lines further down on "error CS0246: the type or namespace
# name 'List<>' could not be found". Add-Type on .NET Core references only what -ReferencedAssemblies
# names, and System.Runtime is not in that list. Running on 7 is a different project - WinForms, WPF
# and every P/Invoke here would have to be measured again - so this is a refusal, not a fallback. What
# it buys is that whoever typed .\Set-Display.ps1 in their own terminal is told which shell to use,
# instead of reading a C# compiler complaint about a type they never wrote. The .cmd files call
# powershell.exe by name and never reach this.
if ($PSVersionTable.PSEdition -eq 'Core') {
    throw ("DeskModes needs Windows PowerShell 5.1, and this is PowerShell {0}. Start it from the " +
           ".cmd files in this folder, or name the shell yourself: " +
           "powershell -ExecutionPolicy Bypass -File .\Set-Display.ps1 status") -f $PSVersionTable.PSVersion
}

$script:ToolRoot     = $PSScriptRoot
# The log's path is redirected by an environment variable — for the tests' sake: the first lines
# (compiling the types, rotating the log) are written while this file is being loaded, and replacing
# $script:LogFile after the dot-source is too late. The log is the main tool for working things out,
# and there must be no foreign traces in it.
$script:LogFile      = $(if ($env:DESKMODES_LOG_FILE) { $env:DESKMODES_LOG_FILE } else { Join-Path $PSScriptRoot 'last-run.log' })
$script:SettingsFile = Join-Path $PSScriptRoot 'settings.json'
$script:LastModeFile = Join-Path $PSScriptRoot 'last-mode.json'
$script:ModeCacheFile = Join-Path $PSScriptRoot 'display-modes.json'
$script:DesktopSnapshotsFile = Join-Path $PSScriptRoot 'desktop-layouts.json'
# Every monitor this desk has ever had, by the name the settings call it (see Get-KnownDisplays).
$script:KnownDisplaysFile = Join-Path $PSScriptRoot 'known-displays.json'
# Where the Settings window stood and which page it was on. The machine's state and not a
# setting: it is not in settings.json, it is in .gitignore, and deleting it costs a person
# nothing but a centred window.
$script:UiStateFile = Join-Path $PSScriptRoot 'ui-state.json'

# The version is where a person starts a bug report: without it "my monitor will not go out" cannot be
# matched against either the log or a commit. The line is assembled by one function for everybody: keeping
# it in sync between the command line and the tray menu any other way would have failed in the very first
# release.
#
# The Windows build and the PowerShell version go in there too: almost every refusal in this code is a
# refusal of one particular "driver + system build" pair, and without them the question "what have you got?"
# takes a separate email.
$script:Version = '1.0.0'

function Get-VersionName {
    return 'DeskModes {0}' -f $script:Version
}

function Get-VersionHost {
    return 'Windows {0}, PowerShell {1}' -f [System.Environment]::OSVersion.Version, $PSVersionTable.PSVersion
}

# The two of them on one line, which is what `Set-Display.ps1 status` prints. The About page
# shows the same two facts on two lines and so asks for them separately - it is one string in a
# console and a row of a card in a window, and neither should be the other's leftovers.
function Get-VersionLine {
    return (Get-VersionName) + ' - ' + (Get-VersionHost)
}

# The addresses the About page opens. Here rather than in the window's markup for the reason the
# version is here: README links the same project, and two copies of an address drift apart at
# the first rename.
$script:RepoUrl = 'https://github.com/GangHack/DeskModes'
$script:IssuesUrl = 'https://github.com/GangHack/DeskModes/issues'
# Empty on purpose until there is an address to put here. The Support card is built either way;
# with no address the button says so and does nothing, which is honest, while a button that
# opens a 404 is not.
$script:DonateUrl = ''

# The date and time for the log and for the files — the same on any locale. Both `-Format` and ToString
# without a culture take from the current one not only the time separator but the CALENDAR: on a Thai locale
# 'yyyy' is the year 2569 in the Buddhist reckoning, and on an Arabic one it can be the Hijri. The log would
# stop reading as an ISO date, and the diary's keys would stop comparing as strings against last year's.
function Format-DisplayStamp {
    param([datetime]$When = (Get-Date), [string]$Pattern = 'yyyy-MM-dd HH:mm:ss')
    return $When.ToString($Pattern, [cultureinfo]::InvariantCulture)
}

function Write-DisplayLog {
    param([string]$Message)
    try {
        # -ErrorAction Stop is mandatory: a refusal from Add-Content (the file is open for writing, it is
        # read-only, the disk is full) is a NON-terminating error, and without this the catch below will not
        # catch it. The log going quiet must not depend on whether the caller has
        # $ErrorActionPreference = 'Stop' set.
        Add-Content -Path $script:LogFile -Encoding UTF8 -ErrorAction Stop `
                    -Value ('{0}  {1}' -f (Format-DisplayStamp), $Message)
    }
    catch { }   # the log must not bring a monitor switch down
}

# The log grows by a line on every switch, every start and every firing of the watchdog; a megabyte is about
# a year, and history older than a year is not needed.
#
# One check, when DisplayCore is loaded, and not on every write: otherwise Get-Item would be pulled several
# times per switch for nothing. A rename rather than a truncation: the file may be open in a live process,
# and cutting it from under one is not allowed. The previous .old is overwritten — two generations are enough.
function Limit-DisplayLog {
    param([int]$MaxBytes = 1MB)

    try {
        if (-not (Test-Path $script:LogFile)) { return }
        if ((Get-Item $script:LogFile).Length -lt $MaxBytes) { return }

        $old = $script:LogFile + '.old'
        # -ErrorAction Stop for the same reason as in Write-DisplayLog: without it "the file is in use by
        # another process" leaves for the error stream, and status.cmd prints a red wall of text because of
        # some tidying up in the log.
        Move-Item -LiteralPath $script:LogFile -Destination $old -Force -ErrorAction Stop
        # The first line of the new file explains where the previous one went.
        Write-DisplayLog 'core: log rotated, the previous one is last-run.log.old'
    }
    catch {
        # Could not — never mind: we carry on writing into the same file. Bringing the tool down over some
        # tidying up in the log is not allowed.
    }
}

Limit-DisplayLog

# --- the settings -----------------------------------------------------------
# The shortcut bindings live in settings.json rather than in the code: the user edits them themselves
# through the Settings window. The mode keys are stable (see Get-DisplayModes).

function Get-DefaultSettings {
    return [ordered]@{
        # Mode key -> keys. One entry is not a mode: "back" is the shortcut that returns to the
        # mode before the current one (see Get-PreviousModeKey).
        hotkeys         = [ordered]@{}
        maximizeRefresh = $true
        notifications   = $true
        # The interface's language: a code with a file under lang\, or "auto" — follow Windows.
        # The log is not covered by this and never will be; see Get-Text.
        language        = 'auto'
        # The physical order of the monitors on the desk, left to right. The layout in
        # Windows is built along it, so that the cursor crosses between screens the same
        # way they really stand. Names can be written in parts: "UltraGear" will find
        # "LG ULTRAGEAR".
        layout          = @()
        # Old versions filled layout and primary while saving unrelated settings. These markers are set
        # only by an explicit reorder or taskbar choice, so a legacy incidental value cannot override a
        # physical desktop snapshot.
        layoutOverride  = $false
        # Which monitor to make primary (that is, where the taskbar goes), if it is
        # among the ones that are on. A piece of a name, as in layout.
        primary         = ''
        primaryOverride = $false
        # Combos: a name -> an arbitrary set of monitors. The sets may overlap, and one
        # monitor takes part in as many as it likes. The mode key is combo:<name>, and
        # the title is the name itself, as entered.
        #   "combos": {
        #       "Movie night": { "displays": ["ULTRAFINE", "XG27AQDMGR"], "primary": "ULTRAFINE" }
        #   }
        # displays — pieces of names, matched by the same rules as layout.
        # primary — who gets the taskbar in this mode; an empty string, or that monitor
        # not being on the desk, and the general rules apply (see
        # Select-PrimaryDisplay). Edited in the Settings window; by hand the short form
        # is allowed too — just an array of names instead of an object.
        combos          = [ordered]@{}
        # Remember where the windows sat for every desk layout and put them back when
        # returning to it (WindowLayout.ps1).
        restoreWindows  = $true
        # Put back the last chosen mode after the computer is turned on. Windows brings
        # up its own set of screens rather than the one chosen before shutdown (see
        # Save-LastMode and Invoke-StartupRestore).
        restoreLastMode = $true
        # Rules: "when this happens, become that". Checked in order, the first that fits
        # wins; while a rule "owns" the desk the others keep quiet (see
        # Get-RuleDecision).
        #   "rules": [
        #       { "when": "process", "process": "cs2", "mode": "solo:XG27AQDMGR" },
        #       { "when": "idle", "minutes": 20, "mode": "solo:LG ULTRAGEAR" },
        #       { "when": "displays", "displays": ["U2720Q", "ULTRAGEAR"], "mode": "combo:Home" }
        #   ]
        # when     process — a process is running; idle — nobody has worked at the
        #          computer for minutes minutes; displays — the connected displays are
        #          exactly the ones named (the laptop docked at home, say), matched by a
        #          piece of the name or the Monitor ID like layout is;
        # mode     the key of the mode to go to;
        # back     where to go back to once the condition ends; empty — to wherever
        #          the desk was before it fired;
        # enabled  false switches a rule off without deleting it.
        rules           = @()
        # The world changed by itself — assemble the desk again. After waking from sleep
        # and after a monitor is reconnected Windows arranges the screens as it sees fit:
        # the layout drifts, the taskbar moves, the refresh rate drops.
        #   onResume  waking from sleep: put back the last chosen mode;
        #   onUnplug  a monitor went away: rebuild what is left;
        #   onPlug    a monitor appeared: the key of the mode to go to, and only if
        #             the monitor that appeared belongs to that mode. Empty — do
        #             nothing. Empty by default deliberately: putting out a monitor a
        #             person has just switched on with the button is a fight with a
        #             person, and the decision here is theirs.
        reapply         = [ordered]@{
            onResume = $true
            onUnplug = $true
            onPlug   = ''
        }
        # A command to run around a switch: mode key -> { before, after }. A string
        # instead of an object means after — it is shorter that way, and after is the
        # one wanted more often.
        #   "hooks": { "combo:Movie night": { "after": "taskkill /im slack.exe" } }
        # A command is started and NOT waited for: switching the desk must not depend
        # on somebody else's program. A path to a .ps1 is started through powershell,
        # everything else through cmd /c (see Get-HookLaunch).
        hooks           = [ordered]@{}
        # Brightness and contrast as part of a mode: mode key -> a number 0..100 for
        # every monitor in the set, or { a piece of a name -> a number } for one each.
        # It goes over DDC/CI — the same channel in the cable the buttons on the
        # monitor's bezel work over (see Set-MonitorLevels).
        #   "brightness": { "combo:Work": 80, "all": { "ULTRAFINE": 25 } }
        brightness      = [ordered]@{}
        contrast        = [ordered]@{}
        # The monitor's picture preset as part of a mode - what its own menu calls Reader, FPS,
        # sRGB, Cinema. Mode key -> { a piece of a name -> "register:number" }, and the register
        # is part of it because monitors disagree about which one holds the preset: the standard
        # 0xDC, LG's 0x15. Both the register and the number are learnt from the monitor itself by
        # "Remember the monitor's current preset" - there are no names and no table of models
        # here, because the numbers are the vendor's and two of them can wear the same name.
        #   "picture": { "combo:Work": { "ULTRAGEAR": "0x15:45", "XG27": "0xDC:6" } }
        picture         = [ordered]@{}
        # HDR as part of a mode: mode key -> true/false for every display of the mode, or
        # { a piece of a name -> true/false } for one each. A display the mode does not
        # mention is left as it is (see Set-ModeHdr).
        #   "hdr": { "combo:Game": true, "combo:Work": { "ULTRAGEAR": false } }
        hdr             = [ordered]@{}
        # The diary: which application, on which monitor and in which mode, for how
        # long. Kept next to the scripts in activity.json, goes nowhere, and window
        # titles are NOT recorded — only the process name. Off by default: this is data
        # about a person, and it is not ours to turn on for them.
        stats           = $false
        # Audio following the mode: mode key -> a piece of an output device's name.
        # An empty dictionary = off. Edited in the mode editor, and by hand:
        #   "audio": { "solo:XG27AQDMGR": "ROG", "combo:Work": "ULTRAFINE" }
        audio           = [ordered]@{}
        # Run-at-startup is deliberately not here: the truth about it lives in whether
        # the shortcut exists (see Test-RunAtStartup), and two copies of one fact can drift apart.
    }
}

# Parsing one value out of settings.json — a function per form. All of them are pure, and therefore under
# tests, and all of them tolerate rubbish: the file gets edited by hand, and "it did not parse" has to mean
# "there is no such setting" rather than the application dying.

# A combo. Three forms of entry: the full one ({ displays, primary }) — which is what the Settings window
# writes; the short one (an array of names) and the very short one (a single name as a string) — for editing
# by hand. Inside it is always the full one.
function ConvertTo-ComboSetting {
    param($Value)

    $displays = @()
    $primary = ''
    if ($Value -is [array])      { $displays = @($Value | ForEach-Object { [string]$_ }) }
    elseif ($Value -is [string]) { $displays = @([string]$Value) }
    elseif ($Value) {
        if ($null -ne $Value.displays) { $displays = @($Value.displays | ForEach-Object { [string]$_ }) }
        if ($null -ne $Value.primary)  { $primary = [string]$Value.primary }
    }
    return [ordered]@{
        displays = @($displays | Where-Object { $_ })
        primary  = $primary
    }
}

# A command around a switch. What gets written as a string is the one wanted more often: the command AFTER.
# $null means "there is no entry" — there is no point keeping an empty pair in the settings.
function ConvertTo-HookSetting {
    param($Value)

    $before = ''
    $after = ''
    if ($Value -is [string]) { $after = [string]$Value }
    elseif ($Value) {
        if ($null -ne $Value.before) { $before = [string]$Value.before }
        if ($null -ne $Value.after)  { $after  = [string]$Value.after }
    }
    if (-not $before -and -not $after) { return $null }
    return [ordered]@{ before = $before; after = $after }
}

# A mode's brightness or contrast: a number — the same for every monitor in the set, an object — one each.
# $null means "there is no entry".
function ConvertTo-LevelSetting {
    param($Value)

    if ($Value -is [string] -or $Value -is [int] -or $Value -is [double] -or $Value -is [long]) {
        return [int]$Value
    }
    if (-not $Value) { return $null }

    $perDisplay = [ordered]@{}
    foreach ($p in $Value.PSObject.Properties) {
        if ($p.Name) { $perDisplay[$p.Name] = [int]$p.Value }
    }
    if ($perDisplay.Count -eq 0) { return $null }
    return $perDisplay
}

# The rules brought to one shape. Here specifically, at read time: further on the tray timer reads them
# every 15 seconds, and sorting out a field that may not be in the file is no longer possible there.
function ConvertTo-RuleSettings {
    param($Value)

    return @(foreach ($r in @($Value)) {
        if (-not $r) { continue }
        $when = [string]$r.when
        if (-not $when) { $when = 'process' }
        [ordered]@{
            when     = $when.ToLowerInvariant()
            process  = [string]$r.process
            minutes  = $(if ($null -ne $r.minutes) { [int]$r.minutes } else { 0 })
            # Always an array, even for the two conditions that do not use it: the tray joins it into
            # the rule's signature, and a missing key there would read as a different rule.
            displays = @(@($r.displays) | ForEach-Object { [string]$_ } | Where-Object { $_ })
            mode    = [string]$r.mode
            back    = [string]$r.back
            enabled = $(if ($null -ne $r.enabled) { [bool]$r.enabled } else { $true })
        }
    })
}

# A copy of a damaged file has to be kept: from here on the application sees an empty shortcut list, takes
# that for a first run and writes the defaults over the top. Without a copy the bindings would disappear
# altogether.
function Save-DamagedSettingsCopy {
    param([string]$Reason)

    Write-DisplayLog "settings: file is damaged, falling back to defaults - $Reason"
    try {
        Copy-Item $script:SettingsFile ($script:SettingsFile + '.bad') -Force
        Write-DisplayLog 'settings: kept a copy of the damaged file as settings.json.bad'
    }
    catch { }   # could not keep a copy — we bring the settings up all the same
}

# The contents of settings.json, parsed out of JSON, or $null — the file is absent or damaged.
function Read-SettingsFile {
    if (Test-Path -LiteralPath $script:SettingsFile) {
        try {
            $raw = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            if ($raw -isnot [pscustomobject]) { throw 'Settings must be a JSON object.' }
            return $raw
        }
        catch { Save-DamagedSettingsCopy -Reason $_.Exception.Message }
    }
    # The backup is a complete prior save, not the damaged bytes kept for diagnosis. Recovery
    # remains usable even in a read-only folder: failure to repair the primary is not fatal.
    $backup = $script:SettingsFile + '.bak'
    if (Test-Path -LiteralPath $backup) {
        try {
            $raw = Get-Content -LiteralPath $backup -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            if ($raw -isnot [pscustomobject]) { throw 'Settings backup must be a JSON object.' }
            [void](Save-DisplaySettings -Settings $raw)
            Write-DisplayLog 'settings: recovered the previous complete settings from settings.json.bak'
            return $raw
        }
        catch { Write-DisplayLog 'warn: the settings backup could not be recovered' }
    }
    return $null
}

# The settings: the defaults, with whatever was found in the file laid over them.
#
# Field by field rather than by assigning the object whole: the file may hold half the keys (it gets edited
# by hand), and the rest have to stay at their defaults rather than turn into $null.
function Get-DisplaySettings {
    $s = Get-DefaultSettings
    $raw = Read-SettingsFile
    if (-not $raw) { return $s }

    # The whole parse is under the try and not only the JSON read: the file gets edited by hand, and valid
    # JSON easily carries a meaningless value ("brightness": "high", "minutes": "twenty"). A type cast on
    # one of those is a TERMINATING error, and without this catch it leaves the function: both entry points
    # stand with $ErrorActionPreference = 'Stop' and call Get-DisplaySettings at startup, so the tray would
    # not come up at all. A damaged value is the same "the file is damaged" as damaged JSON, and the answer
    # to it is the same. What has already been parsed stays: half the settings are better than none.
    try {
        if ($null -ne $raw.maximizeRefresh) { $s.maximizeRefresh = [bool]$raw.maximizeRefresh }
        if ($null -ne $raw.notifications)   { $s.notifications   = [bool]$raw.notifications }
        if ($null -ne $raw.restoreWindows)  { $s.restoreWindows  = [bool]$raw.restoreWindows }
        if ($null -ne $raw.restoreLastMode) { $s.restoreLastMode = [bool]$raw.restoreLastMode }
        if ($null -ne $raw.stats)           { $s.stats           = [bool]$raw.stats }
        if ($null -ne $raw.layout)          { $s.layout          = @($raw.layout | ForEach-Object { [string]$_ }) }
        if ($null -ne $raw.primary)         { $s.primary         = [string]$raw.primary }
        if ($null -ne $raw.layoutOverride)  { $s.layoutOverride  = [bool]$raw.layoutOverride }
        if ($null -ne $raw.primaryOverride) { $s.primaryOverride = [bool]$raw.primaryOverride }
        if ($null -ne $raw.language)        { $s.language        = [string]$raw.language }

        foreach ($field in 'hotkeys', 'audio') {
            if (-not $raw.$field) { continue }
            foreach ($p in $raw.$field.PSObject.Properties) { $s.$field[$p.Name] = [string]$p.Value }
        }

        if ($raw.combos) {
            foreach ($p in $raw.combos.PSObject.Properties) {
                if ($p.Name) { $s.combos[$p.Name] = ConvertTo-ComboSetting $p.Value }
            }
        }

        if ($raw.hooks) {
            foreach ($p in $raw.hooks.PSObject.Properties) {
                if (-not $p.Name) { continue }
                $hook = ConvertTo-HookSetting $p.Value
                if ($hook) { $s.hooks[$p.Name] = $hook }
            }
        }

        foreach ($field in 'brightness', 'contrast') {
            if (-not $raw.$field) { continue }
            foreach ($p in $raw.$field.PSObject.Properties) {
                if (-not $p.Name) { continue }
                $level = ConvertTo-LevelSetting $p.Value
                if ($null -ne $level) { $s.$field[$p.Name] = $level }
            }
        }

        if ($raw.picture) {
            foreach ($p in $raw.picture.PSObject.Properties) {
                if (-not $p.Name) { continue }
                $one = ConvertTo-PictureSetting $p.Value
                if ($one) { $s.picture[$p.Name] = $one }
            }
        }

        if ($raw.hdr) {
            foreach ($p in $raw.hdr.PSObject.Properties) {
                if (-not $p.Name) { continue }
                $one = ConvertTo-HdrSetting $p.Value
                if ($null -ne $one) { $s.hdr[$p.Name] = $one }
            }
        }

        # The @() at the call site is mandatory: a function that returned a single-element array hands it
        # back as a scalar, and $s.rules[0] would stop existing.
        if ($raw.rules) { $s.rules = @(ConvertTo-RuleSettings $raw.rules) }

        if ($raw.reapply) {
            if ($null -ne $raw.reapply.onResume) { $s.reapply.onResume = [bool]$raw.reapply.onResume }
            if ($null -ne $raw.reapply.onUnplug) { $s.reapply.onUnplug = [bool]$raw.reapply.onUnplug }
            if ($null -ne $raw.reapply.onPlug)   { $s.reapply.onPlug   = [string]$raw.reapply.onPlug }
        }
    }
    catch {
        Save-DamagedSettingsCopy -Reason $_.Exception.Message
    }

    return $s
}

# $true when the file was really written.
#
# A refusal must NOT leave as an exception, and that is the whole reason this has a try around it. Both
# entry points stand with $ErrorActionPreference = 'Stop', and the tray calls this at the TOP LEVEL of its
# startup — before the message loop, with the console hidden. A folder without write rights (a shared
# Tools\, a read-only share, an editor holding the file open) therefore took the tray down silently and
# without a line in the log: the one place in this file where a failed write was not survivable. Every
# other write here says so and carries on, and now so does this one.
function Save-DisplaySettings {
    param($Settings)

    $temporary = $script:SettingsFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        # Serialize and finish writing beside the destination before replacing it. A crash or
        # a concurrent reader can no longer observe half a JSON document as the active settings.
        $json = $Settings | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($temporary, $json + "`r`n", (New-Object System.Text.UTF8Encoding $true))
        if (Test-Path -LiteralPath $script:SettingsFile) {
            $backup = $null
            try {
                $previous = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                if ($previous -is [pscustomobject]) { $backup = $script:SettingsFile + '.bak' }
            }
            catch { } # A damaged primary must not overwrite the last good backup during recovery.
            if ($backup) { [System.IO.File]::Replace($temporary, $script:SettingsFile, $backup) }
            else { [System.IO.File]::Replace($temporary, $script:SettingsFile, [NullString]::Value) }
        }
        else { [System.IO.File]::Move($temporary, $script:SettingsFile) }
        Write-DisplayLog 'settings: saved'
        return $true
    }
    catch {
        Write-DisplayLog "warn: could not save the settings - $($_.Exception.Message)"
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

# --- the language -----------------------------------------------------------
# The interface speaks the person's language; the log does not, ever. That split is the whole rule:
# last-run.log is read by whoever is taking a failure apart, and a line that changed language with
# the window cannot be matched against a grep, a commit or an issue. So every message a person
# reads is formatted twice - once for them, once in English for the log - and -Language is how the
# second one is asked for.
#
# One file per language under lang\, each returning a hashtable of key -> text. English is loaded
# first and the chosen language laid over it, so a key nobody has translated yet shows its English
# text rather than an empty label: a half-finished translation is a worse thing to ship than a
# mixed one. A file also carries its own name for the drop-down (_name) and its own plural rule
# (_plural), so a new language is a new file and nothing else - no list in the code to remember.

$script:LangDir = Join-Path $PSScriptRoot 'lang'
$script:LangFallback = 'en'
$script:LangCode = ''
# code -> the English map with that language laid over it. Built once per language and kept: the
# tray menu asks for a dozen strings on every open, and re-reading two files there would be a
# file system round trip inside a menu's Opening handler.
$script:LangMaps = @{}

# code -> the language's own name for itself, for the drop-down. Read off the files rather than
# written down here, and sorted by code so the list does not depend on how the disk feels.
function Get-LanguageChoices {
    $found = [ordered]@{}
    if (-not (Test-Path $script:LangDir)) { return $found }
    foreach ($file in @(Get-ChildItem -Path $script:LangDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
                        Sort-Object Name)) {
        $code = [System.IO.Path]::GetFileNameWithoutExtension($file.Name).ToLowerInvariant()
        $map = Import-LanguageFile -Code $code
        if (-not $map) { continue }
        $name = [string]$map['_name']
        if (-not $name) { $name = $code }
        $found[$code] = $name
    }
    return $found
}

# The file's hashtable, or $null. A language file is data and must never bring the application
# down: a syntax error in a translation somebody edited by hand costs that language, not the tray.
function Import-LanguageFile {
    param([string]$Code)

    if (-not $Code) { return $null }
    $path = Join-Path $script:LangDir ($Code + '.ps1')
    if (-not (Test-Path $path)) { return $null }
    try {
        $map = & $path
        if ($map -is [hashtable] -or $map -is [System.Collections.Specialized.OrderedDictionary]) { return $map }
        Write-DisplayLog ('lang: {0}.ps1 did not hand back a table, ignoring it' -f $Code)
    }
    catch {
        Write-DisplayLog ('lang: could not read {0}.ps1 - {1}' -f $Code, $_.Exception.Message)
    }
    return $null
}

# What "auto" means, and what an unknown code falls back to. Two letters and not the full culture:
# ru-RU, ru-UA and ru-KZ are one translation, and pretending otherwise would need three files.
function Resolve-LanguageCode {
    param([string]$Wanted)

    if (-not $Wanted -or $Wanted -eq 'auto') {
        # The UI culture and not the culture: a person can be on English Windows with Russian dates,
        # and it is the language of the interface that is being asked about here.
        $Wanted = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
    }
    $Wanted = $Wanted.ToLowerInvariant()
    if (Test-Path (Join-Path $script:LangDir ($Wanted + '.ps1'))) { return $Wanted }
    return $script:LangFallback
}

# English with one language laid over it. Nothing here reads the settings: the caller says which
# language, and Initialize-Language is the one place that turns the setting into a code.
function Get-LanguageMap {
    param([string]$Code)

    if (-not $Code) {
        if (-not $script:LangCode) { [void](Initialize-Language) }
        $Code = $script:LangCode
    }
    $Code = $Code.ToLowerInvariant()
    if ($script:LangMaps.ContainsKey($Code)) { return $script:LangMaps[$Code] }

    $merged = @{}
    foreach ($step in $script:LangFallback, $Code) {
        $map = Import-LanguageFile -Code $step
        if (-not $map) { continue }
        foreach ($key in @($map.Keys)) { $merged[$key] = $map[$key] }
    }
    $script:LangMaps[$Code] = $merged
    return $merged
}

# Which language the interface is in from here on. Called with the setting at startup and again
# when it is changed, so a window built afterwards is in the new language.
function Initialize-Language {
    param([string]$Code)

    $script:LangCode = Resolve-LanguageCode -Wanted $Code
    [void](Get-LanguageMap -Code $script:LangCode)
    return $script:LangCode
}

# The interface's text by key. Loads on the first ask rather than at dot-source time: Set-Display.ps1
# switches displays and never asks for a word of this.
#
# Arguments go in through -f, which takes the decimal separator from the CURRENT culture. Anything
# numeric must therefore arrive already formatted (Format-DisplayStamp and friends) rather than as
# a number - the same rule the log lives by, for the same reason.
function Get-Text {
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Values,
        # 'en' for a line on its way to the log. Left empty, the language a person chose.
        [string]$Language = ''
    )

    $map = Get-LanguageMap -Code $Language
    $text = $map[$Key]
    # The key itself, in brackets, and not an empty string: a missing key has to be visible on the
    # window at a glance, and an empty label looks like a decision somebody made.
    if ($null -eq $text) { return '[' + $Key + ']' }
    if ($text -is [array]) { $text = [string]$text[0] }
    # -not $null and not just truthiness: @(0) is a one-element array whose truth is the truth of
    # its element, so "0 s" arrived here and left as "{0} s".
    if ($null -ne $Values -and $Values.Count -gt 0) { return ([string]$text -f $Values) }
    return [string]$text
}

# One, two or five - the form the count needs. English wants two forms and Russian three, so the
# rule travels with the translation (_plural in the file) rather than living in a switch here that
# every new language would have to be added to.
function Get-PluralText {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][int]$Count,
        [string]$Language = ''
    )

    $map = Get-LanguageMap -Code $Language
    $forms = $map[$Key]
    if ($null -eq $forms) { return '[' + $Key + ']' }
    if ($forms -isnot [array]) { return ([string]$forms -f $Count) }

    $index = 0
    $rule = $map['_plural']
    if ($rule -is [scriptblock]) {
        try { $index = [int](& $rule $Count) } catch { $index = 0 }
    }
    elseif ($Count -ne 1) { $index = 1 }
    if ($index -lt 0 -or $index -ge $forms.Count) { $index = $forms.Count - 1 }
    return ([string]$forms[$index] -f $Count)
}

# The same fact for the person and for the log. Every message that reaches a balloon, a window or
# the command line is built through this: .Text is what they read, .Log is the English of it, and
# the two are one sentence in two languages rather than two sentences that will drift apart.
function New-DisplayMessage {
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Values,
        # What the log gets in place of -Values, when the values themselves are for a person. A
        # mode's title is the case this exists for: "Only LG ULTRAGEAR" is the right thing to read
        # and the wrong thing to grep for, so the log is handed the mode's key instead.
        [object[]]$LogValues
    )

    if ($null -eq $LogValues) { $LogValues = $Values }
    return [pscustomobject]@{
        Key  = $Key
        Text = (Get-Text -Key $Key -Values $Values)
        Log  = (Get-Text -Key $Key -Values $LogValues -Language $script:LangFallback)
    }
}

# A refusal a person will read, built so that the log keeps the English of it. The English line is
# written HERE and the exception is marked as already written down, so the catch at the bottom of
# Switch-DisplayMode adds nothing and the ERROR: line stays greppable whatever the window speaks.
# It is thrown at the call site rather than here, because a function that leaves by throwing and
# says so only in its comment is a function whose callers read as if they carry on.
function New-DisplayRefusal {
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Values,
        [object[]]$LogValues
    )

    $message = New-DisplayMessage -Key $Key -Values $Values -LogValues $LogValues
    Write-DisplayLog ('ERROR: ' + $message.Log)
    $refusal = New-Object System.InvalidOperationException($message.Text)
    # Not an exception type of our own: one marked field is enough to tell "we said this on purpose"
    # from "something fell over", and a new type would have to live in the embedded C# block.
    $refusal.Data['dm.logged'] = $true
    return $refusal
}

# --- the last chosen mode ---------------------------------------------------
# After the computer is turned on, Windows brings up ITS OWN set of screens rather than the one that was
# chosen before shutdown: it keeps its own idea of the layout to itself, does not report it to us, and
# restores it as it sees fit. In the log that is visible across all the days at once — almost every "tray:
# started" is followed, seconds or minutes later, by a switch made by hand. Which means the choice has to
# be remembered by us and put back when the tray starts (Invoke-StartupRestore in Displays.ps1).
#
# In a file of its own rather than a field in settings.json: the settings are under git and get edited by a
# person, whereas this is the machine's state, changing on every switch.

$script:SessionIdCache = ''

# A fingerprint of the machine's current power-on. Needed to tell "the tray started after the computer was
# turned on" from "the tray was restarted in the same session". In the first case the mode has to be put
# back, in the second the screens must not be touched: the set could have been changed by the person
# themselves through Win+P or Windows settings, and that is their decision.
#
# Two sources, because on its own neither is enough:
#   * ShutdownTime — the time of the last shutdown. It changes on every power-off and reboot, fast startup
#     included (HiberbootEnabled=1 on this machine), where the uptime counter may carry on from the
#     previous session;
#   * the moment of boot (now minus the uptime) — this covers the case where there was no shutdown at all:
#     a crash, a Reset, a loss of power.
# It is enough for EITHER of them to have changed.
#
# Worked out once per process: within one power-on the answer does not change, while the uptime counter
# drifts slightly after a long sleep.
function Get-SystemSessionId {
    if ($script:SessionIdCache) { return $script:SessionIdCache }

    $parts = @()
    try {
        $raw = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Windows' `
                                 -Name 'ShutdownTime' -ErrorAction Stop).ShutdownTime
        $parts += ([System.BitConverter]::ToInt64([byte[]]$raw, 0)).ToString()
    }
    catch {
        # The value is absent — we make do with one source. Silently: this is not a breakage.
        $parts += 'no-shutdown-time'
    }

    # The moment of boot as whole seconds since the epoch. Two processes work it out at two different
    # moments, so the value drifts by a second or so between them — and the slack for that lives in the
    # COMPARISON (Test-SameSession) rather than in the value itself. It used to live here, as a stamp
    # rounded down to the minute, and that left a seam: a boot instant that landed near a minute boundary
    # gave two processes two different strings, and a tray restarted in that session took itself for a
    # fresh boot and laid the remembered mode over a desk the person had just arranged by hand.
    $up = [System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency
    $epoch = New-Object datetime 1970, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)
    $boot = (Get-Date).ToUniversalTime().AddSeconds(-$up)
    $parts += ([int64]($boot - $epoch).TotalSeconds).ToString([cultureinfo]::InvariantCulture)

    $script:SessionIdCache = ($parts -join '/')
    return $script:SessionIdCache
}

# Whether a remembered stamp belongs to the power-on we are living in now.
#
# Not a string comparison, and that is the point: the second half of the stamp comes off the uptime
# counter, which two processes read at two different moments. The answer decides whether the tray puts
# the remembered mode back over a desk somebody may have arranged by hand, so it must not depend on where
# the boot instant happened to fall. Two minutes of slack is far below the shortest gap between two real
# power-ons and far above any drift in the counter.
#
# $Current is a seam for the tests only: the real caller has one answer to this, and it is cached.
# A stamp of a shape we do not know (written by an older version) is compared the way it always was.
function Test-SameSession {
    param([string]$Saved, [string]$Current = '', [int]$ToleranceSeconds = 120)

    if (-not $Current) { $Current = Get-SystemSessionId }
    if ($Saved -eq $Current) { return $true }

    $was = $Saved -split '/'
    $now = $Current -split '/'
    if ($was.Count -ne 2 -or $now.Count -ne 2) { return $false }
    # The shutdown half is read out of the registry by both sides and has to match exactly: it changes on
    # every power-off, and no drift is possible in it.
    if ($was[0] -ne $now[0]) { return $false }

    $a = [int64]0
    $b = [int64]0
    if (-not [int64]::TryParse($now[1], [ref]$b)) { return $false }
    if (-not [int64]::TryParse($was[1], [ref]$a)) {
        # A stamp an older version wrote: its second half is a date rounded to the minute
        # ("134326946768424535/2026-09-01 10:25"), not a count of seconds, so there is nothing here to
        # compare against. The shutdown half above has already matched, and that one changes at every
        # power-off — so this is the session we are living in, bar a crash or a Reset, which leave it
        # untouched. That "bar" is why the answer is yes rather than no: guessing wrong the other way
        # lays the remembered mode over a desk somebody has arranged by hand, while a startup restore
        # skipped once costs one keypress. It happens exactly once per installation — the first switch
        # after the upgrade rewrites the stamp in today's shape.
        return $true
    }
    return ([math]::Abs($a - $b) -le $ToleranceSeconds)
}

# The only writer of last-mode.json. Two callers want two different things out of it and the file has
# exactly one shape, so the shape lives here once: the two used to be a copy of each other, and a third
# field would have had to be remembered in both.
#
# $Whose finishes the sentence "warn: could not ..." — the two callers fail for the same reasons and a
# reader has to be able to tell which of them was writing.
function Write-LastMode {
    param([string]$Key, [string]$When, [string]$Whose, [string]$Previous = '')

    try {
        [ordered]@{
            key      = $Key
            # The mode before this one - what "back" goes to. Kept here rather than in memory
            # because the tray is restarted and the command line has no memory at all.
            previous = $Previous
            session  = Get-SystemSessionId
            when     = $When
        } | ConvertTo-Json -Compress |
            Set-Content -Path $script:LastModeFile -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # We did not write it down — the switch happened all the same. Bringing it down is not allowed.
        Write-DisplayLog ("warn: could not {0} - {1}" -f $Whose, $_.Exception.Message)
    }
}

# Remember the chosen mode. Called from Switch-DisplayMode on every switch that made it to the end — both
# from the tray and from the command line.
function Save-LastMode {
    param([Parameter(Mandatory)][string]$Key)

    # The mode being left becomes the one to go back to. Pressing the same shortcut twice is not a
    # departure, so the previous stays what it was - otherwise "back" from a repeat press would go
    # nowhere at all.
    $last = Get-LastMode
    $previous = ''
    if ($last) { $previous = $(if ($last.Key -ne $Key) { [string]$last.Key } else { [string]$last.Previous }) }
    Write-LastMode -Key $Key -When (Get-Date).ToString('s') -Whose 'remember the mode' -Previous $previous
}

# The mode to go back to: the one that was chosen before the current one, or an empty string when
# nothing has been left yet. The tray, the menu and the command line all ask this and nothing else.
function Get-PreviousModeKey {
    $last = Get-LastMode
    if (-not $last) { return '' }
    return [string]$last.Previous
}

# The name "back" travels in the hotkeys map beside the mode keys, because that is the one map the
# tray registers shortcuts from. It is not a mode: everything that turns a hotkey key into a row, an
# orphan or a title has to step over it.
$script:BackHotkeyName = 'back'

# Re-stamp the session without touching the choice. An automatic switch is not a choice, so it must not
# write the key — but it HAS touched the desk, and the startup restore reads the session to tell "a fresh
# boot" from "the tray was merely restarted". Without this the stamp stays at the previous boot's value
# until the person switches by hand, and every tray restart in between lays the remembered mode back over
# a desk they had rearranged through Win+P.
function Update-LastModeSession {
    $last = Get-LastMode
    if (-not $last) { return }   # nothing chosen yet: there is no record to re-stamp

    # Already stamped with this power-on: the file would come out byte for byte the same. Every automatic
    # switch came through here — a rule, a reapply, the watchdog's mode restore — so this is the common
    # case, not the rare one, and each of them used to cost a read, a serialise and a write.
    if ($last.Session -eq (Get-SystemSessionId)) { return }

    Write-LastMode -Key $last.Key -When $last.When -Whose 're-stamp the session' -Previous $last.Previous
}

# What was chosen last time: Key, Session, When. $null if the file is absent or unreadable.
function Get-LastMode {
    if (-not (Test-Path $script:LastModeFile)) { return $null }
    try {
        $raw = Get-Content $script:LastModeFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $raw.key) { return $null }
        # ConvertFrom-Json turns an ISO stamp into a [datetime], and a bare [string] cast on that takes
        # the CURRENT culture — including its calendar. It would print "08/31/2026" here and a Buddhist
        # year on a Thai locale, and Update-LastModeSession writes this value back to the file, so the
        # mangling would not stay on the screen: it would be what the next run reads.
        $when = $raw.when
        if ($when -is [datetime]) { $when = $when.ToString('s', [cultureinfo]::InvariantCulture) }
        return [pscustomobject]@{
            Key      = [string]$raw.key
            Previous = [string]$raw.previous
            Session  = [string]$raw.session
            When     = [string]$when
        }
    }
    catch {
        Write-DisplayLog "warn: the remembered mode is unreadable - $($_.Exception.Message)"
        return $null
    }
}

# --- the monitors' verified modes -------------------------------------------
# What exactly each monitor really showed last time: path -> {W;H;Hz}.
#
# Needed so that the desk lands in one transition. Set-CcdFullConfig sets the resolution and the refresh
# rate at once, together with the set of screens — but for a monitor that has GONE OUT there is nowhere to
# get a refresh rate from: EnumDisplaySettings enumerates modes only for an active output, and out of EDID
# the system hands back the native resolution alone (Get-CcdTargets, GET_TARGET_PREFERRED_MODE). Without
# this file a monitor that is waking up — and one wakes up in almost every switch — would come up at the
# refresh rate out of Windows's own record, and that would have to be fixed by a second rebuild of the desk.
#
# We write down what the monitor GAVE US rather than what was asked for: that doubles as protection against
# impossible modes. A monitor that refused 2560x1440@240 and stayed at 144 will write exactly 144 into the
# file — and the next switch will ask for that straight away.
#
# The refresh rate is stored as a FRACTION (num/den) rather than only as whole hertz, and that is not
# pedantry. CCD accepts nothing but the exact value: on this machine 144 Hz is 143999/1000 and 60 Hz is
# 59997/1000. A request for "144/1" the system rejects entirely, and the switch loses its refresh-rate hint.
# The whole hertz stay alongside — they show which mode the fraction belongs to, and they are what a person
# reads.
#
# In a file of its own rather than a field in settings.json: the settings are edited by a person and live
# under git, whereas this is the machine's state.

function Get-ModeCache {
    if (-not (Test-Path $script:ModeCacheFile)) { return @{} }
    try {
        $raw = Get-Content $script:ModeCacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $out = @{}
        foreach ($p in $raw.PSObject.Properties) {
            $v = $p.Value
            if ($null -eq $v) { continue }
            $w = [int]$v.w; $h = [int]$v.h; $hz = [int]$v.hz
            # Rubbish in the file must not turn into a request for an impossible mode.
            if ($w -le 0 -or $h -le 0) { continue }
            $num = [int]$v.num; $den = [int]$v.den
            if ($num -le 0 -or $den -le 0) { $num = 0; $den = 0 }
            $out[$p.Name] = [pscustomobject]@{
                Width = $w; Height = $h; Hz = $hz
                RateNum = $num; RateDen = $den
            }
        }
        return $out
    }
    catch {
        # A damaged file merely means "we do not know a sleeping monitor's refresh rate": the switch will
        # happen, just with a repair step. Silently, as with the remembered mode.
        return @{}
    }
}

# Add what the monitors are showing right now to the cache. By merging rather than replacing: a monitor that
# was not in this mode keeps its record — it will be needed when that monitor is switched on again.
function Save-ModeCache {
    param([Parameter(Mandatory)]$Modes)

    if (@($Modes.Keys).Count -eq 0) { return }
    try {
        $merged = Get-ModeCache
        foreach ($k in @($Modes.Keys)) { $merged[$k] = $Modes[$k] }

        $flat = [ordered]@{}
        foreach ($k in @($merged.Keys | Sort-Object)) {
            $m = $merged[$k]
            $flat[$k] = [ordered]@{
                w   = [int]$m.Width
                h   = [int]$m.Height
                hz  = [int]$m.Hz
                num = [int]$m.RateNum
                den = [int]$m.RateDen
            }
        }
        $flat | ConvertTo-Json -Depth 4 -Compress |
            Set-Content -Path $script:ModeCacheFile -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # We did not write it — the next switch simply will not know a sleeping monitor's refresh rate. There
        # is nothing worth bringing down over a cache.
        Write-DisplayLog "warn: could not remember the display modes - $($_.Exception.Message)"
    }
}

# --- exact physical desktops -----------------------------------------------
# A desktop is more than the set of active targets. Windows can change the primary display, source
# coordinates, rotation and the exact refresh fraction while another set is active. These snapshots are
# keyed by physical monitor device paths so DISPLAY1/2 renumbering cannot send a portrait mode to a
# neighbour.

function Get-DesktopSetKey {
    param([Parameter(Mandatory)][string[]]$DevicePaths)

    $ids = @($DevicePaths | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    if ($ids.Count -eq 0) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($ids -join "`n"))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function New-DesktopSnapshot {
    param([Parameter(Mandatory)]$State)

    $active = @($State | Where-Object { $_.Active -and -not $_.Disconnected })
    if ($active.Count -eq 0) { return $null }
    $ids = @($active | ForEach-Object { [string]$_.Id })
    if (@($ids | Where-Object { $_ }).Count -ne $active.Count -or
        @($ids | Sort-Object -Unique).Count -ne $active.Count) { return $null }
    $primary = @($active | Where-Object { $_.Primary })
    if ($primary.Count -ne 1) { return $null }

    $displays = @()
    foreach ($m in $active) {
        foreach ($field in 'X', 'Y', 'Rotation', 'RateNum', 'RateDen') {
            if (-not $m.PSObject.Properties[$field]) { return $null }
        }
        if ([int]$m.Width -le 0 -or [int]$m.Height -le 0 -or [int]$m.Hz -le 0 -or
            [int]$m.Rotation -lt 1 -or [int]$m.Rotation -gt 4 -or
            [int]$m.RateNum -le 0 -or [int]$m.RateDen -le 0) { return $null }
        $displays += [pscustomobject][ordered]@{
            Id       = [string]$m.Id
            Label    = [string]$m.Label
            X        = [int]$m.X
            Y        = [int]$m.Y
            Width    = [int]$m.Width
            Height   = [int]$m.Height
            Hz       = [int]$m.Hz
            Rotation = [int]$m.Rotation
            RateNum  = [int]$m.RateNum
            RateDen  = [int]$m.RateDen
        }
    }

    return [pscustomobject][ordered]@{
        Key       = Get-DesktopSetKey -DevicePaths $ids
        PrimaryId = [string]$primary[0].Id
        Displays  = @($displays)
    }
}

function New-DesktopSnapshotStore {
    return [pscustomobject][ordered]@{
        Version           = 2
        Snapshots         = @{}
        ProtectedKey      = ''
        ProtectedSnapshot = $null
        PendingKey        = ''
        UnsafeKeys        = @{}
    }
}

function Read-DesktopSnapshotStore {
    $store = New-DesktopSnapshotStore
    if (-not (Test-Path $script:DesktopSnapshotsFile)) { return $store }
    try {
        $raw = Get-Content $script:DesktopSnapshotsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($saved in @($raw.snapshots)) {
            if (-not $saved) { continue }
            $state = @()
            foreach ($d in @($saved.displays)) {
                foreach ($field in 'id', 'x', 'y', 'width', 'height', 'hz', 'rotation', 'rateNum', 'rateDen') {
                    if (-not $d.PSObject.Properties[$field]) { throw "Desktop snapshot is missing $field." }
                }
                $state += [pscustomobject]@{
                    Id = [string]$d.id; Label = [string]$d.label
                    Active = $true; Disconnected = $false
                    Primary = ([string]$d.id -eq [string]$saved.primaryId)
                    X = [int]$d.x; Y = [int]$d.y
                    Width = [int]$d.width; Height = [int]$d.height; Hz = [int]$d.hz
                    Rotation = [int]$d.rotation; RateNum = [int]$d.rateNum; RateDen = [int]$d.rateDen
                }
            }
            $snapshot = New-DesktopSnapshot -State $state
            if ($snapshot -and ([string]$saved.key -eq $snapshot.Key)) {
                $store.Snapshots[$snapshot.Key] = $snapshot
            }
        }
        $store.ProtectedKey = [string]$raw.protectedKey
        if ($raw.protectedSnapshot) {
            $saved = $raw.protectedSnapshot
            $state = @()
            foreach ($d in @($saved.displays)) {
                foreach ($field in 'id', 'x', 'y', 'width', 'height', 'hz', 'rotation', 'rateNum', 'rateDen') {
                    if (-not $d.PSObject.Properties[$field]) { throw "Protected desktop snapshot is missing $field." }
                }
                $state += [pscustomobject]@{
                    Id = [string]$d.id; Label = [string]$d.label
                    Active = $true; Disconnected = $false
                    Primary = ([string]$d.id -eq [string]$saved.primaryId)
                    X = [int]$d.x; Y = [int]$d.y
                    Width = [int]$d.width; Height = [int]$d.height; Hz = [int]$d.hz
                    Rotation = [int]$d.rotation; RateNum = [int]$d.rateNum; RateDen = [int]$d.rateDen
                }
            }
            $protected = New-DesktopSnapshot -State $state
            if ($protected -and $protected.Key -eq $store.ProtectedKey -and
                [string]$saved.key -eq $protected.Key) {
                $store.ProtectedSnapshot = $protected
            }
        }
        $store.PendingKey = [string]$raw.pendingKey
        if ($store.PendingKey) { $store.UnsafeKeys[$store.PendingKey] = $true }
        foreach ($key in @($raw.unsafeKeys)) {
            if ([string]$key) { $store.UnsafeKeys[[string]$key] = $true }
        }
    }
    catch {
        # A damaged state file cannot justify touching a desktop. It reads as empty and the current complete
        # desk will be captured before the next transition.
        return (New-DesktopSnapshotStore)
    }
    return $store
}

function Write-DesktopSnapshotStore {
    param([Parameter(Mandatory)]$Store)

    $saved = @()
    foreach ($key in @($Store.Snapshots.Keys | Sort-Object)) {
        $s = $Store.Snapshots[$key]
        if (-not $s) { continue }
        $saved += [ordered]@{
            key = [string]$s.Key; primaryId = [string]$s.PrimaryId
            displays = @($s.Displays | ForEach-Object {
                [ordered]@{
                    id = [string]$_.Id; label = [string]$_.Label
                    x = [int]$_.X; y = [int]$_.Y
                    width = [int]$_.Width; height = [int]$_.Height; hz = [int]$_.Hz
                    rotation = [int]$_.Rotation; rateNum = [int]$_.RateNum; rateDen = [int]$_.RateDen
                }
            })
        }
    }
    $protected = $null
    if ($Store.ProtectedSnapshot) {
        $protected = [ordered]@{
            key = [string]$Store.ProtectedSnapshot.Key
            primaryId = [string]$Store.ProtectedSnapshot.PrimaryId
            displays = @($Store.ProtectedSnapshot.Displays | ForEach-Object {
                [ordered]@{
                    id = [string]$_.Id; label = [string]$_.Label
                    x = [int]$_.X; y = [int]$_.Y
                    width = [int]$_.Width; height = [int]$_.Height; hz = [int]$_.Hz
                    rotation = [int]$_.Rotation; rateNum = [int]$_.RateNum; rateDen = [int]$_.RateDen
                }
            })
        }
    }
    $flat = [ordered]@{
        version = 2; protectedKey = [string]$Store.ProtectedKey
        protectedSnapshot = $protected
        pendingKey = [string]$Store.PendingKey
        unsafeKeys = @($Store.UnsafeKeys.Keys | Sort-Object)
        snapshots = @($saved)
    }
    $temp = $script:DesktopSnapshotsFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $json = $flat | ConvertTo-Json -Depth 6 -Compress
        [System.IO.File]::WriteAllText($temp, $json + "`r`n", (New-Object System.Text.UTF8Encoding $true))
        if (Test-Path -LiteralPath $script:DesktopSnapshotsFile) {
            [System.IO.File]::Replace($temp, $script:DesktopSnapshotsFile, [NullString]::Value)
        }
        else { [System.IO.File]::Move($temp, $script:DesktopSnapshotsFile) }
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function New-DesktopRestorePlan {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Wanted,
        [string]$PrimaryPath = '',
        [string[]]$Order = @(),
        [switch]$UseConfiguredLayout,
        [switch]$KeepMode
    )

    $wantedById = @{}
    foreach ($m in @($Wanted)) { $wantedById[[string]$m.Id] = $m }
    if ($wantedById.Count -ne @($Snapshot.Displays).Count) { return $null }
    foreach ($d in @($Snapshot.Displays)) {
        if (-not $wantedById.ContainsKey([string]$d.Id)) { return $null }
    }

    $primary = $(if ($PrimaryPath) { $PrimaryPath } else { [string]$Snapshot.PrimaryId })
    if (-not $wantedById.ContainsKey($primary)) { return $null }
    $anchor = @($Snapshot.Displays | Where-Object { $_.Id -eq $primary })[0]
    $configuredPositions = @{}
    if ($UseConfiguredLayout) {
        $configuredPositions = Get-LayoutPositions -Screens @($Snapshot.Displays | ForEach-Object {
            [pscustomobject]@{
                DevicePath = [string]$_.Id; Label = [string]$wantedById[[string]$_.Id].Label
                Width = [int]$_.Width; Height = [int]$_.Height
            }
        }) -Order $Order -PrimaryPath $primary
    }
    $targets = @()
    foreach ($d in @($Snapshot.Displays)) {
        $m = $wantedById[[string]$d.Id]
        $where = $configuredPositions[[string]$d.Id]
        $width = [int]$d.Width; $height = [int]$d.Height; $hz = [int]$d.Hz
        $rateNum = [int]$d.RateNum; $rateDen = [int]$d.RateDen
        if ($KeepMode -and $m.Active) {
            # The source size belongs to the rotation under which it was observed. Reusing it under a
            # quarter-turn would ask CCD for a different physical mode while claiming to keep it.
            $savedPortrait = ([int]$d.Rotation -eq 2 -or [int]$d.Rotation -eq 4)
            $livePortrait = ([int]$m.Rotation -eq 2 -or [int]$m.Rotation -eq 4)
            if ($savedPortrait -ne $livePortrait -or [int]$m.Width -le 0 -or [int]$m.Height -le 0 -or
                [int]$m.RateNum -le 0 -or [int]$m.RateDen -le 0) { return $null }
            $width = [int]$m.Width; $height = [int]$m.Height; $hz = [int]$m.Hz
            $rateNum = [int]$m.RateNum; $rateDen = [int]$m.RateDen
        }
        $targets += [pscustomobject][ordered]@{
            DevicePath = [string]$d.Id
            Label      = [string]$m.Label
            Width      = $width
            Height     = $height
            Hz         = $hz
            RateNum    = $rateNum
            RateDen    = $rateDen
            Rotation   = [int]$d.Rotation
            X          = $(if ($UseConfiguredLayout) { [int]$where.X } else { [int]$d.X - [int]$anchor.X })
            Y          = $(if ($UseConfiguredLayout) { [int]$where.Y } else { [int]$d.Y - [int]$anchor.Y })
        }
    }
    # Saved coordinates describe saved rectangles. A larger live mode can extend into a sleeping
    # neighbour; applying that overlap would invent a new arrangement despite -KeepMode. Refuse before
    # CCD sees anything and leave the canonical snapshot untouched for an ordinary restore.
    if ($KeepMode) {
        for ($i = 0; $i -lt $targets.Count; $i++) {
            for ($j = $i + 1; $j -lt $targets.Count; $j++) {
                $a = $targets[$i]; $b = $targets[$j]
                $overlapX = ([int]$a.X -lt [int]$b.X + [int]$b.Width -and
                             [int]$b.X -lt [int]$a.X + [int]$a.Width)
                $overlapY = ([int]$a.Y -lt [int]$b.Y + [int]$b.Height -and
                             [int]$b.Y -lt [int]$a.Y + [int]$a.Height)
                if ($overlapX -and $overlapY) { return $null }
            }
        }
    }
    $expectedState = @($targets | ForEach-Object {
        [pscustomobject]@{
            Id = [string]$_.DevicePath; Label = [string]$_.Label
            Active = $true; Disconnected = $false; Primary = ([string]$_.DevicePath -eq $primary)
            X = [int]$_.X; Y = [int]$_.Y
            Width = [int]$_.Width; Height = [int]$_.Height; Hz = [int]$_.Hz
            Rotation = [int]$_.Rotation; RateNum = [int]$_.RateNum; RateDen = [int]$_.RateDen
        }
    })
    $expected = New-DesktopSnapshot -State $expectedState
    return [pscustomobject]@{ PrimaryPath = $primary; Targets = @($targets); Expected = $expected }
}

# Build a first snapshot for a subset from physical records already observed in a larger desk. This is
# what keeps a portrait display portrait on its first solo switch: BestMode knows only width, height and
# hertz, while the source desktop also knows its rotation and exact rate.
function New-DesktopSubsetSnapshot {
    param(
        [Parameter(Mandatory)]$Wanted,
        $CurrentSnapshot,
        [Parameter(Mandatory)]$Store
    )

    $wantedList = @($Wanted)
    $wantedIds = @($wantedList | ForEach-Object { [string]$_.Id })
    $candidates = @()
    foreach ($key in @($Store.Snapshots.Keys | Sort-Object)) {
        if ($Store.PendingKey -eq $key -or $Store.UnsafeKeys.ContainsKey($key)) { continue }
        $snapshot = $Store.Snapshots[$key]
        if ($snapshot) { $candidates += $snapshot }
    }

    # Relative coordinates only have meaning inside one observation. Combining records from two solo
    # snapshots would put both displays at (0,0), even though every individual record is valid.
    $source = $null
    if ($CurrentSnapshot) {
        $currentIds = @($CurrentSnapshot.Displays | ForEach-Object { [string]$_.Id })
        if (@($wantedIds | Where-Object { $currentIds -notcontains $_ }).Count -eq 0) {
            $source = $CurrentSnapshot
        }
    }
    foreach ($snapshot in @($candidates | Sort-Object { @($_.Displays).Count }, Key)) {
        if ($source) { break }
        $ids = @($snapshot.Displays | ForEach-Object { [string]$_.Id })
        if (@($wantedIds | Where-Object { $ids -notcontains $_ }).Count -eq 0) {
            $source = $snapshot
            break
        }
    }
    if (-not $source) { return $null }

    $records = @()
    foreach ($m in $wantedList) {
        $record = @($source.Displays | Where-Object { $_.Id -eq [string]$m.Id } | Select-Object -First 1)[0]
        $records += [pscustomobject]@{
            Id = [string]$m.Id; Label = [string]$m.Label
            Active = $true; Disconnected = $false; Primary = $false
            X = [int]$record.X; Y = [int]$record.Y
            Width = [int]$record.Width; Height = [int]$record.Height; Hz = [int]$record.Hz
            Rotation = [int]$record.Rotation; RateNum = [int]$record.RateNum; RateDen = [int]$record.RateDen
        }
    }
    $primaryId = ''
    if (@($records | Where-Object { $_.Id -eq $source.PrimaryId }).Count -gt 0) {
        $primaryId = [string]$source.PrimaryId
    }
    else { $primaryId = [string]$records[0].Id }
    foreach ($r in $records) { $r.Primary = ($r.Id -eq $primaryId) }
    return (New-DesktopSnapshot -State $records)
}

function Test-DesktopSnapshotMatch {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$State)

    $now = New-DesktopSnapshot -State $State
    if (-not $now -or $now.Key -ne $Snapshot.Key -or $now.PrimaryId -ne $Snapshot.PrimaryId) { return $false }
    $byId = @{}
    foreach ($d in @($now.Displays)) { $byId[[string]$d.Id] = $d }
    foreach ($wanted in @($Snapshot.Displays)) {
        $actual = $byId[[string]$wanted.Id]
        if (-not $actual) { return $false }
        foreach ($field in 'X', 'Y', 'Width', 'Height', 'Rotation') {
            if ([int]$actual.$field -ne [int]$wanted.$field) { return $false }
        }
        # Drivers are free to reduce the same fraction (60000/1000 -> 60/1). Cross multiplication accepts
        # that normalization while still distinguishing 143999/1000 from the invented 144/1.
        if ([int64]$actual.RateNum * [int64]$wanted.RateDen -ne
            [int64]$wanted.RateNum * [int64]$actual.RateDen) { return $false }
    }
    return $true
}

# The explicit UI action for adopting a rearranged Windows desktop. Ordinary Settings saves must never
# call this: taking a baseline is a physical observation, not a side effect of editing a shortcut.
function Save-CurrentDesktopSnapshot {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\DeskModesSwitch')
    $held = $false
    try { $held = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { $mutex.Dispose(); return $false }
    try {
        $snapshot = New-DesktopSnapshot -State @(Get-DisplayState)
        if (-not $snapshot) { return $false }
        $store = Read-DesktopSnapshotStore
        $store.Snapshots[$snapshot.Key] = $snapshot
        if ($store.PendingKey -eq $snapshot.Key) { $store.PendingKey = '' }
        [void]$store.UnsafeKeys.Remove($snapshot.Key)
        $store.ProtectedKey = $snapshot.Key
        $store.ProtectedSnapshot = $null
        Write-DesktopSnapshotStore -Store $store
        Write-DisplayLog ("desktop: adopted the current physical arrangement - {0} display(s)" -f $snapshot.Displays.Count)
        return $true
    }
    catch {
        Write-DisplayLog "warn: could not remember the current physical desktop - $($_.Exception.Message)"
        return $false
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Get-WatchdogMode {
    param($Monitor, $ProtectedSnapshot)

    if ($ProtectedSnapshot) {
        $saved = @($ProtectedSnapshot.Displays | Where-Object { $_.Id -eq [string]$Monitor.Id } |
                   Select-Object -First 1)
        if ($saved.Count -gt 0) {
            return [pscustomobject]@{
                Width = [int]$saved[0].Width; Height = [int]$saved[0].Height; Hz = [int]$saved[0].Hz
            }
        }
    }
    return $Monitor.BestMode
}

# The target state of every monitor for a one-call transition: DevicePath, Label, Width, Height, Hz. An
# empty array means "this will not work" — the caller takes the old road of three steps.
#
# Where the sizes come from, in descending order of trust:
#   1. BestMode — already worked out by Get-DisplayState for a monitor that is on;
#   2. the cache of verified modes — for one that is asleep right now (see Get-ModeCache);
#   3. the native resolution out of EDID — present even for one that has gone out, but with no refresh rate.
# With -KeepMode nobody is asking for the resolution or the refresh rate to change, so for a monitor that is
# on we take what it is standing at.
#
# The refresh rate travels onward as a FRACTION and only out of the cache: CCD accepts nothing but the exact
# value (144 Hz here is 143999/1000), whereas the whole hertz out of EnumDisplaySettings are rounded and a
# request by them the system rejects. A fraction is only good if it is from THE SAME mode: the cache
# remembers 144 Hz while 240 is being asked for — so we have no fraction for 240, the system will choose the
# rate, and the repair step will bring it up and teach the cache for next time.
#
# A pure function: it asks the system nothing and only works things out.
function Get-SwitchTargets {
    param(
        [Parameter(Mandatory)]$Wanted,
        $Cache = @{},
        [switch]$KeepMode
    )

    if (-not $Cache) { $Cache = @{} }
    $out = @()
    foreach ($m in @($Wanted)) {
        $w = 0; $h = 0; $hz = 0
        $cached = $null
        if ($Cache.ContainsKey([string]$m.Id)) { $cached = $Cache[[string]$m.Id] }

        if ($KeepMode -and $m.Active -and $m.Width -gt 0 -and $m.Height -gt 0) {
            $w = [int]$m.Width; $h = [int]$m.Height; $hz = [int]$m.Hz
        }
        elseif (-not $KeepMode -and $m.BestMode) {
            $w = [int]$m.BestMode.Width; $h = [int]$m.BestMode.Height; $hz = [int]$m.BestMode.Hz
        }
        elseif ($cached) {
            $w = [int]$cached.Width; $h = [int]$cached.Height
            # With -KeepMode we do not force a refresh rate: the person asked us not to touch the mode.
            if (-not $KeepMode) { $hz = [int]$cached.Hz }
        }
        elseif ($m.Native) {
            $w = [int]$m.Native.Width; $h = [int]$m.Native.Height
        }

        # There is not one size — there is nothing to set the source mode with, and mixing specified with
        # unspecified in one request means guessing what the system will do with the remainder. Such a set
        # goes to the old road whole.
        if ($w -le 0 -or $h -le 0) { return @() }

        $num = 0; $den = 0
        if ($hz -gt 0 -and $cached -and [int]$cached.RateDen -gt 0 -and
            [int]$cached.Width -eq $w -and [int]$cached.Height -eq $h -and [int]$cached.Hz -eq $hz) {
            $num = [int]$cached.RateNum; $den = [int]$cached.RateDen
        }

        $out += [pscustomobject]@{
            DevicePath = [string]$m.Id
            Label      = [string]$m.Label
            Width      = $w
            Height     = $h
            Hz         = $hz
            RateNum    = $num
            RateDen    = $den
        }
    }
    return $out
}

# --- parsing key combinations -----------------------------------------------

$script:ModAlt = 0x1; $script:ModControl = 0x2; $script:ModShift = 0x4
$script:ModWin = 0x8; $script:ModNoRepeat = 0x4000

# "Ctrl+Alt+F1" -> @{ Modifiers = 3; Vk = 0x70 }. $null if it cannot be parsed.
function ConvertFrom-HotkeyString {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $mods = 0
    $key = $null
    foreach ($part in ($Text -split '\+')) {
        switch ($part.Trim().ToUpperInvariant()) {
            'CTRL'    { $mods = $mods -bor $script:ModControl }
            'CONTROL' { $mods = $mods -bor $script:ModControl }
            'ALT'     { $mods = $mods -bor $script:ModAlt }
            'SHIFT'   { $mods = $mods -bor $script:ModShift }
            'WIN'     { $mods = $mods -bor $script:ModWin }
            default   { $key = $part.Trim().ToUpperInvariant() }
        }
    }
    if (-not $key) { return $null }

    $vk = 0
    if ($key -match '^F([1-9]|1[0-9]|2[0-4])$') { $vk = 0x70 + [int]$Matches[1] - 1 }
    elseif ($key -match '^[A-Z]$')              { $vk = [int][char]$key }
    elseif ($key -match '^[0-9]$')              { $vk = 0x30 + [int]$key }
    else { return $null }

    # Without a modifier a global shortcut would take the key away from the whole system.
    if ($mods -eq 0) { return $null }

    return [pscustomobject]@{ Modifiers = $mods; Vk = $vk; Text = (Format-HotkeyString -Modifiers $mods -Vk $vk) }
}

function Format-HotkeyString {
    param([int]$Modifiers, [int]$Vk)

    $parts = @()
    if ($Modifiers -band $script:ModControl) { $parts += 'Ctrl' }
    if ($Modifiers -band $script:ModAlt)     { $parts += 'Alt' }
    if ($Modifiers -band $script:ModShift)   { $parts += 'Shift' }
    if ($Modifiers -band $script:ModWin)     { $parts += 'Win' }

    $key = ''
    if ($Vk -ge 0x70 -and $Vk -le 0x87)      { $key = 'F' + ($Vk - 0x70 + 1) }
    elseif ($Vk -ge 0x41 -and $Vk -le 0x5A)  { $key = [char]$Vk }
    elseif ($Vk -ge 0x30 -and $Vk -le 0x39)  { $key = [char]$Vk }
    else                                     { $key = "VK$Vk" }

    $parts += $key
    return ($parts -join '+')
}

# --- the theme --------------------------------------------------------------
# The tray menu and the Settings window are drawn to match the system theme. Both facts — whether the
# theme is dark and what the accent colour is — Windows keeps in the registry; there is still no official
# API for Win32 applications (UISettings is WinRT, and dragging that into PowerShell 5.1 costs more than
# reading two values). It is read on every menu or window open, so a change of theme is picked up without
# a restart.

# Whether the APPS theme is dark (in Windows that is separate from the system theme). The value is absent
# on older builds — and then it is light, as it was before dark existed.
function Test-DarkTheme {
    try {
        $v = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
                              -Name 'AppsUseLightTheme' -ErrorAction Stop
        return ($v.AppsUseLightTheme -eq 0)
    }
    catch { return $false }
}

# The system's accent colour, as a #RRGGBB string.
#
# The main source is AccentPalette: 8 colours of 4 RGBA bytes each, from light to dark, the base one being
# the fourth (index 3). It is needed because the palette has lightened variants: on a dark background the
# accent itself is often unreadable (Windows lets it be almost black), and in a dark theme the system uses
# light2 (index 1) — which is what -ForDarkTheme asks for. No palette — we take the DWM AccentColor (an
# ABGR number there); none of that either — blue by default, as Windows has out of the box.
function Get-AccentColor {
    param([switch]$ForDarkTheme)

    try {
        $pal = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent' `
                                 -Name 'AccentPalette' -ErrorAction Stop).AccentPalette
        if ($pal -and $pal.Count -ge 32) {
            $i = $(if ($ForDarkTheme) { 1 } else { 3 }) * 4
            return ('#{0:X2}{1:X2}{2:X2}' -f $pal[$i], $pal[$i + 1], $pal[$i + 2])
        }
    }
    catch { }   # the key is absent or of another shape — the fallback path is below

    try {
        $abgr = [uint32]((Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' `
                                           -Name 'AccentColor' -ErrorAction Stop).AccentColor)
        return ('#{0:X2}{1:X2}{2:X2}' -f ($abgr -band 0xFF), (($abgr -shr 8) -band 0xFF), (($abgr -shr 16) -band 0xFF))
    }
    catch { }   # this key is missing too — the out-of-the-box blue is what is left

    return $(if ($ForDarkTheme) { '#4CC2FF' } else { '#0067C0' })
}

# --- Windows API ------------------------------------------------------------
# Every class lives in ONE source and is compiled by one call: each Add-Type -TypeDefinition is a separate
# compilation, and four of those cost a third of a second on every CLI run and on every tray start.

$script:NativeSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class NativeDisplay {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields;
        public int dmPositionX, dmPositionY;
        public int dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType;
        public int dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, int dwflags, IntPtr lParam);

    public const int CURRENT_SETTINGS = -1;

    public const int DM_BITSPERPEL = 0x00040000;
    public const int DM_PELSWIDTH = 0x00080000;
    public const int DM_PELSHEIGHT = 0x00100000;
    public const int DM_DISPLAYFREQUENCY = 0x00400000;

    public const int CDS_UPDATEREGISTRY = 0x00000001;
    public const int PRIMARY_DEVICE = 0x00000004;
}

// --- CCD: the modern display configuration API ---------------------------
// Why the state is read with it rather than with the old API:
//
// 1. Speed. QueryDisplayConfig answers in ~1 ms, and the state is asked for on every switch, on every
//    menu open and on every firing of the watchdog.
// 2. A monitor that is switched off. CCD enumerates inactive targets too, keeping their name and device
//    path — otherwise there would be nothing to switch a darkened monitor back on with.
// 3. The native resolution. GET_TARGET_PREFERRED_MODE hands back the preferred timing out of EDID by the
//    system's own effort — and for a monitor that is switched off as well. There is no need to parse EDID
//    out of the registry by hand.
public class NativeCcd {
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] public struct RATIONAL { public uint Numerator, Denominator; }

    [StructLayout(LayoutKind.Sequential)] public struct SOURCE_INFO {
        public LUID adapterId; public uint id, modeInfoIdx, statusFlags; }

    [StructLayout(LayoutKind.Sequential)] public struct TARGET_INFO {
        public LUID adapterId; public uint id, modeInfoIdx, outputTechnology, rotation, scaling;
        public RATIONAL refreshRate; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags; }

    [StructLayout(LayoutKind.Sequential)] public struct PATH_INFO {
        public SOURCE_INFO sourceInfo; public TARGET_INFO targetInfo; public uint flags; }

    // An explicit layout: only the source mode's fields are needed out of the union — the position, by
    // which Windows determines the primary monitor. The rest (the target's timings) we do not touch, so
    // there is simply room left for it. The size has to be 64 bytes.
    [StructLayout(LayoutKind.Explicit)] public struct MODE_INFO {
        [FieldOffset(0)]  public uint infoType;
        [FieldOffset(4)]  public uint id;
        [FieldOffset(8)]  public LUID adapterId;
        [FieldOffset(16)] public uint srcWidth;
        [FieldOffset(20)] public uint srcHeight;
        [FieldOffset(24)] public uint srcPixelFormat;
        [FieldOffset(28)] public int  srcPosX;
        [FieldOffset(32)] public int  srcPosY;
        [FieldOffset(56)] public ulong tail; }

    [StructLayout(LayoutKind.Sequential)] public struct HEADER {
        public uint type, size; public LUID adapterId; public uint id; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct TARGET_DEVICE_NAME {
        public HEADER header; public uint flags, outputTechnology;
        public ushort edidManufactureId, edidProductCodeId; public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct SOURCE_DEVICE_NAME {
        public HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName; }

    [StructLayout(LayoutKind.Sequential)] public struct VIDEO_SIGNAL_INFO {
        public ulong pixelRate; public RATIONAL hSyncFreq, vSyncFreq;
        public uint activeCx, activeCy, totalCx, totalCy, misc, scanLineOrdering; }

    [StructLayout(LayoutKind.Sequential)] public struct TARGET_PREFERRED_MODE {
        public HEADER header; public uint width, height; public VIDEO_SIGNAL_INFO targetMode; }

    [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint flags, ref uint numPath, ref uint numMode);
    [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint flags, ref uint numPath, [Out] PATH_INFO[] paths, ref uint numMode, [Out] MODE_INFO[] modes, IntPtr info);
    [DllImport("user32.dll")] public static extern int SetDisplayConfig(uint numPath, [In] PATH_INFO[] paths, uint numMode, [In] MODE_INFO[] modes, uint flags);
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref TARGET_DEVICE_NAME d);
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref SOURCE_DEVICE_NAME d);
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref TARGET_PREFERRED_MODE d);

    // HDR. It survives a change in the set of monitors by itself (verified 2026-08-11), so a switch never
    // has to RESTORE it; what these two calls are for is a mode that WANTS it one way - HDR on for the
    // game, off for the spreadsheet next to it. The value word is a bitfield: bit 0 says the display can
    // do advanced colour at all, bit 1 says it is on. The set call takes bit 0 as "turn it on".
    [StructLayout(LayoutKind.Sequential)] public struct ADVANCED_COLOR_INFO {
        public HEADER header; public uint value, colorEncoding, bitsPerColorChannel; }
    [StructLayout(LayoutKind.Sequential)] public struct ADVANCED_COLOR_STATE {
        public HEADER header; public uint value; }
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref ADVANCED_COLOR_INFO d);
    [DllImport("user32.dll")] public static extern int DisplayConfigSetDeviceInfo(ref ADVANCED_COLOR_STATE d);
    public const uint GET_ADVANCED_COLOR_INFO = 9;
    public const uint SET_ADVANCED_COLOR_STATE = 10;
    public const uint ADVANCED_COLOR_SUPPORTED = 1;
    public const uint ADVANCED_COLOR_ENABLED = 2;

    public const uint QDC_ALL_PATHS = 1;
    public const uint QDC_ONLY_ACTIVE_PATHS = 2;

    public const uint GET_SOURCE_NAME = 1;
    public const uint GET_TARGET_NAME = 2;
    public const uint GET_TARGET_PREFERRED_MODE = 3;

    public const uint PATH_ACTIVE = 0x00000001;
    public const uint MODE_IDX_INVALID = 0xFFFFFFFF;
    public const uint MODE_INFO_TYPE_SOURCE = 1;

    // The source mode's pixel format: 32 bits. Mandatory when we set the mode ourselves
    // (Set-CcdFullConfig): a zero here is an invalid value, and validation answers with a refusal.
    public const uint PIXELFORMAT_32BPP = 4;
    // The target's scanning: progressive. It goes together with the refresh rate, when the rate is passed
    // as a hint in targetInfo (see Set-CcdFullConfig).
    public const uint SCANLINE_PROGRESSIVE = 1;
    // No rotation and no scaling. Needed in the same place: for a path that has GONE OUT the system hands
    // these fields back as zeroes, and a zero is invalid in both enumerations, and together with a
    // specified refresh rate such a path fails validation.
    public const uint ROTATION_IDENTITY = 1;
    public const uint SCALING_IDENTITY = 1;

    public const uint SDC_VALIDATE = 0x00000040;
    public const uint SDC_APPLY = 0x00000080;
    public const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;
    public const uint SDC_ALLOW_CHANGES = 0x00000400;
    public const uint SDC_SAVE_TO_DATABASE = 0x00000200;
}

public class NativeForeground {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public int dwFlags;
    }

    [DllImport("shell32.dll")]
    public static extern int SHQueryUserNotificationState(out int pquns);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    [DllImport("user32.dll", EntryPoint = "GetClassNameW", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    public const uint MONITOR_DEFAULTTONEAREST = 2;

    // The tells of a window that is not on the desk. The very same ones NativeWindows.Enumerate() already
    // filters out for the window-position snapshots: the rule is one, but it was known in one place out of
    // two.
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out int value, int size);

    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int DWMWA_CLOAKED = 14;

    // DWM "hides" a window without closing it: IsWindowVisible still says yes, while it is not on the
    // screen. That is exactly what TextInputHost looks like — the system input window, exactly the size of
    // the monitor.
    public static bool IsCloaked(IntPtr hWnd) {
        int cloaked = 0;
        try { if (DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, out cloaked, sizeof(int)) == 0) return cloaked != 0; }
        catch { }   // the attribute is absent on older builds — we take the window to be visible
        return false;
    }

    // No taskbar button and no Alt-Tab. A game does not set that on itself, whereas overlays like the
    // NVIDIA Overlay do.
    public static bool IsToolWindow(IntPtr hWnd) {
        return (GetWindowLong(hWnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0;
    }
}

// Brightness and contrast go over DDC/CI, a service channel inside the cable. It is the same path the
// buttons on the monitor's bezel work over, and there is no other way: on an external monitor the
// brightness lives in its firmware rather than in Windows (the WMI class WmiMonitorBrightnessMethods only
// answers on laptops' built-in screens).
//
// A physical monitor's handle is taken from an HMONITOR, and that comes from a walk of
// EnumDisplayMonitors. We tie it to our own state by the output name (\\.\DISPLAY1) out of MONITORINFOEX:
// the description ("Generic PnP Monitor") is no good — it is the same on all three monitors on this
// machine.
//
// IMPORTANT about speed: one DDC request costs tens of milliseconds, and sometimes over a hundred — the
// bus is slow. So we read everything at once in one walk, and write only what was asked for, and only to
// the monitors that are on right now: a sleeping monitor does not answer a request at all, and there is
// nothing to wait for.
public class MonitorLevels {
    public string Device;
    public string Description;
    public bool CanBrightness;
    public bool CanContrast;
    public int Brightness, BrightnessMin, BrightnessMax;
    public int Contrast, ContrastMin, ContrastMax;
}

public class NativeDdc {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX {
        public int cbSize;
        public int mLeft, mTop, mRight, mBottom;
        public int wLeft, wTop, wRight, wBottom;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PHYSICAL_MONITOR {
        public IntPtr handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string description;
    }

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr rect, IntPtr data);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr rect, MonitorEnumProc proc, IntPtr data);

    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfoEx(IntPtr hMonitor, ref MONITORINFOEX info);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetMonitorBrightness(IntPtr h, out uint min, out uint current, out uint max);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetMonitorBrightness(IntPtr h, uint value);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetMonitorContrast(IntPtr h, out uint min, out uint current, out uint max);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetMonitorContrast(IntPtr h, uint value);

    // The picture preset - what the monitor's own menu calls Reader, FPS, sRGB, Cinema. Brightness has
    // one standard code and one meaning everywhere; this has neither, so it goes through the raw VCP
    // pair instead of a named helper. Which register answers is decided per monitor at the moment a
    // preset is remembered, and the number behind a name is the vendor's to choose.
    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out int type, out uint current, out uint maximum);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetVCPFeature(IntPtr h, byte code, uint value);

    [DllImport("dxva2.dll")]
    private static extern bool DestroyPhysicalMonitor(IntPtr h);

    // Output name -> the handles of its physical monitors. There can be more than one: an HMONITOR is
    // an area of the desktop, and in duplicate mode two real monitors stand behind it.
    private static List<KeyValuePair<string, PHYSICAL_MONITOR>> Open() {
        var found = new List<KeyValuePair<string, PHYSICAL_MONITOR>>();
        var screens = new List<IntPtr>();
        MonitorEnumProc collect = delegate(IntPtr h, IntPtr hdc, IntPtr rect, IntPtr data) {
            screens.Add(h); return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, collect, IntPtr.Zero);

        foreach (IntPtr screen in screens) {
            var info = new MONITORINFOEX();
            info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (!GetMonitorInfoEx(screen, ref info)) { continue; }

            uint count;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(screen, out count) || count == 0) { continue; }
            var physical = new PHYSICAL_MONITOR[count];
            if (!GetPhysicalMonitorsFromHMONITOR(screen, count, physical)) { continue; }
            foreach (PHYSICAL_MONITOR p in physical) {
                found.Add(new KeyValuePair<string, PHYSICAL_MONITOR>(info.szDevice, p));
            }
        }
        return found;
    }

    // One failure on this bus is normal, not an answer. The I2C inside the cable was never designed for
    // reliability: the monitor answers late, muddles the checksum (0xC0262589 — "an invalid command in
    // the message"), stays quiet while it is busy with its own menu. Verified on this machine: the same
    // call to the same monitor sometimes goes through and sometimes does not. So three attempts with a
    // pause are part of the job rather than belt and braces; the last error stays in GetLastWin32Error
    // for the log.
    private const int Tries = 3;
    private const int PauseMs = 60;

    // How long to wait for confirmation from a monitor that has only just been switched on. A second and
    // a half in the worst case and not one extra pause in the ordinary one (see the confirmation loop in
    // Set). Waking over DDC is measured in hundreds of milliseconds: 120 ms is enough for one that was
    // already working and not enough for one that woke up during this same switch.
    private const int ConfirmPasses = 6;
    private const int ConfirmPauseMs = 250;

    public static int LastError;

    private static bool WithRetry(Func<bool> call) {
        for (int i = 0; i < Tries; i++) {
            if (call()) { return true; }
            LastError = Marshal.GetLastWin32Error();
            if (i + 1 < Tries) { System.Threading.Thread.Sleep(PauseMs); }
        }
        return false;
    }

    // What a monitor answers on one register right now. One try and not three: this is asked of
    // registers a monitor may not have at all (0xDC on an LG is a refusal, not a hiccup), and paying
    // three times 60 ms for every "no" would make asking the desk a second-long affair.
    private static bool ReadVcp(IntPtr handle, byte code, out uint current) {
        int type = 0; uint cur = 0, max = 0;
        bool ok = GetVCPFeatureAndVCPFeatureReply(handle, code, out type, out cur, out max);
        if (!ok) { LastError = Marshal.GetLastWin32Error(); }
        current = cur;
        return ok;
    }

    // What preset a monitor is holding right now, and on which register. The codes are tried in the
    // order given: the standard 0xDC first, the vendor ones after it. Answered == false means nobody
    // answered anything, which is a different thing from "the preset is 0".
    public class Picture {
        public string Device;
        public string Description;
        public bool Answered;
        public int Code = -1;
        public int Value = -1;
    }

    public static List<Picture> ReadPicture(int[] codes) {
        var result = new List<Picture>();
        foreach (var pair in Open()) {
            var one = new Picture();
            one.Device = pair.Key;
            one.Description = pair.Value.description;
            IntPtr handle = pair.Value.handle;
            foreach (int code in codes) {
                uint current = 0;
                if (ReadVcp(handle, (byte)code, out current)) {
                    one.Answered = true;
                    one.Code = code;
                    one.Value = (int)current;
                    break;
                }
            }
            DestroyPhysicalMonitor(handle);
            result.Add(one);
        }
        return result;
    }

    public static List<MonitorLevels> Read() {
        var result = new List<MonitorLevels>();
        foreach (var pair in Open()) {
            var level = new MonitorLevels();
            level.Device = pair.Key;
            level.Description = pair.Value.description;
            IntPtr handle = pair.Value.handle;

            uint bMin = 0, bCur = 0, bMax = 0;
            if (WithRetry(delegate { return GetMonitorBrightness(handle, out bMin, out bCur, out bMax); })) {
                level.CanBrightness = true;
                level.BrightnessMin = (int)bMin; level.Brightness = (int)bCur; level.BrightnessMax = (int)bMax;
            }
            uint cMin = 0, cCur = 0, cMax = 0;
            if (WithRetry(delegate { return GetMonitorContrast(handle, out cMin, out cCur, out cMax); })) {
                level.CanContrast = true;
                level.ContrastMin = (int)cMin; level.Contrast = (int)cCur; level.ContrastMax = (int)cMax;
            }
            DestroyPhysicalMonitor(handle);
            result.Add(level);
        }
        return result;
    }

    // The result of setting, one line per monitor asked for. Three states rather than two, because there
    // really are three: it worked, it was refused, and "we said so but there is no confirmation".
    public class Applied {
        public string Device;
        public bool Found;
        public bool BrightnessAsked, BrightnessConfirmed;
        public bool ContrastAsked, ContrastConfirmed;
        // Whether the monitor answered the re-read at all, and what exactly it answered. Without this,
        // "did not confirm" merges two different cases into one: the monitor is quiet (still waking) and
        // the monitor answers with somebody else's number (a refusal, DDC/CI switched off in its menu).
        // Advising "check the menu" in the first case is a lie.
        public bool BrightnessRead, ContrastRead;
        public int BrightnessActual = -1, ContrastActual = -1;
        public bool PictureAsked, PictureConfirmed, PictureRead;
        public int PictureActual = -1;
    }

    // DDC/CI writes REQUIRE NO ANSWER: SetMonitorBrightness returned true for a monitor that answers a
    // read of that same brightness with a refusal (verified on 21 August on an LG UltraGear with a stuck
    // bus). That is, the return code here means "the message went out" rather than "the monitor obeyed",
    // and it cannot be trusted: this project's log exists precisely because other people's switchers lied
    // about success. So every value is read back and compared.
    //
    // ALL the monitors at once, in one walk — as in Read(), and for the same reason. Set used to take one
    // monitor, and on three monitors the enumeration with the opening and closing of ALL the handles went
    // round three times: nine open/destroy pairs instead of three on a slow bus where one request costs
    // tens of milliseconds. At the same time the "let it apply" pause is now one for everybody: the
    // monitors wait in parallel rather than in turn, and that saves 120 ms for every monitor past the first.
    //
    // The brightness and contrast arrays go by the indices of devices; -1 means "this one was not asked
    // for".
    // pictureCode/pictureValue go by the indices of devices, like the levels; -1 in the code means
    // "this one has no preset to set". The preset goes out BEFORE brightness and contrast: on some LG
    // presets those two are locked in the monitor's own menu, and a level written before the preset
    // would land in a monitor that is about to forget it.
    public static List<Applied> Set(string[] devices, int[] brightness, int[] contrast,
                                    int[] pictureCode, int[] pictureValue) {
        var result = new List<Applied>();
        for (int i = 0; i < devices.Length; i++) {
            var a = new Applied();
            a.Device = devices[i];
            result.Add(a);
        }

        var open = Open();
        try {
            // Which request row belongs to which of the opened monitors; -1 — this one was not asked for.
            // Worked out in advance so that the walk is a single one with no searching inside it: in
            // duplicate mode two monitors stand behind one output, and the second must not be given the
            // same row.
            var slot = new int[open.Count];
            for (int j = 0; j < open.Count; j++) {
                slot[j] = -1;
                for (int i = 0; i < devices.Length; i++) {
                    if (devices[i] == open[j].Key && !result[i].Found) {
                        slot[j] = i;
                        result[i].Found = true;
                        break;
                    }
                }
            }

            bool asked = false;
            for (int j = 0; j < open.Count; j++) {
                if (slot[j] < 0) { continue; }
                Applied a = result[slot[j]];
                IntPtr handle = open[j].Value.handle;
                int wantB = brightness[slot[j]];
                int wantC = contrast[slot[j]];
                int wantCode = pictureCode[slot[j]];
                int wantPicture = pictureValue[slot[j]];
                if (wantCode >= 0) {
                    byte code = (byte)wantCode;
                    uint value = (uint)wantPicture;
                    a.PictureAsked = WithRetry(delegate { return SetVCPFeature(handle, code, value); });
                }
                if (wantB >= 0) {
                    a.BrightnessAsked = WithRetry(delegate { return SetMonitorBrightness(handle, (uint)wantB); });
                }
                if (wantC >= 0) {
                    a.ContrastAsked = WithRetry(delegate { return SetMonitorContrast(handle, (uint)wantC); });
                }
                if (a.BrightnessAsked || a.ContrastAsked || a.PictureAsked) { asked = true; }
            }

            // The monitor needs time to apply it and start answering with the new value: right after the
            // write it still hands back the old one.
            if (asked) { System.Threading.Thread.Sleep(120); }

            // The confirmation is SEVERAL passes with a pause, not one question. A monitor that has just
            // been switched on by a change of set stays quiet on the first question: on 21 August the
            // ULTRAFINE took brightness 60 (a re-read a second later showed it) but had no time to confirm
            // right after waking — and the log wrote "did not take" about a value the monitor had accepted.
            // Blaming a monitor for nothing costs more than waiting. Only those that have not answered yet
            // pay for this: the passes stop as soon as everybody has confirmed (the ordinary case is on the
            // first try, without a single extra pause).
            for (int pass = 0; pass < ConfirmPasses; pass++) {
                bool waiting = false;
                for (int j = 0; j < open.Count; j++) {
                    if (slot[j] < 0) { continue; }
                    Applied a = result[slot[j]];
                    IntPtr handle = open[j].Value.handle;

                    if (a.PictureAsked && !a.PictureConfirmed) {
                        uint current = 0;
                        if (ReadVcp(handle, (byte)pictureCode[slot[j]], out current)) {
                            a.PictureRead = true;
                            a.PictureActual = (int)current;
                            a.PictureConfirmed = ((int)current == pictureValue[slot[j]]);
                        }
                        if (!a.PictureConfirmed) { waiting = true; }
                    }
                    if (a.BrightnessAsked && !a.BrightnessConfirmed) {
                        uint min = 0, cur = 0, max = 0;
                        // One question, without WithRetry: the retry here IS the outer loop, and its pause
                        // is longer — silence after waking is measured in hundreds of milliseconds rather
                        // than tens.
                        if (GetMonitorBrightness(handle, out min, out cur, out max)) {
                            a.BrightnessRead = true;
                            a.BrightnessActual = (int)cur;
                            a.BrightnessConfirmed = ((int)cur == brightness[slot[j]]);
                        }
                        else { LastError = Marshal.GetLastWin32Error(); }
                        if (!a.BrightnessConfirmed) { waiting = true; }
                    }
                    if (a.ContrastAsked && !a.ContrastConfirmed) {
                        uint min = 0, cur = 0, max = 0;
                        if (GetMonitorContrast(handle, out min, out cur, out max)) {
                            a.ContrastRead = true;
                            a.ContrastActual = (int)cur;
                            a.ContrastConfirmed = ((int)cur == contrast[slot[j]]);
                        }
                        else { LastError = Marshal.GetLastWin32Error(); }
                        if (!a.ContrastConfirmed) { waiting = true; }
                    }
                }
                if (!waiting) { break; }
                if (pass + 1 < ConfirmPasses) { System.Threading.Thread.Sleep(ConfirmPauseMs); }
            }
        }
        finally {
            // The handles are closed in any case: the tray process lives for weeks, and a leak of one per
            // monitor per switch would eat it.
            foreach (var pair in open) { DestroyPhysicalMonitor(pair.Value.handle); }
        }
        return result;
    }
}

// Sleep is the only state with no console command for it: shutdown.exe can do a shutdown, a reboot and a
// hibernation, and "sleep" is not in it at all.
//
// The other four are "how long until the displays go dark", which is Windows' own setting and not ours.
// Through the API and never through powercfg.exe: its output is LOCALISED - on a Russian Windows the line
// to parse reads "Текущий индекс параметра питания от сети" - and parsing a translated table is the same
// trap as matching Smart App Control on the text of its error instead of on the number.
//
// PowerGetActiveScheme allocates the GUID it hands back, so it is freed with LocalFree; a write is
// PowerWriteACValueIndex followed by PowerSetActiveScheme, because the write alone changes the stored
// scheme without applying it.
public class NativePower {
    [DllImport("powrprof.dll", SetLastError = true)]
    public static extern bool SetSuspendState(bool hibernate, bool force, bool wakeupEventsDisabled);

    [DllImport("powrprof.dll")]
    public static extern uint PowerGetActiveScheme(IntPtr rootPowerKey, out IntPtr activePolicyGuid);
    [DllImport("powrprof.dll")]
    public static extern uint PowerReadACValueIndex(IntPtr rootPowerKey, ref Guid scheme, ref Guid subGroup,
                                                    ref Guid setting, ref uint value);
    [DllImport("powrprof.dll")]
    public static extern uint PowerWriteACValueIndex(IntPtr rootPowerKey, ref Guid scheme, ref Guid subGroup,
                                                     ref Guid setting, uint value);
    [DllImport("powrprof.dll")]
    public static extern uint PowerSetActiveScheme(IntPtr rootPowerKey, ref Guid scheme);
    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr mem);
}

// Who is in the foreground right now, on which monitor, and how long ago the keyboard was last touched.
// Needed by the rules (the "nobody is working at the computer" condition) and by the diary.
//
// Window titles are deliberately NOT read: a window's title holds the document's name, the page address
// and the text of an email, whereas the process name is enough for "how much time in what". What is not
// there cannot leak.
public class ActivitySample {
    public string Process;
    public string Device;
    public int IdleSeconds;
}

public class NativeActivity {
    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX {
        public int cbSize;
        public int mLeft, mTop, mRight, mBottom;
        public int wLeft, wTop, wRight, wBottom;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfoEx(IntPtr hMonitor, ref MONITORINFOEX info);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(int access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageNameW(IntPtr h, int flags, StringBuilder name, ref int size);

    private const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint MONITOR_DEFAULTTONULL = 0;

    public static int IdleSeconds() {
        var info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref info)) { return 0; }
        // Both counters are 32-bit and wrap round after 49 days. Subtraction in unsigned arithmetic
        // survives the wrap correctly, a cast to int afterwards does not, so we subtract first and cast
        // second.
        uint now = (uint)Environment.TickCount;
        return (int)((now - info.dwTime) / 1000);
    }

    public static ActivitySample Sample() {
        var sample = new ActivitySample();
        sample.Process = "";
        sample.Device = "";
        sample.IdleSeconds = IdleSeconds();

        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) { return sample; }

        IntPtr screen = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL);
        if (screen != IntPtr.Zero) {
            var info = new MONITORINFOEX();
            info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (GetMonitorInfoEx(screen, ref info)) { sample.Device = info.szDevice; }
        }

        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        if (pid == 0) { return sample; }
        IntPtr proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (proc == IntPtr.Zero) { return sample; }
        try {
            var name = new StringBuilder(1024);
            int size = name.Capacity;
            if (QueryFullProcessImageNameW(proc, 0, name, ref size)) {
                string full = name.ToString();
                int slash = full.LastIndexOf('\\');
                string file = slash >= 0 ? full.Substring(slash + 1) : full;
                if (file.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) {
                    file = file.Substring(0, file.Length - 4);
                }
                sample.Process = file;
            }
        }
        finally { CloseHandle(proc); }
        return sample;
    }
}

// Give the system back memory that was needed once. After startup a PowerShell process holds ~75 MB of
// working set, but only about ten of it is live: the rest is left over from the compilation, from reading
// the settings and from building the menu for the first time. Trimming does not lie to Task Manager: the
// pages go to the standby list, the system hands them out to whoever needs them, and they come back to us
// on demand — at the cost of milliseconds on the first menu open after a trim.
public class NativeMemory {
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern bool SetProcessWorkingSetSize(IntPtr process, IntPtr min, IntPtr max);

    public static void Trim() {
        SetProcessWorkingSetSize(GetCurrentProcess(), (IntPtr)(-1), (IntPtr)(-1));
    }
}

// Audio: the list of output devices and assigning the default one.
//
// No external .exe is needed. The list comes from the documented IMMDeviceEnumerator, and the assignment
// from the undocumented IPolicyConfig: there is no public API in Windows at all for "make this device the
// default one", every audio switcher uses this one, and it has not changed in many years.
//
// CAREFUL with the order of the methods in IPolicyConfig. A COM interface's methods are called by their
// slot number in the table rather than by name: miss out or muddle even one, and the call will go to the
// NEIGHBOURING function — into SetDeviceFormat with rubbish instead of a format, for instance. So all
// twelve slots are declared in exact order, even though only one of them is needed — the eleventh.
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorComObject { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
}

[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceCollection {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int Item(int index, out IMMDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    [PreserveSig] int OpenPropertyStore(int stgmAccess, out IPropertyStore properties);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out int state);
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int GetAt(int index, out PROPERTYKEY key);
    [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
    [PreserveSig] int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
    [PreserveSig] int Commit();
}

[StructLayout(LayoutKind.Sequential)]
public struct PROPERTYKEY { public Guid fmtid; public int pid; }

// Only one case out of the union is needed — VT_LPWSTR. On x64 the data starts at the eighth byte, so
// that is where the pointer lies.
//
// Size is stated OUTRIGHT, and it is not decoration: the real PROPVARIANT is 24 bytes on x64 (8 of
// header plus a 16-byte union), while these two fields measure 16. GetValue below writes a whole
// PROPVARIANT into the buffer the marshaller lays out from this declaration — that is, eight bytes past
// its end. Nothing visible ever came of it, which is exactly what makes it worth naming.
[StructLayout(LayoutKind.Explicit, Size = 24)]
public struct PROPVARIANT {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pointerValue;
}

[ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
public class PolicyConfigComObject { }

[ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPolicyConfig {
    [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr format);
    [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool isDefault, out IntPtr format);
    [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
    [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
    [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool isDefault, out IntPtr defaultPeriod, out IntPtr minimumPeriod);
    [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr period);
    [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr mode);
    [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
    [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool isFxStore, ref PROPERTYKEY key, out PROPVARIANT value);
    [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool isFxStore, ref PROPERTYKEY key, IntPtr value);
    [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int role);
    [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool visible);
}

public class AudioDev {
    public string Id;
    public string Name;
    public bool IsDefault;
}

public class NativeAudio {
    private const int RENDER = 0;              // eRender: output, not capture
    private const int DEVICE_STATE_ACTIVE = 1; // live devices only
    private const int STGM_READ = 0;

    // The string a property store hands back is allocated by the store and freed by us. Without this the
    // device name leaked on every listing — and the tray lists the devices on every switch that carries
    // an audio setting, for weeks on end.
    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PROPVARIANT pvar);

    // PKEY_Device_FriendlyName — "Speakers (Realtek)", what is visible in the system.
    private static PROPERTYKEY FriendlyName() {
        PROPERTYKEY k = new PROPERTYKEY();
        k.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0");
        k.pid = 14;
        return k;
    }

    public static List<AudioDev> ListRenderDevices() {
        List<AudioDev> result = new List<AudioDev>();
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());

        string defaultId = "";
        IMMDevice def;
        if (en.GetDefaultAudioEndpoint(RENDER, 0, out def) == 0 && def != null) {
            def.GetId(out defaultId);
        }

        IMMDeviceCollection col;
        if (en.EnumAudioEndpoints(RENDER, DEVICE_STATE_ACTIVE, out col) != 0) return result;

        int count = 0;
        if (col.GetCount(out count) != 0) return result;

        for (int i = 0; i < count; i++) {
            IMMDevice dev;
            if (col.Item(i, out dev) != 0 || dev == null) continue;

            string id;
            if (dev.GetId(out id) != 0) continue;

            string name = "";
            IPropertyStore store;
            if (dev.OpenPropertyStore(STGM_READ, out store) == 0 && store != null) {
                PROPERTYKEY key = FriendlyName();
                PROPVARIANT v;
                if (store.GetValue(ref key, out v) == 0) {
                    // PtrToStringUni has already copied it into managed memory, so the native string is
                    // ours to release — and it has to be released whether or not there was one.
                    if (v.pointerValue != IntPtr.Zero) { name = Marshal.PtrToStringUni(v.pointerValue); }
                    PropVariantClear(ref v);
                }
            }

            AudioDev d = new AudioDev();
            d.Id = id;
            d.Name = name == null ? "" : name;
            d.IsDefault = (id == defaultId);
            result.Add(d);
        }
        return result;
    }

    // role: 0 eConsole, 1 eMultimedia, 2 eCommunications
    public static int SetDefault(string deviceId, int role) {
        IPolicyConfig cfg = (IPolicyConfig)(new PolicyConfigComObject());
        return cfg.SetDefaultEndpoint(deviceId, role);
    }
}

// Window positions: enumeration and restoring. The walk is done here rather than in PowerShell for two
// reasons: EnumWindows requires a delegate (which is fragile and slow from PowerShell), and over dozens of
// windows every P/Invoke from a script costs more than the call itself.
//
// GetWindowPlacement rather than GetWindowRect: it carries both the normal-state frame and the
// "minimised/maximised" flag. A maximised window through GetWindowRect would hand back full-screen
// coordinates, and restoring would turn it into an ordinary window of that size — whereas what is wanted
// is for it to stay maximised.
//
// No window title and no path to the executable. They were collected here and written into
// window-state.json, and NOTHING ever read them back: a title holds the document you have open, the page
// you are on, the subject of the letter you are writing, and the repository promises in three places that
// titles are never read. A promise is kept where the reading would happen, not where the writing does —
// what is never gathered cannot be written down by the next person to touch the snapshot. It is also the
// cheaper walk: the path cost an OpenProcess per window on the switch path.
public class WinInfo {
    public IntPtr Hwnd;
    public int Pid;
    public int ShowCmd;
    public int NL, NT, NR, NB;      // rcNormalPosition
    public int MinX, MinY;          // ptMinPosition
    public int MaxX, MaxY;          // ptMaxPosition
}

public class NativeWindows {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct WRECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT {
        public int length;
        public int flags;
        public int showCmd;
        public POINT ptMinPosition;
        public POINT ptMaxPosition;
        public WRECT rcNormalPosition;
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    // The LENGTH of the title only, never the title: a window with no caption at all belongs to the
    // system, not to a person, and is left out of the snapshot.
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLengthW(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] private static extern bool SetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT p);

    // A window that belongs to the system rather than to the user: panels, popups, invisible handler
    // windows. Where they sit on the desk is of no interest to anybody.
    private const int GWL_EXSTYLE = -20;
    private const int GWL_STYLE = -16;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_CHILD = 0x40000000;

    // DWM "hides" Store apps' windows without closing them: they stay visible by IsWindowVisible, but they
    // are not on the desk. Laying them back out is pointless, and they would land in the snapshot by the
    // dozen.
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out int value, int size);
    private const int DWMWA_CLOAKED = 14;

    private static bool IsCloaked(IntPtr hWnd) {
        int cloaked = 0;
        try { if (DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, out cloaked, sizeof(int)) == 0) return cloaked != 0; }
        catch { }   // the attribute is absent on older builds — we take the window to be visible
        return false;
    }

    public static List<WinInfo> Enumerate() {
        List<WinInfo> list = new List<WinInfo>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lp) {
            if (!IsWindowVisible(hWnd)) return true;
            if ((GetWindowLong(hWnd, GWL_STYLE) & WS_CHILD) != 0) return true;
            if ((GetWindowLong(hWnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) return true;
            if (GetWindowTextLengthW(hWnd) == 0) return true;
            if (IsCloaked(hWnd)) return true;

            WINDOWPLACEMENT p = new WINDOWPLACEMENT();
            p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
            if (!GetWindowPlacement(hWnd, ref p)) return true;

            uint pid = 0;
            GetWindowThreadProcessId(hWnd, out pid);

            WinInfo w = new WinInfo();
            w.Hwnd = hWnd;
            w.Pid = (int)pid;
            w.ShowCmd = p.showCmd;
            w.NL = p.rcNormalPosition.Left;   w.NT = p.rcNormalPosition.Top;
            w.NR = p.rcNormalPosition.Right;  w.NB = p.rcNormalPosition.Bottom;
            w.MinX = p.ptMinPosition.X;       w.MinY = p.ptMinPosition.Y;
            w.MaxX = p.ptMaxPosition.X;       w.MaxY = p.ptMaxPosition.Y;
            list.Add(w);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static bool ApplyPlacement(IntPtr hWnd, int showCmd,
                                     int nl, int nt, int nr, int nb,
                                     int minX, int minY, int maxX, int maxY) {
        if (!IsWindow(hWnd)) return false;
        WINDOWPLACEMENT p = new WINDOWPLACEMENT();
        p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        p.flags = 0;
        p.showCmd = showCmd;
        p.ptMinPosition.X = minX; p.ptMinPosition.Y = minY;
        p.ptMaxPosition.X = maxX; p.ptMaxPosition.Y = maxY;
        p.rcNormalPosition.Left = nl; p.rcNormalPosition.Top = nt;
        p.rcNormalPosition.Right = nr; p.rcNormalPosition.Bottom = nb;
        return SetWindowPlacement(hWnd, ref p);
    }

    public static int PidOfWindow(IntPtr hWnd) {
        uint pid = 0;
        GetWindowThreadProcessId(hWnd, out pid);
        return (int)pid;
    }
}

// The process's DPI awareness. Needed for two reasons, and the second matters more:
//
// 1. Cosmetics: at 150% scale the Settings window would otherwise be stretched by the system out
//    of 100% and look like mush.
// 2. Coordinates. The window-position snapshot (WindowLayout.ps1) reads and restores rectangles in
//    desktop pixels. A process that is not DPI-aware receives them virtualised — the system
//    recalculates them for a notional 96 dpi — and on monitors of different scale the snapshot and
//    the restore would be speaking different languages. One coordinate system for the whole
//    process settles the question.
//
// PER_MONITOR_AWARE_V2 has existed since Windows 10 1703. On older builds
// SetProcessDpiAwarenessContext is absent or hands back an error — and then we fall back to
// SetProcessDPIAware (system-aware), which has been there since Vista.
public class NativeDpi {
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    private static extern IntPtr GetThreadDpiAwarenessContext();

    [DllImport("user32.dll")]
    private static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(POINT point, uint flags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int dpiType,
                                               out uint dpiX, out uint dpiY);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr window, IntPtr dc);

    [DllImport("gdi32.dll")]
    private static extern int GetDeviceCaps(IntPtr dc, int index);

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4
    public static readonly IntPtr PER_MONITOR_AWARE_V2 = new IntPtr(-4);
    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE = (HANDLE)-3
    public static readonly IntPtr PER_MONITOR_AWARE = new IntPtr(-3);

    // Whether the process really ended up per-monitor aware — asked of the system rather than inferred
    // from which of our own calls succeeded. Three ways to be system-aware without any of them failing
    // loudly: an old build with no SetProcessDpiAwarenessContext, a manifest that got there first, or the
    // "Override high DPI scaling behavior: System" compatibility flag on powershell.exe. GetDpiForMonitor
    // answers with the monitor's real DPI in every one of those cases, so without this the caller would
    // scale a second time on top of what Windows already did.
    public static bool IsPerMonitorAware() {
        try {
            IntPtr current = GetThreadDpiAwarenessContext();
            return AreDpiAwarenessContextsEqual(current, PER_MONITOR_AWARE_V2) ||
                   AreDpiAwarenessContextsEqual(current, PER_MONITOR_AWARE);
        }
        catch (DllNotFoundException) { return false; }
        catch (EntryPointNotFoundException) { return false; }
    }

    private const uint MONITOR_DEFAULTTONEAREST = 2;
    private const int MDT_EFFECTIVE_DPI = 0;
    private const int LOGPIXELSY = 90;

    public static int GetDpiAtCursor() {
        // The menu does not yet have a reliably placed HWND, so GetDpiForWindow is no good here.
        // GetDpiForMonitor is formally not DPI-aware, but for a process with per-monitor awareness it
        // returns the actual DPI of the monitor chosen; it is the process, not whatever window happens
        // to be under the cursor, that sets this contract.
        try {
            POINT point;
            if (GetCursorPos(out point)) {
                IntPtr monitor = MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
                uint dpiX, dpiY;
                if (monitor != IntPtr.Zero &&
                    GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, out dpiX, out dpiY) == 0 &&
                    dpiY > 0) return (int)dpiY;
            }
        }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }

        // On a Windows without shcore the process falls back to system-aware. There the desktop DC
        // knows the system DPI; under PMv2 it will give 96, but we only reach this point after the
        // precise query has refused, and 96 keeps the previous look.
        IntPtr dc = GetDC(IntPtr.Zero);
        if (dc != IntPtr.Zero) {
            try {
                int dpi = GetDeviceCaps(dc, LOGPIXELSY);
                if (dpi > 0) return dpi;
            }
            finally { ReleaseDC(IntPtr.Zero, dc); }
        }
        return 96;
    }
}

// The global-shortcut receiver. It used to live in Displays.ps1 and was compiled by a fourth separate
// call; it moved here so that there is only one compilation. The tray needs it and the CLI does not,
// but an unused class in the assembly costs nothing: the reference to System.Windows.Forms is resolved
// lazily, on the first use of the type.
//
// RegisterHotKey requires an HWND and only works where a message loop is running.
public class HotkeyWindow : NativeWindow, IDisposable {
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int WM_HOTKEY = 0x0312;
    private int _nextId = 1;
    private readonly List<int> _ids = new List<int>();

    public event EventHandler<int> HotkeyPressed;

    public HotkeyWindow() { CreateHandle(new CreateParams()); }

    // MOD_ALT 1 | MOD_CONTROL 2 | MOD_SHIFT 4 | MOD_WIN 8 | MOD_NOREPEAT 0x4000
    public int Register(uint modifiers, uint vk) {
        int id = _nextId++;
        if (!RegisterHotKey(Handle, id, modifiers, vk)) return -1;
        _ids.Add(id);
        return id;
    }

    public void UnregisterAll() {
        foreach (int id in _ids) { UnregisterHotKey(Handle, id); }
        _ids.Clear();
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            EventHandler<int> h = HotkeyPressed;
            if (h != null) h(this, (int)m.WParam);
        }
        base.WndProc(ref m);
    }

    public void Dispose() { UnregisterAll(); DestroyHandle(); }
}

// Dressing windows through DWM: a dark title bar and rounded corners. They appeared in Windows
// gradually (the dark title bar is attribute 19, and 20 since 20H1; the corners exist only in
// Windows 11), which is why both methods are Try*: on an older build the call quietly hands back an
// error and the window stays as it was — with a light title bar and square corners. There is nothing
// worth breaking over cosmetics.
public static class NativeTheme {
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;   // builds 1809-1909
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE     = 20;   // since 20H1
    private const int DWMWA_WINDOW_CORNER_PREFERENCE    = 33;   // since Windows 11
    private const int DWMWCP_ROUND      = 2;
    private const int DWMWCP_ROUNDSMALL = 3;

    public static void TryDarkTitleBar(IntPtr hwnd, bool dark) {
        int v = dark ? 1 : 0;
        if (DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref v, 4) != 0)
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, ref v, 4);
    }

    public static void TryRoundCorners(IntPtr hwnd, bool small) {
        int v = small ? DWMWCP_ROUNDSMALL : DWMWCP_ROUND;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref v, 4);
    }
}

// Drawing the tray menu in the spirit of Windows 11: a flat background matching the system theme, a
// rounded highlight on the row, a check mark in the accent colour. The stock WinForms renderers are
// stuck in the past — System draws Windows 7, Professional draws Office 2007 with gradients — and the
// tray icon itself cannot live without WinForms, so a modern-looking menu is only reachable through a
// ToolStripRenderer of our own.
//
// The colours arrive from PowerShell ready-made (the theme and the accent are read there): the
// renderer is created on every menu open, so a change of Windows theme is picked up without restarting
// the tray.
//
// The rows' semantic roles are passed through Tag: "header" is a section heading, "info" is an
// information line (the DISPLAYS section). Both are disabled so as not to catch clicks, but a heading
// has to be dimmed while information has to read as ordinary text: with the system renderer all of
// this was equally grey.
public class ModernMenuRenderer : ToolStripRenderer {
    private readonly Color _back, _text, _dim, _hover, _line, _accent;
    private readonly float _scale;

    public ModernMenuRenderer(bool dark, Color accent) : this(dark, accent, 1f) { }

    public ModernMenuRenderer(bool dark, Color accent, float scale) {
        _accent = accent;
        _scale = scale < 1f ? 1f : scale;
        if (dark) {
            _back  = Color.FromArgb(0x2C, 0x2C, 0x2C);
            _text  = Color.FromArgb(0xF2, 0xF2, 0xF2);
            // A dimmed tone rather than "nearly the background": the monitor's mode and the section
            // headings are written in it, and at 0x8F they were hard to read (contrast to the background ~4:1).
            _dim   = Color.FromArgb(0xAD, 0xAD, 0xAD);
            _hover = Color.FromArgb(0x3D, 0x3D, 0x3D);
            _line  = Color.FromArgb(0x45, 0x45, 0x45);
        } else {
            _back  = Color.FromArgb(0xF9, 0xF9, 0xF9);
            _text  = Color.FromArgb(0x1B, 0x1B, 0x1B);
            _dim   = Color.FromArgb(0x66, 0x66, 0x66);
            _hover = Color.FromArgb(0xEA, 0xEA, 0xEA);
            _line  = Color.FromArgb(0xE0, 0xE0, 0xE0);
        }
    }

    private int S(int value) {
        return (int)Math.Round(value * _scale, MidpointRounding.AwayFromZero);
    }

    private static GraphicsPath Rounded(Rectangle r, int radius) {
        var p = new GraphicsPath();
        int d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
        using (var b = new SolidBrush(_back)) e.Graphics.FillRectangle(b, e.AffectedBounds);
    }

    // Deliberately empty: the strip under the icons must not differ from the background.
    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }

    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) {
        // A thin border so that the menu does not blend into whatever is beneath it. Its corners are
        // square — on Windows 11 DWM will cut them along with the corners of the window itself. One
        // physical pixel is left deliberately: system menus keep a hairline at any DPI so that the
        // outline never becomes heavier than the content.
        var r = new Rectangle(0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
        using (var p = new Pen(_line)) e.Graphics.DrawRectangle(p, r);
    }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        var g = e.Graphics;
        var r = new Rectangle(S(3), S(1), e.Item.Width - S(6), e.Item.Height - S(2));
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Rounded(r, S(4)))
        using (var b = new SolidBrush(_hover)) g.FillPath(b, path);
        g.SmoothingMode = old;
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        if (e.Vertical) { base.OnRenderSeparator(e); return; }
        int y = e.Item.Height / 2;
        // Like the border, the line itself stays a hairline; only its inset grows.
        using (var p = new Pen(_line)) e.Graphics.DrawLine(p, S(10), y, e.Item.Width - S(10), y);
    }

    // We SET THE COLOUR OURSELVES, because the base ToolStripRenderer.OnRenderItemText does
    // `textColor = item.Enabled ? textColor : SystemColors.GrayText` — that is, for any disabled row it
    // throws our colour away and takes the system's dark grey. And the monitor rows are disabled
    // deliberately (they cannot be clicked), and on a dark background the system grey was hard to read:
    // the DISPLAYS section looked like a faded placeholder, even though it is the most useful
    // thing in the menu.
    //
    // At the same time a monitor's row is drawn in two tones: the name at full brightness, the mode and
    // the notes dimmed. That way both what is connected and what it is running at are visible, without
    // the second competing with the first for attention.
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        bool header = "header".Equals(e.Item.Tag as string);
        bool info   = "info".Equals(e.Item.Tag as string);

        if (e.Item.Enabled) {
            // The key combination is quieter than the mode's name: it is a hint, not the item itself.
            // ToolStripMenuItem draws it in a separate call with the same colour as the text, and the menu
            // came out equally loud across its whole width.
            var mi = e.Item as ToolStripMenuItem;
            bool isShortcut = mi != null && !string.IsNullOrEmpty(mi.ShortcutKeyDisplayString)
                              && e.Text == mi.ShortcutKeyDisplayString;
            e.TextColor = isShortcut ? _dim : _text;
            base.OnRenderItemText(e);
            return;
        }

        // The horizontal alignment is removed: the parts are drawn one after another, from the left.
        // NoPadding is there so that the measured width of the name matches the drawn one, otherwise the
        // second tone would slide a pixel or two away from the first.
        TextFormatFlags flags = (e.TextFormat | TextFormatFlags.NoPadding)
                                & ~(TextFormatFlags.HorizontalCenter | TextFormatFlags.Right);
        Rectangle r = e.TextRectangle;

        int split = info ? e.Text.IndexOf("    ") : -1;
        if (split <= 0) {
            // A section heading, an unavailable mode or a line with no separator — all in one tone. The
            // heading is dimmed deliberately, it is a service line.
            TextRenderer.DrawText(e.Graphics, e.Text, e.TextFont, r,
                                  (header || !info) ? _dim : _text, flags);
            return;
        }

        string name = e.Text.Substring(0, split);
        string rest = e.Text.Substring(split);
        Size nameSize = TextRenderer.MeasureText(e.Graphics, name, e.TextFont,
                                                new Size(int.MaxValue, r.Height), flags);
        TextRenderer.DrawText(e.Graphics, name, e.TextFont, r, _text, flags);
        Rectangle tail = new Rectangle(r.X + nameSize.Width, r.Y,
                                       Math.Max(0, r.Width - nameSize.Width), r.Height);
        TextRenderer.DrawText(e.Graphics, rest, e.TextFont, tail, _dim, flags);
    }

    // We draw the status dot ourselves, in full colour. The base renderer runs a disabled item's image
    // through ControlPaint.DrawImageDisabled, and the monitor rows are disabled deliberately (they cannot
    // be clicked) — so the green "at its maximum" dot, the amber "rate is lower" one and the grey "off"
    // one all turned into three identical grey smudges. Verified with a pixel dump of an off-screen
    // render: #828282, #7D7D7D, #8B8B8B instead of green, amber and grey.
    protected override void OnRenderItemImage(ToolStripItemImageRenderEventArgs e) {
        if (e.Image == null) { base.OnRenderItemImage(e); return; }
        e.Graphics.DrawImage(e.Image, e.ImageRectangle);
    }

    // The current mode's check mark is drawn with a pen rather than with a font glyph: Segoe MDL2 is not
    // everywhere, and when a font is missing GDI+ silently substitutes another one, and instead of a check
    // mark a little square would come out.
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
        var g = e.Graphics;
        var r = e.ImageRectangle;
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var p = new Pen(_accent, 1.8f * _scale)) {
            p.StartCap = LineCap.Round;
            p.EndCap = LineCap.Round;
            p.LineJoin = LineJoin.Round;
            g.DrawLines(p, new PointF[] {
                new PointF(r.Left + r.Width * 0.24f, r.Top + r.Height * 0.55f),
                new PointF(r.Left + r.Width * 0.44f, r.Top + r.Height * 0.74f),
                new PointF(r.Left + r.Width * 0.78f, r.Top + r.Height * 0.30f) });
        }
        g.SmoothingMode = old;
    }
}
'@

# Compiled once, and from then on out of the cache next to the scripts.
#
# The assembly's name contains the first 8 hex of the source's SHA256: edit the C# and the hash changes
# and it is rebuilt, while the old files are deleted. Forgetting to rebuild is impossible by
# construction.
#
# Any cache failure (a read-only folder, a file in use, a race between two processes) must not bring the
# tool down: in that case we simply compile into memory and write the reason to the log.
# "The file is blocked by the code integrity policy" is what Windows answers an attempt to load an
# unsigned assembly with when Smart App Control is on (or a WDAC policy is in force). We check the
# NUMBER and not the text: the message arrives in the system's language, and on a Russian Windows a
# check by words would silently stop working.
$script:BlockedByPolicyHResult = 0x800711C7

function Test-BlockedByPolicy {
    param($ErrorRecord)

    $e = $ErrorRecord.Exception
    while ($e) {
        if ($e.HResult -eq $script:BlockedByPolicyHResult) { return $true }
        $e = $e.InnerException
    }
    return $false
}

# Remove the assemblies that will not be of use any more: from earlier versions of the source they only
# take up space and cause confusion.
#
# First a cheap check by mask: in a clean folder that is one Test-Path rather than a directory walk on
# every start. Ones in use are skipped silently — the tray lives for weeks and keeps its own assembly
# open, so right after the C# is edited the old file cannot be deleted; it will go on the next run, once
# the tray has been restarted.
function Remove-StaleNativeAssemblies {
    param([string]$Keep = '')

    if (-not (Test-Path (Join-Path $script:ToolRoot 'native-*.dll'))) { return }
    foreach ($old in @(Get-ChildItem -Path $script:ToolRoot -Filter 'native-*.dll' -ErrorAction SilentlyContinue)) {
        if ($Keep -and $old.Name -eq $Keep) { continue }
        Remove-Item $old.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-NativeTypes {
    # Already in this session — we leave. The check on NativeDisplay covers all four classes: they are
    # compiled together and appear together.
    if ('NativeDisplay' -as [type]) { return }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # System.Drawing — for ModernMenuRenderer's sake: the colours, pens and brushes come from there.
    $refs = @('System.Windows.Forms', 'System.Drawing')
    $how = 'compiled'
    $dll = ''

    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:NativeSource)) }
        finally { $sha.Dispose() }
        $hash = -join ($digest[0..3] | ForEach-Object { $_.ToString('x2') })

        $name = "native-$hash.dll"
        $dll = Join-Path $script:ToolRoot $name

        Remove-StaleNativeAssemblies -Keep $name

        if (Test-Path $dll) {
            Add-Type -Path $dll
            $how = 'cache'
        }
        else {
            # We build into a temporary file with the process number in its name and only rename it
            # afterwards: the tray and the CLI can start at the same time, and two processes must not write
            # into one file.
            $tmp = Join-Path $script:ToolRoot ("native-$hash.$PID.tmp")
            Add-Type -TypeDefinition $script:NativeSource -ReferencedAssemblies $refs -OutputAssembly $tmp
            try { Move-Item -LiteralPath $tmp -Destination $dll -Force }
            catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

            # -OutputAssembly in PS 5.1 does NOT load the types into the session, so we load them from
            # the file. The check is in case the behaviour is different.
            if (-not ('NativeDisplay' -as [type])) { Add-Type -Path $dll }
        }
    }
    catch {
        # A refusal from the code integrity policy is a separate case, and it is cured by deleting the
        # file. Verified on a live machine: Smart App Control refused an unsigned assembly and let the
        # very same assembly through once it had been rebuilt — the decision is made by the file's
        # reputation, not by its content alone. Which means keeping a rejected file is not allowed: it
        # guarantees the same refusal on the next start, and every refusal is two more entries in the
        # CodeIntegrity log. Without it the next start will rebuild the assembly and get a fresh chance;
        # nothing breaks, and in the worst case it compiles into memory.
        if (Test-BlockedByPolicy $_) {
            Write-DisplayLog 'core: the code integrity policy refused our cached assembly - dropping it, the next start will rebuild'
            if ($dll) { Remove-Item -LiteralPath $dll -Force -ErrorAction SilentlyContinue }
        }
        else {
            # Everything else — a read-only folder, a file in use, a race between two processes — is
            # written down as it is.
            Write-DisplayLog "core: dll cache failed - $($_.Exception.Message)"
        }

        if (-not ('NativeDisplay' -as [type])) {
            Add-Type -TypeDefinition $script:NativeSource -ReferencedAssemblies $refs
        }
        $how = 'compiled'
    }

    Write-DisplayLog ("core: native types ready in {0} ms ({1})" -f [int]$sw.ElapsedMilliseconds, $how)
}

Initialize-NativeTypes

# A process can only be declared DPI-aware BEFORE the first window is created and before the first
# metrics query — after that the system ignores the call. Which is why this is done here, right after
# the types, and not in Displays.ps1: DisplayCore is dot-sourced on the first line in both the tray and
# the CLI.
#
# Called once per process: a repeat call would return an error, and `dpi:` lines would rain into the log
# on every request.
$script:DpiSet = $false

function Initialize-DpiAwareness {
    if ($script:DpiSet) { return }
    $script:DpiSet = $true

    try {
        if ([NativeDpi]::SetProcessDpiAwarenessContext([NativeDpi]::PER_MONITOR_AWARE_V2)) { return }
    }
    catch { }   # on older builds the function itself is absent — that is not an error

    # The fallback: system-aware. Worse than per-monitor (when a window moves between monitors of
    # different scale the system will draw it), but at least the coordinates are not virtualised.
    try {
        if ([NativeDpi]::SetProcessDPIAware()) {
            Write-DisplayLog 'core: per-monitor DPI is unavailable, fell back to system-aware'
            return
        }
    }
    catch { }   # that did not work either — we stay with the system's scaling

    # Already aware (set in a manifest or through an environment variable, for instance) — both calls
    # will return false, and that is normal. We keep quiet rather than alarm the log.
}

Initialize-DpiAwareness

function Get-UiScale {
    param([int]$Dpi = 0)

    # Zero means a live query for the monitor under the cursor. An explicit value is a deterministic seam
    # for the tests: they must not depend on the real desk, so the awareness check below is skipped there
    # — the caller asked for that DPI and gets the scale for it.
    if ($Dpi -le 0) {
        # A system-aware process is already being scaled by Windows, and GetDpiForMonitor reports the
        # monitor's true DPI regardless of awareness. Multiplying by it again would draw the menu half as
        # big again on a 150% screen — the very fault the scaling was added to cure, inverted.
        try { if (-not [NativeDpi]::IsPerMonitorAware()) { return [double]1.0 } }
        catch { return [double]1.0 }

        try { $Dpi = [NativeDpi]::GetDpiAtCursor() }
        catch { $Dpi = 96 }
    }
    return [Math]::Max([double]1.0, ([double]$Dpi / 96.0))
}

# A design figure in device pixels at the scale in hand. Seven copies of the same expression stood around
# the tray menu, and they are all one decision, made once here: AwayFromZero rather than .NET's default
# banker's rounding. A single pixel of padding at 125% is 1.25 and rounds either way under the default;
# with a column of such figures some go up and some go down, and the gaps above and below an item stop
# matching each other. Away from zero also keeps a 1 px hairline from rounding to 0 and disappearing.
function Get-ScaledPx {
    param([Parameter(Mandatory)][double]$Value, [double]$Scale = 1.0)

    return [int][Math]::Round($Value * $Scale, [System.MidpointRounding]::AwayFromZero)
}

function New-DisplayDevice {
    $d = New-Object NativeDisplay+DISPLAY_DEVICE
    $d.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($d)
    return $d
}

# --- reading the state through CCD ------------------------------------------

# The manufacturer code out of EDID: three letters packed into 5 bits each. Windows hands the word back
# with the bytes in reverse order, so it has to be turned round. If what comes out after turning it is
# not letters, we take it as it is rather than invent something.
function ConvertTo-VendorCode {
    param([int]$Raw)

    foreach ($v in @(((($Raw -band 0xFF) -shl 8) -bor (($Raw -shr 8) -band 0xFF)), $Raw)) {
        $s = ''
        foreach ($shift in 10, 5, 0) { $s += [char]((($v -shr $shift) -band 0x1F) + 64) }
        if ($s -match '^[A-Z]{3}$') { return $s }
    }
    return ''
}

# --- how big the panel actually is ------------------------------------------
# The resolution says nothing about the size: a 4K panel can be a 24-inch one standing next to
# a 27-inch 1440p. The picture of the desk has to be drawn to the size a person sees, and the
# only place that number is written down is the monitor's own EDID.

# Bytes 21 and 22 of the base block: the panel in whole centimetres. A pure function, so the
# awkward cases can be pinned down by tests rather than by a monitor being plugged in.
function ConvertFrom-EdidSize {
    param([byte[]]$Edid)

    # Zeros are not a small monitor: they are "not said". Projectors and network displays write
    # nothing there, and a television writes its aspect ratio into these two bytes instead.
    if ($null -eq $Edid -or $Edid.Length -lt 23) { return $null }
    $w = [int]$Edid[21]; $h = [int]$Edid[22]
    if ($w -le 0 -or $h -le 0) { return $null }

    return [pscustomobject]@{
        WidthCm  = $w
        HeightCm = $h
        Inches   = [math]::Round([math]::Sqrt(($w * $w) + ($h * $h)) / 2.54, 1)
    }
}

# The same for a live monitor. Windows keeps the EDID of every monitor ever plugged in under
# HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY, and the way in is the device path Get-DisplayState
# already knows a monitor by:
#
#   \\?\DISPLAY#GSM5CBC#5&2b9c6f03&0&UID4357#{e6f07b5f-...}
#              hardware id ^      ^ instance
#
# Deliberately NOT part of the state record: three registry reads cost 3 ms, and Get-DisplayState
# is on the switch path, where every millisecond is measured and printed in the log. The desk
# picture asks for this once per window instead, and the answer is kept: a panel does not change
# size while the app is running.
#
# The keeping is also the way an invented desk gets sizes: render-preview.ps1 -Fake writes its
# monitors in here by hand, because they are plugged into nothing and the registry has never
# heard of them.
$script:MonitorSizeCache = @{}

function Get-MonitorPhysicalSize {
    param([string]$DevicePath)

    if (-not $DevicePath) { return $null }
    if ($script:MonitorSizeCache.ContainsKey($DevicePath)) { return $script:MonitorSizeCache[$DevicePath] }

    $size = $null
    try {
        $parts = ($DevicePath -replace '^\\\\\?\\', '') -split '#'
        if ($parts.Count -ge 3 -and $parts[0] -eq 'DISPLAY') {
            $key = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\{0}\{1}\Device Parameters' -f $parts[1], $parts[2]
            $edid = (Get-ItemProperty -LiteralPath $key -Name EDID -ErrorAction Stop).EDID
            $size = ConvertFrom-EdidSize -Edid $edid
        }
    }
    catch { }   # no such key, no EDID under it, or no permission: the size is simply not known

    $script:MonitorSizeCache[$DevicePath] = $size
    return $size
}

# The panel's diagonal in inches for a monitor of the state, or 0 when nobody knows — a monitor
# that is not plugged in right now included: the card keeps its place in the row either way.
function Get-DisplayInches {
    param($Display)

    if (-not $Display) { return 0.0 }
    $size = Get-MonitorPhysicalSize -DevicePath ([string]$Display.Id)
    if ($size) { return [double]$size.Inches }
    return 0.0
}

# Every target the system knows about: the ones that are on and the merely connected ones alike.
function Get-CcdTargets {
    $M = [System.Runtime.InteropServices.Marshal]

    $np = 0; $nm = 0
    if ([NativeCcd]::GetDisplayConfigBufferSizes([NativeCcd]::QDC_ALL_PATHS, [ref]$np, [ref]$nm) -ne 0) { return @() }
    $paths = New-Object 'NativeCcd+PATH_INFO[]' $np
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $nm
    if ([NativeCcd]::QueryDisplayConfig([NativeCcd]::QDC_ALL_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) { return @() }

    # QDC_ALL_PATHS hands back every "source x target" combination — with three monitors that is close to
    # six dozen paths. First we reduce them to one path per target (an active one is preferred: it has the
    # output name filled in), and only then do we ask for the names. Otherwise three calls went out for
    # each of the 58 paths, and reading cost 200 ms instead of 10.
    $pick = [ordered]@{}
    for ($i = 0; $i -lt $np; $i++) {
        $ti = $paths[$i].targetInfo
        $tk = '{0}:{1}:{2}' -f $ti.adapterId.Low, $ti.adapterId.High, $ti.id
        if (-not $pick.Contains($tk)) { $pick[$tk] = $i }
        elseif (($paths[$i].flags -band [NativeCcd]::PATH_ACTIVE) -ne 0) { $pick[$tk] = $i }
    }

    $byPath = [ordered]@{}
    foreach ($i in @($pick.Values)) {
        $p = $paths[$i]
        $active = (($p.flags -band [NativeCcd]::PATH_ACTIVE) -ne 0)

        $t = New-Object NativeCcd+TARGET_DEVICE_NAME
        $h = New-Object NativeCcd+HEADER
        $h.type = [NativeCcd]::GET_TARGET_NAME
        $h.size = $M::SizeOf($t)
        $h.adapterId = $p.targetInfo.adapterId
        $h.id = $p.targetInfo.id
        $t.header = $h
        if ([NativeCcd]::DisplayConfigGetDeviceInfo([ref]$t) -ne 0) { continue }
        if ([string]::IsNullOrWhiteSpace($t.monitorDevicePath)) { continue }

        $key = $t.monitorDevicePath
        if ($byPath.Contains($key) -and -not $active) { continue }

        $output = ''
        if ($active) {
            $s = New-Object NativeCcd+SOURCE_DEVICE_NAME
            $hs = New-Object NativeCcd+HEADER
            $hs.type = [NativeCcd]::GET_SOURCE_NAME
            $hs.size = $M::SizeOf($s)
            $hs.adapterId = $p.sourceInfo.adapterId
            $hs.id = $p.sourceInfo.id
            $s.header = $hs
            # The output name is only reliable for an active target: for the ones that are off the system
            # hands back one and the same \\.\DISPLAYx for all of them.
            if ([NativeCcd]::DisplayConfigGetDeviceInfo([ref]$s) -eq 0) { $output = $s.viewGdiDeviceName }
        }

        $native = $null
        $pm = New-Object NativeCcd+TARGET_PREFERRED_MODE
        $hp = New-Object NativeCcd+HEADER
        $hp.type = [NativeCcd]::GET_TARGET_PREFERRED_MODE
        $hp.size = $M::SizeOf($pm)
        $hp.adapterId = $p.targetInfo.adapterId
        $hp.id = $p.targetInfo.id
        $pm.header = $hp
        if ([NativeCcd]::DisplayConfigGetDeviceInfo([ref]$pm) -eq 0 -and $pm.width -ge 640) {
            $native = [pscustomobject]@{ Width = [int]$pm.width; Height = [int]$pm.height }
        }

        $shortId = (ConvertTo-VendorCode ([int]$t.edidManufactureId)) + ('{0:X4}' -f $t.edidProductCodeId)

        $x = 0; $y = 0; $rotation = 0; $rateNum = 0; $rateDen = 0
        if ($active) {
            $mi = [uint32]$p.sourceInfo.modeInfoIdx
            if ($mi -ne [NativeCcd]::MODE_IDX_INVALID -and $mi -lt $nm -and
                $modes[[int]$mi].infoType -eq [NativeCcd]::MODE_INFO_TYPE_SOURCE -and
                $modes[[int]$mi].id -eq $p.sourceInfo.id -and
                $modes[[int]$mi].adapterId.Low -eq $p.sourceInfo.adapterId.Low -and
                $modes[[int]$mi].adapterId.High -eq $p.sourceInfo.adapterId.High) {
                $x = [int]$modes[[int]$mi].srcPosX; $y = [int]$modes[[int]$mi].srcPosY
                $rotation = [int]$p.targetInfo.rotation
                $rateNum = [int]$p.targetInfo.refreshRate.Numerator
                $rateDen = [int]$p.targetInfo.refreshRate.Denominator
            }
            # An active path without its matching source-mode record is a transient, incomplete read. The
            # zero rotation/rate values make New-DesktopSnapshot reject it instead of accepting (0,0) as a
            # real position and later flattening the desk around that invented origin.
        }

        $byPath[$key] = [pscustomobject]@{
            DevicePath = $t.monitorDevicePath
            Label      = $t.monitorFriendlyDeviceName
            ShortId    = $shortId
            Output     = $output
            Active     = $active
            Available  = ($p.targetInfo.targetAvailable -ne 0)
            Native     = $native
            PathIndex  = $i
            X           = $x
            Y           = $y
            Rotation    = $rotation
            RateNum     = $rateNum
            RateDen     = $rateDen
            # Who to address a per-target question to (HDR, say): the adapter's LUID and the target's
            # id, as one struct and one number - a LUID's fields cannot be set one at a time from
            # PowerShell, which hands back a copy of a nested struct.
            Adapter    = $p.targetInfo.adapterId
            TargetId   = [uint32]$p.targetInfo.id
        }
    }

    return @($byPath.Values)
}

# The device path for one CCD path. Separately, because it is needed both when reading and when switching
# on.
function Get-CcdPathDevice {
    param($Path)

    $t = New-Object NativeCcd+TARGET_DEVICE_NAME
    $h = New-Object NativeCcd+HEADER
    $h.type = [NativeCcd]::GET_TARGET_NAME
    $h.size = [System.Runtime.InteropServices.Marshal]::SizeOf($t)
    $h.adapterId = $Path.targetInfo.adapterId
    $h.id = $Path.targetInfo.id
    $t.header = $h
    if ([NativeCcd]::DisplayConfigGetDeviceInfo([ref]$t) -ne 0) { return '' }
    return $t.monitorDevicePath
}

# Pick one CCD path for each of the monitors that were asked for.
#
# The shared part of the two ways of rebuilding the desk — Set-CcdFullConfig (the ordinary path) and
# Set-CcdTopology (the fallback). Lifted out so that the path-selection rule exists in a single copy: let
# those two copies diverge, and the fallback would change the desk differently from the main path, and
# that would only become noticeable on the day the main path refuses.
#
# Returns $null if CCD does not answer or not one path was found, and otherwise Paths (the whole array
# from QueryDisplayConfig) and Chosen (the indices of the chosen paths).
function Get-CcdPathChoice {
    param([Parameter(Mandatory)][string[]]$DevicePaths)

    $want = @{}
    foreach ($p in $DevicePaths) { if ($p) { $want[$p] = $true } }
    # An empty set is a black screen. Such a request simply never happens, but the cost of being wrong
    # here is such that the check is worth one line.
    if ($want.Count -eq 0) { return $null }

    $np = 0; $nm = 0
    if ([NativeCcd]::GetDisplayConfigBufferSizes([NativeCcd]::QDC_ALL_PATHS, [ref]$np, [ref]$nm) -ne 0) { return $null }
    $paths = New-Object 'NativeCcd+PATH_INFO[]' $np
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $nm
    if ([NativeCcd]::QueryDisplayConfig([NativeCcd]::QDC_ALL_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) { return $null }

    # QDC_ALL_PATHS hands back every "source x target" combination. We take one path per monitor with a
    # free source: two monitors on one source is a clone, and what is wanted is an extend. A path that is
    # already active is preferred — fewer rebuilds.
    $chosen = @()
    $usedSources = @{}
    $covered = @{}
    # The DevicePath by the chosen path's index: Set-CcdFullConfig finds the monitor's target mode by it.
    # We remember it here, where the path has already been identified — there is no point asking the system
    # a second time about something known.
    $byIndex = @{}

    foreach ($onlyActive in $true, $false) {
        for ($i = 0; $i -lt $np; $i++) {
            $isActive = (($paths[$i].flags -band [NativeCcd]::PATH_ACTIVE) -ne 0)
            if ($onlyActive -ne $isActive) { continue }
            if ($paths[$i].targetInfo.targetAvailable -eq 0) { continue }
            $dp = Get-CcdPathDevice $paths[$i]
            if (-not $dp -or -not $want.ContainsKey($dp) -or $covered.ContainsKey($dp)) { continue }
            # A source id is local to one adapter. Source 0 on two graphics adapters names two
            # independent sources, so both halves of the LUID are part of the key.
            $sid = [string]::Format([cultureinfo]::InvariantCulture, '{0}:{1}:{2}',
                [uint32]$paths[$i].sourceInfo.adapterId.Low,
                [int32]$paths[$i].sourceInfo.adapterId.High,
                [uint32]$paths[$i].sourceInfo.id)
            if ($usedSources.ContainsKey($sid)) { continue }
            $usedSources[$sid] = $true
            $covered[$dp] = $true
            $byIndex[$i] = $dp
            $chosen += $i
        }
    }

    $missing = @($want.Keys | Where-Object { -not $covered.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        Write-DisplayLog ("ccd: no usable path for {0} display(s)" -f $missing.Count)
        return $null
    }
    if ($chosen.Count -eq 0) { return $null }

    return [pscustomobject]@{ Paths = $paths; Chosen = @($chosen); DeviceByIndex = $byIndex }
}

# Set the whole SET of monitors that are on: the ones listed come on, all the rest go out. In one call
# rather than three steps of "switch on the ones we want, carry the taskbar over, put the spare ones out":
# the system moves the primary role inside the transition itself, and no intermediate state with spare
# screens appears on the desk.
#
# SDC_ALLOW_CHANGES is needed here: we do not set the modes or the positions (the indices are invalid), so
# let the system pick them itself. We will set ours right afterwards — Set-CcdLayout for the positions,
# Set-BestModeFor for the refresh rate.
#
# This is the fallback: the ordinary path is Set-CcdFullConfig, which sets the set, the positions and the
# modes in one transition. People arrive here when that one has refused (see there).
function Set-CcdTopology {
    param([Parameter(Mandatory)][string[]]$DevicePaths)

    $choice = Get-CcdPathChoice -DevicePaths $DevicePaths
    if (-not $choice) { return $false }

    $paths = $choice.Paths
    $chosen = $choice.Chosen

    $out = New-Object 'NativeCcd+PATH_INFO[]' $chosen.Count
    for ($k = 0; $k -lt $chosen.Count; $k++) {
        $p = $paths[$chosen[$k]]
        $p.flags = $p.flags -bor [NativeCcd]::PATH_ACTIVE
        $s = $p.sourceInfo; $s.modeInfoIdx = [NativeCcd]::MODE_IDX_INVALID; $p.sourceInfo = $s
        $t = $p.targetInfo
        $t.modeInfoIdx = [NativeCcd]::MODE_IDX_INVALID
        $rate = New-Object NativeCcd+RATIONAL
        $rate.Numerator = 0; $rate.Denominator = 0
        $t.refreshRate = $rate
        $t.scanLineOrdering = 0
        $p.targetInfo = $t
        $out[$k] = $p
    }

    $base = [NativeCcd]::SDC_USE_SUPPLIED_DISPLAY_CONFIG -bor [NativeCcd]::SDC_ALLOW_CHANGES
    $rc = [NativeCcd]::SetDisplayConfig($out.Count, $out, 0, $null, ($base -bor [NativeCcd]::SDC_VALIDATE))
    if ($rc -ne 0) {
        Write-DisplayLog "ccd: topology validate -> $rc"
        return $false
    }
    $rc = [NativeCcd]::SetDisplayConfig($out.Count, $out, 0, $null,
        ($base -bor [NativeCcd]::SDC_APPLY -bor [NativeCcd]::SDC_SAVE_TO_DATABASE))
    if ($rc -ne 0) {
        Write-DisplayLog "ccd: topology apply -> $rc"
        return $false
    }
    Write-DisplayLog ("ccd: topology set - {0} display(s) on" -f $out.Count)
    return $true
}

# --- the whole desk in one transition ---------------------------------------
# Set EVERYTHING at once: which monitors are lit, where they stand, who is primary, at what resolution and
# at what refresh rate. One SetDisplayConfig instead of three steps.
#
# What for. The road of three rebuilds (the set of screens, then the positions, then the refresh rate)
# costs three freezes of DWM and of input: the cursor stalls and then "shoots" forward, the screens blink
# three times, every window gets WM_DISPLAYCHANGE three times, and all of it costs seconds. CCD can set
# those same three things in one structure — and then the system rebuilds the desk once.
#
# $Targets is objects with DevicePath, Label, Width, Height, Hz (Hz = 0 means "let the system choose").
# The width and height are mandatory: without them the source mode cannot be set, and such a set does not
# reach this point (see Get-SwitchTargets).
#
# Returns $true/$false. A failure is not frightening: the caller falls back to the old ladder of three
# steps, which has not gone anywhere.
function Set-CcdFullConfig {
    param(
        [Parameter(Mandatory)]$Targets,
        [string]$PrimaryPath = '',
        [string[]]$Order = @(),
        [switch]$Exact
    )

    $list = @($Targets)
    if ($list.Count -eq 0) { return $false }
    $targetPaths = @{}
    foreach ($t in $list) {
        $path = [string]$t.DevicePath
        if (-not $path -or $targetPaths.ContainsKey($path)) { return $false }
        $targetPaths[$path] = $true
        if ([int]$t.Width -le 0 -or [int]$t.Height -le 0) { return $false }
        if ($Exact -and ([int]$t.RateNum -le 0 -or [int]$t.RateDen -le 0 -or
                         [int]$t.Rotation -lt 1 -or [int]$t.Rotation -gt 4)) { return $false }
    }

    # Without the monitors' order this road cannot be taken. Setting the whole desk, we are obliged to name
    # the coordinates of EVERY screen, and there is no "do not know" among them: it would turn out that we
    # arrange the monitors by our own judgement — that is, alphabetically — where nobody asked us to. The
    # old path is more honest in that case: it moves only the primary monitor and leaves the rest standing
    # (see Invoke-CcdLayoutAttempt).
    #
    # ONE screen is the exception, and not a small one: there is nothing to arrange it against, its place
    # is the coordinate origin whatever anybody wrote in the settings, and a solo mode is the mode pressed
    # most often of all. Without this line every desk whose owner has never opened the Settings window —
    # that is, every fresh install — went the long way with its three transitions even to switch to a
    # single display.
    $hasExactPositions = ($Exact -and @($list | Where-Object { $null -eq $_.X -or $null -eq $_.Y }).Count -eq 0)
    if ($list.Count -gt 1 -and -not $hasExactPositions -and @($Order | Where-Object { $_ }).Count -eq 0) {
        Write-DisplayLog 'ccd: no display order in the settings - rebuilding the desk the long way'
        return $false
    }

    # Two attempts, and the second is not a repeat but a deliberate simplification of the request. The
    # refresh rate is the most fragile thing in this set: on the ASUS a 240 Hz write does not go through at
    # all, and on the ULTRAGEAR over HDMI such a mode simply does not exist.
    # A refusal over the refresh rate is no reason to lose the rest: the system will accept the resolutions
    # and the layout without a hint about hertz, and the refresh rate will be brought up afterwards by
    # Set-BestModeFor — in one repair step instead of three mandatory ones.
    #
    # We skip the first attempt when there is no exact fraction for any monitor: there is nothing to ask a
    # refresh rate with, and the attempt would knowingly be the same as the second.
    foreach ($withHz in $true, $false) {
        # A saved physical desktop is an all-or-nothing request. Retrying it without the exact rate would
        # report success after silently replacing part of the baseline Windows was asked to restore.
        if ($Exact -and -not $withHz) { continue }
        if ($withHz -and -not (@($list | Where-Object { [int]$_.RateDen -gt 0 }).Count)) { continue }
        if (Invoke-CcdFullConfigAttempt -Targets $list -PrimaryPath $PrimaryPath -Order $Order `
                                        -WithHz:$withHz -Exact:$Exact) {
            return $true
        }
    }
    return $false
}

# One attempt at setting the whole desk. A function of its own by the same rule as Invoke-CcdLayoutAttempt:
# all the work with CCD is here, while the "repeat or simplify" decision belongs to the caller, and the
# tests can shadow the attempt whole.
function Invoke-CcdFullConfigAttempt {
    param(
        [Parameter(Mandatory)]$Targets,
        [string]$PrimaryPath = '',
        [string[]]$Order = @(),
        [switch]$WithHz,
        [switch]$Exact
    )

    $tag = $(if ($WithHz) { ' (with refresh rates)' } else { ' (rates left to Windows)' })

    $byPath = @{}
    foreach ($t in @($Targets)) { $byPath[[string]$t.DevicePath] = $t }

    $choice = Get-CcdPathChoice -DevicePaths @($byPath.Keys)
    if (-not $choice) { return $false }
    # Get-CcdPathChoice refuses an incomplete set itself. Keep the same invariant here because this is
    # the last boundary before SetDisplayConfig and the choice is a plain object supplied by a caller.
    if (@($choice.Chosen).Count -ne $byPath.Count) { return $false }

    $paths = $choice.Paths
    $chosen = $choice.Chosen

    # The layout is worked out from the TARGET sizes rather than the current ones: some of the monitors
    # are out right now and have no sizes of their own at all, and they have to land straight in their
    # places — otherwise the repair pass will move them in a second rebuild.
    $screens = @()
    foreach ($i in $chosen) {
        $t = $byPath[$choice.DeviceByIndex[$i]]
        if (-not $t) { continue }
        $screens += [pscustomobject]@{
            DevicePath = [string]$t.DevicePath
            Label      = [string]$t.Label
            Width      = [int]$t.Width
            Height     = [int]$t.Height
        }
    }
    if ($screens.Count -ne $chosen.Count) { return $false }
    $useSavedPositions = ($Exact -and @($Targets | Where-Object { $null -eq $_.X -or $null -eq $_.Y }).Count -eq 0)
    $pos = @{}
    if ($useSavedPositions) {
        foreach ($t in @($Targets)) {
            $pos[[string]$t.DevicePath] = [pscustomobject]@{ X = [int]$t.X; Y = [int]$t.Y }
        }
    }
    else {
        $pos = Get-LayoutPositions -Screens $screens -Order $Order -PrimaryPath $PrimaryPath
    }

    # One mode record per path: the source mode (resolution and position). We do not set the TARGET's
    # mode — the refresh-rate hint in targetInfo is enough for it, and there is nowhere and no need to
    # get a full set of timings from.
    $out = New-Object 'NativeCcd+PATH_INFO[]' $chosen.Count
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $chosen.Count

    for ($k = 0; $k -lt $chosen.Count; $k++) {
        $p = $paths[$chosen[$k]]
        $t = $byPath[$choice.DeviceByIndex[$chosen[$k]]]
        $where = $pos[[string]$t.DevicePath]
        if (-not $where) { return $false }

        $m = New-Object NativeCcd+MODE_INFO
        $m.infoType = [NativeCcd]::MODE_INFO_TYPE_SOURCE
        $m.id = $p.sourceInfo.id
        $m.adapterId = $p.sourceInfo.adapterId
        $m.srcWidth = [uint32][int]$t.Width
        $m.srcHeight = [uint32][int]$t.Height
        $m.srcPixelFormat = [NativeCcd]::PIXELFORMAT_32BPP
        $m.srcPosX = [int]$where.X
        $m.srcPosY = [int]$where.Y
        $modes[$k] = $m

        $p.flags = $p.flags -bor [NativeCcd]::PATH_ACTIVE
        $s = $p.sourceInfo; $s.modeInfoIdx = [uint32]$k; $p.sourceInfo = $s

        $ti = $p.targetInfo
        # We do not set the target's mode by index — then the system takes the refresh rate from
        # refreshRate. Zeroes mean "choose it yourself", and that same value goes out on the second
        # attempt, when the refresh rate turned out to be unreachable.
        $ti.modeInfoIdx = [NativeCcd]::MODE_IDX_INVALID
        $rate = New-Object NativeCcd+RATIONAL
        $num = [int]$t.RateNum
        $den = [int]$t.RateDen
        if ($WithHz -and $num -gt 0 -and $den -gt 0) {
            $rate.Numerator = [uint32]$num
            $rate.Denominator = [uint32]$den
            $ti.scanLineOrdering = [NativeCcd]::SCANLINE_PROGRESSIVE
            # For a path that has gone out the system hands back the rotation and the scaling as zeroes,
            # and a zero is invalid in both enumerations: together with a specified refresh rate such a
            # path fails validation. We fix only the zeroes — if there is a value, it is somebody else's
            # and touching it is none of our business.
            if ($Exact)             { $ti.rotation = [uint32][int]$t.Rotation }
            elseif ($ti.rotation -eq 0) { $ti.rotation = [NativeCcd]::ROTATION_IDENTITY }
            if ($ti.scaling -eq 0)  { $ti.scaling  = [NativeCcd]::SCALING_IDENTITY }
        }
        else {
            $rate.Numerator = 0
            $rate.Denominator = 0
            $ti.scanLineOrdering = 0
        }
        $ti.refreshRate = $rate
        $p.targetInfo = $ti

        $out[$k] = $p
    }

    # SDC_ALLOW_CHANGES is deliberately NOT set: everything is specified here, and the system has to
    # apply exactly this or refuse. With it, the system may pick something of its own — and we would
    # again not know what is actually standing on the desk.
    $base = [NativeCcd]::SDC_USE_SUPPLIED_DISPLAY_CONFIG
    $rc = [NativeCcd]::SetDisplayConfig($out.Count, $out, $modes.Count, $modes, ($base -bor [NativeCcd]::SDC_VALIDATE))
    if ($rc -ne 0) {
        Write-DisplayLog ("ccd: full config validate -> $rc" + $tag)
        return $false
    }
    $rc = [NativeCcd]::SetDisplayConfig($out.Count, $out, $modes.Count, $modes,
        ($base -bor [NativeCcd]::SDC_APPLY -bor [NativeCcd]::SDC_SAVE_TO_DATABASE))
    if ($rc -ne 0) {
        Write-DisplayLog ("ccd: full config apply -> $rc" + $tag)
        return $false
    }

    Write-DisplayLog ("ccd: full config applied - {0} display(s) on{1}" -f $out.Count, $tag)
    return $true
}


# --- the layout and the primary monitor -------------------------------------
# Arranging the monitors and assigning the primary is one CCD call. Two things are done together
# because in Windows they are one and the same: "primary" is not a flag but a position — the monitor
# whose top-left corner lies at (0,0) becomes it. Which is why the layout is first built left to right
# and then shifted whole so that the future primary lands at the coordinate origin.
#
# The order comes from the settings (the layout key) — a list of names left to right. A monitor that is
# not in the list goes to the end. If the list is empty, the current coordinates are kept as they are
# and only the primary is moved.
#
# Why not the old API: ChangeDisplaySettingsEx with CDS_UPDATEREGISTRY hands back -1 on all three
# monitors at once. Writing the layout the old way simply does not work on this machine.
#
# SDC_ALLOW_CHANGES is deliberately NOT set: without it the system has to apply exactly the coordinates
# it was handed or refuse. With it, it may pick something of its own, and the monitors would drift apart
# again.

# Ok + Changed rather than a yes/no: the caller needs Changed so as not to write "arranged left to
# right" into the log where nothing was arranged — a line about work that never happened sends people
# looking for the defect in the wrong place.
# $Note is what the log should say instead of "already correct" when nothing moved for a reason of its
# own. Empty for every ordinary answer: the caller has a line for each of those.
function New-LayoutResult {
    param([bool]$Ok, [bool]$Changed, [string]$Note = '')
    return [pscustomobject]@{ Ok = $Ok; Changed = $Changed; Note = $Note }
}

# Where each monitor lands: device path -> @{X;Y}. Pure arithmetic, without a single call to the system
# — which is why it is covered by tests and does not depend on who is asking.
#
# Two callers ask: Set-CcdFullConfig, which sets the whole desk in one transition (there the sizes are
# the TARGET ones, and a monitor may still be out), and Invoke-CcdLayoutAttempt, which adjusts a desk
# that already stands (there the sizes are the current ones). The layout has to come out the same: let
# those two calculations diverge, and the repair pass would move the monitors after the primary — the
# very extra rebuild that makes the whole desk stutter.
#
# $Screens is objects with DevicePath, Label, Width, Height.
function Get-LayoutPositions {
    param(
        [Parameter(Mandatory)]$Screens,
        [string[]]$Order = @(),
        [string]$PrimaryPath = ''
    )

    $list = @($Screens)
    $out = @{}
    if ($list.Count -eq 0) { return $out }

    # A place in the list: we compare by containment so that "UltraGear" finds "LG ULTRAGEAR" and the
    # other way round — the system's names are shorter than the human ones.
    #
    # A display the order does not name starts one past the last rank, so it lands behind everybody the
    # order does name, and Sort-Object breaks that tie by label. With no order at all $Order.Count is 0:
    # everybody ranks the same and the whole desk is sorted by label. ".Count on $Order" is deliberately
    # the ONE spelling of "is there an order" in this file — $null.Count is 0 in PowerShell 5.1, so the
    # extra truthiness test that used to guard it only made three places look like three questions.
    $ranked = @()
    foreach ($s in $list) {
        $rank = $Order.Count
        for ($k = 0; $k -lt $Order.Count; $k++) {
            $o = $Order[$k]
            if (-not $o) { continue }
            if (Test-DisplayNameMatch -Pattern $o -Label $s.Label -ShortId '') { $rank = $k; break }
        }
        $ranked += [pscustomobject]@{
            DevicePath = $s.DevicePath
            Label      = $s.Label
            Width      = [int]$s.Width
            Height     = [int]$s.Height
            Rank       = $rank
        }
    }
    $ordered = @($ranked | Sort-Object Rank, Label)

    # Vertically they are centred: the screens differ in height in pixels (1440 and 2160), and aligning
    # them at the top leaves a strip at the bottom of the tall one that the cursor cannot cross to the
    # neighbour from.
    $tallest = ($ordered | Measure-Object -Property Height -Maximum).Maximum
    $x = 0
    foreach ($s in $ordered) {
        $out[$s.DevicePath] = [pscustomobject]@{ X = $x; Y = [int](($tallest - $s.Height) / 2) }
        $x += $s.Width
    }

    # We shift everything so that the primary ends up at (0,0): in Windows the monitor whose top-left
    # corner lies there is the one that becomes primary.
    $anchorPath = ''
    if ($PrimaryPath -and $out.ContainsKey($PrimaryPath)) { $anchorPath = $PrimaryPath }
    else { $anchorPath = $ordered[0].DevicePath }

    $dx = $out[$anchorPath].X
    $dy = $out[$anchorPath].Y
    if ($dx -ne 0 -or $dy -ne 0) {
        foreach ($k in @($out.Keys)) {
            $out[$k] = [pscustomobject]@{ X = ($out[$k].X - $dx); Y = ($out[$k].Y - $dy) }
        }
    }

    return $out
}

function Set-CcdLayout {
    param([string]$PrimaryPath, [string[]]$Order = @(), [int]$RetryDelayMs = 300)

    # Up to three attempts, each with a fresh QueryDisplayConfig. A second after a topology change the
    # validation returns 87 (ERROR_INVALID_PARAMETER): a snapshot taken in a transitional state is one the
    # system then refuses to accept itself, while the same call a little later goes through on the first
    # try in half a second. Without a retry the desk would be left standing the way Windows arranged it —
    # with the monitors muddled up. The refusal is momentary, so it is cured by a retry, but the retry has
    # to be whole: after a refusal the old configuration snapshot no longer describes anything.
    $attempts = 3
    for ($n = 1; $n -le $attempts; $n++) {
        if ($n -gt 1 -and $RetryDelayMs -gt 0) { Start-Sleep -Milliseconds $RetryDelayMs }
        $r = Invoke-CcdLayoutAttempt -PrimaryPath $PrimaryPath -Order $Order -Attempt $n -Attempts $attempts
        if ($r.Ok) { return $r }
    }
    Write-DisplayLog ("warn: layout gave up after {0} attempts" -f $attempts)
    return (New-LayoutResult -Ok $false -Changed $false)
}

# One attempt at arranging the monitors. A function of its own so that Set-CcdLayout can repeat it whole
# and the tests can shadow it; all the real work with CCD is here.
function Invoke-CcdLayoutAttempt {
    param([string]$PrimaryPath, [string[]]$Order = @(), [int]$Attempt = 1, [int]$Attempts = 1)

    $tag = " (attempt $Attempt/$Attempts)"

    $np = 0; $nm = 0
    if ([NativeCcd]::GetDisplayConfigBufferSizes([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, [ref]$nm) -ne 0) {
        Write-DisplayLog ('warn: layout - could not size the display config buffers' + $tag)
        return (New-LayoutResult -Ok $false -Changed $false)
    }
    $paths = New-Object 'NativeCcd+PATH_INFO[]' $np
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $nm
    if ([NativeCcd]::QueryDisplayConfig([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) {
        Write-DisplayLog ('warn: layout - QueryDisplayConfig refused' + $tag)
        return (New-LayoutResult -Ok $false -Changed $false)
    }

    # The original positions are remembered BEFORE any edits: below, they are what decides whether to call
    # SetDisplayConfig at all. Windows with SDC_SAVE_TO_DATABASE often restores the layout itself, and the
    # typical case — "everything already stands as it should" — used to cost a second rebuild of the
    # screens: a blink and a second or two of time.
    $before = @{}
    for ($i = 0; $i -lt $nm; $i++) {
        if ($modes[$i].infoType -ne [NativeCcd]::MODE_INFO_TYPE_SOURCE) { continue }
        $before[$i] = [pscustomobject]@{ X = $modes[$i].srcPosX; Y = $modes[$i].srcPosY }
    }

    # Source-mode index -> monitor. One source can serve several paths, so we walk the paths and remember
    # the first match.
    $screens = @()
    $seenIdx = @{}
    for ($i = 0; $i -lt $np; $i++) {
        $mi = $paths[$i].sourceInfo.modeInfoIdx
        if ($mi -eq [NativeCcd]::MODE_IDX_INVALID) { continue }
        $idx = [int]$mi
        if ($seenIdx.ContainsKey($idx)) { continue }
        $seenIdx[$idx] = $true

        $dp = Get-CcdPathDevice $paths[$i]
        if (-not $dp) { continue }

        $t = New-Object NativeCcd+TARGET_DEVICE_NAME
        $h = New-Object NativeCcd+HEADER
        $h.type = [NativeCcd]::GET_TARGET_NAME
        $h.size = [System.Runtime.InteropServices.Marshal]::SizeOf($t)
        $h.adapterId = $paths[$i].targetInfo.adapterId
        $h.id = $paths[$i].targetInfo.id
        $t.header = $h
        $label = ''
        if ([NativeCcd]::DisplayConfigGetDeviceInfo([ref]$t) -eq 0) { $label = $t.monitorFriendlyDeviceName }

        $screens += [pscustomobject]@{
            ModeIdx    = $idx
            DevicePath = $dp
            Label      = $label
            Width      = [int]$modes[$idx].srcWidth
            Height     = [int]$modes[$idx].srcHeight
        }
    }
    if ($screens.Count -eq 0) {
        Write-DisplayLog ('warn: layout - no active screens to arrange' + $tag)
        return (New-LayoutResult -Ok $false -Changed $false)
    }

    Set-DisplayIdentity -State $screens -Known (Get-KnownDisplays)
    if ($Order.Count -gt 0) {
        $want = Get-LayoutPositions -Screens $screens -Order $Order -PrimaryPath $PrimaryPath
        foreach ($s in $screens) {
            $p = $want[$s.DevicePath]
            if (-not $p) { continue }
            $m = $modes[$s.ModeIdx]
            $m.srcPosX = $p.X
            $m.srcPosY = $p.Y
            $modes[$s.ModeIdx] = $m
        }
    }
    else {
        # There is no order — nothing to arrange, but the primary monitor still has to end up at (0,0):
        # in Windows "primary" is not a flag but a place.
        #
        # And only that monitor. Anchoring on whoever happens to be first when the one we were asked for
        # is NOT on the desk shifts the WHOLE desk by that stranger's offset: every window moves, the
        # taskbar lands on a display nobody named, and the line below reports the taskbar as having gone
        # to the display that never came up. Harmless while this branch was reached only when a `layout`
        # existed; since the call became unconditional (see Switch-DisplayMode) it is reached on every
        # desk whose owner has never opened the Settings window, and a display that refused to wake is
        # exactly when it fires. There is nobody to anchor, so nothing moves — the absent display is
        # already reported in its own right.
        $anchor = $null
        if ($PrimaryPath) { $anchor = @($screens | Where-Object { $_.DevicePath -eq $PrimaryPath }) | Select-Object -First 1 }
        if (-not $anchor) {
            $why = $(if ($PrimaryPath) { 'the display that was to be primary is not on the desk' }
                     else { 'no display was named primary' })
            return (New-LayoutResult -Ok $true -Changed $false -Note ('layout: ' + $why + ' - nobody moved'))
        }

        $dx = $modes[$anchor.ModeIdx].srcPosX
        $dy = $modes[$anchor.ModeIdx].srcPosY
        if ($dx -ne 0 -or $dy -ne 0) {
            for ($i = 0; $i -lt $nm; $i++) {
                if ($modes[$i].infoType -ne [NativeCcd]::MODE_INFO_TYPE_SOURCE) { continue }
                $m = $modes[$i]
                $m.srcPosX = $m.srcPosX - $dx
                $m.srcPosY = $m.srcPosY - $dy
                $modes[$i] = $m
            }
        }
    }

    # Nothing moved — so there is nothing to apply. The check comes after the shift to the anchor, so it
    # also means "the monitor we need is already at (0,0)", that is, already primary.
    $moved = $false
    foreach ($i in @($before.Keys)) {
        if ($modes[$i].srcPosX -ne $before[$i].X -or $modes[$i].srcPosY -ne $before[$i].Y) { $moved = $true; break }
    }
    if (-not $moved) { return (New-LayoutResult -Ok $true -Changed $false) }

    # Where it has to arrive goes by the monitor's path rather than by the mode index: indices need not
    # match between two QueryDisplayConfig calls, whereas a device path is stable. We take it before
    # applying and check it afterwards.
    $wantPos = @{}
    foreach ($s in $screens) {
        $wantPos[$s.DevicePath] = [pscustomobject]@{ X = $modes[$s.ModeIdx].srcPosX; Y = $modes[$s.ModeIdx].srcPosY }
    }

    $base = [NativeCcd]::SDC_USE_SUPPLIED_DISPLAY_CONFIG
    $rc = [NativeCcd]::SetDisplayConfig($np, $paths, $nm, $modes, ($base -bor [NativeCcd]::SDC_VALIDATE))
    if ($rc -ne 0) {
        Write-DisplayLog ("ccd: layout validate -> $rc" + $tag)
        return (New-LayoutResult -Ok $false -Changed $false)
    }
    $rc = [NativeCcd]::SetDisplayConfig($np, $paths, $nm, $modes,
        ($base -bor [NativeCcd]::SDC_APPLY -bor [NativeCcd]::SDC_SAVE_TO_DATABASE))
    if ($rc -ne 0) {
        Write-DisplayLog ("ccd: layout apply -> $rc" + $tag)
        return (New-LayoutResult -Ok $false -Changed $false)
    }

    # Instead of Start-Sleep 700 we wait on the fact: the system has to start handing back the positions
    # we just set. The pause was "just in case", and like every fixed pause it was both too long in the
    # ordinary case and too short in the bad one.
    if (-not (Wait-ForLayout -WantedPositions $wantPos)) {
        Write-DisplayLog 'warn: layout did not settle'
        return (New-LayoutResult -Ok $false -Changed $false)
    }
    return (New-LayoutResult -Ok $true -Changed $true)
}

# The exact refresh rate of the active monitors: path -> @{Num;Den}. There are deliberately no whole
# hertz here — for those one goes to EnumDisplaySettings, whereas one comes here for the fraction
# specifically, which can then be handed back to the system word for word (see Get-ModeCache).
function Get-CcdActiveRates {
    $np = 0; $nm = 0
    if ([NativeCcd]::GetDisplayConfigBufferSizes([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, [ref]$nm) -ne 0) { return @{} }
    $paths = New-Object 'NativeCcd+PATH_INFO[]' $np
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $nm
    if ([NativeCcd]::QueryDisplayConfig([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) { return @{} }

    $out = @{}
    for ($i = 0; $i -lt $np; $i++) {
        $r = $paths[$i].targetInfo.refreshRate
        if ($r.Numerator -le 0 -or $r.Denominator -le 0) { continue }
        $dp = Get-CcdPathDevice $paths[$i]
        if (-not $dp -or $out.ContainsKey($dp)) { continue }
        $out[$dp] = [pscustomobject]@{ Num = [int]$r.Numerator; Den = [int]$r.Denominator }
    }
    return $out
}

# The positions of the source modes by monitor path: path -> @{X;Y}. A function of its own, because it is
# needed both for waiting on the layout and, in future, for window snapshots.
function Get-CcdSourcePositions {
    $np = 0; $nm = 0
    if ([NativeCcd]::GetDisplayConfigBufferSizes([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, [ref]$nm) -ne 0) { return @{} }
    $paths = New-Object 'NativeCcd+PATH_INFO[]' $np
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $nm
    if ([NativeCcd]::QueryDisplayConfig([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) { return @{} }

    $out = @{}
    for ($i = 0; $i -lt $np; $i++) {
        $mi = $paths[$i].sourceInfo.modeInfoIdx
        if ($mi -eq [NativeCcd]::MODE_IDX_INVALID) { continue }
        $dp = Get-CcdPathDevice $paths[$i]
        if (-not $dp -or $out.ContainsKey($dp)) { continue }
        $out[$dp] = [pscustomobject]@{ X = [int]$modes[[int]$mi].srcPosX; Y = [int]$modes[[int]$mi].srcPosY }
    }
    return $out
}

# Wait until the positions we set really land. $false — they did not within the deadline.
function Wait-ForLayout {
    param(
        [Parameter(Mandatory)]$WantedPositions,
        [int]$TimeoutMs = 3000,
        [int]$StepMs = 200
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $now = Get-CcdSourcePositions
        $bad = 0
        foreach ($dp in @($WantedPositions.Keys)) {
            $p = $now[$dp]
            if ($null -eq $p -or $p.X -ne $WantedPositions[$dp].X -or $p.Y -ne $WantedPositions[$dp].Y) { $bad++ }
        }
        if ($bad -eq 0) { return $true }
        if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $false }
        Start-Sleep -Milliseconds $StepMs
    }
}

# Wait until the desk is exactly what was asked for: every monitor we need has come up and not one
# spare is left. Counted through CCD rather than through the output map: with CCD the active flag sits
# on the monitor's own path, and it cannot be confused with a neighbour's.
#
# We wait on a condition rather than on a timer: a fixed pause is either too short (we read "still
# active" off a monitor that is going out) or spent for nothing. A full Get-DisplayState is not needed
# here — Get-CcdTargets hands back both the activity and the names, and costs ~10 ms against ~90.
#
# Returns Ok plus two lists of names: who did not come up and who did not go out.
#
# Two deadlines rather than one. TimeoutMs is how long we wait for the monitors to wake up (the ASUS
# takes about ten seconds, that is physics). ExtraGraceMs is how much longer we wait for the spare ones
# to go out AFTER everything we need is already on the desk: a monitor that is about to go out does so
# in a second or two, and if it has dug in, it has dug in. With one shared deadline a refusal to go out
# would cost the whole 15 s of waiting on a path that had already failed anyway.
function Wait-ForTopology {
    param(
        [Parameter(Mandatory)][string[]]$WantedPaths,
        [int]$TimeoutMs = 15000,
        [int]$ExtraGraceMs = 3000,
        [int]$StepMs = 200
    )

    $want = @{}
    foreach ($p in $WantedPaths) { if ($p) { $want[$p] = $true } }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $allUpAt = -1
    $missing = @()
    $extra = @()

    while ($true) {
        $byPath = @{}
        foreach ($t in @(Get-CcdTargets)) { $byPath[$t.DevicePath] = $t }

        # The name for the report comes from CCD; if the path has vanished from the enumeration
        # altogether, we show the path — staying quiet is not allowed, and there is nothing else to call
        # the monitor by.
        $missing = @()
        foreach ($p in @($want.Keys)) {
            $t = $byPath[$p]
            if ($null -eq $t -or -not $t.Active) {
                $missing += $(if ($t -and $t.Label) { $t.Label } else { $p })
            }
        }
        $extra = @($byPath.Values |
            Where-Object { $_.Active -and -not $want.ContainsKey($_.DevicePath) } |
            ForEach-Object { $(if ($_.Label) { $_.Label } else { $_.DevicePath }) })

        if ($missing.Count -eq 0 -and $extra.Count -eq 0) {
            return [pscustomobject]@{ Ok = $true; MissingLabels = @(); ExtraLabels = @() }
        }

        $elapsed = $sw.ElapsedMilliseconds
        if ($missing.Count -eq 0) {
            if ($allUpAt -lt 0) { $allUpAt = $elapsed }
            if (($elapsed - $allUpAt) -ge $ExtraGraceMs) { break }
        }
        if ($elapsed -ge $TimeoutMs) { break }

        Start-Sleep -Milliseconds $StepMs
    }

    return [pscustomobject]@{ Ok = $false; MissingLabels = @($missing); ExtraLabels = @($extra) }
}


# A monitor's output name, once it is on the desk. $null if it never turned up.
function Get-CcdOutput {
    param([Parameter(Mandatory)][string]$DevicePath, [int]$TimeoutMs = 8000)

    $waited = 0
    while ($true) {
        $t = @(Get-CcdTargets | Where-Object { $_.DevicePath -eq $DevicePath -and $_.Active -and $_.Output })
        if ($t.Count -gt 0) { return $t[0].Output }
        if ($waited -ge $TimeoutMs) { return $null }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
}


# The native resolution comes from the system: GET_TARGET_PREFERRED_MODE in Get-CcdTargets hands back
# the preferred timing out of EDID, and for a monitor that is switched off too — there is no need to
# parse the registry by hand. Asking the driver is useless: for the ULTRAGEAR it answers 3840x2160,
# because over HDMI that one accepts 4K and squeezes it into its own 1440p itself.
# The best mode is the highest refresh rate at the native resolution. Without it, if EDID could not be
# read, we fall back to the old rule — the largest area, then the refresh rate. Progressive modes only
# (dmDisplayFlags = 0).
function Get-BestMode {
    param([string]$Output, [int]$NativeWidth = 0, [int]$NativeHeight = 0)

    $best = $null
    $i = 0
    while ($true) {
        $dm = New-Object NativeDisplay+DEVMODE
        $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        if (-not [NativeDisplay]::EnumDisplaySettings($Output, $i, [ref]$dm)) { break }
        $i++

        if ($dm.dmBitsPerPel -lt 32 -or $dm.dmDisplayFlags -ne 0) { continue }

        if ($NativeWidth -gt 0 -and $NativeHeight -gt 0) {
            if ($dm.dmPelsWidth -ne $NativeWidth -or $dm.dmPelsHeight -ne $NativeHeight) { continue }
            $score = [int64]$dm.dmDisplayFrequency
        }
        else {
            $score = ([int64]$dm.dmPelsWidth * $dm.dmPelsHeight * 10000) + $dm.dmDisplayFrequency
        }

        if (($null -eq $best) -or ($score -gt $best.Score)) {
            $best = [pscustomobject]@{
                Width = $dm.dmPelsWidth; Height = $dm.dmPelsHeight
                Hz    = $dm.dmDisplayFrequency; Score = $score
            }
        }
    }

    # There is a native resolution but no modes at it — that happens when a monitor is connected through
    # an adapter. Then the old rule is better than nothing.
    if (-not $best -and $NativeWidth -gt 0) { return Get-BestMode -Output $Output }
    return $best
}

function Get-CurrentMode {
    param([string]$Output)

    $dm = New-Object NativeDisplay+DEVMODE
    $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
    if ([NativeDisplay]::EnumDisplaySettings($Output, [NativeDisplay]::CURRENT_SETTINGS, [ref]$dm)) {
        return [pscustomobject]@{
            Width = $dm.dmPelsWidth; Height = $dm.dmPelsHeight; Hz = $dm.dmDisplayFrequency
            X = $dm.dmPositionX; Y = $dm.dmPositionY; Rotation = $dm.dmDisplayOrientation
        }
    }
    return $null
}


# Changing one monitor's resolution and refresh rate. ChangeDisplaySettingsEx hands back a return code,
# so a miss is visible at once and the attempt can be repeated.
function Set-DisplayMode {
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [Parameter(Mandatory)][int]$Hz
    )

    # Every time we assemble the DEVMODE afresh out of the current one: that way the position, the
    # orientation and everything else that is none of our business are preserved, and a failed call
    # leaves no damaged structure behind it.
    $build = {
        $dm = New-Object NativeDisplay+DEVMODE
        $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        if (-not [NativeDisplay]::EnumDisplaySettings($Output, [NativeDisplay]::CURRENT_SETTINGS, [ref]$dm)) {
            return $null
        }
        $dm.dmBitsPerPel = 32
        $dm.dmPelsWidth = $Width
        $dm.dmPelsHeight = $Height
        $dm.dmDisplayFrequency = $Hz
        $dm.dmFields = [NativeDisplay]::DM_BITSPERPEL -bor [NativeDisplay]::DM_PELSWIDTH -bor
                       [NativeDisplay]::DM_PELSHEIGHT -bor [NativeDisplay]::DM_DISPLAYFREQUENCY
        return $dm
    }

    $describe = {
        param($c)
        switch ($c) {
            0       { 'ok' }
            1       { 'needs restart' }
            -1      { 'failed' }
            -2      { 'bad mode' }
            -3      { 'not updated' }
            -4      { 'bad flags' }
            -5      { 'bad parameter' }
            default { "code $c" }
        }
    }

    $dm = & $build
    if (-not $dm) { return [pscustomobject]@{ Code = -999; Text = 'EnumDisplaySettings failed'; Persisted = $false } }

    # First we ask for the mode to be applied and remembered (CDS_UPDATEREGISTRY).
    $code = [NativeDisplay]::ChangeDisplaySettingsEx($Output, [ref]$dm, [IntPtr]::Zero,
                                                     [NativeDisplay]::CDS_UPDATEREGISTRY, [IntPtr]::Zero)
    if ($code -eq 0) {
        return [pscustomobject]@{ Code = 0; Text = 'ok'; Persisted = $true }
    }

    # It did not work out — we apply without writing to the registry (flags = 0).
    #
    # On the ASUS ROG STRIX the registry write goes through for no refresh rate at all, including the one
    # that is already set: CDS_UPDATEREGISTRY hands back failed, while the same mode with flags = 0
    # applies instantly. Because of that the monitor used to stay at 59 Hz instead of 240. Both LGs work
    # fine with the write.
    #
    # The refresh rate matters more than saving it: we set the mode afresh on every switch anyway. The
    # check for -2/-5 is there so as not to repeat a mode that is known to be impossible.
    if ($code -eq -2 -or $code -eq -5) {
        return [pscustomobject]@{ Code = $code; Text = (& $describe $code); Persisted = $false }
    }

    $dm2 = & $build
    if (-not $dm2) { return [pscustomobject]@{ Code = $code; Text = (& $describe $code); Persisted = $false } }

    $code2 = [NativeDisplay]::ChangeDisplaySettingsEx($Output, [ref]$dm2, [IntPtr]::Zero, 0, [IntPtr]::Zero)
    if ($code2 -eq 0) {
        return [pscustomobject]@{ Code = 0; Text = 'ok (not saved to registry)'; Persisted = $false }
    }
    return [pscustomobject]@{ Code = $code2; Text = (& $describe $code2); Persisted = $false }
}

# Wait until the monitor really reports the mode we set. A short deadline: a mode change either lands
# almost at once or does not land at all and a second attempt is needed.
function Wait-ForMode {
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [Parameter(Mandatory)][int]$Hz,
        [int]$TimeoutMs = 1500,
        [int]$StepMs = 100
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $c = Get-CurrentMode $Output
        if ($c -and $c.Width -eq $Width -and $c.Height -eq $Height -and $c.Hz -eq $Hz) { return $true }
        if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $false }
        Start-Sleep -Milliseconds $StepMs
    }
}

# Bring a monitor up to its best mode, if it is not standing there already. With a check and a retry: a
# change of primary monitor and putting a neighbour out can reset the mode even after it has been set.
function Set-BestModeFor {
    param(
        [Parameter(Mandatory)][string]$Output,
        [string]$Label = '',
        [int]$NativeWidth = 0,
        [int]$NativeHeight = 0,
        $Best = $null
    )

    # $Best can be handed in ready, and that is not a micro-optimisation. Get-BestMode walks
    # EnumDisplaySettings over all of a monitor's modes, and right after a topology change the driver
    # hands them back an order of magnitude more slowly than at rest: seconds against 60 ms, and that on
    # monitors that needed nothing changed.
    #
    # The state taken on the way into a switch already holds the BestMode of every monitor that is on
    # (Get-DisplayState worked it out), and the largest mode does not change when the set of screens does:
    # the native resolution comes from EDID, and the list of refresh rates is a property of the panel, not
    # of the layout. A recount is left only for whoever has just woken up: their BestMode is unknown.
    $best = $Best
    if (-not $best) { $best = Get-BestMode -Output $Output -NativeWidth $NativeWidth -NativeHeight $NativeHeight }
    if (-not $best) { return $null }

    foreach ($attempt in 1, 2) {
        $current = Get-CurrentMode $Output
        if ($current -and $current.Width -eq $best.Width -and $current.Height -eq $best.Height -and $current.Hz -eq $best.Hz) {
            return $true
        }

        $r = Set-DisplayMode -Output $Output -Width $best.Width -Height $best.Height -Hz $best.Hz
        Write-DisplayLog ("mode: {0} {1} -> {2}x{3}@{4} - {5} (attempt {6})" -f `
            $Label, $Output, $best.Width, $best.Height, $best.Hz, $r.Text, $attempt)
        # The mode is impossible — there is nothing to repeat. Other refusals happen because the monitor
        # is still rebuilding, and those are worth repeating.
        if ($r.Code -eq -2 -or $r.Code -eq -5) { return $false }

        # There used to be a Start-Sleep 600 here — and it slept even when the mode landed on the first
        # attempt: the success was only discovered at the start of the next lap. In `all` mode that is an
        # extra 600 ms for every monitor whose refresh rate was changed. Now we wait on the fact: the
        # moment the monitor reports the mode we want, we leave.
        if (Wait-ForMode -Output $Output -Width $best.Width -Height $best.Height -Hz $best.Hz) {
            return $true
        }
    }

    $current = Get-CurrentMode $Output
    $ok = ($current -and $current.Hz -eq $best.Hz)
    if (-not $ok) {
        # The monitor could have detached between two lines — then $current is empty, and without this
        # substitution the log used to get "stayed at  Hz", that is, the diagnostic vanished in exactly
        # the place it is needed.
        $was = $(if ($current) { [string]$current.Hz } else { 'unknown - the display detached' })
        Write-DisplayLog ("mode: {0} stayed at {1} Hz instead of {2} - something outside is resetting it" -f `
            $Label, $was, $best.Hz)
    }
    return $ok
}

# --- state ------------------------------------------------------------------
# The short Monitor ID is the manufacturer code out of EDID plus the model code: GSM = LG (GoldStar),
# AUS = ASUS. It is stable for a model but NOT for an instance and not for an input, which is why the
# settings key is the monitor's name (see Get-DisplayModes).

# Whether a piece of a name from the settings fits this monitor. We compare by containment in both
# directions: the system knows the monitor as "XG27AQDMGR" while a person might have written "ROG STRIX
# XG27AQDMGR", and the other way round "UltraGear" has to find "LG ULTRAGEAR". Case does not matter:
# -like without -c.
#
# One rule for everywhere a person names a monitor in words: layout, primary, a combo's membership. Two
# definitions would drift apart on the very first non-standard name.
# Duplicate panels keep a connection fingerprint in their label. Enumeration ordinals would send
# a saved shortcut to the other panel after hotplug. Model remains the manufacturer's name.
function Set-DisplayIdentity {
    param($State, $Known = $null)

    $counts = @{}
    foreach ($m in @($State)) {
        $model = [string]$m.Model
        if (-not $model) { $model = [string]$m.Label }
        $counts[$model] = 1 + [int]$counts[$model]
    }
    foreach ($m in @($State)) {
        if (-not $m) { continue }
        $deviceId = [string]$m.Id
        if (-not $deviceId) { $deviceId = [string]$m.DevicePath }
        if (-not $deviceId) { continue }
        if ([string]$m.Label -match ' \{[a-f0-9]{16}\}$') { continue }
        $remembered = $null
        if ($Known) {
            $remembered = @($Known.Values | Where-Object {
                $_.Id -eq $deviceId -and $_.Label -match ' \{[a-f0-9]{16}\}$'
            }) | Select-Object -First 1
        }
        if ($remembered) { $m.Label = [string]$remembered.Label; continue }
        $model = [string]$m.Model
        if (-not $model) { $model = [string]$m.Label }
        $knownTwin = $false
        if ($Known) {
            $knownTwin = @($Known.Values | Where-Object {
                $_.Model -eq $model -and $_.Label -match ' \{[a-f0-9]{16}\}$'
            }).Count -gt 0
        }
        if ($counts[$model] -lt 2 -and -not $knownTwin) { continue }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($deviceId.ToLowerInvariant())
            $suffix = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 16).ToLowerInvariant()
        }
        finally { $sha.Dispose() }
        $m.Label = $model + ' {' + $suffix + '}'
    }
}

function Test-DisplayNameMatch {
    param([string]$Pattern, [string]$Label, [string]$ShortId)

    if (-not $Pattern) { return $false }
    # An absent instance must not fall back to its model and select its connected twin.
    if ($Pattern -match ' \{[a-f0-9]{16}\}$') { return $Pattern -eq $Label }
    foreach ($name in $Label, $ShortId) {
        if (-not $name) { continue }
        if ($name.IndexOf($Pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $Pattern.IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

# A connection fingerprint is part of the stable selector, not a name anyone should have to
# read. Keep enough of it visible to tell identical panels apart, while the complete Label stays
# behind the title for settings, matching and the log. The same formatting is used for a live
# display and for a solo key whose display is currently absent.
function Get-DisplayTitle {
    param([string]$Label)

    if ($Label -match '^(.*) \{([a-f0-9]{16})\}$') {
        return $Matches[1] + ' ' + [string][char]0x00B7 + ' ' + $Matches[2].Substring(0, 6).ToUpperInvariant()
    }
    return $Label
}

# Who is primary right now. We ask the adapters only: they carry the PRIMARY_DEVICE flag right there in
# StateFlags, and there is no need at all to walk the child monitors (where the bug with the hard-coded
# index 0 used to live) for this.
function Get-PrimaryOutput {
    $i = 0
    while ($true) {
        $a = New-DisplayDevice
        if (-not [NativeDisplay]::EnumDisplayDevices([NullString]::Value, $i, [ref]$a, 0)) { break }
        $i++
        if (($a.StateFlags -band [NativeDisplay]::PRIMARY_DEVICE) -ne 0) { return $a.DeviceName }
    }
    return $null
}

# The state of every monitor — out of CCD (see the comment on the NativeCcd class).
#
# Id is the device path out of CCD. A monitor that is switched off has one too, so it can be both
# identified by it and switched back on by it.
#
# The settings are not needed here and are not read: the state is what Windows says about the desk, not
# what a person wrote about it. A combo's membership is parsed by Get-DisplayModes, and that is what the
# settings are handed to.
function Get-DisplayState {
    $targets = @(Get-CcdTargets)
    if ($targets.Count -eq 0) { throw 'Windows returned no displays at all' }

    $primaryOutput = Get-PrimaryOutput

    $state = @(foreach ($t in $targets) {
        $label = $t.Label
        if (-not $label) { $label = $t.ShortId }
        if (-not $label) { $label = $t.DevicePath }

        $nw = 0; $nh = 0
        if ($t.Native) { $nw = $t.Native.Width; $nh = $t.Native.Height }

        $best = $null
        $cur = $null
        if ($t.Active -and $t.Output) {
            $best = Get-BestMode -Output $t.Output -NativeWidth $nw -NativeHeight $nh
            $cur = Get-CurrentMode $t.Output
        }

        [pscustomobject]@{
            Output       = $t.Output
            Label        = $label
            Model        = $label
            ShortId      = $t.ShortId
            Native       = $t.Native
            Id           = $t.DevicePath
            Active       = $t.Active
            Primary      = ($t.Active -and $t.Output -and $t.Output -eq $primaryOutput)
            Disconnected = (-not $t.Available)
            Width        = $(if ($cur) { $cur.Width } else { 0 })
            Height       = $(if ($cur) { $cur.Height } else { 0 })
            Hz           = $(if ($cur) { $cur.Hz } else { 0 })
            X            = $(if ($t.Active) { [int]$t.X } else { 0 })
            Y            = $(if ($t.Active) { [int]$t.Y } else { 0 })
            Rotation     = $(if ($t.Active) { [int]$t.Rotation } else { 0 })
            RateNum      = $(if ($t.Active) { [int]$t.RateNum } else { 0 })
            RateDen      = $(if ($t.Active) { [int]$t.RateDen } else { 0 })
            BestMode     = $best
        }
    })
    Set-DisplayIdentity -State $state -Known (Get-KnownDisplays)
    return $state
}

# --- the monitors this desk has ever had ------------------------------------
# A monitor switched off at its own button does not always stay on the bus, and the two kinds
# look nothing alike from here. Both LGs on this desk keep their target: CCD hands it back with
# targetAvailable = 0, so the state still holds a record and the interface can say "LG ULTRAFINE
# - not connected". The ASUS leaves the DisplayPort bus altogether (that is the Kernel-PnP 1010
# tools/trace-displays.ps1 pairs our log with), QueryDisplayConfig stops mentioning it at all,
# and everything downstream loses it: no card on the desk, no row in the table, no tick in a
# combo and no solo mode — so no way to write a rule about the display you are about to switch
# to. Which is exactly the moment a person writes one.
#
# So the desk the INTERFACE shows is the state plus this roster: what has been seen before and
# is not in the enumeration now. $script:KnownLabels in Displays.ps1 is the same idea for the
# length of one run — it names a monitor at the instant it drops off the bus, when asking the
# system is already too late; this is that index written down, so it survives a restart.
#
# Records use the selected label: plain model names for unique panels, a connection fingerprint
# for identical ones. This keeps both twins when one leaves the bus without importing stale
# monitors from the registry. A changed port on an identical panel requires selecting it again;
# silently transferring its settings to another instance would switch the wrong screen.
#
# Only the interface adds absent records. Get-DisplayState reads labels but sees the desk as
# Windows has it, so a remembered monitor's mode comes out Available = $false and asking for it
# fails in the same words it did before ("That display is not connected right now").

# How long a monitor is remembered after it was last seen. One that has been sold, or left
# behind at an old desk, has to stop being offered by itself: this is the machine's state rather
# than a setting, and there is deliberately no interface to it for clearing a row by hand. Three
# months is longer than a holiday and shorter than a job.
$script:KnownDisplayDays = 90

# The roster off the disk: name -> {Label; ShortId; Id; Native; Seen}. An empty map when the file
# is absent or damaged — a roster is a convenience, and there is nothing in it worth failing a
# window over.
function Get-KnownDisplays {
    $out = [ordered]@{}
    if (-not (Test-Path $script:KnownDisplaysFile)) { return $out }
    try {
        $raw = Get-Content $script:KnownDisplaysFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) {
            if (-not $p.Name -or $null -eq $p.Value) { continue }
            $v = $p.Value
            $w = [int]$v.w; $h = [int]$v.h
            # ConvertFrom-Json turns "2026-09-04" into a [datetime], and a bare [string] cast on
            # that takes the current culture along with its calendar — a Buddhist year here, and
            # not merely on the screen: the value is written straight back to the file. The same
            # trap Get-LastMode carries a comment about.
            $seen = $v.seen
            if ($seen -is [datetime]) { $seen = Format-DisplayStamp -When $seen -Pattern 'yyyy-MM-dd' }
            $out[[string]$p.Name] = [pscustomobject]@{
                Label   = [string]$p.Name
                Model   = $(if ($v.model) { [string]$v.model } else { [string]$p.Name })
                ShortId = [string]$v.short
                Id      = [string]$v.id
                Native  = $(if ($w -gt 0 -and $h -gt 0) { [pscustomobject]@{ Width = $w; Height = $h } } else { $null })
                Seen    = [string]$seen
            }
        }
    }
    catch {
        Write-DisplayLog "warn: the list of known displays is unreadable - $($_.Exception.Message)"
        return [ordered]@{}
    }
    return $out
}

# The file's exact text for a roster. One function, because the write and the "would this change
# anything at all" check below have to agree to the byte — comparing the two maps field by field
# is that same comparison written a second time, and the second copy is the one that goes stale.
function Format-KnownDisplays {
    param($Known)

    $flat = [ordered]@{}
    foreach ($name in @($Known.Keys | Sort-Object)) {
        $k = $Known[$name]
        $flat[[string]$name] = [ordered]@{
            model = [string]$k.Model
            short = [string]$k.ShortId
            id    = [string]$k.Id
            w     = $(if ($k.Native) { [int]$k.Native.Width } else { 0 })
            h     = $(if ($k.Native) { [int]$k.Native.Height } else { 0 })
            seen  = [string]$k.Seen
        }
    }
    # An empty map has to come out as a JSON object rather than as PowerShell's "null": the next
    # read would log the file as unreadable, once per window, for ever.
    if ($flat.Count -eq 0) { return '{}' }
    return ($flat | ConvertTo-Json -Depth 4 -Compress)
}

# Write today's desk into the roster and drop whatever has aged out. Answers whether the file was
# touched.
#
# The write is skipped whenever the text would come out unchanged, which on an ordinary day is
# every single time: this runs on every refresh of the tray's state cache — a right-click on the
# icon does one — and a monitor's name, size and short ID do not change while the machine is on.
# The stamp is a DAY for the same reason: at any finer resolution every menu open would rewrite
# the file.
function Update-KnownDisplays {
    param($State)

    $known = Get-KnownDisplays
    $was = Format-KnownDisplays $known
    Set-DisplayIdentity -State $State -Known $known
    $today = Format-DisplayStamp -Pattern 'yyyy-MM-dd'

    $live = @()
    foreach ($m in @($State)) {
        if (-not $m -or -not $m.Label) { continue }
        $live += [string]$m.Label
        # Promotion to an instance label must not leave a third ghost card for the same target.
        foreach ($old in @($known.Keys)) {
            if ($old -ne $m.Label -and $known[$old].Id -eq $m.Id) { $known.Remove($old) }
        }
        $known[[string]$m.Label] = [pscustomobject]@{
            Label   = [string]$m.Label
            Model   = [string]$m.Model
            ShortId = [string]$m.ShortId
            Id      = [string]$m.Id
            Native  = $m.Native
            Seen    = $today
        }
    }

    # Never a monitor the enumeration has just named, whatever its stamp says: a clock set wrong,
    # or a folder copied from another machine, must not throw away a display that is on the desk.
    $cut = (Get-Date).Date.AddDays(-$script:KnownDisplayDays)
    foreach ($name in @($known.Keys)) {
        if ($live -contains [string]$name) { continue }
        $seen = [datetime]::MinValue
        # An unreadable stamp — a record from a version that wrote none — is dropped rather than
        # kept for ever: one appearance of the monitor puts it straight back.
        $ok = [datetime]::TryParseExact([string]$known[$name].Seen, 'yyyy-MM-dd',
                  [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$seen)
        if (-not $ok -or $seen -lt $cut) { $known.Remove([string]$name) }
    }

    $text = Format-KnownDisplays $known
    if ($text -eq $was) { return $false }
    try {
        Set-Content -Path $script:KnownDisplaysFile -Value $text -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch {
        # Nothing was written down, and nothing else is affected: the interface simply offers the
        # monitors Windows can see right now, which is what it did before this file existed.
        Write-DisplayLog "warn: could not remember the displays - $($_.Exception.Message)"
        return $false
    }
}

# The desk as the interface should show it: everything Windows says about it, then the remembered
# monitors it says nothing about at all, in the roster's order.
#
# A remembered one is built with the fields of a state record and not one field more. That is the
# point: the desk cards, the table, the combo ticks, Get-DisplayModes and Get-ModeMembers all
# already know what to do with a display that is not connected — which is what this is — and not
# one of them has to learn a new field to tell the two apart.
function Get-DeskDisplays {
    param($State)

    $out = @(@($State) | Where-Object { $_ })
    $known = Get-KnownDisplays
    Set-DisplayIdentity -State $out -Known $known
    $live = @($out | ForEach-Object { [string]$_.Label })
    foreach ($name in @($known.Keys)) {
        if ($live -contains [string]$name) { continue }
        $k = $known[$name]
        $out += [pscustomobject]@{
            Output       = ''
            Label        = [string]$k.Label
            Model        = [string]$k.Model
            ShortId      = [string]$k.ShortId
            Native       = $k.Native
            Id           = [string]$k.Id
            Active       = $false
            Primary      = $false
            Disconnected = $true
            Width        = 0
            Height       = 0
            Hz           = 0
            X            = 0
            Y            = 0
            Rotation     = 0
            RateNum      = 0
            RateDen      = 0
            BestMode     = $null
        }
    }
    return @($out)
}

# --- modes ------------------------------------------------------------------
# The modes are built out of the current state rather than from a hard-coded list: every monitor
# gets a solo mode of its own by itself, the moment it is connected. A mode's key is stable (the
# selected label), so output numbering never assigns a shortcut to another panel.

function Get-DisplayModes {
    # $Settings is needed for the combos' sake only. The disk is NEVER read here: the tray menu calls
    # this function on every open, and reading the file would cost exactly the delay the state cache
    # was created to avoid. No settings handed in — and there will be no combos in the list; every
    # real caller (the tray, the switcher, the CLI, the Settings window) hands the settings in.
    param($State, $Settings)

    # $null specifically, not "falsy": an empty array is falsy in PowerShell too, and on one this
    # line would go to the system again right inside the menu's Opening handler — which is the very
    # thing the state cache exists for.
    if ($null -eq $State) { $State = @(Get-DisplayState) }
    $modes = @()

    Set-DisplayIdentity -State $State
    foreach ($m in $State) {
        $name = $m.Label

        $modes += [pscustomobject]@{
            Key       = 'solo:' + $name
            # The title is for a person and changes with the language; the KEY is what settings.json,
            # the log and every comparison use, and it never does. Nothing may be looked up by title.
            Title     = (Get-Text -Key 'mode.solo' -Values @((Get-DisplayTitle -Label ([string]$m.Label))))
            Kind      = 'solo'
            Label     = $m.Label
            ShortId   = $m.ShortId
            # Only a live device path can select hardware; a label fingerprint never adds a target
            # that Windows has stopped reporting.
            Id        = $m.Id
            Primary   = $null
            Available = (-not $m.Disconnected)
        }
    }

    # The combos come in the file's order, unsorted: a person chose their order in the Settings
    # window, and rearranging it of our own accord is not our business.
    if ($Settings -and $Settings.combos) {
        foreach ($name in @($Settings.combos.Keys)) {
            $c = $Settings.combos[$name]
            $patterns = @()
            $comboPrimary = ''
            if ($c -is [array]) { $patterns = @($c | ForEach-Object { [string]$_ }) }
            elseif ($c) {
                if ($null -ne $c.displays) { $patterns = @($c.displays | ForEach-Object { [string]$_ }) }
                if ($null -ne $c.primary)  { $comboPrimary = [string]$c.primary }
            }

            # Availability is at least one member on the desk: a combo switches on what is there, like
            # "all". An empty member list honestly gives an unavailable mode — Switch-DisplayMode will
            # say so in words.
            $available = $false
            foreach ($m in $State) {
                if ($m.Disconnected) { continue }
                foreach ($pat in $patterns) {
                    if (Test-DisplayNameMatch -Pattern $pat -Label $m.Label -ShortId $m.ShortId) { $available = $true; break }
                }
                if ($available) { break }
            }

            $modes += [pscustomobject]@{
                Key       = 'combo:' + $name
                Title     = [string]$name
                Kind      = 'combo'
                Patterns  = $patterns
                Primary   = $comboPrimary
                Available = $available
            }
        }
    }

    $modes += [pscustomobject]@{
        Key       = 'all'
        Title     = (Get-Text -Key 'mode.all')
        Kind      = 'all'
        Primary   = $null
        Available = (@($State | Where-Object { -not $_.Disconnected }).Count -gt 0)
    }

    return $modes
}

# A mode's title from its key alone, without querying the state. Needed for bindings to monitors
# that are not in the system right now: no such mode appears in Get-DisplayModes, and it still has to
# be shown in the settings. There is nowhere to get the monitor's model from, so the short Monitor ID
# is what stays in the title.
function Get-ModeTitleFromKey {
    param([Parameter(Mandatory)][string]$Key)

    switch -Regex ($Key) {
        '^solo:(.+)$'  { return (Get-Text -Key 'mode.solo' -Values @((Get-DisplayTitle -Label $Matches[1]))) }
        '^combo:(.+)$' { return $Matches[1] }
        '^all$'        { return (Get-Text -Key 'mode.all') }
        default        { return $Key }
    }
}

# Moving the bindings from old keys to new ones. A solo mode written down by short Monitor ID loses
# its key when the monitor moves to another input. If such a key matches the ID of a connected
# monitor, the binding moves to the name-based key — by itself, with no person involved. Returns
# $true if anything changed (and then the settings have to be saved).
function Update-HotkeyKeys {
    param($Settings, $State)

    if (-not $Settings) { return $false }

    # A mode can own brightness, commands or a rule without owning a shortcut. Collect every
    # reference before renaming anything, or tray-only preferences would be orphaned on upgrade.
    $fields = @('hotkeys', 'audio', 'hooks', 'brightness', 'contrast', 'picture', 'hdr')
    $references = [ordered]@{}
    foreach ($field in $fields) {
        $dict = $Settings[$field]
        if (-not $dict) { continue }
        foreach ($key in @($dict.Keys)) { $references[[string]$key] = $true }
    }
    foreach ($rule in @($Settings.rules)) {
        if (-not $rule) { continue }
        foreach ($field in @('mode', 'back')) {
            if ($rule[$field]) { $references[[string]$rule[$field]] = $true }
        }
    }
    if ($Settings.reapply -and $Settings.reapply.onPlug) {
        $references[[string]$Settings.reapply.onPlug] = $true
    }
    if ($references.Count -eq 0) { return $false }

    $modes = @(Get-DisplayModes -State $State)
    $live = @($modes | ForEach-Object { $_.Key })
    $changed = $false

    foreach ($old in @($references.Keys)) {
        if ($old -notlike 'solo:*') { continue }
        if ($live -contains $old) { continue }

        $id = $old.Substring(5)
        # Instance keys cannot migrate by model: the matching model may be the other panel.
        if ($id -match ' \{[a-f0-9]{16}\}$| #\d+$') { continue }
        $candidates = @($modes | Where-Object { $_.Kind -eq 'solo' -and $_.ShortId -eq $id -and $_.Label -notmatch ' \{[a-f0-9]{16}\}$' })
        $hit = $null
        if ($candidates.Count -eq 1) { $hit = $candidates[0] }
        if (-not $hit) {
            $candidates = @($State | Where-Object { $id -eq ($_.Model + ' ' + $_.ShortId) })
            if ($candidates.Count -eq 1) {
                $hit = $modes | Where-Object { $_.Kind -eq 'solo' -and $_.Id -eq $candidates[0].Id } | Select-Object -First 1
            }
        }

        # A monitor's name can change too — from the full "ROG STRIX XG27AQDMGR" to the short
        # "XG27AQDMGR", for instance. One is contained in the other, and that is enough to recognise
        # the monitor and carry the binding over.
        if (-not $hit) {
            $candidates = @($modes | Where-Object {
                $_.Kind -eq 'solo' -and $_.Label -notmatch ' \{[a-f0-9]{16}\}$' -and
                (Test-DisplayNameMatch -Pattern $id -Label $_.Label -ShortId '')
            })
            if ($candidates.Count -eq 1) { $hit = $candidates[0] }
        }
        if (-not $hit) { continue }
        # A chosen target value wins within its own map. Its conflict must not block unrelated
        # preferences or rules, and the old conflicting value stays available for manual editing.
        $migrated = $false
        foreach ($field in $fields) {
            $dict = $Settings[$field]
            if (-not $dict -or -not $dict.Contains($old)) { continue }
            if ($dict.Contains($hit.Key)) { continue }
            $dict[$hit.Key] = $dict[$old]
            $dict.Remove($old)
            $migrated = $true
        }
        foreach ($rule in @($Settings.rules)) {
            if (-not $rule) { continue }
            foreach ($field in @('mode', 'back')) {
                if ([string]$rule[$field] -eq $old) {
                    $rule[$field] = [string]$hit.Key
                    $migrated = $true
                }
            }
        }
        if ($Settings.reapply -and [string]$Settings.reapply.onPlug -eq $old) {
            $Settings.reapply.onPlug = [string]$hit.Key
            $migrated = $true
        }
        if ($migrated) {
            Write-DisplayLog "settings: moved mode references from '$old' to '$($hit.Key)'"
            $changed = $true
        }
    }
    return $changed
}

function Get-ModeMembers {
    param($Mode, $State)

    $usable = @($State | Where-Object { -not $_.Disconnected })
    switch ($Mode.Kind) {
        'all'  { return $usable }
        # By the full Monitor ID and not the short one: the short one is the model, and for two
        # identical monitors it is one between them.
        'solo' { return @($usable | Where-Object { $_.Id -eq $Mode.Id }) }
        # A combo member is a monitor that at least one of its patterns fitted. Loops rather than a
        # pipeline: a nested Where-Object with two $_ reads worse than what it does.
        'combo' {
            $members = @()
            foreach ($m in $usable) {
                foreach ($pat in @($Mode.Patterns)) {
                    if (Test-DisplayNameMatch -Pattern $pat -Label $m.Label -ShortId $m.ShortId) {
                        $members += $m
                        break
                    }
                }
            }
            return $members
        }
    }
    return @()
}

# A monitor's name by device path — for the log.
#
# Created for the sake of the "plug:" lines: without the names, the log shows which branch fired but
# not what set it off, and working it out runs into guesswork.
#
# Two roads, and the second one is mandatory. A monitor that fell asleep is usually still in the
# state, marked Disconnected. But when the driver takes it off the bus altogether — and that is
# exactly what "the monitor went out by itself" looks like, which Windows writes down as "surprise
# removed as it is reported as missing on the bus" — it is not in the enumeration either. Asking the
# state for a name at that moment is already too late, so $Known is what was seen earlier: path ->
# name. Without it the line about a disappearance would call it "a display" in exactly the case it
# was written for.
function Get-DisplayLabelById {
    param([string]$Id, $State, $Known = $null)

    $one = @($State | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if ($one -and $one.Label) { return [string]$one.Label }
    if ($Known -and $Known.Contains($Id) -and $Known[$Id]) { return [string]$Known[$Id] }
    # And a third road. On 31 August both of the two above came up empty and the log wrote the nameless
    # "a display" about the ASUS leaving the bus: in that build the map was filled from Write-DeskSnapshot,
    # which runs only on a configuration change and reads the cache AFTER the refresh, so on the first
    # event of a run it was still empty. That is cured where it belongs (the map is filled in
    # Update-StateCache now), and this road is what remains: the path IS the identifier, and the monitor's
    # own id sits inside it. Not the human name, but this function's job is that the log never says
    # "somebody", and it must not depend on somebody else's map being filled in time.
    $short = Get-MonitorIdFromPath -Id $Id
    if ($short) { return $short }
    return 'a display'
}

# The monitor's id out of a CCD device path: \\?\DISPLAY#GSM5BB3#5&2a1f...#{guid} -> GSM5BB3. An empty
# string for a path of any other shape: inventing a name out of nothing is worse than admitting there is
# none. A pure function, and therefore under tests.
function Get-MonitorIdFromPath {
    param([string]$Id)

    if ([string]$Id -match '(?i)DISPLAY#([^#\\]+)#') { return [string]$Matches[1] }
    return ''
}

# The whole desk in one line — for the log, on every configuration change.
#
# On 28 August the log said "a display went away" and did not say WHICH, and said nothing about the
# others. Working it out went on inferring that indirectly — from which branch had fired. This line
# answers straight away and in full.
#
# Three states, and they are not about the same thing:
#   gone — the monitor is not on the bus: it fell asleep on its own button, the cable was pulled, or
#          the driver took it off as "missing on the bus";
#   off  — connected, but showing no picture (which is how we switch it off);
#   on   — showing, and in what mode.
function Format-DeskSnapshot {
    param($State)

    $parts = @()
    # Where-Object, not a bare @($State): @($null) is an array of ONE $null, so a state that could not be
    # read would walk the loop once with $m = $null, fall through to "-not $m.Active" and log a nameless
    # " off" — a phantom monitor at exactly the moment the query broke. And $null is what arrives here: a
    # throw inside Update-StateCache leaves the cache unset, and a stored @() comes back as $null anyway,
    # because returning an empty array from a function emits nothing.
    foreach ($m in @($State | Where-Object { $_ })) {
        $label = [string]$m.Label
        if ($m.Disconnected)  { $parts += ('{0} gone' -f $label); continue }
        if (-not $m.Active)   { $parts += ('{0} off' -f $label); continue }
        $parts += ('{0} on {1}x{2}@{3}' -f $label, [int]$m.Width, [int]$m.Height, [int]$m.Hz)
    }
    if ($parts.Count -eq 0) { return 'nothing at all' }
    return ($parts -join ', ')
}

# Whether exactly this set of screens is already standing on the desk. We compare SETS and not mode
# keys: while one monitor is not plugged in, "all" and "work" are one and the same desk, and comparing
# keys would declare a switch out of something that is not happening. It is also how the tray learns
# that the layout is all that might need fixing and no balloon is needed. One definition of "the desk
# equals the mode" for the whole application: two of them would drift apart.
function Test-DeskMatchesMode {
    param($Mode, $State)

    $wanted = @(Get-ModeMembers -Mode $Mode -State $State | ForEach-Object { $_.Id } | Sort-Object)
    $on = @($State | Where-Object { $_.Active } | ForEach-Object { $_.Id } | Sort-Object)
    return ($wanted.Count -eq $on.Count -and -not (Compare-Object $wanted $on))
}

# Which mode matches what is switched on right now. Needed to tick the current state in the menu.
function Get-ActiveModeKey {
    param($State, $Modes)

    # A desk that has gone out equals no mode at all, and that has to be checked BEFORE the pass: a
    # mode not one of whose monitors is connected has an empty set too, and comparing sets would
    # declare it the current one.
    if (@($State | Where-Object { $_.Active }).Count -eq 0) { return $null }

    foreach ($mode in $Modes) {
        if (Test-DeskMatchesMode -Mode $mode -State $State) {
            return $mode.Key
        }
    }
    return $null
}

# --- switching --------------------------------------------------------------

# The switch summary and the "success or not" verdict, in one place. The tray picks between a green
# balloon and a yellow one by Ok, the CLI picks its exit code by it, so everything that went wrong has
# to reach both the text and Ok. A pure function: assembling the text has lied twice already (a monitor
# dropped out of the summary, a refusal to switch off got lost), and each case was fixed by feel — now
# it is covered by tests.
#
# A refusal to switch off is said straight out in the summary: otherwise the result is a report of
# success while more screens are left on the desk than were asked for. A layout failure goes the same
# way: if it is only visible in the log, the tray reports a green "Displays switched" and the person
# discovers the muddled monitors themselves.
function Format-SwitchResult {
    param(
        [string[]]$Summary = @(),
        [string[]]$Failed = @(),
        [string[]]$Refused = @(),
        [bool]$LayoutFailed = $false,
        [bool]$RestoreFailed = $false
    )

    # Twice over, in the person's language and in English: this verdict is both the balloon a person
    # reads and the done: line in the log, and the log stays English (see Get-Text).
    $said = [ordered]@{}
    foreach ($lang in '', $script:LangFallback) {
        $text = (@($Summary) -join ', ')
        $parts = @()
        if (@($Failed).Count -gt 0) {
            $parts += (Get-Text -Key 'verdict.failed' -Values @((@($Failed) -join ', ')) -Language $lang)
        }
        if (@($Refused).Count -gt 0) {
            $parts += (Get-Text -Key 'verdict.refused' -Values @((@($Refused) -join ', ')) -Language $lang)
        }
        if ($LayoutFailed) {
            $parts += (Get-Text -Key 'verdict.layout' -Language $lang)
        }
        if ($RestoreFailed) {
            $parts += (Get-Text -Key 'verdict.restore' -Language $lang)
        }
        foreach ($p in $parts) {
            $text = $(if ($text) { $text + '. ' + $p } else { $p })
        }
        $said[$lang] = $text
    }
    return [pscustomobject]@{
        Text = $said['']
        Log  = $said[$script:LangFallback]
        Ok   = (@($Failed).Count -eq 0 -and @($Refused).Count -eq 0 -and
                -not $LayoutFailed -and -not $RestoreFailed)
    }
}

# Every answer a switch can give, in one shape, because for a while there was no shape at all: the
# result carried Skipped and Ok and no word on whether the answer was temporary, and the two callers in
# the tray each read the pieces and derived OPPOSITE retry policies out of them. The way back from a rule
# let the desk go on any failure and left a person on the game display for good; the postponed rebuild,
# reading the other field, threw its intent away when a monitor had not woken yet and put it back when
# Windows had refused outright — a warning balloon every fifteen seconds, for good as well. Whoever
# changes the policy now has one place to change it in.
#
# Two fields decide what a caller does next:
#
#   Ok    - the desk IS in the requested mode now. Nothing else means that: a switch that came to
#           nothing ran to the end, has a summary and a duration, and is still not a success.
#   Retry - asking again in a moment can change this answer. A busy mutex clears in about a second (the
#           refresh-rate watchdog holds it after every switch — including ours), and a display still
#           waking up attaches a moment later. Windows refusing the whole configuration, or a mode that
#           is no longer in the settings, will not come right by being asked again.
#
# Outcome is the same answer as a word, for the log and for the caller that has to tell "we never
# started" from "we tried and the screen stayed dark":
#
#   done    - everything landed.
#   partial - it ran, and something did not: a display that never came up, a layout Windows refused.
#   busy    - another switch is in progress; this one did not start.
#   dryrun  - nothing was touched on purpose.
#   refused - the switch threw. Built by the caller that catches it (see New-SwitchFailure), so that a
#             failure speaks the same vocabulary as a success.
function New-SwitchResult {
    param(
        # AllowEmptyString for the tray's starting value: "no switch in this run yet" names no mode.
        [Parameter(Mandatory)][AllowEmptyString()][string]$ModeKey,
        [Parameter(Mandatory)][ValidateSet('done', 'partial', 'busy', 'dryrun', 'refused')][string]$Outcome,
        [string]$Message = '',
        [string[]]$Refused = @(),
        [string[]]$Failed = @(),
        [double]$Seconds = 0
    )

    return [pscustomobject]@{
        Mode    = $ModeKey
        Outcome = $Outcome
        # Kept as a field of its own because the command line prints it differently and exits 2 by it.
        Skipped = ($Outcome -eq 'busy')
        Ok      = ($Outcome -eq 'done' -or $Outcome -eq 'dryrun')
        Retry   = ($Outcome -eq 'busy' -or $Outcome -eq 'partial')
        Message = $Message
        Refused = @($Refused)
        Failed  = @($Failed)
        Seconds = $Seconds
    }
}

# A switch that threw, in the same shape as one that did not. For the tray: Switch-DisplayMode reports a
# refusal by throwing — the message is written for a person and belongs in a balloon — and the caller
# that catches it still has to tell the rules and the postponed rebuild what happened.
function New-SwitchFailure {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ModeKey, [string]$Message = '')
    return (New-SwitchResult -ModeKey $ModeKey -Outcome 'refused' -Message $Message)
}

# The per-phase time breakdown for the log: 'state 0.3, apply 1.2'. It answers the question "whose
# second is this": state and layout are our own work, while apply, settle and modes are mostly waiting
# on the system and the monitors. Phases shorter than 0.05 s are dropped: the zeroes would only hide
# what matters. The order is the dictionary's order; the seconds go through InvariantCulture, for the
# same reason as in done:.
function Format-PhaseTimes {
    param($Phases)

    if (-not $Phases) { return '' }
    $parts = @()
    foreach ($name in @($Phases.Keys)) {
        $s = [double]$Phases[$name]
        if ($s -lt 0.05) { continue }
        $parts += ('{0} {1}' -f $name, $s.ToString('0.0', [cultureinfo]::InvariantCulture))
    }
    return ($parts -join ', ')
}

# Which of the monitors being switched on becomes the primary (that is, where the taskbar goes).
# Lifted out of Switch-DisplayMode as a pure function: a six-rung ladder inside the switcher was
# untestable.
#
# The rungs, top to bottom, the first one found wins:
#   1. -PrimaryMatch from the command line — HARD: it matched nobody, which means the person made a
#      typo, and silently substituting our own choice for theirs is not allowed — it is an error.
#   2. the mode's own primary (for combos) — soft: that monitor may not be on the desk, and the combo
#      has to work without it.
#   3. the primary from the settings — soft, for the same reason.
#   4. whoever is primary right now, if they are among those being switched on: do not move it without need.
#   5. the rightmost by layout: a desk has a "main" side.
#   6. the first one that comes to hand.
function Select-PrimaryDisplay {
    param(
        $Wanted,
        [string]$PrimaryMatch,
        [string]$ModePrimary,
        [string]$SettingsPrimary,
        $Layout,
        [string]$ModeTitle = ''
    )

    $wanted = @($Wanted)

    if ($PrimaryMatch) {
        $hit = @($wanted | Where-Object { $_.Label -match [regex]::Escape($PrimaryMatch) })
        if ($hit.Count -gt 1) { throw ("-PrimaryMatch '$PrimaryMatch' matches several displays. Use the full instance label.") }
        if (-not $hit) {
            $where = $(if ($ModeTitle) { "in '$ModeTitle'" } else { 'that are being turned on' })
            throw "-PrimaryMatch '$PrimaryMatch' matched none of the displays $where."
        }
        return $hit[0]
    }

    foreach ($soft in @($ModePrimary, $SettingsPrimary)) {
        if (-not $soft) { continue }
        $hit = @($wanted | Where-Object { Test-DisplayNameMatch -Pattern $soft -Label $_.Label -ShortId $_.ShortId })
        if ($hit.Count -eq 1) { return $hit[0] }
    }

    $hit = $wanted | Where-Object { $_.Primary } | Select-Object -First 1
    if ($hit) { return $hit }

    $order = @($Layout)
    for ($k = $order.Count - 1; $k -ge 0; $k--) {
        $hit = $wanted | Where-Object { Test-DisplayNameMatch -Pattern $order[$k] -Label $_.Label -ShortId $_.ShortId } | Select-Object -First 1
        if ($hit) { return $hit }
    }

    return ($wanted | Select-Object -First 1)
}

# Whether all these monitors already stand in their best modes. A pure function: it looks only at
# the state taken on the way into a switch and asks the system nothing.
function Test-ModesAlreadyBest {
    param($Wanted)

    foreach ($m in @($Wanted)) {
        if (-not $m.Active -or -not $m.Output -or -not $m.BestMode) { return $false }
        if ($m.Width -ne $m.BestMode.Width -or $m.Height -ne $m.BestMode.Height -or
            $m.Hz -ne $m.BestMode.Hz) { return $false }
    }
    return $true
}

# Bring the modes of the monitors we need up to scratch and put together a report on them:
#   Summary       lines like "LG ULTRAGEAR 2560x1440 @ 144 Hz" for the summary shown to a person;
#   Failed        the names of those that never attached;
#   Applied       device path -> what the monitor really shows;
#   LevelTargets  who to set brightness on afterwards, with the output name already known —
#                 a CCD walk costs tens of milliseconds, and it is not needed a second time
#                 within one switch.
#
# Two roads. The short one (-AlreadyBest) is for when the desk did not move and every monitor is
# already in its best mode: the summary is put together from the state taken on the way in, and not
# one request goes to the system. The saving is not cosmetic: right after a layout change the driver
# answers questions about modes noticeably more slowly, and a second press a second after a switch
# costs twice what it does at rest.
function Set-WantedModes {
    param(
        [Parameter(Mandatory)]$Wanted,
        [switch]$AlreadyBest,
        [switch]$KeepMode
    )

    $summary = @()
    $failed = @()
    $applied = @{}
    $levelTargets = @()

    if ($AlreadyBest) {
        foreach ($m in @($Wanted)) {
            $summary += '{0} {1}x{2} @ {3} Hz' -f $m.Label, $m.Width, $m.Height, $m.Hz
            $applied[[string]$m.Id] = [pscustomobject]@{ Width = $m.Width; Height = $m.Height; Hz = $m.Hz }
            $levelTargets += [pscustomobject]@{ Device = [string]$m.Output; Label = [string]$m.Label; ShortId = [string]$m.ShortId }
        }
        Write-DisplayLog 'switch: modes already correct'
    }
    else {
        # The mode is set last, once the set of active monitors is already final: both assigning the
        # primary and putting a neighbour out reset the refresh rate to whatever is written in the
        # registry, and there it is often below the native one.
        #
        # The output names are taken in ONE enumeration for everybody rather than one per monitor:
        # Get-CcdOutput calls Get-CcdTargets inside (a full CCD walk with a name query, ~50 ms), and
        # on three monitors that is three times the cost for no reason at all. Whoever is already on
        # the desk will be found here; whoever is still waking will go to Get-CcdOutput and be waited
        # for honestly.
        $outputs = @{}
        foreach ($t in @(Get-CcdTargets)) {
            if ($t.Active -and $t.Output) { $outputs[$t.DevicePath] = $t.Output }
        }

        foreach ($m in @($Wanted)) {
            $output = $outputs[$m.Id]
            if (-not $output) { $output = Get-CcdOutput -DevicePath $m.Id }
            if (-not $output) {
                # Skipping silently is not allowed: the monitor would vanish from the summary, and the
                # result would be a report of success with a black screen.
                Write-DisplayLog "warn: $($m.Label) did not attach within 8 s - mode was not applied"
                $failed += $m.Label
                continue
            }
            if (-not $KeepMode) {
                $nw = 0; $nh = 0
                if ($m.Native) { $nw = $m.Native.Width; $nh = $m.Native.Height }
                # $m.BestMode was worked out in Get-DisplayState on the way in — for a monitor that
                # was already on it is ready, and a pass over the modes (expensive right after a
                # topology change) is not needed. For one that has just woken it is $null, and
                # Set-BestModeFor will work it out itself.
                [void](Set-BestModeFor -Output $output -Label $m.Label -NativeWidth $nw -NativeHeight $nh -Best $m.BestMode)
            }
            $levelTargets += [pscustomobject]@{ Device = [string]$output; Label = [string]$m.Label; ShortId = [string]$m.ShortId }
            $cur = Get-CurrentMode $output
            $summary += $(if ($cur) { '{0} {1}x{2} @ {3} Hz' -f $m.Label, $cur.Width, $cur.Height, $cur.Hz } else { $m.Label })
            if ($cur -and $cur.Width -gt 0) {
                $applied[[string]$m.Id] = [pscustomobject]@{ Width = $cur.Width; Height = $cur.Height; Hz = $cur.Hz }
            }
        }
    }

    return [pscustomobject]@{
        Summary = @($summary); Failed = @($failed)
        Applied = $applied;    LevelTargets = @($levelTargets)
    }
}

# Remember what the monitors really showed in the cache of verified modes: the next switch will be
# able to set the refresh rate straight away, without waiting for a sleeping monitor to wake up and
# tell us about itself.
#
# The exact fraction of the refresh rate is taken from CCD: whole hertz are not enough to request a
# mode (see Get-ModeCache), and one walk over the active paths costs single-digit milliseconds.
function Save-AppliedModes {
    param($Applied)

    if (-not $Applied -or @($Applied.Keys).Count -eq 0) { return }

    $rates = Get-CcdActiveRates
    foreach ($k in @($Applied.Keys)) {
        $r = $rates[$k]
        $Applied[$k] | Add-Member -NotePropertyName RateNum -NotePropertyValue $(if ($r) { $r.Num } else { 0 }) -Force
        $Applied[$k] | Add-Member -NotePropertyName RateDen -NotePropertyValue $(if ($r) { $r.Den } else { 0 }) -Force
    }
    Save-ModeCache -Modes $Applied
}

# The tail of a switch: what is done AFTER the desk is assembled and therefore does not land in the
# done: line — window positions, audio, brightness and the "after" command.
#
# An after: line of its own: in the log done: means "the desk is assembled", while brightness over
# DDC is still being brought up for seconds afterwards, and without this line its time would look
# like a hole between done: and the next entry. There is no line at all when the tail is unnoticeable.
#
# The order here is deliberate. The windows come after the mode change and the primary assignment:
# both of those move windows themselves, so arranging them earlier is pointless. The audio and the
# brightness come after the mode has actually happened: there is no reason to shuffle devices about
# if the switch failed. The "after" command comes at the very end — that is what it is for, to catch
# a finished state.
function Invoke-SwitchTail {
    param(
        $Settings,
        [Parameter(Mandatory)][string]$ModeKey,
        # The topology really did change AND window snapshots are on. On a repeat press of the
        # shortcut we do not touch the windows at all.
        [bool]$RestoreWindows,
        [string[]]$WantedIds = @(),
        # The monitors that brightness can be set on: the output name is already known, and a second
        # CCD walk within one switch is not needed.
        $LevelTargets = @()
    )

    $tail = [ordered]@{}
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $note = {
        param([string]$Name)
        $tail[$Name] = [double]$tail[$Name] + $watch.Elapsed.TotalSeconds
        $watch.Restart()
    }

    if ($RestoreWindows) {
        try { Restore-WindowLayout -Key (Get-DisplayLayoutKey -DevicePaths $WantedIds) }
        catch { Write-DisplayLog "warn: windows - restoring failed: $($_.Exception.Message)" }
    }
    & $note 'windows'

    # The dictionary is empty (by default) — not one line is executed.
    if ($Settings.audio -and $Settings.audio.Contains($ModeKey)) {
        $want = [string]$Settings.audio[$ModeKey]
        if ($want) {
            try { [void](Set-DefaultAudioDevice -Match $want) }
            catch { Write-DisplayLog "warn: audio - failed: $($_.Exception.Message)" }
        }
    }
    & $note 'audio'

    # Only for the monitors that are on: a sleeping one does not answer over DDC. The dictionaries are
    # empty (by default) — and not one request leaves over the slow bus.
    $hasLevels = (($Settings.brightness -and $Settings.brightness.Contains($ModeKey)) -or
                  ($Settings.contrast -and $Settings.contrast.Contains($ModeKey)) -or
                  ($Settings.picture -and $Settings.picture.Contains($ModeKey)))
    if ($hasLevels -and @($LevelTargets).Count -gt 0) {
        $b = $(if ($Settings.brightness -and $Settings.brightness.Contains($ModeKey)) { $Settings.brightness[$ModeKey] } else { $null })
        $c = $(if ($Settings.contrast   -and $Settings.contrast.Contains($ModeKey))   { $Settings.contrast[$ModeKey] }   else { $null })
        $p = $(if ($Settings.picture    -and $Settings.picture.Contains($ModeKey))    { $Settings.picture[$ModeKey] }    else { $null })
        try { [void](Set-MonitorLevels -Targets $LevelTargets -BrightnessSetting $b -ContrastSetting $c -PictureSetting $p) }
        catch { Write-DisplayLog "warn: levels - failed: $($_.Exception.Message)" }
    }
    & $note 'levels'

    # HDR by the same rule: nothing in the dictionary, nothing asked of the system. Not over DDC - this
    # is Windows' own switch, and it answers in a millisecond.
    if ($Settings.hdr -and $Settings.hdr.Contains($ModeKey) -and @($LevelTargets).Count -gt 0) {
        try { [void](Set-ModeHdr -Setting $Settings.hdr[$ModeKey] -Targets $LevelTargets) }
        catch { Write-DisplayLog "warn: hdr - failed: $($_.Exception.Message)" }
    }
    & $note 'hdr'

    [void](Invoke-ModeHook -Settings $Settings -ModeKey $ModeKey -Phase 'after')
    & $note 'hook'

    $text = Format-PhaseTimes $tail
    if ($text) { Write-DisplayLog ("after: {0} s" -f $text) }
}

function Switch-DisplayMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModeKey,
        [string]$PrimaryMatch,
        [switch]$KeepMode,
        [switch]$DryRun,
        [switch]$Quiet,
        # The switch was our own idea and not a person's: the watchdog, a rule, assembling the desk
        # after sleep or after a monitor went away. It differs in exactly one thing — a switch like
        # that does not overwrite the chosen mode (see Save-LastMode below).
        [switch]$Automatic
    )

    # One switcher at a time. Without this, two quick presses started two processes that cut across
    # each other: one was switching a monitor on while the other was changing its mode at the same
    # moment — and the result became unpredictable.
    $mutex = New-Object System.Threading.Mutex($false, 'Local\DeskModesSwitch')
    # WaitOne can THROW and hand us the mutex in the same breath: a previous holder that died without
    # letting go raises AbandonedMutexException, and ownership passes to us all the same. Outside a try
    # that meant an owned mutex nobody ever released, and in the tray — a process that lives for weeks —
    # every switch after it would answer "a switch is already in progress" for good.
    $held = $false
    try { $held = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] {
        $held = $true
        Write-DisplayLog 'warn: the previous switch died without letting go of the lock - taking it over'
    }
    if (-not $held) {
        Write-DisplayLog "skip: mode=$ModeKey - the previous switch has not finished yet"
        if (-not $Quiet) { Write-Host 'A switch is already in progress - skipping.' -ForegroundColor Yellow }
        # Dispose is required here too: in the tray the process lives for weeks, and every skipped
        # switch used to leave a kernel handle behind it.
        $mutex.Dispose()
        return (New-SwitchResult -ModeKey $ModeKey -Outcome 'busy' -Message (Get-Text -Key 'switch.busy'))
    }

    # A switch's duration is written into the final done: and stays there forever. Three lines of code
    # give a permanent watch on speed regressions right in the log: working out "it got slower" with
    # no figures for the past weeks is impossible.
    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    # The second stopwatch is per-phase, for that same done: line. The overall figure says "6
    # seconds", the breakdown says WHERE they went: in our own requests or in waiting for a monitor.
    # The script block writes into the dictionary it is handed, because there are two dictionaries: the
    # phases before done: and the tail after it (see $tail below).
    $phases = [ordered]@{}
    $phaseWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $notePhase = {
        param($Into, [string]$Name)
        $Into[$Name] = [double]$Into[$Name] + $phaseWatch.Elapsed.TotalSeconds
        $phaseWatch.Restart()
    }

    # Declared here rather than only where they are assigned: both are set only on the "the topology
    # changed" branch, while they are read unconditionally below. In that case PowerShell looks for the
    # variable in the caller's scope — and would one day have found somebody else's, after which the
    # summary would have lied about "Still on:".
    $refused = @()
    $doWindows = $false

    try {
        Write-DisplayLog "--- start mode=$ModeKey primaryMatch='$PrimaryMatch' keepMode=$KeepMode dryRun=$DryRun"

        # The settings are read EXACTLY once per switch: otherwise different versions of the file can
        # be picked up within one transition, if it is being edited from the Settings window right now.
        $settings = Get-DisplaySettings

        # The settings have already been read — we hand them to the modes so they do not go to disk
        # themselves.
        $monitors = @(Get-DisplayState)
        $modes = Get-DisplayModes -State $monitors -Settings $settings
        $mode = $modes | Where-Object { $_.Key -eq $ModeKey } | Select-Object -First 1
        if (-not $mode) {
            # A shortcut can be assigned to a monitor that is not plugged in right now — that is a
            # normal situation and not a breakage, and it has to be said in human terms.
            if ($ModeKey -like 'solo:*') {
                throw (New-DisplayRefusal -Key 'switch.notConnected')
            }
            # The combo could have been deleted in the settings while the shortcut stayed.
            if ($ModeKey -like 'combo:*') {
                throw (New-DisplayRefusal -Key 'switch.noCombo' -Values @((Get-ModeTitleFromKey $ModeKey)))
            }
            throw (New-DisplayRefusal -Key 'switch.unknownMode' -Values @($ModeKey))
        }

        $usable = @($monitors | Where-Object { -not $_.Disconnected })
        $wanted = @(Get-ModeMembers -Mode $mode -State $monitors)

        if ($wanted.Count -eq 0) {
            throw (New-DisplayRefusal -Key 'switch.noMembers' -Values @($mode.Title) -LogValues @($mode.Key))
        }

        $wantedIds = @($wanted | ForEach-Object { $_.Id })
        $toDisable = @($usable | Where-Object { $wantedIds -notcontains $_.Id })

        $activeNow = @($monitors | Where-Object { $_.Active } | ForEach-Object { $_.Id } | Sort-Object)
        $wantedSorted = @($wantedIds | Sort-Object)
        $sameTopology = ($activeNow.Count -eq $wantedSorted.Count -and
                         -not (Compare-Object $activeNow $wantedSorted))

        # Capture the complete physical source desk before any command or Windows call can change it. A
        # pending key means an earlier exact restore did not reach verified success (or the process died
        # during it); that observed destination must not replace the good baseline on the next run.
        $desktopStore = Read-DesktopSnapshotStore
        $destinationKey = Get-DesktopSetKey -DevicePaths $wantedIds
        $currentSnapshot = New-DesktopSnapshot -State $monitors
        $destinationSnapshot = $desktopStore.Snapshots[$destinationKey]
        $hadDestinationSnapshot = ($null -ne $destinationSnapshot)
        $usingProtectedSnapshot = ($Automatic -and $desktopStore.ProtectedKey -eq $destinationKey -and
            -not $desktopStore.UnsafeKeys.ContainsKey($destinationKey) -and
            $desktopStore.ProtectedSnapshot -and $desktopStore.ProtectedSnapshot.Key -eq $destinationKey)
        if ($usingProtectedSnapshot) { $destinationSnapshot = $desktopStore.ProtectedSnapshot }
        $storeDirty = $false
        $currentSnapshotTrusted = ($currentSnapshot -and
            $desktopStore.PendingKey -ne $currentSnapshot.Key -and
            -not $desktopStore.UnsafeKeys.ContainsKey($currentSnapshot.Key))
        if ($currentSnapshot) {
            if ($currentSnapshot.Key -ne $destinationKey) {
                if ($currentSnapshotTrusted) {
                    $desktopStore.Snapshots[$currentSnapshot.Key] = $currentSnapshot
                    $storeDirty = $true
                }
            }
            elseif (-not $destinationSnapshot -and $currentSnapshotTrusted) {
                # The first All press on an already complete desk establishes the live arrangement as the
                # baseline. It then becomes an exact no-op instead of applying legacy incidental settings.
                $desktopStore.Snapshots[$currentSnapshot.Key] = $currentSnapshot
                $destinationSnapshot = $currentSnapshot
                $storeDirty = $true
            }
            elseif (-not $Automatic -and $desktopStore.PendingKey -ne $destinationKey -and
                    -not $desktopStore.UnsafeKeys.ContainsKey($destinationKey) -and
                    -not $PrimaryMatch -and -not [string]$mode.Primary -and
                    -not $settings.layoutOverride -and -not $settings.primaryOverride) {
                # A person's repeat press on the set already in front of them adopts the complete live
                # geometry. This makes All idempotent after a deliberate Windows rearrangement. Automatic
                # reapply keeps using the baseline instead, which is what repairs drift after wake.
                $desktopStore.Snapshots[$currentSnapshot.Key] = $currentSnapshot
                $destinationSnapshot = $currentSnapshot
                $storeDirty = $true
            }
        }
        if (-not $destinationSnapshot) {
            $destinationSnapshot = New-DesktopSubsetSnapshot -Wanted $wanted `
                -CurrentSnapshot $(if ($currentSnapshotTrusted) { $currentSnapshot } else { $null }) `
                -Store $desktopStore
        }

        # The whole ladder of the choice is in Select-PrimaryDisplay (and in its tests). Combos have a
        # primary of their own — it is gentler than -PrimaryMatch: that one a person types right now and
        # a typo has to be an error, whereas a combo's primary was written down once, and that monitor
        # not being on the desk is no reason to bring the whole mode down.
        $snapshotPrimary = ''
        if ($destinationSnapshot) {
            $snapshotPrimary = [string](@($wanted | Where-Object {
                $_.Id -eq [string]$destinationSnapshot.PrimaryId }) | Select-Object -First 1).Label
        }
        $settingsPrimary = $(if ($settings.primaryOverride) { [string]$settings.primary } else { $snapshotPrimary })
        $selectionLayout = $(if ($destinationSnapshot -and -not $settings.layoutOverride) { @() } else { @($settings.layout) })
        $primary = Select-PrimaryDisplay -Wanted $wanted -PrimaryMatch $PrimaryMatch `
                                         -ModePrimary ([string]$mode.Primary) `
                                         -SettingsPrimary $settingsPrimary `
                                         -Layout $selectionLayout -ModeTitle $mode.Title
        $restorePlan = $null
        if ($destinationSnapshot) {
            $restorePlan = New-DesktopRestorePlan -Snapshot $destinationSnapshot -Wanted $wanted `
                -PrimaryPath ([string]$primary.Id) -Order @($settings.layout) `
                -UseConfiguredLayout:([bool]$settings.layoutOverride) -KeepMode:$KeepMode
            if (-not $restorePlan) {
                throw (New-DisplayRefusal -Key 'switch.refused' -Values @($mode.Title) -LogValues @($mode.Key))
            }
        }
        $exactAlready = ($restorePlan -and $currentSnapshot -and
                         (Test-DesktopSnapshotMatch -Snapshot $restorePlan.Expected -State $monitors))

        if (-not $DryRun) {
            $willChangeDesktop = (-not $exactAlready)
            if ($willChangeDesktop -and -not $currentSnapshot -and
                -not $desktopStore.Snapshots[(Get-DesktopSetKey -DevicePaths $activeNow)]) {
                throw (New-DisplayRefusal -Key 'switch.snapshotWriteFailed')
            }
            if ($willChangeDesktop) {
                $desktopStore.PendingKey = $destinationKey
                $desktopStore.UnsafeKeys[$destinationKey] = $true
                $desktopStore.ProtectedKey = ''
                $desktopStore.ProtectedSnapshot = $null
                $storeDirty = $true
            }
            if ($storeDirty) {
                try { Write-DesktopSnapshotStore -Store $desktopStore }
                catch { throw (New-DisplayRefusal -Key 'switch.snapshotWriteFailed') }
            }
        }
        & $notePhase $phases 'state'

        if (-not $Quiet) {
            Write-Host "$($mode.Title):" -ForegroundColor Cyan
            foreach ($m in $wanted)    { Write-Host "  on       $($m.Output)  $($m.Label)" }
            Write-Host "  primary  $($primary.Output)  $($primary.Label)"
            foreach ($m in $toDisable) { Write-Host "  off      $($m.Output)  $($m.Label)" }
        }

        # One transition instead of three steps: the set is given whole, and the system moves the
        # primary role inside the transition itself.
        if ($DryRun) {
            Write-Host ("DRY  displays on: " + (($wanted | ForEach-Object { $_.Label }) -join ', ')) -ForegroundColor DarkGray
            Write-Host ("DRY  primary -> " + $primary.Label) -ForegroundColor DarkGray
        }
        else {
            Write-DisplayLog ("switch: on = " + (($wanted | ForEach-Object { $_.Label }) -join ', '))

            # The "before" command goes here rather than at the very start: up to this line the switch
            # can still refuse (there is no such mode, not one monitor is connected), and starting
            # somebody else's program for a mode that will not happen is not allowed.
            [void](Invoke-ModeHook -Settings $settings -ModeKey $ModeKey -Phase 'before')

            if ($exactAlready) {
                Write-DisplayLog 'switch: physical desktop already correct'
            }
            else {
                # The window-position snapshot comes before the rebuild, while the windows still stand
                # where a person put them. The functions live in WindowLayout.ps1, which the entry points
                # dot-source; core has to work without it too, so we check for their presence rather than
                # calling blind.
                #
                # Only when the topology really changes: on a repeat press the windows did not move
                # anywhere, and walking the windows while reading process paths costs tens of
                # milliseconds.
                $doWindows = (-not $sameTopology -and (Test-Path Function:\Save-WindowLayout) -and
                              ($null -eq $settings.restoreWindows -or $settings.restoreWindows))
                if ($doWindows) {
                    # A failed exact destination is not a new source of truth. Its windows may already
                    # have been squeezed onto the wrong geometry, so leaving it must not overwrite the
                    # last trusted window snapshot for that display set. The tail still restores the
                    # destination after a successful switch.
                    if ($currentSnapshotTrusted) {
                        try { Save-WindowLayout -Key (Get-DisplayLayoutKey -DevicePaths $activeNow) }
                        catch { Write-DisplayLog "warn: windows - saving failed: $($_.Exception.Message)" }
                    }
                    else { Write-DisplayLog 'windows: source desktop is unverified - keeping its saved window positions' }
                    & $notePhase $phases 'windows'
                }

                # The ordinary path is to set the whole desk in one transition: the set, the positions,
                # the primary, the resolutions and the refresh rates all at once. That way the system
                # rebuilds the desk ONCE instead of three times, and that is exactly what removes the
                # triple input freeze and the blinking screens.
                #
                # The checks below (Wait-ForTopology, Set-CcdLayout, Set-BestModeFor) stay where they are
                # and work as repairs: when everything landed at once, they see "already correct" and do
                # nothing.
                $full = $false
                if ($restorePlan) {
                    # Saved physical state is exact. A simplified retry would erase the very rotation or
                    # rational rate this path exists to preserve, so refusal stops here.
                    $full = Set-CcdFullConfig -Targets $restorePlan.Targets `
                        -PrimaryPath $restorePlan.PrimaryPath -Exact
                    if (-not $full) {
                        throw (New-DisplayRefusal -Key 'switch.refused' -Values @($mode.Title) -LogValues @($mode.Key))
                    }
                }
                elseif (-not $sameTopology) {
                    $targets = @(Get-SwitchTargets -Wanted $wanted -Cache (Get-ModeCache) -KeepMode:$KeepMode)
                    if ($targets.Count -eq $wanted.Count) {
                        $full = Set-CcdFullConfig -Targets $targets -PrimaryPath $primary.Id -Order @($settings.layout)
                    }
                    # It did not work out — the old three-step road. It works, it just blinks: the set
                    # without the modes, and the positions and the refresh rate brought up afterwards.
                    if (-not $full -and -not (Set-CcdTopology -DevicePaths $wantedIds)) {
                        throw (New-DisplayRefusal -Key 'switch.refused' -Values @($mode.Title) -LogValues @($mode.Key))
                    }
                }
                & $notePhase $phases 'apply'

                # We check the result rather than trusting the return code: otherwise a refusal to put a
                # monitor out looks like a complete success in the log.
                $settled = Wait-ForTopology -WantedPaths $wantedIds
                & $notePhase $phases 'settle'
                if (-not $settled.Ok) {
                    if ($settled.MissingLabels.Count -gt 0) {
                        Write-DisplayLog 'warn: not all requested displays came up'
                    }
                    if ($settled.ExtraLabels.Count -gt 0) {
                        $refused = @($settled.ExtraLabels)
                        Write-DisplayLog ("warn: refused to turn off: " + ($refused -join ', '))
                    }
                }
            }
        }


        if ($DryRun) { return (New-SwitchResult -ModeKey $ModeKey -Outcome 'dryrun' -Message 'dry run') }

        $order = @($settings.layout)
        $layoutChanged = $false
        $layoutFailed = $false
        if ($restorePlan) {
            # The exact CCD request already included the primary and both source coordinates. Calling the
            # ordinary layout path here would immediately flatten those saved offsets into a row.
            Write-DisplayLog $(if ($exactAlready) { 'layout: physical arrangement already correct' }
                               else { 'layout: restored the saved physical arrangement' })
        }
        else {
            $laid = Set-CcdLayout -PrimaryPath $primary.Id -Order $order
            if ($laid.Ok -and $laid.Changed) {
                if ($order.Count -gt 0) {
                    Write-DisplayLog ("layout: arranged left to right - " + ($order -join ' | '))
                }
                else {
                    Write-DisplayLog ("layout: taskbar moved to " + $primary.Label + " - no display order in the settings, the rest stay where they are")
                }
                $layoutChanged = $true
            }
            elseif ($laid.Ok) {
                if ($laid.Note) { Write-DisplayLog $laid.Note }
                else            { Write-DisplayLog 'layout: already correct' }
            }
            else { $layoutFailed = $true }
        }
        & $notePhase $phases 'layout'

        # The third and last "already done" check, after the topology and the layout: the desk did
        # not move at all AND every monitor we need is already in its best mode.
        $nothingMoved = ($sameTopology -eq $true) -and (-not $layoutChanged)
        $alreadyBest = ($nothingMoved -and -not $KeepMode -and (Test-ModesAlreadyBest $wanted))

        if ($restorePlan -and $exactAlready) {
            $step = Set-WantedModes -Wanted $wanted -AlreadyBest
        }
        elseif ($restorePlan) {
            # Query and summarize what landed, but never run the best-mode repair over an exact snapshot.
            $step = Set-WantedModes -Wanted $wanted -KeepMode
        }
        else {
            $step = Set-WantedModes -Wanted $wanted -AlreadyBest:$alreadyBest -KeepMode:$KeepMode
        }
        & $notePhase $phases 'modes'

        $restoreFailed = $false
        $verifiedState = $null
        if ($restorePlan) {
            $verifiedState = $(if ($exactAlready) { $monitors } else { @(Get-DisplayState) })
            $restoreFailed = -not (Test-DesktopSnapshotMatch -Snapshot $restorePlan.Expected -State $verifiedState)
            if ($restoreFailed) {
                Write-DisplayLog 'warn: the saved physical desktop did not verify after apply'
            }
        }

        # Not one of the displays we asked for attached: the set we put out is out, and the set we put
        # on never came. That is a black desk - the one failure a shortcut cannot mend, because the
        # person cannot see the menu to try again from. So the set that was on before the switch goes
        # back on, and the switch reports a refusal rather than a summary with nothing in it.
        #
        # Only when the topology really moved: on a repeat press nothing was put out, so there is
        # nothing to put back, and "did not attach" there is a monitor that is asleep, not a desk that
        # went dark. And only when EVERY wanted display failed - one that came up keeps the picture, and
        # the partial verdict below says which did not.
        if (-not $sameTopology -and $wanted.Count -gt 0 -and @($step.Failed).Count -ge $wanted.Count) {
            $sourceIds = @($(if ($currentSnapshot) { $currentSnapshot.Displays | ForEach-Object { $_.Id } }
                             else { $activeNow }))
            $wasOn = @($monitors | Where-Object { $sourceIds -contains $_.Id })
            Write-DisplayLog ("revert: none of the requested displays came up - putting back " + (@($wasOn | ForEach-Object { $_.Label }) -join ', '))
            $reverted = $false
            $exactReverted = $false
            $sourceKey = $(if ($currentSnapshot) { [string]$currentSnapshot.Key }
                           else { Get-DesktopSetKey -DevicePaths @($wasOn | ForEach-Object { $_.Id }) })
            if ($sourceKey) {
                # A topology-only emergency fallback can recover the picture while losing the primary,
                # coordinates or rotation. Guard that observed set before attempting the rollback so a
                # later switch cannot learn the damaged result over its complete baseline.
                $desktopStore.UnsafeKeys[$sourceKey] = $true
                try { Write-DesktopSnapshotStore -Store $desktopStore }
                catch { Write-DisplayLog "warn: could not guard the previous desktop before rollback - $($_.Exception.Message)" }
            }
            $sourceSnapshot = $(if ($currentSnapshotTrusted) { $currentSnapshot }
                                elseif ($sourceKey) { $desktopStore.Snapshots[$sourceKey] })
            if ($sourceSnapshot) {
                # When this source set was already guarded, the live pre-switch state may itself be the
                # damaged result of an earlier topology-only rollback. Restore and verify the saved good
                # baseline; matching that damaged observation must never clear its guard.
                $sourcePlan = New-DesktopRestorePlan -Snapshot $sourceSnapshot -Wanted $wasOn
                if ($sourcePlan) {
                    $reverted = Set-CcdFullConfig -Targets $sourcePlan.Targets `
                        -PrimaryPath $sourcePlan.PrimaryPath -Exact
                    if ($reverted) {
                        $reverted = Test-DesktopSnapshotMatch -Snapshot $sourcePlan.Expected `
                            -State @(Get-DisplayState)
                        $exactReverted = $reverted
                        if ($exactReverted -and $sourceKey) {
                            [void]$desktopStore.UnsafeKeys.Remove($sourceKey)
                            try { Write-DesktopSnapshotStore -Store $desktopStore }
                            catch { Write-DisplayLog "warn: could not mark the previous physical desktop verified - $($_.Exception.Message)" }
                        }
                    }
                }
            }
            if (-not $reverted) {
                $reverted = Set-CcdTopology -DevicePaths @($wasOn | ForEach-Object { $_.Id })
            }
            if ($exactReverted) { Write-DisplayLog 'revert: the previous physical desktop is back' }
            elseif ($reverted)  { Write-DisplayLog 'revert: the previous display set is back' }
            else           { Write-DisplayLog 'revert: Windows refused the previous desktop as well' }
            throw (New-DisplayRefusal -Key 'switch.noneCameUp' -Values @($mode.Title) -LogValues @($mode.Key))
        }

        $verdict = Format-SwitchResult -Summary $step.Summary -Failed $step.Failed `
                                       -Refused $refused -LayoutFailed $layoutFailed `
                                       -RestoreFailed $restoreFailed

        # A pending destination stays durable until fresh CCD state proves the whole physical desktop.
        # Only then may the watchdog protect these exact modes, including across a separate tray process.
        if ($verdict.Ok) {
            if (-not $verifiedState) { $verifiedState = @(Get-DisplayState) }
            $verifiedSnapshot = New-DesktopSnapshot -State $verifiedState
            if ($verifiedSnapshot -and $verifiedSnapshot.Key -eq $destinationKey) {
                if (-not $hadDestinationSnapshot) {
                    $desktopStore.Snapshots[$destinationKey] = $verifiedSnapshot
                }
                $desktopStore.PendingKey = ''
                [void]$desktopStore.UnsafeKeys.Remove($destinationKey)
                $desktopStore.ProtectedKey = $destinationKey
                $desktopStore.ProtectedSnapshot = $(if ($KeepMode -or $usingProtectedSnapshot) {
                                                          $verifiedSnapshot
                                                      }
                                                      else { $null })
                try { Write-DesktopSnapshotStore -Store $desktopStore }
                catch {
                    Write-DisplayLog "warn: the restored physical desktop could not be marked complete - $($_.Exception.Message)"
                    $restoreFailed = $true
                    $verdict = Format-SwitchResult -Summary $step.Summary -Failed $step.Failed `
                        -Refused $refused -LayoutFailed $layoutFailed -RestoreFailed $true
                }
            }
            else {
                $restoreFailed = $true
                $verdict = Format-SwitchResult -Summary $step.Summary -Failed $step.Failed `
                    -Refused $refused -LayoutFailed $layoutFailed -RestoreFailed $true
            }
        }
        $text = $verdict.Text
        # Formatted through InvariantCulture: the log is English, and `-f` takes the separator from
        # the current locale and on a Russian one would write "4,2 s".
        $took = $watch.Elapsed.TotalSeconds.ToString('0.0', [cultureinfo]::InvariantCulture)
        $breakdown = Format-PhaseTimes $phases
        if ($breakdown) { $breakdown = ': ' + $breakdown }
        Write-DisplayLog ("done: {0} ({1} s{2})" -f $verdict.Log, $took, $breakdown)

        # We remember the CHOICE, not the result: even if one monitor never came up, the person
        # asked for exactly this mode, and it is the one to put back after the computer is turned
        # on. A failed switch does not reach this point — it leaves as an exception above.
        #
        # And only a person's choice. An automatic switch is not a choice, and on 28 August that
        # cost an evening: a reapply on a monitor appearing wrote combo:Work over the chosen
        # solo:XG27AQDMGR, after which both onUnplug and the startup restore led to Work — that is,
        # past the monitor the person was sitting at. Every waking of the neighbouring screen
        # affirmed the trap all over again, and there was nothing to get out of it with.
        # The session stamp, though, is refreshed either way: it records that WE touched the desk in this
        # boot, not what the person chose, and the startup restore leans on it to keep quiet when the tray
        # was merely restarted.
        if (-not $Automatic) { Save-LastMode -Key $ModeKey } else { Update-LastModeSession }

        # And here it is the other way round — only the fact: whatever the monitor showed is what we remembered.
        Save-AppliedModes -Applied $step.Applied

        Invoke-SwitchTail -Settings $settings -ModeKey $ModeKey -RestoreWindows:($doWindows -and $verdict.Ok) `
                          -WantedIds $wantedIds -LevelTargets $step.LevelTargets

        return (New-SwitchResult -ModeKey $ModeKey -Message $text `
                    -Outcome $(if ($verdict.Ok) { 'done' } else { 'partial' }) `
                    -Refused $refused -Failed $step.Failed -Seconds $watch.Elapsed.TotalSeconds)
    }
    catch {
        # A refusal we raised ourselves has already put its English into the log (New-DisplayRefusal);
        # logging $_.Exception.Message here as well would put the SAME line in twice, in the language
        # of the window. Anything else that fell over says whatever it says, in English, as before.
        if (-not $_.Exception.Data.Contains('dm.logged')) { Write-DisplayLog "ERROR: $($_.Exception.Message)" }
        throw
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

# --- the refresh-rate watchdog ----------------------------------------------
# Windows drops the refresh rate by itself: when a monitor is connected, when it wakes from
# sleep, when the layout changes. On this machine it also cannot write the mode into the registry
# (see Set-DisplayMode), so "remember 240 Hz" is impossible in principle — the mode only lives
# until the next drop. Which means it has to be put back.
#
# Called on the system's DisplaySettingsChanged event. The bounce is damped: one layout change
# raises the event several times in a row.

$script:LastRestore = [datetime]::MinValue

# The watchdog is waiting for a game to end: while this is true, the tray timer will try again.
$script:RestorePending = $false

# So that "the resolution is not ours" is not logged on every check: monitor -> WxH.
$script:LastResNote = @{}

# A window that is not on the desk: it occupies no full screen, whatever its rectangle may be.
#
# The rule is not new — NativeWindows.Enumerate() already filters exactly this out when it takes
# window positions. Test-FullscreenApp did not know about it, and that is what caught
# TextInputHost: the system input window, EXACTLY the size of the monitor, visible by
# IsWindowVisible and cloaked by DWM at the same time. Measured 2026-08-26 — the only window on
# the desk that passed the check outright; the NVIDIA Overlay fell one pixel short of it and would
# have passed tomorrow, but it is a tool window.
#
# An empty title is NOT taken as a tell, even though the window enumeration accounts for it: a
# borderless game may well have no title, and filtering it out would be worse than a false positive.
#
# The function is pure and therefore testable: in the real check every input comes from Windows,
# and [NativeForeground] is a type rather than a function, so there is nothing to shadow it with in
# a test. Returns the reason the window does not count, or an empty string.
function Get-GhostWindowReason {
    param([bool]$Visible, [bool]$Cloaked, [bool]$Minimised, [bool]$ToolWindow)

    if (-not $Visible) { return 'the window is not visible' }
    if ($Cloaked) { return 'the window is cloaked by DWM' }
    if ($Minimised) { return 'the window is minimised' }
    if ($ToolWindow) { return 'the window is a tool window' }
    return ''
}

# Why the watchdog decided a full screen is on. Test-FullscreenApp writes it on every call, and
# whoever postponed work because of it reads it.
#
# The line is needed because "postponed" on its own is indistinguishable: two completely different
# checks stand behind it, and a hundred and fifty log entries did not answer which of them fired
# and on what. And the false positives there are real: TextInputHost (the system input window) is
# exactly the size of the monitor and passes the check, while the NVIDIA Overlay falls ONE pixel
# short of it — that is, tomorrow it will pass too. Until it is known which branch is at fault,
# editing the logic would be shooting blind.
$script:FullscreenWhy = ''

# The names of the QUERY_USER_NOTIFICATION_STATE values are for the log only: "2" in a bug report
# says nothing, "QUNS_BUSY" says everything.
$script:NotificationStateNames = @{
    1 = 'QUNS_NOT_PRESENT'; 2 = 'QUNS_BUSY'; 3 = 'QUNS_RUNNING_D3D_FULL_SCREEN'
    4 = 'QUNS_PRESENTATION_MODE'; 5 = 'QUNS_ACCEPTS_NOTIFICATIONS'
    6 = 'QUNS_QUIET_TIME'; 7 = 'QUNS_APP'
}

# A game sets its own mode, and touching it at that moment is not allowed: a mode change from
# outside kills a full-screen D3D device — the picture blinks, the window minimises. That is exactly
# what used to happen when Counter-Strike started.
#
# We ask twice. First the shell: SHQueryUserNotificationState, the same source Windows uses to
# decide whether to show balloons. It catches an honest full screen but does not catch a borderless
# window, so as a second step we look at whether the active window covers its monitor entirely.
function Test-FullscreenApp {
    $script:FullscreenWhy = ''
    try {
        $state = 0
        if ([NativeForeground]::SHQueryUserNotificationState([ref]$state) -eq 0) {
            # 2 — a full-screen window, 3 — D3D across the whole screen, 4 — presentation mode,
            # 7 — a Store app across the whole screen. 5 and 6 do not get in our way.
            if ($state -eq 2 -or $state -eq 3 -or $state -eq 4 -or $state -eq 7) {
                $name = $script:NotificationStateNames[[int]$state]
                if (-not $name) { $name = 'unknown' }
                $script:FullscreenWhy = 'the shell says {0} ({1})' -f $state, $name
                return $true
            }
        }
    }
    catch { }   # the system did not answer — we take it that there is no full screen

    try {
        $hwnd = [NativeForeground]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $false }

        # The desktop and the taskbar are full-screen too — they do not count.
        $cls = New-Object System.Text.StringBuilder 256
        [void][NativeForeground]::GetClassName($hwnd, $cls, 256)
        if (@('Progman', 'WorkerW', 'Shell_TrayWnd') -contains $cls.ToString()) { return $false }

        # The ghost is filtered out BEFORE the geometry: its geometry can be anything at all, right
        # up to the monitor's exact size.
        $ghost = Get-GhostWindowReason -Visible ([NativeForeground]::IsWindowVisible($hwnd)) `
                                       -Cloaked ([NativeForeground]::IsCloaked($hwnd)) `
                                       -Minimised ([NativeForeground]::IsIconic($hwnd)) `
                                       -ToolWindow ([NativeForeground]::IsToolWindow($hwnd))
        if ($ghost) { return $false }

        $rect = New-Object NativeForeground+RECT
        if (-not [NativeForeground]::GetWindowRect($hwnd, [ref]$rect)) { return $false }

        $mon = [NativeForeground]::MonitorFromWindow($hwnd, [NativeForeground]::MONITOR_DEFAULTTONEAREST)
        $mi = New-Object NativeForeground+MONITORINFO
        $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
        if (-not [NativeForeground]::GetMonitorInfo($mon, [ref]$mi)) { return $false }

        # This is by design: a maximised window covers the work area but not the taskbar, so only a
        # genuinely borderless full screen reaches this point. The margin is a matter of a few pixels
        # in practice, which is why BOTH rectangles and the window class go to the log: from them it
        # is visible whether this is a real game or yet another window that reached the monitor's edge.
        $covers = ($rect.Left -le $mi.rcMonitor.Left -and $rect.Top -le $mi.rcMonitor.Top -and
                   $rect.Right -ge $mi.rcMonitor.Right -and $rect.Bottom -ge $mi.rcMonitor.Bottom)
        if ($covers) {
            $script:FullscreenWhy = ('{0} covers its monitor: window {1},{2}..{3},{4}, monitor {5},{6}..{7},{8}' -f
                $cls.ToString(), $rect.Left, $rect.Top, $rect.Right, $rect.Bottom,
                $mi.rcMonitor.Left, $mi.rcMonitor.Top, $mi.rcMonitor.Right, $mi.rcMonitor.Bottom)
        }
        return $covers
    }
    catch { return $false }
}

function Restore-BestModes {
    param([int]$DebounceMs = 3000)

    if (((Get-Date) - $script:LastRestore).TotalMilliseconds -lt $DebounceMs) { return @() }
    $script:LastRestore = Get-Date

    if (Test-FullscreenApp) {
        if (-not $script:RestorePending) {
            Write-DisplayLog ('watch: postponed - full screen: {0}' -f $script:FullscreenWhy)
        }
        $script:RestorePending = $true
        return @()
    }

    # During a switch we do not interfere — the modes are being set there anyway.
    # The wait is inside a try for the same reason as in Switch-DisplayMode: an abandoned mutex arrives
    # as an exception that has already handed us ownership, and out here that would have leaked it.
    $mutex = New-Object System.Threading.Mutex($false, 'Local\DeskModesSwitch')
    $held = $false
    try { $held = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] {
        $held = $true
        Write-DisplayLog 'warn: watch - the previous holder of the lock died without letting go'
    }
    if (-not $held) { $mutex.Dispose(); return @() }

    try {
        # First we only gather the list — nothing is applied. A game manages to open after the
        # mode-change event, and the check on the way in sometimes does not catch it; gathering the
        # state takes a second, and the repeat check below lands on an already-open full screen.
        $state = @(Get-DisplayState)
        $activeKey = Get-DesktopSetKey -DevicePaths @($state | Where-Object { $_.Active } | ForEach-Object { $_.Id })
        $snapshotStore = Read-DesktopSnapshotStore
        # Pending or previously failed exact geometry is neither a baseline nor permission to fall back
        # to BestMode. A repair here can mutate the destination between retries and make verification
        # impossible on the next switch.
        if ($snapshotStore.PendingKey -eq $activeKey -or $snapshotStore.UnsafeKeys.ContainsKey($activeKey)) {
            Write-DisplayLog 'watch: active physical desktop is unverified - postponing mode repair'
            return @()
        }
        $protectedSnapshot = $null
        if ($snapshotStore.ProtectedKey -eq $activeKey -and
            -not $snapshotStore.UnsafeKeys.ContainsKey($activeKey)) {
            $protectedSnapshot = $(if ($snapshotStore.ProtectedSnapshot -and
                                       $snapshotStore.ProtectedSnapshot.Key -eq $activeKey) {
                                       $snapshotStore.ProtectedSnapshot
                                   }
                                   else { $snapshotStore.Snapshots[$activeKey] })
        }

        $todo = @()
        foreach ($m in $state) {
            if (-not $m.Active -or -not $m.BestMode) { continue }
            $cur = Get-CurrentMode $m.Output
            if (-not $cur) { continue }
            $desired = Get-WatchdogMode -Monitor $m -ProtectedSnapshot $protectedSnapshot
            if (-not $desired) { continue }
            # The watchdog does not touch the resolution. It does not change by itself: what Windows
            # drops is the refresh rate specifically (see the log — 240→144, 60→29). An application,
            # though, changes the resolution specifically and deliberately: Counter-Strike sets a
            # stretched 1440x1080, and three restores to 2560x1440 in a row broke its startup.
            $sameRes = ($cur.Width -eq $desired.Width -and $cur.Height -eq $desired.Height)
            if (-not $sameRes) {
                $note = '{0}x{1}' -f $cur.Width, $cur.Height
                if ($script:LastResNote[$m.Label] -ne $note) {
                    $script:LastResNote[$m.Label] = $note
                    Write-DisplayLog ("watch: {0} is at {1}x{2}, not {3}x{4} - leaving the resolution alone, an app set it" -f `
                        $m.Label, $cur.Width, $cur.Height, $desired.Width, $desired.Height)
                }
                continue
            }

            $script:LastResNote.Remove($m.Label)
            if ($cur.Hz -eq $desired.Hz) { continue }

            $todo += [pscustomobject]@{ Monitor = $m; Current = $cur; Desired = $desired }
        }

        if ($todo.Count -gt 0 -and (Test-FullscreenApp)) {
            if (-not $script:RestorePending) {
                Write-DisplayLog ('watch: postponed - full screen: {0}' -f $script:FullscreenWhy)
            }
            $script:RestorePending = $true
            return @()
        }

        $fixed = @()
        foreach ($t in $todo) {
            $m = $t.Monitor
            $cur = $t.Current
            $desired = $t.Desired

            Write-DisplayLog ("watch: {0} dropped to {1}x{2} @ {3} Hz, restoring {4}x{5} @ {6} Hz" -f `
                $m.Label, $cur.Width, $cur.Height, $cur.Hz, $desired.Width, $desired.Height, $desired.Hz)

            $nw = 0; $nh = 0
            if ($m.Native) { $nw = $m.Native.Width; $nh = $m.Native.Height }
            # A protected physical snapshot deliberately takes precedence over the largest driver mode.
            if (Set-BestModeFor -Output $m.Output -Label $m.Label -NativeWidth $nw -NativeHeight $nh -Best $desired) {
                $fixed += $m.Label
            }
        }
        # Our own change will raise the event again — we do not let ourselves go round in a circle.
        if ($fixed.Count -gt 0) { $script:LastRestore = Get-Date }
        $script:RestorePending = $false
        return $fixed
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

# --- audio following the mode -----------------------------------------------
# Every mode can be matched with an output device: sat down to play on the ASUS — the sound went to
# its speakers; came back to work — to the headphones on the desk. Off while the audio dictionary in
# the settings is empty.

# The list of output devices, for configuring by hand: so it is known which part of a name to write
# into settings.json. Called from Set-Display.ps1 (audio).
function Get-AudioDevices {
    try { return @([NativeAudio]::ListRenderDevices()) }
    catch {
        Write-DisplayLog "warn: audio - could not list devices: $($_.Exception.Message)"
        return @()
    }
}

# Make the first device whose name contains $Match the default one.
#
# We assign the eConsole and eMultimedia roles and deliberately do NOT touch eCommunications: the
# device for talking is usually a headset, and it should not travel after the monitors. Whoever needs
# it otherwise will edit it here.
function Set-DefaultAudioDevice {
    param([Parameter(Mandatory)][string]$Match)

    if (-not $Match) { return $false }

    # @(): a single device would come back from the function as a scalar, and a scalar has no .Count.
    $devices = @(Get-AudioDevices)
    if ($devices.Count -eq 0) { return $false }

    $hit = $devices | Where-Object { $_.Name -like ('*' + $Match + '*') } | Select-Object -First 1
    if (-not $hit) {
        # The names are listed in the log: the setting is a PIECE of a name, and when it matches
        # nothing the only useful answer is what there was to match against. The mode editor offers
        # the same list in its dropdown, but a device can go away between one switch and the next —
        # and then this line is the only place the change is written down.
        Write-DisplayLog ("warn: audio device '{0}' not found - have: {1}" -f `
            $Match, (($devices | ForEach-Object { $_.Name }) -join '; '))
        return $false
    }

    if ($hit.IsDefault) { return $true }   # already this one — we keep quiet rather than make noise

    try {
        $rc = [NativeAudio]::SetDefault($hit.Id, 0)          # eConsole
        $rc2 = [NativeAudio]::SetDefault($hit.Id, 1)         # eMultimedia
        if ($rc -ne 0 -or $rc2 -ne 0) {
            Write-DisplayLog ("warn: audio - switching to '{0}' returned {1}/{2}" -f $hit.Name, $rc, $rc2)
            return $false
        }
        Write-DisplayLog ("audio: default -> {0}" -f $hit.Name)
        return $true
    }
    catch {
        Write-DisplayLog "warn: audio - could not switch: $($_.Exception.Message)"
        return $false
    }
}

# --- brightness and contrast following the mode -----------------------------
# An external monitor's brightness lives in its firmware rather than in Windows, and it is
# changed over DDC/CI — the same channel as the buttons on the bezel (see NativeDdc). Which
# means a mode can carry it along: "Work" is 80, the evening one is 25, and the little wheel
# under the desk is no longer needed.
#
# There is nothing to set on a sleeping monitor: it answers no requests. So the levels are set
# only on the ones that are on, at the very end of a switch.

function Get-MonitorLevels {
    try { return @([NativeDdc]::Read()) }
    catch {
        Write-DisplayLog "levels: could not ask the monitors - $($_.Exception.Message)"
        return @()
    }
}

# A pure function: one mode's setting + that mode's monitors -> who gets which number. Two
# forms of entry, because both are needed: a number is "the same for everyone" (which is how it
# is written nine times out of ten), a dictionary is "one each".
#
# Hands back an [ordered] in the monitors' order: the log has to read in the same order the
# monitors stand in on the desk.
function Get-LevelPlan {
    param($Setting, $Wanted)

    $plan = [ordered]@{}
    if ($null -eq $Setting) { return $plan }

    foreach ($m in @($Wanted)) {
        $value = $null
        if ($Setting -is [int] -or $Setting -is [long] -or $Setting -is [double] -or $Setting -is [string]) {
            $parsed = 0
            if ([int]::TryParse([string]$Setting, [ref]$parsed)) { $value = $parsed }
        }
        elseif ($Setting -is [System.Collections.IDictionary]) {
            foreach ($key in @($Setting.Keys)) {
                if (Test-DisplayNameMatch -Pattern ([string]$key) -Label $m.Label -ShortId $m.ShortId) {
                    $parsed = 0
                    if ([int]::TryParse([string]$Setting[$key], [ref]$parsed)) { $value = $parsed }
                    break
                }
            }
        }
        if ($null -eq $value) { continue }
        # Zero is a legitimate brightness (the monitor goes black but stays on), so we clamp
        # rather than discard. Numbers outside 0..100 are almost always a typo, and taking a
        # monitor to black over a typo is not allowed.
        if ($value -lt 0) { $value = 0 }
        if ($value -gt 100) { $value = 100 }
        $plan[[string]$m.Label] = $value
    }
    return $plan
}

# --- HDR following the mode -------------------------------------------------
# A game wants HDR on, and everything else on the same display wants it off: the toggle is three clicks
# deep in Windows settings, and a mode is the natural place to hang it. A mode carries one answer per
# display, or one for all of them, and "not mentioned" leaves the display exactly as it is - HDR
# survives a switch by itself (see the note in NativeCcd), so a mode that says nothing costs nothing.

# What one target says about itself: Supported and Enabled, or $null when the system would not answer -
# an inactive target, a display without the capability, an older Windows.
function Get-DisplayHdr {
    param($Target)

    $M = [System.Runtime.InteropServices.Marshal]
    $info = New-Object NativeCcd+ADVANCED_COLOR_INFO
    $h = New-Object NativeCcd+HEADER
    $h.type = [NativeCcd]::GET_ADVANCED_COLOR_INFO
    $h.size = $M::SizeOf($info)
    $h.adapterId = $Target.Adapter
    $h.id = [uint32]$Target.TargetId
    $info.header = $h
    if ([NativeCcd]::DisplayConfigGetDeviceInfo([ref]$info) -ne 0) { return $null }
    return [pscustomobject]@{
        Supported = (($info.value -band [NativeCcd]::ADVANCED_COLOR_SUPPORTED) -ne 0)
        Enabled   = (($info.value -band [NativeCcd]::ADVANCED_COLOR_ENABLED) -ne 0)
    }
}

# Turn HDR on or off on one target. $true when Windows took it.
function Set-DisplayHdr {
    param($Target, [bool]$Enabled)

    $M = [System.Runtime.InteropServices.Marshal]
    $set = New-Object NativeCcd+ADVANCED_COLOR_STATE
    $h = New-Object NativeCcd+HEADER
    $h.type = [NativeCcd]::SET_ADVANCED_COLOR_STATE
    $h.size = $M::SizeOf($set)
    $h.adapterId = $Target.Adapter
    $h.id = [uint32]$Target.TargetId
    $set.header = $h
    $set.value = $(if ($Enabled) { 1 } else { 0 })
    return ([NativeCcd]::DisplayConfigSetDeviceInfo([ref]$set) -eq 0)
}

# A value out of settings.json -> $true, $false, { name -> bool }, or $null for "there is no entry".
# Booleans are what the window writes; "on"/"off"/"true"/"false" are for a hand that edits the file.
function ConvertTo-HdrSetting {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string]) {
        switch ($Value.Trim().ToLowerInvariant()) {
            'true'  { return $true }
            'on'    { return $true }
            'false' { return $false }
            'off'   { return $false }
            default { return $null }
        }
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return $null }

    $perDisplay = [ordered]@{}
    $properties = $(if ($Value -is [System.Collections.IDictionary]) {
                        @($Value.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Value = $Value[$_] } })
                    } else { @($Value.PSObject.Properties) })
    foreach ($p in $properties) {
        if (-not $p.Name) { continue }
        $one = ConvertTo-HdrSetting $p.Value
        if ($one -is [bool]) { $perDisplay[[string]$p.Name] = $one }
    }
    if ($perDisplay.Count -eq 0) { return $null }
    return $perDisplay
}

# Which of the wanted displays get what: label -> bool. The same matching brightness uses.
function Get-HdrPlan {
    param($Setting, $Wanted)

    $plan = [ordered]@{}
    if ($null -eq $Setting) { return $plan }
    foreach ($m in @($Wanted)) {
        if ($Setting -is [bool]) { $plan[[string]$m.Label] = [bool]$Setting; continue }
        if ($Setting -is [System.Collections.IDictionary]) {
            foreach ($key in @($Setting.Keys)) {
                if (Test-DisplayNameMatch -Pattern ([string]$key) -Label $m.Label -ShortId $m.ShortId) {
                    $plan[[string]$m.Label] = [bool]$Setting[$key]
                    break
                }
            }
        }
    }
    return $plan
}

# Apply a mode's HDR to the displays that are on. One CCD walk for everybody, a read before every
# write: a display already where the mode wants it is not touched, because the toggle itself blanks
# the screen for a moment. Returns the labels that changed.
function Set-ModeHdr {
    param($Setting, $Targets)

    $plan = Get-HdrPlan -Setting $Setting -Wanted $Targets
    if ($plan.Count -eq 0) { return @() }

    $byOutput = @{}
    foreach ($t in @(Get-CcdTargets)) { if ($t.Active -and $t.Output) { $byOutput[[string]$t.Output] = $t } }

    $changed = @()
    foreach ($t in @($Targets)) {
        $label = [string]$t.Label
        if (-not $plan.Contains($label)) { continue }
        $want = [bool]$plan[$label]
        $target = $byOutput[[string]$t.Device]
        if (-not $target) { Write-DisplayLog "hdr: $label is not on the desk - left alone"; continue }
        $now = Get-DisplayHdr -Target $target
        if (-not $now -or -not $now.Supported) { Write-DisplayLog "hdr: $label does not support HDR - left alone"; continue }
        if ($now.Enabled -eq $want) { continue }
        if (Set-DisplayHdr -Target $target -Enabled $want) {
            Write-DisplayLog ("hdr: {0} -> {1}" -f $label, $(if ($want) { 'on' } else { 'off' }))
            $changed += $label
        }
        else { Write-DisplayLog "warn: hdr - Windows refused to turn it $(if ($want) { 'on' } else { 'off' }) on $label" }
    }
    return $changed
}

# --- the monitor's picture preset following the mode ------------------------
# A mode already carries brightness and contrast; the preset is the third thing the monitor holds
# in its own firmware, and the one a person changes with the bezel buttons: Reader for reading,
# FPS for a game, sRGB for a photograph.
#
# What this deliberately does NOT do is name them. Probed on this desk on 2026-09-03: on the LG
# UltraGear register 0x15 answers 1 for Reader and 6 for Gamer 1 - and 45, which the menu ALSO
# calls Gamer 1 and which looks different from 6. The name is not the setting; the number is. So
# there is no table of models here and no learning of names: DeskModes remembers the number the
# monitor is holding right now, and writes that number back.
#
# Which register holds it is the monitor's business too: MCCS names 0xDC, both LGs here are silent
# on it and answer on 0x15 instead, and the ASUS is the other way round. So the register is learnt
# at the same moment as the number and stored beside it.

# The order they are tried in: the standard one first.
$script:PictureCodes = @(0xDC, 0x15)

# What every monitor that is on is holding right now. A monitor that is asleep answers nothing and
# is simply not in the list.
function Get-MonitorPictures {
    try { return @([NativeDdc]::ReadPicture([int[]]$script:PictureCodes)) }
    catch {
        Write-DisplayLog "picture: could not ask the monitors - $($_.Exception.Message)"
        return @()
    }
}

# "0x15:45" - a register and a number, the way it is written in settings.json. Hex for the
# register because that is how every monitor's documentation writes it, and plain for the number
# because that is what a person sees change when they press a button on the bezel.
function Format-PictureSetting {
    param([int]$Code, [int]$Value)

    return ('0x{0:X2}:{1}' -f $Code, $Value)
}

# The other way round, and forgiving: "0x15:45" and "21:45" are the same thing, spaces do not
# matter, and anything else is $null rather than an error - settings.json is edited by hand, and a
# typo there must cost a line in the log, not a switch.
function ConvertTo-PictureSetting {
    param($Value)

    if ($Value -is [System.Collections.IDictionary] -or
        ($Value -and $Value.PSObject -and $null -eq $Value.PSObject.Properties['Keys'] -and
         $Value -isnot [string] -and $Value -isnot [int] -and $Value.PSObject.Properties.Count -gt 0)) {
        # A mode's entry: a map of "a piece of a name" -> "register:number".
        $one = [ordered]@{}
        $properties = $(if ($Value -is [System.Collections.IDictionary]) {
                            @($Value.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Value = $Value[$_] } })
                        } else { @($Value.PSObject.Properties) })
        foreach ($p in $properties) {
            if (-not $p.Name) { continue }
            $text = [string]$p.Value
            if (ConvertFrom-PictureSetting $text) { $one[[string]$p.Name] = $text.Trim() }
            else { Write-DisplayLog ("picture: '{0}' for {1} is not a register and a number - ignored" -f $text, $p.Name) }
        }
        if ($one.Count -eq 0) { return $null }
        return $one
    }
    return $null
}

# One "register:number" -> the pair, or $null. A pure function: this is where a hand-written
# settings.json is either understood or refused, and it is the one place worth pinning down.
function ConvertFrom-PictureSetting {
    param([string]$Text)

    if (-not $Text) { return $null }
    $parts = ([string]$Text).Split(':')
    if ($parts.Count -ne 2) { return $null }

    $code = 0; $value = 0
    foreach ($pair in @(@{ Text = $parts[0].Trim(); Into = 'code' }, @{ Text = $parts[1].Trim(); Into = 'value' })) {
        $text = [string]$pair.Text
        $number = 0
        if ($text -match '^0[xX][0-9a-fA-F]+$') { $number = [Convert]::ToInt32($text.Substring(2), 16) }
        elseif ([int]::TryParse($text, [ref]$number)) { }
        else { return $null }
        if ($number -lt 0 -or $number -gt 255) { return $null }
        if ($pair.Into -eq 'code') { $code = $number } else { $value = $number }
    }
    return [pscustomobject]@{ Code = $code; Value = $value }
}

# A pure function, the twin of Get-LevelPlan: one mode's picture setting + that mode's monitors ->
# who gets which register and number. Only a map here, never a single value: a preset number means
# nothing on a monitor of another make, so "the same for everybody" would be a promise this cannot
# keep.
function Get-PicturePlan {
    param($Setting, $Wanted)

    $plan = [ordered]@{}
    if ($null -eq $Setting -or -not ($Setting -is [System.Collections.IDictionary])) { return $plan }

    foreach ($m in @($Wanted)) {
        foreach ($key in @($Setting.Keys)) {
            if (-not (Test-DisplayNameMatch -Pattern ([string]$key) -Label $m.Label -ShortId $m.ShortId)) { continue }
            $one = ConvertFrom-PictureSetting ([string]$Setting[$key])
            if ($one) { $plan[[string]$m.Label] = $one }
            else { Write-DisplayLog ("picture: '{0}' for {1} is not a register and a number - ignored" -f $Setting[$key], $key) }
            break
        }
    }
    return $plan
}

# $Targets is an array of objects with the fields Device (\\.\DISPLAY1), Label and ShortId.
# Device comes from the output enumeration that has already been done: there is deliberately no
# CCD walk of our own here, a switch is not free enough as it is.
function Set-MonitorLevels {
    param($Targets, $BrightnessSetting, $ContrastSetting, $PictureSetting)

    $bright = Get-LevelPlan -Setting $BrightnessSetting -Wanted $Targets
    $contra = Get-LevelPlan -Setting $ContrastSetting -Wanted $Targets
    $picture = Get-PicturePlan -Setting $PictureSetting -Wanted $Targets
    if ($bright.Count -eq 0 -and $contra.Count -eq 0 -and $picture.Count -eq 0) { return @() }

    # First the whole request is assembled and only then do we go to the bus: one walk for every
    # monitor instead of a walk per monitor (see NativeDdc.Set).
    $devices = @(); $wantB = @(); $wantC = @(); $wantCode = @(); $wantPicture = @(); $labels = @()
    foreach ($t in @($Targets)) {
        $label = [string]$t.Label
        $b = $(if ($bright.Contains($label)) { [int]$bright[$label] } else { -1 })
        $c = $(if ($contra.Contains($label)) { [int]$contra[$label] } else { -1 })
        $p = $(if ($picture.Contains($label)) { $picture[$label] } else { $null })
        if ($b -lt 0 -and $c -lt 0 -and $null -eq $p) { continue }
        if (-not $t.Device) { continue }

        $devices += [string]$t.Device
        $wantB += $b
        $wantC += $c
        $wantCode += $(if ($p) { [int]$p.Code } else { -1 })
        $wantPicture += $(if ($p) { [int]$p.Value } else { -1 })
        $labels += $label
    }
    if ($devices.Count -eq 0) { return @() }

    $applied = @()
    try { $applied = @([NativeDdc]::Set([string[]]$devices, [int[]]$wantB, [int[]]$wantC,
                                        [int[]]$wantCode, [int[]]$wantPicture)) }
    catch { Write-DisplayLog "levels: could not set - $($_.Exception.Message)"; return @() }

    $done = @()
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $label = $labels[$i]
        $b = [int]$wantB[$i]
        $c = [int]$wantC[$i]
        $one = $(if ($i -lt $applied.Count) { $applied[$i] } else { $null })
        if (-not $one) {
            Write-DisplayLog ("levels: {0} - no answer from the bus at all" -f $label)
            continue
        }

        # Broken down by value rather than "worked / did not work": the monitor could have applied
        # the brightness and not the contrast, and that has to be visible in the log separately.
        # The confirmation is the value read back, not the write's return code (see NativeDdc.Set).
        #
        # And three outcomes rather than two. "Answered with somebody else's number" is a refusal,
        # and the advice about the monitor's own menu belongs here. "Did not answer at all" is most
        # often a bus that has not woken up yet, and the value most likely DID land. One message for
        # both cases would lie in half of them: "did not take brightness 60" used to go to a monitor
        # that was standing at exactly 60.
        $good = @()
        $refused = @()
        $silent = @()
        # The preset first, in the log as on the bus: on some LG presets brightness and contrast are
        # locked in the monitor's own menu, and reading "brightness 80, picture 45" would suggest an
        # order that never happened.
        if ([int]$wantCode[$i] -ge 0) {
            $want = [int]$wantPicture[$i]
            if ($one.PictureConfirmed) { $good += "picture $want" }
            elseif ($one.PictureRead)  { $refused += "picture $want (it reports $($one.PictureActual))" }
            else                       { $silent += "picture $want" }
        }
        if ($b -ge 0) {
            if ($one.BrightnessConfirmed) { $good += "brightness $b" }
            elseif ($one.BrightnessRead)  { $refused += "brightness $b (it reports $($one.BrightnessActual))" }
            else                          { $silent += "brightness $b" }
        }
        if ($c -ge 0) {
            if ($one.ContrastConfirmed) { $good += "contrast $c" }
            elseif ($one.ContrastRead)  { $refused += "contrast $c (it reports $($one.ContrastActual))" }
            else                        { $silent += "contrast $c" }
        }

        if ($good.Count -gt 0) {
            Write-DisplayLog ("levels: {0} - {1}" -f $label, ($good -join ', '))
            $done += $label
        }
        if ($refused.Count -gt 0) {
            Write-DisplayLog ("levels: {0} refused {1} - DDC/CI may be off in its own menu" -f $label, ($refused -join ', '))
        }
        if ($silent.Count -gt 0) {
            # Not "did not take it" but "did not answer": lying about success is not allowed, but
            # nor is pinning a refusal on a monitor that never made one.
            Write-DisplayLog ("levels: {0} never answered about {1} - it may still be waking up, and the value may well have landed" -f `
                              $label, ($silent -join ', '))
        }
    }
    return $done
}

# --- commands around a switch -----------------------------------------------
# "Do this as well when you turn on such-and-such a set of screens." One line in the settings
# instead of ten new fields: close an application, change the power plan, put the lights out in
# the room — those are all other people's programs, and there is no need to know about them. Our
# business is to start it and write down in the log that we did.

# A pure function: settings + mode key + phase -> a command, or an empty string.
function Get-ModeHook {
    param($Settings, [string]$ModeKey, [string]$Phase)

    if (-not $Settings -or -not $Settings.hooks -or -not $ModeKey) { return '' }
    if (-not $Settings.hooks.Contains($ModeKey)) { return '' }
    $entry = $Settings.hooks[$ModeKey]
    if ($null -eq $entry) { return '' }
    # A string instead of an object means "after": the short form for the frequent case.
    if ($entry -is [string]) { return $(if ($Phase -eq 'after') { [string]$entry } else { '' }) }
    return [string]$entry[$Phase]
}

# A pure function: a command -> what to run it with and how. A .ps1 has to be called through
# powershell with the policy bypassed (our own scripts will not start otherwise); everything else
# goes to cmd /c — there .exe, .bat and built-ins like start all work.
function Get-HookLaunch {
    param([string]$Command)

    $cmd = [string]$Command
    if (-not $cmd -or -not $cmd.Trim()) { return $null }
    $cmd = $cmd.Trim()

    # The first word, quotes respected: a path to a script sometimes has spaces in it.
    $first = ''
    if ($cmd -match '^"([^"]+)"') { $first = $Matches[1] }
    elseif ($cmd -match '^(\S+)') { $first = $Matches[1] }

    if ($first -like '*.ps1') {
        $rest = $cmd.Substring($(if ($cmd.StartsWith('"')) { $first.Length + 2 } else { $first.Length })).Trim()
        $argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $first
        if ($rest) { $argLine += ' ' + $rest }
        return [pscustomobject]@{
            File      = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
            Arguments = $argLine
        }
    }
    return [pscustomobject]@{
        File      = (Join-Path $env:SystemRoot 'System32\cmd.exe')
        Arguments = '/c ' + $cmd
    }
}

function Invoke-ModeHook {
    param($Settings, [string]$ModeKey, [string]$Phase)

    $cmd = Get-ModeHook -Settings $Settings -ModeKey $ModeKey -Phase $Phase
    if (-not $cmd) { return $false }
    $launch = Get-HookLaunch -Command $cmd
    if (-not $launch) { return $false }

    try {
        # We start it and do NOT wait. Switching the desk is something a person does with a
        # shortcut and measures in tenths of a second; somebody else's program has no right to hold
        # it up, and a "hung before" would mean a black screen.
        Start-Process -FilePath $launch.File -ArgumentList $launch.Arguments -WindowStyle Hidden | Out-Null
        Write-DisplayLog ("hook: {0} - {1}" -f $Phase, $cmd)
        return $true
    }
    catch {
        Write-DisplayLog ("hook: {0} failed - {1}" -f $Phase, $_.Exception.Message)
        return $false
    }
}

# --- rules ------------------------------------------------------------------
# "When this happens, become that."
#
# All the logic is here, as a pure function over facts, and it is under tests. What is left in
# the tray is only gathering the facts and carrying out the decision: the watching lives in a
# timer that ticks every fifteen seconds for weeks, and debugging that from the log instead of
# from tests is far too expensive.
#
# Ownership: while a rule holds the desk, the others keep quiet. Otherwise two matching rules
# would cut across each other every fifteen seconds.

function Test-RuleMatch {
    param($Rule, $Facts)

    if (-not $Rule) { return $false }
    if ($null -ne $Rule.enabled -and -not $Rule.enabled) { return $false }
    if (-not $Rule.mode) { return $false }

    switch ([string]$Rule.when) {
        'process' {
            if (-not $Rule.process) { return $false }
            $want = ([string]$Rule.process) -replace '\.exe$', ''
            foreach ($p in @($Facts.Processes)) {
                if ([string]$p -and ([string]$p).ToLowerInvariant() -eq $want.ToLowerInvariant()) { return $true }
            }
            return $false
        }
        'idle' {
            $minutes = [int]$Rule.minutes
            if ($minutes -le 0) { return $false }
            return ([int]$Facts.IdleSeconds -ge $minutes * 60)
        }
        'displays' {
            return (Test-DisplaySetMatch -Patterns @($Rule.displays) -Connected @($Facts.Connected))
        }
        default { return $false }
    }
}

# Whether the CONNECTED displays are exactly the ones a rule names - every pattern finds a display of its
# own, and no display is left over. Exactly, and not "at least": the laptop-and-dock case this exists for
# is "these two monitors are here, so this is the desk at home", and a rule for the one monitor at the
# office must not fire at home as well because that monitor is there too. Connected, not on: a monitor
# that is off at its own button is still part of the desk, and it is the set of the desk that says
# where the computer is standing.
#
# $Connected is what the tray gathers: Label and ShortId per display, so a rule can name a display the
# way layout and a combo's members do - by a piece of its name or by its Monitor ID.
function Test-DisplaySetMatch {
    param($Patterns, $Connected)

    $want = @(@($Patterns) | Where-Object { $_ })
    $have = @(@($Connected) | Where-Object { $_ })
    if ($want.Count -eq 0) { return $false }
    if ($want.Count -ne $have.Count) { return $false }

    # Find a complete one-to-one assignment rather than taking the first match. With the patterns LG
    # and ULTRAGEAR, the broad LG may first meet LG ULTRAGEAR even though it can move to LG ULTRAFINE;
    # a greedy choice would then make the answer depend on pattern order.
    $candidates = @{}
    for ($patternIndex = 0; $patternIndex -lt $want.Count; $patternIndex++) {
        $matches = @()
        for ($displayIndex = 0; $displayIndex -lt $have.Count; $displayIndex++) {
            $m = $have[$displayIndex]
            if (Test-DisplayNameMatch -Pattern ([string]$want[$patternIndex]) `
                    -Label ([string]$m.Label) -ShortId ([string]$m.ShortId)) {
                $matches += $displayIndex
            }
        }
        if ($matches.Count -eq 0) { return $false }
        $candidates[$patternIndex] = @($matches)
    }

    # Augmenting paths let a later, narrower pattern displace an earlier broad match when the broad
    # pattern has another candidate. Every display is still assigned at most once.
    $assigned = @{}
    $assign = $null
    $assign = {
        param([int]$PatternIndex, $SeenDisplays)

        foreach ($displayIndex in @($candidates[$PatternIndex])) {
            if ($SeenDisplays.ContainsKey($displayIndex)) { continue }
            $SeenDisplays[$displayIndex] = $true
            if (-not $assigned.ContainsKey($displayIndex) -or
                (& $assign -PatternIndex ([int]$assigned[$displayIndex]) -SeenDisplays $SeenDisplays)) {
                $assigned[$displayIndex] = $PatternIndex
                return $true
            }
        }
        return $false
    }
    for ($patternIndex = 0; $patternIndex -lt $want.Count; $patternIndex++) {
        if (-not (& $assign -PatternIndex $patternIndex -SeenDisplays @{})) { return $false }
    }
    return $true
}

# The decision over all the rules at once. $OwnedIndex is the number of the rule that holds the
# desk right now, or -1.
#
# Action:
#   switch   go to Mode, remembering Back and RuleIndex;
#   return   the condition ended, go back to Mode;
#   release  the desk was switched by hand — let go, doing nothing;
#   blocked  the rule fired, but there will be nowhere to go back to afterwards;
#   none     do nothing.
# What identifies a rule, as against where it happens to sit in the list. A claim on the desk used to be
# the INDEX and nothing else, and the list is edited both by hand and from the Settings window while a
# rule is holding the desk: delete a rule above the owner, and the claim quietly moves to whoever slides
# into that slot — the desk gets handed back to a stranger's "back", or held by a condition nobody asked
# about.
#
# The four fields are the whole of a rule as far as this question goes: what it watches, what for, where
# it takes the desk and where it gives it back. Two rules alike in all four ARE one rule here — either of
# them holding the desk gives the same answer.
function Get-RuleSignature {
    param($Rule)

    if (-not $Rule) { return '' }
    # Tab-joined: a tab cannot occur in a mode key or a process name, so no pair of different rules can
    # collide by the separator landing inside a field.
    # The displays are one field here, joined by a bar: a display name cannot hold a tab either, and
    # the bar keeps two rules about different desks from reading as one.
    return (@([string]$Rule.when, [string]$Rule.process, [int]$Rule.minutes,
              (@(@($Rule.displays) | ForEach-Object { [string]$_ }) -join '|'),
              [string]$Rule.mode, [string]$Rule.back) -join "`t")
}

# $OwnedSignature is who the holder IS (see Get-RuleSignature); $OwnedIndex is only where to look first.
# $OwnedTaken is whether the switch that was to take the desk actually went through: a claim can be held
# by a rule that never got the desk at all — see the tray, which holds one rather than nagging every
# fifteen seconds over a refusal that will not come right.
function Get-RuleDecision {
    param($Rules, $Facts, [string]$CurrentMode, [int]$OwnedIndex = -1, [string]$OwnedBack = '',
          [string]$OwnedSignature = '', [bool]$OwnedTaken = $true, [string]$OwnedDeskRelation = '',
          [int]$ReturnTries = 0)

    $list = @($Rules)
    $none = [pscustomobject]@{ Action = 'none'; Mode = ''; Back = ''; RuleIndex = -1; Reason = '' }

    if ($OwnedIndex -ge 0) {
        $owned = $(if ($OwnedIndex -lt $list.Count) { $list[$OwnedIndex] } else { $null })
        # Not the rule that took the desk any more: the list was edited underneath it. The index is a
        # hint, the signature is the answer.
        if ($OwnedSignature -and (Get-RuleSignature -Rule $owned) -ne $OwnedSignature) {
            $owned = @($list | Where-Object { (Get-RuleSignature -Rule $_) -eq $OwnedSignature }) |
                        Select-Object -First 1
        }
        # A manual desk wins even when the condition ends or its rule is removed on this same tick.
        # Once a return has started, its own partial result can also sit outside the rule's envelope;
        # keep that bounded retry alive rather than calling the tray's switch a person's change.
        if ($OwnedTaken -and $OwnedDeskRelation -eq 'different' -and $ReturnTries -le 0) {
            return [pscustomobject]@{ Action = 'release'; Mode = ''; Back = ''; RuleIndex = -1
                                      Reason = 'the displays were changed by hand' }
        }
        # The rule vanished from the settings while it was holding the desk (the file gets edited
        # by hand and from the Settings window) — we go back where we came from and let go.
        if (-not $owned) {
            # Unless it never had the desk: then there is nothing to give back, and switching anywhere
            # over a rule that is gone would be moving the screens on nobody's say-so.
            if (-not $OwnedTaken) {
                return [pscustomobject]@{ Action = 'release'; Mode = ''; Back = ''; RuleIndex = -1
                                          Reason = 'the rule is gone from the settings, and it never took the desk' }
            }
            return [pscustomobject]@{ Action = 'return'; Mode = [string]$OwnedBack; Back = ''; RuleIndex = -1
                                      Reason = 'the rule is gone from the settings' }
        }
        if (Test-RuleMatch -Rule $owned -Facts $Facts) {
            # The switch that was to take the desk did not go through, so the desk is nobody's and there
            # is nothing to hold it up against. The claim is kept only to keep from asking again every
            # fifteen seconds for something that will not come right; we sit quiet until the condition
            # ends. Without this the next tick read an unchanged desk as "the displays were changed by
            # hand" and wrote that in the log about a person who had touched nothing.
            if (-not $OwnedTaken) { return $none }
            # We do not fight people: a physical desk outside the envelope left by our switch is a
            # deliberate decision. When no physical claim was supplied, retain the key comparison
            # for callers that do not own a state cache. An unknown cache proves nothing either way.
            $changedByHand = (-not $OwnedDeskRelation -and $CurrentMode -and
                              $CurrentMode -ne [string]$owned.mode)
            if ($changedByHand) {
                return [pscustomobject]@{ Action = 'release'; Mode = ''; Back = ''; RuleIndex = -1
                                          Reason = 'the displays were changed by hand' }
            }
            return $none
        }
        # The condition has ended. Nothing to give back if we never took anything: the desk is where the
        # person left it, and a switch here would move it for the first time on the way OUT of a rule.
        if (-not $OwnedTaken) {
            return [pscustomobject]@{ Action = 'release'; Mode = ''; Back = ''; RuleIndex = -1
                                      Reason = 'the condition ended, and the switch never went through' }
        }
        return [pscustomobject]@{ Action = 'return'; Mode = [string]$OwnedBack; Back = ''; RuleIndex = -1
                                  Reason = 'the condition ended' }
    }

    for ($i = 0; $i -lt $list.Count; $i++) {
        $rule = $list[$i]
        if (-not (Test-RuleMatch -Rule $rule -Facts $Facts)) { continue }

        # Already in this mode — no reason to take the desk: there would be nothing to give back
        # afterwards, and that is right (the auto game mode made the same decision).
        if ($CurrentMode -eq [string]$rule.mode) { return $none }

        $back = $(if ($rule.back) { [string]$rule.back } else { [string]$CurrentMode })
        if (-not $back) {
            return [pscustomobject]@{ Action = 'blocked'; Mode = [string]$rule.mode; Back = ''; RuleIndex = $i
                                      Reason = 'the current displays match no known mode, so there would be no way back' }
        }
        return [pscustomobject]@{ Action = 'switch'; Mode = [string]$rule.mode; Back = $back; RuleIndex = $i
                                  Reason = (Format-RuleReason -Rule $rule) }
    }
    return $none
}

# The same condition in the person's words, for the rules list in the Settings window. Its own
# function and not a -Language on the one below, because the log's phrasing is terse on purpose
# ("idle for 20 min") and a window has room to say it properly.
function Get-RuleReasonText {
    param($Rule)

    switch ([string]$Rule.when) {
        'process'  { return (Get-Text -Key 'reason.process' -Values @([string]$Rule.process)) }
        'idle'     { return (Get-Text -Key 'reason.idle' -Values @((Format-DurationShort ([int]$Rule.minutes)))) }
        'displays' {
            $names = @(@($Rule.displays) | ForEach-Object { [string]$_ } | Where-Object { $_ })
            if ($names.Count -eq 1) { return (Get-Text -Key 'reason.oneDisplay' -Values @($names[0])) }
            return (Get-Text -Key 'reason.displays' -Values @(($names -join ', ')))
        }
        default    { return [string]$Rule.when }
    }
}

# A line for the LOG: "cs2 is running", "idle for 20 min". English, always - the rules are the
# hardest thing here to work out after the fact, and their lines have to grep.
function Format-RuleReason {
    param($Rule)

    switch ([string]$Rule.when) {
        'process'  { return ('{0} is running' -f [string]$Rule.process) }
        'idle'     { return ('idle for {0} min' -f [int]$Rule.minutes) }
        'displays' {
            $names = @(@($Rule.displays) | ForEach-Object { [string]$_ } | Where-Object { $_ })
            if ($names.Count -eq 1) { return ('{0} is the only display' -f $names[0]) }
            return (($names -join ', ') + ' are connected')
        }
        default    { return [string]$Rule.when }
    }
}

# --- the world changed by itself --------------------------------------------
# After waking from sleep and after a monitor is reconnected, Windows arranges the screens as it
# sees fit: the layout drifts, the taskbar moves to another monitor, the refresh rate drops. The
# desk has to be assembled again.
#
# A pure function: two sets of connected monitors (before and after) + the setting -> what to do.
# The event itself arrives in the tray, and the decision is carried out there too.
#
# What matters is that it is the CONNECTED monitors being compared and not the ones that are on:
# the ones that are on we change ourselves on every switch, and reacting to our own work would
# mean going round in an endless circle.
function Get-ReapplyDecision {
    # $PlugModeMembers is the device paths of the monitors belonging to the onPlug mode. The caller
    # works them out: a mode's membership depends on what is on the desk right now, and this
    # function does not know the state and must not. $null means "we were not told".
    #
    # $VanishedRecently and $SecondsSinceVanish are who went away LAST time and how long ago (see
    # the quarantine below). The time is handed in from outside rather than read off a clock here:
    # with a clock the function could not be tested.
    param($Reapply, $Before, $Now, [string]$LastMode, $PlugModeMembers = $null,
          $VanishedRecently = $null, $SecondsSinceVanish = $null, [int]$QuietSeconds = 10)

    $none = [pscustomobject]@{ Action = 'none'; Mode = ''; Reason = ''; Appeared = @(); Vanished = @() }
    if (-not $Reapply) { return $none }

    $before = @($Before | Where-Object { $_ })
    $now = @($Now | Where-Object { $_ })
    # An empty "before" is the first query of the run; there is nothing to compare against.
    if ($before.Count -eq 0) { return $none }

    $appeared = @($now | Where-Object { $before -notcontains $_ })
    $vanished = @($before | Where-Object { $now -notcontains $_ })

    # From here on "we do nothing" is about specific monitors: the log needs their names, and
    # whoever times the quarantine needs the list of the ones that went away.
    $none = [pscustomobject]@{ Action = 'none'; Mode = ''; Reason = ''
                               Appeared = $appeared; Vanished = $vanished }

    # A monitor appeared. By default we do nothing: a person has just switched it on with the
    # button, and putting it out in reply is a fight with a person. The mode for this case is named
    # explicitly (reapply.onPlug).
    #
    # But even the named mode is applied only when the monitor that appeared BELONGS to it.
    # Otherwise "assemble the desk yourself" would mean "put out everything I switched on off
    # plan": combo:Work has no ASUS in it, and an ASUS switched on with the button would go out a
    # second later — the same fight, only now by configuration. For 'all' the members are
    # everything connected, so there the check changes nothing.
    if ($appeared.Count -gt 0 -and [string]$Reapply.onPlug) {
        $ours = $true
        if ($null -ne $PlugModeMembers) {
            $members = @($PlugModeMembers | Where-Object { $_ })
            $ours = (@($appeared | Where-Object { $members -contains $_ }).Count -gt 0)
        }

        # The quarantine: an appearance soon after a disappearance is not a hand on a cable but an
        # echo. When a monitor leaves the bus, Windows immediately rearranges the desk, and the
        # woken screens arrive as a SEPARATE event a second or two later. Measured 2026-08-28: the
        # ASUS went away at 21:06:43, "a monitor came up" arrived at 21:06:45, and the desk left for
        # combo:Work, which has no ASUS in it.
        #
        # The membership check (above) does not save us from this: a ULTRAGEAR that woke up belongs
        # to combo:Work honestly. The question is not whose monitor it is but who switched it on.
        #
        # One that came back — the very one that went away — is an echo too, and that is not
        # obvious: it looks like "switched off with the button and switched back on", exactly what
        # onPlug exists for. But on 30 August at 19:58 and again at 23:47 a ULTRAGEAR that had been
        # put out by a mode left the bus by itself and came back a SECOND later — that is the
        # monitor's deep sleep — and onPlug applied combo:Work to it and put the ASUS out in the
        # middle of a full-screen window. The gap is visible right through the log: its own flap is
        # 1 s, a real switch-on with the button is 17335 s and 35256 s. A hand does not fit inside
        # QuietSeconds, and if it did — the next press will fire.
        #
        # A disappearance together with an appearance in ONE event the quarantine does NOT touch:
        # that is a cable moved over, and there the new monitor IS the news (see the cable-swapped
        # case in the tests file).
        # $vanished.Count -eq 0 is what makes that last paragraph true: without it the cable swap is
        # only exempt while the quarantine happens to be unarmed, and one unrelated flap a second
        # earlier sends the swap down the onUnplug branch instead.
        #
        # And the elapsed time is bounded from BELOW as well. It comes off the wall clock, which
        # steps backwards on the autumn hour and on any NTP correction; a negative gap satisfies
        # "less than QuietSeconds" just as well as a real echo does, and every genuine press of a
        # button would then be dismissed for as long as the jump lasted.
        #
        # Of $VanishedRecently only whether it holds ANYBODY is asked, never who: the two cases this
        # tells apart — a display's own flap and a hand on its button — are told apart by the gap, and on
        # 30 August the display that came back was the very one that had left.
        $somethingVanishedRecently = (@($VanishedRecently | Where-Object { $_ }).Count -gt 0)
        $echo = ($null -ne $SecondsSinceVanish -and $somethingVanishedRecently -and $vanished.Count -eq 0 -and
                 [double]$SecondsSinceVanish -ge 0 -and [double]$SecondsSinceVanish -lt $QuietSeconds)

        if ($ours -and $echo) {
            # Straight out, rather than through a flag read at the end of the function: an echo means
            # nothing vanished in THIS event, and the only branch between here and there wants the
            # opposite ($vanished.Count -gt 0). The flag could never have been read anywhere else, and it
            # read like a fall-through that had a second destination.
            return [pscustomobject]@{ Action = 'none'; Mode = ''
                                      Reason = 'a display came up right after one went away'
                                      Appeared = $appeared; Vanished = $vanished }
        }
        elseif ($ours) {
            return [pscustomobject]@{ Action = 'mode'; Mode = [string]$Reapply.onPlug
                                      Reason = 'a display was plugged in'
                                      Appeared = $appeared; Vanished = $vanished }
        }
    }

    # A monitor went away. We put back the last chosen mode: Switch-DisplayMode will assemble out
    # of it whatever is left on the desk — the layout and the taskbar included. Nothing new gets
    # switched on in the process.
    if ($vanished.Count -gt 0 -and $Reapply.onUnplug -and $LastMode) {
        return [pscustomobject]@{ Action = 'mode'; Mode = [string]$LastMode
                                  Reason = 'a display went away'
                                  Appeared = $appeared; Vanished = $vanished }
    }

    return $none
}

# --- the shutdown timer -----------------------------------------------------
# "Turn the computer off in an hour." The countdown lives in the tray and dies with it: writing
# it to disk is not allowed — a computer that turns itself off a day after being asked to is
# scarier than any usefulness.

# A pure function: what a person wrote -> minutes. It understands "30", "90m", "1h", "1h30",
# "1:30", "2 hours". Zero means "could not parse it".
function ConvertFrom-DurationText {
    param([string]$Text)

    $t = ([string]$Text).Trim().ToLowerInvariant()
    if (-not $t) { return 0 }

    # The English words are ALWAYS accepted, whatever the window speaks: this box is filled from
    # Format-DurationShort, which now writes the language's own abbreviation, and it is also filled
    # by a person who may well type "1h30" out of habit. Dropping either half breaks somebody.
    $h = 'h|hr|hrs|hour|hours' + (Get-Text -Key 'unit.parse.hours')
    $m = 'm|min|mins|minute|minutes' + (Get-Text -Key 'unit.parse.minutes')

    # Hours with minutes: "1h30", "1h 30m", "1:30".
    if ($t -match ('^(\d+)\s*(?:' + $h + '|:)\s*(\d+)\s*(?:' + $m + ')?$')) {
        return [int]$Matches[1] * 60 + [int]$Matches[2]
    }
    if ($t -match ('^(\d+)\s*(?:' + $h + ')$')) { return [int]$Matches[1] * 60 }
    if ($t -match ('^(\d+)\s*(?:' + $m + ')?$')) { return [int]$Matches[1] }
    return 0
}

# "1 h 05 min", "45 min", "30 s" — for the icon's tooltip and the balloon.
function Format-Duration {
    param([int]$Seconds)

    if ($Seconds -lt 0) { $Seconds = 0 }
    if ($Seconds -lt 60) { return (Get-Text -Key 'unit.seconds' -Values @($Seconds)) }
    $minutes = [int][math]::Floor($Seconds / 60)
    if ($minutes -lt 60) { return (Get-Text -Key 'unit.minutes' -Values @($minutes)) }
    # The minutes are padded to two digits: this one counts down in the tray's tooltip, and a line
    # whose width jumps between "59 min" and "1 h 0 min" twitches once a minute.
    return (Get-Text -Key 'unit.hoursMinutesPadded' -Values @([int][math]::Floor($minutes / 60), ($minutes % 60)))
}

# The same duration, but as it is written on a button: "45 min", "1 h", "1 h 30 min".
# Format-Duration puts "1 h 00 min" — in a countdown that is right (the width of the line does
# not jump every minute), but on a pill and in a menu item the extra zero only gets in the way.
# It reads back through the same ConvertFrom-DurationText.
# --- how long until the displays go dark ------------------------------------
# Windows' own setting, on the page where the desk is arranged: it is the same question as
# "which displays are on", and looking for it in the Control Panel in the middle of setting up
# a desk is a detour. It is NOT in settings.json - this is the system's state, and DeskModes
# only shows it and writes it back.
#
# "From the mains" only. A desktop has no battery, and a laptop with different answers for the
# two cases will have set them in Windows, where both are offered.

# The subsystem and the setting, out of WinNT.h: GUID_VIDEO_SUBGROUP and GUID_VIDEO_POWERDOWN_TIMEOUT.
$script:VideoSubGroupGuid = [guid]'7516b95f-f776-4464-8c53-06167f40cc99'
$script:VideoIdleGuid     = [guid]'3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'

# The active power scheme, or $null. Whoever asks has to free nothing: that is done here.
function Get-ActivePowerScheme {
    $pointer = [IntPtr]::Zero
    try {
        if ([NativePower]::PowerGetActiveScheme([IntPtr]::Zero, [ref]$pointer) -ne 0) { return $null }
        if ($pointer -eq [IntPtr]::Zero) { return $null }
        return [System.Runtime.InteropServices.Marshal]::PtrToStructure($pointer, [type][guid])
    }
    catch { return $null }   # no such API, or it refused: the setting is simply not shown
    finally {
        if ($pointer -ne [IntPtr]::Zero) { [void][NativePower]::LocalFree($pointer) }
    }
}

# How many minutes of nobody working before the displays go dark. 0 is "never", which is what
# Windows stores as a timeout of nought seconds; -1 is "could not be read", and that is not the
# same answer - a window must not offer to change a setting it could not find.
function Get-DisplaySleepMinutes {
    $scheme = Get-ActivePowerScheme
    if ($null -eq $scheme) { return -1 }
    try {
        $seconds = [uint32]0
        $sub = $script:VideoSubGroupGuid
        $setting = $script:VideoIdleGuid
        if ([NativePower]::PowerReadACValueIndex([IntPtr]::Zero, [ref]$scheme, [ref]$sub, [ref]$setting, [ref]$seconds) -ne 0) {
            return -1
        }
        return [int]([math]::Round($seconds / 60.0))
    }
    catch {
        Write-DisplayLog "power: could not read the display timeout - $($_.Exception.Message)"
        return -1
    }
}

# Write it back and apply it. The write alone only changes the stored scheme - it is
# PowerSetActiveScheme that makes Windows pick the change up.
function Set-DisplaySleepMinutes {
    param([int]$Minutes)

    if ($Minutes -lt 0) { return $false }
    $scheme = Get-ActivePowerScheme
    if ($null -eq $scheme) { return $false }
    try {
        $sub = $script:VideoSubGroupGuid
        $setting = $script:VideoIdleGuid
        $code = [NativePower]::PowerWriteACValueIndex([IntPtr]::Zero, [ref]$scheme, [ref]$sub, [ref]$setting,
                                                      [uint32]($Minutes * 60))
        if ($code -ne 0) {
            Write-DisplayLog "power: the display timeout was refused, code $code"
            return $false
        }
        [void][NativePower]::PowerSetActiveScheme([IntPtr]::Zero, [ref]$scheme)
        # Minutes plainly, and not Format-DurationShort: that one speaks the window's language now,
        # and this line is the log's.
        Write-DisplayLog ("power: displays go to sleep after {0}" -f $(if ($Minutes -eq 0) { 'never' } else { "$Minutes min" }))
        return $true
    }
    catch {
        Write-DisplayLog "power: could not write the display timeout - $($_.Exception.Message)"
        return $false
    }
}

# The ready answers, in minutes. Nought is "never" and stands first, the way Windows lists it.
$script:SleepChoices = @(0, 1, 2, 5, 10, 15, 20, 30, 45, 60)

# What one of them is called. A pure function, so the odd value somebody set in Windows itself
# reads the same way as the ready ones.
function Get-SleepChoiceTitle {
    param([int]$Minutes)

    if ($Minutes -le 0) { return (Get-Text -Key 'sleep.never') }
    return Format-DurationShort $Minutes
}

# The list to offer, given what Windows says right now: the ready answers, plus that value if it
# is not one of them, in order. A setting made in Windows itself must not be quietly rounded to
# the nearest thing this list happens to hold.
function Get-SleepChoices {
    param([int]$Current = -1)

    $all = @($script:SleepChoices)
    if ($Current -gt 0 -and $all -notcontains $Current) { $all += $Current }
    return @($all | Sort-Object)
}

function Format-DurationShort {
    param([int]$Minutes)

    if ($Minutes -lt 0) { $Minutes = 0 }
    if ($Minutes -lt 60) { return (Get-Text -Key 'unit.minutes' -Values @($Minutes)) }
    $hours = [int][math]::Floor($Minutes / 60)
    $rest = $Minutes % 60
    if ($rest -eq 0) { return (Get-Text -Key 'unit.hours' -Values @($hours)) }
    return (Get-Text -Key 'unit.hoursMinutes' -Values @($hours, $rest))
}

# The slider steps in the timer window. Not an even step: "in five minutes" and "in eight hours"
# have different costs of being wrong, and an even step makes the small end unmanageable and the
# large end endless. Near the bottom the step is five minutes, further out it grows, and the whole
# range fits into three dozen positions.
$script:TimerSteps = @(5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60,
                       70, 80, 90, 100, 110, 120,
                       150, 180, 210, 240, 300, 360, 420, 480, 600, 720)

# The ceiling is the same twelve hours as the last step. A sleep timer beyond half a day is no
# longer "turn off when I have finished watching": nobody keeps that much deferred shutdown in
# their head, and the computer will turn off all the same.
$script:TimerMaxMinutes = 720

function Get-TimerSteps { return $script:TimerSteps }

# Minutes -> the nearest slider step. The nearest, not the next one down: "1h29" was typed, and
# the slider has to land on an hour and a half rather than on an hour twenty.
function Get-TimerStepIndex {
    param([int]$Minutes)

    $steps = $script:TimerSteps
    $best = 0
    $bestGap = [int]::MaxValue
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $gap = [math]::Abs($steps[$i] - $Minutes)
        if ($gap -lt $bestGap) { $bestGap = $gap; $best = $i }
    }
    return $best
}

function Get-TimerStepMinutes {
    param([int]$Index)

    $steps = $script:TimerSteps
    if ($Index -lt 0) { $Index = 0 }
    if ($Index -ge $steps.Count) { $Index = $steps.Count - 1 }
    return [int]$steps[$Index]
}

# Nudge the value by a step with the wheel or the arrows: five minutes, but along the five-minute
# grid rather than "47 -> 52". We never go below five minutes or above the ceiling.
function Get-TimerNudge {
    param([int]$Minutes, [int]$Step = 5)

    if ($Step -eq 0) { return $Minutes }
    $grid = [int][math]::Round($Minutes / [double]$Step) * $Step
    # Already on the grid — we step; between nodes — we snap to the nearest one in the direction of
    # travel, otherwise the first movement of the wheel would feel like half a step.
    if ($grid -eq $Minutes) { $next = $Minutes + $Step }
    elseif ($Step -gt 0)    { $next = $(if ($grid -gt $Minutes) { $grid } else { $grid + $Step }) }
    else                    { $next = $(if ($grid -lt $Minutes) { $grid } else { $grid + $Step }) }

    if ($next -lt 5) { $next = 5 }
    if ($next -gt $script:TimerMaxMinutes) { $next = $script:TimerMaxMinutes }
    return [int]$next
}

# "at 03:45" and "at 03:45 tomorrow" — when exactly this will happen. A person checks a clock time
# against their own plans faster than a remainder in minutes: "in 340 min" says nothing, "at 06:20
# tomorrow" says everything. The time goes through the invariant culture: our log and our interface
# do not depend on the system's language.
function Get-TimerTargetText {
    param([int]$Minutes, [datetime]$Now = (Get-Date))

    $at = $Now.AddMinutes($Minutes)
    # The clock face itself still goes through InvariantCulture: 24-hour HH:mm is the only form
    # this window has room for, and a locale that would rather write 9:05 PM is not asked.
    $text = Get-Text -Key 'timer.at' -Values @($at.ToString('HH:mm', [cultureinfo]::InvariantCulture))
    if ($at.Date -gt $Now.Date) { $text += ' ' + (Get-Text -Key 'timer.tomorrow') }
    return $text
}

# The shutdown itself. shutdown.exe rather than the API: it alone can both ask programs to close
# and show the reason in the Windows event log.
function Invoke-PowerAction {
    param([ValidateSet('shutdown', 'restart', 'sleep')][string]$Action)

    Write-DisplayLog "power: $Action now"
    switch ($Action) {
        'shutdown' { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -ArgumentList '/s', '/t', '0' -WindowStyle Hidden | Out-Null }
        'restart'  { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -ArgumentList '/r', '/t', '0' -WindowStyle Hidden | Out-Null }
        'sleep'    {
            # Sleep only through SetSuspendState: shutdown.exe /h is hibernation, and /s /hybrid is
            # a shutdown. The first parameter being false is what means "sleep, not hibernate".
            [void][NativePower]::SetSuspendState($false, $true, $false)
        }
    }
}

# --- run at startup ---------------------------------------------------------

function Get-StartupShortcutPath {
    return Join-Path ([Environment]::GetFolderPath('Startup')) 'DeskModes.lnk'
}

function Test-RunAtStartup {
    $path = Get-StartupShortcutPath
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $shell = $null; $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($path)
        $target = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:ToolRoot 'Displays.ps1')
        # Existence alone leaves the toggle enabled after a portable folder is moved. The next
        # Save with the toggle enabled rebuilds the shortcut using the current location.
        return ($shortcut.TargetPath -eq $target -and $shortcut.Arguments -eq $arguments -and
                $shortcut.WorkingDirectory -eq $script:ToolRoot)
    }
    catch { return $false }
    finally {
        foreach ($com in @($shortcut, $shell)) {
            if ($null -ne $com -and [System.Runtime.InteropServices.Marshal]::IsComObject($com)) {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($com)
            }
        }
    }
}

function Set-RunAtStartup {
    param([bool]$Enabled)

    $lnk = Get-StartupShortcutPath
    if (-not $Enabled) {
        if (Test-Path $lnk) { Remove-Item $lnk -Force }
        Write-DisplayLog 'startup: disabled'
        return
    }

    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sc.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:ToolRoot 'Displays.ps1')
    $sc.WorkingDirectory = $script:ToolRoot
    $icon = Join-Path $script:ToolRoot 'app.ico'
    if (Test-Path $icon) { $sc.IconLocation = $icon + ',0' }
    else { $sc.IconLocation = (Join-Path $env:SystemRoot 'System32\DisplaySwitch.exe') + ',0' }
    $sc.WindowStyle = 7
    $sc.Description = 'DeskModes - display switcher in the notification area'
    $sc.Save()
    Write-DisplayLog 'startup: enabled'
}
