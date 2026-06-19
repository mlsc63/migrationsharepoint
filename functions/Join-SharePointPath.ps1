function Join-SharePointPath {
    param(
        [Parameter(Mandatory)]
        [string]$SiteUrl,

        [Parameter(Mandatory)]
        [string]$Library,

        [string]$Folder
    )

    $uri = [Uri]$SiteUrl
    $sitePath = [Uri]::UnescapeDataString($uri.AbsolutePath.TrimEnd("/"))

    if ([string]::IsNullOrWhiteSpace($sitePath) -or $sitePath -eq "/") {
        throw "Destination.SiteUrl doit pointer vers un site SharePoint, ex: https://contoso.sharepoint.com/sites/Projet"
    }

    $libraryPath = $Library.Trim("/")
    $folderPath = if ([string]::IsNullOrWhiteSpace($Folder)) { "" } else { $Folder.Trim("/") }
    $serverRelativeRoot = "$sitePath/$libraryPath"

    if (-not [string]::IsNullOrWhiteSpace($folderPath)) {
        $serverRelativeRoot = "$serverRelativeRoot/$folderPath"
    }

    return [pscustomobject]@{
        SiteUrl            = "$($uri.Scheme)://$($uri.Host)$sitePath"
        ServerRelativeRoot = $serverRelativeRoot
    }
}
