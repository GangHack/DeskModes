# The packer is exercised whole in an isolated folder: a rejected build must leave no distributable.
# Git is shadowed at the command boundary so a failed status can be reproduced without breaking a repo.
function Invoke-PackFixture {
    param([int]$StatusExitCode = 0, [string]$Pending = '', [switch]$Release)

    $fixtureRoot = Join-Path $script:TestDir ('pack-fixture-' + [guid]::NewGuid().ToString('N'))
    $fixtureTools = Join-Path $fixtureRoot 'tools'
    $fixtureOut = Join-Path $fixtureRoot 'out'
    [void](New-Item -ItemType Directory -Path $fixtureTools)
    Copy-Item -LiteralPath (Join-Path $root 'tools/pack.ps1') -Destination (Join-Path $fixtureTools 'pack.ps1')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'DisplayCore.ps1'), "`$script:Version = '9.8.7'`r`n", (New-Object Text.UTF8Encoding $true))
    $changelog = "# Changelog`r`n`r`n## Unreleased`r`n`r`n$Pending`r`n`r`n## 9.8.7 - 2026-09-06`r`n`r`n- Released fixture behavior.`r`n"
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'CHANGELOG.md'), $changelog, (New-Object Text.UTF8Encoding $false))

    # This unique local is inherited by the fake across the packer's separate script scope.
    $packFixtureStatusCode = $StatusExitCode
    function git {
        if ($args -contains 'ls-files') {
            $global:LASTEXITCODE = 0
            return @('DisplayCore.ps1', 'CHANGELOG.md', 'tools/pack.ps1')
        }
        if ($args -contains 'status') {
            $global:LASTEXITCODE = $packFixtureStatusCode
            return
        }
        throw 'The pack fixture received an unexpected git command.'
    }

    # Native commands publish LASTEXITCODE outside their function call scope. Preserve the caller's value.
    $oldExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $oldExitValue = if ($oldExitCode) { $oldExitCode.Value } else { $null }
    $problem = ''
    $packArgs = @{ OutDir = $fixtureOut; NotesOut = (Join-Path $fixtureOut 'notes.md') }
    if ($Release) { $packArgs.ExpectVersion = '9.8.7' }
    try { & (Join-Path $fixtureTools 'pack.ps1') @packArgs 6>$null | Out-Null }
    catch { $problem = $_.Exception.Message }
    finally {
        if ($oldExitCode) { $global:LASTEXITCODE = $oldExitValue }
        else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{
        Problem = $problem
        Zip = (Join-Path $fixtureOut 'DeskModes-9.8.7.zip')
        Hash = (Join-Path $fixtureOut 'DeskModes-9.8.7.zip.sha256')
        Notes = (Join-Path $fixtureOut 'notes.md')
    }
}

Test-Case 'release packing: a clean fixture builds the archive hash and matching notes' {
    $result = Invoke-PackFixture -Release
    Assert-Equal '' $result.Problem 'a dated matching release with no pending changes is accepted'
    Assert-True (Test-Path -LiteralPath $result.Zip) 'the archive exists'
    Assert-True (Test-Path -LiteralPath $result.Hash) 'its hash exists'
    Assert-True (Test-Path -LiteralPath $result.Notes) 'its release notes exist'
}

Test-Case 'release packing: failed git status refuses before any release artifact is written' {
    $result = Invoke-PackFixture -StatusExitCode 128
    Assert-True ([bool]$result.Problem) 'a failed cleanliness check cannot be treated as a clean tree'
    Assert-True (-not (Test-Path -LiteralPath $result.Zip)) 'no archive is produced'
    Assert-True (-not (Test-Path -LiteralPath $result.Hash)) 'no hash is produced'
    Assert-True (-not (Test-Path -LiteralPath $result.Notes)) 'no release notes are produced'
}

Test-Case 'release packing: a tagged version cannot omit pending changelog changes' {
    $result = Invoke-PackFixture -Release -Pending '- New behavior awaiting a version.'
    Assert-True ([bool]$result.Problem) 'release notes must account for every pending change'
    Assert-True (-not (Test-Path -LiteralPath $result.Zip)) 'the refusal happens before packing'
}

Test-Case 'release packing: local candidates may carry pending changelog changes' {
    $result = Invoke-PackFixture -Pending '- New behavior awaiting a version.'
    Assert-Equal '' $result.Problem 'local candidates can be reviewed before the release is dated'
    Assert-True (Test-Path -LiteralPath $result.Zip) 'the candidate archive is built'
}
