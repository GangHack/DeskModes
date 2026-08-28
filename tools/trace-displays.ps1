#Requires -Version 5.1

<#
    tools\trace-displays.ps1 — одна лента из двух журналов.

    Наш журнал знает, что РЕШИЛ переключатель. Windows знает, что случилось с
    железом. Порознь эти две половины отвечают на разные вопросы, и 28 августа
    вечер ушёл на то, чтобы сложить их руками.

    Windows пишет отвал монитора сюда:

        Microsoft-Windows-Kernel-PnP/Device Management, событие 1010
        «Device DISPLAY\AUSAA1D\... has been surprise removed as it is
         reported as missing on the bus»

    Это то самое «монитор погас сам»: он ушёл с шины — уснул своей кнопкой,
    моргнул линком, или драйвер перестал его видеть. Событие приходит на
    секунду-две РАНЬШЕ, чем это заметит трей, поэтому в общей ленте видно, что
    было причиной, а что следствием.

        .\tools\trace-displays.ps1              за последние сутки
        .\tools\trace-displays.ps1 -Hours 3     за три часа
        .\tools\trace-displays.ps1 -All         всё, что есть в обоих журналах

    Только читает. Ничего не меняет ни на столе, ни на диске.
#>
[CmdletBinding()]
param(
    [int]$Hours = 24,
    [switch]$All
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$logFile = Join-Path $root 'last-run.log'

$since = $(if ($All) { [datetime]'1970-01-01' } else { (Get-Date).AddHours(-$Hours) })

# --- наш журнал -------------------------------------------------------------
# Строки вида «2026-08-28 21:06:43  reapply: ...». Всё, что не начинается с даты,
# — продолжение предыдущей строки, и в ленту оно не идёт.
$ours = @()
if (Test-Path $logFile) {
    foreach ($line in (Get-Content -LiteralPath $logFile -Encoding UTF8)) {
        if ($line -notmatch '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+(.*)$') { continue }
        $when = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss',
                                       [System.Globalization.CultureInfo]::InvariantCulture)
        if ($when -lt $since) { continue }
        $ours += [pscustomobject]@{ When = $when; Source = 'deck'; Text = $Matches[2] }
    }
}

# --- журнал Windows ---------------------------------------------------------
# Фильтр по имени журнала, а не перебор всех: этот перебирается за миллисекунды,
# а «все включённые» — за минуту.
$theirs = @()
try {
    $filter = @{ LogName = 'Microsoft-Windows-Kernel-PnP/Device Management'; Id = 1010 }
    if (-not $All) { $filter['StartTime'] = $since }
    foreach ($e in (Get-WinEvent -FilterHashtable $filter -ErrorAction Stop)) {
        if ($e.Message -notmatch 'DISPLAY\\([A-Z0-9_]+)\\') { continue }
        $theirs += [pscustomobject]@{
            When = $e.TimeCreated; Source = 'pnp'
            Text = ('{0} surprise removed - missing on the bus' -f $Matches[1])
        }
    }
}
catch [System.Diagnostics.Eventing.Reader.EventLogNotFoundException] {
    Write-Host 'Kernel-PnP log is not there - only the deck side will be shown.' -ForegroundColor Yellow
}
catch {
    # Пустой журнал за период — это не ошибка, это ответ «ничего не отваливалось».
    if ($_.Exception.Message -notmatch 'No events') { throw }
}

# --- одна лента -------------------------------------------------------------
$rows = @($ours + $theirs) | Sort-Object When

if ($rows.Count -eq 0) {
    Write-Host 'Nothing in either log for that period.' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host ('displays, one timeline - {0} lines' -f $rows.Count) -ForegroundColor White
Write-Host ''

foreach ($row in $rows) {
    $stamp = $row.When.ToString('yyyy-MM-dd HH:mm:ss',
                                [System.Globalization.CultureInfo]::InvariantCulture)
    if ($row.Source -eq 'pnp') {
        Write-Host ('{0}  WINDOWS  {1}' -f $stamp, $row.Text) -ForegroundColor Yellow
    }
    else {
        # Строки, ради которых лента и собирается, — глазами их надо находить сразу.
        $loud = ($row.Text -like 'plug:*' -or $row.Text -like 'reapply:*' -or
                 $row.Text -like 'desk:*' -or $row.Text -like 'ERROR*')
        $colour = $(if ($loud) { 'White' } else { 'DarkGray' })
        Write-Host ('{0}  deck     {1}' -f $stamp, $row.Text) -ForegroundColor $colour
    }
}

Write-Host ''
Write-Host 'WINDOWS lines are the hardware. A deck line under one is a reaction to it.' -ForegroundColor DarkGray
