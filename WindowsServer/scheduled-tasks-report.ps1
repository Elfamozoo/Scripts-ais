<#
.SYNOPSIS
    Rapport complet des tâches planifiées Windows (état, dernière exécution, prochaine exécution).
.DESCRIPTION
    Liste toutes les tâches planifiées via le Schedule.Service COM object.
    Pour chaque tâche : nom, statut (Enabled/Disabled), chemin, dernière exécution,
    prochaine exécution, résultat, et auteur. Génère un rapport HTML avec
    filtrage par dossier et détection des tâches en échec.
.PARAMETER ComputerName
    Serveur cible (par défaut : localhost).
.PARAMETER TaskPath
    Chemin racine dans le Task Scheduler (défaut : "\").
.PARAMETER IncludeDisabled
    Inclure les tâches désactivées (défaut : $true).
.PARAMETER FailedThreshold
    Nombre d'échecs consécutifs pour alerte (défaut : 3).
.PARAMETER OutputPath
    Chemin du rapport HTML (défaut : ./scheduled-tasks-report.html).
.PARAMETER CsvPath
    Chemin du fichier CSV (facultatif).
.PARAMETER ExportFailedOnly
    N'exporter que les tâches en échec (défaut : $false).
.EXAMPLE
    .\scheduled-tasks-report.ps1
    .\scheduled-tasks-report.ps1 -ComputerName SRV-DC-01 -TaskPath "\Microsoft\"
    .\scheduled-tasks-report.ps1 -ExportFailedOnly -CsvPath C:\Rapports\tasks-failed.csv
.NOTES
    Auteur: Scripts-ais
    Version: 1.0
    Utilise: Schedule.Service (COM) - disponible sur tous les Windows récents.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory=$false)]
    [string]$TaskPath = "\",

    [Parameter(Mandatory=$false)]
    [bool]$IncludeDisabled = $true,

    [Parameter(Mandatory=$false)]
    [int]$FailedThreshold = 3,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\scheduled-tasks-report.html",

    [Parameter(Mandatory=$false)]
    [string]$CsvPath = "",

    [Parameter(Mandatory=$false)]
    [switch]$ExportFailedOnly = $false
)

# ---------- Fonctions ----------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Get-TaskFolderRecursive {
    param(
        [__ComObject]$TaskService,
        [string]$FolderPath
    )
    try {
        $folder = $TaskService.GetFolder($FolderPath)
        $allTasks = @()

        # Tâches dans le dossier courant
        $tasks = $folder.GetTasks(1)  # 1 = TASK_ENUM_HIDDEN
        foreach ($task in $tasks) {
            $taskXml = [xml]$task.Xml
            $taskObj = [PSCustomObject]@{
                TaskName        = $task.Name
                TaskPath        = $task.Path
                Enabled         = $task.Enabled
                State           = switch ($task.State) {
                    0 { "Unknown" }
                    1 { "Disabled" }
                    2 { "Queued" }
                    3 { "Ready" }
                    4 { "Running" }
                    default { "Unknown" }
                }
                LastRunTime     = if ($task.LastRunTime -gt '1900-01-01') { $task.LastRunTime } else { $null }
                LastTaskResult  = $task.LastTaskResult
                NextRunTime     = if ($task.NextRunTime -gt '1900-01-01') { $task.NextRunTime } else { $null }
                Author          = $taskXml.Task.RegistrationInfo.Author
                Description     = $taskXml.Task.RegistrationInfo.Description
                RunAsUser       = $task.Principal
                Triggers        = $task.Definition.Triggers | ForEach-Object { "$($_.Type) : $($_.StartBoundary)" }
                Actions         = ($task.Definition.Actions | ForEach-Object { "$($_.Path) $($_.Arguments)" }) -join '; '
                CreationDate    = $taskXml.Task.RegistrationInfo.Date
                Source          = $ComputerName
            }
            $allTasks += $taskObj
        }

        # Sous-dossiers (récursif)
        $subFolders = $folder.GetFolders(0)
        foreach ($sub in $subFolders) {
            $allTasks += Get-TaskFolderRecursive -TaskService $TaskService -FolderPath $sub.Path
        }

        return $allTasks
    } catch {
        Write-Log "Erreur sur le dossier $FolderPath : $_" "WARN"
        return @()
    }
}

# ---------- Connexion au Task Scheduler ----------
Write-Log "Connexion au Task Scheduler sur $ComputerName" "INFO"

