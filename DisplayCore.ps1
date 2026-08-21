<#
    DisplayCore.ps1 — общая логика переключения мониторов.

    Только определения, никаких действий при загрузке. Точки входа:
        Displays.ps1      значок в трее
        Set-Display.ps1   командная строка

    Всё делается через Windows API, напрямую. Проект начинался как обвязка вокруг
    MultiMonitorTool Нира Софера, и тот в работе больше не участвует: чтение
    состояния он отдавал за 1100 мс против ~90 мс у CCD, выключенный монитор в
    его дампе терял имя и идентификатор (то есть включить его было нечем), а его
    команды шли через ту запись раскладки, которая на этой машине отвечает
    отказом. Частью проекта он не является и в репозитории не лежит.
#>

$script:ToolRoot     = $PSScriptRoot
# Путь к журналу можно перенаправить переменной окружения. Единственный
# потребитель — tests\run-tests.ps1: подменить $script:LogFile ПОСЛЕ дот-сорса он
# уже не успевает, первые строки (компиляция типов, поворот журнала) пишутся прямо
# при загрузке этого файла, и прогон тестов оставлял их в настоящем last-run.log.
# Журнал здесь — единственный инструмент разбора, и чужих следов в нём быть не
# должно.
$script:LogFile      = $(if ($env:MMT_LOG_FILE) { $env:MMT_LOG_FILE } else { Join-Path $PSScriptRoot 'last-run.log' })
$script:SettingsFile = Join-Path $PSScriptRoot 'settings.json'
$script:LastModeFile = Join-Path $PSScriptRoot 'last-mode.json'
$script:ModeCacheFile = Join-Path $PSScriptRoot 'display-modes.json'

# Дата и время для журнала и для файлов — одни и те же на любой локали. И
# `-Format`, и ToString без указания культуры берут у текущей не только
# разделитель времени, но и КАЛЕНДАРЬ: на тайской локали 'yyyy' — это 2569-й год
# по буддийскому, на арабской бывает Хиджра. Журнал перестаёт читаться как
# ISO-дата, а ключи дневника — сравниваться строкой с прошлогодними. Журнал в
# этом проекте английский, и дата в нём — тоже (тот же случай, что и длительность
# в done:, см. Switch-DisplayMode).
function Format-DisplayStamp {
    param([datetime]$When = (Get-Date), [string]$Pattern = 'yyyy-MM-dd HH:mm:ss')
    return $When.ToString($Pattern, [cultureinfo]::InvariantCulture)
}

function Write-DisplayLog {
    param([string]$Message)
    try {
        # -ErrorAction Stop не для красоты: отказ Add-Content (файл открыт на
        # запись чем-то ещё, только чтение, диск полон) — ошибка НЕтерминирующая,
        # и без этого catch ниже её не поймает. Обе точки входа ставят
        # $ErrorActionPreference = 'Stop' и потому были прикрыты случайно, а вот
        # DisplayCore, подключённый в обычную консоль, сыпал красным текстом на
        # каждую строку журнала. Теперь молчание не зависит от вызывающего.
        Add-Content -Path $script:LogFile -Encoding UTF8 -ErrorAction Stop `
                    -Value ('{0}  {1}' -f (Format-DisplayStamp), $Message)
    }
    catch { }   # лог не должен ронять переключение мониторов
}

# Журнал в этом проекте — главный (и единственный) инструмент разбора, поэтому он
# растёт: строка на каждое переключение, на каждый старт, на каждое срабатывание
# сторожа. Один мегабайт — это примерно год такой жизни; дальше открывать его
# блокнотом становится больно, а история старше года не нужна ни разу.
#
# Проверка ОДНА, при загрузке DisplayCore, а не на каждой записи: иначе Get-Item
# дёргался бы по нескольку раз за переключение впустую.
#
# Переименование, а не обрезание: активный процесс может держать файл открытым, и
# резать его под ним нельзя. Прошлый .old перезаписывается — двух поколений
# достаточно.
function Rotate-DisplayLog {
    param([int]$MaxBytes = 1MB)

    try {
        if (-not (Test-Path $script:LogFile)) { return }
        if ((Get-Item $script:LogFile).Length -lt $MaxBytes) { return }

        $old = $script:LogFile + '.old'
        # -ErrorAction Stop обязателен: без него отказ Move-Item — ошибка
        # НЕтерминирующая, catch ниже не срабатывает, и текст «файл занят другим
        # процессом» уезжает в поток ошибок. В трее это никто не увидит, а вот
        # status.cmd печатал бы красную простыню из-за уборки в журнале.
        Move-Item -LiteralPath $script:LogFile -Destination $old -Force -ErrorAction Stop
        # Первая строка нового файла объясняет, куда девалось прошлое.
        Write-DisplayLog 'core: log rotated, the previous one is last-run.log.old'
    }
    catch {
        # Не смогли — не беда: пишем дальше в тот же файл. Ронять инструмент
        # из-за уборки в журнале нельзя.
    }
}

Rotate-DisplayLog

# --- настройки --------------------------------------------------------------
# Привязки клавиш живут в settings.json, а не в коде: их правит сам пользователь
# через окно настроек. Ключи режимов — стабильные (см. Get-DisplayModes).

function Get-DefaultSettings {
    return [ordered]@{
        hotkeys         = [ordered]@{}
        maximizeRefresh = $true
        notifications   = $true
        # Физический порядок мониторов на столе, слева направо. По нему
        # выстраивается раскладка в Windows, чтобы курсор переходил между
        # экранами в ту же сторону, в которую они реально стоят. Названия можно
        # писать частями: «UltraGear» найдёт «LG ULTRAGEAR».
        layout          = @()
        # Какой монитор делать основным (то есть где панель задач), если он есть
        # среди включённых. Часть названия, как и в layout.
        primary         = ''
        # УСТАРЕЛО, читается только ради переезда. Роли были вторым способом
        # сказать то же, что говорят combos: «эти мониторы — вместе». Ролью
        # помечался монитор (кусок названия -> имя роли), и режим появлялся сам,
        # когда роль делили двое:
        #   "roles": { "ULTRAFINE": "work", "XG27AQDMGR": "game" }
        #
        # Два способа для одной вещи не выжили при встрече с человеком: «Work
        # displays» и «Movie night» в списке выглядели одинаково, а удалялись
        # по-разному — комбинация кнопкой, группа стиранием имени в другой
        # карточке. Роль вдобавок у монитора одна, поэтому пересекающиеся наборы
        # ею не выразить, и своего монитора для панели задач у неё нет. То есть
        # группа — это комбинация, только слабее.
        #
        # Теперь роли из файла превращаются в комбинации при чтении настроек
        # (Convert-RoleSettingsToCombos), а ключ остаётся пустым: он нужен, чтобы
        # старый settings.json и записи, сделанные рукой, продолжали работать.
        roles           = [ordered]@{}
        # Комбинации: имя -> произвольный набор мониторов. Роли этого не умеют:
        # роль у монитора одна, а комбинаций с его участием может быть сколько
        # угодно. Ключ режима — combo:<имя>, заголовок — само имя, как введено.
        #   "combos": {
        #       "Movie night": { "displays": ["ULTRAFINE", "XG27AQDMGR"], "primary": "ULTRAFINE" }
        #   }
        # displays — куски названий, правила совпадения те же, что у layout и
        # ролей. primary — кому достанется панель задач в этом режиме; пустая
        # строка или отсутствие монитора на столе — работают общие правила (см.
        # Select-PrimaryDisplay). Правится в окне настроек; руками допустима и
        # краткая запись — просто массив названий вместо объекта.
        combos          = [ordered]@{}
        # Запоминать положение окон для каждой раскладки столов и возвращать их
        # обратно при возврате к ней (WindowLayout.ps1).
        restoreWindows  = $true
        # Возвращать последний выбранный режим после включения компьютера.
        # Windows поднимает свой набор экранов, а не тот, что был выбран перед
        # выключением (см. Save-LastMode и Invoke-StartupRestore).
        restoreLastMode = $true
        # УСТАРЕЛО, читается только ради переезда: автоматический игровой режим
        # умел ровно одно правило — «запустился процесс, уйди в режим, закрылся,
        # вернись». Теперь это первый элемент rules (Convert-AutoGameToRules),
        # ключ остаётся, чтобы старый settings.json продолжал работать.
        #   enabled   включить слежение;
        #   process   имя процесса БЕЗ .exe, как его показывает Get-Process (cs2);
        #   gameMode  ключ режима, в который уходить (см. Set-Display.ps1 modes);
        #   backMode  куда возвращаться; пусто — в тот режим, что был до игры.
        autoGame        = [ordered]@{
            enabled  = $false
            process  = ''
            gameMode = ''
            backMode = ''
        }
        # Правила: «случилось это — стань таким». То же, что делал autoGame, но
        # условий больше одного и правил может быть сколько угодно. Проверяются
        # по порядку, первое подходящее выигрывает; пока правило «владеет»
        # столом, остальные молчат (см. Get-RuleDecision).
        #   "rules": [
        #       { "when": "process", "process": "cs2", "mode": "solo:XG27AQDMGR" },
        #       { "when": "idle", "minutes": 20, "mode": "solo:LG ULTRAGEAR" }
        #   ]
        # when     process — процесс запущен; idle — за компьютером не работают
        #          minutes минут;
        # mode     ключ режима, в который уходить;
        # back     куда возвращаться, когда условие кончилось; пусто — туда, где
        #          стол был до срабатывания;
        # enabled  false выключает правило, не удаляя его.
        rules           = @()
        # Мир изменился сам — собрать стол заново. Windows после выхода из сна и
        # после переподключения монитора расставляет экраны по своему усмотрению:
        # раскладка разъезжается, панель задач уезжает, частота падает.
        #   onResume  выход из сна: вернуть последний выбранный режим;
        #   onUnplug  монитор пропал: перестроить то, что осталось;
        #   onPlug    монитор появился: ключ режима, в который уйти. Пусто —
        #             ничего не делать. Пустое по умолчанию намеренно: гасить
        #             монитор, который человек только что включил кнопкой, —
        #             это война с человеком, и решение тут за ним.
        reapply         = [ordered]@{
            onResume = $true
            onUnplug = $true
            onPlug   = ''
        }
        # Команда, которую надо выполнить вокруг переключения: ключ режима ->
        # { before, after }. Строка вместо объекта означает after — так короче, а
        # нужен чаще именно он.
        #   "hooks": { "combo:Movie night": { "after": "taskkill /im slack.exe" } }
        # Команду запускают и НЕ ждут: переключение стола не должно зависеть от
        # чужой программы. Путь на .ps1 запускается через powershell, всё
        # остальное — через cmd /c (см. Get-HookLaunch).
        hooks           = [ordered]@{}
        # Яркость и контраст как часть режима: ключ режима -> число 0..100 для
        # всех мониторов набора, либо { кусок названия -> число } для каждого
        # своё. Идёт по DDC/CI — тому же каналу в кабеле, по которому работают
        # кнопки на корпусе монитора (см. Set-MonitorLevels).
        #   "brightness": { "combo:Work": 80, "all": { "ULTRAFINE": 25 } }
        brightness      = [ordered]@{}
        contrast        = [ordered]@{}
        # Дневник: какое приложение, на каком мониторе и в каком режиме сколько
        # времени. Хранится рядом со скриптами в activity.json, никуда не
        # уходит, названия окон НЕ пишутся — только имя процесса. Выключено по
        # умолчанию: это данные о человеке, и включать их за него нельзя.
        stats           = $false
        # Звук следом за режимом: ключ режима -> кусок названия устройства вывода.
        # Пустой словарь = выключено. Тоже правится руками:
        #   "audio": { "solo:XG27AQDMGR": "ROG", "role:work": "ULTRAFINE" }
        audio           = [ordered]@{}
        # runAtStartup здесь был и убран: его писали, но никогда не читали —
        # правда об автозагрузке живёт в наличии ярлыка (см. Test-RunAtStartup),
        # и две копии одного факта могли разойтись.
    }
}

function Get-DisplaySettings {
    $s = Get-DefaultSettings
    if (Test-Path $script:SettingsFile) {
        try {
            $raw = Get-Content $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $raw.maximizeRefresh) { $s.maximizeRefresh = [bool]$raw.maximizeRefresh }
            if ($null -ne $raw.notifications)   { $s.notifications   = [bool]$raw.notifications }
            if ($null -ne $raw.restoreWindows)  { $s.restoreWindows  = [bool]$raw.restoreWindows }
            if ($null -ne $raw.restoreLastMode) { $s.restoreLastMode = [bool]$raw.restoreLastMode }
            if ($null -ne $raw.layout)          { $s.layout          = @($raw.layout | ForEach-Object { [string]$_ }) }
            if ($null -ne $raw.primary)         { $s.primary         = [string]$raw.primary }
            if ($raw.hotkeys) {
                foreach ($p in $raw.hotkeys.PSObject.Properties) { $s.hotkeys[$p.Name] = [string]$p.Value }
            }
            # Поле за полем, а не присваиванием объекта целиком: в файле может
            # лежать половина ключей (его правят руками), и остальные обязаны
            # остаться дефолтными, а не превратиться в $null.
            if ($raw.audio) {
                foreach ($p in $raw.audio.PSObject.Properties) { $s.audio[$p.Name] = [string]$p.Value }
            }
            if ($raw.roles) {
                foreach ($p in $raw.roles.PSObject.Properties) { $s.roles[$p.Name] = [string]$p.Value }
            }
            if ($raw.combos) {
                foreach ($p in $raw.combos.PSObject.Properties) {
                    if (-not $p.Name) { continue }
                    # Три формы записи: полная ({ displays, primary }) — её пишет окно
                    # настроек; краткая (массив названий) и совсем краткая (одно
                    # название строкой) — для правки рукой. Внутри всегда полная.
                    $displays = @()
                    $prim = ''
                    if ($p.Value -is [array])       { $displays = @($p.Value | ForEach-Object { [string]$_ }) }
                    elseif ($p.Value -is [string])  { $displays = @([string]$p.Value) }
                    elseif ($p.Value) {
                        if ($null -ne $p.Value.displays) { $displays = @($p.Value.displays | ForEach-Object { [string]$_ }) }
                        if ($null -ne $p.Value.primary)  { $prim = [string]$p.Value.primary }
                    }
                    $s.combos[$p.Name] = [ordered]@{
                        displays = @($displays | Where-Object { $_ })
                        primary  = $prim
                    }
                }
            }
            if ($raw.autoGame) {
                if ($null -ne $raw.autoGame.enabled)  { $s.autoGame.enabled  = [bool]$raw.autoGame.enabled }
                if ($null -ne $raw.autoGame.process)  { $s.autoGame.process  = [string]$raw.autoGame.process }
                if ($null -ne $raw.autoGame.gameMode) { $s.autoGame.gameMode = [string]$raw.autoGame.gameMode }
                if ($null -ne $raw.autoGame.backMode) { $s.autoGame.backMode = [string]$raw.autoGame.backMode }
            }
            if ($null -ne $raw.stats) { $s.stats = [bool]$raw.stats }
            if ($raw.reapply) {
                if ($null -ne $raw.reapply.onResume) { $s.reapply.onResume = [bool]$raw.reapply.onResume }
                if ($null -ne $raw.reapply.onUnplug) { $s.reapply.onUnplug = [bool]$raw.reapply.onUnplug }
                if ($null -ne $raw.reapply.onPlug)   { $s.reapply.onPlug   = [string]$raw.reapply.onPlug }
            }
            if ($raw.rules) {
                # Приводим к одной форме здесь, на чтении: дальше правила читает
                # таймер трея каждые 15 секунд, и разбираться с полем, которого
                # в файле может не быть, там уже нельзя.
                $s.rules = @(foreach ($r in @($raw.rules)) {
                    if (-not $r) { continue }
                    $when = [string]$r.when
                    if (-not $when) { $when = 'process' }
                    [ordered]@{
                        when    = $when.ToLowerInvariant()
                        process = [string]$r.process
                        minutes = $(if ($null -ne $r.minutes) { [int]$r.minutes } else { 0 })
                        mode    = [string]$r.mode
                        back    = [string]$r.back
                        enabled = $(if ($null -ne $r.enabled) { [bool]$r.enabled } else { $true })
                    }
                })
            }
            if ($raw.hooks) {
                foreach ($p in $raw.hooks.PSObject.Properties) {
                    if (-not $p.Name) { continue }
                    $before = ''; $after = ''
                    # Строкой пишут то, что нужно чаще: команду ПОСЛЕ переключения.
                    if ($p.Value -is [string]) { $after = [string]$p.Value }
                    elseif ($p.Value) {
                        if ($null -ne $p.Value.before) { $before = [string]$p.Value.before }
                        if ($null -ne $p.Value.after)  { $after  = [string]$p.Value.after }
                    }
                    if (-not $before -and -not $after) { continue }
                    $s.hooks[$p.Name] = [ordered]@{ before = $before; after = $after }
                }
            }
            foreach ($key in @('brightness', 'contrast')) {
                if (-not $raw.$key) { continue }
                foreach ($p in $raw.$key.PSObject.Properties) {
                    if (-not $p.Name) { continue }
                    # Число — всем мониторам режима поровну; объект — каждому своё.
                    if ($p.Value -is [string] -or $p.Value -is [int] -or $p.Value -is [double] -or $p.Value -is [long]) {
                        $s.$key[$p.Name] = [int]$p.Value
                    }
                    elseif ($p.Value) {
                        $per = [ordered]@{}
                        foreach ($d in $p.Value.PSObject.Properties) {
                            if ($d.Name) { $per[$d.Name] = [int]$d.Value }
                        }
                        if ($per.Count -gt 0) { $s.$key[$p.Name] = $per }
                    }
                }
            }
        }
        catch {
            Write-DisplayLog "settings: file is damaged, falling back to defaults - $($_.Exception.Message)"
            # Копию испорченного файла надо сохранить: дальше приложение видит
            # пустой список клавиш, считает это первым запуском и записывает
            # поверх значения по умолчанию. Без копии привязки исчезали совсем.
            try {
                Copy-Item $script:SettingsFile ($script:SettingsFile + '.bad') -Force
                Write-DisplayLog 'settings: kept a copy of the damaged file as settings.json.bad'
            }
            catch { }
        }
    }

    # Роли — устаревший способ описать набор мониторов; превращаем их в
    # комбинации ЗДЕСЬ, на чтении, чтобы весь остальной код (меню, режимы,
    # переключатель, командная строка) знал только один вид набора. В памяти, без
    # записи: писать из функции чтения нельзя — два процесса читают настройки
    # одновременно. Файл приберёт трей при следующем запуске, по этому флагу.
    $script:LegacyRolesOnDisk = Convert-RoleSettingsToCombos $s

    # Ровно так же, как роли, переезжает и автоматический игровой режим: одно
    # правило «процесс -> режим» — это первый элемент rules, и весь остальной код
    # знает только правила.
    $script:LegacyAutoGameOnDisk = Convert-AutoGameToRules $s

    return $s
}

# Признак того, что в settings.json ещё лежат роли. Ставится на каждом чтении;
# читает его трей, чтобы один раз перезаписать файл (см. Displays.ps1).
$script:LegacyRolesOnDisk = $false

# То же для автоматического игрового режима, переехавшего в rules.
$script:LegacyAutoGameOnDisk = $false

function Save-DisplaySettings {
    param($Settings)
    $Settings | ConvertTo-Json -Depth 5 | Set-Content -Path $script:SettingsFile -Encoding UTF8
    Write-DisplayLog 'settings: saved'
}

# --- последний выбранный режим ----------------------------------------------
# После включения компьютера Windows поднимает СВОЙ набор экранов, а не тот,
# который был выбран перед выключением: своё представление о раскладке она хранит
# сама, нам о нём не докладывает и восстанавливает как считает нужным. В журнале
# это видно за все дни разом — почти за каждым «tray: started» через секунды или
# минуты идёт переключение руками. Значит выбор надо помнить нам самим и
# возвращать его при старте трея (Invoke-StartupRestore в Displays.ps1).
#
# Отдельным файлом, а не полем в settings.json: настройки лежат под git и правятся
# человеком, а это состояние машины, меняющееся на каждом переключении.

$script:SessionIdCache = ''

# Отпечаток текущего включения машины. Нужен, чтобы отличить «трей запустился
# после включения компьютера» от «трей перезапустили в той же сессии». В первом
# случае режим надо вернуть, во втором — экраны трогать нельзя: набор мог сменить
# сам человек через Win+P или параметры Windows, и это его решение.
#
# Два источника, потому что по отдельности ни одного не хватает:
#   * ShutdownTime — время последнего завершения работы. Меняется при каждом
#     выключении и перезагрузке, включая быстрый запуск (HiberbootEnabled=1 на
#     этой машине), при котором счётчик времени работы может продолжить прошлый;
#   * момент загрузки (сейчас минус время работы) — прикрывает случай, когда
#     завершения работы не было вовсе: сбой, Reset, потеря питания.
# Достаточно, чтобы ЛЮБОЙ из них изменился.
#
# Считаем один раз за процесс: в пределах одного включения ответ не меняется, а
# счётчик времени работы после долгого сна слегка уползает.
function Get-SystemSessionId {
    if ($script:SessionIdCache) { return $script:SessionIdCache }

    $parts = @()
    try {
        $raw = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Windows' `
                                 -Name 'ShutdownTime' -ErrorAction Stop).ShutdownTime
        $parts += ([System.BitConverter]::ToInt64([byte[]]$raw, 0)).ToString()
    }
    catch {
        # Значения нет — обходимся одним источником. Молча: это не поломка.
        $parts += 'no-shutdown-time'
    }

    # Минуты, а не секунды: два процесса считают это в разные моменты, и точность
    # до секунды здесь только создавала бы расхождения на ровном месте.
    $up = [System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency
    $parts += Format-DisplayStamp ((Get-Date).AddSeconds(-$up)) 'yyyy-MM-dd HH:mm'

    $script:SessionIdCache = ($parts -join '/')
    return $script:SessionIdCache
}

# Запомнить выбранный режим. Зовётся из Switch-DisplayMode на каждом доехавшем до
# конца переключении — и из трея, и из командной строки.
function Save-LastMode {
    param([Parameter(Mandatory)][string]$Key)

    try {
        [ordered]@{
            key     = $Key
            session = Get-SystemSessionId
            when    = (Get-Date).ToString('s')
        } | ConvertTo-Json -Compress |
            Set-Content -Path $script:LastModeFile -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Не запомнили — переключение всё равно состоялось. Ронять его нельзя.
        Write-DisplayLog "warn: could not remember the mode - $($_.Exception.Message)"
    }
}

# Что было выбрано в прошлый раз: Key, Session, When. $null, если файла нет или он
# нечитаем.
function Get-LastMode {
    if (-not (Test-Path $script:LastModeFile)) { return $null }
    try {
        $raw = Get-Content $script:LastModeFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $raw.key) { return $null }
        return [pscustomobject]@{
            Key     = [string]$raw.key
            Session = [string]$raw.session
            When    = [string]$raw.when
        }
    }
    catch {
        Write-DisplayLog "warn: the remembered mode is unreadable - $($_.Exception.Message)"
        return $null
    }
}

# --- проверенные режимы мониторов -------------------------------------------
# Что именно каждый монитор реально показывал в прошлый раз: путь -> {W;H;Hz}.
#
# Нужно, чтобы стол вставал одним переходом. Set-CcdFullConfig задаёт разрешение
# и частоту сразу, вместе с набором экранов, — но для ПОГАШЕННОГО монитора взять
# частоту негде: EnumDisplaySettings перечисляет режимы только у активного
# выхода, а из EDID система отдаёт лишь родное разрешение (Get-CcdTargets,
# GET_TARGET_PREFERRED_MODE). Без этого файла монитор, который просыпается —
# а он просыпается почти в каждом переключении, — поднимался бы на частоте из
# записи Windows, и её пришлось бы править вторым перестроением стола.
#
# Пишем то, что монитор ОТДАЛ, а не то, что мы просили: это заодно защита от
# невозможных режимов. 19 августа 2026 ULTRAGEAR по HDMI получил запрос на
# 2560x1440@240 («bad mode» в журнале) и остался на 144 — в файл уйдут именно
# 144, и следующее переключение попросит сразу их.
#
# Частота хранится ДРОБЬЮ (num/den), а не только целыми герцами, и это не
# педантизм. CCD принимает лишь точное значение: на этой машине 144 Гц — это
# 143999/1000, а 60 Гц — 59997/1000. Запрос «144/1» система отвергает целиком
# (проверено 20 августа, validate -> 1610), и переключение теряло подсказку о
# частоте. Целые герцы остаются рядом — по ним видно, к какому режиму дробь
# относится, и их читает человек.
#
# Отдельным файлом, а не полем в settings.json: настройки правит человек и они
# лежат под git, а это состояние машины.

function Get-ModeCache {
    if (-not (Test-Path $script:ModeCacheFile)) { return @{} }
    try {
        $raw = Get-Content $script:ModeCacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $out = @{}
        foreach ($p in $raw.PSObject.Properties) {
            $v = $p.Value
            if ($null -eq $v) { continue }
            $w = [int]$v.w; $h = [int]$v.h; $hz = [int]$v.hz
            # Мусор в файле не должен превратиться в запрос невозможного режима.
            if ($w -le 0 -or $h -le 0) { continue }
            $num = [int]$v.num; $den = [int]$v.den
            if ($num -le 0 -or $den -le 0) { $num = 0; $den = 0 }
            $out[$p.Name] = [pscustomobject]@{
                Width = $w; Height = $h; Hz = $hz
                RateNum = $num; RateDen = $den
            }
        }
        return $out
    }
    catch {
        # Испорченный файл — это всего лишь «частоту спящего монитора не знаем»:
        # переключение состоится, просто с ремонтным шагом. Молча, как и с
        # запомненным режимом.
        return @{}
    }
}

