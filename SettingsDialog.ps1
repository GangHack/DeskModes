<#
    SettingsDialog.ps1 — окно настроек ScreenDeck.

    WPF, а не WinForms: у WinForms нет шаблонов, и «современно» там означает
    рисовать каждую кнопку руками в Paint. В WPF скруглённые углы, тумблеры и
    тёмная тема — это разметка, а не код. Сборки WPF грузятся лениво, при первом
    открытии окна: они стоят сотни миллисекунд, а трей меряет свой старт.

    Окно собирается отдельно от показа — и ради тестов, и ради отладки: в трее
    исключение при построении формы видно только как системное окно с ошибкой.

        New-SettingsWindow    собрать окно, вернуть его и элементы (проверяемо)
        Read-SettingsFromUi   собрать настройки из элементов окна (проверяемо)
        Show-SettingsDialog   показать и вернуть изменённые настройки или $null

    Тема — системная: тёмная/светлая и акцентный цвет читаются из реестра при
    каждом открытии (Test-DarkTheme и Get-AccentColor в DisplayCore.ps1).
#>

# --- WPF --------------------------------------------------------------------
# Загрузка при первом открытии окна, а не при дот-сорсе: этот файл подключается
# на старте трея, и «tray: started in N ms» не должен оплачивать четыре сборки,
# которые понадобятся только когда человек откроет настройки.

$script:WpfReady = $false

function Initialize-WpfRuntime {
    if ($script:WpfReady) { return }
    # WPF живёт только в STA. powershell.exe с 3.0 запускается в STA сам, но
    # проверить дешевле, чем разбирать невнятное исключение из глубин WPF.
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'The settings window needs an STA thread. Run powershell.exe without -MTA.'
    }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $script:WpfReady = $true
}

# --- палитра ----------------------------------------------------------------
# Значения списаны с приложения «Параметры» Windows 11: фон окна, карточки чуть
# светлее (в тёмной) или белые (в светлой), приглушённый второй текст. Акцент —
# системный; на нём считается контрастный цвет текста, иначе на жёлтом акценте
# белые буквы нечитаемы.

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

# --- разметка ---------------------------------------------------------------
# Ресурсы (кисти и стили) — одним блоком, он подставляется и в главное окно, и в
# редактор комбинации: StaticResource разрешается при разборе, поэтому ресурсы
# обязаны приехать вместе с разметкой окна, а не после.
#
# Токены %%NAME%% заменяются значениями палитры перед разбором. Не -f: XAML
# полон фигурных скобок, и форматирование строк на нём подрывается.

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

        <Style x:Key="H2" TargetType="TextBlock">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Margin" Value="0,0,0,2"/>
        </Style>
        <Style x:Key="Hint" TargetType="TextBlock">
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="Margin" Value="0,2,0,12"/>
        </Style>
        <Style x:Key="RowTitle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
        </Style>
        <Style x:Key="RowSub" TargetType="TextBlock">
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="Margin" Value="0,1,0,0"/>
        </Style>

        <!-- Ползунок уровня. Свой шаблон, потому что системный Slider не знает
             ни тёмной темы, ни акцента: в тёмном окне он оставался светлым.
             Заполненная часть — DecreaseRepeatButton трека, это штатный способ
             показать пройденное; правая половина прозрачная. -->
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

        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="{StaticResource CardBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="8"/>
            <Setter Property="Padding" Value="16,14"/>
            <Setter Property="Margin" Value="0,0,0,10"/>
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
            <Setter Property="Margin" Value="0,3"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal" Background="Transparent">
                            <Border x:Name="Box" Width="18" Height="18" CornerRadius="3"
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
            <Setter Property="FontSize" Value="13"/>
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
                                <TextBlock x:Name="Lbl" Text="Taskbar" FontSize="11"
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
                        <Border x:Name="Bd" CornerRadius="3" Padding="8,5" Margin="2,1" Background="Transparent">
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
                                <Border CornerRadius="6" Background="{StaticResource CardBrush}"
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
'@

$script:SettingsWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ScreenDeck - Settings"
        Width="640" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" ShowInTaskbar="True"
        Background="%%BG%%" Foreground="%%TEXT%%"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
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
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="20,16,20,6">
            <StackPanel>
                <Border Style="{StaticResource Card}">
                    <StackPanel>
                        <TextBlock Style="{StaticResource H2}" Text="Your desk"/>
                        <TextBlock Style="{StaticResource Hint}"
                                   Text="Arrange the cards in the order the displays stand on your desk, left to right - the cursor will cross between screens the same way. The star marks the display that keeps the taskbar."/>
                        <WrapPanel x:Name="DeskPanel"/>
                        <Border x:Name="PreviewBox" CornerRadius="6" Padding="12,10" Margin="0,4,0,0"
                                Background="{StaticResource MiniBrush}"
                                BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1">
                            <StackPanel>
                                <Canvas x:Name="PreviewCanvas" Width="540" Height="132" HorizontalAlignment="Center"/>
                                <TextBlock x:Name="PreviewHint" Style="{StaticResource Hint}" Margin="0,8,0,0"
                                           TextAlignment="Center"
                                           Text="Your desk as Windows will see it: sizes to scale, centred vertically so the cursor can cross between panels of different heights."/>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                    <StackPanel>
                        <TextBlock Style="{StaticResource H2}" Text="Modes"/>
                        <TextBlock Style="{StaticResource Hint}"
                                   Text="Everything you can switch to: one mode per display, every combination you made, and all of them at once. Edit opens the one place a mode is set up - the displays it turns on, where the taskbar goes, the shortcut, and the brightness of its monitors. A display's mode exists while the display does; combinations are yours to add and to remove."/>
                        <StackPanel x:Name="ModesPanel"/>
                        <Button x:Name="AddComboBtn" Style="{StaticResource Btn}" Content="Add a combination"
                                HorizontalAlignment="Left" Margin="0,10,0,0"/>
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
                                           Text="Count how long you spend in which app, on which display and in which mode - Statistics in the tray menu shows it. Kept in activity.json next to the scripts, never sent anywhere; window titles are not recorded. Delete the file to forget everything."/>
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
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        UseLayoutRounding="True">
    <Window.Resources>
