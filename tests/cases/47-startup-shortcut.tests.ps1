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

Test-Case 'settings Save: a startup failure warns but returns the settings already committed' {
    $script:SavedSettings = $null
    $script:StartupCalls = 0
    $script:SettingsWarning = ''
    $window = [pscustomobject]@{}
    $window | Add-Member -MemberType ScriptMethod -Name ShowDialog -Value {
        $script:SettingsSaveUi.StartupBox.IsChecked = $true
        return $true
    }
    $window | Add-Member -MemberType ScriptMethod -Name Close -Value { }
    $updated = Get-DefaultSettings
    $updated.language = 'ru'
    $script:SettingsSaveUi = [pscustomobject]@{
        Window = $window; Result = $updated
        StartupBox = [pscustomobject]@{ IsChecked = $true }
    }

    function Get-DialogModes { param($State, $Settings) return @() }
    function New-SettingsWindow { param($Modes, $Settings, $State, $Positions, [string]$Page) return $script:SettingsSaveUi }
    function Test-RunAtStartup { return $false }
    function Get-DisplaySleepMinutes { return 10 }
    function Set-UiSleepMinutes { param($Ui, [int]$Minutes) }
    function Set-UiBaseline { param($Ui) }
    function Update-UiFooter { param($Ui) }
    function Save-DisplaySettings { param($Settings) $script:SavedSettings = $Settings; return $true }
    function Set-RunAtStartup { param([bool]$Enabled) $script:StartupCalls++; throw 'fictional Startup folder refusal' }
    function Save-UiSleepMinutes { param($Ui) return $true }
    function Show-SettingsWarning { param([string]$Text) $script:SettingsWarning = $Text }

    try {
        [void](Initialize-Language -Code 'ru')
        $got = Show-SettingsDialog -State @() -Settings (Get-DefaultSettings)
        Assert-True ($got -eq $updated) 'the tray receives the object written to settings.json'
        Assert-True ($script:SavedSettings -eq $updated) 'the settings were committed before the shortcut failed'
        Assert-Equal 1 $script:StartupCalls 'the requested startup change was attempted once'
        Assert-Equal (Get-Text -Key 'settings.startupFailed') $script:SettingsWarning 'the warning follows the active language'
        Assert-True ($script:SettingsWarning -notmatch '^\[') 'the warning key exists'
    }
    finally { [void](Initialize-Language -Code 'en') }
}

Test-Case 'settings Save: an unchanged startup choice is not rewritten' {
    $script:StartupCalls = 0
    $window = [pscustomobject]@{}
    $window | Add-Member -MemberType ScriptMethod -Name ShowDialog -Value { return $true }
    $window | Add-Member -MemberType ScriptMethod -Name Close -Value { }
    $updated = Get-DefaultSettings
    $script:SettingsSaveUi = [pscustomobject]@{
        Window = $window; Result = $updated
        StartupBox = [pscustomobject]@{ IsChecked = $true }
    }

    function Get-DialogModes { param($State, $Settings) return @() }
    function New-SettingsWindow { param($Modes, $Settings, $State, $Positions, [string]$Page) return $script:SettingsSaveUi }
    function Test-RunAtStartup { return $true }
    function Get-DisplaySleepMinutes { return 10 }
    function Set-UiSleepMinutes { param($Ui, [int]$Minutes) }
    function Set-UiBaseline { param($Ui) }
    function Update-UiFooter { param($Ui) }
    function Save-DisplaySettings { param($Settings) return $true }
    function Set-RunAtStartup { param([bool]$Enabled) $script:StartupCalls++ }
    function Save-UiSleepMinutes { param($Ui) return $true }

    $got = Show-SettingsDialog -State @() -Settings (Get-DefaultSettings)
    Assert-True ($got -eq $updated) 'the committed settings still return'
    Assert-Equal 0 $script:StartupCalls 'the current valid shortcut is left alone'
}
