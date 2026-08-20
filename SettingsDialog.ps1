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

# --- WPF ----------------------------------------------------------------------
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

# --- палитра ------------------------------------------------------------------
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

# --- разметка -----------------------------------------------------------------
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
                    </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                    <StackPanel>
                        <TextBlock Style="{StaticResource H2}" Text="Combinations"/>
                        <TextBlock Style="{StaticResource Hint}"
                                   Text="Your own modes: any set of displays under a name you choose, with the taskbar wherever you want it. One display can be in as many combinations as you like. Each one gets an entry in the tray menu, a shortcut if you want one, and a Remove button right here."/>
                        <StackPanel x:Name="CombosPanel"/>
                        <Button x:Name="AddComboBtn" Style="{StaticResource Btn}" Content="Add a combination"
                                HorizontalAlignment="Left" Margin="0,6,0,0"/>
                    </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                    <StackPanel>
                        <TextBlock Style="{StaticResource H2}" Text="Keyboard shortcuts"/>
                        <TextBlock Style="{StaticResource Hint}"
                                   Text="Every mode you can switch to: one per display, every combination you made, and all of them at once. Click a box and press the keys; the cross removes a shortcut. Modes are not removed here - a display's mode exists while the display does, and a combination is removed in the card above."/>
                        <StackPanel x:Name="ModesPanel"/>
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
                    </StackPanel>
                </Border>
            </StackPanel>
        </ScrollViewer>
    </DockPanel>
</Window>
'@

$script:ComboEditorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ScreenDeck - Combination"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        Background="%%BG%%" Foreground="%%TEXT%%"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        UseLayoutRounding="True">
    <Window.Resources>
%%RES%%
    </Window.Resources>
    <StackPanel Margin="20,16" Width="330">
        <TextBlock Style="{StaticResource H2}" Text="Name"/>
        <TextBox x:Name="NameBox" Style="{StaticResource Input}" Margin="0,4,0,0"/>
        <TextBlock Style="{StaticResource H2}" Text="Displays" Margin="0,16,0,0"/>
        <TextBlock Style="{StaticResource Hint}" Text="Tick every display this combination switches on."/>
        <StackPanel x:Name="MembersPanel"/>
        <TextBlock Style="{StaticResource H2}" Text="Taskbar" Margin="0,14,0,0"/>
        <TextBlock Style="{StaticResource Hint}" Text="Which display keeps the taskbar while this combination is on."/>
        <ComboBox x:Name="PrimaryBox" Style="{StaticResource Select}" Height="30"/>
        <TextBlock Style="{StaticResource H2}" Text="Shortcut" Margin="0,16,0,0"/>
        <TextBlock Style="{StaticResource Hint}" Text="Optional - the combination works from the tray menu either way. Click the box and press the keys: Ctrl, Alt, Shift or Win plus something."/>
        <StackPanel Orientation="Horizontal">
            <TextBox x:Name="HotkeyBox" Style="{StaticResource Input}" Width="150" TextAlignment="Center"/>
            <Button x:Name="ClearHotkeyBtn" Style="{StaticResource BtnSubtle}" Content="&#x00D7;"
                    FontSize="15" Width="26" Margin="4,0,0,0" VerticalAlignment="Center"
                    ToolTip="Remove this shortcut"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
            <Button x:Name="OkBtn" Style="{StaticResource BtnAccent}" Content="Save" Width="90" IsDefault="True"/>
            <Button x:Name="CancelBtn" Style="{StaticResource Btn}" Content="Cancel" Width="90" Margin="8,0,0,0" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
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

# --- обработчики событий: почему без .GetNewClosure() ---------------------------
# Обработчик, созданный через .GetNewClosure(), получает собственную область, и
# из неё не разрешается ни $script: (об этом в проекте уже есть комментарий у
# Get-ActiveSettings), ни — как выяснилось 2026-08-19 — имена функций, если
# замыкание создано в дот-сорснутом файле и вызывается WPF через делегат: клик
# по кнопке падал с «ConvertFrom-HotkeyString is not recognized». Поймали тесты,
# и это было не свойство тестов: тем же путём шли Save и все кнопки окна.
#
# Поэтому здесь ни один обработчик не замыкается. Всё, что ему нужно, приезжает
# двумя путями: состояние окна — через $script:ActiveUi, состояние конкретной
# строки — через .Tag самого элемента (внутри блока он доступен как $this).
# Плоский блок сохраняет область файла, и функции с $script: в нём работают.

