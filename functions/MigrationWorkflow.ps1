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
    Write-Host "  -Resume                     Reprend Pending/Failed et reconcilie toujours les Uploading."
    Write-Host "  -DeleteRemoteMissing        Avec -Migrate ou -Resume, supprime dans SharePoint les fichiers MissingLocalFile."
    Write-Host "  -Status                     Affiche le bilan par statut."
    Write-Host "  -ExportReport               Exporte detail, resume, erreurs et modifications en CSV."
    Write-Host "  -ResetFailed                Remet les Failed en Pending, AttemptCount a 0 et vide LastError."
    Write-Host "  -PurgeReports               Supprime les rapports CSV anciens."
    Write-Host "  -ReportRetentionDays <n>    Jours de conservation des rapports. Defaut: 30."
    Write-Host "  -WhatIf                     Simule migration/reprise sans upload ni suppression SharePoint."
    Write-Host "  -Overwrite                  Supprime le fichier cible existant puis upload."
    Write-Host "  -ParallelUploads <1-16>    Nombre d'uploads simultanes. 0 = valeur XML."
    Write-Host "  -MaxFiles <n>              Limite le nombre de fichiers traites avec -Migrate ou -Resume. 0 = illimite."
    Write-Host "  -AssumeDestinationEmpty    Ignore le controle d'existence distant avant upload."
    Write-Host "  -ExcludeFile <patterns>     Exclut des fichiers, ex: *.tmp,Thumbs.db."
    Write-Host "  -ExcludeFolder <patterns>   Exclut des dossiers, ex: node_modules,archive/*."
    Write-Host ""
    Write-Host "Configuration importante"
    Write-Host "  Authentication.*            TenantId, ClientId, CertificateThumbprint."
    Write-Host "  Source.LocalPath            Dossier local source."
    Write-Host "  Destination.*               SiteUrl, Library, Folder."
    Write-Host "  Logging.LogDirectory        Dossier des logs."
    Write-Host "  Logging.ConsoleMode         Verbose, ProgressOnly, ErrorsOnly ou Quiet."
    Write-Host "  Logging.FileMode            Verbose, ProgressOnly, ErrorsOnly ou Quiet."
    Write-Host "  Logging.ProgressEveryFiles  Frequence de progression par nombre de fichiers."
    Write-Host "  Logging.ProgressEverySeconds Frequence de progression par duree."
    Write-Host "  Migration.HashMode          SHA256, Quick ou None."
    Write-Host "  Migration.ParallelInventory Nombre de calculs d'empreinte simultanes. Defaut: 4."
    Write-Host "  Migration.MaxAttemptsPerFile Nombre max de tentatives par fichier. 0 = illimite."
    Write-Host "  Migration.MaxTotalErrors    Nombre max d'erreurs par execution. 0 = illimite."
    Write-Host "  Migration.ParallelUploads   Nombre d'uploads simultanes. Defaut: 4."
    Write-Host "  Migration.IncludeHiddenItems Inclut les fichiers caches/systeme dans l'inventaire."
    Write-Host "  Migration.AssumeDestinationEmpty Ignore Get-PnPFile avant chaque upload."
    Write-Host "  Migration.TreatTenantSyncExclusionsAsBlocked Politique optionnelle de compatibilite OneDrive."
    Write-Host "  Migration.ProcessingBatchSize Nombre de lignes SQLite chargees par page."
    Write-Host "  Exclusions.*                Motifs de fichiers/dossiers a ignorer."
    Write-Host ""
    Write-Host "Statuts base"
    Write-Host "  Pending, Uploading, Uploaded, Failed, BlockedExtension, Excluded, SkippedExists, MissingLocalFile, DeletedRemote"
    Write-Host ""
    Write-Host "Documentation complete: README.md"
    Write-Host ""
}

