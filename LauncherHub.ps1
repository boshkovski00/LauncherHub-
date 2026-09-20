param([switch]$Check, [switch]$Scan)

$ErrorActionPreference = 'Stop'
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$appData = Join-Path $env:APPDATA 'LauncherHub'
$configPath = Join-Path $appData 'config.json'
$statusPath = Join-Path $appData 'updates.json'
$helperPath = Join-Path $PSScriptRoot 'LauncherHubUpdates.ps1'
$startupFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
$catalog = @{
    'Battle.net'              = @{ Process = '^(Battle\.net|BattleNet)$'; Package = 'Blizzard.BattleNet'; Color = '#2C89FF' }
    'CurseForge'              = @{ Process = '^CurseForge$'; Package = ''; Color = '#F16B31' }
    'EA'                      = @{ Process = '^(EADesktop|EALauncher)$'; Package = 'ElectronicArts.EADesktop'; Color = '#FA5B59' }
    'Epic Games Launcher'     = @{ Process = '^EpicGamesLauncher$'; Package = 'EpicGames.EpicGamesLauncher'; Color = '#C2C5D3' }
    'FTB App'                 = @{ Process = '^(FTB|FTBApp|FTB App)$'; Package = ''; Color = '#F3A743' }
    'GOG GALAXY'              = @{ Process = '^GalaxyClient$'; Package = 'GOG.Galaxy'; Color = '#C56BFF' }
    'Overwolf'                = @{ Process = '^Overwolf'; Package = ''; Color = '#FB5B5B' }
    'Riot Client'             = @{ Process = '^RiotClient'; Package = ''; Color = '#F15B63' }
    'Rockstar Games Launcher' = @{ Process = '^(LauncherPatcher|RockstarService)$'; Package = 'RockstarGames.Launcher'; Color = '#F8B747' }
    'Steam'                   = @{ Process = '^steam$'; Package = 'Valve.Steam'; Color = '#7CB8FF' }
    'Ubisoft Connect'         = @{ Process = '^(UbisoftConnect|upc)$'; Package = 'Ubisoft.Connect'; Color = '#75CBFF' }
    'Minecraft Launcher'      = @{ Process = '^MinecraftLauncher$'; Package = 'Mojang.MinecraftLauncher'; Color = '#65C768' }
    'Playnite'                = @{ Process = '^Playnite'; Package = 'Playnite.Playnite'; Color = '#56BAEF' }
    'Prism Launcher'          = @{ Process = '^prismlauncher$'; Package = 'PrismLauncher.PrismLauncher'; Color = '#A291F5' }
    'Modrinth App'            = @{ Process = '^Modrinth'; Package = 'Modrinth.ModrinthApp'; Color = '#52CC8C' }
    'Amazon Games'            = @{ Process = '^Amazon Games'; Package = ''; Color = '#FFBC66' }
    'itch'                    = @{ Process = '^itch$'; Package = 'ItchIo.Itch'; Color = '#FF7183' }
}

function Save-Config {
    if (-not (Test-Path -LiteralPath $appData)) { New-Item -ItemType Directory -Path $appData -Force | Out-Null }
    @{ Entries=@($script:entries); HiddenNames=@($script:hiddenNames); Window=$script:windowSettings } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
}

