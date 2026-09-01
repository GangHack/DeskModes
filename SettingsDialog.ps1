<#
    SettingsDialog.ps1 — ScreenDeck's windows, in WPF: the settings, the mode editor and the
    time picker for the timer.

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

    What they share is the palette, the markup resources and Convert-UiXaml: three windows of
    one application have to look like one, not like three.

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
            MINI = '#3A3A3A'; SCROLL = '#5F5F5F'
            ACCENT = $accent; ACCENTTEXT = (Get-ContrastTextColor $accent)
        }
    }
    $accent = Get-AccentColor
    return @{
        BG = '#F3F3F3'; CARD = '#FBFBFB'; CARDBORDER = '#E5E5E5'; FOOTER = '#F3F3F3'
        TEXT = '#1B1B1B'; DIM = '#5F5F5F'
        INPUT = '#FFFFFF'; INPUTBORDER = '#D6D6D6'; HOVER = '#F0F0F0'; PRESSED = '#E8E8E8'
        MINI = '#EDEDED'; SCROLL = '#9A9A9A'
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
             sections; there is no shadow and no second layer beneath it. -->
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="{StaticResource CardBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="4"/>
            <Setter Property="Padding" Value="16,16"/>
            <Setter Property="Margin" Value="0,0,0,12"/>
        </Style>

        <Style x:Key="Btn" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Padding" Value="14,6"/>
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
            <Setter Property="Padding" Value="14,6"/>
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
                                <TextBlock x:Name="Lbl" Text="Taskbar" FontSize="12"
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
'@

$script:SettingsWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ScreenDeck - Settings"
        Width="640" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" ShowInTaskbar="True"
        Background="%%BG%%" Foreground="%%TEXT%%"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        UseLayoutRounding="True">
    <Window.Resources>
%%RES%%
    </Window.Resources>
    <DockPanel LastChildFill="True">
        <Border DockPanel.Dock="Bottom" Background="{StaticResource FooterBrush}"
                BorderBrush="{StaticResource CardBorderBrush}" BorderThickness="0,1,0,0" Padding="20,12">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="SaveBtn" Style="{StaticResource BtnAccent}" Content="Save" Width="96" IsDefault="True"/>
                <Button x:Name="CancelBtn" Style="{StaticResource Btn}" Content="Cancel" Width="96" Margin="8,0,0,0" IsCancel="True"/>
            </StackPanel>
        </Border>
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="20,16,20,8">
            <StackPanel>
                <Border Style="{StaticResource Card}">
                    <StackPanel>
                        <TextBlock Style="{StaticResource H2}" Text="Your desk"/>
                        <TextBlock Style="{StaticResource Hint}"
                                   Text="Arrange the cards from left to right; the star marks the display that keeps the taskbar."/>
                        <WrapPanel x:Name="DeskPanel"/>
                        <Border x:Name="PreviewBox" CornerRadius="4" Padding="12,12" Margin="0,4,0,0"
                                Background="{StaticResource MiniBrush}"
                                BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1">
                            <StackPanel>
                                <Canvas x:Name="PreviewCanvas" Width="540" Height="132" HorizontalAlignment="Center"/>
                                <TextBlock x:Name="PreviewHint" Style="{StaticResource Hint}" Margin="0,8,0,0"
                                           TextAlignment="Center"
                                           Text="How Windows will arrange the displays."/>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                    <StackPanel>
                        <TextBlock Style="{StaticResource H2}" Text="Modes"/>
                        <TextBlock Style="{StaticResource Hint}"
                                   Text="Everything you can switch to; Edit opens the one place each mode is set up."/>
                        <StackPanel x:Name="ModesPanel"/>
                        <Button x:Name="AddComboBtn" Style="{StaticResource Btn}" Content="Add a combination"
                                HorizontalAlignment="Left" Margin="0,12,0,0"/>
                    </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                    <StackPanel>
                        <TextBlock Style="{StaticResource H2}" Text="Behavior" Margin="0,0,0,4"/>
                        <Grid Margin="0,8,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Margin="0,0,16,0">
                                <TextBlock Style="{StaticResource RowTitle}" Text="Start with Windows"/>
                                <TextBlock Style="{StaticResource RowSub}" Text="The tray icon and the shortcuts come back after a reboot."/>
                            </StackPanel>
                            <CheckBox x:Name="StartupBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                        </Grid>
                        <Grid Margin="0,12,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Margin="0,0,16,0">
                                <TextBlock Style="{StaticResource RowTitle}" Text="Best refresh rate"/>
                                <TextBlock Style="{StaticResource RowSub}" Text="Put every display back to its maximum refresh rate when Windows silently drops it."/>
                            </StackPanel>
                            <CheckBox x:Name="RefreshBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                        </Grid>
                        <Grid Margin="0,12,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Margin="0,0,16,0">
                                <TextBlock Style="{StaticResource RowTitle}" Text="Notifications"/>
                                <TextBlock Style="{StaticResource RowSub}" Text="Show a notification after switching."/>
                            </StackPanel>
                            <CheckBox x:Name="NotifyBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                        </Grid>
                        <Grid Margin="0,12,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Margin="0,0,16,0">
                                <TextBlock Style="{StaticResource RowTitle}" Text="Remember window positions"/>
                                <TextBlock Style="{StaticResource RowSub}" Text="Bring windows back where they were, separately for every display set."/>
                            </StackPanel>
                            <CheckBox x:Name="WindowsBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                        </Grid>
                        <Grid Margin="0,12,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Margin="0,0,16,0">
                                <TextBlock Style="{StaticResource RowTitle}" Text="Restore the last mode"/>
                                <TextBlock Style="{StaticResource RowSub}" Text="After turning the computer on, return to the mode you chose last - not to whatever Windows picked."/>
                            </StackPanel>
                            <CheckBox x:Name="LastModeBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                        </Grid>
                        <Grid Margin="0,12,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Margin="0,0,16,0">
                                <TextBlock Style="{StaticResource RowTitle}" Text="Keep a diary"/>
                                <TextBlock Style="{StaticResource RowSub}" TextWrapping="Wrap"
                                           Text="Local only &#x00B7; No window titles &#x00B7; Delete activity.json to forget everything."/>
                            </StackPanel>
                            <CheckBox x:Name="StatsBox" Grid.Column="1" Style="{StaticResource Toggle}" VerticalAlignment="Center"/>
                        </Grid>
                    </StackPanel>
                </Border>
            </StackPanel>
        </ScrollViewer>
    </DockPanel>
</Window>
'@

$script:ModeEditorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ScreenDeck - Mode"
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
                    Margin="20,16,20,16">
            <Button x:Name="OkBtn" Style="{StaticResource BtnAccent}" Content="Save" Width="90" IsDefault="True"/>
            <Button x:Name="CancelBtn" Style="{StaticResource Btn}" Content="Cancel" Width="90" Margin="8,0,0,0" IsCancel="True"/>
        </StackPanel>
        <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="20,16,20,0" Width="400">
                <TextBlock x:Name="HeadTitle" Style="{StaticResource H1}" Text="Mode"/>
                <TextBlock x:Name="HeadHint" Style="{StaticResource Hint}"/>
                <StackPanel x:Name="ComboPart" Margin="0,12,0,0">
                    <TextBlock Style="{StaticResource H2}" Text="Name"/>
                    <TextBox x:Name="NameBox" Style="{StaticResource Input}" Margin="0,4,0,0"/>
                    <TextBlock Style="{StaticResource H2}" Text="Displays" Margin="0,16,0,0"/>
                    <TextBlock Style="{StaticResource Hint}" Text="Tick every display this combination switches on."/>
                    <StackPanel x:Name="MembersPanel"/>
                    <TextBlock Style="{StaticResource H2}" Text="Taskbar" Margin="0,16,0,0"/>
                    <TextBlock Style="{StaticResource Hint}" Text="Which display keeps the taskbar while this combination is on."/>
                    <ComboBox x:Name="PrimaryBox" Style="{StaticResource Select}" Height="30"/>
                </StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Shortcut" Margin="0,16,0,0"/>
                <TextBlock Style="{StaticResource Hint}" Text="Optional - the mode still works from the tray; click the box and press Ctrl, Alt, Shift or Win plus another key."/>
                <StackPanel Orientation="Horizontal">
                    <TextBox x:Name="HotkeyBox" Style="{StaticResource Input}" Width="150" TextAlignment="Center"/>
                    <Button x:Name="ClearHotkeyBtn" Style="{StaticResource BtnSubtle}" Content="&#x00D7;"
                            FontSize="15" Width="26" Margin="4,0,0,0" VerticalAlignment="Center"
                            ToolTip="Remove this shortcut"/>
                </StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Brightness" Margin="0,16,0,0"/>
                <TextBlock Style="{StaticResource Hint}"
                           Text="Set brightness with this mode; &quot;Ask the monitors&quot; shows which of yours can be set."/>
                <ComboBox x:Name="LevelKindBox" Style="{StaticResource Select}" Height="30" Margin="0,4,0,0"/>
                <Grid x:Name="LevelOnePanel" Margin="0,12,0,0" Visibility="Collapsed">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Slider x:Name="LevelOneSlider" Style="{StaticResource Level}" VerticalAlignment="Center"/>
                    <TextBlock x:Name="LevelOneValue" Grid.Column="1" Width="34" TextAlignment="Right"
                               VerticalAlignment="Center" Margin="12,0,0,0"/>
                </Grid>
                <StackPanel x:Name="LevelRowsPanel" Margin="0,8,0,0"/>
                <Button x:Name="LevelTestBtn" Style="{StaticResource Btn}" Content="Ask the monitors"
                        HorizontalAlignment="Left" Margin="0,12,0,0"/>
                <TextBlock x:Name="LevelNote" Style="{StaticResource RowSub}" Margin="0,8,0,0" TextWrapping="Wrap"/>
            </StackPanel>
        </ScrollViewer>
    </DockPanel>
</Window>
'@

# Parse the markup, substituting the palette. The shared resources arrive on the %%RES%% token.
function Convert-UiXaml {
    param([string]$Xaml, $Palette)

    $text = $Xaml.Replace('%%RES%%', $script:UiResourcesXaml)
    foreach ($key in $Palette.Keys) {
        $text = $text.Replace('%%' + $key + '%%', [string]$Palette[$key])
    }
    return [System.Windows.Markup.XamlReader]::Parse($text)
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

# --- small factories --------------------------------------------------------

function New-UiTextBlock {
    param([string]$Text, $Style, $Window)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    if ($Style) { $t.Style = $Window.FindResource($Style) }
    return $t
}

# What stands in the field when there is no shortcut. As one constant: the text is compared in
# several places, and copies that drifted apart would silently turn "no binding" into "a binding
# that could not be parsed".
$script:NoHotkeyText = 'no shortcut'
# The hint in an empty field while it has focus: "press the keys" has to be said at the moment
# a person is looking at the field, not a paragraph further up.
$script:PressKeysText = 'press the keys'

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
        if (-not (ConvertFrom-HotkeyString $sender.Text)) { $sender.Text = $script:PressKeysText }
    })
    $Box.add_LostFocus({
        param($sender, $e)
        if (-not (ConvertFrom-HotkeyString $sender.Text)) { $sender.Text = $script:NoHotkeyText }
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
            $sender.Text = $script:NoHotkeyText
            return
        }

        if ($mods -eq 0) {
            $sender.Text = 'needs Ctrl / Alt / Shift'
            return
        }

        $vk = [System.Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
        $text = Format-HotkeyString -Modifiers $mods -Vk $vk
        if (ConvertFrom-HotkeyString $text) { $sender.Text = $text }
        else { $sender.Text = 'unsupported key' }
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
        $this.Tag.Text = $script:NoHotkeyText
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
        'solo'   { return 'Display' }
        'combo'  {
            $text = 'Combination  -  ' + (@($Mode.Patterns) -join ' + ')
            if ($Mode.Primary) { $text += '   (taskbar on ' + $Mode.Primary + ')' }
            return $text
        }
        'all'    { return 'Every connected display' }
        'orphan' { return 'Gone from your desk - what was set for it is kept until you remove it' }
    }
    return ''
}

