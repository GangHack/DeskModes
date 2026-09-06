# --- the interface speaks, the log does not ---------------------------------
# Two halves, and the split between them is the whole point of this file. The window, the menu
# and the balloons follow the person's language; last-run.log stays English forever, because it
# is read against greps, commits and issues rather than by whoever is sitting at the desk.
#
# The failures these guard against are all silent ones: a label that reads "[balloon.saved]", a
# done: line that changed language with the window, a timer box that no longer understands the
# text it wrote into itself, and an apostrophe in a translation taking a whole window down at
# parse time.

Write-Host ''
Write-Host 'the interface in another language' -ForegroundColor White

# Every case here leaves the run as it found it: run-tests.ps1 pins English, and a case that
# forgot to switch back would fail every file after it rather than itself.
function Invoke-InLanguage {
    param([string]$Code, [scriptblock]$Body)

    try {
        [void](Initialize-Language -Code $Code)
        & $Body
    }
    finally { [void](Initialize-Language -Code 'en') }
}

Test-Case 'language: a code with no file falls back to English rather than to nothing' {
    Assert-Equal 'en' (Resolve-LanguageCode -Wanted 'kl') 'Klingon is not shipped'
    Assert-Equal 'ru' (Resolve-LanguageCode -Wanted 'RU') 'the code is case-insensitive'
    Assert-Equal 'ru' (Resolve-LanguageCode -Wanted 'ru') 'and it is the file name'
}

Test-Case 'language: every file says what it calls itself, in itself' {
    $choices = Get-LanguageChoices
    Assert-Equal 'English' $choices['en'] 'English'
    foreach ($code in 'ru', 'uk', 'es', 'fr', 'de') {
        Assert-True ([bool]$choices[$code]) ($code + ' is listed')
    }
    # Not "Russian" and not "German": the drop-down is read by somebody who cannot read the
    # language the rest of the window is in.
    Assert-True ($choices['ru'] -notmatch '^[a-zA-Z]+$') 'Russian says it in its own alphabet'
    Assert-Equal 'Deutsch' $choices['de'] 'and German in its own word'
}

Test-Case 'language: a key nobody translated shows its English rather than an empty label' {
    Invoke-InLanguage 'ru' {
        # A key that exists in en.ps1 and, by construction, in no translation.
        $script:Strings = $null
        $map = Get-LanguageMap -Code 'ru'
        Assert-True $map.Contains('mode.all') 'the English base is under the translation'
        Assert-Equal 'Все мониторы' (Get-Text -Key 'mode.all') 'and the translation is on top'
    }
}

Test-Case 'language: a key that exists nowhere is visible on the window, not silently empty' {
    Assert-Equal '[no.such.key]' (Get-Text -Key 'no.such.key') 'in brackets, so it is noticed'
}

Test-Case 'language: nought formats as nought and not as the template' {
    # @(0) is a one-element array whose truth is the truth of its element, and "0 s" once left
    # this function as "{0} s".
    Assert-Equal '0 s' (Format-Duration 0) 'zero seconds'
    Assert-Equal '0 min' (Format-DurationShort 0) 'zero minutes'
}

Test-Case 'language: one, two and five each get their own form' {
    Invoke-InLanguage 'ru' {
        Assert-Equal '1 день'  (Get-PluralText -Key 'diary.days' -Count 1)   'one'
        Assert-Equal '3 дня'   (Get-PluralText -Key 'diary.days' -Count 3)   'a few'
        Assert-Equal '7 дней'  (Get-PluralText -Key 'diary.days' -Count 7)   'many'
        # The exception the rule exists for: 11 is not 1, and 12-14 are not 2-4.
        Assert-Equal '11 дней' (Get-PluralText -Key 'diary.days' -Count 11)  'eleven'
        Assert-Equal '21 день' (Get-PluralText -Key 'diary.days' -Count 21)  'twenty-one'
        Assert-Equal '13 дней' (Get-PluralText -Key 'diary.days' -Count 13)  'thirteen'
    }
    Assert-Equal '1 day'  (Get-PluralText -Key 'diary.days' -Count 1) 'and English has two forms'
    Assert-Equal '0 days' (Get-PluralText -Key 'diary.days' -Count 0) 'with nought taking the plural'

    # French is the one that does not: 0 jour, 1 jour, 2 jours. Spanish and German count nought
    # as a plural, as English does.
    Invoke-InLanguage 'fr' {
        Assert-Equal '0 jour'  (Get-PluralText -Key 'diary.days' -Count 0) 'nought is singular in French'
        Assert-Equal '2 jours' (Get-PluralText -Key 'diary.days' -Count 2) 'two is not'
    }
    Invoke-InLanguage 'es' {
        Assert-Equal '0 días' (Get-PluralText -Key 'diary.days' -Count 0) 'and it is plural in Spanish'
    }
    Invoke-InLanguage 'de' {
        Assert-Equal '1 Tag'  (Get-PluralText -Key 'diary.days' -Count 1) 'one, in German'
        Assert-Equal '5 Tage' (Get-PluralText -Key 'diary.days' -Count 5) 'and more than one'
    }
}

