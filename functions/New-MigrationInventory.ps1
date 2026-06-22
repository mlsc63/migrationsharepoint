function New-MigrationInventory {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo[]]$Files,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$BlockedExtensions,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [string]$LogDirectory
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = Join-Path $PSScriptRoot "..\logs"
    }

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $blockedLogPath = Join-Path $LogDirectory ("blocked_extensions_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $normalizedBlockedExtensions = @($BlockedExtensions) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().TrimStart(".").ToLowerInvariant() }

    $blockedItems = [System.Collections.Generic.List[object]]::new()
    $blockedLines = [System.Collections.Generic.List[string]]::new()
    $migratableCount = 0

    Set-Content -LiteralPath $blockedLogPath -Value "Fichiers non migrables selon la politique d'extensions"
    Add-Content -LiteralPath $blockedLogPath -Value ("Date inventaire: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
    Add-Content -LiteralPath $blockedLogPath -Value ""

    foreach ($file in $Files) {
        $relativePath = Convert-ToSharePointRelativePath -BasePath $SourceRoot -FilePath $file.FullName
        $fileSize = Format-FileSize -Bytes $file.Length
        $extension = [System.IO.Path]::GetExtension($file.Name).Trim().TrimStart(".").ToLowerInvariant()

        if (-not [string]::IsNullOrWhiteSpace($extension) -and $normalizedBlockedExtensions -contains $extension) {
            $line = "[BLOQUE] $relativePath - Path: $($file.FullName) - Extension: .$extension - Taille: $fileSize"
            $blockedLines.Add($line)

            $blockedItems.Add([pscustomobject]@{
                Path      = $relativePath
                FullPath  = $file.FullName
                Extension = $extension
                SizeBytes = $file.Length
                Size      = $fileSize
            })

            continue
        }

        $migratableCount++
    }

    if ($blockedItems.Count -eq 0) {
        Add-Content -LiteralPath $blockedLogPath -Value "Aucun fichier bloque par la politique d'extensions."
    }
    else {
        Add-Content -LiteralPath $blockedLogPath -Value $blockedLines.ToArray()
    }

    return [pscustomobject]@{
        TotalFiles       = $Files.Count
        MigratableFiles  = $migratableCount
        BlockedFiles     = $blockedItems.Count
        BlockedLogPath   = (Resolve-Path -LiteralPath $blockedLogPath).Path
        BlockedItems     = $blockedItems.ToArray()
    }
}
