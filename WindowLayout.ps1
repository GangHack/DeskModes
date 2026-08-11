<#
    WindowLayout.ps1 — окна помнят свои места для каждой раскладки столов.

    README честно признавал дыру: смена набора мониторов сдвигает окна, и обратно
    они сами не раскладываются. Это ограничение Windows, а не тулзы — но снять
    снимок до перестроения и вернуть его после вполне можно.

    Подключается из точек входа (Displays.ps1, Set-Display.ps1), а НЕ из
    DisplayCore.ps1: core остаётся «только определения» и ничего про окна не знает.
    Switch-DisplayMode вызывает эти функции, только если они определены, — поэтому
    core работает и без этого файла.

    Ключ снимка — раскладка СТОЛОВ, а не название режима: отсортированные пути
    активных мониторов, склеенные через '|'. Два разных режима с одинаковым набором
    экранов (пока ASUS не воткнут, «оба LG» и «все» — это один набор) обязаны
    делить один снимок, иначе окна возвращались бы через раз.

    Хранилище — window-state.json рядом со скриптами. HWND действительны в рамках
    одного входа в Windows и одинаковы для всех процессов, поэтому снимок,
    снятый из CLI, годится трею и наоборот. При старте трея записи с мёртвыми
    процессами вычищаются.
#>

$script:WindowStateFile = Join-Path $PSScriptRoot 'window-state.json'

# Ключ раскладки столов по состоянию мониторов (или по готовому списку путей).
function Get-DisplayLayoutKey {
    param($State, [string[]]$DevicePaths)

    $paths = $DevicePaths
    if (-not $paths) {
        $paths = @($State | Where-Object { $_.Active } | ForEach-Object { $_.Id })
    }
    $clean = @($paths | Where-Object { $_ } | Sort-Object)
    if ($clean.Count -eq 0) { return '' }
    return ($clean -join '|')
}

function Get-WindowStateStore {
    if (-not (Test-Path $script:WindowStateFile)) { return @{} }
    try {
        $raw = Get-Content $script:WindowStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $store = @{}
        foreach ($p in $raw.PSObject.Properties) { $store[$p.Name] = $p.Value }
        return $store
    }
    catch {
        # Испорченный файл — это неприятность, а не поломка: снимки наживаются
        # заново за одно переключение. Настройки в такой ситуации сохраняют копию,
        # здесь это не нужно.
        Write-DisplayLog "windows: state file is damaged, starting over - $($_.Exception.Message)"
        return @{}
    }
}

function Save-WindowStateStore {
    param($Store)
    try {
        $Store | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $script:WindowStateFile -Encoding UTF8
        return $true
    }
    catch {
        Write-DisplayLog "warn: windows - could not write the state file: $($_.Exception.Message)"
        return $false
    }
}

# Снять положение всех пользовательских окон и запомнить под ключом раскладки.
function Save-WindowLayout {
    param([Parameter(Mandatory)][string]$Key)

    if (-not $Key) { Write-DisplayLog 'warn: windows - no layout key, nothing saved'; return }

    try {
        $wins = @([NativeWindows]::Enumerate())
    }
    catch {
        Write-DisplayLog "warn: windows - could not enumerate: $($_.Exception.Message)"
        return
    }
    if ($wins.Count -eq 0) { Write-DisplayLog 'windows: nothing to save, no ordinary windows on the desktop'; return }

    $list = @()
    foreach ($w in $wins) {
        $list += [ordered]@{
            hwnd    = [int64]$w.Hwnd
            pid     = $w.Pid
            path    = $w.Path
            title   = $w.Title
            showCmd = $w.ShowCmd
            n       = @($w.NL, $w.NT, $w.NR, $w.NB)
            mn      = @($w.MinX, $w.MinY)
            mx      = @($w.MaxX, $w.MaxY)
        }
    }

    $store = Get-WindowStateStore
    $store[$Key] = [ordered]@{
        saved   = (Get-Date).ToString('s')
        windows = $list
    }
    if (Save-WindowStateStore $store) {
        Write-DisplayLog ("windows: saved {0} for {1}" -f $list.Count, (Format-LayoutKey $Key))
    }
}

