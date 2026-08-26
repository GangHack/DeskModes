#Requires -Version 5.1

<#
    tests\live.ps1 — прогон по НАСТОЯЩЕМУ столу. Только руками, никогда в CI и
    никогда по умолчанию.

    Зачем он есть, когда есть 273 обычных случая: вся ценность этого проекта — в
    поведении на настоящем железе. Подписи P/Invoke, отказы драйвера, время, за
    которое монитор просыпается, дробь частоты, которую примет именно эта
    видеокарта, — ни одна подделка этого не воспроизводит. Открытый риск номер
    один здесь звучит как «никто не запускал ни на чём, кроме одного стола», и
    сценарный прогон отвечает на него лучше, чем прогон по памяти.

    Это чек-лист, а не второй набор тестов: он проходит по всем режимам из
    настроек, после каждого сверяет состав, основной монитор, раскладку и частоты,
    и возвращает стол как было. Экраны будут моргать.

        .\tests\live.ps1 -ReadOnly    только смоук CLI, мониторы не трогать
        .\tests\live.ps1                 полный прогон, со подтверждением
        .\tests\live.ps1 -Yes            полный прогон без вопросов

    Журнал НЕ уводится в сторону: строки done: в last-run.log — это и есть замер
    скорости, и сравнивать их надо с прошлыми неделями, а не с пустым файлом.

    Код возврата: 0 — всё сошлось, 1 — есть расхождения, 2 — прогон не начинался.
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$ReadOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# В CI этому файлу делать нечего: там нет ни мониторов, ни человека, который
# увидит, что стол остался разобранным.
if ($env:CI -or $env:GITHUB_ACTIONS -or $env:TF_BUILD) {
    Write-Host 'live.ps1 drives real displays and never runs in CI.' -ForegroundColor Yellow
    exit 2
}

. (Join-Path $root 'DisplayCore.ps1')
. (Join-Path $root 'WindowLayout.ps1')
. (Join-Path $root 'Activity.ps1')

$script:Bad = 0

function Write-LiveCheck {
    param([bool]$Ok, [string]$What, [string]$Detail = '')
    if ($Ok) { Write-Host ("  +  {0}" -f $What) -ForegroundColor Green }
    else {
        $script:Bad++
        Write-Host ("  x  {0}" -f $What) -ForegroundColor Red
        if ($Detail) { Write-Host ("       {0}" -f $Detail) -ForegroundColor DarkRed }
    }
}

# Последняя строка done: — это замер, который переключение оставило само. Читаем
# её из журнала, а не считаем секунды здесь: сравнивать надо ровно то число,
# которое лежит в файле за прошлые недели.
function Get-LastDoneLine {
    try {
        $tail = @(Get-Content -LiteralPath $script:LogFile -Tail 40 -ErrorAction Stop)
        $line = @($tail | Where-Object { $_ -match '\sdone: ' })[-1]
        if ($line -match '\((\d+[.,]\d+) s') { return $Matches[1] }
    }
    catch { }   # журнала может не быть вовсе — это не повод рушить прогон
    return ''
}

function Invoke-Cli {
    param([string[]]$CliArgs)

    # 'Continue' здесь обязателен, и это не перестраховка. Дочерний powershell.exe
    # пишет отказ в stderr, а `2>&1` превращает его в запись об ошибке; при
    # $ErrorActionPreference = 'Stop' такая запись от НЕ-PowerShell команды
    # терминирующая, и прогон падал ровно на том случае, который проверяет код
    # возврата 1. Присваивание локальное: за пределами функции преференс тот же.
    $ErrorActionPreference = 'Continue'

    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Set-Display.ps1') @CliArgs 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n") }
}

# --- смоук командной строки: ничего не меняет -------------------------------

Write-Host ''
Write-Host 'ScreenDeck - live' -ForegroundColor Cyan
Write-Host ''
Write-Host 'the command line (read-only)' -ForegroundColor White

$r = Invoke-Cli @('status')
Write-LiveCheck ($r.Code -eq 0) 'status exits 0' "exit $($r.Code)"
Write-LiveCheck ($r.Text -match 'primary') 'status says which display is primary' $r.Text

$r = Invoke-Cli @('modes')
Write-LiveCheck ($r.Code -eq 0) 'modes exits 0' "exit $($r.Code)"
Write-LiveCheck ($r.Text -match 'Modes:') 'modes prints the list' $r.Text

$r = Invoke-Cli @('brightness')
Write-LiveCheck ($r.Code -eq 0) 'brightness exits 0 even when nothing answers over DDC' "exit $($r.Code)"

# Неизвестное имя — ошибка с кодом 1, а не молчаливый успех: .cmd-обёртки судят
# именно по коду.
$r = Invoke-Cli @('no-such-display-anywhere')
Write-LiveCheck ($r.Code -eq 1) 'an unknown name exits 1' "exit $($r.Code)"

$before = @(Get-DisplayState | Where-Object { $_.Active } | ForEach-Object { $_.Id } | Sort-Object)
$r = Invoke-Cli @('all', '-DryRun')
$after = @(Get-DisplayState | Where-Object { $_.Active } | ForEach-Object { $_.Id } | Sort-Object)
Write-LiveCheck ($r.Code -eq 0) '-DryRun exits 0' "exit $($r.Code)"
Write-LiveCheck (-not (Compare-Object $before $after)) '-DryRun changed nothing on the desk'

if ($ReadOnly) {
    Write-Host ''
    Write-Host ('Read-only part done. ' + $(if ($script:Bad -eq 0) { 'All good.' } else { "$($script:Bad) problem(s)." }))
    Write-Host ''
    exit $(if ($script:Bad -eq 0) { 0 } else { 1 })
}

# --- полный прогон по режимам ------------------------------------------------

