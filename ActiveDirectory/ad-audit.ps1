<#
.SYNOPSIS
    Audit complet de l'Active Directory : utilisateurs, groupes, ordinateurs et OU.
.DESCRIPTION
    Génère un état des lieux structuré de l'infrastructure AD avec :
    - Utilisateurs : actifs, inactifs, verrouillés, expirés
    - Groupes : universels, globaux, domain local, distribution/sécurité, membres
    - Ordinateurs : système d'exploitation, dernière connexion, activé/désactivé
    - OU : arborescence complète avec nombre d'objets par type
    Exporte les résultats dans des fichiers CSV organisés.
.PARAMETER SearchBase
    Base de recherche (optionnel, racine du domaine par défaut).
.PARAMETER OutputDir
    Répertoire de sortie des rapports CSV.
.PARAMETER IncludeComputers
    Inclut l'audit des ordinateurs (défaut : $true).
.PARAMETER IncludeGroups
    Inclut l'audit des groupes (défaut : $true).
.PARAMETER IncludeOUS
    Inclut l'audit des unités d'organisation (défaut : $true).
.PARAMETER PassThru
    Retourne les objets en plus de la console.
.EXAMPLE
    .\ad-audit.ps1 -OutputDir "C:\Audit\AD-$(Get-Date -Format yyyyMMdd)"
.EXAMPLE
    .\ad-audit.ps1 -SearchBase "OU=Paris,DC=domaine,DC=fr" -IncludeComputers:$false
.NOTES
    Auteur : Hermes Agent
    Requiert : Module ActiveDirectory, privilèges de lecture AD
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SearchBase,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = ".\AD-Audit_$(Get-Date -Format 'yyyyMMdd_HHmmss')",

    [Parameter(Mandatory = $false)]
    [switch]$IncludeComputers  = $true,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeGroups     = $true,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeOUS        = $true,

    [Parameter(Mandatory = $false)]
    [switch]$PassThru
)

# ---- Dépendances ----
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "Le module ActiveDirectory n'est pas installé."
    exit 1
}
Import-Module ActiveDirectory -Force

# ---- Préparation ----
$domainInfo = Get-ADDomain
$domainDN   = $domainInfo.DistinguishedName
$domainName = $domainInfo.DNSRoot
$rootOU     = if ($SearchBase) { $SearchBase } else { $domainDN }

# Création du dossier de sortie
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

$startTime = Get-Date
$auditLog  = Join-Path $OutputDir "audit-summary.log"

Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  AUDIT ACTIVE DIRECTORY - $domainName" -ForegroundColor Cyan
Write-Host "  Démarré le : $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host "  Domaine    : $domainDN" -ForegroundColor Cyan
Write-Host "  Base       : $rootOU" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan

$summary = [ordered]@{}

# ============================================================
#  1. AUDIT DES UTILISATEURS
# ============================================================
Write-Host "`n👤 1/4 — Audit des utilisateurs..." -ForegroundColor Yellow

$userSplat = @{
    Properties = @('DisplayName', 'SamAccountName', 'Mail', 'Enabled', 'LockedOut',
                   'LastLogonDate', 'PasswordLastSet', 'Created', 'AccountExpirationDate',
                   'BadLogonCount', 'Department', 'Title', 'Description', 'Manager',
                   'MemberOf', 'UserPrincipalName', 'PasswordNeverExpires',
                   'CannotChangePassword', 'DistinguishedName')
    ResultPageSize = 500
}
if ($SearchBase) { $userSplat.SearchBase = $SearchBase }

$allUsers = Get-ADUser -Filter * @userSplat

