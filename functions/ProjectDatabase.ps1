function Ensure-PSSQLite {
    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        throw "Le module PSSQLite est introuvable. Installe-le avec: Install-Module PSSQLite -Scope CurrentUser"
    }

    Import-Module PSSQLite -ErrorAction Stop
}

function Get-ProjectRoot {
    param(
        [string]$RootDirectory
    )

    if ([string]::IsNullOrWhiteSpace($RootDirectory)) {
        $RootDirectory = Join-Path $PSScriptRoot "..\projects"
    }

    if (-not (Test-Path -LiteralPath $RootDirectory)) {
        New-Item -ItemType Directory -Path $RootDirectory -Force | Out-Null
    }

    return (Resolve-Path -LiteralPath $RootDirectory).Path
}

function Initialize-MigrationDatabase {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath
    )

    Ensure-PSSQLite

    $schema = @"
CREATE TABLE IF NOT EXISTS ProjectMetadata (
    Key TEXT PRIMARY KEY,
    Value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS Files (
    Id INTEGER PRIMARY KEY AUTOINCREMENT,
    FullPath TEXT NOT NULL UNIQUE,
    RelativePath TEXT NOT NULL,
    Extension TEXT,
    FileHash TEXT,
    PreviousFileHash TEXT,
    HashChanged INTEGER NOT NULL DEFAULT 0,
    LastHashChangedAt TEXT,
    SizeBytes INTEGER NOT NULL,
    LastWriteTimeUtc TEXT NOT NULL,
    TargetFolder TEXT NOT NULL,
    TargetUrl TEXT NOT NULL,
    Status TEXT NOT NULL,
    AttemptCount INTEGER NOT NULL DEFAULT 0,
    LastError TEXT,
    LastInventorySeenAt TEXT,
    CreatedAt TEXT NOT NULL,
    UpdatedAt TEXT NOT NULL,
    UploadedAt TEXT
);

CREATE INDEX IF NOT EXISTS IX_Files_Status ON Files(Status);
CREATE INDEX IF NOT EXISTS IX_Files_RelativePath ON Files(RelativePath);

CREATE TABLE IF NOT EXISTS Runs (
    Id INTEGER PRIMARY KEY AUTOINCREMENT,
    Mode TEXT NOT NULL,
    StartedAt TEXT NOT NULL,
    FinishedAt TEXT,
    Result TEXT,
    Message TEXT
);
"@

    Invoke-SqliteQuery -DataSource $DatabasePath -Query $schema | Out-Null
    Add-SqliteColumnIfMissing -DatabasePath $DatabasePath -TableName "Files" -ColumnName "FileHash" -ColumnDefinition "TEXT"
    Add-SqliteColumnIfMissing -DatabasePath $DatabasePath -TableName "Files" -ColumnName "PreviousFileHash" -ColumnDefinition "TEXT"
    Add-SqliteColumnIfMissing -DatabasePath $DatabasePath -TableName "Files" -ColumnName "HashChanged" -ColumnDefinition "INTEGER NOT NULL DEFAULT 0"
    Add-SqliteColumnIfMissing -DatabasePath $DatabasePath -TableName "Files" -ColumnName "LastHashChangedAt" -ColumnDefinition "TEXT"
    Add-SqliteColumnIfMissing -DatabasePath $DatabasePath -TableName "Files" -ColumnName "LastInventorySeenAt" -ColumnDefinition "TEXT"
}

function Add-SqliteColumnIfMissing {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$TableName,

        [Parameter(Mandatory)]
        [string]$ColumnName,

        [Parameter(Mandatory)]
        [string]$ColumnDefinition
    )

    $columns = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "PRAGMA table_info($TableName);" -As "PSObject")
    $exists = @($columns | Where-Object { $_.name -eq $ColumnName }).Count -gt 0

    if (-not $exists) {
        Invoke-SqliteQuery -DataSource $DatabasePath -Query "ALTER TABLE $TableName ADD COLUMN $ColumnName $ColumnDefinition;" | Out-Null
    }
}

