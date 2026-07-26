<#
.SYNOPSIS
    Vérifie et analyse les comptes AD verrouillés (locked-out).
.DESCRIPTION
    Liste les comptes verrouillés, identifie le contrôleur de domaine d'origine
    du verrouillage, et affiche l'historique des échecs d'authentification.
    Peut déverrouiller les comptes et envoyer une notification.
.PARAMETER Unlock
    Déverrouille les comptes verrouillés trouvés.
.PARAMETER SearchBase
    OU de recherche spécifique (optionnel).
.PARAMETER HistoryHours
    Nombre d'heures d'historique à analyser pour les événements de verrouillage (défaut : 24).
.PARAMETER OutputPath
    Export CSV du rapport.
.PARAMETER AutoRemediate
    Déverrouille automatiquement sans demande de confirmation.
.EXAMPLE
    .\check-lockout.ps1
.EXAMPLE
    .\check-lockout.ps1 -Unlock -HistoryHours 48 -OutputPath "C:\Rapports\lockout.csv"
.NOTES
    Auteur : Hermes Agent
    Requiert : Module ActiveDirectory, EventLog (pour historique),
              privilèges de lecture des logs de sécurité
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Unlock,

    [Parameter(Mandatory = $false)]
    [string]$SearchBase,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 168)]
    [int]$HistoryHours = 24,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$AutoRemediate
)

# ---- Dépendances ----
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "Le module ActiveDirectory n'est pas installé."
    exit 1
}
Import-Module ActiveDirectory -Force

# ---- Couleurs ----
$C = @{
    Info = 'Cyan'
    OK   = 'Green'
    Warn = 'Yellow'
    Err  = 'Red'
    Box  = 'Magenta'
}

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $t = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$t] $Msg" -ForegroundColor $C[$Level]
}

Write-Host "-------------------------------------------" -ForegroundColor $C['Box']
Write-Host "  ANALYSE DES COMPTES VERROUILLÉS (Lockout)" -ForegroundColor $C['Box']
Write-Host "-------------------------------------------" -ForegroundColor $C['Box']

# ---- 1. Récupération des comptes verrouillés ----
Write-Log "[SEARCH] Recherche des comptes verrouillés..." 'Info'

$params = @{ Properties = @('DisplayName', 'Mail', 'SamAccountName', 'LockedOut',
                             'LockoutTime', 'LastLogonDate', 'BadLogonCount',
                             'BadPasswordTime', 'UserPrincipalName', 'Enabled', 'Department')
             ResultPageSize = 500 }
if ($SearchBase) { $params.SearchBase = $SearchBase }

try {
    $lockedUsers = Get-ADUser -Filter "LockedOut -eq '`$true'" @params
} catch {
    Write-Log "[ERR] Erreur de requête AD : $_" 'Err'
    exit 1
}

if ($lockedUsers.Count -eq 0) {
    Write-Log "[OK] Aucun compte verrouillé trouvé." 'OK'
    exit 0
}

Write-Log "[WARN]  $($lockedUsers.Count) compte(s) verrouillé(s) détecté(s) !" 'Warn'

