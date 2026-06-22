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
}