$usersReport = $allUsers | ForEach-Object {
    $etat = if ($_.Enabled) {
        if ($_.LockedOut) { 'Verrouillé' } else { 'Actif' }
    } else {
        if ($_.AccountExpirationDate -and $_.AccountExpirationDate -lt (Get-Date)) { 'Expiré' }
        else { 'Désactivé' }
    }

    $isInactive = $false
    if ($_.Enabled) {
        if (-not $_.LastLogonDate -or $_.LastLogonDate -lt (Get-Date).AddDays(-90)) {
            $isInactive = $true
        }
    }

    $groupsCount = ($_.MemberOf | Measure-Object).Count

    [PSCustomObject]@{
        Nom                 = $_.DisplayName
        Login               = $_.SamAccountName
        UPN                 = $_.UserPrincipalName
        Email               = $_.Mail
        Etat                = $etat
        Inactif90j          = if ($isInactive) { 'OUI' } else { 'Non' }
        Verrouille          = if ($_.LockedOut) { 'OUI' } else { 'Non' }
        Dpt                 = $_.Department
        Titre               = $_.Title
        NbGroupes           = $groupsCount
        DateCreation        = $_.Created.ToString('yyyy-MM-dd')
        DerniereConnexion   = if ($_.LastLogonDate) { $_.LastLogonDate.ToString('yyyy-MM-dd HH:mm') } else { 'Jamais' }
        MDPExpire           = if (-not $_.PasswordNeverExpires) { 'Oui' } else { 'Non' }
        MDPChangeInterdit   = if ($_.CannotChangePassword) { 'Oui' } else { 'Non' }
        DateExpiration      = if ($_.AccountExpirationDate) { $_.AccountExpirationDate.ToString('yyyy-MM-dd') } else { 'N/A' }
        TentativesEchouees  = $_.BadLogonCount
        Manager             = if ($_.Manager) {
            try { (Get-ADUser -Identity $_.Manager -Properties DisplayName).DisplayName } catch { $_.Manager }
        } else { '(Aucun)' }
        DN                  = $_.DistinguishedName
    }
}

$usersReport | Export-Csv -Path (Join-Path $OutputDir "ad-users.csv") -NoTypeInformation -Encoding UTF8

$summary['Utilisateurs (Total)'] = $allUsers.Count
$summary['   Actifs']            = ($usersReport | Where-Object Etat -eq 'Actif').Count
$summary['   Désactivés']        = ($usersReport | Where-Object Etat -eq 'Désactivé').Count
$summary['   Verrouillés']       = ($usersReport | Where-Object Etat -eq 'Verrouillé').Count
$summary['   Expirés']           = ($usersReport | Where-Object Etat -eq 'Expiré').Count
$summary['   Inactifs 90j+']     = ($usersReport | Where-Object Inactif90j -eq 'OUI').Count
$summary['   Avec email']        = ($usersReport | Where-Object { $_.Email }).Count
$summary['   Sans email']        = ($usersReport | Where-Object { -not $_.Email }).Count

Write-Host "   ✅ $($allUsers.Count) utilisateurs exportés" -ForegroundColor Green

# ============================================================
#  2. AUDIT DES GROUPES
# ============================================================
if ($IncludeGroups) {
    Write-Host "`n👥 2/4 — Audit des groupes..." -ForegroundColor Yellow

    $groupSplat = @{
        Properties = @('Name', 'SamAccountName', 'GroupCategory', 'GroupScope',
                       'Description', 'Member', 'MemberOf', 'DistinguishedName',
                       'Created', 'ManagedBy', 'GroupType')
        ResultPageSize = 500
    }
    if ($SearchBase) { $groupSplat.SearchBase = $SearchBase }

    $allGroups = Get-ADGroup -Filter * @groupSplat

    $groupsReport = $allGroups | ForEach-Object {
        $memberCount = ($_.Member | Measure-Object).Count
        $parentGroups = ($_.MemberOf | Measure-Object).Count

        $managedBy = if ($_.ManagedBy) {
            try { (Get-ADUser -Identity $_.ManagedBy -Properties DisplayName).DisplayName } catch { $_.ManagedBy }
        } else { '(Aucun)' }

        # Catégorie en français
        $catFr = @{
            'Security'    = 'Sécurité'
            'Distribution' = 'Distribution'
        }[$_.GroupCategory] -or $_.GroupCategory

        $scopeFr = @{
            'Global'           = 'Global'
            'DomainLocal'      = 'Domaine Local'
            'Universal'        = 'Universel'
        }[$_.GroupScope] -or $_.GroupScope

        [PSCustomObject]@{
            Nom            = $_.Name
            LoginGroupe    = $_.SamAccountName
            Portee         = $scopeFr
            Categorie      = $catFr
            Type           = @{ 'Security' = 'Sécurité'; 'Distribution' = 'Distribution' }[$_.GroupCategory]
            Description    = $_.Description
            NbMembres      = $memberCount
            NbGroupesParents = $parentGroups
            GerePar        = $managedBy
            DateCreation   = $_.Created.ToString('yyyy-MM-dd')
            DN             = $_.DistinguishedName
        }
    }

    $groupsReport | Export-Csv -Path (Join-Path $OutputDir "ad-groupes.csv") -NoTypeInformation -Encoding UTF8

    $summary['Groupes (Total)']   = $allGroups.Count
    $summary['   Sécurité']       = ($groupsReport | Where-Object Type -eq 'Sécurité').Count
    $summary['   Distribution']   = ($groupsReport | Where-Object Type -eq 'Distribution').Count
    $summary['   Universel']      = ($groupsReport | Where-Object Portee -eq 'Universel').Count
    $summary['   Global']         = ($groupsReport | Where-Object Portee -eq 'Global').Count
    $summary['   Domaine Local']  = ($groupsReport | Where-Object Portee -eq 'Domaine Local').Count
    $summary['   Vides (0 membre)'] = ($groupsReport | Where-Object NbMembres -eq 0).Count

    Write-Host "   ✅ $($allGroups.Count) groupes exportés" -ForegroundColor Green
}

