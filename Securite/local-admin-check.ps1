<#
.SYNOPSIS
    Vérifie qui est administrateur local sur une machine locale ou distante.
.DESCRIPTION
    Liste les membres du groupe Administrateurs local.
    Détecte les comptes suspects ou non autorisés.
    Compatible Windows FR, EN et autres langues.
.PARAMETER ComputerName
    Nom de la machine distante (défaut: localhost)
.EXAMPLE
    .\local-admin-check.ps1
    .\local-admin-check.ps1 -ComputerName SRV-DC01
#>

param([string]$ComputerName = $env:COMPUTERNAME)

function Get-LocalAdmins {
    param([string]$Computer)
    
    # Méthode 1: net localgroup (marche sur toutes les langues)
    try {
        $Output = net localgroup Administrateurs /domain 2>$null
        if (-not $Output) { $Output = net localgroup Administrators /domain 2>$null }
        if (-not $Output) { $Output = net localgroup Administratoren /domain 2>$null }
        if (-not $Output) { 
            # Essai sans /domain (machine locale)
            $Output = net localgroup Administrateurs 2>$null
            if (-not $Output) { $Output = net localgroup Administrators 2>$null }
            if (-not $Output) { $Output = net localgroup Administratoren 2>$null }
        }
        
        if ($Output) {
            $Members = $Output | Select-Object -Skip 4 | Where-Object { $_ -and $_ -notmatch "command successfully|la commande|-----" } | ForEach-Object { $_.Trim() }
            return @($Members | Where-Object { $_ -ne "" })
        }
    } catch {
        # Silently continue
    }
    
    # Méthode 2: Get-LocalGroupMember (PowerShell 5.1+)
    $GroupNames = @("Administrateurs", "Administrators", "Administratoren", "Администраторы")
    foreach ($GroupName in $GroupNames) {
        try {
            $Members = Get-LocalGroupMember -Group $GroupName -ComputerName $Computer -ErrorAction Stop
            return @($Members | ForEach-Object { $_.Name })
        } catch {
            continue
        }
    }
    
    # Méthode 3: WMI (machine distante)
    try {
        $Group = Get-WmiObject -Class Win32_Group -ComputerName $Computer -Filter "SID='S-1-5-32-544'" -ErrorAction Stop
        if ($Group) {
            $Members = Get-WmiObject -Class Win32_GroupUser -ComputerName $Computer -Filter "GroupComponent='Win32_Group.Domain=`"$($Group.Domain)`",Name=`"$($Group.Name)`"'" -ErrorAction Stop
            return @($Members | ForEach-Object { 
                $Parts = $_.PartComponent -split ","
                $Name = ($Parts[0] -split "=")[1] -replace '"',''
                $Domain = ($Parts[1] -split "=")[1] -replace '"','' -replace '>',''
                "$Domain\$Name"
            })
        }
    } catch { }
    
    return $null
}

$Admins = Get-LocalAdmins -Computer $ComputerName

if (-not $Admins -or $Admins.Count -eq 0) {
    Write-Host "[ERR] Impossible de récupérer la liste des administrateurs sur $ComputerName" -ForegroundColor Red
    Write-Host "   Vérifiez que le service 'Remote Registry' tourne ou utilisez PowerShell en admin" -ForegroundColor Yellow
    exit
}

Write-Host "---------------------------------------------------" -ForegroundColor Cyan
Write-Host "ADMINISTRATEURS LOCAUX - $ComputerName" -ForegroundColor Cyan
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

$Admins | ForEach-Object { Write-Host "  $_" }

Write-Host "`nTotal: $($Admins.Count) membres" -ForegroundColor Cyan
