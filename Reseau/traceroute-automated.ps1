<#
.SYNOPSIS
    Traceroute automatisé vers une destination avec export des résultats.
.DESCRIPTION
    Effectue un traceroute vers une IP ou un nom de domaine, mesure les
    temps de réponse par saut, et exporte les résultats en CSV/JSON/TXT.
.PARAMETER Target
    Adresse IP ou nom de domaine destination
.PARAMETER MaxHops
    Nombre maximum de sauts (défaut: 30)
.PARAMETER Timeout
    Délai d'attente en ms par requête (défaut: 3000)
.PARAMETER ResolveNames
    Résoudre les noms d'hôte pour chaque saut (défaut: $true)
.PARAMETER ExportPath
    Chemin du fichier d'export (optionnel)
.PARAMETER ExportFormat
    Format d'export (CSV, JSON, TXT) (défaut: CSV)
.PARAMETER Continuous
    Mode continu — répète le traceroute toutes les N secondes (optionnel)
.EXAMPLE
    .\traceroute-automated.ps1 -Target "google.com"
    .\traceroute-automated.ps1 -Target "8.8.8.8" -ExportPath "trace.csv" -ExportFormat CSV
    .\traceroute-automated.ps1 -Target "github.com" -Continuous 10 -MaxHops 20
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = "Adresse IP ou nom de domaine")]
    [string]$Target,

    [ValidateRange(1, 255)]
    [int]$MaxHops = 30,

    [int]$Timeout = 3000,

    [bool]$ResolveNames = $true,

    [string]$ExportPath = "",

    [ValidateSet("CSV", "JSON", "TXT")]
    [string]$ExportFormat = "CSV",

    [int]$Continuous = 0
)

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "          TRACEROUTE AUTOMATISÉ" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# Résoudre la destination
try {
    $ipList = [System.Net.Dns]::GetHostAddresses($Target) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }
    if (-not $ipList) {
        $ipList = [System.Net.Dns]::GetHostAddresses($Target)
    }
    $destinationIP = $ipList[0].IPAddressToString
    Write-Host "Destination : $Target ($destinationIP)" -ForegroundColor White
} catch {
    Write-Error "Impossible de résoudre la cible: $Target"
    exit 1
}

Write-Host "Sauts max   : $MaxHops"
Write-Host "Timeout     : ${Timeout}ms"
if ($Continuous) { Write-Host "Mode continu: toutes les ${Continuous}s" }
Write-Host ""

function Do-Traceroute {
    param([string]$DestIP, [int]$MaxH, [int]$TO, [bool]$Resolve)

    $results = @()
    $targetReached = $false

    for ($ttl = 1; $ttl -le $MaxH; $ttl++) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $pingOptions = New-Object System.Net.NetworkInformation.PingOptions($ttl, $true)
        $reply = $ping.Send($DestIP, $TO, [byte[]]@(0x41, 0x42, 0x43, 0x44), $pingOptions)

        $hopResult = [PSCustomObject]@{
            Saut      = $ttl
            Adresse   = ""
            Hostname  = ""
            Temps1Ms  = "*"
            Temps2Ms  = "*"
            Temps3Ms  = "*"
            Status    = ""
        }

        if ($reply.Status -eq 'Success' -or $reply.Status -eq 'TtlExpired' -or $reply.Status -eq 'TimeExceeded') {
            $addr = $reply.Address.IPAddressToString
            $hopResult.Adresse = $addr

            if ($Resolve -and $addr -ne "0.0.0.0") {
                try {
                    $hopResult.Hostname = [System.Net.Dns]::GetHostEntry($addr).HostName
                } catch {
                    $hopResult.Hostname = "N/A"
                }
            }

            # On fait 3 mesures par saut
            $times = @()
            for ($n = 0; $n -lt 3; $n++) {
                $r = $ping.Send($DestIP, $TO, [byte[]]@(0x41, 0x42, 0x43, 0x44), $pingOptions)
                $times += if ($r.Status -eq 'Success' -or $r.Status -eq 'TtlExpired') { $r.RoundtripTime } else { $null }
            }
            $hopResult.Temps1Ms = if ($times[0] -ne $null) { "$($times[0]) ms" } else { "*" }
            $hopResult.Temps2Ms = if ($times[1] -ne $null) { "$($times[1]) ms" } else { "*" }
            $hopResult.Temps3Ms = if ($times[2] -ne $null) { "$($times[2]) ms" } else { "*" }

            if ($reply.Status -eq 'Success') {
                $hopResult.Status = "Destination atteinte"
                $targetReached = $true
            } elseif ($reply.Status -eq 'TtlExpired') {
                $hopResult.Status = "Saut intermédiaire"
            } else {
                $hopResult.Status = "Délai dépassé"
            }
        } else {
            $hopResult.Status = "Aucune réponse"
        }

        $results += $hopResult
        Write-Host "[$ttl] $($hopResult.Adresse.PadRight(16)) $($hopResult.Temps1Ms.PadRight(10))$($hopResult.Temps2Ms.PadRight(10))$($hopResult.Temps3Ms.PadRight(10)) $($hopResult.Hostname)"

        if ($targetReached) { break }
    }

    return $results, $targetReached
}

do {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "── $timestamp ───────────────────────────────" -ForegroundColor Yellow
    Write-Host " Saut   Adresse         T1         T2         T3         Hostname" -ForegroundColor Cyan
    Write-Host " ─────────────────────────────────────────────────────────────────" -ForegroundColor Cyan

    $results, $reached = Do-Traceroute -DestIP $destinationIP -MaxH $MaxHops -TO $Timeout -Resolve $ResolveNames

    $totalHops = $results[-1].Saut

    Write-Host ""
    if ($reached) {
        Write-Host "✓ Destination atteinte en $totalHops sauts" -ForegroundColor Green
    } else {
        Write-Host "✗ Destination non atteinte après $MaxHops sauts" -ForegroundColor Red
    }
    Write-Host ""

    # Export si demandé
    if ($ExportPath) {
        $exportFile = $ExportPath
        if ($Continuous) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($ExportPath)
            $ext  = [System.IO.Path]::GetExtension($ExportPath)
            $ts = Get-Date -Format "yyyyMMdd-HHmmss"
            $exportFile = "$base-$ts$ext"
        }

        switch ($ExportFormat.ToUpper()) {
            "CSV" {
                $results | Export-Csv -Path $exportFile -NoTypeInformation -Encoding UTF8
            }
            "JSON" {
                $results | ConvertTo-Json | Set-Content -Path $exportFile -Encoding UTF8
            }
            "TXT" {
                $results | Format-Table Saut, Adresse, Temps1Ms, Temps2Ms, Temps3Ms, Status, Hostname -AutoSize | Out-String -Width 4096 | Set-Content -Path $exportFile -Encoding UTF8
            }
        }
        Write-Host "Exporté vers: $exportFile" -ForegroundColor Yellow
    }

    if ($Continuous -gt 0) {
        Write-Host "Attente ${Continuous}s avant la prochaine mesure..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $Continuous
    }

} while ($Continuous -gt 0)

return $results