function Set-ProjectMetadata {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "INSERT OR REPLACE INTO ProjectMetadata (Key, Value) VALUES (@Key, @Value);" `
        -SqlParameters @{ Key = $Key; Value = $Value } | Out-Null
}

function New-MigrationProject {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectName,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [string]$RootDirectory
    )

    Ensure-PSSQLite

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Fichier de configuration introuvable: $ConfigPath"
    }

    $projectRoot = Get-ProjectRoot -RootDirectory $RootDirectory
    $safeProjectName = $ProjectName -replace '[\\/:*?"<>|]', "_"
    $projectDirectory = Join-Path $projectRoot $safeProjectName

    if (Test-Path -LiteralPath $projectDirectory) {
        throw "Le projet existe deja: $projectDirectory"
    }

    New-Item -ItemType Directory -Path $projectDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $projectDirectory "logs") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $projectDirectory "reports") -Force | Out-Null

    $projectConfigPath = Join-Path $projectDirectory "config.xml"
    Copy-Item -LiteralPath $ConfigPath -Destination $projectConfigPath -Force

    $databasePath = Join-Path $projectDirectory "migration.db"
    Initialize-MigrationDatabase -DatabasePath $databasePath

    $now = (Get-Date).ToUniversalTime().ToString("o")
    Set-ProjectMetadata -DatabasePath $databasePath -Key "ProjectName" -Value $ProjectName
    Set-ProjectMetadata -DatabasePath $databasePath -Key "CreatedAtUtc" -Value $now
    Set-ProjectMetadata -DatabasePath $databasePath -Key "ConfigPath" -Value $projectConfigPath

    $projectInfo = [pscustomobject]@{
        Name           = $ProjectName
        Directory      = (Resolve-Path -LiteralPath $projectDirectory).Path
        ConfigPath     = (Resolve-Path -LiteralPath $projectConfigPath).Path
        DatabasePath   = (Resolve-Path -LiteralPath $databasePath).Path
        LogDirectory   = (Resolve-Path -LiteralPath (Join-Path $projectDirectory "logs")).Path
        ReportDirectory = (Resolve-Path -LiteralPath (Join-Path $projectDirectory "reports")).Path
        CreatedAtUtc   = $now
    }

    $projectJsonPath = Join-Path $projectDirectory "project.json"
    $projectInfo | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $projectJsonPath -Encoding UTF8

    return $projectInfo
}

function Get-MigrationProject {
    param(
        [Parameter(Mandatory)]
        [string]$Project,

        [string]$RootDirectory
    )

    $candidate = $Project
    if (-not (Test-Path -LiteralPath $candidate)) {
        $candidate = Join-Path (Get-ProjectRoot -RootDirectory $RootDirectory) $Project
    }

    if (-not (Test-Path -LiteralPath $candidate)) {
        $projectRoot = Get-ProjectRoot -RootDirectory $RootDirectory
        $knownProjects = @(Get-ChildItem -LiteralPath $projectRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        $knownProjectsText = if ($knownProjects.Count -gt 0) { $knownProjects -join ", " } else { "aucun projet existant" }

        throw "Projet introuvable: $Project. Cree-le avec: .\main.ps1 -NewProject -ProjectName `"$Project`" -ConfigPath .\config.xml. Projets disponibles: $knownProjectsText"
    }

    $projectDirectory = (Resolve-Path -LiteralPath $candidate).Path
    $projectJsonPath = Join-Path $projectDirectory "project.json"
    $databasePath = Join-Path $projectDirectory "migration.db"

    if (-not (Test-Path -LiteralPath $projectJsonPath)) {
        throw "Fichier projet introuvable: $projectJsonPath"
    }

    if (-not (Test-Path -LiteralPath $databasePath)) {
        throw "Base de donnees projet introuvable: $databasePath"
    }

    $projectInfo = Get-Content -Raw -LiteralPath $projectJsonPath | ConvertFrom-Json
    $projectInfo.DatabasePath = (Resolve-Path -LiteralPath $databasePath).Path
    $projectInfo.Directory = $projectDirectory
    $projectInfo.ConfigPath = (Resolve-Path -LiteralPath $projectInfo.ConfigPath).Path

    Initialize-MigrationDatabase -DatabasePath $projectInfo.DatabasePath
    return $projectInfo
}

