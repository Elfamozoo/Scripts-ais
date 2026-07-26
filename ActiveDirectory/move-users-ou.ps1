<#
.SYNOPSIS
    Déplace des utilisateurs AD d'une OU source vers une OU cible.
.DESCRIPTION
    Permet de déplacer des utilisateurs entre unités d'organisation (OU).
    Supporte le déplacement par liste CSV, par fichier de logins (txt), par filtre,
    ou par OU source complète.
    En mode WhatIf, simule le déplacement sans appliquer les changements.
.PARAMETER SourceOU
    OU source (DN) pour déplacer tous les utilisateurs qu'elle contient.
.PARAMETER TargetOU
    OU cible (DN) de destination.
.PARAMETER UserList
    Chemin d'un fichier texte contenant les SamAccountName (un par ligne).
.PARAMETER CsvPath
    Chemin d'un fichier CSV contenant les utilisateurs à déplacer.
    Colonne attendue : SamAccountName (ou Login).
.PARAMETER UserFilter
    Filtre LDAP pour sélectionner les utilisateurs (ex: "Department -eq 'Ventes'").
    Utilisé uniquement avec SourceOU.
.PARAMETER LogPath
    Chemin du fichier de log.
.PARAMETER WhatIf
    Simule le déplacement sans l'appliquer (recommandé avant exécution).
.PARAMETER CreateLogFile
    Crée un rapport CSV des déplacements effectués.
.EXAMPLE
    .\move-users-ou.ps1 -SourceOU "OU=Anciens,DC=domaine,DC=fr" -TargetOU "OU=Archives,DC=domaine,DC=fr"
.EXAMPLE
    .\move-users-ou.ps1 -UserList "C:\users-a-deplacer.txt" -TargetOU "OU=NouveauService,DC=domaine,DC=fr" -WhatIf
.EXAMPLE
    .\move-users-ou.ps1 -SourceOU "OU=DepartementA,DC=domaine,DC=fr" -TargetOU "OU=DepartementB,DC=domaine,DC=fr" -UserFilter "Department -eq 'Ventes'"
.NOTES
    Auteur : Hermes Agent
    Requiert : Module ActiveDirectory, privilèges de modification AD
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ByOU')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ByOU')]
    [string]$SourceOU,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByList')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$UserList,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByCSV')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({
        try {
            [adsi]"LDAP://$_"
            $true
        } catch {
            throw "OU cible invalide ou inaccessible : $_"
        }
    })]
    [string]$TargetOU,

    [Parameter(Mandatory = $false)]
    [string]$UserFilter,

    [Parameter(Mandatory = $false)]
    [string]$LogPath,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [switch]$CreateLogFile
)

# ---- Dépendances ----
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "Le module ActiveDirectory n'est pas installé."
    exit 1
}
Import-Module ActiveDirectory -Force

# ---- Fonction de log ----
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Msg"
    switch ($Level) {
        'OK'   { Write-Host $line -ForegroundColor Green }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERR'  { Write-Host $line -ForegroundColor Red }
        'INFO' { Write-Host $line -ForegroundColor Gray }
    }
    if ($LogPath) { Add-Content -Path $LogPath -Value $line }
}

# ---- Récupération de la liste des utilisateurs ----
$usersToMove = @()

switch ($PSCmdlet.ParameterSetName) {
    'ByOU' {
        Write-Log "[SEARCH] Recherche des utilisateurs dans : $SourceOU" 'INFO'
        $splat = @{
            Filter        = if ($UserFilter) { $UserFilter } else { '*' }
            SearchBase    = $SourceOU
            SearchScope   = 'OneLevel'
            Properties    = @('DisplayName', 'SamAccountName', 'Mail', 'Department', 'Title', 'DistinguishedName')
            ResultPageSize = 500
        }
        $usersToMove = Get-ADUser @splat
        Write-Log "[DIR] $($usersToMove.Count) utilisateur(s) trouvé(s) dans l'OU source" 'INFO'
    }
    'ByList' {
        Write-Log "[FILE] Lecture de la liste depuis : $UserList" 'INFO'
        $logins = Get-Content -Path $UserList | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' }
        foreach ($login in $logins) {
            try {
                $user = Get-ADUser -Identity $login -Properties DisplayName, SamAccountName, Mail, Department, Title, DistinguishedName -ErrorAction Stop
                $usersToMove += $user
            } catch {
                Write-Log "[WARN]  Utilisateur '$login' introuvable dans AD" 'WARN'
            }
        }
        Write-Log "[DIR] $($usersToMove.Count) utilisateur(s) chargé(s) depuis la liste" 'INFO'
    }
    'ByCSV' {
        Write-Log "[FILE] Lecture du CSV depuis : $CsvPath" 'INFO'
        $csvUsers = Import-Csv -Path $CsvPath -Encoding UTF8

        # Déterminer la colonne contenant le login
        $loginCol = if ('SamAccountName' -in $csvUsers[0].PSObject.Properties.Name) {
            'SamAccountName'
        } elseif ('Login' -in $csvUsers[0].PSObject.Properties.Name) {
            'Login'
        } elseif ('Username' -in $csvUsers[0].PSObject.Properties.Name) {
            'Username'
        } else {
            $null
        }

        if (-not $loginCol) {
            Write-Log "[ERR] Colonne 'SamAccountName' ou 'Login' introuvable dans le CSV" 'ERR'
            exit 1
        }

        foreach ($row in $csvUsers) {
            $login = $row.$loginCol.Trim()
            try {
                $user = Get-ADUser -Identity $login -Properties DisplayName, SamAccountName, Mail, Department, Title, DistinguishedName -ErrorAction Stop
                $usersToMove += $user
            } catch {
                Write-Log "[WARN]  Utilisateur '$login' introuvable dans AD" 'WARN'
            }
        }
        Write-Log "[DIR] $($usersToMove.Count) utilisateur(s) chargé(s) depuis le CSV" 'INFO'
    }
}

