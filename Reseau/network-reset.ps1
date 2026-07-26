<#
.SYNOPSIS
    Réinitialisation complète de la pile réseau Windows.
.DESCRIPTION
    Réinitialise : Winsock, DNS (cache + paramètres), IP (release/renew/reset),
    et le pare-feu Windows. Nécessite des privilèges administrateur.
.PARAMETER ResetWinsock
    Réinitialiser Winsock (défaut: $true)
.PARAMETER ResetDNS
    Réinitialiser le cache DNS (défaut: $true)
.PARAMETER ResetIP
    Réinitialiser la pile TCP/IP (défaut: $false)
.PARAMETER ResetFirewall
    Réinitialiser le pare-feu Windows aux valeurs par défaut (défaut: $false)
.PARAMETER ReleaseRenew
    Exécuter ipconfig /release et /renew sur toutes les interfaces (défaut: $true)
.PARAMETER FlushARP
    Vider le cache ARP (défaut: $false)
.PARAMETER ResetNBT
    Réinitialiser NetBIOS (défaut: $false)
.PARAMETER RestartAdapter
    Redémarrer les adaptateurs réseau (défaut: $false)
.PARAMETER AdapterName
    Nom de l'adaptateur à redémarrer (optionnel, tous si vide)
.PARAMETER LogPath
    Chemin du fichier de log (optionnel)
.PARAMETER AutoConfirm
    Ignorer les confirmations (défaut: $false)
.EXAMPLE
    .\network-reset.ps1 -AutoConfirm
    .\network-reset.ps1 -ResetWinsock -ResetDNS -ReleaseRenew -LogPath "reset.log"
    .\network-reset.ps1 -ResetAll
#>

param(
    [bool]$ResetWinsock  = $true,
    [bool]$ResetDNS      = $true,
    [bool]$ResetIP       = $false,
    [bool]$ResetFirewall = $false,
    [bool]$ReleaseRenew  = $true,
    [bool]$FlushARP      = $false,
    [bool]$ResetNBT      = $false,
    [bool]$RestartAdapter = $false,
    [string]$AdapterName = "",
    [string]$LogPath     = "",
    [bool]$AutoConfirm   = $false
)

# Vérifier les privilèges administrateur
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Ce script nécessite des privilèges Administrateur !"
    Write-Warning "Veuillez relancer PowerShell en tant qu'Administrateur."
    exit 1
}

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
    if ($LogPath) {
        "[$timestamp] $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
    }
}

function Show-Banner {
    Clear-Host
    Write-Host @"

╔══════════════════════════════════════════════════════╗
║         RÉINITIALISATION RÉSEAU WINDOWS              ║
║         network-reset.ps1                            ║
╚══════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan
    Write-Host "Privilèges : Administrateur [✓]" -ForegroundColor Green
    Write-Host ""

    $checks = @()
    if ($ResetWinsock)  { $checks += "Winsock" }
    if ($ResetDNS)      { $checks += "Cache DNS" }
    if ($ResetIP)       { $checks += "Pile TCP/IP" }
    if ($ResetFirewall) { $checks += "Pare-feu" }
    if ($ReleaseRenew)  { $checks += "IP Release/Renew" }
    if ($FlushARP)      { $checks += "Cache ARP" }
    if ($ResetNBT)      { $checks += "NetBIOS" }
    if ($RestartAdapter){ $checks += "Redémarrage adaptateur" }

    Write-Host "Opérations planifiées :" -ForegroundColor Yellow
    $checks | ForEach-Object { Write-Host "  • $_" -ForegroundColor White }
    Write-Host ""
}

function Do-WinsockReset {
    Write-Log "Réinitialisation de Winsock..." "Cyan"
    try {
        $result = netsh winsock reset
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  ✓ Winsock réinitialisé avec succès" "Green"
            return $true
        } else {
            Write-Log "  ✗ Erreur lors de la réinitialisation Winsock" "Red"
            return $false
        }
    } catch {
        Write-Log "  ✗ Exception: $_" "Red"
        return $false
    }
}

