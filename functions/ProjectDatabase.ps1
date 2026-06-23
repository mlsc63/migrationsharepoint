function Ensure-PSSQLite {
    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        throw "Le module PSSQLite est introuvable. Installe-le avec: Install-Module PSSQLite -Scope CurrentUser"
    }

    Import-Module PSSQLite -ErrorAction Stop
}

function Invoke-MigrationDatabaseTransaction {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $connection = New-SQLiteConnection -DataSource $DatabasePath -Open $true

    try {
        Invoke-SqliteQuery -SQLiteConnection $connection -Query "PRAGMA busy_timeout=30000; BEGIN IMMEDIATE;" | Out-Null

        try {
            & $Action $connection
            Invoke-SqliteQuery -SQLiteConnection $connection -Query "COMMIT;" | Out-Null
        }
        catch {
            try {
                Invoke-SqliteQuery -SQLiteConnection $connection -Query "ROLLBACK;" | Out-Null
            }
            catch {
                # Preserve the original transaction error.
            }

            throw
        }
    }
    finally {
        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }
}

function Enter-MigrationProjectLock {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath
    )

    $projectDirectory = Split-Path -Parent $DatabasePath
    $lockPath = Join-Path $projectDirectory "migration.lock"

    $lockSet = Get-Variable -Name MigrationSharePointProjectLocks -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $lockSet -or $null -eq $lockSet.Value) {
        $global:MigrationSharePointProjectLocks = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
    }

    if ($global:MigrationSharePointProjectLocks.Contains($lockPath)) {
        throw "Le projet est deja utilise par cette execution: $projectDirectory"
    }

    $lockStream = $null
    try {
        $lockStream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)

        $metadata = "PID=$PID; StartedAtUtc=$((Get-Date).ToUniversalTime().ToString('o'))"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($metadata)
        $lockStream.SetLength(0)
        $lockStream.Write($bytes, 0, $bytes.Length)
        $lockStream.Flush()

        [void]$global:MigrationSharePointProjectLocks.Add($lockPath)

        return ,$lockStream
    }
    catch [System.IO.IOException] {
        if ($null -ne $lockStream) {
            $lockStream.Dispose()
        }

        throw "Le projet est deja utilise par une autre execution: $projectDirectory"
    }
}

function Exit-MigrationProjectLock {
    param(
        [System.IO.FileStream]$LockStream
    )

    if ($null -ne $LockStream) {
        $lockPath = $LockStream.Name
        $LockStream.Dispose()

        if ($null -ne $global:MigrationSharePointProjectLocks) {
            [void]$global:MigrationSharePointProjectLocks.Remove($lockPath)
        }
    }
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
    StatusBeforeExclusion TEXT,
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
    Invoke-SqliteQuery -DataSource $DatabasePath -Query "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=30000;" | Out-Null
    Add-SqliteColumnIfMissing -DatabasePath $DatabasePath -TableName "Files" -ColumnName "FileHash" -ColumnDefinition "TEXT"
    Add-SqliteColumnIfMissing -DatabasePath $DatabasePath -TableName "Files" -ColumnName "PreviousFileHash" -ColumnDefinition "TEXT"
    Add-SqliteColumnIfMissing -DatabasePath $DatabasePath -TableName "Files" -ColumnName "HashChanged" -ColumnDefinition "INTEGER NOT NULL DEFAULT 0"
    Add-SqliteColumnIfMissing -DatabasePath $DatabasePath -TableName "Files" -ColumnName "LastHashChangedAt" -ColumnDefinition "TEXT"
    Add-SqliteColumnIfMissing -DatabasePath $DatabasePath -TableName "Files" -ColumnName "LastInventorySeenAt" -ColumnDefinition "TEXT"
    Add-SqliteColumnIfMissing -DatabasePath $DatabasePath -TableName "Files" -ColumnName "StatusBeforeExclusion" -ColumnDefinition "TEXT"
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
    $projectInfo.ConfigPath = (Resolve-Path -LiteralPath (Join-Path $projectDirectory "config.xml")).Path
    $projectInfo.LogDirectory = Join-Path $projectDirectory "logs"
    $projectInfo.ReportDirectory = Join-Path $projectDirectory "reports"

    foreach ($directory in @($projectInfo.LogDirectory, $projectInfo.ReportDirectory)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }

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
    return Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query @"
UPDATE Runs
SET FinishedAt = @StartedAt,
    Result = 'Interrupted',
    Message = 'Execution precedente interrompue avant sa cloture'
WHERE Result = 'Running';

INSERT INTO Runs (Mode, StartedAt, Result)
VALUES (@Mode, @StartedAt, 'Running');

SELECT last_insert_rowid();
"@ `
        -SqlParameters @{ Mode = $Mode; StartedAt = $now } `
        -As "SingleValue"
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
        -Query "UPDATE Files SET LastError = 'Upload precedent interrompu: verification distante obligatoire avant reprise', UpdatedAt = @UpdatedAt WHERE Status = 'Uploading';" `
        -SqlParameters @{ UpdatedAt = $now } | Out-Null
}