Test-Case 'language: the log keeps its English while the window changes' {
    Invoke-InLanguage 'ru' {
        $verdict = Format-SwitchResult -Summary @('LG 2560x1440') -Failed @('XG27')
        Assert-True ($verdict.Text -match 'не поднялись') 'the balloon is in the person''s language'
        Assert-True ($verdict.Log -match 'did not come up') 'and the done: line is not'
        Assert-True ($verdict.Log -notmatch 'поднял') 'nothing Russian leaks into the log'
        Assert-True (-not $verdict.Ok) 'a display that never came up is not a success'
    }
}

Test-Case 'language: a refusal reaches the person translated and the log in English' {
    Invoke-InLanguage 'ru' {
        $refusal = New-DisplayRefusal -Key 'switch.notConnected'
        Assert-True ($refusal.Message -match 'не подключ') 'the balloon is Russian'
        # The mark is what stops Switch-DisplayMode's catch writing the same line a second time,
        # in the wrong language.
        Assert-True ($refusal.Data.Contains('dm.logged')) 'and it is marked as already logged'

        $log = Get-Content -LiteralPath $env:DESKMODES_LOG_FILE -Tail 1
        Assert-True ($log -match 'not connected right now') 'the English of it went to the log'
    }
}

Test-Case 'language: a mode title follows the window and a mode key never does' {
    Invoke-InLanguage 'ru' {
        Assert-Equal 'Только LG'   (Get-ModeTitleFromKey 'solo:LG') 'the title is for a person'
        Assert-Equal 'Все мониторы' (Get-ModeTitleFromKey 'all')     'and so is this one'
    }
    # The key is what settings.json, the hotkeys and every comparison use, and it is the same
    # string in every language - which is why nothing here is ever looked up by title.
    Assert-Equal 'Only LG' (Get-ModeTitleFromKey 'solo:LG') 'back in English'
}

