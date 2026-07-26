<#
.SYNOPSIS
    Affiche la liste des administrateurs locaux.
.DESCRIPTION
    Utilise net localgroup, fonctionne sur toutes les versions de Windows.
    Essaie les noms de groupe dans plusieurs langues.
.PARAMETER ComputerName
    Machine cible (defaut: locale)
.EXAMPLE
    .\local-admin-check.ps1
    .\local-admin-check.ps1 -ComputerName SRV-DC01
#>

param([string]$ComputerName = $env:COMPUTERNAME)

$GroupNames = @(
    "Administrateurs",    # Francais
    "Administrators",     # Anglais
    "Administratoren",    # Allemand
    "Администраторы"      # Russe
)

$Members = @()
$Found = $false

foreach ($Group in $GroupNames) {
    if ($Found) { break }
    
    if ($ComputerName -eq $env:COMPUTERNAME -or $ComputerName -eq "localhost") {
        $Output = net localgroup $Group 2>$null
    } else {
        $Output = net localgroup $Group /domain 2>$null
    }
    
    if ($Output -and $Output.Count -gt 4) {
        # Trouver le debut de la liste des membres (ligne apres les ---)
        $StartLine = -1
        for ($i = 0; $i -lt $Output.Count; $i++) {
            if ($Output[$i] -match "^-+$" -and $i -lt ($Output.Count - 1)) {
                $StartLine = $i + 1
                break
            }
        }
        
        if ($StartLine -gt 0) {
            $Members = $Output[$StartLine..($Output.Count - 1)] | Where-Object {
                $_ -and $_.Trim() -ne "" -and $_ -notmatch "command completed|terminee correctement"
            } | ForEach-Object { $_.Trim() }
        }
        $Found = $true
    }
}

if ($Members.Count -eq 0) {
    Write-Host "[ERR] Aucun administrateur trouve ou acces refuse sur $ComputerName" -ForegroundColor Red
    Write-Host "       Verifiez que vous lancez PowerShell en administrateur" -ForegroundColor Yellow
    exit
}

Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host "ADMINISTRATEURS LOCAUX - $ComputerName" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan

foreach ($Member in $Members) {
    Write-Host "  $Member"
}

Write-Host "`nTotal: $($Members.Count) membre(s)" -ForegroundColor Cyan
