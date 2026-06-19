function Get-TenantBlockedExtensions {
    param(
        [switch]$IncludeDot
    )

    $syncClientRestriction = Get-PnPTenantSyncClientRestriction -ErrorAction Stop
    $extensions = $syncClientRestriction.ExcludedFileExtensions

    if ($null -eq $extensions) {
        return @()
    }

    $blockedExtensions = @($extensions) |
        ForEach-Object {
            "$_" -split ";"
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object {
            $extension = $_.Trim().TrimStart(".").ToLowerInvariant()

            if ($IncludeDot) {
                ".$extension"
            }
            else {
                $extension
            }
        } |
        Sort-Object -Unique

    return $blockedExtensions
}
