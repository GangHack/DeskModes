# Identical models must remain distinct when Windows changes enumeration order or removes a target.
# These checks use the real mode builder and editor, with fictional monitors and no hardware calls.

Test-Case 'display identity: reversing identical monitors does not reassign their solo keys' {
    $left = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-a'
    $right = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-b'
    $settings = New-TestSettings
    $before = @(Get-DisplayModes -State @($left, $right) -Settings $settings | Where-Object { $_.Kind -eq 'solo' })
    $after = @(Get-DisplayModes -State @($right, $left) -Settings $settings | Where-Object { $_.Kind -eq 'solo' })

    Assert-Equal 2 @($before.Key | Select-Object -Unique).Count 'each instance has its own key'
    foreach ($mode in $before) {
        $sameKey = @($after | Where-Object { $_.Key -eq $mode.Key })
        Assert-Equal @($mode.Id) @($sameKey.Id) 'the shortcut still names the same physical target'
    }
}

Test-Case 'display identity: fingerprinted labels have short stable visible titles' {
    $left = New-FakeMonitor -Label 'Acer XV272U {0123456789abcdef}' -ShortId 'ACR1234' -Id 'path-acer-left'
    $right = New-FakeMonitor -Label 'Acer XV272U {fedcba9876543210}' -ShortId 'ACR1234' -Id 'path-acer-right'

    Assert-Equal 'Acer XV272U · 012345' (Get-DisplayTitle -Label $left.Label) 'the stable selector is shortened for a person'
    Assert-Equal 'Acer XV272U · FEDCBA' (Get-DisplayTitle -Label $right.Label) 'the twins remain visibly distinct'

    $modes = @(Get-DisplayModes -State @($right, $left) -Settings (New-TestSettings) | Where-Object { $_.Kind -eq 'solo' })
    Assert-Equal 'Only Acer XV272U · 012345' (($modes | Where-Object { $_.Id -eq $left.Id }).Title) 'the mode uses the visible title'
    Assert-Equal 'Only Acer XV272U · FEDCBA' (Get-ModeTitleFromKey ('solo:' + $right.Label)) 'a saved key gets the same title without a live state'
    Assert-Equal ('solo:' + $left.Label) (($modes | Where-Object { $_.Id -eq $left.Id }).Key) 'the full fingerprint remains the selector'
}

Test-Case 'display identity: a remaining identical monitor keeps its solo key' {
    $oldRosterPath = $script:KnownDisplaysFile
    $script:KnownDisplaysFile = Join-Path $script:TestDir 'identity-survivor-roster.json'
    try {
        $left = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-a'
        $right = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-b'
        $settings = New-TestSettings
        [void](Update-KnownDisplays -State @($left, $right))
        $before = @(Get-DisplayModes -State @($left, $right) -Settings $settings | Where-Object { $_.Kind -eq 'solo' })

        foreach ($remaining in @($left, $right)) {
            $original = $before | Where-Object { $_.Id -eq $remaining.Id }
            $fresh = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id $remaining.Id
            $desk = @(Get-DeskDisplays -State @($fresh))
            $after = @(Get-DisplayModes -State $desk -Settings $settings | Where-Object { $_.Kind -eq 'solo' -and $_.Available })
            Assert-Equal @($original.Key) @($after.Key) 'unplugging its twin does not orphan the shortcut'
        }
    }
    finally { $script:KnownDisplaysFile = $oldRosterPath }
}

