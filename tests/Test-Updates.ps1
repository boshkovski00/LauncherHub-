# No WinGet invocation or real software installation. Run with Windows PowerShell 5.1 -STA.
param([string]$PreviewDirectory)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'LauncherHub.UpdateCore.ps1')
$script:checks = 0
function Assert($condition, [string]$message) {
    if (-not $condition) { throw "FAILED: $message" }
    $script:checks++
}
foreach ($file in @(Get-ChildItem -LiteralPath $repo -Filter '*.ps1')) {
    $tokens=$null; $errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert ($errors.Count -eq 0) "Syntax: $($file.Name)"
}
$rows = @('Steam  Valve.Steam  1.0.0  2.0.0  winget', 'Other Valve.Steam.Tools 1.0.0 3.0.0 winget')
$status = Get-HubPackageStatus 'Valve.Steam' $rows @() '1.0.0'
Assert ($status.CanUpdate -and $status.Available -eq '2.0.0') 'Exact package upgrade'
Assert (-not (Get-HubPackageStatus 'Valve.Steam' $rows @() '2.0.0').CanUpdate) 'Current binary is not reinstalled'
Assert ((Get-HubPackageStatus 'Valve.Steam' $rows @() '10.0.0').CanUpdate) 'Different binary version scheme does not hide a WinGet update'
Assert (-not (Get-HubPackageStatus 'Valve.Steam' @('Steam Valve.Steam 1.0 winget') @() '').CanUpdate) 'Missing target version is not an update'
Assert (-not (Get-HubPackageStatus 'Valve.Steam' @($rows[1]) @() '').CanUpdate) 'Package prefix cannot match another package'
Assert ((Get-HubPackageStatus 'Valve.Steam' @('Steam Valve.Steam < 1.0 2.0 winget') @() '').CanUpdate) 'Less-than version'
Assert ((Get-HubPackageStatus 'Valve.Steam' @('Steam Valve.Steam 1.0 2.0') @() '').CanUpdate) 'Single-source table without source column'
Assert ((Get-HubPackageStatus 'Valve.Steam' @('Steam Valve.Steam Unknown 2.0-beta winget') @() '').CanUpdate) 'Non-numeric versions do not crash'
Assert (-not (Get-HubPackageStatus 'Valve.Steam' @('Steam Valve.Steam truncated') @() '').CanUpdate) 'Ambiguous output cannot start an install'
Assert (-not (Get-HubPackageStatus '' $rows @() '').CanUpdate) 'Unsupported launcher'
Assert ((Get-HubPackageStatus 'Valve.Steam' @() @('Steam Valve.Steam 2.0 winget') '').Tone -eq 'Current') 'Installed without update'
$arguments = @(Get-HubUpgradeArguments 'Valve.Steam')
Assert (($arguments -contains '--exact') -and ($arguments -contains '--source') -and ($arguments -notcontains '--all') -and ($arguments -notcontains '--force')) 'Scoped update command'
$rejected = $false
try { Get-HubUpgradeArguments 'Valve.Steam --all' | Out-Null } catch { $rejected = $true }
Assert $rejected 'Reject injected package options'
Assert ((Get-HubUpgradeOutcome 0).State -eq 'Succeeded') 'Success code'
Assert ((Get-HubUpgradeOutcome -1978335189).State -eq 'Unchanged') 'No applicable update is not an install success'
Assert ((Get-HubUpgradeOutcome -1978334967).Message -match 'Neustart') 'Restart requirement'
Assert ((Get-HubUpgradeOutcome -1978334975).State -eq 'Failed') 'Running app is a failure'
Assert ((Get-HubUpgradeOutcome 123).State -eq 'Failed') 'Unknown error is a failure'

