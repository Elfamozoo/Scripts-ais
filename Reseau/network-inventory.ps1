<#
.SYNOPSIS
    Inventaire réseau complet : IP, MAC, hostname et détails des interfaces.
.DESCRIPTION
    Scanne le réseau local et collecte les informations des machines :
    adresse IP, adresse MAC, fabricant OUI, hostname, statut DHCP,
    interface réseau, et état de la connexion.
.PARAMETER IncludeLocal
    Inclure les infos de la machine locale (défaut: $true)
.PARAMETER ScanSubnet
    Effectuer un ping sweep pour découvrir les machines actives (défaut: $false)
.PARAMETER Subnet
    Sous-réseau pour le scan (ex: 192.168.1)
.PARAMETER ExportCSV
    Chemin du fichier CSV d'export (optionnel)
.PARAMETER ExportHTML
    Chemin du fichier HTML pour un rapport visuel (optionnel)
.EXAMPLE
    .\network-inventory.ps1
    .\network-inventory.ps1 -ScanSubnet -Subnet "192.168.1" -ExportCSV "inventory.csv" -ExportHTML "report.html"
#>

param(
    [bool]$IncludeLocal = $true,

    [bool]$ScanSubnet = $false,

    [string]$Subnet = "",

    [string]$ExportCSV = "",

    [string]$ExportHTML = ""
)

function Get-OuiVendor {
    param([string]$Mac)
    # Table OUI simplifiée des fabricants courants
    $ouis = @{
        "00037F" = "Cisco"
        "000C29" = "VMware"
        "005056" = "VMware"
        "000569" = "VMware"
        "001C14" = "Intel"
        "00155D" = "Hyper-V"
        "0003FF" = "Microsoft"
        "08002B" = "DEC"
        "0050B6" = "3Com"
        "0080C8" = "Xerox"
        "00AA00" = "Intel"
        "00A0C9" = "Intel"
        "0013D4" = "Dell"
        "0018FE" = "Apple"
        "001636" = "Apple"
        "001B63" = "Apple"
        "002332" = "Apple"
        "003065" = "Apple"
        "00C0B6" = "Apple"
        "A8D300" = "Apple"
        "04F938" = "Ubiquiti"
        "001A17" = "Samsung"
        "00A0DE" = "Sony"
        "0050F2" = "HP"
        "0004EA" = "Huawei"
        "00037B" = "Nokia"
        "B0C4DE" = "Raspberry Pi"
        "DCA632" = "Raspberry Pi"
        "E45F01" = "Raspberry Pi"
        "28B2BD" = "Aruba"
        "0050DA" = "Aruba"
        "0024A5" = "TP-Link"
        "14CF92" = "TP-Link"
        "18A6F7" = "TP-Link"
        "4CE1AF" = "Netgear"
        "A021B7" = "Netgear"
        "90F652" = "ASUS"
        "E03F49" = "Synology"
        "001132" = "Synology"
        "001D60" = "QNAP"
        "080027" = "Oracle VM"
        "000C14" = "Oracle"
        "001485" = "Realtek"
    }

    $ouiKey = $Mac -replace "[-:]", ""
    if ($ouiKey.Length -ge 6) {
        $prefix = $ouiKey.Substring(0, 6).ToUpper()
        if ($ouis.ContainsKey($prefix)) {
            return $ouis[$prefix]
        }
    }
    return "Inconnu"
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "         INVENTAIRE RÉSEAU" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

$inventory = @()
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# --- 1. Informations locales ---
if ($IncludeLocal) {
    Write-Host "-- Informations locales ----------------------" -ForegroundColor Yellow

    $hostname = $env:COMPUTERNAME
    Write-Host "Hostname: $hostname" -ForegroundColor Green

    $interfaces = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }

    foreach ($iface in $interfaces) {
        $ipConfig = Get-NetIPAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dns = Get-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $gateway = Get-NetRoute -InterfaceIndex $iface.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue

        $macFormatted = $iface.MacAddress
        $vendor = Get-OuiVendor -Mac $macFormatted

        $entry = [PSCustomObject]@{
            Type         = "Locale"
            IP           = if ($ipConfig) { $ipConfig.IPAddress } else { "N/A" }
            MAC          = $macFormatted
            Fabricant    = $vendor
            Hostname     = $hostname
            Interface    = $iface.Name
            DHCP         = if ($ipConfig -and $ipConfig.PrefixOrigin -eq 'Dhcp') { "Oui" } else { "Non" }
            DNS          = if ($dns) { ($dns.ServerAddresses -join ", ") } else { "N/A" }
            Passerelle   = if ($gateway) { $gateway.NextHop } else { "N/A" }
            Statut       = $iface.Status
        }
        $inventory += $entry

        Write-Host ""
        Write-Host "  Interface : $($iface.Name)" -ForegroundColor White
        Write-Host "    IP       : $($entry.IP)"
        Write-Host "    MAC      : $macFormatted ($vendor)"
        Write-Host "    DHCP     : $($entry.DHCP)"
        Write-Host "    DNS      : $($entry.DNS)"
        Write-Host "    Passerelle: $($entry.Passerelle)"
    }
}

