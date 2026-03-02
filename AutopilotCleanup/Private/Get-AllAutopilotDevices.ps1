function Get-AllAutopilotDevices {
    Write-ColorOutput "Retrieving all Autopilot devices..." "Yellow"

    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities"
        $allDevices = @()

        do {
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($response.value) {
                $allDevices += $response.value
            }
            $uri = $response.'@odata.nextLink'
        } while ($uri)

        Write-ColorOutput "Found $($allDevices.Count) Autopilot devices" "Green"
        return $allDevices
    }
    catch {
        Write-ColorOutput "Error retrieving Autopilot devices: $($_.Exception.Message)" "Red"
        return @()
    }
}
