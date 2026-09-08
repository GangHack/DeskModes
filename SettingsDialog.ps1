<#
    SettingsDialog.ps1 — DeskModes's windows, in WPF: the settings, the mode editor, the time
    picker for the timer and the diary.

    WPF and not WinForms: WinForms has no templates, and "modern" there means drawing every
    button by hand in Paint. In WPF rounded corners, toggles and a dark theme are markup
    rather than code. The WPF assemblies load lazily, on the first window open: they cost
    hundreds of milliseconds, and the tray measures its own startup.

    A window is built separately from being shown — both for the tests and for debugging: in
    the tray an exception while building a form is only visible as a system error window.

        New-SettingsWindow    build the window, hand back it and its elements (testable)
        Read-SettingsFromUi   collect the settings out of the window's elements (testable)
        Show-SettingsDialog   show it and hand back the changed settings, or $null
        New-TimerWindow       build the timer window (testable)
        Show-TimerDialog      show it and hand back the minutes, or 0
        New-StatsUi           build the diary page over a pot of days (testable)

    What they share is the palette, the markup resources and Convert-UiXaml: four windows of
    one application have to look like one, not like four.

    The theme is the system's: dark/light and the accent colour are read out of the registry on
    every open (Test-DarkTheme and Get-AccentColor in DisplayCore.ps1).
#>

# --- WPF --------------------------------------------------------------------
# Loaded on the first window open rather than at dot-source time: this file is included at
# tray startup, and "tray: started in N ms" must not pay for four assemblies that are only
# needed once a person opens the settings.

$script:WpfReady = $false

function Initialize-WpfRuntime {
    if ($script:WpfReady) { return }
    # WPF only lives in STA. powershell.exe has started in STA by itself since 3.0, but checking
    # is cheaper than untangling an obscure exception out of the depths of WPF.
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'The settings window needs an STA thread. Run powershell.exe without -MTA.'
    }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $script:WpfReady = $true
}

# --- the palette ------------------------------------------------------------
# The values are copied from the Windows 11 Settings app: the window background, cards a shade
# lighter (in dark) or white (in light), a dimmed secondary text. The accent is the system's;
# the contrasting text colour is worked out from it, otherwise white letters on a yellow accent
# are unreadable.

function Get-ContrastTextColor {
    param([string]$Hex)
    $r = [Convert]::ToInt32($Hex.Substring(1, 2), 16)
    $g = [Convert]::ToInt32($Hex.Substring(3, 2), 16)
    $b = [Convert]::ToInt32($Hex.Substring(5, 2), 16)
    $lum = 0.2126 * $r + 0.7152 * $g + 0.0722 * $b
    if ($lum -gt 160) { return '#1B1B1B' }
    return '#FFFFFF'
}

function Get-UiPalette {
    param([bool]$Dark)

    if ($Dark) {
        $accent = Get-AccentColor -ForDarkTheme
        return @{
            BG = '#202020'; CARD = '#2B2B2B'; CARDBORDER = '#232323'; FOOTER = '#1C1C1C'
            TEXT = '#F5F5F5'; DIM = '#A0A0A0'
            INPUT = '#363636'; INPUTBORDER = '#4A4A4A'; HOVER = '#3C3C3C'; PRESSED = '#333333'
            # The navigation pane is DARKER than the page, as it is in Windows 11 Settings: the
            # page is where the work is, and the pane stands behind it.
            MINI = '#3A3A3A'; PANE = '#1B1B1B'; SCROLL = '#5F5F5F'
            ACCENT = $accent; ACCENTTEXT = (Get-ContrastTextColor $accent)
        }
    }
    $accent = Get-AccentColor
    return @{
        BG = '#F3F3F3'; CARD = '#FBFBFB'; CARDBORDER = '#E5E5E5'; FOOTER = '#F3F3F3'
        TEXT = '#1B1B1B'; DIM = '#5F5F5F'
        INPUT = '#FFFFFF'; INPUTBORDER = '#D6D6D6'; HOVER = '#F0F0F0'; PRESSED = '#E8E8E8'
        # In the light theme the pane is darker than the page for the same reason.
        MINI = '#EDEDED'; PANE = '#EBEBEB'; SCROLL = '#9A9A9A'
        ACCENT = $accent; ACCENTTEXT = (Get-ContrastTextColor $accent)
    }
}

# --- the markup -------------------------------------------------------------
# The resources (brushes and styles) come as one block, which is substituted into both the main
# window and the combo editor: StaticResource is resolved at parse time, so the resources have
# to arrive together with the window's markup rather than after it.
#
# %%NAME%% tokens are replaced with the palette's values before parsing. Not -f: XAML is full of
# curly braces, and string formatting on it comes apart.

$script:UiResourcesXaml = @'
        <SolidColorBrush x:Key="BgBrush" Color="%%BG%%"/>
        <SolidColorBrush x:Key="CardBrush" Color="%%CARD%%"/>
        <SolidColorBrush x:Key="CardBorderBrush" Color="%%CARDBORDER%%"/>
        <SolidColorBrush x:Key="FooterBrush" Color="%%FOOTER%%"/>
        <SolidColorBrush x:Key="TextBrush" Color="%%TEXT%%"/>
        <SolidColorBrush x:Key="DimBrush" Color="%%DIM%%"/>
        <SolidColorBrush x:Key="InputBrush" Color="%%INPUT%%"/>
        <SolidColorBrush x:Key="InputBorderBrush" Color="%%INPUTBORDER%%"/>
        <SolidColorBrush x:Key="HoverBrush" Color="%%HOVER%%"/>
        <SolidColorBrush x:Key="PressedBrush" Color="%%PRESSED%%"/>
        <SolidColorBrush x:Key="MiniBrush" Color="%%MINI%%"/>
        <SolidColorBrush x:Key="PaneBrush" Color="%%PANE%%"/>
        <SolidColorBrush x:Key="ScrollBrush" Color="%%SCROLL%%"/>
        <SolidColorBrush x:Key="AccentBrush" Color="%%ACCENT%%"/>
        <SolidColorBrush x:Key="AccentTextBrush" Color="%%ACCENTTEXT%%"/>

        <!-- The type sizes are the Windows scale: body 14, caption 12. There are no more than
             two steps in the window; the hierarchy is held by weight and colour, not by a fifth
             size. A section heading is 16 rather than the scale's 20: 20 is meant for a settings
             page filling the screen, whereas here four sections run one after another in 640
             points of width, and 20 would read as the window's title. The departure is a single
             deliberate one; everything else is taken from the scale literally. -->
        <Style x:Key="H2" TargetType="TextBlock">
            <Setter Property="FontSize" Value="16"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Margin" Value="0,0,0,4"/>
        </Style>
        <!-- The mode editor's heading is that very 20 from the scale, exactly one step above H2.
             At the same size as the section captions, a mode's name read as one more section, and
             the window looked like a list of equal parts instead of "this is the mode, and this is
             what it is made of". -->
        <Style x:Key="H1" TargetType="TextBlock">
            <Setter Property="FontSize" Value="20"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Margin" Value="0,0,0,4"/>
        </Style>
        <Style x:Key="Hint" TargetType="TextBlock">
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="Margin" Value="0,0,0,12"/>
        </Style>
        <Style x:Key="RowTitle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
        </Style>
        <Style x:Key="RowSub" TargetType="TextBlock">
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="Margin" Value="0,4,0,0"/>
        </Style>

        <!-- The level slider. A template of its own, because the system Slider knows nothing of
             a dark theme or an accent: in a dark window it stayed light. The filled part is the
             track's DecreaseRepeatButton, which is the standard way to show what has been covered;
             the right half is transparent. -->
        <Style x:Key="Level" TargetType="Slider">
            <Setter Property="Minimum" Value="0"/>
            <Setter Property="Maximum" Value="100"/>
            <Setter Property="IsSnapToTickEnabled" Value="True"/>
            <Setter Property="TickFrequency" Value="1"/>
            <Setter Property="SmallChange" Value="1"/>
            <Setter Property="LargeChange" Value="10"/>
            <Setter Property="Height" Value="22"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Slider">
                        <Grid Background="Transparent">
                            <Border Height="4" CornerRadius="2" VerticalAlignment="Center"
                                    Background="{StaticResource InputBorderBrush}"/>
                            <Track x:Name="PART_Track">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="Slider.DecreaseLarge" Focusable="False">
                                        <RepeatButton.Template>
                                            <ControlTemplate TargetType="RepeatButton">
                                                <Border Height="4" CornerRadius="2" VerticalAlignment="Center"
                                                        Background="{StaticResource AccentBrush}"/>
                                            </ControlTemplate>
                                        </RepeatButton.Template>
                                    </RepeatButton>
                                </Track.DecreaseRepeatButton>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
                                        <RepeatButton.Template>
                                            <ControlTemplate TargetType="RepeatButton">
                                                <Border Background="Transparent"/>
                                            </ControlTemplate>
                                        </RepeatButton.Template>
                                    </RepeatButton>
                                </Track.IncreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Width="14" Height="14">
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="Thumb">
                                                <Ellipse Fill="{StaticResource TextBrush}"
                                                         Stroke="{StaticResource InputBorderBrush}" StrokeThickness="1"/>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Radius 4, not 8: a card is a surface inside a page, and in Windows the eight belongs
             to what floats above it (dialogs, dropdowns). The card here only cuts the page into
             sections; there is no shadow and no second layer beneath it.

             12 and not 16: with the padding at 16 and the gap between rows at 10, one row of
             Behavior stood 54 points tall, and the page read as a form for a much larger screen
             than the one it opens on. The type sizes are untouched — what was big was the air. -->
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="{StaticResource CardBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="4"/>
            <Setter Property="Padding" Value="12,12"/>
            <Setter Property="Margin" Value="0,0,0,10"/>
        </Style>

        <!-- A row of a card: a label with its caption on the left, one control on the right.
             There were fourteen copies of this Grid in the markup, each with its own
             Margin="0,10,0,0" — and the gap is the page's rhythm, so fourteen places had to be
             edited to change it. One style, and the rhythm is one number. -->
        <Style x:Key="Row" TargetType="Grid">
            <Setter Property="Margin" Value="0,6,0,0"/>
        </Style>
        <!-- The first row of a card sits under the padding already and must not add to it. -->
        <Style x:Key="RowFirst" TargetType="Grid">
            <Setter Property="Margin" Value="0"/>
        </Style>

        <!-- The navigation pane. One ListBox with a container style, which is all a Windows 11
             sidebar is: 32 points high, radius 4, an accent bar 3 x 16 on the chosen one. The
             chosen item is filled with the CARD colour rather than with the hover one — on the
             pane those two are four values apart in the light theme, and the bar alone was
             carrying the whole answer to "where am I".

             The glyphs are Segoe Fluent Icons with a fallback to Segoe MDL2 Assets: both ship
             with Windows, and nothing is installed. -->
        <Style x:Key="NavIcon" TargetType="TextBlock">
            <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
            <Setter Property="FontSize" Value="16"/>
            <Setter Property="Width" Value="24"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style x:Key="NavItem" TargetType="ListBoxItem">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Grid Height="32" Margin="6,1,6,1">
                            <Border x:Name="Bd" CornerRadius="4" Background="Transparent"/>
                            <Border x:Name="Bar" Width="3" Height="16" CornerRadius="2" Visibility="Collapsed"
                                    HorizontalAlignment="Left" Background="{StaticResource AccentBrush}"/>
                            <ContentPresenter VerticalAlignment="Center" Margin="14,0,10,0"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource HoverBrush}"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource CardBrush}"/>
                                <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="Nav" TargetType="ListBox">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="ItemContainerStyle" Value="{StaticResource NavItem}"/>
            <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
        </Style>

        <!-- 12,5 and not 14,6: at the larger padding the footer's Save was the biggest thing on
             a page, and the About page was a column of plates. A button is still 30 points tall,
             which is the height of every field beside it. -->
        <Style x:Key="Btn" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Padding" Value="12,5"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" CornerRadius="4" Background="{StaticResource InputBrush}"
                                BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource HoverBrush}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource PressedBrush}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnAccent" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource AccentTextBrush}"/>
            <Setter Property="Padding" Value="12,5"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" CornerRadius="4" Background="{StaticResource AccentBrush}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.9"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.8"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnSmall" TargetType="Button" BasedOn="{StaticResource Btn}">
            <Setter Property="Padding" Value="10,3"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>

        <Style x:Key="BtnSubtle" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" CornerRadius="4" Background="Transparent"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource HoverBrush}"/>
                                <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource PressedBrush}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.35"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- The fold that opens "Brightness, sound and commands". It used to be a BtnSubtle: a
             dimmed 13-point caption with a small triangle in front of it, which read as a link
             somebody had forgotten to underline rather than as a thing to press. So: the full
             width of the editor, a rule above it to say a section starts here, and the type size
             of the body text. The triangle is still the whole state indicator (see
             Set-DisclosureOpen) — it is the LABEL that grew up. -->
        <Style x:Key="Disclose" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Padding" Value="0,10,0,2"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <!-- InputBorderBrush and not CardBorderBrush for the rule: in the dark
                             theme the card's border is #232323 against a #202020 window, which
                             is a line nobody can see - and it is standing on the window here,
                             not on a card. This is the one line saying a section begins. -->
                        <Border x:Name="Bd" Background="Transparent"
                                BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="0,1,0,0"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource HoverBrush}"/>
                                <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="Toggle" TargetType="CheckBox">
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Border x:Name="Track" Width="40" Height="20" CornerRadius="10"
                                Background="Transparent" BorderBrush="{StaticResource InputBorderBrush}"
                                BorderThickness="1">
                            <Ellipse x:Name="Thumb" Width="12" Height="12" Fill="{StaticResource DimBrush}"
                                     HorizontalAlignment="Left" Margin="3,0,3,0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Track" Property="Opacity" Value="0.85"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Track" Property="Background" Value="{StaticResource AccentBrush}"/>
                                <Setter TargetName="Track" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                                <Setter TargetName="Thumb" Property="Fill" Value="{StaticResource AccentTextBrush}"/>
                                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="Check" TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="0,4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal" Background="Transparent">
                            <Border x:Name="Box" Width="18" Height="18" CornerRadius="4"
                                    Background="{StaticResource InputBrush}"
                                    BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1"
                                    VerticalAlignment="Center">
                                <Path x:Name="Mark" Data="M 3,9 L 7,13 L 14,4.5"
                                      Stroke="{StaticResource AccentTextBrush}" StrokeThickness="2"
                                      StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                                      StrokeLineJoin="Round" Visibility="Collapsed"/>
                            </Border>
                            <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource DimBrush}"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Box" Property="Background" Value="{StaticResource AccentBrush}"/>
                                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="Input" TargetType="TextBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
            <Setter Property="SelectionBrush" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Background" Value="{StaticResource InputBrush}"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="Bd" CornerRadius="4" Background="{TemplateBinding Background}"
                                BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="8,5" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource DimBrush}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="TaskbarPick" TargetType="RadioButton">
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="Bd" CornerRadius="4" Padding="6,3" Background="Transparent">
                            <StackPanel Orientation="Horizontal">
                                <Path x:Name="Star" Width="12" Height="12" Stretch="Uniform"
                                      Fill="{StaticResource DimBrush}" VerticalAlignment="Center"
                                      Data="M 6,0 L 7.6,4.2 L 12,4.4 L 8.6,7.2 L 9.8,11.5 L 6,9 L 2.2,11.5 L 3.4,7.2 L 0,4.4 L 4.4,4.2 Z"/>
                                <TextBlock x:Name="Lbl" Text="%%T:desk.taskbar%%" FontSize="12"
                                           Foreground="{StaticResource DimBrush}" Margin="5,0,0,0"
                                           VerticalAlignment="Center"/>
                            </StackPanel>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource HoverBrush}"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Star" Property="Fill" Value="{StaticResource AccentBrush}"/>
                                <Setter TargetName="Lbl" Property="Foreground" Value="{StaticResource TextBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="Bd" CornerRadius="4" Padding="8,5" Margin="2,1" Background="Transparent">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource HoverBrush}"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource PressedBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="Select" TargetType="ComboBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="Toggle" Focusable="False" ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="Bd" CornerRadius="4" Background="{StaticResource InputBrush}"
                                                BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1">
                                            <Path HorizontalAlignment="Right" Margin="0,0,10,0" VerticalAlignment="Center"
                                                  Data="M 0,0 L 4,4 L 8,0" Stroke="{StaticResource DimBrush}"
                                                  StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource HoverBrush}"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter Margin="10,5,26,5" VerticalAlignment="Center" IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
                            <Popup x:Name="PART_Popup" Placement="Bottom"
                                   IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                   AllowsTransparency="True">
                                <Border CornerRadius="8" Background="{StaticResource CardBrush}"
                                        BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1"
                                        Margin="0,4,0,0" MinWidth="{TemplateBinding ActualWidth}">
                                    <ScrollViewer MaxHeight="220">
                                        <ItemsPresenter/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- The same dropdown, but what it holds can also be typed. For the audio device
             specifically: what is stored is a PIECE of a device's name, and the list can only
             offer the whole one — a person shortens "Speakers (Realtek High Definition Audio)"
             to "Realtek" by hand so the setting survives a driver renaming the rest. An
             editable ComboBox needs PART_EditableTextBox by that exact name in the template:
             without it WPF finds nothing to type into and the box is silently read-only. -->
        <Style x:Key="SelectEdit" TargetType="ComboBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="IsEditable" Value="True"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border x:Name="Bd" CornerRadius="4" Background="{StaticResource InputBrush}"
                                    BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1"/>
                            <ToggleButton x:Name="Toggle" Focusable="False" ClickMode="Press"
                                          HorizontalAlignment="Right" Width="26" Cursor="Hand"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Background="Transparent">
                                            <Path HorizontalAlignment="Center" VerticalAlignment="Center"
                                                  Data="M 0,0 L 4,4 L 8,0" Stroke="{StaticResource DimBrush}"
                                                  StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                                        </Border>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <TextBox x:Name="PART_EditableTextBox" Margin="9,0,26,0"
                                     VerticalContentAlignment="Center" BorderThickness="0" Padding="0"
                                     Background="Transparent" Foreground="{StaticResource TextBrush}"
                                     CaretBrush="{StaticResource TextBrush}"
                                     SelectionBrush="{StaticResource AccentBrush}"
                                     FocusVisualStyle="{x:Null}"/>
                            <Popup x:Name="PART_Popup" Placement="Bottom"
                                   IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                   AllowsTransparency="True">
                                <Border CornerRadius="8" Background="{StaticResource CardBrush}"
                                        BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1"
                                        Margin="0,4,0,0" MinWidth="{TemplateBinding ActualWidth}">
                                    <ScrollViewer MaxHeight="220">
                                        <ItemsPresenter/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ScrollThumb" TargetType="Thumb">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border CornerRadius="3" Background="{StaticResource ScrollBrush}" Margin="2"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Track x:Name="PART_Track" IsDirectionReversed="True">
                            <Track.DecreaseRepeatButton>
                                <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                            </Track.DecreaseRepeatButton>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                            </Track.IncreaseRepeatButton>
                            <Track.Thumb>
                                <Thumb Style="{StaticResource ScrollThumb}"/>
                            </Track.Thumb>
                        </Track>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Width" Value="Auto"/>
                    <Setter Property="Height" Value="10"/>
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="ScrollBar">
                                <Track x:Name="PART_Track">
                                    <Track.DecreaseRepeatButton>
                                        <RepeatButton Command="ScrollBar.PageLeftCommand" Opacity="0" Focusable="False"/>
                                    </Track.DecreaseRepeatButton>
                                    <Track.IncreaseRepeatButton>
                                        <RepeatButton Command="ScrollBar.PageRightCommand" Opacity="0" Focusable="False"/>
                                    </Track.IncreaseRepeatButton>
                                    <Track.Thumb>
                                        <Thumb Style="{StaticResource ScrollThumb}"/>
                                    </Track.Thumb>
                                </Track>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- The timer window's big field: the figure itself, with no box around it. A field and
             not a label — it can be typed into; but it has to look like a value rather than like
             a form, which is why the border only appears under the cursor and on focus, and only
             along the bottom. -->
        <Style x:Key="Big" TargetType="TextBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="CaretBrush" Value="{StaticResource AccentBrush}"/>
            <Setter Property="SelectionBrush" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="FontSize" Value="30"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="Bd" Background="Transparent"
                                BorderBrush="Transparent" BorderThickness="0,0,0,2">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="0,0,0,2" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource InputBorderBrush}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- The quick-value pill: "15 min", "1 h". Outlined in the accent under the cursor rather
             than filled — there are several of them in a row, and a fill would turn the row into a
             traffic light. The radius here is half the height rather than the window's four: the
             shape IS the "press me" caption, and this is the very exception the contract keeps its
             proviso about signature surfaces for. -->
        <Style x:Key="Chip" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="12,4"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" CornerRadius="13" Background="{StaticResource MiniBrush}"
                                BorderBrush="Transparent" BorderThickness="1"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource PressedBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- The same pill, chosen. Filled, because here the row IS a choice of one out of four
             (the diary's period) rather than four separate offers: an outline would say "under the
             cursor" and not "this is the one you are looking at". -->
        <Style x:Key="ChipOn" TargetType="Button" BasedOn="{StaticResource Chip}">
            <Setter Property="Foreground" Value="{StaticResource AccentTextBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border CornerRadius="13" Background="{StaticResource AccentBrush}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
'@

$script:SettingsWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="%%T:win.settings%%"
        Width="880" Height="620" MinWidth="760" MinHeight="520"
        ResizeMode="CanResize" WindowStartupLocation="CenterScreen" ShowInTaskbar="True"
        Background="%%BG%%" Foreground="%%TEXT%%"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        UseLayoutRounding="True">
    <Window.Resources>
%%RES%%
    </Window.Resources>
    <!-- 880 x 620 and a pane of 200. It opened at 980 x 700, which on a 2560 x 1440 screen at
         150 % is 1470 x 1050 pixels — more than half the screen for a page that was a third
         full. The minimum is what the widest page still needs: the mode list's four columns and
         the diary's three cards across. -->
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="200"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- The pane. Two lists rather than one: About sits at the bottom, where Windows keeps
             its own Settings item, and a single ListBox cannot have a gap in the middle of it.
             What keeps them from both looking chosen at once is Set-UiPage. -->
        <Border Background="{StaticResource PaneBrush}"
                BorderBrush="{StaticResource CardBorderBrush}" BorderThickness="0,0,1,0">
            <DockPanel LastChildFill="False">
                <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="20,16,12,14">
                    <TextBlock Style="{StaticResource NavIcon}" Foreground="{StaticResource AccentBrush}"
                               FontSize="18" Text="&#xE7F4;"/>
                    <TextBlock Text="DeskModes" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
                </StackPanel>
                <ListBox x:Name="NavList" DockPanel.Dock="Top" Style="{StaticResource Nav}">
                    <ListBoxItem Tag="desk">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Style="{StaticResource NavIcon}" Text="&#xE7F4;"/>
                            <TextBlock Text="%%T:nav.desk%%" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ListBoxItem>
                    <ListBoxItem Tag="modes">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Style="{StaticResource NavIcon}" Text="&#xE8A9;"/>
                            <TextBlock Text="%%T:nav.modes%%" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ListBoxItem>
                    <ListBoxItem Tag="rules">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Style="{StaticResource NavIcon}" Text="&#xE945;"/>
                            <TextBlock Text="%%T:nav.rules%%" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ListBoxItem>
                    <ListBoxItem Tag="behavior">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Style="{StaticResource NavIcon}" Text="&#xE713;"/>
                            <TextBlock Text="%%T:nav.behavior%%" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ListBoxItem>
                    <ListBoxItem Tag="diary">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Style="{StaticResource NavIcon}" Text="&#xE787;"/>
                            <TextBlock Text="%%T:nav.diary%%" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ListBoxItem>
                </ListBox>
                <ListBox x:Name="NavAbout" DockPanel.Dock="Bottom" Style="{StaticResource Nav}" Margin="0,0,0,10">
                    <ListBoxItem Tag="about">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Style="{StaticResource NavIcon}" Text="&#xE946;"/>
                            <TextBlock Text="%%T:nav.about%%" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ListBoxItem>
                </ListBox>
            </DockPanel>
        </Border>

        <Grid Grid.Column="1">
            <Grid.RowDefinitions>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid x:Name="PageHost">

                <!-- Your desk -->
                <Grid x:Name="DeskPage">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Margin="24,20,24,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock Style="{StaticResource H1}" Text="%%T:nav.desk%%"/>
                            <TextBlock Style="{StaticResource Hint}" Margin="0"
                                       Text="%%T:desk.hint%%"/>
                        </StackPanel>
                        <!-- Two commands in the page's head, like Add a combination on the next
                             page. "Copy from Windows" takes the order and the taskbar off the desk
                             as it stands this second, which on a first run is the whole set-up in
                             one click; "Which is which" puts a badge on every display for a moment,
                             because three cards that all say LG tell nobody which LG. -->
                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
                            <Button x:Name="IdentifyBtn" Style="{StaticResource Btn}" Content="%%T:desk.whichIsWhich%%"
                                    ToolTip="%%T:desk.whichIsWhich.tip%%"/>
                            <Button x:Name="ReadDeskBtn" Style="{StaticResource Btn}" Content="%%T:desk.copy%%" Margin="8,0,0,0"
                                    ToolTip="%%T:desk.copy.tip%%"/>
                        </StackPanel>
                    </Grid>
                    <ScrollViewer x:Name="DeskScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="24,4,24,4">
                        <StackPanel>
                            <!-- This drawing is Windows' current geometry, kept separate from the
                                 saved order below. Reordering a switch must never make the page lie
                                 about where a portrait panel or a raised side panel stands now. -->
                            <Border Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Style="{StaticResource H2}" Text="%%T:desk.live%%"/>
                                    <TextBlock Style="{StaticResource Hint}" Text="%%T:desk.live.hint%%"/>
                                    <Canvas x:Name="LiveDeskCanvas" Height="150" Margin="0,10,0,0"
                                            ClipToBounds="True"/>
                                </StackPanel>
                            </Border>
                            <!-- One slot per display, filling the card's whole width whatever the
                                 window is; the screen inside each slot is drawn against the slot
                                 it actually got (Update-DeskShapes, on SizeChanged).

                                 It was a WrapPanel of 140-point cards, and that was wrong twice
                                 over: on a desk of three it left the right half of the card
                                 empty, and on a desk of five it dropped to a second row - which
                                 makes "arrange them left to right" a lie, the fifth display
                                 sitting visually left of the fourth.

                                 The -4 cancels the cards' own outer margins, so the leftmost
                                 screen lines up with the card's padding rather than 4 points in. -->
                            <Border Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Style="{StaticResource H2}" Text="%%T:desk.saved%%"/>
                                    <TextBlock Style="{StaticResource Hint}" Text="%%T:desk.saved.hint%%"/>
                                    <UniformGrid x:Name="DeskPanel" Rows="1" Margin="-4,6,-4,0"/>
                                </StackPanel>
                            </Border>
                            <Border Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Style="{StaticResource H2}" Text="%%T:displays.heading%%"/>
                                    <TextBlock Style="{StaticResource Hint}"
                                               Text="%%T:desk.table.hint%%"/>
                                    <Grid x:Name="DisplaysTable"/>
                                </StackPanel>
                            </Border>
                            <!-- Windows' own setting, not one of ours: it is the same question as
                                 "which displays are on", and looking for it in the Control Panel in
                                 the middle of arranging a desk is a detour. -->
                            <Border Style="{StaticResource Card}">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <StackPanel Margin="0,0,16,0">
                                        <TextBlock Style="{StaticResource RowTitle}" Text="%%T:desk.sleep%%"/>
                                        <TextBlock x:Name="SleepHint" Style="{StaticResource RowSub}"
                                                   Text="%%T:desk.sleep.hint%%"/>
                                    </StackPanel>
                                    <ComboBox x:Name="SleepBox" Grid.Column="1" Style="{StaticResource Select}"
                                              Width="196" Height="30" VerticalAlignment="Center"/>
                                </Grid>
                            </Border>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>

                <!-- Modes -->
                <Grid x:Name="ModesPage" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Margin="24,20,24,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock Style="{StaticResource H1}" Text="%%T:nav.modes%%"/>
                            <TextBlock Style="{StaticResource Hint}" Margin="0"
                                       Text="%%T:modes.hint%%"/>
                        </StackPanel>
                        <!-- The command stands in the page's head, not under the list: with a
                             dozen modes, adding one meant scrolling to the bottom first. -->
                        <Button x:Name="AddComboBtn" Grid.Column="1" Style="{StaticResource Btn}"
                                Content="%%T:modes.add%%" VerticalAlignment="Center" Margin="16,0,0,0"/>
                    </Grid>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="24,4,24,4">
                        <!-- Top, not stretched: a card is as tall as what is in it. A list of
                             three modes in a card the height of the window reads as a list that
                             lost the rest of itself. -->
                        <Border Style="{StaticResource Card}" VerticalAlignment="Top">
                            <StackPanel x:Name="ModesPanel"/>
                        </Border>
                    </ScrollViewer>
                </Grid>

                <!-- Rules -->
                <Grid x:Name="RulesPage" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Margin="24,20,24,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock Style="{StaticResource H1}" Text="%%T:nav.rules%%"/>
                            <TextBlock Style="{StaticResource Hint}" Margin="0"
                                       Text="%%T:rules.hint%%"/>
                        </StackPanel>
                        <Button x:Name="AddRuleBtn" Grid.Column="1" Style="{StaticResource Btn}"
                                Content="%%T:rules.add%%" VerticalAlignment="Center" Margin="16,0,0,0"/>
                    </Grid>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="24,4,24,4">
                        <Border Style="{StaticResource Card}" VerticalAlignment="Top">
                            <StackPanel x:Name="RulesPanel"/>
                        </Border>
                    </ScrollViewer>
                </Grid>

                <!-- Behavior -->
                <Grid x:Name="BehaviorPage" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <StackPanel Margin="24,20,24,10">
                        <TextBlock Style="{StaticResource H1}" Text="%%T:nav.behavior%%"/>
                        <TextBlock Style="{StaticResource Hint}" Margin="0" Text="%%T:behavior.hint%%"/>
                    </StackPanel>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="24,4,24,4">
                        <StackPanel>
                            <!-- Both cards carry a heading. With one of them titled and the other
                                 not, the two read as different kinds of content — a list of
                                 settings above, a section below — when they are the same thing
                                 twice: rows with a switch on the right. -->
                            <Border Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Style="{StaticResource H2}" Text="%%T:behavior.dayToDay%%"/>
                                    <!-- First on the page, and above Start with Windows: somebody who
                                         cannot read the rest of this window has to be able to find the
                                         one row that fixes that, and looking for it is exactly what they
                                         cannot do. -->
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:behavior.language%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" Text="%%T:behavior.language.hint%%"/>
                                        </StackPanel>
                                        <ComboBox x:Name="LanguageBox" Grid.Column="1" Style="{StaticResource Select}"
                                                  Width="170" Height="30" VerticalAlignment="Center"/>
                                    </Grid>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:behavior.startup%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" Text="%%T:behavior.startup.hint%%"/>
                                        </StackPanel>
                                        <CheckBox x:Name="StartupBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                                    </Grid>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:behavior.notifications%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" Text="%%T:behavior.notifications.hint%%"/>
                                        </StackPanel>
                                        <CheckBox x:Name="NotifyBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                                    </Grid>
                                    <!-- The one shortcut that is not a mode's. It lives here and not on the
                                         Modes page because it has no row there to live on, and a person
                                         who wants it is a person whose last switch went wrong - a key
                                         pressed blind, which is why it can be set at all. -->
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:behavior.back%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" TextWrapping="Wrap"
                                                       Text="%%T:behavior.back.hint%%"/>
                                        </StackPanel>
                                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                                            <TextBox x:Name="BackHotkeyBox" Style="{StaticResource Input}" Width="150" Height="30" TextAlignment="Center"/>
                                            <Button x:Name="ClearBackHotkeyBtn" Style="{StaticResource Btn}" Content="&#x00D7;"
                                                    FontSize="15" Width="30" Height="30" Padding="0" Margin="6,0,0,0"
                                                    ToolTip="%%T:hotkey.clear%%"/>
                                        </StackPanel>
                                    </Grid>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:behavior.windows%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" Text="%%T:behavior.windows.hint%%"/>
                                        </StackPanel>
                                        <CheckBox x:Name="WindowsBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                                    </Grid>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:behavior.lastMode%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" Text="%%T:behavior.lastMode.hint%%"/>
                                        </StackPanel>
                                        <CheckBox x:Name="LastModeBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                                    </Grid>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:behavior.diary%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" TextWrapping="Wrap"
                                                       Text="%%T:behavior.diary.hint%%"/>
                                        </StackPanel>
                                        <CheckBox x:Name="StatsBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                                    </Grid>
                                </StackPanel>
                            </Border>
                            <!-- Four settings nobody changes twice: a watchdog that should just
                                 work, and three answers to "what should happen when Windows
                                 rearranges the desk behind my back" - a question with a right
                                 default. They used to be folded away to keep the window short
                                 enough for a screen; a page of its own has the room. -->
                            <Border Style="{StaticResource Card}">
                                <StackPanel>
                                    <!-- No subtitle. "Three answers with a right default, and a
                                         watchdog that should just work" told a person nothing
                                         they could act on — it described the section to whoever
                                         wrote it. The four rows say what they do themselves. -->
                                    <TextBlock Style="{StaticResource H2}" Text="%%T:behavior.reapply%%"
                                               Margin="0,0,0,2"/>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:behavior.refresh%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" Text="%%T:behavior.refresh.hint%%"/>
                                        </StackPanel>
                                        <CheckBox x:Name="RefreshBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                                    </Grid>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:behavior.onResume%%"/>
                                        </StackPanel>
                                        <CheckBox x:Name="ResumeBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                                    </Grid>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:behavior.onUnplug%%"/>
                                        </StackPanel>
                                        <CheckBox x:Name="UnplugBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                                    </Grid>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:behavior.onPlug%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" Text="%%T:behavior.onPlug.hint%%"/>
                                        </StackPanel>
                                        <ComboBox x:Name="PlugModeBox" Grid.Column="1" Style="{StaticResource Select}"
                                                  Width="196" Height="30" VerticalAlignment="Center"/>
                                    </Grid>
                                </StackPanel>
                            </Border>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>

                <!-- Diary. It used to be a window of its own, 880 points wide; here it is a page
                     like the others, and a wider one.

                     It scrolls, and the sections are as tall as what is in them. Stretching them
                     to the window instead was tried and taken out: four sections of five rows want
                     about 865 points of window, the window opens at 660, and what came of the
                     difference was a list arranged into a cell too small for it - five rows in the
                     tree, one of them drawn. A page that scrolls says the same thing without
                     lying about it. -->
                <Grid x:Name="DiaryPage" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Margin="24,20,24,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock Style="{StaticResource H1}" Text="%%T:nav.diary%%"/>
                            <!-- NoWrap, and the sentence itself is shorter (see
                                 Get-StatsRangeText). Wrapping, it took a second line and walked
                                 straight into the period pills standing beside it: four pills, a
                                 button, a title and a two-line caption in one strip. -->
                            <TextBlock x:Name="RangeText" Style="{StaticResource Hint}" Margin="0"
                                       TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                        <!-- The period is chosen where the diary is read: "today" and "all of it"
                             are different questions, and both get asked in the same minute. -->
                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
                            <StackPanel x:Name="PeriodRow" Orientation="Horizontal" VerticalAlignment="Center"/>
                            <Button x:Name="PageBtn" Style="{StaticResource Btn}" Content="%%T:diary.page%%" Margin="8,0,0,0"
                                    ToolTip="%%T:diary.page.tip%%"/>
                        </StackPanel>
                    </Grid>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="24,4,24,4">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <!-- Three by two, not six across: "09:40-23:15" is the widest value there
                             is, and six columns of a page's width leave it nowhere to stand. -->
                        <UniformGrid x:Name="CardsPanel" Rows="2" Columns="3" Margin="-4,0,-4,12"/>
                        <Border Grid.Row="1" Style="{StaticResource Card}">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>
                                <TextBlock Style="{StaticResource H2}" Text="%%T:diary.timeOfDay%%"/>
                                <UniformGrid x:Name="HoursPanel" Grid.Row="1" Rows="1" Columns="24" Height="88"/>
                                <UniformGrid x:Name="HourLabels" Grid.Row="2" Rows="1" Columns="24" Margin="0,4,0,0"/>
                            </Grid>
                        </Border>
                        <Grid Grid.Row="2">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <Border Style="{StaticResource Card}" Margin="0,0,6,12">
                                <StackPanel>
                                    <TextBlock Style="{StaticResource H2}" Text="%%T:displays.heading%%"/>
                                    <StackPanel x:Name="DisplayRows"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="1" Style="{StaticResource Card}" Margin="6,0,0,12">
                                <StackPanel>
                                    <TextBlock Style="{StaticResource H2}" Text="%%T:nav.modes%%"/>
                                    <StackPanel x:Name="ModeRows"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,0,6,0">
                                <StackPanel>
                                    <TextBlock Style="{StaticResource H2}" Text="%%T:diary.apps%%"/>
                                    <StackPanel x:Name="AppRows"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Row="1" Grid.Column="1" Style="{StaticResource Card}" Margin="6,0,0,0">
                                <StackPanel>
                                    <TextBlock Style="{StaticResource H2}" Text="%%T:diary.appOnDisplay%%"/>
                                    <StackPanel x:Name="PairRows"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </Grid>
                    </ScrollViewer>
                </Grid>

                <!-- About -->
                <Grid x:Name="AboutPage" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <!-- The head carries the promise and nothing else. It used to carry the whole
                         version line as well - name, version, Windows build, PowerShell build and
                         the promise, five facts in one sentence that wrapped onto two lines. The
                         version is a row of the card below now, on two short lines of its own. -->
                    <StackPanel Margin="24,20,24,10">
                        <TextBlock Style="{StaticResource H1}" Text="%%T:nav.about%%"/>
                        <TextBlock Style="{StaticResource Hint}" Margin="0"
                                   Text="%%T:about.folder%%"/>
                    </StackPanel>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="24,4,24,4">
                        <StackPanel>
                            <!-- Every button in this card is the same width. Three of them were
                                 132 and "Open the log" was 108, which read as one of them having
                                 come out wrong rather than as four doors.

                                 MinWidth and not Width: on a desk with Windows' text scaled up,
                                 a fixed 140 clips "Report a problem" and a clipped label is
                                 worse than an uneven row. At the ordinary scale they are all
                                 exactly 140, which is what this is for. -->
                            <Border Style="{StaticResource Card}">
                                <StackPanel>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock x:Name="VersionText" Style="{StaticResource RowTitle}"/>
                                            <TextBlock x:Name="VersionHost" Style="{StaticResource RowSub}"/>
                                        </StackPanel>
                                        <Button x:Name="CopyVersionBtn" Grid.Column="1" Style="{StaticResource Btn}"
                                                Content="%%T:common.copy%%" VerticalAlignment="Center" MinWidth="140"
                                                ToolTip="%%T:about.copy.tip%%"/>
                                    </Grid>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:about.project%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" Text="%%T:about.project.hint%%"/>
                                        </StackPanel>
                                        <Button x:Name="RepoBtn" Grid.Column="1" Style="{StaticResource Btn}" Content="%%T:common.open%%"
                                                VerticalAlignment="Center" MinWidth="140"/>
                                    </Grid>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:about.trouble%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" Text="%%T:about.trouble.hint%%"/>
                                        </StackPanel>
                                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                                            <Button x:Name="LogBtn" Style="{StaticResource Btn}" Content="%%T:about.openLog%%" MinWidth="140"/>
                                            <Button x:Name="IssueBtn" Style="{StaticResource Btn}" Content="%%T:about.report%%"
                                                    MinWidth="140" Margin="8,0,0,0"/>
                                        </StackPanel>
                                    </Grid>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:about.diagnostics%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" Text="%%T:about.diagnostics.hint%%"/>
                                        </StackPanel>
                                        <Button x:Name="DiagnosticsBtn" Grid.Column="1" Style="{StaticResource Btn}"
                                                Content="%%T:about.diagnostics.copy%%" VerticalAlignment="Center"/>
                                    </Grid>
                                    <Grid Style="{StaticResource Row}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:about.where%%"/>
                                            <TextBlock Style="{StaticResource RowSub}" Text="%%T:about.where.hint%%"/>
                                        </StackPanel>
                                        <Button x:Name="FolderBtn" Grid.Column="1" Style="{StaticResource Btn}" Content="%%T:about.openFolder%%"
                                                VerticalAlignment="Center" MinWidth="140"/>
                                    </Grid>
                                </StackPanel>
                            </Border>
                            <!-- Collapsed whole while there is no address (see New-SettingsWindow).
                                 A disabled BtnAccent is a grey-blue plate the size of the page's
                                 primary action, and it read as the one button on the page that was
                                 broken. Nothing to say is better said by saying nothing. -->
                            <Border x:Name="SupportCard" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Style="{StaticResource H2}" Text="%%T:about.support%%"/>
                                    <TextBlock Style="{StaticResource Hint}"
                                               Text="%%T:about.support.hint%%"/>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Margin="0,0,16,0">
                                            <TextBlock Style="{StaticResource RowTitle}" Text="%%T:about.donate%%"/>
                                            <TextBlock x:Name="DonateHint" Style="{StaticResource RowSub}" Text="%%T:about.donate.tip%%"/>
                                        </StackPanel>
                                        <Button x:Name="DonateBtn" Grid.Column="1" Style="{StaticResource BtnAccent}" Content="%%T:about.donate%%"
                                                VerticalAlignment="Center" MinWidth="140"/>
                                    </Grid>
                                </StackPanel>
                            </Border>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>

            </Grid>

            <!-- 84, not 96: at 96 with the old padding these two were the largest elements on
                 the screen, and the footer read as the point of the window rather than as the
                 way out of it. The second one says "Close" while there is nothing to save and
                 "Cancel" once there is (see Update-UiFooter) - on the Diary and About pages
                 there is nothing to cancel, and a button offering to throw work away when there
                 is none is a question a person has to stop and answer. -->
            <Border Grid.Row="1" Background="{StaticResource FooterBrush}"
                    BorderBrush="{StaticResource CardBorderBrush}" BorderThickness="0,1,0,0" Padding="24,10">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button x:Name="SaveBtn" Style="{StaticResource BtnAccent}" Content="%%T:common.save%%" MinWidth="84" IsDefault="True"/>
                    <Button x:Name="CancelBtn" Style="{StaticResource Btn}" Content="%%T:common.cancel%%" MinWidth="84" Margin="8,0,0,0" IsCancel="True"/>
                </StackPanel>
            </Border>
        </Grid>
    </Grid>
</Window>
'@

$script:ModeEditorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="%%T:win.mode%%"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        Background="%%BG%%" Foreground="%%TEXT%%"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        UseLayoutRounding="True">
    <Window.Resources>
%%RES%%
    </Window.Resources>
    <DockPanel LastChildFill="True">
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right"
                    Margin="20,14,20,14">
            <Button x:Name="OkBtn" Style="{StaticResource BtnAccent}" Content="%%T:common.save%%" MinWidth="84" IsDefault="True"/>
            <Button x:Name="CancelBtn" Style="{StaticResource Btn}" Content="%%T:common.cancel%%" MinWidth="84" Margin="8,0,0,0" IsCancel="True"/>
        </StackPanel>
        <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto">
            <!-- 430 and not 400: every hint in here wraps, and thirty points of width is a line
                 saved on most of them. The editor is the tallest window in the program - it is
                 cheaper to widen it than to let it grow downwards. -->
            <StackPanel Margin="20,16,20,0" Width="430">
                <TextBlock x:Name="HeadTitle" Style="{StaticResource H1}" Text="%%T:editor.mode%%"/>
                <TextBlock x:Name="HeadHint" Style="{StaticResource Hint}"/>
                <StackPanel x:Name="ComboPart" Margin="0,10,0,0">
                    <TextBlock Style="{StaticResource H2}" Text="%%T:editor.name%%"/>
                    <TextBox x:Name="NameBox" Style="{StaticResource Input}" Margin="0,4,0,0"/>
                    <TextBlock Style="{StaticResource H2}" Text="%%T:displays.heading%%" Margin="0,14,0,0"/>
                    <TextBlock Style="{StaticResource Hint}" Text="%%T:editor.displays.hint%%"/>
                    <StackPanel x:Name="MembersPanel"/>
                    <TextBlock Style="{StaticResource H2}" Text="%%T:desk.taskbar%%" Margin="0,14,0,0"/>
                    <TextBlock Style="{StaticResource Hint}" Text="%%T:editor.taskbar.hint%%"/>
                    <ComboBox x:Name="PrimaryBox" Style="{StaticResource Select}" Height="30"/>
                </StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="%%T:editor.shortcut%%" Margin="0,14,0,0"/>
                <TextBlock Style="{StaticResource Hint}" Text="%%T:editor.shortcut.hint%%"/>
                <!-- The cross is a bordered square the height of the field beside it. As a
                     BtnSubtle 26 wide it was a bare glyph floating off the field's centre - the
                     multiplication sign is centred on the maths axis rather than on the text
                     one - and nobody read it as a button at all. -->
                <StackPanel Orientation="Horizontal">
                    <TextBox x:Name="HotkeyBox" Style="{StaticResource Input}" Width="150" Height="30" TextAlignment="Center"/>
                    <Button x:Name="ClearHotkeyBtn" Style="{StaticResource Btn}" Content="&#x00D7;"
                            FontSize="15" Width="30" Height="30" Padding="0" Margin="6,0,0,0"
                            ToolTip="%%T:hotkey.clear%%"/>
                </StackPanel>
                <!-- Everything a mode does to the HARDWARE, folded away. What a mode IS
                     stays above: its name, its displays, where the taskbar goes and the keys
                     that reach it. These four all mean "leave it alone" until asked, and the
                     editor was a window and a half tall with them unfolded.

                     It opens by itself when any of them is set, including a setting inherited
                     from the name just typed (see Sync-EditorInheritance) - a setting nobody
                     can see is the one bug this whole change exists to close. -->
                <Button x:Name="MoreBtn" Style="{StaticResource Disclose}"
                        Margin="0,16,0,0" Content="%%T:editor.more%%"/>
                <StackPanel x:Name="MorePanel" Visibility="Collapsed">
                    <!-- "Ask the monitors" stands beside the Brightness heading rather than
                         between the contrast rows and the picture preset, where it used to sit:
                         one walk of the bus answers for brightness AND contrast, so the button
                         belongs to the pair of sections and not to a gap between them. In the gap
                         it read as belonging to whichever section it happened to touch. -->
                    <Grid Margin="0,14,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource H2}" Text="%%T:editor.brightness%%" VerticalAlignment="Center"/>
                        <Button x:Name="LevelTestBtn" Grid.Column="1" Style="{StaticResource BtnSmall}"
                                Content="%%T:editor.ask%%" VerticalAlignment="Center"/>
                    </Grid>
                    <TextBlock Style="{StaticResource Hint}"
                               Text="%%T:editor.brightness.hint%%"/>
                    <!-- Collapsed while it has nothing to say: an empty TextBlock still spends
                         its Margin, so two of these left a double gap in the middle of the
                         window whenever nobody had pressed the button (see Set-UiNote). -->
                    <TextBlock x:Name="LevelNote" Style="{StaticResource RowSub}" Margin="0,0,0,8"
                               TextWrapping="Wrap" Visibility="Collapsed"/>
                    <ComboBox x:Name="LevelKindBox" Style="{StaticResource Select}" Height="30"/>
                    <Grid x:Name="LevelOnePanel" Margin="0,10,0,0" Visibility="Collapsed">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Slider x:Name="LevelOneSlider" Style="{StaticResource Level}" VerticalAlignment="Center"/>
                        <TextBlock x:Name="LevelOneValue" Grid.Column="1" Width="34" TextAlignment="Right"
                                   VerticalAlignment="Center" Margin="12,0,0,0"/>
                    </Grid>
                    <StackPanel x:Name="LevelRowsPanel" Margin="0,6,0,0"/>
                    <TextBlock Style="{StaticResource H2}" Text="%%T:editor.contrast%%" Margin="0,14,0,0"/>
                    <TextBlock Style="{StaticResource Hint}"
                               Text="%%T:editor.contrast.hint%%"/>
                    <ComboBox x:Name="ContrastKindBox" Style="{StaticResource Select}" Height="30"/>
                    <Grid x:Name="ContrastOnePanel" Margin="0,10,0,0" Visibility="Collapsed">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Slider x:Name="ContrastOneSlider" Style="{StaticResource Level}" VerticalAlignment="Center"/>
                        <TextBlock x:Name="ContrastOneValue" Grid.Column="1" Width="34" TextAlignment="Right"
                                   VerticalAlignment="Center" Margin="12,0,0,0"/>
                    </Grid>
                    <StackPanel x:Name="ContrastRowsPanel" Margin="0,6,0,0"/>
                    <!-- The monitor's own picture preset. No list and no names: which number is
                         which preset is the vendor's business, and on this desk one monitor calls
                         two different numbers "Gamer 1". What is remembered is the number the
                         monitor is holding at the moment the button is pressed. -->
                    <TextBlock Style="{StaticResource H2}" Text="%%T:editor.picture%%" Margin="0,14,0,0"/>
                    <TextBlock Style="{StaticResource Hint}"
                               Text="%%T:editor.picture.hint%%"/>
                    <StackPanel x:Name="PicturePanel"/>
                    <TextBlock x:Name="PictureNote" Style="{StaticResource RowSub}" Margin="0,8,0,0"
                               TextWrapping="Wrap" Visibility="Collapsed"/>
                    <!-- Windows' own HDR switch, per display. "Leave alone" is the default and
                         costs nothing on a switch; a display that cannot do HDR is left alone
                         whatever is chosen, and the log says so. -->
                    <TextBlock Style="{StaticResource H2}" Text="%%T:editor.hdr%%" Margin="0,14,0,0"/>
                    <TextBlock Style="{StaticResource Hint}"
                               Text="%%T:editor.hdr.hint%%"/>
                    <StackPanel x:Name="HdrPanel"/>
                    <TextBlock Style="{StaticResource H2}" Text="%%T:editor.audio%%" Margin="0,14,0,0"/>
                    <TextBlock Style="{StaticResource Hint}"
                               Text="%%T:editor.audio.hint%%"/>
                    <ComboBox x:Name="AudioBox" Style="{StaticResource SelectEdit}" Height="30"/>
                    <TextBlock Style="{StaticResource H2}" Text="%%T:editor.hooks%%" Margin="0,14,0,0"/>
                    <TextBlock Style="{StaticResource Hint}"
                               Text="%%T:editor.hooks.hint%%"/>
                    <TextBlock Style="{StaticResource RowSub}" Text="%%T:editor.before%%" Margin="0,0,0,3"/>
                    <TextBox x:Name="HookBeforeBox" Style="{StaticResource Input}"/>
                    <TextBlock Style="{StaticResource RowSub}" Text="%%T:editor.after%%" Margin="0,8,0,3"/>
                    <TextBox x:Name="HookAfterBox" Style="{StaticResource Input}"/>
                </StackPanel>
            </StackPanel>
        </ScrollViewer>
    </DockPanel>
</Window>
'@

$script:RuleEditorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="%%T:win.rule%%"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        Background="%%BG%%" Foreground="%%TEXT%%"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        UseLayoutRounding="True">
    <Window.Resources>
%%RES%%
    </Window.Resources>
    <DockPanel LastChildFill="True">
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right"
                    Margin="20,14,20,14">
            <Button x:Name="OkBtn" Style="{StaticResource BtnAccent}" Content="%%T:common.save%%" MinWidth="84" IsDefault="True"/>
            <Button x:Name="CancelBtn" Style="{StaticResource Btn}" Content="%%T:common.cancel%%" MinWidth="84" Margin="8,0,0,0" IsCancel="True"/>
        </StackPanel>
        <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="20,16,20,0" Width="430">
                <TextBlock Style="{StaticResource H1}" Text="%%T:rule.heading%%"/>
                <TextBlock Style="{StaticResource Hint}"
                           Text="%%T:rule.hint%%"/>
                <TextBlock Style="{StaticResource H2}" Text="%%T:rule.when%%"/>
                <ComboBox x:Name="WhenBox" Style="{StaticResource Select}" Height="30"/>
                <!-- The two conditions want different questions, so only one panel is up at a
                     time. Both are built: swapping visibility keeps what was typed in the other
                     one, and a person who tries both ways round does not retype it. -->
                <!-- Both conditions are labelled the way every other field in this window is: an
                     H2 for the name of the thing and a Hint under it. They used to carry a RowSub
                     above the control instead - a dimmed caption where the three fields around
                     them had headings, so the window had two kinds of label for one kind of
                     field. -->
                <StackPanel x:Name="ProcessPanel" Margin="0,14,0,0">
                    <TextBlock Style="{StaticResource H2}" Text="%%T:rule.process%%"/>
                    <TextBlock Style="{StaticResource Hint}" Text="%%T:rule.process.hint%%"/>
                    <!-- Editable: the list is what is running now and what the diary has seen, and a
                         rule is often written for a game that is doing neither at that moment. -->
                    <ComboBox x:Name="ProcessBox" Style="{StaticResource SelectEdit}" Height="30"/>
                </StackPanel>
                <StackPanel x:Name="IdlePanel" Margin="0,14,0,0" Visibility="Collapsed">
                    <TextBlock Style="{StaticResource H2}" Text="%%T:rule.idle%%"/>
                    <TextBlock Style="{StaticResource Hint}" Text="%%T:rule.idle.hint%%"/>
                    <TextBox x:Name="MinutesBox" Style="{StaticResource Input}" Width="90" Height="30"
                             HorizontalAlignment="Left"/>
                </StackPanel>
                <!-- The desk as a condition: a laptop docked at home has these two monitors, at the
                     office that one, on the train none. Exactly these and no others, or the office
                     rule would fire at home as well. The ticks come from the roster, so a display
                     that is off right now can be ticked - the desk it describes is usually not the
                     one in front of you while you write the rule. -->
                <StackPanel x:Name="DisplaysPanel" Margin="0,14,0,0" Visibility="Collapsed">
                    <TextBlock Style="{StaticResource H2}" Text="%%T:rule.displays%%"/>
                    <TextBlock Style="{StaticResource Hint}"
                               Text="%%T:rule.displays.hint%%"/>
                    <StackPanel x:Name="DisplaysChecks"/>
                </StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="%%T:rule.mode%%" Margin="0,14,0,0"/>
                <ComboBox x:Name="ModeBox" Style="{StaticResource Select}" Height="30"/>
                <TextBlock Style="{StaticResource H2}" Text="%%T:rule.back%%" Margin="0,14,0,0"/>
                <TextBlock Style="{StaticResource Hint}"
                           Text="%%T:rule.back.hint%%"/>
                <ComboBox x:Name="BackBox" Style="{StaticResource Select}" Height="30"/>
            </StackPanel>
        </ScrollViewer>
    </DockPanel>
</Window>
'@

# The markup holds keys rather than sentences, and this is where the sentences arrive. Escaped on
# the way in, because a translation is prose: an apostrophe, a quote or an ampersand inside an XML
# attribute takes the whole window down at parse time, and the window that dies is the one nobody
# who reads that language can open.
function Expand-UiText {
    param([string]$Text)

    return [regex]::Replace($Text, '%%T:([A-Za-z0-9_.]+)%%', {
        param($m)
        $value = Get-Text -Key $m.Groups[1].Value
        return $value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    })
}

# Parse the markup, substituting the palette. The shared resources arrive on the %%RES%% token.
function Convert-UiXaml {
    param([string]$Xaml, $Palette)

    $text = $Xaml.Replace('%%RES%%', $script:UiResourcesXaml)
    foreach ($key in $Palette.Keys) {
        $text = $text.Replace('%%' + $key + '%%', [string]$Palette[$key])
    }
    # After the palette: a palette value is a colour and can hold no text token, whereas a
    # translation could easily hold a %% of its own and must not be read as one.
    $text = Expand-UiText -Text $text
    $root = [System.Windows.Markup.XamlReader]::Parse($text)
    Register-WheelPassThrough -Root $root
    return $root
}

# --- the wheel over a closed drop-down --------------------------------------
# WPF's ComboBox steps its own selection on a turn of the wheel whenever its list is shut,
# and every box here sits on a page that scrolls. So the wheel, with the cursor over a box
# somebody had just picked from, silently changed the pick instead of scrolling the page -
# silently, because a shut box looks the same whatever is inside it. Somebody scrolling the
# mode editor down to the hooks would arrive with "one level for all" turned into
# "per monitor", and nothing on screen said so.
#
# So the box hands the wheel back to the page: the tunnelling Preview reaches the box before
# WPF's own handler gets to act on it, and the same turn is raised again on the box's parent,
# where it bubbles up to the ScrollViewer and scrolls. With the list open the wheel is left
# alone - walking a long list is exactly what it is for there.
function Register-WheelPassThrough {
    param($Root)

    foreach ($box in @(Get-UiDropDowns -Root $Root)) {
        $box.add_PreviewMouseWheel({
            param($sender, $e)
            if ($sender.IsDropDownOpen) { return }
            $parent = $sender.Parent
            if (-not $parent) { return }
            $e.Handled = $true
            $again = New-Object System.Windows.Input.MouseWheelEventArgs(
                $e.MouseDevice, $e.Timestamp, $e.Delta)
            $again.RoutedEvent = [System.Windows.UIElement]::MouseWheelEvent
            $parent.RaiseEvent($again)
        })
    }
}

# Every ComboBox in a window that has never been shown. The visual tree is not built until
# it is, so this walks the logical one - which is what XAML fills in at parse time. A window
# is parsed once, so the walk is paid once and covers a box added to any of the four
# markups later without anybody having to remember this file.
function Get-UiDropDowns {
    param($Root)

    $found = @()
    foreach ($child in @([System.Windows.LogicalTreeHelper]::GetChildren($Root))) {
        # A TextBlock's logical children include its text, which is a string and has no
        # children of its own to ask about.
        if ($child -isnot [System.Windows.DependencyObject]) { continue }
        if ($child -is [System.Windows.Controls.ComboBox]) { $found += $child; continue }
        $found += @(Get-UiDropDowns -Root $child)
    }
    return @($found)
}

# --- event handlers: why there is no .GetNewClosure() -----------------------
# A handler created with .GetNewClosure() gets a scope of its own, and out of it neither
# $script: (see Get-ActiveSettings in Displays.ps1) nor function names resolve when the
# closure was created in a dot-sourced file and is called by WPF through a delegate: a click
# on a button dies with "ConvertFrom-HotkeyString is not recognized".
#
# So not one handler here closes over anything. Everything it needs arrives two ways: the
# window's state through $script:ActiveUi, and a particular row's state through the .Tag of the
# element itself (inside the block it is available as $this). A flat block keeps the file's
# scope, and functions and $script: inside it work.

# The window being worked with right now. One per process: the window is modal, so there cannot
# be two at once. The combo editor keeps its own in $script:ActiveEditor.
$script:ActiveUi = $null
$script:ActiveEditor = $null

# A dark title bar — right after the HWND appears: before that there simply is not one.
function Register-WindowTheme {
    param($Window, [bool]$Dark)

    # The darkness lives on the window itself: the handler will get it as $this.
    $Window.Tag = [pscustomobject]@{ Dark = $Dark }
    $Window.add_SourceInitialized({
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper $this).Handle
            [NativeTheme]::TryDarkTitleBar($h, [bool]$this.Tag.Dark)
        }
        catch { }   # did not work out — the title bar stays light
    })

    try {
        $ico = Join-Path $script:ToolRoot 'app.ico'
        if (Test-Path $ico) {
            $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create(
                (New-Object System.Uri $ico), 'None', 'OnLoad')
        }
    }
    catch { }   # the icon is not required: the window opens without it
}

