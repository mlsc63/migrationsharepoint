function Ensure-RemoteFolder {
    param(
        [Parameter(Mandatory)]
        [string]$ServerRelativeFolder,

        [switch]$WhatIf
    )

    $normalized = $ServerRelativeFolder.Trim("/")
    $parts = @($normalized -split "/" | Where-Object { $_ })

    if ($parts.Count -lt 3) {
        throw "Chemin SharePoint invalide: $ServerRelativeFolder"
    }

    $current = "/$($parts[0])/$($parts[1])/$($parts[2])"

    try {
        Get-PnPFolder -Url $current -ErrorAction Stop | Out-Null
    }
    catch {
        throw "Bibliotheque ou dossier racine inaccessible: $current - $($_.Exception.Message)"
    }

    for ($i = 3; $i -lt $parts.Count; $i++) {
        $parent = $current
        $current = "$current/$($parts[$i])"

        try {
            Get-PnPFolder -Url $current -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Log -Level "INFO" -Message "Creation du dossier SharePoint: $current"
            if (-not $WhatIf) {
                Add-PnPFolder -Name $parts[$i] -Folder $parent | Out-Null
            }
        }
    }
}