%%RES%%
    </Window.Resources>
    <DockPanel LastChildFill="True">
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right"
                    Margin="20,14,20,16">
            <Button x:Name="OkBtn" Style="{StaticResource BtnAccent}" Content="Save" Width="90" IsDefault="True"/>
            <Button x:Name="CancelBtn" Style="{StaticResource Btn}" Content="Cancel" Width="90" Margin="8,0,0,0" IsCancel="True"/>
        </StackPanel>
        <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="20,16,20,0" Width="400">
                <TextBlock x:Name="HeadTitle" Style="{StaticResource H2}" Text="Mode"/>
                <TextBlock x:Name="HeadHint" Style="{StaticResource Hint}"/>
                <StackPanel x:Name="ComboPart" Margin="0,12,0,0">
                    <TextBlock Style="{StaticResource H2}" Text="Name"/>
                    <TextBox x:Name="NameBox" Style="{StaticResource Input}" Margin="0,4,0,0"/>
                    <TextBlock Style="{StaticResource H2}" Text="Displays" Margin="0,16,0,0"/>
                    <TextBlock Style="{StaticResource Hint}" Text="Tick every display this combination switches on."/>
                    <StackPanel x:Name="MembersPanel"/>
                    <TextBlock Style="{StaticResource H2}" Text="Taskbar" Margin="0,14,0,0"/>
                    <TextBlock Style="{StaticResource Hint}" Text="Which display keeps the taskbar while this combination is on."/>
                    <ComboBox x:Name="PrimaryBox" Style="{StaticResource Select}" Height="30"/>
                </StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Shortcut" Margin="0,16,0,0"/>
                <TextBlock Style="{StaticResource Hint}" Text="Optional - the mode works from the tray menu either way. Click the box and press the keys: Ctrl, Alt, Shift or Win plus something."/>
                <StackPanel Orientation="Horizontal">
                    <TextBox x:Name="HotkeyBox" Style="{StaticResource Input}" Width="150" TextAlignment="Center"/>
                    <Button x:Name="ClearHotkeyBtn" Style="{StaticResource BtnSubtle}" Content="&#x00D7;"
                            FontSize="15" Width="26" Margin="4,0,0,0" VerticalAlignment="Center"
                            ToolTip="Remove this shortcut"/>
                </StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Brightness" Margin="0,18,0,0"/>
                <TextBlock Style="{StaticResource Hint}"
                           Text="This mode can carry the brightness of its monitors, so you stop reaching for the buttons on the bezel. It goes over DDC/CI, the service channel inside the cable: only monitors that answer can be set, and &quot;Ask the monitors&quot; tells which of yours do. Contrast is the same idea and lives in settings.json."/>
                <ComboBox x:Name="LevelKindBox" Style="{StaticResource Select}" Height="30" Margin="0,4,0,0"/>
                <Grid x:Name="LevelOnePanel" Margin="0,12,0,0" Visibility="Collapsed">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Slider x:Name="LevelOneSlider" Style="{StaticResource Level}" VerticalAlignment="Center"/>
                    <TextBlock x:Name="LevelOneValue" Grid.Column="1" Width="34" TextAlignment="Right"
                               VerticalAlignment="Center" Margin="10,0,0,0"/>
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

# Разобрать разметку, подставив палитру. Общие ресурсы въезжают токеном %%RES%%.
function Convert-UiXaml {
    param([string]$Xaml, $Palette)

    $text = $Xaml.Replace('%%RES%%', $script:UiResourcesXaml)
    foreach ($key in $Palette.Keys) {
        $text = $text.Replace('%%' + $key + '%%', [string]$Palette[$key])
    }
    return [System.Windows.Markup.XamlReader]::Parse($text)
}

# --- обработчики событий: почему без .GetNewClosure() -----------------------
# Обработчик, созданный через .GetNewClosure(), получает собственную область, и из
# неё не разрешается ни $script: (см. Get-ActiveSettings в Displays.ps1), ни имена
# функций, если замыкание создано в дот-сорснутом файле и вызывается WPF через
# делегат: клик по кнопке падает с «ConvertFrom-HotkeyString is not recognized».
#
# Поэтому здесь ни один обработчик не замыкается. Всё, что ему нужно, приезжает
# двумя путями: состояние окна — через $script:ActiveUi, состояние конкретной
# строки — через .Tag самого элемента (внутри блока он доступен как $this).
# Плоский блок сохраняет область файла, и функции с $script: в нём работают.

# Окно, с которым идёт работа прямо сейчас. Одно на процесс: окно модальное, двух
# сразу быть не может. Редактор комбинации держит своё в $script:ActiveEditor.
$script:ActiveUi = $null
$script:ActiveEditor = $null

# Тёмный заголовок окна — сразу после появления HWND: до этого его просто нет.
function Register-WindowTheme {
    param($Window, [bool]$Dark)

    # Тёмность — на самом окне: обработчик получит его как $this.
    $Window.Tag = [pscustomobject]@{ Dark = $Dark }
    $Window.add_SourceInitialized({
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper $this).Handle
            [NativeTheme]::TryDarkTitleBar($h, [bool]$this.Tag.Dark)
        }
        catch { }   # не вышло — заголовок останется светлым
    })

    try {
        $ico = Join-Path $script:ToolRoot 'app.ico'
        if (Test-Path $ico) {
            $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create(
                (New-Object System.Uri $ico), 'None', 'OnLoad')
        }
    }
    catch { }   # иконка не обязательна: окно откроется и без неё
}

# --- мелкие фабрики ---------------------------------------------------------

function New-UiTextBlock {
    param([string]$Text, $Style, $Window)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    if ($Style) { $t.Style = $Window.FindResource($Style) }
    return $t
}

# Что стоит в поле, когда клавиши нет. Одной константой: текст сравнивается в
# нескольких местах, и разъехавшиеся копии молча превратили бы «нет привязки» в
# «привязка, которую не удалось разобрать».
$script:NoHotkeyText = 'no shortcut'
# Подсказка в пустом поле, пока в нём фокус: «нажми клавиши» надо говорить в тот
# момент, когда человек смотрит на поле, а не абзацем выше.
$script:PressKeysText = 'press the keys'

