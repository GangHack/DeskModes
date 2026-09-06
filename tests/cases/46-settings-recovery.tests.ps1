# Every recovery scenario has its own settings path: backup files from another case must not help it pass.
function Invoke-WithRecoverySettings {
    param([scriptblock]$Body)
    $oldSettingsPath = $script:SettingsFile
    $script:SettingsFile = Join-Path $script:TestDir ('recovery-' + [guid]::NewGuid().ToString('N') + '.json')
    try { & $Body }
    finally { $script:SettingsFile = $oldSettingsPath }
}

Test-Case 'settings recovery: each successful save keeps the previous complete settings as backup' {
    Invoke-WithRecoverySettings {
        $first = Get-DefaultSettings
        $first.primary = 'First panel'
        Assert-True (Save-DisplaySettings -Settings $first) 'the initial save succeeds'
        $firstBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:SettingsFile))
        $second = Get-DefaultSettings
        $second.primary = 'Second panel'
        Assert-True (Save-DisplaySettings -Settings $second) 'the next save succeeds'
        $backup = $script:SettingsFile + '.bak'
        Assert-True (Test-Path -LiteralPath $backup) 'the last good version has a backup'
        if (Test-Path -LiteralPath $backup) {
            Assert-Equal $firstBytes ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backup))) 'the backup retains the previous bytes'
        }
        Assert-Equal 'Second panel' (Read-SettingsFile).primary 'the new settings are current'
    }
}

Test-Case 'settings recovery: damaged primary settings recover the backup and retain the damaged bytes' {
    Invoke-WithRecoverySettings {
        $damaged = '{ interrupted while saving'
        Set-Content -LiteralPath $script:SettingsFile -Value $damaged -Encoding UTF8
        $damagedBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:SettingsFile))
        Set-Content -LiteralPath ($script:SettingsFile + '.bak') -Value '{ "primary": "Recovered panel", "notifications": false }' -Encoding UTF8
        $settings = Get-DisplaySettings
        Assert-Equal 'Recovered panel' $settings.primary 'the saved preference is recovered'
        Assert-True (-not $settings.notifications) 'false values survive recovery'
        $bad = $script:SettingsFile + '.bad'
        Assert-True (Test-Path -LiteralPath $bad) 'the damaged file remains available for inspection'
        if (Test-Path -LiteralPath $bad) {
            Assert-Equal $damagedBytes ([Convert]::ToBase64String([IO.File]::ReadAllBytes($bad))) 'the damaged content is retained exactly'
        }
    }
}

Test-Case 'settings recovery: valid current settings take precedence over an older backup' {
    Invoke-WithRecoverySettings {
        Set-Content -LiteralPath $script:SettingsFile -Value '{ "primary": "Current panel" }' -Encoding UTF8
        Set-Content -LiteralPath ($script:SettingsFile + '.bak') -Value '{ "primary": "Old panel" }' -Encoding UTF8
        Assert-Equal 'Current panel' (Read-SettingsFile).primary 'a healthy primary wins'
    }
}

Test-Case 'settings recovery: two damaged copies fall back to defaults without throwing' {
    Invoke-WithRecoverySettings {
        Set-Content -LiteralPath $script:SettingsFile -Value '{ damaged primary' -Encoding UTF8
        Set-Content -LiteralPath ($script:SettingsFile + '.bak') -Value '{ damaged backup' -Encoding UTF8
        $settings = Get-DisplaySettings
        Assert-Equal '' $settings.primary 'no preference can be recovered'
        Assert-True $settings.notifications 'the default settings remain usable'
    }
}

Test-Case 'settings recovery: a refused save preserves both last good files' {
    Invoke-WithRecoverySettings {
        Set-Content -LiteralPath $script:SettingsFile -Value '{ "primary": "Current panel" }' -Encoding UTF8
        $backup = $script:SettingsFile + '.bak'
        Set-Content -LiteralPath $backup -Value '{ "primary": "Older panel" }' -Encoding UTF8
        $currentBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:SettingsFile))
        $backupBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($backup))
        # Readers still work, but both overwriting and replacement are refused by the operating system.
        $held = [IO.File]::Open($script:SettingsFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $changed = Get-DefaultSettings
            $changed.primary = 'Unsaved panel'
            Assert-True (-not (Save-DisplaySettings -Settings $changed)) 'failure is reported without an exception'
            Assert-Equal $currentBytes ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:SettingsFile))) 'the active file remains complete'
            Assert-Equal $backupBytes ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backup))) 'failure cannot advance the backup'
        }
        finally { $held.Dispose() }
    }
}

Test-Case 'settings recovery: saving after corruption does not replace a valid backup with damaged JSON' {
    Invoke-WithRecoverySettings {
        Set-Content -LiteralPath $script:SettingsFile -Value '{ damaged primary' -Encoding UTF8
        $backup = $script:SettingsFile + '.bak'
        Set-Content -LiteralPath $backup -Value '{ "primary": "Last good panel" }' -Encoding UTF8
        $backupBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($backup))
        $changed = Get-DefaultSettings
        $changed.primary = 'New panel'
        Assert-True (Save-DisplaySettings -Settings $changed) 'a healthy replacement can be saved'
        Assert-Equal $backupBytes ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backup))) 'the last recoverable settings remain recoverable'
        Assert-Equal 'New panel' (Read-SettingsFile).primary 'the replacement is current'
    }
}