function Test-PnPNotFoundError {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $serverErrorCode = $exception.PSObject.Properties["ServerErrorCode"]
        $serverErrorCodeText = if ($null -ne $serverErrorCode) { "$($serverErrorCode.Value)" } else { "" }
        if ($serverErrorCodeText -in @("-2147024894", "404")) {
            return $true
        }

        $response = $exception.PSObject.Properties["Response"]
        if ($null -ne $response -and $null -ne $response.Value) {
            $statusCode = $response.Value.PSObject.Properties["StatusCode"]
            $statusCodeText = if ($null -ne $statusCode) { "$($statusCode.Value)" } else { "" }
            if ($statusCodeText -match "^(404|NotFound)$") {
                return $true
            }
        }

        if ($exception.Message -match "(?i)(404|file not found|does not exist|introuvable|n'existe pas)") {
            return $true
        }

        $exception = $exception.InnerException
    }

    return $false
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

    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $configDirectory = Split-Path -Parent $ConfigPath
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
    $loggingNode = $config.Configuration.Logging
    $logDirectory = $loggingNode.LogDirectory
    $logConsoleMode = "Verbose"
    $logFileMode = "Verbose"
    $progressEveryFiles = 1000
    $progressEverySeconds = 30

    if ($null -ne $loggingNode) {
        $consoleModeNode = $loggingNode.SelectSingleNode("ConsoleMode")
        $fileModeNode = $loggingNode.SelectSingleNode("FileMode")
        $progressEveryFilesNode = $loggingNode.SelectSingleNode("ProgressEveryFiles")
        $progressEverySecondsNode = $loggingNode.SelectSingleNode("ProgressEverySeconds")

        if ($null -ne $consoleModeNode -and -not [string]::IsNullOrWhiteSpace($consoleModeNode.InnerText)) {
            $logConsoleMode = "$($consoleModeNode.InnerText)".Trim()
        }

        if ($null -ne $fileModeNode -and -not [string]::IsNullOrWhiteSpace($fileModeNode.InnerText)) {
            $logFileMode = "$($fileModeNode.InnerText)".Trim()
        }

        if ($null -ne $progressEveryFilesNode -and -not [string]::IsNullOrWhiteSpace($progressEveryFilesNode.InnerText)) {
            $progressEveryFiles = [int]$progressEveryFilesNode.InnerText
        }

        if ($null -ne $progressEverySecondsNode -and -not [string]::IsNullOrWhiteSpace($progressEverySecondsNode.InnerText)) {
            $progressEverySeconds = [int]$progressEverySecondsNode.InnerText
        }
    }

    if (-not [System.IO.Path]::IsPathRooted($sourcePath)) {
        $sourcePath = Join-Path $configDirectory $sourcePath
    }

    if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not [System.IO.Path]::IsPathRooted($logDirectory)) {
        $logDirectory = Join-Path $configDirectory $logDirectory
    }
    $migrationNode = $config.SelectSingleNode("/Configuration/Migration")
    $maxAttemptsPerFile = 3
    $maxTotalErrors = 1000
    $hashMode = "SHA256"
    $parallelInventory = 4
    $parallelUploads = 4
    $assumeDestinationEmpty = $false
    $treatTenantSyncExclusionsAsBlocked = $false
    $processingBatchSize = 1000
    $includeHiddenItems = $false

    if ($null -ne $migrationNode) {
        $maxAttemptsNode = $migrationNode.SelectSingleNode("MaxAttemptsPerFile")
        $maxTotalErrorsNode = $migrationNode.SelectSingleNode("MaxTotalErrors")
        $hashModeNode = $migrationNode.SelectSingleNode("HashMode")
        $parallelInventoryNode = $migrationNode.SelectSingleNode("ParallelInventory")
        $parallelUploadsNode = $migrationNode.SelectSingleNode("ParallelUploads")
        $assumeDestinationEmptyNode = $migrationNode.SelectSingleNode("AssumeDestinationEmpty")
        $tenantSyncExclusionsNode = $migrationNode.SelectSingleNode("TreatTenantSyncExclusionsAsBlocked")
        $processingBatchSizeNode = $migrationNode.SelectSingleNode("ProcessingBatchSize")
        $includeHiddenItemsNode = $migrationNode.SelectSingleNode("IncludeHiddenItems")

        if ($null -ne $maxAttemptsNode -and -not [string]::IsNullOrWhiteSpace($maxAttemptsNode.InnerText)) {
            $maxAttemptsPerFile = [int]$maxAttemptsNode.InnerText
        }

        if ($null -ne $maxTotalErrorsNode -and -not [string]::IsNullOrWhiteSpace($maxTotalErrorsNode.InnerText)) {
            $maxTotalErrors = [int]$maxTotalErrorsNode.InnerText
        }

        if ($null -ne $hashModeNode -and -not [string]::IsNullOrWhiteSpace($hashModeNode.InnerText)) {
            $hashMode = "$($hashModeNode.InnerText)".Trim()
        }

        if ($null -ne $parallelInventoryNode -and -not [string]::IsNullOrWhiteSpace($parallelInventoryNode.InnerText)) {
            $parallelInventory = [int]$parallelInventoryNode.InnerText
        }

        if ($null -ne $parallelUploadsNode -and -not [string]::IsNullOrWhiteSpace($parallelUploadsNode.InnerText)) {
            $parallelUploads = [int]$parallelUploadsNode.InnerText
        }

        if ($null -ne $assumeDestinationEmptyNode -and -not [string]::IsNullOrWhiteSpace($assumeDestinationEmptyNode.InnerText)) {
            $assumeDestinationEmpty = [System.Convert]::ToBoolean($assumeDestinationEmptyNode.InnerText)
        }

        if ($null -ne $tenantSyncExclusionsNode -and -not [string]::IsNullOrWhiteSpace($tenantSyncExclusionsNode.InnerText)) {
            $treatTenantSyncExclusionsAsBlocked = [System.Convert]::ToBoolean($tenantSyncExclusionsNode.InnerText)
        }

        if ($null -ne $processingBatchSizeNode -and -not [string]::IsNullOrWhiteSpace($processingBatchSizeNode.InnerText)) {
            $processingBatchSize = [int]$processingBatchSizeNode.InnerText
        }

        if ($null -ne $includeHiddenItemsNode -and -not [string]::IsNullOrWhiteSpace($includeHiddenItemsNode.InnerText)) {
            $includeHiddenItems = [System.Convert]::ToBoolean($includeHiddenItemsNode.InnerText)
        }
    }

    if ($parallelUploads -lt 1 -or $parallelUploads -gt 16) {
        throw "Migration.ParallelUploads doit etre compris entre 1 et 16."
    }

    if ($parallelInventory -lt 1 -or $parallelInventory -gt 16) {
        throw "Migration.ParallelInventory doit etre compris entre 1 et 16."
    }

    if ($processingBatchSize -lt 100 -or $processingBatchSize -gt 100000) {
        throw "Migration.ProcessingBatchSize doit etre compris entre 100 et 100000."
    }

    if ($maxAttemptsPerFile -lt 0) {
        throw "Migration.MaxAttemptsPerFile doit etre superieur ou egal a 0."
    }

    if ($maxTotalErrors -lt 0) {
        throw "Migration.MaxTotalErrors doit etre superieur ou egal a 0."
    }

    if ($hashMode -notin @("SHA256", "Quick", "None")) {
        throw "Migration.HashMode invalide: $hashMode. Valeurs autorisees: SHA256, Quick, None."
    }

    if ($logConsoleMode -notin @("Verbose", "ProgressOnly", "ErrorsOnly", "Quiet")) {
        throw "Logging.ConsoleMode invalide: $logConsoleMode. Valeurs autorisees: Verbose, ProgressOnly, ErrorsOnly, Quiet."
    }

    if ($logFileMode -notin @("Verbose", "ProgressOnly", "ErrorsOnly", "Quiet")) {
        throw "Logging.FileMode invalide: $logFileMode. Valeurs autorisees: Verbose, ProgressOnly, ErrorsOnly, Quiet."
    }

    if ($progressEveryFiles -lt 0) {
        throw "Logging.ProgressEveryFiles doit etre superieur ou egal a 0."
    }

    if ($progressEverySeconds -lt 0) {
        throw "Logging.ProgressEverySeconds doit etre superieur ou egal a 0."
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
        throw "Source.LocalPath doit etre un repertoire local: $sourcePath"
    }

    $sourceRoot = $sourceItem.FullName.TrimEnd("\", "/")
    $destination = Join-SharePointPath -SiteUrl $destinationSiteUrl -Library $destinationLibrary -Folder $destinationFolder

    return [pscustomobject]@{
        ConfigPath            = $ConfigPath
        LogDirectory          = $logDirectory
        LogConsoleMode        = $logConsoleMode
        LogFileMode           = $logFileMode
        ProgressEveryFiles    = $progressEveryFiles
        ProgressEverySeconds  = $progressEverySeconds
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
        ParallelInventory     = $parallelInventory
        ParallelUploads       = $parallelUploads
        AssumeDestinationEmpty = $assumeDestinationEmpty
        TreatTenantSyncExclusionsAsBlocked = $treatTenantSyncExclusionsAsBlocked
        ProcessingBatchSize   = $processingBatchSize
        IncludeHiddenItems    = $includeHiddenItems
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
        [pscustomobject]$Context,

        [switch]$Detailed
    )

    $childItemParameters = @{
        LiteralPath = $Context.SourceRoot
        File        = $true
        Recurse     = $true
    }

    if ($Context.IncludeHiddenItems) {
        $childItemParameters.Force = $true
    }

    $files = @(Get-ChildItem @childItemParameters)
    $includedFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new($files.Count)
    $excludedFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $excludedCount = 0

    foreach ($file in $files) {
        $relativePath = Convert-ToSharePointRelativePath -BasePath $Context.SourceRoot -FilePath $file.FullName

        if (Test-MigrationPathExcluded `
                -RelativePath $relativePath `
                -ExcludeFilePatterns $Context.ExcludeFilePatterns `
                -ExcludeFolderPatterns $Context.ExcludeFolderPatterns) {
            Write-Log -Level "INFO" -Message "[EXCLU] $relativePath"
            $excludedFiles.Add($file)
            $excludedCount++
            continue
        }

        $includedFiles.Add($file)
    }

    if ($excludedCount -gt 0) {
        Write-Log -Level "INFO" -Message "Fichiers exclus par configuration: $excludedCount"
    }

    if ($Detailed) {
        return [pscustomobject]@{
            IncludedFiles = $includedFiles.ToArray()
            ExcludedFiles = $excludedFiles.ToArray()
            TotalCount    = $files.Count
        }
    }

    return $includedFiles.ToArray()
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

function Get-InventoryBlockedExtensions {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [switch]$SkipConnection
    )

    if (-not $Context.TreatTenantSyncExclusionsAsBlocked) {
        Write-Log -Level "INFO" -Message "Les exclusions de synchronisation OneDrive ne sont pas traitees comme des blocages d'upload."
        return @()
    }

    Write-Step "Recuperation des extensions exclues de la synchronisation OneDrive"

    if ($SkipConnection) {
        Write-Log -Level "WARN" -Message "Lecture des exclusions de synchronisation ignoree car aucune connexion SharePoint n'est active."
        return @()
    }

    try {
        $blockedExtensions = @(Get-TenantSyncExcludedExtensions)

        if ($blockedExtensions.Count -gt 0) {
            Write-Log -Level "WARN" -Message "Extensions de synchronisation traitees comme bloquees par la politique de migration: $($blockedExtensions -join ', ')"
        }
        else {
            Write-Log -Level "INFO" -Message "Aucune extension exclue de la synchronisation OneDrive."
        }

        return $blockedExtensions
    }
    catch {
        Write-Log -Level "ERROR" -Message "Impossible de recuperer les exclusions de synchronisation OneDrive: $($_.Exception.Message)"
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

function Get-MigrationFileFingerprintsParallel {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo[]]$Files,

        [Parameter(Mandatory)]
        [ValidateSet("SHA256", "Quick", "None")]
        [string]$HashMode,

        [ValidateRange(1, 16)]
        [int]$ThrottleLimit = 4
    )

    return @($Files | ForEach-Object -Parallel {
        $file = $_
        $hashMode = $using:HashMode

        try {
            $fileHash = switch ($hashMode.ToUpperInvariant()) {
                "NONE" { "" }
                "QUICK" { "QUICK:$($file.Length):$($file.LastWriteTimeUtc.Ticks)" }
                "SHA256" { "SHA256:$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash)" }
            }

            [pscustomobject]@{
                FullPath = $file.FullName
                FileHash = $fileHash
                Error    = ""
            }
        }
        catch {
            [pscustomobject]@{
                FullPath = $file.FullName
                FileHash = ""
                Error    = $_.Exception.Message
            }
        }
    } -ThrottleLimit $ThrottleLimit)
}

function Assert-MigrationFingerprintBatch {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Fingerprints
    )

    $failures = @($Fingerprints | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Error) })
    if ($failures.Count -eq 0) {
        return
    }

    foreach ($failure in $failures) {
        Write-Log -Level "ERROR" -Message "[EMPREINTE] $($failure.FullPath) - $($failure.Error)"
    }

    throw "$($failures.Count) empreinte(s) de fichier n'ont pas pu etre calculees."
}

function Get-PreparedMigrationFingerprints {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.IO.FileInfo[]]$Files,

        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$ProgressLabel
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Les inventaires paralleles necessitent PowerShell 7 ou plus recent."
    }

    $prepared = [System.Collections.Generic.List[object]]::new($Files.Count)
    for ($offset = 0; $offset -lt $Files.Count; $offset += $Context.ProcessingBatchSize) {
        $lastIndex = [Math]::Min($offset + $Context.ProcessingBatchSize - 1, $Files.Count - 1)
        $batch = @($Files[$offset..$lastIndex])
        $fingerprints = @(Get-MigrationFileFingerprintsParallel `
                -Files $batch `
                -HashMode $Context.HashMode `
                -ThrottleLimit $Context.ParallelInventory)

        Assert-MigrationFingerprintBatch -Fingerprints $fingerprints
        foreach ($fingerprint in $fingerprints) {
            $prepared.Add($fingerprint)
        }

        Write-Log -Level "INFO" -Message "${ProgressLabel}: $($prepared.Count)/$($Files.Count)"
    }

    return $prepared.ToArray()
}

