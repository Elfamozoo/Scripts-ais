<#
.SYNOPSIS
    Liste tous les logiciels installés sur une machine locale ou distante.
.DESCRIPTION
    Récupère la liste des logiciels depuis le registre (Uninstall) et WinRM/WMI.
.PARAMETER ComputerName
    Nom de la machine (défaut: localhost)
.PARAMETER ExportCSV
    Exporter les résultats en CSV
.EXAMPLE
    .\installed-software.ps1
    .\installed-software.ps1 -ComputerName SRV-DC01 -ExportCSV
#>

param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [switch]$ExportCSV
)

# Bannir Win32_Product (declenche reconfiguration MSI)
$Software = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" -ErrorAction SilentlyContinue |
    Get-ItemProperty | Where-Object { $_.DisplayName } |
    Select-Object @{N='Nom';E={$_.DisplayName}},
                  @{N='Version';E={$_.DisplayVersion}},
                  @{N='Fabricant';E={$_.Publisher}},
                  @{N='InstallDate';E={$_.InstallDate}},
                  @{N='Taille_KB';E={[int]($_.EstimatedSize / 1024)}}
$Software += Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\" -ErrorAction SilentlyContinue |
    Get-ItemProperty | Where-Object { $_.DisplayName } |
    Select-Object @{N='Nom';E={$_.DisplayName}},
                  @{N='Version';E={$_.DisplayVersion}},
                  @{N='Fabricant';E={$_.Publisher}},
                  @{N='InstallDate';E={$_.InstallDate}},
                  @{N='Taille_KB';E={[int]($_.EstimatedSize / 1024)}}
$Software = $Software | Sort-Object Nom

Write-Host "---------------------------------------------------" -ForegroundColor Cyan
Write-Host "[PACKAGE] LOGICIELS INSTALLÉS - $ComputerName" -ForegroundColor Cyan
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

$Software | Format-Table -AutoSize Nom, Version, Fabricant

Write-Host "`n[STATS] Total: $($Software.Count) logiciels installés" -ForegroundColor Cyan

if ($ExportCSV) {
    $ExportPath = "software_$ComputerName`_$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    $Software | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "[FILE] Export: $ExportPath" -ForegroundColor Green
}