# Дописать в кэш то, что мониторы показывают сейчас. Слиянием, а не заменой:
# монитор, которого в этом режиме не было, свою запись сохраняет — она понадобится,
# когда его включат снова.
function Save-ModeCache {
    param([Parameter(Mandatory)]$Modes)

    if (@($Modes.Keys).Count -eq 0) { return }
    try {
        $merged = Get-ModeCache
        foreach ($k in @($Modes.Keys)) { $merged[$k] = $Modes[$k] }

        $flat = [ordered]@{}
        foreach ($k in @($merged.Keys | Sort-Object)) {
            $m = $merged[$k]
            $flat[$k] = [ordered]@{
                w   = [int]$m.Width
                h   = [int]$m.Height
                hz  = [int]$m.Hz
                num = [int]$m.RateNum
                den = [int]$m.RateDen
            }
        }
        $flat | ConvertTo-Json -Depth 4 -Compress |
            Set-Content -Path $script:ModeCacheFile -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Не записали — следующее переключение просто не будет знать частоту
        # спящего монитора. Ронять из-за кэша нечего.
        Write-DisplayLog "warn: could not remember the display modes - $($_.Exception.Message)"
    }
}

# Целевое состояние каждого монитора для перехода одним вызовом: DevicePath,
# Label, Width, Height, Hz. Пустой массив означает «так не выйдет» — вызывающий
# идёт старой дорогой из трёх шагов.
#
# Откуда берутся размеры, по убыванию доверия:
#   1. BestMode — он уже посчитан Get-DisplayState для включённого монитора;
#   2. кэш проверенных режимов — для того, кто сейчас спит (см. Get-ModeCache);
#   3. родное разрешение из EDID — есть даже у погашенного, но без частоты.
# При -KeepMode разрешение и частоту менять не просят, поэтому для включённого
# берётся то, что на нём стоит.
#
# Частота уходит дальше ДРОБЬЮ и только из кэша: CCD принимает лишь точное
# значение (144 Гц здесь — это 143999/1000), а целые герцы из EnumDisplaySettings
# округлены, и запрос по ним система отвергает. Дробь годится, только если она от
# ТОГО ЖЕ режима: кэш помнит 144 Гц, а просят 240 — значит дроби для 240 у нас нет,
# частоту выберет система, а ремонтный шаг доведёт её и научит кэш на будущее.
#
# Чистая функция: ничего не спрашивает у системы, только считает.
function Get-SwitchTargets {
    param(
        [Parameter(Mandatory)]$Wanted,
        $Cache = @{},
        [switch]$KeepMode
    )

    if (-not $Cache) { $Cache = @{} }
    $out = @()
    foreach ($m in @($Wanted)) {
        $w = 0; $h = 0; $hz = 0
        $cached = $null
        if ($Cache.ContainsKey([string]$m.Id)) { $cached = $Cache[[string]$m.Id] }

        if ($KeepMode -and $m.Active -and $m.Width -gt 0 -and $m.Height -gt 0) {
            $w = [int]$m.Width; $h = [int]$m.Height; $hz = [int]$m.Hz
        }
        elseif (-not $KeepMode -and $m.BestMode) {
            $w = [int]$m.BestMode.Width; $h = [int]$m.BestMode.Height; $hz = [int]$m.BestMode.Hz
        }
        elseif ($cached) {
            $w = [int]$cached.Width; $h = [int]$cached.Height
            # При -KeepMode частоту не навязываем: человек просил не трогать режим.
            if (-not $KeepMode) { $hz = [int]$cached.Hz }
        }
        elseif ($m.Native) {
            $w = [int]$m.Native.Width; $h = [int]$m.Native.Height
        }

        # Размеров нет ни одного — задать исходный режим нечем, а мешать заданные
        # с незаданными в одном запросе значит гадать, что система сделает с
        # остатком. Такой набор целиком уходит на старую дорогу.
        if ($w -le 0 -or $h -le 0) { return @() }

        $num = 0; $den = 0
        if ($hz -gt 0 -and $cached -and [int]$cached.RateDen -gt 0 -and
            [int]$cached.Width -eq $w -and [int]$cached.Height -eq $h -and [int]$cached.Hz -eq $hz) {
            $num = [int]$cached.RateNum; $den = [int]$cached.RateDen
        }

        $out += [pscustomobject]@{
            DevicePath = [string]$m.Id
            Label      = [string]$m.Label
            Width      = $w
            Height     = $h
            Hz         = $hz
            RateNum    = $num
            RateDen    = $den
        }
    }
    return $out
}

# --- разбор комбинаций клавиш -----------------------------------------------

$script:ModAlt = 0x1; $script:ModControl = 0x2; $script:ModShift = 0x4
$script:ModWin = 0x8; $script:ModNoRepeat = 0x4000

# "Ctrl+Alt+F1" -> @{ Modifiers = 3; Vk = 0x70 }. $null, если разобрать нельзя.
function ConvertFrom-HotkeyString {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $mods = 0
    $key = $null
    foreach ($part in ($Text -split '\+')) {
        switch ($part.Trim().ToUpperInvariant()) {
            'CTRL'    { $mods = $mods -bor $script:ModControl }
            'CONTROL' { $mods = $mods -bor $script:ModControl }
            'ALT'     { $mods = $mods -bor $script:ModAlt }
            'SHIFT'   { $mods = $mods -bor $script:ModShift }
            'WIN'     { $mods = $mods -bor $script:ModWin }
            default   { $key = $part.Trim().ToUpperInvariant() }
        }
    }
    if (-not $key) { return $null }

    $vk = 0
    if ($key -match '^F([1-9]|1[0-9]|2[0-4])$') { $vk = 0x70 + [int]$Matches[1] - 1 }
    elseif ($key -match '^[A-Z]$')              { $vk = [int][char]$key }
    elseif ($key -match '^[0-9]$')              { $vk = 0x30 + [int]$key }
    else { return $null }

    # Без модификатора глобальная клавиша отобрала бы её у всей системы.
    if ($mods -eq 0) { return $null }

    return [pscustomobject]@{ Modifiers = $mods; Vk = $vk; Text = (Format-HotkeyString $mods $vk) }
}

function Format-HotkeyString {
    param([int]$Modifiers, [int]$Vk)

    $parts = @()
    if ($Modifiers -band $script:ModControl) { $parts += 'Ctrl' }
    if ($Modifiers -band $script:ModAlt)     { $parts += 'Alt' }
    if ($Modifiers -band $script:ModShift)   { $parts += 'Shift' }
    if ($Modifiers -band $script:ModWin)     { $parts += 'Win' }

    $key = ''
    if ($Vk -ge 0x70 -and $Vk -le 0x87)      { $key = 'F' + ($Vk - 0x70 + 1) }
    elseif ($Vk -ge 0x41 -and $Vk -le 0x5A)  { $key = [char]$Vk }
    elseif ($Vk -ge 0x30 -and $Vk -le 0x39)  { $key = [char]$Vk }
    else                                     { $key = "VK$Vk" }

    $parts += $key
    return ($parts -join '+')
}

# --- тема оформления ----------------------------------------------------------
# Меню трея и окно настроек рисуются под системную тему. Оба факта — тёмная ли
# тема и какой акцентный цвет — Windows держит в реестре; официального API для
# Win32-приложений так и нет (UISettings — это WinRT, и тянуть его в PowerShell
# 5.1 дороже, чем прочитать два значения). Читается при каждом открытии меню или
# окна, поэтому смена темы подхватывается без перезапуска.

# Тёмная ли тема ПРИЛОЖЕНИЙ (в Windows она отдельная от темы системы). Значения
# нет на старых сборках — тогда светлая, как и было до появления тёмной.
function Test-DarkTheme {
    try {
        $v = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
                              -Name 'AppsUseLightTheme' -ErrorAction Stop
        return ($v.AppsUseLightTheme -eq 0)
    }
    catch { return $false }
}

# Акцентный цвет системы, строкой #RRGGBB.
#
# Основной источник — AccentPalette: 8 цветов по 4 байта RGBA, от светлого к
# тёмному, базовый — четвёртый (индекс 3). Нужен он потому, что у палитры есть
# осветлённые варианты: на тёмном фоне сам акцент часто нечитаем (у Windows он
# может быть почти чёрным), и система в тёмной теме использует light2 (индекс 1)
# — его и просим через -ForDarkTheme. Нет палитры — берём DWM AccentColor (там
# ABGR-число), нет и его — синий по умолчанию, как у Windows из коробки.
function Get-AccentColor {
    param([switch]$ForDarkTheme)

    try {
        $pal = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent' `
                                 -Name 'AccentPalette' -ErrorAction Stop).AccentPalette
        if ($pal -and $pal.Count -ge 32) {
            $i = $(if ($ForDarkTheme) { 1 } else { 3 }) * 4
            return ('#{0:X2}{1:X2}{2:X2}' -f $pal[$i], $pal[$i + 1], $pal[$i + 2])
        }
    }
    catch { }

    try {
        $abgr = [uint32]((Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' `
                                           -Name 'AccentColor' -ErrorAction Stop).AccentColor)
        return ('#{0:X2}{1:X2}{2:X2}' -f ($abgr -band 0xFF), (($abgr -shr 8) -band 0xFF), (($abgr -shr 16) -band 0xFF))
    }
    catch { }

    return $(if ($ForDarkTheme) { '#4CC2FF' } else { '#0067C0' })
}

# --- Windows API ------------------------------------------------------------
# Все классы живут в ОДНОМ исходнике и компилируются одним вызовом.
#
# Раньше их было четыре отдельных Add-Type (три здесь и HotkeyWindow в
# Displays.ps1), а каждый Add-Type -TypeDefinition — это отдельная компиляция.
# Замер на этой машине: 129 + 75 + 75 + 87 мс, то есть треть секунды на каждый
# запуск CLI и на каждый старт трея. (В плане стояло «~2 с на каждый» — это
# оказалось неверно, csc здесь заметно быстрее, чем ожидалось.)
#
# Комментарий «отдельным классом, а не полем в NativeDisplay» относился к
# ДОПИСЫВАНИЮ в уже скомпилированный тип — так действительно нельзя без
# перезапуска процесса. Совместной компиляции с нуля это не противоречит.

$script:NativeSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class NativeDisplay {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields;
        public int dmPositionX, dmPositionY;
        public int dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType;
        public int dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, int dwflags, IntPtr lParam);

    // Тот же вызов, но с возможностью передать NULL вместо DEVMODE: так подаётся
    // финальное «применить всё накопленное» после серии CDS_NORESET.
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
    public static extern int ChangeDisplaySettingsExApply(string lpszDeviceName, IntPtr lpDevMode, IntPtr hwnd, int dwflags, IntPtr lParam);

    public const int ATTACHED_TO_DESKTOP = 0x00000001;   // у адаптера
    public const int MONITOR_ACTIVE = 0x00000001;        // у дочернего монитора (DISPLAY_DEVICE_ACTIVE)
    public const int CURRENT_SETTINGS = -1;

    public const int DM_POSITION = 0x00000020;
    public const int DM_BITSPERPEL = 0x00040000;
    public const int DM_PELSWIDTH = 0x00080000;
    public const int DM_PELSHEIGHT = 0x00100000;
    public const int DM_DISPLAYFREQUENCY = 0x00400000;

    public const int CDS_UPDATEREGISTRY = 0x00000001;
    public const int CDS_SET_PRIMARY = 0x00000010;
    public const int CDS_NORESET = 0x10000000;
    public const int PRIMARY_DEVICE = 0x00000004;
}

// --- CCD: современный API конфигурации дисплеев ---------------------------
// Зачем он здесь, если есть и MultiMonitorTool, и старый API.
//
// 1. Скорость. QueryDisplayConfig отвечает за ~1 мс, дамп MultiMonitorTool —
//    за 1100 мс. Дамп делался на каждом переключении, на каждом открытии меню
//    и на каждом срабатывании сторожа.
// 2. Выключенный монитор. Для MultiMonitorTool его просто нет: в дампе
//    остаётся строка без имени, без короткого ID и с пустым Monitor ID
//    (проверено 7 августа: оба погашенных LG схлопнулись в одну безымянную
//    строку). Включить такой монитор по имени нечем — отсюда `/enable ` с
//    пустым аргументом в журнале. CCD же перечисляет и неактивные цели.
// 3. Родное разрешение. GET_TARGET_PREFERRED_MODE отдаёт preferred timing из
//    EDID силами системы — и для выключенного монитора тоже. Разбор EDID из
//    реестра вручную больше не нужен.
public class NativeCcd {
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] public struct RATIONAL { public uint Numerator, Denominator; }

    [StructLayout(LayoutKind.Sequential)] public struct SOURCE_INFO {
        public LUID adapterId; public uint id, modeInfoIdx, statusFlags; }

    [StructLayout(LayoutKind.Sequential)] public struct TARGET_INFO {
        public LUID adapterId; public uint id, modeInfoIdx, outputTechnology, rotation, scaling;
        public RATIONAL refreshRate; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags; }

    [StructLayout(LayoutKind.Sequential)] public struct PATH_INFO {
        public SOURCE_INFO sourceInfo; public TARGET_INFO targetInfo; public uint flags; }

    // Явная раскладка: из объединения нужны только поля исходного режима —
    // положение, по которому Windows определяет основной монитор. Остальное
    // (тайминги цели) не трогаем, поэтому под него просто оставлено место.
    // Размер обязан быть 64 байта.
    [StructLayout(LayoutKind.Explicit)] public struct MODE_INFO {
        [FieldOffset(0)]  public uint infoType;
        [FieldOffset(4)]  public uint id;
        [FieldOffset(8)]  public LUID adapterId;
        [FieldOffset(16)] public uint srcWidth;
        [FieldOffset(20)] public uint srcHeight;
        [FieldOffset(24)] public uint srcPixelFormat;
        [FieldOffset(28)] public int  srcPosX;
        [FieldOffset(32)] public int  srcPosY;
        [FieldOffset(56)] public ulong tail; }

    [StructLayout(LayoutKind.Sequential)] public struct HEADER {
        public uint type, size; public LUID adapterId; public uint id; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct TARGET_DEVICE_NAME {
        public HEADER header; public uint flags, outputTechnology;
        public ushort edidManufactureId, edidProductCodeId; public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct SOURCE_DEVICE_NAME {
        public HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName; }

    [StructLayout(LayoutKind.Sequential)] public struct VIDEO_SIGNAL_INFO {
        public ulong pixelRate; public RATIONAL hSyncFreq, vSyncFreq;
        public uint activeCx, activeCy, totalCx, totalCy, misc, scanLineOrdering; }

    [StructLayout(LayoutKind.Sequential)] public struct TARGET_PREFERRED_MODE {
        public HEADER header; public uint width, height; public VIDEO_SIGNAL_INFO targetMode; }

    [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint flags, ref uint numPath, ref uint numMode);
    [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint flags, ref uint numPath, [Out] PATH_INFO[] paths, ref uint numMode, [Out] MODE_INFO[] modes, IntPtr info);
    [DllImport("user32.dll")] public static extern int SetDisplayConfig(uint numPath, [In] PATH_INFO[] paths, uint numMode, [In] MODE_INFO[] modes, uint flags);
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref TARGET_DEVICE_NAME d);
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref SOURCE_DEVICE_NAME d);
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref TARGET_PREFERRED_MODE d);

    // HDR здесь намеренно НЕ объявлен. Проверено 2026-08-11: HDR переживает
    // смену набора мониторов, возвращать его не надо (подробности и рецепт на
    // случай, если это изменится, — в PLAN.md, пункт 3.4).

    public const uint QDC_ALL_PATHS = 1;
    public const uint QDC_ONLY_ACTIVE_PATHS = 2;

    public const uint GET_SOURCE_NAME = 1;
    public const uint GET_TARGET_NAME = 2;
    public const uint GET_TARGET_PREFERRED_MODE = 3;

    public const uint PATH_ACTIVE = 0x00000001;
    public const uint MODE_IDX_INVALID = 0xFFFFFFFF;
    public const uint MODE_INFO_TYPE_SOURCE = 1;

    // Формат пикселя исходного режима: 32 бита. Обязателен, когда режим задаём мы
    // сами (Set-CcdFullConfig): ноль здесь — недопустимое значение, и валидация
    // отвечает отказом.
    public const uint PIXELFORMAT_32BPP = 4;
    // Развёртка цели: прогрессивная. Идёт вместе с частотой, когда частота
    // передаётся подсказкой в targetInfo (см. Set-CcdFullConfig).
    public const uint SCANLINE_PROGRESSIVE = 1;
    // Без поворота и без растяжения. Нужны там же: у ПОГАШЕННОГО пути система
    // отдаёт эти поля нулями, а ноль в обоих перечислениях недопустим, и вместе
    // с заданной частотой такой путь валидацию не проходит.
    public const uint ROTATION_IDENTITY = 1;
    public const uint SCALING_IDENTITY = 1;

    public const uint SDC_VALIDATE = 0x00000040;
    public const uint SDC_APPLY = 0x00000080;
    public const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;
    public const uint SDC_ALLOW_CHANGES = 0x00000400;
    public const uint SDC_SAVE_TO_DATABASE = 0x00000200;
}

public class NativeForeground {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public int dwFlags;
    }

    [DllImport("shell32.dll")]
    public static extern int SHQueryUserNotificationState(out int pquns);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    [DllImport("user32.dll", EntryPoint = "GetClassNameW", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    public const uint MONITOR_DEFAULTTONEAREST = 2;
}

// Яркость и контраст — по DDC/CI, служебному каналу внутри кабеля. Это тот же
// путь, по которому работают кнопки на корпусе монитора, и другого способа нет:
// у внешнего монитора яркость живёт в его прошивке, а не в Windows (WMI-класс
// WmiMonitorBrightnessMethods отвечает только на встроенных экранах ноутбуков).
//
// Дескриптор физического монитора берётся от HMONITOR, а тот приходит из обхода
// EnumDisplayMonitors. Связываем с нашим состоянием по имени выхода (\\.\DISPLAY1)
// из MONITORINFOEX: описание («Generic PnP Monitor») не годится — оно одинаковое
// у всех трёх мониторов на этой машине.
//
// ВАЖНО про скорость: один запрос по DDC стоит десятки миллисекунд, а иногда и
// больше сотни — шина медленная. Поэтому читаем всё разом одним обходом, а пишем
// только то, что просили, и только тем мониторам, которые сейчас включены:
// спящий монитор на запрос не отвечает вообще, и ждать его нечего.
public class MonitorLevels {
    public string Device;
    public string Description;
    public bool CanBrightness;
    public bool CanContrast;
    public int Brightness, BrightnessMin, BrightnessMax;
    public int Contrast, ContrastMin, ContrastMax;
}

public class NativeDdc {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX {
        public int cbSize;
        public int mLeft, mTop, mRight, mBottom;
        public int wLeft, wTop, wRight, wBottom;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PHYSICAL_MONITOR {
        public IntPtr handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string description;
    }

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr rect, IntPtr data);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr rect, MonitorEnumProc proc, IntPtr data);

    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfoEx(IntPtr hMonitor, ref MONITORINFOEX info);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetMonitorBrightness(IntPtr h, out uint min, out uint current, out uint max);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetMonitorBrightness(IntPtr h, uint value);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetMonitorContrast(IntPtr h, out uint min, out uint current, out uint max);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetMonitorContrast(IntPtr h, uint value);

    [DllImport("dxva2.dll")]
    private static extern bool DestroyPhysicalMonitor(IntPtr h);

    // Имя выхода -> дескрипторы его физических мониторов. Их может быть больше
    // одного: HMONITOR — это область рабочего стола, и в режиме дублирования за
    // ней стоят два настоящих монитора.
    private static List<KeyValuePair<string, PHYSICAL_MONITOR>> Open() {
        var found = new List<KeyValuePair<string, PHYSICAL_MONITOR>>();
        var screens = new List<IntPtr>();
        MonitorEnumProc collect = delegate(IntPtr h, IntPtr hdc, IntPtr rect, IntPtr data) {
            screens.Add(h); return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, collect, IntPtr.Zero);

        foreach (IntPtr screen in screens) {
            var info = new MONITORINFOEX();
            info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (!GetMonitorInfoEx(screen, ref info)) { continue; }

            uint count;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(screen, out count) || count == 0) { continue; }
            var physical = new PHYSICAL_MONITOR[count];
            if (!GetPhysicalMonitorsFromHMONITOR(screen, count, physical)) { continue; }
            foreach (PHYSICAL_MONITOR p in physical) {
                found.Add(new KeyValuePair<string, PHYSICAL_MONITOR>(info.szDevice, p));
            }
        }
        return found;
    }

    // Одна неудача на этой шине — норма, а не ответ. I2C внутри кабеля не
    // рассчитан на надёжность: монитор отвечает с задержкой, путает контрольную
    // сумму (0xC0262589 — «неверная команда в сообщении»), молчит, если занят
    // своим меню. Проверено на этой машине: тот же вызов к тому же монитору то
    // проходит, то нет. Поэтому три попытки с паузой — часть работы, а не
    // перестраховка; последняя ошибка остаётся в GetLastWin32Error для журнала.
    private const int Tries = 3;
    private const int PauseMs = 60;

    public static int LastError;

    private static bool WithRetry(Func<bool> call) {
        for (int i = 0; i < Tries; i++) {
            if (call()) { return true; }
            LastError = Marshal.GetLastWin32Error();
            if (i + 1 < Tries) { System.Threading.Thread.Sleep(PauseMs); }
        }
        return false;
    }

    public static List<MonitorLevels> Read() {
        var result = new List<MonitorLevels>();
        foreach (var pair in Open()) {
            var level = new MonitorLevels();
            level.Device = pair.Key;
            level.Description = pair.Value.description;
            IntPtr handle = pair.Value.handle;

            uint bMin = 0, bCur = 0, bMax = 0;
            if (WithRetry(delegate { return GetMonitorBrightness(handle, out bMin, out bCur, out bMax); })) {
                level.CanBrightness = true;
                level.BrightnessMin = (int)bMin; level.Brightness = (int)bCur; level.BrightnessMax = (int)bMax;
            }
            uint cMin = 0, cCur = 0, cMax = 0;
            if (WithRetry(delegate { return GetMonitorContrast(handle, out cMin, out cCur, out cMax); })) {
                level.CanContrast = true;
                level.ContrastMin = (int)cMin; level.Contrast = (int)cCur; level.ContrastMax = (int)cMax;
            }
            DestroyPhysicalMonitor(handle);
            result.Add(level);
        }
        return result;
    }

    // Результат установки, по строке на каждый запрошенный монитор. Три
    // состояния, а не два, потому что их действительно три: получилось, отказано
    // и «сказали, но подтверждения нет».
    public class Applied {
        public string Device;
        public bool Found;
        public bool BrightnessAsked, BrightnessConfirmed;
        public bool ContrastAsked, ContrastConfirmed;
    }

    // Записи по DDC/CI ОТВЕТА НЕ ТРЕБУЮТ: SetMonitorBrightness вернул true для
    // монитора, который на чтение той же яркости отвечает отказом (проверено
    // 21 августа на LG UltraGear с зависшей шиной). То есть код возврата здесь
    // означает «сообщение ушло», а не «монитор послушался», и верить ему нельзя:
    // журнал этого проекта существует именно потому, что чужие переключалки врали
    // об успехе. Поэтому каждое значение читается обратно и сравнивается.
    //
    // ВСЕ мониторы разом, одним обходом — как и Read(), и по той же причине. Раньше
    // Set принимал один монитор, и на трёх мониторах перечисление с открытием и
    // закрытием ВСЕХ дескрипторов шло трижды: девять пар open/destroy вместо трёх
    // на медленной шине, где один запрос стоит десятки миллисекунд. Заодно пауза
    // «дай применить» теперь одна на всех: мониторы ждут параллельно, а не по
    // очереди, и с неё уходит по 120 мс на каждый монитор сверх первого.
    //
    // Строки brightness и contrast идут по номерам devices; -1 означает «этого не
    // просили».
    public static List<Applied> Set(string[] devices, int[] brightness, int[] contrast) {
        var result = new List<Applied>();
        for (int i = 0; i < devices.Length; i++) {
            var a = new Applied();
            a.Device = devices[i];
            result.Add(a);
        }

        var open = Open();
        try {
            // Кому из открытых мониторов какая строка запроса; -1 — этого не
            // просили. Считаем заранее, чтобы обход был один и в нём не было
            // поиска: в режиме дублирования за одним выходом стоят два монитора,
            // и второму та же строка достаться не должна.
            var slot = new int[open.Count];
            for (int j = 0; j < open.Count; j++) {
                slot[j] = -1;
                for (int i = 0; i < devices.Length; i++) {
                    if (devices[i] == open[j].Key && !result[i].Found) {
                        slot[j] = i;
                        result[i].Found = true;
                        break;
                    }
                }
            }

            bool asked = false;
            for (int j = 0; j < open.Count; j++) {
                if (slot[j] < 0) { continue; }
                Applied a = result[slot[j]];
                IntPtr handle = open[j].Value.handle;
                int wantB = brightness[slot[j]];
                int wantC = contrast[slot[j]];
                if (wantB >= 0) {
                    a.BrightnessAsked = WithRetry(delegate { return SetMonitorBrightness(handle, (uint)wantB); });
                }
                if (wantC >= 0) {
                    a.ContrastAsked = WithRetry(delegate { return SetMonitorContrast(handle, (uint)wantC); });
                }
                if (a.BrightnessAsked || a.ContrastAsked) { asked = true; }
            }

            // Монитору нужно время, чтобы применить и начать отвечать новым
            // значением: сразу после записи он ещё отдаёт старое.
            if (asked) { System.Threading.Thread.Sleep(120); }

            for (int j = 0; j < open.Count; j++) {
                if (slot[j] < 0) { continue; }
                Applied a = result[slot[j]];
                IntPtr handle = open[j].Value.handle;
                if (a.BrightnessAsked) {
                    uint min = 0, cur = 0, max = 0;
                    if (WithRetry(delegate { return GetMonitorBrightness(handle, out min, out cur, out max); })) {
                        a.BrightnessConfirmed = ((int)cur == brightness[slot[j]]);
                    }
                }
                if (a.ContrastAsked) {
                    uint min = 0, cur = 0, max = 0;
                    if (WithRetry(delegate { return GetMonitorContrast(handle, out min, out cur, out max); })) {
                        a.ContrastConfirmed = ((int)cur == contrast[slot[j]]);
                    }
                }
            }
        }
        finally {
            // Дескрипторы закрываем в любом случае: процесс трея живёт неделями, и
            // утечка по одному на монитор за переключение его бы и съела.
            foreach (var pair in open) { DestroyPhysicalMonitor(pair.Value.handle); }
        }
        return result;
    }
}

