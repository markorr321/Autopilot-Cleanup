function Remove-IntuneDevice {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )

    $IntuneDevice = Get-IntuneDevice -DeviceName $DeviceName -SerialNumber $SerialNumber

    if (-not $IntuneDevice) {
        Write-ColorOutput "  - Intune (not found)" "Yellow"
        return @{ Success = $false; Found = $false; Error = "Device not found" }
    }

    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($IntuneDevice.id)"

        if ($PSCmdlet.ShouldProcess("$($IntuneDevice.deviceName) (Serial: $($IntuneDevice.serialNumber))", "Remove from Intune")) {
            Invoke-MgGraphRequest -Uri $uri -Method DELETE
            Write-ColorOutput "  ✓ Intune" "Green"
        } else {
            Write-ColorOutput "WHATIF: Would remove Intune device: $($IntuneDevice.deviceName) (Serial: $($IntuneDevice.serialNumber))" "Yellow"
        }
        return @{ Success = $true; Found = $true; Error = $null }
    }
    catch {
        $errorMsg = $_.Exception.Message
        Write-ColorOutput "✗ Error removing device $DeviceName from Intune: $errorMsg" "Red"
        return @{ Success = $false; Found = $true; Error = $errorMsg }
    }
}