# --- a window that does not run off the bottom of the screen ----------------
# SizeToContent changes Height and leaves Top alone, and WindowStartupLocation places the
# window once, when it is shown. So a window that grows afterwards grows DOWNWARDS: open
# "Add a combination" on the lower half of a screen, unfold "Brightness, sound and commands"
# — 620 points become 1342 — and Save ends up under the taskbar with no way to reach it.
# MaxHeight limits the growth but never moves anything, and it used to be read off the
# PRIMARY monitor rather than the one the window stands on.
#
# The arithmetic is a pure function, the way Get-PopupPlacement is; what has to be asked of
# Windows — which monitor, and at what scale — is around it.

function Get-WindowShift {
    param([double]$Left, [double]$Top, [double]$Width, [double]$Height,
          [double]$AreaLeft, [double]$AreaTop, [double]$AreaRight, [double]$AreaBottom)

    # Not named $left/$top: PowerShell variables have no case, and such a pair would silently
    # turn out to be the same $Left/$Top that arrived in the parameters.
    $px = $Left; $py = $Top
    if ($py + $Height -gt $AreaBottom) { $py = $AreaBottom - $Height }
    # Taller than the work area: pinned to the top, not to the bottom. The title and the first
    # question stay reachable, and what does not fit is reached by the scrollbar.
    if ($py -lt $AreaTop) { $py = $AreaTop }
    if ($px + $Width -gt $AreaRight) { $px = $AreaRight - $Width }
    if ($px -lt $AreaLeft) { $px = $AreaLeft }
    return [pscustomobject]@{ X = $px; Y = $py }
}

# The work area of the monitor a window stands on, in WPF units. $null — the window has no
# HWND yet: until it is shown it stands nowhere, and its Top is not even a number.
function Get-WindowWorkArea {
    param($Window)

    if (-not $Window) { return $null }
    $handle = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
    if ($handle -eq [System.IntPtr]::Zero) { return $null }
    $area = [System.Windows.Forms.Screen]::FromHandle($handle).WorkingArea

    # Pixels -> WPF units, exactly as Set-PopupPlace does it: on a monitor at 150% those are
    # different numbers, and a window placed by pixels would land a third of a screen away.
    $sx = 1.0; $sy = 1.0
    $src = [System.Windows.PresentationSource]::FromVisual($Window)
    if ($src -and $src.CompositionTarget) {
        $t = $src.CompositionTarget.TransformFromDevice
        $sx = $t.M11; $sy = $t.M22
    }
    return [pscustomobject]@{
        Left   = $area.Left   * $sx
        Top    = $area.Top    * $sy
        Right  = $area.Right  * $sx
        Bottom = $area.Bottom * $sy
        Height = $area.Height * $sy
    }
}

# How tall a window is allowed to be. -Window is the one to measure by — for an editor that is
# its owner, which is on screen already and is the monitor the editor will open on
# (CenterOwner). Nobody to ask — the primary monitor, which is where a window with no owner
# opens anyway (CenterScreen).
function Get-WorkAreaHeight {
    param($Window)

    $area = Get-WindowWorkArea -Window $Window
    if ($area) { return [double]$area.Height }
    return [double][System.Windows.SystemParameters]::WorkArea.Height
}

# Off for render-preview.ps1 and nobody else: it shows the windows at -10000 on purpose, to
# photograph them without anything flashing on the desk, and being pulled back onto the screen
# is exactly what it is avoiding.
$script:KeepWindowsInWorkArea = $true

# Called from SizeChanged, so there is no closure here and the window arrives as $this (see the
# note about .GetNewClosure() above).
function Move-WindowIntoWorkArea {
    param($Window)

    if (-not $script:KeepWindowsInWorkArea) { return }
    try {
        $area = Get-WindowWorkArea -Window $Window
        if (-not $area) { return }
        # Before the first layout Top and Left are NaN, and assigning NaN back throws.
        if ([double]::IsNaN($Window.Top) -or [double]::IsNaN($Window.Left)) { return }

        $place = Get-WindowShift -Left $Window.Left -Top $Window.Top `
                                 -Width $Window.ActualWidth -Height $Window.ActualHeight `
                                 -AreaLeft $area.Left  -AreaTop $area.Top `
                                 -AreaRight $area.Right -AreaBottom $area.Bottom
        $Window.Top  = $place.Y
        $Window.Left = $place.X
    }
    catch { }   # did not work out — the window stays where it grew, as it did before
}

# --- small factories --------------------------------------------------------

# The separator between two facts on one line, and the arrow between a cause and its effect.
# A middle dot rather than a hyphen: a hyphen is already a minus, a range and a word-joiner, so
# "144 Hz - taskbar" and "contrast 70 - audio" each took a moment to read as two things. The
# arrow is the real one, the same character the desk cards move by, not the two-character "->"
# that stood in the rule list beside them.
#
# One constant each because between them they appear in a dozen captions: a window where half of
# those had drifted to something else looks like two windows stitched together.
$script:UiDot = '   ' + [string][char]0x00B7 + '   '
$script:UiArrow = '   ' + [string][char]0x2192 + '   '
# The taskbar star, as the desk cards draw it. In a caption it is a character; on a card it is a
# Path (see the TaskbarPick style) - one meaning, and both of them say it without a word.
$script:UiStar = [string][char]0x2605

# A line that is there only when it has something to say - the mode editor's two notes about
# what the monitors answered. Text alone is not enough: an empty TextBlock still spends its
# Margin, and the two of them left a double gap in the middle of the editor for everybody who
# had never pressed either button.
function Set-UiNote {
    param($Block, [string]$Text)

    if (-not $Block) { return }
    $Block.Text = $Text
    $Block.Visibility = $(if ($Text) { 'Visible' } else { 'Collapsed' })
}

function New-UiTextBlock {
    param([string]$Text, $Style, $Window)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    if ($Style) { $t.Style = $Window.FindResource($Style) }
    return $t
}

# What stands in the field when there is no shortcut. Asked for rather than kept in a variable:
# a $script: constant is filled at dot-source time, which is before the settings have said what
# language this is, and the window would open holding the previous one.
function Get-NoHotkeyText { return (Get-Text -Key 'hotkey.none') }
# The hint in an empty field while it has focus: "press the keys" has to be said at the moment
# a person is looking at the field, not a paragraph further up.
function Get-PressKeysText { return (Get-Text -Key 'hotkey.press') }

# Taking a key combination: we catch PreviewKeyDown and wait for a main key while the modifiers
# are held. WPF's ModifierKeys bits
# coincide with RegisterHotKey's MOD_* ones (Alt 1, Ctrl 2, Shift 4, Win 8) — no re-encoding is
# needed, and the coincidence is pinned down by a mapping test.
function Register-HotkeyCapture {
    param($Box)

    $Box.IsReadOnly = $true
    $Box.IsReadOnlyCaretVisible = $false

    # An empty field with focus hints at what to do; when focus leaves, the hint and the refusal
    # messages ("needs Ctrl…") give way to the ordinary "no shortcut" — otherwise the window
    # would be left with an error message in a field that has no binding.
    $Box.add_GotFocus({
        param($sender, $e)
        if (-not (ConvertFrom-HotkeyString $sender.Text)) { $sender.Text = (Get-PressKeysText) }
    })
    $Box.add_LostFocus({
        param($sender, $e)
        if (-not (ConvertFrom-HotkeyString $sender.Text)) { $sender.Text = (Get-NoHotkeyText) }
    })

    $Box.add_PreviewKeyDown({
        param($sender, $e)

        $key = $e.Key
        if ($key -eq [System.Windows.Input.Key]::System) { $key = $e.SystemKey }
        $mods = [int][System.Windows.Input.Keyboard]::Modifiers

        # Esc and Tab without modifiers are handed to the window: Esc closes it, Tab moves focus
        # on. Otherwise there is no getting out of the field from the keyboard.
        if ($mods -eq 0 -and ($key -eq [System.Windows.Input.Key]::Escape -or
                              $key -eq [System.Windows.Input.Key]::Tab)) { return }

        $e.Handled = $true

        $bare = @([System.Windows.Input.Key]::LeftCtrl,  [System.Windows.Input.Key]::RightCtrl,
                  [System.Windows.Input.Key]::LeftAlt,   [System.Windows.Input.Key]::RightAlt,
                  [System.Windows.Input.Key]::LeftShift, [System.Windows.Input.Key]::RightShift,
                  [System.Windows.Input.Key]::LWin,      [System.Windows.Input.Key]::RWin)
        if ($bare -contains $key) { return }

        if ($key -eq [System.Windows.Input.Key]::Back -or
            $key -eq [System.Windows.Input.Key]::Delete) {
            $sender.Text = (Get-NoHotkeyText)
            return
        }

        if ($mods -eq 0) {
            $sender.Text = (Get-Text -Key 'hotkey.needsMods')
            return
        }

        $vk = [System.Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
        $text = Format-HotkeyString -Modifiers $mods -Vk $vk
        if (ConvertFrom-HotkeyString $text) { $sender.Text = $text }
        else { $sender.Text = (Get-Text -Key 'hotkey.unsupported') }
    })
}

# The "clear the shortcut" cross next to the field. One function for both places (the mode list
# and the combo editor): the logic is one, and duplicating it would be to let the copies drift
# apart. The "field <-> button" pair travels in the .Tag of each of them — closures are not
# allowed here (see the comment about handlers above).
function Register-HotkeyClearButton {
    param($Box, $Button)

    # References to each other, one in each direction: these handlers need nothing more than
    # that.
    $Button.Tag = $Box
    $Box.Tag = $Button

    $Button.add_Click({
        $this.Tag.Text = (Get-NoHotkeyText)
        $this.IsEnabled = $false
    })
    # The cross's state follows the field: the shortcut could have been assigned or cleared with
    # Backspace, past the button.
    $Box.add_TextChanged({
        $this.Tag.IsEnabled = [bool](ConvertFrom-HotkeyString $this.Text)
    })
}

# The caption under a mode's name: WHERE it came from and what it is made of.
#
# The provenance is not decoration: the caption answers why one row has a Remove button and
# another does not. A monitor mode and "all" appear by themselves; a combo is something you
# create and delete.
function Get-ModeSubtitle {
    param($Mode)

    switch ([string]$Mode.Kind) {
        # Nothing at all: the title of a display's mode is already "Only <the display>", and a
        # second line under it saying "Display" was a word repeating the first. Empty here means
        # the row has one line unless the mode actually has something set on it — and on a desk
        # of three or four displays that is the difference between a window that fits and one
        # that scrolls.
        'solo'   { return '' }
        'combo'  {
            # No word saying "combination": the row stands under the Modes heading, and a
            # combination is the only kind with a Remove button beside it, so the word said
            # nothing the row did not already show. It cost 87 points of a caption that has
            # about 300 — which is exactly the room the settings behind Edit were being
            # trimmed out of.
            $text = @($Mode.Patterns) -join ' + '
            # The star and the name, not "(taskbar on ...)". The card above draws that star for
            # the same fact, and the words cost eleven characters of a caption that is the first
            # thing on this row to be trimmed.
            if ($Mode.Primary) { $text += '   ' + $script:UiStar + ' ' + $Mode.Primary }
            return $text
        }
        'all'    { return (Get-Text -Key 'modes.allSub') }
        'orphan' { return (Get-Text -Key 'modes.orphanSub') }
    }
    return ''
}

# --- the pages, and where the window stood ----------------------------------
# The window is an application now rather than one long column: a pane on the left, a page on
# the right, Save and Cancel underneath. Which page was open and how big the window was are
# remembered in ui-state.json — the machine's state, next to window-state.json and last-mode.json
# and ignored by git the same way.

# The pages, in the order the pane lists them. The first one is what a person who has never
# opened this window gets.
$script:UiPages = @('desk', 'modes', 'rules', 'behavior', 'diary', 'about')

# Is a saved rectangle still on somebody's screen? A pure function over rectangles — the real
# screens are asked for by the caller — because this is where the mistake would be silent:
# monitors come and go, and a window put back onto a monitor that is no longer there cannot be
# reached, moved or closed.
function Test-WindowRectVisible {
    param([double]$Left, [double]$Top, [double]$Width, [double]$Height, $Screens)

    if ($Width -le 0 -or $Height -le 0) { return $false }
    foreach ($s in @($Screens)) {
        if (-not $s) { continue }
        # Not $left/$top: PowerShell variables have no case, so those two ARE the $Left and $Top
        # that arrived in the parameters. Written that way once, this function said a window at
        # -9000 was on the screen — because the first line had already moved it to the edge.
        #
        # An overlapping corner is not enough either. What has to land on a screen is the title
        # bar — 120 points of it across and any part of its height — because that is what a
        # window is dragged and closed by.
        $ol = [math]::Max($Left, [double]$s.Left)
        $or = [math]::Min($Left + $Width, [double]$s.Right)
        $ot = [math]::Max($Top, [double]$s.Top)
        $ob = [math]::Min($Top + 40, [double]$s.Bottom)
        if (($or - $ol) -ge 120 -and ($ob - $ot) -gt 0) { return $true }
    }
    return $false
}

# The screens as rectangles in WPF units. Windows hands them out in pixels, and the whole desk
# is scaled by one number here — the virtual screen in units against the virtual screen in
# pixels. On a desk of mixed DPI that is an approximation, and it is the right one: it is used
# to answer "is this window reachable at all", not to place anything.
function Get-ScreenRects {
    $scale = 1.0
    try {
        $pixels = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width
        if ($pixels -gt 0) { $scale = [System.Windows.SystemParameters]::VirtualScreenWidth / $pixels }
    }
    catch { }   # no desk to ask — one to one, and the check below simply passes

    $rects = @()
    try {
        foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
            $b = $screen.WorkingArea
            $rects += [pscustomobject]@{
                Left = $b.Left * $scale; Top = $b.Top * $scale
                Right = $b.Right * $scale; Bottom = $b.Bottom * $scale
            }
        }
    }
    catch { }   # no screens: the caller treats that as "the saved rectangle is no good"
    return $rects
}

function Get-UiState {
    if (-not (Test-Path $script:UiStateFile)) { return $null }
    try {
        $raw = Get-Content $script:UiStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $raw) { return $null }
        $page = [string]$raw.page
        if ($script:UiPages -notcontains $page) { $page = '' }   # a page that no longer exists
        return [pscustomobject]@{
            Left = [double]$raw.left; Top = [double]$raw.top
            Width = [double]$raw.width; Height = [double]$raw.height
            Page = $page
        }
    }
    catch {
        # A damaged file costs a centred window and nothing else, so it is not worth a word to
        # the person — only one in the log.
        Write-DisplayLog "settings dialog: ui-state.json is damaged, opening on the defaults - $($_.Exception.Message)"
        return $null
    }
}

function Save-UiState {
    param($Ui)

    if (-not $Ui -or -not $Ui.Window) { return }
    try {
        # RestoreBounds and not Left/Top: a window that was maximised has to come back the size
        # it was before, and for a window that was never shown this is Rect.Empty — which is the
        # guard the tests and render-preview.ps1 rely on, and why neither of them writes a file.
        $rect = $Ui.Window.RestoreBounds
        if ($rect.Width -le 0 -or $rect.Height -le 0) { return }
        if (-not (Test-WindowRectVisible -Left $rect.Left -Top $rect.Top `
                                         -Width $rect.Width -Height $rect.Height -Screens (Get-ScreenRects))) {
            return
        }
        $state = [ordered]@{
            left = [int]$rect.Left; top = [int]$rect.Top
            width = [int]$rect.Width; height = [int]$rect.Height
            page = [string]$Ui.Page
        }
        # -ErrorAction Stop: a refusal from Set-Content is a non-terminating error, and without
        # it a read-only folder would be reported as a successful save.
        $state | ConvertTo-Json -Compress |
            Set-Content -Path $script:UiStateFile -Encoding UTF8 -ErrorAction Stop
    }
    catch { Write-DisplayLog "settings dialog: could not write ui-state.json - $($_.Exception.Message)" }
}

# Show one page and mark it in the pane. The two lists are told apart by which one holds the
# page: only one of them may look chosen, and while that is being sorted out both handlers keep
# quiet — setting a selection in code would otherwise count as a person's click.
# --- has anything been touched ----------------------------------------------
# The window as it stands, in one string: what Save would write, plus the two settings that are
# Windows' rather than ours and so travel outside settings.json - the startup shortcut and the
# display timeout. Compared against the same string taken when the window opened, which is the
# only comparison that means anything: settings.json is edited by hand and may be missing half
# its keys, so the file itself does not equal what the window would write even untouched.
function Get-UiFingerprint {
    param($Ui)

    $got = Read-SettingsFromUi -Ui $Ui -Settings $Ui.Settings -Quiet
    # Two modes on one key: the window cannot say what it would save, and somebody has plainly
    # been typing. A fingerprint nothing can equal is exactly the right answer.
    if (-not $got.Ok) { return 'unsaveable ' + [guid]::NewGuid().ToString() }
    return (($got.Settings | ConvertTo-Json -Depth 5 -Compress) + '|' +
            [string][bool]$Ui.StartupBox.IsChecked + '|' + [string](Get-UiSleepMinutes -Ui $Ui))
}

# Written down when the window is built, and again once Show-SettingsDialog has asked Windows for
# the two settings that are Windows' own: it is "as it opened" that has to be remembered, and
# those two arrive a moment after the markup does.
function Set-UiBaseline {
    param($Ui)

    if (-not $Ui) { return }
    $Ui.Baseline = Get-UiFingerprint -Ui $Ui
}