try {
    $scheduler = New-Object -ComObject "Schedule.Service" -ErrorAction Stop
    $scheduler.Connect($ComputerName)
    Write-Log "Connecté au Task Scheduler" "OK"
} catch {
    Write-Log "Impossible de se connecter au Task Scheduler sur $ComputerName : $_" "ERROR"
    exit 1
}

# ---------- Collecte ----------
Write-Log "Récupération des tâches depuis $TaskPath (incl. désactivées : $IncludeDisabled)" "INFO"

$allTasks = Get-TaskFolderRecursive -TaskService $scheduler -FolderPath $TaskPath
$totalTasks = ($allTasks | Measure-Object).Count
Write-Log "Total tâches trouvées : $totalTasks" "INFO"

# Filtrage
$filteredTasks = if ($IncludeDisabled) { $allTasks } else { $allTasks | Where-Object { $_.Enabled } }
$finalTasks = if ($ExportFailedOnly) { $filteredTasks | Where-Object { $_.LastTaskResult -ne 0 -and $null -ne $_.LastRunTime } } else { $filteredTasks }

$taskCount = ($filteredTasks | Measure-Object).Count
$failedCount = ($filteredTasks | Where-Object { $_.LastTaskResult -ne 0 -and $null -ne $_.LastRunTime } | Measure-Object).Count
$enabledCount = ($filteredTasks | Where-Object { $_.Enabled } | Measure-Object).Count
$disabledCount = ($filteredTasks | Where-Object { -not $_.Enabled } | Measure-Object).Count
$runningNow = ($filteredTasks | Where-Object { $_.State -eq "Running" } | Measure-Object).Count

Write-Host "  Actives : $enabledCount | Désactivées : $disabledCount | En échec : $failedCount | En cours : $runningNow" -ForegroundColor Cyan

# ---------- Export CSV ----------
if ($CsvPath -and $finalTasks.Count -gt 0) {
    try {
        $finalTasks | Select-Object TaskPath, TaskName, State, Enabled, LastRunTime, LastTaskResult, NextRunTime, Author, RunAsUser, Source |
                     Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
        Write-Log "Export CSV : $CsvPath" "OK"
    } catch {
        Write-Log "Échec export CSV : $_" "WARN"
    }
}