function Start-MigrationRun {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$Mode
    )

    $now = (Get-Date).ToUniversalTime().ToString("o")
    Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "INSERT INTO Runs (Mode, StartedAt, Result) VALUES (@Mode, @StartedAt, 'Running');" `
        -SqlParameters @{ Mode = $Mode; StartedAt = $now } | Out-Null

    return Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT last_insert_rowid();" -As "SingleValue"
}

function Complete-MigrationRun {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [int]$RunId,

        [Parameter(Mandatory)]
        [string]$Result,

        [string]$Message
    )

    $now = (Get-Date).ToUniversalTime().ToString("o")
    Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "UPDATE Runs SET FinishedAt = @FinishedAt, Result = @Result, Message = @Message WHERE Id = @Id;" `
        -SqlParameters @{ FinishedAt = $now; Result = $Result; Message = "$Message"; Id = $RunId } | Out-Null
}

function Reset-IncompleteUploads {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath
    )

    $now = (Get-Date).ToUniversalTime().ToString("o")
    Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "UPDATE Files SET Status = 'Pending', LastError = 'Repris apres interruption pendant Uploading', UpdatedAt = @UpdatedAt WHERE Status = 'Uploading';" `
        -SqlParameters @{ UpdatedAt = $now } | Out-Null
}

function Reset-MigrationHashChanges {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath
    )

    $now = (Get-Date).ToUniversalTime().ToString("o")
    Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "UPDATE Files SET HashChanged = 0, LastHashChangedAt = NULL, UpdatedAt = @UpdatedAt;" `
        -SqlParameters @{ UpdatedAt = $now } | Out-Null
}

function Get-MigrationFileFingerprint {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,

        [string]$HashMode = "SHA256"
    )

    switch ($HashMode.ToUpperInvariant()) {
        "NONE" {
            return ""
        }
        "QUICK" {
            return "QUICK:$($File.Length):$($File.LastWriteTimeUtc.Ticks)"
        }
        "SHA256" {
            return "SHA256:$((Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash)"
        }
        default {
            throw "HashMode invalide: $HashMode. Valeurs autorisees: SHA256, Quick, None."
        }
    }
}