function Test-UiEdited {
    param($Ui)

    if (-not $Ui -or -not $Ui.Baseline) { return $true }
    try { return ((Get-UiFingerprint -Ui $Ui) -ne [string]$Ui.Baseline) }
    catch {
        # Never the reason a page will not open. "Edited" leaves the footer the way this window
        # has always had it - Save and Cancel both.
        Write-DisplayLog "settings dialog: could not compare the window with how it opened - $($_.Exception.Message)"
        return $true
    }
}

# The footer for the page now showing. The Diary and the About page hold no setting of their own:
# with nothing edited anywhere either, a Save that would rewrite the file unchanged and a Cancel
# offering to throw away nothing are two questions a person has to stop and answer on a page they
# opened to read. So there is one button there and it says Close.
#
# Anything edited on another page and the pair comes straight back: the footer belongs to the
# WINDOW and not to the page, and hiding Save with edits standing behind it would strand them on
# a page with no way to save.
#
# Asked only when a page comes up, which is enough and is the point: neither of those two pages
# can change a setting, so the answer cannot go stale while one of them is open.
function Update-UiFooter {
    param($Ui)

    if (-not $Ui -or -not $Ui.SaveBtn -or -not $Ui.CancelBtn) { return }
    $quiet = (($Ui.Page -eq 'diary' -or $Ui.Page -eq 'about') -and -not (Test-UiEdited -Ui $Ui))
    $Ui.SaveBtn.Visibility = $(if ($quiet) { 'Collapsed' } else { 'Visible' })
    $Ui.CancelBtn.Content = $(if ($quiet) { Get-Text -Key 'common.close' } else { Get-Text -Key 'common.cancel' })
}

function Set-UiPage {
    param($Ui, [string]$Page)

    if (-not $Ui) { return }
    if ($script:UiPages -notcontains $Page) { $Page = $script:UiPages[0] }
    $Ui.Page = $Page

    foreach ($name in @($Ui.Pages.Keys)) {
        $panel = $Ui.Pages[$name]
        if ($panel) { $panel.Visibility = $(if ($name -eq $Page) { 'Visible' } else { 'Collapsed' }) }
    }

    $Ui.NavBusy = $true
    try {
        foreach ($list in @($Ui.NavList, $Ui.NavAbout)) {
            if (-not $list) { continue }
            $hit = $null
            foreach ($item in @($list.Items)) {
                if ([string]$item.Tag -eq $Page) { $hit = $item; break }
            }
            $list.SelectedItem = $hit   # $null clears the other list's highlight
        }
    }
    finally { $Ui.NavBusy = $false }

    Update-UiFooter -Ui $Ui
}

# The display-sleep row, filled from what Windows says. -1 is "it would not say": the row then
# says so and cannot be used, because a dropdown that shows "Never" over a setting nobody could
# read is a lie a person would act on.
# The language drop-down: every file under lang\ by its own name for itself, and "Follow Windows"
# first. The codes ride on the items' Tag - the visible text is the language's own word for
# itself and is nobody's key.
function Set-UiLanguageBox {
    param($Ui, $Settings)

    $box = $Ui.LanguageBox
    if (-not $box) { return }
    $box.Items.Clear()

    $auto = New-Object System.Windows.Controls.ComboBoxItem
    $auto.Content = Get-Text -Key 'behavior.language.auto'
    $auto.Tag = 'auto'
    [void]$box.Items.Add($auto)

    $want = [string]$(if ($Settings) { $Settings.language } else { 'auto' })
    if (-not $want) { $want = 'auto' }
    $box.SelectedItem = $auto

    foreach ($entry in (Get-LanguageChoices).GetEnumerator()) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = [string]$entry.Value
        $item.Tag = [string]$entry.Key
        [void]$box.Items.Add($item)
        if ([string]$entry.Key -eq $want.ToLowerInvariant()) { $box.SelectedItem = $item }
    }
}

# The code the drop-down is on. Never the visible text: that is the language's own name for
# itself and would land in settings.json as "Українська".
function Get-UiLanguage {
    param($Ui)

    $item = $(if ($Ui.LanguageBox) { $Ui.LanguageBox.SelectedItem } else { $null })
    if (-not $item) { return 'auto' }
    $code = [string]$item.Tag
    if (-not $code) { return 'auto' }
    return $code
}

function Set-UiSleepMinutes {
    param($Ui, [int]$Minutes)

    if (-not $Ui -or -not $Ui.SleepBox) { return }
    $Ui.SleepMinutes = $Minutes
    $Ui.SleepBox.Items.Clear()
    if ($Minutes -lt 0) {
        $Ui.SleepBox.IsEnabled = $false
        $Ui.SleepHint.Text = (Get-Text -Key 'desk.sleep.unknown')
        return
    }
    $Ui.SleepBox.IsEnabled = $true
    foreach ($choice in @(Get-SleepChoices -Current $Minutes)) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = Get-SleepChoiceTitle $choice
        $item.Tag = [int]$choice
        [void]$Ui.SleepBox.Items.Add($item)
        if ([int]$choice -eq $Minutes) { $Ui.SleepBox.SelectedItem = $item }
    }
    if (-not $Ui.SleepBox.SelectedItem -and $Ui.SleepBox.Items.Count -gt 0) { $Ui.SleepBox.SelectedIndex = 0 }
}

# What the box says now, or -1 when there is nothing to say.
function Get-UiSleepMinutes {
    param($Ui)

    if (-not $Ui -or -not $Ui.SleepBox -or -not $Ui.SleepBox.IsEnabled) { return -1 }
    $item = $Ui.SleepBox.SelectedItem
    if (-not $item) { return -1 }
    return [int]$item.Tag
}

# Written on Save, and only when it changed: this is Windows' setting, and rewriting it with the
# same number on every Save would put DeskModes's name on a change nobody made.
#
# Answers whether the setting now says what the box says - "nothing to write" included. A refusal
# has to reach the caller: this is the one setting in the window that Windows can turn down on its
# own (a scheme managed by policy), and the person would otherwise close a window that reported a
# clean save and find the old value back in the dropdown next time, with nothing to say why.
function Save-UiSleepMinutes {
    param($Ui)

    $wanted = Get-UiSleepMinutes -Ui $Ui
    if ($wanted -lt 0 -or $wanted -eq [int]$Ui.SleepMinutes) { return $true }
    $saved = [bool](Set-DisplaySleepMinutes -Minutes $wanted)
    if ($saved) { $Ui.SleepMinutes = $wanted }
    return $saved
}

# A page, a folder or a file, opened by whatever Windows uses for it. Every button on the About
# page goes through here: a browser that will not start is a shrug, not a window that dies on
# somebody looking at the version number.
function Open-UiTarget {
    param([string]$Target)

    if (-not $Target) { return }
    try { Start-Process $Target }
    catch { Write-DisplayLog "settings dialog: could not open $Target - $($_.Exception.Message)" }
}

# --- assembling the window --------------------------------------------------

function New-SettingsWindow {
    param(
        $Modes,
        $Settings,
        # The connected monitors: the desk cards and the combo members. Empty — and the
        # corresponding sections simply stand empty (tests).
        $State,
        # A single CCD snapshot taken with State. Kept out of settings.json: it describes what
        # Windows is showing now, while layout below is an intentional switching override.
        $Positions = @{},
        # Which page to open on. Empty — the one the window was left on last time. The tray's
        # About item is what passes a page.
        [string]$Page = ''
    )

    Initialize-WpfRuntime
    # A card keeps the device path as its identity. Naming the instances before the cards are
    # built means two panels of one model leave with different selectors when either is chosen.
    Set-DisplayIdentity -State $State

    $dark = Test-DarkTheme
    $palette = Get-UiPalette -Dark $dark
    $win = Convert-UiXaml -Xaml $script:SettingsWindowXaml -Palette $palette
    Register-WindowTheme -Window $win -Dark $dark

    $ui = [pscustomobject]@{
        Window            = $win
        Dark              = $dark
        # Mode key -> the text of the key combination. Not input fields: the shortcut lives in
        # the mode editor, and rows are enough for the main window.
        Hotkeys           = [ordered]@{}
        Combos            = (New-Object System.Collections.ArrayList)
        DeletedComboKeys  = @()
        LiveDeskCanvas    = $win.FindName('LiveDeskCanvas')
        DeskPanel         = $win.FindName('DeskPanel')
        ModesPanel        = $win.FindName('ModesPanel')
        RulesPanel        = $win.FindName('RulesPanel')
        AddComboBtn       = $win.FindName('AddComboBtn')
        AddRuleBtn        = $win.FindName('AddRuleBtn')
        ReadDeskBtn       = $win.FindName('ReadDeskBtn')
        IdentifyBtn       = $win.FindName('IdentifyBtn')
        # The shortcut that goes back to the mode before this one. Not in Hotkeys: that map is keyed
        # by MODE, and everything that reads it - the rows, the orphan rows, the editor's "somebody
        # else has this key" check - would take a key called back for a mode called back.
        BackHotkeyBox     = $win.FindName('BackHotkeyBox')
        # The rules as the tray reads them, edited in place. Filled by Import-RuleSettings.
        Rules             = (New-Object System.Collections.ArrayList)
        SaveBtn           = $win.FindName('SaveBtn')
        CancelBtn         = $win.FindName('CancelBtn')
        StartupBox        = $win.FindName('StartupBox')
        RefreshBox        = $win.FindName('RefreshBox')
        NotifyBox         = $win.FindName('NotifyBox')
        LanguageBox       = $win.FindName('LanguageBox')
        WindowsBox        = $win.FindName('WindowsBox')
        LastModeBox       = $win.FindName('LastModeBox')
        StatsBox          = $win.FindName('StatsBox')
        ResumeBox         = $win.FindName('ResumeBox')
        UnplugBox         = $win.FindName('UnplugBox')
        PlugModeBox       = $win.FindName('PlugModeBox')
        DisplaysTable     = $win.FindName('DisplaysTable')
        SleepBox          = $win.FindName('SleepBox')
        SleepHint         = $win.FindName('SleepHint')
        # What Windows said when the window opened, in minutes; -1 is "it would not say". Kept so
        # that Save writes only a value somebody actually changed - like "Start with Windows",
        # this is the system's state and not ours to rewrite on every Save.
        SleepMinutes      = -1
        # These are filled by Show-SettingsDialog. Keeping them on the window state lets each
        # Save compare against the last operation that really reached Windows and notify the tray
        # while the same modal window remains open.
        StartupWasEnabled = $false
        OnSaved           = $null
        SaveBusy          = $false
        NavList           = $win.FindName('NavList')
        NavAbout          = $win.FindName('NavAbout')
        # Page name -> the panel that is that page. One map, so Set-UiPage does not have to know
        # the five names in two places.
        Pages             = [ordered]@{
            desk     = $win.FindName('DeskPage')
            modes    = $win.FindName('ModesPage')
            rules    = $win.FindName('RulesPage')
            behavior = $win.FindName('BehaviorPage')
            diary    = $win.FindName('DiaryPage')
            about    = $win.FindName('AboutPage')
        }
        Page              = ''
        # While a page is being marked in the pane, the pane's own handlers keep quiet.
        NavBusy           = $false
        # The window as it opened, for the footer to tell "nothing to save" from "something to
        # save" (see Get-UiFingerprint). Empty until it is taken, and empty reads as "edited",
        # which is the safe way round.
        Baseline          = ''
        # The diary page's state, built below: the page is part of this window, but everything it
        # knows (the pot, the period, the report) is its own.
        Stats             = $null
        VersionText       = $win.FindName('VersionText')
        VersionHost       = $win.FindName('VersionHost')
        CopyVersionBtn    = $win.FindName('CopyVersionBtn')
        DiagnosticsBtn    = $win.FindName('DiagnosticsBtn')
        SupportCard       = $win.FindName('SupportCard')
        DonateBtn         = $win.FindName('DonateBtn')
        DonateHint        = $win.FindName('DonateHint')
        # "A display was plugged in — switch to" names a mode by the same key everything else
        # does, so it is kept HERE and not read off the dropdown at Save time: a combo renamed
        # while the window is open has to take this along, and a dropdown built when the window
        # opened would still be holding the old key. Remove-UiModeKey and Move-UiModeKey are
        # what keep it honest; the box is only a view of it (see Update-PlugModeBox).
        OnPlugKey         = ''
        # While the box is being rebuilt its handler keeps quiet: setting the selection in code
        # would otherwise count as a person's choice.
        PlugBusy          = $false
        # Mode key -> the brightness and contrast models (see ConvertTo-LevelModel), the audio
        # device (a piece of a name) and the pair of commands. All four are edited in the mode
        # editor and leave for settings.json on Save — the window owns them, so they must not
        # also be carried blindly from the file (see the loop in Read-SettingsFromUi).
        Levels            = [ordered]@{}
        Contrast          = [ordered]@{}
        # Mode key -> { display name -> "register:number" }: the monitor's own picture preset,
        # learnt from the monitor and written back to it on a switch.
        Picture           = [ordered]@{}
        # Mode key -> { display name -> $true/$false }: HDR on or off with the mode.
        Hdr               = [ordered]@{}
        Audio             = [ordered]@{}
        Hooks             = [ordered]@{}
        Modes             = @($Modes)
        Settings          = $Settings
        State             = @($State)
        Positions         = $Positions
        # Programmatic checks while the window is built do not count. Only the card buttons set
        # these flags, so an unrelated Save cannot turn legacy values into explicit overrides.
        LayoutEdited      = $false
        PrimaryEdited     = $false
        AdoptLiveDesk     = $false
        Result            = $null
    }

    # The combos go into a working list: the window edits that, and settings.json is rewritten
    # from it whole on Save. The name the combo had in the file is deliberately NOT kept beside
    # it: everything keyed by mode moves the instant the name changes (Move-UiModeKey), so
    # nothing is left under the old key for anybody to go back for — and a remembered old name
    # is a key somebody else may own by the time it is used (see Remove-UiCombo).
    if ($Settings -and $Settings.combos) {
        foreach ($name in @($Settings.combos.Keys)) {
            $c = $Settings.combos[$name]
            $patterns = @()
            $prim = ''
            if ($c -is [array]) { $patterns = @($c | ForEach-Object { [string]$_ }) }
            elseif ($c) {
                if ($null -ne $c.displays) { $patterns = @($c.displays | ForEach-Object { [string]$_ }) }
                if ($null -ne $c.primary)  { $prim = [string]$c.primary }
            }
            [void]$ui.Combos.Add([pscustomobject]@{
                Name     = [string]$name
                Patterns = $patterns
                Primary  = $prim
            })
        }
    }

    # Before the mode list is built: the rows read these maps, and an entry left in the file for
    # a mode that no longer exists is what turns into an orphan row (see Resolve-PanelModes).
    Import-LevelSettings -Ui $ui -Settings $Settings
    Import-ModeExtras    -Ui $ui -Settings $Settings
    # Before the mode list too: Update-ModesPanel builds the "switch to" dropdown and the rule
    # rows out of it.
    if ($Settings -and $Settings.reapply) { $ui.OnPlugKey = [string]$Settings.reapply.onPlug }
    Import-RuleSettings -Ui $ui -Settings $Settings
    Update-DeskPanel  -Ui $ui
    Update-LiveDesk   -Ui $ui
    $ui.LiveDeskCanvas.Tag = $ui
    $ui.LiveDeskCanvas.add_SizeChanged({
        param($sender, $e)
        if ($e.WidthChanged) { Update-LiveDesk -Ui $sender.Tag }
    })
    Update-DisplaysTable -Ui $ui
    Update-ModesPanel -Ui $ui -InitialModes $Modes -InitialHotkeys $Settings.hotkeys

    # The way-back shortcut, out of the same map the modes' shortcuts came from, into a field of its
    # own. The same capture and the same cross as the mode editor's field: one way of setting a key.
    $backText = ''
    if ($Settings -and $Settings.hotkeys -and $Settings.hotkeys.Contains($script:BackHotkeyName)) {
        $backText = [string]$Settings.hotkeys[$script:BackHotkeyName]
    }
    $ui.BackHotkeyBox.Cursor = [System.Windows.Input.Cursors]::Hand
    Register-HotkeyCapture -Box $ui.BackHotkeyBox
    $parsedBack = ConvertFrom-HotkeyString $backText
    $ui.BackHotkeyBox.Text = $(if ($parsedBack) { $parsedBack.Text } else { (Get-NoHotkeyText) })
    $clearBack = $win.FindName('ClearBackHotkeyBtn')
    $clearBack.IsEnabled = [bool]$parsedBack
    Register-HotkeyClearButton -Box $ui.BackHotkeyBox -Button $clearBack

    Set-UiLanguageBox -Ui $ui -Settings $Settings

    $ui.RefreshBox.IsChecked  = [bool]$Settings.maximizeRefresh
    $ui.NotifyBox.IsChecked   = [bool]$Settings.notifications
    # A key missing from settings.json means "the default", that is, on: the file gets edited by
    # hand, and half the keys may not be in it.
    $ui.WindowsBox.IsChecked  = ($null -eq $Settings.restoreWindows -or [bool]$Settings.restoreWindows)
    $ui.LastModeBox.IsChecked = ($null -eq $Settings.restoreLastMode -or [bool]$Settings.restoreLastMode)
    # The diary is the other way round: a missing key means "off". This is data about a person,
    # and it is not collected by default.
    $ui.StatsBox.IsChecked    = [bool]$Settings.stats
    # Both default to on, as Get-DefaultSettings has them: a half-written reapply in a
    # hand-edited file must not read as "turn the other one off".
    $ui.ResumeBox.IsChecked = ($null -eq $Settings.reapply -or $null -eq $Settings.reapply.onResume -or
                               [bool]$Settings.reapply.onResume)
    $ui.UnplugBox.IsChecked = ($null -eq $Settings.reapply -or $null -eq $Settings.reapply.onUnplug -or
                               [bool]$Settings.reapply.onUnplug)

    # The ready answers, so a window built without being shown (the tests, render-preview) has a
    # list rather than an empty box. What Windows actually says arrives in Show-SettingsDialog.
    Set-UiSleepMinutes -Ui $ui -Minutes 0

    # The diary reads the pot as it stands right now. The tray writes it out before opening this
    # window (Statistics...), so the last few minutes are in it.
    $ui.Stats = New-StatsUi -Window $win -Store (Get-ActivityStore)

    # Two short lines, not one long one: this is what a bug report opens with, and it was a
    # sentence of five facts that wrapped. The pair still adds up to Get-VersionLine word for
    # word - `Set-Display.ps1 status` prints that same line, and the two must not drift.
    $ui.VersionText.Text = Get-VersionName
    $ui.VersionHost.Text = Get-VersionHost
    # No address yet: the whole section goes. A disabled BtnAccent is a grey-blue plate the size
    # of the page's primary action and reads as the one broken button on the page - and a button
    # that opens a 404 would be worse still. The button stays disabled underneath as the second
    # lock: the card is collapsed, not removed, and a future address brings it back with one
    # variable rather than with a rebuild.
    if (-not $script:DonateUrl) {
        $ui.SupportCard.Visibility = 'Collapsed'
        $ui.DonateBtn.IsEnabled = $false
        $ui.DonateHint.Text = (Get-Text -Key 'about.donate.none')
    }

    # Where it stood last time, and on which page. A rectangle that is no longer on any screen is
    # dropped whole: the window opens centred, at the size the markup gives it.
    $saved = Get-UiState
    if ($saved -and (Test-WindowRectVisible -Left $saved.Left -Top $saved.Top `
                                            -Width $saved.Width -Height $saved.Height -Screens (Get-ScreenRects))) {
        $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
        $win.Left = $saved.Left; $win.Top = $saved.Top
        $win.Width = $saved.Width; $win.Height = $saved.Height
    }
    # Before the first page is shown: Set-UiPage asks the footer what to say, and the footer
    # compares the window against this.
    Set-UiBaseline -Ui $ui

    $wanted = $Page
    if (-not $wanted -and $saved) { $wanted = [string]$saved.Page }
    Set-UiPage -Ui $ui -Page $wanted

    # The geometry is written when the window closes rather than while it is being dragged: this
    # is a note about where to open next time, not a setting Save is responsible for.
    $win.Tag = $ui
    $win.add_Closing({
        $closingUi = $this.Tag
        Save-UiState -Ui $closingUi
        # The diary page goes with the window: its handlers look for it in here, and a stale one
        # would be a page of a window that is gone.
        if ([object]::ReferenceEquals($script:ActiveUi, $closingUi)) {
            $script:ActiveStatsUi = $null
            $script:ActiveUi = $null
            $script:PendingSettingsDeskState = $null
            $script:PendingSettingsPage = ''
        }
    })

    $ui.NavList.add_SelectionChanged({
        $ui = $script:ActiveUi
        if (-not $ui -or $ui.NavBusy -or -not $this.SelectedItem) { return }
        Set-UiPage -Ui $ui -Page ([string]$this.SelectedItem.Tag)
    })
    $ui.NavAbout.add_SelectionChanged({
        $ui = $script:ActiveUi
        if (-not $ui -or $ui.NavBusy -or -not $this.SelectedItem) { return }
        Set-UiPage -Ui $ui -Page ([string]$this.SelectedItem.Tag)
    })

    $ui.PlugModeBox.add_SelectionChanged({
        $ui = $script:ActiveUi
        if (-not $ui -or $ui.PlugBusy) { return }
        $item = $this.SelectedItem
        $ui.OnPlugKey = [string]$(if ($item) { $item.Tag } else { '' })
    })

    $ui.AddComboBtn.add_Click({
        $ui = $script:ActiveUi
        if (-not $ui) { return }
        # A new combination opens on the displays that are on right now, with the current taskbar
        # display chosen: the set in front of a person is the one they most often want to name.
        Invoke-ModeEditor -Ui $ui -Mode $null -Combo $null -Template (New-DeskTemplate -State $ui.State)
    })

    $ui.ReadDeskBtn.add_Click({
        $ui = $script:ActiveUi
        if (-not $ui) { return }
        if (-not (Invoke-DeskRead -Ui $ui)) {
            [void][System.Windows.MessageBox]::Show(
                $ui.Window, (Get-Text -Key 'desk.copy.failed'), 'DeskModes',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        }
    })

    $ui.IdentifyBtn.add_Click({
        $ui = $script:ActiveUi
        if (-not $ui) { return }
        try { Show-DisplayBadges -State $ui.State }
        catch { Write-DisplayLog "settings dialog: could not show the badges - $($_.Exception.Message)" }
    })

    $ui.AddRuleBtn.add_Click({
        $ui = $script:ActiveUi
        if (-not $ui) { return }
        Invoke-RuleEditor -Ui $ui -Rule $null
    })

    # The About page's four doors. Each one is a line, and each one goes through Open-UiTarget:
    # a browser or Explorer refusing to start must not take the window down with it.
    $win.FindName('RepoBtn').add_Click({ Open-UiTarget -Target $script:RepoUrl })
    $win.FindName('IssueBtn').add_Click({ Open-UiTarget -Target $script:IssuesUrl })
    $win.FindName('FolderBtn').add_Click({ Open-UiTarget -Target $script:ToolRoot })
    $win.FindName('LogBtn').add_Click({
        if (Test-Path $script:LogFile) { Open-UiTarget -Target $script:LogFile }
        else { [void][System.Windows.MessageBox]::Show($script:ActiveUi.Window,
                   'There is no log yet. It appears after the first switch.', 'DeskModes',
                   [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) }
    })
    $ui.DonateBtn.add_Click({ Open-UiTarget -Target $script:DonateUrl })

    # The version line onto the clipboard, because the first thing an issue asks for is the one
    # thing that cannot be typed from memory. A clipboard held by another process refuses, and
    # that is a shrug rather than a window that dies on somebody reading a version number.
    $ui.CopyVersionBtn.add_Click({
        try { [System.Windows.Clipboard]::SetText((Get-VersionLine)) }
        catch { Write-DisplayLog "settings dialog: could not copy the version - $($_.Exception.Message)" }
    })

    $ui.DiagnosticsBtn.add_Click({
        $ui = $script:ActiveUi
        if (-not $ui) { return }
        try {
            [System.Windows.Clipboard]::SetText((Format-DisplayDiagnostics -State $ui.State))
        }
        catch { Write-DisplayLog "settings dialog: could not copy diagnostics - $($_.Exception.Message)" }
    })

    # Save is a commit, not a way out. Validation, the durable write and the tray callback all
    # happen while the window is open, so another edit can be saved without rebuilding the form.
    $ui.SaveBtn.add_Click({
        $ui = $script:ActiveUi
        if (-not $ui) { return }
        [void](Invoke-SettingsSave -Ui $ui)
    })

    # Last, after every control and handler is ready. If construction throws before here there is
    # no half-built window for the tray's singleton guard to mistake for one it can activate.
    $script:ActiveUi = $ui
    return $ui
}

# A fold: one caption that opens and shuts the panel under it. The mode editor has one, for what
# a mode does to the hardware; the Settings window used to have one too, for the settings with a
# right default, and gave it up when those got a page with room on it.
#
# The arrow lives in the caption rather than in a glyph of its own: one string is one thing to
# keep in step, and the button reads left to right anyway.
#
# Collapsed and not merely hidden: a hidden panel still takes its height, and the height of the
# editor is the whole reason anything is folded away.
function Set-DisclosureOpen {
    param($Button, $Panel, [string]$Label, [bool]$Open)

    if (-not $Button -or -not $Panel) { return }
    $Panel.Visibility = $(if ($Open) { 'Visible' } else { 'Collapsed' })
    # A solid triangle rather than a chevron: U+2303/U+2304 are not in Segoe UI Variable and fall
    # back to a caret and a lowercase v, which read as punctuation. U+25B4/U+25BE are.
    $Button.Content = $(if ($Open) { [string][char]0x25B4 } else { [string][char]0x25BE }) +
                      '  ' + $Label
}

function Set-EditorMoreVisible {
    param($Editor, [bool]$Open)

    Set-DisclosureOpen -Button $Editor.MoreBtn -Panel $Editor.MorePanel `
                       -Label (Get-Text -Key 'editor.more') -Open $Open
}

# Is anything set behind the editor's fold? A pure question over the controls, so the answer is
# the same one Read-ModeFromUi would give.
function Test-EditorExtrasSet {
    param($Editor)

    if ($null -ne (ConvertFrom-LevelModel $Editor.Brightness.Model)) { return $true }
    if ($null -ne (ConvertFrom-LevelModel $Editor.Contrast.Model))   { return $true }
    # Not @(...).Count: wrapping a dictionary in an array gives ONE element whatever is in it, and
    # the fold would spring open for every mode that has nothing set at all.
    if ((Get-PictureForSave -Editor $Editor).Count -gt 0)            { return $true }
    if ((Get-HdrForSave -Editor $Editor).Count -gt 0)                { return $true }
    if (([string]$Editor.AudioBox.Text).Trim())                      { return $true }
    if (Get-HookFingerprint -Before $Editor.HookBeforeBox.Text -After $Editor.HookAfterBox.Text) { return $true }
    return $false
}

# Open the fold if there is something inside it to see. A setting folded out of sight is
# invisible, and an invisible setting that an empty field then erases is exactly the bug the
# inheritance code exists to prevent — so this runs after inheritance too, not only on opening.
#
# It only ever OPENS, and never against a person who worked the fold themselves: without that
# last guard, shutting it while a brightness is set would have it spring open again on the next
# keystroke in the name box.
function Update-EditorDisclosure {
    param($Editor)

    if ($Editor.MoreTouched -or $Editor.MoreOpen) { return }
    if (-not (Test-EditorExtrasSet -Editor $Editor)) { return }
    $Editor.MoreOpen = $true
    Set-EditorMoreVisible -Editor $Editor -Open $true
}

# --- the desk as Windows holds it -------------------------------------------
# CCD positions and current source sizes are both pixels, so one scale preserves offsets,
# relative sizes and rotation exactly. This function only performs the arithmetic; the WPF
# drawing below is deliberately thin, and tests can prove the geometry without showing a window.
function Get-LiveDeskGeometry {
    param($State, $Positions, [double]$Width, [double]$Height)

    $screens = @()
    foreach ($m in @($State | Where-Object { $_ -and $_.Active -and -not $_.Disconnected })) {
        $pos = $(if ($Positions -and $Positions.Contains([string]$m.Id)) { $Positions[[string]$m.Id] } else { $null })
        if (-not $pos -or $m.Width -le 0 -or $m.Height -le 0) { continue }
        $screens += [pscustomobject]@{
            Display = $m
            X = [double]$pos.X; Y = [double]$pos.Y
            PixelWidth = [double]$m.Width; PixelHeight = [double]$m.Height
        }
    }
    if ($screens.Count -eq 0) { return @() }

    $minX = [double]($screens | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum
    $minY = [double]($screens | ForEach-Object { $_.Y } | Measure-Object -Minimum).Minimum
    $maxX = [double]($screens | ForEach-Object { $_.X + $_.PixelWidth } | Measure-Object -Maximum).Maximum
    $maxY = [double]($screens | ForEach-Object { $_.Y + $_.PixelHeight } | Measure-Object -Maximum).Maximum
    $spanX = [math]::Max(1.0, $maxX - $minX)
    $spanY = [math]::Max(1.0, $maxY - $minY)
    $insideWidth = [math]::Max(40.0, $Width - 12.0)
    $insideHeight = [math]::Max(32.0, $Height - 12.0)
    $scale = [math]::Min($insideWidth / $spanX, $insideHeight / $spanY)
    $usedWidth = $spanX * $scale
    $usedHeight = $spanY * $scale
    $offsetX = 6.0 + ($insideWidth - $usedWidth) / 2.0
    $offsetY = 6.0 + ($insideHeight - $usedHeight) / 2.0

    return @($screens | Sort-Object -Property X, Y | ForEach-Object {
        [pscustomobject]@{
            Display = $_.Display
            Left = $offsetX + ($_.X - $minX) * $scale
            Top = $offsetY + ($_.Y - $minY) * $scale
            Width = $_.PixelWidth * $scale
            Height = $_.PixelHeight * $scale
        }
    })
}

function Update-LiveDesk {
    param($Ui)

    if (-not $Ui -or -not $Ui.LiveDeskCanvas) { return }
    $canvas = $Ui.LiveDeskCanvas
    $canvas.Children.Clear()
    $wide = [double]$canvas.ActualWidth
    if ($wide -le 0) { $wide = 560.0 }
    $tall = [double]$canvas.Height
    if ($tall -le 0) { $tall = 150.0 }
    $geometry = @(Get-LiveDeskGeometry -State $Ui.State -Positions $Ui.Positions -Width $wide -Height $tall)
    if ($geometry.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = Get-Text -Key 'desk.live.unavailable'
        $empty.Foreground = $Ui.Window.FindResource('DimBrush')
        [System.Windows.Controls.Canvas]::SetLeft($empty, 4)
        [System.Windows.Controls.Canvas]::SetTop($empty, 54)
        [void]$canvas.Children.Add($empty)
        return
    }

    foreach ($g in $geometry) {
        $m = $g.Display
        $primary = [bool]$m.Primary
        $screen = New-Object System.Windows.Controls.Border
        $screen.Width = [math]::Max(28.0, [math]::Floor([double]$g.Width))
        $screen.Height = [math]::Max(22.0, [math]::Floor([double]$g.Height))
        $screen.CornerRadius = New-Object System.Windows.CornerRadius 4
        $screen.Background = $Ui.Window.FindResource('MiniBrush')
        $screen.BorderThickness = New-Object System.Windows.Thickness $(if ($primary) { 2 } else { 1 })
        $screen.BorderBrush = $Ui.Window.FindResource($(if ($primary) { 'AccentBrush' } else { 'InputBorderBrush' }))
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $(if ($primary) { $script:UiStar + ' ' } else { '' }) + (Get-DisplayTitle -Label ([string]$m.Label))
        $label.FontSize = 10
        $label.TextWrapping = 'Wrap'
        $label.TextAlignment = 'Center'
        $label.VerticalAlignment = 'Center'
        $label.HorizontalAlignment = 'Center'
        $label.Margin = New-Object System.Windows.Thickness 3
        $screen.Child = $label
        [System.Windows.Controls.Canvas]::SetLeft($screen, [double]$g.Left)
        [System.Windows.Controls.Canvas]::SetTop($screen, [double]$g.Top)
        [void]$canvas.Children.Add($screen)
    }
}

# --- the saved desk: order and the taskbar ----------------------------------
# The cards in DeskPanel ARE the layout: their order left to right leaves for settings.json ->
# layout, and the starred one -> primary. Entries for monitors that are not here right now are
# not lost: a dimmed card of its own is built for each of them.

function Update-DeskPanel {
    param($Ui)

    $Ui.DeskPanel.Children.Clear()

    $settings = $Ui.Settings
    $state = @($Ui.State | Where-Object { $_ })
    $placed = New-Object System.Collections.ArrayList   # monitors that already have a card
    $cards = @()

    # First the order out of the settings: every pattern either finds a monitor or becomes a
    # reminder card (the monitor is disconnected, but it keeps its place in the row — otherwise
    # every Save would erase it from layout).
    foreach ($pattern in @($settings.layout)) {
        if (-not $pattern) { continue }
        $hit = $null
        foreach ($m in $state) {
            if ($placed -contains $m) { continue }
            if (Test-DisplayNameMatch -Pattern $pattern -Label $m.Label -ShortId $m.ShortId) { $hit = $m; break }
        }
        if ($hit) {
            [void]$placed.Add($hit)
            $cards += [pscustomobject]@{ Label = $hit.Label; Display = $hit }
        }
        else {
            $cards += [pscustomobject]@{ Label = [string]$pattern; Display = $null }
        }
    }

    # Then every display the desk knows of that layout does not mention, at the end of the row.
    # Knows of, not "is connected": one that is off at its own button has a place in the row too,
    # and arranging it while it is off is the only time anybody wants to.
    foreach ($m in $state) {
        if ($placed -contains $m) { continue }
        $cards += [pscustomobject]@{ Label = $m.Label; Display = $m }
    }

    # One slot per card, so the row fills the panel whatever the window's width is. Set BEFORE
    # the cards go in: UniformGrid works its columns out from the count only while Columns is 0,
    # and leaving it to do that would give a desk of three a 2 x 2 grid.
    $Ui.DeskPanel.Columns = [Math]::Max(1, $cards.Count)
    # And a ceiling on the row, because the screens inside it have one (DeskBandMax): past the
    # point where they stop growing, a wider window only pushed the cards further apart, and
    # three drawings adrift in a 1900-point strip say less about a desk than three side by side.
    # Stretch with a MaxWidth centres what is left over, which is where a row of a desk belongs.
    $Ui.DeskPanel.MaxWidth = [Math]::Max(1, $cards.Count) * $script:DeskSlotMax

    foreach ($card in $cards) {
        Add-DeskCard -Ui $Ui -Label $card.Label -Display $card.Display
    }

    # The taskbar star goes on the FIRST match against the setting, left to right: that is
    # exactly how the switcher picks it too. Setting it inside the card-building loop is not
    # allowed — each next match would clear the previous one, and the last would win.
    if ($settings.primary) {
        foreach ($child in @($Ui.DeskPanel.Children)) {
            $info = $child.Tag
            if (-not $info) { continue }
            if (Test-DisplayNameMatch -Pattern ([string]$settings.primary) -Label $info.Label -ShortId $info.ShortId) {
                $info.Radio.IsChecked = $true
                break
            }
        }
    }

    Update-DeskShapes -Ui $Ui
}

function Add-DeskCard {
    param($Ui, [string]$Label, $Display)

    $win = $Ui.Window
    $connected = ($null -ne $Display -and -not $Display.Disconnected)

    # No width of its own: the card takes the slot the UniformGrid gives it, which is the panel's
    # width divided by the number of displays. So the row is always exactly as wide as the card
    # it sits in, at any window size and on any desk.
    #
    # It used to be 140 points fixed, with a second rule that divided a hardcoded 534 from four
    # displays on. Both numbers were the window as it opened in 2026-09, and both were wrong the
    # moment somebody dragged the edge: three cards of 140 filled the left half of a 651-point
    # panel and left the right half empty, and the arithmetic for four knew nothing of the width
    # it was actually given. The drawing inside is measured against the real slot instead — see
    # Update-DeskShapes, which now also runs on SizeChanged.
    $outer = New-Object System.Windows.Controls.Border
    # 4 a side, cancelled by the panel's own -4 margin, so the outermost screens line up with the
    # card's padding rather than standing 4 points inside it.
    $outer.Margin = New-Object System.Windows.Thickness 4, 0, 4, 4
    $outer.Padding = New-Object System.Windows.Thickness 8
    $outer.CornerRadius = New-Object System.Windows.CornerRadius 4

    $stack = New-Object System.Windows.Controls.StackPanel
    $outer.Child = $stack

    # A mini-screen with its name immediately below it — the same metaphor as in Windows settings.
    # Its size is NOT set here: it comes from the whole desk at once, in Update-DeskShapes, because
    # a screen can only be drawn to scale against its neighbours.
    #
    # The band is one height for the whole row, so the cards line up whatever shapes the panels
    # are; the mini stands in the middle of it. Its height is worked out with the widths, in
    # Update-DeskShapes — the 76 here is only what a window that was never laid out shows.
    $band = New-Object System.Windows.Controls.Grid
    $band.Height = 76
    $mini = New-Object System.Windows.Controls.Border
    $mini.CornerRadius = New-Object System.Windows.CornerRadius 4
    $mini.Background = $win.FindResource('MiniBrush')
    $mini.BorderBrush = $win.FindResource('InputBorderBrush')
    $mini.BorderThickness = New-Object System.Windows.Thickness 1
    $mini.HorizontalAlignment = 'Center'
    $mini.VerticalAlignment = 'Center'
    $name = New-Object System.Windows.Controls.TextBlock
    $title = Get-DisplayTitle -Label $Label
    $name.Text = $title
    # The title sits below the shape. Inside a 27-inch landscape silhouette it was squeezed to
    # two clipped lines as soon as stable duplicate suffixes appeared, and a portrait silhouette
    # was narrower still. The rectangle says shape; this caption says which physical panel.
    $name.FontSize = 12
    $name.TextWrapping = 'Wrap'
    $name.TextAlignment = 'Center'
    $name.VerticalAlignment = 'Center'
    # Stretch constrains wrapping to this card's slot. Center let the desired width spill into the
    # next card, so two fingerprinted panels could read like one concatenated monitor name.
    $name.HorizontalAlignment = 'Stretch'
    $name.Margin = New-Object System.Windows.Thickness 4, 4, 4, 0
    $name.ToolTip = $title
    [void]$band.Children.Add($mini)
    [void]$stack.Children.Add($band)
    [void]$stack.Children.Add($name)

    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.FontSize = 12
    $sub.TextAlignment = 'Center'
    # On a narrowed card the resolution line no longer fits; an ellipsis says "there is more here",
    # a clipped glyph says nothing. The full text stays available on hover.
    $sub.TextTrimming = 'CharacterEllipsis'
    $sub.Foreground = $win.FindResource('DimBrush')
    $sub.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
    if (-not $connected)      { $sub.Text = (Get-Text -Key 'display.notConnected') }
    elseif ($Display.Active)  { $sub.Text = (Get-Text -Key 'display.resolution' -Values @($Display.Width, $Display.Height, $Display.Hz)) }
    else                      { $sub.Text = (Get-Text -Key 'display.off') }
    # The size is drawn into the card and said in words on hover. Not in the caption itself: that
    # line is already the longest thing on the card, and it is the first to be trimmed.
    $inches = Get-DisplayInches -Display $Display
    $sub.ToolTip = $sub.Text + $(if ($inches -gt 0) { $script:UiDot + ('{0} inches' -f [int][math]::Round($inches)) } else { '' })
    [void]$stack.Children.Add($sub)

    $radio = New-Object System.Windows.Controls.RadioButton
    $radio.GroupName = 'taskbar'
    $radio.Style = $win.FindResource('TaskbarPick')
    $radio.HorizontalAlignment = 'Center'
    $radio.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
    # Windows will not put the taskbar on a display that is not there, so neither will this. It
    # still SHOWS as chosen when settings.primary names it — that setting is a pattern, and it
    # matched this card — and Read-SettingsFromUi still reads a disabled radio, so the choice
    # survives being looked at while the monitor is unplugged.
    $radio.IsEnabled = $connected
    [void]$stack.Children.Add($radio)

    $arrows = New-Object System.Windows.Controls.StackPanel
    $arrows.Orientation = 'Horizontal'
    $arrows.HorizontalAlignment = 'Center'
    $left = New-Object System.Windows.Controls.Button
    $left.Content = [string][char]0x2190   # a left arrow
    $left.Style = $win.FindResource('BtnSubtle')
    $left.FontSize = 12
    $right = New-Object System.Windows.Controls.Button
    $right.Content = [string][char]0x2192  # a right arrow
    $right.Style = $win.FindResource('BtnSubtle')
    $right.FontSize = 12
    [void]$arrows.Children.Add($left)
    [void]$arrows.Children.Add($right)
    [void]$stack.Children.Add($arrows)

    # Dimmed by parts, not as a whole. At 0.55 on the card everything faded together — including
    # the two arrows, which are the one thing on such a card that still works and the whole reason
    # it is kept: its place in the row IS the layout entry, and moving it is how that entry is
    # reordered. So the drawing and the name go quiet and the controls stay at full strength.
    if (-not $connected) {
        $mini.Opacity = 0.45
        $name.Opacity = 0.6
        $outer.ToolTip = Get-Text -Key 'desk.card.remembered' -Values @($title)
    }

    # The size in pixels, for the desk preview. From a monitor that is on we take what it shows
    # right now; from one that is out, its native resolution (which is known from EDID even while
    # the monitor sleeps); from one that is absent we take nothing: the preview will put an
    # ordinary 16:9 in its place.
    $pw = 0; $ph = 0
    if ($Display) {
        if ($Display.Active -and $Display.Width -gt 0) { $pw = [int]$Display.Width; $ph = [int]$Display.Height }
        elseif ($Display.Native)   { $pw = [int]$Display.Native.Width; $ph = [int]$Display.Native.Height }
        elseif ($Display.BestMode) { $pw = [int]$Display.BestMode.Width; $ph = [int]$Display.BestMode.Height }
    }

    $outer.Tag = [pscustomobject]@{
        Label     = $Label
        # The label is the durable selector, but the device path is how a live refresh finds this
        # same physical card if duplicate-panel labels are promoted or enumeration order changes.
        DisplayId = $(if ($Display) { [string]$Display.Id } else { '' })
        ShortId   = $(if ($Display) { [string]$Display.ShortId } else { '' })
        Connected = $connected
        Radio     = $radio
        Name      = $name
        LeftButton = $left
        RightButton = $right
        Width     = $pw
        Height    = $ph
        # The panel's diagonal, which is what the screen is drawn to scale by. 0 — the EDID does
        # not say, and the card takes after its neighbours.
        Inches    = $inches
        # The shape to draw the desk into: Update-DeskShapes gives it its size.
        Mini      = $mini
        Band      = $band
        # What the drawing has to fit inside. Re-measured on every pass of Update-DeskShapes
        # rather than written down once: the window is resizable, and a number taken at build
        # time is the width of a window nobody has dragged yet.
        Inner     = Get-DeskCardInner -Band $band
    }

    # The row is redrawn whenever a card changes WIDTH, which is what happens when the window is
    # dragged: the panel divides itself between the cards, so every card is a different width and
    # every screen in it a different size. Only the width — setting the band's height in
    # Update-DeskShapes changes this element's HEIGHT, and without the guard that would come
    # straight back in here.
    #
    # The row arrives on the band itself and not through $script:ActiveUi: the cards are built
    # before the window is declared active (see the comment about handlers above), which is the
    # same reason the arrows below carry theirs.
    $band.Tag = $Ui
    $band.add_SizeChanged({
        param($sender, $e)
        if (-not $e.WidthChanged) { return }
        Update-DeskShapes -Ui $sender.Tag
    })

    # The arrow needs the row and its own card — both arrive on the arrow itself (see the comment
    # about handlers above). The row does not come through $script:ActiveUi: the cards are built
    # before the window is declared active.
    $panel = $Ui.DeskPanel
    $left.Tag  = [pscustomobject]@{ Panel = $panel; Card = $outer; Delta = -1; Ui = $Ui }
    $right.Tag = [pscustomobject]@{ Panel = $panel; Card = $outer; Delta = 1; Ui = $Ui }
    # The preview is redrawn at once: that is what it is for — to see what will come out BEFORE
    # saving. The row and the window arrive on the button — the cards are built before the window
    # is declared active (see the comment above).
    $move = {
        Move-DeskCard -Panel $this.Tag.Panel -Card $this.Tag.Card -Delta $this.Tag.Delta
        $this.Tag.Ui.LayoutEdited = $true
        Update-DeskShapes -Ui $this.Tag.Ui
    }
    $left.add_Click($move)
    $right.add_Click($move)

    # The taskbar star changes the picture too: the primary monitor is outlined in the accent
    # colour in it, and the whole layout's shift to the coordinate origin is counted from it.
    $radio.Tag = $Ui
    $radio.add_Checked({ Update-DeskShapes -Ui $this.Tag })
    # Click, unlike Checked, is only raised by a person (mouse or keyboard). The window checks a
    # saved primary while building, and that must not silently become an explicit override.
    $radio.add_Click({ $this.Tag.PrimaryEdited = $true })

    [void]$panel.Children.Add($outer)
}

# The table under the cards: what each display reports about itself. The cards are for arranging
# the desk and are drawn; this is for reading — and it is where the Monitor ID lives, which is
# the name settings.json and the log call a display by, and the one a person needs when they open
# either by hand.
function Update-DisplaysTable {
    param($Ui)

    $grid = $Ui.DisplaysTable
    if (-not $grid) { return }
    $grid.Children.Clear()
    $grid.RowDefinitions.Clear()
    $grid.ColumnDefinitions.Clear()

    $win = $Ui.Window
    $rows = @()
    foreach ($m in @($Ui.State | Where-Object { $_ })) {
        $now = Get-Text -Key 'display.off'
        if ($m.Disconnected) { $now = Get-Text -Key 'display.notConnected' }
        elseif ($m.Active)   {
            $now = Get-Text -Key 'display.resolution' -Values @($m.Width, $m.Height, $m.Hz)
            # The same star the card above draws, and not a dash and the word: the two are the
            # same fact in the same window, and reading them as two took a moment every time.
            if ($m.Primary) { $now += '   ' + $script:UiStar + ' ' + (Get-Text -Key 'desk.taskbar.lower') }
        }
        $inches = Get-DisplayInches -Display $m
        $native = '-'
        if ($m.Native) { $native = '{0} x {1}' -f $m.Native.Width, $m.Native.Height }
        $rows += ,@(
            (Get-DisplayTitle -Label ([string]$m.Label))
            [string]$m.ShortId
            $(if ($inches -gt 0) { '{0}"' -f [int][math]::Round($inches) } else { '-' })
            $native
            $now
        )
    }
    if ($rows.Count -eq 0) { return }   # no desk to describe (this is what the tests see)

    # The name takes what is left; the four facts take what they need. A monitor called
    # "LG ULTRAFINE (DisplayPort)" must not push the resolution off the card.
    foreach ($i in 0..4) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = $(if ($i -eq 0) { [System.Windows.GridLength]::new(1, 'Star') }
                       else { [System.Windows.GridLength]::Auto })
        $grid.ColumnDefinitions.Add($col)
    }

    # Monitor ID is not translated on purpose: it is the name settings.json and the log call a
    # display by, and a person who reads it here has to be able to find it there.
    $titles = @((Get-Text -Key 'table.display'), 'Monitor ID',
                (Get-Text -Key 'table.size'), (Get-Text -Key 'table.native'), (Get-Text -Key 'table.now'))
    $line = 0
    foreach ($cell in 0..4) {
        $head = New-Object System.Windows.Controls.TextBlock
        $head.Text = $titles[$cell]
        $head.FontSize = 12
        $head.Foreground = $win.FindResource('DimBrush')
        $head.Margin = New-Object System.Windows.Thickness $(if ($cell -eq 0) { 0 } else { 16 }), 0, 0, 6
        [System.Windows.Controls.Grid]::SetColumn($head, $cell)
        [void]$grid.Children.Add($head)
    }
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))

    foreach ($row in $rows) {
        $line++
        $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))

        # The rule is one element spanning the whole width, drawn in the row it belongs to: five
        # borders under five cells would come apart the moment a column changed width.
        $rule = New-Object System.Windows.Controls.Border
        $rule.BorderBrush = $win.FindResource('CardBorderBrush')
        $rule.BorderThickness = New-Object System.Windows.Thickness 0, 1, 0, 0
        $rule.VerticalAlignment = 'Top'
        [System.Windows.Controls.Grid]::SetRow($rule, $line)
        [System.Windows.Controls.Grid]::SetColumnSpan($rule, 5)
        [void]$grid.Children.Add($rule)

        foreach ($cell in 0..4) {
            $text = New-Object System.Windows.Controls.TextBlock
            $text.Text = [string]$row[$cell]
            $text.FontSize = 13
            $text.TextTrimming = 'CharacterEllipsis'
            $text.Margin = New-Object System.Windows.Thickness $(if ($cell -eq 0) { 0 } else { 16 }), 6, 0, 6
            # Centred, all five of them. Stretched — which is what a TextBlock in a Grid cell is
            # by default — each one sat at the top of its own box, and a box is as tall as the
            # font's line height: the mono cell next door has a different one, so the Monitor ID
            # rode visibly higher than the four cells beside it.
            $text.VerticalAlignment = 'Center'
            # The Monitor ID is what gets typed into settings.json, so it is set in the font that
            # tells an O from a 0. One size down: at 13 the mono face is heavier than the text
            # around it, and the column read as the emphasised one when it is only the exact one.
            if ($cell -eq 1) {
                $text.FontFamily = New-Object System.Windows.Media.FontFamily 'Cascadia Mono, Consolas'
                $text.FontSize = 12
            }
            [System.Windows.Controls.Grid]::SetRow($text, $line)
            [System.Windows.Controls.Grid]::SetColumn($text, $cell)
            [void]$grid.Children.Add($text)
        }
    }
}