# ---------- Rapport HTML ----------
$htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Rapport Tâches Planifiées - $ComputerName</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #f5f5f5; }
        h1 { color: #333; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #555; margin-top: 25px; }
        table { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 2px 4px rgba(0,0,0,0.1); font-size: 0.9em; }
        th { background: #0078d4; color: #fff; padding: 7px; text-align: left; position: sticky; top: 0; }
        td { padding: 5px 7px; border-bottom: 1px solid #ddd; }
        tr:hover { background: #f0f0f0; }
        .failed { background: #f8d7da; }
        .running { background: #cce5ff; }
        .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 15px; margin: 20px 0; }
        .kpi-card { background: #fff; padding: 15px; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); text-align: center; }
        .kpi-card .number { font-size: 2em; font-weight: bold; }
        .kpi-card .label { font-size: 0.85em; color: #666; margin-top: 5px; }
        .kpi-green .number { color: #28a745; }
        .kpi-red .number { color: #dc3545; }
        .kpi-blue .number { color: #0078d4; }
        .badge { display: inline-block; padding: 2px 8px; border-radius: 3px; font-size: 0.85em; }
        .badge-ok { background: #28a745; color: #fff; }
        .badge-ko { background: #dc3545; color: #fff; }
        .badge-warn { background: #ffc107; color: #333; }
        .badge-info { background: #0078d4; color: #fff; }
        .badge-running { background: #17a2b8; color: #fff; }
        .footer { margin-top: 20px; color: #666; font-size: 0.9em; }
    </style>
</head>
<body>
    <h1>Rapport des Tâches Planifiées</h1>
    <p><strong>Serveur :</strong> $ComputerName</p>
    <p><strong>Généré le :</strong> $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")</p>
"@

$htmlBody = @"
    <div class="kpi-grid">
        <div class="kpi-card kpi-blue">
            <div class="number">$taskCount</div>
            <div class="label">Total tâches</div>
        </div>
        <div class="kpi-card kpi-green">
            <div class="number">$enabledCount</div>
            <div class="label">Activées</div>
        </div>
        <div class="kpi-card">
            <div class="number">$disabledCount</div>
            <div class="label">Désactivées</div>
        </div>
        <div class="kpi-card kpi-red">
            <div class="number">$failedCount</div>
            <div class="label">En échec</div>
        </div>
        <div class="kpi-card kpi-running">
            <div class="number">$runningNow</div>
            <div class="label">En cours</div>
        </div>
    </div>
"@

# Tableau principal
$htmlBody += @"
    <h2>Détail des tâches</h2>
    <table>
        <tr>
            <th>Chemin</th>
            <th>Nom</th>
            <th>État</th>
            <th>Activée</th>
            <th>Dernière exécution</th>
            <th>Résultat</th>
            <th>Prochaine exécution</th>
            <th>Exécutant</th>
        </tr>
"@

$sortedTasks = $filteredTasks | Sort-Object TaskPath, TaskName
foreach ($t in $sortedTasks) {
    $rowClass = if ($t.LastTaskResult -ne 0 -and $null -ne $t.LastRunTime) { "failed" } elseif ($t.State -eq "Running") { "running" } else { "" }
    
    $stateBadge = switch ($t.State) {
        "Ready"   { "<span class='badge badge-ok'>Ready</span>" }
        "Running" { "<span class='badge badge-running'>Running</span>" }
        "Disabled" { "<span class='badge badge-warn'>Disabled</span>" }
        "Queued"  { "<span class='badge badge-info'>Queued</span>" }
        default   { "<span class='badge badge-warn'>$($t.State)</span>" }
    }
    
    $enabledBadge = if ($t.Enabled) { "<span class='badge badge-ok'>Oui</span>" } else { "<span class='badge badge-ko'>Non</span>" }
    
    $lastRun = if ($t.LastRunTime) { $t.LastRunTime.ToString("dd/MM/yyyy HH:mm") } else { "-" }
    $nextRun = if ($t.NextRunTime) { $t.NextRunTime.ToString("dd/MM/yyyy HH:mm") } else { "-" }
    $resultDisplay = if ($null -ne $t.LastRunTime) {
        if ($t.LastTaskResult -eq 0) { "<span class='badge badge-ok'>Succès (0)</span>" } else { "<span class='badge badge-ko'>Échec ($($t.LastTaskResult))</span>" }
    } else { "-" }
    
    $htmlBody += "<tr class='$rowClass'><td>$($t.TaskPath)</td><td>$($t.TaskName)</td><td>$stateBadge</td><td>$enabledBadge</td><td>$lastRun</td><td>$resultDisplay</td><td>$nextRun</td><td>$($t.RunAsUser)</td></tr>"
}

$htmlBody += "</table>"

# Tâches en échec uniquement (section dédiée)
if ($failedCount -gt 0) {
    $htmlBody += @"
    <h2>Tâches en échec (détail)</h2>
    <table>
        <tr><th>Tâche</th><th>Dernière exécution</th><th>Code erreur</th><th>Actions</th><th>Auteur</th></tr>
"@
    $failedTasks = $filteredTasks | Where-Object { $_.LastTaskResult -ne 0 -and $null -ne $_.LastRunTime }
    foreach ($ft in $failedTasks) {
        $htmlBody += "<tr class='failed'><td>$($ft.TaskPath)$($ft.TaskName)</td><td>$($ft.LastRunTime.ToString('dd/MM/yyyy HH:mm'))</td><td><strong>$($ft.LastTaskResult)</strong>$(if($ft.LastTaskResult -eq 2147942405){' (Fichier introuvable)'})</td><td>$($ft.Actions)</td><td>$($ft.Author)</td></tr>"
    }
    $htmlBody += "</table>"
}

$htmlFooter = @"
    <div class="footer">
        <p>Script scheduled-tasks-report.ps1 - Intervalle recommandé : quotidien</p>
        <p>Source : Schedule.Service (COM Object)</p>
    </div>
</body>
</html>
"@

$html = $htmlHeader + $htmlBody + $htmlFooter
$html | Out-File -FilePath $OutputPath -Encoding utf8
Write-Log "Rapport HTML généré : $OutputPath" "OK"

# ---------- Résultat final ----------
Write-Log "=== Résumé ===" "INFO"
Write-Log "Total : $taskCount | Activées : $enabledCount | Désactivées : $disabledCount | Échec : $failedCount | En cours : $runningNow" "INFO"

if ($failedCount -gt 0) {
    Write-Log "ATTENTION : $failedCount tâche(s) en échec détectée(s)" "ERROR"
    exit 1
}
exit 0
