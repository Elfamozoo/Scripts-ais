<#
.SYNOPSIS
    Désactive les comptes utilisateurs AD inactifs depuis plus de 90 jours.
.DESCRIPTION
    Recherche les utilisateurs dont la dernière connexion (LastLogonDate) remonte
    à plus de 90 jours, ou les comptes créés mais jamais connectés.
    Fournit un mode rapport (pas de désactivation) et un mode exécution.
.PARAMETER InactiveDays
    Nombre de jours d'inactivité déclenchant la désactivation (défaut : 90).
.PARAMETER SearchBase
    OU de recherche spécifique (optionnel).
.PARAMETER ReportOnly
    Génère un rapport sans désactiver les comptes (mode audit).
.PARAMETER ExcludeServiceAccounts
    Exclut les comptes de service (SamAccountName commençant par "svc_").
.PARAMETER OutputPath
    Chemin du rapport CSV.
.PARAMETER LogPath
    Chemin du fichier de log.
.EXAMPLE
    .\disable-inactive-users.ps1 -InactiveDays 90 -ReportOnly
.EXAMPLE
    .\disable-inactive-users.ps1 -InactiveDays 60 -ExcludeServiceAccounts
.NOTES
    Auteur : Hermes Agent
    Requiert : Module ActiveDirectory, privilèges de modification AD
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 999)]
    [int]$InactiveDays = 90,

    [Parameter(Mandatory = $false)]
    [string]$SearchBase,

    [Parameter(Mandatory = $false)]
    [switch]$ReportOnly,

    [Parameter(Mandatory = $false)]
    [switch]$ExcludeServiceAccounts,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$LogPath
)

# ---- Dépendances ----
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "Le module ActiveDirectory n'est pas installé."
    exit 1
}
Import-Module ActiveDirectory -Force

# ---- Fonction de log ----
$log = { param($msg, $level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$level] $msg"
    switch ($level) {
        'OK'   { Write-Host $line -ForegroundColor Green }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERR'  { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line -ForegroundColor Gray }
    }
    if ($LogPath) { Add-Content -Path $LogPath -Value $line }
}

# ---- Date de référence ----
$refDate = (Get-Date).AddDays(-$InactiveDays)
$cutoff = $refDate.ToString('yyyy-MM-dd')
&$log "[SEARCH] Recherche des utilisateurs inactifs depuis $InactiveDays jours (avant le $cutoff)..." 'INFO'

# ---- Paramètres de requête ----
$splat = @{
    Properties = @('DisplayName', 'Mail', 'SamAccountName', 'LastLogonDate',
                   'Enabled', 'Created', 'PasswordLastSet', 'Description',
                   'DistinguishedName', 'UserPrincipalName', 'Department')
    ResultPageSize = 500
}
if ($SearchBase) { $splat.SearchBase = $SearchBase }

# On récupère TOUS les utilisateurs activés (filtrer côté client pour LastLogonDate)
$splat.Filter = "Enabled -eq '`$true'"

try {
    $users = Get-ADUser @splat
    &$log "[DIR] $($users.Count) utilisateurs activés trouvés" 'INFO'
} catch {
    &$log "[ERR] Erreur de requête AD : $_" 'ERR'
    exit 1
}