Test-Case 'language: the timer box still understands the text it wrote into itself' {
    Invoke-InLanguage 'ru' {
        $written = Format-DurationShort 90
        Assert-Equal '1 ч 30 мин' $written 'what the button says'
        Assert-Equal 90 (ConvertFrom-DurationText $written) 'and what it reads back'
        Assert-Equal 45 (ConvertFrom-DurationText '45 мин') 'minutes on their own'
        Assert-Equal 120 (ConvertFrom-DurationText '2 ч') 'hours on their own'
        # English is accepted whatever the window speaks: a person types "1h30" out of habit,
        # and the box must not answer that with nought.
        Assert-Equal 90 (ConvertFrom-DurationText '1h30') 'and the English form goes on working'
    }
    # Every language, every step the timer offers: this is the one place a translation can break
    # something rather than merely read oddly, and it breaks it silently - the box answers nought
    # and the timer is set to nothing.
    foreach ($code in 'en', 'ru', 'uk', 'es', 'fr', 'de') {
        Invoke-InLanguage $code {
            foreach ($minutes in 1, 5, 45, 60, 90, 120, 720) {
                Assert-Equal $minutes (ConvertFrom-DurationText (Format-DurationShort $minutes)) `
                             ($code + ': ' + $minutes)
            }
            Assert-Equal 90 (ConvertFrom-DurationText '1h30') ($code + ': and "1h30" typed out of habit')
        }
    }
}

Test-Case 'language: a translation goes into the markup escaped' {
    # A window is markup, and prose is full of the four characters XML cannot take raw. Before
    # Expand-UiText escaped them, an ampersand in a translation was a window that would not parse
    # - and the window that fails is the one nobody who reads that language can open.
    # Straight into the map the window is being built from: Expand-UiText asks Get-Text for the
    # language in force, and a map put somewhere else would never be looked in.
    $map = Get-LanguageMap
    $map['test.prose'] = 'Tom & Jerry <b> "quoted"'
    $out = Expand-UiText -Text '<TextBlock Text="%%T:test.prose%%"/>'
    Assert-True ($out -match '&amp;') 'the ampersand'
    Assert-True ($out -match '&lt;b&gt;') 'the tags'
    Assert-True ($out -match '&quot;quoted&quot;') 'the quotes'
    Assert-True ($out -notmatch '%%T:') 'and the token is gone'
    $map.Remove('test.prose')
}

Test-Case 'language: what the code asks for is a question the check answers, not a guess' {
    # Not a substitute for gate 4 in tools\check.ps1, which walks every file: this is the handful
    # of keys that are BUILT rather than written down, and a missing one of those shows up as
    # "[timer.set.sleep]" in a balloon nobody is looking at when it happens.
    foreach ($action in 'shutdown', 'sleep') {
        foreach ($stem in 'timer.set', 'timer.moved', 'timer.lastMinute', 'tray.timer',
                          'menu.timer.in', 'menu.timer.armed', 'timer.caption', 'timer.start') {
            $key = $stem + '.' + $action
            Assert-True ((Get-Text -Key $key) -notmatch '^\[') $key
        }
    }
}

Test-Case 'language: the drop-down hands back a code and never the language''s own name' {
    $ui = New-DialogUi -Settings (New-TestSettings)
    try {
        Set-UiLanguageBox -Ui $ui -Settings ([ordered]@{ language = 'ru' })
        Assert-Equal 'ru' (Get-UiLanguage -Ui $ui) 'the code, which is what settings.json holds'

        Set-UiLanguageBox -Ui $ui -Settings ([ordered]@{ language = 'auto' })
        Assert-Equal 'auto' (Get-UiLanguage -Ui $ui) 'and "follow Windows" is a value of its own'

        # A language somebody wrote into the file by hand that has no file of its own: the box
        # falls back to the first item rather than showing a blank.
        Set-UiLanguageBox -Ui $ui -Settings ([ordered]@{ language = 'kl' })
        Assert-Equal 'auto' (Get-UiLanguage -Ui $ui) 'an unknown code reads as "follow Windows"'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'language: changing the drop-down survives the full form read and marks the window edited' {
    $settings = New-TestSettings
    $settings.language = 'en'
    $ui = New-DialogUi -Settings $settings
    try {
        Assert-Equal $false (Test-UiEdited -Ui $ui) 'the window starts untouched'
        Set-UiLanguageBox -Ui $ui -Settings ([ordered]@{ language = 'ru' })
        Assert-True (Test-UiEdited -Ui $ui) 'the changed language is an edit'

        $got = Read-SettingsFromUi -Ui $ui -Settings $settings
        Assert-True $got.Ok 'the whole form can be read'
        Assert-Equal 'ru' ([string]$got.Settings.language) 'and the selected language reaches the settings'
    }
    finally { $ui.Window.Close() }
}

Test-Case 'language: disconnected rows and editor validation follow Russian' {
    Invoke-InLanguage 'ru' {
        $state = @(
            (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
            (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf' $false $true)
        )
        $mode = [pscustomobject]@{ Key = 'combo:Work'; Title = 'Work'; Kind = 'combo'; Available = $true }
        $combo = [pscustomobject]@{ Name = 'Work'; Patterns = @('GSM5BB3', 'GSM5CBC'); Primary = '' }
        $ed = New-ModeEditorWindow -Mode $mode -Combo $combo -State $state -TakenNames @('Office') `
                                   -Hotkeys ([ordered]@{ 'all' = 'Ctrl+Alt+F5' }) -Dark $false
        try {
            Assert-True ([string]$ed.Checks[1].Content -match 'не подключ') 'the disconnected display is translated'
            Assert-True ([string]$ed.Checks[1].Content -notmatch 'not connected') 'no English suffix remains'

            $ed.NameBox.Text = 'Office'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True ($got.Problem -match 'уже существует') 'the duplicate name is translated'

            $ed.NameBox.Text = 'Studio'
            $ed.HotkeyBox.Text = 'Ctrl+Alt+F5'
            $got = Read-ModeFromUi -Editor $ed
            Assert-True ($got.Problem -match 'уже переключает') 'the shortcut conflict is translated'
        }
        finally { $ed.Window.Close() }
    }
}

Test-Case 'language: duplicate shortcut validation follows Russian including Back' {
    Invoke-InLanguage 'ru' {
        $settings = New-TestSettings
        $ui = New-DialogUi -Settings $settings
        try {
            $ui.Hotkeys['all'] = 'Ctrl+Alt+F5'
            $ui.Hotkeys['solo:LG ULTRAGEAR'] = 'Ctrl+Alt+F5'
            $got = Read-SettingsFromUi -Ui $ui -Settings $settings
            Assert-True ($got.Problem -match 'назначено дважды') 'two modes report the conflict in Russian'

            $ui.Hotkeys.Remove('solo:LG ULTRAGEAR')
            $ui.BackHotkeyBox.Text = 'Ctrl+Alt+F5'
            $got = Read-SettingsFromUi -Ui $ui -Settings $settings
            Assert-True ($got.Problem -match 'назначено дважды') 'Back reports the conflict in Russian too'
        }
        finally { $ui.Window.Close() }
    }
}

Test-Case 'language: the setting travels through settings.json and back' {
    $file = Join-Path $script:TestDir 'settings.json'
    '{ "language": "uk" }' | Set-Content -Path $file -Encoding UTF8
    try {
        $s = Get-DisplaySettings
        Assert-Equal 'uk' $s.language 'read'
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }

    Assert-Equal 'auto' (Get-DefaultSettings).language 'and a file that does not say follows Windows'
}