Test-Case 'display identity: saving one identical monitor in a combination selects only that instance' {
    $left = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-a'
    $right = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-b'
    $state = @($left, $right)
    $editor = New-ModeEditorWindow -Mode $null -Combo $null -State $state -Dark $false
    try {
        $editor.NameBox.Text = 'Right only'
        foreach ($check in $editor.Checks) { $check.IsChecked = $false }
        # The member controls follow the supplied desk order; choose the second physical display.
        $editor.Checks[1].IsChecked = $true
        $saved = Read-ModeFromUi -Editor $editor
        Assert-True $saved.Ok 'the editor accepts the selection'
        $settings = New-TestSettings -Combos @{ 'Right only' = @{ displays = @($saved.Mode.Patterns); primary = '' } }

        foreach ($desk in @(@($left, $right), @($right, $left))) {
            $mode = Get-DisplayModes -State $desk -Settings $settings | Where-Object { $_.Key -eq 'combo:Right only' }
            $members = @(Get-ModeMembers -Mode $mode -State $desk)
            Assert-Equal @($right.Id) @($members.Id) 'the saved selection survives enumeration changes'
        }
        $mode = Get-DisplayModes -State @($left) -Settings $settings | Where-Object { $_.Key -eq 'combo:Right only' }
        Assert-Equal 0 @(Get-ModeMembers -Mode $mode -State @($left)).Count 'the other twin cannot replace an absent member'
        Assert-True (-not $mode.Available) 'the combination reports its selected display as unavailable'

        $reopened = New-ModeEditorWindow -Mode $mode -Combo $saved.Mode -State $state -Dark $false
        try {
            Assert-Equal 1 @($reopened.Checks | Where-Object { $_.IsChecked }).Count 'reopening does not tick both twins'
            Assert-True $reopened.Checks[1].IsChecked 'the selected instance stays ticked'
        }
        finally { $reopened.Window.Close() }
    }
    finally { $editor.Window.Close() }
}

Test-Case 'display identity: the roster preserves both identical monitors after a fresh singleton read' {
    $oldRosterPath = $script:KnownDisplaysFile
    $script:KnownDisplaysFile = Join-Path $script:TestDir 'identity-roster.json'
    try {
        $left = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-a'
        $right = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-b'
        [void](Update-KnownDisplays -State @($left, $right))
        $before = @(Get-DisplayModes -State @($left, $right) -Settings (New-TestSettings) | Where-Object { $_.Kind -eq 'solo' })

        # A new state object represents a later process: it cannot carry annotations from the pair.
        $fresh = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-a'
        $desk = @(Get-DeskDisplays -State @($fresh))
        Assert-Equal @($left.Id, $right.Id) @($desk.Id | Sort-Object) 'the roster remembers each instance independently'
        $after = @(Get-DisplayModes -State $desk -Settings (New-TestSettings) | Where-Object { $_.Kind -eq 'solo' })
        foreach ($original in $before) {
            $sameInstance = @($after | Where-Object { $_.Id -eq $original.Id })
            Assert-Equal @($original.Key) @($sameInstance.Key) 'both keys survive the fresh read'
        }
        $missing = @($desk | Where-Object { $_.Id -eq $right.Id })
        Assert-True ($missing.Count -eq 1 -and $missing[0].Disconnected) 'only the absent twin is marked disconnected'
    }
    finally { $script:KnownDisplaysFile = $oldRosterPath }
}

Test-Case 'display identity: a model and unique short ID migrate their shortcut to the same instance' {
    $left = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1111' -Id 'path-twin-a'
    $right = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN2222' -Id 'path-twin-b'
    $settings = New-TestSettings
    $oldKey = 'solo:Twin Panel TWN1111'
    $settings.hotkeys[$oldKey] = 'Ctrl+Alt+F1'
    $settings.audio[$oldKey] = 'Desk speakers'

    Assert-True (Update-HotkeyKeys -Settings $settings -State @($right, $left)) 'the unambiguous shortcut migrates'
    $target = Get-DisplayModes -State @($right, $left) -Settings $settings | Where-Object { $_.Kind -eq 'solo' -and $_.Id -eq $left.Id }
    Assert-Equal 'Ctrl+Alt+F1' $settings.hotkeys[$target.Key] 'the shortcut still addresses the original instance'
    Assert-Equal 'Desk speakers' $settings.audio[$target.Key] 'the settings bound to that shortcut follow it'
    Assert-True (-not $settings.hotkeys.Contains($oldKey)) 'the obsolete key is removed'
}

