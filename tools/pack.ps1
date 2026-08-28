#Requires -Version 5.1

<#
    tools\pack.ps1 — релизный архив: то, что человек скачивает и распаковывает.

    В архив идёт ТОЛЬКО программа. Тесты, ворота, дневник разработки и правила для
    своих остаются в репозитории: тому, кто пришёл переключать мониторы, они не
    нужны, а 150 килобайт русских заметок в папке инструмента только сбивают.

        .\tools\pack.ps1                        ScreenDeck-<версия>.zip рядом с корнем
        .\tools\pack.ps1 -OutDir C:\out         положить в другое место
        .\tools\pack.ps1 -NotesOut notes.md     заодно выдрать раздел CHANGELOG
        .\tools\pack.ps1 -ExpectVersion 1.0.0   отказаться, если в коде не эта версия
        .\tools\pack.ps1 -AllowDirty            паковать поверх незакоммиченных правок

    Грязное дерево — отказ по умолчанию: собранный из него архив невоспроизводим,
    и разбираться, что именно уехало пользователю, будет уже поздно.

    Список файлов спрашивается у git, как и в check.ps1: один источник правды о
    том, что вообще относится к проекту. Порождённые файлы (settings.json, журнал,
    native-*.dll) в .gitignore и в архив не попадают сами собой — то есть человек
    получает чистую папку, а не слепок чужой машины.

    Код возврата: 0 — архив собран, иначе исключение.
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
# Относительный -OutDir разворачиваем сразу: ZipFile::Open — это .NET, а у .NET
# своя текущая директория, и за Set-Location она не ходит. Без этого архив уезжает
# мимо только что созданной папки, а Get-FileHash ищет его там, где его нет.
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path (Get-Location).Path $OutDir }

# Что в архив не идёт. Список — исключающий, а не разрешающий, намеренно: новый
# файл ПРОГРАММЫ обязан уехать пользователю сам, без правки упаковщика, иначе
# однажды соберётся релиз без него и никто этого не заметит. Новый файл для своих,
# наоборот, требует строчки здесь — и это видимое решение, а не умолчание.
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

# --- версия -----------------------------------------------------------------
# Регуляркой, а не дот-сорсом: загрузка DisplayCore.ps1 компилирует нативные типы
# и пишет в журнал, а упаковщик обязан быть без побочных действий — его зовут и в
# CI, где ни того, ни другого делать незачем.
$coreFile = Join-Path $root 'DisplayCore.ps1'
$pattern = "^\s*\`$script:Version\s*=\s*'(\d+\.\d+\.\d+)'"
$version = ''
foreach ($line in [System.IO.File]::ReadAllLines($coreFile)) {
    if ($line -match $pattern) { $version = $Matches[1]; break }
}
if (-not $version) { throw ('Could not read $script:Version from ' + $coreFile) }

# Тег без поднятой версии — самая дешёвая из ошибок релиза и самая обидная: архив
# уезжает под чужим номером, и About внутри него говорит не то, что написано на
# странице релиза. Сверку зовёт воркфлоу, передавая имя тега без «v».
if ($ExpectVersion -and $ExpectVersion -ne $version) {
    throw ("The tag says $ExpectVersion, but " + '$script:Version' + " in DisplayCore.ps1 is $version. Bump one of them.")
}

# --- что пакуем -------------------------------------------------------------
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

# git перечисляет и то, что удалено из рабочей копии, но ещё лежит в индексе.
# Молча пропустить такой файл нельзя: архив выйдет неполным и об этом никто не
# узнает до первой жалобы.
$missing = @($manifest | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root ($_ -replace '/', '\')) -PathType Leaf) })
if ($missing.Count -gt 0) {
    throw ("Tracked but not on disk:`n" + ($missing -join "`n"))
}

# --- архив ------------------------------------------------------------------
# Пакуем из рабочего дерева, а не через git archive: в репозитории лежит LF, а
# CRLF навешивает .gitattributes при выкладке. Архив с LF сломал бы вторые ворота
# у любого, кто запустит check.ps1 из распакованной папки.
$zipName = "ScreenDeck-$version.zip"
$zipPath = Join-Path $OutDir $zipName
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

# Две сборки, а не одна: ZipFile и ZipFileExtensions лежат в ...FileSystem, а
# ZipArchiveMode и CompressionLevel — в System.IO.Compression. Без второй строки
# упаковщик падает на «Unable to find type» в любой свежей сессии, включая CI.
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

Write-Host ''
Write-Host "ScreenDeck - pack $version" -ForegroundColor Cyan
Write-Host ''

# Все записи — под общей папкой ScreenDeck/, чтобы распаковка в любую директорию
# давала одну папку, а не рассыпала два десятка файлов поверх чужих.
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($relative in $manifest) {
        $full = Join-Path $root ($relative -replace '/', '\')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $full, "ScreenDeck/$relative", [System.IO.Compression.CompressionLevel]::Optimal)
        Write-Host "  +  $relative" -ForegroundColor DarkGray
    }
}
finally { $zip.Dispose() }

# Хэш нужен Scoop: манифест бакета читает его отсюда при автообновлении. Формат —
# как у sha256sum, чтобы человек мог проверить своей утилитой, не разбираясь.
# ToLowerInvariant, а не ToLower: регистр не должен зависеть от языка системы.
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$hashPath = "$zipPath.sha256"
Set-Content -LiteralPath $hashPath -Value "$hash *$zipName" -Encoding ASCII

# --- заметки к релизу -------------------------------------------------------
# Раздел своей версии из CHANGELOG.md — чтобы описание релиза на GitHub писалось
# один раз и в одном месте, а не расходилось с файлом.
if ($NotesOut) {
    $notes = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $root 'CHANGELOG.md'))) {
        if ($line -match '^##\s+(\d+\.\d+\.\d+)') {
            if ($Matches[1] -eq $version) { $inside = $true; continue }
            if ($inside) { break }
        }
        if ($inside) { $notes.Add($line) }
    }
    if ($notes.Count -eq 0) { throw "CHANGELOG.md has no section for $version." }
    # Относительный путь разворачиваем сами: у .NET своя текущая директория, и она
    # не обязана совпадать с той, где стоит PowerShell — файл уехал бы не туда.
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
