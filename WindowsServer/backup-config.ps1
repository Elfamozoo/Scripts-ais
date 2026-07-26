﻿<#
.SYNOPSIS
    Sauvegarde des configurations DHCP, DNS et IIS vers un dossier d'archive.
.DESCRIPTION
    Script d'export des configurations critiques Windows Server : 
      - DHCP : Export Netsh du scope et des réservations
      - DNS : Export des zones et enregistrements via dnscmd /export
      - IIS : Export des sites, application pools et configuration via appcmd
    Archive le tout dans un dossier horodaté avec rotation configurable.
.PARAMETER ComputerName
    Serveur cible (par défaut : localhost).
.PARAMETER BackupRoot
    Dossier racine de sauvegarde (défaut : C:\Backups\Config).
.PARAMETER IncludeDHCP
    Inclure la config DHCP (défaut : $true). Nécessite rôle DHCP.
.PARAMETER IncludeDNS
    Inclure la config DNS (défaut : $true). Nécessite rôle DNS.
.PARAMETER IncludeIIS
    Inclure la config IIS (défaut : $true). Nécessite rôle IIS.
.PARAMETER RetentionDays
    Nombre de jours de conservation des backups (défaut : 30).
.PARAMETER Compress
    Compresser l'archive en ZIP via Compress-Archive (défaut : $true).
.PARAMETER OutputPath
    Chemin du rapport HTML (défaut : ./backup-config-report.html).
.EXAMPLE
    .\backup-config.ps1
    .\backup-config.ps1 -ComputerName SRV-DC-01 -BackupRoot D:\Backups
    .\backup-config.ps1 -IncludeDHCP $true -IncludeDNS $true -IncludeIIS $false
.NOTES
    Auteur: Scripts-ais
    Version: 1.0
    Requiert: Droits administrateur sur le serveur cible.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory=$false)]
    [string]$BackupRoot = "C:\Backups\Config",

    [Parameter(Mandatory=$false)]
    [bool]$IncludeDHCP = $true,

    [Parameter(Mandatory=$false)]
    [bool]$IncludeDNS = $true,

    [Parameter(Mandatory=$false)]
    [bool]$IncludeIIS = $true,

    [Parameter(Mandatory=$false)]
    [int]$RetentionDays = 30,

    [Parameter(Mandatory=$false)]
    [bool]$Compress = $true,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\backup-config-report.html"
)

# ---------- Fonctions ----------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function New-BackupDirectory {
    param([string]$Root, [string]$Server)
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $path = Join-Path $Root "$Server-$timestamp"
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Write-Log "Dossier de backup créé : $path" "INFO"
    return $path
}

function Invoke-RemoteCommand {
    param([string]$Computer, [scriptblock]$ScriptBlock)
    try {
        $result = Invoke-Command -ComputerName $Computer -ScriptBlock $ScriptBlock -ErrorAction Stop
        return $result
    } catch {
        Write-Log "Échec commande distante sur $Computer : $_" "ERROR"
        return $null
    }
}

function Backup-DHCP {
    param([string]$BackupDir, [string]$Server)
    Write-Log "--- Sauvegarde DHCP ---" "INFO"
    $dhcpDir = Join-Path $BackupDir "DHCP"
    New-Item -ItemType Directory -Path $dhcpDir -Force | Out-Null

    # 1. Export Netsh complet
    $netshFile = Join-Path $dhcpDir "dhcp-scopes.txt"
    try {
        if ($Server -eq $env:COMPUTERNAME) {
            netsh dhcp server export $netshFile all 2>&1 | Out-Null
        } else {
            netsh dhcp server \\$Server export $netshFile all 2>&1 | Out-Null
        }
        if (Test-Path $netshFile) {
            Write-Log "  Export DHCP Netsh : OK ($((Get-Item $netshFile).Length / 1KB) Ko)" "OK"
        } else {
            Write-Log "  Export DHCP Netsh : aucun fichier produit (rôle non installé ?)" "WARN"
        }
    } catch {
        Write-Log "  Export DHCP Netsh : $_" "WARN"
    }

    # 2. Liste des serveurs DHCP et scopes via PowerShell
    $scopeFile = Join-Path $dhcpDir "dhcp-scopes.csv"
    try {
        $dhcpServers = Get-DhcpServerInDC -ErrorAction SilentlyContinue
        if ($dhcpServers) {
            $allScopes = @()
            foreach ($dhcpSrv in $dhcpServers) {
                $scopes = Get-DhcpServerv4Scope -ComputerName $dhcpSrv.DnsName -ErrorAction SilentlyContinue
                foreach ($scope in $scopes) {
                    $allScopes += [PSCustomObject]@{
                        Server      = $dhcpSrv.DnsName
                        ScopeId     = $scope.ScopeId
                        Name        = $scope.Name
                        SubnetMask  = $scope.SubnetMask
                        StartRange  = $scope.StartRange
                        EndRange    = $scope.EndRange
                        State       = $scope.State
                        LeaseDuration = $scope.LeaseDuration
                    }
                }
            }
            if ($allScopes.Count -gt 0) {
                $allScopes | Export-Csv -Path $scopeFile -NoTypeInformation -Encoding utf8
                Write-Log "  $($allScopes.Count) scopes DHCP exportés" "OK"
            }
        } else {
            Write-Log "  Aucun serveur DHCP trouvé dans le domaine" "WARN"
        }
    } catch {
        Write-Log "  Export scopes DHCP impossible : $_" "WARN"
    }

    return $dhcpDir
}