function Upsert-MigrationFile {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ServerRelativeRoot,

        [string[]]$BlockedExtensions,

        [Parameter(Mandatory)]
        [string]$InventorySeenAt,

        [string]$HashMode = "SHA256"
    )

    $relativePath = Convert-ToSharePointRelativePath -BasePath $SourceRoot -FilePath $File.FullName
    $relativeFolder = [System.IO.Path]::GetDirectoryName($relativePath)

    if ([string]::IsNullOrWhiteSpace($relativeFolder)) {
        $targetFolder = $ServerRelativeRoot
    }
    else {
        $targetFolder = "$ServerRelativeRoot/$($relativeFolder -replace "\\", "/")"
    }

    $extension = [System.IO.Path]::GetExtension($File.Name).Trim().TrimStart(".").ToLowerInvariant()
    $status = "Pending"
    $lastError = ""
    $fileHash = Get-MigrationFileFingerprint -File $File -HashMode $HashMode
    $previousFileHash = ""
    $hashChanged = 0
    $lastHashChangedAt = $null
    $hashComparisonEnabled = $HashMode.ToUpperInvariant() -ne "NONE"

    if (-not [string]::IsNullOrWhiteSpace($extension) -and $BlockedExtensions -contains $extension) {
        $status = "BlockedExtension"
        $lastError = "Extension bloquee par le tenant: .$extension"
    }

    $existingRows = @(Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "SELECT Status, FileHash, PreviousFileHash, HashChanged, LastHashChangedAt, LastError FROM Files WHERE FullPath = @FullPath LIMIT 1;" `
        -SqlParameters @{ FullPath = $File.FullName } `
        -As "PSObject")

    if ($existingRows.Count -gt 0) {
        $existingFile = $existingRows[0]
        $existingStatus = "$($existingFile.Status)"
        $existingHash = "$($existingFile.FileHash)"
        $previousFileHash = $existingHash

        if ($status -ne "BlockedExtension" -and -not $hashComparisonEnabled) {
            $status = $existingStatus
            $lastError = "$($existingFile.LastError)"
            $hashChanged = [int]$existingFile.HashChanged
            $lastHashChangedAt = $existingFile.LastHashChangedAt
        }
        elseif ($status -ne "BlockedExtension" -and $existingStatus -in @("Uploaded", "SkippedExists") -and [string]::IsNullOrWhiteSpace($existingHash)) {
            $status = $existingStatus
            $lastError = "$($existingFile.LastError)"
        }
        elseif ($status -ne "BlockedExtension" -and $existingStatus -in @("Uploaded", "SkippedExists") -and $existingHash -eq $fileHash) {
            $status = $existingStatus
            $lastError = "$($existingFile.LastError)"
        }
        elseif ($status -ne "BlockedExtension" -and $existingStatus -in @("Uploaded", "SkippedExists") -and $existingHash -ne $fileHash) {
            $status = "Pending"
            $lastError = ""
        }

        if ($hashComparisonEnabled -and -not [string]::IsNullOrWhiteSpace($existingHash) -and $existingHash -ne $fileHash) {
            $hashChanged = 1
            $lastHashChangedAt = (Get-Date).ToUniversalTime().ToString("o")
        }
        elseif ($hashComparisonEnabled) {
            $hashChanged = [int]$existingFile.HashChanged
            $lastHashChangedAt = $existingFile.LastHashChangedAt
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $targetUrl = "$targetFolder/$($File.Name)"

    Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query @"
INSERT INTO Files (
    FullPath, RelativePath, Extension, FileHash, PreviousFileHash, HashChanged, LastHashChangedAt, SizeBytes, LastWriteTimeUtc,
    TargetFolder, TargetUrl, Status, AttemptCount, LastError, LastInventorySeenAt,
    CreatedAt, UpdatedAt, UploadedAt
)
VALUES (
    @FullPath, @RelativePath, @Extension, @FileHash, @PreviousFileHash, @HashChanged, @LastHashChangedAt, @SizeBytes, @LastWriteTimeUtc,
    @TargetFolder, @TargetUrl, @Status, 0, @LastError, @LastInventorySeenAt,
    @CreatedAt, @UpdatedAt, NULL
)
ON CONFLICT(FullPath) DO UPDATE SET
    RelativePath = excluded.RelativePath,
    Extension = excluded.Extension,
    FileHash = excluded.FileHash,
    PreviousFileHash = excluded.PreviousFileHash,
    HashChanged = excluded.HashChanged,
    LastHashChangedAt = excluded.LastHashChangedAt,
    SizeBytes = excluded.SizeBytes,
    LastWriteTimeUtc = excluded.LastWriteTimeUtc,
    TargetFolder = excluded.TargetFolder,
    TargetUrl = excluded.TargetUrl,
    Status = excluded.Status,
    LastError = excluded.LastError,
    LastInventorySeenAt = excluded.LastInventorySeenAt,
    UpdatedAt = excluded.UpdatedAt;
"@ `
        -SqlParameters @{
            FullPath         = $File.FullName
            RelativePath     = $relativePath
            Extension        = $extension
            FileHash         = $fileHash
            PreviousFileHash = $previousFileHash
            HashChanged      = $hashChanged
            LastHashChangedAt = $lastHashChangedAt
            SizeBytes        = $File.Length
            LastWriteTimeUtc = $File.LastWriteTimeUtc.ToString("o")
            TargetFolder     = $targetFolder
            TargetUrl        = $targetUrl
            Status           = $status
            LastError        = $lastError
            LastInventorySeenAt = $InventorySeenAt
            CreatedAt        = $now
            UpdatedAt        = $now
        } | Out-Null
}

function Update-MissingInventoryFiles {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$InventorySeenAt
    )

    $candidates = @(Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "SELECT Id, FullPath, RelativePath FROM Files WHERE Status <> 'DeletedRemote' AND (LastInventorySeenAt IS NULL OR LastInventorySeenAt <> @InventorySeenAt);" `
        -SqlParameters @{ InventorySeenAt = $InventorySeenAt } `
        -As "PSObject")
    $missingCount = 0

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate.FullPath)) {
            Update-MigrationFileStatus `
                -DatabasePath $DatabasePath `
                -Id $candidate.Id `
                -Status "MissingLocalFile" `
                -LastError "Fichier local absent lors du dernier inventaire"
            $missingCount++
        }
    }

    return $missingCount
}