# The desk as Windows holds it this second: the displays that are on, left to right by the position
# Windows gave them, and whichever of them carries the taskbar. A pure function of the state and the
# positions, so the button that applies it is one line and this is what gets tested.
#
# Left to right by X, and by Y for a tie: two displays one above the other share an X, and an order
# has to come out all the same. A display that is off has no position and is not in the answer - its
# card stays where it was, behind the ones that are.
function Get-DeskReadOrder {
    param($State, $Positions)

    $placed = @()
    foreach ($m in @($State | Where-Object { $_ -and $_.Active })) {
        $pos = $(if ($Positions -and $Positions.Contains([string]$m.Id)) { $Positions[[string]$m.Id] } else { $null })
        if (-not $pos) { continue }
        $placed += [pscustomobject]@{
            Id = [string]$m.Id; Label = [string]$m.Label
            X = [int]$pos.X; Y = [int]$pos.Y; Primary = [bool]$m.Primary
        }
    }
    $ordered = @($placed | Sort-Object -Property X, Y)
    $primary = @($ordered | Where-Object { $_.Primary } | ForEach-Object { $_.Label })
    return [pscustomobject]@{
        Order   = @($ordered | ForEach-Object { $_.Label })
        Primary = [string]$(if ($primary.Count -gt 0) { $primary[0] } else { '' })
        Displays = $ordered
    }
}

# Refresh the facts attached to configured cards without rebuilding their row. Rebuilding would
# throw away an unsaved order and taskbar choice; matching on the device path lets a card acquire
# the stable fingerprint Windows now reports while keeping every control exactly where it is.
function Update-DeskCardIdentities {
    param($Ui, $State)

    foreach ($card in @($Ui.DeskPanel.Children)) {
        $info = $card.Tag
        if (-not $info -or -not $info.DisplayId) { continue }
        $display = @($State | Where-Object { $_ -and [string]$_.Id -eq [string]$info.DisplayId }) |
                   Select-Object -First 1
        if (-not $display) { continue }
        $info.Label = [string]$display.Label
        $info.ShortId = [string]$display.ShortId
        if ($info.Name) {
            $title = Get-DisplayTitle -Label ([string]$display.Label)
            $info.Name.Text = $title
            $info.Name.ToolTip = $title
        }
    }
}

# Replace only the live facts in an open Settings window. Form controls and the configured row
# remain the person's working copy; the live canvas and table follow an external Windows change.
function Update-SettingsLiveDesk {
    param($Ui, $State = $null, $Positions = $null)

    if (-not $Ui) { return $false }
    if ($null -eq $State) {
        try { $State = @(Get-DeskDisplays -State @(Get-DisplayState)) }
        catch { return $false }
    }
    if ($null -eq $Positions) {
        try { $Positions = Get-CcdSourcePositions }
        catch { return $false }
    }
    Set-DisplayIdentity -State $State
    $Ui.State = @($State)
    $Ui.Positions = $Positions
    Update-DeskCardIdentities -Ui $Ui -State $Ui.State
    Update-LiveDesk -Ui $Ui
    Update-DisplaysTable -Ui $Ui
    return $true
}

# SystemEvents can arrive away from WPF's dispatcher. The latest cache snapshot is kept in script
# scope and the actual control update is posted to the window's own thread without a closure.
$script:PendingSettingsDeskState = $null
function Update-OpenSettingsDesk {
    param($State = $null)

    if ($null -ne $State) { $script:PendingSettingsDeskState = @($State) }
    $ui = $script:ActiveUi
    if (-not $ui -or -not $ui.Window) { return }
    if (-not $ui.Window.Dispatcher.CheckAccess()) {
        [void]$ui.Window.Dispatcher.BeginInvoke([action]{ Update-OpenSettingsDesk })
        return
    }
    $fresh = $script:PendingSettingsDeskState
    $script:PendingSettingsDeskState = $null
    if ($null -eq $fresh) { return }
    if (-not (Update-SettingsLiveDesk -Ui $ui -State $fresh)) {
        Write-DisplayLog 'settings dialog: could not refresh the live desk'
    }
}

# "Copy from Windows": the cards take the order Windows holds and the star goes to the display that
# has the taskbar now. On a desk that has never been arranged this is the whole of the set-up; on one
# that has, it is a way back to what the eye can see after an experiment went wrong. The complete
# snapshot is saved immediately; the footer still tracks the compatibility fields shown in the row.
function Invoke-DeskRead {
    param($Ui, $State = $null, $Positions = $null, [switch]$SkipSnapshot)

    # Adoption is durable before the form changes. A concurrent switch or an unwritable file
    # refuses the snapshot, and the row must then stay exactly as it was.
    if (-not $SkipSnapshot -and (Test-Path Function:\Save-CurrentDesktopSnapshot)) {
        if (-not (Save-CurrentDesktopSnapshot)) { return $false }
    }
    if ($null -eq $State) {
        try { $State = @(Get-DeskDisplays -State @(Get-DisplayState)) }
        catch { return $false }
    }
    if ($null -eq $Positions) {
        try { $Positions = Get-CcdSourcePositions }
        catch { return $false }
    }
    $read = Get-DeskReadOrder -State $State -Positions $Positions
    if (@($read.Order).Count -eq 0) { return $false }

    $Ui.State = @($State)
    $Ui.Positions = $Positions

    $panel = $Ui.DeskPanel
    $at = 0
    Update-DeskCardIdentities -Ui $Ui -State $Ui.State
    foreach ($display in @($read.Displays)) {
        $card = @($panel.Children | Where-Object {
            $_.Tag -and (($_.Tag.DisplayId -and [string]$_.Tag.DisplayId -eq [string]$display.Id) -or
                         (-not $_.Tag.DisplayId -and [string]$_.Tag.Label -eq [string]$display.Label))
        })
        if ($card.Count -eq 0) { continue }
        $i = $panel.Children.IndexOf($card[0])
        if ($i -ne $at) {
            $panel.Children.RemoveAt($i)
            $panel.Children.Insert($at, $card[0])
        }
        $at++
    }
    $primaryDisplay = @($read.Displays | Where-Object { $_.Primary }) | Select-Object -First 1
    if ($primaryDisplay) {
        foreach ($child in @($panel.Children)) {
            $info = $child.Tag
            if ($info -and $info.Radio -and
                (($info.DisplayId -and [string]$info.DisplayId -eq [string]$primaryDisplay.Id) -or
                 (-not $info.DisplayId -and [string]$info.Label -eq [string]$primaryDisplay.Label))) {
                $info.Radio.IsChecked = $true
                break
            }
        }
    }
    # Adopting the exact Windows snapshot removes synthetic overrides. The row still follows the
    # fresh state so the configured view says what Save will preserve for older settings readers.
    $Ui.AdoptLiveDesk = $true
    $Ui.LayoutEdited = $false
    $Ui.PrimaryEdited = $false
    Update-DeskShapes -Ui $Ui
    Update-LiveDesk -Ui $Ui
    return $true
}

# What "Add a combination" opens on: the displays that are on, and the one with the taskbar. The same
# shape as a combo's working record, so the editor reads it the way it reads one being edited - but it
# is handed to the editor alone and never to Set-UiMode, which would write into it instead of adding a
# new combination to the list.
function New-DeskTemplate {
    param($State)

    $on = @($State | Where-Object { $_ -and $_.Active -and -not $_.Disconnected })
    $primary = @($on | Where-Object { $_.Primary } | ForEach-Object { [string]$_.Label })
    return [pscustomobject]@{
        Name     = ''
        Patterns = @($on | ForEach-Object { [string]$_.Label })
        Primary  = [string]$(if ($primary.Count -gt 0) { $primary[0] } else { '' })
    }
}

function Move-DeskCard {
    param($Panel, $Card, [int]$Delta)

    $i = $Panel.Children.IndexOf($Card)
    if ($i -lt 0) { return }
    $j = $i + $Delta
    if ($j -lt 0 -or $j -ge $Panel.Children.Count) { return }
    $Panel.Children.RemoveAt($i)
    $Panel.Children.Insert($j, $Card)
}

# --- the desk drawn into its cards ------------------------------------------
# The row of cards is the picture of the desk: their order left to right is the layout, and the
# screen inside each card is the panel it stands for. Which means the screens have to be drawn
# to the size a person SEES — the inches of the panel — and not to its resolution.
#
# Drawing by pixels was measured and it lied: the 4K UltraFine got 128 points and the 1440p
# beside it 85, while on the desk the 4K is the 24-inch one and the 1440p is a 27. The picture
# said the opposite of what was standing there.
#
# The difference is damped — the width goes as the square root of the ratio of the diagonals —
# because the row is for telling which panel is which, not for measuring them: 24 next to 27
# comes out at 94 %, and 32 next to 24 at 115 %. Undamped, a 24 beside a 32 would be a thumbnail.

# How much room a card has inside itself for the drawing. The band is measured rather than the
# card: it is the strip the screen is drawn into, it already stands inside the card's padding,
# and its width is what changes when the window is dragged — so it is both the measure and the
# signal (see the SizeChanged in Add-DeskCard).
#
# ActualWidth is 0 until the window has been laid out — a window built and never shown (the
# tests, render-preview before Show), and the first pass of Update-DeskPanel on a real one. Then
# this answers with about the narrowest card the smallest allowed window can produce, so a desk
# is drawn rather than not drawn, and the SizeChanged pass corrects it a frame later.
$script:DeskCardAssumed = 96.0

function Get-DeskCardInner {
    param($Band)

    if (-not $Band) { return $script:DeskCardAssumed }
    $wide = [double]$Band.ActualWidth
    if ($wide -le 0) { return $script:DeskCardAssumed }
    return [math]::Max(24.0, $wide)
}

# The tallest a band may grow to. Without a cap, a desk of two on a window somebody has dragged
# wide draws two screens 200 points tall, and a 4:3 panel makes it worse - the row of cards would
# take the page and the table under it would be below the fold. 112 is large enough that a 24
# beside a 27 is plainly the smaller one, which is the whole job of the drawing.
$script:DeskBandMax = 112.0
# And the widest one card may get, which follows from that: a 16:9 panel 112 points tall is 199
# wide, plus the card's 8 of padding a side and the 4 of margin. Past this a card is only air.
$script:DeskSlotMax = 224.0

function Update-DeskShapes {
    param($Ui)

    if (-not $Ui -or -not $Ui.DeskPanel) { return }

    # What we know about the cards, in their VISIBLE order: that order is the layout.
    $infos = @()
    foreach ($child in @($Ui.DeskPanel.Children)) {
        $info = $child.Tag
        if ($info) { $infos += $info }
    }
    if ($infos.Count -eq 0) { return }

    # A monitor whose EDID says nothing about its size is drawn as the average of the ones that
    # do: on a row where everybody else is a 27, the unknown one is a card like its neighbours
    # rather than a dot. Nobody knows anything — they are all drawn the same.
    $known = @($infos | ForEach-Object { [double]$_.Inches } | Where-Object { $_ -gt 0 })
    $stand = $(if ($known.Count -gt 0) { [double]($known | Measure-Object -Average).Average } else { 1.0 })
    $diagonals = @($infos | ForEach-Object {
        $(if ([double]$_.Inches -gt 0) { [double]$_.Inches } else { $stand })
    })
    $biggest = [double]($diagonals | Measure-Object -Maximum).Maximum
    if ($biggest -le 0) { return }

    # The widest screen fills its card, and everything else is drawn against it. Measured now
    # rather than remembered from when the card was built: the window is resizable, and this runs
    # again on every SizeChanged of the row. The narrowest card in the row sets the measure — all
    # the slots are the same width, so they only differ while a card is still being laid out, and
    # taking the smallest keeps every drawing inside its own card meanwhile.
    foreach ($info in $infos) { $info.Inner = Get-DeskCardInner -Band $info.Band }
    $base = [double]($infos | ForEach-Object { [double]$_.Inner } | Measure-Object -Minimum).Minimum

    $widths = @(); $heights = @()
    for ($i = 0; $i -lt $infos.Count; $i++) {
        $w = $base * [math]::Sqrt($diagonals[$i] / $biggest)
        # The SHAPE is still the resolution's, so a 21:9 stays a long one. Nothing known about a
        # monitor that is not here right now — an ordinary 16:9, and it keeps its place in the row.
        $px = [double]$infos[$i].Width; $py = [double]$infos[$i].Height
        if ($px -le 0 -or $py -le 0) { $px = 16; $py = 9 }
        $widths += $w
        $heights += $w * $py / $px
    }

    # The band grows to the tallest drawing rather than the drawings shrinking to a fixed band.
    # At 76 points fixed, a wide window drew three 16:9 screens 97 points tall and then shrank
    # the whole row by a fifth to get them back in — so widening the window past a point made the
    # desk no bigger, and a 4:3 panel made every screen beside it small. It is one height for the
    # whole row: a card taller than its neighbours would read as a monitor standing higher on the
    # desk, which is not what any of this means. Past DeskBandMax the row shrinks as it used to.
    $tallest = [double]($heights | Measure-Object -Maximum).Maximum
    $band = [math]::Min($script:DeskBandMax, [math]::Max(60.0, [math]::Ceiling($tallest)))
    $fit = $(if ($tallest -gt $band -and $tallest -gt 0) { $band / $tallest } else { 1.0 })

    $win = $Ui.Window
    for ($i = 0; $i -lt $infos.Count; $i++) {
        $info = $infos[$i]
        $info.Band.Height = $band

        # Floors, not the raw numbers: a fractional width leaves a hairline of background down
        # one edge of the border, and on a row of three that reads as sloppy drawing.
        $info.Mini.Width = [math]::Max(22, [math]::Floor($widths[$i] * $fit))
        $info.Mini.Height = [math]::Max(16, [math]::Floor($heights[$i] * $fit))
        # The taskbar display is outlined in the accent colour: "primary" in Windows is a place,
        # and this is the card standing at the origin of it.
        $primary = [bool]($info.Radio -and $info.Radio.IsChecked)
        $info.Mini.BorderThickness = New-Object System.Windows.Thickness $(if ($primary) { 2 } else { 1 })
        $info.Mini.BorderBrush = $win.FindResource($(if ($primary) { 'AccentBrush' } else { 'InputBorderBrush' }))
    }
}

# --- brightness -------------------------------------------------------------
# Brightness is written in the settings two ways, and both are needed: a number ("the same
# for every monitor in the mode", which is how it is usually written) and an object ("one
# each"). The window has to handle both AND MUST NOT TURN ONE INTO THE OTHER ON ITS OWN: by
# expanding a number into an object over the monitors that happen to be on the desk it would
# lose the brightness for a monitor that was pulled out, and it would change the meaning of
# an "all" entry for a monitor that turns up tomorrow. So the form is a person's choice
# ("Then..." in the card) and not the window's guess.

# A value from the settings -> the window's model. A pure function.
#   Kind = 'none'  no brightness is set for this mode;
#          'one'   one number for every monitor in the mode (Value);
#          'each'  a number each (Map: name -> number).
function ConvertTo-LevelModel {
    param($Setting)

    $model = [pscustomobject]@{ Kind = 'none'; Value = 80; Map = [ordered]@{} }
    if ($null -eq $Setting) { return $model }

    if ($Setting -is [System.Collections.IDictionary]) {
        foreach ($key in @($Setting.Keys)) {
            if (-not $key) { continue }
            $parsed = 0
            if ([int]::TryParse([string]$Setting[$key], [ref]$parsed)) {
                $model.Map[[string]$key] = [math]::Max(0, [math]::Min(100, $parsed))
            }
        }
        if ($model.Map.Count -gt 0) { $model.Kind = 'each' }
        return $model
    }

    $parsed = 0
    if ([int]::TryParse([string]$Setting, [ref]$parsed)) {
        $model.Kind = 'one'
        $model.Value = [math]::Max(0, [math]::Min(100, $parsed))
    }
    return $model
}

# And back again, into what leaves for settings.json. $null means "the key must not be
# there": an empty object in the file would look like a setting that does not exist.
function ConvertFrom-LevelModel {
    param($Model)

    if (-not $Model) { return $null }
    switch ([string]$Model.Kind) {
        'one'  { return [int]$Model.Value }
        'each' {
            if (-not $Model.Map -or $Model.Map.Count -eq 0) { return $null }
            $out = [ordered]@{}
            foreach ($key in @($Model.Map.Keys)) { $out[[string]$key] = [int]$Model.Map[$key] }
            return $out
        }
        default { return $null }
    }
}

# A whole "mode key -> model" map out of a whole section of settings.json. Brightness and
# contrast are the same shape and go through the same pair of functions: a second copy of this
# would drift away from the first the day one of them was fixed.
#
# No empty models are created here: "the key exists but has no level in it" is not a setting
# but rubbish out of the file ({} or a number that is not a number). Since it is never put
# there, "empty means absent" does not have to be checked by everyone who looks at the map.
function ConvertTo-LevelModels {
    param($Section)

    $out = [ordered]@{}
    if (-not $Section) { return $out }
    foreach ($key in @($Section.Keys)) {
        $model = ConvertTo-LevelModel $Section[$key]
        if ($null -ne (ConvertFrom-LevelModel $model)) { $out[[string]$key] = $model }
    }
    return $out
}

# Every model of the window -> what leaves for settings.json. Modes with no level do not reach
# the file at all: a key with a dummy dictionary in it would look like a setting that does not
# exist. A pure function.
function ConvertFrom-LevelModels {
    param($Models)

    $out = [ordered]@{}
    if (-not $Models) { return $out }
    foreach ($key in @($Models.Keys)) {
        $value = ConvertFrom-LevelModel $Models[$key]
        if ($null -ne $value) { $out[[string]$key] = $value }
    }
    return $out
}

# The slider rows: the mode's monitors plus the "orphans" — names that are already in the map
# but match no monitor of the mode (the monitor was taken away, the combo was edited by hand).
# They have to be SHOWN, or the setting can neither be seen nor cleared — the shortcut
# bindings live by the same rule.
function Get-LevelRowNames {
    # The parameter's name must not match the accumulator's even in case: in PowerShell $rows
    # and $Rows are one variable, and the first assignment would wipe out what arrived from
    # outside.
    param($Displays, $Map)

    $rows = @()
    foreach ($name in @($Displays)) {
        if (-not $name) { continue }
        if ($rows -notcontains [string]$name) { $rows += [string]$name }
    }
    if ($Map) {
        foreach ($key in @($Map.Keys)) {
            if ($rows -notcontains [string]$key) { $rows += [string]$key }
        }
    }
    return @($rows | Where-Object { $_ })
}

# The forms a level can be entered in. The ORDER of this list is the order of the items in the
# box, and Update-LevelGroup picks the selected item by the index of the kind in it — so it is
# not free to rearrange.
$script:LevelKinds = @('none', 'one', 'each')

# The same three lines for brightness and for contrast, differing in one noun. "Leave the
# brightness alone" standing under the Contrast heading is the kind of thing nobody notices
# until they have set the wrong one.
function Get-LevelKindTitle {
    param([string]$Kind, [string]$Noun)

    switch ($Kind) {
        'none' { return (Get-Text -Key 'level.none' -Values @($Noun)) }
        'one'  { return (Get-Text -Key 'level.one') }
        'each' { return (Get-Text -Key 'level.each') }
    }
    return $Kind
}

# Brightness and contrast from the settings into the window's working models, keyed by mode.
# The mode editor edits them, and they leave on Save (see ConvertFrom-LevelModels).
function Import-LevelSettings {
    param($Ui, $Settings)

    $Ui.Levels   = ConvertTo-LevelModels -Section $(if ($Settings) { $Settings.brightness } else { $null })
    $Ui.Contrast = ConvertTo-LevelModels -Section $(if ($Settings) { $Settings.contrast }   else { $null })

    # The presets come across as they are written: "register:number" per display. Only what parses
    # is taken in - the window owns this setting now, and a line it could not read would be written
    # back out on the next Save as though somebody had meant it.
    $Ui.Picture = [ordered]@{}
    if ($Settings -and $Settings.picture) {
        foreach ($key in @($Settings.picture.Keys)) {
            $one = $Settings.picture[$key]
            if (-not ($one -is [System.Collections.IDictionary])) { continue }
            $kept = [ordered]@{}
            foreach ($name in @($one.Keys)) {
                $text = ([string]$one[$name]).Trim()
                if (ConvertFrom-PictureSetting $text) { $kept[[string]$name] = $text }
            }
            if ($kept.Count -gt 0) { $Ui.Picture[[string]$key] = $kept }
        }
    }
}

# The window's map -> what goes into settings.json. Empty entries do not travel: a mode whose
# presets were all forgotten leaves no key behind.
function ConvertTo-PictureSettings {
    param($Picture)

    $out = [ordered]@{}
    if (-not $Picture) { return $out }
    foreach ($key in @($Picture.Keys)) {
        $one = $Picture[$key]
        if (-not ($one -is [System.Collections.IDictionary])) { continue }
        $kept = [ordered]@{}
        foreach ($name in @($one.Keys)) {
            $text = ([string]$one[$name]).Trim()
            if ($text -and (ConvertFrom-PictureSetting $text)) { $kept[[string]$name] = $text }
        }
        if ($kept.Count -gt 0) { $out[[string]$key] = $kept }
    }
    return $out
}

# The audio device and the commands out of the settings into the window's working maps. Both
# are edited in the mode editor now, so both have to be in the window rather than carried
# blindly from the file — see the loop in Read-SettingsFromUi.
#
# The entries are normalised on the way in (an empty device, a hook that is a bare string) so
# that everything downstream sees one shape and not four.
function Import-ModeExtras {
    param($Ui, $Settings)

    $Ui.Audio = [ordered]@{}
    if ($Settings -and $Settings.audio) {
        foreach ($key in @($Settings.audio.Keys)) {
            $device = ([string]$Settings.audio[$key]).Trim()
            if ($device) { $Ui.Audio[[string]$key] = $device }
        }
    }

    $Ui.Hooks = [ordered]@{}
    if ($Settings -and $Settings.hooks) {
        foreach ($key in @($Settings.hooks.Keys)) {
            $hook = ConvertTo-HookSetting $Settings.hooks[$key]
            if ($hook) { $Ui.Hooks[[string]$key] = $hook }
        }
    }

    # HDR is kept per display in the window whatever shape the file wrote it in: a bare true for a
    # whole mode becomes one row per display the moment the editor opens (ConvertTo-HdrMap), and the
    # file gets the per-display form back. That is the form a person can read a row of.
    $Ui.Hdr = [ordered]@{}
    if ($Settings -and $Settings.hdr) {
        foreach ($key in @($Settings.hdr.Keys)) {
            $one = ConvertTo-HdrSetting $Settings.hdr[$key]
            if ($null -eq $one) { continue }
            if ($one -is [bool]) { $Ui.Hdr[[string]$key] = $one }
            else { $Ui.Hdr[[string]$key] = $one }
        }
    }
}

# A mode's HDR setting -> the editor's map, display name -> bool. A bare bool is spread over the
# displays the mode has, so that the rows show what the switch will actually do to each of them.
function ConvertTo-HdrMap {
    param($Setting, [string[]]$Names)

    $map = [ordered]@{}
    if ($null -eq $Setting) { return $map }
    if ($Setting -is [bool]) {
        foreach ($name in @($Names)) { if ($name) { $map[[string]$name] = [bool]$Setting } }
        return $map
    }
    if ($Setting -is [System.Collections.IDictionary]) {
        foreach ($key in @($Setting.Keys)) { $map[[string]$key] = [bool]$Setting[$key] }
    }
    return $map
}

# The window's HDR map -> what leaves for settings.json: only modes that say something.
function ConvertTo-HdrSettings {
    param($Hdr)

    $out = [ordered]@{}
    if (-not $Hdr) { return $out }
    foreach ($key in @($Hdr.Keys)) {
        $value = $Hdr[$key]
        if ($value -is [bool]) { $out[[string]$key] = $value; continue }
        if ($value -is [System.Collections.IDictionary] -and $value.Count -gt 0) {
            $one = [ordered]@{}
            foreach ($name in @($value.Keys)) { $one[[string]$name] = [bool]$value[$name] }
            $out[[string]$key] = $one
        }
    }
    return $out
}

# The window's audio map -> what leaves for settings.json. An empty device does not reach the
# file: a key holding an empty string would look like a device that cannot be found, and the
# log would complain about it on every switch.
function ConvertTo-AudioSettings {
    param($Audio)

    $out = [ordered]@{}
    if (-not $Audio) { return $out }
    foreach ($key in @($Audio.Keys)) {
        $device = ([string]$Audio[$key]).Trim()
        if ($device) { $out[[string]$key] = $device }
    }
    return $out
}

# The same for the commands. ConvertTo-HookSetting hands back $null for a pair that is empty on
# both sides, and that is exactly "there is no entry".
function ConvertTo-HookSettings {
    param($Hooks)

    $out = [ordered]@{}
    if (-not $Hooks) { return $out }
    foreach ($key in @($Hooks.Keys)) {
        $hook = ConvertTo-HookSetting $Hooks[$key]
        if ($hook) { $out[[string]$key] = $hook }
    }
    return $out
}

# A pair of commands as one string, so that two of them can be compared. Empty means "there is
# no command" — the same rule Get-LevelFingerprint lives by, and for the same reason (see
# Sync-EditorInheritance).
function Get-HookFingerprint {
    param([string]$Before, [string]$After)

    $b = ([string]$Before).Trim()
    $a = ([string]$After).Trim()
    if (-not $b -and -not $a) { return '' }
    # Tab-joined: a tab cannot occur in a command line typed into a one-line box, so no two
    # different pairs can collide by the separator landing inside a field.
    return ($b + "`t" + $a)
}

# A copy of the model: the editor edits it in place, and Cancel has to leave the window with
# what was there. Rolling the sliders back would be a lie — a copy is more honest and costs
# one dictionary entry.
function Copy-LevelModel {
    param($Model)

    $copy = [pscustomobject]@{ Kind = 'none'; Value = 80; Map = [ordered]@{} }
    if (-not $Model) { return $copy }
    $copy.Kind = [string]$Model.Kind
    $copy.Value = [int]$Model.Value
    foreach ($key in @($Model.Map.Keys)) { $copy.Map[[string]$key] = [int]$Model.Map[$key] }
    return $copy
}

