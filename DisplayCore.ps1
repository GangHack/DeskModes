<#
    DisplayCore.ps1 — общая логика переключения мониторов.

    Только определения, никаких действий при загрузке. Точки входа:
        Displays.ps1      значок в трее
        Set-Display.ps1   командная строка

    Всё делается через Windows API напрямую, без сторонних утилит: состояние
    читается за ~90 мс, погашенный монитор сохраняет имя и идентификатор (иначе
    включить его было бы нечем), а раскладка пишется тем вызовом, который на
    этой машине действительно срабатывает.
#>

$script:ToolRoot     = $PSScriptRoot
# Путь к журналу перенаправляется переменной окружения — ради тестов: первые
# строки (компиляция типов, поворот журнала) пишутся уже при загрузке этого
# файла, и подменить $script:LogFile после дот-сорса поздно. Журнал — главный
# инструмент разбора, чужих следов в нём быть не должно.
$script:LogFile      = $(if ($env:MMT_LOG_FILE) { $env:MMT_LOG_FILE } else { Join-Path $PSScriptRoot 'last-run.log' })
$script:SettingsFile = Join-Path $PSScriptRoot 'settings.json'
$script:LastModeFile = Join-Path $PSScriptRoot 'last-mode.json'
$script:ModeCacheFile = Join-Path $PSScriptRoot 'display-modes.json'

# Версия — то, с чего человек начинает баг-репорт: без неё «у меня не гаснет
# монитор» невозможно сопоставить ни с журналом, ни с коммитом. Строку собирает
# одна функция на всех: рассинхронизировать её между командной строкой и меню
# трея иначе вышло бы в первый же выпуск.
#
# Сюда же сборка Windows и версия PowerShell: почти все отказы в этом коде — это
# отказы конкретной пары «драйвер + сборка системы», и без них вопрос «а у тебя
# что?» задаётся отдельным письмом.
$script:Version = '1.0.0'

function Get-VersionLine {
    return 'ScreenDeck {0} - Windows {1}, PowerShell {2}' -f $script:Version,
           [System.Environment]::OSVersion.Version, $PSVersionTable.PSVersion
}

# Дата и время для журнала и для файлов — одни и те же на любой локали. И
# `-Format`, и ToString без указания культуры берут у текущей не только
# разделитель времени, но и КАЛЕНДАРЬ: на тайской локали 'yyyy' — это 2569-й год
# по буддийскому, на арабской бывает Хиджра. Журнал перестал бы читаться как
# ISO-дата, а ключи дневника — сравниваться строкой с прошлогодними.
function Format-DisplayStamp {
    param([datetime]$When = (Get-Date), [string]$Pattern = 'yyyy-MM-dd HH:mm:ss')
    return $When.ToString($Pattern, [cultureinfo]::InvariantCulture)
}

function Write-DisplayLog {
    param([string]$Message)
    try {
        # -ErrorAction Stop обязателен: отказ Add-Content (файл занят на запись,
        # только чтение, диск полон) — ошибка НЕтерминирующая, и catch ниже её без
        # этого не поймает. Молчание журнала не должно зависеть от того, стоит ли
        # у вызывающего $ErrorActionPreference = 'Stop'.
        Add-Content -Path $script:LogFile -Encoding UTF8 -ErrorAction Stop `
                    -Value ('{0}  {1}' -f (Format-DisplayStamp), $Message)
    }
    catch { }   # лог не должен ронять переключение мониторов
}

# Журнал растёт на строку с каждого переключения, старта и срабатывания сторожа;
# мегабайт — это примерно год, а история старше года не нужна.
#
# Проверка одна, при загрузке DisplayCore, а не на каждой записи: иначе Get-Item
# дёргался бы по нескольку раз за переключение впустую. Переименование, а не
# обрезание: файл может быть открыт живым процессом, и резать его под ним нельзя.
# Прошлый .old перезаписывается — двух поколений достаточно.
function Limit-DisplayLog {
    param([int]$MaxBytes = 1MB)

    try {
        if (-not (Test-Path $script:LogFile)) { return }
        if ((Get-Item $script:LogFile).Length -lt $MaxBytes) { return }

        $old = $script:LogFile + '.old'
        # -ErrorAction Stop по той же причине, что и в Write-DisplayLog: без него
        # «файл занят другим процессом» уезжает в поток ошибок, и status.cmd
        # печатает красную простыню из-за уборки в журнале.
        Move-Item -LiteralPath $script:LogFile -Destination $old -Force -ErrorAction Stop
        # Первая строка нового файла объясняет, куда девалось прошлое.
        Write-DisplayLog 'core: log rotated, the previous one is last-run.log.old'
    }
    catch {
        # Не смогли — не беда: пишем дальше в тот же файл. Ронять инструмент
        # из-за уборки в журнале нельзя.
    }
}

Limit-DisplayLog

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
        # Комбинации: имя -> произвольный набор мониторов. Наборы могут
        # пересекаться, и один монитор участвует в скольких угодно. Ключ режима —
        # combo:<имя>, заголовок — само имя, как введено.
        #   "combos": {
        #       "Movie night": { "displays": ["ULTRAFINE", "XG27AQDMGR"], "primary": "ULTRAFINE" }
        #   }
        # displays — куски названий, правила совпадения те же, что у layout.
        # primary — кому достанется панель задач в этом режиме; пустая строка или
        # отсутствие монитора на столе — работают общие правила (см.
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
        # Правила: «случилось это — стань таким». Проверяются по порядку, первое
        # подходящее выигрывает; пока правило «владеет» столом, остальные молчат
        # (см. Get-RuleDecision).
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
        #   onPlug    монитор появился: ключ режима, в который уйти, и только
        #             если появившийся монитор в этот режим входит. Пусто —
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
        # Пустой словарь = выключено. Правится руками:
        #   "audio": { "solo:XG27AQDMGR": "ROG", "combo:Work": "ULTRAFINE" }
        audio           = [ordered]@{}
        # Автозагрузки здесь нет намеренно: правда о ней живёт в наличии ярлыка
        # (см. Test-RunAtStartup), а две копии одного факта могут разойтись.
    }
}

# Разбор одного значения из settings.json — каждой формы по функции. Все они
# чистые, поэтому под тестами, и все терпят мусор: файл правят руками, и «не
# разобралось» должно означать «настройки нет», а не падение приложения.

# Комбинация. Три формы записи: полная ({ displays, primary }) — её пишет окно
# настроек; краткая (массив названий) и совсем краткая (одно название строкой) —
# для правки рукой. Внутри всегда полная.
function ConvertTo-ComboSetting {
    param($Value)

    $displays = @()
    $primary = ''
    if ($Value -is [array])      { $displays = @($Value | ForEach-Object { [string]$_ }) }
    elseif ($Value -is [string]) { $displays = @([string]$Value) }
    elseif ($Value) {
        if ($null -ne $Value.displays) { $displays = @($Value.displays | ForEach-Object { [string]$_ }) }
        if ($null -ne $Value.primary)  { $primary = [string]$Value.primary }
    }
    return [ordered]@{
        displays = @($displays | Where-Object { $_ })
        primary  = $primary
    }
}

# Команда вокруг переключения. Строкой пишут то, что нужно чаще: команду ПОСЛЕ.
# $null означает «записи нет» — пустую пару в настройках держать незачем.
function ConvertTo-HookSetting {
    param($Value)

    $before = ''
    $after = ''
    if ($Value -is [string]) { $after = [string]$Value }
    elseif ($Value) {
        if ($null -ne $Value.before) { $before = [string]$Value.before }
        if ($null -ne $Value.after)  { $after  = [string]$Value.after }
    }
    if (-not $before -and -not $after) { return $null }
    return [ordered]@{ before = $before; after = $after }
}

# Яркость или контраст режима: число — всем мониторам набора поровну, объект —
# каждому своё. $null означает «записи нет».
function ConvertTo-LevelSetting {
    param($Value)

    if ($Value -is [string] -or $Value -is [int] -or $Value -is [double] -or $Value -is [long]) {
        return [int]$Value
    }
    if (-not $Value) { return $null }

    $perDisplay = [ordered]@{}
    foreach ($p in $Value.PSObject.Properties) {
        if ($p.Name) { $perDisplay[$p.Name] = [int]$p.Value }
    }
    if ($perDisplay.Count -eq 0) { return $null }
    return $perDisplay
}

# Правила, приведённые к одной форме. Именно здесь, на чтении: дальше их читает
# таймер трея каждые 15 секунд, и разбираться с полем, которого в файле может не
# быть, там уже нельзя.
function ConvertTo-RuleSettings {
    param($Value)

    return @(foreach ($r in @($Value)) {
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

# Копию испорченного файла надо сохранить: дальше приложение видит пустой список
# клавиш, считает это первым запуском и записывает поверх значения по умолчанию.
# Без копии привязки исчезали бы совсем.
function Save-DamagedSettingsCopy {
    param([string]$Reason)

    Write-DisplayLog "settings: file is damaged, falling back to defaults - $Reason"
    try {
        Copy-Item $script:SettingsFile ($script:SettingsFile + '.bad') -Force
        Write-DisplayLog 'settings: kept a copy of the damaged file as settings.json.bad'
    }
    catch { }   # не смогли сохранить копию — настройки всё равно поднимаем
}

# Содержимое settings.json, разобранное из JSON, или $null — файла нет либо он
# испорчен.
function Read-SettingsFile {
    if (-not (Test-Path $script:SettingsFile)) { return $null }
    try {
        return (Get-Content $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        Save-DamagedSettingsCopy -Reason $_.Exception.Message
        return $null
    }
}

# Настройки: значения по умолчанию, поверх них — то, что нашлось в файле.
#
# Поле за полем, а не присваиванием объекта целиком: в файле может лежать половина
# ключей (его правят руками), и остальные обязаны остаться дефолтными, а не
# превратиться в $null.
function Get-DisplaySettings {
    $s = Get-DefaultSettings
    $raw = Read-SettingsFile
    if (-not $raw) { return $s }

    # Разбор целиком под try, а не только чтение JSON: файл правят руками, и
    # правильный JSON легко несёт бессмысленное значение («brightness»: «high»,
    # «minutes»: «twenty»). Приведение типа на таком — ошибка ТЕРМИНИРУЮЩАЯ, и
    # без этого catch она уходит наружу: обе точки входа стоят с
    # $ErrorActionPreference = 'Stop' и зовут Get-DisplaySettings на старте, то
    # есть трей не поднимался бы вовсе. Испорченное значение — тот же «файл
    # испорчен», что и испорченный JSON, и ответ на него тот же. Уже разобранное
    # остаётся: половина настроек лучше, чем ни одной.
    try {
        if ($null -ne $raw.maximizeRefresh) { $s.maximizeRefresh = [bool]$raw.maximizeRefresh }
        if ($null -ne $raw.notifications)   { $s.notifications   = [bool]$raw.notifications }
        if ($null -ne $raw.restoreWindows)  { $s.restoreWindows  = [bool]$raw.restoreWindows }
        if ($null -ne $raw.restoreLastMode) { $s.restoreLastMode = [bool]$raw.restoreLastMode }
        if ($null -ne $raw.stats)           { $s.stats           = [bool]$raw.stats }
        if ($null -ne $raw.layout)          { $s.layout          = @($raw.layout | ForEach-Object { [string]$_ }) }
        if ($null -ne $raw.primary)         { $s.primary         = [string]$raw.primary }

        foreach ($field in 'hotkeys', 'audio') {
            if (-not $raw.$field) { continue }
            foreach ($p in $raw.$field.PSObject.Properties) { $s.$field[$p.Name] = [string]$p.Value }
        }

        if ($raw.combos) {
            foreach ($p in $raw.combos.PSObject.Properties) {
                if ($p.Name) { $s.combos[$p.Name] = ConvertTo-ComboSetting $p.Value }
            }
        }

        if ($raw.hooks) {
            foreach ($p in $raw.hooks.PSObject.Properties) {
                if (-not $p.Name) { continue }
                $hook = ConvertTo-HookSetting $p.Value
                if ($hook) { $s.hooks[$p.Name] = $hook }
            }
        }

        foreach ($field in 'brightness', 'contrast') {
            if (-not $raw.$field) { continue }
            foreach ($p in $raw.$field.PSObject.Properties) {
                if (-not $p.Name) { continue }
                $level = ConvertTo-LevelSetting $p.Value
                if ($null -ne $level) { $s.$field[$p.Name] = $level }
            }
        }

        # @() на месте вызова обязательна: функция, вернувшая массив из одного элемента,
        # отдаёт его скаляром, и $s.rules[0] перестал бы существовать.
        if ($raw.rules) { $s.rules = @(ConvertTo-RuleSettings $raw.rules) }

        if ($raw.reapply) {
            if ($null -ne $raw.reapply.onResume) { $s.reapply.onResume = [bool]$raw.reapply.onResume }
            if ($null -ne $raw.reapply.onUnplug) { $s.reapply.onUnplug = [bool]$raw.reapply.onUnplug }
            if ($null -ne $raw.reapply.onPlug)   { $s.reapply.onPlug   = [string]$raw.reapply.onPlug }
        }
    }
    catch {
        Save-DamagedSettingsCopy -Reason $_.Exception.Message
    }

    return $s
}

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
# Пишем то, что монитор ОТДАЛ, а не то, что просили: это заодно защита от
# невозможных режимов. Монитор, отказавшийся от 2560x1440@240 и оставшийся на
# 144, запишет в файл именно 144 — и следующее переключение попросит сразу их.
#
# Частота хранится ДРОБЬЮ (num/den), а не только целыми герцами, и это не
# педантизм. CCD принимает лишь точное значение: на этой машине 144 Гц — это
# 143999/1000, а 60 Гц — 59997/1000. Запрос «144/1» система отвергает целиком, и
# переключение теряет подсказку о частоте. Целые герцы остаются рядом — по ним
# видно, к какому режиму дробь относится, и их читает человек.
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

    return [pscustomobject]@{ Modifiers = $mods; Vk = $vk; Text = (Format-HotkeyString -Modifiers $mods -Vk $vk) }
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

# --- тема оформления --------------------------------------------------------
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
    catch { }   # ключа нет или он другой формы — ниже запасной путь

    try {
        $abgr = [uint32]((Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' `
                                           -Name 'AccentColor' -ErrorAction Stop).AccentColor)
        return ('#{0:X2}{1:X2}{2:X2}' -f ($abgr -band 0xFF), (($abgr -shr 8) -band 0xFF), (($abgr -shr 16) -band 0xFF))
    }
    catch { }   # и этого ключа нет — остаётся синий из коробки

    return $(if ($ForDarkTheme) { '#4CC2FF' } else { '#0067C0' })
}

