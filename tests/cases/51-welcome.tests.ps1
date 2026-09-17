# --- the first steps --------------------------------------------------------
# Built without being shown, like every other window here. Two things are worth a test and the
# pictures on the four screens are not: what the window DERIVES (the counter, the heading, what
# the two buttons say on the last screen, what it hands back to its caller), and what
# Get-WelcomeFacts is prepared to be given — a desk with a monitor that is merely remembered, a
# mode nobody gave a shortcut to, settings whose hotkeys map has never been written.
#
# The tour writes nothing and changes no setting. That is the one property a case here must never
# let slip: it is shown on the run that creates settings.json, ahead of everything, and a tour
# that could refuse to open would be a first run that never reaches the tray.

Write-Host ''
Write-Host 'the first steps' -ForegroundColor White

function New-WelcomeUi {
    param([string[]]$Displays = @('LG ULTRAGEAR'), $Shortcuts = @(), [switch]$InSettings,
          [string]$Language = 'auto')
    return New-WelcomeWindow -Displays $Displays -Shortcuts $Shortcuts -InSettings:$InSettings -Language $Language
}

# The drop-down's items carry their code on .Tag; the visible text is each language's own word for
# itself and is nobody's key. Picking by Tag is how a person's click is imitated here.
function Select-WelcomeLanguage {
    param($Ui, [string]$Code)
    foreach ($item in @($Ui.LanguageBox.Items)) {
        if ([string]$item.Tag -eq $Code) { $Ui.LanguageBox.SelectedItem = $item; return }
    }
    throw "no language item for '$Code'"
}

function Close-WelcomeUi {
    param($Ui)
    if ($Ui -and $Ui.Window) { $Ui.Window.Close() }
    $script:ActiveWelcome = $null
}

function New-WelcomeShortcuts {
    param([int]$Count)
    $out = @()
    for ($i = 1; $i -le $Count; $i++) {
        $out += [pscustomobject]@{ Keys = "Ctrl+Alt+F$i"; Title = "Mode $i" }
    }
    return @($out)
}

