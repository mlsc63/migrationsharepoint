function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO",

        [switch]$NoConsole
    )

    function Test-LogModeAllowsMessage {
        param(
            [Parameter(Mandatory)]
            [string]$Mode,

            [Parameter(Mandatory)]
            [string]$Message,

            [Parameter(Mandatory)]
            [string]$Level
        )

        switch ($Mode) {
            "Quiet" {
                return $false
            }
            "ErrorsOnly" {
                return $Level -eq "ERROR"
            }
            "ProgressOnly" {
                if ($Level -eq "ERROR") {
                    return $true
                }

                if ($Level -eq "SUCCESS") {
                    return $false
                }

                if ($Message -match "^\[(OK|SKIP|WHATIF|EXCLU|BLOQUE)\]") {
                    return $false
                }

                if ($Message -match "^(Upload cible:|Creation du dossier SharePoint:)") {
                    return $false
                }

                return $true
            }
            default {
                return $true
            }
        }
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message

    $logPathVariable = Get-Variable -Name LogPath -Scope Script -ErrorAction SilentlyContinue
    $fileModeVariable = Get-Variable -Name LogFileMode -Scope Script -ErrorAction SilentlyContinue
    $fileMode = if ($fileModeVariable -and -not [string]::IsNullOrWhiteSpace($fileModeVariable.Value)) { "$($fileModeVariable.Value)" } else { "Verbose" }
    if ($logPathVariable -and -not [string]::IsNullOrWhiteSpace($logPathVariable.Value) -and (Test-LogModeAllowsMessage -Mode $fileMode -Message $Message -Level $Level)) {
        Add-Content -LiteralPath $logPathVariable.Value -Value $line
    }

    $consoleModeVariable = Get-Variable -Name LogConsoleMode -Scope Script -ErrorAction SilentlyContinue
    $consoleMode = if ($consoleModeVariable -and -not [string]::IsNullOrWhiteSpace($consoleModeVariable.Value)) { "$($consoleModeVariable.Value)" } else { "Verbose" }
    if (-not $NoConsole -and (Test-LogModeAllowsMessage -Mode $consoleMode -Message $Message -Level $Level)) {
        $color = switch ($Level) {
            "ERROR" { "Red" }
            "WARN" { "DarkYellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }

        Write-Host $line -ForegroundColor $color
    }
}