function Get-StartupPath($entry) {
    $safeName = [regex]::Replace([string]$entry.Name, '[<>:"/\\|?*]', '_')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(([string]$entry.Path).ToLowerInvariant())
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try { $key = ([System.BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').Substring(0, 8) }
    finally { $hash.Dispose() }
    return (Join-Path $startupFolder "LauncherHub - $safeName-$key.lnk")
}

function Set-LauncherStartup($entry, [bool]$enabled) {
    $destination = Get-StartupPath $entry
    if ($enabled) {
        if (Test-Path -LiteralPath $destination -PathType Leaf) { return }
        if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) { throw "Launcher-Datei fehlt: $($entry.Path)" }
        if ([System.IO.Path]::GetExtension($entry.Path) -eq '.lnk') {
            Copy-Item -LiteralPath $entry.Path -Destination $destination -ErrorAction Stop
        } else {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($destination)
            $shortcut.TargetPath = $entry.Path
            $shortcut.WorkingDirectory = Split-Path -Parent $entry.Path
            $shortcut.Description = "Autostart für $($entry.Name) über Launcher Hub"
            $shortcut.Save()
        }
    } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
        Remove-Item -LiteralPath $destination -Force -ErrorAction Stop
    }
}

function Find-ExecutableInInstall($root, $fileName) {
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $queue.Enqueue(@($root, 0))
    $visited = 0
    while ($queue.Count -gt 0 -and $visited -lt 100) {
        $node = $queue.Dequeue(); $visited++
        $folder = [string]$node[0]; $depth = [int]$node[1]
        $candidate = Join-Path $folder $fileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        if ($depth -ge 3) { continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue)) {
            if ($child.Name -in @('steamapps','Games','game','cache','logs')) { continue }
            $queue.Enqueue(@($child.FullName, ($depth + 1)))
        }
    }
    return $null
}

function Find-Launchers {
    $startUser = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $startAll = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $desktopAll = Join-Path $env:PUBLIC 'Desktop'
    $roots = @($startUser, $startAll, $desktop, $desktopAll, (Join-Path $desktop 'Launcher'))
    $found = @{}
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $recursive = $root -in @($startUser, $startAll)
        $shortcuts = if ($recursive) { Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.lnk' -ErrorAction SilentlyContinue }
                     else { Get-ChildItem -LiteralPath $root -File -Filter '*.lnk' -ErrorAction SilentlyContinue }
        foreach ($shortcut in $shortcuts) {
            if ($catalog.ContainsKey($shortcut.BaseName) -and -not $found.ContainsKey($shortcut.BaseName)) {
                $found[$shortcut.BaseName] = $shortcut.FullName
            }
        }
    }
    $executables = @{
        'Battle.net'='Battle.net Launcher.exe'; 'EA'='EALauncher.exe'
        'Epic Games Launcher'='EpicGamesLauncher.exe'; 'GOG GALAXY'='GalaxyClient.exe'
        'Overwolf'='OverwolfLauncher.exe'; 'Riot Client'='RiotClientServices.exe'
        'Rockstar Games Launcher'='LauncherPatcher.exe'; 'Steam'='Steam.exe'
        'Ubisoft Connect'='UbisoftConnect.exe'; 'Minecraft Launcher'='MinecraftLauncher.exe'
        'Playnite'='Playnite.DesktopApp.exe'; 'Prism Launcher'='prismlauncher.exe'
        'Modrinth App'='Modrinth App.exe'; 'Amazon Games'='Amazon Games.exe'; 'itch'='itch.exe'
    }
    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($program in @(Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue)) {
        $name = [string]$program.DisplayName
        if ($name -eq 'EA app') { $name = 'EA' }
        if (-not $catalog.ContainsKey($name) -or $found.ContainsKey($name)) { continue }
        $folder = ([string]$program.InstallLocation).Trim('"')
        $exe = Find-ExecutableInInstall $folder $executables[$name]
        if ($exe) { $found[$name] = $exe }
    }
    @($found.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Name=$_; Path=$found[$_] } })
}

function Add-Detected {
    $added = 0
    foreach ($entry in @(Find-Launchers)) {
        if ($entry.Name -in $script:hiddenNames) { continue }
        if (@($script:entries | Where-Object Name -eq $entry.Name).Count -gt 0) { continue }
        $script:entries += $entry
        $added++
    }
    if ($added) { Save-Config }
    return $added
}

$script:entries = @()
$script:hiddenNames = @()
$script:windowSettings = $null
if (Test-Path -LiteralPath $configPath) {
    $saved = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:entries = @($saved.Entries | Where-Object { $_ -and $_.Path -and (Test-Path -LiteralPath $_.Path -PathType Leaf) })
    $script:hiddenNames = @($saved.HiddenNames)
    $script:windowSettings = $saved.Window
} else {
    Add-Detected | Out-Null
}

