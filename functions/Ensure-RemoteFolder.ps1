function Ensure-RemoteFolder {
    param(
        [Parameter(Mandatory)]
        [string]$ServerRelativeFolder,

        [switch]$WhatIf
    )

    $normalized = $ServerRelativeFolder.Trim("/")
    $parts = @($normalized -split "/" | Where-Object { $_ })

    $cacheVariable = Get-Variable -Name VerifiedRemoteFolders -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $cacheVariable) {
        $script:VerifiedRemoteFolders = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
    }

    if ($parts.Count -lt 3) {
        throw "Chemin SharePoint invalide: $ServerRelativeFolder"
    }

    $current = "/$($parts[0])/$($parts[1])/$($parts[2])"

    if (-not $script:VerifiedRemoteFolders.Contains($current)) {
        try {
            Get-PnPFolder -Url $current -ErrorAction Stop | Out-Null
            [void]$script:VerifiedRemoteFolders.Add($current)
        }
        catch {
            throw "Bibliotheque ou dossier racine inaccessible: $current - $($_.Exception.Message)"
        }
    }

    for ($i = 3; $i -lt $parts.Count; $i++) {
        $parent = $current
        $current = "$current/$($parts[$i])"

        if ($script:VerifiedRemoteFolders.Contains($current)) {
            continue
        }

        try {
            Get-PnPFolder -Url $current -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Log -Level "INFO" -Message "Creation du dossier SharePoint: $current"
            if (-not $WhatIf) {
                Add-PnPFolder -Name $parts[$i] -Folder $parent | Out-Null
            }
        }

        [void]$script:VerifiedRemoteFolders.Add($current)
    }
}
