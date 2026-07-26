<#
.SYNOPSIS
    Scan les ports courants sur une ou plusieurs machines.
.DESCRIPTION
    Teste les ports (22,80,443,3389,445,139,3306,8080,8443) sur les cibles
    spécifiées et affiche les ports ouverts.
.PARAMETER Target
    Adresse IP ou hostname de la cible (ou plage ex: 192.168.1.1-20)
.PARAMETER Ports
    Liste des ports à scanner (défaut: 22,80,443,3389,445,139,3306,8080,8443)
.PARAMETER Timeout
    Délai d'attente en ms par port (défaut: 1000)
.PARAMETER Threads
    Nombre de threads parallèles (défaut: 50)
.PARAMETER ExportCSV
    Chemin du fichier CSV d'export (optionnel)
.EXAMPLE
    .\port-scan.ps1 -Target "192.168.1.1"
    .\port-scan.ps1 -Target "192.168.1.1-10" -ExportCSV "ports.csv"
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = "IP ou hostname cible (ex: 192.168.1.1 ou 192.168.1.1-10)")]
    [string]$Target,

    [int[]]$Ports = @(22, 80, 443, 3389, 445, 139, 3306, 8080, 8443),

    [int]$Timeout = 1000,

    [int]$Threads = 50,

    [string]$ExportCSV = ""
)

function Get-PortService {
    param([int]$Port)
    $services = @{
        22   = "SSH"
        80   = "HTTP"
        443  = "HTTPS"
        3389 = "RDP"
        445  = "SMB"
        139  = "NetBIOS"
        3306 = "MySQL"
        8080 = "HTTP-Proxy"
        8443 = "HTTPS-Alt"
    }
    if ($services.ContainsKey($Port)) { return $services[$Port] } else { return "Inconnu" }
}

function Get-Targets {
    param([string]$Input)
    if ($Input -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.)(\d{1,3})-(\d{1,3})$') {
        $subnet = $Matches[1]
        $start  = [int]$Matches[2]
        $end    = [int]$Matches[3]
        return ($start..$end) | ForEach-Object { "$subnet$_" }
    } elseif ($Input -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$') {
        return @($Input)
    } else {
        # Essayer de résoudre le hostname
        try {
            $ips = [System.Net.Dns]::GetHostAddresses($Input) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }
            return $ips | ForEach-Object { $_.IPAddressToString }
        } catch {
            Write-Error "Impossible de résoudre la cible: $Input"
            exit 1
        }
    }
}

$targets = Get-Targets $Target

Write-Host "=== Port Scan ===" -ForegroundColor Cyan
Write-Host "Cible(s)   : $($targets -join ', ')"
Write-Host "Ports      : $($Ports -join ', ')"
Write-Host "Timeout    : ${Timeout}ms"
Write-Host "Threads    : $Threads"
Write-Host ""

$results = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Pool de runspaces pour le parallélisme
$pool = [RunspaceFactory]::CreateRunspacePool(1, $Threads)
$pool.Open()
$jobs = @()

foreach ($ip in $targets) {
    foreach ($port in $Ports) {
        $ps = [powershell]::Create().AddScript({
            param($ip, $port, $timeout)
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $async = $client.BeginConnect($ip, $port, $null, $null)
                $wait = $async.AsyncWaitHandle.WaitOne($timeout, $false)
                if ($wait -and $client.Connected) {
                    $client.EndConnect($async)
                    return [PSCustomObject]@{
                        IP      = $ip
                        Port    = $port
                        Service = (Get-PortService $port)
                        Status  = "Ouvert"
                    }
                }
            } catch {
                # Port fermé ou erreur
            } finally {
                if ($client) { $client.Close() }
            }
            return $null
        }).AddArgument($ip).AddArgument($port).AddArgument($Timeout)
        $ps.RunspacePool = $pool
        $jobs += [PSCustomObject]@{ PowerShell = $ps; AsyncResult = $ps.BeginInvoke() }
    }
}

$count = 0
foreach ($job in $jobs) {
    $result = $job.PowerShell.EndInvoke($job.AsyncResult)
    if ($result) {
        $results += $result
        $count++
        Write-Host "  [OPEN] $($result.IP):$($result.Port) ($($result.Service))" -ForegroundColor Green
    }
    $job.PowerShell.Dispose()
}

$pool.Close()
$pool.Dispose()
$sw.Stop()

Write-Host ""
Write-Host "=== Résultats ===" -ForegroundColor Cyan
Write-Host "Ports ouverts: $count"
Write-Host "Durée: $($sw.Elapsed.TotalSeconds)s"

if ($ExportCSV -and $results.Count -gt 0) {
    $results | Export-Csv -Path $ExportCSV -NoTypeInformation -Encoding UTF8
    Write-Host "Exporté vers: $ExportCSV" -ForegroundColor Yellow
}

return $results