# ============================================================
#  3. AUDIT DES ORDINATEURS
# ============================================================
if ($IncludeComputers) {
    Write-Host "`n💻 3/4 — Audit des ordinateurs..." -ForegroundColor Yellow

    $compSplat = @{
        Properties = @('Name', 'SamAccountName', 'OperatingSystem', 'OperatingSystemVersion',
                       'Enabled', 'LastLogonDate', 'Created', 'IPv4Address',
                       'Description', 'Location', 'DistinguishedName', 'ManagedBy')
        ResultPageSize = 500
    }
    if ($SearchBase) { $compSplat.SearchBase = $SearchBase }

    $allComputers = Get-ADComputer -Filter * @compSplat

    $computersReport = $allComputers | ForEach-Object {
        $os = $_.OperatingSystem
        # Catégorisation OS
        $osCat = if ($os -like '*Windows Server*') { 'Serveur' }
                 elseif ($os -like '*Windows 10*' -or $os -like '*Windows 11*') { 'Poste de travail' }
                 elseif ($os) { 'Autre' }
                 else { 'Inconnu' }

        $inactive = $false
        if ($_.Enabled -and (-not $_.LastLogonDate -or $_.LastLogonDate -lt (Get-Date).AddDays(-90))) {
            $inactive = $true
        }

        [PSCustomObject]@{
            Nom               = $_.Name
            Login             = $_.SamAccountName
            OS                = $_.OperatingSystem
            VersionOS         = $_.OperatingSystemVersion
            CategorieOS       = $osCat
            Etat              = if ($_.Enabled) { 'Actif' } else { 'Désactivé' }
            Inactif90j        = if ($inactive) { 'OUI' } else { 'Non' }
            IP                = $_.IPv4Address
            DerniereConnexion = if ($_.LastLogonDate) { $_.LastLogonDate.ToString('yyyy-MM-dd HH:mm') } else { 'Jamais' }
            DateJoign         = $_.Created.ToString('yyyy-MM-dd')
            Emplacement       = $_.Location
            Description       = $_.Description
            DN                = $_.DistinguishedName
        }
    }

    $computersReport | Export-Csv -Path (Join-Path $OutputDir "ad-ordinateurs.csv") -NoTypeInformation -Encoding UTF8

    $summary['Ordinateurs (Total)']   = $allComputers.Count
    $summary['   Serveurs']           = ($computersReport | Where-Object CategorieOS -eq 'Serveur').Count
    $summary['   Postes de travail']  = ($computersReport | Where-Object CategorieOS -eq 'Poste de travail').Count
    $summary['   Actifs']             = ($computersReport | Where-Object Etat -eq 'Actif').Count
    $summary['   Désactivés']         = ($computersReport | Where-Object Etat -eq 'Désactivé').Count
    $summary['   Inactifs 90j+']      = ($computersReport | Where-Object Inactif90j -eq 'OUI').Count

    # Top OS
    $topOS = $computersReport | Where-Object OS | Group-Object OS | Sort-Object Count -Descending | Select-Object -First 5
    if ($topOS) {
        $summary['Top OS'] = ''
        foreach ($os in $topOS) {
            $summary["   $($os.Name)"] = $os.Count
        }
    }

    Write-Host "   ✅ $($allComputers.Count) ordinateurs exportés" -ForegroundColor Green
}

