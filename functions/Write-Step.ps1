function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level "INFO" -Message "==> $Message"
        return
    }

    Write-Host "==> $Message" -ForegroundColor Cyan
}