# --- assembling the window --------------------------------------------------

function New-SettingsWindow {
    param(
        $Modes,
        $Settings,
        # The connected monitors: the desk cards and the combo members. Empty — and the
        # corresponding sections simply stand empty (tests).
        $State
    )

    Initialize-WpfRuntime

    $dark = Test-DarkTheme
    $palette = Get-UiPalette -Dark $dark
    $win = Convert-UiXaml -Xaml $script:SettingsWindowXaml -Palette $palette
    Register-WindowTheme -Window $win -Dark $dark

    # The window does not grow past the work area — beyond that it scrolls. Room for the taskbar.
    try { $win.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height - 40 } catch { }   # no work area — no limit then

    $ui = [pscustomobject]@{
        Window            = $win
        Dark              = $dark
        # Mode key -> the text of the key combination. Not input fields: the shortcut lives in
        # the mode editor, and rows are enough for the main window.
        Hotkeys           = [ordered]@{}
        Combos            = (New-Object System.Collections.ArrayList)
        DeletedComboKeys  = @()
        DeskPanel         = $win.FindName('DeskPanel')
        ModesPanel        = $win.FindName('ModesPanel')
        AddComboBtn       = $win.FindName('AddComboBtn')
        SaveBtn           = $win.FindName('SaveBtn')
        CancelBtn         = $win.FindName('CancelBtn')
        StartupBox        = $win.FindName('StartupBox')
        RefreshBox        = $win.FindName('RefreshBox')
        NotifyBox         = $win.FindName('NotifyBox')
        WindowsBox        = $win.FindName('WindowsBox')
        LastModeBox       = $win.FindName('LastModeBox')
        StatsBox          = $win.FindName('StatsBox')
        PreviewCanvas     = $win.FindName('PreviewCanvas')
        PreviewHint       = $win.FindName('PreviewHint')
        # Mode key -> the brightness model (see ConvertTo-LevelModel). Edited in the mode editor,
        # leaves for settings.json on Save.
        Levels            = [ordered]@{}
        Modes             = @($Modes)
        Settings          = $Settings
        State             = @($State)
        Result            = $null
    }

    # The combos go into a working list: the window edits that, and settings.json is rewritten
    # from it whole on Save. OriginalName remembers the name the combo sits under in the file
    # right now: on a rename the shortcut and the audio move by it.
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
                Name         = [string]$name
                Patterns     = $patterns
                Primary      = $prim
                OriginalName = [string]$name
            })
        }
    }

    Import-LevelSettings -Ui $ui -Settings $Settings
    Update-DeskPanel  -Ui $ui
    Update-ModesPanel -Ui $ui -InitialModes $Modes -InitialHotkeys $Settings.hotkeys

    $ui.RefreshBox.IsChecked  = [bool]$Settings.maximizeRefresh
    $ui.NotifyBox.IsChecked   = [bool]$Settings.notifications
    # A key missing from settings.json means "the default", that is, on: the file gets edited by
    # hand, and half the keys may not be in it.
    $ui.WindowsBox.IsChecked  = ($null -eq $Settings.restoreWindows -or [bool]$Settings.restoreWindows)
    $ui.LastModeBox.IsChecked = ($null -eq $Settings.restoreLastMode -or [bool]$Settings.restoreLastMode)
    # The diary is the other way round: a missing key means "off". This is data about a person,
    # and it is not collected by default.
    $ui.StatsBox.IsChecked    = [bool]$Settings.stats

    # The window is built — from this point on the handlers find it here.
    $script:ActiveUi = $ui

    $ui.AddComboBtn.add_Click({
        $ui = $script:ActiveUi
        if (-not $ui) { return }
        Invoke-ModeEditor -Ui $ui -Mode $null -Combo $null
    })

    # Save validates the input BEFORE closing: the old window used to close on a duplicate key
    # combination and throw every edit away; now it stays open.
    $ui.SaveBtn.add_Click({
        $ui = $script:ActiveUi
        if (-not $ui) { return }
        $got = Read-SettingsFromUi -Ui $ui -Settings $ui.Settings
        if (-not $got.Ok) {
            [void][System.Windows.MessageBox]::Show($ui.Window, $got.Problem, 'ScreenDeck',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
        $ui.Result = $got.Settings
        $ui.Window.DialogResult = $true
    })

    return $ui
}

# --- the desk: order and the taskbar ----------------------------------------
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

    # Then everything that is connected but not mentioned in layout, at the end of the row.
    foreach ($m in $state) {
        if ($placed -contains $m) { continue }
        $cards += [pscustomobject]@{ Label = $m.Label; Display = $m }
    }

    foreach ($card in $cards) {
        Add-DeskCard -Ui $Ui -Label $card.Label -Display $card.Display -Total $cards.Count
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

    Update-DeskPreview -Ui $Ui
}

function Add-DeskCard {
    param($Ui, [string]$Label, $Display, [int]$Total = 0)

    $win = $Ui.Window
    $connected = ($null -ne $Display -and -not $Display.Disconnected)

    # The card's width is not a matter of taste: the caption under the mini-screen ("3840 x 2160
    # @ 60 Hz") knows nothing of wrapping, and at type size 12 from the scale it needs 140 points,
    # or the line gets clipped. Three cards of 140 with their margins fit the window's 640.
    #
    # A fourth does not, and the panel is a WrapPanel, so it would drop to a second row — and once
    # the taller window hits MaxHeight a scrollbar appears and takes another 17 points, so only
    # three fit even then. The instruction under the cards says "arrange them from left to right",
    # which a two-row grid makes a lie: the fourth display sits visually left of the third. So from
    # four displays on, the card narrows to whatever divides the row evenly and the caption trims
    # with an ellipsis instead of the layout breaking.
    $outer = New-Object System.Windows.Controls.Border
    $gap = 12
    $outer.Width = 140
    if ($Total -gt 3) {
        # 534 is the panel with the scrollbar already allowed for — narrower is honest, wider gambles.
        $gap = 8
        $outer.Width = [Math]::Floor(534 / $Total) - $gap
    }
    $outer.Margin = New-Object System.Windows.Thickness 0, 0, $gap, 8
    $outer.Padding = New-Object System.Windows.Thickness 8
    $outer.CornerRadius = New-Object System.Windows.CornerRadius 4

    $stack = New-Object System.Windows.Controls.StackPanel
    $outer.Child = $stack

    # A mini-screen with the name inside it — the same metaphor as in Windows settings.
    $mini = New-Object System.Windows.Controls.Border
    $mini.Height = 60
    $mini.CornerRadius = New-Object System.Windows.CornerRadius 4
    $mini.Background = $win.FindResource('MiniBrush')
    $mini.BorderBrush = $win.FindResource('InputBorderBrush')
    $mini.BorderThickness = New-Object System.Windows.Thickness 1
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = $Label
    $name.FontSize = 12
    $name.TextWrapping = 'Wrap'
    $name.TextAlignment = 'Center'
    $name.VerticalAlignment = 'Center'
    $name.Margin = New-Object System.Windows.Thickness 4
    $mini.Child = $name
    [void]$stack.Children.Add($mini)

    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.FontSize = 12
    $sub.TextAlignment = 'Center'
    # On a narrowed card the resolution line no longer fits; an ellipsis says "there is more here",
    # a clipped glyph says nothing. The full text stays available on hover.
    $sub.TextTrimming = 'CharacterEllipsis'
    $sub.Foreground = $win.FindResource('DimBrush')
    $sub.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
    if (-not $connected)      { $sub.Text = 'not connected' }
    elseif ($Display.Active)  { $sub.Text = '{0} x {1} @ {2} Hz' -f $Display.Width, $Display.Height, $Display.Hz }
    else                      { $sub.Text = 'off' }
    $sub.ToolTip = $sub.Text
    [void]$stack.Children.Add($sub)

    $radio = New-Object System.Windows.Controls.RadioButton
    $radio.GroupName = 'taskbar'
    $radio.Style = $win.FindResource('TaskbarPick')
    $radio.HorizontalAlignment = 'Center'
    $radio.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
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

    if (-not $connected) { $outer.Opacity = 0.55 }

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
        ShortId   = $(if ($Display) { [string]$Display.ShortId } else { '' })
        Connected = $connected
        Radio     = $radio
        Width     = $pw
        Height    = $ph
    }

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
        Update-DeskPreview -Ui $this.Tag.Ui
    }
    $left.add_Click($move)
    $right.add_Click($move)

    # The taskbar star changes the picture too: the primary monitor is outlined in the accent
    # colour in it, and the whole layout's shift to the coordinate origin is counted from it.
    $radio.Tag = $Ui
    $radio.add_Checked({ Update-DeskPreview -Ui $this.Tag })

    [void]$panel.Children.Add($outer)
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

