# --- разбор и печать комбинаций клавиш --------------------------------------

Write-Host 'hotkey strings' -ForegroundColor White

Test-Case 'hotkey: Ctrl+Alt+F1 parses' {
    $r = ConvertFrom-HotkeyString 'Ctrl+Alt+F1'
    Assert-True ($null -ne $r) 'parsed'
    Assert-Equal 3 $r.Modifiers 'modifiers (ctrl 2 | alt 1)'
    Assert-Equal 0x70 $r.Vk 'vk of F1'
    Assert-Equal 'Ctrl+Alt+F1' $r.Text 'round-trip text'
}

Test-Case 'hotkey: every F key from F1 to F24' {
    for ($n = 1; $n -le 24; $n++) {
        $r = ConvertFrom-HotkeyString "Ctrl+F$n"
        Assert-True ($null -ne $r) "F$n parsed"
        if ($r) { Assert-Equal (0x70 + $n - 1) $r.Vk "F$n vk" }
    }
}

Test-Case 'hotkey: F25 is not a key' {
    Assert-Null (ConvertFrom-HotkeyString 'Ctrl+F25') 'F25'
}

Test-Case 'hotkey: needs a modifier' {
    Assert-Null (ConvertFrom-HotkeyString 'F1') 'bare F1'
    Assert-Null (ConvertFrom-HotkeyString 'A') 'bare letter'
}

Test-Case 'hotkey: rubbish is rejected' {
    Assert-Null (ConvertFrom-HotkeyString '') 'empty'
    Assert-Null (ConvertFrom-HotkeyString '   ') 'spaces'
    Assert-Null (ConvertFrom-HotkeyString 'Ctrl+') 'modifier only'
    Assert-Null (ConvertFrom-HotkeyString 'Ctrl+Alt') 'modifiers only'
    Assert-Null (ConvertFrom-HotkeyString 'Ctrl+F0') 'F0'
    Assert-Null (ConvertFrom-HotkeyString 'Ctrl+Enter') 'unsupported key name'
    Assert-Null (ConvertFrom-HotkeyString 'nonsense') 'plain word'
}

Test-Case 'hotkey: letters and digits work' {
    $a = ConvertFrom-HotkeyString 'Win+A'
    Assert-Equal 0x41 $a.Vk 'A'
    Assert-Equal 'Win+A' $a.Text 'A text'
    $d = ConvertFrom-HotkeyString 'Ctrl+Shift+7'
    Assert-Equal 0x37 $d.Vk '7'
    Assert-Equal 'Ctrl+Shift+7' $d.Text '7 text'
}

Test-Case 'hotkey: modifier order is normalised, aliases understood' {
    # Порядок в тексте всегда Ctrl, Alt, Shift, Win — независимо от того, как ввели.
    Assert-Equal 'Ctrl+Alt+F5' (ConvertFrom-HotkeyString 'Alt+Ctrl+F5').Text 'reordered'
    Assert-Equal 'Ctrl+F5' (ConvertFrom-HotkeyString 'CONTROL+f5').Text 'alias and case'
    Assert-Equal 'Ctrl+Alt+Shift+Win+F2' (ConvertFrom-HotkeyString 'win+shift+alt+ctrl+F2').Text 'all four'
}

Test-Case 'hotkey: format and parse round-trip each other' {
    foreach ($text in 'Ctrl+F1', 'Alt+F12', 'Ctrl+Shift+A', 'Win+9', 'Ctrl+Alt+Shift+Win+F24') {
        $p = ConvertFrom-HotkeyString $text
        Assert-True ($null -ne $p) "$text parsed"
        if ($p) {
            Assert-Equal $text (Format-HotkeyString $p.Modifiers $p.Vk) "$text round-trip"
            Assert-Equal $text (ConvertFrom-HotkeyString (Format-HotkeyString $p.Modifiers $p.Vk)).Text "$text twice"
        }
    }
}

Test-Case 'hotkey: unknown vk prints as VKnn instead of throwing' {
    Assert-Equal 'Ctrl+VK13' (Format-HotkeyString 2 13) 'Enter has no name'
}
