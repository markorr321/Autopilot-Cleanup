function Invoke-IntuneDeviceWipe {
    param(
        [string]$ManagedDeviceId,
        [bool]$KeepEnrollmentData = $false,
        [bool]$KeepUserData = $false
    )

    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$ManagedDeviceId/wipe"
    $body = @{}
    if ($KeepEnrollmentData) { $body.keepEnrollmentData = $true }
    if ($KeepUserData) { $body.keepUserData = $true }

    try {
        if ($body.Count -gt 0) {
            Invoke-MgGraphRequest -Uri $uri -Method POST -Body ($body | ConvertTo-Json)
        } else {
            Invoke-MgGraphRequest -Uri $uri -Method POST
        }
        return $true
    }
    catch {
        Write-ColorOutput "Error sending wipe command: $($_.Exception.Message)" "Red"
        return $false
    }
}