// Сон — единственное состояние, для которого нет консольной команды: shutdown.exe
// умеет выключение, перезагрузку и гибернацию, а «спать» в нём нет вообще.
public class NativePower {
    [DllImport("powrprof.dll", SetLastError = true)]
    public static extern bool SetSuspendState(bool hibernate, bool force, bool wakeupEventsDisabled);
}

// Кто сейчас на переднем плане, на каком мониторе, и давно ли трогали
// клавиатуру. Нужно правилам (условие «за компьютером не работают») и дневнику.
//
// Названия окон НЕ читаются намеренно: в заголовке окна лежит имя документа,
// адрес страницы и текст письма, а для «сколько времени в чём» достаточно имени
// процесса. Того, чего нет, не утечёт.
public class ActivitySample {
    public string Process;
    public string Device;
    public int IdleSeconds;
}

public class NativeActivity {
    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX {
        public int cbSize;
        public int mLeft, mTop, mRight, mBottom;
        public int wLeft, wTop, wRight, wBottom;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfoEx(IntPtr hMonitor, ref MONITORINFOEX info);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(int access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageNameW(IntPtr h, int flags, StringBuilder name, ref int size);

    private const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint MONITOR_DEFAULTTONULL = 0;

    public static int IdleSeconds() {
        var info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref info)) { return 0; }
        // Оба счётчика 32-битные и переполняются через 49 дней. Вычитание в
        // беззнаковой арифметике переживает переполнение правильно, приведение
        // к int после — нет, поэтому сначала вычитаем, потом приводим.
        uint now = (uint)Environment.TickCount;
        return (int)((now - info.dwTime) / 1000);
    }

    public static ActivitySample Sample() {
        var sample = new ActivitySample();
        sample.Process = "";
        sample.Device = "";
        sample.IdleSeconds = IdleSeconds();

        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) { return sample; }

        IntPtr screen = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL);
        if (screen != IntPtr.Zero) {
            var info = new MONITORINFOEX();
            info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (GetMonitorInfoEx(screen, ref info)) { sample.Device = info.szDevice; }
        }

        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        if (pid == 0) { return sample; }
        IntPtr proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (proc == IntPtr.Zero) { return sample; }
        try {
            var name = new StringBuilder(1024);
            int size = name.Capacity;
            if (QueryFullProcessImageNameW(proc, 0, name, ref size)) {
                string full = name.ToString();
                int slash = full.LastIndexOf('\\');
                string file = slash >= 0 ? full.Substring(slash + 1) : full;
                if (file.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) {
                    file = file.Substring(0, file.Length - 4);
                }
                sample.Process = file;
            }
        }
        finally { CloseHandle(proc); }
        return sample;
    }
}

// Вернуть системе память, которая была нужна один раз. PowerShell-процесс после
// старта держит ~75 МБ рабочего набора, но живого в нём — около десяти: остальное
// осталось от компиляции, чтения настроек и первого построения меню. Обрезка не
// врёт диспетчеру задач: страницы уходят в standby-список, система раздаёт их
// тем, кому они нужны, а к нам возвращаются по требованию — ценой миллисекунд
// на первом открытии меню после обрезки.
public class NativeMemory {
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern bool SetProcessWorkingSetSize(IntPtr process, IntPtr min, IntPtr max);

    public static void Trim() {
        SetProcessWorkingSetSize(GetCurrentProcess(), (IntPtr)(-1), (IntPtr)(-1));
    }
}

// Звук: список устройств вывода и назначение устройства по умолчанию.
//
// Внешних .exe не нужно. Список берётся документированным IMMDeviceEnumerator, а
// назначение — недокументированным IPolicyConfig: публичного API «сделать это
// устройство основным» в Windows нет вообще, им пользуются все переключалки
// звука, и он не меняется много лет.
//
// ОСТОРОЖНО с порядком методов в IPolicyConfig. У COM-интерфейса методы
// вызываются по номеру слота в таблице, а не по имени: если пропустить или
// перепутать хотя бы один, вызов уйдёт в СОСЕДНЮЮ функцию — например в
// SetDeviceFormat с мусором вместо формата. Поэтому объявлены все двенадцать
// слотов в точном порядке, хотя нужен из них один — одиннадцатый.
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorComObject { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
}

[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceCollection {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int Item(int index, out IMMDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    [PreserveSig] int OpenPropertyStore(int stgmAccess, out IPropertyStore properties);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out int state);
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int GetAt(int index, out PROPERTYKEY key);
    [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
    [PreserveSig] int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
    [PreserveSig] int Commit();
}

[StructLayout(LayoutKind.Sequential)]
public struct PROPERTYKEY { public Guid fmtid; public int pid; }

// Из объединения нужен один случай — VT_LPWSTR. На x64 данные начинаются с
// восьмого байта, поэтому указатель лежит там.
[StructLayout(LayoutKind.Explicit)]
public struct PROPVARIANT {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pointerValue;
}

[ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
public class PolicyConfigComObject { }

[ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPolicyConfig {
    [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr format);
    [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool isDefault, out IntPtr format);
    [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
    [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
    [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool isDefault, out IntPtr defaultPeriod, out IntPtr minimumPeriod);
    [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr period);
    [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr mode);
    [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
    [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool isFxStore, ref PROPERTYKEY key, out PROPVARIANT value);
    [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool isFxStore, ref PROPERTYKEY key, IntPtr value);
    [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int role);
    [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool visible);
}

public class AudioDev {
    public string Id;
    public string Name;
    public bool IsDefault;
}

public class NativeAudio {
    private const int RENDER = 0;              // eRender: вывод, не запись
    private const int DEVICE_STATE_ACTIVE = 1; // только живые устройства
    private const int STGM_READ = 0;

    // PKEY_Device_FriendlyName — «Динамики (Realtek)», то, что видно в системе.
    private static PROPERTYKEY FriendlyName() {
        PROPERTYKEY k = new PROPERTYKEY();
        k.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0");
        k.pid = 14;
        return k;
    }

    public static List<AudioDev> ListRenderDevices() {
        List<AudioDev> result = new List<AudioDev>();
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());

        string defaultId = "";
        IMMDevice def;
        if (en.GetDefaultAudioEndpoint(RENDER, 0, out def) == 0 && def != null) {
            def.GetId(out defaultId);
        }

        IMMDeviceCollection col;
        if (en.EnumAudioEndpoints(RENDER, DEVICE_STATE_ACTIVE, out col) != 0) return result;

        int count = 0;
        if (col.GetCount(out count) != 0) return result;

        for (int i = 0; i < count; i++) {
            IMMDevice dev;
            if (col.Item(i, out dev) != 0 || dev == null) continue;

            string id;
            if (dev.GetId(out id) != 0) continue;

            string name = "";
            IPropertyStore store;
            if (dev.OpenPropertyStore(STGM_READ, out store) == 0 && store != null) {
                PROPERTYKEY key = FriendlyName();
                PROPVARIANT v;
                if (store.GetValue(ref key, out v) == 0 && v.pointerValue != IntPtr.Zero) {
                    name = Marshal.PtrToStringUni(v.pointerValue);
                }
            }

            AudioDev d = new AudioDev();
            d.Id = id;
            d.Name = name == null ? "" : name;
            d.IsDefault = (id == defaultId);
            result.Add(d);
        }
        return result;
    }

    // role: 0 eConsole, 1 eMultimedia, 2 eCommunications
    public static int SetDefault(string deviceId, int role) {
        IPolicyConfig cfg = (IPolicyConfig)(new PolicyConfigComObject());
        return cfg.SetDefaultEndpoint(deviceId, role);
    }
}

// Позиции окон: перечисление и восстановление. Перебор сделан здесь, а не в
// PowerShell, по двум причинам: EnumWindows требует делегат (из PowerShell это
// хрупко и медленно), и на десятках окон каждый P/Invoke из скрипта стоит дороже
// самого вызова.
//
// GetWindowPlacement, а не GetWindowRect: он несёт и рамку нормального
// состояния, и признак «свёрнуто/развёрнуто». Развёрнутое окно через
// GetWindowRect вернуло бы координаты во весь экран, и восстановление сделало бы
// из него обычное окно такого размера — а нужно, чтобы оно осталось развёрнутым.
public class WinInfo {
    public IntPtr Hwnd;
    public int Pid;
    public string Title;
    public string Path;
    public int ShowCmd;
    public int NL, NT, NR, NB;      // rcNormalPosition
    public int MinX, MinY;          // ptMinPosition
    public int MaxX, MaxY;          // ptMaxPosition
}

public class NativeWindows {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct WRECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT {
        public int length;
        public int flags;
        public int showCmd;
        public POINT ptMinPosition;
        public POINT ptMaxPosition;
        public WRECT rcNormalPosition;
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLengthW(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] private static extern bool SetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT p);

    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(int access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool QueryFullProcessImageNameW(IntPtr h, int flags, StringBuilder name, ref int size);

    // Окно, которое системе принадлежит, а не пользователю: панели, всплывашки,
    // невидимые окна-обработчики. Их место на столе никого не интересует.
    private const int GWL_EXSTYLE = -20;
    private const int GWL_STYLE = -16;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_CHILD = 0x40000000;
    private const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    // DWM «прячет» окна магазинных приложений, не закрывая их: они остаются
    // видимыми по IsWindowVisible, но на столе их нет. Раскладывать их обратно
    // бессмысленно, а в снимок они попадали бы десятками.
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out int value, int size);
    private const int DWMWA_CLOAKED = 14;

    private static bool IsCloaked(IntPtr hWnd) {
        int cloaked = 0;
        try { if (DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, out cloaked, sizeof(int)) == 0) return cloaked != 0; }
        catch { }
        return false;
    }

    public static string PathOf(uint pid) {
        IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return "";
        try {
            StringBuilder sb = new StringBuilder(1024);
            int size = sb.Capacity;
            if (QueryFullProcessImageNameW(h, 0, sb, ref size)) return sb.ToString();
            return "";
        }
        finally { CloseHandle(h); }
    }

    public static List<WinInfo> Enumerate() {
        List<WinInfo> list = new List<WinInfo>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lp) {
            if (!IsWindowVisible(hWnd)) return true;
            if ((GetWindowLong(hWnd, GWL_STYLE) & WS_CHILD) != 0) return true;
            if ((GetWindowLong(hWnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) return true;
            if (GetWindowTextLengthW(hWnd) == 0) return true;
            if (IsCloaked(hWnd)) return true;

            WINDOWPLACEMENT p = new WINDOWPLACEMENT();
            p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
            if (!GetWindowPlacement(hWnd, ref p)) return true;

            StringBuilder sb = new StringBuilder(512);
            GetWindowTextW(hWnd, sb, sb.Capacity);

            uint pid = 0;
            GetWindowThreadProcessId(hWnd, out pid);

            WinInfo w = new WinInfo();
            w.Hwnd = hWnd;
            w.Pid = (int)pid;
            w.Title = sb.ToString();
            w.Path = PathOf(pid);
            w.ShowCmd = p.showCmd;
            w.NL = p.rcNormalPosition.Left;   w.NT = p.rcNormalPosition.Top;
            w.NR = p.rcNormalPosition.Right;  w.NB = p.rcNormalPosition.Bottom;
            w.MinX = p.ptMinPosition.X;       w.MinY = p.ptMinPosition.Y;
            w.MaxX = p.ptMaxPosition.X;       w.MaxY = p.ptMaxPosition.Y;
            list.Add(w);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static bool ApplyPlacement(IntPtr hWnd, int showCmd,
                                     int nl, int nt, int nr, int nb,
                                     int minX, int minY, int maxX, int maxY) {
        if (!IsWindow(hWnd)) return false;
        WINDOWPLACEMENT p = new WINDOWPLACEMENT();
        p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        p.flags = 0;
        p.showCmd = showCmd;
        p.ptMinPosition.X = minX; p.ptMinPosition.Y = minY;
        p.ptMaxPosition.X = maxX; p.ptMaxPosition.Y = maxY;
        p.rcNormalPosition.Left = nl; p.rcNormalPosition.Top = nt;
        p.rcNormalPosition.Right = nr; p.rcNormalPosition.Bottom = nb;
        return SetWindowPlacement(hWnd, ref p);
    }

    public static int PidOfWindow(IntPtr hWnd) {
        uint pid = 0;
        GetWindowThreadProcessId(hWnd, out pid);
        return (int)pid;
    }
}

// DPI-осведомлённость процесса. Нужна по двум причинам, и вторая важнее:
//
// 1. Косметика: окно настроек при масштабе 150% иначе растягивается системой из
//    100% и выглядит мылом.
// 2. Координаты. Снимок позиций окон (WindowLayout.ps1) читает и возвращает
//    прямоугольники в пикселях рабочего стола. Процесс, не осведомлённый о DPI,
//    получает их виртуализованными — система пересчитывает их под мнимые 96 dpi,
//    и на мониторах с разным масштабом снимок и восстановление говорили бы на
//    разных языках. Одна система координат на весь процесс снимает вопрос.
//
// PER_MONITOR_AWARE_V2 есть с Windows 10 1703. На более старых сборках
// SetProcessDpiAwarenessContext отсутствует или отдаёт ошибку — тогда откат на
// SetProcessDPIAware (system-aware), он есть с Vista.
public class NativeDpi {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4
    public static readonly IntPtr PER_MONITOR_AWARE_V2 = new IntPtr(-4);
}

// Приёмник горячих клавиш. Жил в Displays.ps1 и компилировался четвёртым
// отдельным вызовом; переехал сюда, чтобы компиляция была одна. Трею он нужен,
// CLI — нет, но неиспользованный класс в сборке ничего не стоит: ссылка на
// System.Windows.Forms разрешается лениво, при первом обращении к типу.
//
// RegisterHotKey требует HWND и работает только там, где крутится цикл сообщений.
public class HotkeyWindow : NativeWindow, IDisposable {
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int WM_HOTKEY = 0x0312;
    private int _nextId = 1;
    private readonly List<int> _ids = new List<int>();

    public event EventHandler<int> HotkeyPressed;

    public HotkeyWindow() { CreateHandle(new CreateParams()); }

    // MOD_ALT 1 | MOD_CONTROL 2 | MOD_SHIFT 4 | MOD_WIN 8 | MOD_NOREPEAT 0x4000
    public int Register(uint modifiers, uint vk) {
        int id = _nextId++;
        if (!RegisterHotKey(Handle, id, modifiers, vk)) return -1;
        _ids.Add(id);
        return id;
    }

    public void UnregisterAll() {
        foreach (int id in _ids) { UnregisterHotKey(Handle, id); }
        _ids.Clear();
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            EventHandler<int> h = HotkeyPressed;
            if (h != null) h(this, (int)m.WParam);
        }
        base.WndProc(ref m);
    }

    public void Dispose() { UnregisterAll(); DestroyHandle(); }
}

// Оформление окон через DWM: тёмный заголовок и скруглённые углы. Появлялись
// они в Windows постепенно (тёмный заголовок — атрибут 19, с 20H1 — 20; углы —
// только в Windows 11), поэтому оба метода Try*: на старой сборке вызов молча
// возвращает ошибку, и окно остаётся как было — со светлым заголовком и
// прямыми углами. Ломать из-за косметики нечего.
public static class NativeTheme {
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;   // сборки 1809-1909
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE     = 20;   // с 20H1
    private const int DWMWA_WINDOW_CORNER_PREFERENCE    = 33;   // с Windows 11
    private const int DWMWCP_ROUND      = 2;
    private const int DWMWCP_ROUNDSMALL = 3;

    public static void TryDarkTitleBar(IntPtr hwnd, bool dark) {
        int v = dark ? 1 : 0;
        if (DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref v, 4) != 0)
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, ref v, 4);
    }

    public static void TryRoundCorners(IntPtr hwnd, bool small) {
        int v = small ? DWMWCP_ROUNDSMALL : DWMWCP_ROUND;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref v, 4);
    }
}

// Отрисовка меню трея в духе Windows 11: плоский фон под системную тему,
// скруглённая подсветка строки, галочка в цвет акцента. Штатные отрисовщики
// WinForms застряли в прошлом — System рисует Windows 7, Professional рисует
// Office 2007 с градиентами, — а сам значок в трее без WinForms не живёт,
// поэтому современный вид меню достижим только своим ToolStripRenderer.
//
// Цвета приходят из PowerShell готовыми (там же читается тема и акцент):
// рендерер создаётся на каждое открытие меню, и смена темы Windows
// подхватывается без перезапуска трея.
//
// Смысловые роли строк передаются через Tag: "header" — заголовок раздела,
// "info" — информационная строка (CONNECTED DISPLAYS). Обе выключены, чтобы
// не ловить клики, но заголовок должен быть приглушён, а информация — читаться
// как обычный текст: с системным отрисовщиком всё это было одинаково серым.
public class ModernMenuRenderer : ToolStripRenderer {
    private readonly Color _back, _text, _dim, _hover, _line, _accent;

    public ModernMenuRenderer(bool dark, Color accent) {
        _accent = accent;
        if (dark) {
            _back  = Color.FromArgb(0x2C, 0x2C, 0x2C);
            _text  = Color.FromArgb(0xF2, 0xF2, 0xF2);
            // Приглушённый тон, а не «почти фон»: им пишутся режим монитора и заголовки
            // разделов, и на 0x8F они читались с трудом (контраст к фону ~4:1).
            _dim   = Color.FromArgb(0xAD, 0xAD, 0xAD);
            _hover = Color.FromArgb(0x3D, 0x3D, 0x3D);
            _line  = Color.FromArgb(0x45, 0x45, 0x45);
        } else {
            _back  = Color.FromArgb(0xF9, 0xF9, 0xF9);
            _text  = Color.FromArgb(0x1B, 0x1B, 0x1B);
            _dim   = Color.FromArgb(0x66, 0x66, 0x66);
            _hover = Color.FromArgb(0xEA, 0xEA, 0xEA);
            _line  = Color.FromArgb(0xE0, 0xE0, 0xE0);
        }
    }

    private static GraphicsPath Rounded(Rectangle r, int radius) {
        var p = new GraphicsPath();
        int d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
        using (var b = new SolidBrush(_back)) e.Graphics.FillRectangle(b, e.AffectedBounds);
    }

    // Пустое намеренно: полоса под значки не должна отличаться от фона.
    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }

    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) {
        // Тонкая рамка, чтобы меню не сливалось с тем, что под ним. Углы у неё
        // прямые — на Windows 11 их срежет DWM вместе с углами самого окна.
        var r = new Rectangle(0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
        using (var p = new Pen(_line)) e.Graphics.DrawRectangle(p, r);
    }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        var g = e.Graphics;
        var r = new Rectangle(3, 1, e.Item.Width - 6, e.Item.Height - 2);
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Rounded(r, 4))
        using (var b = new SolidBrush(_hover)) g.FillPath(b, path);
        g.SmoothingMode = old;
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        if (e.Vertical) { base.OnRenderSeparator(e); return; }
        int y = e.Item.Height / 2;
        using (var p = new Pen(_line)) e.Graphics.DrawLine(p, 10, y, e.Item.Width - 10, y);
    }

    // Цвет ЗАДАЁМ САМИ, потому что базовый ToolStripRenderer.OnRenderItemText
    // делает `textColor = item.Enabled ? textColor : SystemColors.GrayText` — то
    // есть для любой выключенной строки выбрасывает наш цвет и берёт системный
    // тёмно-серый. А строки мониторов выключены намеренно (по ним нельзя щёлкать),
    // и на тёмном фоне системный серый читался с трудом: раздел CONNECTED
    // DISPLAYS выглядел как выцветшая заглушка, хотя это самое полезное в меню.
    //
    // Заодно строка монитора рисуется в два тона: название — полной яркостью,
    // режим и пометки — приглушённо. Так видно и что подключено, и на чём оно
    // стоит, без того чтобы второе спорило с первым за внимание.
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        bool header = "header".Equals(e.Item.Tag as string);
        bool info   = "info".Equals(e.Item.Tag as string);

        if (e.Item.Enabled) {
            // Комбинация клавиш тише названия режима: она подсказка, а не сам пункт.
            // ToolStripMenuItem рисует её отдельным вызовом с тем же цветом, что и
            // текст, и меню выходило одинаково громким по всей ширине.
            var mi = e.Item as ToolStripMenuItem;
            bool isShortcut = mi != null && !string.IsNullOrEmpty(mi.ShortcutKeyDisplayString)
                              && e.Text == mi.ShortcutKeyDisplayString;
            e.TextColor = isShortcut ? _dim : _text;
            base.OnRenderItemText(e);
            return;
        }

        // Горизонтальное выравнивание убираем: части рисуются подряд, слева.
        // NoPadding — чтобы измеренная ширина названия совпала с нарисованной,
        // иначе второй тон уезжал бы на пиксель-два от первого.
        TextFormatFlags flags = (e.TextFormat | TextFormatFlags.NoPadding)
                                & ~(TextFormatFlags.HorizontalCenter | TextFormatFlags.Right);
        Rectangle r = e.TextRectangle;

        int split = info ? e.Text.IndexOf("    ") : -1;
        if (split <= 0) {
            // Заголовок раздела, недоступный режим или строка без разделителя —
            // одним тоном. Заголовок приглушён намеренно, он служебный.
            TextRenderer.DrawText(e.Graphics, e.Text, e.TextFont, r,
                                  (header || !info) ? _dim : _text, flags);
            return;
        }

        string name = e.Text.Substring(0, split);
        string rest = e.Text.Substring(split);
        Size nameSize = TextRenderer.MeasureText(e.Graphics, name, e.TextFont,
                                                new Size(int.MaxValue, r.Height), flags);
        TextRenderer.DrawText(e.Graphics, name, e.TextFont, r, _text, flags);
        Rectangle tail = new Rectangle(r.X + nameSize.Width, r.Y,
                                       Math.Max(0, r.Width - nameSize.Width), r.Height);
        TextRenderer.DrawText(e.Graphics, rest, e.TextFont, tail, _dim, flags);
    }

    // Точку состояния рисуем сами, полным цветом. Базовый отрисовщик прогоняет
    // картинку выключенного пункта через ControlPaint.DrawImageDisabled, а строки
    // мониторов выключены намеренно (по ним нельзя щёлкать) — и зелёная точка
    // «на максимуме», янтарная «частота ниже» и серая «выключен» превращались в
    // три одинаковых серых пятна. Проверено пиксельным дампом офф-скрин рендера:
    // #828282, #7D7D7D, #8B8B8B вместо зелёного, янтарного и серого.
    protected override void OnRenderItemImage(ToolStripItemImageRenderEventArgs e) {
        if (e.Image == null) { base.OnRenderItemImage(e); return; }
        e.Graphics.DrawImage(e.Image, e.ImageRectangle);
    }

    // Галочка текущего режима — рисуется пером, а не глифом шрифта: Segoe MDL2
    // есть не везде, а GDI+ при отсутствии шрифта молча подставляет другой, и
    // вместо галочки вышел бы квадратик.
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
        var g = e.Graphics;
        var r = e.ImageRectangle;
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var p = new Pen(_accent, 1.8f)) {
            p.StartCap = LineCap.Round;
            p.EndCap = LineCap.Round;
            p.LineJoin = LineJoin.Round;
            g.DrawLines(p, new PointF[] {
                new PointF(r.Left + r.Width * 0.24f, r.Top + r.Height * 0.55f),
                new PointF(r.Left + r.Width * 0.44f, r.Top + r.Height * 0.74f),
                new PointF(r.Left + r.Width * 0.78f, r.Top + r.Height * 0.30f) });
        }
        g.SmoothingMode = old;
    }
}
'@

