param([switch]$Check, [switch]$Scan)

$ErrorActionPreference = 'Stop'
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$appData = Join-Path $env:APPDATA 'LauncherHub'
$configPath = Join-Path $appData 'config.json'
$sessionId = [guid]::NewGuid().ToString('N')
$statusPath = Join-Path $appData "updates-$sessionId.json"
$installPath = Join-Path $appData "install-$sessionId.json"
$helperPath = Join-Path $PSScriptRoot 'LauncherHubUpdates.ps1'
. (Join-Path $PSScriptRoot 'LauncherHub.UpdateCore.ps1')
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
$xaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'LauncherHub.xaml') -Raw -Encoding UTF8
$cardXaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'LauncherHub.Card.xaml') -Raw -Encoding UTF8

$reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$iconPath = Join-Path $PSScriptRoot 'LauncherHub.ico'
if (Test-Path -LiteralPath $iconPath) { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([uri]$iconPath) }
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
$updateAllButton = $window.FindName('UpdateAllButton')
$script:cards = @()
$script:updateProcess = $null
$script:upgradeLines = @()
$script:installedLines = @()
$script:updatesReady = $false
$script:checkError = ''
$script:installProcess = $null
$script:installQueue = New-Object 'System.Collections.Generic.Queue[object]'
$script:installResults = @{}
$script:installCurrent = $null
$script:installTotal = 0
$script:installDone = 0
$script:batchSummary = ''
$script:activeView = 'all'

function Brush($hex) { [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex) }

function Connect-HubUI {
    $script:cardsScroll = $window.FindName('CardsScroll')
    $script:footerState = $window.FindName('FooterState')
    $script:allTab = $window.FindName('AllTab')
    $script:updatesTab = $window.FindName('UpdatesTab')
    $script:updateNavCount = $window.FindName('UpdateNavCount')
    $script:emptyState = $window.FindName('EmptyState')
    $script:emptyTitle = $window.FindName('EmptyTitle')
    $script:emptyDescription = $window.FindName('EmptyDescription')
    $script:scanButton = $window.FindName('ScanButton')
    $allTab.Add_Checked({ $script:activeView = 'all'; Update-HubView })
    $updatesTab.Add_Checked({ $script:activeView = 'updates'; Update-HubView })
    $cardsScroll.Add_SizeChanged({ Update-HubLayout })
    $cardsScroll.Add_ScrollChanged({ param($sender,$e) if ($e.ViewportWidthChange -ne 0) { Update-HubLayout } })
    $window.Add_SizeChanged({ Update-HubLayout })
    $window.FindName('MinimizeButton').Add_Click({ $window.WindowState = 'Minimized' })
    $window.FindName('MaximizeButton').Add_Click({
        $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
    })
    $window.FindName('CloseButton').Add_Click({ $window.Close() })
    $window.Add_StateChanged({
        $window.FindName('MaximizeButton').Content = if ($window.WindowState -eq 'Maximized') { [char]0xE923 } else { [char]0xE922 }
    })
    $settings = $window.FindName('SettingsButton')
    $menu = [System.Windows.Controls.ContextMenu]::new(); $menu.Style = $window.Resources['HubContextMenu']
    $detect = [System.Windows.Controls.MenuItem]::new(); $detect.Header = 'Launcher automatisch erkennen'; $detect.Style = $window.Resources['HubMenuItem']
    $detect.Add_Click({ Invoke-HubScan })
    $menu.Items.Add($detect) | Out-Null
    $log = [System.Windows.Controls.MenuItem]::new(); $log.Header = 'Letztes Update-Protokoll öffnen'; $log.Style = $window.Resources['HubMenuItem']
    $log.Add_Click({
        $path = Join-Path $appData 'last-update-log.json'
        if (Test-Path -LiteralPath $path) {
            try { Start-Process -FilePath (Join-Path $env:WINDIR 'System32\notepad.exe') -ArgumentList ('"' + $path + '"') }
            catch { $footer.Text = 'Das Update-Protokoll konnte nicht geöffnet werden.' }
        } else { $footer.Text = 'Noch kein Update-Protokoll vorhanden.' }
    })
    $menu.Items.Add($log) | Out-Null
    $settings.ContextMenu = $menu
    $settings.Add_Click({ param($sender,$e) $sender.ContextMenu.PlacementTarget = $sender; $sender.ContextMenu.IsOpen = $true })
    Update-HubLayout
}