$settings = Get-DisplaySettings
$state = @(Get-DisplayState)
$modes = @(Get-DisplayModes -State $state -Settings $settings)
$available = @($modes | Where-Object { $_.Available })
$wasKey = Get-ActiveModeKey -State $state -Modes $modes

Write-Host ''
Write-Host ('About to switch through {0} mode(s): {1}' -f $available.Count, ((@($available | ForEach-Object { $_.Title })) -join ', '))
Write-Host ('The desk will be put back to: {0}' -f $(if ($wasKey) { $wasKey } else { 'all (nothing matched what is on now)' }))
Write-Host 'Screens will blink. Close anything you would hate to see moved.' -ForegroundColor Yellow

if (-not $Yes) {
    $answer = Read-Host 'Type yes to go ahead'
    if ($answer -ne 'yes') {
        Write-Host 'Nothing was done.' -ForegroundColor Yellow
        exit 2
    }
}

foreach ($mode in $available) {
    Write-Host ''
    Write-Host $mode.Title -ForegroundColor White

    try { [void](Switch-DisplayMode -ModeKey $mode.Key -Quiet) }
    catch {
        Write-LiveCheck $false ("the switch itself went through") $_.Exception.Message
        continue
    }

    $now = @(Get-DisplayState)
    $nowModes = @(Get-DisplayModes -State $now -Settings $settings)
    $thisMode = @($nowModes | Where-Object { $_.Key -eq $mode.Key })[0]
    if (-not $thisMode) { $thisMode = $mode }

    # Состав. Сравниваем с тем, что режим просит от ТЕКУЩЕГО стола: монитор мог
    # отвалиться посреди прогона, и тогда честный ответ — новый состав, а не старый.
    $want = @(Get-ModeMembers -Mode $thisMode -State $now | ForEach-Object { $_.Id } | Sort-Object)
    $on = @($now | Where-Object { $_.Active } | ForEach-Object { $_.Id } | Sort-Object)
    Write-LiveCheck (-not (Compare-Object $want $on)) 'the set on the desk is the set the mode names' `
        ("wanted [{0}], got [{1}]" -f ($want -join ', '), ($on -join ', '))

    # Основной монитор — та же лестница выбора, что у переключения.
    $primary = Select-PrimaryDisplay -Wanted @($now | Where-Object { $_.Active }) -PrimaryMatch '' `
                                     -ModePrimary ([string]$thisMode.Primary) `
                                     -SettingsPrimary ([string]$settings.primary) `
                                     -Layout @($settings.layout) -ModeTitle $thisMode.Title
    $isPrimary = @($now | Where-Object { $_.Primary } | ForEach-Object { $_.Id })
    Write-LiveCheck ($isPrimary -contains $primary.Id) 'the taskbar is on the display the settings ask for' `
        ("wanted [{0}], got [{1}]" -f $primary.Label, ($isPrimary -join ', '))

    # Раскладка: X-координаты обязаны совпасть с той же математикой, по которой
    # их выставляли. Расхождение здесь — это разъехавшиеся мониторы.
    if (@($settings.layout).Count -gt 0) {
        $screens = @($now | Where-Object { $_.Active } | ForEach-Object {
            [pscustomobject]@{ DevicePath = $_.Id; Label = $_.Label; Width = $_.Width; Height = $_.Height }
        })
        $expect = Get-LayoutPositions -Screens $screens -Order @($settings.layout) -PrimaryPath $primary.Id
        $actual = Get-CcdSourcePositions
        $off = @()
        foreach ($p in @($expect.Keys)) {
            if (-not $actual.ContainsKey($p)) { $off += "$p missing"; continue }
            if ($actual[$p].X -ne $expect[$p].X -or $actual[$p].Y -ne $expect[$p].Y) {
                $off += ("{0}: wanted {1},{2} got {3},{4}" -f $p, $expect[$p].X, $expect[$p].Y, $actual[$p].X, $actual[$p].Y)
            }
        }
        Write-LiveCheck ($off.Count -eq 0) 'the displays stand where the layout says' ($off -join '; ')
    }

    # Частоты: без -KeepMode переключение обязано поднять каждый монитор в его
    # максимум. Именно это Windows сбрасывает сама чаще всего.
    $lower = @($now | Where-Object { $_.Active -and $_.BestMode } | Where-Object {
        $_.Width -ne $_.BestMode.Width -or $_.Height -ne $_.BestMode.Height -or $_.Hz -ne $_.BestMode.Hz
    } | ForEach-Object { "$($_.Label) $($_.Width)x$($_.Height)@$($_.Hz) (best $($_.BestMode.Width)x$($_.BestMode.Height)@$($_.BestMode.Hz))" })
    Write-LiveCheck ($lower.Count -eq 0) 'every display sits in its best mode' ($lower -join '; ')

    $took = Get-LastDoneLine
    if ($took) { Write-Host ("       took {0} s (compare with the weeks before it in last-run.log)" -f $took) -ForegroundColor DarkGray }
}

# --- вернуть как было --------------------------------------------------------

Write-Host ''
Write-Host 'putting the desk back' -ForegroundColor White

$backTo = $(if ($wasKey) { $wasKey } else { 'all' })
try {
    [void](Switch-DisplayMode -ModeKey $backTo -Quiet)
    Write-LiveCheck $true ("back to $backTo")
}
catch { Write-LiveCheck $false ("back to $backTo") $_.Exception.Message }

Write-Host ''
if ($script:Bad -eq 0) {
    Write-Host 'Live run: everything matched.' -ForegroundColor Green
    Write-Host ''
    exit 0
}
Write-Host ("Live run: {0} problem(s) - see the red lines above and last-run.log." -f $script:Bad) -ForegroundColor Red
Write-Host ''
exit 1
