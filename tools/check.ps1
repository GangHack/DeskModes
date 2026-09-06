#Requires -Version 5.1

<#
    tools\check.ps1 — one command for the question "have I broken anything?".

    Four gates, a non-zero exit on any failure:

        1. parse      — every .ps1 and .psd1 parses at all;
        2. encoding   — the .ps1 files have a BOM, and there is no lone LF anywhere;
        3. analyzer   — PSScriptAnalyzer, if it is present on the system;
        4. tests      — tests\run-tests.ps1.

    The first gate exists precisely because no test dot-sources render-preview.ps1 or
    Make-Icon.ps1: a typo in them lives until somebody runs them by hand.

        .\tools\check.ps1                     everything
        .\tools\check.ps1 -Only combos        a filter on test names (passed to the runner)
        .\tools\check.ps1 -RequireAnalyzer    a missing PSScriptAnalyzer is a failure

    Nothing is installed on the system: no analyzer and the step is skipped with a
    warning. -RequireAnalyzer is only used in CI, where the workflow installs the module
    itself.

    Exit code: 0 — everything green, 1 — there are failures.
#>
[CmdletBinding()]
param(
    [string]$Only = '',
    [switch]$RequireAnalyzer
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$script:Bad = 0

function Write-CheckHead {
    param([string]$Title)
    Write-Host ''
    Write-Host $Title -ForegroundColor White
}

function Write-CheckOk {
    param([string]$Message)
    Write-Host "  +  $Message" -ForegroundColor Green
}

function Write-CheckWarn {
    param([string]$Message)
    Write-Host "  !  $Message" -ForegroundColor Yellow
}

function Write-CheckFail {
    param([string]$Message)
    $script:Bad++
    Write-Host "  x  $Message" -ForegroundColor Red
}

# The file list is asked of git: generated files (settings.json, activity.json,
# last-mode.json) the machine writes itself, they are in .gitignore, and catching them on
# their line endings is a false alarm about something that will never reach a commit. No git
# — we walk the whole tree, only without .git: an extra check is better than none.
function Get-CheckFiles {
    $paths = $null
    try {
        $listed = @(& git -C $root ls-files --cached --others --exclude-standard 2>$null)
        if ($LASTEXITCODE -eq 0 -and $listed.Count -gt 0) {
            $paths = @($listed | Where-Object { $_ } | ForEach-Object { Join-Path $root ($_ -replace '/', '\') })
        }
    }
    catch { }   # no git, or this is not a repository — no reason not to check

    if ($null -eq $paths) {
        $paths = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
                   Where-Object { $_.FullName -notlike (Join-Path $root '.git\*') } |
                   ForEach-Object { $_.FullName })
    }

# git lists files deleted from the working copy too — they are still in the index.
    return @($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Sort-Object)
}

$files = Get-CheckFiles
$code  = @($files | Where-Object { $_ -match '\.psd?1$' })
$text  = @($files | Where-Object { $_ -match '\.(ps1|psd1|md|json|cmd)$' })

function Get-Relative {
    param([string]$Path)
    if ($Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($root.Length).TrimStart('\')
    }
    return $Path
}

Write-Host ''
Write-Host 'DeskModes - check' -ForegroundColor Cyan

# --- 1. parse ---------------------------------------------------------------
# ParseFile rather than a dot-source: the file is not executed, there are no side effects,
# and the whole syntax is checked, branches the tests never reach included.

Write-CheckHead ("parse ({0} files)" -f $code.Count)

$parseBad = 0
foreach ($file in $code) {
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $parseBad++
        Write-CheckFail (Get-Relative $file)
        foreach ($e in $parseErrors) {
            Write-Host ("       line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor DarkRed
        }
    }
}
if ($parseBad -eq 0) { Write-CheckOk 'every script parses' }

# --- 2. encoding and line endings -------------------------------------------
# Without a BOM, PowerShell 5.1 reads a file as Windows-1251 and every non-ASCII character
# in it turns to rubbish — silently, without a single error. .gitattributes fixes line
# endings at commit time, and this check catches them on the spot, before the commit.
#
# For a .cmd file the requirement is the opposite one, and the .cmd files were outside this gate
# altogether until they broke. Measured rather than argued about, and the first way of measuring says
# there is nothing wrong: `cmd /c file.cmd` tolerates a BOM, while ShellExecute — a double click, a
# pinned shortcut — glues those three bytes to the first command, which fails as unrecognised
# (ERRORLEVEL 9009) while the rest of the file runs on. Here the first line is `@echo off`, so a BOM
# costs the quiet rather than the switch: an error message and every command echoed into a window that
# closes the instant it is done. An editor set to "UTF-8" puts the BOM back on the next save, which is
# why both this gate and .editorconfig say so.

Write-CheckHead ("encoding ({0} files)" -f $text.Count)

$encBad = 0
foreach ($file in $text) {
    $bytes = [System.IO.File]::ReadAllBytes($file)
    $rel = Get-Relative $file
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    if ($file -match '\.psd?1$') {
        if (-not $hasBom) {
            $encBad++
            Write-CheckFail ("$rel - no UTF-8 BOM (PowerShell 5.1 would read it as Windows-1251)")
        }
    }
    elseif ($file -match '\.cmd$') {
        if ($hasBom) {
            $encBad++
            Write-CheckFail ("$rel - a UTF-8 BOM (on a double click those three bytes eat the first line)")
        }
    }

    # The bytes 0x0A and 0x0D cannot be part of a multi-byte UTF-8 sequence (continuations
    # are always >= 0x80), so for finding line endings an ASCII string is exact and costs
    # little: the other bytes become '?', and that is precisely what does not matter here.
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $lone = [regex]::Match($ascii, "(?<!\r)\n")
    if ($lone.Success) {
        $encBad++
        $line = ([regex]::Matches($ascii.Substring(0, $lone.Index), "\n")).Count + 1
        Write-CheckFail ("$rel - lone LF at line $line (this repository is CRLF)")
    }
}
if ($encBad -eq 0) { Write-CheckOk 'BOM and CRLF everywhere' }

# --- 3. analyzer ------------------------------------------------------------

Write-CheckHead 'PSScriptAnalyzer'

$analyzer = @(Get-Module -ListAvailable -Name PSScriptAnalyzer |
              Sort-Object Version -Descending | Select-Object -First 1)
if ($analyzer.Count -eq 0) {
    if ($RequireAnalyzer) {
        Write-CheckFail 'not installed, and -RequireAnalyzer was given'
    }
    else {
        Write-CheckWarn 'not installed - skipped (Install-Module PSScriptAnalyzer -Scope CurrentUser)'
    }
}
else {
    Import-Module PSScriptAnalyzer -ErrorAction Stop

    # The settings file is not required: without it the analyzer runs on the default rules.
    # That way the check does not turn into an error on a clone where the psd1 is not there yet.
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    $withSettings = @{}
    if (Test-Path -LiteralPath $settings) { $withSettings['Settings'] = $settings }
    else { Write-CheckWarn 'PSScriptAnalyzerSettings.psd1 is missing - running with the default rules' }

    $found = @()
    foreach ($file in $code) {
        $found += @(Invoke-ScriptAnalyzer -Path $file @withSettings)
    }
    # The threshold is not by severity but by list: whatever is not switched off in
    # PSScriptAnalyzerSettings.psd1 is a failure, Information included. One source of truth
    # instead of two, and a new rule after a module update does not slip through silently.
    $problems = @($found)
    if ($problems.Count -eq 0) {
        Write-CheckOk ("clean ({0} v{1})" -f $analyzer[0].Name, $analyzer[0].Version)
    }
    else {
        foreach ($d in $problems) {
            Write-CheckFail ("{0}:{1} {2} - {3}" -f (Get-Relative $d.ScriptPath), $d.Line, $d.RuleName, $d.Message)
        }
    }
}

# --- 4. the language files --------------------------------------------------
# A missing key is not a crash: Get-Text hands back "[the.key]" and the window opens with a
# label nobody can read. That is exactly the kind of failure that ships, so it is caught here
# instead. Two directions, both of them silent otherwise:
#
#   a key the code asks for and English does not have  - the label reads "[balloon.saved]";
#   a key a translation has and English does not       - a line somebody translated that no
#                                                        window will ever show, usually a
#                                                        typo in the key.
#
# A translation that is merely INCOMPLETE is not a failure - it falls back to English on the
# missing keys, which is the whole point of the fallback - but the count is printed, because
# a language that is at 60% is worth knowing about before a release.
#
# Only the keys spelled out in the source are checked. A handful are built (`'timer.set.' +
# $Action`), and those are named below rather than left to a regex that would have to guess.

Write-CheckHead 'language'

$langDir = Join-Path $root 'lang'
$english = Join-Path $langDir 'en.ps1'
if (-not (Test-Path -LiteralPath $english)) {
    Write-CheckFail 'lang\en.ps1 is missing - there is nothing to fall back to'
}
else {
    $en = & $english

    # The keys nothing spells out. Each one is a suffix pinned to the two actions the timer
    # has; if a third ever appears, this list is where it announces itself.
    $built = @()
    foreach ($stem in 'timer.set', 'timer.moved', 'timer.lastMinute', 'tray.timer',
                      'menu.timer.in', 'menu.timer.armed', 'timer.caption', 'timer.start') {
        foreach ($action in 'shutdown', 'sleep') { $built += ($stem + '.' + $action) }
    }

    # The language files themselves are the answer, not the question; and tests\ asks for keys
    # that are MEANT not to exist ("[no.such.key]" is what a missing one has to look like).
    $tests = Join-Path $root 'tests'
    $asked = @{}
    foreach ($file in @($code | Where-Object { $_ -notlike (Join-Path $langDir '*') -and
                                               $_ -notlike (Join-Path $tests '*') })) {
        $body = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        # Named by the function and not by -Key alone: half a dozen other functions here take a
        # -Key too, and Invoke-ReapplyMode -Key 'all' is not a string anybody translates.
        foreach ($m in [regex]::Matches($body, "(?:Get-Text|Get-PluralText|New-DisplayMessage|New-DisplayRefusal)\s+-Key\s+'([A-Za-z0-9_.]+)'")) {
            $asked[$m.Groups[1].Value] = $true
        }
        foreach ($m in [regex]::Matches($body, '%%T:([A-Za-z0-9_.]+)%%')) {
            $asked[$m.Groups[1].Value] = $true
        }
    }
    foreach ($key in $built) { $asked[$key] = $true }

    $langBad = 0
    foreach ($key in @($asked.Keys | Sort-Object)) {
        if (-not $en.Contains($key)) {
            $langBad++
            Write-CheckFail ("lang\en.ps1 - nothing for '{0}', and the window would show it in brackets" -f $key)
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $langDir -Filter '*.ps1' -File | Sort-Object Name)) {
        $code2 = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($code2 -eq 'en') { continue }
        $map = & $file.FullName
        foreach ($key in @($map.Keys | Sort-Object)) {
            if ($key -like '_*') { continue }
            if (-not $en.Contains($key)) {
                $langBad++
                Write-CheckFail ("lang\{0}.ps1 - '{1}' is in no window: English has no such key" -f $code2, $key)
            }
        }
        $wanted = @($en.Keys | Where-Object { $_ -notlike '_*' })
        $done = @($wanted | Where-Object { $map.Contains($_) }).Count
        $note = "{0} - {1} of {2} strings" -f $file.Name, $done, $wanted.Count
        if ($done -lt $wanted.Count) { Write-CheckWarn ($note + ' (the rest falls back to English)') }
        else { Write-CheckOk $note }
    }

    if ($langBad -eq 0) { Write-CheckOk ("every key the code asks for is in en.ps1 ({0} of them)" -f $asked.Count) }
}

# --- 5. tests ---------------------------------------------------------------
# In a child process rather than by dot-sourcing: the runner ends with exit, and in this same
# process it would have taken check.ps1 with it and never let the total be printed.
# powershell.exe explicitly: the tool lives in Windows PowerShell 5.1, and it has to be
# checked there, even when check.ps1 was started from pwsh 7.

Write-CheckHead 'tests'

$runner = Join-Path $root 'tests\run-tests.ps1'
$psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner)
if ($Only) { $psArgs += @('-Only', $Only) }

& powershell.exe @psArgs
if ($LASTEXITCODE -ne 0) { Write-CheckFail "run-tests.ps1 exited with $LASTEXITCODE" }

# --- the total --------------------------------------------------------------

Write-Host ''
if ($script:Bad -eq 0) {
    Write-Host 'Check passed.' -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host ("Check FAILED: {0} problem(s)." -f $script:Bad) -ForegroundColor Red
Write-Host ''
exit 1