Test-Case 'display identity: an ambiguous model shortcut does not move to whichever twin remains' {
    $left = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-a'
    $right = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-b'
    $settings = New-TestSettings
    $oldKey = 'solo:Twin Panel'
    $settings.hotkeys[$oldKey] = 'Ctrl+Alt+F1'

    Assert-True (-not (Update-HotkeyKeys -Settings $settings -State @($left, $right))) 'the pair cannot resolve an ambiguous name'
    # Losing the original target does not make the remaining panel the owner of its old shortcut.
    Assert-True (-not (Update-HotkeyKeys -Settings $settings -State @($right))) 'disconnecting a twin cannot resolve that ambiguity'
    Assert-Equal @($oldKey) @($settings.hotkeys.Keys) 'the original binding stays available for an explicit reassignment'
}

Test-Case 'display identity: a shared short ID shortcut does not move to whichever twin remains' {
    $left = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-a'
    $right = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-b'
    $settings = New-TestSettings
    $oldKey = 'solo:TWN1234'
    $settings.hotkeys[$oldKey] = 'Ctrl+Alt+F1'

    Assert-True (-not (Update-HotkeyKeys -Settings $settings -State @($left, $right))) 'the model ID does not identify one twin'
    Assert-True (-not (Update-HotkeyKeys -Settings $settings -State @($right))) 'absence of the other twin adds no identity evidence'
    Assert-Equal @($oldKey) @($settings.hotkeys.Keys) 'the binding is retained without choosing a physical target'
}

Test-Case 'display identity: every mode setting can migrate without a shortcut' {
    $left = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1111' -Id 'path-twin-a'
    $right = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN2222' -Id 'path-twin-b'
    $state = @($left, $right)
    $oldKey = 'solo:Twin Panel TWN1111'
    $values = [ordered]@{
        audio = 'Desk speakers'
        hooks = [ordered]@{ before = ''; after = 'mode-ready.cmd' }
        brightness = 50
        contrast = 65
        picture = [ordered]@{ 'Twin Panel' = '0x15:45' }
        hdr = $false
    }
    foreach ($field in $values.Keys) {
        $settings = New-TestSettings
        $settings[$field][$oldKey] = $values[$field]
        Assert-True (Update-HotkeyKeys -Settings $settings -State $state) "$field alone triggers migration"
        $target = Get-DisplayModes -State $state -Settings $settings | Where-Object { $_.Kind -eq 'solo' -and $_.Id -eq $left.Id }
        Assert-Equal ($values[$field] | ConvertTo-Json -Compress) ($settings[$field][$target.Key] | ConvertTo-Json -Compress) "$field keeps its value"
        Assert-True (-not $settings[$field].Contains($oldKey)) "$field drops the obsolete key"
        Assert-Equal 0 $settings.hotkeys.Count 'a setting migration never invents a shortcut'
        Assert-True (-not (Update-HotkeyKeys -Settings $settings -State $state)) 'a completed migration reports no further change'
    }
}

Test-Case 'display identity: rule and reconnect references migrate without any mode settings' {
    $left = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1111' -Id 'path-twin-a'
    $right = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN2222' -Id 'path-twin-b'
    $state = @($left, $right)
    $oldKey = 'solo:Twin Panel TWN1111'
    $target = Get-DisplayModes -State $state -Settings (New-TestSettings) | Where-Object { $_.Kind -eq 'solo' -and $_.Id -eq $left.Id }
    foreach ($field in @('mode', 'back')) {
        $settings = New-TestSettings
        $rule = [ordered]@{ when = 'process'; process = 'editor'; mode = ''; back = ''; enabled = $true }
        $rule[$field] = $oldKey
        $settings.rules = @($rule)
        Assert-True (Update-HotkeyKeys -Settings $settings -State $state) "a rule's $field reference triggers migration"
        Assert-Equal $target.Key $settings.rules[0][$field] 'the rule still names the same instance'
        Assert-Equal 0 $settings.hotkeys.Count 'the rule needs no shortcut'
    }
    $settings = New-TestSettings
    $settings.reapply.onPlug = $oldKey
    Assert-True (Update-HotkeyKeys -Settings $settings -State $state) 'the reconnect action alone triggers migration'
    Assert-Equal $target.Key $settings.reapply.onPlug 'reconnecting still activates the intended instance'
    Assert-Equal 0 $settings.hotkeys.Count 'the reconnect action needs no shortcut'
}