function Do-DNSReset {
    Write-Log "Réinitialisation du cache DNS..." "Cyan"
    try {
        $result = ipconfig /flushdns
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  ✓ Cache DNS vidé avec succès" "Green"
            # Vider le cache DNS du client aussi
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            Write-Log "  ✓ Cache DNS Client vidé" "Green"
            return $true
        } else {
            Write-Log "  ✗ Erreur lors du vidage du cache DNS" "Red"
            return $false
        }
    } catch {
        Write-Log "  ✗ Exception: $_" "Red"
        return $false
    }
}

function Do-IPReset {
    Write-Log "Réinitialisation de la pile TCP/IP..." "Cyan"
    $success = $true
    try {
        # Réinitialisation complète de la pile TCP/IP
        $commands = @(
            "netsh int ip reset",
            "netsh int tcp reset",
            "netsh int ipv4 reset",
            "netsh int ipv6 reset"
        )
        foreach ($cmd in $commands) {
            Write-Log "  Exécution: $cmd" "Gray"
            $result = cmd /c "$cmd 2>&1"
            if ($LASTEXITCODE -ne 0) {
                Write-Log "  ⚠ Avertissement pour: $cmd" "Yellow"
                $success = $false
            }
        }
        if ($success) {
            Write-Log "  ✓ Pile TCP/IP réinitialisée" "Green"
        }
    } catch {
        Write-Log "  ✗ Exception: $_" "Red"
        $success = $false
    }
    return $success
}

function Do-ReleaseRenew {
    Write-Log "Libération et renouvellement des adresses IP..." "Cyan"
    $success = $true

    try {
        $result = ipconfig /release
        Write-Log "  ✓ ipconfig /release exécuté" "Green"
    } catch {
        Write-Log "  ⚠ Erreur ipconfig /release" "Yellow"
        $success = $false
    }

    Start-Sleep -Seconds 2

    try {
        $result = ipconfig /renew
        Write-Log "  ✓ ipconfig /renew exécuté" "Green"
    } catch {
        Write-Log "  ⚠ Erreur ipconfig /renew" "Yellow"
        $success = $false
    }

    return $success
}

function Do-FirewallReset {
    Write-Log "Réinitialisation du Pare-feu Windows..." "Cyan"
    $success = $true
    try {
        # Sauvegarde de la politique actuelle
        $backupFile = "$env:TEMP\firewall-backup-$((Get-Date).ToString('yyyyMMdd-HHmmss')).wfw"
        Write-Log "  Sauvegarde de la configuration: $backupFile" "Gray"
        netsh advfirewall export $backupFile 2>$null

        # Réinitialisation
        $result = netsh advfirewall reset
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  ✓ Pare-feu réinitialisé aux valeurs par défaut" "Green"
            Write-Log "  ⚠ Sauvegarde disponible: $backupFile" "Yellow"

            # Activer le pare-feu pour tous les profils
            netsh advfirewall set allprofiles state on 2>$null
            Write-Log "  ✓ Pare-feu activé pour tous les profils" "Green"
        } else {
            Write-Log "  ✗ Erreur lors de la réinitialisation du pare-feu" "Red"
            $success = $false
        }
    } catch {
        Write-Log "  ✗ Exception: $_" "Red"
        $success = $false
    }
    return $success
}

function Do-FlushARP {
    Write-Log "Vidage du cache ARP..." "Cyan"
    try {
        $result = netsh interface ip delete arpcache
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  ✓ Cache ARP vidé avec succès" "Green"
            return $true
        } else {
            Write-Log "  ✗ Erreur lors du vidage du cache ARP" "Red"
            return $false
        }
    } catch {
        Write-Log "  ✗ Exception: $_" "Red"
        return $false
    }
}

function Do-NBTReset {
    Write-Log "Réinitialisation de NetBIOS..." "Cyan"
    try {
        $result = nbtstat -R
        Write-Log "  ✓ Cache NetBIOS vidé (nbtstat -R)" "Green"
        $result = nbtstat -RR
        Write-Log "  ✓ Noms NetBIOS relâchés/renouvelés (nbtstat -RR)" "Green"
        return $true
    } catch {
        Write-Log "  ✗ Erreur: $_" "Red"
        return $false
    }
}