function Backup-DNS {
    param([string]$BackupDir, [string]$Server)
    Write-Log "--- Sauvegarde DNS ---" "INFO"
    $dnsDir = Join-Path $BackupDir "DNS"
    New-Item -ItemType Directory -Path $dnsDir -Force | Out-Null

    # 1. Export des zones via dnscmd
    $zoneFile = Join-Path $dnsDir "dns-zones.txt"
    try {
        if ($Server -eq $env:COMPUTERNAME) {
            $zones = dnscmd /EnumZones 2>&1
        } else {
            $zones = dnscmd $Server /EnumZones 2>&1
        }
        $zones | Out-File -FilePath $zoneFile -Encoding utf8
        Write-Log "  Liste des zones DNS : OK" "OK"
    } catch {
        Write-Log "  Enumération zones DNS : $_" "WARN"
    }

    # 2. Export détaillé de chaque zone
    $zoneDetailDir = Join-Path $dnsDir "Zones"
    New-Item -ItemType Directory -Path $zoneDetailDir -Force | Out-Null
    try {
        $dnsZones = Get-DnsServerZone -ComputerName $Server -ErrorAction SilentlyContinue
        foreach ($zone in $dnsZones) {
            $zoneName = $zone.ZoneName -replace '\.', '_'
            $zoneFile = Join-Path $zoneDetailDir "zone-$zoneName.csv"
            try {
                $records = Get-DnsServerResourceRecord -ZoneName $zone.ZoneName -ComputerName $Server -ErrorAction SilentlyContinue
                if ($records) {
                    $records | Select-Object HostName, RecordType, RecordData, Timestamp, TimeToLive |
                               Export-Csv -Path $zoneFile -NoTypeInformation -Encoding utf8
                    Write-Log "  Zone $($zone.ZoneName) : $($records.Count) enregistrements" "OK"
                }
            } catch {
                Write-Log "  Zone $($zone.ZoneName) : impossible à exporter" "WARN"
            }
        }
    } catch {
        Write-Log "  Export zones DNS impossible : $_" "WARN"
    }

    # 3. Paramètres DNS serveur
    $settingsFile = Join-Path $dnsDir "dns-settings.csv"
    try {
        $settings = Get-DnsServerSetting -ComputerName $Server -ErrorAction SilentlyContinue -All
        if ($settings) {
            $settings | ConvertTo-Csv -NoTypeInformation | Out-File -FilePath $settingsFile -Encoding utf8
            Write-Log "  Paramètres DNS exportés" "OK"
        }
    } catch {
        Write-Log "  Export paramètres DNS : $_" "WARN"
    }

    return $dnsDir
}