function Reset-FailedMigrationFiles {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath
    )

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $count = Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "SELECT COUNT(*) FROM Files WHERE Status = 'Failed';" `
        -As "SingleValue"

    Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "UPDATE Files SET Status = 'Pending', AttemptCount = 0, LastError = '', UpdatedAt = @UpdatedAt WHERE Status = 'Failed';" `
        -SqlParameters @{ UpdatedAt = $now } | Out-Null

    return [int]$count
}

function Export-CsvWithHeaders {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [string[]]$Columns,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Rows.Count -gt 0) {
        $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
        return
    }

    $header = ($Columns | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ","
    Set-Content -LiteralPath $Path -Value $header -Encoding UTF8
}

function Get-MigrationFileReportColumns {
    return @(
        "Id",
        "FullPath",
        "RelativePath",
        "Extension",
        "FileHash",
        "PreviousFileHash",
        "HashChanged",
        "LastHashChangedAt",
        "SizeBytes",
        "LastWriteTimeUtc",
        "TargetFolder",
        "TargetUrl",
        "Status",
        "AttemptCount",
        "LastError",
        "LastInventorySeenAt",
        "CreatedAt",
        "UpdatedAt",
        "UploadedAt"
    )
}

function Get-MigrationFileByFullPath {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$FullPath
    )

    $rows = @(Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "SELECT * FROM Files WHERE FullPath = @FullPath LIMIT 1;" `
        -SqlParameters @{ FullPath = $FullPath } `
        -As "PSObject")

    if ($rows.Count -eq 0) {
        return $null
    }

    return $rows[0]
}

function Update-MigrationFileInventorySeen {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [int]$Id,

        [Parameter(Mandatory)]
        [string]$InventorySeenAt
    )

    $now = (Get-Date).ToUniversalTime().ToString("o")
    Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "UPDATE Files SET LastInventorySeenAt = @LastInventorySeenAt, UpdatedAt = @UpdatedAt WHERE Id = @Id;" `
        -SqlParameters @{ LastInventorySeenAt = $InventorySeenAt; UpdatedAt = $now; Id = $Id } | Out-Null
}

function Get-MigrationFilesToProcess {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [switch]$IncludeFailed,

        [int]$MaxAttemptsPerFile = 3
    )

    $statusFilter = if ($IncludeFailed) { "('Pending', 'Failed', 'Uploading')" } else { "('Pending', 'Uploading')" }

    if ($MaxAttemptsPerFile -le 0) {
        return @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT * FROM Files WHERE Status IN $statusFilter ORDER BY Id;" -As "PSObject")
    }

    if ($IncludeFailed) {
        return @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT * FROM Files WHERE Status IN ('Pending', 'Failed', 'Uploading') AND AttemptCount < @MaxAttemptsPerFile ORDER BY Id;" -SqlParameters @{ MaxAttemptsPerFile = $MaxAttemptsPerFile } -As "PSObject")
    }

    return @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT * FROM Files WHERE Status IN ('Pending', 'Uploading') AND AttemptCount < @MaxAttemptsPerFile ORDER BY Id;" -SqlParameters @{ MaxAttemptsPerFile = $MaxAttemptsPerFile } -As "PSObject")
}

function Get-MigrationRemoteDeleteCandidates {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [int]$MaxAttemptsPerFile = 3
    )

    if ($MaxAttemptsPerFile -le 0) {
        return @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT * FROM Files WHERE Status = 'MissingLocalFile' ORDER BY Id;" -As "PSObject")
    }

    return @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT * FROM Files WHERE Status = 'MissingLocalFile' AND AttemptCount < @MaxAttemptsPerFile ORDER BY Id;" -SqlParameters @{ MaxAttemptsPerFile = $MaxAttemptsPerFile } -As "PSObject")
}

function Update-MigrationFileStatus {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [int]$Id,

        [Parameter(Mandatory)]
        [string]$Status,

        [string]$LastError,

        [switch]$IncrementAttempt,

        [switch]$SetUploadedAt
    )

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $uploadedAt = if ($SetUploadedAt) { $now } else { $null }

    Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query @"
UPDATE Files
SET Status = @Status,
    LastError = @LastError,
    UpdatedAt = @UpdatedAt,
    UploadedAt = CASE WHEN @UploadedAt IS NULL THEN UploadedAt ELSE @UploadedAt END,
    AttemptCount = AttemptCount + @AttemptIncrement
WHERE Id = @Id;
"@ `
        -SqlParameters @{
            Status           = $Status
            LastError        = "$LastError"
            UpdatedAt        = $now
            UploadedAt       = $uploadedAt
            AttemptIncrement = if ($IncrementAttempt) { 1 } else { 0 }
            Id               = $Id
        } | Out-Null
}