# --- the desk preview -------------------------------------------------------
# The cards say what order the monitors stand in, but they do not show what comes out of
# that: screens of different heights (1440 and 2160) line up centred, and strips are left at
# the edges that the cursor will not cross. Without a preview that only comes to light after
# Save — on the live desk.
#
# The coordinates come from Get-LayoutPositions — the very function the switcher works with.
# Not "a similar picture" but exactly what will be applied: if the picture lies, then the
# switch lies too, and it is one and the same bug that is on show.

# A pure function: the cards (in their visible order) -> screens for Get-LayoutPositions.
# The size in pixels comes from the monitor's current mode, or from its best one if it is
# off; an unknown one is counted as an ordinary 16:9 so that it still takes up its place in
# the row.
function ConvertTo-PreviewScreens {
    param($Cards)

    $screens = @()
    $i = 0
    foreach ($info in @($Cards)) {
        if (-not $info) { continue }
        $w = [int]$info.Width
        $h = [int]$info.Height
        if ($w -le 0 -or $h -le 0) { $w = 1920; $h = 1080 }
        $screens += [pscustomobject]@{
            DevicePath = 'preview-' + $i
            Label      = [string]$info.Label
            Width      = $w
            Height     = $h
            Connected  = [bool]$info.Connected
            Primary    = [bool]$info.Primary
        }
        $i++
    }
    return $screens
}