# The monitors the editor is looking at, by the names they will be written to the file with.
# For a combo those are the TICKED checkboxes and not what is written in the file: the person
# unticked a monitor — its brightness row has to go with it, without waiting for Save. For the
# rest the membership is set by the desk, and Get-ModeMembers is asked about it — the same one
# that answers this question during a switch. Parsing the key ourselves is not allowed: for two
# identical models the solo key holds a short ID or "#2" rather than the monitor's name.
function Get-EditorDisplayNames {
    param($Editor)

    if ($Editor.Kind -eq 'combo') {
        return @($Editor.Checks | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    }
    if (-not $Editor.Mode) { return @() }
    return @(Get-ModeMembers -Mode $Editor.Mode -State $Editor.State | ForEach-Object { [string]$_.Label })
}

# The same list for the picture card, and a monitor that is not on the desk right now counts.
# Get-ModeMembers drops a disconnected one, and a preset is remembered PER DISPLAY: a solo or
# "all" mode opened while its monitor is off would show no row at all and hand back an empty map
# — which Set-UiMode reads as "the person cleared it" and writes as a deletion. A combo needs
# nothing here — its ticks already carry the members that are away, as "(not connected)" (see
# Add-ComboMemberChecks).
function Get-EditorPictureNames {
    param($Editor)

    # Only the two kinds whose membership comes from Get-ModeMembers differ here. A combo already
    # answers correctly, and any other kind (an orphan row) has no membership at all — handing it
    # the whole desk would invent rows for a mode that no longer exists.
    $kind = [string]$Editor.Kind
    if ($kind -ne 'solo' -and $kind -ne 'all') { return @(Get-EditorDisplayNames -Editor $Editor) }
    if (-not $Editor.Mode) { return @() }

    # Get-ModeMembers without its one filter. Not a change to that function: it is on the switch
    # path, where "a member is a monitor that is there" is exactly right.
    $names = @()
    foreach ($m in @($Editor.State)) {
        if (-not $m) { continue }
        if ($kind -eq 'solo' -and [string]$m.Id -ne [string]$Editor.Mode.Id) { continue }
        if ([string]$m.Label) { $names += [string]$m.Label }
    }
    return @($names)
}

# The display rows carry labels because those are what a person reads and what a newly remembered
# value is written under. A hand-edited map may instead use the Monitor ID, which the switch accepts
# on equal terms with the label, so matching an existing entry needs the same second name.
function Get-EditorDisplayShortId {
    param($Editor, [string]$Name)

    foreach ($display in @($Editor.State)) {
        if ($display -and [string]$display.Label -eq $Name) { return [string]$display.ShortId }
    }
    return ''
}

# Which entry of the editor's map stands for one display, or '' when nothing is remembered for it.
#
# A preset is keyed by A PIECE OF A NAME, not by the whole one: that is what Get-PicturePlan
# matches by on a switch, and what Get-DefaultSettings and `Set-Display.ps1 brightness` tell a
# person to write. So "ULTRAFINE" in the file is the preset of the display labelled
# "LG ULTRAFINE", and looking it up by the label alone found nothing: the row said "Not
# remembered" over a preset that was there, and Get-PictureForSave then handed back a map without
# it — which Set-UiMode writes as a deletion. Opening the editor and pressing Save was enough to
# lose a preset written by hand.
#
# The exact name wins, so a desk whose map holds both a whole name and a piece of one behaves the
# way anybody would read it. Below that it is Test-DisplayNameMatch, the same question the switch
# asks, so the editor shows exactly the entry the switch would use.
function Get-PictureKeyFor {
    param($Editor, [string]$Name)

    if (-not $Name -or -not $Editor.Picture) { return '' }
    if ($Editor.Picture.Contains($Name)) { return [string]$Name }
    $shortId = Get-EditorDisplayShortId -Editor $Editor -Name $Name
    foreach ($key in @($Editor.Picture.Keys)) {
        if (Test-DisplayNameMatch -Pattern ([string]$key) -Label $Name -ShortId $shortId) { return [string]$key }
    }
    return ''
}

# One level card of the editor: brightness or contrast. The two are the same machinery over the
# same model and differ in exactly two things — the noun they print and the map they inherit
# from — so they are one set of functions with a group object handed in, not two copies. The
# copies were the first version, and the contrast card was already a fix behind on the day it
# was written.
#
# $Prefix is the x:Name prefix its controls carry in the markup ("Level" for brightness,
# "Contrast" for contrast); $Source is the whole "mode key -> model" map it inherits from while
# the combo's name is being typed (see Sync-EditorInheritance).
function New-LevelGroup {
    param($Editor, [string]$Prefix, [string]$Noun, $Source, $Model)

    $win = $Editor.Window
    $group = [pscustomobject]@{
        # The editor, for the window, the mode's displays and its answer on Save. A group cannot
        # work out its own display list: that depends on the ticked members of the combo.
        Owner     = $Editor
        Noun      = $Noun
        Source    = $(if ($Source) { $Source } else { [ordered]@{} })
        # A COPY of the model: the editor edits it in place, and Cancel has to leave the window
        # with what was there.
        Model     = (Copy-LevelModel $Model)
        KindBox   = $win.FindName($Prefix + 'KindBox')
        OnePanel  = $win.FindName($Prefix + 'OnePanel')
        OneSlider = $win.FindName($Prefix + 'OneSlider')
        OneValue  = $win.FindName($Prefix + 'OneValue')
        RowsPanel = $win.FindName($Prefix + 'RowsPanel')
        # While the panel is being rebuilt the handlers keep quiet: otherwise setting a value in
        # code would immediately count as a person's edit.
        Busy      = $false
        # What we filled in ourselves, so a person's own edit is not overwritten by a name.
        Auto      = ''
    }

    # Which group a control answers for is on the control itself: this window's handlers hold no
    # closures (see the header). The Tag goes on BEFORE the handlers, or the first event would
    # find nothing there.
    $group.KindBox.Tag = $group
    $group.OneSlider.Tag = $group

    $group.KindBox.add_SelectionChanged({
        $group = $this.Tag
        if (-not $group -or $group.Busy) { return }
        $item = $this.SelectedItem
        if (-not $item) { return }
        $group.Model.Kind = [string]$item.Tag
        # The move from "one number" to "one each": we fill the mode's monitors with that very
        # number. That way a person gets what they were looking at and edits from there rather
        # than from an empty list. The move back does not erase the map — coming back, they
        # will find their values in place.
        if ($group.Model.Kind -eq 'each' -and $group.Model.Map.Count -eq 0) {
            foreach ($name in @(Get-EditorDisplayNames -Editor $group.Owner)) {
                $group.Model.Map[[string]$name] = [int]$group.Model.Value
            }
        }
        Update-LevelGroup -Group $group
    })

    $group.OneSlider.add_ValueChanged({
        $group = $this.Tag
        if (-not $group -or $group.Busy) { return }
        $group.Model.Value = [int]$this.Value
        $group.OneValue.Text = [string][int]$this.Value
    })

    return $group
}

# The list of entry forms, for one card. The order of the items IS the order of
# $script:LevelKinds: the item in Update-LevelGroup is picked by it as well.
function Initialize-LevelGroup {
    param($Group)

    $Group.Busy = $true
    try {
        $Group.KindBox.Items.Clear()
        foreach ($kind in @($script:LevelKinds)) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = Get-LevelKindTitle -Kind $kind -Noun $Group.Noun
            $item.Tag = [string]$kind
            [void]$Group.KindBox.Items.Add($item)
        }
    }
    finally { $Group.Busy = $false }

    Update-LevelGroup -Group $Group
}

# Show the card's model: the form choice, one slider, or a row per monitor.
function Update-LevelGroup {
    param($Group)

    $model = $Group.Model
    if (-not $model) { return }

    $Group.Busy = $true
    try {
        $index = @($script:LevelKinds).IndexOf([string]$model.Kind)
        if ($index -lt 0) { $index = 0 }
        $Group.KindBox.SelectedIndex = $index

        $Group.OnePanel.Visibility = $(if ($model.Kind -eq 'one') { 'Visible' } else { 'Collapsed' })
        $Group.OneSlider.Value = [double][int]$model.Value
        $Group.OneValue.Text = [string][int]$model.Value

        $Group.RowsPanel.Children.Clear()
        if ($model.Kind -eq 'each') {
            foreach ($name in @(Get-LevelRowNames -Displays (Get-EditorDisplayNames -Editor $Group.Owner) -Map $model.Map)) {
                Add-LevelRow -Group $Group -Name $name
            }
        }
    }
    finally { $Group.Busy = $false }
}

function Add-LevelRow {
    param($Group, [string]$Name)

    $Model = $Group.Model
    $win = $Group.Owner.Window
    $set = $Model.Map.Contains($Name)

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness 0, 4, 0, 4
    # The widths are given as objects rather than strings: GridLength has no Parse (the first
    # version called it and died on the move to "one each" — what caught it was not a test but
    # a snapshot of the window, which is why there is a test for building the rows now).
    foreach ($width in @((New-Object System.Windows.GridLength 150),
                         (New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)),
                         [System.Windows.GridLength]::Auto)) {
        $column = New-Object System.Windows.Controls.ColumnDefinition
        $column.Width = $width
        [void]$grid.ColumnDefinitions.Add($column)
    }

    # The checkbox IS "set / not set": unticked means this monitor's brightness is not touched
    # in this mode, not "zero".
    $check = New-Object System.Windows.Controls.CheckBox
    $check.Style = $win.FindResource('Check')
    $check.Content = Get-DisplayTitle -Label $Name
    $check.IsChecked = $set
    $check.VerticalAlignment = 'Center'
    [void]$grid.Children.Add($check)

    $slider = New-Object System.Windows.Controls.Slider
    $slider.Style = $win.FindResource('Level')
    $slider.VerticalAlignment = 'Center'
    $slider.IsEnabled = $set
    $slider.Value = [double]$(if ($set) { [int]$Model.Map[$Name] } else { 80 })
    [System.Windows.Controls.Grid]::SetColumn($slider, 1)
    [void]$grid.Children.Add($slider)

    $value = New-Object System.Windows.Controls.TextBlock
    $value.Width = 34
    $value.TextAlignment = 'Right'
    $value.VerticalAlignment = 'Center'
    $value.Margin = New-Object System.Windows.Thickness 12, 0, 0, 0
    $value.Text = $(if ($set) { [string][int]$Model.Map[$Name] } else { 'off' })
    if (-not $set) { $value.Foreground = $win.FindResource('DimBrush') }
    [System.Windows.Controls.Grid]::SetColumn($value, 2)
    [void]$grid.Children.Add($value)

    # A row's state lives on the elements themselves (.Tag), as it does in every other handler
    # of this window: .GetNewClosure() is banned here (see the header). The window is carried on
    # the row rather than reached for through the group's owner: a handler that has to walk two
    # links to find a brush is one rename away from a null.
    $row = [pscustomobject]@{ Group = $Group; Model = $Model; Name = $Name; Window = $win
                              Slider = $slider; Value = $value; Check = $check }
    $check.Tag = $row
    $slider.Tag = $row

    $check.add_Click({
        $row = $this.Tag
        if ($row.Group.Busy) { return }
        if ($this.IsChecked) {
            $row.Model.Map[$row.Name] = [int]$row.Slider.Value
            $row.Slider.IsEnabled = $true
            $row.Value.Text = [string][int]$row.Slider.Value
            $row.Value.Foreground = $row.Window.FindResource('TextBrush')
        }
        else {
            $row.Model.Map.Remove($row.Name)
            $row.Slider.IsEnabled = $false
            $row.Value.Text = Get-Text -Key 'display.off'
            $row.Value.Foreground = $row.Window.FindResource('DimBrush')
        }
    })

    $slider.add_ValueChanged({
        $row = $this.Tag
        if ($row.Group.Busy) { return }
        if (-not $row.Check.IsChecked) { return }
        $row.Model.Map[$row.Name] = [int]$this.Value
        $row.Value.Text = [string][int]$this.Value
    })

    [void]$Group.RowsPanel.Children.Add($grid)
}

# The output devices, into the dropdown, once. Fetched on the first opening of the list and
# never on building the window: enumerating the endpoints goes out to COM, and there is no
# reason to pay that for every Edit click — the same reason "Ask the monitors" below is a button
# of its own rather than something the editor does on the way up.
#
# What is STORED is a piece of a device's name, not the name and not an id: a driver update
# renames "Speakers (Realtek High Definition Audio)" and the setting has to survive it. So the
# list only fills the box in, and whatever is left in the box is what gets saved.
#
# A refusal is written to the log and nothing more: the box can be typed into by hand, so a
# machine whose audio service is unwell loses the convenience and not the setting.
function Add-AudioDeviceItems {
    param($Editor)

    if ($Editor.AudioListed) { return }
    $Editor.AudioListed = $true
    try {
        foreach ($device in @(Get-AudioDevices)) {
            if ([string]$device.Name) { [void]$Editor.AudioBox.Items.Add([string]$device.Name) }
        }
    }
    catch { Write-DisplayLog "settings dialog: could not list the audio devices - $($_.Exception.Message)" }
}

# "Ask the monitors" — query DDC/CI right now. As a button of its own rather than on opening
# the window: one query costs tens of milliseconds per monitor, and on a stuck bus up to a
# second with the retries, and there is no reason to pay that for every opening of the
# settings.
function Invoke-LevelProbe {
    param($Editor)

    Set-UiNote -Block $Editor.LevelNote -Text (Get-Text -Key 'probe.asking')
    # And it has to be PAINTED before we go to the bus. WPF draws when the handler gives the thread
    # back, and the query below holds it for tenths of a second — up to a second on a bus that has to be
    # asked three times. Without this pump the word "asking" appeared together with the answer, that is,
    # never: a person saw a window frozen for a second and no reason for it.
    try {
        $Editor.LevelNote.Dispatcher.Invoke([action]{},
            [System.Windows.Threading.DispatcherPriority]::Render)
    }
    catch { }   # no dispatcher (a window built and never shown, as in the tests) — nothing to paint

    $answers = @()
    try { $answers = @(Get-MonitorLevels) }
    catch {
        Set-UiNote -Block $Editor.LevelNote -Text (Get-Text -Key 'probe.failed' -Values @($_.Exception.Message))
        return
    }

    # DDC hands back the output's name (\\.\DISPLAY1); a person needs the monitor's name.
    $byOutput = @{}
    foreach ($m in @($Editor.State)) { if ($m.Output) { $byOutput[[string]$m.Output] = [string]$m.Label } }

    # Both cards are answered by one walk of the bus, so both are reported. A monitor that does
    # brightness and refuses contrast is common, and without naming which is which the Contrast
    # card above would look broken rather than unsupported.
    $good = @()
    $bad = @()
    foreach ($a in $answers) {
        $label = $(if ($byOutput.Contains([string]$a.Device)) { $byOutput[[string]$a.Device] } else { [string]$a.Device })
        $can = @()
        if ($a.CanBrightness) { $can += (Get-Text -Key 'probe.brightness' -Values @($a.Brightness)) }
        if ($a.CanContrast)   { $can += (Get-Text -Key 'probe.contrast' -Values @($a.Contrast)) }
        if ($can.Count -gt 0) { $good += ('{0} ({1})' -f $label, ($can -join ', ')) } else { $bad += $label }
    }

    $parts = @()
    if ($good.Count -gt 0) { $parts += (Get-Text -Key 'probe.answers' -Values @(($good -join ', '))) }
    if ($bad.Count -gt 0)  { $parts += (Get-Text -Key 'probe.noAnswer' -Values @(($bad -join ', '))) }
    if ($parts.Count -eq 0) { $parts += (Get-Text -Key 'probe.nobody') }
    # We always say something about the sleeping ones: they are not in the answer at all, and
    # without this line it would look as though the monitor cannot do it.
    Set-UiNote -Block $Editor.LevelNote -Text (($parts -join '; ') + '. ' + (Get-Text -Key 'probe.sleeping'))
}

# --- a mode: editing one ----------------------------------------------------
# One editor for any mode, and that is the answer to "where is this configured". For a combo
# everything is edited — the name, the membership, the taskbar, the shortcut, the brightness;
# for a monitor mode and for "all" the membership is set by life itself, and the shortcut and
# the brightness are what remain. There are no three cards for this any more: a person looks
# for a mode's settings where they clicked Edit.

# Take everything this window holds off a key. One place for all three cases (a rename, a combo
# deletion, an orphan row cleared): there are already two settings living in the window under a
# mode key, and copies that drifted apart would leave a ghost setting — the very one that shows
# up in no window at all.
function Remove-UiModeKey {
    param($Ui, [string]$Key)

    # Every map the window keys by mode. A new one added above and forgotten here is exactly the
    # ghost setting this function exists to prevent, which is why they are listed in one loop
    # rather than in five lines somebody can add a sixth beside.
    foreach ($map in @($Ui.Hotkeys, $Ui.Levels, $Ui.Contrast, $Ui.Picture, $Ui.Hdr, $Ui.Audio, $Ui.Hooks)) {
        if ($map -and $map.Contains($Key)) { $map.Remove($Key) }
    }
    # Not a map, but keyed by mode all the same: a rule pointing at a mode that no longer exists
    # would head for it on every hotplug and be answered with "combination no longer exists".
    if ([string]$Ui.OnPlugKey -eq $Key) { $Ui.OnPlugKey = '' }

    # The rules the same way, and by the rule Move-RuleModeKeys used to apply at Save time. An
    # empty "go back to" is legitimate — it means "wherever the desk was" — but a rule with
    # nowhere to go is no longer a rule at all.
    foreach ($rule in @($Ui.Rules)) {
        if ([string]$rule['back'] -eq $Key) {
            $rule['back'] = ''
            Write-DisplayLog "settings dialog: cleared the way back of a rule for removed $Key"
        }
    }
    foreach ($rule in @(@($Ui.Rules) | Where-Object { [string]$_['mode'] -eq $Key })) {
        Write-DisplayLog "settings dialog: dropped a rule whose mode $Key was removed"
        $Ui.Rules.Remove($rule)
    }
}

# A rename: everything under the old key MOVES to the new one. Not "remove, and let the editor
# write back what it carries" — that was the first version, and it silently ate any setting the
# caller's answer happened not to mention. A property missing from an edit means "not touched"
# everywhere else in this window, and a rename must not be the one place where it means "throw
# it away".
#
# A value already sitting on the new key stays: it is its own, and it owes its place to nobody
# who is moving. Move-ModeKeyedEntries settles the same question the same way.
function Move-UiModeKey {
    param($Ui, [string]$From, [string]$To)

    if (-not $From -or -not $To -or $From -eq $To) { return }
    foreach ($map in @($Ui.Hotkeys, $Ui.Levels, $Ui.Contrast, $Ui.Picture, $Ui.Hdr, $Ui.Audio, $Ui.Hooks)) {
        if (-not $map -or -not $map.Contains($From)) { continue }
        $value = $map[$From]
        $map.Remove($From)
        if (-not $map.Contains($To)) { $map[$To] = $value }
    }
    if ([string]$Ui.OnPlugKey -eq $From) { $Ui.OnPlugKey = $To }
    foreach ($rule in @($Ui.Rules)) {
        if ([string]$rule['mode'] -eq $From) { $rule['mode'] = $To }
        if ([string]$rule['back'] -eq $From) { $rule['back'] = $To }
    }
}

# Apply the editor's answer to the window's working state. Separate from the click handlers:
# this is the testable part of an edit, and the handlers only call the editor and pass its
# answer along to here.
function Set-UiMode {
    param($Ui, $Mode, $Combo, $Edited)

    if (-not $Edited) { return }

    # The key the mode sat under before the edit: for a combo it changes along with the name,
    # and everything tied to it has to move.
    $oldKey = $(if ($Mode) { [string]$Mode.Key } else { '' })
    $newKey = $oldKey

    if ($null -ne $Edited.PSObject.Properties['Name']) {
        if ($Combo) {
            $Combo.Name = [string]$Edited.Name
            $Combo.Patterns = @($Edited.Patterns)
            $Combo.Primary = [string]$Edited.Primary
        }
        else {
            [void]$Ui.Combos.Add([pscustomobject]@{
                Name     = [string]$Edited.Name
                Patterns = @($Edited.Patterns)
                Primary  = [string]$Edited.Primary
            })
        }
        $newKey = 'combo:' + [string]$Edited.Name
        # A name that was deleted in this same session came back — the deletion is cancelled.
        $Ui.DeletedComboKeys = @($Ui.DeletedComboKeys | Where-Object { $_ -ne $newKey })
    }

    # A rename carries everything the window keys by mode over to the new key: under the old one
    # a ghost setting would be left that shows up in no window. All five maps travel together,
    # and they travel WHOLE — what the edit below does not mention keeps the value it had.
    if ($oldKey -and $newKey -and $oldKey -ne $newKey) {
        Move-UiModeKey -Ui $Ui -From $oldKey -To $newKey
    }

    # What the editor showed is what we save — the empty included. An empty shortcut honestly
    # means "there is no shortcut": the person could well have cleared it. That is exactly why
    # the editor is shown the settings left under this key from the name's earlier life (see
    # Sync-EditorInheritance): otherwise an empty field would erase something the person never
    # saw.
    if ($newKey) {
        if ($null -ne $Edited.PSObject.Properties['Hotkey']) {
            $parsed = ConvertFrom-HotkeyString ([string]$Edited.Hotkey)
            if ($parsed) { $Ui.Hotkeys[$newKey] = $parsed.Text }
            elseif ($Ui.Hotkeys.Contains($newKey)) { $Ui.Hotkeys.Remove($newKey) }
        }
        # A model with no level is not a setting: a key holding one must not be in the map (see
        # ConvertTo-LevelModels).
        if ($null -ne $Edited.PSObject.Properties['Level']) {
            if ($null -ne (ConvertFrom-LevelModel $Edited.Level)) { $Ui.Levels[$newKey] = $Edited.Level }
            elseif ($Ui.Levels.Contains($newKey)) { $Ui.Levels.Remove($newKey) }
        }
        if ($null -ne $Edited.PSObject.Properties['Contrast']) {
            if ($null -ne (ConvertFrom-LevelModel $Edited.Contrast)) { $Ui.Contrast[$newKey] = $Edited.Contrast }
            elseif ($Ui.Contrast.Contains($newKey)) { $Ui.Contrast.Remove($newKey) }
        }
        if ($null -ne $Edited.PSObject.Properties['Picture']) {
            if ($Edited.Picture -and @($Edited.Picture.Keys).Count -gt 0) { $Ui.Picture[$newKey] = $Edited.Picture }
            elseif ($Ui.Picture.Contains($newKey)) { $Ui.Picture.Remove($newKey) }
        }
        if ($null -ne $Edited.PSObject.Properties['Hdr']) {
            if ($Edited.Hdr -and @($Edited.Hdr.Keys).Count -gt 0) { $Ui.Hdr[$newKey] = $Edited.Hdr }
            elseif ($Ui.Hdr.Contains($newKey)) { $Ui.Hdr.Remove($newKey) }
        }
        # An empty device is not a setting either: the switch would look for a device called
        # nothing and write a warning into the log every time.
        if ($null -ne $Edited.PSObject.Properties['Audio']) {
            $device = ([string]$Edited.Audio).Trim()
            if ($device) { $Ui.Audio[$newKey] = $device }
            elseif ($Ui.Audio.Contains($newKey)) { $Ui.Audio.Remove($newKey) }
        }
        # $null from Read-ModeFromUi means both boxes were empty (see ConvertTo-HookSetting).
        if ($null -ne $Edited.PSObject.Properties['Hook']) {
            if ($Edited.Hook) { $Ui.Hooks[$newKey] = $Edited.Hook }
            elseif ($Ui.Hooks.Contains($newKey)) { $Ui.Hooks.Remove($newKey) }
        }
    }

    Update-ModesPanel -Ui $Ui
}

function Remove-UiCombo {
    param($Ui, $Combo)

    # The combo's PRESENT name and nothing else. It used to clear the name it had in the file as
    # well, from the days when audio and commands were carried straight out of the file at Save
    # time and so still sat under the old key. Move-UiModeKey empties that key the moment the
    # rename happens now, so the second key clears nothing of this combo's — and can belong to
    # somebody else: rename "Work" to "Gaming", make a new combo called "Work", delete "Gaming",
    # and the new one lost its shortcut, its levels, its preset, its audio, its commands and
    # every rule that pointed at it, while staying in the list looking untouched.
    $key = 'combo:' + $Combo.Name
    $Ui.DeletedComboKeys = @($Ui.DeletedComboKeys) + $key
    $Ui.Combos.Remove($Combo)
    Remove-UiModeKey -Ui $Ui -Key $key
    Update-ModesPanel -Ui $Ui
}

# Clear away everything left of a mode that no longer exists: the monitor was taken away, the
# combo was wiped out of the file by hand. The shortcut is claimed globally after all, and it
# can only be cleared from here — which is why such a row has a button of its own.
function Remove-UiOrphan {
    param($Ui, [string]$Key)

    Remove-UiModeKey -Ui $Ui -Key $Key
    Update-ModesPanel -Ui $Ui
}

# A combo's working record by mode key. A combo's name IS its key without the prefix, and
# Get-ModeTitleFromKey is what parses keys — one place for the whole codebase, and the width of
# the prefix is not nailed down across four files.
function Get-UiCombo {
    param($Ui, [string]$Key)

    if ($Key -notlike 'combo:*') { return $null }
    $name = Get-ModeTitleFromKey $Key
    return @($Ui.Combos | Where-Object { $_.Name -eq $name } | Select-Object -First 1)[0]
}

# The mode editor: built separately from being shown, for the same reason as the main window —
# a window built without being shown can be tested.
# The editor's heading, and which part of it is visible at all. It depends only on the kind of
# mode: a combo is assembled by a person, so it has a name and a membership; a monitor mode and
# "all" are set by the desk, and only the shortcut and the brightness are edited on them —
# there is nothing to argue about regarding a name or members, so that part of the window hides.
function Set-ModeEditorHeader {
    param($Window, [string]$Kind, $Mode, $Combo)

    $headTitle = $Window.FindName('HeadTitle')
    $headHint = $Window.FindName('HeadHint')

    if ($Kind -eq 'combo') {
        # The name and the membership are edited below, in fields of their own: all the heading
        # has left to say is what this thing even is. For a combo that already exists there is
        # nothing left to explain — the hint goes, and the window gets a line shorter.
        $headTitle.Text = $(if ($Combo) { Get-Text -Key 'editor.combo' } else { Get-Text -Key 'editor.newCombo' })
        if ($Combo) { $headHint.Visibility = 'Collapsed' }
        else {
            $headHint.Text = Get-Text -Key 'editor.comboHint'
        }
    }
    else {
        $Window.FindName('ComboPart').Visibility = 'Collapsed'
        $headTitle.Text = $(if ($Mode) { [string]$Mode.Title } else { Get-Text -Key 'editor.mode' })
        $headHint.Text = $(if ($Kind -eq 'all') { Get-Text -Key 'editor.allHint' }
                           else { Get-Text -Key 'editor.soloHint' })
    }

    $Window.Title = 'DeskModes - ' + $headTitle.Text
}

# A combo's membership: the members' checkboxes and the "whose taskbar" dropdown. Returns the
# list of checkboxes — Read-ModeFromUi reads them, and the Tag of each holds the exact string
# that will leave for settings.json.
#
# The checkboxes are every display the desk knows of — the ones that are off at their own button
# included, marked as such — and then the combo's patterns that matched none of them: the monitor
# was taken away, but throwing it out of the combo silently is not allowed.
#
# A monitor that is not there is offered rather than hidden, because a combo is most often built
# for the desk you are about to have and not for the one in front of you. It cannot be switched
# on this moment, and a mode that names it says so where it is switched from.
function Add-ComboMemberChecks {
    param($Window, $Combo, $Displays)

    $membersPanel = $Window.FindName('MembersPanel')
    $primaryBox = $Window.FindName('PrimaryBox')

    $patterns = @()
    if ($Combo) {
        $Window.FindName('NameBox').Text = [string]$Combo.Name
        $patterns = @($Combo.Patterns)
    }

    $checks = @()
    $notConnected = '   (' + (Get-Text -Key 'display.notConnected') + ')'
    foreach ($m in $Displays) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $Window.FindResource('Check')
        # The same wording a pattern with no monitor behind it gets below, and the same one the
        # tray menu and the mode list use: one phrase for one fact.
        $displayTitle = Get-DisplayTitle -Label ([string]$m.Label)
        $cb.Content = $(if ($m.Disconnected) { $displayTitle + $notConnected } else { $displayTitle })
        $cb.Tag = [string]$m.Label
        foreach ($pat in $patterns) {
            if (Test-DisplayNameMatch -Pattern $pat -Label $m.Label -ShortId $m.ShortId) { $cb.IsChecked = $true; break }
        }
        [void]$membersPanel.Children.Add($cb)
        $checks += $cb
    }
    foreach ($pat in $patterns) {
        $matched = $false
        foreach ($m in $Displays) {
            if (Test-DisplayNameMatch -Pattern $pat -Label $m.Label -ShortId $m.ShortId) { $matched = $true; break }
        }
        if ($matched) { continue }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $Window.FindResource('Check')
        $cb.Content = ([string]$pat + $notConnected)
        $cb.Tag = [string]$pat
        $cb.IsChecked = $true
        [void]$membersPanel.Children.Add($cb)
        $checks += $cb
    }

    [void]$primaryBox.Items.Add((Get-Text -Key 'editor.usualRules'))
    foreach ($cb in $checks) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = [string]$cb.Content
        $item.Tag = [string]$cb.Tag
        # Tag identifies the visible member for checkbox validation; DataContext is the selector
        # that settings.json keeps. They differ when a supported ShortId selected this display.
        $item.DataContext = [string]$cb.Tag
        [void]$primaryBox.Items.Add($item)
    }
    $primaryBox.SelectedIndex = 0
    if ($Combo -and $Combo.Primary) {
        foreach ($item in @($primaryBox.Items | Select-Object -Skip 1)) {
            $shortId = ''
            foreach ($display in $Displays) {
                if ([string]$display.Label -eq [string]$item.Tag) {
                    $shortId = [string]$display.ShortId
                    break
                }
            }
            if (Test-DisplayNameMatch -Pattern ([string]$Combo.Primary) -Label ([string]$item.Tag) -ShortId $shortId) {
                $item.DataContext = [string]$Combo.Primary
                $primaryBox.SelectedItem = $item
                break
            }
        }
    }

    return $checks
}

# The key of the mode the editor is editing RIGHT NOW. For a combo it is assembled from the
# name in the field rather than taken from the input: the name IS the key, which is why
# "create a combo called Movie" and "rename a combo to Movie" lead to one and the same key
# `combo:Movie` — with everything that sits under it.
function Get-EditorModeKey {
    param($Editor)

    if ($Editor.Kind -ne 'combo') { return [string]$Editor.ModeKey }
    $name = $Editor.NameBox.Text.Trim()
    if (-not $name) { return '' }
    return 'combo:' + $name
}

# The brightness model in the shape it will leave for the file, as a string, so that two
# models can be compared. Empty means "brightness is not set".
function Get-LevelFingerprint {
    param($Model)

    $value = ConvertFrom-LevelModel $Model
    if ($null -eq $value) { return '' }
    return (ConvertTo-Json $value -Compress -Depth 4)
}

# The settings left under the typed name go into the editor's fields.
#
# A combo can be wiped out of the file by hand while its key, brightness, audio and commands
# are left behind: they sit under the key `combo:<name>`, and the window shows them as an
# orphan row. Creating a combo with the same name means claiming that very key: the audio
# and the commands go to it in any case (Read-SettingsFromUi carries those, and the key is
# only known there at Save time). So the shortcut and the brightness have to go to it too —
# and they have to be VISIBLE, or empty fields would silently erase two settings out of
# four, and the person would never learn they had inherited the other two.
#
# We fill in only an empty field, or over something we filled in ourselves: what is theirs a
# person edits by hand, and overwriting their edit with the typed name is not allowed.
function Sync-EditorInheritance {
    param($Editor)

    $key = Get-EditorModeKey -Editor $Editor
    if ($key -eq $Editor.ShownKey) { return }
    $Editor.ShownKey = $key

    $inherited = ConvertFrom-HotkeyString $(if ($key -and $Editor.Hotkeys.Contains($key)) { [string]$Editor.Hotkeys[$key] } else { '' })
    $shown = ConvertFrom-HotkeyString $Editor.HotkeyBox.Text
    if (-not $shown -or ($Editor.AutoHotkey -and $shown.Text -eq $Editor.AutoHotkey)) {
        $Editor.AutoHotkey = $(if ($inherited) { $inherited.Text } else { '' })
        $Editor.HotkeyBox.Text = $(if ($inherited) { $inherited.Text } else { (Get-NoHotkeyText) })
    }

    # Brightness and contrast by the same rule, from the map each card was built with.
    foreach ($group in @($Editor.Brightness, $Editor.Contrast)) {
        $inherited = $(if ($key -and $group.Source.Contains($key)) { $group.Source[$key] } else { $null })
        $shown = Get-LevelFingerprint $group.Model
        if ($shown -and $shown -ne $group.Auto) { continue }
        $group.Model = Copy-LevelModel $inherited
        $group.Auto = Get-LevelFingerprint $group.Model
        Update-LevelGroup -Group $group
    }

    $device = [string]$(if ($key -and $Editor.Audio.Contains($key)) { $Editor.Audio[$key] } else { '' })
    $shownDevice = ([string]$Editor.AudioBox.Text).Trim()
    if (-not $shownDevice -or $shownDevice -eq $Editor.AutoAudio) {
        $Editor.AutoAudio = $device
        $Editor.AudioBox.Text = $device
    }

    # The two command boxes move as one pair: a name that carries a "before" and an "after"
    # cannot hand over half of itself.
    $hook = $(if ($key -and $Editor.Hooks.Contains($key)) { $Editor.Hooks[$key] } else { $null })
    $before = [string]$(if ($hook) { $hook.before } else { '' })
    $after  = [string]$(if ($hook) { $hook.after }  else { '' })
    $shownHook = Get-HookFingerprint -Before $Editor.HookBeforeBox.Text -After $Editor.HookAfterBox.Text
    if (-not $shownHook -or $shownHook -eq $Editor.AutoHook) {
        $Editor.HookBeforeBox.Text = $before
        $Editor.HookAfterBox.Text = $after
        $Editor.AutoHook = Get-HookFingerprint -Before $before -After $after
    }

    # The presets by the same rule as the rest. Left out, they were the one map a typed name
    # could not inherit — and Get-PictureForSave hands back its card WHOLE on Save, so an empty
    # card is read as "the person forgot them all" and the key's presets went.
    $preset = $(if ($key -and $Editor.PictureSource.Contains($key)) { $Editor.PictureSource[$key] } else { $null })
    $shownPicture = Get-PictureFingerprint -Map $Editor.Picture
    if (-not $shownPicture -or $shownPicture -eq $Editor.AutoPicture) {
        # A copy, as on the way in: the window's map is not the editor's to change until Save.
        $Editor.Picture = [ordered]@{}
        if ($preset) {
            foreach ($name in @($preset.Keys)) { $Editor.Picture[[string]$name] = [string]$preset[$name] }
        }
        $Editor.AutoPicture = Get-PictureFingerprint -Map $Editor.Picture
        Update-PicturePanel -Editor $Editor
    }

    # And HDR, by the same rule and for the same reason.
    $hdr = $(if ($key -and $Editor.HdrSource.Contains($key)) { $Editor.HdrSource[$key] } else { $null })
    $shownHdr = Get-HdrFingerprint -Map $Editor.Hdr
    if (-not $shownHdr -or $shownHdr -eq $Editor.AutoHdr) {
        $Editor.Hdr = ConvertTo-HdrMap -Setting $hdr -Names (Get-EditorPictureNames -Editor $Editor)
        $Editor.AutoHdr = Get-HdrFingerprint -Map $Editor.Hdr
        Update-HdrPanel -Editor $Editor
    }

    # Typing a name can inherit a brightness, a device or a command from the key that name owns.
    # Inheriting one out of sight would be worse than not inheriting it at all: the fields below
    # are read on Save, and an empty one erases.
    Update-EditorDisclosure -Editor $Editor
}

# --- the monitor's picture preset -------------------------------------------
# One row per display of the mode: what is remembered for it, and the buttons to remember, update
# or forget. There is no list of presets and no name of one anywhere here, and that is the whole
# design: the numbers are the vendor's, and on this desk one monitor calls two different numbers
# "Gamer 1" while they look nothing alike (probed 2026-09-03). So the question a person answers is
# not "which preset" but "the way it looks right now".

# A whole card of presets as one string, so two of them can be compared - the twin of
# Get-LevelFingerprint and Get-HookFingerprint, and empty means "nothing is remembered here".
# Sorted, because the order the rows were pressed in is not part of the answer.
function Get-PictureFingerprint {
    param($Map)

    if (-not $Map -or $Map.Count -eq 0) { return '' }
    return (@(@($Map.Keys) | Sort-Object | ForEach-Object { [string]$_ + '=' + [string]$Map[$_] }) -join "`t")
}

# What the row says, given what is remembered for that display.
function Get-PictureRowText {
    param([string]$Setting)

    $one = ConvertFrom-PictureSetting $Setting
    if (-not $one) { return (Get-Text -Key 'picture.notRemembered') }
    return (Get-Text -Key 'picture.remembered')
}

# Rebuilt whenever the model changes: the rows are three states of one thing, and rebuilding is
# shorter than keeping three of them in step.
function Update-PicturePanel {
    param($Editor)

    $panel = $Editor.PicturePanel
    if (-not $panel) { return }
    $panel.Children.Clear()
    $win = $Editor.Window

    $names = @(Get-EditorPictureNames -Editor $Editor)
    if ($names.Count -eq 0) {
        # Only a combo is ticked; the rest take their displays from the desk, and telling their
        # owner to tick something would send them looking for a control that is not there.
        $empty = $(if ($Editor.Kind -eq 'combo') { Get-Text -Key 'editor.tickFirst' }
                   else { Get-Text -Key 'picture.noDisplay' })
        [void]$panel.Children.Add((New-UiTextBlock -Text $empty -Style 'RowSub' -Window $win))
        return
    }

    foreach ($name in $names) {
        # By match and not by the name alone: the key may be a piece of it (see Get-PictureKeyFor).
        $key = Get-PictureKeyFor -Editor $Editor -Name $name
        $setting = [string]$(if ($key) { $Editor.Picture[$key] } else { '' })

        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
        foreach ($width in @((New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)),
                             [System.Windows.GridLength]::Auto)) {
            $column = New-Object System.Windows.Controls.ColumnDefinition
            $column.Width = $width
            [void]$row.ColumnDefinitions.Add($column)
        }

        $text = New-Object System.Windows.Controls.StackPanel
        $text.VerticalAlignment = 'Center'
        $text.Margin = New-Object System.Windows.Thickness 0, 0, 12, 0
        [void]$text.Children.Add((New-UiTextBlock -Text (Get-DisplayTitle -Label $name) -Style 'RowTitle' -Window $win))
        $state = New-UiTextBlock -Text (Get-PictureRowText -Setting $setting) -Style 'RowSub' -Window $win
        # The number itself is on hover and in settings.json, never in the row: a person who has
        # never opened a monitor's menu has no use for "0x15:45", and one who edits the file by
        # hand needs to see exactly that.
        if ($setting) { $state.ToolTip = $setting }
        [void]$text.Children.Add($state)
        [void]$row.Children.Add($text)

        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = 'Horizontal'
        $buttons.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($buttons, 1)

        $remember = New-Object System.Windows.Controls.Button
        $remember.Style = $win.FindResource('BtnSmall')
        $remember.Content = $(if ($setting) { Get-Text -Key 'picture.update' } else { Get-Text -Key 'picture.remember' })
        # Which display a button answers for is on the button itself: this window's handlers hold
        # no closures (see the note about .GetNewClosure() above).
        $remember.Tag = $name
        $remember.add_Click({
            $ed = $script:ActiveEditor
            if ($ed) { Read-PictureForDisplay -Editor $ed -Display ([string]$this.Tag) }
        })
        [void]$buttons.Children.Add($remember)

        if ($setting) {
            $forget = New-Object System.Windows.Controls.Button
            $forget.Style = $win.FindResource('BtnSmall')
            $forget.Content = Get-Text -Key 'picture.forget'
            $forget.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
            # The KEY the row was drawn from, not the display's name: forgetting has to take away
            # the entry that is actually there, which for a hand-written one is a piece of a name.
            $forget.Tag = $key
            $forget.add_Click({
                $ed = $script:ActiveEditor
                if (-not $ed) { return }
                $key = [string]$this.Tag
                if ($ed.Picture.Contains($key)) { $ed.Picture.Remove($key) }
                Set-UiNote -Block $ed.PictureNote -Text ''
                Update-PicturePanel -Editor $ed
            })
            [void]$buttons.Children.Add($forget)
        }

        [void]$row.Children.Add($buttons)
        [void]$panel.Children.Add($row)
    }
}

