#Requires -Version 5.1

<#
    tests\run-tests.ps1 — the test suite's entry point. Our own, without Pester.

    Why without Pester: PowerShell 5.1 comes with an ancient 3.4 preinstalled, and installing a newer
    one goes against the project's philosophy ("nothing is installed on your system, the folder can
    just be deleted"). What is needed here is Assert and a non-zero exit code; everything else is a
    dependency we do not want.

    This file only sets a run up: it redirects the log, pins the interface to English, dot-sources
    the code under test, walks cases/ and prints the total. The checks themselves live alongside:

        framework.ps1          Test-Case and the assertions
        fakes.ps1              the fakes that more than one group needs
        cases/NN-name.tests.ps1 one file per group; the prefix fixes the order of the output

    The tests touch ONLY pure functions: not one of them changes the monitors and not one writes into
    the real settings.json, the log or the diary — every path is redirected to files in a temporary
    folder. A run takes seconds.

        .\tests\run-tests.ps1                 all of them
        .\tests\run-tests.ps1 -Only hotkey    only tests whose name contains the string
        .\tests\run-tests.ps1 -File 12        only that file of cases

    Exit code: 0 — everything green, 1 — there are failures.
#>
[CmdletBinding()]
param(
    [string]$Only = '',
    [string]$File = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# The log is redirected BEFORE the dot-source: DisplayCore writes into it while it is being loaded
# (log rotation, type compilation), and replacing $script:LogFile afterwards was too late — those
# lines went into the real last-run.log.
$script:LogDir = Join-Path $env:TEMP ('deskmodes-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:LogDir | Out-Null
$env:DESKMODES_LOG_FILE = Join-Path $script:LogDir 'last-run.log'

# The framework comes before the code under test: Test-Case and the assertions are needed by
# everybody, and the dot-source puts them in THIS file's scope, where the counters and $Only live.
. (Join-Path $PSScriptRoot 'framework.ps1')

# The entry points must not be dot-sourced: Displays.ps1 brings the whole application up when it is
# loaded. We take core, WindowLayout and the dialog, while Resolve-ModeKey out of Set-Display.ps1 is
# pulled in by the file of cases that needs it
# (cases/11-cli-mode-key.tests.ps1).

. (Join-Path $root 'DisplayCore.ps1')
. (Join-Path $root 'WindowLayout.ps1')
. (Join-Path $root 'Activity.ps1')
. (Join-Path $root 'SettingsDialog.ps1')

# English, pinned, whatever language the machine is in. Almost every assertion here is a sentence
# the window would show, and on Russian Windows an unpinned run would fail on all of them at once
# — which reads like the code is broken rather than like the test forgot to say what it wanted.
# A case that is ABOUT another language switches and switches back (cases/42-language.tests.ps1).
[void](Initialize-Language -Code 'en')

# The real settings.json is touched by NOT ONE test.
$script:TestDir = $script:LogDir   # the same one, created above for the log's sake
$script:SettingsFile = Join-Path $script:TestDir 'settings.json'
$script:WindowStateFile = Join-Path $script:TestDir 'window-state.json'
$script:LastModeFile = Join-Path $script:TestDir 'last-mode.json'
$script:ModeCacheFile = Join-Path $script:TestDir 'display-modes.json'
# The roster of monitors ever seen. Redirected like the rest: a case that learns an invented desk
# must not teach the real one, and the real file names the monitors on this actual machine.
$script:KnownDisplaysFile = Join-Path $script:TestDir 'known-displays.json'
# Where the Settings window stood: written when a window closes, and every test closes its window.
$script:UiStateFile = Join-Path $script:TestDir 'ui-state.json'
# The tests do not touch the real diary either: it is about a person, and mixing invented days into
# it is not allowed.
$script:ActivityFile = Join-Path $script:TestDir 'activity.json'

# The fakes come after the code under test: New-TestSettings is built on Get-DefaultSettings, and
# $script:DlgState on the real Get-DialogModes.
. (Join-Path $PSScriptRoot 'fakes.ps1')

Write-Host ''
Write-Host 'DeskModes - tests' -ForegroundColor Cyan
Write-Host ''

# --- the cases --------------------------------------------------------------
# The order of the output is held by the numeric prefix of the file name rather than by the order of
# the file-system walk: the sort by name is explicit, so that a run reads the same on any machine.

$cases = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'cases') -Filter '*.tests.ps1' |
           Sort-Object Name)
if ($File) { $cases = @($cases | Where-Object { $_.Name -like "*$File*" }) }
if ($cases.Count -eq 0) {
    Write-Host ("No case files matched '{0}'." -f $File) -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

foreach ($case in $cases) { . $case.FullName }

# --- the total --------------------------------------------------------------

Remove-Item -LiteralPath $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\DESKMODES_LOG_FILE -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failed -eq 0) {
    Write-Host ("All good: {0} assertions passed." -f $script:Total) -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host ("FAILED: {0} of {1} assertions." -f $script:Failed, $script:Total) -ForegroundColor Red
Write-Host ''
foreach ($f in $script:Failures) { Write-Host "  $f" -ForegroundColor Red }
Write-Host ''
exit 1