function Do-AdapterRestart {
    Write-Log "Redémarrage des adaptateurs réseau..." "Cyan"
    $success = $true

    $adapters = if ($AdapterName) {
        Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    } else {
        Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    }

    if (-not $adapters) {
        Write-Log "  ⚠ Aucun adaptateur trouvé à redémarrer" "Yellow"
        return $false
    }

    foreach ($adapter in $adapters) {
        try {
            Write-Log "  Redémarrage de: $($adapter.Name)..." "Gray"
            Restart-NetAdapter -Name $adapter.Name -Confirm:$false
            Write-Log "  ✓ $($adapter.Name) redémarré" "Green"
            Start-Sleep -Seconds 3
        } catch {
            Write-Log "  ✗ Erreur pour $($adapter.Name): $_" "Red"
            $success = $false
        }
    }
    return $success
}

function Show-Summary {
    param($Results)

    Write-Host ""
    Write-Log "═══════════════════════════════════════════" "Cyan"
    Write-Log "         RÉSUMÉ DES OPÉRATIONS" "Cyan"
    Write-Log "═══════════════════════════════════════════" "Cyan"

    $successCount = ($Results.Values | Where-Object { $_ -eq $true }).Count
    $failCount    = ($Results.Values | Where-Object { $_ -eq $false }).Count

    foreach ($op in $Results.Keys) {
        $status = if ($Results[$op]) { "✓" } else { "✗" }
        $color  = if ($Results[$op]) { "Green" } else { "Red" }
        Write-Log "  $status $op" $color
    }

    Write-Host ""
    if ($failCount -eq 0) {
        Write-Log "✅ Toutes les opérations ont réussi !" "Green"
        Write-Log "Il est recommandé de redémarrer l'ordinateur." "Yellow"
    } else {
        Write-Log "⚠ $failCount opération(s) ont échoué." "Yellow"
        Write-Log "Vérifiez les logs pour plus de détails." "Yellow"
    }
    Write-Log "═══════════════════════════════════════════" "Cyan"
}

# ===== MAIN =====

Show-Banner

# Demander confirmation
if (-not $AutoConfirm) {
    Write-Host "ATTENTION : Certaines opérations vont interrompre" -ForegroundColor Red
    Write-Host "la connectivité réseau temporairement." -ForegroundColor Red
    Write-Host ""
    $conf = Read-Host "Voulez-vous continuer ? (O/N)"
    if ($conf -ne "O" -and $conf -ne "o" -and $conf -ne "Oui" -and $conf -ne "oui") {
        Write-Log "Opération annulée par l'utilisateur." "Yellow"
        exit 0
    }
}

Write-Log "Début des opérations de réinitialisation réseau..." "Cyan"
Write-Log ""

$results = @{}

if ($LogPath) {
    # Initialiser le fichier de log
    "═══════════════════════════════════════════" | Out-File -FilePath $LogPath -Encoding UTF8
    "Réinitialisation réseau - $(Get-Date)" | Out-File -FilePath $LogPath -Append -Encoding UTF8
    "═══════════════════════════════════════════" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

# 1. Winsock
if ($ResetWinsock) {
    $results["Winsock"] = Do-WinsockReset
    Write-Host ""
}

# 2. Cache DNS
if ($ResetDNS) {
    $results["Cache DNS"] = Do-DNSReset
    Write-Host ""
}

# 3. IP Release/Renew
if ($ReleaseRenew) {
    $results["IP Release/Renew"] = Do-ReleaseRenew
    Write-Host ""
}

# 4. Cache ARP
if ($FlushARP) {
    $results["Cache ARP"] = Do-FlushARP
    Write-Host ""
}

# 5. NetBIOS
if ($ResetNBT) {
    $results["NetBIOS"] = Do-NBTReset
    Write-Host ""
}

# 6. Pile TCP/IP
if ($ResetIP) {
    $results["Pile TCP/IP"] = Do-IPReset
    Write-Host ""
}

# 7. Pare-feu
if ($ResetFirewall) {
    $results["Pare-feu"] = Do-FirewallReset
    Write-Host ""
}

# 8. Redémarrage adaptateur
if ($RestartAdapter) {
    $results["Redémarrage adaptateur"] = Do-AdapterRestart
    Write-Host ""
}

Write-Host ""
Show-Summary -Results $results

Write-Host ""
Write-Log "Opérations terminées." "Cyan"
if ($LogPath) {
    Write-Log "Log sauvegardé: $LogPath" "Yellow"
}