function Reset-MigrationHashChanges {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [object]$SQLiteConnection
    )

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $queryParameters = @{
        Query         = "UPDATE Files SET HashChanged = 0, LastHashChangedAt = NULL, UpdatedAt = @UpdatedAt WHERE HashChanged <> 0 OR LastHashChangedAt IS NOT NULL;"
        SqlParameters = @{ UpdatedAt = $now }
    }
    if ($null -ne $SQLiteConnection) {
        $queryParameters.SQLiteConnection = $SQLiteConnection
    }
    else {
        $queryParameters.DataSource = $DatabasePath
    }

    Invoke-SqliteQuery @queryParameters | Out-Null
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

function New-MigrationPreparedCommand {
    param(
        [Parameter(Mandatory)]
        [object]$SQLiteConnection,

        [Parameter(Mandatory)]
        [string]$CommandText,

        [string[]]$ParameterNames = @()
    )

    $command = $SQLiteConnection.CreateCommand()
    $command.CommandText = $CommandText

    foreach ($parameterName in $ParameterNames) {
        $parameter = $command.CreateParameter()
        $parameter.ParameterName = if ($parameterName.StartsWith("@")) { $parameterName } else { "@$parameterName" }
        $null = $command.Parameters.Add($parameter)
    }

    $command.Prepare()
    return $command
}

