param(
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateSet('Check','Upgrade')][string]$Mode = 'Check',
    [string]$PackageId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LauncherHub.UpdateCore.ps1')
$result = @{ Mode=$Mode; PackageId=$PackageId; Upgrade=''; Installed=''; Error='';
    State='Failed'; Message=''; Output=''; CheckedAt=(Get-Date).ToString('o') }
try {
    $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (-not (Test-Path -LiteralPath $winget -PathType Leaf)) { throw 'WinGet nicht gefunden. Bitte App-Installer über den Microsoft Store installieren.' }
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [Console]::OutputEncoding
    # Native stderr is diagnostic output, not a PowerShell terminating error.
    $ErrorActionPreference = 'Continue'
    if ($Mode -eq 'Upgrade') {
        $arguments = @(Get-HubUpgradeArguments $PackageId)
        $result.Output = (& $winget @arguments 2>&1 | Out-String)
        $outcome = Get-HubUpgradeOutcome $LASTEXITCODE
        $result.State = $outcome.State; $result.Message = $outcome.Message; $result.ExitCode = $outcome.Code
    } else {
        $result.Upgrade = (& $winget upgrade --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
        $upgradeCode = $LASTEXITCODE
        $result.Installed = (& $winget list --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
        $listCode = $LASTEXITCODE
        if ($upgradeCode -notin @(0, -1978335189) -or $listCode -ne 0) {
            throw "WinGet-Prüfung fehlgeschlagen (upgrade: $upgradeCode, list: $listCode)."
        }
        $result.State = 'Succeeded'
    }
} catch {
    $result.Error = $_.Exception.Message; $result.Message = $result.Error
} finally {
    $ErrorActionPreference = 'Stop'
    $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}
