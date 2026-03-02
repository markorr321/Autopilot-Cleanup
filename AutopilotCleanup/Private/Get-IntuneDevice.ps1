function Get-IntuneDevice {
    param(
        [Parameter(Position = 0)]
        [string]$DeviceName,
        [string]$SerialNumber
    )

    if (-not $DeviceName -and -not $SerialNumber) {
        Write-Warning "Get-IntuneDevice: You must provide -DeviceName or -SerialNumber."
        return $null
    }

    $IntuneDevice = $null

    # Try by device name first if available
    if ($DeviceName) {
        try {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$DeviceName'"
            $IntuneDevice = (Invoke-MgGraphRequest -Uri $uri -Method GET).value | Select-Object -First 1

            if ($IntuneDevice) {
                return $IntuneDevice
            }
        }
        catch {
            Write-ColorOutput "Error searching Intune by device name: $($_.Exception.Message)" "Yellow"
        }
    }

    # If not found by name and we have serial number, try by serial
    if (-not $IntuneDevice -and $SerialNumber) {
        try {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$SerialNumber'"
            $IntuneDevice = (Invoke-MgGraphRequest -Uri $uri -Method GET).value | Select-Object -First 1

        }
        catch {
            Write-ColorOutput "Error searching Intune by serial number: $($_.Exception.Message)" "Yellow"
        }
    }

    return $IntuneDevice
}
