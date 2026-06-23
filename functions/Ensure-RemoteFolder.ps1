function Ensure-RemoteFolder {
    param(
        [Parameter(Mandatory)]
        [string]$ServerRelativeFolder,

        [string]$ExistingRoot,

        [switch]$WhatIf
    )

    function Test-PnPTransientFolderError {
        param([System.Management.Automation.ErrorRecord]$ErrorRecord)

        $exception = $ErrorRecord.Exception
        while ($null -ne $exception) {
            if ($exception.Message -match "(?i)(nullable object must have a value|timeout|temporar|throttl|429|502|503|connection|conflict|already exists|existe deja)") {
                return $true
            }

            $exception = $exception.InnerException
        }

        return $false
    }

    function Get-PnPFolderWithRetry {
        param(
            [Parameter(Mandatory)]
            [string]$Url,

            [int]$MaxAttempts = 5
        )

        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            try {
                Get-PnPFolder -Url $Url -ErrorAction Stop | Out-Null
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

            [int]$MaxAttempts = 5
        )

        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            try {
                Add-PnPFolder -Name $Name -Folder $Folder -ErrorAction Stop | Out-Null
                Get-PnPFolderWithRetry -Url $Url -MaxAttempts $MaxAttempts
                return
            }
            catch {
                try {
                    Get-PnPFolderWithRetry -Url $Url -MaxAttempts $MaxAttempts
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

    $normalized = "/$($ServerRelativeFolder.Trim('/'))"

    $cacheVariable = Get-Variable -Name VerifiedRemoteFolders -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $cacheVariable) {
        $script:VerifiedRemoteFolders = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
    }

    if ([string]::IsNullOrWhiteSpace($ExistingRoot)) {
        $parts = @($normalized.Trim("/") -split "/" | Where-Object { $_ })
        if ($parts.Count -lt 3) {
            throw "Chemin SharePoint invalide: $ServerRelativeFolder"
        }

        $current = "/$($parts[0])/$($parts[1])/$($parts[2])"
        $remainingParts = @($parts | Select-Object -Skip 3)
    }
    else {
        $current = "/$($ExistingRoot.Trim('/'))"
        if ($normalized -ne $current -and -not $normalized.StartsWith("$current/", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Le dossier cible n'est pas situe sous la racine SharePoint attendue: $ServerRelativeFolder"
        }

        $relativeFolder = $normalized.Substring($current.Length).Trim("/")
        $remainingParts = @($relativeFolder -split "/" | Where-Object { $_ })
    }

    if (-not $script:VerifiedRemoteFolders.Contains($current)) {
        try {
            Get-PnPFolderWithRetry -Url $current
            [void]$script:VerifiedRemoteFolders.Add($current)
        }
        catch {
            throw "Bibliotheque ou dossier racine inaccessible: $current - $($_.Exception.Message)"
        }
    }

    foreach ($part in $remainingParts) {
        $parent = $current
        $current = "$current/$part"

        if ($script:VerifiedRemoteFolders.Contains($current)) {
            continue
        }

        try {
            Get-PnPFolderWithRetry -Url $current
        }
        catch {
            if (-not (Test-PnPNotFoundError -ErrorRecord $_)) {
                throw "Verification du dossier SharePoint impossible: $current - $($_.Exception.Message)"
            }

            Write-Log -Level "INFO" -Message "Creation du dossier SharePoint: $current"
            if (-not $WhatIf) {
                Add-PnPFolderWithRetry -Name $part -Folder $parent -Url $current
            }
        }

        [void]$script:VerifiedRemoteFolders.Add($current)
    }
}