# --- HDR in the editor ------------------------------------------------------
# One row per display of the mode, a dropdown of three answers: leave alone, on, off. Nothing to ask
# the monitor - this is Windows' switch - so the row has no button, only the choice.

# A function and not a constant, for the reason Get-NoHotkeyText is one: a $script: array is
# filled at dot-source time, before the settings have said what language this is.
function Get-HdrChoices {
    return @((Get-Text -Key 'hdr.leaveAlone'), (Get-Text -Key 'hdr.on'), (Get-Text -Key 'hdr.off'))
}

function Get-HdrFingerprint {
    param($Map)

    if (-not $Map -or $Map.Count -eq 0) { return '' }
    return (@(@($Map.Keys) | ForEach-Object { [string]$_ + '=' + [string][bool]$Map[$_] }) -join '|')
}

# The entry that answers for a display: its whole name, or a piece of one written by hand.
function Get-HdrKeyFor {
    param($Editor, [string]$Name)

    if (-not $Name -or -not $Editor.Hdr) { return '' }
    if ($Editor.Hdr.Contains($Name)) { return [string]$Name }
    $shortId = Get-EditorDisplayShortId -Editor $Editor -Name $Name
    foreach ($key in @($Editor.Hdr.Keys)) {
        if (Test-DisplayNameMatch -Pattern ([string]$key) -Label $Name -ShortId $shortId) { return [string]$key }
    }
    return ''
}

# What leaves the editor: the displays the mode still has, under the key each was found by - the
# same courtesy Get-PictureForSave pays a hand-written piece of a name.
function Get-HdrForSave {
    param($Editor)

    $out = [ordered]@{}
    foreach ($name in @(Get-EditorPictureNames -Editor $Editor)) {
        $key = Get-HdrKeyFor -Editor $Editor -Name $name
        if ($key) { $out[$key] = [bool]$Editor.Hdr[$key] }
    }
    return $out
}

function Update-HdrPanel {
    param($Editor)

    $panel = $Editor.HdrPanel
    if (-not $panel) { return }
    $panel.Children.Clear()
    $win = $Editor.Window

    $names = @(Get-EditorPictureNames -Editor $Editor)
    if ($names.Count -eq 0) {
        $empty = $(if ($Editor.Kind -eq 'combo') { Get-Text -Key 'editor.tickFirst' }
                   else { Get-Text -Key 'hdr.noDisplay' })
        [void]$panel.Children.Add((New-UiTextBlock -Text $empty -Style 'RowSub' -Window $win))
        return
    }

    $Editor.HdrBusy = $true
    try {
        foreach ($name in $names) {
            $key = Get-HdrKeyFor -Editor $Editor -Name $name
            $row = New-Object System.Windows.Controls.Grid
            $row.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
            foreach ($width in @((New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)),
                                 [System.Windows.GridLength]::Auto)) {
                $column = New-Object System.Windows.Controls.ColumnDefinition
                $column.Width = $width
                [void]$row.ColumnDefinitions.Add($column)
            }
            $title = New-UiTextBlock -Text (Get-DisplayTitle -Label $name) -Style 'RowTitle' -Window $win
            $title.VerticalAlignment = 'Center'
            $title.Margin = New-Object System.Windows.Thickness 0, 0, 12, 0
            [void]$row.Children.Add($title)

            $box = New-Object System.Windows.Controls.ComboBox
            $box.Style = $win.FindResource('Select')
            $box.Width = 150
            $box.Height = 30
            foreach ($choice in (Get-HdrChoices)) { [void]$box.Items.Add($choice) }
            $box.SelectedIndex = $(if (-not $key) { 0 } elseif ([bool]$Editor.Hdr[$key]) { 1 } else { 2 })
            # The display's name rides on the box: the handler holds no closure (see the note about
            # .GetNewClosure() above) and finds the editor in $script:ActiveEditor.
            $box.Tag = $name
            $box.add_SelectionChanged({
                $ed = $script:ActiveEditor
                if (-not $ed -or $ed.HdrBusy) { return }
                $name = [string]$this.Tag
                $key = Get-HdrKeyFor -Editor $ed -Name $name
                switch ($this.SelectedIndex) {
                    0 { if ($key) { $ed.Hdr.Remove($key) } }
                    1 { $ed.Hdr[$(if ($key) { $key } else { $name })] = $true }
                    2 { $ed.Hdr[$(if ($key) { $key } else { $name })] = $false }
                }
            })
            [System.Windows.Controls.Grid]::SetColumn($box, 1)
            [void]$row.Children.Add($box)
            [void]$panel.Children.Add($row)
        }
    }
    finally { $Editor.HdrBusy = $false }
}

# The button's whole job: ask that monitor what it is holding right now and write it down. A
# monitor that is asleep or has DDC/CI switched off in its menu answers nothing, and then nothing
# is written down - guessing a preset would be worse than saying so.
function Read-PictureForDisplay {
    param($Editor, [string]$Display)

    $device = ''
    foreach ($m in @($Editor.State)) {
        if (-not $m -or $m.Disconnected -or -not $m.Active) { continue }
        if ([string]$m.Label -eq $Display) { $device = [string]$m.Output; break }
    }
    if (-not $device) {
        Set-UiNote -Block $Editor.PictureNote -Text (Get-Text -Key 'picture.notOnDesk' -Values @($Display))
        return
    }

    $found = $null
    foreach ($one in @(Get-MonitorPictures)) {
        if ([string]$one.Device -eq $device -and $one.Answered) { $found = $one; break }
    }
    if (-not $found) {
        Set-UiNote -Block $Editor.PictureNote -Text (Get-Text -Key 'picture.noAnswer' -Values @($Display))
        return
    }

    # Under the display's whole name, and whatever this row was reading before goes: an entry
    # written by hand as a piece of a name stands for this same display (see Get-PictureKeyFor),
    # and leaving it would put two presets in the map where the row shows one - with only
    # Get-PictureKeyFor's order deciding which of them the switch would find.
    $old = Get-PictureKeyFor -Editor $Editor -Name $Display
    if ($old -and $old -ne $Display) { $Editor.Picture.Remove($old) }
    $Editor.Picture[$Display] = Format-PictureSetting -Code ([int]$found.Code) -Value ([int]$found.Value)
    Set-UiNote -Block $Editor.PictureNote -Text (Get-Text -Key 'picture.done' -Values @($Display))
    Update-PicturePanel -Editor $Editor
}

function New-ModeEditorWindow {
    param(
        # The mode being edited. $null — we are creating a new combo.
        $Mode,
        # The combo's working record from the window's list. $null — the mode is not a combo,
        # or the combo has not been created yet.
        $Combo,
        $State,
        # Everything the window keys by mode, as whole "mode key -> value" maps. Not ready
        # values: a combo's key follows the name in the field, and while the name is being typed
        # the editor has to find both what will go to this name and what to count as somebody
        # else's shortcut. The levels are edited as a COPY: Cancel has to leave the window with
        # what was there.
        $Hotkeys,
        $Levels,
        $Contrast,
        $Picture,
        $Hdr,
        $Audio,
        $Hooks,
        [string[]]$TakenNames = @(),
        $Owner,
        [bool]$Dark,
        # What a NEW combination opens on (New-DeskTemplate). Read for the ticks and the taskbar
        # only; the heading still says "New combination", and Save still adds to the list.
        $Template = $null
    )

    Initialize-WpfRuntime
    Set-DisplayIdentity -State $State

    $palette = Get-UiPalette -Dark $Dark
    $win = Convert-UiXaml -Xaml $script:ModeEditorXaml -Palette $palette
    Register-WindowTheme -Window $win -Dark $Dark
    if ($Owner) { $win.Owner = $Owner }

    # The window does not grow past the work area — beyond that it scrolls, as the main one does.
    # The owner's monitor, not the primary one: the editor opens centred on the owner, and on a
    # desk of three monitors those work areas are of different heights.
    try { $win.MaxHeight = (Get-WorkAreaHeight -Window $Owner) - 80 } catch { }   # no work area — no limit then
    # This is the window the disclosure doubles in height: it must not grow off the screen.
    $win.add_SizeChanged({ Move-WindowIntoWorkArea -Window $this })

    # The kind of mode decides what the window shows. A new record is always a combo: monitor
    # modes and "all" are created by the desk, not by a person.
    $kind = 'combo'
    if ($Mode -and [string]$Mode.Kind -and [string]$Mode.Kind -ne 'combo') { $kind = [string]$Mode.Kind }

    $nameBox = $win.FindName('NameBox')
    $primaryBox = $win.FindName('PrimaryBox')
    $hotkeyBox = $win.FindName('HotkeyBox')
    $okBtn = $win.FindName('OkBtn')

    Set-ModeEditorHeader -Window $win -Kind $kind -Mode $Mode -Combo $Combo

    # The key the mode sits under on the way in. A new combo does not have one yet — it will
    # come from the name that gets typed into the field.
    $key = $(if ($Mode) { [string]$Mode.Key } else { '' })
    if (-not $Hotkeys)  { $Hotkeys  = [ordered]@{} }
    if (-not $Levels)   { $Levels   = [ordered]@{} }
    if (-not $Contrast) { $Contrast = [ordered]@{} }
    if (-not $Picture)  { $Picture  = [ordered]@{} }
    if (-not $Hdr)      { $Hdr      = [ordered]@{} }
    if (-not $Audio)    { $Audio    = [ordered]@{} }
    if (-not $Hooks)    { $Hooks    = [ordered]@{} }
    $hotkeyText = $(if ($key -and $Hotkeys.Contains($key)) { [string]$Hotkeys[$key] } else { '' })
    $level = $(if ($key -and $Levels.Contains($key)) { $Levels[$key] } else { $null })
    $contrastLevel = $(if ($key -and $Contrast.Contains($key)) { $Contrast[$key] } else { $null })
    $hook = $(if ($key -and $Hooks.Contains($key)) { $Hooks[$key] } else { $null })

    $hotkeyBox.Cursor = [System.Windows.Input.Cursors]::Hand
    Register-HotkeyCapture -Box $hotkeyBox
    $parsedHotkey = ConvertFrom-HotkeyString $hotkeyText
    $hotkeyBox.Text = $(if ($parsedHotkey) { $parsedHotkey.Text } else { (Get-NoHotkeyText) })

    $clearHotkey = $win.FindName('ClearHotkeyBtn')
    $clearHotkey.IsEnabled = [bool]$parsedHotkey
    Register-HotkeyClearButton -Box $hotkeyBox -Button $clearHotkey

    $checks = @()
    if ($kind -eq 'combo') {
        $checks = @(Add-ComboMemberChecks -Window $win -Combo $(if ($Combo) { $Combo } else { $Template }) `
                        -Displays @($State | Where-Object { $_ }))
    }

    $ed = [pscustomobject]@{
        Window         = $win
        Kind           = $kind
        # The mode itself, not just its key: a mode's membership is asked of Get-ModeMembers,
        # and it cannot be reconstructed from the key.
        Mode           = $Mode
        ModeKey        = $key
        NameBox        = $nameBox
        Checks         = $checks
        PrimaryBox     = $primaryBox
        HotkeyBox      = $hotkeyBox
        LevelTestBtn   = $win.FindName('LevelTestBtn')
        LevelNote      = $win.FindName('LevelNote')
        AudioBox       = $win.FindName('AudioBox')
        HookBeforeBox  = $win.FindName('HookBeforeBox')
        HookAfterBox   = $win.FindName('HookAfterBox')
        MoreBtn        = $win.FindName('MoreBtn')
        MorePanel      = $win.FindName('MorePanel')
        # Whether the fold is open, and whether the PERSON is the one who last said so (see
        # Update-EditorDisclosure).
        MoreOpen       = $false
        MoreTouched    = $false
        # The two level cards. Filled in below: a card needs the editor it belongs to, and the
        # editor is only an object once this literal is closed.
        Brightness     = $null
        Contrast       = $null
        # A COPY of what this mode has remembered, display -> "register:number". Cancel has to
        # leave the window with what was there.
        Picture        = [ordered]@{}
        # And the whole map it is inherited from while the name is being typed, the way the level
        # cards keep their Source.
        PictureSource  = $Picture
        PicturePanel   = $win.FindName('PicturePanel')
        PictureNote    = $win.FindName('PictureNote')
        # HDR the same way as the presets: a copy per display, the whole map it is inherited from,
        # and a panel of one row per display. Busy while the rows are being rebuilt, so that setting
        # a dropdown from code does not count as a person's choice.
        Hdr            = [ordered]@{}
        HdrSource      = $Hdr
        HdrPanel       = $win.FindName('HdrPanel')
        HdrBusy        = $false
        # Whether the device list has already been fetched. It is fetched on the first opening
        # of the dropdown and never on building the window: enumerating the endpoints goes to
        # COM, and the tests build editors headless.
        AudioListed    = $false
        State          = @($State)
        TakenNames     = @($TakenNames)
        Hotkeys        = $Hotkeys
        Audio          = $Audio
        Hooks          = $Hooks
        # Whose key is in the fields right now, and what we filled into them ourselves: we do
        # not overwrite a person's edit with a name (see Sync-EditorInheritance).
        ShownKey       = $key
        AutoHotkey     = ''
        AutoAudio      = ''
        AutoHook       = ''
        AutoPicture    = ''
        AutoHdr        = ''
        Result         = $null
    }
    # The handlers find the editor here rather than in a closure: see the comment about
    # handlers above. The editor is modal, so one place is enough.
    $script:ActiveEditor = $ed

    $ed.Brightness = New-LevelGroup -Editor $ed -Prefix 'Level' -Noun (Get-Text -Key 'noun.brightness') `
                                    -Source $Levels -Model $level
    $ed.Contrast   = New-LevelGroup -Editor $ed -Prefix 'Contrast' -Noun (Get-Text -Key 'noun.contrast') `
                                    -Source $Contrast -Model $contrastLevel
    Initialize-LevelGroup -Group $ed.Brightness
    Initialize-LevelGroup -Group $ed.Contrast

    # A copy, not the map itself: Cancel has to leave the window with what was there.
    if ($key -and $Picture.Contains($key)) {
        foreach ($name in @($Picture[$key].Keys)) { $ed.Picture[[string]$name] = [string]$Picture[$key][$name] }
    }
    Update-PicturePanel -Editor $ed

    if ($key -and $Hdr.Contains($key)) {
        $ed.Hdr = ConvertTo-HdrMap -Setting $Hdr[$key] -Names (Get-EditorPictureNames -Editor $ed)
    }
    Update-HdrPanel -Editor $ed

    $ed.AudioBox.Text = [string]$(if ($key -and $Audio.Contains($key)) { $Audio[$key] } else { '' })
    $ed.HookBeforeBox.Text = [string]$(if ($hook) { $hook.before } else { '' })
    $ed.HookAfterBox.Text  = [string]$(if ($hook) { $hook.after }  else { '' })

    $ed.AudioBox.add_DropDownOpened({
        $ed = $script:ActiveEditor
        if ($ed) { Add-AudioDeviceItems -Editor $ed }
    })

    # Shut unless this mode already has something behind it to show.
    Set-EditorMoreVisible -Editor $ed -Open $false
    Update-EditorDisclosure -Editor $ed

    $ed.MoreBtn.add_Click({
        $ed = $script:ActiveEditor
        if (-not $ed) { return }
        # The person has an opinion about the fold now, and it outranks ours from here on.
        $ed.MoreTouched = $true
        $ed.MoreOpen = -not $ed.MoreOpen
        Set-EditorMoreVisible -Editor $ed -Open $ed.MoreOpen
    })

    # The name is watched rather than asked for on OK: the name is the mode key, and whose
    # settings the editor shows and what it counts as a foreign shortcut both depend on it.
    $nameBox.add_TextChanged({
        $ed = $script:ActiveEditor
        if (-not $ed) { return }
        Sync-EditorInheritance -Editor $ed
    })

    $ed.LevelTestBtn.add_Click({
        $ed = $script:ActiveEditor
        if (-not $ed) { return }
        Invoke-LevelProbe -Editor $ed
    })

    # A monitor was taken off the combo — its rows follow, without waiting for Save: otherwise a
    # slider would stand under a monitor the mode no longer has. Both cards, or the contrast
    # rows would keep a monitor the brightness rows have already let go of.
    foreach ($cb in $checks) {
        $cb.add_Click({
            $ed = $script:ActiveEditor
            if (-not $ed) { return }
            foreach ($group in @($ed.Brightness, $ed.Contrast)) {
                if ($group.Busy) { continue }
                if ([string]$group.Model.Kind -eq 'each') { Update-LevelGroup -Group $group }
            }
            # The preset rows are one per display too. What was remembered for a display that has
            # just been unticked is KEPT in the model until Save: ticking it back must not have
            # cost the person the preset they learnt.
            Update-PicturePanel -Editor $ed
            Update-HdrPanel -Editor $ed
        })
    }

    $okBtn.add_Click({
        $ed = $script:ActiveEditor
        if (-not $ed) { return }
        $got = Read-ModeFromUi -Editor $ed
        if (-not $got.Ok) {
            [void][System.Windows.MessageBox]::Show($ed.Window, $got.Problem, 'DeskModes',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
        $ed.Result = $got.Mode
        $ed.Window.DialogResult = $true
    })

    return $ed
}

# What a person typed into the editor, with validation. A function of its own — as
# Read-SettingsFromUi is for the main window: testable without showing the window.
function Read-ModeFromUi {
    param($Editor)

    # The field can hold "no shortcut" or the hint "needs Ctrl…" — only what parses counts as
    # a shortcut. Empty means no shortcut.
    $hk = ''
    $parsed = ConvertFrom-HotkeyString $Editor.HotkeyBox.Text
    if ($parsed) { $hk = $parsed.Text }

    # A foreign shortcut is one that sits on ANOTHER key. What makes a key ours is the name in
    # the field (see Get-EditorModeKey): otherwise a combo named after an orphan row would
    # argue with itself over the shortcut — and the person would be shown a mode they cannot
    # see and cannot open.
    if ($hk) {
        $selfKey = Get-EditorModeKey -Editor $Editor
        foreach ($key in @($Editor.Hotkeys.Keys)) {
            # During a rename both keys are ours: the destination names the result, while ModeKey
            # still owns every setting shown in the editor until Set-UiMode moves them together.
            if ([string]$key -eq $selfKey -or [string]$key -eq [string]$Editor.ModeKey) { continue }
            $other = ConvertFrom-HotkeyString ([string]$Editor.Hotkeys[$key])
            if (-not $other -or $other.Text -ne $hk) { continue }
            return [pscustomobject]@{
                Ok = $false; Mode = $null
                Problem = Get-Text -Key 'editor.hotkeyTaken' -Values @($hk, (Get-ModeTitleFromKey ([string]$key)))
            }
        }
    }

    # Everything the editor owns that is not the combo's own name and membership. Handed back
    # for BOTH kinds of mode and always, even untouched: a property that is present but empty
    # means "cleared", and one that is absent means "not edited" (see Set-UiMode). Leaving a
    # field out when a person emptied it would make clearing a setting impossible.
    $device = ([string]$Editor.AudioBox.Text).Trim()
    $hook = ConvertTo-HookSetting ([ordered]@{
        before = ([string]$Editor.HookBeforeBox.Text).Trim()
        after  = ([string]$Editor.HookAfterBox.Text).Trim()
    })

    # For a monitor mode and for "all" the membership is set by the desk: only the settings
    # above are edited, and there is nothing more to check.
    if ($Editor.Kind -ne 'combo') {
        return [pscustomobject]@{
            Ok = $true
            Mode = [pscustomobject]@{
                Hotkey = $hk; Level = $Editor.Brightness.Model
                Contrast = $Editor.Contrast.Model; Picture = (Get-PictureForSave -Editor $Editor)
                Hdr = (Get-HdrForSave -Editor $Editor)
                Audio = $device; Hook = $hook
            }
            Problem = ''
        }
    }

    $name = $Editor.NameBox.Text.Trim()
    $chosen = @($Editor.Checks | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    $prim = ''
    $primMember = ''
    if ($Editor.PrimaryBox.SelectedIndex -gt 0) {
        $primMember = [string]$Editor.PrimaryBox.SelectedItem.Tag
        $prim = [string]$Editor.PrimaryBox.SelectedItem.DataContext
        if (-not $prim) { $prim = $primMember }
    }

    $problem = ''
    if (-not $name) { $problem = Get-Text -Key 'editor.needName' }
    elseif (@($Editor.TakenNames | Where-Object { $_ -and $_ -ieq $name }).Count -gt 0) {
        $problem = Get-Text -Key 'editor.nameTaken' -Values @($name)
    }
    elseif ($chosen.Count -eq 0) { $problem = Get-Text -Key 'editor.needDisplay' }
    elseif ($primMember -and $chosen -notcontains $primMember) {
        $problem = Get-Text -Key 'editor.taskbarMember'
    }
    if ($problem) { return [pscustomobject]@{ Ok = $false; Mode = $null; Problem = $problem } }

    return [pscustomobject]@{
        Ok = $true
        Mode = [pscustomobject]@{
            Name = $name; Patterns = $chosen; Primary = $prim
            Hotkey = $hk; Level = $Editor.Brightness.Model
            Contrast = $Editor.Contrast.Model; Picture = (Get-PictureForSave -Editor $Editor)
            Hdr = (Get-HdrForSave -Editor $Editor)
            Audio = $device; Hook = $hook
        }
        Problem = ''
    }
}

# What leaves the editor: only the displays the mode still has - the rows that were shown, in
# other words, and nothing that was not. A preset remembered for a display and then unticked stays
# in the window while it is open (ticking it back is free) and goes no further than that -
# settings.json must not collect presets for displays no mode uses.
#
# "Has" and not "has switched on right now": Get-EditorPictureNames counts a monitor that is
# unplugged or asleep, or opening the editor of a mode whose display is off would erase the very
# preset it was opened to look at.
#
# The entry is found by Get-PictureKeyFor and goes out UNDER THE KEY IT WAS FOUND BY: a preset
# written by hand as a piece of a name is that person's way of writing it, and rewriting it to
# the whole label on the way past would be an edit nobody asked for - besides being the thing
# that used to erase it.
function Get-PictureForSave {
    param($Editor)

    $out = [ordered]@{}
    foreach ($name in @(Get-EditorPictureNames -Editor $Editor)) {
        $key = Get-PictureKeyFor -Editor $Editor -Name $name
        if ($key) { $out[$key] = [string]$Editor.Picture[$key] }
    }
    return $out
}

# Showing the editor. Returns the mode's edit, or $null on cancel.
function Show-ModeEditor {
    param(
        $Mode,
        $Combo,
        $State,
        $Hotkeys,
        $Levels,
        $Contrast,
        $Picture,
        $Hdr,
        $Audio,
        $Hooks,
        [string[]]$TakenNames = @(),
        $Owner,
        [bool]$Dark,
        $Template = $null
    )

    $ed = New-ModeEditorWindow -Mode $Mode -Combo $Combo -State $State `
                               -Hotkeys $Hotkeys -Levels $Levels -Contrast $Contrast `
                               -Picture $Picture -Hdr $Hdr -Audio $Audio -Hooks $Hooks -TakenNames $TakenNames `
                               -Owner $Owner -Dark $Dark -Template $Template
    try {
        if ($ed.Window.ShowDialog()) { return $ed.Result }
        return $null
    }
    finally {
        $ed.Window.Close()
        $script:ActiveEditor = $null
    }
}

# Gather everything the editor needs from the window, show it and apply the answer. One place
# for both "Add a combination" and every Edit row: the rules about taken names and shortcuts
# have to be the same for every mode.
function Invoke-ModeEditor {
    param($Ui, $Mode, $Combo, $Template = $null)

    # Everything keyed by mode is handed over as whole maps: the editor finds its own record by
    # key itself, and that key changes along with the name while the window is open.
    $taken = @($Ui.Combos | Where-Object { -not $Combo -or $_ -ne $Combo } | ForEach-Object { [string]$_.Name })

    $made = Show-ModeEditor -Mode $Mode -Combo $Combo -State $Ui.State `
                            -Hotkeys $Ui.Hotkeys -Levels $Ui.Levels -Contrast $Ui.Contrast `
                            -Picture $Ui.Picture -Hdr $Ui.Hdr -Audio $Ui.Audio -Hooks $Ui.Hooks -TakenNames $taken `
                            -Owner $Ui.Window -Dark $Ui.Dark -Template $Template
    if ($made) { Set-UiMode -Ui $Ui -Mode $Mode -Combo $Combo -Edited $made }
}

# --- the mode list ----------------------------------------------------------
# Rebuilt on every edit: the modes are derived from the desk and from the combo list, and the
# rows have to show what will be there after Save. The shortcut and the brightness live not
# in the rows but in $Ui.Hotkeys and $Ui.Levels: a row only shows them, the editor edits them.

# The short truth about a mode's brightness goes into the row's caption. Otherwise a setting
# hidden behind an Edit button is invisible until every mode has been opened in turn.
function Get-LevelSummary {
    param($Model, [string]$Noun = '')

    if (-not $Model) { return '' }
    if (-not $Noun) { $Noun = Get-Text -Key 'noun.brightness' }
    switch ([string]$Model.Kind) {
        'one'  { return (Get-Text -Key 'summary.level' -Values @($Noun, [int]$Model.Value)) }
        'each' {
            if (-not $Model.Map -or $Model.Map.Count -eq 0) { return '' }
            return (Get-Text -Key 'summary.levelEach' -Values @($Noun))
        }
    }
    return ''
}

# The whole caption of a mode's row: what the mode is, then one short word per setting hidden
# behind its Edit button. One word each and no more — the row must not wrap, and the list is as
# long as the desk has modes.
function Get-ModeRowSubtitle {
    param($Ui, $Mode)

    $key = [string]$Mode.Key
    $parts = @(Get-ModeSubtitle -Mode $Mode)
    if ($Ui.Levels.Contains($key))   { $parts += Get-LevelSummary -Model $Ui.Levels[$key]   -Noun (Get-Text -Key 'noun.brightness') }
    if ($Ui.Contrast.Contains($key)) { $parts += Get-LevelSummary -Model $Ui.Contrast[$key] -Noun (Get-Text -Key 'noun.contrast') }
    if ($Ui.Picture.Contains($key)) {
        # "picture" and not "picture preset": this caption is the one thing on the row that gets
        # trimmed, and the word "preset" is eight characters saying what the section it comes
        # from is called.
        $count = @($Ui.Picture[$key].Keys).Count
        $parts += $(if ($count -eq 1) { Get-Text -Key 'summary.picture' }
                    else { Get-PluralText -Key 'summary.pictureOn' -Count $count })
    }
    # The device's name is not printed: it is long enough to push the row into a second line,
    # and the row's job is to say that the setting is there at all.
    if ($Ui.Hdr.Contains($key))      { $parts += (Get-Text -Key 'summary.hdr') }
    if ($Ui.Audio.Contains($key))    { $parts += (Get-Text -Key 'summary.audio') }
    if ($Ui.Hooks.Contains($key))    { $parts += (Get-Text -Key 'summary.hook') }
    return (@($parts | Where-Object { $_ }) -join $script:UiDot)
}

# Entries tied to modes, in the order of the modes themselves. What does not match that order
# (a setting from a mode that no longer exists) follows behind, in the order it was in. A
# pure function.
function Get-MapInModeOrder {
    param($Map, $Modes)

    $sorted = [ordered]@{}
    if (-not $Map) { return $sorted }
    foreach ($mode in @($Modes)) {
        $key = [string]$mode.Key
        if ($Map.Contains($key) -and -not $sorted.Contains($key)) { $sorted[$key] = $Map[$key] }
    }
    foreach ($key in @($Map.Keys)) {
        if (-not $sorted.Contains([string]$key)) { $sorted[[string]$key] = $Map[$key] }
    }
    return $sorted
}

# Which rows to show in the mode list — and in what order. It draws nothing: it works out the
# list and lays the window's entries out along it.
#
# $InitialModes arrives with the first call from New-SettingsWindow (the modes have already
# been worked out outside, together with the orphan rows); $null means a recount after edits,
# and then the combos are taken from the window's working list rather than from the settings
# the window was opened with.
function Resolve-PanelModes {
    param($Ui, $InitialModes)

    $modes = $InitialModes
    if ($null -eq $modes) {
        $settings = @{ combos = (ConvertTo-ComboSettings -Combos $Ui.Combos) }
        $modes = @(Get-DisplayModes -State $Ui.State -Settings $settings)
    }
    $modes = @($modes)

    # A setting with no mode gets a row of its own. The shortcut is claimed globally
    # (RegisterHotKey works whether a monitor is there or not), and the rest hang on a key that
    # no longer exists; all of them can only be seen and cleared from here. The window's maps
    # hold only real settings (see ConvertTo-LevelModels and Import-ModeExtras), so any
    # unfamiliar key here is a row. Every map is asked, or a hand-written audio entry for a
    # monitor that has left would get no row and could never be cleared.
    $known = @($modes | ForEach-Object { [string]$_.Key })
    $strays = @()
    foreach ($key in @(@($Ui.Hotkeys.Keys) + @($Ui.Levels.Keys) + @($Ui.Contrast.Keys) +
                       @($Ui.Picture.Keys) + @($Ui.Hdr.Keys) + @($Ui.Audio.Keys) + @($Ui.Hooks.Keys))) {
        $key = [string]$key
        if (-not $key -or $known -contains $key -or $strays -contains $key) { continue }
        $strays += $key
    }
    foreach ($key in $strays) {
        $modes += [pscustomobject]@{
            Key       = $key
            Title     = Get-ModeTitleFromKey $key
            Kind      = 'orphan'
            Available = $false
        }
    }

    # The entries are lined up in the order of the modes: otherwise settings.json would get
    # reshuffled by the order in which a person happened to open the editors, and every edit of
    # one shortcut would rewrite half the file.
    $Ui.Hotkeys  = Get-MapInModeOrder -Map $Ui.Hotkeys  -Modes $modes
    $Ui.Levels   = Get-MapInModeOrder -Map $Ui.Levels   -Modes $modes
    $Ui.Contrast = Get-MapInModeOrder -Map $Ui.Contrast -Modes $modes
    $Ui.Picture  = Get-MapInModeOrder -Map $Ui.Picture  -Modes $modes
    $Ui.Hdr      = Get-MapInModeOrder -Map $Ui.Hdr      -Modes $modes
    $Ui.Audio    = Get-MapInModeOrder -Map $Ui.Audio    -Modes $modes
    $Ui.Hooks    = Get-MapInModeOrder -Map $Ui.Hooks    -Modes $modes

    return @($modes)
}

function Update-ModesPanel {
    param(
        $Ui,
        # The first call from New-SettingsWindow: the modes have already been worked out outside
        # (together with the orphan rows), and the shortcuts come from the settings.
        $InitialModes,
        $InitialHotkeys
    )

    $win = $Ui.Window

    if ($InitialHotkeys) {
        $Ui.Hotkeys = [ordered]@{}
        foreach ($key in @($InitialHotkeys.Keys)) {
            # Not a mode's key: it has a field of its own on the Behavior page, and in this map it
            # would become an orphan row called "back" (see Resolve-PanelModes).
            if ([string]$key -eq $script:BackHotkeyName) { continue }
            $text = [string]$InitialHotkeys[$key]
            if ($text) { $Ui.Hotkeys[[string]$key] = $text }
        }
    }

    $modes = @(Resolve-PanelModes -Ui $Ui -InitialModes $InitialModes)

    $Ui.ModesPanel.Children.Clear()

    foreach ($mode in $modes) {
        $key = [string]$mode.Key
        $row = New-Object System.Windows.Controls.Grid
        # Two points, not four: the list is as long as the desk has modes, and every point here
        # is paid six times over. The rows are still told apart by their two lines of text.
        $row.Margin = New-Object System.Windows.Thickness 0, 2, 0, 2
        # One height for every row, whether it has one line of text or two. A display's mode has
        # no caption by design (Get-ModeSubtitle) and a combination always has one, so without
        # this the shortcut and the buttons stepped up and down the list from row to row.
        $row.MinHeight = 40
        # Four columns: the caption, the shortcut, Remove, Edit. Edit LAST and Remove before it,
        # which is the whole fix for buttons that used to move: Edit is on every row, Remove only
        # on a combination and an orphan, so with Edit in the third column its place depended on
        # whether the fourth was occupied - it sat 72 points further right on a display's mode
        # than on the combination under it. As the last column its right edge is the row's right
        # edge, and it is in the same place on every row of the list.
        foreach ($width in @((New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)),
                             [System.Windows.GridLength]::Auto,
                             [System.Windows.GridLength]::Auto,
                             [System.Windows.GridLength]::Auto)) {
            $column = New-Object System.Windows.Controls.ColumnDefinition
            $column.Width = $width
            [void]$row.ColumnDefinitions.Add($column)
        }

        $textStack = New-Object System.Windows.Controls.StackPanel
        $textStack.VerticalAlignment = 'Center'
        # 8 and not 12 either side of the shortcut: the caption is the column that gets trimmed,
        # and eight points of gutter is enough to keep two columns apart.
        $textStack.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
        $title = New-UiTextBlock -Text $mode.Title -Style 'RowTitle' -Window $win
        if (-not $mode.Available -and $mode.Kind -ne 'orphan') {
            $title.Text = [string]$mode.Title + '   (' + (Get-Text -Key 'display.notConnected') + ')'
            $title.Foreground = $win.FindResource('DimBrush')
        }
        if ($mode.Kind -eq 'orphan') { $title.Foreground = $win.FindResource('DimBrush') }
        [void]$textStack.Children.Add($title)

        $subText = Get-ModeRowSubtitle -Ui $Ui -Mode $mode
        if ($subText) {
            $sub = New-UiTextBlock -Text $subText -Style 'RowSub' -Window $win
            # One line, cut with an ellipsis rather than wrapped. RowSub wraps everywhere else,
            # and here it must not: this list is as long as the desk has modes, and a caption
            # that grew a second line took the whole window past the work area into a scrollbar
            # it did not need. What is cut is the tail of a summary — the full truth is one
            # click away behind Edit, and the tooltip carries it meanwhile.
            $sub.TextWrapping = 'NoWrap'
            $sub.TextTrimming = 'CharacterEllipsis'
            $sub.ToolTip = $subText
            [void]$textStack.Children.Add($sub)
        }
        [void]$row.Children.Add($textStack)

        # The shortcut as a label rather than a field: it is edited in the same place as
        # everything else about the mode. Its space is always taken, otherwise the buttons would
        # jump along the row from one binding to the next.
        $shortcut = [string]$(if ($Ui.Hotkeys.Contains($key)) { $Ui.Hotkeys[$key] } else { '' })
        $keyText = New-UiTextBlock -Text $(if ($shortcut) { $shortcut } else { (Get-NoHotkeyText) }) `
                                   -Style 'RowSub' -Window $win
        # 96 is what the longest combination anybody binds ("Ctrl+Shift+F12") needs; the field it
        # replaced reserved 110.
        $keyText.MinWidth = 96
        $keyText.TextAlignment = 'Right'
        $keyText.VerticalAlignment = 'Center'
        $keyText.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
        if ($shortcut) { $keyText.Foreground = $win.FindResource('TextBrush') }
        [System.Windows.Controls.Grid]::SetColumn($keyText, 1)
        [void]$row.Children.Add($keyText)

        # Buttons with a border, specifically, not dimmed labels: the very first person took the
        # flat Edit/Remove for captions and could not find how to delete a combo.
        if ($mode.Kind -ne 'orphan') {
            $edit = New-Object System.Windows.Controls.Button
            $edit.Content = Get-Text -Key 'common.edit'
            $edit.Style = $win.FindResource('BtnSmall')
            $edit.VerticalAlignment = 'Center'
            # Which mode a button answers for is on the button itself: this window's handlers
            # hold no closures (see the comment above).
            $edit.Tag = $mode
            # The last column, so it stands in the same place on every row (see above).
            [System.Windows.Controls.Grid]::SetColumn($edit, 3)
            [void]$row.Children.Add($edit)
            $edit.add_Click({
                $ui = $script:ActiveUi
                $mode = $this.Tag
                if (-not $ui -or -not $mode) { return }
                Invoke-ModeEditor -Ui $ui -Mode $mode -Combo (Get-UiCombo -Ui $ui -Key ([string]$mode.Key))
            })
        }

        # What can be removed is what a person created themselves, and what is left as nothing
        # but a key. A monitor mode and "all" are not deletable: they exist as long as the desk does.
        if ($mode.Kind -eq 'combo' -or $mode.Kind -eq 'orphan') {
            $remove = New-Object System.Windows.Controls.Button
            $remove.Content = Get-Text -Key 'common.remove'
            $remove.Style = $win.FindResource('BtnSmall')
            $remove.VerticalAlignment = 'Center'
            # To the LEFT of Edit, in the column before it: an absent Remove then costs its own
            # place and nobody else's, which is why Edit no longer moves between rows. Destructive
            # away from the edge is the better place for it anyway.
            $remove.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
            $remove.Tag = $mode
            [System.Windows.Controls.Grid]::SetColumn($remove, 2)
            [void]$row.Children.Add($remove)
            $remove.add_Click({
                $ui = $script:ActiveUi
                $mode = $this.Tag
                if (-not $ui -or -not $mode) { return }
                if ([string]$mode.Kind -eq 'orphan') {
                    Remove-UiOrphan -Ui $ui -Key ([string]$mode.Key)
                    return
                }
                $combo = Get-UiCombo -Ui $ui -Key ([string]$mode.Key)
                if ($combo) { Remove-UiCombo -Ui $ui -Combo $combo }
            })
        }

        [void]$Ui.ModesPanel.Children.Add($row)
    }

    # Everything else that names a mode is rebuilt here too: this is the one function every
    # rename, addition and deletion goes through, and a dropdown or a rule row still showing
    # yesterday's name is how a person picks a mode that no longer exists.
    $Ui.Modes = @($modes)
    Update-PlugModeBox -Ui $Ui -Modes $modes
    Update-RulesPanel -Ui $Ui
}

# The "switch to" dropdown: "(do nothing)" and then every mode, by title. The mode KEY rides on
# each item's Tag — a title is what a person reads and is not unique enough to save.
#
# A key that matches no mode gets an item of its own rather than being dropped: the mode may
# belong to a monitor that is unplugged right now, and silently clearing a setting because its
# display is asleep is how a person loses a choice they never cancelled.
function Update-PlugModeBox {
    param($Ui, $Modes)

    $box = $Ui.PlugModeBox
    if (-not $box) { return }

    $Ui.PlugBusy = $true
    try {
        $box.Items.Clear()
        $none = New-Object System.Windows.Controls.ComboBoxItem
        $none.Content = Get-Text -Key 'behavior.onPlug.nothing'
        $none.Tag = ''
        [void]$box.Items.Add($none)

        $want = [string]$Ui.OnPlugKey
        $found = $false
        foreach ($mode in @($Modes)) {
            if ([string]$mode.Kind -eq 'orphan') { continue }
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = [string]$mode.Title
            $item.Tag = [string]$mode.Key
            [void]$box.Items.Add($item)
            if ($want -and [string]$mode.Key -eq $want) { $box.SelectedItem = $item; $found = $true }
        }

        if ($want -and -not $found) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = (Get-ModeTitleFromKey $want)
            $item.Tag = $want
            $item.Foreground = $Ui.Window.FindResource('DimBrush')
            [void]$box.Items.Add($item)
            $box.SelectedItem = $item
        }
        if (-not $want) { $box.SelectedIndex = 0 }
    }
    finally { $Ui.PlugBusy = $false }
}

