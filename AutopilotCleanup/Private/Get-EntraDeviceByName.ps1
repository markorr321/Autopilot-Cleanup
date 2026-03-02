function Get-EntraDeviceByName {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null,
        [string]$EntraDeviceId = $null
    )

    $AADDevices = @()

    try {
        # First try by Azure AD Device ID (most reliable)
        if ($EntraDeviceId) {
            $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$EntraDeviceId'"
            $AADDevices = (Invoke-MgGraphRequest -Uri $uri -Method GET).value
            if ($AADDevices -and $AADDevices.Count -gt 0) {
                Write-ColorOutput "  Found Entra device by Azure AD Device ID" "Green"
            }
        }

        # Fall back to display name search
        if ((-not $AADDevices -or $AADDevices.Count -eq 0) -and -not [string]::IsNullOrWhiteSpace($DeviceName)) {
            $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$DeviceName'"
            $AADDevices = (Invoke-MgGraphRequest -Uri $uri -Method GET).value
        }

        if (-not $AADDevices -or $AADDevices.Count -eq 0) {
            if (-not $script:MonitoringMode) {
                Write-ColorOutput "  - Entra ID (not found)" "Yellow"
            }
            return @()
        }

        # Log if we found duplicates
        if ($AADDevices.Count -gt 1) {
            Write-ColorOutput "Found $($AADDevices.Count) devices with name '$DeviceName' in Entra ID. Will process all duplicates." "Yellow"
        }

        # If we have a serial number, validate each device
        if ($SerialNumber) {
            $validatedDevices = @()
            foreach ($AADDevice in $AADDevices) {
                $deviceSerial = $null
                if ($AADDevice.physicalIds) {
                    foreach ($physicalId in $AADDevice.physicalIds) {
                        if ($physicalId -match '\[SerialNumber\]:(.+)') {
                            $deviceSerial = $matches[1].Trim()
                            break
                        }
                    }
                }

                # If serial numbers match or device has no serial, include it
                if (-not $deviceSerial -or $deviceSerial -eq $SerialNumber) {
                    $validatedDevices += $AADDevice
                    if ($deviceSerial) {
                        Write-ColorOutput "Validated Entra device: $($AADDevice.displayName) (Serial: $deviceSerial)" "Green"
                    }
                } else {
                    Write-ColorOutput "Skipping Entra ID device with ID $($AADDevice.id) - serial number mismatch (Device: $deviceSerial, Expected: $SerialNumber)" "Yellow"
                }
            }
            return $validatedDevices
        }

        return $AADDevices
    }
    catch {
        Write-ColorOutput "Error searching for Entra devices: $($_.Exception.Message)" "Red"
        return @()
    }
}