# Вернуть окна на места, запомненные для этой раскладки.
function Restore-WindowLayout {
    param([Parameter(Mandatory)][string]$Key)

    if (-not $Key) { Write-DisplayLog 'warn: windows - no layout key, nothing restored'; return }

    $store = Get-WindowStateStore
    if (-not $store.ContainsKey($Key)) {
        # Не ошибка: этой раскладки ещё не видели. Снимок появится, когда с неё
        # будут уходить.
        Write-DisplayLog ("windows: no snapshot for {0} yet" -f (Format-LayoutKey $Key))
        return
    }

    $saved = @($store[$Key].windows)
    if ($saved.Count -eq 0) { Write-DisplayLog 'windows: snapshot is empty'; return }

    $done = 0
    $gone = 0
    $refused = 0
    foreach ($w in $saved) {
        $h = [IntPtr][int64]$w.hwnd
        # Живо ли окно и то ли это окно. HWND переиспользуются: номер закрытого
        # окна система может выдать другому, поэтому одной проверки IsWindow мало
        # — сверяем ещё и процесс. Иначе снимок Firefox однажды переставил бы
        # чужое окно, оказавшееся на том же номере.
        if (-not [NativeWindows]::IsWindow($h)) { $gone++; continue }
        if ([NativeWindows]::PidOfWindow($h) -ne [int]$w.pid) { $gone++; continue }

        $n = @($w.n); $mn = @($w.mn); $mx = @($w.mx)
        $ok = $false
        try {
            $ok = [NativeWindows]::ApplyPlacement($h, [int]$w.showCmd,
                    [int]$n[0], [int]$n[1], [int]$n[2], [int]$n[3],
                    [int]$mn[0], [int]$mn[1], [int]$mx[0], [int]$mx[1])
        }
        catch { $ok = $false }
        if ($ok) { $done++ } else { $refused++ }
    }

    # Считаем честно: сколько вернули из скольких, и сколько окон уже нет. Отказы
    # (окно живо, а SetWindowPlacement его не пустил — так бывает у окон с правами
    # выше наших) показываем отдельно, чтобы не выглядело «пропало».
    $line = "windows: restored {0} of {1}" -f $done, $saved.Count
    $tail = @()
    if ($gone -gt 0)    { $tail += "$gone gone" }
    if ($refused -gt 0) { $tail += "$refused refused" }
    if ($tail.Count -gt 0) { $line += ' (' + ($tail -join ', ') + ')' }
    Write-DisplayLog $line
}

# Ключ в журнале — это три длинных пути устройств; читать невозможно. Для
# журнала сокращаем до количества экранов, а сам ключ и так лежит в json.
function Format-LayoutKey {
    param([string]$Key)
    if (-not $Key) { return '(none)' }
    $n = @($Key -split '\|').Count
    return ("a {0}-display layout" -f $n)
}

# Записи, все процессы которых уже мертвы, держать незачем: HWND из прошлого
# входа в Windows не значат ничего. Вызывается при старте трея.
function Remove-DeadWindowLayouts {
    if (-not (Test-Path $script:WindowStateFile)) { return }

    $store = Get-WindowStateStore
    if ($store.Count -eq 0) { return }

    $alive = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $alive[$p.Id] = $true }

    $dropped = 0
    foreach ($key in @($store.Keys)) {
        $wins = @($store[$key].windows)
        $live = @($wins | Where-Object { $alive.ContainsKey([int]$_.pid) })
        if ($live.Count -eq 0) { $store.Remove($key); $dropped++ }
    }
    if ($dropped -gt 0) {
        [void](Save-WindowStateStore $store)
        Write-DisplayLog ("windows: dropped {0} stale snapshot(s) from a previous session" -f $dropped)
    }
}
