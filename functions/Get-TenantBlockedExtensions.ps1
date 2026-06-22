function Get-TenantBlockedExtensions {
    param(
        [switch]$IncludeDot
    )

    Write-Warning "Get-TenantBlockedExtensions est obsolete. Utilise Get-TenantSyncExcludedExtensions."
    return @(Get-TenantSyncExcludedExtensions -IncludeDot:$IncludeDot)
}
