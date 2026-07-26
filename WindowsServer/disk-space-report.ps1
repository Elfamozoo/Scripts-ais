<#
.SYNOPSIS
    Rapport d'espace disque via WMI (local et serveurs distants).
.DESCRIPTION
    Interroge Win32_LogicalDisk via WMI pour collecter l'espace libre,
    utilisé, et total de chaque volume. Supporte le localhost et une
    liste de serveurs distants. Génère un rapport HTML avec alertes
    de seuil configurable. Peut exporter en CSV pour ingestion dans
    un outil de monitoring (PRTG, Zabbix, etc.).
.PARAMETER ComputerNames
    Tableau de noms de serveurs. Par défaut : localhost uniquement.
    Passer @("SRV-DC-01","SRV-FS-01","SRV-IIS-01") pour des cibles multiples.
.PARAMETER ThresholdPercent
    Seuil d'alerte en pourcentage d'espace libre (défaut : 10%).
.PARAMETER ThresholdGB
    Seuil d'alerte en Go d'espace libre (défaut : 5 Go). Prioritaire sur ThresholdPercent.
.PARAMETER OutputPath
    Chemin du rapport HTML (défaut : ./disk-space-report.html).
.PARAMETER CsvPath
    Chemin du fichier CSV (facultatif).
.PARAMETER ExcludeDrives
    Lecteurs à exclure (ex: @("A:","B:")).
.EXAMPLE
    .\disk-space-report.ps1
    .\disk-space-report.ps1 -ComputerNames @("SRV-DC-01","SRV-SQL-01") -ThresholdPercent 15
    .\disk-space-report.ps1 -ComputerNames @("srv-dc-01","srv-fs-01") -CsvPath C:\Rapports\disks.csv
.NOTES
    Auteur: Scripts-ais
    Version: 1.0
    Requiert: WinRM activé sur les cibles distantes, utilisateur admin domaine.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string[]]$ComputerNames = @($env:COMPUTERNAME),

    [Parameter(Mandatory=$false)]
    [int]$ThresholdPercent = 10,

    [Parameter(Mandatory=$false)]
    [int]$ThresholdGB = 5,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\disk-space-report.html",

    [Parameter(Mandatory=$false)]
    [string]$CsvPath = "",

    [Parameter(Mandatory=$false)]
    [string[]]$ExcludeDrives = @("A:")
)

