<#
.SYNOPSIS
    Inventaire complet d'une machine (CPU, RAM, disques, OS, IP, MAC).
.DESCRIPTION
    Récupère toutes les informations matérielles et logicielles d'une machine
    locale ou distante via WMI/CIM. Exporte en CSV.
.PARAMETER ComputerName
    Nom de la machine (défaut: localhost)
.PARAMETER Credential
    Credentials pour machine distante
.EXEMPLE
    .\machine-inventory.ps1
    .\machine-inventory.ps1 -ComputerName SRV-DC01
#>

param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [PSCredential]$Credential = $null
)

$Params = @{ComputerName=$ComputerName; ErrorAction='SilentlyContinue'}
if ($Credential) { $Params.Credential = $Credential }

try {
    $CS = Get-CimInstance Win32_ComputerSystem @Params
    $OS = Get-CimInstance Win32_OperatingSystem @Params
    $CPU = Get-CimInstance Win32_Processor @Params | Select-Object -First 1
    $RAM = [math]::Round($CS.TotalPhysicalMemory / 1GB, 2)
    $Disks = Get-CimInstance Win32_LogicalDisk @Params | Where-Object DriveType -eq 3
    $Networks = Get-CimInstance Win32_NetworkAdapterConfiguration @Params | Where-Object IPEnabled -eq $true

    $Inventory = [PSCustomObject]@{
        NomMachine = $CS.Name
        Fabricant = $CS.Manufacturer
        Modele = $CS.Model
        OS = $OS.Caption
        VersionOS = $OS.Version
        Architecture = $OS.OSArchitecture
        CPU = $CPU.Name
        Coeurs = $CPU.NumberOfCores
        Threads = $CPU.NumberOfLogicalProcessors
        RAM_Go = $RAM
        Disques = ($Disks | ForEach-Object {"$($_.DeviceID) $([math]::Round($_.Size/1GB,2))Go ($([math]::Round($_.FreeSpace/1GB,2))Go libre)"}) -join ' | '
        IP = ($Networks.IPAddress -join ', ')
        MAC = ($Networks.MACAddress -join ', ')
        DernierDemarrage = $OS.LastBootUpTime
        UptimeJours = [math]::Round(((Get-Date) - $OS.LastBootUpTime).TotalDays, 1)
    }

    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "💻 INVENTAIRE - $ComputerName" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    $Inventory | Format-List

    # Export
    $ExportPath = "inventory_$ComputerName`_$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    $Inventory | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "📁 Export: $ExportPath" -ForegroundColor Green

} catch {
    Write-Host "❌ Erreur de connexion à $ComputerName" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
}
