function Invoke-IntuneDeviceSync {
    param([string]$ManagedDeviceId)

    try {
        Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$ManagedDeviceId/syncDevice" -Method POST
        return $true
    }
    catch { return $false }
}
