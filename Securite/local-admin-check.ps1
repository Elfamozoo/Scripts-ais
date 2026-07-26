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
    
    if ($ComputerName -eq $env:COMPUTERNAME -or $ComputerName -eq "localhost" -or $ComputerName -eq "127.0.0.1") {
        $Output = net localgroup $Group 2>$null
    } else {
        # Machine distante via WMI
        try {
            $wmi = Get-WmiObject -Class Win32_Group -ComputerName $ComputerName -Filter "SID='S-1-5-32-544'" -ErrorAction Stop
            $remoteMembers = Get-WmiObject -Class Win32_GroupUser -ComputerName $ComputerName -Filter "GroupComponent='Win32_Group.Domain=`"$($wmi.Domain)`",Name=`"$($wmi.Name)`"'" -ErrorAction Stop
            if ($remoteMembers) {
                $Members = $remoteMembers | ForEach-Object {
                    $Parts = $_.PartComponent -split ","
                    $Name = ($Parts[0] -split "=")[1] -replace '"',''
                    $Domain = ($Parts[1] -split "=")[1] -replace '"','' -replace '>',''
                    "$Domain\$Name"
                }
                $Found = $true
                break
            }
        } catch {
            continue
        }
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