Test-Case 'display identity: conflicting target settings survive while other references migrate' {
    $left = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1111' -Id 'path-twin-a'
    $right = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN2222' -Id 'path-twin-b'
    $state = @($left, $right)
    $oldKey = 'solo:Twin Panel TWN1111'
    $settings = New-TestSettings
    $target = Get-DisplayModes -State $state -Settings $settings | Where-Object { $_.Kind -eq 'solo' -and $_.Id -eq $left.Id }
    $settings.hotkeys[$oldKey] = 'Ctrl+Alt+F1'
    $settings.hotkeys[$target.Key] = 'Ctrl+Alt+F9'
    $settings.audio[$oldKey] = 'Old speakers'
    $settings.audio[$target.Key] = 'Chosen speakers'
    $settings.brightness[$oldKey] = 45
    $settings.rules = @([ordered]@{ when = 'process'; process = 'editor'; mode = $oldKey; back = ''; enabled = $true })

    Assert-True (Update-HotkeyKeys -Settings $settings -State $state) 'unconflicted preferences and references still migrate'
    Assert-Equal 'Ctrl+Alt+F9' $settings.hotkeys[$target.Key] 'the chosen target shortcut is never overwritten'
    Assert-Equal 'Ctrl+Alt+F1' $settings.hotkeys[$oldKey] 'the conflicting old shortcut remains available to edit'
    Assert-Equal 'Chosen speakers' $settings.audio[$target.Key] 'the chosen target audio is never overwritten'
    Assert-Equal 'Old speakers' $settings.audio[$oldKey] 'the conflicting source audio is retained'
    Assert-Equal 45 $settings.brightness[$target.Key] 'an unrelated preference is not blocked by the shortcut collision'
    Assert-Equal $target.Key $settings.rules[0].mode 'the rule points at a valid mode'
    Assert-True (-not (Update-HotkeyKeys -Settings $settings -State $state)) 'unresolved collisions alone are not reported as new writes'
}

Test-Case 'display identity: settings without shortcuts retain ambiguous model keys for explicit reassignment' {
    $left = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-a'
    $right = New-FakeMonitor -Label 'Twin Panel' -ShortId 'TWN1234' -Id 'path-twin-b'
    [void](Get-DisplayModes -State @($left, $right) -Settings (New-TestSettings))
    $settings = New-TestSettings
    $settings.brightness['solo:Twin Panel'] = 45
    Assert-True (-not (Update-HotkeyKeys -Settings $settings -State @($right))) 'a lone surviving twin cannot claim an ambiguous preference'
    Assert-Equal 45 $settings.brightness['solo:Twin Panel'] 'the original preference is not discarded'
}

