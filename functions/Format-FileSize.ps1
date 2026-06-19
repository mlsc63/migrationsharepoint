function Format-FileSize {
    param(
        [Parameter(Mandatory)]
        [long]$Bytes
    )

    if ($Bytes -ge 1GB) {
        return "{0:N2} Go ({1} octets)" -f ($Bytes / 1GB), $Bytes
    }

    if ($Bytes -ge 1MB) {
        return "{0:N2} Mo ({1} octets)" -f ($Bytes / 1MB), $Bytes
    }

    if ($Bytes -ge 1KB) {
        return "{0:N2} Ko ({1} octets)" -f ($Bytes / 1KB), $Bytes
    }

    return "$Bytes octets"
}
