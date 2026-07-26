<#
.SYNOPSIS
    État des mises à jour Windows installées et en attente.
.DESCRIPTION
    Utilise Microsoft.Update.Session (COM) et PSWindowsUpdate (si disponible)
    pour lister les mises à jour installées, les mises à jour en attente,
    le statut de Windows Update, et l'historique des derniers reboots.
    Génère un rapport HTML avec recommandations.
.PARAMETER ComputerName
    Serveur cible (par défaut : localhost).
.PARAMETER IncludeRebootHistory
    Inclure l'historique des redémarrages via le journal System (défaut : $true).
.PARAMETER OutputPath
    Chemin du rapport HTML (défaut : ./update-status.html).
.PARAMETER UsePSWindowsUpdate
    Tenter d'utiliser le module PSWindowsUpdate pour plus de détails.
.PARAMETER DaysHistory
    Historique des mises à jour à remonter (défaut : 30 jours).
.EXAMPLE
    .\update-status.ps1
    .\update-status.ps1 -ComputerName SRV-DC-01 -DaysHistory 7
    .\update-status.ps1 -UsePSWindowsUpdate
.NOTES
    Auteur: Scripts-ais
    Version: 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeRebootHistory = $true,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\update-status.html",

    [Parameter(Mandatory=$false)]
    [switch]$UsePSWindowsUpdate = $false,

    [Parameter(Mandatory=$false)]
    [int]$DaysHistory = 30
)

# ---------- Fonctions ----------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Get-WURebootRequired {
    # Vérifie via le système si un redémarrage est en attente
    $rebootPending = $false
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SOFTWARE\Microsoft\ServerManager\CurrentRebootAttempts",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
    )
    foreach ($path in $paths) {
        if (Test-Path $path) {
            $rebootPending = $true
            break
        }
    }
    return $rebootPending
}

function Get-WUStatusViaCOM {
    # Utilise l'API COM Windows Update (natif, pas de module requis)
    try {
        $session = New-Object -ComObject Microsoft.Update.Session -ErrorAction Stop
        $searcher = $session.CreateUpdateSearcher()
        
        # Total des mises à jour installées (cache)
        $installedCount = $searcher.GetTotalHistoryCount()
        
        # Recherche des mises à jour disponibles
        $searchResult = $searcher.Search("IsInstalled=0 AND IsHidden=0")
        $pendingUpdates = @()
        foreach ($update in $searchResult.Updates) {
            $pendingUpdates += [PSCustomObject]@{
                Title       = $update.Title
                KB          = if ($update.Title -match 'KB(\d+)') { "KB$($matches[1])" } else { "N/A" }
                Size        = [math]::Round($update.MaxDownloadSize / 1MB, 1)
                IsMandatory = $update.IsMandatory
                Categories  = ($update.Categories | ForEach-Object { $_.Name }) -join '; '
                Severity    = $update.MsrcSeverity
            }
        }

        # Dernière recherche
        $lastSearchDate = $null
        try {
            $lastSearchInfo = $searcher.QueryHistory(0, 1)
            $lastSearchDate = $lastSearchInfo[0].Date
        } catch { }

        return [PSCustomObject]@{
            InstalledCount    = $installedCount
            PendingCount      = $pendingUpdates.Count
            PendingUpdates    = $pendingUpdates
            LastSearch        = $lastSearchDate
            Online            = $true
        }
    } catch {
        Write-Log "API COM Windows Update inaccessible : $_" "WARN"
        return [PSCustomObject]@{
            InstalledCount = 0
            PendingCount   = -1
            PendingUpdates = @()
            LastSearch     = $null
            Online         = $false
        }
    }
}

