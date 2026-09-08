# Only a file under the test directory stands in for the startup shortcut; COM is replaced in scope.
function Invoke-StartupShortcutFixture {
    param([string]$ChangedField = '', [string]$ChangedValue = '', [switch]$Missing, [switch]$Unreadable)

    $script:StartupFixturePath = Join-Path $script:TestDir ('startup-' + [guid]::NewGuid().ToString('N') + '.lnk')
    if (-not $Missing) { [IO.File]::WriteAllText($script:StartupFixturePath, 'fictional shortcut') }
    $script:StartupFixtureUnreadable = [bool]$Unreadable
    $script:StartupFixtureShortcut = [pscustomobject]@{
        TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        Arguments = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:ToolRoot 'Displays.ps1'))
        WorkingDirectory = $script:ToolRoot
    }
    if ($ChangedField) { $script:StartupFixtureShortcut.$ChangedField = $ChangedValue }
    $script:StartupFixtureShell = [pscustomobject]@{}
    $script:StartupFixtureShell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {
        param([string]$Path)
        if ($Path -ne $script:StartupFixturePath) { throw 'The test attempted to open a real shortcut.' }
        if ($script:StartupFixtureUnreadable) { throw 'The fictional shortcut cannot be read.' }
        return $script:StartupFixtureShortcut
    }
    function Get-StartupShortcutPath { return $script:StartupFixturePath }
    function New-Object {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped COM fake prevents tests from opening Windows startup shortcuts.')]
        param([string]$ComObject)
        if ($ComObject -ne 'WScript.Shell') { throw 'The test received an unexpected COM request.' }
        return $script:StartupFixtureShell
    }
    return (Test-RunAtStartup)
}

Test-Case 'startup shortcut: the current PowerShell command and working directory count as enabled' {
    Assert-True (Invoke-StartupShortcutFixture) 'the current launch command is enabled'
}

Test-Case 'startup shortcut: a missing shortcut counts as disabled' {
    Assert-True (-not (Invoke-StartupShortcutFixture -Missing)) 'nothing is configured to launch'
}

Test-Case 'startup shortcut: a different executable does not count as this application being enabled' {
    $stale = Join-Path $script:TestDir 'other-program.exe'
    Assert-True (-not (Invoke-StartupShortcutFixture -ChangedField 'TargetPath' -ChangedValue $stale)) 'the shortcut must launch Windows PowerShell'
}

Test-Case 'startup shortcut: arguments pointing at a moved folder count as disabled' {
    $staleScript = Join-Path $script:TestDir 'old-folder/Displays.ps1'
    $stale = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $staleScript
    Assert-True (-not (Invoke-StartupShortcutFixture -ChangedField 'Arguments' -ChangedValue $stale)) 'an old script path cannot silently look enabled'
}

Test-Case 'startup shortcut: a stale working directory counts as disabled' {
    $stale = Join-Path $script:TestDir 'old-folder'
    Assert-True (-not (Invoke-StartupShortcutFixture -ChangedField 'WorkingDirectory' -ChangedValue $stale)) 'the working directory must follow the portable folder'
}

Test-Case 'startup shortcut: an unreadable shortcut counts as disabled without breaking settings' {
    Assert-True (-not (Invoke-StartupShortcutFixture -Unreadable)) 'an unreadable shortcut cannot be verified as enabled'
}

