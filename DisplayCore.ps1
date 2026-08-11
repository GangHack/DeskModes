<#
    DisplayCore.ps1 — общая логика переключения мониторов.

    Только определения, никаких действий при загрузке. Точки входа:
        Displays.ps1      значок в трее
        Set-Display.ps1   командная строка

    Всё делается через Windows API, напрямую. MultiMonitorTool.exe в работе
    больше не участвует: чтение состояния он отдавал за 1100 мс против ~90 мс у
    CCD, выключенный монитор в его дампе терял имя и идентификатор, а его
    команды шли через ту запись раскладки, которая на этой машине отвечает
    отказом. Файл оставлен в папке — иногда полезен вручную, для сверки.
#>

$script:ToolRoot     = $PSScriptRoot
$script:LogFile      = Join-Path $PSScriptRoot 'last-run.log'
$script:SettingsFile = Join-Path $PSScriptRoot 'settings.json'

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
                    -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
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
        # Запоминать положение окон для каждой раскладки столов и возвращать их
        # обратно при возврате к ней (WindowLayout.ps1).
        restoreWindows  = $true
        # Автоматический игровой режим. Своего элемента в окне настроек нет
        # намеренно: настройка редкая и правится руками в settings.json.
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
            if ($null -ne $raw.layout)          { $s.layout          = @($raw.layout | ForEach-Object { [string]$_ }) }
            if ($null -ne $raw.primary)         { $s.primary         = [string]$raw.primary }
            if ($raw.hotkeys) {
                foreach ($p in $raw.hotkeys.PSObject.Properties) { $s.hotkeys[$p.Name] = [string]$p.Value }
            }
            # Поле за полем, а не присваиванием объекта целиком: в файле может
            # лежать половина ключей (его правят руками), и остальные обязаны
            # остаться дефолтными, а не превратиться в $null.
            if ($raw.autoGame) {
                if ($null -ne $raw.autoGame.enabled)  { $s.autoGame.enabled  = [bool]$raw.autoGame.enabled }
                if ($null -ne $raw.autoGame.process)  { $s.autoGame.process  = [string]$raw.autoGame.process }
                if ($null -ne $raw.autoGame.gameMode) { $s.autoGame.gameMode = [string]$raw.autoGame.gameMode }
                if ($null -ne $raw.autoGame.backMode) { $s.autoGame.backMode = [string]$raw.autoGame.backMode }
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
# Все четыре класса живут в ОДНОМ исходнике и компилируются одним вызовом.
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

    public const uint QDC_ALL_PATHS = 1;
    public const uint QDC_ONLY_ACTIVE_PATHS = 2;

    public const uint GET_SOURCE_NAME = 1;
    public const uint GET_TARGET_NAME = 2;
    public const uint GET_TARGET_PREFERRED_MODE = 3;

    public const uint PATH_ACTIVE = 0x00000001;
    public const uint MODE_IDX_INVALID = 0xFFFFFFFF;
    public const uint MODE_INFO_TYPE_SOURCE = 1;

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
    $refs = @('System.Windows.Forms')
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
function Set-CcdTopology {
    param([Parameter(Mandatory)][string[]]$DevicePaths)

    $want = @{}
    foreach ($p in $DevicePaths) { if ($p) { $want[$p] = $true } }
    # Пустой набор — это чёрный экран. Такого запроса просто не бывает, но цена
    # ошибки здесь такая, что проверка стоит одной строки.
    if ($want.Count -eq 0) { return $false }

    $np = 0; $nm = 0
    if ([NativeCcd]::GetDisplayConfigBufferSizes([NativeCcd]::QDC_ALL_PATHS, [ref]$np, [ref]$nm) -ne 0) { return $false }
    $paths = New-Object 'NativeCcd+PATH_INFO[]' $np
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $nm
    if ([NativeCcd]::QueryDisplayConfig([NativeCcd]::QDC_ALL_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) { return $false }

    # QDC_ALL_PATHS отдаёт все сочетания «источник x цель». Берём по одному пути
    # на монитор со свободным источником: два монитора на одном источнике — это
    # клон, а нужно расширение. Уже активный путь предпочтительнее — меньше
    # перестроений.
    $chosen = @()
    $usedSources = @{}
    $covered = @{}

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
            $chosen += $i
        }
    }

    $missing = @($want.Keys | Where-Object { -not $covered.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        Write-DisplayLog ("ccd: no usable path for {0} display(s)" -f $missing.Count)
    }
    if ($chosen.Count -eq 0) { return $false }

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

function Set-CcdLayout {
    param([string]$PrimaryPath, [string[]]$Order = @())

    $np = 0; $nm = 0
    if ([NativeCcd]::GetDisplayConfigBufferSizes([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, [ref]$nm) -ne 0) {
        Write-DisplayLog 'warn: layout - could not size the display config buffers'
        return (New-LayoutResult -Ok $false -Changed $false)
    }
    $paths = New-Object 'NativeCcd+PATH_INFO[]' $np
    $modes = New-Object 'NativeCcd+MODE_INFO[]' $nm
    if ([NativeCcd]::QueryDisplayConfig([NativeCcd]::QDC_ONLY_ACTIVE_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) {
        Write-DisplayLog 'warn: layout - QueryDisplayConfig refused'
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
        Write-DisplayLog 'warn: layout - no active screens to arrange'
        return (New-LayoutResult -Ok $false -Changed $false)
    }

    if ($Order -and $Order.Count -gt 0) {
        # Место в списке: сравниваем по вхождению, чтобы «UltraGear» находил
        # «LG ULTRAGEAR» и наоборот — названия у системы короче человеческих.
        foreach ($s in $screens) {
            $rank = $Order.Count
            for ($k = 0; $k -lt $Order.Count; $k++) {
                $o = $Order[$k]
                if (-not $o) { continue }
                if ($s.Label -like ('*' + $o + '*') -or $o -like ('*' + $s.Label + '*')) { $rank = $k; break }
            }
            $s | Add-Member -NotePropertyName Rank -NotePropertyValue $rank -Force
        }
        $ordered = @($screens | Sort-Object Rank, Label)

        $tallest = ($ordered | Measure-Object -Property Height -Maximum).Maximum
        $x = 0
        foreach ($s in $ordered) {
            $m = $modes[$s.ModeIdx]
            $m.srcPosX = $x
            $m.srcPosY = [int](($tallest - $s.Height) / 2)
            $modes[$s.ModeIdx] = $m
            $x += $s.Width
        }
    }

    # Сдвигаем всё так, чтобы основной оказался в (0,0).
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
        Write-DisplayLog "ccd: layout validate -> $rc"
        return (New-LayoutResult -Ok $false -Changed $false)
    }
    $rc = [NativeCcd]::SetDisplayConfig($np, $paths, $nm, $modes,
        ($base -bor [NativeCcd]::SDC_APPLY -bor [NativeCcd]::SDC_SAVE_TO_DATABASE))
    if ($rc -ne 0) {
        Write-DisplayLog "ccd: layout apply -> $rc"
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

function Get-MonitorRole {
    param([string]$ShortId, [string]$Label)

    if ($ShortId -match '^AUS' -or $Label -match 'ROG|ASUS|XG\d') { return 'game' }
    if ($ShortId -match '^GSM' -or $Label -match '\bLG\b')        { return 'work' }
    return 'other'
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
            Role         = Get-MonitorRole $t.ShortId $label
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
    param($State)

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
    }
    return $changed
}

function Get-ModeMembers {
    param($Mode, $State)

    $usable = @($State | Where-Object { -not $_.Disconnected })
    switch ($Mode.Kind) {
        'all'  { return $usable }
        'role' { return @($usable | Where-Object { $_.Role -eq $Mode.Role }) }
        # По полному Monitor ID, а не по короткому: короткий — это модель, и у
        # двух одинаковых мониторов он один на двоих.
        'solo' { return @($usable | Where-Object { $_.Id -eq $Mode.Id }) }
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
        # Dispose обязателен и здесь: в трее процесс живёт неделями, и каждое
        # пропущенное переключение оставляло за собой дескриптор ядра.
        $mutex.Dispose()
        return [pscustomobject]@{ Mode = $ModeKey; Skipped = $true; Message = 'A switch is already in progress.' }
    }

    # Длительность переключения пишется в итоговый done: и остаётся там навсегда.
    # Три строки кода дают постоянный контроль регрессий скорости прямо в журнале:
    # разбор «стало медленнее» без цифр за прошлые недели невозможен.
    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        Write-DisplayLog "--- start mode=$ModeKey primaryMatch='$PrimaryMatch' keepMode=$KeepMode dryRun=$DryRun"

        # Настройки читаем РОВНО один раз на переключение. Раньше
        # Get-DisplaySettings вызывался до трёх раз (предпочтение primary,
        # запасной primary по layout, сама раскладка) — три чтения диска и, что
        # хуже, возможность взять разные версии файла внутри одного переключения,
        # если его правят в этот момент из окна настроек.
        $settings = Get-DisplaySettings

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
            $primary = $wanted | Where-Object { $_.Label -match [regex]::Escape($PrimaryMatch) } | Select-Object -First 1
            if (-not $primary) { throw "-PrimaryMatch '$PrimaryMatch' matched none of the displays in '$($mode.Title)'." }
        }

        # Предпочтение из настроек — мягкое: если этого монитора в режиме нет,
        # молча идём дальше. Без него основным оставался тот, кто им был раньше,
        # и панель задач переезжала от переключения к переключению непредсказуемо.
        if (-not $primary) {
            $prefer = [string]$settings.primary
            if ($prefer) {
                $primary = $wanted | Where-Object { $_.Label -like ('*' + $prefer + '*') } | Select-Object -First 1
            }
        }
        if (-not $primary) { $primary = $wanted | Where-Object { $_.Primary } | Select-Object -First 1 }

        # Последний довод — самый правый по физической раскладке: у стола есть
        # «главная» сторона, и случайный выбор по порядку опроса ей не помогает.
        if (-not $primary) {
            $order = @($settings.layout)
            if ($order.Count -gt 0) {
                for ($k = $order.Count - 1; $k -ge 0; $k--) {
                    $primary = $wanted | Where-Object { $_.Label -like ('*' + $order[$k] + '*') } | Select-Object -First 1
                    if ($primary) { break }
                }
            }
        }
        if (-not $primary) { $primary = $wanted | Select-Object -First 1 }

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

                if (-not (Set-CcdTopology -DevicePaths $wantedIds)) {
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
        if ($order.Count -gt 0) {
            $laid = Set-CcdLayout -PrimaryPath $primary.Id -Order $order
            # Пишем «arranged» только когда действительно расставляли. Раньше
            # строка уходила в журнал при любом успехе, и после granular-skip'а
            # получалась пара «already correct» + «arranged left to right» — вторая
            # строка отчитывалась о работе, которой не было.
            if ($laid.Ok -and $laid.Changed) {
                Write-DisplayLog ("layout: arranged left to right - " + ($order -join ' | '))
            }
            elseif ($laid.Ok) {
                Write-DisplayLog 'layout: already correct'
            }
        }

        # Режим выставляем последним, когда набор активных мониторов уже
        # окончательный: и назначение основного, и гашение соседа сбрасывают
        # частоту на то, что записано в реестре, а там она часто ниже родной.
        # Каждый монитор ждём отдельно — иначе он не успевает прицепиться, и
        # установка режима вместе со сводкой пропадают вообще без следа.
        $summary = @()
        $failed = @()
        foreach ($m in $wanted) {
            $output = Get-CcdOutput -DevicePath $m.Id
            if (-not $output) {
                # Раньше здесь стоял continue, и монитор просто исчезал из сводки.
                # Получался рапорт об успехе при чёрном экране: в журнале
                # «did not attach» и следом пустое «done:», а человек в этот
                # момент смотрел на погасший стол.
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
            $cur = Get-CurrentMode $output
            $summary += $(if ($cur) { '{0} {1}x{2} @ {3} Hz' -f $m.Label, $cur.Width, $cur.Height, $cur.Hz } else { $m.Label })
        }

        $text = ($summary -join ', ')
        if ($failed.Count -gt 0) {
            $part = 'did not come up: ' + ($failed -join ', ') + ' - unplug the cable and plug it back in'
            $text = $(if ($text) { $text + '. ' + $part } else { $part })
        }
        # Об отказе гасить говорим прямо в сводке: иначе выходит рапорт об успехе
        # при том, что на столе осталось больше экранов, чем просили.
        if ($refused -and $refused.Count -gt 0) {
            $text += ('. Still on: ' + ($refused -join ', ') + ' - Windows would not turn them off')
        }
        # Форматируем через InvariantCulture: журнал английский, а `-f` берёт
        # разделитель из текущей локали и на русской писал бы «4,2 s».
        $took = $watch.Elapsed.TotalSeconds.ToString('0.0', [cultureinfo]::InvariantCulture)
        Write-DisplayLog ("done: {0} ({1} s)" -f $text, $took)

        # Окна раскладываем последними: и смена режима, и назначение основного
        # монитора двигают их сами, поэтому раньше это делать бессмысленно.
        # $doWindows выставлен только если топология действительно менялась —
        # при повторном нажатии окна не трогаем вообще.
        if ($doWindows) {
            try { Restore-WindowLayout -Key (Get-DisplayLayoutKey -DevicePaths $wantedIds) }
            catch { Write-DisplayLog "warn: windows - restoring failed: $($_.Exception.Message)" }
        }
        return [pscustomobject]@{
            Mode = $ModeKey; Skipped = $false; Message = $text
            Refused = $refused; Failed = $failed
            Seconds = $watch.Elapsed.TotalSeconds
            Ok = ($failed.Count -eq 0 -and (-not $refused -or $refused.Count -eq 0))
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
