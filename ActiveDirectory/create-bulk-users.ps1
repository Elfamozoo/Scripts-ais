<#
.SYNOPSIS
    Crée des utilisateurs Active Directory en masse depuis un fichier CSV.
.DESCRIPTION
    Lit un fichier CSV et crée les comptes utilisateurs correspondants dans l'OU cible.
    Génère un mot de passe aléatoire par défaut (changeable à la prochaine connexion).
    Les colonnes requises : FirstName, LastName, SamAccountName, UserPrincipalName, Email.
    Colonnes optionnelles : Password, OU, Department, Title, Phone, Description, Manager, Groupes.
.PARAMETER CsvPath
    Chemin du fichier CSV source (obligatoire).
.PARAMETER DefaultPassword
    Mot de passe par défaut si non spécifié dans le CSV (défaut : "P@ssw0rd2024!").
.PARAMETER DefaultOU
    OU de création par défaut si non précisée dans le CSV.
.PARAMETER WhatIf
    Simule la création sans appliquer les changements.
.PARAMETER LogPath
    Chemin du fichier de log (optionnel).
.EXAMPLE
    .\create-bulk-users.ps1 -CsvPath "C:\import\nouveaux-users.csv" -DefaultOU "OU=Employes,DC=domaine,DC=fr"
.EXAMPLE
    .\create-bulk-users.ps1 -CsvPath "users.csv" -WhatIf
.NOTES
    Auteur : Hermes Agent
    Requiert : Module ActiveDirectory, privilèges de création AD
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [string]$DefaultPassword = 'P@ssw0rd2024!',

    [Parameter(Mandatory = $false)]
    [string]$DefaultOU,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

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
    Write-Host $line -ForegroundColor @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERR = 'Red' }[$level]
    if ($LogPath) { Add-Content -Path $LogPath -Value $line }
}

# ---- Lecture du CSV ----
if (-not (Test-Path $CsvPath)) {
    &$log "Fichier CSV introuvable : $CsvPath" 'ERR'
    exit 1
}

$users = Import-Csv -Path $CsvPath -Encoding UTF8
&$log "📄 $($users.Count) utilisateurs chargés depuis $CsvPath" 'INFO'

# ---- Validation des colonnes ----
$required = @('FirstName', 'LastName', 'SamAccountName')
$missing = $required | Where-Object { $_ -notin $users[0].PSObject.Properties.Name }
if ($missing) {
    &$log "Colonnes requises manquantes dans le CSV : $($missing -join ', ')" 'ERR'
    exit 1
}

# ---- Stats ----
$stats = @{ Cree = 0; Existe = 0; Erreur = 0; Ignore = 0 }

# ---- Boucle de création ----
foreach ($u in $users) {
    $sam   = $u.SamAccountName.Trim()
    $fname = $u.FirstName.Trim()
    $lname = $u.LastName.Trim()
    $upn   = if ($u.UserPrincipalName) { $u.UserPrincipalName } else { "$($sam)@$( (Get-ADDomain).DNSRoot )" }
    $email = if ($u.Email) { $u.Email } else { $upn }

    $displayName = "$fname $lname"
    $ou = if ($u.OU) { $u.OU.Trim() } else { $DefaultOU }

    # Vérifier si l'utilisateur existe déjà
    try {
        $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction Stop
        if ($existing) {
            &$log "⏭️  $sam existe déjà (DN: $($existing.DistinguishedName))" 'WARN'
            $stats.Existe++
            continue
        }
    } catch { }

    # Mot de passe
    $pwd = if ($u.Password) { $u.Password } else { $DefaultPassword }
    $securePwd = ConvertTo-SecureString -String $pwd -AsPlainText -Force

    # Paramètres de création
    $params = @{
        Name                 = $sam
        SamAccountName       = $sam
        UserPrincipalName    = $upn
        GivenName            = $fname
        Surname              = $lname
        DisplayName          = $displayName
        EmailAddress         = $email
        AccountPassword      = $securePwd
        Enabled              = $true
        ChangePasswordAtLogon = $true
        PassThru             = $true
        ErrorAction          = 'Stop'
    }

    if ($ou) { $params.Path = $ou }
    if ($u.Department)  { $params.Department = $u.Department.Trim() }
    if ($u.Title)       { $params.Title = $u.Title.Trim() }
    if ($u.Phone)       { $params.PhoneNumber = $u.Phone.Trim() }
    if ($u.Description) { $params.Description = $u.Description.Trim() }
    if ($u.Office)      { $params.Office = $u.Office.Trim() }
    if ($u.Company)     { $params.Company = $u.Company.Trim() }

    if ($u.Manager) {
        try {
            $mgr = Get-ADUser -Filter "SamAccountName -eq '$($u.Manager.Trim())'" -ErrorAction Stop
            $params.Manager = $mgr.DistinguishedName
        } catch {
            &$log "⚠️  Manager '$($u.Manager)' introuvable pour $sam" 'WARN'
        }
    }

    # WhatIf ou création réelle
    if ($WhatIf) {
        &$log "🔍 [SIMULATION] Création de $sam ($displayName) dans $ou" 'INFO'
        $stats.Cree++
        continue
    }

    try {
        $newUser = New-ADUser @params
        &$log "✅ $sam ($displayName) créé avec succès" 'OK'
        $stats.Cree++

        # Ajout aux groupes (colonne Groupes = nom séparé par point-virgule)
        if ($u.Groupes) {
            $groupes = $u.Groupes -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            foreach ($g in $groupes) {
                try {
                    Add-ADGroupMember -Identity $g -Members $sam -ErrorAction Stop
                    &$log "   ➕ $sam ajouté au groupe $g" 'OK'
                } catch {
                    &$log "   ⚠️  Échec ajout groupe $g pour $sam : $_" 'WARN'
                }
            }
        }
    } catch {
        &$log "❌ Échec création $sam : $_" 'ERR'
        $stats.Erreur++
    }
}

# ---- Résumé final ----
Write-Host "`n═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  RÉSULTAT DE L'IMPORT EN MASSE" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Créés      : $($stats.Cree)"
Write-Host "  Déjà existants : $($stats.Existe)"
Write-Host "  Erreurs    : $($stats.Erreur)"
if ($WhatIf) { Write-Host "  [MODE SIMULATION - aucune modification réelle]" -ForegroundColor Yellow }
Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
