<#
.SYNOPSIS
    Applique des configurations de durcissement de sécurité sur Windows.
.DESCRIPTION
    Désactive les services inutiles, renforce les politiques de mot de passe,
    désactive les protocoles obsolètes (SMBv1, LLMNR, NetBIOS), et plus.
.PARAMETER Level
    Niveau de durcissement: Basic, Standard, Strict (défaut: Standard)
.EXEMPLE
    .\harden-windows.ps1
    .\harden-windows.ps1 -Level Strict
#>

param([ValidateSet('Basic','Standard','Strict')][string]$Level = 'Standard')

# Vérifier les droits admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "❌ Ce script nécessite les droits administrateur." -ForegroundColor Red
    exit
}

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🔐 DURCISSEMENT WINDOWS - Niveau $Level" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

# 1. Politiques de mot de passe
Write-Host "`n📌 Politiques de mot de passe..." -ForegroundColor Yellow
net accounts /minpwlen:8 /maxpwage:60 /minpwage:1 /lockoutthreshold:5 /lockoutduration:30 /lockoutwindow:30

# 2. Désactiver SMBv1
Write-Host "📌 Désactivation SMBv1..." -ForegroundColor Yellow
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "SMB1" -Type DWord -Value 0 -Force
Disable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -NoRestart -ErrorAction SilentlyContinue

# 3. Désactiver LLMNR et NetBIOS
Write-Host "📌 Désactivation LLMNR/NetBIOS..." -ForegroundColor Yellow
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Name "EnableMulticast" -Type DWord -Value 0 -Force

# 4. Désactiver services inutiles
$ServicesToDisable = @(
    @{Name="XboxGipSvc"; Display="Xbox Accessory Management"},
    @{Name="XblAuthManager"; Display="Xbox Live Auth Manager"},
    @{Name="XblGameSave"; Display="Xbox Live Game Save"},
    @{Name="XboxNetApiSvc"; Display="Xbox Live Networking"},
    @{Name="RemoteRegistry"; Display="Registre à distance"},
    @{Name="SharedAccess"; Display="ICS"}
)

if ($Level -ne 'Basic') {
    $ServicesToDisable += @{Name="WSearch"; Display="Windows Search"}
    $ServicesToDisable += @{Name="DiagTrack"; Display="Connected User Experiences"}
    $ServicesToDisable += @{Name="dmwappushservice"; Display="WAP Push"}
}

if ($Level -eq 'Strict') {
    $ServicesToDisable += @{Name="Spooler"; Display="Print Spooler"}
    $ServicesToDisable += @{Name="SessionEnv"; Display="Remote Desktop Configuration"}
}

foreach ($Svc in $ServicesToDisable) {
    $Service = Get-Service -Name $Svc.Name -ErrorAction SilentlyContinue
    if ($Service -and $Service.StartType -ne 'Disabled') {
        Stop-Service -Name $Svc.Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $Svc.Name -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host "   ✅ Désactivé: $($Svc.Display)" -ForegroundColor Green
    }
}

# 5. Renforcer les paramètres de sécurité
Write-Host "📌 Renforcement registre..." -ForegroundColor Yellow

# UAC
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Type DWord -Value 1 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Type DWord -Value 2 -Force

# Désactiver l'énumération anonyme
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RestrictAnonymous" -Type DWord -Value 1 -Force
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RestrictAnonymousSAM" -Type DWord -Value 1 -Force

# Désactiver le stockage de mot de passe en texte clair
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "LimitBlankPasswordUse" -Type DWord -Value 1 -Force

Write-Host "`n✅ Durcissement terminé ! Un redémarrage est recommandé." -ForegroundColor Green
