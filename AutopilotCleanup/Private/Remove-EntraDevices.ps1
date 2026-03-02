function Remove-EntraDevices {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [array]$Devices,
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )

    if (-not $Devices -or $Devices.Count -eq 0) {
        return @{ Success = $false; DeletedCount = 0; FailedCount = 0; Errors = @() }
    }

    $deletedCount = 0
    $failedCount = 0
    $allErrors = @()

    foreach ($AADDevice in $Devices) {
        # Extract serial number from physicalIds for logging
        $deviceSerial = $null
        if ($AADDevice.physicalIds) {
            foreach ($physicalId in $AADDevice.physicalIds) {
                if ($physicalId -match '\[SerialNumber\]:(.+)') {
                    $deviceSerial = $matches[1].Trim()
                    break
                }
            }
        }

        try {
            if ($PSCmdlet.ShouldProcess("$($AADDevice.displayName) (ID: $($AADDevice.id), Serial: $deviceSerial)", "Remove from Entra ID")) {
                $uri = "https://graph.microsoft.com/v1.0/devices/$($AADDevice.id)"
                Invoke-MgGraphRequest -Uri $uri -Method DELETE
                $deletedCount++
                Write-ColorOutput "  ✓ Entra ID" "Green"
            } else {
                Write-ColorOutput "WHATIF: Would remove Entra ID device: $($AADDevice.displayName) (ID: $($AADDevice.id), Serial: $deviceSerial)" "Yellow"
                $deletedCount++
            }
        }
        catch {
            $failedCount++
            $errorMsg = $_.Exception.Message
            $allErrors += $errorMsg
            Write-ColorOutput "✗ Error removing device $DeviceName (ID: $($AADDevice.id)) from Entra ID: $errorMsg" "Red"
        }
    }

    # Determine overall success
    $success = $false
    if ($deletedCount -gt 0 -and $failedCount -eq 0) {
        $success = $true
        if ($deletedCount -gt 1) {
            Write-ColorOutput "Successfully removed all $deletedCount duplicate devices named '$DeviceName' from Entra ID." "Green"
        }
    }
    elseif ($deletedCount -gt 0 -and $failedCount -gt 0) {
        Write-ColorOutput "Partial success: Deleted $deletedCount device(s), failed to delete $failedCount device(s) from Entra ID." "Yellow"
    }

    return @{
        Success = $success
        DeletedCount = $deletedCount
        FailedCount = $failedCount
        Errors = $allErrors
    }
}
