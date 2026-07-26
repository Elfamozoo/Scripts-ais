<#
.SYNOPSIS
    Vérifie l'uptime des serveurs (local ou liste depuis un fichier).
.DESCRIPTION
    Interroge une ou plusieurs machines pour connaître leur temps de fonctionnement.
    Idéal pour savoir quels serveurs ont besoin d'un redémarrage.
.PARAMETER ComputerName
    Nom de la machine ou chemin d'un fichier texte avec une machine par ligne
.PARAMETER MinUptimeDays
    Afficher uniquement les machines avec uptime < X jours (défaut: 0 = toutes)
.EXAMPLE
    .\uptime-report.ps1
    .\uptime-report.ps1 -ComputerName "SRV-DC01","SRV-EXCH01"
    .\uptime-report.ps1 -ComputerName "C:\servers.txt" -MinUptimeDays 7
#>

param(
    [string[]]$ComputerName,
    [int]$MinUptimeDays = 0
)

if (-not $ComputerName) {
    $ComputerName = @($env:COMPUTERNAME)
} elseif ($ComputerName.Count -eq 1 -and (Test-Path $ComputerName[0])) {
    $ComputerName = Get-Content $ComputerName[0]
}

$Results = foreach ($Computer in $ComputerName) {
    try {
        $OS = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $Computer -ErrorAction Stop
        $Uptime = (Get-Date) - $OS.LastBootUpTime
        $Days = [math]::Round($Uptime.TotalDays, 1)
        $RebootPending = $OS.RebootPending

        if ($MinUptimeDays -eq 0 -or $Days -lt $MinUptimeDays) {
            [PSCustomObject]@{
                Serveur = $Computer
                UptimeJours = $Days
                UptimeFormate = "$($Uptime.Days)j $($Uptime.Hours)h $($Uptime.Minutes)m"
                Demarrage = $OS.LastBootUpTime
                OS = $OS.Caption
                Status = if ($RebootPending -or $Days -gt 30) { "[WARN] Redémarrage recommandé" } else { "[OK] OK" }
            }
        }
    } catch {
        [PSCustomObject]@{
            Serveur = $Computer
            UptimeJours = $null
            UptimeFormate = "[ERR] INJOIGNABLE"
            Demarrage = $null
            OS = $null
            Status = "[ERR] Erreur de connexion"
        }
    }
}

Write-Host "---------------------------------------------------" -ForegroundColor Cyan
Write-Host "[TIMER] RAPPORT UPTIME DES SERVEURS" -ForegroundColor Cyan
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

$Results | ForEach-Object {
    $Color = if ($_.UptimeJours -gt 30 -or $_.Status -like "*Redémarrage*") { "Yellow" } elseif ($_.Status -like "*Erreur*") { "Red" } else { "Green" }
    Write-Host "$($_.Serveur.PadRight(20)) | $($_.UptimeFormate.PadRight(20)) | $($_.Status)" -ForegroundColor $Color
}

Write-Host "`n[STATS] $($Results.Count) serveurs interrogés" -ForegroundColor Cyan
