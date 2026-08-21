<#
    Activity.ps1 — дневник: что, где и сколько.

    Раз в несколько секунд смотрим, какое приложение на переднем плане, на каком
    оно мониторе и какой сейчас режим стола, и складываем секунды в копилку по
    дням. Из копилки потом собирается отчёт — в консоль и в HTML.

    Три решения, которые здесь важнее кода:

      * НАЗВАНИЯ ОКОН НЕ ЧИТАЮТСЯ. В заголовке окна лежит имя документа, адрес
        страницы и тема письма; для «сколько времени в чём» достаточно имени
        процесса. Того, чего нет в файле, из него не утечёт.
      * Копится сумма, а не события. В файле лежат итоги по дню («chrome — 3600
        секунд»), а не поток «в 14:03:10 был chrome». Файл остаётся крошечным
        навсегда, и по нему нельзя восстановить, что человек делал в четверг в
        три часа дня.
      * Выключено по умолчанию (settings.stats). Это данные о человеке, и
        включать их за него нельзя.

    Файл — activity.json рядом со скриптами, его можно удалить в любой момент.
#>

$script:ActivityFile = Join-Path $PSScriptRoot 'activity.json'

# Простой дольше этого — человека за компьютером нет, секунды не копим. Полторы
# минуты, а не пять: у 10-секундного опроса это три пустых замера, и обеденный
# перерыв не попадёт в «время за компьютером».
$script:ActivityIdleLimit = 90

# Копилка в памяти. На диск уходит редко (см. Save-ActivityStore): дневник — не
# та вещь, ради которой стоит будить SSD каждые десять секунд.
$script:ActivityStore = $null
$script:ActivityDirty = $false

# Незаконченный отрезок непрерывной работы: с него считается «самый долгий
# сеанс». Живёт только в памяти — после перезапуска трея отрезок начинается
# заново, и это честно: мы не знаем, что было, пока нас не было.
$script:ActivityRunStart = $null
$script:ActivityRunLast = $null

function Get-ActivityStore {
    if ($null -ne $script:ActivityStore) { return $script:ActivityStore }

    $store = [ordered]@{ days = [ordered]@{} }
    if (Test-Path $script:ActivityFile) {
        try {
            $raw = Get-Content $script:ActivityFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($raw.days) {
                foreach ($d in $raw.days.PSObject.Properties) {
                    $store.days[$d.Name] = ConvertTo-ActivityDay $d.Value
                }
            }
        }
        catch {
            # Дневник — не настройки: терять его не страшно, и портить из-за него
            # запуск приложения тем более незачем.
            Write-DisplayLog "stats: activity.json is damaged, starting a new one - $($_.Exception.Message)"
            $store = [ordered]@{ days = [ordered]@{} }
        }
    }
    $script:ActivityStore = $store
    return $store
}

# Из того, что вернул ConvertFrom-Json (объекты), в то, с чем работает код
# (словари). Заодно проставляет отсутствующие разделы: файл мог быть записан
# прошлой версией, и «нет ключа» не должно превращаться в падение отчёта.
function ConvertTo-ActivityDay {
    param($Raw)

    $day = New-ActivityDay
    if (-not $Raw) { return $day }
    foreach ($section in 'modes', 'apps', 'displays', 'pairs', 'hours') {
        if (-not $Raw.$section) { continue }
        foreach ($p in $Raw.$section.PSObject.Properties) {
            if ($p.Name) { $day[$section][$p.Name] = [int]$p.Value }
        }
    }
    foreach ($field in 'active', 'switches', 'longest') {
        if ($null -ne $Raw.$field) { $day[$field] = [int]$Raw.$field }
    }
    foreach ($field in 'first', 'last') {
        if ($Raw.$field) { $day[$field] = [string]$Raw.$field }
    }
    return $day
}