function Invoke-ProjectInventory {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$ProjectInfo,

        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [string[]]$BlockedExtensions
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "L'inventaire projet necessite PowerShell 7 ou plus recent."
    }

    $runId = Start-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -Mode "Inventory"

    try {
        $inventorySeenAt = (Get-Date).ToUniversalTime().ToString("o")
        $sourceInventory = Get-MigrationSourceFiles -Context $Context -Detailed
        $files = @($sourceInventory.IncludedFiles)
        $excludedFiles = @($sourceInventory.ExcludedFiles)
        Write-Step "$($sourceInventory.TotalCount) fichier(s) detecte(s) dans $($Context.SourceRoot)"
        Write-Log -Level "INFO" -Message "Mode de hash inventaire: $($Context.HashMode)"
        Write-Log -Level "INFO" -Message "Calculs d'empreinte paralleles: $($Context.ParallelInventory)"

        if ($Context.HashMode -eq "None") {
            Write-Log -Level "WARN" -Message "HashMode=None: les modifications locales ne seront pas detectees par hash."
        }

        $preparedFiles = @(Get-PreparedMigrationFingerprints `
                -Files $files `
                -Context $Context `
                -ProgressLabel "Preparation inventaire")

        $transactionResult = Invoke-MigrationDatabaseTransaction -DatabasePath $ProjectInfo.DatabasePath -Action {
            param($connection)

            $writer = New-MigrationFileWriter -SQLiteConnection $connection

            try {
                Reset-MigrationHashChanges -DatabasePath $ProjectInfo.DatabasePath -SQLiteConnection $connection

                $appliedFiles = 0
                foreach ($fingerprint in $preparedFiles) {
                    $null = Upsert-MigrationFile `
                        -DatabasePath $ProjectInfo.DatabasePath `
                        -File ([System.IO.FileInfo]::new($fingerprint.FullPath)) `
                        -SourceRoot $Context.SourceRoot `
                        -ServerRelativeRoot $Context.Destination.ServerRelativeRoot `
                        -BlockedExtensions $BlockedExtensions `
                        -InventorySeenAt $inventorySeenAt `
                        -HashMode $Context.HashMode `
                        -FileHash $fingerprint.FileHash `
                        -FingerprintProvided `
                        -SQLiteConnection $connection `
                        -Writer $writer

                    $appliedFiles++
                    if ($appliedFiles -eq $preparedFiles.Count -or $appliedFiles % $Context.ProcessingBatchSize -eq 0) {
                        Write-Log -Level "INFO" -Message "Application inventaire SQLite: $appliedFiles/$($preparedFiles.Count)"
                    }
                }

                $appliedExcluded = 0
                foreach ($file in $excludedFiles) {
                    Set-MigrationFileExcluded `
                        -DatabasePath $ProjectInfo.DatabasePath `
                        -File $file `
                        -SourceRoot $Context.SourceRoot `
                        -ServerRelativeRoot $Context.Destination.ServerRelativeRoot `
                        -InventorySeenAt $inventorySeenAt `
                        -SQLiteConnection $connection `
                        -Writer $writer

                    $appliedExcluded++
                    if ($appliedExcluded -eq $excludedFiles.Count -or $appliedExcluded % $Context.ProcessingBatchSize -eq 0) {
                        Write-Log -Level "INFO" -Message "Application exclusions SQLite: $appliedExcluded/$($excludedFiles.Count)"
                    }
                }

                $missing = Update-MissingInventoryFiles `
                    -DatabasePath $ProjectInfo.DatabasePath `
                    -InventorySeenAt $inventorySeenAt `
                    -SQLiteConnection $connection

                [pscustomobject]@{ MissingCount = $missing }
            }
            finally {
                Close-MigrationFileWriter -Writer $writer
            }
        }

        $missingCount = [int]$transactionResult.MissingCount
        if ($missingCount -gt 0) {
            Write-Log -Level "WARN" -Message "Fichiers marques MissingLocalFile pendant l'inventaire: $missingCount"
        }

        $blockedReportPath = Export-MigrationBlockedExtensionReport `
            -DatabasePath $ProjectInfo.DatabasePath `
            -ReportDirectory $ProjectInfo.ReportDirectory
        Write-Log -Level "INFO" -Message "Rapport des extensions bloquees: $blockedReportPath"

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

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Le delta inventaire necessite PowerShell 7 ou plus recent."
    }

    $runId = Start-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -Mode "DeltaInventory"

    try {
        $inventorySeenAt = (Get-Date).ToUniversalTime().ToString("o")
        $sourceInventory = Get-MigrationSourceFiles -Context $Context -Detailed
        $files = @($sourceInventory.IncludedFiles)
        $excludedFiles = @($sourceInventory.ExcludedFiles)

        Write-Step "Delta inventaire: $($sourceInventory.TotalCount) fichier(s) detecte(s) dans $($Context.SourceRoot)"
        Write-Log -Level "INFO" -Message "Mode de hash delta: $($Context.HashMode)"
        Write-Log -Level "INFO" -Message "Calculs d'empreinte paralleles: $($Context.ParallelInventory)"

        if ($Context.HashMode -eq "None") {
            Write-Log -Level "WARN" -Message "HashMode=None: seuls les nouveaux fichiers seront detectes de facon fiable."
        }

        $preparedFiles = @(Get-PreparedMigrationFingerprints `
                -Files $files `
                -Context $Context `
                -ProgressLabel "Preparation delta inventaire")

        $transactionResult = Invoke-MigrationDatabaseTransaction -DatabasePath $ProjectInfo.DatabasePath -Action {
            param($connection)

            $newCount = 0
            $changedCount = 0
            $statusChangedCount = 0
            $unchangedCount = 0
            $writer = New-MigrationFileWriter -SQLiteConnection $connection

            try {
                Reset-MigrationHashChanges -DatabasePath $ProjectInfo.DatabasePath -SQLiteConnection $connection

                $appliedFiles = 0
                foreach ($fingerprint in $preparedFiles) {
                    $file = [System.IO.FileInfo]::new($fingerprint.FullPath)
                    $upsertResult = Upsert-MigrationFile `
                        -DatabasePath $ProjectInfo.DatabasePath `
                        -File $file `
                        -SourceRoot $Context.SourceRoot `
                        -ServerRelativeRoot $Context.Destination.ServerRelativeRoot `
                        -BlockedExtensions $BlockedExtensions `
                        -InventorySeenAt $inventorySeenAt `
                        -HashMode $Context.HashMode `
                        -FileHash $fingerprint.FileHash `
                        -FingerprintProvided `
                        -SQLiteConnection $connection `
                        -Writer $writer

                    if ($upsertResult.IsNew) {
                        $newCount++
                    }
                    elseif ($upsertResult.ContentChanged) {
                        $changedCount++
                    }
                    elseif ($upsertResult.StatusChanged) {
                        $statusChangedCount++
                    }
                    else {
                        $unchangedCount++
                    }

                    $appliedFiles++
                    if ($appliedFiles -eq $preparedFiles.Count -or $appliedFiles % $Context.ProcessingBatchSize -eq 0) {
                        Write-Log -Level "INFO" -Message "Application delta SQLite: $appliedFiles/$($preparedFiles.Count)"
                    }
                }

                $appliedExcluded = 0
                foreach ($file in $excludedFiles) {
                    Set-MigrationFileExcluded `
                        -DatabasePath $ProjectInfo.DatabasePath `
                        -File $file `
                        -SourceRoot $Context.SourceRoot `
                        -ServerRelativeRoot $Context.Destination.ServerRelativeRoot `
                        -InventorySeenAt $inventorySeenAt `
                        -SQLiteConnection $connection `
                        -Writer $writer

                    $appliedExcluded++
                    if ($appliedExcluded -eq $excludedFiles.Count -or $appliedExcluded % $Context.ProcessingBatchSize -eq 0) {
                        Write-Log -Level "INFO" -Message "Application exclusions SQLite: $appliedExcluded/$($excludedFiles.Count)"
                    }
                }

                $missingCount = 0
                if ($IncludeDeleted) {
                    $missingCount = Update-MissingInventoryFiles `
                        -DatabasePath $ProjectInfo.DatabasePath `
                        -InventorySeenAt $inventorySeenAt `
                        -SQLiteConnection $connection
                }

                [pscustomobject]@{
                    NewCount           = $newCount
                    ChangedCount       = $changedCount
                    StatusChangedCount = $statusChangedCount
                    UnchangedCount     = $unchangedCount
                    MissingCount       = $missingCount
                }
            }
            finally {
                Close-MigrationFileWriter -Writer $writer
            }
        }

        $missingCount = [int]$transactionResult.MissingCount
        if ($IncludeDeleted -and $missingCount -gt 0) {
            Write-Log -Level "WARN" -Message "Fichiers marques MissingLocalFile pendant le delta: $missingCount"
        }
        elseif (-not $IncludeDeleted) {
            Write-Log -Level "INFO" -Message "Fichiers supprimes ignores pendant le delta. Utilise -IncludeDeleted pour les marquer MissingLocalFile."
        }

        $summary = "Nouveaux: $($transactionResult.NewCount); Modifies: $($transactionResult.ChangedCount); Statuts ajustes: $($transactionResult.StatusChangedCount); Inchanges: $($transactionResult.UnchangedCount); Supprimes marques: $missingCount"
        $blockedReportPath = Export-MigrationBlockedExtensionReport `
            -DatabasePath $ProjectInfo.DatabasePath `
            -ReportDirectory $ProjectInfo.ReportDirectory
        Write-Log -Level "INFO" -Message "Rapport des extensions bloquees: $blockedReportPath"
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

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Le controle des changements necessite PowerShell 7 ou plus recent."
    }

    if (-not (Test-Path -LiteralPath $ProjectInfo.ReportDirectory)) {
        New-Item -ItemType Directory -Path $ProjectInfo.ReportDirectory -Force | Out-Null
    }

    $runId = Start-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -Mode "CheckChanges"
    $reportPath = Join-Path $ProjectInfo.ReportDirectory ("migration_checkchanges_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

    try {
        $files = @(Get-MigrationSourceFiles -Context $Context)
        $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $changes = [System.Collections.Generic.List[object]]::new()

        Write-Step "Controle des changements: $($files.Count) fichier(s) detecte(s) dans $($Context.SourceRoot)"
        Write-Log -Level "INFO" -Message "Mode de hash controle: $($Context.HashMode)"

        if ($Context.HashMode -eq "None") {
            Write-Log -Level "WARN" -Message "HashMode=None: les modifications locales ne seront pas detectees par hash."
        }

        $preparedFiles = @(Get-PreparedMigrationFingerprints `
                -Files $files `
                -Context $Context `
                -ProgressLabel "Preparation controle changements")

        foreach ($fingerprint in $preparedFiles) {
            $file = [System.IO.FileInfo]::new($fingerprint.FullPath)
            [void]$seenPaths.Add($file.FullName)
            $relativePath = Convert-ToSharePointRelativePath -BasePath $Context.SourceRoot -FilePath $file.FullName
            $currentHash = $fingerprint.FileHash
            $existingFile = Get-MigrationFileByFullPath -DatabasePath $ProjectInfo.DatabasePath -FullPath $file.FullName

            if ($null -eq $existingFile) {
                $changes.Add([pscustomobject]@{
                    ChangeType       = "New"
                    RelativePath     = $relativePath
                    FullPath         = $file.FullName
                    Status           = ""
                    PreviousFileHash = ""
                    CurrentFileHash  = $currentHash
                    SizeBytes        = $file.Length
                    LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString("o")
                })
                continue
            }

            $existingHash = "$($existingFile.FileHash)"
            if ($Context.HashMode -ne "None" -and -not [string]::IsNullOrWhiteSpace($existingHash) -and $existingHash -ne $currentHash) {
                $changes.Add([pscustomobject]@{
                    ChangeType       = "Modified"
                    RelativePath     = $relativePath
                    FullPath         = $file.FullName
                    Status           = $existingFile.Status
                    PreviousFileHash = $existingHash
                    CurrentFileHash  = $currentHash
                    SizeBytes        = $file.Length
                    LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString("o")
                })
            }
        }

        if ($IncludeDeleted) {
            $knownFiles = @(Invoke-SqliteQuery -DataSource $ProjectInfo.DatabasePath -Query "SELECT FullPath, RelativePath, Status, FileHash, SizeBytes, LastWriteTimeUtc FROM Files WHERE Status <> 'DeletedRemote' ORDER BY RelativePath;" -As "PSObject")
            foreach ($knownFile in $knownFiles) {
                if (-not $seenPaths.Contains("$($knownFile.FullPath)") -and -not (Test-Path -LiteralPath $knownFile.FullPath)) {
                    $changes.Add([pscustomobject]@{
                        ChangeType       = "Deleted"
                        RelativePath     = $knownFile.RelativePath
                        FullPath         = $knownFile.FullPath
                        Status           = $knownFile.Status
                        PreviousFileHash = $knownFile.FileHash
                        CurrentFileHash  = ""
                        SizeBytes        = $knownFile.SizeBytes
                        LastWriteTimeUtc = $knownFile.LastWriteTimeUtc
                    })
                }
            }
        }

        Export-CsvWithHeaders `
            -Rows $changes.ToArray() `
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

function Invoke-ParallelMigrationUploads {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [ValidateRange(1, 16)]
        [int]$ThrottleLimit = 4,

        [ValidateRange(1, 1000)]
        [int]$TaskSize = 25,

        [int]$MaxAttemptsPerFile = 3,

        [switch]$Overwrite,

        [switch]$AssumeDestinationEmpty
    )

    if ($Rows.Count -eq 0) {
        return
    }

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Les uploads paralleles necessitent PowerShell 7 ou plus recent."
    }

    $siteUrl = $Context.Destination.SiteUrl
    $tenantId = $Context.TenantId
    $clientId = $Context.ClientId
    $certificateThumbprint = $Context.CertificateThumbprint
    $destinationRoot = $Context.Destination.ServerRelativeRoot.TrimEnd("/")
    $databasePathValue = $DatabasePath
    $overwriteEnabled = [bool]$Overwrite
    $skipExistenceCheck = [bool]$AssumeDestinationEmpty
    $maxAttempts = $MaxAttemptsPerFile

    $folderTasks = @($Rows | Group-Object -Property TargetFolder | ForEach-Object {
        $folderRows = @($_.Group)

        for ($offset = 0; $offset -lt $folderRows.Count; $offset += $TaskSize) {
            $lastIndex = [Math]::Min($offset + $TaskSize - 1, $folderRows.Count - 1)
            [pscustomobject]@{
                TargetFolder = $_.Name
                Rows         = @($folderRows[$offset..$lastIndex])
            }
        }
    })

    $folderTasks | ForEach-Object -Parallel {
        $task = $_
        $operation = "Connexion SharePoint"
        $rootFolder = $using:destinationRoot

        function Test-PnPNotFoundError {
            param([System.Management.Automation.ErrorRecord]$ErrorRecord)

            $exception = $ErrorRecord.Exception
            while ($null -ne $exception) {
                $serverErrorCode = $exception.PSObject.Properties["ServerErrorCode"]
                $serverErrorCodeText = if ($null -ne $serverErrorCode) { "$($serverErrorCode.Value)" } else { "" }
                if ($serverErrorCodeText -in @("-2147024894", "404")) {
                    return $true
                }

                $response = $exception.PSObject.Properties["Response"]
                if ($null -ne $response -and $null -ne $response.Value) {
                    $statusCode = $response.Value.PSObject.Properties["StatusCode"]
                    $statusCodeText = if ($null -ne $statusCode) { "$($statusCode.Value)" } else { "" }
                    if ($statusCodeText -match "^(404|NotFound)$") {
                        return $true
                    }
                }

                if ($exception.Message -match "(?i)(404|file not found|does not exist|introuvable|n'existe pas)") {
                    return $true
                }

                $exception = $exception.InnerException
            }

            return $false
        }

        function Test-PnPTransientFolderError {
            param([System.Management.Automation.ErrorRecord]$ErrorRecord)

            $exception = $ErrorRecord.Exception
            while ($null -ne $exception) {
                if ($exception.Message -match "(?i)(nullable object must have a value|object reference not set|timeout|temporar|throttl|429|502|503|connection|conflict|already exists|existe deja)") {
                    return $true
                }

                $exception = $exception.InnerException
            }

            return $false
        }

        function Connect-PnPOnlineWithRetry {
            param(
                [Parameter(Mandatory)]
                [string]$Url,

                [Parameter(Mandatory)]
                [string]$Tenant,

                [Parameter(Mandatory)]
                [string]$ClientId,

                [Parameter(Mandatory)]
                [string]$Thumbprint,

                [int]$MaxAttempts = 5
            )

            for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                try {
                    return Connect-PnPOnline `
                        -Url $Url `
                        -Tenant $Tenant `
                        -ClientId $ClientId `
                        -Thumbprint $Thumbprint `
                        -ReturnConnection `
                        -ErrorAction Stop
                }
                catch {
                    if ($attempt -ge $MaxAttempts -or -not (Test-PnPTransientFolderError -ErrorRecord $_)) {
                        throw
                    }

                    Start-Sleep -Milliseconds (500 * $attempt)
                }
            }
        }

        function Get-PnPFolderWithRetry {
            param(
                [Parameter(Mandatory)]
                [string]$Url,

                [Parameter(Mandatory)]
                $Connection,

                [int]$MaxAttempts = 5
            )

            for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                try {
                    Get-PnPFolder -Url $Url -Connection $Connection -ErrorAction Stop | Out-Null
                    return
                }
                catch {
                    if ($attempt -ge $MaxAttempts -or -not (Test-PnPTransientFolderError -ErrorRecord $_)) {
                        throw
                    }

                    Start-Sleep -Milliseconds (200 * $attempt)
                }
            }
        }

        function Add-PnPFolderWithRetry {
            param(
                [Parameter(Mandatory)]
                [string]$Name,

                [Parameter(Mandatory)]
                [string]$Folder,

                [Parameter(Mandatory)]
                [string]$Url,

                [Parameter(Mandatory)]
                $Connection,

                [int]$MaxAttempts = 5
            )

            for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                try {
                    Add-PnPFolder -Name $Name -Folder $Folder -Connection $Connection -ErrorAction Stop | Out-Null
                    Get-PnPFolderWithRetry -Url $Url -Connection $Connection -MaxAttempts $MaxAttempts
                    return
                }
                catch {
                    try {
                        Get-PnPFolderWithRetry -Url $Url -Connection $Connection -MaxAttempts $MaxAttempts
                        return
                    }
                    catch {
                        if ($attempt -ge $MaxAttempts -or -not (Test-PnPTransientFolderError -ErrorRecord $_)) {
                            throw "Impossible de creer ou verifier le dossier SharePoint '$Url' apres $attempt tentative(s): $($_.Exception.Message)"
                        }
                    }

                    Start-Sleep -Milliseconds (250 * $attempt)
                }
            }
        }

        try {
            $connectionVariable = Get-Variable -Name MigrationPnPConnection -Scope Script -ErrorAction SilentlyContinue
            if ($null -eq $connectionVariable -or $null -eq $connectionVariable.Value) {
                Import-Module PnP.PowerShell -ErrorAction Stop
                Import-Module PSSQLite -ErrorAction Stop
                $script:MigrationPnPConnection = Connect-PnPOnlineWithRetry `
                    -Url $using:siteUrl `
                    -Tenant $using:tenantId `
                    -ClientId $using:clientId `
                    -Thumbprint $using:certificateThumbprint
            }

            $connection = $script:MigrationPnPConnection
            $operation = "Creation/verification du dossier SharePoint"
            $targetFolder = "$($task.TargetFolder)".TrimEnd("/")
            if ($targetFolder -ne $rootFolder -and -not $targetFolder.StartsWith("$rootFolder/", [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Chemin SharePoint invalide: $($task.TargetFolder)"
            }

            $currentFolder = $rootFolder
            Get-PnPFolderWithRetry -Url $currentFolder -Connection $connection
            $relativeFolder = $targetFolder.Substring($rootFolder.Length).Trim("/")
            $parts = @($relativeFolder -split "/" | Where-Object { $_ })

            for ($i = 0; $i -lt $parts.Count; $i++) {
                $parentFolder = $currentFolder
                $currentFolder = "$currentFolder/$($parts[$i])"

                try {
                    Get-PnPFolderWithRetry -Url $currentFolder -Connection $connection
                }
                catch {
                    if (-not (Test-PnPNotFoundError -ErrorRecord $_)) {
                        throw "Verification du dossier SharePoint impossible: $currentFolder - $($_.Exception.Message)"
                    }

                    Add-PnPFolderWithRetry -Name $parts[$i] -Folder $parentFolder -Url $currentFolder -Connection $connection
                }
            }
        }
        catch {
            foreach ($row in $task.Rows) {
                [pscustomobject]@{
                    Id           = [int]$row.Id
                    RelativePath = "$($row.RelativePath)"
                    TargetUrl    = "$($row.TargetUrl)"
                    SizeBytes    = [long]$row.SizeBytes
                    Status       = if ("$($row.Status)" -eq "Uploading") { "RetryUncertain" } else { "Failed" }
                    Message      = "Operation: $operation - Cible: $($row.TargetUrl) - $($_.Exception.Message)"
                    AttemptStarted = "$($row.Status)" -eq "Uploading"
                }
            }
            return
        }

        foreach ($row in $task.Rows) {
            $isInterruptedUpload = "$($row.Status)" -eq "Uploading"
            $operation = "Verification de l'existence du fichier SharePoint"
            $attemptStarted = $isInterruptedUpload
            $newAttemptStarted = $false

            try {
                $fileExists = $false
                $mustCheckExistence = (-not $using:skipExistenceCheck) -or $isInterruptedUpload

                if ($mustCheckExistence) {
                    try {
                        Get-PnPFile -Url $row.TargetUrl -Connection $connection -ErrorAction Stop | Out-Null
                        $fileExists = $true
                    }
                    catch {
                        if (Test-PnPNotFoundError -ErrorRecord $_) {
                            $fileExists = $false
                        }
                        else {
                            throw
                        }
                    }
                }

                if ($fileExists -and ((-not $using:overwriteEnabled) -or $isInterruptedUpload)) {
                    [pscustomobject]@{
                        Id             = [int]$row.Id
                        RelativePath   = "$($row.RelativePath)"
                        TargetUrl      = "$($row.TargetUrl)"
                        SizeBytes      = [long]$row.SizeBytes
                        Status         = "SkippedExists"
                        Message        = if ($isInterruptedUpload) { "Upload precedent confirme dans SharePoint" } else { "Existe deja dans SharePoint" }
                        AttemptStarted = $true
                    }
                    continue
                }

                if ($isInterruptedUpload -and $using:maxAttempts -gt 0 -and [int]$row.AttemptCount -ge $using:maxAttempts) {
                    [pscustomobject]@{
                        Id             = [int]$row.Id
                        RelativePath   = "$($row.RelativePath)"
                        TargetUrl      = "$($row.TargetUrl)"
                        SizeBytes      = [long]$row.SizeBytes
                        Status         = "Failed"
                        Message        = "Upload precedent absent de SharePoint et limite de tentatives atteinte ($($row.AttemptCount)/$using:maxAttempts)"
                        AttemptStarted = $true
                    }
                    continue
                }

                $operation = "Initialisation de la tentative SQLite"
                $now = (Get-Date).ToUniversalTime().ToString("o")
                Invoke-SqliteQuery `
                    -DataSource $using:databasePathValue `
                    -Query "PRAGMA busy_timeout=30000; UPDATE Files SET Status = 'Uploading', LastError = '', UpdatedAt = @UpdatedAt, AttemptCount = AttemptCount + 1 WHERE Id = @Id;" `
                    -SqlParameters @{ UpdatedAt = $now; Id = [int]$row.Id } | Out-Null
                $attemptStarted = $true
                $newAttemptStarted = $true

                if ($fileExists -and $using:overwriteEnabled) {
                    $operation = "Suppression du fichier cible avant ecrasement"
                    Remove-PnPFile -ServerRelativeUrl $row.TargetUrl -Force -Connection $connection -ErrorAction Stop
                }

                $operation = "Upload du fichier vers SharePoint"
                Add-PnPFile -Path $row.FullPath -Folder $row.TargetFolder -Connection $connection -ErrorAction Stop | Out-Null

                [pscustomobject]@{
                    Id             = [int]$row.Id
                    RelativePath   = "$($row.RelativePath)"
                    TargetUrl      = "$($row.TargetUrl)"
                    SizeBytes      = [long]$row.SizeBytes
                    Status         = "Uploaded"
                    Message        = ""
                    AttemptStarted = $attemptStarted
                }
            }
            catch {
                [pscustomobject]@{
                    Id             = [int]$row.Id
                    RelativePath   = "$($row.RelativePath)"
                    TargetUrl      = "$($row.TargetUrl)"
                    SizeBytes      = [long]$row.SizeBytes
                    Status         = if ($isInterruptedUpload -and -not $newAttemptStarted) { "RetryUncertain" } else { "Failed" }
                    Message        = "Operation: $operation - Cible: $($row.TargetUrl) - $($_.Exception.Message)"
                    AttemptStarted = $attemptStarted
                }
            }
        }
    } -ThrottleLimit $ThrottleLimit
}

