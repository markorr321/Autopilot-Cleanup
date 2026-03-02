<#
.SYNOPSIS
    Bulk removal tool for devices from Windows Autopilot, Microsoft Intune, and Microsoft Entra ID

.DESCRIPTION
    Wrapper script that imports the AutopilotCleanup module and runs the interactive cleanup process.

    Features:
    - Automatic validation and installation of required Microsoft Graph PowerShell modules
    - Retrieves all Windows Autopilot devices and enriches data with Intune and Entra ID information
    - Interactive grid view for device selection
    - Removes selected devices from all three services (Intune, Autopilot, and Entra ID)
    - Validates serial numbers to prevent accidental deletion of duplicate device names
    - Real-time monitoring of deletion progress with automatic verification
    - Handles edge cases like pending deletions, duplicates, and missing devices
    - Supports WhatIf mode for safe testing without actual deletions

    Required Permissions:
    - Device.ReadWrite.All
    - DeviceManagementManagedDevices.ReadWrite.All
    - DeviceManagementServiceConfig.ReadWrite.All

.PARAMETER WhatIf
    Preview mode that shows what would be deleted without performing actual deletions

.NOTES
    Author: Mark Orr
    Requires: Microsoft Graph PowerShell SDK modules
    Version: 2.0
#>

param(
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(HelpMessage = "Client ID of the app registration to use for delegated auth")]
    [string]$ClientId,

    [Parameter(HelpMessage = "Tenant ID to use with the specified app registration")]
    [string]$TenantId
)

# Import the module from the adjacent directory
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'AutopilotCleanup'
Import-Module $modulePath -Force

# Build parameters to forward
$invokeParams = @{}
if ($WhatIf) { $invokeParams['WhatIf'] = $true }
if ($ClientId) { $invokeParams['ClientId'] = $ClientId }
if ($TenantId) { $invokeParams['TenantId'] = $TenantId }

# Run the main cleanup function
Invoke-AutopilotCleanup @invokeParams