Test-Case 'settings Save: a startup failure keeps the external edit dirty and retries it' {
    $script:SavedSettings = $null
    $script:StartupCalls = 0
    $script:StartupSucceeds = $false
    $script:SettingsWarnings = @()
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    $ui.StartupWasEnabled = $false
    $ui.StartupBox.IsChecked = $true
    function Save-DisplaySettings { param($Settings) $script:SavedSettings = $Settings; return $true }
    function Set-RunAtStartup {
        param([bool]$Enabled)
        $script:StartupCalls++
        if (-not $script:StartupSucceeds) { throw 'fictional Startup folder refusal' }
    }
    function Save-UiSleepMinutes { param($Ui) return $true }
    function Show-SettingsWarning { param([string]$Text, $Owner) $script:SettingsWarnings += $Text }

    try {
        Assert-True (Invoke-SettingsSave -Ui $ui) 'settings.json is still a successful save'
        Assert-True ($script:SavedSettings -eq $ui.Result) 'the result is the object already committed'
        Assert-Equal 1 $script:StartupCalls 'the requested startup change was attempted once'
        Assert-Equal (Get-Text -Key 'settings.startupFailed') $script:SettingsWarnings[0] 'the failure is visible'
        Assert-True (Test-UiEdited -Ui $ui) 'the unconfirmed external choice remains dirty'

        $script:StartupSucceeds = $true
        Assert-True (Invoke-SettingsSave -Ui $ui) 'the same open window retries successfully'
        Assert-Equal 2 $script:StartupCalls 'the external change was attempted again'
        Assert-Equal $true ([bool]$ui.StartupWasEnabled) 'the confirmed state advances'
        Assert-Equal $false (Test-UiEdited -Ui $ui) 'the successful retry becomes the baseline'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'settings Save: an unchanged startup choice is not rewritten' {
    $script:StartupCalls = 0
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    $ui.StartupWasEnabled = $true
    $ui.StartupBox.IsChecked = $true
    function Save-DisplaySettings { param($Settings) return $true }
    function Set-RunAtStartup { param([bool]$Enabled) $script:StartupCalls++ }
    function Save-UiSleepMinutes { param($Ui) return $true }

    try {
        Assert-True (Invoke-SettingsSave -Ui $ui) 'the settings save succeeds'
        Assert-Equal 0 $script:StartupCalls 'the current valid shortcut is left alone'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'settings Save: a refused sleep timeout stays dirty until a retry succeeds' {
    $script:SleepCalls = 0
    $script:SleepSucceeds = $false
    $script:SettingsWarnings = @()
    $ui = New-DialogUi -Settings (Get-DefaultSettings)
    $ui.StartupWasEnabled = $false
    $ui.StartupBox.IsChecked = $false
    Set-UiSleepMinutes -Ui $ui -Minutes 5
    $ui.SleepBox.SelectedItem = @($ui.SleepBox.Items | Where-Object { [int]$_.Tag -eq 15 })[0]
    function Save-DisplaySettings { param($Settings) return $true }
    function Set-DisplaySleepMinutes { param([int]$Minutes) $script:SleepCalls++; return $script:SleepSucceeds }
    function Show-SettingsWarning { param([string]$Text, $Owner) $script:SettingsWarnings += $Text }

    try {
        Assert-True (Invoke-SettingsSave -Ui $ui) 'the settings file still commits'
        Assert-Equal 1 $script:SleepCalls 'Windows was asked once'
        Assert-Equal 5 ([int]$ui.SleepMinutes) 'the confirmed timeout remains old'
        Assert-True (Test-UiEdited -Ui $ui) 'the refused timeout remains dirty'

        $script:SleepSucceeds = $true
        Assert-True (Invoke-SettingsSave -Ui $ui) 'the same window retries the timeout'
        Assert-Equal 2 $script:SleepCalls 'Windows was asked again'
        Assert-Equal 15 ([int]$ui.SleepMinutes) 'the confirmed timeout advances'
        Assert-Equal $false (Test-UiEdited -Ui $ui) 'the successful retry becomes clean'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'settings dialog: reopening activates the existing modal window and keeps its result' {
    $settings = Get-DefaultSettings
    $ui = New-DialogUi -Settings $settings
    $ui.Result = $settings
    try {
        $got = Show-SettingsDialog -State @() -Settings $settings -Page 'about'
        Assert-True ($got -eq $settings) 'no second modal lifetime replaces the saved result'
        Assert-True ($script:ActiveUi -eq $ui) 'the original window remains active'
        Assert-Equal 'about' ([string]$ui.Page) 'the explicitly requested page is honored'
    }
    finally { $ui.Window.Close(); $script:ActiveUi = $null }
}

Test-Case 'settings dialog: failed setup releases the half-built active window' {
    $script:ActiveUi = $null
    $failed = $false
    function Test-RunAtStartup { return $false }
    function Get-DisplaySleepMinutes { throw 'fictional power query failure' }

    try { [void](Show-SettingsDialog -State $script:DlgState -Settings (Get-DefaultSettings)) }
    catch { $failed = $true }

    Assert-True $failed 'the setup failure still reaches the caller'
    Assert-Null $script:ActiveUi 'a later tray double-click can build a fresh window'
}