# --- 2. Table ARP (voisins connus) ---
Write-Host ""
Write-Host "-- Table ARP (Voisins réseau) -----------------" -ForegroundColor Yellow

$arpTable = arp -a | Select-String '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+[0-9a-f]{2}[-:][0-9a-f]{2}[-:][0-9a-f]{2}[-:][0-9a-f]{2}[-:][0-9a-f]{2}[-:][0-9a-f]{2}'

$arpCount = 0
foreach ($line in $arpTable) {
    $parts = $line -split '\s+' | Where-Object { $_ -ne '' }
    if ($parts.Count -ge 2) {
        $ip = $parts[0]
        $mac = $parts[1]

        # Exclure broadcast et multicast
        if ($ip -match '\.255$' -or $ip -match '\.0$' -or $mac -match '^ff-|^ff:' -or $mac -match '^00-00-00|^00:00:00') {
            continue
        }

        $arpCount++
        $vendor = Get-OuiVendor -Mac $mac

        # Résoudre le hostname
        try {
            $name = [System.Net.Dns]::GetHostEntry($ip).HostName
        } catch {
            $name = "N/A"
        }

        $entry = [PSCustomObject]@{
            Type         = "ARP"
            IP           = $ip
            MAC          = $mac
            Fabricant    = $vendor
            Hostname     = $name
            Interface    = ""
            DHCP         = ""
            DNS          = ""
            Passerelle   = ""
            Statut       = "Atteignable"
        }
        $inventory += $entry

        Write-Host "  $ip".PadRight(20) "$mac ($vendor)".PadRight(30) "$name"
    }
}

Write-Host "  ($arpCount entrées ARP trouvées)"

# --- 3. Scan optionnel du sous-réseau ---
if ($ScanSubnet -and $Subnet) {
    Write-Host ""
    Write-Host "-- Scan du sous-réseau $Subnet.x -------------" -ForegroundColor Yellow

    $found = 0
    for ($i = 1; $i -le 254; $i++) {
        $ip = "$Subnet.$i"
        $ping = New-Object System.Net.NetworkInformation.Ping
        try {
            $reply = $ping.Send($ip, 100)
            if ($reply.Status -eq 'Success') {
                $found++
                # Vérifier si déjà dans l'inventaire
                $alreadyInInventory = $inventory | Where-Object { $_.IP -eq $ip }
                if (-not $alreadyInInventory) {
                    try {
                        $name = [System.Net.Dns]::GetHostEntry($ip).HostName
                    } catch {
                        $name = "N/A"
                    }

                    # Récupérer MAC via ARP
                    $macAddr = "N/A"
                    $arpLine = arp -a $ip 2>$null
                    if ($arpLine) {
                        $arpParts = $arpLine -split '\s+' | Where-Object { $_ -ne '' }
                        if ($arpParts.Count -ge 2) {
                            $macAddr = $arpParts[1]
                        }
                    }

                    $vendor = Get-OuiVendor -Mac $macAddr
                    $entry = [PSCustomObject]@{
                        Type         = "Scan"
                        IP           = $ip
                        MAC          = $macAddr
                        Fabricant    = $vendor
                        Hostname     = $name
                        Interface    = ""
                        DHCP         = ""
                        DNS          = ""
                        Passerelle   = ""
                        Statut       = "Atteignable (scan)"
                    }
                    $inventory += $entry
                }
                Write-Host "  [[OK]] $ip" -ForegroundColor Green
            }
        } catch {
            # Pas de réponse
        }
    }
    Write-Host "  ($found machines trouvées au scan)"
}

