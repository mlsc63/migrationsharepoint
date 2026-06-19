function Convert-ToSharePointRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$BasePath,

        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $relativePath = [System.IO.Path]::GetRelativePath($BasePath, $FilePath)
    return ($relativePath -replace "\\", "/")
}
