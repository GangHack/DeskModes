#Requires -Version 5.1

# A support report is an allowlist, not a scrubbed copy of settings or the log. Hooks can contain
# secrets, paths can name the user, and the diary records personal activity. None is read here.
# The caller supplies its display snapshot; formatting cannot query or change the real desk.
function Format-DisplayDiagnostics {
    param($State)

    $displays = @(foreach ($m in @($State)) {
        if (-not $m) { continue }
        # A nameless target falls back to its device path in Get-DisplayState. An allowed
        # property name alone therefore does not make its contents safe to share.
        $model = [string]$m.Model
        if (($model -and ($model -eq [string]$m.Id -or $model -eq [string]$m.DevicePath)) -or
            $model.StartsWith('\\', [StringComparison]::Ordinal)) { $model = '' }
        [ordered]@{
            model = $model
            monitorId = [string]$m.ShortId
            active = [bool]$m.Active
            primary = [bool]$m.Primary
            connected = (-not [bool]$m.Disconnected)
            width = [int]$m.Width
            height = [int]$m.Height
            hz = [double]$m.Hz
        }
    })
    return ([ordered]@{
        schema = 1
        version = (Get-VersionName)
        windows = [string][Environment]::OSVersion.Version
        powershell = [string]$PSVersionTable.PSVersion
        displays = $displays
    } | ConvertTo-Json -Depth 4)
}
