function Initialize-Log {
    param(
        [string]$LogDirectory,

        [ValidateSet("Verbose", "ProgressOnly", "ErrorsOnly", "Quiet")]
        [string]$ConsoleMode = "Verbose",

        [ValidateSet("Verbose", "ProgressOnly", "ErrorsOnly", "Quiet")]
        [string]$FileMode = "Verbose"
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = Join-Path $PSScriptRoot "..\logs"
    }

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $logFileName = "migration_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss_fff")
    $LogPath = Join-Path $LogDirectory $logFileName

    New-Item -ItemType File -Path $LogPath -Force | Out-Null
    $script:LogPath = (Resolve-Path -LiteralPath $LogPath).Path
    $script:LogConsoleMode = $ConsoleMode
    $script:LogFileMode = $FileMode

    Write-Log -Level "INFO" -Message "Journal initialise: $script:LogPath"
    return $script:LogPath
}