# ============================================================
#  4. AUDIT DES UNITÉS D'ORGANISATION
# ============================================================
if ($IncludeOUS) {
    Write-Host "`n📁 4/4 — Audit des Unités d'Organisation..." -ForegroundColor Yellow

    function Get-OUTree {
        param([string]$DN, [int]$Depth = 0, [string]$ParentDN = '')

        $ous = Get-ADOrganizationalUnit -Filter * -SearchBase $DN -SearchScope OneLevel -Properties Description, ProtectedFromAccidentalDeletion, DistinguishedName

        foreach ($ou in $ous) {
            # Compter les objets enfants
            $childUsers     = (Get-ADUser -Filter * -SearchBase $ou.DistinguishedName -SearchScope OneLevel -ResultPageSize 1000 -ResultSetSize $null -ErrorAction SilentlyContinue).Count
            $childGroups    = (Get-ADGroup -Filter * -SearchBase $ou.DistinguishedName -SearchScope OneLevel -ResultPageSize 1000 -ResultSetSize $null -ErrorAction SilentlyContinue).Count
            $childComputers = (Get-ADComputer -Filter * -SearchBase $ou.DistinguishedName -SearchScope OneLevel -ResultPageSize 1000 -ResultSetSize $null -ErrorAction SilentlyContinue).Count
            $childOUs       = (Get-ADOrganizationalUnit -Filter * -SearchBase $ou.DistinguishedName -SearchScope OneLevel -ErrorAction SilentlyContinue).Count

            $indent = '  ' * $Depth
            $prefix = if ($Depth -eq 0) { '📁' } else { '📂' }

            [PSCustomObject]@{
                Niveau          = $Depth
                Arborescence    = "$indent$prefix $($ou.Name)"
                Nom             = $ou.Name
                DN              = $ou.DistinguishedName
                Description     = if ($ou.Description) { $ou.Description } else { '-' }
                ProtectionSup   = if ($ou.ProtectedFromAccidentalDeletion) { 'OUI' } else { 'Non' }
                NbUtilisateurs  = $childUsers
                NbGroupes       = $childGroups
                NbOrdinateurs   = $childComputers
                NbSousOUs       = $childOUs
                TotalObjets     = $childUsers + $childGroups + $childComputers
            }

            # Récursion pour les sous-OUs
            Get-OUTree -DN $ou.DistinguishedName -Depth ($Depth + 1) -ParentDN $ou.DistinguishedName
        }
    }

    $ouReport = Get-OUTree -DN $rootOU

    $ouReport | Export-Csv -Path (Join-Path $OutputDir "ad-ous.csv") -NoTypeInformation -Encoding UTF8

    $summary['Unités d\'organisation'] = $ouReport.Count
    $summary['   Racines (niveau 1)']   = ($ouReport | Where-Object Niveau -eq 1).Count
    $summary['   Profondeur max']       = ($ouReport | Measure-Object Niveau -Maximum).Maximum

    Write-Host "   ✅ $($ouReport.Count) OU exportées (arborescence complète)" -ForegroundColor Green
}

# ============================================================
#  RAPPORT FINAL
# ============================================================
$endTime = Get-Date
$duration = ($endTime - $startTime).TotalSeconds

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  RÉSUMÉ D'AUDIT — $domainName" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan

foreach ($key in $summary.Keys) {
    $val = $summary[$key]
    if ($val -eq '') {
        Write-Host "  $key" -ForegroundColor Cyan
    } else {
        if ($key -match '^\s{3,}') {
            Write-Host "   $key : $val" -ForegroundColor Gray
        } else {
            Write-Host "  $key : $val" -ForegroundColor White
        }
    }
}
Write-Host "`n  Durée    : $([math]::Round($duration, 1)) secondes" -ForegroundColor Gray
Write-Host "  Dossier  : $OutputDir" -ForegroundColor Gray
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan

# Enregistrer le résumé dans le log
@"
═══════════════════════════════════════════
AUDIT AD - $domainName
Date : $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))
Durée : $([math]::Round($duration, 1))s
═══════════════════════════════════════════
$($summary.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" } | Out-String)
Fichiers dans : $OutputDir
═══════════════════════════════════════════
"@ | Out-File -FilePath $auditLog -Encoding UTF8

Write-Host "`n📄 Fichiers générés dans : $OutputDir" -ForegroundColor Yellow
Get-ChildItem $OutputDir | ForEach-Object { Write-Host "   📄 $($_.Name) ($([math]::Round($_.Length/1KB, 1)) KB)" -ForegroundColor Gray }

if ($PassThru) {
    return @{
        Users     = $usersReport
        Groups    = if ($IncludeGroups) { $groupsReport } else { $null }
        Computers = if ($IncludeComputers) { $computersReport } else { $null }
        OUs       = if ($IncludeOUS) { $ouReport } else { $null }
        Summary   = $summary
    }
}