# Приём комбинации клавиш: ловим PreviewKeyDown и ждём основную клавишу при
# зажатых модификаторах. Биты
# ModifierKeys у WPF совпадают с MOD_* у RegisterHotKey (Alt 1, Ctrl 2, Shift 4,
# Win 8) — перекодировка не нужна, совпадение закреплено тестом маппинга.
function Register-HotkeyCapture {
    param($Box)

    $Box.IsReadOnly = $true
    $Box.IsReadOnlyCaretVisible = $false

    # Пустое поле в фокусе подсказывает, что делать; при уходе фокуса подсказка и
    # сообщения об отказе («needs Ctrl…») уступают место обычному «no shortcut» —
    # иначе окно осталось бы с текстом ошибки в поле, где привязки нет.
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

        # Esc и Tab без модификаторов отдаём окну: Esc закрывает его, Tab ведёт
        # фокус дальше. Иначе из поля не выбраться с клавиатуры.
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

# Крестик «снять клавишу» рядом с полем. Одной функцией на оба места (список
# режимов и редактор комбинации): логика одна, а дублировать её значило бы
# позволить копиям разойтись. Пара «поле ↔ кнопка» ездит в .Tag каждого из них —
# замыкания здесь нельзя (см. комментарий об обработчиках выше).
function Register-HotkeyClearButton {
    param($Box, $Button)

    # Ссылки друг на друга, по одной в каждую сторону: больше этим обработчикам
    # ничего не нужно.
    $Button.Tag = $Box
    $Box.Tag = $Button

    $Button.add_Click({
        $this.Tag.Text = $script:NoHotkeyText
        $this.IsEnabled = $false
    })
    # Состояние крестика следует за полем: клавишу могли назначить или снять
    # Backspace'ом, минуя кнопку.
    $Box.add_TextChanged({
        $this.Tag.IsEnabled = [bool](ConvertFrom-HotkeyString $this.Text)
    })
}

# Подпись под названием режима: ОТКУДА он взялся и из чего состоит.
#
# Происхождение — не украшение: подпись отвечает, почему у одной строки есть
# кнопка Remove, а у другой нет. Режим монитора и «все» появляются сами,
# комбинацию создаёшь и удаляешь ты.
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

# --- сборка окна ------------------------------------------------------------

function New-SettingsWindow {
    param(
        $Modes,
        $Settings,
        # Подключённые мониторы: карточки стола и участники комбинаций. Пусто —
        # соответствующие разделы просто пустуют (тесты).
        $State
    )

    Initialize-WpfRuntime

    $dark = Test-DarkTheme
    $palette = Get-UiPalette -Dark $dark
    $win = Convert-UiXaml -Xaml $script:SettingsWindowXaml -Palette $palette
    Register-WindowTheme -Window $win -Dark $dark

    # Ниже рабочей области окно не растёт — дальше прокрутка. Запас на панель задач.
    try { $win.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height - 40 } catch { }   # нет рабочей области — не ограничиваем

    $ui = [pscustomobject]@{
        Window            = $win
        Dark              = $dark
        # Ключ режима -> текст комбинации клавиш. Не поля ввода: клавиша живёт в
        # редакторе режима, а главному окну довольно строк.
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
        # Ключ режима -> модель яркости (см. ConvertTo-LevelModel). Правится в
        # редакторе режима, уезжает в settings.json на Save.
        Levels            = [ordered]@{}
        Modes             = @($Modes)
        Settings          = $Settings
        State             = @($State)
        Result            = $null
    }

    # Комбинации — в рабочий список: окно правит его, а settings.json перепишется
    # из него целиком на Save. OriginalName помнит, под каким именем комбинация
    # лежит в файле сейчас: по нему при переименовании переезжают клавиша и звук.
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
    # Отсутствие ключа в settings.json означает «по умолчанию», то есть включено:
    # файл правится руками, и половины ключей в нём может не быть.
    $ui.WindowsBox.IsChecked  = ($null -eq $Settings.restoreWindows -or [bool]$Settings.restoreWindows)
    $ui.LastModeBox.IsChecked = ($null -eq $Settings.restoreLastMode -or [bool]$Settings.restoreLastMode)
    # Дневник — наоборот: отсутствие ключа означает «выключено». Это данные о
    # человеке, и по умолчанию их не собирают.
    $ui.StatsBox.IsChecked    = [bool]$Settings.stats

    # Окно собрано — с этого момента обработчики находят его здесь.
    $script:ActiveUi = $ui

    $ui.AddComboBtn.add_Click({
        $ui = $script:ActiveUi
        if (-not $ui) { return }
        Invoke-ModeEditor -Ui $ui -Mode $null -Combo $null
    })

    # Save проверяет ввод ДО закрытия: старое окно на дубликате комбинации клавиш
    # закрывалось и выбрасывало все правки, теперь оно остаётся открытым.
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

# --- стол: порядок и панель задач -------------------------------------------
# Карточки в DeskPanel и есть раскладка: их порядок слева направо уезжает в
# settings.json -> layout, отмеченная звезда -> primary. Записи для мониторов,
# которых сейчас нет, не теряются: для них строится своя, приглушённая карточка.

function Update-DeskPanel {
    param($Ui)

    $Ui.DeskPanel.Children.Clear()

    $settings = $Ui.Settings
    $state = @($Ui.State | Where-Object { $_ })
    $placed = New-Object System.Collections.ArrayList   # мониторы, уже получившие карточку
    $cards = @()

    # Сначала — порядок из настроек: каждый шаблон либо находит монитор, либо
    # становится карточкой-памяткой (монитор отключён, но своё место в ряду он
    # сохраняет — иначе каждый Save стирал бы его из layout).
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

    # Затем всё, что подключено, но в layout не упомянуто, — в конец ряда.
    foreach ($m in $state) {
        if ($placed -contains $m) { continue }
        $cards += [pscustomobject]@{ Label = $m.Label; Display = $m }
    }

    foreach ($card in $cards) {
        Add-DeskCard -Ui $Ui -Label $card.Label -Display $card.Display
    }

    # Звезда панели задач — по ПЕРВОМУ совпадению с настройкой, слева направо:
    # ровно так выбирает и переключатель. Ставить в цикле сборки карточек нельзя —
    # каждое следующее совпадение снимало бы предыдущее, и выигрывал бы последний.
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
    param($Ui, [string]$Label, $Display)

    $win = $Ui.Window
    $connected = ($null -ne $Display -and -not $Display.Disconnected)

    $outer = New-Object System.Windows.Controls.Border
    $outer.Width = 122
    $outer.Margin = New-Object System.Windows.Thickness 0, 0, 10, 6
    $outer.Padding = New-Object System.Windows.Thickness 6
    $outer.CornerRadius = New-Object System.Windows.CornerRadius 6

    $stack = New-Object System.Windows.Controls.StackPanel
    $outer.Child = $stack

    # Мини-экран с названием внутри — та же метафора, что в параметрах Windows.
    $mini = New-Object System.Windows.Controls.Border
    $mini.Height = 60
    $mini.CornerRadius = New-Object System.Windows.CornerRadius 4
    $mini.Background = $win.FindResource('MiniBrush')
    $mini.BorderBrush = $win.FindResource('InputBorderBrush')
    $mini.BorderThickness = New-Object System.Windows.Thickness 1
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = $Label
    $name.FontSize = 10.5
    $name.TextWrapping = 'Wrap'
    $name.TextAlignment = 'Center'
    $name.VerticalAlignment = 'Center'
    $name.Margin = New-Object System.Windows.Thickness 4
    $mini.Child = $name
    [void]$stack.Children.Add($mini)

    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.FontSize = 10.5
    $sub.TextAlignment = 'Center'
    $sub.Foreground = $win.FindResource('DimBrush')
    $sub.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
    if (-not $connected)      { $sub.Text = 'not connected' }
    elseif ($Display.Active)  { $sub.Text = '{0} x {1} @ {2} Hz' -f $Display.Width, $Display.Height, $Display.Hz }
    else                      { $sub.Text = 'off' }
    [void]$stack.Children.Add($sub)

    $radio = New-Object System.Windows.Controls.RadioButton
    $radio.GroupName = 'taskbar'
    $radio.Style = $win.FindResource('TaskbarPick')
    $radio.HorizontalAlignment = 'Center'
    $radio.Margin = New-Object System.Windows.Thickness 0, 3, 0, 0
    [void]$stack.Children.Add($radio)

    $arrows = New-Object System.Windows.Controls.StackPanel
    $arrows.Orientation = 'Horizontal'
    $arrows.HorizontalAlignment = 'Center'
    $left = New-Object System.Windows.Controls.Button
    $left.Content = [string][char]0x2190   # стрелка влево
    $left.Style = $win.FindResource('BtnSubtle')
    $left.FontSize = 12
    $right = New-Object System.Windows.Controls.Button
    $right.Content = [string][char]0x2192  # стрелка вправо
    $right.Style = $win.FindResource('BtnSubtle')
    $right.FontSize = 12
    [void]$arrows.Children.Add($left)
    [void]$arrows.Children.Add($right)
    [void]$stack.Children.Add($arrows)

    if (-not $connected) { $outer.Opacity = 0.55 }

    # Размер в пикселях — для предпросмотра стола. У включённого монитора берём
    # то, что он показывает сейчас, у погашенного — его родное разрешение (оно
    # известно из EDID даже когда монитор спит), у отсутствующего не берём
    # ничего: предпросмотр поставит на его место обычные 16:9.
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

    # Стрелке нужны ряд и своя карточка — приезжают на ней самой (см. комментарий
    # про обработчики выше). Ряд не через $script:ActiveUi: карточки строятся до
    # того, как окно объявлено активным.
    $panel = $Ui.DeskPanel
    $left.Tag  = [pscustomobject]@{ Panel = $panel; Card = $outer; Delta = -1; Ui = $Ui }
    $right.Tag = [pscustomobject]@{ Panel = $panel; Card = $outer; Delta = 1; Ui = $Ui }
    # Предпросмотр перерисовываем сразу: он затем и нужен, чтобы видеть, что
    # получится, ДО сохранения. Ряд и окно приезжают на кнопке — карточки
    # строятся до того, как окно объявлено активным (см. комментарий выше).
    $move = {
        Move-DeskCard -Panel $this.Tag.Panel -Card $this.Tag.Card -Delta $this.Tag.Delta
        Update-DeskPreview -Ui $this.Tag.Ui
    }
    $left.add_Click($move)
    $right.add_Click($move)

    # Звезда панели задач тоже меняет картинку: основной монитор в ней обведён
    # акцентом, и от него же считается сдвиг всей раскладки к нулю координат.
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

# --- предпросмотр стола -----------------------------------------------------
# Карточки говорят, в каком порядке мониторы стоят, но не показывают, что из
# этого получится: экраны разной высоты (1440 и 2160) выстраиваются по центру, и
# по краям остаются полосы, через которые курсор не переходит. Без предпросмотра
# это выясняется только после Save — на живом столе.
#
# Координаты берём у Get-LayoutPositions — той самой функции, которой считает
# переключатель. Не «похожая картинка», а ровно то, что будет применено: если
# картинка врёт, значит врёт и переключение, и виден один и тот же баг.

# Чистая функция: карточки (в их видимом порядке) -> экраны для Get-LayoutPositions.
# Размер в пикселях берётся из текущего режима монитора, а если он выключен — из
# его максимального; неизвестный считаем обычным 16:9, чтобы место в ряду он всё
# равно занял.
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

# Координаты для картинки — через Get-LayoutPositions, ту же функцию, которой
# считает переключатель.
#
# Порядок ей надо передать ЯВНО, названиями в порядке карточек: с пустым Order у
# всех экранов одинаковый ранг, и она сортирует их по названию. Первая версия так
# и рисовала — по алфавиту: ULTRAFINE, ULTRAGEAR, XG27AQDMGR вместо ULTRAFINE,
# XG27AQDMGR, ULTRAGEAR, то есть показывала не тот стол, который получится.
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

    # Сведения о карточках — в их ВИДИМОМ порядке: он и есть раскладка.
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

    # Масштаб: вся раскладка должна поместиться в холст целиком.
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
    # Зазор между экранами рисуем, а в координатах его нет: на настоящем столе
    # мониторы стоят в рамках и вплотную не сходятся.
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

# --- яркость ----------------------------------------------------------------
# Яркость в настройках записана двумя способами, и оба нужны: число («всем
# мониторам режима поровну», так пишут чаще всего) и объект («каждому своё»).
# Окно обязано уметь оба И НЕ ПРЕВРАЩАТЬ ОДИН В ДРУГОЙ САМО: развернув число в
# объект по тем мониторам, что сейчас на столе, оно потеряло бы яркость для
# выдернутого монитора и изменило бы смысл записи «all» для монитора, который
# появится завтра. Поэтому форма — это выбор человека («Then...» в карточке), а
# не догадка окна.

# Значение из настроек -> модель для окна. Чистая функция.
#   Kind = 'none'  яркость этому режиму не задана;
#          'one'   одно число на все мониторы режима (Value);
#          'each'  своё число каждому (Map: имя -> число).
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

# И обратно, в то, что уезжает в settings.json. $null означает «ключа быть не
# должно»: пустой объект в файле выглядел бы как настройка, которой нет.
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

# Все модели окна -> то, что уезжает в settings.json. Режимы без яркости в файл
# не попадают вовсе: ключ со словарём-пустышкой выглядел бы как настройка,
# которой нет. Чистая функция.
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

# Мониторы режима — по именам, как их запишут в файл. Ключ режима знает о них
# всё: «all» — весь стол, «solo:» — один монитор, «combo:» — набор из рабочего
# списка окна.
function Get-ModeDisplayNames {
    param([string]$ModeKey, $State, $Combos)

    $names = @()
    $live = @($State | Where-Object { $_ })

    if ($ModeKey -eq 'all') {
        $names = @($live | Where-Object { -not $_.Disconnected } | ForEach-Object { [string]$_.Label })
    }
    elseif ($ModeKey -like 'solo:*') {
        $names = @($ModeKey.Substring(5))
    }
    elseif ($ModeKey -like 'combo:*') {
        $name = $ModeKey.Substring(6)
        $combo = @($Combos | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
        if ($combo.Count -gt 0) {
            foreach ($pattern in @($combo[0].Patterns)) {
                if (-not $pattern) { continue }
                # Название монитора точнее шаблона: «ULTRAFINE» из файла станет
                # «LG ULTRAFINE», и обе записи по-прежнему совпадают (сравнение
                # идёт вхождением в обе стороны).
                $hit = @($live | Where-Object { Test-DisplayNameMatch -Pattern $pattern -Label $_.Label -ShortId $_.ShortId } | Select-Object -First 1)
                $names += $(if ($hit.Count -gt 0) { [string]$hit[0].Label } else { [string]$pattern })
            }
        }
    }
    return @($names | Where-Object { $_ })
}

# Строки ползунков: мониторы режима плюс «сироты» — имена, которые уже есть в
# карте, но ни одному монитору режима не соответствуют (монитор увезли,
# комбинацию правили рукой). Их надо ПОКАЗАТЬ, иначе настройку нельзя ни
# увидеть, ни снять — тем же правилом живут привязки клавиш.
function Get-LevelRowNames {
    # Имя параметра не должно совпадать с именем накопителя даже регистром: в
    # PowerShell $rows и $Rows — одна переменная, и первое же присваивание стёрло
    # бы то, что пришло снаружи.
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

# Яркость из настроек — в рабочие модели окна, ключом режима. Правит их редактор
# режима, а уезжают они на Save (см. ConvertTo-BrightnessSettings).
function Import-LevelSettings {
    param($Ui, $Settings)

    $Ui.Levels = [ordered]@{}
    if ($Settings -and $Settings.brightness) {
        foreach ($key in @($Settings.brightness.Keys)) {
            $Ui.Levels[[string]$key] = ConvertTo-LevelModel $Settings.brightness[$key]
        }
    }
}

# Копия модели: редактор правит её на месте, и Cancel обязан оставить окно с
# тем, что было. Откатывать ползунки назад было бы враньём — копия честнее и
# стоит одну запись в словаре.
function Copy-LevelModel {
    param($Model)

    $copy = [pscustomobject]@{ Kind = 'none'; Value = 80; Map = [ordered]@{} }
    if (-not $Model) { return $copy }
    $copy.Kind = [string]$Model.Kind
    $copy.Value = [int]$Model.Value
    foreach ($key in @($Model.Map.Keys)) { $copy.Map[[string]$key] = [int]$Model.Map[$key] }
    return $copy
}

# Мониторы, на которые смотрит редактор. У комбинации — ОТМЕЧЕННЫЕ галочки, а не
# то, что записано в файле: человек снял монитор — строка яркости обязана уйти
# вместе с ним, не дожидаясь Save.
function Get-EditorDisplayNames {
    param($Editor)

    if ($Editor.Kind -eq 'combo') {
        return @($Editor.Checks | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    }
    return @(Get-ModeDisplayNames -ModeKey ([string]$Editor.ModeKey) -State $Editor.State -Combos @())
}

# Список форм записи — в редактор. Порядок пунктов и есть порядок
# $script:LevelKindTitles: по нему же выбирается пункт в Update-EditorLevel.
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

# Показать модель редактора: выбор формы, один ползунок или строка на монитор.
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
    # Ширины задаём объектами, а не строками: у GridLength нет Parse (первая
    # версия звала его и падала при переходе на «каждому своё» — поймал не тест, а
    # снимок окна, поэтому тест на построение строк теперь есть).
    foreach ($width in @((New-Object System.Windows.GridLength 150),
                         (New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)),
                         [System.Windows.GridLength]::Auto)) {
        $column = New-Object System.Windows.Controls.ColumnDefinition
        $column.Width = $width
        [void]$grid.ColumnDefinitions.Add($column)
    }

    # Галочка и есть «задано / не задано»: снятая означает, что этому монитору
    # яркость в этом режиме не трогают, а не «ноль».
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
    $value.Margin = New-Object System.Windows.Thickness 10, 0, 0, 0
    $value.Text = $(if ($set) { [string][int]$Model.Map[$Name] } else { 'off' })
    if (-not $set) { $value.Foreground = $win.FindResource('DimBrush') }
    [System.Windows.Controls.Grid]::SetColumn($value, 2)
    [void]$grid.Children.Add($value)

    # Состояние строки — на самих элементах (.Tag), как и во всех остальных
    # обработчиках этого окна: .GetNewClosure() здесь запрещён (см. заголовок).
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

# «Ask the monitors» — спросить DDC/CI прямо сейчас. Отдельной кнопкой, а не при
# открытии окна: один опрос стоит десятки миллисекунд на монитор, а на зависшей
# шине — до секунды с повторами, и платить это за каждое открытие настроек
# незачем.
function Invoke-LevelProbe {
    param($Editor)

    $Editor.LevelNote.Text = 'asking...'
    $answers = @()
    try { $answers = @(Get-MonitorLevels) }
    catch {
        $Editor.LevelNote.Text = "could not ask the monitors - $($_.Exception.Message)"
        return
    }

    # DDC отдаёт имя выхода (\\.\DISPLAY1), человеку нужно название монитора.
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
    # Про спящие говорим всегда: их в ответе нет вовсе, и без этой строки
    # выглядело бы, будто монитор не умеет.
    $Editor.LevelNote.Text = ($parts -join '; ') + '. Sleeping displays cannot be asked.'
}

# --- режим: правка одного ---------------------------------------------------
# Один редактор на любой режим, и это ответ на вопрос «где это настраивается».
# У комбинации правится всё — имя, состав, панель задач, клавиша, яркость; у
# режима монитора и у «all» состав задан самой жизнью, и остаются клавиша с
# яркостью. Трёх карточек на это больше нет: человек ищет настройки режима там,
# где нажал Edit.

# Применить ответ редактора к рабочему состоянию окна. Отдельно от обработчиков
# кликов: это и есть проверяемая часть правки, обработчики только зовут редактор
# и передают его ответ сюда.
function Set-UiMode {
    param($Ui, $Mode, $Combo, $Edited)

    if (-not $Edited) { return }

    # Ключ, под которым режим лежал до правки: у комбинации он меняется вместе с
    # именем, и всё привязанное к нему обязано переехать.
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
        # Вернули имя, которое в этом же сеансе удаляли, — удаление отменилось.
        $Ui.DeletedComboKeys = @($Ui.DeletedComboKeys | Where-Object { $_ -ne $newKey })
    }

    # Переименование уводит клавишу и яркость на новый ключ: под старым осталась
    # бы настройка-призрак, которой не видно ни в одном окне. То же самое для
    # звука и команд делает Read-SettingsFromUi — там ключ известен только на Save.
    if ($oldKey -and $newKey -and $oldKey -ne $newKey) {
        if ($Ui.Hotkeys.Contains($oldKey)) { $Ui.Hotkeys.Remove($oldKey) }
        if ($Ui.Levels.Contains($oldKey))  { $Ui.Levels.Remove($oldKey) }
    }

    if ($newKey) {
        # Пустая клавиша честно означает «клавиши нет»: человек мог её и снять.
        if ($null -ne $Edited.PSObject.Properties['Hotkey']) {
            $parsed = ConvertFrom-HotkeyString ([string]$Edited.Hotkey)
            if ($parsed) { $Ui.Hotkeys[$newKey] = $parsed.Text }
            elseif ($Ui.Hotkeys.Contains($newKey)) { $Ui.Hotkeys.Remove($newKey) }
        }
        if ($null -ne $Edited.PSObject.Properties['Level']) {
            $Ui.Levels[$newKey] = $Edited.Level
        }
    }

    Update-ModesPanel -Ui $Ui
}

function Remove-UiCombo {
    param($Ui, $Combo)

    # Помним оба ключа: под OriginalName комбинация лежит в файле (звук, команды),
    # под нынешним именем — в клавишах и яркости этого окна.
    $keys = @('combo:' + $Combo.Name)
    if ($Combo.OriginalName) { $keys += ('combo:' + $Combo.OriginalName) }
    $Ui.DeletedComboKeys = @($Ui.DeletedComboKeys) + $keys
    $Ui.Combos.Remove($Combo)
    foreach ($key in $keys) {
        if ($Ui.Hotkeys.Contains($key)) { $Ui.Hotkeys.Remove($key) }
        if ($Ui.Levels.Contains($key))  { $Ui.Levels.Remove($key) }
    }
    Update-ModesPanel -Ui $Ui
}

# Снять всё, что осталось от режима, которого больше нет: монитор увезли,
# комбинацию стёрли рукой из файла. Клавиша-то занята глобально, и снять её
# можно только отсюда — потому у такой строки своя кнопка.
function Remove-UiOrphan {
    param($Ui, [string]$Key)

    if ($Ui.Hotkeys.Contains($Key)) { $Ui.Hotkeys.Remove($Key) }
    if ($Ui.Levels.Contains($Key))  { $Ui.Levels.Remove($Key) }
    Update-ModesPanel -Ui $Ui
}

# Редактор режима: сборка отдельно от показа, по той же причине, что и у
# главного окна, — собранное без показа окно можно проверить.
# Заголовок редактора и то, какая его часть вообще видна. Зависит только от вида
# режима: комбинацию человек собирает сам, поэтому у неё есть имя и состав; режим
# монитора и «все» задаёт стол, и правится у них только клавиша с яркостью —
# спорить о названии и участниках там не о чем, эта часть окна прячется.
function Set-ModeEditorHeader {
    param($Window, [string]$Kind, $Mode, $Combo)

    $headTitle = $Window.FindName('HeadTitle')
    $headHint = $Window.FindName('HeadHint')

    if ($Kind -eq 'combo') {
        # Имя и состав правятся ниже, своими полями: заголовку остаётся сказать,
        # что это вообще такое. Заведённой комбинации объяснять уже нечего —
        # подсказка уходит, окно становится короче на две строки.
        $headTitle.Text = $(if ($Combo) { 'Combination' } else { 'New combination' })
        if ($Combo) { $headHint.Visibility = 'Collapsed' }
        else {
            $headHint.Text = 'Any set of displays under a name you choose. It gets an entry in the tray menu, a shortcut if you want one, and the brightness set below.'
        }
    }
    else {
        $Window.FindName('ComboPart').Visibility = 'Collapsed'
        $headTitle.Text = $(if ($Mode) { [string]$Mode.Title } else { 'Mode' })
        $headHint.Text = $(if ($Kind -eq 'all') {
            'Every display on your desk at once. Which displays these are the desk decides, so what belongs to the mode itself is the shortcut and the brightness.'
        } else {
            'This mode leaves one display on and turns the rest off. Its set of displays is fixed, so what belongs to the mode itself is the shortcut and the brightness.'
        })
    }

    $Window.Title = 'ScreenDeck - ' + $headTitle.Text
}

# Состав комбинации: галочки участников и выпадающий список «кому панель задач».
# Возвращает список галочек — их читает Read-ModeFromUi, и Tag каждой хранит
# точную строку, которая уедет в settings.json.
#
# Галочки — все подключённые мониторы, затем шаблоны комбинации, не совпавшие ни
# с одним из них: монитор увезли, но выбрасывать его из комбинации молча нельзя.
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

function New-ModeEditorWindow {
    param(
        # Режим, который правим. $null — создаём новую комбинацию.
        $Mode,
        # Рабочая запись комбинации из списка окна. $null — режим не комбинация
        # либо комбинация ещё не заведена.
        $Combo,
        $State,
        # Модель яркости режима. Правится КОПИЯ: Cancel обязан оставить окно с
        # тем, что было.
        $Level,
        [string[]]$TakenNames = @(),
        [string]$Hotkey = '',
        # Комбинации, занятые другими режимами: назначить одну клавишу дважды
        # нельзя, и сказать об этом надо сейчас, а не после закрытия редактора.
        [string[]]$TakenHotkeys = @(),
        $Owner,
        [bool]$Dark
    )

    Initialize-WpfRuntime
    $palette = Get-UiPalette -Dark $Dark
    $win = Convert-UiXaml -Xaml $script:ModeEditorXaml -Palette $palette
    Register-WindowTheme -Window $win -Dark $Dark
    if ($Owner) { $win.Owner = $Owner }

    # Ниже рабочей области окно не растёт — дальше прокрутка, как и у главного.
    try { $win.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height - 80 } catch { }   # нет рабочей области — не ограничиваем

    # Вид режима решает, что в окне показывать. Новая запись — всегда комбинация:
    # режимы монитора и «all» заводит стол, а не человек.
    $kind = 'combo'
    if ($Mode -and [string]$Mode.Kind -and [string]$Mode.Kind -ne 'combo') { $kind = [string]$Mode.Kind }

    $nameBox = $win.FindName('NameBox')
    $primaryBox = $win.FindName('PrimaryBox')
    $hotkeyBox = $win.FindName('HotkeyBox')
    $okBtn = $win.FindName('OkBtn')

    Set-ModeEditorHeader -Window $win -Kind $kind -Mode $Mode -Combo $Combo

    $hotkeyBox.Cursor = [System.Windows.Input.Cursors]::Hand
    Register-HotkeyCapture -Box $hotkeyBox
    $parsedHotkey = ConvertFrom-HotkeyString $Hotkey
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
        ModeKey        = $(if ($Mode) { [string]$Mode.Key } else { '' })
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
        # Пока панель перестраивается, обработчики ползунков молчат: иначе
        # программная установка значения тут же считалась бы правкой человека.
        LevelBusy      = $false
        Level          = (Copy-LevelModel $Level)
        State          = @($State)
        TakenNames     = @($TakenNames)
        TakenHotkeys   = @($TakenHotkeys)
        Result         = $null
    }
    # Обработчики находят редактор здесь, а не в замыкании: см. комментарий об
    # обработчиках выше. Редактор модальный, поэтому одного места достаточно.
    $script:ActiveEditor = $ed

    Initialize-EditorLevel -Editor $ed

    $ed.LevelKindBox.add_SelectionChanged({
        $ed = $script:ActiveEditor
        if (-not $ed -or $ed.LevelBusy) { return }
        $item = $ed.LevelKindBox.SelectedItem
        if (-not $item) { return }
        $ed.Level.Kind = [string]$item.Tag
        # Переход «одно число» -> «каждому своё»: заполняем мониторы режима тем
        # самым числом. Так человек получает то, что видел, и правит от него, а
        # не пустой список. Обратный переход карту не стирает — вернувшись, он
        # найдёт свои значения на месте.
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

    # Сняли монитор с комбинации — его строка яркости уходит следом, не дожидаясь
    # Save: иначе ползунок стоял бы под монитором, которого в режиме уже нет.
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

# Что человек набрал в редакторе, с проверкой. Отдельной функцией — как и
# Read-SettingsFromUi у главного окна: проверяемо без показа окна.
function Read-ModeFromUi {
    param($Editor)

    # В поле может стоять и «no shortcut», и подсказка «needs Ctrl…» — клавишей
    # считается только то, что разбирается. Пусто — значит без клавиши.
    $hk = ''
    $parsed = ConvertFrom-HotkeyString $Editor.HotkeyBox.Text
    if ($parsed) { $hk = $parsed.Text }

    if ($hk -and @($Editor.TakenHotkeys) -contains $hk) {
        return [pscustomobject]@{
            Ok = $false; Mode = $null
            Problem = "$hk already drives another mode. Each combination of keys can only drive one."
        }
    }

    # У режима монитора и у «all» состав задан столом: правятся только клавиша и
    # яркость, и проверять больше нечего.
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

# Показ редактора. Возвращает правку режима или $null при отмене.
function Show-ModeEditor {
    param(
        $Mode,
        $Combo,
        $State,
        $Level,
        [string[]]$TakenNames = @(),
        [string]$Hotkey = '',
        [string[]]$TakenHotkeys = @(),
        $Owner,
        [bool]$Dark
    )

    $ed = New-ModeEditorWindow -Mode $Mode -Combo $Combo -State $State -Level $Level `
                               -TakenNames $TakenNames -Hotkey $Hotkey -TakenHotkeys $TakenHotkeys `
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

# Собрать всё, что редактору нужно от окна, показать его и применить ответ. Одно
# место и на «Add a combination», и на каждую строку Edit: правила о занятых
# именах и клавишах обязаны быть одинаковыми для всех режимов.
function Invoke-ModeEditor {
    param($Ui, $Mode, $Combo)

    $key = $(if ($Mode) { [string]$Mode.Key } else { '' })
    $taken = @($Ui.Combos | Where-Object { -not $Combo -or $_ -ne $Combo } | ForEach-Object { [string]$_.Name })
    $hotkey = $(if ($key -and $Ui.Hotkeys.Contains($key)) { [string]$Ui.Hotkeys[$key] } else { '' })
    $level = $(if ($key -and $Ui.Levels.Contains($key)) { $Ui.Levels[$key] } else { $null })

    $made = Show-ModeEditor -Mode $Mode -Combo $Combo -State $Ui.State -Level $level `
                            -TakenNames $taken -Hotkey $hotkey `
                            -TakenHotkeys (Get-TakenHotkeys -Ui $Ui -ExceptKey $key) `
                            -Owner $Ui.Window -Dark $Ui.Dark
    if ($made) { Set-UiMode -Ui $Ui -Mode $Mode -Combo $Combo -Edited $made }
}

# Комбинации клавиш, занятые всеми режимами, КРОМЕ одного (того, что сейчас в
# редакторе): его собственная клавиша — не конфликт.
function Get-TakenHotkeys {
    param($Ui, [string]$ExceptKey = '')

    $taken = @()
    foreach ($key in @($Ui.Hotkeys.Keys)) {
        if ($ExceptKey -and $key -eq $ExceptKey) { continue }
        $parsed = ConvertFrom-HotkeyString ([string]$Ui.Hotkeys[$key])
        if ($parsed) { $taken += $parsed.Text }
    }
    return $taken
}

# --- список режимов ---------------------------------------------------------
# Перестраивается при каждой правке: режимы — производная от стола и от списка
# комбинаций, и строки обязаны показывать то, что будет после Save. Клавиша и
# яркость живут не в строках, а в $Ui.Hotkeys и $Ui.Levels: строка их только
# показывает, правит редактор.

# Короткая правда о яркости режима — в подпись строки. Иначе настройку, спрятанную
# за кнопкой Edit, не видно, пока не откроешь каждый режим по очереди.
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

# Записи, привязанные к режимам, — в порядке самих режимов. Что порядку не
# соответствует (настройка от режима, которого больше нет), едет следом, в том
# порядке, в котором лежало. Чистая функция.
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

# Какие строки показывать в списке режимов — и в каком порядке. Ничего не рисует:
# считает список и раскладывает по нему записи окна.
#
# $InitialModes приходит с первым вызовом из New-SettingsWindow (режимы уже
# посчитаны снаружи, вместе со строками-сиротами); $null означает пересчёт после
# правок, и тогда комбинации берутся из рабочего списка окна, а не из настроек, с
# которыми окно открывалось.
function Resolve-PanelModes {
    param($Ui, $InitialModes)

    $modes = $InitialModes
    if ($null -eq $modes) {
        $settings = @{ combos = (ConvertTo-ComboSettings -Combos $Ui.Combos) }
        $modes = @(Get-DisplayModes -State $Ui.State -Settings $settings)
    }
    $modes = @($modes)

    # Настройки без режима — своей строкой. Клавиша занята глобально
    # (RegisterHotKey работает независимо от наличия монитора), а яркость висит
    # на ключе, которого больше нет; увидеть и снять то и другое можно только
    # отсюда. Пустая модель яркости строки не держит: она заводится от одного
    # захода в редактор и ничего не значит.
    $known = @($modes | ForEach-Object { [string]$_.Key })
    $strays = @()
    foreach ($key in @(@($Ui.Hotkeys.Keys) + @($Ui.Levels.Keys))) {
        $key = [string]$key
        if (-not $key -or $known -contains $key -or $strays -contains $key) { continue }
        if (-not $Ui.Hotkeys.Contains($key)) {
            if ($null -eq (ConvertFrom-LevelModel $Ui.Levels[$key])) { continue }
        }
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

    # Записи выстраиваем по порядку режимов: иначе settings.json перетасовывался
    # бы от того, в каком порядке человек открывал редакторы, и каждая правка
    # одной клавиши переписывала бы полфайла.
    $Ui.Hotkeys = Get-MapInModeOrder -Map $Ui.Hotkeys -Modes $modes
    $Ui.Levels  = Get-MapInModeOrder -Map $Ui.Levels  -Modes $modes

    return @($modes)
}

function Update-ModesPanel {
    param(
        $Ui,
        # Первый вызов из New-SettingsWindow: режимы уже посчитаны снаружи (вместе
        # со строками-сиротами), а клавиши берутся из настроек.
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
        $row.Margin = New-Object System.Windows.Thickness 0, 5, 0, 5
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

        # Клавиша — надписью, а не полем: правится она там же, где всё остальное
        # про режим. Место под неё занято всегда, иначе кнопки прыгали бы по
        # строке от одной привязки к другой.
        $shortcut = [string]$(if ($Ui.Hotkeys.Contains($key)) { $Ui.Hotkeys[$key] } else { '' })
        $keyText = New-UiTextBlock -Text $(if ($shortcut) { $shortcut } else { $script:NoHotkeyText }) `
                                   -Style 'RowSub' -Window $win
        $keyText.MinWidth = 110
        $keyText.TextAlignment = 'Right'
        $keyText.VerticalAlignment = 'Center'
        $keyText.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0
        if ($shortcut) { $keyText.Foreground = $win.FindResource('TextBrush') }
        [System.Windows.Controls.Grid]::SetColumn($keyText, 1)
        [void]$row.Children.Add($keyText)

        # Именно кнопки с рамкой, а не приглушённые надписи: плоские Edit/Remove
        # первый же человек принял за подписи и не нашёл, как удалить комбинацию.
        if ($mode.Kind -ne 'orphan') {
            $edit = New-Object System.Windows.Controls.Button
            $edit.Content = 'Edit'
            $edit.Style = $win.FindResource('BtnSmall')
            $edit.VerticalAlignment = 'Center'
            # За какой режим отвечает кнопка — на самой кнопке: обработчики этого
            # окна замыканий не держат (см. комментарий выше).
            $edit.Tag = $mode
            [System.Windows.Controls.Grid]::SetColumn($edit, 2)
            [void]$row.Children.Add($edit)
            $edit.add_Click({
                $ui = $script:ActiveUi
                $mode = $this.Tag
                if (-not $ui -or -not $mode) { return }
                $combo = $null
                if ([string]$mode.Kind -eq 'combo') {
                    $name = ([string]$mode.Key).Substring(6)
                    $combo = @($ui.Combos | Where-Object { $_.Name -eq $name } | Select-Object -First 1)[0]
                }
                Invoke-ModeEditor -Ui $ui -Mode $mode -Combo $combo
            })
        }

        # Убрать можно то, что человек завёл сам, и то, от чего остался один
        # ключ. Режим монитора и «all» не удаляются: они есть, пока есть стол.
        if ($mode.Kind -eq 'combo' -or $mode.Kind -eq 'orphan') {
            $remove = New-Object System.Windows.Controls.Button
            $remove.Content = 'Remove'
            $remove.Style = $win.FindResource('BtnSmall')
            $remove.VerticalAlignment = 'Center'
            $remove.Margin = New-Object System.Windows.Thickness 6, 0, 0, 0
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
                $name = ([string]$mode.Key).Substring(6)
                $combo = @($ui.Combos | Where-Object { $_.Name -eq $name } | Select-Object -First 1)[0]
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

# --- переезд ключей режимов -------------------------------------------------
# Ключ комбинации — `combo:<имя>`, то есть переименование в окне меняет ключ, а
# удаление его уносит. Всё, что к ключам режимов привязано (звук, команды,
# яркость, контраст, правила, «монитор появился»), обязано переехать вместе с
# ними — иначе остаётся настройка-призрак, которую не видно ни в одном окне, или
# правило, каждые пятнадцать секунд уходящее в режим, которого нет.

# Старый ключ -> новый, по тем комбинациям, которые в окне переименовали.
#
# Словарь УПОРЯДОЧЕННЫЙ, в порядке списка комбинаций, и это не косметика: два
# переименования могут выстроиться в цепочку (одну комбинацию назвали «B», другая
# при этом «B» освободила), и тогда от порядка применения зависит, доедет ли
# первая запись до нового ключа. Пусть он будет предсказуемым.
function Get-ComboRenames {
    param($Combos)

    $renames = [ordered]@{}
    foreach ($c in @($Combos)) {
        if (-not $c.OriginalName -or $c.OriginalName -eq $c.Name) { continue }
        $renames['combo:' + $c.OriginalName] = 'combo:' + $c.Name
    }
    return $renames
}

# Словарь «ключ режима -> значение» после переименований и удалений. Запись
# переезжает НА СВОЁМ МЕСТЕ: словари уезжают в settings.json как есть, и ключ,
# дописанный в конец секции, выглядел бы в git-диффе правкой, которой никто не
# делал. $What — только для журнала.
function Move-ModeKeyedEntries {
    param($Source, $Renames, [string[]]$Gone = @(), [string]$What = 'setting')

    $moved = [ordered]@{}
    if (-not $Source) { return $moved }

    # Ключи, которые никуда не переезжают: их значения свои, и отдавать своё место
    # переезжающему они не обязаны.
    $taken = @{}
    foreach ($k in @($Source.Keys)) {
        if (-not $Renames.Contains([string]$k)) { $taken[[string]$k] = $true }
    }

    foreach ($k in @($Source.Keys)) {
        $key = [string]$k
        if ($Renames.Contains($key)) {
            $new = [string]$Renames[$key]
            # Новый ключ занят своим значением — оно важнее переезжающего, а
            # переезжающее теряется вместе со старым именем.
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

# Правила после переименований и удалений. ПЕРЕСОБИРАЕМ, а не правим на месте:
# результат Save — копия, и неудачная запись на диск не должна оставлять правку в
# настройках, с которыми живёт трей.
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
                # Пустое «куда возвращаться» — это «туда, где стол был до
                # срабатывания», законное значение (см. Get-RuleDecision).
                $copy[$field] = ''
                Write-DisplayLog "settings: dropped the $field of a rule for removed $v"
            }
        }
        # А вот правило без режима — уже не правило: уходить некуда.
        if (-not [string]$copy['mode']) {
            Write-DisplayLog 'settings: dropped a rule whose mode was removed'
            continue
        }
        $out += $copy
    }
    return @($out)
}

# --- сбор настроек из окна --------------------------------------------------
# Отдельной функцией и без показа окна: это и есть проверяемая часть Save.
# Возвращает Ok/Settings/Problem; при Problem окно остаётся открытым.

function Read-SettingsFromUi {
    param($Ui, $Settings)

    # Комбинации клавиш — с проверкой на дубликаты: два режима на одной клавише —
    # это неразрешимая двусмысленность, а не предупреждение.
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

    # Сохраняем в КОПИЮ, а не в переданный объект: $Settings — это тот же словарь,
    # с которым живёт трей, и неудачная запись на диск не должна оставлять три
    # разные версии настроек (в памяти, на диске и в зарегистрированных клавишах).
    $updated = Get-DefaultSettings
    $updated.hotkeys = $newHotkeys
    $updated.maximizeRefresh = [bool]$Ui.RefreshBox.IsChecked
    $updated.notifications = [bool]$Ui.NotifyBox.IsChecked
    $updated.restoreWindows = [bool]$Ui.WindowsBox.IsChecked
    $updated.restoreLastMode = [bool]$Ui.LastModeBox.IsChecked
    $updated.stats = [bool]$Ui.StatsBox.IsChecked

    # Окно правит только то, что в нём есть; остальные поля обязаны проехать
    # насквозь и НЕ уехать дефолтными — на этом уже терялись layout и primary.
    # Переносится всё, кроме полей с элементами формы, чтобы каждая новая
    # настройка без своего элемента не заводила этот баг заново.
    $fromForm = @('hotkeys', 'maximizeRefresh', 'notifications', 'restoreWindows',
                  'restoreLastMode', 'stats', 'layout', 'primary', 'combos', 'audio')
    foreach ($k in @($Settings.Keys)) {
        if ($fromForm -contains $k) { continue }
        $updated[$k] = $Settings[$k]
    }

    # Раскладка и панель задач — из карточек стола, в их видимом порядке.
    $labels = @()
    $primary = ''
    foreach ($card in @($Ui.DeskPanel.Children)) {
        $info = $card.Tag
        if (-not $info) { continue }
        $labels += [string]$info.Label
        if ($info.Radio -and $info.Radio.IsChecked) { $primary = [string]$info.Label }
    }
    $updated.layout = $labels
    # Звезду не ставили — оставляем как было: пустая строка стёрла бы выбор,
    # который человек не отменял.
    $updated.primary = $(if ($primary) { $primary } else { [string]$Settings.primary })

    $updated.combos = ConvertTo-ComboSettings -Combos $Ui.Combos

    # Звук, команды, яркость и контраст привязаны к ключам режимов, а у
    # комбинаций эти ключи меняются вместе с именем: запись переезжает за
    # переименованием и умирает с удалением. Иначе осталась бы настройка-призрак,
    # которую не видно ни в одном окне. Одним циклом на все четыре: следующая
    # настройка, привязанная к режиму, не должна заводить этот баг заново.
    $currentComboKeys = @($Ui.Combos | ForEach-Object { 'combo:' + $_.Name })
    $renames = Get-ComboRenames -Combos $Ui.Combos
    $gone = @(@($Ui.DeletedComboKeys) | Where-Object { $_ -and $currentComboKeys -notcontains $_ })

    foreach ($field in 'audio', 'hooks', 'brightness', 'contrast') {
        # Яркость приезжает из карточки с ползунками, остальное — из настроек как
        # было: окно этого не правит. Отсюда и разные карты переезда. Звук,
        # команды и контраст лежат под ТЕМИ ключами, что в файле, — их надо
        # переименовать. А яркость Set-UiMode перекладывает на новый ключ сразу
        # при правке, и второе применение карты не просто лишнее: комбинация,
        # занявшая освободившееся имя, совпала бы с ИСТОЧНИКОМ переименования и
        # молча потеряла бы свою яркость.
        $source = $Settings[$field]
        $map = $renames
        if ($field -eq 'brightness') {
            $source = ConvertTo-BrightnessSettings -Levels $Ui.Levels
            $map = [ordered]@{}
        }
        $updated[$field] = Move-ModeKeyedEntries -Source $source -Renames $map -Gone $gone -What $field
    }

    # Правила и «монитор появился» ссылаются на режимы ТЕМИ ЖЕ ключами, значит и
    # переезжать должны вместе с ними: комбинацию переименовали — правило обязано
    # смотреть на новое имя, удалили — правило про неё больше не правило. Иначе
    # осталось бы правило, которое каждые пятнадцать секунд уходит в режим,
    # которого нет, и переключение отвечало бы «combination no longer exists».
    # То же делает Update-HotkeyKeys, когда монитор переехал на другой вход.
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

# --- показ ------------------------------------------------------------------

# Режимы для окна: настоящие плюс строки-сироты для привязок, чьих режимов
# сейчас нет (монитор увезли, комбинацию переименовали или стёрли рукой из
# файла). Клавиша-то занята глобально — RegisterHotKey работает независимо от
# наличия монитора, — и увидеть или снять её можно только из окна.
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

# Возвращает изменённые настройки, либо $null если отменили. Иконку окно берёт с
# диска само (Register-WindowTheme): WPF нужен ImageSource, а не GDI-иконка.
function Show-SettingsDialog {
    param($State, $Settings)

    # Страховка: если настройки не доехали, читаем их с диска, а не падаем на
    # обращении к $null.
    if (-not $Settings -or -not $Settings.hotkeys) {
        Write-DisplayLog 'settings dialog: settings arrived empty, reading them from disk'
        $Settings = Get-DisplaySettings
    }

    $modes = @(Get-DialogModes -State $State -Settings $Settings)

    $ui = New-SettingsWindow -Modes $modes -Settings $Settings -State $State

    # Галочку автозагрузки читаем из факта наличия ярлыка, а не из настроек:
    # ярлык могли удалить руками.
    $ui.StartupBox.IsChecked = (Test-RunAtStartup)

    try {
        if (-not $ui.Window.ShowDialog()) { return $null }
        $updated = $ui.Result
        if (-not $updated) { return $null }

        Save-DisplaySettings $updated
        Set-RunAtStartup ([bool]$ui.StartupBox.IsChecked)
        return $updated
    }
    finally {
        $ui.Window.Close()
        $script:ActiveUi = $null
    }
}