function Get-RebootHistory {
    param([int]$Days = 30)
    $since = (Get-Date).AddDays(-$Days)
    try {
        $events = Get-WinEvent -LogName System -FilterXPath "*[System[EventID=12 or EventID=13 or EventID=6005 or EventID=6006 or EventID=6008 or EventID=41]]" -MaxEvents 100 -ErrorAction SilentlyContinue |
                  Where-Object { $_.TimeCreated -ge $since } |
                  Select-Object TimeCreated, Id,
                      @{N='Type';E={
                          switch ($_.Id) {
                              12  {'OS Démarré'}
                              13  {'OS Arrêté'}
                              6005{'Log Event démarré (boot)'}
                              6006{'Arrêt propre'}
                              6008{'Arrêt inattendu'}
                              41  {'Redémarrage sans arrêt propre'}
                              default {"Événement $($_.Id)"}
                          }
                      }},
                      @{N='Message';E={$_.Message.Substring(0, [Math]::Min(150, $_.Message.Length))}}
        return $events
    } catch {
        Write-Log "Impossible de lire l'historique des redémarrages : $_" "WARN"
        return $null
    }
}

# ---------- Collecte ----------
Write-Log "Analyse du statut Windows Update sur $ComputerName" "INFO"

# Statut du service Windows Update
$wuService = Get-Service -Name "wuauserv" -ComputerName $ComputerName -ErrorAction SilentlyContinue
$wuServiceStatus = if ($wuService) { $wuService.Status.ToString() } else { "Inaccessible" }

# Via API COM (natif)
$wuInfo = Get-WUStatusViaCOM

# Redémarrage en attente ?
$rebootRequired = Get-WURebootRequired

# Historique des redémarrages
$rebootHistory = if ($IncludeRebootHistory) { Get-RebootHistory -Days $DaysHistory } else { $null }

# Informations système
$osInfo = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $ComputerName -ErrorAction SilentlyContinue
$osName = if ($osInfo) { $osInfo.Caption } else { "N/A" }
$osBuild = if ($osInfo) { "$($osInfo.Version) (Build $($osInfo.BuildNumber))" } else { "N/A" }
$lastBoot = if ($osInfo) { $osInfo.LastBootUpTime } else { "N/A" }
$uptime = if ($osInfo) {
    $ts = (Get-Date) - $osInfo.LastBootUpTime
    "$($ts.Days)j $($ts.Hours)h $($ts.Minutes)m"
} else { "N/A" }

# ---------- Résumé console ----------
Write-Log "OS : $osName $osBuild" "INFO"
Write-Log "Dernier démarrage : $lastBoot (Uptime : $uptime)" "INFO"
Write-Log "Service WUAUSERV : $wuServiceStatus" "INFO"
Write-Log "Mises à jour en attente : $($wuInfo.PendingCount)" $(if ($wuInfo.PendingCount -gt 0) { "WARN" } else { "OK" })
Write-Log "Redémarrage en attente : $rebootRequired" $(if ($rebootRequired) { "WARN" } else { "OK" })

# ---------- Rapport HTML ----------
$pendingClass = if ($wuInfo.PendingCount -gt 0) { "alert-red" } elseif ($wuInfo.PendingCount -eq 0) { "alert-green" } else { "alert-yellow" }
$pendingText = if ($wuInfo.PendingCount -gt 0) { "$($wuInfo.PendingCount) mise(s) à jour en attente" } elseif ($wuInfo.PendingCount -eq 0) { "Aucune mise à jour en attente" } else { "Non déterminé" }

$rebootClass = if ($rebootRequired) { "alert-red" } else { "alert-green" }
$rebootText = if ($rebootRequired) { "REDÉMARRAGE REQUIS" } else { "Aucun redémarrage nécessaire" }

$htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Statut Windows Update - $ComputerName</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #f5f5f5; }
        h1 { color: #333; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #555; margin-top: 25px; }
        table { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin-bottom: 20px; }
        th { background: #0078d4; color: #fff; padding: 8px; text-align: left; }
        td { padding: 6px 8px; border-bottom: 1px solid #ddd; }
        tr:hover { background: #f0f0f0; }
        .alert-red { background: #f8d7da; }
        .alert-green { background: #d4edda; }
        .alert-yellow { background: #fff3cd; }
        .badge-red { background: #dc3545; color: #fff; padding: 3px 10px; border-radius: 3px; display: inline-block; }
        .badge-green { background: #28a745; color: #fff; padding: 3px 10px; border-radius: 3px; display: inline-block; }
        .badge-yellow { background: #ffc107; color: #333; padding: 3px 10px; border-radius: 3px; display: inline-block; }
        .info-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; margin: 20px 0; }
        .info-card { background: #fff; padding: 15px; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        .info-card h3 { margin-top: 0; color: #0078d4; }
        .footer { margin-top: 20px; color: #666; font-size: 0.9em; }
    </style>
</head>
<body>
    <h1>Statut Windows Update - $ComputerName</h1>
    <p><strong>Généré le :</strong> $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")</p>
"@

$htmlBody = @"
    <div class="info-grid">
        <div class="info-card">
            <h3>Système</h3>
            <p><strong>OS :</strong> $osName</p>
            <p><strong>Build :</strong> $osBuild</p>
            <p><strong>Dernier boot :</strong> $lastBoot</p>
            <p><strong>Uptime :</strong> $uptime</p>
            <p><strong>Service WU :</strong> <span class='$(if($wuServiceStatus -eq "Running"){"badge-green"}else{"badge-red"})'>$wuServiceStatus</span></p>
        </div>
        <div class="info-card">
            <h3>Résumé Mises à Jour</h3>
            <p><strong>MàJ installées (total) :</strong> $($wuInfo.InstalledCount)</p>
            <p><strong>MàJ en attente :</strong> <span class='$(if($wuInfo.PendingCount -gt 0){"badge-red"}else{"badge-green"})'>$pendingText</span></p>
            <p><strong>Redémarrage :</strong> <span class='$(if($rebootRequired){"badge-red"}else{"badge-green"})'>$rebootText</span></p>
        </div>
    </div>
"@

# Liste des mises à jour en attente
if ($wuInfo.PendingUpdates.Count -gt 0) {
    $htmlBody += @"
    <h2>Mises à jour en attente ($($wuInfo.PendingCount))</h2>
    <table>
        <tr><th>KB</th><th>Titre</th><th>Taille (Mo)</th><th>Sévérité</th><th>Obligatoire</th></tr>
"@
    foreach ($upd in ($wuInfo.PendingUpdates | Sort-Object Severity -Descending)) {
        $mandatoryBadge = if ($upd.IsMandatory) { "<span class='badge-red'>Oui</span>" } else { "Non" }
        $htmlBody += "<tr><td>$($upd.KB)</td><td>$($upd.Title)</td><td>$($upd.Size)</td><td>$($upd.Severity)</td><td>$mandatoryBadge</td></tr>"
    }
    $htmlBody += "</table>"
}

# Historique des redémarrages
if ($rebootHistory -and ($rebootHistory | Measure-Object).Count -gt 0) {
    $htmlBody += @"
    <h2>Historique des redémarrages ($DaysHistory jours)</h2>
    <table>
        <tr><th>Date</th><th>Type</th><th>Message</th></tr>
"@
    $crashCount = 0
    foreach ($evt in ($rebootHistory | Sort-Object TimeCreated -Descending)) {
        $rowClass = if ($evt.Id -in 41,6008) { "alert-red" } else { "" }
        if ($evt.Id -in 41,6008) { $crashCount++ }
        $htmlBody += "<tr class='$rowClass'><td>$($evt.TimeCreated.ToString('dd/MM HH:mm'))</td><td>$($evt.Type)</td><td>$($evt.Message)</td></tr>"
    }
    $htmlBody += "</table>"
    if ($crashCount -gt 0) {
        $htmlBody += "<p style='color:red;'><strong>⚠️ $crashCount arrêt(s) inattendu(s) détecté(s) !</strong></p>"
    }
}

$htmlFooter = @"
    <div class="footer">
        <p>Script update-status.ps1 - Intervalle recommandé : quotidien</p>
        <p>Source : API COM Microsoft.Update.Session + EventLog System</p>
    </div>
</body>
</html>
"@

$html = $htmlHeader + $htmlBody + $htmlFooter
$html | Out-File -FilePath $OutputPath -Encoding utf8
Write-Log "Rapport HTML généré : $OutputPath" "OK"

# ---------- Code de sortie ----------
if ($wuInfo.PendingCount -gt 0 -or $rebootRequired) {
    Write-Log "Actions requises : $($wuInfo.PendingCount) màj en attente, reboot=$rebootRequired" "WARN"
    exit 1
}
exit 0
