<#
.SYNOPSIS
    Liste l'historique des périphériques USB branchés sur la machine.
.DESCRIPTION
    Extrait les événements 2003 (connexion USB) des logs système.
    Affiche la date, le périphérique, le fabricant et le numéro de série.
.PARAMETER Days
    Nombre de jours à analyser (défaut: 30)
.EXAMPLE
    .\usb-history.ps1 -Days 7
#>

param([int]$Days = 30)

$TimeFilter = (Get-Date).AddDays(-$Days)
$Events = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Kernel-PnP/Configuration'; ID=2003; StartTime=$TimeFilter} -ErrorAction SilentlyContinue

if (-not $Events) {
    # Fallback sur le log System
    $Events = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-PnP'; ID=2003; StartTime=$TimeFilter} -ErrorAction SilentlyContinue
}

if (-not $Events) {
    Write-Host "[WARN] Aucun historique USB trouvé (pas de logs ou pas de périphériques récents)" -ForegroundColor Yellow
    exit
}

$USBDevices = $Events | Select-Object TimeCreated,
    @{N='Périphérique';E={$_.Properties[0].Value}},
    @{N='Description';E={$_.Properties[1].Value}} |
    Sort-Object TimeCreated -Descending

Write-Host "---------------------------------------------------" -ForegroundColor Cyan
Write-Host "[PLUG] HISTORIQUE DES PÉRIPHÉRIQUES USB ($Days jours)" -ForegroundColor Cyan
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

$USBDevices | ForEach-Object {
    Write-Host "$($_.TimeCreated.ToString('dd/MM/yyyy HH:mm')) | $($_.Périphérique) - $($_.Description)"
}

Write-Host "`n[STATS] Total: $($USBDevices.Count) connexions USB détectées" -ForegroundColor Cyan

# Export CSV
$ExportPath = "usb-history_$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$USBDevices | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Host "[FILE] Export: $ExportPath" -ForegroundColor Green
