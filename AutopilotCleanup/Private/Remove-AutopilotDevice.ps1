function Remove-AutopilotDevice {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )

    $AutopilotDevice = Get-AutopilotDevice -DeviceName $DeviceName -SerialNumber $SerialNumber

    if (-not $AutopilotDevice) {
        Write-ColorOutput "  - Autopilot (not found)" "Yellow"
        return @{ Success = $false; Found = $false; Error = "Device not found" }
    }

    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($AutopilotDevice.id)"

        if ($PSCmdlet.ShouldProcess("$($AutopilotDevice.displayName) (Serial: $($AutopilotDevice.serialNumber))", "Remove from Autopilot")) {
            Invoke-MgGraphRequest -Uri $uri -Method DELETE
            Write-ColorOutput "  ✓ Autopilot" "Green"
        } else {
            Write-ColorOutput "WHATIF: Would remove Autopilot device: $($AutopilotDevice.displayName) (Serial: $($AutopilotDevice.serialNumber))" "Yellow"
        }
        return @{ Success = $true; Found = $true; Error = $null }
    }
    catch {
        $errorMsg = $_.Exception.Message

        # Check for common deletion scenarios
        if ($errorMsg -like "*BadRequest*" -or $errorMsg -like "*Bad Request*") {
            if ($errorMsg -like "*already*" -or $errorMsg -like "*pending*") {
                Write-ColorOutput "⚠ Device $SerialNumber already queued for deletion from Autopilot" "Yellow"
                return @{ Success = $true; Found = $true; Error = "Already queued for deletion" }
            } else {
                Write-ColorOutput "⚠ Device $SerialNumber cannot be deleted from Autopilot (may already be processing)" "Yellow"
                Write-ColorOutput "  Error details: $errorMsg" "Gray"
                return @{ Success = $true; Found = $true; Error = "Cannot delete - likely already processing" }
            }
        }
        elseif ($errorMsg -like "*NotFound*" -or $errorMsg -like "*Not Found*") {
            Write-ColorOutput "⚠ Device $SerialNumber no longer exists in Autopilot (already removed)" "Yellow"
            return @{ Success = $true; Found = $true; Error = "Already removed" }
        }
        else {
            Write-ColorOutput "✗ Error removing device $SerialNumber from Autopilot: $errorMsg" "Red"
            return @{ Success = $false; Found = $true; Error = $errorMsg }
        }
    }
}
