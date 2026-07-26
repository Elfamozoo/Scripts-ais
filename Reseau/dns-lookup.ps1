<#
.SYNOPSIS
    Effectue des résolutions DNS complètes (A, MX, CNAME, NS, TXT, AAAA).
.DESCRIPTION
    Interroge les enregistrements DNS pour un domaine donné et affiche
    les résultats organisés par type d'enregistrement.
.PARAMETER Domain
    Nom de domaine à interroger (ex: exemple.com)
.PARAMETER RecordTypes
    Types d'enregistrement à vérifier (défaut: A,MX,CNAME,NS,TXT,AAAA)
.PARAMETER DnsServer
    Serveur DNS spécifique à utiliser (optionnel)
.PARAMETER ExportCSV
    Chemin du fichier CSV d'export (optionnel)
.EXAMPLE
    .\dns-lookup.ps1 -Domain "google.com"
    .\dns-lookup.ps1 -Domain "github.com" -RecordTypes A,MX,NS -DnsServer "8.8.8.8"
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = "Nom de domaine (ex: exemple.com)")]
    [string]$Domain,

    [ValidateSet("A", "AAAA", "CNAME", "MX", "NS", "TXT", "SOA", "SRV", "PTR")]
    [string[]]$RecordTypes = @("A", "MX", "CNAME", "NS", "TXT", "AAAA"),

    [string]$DnsServer = "",

    [string]$ExportCSV = ""
)

# Vérifier que le module DnsClient est disponible
$moduleLoaded = $false
try {
    Import-Module DnsClient -ErrorAction Stop
    $moduleLoaded = $true
} catch {
    # DnsClient non disponible, on utilisera Resolve-DnsName (Windows natif) ou nslookup
    try {
        Get-Command Resolve-DnsName -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Ni DnsClient ni Resolve-DnsName ne sont disponibles. Utilisation de nslookup en fallback."
    }
}

Write-Host "=== DNS Lookup ===" -ForegroundColor Cyan
Write-Host "Domaine     : $Domain"
Write-Host "Types       : $($RecordTypes -join ', ')"
if ($DnsServer) { Write-Host "DNS Serveur : $DnsServer" }
Write-Host ""

$results = @()

foreach ($type in $RecordTypes) {
    Write-Host "-- [$type] ------------------------" -ForegroundColor Yellow

    try {
        $params = @{
            Name = $Domain
            Type = $type
            ErrorAction = 'SilentlyContinue'
        }
        if ($moduleLoaded) {
            $cmd = "Resolve-DnsRecord"
        } else {
            $cmd = "Resolve-DnsName"
        }
        if ($DnsServer) { $params.Server = $DnsServer }

        $entries = & $cmd @params

        if (-not $entries) {
            Write-Host "  Aucun enregistrement trouvé" -ForegroundColor DarkGray
            continue
        }

        foreach ($entry in $entries) {
            $record = [PSCustomObject]@{
                Domain      = $Domain
                Type        = $type
                Valeur      = ""
                TTL         = 0
                ServeurDNS  = if ($DnsServer) { $DnsServer } else { "Par défaut" }
            }

            switch ($type) {
                "A" {
                    $val = $entry.IPAddress
                    $record.Valeur = $val
                    $record.TTL = $entry.TTL
                    Write-Host "  $val (TTL: $($entry.TTL))" -ForegroundColor Green
                }
                "AAAA" {
                    $val = $entry.IPAddress
                    $record.Valeur = $val
                    $record.TTL = $entry.TTL
                    Write-Host "  $val (TTL: $($entry.TTL))" -ForegroundColor Green
                }
                "MX" {
                    $val = "$($entry.NameExchange) [Priority: $($entry.Preference)]"
                    $record.Valeur = $val
                    $record.TTL = $entry.TTL
                    Write-Host "  $val (TTL: $($entry.TTL))" -ForegroundColor Green
                }
                "CNAME" {
                    $val = $entry.NameHost
                    $record.Valeur = $val
                    $record.TTL = $entry.TTL
                    Write-Host "  $val (TTL: $($entry.TTL))" -ForegroundColor Green
                }
                "NS" {
                    $val = $entry.NameServer
                    $record.Valeur = $val
                    $record.TTL = $entry.TTL
                    Write-Host "  $val (TTL: $($entry.TTL))" -ForegroundColor Green
                }
                "TXT" {
                    $val = $entry.Strings -join " "
                    $record.Valeur = $val
                    $record.TTL = $entry.TTL
                    Write-Host "  $val (TTL: $($entry.TTL))" -ForegroundColor Green
                }
                "SOA" {
                    $val = "$($entry.PrimaryServer) / $($entry.ResponsiblePerson)"
                    $record.Valeur = $val
                    $record.TTL = $entry.TTL
                    Write-Host "  $val (TTL: $($entry.TTL))" -ForegroundColor Green
                }
                default {
                    $val = $entry | Out-String
                    $record.Valeur = $val.Trim()
                    Write-Host "  $val" -ForegroundColor Green
                }
            }

            $results += $record
        }
    } catch {
        Write-Host "  Erreur: $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== Résumé DNS pour $Domain ===" -ForegroundColor Cyan
$results | Format-Table Type, Valeur, TTL -AutoSize

if ($ExportCSV -and $results.Count -gt 0) {
    $results | Export-Csv -Path $ExportCSV -NoTypeInformation -Encoding UTF8
    Write-Host "Exporté vers: $ExportCSV" -ForegroundColor Yellow
}

return $results
