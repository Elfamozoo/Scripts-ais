﻿<#
.SYNOPSIS
    Détecte les attaques brute-force RDP.
.DESCRIPTION
    Analyse les événements 4625 (échec) et 4624 (succès) du service Terminal Services.
    Identifie les IPs suspectes avec +X tentatives échouées.
.PARAMETER Threshold
    Seuil de tentatives échouées pour alerte (défaut: 10)
.PARAMETER Hours
    Période d'analyse en heures (défaut: 24)
.EXAMPLE
    .\rdp-brute-check.ps1
    .\rdp-brute-check.ps1 -Threshold 5 -Hours 48
#>

param(
    [int]$Threshold = 10,
    [int]$Hours = 24
)

$TimeFilter = (Get-Date).AddHours(-$Hours)

# Échecs RDP (4625, logon type 10 = RemoteInteractive)
$FailedRDP = Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4625; StartTime=$TimeFilter} -ErrorAction SilentlyContinue |
    Where-Object { $_.Properties[8].Value -eq 10 }

# Succès RDP (4624, logon type 10)
$SuccessRDP = Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4624; StartTime=$TimeFilter} -ErrorAction SilentlyContinue |
    Where-Object { $_.Properties[8].Value -eq 10 }

$FailedByIP = $FailedRDP | Group-Object @{Expression={$_.Properties[18].Value}} |
    Select-Object @{N='IP_Source';E={$_.Name}}, @{N='Tentatives';E={$_.Count}},
                  @{N='PremierEssai';E={($_.Group | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated}},
                  @{N='DernierEssai';E={($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated}} |
    Where-Object Tentatives -ge $Threshold | Sort-Object Tentatives -Descending

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red
Write-Host "🚨 DÉTECTION BRUTE-FORCE RDP" -ForegroundColor Red
Write-Host "Période: $Hours h  |  Seuil: $Threshold tentatives"
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red

if ($FailedByIP) {
    $FailedByIP | ForEach-Object {
        $Level = if ($_.Tentatives -ge 50) { "🔴 CRITIQUE" } elseif ($_.Tentatives -ge 20) { "🟠 ÉLEVÉ" } else { "🟡 MOYEN" }
        Write-Host "$Level | $($_.Tentatives)x tentatives de $($_.IP_Source)" -ForegroundColor Red
        Write-Host "        ↳ $($_.PremierEssai.ToString('dd/MM HH:mm')) → $($_.DernierEssai.ToString('dd/MM HH:mm'))"
    }

    # Suggestion blocage
    Write-Host "`n🔒 Suggestion: bloquer ces IPs avec:" -ForegroundColor Yellow
    $FailedByIP | ForEach-Object {
        Write-Host "   netsh advfirewall firewall add rule name='BLOCK_RDP_$($_.IP_Source)' dir=in action=block protocol=TCP localport=3389 remoteip=$($_.IP_Source)" -ForegroundColor Gray
    }
} else {
    Write-Host "✅ Aucune attaque brute-force détectée" -ForegroundColor Green
}

$SuccessCount = ($SuccessRDP | Select-Object @{N='IP';E={$_.Properties[18].Value}} -Unique).Count
Write-Host "`n📊 Connexions RDP réussies: $($SuccessRDP.Count) depuis $SuccessCount IPs différentes" -ForegroundColor Cyan