function Update-HubLayout([double]$width = 0) {
    if ($width -le 0) {
        $width = $window.FindName('RootGrid').ActualWidth
        if ($width -le 0) { $width = $window.Width }
    }
    $compact = $width -lt 1080
    $actions = $window.FindName('HeaderActions'); $summary = $window.FindName('Summary')
    if ($compact) {
        [System.Windows.Controls.Grid]::SetRow($actions, 1); [System.Windows.Controls.Grid]::SetColumn($actions, 0)
        [System.Windows.Controls.Grid]::SetColumnSpan($actions, 2)
        [System.Windows.Controls.Grid]::SetRow($summary, 2)
        $actions.Margin = '0,16,0,0'; $actions.HorizontalAlignment = 'Left'
    } else {
        [System.Windows.Controls.Grid]::SetRow($actions, 0); [System.Windows.Controls.Grid]::SetColumn($actions, 1)
        [System.Windows.Controls.Grid]::SetColumnSpan($actions, 1)
        [System.Windows.Controls.Grid]::SetRow($summary, 1)
        $actions.Margin = '0'; $actions.HorizontalAlignment = 'Right'
    }
    $window.FindName('Byline').Visibility = if ($width -lt 1080) { 'Collapsed' } else { 'Visible' }
    $window.FindName('SettingsLabel').Visibility = if ($width -lt 1100) { 'Collapsed' } else { 'Visible' }
    $window.FindName('AllTabLabel').Text = if ($width -lt 900) { 'Launcher' } else { 'Meine Launcher' }
    $footerState.Visibility = if ($width -lt 980) { 'Collapsed' } else { 'Visible' }
    $space = $cardsScroll.ViewportWidth
    if ($space -le 0) { $space = $width - 54 }
    $columns = if ($space -ge 920) { 2 } else { 1 }
    $itemWidth = [math]::Floor($space / $columns)
    if ([math]::Abs($cardsPanel.ItemWidth - $itemWidth) -gt 0.5) { $cardsPanel.ItemWidth = $itemWidth }
    foreach ($card in $script:cards) { $card.Outer.Width = [math]::Max(320, $itemWidth - 18) }
}

function Update-HubView {
    $visible = 0
    foreach ($card in $script:cards) {
        $show = $script:activeView -ne 'updates' -or $card.CanUpdate -or
            ($card.Meta.Package -and $script:installResults.ContainsKey($card.Meta.Package))
        $card.Outer.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
        if ($show) { $visible++ }
    }
    $emptyState.Visibility = if ($visible -eq 0) { 'Visible' } else { 'Collapsed' }
    if ($script:activeView -eq 'updates') {
        $emptyTitle.Text = if (-not $script:updatesReady) { 'Updates werden geprüft …' } elseif ($script:checkError) { 'Prüfung nicht verfügbar' } else { 'Keine offenen Updates.' }
        $emptyDescription.Text = if ($script:checkError) { 'Starte die Prüfung erneut. Programme ohne direkte Unterstützung prüfst du im jeweiligen Launcher.' } else { 'Hier erscheinen erkannte Updates und die Ergebnisse des letzten Durchlaufs.' }
        $scanButton.Visibility = 'Collapsed'
    } else {
        $emptyTitle.Text = 'Dein Hub wartet auf dich.'
        $emptyDescription.Text = 'Erkenne installierte Launcher automatisch oder füge ein Programm hinzu.'
        $scanButton.Visibility = 'Visible'
    }
    Update-HubLayout
}

