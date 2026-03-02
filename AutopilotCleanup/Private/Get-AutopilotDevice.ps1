function Get-AutopilotDevice {
    param(
        [Parameter(Position = 0)]
        [string]$SerialNumber,
        [string]$DeviceName
    )

    if (-not $SerialNumber -and -not $DeviceName) {
        Write-Warning "Get-AutopilotDevice: You must provide -SerialNumber or -DeviceName."
        return $null
    }

    $AutopilotDevice = $null

    # Try to find by serial number first if available
    if ($SerialNumber) {
        try {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$SerialNumber')"
            $AutopilotDevice = (Invoke-MgGraphRequest -Uri $uri -Method GET).value | Select-Object -First 1

            if ($AutopilotDevice) {
                return $AutopilotDevice
            } else {
                if (-not $script:MonitoringMode) {
                    Write-ColorOutput "Device with serial $SerialNumber not found in Autopilot" "Yellow"
                }
            }
        }
        catch {
            Write-ColorOutput "Error searching Autopilot by serial number: $($_.Exception.Message)" "Yellow"
        }
    }


    return $AutopilotDevice
}
