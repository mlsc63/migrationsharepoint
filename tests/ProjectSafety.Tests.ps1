$projectRoot = Split-Path -Parent $PSScriptRoot
Get-ChildItem (Join-Path $projectRoot "functions") -Filter "*.ps1" | ForEach-Object {
    . $_.FullName
}

Describe "Project safety" {
    It "distinguishes a SharePoint 404 from another error" {
        $notFound = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("HTTP 404 File Not Found"),
            "NotFound",
            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
            $null)
        $accessDenied = [System.Management.Automation.ErrorRecord]::new(
            [System.UnauthorizedAccessException]::new("Access denied"),
            "Denied",
            [System.Management.Automation.ErrorCategory]::PermissionDenied,
            $null)

        (Test-PnPNotFoundError -ErrorRecord $notFound) | Should Be $true
        (Test-PnPNotFoundError -ErrorRecord $accessDenied) | Should Be $false
    }

    It "calculates inventory fingerprints in parallel" {
        $files = foreach ($id in 1..8) {
            $path = Join-Path $TestDrive "parallel-$id.txt"
            Set-Content -LiteralPath $path -Value "content-$id" -NoNewline
            Get-Item -LiteralPath $path
        }

        $fingerprints = @(Get-MigrationFileFingerprintsParallel -Files $files -HashMode SHA256 -ThrottleLimit 4)
        $expected = Get-MigrationFileFingerprint -File $files[0] -HashMode SHA256
        $actual = @($fingerprints | Where-Object FullPath -eq $files[0].FullName)[0]

        $fingerprints.Count | Should Be 8
        @($fingerprints | Where-Object { $_.Error }).Count | Should Be 0
        $actual.FileHash | Should Be $expected
    }

    It "stores a fingerprint prepared by an inventory worker" {
        $databasePath = Join-Path $TestDrive "prepared-fingerprint.db"
        $filePath = Join-Path $TestDrive "prepared.txt"
        Set-Content -LiteralPath $filePath -Value "prepared" -NoNewline
        Initialize-MigrationDatabase -DatabasePath $databasePath

        Upsert-MigrationFile `
            -DatabasePath $databasePath `
            -File (Get-Item -LiteralPath $filePath) `
            -SourceRoot $TestDrive `
            -ServerRelativeRoot "/sites/Test/Shared Documents" `
            -InventorySeenAt "2026-06-22T00:00:00Z" `
            -HashMode SHA256 `
            -FileHash "SHA256:PREPARED" `
            -FingerprintProvided

        $storedHash = Invoke-SqliteQuery -DataSource $databasePath -Query "SELECT FileHash FROM Files LIMIT 1;" -As SingleValue
        $storedHash | Should Be "SHA256:PREPARED"
    }

    It "prevents two exclusive executions on the same project" {
        $databasePath = Join-Path $TestDrive "migration.db"
        New-Item -ItemType File -Path $databasePath | Out-Null
        $firstLock = Enter-MigrationProjectLock -DatabasePath $databasePath

        try {
            $functionPath = Join-Path $projectRoot "functions\ProjectDatabase.ps1"
            $command = @"
. '$($functionPath.Replace("'", "''"))'
try {
    `$lock = Enter-MigrationProjectLock -DatabasePath '$($databasePath.Replace("'", "''"))'
    Exit-MigrationProjectLock -LockStream `$lock
    exit 1
}
catch {
    exit 0
}
"@
            & (Join-Path $PSHOME "pwsh.exe") -NoProfile -Command $command
            $LASTEXITCODE | Should Be 0
        }
        finally {
            Exit-MigrationProjectLock -LockStream $firstLock
        }
    }

    It "paginates SQLite files without duplicates" {
        $databasePath = Join-Path $TestDrive "pagination.db"
        Initialize-MigrationDatabase -DatabasePath $databasePath
        $now = (Get-Date).ToUniversalTime().ToString("o")

        foreach ($id in 1..5) {
            Invoke-SqliteQuery -DataSource $databasePath -Query @"
INSERT INTO Files (
    FullPath, RelativePath, SizeBytes, LastWriteTimeUtc, TargetFolder,
    TargetUrl, Status, AttemptCount, CreatedAt, UpdatedAt
) VALUES (
    @FullPath, @RelativePath, 1, @Now, '/sites/Test/Shared Documents',
    @TargetUrl, 'Pending', 0, @Now, @Now
);
"@ -SqlParameters @{
                FullPath     = "C:\test\file$id.txt"
                RelativePath = "file$id.txt"
                TargetUrl    = "/sites/Test/Shared Documents/file$id.txt"
                Now          = $now
            } | Out-Null
        }

        $firstPage = @(Get-MigrationFilesToProcess -DatabasePath $databasePath -BatchSize 2)
        $secondPage = @(Get-MigrationFilesToProcess -DatabasePath $databasePath -AfterId $firstPage[-1].Id -BatchSize 2)

        $firstPage.Count | Should Be 2
        $secondPage.Count | Should Be 2
        @($firstPage.Id | Where-Object { $secondPage.Id -contains $_ }).Count | Should Be 0
    }

    It "closes interrupted runs and completes the active run" {
        $databasePath = Join-Path $TestDrive "runs.db"
        Initialize-MigrationDatabase -DatabasePath $databasePath

        $firstRun = Start-MigrationRun -DatabasePath $databasePath -Mode "Migrate"
        $secondRun = Start-MigrationRun -DatabasePath $databasePath -Mode "Resume"
        Complete-MigrationRun -DatabasePath $databasePath -RunId $secondRun -Result "Success" -Message "OK"
        $runs = @(Invoke-SqliteQuery -DataSource $databasePath -Query "SELECT Id, Result FROM Runs ORDER BY Id;" -As "PSObject")

        $runs.Count | Should Be 2
        $runs[0].Result | Should Be "Interrupted"
        $runs[1].Result | Should Be "Success"
    }

    It "preserves an uncertain upload during a full inventory" {
        $databasePath = Join-Path $TestDrive "uploading-state.db"
        $filePath = Join-Path $TestDrive "uploading.txt"
        Set-Content -LiteralPath $filePath -Value "same-content" -NoNewline
        Initialize-MigrationDatabase -DatabasePath $databasePath
        $null = Upsert-MigrationFile -DatabasePath $databasePath -File (Get-Item $filePath) -SourceRoot $TestDrive -ServerRelativeRoot "/sites/Test/Docs" -InventorySeenAt "run1"
        Invoke-SqliteQuery -DataSource $databasePath -Query "UPDATE Files SET Status='Uploading', AttemptCount=1;" | Out-Null

        $null = Upsert-MigrationFile -DatabasePath $databasePath -File (Get-Item $filePath) -SourceRoot $TestDrive -ServerRelativeRoot "/sites/Test/Docs" -InventorySeenAt "run2"
        $row = @(Invoke-SqliteQuery -DataSource $databasePath -Query "SELECT Status, AttemptCount FROM Files;" -As PSObject)[0]

        $row.Status | Should Be "Uploading"
        $row.AttemptCount | Should Be 1
    }

    It "resets attempts when failed file content changes" {
        $databasePath = Join-Path $TestDrive "changed-failed.db"
        $filePath = Join-Path $TestDrive "changed.txt"
        Set-Content -LiteralPath $filePath -Value "version-one" -NoNewline
        Initialize-MigrationDatabase -DatabasePath $databasePath
        $null = Upsert-MigrationFile -DatabasePath $databasePath -File (Get-Item $filePath) -SourceRoot $TestDrive -ServerRelativeRoot "/sites/Test/Docs" -InventorySeenAt "run1"
        Invoke-SqliteQuery -DataSource $databasePath -Query "UPDATE Files SET Status='Failed', AttemptCount=3, UploadedAt='2026-06-22T00:00:00Z';" | Out-Null
        Set-Content -LiteralPath $filePath -Value "version-two" -NoNewline

        $null = Upsert-MigrationFile -DatabasePath $databasePath -File (Get-Item $filePath) -SourceRoot $TestDrive -ServerRelativeRoot "/sites/Test/Docs" -InventorySeenAt "run2"
        $row = @(Invoke-SqliteQuery -DataSource $databasePath -Query "SELECT Status, AttemptCount, UploadedAt, HashChanged FROM Files;" -As PSObject)[0]

        $row.Status | Should Be "Pending"
        $row.AttemptCount | Should Be 0
        $row.UploadedAt | Should BeNullOrEmpty
        $row.HashChanged | Should Be 1
    }

    It "re-evaluates returned and newly blocked files" {
        $databasePath = Join-Path $TestDrive "status-refresh.db"
        $returnedPath = Join-Path $TestDrive "returned.txt"
        $blockedPath = Join-Path $TestDrive "blocked.foo"
        Set-Content -LiteralPath $returnedPath -Value "returned" -NoNewline
        Set-Content -LiteralPath $blockedPath -Value "blocked" -NoNewline
        Initialize-MigrationDatabase -DatabasePath $databasePath
        $null = Upsert-MigrationFile -DatabasePath $databasePath -File (Get-Item $returnedPath) -SourceRoot $TestDrive -ServerRelativeRoot "/sites/Test/Docs" -InventorySeenAt "run1"
        $null = Upsert-MigrationFile -DatabasePath $databasePath -File (Get-Item $blockedPath) -SourceRoot $TestDrive -ServerRelativeRoot "/sites/Test/Docs" -InventorySeenAt "run1"
        Invoke-SqliteQuery -DataSource $databasePath -Query "UPDATE Files SET Status='MissingLocalFile' WHERE RelativePath='returned.txt';" | Out-Null

        $null = Upsert-MigrationFile -DatabasePath $databasePath -File (Get-Item $returnedPath) -SourceRoot $TestDrive -ServerRelativeRoot "/sites/Test/Docs" -InventorySeenAt "run2"
        $null = Upsert-MigrationFile -DatabasePath $databasePath -File (Get-Item $blockedPath) -SourceRoot $TestDrive -ServerRelativeRoot "/sites/Test/Docs" -BlockedExtensions @("foo") -InventorySeenAt "run2"
        $rows = @(Invoke-SqliteQuery -DataSource $databasePath -Query "SELECT RelativePath, Status FROM Files ORDER BY RelativePath;" -As PSObject)

        @($rows | Where-Object RelativePath -eq "returned.txt")[0].Status | Should Be "Pending"
        @($rows | Where-Object RelativePath -eq "blocked.foo")[0].Status | Should Be "BlockedExtension"
    }

    It "restores a file when its exclusion is removed" {
        $databasePath = Join-Path $TestDrive "excluded-state.db"
        $filePath = Join-Path $TestDrive "excluded.txt"
        Set-Content -LiteralPath $filePath -Value "excluded" -NoNewline
        Initialize-MigrationDatabase -DatabasePath $databasePath
        $null = Upsert-MigrationFile -DatabasePath $databasePath -File (Get-Item $filePath) -SourceRoot $TestDrive -ServerRelativeRoot "/sites/Test/Docs" -InventorySeenAt "run1"
        Set-MigrationFileExcluded -DatabasePath $databasePath -File (Get-Item $filePath) -SourceRoot $TestDrive -ServerRelativeRoot "/sites/Test/Docs" -InventorySeenAt "run2"
        $null = Upsert-MigrationFile -DatabasePath $databasePath -File (Get-Item $filePath) -SourceRoot $TestDrive -ServerRelativeRoot "/sites/Test/Docs" -InventorySeenAt "run3"
        $row = @(Invoke-SqliteQuery -DataSource $databasePath -Query "SELECT Status, StatusBeforeExclusion FROM Files;" -As PSObject)[0]

        $row.Status | Should Be "Pending"
        $row.StatusBeforeExclusion | Should BeNullOrEmpty
    }

    It "includes uncertain uploads even at maximum attempts" {
        $databasePath = Join-Path $TestDrive "max-uploading.db"
        Initialize-MigrationDatabase -DatabasePath $databasePath
        $now = (Get-Date).ToUniversalTime().ToString("o")
        Invoke-SqliteQuery -DataSource $databasePath -Query @"
INSERT INTO Files (FullPath, RelativePath, SizeBytes, LastWriteTimeUtc, TargetFolder, TargetUrl, Status, AttemptCount, CreatedAt, UpdatedAt)
VALUES ('C:\test\uncertain.txt', 'uncertain.txt', 1, @Now, '/sites/Test/Docs', '/sites/Test/Docs/uncertain.txt', 'Uploading', 3, @Now, @Now);
"@ -SqlParameters @{ Now = $now } | Out-Null

        @(Get-MigrationFilesToProcess -DatabasePath $databasePath -IncludeFailed -MaxAttemptsPerFile 3).Count | Should Be 1
    }

    It "rolls back an interrupted inventory transaction" {
        $databasePath = Join-Path $TestDrive "rollback.db"
        Initialize-MigrationDatabase -DatabasePath $databasePath
        Invoke-SqliteQuery -DataSource $databasePath -Query "INSERT INTO ProjectMetadata (Key, Value) VALUES ('State', 'Before');" | Out-Null

        $transactionFailed = $false
        try {
            Invoke-MigrationDatabaseTransaction -DatabasePath $databasePath -Action {
                param($connection)
                Invoke-SqliteQuery -SQLiteConnection $connection -Query "UPDATE ProjectMetadata SET Value='During' WHERE Key='State';" | Out-Null
                throw "Stop test"
            }
        }
        catch {
            $transactionFailed = $true
        }

        $transactionFailed | Should Be $true
        (Invoke-SqliteQuery -DataSource $databasePath -Query "SELECT Value FROM ProjectMetadata WHERE Key='State';" -As SingleValue) | Should Be "Before"
    }

    It "uses WAL and accepts an empty tenant exclusion list" {
        $databasePath = Join-Path $TestDrive "wal.db"
        $logDirectory = Join-Path $TestDrive "empty-list"
        Initialize-MigrationDatabase -DatabasePath $databasePath
        $inventory = New-MigrationInventory -Files (Get-Item $PSCommandPath) -BlockedExtensions @() -SourceRoot $projectRoot -LogDirectory $logDirectory

        (Invoke-SqliteQuery -DataSource $databasePath -Query "PRAGMA journal_mode;" -As SingleValue) | Should Be "wal"
        $inventory.BlockedFiles | Should Be 0
    }

    It "rejects conflicting command actions" {
        $failed = $false
        try {
            & (Join-Path $projectRoot "main.ps1") -Inventory -Migrate
        }
        catch {
            $failed = $_.Exception.Message -match "Une seule action"
        }

        $failed | Should Be $true
    }

    It "validates negative retry limits in XML" {
        $sourceDirectory = Join-Path $TestDrive "config-source"
        $configPath = Join-Path $TestDrive "invalid-config.xml"
        New-Item -ItemType Directory -Path $sourceDirectory | Out-Null
        @"
<Configuration>
  <Authentication><TenantId>tenant</TenantId><ClientId>client</ClientId><CertificateThumbprint>thumbprint</CertificateThumbprint></Authentication>
  <Source><LocalPath>$sourceDirectory</LocalPath></Source>
  <Destination><SiteUrl>https://contoso.sharepoint.com/sites/Test</SiteUrl><Library>Docs</Library><Folder /></Destination>
  <Logging><LogDirectory>logs</LogDirectory></Logging>
  <Migration><HashMode>SHA256</HashMode><MaxAttemptsPerFile>-1</MaxAttemptsPerFile></Migration>
</Configuration>
"@ | Set-Content -LiteralPath $configPath

        $failed = $false
        try {
            Get-MigrationContext -ConfigPath $configPath | Out-Null
        }
        catch {
            $failed = $_.Exception.Message -match "MaxAttemptsPerFile"
        }

        $failed | Should Be $true
    }
}