Test-Case 'upgrade: exact device selectors never select a twin by its shared model ID' {
    $a = New-FakeMonitor -Label 'XV272U' -ShortId 'ACR06C1' -Id '\\?\DISPLAY#ACR06C1#sample&UID256#{guid}'
    $b = New-FakeMonitor -Label 'XV272U' -ShortId 'ACR06C1' -Id '\\?\DISPLAY#ACR06C1#sample&UID260#{guid}'
    $state = @($a,$b)
    Set-DisplayIdentity -State $state
    foreach ($panel in $state) {
        $selector = 'id:' + $panel.Id
        foreach ($candidate in $state) {
            $expected = $panel.Id -eq $candidate.Id
            Assert-Equal $expected (Test-DisplayNameMatch -Pattern $selector -Label $candidate.Label -ShortId $candidate.ShortId -Id $candidate.Id) 'full paths are exact'
            Assert-Equal $expected (Test-DisplayNameMatch -Pattern $selector -Label $candidate.Label -ShortId $candidate.ShortId) 'caption-only consumers compare the physical hash'
        }
        $settings=New-TestSettings
        $settings.combos['One Acer']=[ordered]@{displays=@($selector);primary=$selector}
        $mode=@(Get-DisplayModes -State $state -Settings $settings | Where-Object {$_.Key -eq 'combo:One Acer'})[0]
        Assert-Equal @($panel.Id) @(Get-ModeMembers -Mode $mode -State $state | ForEach-Object {$_.Id}) 'an imported single-panel group stays single'
        Assert-Equal $panel.Id (Select-PrimaryDisplay -Wanted @($b,$a) -ModePrimary $selector).Id 'the imported primary wins regardless of order'
    }
    Assert-Equal $false (Test-DisplayNameMatch -Pattern ('id:'+$a.Id) -Label $b.Label -ShortId $b.ShortId -Id $b.Id) 'an absent twin cannot select the survivor'
    Assert-True (Test-DisplayNameMatch -Pattern ('ID:'+$a.Id.ToUpperInvariant()) -Label 'Renamed Panel' -ShortId 'ACR06C1' -Id $a.Id) 'exact matching is case-insensitive and independent of captions'
    Assert-Equal $false (Test-DisplayNameMatch -Pattern 'id:' -Label $a.Label -ShortId $a.ShortId) 'an empty physical selector is not a model pattern'
}

Test-Case 'upgrade: UID captions migrate shortcuts and preferences to their physical Acer keys' {
    $a=New-FakeMonitor -Label 'XV272U' -ShortId 'ACR06C1' -Id '\\?\DISPLAY#ACR06C1#sample&UID256#{guid}'
    $b=New-FakeMonitor -Label 'XV272U' -ShortId 'ACR06C1' -Id '\\?\DISPLAY#ACR06C1#sample&UID260#{guid}'
    $settings=New-TestSettings
    $oldA='solo:XV272U · ACR06C1 · UID256'
    $oldB='solo:XV272U · ACR06C1 · UID260'
    $settings.hotkeys[$oldA]='Ctrl+Alt+F1'
    $settings.hotkeys[$oldB]='Ctrl+Alt+F2'
    $settings.audio[$oldA]='Speaker A'
    $settings.combos['2 ACER']=[ordered]@{displays=@(('id:'+$a.Id),('id:'+$b.Id));primary=('id:'+$a.Id)}
    $groupBefore=$settings.combos['2 ACER'] | ConvertTo-Json -Depth 5 -Compress
    Assert-True (Update-HotkeyKeys -Settings $settings -State @($b,$a)) 'the imported keys migrate'
    Assert-Equal 'Ctrl+Alt+F1' $settings.hotkeys[('solo:'+$a.Label)] 'F1 keeps UID256'
    Assert-Equal 'Ctrl+Alt+F2' $settings.hotkeys[('solo:'+$b.Label)] 'F2 keeps UID260'
    Assert-Equal 'Speaker A' $settings.audio[('solo:'+$a.Label)] 'non-hotkey preferences follow the same physical mapping'
    Assert-Equal $groupBefore ($settings.combos['2 ACER'] | ConvertTo-Json -Depth 5 -Compress) 'groups and exact primary are preserved'
    Assert-Equal $false (Update-HotkeyKeys -Settings $settings -State @($a,$b)) 'migration is idempotent'

    $missing=New-TestSettings
    $missing.hotkeys[$oldA]='Ctrl+Alt+F1'
    Assert-Equal $false (Update-HotkeyKeys -Settings $missing -State @($b)) 'absence cannot redirect F1 to UID260'
    Assert-Equal 'Ctrl+Alt+F1' $missing.hotkeys[$oldA] 'the unresolved original is retained'
    $b.Disconnected=$true
    Assert-True (Update-HotkeyKeys -Settings $missing -State @($a,$b)) 'remembered targets can retain their bindings'
}