function Backup-IIS {
    param([string]$BackupDir, [string]$Server)
    Write-Log "--- Sauvegarde IIS ---" "INFO"
    $iisDir = Join-Path $BackupDir "IIS"
    New-Item -ItemType Directory -Path $iisDir -Force | Out-Null

    # 1. Export AppCmd (sites + pools)
    $appCmdFile = Join-Path $iisDir "iis-appcmd.xml"
    try {
        $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"
        if ($Server -eq $env:COMPUTENAM) {
            & $appcmd list site /config /xml > $appCmdFile 2>&1
        } else {
            # Version distante : utilisation de Invoke-Command
            $xmlContent = Invoke-Command -ComputerName $Server -ScriptBlock {
                & "$env:windir\system32\inetsrv\appcmd.exe" list site /config /xml
            } -ErrorAction SilentlyContinue
            if ($xmlContent) { $xmlContent | Out-File -FilePath $appCmdFile -Encoding utf8 }
        }
        if (Test-Path $appCmdFile) {
            Write-Log "  Export AppCmd sites : $((Get-Item $appCmdFile).Length / 1KB) Ko" "OK"
        }
    } catch {
        Write-Log "  Export AppCmd sites : $_" "WARN"
    }

    # Application Pools
    $poolsFile = Join-Path $iisDir "iis-apppools.csv"
    try {
        $pools = Invoke-Command -ComputerName $Server -ScriptBlock {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            Get-ChildItem IIS:\AppPools | Select-Object Name, State, @{N='ManagedPipelineMode';E={$_.managedPipelineMode}}, 
                @{N='ManagedRuntimeVersion';E={$_.managedRuntimeVersion}}, @{N='ProcessModel.IdentityType';E={$_.processModel.identityType}},
                @{N='Recycling.PeriodicRestartTime';E={$_.recycling.periodicRestart.time}}
        } -ErrorAction SilentlyContinue
        if ($pools) {
            $pools | Export-Csv -Path $poolsFile -NoTypeInformation -Encoding utf8
            Write-Log "  $($pools.Count) application pools exportés" "OK"
        }
    } catch {
        Write-Log "  Export Application Pools : $_" "WARN"
    }

    # Sites IIS
    $sitesFile = Join-Path $iisDir "iis-sites.csv"
    try {
        $sites = Invoke-Command -ComputerName $Server -ScriptBlock {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            Get-ChildItem IIS:\Sites | Select-Object Name, State, ID, PhysicalPath, Bindings
        } -ErrorAction SilentlyContinue
        if ($sites) {
            $sites | Export-Csv -Path $sitesFile -NoTypeInformation -Encoding utf8
            Write-Log "  $($sites.Count) sites IIS exportés" "OK"
        }
    } catch {
        Write-Log "  Export sites IIS : $_" "WARN"
    }

    # Certificats liés aux bindings HTTPS
    $certsFile = Join-Path $iisDir "iis-ssl-certificates.csv"
    try {
        $certs = Invoke-Command -ComputerName $Server -ScriptBlock {
            Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.NotAfter -gt (Get-Date) } |
                Select-Object Subject, Thumbprint, NotAfter, @{N='FriendlyName';E={$_.FriendlyName}},
                @{N='SerialNumber';E={$_.SerialNumber}}, @{N='Issuer';E={$_.Issuer}}
        } -ErrorAction SilentlyContinue
        if ($certs) {
            $certs | Export-Csv -Path $certsFile -NoTypeInformation -Encoding utf8
            Write-Log "  $($certs.Count) certificats SSL exportés" "OK"
        }
    } catch {
        Write-Log "  Export certificats SSL : $_" "WARN"
    }

    return $iisDir
}

function Remove-OldBackups {
    param([string]$Root, [int]$Days)
    Write-Log "--- Nettoyage des backups de plus de $Days jours ---" "INFO"
    $cutoff = (Get-Date).AddDays(-$Days)
    $oldItems = Get-ChildItem -Path $Root -Directory | Where-Object { $_.CreationTime -lt $cutoff }
    foreach ($old in $oldItems) {
        try {
            Remove-Item -Path $old.FullName -Recurse -Force -ErrorAction Stop
            Write-Log "  Supprimé : $($old.Name)" "OK"
        } catch {
            Write-Log "  Échec suppression $($old.Name) : $_" "WARN"
        }
    }
    Write-Log "  Nettoyage terminé : $($oldItems.Count) dossier(s) supprimé(s)" "INFO"
}

# ---------- Exécution principale ----------
Write-Log "=== Sauvegarde des configurations serveur : $ComputerName ===" "INFO"

# Création du dossier de backup
try {
    $backupDir = New-BackupDirectory -Root $BackupRoot -Server $ComputerName
} catch {
    Write-Log "Impossible de créer le dossier de backup : $_" "ERROR"
    exit 1
}
$results = @()

# DHCP
if ($IncludeDHCP) {
    $dhcpDir = Backup-DHCP -BackupDir $backupDir -Server $ComputerName
    $dhcpFiles = if (Test-Path $dhcpDir) { (Get-ChildItem -Path $dhcpDir -Recurse -File | Measure-Object).Count } else { 0 }
    $results += [PSCustomObject]@{ Composant = "DHCP"; Statut = if ($dhcpFiles -gt 0) { "OK" } else { "Aucun fichier" }; Fichiers = $dhcpFiles }
} else {
    $results += [PSCustomObject]@{ Composant = "DHCP"; Statut = "Ignoré"; Fichiers = 0 }
}

# DNS
if ($IncludeDNS) {
    $dnsDir = Backup-DNS -BackupDir $backupDir -Server $ComputerName
    $dnsFiles = if (Test-Path $dnsDir) { (Get-ChildItem -Path $dnsDir -Recurse -File | Measure-Object).Count } else { 0 }
    $results += [PSCustomObject]@{ Composant = "DNS"; Statut = if ($dnsFiles -gt 0) { "OK" } else { "Aucun fichier" }; Fichiers = $dnsFiles }
} else {
    $results += [PSCustomObject]@{ Composant = "DNS"; Statut = "Ignoré"; Fichiers = 0 }
}