Test-Case 'first steps: the window opens on the first of four with nowhere to go back to' {
    $ui = New-WelcomeUi
    try {
        Assert-Equal 4 $ui.Pages.Count 'four screens'
        Assert-Equal 4 $ui.Dots.Count 'a dot each'
        Assert-Equal 0 $ui.Step 'opens on the first'
        Assert-Equal 'Step 1 of 4' $ui.StepText.Text 'and says so'
        Assert-Equal 'Your screens, in named sets' $ui.TitleText.Text 'the first heading'
        Assert-True (-not $ui.BackBtn.IsEnabled) 'Back is dead on the first screen'
        Assert-Equal 'Next' $ui.NextBtn.Content 'and the other button only goes on'
        Assert-Equal 'Visible' ([string]$ui.Pages[0].Visibility) 'the first screen is the visible one'
        Assert-Equal 'Collapsed' ([string]$ui.Pages[3].Visibility) 'and the last one is not'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: the heading, the counter and the dots follow the step' {
    $ui = New-WelcomeUi
    try {
        Set-WelcomeStep -Ui $ui -Step 2
        Assert-Equal 'Step 3 of 4' $ui.StepText.Text 'the counter'
        Assert-Equal 'The shortcuts are ready' $ui.TitleText.Text 'the heading'
        Assert-True $ui.BackBtn.IsEnabled 'Back works from here'
        Assert-True ([object]::ReferenceEquals($ui.Dots[2].Background, $ui.DotOn)) 'the third dot is lit'
        Assert-True ([object]::ReferenceEquals($ui.Dots[0].Background, $ui.DotOff)) 'and the first is not'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: a step out of range is clamped, not an exception' {
    # Set-WelcomeStep is reached from two buttons and from render-preview.ps1, and a fifth screen
    # asked for by a caller that counted wrong must not take the first run down with it.
    $ui = New-WelcomeUi
    try {
        Set-WelcomeStep -Ui $ui -Step 9
        Assert-Equal 3 $ui.Step 'clamped to the last'
        Set-WelcomeStep -Ui $ui -Step -4
        Assert-Equal 0 $ui.Step 'and to the first'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: the last screen offers the desk, and only the last one' {
    $ui = New-WelcomeUi
    try {
        Set-WelcomeStep -Ui $ui -Step 3
        Assert-Equal 'Set up my desk' $ui.NextBtn.Content 'the last button is the point of the tour'
        Assert-Equal 'Close' $ui.SkipBtn.Content 'and the way out stops calling itself Skip'
        Assert-Equal 'Visible' ([string]$ui.SkipBtn.Visibility) 'the way out is still there'
        Set-WelcomeStep -Ui $ui -Step 1
        Assert-Equal 'Next' $ui.NextBtn.Content 'and it is Next again on the way back'
        Assert-Equal 'Skip' $ui.SkipBtn.Content 'with Skip beside it'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: pressing the last button is what asks for the Settings window' {
    # .Result is the whole answer Show-WelcomeDialog gives its caller, and the tray opens nothing
    # without it. The window is never shown here, so the handler's DialogResult throws and is
    # swallowed — the assignment above it is the part that has to happen anyway.
    $ui = New-WelcomeUi
    try {
        Set-WelcomeStep -Ui $ui -Step 3
        $ui.NextBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        Assert-True $ui.Result 'the desk was asked for'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: Next in the middle turns a page instead of answering' {
    $ui = New-WelcomeUi
    try {
        $ui.NextBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        Assert-Equal 1 $ui.Step 'one page on'
        Assert-True (-not $ui.Result) 'and nothing was asked for'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: skipping asks for nothing' {
    $ui = New-WelcomeUi
    try {
        Set-WelcomeStep -Ui $ui -Step 3
        $ui.SkipBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        Assert-True (-not $ui.Result) 'the way out stays a way out on the last screen too'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: opened from About it says Done and never asks for Settings' {
    # It is standing in front of the window it would otherwise offer to open, and two buttons that
    # both close it would be a choice with no difference in it.
    $ui = New-WelcomeUi -InSettings
    try {
        Set-WelcomeStep -Ui $ui -Step 3
        Assert-Equal 'Done' $ui.NextBtn.Content 'the last button closes'
        Assert-Equal 'Collapsed' ([string]$ui.SkipBtn.Visibility) 'and the second way out is gone'
        $ui.NextBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        Assert-True (-not $ui.Result) 'nothing is asked for'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: the desk line names the monitors, and says so when there are none' {
    $ui = New-WelcomeUi -Displays @('LG ULTRAGEAR', 'LG ULTRAFINE')
    try {
        $line = [string]$ui.Window.FindName('DeskLine').Text
        Assert-True ($line -like '*LG ULTRAGEAR, LG ULTRAFINE*') 'both, in the order they came'
    }
    finally { Close-WelcomeUi -Ui $ui }

    $empty = New-WelcomeUi -Displays @()
    try {
        $line = [string]$empty.Window.FindName('DeskLine').Text
        Assert-True ($line -like '*not named a display*') 'and a sentence rather than a blank'
        Assert-True ($line -notlike '*:*.') 'never "on your desk right now: ."'
    }
    finally { Close-WelcomeUi -Ui $empty }
}

Test-Case 'first steps: the shortcut card lists what was handed out' {
    $ui = New-WelcomeUi -Shortcuts (New-WelcomeShortcuts -Count 3)
    try {
        $list = $ui.Window.FindName('ShortcutList')
        Assert-Equal 3 $list.Children.Count 'a row each'
        Assert-Equal 'Visible' ([string]$list.Parent.Visibility) 'and the card is there'
        Assert-True ([string]$ui.Window.FindName('ShortcutLead').Text -like '*gave each mode a shortcut*') 'the lead says what happened'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: a long list is cut off and counted rather than run off the window' {
    $ui = New-WelcomeUi -Shortcuts (New-WelcomeShortcuts -Count 8)
    try {
        $list = $ui.Window.FindName('ShortcutList')
        Assert-Equal ($script:WelcomeShortcutsShown + 1) $list.Children.Count 'five rows and the line that counts the rest'
        $last = $list.Children[$list.Children.Count - 1]
        Assert-Equal 'and 3 more' ([string]$last.Text) 'which says how many were left out'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: no shortcuts means a sentence, not an empty plate' {
    $ui = New-WelcomeUi -Shortcuts @()
    try {
        $list = $ui.Window.FindName('ShortcutList')
        Assert-Equal 0 $list.Children.Count 'nothing to list'
        Assert-Equal 'Collapsed' ([string]$list.Parent.Visibility) 'so the card is gone'
        Assert-True ([string]$ui.Window.FindName('ShortcutLead').Text -like '*no mode to give one to*') 'and the lead explains itself'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

# --- the language, chosen before anything else ------------------------------
# The first screen a person ever sees is the only place the choice is cheap: after it the tour,
# the balloon and the Settings window have all already spoken. It is the same setting Behavior
# writes and the same drop-down, filled by the same function.

Test-Case 'first steps: the language box offers Follow Windows and every file under lang' {
    $ui = New-WelcomeUi
    try {
        Assert-True ($ui.LanguageBox.Items.Count -gt 1) 'more than just the automatic choice'
        Assert-Equal 'auto' ([string]$ui.LanguageBox.Items[0].Tag) 'and Follow Windows comes first'
        $codes = @($ui.LanguageBox.Items | ForEach-Object { [string]$_.Tag })
        Assert-True ($codes -contains 'en') 'English is offered by name'
        Assert-True ($codes -contains 'ru') 'and so is every other file under lang'
        Assert-Equal 'auto' ([string]$ui.LanguageCode) 'a fresh first run follows Windows'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: the box opens on the code it was given' {
    $ui = New-WelcomeUi -Language 'de'
    try {
        Assert-Equal 'de' (Get-UiLanguage -Ui $ui) 'the drop-down shows it'
        Assert-Equal 'de' ([string]$ui.LanguageCode) 'and the window agrees with the drop-down'
        Assert-True (-not $ui.ReloadLanguage) 'filling it in code is not a person choosing'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: a code with no file falls back to Follow Windows on both sides' {
    # The two have to agree, or the first click on any real language would look like no change.
    $ui = New-WelcomeUi -Language 'kl'
    try {
        Assert-Equal 'auto' (Get-UiLanguage -Ui $ui) 'the box fell back'
        Assert-Equal 'auto' ([string]$ui.LanguageCode) 'and so did what the window remembers'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: choosing a language asks for a rebuild and answers nothing' {
    $ui = New-WelcomeUi
    try {
        Set-WelcomeStep -Ui $ui -Step 2
        Select-WelcomeLanguage -Ui $ui -Code 'en'
        Assert-True $ui.ReloadLanguage 'the window asks to be built again'
        Assert-Equal 'en' ([string]$ui.LanguageCode) 'in the language that was picked'
        Assert-True (-not $ui.Result) 'and a language is not a request for the Settings window'
        Assert-Equal 2 $ui.Step 'the screen it was left on is the screen it comes back on'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: picking the language it is already in changes nothing' {
    $ui = New-WelcomeUi -Language 'en'
    try {
        Select-WelcomeLanguage -Ui $ui -Code 'en'
        Assert-True (-not $ui.ReloadLanguage) 'no rebuild for a choice that is not one'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: opened from About there is no second language picker' {
    # The Behavior page is on the window directly underneath, and two live pickers over one
    # setting is a way to lose an edit.
    $ui = New-WelcomeUi -InSettings
    try {
        Assert-Equal 'Collapsed' ([string]$ui.LanguageGroup.Visibility) 'the group is gone'
        Assert-Equal 0 $ui.LanguageBox.Items.Count 'and it was never filled'
    }
    finally { Close-WelcomeUi -Ui $ui }
}

Test-Case 'first steps: the tray writes the chosen language to the same key Behavior does' {
    $tray = Get-TrayAst
    $set = @($tray.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Set-TrayLanguage' }, $true))
    Assert-Equal 1 $set.Count 'one place turns a pick into a setting'
    if ($set.Count -eq 1) {
        $text = $set[0].Extent.Text
        Assert-True ($text -match '\$settings\.language\s*=') 'the language key, the one Behavior writes'
        Assert-True ($text -match 'Initialize-Language') 'the running tray starts speaking it'
        Assert-True ($text -match 'Save-DisplaySettings') 'and it survives a restart'
        Assert-True ($text -notmatch 'Register-Hotkeys') 'no shortcut was touched, so none is re-registered'
        Assert-True ($text -notmatch 'Show-Balloon') 'and no balloon over a window somebody is reading'
    }
    Assert-True ($tray.Extent.Text -match '-OnLanguage') 'and the tour is given a way to reach it'
}

# --- what the window is told about this desk --------------------------------

Test-Case 'welcome facts: a remembered monitor is not on the desk right now' {
    $state = @(
        (New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug')
        (New-FakeMonitor 'LG ULTRAFINE' 'GSM5CBC' 'path-uf' $false $true)
    )
    $facts = Get-WelcomeFacts -State $state -Settings (New-TestSettings)
    Assert-Equal 1 $facts.Displays.Count 'only the one that is connected'
    Assert-Equal 'LG ULTRAGEAR' ([string]$facts.Displays[0]) 'and it is that one'
}

Test-Case 'welcome facts: a fingerprint is shortened the way every other name here is' {
    # The raw Label of two identical panels carries sixteen hex characters. Get-DisplayTitle is
    # what the menu and the mode list show; a tour that opened with the raw one would look broken.
    $state = @((New-FakeMonitor 'Acer XV272U {1111111111111111}' 'ACR0ABC' 'path-a'))
    $facts = Get-WelcomeFacts -State $state -Settings (New-TestSettings)
    Assert-Equal 1 $facts.Displays.Count 'the one panel'
    Assert-True (([string]$facts.Displays[0]) -notlike '*{*') 'no braces in a name a person reads'
    Assert-True (([string]$facts.Displays[0]) -like 'Acer XV272U*111111') 'enough of it to tell two apart'
}

Test-Case 'welcome facts: a mode with no shortcut is left out of the list' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug'))
    $settings = New-TestSettings
    $modes = @(Get-DisplayModes -State $state -Settings $settings)
    $settings.hotkeys[[string]$modes[0].Key] = 'Ctrl+Alt+F1'
    $facts = Get-WelcomeFacts -State $state -Settings $settings -Modes $modes
    Assert-Equal 1 $facts.Shortcuts.Count 'only the mode that has one'
    Assert-Equal 'Ctrl+Alt+F1' ([string]$facts.Shortcuts[0].Keys) 'the keys'
    Assert-True (([string]$facts.Shortcuts[0].Title).Length -gt 0) 'and what they reach, named'
}

Test-Case 'welcome facts: settings with an empty hotkey map are not an exception' {
    $state = @((New-FakeMonitor 'LG ULTRAGEAR' 'GSM5BB3' 'path-ug'))
    $facts = Get-WelcomeFacts -State $state -Settings (Get-DefaultSettings)
    Assert-Equal 0 $facts.Shortcuts.Count 'nothing was assigned, and nothing is claimed'
    Assert-Equal 1 $facts.Displays.Count 'the desk is still described'
}

Test-Case 'welcome facts: a desk it cannot read at all still answers with two empty lists' {
    # The tour is shown before anything else on a first run. It has to survive state that is not
    # there yet rather than take the start-up down with it.
    $facts = Get-WelcomeFacts -State $null -Settings $null
    Assert-Equal 0 $facts.Displays.Count 'no displays'
    Assert-Equal 0 $facts.Shortcuts.Count 'no shortcuts'
}

# --- how the tray reaches it ------------------------------------------------

Test-Case 'first steps: the tray offers the tour and the first run shows it before Settings' {
    $tray = Get-TrayAst
    $text = $tray.Extent.Text
    Assert-True ($text -match "Get-Text -Key 'menu\.welcome'") 'the menu has an item for it'
    Assert-True ($text -match 'function Open-FirstSteps') 'and a body that answers rather than acts'

    # The order is the whole change: Settings used to open by itself onto the desk diagram, which
    # answers a question nobody has asked on the run that created the settings.
    $ifs = @($tray.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))
    $first = @($ifs | Where-Object { $_.Clauses[0].Item1.Extent.Text -match '\$script:FirstRun$' })
    Assert-Equal 1 $first.Count 'one block is the first run'
    if ($first.Count -eq 1) {
        $body = $first[0].Extent.Text
        Assert-True ($body -match 'Open-FirstSteps') 'the tour is in it'
        Assert-True ($body.IndexOf('Open-FirstSteps') -lt $body.IndexOf('Open-SettingsWindow')) 'and it comes first'
        Assert-True ($body -match '\$goToSettings\s*=\s*\$true') 'a tour that cannot be built still lets the old path run'
    }
}