function Set-MigrationCommandParameter {
    param(
        [Parameter(Mandatory)]
        [object]$Command,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    $parameterName = if ($Name.StartsWith("@")) { $Name } else { "@$Name" }
    $Command.Parameters[$parameterName].Value = if ($null -eq $Value) { [DBNull]::Value } else { $Value }
}

function Get-MigrationDataReaderValue {
    param(
        [Parameter(Mandatory)]
        [object]$Reader,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $ordinal = $Reader.GetOrdinal($Name)
    if ($Reader.IsDBNull($ordinal)) {
        return $null
    }

    return $Reader.GetValue($ordinal)
}

function New-MigrationFileWriter {
    param(
        [Parameter(Mandatory)]
        [object]$SQLiteConnection
    )

    $fileParameterNames = @(
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

    $excludedParameterNames = @(
        "FullPath",
        "RelativePath",
        "Extension",
        "SizeBytes",
        "LastWriteTimeUtc",
        "TargetFolder",
        "TargetUrl",
        "LastInventorySeenAt",
        "CreatedAt",
        "UpdatedAt"
    )

    return [pscustomobject]@{
        SelectCommand = New-MigrationPreparedCommand `
            -SQLiteConnection $SQLiteConnection `
            -CommandText "SELECT Status, StatusBeforeExclusion, FileHash, PreviousFileHash, HashChanged, LastHashChangedAt, LastError, AttemptCount, UploadedAt FROM Files WHERE FullPath = @FullPath LIMIT 1;" `
            -ParameterNames @("FullPath")
        UpsertCommand = New-MigrationPreparedCommand `
            -SQLiteConnection $SQLiteConnection `
            -CommandText @"
INSERT INTO Files (
    FullPath, RelativePath, Extension, FileHash, PreviousFileHash, HashChanged, LastHashChangedAt, SizeBytes, LastWriteTimeUtc,
    TargetFolder, TargetUrl, Status, StatusBeforeExclusion, AttemptCount, LastError, LastInventorySeenAt,
    CreatedAt, UpdatedAt, UploadedAt
)
VALUES (
    @FullPath, @RelativePath, @Extension, @FileHash, @PreviousFileHash, @HashChanged, @LastHashChangedAt, @SizeBytes, @LastWriteTimeUtc,
    @TargetFolder, @TargetUrl, @Status, NULL, @AttemptCount, @LastError, @LastInventorySeenAt,
    @CreatedAt, @UpdatedAt, @UploadedAt
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
    StatusBeforeExclusion = NULL,
    AttemptCount = excluded.AttemptCount,
    LastError = excluded.LastError,
    LastInventorySeenAt = excluded.LastInventorySeenAt,
    UpdatedAt = excluded.UpdatedAt,
    UploadedAt = excluded.UploadedAt;
"@ `
            -ParameterNames $fileParameterNames
        ExcludedCommand = New-MigrationPreparedCommand `
            -SQLiteConnection $SQLiteConnection `
            -CommandText @"
INSERT INTO Files (
    FullPath, RelativePath, Extension, FileHash, PreviousFileHash, HashChanged, SizeBytes, LastWriteTimeUtc,
    TargetFolder, TargetUrl, Status, StatusBeforeExclusion, AttemptCount, LastError, LastInventorySeenAt,
    CreatedAt, UpdatedAt, UploadedAt
)
VALUES (
    @FullPath, @RelativePath, @Extension, '', '', 0, @SizeBytes, @LastWriteTimeUtc,
    @TargetFolder, @TargetUrl, 'Excluded', NULL, 0, 'Exclu par la configuration', @LastInventorySeenAt,
    @CreatedAt, @UpdatedAt, NULL
)
ON CONFLICT(FullPath) DO UPDATE SET
    RelativePath = excluded.RelativePath,
    Extension = excluded.Extension,
    SizeBytes = excluded.SizeBytes,
    LastWriteTimeUtc = excluded.LastWriteTimeUtc,
    TargetFolder = excluded.TargetFolder,
    TargetUrl = excluded.TargetUrl,
    StatusBeforeExclusion = CASE WHEN Files.Status = 'Excluded' THEN Files.StatusBeforeExclusion ELSE Files.Status END,
    Status = 'Excluded',
    LastError = 'Exclu par la configuration',
    LastInventorySeenAt = excluded.LastInventorySeenAt,
    UpdatedAt = excluded.UpdatedAt;
"@ `
            -ParameterNames $excludedParameterNames
    }
}

function Close-MigrationFileWriter {
    param(
        [AllowNull()]
        [object]$Writer
    )

    if ($null -eq $Writer) {
        return
    }

    foreach ($commandName in @("SelectCommand", "UpsertCommand", "ExcludedCommand")) {
        $command = $Writer.$commandName
        if ($null -ne $command) {
            $command.Dispose()
        }
    }
}

function Get-MigrationFileWriterExistingRow {
    param(
        [Parameter(Mandatory)]
        [object]$Writer,

        [Parameter(Mandatory)]
        [string]$FullPath
    )

    Set-MigrationCommandParameter -Command $Writer.SelectCommand -Name "FullPath" -Value $FullPath
    $reader = $Writer.SelectCommand.ExecuteReader()

    try {
        if (-not $reader.Read()) {
            return $null
        }

        return [pscustomobject]@{
            Status                = Get-MigrationDataReaderValue -Reader $reader -Name "Status"
            StatusBeforeExclusion = Get-MigrationDataReaderValue -Reader $reader -Name "StatusBeforeExclusion"
            FileHash              = Get-MigrationDataReaderValue -Reader $reader -Name "FileHash"
            PreviousFileHash      = Get-MigrationDataReaderValue -Reader $reader -Name "PreviousFileHash"
            HashChanged           = Get-MigrationDataReaderValue -Reader $reader -Name "HashChanged"
            LastHashChangedAt     = Get-MigrationDataReaderValue -Reader $reader -Name "LastHashChangedAt"
            LastError             = Get-MigrationDataReaderValue -Reader $reader -Name "LastError"
            AttemptCount          = Get-MigrationDataReaderValue -Reader $reader -Name "AttemptCount"
            UploadedAt            = Get-MigrationDataReaderValue -Reader $reader -Name "UploadedAt"
        }
    }
    finally {
        $reader.Dispose()
    }
}

function Invoke-MigrationFileWriterUpsert {
    param(
        [Parameter(Mandatory)]
        [object]$Writer,

        [Parameter(Mandatory)]
        [hashtable]$Values
    )

    foreach ($key in $Values.Keys) {
        Set-MigrationCommandParameter -Command $Writer.UpsertCommand -Name $key -Value $Values[$key]
    }

    $null = $Writer.UpsertCommand.ExecuteNonQuery()
}

function Invoke-MigrationFileWriterExcluded {
    param(
        [Parameter(Mandatory)]
        [object]$Writer,

        [Parameter(Mandatory)]
        [hashtable]$Values
    )

    foreach ($key in $Values.Keys) {
        Set-MigrationCommandParameter -Command $Writer.ExcludedCommand -Name $key -Value $Values[$key]
    }

    $null = $Writer.ExcludedCommand.ExecuteNonQuery()
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

        [string]$HashMode = "SHA256",

        [AllowEmptyString()]
        [string]$FileHash = "",

        [switch]$FingerprintProvided,

        [object]$SQLiteConnection,

        [object]$Writer
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
    if (-not $FingerprintProvided) {
        $FileHash = Get-MigrationFileFingerprint -File $File -HashMode $HashMode
    }

    $status = "Pending"
    $lastError = ""
    $attemptCount = 0
    $uploadedAt = $null
    $statusBeforeExclusion = $null
    $previousFileHash = ""
    $hashChanged = 0
    $lastHashChangedAt = $null
    $hashComparisonEnabled = $HashMode.ToUpperInvariant() -ne "NONE"
    $isBlocked = -not [string]::IsNullOrWhiteSpace($extension) -and $BlockedExtensions -contains $extension
    $isNew = $true
    $contentChanged = $false
    $statusChanged = $false

    if ($isBlocked) {
        $status = "BlockedExtension"
        $lastError = "Extension exclue par la politique de migration: .$extension"
    }

    if ($null -ne $Writer) {
        $existingFile = Get-MigrationFileWriterExistingRow -Writer $Writer -FullPath $File.FullName
        $existingRows = if ($null -ne $existingFile) { @($existingFile) } else { @() }
    }
    else {
        $selectParameters = @{
            Query         = "SELECT Status, StatusBeforeExclusion, FileHash, PreviousFileHash, HashChanged, LastHashChangedAt, LastError, AttemptCount, UploadedAt FROM Files WHERE FullPath = @FullPath LIMIT 1;"
            SqlParameters = @{ FullPath = $File.FullName }
            As            = "PSObject"
        }
        if ($null -ne $SQLiteConnection) {
            $selectParameters.SQLiteConnection = $SQLiteConnection
        }
        else {
            $selectParameters.DataSource = $DatabasePath
        }

        $existingRows = @(Invoke-SqliteQuery @selectParameters)
    }

    if ($existingRows.Count -gt 0) {
        $isNew = $false
        $existingFile = $existingRows[0]
        $existingStatus = "$($existingFile.Status)"
        $restoredStatus = if ($existingStatus -eq "Excluded") {
            if (-not [string]::IsNullOrWhiteSpace("$($existingFile.StatusBeforeExclusion)")) {
                "$($existingFile.StatusBeforeExclusion)"
            }
            else {
                "Pending"
            }
        }
        else {
            $existingStatus
        }
        $existingHash = "$($existingFile.FileHash)"
        if (-not $hashComparisonEnabled) {
            $FileHash = $existingHash
        }
        $previousFileHash = $existingHash
        $attemptCount = [int]$existingFile.AttemptCount
        $uploadedAt = $existingFile.UploadedAt
        $contentChanged = $hashComparisonEnabled -and -not [string]::IsNullOrWhiteSpace($existingHash) -and $existingHash -ne $FileHash

        if ($isBlocked) {
            $status = "BlockedExtension"
            $lastError = "Extension exclue par la politique de migration: .$extension"
            $attemptCount = 0
        }
        elseif ($contentChanged) {
            $status = "Pending"
            $lastError = ""
            $attemptCount = 0
            $uploadedAt = $null
        }
        elseif ($restoredStatus -eq "DeletedRemote") {
            $status = "Pending"
            $lastError = ""
            $attemptCount = 0
            $uploadedAt = $null
        }
        elseif ($restoredStatus -in @("MissingLocalFile", "BlockedExtension")) {
            $status = if ($null -ne $uploadedAt) { "Uploaded" } else { "Pending" }
            $lastError = ""
            $attemptCount = 0
        }
        else {
            $status = $restoredStatus
            $lastError = "$($existingFile.LastError)"
        }

        if ($contentChanged) {
            $hashChanged = 1
            $lastHashChangedAt = (Get-Date).ToUniversalTime().ToString("o")
        }

        $statusChanged = $existingStatus -ne $status
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $targetUrl = "$targetFolder/$($File.Name)"

    $upsertValues = @{
        FullPath           = $File.FullName
        RelativePath       = $relativePath
        Extension          = $extension
        FileHash           = $FileHash
        PreviousFileHash   = $previousFileHash
        HashChanged        = $hashChanged
        LastHashChangedAt  = $lastHashChangedAt
        SizeBytes          = $File.Length
        LastWriteTimeUtc   = $File.LastWriteTimeUtc.ToString("o")
        TargetFolder       = $targetFolder
        TargetUrl          = $targetUrl
        Status             = $status
        AttemptCount       = $attemptCount
        LastError          = $lastError
        LastInventorySeenAt = $InventorySeenAt
        CreatedAt          = $now
        UpdatedAt          = $now
        UploadedAt         = $uploadedAt
    }

    if ($null -ne $Writer) {
        Invoke-MigrationFileWriterUpsert -Writer $Writer -Values $upsertValues
    }
    else {
        $upsertParameters = @{
            Query = @"
INSERT INTO Files (
    FullPath, RelativePath, Extension, FileHash, PreviousFileHash, HashChanged, LastHashChangedAt, SizeBytes, LastWriteTimeUtc,
    TargetFolder, TargetUrl, Status, StatusBeforeExclusion, AttemptCount, LastError, LastInventorySeenAt,
    CreatedAt, UpdatedAt, UploadedAt
)
VALUES (
    @FullPath, @RelativePath, @Extension, @FileHash, @PreviousFileHash, @HashChanged, @LastHashChangedAt, @SizeBytes, @LastWriteTimeUtc,
    @TargetFolder, @TargetUrl, @Status, NULL, @AttemptCount, @LastError, @LastInventorySeenAt,
    @CreatedAt, @UpdatedAt, @UploadedAt
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
    StatusBeforeExclusion = NULL,
    AttemptCount = excluded.AttemptCount,
    LastError = excluded.LastError,
    LastInventorySeenAt = excluded.LastInventorySeenAt,
    UpdatedAt = excluded.UpdatedAt,
    UploadedAt = excluded.UploadedAt;
"@
            SqlParameters = $upsertValues
        }
        if ($null -ne $SQLiteConnection) {
            $upsertParameters.SQLiteConnection = $SQLiteConnection
        }
        else {
            $upsertParameters.DataSource = $DatabasePath
        }

        Invoke-SqliteQuery @upsertParameters | Out-Null
    }

    return [pscustomobject]@{
        IsNew          = $isNew
        ContentChanged = $contentChanged
        StatusChanged  = $statusChanged
        Status         = $status
    }
}

function Update-MissingInventoryFiles {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$InventorySeenAt,

        [object]$SQLiteConnection
    )

    $queryParameters = @{
        Query = @"
SELECT COUNT(*) AS MissingCount
FROM Files
WHERE Status NOT IN ('DeletedRemote', 'Excluded')
  AND (LastInventorySeenAt IS NULL OR LastInventorySeenAt <> @InventorySeenAt);

UPDATE Files
SET Status = 'MissingLocalFile',
    LastError = 'Fichier local absent lors du dernier inventaire',
    UpdatedAt = @UpdatedAt
WHERE Status NOT IN ('DeletedRemote', 'Excluded')
  AND (LastInventorySeenAt IS NULL OR LastInventorySeenAt <> @InventorySeenAt);
"@
        SqlParameters = @{
            InventorySeenAt = $InventorySeenAt
            UpdatedAt       = (Get-Date).ToUniversalTime().ToString("o")
        }
        As = "PSObject"
    }
    if ($null -ne $SQLiteConnection) {
        $queryParameters.SQLiteConnection = $SQLiteConnection
    }
    else {
        $queryParameters.DataSource = $DatabasePath
    }

    $result = @(Invoke-SqliteQuery @queryParameters)
    return [int]$result[0].MissingCount
}

function Set-MigrationFileExcluded {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ServerRelativeRoot,

        [Parameter(Mandatory)]
        [string]$InventorySeenAt,

        [object]$SQLiteConnection,

        [object]$Writer
    )

    $relativePath = Convert-ToSharePointRelativePath -BasePath $SourceRoot -FilePath $File.FullName
    $relativeFolder = [System.IO.Path]::GetDirectoryName($relativePath)
    $targetFolder = if ([string]::IsNullOrWhiteSpace($relativeFolder)) {
        $ServerRelativeRoot
    }
    else {
        "$ServerRelativeRoot/$($relativeFolder -replace '\\', '/')"
    }
    $extension = [System.IO.Path]::GetExtension($File.Name).Trim().TrimStart(".").ToLowerInvariant()
    $now = (Get-Date).ToUniversalTime().ToString("o")
    $excludedValues = @{
        FullPath           = $File.FullName
        RelativePath       = $relativePath
        Extension          = $extension
        SizeBytes          = $File.Length
        LastWriteTimeUtc   = $File.LastWriteTimeUtc.ToString("o")
        TargetFolder       = $targetFolder
        TargetUrl          = "$targetFolder/$($File.Name)"
        LastInventorySeenAt = $InventorySeenAt
        CreatedAt          = $now
        UpdatedAt          = $now
    }

    if ($null -ne $Writer) {
        Invoke-MigrationFileWriterExcluded -Writer $Writer -Values $excludedValues
    }
    else {
        $queryParameters = @{
            Query = @"
INSERT INTO Files (
    FullPath, RelativePath, Extension, FileHash, PreviousFileHash, HashChanged, SizeBytes, LastWriteTimeUtc,
    TargetFolder, TargetUrl, Status, StatusBeforeExclusion, AttemptCount, LastError, LastInventorySeenAt,
    CreatedAt, UpdatedAt, UploadedAt
)
VALUES (
    @FullPath, @RelativePath, @Extension, '', '', 0, @SizeBytes, @LastWriteTimeUtc,
    @TargetFolder, @TargetUrl, 'Excluded', NULL, 0, 'Exclu par la configuration', @LastInventorySeenAt,
    @CreatedAt, @UpdatedAt, NULL
)
ON CONFLICT(FullPath) DO UPDATE SET
    RelativePath = excluded.RelativePath,
    Extension = excluded.Extension,
    SizeBytes = excluded.SizeBytes,
    LastWriteTimeUtc = excluded.LastWriteTimeUtc,
    TargetFolder = excluded.TargetFolder,
    TargetUrl = excluded.TargetUrl,
    StatusBeforeExclusion = CASE WHEN Files.Status = 'Excluded' THEN Files.StatusBeforeExclusion ELSE Files.Status END,
    Status = 'Excluded',
    LastError = 'Exclu par la configuration',
    LastInventorySeenAt = excluded.LastInventorySeenAt,
    UpdatedAt = excluded.UpdatedAt;
"@
            SqlParameters = $excludedValues
        }
        if ($null -ne $SQLiteConnection) {
            $queryParameters.SQLiteConnection = $SQLiteConnection
        }
        else {
            $queryParameters.DataSource = $DatabasePath
        }

        Invoke-SqliteQuery @queryParameters | Out-Null
    }
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
        "StatusBeforeExclusion",
        "AttemptCount",
        "LastError",
        "LastInventorySeenAt",
        "CreatedAt",
        "UpdatedAt",
        "UploadedAt"
    )
}

function Export-MigrationFilesPaged {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Filter = "1 = 1",

        [ValidateRange(100, 100000)]
        [int]$BatchSize = 5000
    )

    $afterId = 0
    $hasRows = $false

    while ($true) {
        $rows = @(Invoke-SqliteQuery `
            -DataSource $DatabasePath `
            -Query "SELECT * FROM Files WHERE Id > @AfterId AND ($Filter) ORDER BY Id LIMIT @BatchSize;" `
            -SqlParameters @{ AfterId = $afterId; BatchSize = $BatchSize } `
            -As "PSObject")

        if ($rows.Count -eq 0) {
            break
        }

        if ($hasRows) {
            $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -Append
        }
        else {
            $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
            $hasRows = $true
        }

        $afterId = [int64]$rows[-1].Id
    }

    if (-not $hasRows) {
        Export-CsvWithHeaders -Rows @() -Columns (Get-MigrationFileReportColumns) -Path $Path
    }
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

        [int]$MaxAttemptsPerFile = 3,

        [int]$AfterId = 0,

        [ValidateRange(1, 100000)]
        [int]$BatchSize = 1000
    )

    $statusFilter = if ($IncludeFailed) { "('Pending', 'Failed', 'Uploading')" } else { "('Pending', 'Uploading')" }
    $attemptFilter = if ($MaxAttemptsPerFile -gt 0) { "AND (Status = 'Uploading' OR AttemptCount < @MaxAttemptsPerFile)" } else { "" }

    return @(Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "SELECT * FROM Files WHERE Status IN $statusFilter AND Id > @AfterId $attemptFilter ORDER BY Id LIMIT @BatchSize;" `
        -SqlParameters @{
            AfterId            = $AfterId
            BatchSize          = $BatchSize
            MaxAttemptsPerFile = $MaxAttemptsPerFile
        } `
        -As "PSObject")
}