function New-ActivityDay {
    return [ordered]@{
        active   = 0            # секунд за компьютером (без простоя)
        switches = 0            # переключений режима
        longest  = 0            # самый долгий непрерывный отрезок, секунд
        first    = ''           # когда сели, HH:mm
        last     = ''           # когда последний раз что-то делали
        modes    = [ordered]@{} # ключ режима -> секунды
        apps     = [ordered]@{} # имя процесса -> секунды
        displays = [ordered]@{} # название монитора -> секунды
        pairs    = [ordered]@{} # «процесс|монитор» -> секунды
        hours    = [ordered]@{} # час суток (00..23) -> секунды
    }
}

function Get-ActivityDay {
    param($Store, [string]$Date)

    if (-not $Store.days.Contains($Date)) { $Store.days[$Date] = New-ActivityDay }
    return $Store.days[$Date]
}

# Чистая функция: добавить отрезок в день. Всё, что знает о структуре копилки,
# собрано здесь — и потому проверяется тестами без единого монитора.
function Add-ActivitySpan {
    param($Day, [string]$Process, [string]$Display, [string]$Mode, [int]$Seconds, [string]$Time = '', [int]$Hour = -1)

    if ($Seconds -le 0) { return }

    $Day.active += $Seconds
    if ($Hour -ge 0) {
        $key = '{0:00}' -f $Hour
        $Day.hours[$key] = [int]$Day.hours[$key] + $Seconds
    }
    if ($Process) {
        $Day.apps[$Process] = [int]$Day.apps[$Process] + $Seconds
        if ($Display) { $Day.pairs[($Process + '|' + $Display)] = [int]$Day.pairs[($Process + '|' + $Display)] + $Seconds }
    }
    if ($Display) { $Day.displays[$Display] = [int]$Day.displays[$Display] + $Seconds }
    if ($Mode)    { $Day.modes[$Mode] = [int]$Day.modes[$Mode] + $Seconds }
    if ($Time) {
        if (-not $Day.first) { $Day.first = $Time }
        $Day.last = $Time
    }
}

function Save-ActivityStore {
    param([switch]$Force)

    if ($null -eq $script:ActivityStore) { return }
    if (-not $script:ActivityDirty -and -not $Force) { return }
    try {
        # Дни старше года выбрасываем: годовой отчёт — это уже всё, что кто-то
        # станет читать, а файл должен оставаться маленьким без чужого участия.
        $limit = Format-DisplayStamp ((Get-Date).AddDays(-400)) 'yyyy-MM-dd'
        foreach ($key in @($script:ActivityStore.days.Keys)) {
            if ($key -lt $limit) { $script:ActivityStore.days.Remove($key) }
        }
        $script:ActivityStore | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $script:ActivityFile -Encoding UTF8
        $script:ActivityDirty = $false
    }
    catch { Write-DisplayLog "stats: could not save activity.json - $($_.Exception.Message)" }
}

# Дешёвая половина замера: кто перед компьютером. Отделена от записи, чтобы
# вызывающий не готовил карту мониторов и ключ режима для замера, который тут же
# выбросится: ночью и в обед таких тиков большинство, а пересчёт режимов — это
# миллисекунда каждые десять секунд. $null — за компьютером никого.
function Get-ActivitySample {
    $sample = $null
    try { $sample = [NativeActivity]::Sample() }
    catch { return $null }
    if (-not $sample) { return $null }

    # За компьютером никого — отрезок непрерывной работы кончился.
    if ($sample.IdleSeconds -gt $script:ActivityIdleLimit) {
        $script:ActivityRunStart = $null
        $script:ActivityRunLast = $null
        return $null
    }
    return $sample
}

