function Get-RequiredValue {
    param(
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "La valeur '$Name' est obligatoire dans le fichier de configuration."
    }

    return $Value.Trim()
}