function Start-MigrationUploadWorker {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.BlockingCollection[object]]$WorkQueue,

        [Parameter(Mandatory)]
        [System.Collections.Concurrent.BlockingCollection[object]]$ResultQueue,

        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [int]$WorkerId,

        [int]$MaxAttemptsPerFile = 3,

        [switch]$Overwrite,

        [switch]$AssumeDestinationEmpty
    )

    Start-ThreadJob -Name "MigrationUpload-$WorkerId" -ArgumentList @(
        $WorkQueue,
        $ResultQueue,
        $Context,
        $DatabasePath,
        [bool]$Overwrite,
        [bool]$AssumeDestinationEmpty,
        $MaxAttemptsPerFile
    ) -ScriptBlock {
        param(
            $Queue,
            $Results,
            $WorkerContext,
            $WorkerDatabasePath,
            [bool]$WorkerOverwrite,
            [bool]$WorkerAssumeDestinationEmpty,
            [int]$WorkerMaxAttempts
        )

        function Test-PnPNotFoundError {
            param([System.Management.Automation.ErrorRecord]$ErrorRecord)

            $exception = $ErrorRecord.Exception
            while ($null -ne $exception) {
                $serverErrorCode = $exception.PSObject.Properties["ServerErrorCode"]
                $serverErrorCodeText = if ($null -ne $serverErrorCode) { "$($serverErrorCode.Value)" } else { "" }
                if ($serverErrorCodeText -in @("-2147024894", "404")) {
                    return $true
                }

                $response = $exception.PSObject.Properties["Response"]
                if ($null -ne $response -and $null -ne $response.Value) {
                    $statusCode = $response.Value.PSObject.Properties["StatusCode"]
                    $statusCodeText = if ($null -ne $statusCode) { "$($statusCode.Value)" } else { "" }
                    if ($statusCodeText -match "^(404|NotFound)$") {
                        return $true
                    }
                }

                if ($exception.Message -match "(?i)(404|file not found|does not exist|introuvable|n'existe pas)") {
                    return $true
                }

                $exception = $exception.InnerException
            }

            return $false
        }

        function Test-PnPTransientFolderError {
            param([System.Management.Automation.ErrorRecord]$ErrorRecord)

            $exception = $ErrorRecord.Exception
            while ($null -ne $exception) {
                if ($exception.Message -match "(?i)(nullable object must have a value|object reference not set|timeout|temporar|throttl|429|502|503|connection|conflict|already exists|existe deja)") {
                    return $true
                }

                $exception = $exception.InnerException
            }

            return $false
        }

        function Connect-PnPOnlineWithRetry {
            param(
                [Parameter(Mandatory)]
                [string]$Url,

                [Parameter(Mandatory)]
                [string]$Tenant,

                [Parameter(Mandatory)]
                [string]$ClientId,

                [Parameter(Mandatory)]
                [string]$Thumbprint,

                [int]$MaxAttempts = 5
            )

            for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                try {
                    return Connect-PnPOnline `
                        -Url $Url `
                        -Tenant $Tenant `
                        -ClientId $ClientId `
                        -Thumbprint $Thumbprint `
                        -ReturnConnection `
                        -ErrorAction Stop
                }
                catch {
                    if ($attempt -ge $MaxAttempts -or -not (Test-PnPTransientFolderError -ErrorRecord $_)) {
                        throw
                    }

                    Start-Sleep -Milliseconds (500 * $attempt)
                }
            }
        }

        function Get-PnPFolderWithRetry {
            param(
                [Parameter(Mandatory)]
                [string]$Url,

                [Parameter(Mandatory)]
                $Connection,

                [int]$MaxAttempts = 5
            )

            for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                try {
                    Get-PnPFolder -Url $Url -Connection $Connection -ErrorAction Stop | Out-Null
                    return
                }
                catch {
                    if ($attempt -ge $MaxAttempts -or -not (Test-PnPTransientFolderError -ErrorRecord $_)) {
                        throw
                    }

                    Start-Sleep -Milliseconds (200 * $attempt)
                }
            }
        }

        function Add-PnPFolderWithRetry {
            param(
                [Parameter(Mandatory)]
                [string]$Name,

                [Parameter(Mandatory)]
                [string]$Folder,

                [Parameter(Mandatory)]
                [string]$Url,

                [Parameter(Mandatory)]
                $Connection,

                [int]$MaxAttempts = 5
            )

            for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                try {
                    Add-PnPFolder -Name $Name -Folder $Folder -Connection $Connection -ErrorAction Stop | Out-Null
                    Get-PnPFolderWithRetry -Url $Url -Connection $Connection -MaxAttempts $MaxAttempts
                    return
                }
                catch {
                    try {
                        Get-PnPFolderWithRetry -Url $Url -Connection $Connection -MaxAttempts $MaxAttempts
                        return
                    }
                    catch {
                        if ($attempt -ge $MaxAttempts -or -not (Test-PnPTransientFolderError -ErrorRecord $_)) {
                            throw "Impossible de creer ou verifier le dossier SharePoint '$Url' apres $attempt tentative(s): $($_.Exception.Message)"
                        }
                    }

                    Start-Sleep -Milliseconds (250 * $attempt)
                }
            }
        }

        $connection = $null
        $siteUrl = $WorkerContext.Destination.SiteUrl
        $tenantId = $WorkerContext.TenantId
        $clientId = $WorkerContext.ClientId
        $certificateThumbprint = $WorkerContext.CertificateThumbprint
        $rootFolder = $WorkerContext.Destination.ServerRelativeRoot.TrimEnd("/")

        foreach ($row in $Queue.GetConsumingEnumerable()) {
            $operation = "Connexion SharePoint"
            $attemptStarted = "$($row.Status)" -eq "Uploading"
            $newAttemptStarted = $false
            $isInterruptedUpload = "$($row.Status)" -eq "Uploading"

            try {
                if ($null -eq $connection) {
                    Import-Module PnP.PowerShell -ErrorAction Stop
                    Import-Module PSSQLite -ErrorAction Stop
                    $connection = Connect-PnPOnlineWithRetry `
                        -Url $siteUrl `
                        -Tenant $tenantId `
                        -ClientId $clientId `
                        -Thumbprint $certificateThumbprint
                }

                $operation = "Creation/verification du dossier SharePoint"
                $targetFolder = "$($row.TargetFolder)".TrimEnd("/")
                if ($targetFolder -ne $rootFolder -and -not $targetFolder.StartsWith("$rootFolder/", [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Chemin SharePoint invalide: $($row.TargetFolder)"
                }

                $currentFolder = $rootFolder
                Get-PnPFolderWithRetry -Url $currentFolder -Connection $connection
                $relativeFolder = $targetFolder.Substring($rootFolder.Length).Trim("/")
                $parts = @($relativeFolder -split "/" | Where-Object { $_ })

                for ($i = 0; $i -lt $parts.Count; $i++) {
                    $parentFolder = $currentFolder
                    $currentFolder = "$currentFolder/$($parts[$i])"

                    try {
                        Get-PnPFolderWithRetry -Url $currentFolder -Connection $connection
                    }
                    catch {
                        if (-not (Test-PnPNotFoundError -ErrorRecord $_)) {
                            throw "Verification du dossier SharePoint impossible: $currentFolder - $($_.Exception.Message)"
                        }

                        Add-PnPFolderWithRetry -Name $parts[$i] -Folder $parentFolder -Url $currentFolder -Connection $connection
                    }
                }

                $operation = "Verification de l'existence du fichier SharePoint"
                $fileExists = $false
                $mustCheckExistence = (-not $WorkerAssumeDestinationEmpty) -or $isInterruptedUpload

                if ($mustCheckExistence) {
                    try {
                        Get-PnPFile -Url $row.TargetUrl -Connection $connection -ErrorAction Stop | Out-Null
                        $fileExists = $true
                    }
                    catch {
                        if (Test-PnPNotFoundError -ErrorRecord $_) {
                            $fileExists = $false
                        }
                        else {
                            throw
                        }
                    }
                }

                if ($fileExists -and ((-not $WorkerOverwrite) -or $isInterruptedUpload)) {
                    $Results.Add([pscustomobject]@{
                        Id             = [int]$row.Id
                        RelativePath   = "$($row.RelativePath)"
                        TargetUrl      = "$($row.TargetUrl)"
                        SizeBytes      = [long]$row.SizeBytes
                        Status         = "SkippedExists"
                        Message        = if ($isInterruptedUpload) { "Upload precedent confirme dans SharePoint" } else { "Existe deja dans SharePoint" }
                        AttemptStarted = $true
                    })
                    continue
                }

                if ($isInterruptedUpload -and $WorkerMaxAttempts -gt 0 -and [int]$row.AttemptCount -ge $WorkerMaxAttempts) {
                    $Results.Add([pscustomobject]@{
                        Id             = [int]$row.Id
                        RelativePath   = "$($row.RelativePath)"
                        TargetUrl      = "$($row.TargetUrl)"
                        SizeBytes      = [long]$row.SizeBytes
                        Status         = "Failed"
                        Message        = "Upload precedent absent de SharePoint et limite de tentatives atteinte ($($row.AttemptCount)/$WorkerMaxAttempts)"
                        AttemptStarted = $true
                    })
                    continue
                }

                $operation = "Initialisation de la tentative SQLite"
                $now = (Get-Date).ToUniversalTime().ToString("o")
                Invoke-SqliteQuery `
                    -DataSource $WorkerDatabasePath `
                    -Query "PRAGMA busy_timeout=30000; UPDATE Files SET Status = 'Uploading', LastError = '', UpdatedAt = @UpdatedAt, AttemptCount = AttemptCount + 1 WHERE Id = @Id;" `
                    -SqlParameters @{ UpdatedAt = $now; Id = [int]$row.Id } | Out-Null
                $attemptStarted = $true
                $newAttemptStarted = $true

                if ($fileExists -and $WorkerOverwrite) {
                    $operation = "Suppression du fichier cible avant ecrasement"
                    Remove-PnPFile -ServerRelativeUrl $row.TargetUrl -Force -Connection $connection -ErrorAction Stop
                }

                $operation = "Upload du fichier vers SharePoint"
                Add-PnPFile -Path $row.FullPath -Folder $row.TargetFolder -Connection $connection -ErrorAction Stop | Out-Null

                $Results.Add([pscustomobject]@{
                    Id             = [int]$row.Id
                    RelativePath   = "$($row.RelativePath)"
                    TargetUrl      = "$($row.TargetUrl)"
                    SizeBytes      = [long]$row.SizeBytes
                    Status         = "Uploaded"
                    Message        = ""
                    AttemptStarted = $attemptStarted
                })
            }
            catch {
                $Results.Add([pscustomobject]@{
                    Id             = [int]$row.Id
                    RelativePath   = "$($row.RelativePath)"
                    TargetUrl      = "$($row.TargetUrl)"
                    SizeBytes      = [long]$row.SizeBytes
                    Status         = if ($isInterruptedUpload -and -not $newAttemptStarted) { "RetryUncertain" } else { "Failed" }
                    Message        = "Operation: $operation - Cible: $($row.TargetUrl) - $($_.Exception.Message)"
                    AttemptStarted = $attemptStarted
                })
            }
        }
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

        [switch]$DeleteRemoteMissing,

        [ValidateRange(1, 16)]
        [int]$ParallelUploads = 4,

        [int]$MaxFiles = 0,

        [switch]$AssumeDestinationEmpty
    )

    if ($MaxFiles -lt 0) {
        throw "MaxFiles doit etre superieur ou egal a 0."
    }

    Reset-IncompleteUploads -DatabasePath $ProjectInfo.DatabasePath
    $availableFilesToProcess = Get-MigrationFilesToProcessCount `
        -DatabasePath $ProjectInfo.DatabasePath `
        -IncludeFailed:$IncludeFailed `
        -MaxAttemptsPerFile $Context.MaxAttemptsPerFile
    $totalFilesToProcess = if ($MaxFiles -gt 0) {
        [Math]::Min($availableFilesToProcess, $MaxFiles)
    }
    else {
        $availableFilesToProcess
    }
    $remoteDeleteCandidates = [System.Collections.Generic.List[object]]::new()
    if ($DeleteRemoteMissing) {
        foreach ($candidate in @(Get-MigrationRemoteDeleteCandidates `
                -DatabasePath $ProjectInfo.DatabasePath `
                -MaxAttemptsPerFile $Context.MaxAttemptsPerFile)) {
            $remoteDeleteCandidates.Add($candidate)
        }
    }
    $runMode = if ($IncludeFailed) { "Resume" } else { "Migrate" }
    $runId = Start-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -Mode $runMode

    $uploaded = 0
    $skipped = 0
    $deletedRemote = 0
    $failed = 0
    $maxTotalErrors = [int]$Context.MaxTotalErrors

    try {
        Write-Step "$totalFilesToProcess fichier(s) a traiter depuis la base projet"
        if ($DeleteRemoteMissing) {
            Write-Step "$($remoteDeleteCandidates.Count) fichier(s) distant(s) a supprimer car absents localement"
        }
        Write-Log -Level "INFO" -Message "Tentatives max par fichier: $($Context.MaxAttemptsPerFile)"
        Write-Log -Level "INFO" -Message "Erreurs max avant arret: $maxTotalErrors"
        Write-Log -Level "INFO" -Message "Suppression distante MissingLocalFile: $DeleteRemoteMissing"
        Write-Log -Level "INFO" -Message "Uploads paralleles: $ParallelUploads"
        if ($MaxFiles -gt 0) {
            Write-Log -Level "INFO" -Message "Limite fichiers de ce run: $MaxFiles (disponibles: $availableFilesToProcess)"
        }
        Write-Log -Level "INFO" -Message "Taille des pages SQLite: $($Context.ProcessingBatchSize)"
        Write-Log -Level "INFO" -Message "Controle d'existence distant ignore: $AssumeDestinationEmpty"
        if ($AssumeDestinationEmpty) {
            Write-Log -Level "WARN" -Message "Le mode AssumeDestinationEmpty peut ecraser un fichier distant non reference dans la base projet."
        }

        if ($PSVersionTable.PSVersion.Major -lt 7) {
            throw "Les uploads continus necessitent PowerShell 7 ou plus recent."
        }

        $afterFileId = 0
        $processedFileCount = 0
        $enqueuedUploads = 0
        $completedUploads = 0
        $producerDone = $false
        $currentPage = @()
        $currentPageIndex = 0
        $lastProgressFileCount = 0
        $lastProgressLogAt = Get-Date
        $queueCapacity = [Math]::Max($ParallelUploads * 4, $ParallelUploads)
        $workQueue = [System.Collections.Concurrent.BlockingCollection[object]]::new($queueCapacity)
        $resultQueue = [System.Collections.Concurrent.BlockingCollection[object]]::new()
        $workers = @()

        function Receive-MigrationUploadResult {
            param(
                [Parameter(Mandatory)]
                [object]$Result
            )

            $script:MigrationResultHandled = $true
            $fileSize = Format-FileSize -Bytes ([long]$Result.SizeBytes)
            $incrementAttempt = -not [bool]$Result.AttemptStarted

            switch ($Result.Status) {
                "Uploaded" {
                    Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $Result.Id -Status "Uploaded" -LastError "" -IncrementAttempt:$incrementAttempt -SetUploadedAt
                    Write-Log -Level "SUCCESS" -Message "[OK] $($Result.RelativePath) - Cible: $($Result.TargetUrl) - Taille: $fileSize"
                    $script:MigrationUploaded++
                }
                "SkippedExists" {
                    Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $Result.Id -Status "SkippedExists" -LastError $Result.Message -IncrementAttempt:$incrementAttempt
                    Write-Log -Level "WARN" -Message "[SKIP] Existe deja: $($Result.TargetUrl) - Taille: $fileSize"
                    $script:MigrationSkipped++
                }
                "RetryUncertain" {
                    Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $Result.Id -Status "Uploading" -LastError $Result.Message
                    Write-Log -Level "ERROR" -Message "[INCERTAIN] $($Result.RelativePath) - Taille: $fileSize - $($Result.Message)"
                    $script:MigrationFailed++
                }
                default {
                    Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $Result.Id -Status "Failed" -LastError $Result.Message -IncrementAttempt:$incrementAttempt
                    Write-Log -Level "ERROR" -Message "[ERREUR] $($Result.RelativePath) - Taille: $fileSize - $($Result.Message)"
                    $script:MigrationFailed++
                }
            }
        }

        $script:MigrationUploaded = $uploaded
        $script:MigrationSkipped = $skipped
        $script:MigrationFailed = $failed
        $script:MigrationResultHandled = $false

        function Write-MigrationProgressIfNeeded {
            param(
                [Parameter(Mandatory)]
                [int]$ProcessedCount,

                [Parameter(Mandatory)]
                [int]$TotalCount,

                [switch]$Force
            )

            if ($TotalCount -le 0 -or $ProcessedCount -le 0) {
                return
            }

            $now = Get-Date
            $fileThresholdReached = $Context.ProgressEveryFiles -gt 0 -and ($ProcessedCount - $script:LastMigrationProgressFileCount) -ge $Context.ProgressEveryFiles
            $timeThresholdReached = $Context.ProgressEverySeconds -gt 0 -and ($now - $script:LastMigrationProgressLogAt).TotalSeconds -ge $Context.ProgressEverySeconds

            if ($Force -or $ProcessedCount -eq $TotalCount -or $fileThresholdReached -or $timeThresholdReached) {
                if ($ProcessedCount -ne $script:LastMigrationProgressFileCount -or $Force) {
                    Write-Log -Level "INFO" -Message "Progression du run: $ProcessedCount/$TotalCount"
                    $script:LastMigrationProgressFileCount = $ProcessedCount
                    $script:LastMigrationProgressLogAt = $now
                }
            }
        }

        $script:LastMigrationProgressFileCount = $lastProgressFileCount
        $script:LastMigrationProgressLogAt = $lastProgressLogAt

        try {
            for ($workerId = 1; $workerId -le $ParallelUploads; $workerId++) {
                $workers += Start-MigrationUploadWorker `
                    -WorkQueue $workQueue `
                    -ResultQueue $resultQueue `
                    -Context $Context `
                    -DatabasePath $ProjectInfo.DatabasePath `
                    -WorkerId $workerId `
                    -MaxAttemptsPerFile $Context.MaxAttemptsPerFile `
                    -Overwrite:$Overwrite `
                    -AssumeDestinationEmpty:$AssumeDestinationEmpty
            }

            while (-not $producerDone -or $completedUploads -lt $enqueuedUploads) {
                $madeProgress = $false

                while (-not $producerDone -and -not $workQueue.IsAddingCompleted -and $workQueue.Count -lt $queueCapacity) {
                    if ($currentPageIndex -ge $currentPage.Count) {
                        $batchSize = $Context.ProcessingBatchSize
                        if ($MaxFiles -gt 0) {
                            $remainingFiles = $MaxFiles - ($processedFileCount + $enqueuedUploads - $completedUploads)
                            if ($remainingFiles -le 0) {
                                $producerDone = $true
                                $workQueue.CompleteAdding()
                                break
                            }

                            $batchSize = [Math]::Min($Context.ProcessingBatchSize, $remainingFiles)
                        }

                        $currentPage = @(Get-MigrationFilesToProcess `
                            -DatabasePath $ProjectInfo.DatabasePath `
                            -IncludeFailed:$IncludeFailed `
                            -MaxAttemptsPerFile $Context.MaxAttemptsPerFile `
                            -AfterId $afterFileId `
                            -BatchSize $batchSize)

                        $currentPageIndex = 0
                        if ($currentPage.Count -eq 0) {
                            $producerDone = $true
                            $workQueue.CompleteAdding()
                            break
                        }

                        $afterFileId = [int](($currentPage | Measure-Object -Property Id -Maximum).Maximum)
                    }

                    if ($producerDone -or $currentPageIndex -ge $currentPage.Count) {
                        break
                    }

                    $row = $currentPage[$currentPageIndex]
                    $currentPageIndex++
                    $fileSize = Format-FileSize -Bytes ([long]$row.SizeBytes)

                    if (-not (Test-Path -LiteralPath $row.FullPath)) {
                        Write-Log -Level "WARN" -Message "[MANQUANT] $($row.RelativePath) - $($row.FullPath)"

                        if ($DeleteRemoteMissing) {
                            if ($WhatIf) {
                                Write-Log -Level "INFO" -Message "[WHATIF] Suppression distante du fichier local manquant: $($row.TargetUrl)"
                            }
                            else {
                                Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $row.Id -Status "MissingLocalFile" -LastError "Fichier local introuvable"
                                $remoteDeleteCandidates.Add($row)
                            }
                        }
                        else {
                            Update-MigrationFileStatus -DatabasePath $ProjectInfo.DatabasePath -Id $row.Id -Status "MissingLocalFile" -LastError "Fichier local introuvable"
                            $script:MigrationFailed++
                            if ($maxTotalErrors -gt 0 -and $script:MigrationFailed -ge $maxTotalErrors) {
                                throw "Seuil d'erreurs atteint ($script:MigrationFailed/$maxTotalErrors). Arret de la migration."
                            }
                        }

                        $processedFileCount++
                        Write-MigrationProgressIfNeeded -ProcessedCount $processedFileCount -TotalCount $totalFilesToProcess
                        $madeProgress = $true
                        continue
                    }

                    if ($WhatIf) {
                        Write-Log -Level "INFO" -Message "[WHATIF] $($row.FullPath) -> $($row.TargetUrl) - Taille: $fileSize"
                        $processedFileCount++
                        Write-MigrationProgressIfNeeded -ProcessedCount $processedFileCount -TotalCount $totalFilesToProcess
                        $madeProgress = $true
                        continue
                    }

                    if ($workQueue.TryAdd($row, 100)) {
                        $enqueuedUploads++
                        $madeProgress = $true
                    }
                    else {
                        $currentPageIndex--
                        break
                    }
                }

                $result = $null
                while ($resultQueue.TryTake([ref]$result, 50)) {
                    Receive-MigrationUploadResult -Result $result
                    $completedUploads++
                    $processedFileCount++
                    $madeProgress = $true

                    Write-MigrationProgressIfNeeded -ProcessedCount $processedFileCount -TotalCount $totalFilesToProcess

                    if ($maxTotalErrors -gt 0 -and $script:MigrationFailed -ge $maxTotalErrors) {
                        throw "Seuil d'erreurs atteint ($script:MigrationFailed/$maxTotalErrors). Arret de la migration."
                    }

                    $result = $null
                }

                if (-not $madeProgress) {
                    Start-Sleep -Milliseconds 100
                }
            }
        }
        finally {
            if (-not $workQueue.IsAddingCompleted) {
                $workQueue.CompleteAdding()
            }

            if ($completedUploads -ge $enqueuedUploads -and $workers.Count -gt 0) {
                Wait-Job -Job $workers -Timeout 30 -ErrorAction SilentlyContinue | Out-Null
            }

            foreach ($worker in $workers) {
                if ($worker.State -eq "Running") {
                    Stop-Job -Job $worker -ErrorAction SilentlyContinue
                }

                Receive-Job -Job $worker -ErrorAction SilentlyContinue | Out-Null
                Remove-Job -Job $worker -Force -ErrorAction SilentlyContinue
            }

            $uploaded = $script:MigrationUploaded
            $skipped = $script:MigrationSkipped
            $failed = $script:MigrationFailed
        }

        Write-MigrationProgressIfNeeded -ProcessedCount $processedFileCount -TotalCount $totalFilesToProcess -Force

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
                    if (Test-PnPNotFoundError -ErrorRecord $_) {
                        $fileExists = $false
                    }
                    else {
                        throw
                    }
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
        $runResult = if ($failed -gt 0) { "PartialSuccess" } else { "Success" }
        Complete-MigrationRun -DatabasePath $ProjectInfo.DatabasePath -RunId $runId -Result $runResult -Message $summary
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
        Write-Log -Level "INFO" -Message "Fichiers bloques par la politique d'extensions : $($inventoryResult.BlockedFiles)"
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
                Write-Log -Level "WARN" -Message "[BLOQUE] Extension exclue par la politique de migration: $relativePath (.$fileExtension) - Taille: $fileSize"
                $blocked++
                $skipped++
                continue
            }

            if ($WhatIf) {
                Write-Log -Level "INFO" -Message "[WHATIF] $($file.FullName) -> $targetFolder/$($file.Name) - Taille: $fileSize"
                continue
            }

            $currentOperation = "Creation/verification du dossier SharePoint"
            Ensure-RemoteFolder `
                -ServerRelativeFolder $targetFolder `
                -ExistingRoot $Context.Destination.ServerRelativeRoot `
                -WhatIf:$WhatIf

            $existingFileUrl = "$targetFolder/$($file.Name)"
            $fileExists = $false

            try {
                $currentOperation = "Verification de l'existence du fichier SharePoint"
                Get-PnPFile -Url $existingFileUrl -ErrorAction Stop | Out-Null
                $fileExists = $true
            }
            catch {
                if (Test-PnPNotFoundError -ErrorRecord $_) {
                    $fileExists = $false
                }
                else {
                    throw
                }
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
    Write-Log -Level "INFO" -Message "Bloques par la politique d'extensions : $blocked"
    Write-Log -Level "INFO" -Message "Erreurs : $failed"

    if ($failed -gt 0) {
        exit 1
    }
}