if ($Check) {
    Write-Output "Launcher: $($script:entries.Count)"
    $script:entries | ForEach-Object { Write-Output "$($_.Name) | $($_.Path)" }
    exit 0
}

if ($Scan) { Find-Launchers | Format-Table -AutoSize; exit 0 }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Launcher Hub" Width="1160" Height="800" MinWidth="760" MinHeight="520"
        WindowStartupLocation="CenterScreen" Background="#0B101A" Foreground="#F5F7FC"
        FontFamily="Segoe UI" FontSize="14">
  <Window.Resources>
    <Style TargetType="Button" x:Key="TopButton">
      <Setter Property="Background" Value="#26344A"/>
      <Setter Property="Foreground" Value="#EFF6FF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="18,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border Background="{TemplateBinding Background}" CornerRadius="11" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="154"/><RowDefinition Height="*"/><RowDefinition Height="42"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#142039" BorderBrush="#334F70" BorderThickness="0,0,0,1">
      <Grid Margin="30,14,30,10">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel>
          <StackPanel Orientation="Horizontal"><TextBlock Text="LAUNCHER HUB" Foreground="#74D8FF" FontWeight="Bold" FontSize="12"/><TextBlock Text="  ·  by Teo" Foreground="#91A9C6" FontSize="12"/></StackPanel>
          <TextBlock Text="Alles an einem Ort." FontSize="27" FontWeight="SemiBold" Margin="0,1,0,1"/>
          <TextBlock Text="Launcher starten, verwalten und ihren Status prüfen." Foreground="#ADC0DA" FontSize="12"/>
          <StackPanel Orientation="Horizontal" Margin="0,11,0,0">
            <Border Background="#24435B" CornerRadius="14" Padding="12,6" Margin="0,0,9,0"><TextBlock x:Name="TotalCount" Text="0 Launcher" Foreground="#CDEAFF"/></Border>
            <Border Background="#164834" CornerRadius="14" Padding="12,6" Margin="0,0,9,0"><TextBlock x:Name="RunningCount" Text="0 aktiv" Foreground="#97F5BE"/></Border>
            <Border Background="#5A4227" CornerRadius="14" Padding="12,6"><TextBlock x:Name="UpdateCount" Text="Versionshinweise werden geprüft" Foreground="#FFDBA3"/></Border>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
          <Button x:Name="ScanButton" Content="Auto-Erkennung" Style="{StaticResource TopButton}" Margin="0,0,9,0"/>
          <Button x:Name="AddButton" Content="+ Hinzufügen" Style="{StaticResource TopButton}" Margin="0,0,9,0"/>
          <Button x:Name="RefreshButton" Content="↻ Prüfen" Style="{StaticResource TopButton}"/>
        </StackPanel>
      </Grid>
    </Border>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="20,16,20,16">
      <WrapPanel x:Name="Cards" ItemWidth="252" ItemHeight="250"/>
    </ScrollViewer>
    <Border Grid.Row="2" Background="#111A29" BorderBrush="#26354C" BorderThickness="0,1,0,0">
      <TextBlock x:Name="Footer" Text="Laufstatus wird regelmäßig aktualisiert · Versionsprüfung läuft" Foreground="#8CA0BA" VerticalAlignment="Center" Margin="32,0"/>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
if ($script:windowSettings) {
    $view = $script:windowSettings
    if ($view.Width -ge 760 -and $view.Width -le 5000 -and $view.Height -ge 520 -and $view.Height -le 3000) {
        $window.Width = [double]$view.Width
        $window.Height = [double]$view.Height
        $screenLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
        $screenTop = [System.Windows.SystemParameters]::VirtualScreenTop
        $screenRight = $screenLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
        $screenBottom = $screenTop + [System.Windows.SystemParameters]::VirtualScreenHeight
        if ($null -ne $view.Left -and $null -ne $view.Top -and
            [double]$view.Left -ge $screenLeft -and [double]$view.Left -lt ($screenRight - 100) -and
            [double]$view.Top -ge $screenTop -and [double]$view.Top -lt ($screenBottom - 80)) {
            $window.Left = [double]$view.Left
            $window.Top = [double]$view.Top
            $window.WindowStartupLocation = 'Manual'
        }
        if ($view.Maximized) { $window.WindowState = 'Maximized' }
    }
}
$cardsPanel = $window.FindName('Cards')
$totalCount = $window.FindName('TotalCount')
$runningCount = $window.FindName('RunningCount')
$updateCount = $window.FindName('UpdateCount')
$footer = $window.FindName('Footer')
$refreshButton = $window.FindName('RefreshButton')
$scanButton = $window.FindName('ScanButton')
$addButton = $window.FindName('AddButton')
$script:cards = @()
$script:updateProcess = $null
$script:upgradeLines = @()
$script:installedLines = @()
$script:updatesReady = $false

