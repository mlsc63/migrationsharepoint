param(
    [switch]$Help,
    [string]$ConfigPath = ".\config.xml",
    [switch]$WhatIf,
    [switch]$Overwrite,
    [switch]$DeleteRemoteMissing,
    [switch]$Inventory,
    [switch]$DeltaInventory,
    [switch]$CheckChanges,
    [switch]$IncludeDeleted,
    [switch]$NewProject,
    [string]$ProjectName,
    [string]$Project,
    [switch]$Migrate,
    [switch]$Resume,
    [switch]$Status,
    [switch]$ExportReport,
    [switch]$PurgeReports,
    [int]$ReportRetentionDays = 30,
    [switch]$ResetFailed,
    [string[]]$ExcludeFile,
    [string[]]$ExcludeFolder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Get-ChildItem -Path (Join-Path $PSScriptRoot "functions") -Filter "*.ps1" | ForEach-Object {
    . $_.FullName
}

if ($Help) {
    Show-MigrationHelp
    return
}

if ($NewProject) {
    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        throw "Le parametre -ProjectName est obligatoire avec -NewProject."
    }

    $projectInfo = New-MigrationProject -ProjectName $ProjectName -ConfigPath $ConfigPath
    Write-Host "Projet cree: $($projectInfo.Directory)"
    Write-Host "Base SQLite: $($projectInfo.DatabasePath)"
    return
}

$projectInfo = $null
if (-not [string]::IsNullOrWhiteSpace($Project)) {
    $projectInfo = Get-MigrationProject -Project $Project
    $ConfigPath = $projectInfo.ConfigPath
}

$projectOnlyActionRequested = $DeltaInventory -or $CheckChanges -or $Migrate -or $Resume -or $Status -or $ExportReport -or $PurgeReports -or $ResetFailed
if (-not $projectInfo -and $projectOnlyActionRequested) {
    throw "Cette commande necessite -Project <nom|chemin>. Exemple: .\main.ps1 -Project `"Migration-Lunii`" -$(
        if ($CheckChanges) { 'CheckChanges' }
        elseif ($DeltaInventory) { 'DeltaInventory' }
        elseif ($Migrate) { 'Migrate' }
        elseif ($Resume) { 'Resume' }
        elseif ($Status) { 'Status' }
        elseif ($ExportReport) { 'ExportReport' }
        elseif ($PurgeReports) { 'PurgeReports' }
        elseif ($ResetFailed) { 'ResetFailed' }
        else { 'Status' }
    )"
}

if ($projectInfo -and $Status) {
    Write-ProjectStatus -ProjectInfo $projectInfo
    return
}

if ($projectInfo -and $ResetFailed) {
    $resetCount = Reset-FailedMigrationFiles -DatabasePath $projectInfo.DatabasePath
    Write-Host "Fichiers Failed remis en Pending: $resetCount"
    return
}

if ($projectInfo -and $PurgeReports) {
    $purgedReports = @(Remove-OldMigrationReports -ReportDirectory $projectInfo.ReportDirectory -RetentionDays $ReportRetentionDays)
    Write-Host "Rapports supprimes: $($purgedReports.Count)"
    foreach ($reportPath in $purgedReports) {
        Write-Host $reportPath
    }
    return
}

if ($projectInfo -and $ExportReport) {
    $report = Export-MigrationReport -DatabasePath $projectInfo.DatabasePath -ReportDirectory $projectInfo.ReportDirectory
    Write-Host "Rapport detail exporte: $($report.DetailPath)"
    Write-Host "Resume exporte: $($report.SummaryPath)"
    Write-Host "Erreurs exportees: $($report.ErrorPath)"
    Write-Host "Modifications exportees: $($report.ChangesPath)"
    return
}

$context = Get-MigrationContext -ConfigPath $ConfigPath -ExcludeFile $ExcludeFile -ExcludeFolder $ExcludeFolder

if ($projectInfo) {
    $context.LogDirectory = $projectInfo.LogDirectory
}

$resolvedLogPath = Initialize-Log -LogDirectory $context.LogDirectory
Write-Log -Level "INFO" -Message "Demarrage de la migration"
Write-Log -Level "INFO" -Message "Fichier de configuration: $ConfigPath"
Write-Log -Level "INFO" -Message "Mode simulation: $WhatIf"
Write-Log -Level "INFO" -Message "Ecrasement des fichiers existants: $Overwrite"
Write-Log -Level "INFO" -Message "Suppression distante des fichiers absents localement: $DeleteRemoteMissing"
Write-Log -Level "INFO" -Message "Mode inventaire: $Inventory"
Write-Log -Level "INFO" -Message "Mode delta inventaire: $DeltaInventory"
Write-Log -Level "INFO" -Message "Mode controle changements: $CheckChanges"
Write-Log -Level "INFO" -Message "Inclure les fichiers supprimes: $IncludeDeleted"
if ($projectInfo) {
    Write-Log -Level "INFO" -Message "Projet: $($projectInfo.Name)"
    Write-Log -Level "INFO" -Message "Base projet: $($projectInfo.DatabasePath)"
}
Write-Log -Level "INFO" -Message "Source locale: $($context.SourceRoot)"
Write-Log -Level "INFO" -Message "Site SharePoint: $($context.Destination.SiteUrl)"
Write-Log -Level "INFO" -Message "Destination SharePoint: $($context.Destination.ServerRelativeRoot)"

if ($projectInfo -and $CheckChanges) {
    Invoke-ProjectCheckChanges -ProjectInfo $projectInfo -Context $context -IncludeDeleted:$IncludeDeleted
    Write-Log -Level "INFO" -Message "Journal: $resolvedLogPath"
    return
}

$needsSharePointRead = (-not $CheckChanges) -and ((-not $WhatIf) -or $Inventory -or $DeltaInventory)
Connect-MigrationSharePoint -Context $context -SkipConnection:(-not $needsSharePointRead)
$blockedExtensions = Get-BlockedExtensionsForMigration -SkipConnection:(-not $needsSharePointRead)
Assert-SharePointDestination -Context $context -SkipValidation:(-not $needsSharePointRead)

if ($projectInfo) {
    if ($Inventory) {
        Invoke-ProjectInventory -ProjectInfo $projectInfo -Context $context -BlockedExtensions $blockedExtensions
        Write-Log -Level "INFO" -Message "Journal: $resolvedLogPath"
        return
    }

    if ($DeltaInventory) {
        Invoke-ProjectDeltaInventory -ProjectInfo $projectInfo -Context $context -BlockedExtensions $blockedExtensions -IncludeDeleted:$IncludeDeleted
        Write-Log -Level "INFO" -Message "Journal: $resolvedLogPath"
        return
    }

    if ($Migrate -or $Resume) {
        Invoke-ProjectMigration -ProjectInfo $projectInfo -Context $context -IncludeFailed:$Resume -WhatIf:$WhatIf -Overwrite:$Overwrite -DeleteRemoteMissing:$DeleteRemoteMissing
        Write-Log -Level "INFO" -Message "Journal: $resolvedLogPath"
        return
    }

    Write-Log -Level "WARN" -Message "Aucune action projet demandee. Utilise -Inventory, -DeltaInventory, -Migrate, -Resume, -Status ou -ExportReport."
    return
}

Invoke-LegacyMigration -Context $context -WhatIf:$WhatIf -Overwrite:$Overwrite -Inventory:$Inventory -BlockedExtensions $blockedExtensions
Write-Log -Level "INFO" -Message "Journal: $resolvedLogPath"