# --- rules ------------------------------------------------------------------
# "When this happens, become that." The deciding is in DisplayCore (Get-RuleDecision, a pure
# function under tests); this is only the editing of the list.
#
# The rules live in the window as an ArrayList of the very shape ConvertTo-RuleSettings hands
# back, so what a person edits here and what the tray reads every fifteen seconds are one thing
# rather than two that have to be kept in step.

# A function and not a constant, for the reason Get-HdrChoices is one.
function Get-RuleWhenTitles {
    return [ordered]@{
        process  = (Get-Text -Key 'rule.when.process')
        idle     = (Get-Text -Key 'rule.when.idle')
        displays = (Get-Text -Key 'rule.when.displays')
    }
}

function Import-RuleSettings {
    param($Ui, $Settings)

    $Ui.Rules = New-Object System.Collections.ArrayList
    $raw = $(if ($Settings) { $Settings.rules } else { @() })
    foreach ($rule in @(ConvertTo-RuleSettings $raw)) { [void]$Ui.Rules.Add($rule) }
}

# What a rule's row says: the condition, then where it takes the desk. Both in the words the
# rest of the window uses — a mode is named, never keyed, or the list reads like the file.
function Get-RuleRowTitle {
    param($Rule)

    $mode = [string]$Rule['mode']
    $where = $(if ($mode) { Get-ModeTitleFromKey $mode } else { Get-Text -Key 'rule.nowhere' })
    # Get-RuleReasonText and not Format-RuleReason: that one is the log's phrasing and stays English.
    return (Get-RuleReasonText -Rule $Rule) + $script:UiArrow + $where
}

# And the second line: where it puts the desk back. Empty means "wherever it was", which is the
# common case and needs no line of its own.
function Get-RuleRowSubtitle {
    param($Rule)

    $back = [string]$Rule['back']
    if (-not $back) { return '' }
    return Get-Text -Key 'rule.backTo' -Values @((Get-ModeTitleFromKey $back))
}

function Update-RulesPanel {
    param($Ui)

    $win = $Ui.Window
    if (-not $Ui.RulesPanel) { return }
    $Ui.RulesPanel.Children.Clear()

    if (@($Ui.Rules).Count -eq 0) {
        # An empty list has to SAY it is empty: a blank space above a button reads like something
        # that failed to load.
        $none = New-UiTextBlock -Text (Get-Text -Key 'rules.empty') `
                                -Style 'RowSub' -Window $win
        $none.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
        [void]$Ui.RulesPanel.Children.Add($none)
        return
    }

    foreach ($rule in @($Ui.Rules)) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = New-Object System.Windows.Thickness 0, 2, 0, 2
        # The same height and the same four columns as a row of the mode list, in the same order
        # - the caption, the switch, Remove, Edit. Every rule has both buttons, so nothing moves
        # here whichever way round they go; they go this way round because the two lists stand
        # one page apart and a person reaches for Edit in one place, not two.
        $row.MinHeight = 40
        foreach ($width in @((New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)),
                             [System.Windows.GridLength]::Auto,
                             [System.Windows.GridLength]::Auto,
                             [System.Windows.GridLength]::Auto)) {
            $column = New-Object System.Windows.Controls.ColumnDefinition
            $column.Width = $width
            [void]$row.ColumnDefinitions.Add($column)
        }

        $textStack = New-Object System.Windows.Controls.StackPanel
        $textStack.VerticalAlignment = 'Center'
        $textStack.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
        $title = New-UiTextBlock -Text (Get-RuleRowTitle -Rule $rule) -Style 'RowTitle' -Window $win
        # A rule that is switched off is still a rule, and it has to look switched off: without
        # this the list gives no hint why the desk is not moving.
        if (-not $rule['enabled']) { $title.Foreground = $win.FindResource('DimBrush') }
        [void]$textStack.Children.Add($title)
        $subText = Get-RuleRowSubtitle -Rule $rule
        if ($subText) {
            $sub = New-UiTextBlock -Text $subText -Style 'RowSub' -Window $win
            $sub.TextWrapping = 'NoWrap'
            $sub.TextTrimming = 'CharacterEllipsis'
            [void]$textStack.Children.Add($sub)
        }
        [void]$row.Children.Add($textStack)

        # The rule itself rides on every control, never its place in the list: the list is
        # rebuilt on each edit, and an index would point at whoever slid into that slot. The
        # tray settles the same question the same way, by signature rather than by index.
        $toggle = New-Object System.Windows.Controls.CheckBox
        $toggle.Style = $win.FindResource('Toggle')
        $toggle.VerticalAlignment = 'Center'
        $toggle.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
        $toggle.IsChecked = [bool]$rule['enabled']
        $toggle.Tag = $rule
        [System.Windows.Controls.Grid]::SetColumn($toggle, 1)
        [void]$row.Children.Add($toggle)
        $toggle.add_Click({
            $ui = $script:ActiveUi
            $rule = $this.Tag
            if (-not $ui -or -not $rule) { return }
            $rule['enabled'] = [bool]$this.IsChecked
            Update-RulesPanel -Ui $ui
        })

        $edit = New-Object System.Windows.Controls.Button
        $edit.Content = Get-Text -Key 'common.edit'
        $edit.Style = $win.FindResource('BtnSmall')
        $edit.VerticalAlignment = 'Center'
        $edit.Tag = $rule
        [System.Windows.Controls.Grid]::SetColumn($edit, 3)
        [void]$row.Children.Add($edit)
        $edit.add_Click({
            $ui = $script:ActiveUi
            $rule = $this.Tag
            if (-not $ui -or -not $rule) { return }
            Invoke-RuleEditor -Ui $ui -Rule $rule
        })

        $remove = New-Object System.Windows.Controls.Button
        $remove.Content = Get-Text -Key 'common.remove'
        $remove.Style = $win.FindResource('BtnSmall')
        $remove.VerticalAlignment = 'Center'
        $remove.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
        $remove.Tag = $rule
        [System.Windows.Controls.Grid]::SetColumn($remove, 2)
        [void]$row.Children.Add($remove)
        $remove.add_Click({
            $ui = $script:ActiveUi
            $rule = $this.Tag
            if (-not $ui -or -not $rule) { return }
            $ui.Rules.Remove($rule)
            Update-RulesPanel -Ui $ui
        })

        [void]$Ui.RulesPanel.Children.Add($row)
    }
}

# The modes a rule may point at: the real ones, never an orphan row. An orphan is a key nobody
# can switch to, and offering it would let a person build a rule that fails every time it fires.
function Get-RuleTargetModes {
    param($Ui)

    return @(@($Ui.Modes) | Where-Object { $_ -and [string]$_.Kind -ne 'orphan' })
}

# Fill one of the editor's mode dropdowns. $Empty is the wording of the first item when an empty
# choice is allowed ("Go back to" permits one; "Switch to" does not).
#
# A key with no mode behind it gets a dimmed item of its own rather than being dropped: the mode
# may belong to a monitor that is unplugged right now, and a rule silently losing its target
# because a cable is out is a rule that quietly stops working.
#
# A mode that exists and cannot be switched to this second says so and stays CHOOSABLE, which is
# the difference between this dropdown and the tray menu. A rule fires later, by definition: the
# display it is written for is usually the one that is off while it is being written.
function Set-RuleModeItems {
    param($Box, $Modes, [string]$Selected, [string]$Empty = '')

    $Box.Items.Clear()
    if ($Empty) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $Empty
        $item.Tag = ''
        [void]$Box.Items.Add($item)
    }

    $found = $false
    foreach ($mode in @($Modes)) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = [string]$mode.Title + $(if ($mode.Available) { '' } else { '   ' + (Get-Text -Key 'menu.notConnected') })
        $item.Tag = [string]$mode.Key
        [void]$Box.Items.Add($item)
        if ($Selected -and [string]$mode.Key -eq $Selected) { $Box.SelectedItem = $item; $found = $true }
    }

    if ($Selected -and -not $found) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = (Get-ModeTitleFromKey $Selected) + '   ' + (Get-Text -Key 'menu.notConnected')
        $item.Tag = $Selected
        [void]$Box.Items.Add($item)
        $Box.SelectedItem = $item
    }
    if (-not $Selected -and $Box.Items.Count -gt 0) { $Box.SelectedIndex = 0 }
}

# What to offer for "watch for this program", gathered when the list is first opened and never
# while the window is being built: Get-Process walks every process on the machine, and the tests
# build this editor by the dozen.
#
# Two sources, because either one alone is wrong. What is running right now is what a person is
# most likely to mean — but only what has a window of its own, or the list is forty services
# nobody has heard of. And a rule is usually written for a game that is NOT running while you
# write it, which is what the diary is for: it remembers what has been in front of you all month.
#
# Stored without .exe, which is the form a rule keeps; matching strips it either way, so a name
# typed by hand with the extension goes on working.
function Add-ProcessItems {
    param($Editor)

    if ($Editor.ProcessListed) { return }
    $Editor.ProcessListed = $true

    # A hashtable, so a program that is both running and in the diary is offered once. Its keys
    # ignore case, which is what tells "Chrome" and "chrome" apart from two different programs.
    $names = @{}
    try {
        foreach ($p in @(Get-Process -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 })) {
            $name = ([string]$p.ProcessName) -replace '\.exe$', ''
            if ($name) { $names[$name] = $true }
        }
    }
    catch { Write-DisplayLog "settings dialog: could not list the running programs - $($_.Exception.Message)" }

    try {
        foreach ($row in @((Get-ActivityReport -Store (Get-ActivityStore) -Days 30).Apps)) {
            $name = (([string]$row.Name) -replace '\.exe$', '').Trim()
            if ($name) { $names[$name] = $true }
        }
    }
    catch { Write-DisplayLog "settings dialog: could not read the diary for program names - $($_.Exception.Message)" }

    foreach ($name in @($names.Keys | Sort-Object)) { [void]$Editor.ProcessBox.Items.Add($name) }
}

# The rule editor, built separately from being shown — for the same reason as every other window
# here: a window built without being shown can be tested.
function New-RuleEditorWindow {
    # $Displays is the desk with the remembered monitors in it (Get-DeskDisplays): the ticks for the
    # "these displays are connected" condition. Empty, and that condition offers no ticks - the tests
    # that do not care hand nothing in.
    param($Rule, $Modes, $Owner, [bool]$Dark, $Displays = @())

    Initialize-WpfRuntime
    $palette = Get-UiPalette -Dark $Dark
    $win = Convert-UiXaml -Xaml $script:RuleEditorXaml -Palette $palette
    Register-WindowTheme -Window $win -Dark $Dark
    if ($Owner) { $win.Owner = $Owner }
    # The owner's monitor, for the same reason as in the mode editor.
    try { $win.MaxHeight = (Get-WorkAreaHeight -Window $Owner) - 80 } catch { }   # no work area — no limit then
    $win.add_SizeChanged({ Move-WindowIntoWorkArea -Window $this })

    # A new rule starts on the shape everything downstream expects, not on an empty bag: then
    # there is one shape of a rule in this file and not two.
    if (-not $Rule) {
        $Rule = [ordered]@{ when = 'process'; process = ''; minutes = 20; displays = @(); mode = ''; back = ''; enabled = $true }
    }

    $ed = [pscustomobject]@{
        Window       = $win
        WhenBox      = $win.FindName('WhenBox')
        ProcessPanel = $win.FindName('ProcessPanel')
        ProcessBox   = $win.FindName('ProcessBox')
        IdlePanel    = $win.FindName('IdlePanel')
        MinutesBox   = $win.FindName('MinutesBox')
        DisplaysPanel = $win.FindName('DisplaysPanel')
        # One CheckBox per display of the desk, Tag = the name the rule stores.
        DisplayChecks = @()
        ModeBox      = $win.FindName('ModeBox')
        BackBox      = $win.FindName('BackBox')
        # The rule being edited, so Save can write into the very entry the list holds rather than
        # hand back a copy the caller has to find a place for.
        Rule         = $Rule
        Busy         = $false
        Result       = $null
        # The programs are gathered when the list is first opened, never while the window is
        # being built — same as the playback devices in the mode editor.
        ProcessListed = $false
    }
    $script:ActiveRuleUi = $ed

    $ed.Busy = $true
    try {
        $whenTitles = Get-RuleWhenTitles
        foreach ($when in @($whenTitles.Keys)) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = [string]$whenTitles[$when]
            $item.Tag = [string]$when
            [void]$ed.WhenBox.Items.Add($item)
            if ([string]$Rule['when'] -eq $when) { $ed.WhenBox.SelectedItem = $item }
        }
        if (-not $ed.WhenBox.SelectedItem) { $ed.WhenBox.SelectedIndex = 0 }

        $ed.ProcessBox.Text = [string]$Rule['process']
        $minutes = [int]$Rule['minutes']
        $ed.MinutesBox.Text = [string]$(if ($minutes -gt 0) { $minutes } else { 20 })
        $ed.DisplayChecks = @(Add-RuleDisplayChecks -Window $win -Patterns @($Rule['displays']) -Displays @($Displays))

        Set-RuleModeItems -Box $ed.ModeBox -Modes $Modes -Selected ([string]$Rule['mode'])
        Set-RuleModeItems -Box $ed.BackBox -Modes $Modes -Selected ([string]$Rule['back']) `
                          -Empty (Get-Text -Key 'rule.whereverWas')
    }
    finally { $ed.Busy = $false }

    Update-RuleEditorPanels -Editor $ed

    $ed.WhenBox.add_SelectionChanged({
        $ed = $script:ActiveRuleUi
        if (-not $ed -or $ed.Busy) { return }
        Update-RuleEditorPanels -Editor $ed
    })

    $ed.ProcessBox.add_DropDownOpened({
        $ed = $script:ActiveRuleUi
        if ($ed) { Add-ProcessItems -Editor $ed }
    })

    $win.FindName('OkBtn').add_Click({
        $ed = $script:ActiveRuleUi
        if (-not $ed) { return }
        $got = Read-RuleFromUi -Editor $ed
        if (-not $got.Ok) {
            [void][System.Windows.MessageBox]::Show($ed.Window, $got.Problem, 'DeskModes',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
        $ed.Result = $got.Rule
        $ed.Window.DialogResult = $true
    })

    return $ed
}

# Which question the condition asks. Both panels exist all along and only one is up: swapping
# visibility keeps what was typed in the other, so trying it both ways round costs no retyping.
function Update-RuleEditorPanels {
    param($Editor)

    $when = Get-RuleEditorWhen -Editor $Editor
    $Editor.ProcessPanel.Visibility  = $(if ($when -eq 'process')  { 'Visible' } else { 'Collapsed' })
    $Editor.IdlePanel.Visibility     = $(if ($when -eq 'idle')     { 'Visible' } else { 'Collapsed' })
    $Editor.DisplaysPanel.Visibility = $(if ($when -eq 'displays') { 'Visible' } else { 'Collapsed' })
}

# The ticks for the displays condition: one per display of the desk, in the desk's order, ticked where
# the rule names it. A name the rule holds that matches no display of the desk gets a tick of its own,
# already on - the same courtesy a combo's members get (Add-ComboMemberChecks): the monitor may be one
# this machine has not seen for months, and losing it from the rule on an unrelated edit is not ours.
function Add-RuleDisplayChecks {
    param($Window, $Patterns, $Displays)

    $panel = $Window.FindName('DisplaysChecks')
    $checks = @()
    $patterns = @(@($Patterns) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $notConnected = '   (' + (Get-Text -Key 'display.notConnected') + ')'

    foreach ($m in @($Displays | Where-Object { $_ })) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $Window.FindResource('Check')
        $displayTitle = Get-DisplayTitle -Label ([string]$m.Label)
        $cb.Content = $(if ($m.Disconnected) { $displayTitle + $notConnected } else { $displayTitle })
        $cb.Tag = [string]$m.Label
        foreach ($pat in $patterns) {
            if (Test-DisplayNameMatch -Pattern $pat -Label $m.Label -ShortId $m.ShortId) { $cb.IsChecked = $true; break }
        }
        [void]$panel.Children.Add($cb)
        $checks += $cb
    }
    foreach ($pat in $patterns) {
        $matched = $false
        foreach ($m in @($Displays | Where-Object { $_ })) {
            if (Test-DisplayNameMatch -Pattern $pat -Label $m.Label -ShortId $m.ShortId) { $matched = $true; break }
        }
        if ($matched) { continue }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $Window.FindResource('Check')
        $cb.Content = ($pat + $notConnected)
        $cb.Tag = $pat
        $cb.IsChecked = $true
        [void]$panel.Children.Add($cb)
        $checks += $cb
    }
    return $checks
}

function Get-RuleEditorWhen {
    param($Editor)

    $item = $Editor.WhenBox.SelectedItem
    if (-not $item) { return 'process' }
    return [string]$item.Tag
}

# What a person typed, with validation. A function of its own, as Read-ModeFromUi is: testable
# without showing the window.
function Read-RuleFromUi {
    param($Editor)

    $when = Get-RuleEditorWhen -Editor $Editor
    $modeItem = $Editor.ModeBox.SelectedItem
    $mode = [string]$(if ($modeItem) { $modeItem.Tag } else { '' })
    $backItem = $Editor.BackBox.SelectedItem
    $back = [string]$(if ($backItem) { $backItem.Tag } else { '' })

    $process = ([string]$Editor.ProcessBox.Text).Trim()
    $minutes = 0
    $parsed = 0
    if ([int]::TryParse(([string]$Editor.MinutesBox.Text).Trim(), [ref]$parsed)) { $minutes = $parsed }

    $displays = @($Editor.DisplayChecks | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })

    $problem = ''
    if (-not $mode) { $problem = Get-Text -Key 'rule.needMode' }
    elseif ($when -eq 'process' -and -not $process) {
        $problem = Get-Text -Key 'rule.needProcess'
    }
    elseif ($when -eq 'idle' -and $minutes -lt 1) {
        $problem = Get-Text -Key 'rule.needMinutes'
    }
    elseif ($when -eq 'displays' -and $displays.Count -eq 0) {
        $problem = Get-Text -Key 'rule.needDisplays'
    }
    # "Go back to" where it already is would mean the rule undoes itself the moment the condition
    # ends and then fires again — a desk that flickers every fifteen seconds.
    elseif ($back -and $back -eq $mode) {
        $problem = Get-Text -Key 'rule.backIsMode'
    }
    if ($problem) { return [pscustomobject]@{ Ok = $false; Rule = $null; Problem = $problem } }

    # The fields the other condition owns are kept rather than blanked: a person who tried it
    # both ways round finds what they typed still there when they come back.
    return [pscustomobject]@{
        Ok = $true
        Rule = [ordered]@{
            when = $when; process = $process; minutes = $(if ($minutes -gt 0) { $minutes } else { 0 })
            displays = $displays
            mode = $mode; back = $back; enabled = [bool]$Editor.Rule['enabled']
        }
        Problem = ''
    }
}

function Show-RuleEditor {
    param($Rule, $Modes, $Owner, [bool]$Dark, $Displays = @())

    $ed = New-RuleEditorWindow -Rule $Rule -Modes $Modes -Owner $Owner -Dark $Dark -Displays $Displays
    try {
        if ($ed.Window.ShowDialog()) { return $ed.Result }
        return $null
    }
    finally {
        $ed.Window.Close()
        $script:ActiveRuleUi = $null
    }
}

# Show the editor and put its answer back into the list. $Rule is $null for "Add a rule".
function Invoke-RuleEditor {
    param($Ui, $Rule)

    $made = Show-RuleEditor -Rule $Rule -Modes (Get-RuleTargetModes -Ui $Ui) `
                            -Owner $Ui.Window -Dark $Ui.Dark -Displays $Ui.State
    if (-not $made) { return }

    if ($Rule) {
        # Edited IN PLACE, at the position it already holds: a rule's place in the list is the
        # order the tray checks them in, and "the first that fits wins". Removing and appending
        # would quietly move an edited rule to the bottom of that order.
        foreach ($field in @($made.Keys)) { $Rule[$field] = $made[$field] }
    }
    else { [void]$Ui.Rules.Add($made) }

    Update-RulesPanel -Ui $Ui
}

function ConvertTo-ComboSettings {
    param($Combos)

    $out = [ordered]@{}
    foreach ($c in @($Combos)) {
        if (-not $c -or -not $c.Name) { continue }
        $out[[string]$c.Name] = [ordered]@{
            displays = @($c.Patterns | ForEach-Object { [string]$_ })
            primary  = [string]$c.Primary
        }
    }
    return $out
}

# --- dropping mode keys -----------------------------------------------------
# A combo's key is `combo:<name>`, which means renaming it in the window changes the key
# and deleting it takes the key away. Everything tied to mode keys (audio, commands,
# brightness, contrast, presets, rules, "a monitor came up") has to move along with them —
# otherwise a ghost setting is left that shows up in no window at all, or a rule that
# every fifteen seconds heads for a mode that does not exist.
#
# There is ONE place that happens: Move-UiModeKey, the moment the name is changed, and
# Remove-UiModeKey the moment the mode goes. There used to be a second — a rename map worked
# out at Save time from each combo's name in the file — and two answers to "who moves a mode
# key" is one too many: the second pass fell on settings the first had already moved, and a
# combo that took over a freed name lost its own. What is left below is the deletions.

# A "mode key -> value" dictionary with the deleted modes' entries dropped. An entry keeps
# its PLACE: dictionaries go out to settings.json as they are, and a key appended to the end
# of a section would look in a git diff like an edit nobody made. $What is for the log only.
function Move-ModeKeyedEntries {
    param($Source, [string[]]$Gone = @(), [string]$What = 'setting')

    $moved = [ordered]@{}
    if (-not $Source) { return $moved }

    foreach ($k in @($Source.Keys)) {
        $key = [string]$k
        if ($Gone -contains $key) {
            Write-DisplayLog "settings: dropped the $What entry for removed $key"
            continue
        }
        if ($moved.Contains($key)) { continue }
        $moved[$key] = $Source[$k]
    }
    return $moved
}

# --- collecting the settings out of the window ------------------------------
# A function of its own, and without showing the window: this is the testable half of Save.
# Returns Ok/Settings/Problem; on Problem the window stays open.

function Read-SettingsFromUi {
    param(
        $Ui,
        $Settings,
        # Nobody pressed Save: this is the footer asking what the window WOULD write, so that it
        # can tell "nothing to save" from "something to save" (Get-UiFingerprint). The answer is
        # the same one; what it must not do is write "rejected save" into the log about a save
        # that was never attempted.
        [switch]$Quiet
    )

    # The shortcut combinations, with a duplicate check: two modes on one key is an
    # unresolvable ambiguity, not a warning.
    $newHotkeys = [ordered]@{}
    $seen = @{}
    foreach ($key in @($Ui.Hotkeys.Keys)) {
        $parsed = ConvertFrom-HotkeyString ([string]$Ui.Hotkeys[$key])
        if (-not $parsed) { continue }
        if ($seen.ContainsKey($parsed.Text)) {
            if (-not $Quiet) {
                Write-DisplayLog "settings dialog: rejected save - $($parsed.Text) is assigned to both $($seen[$parsed.Text]) and $key"
            }
            return [pscustomobject]@{
                Ok = $false; Settings = $null
                Problem = Get-Text -Key 'settings.hotkeyDuplicate' -Values @($parsed.Text)
            }
        }
        $seen[$parsed.Text] = $key
        $newHotkeys[$key] = $parsed.Text
    }
    # The way-back shortcut joins the same map under its own name, and the same rule: one key
    # combination drives one thing, and "back" is a thing.
    $backParsed = ConvertFrom-HotkeyString ([string]$Ui.BackHotkeyBox.Text)
    if ($backParsed) {
        if ($seen.ContainsKey($backParsed.Text)) {
            if (-not $Quiet) {
                Write-DisplayLog "settings dialog: rejected save - $($backParsed.Text) is assigned to both $($seen[$backParsed.Text]) and the way back"
            }
            return [pscustomobject]@{
                Ok = $false; Settings = $null
                Problem = Get-Text -Key 'settings.hotkeyDuplicate' -Values @($backParsed.Text)
            }
        }
        $newHotkeys[$script:BackHotkeyName] = $backParsed.Text
    }

    # Saved into a COPY rather than into the object we were handed: $Settings is the very
    # dictionary the tray lives with, and a failed write to disk must not leave three
    # different versions of the settings (in memory, on disk, and in the registered keys).
    $updated = Get-DefaultSettings
    $updated.hotkeys = $newHotkeys
    $updated.maximizeRefresh = [bool]$Ui.RefreshBox.IsChecked
    $updated.notifications = [bool]$Ui.NotifyBox.IsChecked
    $updated.language = Get-UiLanguage -Ui $Ui
    $updated.restoreWindows = [bool]$Ui.WindowsBox.IsChecked
    $updated.restoreLastMode = [bool]$Ui.LastModeBox.IsChecked
    $updated.stats = [bool]$Ui.StatsBox.IsChecked

    # The window edits only what is in it; the other fields have to travel straight through
    # and NOT leave as defaults — layout and primary have already been lost that way. Every
    # field is carried over except the ones holding form elements, so that each new setting
    # without an element of its own does not bring this bug back.
    $fromForm = @('hotkeys', 'maximizeRefresh', 'notifications', 'language', 'restoreWindows',
                  'restoreLastMode', 'stats', 'layout', 'primary', 'layoutOverride',
                  'primaryOverride', 'combos',
                  'audio', 'hooks', 'brightness', 'contrast', 'picture', 'reapply', 'rules')
    foreach ($k in @($Settings.Keys)) {
        if ($fromForm -contains $k) { continue }
        $updated[$k] = $Settings[$k]
    }

    # The layout and the taskbar come from the desk cards only after their own direct action.
    # Before that the row is a view of old settings, and writing it back used to turn an ordinary
    # Save into a new physical-layout override.
    $labels = @()
    $primary = ''
    foreach ($card in @($Ui.DeskPanel.Children)) {
        $info = $card.Tag
        if (-not $info) { continue }
        $labels += [string]$info.Label
        if ($info.Radio -and $info.Radio.IsChecked) { $primary = [string]$info.Label }
    }
    if ($Ui.LayoutEdited) {
        $updated.layout = $labels
        $updated.layoutOverride = $true
    }
    elseif ($Ui.AdoptLiveDesk) {
        $updated.layout = $labels
        $updated.layoutOverride = $false
    }
    else {
        $updated.layout = @($Settings.layout)
        $updated.layoutOverride = [bool]$Settings.layoutOverride
    }
    if ($Ui.PrimaryEdited) {
        $updated.primary = $primary
        $updated.primaryOverride = $true
    }
    elseif ($Ui.AdoptLiveDesk) {
        $updated.primary = $primary
        $updated.primaryOverride = $false
    }
    else {
        $updated.primary = [string]$Settings.primary
        $updated.primaryOverride = [bool]$Settings.primaryOverride
    }

    $updated.combos = ConvertTo-ComboSettings -Combos $Ui.Combos

    # Audio, commands, brightness, contrast and the presets are tied to mode keys, and for combos
    # those keys change along with the name. That move is NOT made here: Move-UiModeKey makes it
    # the moment the name is changed, which is the one place it happens (see the note above
    # Move-ModeKeyedEntries). Only the deletions are asked for here.
    $currentComboKeys = @($Ui.Combos | ForEach-Object { 'combo:' + $_.Name })
    $gone = @(@($Ui.DeletedComboKeys) | Where-Object { $_ -and $currentComboKeys -notcontains $_ })

    # All five are edited in the mode editor now, so all five come out of the window rather than
    # out of the file. One loop for them: the next setting tied to a mode must not bring the ghost
    # back.
    #
    # $gone is a second lock on the door: a combo deleted in this session was dropped by
    # Remove-UiCombo already — plus the line in the log that says a setting went away with its
    # mode rather than by itself.
    $sources = [ordered]@{
        audio      = (ConvertTo-AudioSettings  -Audio  $Ui.Audio)
        hooks      = (ConvertTo-HookSettings   -Hooks  $Ui.Hooks)
        brightness = (ConvertFrom-LevelModels  -Models $Ui.Levels)
        contrast   = (ConvertFrom-LevelModels  -Models $Ui.Contrast)
        picture    = (ConvertTo-PictureSettings -Picture $Ui.Picture)
        hdr        = (ConvertTo-HdrSettings -Hdr $Ui.Hdr)
    }
    foreach ($field in @($sources.Keys)) {
        $updated[$field] = Move-ModeKeyedEntries -Source $sources[$field] -Gone $gone -What $field
    }

    # The rules come out of the window's own list. No rename map here either: a combo renamed
    # takes its rules along the moment it is renamed (Move-UiModeKey), and a combo deleted takes
    # them with it (Remove-UiModeKey) — the same path every mode-keyed setting walks.
    # Normalised once more on the way out: what the tray reads every fifteen seconds must have
    # one shape, whoever wrote it.
    $updated.rules = @(ConvertTo-RuleSettings $Ui.Rules)

    # "Rebuild when the world changes" comes out of the form now. Any other key a hand-edited
    # file put in this section is carried through untouched: the window edits three of them and
    # does not own the section.
    $reapply = [ordered]@{}
    if ($Settings.reapply -is [System.Collections.IDictionary]) {
        foreach ($k in @($Settings.reapply.Keys)) { $reapply[$k] = $Settings.reapply[$k] }
    }
    $reapply['onResume'] = [bool]$Ui.ResumeBox.IsChecked
    $reapply['onUnplug'] = [bool]$Ui.UnplugBox.IsChecked
    # No rename map here: the key follows a rename in the window itself (Move-UiModeKey) and
    # dies with a deletion (Remove-UiModeKey), the same way every mode-keyed setting does.
    $reapply['onPlug'] = [string]$Ui.OnPlugKey
    $updated.reapply = $reapply

    return [pscustomobject]@{ Ok = $true; Settings = $updated; Problem = '' }
}

# --- showing it -------------------------------------------------------------

# The modes for the window: the real ones plus orphan rows for bindings whose modes are not
# here right now (the monitor was taken away, the combo was renamed, or it was wiped out of
# the file by hand). The key is claimed globally after all — RegisterHotKey works whether a
# monitor is there or not — and it can only be seen or cleared from the window.
function Get-DialogModes {
    param($State, $Settings)

    $modes = @(Get-DisplayModes -State $State -Settings $Settings)
    $known = @($modes | ForEach-Object { $_.Key })
    foreach ($key in @($Settings.hotkeys.Keys)) {
        if ($known -contains $key) { continue }
        # The way-back shortcut is not a mode that went missing (see $script:BackHotkeyName).
        if ([string]$key -eq $script:BackHotkeyName) { continue }
        $modes += [pscustomobject]@{
            Key       = $key
            Title     = Get-ModeTitleFromKey $key
            Kind      = 'orphan'
            Available = $false
        }
    }
    return $modes
}

function Show-SettingsWarning {
    param([string]$Text, $Owner = $null)

    if ($Owner) {
        [void][System.Windows.MessageBox]::Show(
            $Owner, $Text, 'DeskModes', [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning)
    }
    else {
        [void][System.Windows.MessageBox]::Show(
            $Text, 'DeskModes', [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning)
    }
}

# Commit the current form without ending its modal lifetime. The in-memory working copy advances
# only after settings.json is durable, so a failed write can be corrected and retried without the
# tray, the form and the file disagreeing about which version is active.
function Invoke-SettingsSave {
    param($Ui)

    if (-not $Ui -or $Ui.SaveBusy) { return $false }
    $Ui.SaveBusy = $true
    try {
        $got = Read-SettingsFromUi -Ui $Ui -Settings $Ui.Settings
        if (-not $got.Ok) {
            Show-SettingsWarning -Text $got.Problem -Owner $Ui.Window
            return $false
        }
        $updated = $got.Settings
        if (-not (Save-DisplaySettings $updated)) {
            Show-SettingsWarning -Text (Get-Text -Key 'settings.writeFailed') -Owner $Ui.Window
            return $false
        }

        $externalFailed = $false
        $startupWanted = [bool]$Ui.StartupBox.IsChecked
        if ($startupWanted -ne [bool]$Ui.StartupWasEnabled) {
            try {
                Set-RunAtStartup -Enabled $startupWanted
                $Ui.StartupWasEnabled = $startupWanted
            }
            catch {
                $externalFailed = $true
                Write-DisplayLog "settings dialog: settings saved, but startup could not be changed - $($_.Exception.Message)"
                Show-SettingsWarning -Text (Get-Text -Key 'settings.startupFailed') -Owner $Ui.Window
            }
        }
        if (-not (Save-UiSleepMinutes -Ui $Ui)) {
            $externalFailed = $true
            Show-SettingsWarning -Text (Get-Text -Key 'settings.sleepFailed') -Owner $Ui.Window
        }

        $Ui.Settings = $updated
        $Ui.Result = $updated
        Set-UiBaseline -Ui $Ui
        if ($externalFailed) {
            # The normal fingerprint contains the requested checkbox and timeout. Keep it unequal
            # until a later Save confirms those external Windows settings, including on pages that
            # hide Save when the window is clean.
            $Ui.Baseline = 'external settings still pending'
        }
        Update-UiFooter -Ui $Ui

        $callback = $Ui.OnSaved
        if ($callback) {
            try { & $callback $updated }
            catch {
                Write-DisplayLog "settings dialog: saved settings could not be applied to the tray - $($_.Exception.Message)"
                Show-SettingsWarning -Text (Get-Text -Key 'settings.applyFailed') -Owner $Ui.Window
            }
        }
        return $true
    }
    finally { $Ui.SaveBusy = $false }
}

# A double-click can arrive inside ShowDialog's nested message pump. Reuse the one modal lifetime:
# another New-SettingsWindow would replace ActiveUi and leave the first window's handlers stranded.
$script:PendingSettingsPage = ''
function Show-OpenSettingsWindow {
    param([string]$Page = '')

    $ui = $script:ActiveUi
    if (-not $ui -or -not $ui.Window) { return $false }
    if ($Page) { $script:PendingSettingsPage = $Page }
    if (-not $ui.Window.Dispatcher.CheckAccess()) {
        [void]$ui.Window.Dispatcher.BeginInvoke([action]{ Show-OpenSettingsWindow })
        return $true
    }
    $wanted = $script:PendingSettingsPage
    $script:PendingSettingsPage = ''
    if ($wanted) { Set-UiPage -Ui $ui -Page $wanted }
    if ($ui.Window.WindowState -eq [System.Windows.WindowState]::Minimized) {
        $ui.Window.WindowState = [System.Windows.WindowState]::Normal
    }
    [void]$ui.Window.Activate()
    return $true
}

# Returns the latest settings saved during this window lifetime, or $null if it closed without a
# Save. The window takes its icon off the disk itself (Register-WindowTheme): WPF wants an
# ImageSource, not a GDI icon.
function Show-SettingsDialog {
    param(
        $State,
        $Settings,
        $Positions = @{},
        # Which page to open on. Empty - the one the window was left on. The tray's About item
        # is what names a page.
        [string]$Page = '',
        # The tray supplies this so settings, language and shortcuts change on every successful
        # Save, rather than waiting for the modal window to close.
        [scriptblock]$OnSaved = $null
    )

    if (Show-OpenSettingsWindow -Page $Page) { return $script:ActiveUi.Result }

    # Insurance: if the settings did not make it, we read them off the disk rather than
    # dying on a reference to $null.
    if (-not $Settings -or -not $Settings.hotkeys) {
        Write-DisplayLog 'settings dialog: settings arrived empty, reading them from disk'
        $Settings = Get-DisplaySettings
    }

    $ui = $null
    try {
        $script:PendingSettingsDeskState = $null
        $modes = @(Get-DialogModes -State $State -Settings $Settings)
        $ui = New-SettingsWindow -Modes $modes -Settings $Settings -State $State -Positions $Positions -Page $Page

        # The run-at-startup checkbox is read from the fact that the shortcut exists rather than
        # from the settings: the shortcut could have been deleted by hand.
        $startupWasEnabled = [bool](Test-RunAtStartup)
        $ui.StartupWasEnabled = $startupWasEnabled
        $ui.OnSaved = $OnSaved
        $ui.StartupBox.IsChecked = $startupWasEnabled
        # And the display timeout from Windows, for the same reason: it is the system's, not ours.
        Set-UiSleepMinutes -Ui $ui -Minutes (Get-DisplaySleepMinutes)
        # Both of those were just set from outside, and neither is a person's edit. Taken again so
        # the footer does not open a freshly opened window on "Cancel" - and the page showing is told
        # again, because the first telling compared against a baseline that had neither in it.
        Set-UiBaseline -Ui $ui
        Update-UiFooter -Ui $ui

        [void]$ui.Window.ShowDialog()
        # A close before any Save still returns $null. After one or more Saves this is the latest
        # durable object, which keeps the function useful to non-tray callers and tests.
        return $ui.Result
    }
    finally {
        if ($ui -and $ui.Window) { $ui.Window.Close() }
        if ($ui -and [object]::ReferenceEquals($script:ActiveUi, $ui)) {
            $script:ActiveUi = $null
            $script:PendingSettingsDeskState = $null
            $script:PendingSettingsPage = ''
        }
    }
}

# --- which display is which --------------------------------------------------
# A badge on every display that is on, for a moment: its name, its Monitor ID and what it is showing.
# Three cards that all begin with LG tell nobody which LG is which; Windows has the same button in
# its own display settings for the same reason. The badges are plain windows shown and then closed
# by a timer - nothing is drawn on anybody's desktop, and nothing is left behind.

$script:BadgeMilliseconds = 2500
# The badges on show right now, so the timer that closes them finds them without a closure.
$script:BadgeWindows = @()
$script:BadgeTimer = $null

# The two lines of a badge. Pure, and the reason the badge can be tested without a screen.
function Get-BadgeText {
    param($Display)

    $line = [string]$Display.ShortId
    if ($Display.Width -gt 0 -and $Display.Height -gt 0) {
        $mode = '{0} x {1}' -f $Display.Width, $Display.Height
        if ($Display.Hz -gt 0) { $mode += ' @ {0} Hz' -f $Display.Hz }
        $line = $(if ($line) { $line + $script:UiDot + $mode } else { $mode })
    }
    $mark = Get-Text -Key 'desk.taskbar.lower'
    if ($Display.Primary) { $line = $(if ($line) { $line + $script:UiDot + $mark } else { $mark }) }
    return [pscustomobject]@{ Title = Get-DisplayTitle -Label ([string]$Display.Label); Line = $line }
}

# One badge: a dark plate with light text whatever the theme, because it lies on top of whatever is
# on that screen and has to read against a game as well as against a document. Fixed size and
# centred by arithmetic rather than SizeToContent: a window that measures itself after Show has a
# frame at (0, 0) first, and that frame is on the wrong display.
function New-DisplayBadge {
    param($Display, $Rect)

    Initialize-WpfRuntime
    $text = Get-BadgeText -Display $Display

    $win = New-Object System.Windows.Window
    $win.WindowStyle = 'None'
    $win.ResizeMode = 'NoResize'
    $win.AllowsTransparency = $true
    $win.Background = [System.Windows.Media.Brushes]::Transparent
    $win.ShowInTaskbar = $false
    $win.ShowActivated = $false
    $win.Topmost = $true
    $win.Width = 460
    $win.Height = 150
    $win.WindowStartupLocation = 'Manual'
    if ($Rect) {
        $win.Left = [double]$Rect.Left + (([double]$Rect.Right - [double]$Rect.Left) - $win.Width) / 2
        $win.Top  = [double]$Rect.Top  + (([double]$Rect.Bottom - [double]$Rect.Top) - $win.Height) / 2
    }

    $plate = New-Object System.Windows.Controls.Border
    $plate.CornerRadius = New-Object System.Windows.CornerRadius 14
    $plate.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0xE6, 0x20, 0x20, 0x20))
    $plate.Padding = New-Object System.Windows.Thickness 32, 22, 32, 22

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.VerticalAlignment = 'Center'
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $text.Title
    $title.FontSize = 40
    $title.FontWeight = 'SemiBold'
    $title.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI Variable Display, Segoe UI'
    $title.Foreground = [System.Windows.Media.Brushes]::White
    $title.TextAlignment = 'Center'
    $title.TextTrimming = 'CharacterEllipsis'
    [void]$stack.Children.Add($title)
    if ($text.Line) {
        $line = New-Object System.Windows.Controls.TextBlock
        $line.Text = $text.Line
        $line.FontSize = 18
        $line.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xC8, 0xC8, 0xC8))
        $line.TextAlignment = 'Center'
        $line.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
        [void]$stack.Children.Add($line)
    }
    $plate.Child = $stack
    $win.Content = $plate
    return $win
}

# Where each display that is on stands, in the units a WPF window is placed in. Matched to the state
# by the output name, which is what both sides call a screen (\\.\DISPLAY1). The same scale as
# Get-ScreenRects uses, for the same reason.
function Get-DisplayBadgeRects {
    param($State)

    $scale = 1.0
    try {
        $pixels = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width
        if ($pixels -gt 0) { $scale = [System.Windows.SystemParameters]::VirtualScreenWidth / $pixels }
    }
    catch { }   # one to one, then

    $out = @()
    $screens = @()
    try { $screens = @([System.Windows.Forms.Screen]::AllScreens) } catch { return $out }   # no screens, no badges
    foreach ($m in @($State | Where-Object { $_ -and $_.Active -and $_.Output })) {
        $screen = @($screens | Where-Object { [string]$_.DeviceName -eq [string]$m.Output })
        if ($screen.Count -eq 0) { continue }
        $b = $screen[0].Bounds
        $out += [pscustomobject]@{
            Display = $m
            Rect    = [pscustomobject]@{ Left = $b.Left * $scale; Top = $b.Top * $scale
                                         Right = $b.Right * $scale; Bottom = $b.Bottom * $scale }
        }
    }
    return $out
}

# Show them all and take them down together. A WinForms timer and not a Dispatcher one: the tray
# runs a WinForms message loop, and that is the loop this timer is pumped by wherever the badges were
# asked for from. The tick reads $script:BadgeWindows rather than carrying the list in a closure -
# see the note about .GetNewClosure() at the top of the handlers.
function Show-DisplayBadges {
    param($State)

    Close-DisplayBadges
    $shown = @()
    foreach ($one in @(Get-DisplayBadgeRects -State $State)) {
        $win = New-DisplayBadge -Display $one.Display -Rect $one.Rect
        $win.Show()
        $shown += $win
    }
    if ($shown.Count -eq 0) { return }
    $script:BadgeWindows = $shown

    $script:BadgeTimer = New-Object System.Windows.Forms.Timer
    $script:BadgeTimer.Interval = $script:BadgeMilliseconds
    $script:BadgeTimer.add_Tick({ Close-DisplayBadges })
    $script:BadgeTimer.Start()
}

function Close-DisplayBadges {
    if ($script:BadgeTimer) {
        try { $script:BadgeTimer.Stop(); $script:BadgeTimer.Dispose() } catch { }   # already gone
        $script:BadgeTimer = $null
    }
    foreach ($win in @($script:BadgeWindows)) {
        try { $win.Close() } catch { }   # a badge the person closed themselves, say
    }
    $script:BadgeWindows = @()
}

# --- the timer window -------------------------------------------------------
# "Turn off in however long." The ready-made amounts are in the tray menu; this window is
# about everything else, and a value in it can be TAKEN rather than only described in words:
# a slider over uneven steps (Get-TimerSteps), pills for the popular amounts, the wheel and
# the arrows for five minutes at a time. And all the while the clock time it will happen at
# is visible: "in 340 minutes" says nothing, "at 06:20 tomorrow" says everything. The input
# field has not gone anywhere either — typing "1h30" is sometimes faster.
#
# The window has no frame and closes when it is left: this is a popup by the cursor, not a
# form. Built separately from being shown (New-TimerWindow / Show-TimerDialog) — like the
# other windows here, for the tests' sake.

$script:TimerWindowXaml = @'
<!-- The size is given in numbers and does not grow with the content: the window is placed
     by the cursor using Width and Height BEFORE it is shown (Set-PopupPlace), and with
     SizeToContent it does not have them yet. So the height has to run ahead of the content
     with room to spare — otherwise the window will not grow but will clip: it asks for 233
     right now and stands at 248. -->
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="%%T:win.timer%%"
        Width="330" Height="248"
        WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterScreen" Topmost="True"
        Background="%%BG%%" Foreground="%%TEXT%%"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        UseLayoutRounding="True">
    <Window.Resources>
%%RES%%
    </Window.Resources>
    <!-- A visible border (InputBorderBrush, not CardBorderBrush): a window with no caption
         hangs over other people's windows, and it needs a real edge. -->
    <Border BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1" Padding="16,12,16,16">
        <StackPanel>
            <TextBlock x:Name="CaptionText" Style="{StaticResource RowSub}" Margin="0,0,0,4"/>
            <TextBox x:Name="ValueBox" Style="{StaticResource Big}"/>
            <TextBlock x:Name="TargetText" Style="{StaticResource RowSub}" Margin="0,4,0,0"/>
            <Slider x:Name="Dial" Style="{StaticResource Level}" Margin="0,12,0,0"/>
            <StackPanel x:Name="ChipRow" Orientation="Horizontal" Margin="0,8,0,0"/>
            <!-- The doing one first, the way out second - as in every other window here (Save,
                 then Cancel). This popup had them the other way round, so the button under the
                 cursor after four windows of muscle memory was the one that cancels. -->
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
                <Button x:Name="StartBtn" Style="{StaticResource BtnAccent}" MinWidth="124" IsDefault="True"/>
                <Button x:Name="CancelBtn" Style="{StaticResource Btn}" Content="%%T:common.cancel%%" MinWidth="84"
                        Margin="8,0,0,0" IsCancel="True"/>
            </StackPanel>
        </StackPanel>
    </Border>
</Window>
'@

# The window being worked with right now (see the comment about handlers above: there are no
# closures here, and the handlers take their state from here).
$script:ActiveTimerUi = $null

# Where to put the popup: above the cursor and centred on it, but wholly inside the area we
# were given. A pure function; every size is in WPF units.
function Get-PopupPlacement {
    param([double]$X, [double]$Y, [double]$Width, [double]$Height,
          [double]$Left, [double]$Top, [double]$Right, [double]$Bottom, [double]$Gap = 12)

    # Not named $x/$y: PowerShell variables have no case, and such a pair would silently turn
    # out to be the same $X/$Y that arrived in the parameters.
    $px = $X - $Width / 2
    # Above the cursor: the tray menu opens from the bottom right, and a window dropping DOWN
    # would go under the taskbar. Does not fit above — it goes below the cursor.
    $py = $Y - $Height - $Gap
    if ($py -lt $Top) { $py = $Y + $Gap }

    if ($py + $Height -gt $Bottom) { $py = $Bottom - $Height }
    if ($py -lt $Top) { $py = $Top }
    if ($px + $Width -gt $Right) { $px = $Right - $Width }
    if ($px -lt $Left) { $px = $Left }
    return [pscustomobject]@{ X = $px; Y = $py }
}

# The same, but for a real screen: the cursor and the work area are taken from Windows. It
# did not work out — the window stays wherever WindowStartupLocation puts it.
function Set-PopupPlace {
    param($Window)

    try {
        $pt = [System.Windows.Forms.Control]::MousePosition
        $area = [System.Windows.Forms.Screen]::FromPoint($pt).WorkingArea

        # Pixels -> WPF units. On a monitor at 150% scale those are different numbers, and a
        # window placed by pixels would land a third of a screen away.
        $sx = 1.0; $sy = 1.0
        $src = [System.Windows.PresentationSource]::FromVisual($Window)
        if ($src -and $src.CompositionTarget) {
            $t = $src.CompositionTarget.TransformFromDevice
            $sx = $t.M11; $sy = $t.M22
        }

        $place = Get-PopupPlacement -X ($pt.X * $sx) -Y ($pt.Y * $sy) `
                                    -Width $Window.Width -Height $Window.Height `
                                    -Left ($area.Left * $sx)  -Top ($area.Top * $sy) `
                                    -Right ($area.Right * $sx) -Bottom ($area.Bottom * $sy)
        $Window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
        $Window.Left = $place.X
        $Window.Top  = $place.Y
    }
    catch { }   # did not work out — the window will stand in the middle of the screen
}

