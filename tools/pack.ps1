#Requires -Version 5.1

<#
    tools\pack.ps1 — the release archive: what a person downloads and unpacks.

    ONLY the program goes into the archive. The tests, the gates, the engineering diary and the
    house rules stay in the repository: whoever came here to switch monitors does not need them,
    and 150 kilobytes of engineering notes in the tool's folder only get in the way.

        .\tools\pack.ps1                        DeskModes-<version>.zip next to the root
        .\tools\pack.ps1 -OutDir C:\out         put it somewhere else
        .\tools\pack.ps1 -NotesOut notes.md     also pull out the CHANGELOG section
        .\tools\pack.ps1 -ExpectVersion 1.0.0   refuse if the code says another version
        .\tools\pack.ps1 -AllowDirty            pack over uncommitted edits

    A dirty tree is a refusal by default: an archive built from one is not reproducible, and by
    the time anyone works out what exactly went to the user it is already too late.

    The file list is asked of git, as in check.ps1: one source of truth about what belongs to the
    project at all. Generated files (settings.json, the log, native-*.dll) are in .gitignore and
    do not reach the archive by themselves — that is, a person gets a clean folder rather than a
    cast of somebody else's machine.

    Exit code: 0 — the archive was built, otherwise an exception.
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [string]$NotesOut = '',
    [string]$ExpectVersion = '',
    [switch]$AllowDirty
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = $root }
# A relative -OutDir is expanded straight away: ZipFile::Open is .NET, and .NET has a current
# directory of its own that does not follow Set-Location. Without this the archive goes past the
# folder just created, and Get-FileHash looks for it where it is not.
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path (Get-Location).Path $OutDir }

# What does not go into the archive. The list is an excluding one rather than an allowing one,
# deliberately: a new file of the PROGRAM has to reach the user by itself, without editing the
# packer, or a release will one day be built without it and nobody will notice. A new file for us,
# the other way round, requires a line here — and that is a visible decision rather than a default.
$script:DevDirs = @('tests/', 'tools/', 'docs/', '.github/')
$script:DevFiles = @(
    '.editorconfig'
    '.gitattributes'
    '.gitignore'
    'AGENTS.md'
    'CLAUDE.md'
    'CONTRIBUTING.md'
    'Make-Icon.ps1'
    'PSScriptAnalyzerSettings.psd1'
    'render-preview.ps1'
)

function Test-ShippedFile {
    param([string]$Relative)
    if ($script:DevFiles -contains $Relative) { return $false }
    foreach ($dir in $script:DevDirs) {
        if ($Relative.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

# One version's section of CHANGELOG.md: its heading and its body, separately. Two things want it — the
# heading, to check it carries a date, and the body, which becomes the release description on GitHub — and
# they used to walk the file with a loop each, the two loops agreeing on what a heading looks like only by
# both being written on the same evening. Heading is '' when there is no section at all.
function Get-ChangelogSection {
    param([string]$Version)

    $heading = ''
    $body = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $root 'CHANGELOG.md'))) {
        if ($line -match '^##\s+(\d+\.\d+\.\d+)') {
            # The next version's heading ends ours. Ordered this way round so that a file listing the
            # same version twice takes the first section and stops, rather than glueing them together.
            if ($inside) { break }
            if ($Matches[1] -eq $Version) { $heading = $line; $inside = $true }
            continue
        }
        if ($inside) { $body.Add($line) }
    }
    return [pscustomobject]@{ Heading = $heading; Body = $body }
}

# --- the version ------------------------------------------------------------
# By regex rather than by dot-sourcing: loading DisplayCore.ps1 compiles the native types and writes
# to the log, whereas the packer has to be free of side effects — it is called in CI too, where
# there is no reason to do either.
$coreFile = Join-Path $root 'DisplayCore.ps1'
$pattern = "^\s*\`$script:Version\s*=\s*'(\d+\.\d+\.\d+)'"
$version = ''
foreach ($line in [System.IO.File]::ReadAllLines($coreFile)) {
    if ($line -match $pattern) { $version = $Matches[1]; break }
}
if (-not $version) { throw ('Could not read $script:Version from ' + $coreFile) }

# A tag without the version bumped is the cheapest of release mistakes and the most galling: the
# archive leaves under somebody else's number, and the About inside it says something other than
# what is written on the release page. The workflow calls the check, passing the tag name without the "v".
if ($ExpectVersion -and $ExpectVersion -ne $version) {
    throw ("The tag says $ExpectVersion, but " + '$script:Version' + " in DisplayCore.ps1 is $version. Bump one of them.")
}