# --- Résumé ---
Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "          RÉSUMÉ DE L'INVENTAIRE" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Date        : $timestamp"
Write-Host "Machine     : $hostname"
Write-Host "Total       : $($inventory.Count) entrées"
$active = ($inventory | Where-Object { $_.Statut -match 'Up|Atteignable' }).Count
Write-Host "Actives     : $active"

# Afficher le tableau
Write-Host ""
$inventory | Format-Table IP, MAC, Hostname, Fabricant, Statut -AutoSize

# --- Export CSV ---
if ($ExportCSV) {
    $inventory | Export-Csv -Path $ExportCSV -NoTypeInformation -Encoding UTF8
    Write-Host "Export CSV  : $ExportCSV" -ForegroundColor Yellow
}

# --- Export HTML ---
if ($ExportHTML) {
    $html = @"
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>Inventaire Réseau - $hostname</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 30px; background: #f5f5f5; }
        h1 { color: #1a73e8; border-bottom: 3px solid #1a73e8; padding-bottom: 10px; }
        h2 { color: #333; margin-top: 30px; }
        table { border-collapse: collapse; width: 100%; margin-top: 15px; box-shadow: 0 1px 4px rgba(0,0,0,0.1); }
        th { background: #1a73e8; color: white; padding: 10px 12px; text-align: left; }
        td { padding: 8px 12px; border-bottom: 1px solid #ddd; }
        tr:nth-child(even) { background: #f9f9f9; }
        tr:hover { background: #e8f0fe; }
        .summary { background: white; padding: 15px; border-radius: 5px; box-shadow: 0 1px 4px rgba(0,0,0,0.1); margin-top: 20px; }
        .label { font-weight: bold; color: #555; }
    </style>
</head>
<body>
    <h1>Inventaire Réseau</h1>
    <div class="summary">
        <p><span class="label">Machine :</span> $hostname</p>
        <p><span class="label">Date :</span> $timestamp</p>
        <p><span class="label">Total entrées :</span> $($inventory.Count)</p>
    </div>
    <h2>Périphériques réseau</h2>
    <table>
        <tr>
            <th>IP</th>
            <th>MAC</th>
            <th>Fabricant</th>
            <th>Hostname</th>
            <th>Interface</th>
            <th>Statut</th>
        </tr>
"@

    foreach ($entry in $inventory) {
        $html += @"
        <tr>
            <td>$($entry.IP)</td>
            <td>$($entry.MAC)</td>
            <td>$($entry.Fabricant)</td>
            <td>$($entry.Hostname)</td>
            <td>$($entry.Interface)</td>
            <td>$($entry.Statut)</td>
        </tr>
"@
    }

    $html += @"
    </table>
    <p style="color: #888; margin-top: 20px; font-size: 0.9em;">Généré le $timestamp</p>
</body>
</html>
"@

    $html | Set-Content -Path $ExportHTML -Encoding UTF8
    Write-Host "Export HTML : $ExportHTML" -ForegroundColor Yellow
}

return $inventory
