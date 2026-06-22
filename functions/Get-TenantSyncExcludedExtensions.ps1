function Get-TenantSyncExcludedExtensions {
    param(
        [switch]$IncludeDot
    )

    $syncClientRestriction = Get-PnPTenantSyncClientRestriction -ErrorAction Stop
    $extensions = $syncClientRestriction.ExcludedFileExtensions

    if ($null -eq $extensions) {
        return @()
    }

    $excludedExtensions = @($extensions) |
        ForEach-Object { "$_" -split ";" } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object {
            $extension = $_.Trim().TrimStart(".").ToLowerInvariant()
            if ($IncludeDot) { ".$extension" } else { $extension }
        } |
        Sort-Object -Unique

    return $excludedExtensions
}
