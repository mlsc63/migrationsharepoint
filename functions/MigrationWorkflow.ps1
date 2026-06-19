function Show-MigrationHelp {
    Write-Host ""
    Write-Host "Migration SharePoint - aide rapide"
    Write-Host ""
    Write-Host "Commandes principales"
    Write-Host "  .\main.ps1 -Help"
    Write-Host "  .\main.ps1"
    Write-Host "  .\main.ps1 -Inventory"
    Write-Host "  .\main.ps1 -WhatIf"
    Write-Host ""
    Write-Host "Workflow projet"
    Write-Host "  .\main.ps1 -NewProject -ProjectName ""Migration-Lunii"" -ConfigPath .\config.xml"
    Write-Host "  .\main.ps1 -Project ""Migration-Lunii"" -Inventory"
    Write-Host "  .\main.ps1 -Project ""Migration-Lunii"" -DeltaInventory"
    Write-Host "  .\main.ps1 -Project ""Migration-Lunii"" -CheckChanges"
    Write-Host "  .\main.ps1 -Project ""Migration-Lunii"" -Status"
    Write-Host "  .\main.ps1 -Project ""Migration-Lunii"" -Migrate"
    Write-Host "  .\main.ps1 -Project ""Migration-Lunii"" -Resume"
    Write-Host "  .\main.ps1 -Project ""Migration-Lunii"" -ExportReport"
    Write-Host ""
    Write-Host "Maintenance projet"
    Write-Host "  .\main.ps1 -Project ""Migration-Lunii"" -ResetFailed"
    Write-Host "  .\main.ps1 -Project ""Migration-Lunii"" -PurgeReports -ReportRetentionDays 30"
    Write-Host ""
    Write-Host "Options"
    Write-Host "  -ConfigPath <path>          Fichier XML de configuration."
    Write-Host "  -NewProject                 Cree un projet avec config, logs, reports et migration.db."
    Write-Host "  -Project <name|path>        Utilise un projet existant."
    Write-Host "  -Inventory                  Genere un inventaire sans upload."
    Write-Host "  -DeltaInventory             Met a jour uniquement les fichiers nouveaux ou modifies."
    Write-Host "  -IncludeDeleted             Avec -DeltaInventory ou -CheckChanges, traite les fichiers disparus."
    Write-Host "  -CheckChanges               Genere un rapport de changements sans modifier les statuts."
    Write-Host "  -Migrate                    Migre les fichiers Pending depuis la base projet."
    Write-Host "  -Resume                     Reprend Pending, Failed et Uploading selon les limites configurees."
    Write-Host "  -DeleteRemoteMissing        Avec -Migrate ou -Resume, supprime dans SharePoint les fichiers MissingLocalFile."
    Write-Host "  -Status                     Affiche le bilan par statut."
    Write-Host "  -ExportReport               Exporte detail, resume, erreurs et modifications en CSV."
    Write-Host "  -ResetFailed                Remet les Failed en Pending, AttemptCount a 0 et vide LastError."
    Write-Host "  -PurgeReports               Supprime les rapports CSV anciens."
    Write-Host "  -ReportRetentionDays <n>    Jours de conservation des rapports. Defaut: 30."
    Write-Host "  -WhatIf                     Simule migration/reprise sans upload ni suppression SharePoint."
    Write-Host "  -Overwrite                  Supprime le fichier cible existant puis upload."
    Write-Host "  -ExcludeFile <patterns>     Exclut des fichiers, ex: *.tmp,Thumbs.db."
    Write-Host "  -ExcludeFolder <patterns>   Exclut des dossiers, ex: node_modules,archive/*."
    Write-Host ""
    Write-Host "Configuration importante"
    Write-Host "  Authentication.*            TenantId, ClientId, CertificateThumbprint."
    Write-Host "  Source.LocalPath            Dossier local source."
    Write-Host "  Destination.*               SiteUrl, Library, Folder."
    Write-Host "  Logging.LogDirectory        Dossier des logs."
    Write-Host "  Migration.HashMode          SHA256, Quick ou None."
    Write-Host "  Migration.MaxAttemptsPerFile Nombre max de tentatives par fichier. 0 = illimite."
    Write-Host "  Migration.MaxTotalErrors    Nombre max d'erreurs par execution. 0 = illimite."
    Write-Host "  Exclusions.*                Motifs de fichiers/dossiers a ignorer."
    Write-Host ""
    Write-Host "Statuts base"
    Write-Host "  Pending, Uploading, Uploaded, Failed, BlockedExtension, SkippedExists, MissingLocalFile, DeletedRemote"
    Write-Host ""
    Write-Host "Documentation complete: README.md"
    Write-Host ""
}

