<#
    DisplayCore.ps1 — общая логика переключения мониторов.

    Только определения, никаких действий при загрузке. Точки входа:
        Displays.ps1      значок в трее
        Set-Display.ps1   командная строка

    Всё, что можно узнать через Windows API, узнаётся через него: запуск
    MultiMonitorTool.exe стоит 1-1.5 секунды, а вызов API — бесплатно.
#>

$script:ToolRoot     = $PSScriptRoot
$script:Mmt          = Join-Path $PSScriptRoot 'MultiMonitorTool.exe'
$script:LogFile      = Join-Path $PSScriptRoot 'last-run.log'
$script:SettingsFile = Join-Path $PSScriptRoot 'settings.json'

function Write-DisplayLog {
    param([string]$Message)
    try {
        Add-Content -Path $script:LogFile -Encoding UTF8 -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    }
    catch { }   # лог не должен ронять переключение мониторов
}

# --- настройки --------------------------------------------------------------
# Привязки клавиш живут в settings.json, а не в коде: их правит сам пользователь
# через окно настроек. Ключи режимов — стабильные (см. Get-DisplayModes).

function Get-DefaultSettings {
    return [ordered]@{
        hotkeys         = [ordered]@{}
        maximizeRefresh = $true
        runAtStartup    = $false
        notifications   = $true
    }
}

