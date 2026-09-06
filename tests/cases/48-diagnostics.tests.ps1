# Diagnostic exports are intentionally narrower than the display state and settings objects.
# Loading here keeps a missing optional formatter visible as a normal failed case during development.

Test-Case 'diagnostics: JSON carries the published schema version and display fields' {
    if (Test-Path -LiteralPath (Join-Path $root 'Diagnostics.ps1')) { . (Join-Path $root 'Diagnostics.ps1') }
    $panel = New-FakeMonitor -Label 'Friendly alias' -ShortId 'PNL1234' -Id 'private-path'
    $panel.Model = 'Panel "quoted" \ connector'
    $panel.Primary = $true
    $json = Format-DisplayDiagnostics -State @($panel)
    $payload = $json | ConvertFrom-Json

    Assert-True ($json -is [string]) 'the formatter returns one JSON string'
    Assert-Equal @('displays', 'powershell', 'schema', 'version', 'windows') @($payload.PSObject.Properties.Name | Sort-Object) 'the top level is allowlisted'
    Assert-Equal 1 $payload.schema 'the export schema is explicit'
    Assert-Equal (Get-VersionName) $payload.version 'the export uses the application version source'
    Assert-True ($payload.windows -is [string] -and $payload.windows.Length -gt 0) 'Windows is identified'
    Assert-True ($payload.powershell -is [string] -and $payload.powershell.Length -gt 0) 'PowerShell is identified'
    Assert-True ($payload.displays -is [array]) 'one display is still an array'
    Assert-Equal 1 @($payload.displays).Count 'one display round-trips'
    $display = $payload.displays[0]
    Assert-Equal @('active', 'connected', 'height', 'hz', 'model', 'monitorId', 'primary', 'width') @($display.PSObject.Properties.Name | Sort-Object) 'only approved display fields leave the formatter'
    Assert-Equal $panel.Model $display.model 'quotes and backslashes in the raw model survive JSON escaping'
    Assert-Equal 'PNL1234' $display.monitorId 'only the model ID is included'
    Assert-True ($display.active -and $display.primary -and $display.connected) 'the display state survives'
}

Test-Case 'diagnostics: no displays serialize as an empty array' {
    if (Test-Path -LiteralPath (Join-Path $root 'Diagnostics.ps1')) { . (Join-Path $root 'Diagnostics.ps1') }
    $payload = Format-DisplayDiagnostics -State @() | ConvertFrom-Json
    Assert-True ($payload.displays -is [array]) 'the JSON field is an array rather than null'
    Assert-Equal 0 @($payload.displays).Count 'the array is empty'
}

Test-Case 'diagnostics: numeric display values remain JSON numbers under a comma decimal culture' {
    if (Test-Path -LiteralPath (Join-Path $root 'Diagnostics.ps1')) { . (Join-Path $root 'Diagnostics.ps1') }
    $panel = New-FakeMonitor -Label 'Panel' -ShortId 'PNL1234' -Active $false -Disconnected $true
    $panel.Width = 3840; $panel.Height = 2160; $panel.Hz = 144
    $previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo('fr-FR')
        $payload = Format-DisplayDiagnostics -State @($panel) | ConvertFrom-Json
        $display = $payload.displays[0]
        Assert-Equal 3840 $display.width 'width remains numeric'
        Assert-Equal 2160 $display.height 'height remains numeric'
        Assert-Equal 144 $display.hz 'refresh rate remains numeric'
        Assert-True ($display.width -isnot [string] -and $display.height -isnot [string] -and $display.hz -isnot [string]) 'numbers are not formatted strings'
        Assert-True (-not $display.connected -and -not $display.active) 'a disconnected display is reported honestly'
    }
    finally { [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture }
}

Test-Case 'diagnostics: sensitive extra properties cannot escape through the display state' {
    if (Test-Path -LiteralPath (Join-Path $root 'Diagnostics.ps1')) { . (Join-Path $root 'Diagnostics.ps1') }
    $panel = New-FakeMonitor -Label 'PRIVATE-FRIENDLY-ALIAS' -ShortId 'PNL1234' -Id 'PRIVATE-DEVICE-PATH'
    $panel.Model = 'Public panel model'
    $panel | Add-Member -NotePropertyName Process -NotePropertyValue 'PRIVATE-PROCESS-NAME'
    $panel | Add-Member -NotePropertyName WindowTitle -NotePropertyValue 'PRIVATE-WINDOW-TITLE'
    $panel | Add-Member -NotePropertyName Settings -NotePropertyValue @{ hooks = @{ after = 'PRIVATE-HOOK-COMMAND' } }
    # The caller supplies all display data; formatting must not query the desk, files or clipboard.
    function Get-DisplayState { throw 'Diagnostics formatting must not query hardware.' }
    function Get-Content {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped side-effect guard proves diagnostics formatting does not access files or the clipboard.')]
        param()
        throw 'Diagnostics formatting must not read files.' }
    function Set-Content {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped side-effect guard proves diagnostics formatting does not access files or the clipboard.')]
        param()
        throw 'Diagnostics formatting must not write files.' }
    function Set-Clipboard {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped side-effect guard proves diagnostics formatting does not access files or the clipboard.')]
        param()
        throw 'Diagnostics formatting must not write the clipboard.' }
    $json = Format-DisplayDiagnostics -State @($panel)
    Assert-True (-not $json.Contains('PRIVATE-')) 'none of the unapproved data is serialized'
    $display = ($json | ConvertFrom-Json).displays[0]
    Assert-Equal 'Public panel model' $display.model 'the manufacturer model is retained instead of the custom alias'
}

Test-Case 'diagnostics: a nameless monitor device path cannot escape through the model fallback' {
    if (Test-Path -LiteralPath (Join-Path $root 'Diagnostics.ps1')) { . (Join-Path $root 'Diagnostics.ps1') }
    # A nameless CCD target falls back to DevicePath for both Label and Model in the state builder.
    $devicePath = '\\?\DISPLAY#PRIVATE-DEVICE-PATH#UNIQUE-INSTANCE'
    $nameless = New-FakeMonitor -Label $devicePath -ShortId '' -Id $devicePath
    $normal = New-FakeMonitor -Label 'Friendly alias' -ShortId 'PNL1234' -Id 'another-private-path'
    $normal.Model = 'Public manufacturer model'
    $json = Format-DisplayDiagnostics -State @($nameless, $normal)
    $payload = $json | ConvertFrom-Json

    Assert-True (-not $json.Contains('PRIVATE-DEVICE-PATH')) 'the fallback path remains private even in an approved field'
    Assert-Equal 'Public manufacturer model' $payload.displays[1].model 'ordinary manufacturer names are retained'
    Assert-Equal 2 @($payload.displays).Count 'the nameless display still contributes its safe state fields'
}