function Get-MigrationFilesToProcessCount {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [switch]$IncludeFailed,

        [int]$MaxAttemptsPerFile = 3
    )

    $statusFilter = if ($IncludeFailed) { "('Pending', 'Failed', 'Uploading')" } else { "('Pending', 'Uploading')" }
    $attemptFilter = if ($MaxAttemptsPerFile -gt 0) { "AND (Status = 'Uploading' OR AttemptCount < @MaxAttemptsPerFile)" } else { "" }

    return [int](Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "SELECT COUNT(*) FROM Files WHERE Status IN $statusFilter $attemptFilter;" `
        -SqlParameters @{ MaxAttemptsPerFile = $MaxAttemptsPerFile } `
        -As "SingleValue")
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
PRAGMA busy_timeout=30000;

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
    $summaryRows = @(Invoke-SqliteQuery `
        -DataSource $DatabasePath `
        -Query "SELECT Status, COUNT(*) AS Count, COALESCE(SUM(SizeBytes), 0) AS TotalBytes FROM Files GROUP BY Status ORDER BY Status;" `
        -As "PSObject")
    Export-MigrationFilesPaged -DatabasePath $DatabasePath -Path $reportPath
    Export-CsvWithHeaders -Rows $summaryRows -Columns @("Status", "Count", "TotalBytes") -Path $summaryPath
    Export-MigrationFilesPaged -DatabasePath $DatabasePath -Path $errorReportPath -Filter "Status IN ('Failed', 'MissingLocalFile')"
    Export-MigrationFilesPaged -DatabasePath $DatabasePath -Path $changesReportPath -Filter "HashChanged = 1"

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
    Export-MigrationFilesPaged `
        -DatabasePath $DatabasePath `
        -Path $errorReportPath `
        -Filter "Status IN ('Failed', 'MissingLocalFile')"

    return (Resolve-Path -LiteralPath $errorReportPath).Path
}

function Export-MigrationBlockedExtensionReport {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$ReportDirectory
    )

    if (-not (Test-Path -LiteralPath $ReportDirectory)) {
        New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
    }

    $reportPath = Join-Path $ReportDirectory ("migration_blocked_extensions_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss_fff"))
    Export-MigrationFilesPaged `
        -DatabasePath $DatabasePath `
        -Path $reportPath `
        -Filter "Status = 'BlockedExtension'"
    return (Resolve-Path -LiteralPath $reportPath).Path
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