# ---------- Fonctions ----------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Get-DiskInfo {
    param([string]$Computer)
    Write-Log "Interrogation WMI sur $Computer" "INFO"
    try {
        $disks = Get-WmiObject -ComputerName $Computer -Class Win32_LogicalDisk `
                -Filter "DriveType=3" -ErrorAction Stop  # DriveType 3 = Local Disk
        $results = @()
        foreach ($disk in $disks) {
            $drive = $disk.DeviceID
            if ($drive -in $ExcludeDrives) { continue }

            $totalGB = [math]::Round($disk.Size / 1GB, 2)
            $freeGB  = [math]::Round($disk.FreeSpace / 1GB, 2)
            $usedGB  = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 2)
            $freePct = if ($totalGB -gt 0) { [math]::Round(($freeGB / $totalGB) * 100, 1) } else { 0 }

            # Alerte si seuil dépassé
            $alert = $false
            $alertReason = ""
            if ($freeGB -lt $ThresholdGB) {
                $alert = $true
                $alertReason = "Espace libre < ${ThresholdGB}Go"
            } elseif ($freePct -lt $ThresholdPercent) {
                $alert = $true
                $alertReason = "Espace libre < ${ThresholdPercent}%"
            }

            $results += [PSCustomObject]@{
                Computer     = $Computer
                Drive        = $drive
                VolumeName   = $disk.VolumeName
                TotalGB      = $totalGB
                UsedGB       = $usedGB
                FreeGB       = $freeGB
                FreePercent  = $freePct
                Alert        = $alert
                AlertReason  = $alertReason
                Timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }

            $color = if ($alert) { "Red" } elseif ($freePct -lt 20) { "Yellow" } else { "Green" }
            Write-Host "  [$Computer] $drive ($($disk.VolumeName)) : ${freeGB}Go libre / ${totalGB}Go (${freePct}%)" -ForegroundColor $color
        }
        return $results
    } catch {
        Write-Log "Échec WMI sur $Computer : $_" "ERROR"
        return $null
    }
}

# ---------- Collecte ----------
Write-Log "Collecte des informations disque (seuil : ${ThresholdPercent}% libre ou ${ThresholdGB}Go)" "INFO"

$allDisks = @()
$alerts = @()

foreach ($comp in $ComputerNames) {
    $diskData = Get-DiskInfo -Computer $comp
    if ($diskData -and $diskData.Count -gt 0) {
        $allDisks += $diskData
        $alerts += $diskData | Where-Object { $_.Alert }
    }
}

$totalDisks = ($allDisks | Measure-Object).Count
$totalAlerts = ($alerts | Measure-Object).Count

Write-Log "Total : $totalDisks volumes interrogés, $totalAlerts alerte(s)" "INFO"

# ---------- Export CSV ----------
if ($CsvPath -and $totalDisks -gt 0) {
    try {
        $allDisks | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
        Write-Log "Export CSV : $CsvPath" "OK"
    } catch {
        Write-Log "Échec export CSV : $_" "WARN"
    }
}

# ---------- Rapport HTML ----------
$thresholdLine = if ($ThresholdGB -gt 0) { "${ThresholdGB}Go" } else { "${ThresholdPercent}%" }
$htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Rapport Espace Disque - $(Get-Date -Format "yyyy-MM-dd")</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #f5f5f5; }
        h1 { color: #333; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #555; margin-top: 25px; }
        table { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin-bottom: 20px; }
        th { background: #0078d4; color: #fff; padding: 8px; text-align: left; }
        td { padding: 6px 8px; border-bottom: 1px solid #ddd; }
        tr:hover { background: #f0f0f0; }
        .alert-red { background: #f8d7da; }
        .alert-yellow { background: #fff3cd; }
        .alert-green { background: #d4edda; }
        .critical { background: #dc3545; color: #fff; padding: 2px 8px; border-radius: 3px; }
        .warning { background: #ffc107; color: #333; padding: 2px 8px; border-radius: 3px; }
        .ok { background: #28a745; color: #fff; padding: 2px 8px; border-radius: 3px; }
        .summary-box { padding: 15px; border-radius: 5px; margin: 20px 0; }
        .bar-bg { background: #e9ecef; border-radius: 4px; height: 20px; width: 150px; display: inline-block; }
        .bar-fill { height: 20px; border-radius: 4px; display: block; }
        .footer { margin-top: 20px; color: #666; font-size: 0.9em; }
        .server-group { margin-bottom: 30px; }
    </style>
</head>
<body>
    <h1>Rapport d'Espace Disque</h1>
    <p><strong>Généré le :</strong> $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")</p>
    <p><strong>Seuil d'alerte :</strong> $thresholdLine d'espace libre</p>
    <p><strong>Serveurs interrogés :</strong> $($ComputerNames -join ', ')</p>
"@

$summaryClass = if ($totalAlerts -eq 0) { "alert-green" } else { "alert-red" }
$summaryText = if ($totalAlerts -eq 0) { "[OK] Aucun problème d'espace disque détecté." } else { "[WARN] $totalAlerts volume(s) en alerte sur $totalDisks volume(s) !" }

$htmlBody = @"
    <div class="summary-box $summaryClass">
        <strong>$summaryText</strong>
    </div>
"@

foreach ($comp in $ComputerNames) {
    $compDisks = $allDisks | Where-Object { $_.Computer -eq $comp }
    if (-not $compDisks) { continue }

    $htmlBody += "<div class='server-group'><h2>$comp</h2><table><tr><th>Lecteur</th><th>Nom</th><th>Total (Go)</th><th>Utilisé (Go)</th><th>Libre (Go)</th><th>Libre %</th><th>Barre</th><th>Statut</th></tr>"

    foreach ($d in $compDisks) {
        $rowClass = if ($d.Alert) { "alert-red" } elseif ($d.FreePercent -lt 20) { "alert-yellow" } else { "alert-green" }
        $statusBadge = if ($d.Alert) { "<span class='critical'>ALERTE</span>" } elseif ($d.FreePercent -lt 20) { "<span class='warning'>ATTENTION</span>" } else { "<span class='ok'>OK</span>" }
        $usedPct = 100 - $d.FreePercent
        $barColor = if ($d.Alert) { "#dc3545" } elseif ($d.FreePercent -lt 20) { "#ffc107" } else { "#28a745" }
        $bar = "<div class='bar-bg'><div class='bar-fill' style='width:${usedPct}%;background:${barColor};'></div></div>"
        $htmlBody += "<tr class='$rowClass'><td>$($d.Drive)</td><td>$($d.VolumeName)</td><td>$($d.TotalGB)</td><td>$($d.UsedGB)</td><td>$($d.FreeGB)</td><td>$($d.FreePercent)%</td><td>$bar</td><td>$statusBadge</td></tr>"
    }
    $htmlBody += "</table></div>"
}

$htmlFooter = @"
    <div class="footer">
        <p>Script disk-space-report.ps1 - Intervalle recommandé : toutes les heures</p>
        <p>Seuil configuré : ${ThresholdPercent}% ou ${ThresholdGB}Go libre minimum</p>
    </div>
</body>
</html>
"@

$html = $htmlHeader + $htmlBody + $htmlFooter
$html | Out-File -FilePath $OutputPath -Encoding utf8
Write-Log "Rapport HTML généré : $OutputPath" "OK"

# ---------- Code de sortie ----------
if ($totalAlerts -gt 0) {
    Write-Log "$totalAlerts volume(s) en alerte" "ERROR"
    exit 1
}
exit 0