# Компиляция один раз, дальше — из кэша рядом со скриптами.
#
# Имя сборки содержит первые 8 hex SHA256 от исходника: правишь C# — меняется
# хэш — собирается заново, а старые файлы удаляются. Забыть пересобрать нельзя
# по построению.
#
# Любой сбой кэша (папка только для чтения, занятый файл, гонка двух процессов)
# не должен ронять инструмент: тогда просто компилируем в память, как раньше, и
# пишем причину в журнал.
function Initialize-NativeTypes {
    # Уже в этой сессии — выходим. Проверка по NativeDisplay покрывает все
    # четыре класса: они собираются вместе и появляются вместе.
    if ('NativeDisplay' -as [type]) { return }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # System.Drawing — ради ModernMenuRenderer: цвета, перья и кисти оттуда.
    $refs = @('System.Windows.Forms', 'System.Drawing')
    $how = 'compiled'

    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:NativeSource)) }
        finally { $sha.Dispose() }
        $hash = -join ($digest[0..3] | ForEach-Object { $_.ToString('x2') })

        $name = "native-$hash.dll"
        $dll = Join-Path $script:ToolRoot $name

        # Сборки от прошлых версий исходника только занимают место и путают.
        # Молча пропускаем занятые: трей живёт неделями и держит свою сборку
        # открытой, поэтому сразу после правки C# старый файл удалить нельзя —
        # он уйдёт при следующем запуске, уже после перезапуска трея.
        foreach ($old in @(Get-ChildItem -Path $script:ToolRoot -Filter 'native-*.dll' -ErrorAction SilentlyContinue)) {
            if ($old.Name -ne $name) { Remove-Item $old.FullName -Force -ErrorAction SilentlyContinue }
        }

        if (Test-Path $dll) {
            Add-Type -Path $dll
            $how = 'cache'
        }
        else {
            # Собираем во временный файл с номером процесса в имени и только
            # потом переименовываем: трей и CLI могут стартовать одновременно, и
            # писать двумя процессами в один файл нельзя.
            $tmp = Join-Path $script:ToolRoot ("native-$hash.$PID.tmp")
            Add-Type -TypeDefinition $script:NativeSource -ReferencedAssemblies $refs -OutputAssembly $tmp
            try { Move-Item -LiteralPath $tmp -Destination $dll -Force }
            catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

            # -OutputAssembly в PS 5.1 типы в сессию НЕ загружает, поэтому
            # догружаем из файла. Проверка на случай, если поведение иное.
            if (-not ('NativeDisplay' -as [type])) { Add-Type -Path $dll }
        }
    }
    catch {
        Write-DisplayLog "core: dll cache failed - $($_.Exception.Message)"
        if (-not ('NativeDisplay' -as [type])) {
            Add-Type -TypeDefinition $script:NativeSource -ReferencedAssemblies $refs
        }
        $how = 'compiled'
    }

    Write-DisplayLog ("core: native types ready in {0} ms ({1})" -f [int]$sw.ElapsedMilliseconds, $how)
}

Initialize-NativeTypes

# Объявить процесс DPI-осведомлённым можно только ДО создания первого окна и до
# первого запроса метрик — потом система игнорирует вызов. Поэтому это делается
# здесь, сразу за типами, а не в Displays.ps1: DisplayCore подключается первой
# строкой и в трее, и в CLI.
#
# Вызывается один раз за процесс: повторный вызов вернул бы ошибку, и в журнал
# посыпались бы `dpi:` строки на каждое обращение.
$script:DpiSet = $false

function Initialize-DpiAwareness {
    if ($script:DpiSet) { return }
    $script:DpiSet = $true

    try {
        if ([NativeDpi]::SetProcessDpiAwarenessContext([NativeDpi]::PER_MONITOR_AWARE_V2)) { return }
    }
    catch { }   # на старых сборках самой функции нет — это не ошибка

    # Откат: system-aware. Хуже, чем per-monitor (при переезде окна между
    # мониторами с разным масштабом его отрисует система), но координаты хотя бы
    # не виртуализуются.
    try {
        if ([NativeDpi]::SetProcessDPIAware()) {
            Write-DisplayLog 'core: per-monitor DPI is unavailable, fell back to system-aware'
            return
        }
    }
    catch { }

    # Уже осведомлён (например задано в манифесте или через переменную окружения) —
    # оба вызова вернут false, и это нормально. Молчим, чтобы не пугать журнал.
}

Initialize-DpiAwareness

function New-DisplayDevice {
    $d = New-Object NativeDisplay+DISPLAY_DEVICE
    $d.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($d)
    return $d
}

# --- чтение состояния через CCD ---------------------------------------------

# Код производителя из EDID: три буквы, упакованные по 5 бит. Windows отдаёт
# слово в обратном порядке байт, поэтому его надо развернуть. Если после
# разворота получаются не буквы — берём как есть, чтобы не выдумывать.
function ConvertTo-VendorCode {
    param([int]$Raw)

    foreach ($v in @(((($Raw -band 0xFF) -shl 8) -bor (($Raw -shr 8) -band 0xFF)), $Raw)) {
        $s = ''
        foreach ($shift in 10, 5, 0) { $s += [char]((($v -shr $shift) -band 0x1F) + 64) }
        if ($s -match '^[A-Z]{3}$') { return $s }
    }
    return ''
}

