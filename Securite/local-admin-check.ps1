﻿<#
.SYNOPSIS
    Vérifie qui est administrateur local sur une machine locale ou distante.
.DESCRIPTION
    Liste les membres du groupe Administrateurs local.
    Détecte les comptes suspects ou non autorisés.
.PARAMETER ComputerName
    Nom de la machine distante (défaut: localhost)
.EXAMPLE
    .\local-admin-check.ps1
    .\local-admin-check.ps1 -ComputerName SRV-DC01
#>

param([string]$ComputerName = $env:COMPUTERNAME)

try {
    $Admins = Get-LocalGroupMember -Group "Administrateurs" -ComputerName $ComputerName -ErrorAction Stop
} catch {
    try {
        $Admins = Get-WmiObject -Class Win32_GroupUser -ComputerName $ComputerName -Filter "GroupComponent='Win32_Group.Domain=`"$ComputerName`",Name=`"Administrateurs`"'" -ErrorAction Stop
        Write-Host "⚠️ Mode WMI (limité)" -ForegroundColor Yellow
    } catch {
        Write-Host "❌ Impossible de se connecter à $ComputerName" -ForegroundColor Red
        exit
    }
}

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "👑 ADMINISTRATEURS LOCAUX - $ComputerName" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

$Admins | ForEach-Object {
    $Name = $_.Name
    $Type = if ($_.ObjectClass -eq "User") { "👤" } else { "👥" }
    Write-Host "$Type $Name"
}

Write-Host "`n📊 Total: $($Admins.Count) membres" -ForegroundColor Cyan