# ---- Filtre d'inactivité ----
$inactiveUsers = $users | Where-Object {
    $isInactive = $false

    # 1) Jamais connecté et créé il y a plus de $InactiveDays jours
    if (-not $_.LastLogonDate -and $_.Created -lt $refDate) {
        $isInactive = $true
    }
    # 2) Dernière connexion > $InactiveDays jours
    elseif ($_.LastLogonDate -and $_.LastLogonDate -lt $refDate) {
        $isInactive = $true
    }

    $isInactive
} | ForEach-Object {
    $joursInactif = if ($_.LastLogonDate) {
        [math]::Round((Get-Date - $_.LastLogonDate).TotalDays)
    } else {
        $InactiveDays + [math]::Round((Get-Date - $_.Created).TotalDays) # créé depuis longtemps, jamais connecté
    }

    # Exclure comptes de service si demandé
    if ($ExcludeServiceAccounts -and $_.SamAccountName -like 'svc_*') {
        return $null  # skipé
    }

    [PSCustomObject]@{
        Nom              = $_.DisplayName
        Login            = $_.SamAccountName
        Email            = $_.Mail
        UPN              = $_.UserPrincipalName
        DerniereConnexion = if ($_.LastLogonDate) { $_.LastLogonDate.ToString('yyyy-MM-dd HH:mm') } else { 'Jamais connecté' }
        JoursInactif     = $joursInactif
        DateCreation     = $_.Created.ToString('yyyy-MM-dd')
        Service          = $_.Department
        Description      = $_.Description
        DN               = $_.DistinguishedName
    }
} | Where-Object { $_ -ne $null } | Sort-Object JoursInactif -Descending

# ---- Rapport ----
if ($inactiveUsers.Count -eq 0) {
    &$log "[OK] Aucun utilisateur inactif trouvé au-delà de $InactiveDays jours." 'OK'
    exit 0
}

&$log "[WARN]  $($inactiveUsers.Count) utilisateur(s) inactif(s) détecté(s) :" 'WARN'
$inactiveUsers | Format-Table -AutoSize -Property Nom, Login, Email, JoursInactif, DerniereConnexion

# Export CSV du rapport
if ($OutputPath) {
    $inactiveUsers | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    &$log "[FILE] Rapport exporté vers : $OutputPath" 'OK'
}

# ---- Mode ReportOnly ----
if ($ReportOnly) {
    &$log "[CLIP] Mode rapport uniquement - aucune désactivation effectuée." 'INFO'
    exit 0
}

# ---- Confirmation ----
$confirmation = Read-Host "`n[WARN]  Désactiver ces $($inactiveUsers.Count) utilisateurs ? (O/N)"
if ($confirmation -notin @('O', 'o', 'Oui', 'oui', 'Y', 'y', 'Yes', 'yes')) {
    &$log "[STOP]  Opération annulée par l'utilisateur." 'WARN'
    exit 0
}

# ---- Désactivation ----
$disabled = 0
$errors = 0

foreach ($u in $inactiveUsers) {
    if ($PSCmdlet.ShouldProcess($u.Login, "Désactiver le compte (inactif $($u.JoursInactif) jours)")) {
        try {
            Disable-ADAccount -Identity $u.DN -ErrorAction Stop
            &$log "[ERR] Désactivé : $($u.Login) ($($u.Nom))" 'OK'
            $disabled++
        } catch {
            &$log "[ERR] Échec désactivation $($u.Login) : $_" 'ERR'
            $errors++
        }
    }
}

# ---- Rattacher une description ----
# Ajoute une note dans la description du compte
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
foreach ($u in $inactiveUsers) {
    try {
        $user = Get-ADUser -Identity $u.Login -Properties Description
        $note = "[Désactivé automatiquement le $timestamp - inactif $($u.JoursInactif) jours]"
        $newDesc = if ($user.Description) { "$($user.Description) | $note" } else { $note }
        Set-ADUser -Identity $u.Login -Description $newDesc -ErrorAction SilentlyContinue
    } catch { }
}

# ---- Résumé final ----
Write-Host "`n-------------------------------------------" -ForegroundColor Cyan
Write-Host "  RÉSULTAT DÉSACTIVATION COMPTES INACTIFS" -ForegroundColor Cyan
Write-Host "-------------------------------------------" -ForegroundColor Cyan
Write-Host "  Délai d'inactivité  : $InactiveDays jours"
Write-Host "  Comptes trouvés     : $($inactiveUsers.Count)"
Write-Host "  Désactivés          : $disabled"
Write-Host "  Erreurs             : $errors"
Write-Host "-------------------------------------------" -ForegroundColor Cyan