Test-Case 'upgrade: ambiguous connection tokens and existing destination bindings are never overwritten' {
    $a=New-FakeMonitor -Label 'XV272U' -ShortId 'ACR06C1' -Id '\\?\DISPLAY#ACR06C1#adapterA&UID256#{guid}'
    $b=New-FakeMonitor -Label 'XV272U' -ShortId 'ACR06C1' -Id '\\?\DISPLAY#ACR06C1#adapterB&UID256#{guid}'
    $settings=New-TestSettings
    $old='solo:XV272U · ACR06C1 · UID256'
    $settings.hotkeys[$old]='Ctrl+Alt+F1'
    Assert-Equal $false (Update-HotkeyKeys -Settings $settings -State @($a,$b)) 'a reused UID does not prove physical identity'
    Set-DisplayIdentity -State @($a,$b)
    $settings.hotkeys[('solo:'+$a.Label)]='Ctrl+Alt+F9'
    Assert-Equal $false (Update-HotkeyKeys -Settings $settings -State @($a)) 'a conflicting destination is retained'
    Assert-Equal 'Ctrl+Alt+F9' $settings.hotkeys[('solo:'+$a.Label)] 'the new binding wins'
    Assert-Equal 'Ctrl+Alt+F1' $settings.hotkeys[$old] 'the old binding remains available for manual editing'
    $settings.hotkeys.Clear()
    $settings.hotkeys[('solo:id:'+$a.Id)]='Ctrl+Alt+F1'
    Assert-True (Update-HotkeyKeys -Settings $settings -State @($a,$b)) 'an imported full path needs no UID inference'
    Assert-Equal 'Ctrl+Alt+F1' $settings.hotkeys[('solo:'+$a.Label)] 'the full path selects exactly one panel'
}
Test-Case 'upgrade: a physical solo binding is not downgraded to a replaceable model key' {
    $panel=New-FakeMonitor -Label 'Panel' -ShortId 'PNL1234' -Id 'original-path'
    $settings=New-TestSettings
    $settings.hotkeys['solo:id:original-path']='Ctrl+Alt+F1'
    Assert-Equal $false (Update-HotkeyKeys -Settings $settings -State @($panel)) 'without a physical destination key the original is retained'
    Assert-Equal 'Ctrl+Alt+F1' $settings.hotkeys['solo:id:original-path'] 'the exact binding is not lost'
    Assert-Equal $false $settings.hotkeys.Contains('solo:Panel') 'a replacement panel cannot inherit a model binding'
}

Test-Case 'upgrade: an unrelated combo save retains imported exact member and primary selectors' {
    $panel=New-FakeMonitor -Label 'Panel' -ShortId 'PNL1234' -Id 'original-path'
    $selector='id:original-path'
    $combo=[pscustomobject]@{Name='Existing';Patterns=@($selector);Primary=$selector}
    $ed=New-ModeEditorWindow -Mode $null -Combo $combo -State @($panel) -Dark $false
    try {
        $ed.NameBox.Text='Renamed'
        $got=Read-ModeFromUi -Editor $ed
        Assert-True $got.Ok 'the primary still belongs to the checked display'
        Assert-Equal @($selector) @($got.Mode.Patterns) 'the exact member survives an unrelated edit'
        Assert-Equal $selector $got.Mode.Primary 'the exact primary survives'
        $replacement=New-FakeMonitor -Label 'Panel' -ShortId 'PNL1234' -Id 'replacement-path'
        $settings=New-TestSettings -Combos @{ Renamed=@{displays=$got.Mode.Patterns;primary=$got.Mode.Primary} }
        $mode=Get-DisplayModes -State @($replacement) -Settings $settings | Where-Object {$_.Key -eq 'combo:Renamed'}
        Assert-Equal 0 @(Get-ModeMembers -Mode $mode -State @($replacement)).Count 'a replacement same-model panel remains unselected'
    }
    finally {$ed.Window.Close()}
}