function Invoke-HubScan {
    $added = Add-Detected
    $allTab.IsChecked = $true
    Rebuild-Cards
    $footer.Text = if ($added) { "$added Launcher automatisch hinzugefügt." } else { 'Keine weiteren bekannten Launcher in Desktop und Startmenü gefunden.' }
}

function Get-IconSource($path) {
    $handle = [IntPtr]::Zero
    $managedIcon = $null
    try {
        if (-not $script:iconCache) { $script:iconCache = @{} }
        if ($script:iconCache.ContainsKey($path)) { return $script:iconCache[$path] }
        $target = $path; $index = 0
        if ([System.IO.Path]::GetExtension($path) -eq '.lnk') {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($path)
            $target = $shortcut.TargetPath
            $location = [Environment]::ExpandEnvironmentVariables([string]$shortcut.IconLocation)
            if ($location -match '^(?<file>.+?)(?:,(?<index>-?\d+))?$') {
                $file = $Matches.file.Trim('"'); $iconIndex = [int]$Matches.index
                if (Test-Path -LiteralPath $file -PathType Leaf) { $target = $file; $index = $iconIndex }
            }
        }
        if (-not $target -or -not (Test-Path -LiteralPath $target -PathType Leaf)) { return $null }
        if (-not ('LauncherHubIconReader' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LauncherHubIconReader {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    public static extern int SHDefExtractIconW(string file, int index, uint flags, out IntPtr largeIcon, IntPtr smallIcon, uint size);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr icon);
}
'@
        }
        $code = [LauncherHubIconReader]::SHDefExtractIconW($target, $index, 0, [ref]$handle, [IntPtr]::Zero, 64)
        if ($code -eq 0 -and $handle -ne [IntPtr]::Zero) {
            $source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($handle, [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        } else {
            $managedIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($target)
            if (-not $managedIcon) { return $null }
            $source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($managedIcon.Handle, [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        }
        $source.Freeze(); $script:iconCache[$path] = $source; return $source
    } catch { return $null } finally {
        if ($handle -ne [IntPtr]::Zero) { [LauncherHubIconReader]::DestroyIcon($handle) | Out-Null }
        if ($managedIcon) { $managedIcon.Dispose() }
    }
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
    $outer = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new([xml]$cardXaml))
    $outer.Tag = $item.Path
    $outer.Width = [math]::Max(320, $cardsPanel.ItemWidth - 18)
    $outer.ToolTip = 'Zum Sortieren ziehen und auf einer anderen Kachel ablegen'
    $image = $outer.FindName('LauncherIcon'); $image.Source = Get-IconSource $item.Path
    $fallback = $outer.FindName('IconFallback')
    $fallback.Text = ([string]$item.Name).Substring(0, 1).ToUpperInvariant()
    $fallback.Visibility = if ($image.Source) { 'Collapsed' } else { 'Visible' }
    $name = $outer.FindName('LauncherName'); $name.Text = $item.Name; $name.ToolTip = $item.Name
    $dot = $outer.FindName('RunningDot'); $state = $outer.FindName('RunningState')
    $badge = $outer.FindName('StatusBadge'); $badgeText = $outer.FindName('UpdateStatus')
    $statusDot = $outer.FindName('UpdateDot')
    $open = $outer.FindName('OpenButton'); $open.Tag = $item.Path
    $open.Style = $window.Resources['PrimaryButton']; $open.Padding = '10,4'
    [System.Windows.Automation.AutomationProperties]::SetName($open, "$($item.Name) öffnen")
    $update = $outer.FindName('UpdateButton'); $update.Tag = $item.Path
    $update.Style = $window.Resources['TopButton']; $update.Padding = '7,4'
    $update.Background = Brush '#131F28'; $update.BorderBrush = Brush '#496B80'
    [System.Windows.Automation.AutomationProperties]::SetName($update, "$($item.Name) aktualisieren")
    $autoStart = $outer.FindName('AutoStart'); $autoStart.Tag = $item.Path
    $autoStart.Style = $window.Resources['HubToggle']
    $autoStart.IsChecked = Test-Path -LiteralPath (Get-StartupPath $item) -PathType Leaf
    $autoStart.Add_Checked({ param($sender,$e) Update-StartupCheckbox $sender $true })
    $autoStart.Add_Unchecked({ param($sender,$e) Update-StartupCheckbox $sender $false })
    $operation = $outer.FindName('Operation')
    $menuButton = $outer.FindName('MenuButton'); $menuButton.Style = $window.Resources['TopButton']; $menuButton.Padding = '4,0'
    [System.Windows.Automation.AutomationProperties]::SetName($menuButton, "$($item.Name) verwalten")
    $menu = [System.Windows.Controls.ContextMenu]::new(); $menu.Style = $window.Resources['HubContextMenu']
    $remove = [System.Windows.Controls.MenuItem]::new(); $remove.Header = 'Aus dem Hub entfernen'; $remove.Tag = $item.Path
    $remove.Style = $window.Resources['HubMenuItem']; $menu.Items.Add($remove) | Out-Null
    $menuButton.ContextMenu = $menu
    $menuButton.Add_Click({ param($sender,$e) $sender.ContextMenu.PlacementTarget = $sender; $sender.ContextMenu.IsOpen = $true })
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
    $update.Add_Click({
        param($sender,$e)
        $card = @($script:cards | Where-Object Path -eq ([string]$sender.Tag)) | Select-Object -First 1
        if (-not $card) { return }
        if (-not $card.Meta.Package) {
            try { Start-Process -FilePath $card.Path }
            catch { $footer.Text = "Konnte $($card.Name) nicht öffnen: $($_.Exception.Message)" }
        } else { Start-LauncherUpdates @($card) }
    })
    $open.Add_Click({
        param($sender,$e)
        try { Start-Process -FilePath $sender.Tag }
        catch { [System.Windows.MessageBox]::Show("Konnte den Launcher nicht öffnen: $($_.Exception.Message)", 'Launcher Hub') | Out-Null }
    })
    $outer.Add_MouseEnter({ param($sender,$e) $sender.Background = Brush '#1C2C38'; $sender.BorderBrush = Brush '#48687D' })
    $outer.Add_MouseLeave({ param($sender,$e) $sender.Background = Brush '#17232D'; $sender.BorderBrush = Brush '#304450' })
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
        $sender.BorderBrush = if ($e.Effects -eq [System.Windows.DragDropEffects]::Move) { Brush '#74D8FF' } else { Brush '#304450' }
        $e.Handled = $true
    })
    $outer.Add_DragLeave({ param($sender,$e) $sender.BorderBrush = Brush '#304450' })
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
    $script:cards += [pscustomobject]@{ Name=$item.Name; Path=$item.Path; Meta=$meta; Dot=$dot; State=$state; Badge=$badge; BadgeText=$badgeText; UpdateButton=$update; Operation=$operation; CanUpdate=$false; Outer=$outer; StatusDot=$statusDot; OpenButton=$open; MenuButton=$menuButton; AutoStart=$autoStart }
}

function Rebuild-Cards {
    $cardsPanel.Children.Clear()
    $script:cards = @()
    foreach ($item in $script:entries) { New-Card $item }
    $totalCount.Text = "$($script:cards.Count) Launcher"
    Refresh-Processes
    Apply-UpdateResults
}

function Refresh-Processes {
    $names = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
    $active = 0
    foreach ($card in $script:cards) {
        $running = @($names | Where-Object { $_ -match $card.Meta.Process }).Count -gt 0
        if ($running) {
            $card.Dot.Fill = Brush '#55DF9B'; $card.State.Text = 'Läuft'
            $card.State.Foreground = Brush '#9DF0BF'; $active++
        } else {
            $card.Dot.Fill = Brush '#687A91'; $card.State.Text = 'Geschlossen'
            $card.State.Foreground = Brush '#9EB0C6'
        }
    }
    $runningCount.Text = "$active aktiv"
}

function Start-UpdateCheck {
    if ($script:updateProcess -or $script:installCurrent) { return }
    $script:updatesReady = $false
    $script:checkError = ''
    $footer.Text = ($script:batchSummary + ' Versionen werden geprüft …').Trim()
    try {
        if (Test-Path -LiteralPath $statusPath) { Remove-Item -LiteralPath $statusPath -Force }
        $script:updateProcess = Start-HubWorker 'Check' $statusPath
    } catch {
        $script:checkError = $_.Exception.Message; $script:updatesReady = $true
        $footer.Text = ($script:batchSummary + ' Updateprüfung nicht verfügbar: ' + $script:checkError).Trim()
    }
    Apply-UpdateResults
}

function Start-HubWorker([string]$mode, [string]$outputPath, [string]$packageId) {
    if (-not (Test-Path -LiteralPath $appData)) { New-Item -ItemType Directory -Path $appData -Force | Out-Null }
    $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$helperPath`" -Mode $mode -OutputPath `"$outputPath`""
    if ($mode -eq 'Upgrade') {
        Get-HubUpgradeArguments $packageId | Out-Null
        $arguments += " -PackageId $packageId"
    }
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe; $start.Arguments = $arguments
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [System.Diagnostics.Process]::Start($start)
}

function Get-ActualVersion($card) {
    $target = Resolve-Target $card.Path
    if ($card.Name -eq 'EA') { $target = Join-Path (Split-Path $target) 'EADesktop.exe' }
    if ($card.Name -eq 'Rockstar Games Launcher') { $target = Join-Path (Split-Path $target) 'Launcher.exe' }
    if ($card.Name -eq 'Epic Games Launcher') { $target = $target -replace '\\Win32\\', '\Win64\' }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return '' }
    try {
        $version = (Get-Item -LiteralPath $target).VersionInfo.ProductVersion
        if (-not $version) { $version = (Get-Item -LiteralPath $target).VersionInfo.FileVersion }
        return ($version -replace ',\s*', '.' -replace '\s', '')
    } catch { return '' }
}

function Apply-UpdateResults {
    $hintCount = 0
    foreach ($card in $script:cards) {
        $status = Get-HubPackageStatus -PackageId $card.Meta.Package -UpgradeLines $script:upgradeLines -InstalledLines $script:installedLines -ActualVersion (Get-ActualVersion $card)
        $card.CanUpdate = $script:updatesReady -and -not $script:checkError -and $status.CanUpdate
        $card.Badge.Background = Brush 'Transparent'; $card.BadgeText.Foreground = Brush '#A8BECD'
        $card.StatusDot.Fill = Brush '#8FA5B5'
        $card.BadgeText.Text = $status.Text -replace '^[✓●]\s*', ''
        if ($card.Meta.Package -and -not $script:updatesReady) { $card.BadgeText.Text = 'Versionsprüfung läuft' }
        elseif ($card.Meta.Package -and $script:checkError) { $card.BadgeText.Text = 'Version nicht prüfbar' }
        elseif ($status.Tone -eq 'Current') {
            $card.BadgeText.Foreground = Brush '#A8BECD'
        }
        if ($card.CanUpdate) {
            $card.BadgeText.Text = 'Update verfügbar'
            $card.BadgeText.Foreground = Brush '#FFCB75'; $card.StatusDot.Fill = Brush '#FFBE55'
        }
        $card.BadgeText.TextTrimming = 'CharacterEllipsis'
        $card.BadgeText.ToolTip = if ($card.CanUpdate) { "Update auf $($status.Available)" } else { $card.BadgeText.Text }
        if ($card.CanUpdate) { $hintCount++ }
        $card.UpdateButton.Content = if ($card.Meta.Package) { 'Aktualisieren' } else { 'Im Launcher prüfen' }
        $card.UpdateButton.IsEnabled = -not $script:installCurrent -and ($card.CanUpdate -or -not $card.Meta.Package)
        $card.UpdateButton.ToolTip = if ($card.Meta.Package) { 'Installiert das erkannte WinGet-Update. Windows kann um Berechtigung bitten. Quell- und Paketbedingungen werden bestätigt.' } else { 'Keine direkte Update-Unterstützung: Launcher öffnen und dort prüfen.' }
        $card.Operation.Text = ''; $card.Operation.ToolTip = $null
        if ($card.Meta.Package -and $script:installResults.ContainsKey($card.Meta.Package)) {
            $last = $script:installResults[$card.Meta.Package]
            $card.Operation.Text = $last.Message
            $card.Operation.Foreground = if ($last.State -eq 'Failed') { Brush '#FFB8C0' } else { Brush '#A0EFD1' }
            $card.Operation.ToolTip = $last.Message + "`nDetails: " + (Join-Path $appData 'last-update-log.json')
        }
        if ($script:installCurrent -and $card.Meta.Package -eq $script:installCurrent.Package) {
            $card.Operation.Text = 'Wird aktualisiert …'; $card.Operation.Foreground = Brush '#FFDBA3'
        } elseif (@($script:installQueue.ToArray() | Where-Object Package -eq $card.Meta.Package).Count -gt 0) {
            $card.Operation.Text = 'Wartet auf Aktualisierung …'; $card.Operation.Foreground = Brush '#FFDBA3'
        }
        $card.OpenButton.IsEnabled = -not ($script:installCurrent -and $card.Meta.Package -eq $script:installCurrent.Package)
    }
    $updateCount.Text = if (-not $script:updatesReady) { 'Updates werden geprüft' } elseif ($script:checkError) { 'Prüfung nicht verfügbar' } else { "$hintCount Updates verfügbar" }
    $updateAllButton.IsEnabled = $hintCount -gt 0 -and -not $script:installCurrent -and -not $script:updateProcess
    $refreshButton.IsEnabled = -not $script:installCurrent -and -not $script:updateProcess
    $updateNavCount.Text = [string]$hintCount
    $footerState.Text = if ($script:installCurrent) { 'Aktualisierung läuft' } elseif (-not $script:updatesReady) { 'Prüfung läuft' } elseif ($script:checkError) { 'Prüfung nicht verfügbar' } else { 'Prüfung abgeschlossen' }
    Update-HubView
}

function Start-LauncherUpdates([object[]]$selectedCards) {
    if ($script:installCurrent -or $script:updateProcess -or -not $script:updatesReady -or $script:checkError) { return }
    $selected = @($selectedCards | Where-Object CanUpdate | Group-Object { $_.Meta.Package } | ForEach-Object { $_.Group[0] })
    if (-not $selected.Count) { return }
    $script:installResults = @{}; $script:batchSummary = ''
    $script:installTotal = $selected.Count; $script:installDone = 0
    foreach ($card in $selected) {
        $script:installQueue.Enqueue([pscustomobject]@{ Name=$card.Name; Package=$card.Meta.Package })
    }
    Start-NextLauncherUpdate
}

function Save-InstallResult($result) {
    $script:installResults[$script:installCurrent.Package] = [pscustomobject]@{
        Name=$script:installCurrent.Name; PackageId=$script:installCurrent.Package
        State=$result.State; Message=$result.Message; Output=$result.Output; CheckedAt=(Get-Date).ToString('o')
    }
    try {
        @($script:installResults.Values) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $appData 'last-update-log.json') -Encoding UTF8
    } catch { $script:installResults[$script:installCurrent.Package].Message += ' · Protokoll nicht speicherbar' }
}

function Start-NextLauncherUpdate {
    $script:installCurrent = $null
    while ($script:installQueue.Count -gt 0) {
        $script:installCurrent = $script:installQueue.Dequeue()
        try {
            if (Test-Path -LiteralPath $installPath) { Remove-Item -LiteralPath $installPath -Force }
            $script:installProcess = Start-HubWorker 'Upgrade' $installPath $script:installCurrent.Package
            $footer.Text = "Update $($script:installDone + 1)/$($script:installTotal): $($script:installCurrent.Name) · Bitte warten; Windows kann eine Berechtigung anfordern."
            Apply-UpdateResults
            return
        } catch {
            Save-InstallResult ([pscustomobject]@{ State='Failed'; Message=$_.Exception.Message; Output='' })
            $script:installDone++
        }
    }
    $script:installCurrent = $null
    $results = @($script:installResults.Values)
    $ok = @($results | Where-Object State -eq 'Succeeded').Count
    $failed = @($results | Where-Object State -eq 'Failed').Count
    $unchanged = @($results | Where-Object State -eq 'Unchanged').Count
    $script:batchSummary = "Updates beendet: $ok abgeschlossen, $unchanged ohne Änderung, $failed fehlgeschlagen."
    Start-UpdateCheck
}

function Read-HubWorkerResult([string]$path, [string]$mode) {
    if (-not (Test-Path -LiteralPath $path)) { throw 'Der Update-Helfer hat kein Ergebnis geliefert.' }
    $result = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($result.Mode -ne $mode -or $result.State -notin @('Succeeded','Unchanged','Failed')) {
        throw 'Ungültiges Ergebnis des Update-Helfers.'
    }
    return $result
}

Connect-HubUI
$window.Height = [math]::Min($window.Height, [System.Windows.SystemParameters]::WorkArea.Height - 24)
$window.Width = [math]::Min($window.Width, [System.Windows.SystemParameters]::WorkArea.Width - 24)
$timer = [System.Windows.Threading.DispatcherTimer]::new(); $timer.Interval = [TimeSpan]::FromSeconds(3)
$timer.Add_Tick({
    Refresh-Processes
    if ($script:installProcess -and $script:installProcess.HasExited) {
        try {
            $result = Read-HubWorkerResult $installPath 'Upgrade'
            if ($result.PackageId -ne $script:installCurrent.Package) { throw 'Falsche Paket-ID im Ergebnis.' }
        } catch { $result = [pscustomobject]@{ State='Failed'; Message=$_.Exception.Message; Output='' } }
        $script:installProcess.Dispose(); $script:installProcess = $null
        Save-InstallResult $result
        $script:installDone++
        Start-NextLauncherUpdate
    }
    if ($script:updateProcess -and $script:updateProcess.HasExited) {
        try {
            $result = Read-HubWorkerResult $statusPath 'Check'
            if ($result.State -ne 'Succeeded' -or $result.Error) { throw $result.Error }
            $script:upgradeLines = @($result.Upgrade -split "`r?`n")
            $script:installedLines = @($result.Installed -split "`r?`n")
            $footer.Text = ($script:batchSummary + " Zuletzt geprüft: $(Get-Date -Format 'HH:mm')").Trim()
        } catch {
            $script:checkError = $_.Exception.Message
            $footer.Text = ($script:batchSummary + ' Updateprüfung nicht verfügbar: ' + $script:checkError).Trim()
        } finally {
            $script:updateProcess.Dispose(); $script:updateProcess = $null
            $script:updatesReady = $true; Apply-UpdateResults
        }
    }
})
$refreshButton.Add_Click({ $script:batchSummary = ''; Refresh-Processes; Start-UpdateCheck })
$updateAllButton.Add_Click({ Start-LauncherUpdates @($script:cards) })
$scanButton.Add_Click({ Invoke-HubScan })
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
    param($sender,$e)
    if ($script:installCurrent) {
        $e.Cancel = $true
        [System.Windows.MessageBox]::Show('Bitte warte, bis die laufenden Updates abgeschlossen sind.', 'Launcher Hub') | Out-Null
        return
    }
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
    foreach ($path in @($statusPath, $installPath)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
})
Rebuild-Cards; Start-UpdateCheck; $timer.Start()
$window.ShowDialog() | Out-Null