# IIS
if ($IncludeIIS) {
    $iisDir = Backup-IIS -BackupDir $backupDir -Server $ComputerName
    $iisFiles = if (Test-Path $iisDir) { (Get-ChildItem -Path $iisDir -Recurse -File | Measure-Object).Count } else { 0 }
    $results += [PSCustomObject]@{ Composant = "IIS"; Statut = if ($iisFiles -gt 0) { "OK" } else { "Aucun fichier" }; Fichiers = $iisFiles }
} else {
    $results += [PSCustomObject]@{ Composant = "IIS"; Statut = "Ignoré"; Fichiers = 0 }
}

# Compression ZIP
$reportSize = "N/A"
if ($Compress) {
    $zipPath = "$backupDir.zip"
    try {
        Compress-Archive -Path $backupDir -DestinationPath $zipPath -Force
        $zipInfo = Get-Item $zipPath
        $reportSize = "$([math]::Round($zipInfo.Length / 1MB, 2)) Mo"
        Write-Log "Archive ZIP créée : $zipPath ($reportSize)" "OK"
    } catch {
        Write-Log "Échec compression ZIP : $_" "WARN"
    }
}

# Nettoyage des anciens backups
Remove-OldBackups -Root $BackupRoot -Days $RetentionDays

# ---------- Rapport HTML ----------
$totalFiles = ($results | Where-Object { $_.Statut -eq "OK" } | Measure-Object -Property Fichiers -Sum).Sum
if (-not $totalFiles) { $totalFiles = 0 }
$okCount = ($results | Where-Object { $_.Statut -eq "OK" } | Measure-Object).Count

$htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Rapport Backup Configuration - $ComputerName</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #f5f5f5; }
        h1 { color: #333; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #555; margin-top: 25px; }
        table { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        th { background: #0078d4; color: #fff; padding: 8px; text-align: left; }
        td { padding: 6px 8px; border-bottom: 1px solid #ddd; }
        tr:hover { background: #f0f0f0; }
        .ok { background: #d4edda; }
        .summary-box { padding: 15px; border-radius: 5px; margin: 20px 0; }
        .summary-ok { background: #d4edda; border: 1px solid #c3e6cb; }
        .summary-warn { background: #fff3cd; border: 1px solid #ffeeba; }
        .footer { margin-top: 20px; color: #666; font-size: 0.9em; }
        code { background: #e8e8e8; padding: 2px 5px; border-radius: 3px; }
    </style>
</head>
<body>
    <h1>Rapport Backup Configuration</h1>
    <p><strong>Serveur :</strong> $ComputerName</p>
    <p><strong>Généré le :</strong> $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")</p>
    <p><strong>Dossier de backup :</strong> $backupDir</p>
"@

$summaryClass = if ($totalFiles -gt 0) { "summary-ok" } else { "summary-warn" }
$htmlBody = @"
    <div class="summary-box $summaryClass">
        <strong>Résumé :</strong> $okCount composant(s) sauvegardé(s), $totalFiles fichier(s), taille archive : $reportSize
    </div>
    <h2>Détail par composant</h2>
    <table>
        <tr><th>Composant</th><th>Statut</th><th>Fichiers</th></tr>
"@
foreach ($r in $results) {
    $rowClass = if ($r.Statut -eq "OK") { "ok" } else { "" }
    $htmlBody += "<tr class='$rowClass'><td>$($r.Composant)</td><td>$($r.Statut)</td><td>$($r.Fichiers)</td></tr>"
}

$htmlBody += @"
    </table>
    <h2>Arborescence sauvegardée</h2>
    <pre>$(Get-ChildItem -Path $backupDir -Recurse | Where-Object { $_.PSIsContainer } | ForEach-Object { $_.FullName.Replace($backupDir, '') } | Out-String)</pre>
    <h2>Rétention</h2>
    <p>Les backups de plus de $RetentionDays jours sont automatiquement supprimés.</p>
"@

$htmlFooter = @"
    <div class="footer">
        <p>Script backup-config.ps1 - Intervalle recommandé : quotidien</p>
    </div>
</body>
</html>
"@

$html = $htmlHeader + $htmlBody + $htmlFooter
$html | Out-File -FilePath $OutputPath -Encoding utf8
Write-Log "Rapport HTML généré : $OutputPath" "OK"

Write-Log "=== Sauvegarde terminée avec succès === " "OK"
exit 0