# Записать замер. $Sample — от Get-ActivitySample; $DisplayMap —
# «\\.\DISPLAY1» -> название монитора, его отдаёт вызывающий: состояние стола у
# трея уже в руках, и спрашивать систему второй раз из-за дневника незачем.
function Add-ActivitySample {
    param($Sample, $DisplayMap, [string]$Mode, [int]$IntervalSeconds = 10)

    $sample = $Sample
    if (-not $sample) { return }

    $now = Get-Date

    # Сколько времени прошло с прошлого замера — по часам, а не по шагу таймера:
    # таймер трея может опоздать (система занята, компьютер спал). Но и целиком
    # верить разрыву нельзя, поэтому он ограничен тремя шагами: минута, которую
    # компьютер проспал, не должна достаться приложению, оказавшемуся на экране.
    #
    # Первый замер после перерыва — ровно один шаг: сколько человек сидел до
    # него, мы не знаем, и выдумывать здесь нечего.
    $seconds = $IntervalSeconds
    if ($script:ActivityRunLast) {
        $gap = [int]($now - $script:ActivityRunLast).TotalSeconds
        if ($gap -le 0) { return }
        $seconds = [math]::Min($gap, $IntervalSeconds * 3)
    }

    $display = ''
    if ($sample.Device -and $DisplayMap -and $DisplayMap.Contains([string]$sample.Device)) {
        $display = [string]$DisplayMap[[string]$sample.Device]
    }

    $day = Get-ActivityDay -Store (Get-ActivityStore) -Date (Format-DisplayStamp $now 'yyyy-MM-dd')
    Add-ActivitySpan -Day $day -Process ([string]$sample.Process) -Display $display -Mode $Mode `
                     -Seconds $seconds -Time (Format-DisplayStamp $now 'HH:mm') -Hour $now.Hour

    # Самый долгий непрерывный отрезок. Считаем на ходу, чтобы не хранить в файле
    # поток событий: длина текущего отрезка — это «сейчас минус его начало».
    if (-not $script:ActivityRunStart) { $script:ActivityRunStart = $now }
    $script:ActivityRunLast = $now
    $run = [int]($now - $script:ActivityRunStart).TotalSeconds
    if ($run -gt [int]$day.longest) { $day.longest = $run }

    $script:ActivityDirty = $true
}

# Переключение режима — единственное событие, которое дневник записывает
# отдельно: остальное он суммирует.
function Add-ActivitySwitch {
    param([string]$Mode)

    if (-not $Mode) { return }
    $day = Get-ActivityDay -Store (Get-ActivityStore) -Date (Format-DisplayStamp (Get-Date) 'yyyy-MM-dd')
    $day.switches = [int]$day.switches + 1
    $script:ActivityDirty = $true
}

# --- отчёт ------------------------------------------------------------------
# Чистая функция над копилкой: складывает дни, сортирует, считает проценты.
# Ничего не читает и никуда не пишет — поэтому проверяется тестами целиком.

function Get-ActivityReport {
    param($Store, [int]$Days = 30, [datetime]$Today = (Get-Date))

    $report = [ordered]@{
        From = ''; To = ''; DaysRecorded = 0
        Active = 0; Switches = 0; Longest = 0
        Apps = @(); Displays = @(); Modes = @(); Pairs = @(); Hours = @()
        BusiestHour = -1; AverageDay = 0; AverageStart = ''; AverageEnd = ''
        BestDay = ''; BestDayActive = 0; Streak = 0
    }
    if (-not $Store -or -not $Store.days) { return $report }

    $since = Format-DisplayStamp ($Today.AddDays(-1 * [math]::Max(0, $Days - 1))) 'yyyy-MM-dd'
    $dates = @($Store.days.Keys | Where-Object { [string]$_ -ge $since } | Sort-Object)
    if ($dates.Count -eq 0) { return $report }

    $apps = @{}; $displays = @{}; $modes = @{}; $pairs = @{}; $hours = @{}
    $starts = @(); $ends = @()

    foreach ($date in $dates) {
        $day = $Store.days[$date]
        $report.DaysRecorded++
        $report.Active += [int]$day.active
        $report.Switches += [int]$day.switches
        if ([int]$day.longest -gt $report.Longest) { $report.Longest = [int]$day.longest }
        if ([int]$day.active -gt $report.BestDayActive) {
            $report.BestDayActive = [int]$day.active
            $report.BestDay = [string]$date
        }
        if ($day.first) { $starts += [string]$day.first }
        if ($day.last)  { $ends += [string]$day.last }

        foreach ($pair in @{ apps = $apps; displays = $displays; modes = $modes; pairs = $pairs; hours = $hours }.GetEnumerator()) {
            $section = $day[$pair.Key]
            if (-not $section) { continue }
            foreach ($k in @($section.Keys)) { $pair.Value[$k] = [int]$pair.Value[$k] + [int]$section[$k] }
        }
    }

    $report.From = [string]$dates[0]
    $report.To = [string]$dates[-1]
    if ($report.DaysRecorded -gt 0) { $report.AverageDay = [int]($report.Active / $report.DaysRecorded) }

    $report.Apps = @(ConvertTo-ActivityRows $apps $report.Active)
    $report.Displays = @(ConvertTo-ActivityRows $displays $report.Active)
    $report.Modes = @(ConvertTo-ActivityRows $modes $report.Active)
    $report.Pairs = @(ConvertTo-ActivityRows $pairs $report.Active)

    # Часы отдаём все двадцать четыре, включая пустые: гистограмма с провалом на
    # обед — это и есть то, ради чего её смотрят.
    $peak = 0
    $rows = @()
    for ($h = 0; $h -lt 24; $h++) {
        $key = '{0:00}' -f $h
        $value = [int]$hours[$key]
        if ($value -gt $peak) { $peak = $value; $report.BusiestHour = $h }
        $rows += [pscustomobject]@{ Name = $key; Seconds = $value; Share = 0 }
    }
    if ($peak -gt 0) {
        foreach ($r in $rows) { $r.Share = [math]::Round(100 * $r.Seconds / $peak, 1) }
    }
    $report.Hours = @($rows)

    $report.AverageStart = Get-AverageClock $starts
    $report.AverageEnd = Get-AverageClock $ends
    $report.Streak = Get-ActivityStreak -Dates $dates -Today $Today

    return $report
}

# Словарь «имя -> секунды» в отсортированный список с долями. Доля считается от
# общего времени, а не от суммы строк: одно приложение может стоять на двух
# мониторах, и сумма пар больше времени за компьютером.
function ConvertTo-ActivityRows {
    param($Map, [int]$Total)

    $rows = @()
    foreach ($k in @($Map.Keys)) {
        $rows += [pscustomobject]@{
            Name    = [string]$k
            Seconds = [int]$Map[$k]
            Share   = $(if ($Total -gt 0) { [math]::Round(100 * [int]$Map[$k] / $Total, 1) } else { 0 })
        }
    }
    return @($rows | Sort-Object -Property Seconds -Descending)
}

# Средний час прихода и уход: «08:42». Строки HH:mm складываем в минутах.
function Get-AverageClock {
    param($Times)

    $list = @($Times | Where-Object { $_ -match '^\d{1,2}:\d{2}$' })
    if ($list.Count -eq 0) { return '' }
    $sum = 0
    foreach ($t in $list) {
        $parts = $t -split ':'
        $sum += [int]$parts[0] * 60 + [int]$parts[1]
    }
    $avg = [int]($sum / $list.Count)
    return '{0:00}:{1:00}' -f [int][math]::Floor($avg / 60), ($avg % 60)
}

# Сколько дней подряд, считая назад от сегодня, компьютером пользовались. Разрыв
# в один день обрывает счёт — иначе это не «подряд».
function Get-ActivityStreak {
    param($Dates, [datetime]$Today = (Get-Date))

    $set = @{}
    foreach ($d in @($Dates)) { $set[[string]$d] = $true }
    $streak = 0
    $cursor = $Today.Date
    while ($set.Contains((Format-DisplayStamp $cursor 'yyyy-MM-dd'))) {
        $streak++
        $cursor = $cursor.AddDays(-1)
    }
    return $streak
}

# «3 h 20 min» — для отчёта. Своя, а не Format-Duration из DisplayCore: там
# секунды нужны для обратного отсчёта, здесь они только мешают.
function Format-ActivitySpan {
    param([int]$Seconds)

    if ($Seconds -le 0) { return '-' }
    $minutes = [int][math]::Round($Seconds / 60)
    if ($minutes -lt 60) { return ('{0} min' -f $minutes) }
    return ('{0} h {1:00} min' -f [int][math]::Floor($minutes / 60), ($minutes % 60))
}

# Отчёт в консоль. Чистая функция: отдаёт массив строк, ничего не печатает — так
# её можно проверить тестом.
function Format-ActivityReport {
    param($Report, [int]$Top = 8)

    $out = @()
    if (-not $Report -or $Report.DaysRecorded -eq 0) {
        # Про «включите дневник» здесь не пишем: эта функция не знает настройки, а
        # с включённым дневником такой совет был бы неправдой — пустой отчёт
        # означает всего лишь, что за компьютером ещё не работали. Про
        # выключенный дневник говорит тот, кто это знает (см. Set-Display.ps1).
        return @('Nothing in the diary yet - it fills up while you use the computer.')
    }

    $out += ''
    $out += ('Diary  {0} .. {1}   {2} day(s) recorded' -f $Report.From, $Report.To, $Report.DaysRecorded)
    $out += ''
    $out += ('  at the computer   {0}   ({1} a day on average)' -f (Format-ActivitySpan $Report.Active), (Format-ActivitySpan $Report.AverageDay))
    $out += ('  longest session   {0}' -f (Format-ActivitySpan $Report.Longest))
    $out += ('  mode switches     {0}' -f $Report.Switches)
    if ($Report.AverageStart) { $out += ('  usual day         {0} .. {1}' -f $Report.AverageStart, $Report.AverageEnd) }
    if ($Report.BusiestHour -ge 0) { $out += ('  busiest hour      {0:00}:00' -f $Report.BusiestHour) }
    if ($Report.BestDay) { $out += ('  longest day       {0}   {1}' -f $Report.BestDay, (Format-ActivitySpan $Report.BestDayActive)) }
    $out += ('  days in a row     {0}' -f $Report.Streak)

    foreach ($section in @(
        @{ Title = 'Displays'; Rows = $Report.Displays },
        @{ Title = 'Modes';    Rows = $Report.Modes },
        @{ Title = 'Apps';     Rows = $Report.Apps },
        @{ Title = 'App on display'; Rows = $Report.Pairs })) {

        $rows = @($section.Rows | Select-Object -First $Top)
        if ($rows.Count -eq 0) { continue }
        $out += ''
        $out += $section.Title
        foreach ($r in $rows) {
            $name = [string]$r.Name -replace '\|', ' on '
            # Полоска из решёток: двадцать знаков на сто процентов. В консоли без
            # цвета это единственный способ увидеть пропорцию, не читая цифры.
            $bar = '#' * [int][math]::Round($r.Share / 5)
            # Ширина колонки времени — под «12 h 00 min» целиком: на десяти
            # знаках трёхчасовые строки съезжали относительно двузначных.
            $out += ('  {0,-28} {1,11}  {2,5}%  {3}' -f $name, (Format-ActivitySpan $r.Seconds), (Format-ActivityPercent $r.Share), $bar)
        }
    }

    $out += ''
    return $out
}

# --- отчёт картинкой --------------------------------------------------------
# Тот же отчёт, но с полосками и в цвете темы. Своего окна не заводим: WPF-окно
# со графиками — это день работы и лишняя тысяча строк, а страница в браузере
# читается лучше, открывается везде и уходит человеку файлом, который можно
# сохранить. Внутри нет ни одной внешней ссылки — ни шрифта, ни скрипта: файл
# должен открываться на машине без интернета и не звать никого в гости.

function Format-ActivityHtmlRows {
    param($Rows, [int]$Top = 10)

    $html = ''
    foreach ($r in @($Rows | Select-Object -First $Top)) {
        # Экранируем ДО того, как добавим свою разметку: имя процесса и название
        # монитора приходят извне (название — прямо из EDID, а туда производитель
        # пишет что угодно), поэтому пара «процесс|монитор» обрабатывается как две
        # отдельные строки, а не как одна с заменой разделителя.
        $name = (@([string]$r.Name -split '\|') | ForEach-Object { Format-HtmlText $_ }) -join
                ' <span class="dim">on</span> '
        $html += ('<tr><td class="name">{0}</td><td class="time">{1}</td>' -f
                  $name, (Format-ActivitySpan $r.Seconds))
        $html += ('<td class="bar"><span style="width:{0}%"></span></td><td class="share">{1}%</td></tr>' -f
                  (Format-ActivityPercent ([math]::Min(100, [double]$r.Share))), (Format-ActivityPercent $r.Share))
    }
    if (-not $html) { $html = '<tr><td colspan="4" class="dim">nothing yet</td></tr>' }
    return $html
}

# Всё, что пришло от системы, попадает в разметку только через эту функцию.
# Название монитора читается из EDID, а туда производитель пишет что угодно —
# сломать страницу угловой скобкой в имени монитора не должно быть возможно.
function Format-HtmlText {
    param([string]$Text)

    return ([string]$Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

# Число в разметку — ВСЕГДА с точкой. `-f` берёт разделитель у текущей локали, и
# на русской «width:12,5%» — это не двенадцать с половиной процентов, а
# выброшенное правило CSS: полоска рисуется нулевой ширины, гистограмма часов
# становится плоской, и виноватым выглядит дневник, а не запятая. Проценты здесь
# считаются с одним знаком после точки (см. ConvertTo-ActivityRows), поэтому
# формат ровно на него.
function Format-ActivityPercent {
    param([double]$Value)

    return $Value.ToString('0.#', [cultureinfo]::InvariantCulture)
}

function New-ActivityHtml {
    param($Report, [string]$Accent = '#4CC2FF', [switch]$Dark)

    $hours = ''
    foreach ($h in @($Report.Hours)) {
        $cls = $(if ([int]$h.Name -eq [int]$Report.BusiestHour) { ' peak' } else { '' })
        $hours += ('<div class="hour{0}"><span style="height:{1}%"></span><em>{2}</em></div>' -f
                   $cls, (Format-ActivityPercent ([math]::Max(2, [double]$h.Share))), $h.Name)
    }

    $facts = @(
        @{ K = 'at the computer'; V = (Format-ActivitySpan $Report.Active) }
        @{ K = 'a day on average'; V = (Format-ActivitySpan $Report.AverageDay) }
        @{ K = 'longest session'; V = (Format-ActivitySpan $Report.Longest) }
        @{ K = 'mode switches'; V = [string]$Report.Switches }
        @{ K = 'usual day'; V = $(if ($Report.AverageStart) { $Report.AverageStart + ' .. ' + $Report.AverageEnd } else { '-' }) }
        @{ K = 'days in a row'; V = [string]$Report.Streak }
    )
    $cards = ''
    foreach ($f in $facts) {
        $cards += ('<div class="card"><b>{0}</b><span>{1}</span></div>' -f $f.V, $f.K)
    }

    $bg     = $(if ($Dark) { '#1b1b1b' } else { '#f6f6f6' })
    $panel  = $(if ($Dark) { '#262626' } else { '#ffffff' })
    $ink    = $(if ($Dark) { '#f0f0f0' } else { '#1a1a1a' })
    $dim    = $(if ($Dark) { '#9a9a9a' } else { '#6a6a6a' })
    $track  = $(if ($Dark) { '#333333' } else { '#ebebeb' })

    $title = 'ScreenDeck - diary'
    $range = '{0} .. {1}, {2} day(s)' -f $Report.From, $Report.To, $Report.DaysRecorded

    return @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>$title</title>
<style>
 :root { --bg:$bg; --panel:$panel; --ink:$ink; --dim:$dim; --track:$track; --accent:$Accent; }
 * { box-sizing: border-box; }
 body { margin:0; padding:32px; background:var(--bg); color:var(--ink);
        font:14px/1.5 'Segoe UI Variable Text','Segoe UI',system-ui,sans-serif; }
 h1 { font-size:22px; font-weight:600; margin:0 0 2px; }
 h2 { font-size:13px; font-weight:600; text-transform:uppercase; letter-spacing:.08em;
      color:var(--dim); margin:0 0 12px; }
 .range { color:var(--dim); margin-bottom:24px; }
 .wrap { max-width:1000px; margin:0 auto; }
 .cards { display:flex; flex-wrap:wrap; gap:12px; margin-bottom:24px; }
 .card { background:var(--panel); border-radius:10px; padding:16px 20px; min-width:150px; flex:1; }
 .card b { display:block; font-size:22px; font-weight:600; }
 .card span { color:var(--dim); font-size:12px; }
 section { background:var(--panel); border-radius:10px; padding:20px 24px; margin-bottom:16px; }
 table { width:100%; border-collapse:collapse; }
 td { padding:5px 0; vertical-align:middle; }
 td.name { width:34%; }
 td.time { width:15%; color:var(--dim); font-variant-numeric:tabular-nums; }
 td.share { width:8%; text-align:right; color:var(--dim); font-variant-numeric:tabular-nums; }
 td.bar { padding-right:12px; }
 td.bar span { display:block; height:8px; border-radius:4px; background:var(--accent); min-width:2px; }
 td.bar { background:linear-gradient(var(--track),var(--track)) no-repeat center/100% 8px; border-radius:4px; }
 .dim { color:var(--dim); }
 .hours { display:flex; align-items:flex-end; gap:4px; height:130px; }
 .hour { flex:1; display:flex; flex-direction:column; justify-content:flex-end; align-items:center; height:100%; }
 .hour span { width:100%; background:var(--track); border-radius:3px 3px 0 0; }
 .hour.peak span { background:var(--accent); }
 .hour em { font-style:normal; font-size:10px; color:var(--dim); margin-top:6px; }
 footer { color:var(--dim); font-size:12px; text-align:center; margin-top:24px; }
</style></head><body><div class="wrap">
<h1>$title</h1>
<div class="range">$range</div>
<div class="cards">$cards</div>
<section><h2>Time of day</h2><div class="hours">$hours</div></section>
<section><h2>Displays</h2><table>$(Format-ActivityHtmlRows $Report.Displays)</table></section>
<section><h2>Modes</h2><table>$(Format-ActivityHtmlRows $Report.Modes)</table></section>
<section><h2>Apps</h2><table>$(Format-ActivityHtmlRows $Report.Apps 12)</table></section>
<section><h2>App on display</h2><table>$(Format-ActivityHtmlRows $Report.Pairs 12)</table></section>
<footer>Window titles are never recorded - only process names. Delete activity.json to forget everything.</footer>
</div></body></html>
"@
}

# Собрать отчёт, положить рядом со скриптами и открыть в браузере. Файл
# перезаписывается каждый раз: это не архив, а взгляд на сейчас.
function Show-ActivityReport {
    param([int]$Days = 30)

    $report = Get-ActivityReport -Store (Get-ActivityStore) -Days $Days
    $dark = Test-DarkTheme
    $html = New-ActivityHtml -Report $report -Accent (Get-AccentColor -ForDarkTheme:$dark) -Dark:$dark
    $path = Join-Path $script:ToolRoot 'stats.html'
    Set-Content -Path $path -Value $html -Encoding UTF8
    Write-DisplayLog "stats: report written to stats.html"
    Start-Process $path | Out-Null
    return $path
}