function Brush($hex) { [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex) }
function Get-IconSource($path) {
    try {
        $icon = $null
        if ([System.IO.Path]::GetExtension($path) -eq '.lnk') {
            $shell = New-Object -ComObject WScript.Shell
            $location = $shell.CreateShortcut($path).IconLocation -replace ',\d+$', ''
            if ($location -and (Test-Path -LiteralPath $location -PathType Leaf) -and [System.IO.Path]::GetExtension($location) -eq '.ico') {
                $icon = [System.Drawing.Icon]::new($location)
            }
        }
        if (-not $icon) { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($path) }
        if (-not $icon) { return $null }
        $source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $icon.Handle, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromWidthAndHeight(60, 60))
        $source.Freeze(); $icon.Dispose(); return $source
    } catch { return $null }
}

function Get-Meta($entry) {
    if ($catalog.ContainsKey($entry.Name)) { return $catalog[$entry.Name] }
    $target = Resolve-Target $entry.Path
    $processName = [System.IO.Path]::GetFileNameWithoutExtension($target)
    return @{ Process=('^' + [regex]::Escape($processName) + '$'); Package=''; Color='#79B8FF' }
}

function Resolve-Target($path) {
    try {
        if ([System.IO.Path]::GetExtension($path) -eq '.lnk') {
            $shell = New-Object -ComObject WScript.Shell
            $target = $shell.CreateShortcut($path).TargetPath
            if ($target) { return $target }
        }
    } catch {}
    return $path
}

function Update-StartupCheckbox($checkbox, [bool]$enabled) {
    if ($script:startupGuard) { return }
    $entry = @($script:entries | Where-Object Path -eq ([string]$checkbox.Tag)) | Select-Object -First 1
    if (-not $entry) { return }
    try {
        Set-LauncherStartup $entry $enabled
        $footer.Text = if ($enabled) { "Autostart für $($entry.Name) aktiviert." } else { "Autostart für $($entry.Name) deaktiviert." }
    } catch {
        $script:startupGuard = $true
        $checkbox.IsChecked = -not $enabled
        $script:startupGuard = $false
        [System.Windows.MessageBox]::Show("Autostart konnte nicht geändert werden: $($_.Exception.Message)", 'Launcher Hub') | Out-Null
    }
}

