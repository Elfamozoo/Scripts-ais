<#
.SYNOPSIS
    Ping sweep sur une plage d'adresses IP.
.DESCRIPTION
    Teste chaque adresse IP d'une plage donnée (ex: 192.168.1.1-254) et
    retourne les machines qui répondent avec leur temps de réponse.
.PARAMETER Subnet
    Sous-réseau (ex: 192.168.1)
.PARAMETER StartRange
    Début de la plage (défaut: 1)
.PARAMETER EndRange
    Fin de la plage (défaut: 254)
.PARAMETER Timeout
    Délai d'attente en ms (défaut: 100)
.PARAMETER Threads
    Nombre de threads parallèles (défaut: 50)
.PARAMETER ExportCSV
    Chemin du fichier CSV d'export (optionnel)
.EXAMPLE
    .\ping-sweep.ps1 -Subnet "192.168.1"
    .\ping-sweep.ps1 -Subnet "10.0.0" -StartRange 50 -EndRange 100 -ExportCSV "resultats.csv"
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = "Sous-réseau (ex: 192.168.1)")]
    [string]$Subnet,

    [ValidateRange(1, 254)]
    [int]$StartRange = 1,

    [ValidateRange(1, 254)]
    [int]$EndRange = 254,

    [int]$Timeout = 100,

    [int]$Threads = 50,

    [string]$ExportCSV = ""
)

if ($StartRange -gt $EndRange) {
    Write-Error "StartRange ($StartRange) ne peut pas être supérieur à EndRange ($EndRange)"
    exit 1
}

$total = $EndRange - $StartRange + 1
Write-Host "=== Ping Sweep ===" -ForegroundColor Cyan
Write-Host "Plage      : $Subnet.$StartRange - $Subnet.$EndRange"
Write-Host "Timeout    : ${Timeout}ms"
Write-Host "Threads    : $Threads"
Write-Host "Total IPs  : $total"
Write-Host ""

$results = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Créer une pool de Runspace pour le parallélisme
$pool = [RunspaceFactory]::CreateRunspacePool(1, $Threads)
$pool.Open()
$jobs = @()

for ($i = $StartRange; $i -le $EndRange; $i++) {
    $ip = "$Subnet.$i"
    $ps = [powershell]::Create().AddScript({
        param($ip, $timeout)
        $ping = New-Object System.Net.NetworkInformation.Ping
        try {
            $reply = $ping.Send($ip, $timeout)
            if ($reply.Status -eq 'Success') {
                try {
                    $name = [System.Net.Dns]::GetHostEntry($ip).HostName
                } catch {
                    $name = "N/A"
                }
                return [PSCustomObject]@{
                    IP          = $ip
                    Status      = "Répond"
                    TempsMs     = $reply.RoundtripTime
                    TTL         = $reply.Options.Ttl
                    Hostname    = $name
                }
            }
        } catch {
            # Ignorer les erreurs
        }
        return $null
    }).AddArgument($ip).AddArgument($Timeout)
    $ps.RunspacePool = $pool
    $jobs += [PSCustomObject]@{ PowerShell = $ps; AsyncResult = $ps.BeginInvoke() }
}

$count = 0
foreach ($job in $jobs) {
    $result = $job.PowerShell.EndInvoke($job.AsyncResult)
    if ($result) {
        $results += $result
        $count++
        Write-Host "[$count] $($result.IP) - Temps: $($result.TempsMs)ms | TTL: $($result.TTL) | $($result.Hostname)" -ForegroundColor Green
    }
    $job.PowerShell.Dispose()
}

$pool.Close()
$pool.Dispose()
$sw.Stop()

Write-Host ""
Write-Host "=== Résultats ===" -ForegroundColor Cyan
Write-Host "Machines trouvées: $count / $total"
Write-Host "Durée: $($sw.Elapsed.TotalSeconds)s"

if ($ExportCSV -and $results.Count -gt 0) {
    $results | Export-Csv -Path $ExportCSV -NoTypeInformation -Encoding UTF8
    Write-Host "Exporté vers: $ExportCSV" -ForegroundColor Yellow
}

return $results
