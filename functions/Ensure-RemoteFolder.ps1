function Ensure-RemoteFolder {
    param(
        [Parameter(Mandatory)]
        [string]$ServerRelativeFolder,

        [string]$ExistingRoot,

        [switch]$WhatIf
    )

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
            Get-PnPFolder -Url $current -ErrorAction Stop | Out-Null
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
            Get-PnPFolder -Url $current -ErrorAction Stop | Out-Null
        }
        catch {
            if (-not (Test-PnPNotFoundError -ErrorRecord $_)) {
                throw
            }

            Write-Log -Level "INFO" -Message "Creation du dossier SharePoint: $current"
            if (-not $WhatIf) {
                Add-PnPFolder -Name $part -Folder $parent -ErrorAction Stop | Out-Null
            }
        }

        [void]$script:VerifiedRemoteFolders.Add($current)
    }
}
