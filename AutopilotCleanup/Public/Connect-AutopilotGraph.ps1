function Connect-AutopilotGraph {
    Write-ColorOutput "Connecting to Microsoft Graph..." "Yellow"

    $requiredScopes = @(
        "Device.ReadWrite.All",
        "DeviceManagementManagedDevices.ReadWrite.All",
        "DeviceManagementManagedDevices.PrivilegedOperations.All",
        "DeviceManagementServiceConfig.ReadWrite.All"
    )

    try {
        # Suppress WAM warning by setting preference before connecting
        $WarningPreference = 'SilentlyContinue'

        # Build Connect-MgGraph parameters
        $connectParams = @{
            Scopes      = $requiredScopes
            NoWelcome   = $true
            ErrorAction = 'Stop'
        }

        # Add custom app registration if configured
        if (-not [string]::IsNullOrWhiteSpace($script:CustomClientId)) {
            $connectParams['ClientId'] = $script:CustomClientId
        }
        if (-not [string]::IsNullOrWhiteSpace($script:CustomTenantId)) {
            $connectParams['TenantId'] = $script:CustomTenantId
        }

        Connect-MgGraph @connectParams | Out-Null
        $WarningPreference = 'Continue'

        if (-not [string]::IsNullOrWhiteSpace($script:CustomClientId)) {
            Write-ColorOutput "✓ Successfully connected using custom app registration" "Green"
        } else {
            Write-ColorOutput "✓ Successfully connected to Microsoft Graph" "Green"
        }
        return $true
    }
    catch {
        $WarningPreference = 'Continue'
        Write-ColorOutput "✗ Failed to connect to Microsoft Graph: $($_.Exception.Message)" "Red"
        return $false
    }
}
