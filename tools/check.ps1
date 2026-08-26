#Requires -Version 5.1

<#
    tools\check.ps1 — одна команда на вопрос «не сломал ли я что-нибудь».

    Четыре ворот, ненулевой выход на любом провале:

        1. разбор       — каждый .ps1 и .psd1 вообще разбирается;
        2. кодировка    — .ps1 с BOM, и нигде нет одиночных LF;
        3. анализатор   — PSScriptAnalyzer, если он есть в системе;
        4. тесты        — tests\run-tests.ps1.

    Первые ворота нужны ровно потому, что render-preview.ps1 и Make-Icon.ps1 не
    дот-сорсит ни один тест: опечатка в них живёт до ручного запуска.

        .\tools\check.ps1                     всё
        .\tools\check.ps1 -Only combos        фильтр имён тестов (проброс в раннер)
        .\tools\check.ps1 -RequireAnalyzer    отсутствие PSScriptAnalyzer — провал

    В систему ничего не устанавливается: нет анализатора — шаг пропускается с
    предупреждением. -RequireAnalyzer стоит только в CI, где модуль ставится
    самим воркфлоу.

    Код возврата: 0 — всё зелено, 1 — есть провалы.
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

# Список файлов спрашиваем у git: порождённые файлы (settings.json, activity.json,
# last-mode.json) машина пишет сама, они в .gitignore, и ловить их на концах строк
# — ложная тревога о том, что никогда не попадёт в коммит. Нет git — обходим
# дерево целиком, только без .git: лучше лишняя проверка, чем никакой.
function Get-CheckFiles {
    $paths = $null
    try {
        $listed = @(& git -C $root ls-files --cached --others --exclude-standard 2>$null)
        if ($LASTEXITCODE -eq 0 -and $listed.Count -gt 0) {
            $paths = @($listed | Where-Object { $_ } | ForEach-Object { Join-Path $root ($_ -replace '/', '\') })
        }
    }
    catch { }   # git нет или это не репозиторий — не повод не проверять

    if ($null -eq $paths) {
        $paths = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
                   Where-Object { $_.FullName -notlike (Join-Path $root '.git\*') } |
                   ForEach-Object { $_.FullName })
    }

    # git перечисляет и удалённые из рабочей копии файлы — они ещё в индексе.
    return @($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Sort-Object)
}

$files = Get-CheckFiles
$code  = @($files | Where-Object { $_ -match '\.psd?1$' })
$text  = @($files | Where-Object { $_ -match '\.(ps1|psd1|md|json)$' })

function Get-Relative {
    param([string]$Path)
    if ($Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($root.Length).TrimStart('\')
    }
    return $Path
}

Write-Host ''
Write-Host 'ScreenDeck - check' -ForegroundColor Cyan

# --- 1. разбор --------------------------------------------------------------
# ParseFile, а не дот-сорс: файл не исполняется, побочных действий нет, а
# синтаксис проверен весь, включая ветки, до которых тесты не доходят.

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

# --- 2. кодировка и концы строк ---------------------------------------------
# Без BOM PowerShell 5.1 читает файл как Windows-1251, и русские комментарии
# превращаются в мусор — молча, без единой ошибки. .gitattributes чинит концы
# строк при коммите, а эта проверка ловит их на месте, до коммита.

Write-CheckHead ("encoding ({0} files)" -f $text.Count)

$encBad = 0
foreach ($file in $text) {
    $bytes = [System.IO.File]::ReadAllBytes($file)
    $rel = Get-Relative $file

    if ($file -match '\.psd?1$') {
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if (-not $hasBom) {
            $encBad++
            Write-CheckFail ("$rel - no UTF-8 BOM (PowerShell 5.1 would read it as Windows-1251)")
        }
    }

    # Байты 0x0A и 0x0D в UTF-8 не могут быть частью многобайтовой
    # последовательности (продолжения всегда >= 0x80), поэтому для поиска концов
    # строк ASCII-строка точна и стоит дёшево: остальные байты станут '?', и это
    # ровно то, что нам здесь не важно.
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $lone = [regex]::Match($ascii, "(?<!\r)\n")
    if ($lone.Success) {
        $encBad++
        $line = ([regex]::Matches($ascii.Substring(0, $lone.Index), "\n")).Count + 1
        Write-CheckFail ("$rel - lone LF at line $line (this repository is CRLF)")
    }
}
if ($encBad -eq 0) { Write-CheckOk 'BOM and CRLF everywhere' }

# --- 3. анализатор ----------------------------------------------------------

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

    # Файл настроек — не обязателен: без него анализатор идёт правилами по
    # умолчанию. Так проверка не превращается в ошибку на клоне, где psd1 ещё нет.
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    $withSettings = @{}
    if (Test-Path -LiteralPath $settings) { $withSettings['Settings'] = $settings }
    else { Write-CheckWarn 'PSScriptAnalyzerSettings.psd1 is missing - running with the default rules' }

    $found = @()
    foreach ($file in $code) {
        $found += @(Invoke-ScriptAnalyzer -Path $file @withSettings)
    }
    # Порог не по важности, а по списку: что не выключено в
    # PSScriptAnalyzerSettings.psd1 — то провал, включая Information. Один
    # источник правды вместо двух, и новое правило после обновления модуля не
    # проезжает молча.
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

# --- 4. тесты ---------------------------------------------------------------
# Дочерним процессом, а не дот-сорсом: раннер заканчивается exit, и в этом же
# процессе он унёс бы check.ps1 вместе с собой, не дав напечатать итог. Явно
# powershell.exe: инструмент живёт в Windows PowerShell 5.1, и проверять его надо
# там же, даже если check.ps1 запустили из pwsh 7.

Write-CheckHead 'tests'

$runner = Join-Path $root 'tests\run-tests.ps1'
$psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner)
if ($Only) { $psArgs += @('-Only', $Only) }

& powershell.exe @psArgs
if ($LASTEXITCODE -ne 0) { Write-CheckFail "run-tests.ps1 exited with $LASTEXITCODE" }

# --- итог -------------------------------------------------------------------

Write-Host ''
if ($script:Bad -eq 0) {
    Write-Host 'Check passed.' -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host ("Check FAILED: {0} problem(s)." -f $script:Bad) -ForegroundColor Red
Write-Host ''
exit 1
