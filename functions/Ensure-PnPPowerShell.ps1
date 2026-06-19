function Ensure-PnPPowerShell {
    if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
        throw "Le module PnP.PowerShell est introuvable. Installe-le avec: Install-Module PnP.PowerShell -Scope CurrentUser"
    }

    Import-Module PnP.PowerShell -ErrorAction Stop
}
