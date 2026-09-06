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
