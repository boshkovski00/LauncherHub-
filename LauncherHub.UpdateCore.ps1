# Shared, side-effect-free update logic (Windows PowerShell 5.1).
function Get-HubPackageStatus {
    param([string]$PackageId, [string[]]$UpgradeLines, [string[]]$InstalledLines, [string]$ActualVersion)
    $status = [pscustomobject]@{ CanUpdate=$false; Available=''; Text='●  Version ungeprüft'; Tone='Unknown' }
    if (-not $PackageId) { $status.Text = 'Im Launcher prüfen'; return $status }
    $idPattern = '(?<!\S)' + [regex]::Escape($PackageId) + '(?=\s|$)'
    $upgrade = @($UpgradeLines | Where-Object { $_ -match $idPattern }) | Select-Object -First 1
    $installed = @($InstalledLines | Where-Object { $_ -match $idPattern }) | Select-Object -First 1
    if ($upgrade) {
        $rowPattern = $idPattern + '\s+(?:<\s*)?\S+\s+(?<available>\S+?)(?:\s+winget)?\s*$'
        if ($upgrade -notmatch $rowPattern) { $status.Text = 'Hinweis im Launcher prüfen'; return $status }
        $status.Available = $Matches.available
        if ($status.Available -in @('winget','Unknown','Unbekannt')) { $status.Text = 'Hinweis im Launcher prüfen'; return $status }
        $actual = $null; $available = $null
        if ([version]::TryParse($ActualVersion, [ref]$actual) -and
            [version]::TryParse($status.Available, [ref]$available) -and $actual.Major -eq $available.Major -and $actual -ge $available) {
            $status.Text = '✓  Programmdatei auf Stand'; $status.Tone = 'Current'
        } else {
            $status.CanUpdate = $true; $status.Text = "Update auf $($status.Available)"; $status.Tone = 'Available'
        }
    } elseif ($installed -and $installed -notmatch '\b(Unknown|Unbekannt)\b') {
        $status.Text = '✓  Kein Update gemeldet'; $status.Tone = 'Current'
    }
    return $status
}

function Get-HubUpgradeArguments {
    param([string]$PackageId)
    if ($PackageId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'Ungültige Paket-ID' }
    # Limit each operation to one exact package; never update unrelated PC software.
    @('upgrade', '--id', $PackageId, '--exact', '--source', 'winget', '--silent',
        '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
}

function Get-HubUpgradeOutcome {
    param([long]$ExitCode)
    $code = '0x{0:X8}' -f ($ExitCode -band 4294967295L)
    switch ($code) {
        '0x00000000' { return [pscustomobject]@{ State='Succeeded'; Message='Aktualisierung abgeschlossen'; Code=$code } }
        '0x8A15002B' { return [pscustomobject]@{ State='Unchanged'; Message='Kein anwendbares Update'; Code=$code } }
        '0x8A15004F' { return [pscustomobject]@{ State='Unchanged'; Message='Keine neuere Version'; Code=$code } }
        '0x8A150109' { return [pscustomobject]@{ State='Succeeded'; Message='Installiert · Windows-Neustart erforderlich'; Code=$code } }
        '0x8A150101' { return [pscustomobject]@{ State='Failed'; Message='Launcher schließen und erneut versuchen'; Code=$code } }
        '0x8A150103' { return [pscustomobject]@{ State='Failed'; Message='Datei belegt · Launcher schließen und erneut versuchen'; Code=$code } }
        '0x8A15010C' { return [pscustomobject]@{ State='Failed'; Message='Aktualisierung abgebrochen'; Code=$code } }
        '0x8A150019' { return [pscustomobject]@{ State='Failed'; Message='Administratorberechtigung erforderlich'; Code=$code } }
        default { return [pscustomobject]@{ State='Failed'; Message="Update fehlgeschlagen ($code)"; Code=$code } }
    }
}
