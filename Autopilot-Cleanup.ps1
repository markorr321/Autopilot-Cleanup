#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement

<#
.SYNOPSIS
    Search for and optionally delete Autopilot devices by DisplayName, DeviceId, or ObjectId.

.DESCRIPTION
    This script allows you to search for Autopilot devices using various identifiers
    and optionally delete them after confirmation.

.PARAMETER DisplayName
    Search for Autopilot devices by display name (partial match supported)

.PARAMETER DeviceId
    Search for Autopilot devices by Azure AD Device ID (exact match)

.PARAMETER ObjectId
    Search for Autopilot devices by Autopilot Object ID (exact match)

.PARAMETER WhatIf
    Preview mode - shows what would be deleted without performing actual deletions

.EXAMPLE
    .\Find-AutopilotDevice.ps1 -DisplayName "PC-NAME"
    Search for devices with "PC-NAME" in the display name

.EXAMPLE
    .\Find-AutopilotDevice.ps1 -DeviceId "12345678-1234-1234-1234-123456789abc"
    Search for device by Entra Device ID

.EXAMPLE
    .\Find-AutopilotDevice.ps1 -DisplayName "PC-NAME" -WhatIf
    Preview what would be deleted

.NOTES
    Author: Mark Orr
    Date: December 14th 2025
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$DisplayName,
    
    [Parameter(Mandatory=$false)]
    [string]$DeviceId,
    
    [Parameter(Mandatory=$false)]
    [string]$ObjectId,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Test-GraphConnection {
    try {
        $context = Get-MgContext
        if ($null -eq $context) {
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}

function Connect-ToGraph {
    Write-ColorOutput "Connecting to Microsoft Graph..." "Yellow"
    
    $requiredScopes = @(
        "DeviceManagementServiceConfig.ReadWrite.All"
    )
    
    try {
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
        Write-ColorOutput "✓ Successfully connected to Microsoft Graph" "Green"
        return $true
    }
    catch {
        Write-ColorOutput "✗ Failed to connect to Microsoft Graph: $($_.Exception.Message)" "Red"
        return $false
    }
}

# Main execution
Clear-Host
Write-ColorOutput "=================================================" "Magenta"
Write-ColorOutput "  Find Autopilot Device" "Magenta"
Write-ColorOutput "=================================================" "Magenta"
Write-ColorOutput ""

# If no parameters provided, show interactive menu
if (-not $DisplayName -and -not $DeviceId -and -not $ObjectId) {
    Write-ColorOutput "Where do you want to search?" "Cyan"
    Write-ColorOutput ""
    Write-ColorOutput "  [1] Search Autopilot by Display Name" "White"
    Write-ColorOutput "  [2] Search Autopilot by Entra Device ID" "White"
    Write-ColorOutput "  [3] Search Autopilot by Autopilot Object ID" "White"
    Write-ColorOutput "  [4] Search Entra ID by Display Name" "Yellow"
    Write-ColorOutput "  [5] Search Entra ID by Device ID" "Yellow"
    Write-ColorOutput "  [6] Search Entra ID by Object ID" "Yellow"
    Write-ColorOutput "  [7] Exit" "White"
    Write-ColorOutput ""
    
    $choice = Read-Host "Enter your choice (1-7)"
    
    switch ($choice) {
        "1" {
            $DisplayName = Read-Host "Enter Display Name (partial match supported)"
            if ([string]::IsNullOrWhiteSpace($DisplayName)) {
                Write-ColorOutput "No display name entered. Exiting." "Yellow"
                exit 0
            }
            $script:SearchTarget = "Autopilot"
        }
        "2" {
            $DeviceId = Read-Host "Enter Entra Device ID (GUID)"
            if ([string]::IsNullOrWhiteSpace($DeviceId)) {
                Write-ColorOutput "No device ID entered. Exiting." "Yellow"
                exit 0
            }
            $script:SearchTarget = "Autopilot"
        }
        "3" {
            $ObjectId = Read-Host "Enter Autopilot Object ID (GUID)"
            if ([string]::IsNullOrWhiteSpace($ObjectId)) {
                Write-ColorOutput "No object ID entered. Exiting." "Yellow"
                exit 0
            }
            $script:SearchTarget = "Autopilot"
        }
        "4" {
            $DisplayName = Read-Host "Enter Display Name"
            if ([string]::IsNullOrWhiteSpace($DisplayName)) {
                Write-ColorOutput "No display name entered. Exiting." "Yellow"
                exit 0
            }
            $script:SearchTarget = "Entra"
        }
        "5" {
            $DeviceId = Read-Host "Enter Entra Device ID (GUID)"
            if ([string]::IsNullOrWhiteSpace($DeviceId)) {
                Write-ColorOutput "No device ID entered. Exiting." "Yellow"
                exit 0
            }
            $script:SearchTarget = "Entra"
        }
        "6" {
            $ObjectId = Read-Host "Enter Entra Object ID (GUID)"
            if ([string]::IsNullOrWhiteSpace($ObjectId)) {
                Write-ColorOutput "No object ID entered. Exiting." "Yellow"
                exit 0
            }
            $script:SearchTarget = "Entra"
        }
        "7" {
            Write-ColorOutput "Exiting." "Yellow"
            exit 0
        }
        default {
            Write-ColorOutput "Invalid choice. Exiting." "Red"
            exit 1
        }
    }
    Write-ColorOutput ""
} else {
    $script:SearchTarget = "Autopilot"
}

if ($WhatIf) {
    Write-ColorOutput "Mode: WHATIF (No actual deletions will be performed)" "Yellow"
    Write-ColorOutput ""
}

# Check if already connected to Graph
if (-not (Test-GraphConnection)) {
    if (-not (Connect-ToGraph)) {
        Write-ColorOutput "Failed to connect to Microsoft Graph. Exiting." "Red"
        exit 1
    }
}
Write-ColorOutput ""

# Search based on target (Autopilot or Entra)
if ($script:SearchTarget -eq "Entra") {
    Write-ColorOutput "Searching Entra ID..." "Cyan"
    Write-ColorOutput ""
    
    $foundDevices = @()
    
    # Search Entra by DisplayName
    if ($DisplayName) {
        Write-ColorOutput "Searching by DisplayName: $DisplayName" "Yellow"
        $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$DisplayName'"
        try {
            $results = (Invoke-MgGraphRequest -Uri $uri -Method GET).value
            if ($results) {
                $foundDevices += $results
                Write-ColorOutput "  Found $($results.Count) device(s) by DisplayName" "Green"
            } else {
                Write-ColorOutput "  No devices found by DisplayName" "Yellow"
            }
        } catch {
            Write-ColorOutput "  Error searching by DisplayName: $($_.Exception.Message)" "Red"
        }
    }
    
    # Search Entra by DeviceId
    if ($DeviceId) {
        Write-ColorOutput "Searching by DeviceId: $DeviceId" "Yellow"
        $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$DeviceId'"
        try {
            $results = (Invoke-MgGraphRequest -Uri $uri -Method GET).value
            if ($results) {
                $foundDevices += $results
                Write-ColorOutput "  Found $($results.Count) device(s) by DeviceId" "Green"
            } else {
                Write-ColorOutput "  No devices found by DeviceId" "Yellow"
            }
        } catch {
            Write-ColorOutput "  Error searching by DeviceId: $($_.Exception.Message)" "Red"
        }
    }
    
    # Search Entra by ObjectId
    if ($ObjectId) {
        Write-ColorOutput "Searching by ObjectId: $ObjectId" "Yellow"
        $uri = "https://graph.microsoft.com/v1.0/devices/$ObjectId"
        try {
            $result = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($result) {
                $foundDevices += $result
                Write-ColorOutput "  Found device by ObjectId" "Green"
            }
        } catch {
            Write-ColorOutput "  No device found by ObjectId" "Yellow"
        }
    }
    
    # Remove duplicates by id
    $uniqueDevices = $foundDevices | Sort-Object -Property id -Unique
    
    if ($uniqueDevices.Count -eq 0) {
        Write-ColorOutput ""
        Write-ColorOutput "No Entra ID devices found matching the criteria." "Red"
        exit 0
    }
    
    Write-ColorOutput ""
    Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
    Write-ColorOutput "Found $($uniqueDevices.Count) Entra ID device(s):" "Cyan"
    Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
    
    foreach ($device in $uniqueDevices) {
        Write-ColorOutput ""
        Write-ColorOutput "  Display Name:      $($device.displayName)" "White"
        Write-ColorOutput "  Device ID:         $($device.deviceId)" "White"
        Write-ColorOutput "  Object ID:         $($device.id)" "White"
        Write-ColorOutput "  OS:                $($device.operatingSystem)" "White"
        Write-ColorOutput "  OS Version:        $($device.operatingSystemVersion)" "White"
        Write-ColorOutput "  Trust Type:        $($device.trustType)" "White"
        Write-ColorOutput "  Is Managed:        $($device.isManaged)" "White"
        Write-ColorOutput "  Registration Time: $($device.registrationDateTime)" "Gray"
    }
    
    Write-ColorOutput ""
    Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
    
    if ($WhatIf) {
        Write-ColorOutput ""
        Write-ColorOutput "WHATIF: Would delete the above device(s) from Entra ID" "Yellow"
        exit 0
    }
    
    # Confirm deletion
    Write-ColorOutput ""
    $confirm = Read-Host "Do you want to DELETE these device(s) from Entra ID? (Y/N)"
    
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-ColorOutput "Deletion cancelled." "Yellow"
        exit 0
    }
    
    # Delete each device
    foreach ($device in $uniqueDevices) {
        Write-ColorOutput ""
        Write-ColorOutput "Deleting: $($device.displayName) (ID: $($device.id))" "Cyan"
        try {
            $deleteUri = "https://graph.microsoft.com/v1.0/devices/$($device.id)"
            Invoke-MgGraphRequest -Uri $deleteUri -Method DELETE
            Write-ColorOutput "✓ Successfully deleted from Entra ID" "Green"
        } catch {
            Write-ColorOutput "✗ Error: $($_.Exception.Message)" "Red"
        }
    }
    
    Write-ColorOutput ""
    Write-ColorOutput "Deletion complete." "Green"
    
} else {
    # Search Autopilot
    Write-ColorOutput "Searching Autopilot..." "Cyan"
    Write-ColorOutput ""
    
    $foundDevices = @()
    
    # Search by DisplayName
    if ($DisplayName) {
        Write-ColorOutput "Searching by DisplayName: $DisplayName" "Yellow"
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(displayName,'$DisplayName')"
        try {
            $results = (Invoke-MgGraphRequest -Uri $uri -Method GET).value
            if ($results) {
                $foundDevices += $results
                Write-ColorOutput "  Found $($results.Count) device(s) by DisplayName" "Green"
            } else {
                Write-ColorOutput "  No devices found by DisplayName" "Yellow"
            }
        } catch {
            Write-ColorOutput "  Error searching by DisplayName: $($_.Exception.Message)" "Red"
        }
    }
    
    # Search by DeviceId (azureActiveDirectoryDeviceId)
    if ($DeviceId) {
        Write-ColorOutput "Searching by DeviceId: $DeviceId" "Yellow"
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=azureActiveDirectoryDeviceId eq '$DeviceId'"
        try {
            $results = (Invoke-MgGraphRequest -Uri $uri -Method GET).value
            if ($results) {
                $foundDevices += $results
                Write-ColorOutput "  Found $($results.Count) device(s) by DeviceId" "Green"
            } else {
                Write-ColorOutput "  No devices found by DeviceId" "Yellow"
            }
        } catch {
            Write-ColorOutput "  Error searching by DeviceId: $($_.Exception.Message)" "Red"
        }
    }
    
    # Search by ObjectId (Autopilot id)
    if ($ObjectId) {
        Write-ColorOutput "Searching by ObjectId: $ObjectId" "Yellow"
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$ObjectId"
        try {
            $result = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($result) {
                $foundDevices += $result
                Write-ColorOutput "  Found device by ObjectId" "Green"
            }
        } catch {
            Write-ColorOutput "  No device found by ObjectId" "Yellow"
        }
    }
    
    # Remove duplicates by id
    $uniqueDevices = $foundDevices | Sort-Object -Property id -Unique
    
    if ($uniqueDevices.Count -eq 0) {
        Write-ColorOutput ""
        Write-ColorOutput "No Autopilot devices found matching the criteria." "Red"
        exit 0
    }
    
    Write-ColorOutput ""
    Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
    Write-ColorOutput "Found $($uniqueDevices.Count) Autopilot device(s):" "Cyan"
    Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
    
    foreach ($device in $uniqueDevices) {
        Write-ColorOutput ""
        Write-ColorOutput "  Display Name:    $($device.displayName)" "White"
        Write-ColorOutput "  Serial Number:   $($device.serialNumber)" "White"
        Write-ColorOutput "  Model:           $($device.model)" "White"
        Write-ColorOutput "  Manufacturer:    $($device.manufacturer)" "White"
        Write-ColorOutput "  Group Tag:       $($device.groupTag)" "White"
        Write-ColorOutput "  Autopilot ID:    $($device.id)" "Gray"
        Write-ColorOutput "  AAD Device ID:   $($device.azureActiveDirectoryDeviceId)" "Gray"
    }
    
    Write-ColorOutput ""
    Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
    
    if ($WhatIf) {
        Write-ColorOutput ""
        Write-ColorOutput "WHATIF: Would delete the above device(s) from Autopilot" "Yellow"
        exit 0
    }
    
    # Confirm deletion
    Write-ColorOutput ""
    $confirm = Read-Host "Do you want to DELETE these device(s) from Autopilot? (Y/N)"
    
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-ColorOutput "Deletion cancelled." "Yellow"
        exit 0
    }
    
    # Delete each device
    foreach ($device in $uniqueDevices) {
        Write-ColorOutput ""
        Write-ColorOutput "Deleting: $($device.displayName) (Serial: $($device.serialNumber))" "Cyan"
        try {
            $deleteUri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($device.id)"
            Invoke-MgGraphRequest -Uri $deleteUri -Method DELETE
            Write-ColorOutput "✓ Successfully queued for deletion" "Green"
        } catch {
            Write-ColorOutput "✗ Error: $($_.Exception.Message)" "Red"
        }
    }
    
    Write-ColorOutput ""
    Write-ColorOutput "Deletion complete." "Green"
}