# Все цели, известные системе: и включённые, и просто подключённые.
function Get-CcdTargets {
    $M = [System.Runtime.InteropServices.Marshal]

    $np = 0; $nm = 0
    if ([NativeCcd]::GetDisplayConfigBufferSizes([NativeCcd]::QDC_ALL_PATHS, [ref]$np, [ref]$nm) -ne 0) { return @() }
    $paths = New-Object 'NativeCcd+PATH_INFO[]' $np
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $nm
    if ([NativeCcd]::QueryDisplayConfig([NativeCcd]::QDC_ALL_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) { return @() }

    # QDC_ALL_PATHS отдаёт все сочетания «источник x цель» — у трёх мониторов это
    # под шесть десятков путей. Сначала сводим их к одному пути на цель (активный
    # предпочтительнее: у него заполнено имя выхода), и только потом спрашиваем
    # имена. Иначе на каждый из 58 путей уходило по три вызова, и чтение стоило
    # 200 мс вместо 10.
    $pick = [ordered]@{}
    for ($i = 0; $i -lt $np; $i++) {
        $ti = $paths[$i].targetInfo
        $tk = '{0}:{1}:{2}' -f $ti.adapterId.Low, $ti.adapterId.High, $ti.id
        if (-not $pick.Contains($tk)) { $pick[$tk] = $i }
        elseif (($paths[$i].flags -band [NativeCcd]::PATH_ACTIVE) -ne 0) { $pick[$tk] = $i }
    }

    $byPath = [ordered]@{}
    foreach ($i in @($pick.Values)) {
        $p = $paths[$i]
        $active = (($p.flags -band [NativeCcd]::PATH_ACTIVE) -ne 0)

        $t = New-Object NativeCcd+TARGET_DEVICE_NAME
        $h = New-Object NativeCcd+HEADER
        $h.type = [NativeCcd]::GET_TARGET_NAME
        $h.size = $M::SizeOf($t)
        $h.adapterId = $p.targetInfo.adapterId
        $h.id = $p.targetInfo.id
        $t.header = $h
        if ([NativeCcd]::DisplayConfigGetDeviceInfo([ref]$t) -ne 0) { continue }
        if ([string]::IsNullOrWhiteSpace($t.monitorDevicePath)) { continue }

        $key = $t.monitorDevicePath
        if ($byPath.Contains($key) -and -not $active) { continue }

        $output = ''
        if ($active) {
            $s = New-Object NativeCcd+SOURCE_DEVICE_NAME
            $hs = New-Object NativeCcd+HEADER
            $hs.type = [NativeCcd]::GET_SOURCE_NAME
            $hs.size = $M::SizeOf($s)
            $hs.adapterId = $p.sourceInfo.adapterId
            $hs.id = $p.sourceInfo.id
            $s.header = $hs
            # Имя выхода достоверно только у активной цели: у выключенных
            # система отдаёт один и тот же \\.\DISPLAYx на всех.
            if ([NativeCcd]::DisplayConfigGetDeviceInfo([ref]$s) -eq 0) { $output = $s.viewGdiDeviceName }
        }

        $native = $null
        $pm = New-Object NativeCcd+TARGET_PREFERRED_MODE
        $hp = New-Object NativeCcd+HEADER
        $hp.type = [NativeCcd]::GET_TARGET_PREFERRED_MODE
        $hp.size = $M::SizeOf($pm)
        $hp.adapterId = $p.targetInfo.adapterId
        $hp.id = $p.targetInfo.id
        $pm.header = $hp
        if ([NativeCcd]::DisplayConfigGetDeviceInfo([ref]$pm) -eq 0 -and $pm.width -ge 640) {
            $native = [pscustomobject]@{ Width = [int]$pm.width; Height = [int]$pm.height }
        }

        $shortId = (ConvertTo-VendorCode ([int]$t.edidManufactureId)) + ('{0:X4}' -f $t.edidProductCodeId)

        $byPath[$key] = [pscustomobject]@{
            DevicePath = $t.monitorDevicePath
            Label      = $t.monitorFriendlyDeviceName
            ShortId    = $shortId
            Output     = $output
            Active     = $active
            Available  = ($p.targetInfo.targetAvailable -ne 0)
            Native     = $native
            PathIndex  = $i
        }
    }

    return @($byPath.Values)
}

# Путь устройства для одного пути CCD. Отдельно, потому что нужен и при чтении,
# и при включении.
function Get-CcdPathDevice {
    param($Path)

    $t = New-Object NativeCcd+TARGET_DEVICE_NAME
    $h = New-Object NativeCcd+HEADER
    $h.type = [NativeCcd]::GET_TARGET_NAME
    $h.size = [System.Runtime.InteropServices.Marshal]::SizeOf($t)
    $h.adapterId = $Path.targetInfo.adapterId
    $h.id = $Path.targetInfo.id
    $t.header = $h
    if ([NativeCcd]::DisplayConfigGetDeviceInfo([ref]$t) -ne 0) { return '' }
    return $t.monitorDevicePath
}

# Выбрать по одному пути CCD на каждый из запрошенных мониторов.
#
# Общая часть двух способов перестроить стол — Set-CcdFullConfig (обычный путь) и
# Set-CcdTopology (откат). Вынесена, чтобы правило выбора пути существовало в
# одном экземпляре: разойдись эти две копии, и откат менял бы стол иначе, чем
# основной путь, причём заметно это стало бы только в тот день, когда основной
# путь откажет.
#
# Возвращает $null, если CCD не отвечает или ни одного пути не нашлось, иначе
# Paths (весь массив от QueryDisplayConfig) и Chosen (индексы выбранных путей).
function Get-CcdPathChoice {
    param([Parameter(Mandatory)][string[]]$DevicePaths)

    $want = @{}
    foreach ($p in $DevicePaths) { if ($p) { $want[$p] = $true } }
    # Пустой набор — это чёрный экран. Такого запроса просто не бывает, но цена
    # ошибки здесь такая, что проверка стоит одной строки.
    if ($want.Count -eq 0) { return $null }

    $np = 0; $nm = 0
    if ([NativeCcd]::GetDisplayConfigBufferSizes([NativeCcd]::QDC_ALL_PATHS, [ref]$np, [ref]$nm) -ne 0) { return $null }
    $paths = New-Object 'NativeCcd+PATH_INFO[]' $np
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $nm
    if ([NativeCcd]::QueryDisplayConfig([NativeCcd]::QDC_ALL_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) { return $null }

    # QDC_ALL_PATHS отдаёт все сочетания «источник x цель». Берём по одному пути
    # на монитор со свободным источником: два монитора на одном источнике — это
    # клон, а нужно расширение. Уже активный путь предпочтительнее — меньше
    # перестроений.
    $chosen = @()
    $usedSources = @{}
    $covered = @{}
    # DevicePath по индексу выбранного пути: по нему Set-CcdFullConfig находит
    # целевой режим монитора. Запоминаем здесь, где путь уже опознан, — второй
    # раз спрашивать систему об известном незачем.
    $byIndex = @{}

    foreach ($onlyActive in $true, $false) {
        for ($i = 0; $i -lt $np; $i++) {
            $isActive = (($paths[$i].flags -band [NativeCcd]::PATH_ACTIVE) -ne 0)
            if ($onlyActive -ne $isActive) { continue }
            if ($paths[$i].targetInfo.targetAvailable -eq 0) { continue }
            $dp = Get-CcdPathDevice $paths[$i]
            if (-not $dp -or -not $want.ContainsKey($dp) -or $covered.ContainsKey($dp)) { continue }
            $sid = '' + $paths[$i].sourceInfo.id
            if ($usedSources.ContainsKey($sid)) { continue }
            $usedSources[$sid] = $true
            $covered[$dp] = $true
            $byIndex[$i] = $dp
            $chosen += $i
        }
    }

    $missing = @($want.Keys | Where-Object { -not $covered.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        Write-DisplayLog ("ccd: no usable path for {0} display(s)" -f $missing.Count)
    }
    if ($chosen.Count -eq 0) { return $null }

    return [pscustomobject]@{ Paths = $paths; Chosen = @($chosen); DeviceByIndex = $byIndex }
}

# Задать НАБОР включённых мониторов целиком: перечисленные включаются, все
# остальные гаснут. Одним вызовом, атомарно.
#
# Раньше это делалось тремя шагами — включить нужные, унести роль основного,
# погасить лишние, — и порядок шагов был важен: основной монитор погасить
# нельзя. Здесь порядок не нужен вовсе: система сама переносит роль основного
# внутри перехода. Заодно уходит промежуточное состояние, в котором на столе
# висело больше экранов, чем просили.
#
# Гашение раньше делал MultiMonitorTool. Это была последняя причина держать
# сторонний .exe — и последний путь, который шёл через запись раскладки старым
# API. Включать через него было нечем с самого начала: у выключенного монитора
# в дампе /scomma пустой Monitor ID.
#
# SDC_ALLOW_CHANGES здесь нужен: режимы и позиции мы не задаём (индексы
# недействительны), пусть система подберёт их сама. Свои мы поставим следом —
# Set-CcdLayout для позиций, Set-BestModeFor для частоты.
#
# Это откат: обычный путь — Set-CcdFullConfig, который задаёт набор, позиции и
# режимы одним переходом. Сюда приходят, когда тот отказался (см. там же).
function Set-CcdTopology {
    param([Parameter(Mandatory)][string[]]$DevicePaths)

    $choice = Get-CcdPathChoice -DevicePaths $DevicePaths
    if (-not $choice) { return $false }

    $paths = $choice.Paths
    $chosen = $choice.Chosen

    $out = New-Object 'NativeCcd+PATH_INFO[]' $chosen.Count
    for ($k = 0; $k -lt $chosen.Count; $k++) {
        $p = $paths[$chosen[$k]]
        $p.flags = $p.flags -bor [NativeCcd]::PATH_ACTIVE
        $s = $p.sourceInfo; $s.modeInfoIdx = [NativeCcd]::MODE_IDX_INVALID; $p.sourceInfo = $s
        $t = $p.targetInfo
        $t.modeInfoIdx = [NativeCcd]::MODE_IDX_INVALID
        $rate = New-Object NativeCcd+RATIONAL
        $rate.Numerator = 0; $rate.Denominator = 0
        $t.refreshRate = $rate
        $t.scanLineOrdering = 0
        $p.targetInfo = $t
        $out[$k] = $p
    }

    $base = [NativeCcd]::SDC_USE_SUPPLIED_DISPLAY_CONFIG -bor [NativeCcd]::SDC_ALLOW_CHANGES
    $rc = [NativeCcd]::SetDisplayConfig($out.Count, $out, 0, $null, ($base -bor [NativeCcd]::SDC_VALIDATE))
    if ($rc -ne 0) {
        Write-DisplayLog "ccd: topology validate -> $rc"
        return $false
    }
    $rc = [NativeCcd]::SetDisplayConfig($out.Count, $out, 0, $null,
        ($base -bor [NativeCcd]::SDC_APPLY -bor [NativeCcd]::SDC_SAVE_TO_DATABASE))
    if ($rc -ne 0) {
        Write-DisplayLog "ccd: topology apply -> $rc"
        return $false
    }
    Write-DisplayLog ("ccd: topology set - {0} display(s) on" -f $out.Count)
    return $true
}

# --- стол целиком, одним переходом ------------------------------------------
# Задать ВСЁ сразу: какие мониторы горят, где они стоят, кто основной, в каком
# разрешении и на какой частоте. Один SetDisplayConfig вместо трёх шагов.
#
# Зачем. Раньше переключение с изменением набора экранов состояло из трёх
# перестроений стола: Set-CcdTopology включал набор (с обнулённой частотой и
# SDC_ALLOW_CHANGES — Windows поднимала экраны на той частоте, что записана у неё,
# часто не на родной), Set-CcdLayout вторым переходом двигал позиции, а
# Set-BestModeFor третьим доводил частоту через ChangeDisplaySettingsEx. Каждый
# переход замораживает DWM и ввод: курсор замирал и «выстреливал» вперёд, экраны
# моргали по три раза, и всем окнам трижды приходил WM_DISPLAYCHANGE. В журнале
# 20 августа 2026 такое переключение стоило 6.3 с.
#
# Все три вещи CCD умеет задать одной структурой, и тогда система перестраивает
# стол один раз.
#
# $Targets — объекты с DevicePath, Label, Width, Height, Hz (Hz = 0 значит «пусть
# система выберет сама»). Ширина и высота обязательны: без них исходный режим не
# задать, и такой набор сюда не приходит (см. Get-SwitchTargets).
#
# Возвращает $true/$false. Провал не страшен: вызывающий уходит на старую
# лестницу из трёх шагов, она никуда не делась.
function Set-CcdFullConfig {
    param(
        [Parameter(Mandatory)]$Targets,
        [string]$PrimaryPath = '',
        [string[]]$Order = @()
    )

    $list = @($Targets)
    if ($list.Count -eq 0) { return $false }
    foreach ($t in $list) {
        if ([int]$t.Width -le 0 -or [int]$t.Height -le 0) { return $false }
    }

    # Без порядка мониторов этой дорогой идти нельзя. Задавая стол целиком, мы
    # обязаны назвать координаты КАЖДОГО экрана, а «не знаю» среди них не бывает:
    # получилось бы, что мы расставляем мониторы по собственному разумению — то
    # есть по алфавиту, — там где человек об этом не просил. Старый путь в этом
    # случае честнее: он двигает только основной монитор, остальные оставляет как
    # стоят (см. Invoke-CcdLayoutAttempt).
    if (-not $Order -or @($Order | Where-Object { $_ }).Count -eq 0) {
        Write-DisplayLog 'ccd: no display order in the settings - rebuilding the desk the long way'
        return $false
    }

    # Две попытки, и вторая — не повтор, а осознанное упрощение запроса. Частота
    # — самое хрупкое в этом наборе: у ASUS запись 240 Гц не проходит вообще, а у
    # ULTRAGEAR по HDMI 240 Гц просто нет («bad mode» в журнале 19 августа).
    # Отказ по частоте не повод терять остальное: разрешения и раскладку система
    # примет и без подсказки о герцах, а частоту потом доведёт Set-BestModeFor —
    # одним ремонтным шагом вместо трёх обязательных.
    #
    # Первую попытку пропускаем, когда точной дроби нет ни для одного монитора:
    # просить частоту нечем, и попытка была бы заведомо той же, что вторая.
    foreach ($withHz in $true, $false) {
        if ($withHz -and -not (@($list | Where-Object { [int]$_.RateDen -gt 0 }).Count)) { continue }
        if (Invoke-CcdFullConfigAttempt -Targets $list -PrimaryPath $PrimaryPath -Order $Order -WithHz:$withHz) {
            return $true
        }
    }
    return $false
}

# Одна попытка задать стол целиком. Отдельной функцией по тому же правилу, что и
# Invoke-CcdLayoutAttempt: вся работа с CCD здесь, а решение «повторить или
# упростить» — у вызывающего, и тесты могут подменить попытку целиком.
function Invoke-CcdFullConfigAttempt {
    param(
        [Parameter(Mandatory)]$Targets,
        [string]$PrimaryPath = '',
        [string[]]$Order = @(),
        [switch]$WithHz
    )

    $tag = $(if ($WithHz) { ' (with refresh rates)' } else { ' (rates left to Windows)' })

    $byPath = @{}
    foreach ($t in @($Targets)) { $byPath[[string]$t.DevicePath] = $t }

    $choice = Get-CcdPathChoice -DevicePaths @($byPath.Keys)
    if (-not $choice) { return $false }

    $paths = $choice.Paths
    $chosen = $choice.Chosen

    # Раскладку считаем по ЦЕЛЕВЫМ размерам, а не по текущим: часть мониторов
    # сейчас погашена и своих размеров не имеет вовсе, а встать они должны сразу
    # на свои места — иначе ремонтный проход двинет их вторым перестроением.
    $screens = @()
    foreach ($i in $chosen) {
        $t = $byPath[$choice.DeviceByIndex[$i]]
        if (-not $t) { continue }
        $screens += [pscustomobject]@{
            DevicePath = [string]$t.DevicePath
            Label      = [string]$t.Label
            Width      = [int]$t.Width
            Height     = [int]$t.Height
        }
    }
    if ($screens.Count -ne $chosen.Count) { return $false }
    $pos = Get-LayoutPositions -Screens $screens -Order $Order -PrimaryPath $PrimaryPath

    # По одной записи режима на путь: исходный режим (разрешение и положение).
    # Режим ЦЕЛИ не задаём — для него хватает подсказки о частоте в targetInfo,
    # а полный набор таймингов нам взять негде и незачем.
    $out = New-Object 'NativeCcd+PATH_INFO[]' $chosen.Count
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $chosen.Count

    for ($k = 0; $k -lt $chosen.Count; $k++) {
        $p = $paths[$chosen[$k]]
        $t = $byPath[$choice.DeviceByIndex[$chosen[$k]]]
        $where = $pos[[string]$t.DevicePath]
        if (-not $where) { return $false }

        $m = New-Object NativeCcd+MODE_INFO
        $m.infoType = [NativeCcd]::MODE_INFO_TYPE_SOURCE
        $m.id = $p.sourceInfo.id
        $m.adapterId = $p.sourceInfo.adapterId
        $m.srcWidth = [uint32][int]$t.Width
        $m.srcHeight = [uint32][int]$t.Height
        $m.srcPixelFormat = [NativeCcd]::PIXELFORMAT_32BPP
        $m.srcPosX = [int]$where.X
        $m.srcPosY = [int]$where.Y
        $modes[$k] = $m

        $p.flags = $p.flags -bor [NativeCcd]::PATH_ACTIVE
        $s = $p.sourceInfo; $s.modeInfoIdx = [uint32]$k; $p.sourceInfo = $s

        $ti = $p.targetInfo
        # Режим цели индексом не задаём — тогда система берёт частоту из
        # refreshRate. Нули означают «выбери сама», и это же значение уходит на
        # второй попытке, когда частота оказалась неподъёмной.
        $ti.modeInfoIdx = [NativeCcd]::MODE_IDX_INVALID
        $rate = New-Object NativeCcd+RATIONAL
        $num = [int]$t.RateNum
        $den = [int]$t.RateDen
        if ($WithHz -and $num -gt 0 -and $den -gt 0) {
            $rate.Numerator = [uint32]$num
            $rate.Denominator = [uint32]$den
            $ti.scanLineOrdering = [NativeCcd]::SCANLINE_PROGRESSIVE
            # У погашенного пути система отдаёт поворот и растяжение нулями, а ноль
            # в обоих перечислениях недопустим: вместе с заданной частотой такой
            # путь валидацию не проходит. Чиним только нули — если значение есть,
            # оно чужое и трогать его не наше дело.
            if ($ti.rotation -eq 0) { $ti.rotation = [NativeCcd]::ROTATION_IDENTITY }
            if ($ti.scaling -eq 0)  { $ti.scaling  = [NativeCcd]::SCALING_IDENTITY }
        }
        else {
            $rate.Numerator = 0
            $rate.Denominator = 0
            $ti.scanLineOrdering = 0
        }
        $ti.refreshRate = $rate
        $p.targetInfo = $ti

        $out[$k] = $p
    }

    # SDC_ALLOW_CHANGES намеренно НЕ ставим: здесь задано всё, и система обязана
    # применить ровно это или отказать. С ним она вправе подобрать своё — и мы
    # снова не знали бы, что на самом деле стоит на столе.
    $base = [NativeCcd]::SDC_USE_SUPPLIED_DISPLAY_CONFIG
    $rc = [NativeCcd]::SetDisplayConfig($out.Count, $out, $modes.Count, $modes, ($base -bor [NativeCcd]::SDC_VALIDATE))
    if ($rc -ne 0) {
        Write-DisplayLog ("ccd: full config validate -> $rc" + $tag)
        return $false
    }
    $rc = [NativeCcd]::SetDisplayConfig($out.Count, $out, $modes.Count, $modes,
        ($base -bor [NativeCcd]::SDC_APPLY -bor [NativeCcd]::SDC_SAVE_TO_DATABASE))
    if ($rc -ne 0) {
        Write-DisplayLog ("ccd: full config apply -> $rc" + $tag)
        return $false
    }

    Write-DisplayLog ("ccd: full config applied - {0} display(s) on{1}" -f $out.Count, $tag)
    return $true
}


# Расставить мониторы и назначить основной — одним вызовом CCD.
#
# Две вещи делаются вместе, потому что в Windows это одно и то же. «Основной» —
# не флаг, а положение: основным становится монитор, чей левый верхний угол
# лежит в (0,0). Поэтому раскладка сначала строится слева направо, а потом вся
# целиком сдвигается так, чтобы будущий основной попал в начало координат.
#
# Порядок берётся из настроек (settings.json, ключ layout) — список названий
# слева направо. Монитор, которого в списке нет, уезжает в конец. Если список
# пуст, текущие координаты сохраняются как есть и двигается только основной.
#
# По вертикали выравниваем по центру: экраны разной высоты в пикселях (1440 и
# 2160), и при выравнивании по верху внизу большого остаётся полоса, из которой
# курсор не может перейти на соседний.
#
# Почему не старым API и не MultiMonitorTool. Проверено 7 августа на живой
# машине: /SetMonitors Name=... Primary=1 вернул успех и не сделал ничего, а
# ChangeDisplaySettingsEx с CDS_UPDATEREGISTRY отдал -1 на всех трёх мониторах
# сразу. Запись раскладки старым путём здесь просто не работает.
#
# SDC_ALLOW_CHANGES намеренно НЕ ставим: без него система обязана применить
# ровно те координаты, что переданы, или отказать. С ним она вправе подобрать
# что-то своё, и мониторы опять разъехались бы.
#
# Возвращает не «да/нет», а Ok + Changed. Changed нужен вызывающему, чтобы не
# писать в журнал «arranged left to right» там, где ничего не расставлялось:
# строка, которая рапортует о работе, которой не было, — это то же вранье в
# журнале, из-за которого в этом проекте уже дважды искали дефект не там.
function New-LayoutResult {
    param([bool]$Ok, [bool]$Changed)
    return [pscustomobject]@{ Ok = $Ok; Changed = $Changed }
}

# Куда какой монитор встаёт: путь устройства -> @{X;Y}. Чистая математика, без
# единого обращения к системе — поэтому проверяется тестами и не зависит от того,
# кто спрашивает.
#
# Спрашивают двое: Set-CcdFullConfig, который задаёт стол целиком одним переходом
# (там размеры ЦЕЛЕВЫЕ, монитор может быть ещё погашен), и Invoke-CcdLayoutAttempt,
# который правит уже стоящий стол (там размеры текущие). Раскладка обязана
# получаться одна и та же: разойдись эти два расчёта, и ремонтный проход двигал бы
# мониторы после основного — то самое лишнее перестроение, от которого весь стол
# и подлагивает.
#
# $Screens — объекты с DevicePath, Label, Width, Height.
function Get-LayoutPositions {
    param(
        [Parameter(Mandatory)]$Screens,
        [string[]]$Order = @(),
        [string]$PrimaryPath = ''
    )

    $list = @($Screens)
    $out = @{}
    if ($list.Count -eq 0) { return $out }

    # Место в списке: сравниваем по вхождению, чтобы «UltraGear» находил
    # «LG ULTRAGEAR» и наоборот — названия у системы короче человеческих.
    $ranked = @()
    foreach ($s in $list) {
        $rank = $(if ($Order) { $Order.Count } else { 0 })
        if ($Order) {
            for ($k = 0; $k -lt $Order.Count; $k++) {
                $o = $Order[$k]
                if (-not $o) { continue }
                if ($s.Label -like ('*' + $o + '*') -or $o -like ('*' + $s.Label + '*')) { $rank = $k; break }
            }
        }
        $ranked += [pscustomobject]@{
            DevicePath = $s.DevicePath
            Label      = $s.Label
            Width      = [int]$s.Width
            Height     = [int]$s.Height
            Rank       = $rank
        }
    }
    $ordered = @($ranked | Sort-Object Rank, Label)

    # По вертикали — по центру: экраны разной высоты в пикселях (1440 и 2160), и
    # при выравнивании по верху внизу большого остаётся полоса, из которой курсор
    # не может перейти на соседний.
    $tallest = ($ordered | Measure-Object -Property Height -Maximum).Maximum
    $x = 0
    foreach ($s in $ordered) {
        $out[$s.DevicePath] = [pscustomobject]@{ X = $x; Y = [int](($tallest - $s.Height) / 2) }
        $x += $s.Width
    }

    # Сдвигаем всё так, чтобы основной оказался в (0,0): основным в Windows
    # становится монитор, чей левый верхний угол там лежит.
    $anchorPath = ''
    if ($PrimaryPath -and $out.ContainsKey($PrimaryPath)) { $anchorPath = $PrimaryPath }
    else { $anchorPath = $ordered[0].DevicePath }

    $dx = $out[$anchorPath].X
    $dy = $out[$anchorPath].Y
    if ($dx -ne 0 -or $dy -ne 0) {
        foreach ($k in @($out.Keys)) {
            $out[$k] = [pscustomobject]@{ X = ($out[$k].X - $dx); Y = ($out[$k].Y - $dy) }
        }
    }

    return $out
}

function Set-CcdLayout {
    param([string]$PrimaryPath, [string[]]$Order = @(), [int]$RetryDelayMs = 300)

    # До трёх попыток, каждая — со свежим QueryDisplayConfig. 17 августа 2026
    # валидация вернула 87 (ERROR_INVALID_PARAMETER) через секунду после смены
    # топологии: снимок, снятый в переходном состоянии, система сама же
    # отказалась принять. Попытка была одна, функция молча сдалась — и до
    # следующего нажатия хоткея стол стоял так, как его расставила Windows:
    # мониторы перепутаны местами. Тот же вызов позже прошёл с первого раза за
    # полсекунды. Отказ моментный — значит лечится повтором, но повторять надо
    # целиком: после отказа старый снимок конфигурации уже ничего не описывает.
    $attempts = 3
    for ($n = 1; $n -le $attempts; $n++) {
        if ($n -gt 1 -and $RetryDelayMs -gt 0) { Start-Sleep -Milliseconds $RetryDelayMs }
        $r = Invoke-CcdLayoutAttempt -PrimaryPath $PrimaryPath -Order $Order -Attempt $n -Attempts $attempts
        if ($r.Ok) { return $r }
    }
    Write-DisplayLog ("warn: layout gave up after {0} attempts" -f $attempts)
    return (New-LayoutResult -Ok $false -Changed $false)
}

# Одна попытка расставить мониторы. Отдельной функцией, чтобы Set-CcdLayout мог
# повторять её целиком, а тесты — подменять; вся настоящая работа с CCD здесь.
function Invoke-CcdLayoutAttempt {
    param([string]$PrimaryPath, [string[]]$Order = @(), [int]$Attempt = 1, [int]$Attempts = 1)

    $tag = " (attempt $Attempt/$Attempts)"

    $np = 0; $nm = 0
    if ([NativeCcd]::GetDisplayConfigBufferSizes([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, [ref]$nm) -ne 0) {
        Write-DisplayLog ('warn: layout - could not size the display config buffers' + $tag)
        return (New-LayoutResult -Ok $false -Changed $false)
    }
    $paths = New-Object 'NativeCcd+PATH_INFO[]' $np
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $nm
    if ([NativeCcd]::QueryDisplayConfig([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) {
        Write-DisplayLog ('warn: layout - QueryDisplayConfig refused' + $tag)
        return (New-LayoutResult -Ok $false -Changed $false)
    }

    # Исходные позиции запоминаем ДО любых правок: ниже по ним решается, надо ли
    # вообще звать SetDisplayConfig. Windows с SDC_SAVE_TO_DATABASE часто
    # восстанавливает раскладку сама, и типовой случай — «всё уже стоит как
    # надо» — стоил второго перестроения экранов: моргание и секунда-две времени.
    $before = @{}
    for ($i = 0; $i -lt $nm; $i++) {
        if ($modes[$i].infoType -ne [NativeCcd]::MODE_INFO_TYPE_SOURCE) { continue }
        $before[$i] = [pscustomobject]@{ X = $modes[$i].srcPosX; Y = $modes[$i].srcPosY }
    }

    # Индекс исходного режима -> монитор. Один источник может обслуживать
    # несколько путей, поэтому идём по путям и запоминаем первое совпадение.
    $screens = @()
    $seenIdx = @{}
    for ($i = 0; $i -lt $np; $i++) {
        $mi = $paths[$i].sourceInfo.modeInfoIdx
        if ($mi -eq [NativeCcd]::MODE_IDX_INVALID) { continue }
        $idx = [int]$mi
        if ($seenIdx.ContainsKey($idx)) { continue }
        $seenIdx[$idx] = $true

        $dp = Get-CcdPathDevice $paths[$i]
        if (-not $dp) { continue }

        $t = New-Object NativeCcd+TARGET_DEVICE_NAME
        $h = New-Object NativeCcd+HEADER
        $h.type = [NativeCcd]::GET_TARGET_NAME
        $h.size = [System.Runtime.InteropServices.Marshal]::SizeOf($t)
        $h.adapterId = $paths[$i].targetInfo.adapterId
        $h.id = $paths[$i].targetInfo.id
        $t.header = $h
        $label = ''
        if ([NativeCcd]::DisplayConfigGetDeviceInfo([ref]$t) -eq 0) { $label = $t.monitorFriendlyDeviceName }

        $screens += [pscustomobject]@{
            ModeIdx    = $idx
            DevicePath = $dp
            Label      = $label
            Width      = [int]$modes[$idx].srcWidth
            Height     = [int]$modes[$idx].srcHeight
        }
    }
    if ($screens.Count -eq 0) {
        Write-DisplayLog ('warn: layout - no active screens to arrange' + $tag)
        return (New-LayoutResult -Ok $false -Changed $false)
    }

    if ($Order -and $Order.Count -gt 0) {
        $want = Get-LayoutPositions -Screens $screens -Order $Order -PrimaryPath $PrimaryPath
        foreach ($s in $screens) {
            $p = $want[$s.DevicePath]
            if (-not $p) { continue }
            $m = $modes[$s.ModeIdx]
            $m.srcPosX = $p.X
            $m.srcPosY = $p.Y
            $modes[$s.ModeIdx] = $m
        }
    }
    else {
        # Порядка нет — расставлять нечего, но основной монитор всё равно обязан
        # оказаться в (0,0): в Windows «основной» — это не флаг, а место.
        $anchor = $null
        if ($PrimaryPath) { $anchor = @($screens | Where-Object { $_.DevicePath -eq $PrimaryPath }) | Select-Object -First 1 }
        if (-not $anchor) { $anchor = $screens[0] }

        $dx = $modes[$anchor.ModeIdx].srcPosX
        $dy = $modes[$anchor.ModeIdx].srcPosY
        if ($dx -ne 0 -or $dy -ne 0) {
            for ($i = 0; $i -lt $nm; $i++) {
                if ($modes[$i].infoType -ne [NativeCcd]::MODE_INFO_TYPE_SOURCE) { continue }
                $m = $modes[$i]
                $m.srcPosX = $m.srcPosX - $dx
                $m.srcPosY = $m.srcPosY - $dy
                $modes[$i] = $m
            }
        }
    }

    # Ничего не сдвинулось — значит и применять нечего. Проверка идёт после
    # сдвига к якорю, поэтому она заодно означает «нужный монитор уже в (0,0)»,
    # то есть уже основной.
    $moved = $false
    foreach ($i in @($before.Keys)) {
        if ($modes[$i].srcPosX -ne $before[$i].X -or $modes[$i].srcPosY -ne $before[$i].Y) { $moved = $true; break }
    }
    if (-not $moved) { return (New-LayoutResult -Ok $true -Changed $false) }

    # Куда должно приехать — по пути монитора, а не по индексу режима: индексы
    # между двумя QueryDisplayConfig не обязаны совпадать, а путь устройства
    # стабилен. Снимаем до применения, сверяем после.
    $wantPos = @{}
    foreach ($s in $screens) {
        $wantPos[$s.DevicePath] = [pscustomobject]@{ X = $modes[$s.ModeIdx].srcPosX; Y = $modes[$s.ModeIdx].srcPosY }
    }

    $base = [NativeCcd]::SDC_USE_SUPPLIED_DISPLAY_CONFIG
    $rc = [NativeCcd]::SetDisplayConfig($np, $paths, $nm, $modes, ($base -bor [NativeCcd]::SDC_VALIDATE))
    if ($rc -ne 0) {
        Write-DisplayLog ("ccd: layout validate -> $rc" + $tag)
        return (New-LayoutResult -Ok $false -Changed $false)
    }
    $rc = [NativeCcd]::SetDisplayConfig($np, $paths, $nm, $modes,
        ($base -bor [NativeCcd]::SDC_APPLY -bor [NativeCcd]::SDC_SAVE_TO_DATABASE))
    if ($rc -ne 0) {
        Write-DisplayLog ("ccd: layout apply -> $rc" + $tag)
        return (New-LayoutResult -Ok $false -Changed $false)
    }

    # Вместо Start-Sleep 700 — ждём по факту: система должна начать отдавать те
    # позиции, которые мы только что задали. Пауза была «на всякий случай», и как
    # всякая фиксированная пауза она одновременно и слишком долгая в обычном
    # случае, и слишком короткая в плохом.
    if (-not (Wait-ForLayout -WantedPositions $wantPos)) {
        Write-DisplayLog 'warn: layout did not settle'
    }
    return (New-LayoutResult -Ok $true -Changed $true)
}

# Точная частота активных мониторов: путь -> @{Num;Den}. Целых герцов здесь нет
# намеренно — за ними ходят в EnumDisplaySettings, а сюда именно за дробью,
# которую потом можно вернуть системе слово в слово (см. Get-ModeCache).
function Get-CcdActiveRates {
    $np = 0; $nm = 0
    if ([NativeCcd]::GetDisplayConfigBufferSizes([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, [ref]$nm) -ne 0) { return @{} }
    $paths = New-Object 'NativeCcd+PATH_INFO[]' $np
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $nm
    if ([NativeCcd]::QueryDisplayConfig([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) { return @{} }

    $out = @{}
    for ($i = 0; $i -lt $np; $i++) {
        $r = $paths[$i].targetInfo.refreshRate
        if ($r.Numerator -le 0 -or $r.Denominator -le 0) { continue }
        $dp = Get-CcdPathDevice $paths[$i]
        if (-not $dp -or $out.ContainsKey($dp)) { continue }
        $out[$dp] = [pscustomobject]@{ Num = [int]$r.Numerator; Den = [int]$r.Denominator }
    }
    return $out
}

# Позиции исходных режимов по пути монитора: путь -> @{X;Y}. Отдельной функцией,
# потому что нужна и для ожидания раскладки, и пригодится для снимков окон.
function Get-CcdSourcePositions {
    $np = 0; $nm = 0
    if ([NativeCcd]::GetDisplayConfigBufferSizes([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, [ref]$nm) -ne 0) { return @{} }
    $paths = New-Object 'NativeCcd+PATH_INFO[]' $np
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $nm
    if ([NativeCcd]::QueryDisplayConfig([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) { return @{} }

    $out = @{}
    for ($i = 0; $i -lt $np; $i++) {
        $mi = $paths[$i].sourceInfo.modeInfoIdx
        if ($mi -eq [NativeCcd]::MODE_IDX_INVALID) { continue }
        $dp = Get-CcdPathDevice $paths[$i]
        if (-not $dp -or $out.ContainsKey($dp)) { continue }
        $out[$dp] = [pscustomobject]@{ X = [int]$modes[[int]$mi].srcPosX; Y = [int]$modes[[int]$mi].srcPosY }
    }
    return $out
}

# Дождаться, пока заданные позиции реально встанут. $false — не встали за срок.
function Wait-ForLayout {
    param(
        [Parameter(Mandatory)]$WantedPositions,
        [int]$TimeoutMs = 3000,
        [int]$StepMs = 200
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $now = Get-CcdSourcePositions
        $bad = 0
        foreach ($dp in @($WantedPositions.Keys)) {
            $p = $now[$dp]
            if ($null -eq $p -or $p.X -ne $WantedPositions[$dp].X -or $p.Y -ne $WantedPositions[$dp].Y) { $bad++ }
        }
        if ($bad -eq 0) { return $true }
        if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $false }
        Start-Sleep -Milliseconds $StepMs
    }
}

# Дождаться, пока стол станет ровно запрошенным: все нужные мониторы поднялись и
# ни одного лишнего не осталось. Считаем по CCD, а не по карте выходов: у CCD
# признак активности лежит на самом пути монитора, и его нельзя перепутать с
# соседним (на этом обжигались, см. README про Get-OutputMap).
#
# Пришло на место связки «Start-Sleep 1200 + Wait-ForCcdActive + полный
# Get-DisplayState для поиска лишних». Смысл паузы 1200 был в том, чтобы не
# прочитать «ещё активен» у гаснущего монитора — но это ожидание по условию, а не
# по таймеру: условие «лишние погасли» покрывает тот же случай и уходит сразу,
# как только он выполнен. Полный Get-DisplayState тут больше не нужен:
# Get-CcdTargets отдаёт и активность, и имена, и стоит ~10 мс против ~90.
#
# Возвращает Ok плюс два списка имён: кто не поднялся и кто не погас.
#
# Два срока, а не один. TimeoutMs — сколько ждём, пока мониторы проснутся (ASUS
# просыпается около десяти секунд, это физика). ExtraGraceMs — сколько ещё ждём
# гашения лишних ПОСЛЕ того, как все нужные уже на столе: монитор, который
# собирается погаснуть, делает это за секунду-две, и если он упёрся, то упёрся.
# С одним общим сроком отказ гасить стоил бы все 15 с ожидания на пути, который и
# так уже провалился.
function Wait-ForTopology {
    param(
        [Parameter(Mandatory)][string[]]$WantedPaths,
        [int]$TimeoutMs = 15000,
        [int]$ExtraGraceMs = 3000,
        [int]$StepMs = 200
    )

    $want = @{}
    foreach ($p in $WantedPaths) { if ($p) { $want[$p] = $true } }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $allUpAt = -1
    $missing = @()
    $extra = @()

    while ($true) {
        $byPath = @{}
        foreach ($t in @(Get-CcdTargets)) { $byPath[$t.DevicePath] = $t }

        # Имя для отчёта берём из CCD; если путь вообще исчез из перечисления,
        # показываем путь — молчать нельзя, а назвать монитор больше нечем.
        $missing = @()
        foreach ($p in @($want.Keys)) {
            $t = $byPath[$p]
            if ($null -eq $t -or -not $t.Active) {
                $missing += $(if ($t -and $t.Label) { $t.Label } else { $p })
            }
        }
        $extra = @($byPath.Values |
            Where-Object { $_.Active -and -not $want.ContainsKey($_.DevicePath) } |
            ForEach-Object { $(if ($_.Label) { $_.Label } else { $_.DevicePath }) })

        if ($missing.Count -eq 0 -and $extra.Count -eq 0) {
            return [pscustomobject]@{ Ok = $true; MissingLabels = @(); ExtraLabels = @() }
        }

        $elapsed = $sw.ElapsedMilliseconds
        if ($missing.Count -eq 0) {
            if ($allUpAt -lt 0) { $allUpAt = $elapsed }
            if (($elapsed - $allUpAt) -ge $ExtraGraceMs) { break }
        }
        if ($elapsed -ge $TimeoutMs) { break }

        Start-Sleep -Milliseconds $StepMs
    }

    return [pscustomobject]@{ Ok = $false; MissingLabels = @($missing); ExtraLabels = @($extra) }
}


# Имя выхода монитора, когда он уже на столе. $null, если так и не появился.
function Get-CcdOutput {
    param([Parameter(Mandatory)][string]$DevicePath, [int]$TimeoutMs = 8000)

    $waited = 0
    while ($true) {
        $t = @(Get-CcdTargets | Where-Object { $_.DevicePath -eq $DevicePath -and $_.Active -and $_.Output })
        if ($t.Count -gt 0) { return $t[0].Output }
        if ($waited -ge $TimeoutMs) { return $null }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
}


# Родное разрешение раньше читалось прямо из EDID в реестре: обход
# HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY, выбор нужной записи среди
# оставшихся с прошлых подключений и разбор байта 54 вручную. Всё это делает
# сама система — GET_TARGET_PREFERRED_MODE в Get-CcdTargets, причём и для
# выключенного монитора. Спрашивать драйвер по-прежнему бесполезно: для
# ULTRAGEAR он отвечает 3840x2160, потому что по HDMI тот принимает 4K и сам
# сжимает его в свои 1440p.
# Максимальный режим: самая высокая частота в родном разрешении. Без него, если
# EDID прочитать не удалось, откат к старому правилу — самая большая площадь,
# потом частота. Только прогрессивные режимы (dmDisplayFlags = 0).
function Get-BestMode {
    param([string]$Output, [int]$NativeWidth = 0, [int]$NativeHeight = 0)

    $best = $null
    $i = 0
    while ($true) {
        $dm = New-Object NativeDisplay+DEVMODE
        $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        if (-not [NativeDisplay]::EnumDisplaySettings($Output, $i, [ref]$dm)) { break }
        $i++

        if ($dm.dmBitsPerPel -lt 32 -or $dm.dmDisplayFlags -ne 0) { continue }

        if ($NativeWidth -gt 0 -and $NativeHeight -gt 0) {
            if ($dm.dmPelsWidth -ne $NativeWidth -or $dm.dmPelsHeight -ne $NativeHeight) { continue }
            $score = [int64]$dm.dmDisplayFrequency
        }
        else {
            $score = ([int64]$dm.dmPelsWidth * $dm.dmPelsHeight * 10000) + $dm.dmDisplayFrequency
        }

        if (($null -eq $best) -or ($score -gt $best.Score)) {
            $best = [pscustomobject]@{
                Width = $dm.dmPelsWidth; Height = $dm.dmPelsHeight
                Hz    = $dm.dmDisplayFrequency; Score = $score
            }
        }
    }

    # Родное разрешение есть, а режимов на нём нет — бывает, если монитор
    # подключён через переходник. Тогда лучше старое правило, чем ничего.
    if (-not $best -and $NativeWidth -gt 0) { return Get-BestMode -Output $Output }
    return $best
}

function Get-CurrentMode {
    param([string]$Output)

    $dm = New-Object NativeDisplay+DEVMODE
    $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
    if ([NativeDisplay]::EnumDisplaySettings($Output, [NativeDisplay]::CURRENT_SETTINGS, [ref]$dm)) {
        return [pscustomobject]@{
            Width = $dm.dmPelsWidth; Height = $dm.dmPelsHeight; Hz = $dm.dmDisplayFrequency
            X = $dm.dmPositionX; Y = $dm.dmPositionY
        }
    }
    return $null
}


# Смена режима через Windows API, а не через MultiMonitorTool.
# Причина: /SetMonitors не возвращает результат. Он молча не применял частоту —
# в журнале команда «DisplayFrequency=60» уходила, а монитор оставался на 30 Гц,
# и заметить это можно было только по итоговой сводке. ChangeDisplaySettingsEx
# отдаёт код, поэтому промах виден сразу и его можно повторить.
function Set-DisplayMode {
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [Parameter(Mandatory)][int]$Hz
    )

    # Каждый раз собираем DEVMODE заново из текущего: так сохраняются позиция,
    # ориентация и всё прочее, что нас не касается, а неудачный вызов не оставляет
    # после себя испорченную структуру.
    $build = {
        $dm = New-Object NativeDisplay+DEVMODE
        $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        if (-not [NativeDisplay]::EnumDisplaySettings($Output, [NativeDisplay]::CURRENT_SETTINGS, [ref]$dm)) {
            return $null
        }
        $dm.dmBitsPerPel = 32
        $dm.dmPelsWidth = $Width
        $dm.dmPelsHeight = $Height
        $dm.dmDisplayFrequency = $Hz
        $dm.dmFields = [NativeDisplay]::DM_BITSPERPEL -bor [NativeDisplay]::DM_PELSWIDTH -bor
                       [NativeDisplay]::DM_PELSHEIGHT -bor [NativeDisplay]::DM_DISPLAYFREQUENCY
        return $dm
    }

    $describe = {
        param($c)
        switch ($c) {
            0       { 'ok' }
            1       { 'needs restart' }
            -1      { 'failed' }
            -2      { 'bad mode' }
            -3      { 'not updated' }
            -4      { 'bad flags' }
            -5      { 'bad parameter' }
            default { "code $c" }
        }
    }

    $dm = & $build
    if (-not $dm) { return [pscustomobject]@{ Code = -999; Text = 'EnumDisplaySettings failed'; Persisted = $false } }

    # Сначала просим применить режим и запомнить его (CDS_UPDATEREGISTRY).
    $code = [NativeDisplay]::ChangeDisplaySettingsEx($Output, [ref]$dm, [IntPtr]::Zero,
                                                     [NativeDisplay]::CDS_UPDATEREGISTRY, [IntPtr]::Zero)
    if ($code -eq 0) {
        return [pscustomobject]@{ Code = 0; Text = 'ok'; Persisted = $true }
    }

    # Не вышло — применяем без записи в реестр (flags = 0).
    #
    # У ASUS ROG STRIX запись в реестр не проходит ни для одной частоты, включая
    # ту, что уже стоит: CDS_UPDATEREGISTRY отдаёт failed, а тот же режим с
    # flags = 0 применяется мгновенно. Из-за этого монитор оставался на 59 Гц
    # вместо 240. Оба LG при этом с записью работают нормально.
    #
    # Частота важнее её сохранения: режим мы всё равно выставляем заново на
    # каждом переключении. Проверка на -2/-5 нужна, чтобы не повторять заведомо
    # невозможный режим.
    if ($code -eq -2 -or $code -eq -5) {
        return [pscustomobject]@{ Code = $code; Text = (& $describe $code); Persisted = $false }
    }

    $dm2 = & $build
    if (-not $dm2) { return [pscustomobject]@{ Code = $code; Text = (& $describe $code); Persisted = $false } }

    $code2 = [NativeDisplay]::ChangeDisplaySettingsEx($Output, [ref]$dm2, [IntPtr]::Zero, 0, [IntPtr]::Zero)
    if ($code2 -eq 0) {
        return [pscustomobject]@{ Code = 0; Text = 'ok (not saved to registry)'; Persisted = $false }
    }
    return [pscustomobject]@{ Code = $code2; Text = (& $describe $code2); Persisted = $false }
}

# Дождаться, пока монитор реально отдаёт заданный режим. Короткий срок: смена
# режима либо встаёт почти сразу, либо не встаёт вовсе и нужна вторая попытка.
function Wait-ForMode {
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [Parameter(Mandatory)][int]$Hz,
        [int]$TimeoutMs = 1500,
        [int]$StepMs = 100
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $c = Get-CurrentMode $Output
        if ($c -and $c.Width -eq $Width -and $c.Height -eq $Height -and $c.Hz -eq $Hz) { return $true }
        if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $false }
        Start-Sleep -Milliseconds $StepMs
    }
}

# Поднять монитор в его максимальный режим, если он там ещё не стоит. С проверкой
# и повторной попыткой: смена основного монитора и гашение соседа могут сбросить
# режим уже после того, как он был выставлен.
function Set-BestModeFor {
    param(
        [Parameter(Mandatory)][string]$Output,
        [string]$Label = '',
        [int]$NativeWidth = 0,
        [int]$NativeHeight = 0,
        $Best = $null
    )

    # $Best можно передать готовым, и это не микрооптимизация. Get-BestMode
    # перебирает EnumDisplaySettings по всем режимам монитора, и сразу после
    # смены топологии драйвер отдаёт их заметно медленнее, чем в покое: замер
    # холодного `all` показал 1.6 с на ULTRAGEAR и 0.8 с на ULTRAFINE — на двух
    # мониторах, которым вообще ничего менять не требовалось. В покое тот же
    # перебор стоит 60 мс.
    #
    # Состояние на входе в переключение уже содержит BestMode для каждого
    # включённого монитора (его посчитал Get-DisplayState), а самый большой режим
    # монитора от смены набора экранов не меняется: родное разрешение берётся из
    # EDID, а список частот — свойство панели, не раскладки. Поэтому для
    # монитора, который и до переключения был на столе, пересчитывать нечего.
    # Для того, кто только что проснулся (ASUS), BestMode неизвестен — там
    # перебор честно выполняется.
    $best = $Best
    if (-not $best) { $best = Get-BestMode -Output $Output -NativeWidth $NativeWidth -NativeHeight $NativeHeight }
    if (-not $best) { return $null }

    foreach ($attempt in 1, 2) {
        $current = Get-CurrentMode $Output
        if ($current -and $current.Width -eq $best.Width -and $current.Height -eq $best.Height -and $current.Hz -eq $best.Hz) {
            return $true
        }

        $r = Set-DisplayMode -Output $Output -Width $best.Width -Height $best.Height -Hz $best.Hz
        Write-DisplayLog ("mode: {0} {1} -> {2}x{3}@{4} - {5} (attempt {6})" -f `
            $Label, $Output, $best.Width, $best.Height, $best.Hz, $r.Text, $attempt)
        # Режим невозможен — повторять нечего. Прочие отказы бывают от того, что
        # монитор ещё перестраивается, поэтому раньше здесь стоял выход из
        # функции по любой ошибке и вторая попытка не наступала никогда.
        if ($r.Code -eq -2 -or $r.Code -eq -5) { return $false }

        # Здесь стоял Start-Sleep 600 — и спал даже когда режим встал с первой
        # попытки: успех обнаруживался только в начале следующего витка. В режиме
        # `all` это лишние 600 мс на каждый монитор, которому меняли частоту.
        # Теперь ждём по факту: как только монитор отдаёт нужный режим — выходим.
        if (Wait-ForMode -Output $Output -Width $best.Width -Height $best.Height -Hz $best.Hz) {
            return $true
        }
    }

    $current = Get-CurrentMode $Output
    $ok = ($current -and $current.Hz -eq $best.Hz)
    if (-not $ok) {
        # Монитор мог отцепиться между двумя строками — тогда $current пуст, и
        # без этой подстановки в журнал уходило «stayed at  Hz», то есть
        # диагностика пропадала ровно там, где она нужна.
        $was = $(if ($current) { [string]$current.Hz } else { 'unknown - the display detached' })
        Write-DisplayLog ("mode: {0} stayed at {1} Hz instead of {2} - something outside is resetting it" -f `
            $Label, $was, $best.Hz)
    }
    return $ok
}

# --- состояние --------------------------------------------------------------
# Короткий Monitor ID — код производителя из EDID плюс код модели: GSM = LG
# (GoldStar), AUS = ASUS. Он стабилен для модели, но НЕ для экземпляра и не для
# входа, поэтому ключом настроек служит название монитора (см. Get-DisplayModes).

# Подходит ли кусок названия из настроек этому монитору. Сравниваем по вхождению
# в обе стороны: система знает монитор как «XG27AQDMGR», а человек мог написать
# «ROG STRIX XG27AQDMGR», и наоборот «UltraGear» должен находить «LG ULTRAGEAR».
# Регистр не важен: -like без -c.
#
# Одно правило на всё, где человек называет монитор словами: layout, primary,
# состав комбинации. Два определения разошлись бы на первом же нестандартном
# названии. (Называлась Test-DisplayNameMatch, пока в проекте были роли.)
function Test-DisplayNameMatch {
    param([string]$Pattern, [string]$Label, [string]$ShortId)

    if (-not $Pattern) { return $false }
    foreach ($name in $Label, $ShortId) {
        if (-not $name) { continue }
        if ($name -like ('*' + $Pattern + '*') -or $Pattern -like ('*' + $name + '*')) { return $true }
    }
    return $false
}

# Название режима из имени роли: work -> «Work displays». Осталось ради ключей
# role:<роль>, которые могут лежать в чужом старом settings.json и после переезда
# ролей превращаются в строку-сироту в окне настроек: показать её надо
# по-человечески. ToUpperInvariant, а не ToUpper: на турецкой локали «i»
# превращается в «İ», и заголовок поехал бы от настроек системы.
function Get-RoleTitle {
    param([string]$Role)

    if (-not $Role) { return '' }
    return $Role.Substring(0, 1).ToUpperInvariant() + $Role.Substring(1) + ' displays'
}

# --- переезд авто-игрового режима в правила -------------------------------------
# autoGame был правилом, которого хватало на один случай: один процесс, один
# режим, один возврат. Второго условия («за компьютером не работают двадцать
# минут») он выразить не мог, а второго процесса — тем более. Правила говорят то
# же самое и больше, поэтому старая настройка при чтении превращается в первый
# элемент rules, а её ключ остаётся пустым — ради файлов, написанных рукой.
#
# Чистая функция над словарём настроек, как и переезд ролей: меняет $Settings на
# месте, возвращает $true, если что-то поменяла, и идемпотентна.
function Convert-AutoGameToRules {
    param($Settings)

    if (-not $Settings -or -not $Settings.autoGame) { return $false }
    $cfg = $Settings.autoGame
    # Пустую настройку не переносим: правило без процесса и режима бессмысленно, а
    # заводить его значило бы дописывать мусор в каждый settings.json на свете.
    if (-not $cfg.process -or -not $cfg.gameMode) { return $false }

    if ($null -eq $Settings.rules) { $Settings.rules = @() }

    # Такое правило уже есть — значит переезд уже был, а старый ключ остался
    # лежать в файле, написанном прошлой версией. Второй раз не добавляем.
    foreach ($r in @($Settings.rules)) {
        if ([string]$r.process -eq [string]$cfg.process -and [string]$r.mode -eq [string]$cfg.gameMode) {
            $Settings.autoGame = [ordered]@{ enabled = $false; process = ''; gameMode = ''; backMode = '' }
            return $true
        }
    }

    # Впереди остальных: правило было единственным, и его старшинство надо
    # сохранить — иначе после переезда игру мог бы перебить, например, простой.
    $Settings.rules = @(, ([ordered]@{
        when    = 'process'
        process = [string]$cfg.process
        minutes = 0
        mode    = [string]$cfg.gameMode
        back    = [string]$cfg.backMode
        enabled = [bool]$cfg.enabled
    }) + @($Settings.rules))

    $Settings.autoGame = [ordered]@{ enabled = $false; process = ''; gameMode = ''; backMode = '' }
    return $true
}

# --- переезд ролей в комбинации ------------------------------------------------
# Роли и комбинации описывали одно и то же — именованный набор мониторов, — но
# роль была слабее (одна на монитор, без своей панели задач) и удалялась иначе.
# Один вид набора вместо двух: роли из файла превращаются в комбинации при чтении
# настроек, вместе с привязками клавиш, звуком и авто-игровым режимом.
#
# Чистая функция над словарём настроек: меняет $Settings на месте и возвращает
# $true, если что-то поменяла. Идемпотентна — второй вызов не находит ролей и не
# делает ничего.
function Convert-RoleSettingsToCombos {
    param($Settings)

    if (-not $Settings -or -not $Settings.roles) { return $false }
    if (@($Settings.roles.Keys).Count -eq 0) { return $false }

    if ($null -eq $Settings.combos) { $Settings.combos = [ordered]@{} }

    # Имя роли -> её шаблоны, в порядке файла: порядок выбрал человек, и
    # комбинации должны встать в том же.
    $byRole = [ordered]@{}
    foreach ($pattern in @($Settings.roles.Keys)) {
        if (-not $pattern) { continue }
        $role = ([string]$Settings.roles[$pattern]).Trim()
        if (-not $role) { continue }
        if (-not $byRole.Contains($role)) { $byRole[$role] = @() }
        $byRole[$role] += [string]$pattern
    }

    # Ключи режимов тоже переезжают: role:work -> combo:Work. Клавиша, записанная
    # в файле, обязана продолжать работать — иначе переезд выглядел бы как
    # «настройки сбросились».
    $renames = [ordered]@{}

    foreach ($role in @($byRole.Keys)) {
        # Имя комбинации — роль с заглавной буквы: «work» -> «Work». Так оно
        # остаётся тем словом, которое человек написал сам (и `Set-Display.ps1
        # work` находит его как раньше — сравнение имени регистр не различает),
        # но в меню выглядит как название, а не как строчка из файла.
        $name = $role.Substring(0, 1).ToUpperInvariant() + $role.Substring(1)

        # Одноимённая комбинация уже есть — её состав трогать нельзя, он мог быть
        # задан руками. Уступаем ей имя и берём соседнее.
        if ($Settings.combos.Contains($name)) {
            $try = $name + ' (group)'
            $n = 2
            while ($Settings.combos.Contains($try)) { $try = $name + ' (group ' + $n + ')'; $n++ }
            $name = $try
        }

        $Settings.combos[$name] = [ordered]@{
            displays = @($byRole[$role])
            # Своей панели задач у роли не было — работают общие правила.
            primary  = ''
        }
        $renames['role:' + $role] = 'combo:' + $name
    }

    # Переименование ключей с сохранением порядка: словари [ordered] уезжают в
    # settings.json как есть, и перетасовка выглядела бы в diff'е правкой,
    # которой никто не делал.
    foreach ($field in 'hotkeys', 'audio', 'hooks', 'brightness', 'contrast') {
        if (-not $Settings[$field]) { continue }
        $moved = [ordered]@{}
        foreach ($key in @($Settings[$field].Keys)) {
            $newKey = $(if ($renames.Contains($key)) { [string]$renames[$key] } else { [string]$key })
            # Ключ уже занят — не перетираем: у него своё значение, и молча
            # выбросить одно из двух хуже, чем оставить старое.
            if (-not $moved.Contains($newKey)) { $moved[$newKey] = $Settings[$field][$key] }
        }
        $Settings[$field] = $moved
    }

    if ($Settings.autoGame) {
        foreach ($field in 'gameMode', 'backMode') {
            $v = [string]$Settings.autoGame[$field]
            if ($v -and $renames.Contains($v)) { $Settings.autoGame[$field] = [string]$renames[$v] }
        }
    }

    # Правила и «монитор появился» ссылаются на режимы теми же ключами, значит и
    # переезжать должны вместе с ними. Пропустить это значило бы оставить правило,
    # которое каждые пятнадцать секунд пытается уйти в режим, которого больше нет.
    foreach ($r in @($Settings.rules)) {
        foreach ($field in 'mode', 'back') {
            $v = [string]$r[$field]
            if ($v -and $renames.Contains($v)) { $r[$field] = [string]$renames[$v] }
        }
    }
    if ($Settings.reapply) {
        $v = [string]$Settings.reapply.onPlug
        if ($v -and $renames.Contains($v)) { $Settings.reapply.onPlug = [string]$renames[$v] }
    }

    $Settings.roles = [ordered]@{}
    return $true
}

# Кто сейчас основной. Спрашиваем только адаптеры: у них флаг PRIMARY_DEVICE
# лежит прямо в StateFlags, и перебирать дочерние мониторы (где и водилась
# ошибка с жёстким индексом 0) для этого не нужно вовсе.
function Get-PrimaryOutput {
    $i = 0
    while ($true) {
        $a = New-DisplayDevice
        if (-not [NativeDisplay]::EnumDisplayDevices([NullString]::Value, $i, [ref]$a, 0)) { break }
        $i++
        if (($a.StateFlags -band [NativeDisplay]::PRIMARY_DEVICE) -ne 0) { return $a.DeviceName }
    }
    return $null
}

# Состояние всех мониторов. Раньше здесь запускался MultiMonitorTool /scomma —
# секунда с лишним на каждый вызов, а выключенный монитор в дампе терял и имя, и
# идентификатор. Теперь всё берётся из CCD (см. комментарий у класса NativeCcd).
#
# Id — путь устройства из CCD. Он есть и у выключенного монитора, поэтому по нему
# можно и опознать монитор, и снова его включить. Старый Monitor ID
# (MONITOR\GSM5BB3\...) больше не нужен нигде: он существовал только ради команд
# MultiMonitorTool, а их не осталось.
# $Settings нужны только ради ролей. Параметр необязательный: кто настройки уже
# прочитал (Switch-DisplayMode, трей) — передаёт их и не платит вторым чтением
# диска, остальным удобнее не знать о них вовсе. Читать их здесь безусловно было
# нельзя: Switch-DisplayMode намеренно читает файл РОВНО один раз за
# переключение, чтобы внутри одного перехода не оказалось двух его версий.
function Get-DisplayState {
    param($Settings)

    if (-not $Settings) { $Settings = Get-DisplaySettings }

    $targets = @(Get-CcdTargets)
    if ($targets.Count -eq 0) { throw 'Windows returned no displays at all' }

    $primaryOutput = Get-PrimaryOutput

    foreach ($t in $targets) {
        $label = $t.Label
        if (-not $label) { $label = $t.ShortId }
        if (-not $label) { $label = $t.DevicePath }

        $nw = 0; $nh = 0
        if ($t.Native) { $nw = $t.Native.Width; $nh = $t.Native.Height }

        $best = $null
        $cur = $null
        if ($t.Active -and $t.Output) {
            $best = Get-BestMode -Output $t.Output -NativeWidth $nw -NativeHeight $nh
            $cur = Get-CurrentMode $t.Output
        }

        [pscustomobject]@{
            Output       = $t.Output
            Label        = $label
            Model        = $label
            ShortId      = $t.ShortId
            Native       = $t.Native
            Id           = $t.DevicePath
            Active       = $t.Active
            Primary      = ($t.Active -and $t.Output -and $t.Output -eq $primaryOutput)
            Disconnected = (-not $t.Available)
            Width        = $(if ($cur) { $cur.Width } else { 0 })
            Height       = $(if ($cur) { $cur.Height } else { 0 })
            Hz           = $(if ($cur) { $cur.Hz } else { 0 })
            BestMode     = $best
        }
    }
}

# --- режимы -----------------------------------------------------------------
# Режимы строятся из текущего состояния, а не из жёсткого списка: у каждого
# монитора появляется свой соло-режим сам, как только он подключён. Ключ режима
# стабилен (короткий Monitor ID), поэтому привязки клавиш переживают
# переподключение кабеля и смену номеров выходов.

function Get-DisplayModes {
    # $Settings нужны только ради комбинаций. Диск здесь не читается НИКОГДА:
    # меню трея зовёт эту функцию на каждое открытие, и чтение файла стоило бы
    # ровно той задержки, ради которой заведён кэш состояния. Не передали
    # настройки — значит комбинаций в списке не будет; все настоящие вызывающие
    # (трей, переключатель, CLI, окно настроек) настройки передают.
    param($State, $Settings)

    # Именно $null, а не «ложь»: пустой массив в PowerShell тоже ложь, и на нём
    # эта строка запускала дамп MultiMonitorTool заново — секунда с лишним прямо
    # внутри обработчика открытия меню, ради которого кэш и заводился.
    if ($null -eq $State) { $State = @(Get-DisplayState) }
    $modes = @()

    # Ключ соло-режима — по названию монитора, а не по короткому Monitor ID.
    # Короткий ID стабилен только для пары «монитор + вход»: у монитора на DP и
    # на HDMI разные EDID, и код в них разный. После перекладки кабелей
    # ULTRAGEAR стал GSM5BB4 -> GSM5BB3, ULTRAFINE GSM5CBB -> GSM5CBC, и
    # привязки Ctrl+Alt+F1/F2 указывали в пустоту. Название входу не меняется.
    # Две одинаковые модели различаем коротким ID, а если и он совпал (одинаковые
    # мониторы на одинаковых входах — короткий ID это модель, а не экземпляр), то
    # порядковым номером. Раньше на этом месте была только вторая ступень, и для
    # пары близнецов оба соло-режима получали ОДИН ключ: «включить только этот»
    # зажигало оба.
    $dupes = @($State | Group-Object Label | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    $twins = @($State | Group-Object { $_.Label + '|' + $_.ShortId } | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    $seen = @{}
    foreach ($m in $State) {
        $name = $m.Label
        if ($dupes -contains $m.Label) { $name = $m.Label + ' ' + $m.ShortId }

        $pair = $m.Label + '|' + $m.ShortId
        if ($twins -contains $pair) {
            if (-not $seen.ContainsKey($pair)) { $seen[$pair] = 0 }
            $seen[$pair]++
            $name = $name + ' #' + $seen[$pair]
        }

        $modes += [pscustomobject]@{
            Key       = 'solo:' + $name
            Title     = 'Only ' + $m.Label
            Kind      = 'solo'
            Label     = $m.Label
            ShortId   = $m.ShortId
            # Полный Monitor ID уникален для экземпляра. В настройки он не
            # попадает (он меняется от порта) — только для выбора участников.
            Id        = $m.Id
            Primary   = $null
            Available = (-not $m.Disconnected)
        }
    }

    # Групповых режимов (role:<роль>) здесь больше нет: роль была вторым,
    # более слабым способом сказать то же, что говорит комбинация, и роли из
    # файла превращаются в комбинации при чтении настроек
    # (Convert-RoleSettingsToCombos). Дальше по коду набор бывает одного вида.

    # Комбинации — в порядке файла, без сортировки: их порядок выбрал человек в
    # окне настроек, и переставлять его самовольно не наше дело.
    if ($Settings -and $Settings.combos) {
        foreach ($name in @($Settings.combos.Keys)) {
            $c = $Settings.combos[$name]
            $patterns = @()
            $comboPrimary = ''
            if ($c -is [array]) { $patterns = @($c | ForEach-Object { [string]$_ }) }
            elseif ($c) {
                if ($null -ne $c.displays) { $patterns = @($c.displays | ForEach-Object { [string]$_ }) }
                if ($null -ne $c.primary)  { $comboPrimary = [string]$c.primary }
            }

            # Доступность — хоть один участник на столе: комбинация включает
            # то, что есть, как «все». Пустой список участников честно даёт
            # недоступный режим — Switch-DisplayMode скажет об этом словами.
            $available = $false
            foreach ($m in $State) {
                if ($m.Disconnected) { continue }
                foreach ($pat in $patterns) {
                    if (Test-DisplayNameMatch -Pattern $pat -Label $m.Label -ShortId $m.ShortId) { $available = $true; break }
                }
                if ($available) { break }
            }

            $modes += [pscustomobject]@{
                Key       = 'combo:' + $name
                Title     = [string]$name
                Kind      = 'combo'
                Patterns  = $patterns
                Primary   = $comboPrimary
                Available = $available
            }
        }
    }

    $modes += [pscustomobject]@{
        Key       = 'all'
        Title     = 'All displays'
        Kind      = 'all'
        Primary   = $null
        Available = (@($State | Where-Object { -not $_.Disconnected }).Count -gt 0)
    }

    return $modes
}

# Название режима по одному ключу, без опроса состояния. Нужно для привязок к
# мониторам, которых сейчас нет в системе: такого режима в Get-DisplayModes не
# появляется, а показать его в настройках всё равно надо. Модель монитора взять
# неоткуда, поэтому в названии остаётся короткий Monitor ID.
function Get-ModeTitleFromKey {
    param([Parameter(Mandatory)][string]$Key)

    switch -Regex ($Key) {
        '^solo:(.+)$'  { return 'Only ' + $Matches[1] }
        '^role:(.+)$'  { return Get-RoleTitle $Matches[1] }
        '^combo:(.+)$' { return $Matches[1] }
        '^all$'        { return 'All displays' }
        default        { return $Key }
    }
}

# Перенос привязок со старых ключей на новые. Соло-режимы раньше ключевались
# коротким Monitor ID, а он меняется при переходе монитора на другой вход. Если
# такой ключ совпадает с ID подключённого монитора, привязка переезжает на ключ
# по названию — сама, без участия человека. Возвращает $true, если что-то
# изменилось (тогда настройки надо сохранить).
function Update-HotkeyKeys {
    param($Settings, $State)

    if (-not $Settings -or -not $Settings.hotkeys) { return $false }

    $modes = @(Get-DisplayModes $State)
    $live = @($modes | ForEach-Object { $_.Key })
    $changed = $false

    foreach ($old in @($Settings.hotkeys.Keys)) {
        if ($old -notlike 'solo:*') { continue }
        if ($live -contains $old) { continue }

        $id = $old.Substring(5)
        $hit = $modes | Where-Object { $_.Kind -eq 'solo' -and $_.ShortId -eq $id } | Select-Object -First 1

        # Название монитора тоже может смениться: раньше оно склеивалось из двух
        # полей дампа MultiMonitorTool («ROG STRIX XG27AQDMGR»), а система знает
        # его коротким («XG27AQDMGR»). Одно название содержится в другом —
        # этого достаточно, чтобы узнать монитор и перевезти привязку.
        if (-not $hit) {
            $hit = $modes | Where-Object {
                $_.Kind -eq 'solo' -and $_.Label -and
                ($id -like ('*' + $_.Label + '*') -or $_.Label -like ('*' + $id + '*'))
            } | Select-Object -First 1
        }
        if (-not $hit) { continue }
        # Новый ключ уже занят другой комбинацией — не перетираем молча.
        if ($Settings.hotkeys.Contains($hit.Key)) { continue }

        $combo = $Settings.hotkeys[$old]
        $Settings.hotkeys.Remove($old)
        $Settings.hotkeys[$hit.Key] = $combo
        Write-DisplayLog "settings: moved $combo from '$old' to '$($hit.Key)'"
        $changed = $true

        # За клавишей переезжает всё, что привязано к тому же режиму: звук,
        # команды, яркость, контраст. Иначе после перекладки кабеля клавиша
        # работала бы, а яркость к ней больше не относилась — и разошлись бы две
        # части одной настройки.
        foreach ($field in 'audio', 'hooks', 'brightness', 'contrast') {
            $dict = $Settings[$field]
            if (-not $dict -or -not $dict.Contains($old)) { continue }
            if ($dict.Contains($hit.Key)) { continue }
            $dict[$hit.Key] = $dict[$old]
            $dict.Remove($old)
        }
        foreach ($r in @($Settings.rules)) {
            foreach ($field in 'mode', 'back') {
                if ([string]$r[$field] -eq $old) { $r[$field] = [string]$hit.Key }
            }
        }
        if ($Settings.reapply -and [string]$Settings.reapply.onPlug -eq $old) {
            $Settings.reapply.onPlug = [string]$hit.Key
        }
    }
    return $changed
}

function Get-ModeMembers {
    param($Mode, $State)

    $usable = @($State | Where-Object { -not $_.Disconnected })
    switch ($Mode.Kind) {
        'all'  { return $usable }
        # По полному Monitor ID, а не по короткому: короткий — это модель, и у
        # двух одинаковых мониторов он один на двоих.
        'solo' { return @($usable | Where-Object { $_.Id -eq $Mode.Id }) }
        # Участник комбинации — монитор, на который подошёл хоть один из её
        # шаблонов. Циклы, а не конвейер: вложенный Where-Object с двумя $_
        # читается хуже, чем то, что он делает.
        'combo' {
            $members = @()
            foreach ($m in $usable) {
                foreach ($pat in @($Mode.Patterns)) {
                    if (Test-DisplayNameMatch -Pattern $pat -Label $m.Label -ShortId $m.ShortId) {
                        $members += $m
                        break
                    }
                }
            }
            return $members
        }
    }
    return @()
}

# Какой режим соответствует тому, что включено прямо сейчас. Нужно, чтобы в меню
# отметить галочкой текущее состояние.
function Get-ActiveModeKey {
    param($State, $Modes)

    $activeIds = @($State | Where-Object { $_.Active } | ForEach-Object { $_.Id } | Sort-Object)
    if ($activeIds.Count -eq 0) { return $null }

    foreach ($mode in $Modes) {
        $memberIds = @(Get-ModeMembers $mode $State | ForEach-Object { $_.Id } | Sort-Object)
        if ($memberIds.Count -eq $activeIds.Count -and -not (Compare-Object $memberIds $activeIds)) {
            return $mode.Key
        }
    }
    return $null
}

# --- переключение -----------------------------------------------------------

# Сводка переключения и вердикт «успех или нет» — одним местом. По Ok трей
# выбирает между зелёной всплывашкой и жёлтой, CLI — код возврата, поэтому всё,
# что пошло не так, обязано попасть и в текст, и в Ok. Чистая функция: сборка
# текста уже дважды врала (монитор выпадал из сводки, отказ гасить терялся), и
# каждый случай чинился на ощупь — теперь это покрыто тестами.
#
# Об отказе гасить говорим прямо в сводке: иначе выходит рапорт об успехе при
# том, что на столе осталось больше экранов, чем просили. Провал раскладки —
# туда же: 17 августа 2026 он был виден только в журнале, трей показал зелёное
# «Displays switched», и перепутанные мониторы человек обнаружил сам.
function Format-SwitchResult {
    param([string[]]$Summary = @(), [string[]]$Failed = @(), [string[]]$Refused = @(), [bool]$LayoutFailed = $false)

    $text = (@($Summary) -join ', ')
    $parts = @()
    if (@($Failed).Count -gt 0) {
        $parts += ('did not come up: ' + (@($Failed) -join ', ') + ' - unplug the cable and plug it back in')
    }
    if (@($Refused).Count -gt 0) {
        $parts += ('Still on: ' + (@($Refused) -join ', ') + ' - Windows would not turn them off')
    }
    if ($LayoutFailed) {
        $parts += 'positions not arranged - Windows refused the layout, press the hotkey to retry'
    }
    foreach ($p in $parts) {
        $text = $(if ($text) { $text + '. ' + $p } else { $p })
    }
    return [pscustomobject]@{
        Text = $text
        Ok   = (@($Failed).Count -eq 0 -and @($Refused).Count -eq 0 -and -not $LayoutFailed)
    }
}

# Кто из включаемых мониторов станет основным (то есть где панель задач).
# Вынесено из Switch-DisplayMode чистой функцией: с появлением у комбинаций
# собственного primary лестница выросла до шести ступеней, и проверить её можно
# только тестами — внутри переключателя она была непроверяемой.
#
# Ступени, сверху вниз, первый найденный выигрывает:
#   1. -PrimaryMatch из командной строки — ЖЁСТКИЙ: не совпал ни с кем, значит
#      человек опечатался, и молча подменить его выбор своим нельзя — ошибка.
#   2. primary самого режима (у комбинаций) — мягкий: этого монитора может не
#      быть на столе, а комбинация обязана работать и без него.
#   3. primary из настроек — мягкий, по той же причине.
#   4. кто основной прямо сейчас, если он среди включаемых: не двигать без нужды.
#   5. самый правый по layout: у стола есть «главная» сторона.
#   6. первый попавшийся.
function Select-PrimaryDisplay {
    param(
        $Wanted,
        [string]$PrimaryMatch,
        [string]$ModePrimary,
        [string]$SettingsPrimary,
        $Layout,
        [string]$ModeTitle = ''
    )

    $wanted = @($Wanted)

    if ($PrimaryMatch) {
        $hit = $wanted | Where-Object { $_.Label -match [regex]::Escape($PrimaryMatch) } | Select-Object -First 1
        if (-not $hit) {
            $where = $(if ($ModeTitle) { "in '$ModeTitle'" } else { 'that are being turned on' })
            throw "-PrimaryMatch '$PrimaryMatch' matched none of the displays $where."
        }
        return $hit
    }

    foreach ($soft in @($ModePrimary, $SettingsPrimary)) {
        if (-not $soft) { continue }
        $hit = $wanted | Where-Object { $_.Label -like ('*' + $soft + '*') } | Select-Object -First 1
        if ($hit) { return $hit }
    }

    $hit = $wanted | Where-Object { $_.Primary } | Select-Object -First 1
    if ($hit) { return $hit }

    $order = @($Layout)
    for ($k = $order.Count - 1; $k -ge 0; $k--) {
        $hit = $wanted | Where-Object { $_.Label -like ('*' + $order[$k] + '*') } | Select-Object -First 1
        if ($hit) { return $hit }
    }

    return ($wanted | Select-Object -First 1)
}

function Switch-DisplayMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModeKey,
        [string]$PrimaryMatch,
        [switch]$KeepMode,
        [switch]$DryRun,
        [switch]$Quiet
    )

    # Один переключатель за раз. Без этого два быстрых нажатия запускали два
    # процесса, которые перебивали друг друга: один включал монитор, другой в
    # это же время менял ему режим — и результат становился непредсказуемым.
    $mutex = New-Object System.Threading.Mutex($false, 'Local\ScreenDeckSwitch')
    if (-not $mutex.WaitOne(0)) {
        Write-DisplayLog "skip: mode=$ModeKey - the previous switch has not finished yet"
        if (-not $Quiet) { Write-Host 'A switch is already in progress - skipping.' -ForegroundColor Yellow }
        # Dispose обязателен и здесь: в трее процесс живёт неделями, и каждое
        # пропущенное переключение оставляло за собой дескриптор ядра.
        $mutex.Dispose()
        return [pscustomobject]@{ Mode = $ModeKey; Skipped = $true; Message = 'A switch is already in progress.' }
    }

    # Длительность переключения пишется в итоговый done: и остаётся там навсегда.
    # Три строки кода дают постоянный контроль регрессий скорости прямо в журнале:
    # разбор «стало медленнее» без цифр за прошлые недели невозможен.
    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    # Объявлены здесь, а не только там, где присваиваются: оба выставляются лишь
    # на ветке «топология менялась», а читаются ниже безусловно. PowerShell в
    # таком случае ищет переменную в области вызывающего — и однажды нашёл бы
    # чужую, после чего сводка соврала бы про «Still on:».
    $refused = @()
    $doWindows = $false

    try {
        Write-DisplayLog "--- start mode=$ModeKey primaryMatch='$PrimaryMatch' keepMode=$KeepMode dryRun=$DryRun"

        # Настройки читаем РОВНО один раз на переключение. Раньше
        # Get-DisplaySettings вызывался до трёх раз (предпочтение primary,
        # запасной primary по layout, сама раскладка) — три чтения диска и, что
        # хуже, возможность взять разные версии файла внутри одного переключения,
        # если его правят в этот момент из окна настроек.
        $settings = Get-DisplaySettings

        # Настройки уже прочитаны — отдаём их состоянию, иначе оно полезет за
        # ролями на диск само, и внутри одного переключения оказались бы две
        # версии файла (его могут править из окна настроек прямо сейчас).
        $monitors = @(Get-DisplayState -Settings $settings)
        $modes = Get-DisplayModes $monitors $settings
        $mode = $modes | Where-Object { $_.Key -eq $ModeKey } | Select-Object -First 1
        if (-not $mode) {
            # Клавиша может быть назначена на монитор, который сейчас не воткнут —
            # это нормальная ситуация, а не поломка, и говорить надо по-человечески.
            if ($ModeKey -like 'solo:*' -or $ModeKey -like 'role:*') {
                throw "That display is not connected right now."
            }
            # Комбинацию могли удалить в настройках, а клавиша осталась.
            if ($ModeKey -like 'combo:*') {
                throw ("The combination '{0}' no longer exists in the settings." -f (Get-ModeTitleFromKey $ModeKey))
            }
            throw "Unknown mode '$ModeKey'."
        }

        $usable = @($monitors | Where-Object { -not $_.Disconnected })
        $wanted = @(Get-ModeMembers $mode $monitors)

        if ($wanted.Count -eq 0) {
            throw "Mode '$($mode.Title)': none of its displays are connected. Nothing was turned off, so you keep a picture."
        }

        $wantedIds = @($wanted | ForEach-Object { $_.Id })
        $toDisable = @($usable | Where-Object { $wantedIds -notcontains $_.Id })

        # Вся лестница выбора — в Select-PrimaryDisplay (и в его тестах). У
        # комбинаций есть собственный primary — он мягче, чем -PrimaryMatch: тот
        # набирает человек прямо сейчас и опечатка должна быть ошибкой, а primary
        # комбинации записан однажды, и отсутствие того монитора на столе не
        # повод ронять весь режим.
        $primary = Select-PrimaryDisplay -Wanted $wanted -PrimaryMatch $PrimaryMatch `
                                         -ModePrimary ([string]$mode.Primary) `
                                         -SettingsPrimary ([string]$settings.primary) `
                                         -Layout @($settings.layout) -ModeTitle $mode.Title

        if (-not $Quiet) {
            Write-Host "$($mode.Title):" -ForegroundColor Cyan
            foreach ($m in $wanted)    { Write-Host "  on       $($m.Output)  $($m.Label)" }
            Write-Host "  primary  $($primary.Output)  $($primary.Label)"
            foreach ($m in $toDisable) { Write-Host "  off      $($m.Output)  $($m.Label)" }
        }

        # Один переход вместо трёх шагов. Раньше здесь было «включить нужные ->
        # унести роль основного -> погасить лишние», и порядок был важен, потому
        # что основной монитор погасить нельзя. Теперь набор задаётся целиком, а
        # роль основного система переносит внутри перехода сама.
        if ($DryRun) {
            Write-Host ("DRY  displays on: " + (($wanted | ForEach-Object { $_.Label }) -join ', ')) -ForegroundColor DarkGray
            Write-Host ("DRY  primary -> " + $primary.Label) -ForegroundColor DarkGray
        }
        else {
            Write-DisplayLog ("switch: on = " + (($wanted | ForEach-Object { $_.Label }) -join ', '))

            # Команда «до» — здесь, а не в самом начале: до этой строки
            # переключение ещё может отказаться (нет такого режима, ни один
            # монитор не подключён), и запускать чужую программу под режим,
            # которого не будет, нельзя.
            [void](Invoke-ModeHook -Settings $settings -ModeKey $ModeKey -Phase 'before')

            # Набор уже такой, как просят — перестраивать топологию нечего.
            # Состояние у нас на руках, в $monitors: лишнего опроса не надо.
            #
            # Это главная экономия на повторном нажатии хоткея. Без проверки
            # Windows честно перестраивала стол в то же самое состояние: экраны
            # моргали, частота сбрасывалась, и всё это занимало полный цикл. И
            # это же чинит очередь нажатий: цикл сообщений трея однопоточный,
            # накопившиеся за время переключения нажатия теперь исполняются как
            # дешёвые no-op'ы вместо серии полных перестроений.
            #
            # Layout, primary и режимы ниже всё равно проверяются — после 2.4 это
            # дёшево, а пропустить их нельзя: набор мониторов может совпадать, а
            # раскладка быть развалена (например после DisplaySwitch /extend).
            $activeNow = @($monitors | Where-Object { $_.Active } | ForEach-Object { $_.Id } | Sort-Object)
            $wantedSorted = @($wantedIds | Sort-Object)
            $sameTopology = ($activeNow.Count -eq $wantedSorted.Count -and
                             -not (Compare-Object $activeNow $wantedSorted))

            if ($sameTopology) {
                Write-DisplayLog 'switch: topology already correct'
            }
            else {
                # Снимок позиций окон — до перестроения, пока окна ещё стоят так,
                # как их расставил человек. Функции живут в WindowLayout.ps1,
                # который подключают точки входа; core обязан работать и без него,
                # поэтому проверяем наличие, а не зовём вслепую.
                #
                # Только когда топология действительно меняется: при повторном
                # нажатии окна никуда не двигались, а перебор окон с чтением путей
                # процессов стоит десятки миллисекунд — незачем платить их за
                # no-op, ради которого весь granular-skip и делался.
                $doWindows = ((Test-Path Function:\Save-WindowLayout) -and
                              ($null -eq $settings.restoreWindows -or $settings.restoreWindows))
                if ($doWindows) {
                    try { Save-WindowLayout -Key (Get-DisplayLayoutKey -DevicePaths $activeNow) }
                    catch { Write-DisplayLog "warn: windows - saving failed: $($_.Exception.Message)" }
                }

                # Обычный путь — задать стол целиком одним переходом: набор,
                # позиции, основной, разрешения и частоты сразу. Так система
                # перестраивает стол ОДИН раз вместо трёх, и именно это убирает
                # тройное подвисание ввода и моргание экранов.
                #
                # Проверки ниже (Wait-ForTopology, Set-CcdLayout, Set-BestModeFor)
                # остаются на месте и работают как ремонт: когда всё встало сразу,
                # они видят «уже правильно» и ничего не делают.
                $full = $false
                $targets = @(Get-SwitchTargets -Wanted $wanted -Cache (Get-ModeCache) -KeepMode:$KeepMode)
                if ($targets.Count -eq $wanted.Count) {
                    $full = Set-CcdFullConfig -Targets $targets -PrimaryPath $primary.Id -Order @($settings.layout)
                }

                # Не вышло — старая дорога из трёх шагов. Она рабочая, просто
                # моргает: набор без режимов, а позиции и частоту доводят следом.
                if (-not $full -and -not (Set-CcdTopology -DevicePaths $wantedIds)) {
                    throw "Windows refused the display configuration for '$($mode.Title)'. Nothing was changed, so you keep a picture."
                }

                # Проверяем результат, а не верим коду возврата: раньше отказ гасить
                # выглядел в журнале полным успехом.
                $settled = Wait-ForTopology -WantedPaths $wantedIds
                if (-not $settled.Ok) {
                    if ($settled.MissingLabels.Count -gt 0) {
                        Write-DisplayLog 'warn: not all requested displays came up'
                    }
                    if ($settled.ExtraLabels.Count -gt 0) {
                        $refused = @($settled.ExtraLabels)
                        Write-DisplayLog ("warn: refused to turn off: " + ($refused -join ', '))
                    }
                }
            }
        }


        if ($DryRun) { return [pscustomobject]@{ Mode = $ModeKey; Skipped = $false; Message = 'dry run'; Ok = $true } }

        # Раскладку строим здесь, когда набор активных мониторов окончательный:
        # до гашения расставлять нечего — часть экранов сейчас исчезнет, и их
        # координаты всё равно пришлось бы пересчитывать.
        $order = @($settings.layout)
        $layoutChanged = $false
        $layoutFailed = $false
        if ($order.Count -gt 0) {
            $laid = Set-CcdLayout -PrimaryPath $primary.Id -Order $order
            # Пишем «arranged» только когда действительно расставляли. Раньше
            # строка уходила в журнал при любом успехе, и после granular-skip'а
            # получалась пара «already correct» + «arranged left to right» — вторая
            # строка отчитывалась о работе, которой не было.
            if ($laid.Ok -and $laid.Changed) {
                Write-DisplayLog ("layout: arranged left to right - " + ($order -join ' | '))
                $layoutChanged = $true
            }
            elseif ($laid.Ok) {
                Write-DisplayLog 'layout: already correct'
            }
            else {
                # Причина уже в журнале — Set-CcdLayout пишет каждую попытку.
                # Здесь провал запоминается для сводки и вердикта: молчаливый
                # успех при перепутанных мониторах — это и был баг 17 августа.
                $layoutFailed = $true
            }
        }

        # Третий granular-skip, к топологии и раскладке: если стол не двигался
        # вообще И все нужные мониторы уже стоят в своих максимальных режимах —
        # проверять нечего, сводку можно собрать из состояния, снятого на входе.
        #
        # Экономия не косметическая. Сразу после смены раскладки драйвер отвечает
        # на запросы о режимах заметно медленнее, и повторное нажатие, сделанное
        # через секунду после переключения, стоило 0.6 с вместо 0.3 с в покое —
        # ровно тот случай, ради которого granular-skip и задуман (нажатия,
        # скопившиеся за время переключения). Здесь пропускаются перечисление
        # выходов и по два запроса режима на каждый монитор.
        $nothingMoved = ($sameTopology -eq $true) -and (-not $layoutChanged)
        $alreadyBest = $false
        if ($nothingMoved -and -not $KeepMode) {
            $alreadyBest = $true
            foreach ($m in $wanted) {
                if (-not $m.Active -or -not $m.Output -or -not $m.BestMode) { $alreadyBest = $false; break }
                if ($m.Width -ne $m.BestMode.Width -or $m.Height -ne $m.BestMode.Height -or
                    $m.Hz -ne $m.BestMode.Hz) { $alreadyBest = $false; break }
            }
        }

        # Что мониторы реально показывают в итоге. Уходит в кэш проверенных
        # режимов, чтобы следующее переключение могло задать частоту сразу, не
        # дожидаясь, пока спящий монитор проснётся и расскажет о себе.
        $applied = @{}

        # Кому потом ставить яркость: имя выхода нужно то же, что вернуло
        # перечисление ниже, а не своё повторное — обход CCD стоит десятки
        # миллисекунд, и второй раз за одно переключение он не нужен.
        $levelTargets = @()

        if ($alreadyBest) {
            $summary = @()
            foreach ($m in $wanted) {
                $summary += '{0} {1}x{2} @ {3} Hz' -f $m.Label, $m.Width, $m.Height, $m.Hz
                $applied[[string]$m.Id] = [pscustomobject]@{ Width = $m.Width; Height = $m.Height; Hz = $m.Hz }
                $levelTargets += [pscustomobject]@{ Device = [string]$m.Output; Label = [string]$m.Label; ShortId = [string]$m.ShortId }
            }
            $failed = @()
            Write-DisplayLog 'switch: modes already correct'
        }
        else {
            # Режим выставляем последним, когда набор активных мониторов уже
            # окончательный: и назначение основного, и гашение соседа сбрасывают
            # частоту на то, что записано в реестре, а там она часто ниже родной.
            # Каждый монитор ждём отдельно — иначе он не успевает прицепиться, и
            # установка режима вместе со сводкой пропадают вообще без следа.
            #
            # Имена выходов берём ОДНИМ перечислением на всех, а не по одному на
            # монитор: Get-CcdOutput внутри зовёт Get-CcdTargets (полный обход CCD
            # с запросом имён, ~50 мс), и на трёх мониторах это втрое дороже без
            # всякой причины. Кто уже на столе — найдётся здесь; кто ещё
            # просыпается — уйдёт в Get-CcdOutput и будет честно дождан.
            $outputs = @{}
            foreach ($t in @(Get-CcdTargets)) {
                if ($t.Active -and $t.Output) { $outputs[$t.DevicePath] = $t.Output }
            }

            $summary = @()
            $failed = @()
            foreach ($m in $wanted) {
                $output = $outputs[$m.Id]
                if (-not $output) { $output = Get-CcdOutput -DevicePath $m.Id }
                if (-not $output) {
                    # Раньше здесь стоял continue, и монитор просто исчезал из
                    # сводки. Получался рапорт об успехе при чёрном экране: в
                    # журнале «did not attach» и следом пустое «done:», а человек
                    # в этот момент смотрел на погасший стол.
                    Write-DisplayLog "warn: $($m.Label) did not attach within 8 s - mode was not applied"
                    $failed += $m.Label
                    continue
                }
                if (-not $KeepMode) {
                    $nw = 0; $nh = 0
                    if ($m.Native) { $nw = $m.Native.Width; $nh = $m.Native.Height }
                    # $m.BestMode посчитан в Get-DisplayState на входе — для
                    # монитора, который уже был включён, он готов, и перебор
                    # режимов (дорогой сразу после смены топологии) не нужен. У
                    # только что проснувшегося он $null, и Set-BestModeFor
                    # посчитает сам.
                    [void](Set-BestModeFor -Output $output -Label $m.Label -NativeWidth $nw -NativeHeight $nh -Best $m.BestMode)
                }
                $levelTargets += [pscustomobject]@{ Device = [string]$output; Label = [string]$m.Label; ShortId = [string]$m.ShortId }
                $cur = Get-CurrentMode $output
                $summary += $(if ($cur) { '{0} {1}x{2} @ {3} Hz' -f $m.Label, $cur.Width, $cur.Height, $cur.Hz } else { $m.Label })
                if ($cur -and $cur.Width -gt 0) {
                    $applied[[string]$m.Id] = [pscustomobject]@{ Width = $cur.Width; Height = $cur.Height; Hz = $cur.Hz }
                }
            }
        }

        $verdict = Format-SwitchResult -Summary $summary -Failed $failed -Refused $refused -LayoutFailed $layoutFailed
        $text = $verdict.Text
        # Форматируем через InvariantCulture: журнал английский, а `-f` берёт
        # разделитель из текущей локали и на русской писал бы «4,2 s».
        $took = $watch.Elapsed.TotalSeconds.ToString('0.0', [cultureinfo]::InvariantCulture)
        Write-DisplayLog ("done: {0} ({1} s)" -f $text, $took)

        # Запоминаем ВЫБОР, а не результат: даже если один монитор не поднялся,
        # человек просил именно этот режим, и после включения компьютера
        # возвращать надо его. Провал переключения сюда не доходит — он уходит
        # исключением выше.
        Save-LastMode -Key $ModeKey

        # А здесь наоборот — только факт: что монитор показал, то и запомнили.
        # Точную дробь частоты берём у CCD: целых герцов для запроса режима не
        # хватает (см. Get-ModeCache), а один обход активных путей стоит единицы
        # миллисекунд.
        if (@($applied.Keys).Count -gt 0) {
            $rates = Get-CcdActiveRates
            foreach ($k in @($applied.Keys)) {
                $r = $rates[$k]
                $applied[$k] | Add-Member -NotePropertyName RateNum -NotePropertyValue $(if ($r) { $r.Num } else { 0 }) -Force
                $applied[$k] | Add-Member -NotePropertyName RateDen -NotePropertyValue $(if ($r) { $r.Den } else { 0 }) -Force
            }
            Save-ModeCache -Modes $applied
        }

        # Окна раскладываем последними: и смена режима, и назначение основного
        # монитора двигают их сами, поэтому раньше это делать бессмысленно.
        # $doWindows выставлен только если топология действительно менялась —
        # при повторном нажатии окна не трогаем вообще.
        if ($doWindows) {
            try { Restore-WindowLayout -Key (Get-DisplayLayoutKey -DevicePaths $wantedIds) }
            catch { Write-DisplayLog "warn: windows - restoring failed: $($_.Exception.Message)" }
        }

        # Звук — после того, как режим состоялся: незачем гонять устройства, если
        # переключение провалилось. Словарь пуст (по умолчанию) — кода нет вообще.
        if ($settings.audio -and $settings.audio.Contains($ModeKey)) {
            $want = [string]$settings.audio[$ModeKey]
            if ($want) {
                try { [void](Set-DefaultAudioDevice -Match $want) }
                catch { Write-DisplayLog "warn: audio - failed: $($_.Exception.Message)" }
            }
        }

        # Яркость и контраст — последними и только тем мониторам, что включены:
        # спящий на DDC не отвечает. Словари пусты (по умолчанию) — не выполняется
        # ни одна строка, ни один запрос по медленной шине не уходит.
        $hasLevels = (($settings.brightness -and $settings.brightness.Contains($ModeKey)) -or
                      ($settings.contrast -and $settings.contrast.Contains($ModeKey)))
        if ($hasLevels -and $levelTargets.Count -gt 0) {
            $b = $(if ($settings.brightness -and $settings.brightness.Contains($ModeKey)) { $settings.brightness[$ModeKey] } else { $null })
            $c = $(if ($settings.contrast   -and $settings.contrast.Contains($ModeKey))   { $settings.contrast[$ModeKey] }   else { $null })
            try { [void](Set-MonitorLevels -Targets $levelTargets -BrightnessSetting $b -ContrastSetting $c) }
            catch { Write-DisplayLog "warn: levels - failed: $($_.Exception.Message)" }
        }

        # Команда «после» — в самом конце, когда стол уже собран: она затем и
        # нужна, чтобы застать готовое состояние.
        [void](Invoke-ModeHook -Settings $settings -ModeKey $ModeKey -Phase 'after')
        return [pscustomobject]@{
            Mode = $ModeKey; Skipped = $false; Message = $text
            Refused = $refused; Failed = $failed
            Seconds = $watch.Elapsed.TotalSeconds
            Ok = $verdict.Ok
        }
    }
    catch {
        Write-DisplayLog "ERROR: $($_.Exception.Message)"
        throw
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

# --- сторож частоты ---------------------------------------------------------
# Windows сбрасывает частоту сама: при подключении монитора, при выходе из сна,
# при смене раскладки. На этой машине она вдобавок не может записать режим в
# реестр (см. Set-DisplayMode), поэтому «запомнить 240 Гц» не получается в
# принципе — режим живёт только до следующего сброса. Значит его надо возвращать.
#
# Вызывается по системному событию DisplaySettingsChanged. Дребезг гасим: одно
# изменение раскладки поднимает событие несколько раз подряд.

$script:LastRestore = [datetime]::MinValue

# Сторож ждёт выхода из игры: пока true, таймер трея будет пробовать снова.
$script:RestorePending = $false

# Чтобы «разрешение не наше» не писалось в лог на каждой проверке: монитор -> WxH.
$script:LastResNote = @{}

# Игра ставит себе режим сама, и трогать его в этот момент нельзя: смена режима
# извне роняет полноэкранное устройство D3D — картинка моргает, окно сворачивается.
# Ровно это и происходило при запуске Counter-Strike.
#
# Спрашиваем два раза. Сначала оболочку: SHQueryUserNotificationState — тот же
# источник, по которому Windows решает, показывать ли всплывашки. Он ловит
# честный полный экран, но не ловит безрамочное окно, поэтому вторым шагом
# смотрим, не закрывает ли активное окно свой монитор целиком.
function Test-FullscreenApp {
    try {
        $state = 0
        if ([NativeForeground]::SHQueryUserNotificationState([ref]$state) -eq 0) {
            # 2 — полноэкранное окно, 3 — D3D во весь экран, 4 — режим презентации,
            # 7 — приложение Store во весь экран. 5 и 6 нам не мешают.
            if ($state -eq 2 -or $state -eq 3 -or $state -eq 4 -or $state -eq 7) { return $true }
        }
    }
    catch { }

    try {
        $hwnd = [NativeForeground]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $false }

        # Рабочий стол и панель задач тоже во весь экран — они не в счёт.
        $cls = New-Object System.Text.StringBuilder 256
        [void][NativeForeground]::GetClassName($hwnd, $cls, 256)
        if (@('Progman', 'WorkerW', 'Shell_TrayWnd') -contains $cls.ToString()) { return $false }

        $rect = New-Object NativeForeground+RECT
        if (-not [NativeForeground]::GetWindowRect($hwnd, [ref]$rect)) { return $false }

        $mon = [NativeForeground]::MonitorFromWindow($hwnd, [NativeForeground]::MONITOR_DEFAULTTONEAREST)
        $mi = New-Object NativeForeground+MONITORINFO
        $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
        if (-not [NativeForeground]::GetMonitorInfo($mon, [ref]$mi)) { return $false }

        # Развёрнутое окно закрывает рабочую область, но не панель задач, поэтому
        # сюда попадает только по-настоящему безрамочный полный экран.
        return ($rect.Left -le $mi.rcMonitor.Left -and $rect.Top -le $mi.rcMonitor.Top -and
                $rect.Right -ge $mi.rcMonitor.Right -and $rect.Bottom -ge $mi.rcMonitor.Bottom)
    }
    catch { return $false }
}

function Restore-BestModes {
    param([int]$DebounceMs = 3000)

    if (((Get-Date) - $script:LastRestore).TotalMilliseconds -lt $DebounceMs) { return @() }
    $script:LastRestore = Get-Date

    if (Test-FullscreenApp) {
        if (-not $script:RestorePending) {
            Write-DisplayLog 'watch: postponed - a full-screen app is running, it sets the mode itself'
        }
        $script:RestorePending = $true
        return @()
    }

    # Во время переключения не вмешиваемся — там режимы ставятся сами.
    $mutex = New-Object System.Threading.Mutex($false, 'Local\ScreenDeckSwitch')
    if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); return @() }

    try {
        # Сначала только собираем список — ничего не применяем. Игра успевает
        # открыться уже после события о смене режима, и проверка на входе её
        # иногда не застаёт; сбор состояния занимает секунду, и повторная
        # проверка ниже попадает уже по открытому полному экрану.
        $todo = @()
        # Роли сторожу не нужны — он смотрит только на частоту, — поэтому за
        # настройками на диск не ходим: событие о смене режима приходит пачками,
        # и лишний ввод-вывод в его обработчике здесь ни к чему.
        foreach ($m in @(Get-DisplayState -Settings (Get-DefaultSettings))) {
            if (-not $m.Active -or -not $m.BestMode) { continue }
            $cur = Get-CurrentMode $m.Output
            if (-not $cur) { continue }
            # Разрешение сторож не трогает. Само оно не меняется: Windows сбрасывает
            # именно частоту (см. лог — 240→144, 60→29). А вот приложение меняет
            # именно разрешение и осознанно: Counter-Strike ставит растянутые
            # 1440x1080, и три возврата подряд на 2560x1440 ломали ему запуск.
            $sameRes = ($cur.Width -eq $m.BestMode.Width -and $cur.Height -eq $m.BestMode.Height)
            if (-not $sameRes) {
                $note = '{0}x{1}' -f $cur.Width, $cur.Height
                if ($script:LastResNote[$m.Label] -ne $note) {
                    $script:LastResNote[$m.Label] = $note
                    Write-DisplayLog ("watch: {0} is at {1}x{2}, not {3}x{4} - leaving the resolution alone, an app set it" -f `
                        $m.Label, $cur.Width, $cur.Height, $m.BestMode.Width, $m.BestMode.Height)
                }
                continue
            }

            $script:LastResNote.Remove($m.Label)
            if ($cur.Hz -eq $m.BestMode.Hz) { continue }

            $todo += [pscustomobject]@{ Monitor = $m; Current = $cur }
        }

        if ($todo.Count -gt 0 -and (Test-FullscreenApp)) {
            if (-not $script:RestorePending) {
                Write-DisplayLog 'watch: postponed - a full-screen app is running, it sets the mode itself'
            }
            $script:RestorePending = $true
            return @()
        }

        $fixed = @()
        foreach ($t in $todo) {
            $m = $t.Monitor
            $cur = $t.Current

            Write-DisplayLog ("watch: {0} dropped to {1}x{2} @ {3} Hz, restoring {4}x{5} @ {6} Hz" -f `
                $m.Label, $cur.Width, $cur.Height, $cur.Hz, $m.BestMode.Width, $m.BestMode.Height, $m.BestMode.Hz)

            $nw = 0; $nh = 0
            if ($m.Native) { $nw = $m.Native.Width; $nh = $m.Native.Height }
            # BestMode здесь тоже уже посчитан: сторож как раз по нему и решил,
            # что монитор просел. Второй перебор режимов был бы лишним.
            if (Set-BestModeFor -Output $m.Output -Label $m.Label -NativeWidth $nw -NativeHeight $nh -Best $m.BestMode) {
                $fixed += $m.Label
            }
        }
        # Своё же изменение поднимет событие ещё раз — не даём войти по кругу.
        if ($fixed.Count -gt 0) { $script:LastRestore = Get-Date }
        $script:RestorePending = $false
        return $fixed
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

# --- звук следом за режимом -------------------------------------------------
# Каждому режиму можно сопоставить устройство вывода: сел играть на ASUS — звук
# ушёл в его колонки, вернулся за работу — в наушники на столе. Выключено, пока
# словарь audio в настройках пуст.

# Список устройств вывода — для настройки руками: чтобы знать, какой кусок
# названия писать в settings.json. Вызывается из Set-Display.ps1 (audio).
function Get-AudioDevices {
    try { return @([NativeAudio]::ListRenderDevices()) }
    catch {
        Write-DisplayLog "warn: audio - could not list devices: $($_.Exception.Message)"
        return @()
    }
}

# Сделать устройством по умолчанию первое, чьё название содержит $Match.
#
# Роли назначаем eConsole и eMultimedia, а eCommunications НЕ трогаем осознанно:
# устройство для разговоров — это обычно гарнитура, и она не должна ездить за
# мониторами. Кому нужно иначе, тот поправит здесь.
function Set-DefaultAudioDevice {
    param([Parameter(Mandatory)][string]$Match)

    if (-not $Match) { return $false }

    $devices = Get-AudioDevices
    if ($devices.Count -eq 0) { return $false }

    $hit = $devices | Where-Object { $_.Name -like ('*' + $Match + '*') } | Select-Object -First 1
    if (-not $hit) {
        # Названия перечисляем в журнале: без них непонятно, что писать в
        # настройки, а окна для этого нет.
        Write-DisplayLog ("warn: audio device '{0}' not found - have: {1}" -f `
            $Match, (($devices | ForEach-Object { $_.Name }) -join '; '))
        return $false
    }

    if ($hit.IsDefault) { return $true }   # уже он — молчим, чтобы не шуметь

    try {
        $rc = [NativeAudio]::SetDefault($hit.Id, 0)          # eConsole
        $rc2 = [NativeAudio]::SetDefault($hit.Id, 1)         # eMultimedia
        if ($rc -ne 0 -or $rc2 -ne 0) {
            Write-DisplayLog ("warn: audio - switching to '{0}' returned {1}/{2}" -f $hit.Name, $rc, $rc2)
            return $false
        }
        Write-DisplayLog ("audio: default -> {0}" -f $hit.Name)
        return $true
    }
    catch {
        Write-DisplayLog "warn: audio - could not switch: $($_.Exception.Message)"
        return $false
    }
}

# --- яркость и контраст следом за режимом -----------------------------------
# Яркость внешнего монитора живёт в его прошивке, а не в Windows, и меняется по
# DDC/CI — тому же каналу, что кнопки на корпусе (см. NativeDdc). Значит режим
# может нести её с собой: «Work» — 80, вечерний — 25, и колёсико под столом
# больше не нужно.
#
# Спящему монитору задавать нечего: он на запросы не отвечает. Поэтому уровни
# ставятся только включённым, в самом конце переключения.

function Get-MonitorLevels {
    try { return @([NativeDdc]::Read()) }
    catch {
        Write-DisplayLog "levels: could not ask the monitors - $($_.Exception.Message)"
        return @()
    }
}

# Чистая функция: настройка одного режима + мониторы этого режима -> кому какое
# число. Две формы записи, потому что нужны обе: число — «всем поровну» (так
# пишут в девяти случаях из десяти), словарь — «каждому своё».
#
# Возвращает [ordered] по порядку мониторов: журнал должен читаться в том же
# порядке, в котором мониторы стоят на столе.
function Get-LevelPlan {
    param($Setting, $Wanted)

    $plan = [ordered]@{}
    if ($null -eq $Setting) { return $plan }

    foreach ($m in @($Wanted)) {
        $value = $null
        if ($Setting -is [int] -or $Setting -is [long] -or $Setting -is [double] -or $Setting -is [string]) {
            $parsed = 0
            if ([int]::TryParse([string]$Setting, [ref]$parsed)) { $value = $parsed }
        }
        elseif ($Setting -is [System.Collections.IDictionary]) {
            foreach ($key in @($Setting.Keys)) {
                if (Test-DisplayNameMatch -Pattern ([string]$key) -Label $m.Label -ShortId $m.ShortId) {
                    $parsed = 0
                    if ([int]::TryParse([string]$Setting[$key], [ref]$parsed)) { $value = $parsed }
                    break
                }
            }
        }
        if ($null -eq $value) { continue }
        # Ноль — законная яркость (монитор гаснет в чёрный, но остаётся включён),
        # поэтому обрезаем, а не отбрасываем. Числа вне 0..100 — почти всегда
        # опечатка, и уводить монитор в чёрный по опечатке нельзя.
        if ($value -lt 0) { $value = 0 }
        if ($value -gt 100) { $value = 100 }
        $plan[[string]$m.Label] = $value
    }
    return $plan
}

# $Targets — массив объектов с полями Device (\\.\DISPLAY1), Label и ShortId.
# Device приходит из уже сделанного перечисления выходов: своего обхода CCD здесь
# нет специально, переключение и без того не бесплатное.
function Set-MonitorLevels {
    param($Targets, $BrightnessSetting, $ContrastSetting)

    $bright = Get-LevelPlan -Setting $BrightnessSetting -Wanted $Targets
    $contra = Get-LevelPlan -Setting $ContrastSetting -Wanted $Targets
    if ($bright.Count -eq 0 -and $contra.Count -eq 0) { return @() }

    # Сначала собираем запрос целиком и только потом идём на шину: один обход на
    # все мониторы вместо обхода на каждый (см. NativeDdc.Set).
    $devices = @(); $wantB = @(); $wantC = @(); $labels = @()
    foreach ($t in @($Targets)) {
        $label = [string]$t.Label
        $b = $(if ($bright.Contains($label)) { [int]$bright[$label] } else { -1 })
        $c = $(if ($contra.Contains($label)) { [int]$contra[$label] } else { -1 })
        if ($b -lt 0 -and $c -lt 0) { continue }
        if (-not $t.Device) { continue }

        $devices += [string]$t.Device
        $wantB += $b
        $wantC += $c
        $labels += $label
    }
    if ($devices.Count -eq 0) { return @() }

    $applied = @()
    try { $applied = @([NativeDdc]::Set([string[]]$devices, [int[]]$wantB, [int[]]$wantC)) }
    catch { Write-DisplayLog "levels: could not set - $($_.Exception.Message)"; return @() }

    $done = @()
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $label = $labels[$i]
        $b = [int]$wantB[$i]
        $c = [int]$wantC[$i]
        $one = $(if ($i -lt $applied.Count) { $applied[$i] } else { $null })
        if (-not $one) {
            Write-DisplayLog ("levels: {0} - no answer from the bus at all" -f $label)
            continue
        }

        # Разбираем по значениям, а не «получилось / не получилось»: яркость
        # монитор мог применить, а контраст нет, и в журнале это должно быть видно
        # раздельно. Подтверждение — прочитанное обратно значение, а не код
        # возврата записи (см. NativeDdc.Set).
        $good = @()
        $bad = @()
        if ($b -ge 0) { if ($one.BrightnessConfirmed) { $good += "brightness $b" } else { $bad += "brightness $b" } }
        if ($c -ge 0) { if ($one.ContrastConfirmed)   { $good += "contrast $c" }   else { $bad += "contrast $c" } }

        if ($good.Count -gt 0) {
            Write-DisplayLog ("levels: {0} - {1}" -f $label, ($good -join ', '))
            $done += $label
        }
        if ($bad.Count -gt 0) {
            # Монитор не подтвердил. Причины бывают безобидные (DDC/CI выключен в
            # его меню, монитор ещё просыпается, шина зависла до следующего цикла
            # линка), но врать об успехе нельзя.
            Write-DisplayLog ("levels: {0} did not take {1} - DDC/CI may be off in its own menu" -f $label, ($bad -join ', '))
        }
    }
    return $done
}

# --- команды вокруг переключения --------------------------------------------
# «Сделай ещё вот это, когда включаешь такой набор экранов». Одна строка в
# настройках вместо десяти новых полей: закрыть приложение, сменить схему
# питания, погасить свет в комнате — всё это чужие программы, и знать о них
# незачем. Наше дело — запустить и записать в журнал, что запустили.

# Чистая функция: настройки + ключ режима + фаза -> команда или пустая строка.
function Get-ModeHook {
    param($Settings, [string]$ModeKey, [string]$Phase)

    if (-not $Settings -or -not $Settings.hooks -or -not $ModeKey) { return '' }
    if (-not $Settings.hooks.Contains($ModeKey)) { return '' }
    $entry = $Settings.hooks[$ModeKey]
    if ($null -eq $entry) { return '' }
    # Строка вместо объекта — это «после»: короткая запись для частого случая.
    if ($entry -is [string]) { return $(if ($Phase -eq 'after') { [string]$entry } else { '' }) }
    return [string]$entry[$Phase]
}

# Чистая функция: команда -> чем и с чем её запускать. .ps1 приходится звать
# через powershell с обходом политики (свои же скрипты иначе не запустятся), всё
# остальное уходит в cmd /c — там работают и .exe, и .bat, и встроенные команды
# вроде start.
function Get-HookLaunch {
    param([string]$Command)

    $cmd = [string]$Command
    if (-not $cmd -or -not $cmd.Trim()) { return $null }
    $cmd = $cmd.Trim()

    # Первое слово — с учётом кавычек: в пути к скрипту бывают пробелы.
    $first = ''
    if ($cmd -match '^"([^"]+)"') { $first = $Matches[1] }
    elseif ($cmd -match '^(\S+)') { $first = $Matches[1] }

    if ($first -like '*.ps1') {
        $rest = $cmd.Substring($(if ($cmd.StartsWith('"')) { $first.Length + 2 } else { $first.Length })).Trim()
        $argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $first
        if ($rest) { $argLine += ' ' + $rest }
        return [pscustomobject]@{
            File      = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
            Arguments = $argLine
        }
    }
    return [pscustomobject]@{
        File      = (Join-Path $env:SystemRoot 'System32\cmd.exe')
        Arguments = '/c ' + $cmd
    }
}

function Invoke-ModeHook {
    param($Settings, [string]$ModeKey, [string]$Phase)

    $cmd = Get-ModeHook -Settings $Settings -ModeKey $ModeKey -Phase $Phase
    if (-not $cmd) { return $false }
    $launch = Get-HookLaunch -Command $cmd
    if (-not $launch) { return $false }

    try {
        # Запускаем и НЕ ждём. Переключение стола — вещь, которую человек делает
        # хоткеем и мерит десятыми долями секунды; чужая программа не имеет права
        # держать её у себя, а «зависший before» означал бы чёрный экран.
        Start-Process -FilePath $launch.File -ArgumentList $launch.Arguments -WindowStyle Hidden | Out-Null
        Write-DisplayLog ("hook: {0} - {1}" -f $Phase, $cmd)
        return $true
    }
    catch {
        Write-DisplayLog ("hook: {0} failed - {1}" -f $Phase, $_.Exception.Message)
        return $false
    }
}

# --- правила ----------------------------------------------------------------
# «Случилось это — стань таким». Выросло из авто-игрового режима, который умел
# ровно одно правило (см. Convert-AutoGameToRules).
#
# Вся логика — здесь, чистой функцией над фактами, и она же под тестами. В трее
# остаётся только собрать факты и исполнить решение: слежение живёт в таймере,
# который тикает раз в пятнадцать секунд неделями, и отлаживать его по журналу
# вместо тестов — это и есть тот способ, которым в этом проекте уже ломали стол.
#
# Владение: пока правило держит стол, остальные молчат. Иначе два подходящих
# правила перебивали бы друг друга каждые пятнадцать секунд.

function Test-RuleMatch {
    param($Rule, $Facts)

    if (-not $Rule) { return $false }
    if ($null -ne $Rule.enabled -and -not $Rule.enabled) { return $false }
    if (-not $Rule.mode) { return $false }

    switch ([string]$Rule.when) {
        'process' {
            if (-not $Rule.process) { return $false }
            $want = ([string]$Rule.process) -replace '\.exe$', ''
            foreach ($p in @($Facts.Processes)) {
                if ([string]$p -and ([string]$p).ToLowerInvariant() -eq $want.ToLowerInvariant()) { return $true }
            }
            return $false
        }
        'idle' {
            $minutes = [int]$Rule.minutes
            if ($minutes -le 0) { return $false }
            return ([int]$Facts.IdleSeconds -ge $minutes * 60)
        }
        default { return $false }
    }
}

# Решение по всем правилам разом. $OwnedIndex — номер правила, которое сейчас
# держит стол, или -1.
#
# Action:
#   switch   уйти в Mode, запомнив Back и RuleIndex;
#   return   условие кончилось, вернуться в Mode;
#   release  стол переключили руками — отпустить, ничего не делая;
#   blocked  правило сработало, но возвращаться потом будет некуда;
#   none     ничего не делать.
function Get-RuleDecision {
    param($Rules, $Facts, [string]$CurrentMode, [int]$OwnedIndex = -1, [string]$OwnedBack = '')

    $list = @($Rules)
    $none = [pscustomobject]@{ Action = 'none'; Mode = ''; Back = ''; RuleIndex = -1; Reason = '' }

    if ($OwnedIndex -ge 0) {
        $owned = $(if ($OwnedIndex -lt $list.Count) { $list[$OwnedIndex] } else { $null })
        # Правило исчезло из настроек, пока оно держало стол (файл правят руками и
        # из окна настроек) — возвращаемся туда, откуда пришли, и отпускаем.
        if (-not $owned) {
            return [pscustomobject]@{ Action = 'return'; Mode = [string]$OwnedBack; Back = ''; RuleIndex = -1
                                      Reason = 'the rule is gone from the settings' }
        }
        if (Test-RuleMatch -Rule $owned -Facts $Facts) {
            # С людьми не воюем: набор экранов сменили мимо нас — значит это
            # осознанное решение, и возвращать его назад мы не в праве.
            if ($CurrentMode -and $CurrentMode -ne [string]$owned.mode) {
                return [pscustomobject]@{ Action = 'release'; Mode = ''; Back = ''; RuleIndex = -1
                                          Reason = 'the displays were changed by hand' }
            }
            return $none
        }
        return [pscustomobject]@{ Action = 'return'; Mode = [string]$OwnedBack; Back = ''; RuleIndex = -1
                                  Reason = 'the condition ended' }
    }

    for ($i = 0; $i -lt $list.Count; $i++) {
        $rule = $list[$i]
        if (-not (Test-RuleMatch -Rule $rule -Facts $Facts)) { continue }

        # Уже в этом режиме — брать стол незачем: возвращать потом будет нечего, и
        # это правильно (то же решение принимал авто-игровой режим).
        if ($CurrentMode -eq [string]$rule.mode) { return $none }

        $back = $(if ($rule.back) { [string]$rule.back } else { [string]$CurrentMode })
        if (-not $back) {
            return [pscustomobject]@{ Action = 'blocked'; Mode = [string]$rule.mode; Back = ''; RuleIndex = $i
                                      Reason = 'the current displays match no known mode, so there would be no way back' }
        }
        return [pscustomobject]@{ Action = 'switch'; Mode = [string]$rule.mode; Back = $back; RuleIndex = $i
                                  Reason = (Format-RuleReason -Rule $rule) }
    }
    return $none
}

# Строка для журнала и всплывашки: «cs2 is running», «idle for 20 min».
function Format-RuleReason {
    param($Rule)

    switch ([string]$Rule.when) {
        'process' { return ('{0} is running' -f [string]$Rule.process) }
        'idle'    { return ('idle for {0} min' -f [int]$Rule.minutes) }
        default   { return [string]$Rule.when }
    }
}

# --- мир изменился сам ------------------------------------------------------
# Windows после выхода из сна и после переподключения монитора расставляет
# экраны как считает нужным: раскладка разъезжается, панель задач уезжает на
# другой монитор, частота падает. Стол надо собрать заново.
#
# Чистая функция: два набора подключённых мониторов (до и после) + настройка ->
# что делать. Само событие приходит в трее, там же и исполняется решение.
#
# Важно, что сравниваются ПОДКЛЮЧЁННЫЕ мониторы, а не включённые: включённые
# меняем мы сами на каждом переключении, и реагировать на собственную работу
# значило бы уйти в бесконечный круг.
function Get-ReapplyDecision {
    param($Reapply, $Before, $Now, [string]$LastMode)

    $none = [pscustomobject]@{ Action = 'none'; Mode = ''; Reason = '' }
    if (-not $Reapply) { return $none }

    $before = @($Before | Where-Object { $_ })
    $now = @($Now | Where-Object { $_ })
    # Пустой «до» — это первый опрос за запуск, сравнивать не с чем.
    if ($before.Count -eq 0) { return $none }

    $appeared = @($now | Where-Object { $before -notcontains $_ })
    $vanished = @($before | Where-Object { $now -notcontains $_ })

    # Монитор появился. По умолчанию не делаем ничего: человек только что включил
    # его кнопкой, и погасить его в ответ — это война с человеком. Режим для этого
    # случая называют явно (reapply.onPlug).
    if ($appeared.Count -gt 0 -and [string]$Reapply.onPlug) {
        return [pscustomobject]@{ Action = 'mode'; Mode = [string]$Reapply.onPlug
                                  Reason = 'a display was plugged in' }
    }

    # Монитор пропал. Возвращаем последний выбранный режим: Switch-DisplayMode
    # соберёт из него то, что осталось на столе, — раскладку и панель задач в том
    # числе. Ничего нового при этом не включается.
    if ($vanished.Count -gt 0 -and $Reapply.onUnplug -and $LastMode) {
        return [pscustomobject]@{ Action = 'mode'; Mode = [string]$LastMode
                                  Reason = 'a display went away' }
    }
    return $none
}

# --- таймер выключения ------------------------------------------------------
# «Выключи компьютер через час». Отсчёт живёт в трее и умирает вместе с ним: на
# диск его писать нельзя — компьютер, который выключается сам через сутки после
# того, как об этом попросили, страшнее любой пользы.

# Чистая функция: то, что человек написал -> минуты. Понимает «30», «90m»,
# «1h», «1h30», «1:30», «2 hours». Ноль означает «не разобрал».
function ConvertFrom-DurationText {
    param([string]$Text)

    $t = ([string]$Text).Trim().ToLowerInvariant()
    if (-not $t) { return 0 }

    # Часы с минутами: «1h30», «1h 30m», «1:30».
    if ($t -match '^(\d+)\s*(?:h|hr|hrs|hour|hours|ч|час|часа|часов|:)\s*(\d+)\s*(?:m|min|mins|minute|minutes|м|мин)?$') {
        return [int]$Matches[1] * 60 + [int]$Matches[2]
    }
    if ($t -match '^(\d+)\s*(?:h|hr|hrs|hour|hours|ч|час|часа|часов)$') { return [int]$Matches[1] * 60 }
    if ($t -match '^(\d+)\s*(?:m|min|mins|minute|minutes|м|мин)?$')     { return [int]$Matches[1] }
    return 0
}

# «1 h 05 min», «45 min», «30 s» — для подсказки значка и всплывашки.
function Format-Duration {
    param([int]$Seconds)

    if ($Seconds -lt 0) { $Seconds = 0 }
    if ($Seconds -lt 60) { return ('{0} s' -f $Seconds) }
    $minutes = [int][math]::Floor($Seconds / 60)
    if ($minutes -lt 60) { return ('{0} min' -f $minutes) }
    return ('{0} h {1:00} min' -f [int][math]::Floor($minutes / 60), ($minutes % 60))
}

# Само выключение. shutdown.exe, а не API: он один умеет и попросить программы
# закрыться, и показать причину в журнале событий Windows.
function Invoke-PowerAction {
    param([ValidateSet('shutdown', 'restart', 'sleep')][string]$Action)

    Write-DisplayLog "power: $Action now"
    switch ($Action) {
        'shutdown' { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -ArgumentList '/s', '/t', '0' -WindowStyle Hidden | Out-Null }
        'restart'  { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -ArgumentList '/r', '/t', '0' -WindowStyle Hidden | Out-Null }
        'sleep'    {
            # Спать — только через SetSuspendState: shutdown.exe /h — это
            # гибернация, а /s /hybrid — выключение. Первый параметр false и
            # означает «сон, а не гибернация».
            [void][NativePower]::SetSuspendState($false, $true, $false)
        }
    }
}

# --- автозагрузка -----------------------------------------------------------

function Get-StartupShortcutPath {
    return Join-Path ([Environment]::GetFolderPath('Startup')) 'ScreenDeck.lnk'
}

function Test-RunAtStartup {
    return (Test-Path (Get-StartupShortcutPath))
}

function Set-RunAtStartup {
    param([bool]$Enabled)

    $lnk = Get-StartupShortcutPath
    if (-not $Enabled) {
        if (Test-Path $lnk) { Remove-Item $lnk -Force }
        Write-DisplayLog 'startup: disabled'
        return
    }

    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sc.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:ToolRoot 'Displays.ps1')
    $sc.WorkingDirectory = $script:ToolRoot
    $icon = Join-Path $script:ToolRoot 'app.ico'
    if (Test-Path $icon) { $sc.IconLocation = $icon + ',0' }
    else { $sc.IconLocation = (Join-Path $env:SystemRoot 'System32\DisplaySwitch.exe') + ',0' }
    $sc.WindowStyle = 7
    $sc.Description = 'ScreenDeck - display switcher in the notification area'
    $sc.Save()
    Write-DisplayLog 'startup: enabled'
}
