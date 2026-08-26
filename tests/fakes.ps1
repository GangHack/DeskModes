<#
    tests\fakes.ps1 — подделки, которые нужны больше чем одной группе случаев.

    Тесты не должны зависеть от того, что сейчас на столе, и не должны
    показывать окон. Всё, что нужно только одной группе, живёт в её файле в
    cases/ — здесь только общее.
#>

# Фиктивные мониторы: тесты не должны зависеть от того, что сейчас на столе.
# Поля ровно те, что отдаёт Get-DisplayState: фальшивка не должна знать о полях,
# которых у настоящего состояния нет.
function New-FakeMonitor {
    param([string]$Label, [string]$ShortId, [string]$Id = '',
          [bool]$Active = $true, [bool]$Disconnected = $false)
    if (-not $Id) { $Id = 'path-' + $Label + '-' + $ShortId }
    return [pscustomobject]@{
        Output = '\\.\DISPLAY1'; Label = $Label; Model = $Label; ShortId = $ShortId
        Native = $null; Id = $Id; Active = $Active
        Primary = $false; Disconnected = $Disconnected
        Width = 2560; Height = 1440; Hz = 144; BestMode = $null
    }
}

# Настройки с комбинациями, одной строкой: их пишет почти каждый тест.
function New-TestSettings {
    param([hashtable]$Combos = @{})
    $s = Get-DefaultSettings
    foreach ($name in $Combos.Keys) {
        $v = $Combos[$name]
        $displays = @()
        $primary = ''
        if ($v -is [array]) { $displays = @($v) }
        elseif ($v -is [hashtable]) { $displays = @($v.displays); $primary = [string]$v.primary }
        else { $displays = @([string]$v) }
        $s.combos[$name] = [ordered]@{ displays = $displays; primary = $primary }
    }
    return $s
}

# Экран для расчёта раскладки: только те поля, по которым считают позиции.
function New-FakeScreen {
    param([string]$Path, [string]$Label, [int]$Width, [int]$Height)
    return [pscustomobject]@{ DevicePath = $Path; Label = $Label; Width = $Width; Height = $Height }
}

# Стол по умолчанию для окна настроек и его редакторов: два монитора, и обоих
# хватает всем четырём группам, которые окно проверяют.
$script:DlgState = @(
    (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
    (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf')
)

function New-DialogUi {
    param($Settings, $State)
    if ($null -eq $State) { $State = $script:DlgState }
    $modes = @(Get-DialogModes -State $State -Settings $Settings)
    return New-SettingsWindow -Modes $modes -Settings $Settings -State $State
}
