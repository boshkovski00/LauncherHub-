$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
& $compiler /nologo /target:winexe /optimize+ /reference:System.Windows.Forms.dll "/win32icon:$PSScriptRoot\LauncherHub.ico" "/out:$PSScriptRoot\LauncherHub.exe" "$PSScriptRoot\LauncherHub.Start.cs"
if ($LASTEXITCODE -ne 0) { throw 'Startprogramm konnte nicht erstellt werden.' }
$files = @('LauncherHub.exe','LauncherHub.cmd','LauncherHub.ico','LauncherHub.ps1',
    'LauncherHubUpdates.ps1','LauncherHub.UpdateCore.ps1','README.md')
Compress-Archive -LiteralPath @($files | ForEach-Object { Join-Path $PSScriptRoot $_ }) -DestinationPath (Join-Path $PSScriptRoot 'LauncherHub-Portabel.zip') -Force
Write-Output 'LauncherHub.exe und LauncherHub-Portabel.zip erstellt.'
