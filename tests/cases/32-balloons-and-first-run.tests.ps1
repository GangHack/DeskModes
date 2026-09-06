# --- the balloons and the first run -----------------------------------------
# Notifications turned off mute the background messages — and one day they muted the answer to a click:
# "About DeskModes" is clicked and nothing happens. The fork (switch -Always) is pure logic, and there
# is no reason to test it on a live desk.
#
# A person sees the first run exactly once, and live it cannot be repeated without deleting the settings
# — and that is the one path nobody ever reopens by hand.
#
# Both Show-Balloon and the body of the startup timer come out of Displays.ps1 by parsing it — see
# Get-TrayFunctionSource in tests\fakes.ps1 for why. The first-run block itself is not a function but
# top-level script code, so it is read rather than run.

Write-Host ''
Write-Host 'the balloons and the first run' -ForegroundColor White

# ToolTipIcon comes from WinForms: Show-Balloon takes the icon out of it by the kind's name.
Add-Type -AssemblyName System.Windows.Forms

$script:TrayAst = Get-TrayAst

$balloon = @($script:TrayAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq 'Show-Balloon' }, $true))
if ($balloon.Count -ne 1) { throw "expected exactly one Show-Balloon in Displays.ps1, found $($balloon.Count)" }
. ([scriptblock]::Create($balloon[0].Extent.Text))

# The startup timer's body is not a function but a block handed to .add_Tick(). We take the StartupTimer
# tick specifically: there are four ticks in the file, and the other three are about something else.
$startupTick = @($script:TrayAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $n.Member.Extent.Text -eq 'add_Tick' }, $true) |
    Where-Object { $_.Expression.Extent.Text -match 'StartupTimer' })
if ($startupTick.Count -ne 1) { throw "expected exactly one StartupTimer tick in Displays.ps1, found $($startupTick.Count)" }
# .EndBlock rather than the block itself: a block's Extent is "{ … }" braces included, and Create would
# have assembled a script-block literal out of it rather than a body.
$script:StartupTick = [scriptblock]::Create($startupTick[0].Arguments[0].ScriptBlock.EndBlock.Extent.Text)

$trayMouseClick = @($script:TrayAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $n.Member.Extent.Text -eq 'add_MouseClick' }, $true))
if ($trayMouseClick.Count -ne 1) { throw "expected exactly one tray MouseClick handler in Displays.ps1, found $($trayMouseClick.Count)" }
$script:TrayMouseClick = [scriptblock]::Create($trayMouseClick[0].Arguments[0].ScriptBlock.EndBlock.Extent.Text)

# --- the environment these two pieces expect around themselves ---------------

# The tray icon. Not a real NotifyIcon: a visible one would show a balloon over somebody else's screen,
# and an invisible one would throw on ShowBalloonTip.
$script:tray = New-Object psobject -Property @{
    BalloonTipIcon = $null; BalloonTipTitle = ''; BalloonTipText = ''; Shown = 0
}
$script:tray | Add-Member -MemberType ScriptMethod -Name ShowBalloonTip -Value { $this.Shown++ }

$script:AppName = 'DeskModes'
$script:TimerStopped = $false
$script:SettingsOpened = $false
$script:StartupTimer = New-Object psobject
$script:StartupTimer | Add-Member -MemberType ScriptMethod -Name Stop -Value { $script:TimerStopped = $true }

# The tick's neighbours: the mode restore itself is tested in 16-restore-on-start, and here it only has
# to stay out of the way.
function Invoke-StartupRestore { }
function Open-SettingsWindow { $script:SettingsOpened = $true }
function Optimize-TrayMemory { }

# Show-Balloon reads the settings the way the whole tray does — through the function, never through the
# variable. Ours is declared here rather than borrowed from an earlier file of cases: a test that reads
# somebody else's scene breaks the day that scene is edited.
function Get-ActiveSettings { return $script:Settings }

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

# --- what gets muted and what does not --------------------------------------

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
    Show-Balloon 'DeskModes' 'DeskModes 1.0.0 - Windows 26200, PowerShell 5.1' -Always
    Assert-Equal 1 $script:tray.Shown 'a press always answers'
}

Test-Case 'balloon: a failure is never silenced' {
    Set-BalloonScene -Notifications $false
    Show-Balloon 'Failed' 'Windows refused the configuration.' 'Error'
    Assert-Equal 1 $script:tray.Shown 'shown'
}

