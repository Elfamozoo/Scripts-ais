<#
.SYNOPSIS
    Vérifie l'état des services critiques Windows (Running / Stopped).
.DESCRIPTION
    Script de monitoring qui liste les services Windows marqués comme critiques
    et affiche leur statut. Gère le local et le distant via paramètre -ComputerName.
    Génère un rapport HTML et/ou console avec code couleur.
.PARAMETER ComputerName
    Nom ou adresse IP du serveur distant (par défaut : localhost).
.PARAMETER CriticalServices
    Tableau personnalisé de services à surveiller.
    Par défaut : ADWS, DNS, Dhcp, W3SVC, NTDS, Netlogon, Spooler, EventLog, WinRM, RpcSs.
.PARAMETER OutputPath
    Chemin du rapport HTML généré (par défaut : ./check-services.html).
.PARAMETER EmailTo
    Adresse(s) de notification email en cas de service arrêté (optionnel).
.EXAMPLE
    .\check-services.ps1
    .\check-services.ps1 -ComputerName SRV-DC-01
    .\check-services.ps1 -CriticalServices @("W3SVC","MSSQLSERVER") -OutputPath C:\Rapports\services.html
.NOTES
    Auteur: Scripts-ais
    Version: 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory=$false)]
    [string[]]$CriticalServices = @(
        "ADWS",          # Active Directory Web Services
        "DNS",           # DNS Server
        "Dhcp",          # DHCP Server
        "W3SVC",         # World Wide Web Publishing Service (IIS)
        "NTDS",          # Active Directory Domain Services
        "Netlogon",      # Netlogon
        "Spooler",       # Print Spooler
        "EventLog",      # Windows Event Log
        "WinRM",         # Windows Remote Management
        "RpcSs",         # Remote Procedure Call (RPC)
        "LanmanServer",  # Server
        "LanmanWorkstation", # Workstation
        "MpsSvc",        # Windows Firewall
        "W32Time",       # Windows Time
        "gupdate"        # Google Update (exemple tiers)
    ),

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\check-services.html",

    [Parameter(Mandatory=$false)]
    [string]$EmailTo = ""
)

# ---------- Fonctions ----------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Send-NotificationEmail {
    param(
        [string[]]$StoppedServices,
        [string]$Server
    )
    if (-not $EmailTo) { return }
    $smtpServer = "localhost"
    $subject = "[ALERT] Services arrêtés sur $Server"
    $body = "Les services critiques suivants sont arrêtés sur $Server :`n`n"
    $body += ($StoppedServices -join "`n")
    try {
        Send-MailMessage -To $EmailTo -From "monitoring@$Server" `
                         -Subject $subject -Body $body `
                         -SmtpServer $smtpServer -ErrorAction Stop
        Write-Log "Notification email envoyée à $EmailTo" "OK"
    } catch {
        Write-Log "Échec envoi email : $_" "WARN"
    }
}

# ---------- Récupération des services ----------
Write-Log "Vérification des services critiques sur $ComputerName" "INFO"

try {
    $services = Get-Service -Name $CriticalServices -ComputerName $ComputerName -ErrorAction Stop
} catch {
    Write-Log "Impossible de contacter $ComputerName : $_" "ERROR"
    exit 1
}

# ---------- Analyse ----------
$results = @()
$stopped = @()

foreach ($svc in $services) {
    $status = $svc.Status.ToString()
    $displayName = $svc.DisplayName
    $obj = [PSCustomObject]@{
        NomService   = $svc.Name
        DisplayName  = $displayName
        Statut       = $status
        Machine      = $ComputerName
        Horodatage   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    $results += $obj

    if ($status -eq "Stopped") {
        $stopped += $svc.Name
        Write-Host "  [STOPPED] $($svc.Name) - $displayName" -ForegroundColor Red
    } elseif ($status -eq "Running") {
        Write-Host "  [RUNNING] $($svc.Name) - $displayName" -ForegroundColor Green
    } else {
        Write-Host "  [$status] $($svc.Name) - $displayName" -ForegroundColor Yellow
    }
}

# ---------- Rapport HTML ----------
$htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Rapport Services Critiques - $ComputerName</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #f5f5f5; }
        h1 { color: #333; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        table { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        th { background: #0078d4; color: #fff; padding: 10px; text-align: left; }
        td { padding: 8px 10px; border-bottom: 1px solid #ddd; }
        .running { color: green; font-weight: bold; }
        .stopped { color: red; font-weight: bold; }
        .summary { margin: 20px 0; padding: 15px; border-radius: 5px; }
        .ok { background: #d4edda; border: 1px solid #c3e6cb; }
        .ko { background: #f8d7da; border: 1px solid #f5c6cb; }
        .footer { margin-top: 20px; color: #666; font-size: 0.9em; }
    </style>
</head>
<body>
    <h1>Rapport des Services Critiques</h1>
    <p><strong>Serveur :</strong> $ComputerName</p>
    <p><strong>Généré le :</strong> $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")</p>
"@

$summaryClass = if ($stopped.Count -eq 0) { "ok" } else { "ko" }
$summaryText = if ($stopped.Count -eq 0) { "Tous les services critiques sont en cours d'exécution." } else { "$($stopped.Count) service(s) critique(s) arrêté(s) !" }

$htmlBody = @"
    <div class="summary $summaryClass">
        <strong>Résumé :</strong> $summaryText
    </div>
    <table>
        <tr><th>Service</th><th>Nom d'affichage</th><th>Statut</th></tr>
"@

foreach ($r in $results) {
    $cssClass = if ($r.Statut -eq "Running") { "running" } elseif ($r.Statut -eq "Stopped") { "stopped" } else { "warning" }
    $htmlBody += "<tr><td>$($r.NomService)</td><td>$($r.DisplayName)</td><td class='$cssClass'>$($r.Statut)</td></tr>"
}

$htmlFooter = @"
    </table>
    <div class="footer">
        <p>Script check-services.ps1 - Intervalle recommandé : toutes les 5 minutes</p>
    </div>
</body>
</html>
"@

$html = $htmlHeader + $htmlBody + $htmlFooter
$html | Out-File -FilePath $OutputPath -Encoding utf8
Write-Log "Rapport HTML généré : $OutputPath" "OK"

# ---------- Alerte email si nécessaire ----------
if ($stopped.Count -gt 0) {
    Send-NotificationEmail -StoppedServices $stopped -Server $ComputerName
    Write-Log "ATTENTION : $($stopped.Count) services arrêtés sur $ComputerName" "ERROR"
    exit 1
} else {
    Write-Log "OK : Tous les services critiques sont en cours d'exécution sur $ComputerName" "OK"
    exit 0
}