# --- Windows API ------------------------------------------------------------
# Все классы живут в ОДНОМ исходнике и компилируются одним вызовом: каждый
# Add-Type -TypeDefinition — это отдельная компиляция, и четыре таких стоили
# треть секунды на каждый запуск CLI и на каждый старт трея.

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

    public const int CURRENT_SETTINGS = -1;

    public const int DM_BITSPERPEL = 0x00040000;
    public const int DM_PELSWIDTH = 0x00080000;
    public const int DM_PELSHEIGHT = 0x00100000;
    public const int DM_DISPLAYFREQUENCY = 0x00400000;

    public const int CDS_UPDATEREGISTRY = 0x00000001;
    public const int PRIMARY_DEVICE = 0x00000004;
}

// --- CCD: современный API конфигурации дисплеев ---------------------------
// Почему состояние читается им, а не старым API:
//
// 1. Скорость. QueryDisplayConfig отвечает за ~1 мс, а состояние спрашивают на
//    каждом переключении, на каждом открытии меню и на каждом срабатывании
//    сторожа.
// 2. Выключенный монитор. CCD перечисляет и неактивные цели, сохраняя им имя и
//    путь устройства, — иначе включить погашенный монитор было бы нечем.
// 3. Родное разрешение. GET_TARGET_PREFERRED_MODE отдаёт preferred timing из
//    EDID силами системы — и для выключенного монитора тоже. Разбирать EDID из
//    реестра вручную не нужно.
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

    // Признаки окна, которого на столе нет. Те же самые, что уже отсеивает
    // NativeWindows.Enumerate() для снимков позиций окон: правило одно, а знали
    // о нём в одном месте из двух.
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out int value, int size);

    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int DWMWA_CLOAKED = 14;

    // DWM «прячет» окно, не закрывая его: IsWindowVisible всё ещё говорит «да», а
    // на экране его нет. Именно так выглядит TextInputHost — системное окно ввода
    // размером ровно в монитор.
    public static bool IsCloaked(IntPtr hWnd) {
        int cloaked = 0;
        try { if (DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, out cloaked, sizeof(int)) == 0) return cloaked != 0; }
        catch { }   // атрибута нет на старых сборках — считаем окно видимым
        return false;
    }

    // Без кнопки на панели задач и без Alt-Tab. Игра такого себе не ставит, а
    // накладки вроде NVIDIA Overlay — ставят.
    public static bool IsToolWindow(IntPtr hWnd) {
        return (GetWindowLong(hWnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0;
    }
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

    // Сколько ждать подтверждения от монитора, который только что включили.
    // Полторы секунды в худшем случае и ни одной лишней паузы в обычном (см.
    // цикл подтверждения в Set). Пробуждение по DDC мерится сотнями
    // миллисекунд: 120 мс хватает тому, кто уже работал, и не хватает тому, кто
    // проснулся в этом же переключении.
    private const int ConfirmPasses = 6;
    private const int ConfirmPauseMs = 250;

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
        // Ответил ли монитор на перечитку вообще, и что именно ответил. Без этого
        // «не подтвердил» сливает два разных случая в один: монитор молчит (ещё
        // просыпается) и монитор отвечает чужим числом (отказ, DDC/CI выключен в
        // его меню). Советовать в первом случае «проверьте меню» — вранье.
        public bool BrightnessRead, ContrastRead;
        public int BrightnessActual = -1, ContrastActual = -1;
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

            // Подтверждение — НЕСКОЛЬКО подходов с паузой, а не один вопрос.
            // Монитор, который только что включили переключением набора, на
            // первый вопрос молчит: 21 августа ULTRAFINE взял яркость 60
            // (перечитка через секунду это показала), но подтвердить сразу после
            // пробуждения не успел — и журнал написал «did not take» про
            // значение, которое монитор принял. Обвинить монитор зря дороже, чем
            // подождать. Платят за это только те, кто ещё не ответил: подходы
            // прекращаются, как только подтвердились все (обычный случай — с
            // первого раза, без единой лишней паузы).
            for (int pass = 0; pass < ConfirmPasses; pass++) {
                bool waiting = false;
                for (int j = 0; j < open.Count; j++) {
                    if (slot[j] < 0) { continue; }
                    Applied a = result[slot[j]];
                    IntPtr handle = open[j].Value.handle;

                    if (a.BrightnessAsked && !a.BrightnessConfirmed) {
                        uint min = 0, cur = 0, max = 0;
                        // Один вопрос, без WithRetry: повтор здесь и есть внешний
                        // цикл, и его пауза длиннее — молчание после пробуждения
                        // мерится сотнями миллисекунд, а не десятками.
                        if (GetMonitorBrightness(handle, out min, out cur, out max)) {
                            a.BrightnessRead = true;
                            a.BrightnessActual = (int)cur;
                            a.BrightnessConfirmed = ((int)cur == brightness[slot[j]]);
                        }
                        else { LastError = Marshal.GetLastWin32Error(); }
                        if (!a.BrightnessConfirmed) { waiting = true; }
                    }
                    if (a.ContrastAsked && !a.ContrastConfirmed) {
                        uint min = 0, cur = 0, max = 0;
                        if (GetMonitorContrast(handle, out min, out cur, out max)) {
                            a.ContrastRead = true;
                            a.ContrastActual = (int)cur;
                            a.ContrastConfirmed = ((int)cur == contrast[slot[j]]);
                        }
                        else { LastError = Marshal.GetLastWin32Error(); }
                        if (!a.ContrastConfirmed) { waiting = true; }
                    }
                }
                if (!waiting) { break; }
                if (pass + 1 < ConfirmPasses) { System.Threading.Thread.Sleep(ConfirmPauseMs); }
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
        catch { }   // атрибута нет на старых сборках — считаем окно видимым
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
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(POINT point, uint flags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int dpiType,
                                               out uint dpiX, out uint dpiY);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr window, IntPtr dc);

    [DllImport("gdi32.dll")]
    private static extern int GetDeviceCaps(IntPtr dc, int index);

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4
    public static readonly IntPtr PER_MONITOR_AWARE_V2 = new IntPtr(-4);

    private const uint MONITOR_DEFAULTTONEAREST = 2;
    private const int MDT_EFFECTIVE_DPI = 0;
    private const int LOGPIXELSY = 90;

    public static int GetDpiAtCursor() {
        // У меню ещё нет надёжно размещённого HWND, поэтому GetDpiForWindow здесь
        // не годится. GetDpiForMonitor формально не DPI-aware, но для процесса с
        // per-monitor awareness возвращает фактический DPI выбранного монитора;
        // именно процесс, а не случайное окно под курсором, задаёт этот контракт.
        try {
            POINT point;
            if (GetCursorPos(out point)) {
                IntPtr monitor = MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
                uint dpiX, dpiY;
                if (monitor != IntPtr.Zero &&
                    GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, out dpiX, out dpiY) == 0 &&
                    dpiY > 0) return (int)dpiY;
            }
        }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }

        // На Windows без shcore процесс откатывается на system-aware. Там DC
        // рабочего стола знает системный DPI; в PMv2 он даст 96, но сюда мы
        // попадаем лишь после отказа точного запроса, и 96 сохраняет прежний вид.
        IntPtr dc = GetDC(IntPtr.Zero);
        if (dc != IntPtr.Zero) {
            try {
                int dpi = GetDeviceCaps(dc, LOGPIXELSY);
                if (dpi > 0) return dpi;
            }
            finally { ReleaseDC(IntPtr.Zero, dc); }
        }
        return 96;
    }
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
    private readonly float _scale;

    public ModernMenuRenderer(bool dark, Color accent) : this(dark, accent, 1f) { }

    public ModernMenuRenderer(bool dark, Color accent, float scale) {
        _accent = accent;
        _scale = scale < 1f ? 1f : scale;
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

    private int S(int value) {
        return (int)Math.Round(value * _scale, MidpointRounding.AwayFromZero);
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
        // прямые — на Windows 11 их срежет DWM вместе с углами самого окна. Один
        // физический пиксель оставлен намеренно: системные меню держат hairline
        // при любом DPI, чтобы контур не становился тяжелее содержимого.
        var r = new Rectangle(0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
        using (var p = new Pen(_line)) e.Graphics.DrawRectangle(p, r);
    }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        var g = e.Graphics;
        var r = new Rectangle(S(3), S(1), e.Item.Width - S(6), e.Item.Height - S(2));
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Rounded(r, S(4)))
        using (var b = new SolidBrush(_hover)) g.FillPath(b, path);
        g.SmoothingMode = old;
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        if (e.Vertical) { base.OnRenderSeparator(e); return; }
        int y = e.Item.Height / 2;
        // Как и рамка, сама линия остаётся hairline; растёт только её отступ.
        using (var p = new Pen(_line)) e.Graphics.DrawLine(p, S(10), y, e.Item.Width - S(10), y);
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
        using (var p = new Pen(_accent, 1.8f * _scale)) {
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
# не должен ронять инструмент: тогда просто компилируем в память и пишем причину
# в журнал.
# «Файл заблокирован политикой целостности кода» — то, чем Windows отвечает на
# попытку загрузить неподписанную сборку, когда включён Smart App Control (или
# действует политика WDAC). Сверяем ЧИСЛО, а не текст: сообщение приходит на языке
# системы, и на русской Windows проверка по словам молча перестала бы работать.
$script:BlockedByPolicyHResult = 0x800711C7

function Test-BlockedByPolicy {
    param($ErrorRecord)

    $e = $ErrorRecord.Exception
    while ($e) {
        if ($e.HResult -eq $script:BlockedByPolicyHResult) { return $true }
        $e = $e.InnerException
    }
    return $false
}

# Убрать сборки, которые больше не пригодятся: от прошлых версий исходника они
# только занимают место и путают.
#
# Сначала дешёвая проверка по маске: в чистой папке это один Test-Path, а не обход
# каталога на каждом старте. Занятые пропускаем молча — трей живёт неделями и
# держит свою сборку открытой, поэтому сразу после правки C# старый файл удалить
# нельзя; он уйдёт при следующем запуске, уже после перезапуска трея.
function Remove-StaleNativeAssemblies {
    param([string]$Keep = '')

    if (-not (Test-Path (Join-Path $script:ToolRoot 'native-*.dll'))) { return }
    foreach ($old in @(Get-ChildItem -Path $script:ToolRoot -Filter 'native-*.dll' -ErrorAction SilentlyContinue)) {
        if ($Keep -and $old.Name -eq $Keep) { continue }
        Remove-Item $old.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-NativeTypes {
    # Уже в этой сессии — выходим. Проверка по NativeDisplay покрывает все
    # четыре класса: они собираются вместе и появляются вместе.
    if ('NativeDisplay' -as [type]) { return }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # System.Drawing — ради ModernMenuRenderer: цвета, перья и кисти оттуда.
    $refs = @('System.Windows.Forms', 'System.Drawing')
    $how = 'compiled'
    $dll = ''

    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:NativeSource)) }
        finally { $sha.Dispose() }
        $hash = -join ($digest[0..3] | ForEach-Object { $_.ToString('x2') })

        $name = "native-$hash.dll"
        $dll = Join-Path $script:ToolRoot $name

        Remove-StaleNativeAssemblies -Keep $name

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
        # Отказ политики целостности кода — отдельный случай, и лечится он
        # удалением файла. Проверено на живой машине: Smart App Control отказал
        # неподписанной сборке, а ту же сборку, пересозданную заново, пустил —
        # решение принимается по репутации файла, а не только по содержимому.
        # Значит держать отвергнутый файл нельзя: он гарантирует такой же отказ на
        # следующем старте, и каждый отказ — это ещё две записи в журнале
        # CodeIntegrity. Без него следующий старт соберёт сборку заново и получит
        # новый шанс; ничего не сломается и в худшем случае — компиляция в память.
        if (Test-BlockedByPolicy $_) {
            Write-DisplayLog 'core: the code integrity policy refused our cached assembly - dropping it, the next start will rebuild'
            if ($dll) { Remove-Item -LiteralPath $dll -Force -ErrorAction SilentlyContinue }
        }
        else {
            # Всё остальное — папка только для чтения, занятый файл, гонка двух
            # процессов — пишем как есть.
            Write-DisplayLog "core: dll cache failed - $($_.Exception.Message)"
        }

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
    catch { }   # не вышло и так — остаёмся с масштабированием от системы

    # Уже осведомлён (например задано в манифесте или через переменную окружения) —
    # оба вызова вернут false, и это нормально. Молчим, чтобы не пугать журнал.
}

Initialize-DpiAwareness

function Get-UiScale {
    param([int]$Dpi = 0)

    # Ноль означает живой запрос для монитора под курсором. Явное значение —
    # детерминированный шов тестов: они не должны зависеть от настоящего стола.
    if ($Dpi -le 0) {
        try { $Dpi = [NativeDpi]::GetDpiAtCursor() }
        catch { $Dpi = 96 }
    }
    return [Math]::Max([double]1.0, ([double]$Dpi / 96.0))
}

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
# остальные гаснут. Одним вызовом, а не тремя шагами «включить нужные, унести
# панель задач, погасить лишние»: система сама переносит роль основного внутри
# перехода, и на столе не возникает промежуточного состояния с лишними экранами.
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
# Зачем. Дорога из трёх перестроений (набор экранов, потом позиции, потом
# частота) обходится в три заморозки DWM и ввода: курсор замирает и «выстреливает»
# вперёд, экраны моргают трижды, всем окнам трижды приходит WM_DISPLAYCHANGE, и
# всё это стоит секунд. CCD умеет задать те же три вещи одной структурой — тогда
# система перестраивает стол один раз.
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
    # ULTRAGEAR по HDMI такого режима просто нет.
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


# --- раскладка и основной монитор -------------------------------------------
# Расставить мониторы и назначить основной — одним вызовом CCD. Две вещи делаются
# вместе, потому что в Windows это одно и то же: «основной» — не флаг, а
# положение, им становится монитор, чей левый верхний угол лежит в (0,0). Поэтому
# раскладка сначала строится слева направо, а потом вся целиком сдвигается так,
# чтобы будущий основной попал в начало координат.
#
# Порядок берётся из настроек (ключ layout) — список названий слева направо.
# Монитор, которого в списке нет, уезжает в конец. Если список пуст, текущие
# координаты сохраняются как есть и двигается только основной.
#
# Почему не старым API: ChangeDisplaySettingsEx с CDS_UPDATEREGISTRY отдаёт -1 на
# всех трёх мониторах сразу. Запись раскладки старым путём на этой машине просто
# не работает.
#
# SDC_ALLOW_CHANGES намеренно НЕ ставим: без него система обязана применить ровно
# те координаты, что переданы, или отказать. С ним она вправе подобрать что-то
# своё, и мониторы опять разъехались бы.

# Ok + Changed, а не «да/нет»: Changed нужен вызывающему, чтобы не писать в журнал
# «arranged left to right» там, где ничего не расставлялось — строка о работе,
# которой не было, заставляет искать дефект не там.
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

    # До трёх попыток, каждая — со свежим QueryDisplayConfig. Через секунду после
    # смены топологии валидация возвращает 87 (ERROR_INVALID_PARAMETER): снимок,
    # снятый в переходном состоянии, система сама же отказывается принять, а тот
    # же вызов чуть позже проходит с первого раза за полсекунды. Без повтора стол
    # оставался бы стоять так, как его расставила Windows — с перепутанными
    # мониторами. Отказ моментный — значит лечится повтором, но повторять надо
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
# соседним.
#
# Ждём по условию, а не по таймеру: фиксированная пауза либо слишком коротка
# (прочитаем «ещё активен» у гаснущего монитора), либо тратится впустую. Полного
# Get-DisplayState здесь не надо — Get-CcdTargets отдаёт и активность, и имена, и
# стоит ~10 мс против ~90.
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


# Родное разрешение берём у системы: GET_TARGET_PREFERRED_MODE в Get-CcdTargets
# отдаёт preferred timing из EDID, причём и для выключенного монитора, — разбирать
# реестр вручную не нужно. Спрашивать драйвер бесполезно: для
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


# Смена разрешения и частоты у одного монитора. ChangeDisplaySettingsEx отдаёт
# код возврата, поэтому промах виден сразу и попытку можно повторить.
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
    # перебирает EnumDisplaySettings по всем режимам монитора, и сразу после смены
    # топологии драйвер отдаёт их на порядок медленнее, чем в покое: секунды против
    # 60 мс, причём на мониторах, которым ничего менять не требовалось.
    #
    # Состояние на входе в переключение уже содержит BestMode каждого включённого
    # монитора (его посчитал Get-DisplayState), а самый большой режим от смены
    # набора экранов не меняется: родное разрешение берётся из EDID, а список
    # частот — свойство панели, не раскладки. Пересчёт остаётся только тому, кто
    # прямо сейчас проснулся: его BestMode неизвестен.
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
        # монитор ещё перестраивается, и вот их стоит повторить.
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
# названии.
function Test-DisplayNameMatch {
    param([string]$Pattern, [string]$Label, [string]$ShortId)

    if (-not $Pattern) { return $false }
    foreach ($name in $Label, $ShortId) {
        if (-not $name) { continue }
        if ($name -like ('*' + $Pattern + '*') -or $Pattern -like ('*' + $name + '*')) { return $true }
    }
    return $false
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

# Состояние всех мониторов — из CCD (см. комментарий у класса NativeCcd).
#
# Id — путь устройства из CCD. Он есть и у выключенного монитора, поэтому по нему
# можно и опознать монитор, и снова его включить.
#
# Настройки здесь не нужны и не читаются: состояние — это то, что говорит о столе
# Windows, а не то, что человек про него написал. Состав комбинаций разбирает
# Get-DisplayModes, ему настройки и передают.
function Get-DisplayState {
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
    # эта строка ходила бы к системе заново прямо внутри обработчика открытия
    # меню — ради этого и заведён кэш состояния.
    if ($null -eq $State) { $State = @(Get-DisplayState) }
    $modes = @()

    # Ключ соло-режима — по названию монитора, а не по короткому Monitor ID.
    # Короткий ID стабилен только для пары «монитор + вход»: у монитора на DP и
    # на HDMI разные EDID, и код в них разный. После перекладки кабелей
    # ULTRAGEAR стал GSM5BB4 -> GSM5BB3, ULTRAFINE GSM5CBB -> GSM5CBC, и
    # привязки Ctrl+Alt+F1/F2 указывали в пустоту. Название входу не меняется.
    # Две одинаковые модели различаем коротким ID, а если и он совпал (одинаковые
    # мониторы на одинаковых входах — короткий ID это модель, а не экземпляр), то
    # порядковым номером: без третьей ступени пара близнецов получала бы ОДИН ключ
    # на два соло-режима, и «включить только этот» зажигало оба.
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
        '^combo:(.+)$' { return $Matches[1] }
        '^all$'        { return 'All displays' }
        default        { return $Key }
    }
}

# Перенос привязок со старых ключей на новые. Соло-режим, записанный коротким
# Monitor ID, теряет ключ при переходе монитора на другой вход. Если
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

        # Название монитора тоже может смениться — например с полного «ROG STRIX
        # XG27AQDMGR» на короткое «XG27AQDMGR». Одно содержится в другом, и этого
        # достаточно, чтобы узнать монитор и перевезти привязку.
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

# Имя монитора по пути устройства — для журнала.
#
# Заведено ради строк «plug:»: без имён в журнале видно, какая ветка сработала,
# но не видно, кто её вызвал, и разбор упирается в догадки.
#
# Две дороги, и вторая обязательна. Уснувший монитор в состоянии обычно ещё есть,
# помеченный Disconnected. Но когда драйвер убирает его с шины совсем — а именно
# так и выглядит «монитор погас сам», Windows пишет про это «surprise removed as
# it is reported as missing on the bus» — его нет и в перечислении. Спрашивать
# имя у состояния в этот момент уже поздно, поэтому $Known — то, что видели
# раньше: путь -> имя. Без него строка про пропажу называла бы «a display» ровно
# в том случае, ради которого её и писали.
function Get-DisplayLabelById {
    param([string]$Id, $State, $Known = $null)

    $one = @($State | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if ($one -and $one.Label) { return [string]$one.Label }
    if ($Known -and $Known.Contains($Id) -and $Known[$Id]) { return [string]$Known[$Id] }
    return 'a display'
}

# Весь стол одной строкой — для журнала, на каждое изменение конфигурации.
#
# 28 августа журнал говорил «a display went away» и не говорил, КАКОЙ, а про
# остальных не говорил ничего. Разбор ушёл на то, чтобы вывести это косвенно — по
# тому, какая ветка сработала. Эта строка отвечает сразу и целиком.
#
# Три состояния, и они не об одном и том же:
#   gone — монитора нет на шине: уснул своей кнопкой, выдернули кабель, или
#          драйвер убрал его как «missing on the bus»;
#   off  — подключён, но картинки не показывает (так его выключаем мы);
#   on   — показывает, и в каком режиме.
function Format-DeskSnapshot {
    param($State)

    $parts = @()
    foreach ($m in @($State)) {
        $label = [string]$m.Label
        if ($m.Disconnected)  { $parts += ('{0} gone' -f $label); continue }
        if (-not $m.Active)   { $parts += ('{0} off' -f $label); continue }
        $parts += ('{0} on {1}x{2}@{3}' -f $label, [int]$m.Width, [int]$m.Height, [int]$m.Hz)
    }
    if ($parts.Count -eq 0) { return 'nothing at all' }
    return ($parts -join ', ')
}

# Стоит ли на столе уже ровно этот набор экранов. Сравниваем НАБОРЫ, а не ключи
# режимов: пока один монитор не воткнут, «все» и «рабочие» — это один и тот же
# стол, и сравнение ключей объявило бы переключением то, чего не происходит.
# Отсюда же трей узнаёт, что чинить придётся разве что раскладку и всплывашка не
# нужна. Одно определение «стол равен режиму» на всё приложение: два разошлись бы.
function Test-DeskMatchesMode {
    param($Mode, $State)

    $wanted = @(Get-ModeMembers -Mode $Mode -State $State | ForEach-Object { $_.Id } | Sort-Object)
    $on = @($State | Where-Object { $_.Active } | ForEach-Object { $_.Id } | Sort-Object)
    return ($wanted.Count -eq $on.Count -and -not (Compare-Object $wanted $on))
}

# Какой режим соответствует тому, что включено прямо сейчас. Нужно, чтобы в меню
# отметить галочкой текущее состояние.
function Get-ActiveModeKey {
    param($State, $Modes)

    # Погасший стол не равен никакому режиму, и проверить это надо ДО перебора:
    # у режима, ни один монитор которого не подключён, набор тоже пуст, и
    # сравнение наборов объявило бы его текущим.
    if (@($State | Where-Object { $_.Active }).Count -eq 0) { return $null }

    foreach ($mode in $Modes) {
        if (Test-DeskMatchesMode -Mode $mode -State $State) {
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
# туда же: если он виден только в журнале, трей рапортует зелёным «Displays
# switched», а перепутанные мониторы человек обнаруживает сам.
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

# Пофазная разбивка времени для журнала: 'state 0.3, apply 1.2'. Отвечает на
# вопрос «чья это секунда»: state и layout — наша работа, apply, settle и modes —
# в основном ожидание системы и мониторов. Фазы короче 0.05 с опускаются: нули
# только прятали бы значимое. Порядок — порядок словаря; секунды через
# InvariantCulture, по той же причине, что и в done:.
function Format-PhaseTimes {
    param($Phases)

    if (-not $Phases) { return '' }
    $parts = @()
    foreach ($name in @($Phases.Keys)) {
        $s = [double]$Phases[$name]
        if ($s -lt 0.05) { continue }
        $parts += ('{0} {1}' -f $name, $s.ToString('0.0', [cultureinfo]::InvariantCulture))
    }
    return ($parts -join ', ')
}

# Кто из включаемых мониторов станет основным (то есть где панель задач).
# Вынесено из Switch-DisplayMode чистой функцией: лестница из шести ступеней
# внутри переключателя была непроверяемой.
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

# Стоят ли все эти мониторы уже в своих максимальных режимах. Чистая функция:
# смотрит только на состояние, снятое на входе в переключение, и ни о чём не
# спрашивает систему.
function Test-ModesAlreadyBest {
    param($Wanted)

    foreach ($m in @($Wanted)) {
        if (-not $m.Active -or -not $m.Output -or -not $m.BestMode) { return $false }
        if ($m.Width -ne $m.BestMode.Width -or $m.Height -ne $m.BestMode.Height -or
            $m.Hz -ne $m.BestMode.Hz) { return $false }
    }
    return $true
}

# Довести режимы нужных мониторов и собрать по ним отчёт:
#   Summary       строки «LG ULTRAGEAR 2560x1440 @ 144 Hz» для сводки человеку;
#   Failed        имена тех, кто так и не прицепился;
#   Applied       путь устройства -> что монитор реально показывает;
#   LevelTargets  кому потом ставить яркость, с уже известным именем выхода —
#                 обход CCD стоит десятки миллисекунд, и второй раз за одно
#                 переключение он не нужен.
#
# Две дороги. Короткая (-AlreadyBest) — когда стол не двигался и все мониторы уже
# в максимальных режимах: сводка собирается из состояния, снятого на входе, и к
# системе не уходит ни один запрос. Экономия не косметическая: сразу после смены
# раскладки драйвер отвечает на запросы о режимах заметно медленнее, и повторное
# нажатие через секунду после переключения стоит вдвое дороже, чем в покое.
function Set-WantedModes {
    param(
        [Parameter(Mandatory)]$Wanted,
        [switch]$AlreadyBest,
        [switch]$KeepMode
    )

    $summary = @()
    $failed = @()
    $applied = @{}
    $levelTargets = @()

    if ($AlreadyBest) {
        foreach ($m in @($Wanted)) {
            $summary += '{0} {1}x{2} @ {3} Hz' -f $m.Label, $m.Width, $m.Height, $m.Hz
            $applied[[string]$m.Id] = [pscustomobject]@{ Width = $m.Width; Height = $m.Height; Hz = $m.Hz }
            $levelTargets += [pscustomobject]@{ Device = [string]$m.Output; Label = [string]$m.Label; ShortId = [string]$m.ShortId }
        }
        Write-DisplayLog 'switch: modes already correct'
    }
    else {
        # Режим выставляется последним, когда набор активных мониторов уже
        # окончательный: и назначение основного, и гашение соседа сбрасывают
        # частоту на то, что записано в реестре, а там она часто ниже родной.
        #
        # Имена выходов берём ОДНИМ перечислением на всех, а не по одному на
        # монитор: Get-CcdOutput внутри зовёт Get-CcdTargets (полный обход CCD с
        # запросом имён, ~50 мс), и на трёх мониторах это втрое дороже без всякой
        # причины. Кто уже на столе — найдётся здесь; кто ещё просыпается — уйдёт
        # в Get-CcdOutput и будет честно дождан.
        $outputs = @{}
        foreach ($t in @(Get-CcdTargets)) {
            if ($t.Active -and $t.Output) { $outputs[$t.DevicePath] = $t.Output }
        }

        foreach ($m in @($Wanted)) {
            $output = $outputs[$m.Id]
            if (-not $output) { $output = Get-CcdOutput -DevicePath $m.Id }
            if (-not $output) {
                # Молча пропустить нельзя: монитор исчез бы из сводки, и получился
                # бы рапорт об успехе при чёрном экране.
                Write-DisplayLog "warn: $($m.Label) did not attach within 8 s - mode was not applied"
                $failed += $m.Label
                continue
            }
            if (-not $KeepMode) {
                $nw = 0; $nh = 0
                if ($m.Native) { $nw = $m.Native.Width; $nh = $m.Native.Height }
                # $m.BestMode посчитан в Get-DisplayState на входе — для монитора,
                # который уже был включён, он готов, и перебор режимов (дорогой
                # сразу после смены топологии) не нужен. У только что
                # проснувшегося он $null, и Set-BestModeFor посчитает сам.
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

    return [pscustomobject]@{
        Summary = @($summary); Failed = @($failed)
        Applied = $applied;    LevelTargets = @($levelTargets)
    }
}

# Запомнить, что мониторы реально показали, в кэше проверенных режимов: следующее
# переключение сможет задать частоту сразу, не дожидаясь, пока спящий монитор
# проснётся и расскажет о себе.
#
# Точную дробь частоты берём у CCD: целых герцов для запроса режима не хватает
# (см. Get-ModeCache), а один обход активных путей стоит единицы миллисекунд.
function Save-AppliedModes {
    param($Applied)

    if (-not $Applied -or @($Applied.Keys).Count -eq 0) { return }

    $rates = Get-CcdActiveRates
    foreach ($k in @($Applied.Keys)) {
        $r = $rates[$k]
        $Applied[$k] | Add-Member -NotePropertyName RateNum -NotePropertyValue $(if ($r) { $r.Num } else { 0 }) -Force
        $Applied[$k] | Add-Member -NotePropertyName RateDen -NotePropertyValue $(if ($r) { $r.Den } else { 0 }) -Force
    }
    Save-ModeCache -Modes $Applied
}

# Хвост переключения: то, что делается ПОСЛЕ того, как стол собран, и потому не
# попадает в строку done: — позиции окон, звук, яркость и команда «после».
#
# Своя строка after: в журнале: done: означает «стол собран», а яркость по DDC
# доводится ещё секундами, и без этой строки её время выглядело бы дырой между
# done: и следующей записью. Строки нет вовсе, когда хвост незаметен.
#
# Порядок здесь осмысленный. Окна — после смены режима и назначения основного:
# и то, и другое двигает окна само, поэтому раньше их раскладывать бессмысленно.
# Звук и яркость — после того, как режим состоялся: незачем гонять устройства,
# если переключение провалилось. Команда «после» — в самом конце, она затем и
# нужна, чтобы застать готовое состояние.
function Invoke-SwitchTail {
    param(
        $Settings,
        [Parameter(Mandatory)][string]$ModeKey,
        # Топология действительно менялась И снимки окон включены. При повторном
        # нажатии хоткея окна не трогаем вообще.
        [bool]$RestoreWindows,
        [string[]]$WantedIds = @(),
        # Мониторы, которым можно ставить яркость: имя выхода уже известно, второй
        # обход CCD за одно переключение не нужен.
        $LevelTargets = @()
    )

    $tail = [ordered]@{}
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $note = {
        param([string]$Name)
        $tail[$Name] = [double]$tail[$Name] + $watch.Elapsed.TotalSeconds
        $watch.Restart()
    }

    if ($RestoreWindows) {
        try { Restore-WindowLayout -Key (Get-DisplayLayoutKey -DevicePaths $WantedIds) }
        catch { Write-DisplayLog "warn: windows - restoring failed: $($_.Exception.Message)" }
    }
    & $note 'windows'

    # Словарь пуст (по умолчанию) — не выполняется ни одна строка.
    if ($Settings.audio -and $Settings.audio.Contains($ModeKey)) {
        $want = [string]$Settings.audio[$ModeKey]
        if ($want) {
            try { [void](Set-DefaultAudioDevice -Match $want) }
            catch { Write-DisplayLog "warn: audio - failed: $($_.Exception.Message)" }
        }
    }
    & $note 'audio'

    # Только тем мониторам, что включены: спящий по DDC не отвечает. Словари пусты
    # (по умолчанию) — ни один запрос по медленной шине не уходит.
    $hasLevels = (($Settings.brightness -and $Settings.brightness.Contains($ModeKey)) -or
                  ($Settings.contrast -and $Settings.contrast.Contains($ModeKey)))
    if ($hasLevels -and @($LevelTargets).Count -gt 0) {
        $b = $(if ($Settings.brightness -and $Settings.brightness.Contains($ModeKey)) { $Settings.brightness[$ModeKey] } else { $null })
        $c = $(if ($Settings.contrast   -and $Settings.contrast.Contains($ModeKey))   { $Settings.contrast[$ModeKey] }   else { $null })
        try { [void](Set-MonitorLevels -Targets $LevelTargets -BrightnessSetting $b -ContrastSetting $c) }
        catch { Write-DisplayLog "warn: levels - failed: $($_.Exception.Message)" }
    }
    & $note 'levels'

    [void](Invoke-ModeHook -Settings $Settings -ModeKey $ModeKey -Phase 'after')
    & $note 'hook'

    $text = Format-PhaseTimes $tail
    if ($text) { Write-DisplayLog ("after: {0} s" -f $text) }
}

function Switch-DisplayMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModeKey,
        [string]$PrimaryMatch,
        [switch]$KeepMode,
        [switch]$DryRun,
        [switch]$Quiet,
        # Переключение затеяли мы сами, а не человек: сторож, правило, сборка
        # стола после сна или пропажи монитора. Отличается ровно одним — таким
        # переключением не перезаписывается выбранный режим (см. Save-LastMode
        # ниже).
        [switch]$Automatic
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

    # Второй секундомер — пофазный, для той же строки done:. Общая цифра говорит
    # «6 секунд», разбивка — ГДЕ они: в наших запросах или в ожидании монитора.
    # Скриптблок пишет в переданный словарь, потому что словарей два: фазы до
    # done: и хвост после него (см. $tail ниже).
    $phases = [ordered]@{}
    $phaseWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $notePhase = {
        param($Into, [string]$Name)
        $Into[$Name] = [double]$Into[$Name] + $phaseWatch.Elapsed.TotalSeconds
        $phaseWatch.Restart()
    }

    # Объявлены здесь, а не только там, где присваиваются: оба выставляются лишь
    # на ветке «топология менялась», а читаются ниже безусловно. PowerShell в
    # таком случае ищет переменную в области вызывающего — и однажды нашёл бы
    # чужую, после чего сводка соврала бы про «Still on:».
    $refused = @()
    $doWindows = $false

    try {
        Write-DisplayLog "--- start mode=$ModeKey primaryMatch='$PrimaryMatch' keepMode=$KeepMode dryRun=$DryRun"

        # Настройки читаем РОВНО один раз на переключение: иначе внутри одного
        # перехода можно взять разные версии файла, если его правят из окна
        # настроек прямо сейчас.
        $settings = Get-DisplaySettings

        # Настройки уже прочитаны — отдаём их режимам, чтобы они не шли на диск
        # сами.
        $monitors = @(Get-DisplayState)
        $modes = Get-DisplayModes -State $monitors -Settings $settings
        $mode = $modes | Where-Object { $_.Key -eq $ModeKey } | Select-Object -First 1
        if (-not $mode) {
            # Клавиша может быть назначена на монитор, который сейчас не воткнут —
            # это нормальная ситуация, а не поломка, и говорить надо по-человечески.
            if ($ModeKey -like 'solo:*') {
                throw "That display is not connected right now."
            }
            # Комбинацию могли удалить в настройках, а клавиша осталась.
            if ($ModeKey -like 'combo:*') {
                throw ("The combination '{0}' no longer exists in the settings." -f (Get-ModeTitleFromKey $ModeKey))
            }
            throw "Unknown mode '$ModeKey'."
        }

        $usable = @($monitors | Where-Object { -not $_.Disconnected })
        $wanted = @(Get-ModeMembers -Mode $mode -State $monitors)

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
        & $notePhase $phases 'state'

        if (-not $Quiet) {
            Write-Host "$($mode.Title):" -ForegroundColor Cyan
            foreach ($m in $wanted)    { Write-Host "  on       $($m.Output)  $($m.Label)" }
            Write-Host "  primary  $($primary.Output)  $($primary.Label)"
            foreach ($m in $toDisable) { Write-Host "  off      $($m.Output)  $($m.Label)" }
        }

        # Один переход вместо трёх шагов: набор задаётся целиком, а роль основного
        # система переносит внутри перехода сама.
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
            # Layout, primary и режимы ниже всё равно проверяются: это дёшево, а
            # пропустить их нельзя — набор мониторов может совпадать, а
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
                # процессов стоит десятки миллисекунд.
                $doWindows = ((Test-Path Function:\Save-WindowLayout) -and
                              ($null -eq $settings.restoreWindows -or $settings.restoreWindows))
                if ($doWindows) {
                    try { Save-WindowLayout -Key (Get-DisplayLayoutKey -DevicePaths $activeNow) }
                    catch { Write-DisplayLog "warn: windows - saving failed: $($_.Exception.Message)" }
                    & $notePhase $phases 'windows'
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
                & $notePhase $phases 'apply'

                # Проверяем результат, а не верим коду возврата: иначе отказ гасить
                # выглядит в журнале полным успехом.
                $settled = Wait-ForTopology -WantedPaths $wantedIds
                & $notePhase $phases 'settle'
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
            # Пишем «arranged» только когда действительно расставляли: иначе в
            # журнал уходит пара «already correct» + «arranged left to right», и
            # вторая строка отчитывается о работе, которой не было.
            if ($laid.Ok -and $laid.Changed) {
                Write-DisplayLog ("layout: arranged left to right - " + ($order -join ' | '))
                $layoutChanged = $true
            }
            elseif ($laid.Ok) {
                Write-DisplayLog 'layout: already correct'
            }
            else {
                # Причина уже в журнале — Set-CcdLayout пишет каждую попытку.
                # Здесь провал запоминается для сводки и вердикта: молчаливый успех
                # при перепутанных мониторах — худшее из возможных сообщений.
                $layoutFailed = $true
            }
        }
        & $notePhase $phases 'layout'

        # Третья и последняя проверка «уже сделано», после топологии и раскладки:
        # стол не двигался вообще И все нужные мониторы уже в максимальных режимах.
        $nothingMoved = ($sameTopology -eq $true) -and (-not $layoutChanged)
        $alreadyBest = ($nothingMoved -and -not $KeepMode -and (Test-ModesAlreadyBest $wanted))

        $step = Set-WantedModes -Wanted $wanted -AlreadyBest:$alreadyBest -KeepMode:$KeepMode
        & $notePhase $phases 'modes'

        $verdict = Format-SwitchResult -Summary $step.Summary -Failed $step.Failed `
                                       -Refused $refused -LayoutFailed $layoutFailed
        $text = $verdict.Text
        # Форматируем через InvariantCulture: журнал английский, а `-f` берёт
        # разделитель из текущей локали и на русской писал бы «4,2 s».
        $took = $watch.Elapsed.TotalSeconds.ToString('0.0', [cultureinfo]::InvariantCulture)
        $breakdown = Format-PhaseTimes $phases
        if ($breakdown) { $breakdown = ': ' + $breakdown }
        Write-DisplayLog ("done: {0} ({1} s{2})" -f $text, $took, $breakdown)

        # Запоминаем ВЫБОР, а не результат: даже если один монитор не поднялся,
        # человек просил именно этот режим, и после включения компьютера
        # возвращать надо его. Провал переключения сюда не доходит — он уходит
        # исключением выше.
        #
        # И только выбор человека. Автоматическое переключение выбором не
        # является, и 28 августа это стоило вечера: reapply по появлению монитора
        # записал combo:Work поверх выбранного solo:XG27AQDMGR, после чего и
        # onUnplug, и восстановление при старте вели уже в Work — то есть мимо
        # монитора, за которым человек сидел. Каждое пробуждение соседнего экрана
        # утверждало ловушку заново, и выйти из неё было нечем.
        if (-not $Automatic) { Save-LastMode -Key $ModeKey }

        # А здесь наоборот — только факт: что монитор показал, то и запомнили.
        Save-AppliedModes -Applied $step.Applied

        Invoke-SwitchTail -Settings $settings -ModeKey $ModeKey -RestoreWindows $doWindows `
                          -WantedIds $wantedIds -LevelTargets $step.LevelTargets

        return [pscustomobject]@{
            Mode = $ModeKey; Skipped = $false; Message = $text
            Refused = $refused; Failed = $step.Failed
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

# Окно, которого на столе нет: полного экрана оно не занимает, чем бы ни был его
# прямоугольник.
#
# Правило не новое — ровно это уже отсеивает NativeWindows.Enumerate(), когда
# снимает позиции окон. Test-FullscreenApp про него не знал, и на этом ловился
# TextInputHost: системное окно ввода размером РОВНО в монитор, видимое по
# IsWindowVisible и при этом закрытое DWM. Замерено 2026-08-26 — единственное
# окно на столе, проходившее проверку целиком; NVIDIA Overlay не дотягивал до неё
# один пиксель и прошёл бы завтра, но он tool-window.
#
# Пустой заголовок в признаки НЕ берём, хотя перебор окон его учитывает:
# безрамочная игра вполне может не иметь заголовка, и отсеять её было бы хуже
# ложного срабатывания.
#
# Функция чистая и потому проверяемая: у настоящей проверки все входы приходят от
# Windows, а [NativeForeground] — тип, а не функция, и подменить его в тесте нечем.
# Возвращает причину, по которой окно не в счёт, или пустую строку.
function Get-GhostWindowReason {
    param([bool]$Visible, [bool]$Cloaked, [bool]$Minimised, [bool]$ToolWindow)

    if (-not $Visible) { return 'the window is not visible' }
    if ($Cloaked) { return 'the window is cloaked by DWM' }
    if ($Minimised) { return 'the window is minimised' }
    if ($ToolWindow) { return 'the window is a tool window' }
    return ''
}

# Почему сторож решил, что идёт полный экран. Пишет Test-FullscreenApp при каждом
# вызове, читает тот, кто из-за этого отложил работу.
#
# Строка нужна потому, что «postponed» само по себе неразличимо: за ним стоят две
# совершенно разные проверки, и полторы сотни записей в журнале не отвечали, какая
# из них сработала и на чём. А ложные срабатывания там настоящие: TextInputHost
# (системное окно ввода) по размеру ровно равен монитору и проверку проходит, а
# NVIDIA Overlay не дотягивает до неё ОДИН пиксель — то есть завтра пройдёт и он.
# Пока не известно, какая ветвь виновата, правка логики была бы стрельбой наугад.
$script:FullscreenWhy = ''

# Имена значений QUERY_USER_NOTIFICATION_STATE — только для журнала: «2» в отчёте
# об ошибке не говорит ничего, «QUNS_BUSY» говорит всё.
$script:NotificationStateNames = @{
    1 = 'QUNS_NOT_PRESENT'; 2 = 'QUNS_BUSY'; 3 = 'QUNS_RUNNING_D3D_FULL_SCREEN'
    4 = 'QUNS_PRESENTATION_MODE'; 5 = 'QUNS_ACCEPTS_NOTIFICATIONS'
    6 = 'QUNS_QUIET_TIME'; 7 = 'QUNS_APP'
}

# Игра ставит себе режим сама, и трогать его в этот момент нельзя: смена режима
# извне роняет полноэкранное устройство D3D — картинка моргает, окно сворачивается.
# Ровно это и происходило при запуске Counter-Strike.
#
# Спрашиваем два раза. Сначала оболочку: SHQueryUserNotificationState — тот же
# источник, по которому Windows решает, показывать ли всплывашки. Он ловит
# честный полный экран, но не ловит безрамочное окно, поэтому вторым шагом
# смотрим, не закрывает ли активное окно свой монитор целиком.
function Test-FullscreenApp {
    $script:FullscreenWhy = ''
    try {
        $state = 0
        if ([NativeForeground]::SHQueryUserNotificationState([ref]$state) -eq 0) {
            # 2 — полноэкранное окно, 3 — D3D во весь экран, 4 — режим презентации,
            # 7 — приложение Store во весь экран. 5 и 6 нам не мешают.
            if ($state -eq 2 -or $state -eq 3 -or $state -eq 4 -or $state -eq 7) {
                $name = $script:NotificationStateNames[[int]$state]
                if (-not $name) { $name = 'unknown' }
                $script:FullscreenWhy = 'the shell says {0} ({1})' -f $state, $name
                return $true
            }
        }
    }
    catch { }   # система не ответила — считаем, что полного экрана нет

    try {
        $hwnd = [NativeForeground]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $false }

        # Рабочий стол и панель задач тоже во весь экран — они не в счёт.
        $cls = New-Object System.Text.StringBuilder 256
        [void][NativeForeground]::GetClassName($hwnd, $cls, 256)
        if (@('Progman', 'WorkerW', 'Shell_TrayWnd') -contains $cls.ToString()) { return $false }

        # Призрака отсеиваем ДО геометрии: она у него бывает какая угодно, вплоть
        # до точного размера монитора.
        $ghost = Get-GhostWindowReason -Visible ([NativeForeground]::IsWindowVisible($hwnd)) `
                                       -Cloaked ([NativeForeground]::IsCloaked($hwnd)) `
                                       -Minimised ([NativeForeground]::IsIconic($hwnd)) `
                                       -ToolWindow ([NativeForeground]::IsToolWindow($hwnd))
        if ($ghost) { return $false }

        $rect = New-Object NativeForeground+RECT
        if (-not [NativeForeground]::GetWindowRect($hwnd, [ref]$rect)) { return $false }

        $mon = [NativeForeground]::MonitorFromWindow($hwnd, [NativeForeground]::MONITOR_DEFAULTTONEAREST)
        $mi = New-Object NativeForeground+MONITORINFO
        $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
        if (-not [NativeForeground]::GetMonitorInfo($mon, [ref]$mi)) { return $false }

        # Задумано так: развёрнутое окно закрывает рабочую область, но не панель
        # задач, поэтому сюда попадает только по-настоящему безрамочный полный
        # экран. Запас на деле в считаные пиксели, поэтому в журнал уходят ОБА
        # прямоугольника и класс окна: по ним видно, это настоящая игра или
        # очередное окно, дотянувшееся до края монитора.
        $covers = ($rect.Left -le $mi.rcMonitor.Left -and $rect.Top -le $mi.rcMonitor.Top -and
                   $rect.Right -ge $mi.rcMonitor.Right -and $rect.Bottom -ge $mi.rcMonitor.Bottom)
        if ($covers) {
            $script:FullscreenWhy = ('{0} covers its monitor: window {1},{2}..{3},{4}, monitor {5},{6}..{7},{8}' -f
                $cls.ToString(), $rect.Left, $rect.Top, $rect.Right, $rect.Bottom,
                $mi.rcMonitor.Left, $mi.rcMonitor.Top, $mi.rcMonitor.Right, $mi.rcMonitor.Bottom)
        }
        return $covers
    }
    catch { return $false }
}

function Restore-BestModes {
    param([int]$DebounceMs = 3000)

    if (((Get-Date) - $script:LastRestore).TotalMilliseconds -lt $DebounceMs) { return @() }
    $script:LastRestore = Get-Date

    if (Test-FullscreenApp) {
        if (-not $script:RestorePending) {
            Write-DisplayLog ('watch: postponed - full screen: {0}' -f $script:FullscreenWhy)
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
        foreach ($m in @(Get-DisplayState)) {
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
                Write-DisplayLog ('watch: postponed - full screen: {0}' -f $script:FullscreenWhy)
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

    # @(): одно устройство функция отдала бы скаляром, и .Count у него нет.
    $devices = @(Get-AudioDevices)
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
        #
        # И три исхода, а не два. «Ответил чужим числом» — это отказ, и совет про
        # меню монитора здесь к месту. «Не ответил вовсе» — это чаще всего шина,
        # которая ещё не проснулась, и значение при этом скорее всего ЛЕГЛО. Одно
        # сообщение на оба случая врало бы в половине: «did not take brightness 60»
        # уходило монитору, который ровно на 60 и стоял.
        $good = @()
        $refused = @()
        $silent = @()
        if ($b -ge 0) {
            if ($one.BrightnessConfirmed) { $good += "brightness $b" }
            elseif ($one.BrightnessRead)  { $refused += "brightness $b (it reports $($one.BrightnessActual))" }
            else                          { $silent += "brightness $b" }
        }
        if ($c -ge 0) {
            if ($one.ContrastConfirmed) { $good += "contrast $c" }
            elseif ($one.ContrastRead)  { $refused += "contrast $c (it reports $($one.ContrastActual))" }
            else                        { $silent += "contrast $c" }
        }

        if ($good.Count -gt 0) {
            Write-DisplayLog ("levels: {0} - {1}" -f $label, ($good -join ', '))
            $done += $label
        }
        if ($refused.Count -gt 0) {
            Write-DisplayLog ("levels: {0} refused {1} - DDC/CI may be off in its own menu" -f $label, ($refused -join ', '))
        }
        if ($silent.Count -gt 0) {
            # Не «не принял», а «не ответил»: врать об успехе нельзя, но и вешать
            # на монитор отказ, которого не было, тоже.
            Write-DisplayLog ("levels: {0} never answered about {1} - it may still be waking up, and the value may well have landed" -f `
                              $label, ($silent -join ', '))
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
# «Случилось это — стань таким».
#
# Вся логика — здесь, чистой функцией над фактами, и она же под тестами. В трее
# остаётся только собрать факты и исполнить решение: слежение живёт в таймере,
# который тикает раз в пятнадцать секунд неделями, и отлаживать его по журналу
# вместо тестов слишком дорого.
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
    # $PlugModeMembers — пути мониторов, входящих в режим из onPlug. Считает их
    # вызывающий: состав режима зависит от того, что сейчас на столе, а эта
    # функция состояния не знает и знать не должна. $null означает «не сказали».
    #
    # $VanishedRecently и $SecondsSinceVanish — кто пропал в ПРОШЛЫЙ раз и как
    # давно (см. карантин ниже). Время передают снаружи, а не смотрят на часы
    # здесь: за часы функцию было бы не проверить.
    param($Reapply, $Before, $Now, [string]$LastMode, $PlugModeMembers = $null,
          $VanishedRecently = $null, $SecondsSinceVanish = $null, [int]$QuietSeconds = 10)

    $none = [pscustomobject]@{ Action = 'none'; Mode = ''; Reason = ''; Appeared = @(); Vanished = @() }
    if (-not $Reapply) { return $none }

    $before = @($Before | Where-Object { $_ })
    $now = @($Now | Where-Object { $_ })
    # Пустой «до» — это первый опрос за запуск, сравнивать не с чем.
    if ($before.Count -eq 0) { return $none }

    $appeared = @($now | Where-Object { $before -notcontains $_ })
    $vanished = @($before | Where-Object { $now -notcontains $_ })

    # Дальше «ничего не делаем» уже про конкретные мониторы: их имена нужны
    # журналу, а список пропавших — тому, кто засечёт время для карантина.
    $none = [pscustomobject]@{ Action = 'none'; Mode = ''; Reason = ''
                               Appeared = $appeared; Vanished = $vanished }

    # Монитор появился. По умолчанию не делаем ничего: человек только что включил
    # его кнопкой, и погасить его в ответ — это война с человеком. Режим для этого
    # случая называют явно (reapply.onPlug).
    #
    # Но и названный режим применяем только тогда, когда появившийся монитор в
    # него ВХОДИТ. Иначе «собирай стол сам» означало бы «гаси всё, что я включил
    # не по плану»: в combo:Work нет ASUS, и включённый кнопкой ASUS гаснул бы
    # через секунду — та же война, только теперь по настройке. У 'all' участники —
    # всё подключённое, поэтому там проверка не меняет ничего.
    $echoReason = ''
    if ($appeared.Count -gt 0 -and [string]$Reapply.onPlug) {
        $ours = $true
        if ($null -ne $PlugModeMembers) {
            $members = @($PlugModeMembers | Where-Object { $_ })
            $ours = (@($appeared | Where-Object { $members -contains $_ }).Count -gt 0)
        }

        # Карантин: появление вскоре после ЧУЖОЙ пропажи — это не рука на кабеле,
        # а эхо. Когда монитор уходит с шины, Windows тут же зажигает то, что
        # осталось, и разбуженные экраны приходят ОТДЕЛЬНЫМ событием через
        # секунду-две. Замерено 2026-08-28: ASUS пропал в 21:06:43, «появился
        # монитор» пришло в 21:06:45, и стол уехал в combo:Work, где ASUS'а нет.
        #
        # Проверка членства (выше) на этом не спасает: проснувшийся ULTRAGEAR в
        # combo:Work входит честно. Вопрос не в том, чей монитор, а в том, кто
        # его включил.
        #
        # Два случая карантин НЕ трогает, оба намеренно. Свой же монитор,
        # вернувшийся после собственной пропажи, — это «выключил кнопкой и включил
        # обратно», ровно то, ради чего настройку заводили. И пропажа с появлением
        # в ОДНОМ событии — это переткнутый кабель, там новый монитор и есть
        # новость (см. случай про cable swapped ниже по файлу тестов).
        $recent = @($VanishedRecently | Where-Object { $_ })
        $echo = ($null -ne $SecondsSinceVanish -and $recent.Count -gt 0 -and
                 [double]$SecondsSinceVanish -lt $QuietSeconds -and
                 (@($appeared | Where-Object { $recent -contains $_ }).Count -eq 0))

        if ($ours -and $echo) { $echoReason = 'a display came up right after another went away' }
        elseif ($ours) {
            return [pscustomobject]@{ Action = 'mode'; Mode = [string]$Reapply.onPlug
                                      Reason = 'a display was plugged in'
                                      Appeared = $appeared; Vanished = $vanished }
        }
    }

    # Монитор пропал. Возвращаем последний выбранный режим: Switch-DisplayMode
    # соберёт из него то, что осталось на столе, — раскладку и панель задач в том
    # числе. Ничего нового при этом не включается.
    if ($vanished.Count -gt 0 -and $Reapply.onUnplug -and $LastMode) {
        return [pscustomobject]@{ Action = 'mode'; Mode = [string]$LastMode
                                  Reason = 'a display went away'
                                  Appeared = $appeared; Vanished = $vanished }
    }

    if ($echoReason) {
        return [pscustomobject]@{ Action = 'none'; Mode = ''; Reason = $echoReason
                                  Appeared = $appeared; Vanished = $vanished }
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

# Та же длительность, но как её пишут на кнопке: «45 min», «1 h», «1 h 30 min».
# Format-Duration ставит «1 h 00 min» — в обратном отсчёте это правильно (ширина
# строки не скачет каждую минуту), а на таблетке и в пункте меню лишний ноль
# только мешает. Обратно читается тем же ConvertFrom-DurationText.
function Format-DurationShort {
    param([int]$Minutes)

    if ($Minutes -lt 0) { $Minutes = 0 }
    if ($Minutes -lt 60) { return ('{0} min' -f $Minutes) }
    $hours = [int][math]::Floor($Minutes / 60)
    $rest = $Minutes % 60
    if ($rest -eq 0) { return ('{0} h' -f $hours) }
    return ('{0} h {1} min' -f $hours, $rest)
}

# Ступени ползунка в окне таймера. Не ровный шаг: у «через пять минут» и «через
# восемь часов» разная цена ошибки, и одинаковый шаг делает мелкий конец
# неуправляемым, а крупный — бесконечным. Вблизи шаг в пять минут, дальше он
# растёт, и весь диапазон укладывается в три десятка положений.
$script:TimerSteps = @(5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60,
                       70, 80, 90, 100, 110, 120,
                       150, 180, 210, 240, 300, 360, 420, 480, 600, 720)

# Потолок — те же двенадцать часов, что и последняя ступень. Таймер сна дальше
# полусуток — это уже не «выключи, когда досмотрю»: столько отложенного
# выключения человек не удержит в голове, а компьютер выключится всё равно.
$script:TimerMaxMinutes = 720

function Get-TimerSteps { return $script:TimerSteps }

# Минуты -> ближайшая ступень ползунка. Ближайшая, а не следующая снизу: набрано
# «1h29», ползунок обязан встать на полтора часа, а не на час двадцать.
function Get-TimerStepIndex {
    param([int]$Minutes)

    $steps = $script:TimerSteps
    $best = 0
    $bestGap = [int]::MaxValue
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $gap = [math]::Abs($steps[$i] - $Minutes)
        if ($gap -lt $bestGap) { $bestGap = $gap; $best = $i }
    }
    return $best
}

function Get-TimerStepMinutes {
    param([int]$Index)

    $steps = $script:TimerSteps
    if ($Index -lt 0) { $Index = 0 }
    if ($Index -ge $steps.Count) { $Index = $steps.Count - 1 }
    return [int]$steps[$Index]
}

# Подтолкнуть значение на шаг колесом или стрелками: пять минут, но по сетке
# пятиминуток, а не «47 -> 52». Ниже пяти минут и выше потолка не уходим.
function Get-TimerNudge {
    param([int]$Minutes, [int]$Step = 5)

    if ($Step -eq 0) { return $Minutes }
    $grid = [int][math]::Round($Minutes / [double]$Step) * $Step
    # Уже на сетке — шагаем; между узлами — притягиваемся к ближайшему в сторону
    # движения, иначе первое движение колеса ощущалось бы как половина шага.
    if ($grid -eq $Minutes) { $next = $Minutes + $Step }
    elseif ($Step -gt 0)    { $next = $(if ($grid -gt $Minutes) { $grid } else { $grid + $Step }) }
    else                    { $next = $(if ($grid -lt $Minutes) { $grid } else { $grid + $Step }) }

    if ($next -lt 5) { $next = 5 }
    if ($next -gt $script:TimerMaxMinutes) { $next = $script:TimerMaxMinutes }
    return [int]$next
}

# «в 03:45» и «в 03:45 завтра» — когда именно это случится. Час на часах человек
# сверяет с собственными планами быстрее, чем остаток в минутах: «через 340 мин»
# не говорит ничего, «в 06:20 завтра» говорит всё. Время — через инвариантную
# культуру: журнал и интерфейс у нас не зависят от языка системы.
function Get-TimerTargetText {
    param([int]$Minutes, [datetime]$Now = (Get-Date))

    $at = $Now.AddMinutes($Minutes)
    $text = 'at ' + $at.ToString('HH:mm', [cultureinfo]::InvariantCulture)
    if ($at.Date -gt $Now.Date) { $text += ' tomorrow' }
    return $text
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