Test-Case 'balloon: -Always is a licence for that one message, not for the rest' {
    # Turn the condition round and the ordinary "switched" messages will push through with notifications
    # off — which is exactly what the person turned off.
    Set-BalloonScene -Notifications $false
    Show-Balloon 'Displays switched' 'Both work displays are up.'
    Show-Balloon 'DeskModes' 'DeskModes 1.0.0' -Always
    Show-Balloon 'Displays switched' 'Both work displays are up.'
    Assert-Equal 1 $script:tray.Shown 'only the answer to the press got through'
}

# A rule rather than an example: "clicked it and nothing happened" is invisible in the code, and it went
# out that way once. We look at every Show-Balloon right inside the add_Click handlers — each one has to
# carry -Always or a Kind of its own that does not get muted.
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

# --- the first run ----------------------------------------------------------

Test-Case 'startup: the welcome belongs to the run that had to create the settings' {
    # The tell is the ABSENCE of the settings file: an empty shortcut list is not one, otherwise a person
    # who cleared every binding would get the welcome every time.
    Assert-True ($script:TrayAst.Extent.Text -match '(?m)^\$script:FirstRun\s*=\s*\$false') 'the flag is off by default'

    $ifs = @($script:TrayAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))
    $creates = @($ifs | Where-Object { $_.Clauses[0].Item1.Extent.Text -match 'Test-Path \$script:SettingsFile' })
    Assert-Equal 1 $creates.Count 'one block decides that this is a first run'
    if ($creates.Count -eq 1) {
        Assert-True ($creates[0].Extent.Text -match '\$script:FirstRun\s*=\s*\$true') 'and it is the one that raises the flag'
    }
}

Test-Case 'startup: a first run that could not save the settings says so' {
    # In a folder we may not write to — Program Files, a read-only share — the old line logged "assigned
    # the default shortcuts" over a file that was never created. And since a first run is told by the
    # ABSENCE of that file, every start after it was a first run again: welcome balloon, Settings window,
    # for good. Read rather than run: this block is top-level script code, not a function.
    $ifs = @($script:TrayAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))
    $creates = @($ifs | Where-Object { $_.Clauses[0].Item1.Extent.Text -match 'Test-Path \$script:SettingsFile' })
    Assert-Equal 1 $creates.Count 'the block that decides this is a first run'
    if ($creates.Count -eq 1) {
        $text = $creates[0].Extent.Text
        Assert-True ($text -notmatch '\[void\]\(Save-DisplaySettings') 'the answer is not thrown away'
        Assert-True ($text -match 'if \(Save-DisplaySettings') 'what goes in the log depends on it'
        Assert-True ($text -match 'could not be saved') 'and a refusal is said in words'
    }
}

Test-Case 'startup: the first run says where the menu is and opens Settings itself' {
    # The welcome is shown from the startup timer, once the message loop is already running: before it a
    # balloon does not appear at all, and the Settings window would have stood across the startup. Which
    # is why the tick is run whole rather than read with the eye.
    Invoke-StartupTick -First $true
    Assert-True $script:TimerStopped 'the one-shot timer stopped itself'
    Assert-Equal 1 $script:tray.Shown 'one balloon'
    Assert-True ($script:tray.BalloonTipText -like '*Left-click*') 'which says how Settings opens'
    Assert-True ($script:tray.BalloonTipText -like '*right-click*') 'and where the display menu is'
    Assert-True $script:SettingsOpened 'and the window opened by itself'
}

Test-Case 'startup: every later start is silent' {
    # A Settings window that opens on every login to Windows is the sort of thing a tool gets deleted over.
    Invoke-StartupTick -First $false
    Assert-Equal 0 $script:tray.Shown 'no welcome'
    Assert-True (-not $script:SettingsOpened) 'no window'
    Assert-True $script:TimerStopped 'the timer still stops'
}

Test-Case 'startup: a Settings window that will not open does not take the start down' {
    # Everything the tray does at startup happens before Application.Run: an exception from here is an icon
    # that never appeared at all.
    function Open-SettingsWindow { throw 'no display device' }
    Invoke-StartupTick -First $true
    Assert-Equal 1 $script:tray.Shown 'the balloon still went out'
    Assert-True $script:TimerStopped 'and the start finished'
}

Test-Case 'tray: left click opens Settings and right click remains the context menu' {
    $script:SettingsOpened = $false
    & $script:TrayMouseClick $null ([pscustomobject]@{ Button = [System.Windows.Forms.MouseButtons]::Left })
    Assert-True $script:SettingsOpened 'left click opens Settings'

    $script:SettingsOpened = $false
    & $script:TrayMouseClick $null ([pscustomobject]@{ Button = [System.Windows.Forms.MouseButtons]::Right })
    Assert-True (-not $script:SettingsOpened) 'right click is left to NotifyIcon and its ContextMenuStrip'
}
