<#
.SYNOPSIS
    Extrait les erreurs des journaux d'événements Windows des dernières 24h.
.DESCRIPTION
    Parcourt les logs System, Application, Security, DNS Server, DHCP, et IIS
    pour collecter toutes les entrées de niveau Error / Critical des dernières 24h.
    Génère un rapport CSV et HTML, avec option d'export vers un serveur distant.
.PARAMETER ComputerName
    Nom ou IP du serveur cible (localhost par défaut).
.PARAMETER HoursBack
    Période de recherche en heures (défaut : 24).
.PARAMETER LogNames
    Liste des journaux à inspecter.
.PARAMETER OutputPath
    Chemin du rapport (défaut : ./eventlog-errors.html).
.PARAMETER CsvPath
    Chemin du fichier CSV (facultatif).
.EXAMPLE
    .\eventlog-errors.ps1
    .\eventlog-errors.ps1 -ComputerName SRV-DC-01 -HoursBack 48
    .\eventlog-errors.ps1 -LogNames @("System","Application") -CsvPath C:\Logs\errors.csv
.NOTES
    Auteur: Scripts-ais
    Version: 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory=$false)]
    [int]$HoursBack = 24,

    [Parameter(Mandatory=$false)]
    [string[]]$LogNames = @(
        "System",
        "Application",
        "Security",
        "DNS Server",
        "DHCP Server",
        "Microsoft-Windows-IIS-Logging/Operational",
        "Microsoft-Windows-WinRM/Operational",
        "Microsoft-Windows-GroupPolicy/Operational"
    ),

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\eventlog-errors.html",

    [Parameter(Mandatory=$false)]
    [string]$CsvPath = ""
)

# ---------- Fonctions ----------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Get-ErrorCountBySource {
    param([array]$Entries)
    $groups = $Entries | Group-Object -Property Provider
    $groups | Select-Object @{N='Source';E={$_.Name}}, Count | Sort-Object Count -Descending
}

# ---------- Point de départ ----------
$since = (Get-Date).AddHours(-$HoursBack)
Write-Log "Recherche des erreurs depuis $since sur $ComputerName" "INFO"

$allErrors = @()

foreach ($log in $LogNames) {
    Write-Log "Inspection du journal : $log" "INFO"
    try {
        $entries = Get-WinEvent -ComputerName $ComputerName -LogName $log -MaxEvents 5000 -ErrorAction SilentlyContinue |
                   Where-Object { $_.TimeCreated -ge $since -and $_.Level -in 1,2 } |
                   Select-Object TimeCreated, LevelDisplayName, Id, Provider, Message, LogName

        $count = ($entries | Measure-Object).Count
        Write-Log "  $count entrées trouvées dans $log" "INFO"
        $allErrors += $entries
    } catch {
        Write-Log "  Journal '$log' inaccessible : $_" "WARN"
    }
}

# ---------- Statistiques ----------
$totalErrors = ($allErrors | Measure-Object).Count
Write-Log "Total d'erreurs/critiques trouvées : $totalErrors" "INFO"

$errorSources = Get-ErrorCountBySource -Entries $allErrors
Write-Host "`nTop sources d'erreurs :" -ForegroundColor Cyan
$errorSources | Format-Table -AutoSize | Out-String | Write-Host

# ---------- Export CSV ----------
if ($CsvPath -and $totalErrors -gt 0) {
    try {
        $allErrors | Select-Object TimeCreated, LevelDisplayName, Id, Provider, LogName, @{N='MessageCourt';E={$_.Message.Substring(0, [Math]::Min(200, $_.Message.Length))}} |
                     Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
        Write-Log "Export CSV : $CsvPath" "OK"
    } catch {
        Write-Log "Échec export CSV : $_" "WARN"
    }
}

# ---------- Rapport HTML ----------
$htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Rapport Événements Erreurs - $ComputerName</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #f5f5f5; }
        h1 { color: #333; border-bottom: 2px solid #d9534f; padding-bottom: 10px; }
        h2 { color: #555; }
        .summary { background: #f8d7da; border: 1px solid #f5c6cb; padding: 15px; border-radius: 5px; margin: 20px 0; }
        table { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        th { background: #d9534f; color: #fff; padding: 8px; text-align: left; }
        td { padding: 6px 8px; border-bottom: 1px solid #ddd; font-size: 0.9em; }
        tr:hover { background: #f8d7da; }
        .critical { background: #dc3545; color: #fff; padding: 2px 6px; border-radius: 3px; }
        .error { background: #ffc107; color: #333; padding: 2px 6px; border-radius: 3px; }
        .msg { max-width: 500px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .footer { margin-top: 20px; color: #666; font-size: 0.9em; }
    </style>
</head>
<body>
    <h1>Rapport d'Erreurs (dernières $HoursBack h)</h1>
    <p><strong>Serveur :</strong> $ComputerName</p>
    <p><strong>Période :</strong> $since au $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")</p>
"@

if ($totalErrors -eq 0) {
    $htmlBody = @"
    <div class="summary" style="background:#d4edda;border-color:#c3e6cb;">
        <strong>Aucune erreur trouvée dans la période.</strong>
    </div>
"@
} else {
    $htmlBody = @"
    <div class="summary">
        <strong>$totalErrors erreur(s)</strong> trouvée(s) dans les journaux analysés.
    </div>
    <h2>Top sources</h2>
    <table>
        <tr><th>Source</th><th>Nombre d'erreurs</th></tr>
"@
    foreach ($src in $errorSources) {
        $htmlBody += "<tr><td>$($src.Source)</td><td>$($src.Count)</td></tr>"
    }
    $htmlBody += @"
    </table>
    <h2>Détail des erreurs (dernières 100)</h2>
    <table>
        <tr><th>Date</th><th>Niveau</th><th>ID</th><th>Source</th><th>Message</th></tr>
"@
    $counter = 0
    foreach ($e in ($allErrors | Sort-Object TimeCreated -Descending | Select-Object -First 100)) {
        $levelClass = if ($e.LevelDisplayName -eq "Critical") { "critical" } else { "error" }
        $shortMsg = $e.Message.Substring(0, [Math]::Min(300, $e.Message.Length))
        $htmlBody += "<tr><td>$($e.TimeCreated.ToString('dd/MM HH:mm'))</td><td><span class='$levelClass'>$($e.LevelDisplayName)</span></td><td>$($e.Id)</td><td>$($e.Provider)</td><td class='msg' title='$([System.Security.SecurityElement]::Escape($e.Message))'>$([System.Security.SecurityElement]::Escape($shortMsg))</td></tr>"
        $counter++
    }
}

$htmlFooter = @"
    </table>
    <div class="footer">
        <p>Script eventlog-errors.ps1 - Intervalle recommandé : toutes les 6 heures</p>
    </div>
</body>
</html>
"@

$html = $htmlHeader + $htmlBody + $htmlFooter
$html | Out-File -FilePath $OutputPath -Encoding utf8
Write-Log "Rapport HTML généré : $OutputPath" "OK"

# ---------- Résultat final ----------
if ($totalErrors -gt 0) {
    Write-Log "Terminé avec $totalErrors erreur(s) détectée(s)" "WARN"
    exit 1
} else {
    Write-Log "Terminé - Aucune erreur dans la période" "OK"
    exit 0
}