# The coordinates for the picture come through Get-LayoutPositions, the same function the
# switcher works with.
#
# The order has to be handed to it EXPLICITLY, as names in the cards' order: with an empty
# Order every screen has the same rank and it sorts them by name. The first version drew it
# exactly that way — alphabetically: ULTRAFINE, ULTRAGEAR, XG27AQDMGR instead of ULTRAFINE,
# XG27AQDMGR, ULTRAGEAR, that is, it showed a desk other than the one that would come out.
function Get-PreviewPlacement {
    param($Screens)

    $list = @($Screens)
    if ($list.Count -eq 0) { return @{} }
    $primary = @($list | Where-Object { $_.Primary } | Select-Object -First 1)
    return Get-LayoutPositions -Screens $list -Order @($list | ForEach-Object { [string]$_.Label }) `
                               -PrimaryPath $(if ($primary.Count -gt 0) { $primary[0].DevicePath } else { '' })
}

function Update-DeskPreview {
    param($Ui)

    if (-not $Ui -or -not $Ui.PreviewCanvas) { return }
    $canvas = $Ui.PreviewCanvas
    $canvas.Children.Clear()

    # What we know about the cards, in their VISIBLE order: that order is the layout.
    $cards = @()
    foreach ($child in @($Ui.DeskPanel.Children)) {
        $info = $child.Tag
        if (-not $info) { continue }
        $cards += [pscustomobject]@{
            Label     = [string]$info.Label
            Width     = [int]$info.Width
            Height    = [int]$info.Height
            Connected = [bool]$info.Connected
            Primary   = [bool]($info.Radio -and $info.Radio.IsChecked)
        }
    }
    if ($cards.Count -eq 0) { return }

    $screens = @(ConvertTo-PreviewScreens -Cards $cards)
    $positions = Get-PreviewPlacement -Screens $screens

    # The scale: the whole layout has to fit inside the canvas.
    $minX = 0; $maxX = 0; $minY = 0; $maxY = 0
    foreach ($s in $screens) {
        $p = $positions[$s.DevicePath]
        if (-not $p) { continue }
        if ($p.X -lt $minX) { $minX = $p.X }
        if ($p.Y -lt $minY) { $minY = $p.Y }
        if (($p.X + $s.Width) -gt $maxX) { $maxX = $p.X + $s.Width }
        if (($p.Y + $s.Height) -gt $maxY) { $maxY = $p.Y + $s.Height }
    }
    $spanX = [math]::Max(1, $maxX - $minX)
    $spanY = [math]::Max(1, $maxY - $minY)
    # The gap between screens is drawn, but it is not in the coordinates: on a real desk the
    # monitors stand in their bezels and never meet flush.
    $gap = 3
    $room = [double]$canvas.Width - ($gap * ($screens.Count + 1))
    $scale = [math]::Min($room / $spanX, ([double]$canvas.Height - 22) / $spanY)
    if ($scale -le 0) { return }

    $win = $Ui.Window
    $offsetX = ($canvas.Width - ($spanX * $scale) - ($gap * ($screens.Count - 1))) / 2
    $index = 0
    foreach ($s in $screens) {
        $p = $positions[$s.DevicePath]
        if (-not $p) { continue }

        $box = New-Object System.Windows.Controls.Border
        $box.Width = [math]::Max(24, $s.Width * $scale)
        $box.Height = [math]::Max(18, $s.Height * $scale)
        $box.CornerRadius = New-Object System.Windows.CornerRadius 3
        $box.Background = $win.FindResource('CardBrush')
        $box.BorderThickness = New-Object System.Windows.Thickness $(if ($s.Primary) { 2 } else { 1 })
        $box.BorderBrush = $win.FindResource($(if ($s.Primary) { 'AccentBrush' } else { 'InputBorderBrush' }))
        if (-not $s.Connected) { $box.Opacity = 0.5 }
        $box.ToolTip = '{0} - {1} x {2}{3}' -f $s.Label, $s.Width, $s.Height,
                        $(if ($s.Primary) { ', taskbar here' } else { '' })

        # The one type size off the scale, and deliberately so: the caption lives inside a
        # rectangle drawn at the desk's scale, and that can be 24 points wide. Caption 12 will
        # not fit in it, and this is not text to read — it is a label on a drawing; the ToolTip
        # says the same thing as a full line.
        $text = New-Object System.Windows.Controls.TextBlock
        $text.Text = '{0}{1}{2} x {3}' -f $s.Label, [environment]::NewLine, $s.Width, $s.Height
        $text.FontSize = 9.5
        $text.TextAlignment = 'Center'
        $text.TextWrapping = 'Wrap'
        $text.VerticalAlignment = 'Center'
        $text.HorizontalAlignment = 'Center'
        $text.Foreground = $win.FindResource('DimBrush')
        $box.Child = $text

        [void]$canvas.Children.Add($box)
        [System.Windows.Controls.Canvas]::SetLeft($box, $offsetX + (($p.X - $minX) * $scale) + ($gap * $index))
        [System.Windows.Controls.Canvas]::SetTop($box, ($p.Y - $minY) * $scale)
        $index++
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

# Every model of the window -> what leaves for settings.json. Modes with no brightness do not
# reach the file at all: a key with a dummy dictionary in it would look like a setting that
# does not exist. A pure function.
function ConvertTo-BrightnessSettings {
    param($Levels)

    $out = [ordered]@{}
    if (-not $Levels) { return $out }
    foreach ($key in @($Levels.Keys)) {
        $value = ConvertFrom-LevelModel $Levels[$key]
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

$script:LevelKindTitles = [ordered]@{
    none = 'leave the brightness alone'
    one  = 'one level for every display of this mode'
    each = 'a level for each display'
}

# Brightness from the settings into the window's working models, keyed by mode. The mode editor
# edits them, and they leave on Save (see ConvertTo-BrightnessSettings).
#
# No empty models are created here: "the key exists but has no brightness in it" is not a
# setting but rubbish out of the file ({} or a number that is not a number). Since it is never
# put there, "empty means absent" does not have to be checked by everyone who looks at the map.
function Import-LevelSettings {
    param($Ui, $Settings)

    $Ui.Levels = [ordered]@{}
    if ($Settings -and $Settings.brightness) {
        foreach ($key in @($Settings.brightness.Keys)) {
            $model = ConvertTo-LevelModel $Settings.brightness[$key]
            if ($null -ne (ConvertFrom-LevelModel $model)) { $Ui.Levels[[string]$key] = $model }
        }
    }
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

# The list of entry forms, for the editor. The order of the items IS the order of
# $script:LevelKindTitles: the item in Update-EditorLevel is picked by it as well.
function Initialize-EditorLevel {
    param($Editor)

    $Editor.LevelBusy = $true
    try {
        $Editor.LevelKindBox.Items.Clear()
        foreach ($kind in @($script:LevelKindTitles.Keys)) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = [string]$script:LevelKindTitles[$kind]
            $item.Tag = [string]$kind
            [void]$Editor.LevelKindBox.Items.Add($item)
        }
    }
    finally { $Editor.LevelBusy = $false }

    Update-EditorLevel -Editor $Editor
}

# Show the editor's model: the form choice, one slider, or a row per monitor.
function Update-EditorLevel {
    param($Editor)

    $model = $Editor.Level
    if (-not $model) { return }

    $Editor.LevelBusy = $true
    try {
        $index = @($script:LevelKindTitles.Keys).IndexOf([string]$model.Kind)
        if ($index -lt 0) { $index = 0 }
        $Editor.LevelKindBox.SelectedIndex = $index

        $Editor.LevelOnePanel.Visibility = $(if ($model.Kind -eq 'one') { 'Visible' } else { 'Collapsed' })
        $Editor.LevelOneSlider.Value = [double][int]$model.Value
        $Editor.LevelOneValue.Text = [string][int]$model.Value

        $Editor.LevelRowsPanel.Children.Clear()
        if ($model.Kind -eq 'each') {
            foreach ($name in @(Get-LevelRowNames -Displays (Get-EditorDisplayNames -Editor $Editor) -Map $model.Map)) {
                Add-LevelRow -Editor $Editor -Model $model -Name $name
            }
        }
    }
    finally { $Editor.LevelBusy = $false }
}

function Add-LevelRow {
    param($Editor, $Model, [string]$Name)

    $win = $Editor.Window
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
    $check.Content = $Name
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
    # of this window: .GetNewClosure() is banned here (see the header).
    $row = [pscustomobject]@{ Owner = $Editor; Model = $Model; Name = $Name; Slider = $slider; Value = $value; Check = $check }
    $check.Tag = $row
    $slider.Tag = $row

    $check.add_Click({
        $row = $this.Tag
        if ($row.Owner.LevelBusy) { return }
        if ($this.IsChecked) {
            $row.Model.Map[$row.Name] = [int]$row.Slider.Value
            $row.Slider.IsEnabled = $true
            $row.Value.Text = [string][int]$row.Slider.Value
            $row.Value.Foreground = $row.Owner.Window.FindResource('TextBrush')
        }
        else {
            $row.Model.Map.Remove($row.Name)
            $row.Slider.IsEnabled = $false
            $row.Value.Text = 'off'
            $row.Value.Foreground = $row.Owner.Window.FindResource('DimBrush')
        }
    })

    $slider.add_ValueChanged({
        $row = $this.Tag
        if ($row.Owner.LevelBusy) { return }
        if (-not $row.Check.IsChecked) { return }
        $row.Model.Map[$row.Name] = [int]$this.Value
        $row.Value.Text = [string][int]$this.Value
    })

    [void]$Editor.LevelRowsPanel.Children.Add($grid)
}

# "Ask the monitors" — query DDC/CI right now. As a button of its own rather than on opening
# the window: one query costs tens of milliseconds per monitor, and on a stuck bus up to a
# second with the retries, and there is no reason to pay that for every opening of the
# settings.
function Invoke-LevelProbe {
    param($Editor)

    $Editor.LevelNote.Text = 'asking...'
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
        $Editor.LevelNote.Text = "could not ask the monitors - $($_.Exception.Message)"
        return
    }

    # DDC hands back the output's name (\\.\DISPLAY1); a person needs the monitor's name.
    $byOutput = @{}
    foreach ($m in @($Editor.State)) { if ($m.Output) { $byOutput[[string]$m.Output] = [string]$m.Label } }

    $good = @()
    $bad = @()
    foreach ($a in $answers) {
        $label = $(if ($byOutput.Contains([string]$a.Device)) { $byOutput[[string]$a.Device] } else { [string]$a.Device })
        if ($a.CanBrightness) { $good += ('{0} ({1})' -f $label, $a.Brightness) } else { $bad += $label }
    }

    $parts = @()
    if ($good.Count -gt 0) { $parts += 'answers: ' + ($good -join ', ') }
    if ($bad.Count -gt 0)  { $parts += 'no answer: ' + ($bad -join ', ') }
    if ($parts.Count -eq 0) { $parts += 'nobody answered - only displays that are ON can be asked' }
    # We always say something about the sleeping ones: they are not in the answer at all, and
    # without this line it would look as though the monitor cannot do it.
    $Editor.LevelNote.Text = ($parts -join '; ') + '. Sleeping displays cannot be asked.'
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

    if ($Ui.Hotkeys.Contains($Key)) { $Ui.Hotkeys.Remove($Key) }
    if ($Ui.Levels.Contains($Key))  { $Ui.Levels.Remove($Key) }
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
                Name         = [string]$Edited.Name
                Patterns     = @($Edited.Patterns)
                Primary      = [string]$Edited.Primary
                OriginalName = ''
            })
        }
        $newKey = 'combo:' + [string]$Edited.Name
        # A name that was deleted in this same session came back — the deletion is cancelled.
        $Ui.DeletedComboKeys = @($Ui.DeletedComboKeys | Where-Object { $_ -ne $newKey })
    }

    # A rename takes the shortcut and the brightness away to the new key: under the old one a
    # ghost setting would be left that shows up in no window. Read-SettingsFromUi does the same
    # for the audio and the commands — there the key is only known at Save time.
    if ($oldKey -and $newKey -and $oldKey -ne $newKey) {
        Remove-UiModeKey -Ui $Ui -Key $oldKey
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
        # A model with no brightness is not a setting: a key holding one must not be in the map
        # (see Import-LevelSettings).
        if ($null -ne $Edited.PSObject.Properties['Level']) {
            if ($null -ne (ConvertFrom-LevelModel $Edited.Level)) { $Ui.Levels[$newKey] = $Edited.Level }
            elseif ($Ui.Levels.Contains($newKey)) { $Ui.Levels.Remove($newKey) }
        }
    }

    Update-ModesPanel -Ui $Ui
}

function Remove-UiCombo {
    param($Ui, $Combo)

    # Both keys are remembered: under OriginalName the combo sits in the file (audio, commands),
    # and under its present name in this window's shortcuts and brightness.
    $keys = @('combo:' + $Combo.Name)
    if ($Combo.OriginalName) { $keys += ('combo:' + $Combo.OriginalName) }
    $Ui.DeletedComboKeys = @($Ui.DeletedComboKeys) + $keys
    $Ui.Combos.Remove($Combo)
    foreach ($key in $keys) { Remove-UiModeKey -Ui $Ui -Key $key }
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
        $headTitle.Text = $(if ($Combo) { 'Combination' } else { 'New combination' })
        if ($Combo) { $headHint.Visibility = 'Collapsed' }
        else {
            $headHint.Text = 'A named set of displays with its own tray entry, optional shortcut and brightness.'
        }
    }
    else {
        $Window.FindName('ComboPart').Visibility = 'Collapsed'
        $headTitle.Text = $(if ($Mode) { [string]$Mode.Title } else { 'Mode' })
        $headHint.Text = $(if ($Kind -eq 'all') {
            'Every display at once, with its own shortcut and brightness.'
        } else {
            'One display on and the rest off, with its own shortcut and brightness.'
        })
    }

    $Window.Title = 'ScreenDeck - ' + $headTitle.Text
}

# A combo's membership: the members' checkboxes and the "whose taskbar" dropdown. Returns the
# list of checkboxes — Read-ModeFromUi reads them, and the Tag of each holds the exact string
# that will leave for settings.json.
#
# The checkboxes are every connected monitor, then the combo's patterns that matched none of
# them: the monitor was taken away, but throwing it out of the combo silently is not allowed.
function Add-ComboMemberChecks {
    param($Window, $Combo, $Live)

    $membersPanel = $Window.FindName('MembersPanel')
    $primaryBox = $Window.FindName('PrimaryBox')

    $patterns = @()
    if ($Combo) {
        $Window.FindName('NameBox').Text = [string]$Combo.Name
        $patterns = @($Combo.Patterns)
    }

    $checks = @()
    foreach ($m in $Live) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $Window.FindResource('Check')
        $cb.Content = $m.Label
        $cb.Tag = [string]$m.Label
        foreach ($pat in $patterns) {
            if (Test-DisplayNameMatch -Pattern $pat -Label $m.Label -ShortId $m.ShortId) { $cb.IsChecked = $true; break }
        }
        [void]$membersPanel.Children.Add($cb)
        $checks += $cb
    }
    foreach ($pat in $patterns) {
        $matched = $false
        foreach ($m in $Live) {
            if (Test-DisplayNameMatch -Pattern $pat -Label $m.Label -ShortId $m.ShortId) { $matched = $true; break }
        }
        if ($matched) { continue }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $Window.FindResource('Check')
        $cb.Content = ([string]$pat + '   (not connected)')
        $cb.Tag = [string]$pat
        $cb.IsChecked = $true
        [void]$membersPanel.Children.Add($cb)
        $checks += $cb
    }

    [void]$primaryBox.Items.Add('Follow the usual rules')
    foreach ($cb in $checks) { [void]$primaryBox.Items.Add([string]$cb.Tag) }
    $primaryBox.SelectedIndex = 0
    if ($Combo -and $Combo.Primary) {
        foreach ($cb in $checks) {
            if (Test-DisplayNameMatch -Pattern ([string]$Combo.Primary) -Label ([string]$cb.Tag) -ShortId '') {
                $primaryBox.SelectedItem = [string]$cb.Tag
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
        $Editor.HotkeyBox.Text = $(if ($inherited) { $inherited.Text } else { $script:NoHotkeyText })
    }

    $level = $(if ($key -and $Editor.Levels.Contains($key)) { $Editor.Levels[$key] } else { $null })
    $shownLevel = Get-LevelFingerprint $Editor.Level
    if (-not $shownLevel -or $shownLevel -eq $Editor.AutoLevel) {
        $Editor.Level = Copy-LevelModel $level
        $Editor.AutoLevel = Get-LevelFingerprint $Editor.Level
        Update-EditorLevel -Editor $Editor
    }
}

function New-ModeEditorWindow {
    param(
        # The mode being edited. $null — we are creating a new combo.
        $Mode,
        # The combo's working record from the window's list. $null — the mode is not a combo,
        # or the combo has not been created yet.
        $Combo,
        $State,
        # The shortcuts and the brightness of ALL the window's modes, as "mode key -> value"
        # pairs. Not two ready values: a combo's key follows the name in the field, and while
        # the name is being typed the editor has to find both what will go to this name and
        # what to count as somebody else's shortcut. Brightness is edited as a COPY: Cancel
        # has to leave the window with what was there.
        $Hotkeys,
        $Levels,
        [string[]]$TakenNames = @(),
        $Owner,
        [bool]$Dark
    )

    Initialize-WpfRuntime
    $palette = Get-UiPalette -Dark $Dark
    $win = Convert-UiXaml -Xaml $script:ModeEditorXaml -Palette $palette
    Register-WindowTheme -Window $win -Dark $Dark
    if ($Owner) { $win.Owner = $Owner }

    # The window does not grow past the work area — beyond that it scrolls, as the main one does.
    try { $win.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height - 80 } catch { }   # no work area — no limit then

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
    if (-not $Hotkeys) { $Hotkeys = [ordered]@{} }
    if (-not $Levels)  { $Levels  = [ordered]@{} }
    $hotkeyText = $(if ($key -and $Hotkeys.Contains($key)) { [string]$Hotkeys[$key] } else { '' })
    $level = $(if ($key -and $Levels.Contains($key)) { $Levels[$key] } else { $null })

    $hotkeyBox.Cursor = [System.Windows.Input.Cursors]::Hand
    Register-HotkeyCapture -Box $hotkeyBox
    $parsedHotkey = ConvertFrom-HotkeyString $hotkeyText
    $hotkeyBox.Text = $(if ($parsedHotkey) { $parsedHotkey.Text } else { $script:NoHotkeyText })

    $clearHotkey = $win.FindName('ClearHotkeyBtn')
    $clearHotkey.IsEnabled = [bool]$parsedHotkey
    Register-HotkeyClearButton -Box $hotkeyBox -Button $clearHotkey

    $checks = @()
    if ($kind -eq 'combo') {
        $checks = @(Add-ComboMemberChecks -Window $win -Combo $Combo `
                        -Live @($State | Where-Object { $_ -and -not $_.Disconnected }))
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
        LevelKindBox   = $win.FindName('LevelKindBox')
        LevelOnePanel  = $win.FindName('LevelOnePanel')
        LevelOneSlider = $win.FindName('LevelOneSlider')
        LevelOneValue  = $win.FindName('LevelOneValue')
        LevelRowsPanel = $win.FindName('LevelRowsPanel')
        LevelTestBtn   = $win.FindName('LevelTestBtn')
        LevelNote      = $win.FindName('LevelNote')
        # While the panel is being rebuilt the sliders' handlers keep quiet: otherwise setting
        # a value in code would immediately count as a person's edit.
        LevelBusy      = $false
        Level          = (Copy-LevelModel $level)
        State          = @($State)
        TakenNames     = @($TakenNames)
        Hotkeys        = $Hotkeys
        Levels         = $Levels
        # Whose key is in the fields right now, and what we filled into them ourselves: we do
        # not overwrite a person's edit with a name (see Sync-EditorInheritance).
        ShownKey       = $key
        AutoHotkey     = ''
        AutoLevel      = ''
        Result         = $null
    }
    # The handlers find the editor here rather than in a closure: see the comment about
    # handlers above. The editor is modal, so one place is enough.
    $script:ActiveEditor = $ed

    Initialize-EditorLevel -Editor $ed

    # The name is watched rather than asked for on OK: the name is the mode key, and whose
    # settings the editor shows and what it counts as a foreign shortcut both depend on it.
    $nameBox.add_TextChanged({
        $ed = $script:ActiveEditor
        if (-not $ed) { return }
        Sync-EditorInheritance -Editor $ed
    })

    $ed.LevelKindBox.add_SelectionChanged({
        $ed = $script:ActiveEditor
        if (-not $ed -or $ed.LevelBusy) { return }
        $item = $ed.LevelKindBox.SelectedItem
        if (-not $item) { return }
        $ed.Level.Kind = [string]$item.Tag
        # The move from "one number" to "one each": we fill the mode's monitors with that very
        # number. That way a person gets what they were looking at and edits from there rather
        # than from an empty list. The move back does not erase the map — coming back, they
        # will find their values in place.
        if ($ed.Level.Kind -eq 'each' -and $ed.Level.Map.Count -eq 0) {
            foreach ($name in @(Get-EditorDisplayNames -Editor $ed)) {
                $ed.Level.Map[[string]$name] = [int]$ed.Level.Value
            }
        }
        Update-EditorLevel -Editor $ed
    })

    $ed.LevelOneSlider.add_ValueChanged({
        $ed = $script:ActiveEditor
        if (-not $ed -or $ed.LevelBusy) { return }
        $ed.Level.Value = [int]$ed.LevelOneSlider.Value
        $ed.LevelOneValue.Text = [string][int]$ed.LevelOneSlider.Value
    })

    $ed.LevelTestBtn.add_Click({
        $ed = $script:ActiveEditor
        if (-not $ed) { return }
        Invoke-LevelProbe -Editor $ed
    })

    # A monitor was taken off the combo — its brightness row follows, without waiting for
    # Save: otherwise a slider would stand under a monitor the mode no longer has.
    foreach ($cb in $checks) {
        $cb.add_Click({
            $ed = $script:ActiveEditor
            if (-not $ed -or $ed.LevelBusy) { return }
            if ([string]$ed.Level.Kind -eq 'each') { Update-EditorLevel -Editor $ed }
        })
    }

    $okBtn.add_Click({
        $ed = $script:ActiveEditor
        if (-not $ed) { return }
        $got = Read-ModeFromUi -Editor $ed
        if (-not $got.Ok) {
            [void][System.Windows.MessageBox]::Show($ed.Window, $got.Problem, 'ScreenDeck',
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
            if ([string]$key -eq $selfKey) { continue }
            $other = ConvertFrom-HotkeyString ([string]$Editor.Hotkeys[$key])
            if (-not $other -or $other.Text -ne $hk) { continue }
            return [pscustomobject]@{
                Ok = $false; Mode = $null
                Problem = "$hk already drives '$(Get-ModeTitleFromKey ([string]$key))'. Each combination of keys can only drive one mode."
            }
        }
    }

    # For a monitor mode and for "all" the membership is set by the desk: only the shortcut and
    # the brightness are edited, and there is nothing more to check.
    if ($Editor.Kind -ne 'combo') {
        return [pscustomobject]@{
            Ok = $true
            Mode = [pscustomobject]@{ Hotkey = $hk; Level = $Editor.Level }
            Problem = ''
        }
    }

    $name = $Editor.NameBox.Text.Trim()
    $chosen = @($Editor.Checks | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    $prim = ''
    if ($Editor.PrimaryBox.SelectedIndex -gt 0) { $prim = [string]$Editor.PrimaryBox.SelectedItem }

    $problem = ''
    if (-not $name) { $problem = 'Give the combination a name - it becomes its menu entry.' }
    elseif (@($Editor.TakenNames | Where-Object { $_ -and $_ -ieq $name }).Count -gt 0) {
        $problem = "A combination called '$name' already exists."
    }
    elseif ($chosen.Count -eq 0) { $problem = 'Tick at least one display.' }
    elseif ($prim -and $chosen -notcontains $prim) {
        $problem = 'The taskbar display must be one of the ticked displays.'
    }
    if ($problem) { return [pscustomobject]@{ Ok = $false; Mode = $null; Problem = $problem } }

    return [pscustomobject]@{
        Ok = $true
        Mode = [pscustomobject]@{ Name = $name; Patterns = $chosen; Primary = $prim; Hotkey = $hk; Level = $Editor.Level }
        Problem = ''
    }
}

# Showing the editor. Returns the mode's edit, or $null on cancel.
function Show-ModeEditor {
    param(
        $Mode,
        $Combo,
        $State,
        $Hotkeys,
        $Levels,
        [string[]]$TakenNames = @(),
        $Owner,
        [bool]$Dark
    )

    $ed = New-ModeEditorWindow -Mode $Mode -Combo $Combo -State $State `
                               -Hotkeys $Hotkeys -Levels $Levels -TakenNames $TakenNames `
                               -Owner $Owner -Dark $Dark
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
    param($Ui, $Mode, $Combo)

    # The shortcuts and the brightness are handed over as whole maps: the editor finds its own
    # record by key itself, and that key changes along with the name while the window is open.
    $taken = @($Ui.Combos | Where-Object { -not $Combo -or $_ -ne $Combo } | ForEach-Object { [string]$_.Name })

    $made = Show-ModeEditor -Mode $Mode -Combo $Combo -State $Ui.State `
                            -Hotkeys $Ui.Hotkeys -Levels $Ui.Levels -TakenNames $taken `
                            -Owner $Ui.Window -Dark $Ui.Dark
    if ($made) { Set-UiMode -Ui $Ui -Mode $Mode -Combo $Combo -Edited $made }
}

# --- the mode list ----------------------------------------------------------
# Rebuilt on every edit: the modes are derived from the desk and from the combo list, and the
# rows have to show what will be there after Save. The shortcut and the brightness live not
# in the rows but in $Ui.Hotkeys and $Ui.Levels: a row only shows them, the editor edits them.

# The short truth about a mode's brightness goes into the row's caption. Otherwise a setting
# hidden behind an Edit button is invisible until every mode has been opened in turn.
function Get-LevelSummary {
    param($Model)

    if (-not $Model) { return '' }
    switch ([string]$Model.Kind) {
        'one'  { return 'brightness ' + [string][int]$Model.Value }
        'each' {
            if (-not $Model.Map -or $Model.Map.Count -eq 0) { return '' }
            return 'brightness per display'
        }
    }
    return ''
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
    # (RegisterHotKey works whether a monitor is there or not), and the brightness hangs on a
    # key that no longer exists; both can only be seen and cleared from here. The window's maps
    # hold only real settings (see Import-LevelSettings), so any unfamiliar key here is a row.
    $known = @($modes | ForEach-Object { [string]$_.Key })
    $strays = @()
    foreach ($key in @(@($Ui.Hotkeys.Keys) + @($Ui.Levels.Keys))) {
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
    $Ui.Hotkeys = Get-MapInModeOrder -Map $Ui.Hotkeys -Modes $modes
    $Ui.Levels  = Get-MapInModeOrder -Map $Ui.Levels  -Modes $modes

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
            $text = [string]$InitialHotkeys[$key]
            if ($text) { $Ui.Hotkeys[[string]$key] = $text }
        }
    }

    $modes = @(Resolve-PanelModes -Ui $Ui -InitialModes $InitialModes)

    $Ui.ModesPanel.Children.Clear()

    foreach ($mode in $modes) {
        $key = [string]$mode.Key
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = New-Object System.Windows.Thickness 0, 4, 0, 4
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
        $textStack.Margin = New-Object System.Windows.Thickness 0, 0, 12, 0
        $title = New-UiTextBlock -Text $mode.Title -Style 'RowTitle' -Window $win
        if (-not $mode.Available -and $mode.Kind -ne 'orphan') {
            $title.Text = [string]$mode.Title + '   (not connected)'
            $title.Foreground = $win.FindResource('DimBrush')
        }
        if ($mode.Kind -eq 'orphan') { $title.Foreground = $win.FindResource('DimBrush') }
        [void]$textStack.Children.Add($title)

        $subText = Get-ModeSubtitle -Mode $mode
        $levelText = ''
        if ($Ui.Levels.Contains($key)) { $levelText = Get-LevelSummary -Model $Ui.Levels[$key] }
        if ($levelText) { $subText = $(if ($subText) { $subText + '  -  ' + $levelText } else { $levelText }) }
        if ($subText) {
            $sub = New-UiTextBlock -Text $subText -Style 'RowSub' -Window $win
            [void]$textStack.Children.Add($sub)
        }
        [void]$row.Children.Add($textStack)

        # The shortcut as a label rather than a field: it is edited in the same place as
        # everything else about the mode. Its space is always taken, otherwise the buttons would
        # jump along the row from one binding to the next.
        $shortcut = [string]$(if ($Ui.Hotkeys.Contains($key)) { $Ui.Hotkeys[$key] } else { '' })
        $keyText = New-UiTextBlock -Text $(if ($shortcut) { $shortcut } else { $script:NoHotkeyText }) `
                                   -Style 'RowSub' -Window $win
        $keyText.MinWidth = 110
        $keyText.TextAlignment = 'Right'
        $keyText.VerticalAlignment = 'Center'
        $keyText.Margin = New-Object System.Windows.Thickness 0, 0, 12, 0
        if ($shortcut) { $keyText.Foreground = $win.FindResource('TextBrush') }
        [System.Windows.Controls.Grid]::SetColumn($keyText, 1)
        [void]$row.Children.Add($keyText)

        # Buttons with a border, specifically, not dimmed labels: the very first person took the
        # flat Edit/Remove for captions and could not find how to delete a combo.
        if ($mode.Kind -ne 'orphan') {
            $edit = New-Object System.Windows.Controls.Button
            $edit.Content = 'Edit'
            $edit.Style = $win.FindResource('BtnSmall')
            $edit.VerticalAlignment = 'Center'
            # Which mode a button answers for is on the button itself: this window's handlers
            # hold no closures (see the comment above).
            $edit.Tag = $mode
            [System.Windows.Controls.Grid]::SetColumn($edit, 2)
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
            $remove.Content = 'Remove'
            $remove.Style = $win.FindResource('BtnSmall')
            $remove.VerticalAlignment = 'Center'
            $remove.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
            $remove.Tag = $mode
            [System.Windows.Controls.Grid]::SetColumn($remove, 3)
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

# --- moving mode keys -------------------------------------------------------
# A combo's key is `combo:<name>`, which means renaming it in the window changes the key
# and deleting it takes the key away. Everything tied to mode keys (audio, commands,
# brightness, contrast, rules, "a monitor came up") has to move along with them —
# otherwise a ghost setting is left that shows up in no window at all, or a rule that
# every fifteen seconds heads for a mode that does not exist.

# Old key -> new one, for the combos that were renamed in the window.
#
# The dictionary is ORDERED, in the order of the combo list, and that is not cosmetic: two
# renames can line up into a chain (one combo was named "B", and another freed "B" up at
# the same time), and then whether the first entry reaches its new key depends on the order
# they are applied in. Let that order be predictable.
function Get-ComboRenames {
    param($Combos)

    $renames = [ordered]@{}
    foreach ($c in @($Combos)) {
        if (-not $c.OriginalName -or $c.OriginalName -eq $c.Name) { continue }
        $renames['combo:' + $c.OriginalName] = 'combo:' + $c.Name
    }
    return $renames
}

# A "mode key -> value" dictionary after the renames and deletions. An entry moves IN
# PLACE: dictionaries go out to settings.json as they are, and a key appended to the end of
# a section would look in a git diff like an edit nobody made. $What is for the log only.
function Move-ModeKeyedEntries {
    param($Source, $Renames, [string[]]$Gone = @(), [string]$What = 'setting')

    $moved = [ordered]@{}
    if (-not $Source) { return $moved }

    # Keys that are not moving anywhere: their values are their own, and they owe their
    # place to nobody who is moving.
    $taken = @{}
    foreach ($k in @($Source.Keys)) {
        if (-not $Renames.Contains([string]$k)) { $taken[[string]$k] = $true }
    }

    foreach ($k in @($Source.Keys)) {
        $key = [string]$k
        if ($Renames.Contains($key)) {
            $new = [string]$Renames[$key]
            # The new key is taken by a value of its own — that one matters more than the
            # one moving, and the mover is lost together with the old name.
            if ($taken[$new]) { continue }
            $taken[$new] = $true
            $key = $new
        }
        if ($Gone -contains $key) {
            Write-DisplayLog "settings: dropped the $What entry for removed $key"
            continue
        }
        if ($moved.Contains($key)) { continue }
        $moved[$key] = $Source[$k]
    }
    return $moved
}

# The rules after the renames and deletions. REBUILT rather than edited in place: the result
# of Save is a copy, and a failed write to disk must not leave an edit in the settings the
# tray is living with.
function Move-RuleModeKeys {
    param($Rules, $Renames, [string[]]$Gone = @())

    $out = @()
    foreach ($r in @($Rules)) {
        if (-not $r) { continue }
        $copy = [ordered]@{}
        if ($r -is [System.Collections.IDictionary]) {
            foreach ($k in @($r.Keys)) { $copy[$k] = $r[$k] }
        }
        else {
            foreach ($p in $r.PSObject.Properties) { $copy[$p.Name] = $p.Value }
        }
        foreach ($field in 'mode', 'back') {
            $v = [string]$copy[$field]
            if (-not $v) { continue }
            if ($Renames.Contains($v)) { $copy[$field] = [string]$Renames[$v] }
            elseif ($Gone -contains $v) {
                # An empty "where to go back to" means "to wherever the desk was before it
                # fired", a legitimate value (see Get-RuleDecision).
                $copy[$field] = ''
                Write-DisplayLog "settings: dropped the $field of a rule for removed $v"
            }
        }
        # A rule with no mode, though, is no longer a rule: there is nowhere to go.
        if (-not [string]$copy['mode']) {
            Write-DisplayLog 'settings: dropped a rule whose mode was removed'
            continue
        }
        $out += $copy
    }
    return @($out)
}

# --- collecting the settings out of the window ------------------------------
# A function of its own, and without showing the window: this is the testable half of Save.
# Returns Ok/Settings/Problem; on Problem the window stays open.

function Read-SettingsFromUi {
    param($Ui, $Settings)

    # The shortcut combinations, with a duplicate check: two modes on one key is an
    # unresolvable ambiguity, not a warning.
    $newHotkeys = [ordered]@{}
    $seen = @{}
    foreach ($key in @($Ui.Hotkeys.Keys)) {
        $parsed = ConvertFrom-HotkeyString ([string]$Ui.Hotkeys[$key])
        if (-not $parsed) { continue }
        if ($seen.ContainsKey($parsed.Text)) {
            Write-DisplayLog "settings dialog: rejected save - $($parsed.Text) is assigned to both $($seen[$parsed.Text]) and $key"
            return [pscustomobject]@{
                Ok = $false; Settings = $null
                Problem = "$($parsed.Text) is assigned twice. Each combination of keys can only drive one mode."
            }
        }
        $seen[$parsed.Text] = $key
        $newHotkeys[$key] = $parsed.Text
    }

    # Saved into a COPY rather than into the object we were handed: $Settings is the very
    # dictionary the tray lives with, and a failed write to disk must not leave three
    # different versions of the settings (in memory, on disk, and in the registered keys).
    $updated = Get-DefaultSettings
    $updated.hotkeys = $newHotkeys
    $updated.maximizeRefresh = [bool]$Ui.RefreshBox.IsChecked
    $updated.notifications = [bool]$Ui.NotifyBox.IsChecked
    $updated.restoreWindows = [bool]$Ui.WindowsBox.IsChecked
    $updated.restoreLastMode = [bool]$Ui.LastModeBox.IsChecked
    $updated.stats = [bool]$Ui.StatsBox.IsChecked

    # The window edits only what is in it; the other fields have to travel straight through
    # and NOT leave as defaults — layout and primary have already been lost that way. Every
    # field is carried over except the ones holding form elements, so that each new setting
    # without an element of its own does not bring this bug back.
    $fromForm = @('hotkeys', 'maximizeRefresh', 'notifications', 'restoreWindows',
                  'restoreLastMode', 'stats', 'layout', 'primary', 'combos', 'audio')
    foreach ($k in @($Settings.Keys)) {
        if ($fromForm -contains $k) { continue }
        $updated[$k] = $Settings[$k]
    }

    # The layout and the taskbar come from the desk cards, in their visible order.
    $labels = @()
    $primary = ''
    foreach ($card in @($Ui.DeskPanel.Children)) {
        $info = $card.Tag
        if (-not $info) { continue }
        $labels += [string]$info.Label
        if ($info.Radio -and $info.Radio.IsChecked) { $primary = [string]$info.Label }
    }
    $updated.layout = $labels
    # No star was set — leave it as it was: an empty string would erase a choice the person
    # never cancelled.
    $updated.primary = $(if ($primary) { $primary } else { [string]$Settings.primary })

    $updated.combos = ConvertTo-ComboSettings -Combos $Ui.Combos

    # Audio, commands, brightness and contrast are tied to mode keys, and for combos those
    # keys change along with the name: an entry follows a rename and dies with a deletion.
    # Otherwise a ghost setting would be left that shows up in no window. One loop for all
    # four: the next setting tied to a mode must not bring this bug back.
    $currentComboKeys = @($Ui.Combos | ForEach-Object { 'combo:' + $_.Name })
    $renames = Get-ComboRenames -Combos $Ui.Combos
    $gone = @(@($Ui.DeletedComboKeys) | Where-Object { $_ -and $currentComboKeys -notcontains $_ })

    foreach ($field in 'audio', 'hooks', 'brightness', 'contrast') {
        # Brightness arrives from the card with the sliders, the rest from the settings as
        # they were: the window does not edit those. Hence the two different move maps.
        # Audio, commands and contrast sit under THE keys that are in the file — those need
        # renaming. Brightness, though, Set-UiMode moves onto the new key the moment it is
        # edited, and applying the map a second time is not merely redundant: a combo that
        # took over the freed name would coincide with the renaming's SOURCE and silently
        # lose its own brightness.
        $source = $Settings[$field]
        $map = $renames
        if ($field -eq 'brightness') {
            $source = ConvertTo-BrightnessSettings -Levels $Ui.Levels
            $map = [ordered]@{}
        }
        $updated[$field] = Move-ModeKeyedEntries -Source $source -Renames $map -Gone $gone -What $field
    }

    # The rules and "a monitor came up" refer to modes by THE SAME keys, so they have to move
    # along with them: a combo was renamed — the rule has to look at the new name; deleted —
    # the rule about it is no longer a rule. Otherwise a rule would be left that every
    # fifteen seconds heads for a mode that does not exist, and the switch would answer
    # "combination no longer exists".
    # Update-HotkeyKeys does the same when a monitor has moved to another input.
    $updated.rules = @(Move-RuleModeKeys -Rules $Settings.rules -Renames $renames -Gone $gone)

    if ($Settings.reapply -is [System.Collections.IDictionary]) {
        $reapply = [ordered]@{}
        foreach ($k in @($Settings.reapply.Keys)) { $reapply[$k] = $Settings.reapply[$k] }
        $plug = [string]$reapply['onPlug']
        if ($plug) {
            if ($renames.Contains($plug)) { $reapply['onPlug'] = [string]$renames[$plug] }
            elseif ($gone -contains $plug) {
                $reapply['onPlug'] = ''
                Write-DisplayLog "settings: dropped 'on plug' for removed $plug"
            }
        }
        $updated.reapply = $reapply
    }

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
        $modes += [pscustomobject]@{
            Key       = $key
            Title     = Get-ModeTitleFromKey $key
            Kind      = 'orphan'
            Available = $false
        }
    }
    return $modes
}

# Returns the changed settings, or $null if it was cancelled. The window takes its icon off
# the disk itself (Register-WindowTheme): WPF wants an ImageSource, not a GDI icon.
function Show-SettingsDialog {
    param($State, $Settings)

    # Insurance: if the settings did not make it, we read them off the disk rather than
    # dying on a reference to $null.
    if (-not $Settings -or -not $Settings.hotkeys) {
        Write-DisplayLog 'settings dialog: settings arrived empty, reading them from disk'
        $Settings = Get-DisplaySettings
    }

    $modes = @(Get-DialogModes -State $State -Settings $Settings)

    $ui = New-SettingsWindow -Modes $modes -Settings $Settings -State $State

    # The run-at-startup checkbox is read from the fact that the shortcut exists rather than
    # from the settings: the shortcut could have been deleted by hand.
    $ui.StartupBox.IsChecked = (Test-RunAtStartup)

    try {
        if (-not $ui.Window.ShowDialog()) { return $null }
        $updated = $ui.Result
        if (-not $updated) { return $null }

        # A write that did not happen must not be reported as saved. The window is already closed by
        # this point (setting DialogResult closes it), so the message box goes without an owner — and
        # $null travels back, so the tray keeps living with the settings it had: memory, disk and the
        # registered shortcuts stay one and the same thing.
        if (-not (Save-DisplaySettings $updated)) {
            [void][System.Windows.MessageBox]::Show(
                "Could not write settings.json - nothing was saved." + [environment]::NewLine +
                "Check that the folder ScreenDeck sits in can be written to. Details are in the log.",
                'ScreenDeck', [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning)
            return $null
        }
        Set-RunAtStartup ([bool]$ui.StartupBox.IsChecked)
        return $updated
    }
    finally {
        $ui.Window.Close()
        $script:ActiveUi = $null
    }
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
        Title="ScreenDeck - Timer"
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
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
                <Button x:Name="CancelBtn" Style="{StaticResource Btn}" Content="Cancel" Width="84" IsCancel="True"/>
                <Button x:Name="StartBtn" Style="{StaticResource BtnAccent}" Width="124" Margin="8,0,0,0" IsDefault="True"/>
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
    $Ui.TargetText.Text = 'minutes, or 1h30 - up to {0}' -f (Format-DurationShort $script:TimerMaxMinutes)
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

    $win.FindName('CaptionText').Text = $(if ($Action -eq 'sleep') { 'SLEEP IN' } else { 'SHUT DOWN IN' })
    $ui.StartBtn.Content = $(if ($Action -eq 'sleep') { 'Sleep' } else { 'Shut down' })

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