# The one place where the window's value becomes visible: the field, the slider, the "at what
# time" caption and the button are all updated from here. -KeepText — for when the value came
# from the field itself: rewriting the text under a typing person's fingers is not allowed.
function Set-TimerValue {
    param($Ui, [int]$Minutes, [switch]$KeepText)

    if ($Minutes -lt 1) { $Minutes = 1 }
    if ($Minutes -gt $script:TimerMaxMinutes) { $Minutes = $script:TimerMaxMinutes }
    $Ui.Minutes = $Minutes

    # While the sync is running the field's and the slider's handlers keep quiet: otherwise
    # they would move each other around in circles.
    $Ui.Syncing = $true
    try {
        if (-not $KeepText) {
            $Ui.ValueBox.Text = Format-DurationShort $Minutes
            $Ui.ValueBox.CaretIndex = $Ui.ValueBox.Text.Length
        }
        $Ui.Dial.Value = Get-TimerStepIndex -Minutes $Minutes
    }
    finally { $Ui.Syncing = $false }

    $Ui.TargetText.Text = Get-TimerTargetText -Minutes $Minutes
    $Ui.StartBtn.IsEnabled = $true
}

# Something we do not understand was typed. We dim the button and say what we do understand:
# silently refusing to set a timer is the worst of all options.
function Clear-TimerValue {
    param($Ui)

    $Ui.Minutes = 0
    $Ui.TargetText.Text = Get-Text -Key 'timer.hint' -Values @((Format-DurationShort $script:TimerMaxMinutes))
    $Ui.StartBtn.IsEnabled = $false
}

function New-TimerWindow {
    param(
        [ValidateSet('shutdown', 'sleep')][string]$Action = 'sleep',
        # Where to start from: what is left of a timer already set, or the popular forty-five
        # minutes (see Get-PowerPrefill in Displays.ps1).
        [int]$Minutes = 45
    )

    Initialize-WpfRuntime

    $dark = Test-DarkTheme
    $palette = Get-UiPalette -Dark $dark
    $win = Convert-UiXaml -Xaml $script:TimerWindowXaml -Palette $palette
    Register-WindowTheme -Window $win -Dark $dark

    $ui = [pscustomobject]@{
        Window     = $win
        Dark       = $dark
        Action     = $Action
        ValueBox   = $win.FindName('ValueBox')
        TargetText = $win.FindName('TargetText')
        Dial       = $win.FindName('Dial')
        StartBtn   = $win.FindName('StartBtn')
        CancelBtn  = $win.FindName('CancelBtn')
        # The minutes that will leave for the outside. Zero means "what was typed makes no sense".
        Minutes    = 0
        Syncing    = $false
        # Whether the window has ever had focus. Before that, losing focus does not count: the
        # window opens from the tray menu, and for its first few frames it has no focus.
        Seen       = $false
        Result     = 0
    }

    # A key per action, as everywhere the timer speaks: the caption and the button are a verb.
    $win.FindName('CaptionText').Text = Get-Text -Key ('timer.caption.' + $Action)
    $ui.StartBtn.Content = Get-Text -Key ('timer.start.' + $Action)

    # The slider travels by STEP NUMBER, not by minutes: the steps are uneven (see
    # Get-TimerSteps), and an even travel of the handle is the only way to offer both "in five
    # minutes" and "in twelve hours" on one track.
    $ui.Dial.Minimum = 0
    $ui.Dial.Maximum = (Get-TimerSteps).Count - 1
    $ui.Dial.SmallChange = 1
    $ui.Dial.LargeChange = 3
    $ui.Dial.TickFrequency = 1
    $ui.Dial.IsSnapToTickEnabled = $true

    # The window is built — from this point on the handlers find it here.
    $script:ActiveTimerUi = $ui

    foreach ($chip in 15, 30, 60, 120) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $win.FindResource('Chip')
        $btn.Content = Format-DurationShort $chip
        $btn.Tag = $chip
        $btn.add_Click({
            param($sender, $e)
            $ui = $script:ActiveTimerUi
            if ($ui) { Set-TimerValue -Ui $ui -Minutes ([int]$sender.Tag) }
        })
        [void]$win.FindName('ChipRow').Children.Add($btn)
    }

    $ui.ValueBox.add_TextChanged({
        param($sender, $e)
        $ui = $script:ActiveTimerUi
        if (-not $ui -or $ui.Syncing) { return }
        $minutes = ConvertFrom-DurationText $sender.Text
        if ($minutes -le 0 -or $minutes -gt $script:TimerMaxMinutes) { Clear-TimerValue -Ui $ui; return }
        Set-TimerValue -Ui $ui -Minutes $minutes -KeepText
    })

    # The arrows move five minutes along the grid. In a field holding a value they are more
    # useful than a caret walking over letters: "45 min" is not edited letter by letter.
    $ui.ValueBox.add_PreviewKeyDown({
        param($sender, $e)
        $ui = $script:ActiveTimerUi
        if (-not $ui) { return }
        $step = 0
        if ($e.Key -eq [System.Windows.Input.Key]::Up)   { $step = 5 }
        if ($e.Key -eq [System.Windows.Input.Key]::Down) { $step = -5 }
        if ($step -eq 0) { return }
        $e.Handled = $true
        $from = $(if ($ui.Minutes -gt 0) { $ui.Minutes } else { 45 })
        Set-TimerValue -Ui $ui -Minutes (Get-TimerNudge -Minutes $from -Step $step)
    })

    $ui.Dial.add_ValueChanged({
        param($sender, $e)
        $ui = $script:ActiveTimerUi
        if (-not $ui -or $ui.Syncing) { return }
        Set-TimerValue -Ui $ui -Minutes (Get-TimerStepMinutes -Index ([int]$sender.Value))
    })

    # The wheel works over the whole window, not just over the slider: people want to scroll
    # wherever the cursor happens to be, and nobody should have to hit a track four pixels
    # wide to do it.
    $win.add_PreviewMouseWheel({
        param($sender, $e)
        $ui = $script:ActiveTimerUi
        if (-not $ui) { return }
        $e.Handled = $true
        $from = $(if ($ui.Minutes -gt 0) { $ui.Minutes } else { 45 })
        $step = $(if ($e.Delta -gt 0) { 5 } else { -5 })
        Set-TimerValue -Ui $ui -Minutes (Get-TimerNudge -Minutes $from -Step $step)
    })

    $ui.StartBtn.add_Click({
        param($sender, $e)
        $ui = $script:ActiveTimerUi
        if (-not $ui -or $ui.Minutes -le 0) { return }
        $ui.Result = $ui.Minutes
        $ui.Window.DialogResult = $true
    })

    # A window with no frame: it can be dragged by any empty spot.
    $win.add_MouseLeftButtonDown({
        param($sender, $e)
        try { $sender.DragMove() } catch { }   # the button was released already — nothing to drag
    })

    Set-TimerValue -Ui $ui -Minutes $Minutes
    return $ui
}

# Show it and hand back the minutes. Zero means cancelled: the same as with
# ConvertFrom-DurationText, and one check is enough for the caller.
function Show-TimerDialog {
    param(
        [ValidateSet('shutdown', 'sleep')][string]$Action = 'sleep',
        [int]$Minutes = 45
    )

    $ui = New-TimerWindow -Action $Action -Minutes $Minutes

    # The placement and the focus-lost handling belong to the real showing only. They have no
    # business in New-TimerWindow: the same window is used by the tests and by
    # render-preview.ps1, and those do not show it (and certainly should not get a window that
    # puts itself by the cursor and closes on the first stray click).
    $ui.Window.add_SourceInitialized({ Set-PopupPlace -Window $this })
    # The window takes focus itself: it is opened by a click on the tray menu, and without
    # this there would be nowhere for typing to go. The value is selected whole at the same
    # time — the first digit replaces it rather than being appended to it.
    $ui.Window.add_Loaded({
        $ui = $script:ActiveTimerUi
        if (-not $ui) { return }
        [void]$ui.Window.Activate()
        [void]$ui.ValueBox.Focus()
        $ui.ValueBox.SelectAll()
    })
    $ui.Window.add_Activated({
        $ui = $script:ActiveTimerUi
        if ($ui) { $ui.Seen = $true }
    })
    # The window was left — it closes without setting anything. A popup by the cursor lives
    # exactly as long as it is being looked at; that is why it has no close button.
    $ui.Window.add_Deactivated({
        $ui = $script:ActiveTimerUi
        if (-not $ui -or -not $ui.Seen) { return }
        try { $ui.Window.DialogResult = $false } catch { }   # the window is closing already
    })

    try {
        if ($ui.Window.ShowDialog()) { return [int]$ui.Result }
        return 0
    }
    finally {
        $ui.Window.Close()
        $script:ActiveTimerUi = $null
    }
}

# --- the diary page ---------------------------------------------------------
# What the diary counted, as a page of the Settings window instead of a page in the browser. The
# browser page has not gone anywhere — "Open as a page" writes it and opens it — but for the
# everyday question ("where did today go?") a browser tab is a detour: a file on the disk, a
# second application, and a step away from what you were doing.
#
# Two rules hold its shape:
#
#   * IT IS ONE SCREEN. Nothing here scrolls. The sections are stretched to the window instead,
#     and a section shows as many rows as it has room for — a report you have to scroll is one
#     nobody reads to the end.
#   * The period is chosen HERE, not in the settings. "Today" and "all of it" are different
#     questions, and both get asked in the same minute.

# A function and not a constant, for the reason Get-HdrChoices is one.
function Get-StatsPeriods {
    return @(
        [pscustomobject]@{ Days = 1;  Title = (Get-Text -Key 'diary.today') }
        [pscustomobject]@{ Days = 7;  Title = (Get-PluralText -Key 'diary.days' -Count 7) }
        [pscustomobject]@{ Days = 30; Title = (Get-PluralText -Key 'diary.days' -Count 30) }
        # Nought days is "everything there is" - see Get-ActivityReport.
        [pscustomobject]@{ Days = 0;  Title = (Get-Text -Key 'diary.all') }
    )
}

# How many rows a section shows. Five, not ten: four sections share one page, height is what a
# sixth row costs, and the tail of a top list is noise.
#
# "As many as fit" was tried here and taken out. The sections would have to be stretched to the
# window for it, and four sections of five rows want about 865 points against the 660 the window
# opens at: what came of the difference was a list arranged into a cell too small for it. The
# page scrolls instead, which says the same thing without lying about it.
$script:StatsTopRows = 5

# The window being worked with right now (see the comment about handlers above: the pills and the
# button take their state from here, not from a closure).
$script:ActiveStatsUi = $null

# The line under the title: what is being looked at. A pure function — the window's one piece of
# prose, and the one thing a test can read back without a screenshot.
function Get-StatsRangeText {
    param($Report)

    if (-not $Report -or [int]$Report.DaysRecorded -eq 0) {
        # Not "turn the diary on": by the time this window is open it IS on (the tray offers
        # nothing else). An empty report here means nothing has been counted yet.
        return (Get-Text -Key 'diary.empty')
    }
    if ([string]$Report.From -eq [string]$Report.To) { return [string]$Report.From }
    # Short, because of what it stands next to: four period pills and a button share that strip,
    # and the head of this page has about 220 points for a caption. "2026-08-29 .. 2026-09-04
    # - 7 days with something in them" wrapped onto a second line and walked into the pills. The
    # count is still there - on a 30-day period, how many of those days have anything in them at
    # all is the first thing worth knowing - and the sentence it used to be is on hover
    # (Update-StatsView), which is where this window puts every caption it has had to cut.
    return ('{0} .. {1}' -f $Report.From, $Report.To) + '  ' + [string][char]0x00B7 + '  ' +
           (Get-PluralText -Key 'diary.days' -Count ([int]$Report.DaysRecorded))
}

# The same fact spelled out, for the tooltip: "7 days" says the number and not what it counts,
# and the strip in the header has no room to say both.
function Get-StatsRangeTitle {
    param($Report)

    if (-not $Report -or [int]$Report.DaysRecorded -eq 0) { return Get-StatsRangeText -Report $Report }
    if ([string]$Report.From -eq [string]$Report.To) { return [string]$Report.From }
    return Get-Text -Key 'diary.rangeTitle' -Values @($Report.From, $Report.To, $Report.DaysRecorded)
}

# One fact, big: the number first, what it is underneath. The caption carries a ToolTip of its
# own — six cards share 840 points, and a long value trims rather than pushing its neighbours.
function New-StatsCard {
    param($Window, [string]$Value, [string]$Caption)

    $box = New-Object System.Windows.Controls.Border
    $box.Background = $Window.FindResource('CardBrush')
    $box.BorderBrush = $Window.FindResource('CardBorderBrush')
    $box.BorderThickness = New-Object System.Windows.Thickness 1
    $box.CornerRadius = New-Object System.Windows.CornerRadius 4
    $box.Padding = New-Object System.Windows.Thickness 10, 8, 10, 8
    $box.Margin = New-Object System.Windows.Thickness 4, 0, 4, 0
    $box.ToolTip = [string]$Value + $script:UiDot + [string]$Caption

    $stack = New-Object System.Windows.Controls.StackPanel
    $box.Child = $stack

    $big = New-Object System.Windows.Controls.TextBlock
    $big.Text = $Value
    $big.FontSize = 16
    $big.FontWeight = 'SemiBold'
    $big.TextTrimming = 'CharacterEllipsis'
    [void]$stack.Children.Add($big)

    $small = New-Object System.Windows.Controls.TextBlock
    $small.Text = $Caption
    $small.FontSize = 11
    $small.Foreground = $Window.FindResource('DimBrush')
    $small.TextTrimming = 'CharacterEllipsis'
    $small.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
    [void]$stack.Children.Add($small)

    return $box
}

# A row of a section: two floors. The name, the time and the share on top; the bar underneath,
# across the whole width.
#
# One floor was what the 880-point window could afford, and it cost the name its end: "chrome on
# LG ULTRA..." was already trimmed there, with the time, a 96-point bar and the percentage all
# in the same line. Given the whole width, a name has nowhere left to be cut off.
#
# The percentage went next to the time rather than staying under the bar on a third line of its
# own: the two are one fact said two ways, and apart they made every row of every section three
# times as tall as it needed to be - five rows a section, four sections, on one page.
#
# The bar is two Borders - a track and what is filled in - rather than a Slider or a ProgressBar:
# both of those bring a template, a theme and a hover state along with them, and none of that is
# wanted on a figure. What is filled in is sized by two star columns rather than in points, so it
# is right at any width without anybody measuring the window.
function New-StatsRow {
    param($Window, $Row)

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness 0, 3, 0, 3
    foreach ($i in 1..2) {
        [void]$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
    }

    $top = New-Object System.Windows.Controls.Grid
    foreach ($width in @((New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)),
                         [System.Windows.GridLength]::Auto,
                         [System.Windows.GridLength]::Auto)) {
        $column = New-Object System.Windows.Controls.ColumnDefinition
        $column.Width = $width
        [void]$top.ColumnDefinitions.Add($column)
    }

    # "chrome|LG ULTRAFINE" is a pair, and it is read as one: the separator becomes a word. The
    # name itself comes from the process list and out of EDID, so it can be anything at all - it
    # is put into a TextBlock as text and never becomes markup (which is the whole difference
    # from the HTML page, where Format-HtmlText has to do that work).
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = [string]$Row.Name -replace '\|', ' on '
    $name.FontSize = 13
    $name.TextWrapping = 'NoWrap'
    $name.VerticalAlignment = 'Center'
    $name.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
    # The tooltip stays even though nothing is trimmed: a name can still be longer than a window
    # somebody has made narrow, and hovering is how one asks.
    $name.ToolTip = $name.Text
    [void]$top.Children.Add($name)

    $time = New-Object System.Windows.Controls.TextBlock
    $time.Text = Format-ActivitySpan ([int]$Row.Seconds)
    $time.FontSize = 12
    $time.Foreground = $Window.FindResource('DimBrush')
    $time.TextAlignment = 'Right'
    $time.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($time, 1)
    [void]$top.Children.Add($time)

    $percent = New-Object System.Windows.Controls.TextBlock
    $percent.Text = '{0}%' -f (Format-ActivityPercent ([double]$Row.Share))
    $percent.FontSize = 12
    $percent.Foreground = $Window.FindResource('DimBrush')
    $percent.TextAlignment = 'Right'
    # Reserved whatever the figure is, so a column of "3%" and "100%" ends on one edge.
    $percent.MinWidth = 44
    $percent.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($percent, 2)
    [void]$top.Children.Add($percent)
    [void]$grid.Children.Add($top)

    $track = New-Object System.Windows.Controls.Border
    $track.Height = 6
    $track.CornerRadius = New-Object System.Windows.CornerRadius 3
    $track.Background = $Window.FindResource('MiniBrush')
    $track.VerticalAlignment = 'Center'
    $track.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
    [System.Windows.Controls.Grid]::SetRow($track, 1)

    # Clamped: one application sits on two monitors, so a share is worked out against the time at
    # the computer and can come out above a hundred (see ConvertTo-ActivityRows). Two star columns
    # of "share" and "the rest" cannot add up to more than the track, whatever the number says.
    $share = [math]::Min(100, [math]::Max(0, [double]$Row.Share))
    $split = New-Object System.Windows.Controls.Grid
    foreach ($part in @($share, (100 - $share))) {
        $column = New-Object System.Windows.Controls.ColumnDefinition
        $column.Width = New-Object System.Windows.GridLength $part, ([System.Windows.GridUnitType]::Star)
        [void]$split.ColumnDefinitions.Add($column)
    }
    $fill = New-Object System.Windows.Controls.Border
    $fill.CornerRadius = New-Object System.Windows.CornerRadius 3
    $fill.Background = $Window.FindResource('AccentBrush')
    # Three points even at nought per cent: a bar that disappears reads as a drawing that failed.
    $fill.MinWidth = 3
    [void]$split.Children.Add($fill)
    $track.Child = $split
    [void]$grid.Children.Add($track)

    return $grid
}

function Update-StatsRows {
    param($Ui, $Panel, $Rows)

    $Panel.Children.Clear()
    $list = @($Rows | Select-Object -First $script:StatsTopRows)
    if ($list.Count -eq 0) {
        [void]$Panel.Children.Add((New-UiTextBlock -Text (Get-Text -Key 'diary.nothingYet') -Style 'RowSub' -Window $Ui.Window))
        return
    }
    foreach ($row in $list) {
        [void]$Panel.Children.Add((New-StatsRow -Window $Ui.Window -Row $row))
    }
}

# Twenty-four bars, empty hours included: the dip at lunch and the wall at bedtime are what this
# is looked at for, and they are only visible against the hours that have nothing in them.
function Update-StatsHours {
    param($Ui, $Report)

    $Ui.HoursPanel.Children.Clear()
    $Ui.HourLabels.Children.Clear()
    $win = $Ui.Window
    # The height comes from the markup rather than from a constant here: the panel is what the
    # bar has to fit inside, and two numbers that have to agree are one too many.
    $room = [double]$Ui.HoursPanel.Height

    $hours = @($Report.Hours)
    if ($hours.Count -eq 0) {
        # A report with no days in it hands back no hours either (see Get-ActivityReport). The day
        # is still a day: a row of ticks says "nothing happened here", an empty rectangle says the
        # drawing is broken.
        $hours = @(0..23 | ForEach-Object { [pscustomobject]@{ Name = '{0:00}' -f $_; Seconds = 0; Share = 0 } })
    }

    foreach ($hour in $hours) {
        $bar = New-Object System.Windows.Controls.Border
        $bar.VerticalAlignment = 'Bottom'
        $bar.Margin = New-Object System.Windows.Thickness 3, 0, 3, 0
        $bar.CornerRadius = New-Object System.Windows.CornerRadius 3, 3, 0, 0
        $bar.Background = $win.FindResource('AccentBrush')
        # An hour with nothing in it still gets two points of bar: a row of ticks reads as a scale,
        # a gap in the middle of one reads as a fault in the drawing.
        $bar.Height = [math]::Max(2, $room * [double]$hour.Share / 100.0)
        # The busiest hour at full strength, the rest faded: one accent colour, two weights. A
        # second colour would have to mean something, and there is nothing here for it to mean.
        $bar.Opacity = $(if ([int]$hour.Name -eq [int]$Report.BusiestHour) { 1.0 } else { 0.55 })
        $bar.ToolTip = '{0}:00   {1}' -f $hour.Name, (Format-ActivitySpan ([int]$hour.Seconds))
        [void]$Ui.HoursPanel.Children.Add($bar)

        $label = New-Object System.Windows.Controls.TextBlock
        # Every third hour: twenty-four numbers under twenty-four bars is a fence, not a scale.
        $label.Text = $(if (([int]$hour.Name % 3) -eq 0) { [string]$hour.Name } else { '' })
        $label.FontSize = 10
        $label.Foreground = $win.FindResource('DimBrush')
        $label.TextAlignment = 'Center'
        [void]$Ui.HourLabels.Children.Add($label)
    }
}

# The one place the window's contents come from: the period changes, everything is redrawn out of
# a fresh report. There is no partial update — the whole window is four lists and six numbers, and
# rebuilding it costs less than keeping track of what changed.
function Update-StatsView {
    param($Ui)

    $win = $Ui.Window
    $report = Get-ActivityReport -Store $Ui.Store -Days $Ui.Days -Today $Ui.Today
    $Ui.Report = $report

    foreach ($chip in @($Ui.Chips)) {
        $chip.Style = $win.FindResource($(if ([int]$chip.Tag -eq [int]$Ui.Days) { 'ChipOn' } else { 'Chip' }))
    }

    # The caption, and the sentence it is short for on hover: the head of this page has about 220
    # points for it, and at the window's minimum width even the short form gets an ellipsis.
    $Ui.RangeText.Text = Get-StatsRangeText -Report $report
    $Ui.RangeText.ToolTip = Get-StatsRangeTitle -Report $report

    $Ui.CardsPanel.Children.Clear()
    foreach ($fact in @(
        @{ V = (Format-ActivitySpan $report.Active);     K = (Get-Text -Key 'diary.card.active') }
        @{ V = (Format-ActivitySpan $report.AverageDay); K = (Get-Text -Key 'diary.card.average') }
        @{ V = (Format-ActivitySpan $report.Longest);    K = (Get-Text -Key 'diary.card.longest') }
        @{ V = [string]$report.Switches;                 K = (Get-Text -Key 'diary.card.switches') }
        @{ V = $(if ($report.UsualStart) { '{0}-{1}' -f $report.UsualStart, $report.UsualEnd } else { '-' })
           K = (Get-Text -Key 'diary.card.usualDay') }
        @{ V = [string]$report.Streak;                   K = (Get-Text -Key 'diary.card.streak') })) {
        [void]$Ui.CardsPanel.Children.Add(
            (New-StatsCard -Window $win -Value ([string]$fact.V) -Caption ([string]$fact.K)))
    }

    Update-StatsHours -Ui $Ui -Report $report
    Update-StatsRows -Ui $Ui -Panel $Ui.DisplayRows -Rows $report.Displays
    # By title rather than by key: "Work", not "combo:Work" (see ConvertTo-ModeTitleRows).
    Update-StatsRows -Ui $Ui -Panel $Ui.ModeRows    -Rows (ConvertTo-ModeTitleRows $report.Modes)
    Update-StatsRows -Ui $Ui -Panel $Ui.AppRows     -Rows $report.Apps
    Update-StatsRows -Ui $Ui -Panel $Ui.PairRows    -Rows $report.Pairs
}

function Set-StatsPeriod {
    param($Ui, [int]$Days)

    if ([int]$Ui.Days -eq $Days) { return }
    $Ui.Days = $Days
    Update-StatsView -Ui $Ui
}

# The diary page of a window that has already been built. Separate from the window for the reason
# every other builder here is: a page built without being shown can be tested - and the Settings
# window is what owns the markup now.
function New-StatsUi {
    param($Window, $Store, [int]$Days = 7, [datetime]$Today = (Get-Date))

    $win = $Window

    $ui = [pscustomobject]@{
        Window      = $win
        # The pot as it was when the window opened. The diary goes on counting while it is up, and
        # a window that redrew itself under the reader's eyes would be worse than one that does not.
        Store       = $Store
        Days        = $Days
        Today       = $Today
        Report      = $null
        RangeText   = $win.FindName('RangeText')
        CardsPanel  = $win.FindName('CardsPanel')
        HoursPanel  = $win.FindName('HoursPanel')
        HourLabels  = $win.FindName('HourLabels')
        DisplayRows = $win.FindName('DisplayRows')
        ModeRows    = $win.FindName('ModeRows')
        AppRows     = $win.FindName('AppRows')
        PairRows    = $win.FindName('PairRows')
        Chips       = @()
    }

    # Cleared first: a page can be built over the same window twice (the tests do), and pills
    # added a second time would be eight.
    $win.FindName('PeriodRow').Children.Clear()
    $chips = @()
    foreach ($period in (Get-StatsPeriods)) {
        $chip = New-Object System.Windows.Controls.Button
        $chip.Content = $period.Title
        # Which period a pill stands for is on the pill itself: this window's handlers hold no
        # closures (see the comment about handlers above).
        $chip.Tag = [int]$period.Days
        $chip.Style = $win.FindResource('Chip')
        $chip.add_Click({
            $ui = $script:ActiveStatsUi
            if ($ui) { Set-StatsPeriod -Ui $ui -Days ([int]$this.Tag) }
        })
        [void]$win.FindName('PeriodRow').Children.Add($chip)
        $chips += $chip
    }
    # The last pill's own right margin would leave the row standing off the window's edge, out of
    # line with the cards underneath it.
    if ($chips.Count -gt 0) {
        $chips[-1].Margin = New-Object System.Windows.Thickness 0, 0, 0, 0
    }
    $ui.Chips = $chips

    # Once, and only once. The pills above are thrown away and built again on every call; a button
    # cannot be, because a handler cannot be taken off it — so a page built over the same window a
    # second time (the tests do, and so does render-preview.ps1) would leave this one holding two,
    # and one press would write stats.html twice and open two browser tabs. The Tag is the note
    # that it already has one; nothing else on this button uses it.
    $pageBtn = $win.FindName('PageBtn')
    if (-not $pageBtn.Tag) {
        $pageBtn.Tag = 'wired'
        $pageBtn.add_Click({
            $ui = $script:ActiveStatsUi
            if (-not $ui) { return }
            try { [void](Show-ActivityReport -Days ([int]$ui.Days)) }
            catch {
                Write-DisplayLog "stats: the page failed - $($_.Exception.Message)"
                [void][System.Windows.MessageBox]::Show(
                    (Get-Text -Key 'diary.pageFailed') + [environment]::NewLine +
                    (Get-Text -Key 'diary.pageFailedHint'),
                    'DeskModes', [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning)
            }
        })
    }

    # The page is built — from this point on the handlers find it here.
    $script:ActiveStatsUi = $ui
    Update-StatsView -Ui $ui
    return $ui
}