function Get-MigrationStatus {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath
    )

    return @(Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "SELECT Status, COUNT(*) AS Count FROM Files GROUP BY Status ORDER BY Status;" `
        -As "PSObject")
}

function Export-MigrationReport {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$ReportDirectory
    )

    if (-not (Test-Path -LiteralPath $ReportDirectory)) {
        New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $reportPath = Join-Path $ReportDirectory ("migration_report_{0}.csv" -f $timestamp)
    $summaryPath = Join-Path $ReportDirectory ("migration_summary_{0}.csv" -f $timestamp)
    $errorReportPath = Join-Path $ReportDirectory ("migration_errors_{0}.csv" -f $timestamp)
    $changesReportPath = Join-Path $ReportDirectory ("migration_changes_{0}.csv" -f $timestamp)
    $rows = @(Invoke-SqliteQuery -DataSource $DatabasePath -Query "SELECT * FROM Files ORDER BY Id;" -As "PSObject")
    $summaryRows = @(Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "SELECT Status, COUNT(*) AS Count, COALESCE(SUM(SizeBytes), 0) AS TotalBytes FROM Files GROUP BY Status ORDER BY Status;" `
        -As "PSObject")
    $errorRows = @(Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "SELECT * FROM Files WHERE Status IN ('Failed', 'MissingLocalFile') ORDER BY Status, RelativePath;" `
        -As "PSObject")
    $changedRows = @(Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "SELECT * FROM Files WHERE HashChanged = 1 ORDER BY LastHashChangedAt DESC, RelativePath;" `
        -As "PSObject")

    $fileColumns = Get-MigrationFileReportColumns
    Export-CsvWithHeaders -Rows $rows -Columns $fileColumns -Path $reportPath
    Export-CsvWithHeaders -Rows $summaryRows -Columns @("Status", "Count", "TotalBytes") -Path $summaryPath
    Export-CsvWithHeaders -Rows $errorRows -Columns $fileColumns -Path $errorReportPath
    Export-CsvWithHeaders -Rows $changedRows -Columns $fileColumns -Path $changesReportPath

    return [pscustomobject]@{
        DetailPath  = (Resolve-Path -LiteralPath $reportPath).Path
        SummaryPath = (Resolve-Path -LiteralPath $summaryPath).Path
        ErrorPath   = (Resolve-Path -LiteralPath $errorReportPath).Path
        ChangesPath = (Resolve-Path -LiteralPath $changesReportPath).Path
    }
}

function Export-MigrationErrorReport {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$ReportDirectory
    )

    if (-not (Test-Path -LiteralPath $ReportDirectory)) {
        New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
    }

    $errorReportPath = Join-Path $ReportDirectory ("migration_errors_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $rows = @(Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "SELECT * FROM Files WHERE Status IN ('Failed', 'MissingLocalFile') ORDER BY Status, RelativePath;" `
        -As "PSObject")

    Export-CsvWithHeaders -Rows $rows -Columns (Get-MigrationFileReportColumns) -Path $errorReportPath

    return (Resolve-Path -LiteralPath $errorReportPath).Path
}

function Remove-OldMigrationReports {
    param(
        [Parameter(Mandatory)]
        [string]$ReportDirectory,

        [int]$RetentionDays = 30
    )

    if (-not (Test-Path -LiteralPath $ReportDirectory)) {
        return @()
    }

    if ($RetentionDays -lt 0) {
        throw "ReportRetentionDays doit etre superieur ou egal a 0."
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $reports = @(Get-ChildItem -LiteralPath $ReportDirectory -File -Filter "migration_*.csv" |
        Where-Object { $_.LastWriteTime -lt $cutoff })
    $removed = @()

    foreach ($report in $reports) {
        $removed += $report.FullName
        Remove-Item -LiteralPath $report.FullName -Force
    }

    return $removed
}
