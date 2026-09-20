param([Parameter(Mandatory)][string]$OutputPath)

$ErrorActionPreference = 'Stop'
try {
    $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (-not (Test-Path -LiteralPath $winget -PathType Leaf)) { throw 'WinGet nicht gefunden' }
    $upgrade = (& $winget upgrade --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
    $installed = (& $winget list --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
    $result = @{ Upgrade=$upgrade; Installed=$installed; Error=''; CheckedAt=(Get-Date).ToString('o') }
} catch {
    $result = @{ Upgrade=''; Installed=''; Error=$_.Exception.Message; CheckedAt=(Get-Date).ToString('o') }
}
$result | ConvertTo-Json -Compress | Set-Content -LiteralPath $OutputPath -Encoding UTF8