# Окно, с которым идёт работа прямо сейчас. Одно на процесс: окно модальное, двух
# сразу быть не может. Редактор комбинации держит своё в $script:ActiveEditor.
$script:ActiveUi = $null
$script:ActiveEditor = $null

# Тёмный заголовок окна — сразу после появления HWND (раньше его просто нет).
function Register-WindowTheme {
    param($Window, [bool]$Dark)

    # Тёмность — на самом окне: обработчик получит его как $this.
    $Window.Tag = [pscustomobject]@{ Dark = $Dark }
    $Window.add_SourceInitialized({
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper $this).Handle
            [NativeTheme]::TryDarkTitleBar($h, [bool]$this.Tag.Dark)
        }
        catch { }
    })

    try {
        $ico = Join-Path $script:ToolRoot 'app.ico'
        if (Test-Path $ico) {
            $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create(
                (New-Object System.Uri $ico), 'None', 'OnLoad')
        }
    }
    catch { }
}

# --- мелкие фабрики -----------------------------------------------------------

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

# Приём комбинации клавиш. Той же логикой, что и в WinForms-версии: ловим
# PreviewKeyDown, ждём основную клавишу при зажатых модификаторах. Биты
# ModifierKeys у WPF совпадают с MOD_* у RegisterHotKey (Alt 1, Ctrl 2, Shift 4,
# Win 8) — перекодировка не нужна, совпадение проверено тестом маппинга.
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
        $text = Format-HotkeyString $mods $vk
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
# Происхождение — не украшение. Пока в проекте были и группы, и комбинации,
# «Work displays» и «Movie night» в списке выглядели одинаково, а удалялись
# по-разному; вопрос «а Work displays — это комбинация?» прозвучал трижды. Групп
# больше нет (роли переехали в комбинации), но подпись осталась: она отвечает,
# почему у одной строки есть кнопка Remove, а у другой нет — режим монитора и
# «все» появляются сами, комбинацию создаёшь и удаляешь ты.
function Get-ModeSubtitle {
    param($Mode, $State)

    switch ([string]$Mode.Kind) {
        'solo'   { return 'Display' }
        'combo'  {
            $text = 'Combination  -  ' + (@($Mode.Patterns) -join ' + ')
            if ($Mode.Primary) { $text += '   (taskbar on ' + $Mode.Primary + ')' }
            return $text
        }
        'all'    { return 'Every connected display' }
        'orphan' { return 'Not connected now - the shortcut stays reserved' }
    }
    return ''
}