function Get-MigrationContext {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [string[]]$ExcludeFile,

        [string[]]$ExcludeFolder
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Fichier de configuration introuvable: $ConfigPath"
    }

    [xml]$config = Get-Content -Raw -LiteralPath $ConfigPath

    $authNode = $config.Configuration.Authentication
    $destinationNode = $config.Configuration.Destination
    $tenantId = Get-RequiredValue -Value $authNode.TenantId -Name "Authentication.TenantId"
    $clientId = Get-RequiredValue -Value $authNode.ClientId -Name "Authentication.ClientId"
    $certificateThumbprint = Get-RequiredValue -Value $authNode.CertificateThumbprint -Name "Authentication.CertificateThumbprint"
    $sourcePath = Get-RequiredValue -Value $config.Configuration.Source.LocalPath -Name "Source.LocalPath"
    $destinationSiteUrl = Get-RequiredValue -Value $destinationNode.SiteUrl -Name "Destination.SiteUrl"
    $destinationLibrary = Get-RequiredValue -Value $destinationNode.Library -Name "Destination.Library"
    $destinationFolder = $destinationNode.Folder
    $logDirectory = $config.Configuration.Logging.LogDirectory
    $migrationNode = $config.SelectSingleNode("/Configuration/Migration")
    $maxAttemptsPerFile = 3
    $maxTotalErrors = 1000
    $hashMode = "SHA256"

    if ($null -ne $migrationNode) {
        $maxAttemptsNode = $migrationNode.SelectSingleNode("MaxAttemptsPerFile")
        $maxTotalErrorsNode = $migrationNode.SelectSingleNode("MaxTotalErrors")
        $hashModeNode = $migrationNode.SelectSingleNode("HashMode")

        if ($null -ne $maxAttemptsNode -and -not [string]::IsNullOrWhiteSpace($maxAttemptsNode.InnerText)) {
            $maxAttemptsPerFile = [int]$maxAttemptsNode.InnerText
        }

        if ($null -ne $maxTotalErrorsNode -and -not [string]::IsNullOrWhiteSpace($maxTotalErrorsNode.InnerText)) {
            $maxTotalErrors = [int]$maxTotalErrorsNode.InnerText
        }

        if ($null -ne $hashModeNode -and -not [string]::IsNullOrWhiteSpace($hashModeNode.InnerText)) {
            $hashMode = "$($hashModeNode.InnerText)".Trim()
        }
    }

    $exclusionsNode = $config.SelectSingleNode("/Configuration/Exclusions")
    $configExcludeFiles = @()
    $configExcludeFolders = @()

    if ($null -ne $exclusionsNode) {
        $configExcludeFiles = @($exclusionsNode.SelectNodes("Files/Pattern")) |
            ForEach-Object { $_.InnerText } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { "$_".Trim() }
        $configExcludeFolders = @($exclusionsNode.SelectNodes("Folders/Pattern")) |
            ForEach-Object { $_.InnerText } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { "$_".Trim().Trim("/", "\") }
    }
    $excludeFilePatterns = @($configExcludeFiles + @($ExcludeFile)) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { "$_".Trim() } |
        Sort-Object -Unique
    $excludeFolderPatterns = @($configExcludeFolders + @($ExcludeFolder)) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { "$_".Trim().Trim("/", "\") } |
        Sort-Object -Unique

    $sourceItem = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
    if (-not $sourceItem.PSIsContainer) {
        throw "Source.Path doit etre un repertoire local: $sourcePath"
    }

    $sourceRoot = $sourceItem.FullName.TrimEnd("\", "/")
    $destination = Join-SharePointPath -SiteUrl $destinationSiteUrl -Library $destinationLibrary -Folder $destinationFolder

    return [pscustomobject]@{
        ConfigPath            = $ConfigPath
        LogDirectory          = $logDirectory
        TenantId              = $tenantId
        ClientId              = $clientId
        CertificateThumbprint = $certificateThumbprint
        SourceRoot            = $sourceRoot
        Destination           = $destination
        ExcludeFilePatterns   = $excludeFilePatterns
        ExcludeFolderPatterns = $excludeFolderPatterns
        MaxAttemptsPerFile    = $maxAttemptsPerFile
        MaxTotalErrors        = $maxTotalErrors
        HashMode              = $hashMode
    }
}

function Test-MigrationPathExcluded {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath,

        [string[]]$ExcludeFilePatterns,

        [string[]]$ExcludeFolderPatterns
    )

    $normalizedPath = $RelativePath -replace "\\", "/"
    $fileName = [System.IO.Path]::GetFileName($normalizedPath)
    $relativeFolder = [System.IO.Path]::GetDirectoryName($normalizedPath) -replace "\\", "/"

    foreach ($pattern in @($ExcludeFilePatterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            continue
        }

        $normalizedPattern = $pattern -replace "\\", "/"
        if ($fileName -like $normalizedPattern -or $normalizedPath -like $normalizedPattern) {
            return $true
        }
    }

    foreach ($pattern in @($ExcludeFolderPatterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            continue
        }

        $normalizedPattern = ($pattern -replace "\\", "/").Trim("/")
        $folderParts = @($relativeFolder -split "/" | Where-Object { $_ })

        if ($relativeFolder -like $normalizedPattern -or $relativeFolder -like "$normalizedPattern/*") {
            return $true
        }

        foreach ($part in $folderParts) {
            if ($part -like $normalizedPattern) {
                return $true
            }
        }
    }

    return $false
}

function Get-MigrationSourceFiles {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    $files = @(Get-ChildItem -LiteralPath $Context.SourceRoot -File -Recurse)
    $includedFiles = @()
    $excludedCount = 0

    foreach ($file in $files) {
        $relativePath = Convert-ToSharePointRelativePath -BasePath $Context.SourceRoot -FilePath $file.FullName

        if (Test-MigrationPathExcluded `
                -RelativePath $relativePath `
                -ExcludeFilePatterns $Context.ExcludeFilePatterns `
                -ExcludeFolderPatterns $Context.ExcludeFolderPatterns) {
            Write-Log -Level "INFO" -Message "[EXCLU] $relativePath"
            $excludedCount++
            continue
        }

        $includedFiles += $file
    }

    if ($excludedCount -gt 0) {
        Write-Log -Level "INFO" -Message "Fichiers exclus par configuration: $excludedCount"
    }

    return $includedFiles
}

function Connect-MigrationSharePoint {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [switch]$SkipConnection
    )

    Write-Step "Verification du module PnP.PowerShell"
    Ensure-PnPPowerShell

    if ($SkipConnection) {
        Write-Log -Level "WARN" -Message "Mode simulation actif: aucune connexion ni modification ne sera effectuee."
        return
    }

    Write-Step "Connexion a SharePoint: $($Context.Destination.SiteUrl)"
    Connect-PnPOnline `
        -Url $Context.Destination.SiteUrl `
        -Tenant $Context.TenantId `
        -ClientId $Context.ClientId `
        -Thumbprint $Context.CertificateThumbprint
}

function Get-BlockedExtensionsForMigration {
    param(
        [switch]$SkipConnection
    )

    Write-Step "Recuperation des extensions bloquees au niveau du tenant"

    if ($SkipConnection) {
        Write-Log -Level "WARN" -Message "Controle des extensions bloquees ignore en mode simulation, car aucune connexion SharePoint n'est effectuee."
        return @()
    }

    try {
        $blockedExtensions = @(Get-TenantBlockedExtensions)

        if ($blockedExtensions.Count -gt 0) {
            Write-Log -Level "INFO" -Message "Extensions bloquees par le tenant: $($blockedExtensions -join ', ')"
        }
        else {
            Write-Log -Level "INFO" -Message "Aucune extension bloquee n'a ete retournee par le tenant."
        }

        return $blockedExtensions
    }
    catch {
        Write-Log -Level "ERROR" -Message "Impossible de recuperer les extensions bloquees du tenant: $($_.Exception.Message)"
        throw
    }
}

function Assert-SharePointDestination {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [switch]$SkipValidation
    )

    Write-Step "Validation de la destination SharePoint"

    if ($SkipValidation) {
        Write-Log -Level "WARN" -Message "Validation SharePoint ignoree car aucune connexion n'est active."
        return
    }

    try {
        Get-PnPFolder -Url $Context.Destination.ServerRelativeRoot -ErrorAction Stop | Out-Null
        Write-Log -Level "INFO" -Message "Destination SharePoint validee: $($Context.Destination.ServerRelativeRoot)"
    }
    catch {
        Write-Log -Level "ERROR" -Message "Destination SharePoint invalide ou inaccessible: $($Context.Destination.ServerRelativeRoot) - $($_.Exception.Message)"
        throw
    }
}

function Add-MigrationPnPFile {
    param(
        [Parameter(Mandatory)]
        [string]$LocalPath,

        [Parameter(Mandatory)]
        [string]$TargetFolder,

        [Parameter(Mandatory)]
        [string]$TargetUrl,

        [switch]$Overwrite,

        [switch]$TargetExists
    )

    if ($Overwrite -and $TargetExists) {
        Write-Log -Level "WARN" -Message "Ecrasement explicite: suppression du fichier cible avant upload: $TargetUrl"
        Remove-PnPFile -ServerRelativeUrl $TargetUrl -Force -ErrorAction Stop
    }
    elseif ($Overwrite) {
        Write-Log -Level "INFO" -Message "Ecrasement explicite demande, mais le fichier cible est absent: $TargetUrl"
    }

    Add-PnPFile -Path $LocalPath -Folder $TargetFolder | Out-Null
}

function Write-ProjectStatus {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$ProjectInfo
    )

    $rows = @(Get-MigrationStatus -DatabasePath $ProjectInfo.DatabasePath)
    $total = 0

    Write-Host "Projet: $($ProjectInfo.Name)"
    Write-Host "Base: $($ProjectInfo.DatabasePath)"

    foreach ($row in $rows) {
        $total += [int]$row.Count
        Write-Host ("{0}: {1}" -f $row.Status, $row.Count)
    }

    Write-Host ("Total: {0}" -f $total)
}

function Invoke-ProjectInventory {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$ProjectInfo,

        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [string[]]$BlockedExtensions
    )

    $runId = Start-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -Mode "Inventory"

    try {
        $inventorySeenAt = (Get-Date).ToUniversalTime().ToString("o")
        $files = @(Get-MigrationSourceFiles -Context $Context)
        Write-Step "$($files.Count) fichier(s) detecte(s) dans $($Context.SourceRoot)"
        Write-Log -Level "INFO" -Message "Mode de hash inventaire: $($Context.HashMode)"
        Reset-MigrationHashChanges -DatabasePath $ProjectInfo.DatabasePath

        if ($Context.HashMode -eq "None") {
            Write-Log -Level "WARN" -Message "HashMode=None: les modifications locales ne seront pas detectees par hash."
        }

        foreach ($file in $files) {
            Upsert-MigrationFile `
                -DatabasePath $ProjectInfo.DatabasePath `
                -File $file `
                -SourceRoot $Context.SourceRoot `
                -ServerRelativeRoot $Context.Destination.ServerRelativeRoot `
                -BlockedExtensions $BlockedExtensions `
                -InventorySeenAt $inventorySeenAt `
                -HashMode $Context.HashMode
        }

        $missingCount = Update-MissingInventoryFiles -DatabasePath $ProjectInfo.DatabasePath -InventorySeenAt $inventorySeenAt
        if ($missingCount -gt 0) {
            Write-Log -Level "WARN" -Message "Fichiers marques MissingLocalFile pendant l'inventaire: $missingCount"
        }

        Complete-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -RunId $runId -Result "Success" -Message "Inventaire termine"
        Write-Log -Level "INFO" -Message "Inventaire projet termine dans la base: $($ProjectInfo.DatabasePath)"
        Write-ProjectStatus -ProjectInfo $ProjectInfo
    }
    catch {
        Complete-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -RunId $runId -Result "Failed" -Message $_.Exception.Message
        throw
    }
}

function Invoke-ProjectDeltaInventory {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$ProjectInfo,

        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [string[]]$BlockedExtensions,

        [switch]$IncludeDeleted
    )

    $runId = Start-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -Mode "DeltaInventory"

    try {
        $inventorySeenAt = (Get-Date).ToUniversalTime().ToString("o")
        $files = @(Get-MigrationSourceFiles -Context $Context)
        $newCount = 0
        $changedCount = 0
        $unchangedCount = 0

        Write-Step "Delta inventaire: $($files.Count) fichier(s) detecte(s) dans $($Context.SourceRoot)"
        Write-Log -Level "INFO" -Message "Mode de hash delta: $($Context.HashMode)"
        Reset-MigrationHashChanges -DatabasePath $ProjectInfo.DatabasePath

        if ($Context.HashMode -eq "None") {
            Write-Log -Level "WARN" -Message "HashMode=None: seuls les nouveaux fichiers seront detectes de facon fiable."
        }

        foreach ($file in $files) {
            $existingFile = Get-MigrationFileByFullPath -DatabasePath $ProjectInfo.DatabasePath -FullPath $file.FullName
            $currentHash = Get-MigrationFileFingerprint -File $file -HashMode $Context.HashMode

            if ($null -eq $existingFile) {
                Upsert-MigrationFile `
                    -DatabasePath $ProjectInfo.DatabasePath `
                    -File $file `
                    -SourceRoot $Context.SourceRoot `
                    -ServerRelativeRoot $Context.Destination.ServerRelativeRoot `
                    -BlockedExtensions $BlockedExtensions `
                    -InventorySeenAt $inventorySeenAt `
                    -HashMode $Context.HashMode
                $newCount++
                continue
            }

            $existingHash = "$($existingFile.FileHash)"
            if ($Context.HashMode -eq "None") {
                Update-MigrationFileInventorySeen `
                    -DatabasePath $ProjectInfo.DatabasePath `
                    -Id $existingFile.Id `
                    -InventorySeenAt $inventorySeenAt
                $unchangedCount++
                continue
            }

            if ([string]::IsNullOrWhiteSpace($existingHash) -or $existingHash -ne $currentHash) {
                Upsert-MigrationFile `
                    -DatabasePath $ProjectInfo.DatabasePath `
                    -File $file `
                    -SourceRoot $Context.SourceRoot `
                    -ServerRelativeRoot $Context.Destination.ServerRelativeRoot `
                    -BlockedExtensions $BlockedExtensions `
                    -InventorySeenAt $inventorySeenAt `
                    -HashMode $Context.HashMode
                $changedCount++
                continue
            }

            Update-MigrationFileInventorySeen `
                -DatabasePath $ProjectInfo.DatabasePath `
                -Id $existingFile.Id `
                -InventorySeenAt $inventorySeenAt
            $unchangedCount++
        }

        $missingCount = 0
        if ($IncludeDeleted) {
            $missingCount = Update-MissingInventoryFiles -DatabasePath $ProjectInfo.DatabasePath -InventorySeenAt $inventorySeenAt
            if ($missingCount -gt 0) {
                Write-Log -Level "WARN" -Message "Fichiers marques MissingLocalFile pendant le delta: $missingCount"
            }
        }
        else {
            Write-Log -Level "INFO" -Message "Fichiers supprimes ignores pendant le delta. Utilise -IncludeDeleted pour les marquer MissingLocalFile."
        }

        $summary = "Nouveaux: $newCount; Modifies: $changedCount; Inchanges: $unchangedCount; Supprimes marques: $missingCount"
        Complete-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -RunId $runId -Result "Success" -Message $summary
        Write-Log -Level "INFO" -Message "Delta inventaire termine dans la base: $($ProjectInfo.DatabasePath)"
        Write-Log -Level "INFO" -Message $summary
        Write-ProjectStatus -ProjectInfo $ProjectInfo
    }
    catch {
        Complete-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -RunId $runId -Result "Failed" -Message $_.Exception.Message
        throw
    }
}

function Invoke-ProjectCheckChanges {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$ProjectInfo,

        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [switch]$IncludeDeleted
    )

    if (-not (Test-Path -LiteralPath $ProjectInfo.ReportDirectory)) {
        New-Item -ItemType Directory -Path $ProjectInfo.ReportDirectory -Force | Out-Null
    }

    $runId = Start-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -Mode "CheckChanges"
    $reportPath = Join-Path $ProjectInfo.ReportDirectory ("migration_checkchanges_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

    try {
        $files = @(Get-MigrationSourceFiles -Context $Context)
        $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $changes = @()

        Write-Step "Controle des changements: $($files.Count) fichier(s) detecte(s) dans $($Context.SourceRoot)"
        Write-Log -Level "INFO" -Message "Mode de hash controle: $($Context.HashMode)"

        if ($Context.HashMode -eq "None") {
            Write-Log -Level "WARN" -Message "HashMode=None: les modifications locales ne seront pas detectees par hash."
        }

        foreach ($file in $files) {
            [void]$seenPaths.Add($file.FullName)
            $relativePath = Convert-ToSharePointRelativePath -BasePath $Context.SourceRoot -FilePath $file.FullName
            $currentHash = Get-MigrationFileFingerprint -File $file -HashMode $Context.HashMode
            $existingFile = Get-MigrationFileByFullPath -DatabasePath $ProjectInfo.DatabasePath -FullPath $file.FullName

            if ($null -eq $existingFile) {
                $changes += [pscustomobject]@{
                    ChangeType       = "New"
                    RelativePath     = $relativePath
                    FullPath         = $file.FullName
                    Status           = ""
                    PreviousFileHash = ""
                    CurrentFileHash  = $currentHash
                    SizeBytes        = $file.Length
                    LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString("o")
                }
                continue
            }

            $existingHash = "$($existingFile.FileHash)"
            if ($Context.HashMode -ne "None" -and -not [string]::IsNullOrWhiteSpace($existingHash) -and $existingHash -ne $currentHash) {
                $changes += [pscustomobject]@{
                    ChangeType       = "Modified"
                    RelativePath     = $relativePath
                    FullPath         = $file.FullName
                    Status           = $existingFile.Status
                    PreviousFileHash = $existingHash
                    CurrentFileHash  = $currentHash
                    SizeBytes        = $file.Length
                    LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString("o")
                }
            }
        }

        if ($IncludeDeleted) {
            $knownFiles = @(Invoke-SqliteQuery -DataSource $ProjectInfo.DatabasePath -Query "SELECT FullPath, RelativePath, Status, FileHash, SizeBytes, LastWriteTimeUtc FROM Files WHERE Status <> 'DeletedRemote' ORDER BY RelativePath;" -As "PSObject")
            foreach ($knownFile in $knownFiles) {
                if (-not $seenPaths.Contains("$($knownFile.FullPath)") -and -not (Test-Path -LiteralPath $knownFile.FullPath)) {
                    $changes += [pscustomobject]@{
                        ChangeType       = "Deleted"
                        RelativePath     = $knownFile.RelativePath
                        FullPath         = $knownFile.FullPath
                        Status           = $knownFile.Status
                        PreviousFileHash = $knownFile.FileHash
                        CurrentFileHash  = ""
                        SizeBytes        = $knownFile.SizeBytes
                        LastWriteTimeUtc = $knownFile.LastWriteTimeUtc
                    }
                }
            }
        }

        Export-CsvWithHeaders `
            -Rows $changes `
            -Columns @("ChangeType", "RelativePath", "FullPath", "Status", "PreviousFileHash", "CurrentFileHash", "SizeBytes", "LastWriteTimeUtc") `
            -Path $reportPath
        $summary = "Changements detectes: $($changes.Count)"
        Complete-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -RunId $runId -Result "Success" -Message $summary
        Write-Log -Level "INFO" -Message $summary
        Write-Host "Rapport changements exporte: $((Resolve-Path -LiteralPath $reportPath).Path)"
        if ($changes.Count -gt 0) {
            Write-Host "Note: -CheckChanges ne modifie pas la base. Pour migrer ces changements, execute: .\main.ps1 -Project `"$($ProjectInfo.Name)`" -DeltaInventory puis .\main.ps1 -Project `"$($ProjectInfo.Name)`" -Migrate"
        }
    }
    catch {
        Complete-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -RunId $runId -Result "Failed" -Message $_.Exception.Message
        throw
    }
}

function Invoke-ProjectMigration {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$ProjectInfo,

        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [switch]$IncludeFailed,

        [switch]$WhatIf,

        [switch]$Overwrite,

        [switch]$DeleteRemoteMissing
    )

    Reset-IncompleteUploads -DatabasePath $ProjectInfo.DatabasePath
    $filesToProcess = @(Get-MigrationFilesToProcess `
        -DatabasePath $ProjectInfo.DatabasePath `
        -IncludeFailed:$IncludeFailed `
        -MaxAttemptsPerFile $Context.MaxAttemptsPerFile)
    $remoteDeleteCandidates = @()
    if ($DeleteRemoteMissing) {
        $remoteDeleteCandidates = @(Get-MigrationRemoteDeleteCandidates `
            -DatabasePath $ProjectInfo.DatabasePath `
            -MaxAttemptsPerFile $Context.MaxAttemptsPerFile)
    }
    $runMode = if ($IncludeFailed) { "Resume" } else { "Migrate" }
    $runId = Start-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -Mode $runMode

    $uploaded = 0
    $skipped = 0
    $deletedRemote = 0
    $failed = 0
    $maxTotalErrors = [int]$Context.MaxTotalErrors

    try {
        Write-Step "$($filesToProcess.Count) fichier(s) a traiter depuis la base projet"
        if ($DeleteRemoteMissing) {
            Write-Step "$($remoteDeleteCandidates.Count) fichier(s) distant(s) a supprimer car absents localement"
        }
        Write-Log -Level "INFO" -Message "Tentatives max par fichier: $($Context.MaxAttemptsPerFile)"
        Write-Log -Level "INFO" -Message "Erreurs max avant arret: $maxTotalErrors"
        Write-Log -Level "INFO" -Message "Suppression distante MissingLocalFile: $DeleteRemoteMissing"

        foreach ($row in $filesToProcess) {
            $fileSize = Format-FileSize -Bytes ([long]$row.SizeBytes)
            $currentOperation = "Preparation"

            try {
                if (-not (Test-Path -LiteralPath $row.FullPath)) {
                    Write-Log -Level "WARN" -Message "[MANQUANT] $($row.RelativePath) - $($row.FullPath)"

                    if ($DeleteRemoteMissing) {
                        if ($WhatIf) {
                            Write-Log -Level "INFO" -Message "[WHATIF] Suppression distante du fichier local manquant: $($row.TargetUrl)"
                            continue
                        }

                        Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $row.Id -Status "MissingLocalFile" -LastError "Suppression distante en cours" -IncrementAttempt

                        $fileExists = $false
                        try {
                            Get-PnPFile -Url $row.TargetUrl -ErrorAction Stop | Out-Null
                            $fileExists = $true
                        }
                        catch {
                            $fileExists = $false
                        }

                        if ($fileExists) {
                            Remove-PnPFile -ServerRelativeUrl $row.TargetUrl -Force -ErrorAction Stop
                            Write-Log -Level "SUCCESS" -Message "[DELETE] Supprime de SharePoint: $($row.TargetUrl)"
                        }
                        else {
                            Write-Log -Level "WARN" -Message "[DELETE] Deja absent de SharePoint: $($row.TargetUrl)"
                        }

                        Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $row.Id -Status "DeletedRemote" -LastError ""
                        $deletedRemote++
                    }
                    else {
                        Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $row.Id -Status "MissingLocalFile" -LastError "Fichier local introuvable"
                        $failed++
                        if ($maxTotalErrors -gt 0 -and $failed -ge $maxTotalErrors) {
                            throw "Seuil d'erreurs atteint ($failed/$maxTotalErrors). Arret de la migration."
                        }
                    }
                    continue
                }

                if ($WhatIf) {
                    Write-Log -Level "INFO" -Message "[WHATIF] $($row.FullPath) -> $($row.TargetUrl) - Taille: $fileSize"
                    continue
                }

                Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $row.Id -Status "Uploading" -LastError "" -IncrementAttempt

                $currentOperation = "Creation/verification du dossier SharePoint"
                Ensure-RemoteFolder -ServerRelativeFolder $row.TargetFolder

                $fileExists = $false
                try {
                    $currentOperation = "Verification de l'existence du fichier SharePoint"
                    Get-PnPFile -Url $row.TargetUrl -ErrorAction Stop | Out-Null
                    $fileExists = $true
                }
                catch {
                    $fileExists = $false
                }

                if ($fileExists -and -not $Overwrite) {
                    Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $row.Id -Status "SkippedExists" -LastError "Existe deja dans SharePoint"
                    Write-Log -Level "WARN" -Message "[SKIP] Existe deja: $($row.TargetUrl) - Taille: $fileSize"
                    $skipped++
                    continue
                }

                $currentOperation = "Upload du fichier vers SharePoint"
                Write-Log -Level "INFO" -Message "Upload cible: $($row.TargetUrl) - Taille: $fileSize"
                Add-MigrationPnPFile -LocalPath $row.FullPath -TargetFolder $row.TargetFolder -TargetUrl $row.TargetUrl -Overwrite:$Overwrite -TargetExists:$fileExists

                Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $row.Id -Status "Uploaded" -LastError "" -SetUploadedAt
                Write-Log -Level "SUCCESS" -Message "[OK] $($row.RelativePath) - Taille: $fileSize"
                $uploaded++
            }
            catch {
                $message = "Operation: $currentOperation - Cible: $($row.TargetUrl) - $($_.Exception.Message)"
                Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $row.Id -Status "Failed" -LastError $message
                Write-Log -Level "ERROR" -Message "[ERREUR] $($row.RelativePath) - Taille: $fileSize - $message"
                $failed++
                if ($maxTotalErrors -gt 0 -and $failed -ge $maxTotalErrors) {
                    throw "Seuil d'erreurs atteint ($failed/$maxTotalErrors). Arret de la migration."
                }
            }
        }

        foreach ($row in $remoteDeleteCandidates) {
            $currentOperation = "Suppression du fichier distant"

            try {
                if ($WhatIf) {
                    Write-Log -Level "INFO" -Message "[WHATIF] Suppression distante: $($row.TargetUrl)"
                    continue
                }

                Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $row.Id -Status "MissingLocalFile" -LastError "Suppression distante en cours" -IncrementAttempt

                $fileExists = $false
                try {
                    Get-PnPFile -Url $row.TargetUrl -ErrorAction Stop | Out-Null
                    $fileExists = $true
                }
                catch {
                    $fileExists = $false
                }

                if ($fileExists) {
                    Remove-PnPFile -ServerRelativeUrl $row.TargetUrl -Force -ErrorAction Stop
                    Write-Log -Level "SUCCESS" -Message "[DELETE] Supprime de SharePoint: $($row.TargetUrl)"
                }
                else {
                    Write-Log -Level "WARN" -Message "[DELETE] Deja absent de SharePoint: $($row.TargetUrl)"
                }

                Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $row.Id -Status "DeletedRemote" -LastError ""
                $deletedRemote++
            }
            catch {
                $message = "Operation: $currentOperation - Cible: $($row.TargetUrl) - $($_.Exception.Message)"
                Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $row.Id -Status "MissingLocalFile" -LastError $message
                Write-Log -Level "ERROR" -Message "[ERREUR DELETE] $($row.RelativePath) - $message"
                $failed++
                if ($maxTotalErrors -gt 0 -and $failed -ge $maxTotalErrors) {
                    throw "Seuil d'erreurs atteint ($failed/$maxTotalErrors). Arret de la migration."
                }
            }
        }

        $summary = "Envoyes: $uploaded; Ignores: $skipped; Supprimes distants: $deletedRemote; Erreurs: $failed"
        Complete-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -RunId $runId -Result "Success" -Message $summary
        Write-Step "Migration projet terminee"
        Write-Log -Level "INFO" -Message $summary
        Write-ProjectStatus -ProjectInfo $ProjectInfo

        if ($failed -gt 0) {
            exit 1
        }
    }
    catch {
        Complete-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -RunId $runId -Result "Failed" -Message $_.Exception.Message
        throw
    }
}

function Invoke-LegacyMigration {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [switch]$WhatIf,

        [switch]$Overwrite,

        [switch]$Inventory,

        [string[]]$BlockedExtensions
    )

    $files = @(Get-MigrationSourceFiles -Context $Context)
    Write-Step "$($files.Count) fichier(s) a migrer depuis $($Context.SourceRoot)"

    if ($Inventory) {
        Write-Step "Generation de l'inventaire"
        $inventoryResult = New-MigrationInventory `
            -Files $files `
            -BlockedExtensions $BlockedExtensions `
            -SourceRoot $Context.SourceRoot `
            -LogDirectory $Context.LogDirectory

        Write-Log -Level "INFO" -Message "Inventaire termine"
        Write-Log -Level "INFO" -Message "Fichiers analyses : $($inventoryResult.TotalFiles)"
        Write-Log -Level "INFO" -Message "Fichiers migrables : $($inventoryResult.MigratableFiles)"
        Write-Log -Level "INFO" -Message "Fichiers bloques par extension tenant : $($inventoryResult.BlockedFiles)"
        Write-Log -Level "INFO" -Message "Journal des fichiers bloques : $($inventoryResult.BlockedLogPath)"
        Write-Log -Level "INFO" -Message "Aucun upload effectue en mode inventaire."
        return
    }

    $uploaded = 0
    $skipped = 0
    $blocked = 0
    $failed = 0
    $maxTotalErrors = [int]$Context.MaxTotalErrors

    foreach ($file in $files) {
        $relativePath = Convert-ToSharePointRelativePath -BasePath $Context.SourceRoot -FilePath $file.FullName
        $relativeFolder = [System.IO.Path]::GetDirectoryName($relativePath)
        $fileSize = Format-FileSize -Bytes $file.Length
        $currentOperation = "Preparation"

        if ([string]::IsNullOrWhiteSpace($relativeFolder)) {
            $targetFolder = $Context.Destination.ServerRelativeRoot
        }
        else {
            $targetFolder = "$($Context.Destination.ServerRelativeRoot)/$($relativeFolder -replace "\\", "/")"
        }

        try {
            $fileExtension = [System.IO.Path]::GetExtension($file.Name).Trim().TrimStart(".").ToLowerInvariant()

            if (-not [string]::IsNullOrWhiteSpace($fileExtension) -and $BlockedExtensions -contains $fileExtension) {
                Write-Log -Level "WARN" -Message "[BLOQUE] Extension interdite par le tenant: $relativePath (.$fileExtension) - Taille: $fileSize"
                $blocked++
                $skipped++
                continue
            }

            if ($WhatIf) {
                Write-Log -Level "INFO" -Message "[WHATIF] $($file.FullName) -> $targetFolder/$($file.Name) - Taille: $fileSize"
                continue
            }

            $currentOperation = "Creation/verification du dossier SharePoint"
            Ensure-RemoteFolder -ServerRelativeFolder $targetFolder -WhatIf:$WhatIf

            $existingFileUrl = "$targetFolder/$($file.Name)"
            $fileExists = $false

            try {
                $currentOperation = "Verification de l'existence du fichier SharePoint"
                Get-PnPFile -Url $existingFileUrl -ErrorAction Stop | Out-Null
                $fileExists = $true
            }
            catch {
                $fileExists = $false
            }

            if ($fileExists -and -not $Overwrite) {
                Write-Log -Level "WARN" -Message "[SKIP] Existe deja: $existingFileUrl - Taille: $fileSize"
                $skipped++
                continue
            }

            $currentOperation = "Upload du fichier vers SharePoint"
            Write-Log -Level "INFO" -Message "Upload cible: $existingFileUrl - Taille: $fileSize"
            Add-MigrationPnPFile -LocalPath $file.FullName -TargetFolder $targetFolder -TargetUrl $existingFileUrl -Overwrite:$Overwrite -TargetExists:$fileExists
            Write-Log -Level "SUCCESS" -Message "[OK] $relativePath - Taille: $fileSize"
            $uploaded++
        }
        catch {
            Write-Log -Level "ERROR" -Message "[ERREUR] $relativePath - Taille: $fileSize - Operation: $currentOperation - Cible: $targetFolder - $($_.Exception.Message)"
            $failed++
            if ($maxTotalErrors -gt 0 -and $failed -ge $maxTotalErrors) {
                Write-Log -Level "ERROR" -Message "Seuil d'erreurs atteint ($failed/$maxTotalErrors). Arret de la migration."
                break
            }
        }
    }

    Write-Step "Migration terminee"
    Write-Log -Level "INFO" -Message "Envoyes : $uploaded"
    Write-Log -Level "INFO" -Message "Ignores : $skipped"
    Write-Log -Level "INFO" -Message "Bloques par extension tenant : $blocked"
    Write-Log -Level "INFO" -Message "Erreurs : $failed"

    if ($failed -gt 0) {
        exit 1
    }
}