# Load the real WPF layout, card creation, queue functions and timer callback, without running the app startup.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing
$tokens=$null; $errors=$null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'LauncherHub.ps1'), [ref]$tokens, [ref]$errors)
foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    Invoke-Expression $node.Extent.Text
}
foreach ($variable in @('catalog','xaml')) {
    $assignment = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.VariablePath.UserPath -eq $variable }, $false)
    Invoke-Expression $assignment.Extent.Text
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('LauncherHub-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $appData=$scratch; $startupFolder=$scratch
    $statusPath=Join-Path $scratch 'check.json'; $installPath=Join-Path $scratch 'install.json'
    $window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new([xml]$xaml))
    $cardsPanel=$window.FindName('Cards'); $totalCount=$window.FindName('TotalCount')
    $runningCount=$window.FindName('RunningCount'); $updateCount=$window.FindName('UpdateCount')
    $footer=$window.FindName('Footer'); $refreshButton=$window.FindName('RefreshButton')
    $updateAllButton=$window.FindName('UpdateAllButton')
    $script:entries = @(
        [pscustomobject]@{ Name='Steam'; Path=(Join-Path $scratch 'Steam.exe') },
        [pscustomobject]@{ Name='EA'; Path=(Join-Path $scratch 'EA.exe') },
        [pscustomobject]@{ Name='Custom'; Path=(Join-Path $scratch 'Custom.exe') }
    )
    $script:cards=@(); $script:updateProcess=$null; $script:installProcess=$null; $script:installCurrent=$null
    $script:installQueue=New-Object 'System.Collections.Generic.Queue[object]'
    $script:installResults=@{}; $script:updatesReady=$true; $script:checkError=''; $script:batchSummary=''
    $script:upgradeLines=@($rows[0], 'EA ElectronicArts.EADesktop 1.0.0 2.0.0 winget')
    $script:installedLines=@(); $script:installDone=0; $script:installTotal=0
    $script:workerCalls=New-Object 'System.Collections.Generic.List[string]'
    function Start-HubWorker([string]$mode,[string]$outputPath,[string]$packageId) {
        $script:workerCalls.Add("${mode}:$packageId")
        $worker = [pscustomobject]@{ HasExited=$false }
        $worker | Add-Member ScriptMethod Dispose { }
        return $worker
    }
    Rebuild-Cards
    Assert ($script:cards.Count -eq 3 -and $updateAllButton.IsEnabled) 'Real cards expose available updates'
    Assert ($script:cards[2].UpdateButton.Content -eq 'Im Launcher prüfen') 'Unsupported app opens launcher'
    Start-LauncherUpdates @($script:cards + $script:cards[0])
    Assert ($script:workerCalls.Count -eq 1 -and $script:installQueue.Count -eq 1) 'One worker and deduplicated queue'
    Assert (-not $updateAllButton.IsEnabled -and -not $refreshButton.IsEnabled) 'Disable overlapping operations'
    Start-LauncherUpdates @($script:cards)
    Assert ($script:workerCalls.Count -eq 1) 'Double click cannot launch duplicate installs'
    Rebuild-Cards
    Assert ($script:cards[0].Operation.Text -eq 'Wird aktualisiert …') 'Rebuilding retains active progress'
    $tickNode = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_Tick' }, $false)
    $tick = $tickNode.Arguments[0].ScriptBlock.GetScriptBlock()
    @{ Mode='Upgrade'; PackageId=$script:installCurrent.Package; State='Failed'; Message='Test failure'; Output='Fixture' } | ConvertTo-Json | Set-Content -LiteralPath $installPath -Encoding UTF8
    $script:installProcess.HasExited=$true
    . $tick
    Assert ($script:installDone -eq 1 -and $script:installCurrent.Name -eq 'EA') 'Failure continues with next launcher'
    # Missing output must be reported as a failure; it must not stall the queue.
    $script:installProcess.HasExited=$true
    . $tick
    Assert ($null -eq $script:installCurrent -and $script:workerCalls[2] -eq 'Check:') 'Queue completion rechecks versions'
    Assert ($script:batchSummary -match '2 fehlgeschlagen') 'Per-item failures retained in summary'
    @{ Mode='Check'; State='Succeeded'; Error=''; Upgrade=''; Installed='Steam Valve.Steam 2.0 winget' } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $script:updateProcess.HasExited=$true
    . $tick
    Assert ($script:updatesReady -and $refreshButton.IsEnabled -and -not $updateAllButton.IsEnabled) 'Completed recheck clears stale install actions'
    # Corrupt check results are caught and cannot turn into an up-to-date status.
    Start-UpdateCheck
    '{broken' | Set-Content -LiteralPath $statusPath
    $script:updateProcess.HasExited=$true
    . $tick
    Assert ($script:checkError -and -not $updateAllButton.IsEnabled -and $refreshButton.IsEnabled) 'Corrupt check fails safely and allows retry'
    Assert (Test-Path -LiteralPath (Join-Path $scratch 'last-update-log.json')) 'Per-package diagnostics saved'
    $script:checkError=''; $script:upgradeLines=$rows
    Apply-UpdateResults
    Start-LauncherUpdates @($script:cards[0])
    @{ Mode='Upgrade'; PackageId='Valve.Steam'; State='Succeeded'; Message='Aktualisierung abgeschlossen'; Output='Fixture' } | ConvertTo-Json | Set-Content -LiteralPath $installPath -Encoding UTF8
    $script:installProcess.HasExited=$true
    . $tick
    Assert ($script:batchSummary -match '1 abgeschlossen' -and $script:installResults['Valve.Steam'].State -eq 'Succeeded') 'Single-update success is recorded and rechecked'
    if ($PreviewDirectory) {
        New-Item -ItemType Directory -Path $PreviewDirectory -Force | Out-Null
        $script:updateProcess=$null; $script:updatesReady=$true; $script:installResults=@{}
        $script:upgradeLines=@($rows[0], 'EA ElectronicArts.EADesktop 1.0 2.0 winget')
        $script:entries += @([pscustomobject]@{ Name='Epic Games Launcher'; Path=(Join-Path $scratch 'Epic.exe') }, [pscustomobject]@{ Name='Rockstar Games Launcher'; Path=(Join-Path $scratch 'Rockstar.exe') })
        Rebuild-Cards
        $footer.Text='2 Updates verfügbar · Kontostatus ist getrennt vom Laufstatus.'
        foreach ($size in @(@(1160,800),@(760,520))) {
            $root=$window.Content
            $root.Measure([System.Windows.Size]::new($size[0],$size[1]))
            $root.Arrange([System.Windows.Rect]::new(0,0,$size[0],$size[1])); $root.UpdateLayout()
            $bitmap=[System.Windows.Media.Imaging.RenderTargetBitmap]::new($size[0],$size[1],96,96,[System.Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($root)
            $encoder=[System.Windows.Media.Imaging.PngBitmapEncoder]::new()
            $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $file=[IO.File]::Create((Join-Path $PreviewDirectory "hub-$($size[0]).png"))
            try { $encoder.Save($file) } finally { $file.Dispose() }
        }
    }
    $window.Close()
} finally {
    Get-ChildItem -LiteralPath $scratch -File | Remove-Item -Force
    Remove-Item -LiteralPath $scratch
}
Write-Output "$script:checks checks passed; no software was installed."