# ---- Vérification ----
if ($usersToMove.Count -eq 0) {
    Write-Log "[ERR] Aucun utilisateur à déplacer." 'ERR'
    exit 0
}

# ---- Vérifier que les utilisateurs ne sont pas déjà dans la cible ----
$alreadyThere = @()
foreach ($u in $usersToMove) {
    $parentOU = $u.DistinguishedName.Substring($u.DistinguishedName.IndexOf(',') + 1)
    if ($parentOU -eq $TargetOU) {
        $alreadyThere += $u
    }
}
$usersToMove = $usersToMove | Where-Object { $_ -notin $alreadyThere }

if ($alreadyThere.Count -gt 0) {
    Write-Log "[SKIP]  $($alreadyThere.Count) utilisateur(s) déjà dans l'OU cible (ignorés)" 'WARN'
}

# ---- Afficher les utilisateurs à déplacer ----
$displayData = $usersToMove | Select-Object @{N='Nom';E={$_.DisplayName}},
                                             @{N='Login';E={$_.SamAccountName}},
                                             @{N='Email';E={$_.Mail}},
                                             @{N='Service';E={$_.Department}},
                                             @{N='OU_Actuelle';E={
                                                $dn = $_.DistinguishedName
                                                $dn.Substring($dn.IndexOf(',') + 1)
                                             }}

Write-Host "`n[CLIP] Utilisateurs à déplacer vers : $TargetOU" -ForegroundColor Cyan
$displayData | Format-Table -AutoSize -Property Nom, Login, Email, Service

Write-Host "  Total : $($usersToMove.Count) utilisateur(s)" -ForegroundColor Cyan

# ---- Confirmation ----
if (-not $WhatIf) {
    $confirm = Read-Host "`n[MOVE] Confirmer le déplacement de ces $($usersToMove.Count) utilisateurs ? (O/N)"
    if ($confirm -notin @('O','o','Oui','oui','Y','y','Yes','yes')) {
        Write-Log "[STOP]  Déplacement annulé par l'utilisateur." 'WARN'
        exit 0
    }
}

# ---- Exécution du déplacement ----
$moved = 0
$errors = 0
$logEntries = @()

foreach ($u in $usersToMove) {
    $sourceDN = $u.DistinguishedName
    $login    = $u.SamAccountName
    $name     = $u.DisplayName

    if ($PSCmdlet.ShouldProcess($login, "Déplacer vers $TargetOU")) {
        if ($WhatIf) {
            Write-Log "[SEARCH] [SIMULATION] Déplacement de $login ($name) vers $TargetOU" 'INFO'
            $moved++
            continue
        }

        try {
            Move-ADObject -Identity $sourceDN -TargetPath $TargetOU -ErrorAction Stop
            Write-Log "[OK] $login ($name) déplacé vers $TargetOU" 'OK'
            $moved++

            $logEntries += [PSCustomObject]@{
                Login     = $login
                Nom       = $name
                Email     = $u.Mail
                SourceDN  = $sourceDN
                TargetOU  = $TargetOU
                Date      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                Statut    = 'Déplacé'
            }
        } catch {
            Write-Log "[ERR] Échec déplacement $login ($name) : $_" 'ERR'
            $errors++
            $logEntries += [PSCustomObject]@{
                Login     = $login
                Nom       = $name
                Email     = $u.Mail
                SourceDN  = $sourceDN
                TargetOU  = $TargetOU
                Date      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                Statut    = "Erreur : $_"
            }
        }
    }
}

# ---- Rapport CSV ----
if ($CreateLogFile -and $logEntries.Count -gt 0) {
    $reportPath = "move-users-report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $logEntries | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
    Write-Log "[FILE] Rapport détaillé : $reportPath" 'OK'
}

# ---- Résumé final ----
Write-Host "`n-------------------------------------------" -ForegroundColor Cyan
Write-Host "  RÉSULTAT DÉPLACEMENT" -ForegroundColor Cyan
Write-Host "-------------------------------------------" -ForegroundColor Cyan
Write-Host "  Source   : $SourceOU" -ForegroundColor Gray
Write-Host "  Cible    : $TargetOU" -ForegroundColor Gray
Write-Host "  Déplacés : $moved" -ForegroundColor Green
Write-Host "  Erreurs  : $errors" -ForegroundColor Red
if ($WhatIf) {
    Write-Host "  [MODE SIMULATION - aucun déplacement réel]" -ForegroundColor Yellow
}
Write-Host "-------------------------------------------" -ForegroundColor Cyan
