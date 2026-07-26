# Scripts-AIS 🛠️

> Collection de scripts PowerShell pour technicien systèmes et réseaux
> Par Illyes Zerga — Formation AIS (Administrateur Infrastructures Sécurisé)

---

## 📂 Structure

```
📁 Scripts-AIS/
├── 📁 Reseau/           # Outils réseau
├── 📁 ActiveDirectory/   # Gestion Active Directory
├── 📁 WindowsServer/    # Administration Windows Server
├── 📁 Securite/         # Sécurité et audit
├── 📁 Inventaire/       # Inventaire et reporting
└── README.md
```

---

## 🌐 Réseau

| Script | Description |
|---|---|
| `ping-sweep.ps1` | Ping toute une plage IP et liste les machines actives |
| `port-scan.ps1` | Scan les ports courants d'une machine distante |
| `dns-lookup.ps1` | Interroge les enregistrements DNS (A, MX, CNAME, NS) |
| `traceroute-automated.ps1` | Trace la route vers une cible et exporte le résultat |
| `network-inventory.ps1` | Inventaire réseau : IP, MAC, hostname |
| `network-reset.ps1` | Réinitialisation complète de la stack réseau |

## 👥 Active Directory

| Script | Description |
|---|---|
| `list-users.ps1` | Liste tous les utilisateurs AD (nom, email, groupe, état) |
| `create-bulk-users.ps1` | Création en masse depuis un fichier CSV |
| `disable-inactive-users.ps1` | Désactive les comptes inactifs depuis +90 jours |
| `check-lockout.ps1` | Identifie les verrouillages de comptes |
| `ad-audit.ps1` | Rapport AD complet : users, groupes, ordinateurs |
| `move-users-ou.ps1` | Déplace des utilisateurs vers une OU cible |

## 🖥️ Windows Server

| Script | Description |
|---|---|
| `check-services.ps1` | Vérifie l'état des services critiques |
| `eventlog-errors.ps1` | Extrait les erreurs des logs des dernières 24h |
| `disk-space-report.ps1` | Rapport d'espace disque (local et distant) |
| `update-status.ps1` | Vérifie l'état des mises à jour |
| `backup-config.ps1` | Sauvegarde la configuration DHCP, DNS, IIS |
| `scheduled-tasks-report.ps1` | Liste toutes les tâches planifiées |

## 🔒 Sécurité

| Script | Description |
|---|---|
| `failed-logins.ps1` | Analyse les tentatives de connexion échouées |
| `usb-history.ps1` | Historique des périphériques USB branchés |
| `local-admin-check.ps1` | Vérifie qui est administrateur local |
| `firewall-rules-export.ps1` | Exporte les règles du pare-feu Windows |
| `rdp-brute-check.ps1` | Détection d'attaques brute-force RDP |
| `harden-windows.ps1` | Durcissement de la sécurité Windows |

## 📊 Inventaire

| Script | Description |
|---|---|
| `machine-inventory.ps1` | Inventaire complet CPU, RAM, disques, OS, IP |
| `installed-software.ps1` | Liste des logiciels installés |
| `uptime-report.ps1` | Uptime des serveurs |

---

## 🚀 Utilisation

```powershell
# Exécuter un script
.\Reseau\port-scan.ps1 -Target 192.168.1.1

# Aide intégrée
Get-Help .\Reseau\port-scan.ps1

# Scanner un réseau
.\Reseau\ping-sweep.ps1 -Subnet 192.168.1

# Audit AD complet
.\ActiveDirectory\ad-audit.ps1 -ExportCSV

# Vérifier les tentatives de connexion
.\Securite\failed-logins.ps1 -Hours 24 -Threshold 5

# Inventaire machine distante
.\Inventaire\machine-inventory.ps1 -ComputerName SRV-DC01

# Durcissement strict
.\Securite\harden-windows.ps1 -Level Strict
```

---

## 📋 Prérequis

- Windows 10/11 ou Windows Server 2019/2022
- PowerShell 5.1 ou PowerShell 7+
- Droits administrateur pour certains scripts
- Module Active Directory pour les scripts AD (`Install-WindowsFeature RSAT-AD-PowerShell`)

---

## 📖 À propos

Scripts créés dans le cadre de ma formation **AIS (Administrateur Infrastructures Sécurisé)**.
Utilisables librement pour vos audits, déploiements et administration au quotidien.

**Illyes Zerga** — [GitHub](https://github.com/Elfamozoo)