# --- сборка окна ---------------------------------------------------------------

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
    try { $win.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height - 40 } catch { }

    $ui = [pscustomobject]@{
        Window            = $win
        Dark              = $dark
        Boxes             = [ordered]@{}   # ключ режима -> поле комбинации клавиш
        Combos            = (New-Object System.Collections.ArrayList)
        DeletedComboKeys  = @()
        DeskPanel         = $win.FindName('DeskPanel')
        CombosPanel       = $win.FindName('CombosPanel')
        ModesPanel        = $win.FindName('ModesPanel')
        AddComboBtn       = $win.FindName('AddComboBtn')
        SaveBtn           = $win.FindName('SaveBtn')
        CancelBtn         = $win.FindName('CancelBtn')
        StartupBox        = $win.FindName('StartupBox')
        RefreshBox        = $win.FindName('RefreshBox')
        NotifyBox         = $win.FindName('NotifyBox')
        WindowsBox        = $win.FindName('WindowsBox')
        LastModeBox       = $win.FindName('LastModeBox')
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

    Update-DeskPanel  -Ui $ui
    Update-CombosPanel -Ui $ui
    Update-ModesPanel -Ui $ui -InitialModes $Modes -InitialHotkeys $Settings.hotkeys

    $ui.RefreshBox.IsChecked  = [bool]$Settings.maximizeRefresh
    $ui.NotifyBox.IsChecked   = [bool]$Settings.notifications
    # Отсутствие ключа в старом settings.json означает «по умолчанию», то есть
    # включено — ровно как в WinForms-версии, на этом уже ломался restoreWindows.
    $ui.WindowsBox.IsChecked  = ($null -eq $Settings.restoreWindows -or [bool]$Settings.restoreWindows)
    $ui.LastModeBox.IsChecked = ($null -eq $Settings.restoreLastMode -or [bool]$Settings.restoreLastMode)

    # Окно собрано — с этого момента обработчики находят его здесь.
    $script:ActiveUi = $ui

    $ui.AddComboBtn.add_Click({
        $ui = $script:ActiveUi
        if (-not $ui) { return }
        $taken = @($ui.Combos | ForEach-Object { $_.Name })
        $made = Show-ComboEditor -Combo $null -State $ui.State -TakenNames $taken `
                                 -TakenHotkeys (Get-TakenHotkeys -Ui $ui) -Owner $ui.Window -Dark $ui.Dark
        if ($made) { Set-UiCombo -Ui $ui -Combo $null -Edited $made }
    })

    # Save проверяет ввод ДО закрытия: старое окно на дубликате комбинации клавиш
    # закрывалось и выбрасывало все правки, теперь оно остаётся открытым.
    $ui.SaveBtn.add_Click({
        $ui = $script:ActiveUi
        if (-not $ui) { return }
        $got = Read-SettingsFromUi -Ui $ui -Settings $ui.Settings -State $ui.State
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

# --- стол: порядок и панель задач ----------------------------------------------
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

    $outer.Tag = [pscustomobject]@{
        Label     = $Label
        ShortId   = $(if ($Display) { [string]$Display.ShortId } else { '' })
        Connected = $connected
        Radio     = $radio
    }

    # Стрелке нужны ряд и своя карточка — приезжают на ней самой (см. комментарий
    # про обработчики выше). Ряд не через $script:ActiveUi: карточки строятся до
    # того, как окно объявлено активным.
    $panel = $Ui.DeskPanel
    $left.Tag  = [pscustomobject]@{ Panel = $panel; Card = $outer; Delta = -1 }
    $right.Tag = [pscustomobject]@{ Panel = $panel; Card = $outer; Delta = 1 }
    $move = { Move-DeskCard -Panel $this.Tag.Panel -Card $this.Tag.Card -Delta $this.Tag.Delta }
    $left.add_Click($move)
    $right.add_Click($move)

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

# --- комбинации -----------------------------------------------------------------

# Применить результат редактора к рабочему списку: $Combo — существующая запись,
# $null — новая. Отдельно от обработчиков кликов: это и есть проверяемая часть
# правки комбинаций, обработчики только зовут редактор и передают его ответ сюда.
function Set-UiCombo {
    param($Ui, $Combo, $Edited)

    if (-not $Edited) { return }
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
    # Вернули имя, которое в этом же сеансе удаляли, — удаление отменилось.
    $Ui.DeletedComboKeys = @($Ui.DeletedComboKeys | Where-Object { $_ -ne ('combo:' + $Edited.Name) })
    Update-CombosPanel -Ui $Ui
    Update-ModesPanel -Ui $Ui

    # Клавиша из редактора — в поле главного окна: правда о привязках одна, и
    # живёт она в полях. Пустая строка честно означает «клавиши нет» — человек
    # мог и снять её.
    if ($null -ne $Edited.PSObject.Properties['Hotkey']) {
        $key = 'combo:' + $Edited.Name
        if ($Ui.Boxes.Contains($key)) {
            $parsed = ConvertFrom-HotkeyString ([string]$Edited.Hotkey)
            $Ui.Boxes[$key].Text = $(if ($parsed) { $parsed.Text } else { $script:NoHotkeyText })
        }
    }
}

function Remove-UiCombo {
    param($Ui, $Combo)

    # Помним оба ключа: под OriginalName комбинация лежит в файле (звук), под
    # текущим именем — в полях клавиш этого окна.
    $keys = @('combo:' + $Combo.Name)
    if ($Combo.OriginalName) { $keys += ('combo:' + $Combo.OriginalName) }
    $Ui.DeletedComboKeys = @($Ui.DeletedComboKeys) + $keys
    $Ui.Combos.Remove($Combo)
    Update-CombosPanel -Ui $Ui
    Update-ModesPanel -Ui $Ui
}

function Update-CombosPanel {
    param($Ui)

    $Ui.CombosPanel.Children.Clear()
    $win = $Ui.Window

    if ($Ui.Combos.Count -eq 0) {
        $none = New-UiTextBlock -Text 'No combinations yet.' -Style 'RowSub' -Window $win
        $none.Margin = New-Object System.Windows.Thickness 0, 2, 0, 2
        [void]$Ui.CombosPanel.Children.Add($none)
        return
    }

    foreach ($combo in @($Ui.Combos)) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = New-Object System.Windows.Thickness 0, 4, 0, 4
        $c0 = New-Object System.Windows.Controls.ColumnDefinition
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        $c1.Width = [System.Windows.GridLength]::Auto
        $c2 = New-Object System.Windows.Controls.ColumnDefinition
        $c2.Width = [System.Windows.GridLength]::Auto
        [void]$row.ColumnDefinitions.Add($c0)
        [void]$row.ColumnDefinitions.Add($c1)
        [void]$row.ColumnDefinitions.Add($c2)

        $textStack = New-Object System.Windows.Controls.StackPanel
        $title = New-UiTextBlock -Text $combo.Name -Style 'RowTitle' -Window $win
        $title.FontWeight = 'SemiBold'
        [void]$textStack.Children.Add($title)
        $subText = (@($combo.Patterns) -join ' + ')
        if ($combo.Primary) { $subText += '   (taskbar on ' + $combo.Primary + ')' }
        $sub = New-UiTextBlock -Text $subText -Style 'RowSub' -Window $win
        [void]$textStack.Children.Add($sub)
        [void]$row.Children.Add($textStack)

        # Именно кнопки с рамкой, а не приглушённые надписи: плоские Edit/Remove
        # первый же человек принял за подписи и не нашёл, как удалить комбинацию.
        $edit = New-Object System.Windows.Controls.Button
        $edit.Content = 'Edit'
        $edit.Style = $win.FindResource('BtnSmall')
        $edit.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($edit, 1)
        [void]$row.Children.Add($edit)

        $remove = New-Object System.Windows.Controls.Button
        $remove.Content = 'Remove'
        $remove.Style = $win.FindResource('BtnSmall')
        $remove.VerticalAlignment = 'Center'
        $remove.Margin = New-Object System.Windows.Thickness 6, 0, 0, 0
        [System.Windows.Controls.Grid]::SetColumn($remove, 2)
        [void]$row.Children.Add($remove)

        # Какую комбинацию правит эта кнопка — на самой кнопке.
        $edit.Tag = $combo
        $remove.Tag = $combo

        $edit.add_Click({
            $ui = $script:ActiveUi
            $combo = $this.Tag
            if (-not $ui -or -not $combo) { return }
            $taken = @($ui.Combos | Where-Object { $_ -ne $combo } | ForEach-Object { $_.Name })
            $key = 'combo:' + $combo.Name
            $current = ''
            if ($ui.Boxes.Contains($key)) { $current = $ui.Boxes[$key].Text }
            $made = Show-ComboEditor -Combo $combo -State $ui.State -TakenNames $taken `
                                     -Hotkey $current -TakenHotkeys (Get-TakenHotkeys -Ui $ui -ExceptKey $key) `
                                     -Owner $ui.Window -Dark $ui.Dark
            if ($made) { Set-UiCombo -Ui $ui -Combo $combo -Edited $made }
        })

        $remove.add_Click({
            $ui = $script:ActiveUi
            if ($ui -and $this.Tag) { Remove-UiCombo -Ui $ui -Combo $this.Tag }
        })

        [void]$Ui.CombosPanel.Children.Add($row)
    }
}

# Редактор одной комбинации: сборка отдельно от показа, по той же причине, что
# и у главного окна, — собранное без показа окно можно проверить.
function New-ComboEditorWindow {
    param(
        $Combo,          # $null — создание новой
        $State,
        [string[]]$TakenNames = @(),
        # Комбинация — это не только клавиша, но клавишу человек хочет назначить
        # там же, где создаёт набор, а не идти за ней в другую карточку. Поэтому
        # поле шортката живёт и здесь; правда о привязках остаётся в полях
        # главного окна — сюда приезжает текущий текст, обратно — новый.
        [string]$Hotkey = '',
        # Комбинации, занятые другими режимами: назначить одну клавишу дважды
        # нельзя, и сказать об этом надо сейчас, а не после закрытия редактора.
        [string[]]$TakenHotkeys = @(),
        $Owner,
        [bool]$Dark
    )

    Initialize-WpfRuntime
    $palette = Get-UiPalette -Dark $Dark
    $win = Convert-UiXaml -Xaml $script:ComboEditorXaml -Palette $palette
    Register-WindowTheme -Window $win -Dark $Dark
    if ($Owner) { $win.Owner = $Owner }

    $nameBox = $win.FindName('NameBox')
    $membersPanel = $win.FindName('MembersPanel')
    $primaryBox = $win.FindName('PrimaryBox')
    $hotkeyBox = $win.FindName('HotkeyBox')
    $okBtn = $win.FindName('OkBtn')

    $hotkeyBox.Cursor = [System.Windows.Input.Cursors]::Hand
    Register-HotkeyCapture -Box $hotkeyBox
    $parsedHotkey = ConvertFrom-HotkeyString $Hotkey
    $hotkeyBox.Text = $(if ($parsedHotkey) { $parsedHotkey.Text } else { $script:NoHotkeyText })

    $clearHotkey = $win.FindName('ClearHotkeyBtn')
    $clearHotkey.IsEnabled = [bool]$parsedHotkey
    Register-HotkeyClearButton -Box $hotkeyBox -Button $clearHotkey

    $patterns = @()
    if ($Combo) {
        $nameBox.Text = [string]$Combo.Name
        $patterns = @($Combo.Patterns)
    }

    # Галочки: все подключённые мониторы, затем шаблоны комбинации, не совпавшие
    # ни с одним из них, — монитор увезли, но выбрасывать его из комбинации молча
    # нельзя. Tag хранит точную строку, которая уедет в settings.json.
    $checks = @()
    $live = @($State | Where-Object { $_ -and -not $_.Disconnected })
    foreach ($m in $live) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $win.FindResource('Check')
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
        foreach ($m in $live) {
            if (Test-DisplayNameMatch -Pattern $pat -Label $m.Label -ShortId $m.ShortId) { $matched = $true; break }
        }
        if ($matched) { continue }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $win.FindResource('Check')
        $cb.Content = ([string]$pat + '   (not connected)')
        $cb.Tag = [string]$pat
        $cb.IsChecked = $true
        [void]$membersPanel.Children.Add($cb)
        $checks += $cb
    }

    $defaultChoice = 'Follow the usual rules'
    [void]$primaryBox.Items.Add($defaultChoice)
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

    $ed = [pscustomobject]@{
        Window       = $win
        NameBox      = $nameBox
        Checks       = $checks
        PrimaryBox   = $primaryBox
        HotkeyBox    = $hotkeyBox
        TakenNames   = @($TakenNames)
        TakenHotkeys = @($TakenHotkeys)
        Result       = $null
    }
    # Обработчик Save находит редактор здесь, а не в замыкании: см. комментарий об
    # обработчиках выше. Редактор модальный, поэтому одного места достаточно.
    $script:ActiveEditor = $ed

    $okBtn.add_Click({
        $ed = $script:ActiveEditor
        if (-not $ed) { return }
        $got = Read-ComboFromUi -Editor $ed
        if (-not $got.Ok) {
            [void][System.Windows.MessageBox]::Show($ed.Window, $got.Problem, 'ScreenDeck',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
        $ed.Result = $got.Combo
        $ed.Window.DialogResult = $true
    })

    return $ed
}

# Что человек набрал в редакторе комбинации, с проверкой. Отдельной функцией — как
# и Read-SettingsFromUi у главного окна: проверяемо без показа окна.
function Read-ComboFromUi {
    param($Editor)

    $name = $Editor.NameBox.Text.Trim()
    $chosen = @($Editor.Checks | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    $prim = ''
    if ($Editor.PrimaryBox.SelectedIndex -gt 0) { $prim = [string]$Editor.PrimaryBox.SelectedItem }
    # В поле может стоять и «no shortcut», и подсказка «needs Ctrl…» — клавишей
    # считается только то, что разбирается. Пусто — значит без клавиши.
    $hk = ''
    $parsed = ConvertFrom-HotkeyString $Editor.HotkeyBox.Text
    if ($parsed) { $hk = $parsed.Text }

    $problem = ''
    if (-not $name) { $problem = 'Give the combination a name - it becomes its menu entry.' }
    elseif (@($Editor.TakenNames | Where-Object { $_ -and $_ -ieq $name }).Count -gt 0) {
        $problem = "A combination called '$name' already exists."
    }
    elseif ($chosen.Count -eq 0) { $problem = 'Tick at least one display.' }
    elseif ($prim -and $chosen -notcontains $prim) {
        $problem = 'The taskbar display must be one of the ticked displays.'
    }
    elseif ($hk -and @($Editor.TakenHotkeys) -contains $hk) {
        $problem = "$hk already drives another mode. Each combination of keys can only drive one."
    }
    if ($problem) { return [pscustomobject]@{ Ok = $false; Combo = $null; Problem = $problem } }

    return [pscustomobject]@{
        Ok = $true
        Combo = [pscustomobject]@{ Name = $name; Patterns = $chosen; Primary = $prim; Hotkey = $hk }
        Problem = ''
    }
}

# Показ редактора. Возвращает @{ Name; Patterns; Primary; Hotkey } или $null при отмене.
function Show-ComboEditor {
    param(
        $Combo,
        $State,
        [string[]]$TakenNames = @(),
        [string]$Hotkey = '',
        [string[]]$TakenHotkeys = @(),
        $Owner,
        [bool]$Dark
    )

    $ed = New-ComboEditorWindow -Combo $Combo -State $State -TakenNames $TakenNames `
                                -Hotkey $Hotkey -TakenHotkeys $TakenHotkeys -Owner $Owner -Dark $Dark
    try {
        if ($ed.Window.ShowDialog()) { return $ed.Result }
        return $null
    }
    finally {
        $ed.Window.Close()
        $script:ActiveEditor = $null
    }
}

# Комбинации клавиш, занятые всеми режимами, КРОМЕ одного (того, что сейчас в
# редакторе): его собственная клавиша — не конфликт.
function Get-TakenHotkeys {
    param($Ui, [string]$ExceptKey = '')

    $taken = @()
    foreach ($key in $Ui.Boxes.Keys) {
        if ($ExceptKey -and $key -eq $ExceptKey) { continue }
        $parsed = ConvertFrom-HotkeyString $Ui.Boxes[$key].Text
        if ($parsed) { $taken += $parsed.Text }
    }
    return $taken
}

# --- список режимов и клавиш ------------------------------------------------------
# Перестраивается при каждой правке групп и комбинаций: режимы — производная от
# них, и список обязан показывать то, что будет после Save. Уже введённые
# комбинации клавиш переживают перестроение в тайнике, ключом режима.

function Update-ModesPanel {
    param(
        $Ui,
        # Первый вызов из New-SettingsWindow: режимы уже посчитаны снаружи (вместе
        # со строками-сиротами), а клавиши берутся из настроек, не из полей.
        $InitialModes,
        $InitialHotkeys
    )

    $win = $Ui.Window

    # Тайник текущего ввода. При первом вызове — то, что лежит в настройках.
    $stash = [ordered]@{}
    if ($InitialHotkeys) {
        foreach ($k in @($InitialHotkeys.Keys)) { $stash[$k] = [string]$InitialHotkeys[$k] }
    }
    else {
        foreach ($k in @($Ui.Boxes.Keys)) { $stash[$k] = $Ui.Boxes[$k].Text }
    }

    # Переименованная комбинация увозит свою клавишу на новый ключ.
    foreach ($c in @($Ui.Combos)) {
        if (-not $c.OriginalName -or $c.OriginalName -eq $c.Name) { continue }
        $old = 'combo:' + $c.OriginalName
        $new = 'combo:' + $c.Name
        if ($stash.Contains($old)) {
            if (-not $stash.Contains($new)) { $stash[$new] = $stash[$old] }
            $stash.Remove($old)
        }
    }

    # Клавиши удалённых в этом окне комбинаций умирают вместе с ними — но только
    # если имя не воскресло заново.
    $currentComboKeys = @($Ui.Combos | ForEach-Object { 'combo:' + $_.Name })
    foreach ($dead in @($Ui.DeletedComboKeys)) {
        if ($currentComboKeys -contains $dead) { continue }
        if ($stash.Contains($dead)) { $stash.Remove($dead) }
    }

    $subState = @($Ui.State)

    $modes = $InitialModes
    if ($null -eq $modes) {
        # Пересчёт после правок: комбинации берём из рабочего списка окна, а не из
        # настроек, с которыми окно открывалось, — список клавиш обязан показывать
        # то, что будет после Save.
        $settings2 = @{ combos = (ConvertTo-ComboSettings -Combos $Ui.Combos) }
        $modes = @(Get-DisplayModes $Ui.State $settings2)

        # Привязки без режима (монитор увезли, комбинацию удалили) — своей
        # строкой: клавиша занята глобально, и снять её можно только отсюда.
        $known = @($modes | ForEach-Object { $_.Key })
        foreach ($key in @($stash.Keys)) {
            if ($known -contains $key) { continue }
            $modes += [pscustomobject]@{
                Key       = $key
                Title     = Get-ModeTitleFromKey $key
                Kind      = 'orphan'
                Available = $false
            }
        }
    }

    $Ui.ModesPanel.Children.Clear()
    $Ui.Boxes = [ordered]@{}

    foreach ($mode in @($modes)) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = New-Object System.Windows.Thickness 0, 4, 0, 4
        $c0 = New-Object System.Windows.Controls.ColumnDefinition
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        $c1.Width = [System.Windows.GridLength]::Auto
        [void]$row.ColumnDefinitions.Add($c0)
        [void]$row.ColumnDefinitions.Add($c1)

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
        $subText = Get-ModeSubtitle -Mode $mode -State $subState
        if ($subText) {
            $sub = New-UiTextBlock -Text $subText -Style 'RowSub' -Window $win
            [void]$textStack.Children.Add($sub)
        }
        [void]$row.Children.Add($textStack)

        # Поле клавиши и крестик рядом. Крестик — не украшение: снять привязку
        # можно было только Backspace'ом по строчке-подсказке, и первый же человек
        # решил, что клавиши вообще не убираются. Видимая кнопка отвечает на это
        # вопрос без чтения подсказок.
        $keyCell = New-Object System.Windows.Controls.StackPanel
        $keyCell.Orientation = 'Horizontal'
        $keyCell.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($keyCell, 1)
        [void]$row.Children.Add($keyCell)

        $box = New-Object System.Windows.Controls.TextBox
        $box.Style = $win.FindResource('Input')
        $box.Width = 150
        $box.TextAlignment = 'Center'
        $box.Cursor = [System.Windows.Input.Cursors]::Hand
        $box.VerticalAlignment = 'Center'
        # Ключ режима здесь не нужен: поля лежат в $Ui.Boxes под своими ключами, а
        # .Tag поля занят крестиком (Register-HotkeyClearButton).
        $existing = $null
        if ($stash.Contains($mode.Key)) { $existing = [string]$stash[$mode.Key] }
        if ($existing) { $box.Text = $existing } else { $box.Text = $script:NoHotkeyText }
        Register-HotkeyCapture -Box $box
        [void]$keyCell.Children.Add($box)

        $clear = New-Object System.Windows.Controls.Button
        $clear.Content = [string][char]0x00D7   # ×
        $clear.Style = $win.FindResource('BtnSubtle')
        $clear.FontSize = 15
        $clear.Width = 26
        $clear.Margin = New-Object System.Windows.Thickness 4, 0, 0, 0
        $clear.VerticalAlignment = 'Center'
        $clear.ToolTip = 'Remove this shortcut'
        # Нечего снимать — кнопка есть, но приглушена и не нажимается: пропадающая
        # кнопка дёргала бы строку по ширине на каждую правку.
        $clear.IsEnabled = [bool]$existing
        Register-HotkeyClearButton -Box $box -Button $clear
        [void]$keyCell.Children.Add($clear)

        [void]$Ui.ModesPanel.Children.Add($row)
        $Ui.Boxes[$mode.Key] = $box
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

# --- сбор настроек из окна --------------------------------------------------------
# Отдельной функцией и без показа окна: это и есть проверяемая часть Save.
# Возвращает Ok/Settings/Problem; при Problem окно остаётся открытым.

function Read-SettingsFromUi {
    param($Ui, $Settings, $State)

    # Комбинации клавиш — с проверкой на дубликаты. Как и раньше: два режима на
    # одной клавише — это неразрешимая двусмысленность, а не предупреждение.
    $newHotkeys = [ordered]@{}
    $seen = @{}
    foreach ($key in $Ui.Boxes.Keys) {
        $parsed = ConvertFrom-HotkeyString $Ui.Boxes[$key].Text
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

    # Окно правит только то, что в нём есть; остальные поля обязаны проехать
    # насквозь ДЕФОЛТНЫМИ они уезжать не должны — на этом уже терялись layout и
    # primary. Переносится всё, кроме полей с элементами формы, чтобы каждая
    # новая настройка без своего элемента не заводила этот баг заново.
    $fromForm = @('hotkeys', 'maximizeRefresh', 'notifications', 'restoreWindows',
                  'restoreLastMode', 'layout', 'primary', 'combos', 'audio')
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

    # roles в $updated остаётся пустым (из Get-DefaultSettings): роли из файла уже
    # превратились в комбинации на чтении, и записывать их обратно значило бы
    # заводить второй вид набора заново. Save заодно и вычищает их с диска.
    $updated.combos = ConvertTo-ComboSettings -Combos $Ui.Combos

    # Звук привязан к ключам режимов, и у комбинаций эти ключи меняются вместе с
    # именем: запись переезжает за переименованием и умирает с удалением. Иначе
    # осталась бы настройка-призрак, которую не видно ни в одном окне.
    $audio = [ordered]@{}
    if ($Settings.audio) {
        foreach ($k in @($Settings.audio.Keys)) { $audio[$k] = [string]$Settings.audio[$k] }
    }
    foreach ($c in @($Ui.Combos)) {
        if (-not $c.OriginalName -or $c.OriginalName -eq $c.Name) { continue }
        $old = 'combo:' + $c.OriginalName
        $new = 'combo:' + $c.Name
        if ($audio.Contains($old)) {
            if (-not $audio.Contains($new)) { $audio[$new] = $audio[$old] }
            $audio.Remove($old)
        }
    }
    $currentComboKeys = @($Ui.Combos | ForEach-Object { 'combo:' + $_.Name })
    foreach ($dead in @($Ui.DeletedComboKeys)) {
        if ($currentComboKeys -contains $dead) { continue }
        if ($audio.Contains($dead)) {
            $audio.Remove($dead)
            Write-DisplayLog "settings: dropped the audio entry for removed $dead"
        }
    }
    $updated.audio = $audio

    return [pscustomobject]@{ Ok = $true; Settings = $updated; Problem = '' }
}

# --- показ ------------------------------------------------------------------------

# Режимы для окна: настоящие плюс строки-сироты для привязок, чьих режимов
# сейчас нет (монитор увезли, группу переименовали, комбинацию стёрли рукой из
# файла). Клавиша-то занята глобально — RegisterHotKey работает независимо от
# наличия монитора, — и увидеть или снять её можно только из окна.
function Get-DialogModes {
    param($State, $Settings)

    $modes = @(Get-DisplayModes $State $Settings)
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

# Возвращает изменённые настройки, либо $null если отменили.
# $Icon оставлен в сигнатуре для совместимости с вызовом из трея; окно берёт
# app.ico с диска само — WPF нужен ImageSource, а не GDI-иконка.
function Show-SettingsDialog {
    param(
        $State,
        $Settings,
        $Icon
    )

    # Страховка: если настройки не доехали, читаем их с диска, а не падаем на
    # обращении к $null. Именно так это однажды и сломалось.
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
