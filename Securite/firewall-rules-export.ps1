﻿<#
.SYNOPSIS
    Exporte toutes les règles du pare-feu Windows au format CSV.
.DESCRIPTION
    Liste toutes les règles du pare-feu avec leur nom, action, protocole, ports, profils.
.PARAMETER FilePath
    Chemin du fichier CSV de sortie.
.EXAMPLE
    .\firewall-rules-export.ps1
    .\firewall-rules-export.ps1 -FilePath "C:\temp\firewall.csv"
#>

param([string]$FilePath = "firewall-rules_$(Get-Date -Format 'yyyyMMdd-HHmmss').csv")

$Rules = Get-NetFirewallRule | Where-Object Enabled -eq $true | ForEach-Object {
    $PortFilter = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    $AddressFilter = $_ | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        Nom = $_.DisplayName
        Action = $_.Action
        Direction = $_.Direction
        Protocole = $PortFilter.Protocol
        PortLocal = $PortFilter.LocalPort
        PortDistant = $PortFilter.RemotePort
        IPLocale = $AddressFilter.LocalAddress
        IPDistante = $AddressFilter.RemoteAddress
        Profil = $_.Profile
        Groupe = $_.Group
    }
} | Sort-Object Nom

$Rules | Export-Csv -Path $FilePath -NoTypeInformation -Encoding UTF8

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🛡️ RÈGLES PARE-FEU ACTIVES" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

$In = ($Rules | Where-Object Direction -eq 'Inbound').Count
$Out = ($Rules | Where-Object Direction -eq 'Outbound').Count
$Allow = ($Rules | Where-Object Action -eq 'Allow').Count
$Block = ($Rules | Where-Object Action -eq 'Block').Count

Write-Host "📊 $($Rules.Count) règles actives"
Write-Host "   ↳ Entrant: $In  |  Sortant: $Out"
Write-Host "   ↳ Autoriser: $Allow  |  Bloquer: $Block"
Write-Host "📁 Export: $FilePath" -ForegroundColor Green