# ---- 2. Détails pour chaque compte verrouillé ----
$results = foreach ($u in $lockedUsers) {
    $lockTime = if ($u.LockoutTime) {
        [System.DateTime]::FromFileTime($u.LockoutTime)
    } else { $null }

    $lastBadPwd = if ($u.BadPasswordTime -and $u.BadPasswordTime -gt 0) {
        [System.DateTime]::FromFileTime($u.BadPasswordTime)
    } else { $null }

    [PSCustomObject]@{
        Nom              = $u.DisplayName
        Login            = $u.SamAccountName
        Email            = $u.Mail
        UPN              = $u.UserPrincipalName
        VerrouilleLe     = if ($lockTime) { $lockTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'Inconnu' }
        DureeVerrouillage = if ($lockTime) {
            $d = (Get-Date) - $lockTime
            "$($d.Hours)h$($d.Minutes)m"
        } else { 'N/A' }
        TentativesEchouees = $u.BadLogonCount
        DernierMauvaisMDP = if ($lastBadPwd) { $lastBadPwd.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
        DerniereConnexion = if ($u.LastLogonDate) { $u.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Jamais' }
        EtatCompte        = if ($u.Enabled) { 'Activé' } else { 'Désactivé' }
        Service           = $u.Department
        DN                = $u.DistinguishedName
    }
}

$results | Format-Table -AutoSize -Property Nom, Login, VerrouilleLe, DureeVerrouillage, TentativesEchouees, DernierMauvaisMDP

# ---- 3. Analyse des événements de verrouillage (logs sécurité) ----
Write-Log "`n[CLIP] Analyse des événements de verrouillage (EventID 4740) sur les dernières $HistoryHours heures..." 'Info'

$since = (Get-Date).AddHours(-$HistoryHours)
$lockoutEvents = @()

try {
    # Chercher sur tous les contrôleurs de domaine
    $dcs = Get-ADDomainController | Select-Object -ExpandProperty Name
    foreach ($dc in $dcs) {
        try {
            $events = Get-WinEvent -ComputerName $dc -FilterHashtable @{
                LogName   = 'Security'
                Id        = 4740
                StartTime = $since
            } -ErrorAction SilentlyContinue | ForEach-Object {
                [PSCustomObject]@{
                    Temps  = $_.TimeCreated
                    DC     = $dc.ToUpper()
                    Message = $_.Message
                    User   = if ($_.Properties[0].Value) { $_.Properties[0].Value } else { 'Inconnu' }
                    Source = if ($_.Properties[3].Value) { $_.Properties[3].Value } else { 'Inconnue' }
                }
            }
            $lockoutEvents += $events
        } catch {
            # Pas d'événements ou accès refusé - on continue
        }
    }

    if ($lockoutEvents.Count -gt 0) {
        Write-Log "[LOCK] $($lockoutEvents.Count) événements de verrouillage trouvés (source du verrouillage) :" 'Info'
        $lockoutEvents | Group-Object User | Sort-Object Count -Descending | ForEach-Object {
            $sources = ($_.Group | Select-Object -ExpandProperty Source -Unique) -join ', '
            Write-Host "   $($_.Name) : $($_.Count) verrouillage(s) - depuis : $sources" -ForegroundColor Yellow
        }
    } else {
        Write-Log "   Aucun événement 4740 trouvé dans l'historique (vérifiez les permissions EventLog)." 'Warn'
    }
} catch {
    Write-Log "   Impossible de lire les événements de sécurité : $_" 'Warn'
}

# ---- Export CSV ----
if ($OutputPath) {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Log "[FILE] Rapport exporté vers : $OutputPath" 'OK'
}

# ---- 4. Déverrouillage ----
if ($Unlock -or $AutoRemediate) {
    if (-not $AutoRemediate) {
        $confirm = Read-Host "`n[UNLOCK] Déverrouiller ces $($lockedUsers.Count) comptes ? (O/N)"
        if ($confirm -notin @('O','o','Oui','oui','Y','y','Yes','yes')) {
            Write-Log "[STOP]  Déverrouillage annulé." 'Warn'
            exit 0
        }
    }

    $unlocked = 0
    $errors = 0
    foreach ($u in $lockedUsers) {
        if ($PSCmdlet.ShouldProcess($u.SamAccountName, 'Déverrouiller le compte')) {
            try {
                Unlock-ADAccount -Identity $u.DistinguishedName -ErrorAction Stop
                Write-Log "[UNLOCK] Déverrouillé : $($u.SamAccountName)" 'OK'
                $unlocked++
            } catch {
                Write-Log "[ERR] Échec déverrouillage $($u.SamAccountName) : $_" 'Err'
                $errors++
            }
        }
    }

    Write-Host "`n[STATS] Déverrouillage terminé : $unlocked succès, $errors erreur(s)" -ForegroundColor Cyan
} else {
    Write-Host "`n[TIP] Astuce : Ajoutez -Unlock pour déverrouiller les comptes automatiquement." -ForegroundColor Gray
}

# ---- Recommandations ----
Write-Host "`n-------------------------------------------" -ForegroundColor $C['Box']
Write-Host "  RECOMMANDATIONS" -ForegroundColor $C['Box']
Write-Host "-------------------------------------------" -ForegroundColor $C['Box']
if ($results.Count -gt 5) {
    Write-Host "  [WARN]  Nombre élevé de verrouillages - vérifiez :" -ForegroundColor Yellow
    Write-Host "     * Mot de passe compromis partagé"
    Write-Host "     * Script ou service utilisant d'anciens identifiants"
    Write-Host "     * Application avec des credentials périmés"
    Write-Host "     * Attaque par force brute"
}
Write-Host "  [INFO] Politique de verrouillage actuelle :" -ForegroundColor Gray
try {
    $pwPolicy = Get-ADDefaultDomainPasswordPolicy
    Write-Host "     * Seuil de verrouillage     : $($pwPolicy.LockoutThreshold) tentatives"
    Write-Host "     * Durée de verrouillage      : $($pwPolicy.LockoutDuration) minutes"
    Write-Host "     * Fenêtre d'observation      : $($pwPolicy.LockoutObservationWindow) minutes"
} catch {
    Write-Host "     (Impossible de lire la politique de mot de passe)"
}
Write-Host "-------------------------------------------" -ForegroundColor $C['Box']
