<#
.SYNOPSIS
    Liste les utilisateurs Active Directory avec nom, email, groupe principal et état.
.DESCRIPTION
    Exporte les utilisateurs AD avec leurs propriétés essentielles : DisplayName, EmailAddress,
    groupes (membre de) et état du compte (activé/désactivé).
    Résultats affichés dans la console et export optionnel en CSV.
.PARAMETER SearchBase
    OU de base pour la recherche (ex: "OU=Utilisateurs,DC=domaine,DC=fr").
    Par défaut : racine du domaine.
.PARAMETER OutputPath
    Chemin du fichier CSV d'export (optionnel).
.PARAMETER Enabled
    Filtre par état du compte : $true (activés), $false (désactivés), ou $null (tous).
.EXAMPLE
    .\list-users.ps1 -OutputPath "C:\Rapports\users.csv"
.EXAMPLE
    .\list-users.ps1 -SearchBase "OU=Paris,DC=domaine,DC=fr" -Enabled $true
.NOTES
    Auteur : Hermes Agent
    Requiert : Module ActiveDirectory, privilèges de lecture AD
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SearchBase,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [nullable[bool]]$Enabled = $null
)

# ---- Dépendances ----
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "Le module ActiveDirectory n'est pas installé. Installez RSAT-AD-PowerShell."
    exit 1
}
Import-Module ActiveDirectory -Force

# ---- Paramètres de recherche ----
$splat = @{
    Properties = @(
        'DisplayName', 'Mail', 'SamAccountName', 'UserPrincipalName',
        'Enabled', 'LastLogonDate', 'PasswordLastSet', 'Created',
        'MemberOf', 'Description', 'Title', 'Department'
    )
    ResultPageSize = 500
}
if ($SearchBase) { $splat.SearchBase = $SearchBase }

# ---- Récupération ----
Write-Host "🔍 Récupération des utilisateurs AD..." -ForegroundColor Cyan
$users = Get-ADUser -Filter * @splat

# ---- Filtre optionnel ----
if ($null -ne $Enabled) {
    $users = $users | Where-Object { $_.Enabled -eq $Enabled }
}

# ---- Transformation ----
$results = $users | ForEach-Object {
    $groups = ($_.MemberOf | ForEach-Object {
        try { (Get-ADGroup $_).Name } catch { $_ }
    }) -join '; '

    $etat = if ($_.Enabled) { 'Actif' } else { 'Désactivé' }

    [PSCustomObject]@{
        Nom                = $_.DisplayName
        Login              = $_.SamAccountName
        UPN                = $_.UserPrincipalName
        Email              = $_.Mail
        Groupe             = if ($groups) { $groups } else { '(Aucun)' }
        Etat               = $etat
        Service            = $_.Department
        Fonction           = $_.Title
        DerniereConnexion  = if ($_.LastLogonDate) { $_.LastLogonDate.ToString('yyyy-MM-dd HH:mm') } else { 'Jamais' }
        MotDePasseLe       = if ($_.PasswordLastSet) { $_.PasswordLastSet.ToString('yyyy-MM-dd HH:mm') } else { 'N/A' }
        DateCreation       = $_.Created.ToString('yyyy-MM-dd')
        Description        = $_.Description
        CheminAD           = $_.DistinguishedName
    }
}

# ---- Affichage ----
Write-Host "`n📋 Utilisateurs AD ($($results.Count) trouvés) :" -ForegroundColor Green
$results | Format-Table -AutoSize -Property Nom, Login, Email, Groupe, Etat, DerniereConnexion

# ---- Export CSV ----
if ($OutputPath) {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "✅ Exporté vers : $OutputPath" -ForegroundColor Yellow
}

# ---- Résumé ----
$stats = @{
    Actifs    = ($results | Where-Object Etat -eq 'Actif').Count
    Inactifs  = ($results | Where-Object Etat -eq 'Désactivé').Count
    AvecEmail = ($results | Where-Object { $_.Email }).Count
    SansEmail = ($results | Where-Object { -not $_.Email }).Count
}

Write-Host "`n📊 Résumé :" -ForegroundColor Cyan
Write-Host "  Actifs       : $($stats.Actifs)"
Write-Host "  Désactivés   : $($stats.Inactifs)"
Write-Host "  Avec email   : $($stats.AvecEmail)"
Write-Host "  Sans email   : $($stats.SansEmail)"