function New-Card($item) {
    $meta = Get-Meta $item
    $outer = [System.Windows.Controls.Border]::new()
    $outer.Width = 232; $outer.Height = 230
    $outer.Margin = '10'; $outer.Padding = '17'; $outer.CornerRadius = '18'
    $outer.Background = Brush '#1B2638'; $outer.BorderBrush = Brush '#34445E'
    $outer.BorderThickness = '1'; $outer.Tag = $item.Path
    $outer.AllowDrop = $true
    $outer.ToolTip = 'Zum Sortieren ziehen und auf einer anderen Kachel ablegen'
    $stack = [System.Windows.Controls.StackPanel]::new(); $outer.Child = $stack
    $top = [System.Windows.Controls.Grid]::new(); $top.Height = 54
    $top.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
    $col = [System.Windows.Controls.ColumnDefinition]::new(); $col.Width = 'Auto'; $top.ColumnDefinitions.Add($col)
    $col2 = [System.Windows.Controls.ColumnDefinition]::new(); $col2.Width = 'Auto'; $top.ColumnDefinitions.Add($col2)
    $stack.Children.Add($top) | Out-Null
    $image = [System.Windows.Controls.Image]::new(); $image.Source = Get-IconSource $item.Path
    $image.Width = 52; $image.Height = 52; $image.HorizontalAlignment = 'Left'
    $top.Children.Add($image) | Out-Null
    $dot = [System.Windows.Shapes.Ellipse]::new(); $dot.Width = 11; $dot.Height = 11
    $dot.Fill = Brush '#687A91'; $dot.VerticalAlignment = 'Top'; $dot.Margin = '0,6,3,0'
    [System.Windows.Controls.Grid]::SetColumn($dot, 1); $top.Children.Add($dot) | Out-Null
    $remove = [System.Windows.Controls.Button]::new(); $remove.Content = '×'; $remove.Tag = $item.Path
    $remove.Width = 21; $remove.Height = 21; $remove.Margin = '12,-11,-9,0'
    $remove.VerticalAlignment = 'Top'; $remove.HorizontalAlignment = 'Right'
    $remove.Background = Brush '#34445C'; $remove.Foreground = Brush '#DCE8FA'
    $remove.BorderThickness = '0'; $remove.Cursor = 'Hand'
    $remove.ToolTip = 'Nur aus dem Hub entfernen'
    [System.Windows.Controls.Grid]::SetColumn($remove, 2); $top.Children.Add($remove) | Out-Null
    $remove.Add_Click({
        param($sender,$e)
        $path = [string]$sender.Tag
        $entry = @($script:entries | Where-Object Path -eq $path) | Select-Object -First 1
        if ($entry) {
            try { Set-LauncherStartup $entry $false }
            catch { [System.Windows.MessageBox]::Show("Autostart konnte nicht entfernt werden: $($_.Exception.Message)", 'Launcher Hub') | Out-Null; return }
            $script:entries = @($script:entries | Where-Object Path -ne $path)
            $script:hiddenNames += $entry.Name
            Save-Config; Rebuild-Cards
            $footer.Text = "$($entry.Name) wurde nur aus dem Hub entfernt."
        }
    })
    $name = [System.Windows.Controls.TextBlock]::new(); $name.Text = $item.Name
    $name.FontSize = 17; $name.FontWeight = 'SemiBold'; $name.Foreground = Brush '#F5F8FF'
    $name.TextTrimming = 'CharacterEllipsis'; $name.Margin = '0,6,0,0'
    $stack.Children.Add($name) | Out-Null
    $state = [System.Windows.Controls.TextBlock]::new(); $state.Text = 'Geschlossen'
    $state.FontSize = 12; $state.Foreground = Brush '#9EB0C6'; $state.Margin = '0,2,0,8'
    $stack.Children.Add($state) | Out-Null
    $badge = [System.Windows.Controls.Border]::new(); $badge.Background = Brush '#3B382A'
    $badge.CornerRadius = '9'; $badge.Padding = '9,5'; $badge.HorizontalAlignment = 'Left'
    $badgeText = [System.Windows.Controls.TextBlock]::new(); $badgeText.Text = 'Versionsprüfung läuft'
    $badgeText.FontSize = 11; $badgeText.Foreground = Brush '#FFD793'; $badge.Child = $badgeText
    $stack.Children.Add($badge) | Out-Null
    $open = [System.Windows.Controls.Button]::new(); $open.Content = 'ÖFFNEN  →'; $open.Tag = $item.Path
    $open.Height = 29; $open.HorizontalAlignment = 'Left'; $open.Margin = '0,0,12,0'
    $open.Padding = '10,3'; $open.Background = Brush '#2B4963'; $open.Foreground = Brush '#C7ECFF'
    $open.BorderThickness = '0'; $open.Cursor = 'Hand'
    $actions = [System.Windows.Controls.StackPanel]::new(); $actions.Orientation = 'Horizontal'; $actions.Margin = '0,11,0,0'
    $actions.Children.Add($open) | Out-Null
    $autoStart = [System.Windows.Controls.CheckBox]::new()
    $autoStart.Content = 'Autostart'; $autoStart.Tag = $item.Path
    $autoStart.FontSize = 12; $autoStart.Foreground = Brush '#C7D9ED'
    $autoStart.VerticalAlignment = 'Center'; $autoStart.Cursor = 'Hand'
    $autoStart.ToolTip = 'Mit Windows starten (über Launcher Hub)'
    $autoStart.IsChecked = Test-Path -LiteralPath (Get-StartupPath $item) -PathType Leaf
    $autoStart.Add_Checked({ param($sender,$e) Update-StartupCheckbox $sender $true })
    $autoStart.Add_Unchecked({ param($sender,$e) Update-StartupCheckbox $sender $false })
    $actions.Children.Add($autoStart) | Out-Null
    $stack.Children.Add($actions) | Out-Null
    $open.Add_Click({
        param($sender,$e)
        try { Start-Process -FilePath $sender.Tag }
        catch { [System.Windows.MessageBox]::Show("Konnte den Launcher nicht öffnen: $($_.Exception.Message)", 'Launcher Hub') | Out-Null }
    })
    $outer.Add_MouseEnter({ param($sender,$e) $sender.Background = Brush '#273852' })
    $outer.Add_MouseLeave({ param($sender,$e) $sender.Background = Brush '#1B2638'; $sender.BorderBrush = Brush '#34445E' })
    $outer.Add_PreviewMouseLeftButtonDown({
        param($sender,$e)
        $source = $e.OriginalSource
        while ($source -and $source -ne $sender) {
            if ($source -is [System.Windows.Controls.Primitives.ButtonBase]) { return }
            $source = [System.Windows.Media.VisualTreeHelper]::GetParent($source)
        }
        $script:dragPath = [string]$sender.Tag
        $script:dragStart = $e.GetPosition($cardsPanel)
    })
    $outer.Add_PreviewMouseMove({
        param($sender,$e)
        if (-not $script:dragPath -or $e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
        $point = $e.GetPosition($cardsPanel)
        if ([math]::Abs($point.X - $script:dragStart.X) -lt 7 -and
            [math]::Abs($point.Y - $script:dragStart.Y) -lt 7) { return }
        $path = $script:dragPath
        $script:dragPath = $null
        $data = [System.Windows.DataObject]::new('LauncherHubPath', $path)
        [System.Windows.DragDrop]::DoDragDrop($sender, $data, [System.Windows.DragDropEffects]::Move) | Out-Null
    })
    $outer.Add_PreviewMouseLeftButtonUp({ $script:dragPath = $null })
    $outer.Add_DragOver({
        param($sender,$e)
        $e.Effects = if ($e.Data.GetDataPresent('LauncherHubPath') -and
            [string]$e.Data.GetData('LauncherHubPath') -ne [string]$sender.Tag) {
            [System.Windows.DragDropEffects]::Move
        } else { [System.Windows.DragDropEffects]::None }
        $sender.BorderBrush = if ($e.Effects -eq [System.Windows.DragDropEffects]::Move) { Brush '#74D8FF' } else { Brush '#34445E' }
        $e.Handled = $true
    })
    $outer.Add_DragLeave({ param($sender,$e) $sender.BorderBrush = Brush '#34445E' })
    $outer.Add_Drop({
        param($sender,$e)
        if (-not $e.Data.GetDataPresent('LauncherHubPath')) { return }
        $from = [string]$e.Data.GetData('LauncherHubPath')
        $to = [string]$sender.Tag
        if ($from -eq $to) { return }
        $after = $e.GetPosition($sender).X -ge ($sender.ActualWidth / 2)
        $moving = @($script:entries | Where-Object Path -eq $from) | Select-Object -First 1
        if (-not $moving -or @($script:entries | Where-Object Path -eq $to).Count -eq 0) { return }
        $ordered = New-Object 'System.Collections.Generic.List[object]'
        foreach ($entry in $script:entries) {
            if ($entry.Path -eq $from) { continue }
            if ($entry.Path -eq $to -and -not $after) { $ordered.Add($moving) }
            $ordered.Add($entry)
            if ($entry.Path -eq $to -and $after) { $ordered.Add($moving) }
        }
        $script:entries = @($ordered.ToArray())
        Save-Config
        Rebuild-Cards
        $footer.Text = 'Reihenfolge gespeichert.'
        $e.Handled = $true
    })
    $cardsPanel.Children.Add($outer) | Out-Null
    $script:cards += [pscustomobject]@{ Name=$item.Name; Path=$item.Path; Meta=$meta; Dot=$dot; State=$state; Badge=$badge; BadgeText=$badgeText }
}

function Rebuild-Cards {
    $cardsPanel.Children.Clear()
    $script:cards = @()
    foreach ($item in $script:entries) { New-Card $item }
    $totalCount.Text = "$($script:cards.Count) Launcher"
    Refresh-Processes
    if ($script:updatesReady) { Apply-UpdateResults }
}

function Refresh-Processes {
    $names = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
    $active = 0
    foreach ($card in $script:cards) {
        $running = @($names | Where-Object { $_ -match $card.Meta.Process }).Count -gt 0
        if ($running) {
            $card.Dot.Fill = Brush '#48DF8D'; $card.State.Text = 'Läuft gerade'
            $card.State.Foreground = Brush '#9DF0BF'; $active++
        } else {
            $card.Dot.Fill = Brush '#687A91'; $card.State.Text = 'Geschlossen'
            $card.State.Foreground = Brush '#9EB0C6'
        }
    }
    $runningCount.Text = "$active aktiv"
}

function Start-UpdateCheck {
    if ($script:updateProcess -and -not $script:updateProcess.HasExited) { return }
    $script:updatesReady = $false
    $footer.Text = 'Laufstatus wird regelmäßig aktualisiert · Versionen werden geprüft …'
    if (Test-Path -LiteralPath $statusPath) { Remove-Item -LiteralPath $statusPath -Force }
    $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$helperPath`" -OutputPath `"$statusPath`""
    $script:updateProcess = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Get-ActualVersion($card) {
    $target = Resolve-Target $card.Path
    if ($card.Name -eq 'EA') { $target = Join-Path (Split-Path $target) 'EADesktop.exe' }
    if ($card.Name -eq 'Rockstar Games Launcher') { $target = Join-Path (Split-Path $target) 'Launcher.exe' }
    if ($card.Name -eq 'Epic Games Launcher') { $target = $target -replace '\\Win32\\', '\Win64\' }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return '' }
    $version = (Get-Item -LiteralPath $target).VersionInfo.ProductVersion
    if (-not $version) { $version = (Get-Item -LiteralPath $target).VersionInfo.FileVersion }
    return ($version -replace ',\s*', '.' -replace '\s', '')
}

function Apply-UpdateResults {
    $hintCount = 0
    foreach ($card in $script:cards) {
        $package = $card.Meta.Package
        $line = if ($package) { @($script:installedLines | Where-Object { $_ -match [regex]::Escape($package) }) | Select-Object -First 1 } else { $null }
        $upgrade = if ($package) { @($script:upgradeLines | Where-Object { $_ -match [regex]::Escape($package) }) | Select-Object -First 1 } else { $null }
        if ($upgrade) {
            $actual = Get-ActualVersion $card
            $available = ''
            if ($upgrade -match '\s(?<installed><?\s*\d+(?:\.\d+)+)\s+(?<available>\d+(?:\.\d+)+)\s+winget\s*$') {
                $available = $Matches.available
            }
            if ($actual -match '^\d+(?:\.\d+)+$' -and $available -and ([version]$actual) -ge ([version]$available)) {
                $card.Badge.Background = Brush '#1B473D'; $card.BadgeText.Foreground = Brush '#A0EFD1'
                $card.BadgeText.Text = '✓  Programmdatei auf Stand'
            } elseif ($actual -match '^\d+(?:\.\d+)+$' -and $available -and
                      ([version]$actual).Major -eq ([version]$available).Major -and ([version]$actual) -lt ([version]$available)) {
                $card.Badge.Background = Brush '#512A31'; $card.BadgeText.Foreground = Brush '#FFB8C0'
                $card.BadgeText.Text = '●  Update bestätigt'
                $hintCount++
            } else {
                $card.Badge.Background = Brush '#59422B'; $card.BadgeText.Foreground = Brush '#FFDBA3'
                $card.BadgeText.Text = '●  WinGet-Hinweis, prüfen'
                $hintCount++
            }
        } elseif ($line -and $line -notmatch '\bUnknown\b') {
            $card.Badge.Background = Brush '#28423D'; $card.BadgeText.Foreground = Brush '#B7E5D4'
            $card.BadgeText.Text = '✓  Kein Update gemeldet'
        } else {
            $card.Badge.Background = Brush '#3B382A'; $card.BadgeText.Foreground = Brush '#FFD793'
            $card.BadgeText.Text = '●  Version ungeprüft'
        }
    }
    $updateCount.Text = "$hintCount Versionshinweise"
    $footer.Text = "Laufstatus wird regelmäßig aktualisiert · Versionsprüfung: $(Get-Date -Format 'HH:mm') · Hinweise bitte im Launcher bestätigen"
    $script:updatesReady = $true
}

$timer = [System.Windows.Threading.DispatcherTimer]::new(); $timer.Interval = [TimeSpan]::FromSeconds(3)
$timer.Add_Tick({
    Refresh-Processes
    if ($script:updateProcess -and $script:updateProcess.HasExited -and -not $script:updatesReady) {
        $result = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json } else { $null }
        $script:updateProcess.Dispose()
        $script:updateProcess = $null
        if ($result -and -not $result.Error) {
            $script:upgradeLines = @($result.Upgrade -split "`r?`n")
            $script:installedLines = @($result.Installed -split "`r?`n")
            Apply-UpdateResults
        } else {
            foreach ($card in $script:cards) {
                $card.Badge.Background = Brush '#3B382A'
                $card.BadgeText.Foreground = Brush '#FFD793'
                $card.BadgeText.Text = '●  Version nicht prüfbar'
            }
            $updateCount.Text = 'Prüfung nicht verfügbar'
            $footer.Text = 'Laufstatus wird regelmäßig aktualisiert · Updateprüfung fehlgeschlagen'
            $script:updatesReady = $true
        }
    }
})
$refreshButton.Add_Click({ Refresh-Processes; Start-UpdateCheck })
$scanButton.Add_Click({
    $added = Add-Detected
    Rebuild-Cards
    $footer.Text = if ($added) { "$added Launcher automatisch hinzugefügt." } else { 'Keine weiteren bekannten Launcher in Desktop und Startmenü gefunden.' }
})
$addButton.Add_Click({
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = 'Launcher hinzufügen'
    $dialog.Filter = 'Programme und Verknüpfungen|*.exe;*.lnk;*.url|Alle Dateien|*.*'
    if ($dialog.ShowDialog($window) -eq $true) {
        $path = $dialog.FileName
        $name = [System.IO.Path]::GetFileNameWithoutExtension($path)
        if (@($script:entries | Where-Object Path -eq $path).Count -eq 0) {
            $script:entries += [pscustomobject]@{ Name=$name; Path=$path }
            $script:hiddenNames = @($script:hiddenNames | Where-Object { $_ -ne $name })
            Save-Config; Rebuild-Cards
            $footer.Text = "$name hinzugefügt."
        }
    }
})
$window.Add_Closing({
    $bounds = if ($window.WindowState -eq 'Normal') { $window } else { $window.RestoreBounds }
    $script:windowSettings = [pscustomobject]@{
        Width=[math]::Round($bounds.Width); Height=[math]::Round($bounds.Height)
        Left=[math]::Round($bounds.Left); Top=[math]::Round($bounds.Top)
        Maximized=($window.WindowState -eq 'Maximized')
    }
    Save-Config
})
$window.Add_Closed({
    $timer.Stop()
    if ($script:updateProcess) { $script:updateProcess.Dispose() }
})
Rebuild-Cards; Start-UpdateCheck; $timer.Start()
$window.ShowDialog() | Out-Null
