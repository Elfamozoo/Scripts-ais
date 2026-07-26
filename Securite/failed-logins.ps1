<#
.SYNOPSIS
    Analyse les tentatives de connexion échouées depuis les logs de sécurité Windows.
.DESCRIPTION
    Extrait les événements 4625 (échec connexion) des dernières 24h.
    Affiche l'IP source, le nom d'utilisateur ciblé, le nombre de tentatives.
.PARAMETER Hours
    Nombre d'heures à analyser (défaut: 24)
.PARAMETER Threshold
    Seuil d'alertes (défaut: 5 tentatives)
.EXEMPLE
    .\failed-logins.ps1 -Hours 48 -Threshold 10
#>

param(
    [int]$Hours = 24,
    [int]$Threshold = 5
)

$TimeFilter = (Get-Date).AddHours(-$Hours)
$Events = Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4625; StartTime=$TimeFilter} -ErrorAction SilentlyContinue

if (-not $Events) {
    Write-Host "✅ Aucune tentative échouée trouvée dans les dernières $Hours heures." -ForegroundColor Green
    exit
}

$FailedLogins = $Events | Group-Object @{Expression={$_.Properties[5].Value}}, @{Expression={$_.Properties[18].Value}} |
    Select-Object @{N='Utilisateur';E={$_.Values[0]}},
                  @{N='IP_Source';E={$_.Values[1]}},
                  @{N='Tentatives';E={$_.Count}},
                  @{N='PremierEssai';E={($_.Group | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated}},
                  @{N='DernierEssai';E={($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated}} |
    Sort-Object Tentatives -Descending

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🔒 TENTATIVES DE CONNEXION ÉCHOUÉES" -ForegroundColor Cyan
Write-Host "Période: $Hours h  |  Seuil alerte: $Threshold tentatives" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

$FailedLogins | ForEach-Object {
    $Color = if ($_.Tentatives -ge $Threshold) { "Red" } else { "Yellow" }
    Write-Host "[$($_.Tentatives)x] $($_.Utilisateur) → $($_.IP_Source)" -ForegroundColor $Color
}

$TotalIPs = ($FailedLogins | Select-Object IP_Source -Unique).Count
$TotalUsers = ($FailedLogins | Select-Object Utilisateur -Unique).Count
Write-Host "`n📊 Résumé: $($FailedLogins.Count) tentatives, $TotalIPs IPs différentes, $TotalUsers utilisateurs ciblés" -ForegroundColor Cyan

# Export CSV
$ExportPath = "failed-logins_$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$FailedLogins | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Host "📁 Export: $ExportPath" -ForegroundColor Green