function Get-DisplaySettings {
    $s = Get-DefaultSettings
    if (Test-Path $script:SettingsFile) {
        try {
            $raw = Get-Content $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $raw.maximizeRefresh) { $s.maximizeRefresh = [bool]$raw.maximizeRefresh }
            if ($null -ne $raw.runAtStartup)    { $s.runAtStartup    = [bool]$raw.runAtStartup }
            if ($null -ne $raw.notifications)   { $s.notifications   = [bool]$raw.notifications }
            if ($raw.hotkeys) {
                foreach ($p in $raw.hotkeys.PSObject.Properties) { $s.hotkeys[$p.Name] = [string]$p.Value }
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
    return $s
}

function Save-DisplaySettings {
    param($Settings)
    $Settings | ConvertTo-Json -Depth 5 | Set-Content -Path $script:SettingsFile -Encoding UTF8
    Write-DisplayLog 'settings: saved'
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

# --- Windows API ------------------------------------------------------------

if (-not ('NativeDisplay' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

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

    public const int ATTACHED_TO_DESKTOP = 0x00000001;
    public const int CURRENT_SETTINGS = -1;

    public const int DM_BITSPERPEL = 0x00040000;
    public const int DM_PELSWIDTH = 0x00080000;
    public const int DM_PELSHEIGHT = 0x00100000;
    public const int DM_DISPLAYFREQUENCY = 0x00400000;

    public const int CDS_UPDATEREGISTRY = 0x00000001;
    public const int PRIMARY_DEVICE = 0x00000004;
}
'@
}

# Отдельным классом, а не полем в NativeDisplay: у той проверка «тип уже есть»
# своя, и дописывать в неё нельзя без перезапуска процесса.
if (-not ('NativeForeground' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

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
'@
}

function New-DisplayDevice {
    $d = New-Object NativeDisplay+DISPLAY_DEVICE
    $d.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($d)
    return $d
}

# Карта: Monitor ID -> имя выхода \\.\DISPLAYx и признак «прицеплен к столу».
# Нужна отдельно от дампа MultiMonitorTool, потому что после включения монитора
# номера выходов тасуются, а перечитывать дамп ради этого дорого.
function Get-OutputMap {
    $map = @{}
    $i = 0
    while ($true) {
        $adapter = New-DisplayDevice
        # [NullString]::Value, а не $null: PowerShell превратил бы $null в пустую
        # строку, а EnumDisplayDevices на пустое имя устройства отвечает FALSE —
        # карта молча получалась пустой.
        if (-not [NativeDisplay]::EnumDisplayDevices([NullString]::Value, $i, [ref]$adapter, 0)) { break }

        $monitor = New-DisplayDevice
        if ([NativeDisplay]::EnumDisplayDevices($adapter.DeviceName, 0, [ref]$monitor, 0)) {
            if ($monitor.DeviceID) {
                $map[$monitor.DeviceID.ToUpperInvariant()] = [pscustomobject]@{
                    Output   = $adapter.DeviceName
                    Attached = (($adapter.StateFlags -band [NativeDisplay]::ATTACHED_TO_DESKTOP) -ne 0)
                    Primary  = (($adapter.StateFlags -band [NativeDisplay]::PRIMARY_DEVICE) -ne 0)
                }
            }
        }
        $i++
    }
    return $map
}

# Прицеплен ли к рабочему столу хоть один из указанных мониторов. С повторами:
# сразу после смены режима дисплей на доли секунды отцепляется, и одиночная
# проверка принимает это за «не включился».
# Дождаться конкретного монитора и вернуть его запись. Фиксированной паузой это
# делать нельзя: после /disable карта ещё несколько секунд отвечает «не
# прицеплен», и работа, стоявшая за такой проверкой, молча пропускалась.
function Get-AttachedOutput {
    param([Parameter(Mandatory)][string]$Id, [int]$TimeoutMs = 8000)

    $key = $Id.ToUpperInvariant()
    $waited = 0
    while ($true) {
        $entry = (Get-OutputMap)[$key]
        if ($entry -and $entry.Attached) { return $entry }
        if ($waited -ge $TimeoutMs) { return $null }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
}

# Кто из перечисленных всё ещё висит на рабочем столе. Пустой список — все
# погасли. EnumDisplayDevices бесплатен, поэтому опрашивать можно часто.
function Wait-ForDetached {
    param([string[]]$Ids, [int]$TimeoutMs = 5000)

    $waited = 0
    while ($true) {
        $map = Get-OutputMap
        $still = @()
        foreach ($id in $Ids) {
            $entry = $map[$id.ToUpperInvariant()]
            if ($entry -and $entry.Attached) { $still += $id }
        }
        if ($still.Count -eq 0) { return @() }
        if ($waited -ge $TimeoutMs) { return $still }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
}

function Wait-ForAttached {
    param([string[]]$Ids, [int]$TimeoutMs = 15000)

    $waited = 0
    while ($true) {
        $map = Get-OutputMap
        foreach ($id in $Ids) {
            $entry = $map[$id.ToUpperInvariant()]
            if ($entry -and $entry.Attached) { return $true }
        }
        if ($waited -ge $TimeoutMs) { return $false }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
}

# Родное разрешение монитора из EDID: первый детальный тайминг (offset 54) — это
# preferred timing, то есть физическая матрица.
#
# Спрашивать драйвер бесполезно. Windows и MultiMonitorTool сообщали для
# ULTRAGEAR «Maximum Resolution 3840x2160», потому что по HDMI он принимает 4K и
# сам его сжимает в свои 1440p. Выбор режима «по самой большой площади» из-за
# этого целился в 3840x2160@60: применить не удавалось (в журнале
# `mode: ... failed`), а удалось бы — уронило бы 144 Гц до 60.
function Get-NativeResolution {
    # ShortId без Mandatory и с проверкой ниже: у выключенного монитора дамп
    # /scomma отдаёт пустой короткий ID, и обязательный параметр валил весь вывод
    # status с ошибкой привязки.
    param([string]$ShortId, [string]$DriverKey)

    if ([string]::IsNullOrWhiteSpace($ShortId)) { return $null }

    try {
        $base = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\$ShortId"
        if (-not (Test-Path $base)) { return $null }

        $instances = @(Get-ChildItem $base -ErrorAction Stop)
        $chosen = $null
        if ($DriverKey) {
            # Один и тот же монитор оставляет в реестре записи с прошлых
            # подключений. Нужная — та, чей Driver совпадает с текущей.
            foreach ($inst in $instances) {
                $drv = (Get-ItemProperty $inst.PSPath -Name Driver -ErrorAction SilentlyContinue).Driver
                if ($drv -eq $DriverKey) { $chosen = $inst; break }
            }
        }
        if (-not $chosen) { $chosen = $instances | Select-Object -First 1 }
        if (-not $chosen) { return $null }

        $edid = (Get-ItemProperty (Join-Path $chosen.PSPath 'Device Parameters') -Name EDID -ErrorAction Stop).EDID
        if (-not $edid -or $edid.Length -lt 72) { return $null }

        $b = 54
        $w = $edid[$b + 2] -bor (($edid[$b + 4] -band 0xF0) -shl 4)
        $h = $edid[$b + 5] -bor (($edid[$b + 7] -band 0xF0) -shl 4)
        if ($w -lt 640 -or $h -lt 480) { return $null }
        return [pscustomobject]@{ Width = $w; Height = $h }
    }
    catch { return $null }
}

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
        return [pscustomobject]@{ Width = $dm.dmPelsWidth; Height = $dm.dmPelsHeight; Hz = $dm.dmDisplayFrequency }
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

# Поднять монитор в его максимальный режим, если он там ещё не стоит. С проверкой
# и повторной попыткой: смена основного монитора и гашение соседа могут сбросить
# режим уже после того, как он был выставлен.
function Set-BestModeFor {
    param(
        [Parameter(Mandatory)][string]$Output,
        [string]$Label = '',
        [int]$NativeWidth = 0,
        [int]$NativeHeight = 0
    )

    $best = Get-BestMode -Output $Output -NativeWidth $NativeWidth -NativeHeight $NativeHeight
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
        Start-Sleep -Milliseconds 600
    }

    $current = Get-CurrentMode $Output
    $ok = ($current -and $current.Hz -eq $best.Hz)
    if (-not $ok) {
        Write-DisplayLog ("mode: {0} stayed at {1} Hz instead of {2} - something outside is resetting it" -f `
            $Label, $current.Hz, $best.Hz)
    }
    return $ok
}

# --- основной монитор -------------------------------------------------------
# Заклинивание, из-за которого не работало ничего (5 августа 2026).
#
# ASUS в режиме 2560x1440@240 использует DSC, и такой режим Windows не может
# записать в реестр. Пока он был основным в этом режиме, система не могла
# перезаписать конфигурацию дисплеев вообще: роль основного не уходила с него, а
# основной монитор выключить нельзя — значит не гасилось ничего, ни он, ни
# соседи. Все команды при этом отвечали успехом, включая родной DisplaySwitch.
#
# Расклинивается это тем, что монитор переводится на частоту, которая
# сохраняется (у ASUS это 120 Гц). После переноса роли режим возвращается
# последним шагом переключения, и 240 Гц снова на месте.

function Test-IsPrimary {
    param([Parameter(Mandatory)][string]$Id)
    $entry = (Get-OutputMap)[$Id.ToUpperInvariant()]
    return ($entry -and $entry.Primary)
}

# Частоты, доступные в заданном разрешении, по убыванию.
function Get-RefreshRates {
    param([string]$Output, [int]$Width, [int]$Height)

    $rates = @()
    $i = 0
    while ($true) {
        $dm = New-Object NativeDisplay+DEVMODE
        $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        if (-not [NativeDisplay]::EnumDisplaySettings($Output, $i, [ref]$dm)) { break }
        $i++
        if ($dm.dmBitsPerPel -lt 32 -or $dm.dmDisplayFlags -ne 0) { continue }
        if ($dm.dmPelsWidth -ne $Width -or $dm.dmPelsHeight -ne $Height) { continue }
        $rates += [int]$dm.dmDisplayFrequency
    }
    return @($rates | Sort-Object -Unique -Descending)
}

# Найденную сохраняемую частоту помним: в следующий раз идём прямо к ней и не
# мигаем экраном по всему списку.
$script:PersistableHz = @{}

function Set-PersistableMode {
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [string]$Label = ''
    )

    $cacheKey = '{0}|{1}x{2}' -f $Output, $Width, $Height
    $rates = @(Get-RefreshRates -Output $Output -Width $Width -Height $Height)
    if ($script:PersistableHz.ContainsKey($cacheKey)) {
        $known = $script:PersistableHz[$cacheKey]
        $rates = @($known) + @($rates | Where-Object { $_ -ne $known })
    }

    $current = Get-CurrentMode $Output
    foreach ($hz in $rates) {
        # Текущую частоту пропускаем: она и есть та, что не сохраняется.
        if ($current -and $hz -eq $current.Hz) { continue }

        $r = Set-DisplayMode -Output $Output -Width $Width -Height $Height -Hz $hz
        if ($r.Code -eq 0 -and $r.Persisted) {
            $script:PersistableHz[$cacheKey] = $hz
            Write-DisplayLog ("unjam: {0} moved to {1} Hz - a rate Windows can actually save" -f $Label, $hz)
            return $true
        }
    }
    Write-DisplayLog ("unjam: {0} has no refresh rate that Windows will save" -f $Label)
    return $false
}

# Перенести роль основного и убедиться, что перенос состоялся. Проверка
# бесплатная (EnumDisplayDevices), поэтому её не жалко делать всегда: раньше
# команда уходила, отвечала успехом и не делала ничего, а приложение шло дальше
# как будто всё хорошо.
function Set-PrimaryDisplay {
    param(
        [Parameter(Mandatory)]$Target,
        $State,
        [switch]$DryRun
    )

    if (Test-IsPrimary $Target.Id) { return $true }

    Invoke-Mmt @('/SetMonitors', ('Name=' + $Target.Id + ' Primary=1')) -SettleMs 500 -DryRun:$DryRun
    if ($DryRun) { return $true }
    if (Test-IsPrimary $Target.Id) { return $true }

    # Не переехало. Виноват тот, кто держит роль сейчас: его режим не сохраняется.
    $map = Get-OutputMap
    $blockerOutput = $null
    foreach ($id in $map.Keys) { if ($map[$id].Primary) { $blockerOutput = $map[$id].Output; break } }
    if (-not $blockerOutput) { return $false }

    $blocker = $State | Where-Object { $_.Output -eq $blockerOutput } | Select-Object -First 1
    $label = if ($blocker) { $blocker.Label } else { $blockerOutput }
    Write-DisplayLog ("warn: primary did not move to {0}; {1} is holding it" -f $Target.Label, $label)

    $w = 0; $h = 0
    if ($blocker -and $blocker.Native) { $w = $blocker.Native.Width; $h = $blocker.Native.Height }
    if ($w -eq 0) {
        $cur = Get-CurrentMode $blockerOutput
        if ($cur) { $w = $cur.Width; $h = $cur.Height }
    }
    if ($w -eq 0) { return $false }

    if (-not (Set-PersistableMode -Output $blockerOutput -Width $w -Height $h -Label $label)) { return $false }

    Invoke-Mmt @('/SetMonitors', ('Name=' + $Target.Id + ' Primary=1')) -SettleMs 500
    if (Test-IsPrimary $Target.Id) {
        Write-DisplayLog ("unjam: primary moved to {0} on the second try" -f $Target.Label)
        return $true
    }
    Write-DisplayLog ("warn: primary still would not move to {0}" -f $Target.Label)
    return $false
}

# --- состояние --------------------------------------------------------------
# Короткий Monitor ID — код производителя из EDID: GSM = LG (GoldStar),
# AUS = ASUS. Он стабилен для модели и используется как ключ в настройках.
# В самих командах всегда идёт полный Monitor ID — он уникален для выхода.

function Get-MonitorRole {
    param($Row)

    $shortId = [string]$Row.'Short Monitor ID'
    $text = ([string]$Row.'Monitor Name') + ' ' + ([string]$Row.'Monitor String')

    if ($shortId -match '^AUS' -or $text -match 'ROG|ASUS') { return 'game' }
    if ($shortId -match '^GSM' -or $text -match '\bLG\b')   { return 'work' }
    return 'other'
}

# Дамп MultiMonitorTool — единственное, что надёжно различает «подключён, но
# выключен» и «выдернут из порта»: данные о выключенных он берёт из реестра.
function Get-DisplayState {
    $tmp = Join-Path $env:TEMP ('mmt-' + [guid]::NewGuid().ToString('N') + '.csv')
    try {
        Start-Process -FilePath $script:Mmt -ArgumentList '/scomma', $tmp -Wait -NoNewWindow

        $waited = 0
        while ((-not (Test-Path $tmp)) -and $waited -lt 5000) {
            Start-Sleep -Milliseconds 100
            $waited += 100
        }
        if (-not (Test-Path $tmp)) { throw 'MultiMonitorTool did not return a monitor list' }

        $rows = @(Import-Csv -Path $tmp)
    }
    finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    foreach ($row in $rows) {
        $parts = ([string]$row.Resolution) -split '\s*X\s*'
        $width = 0; $height = 0
        if ($parts.Count -eq 2) { $width = [int]$parts[0]; $height = [int]$parts[1] }

        $output = [string]$row.Name
        $shortId = [string]$row.'Short Monitor ID'

        # Ключ драйвера из Monitor Key: им отличаем текущую запись монитора в
        # реестре от оставшихся с прошлых подключений.
        $driverKey = $null
        if (([string]$row.'Monitor Key') -match '\\Class\\(.+)$') { $driverKey = $Matches[1] }
        $native = Get-NativeResolution -ShortId $shortId -DriverKey $driverKey

        $best = $null
        if ($row.Active -eq 'Yes') {
            $nw = 0; $nh = 0
            if ($native) { $nw = $native.Width; $nh = $native.Height }
            $best = Get-BestMode -Output $output -NativeWidth $nw -NativeHeight $nh
        }

        $label = [string]$row.'Monitor Name'
        if (-not $label) { $label = [string]$row.'Monitor String' }
        if (-not $label) { $label = $output }

        [pscustomobject]@{
            Output       = $output
            Label        = $label
            Model        = "$($row.'Monitor Name') $($row.'Monitor String')".Trim()
            ShortId      = $shortId
            Native       = $native
            Role         = Get-MonitorRole $row
            Id           = [string]$row.'Monitor ID'
            Active       = ($row.Active -eq 'Yes')
            Primary      = ($row.Primary -eq 'Yes')
            Disconnected = ($row.Disconnected -eq 'Yes')
            Width        = $width
            Height       = $height
            Hz           = [int]$row.Frequency
            BestMode     = $best
            Position     = [string]$row.'Left-Top'
        }
    }
}

# --- режимы -----------------------------------------------------------------
# Режимы строятся из текущего состояния, а не из жёсткого списка: у каждого
# монитора появляется свой соло-режим сам, как только он подключён. Ключ режима
# стабилен (короткий Monitor ID), поэтому привязки клавиш переживают
# переподключение кабеля и смену номеров выходов.

function Get-DisplayModes {
    param($State)

    if (-not $State) { $State = @(Get-DisplayState) }
    $modes = @()

    # Ключ соло-режима — по названию монитора, а не по короткому Monitor ID.
    # Короткий ID стабилен только для пары «монитор + вход»: у монитора на DP и
    # на HDMI разные EDID, и код в них разный. После перекладки кабелей
    # ULTRAGEAR стал GSM5BB4 -> GSM5BB3, ULTRAFINE GSM5CBB -> GSM5CBC, и
    # привязки Ctrl+Alt+F1/F2 указывали в пустоту. Название входу не меняется.
    $dupes = @($State | Group-Object Label | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    foreach ($m in $State) {
        # Две одинаковые модели дали бы один ключ на двоих — тогда различаем их
        # коротким ID, другого признака нет.
        $name = $m.Label
        if ($dupes -contains $m.Label) { $name = $m.Label + ' ' + $m.ShortId }
        $modes += [pscustomobject]@{
            Key       = 'solo:' + $name
            Title     = 'Only ' + $m.Label
            Kind      = 'solo'
            ShortId   = $m.ShortId
            Primary   = $null
            Available = (-not $m.Disconnected)
        }
    }

    $groups = @(
        [pscustomobject]@{ Key = 'role:work'; Title = 'Work displays'; Role = 'work'; Primary = $null }
        [pscustomobject]@{ Key = 'role:game'; Title = 'Gaming display'; Role = 'game'; Primary = $null }
    )
    foreach ($g in $groups) {
        $members = @($State | Where-Object { $_.Role -eq $g.Role -and -not $_.Disconnected })
        # Группу из одного монитора не показываем — для него уже есть соло-режим.
        if ($members.Count -lt 2) { continue }
        $modes += [pscustomobject]@{
            Key       = $g.Key
            Title     = $g.Title
            Kind      = 'role'
            Role      = $g.Role
            Primary   = $g.Primary
            Available = $true
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
        '^solo:(.+)$' { return 'Only ' + $Matches[1] }
        '^role:work$' { return 'Work displays' }
        '^role:game$' { return 'Gaming display' }
        '^all$'       { return 'All displays' }
        default       { return $Key }
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
        if (-not $hit) { continue }
        # Новый ключ уже занят другой комбинацией — не перетираем молча.
        if ($Settings.hotkeys.Contains($hit.Key)) { continue }

        $combo = $Settings.hotkeys[$old]
        $Settings.hotkeys.Remove($old)
        $Settings.hotkeys[$hit.Key] = $combo
        Write-DisplayLog "settings: moved $combo from '$old' to '$($hit.Key)'"
        $changed = $true
    }
    return $changed
}

function Get-ModeMembers {
    param($Mode, $State)

    $usable = @($State | Where-Object { -not $_.Disconnected })
    switch ($Mode.Kind) {
        'all'  { return $usable }
        'role' { return @($usable | Where-Object { $_.Role -eq $Mode.Role }) }
        'solo' { return @($usable | Where-Object { $_.ShortId -eq $Mode.ShortId }) }
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

function Invoke-Mmt {
    param([string[]]$MmtArgs, [int]$SettleMs = 300, [switch]$DryRun)

    if ($DryRun) {
        Write-Host "DRY  MultiMonitorTool.exe $($MmtArgs -join ' ')" -ForegroundColor DarkGray
        return
    }
    Write-DisplayLog "run: MultiMonitorTool.exe $($MmtArgs -join ' ')"
    Start-Process -FilePath $script:Mmt -ArgumentList $MmtArgs -Wait -NoNewWindow
    if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }
}

# --- переключение -----------------------------------------------------------

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
    $mutex = New-Object System.Threading.Mutex($false, 'Local\SuperDisplaySwitch')
    if (-not $mutex.WaitOne(0)) {
        Write-DisplayLog "skip: mode=$ModeKey - the previous switch has not finished yet"
        if (-not $Quiet) { Write-Host 'A switch is already in progress - skipping.' -ForegroundColor Yellow }
        return [pscustomobject]@{ Mode = $ModeKey; Skipped = $true; Message = 'A switch is already in progress.' }
    }

    try {
        Write-DisplayLog "--- start mode=$ModeKey primaryMatch='$PrimaryMatch' keepMode=$KeepMode dryRun=$DryRun"

        $monitors = @(Get-DisplayState)
        $modes = Get-DisplayModes $monitors
        $mode = $modes | Where-Object { $_.Key -eq $ModeKey } | Select-Object -First 1
        if (-not $mode) {
            # Клавиша может быть назначена на монитор, который сейчас не воткнут —
            # это нормальная ситуация, а не поломка, и говорить надо по-человечески.
            if ($ModeKey -like 'solo:*' -or $ModeKey -like 'role:*') {
                throw "That display is not connected right now."
            }
            throw "Unknown mode '$ModeKey'."
        }

        $outputs = Get-OutputMap
        $usable = @($monitors | Where-Object { -not $_.Disconnected })
        $wanted = @(Get-ModeMembers $mode $monitors)

        if ($wanted.Count -eq 0) {
            throw "Mode '$($mode.Title)': none of its displays are connected. Nothing was turned off, so you keep a picture."
        }

        $wantedIds = @($wanted | ForEach-Object { $_.Id })
        $toDisable = @($usable | Where-Object { $wantedIds -notcontains $_.Id })

        if (-not $PrimaryMatch) { $PrimaryMatch = $mode.Primary }

        $primary = $null
        if ($PrimaryMatch) {
            $primary = $wanted | Where-Object { $_.Model -match [regex]::Escape($PrimaryMatch) } | Select-Object -First 1
            if (-not $primary) { throw "-PrimaryMatch '$PrimaryMatch' matched none of the displays in '$($mode.Title)'." }
        }
        if (-not $primary) { $primary = $wanted | Where-Object { $_.Primary } | Select-Object -First 1 }
        if (-not $primary) { $primary = $wanted | Select-Object -First 1 }

        if (-not $Quiet) {
            Write-Host "$($mode.Title):" -ForegroundColor Cyan
            foreach ($m in $wanted)    { Write-Host "  on       $($m.Output)  $($m.Label)" }
            Write-Host "  primary  $($primary.Output)  $($primary.Label)"
            foreach ($m in $toDisable) { Write-Host "  off      $($m.Output)  $($m.Label)" }
        }

        # Порядок важен: поднять нужные -> выставить основной и режим -> погасить
        # остальные. Иначе можно на миг остаться совсем без дисплея.

        $toEnable = @($wanted | Where-Object { -not $_.Active })
        if ($toEnable.Count -gt 0) {
            Invoke-Mmt (@('/enable') + @($toEnable | ForEach-Object { $_.Id })) -SettleMs 1200 -DryRun:$DryRun
            if (-not $DryRun) { $outputs = Get-OutputMap }
        }

        # /SetMonitors теперь только про основной монитор. Режимы ставятся ниже,
        # через API, и последним шагом — см. комментарий там.
        if ($primary.Id -ne ($monitors | Where-Object { $_.Primary } | Select-Object -First 1).Id) {
            Invoke-Mmt @('/SetMonitors', ('Name=' + $primary.Id + ' Primary=1')) -SettleMs 500 -DryRun:$DryRun
        }

        $toDisableActive = @($toDisable | Where-Object { $_.Active })
        if ($toDisableActive.Count -gt 0) {
            # Гасим только убедившись, что нужное реально прицепилось к рабочему
            # столу. Обычно это 1-2 секунды; если не дождались — почти наверняка
            # плохо сидит кабель или монитор ушёл в глубокий сон по DisplayPort.
            if (-not $DryRun) {
                if (-not (Wait-ForAttached -Ids $wantedIds)) {
                    throw "No display from '$($mode.Title)' came up within 15 seconds, so nothing was turned off. The monitor has dropped its link. Unplug its cable and plug it back in - a power cycle alone has not been enough. If this keeps happening, replace the cable."
                }
            }
            Invoke-Mmt (@('/disable') + @($toDisableActive | ForEach-Object { $_.Id })) -SettleMs 0 -DryRun:$DryRun

            # Проверяем, что они действительно отцепились от рабочего стола.
            # Раньше этого не было, и строка done: перечисляла только те мониторы,
            # которые должны остаться включёнными. Из-за этого отказ /disable
            # выглядел в журнале как полный успех: приложение сообщало «готово», а
            # на столе оставалось три экрана вместо одного.
            if (-not $DryRun) {
                $stubborn = @(Wait-ForDetached -Ids @($toDisableActive | ForEach-Object { $_.Id }))
                if ($stubborn.Count -gt 0) {
                    $names = @($toDisableActive | Where-Object { $stubborn -contains $_.Id } | ForEach-Object { $_.Label })
                    Write-DisplayLog ("warn: refused to turn off: " + ($names -join ', '))
                    $refused = $names
                }
            }
        }

        if ($DryRun) { return [pscustomobject]@{ Mode = $ModeKey; Skipped = $false; Message = 'dry run' } }

        # Режим выставляем последним, когда набор активных мониторов уже
        # окончательный: и назначение основного, и гашение соседа сбрасывают
        # частоту на то, что записано в реестре, а там она часто ниже родной.
        # Каждый монитор ждём отдельно — иначе он не успевает прицепиться, и
        # установка режима вместе со сводкой пропадают вообще без следа.
        $summary = foreach ($m in $wanted) {
            $entry = Get-AttachedOutput -Id $m.Id
            if (-not $entry) {
                Write-DisplayLog "warn: $($m.Label) did not attach within 8 s - mode was not applied"
                continue
            }
            if (-not $KeepMode) {
                $nw = 0; $nh = 0
                if ($m.Native) { $nw = $m.Native.Width; $nh = $m.Native.Height }
                [void](Set-BestModeFor -Output $entry.Output -Label $m.Label -NativeWidth $nw -NativeHeight $nh)
            }
            $cur = Get-CurrentMode $entry.Output
            if ($cur) { '{0} {1}x{2} @ {3} Hz' -f $m.Label, $cur.Width, $cur.Height, $cur.Hz } else { $m.Label }
        }
        $text = ($summary -join ', ')
        # Об отказе гасить говорим прямо в сводке: иначе выходит рапорт об успехе
        # при том, что на столе осталось больше экранов, чем просили.
        if ($refused -and $refused.Count -gt 0) {
            $text += ('. Still on: ' + ($refused -join ', ') + ' - Windows would not turn them off')
        }
        Write-DisplayLog "done: $text"
        return [pscustomobject]@{ Mode = $ModeKey; Skipped = $false; Message = $text; Refused = $refused }
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
    $mutex = New-Object System.Threading.Mutex($false, 'Local\SuperDisplaySwitch')
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
            if (Set-BestModeFor -Output $m.Output -Label $m.Label -NativeWidth $nw -NativeHeight $nh) {
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

# --- автозагрузка -----------------------------------------------------------

function Get-StartupShortcutPath {
    return Join-Path ([Environment]::GetFolderPath('Startup')) 'Multi-Monitor Tool.lnk'
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
    $sc.Description = 'Multi-Monitor Tool - display switcher in the notification area'
    $sc.Save()
    Write-DisplayLog 'startup: enabled'
}
