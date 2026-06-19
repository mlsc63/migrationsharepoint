function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO",

        [switch]$NoConsole
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message

    $logPathVariable = Get-Variable -Name LogPath -Scope Script -ErrorAction SilentlyContinue
    if ($logPathVariable -and -not [string]::IsNullOrWhiteSpace($logPathVariable.Value)) {
        Add-Content -LiteralPath $logPathVariable.Value -Value $line
    }

    if (-not $NoConsole) {
        $color = switch ($Level) {
            "ERROR" { "Red" }
            "WARN" { "DarkYellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }

        Write-Host $line -ForegroundColor $color
    }
}