# The other half of the same mistake, and until now nothing caught it: a version's section in
# CHANGELOG.md rightly says "not released yet" for as long as it is being written, and on the release
# path that same line is wrong. Only the body of the section reaches the release page, so the archive
# used to build happily under a heading claiming the release had not happened.
#
# Checked HERE and not down with the notes: a refusal after the archive has been written and hashed is
# a refusal that leaves rubbish behind. -ExpectVersion is what tells a release from a local build —
# only the workflow passes it, and only for a tag.
if ($ExpectVersion) {
    $heading = (Get-ChangelogSection -Version $version).Heading
    if (-not $heading) { throw "CHANGELOG.md has no section for $version." }
    if ($heading -notmatch '\d{4}-\d{2}-\d{2}') {
        throw ("CHANGELOG.md: the heading for $version carries no date - '$($heading.Trim())'. " +
               "Write it as '## $version " + [char]0x2014 + " yyyy-mm-dd' before tagging.")
    }
}

# --- what we pack -----------------------------------------------------------
$listed = @(& git -C $root ls-files 2>$null)
if ($LASTEXITCODE -ne 0 -or $listed.Count -eq 0) {
    throw 'git is required to pack: the release contents come from git ls-files.'
}

if (-not $AllowDirty) {
    $dirty = @(& git -C $root status --porcelain)
    if ($dirty.Count -gt 0) {
        throw ("The working tree is dirty, so the archive would not be reproducible:`n" +
               ($dirty -join "`n") + "`n`nCommit first, or pass -AllowDirty.")
    }
}

$manifest = @($listed | Where-Object { $_ } | Where-Object { Test-ShippedFile -Relative $_ } | Sort-Object)

# git lists what has been deleted from the working copy but is still in the index. Skipping such a
# file silently is not allowed: the archive would come out incomplete and nobody would know about it
# until the first complaint.
$missing = @($manifest | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root ($_ -replace '/', '\')) -PathType Leaf) })
if ($missing.Count -gt 0) {
    throw ("Tracked but not on disk:`n" + ($missing -join "`n"))
}

# --- the archive ------------------------------------------------------------
# We pack out of the working tree rather than through git archive: the repository holds LF, and CRLF
# is put on by .gitattributes at checkout. An archive with LF would break the second gate for anyone
# who runs check.ps1 out of the unpacked folder.
$zipName = "DeskModes-$version.zip"
$zipPath = Join-Path $OutDir $zipName
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

# Two assemblies rather than one: ZipFile and ZipFileExtensions live in ...FileSystem, while
# ZipArchiveMode and CompressionLevel are in System.IO.Compression. Without the second line the
# packer dies on "Unable to find type" in any fresh session, CI included.
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

Write-Host ''
Write-Host "DeskModes - pack $version" -ForegroundColor Cyan
Write-Host ''

# Every entry goes under a shared DeskModes/ folder, so that unpacking into any directory gives one
# folder rather than scattering two dozen files over somebody else's.
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($relative in $manifest) {
        $full = Join-Path $root ($relative -replace '/', '\')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $full, "DeskModes/$relative", [System.IO.Compression.CompressionLevel]::Optimal)
        Write-Host "  +  $relative" -ForegroundColor DarkGray
    }
}
finally { $zip.Dispose() }

# Scoop needs the hash: a bucket manifest reads it from here when it auto-updates. The format is the
# one sha256sum uses, so that a person can check it with their own utility without having to work
# anything out. ToLowerInvariant and not ToLower: the case must not depend on the system's language.
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$hashPath = "$zipPath.sha256"
Set-Content -LiteralPath $hashPath -Value "$hash *$zipName" -Encoding ASCII

# --- the release notes ------------------------------------------------------
# Its own version's section out of CHANGELOG.md — so that the release description on GitHub is
# written once and in one place rather than drifting apart from the file.
if ($NotesOut) {
    $notes = (Get-ChangelogSection -Version $version).Body
    if ($notes.Count -eq 0) { throw "CHANGELOG.md has no section for $version." }
    # We expand a relative path ourselves: .NET has a current directory of its own, and it need not
    # match the one PowerShell is standing in — the file would have gone somewhere else.
    $notesPath = $NotesOut
    if (-not [System.IO.Path]::IsPathRooted($notesPath)) {
        $notesPath = Join-Path (Get-Location).Path $notesPath
    }
    [System.IO.File]::WriteAllLines($notesPath, $notes)
    Write-Host ''
    Write-Host "  notes: $notesPath" -ForegroundColor DarkGray
}

$size = [int]((Get-Item -LiteralPath $zipPath).Length / 1KB)
Write-Host ''
Write-Host "  $zipName - $($manifest.Count) files, $size KB" -ForegroundColor Green
Write-Host "  $hash" -ForegroundColor DarkGray
Write-Host ''
