#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, Microsoft.Graph.Identity.DirectoryManagement

<#
.SYNOPSIS
    Bulk removal tool for devices from Windows Autopilot, Microsoft Intune, and Microsoft Entra ID

.DESCRIPTION
    This PowerShell script provides an interactive interface to manage device cleanup across Microsoft's endpoint management ecosystem.
    
    Features:
    - Automatic validation and installation of required Microsoft Graph PowerShell modules
    - Retrieves all Windows Autopilot devices and enriches data with Intune and Entra ID information
    - Interactive grid view for device selection
    - Removes selected devices from all three services (Intune, Autopilot, and Entra ID)
    - Validates serial numbers to prevent accidental deletion of duplicate device names
    - Real-time monitoring of deletion progress with automatic verification
    - Handles edge cases like pending deletions, duplicates, and missing devices
    - Supports WhatIf mode for safe testing without actual deletions
    
    Module Installation:
    The script automatically checks for required Microsoft Graph modules and prompts to install any missing dependencies.
    Installation uses CurrentUser scope to avoid requiring administrator privileges.
    
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
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

#region Module Validation
function Install-RequiredModules {
    param(
        [string[]]$ModuleNames
    )
    
    Write-Host "Checking required PowerShell modules..." -ForegroundColor Yellow
    
    $missingModules = @()
    
    foreach ($moduleName in $ModuleNames) {
        if (Get-Module -ListAvailable -Name $moduleName) {
            Write-Host "✓ Module '$moduleName' is already installed" -ForegroundColor Green
        } else {
            Write-Host "✗ Module '$moduleName' is not installed" -ForegroundColor Red
            $missingModules += $moduleName
        }
    }
    
    if ($missingModules.Count -gt 0) {
        Write-Host "" -ForegroundColor White
        Write-Host "The following modules need to be installed:" -ForegroundColor Yellow
        $missingModules | ForEach-Object { Write-Host "  - $_" -ForegroundColor Cyan }
        Write-Host "" -ForegroundColor White
        
        $install = Read-Host "Would you like to install missing modules? (Y/N)"
        
        if ($install -eq 'Y' -or $install -eq 'y') {
            foreach ($module in $missingModules) {
                try {
                    Write-Host "Installing module: $module..." -ForegroundColor Yellow
                    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                    Write-Host "✓ Successfully installed $module" -ForegroundColor Green
                }
                catch {
                    Write-Host "✗ Failed to install $module : $($_.Exception.Message)" -ForegroundColor Red
                    return $false
                }
            }
            Write-Host "" -ForegroundColor White
            Write-Host "All required modules have been installed successfully!" -ForegroundColor Green
            return $true
        }
        else {
            Write-Host "Cannot proceed without required modules. Exiting." -ForegroundColor Red
            return $false
        }
    }
    else {
        Write-Host "All required modules are installed." -ForegroundColor Green
        return $true
    }
}
#endregion Module Validation

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Function to check Graph connection
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

# Function to connect to Microsoft Graph
function Connect-ToGraph {
    Write-ColorOutput "Connecting to Microsoft Graph..." "Yellow"
    
    $requiredScopes = @(
        "Device.ReadWrite.All",
        "DeviceManagementManagedDevices.ReadWrite.All", 
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

# Function to get all Autopilot devices
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

# Function to get matching Entra ID device by device name with serial validation
function Get-EntraDeviceByName {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    
    if ([string]::IsNullOrWhiteSpace($DeviceName)) {
        return @()
    }
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$DeviceName'"
        $AADDevices = (Invoke-MgGraphRequest -Uri $uri -Method GET).value
        
        if (-not $AADDevices -or $AADDevices.Count -eq 0) {
            Write-ColorOutput "  $DeviceName not found in Entra ID" "Red"
            Write-ColorOutput ""
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

# Function to get paged results from Graph API
function Get-GraphPagedResults {
    param([string]$Uri)
    
    $allResults = @()
    $currentUri = $Uri
    
    do {
        try {
            $response = Invoke-MgGraphRequest -Uri $currentUri -Method GET
            if ($response.value) {
                $allResults += $response.value
            }
            $currentUri = $response.'@odata.nextLink'
        }
        catch {
            Write-ColorOutput "Error getting paged results: $($_.Exception.Message)" "Red"
            break
        }
    } while ($currentUri)
    
    return $allResults
}

# Function to get Autopilot device with advanced search
function Get-AutopilotDevice {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    
    $AutopilotDevice = $null
    
    # Try to find by serial number first if available
    if ($SerialNumber) {
        try {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$SerialNumber')"
            $AutopilotDevice = (Invoke-MgGraphRequest -Uri $uri -Method GET).value | Select-Object -First 1
            
            if ($AutopilotDevice) {
                # Only show message during initial search, not during monitoring
                if (-not $script:MonitoringMode) {
                    Write-ColorOutput "  Found Autopilot device: $($AutopilotDevice.displayName)" "Green"
                    Write-ColorOutput ""
                }
                return $AutopilotDevice
            } else {
                if (-not $script:MonitoringMode) {
                    Write-ColorOutput "Device with serial $SerialNumber not found in Autopilot" "Yellow"
                }
            }
        }
        catch {
            Write-ColorOutput "Error searching Autopilot by serial number: $($_.Exception.Message)" "Yellow"
        }
    }
    
    
    return $AutopilotDevice
}

# Function to remove device from Autopilot
function Remove-AutopilotDevice {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    
    $AutopilotDevice = Get-AutopilotDevice -DeviceName $DeviceName -SerialNumber $SerialNumber
    
    if (-not $AutopilotDevice) {
        $searchCriteria = if ($SerialNumber) { "serial $SerialNumber or name $DeviceName" } else { "name $DeviceName" }
        Write-ColorOutput "Device with $searchCriteria not found in Autopilot." "Yellow"
        return @{ Success = $false; Found = $false; Error = "Device not found" }
    }
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($AutopilotDevice.id)"
        
        if ($WhatIf) {
            Write-ColorOutput "WHATIF: Would remove Autopilot device: $($AutopilotDevice.displayName) (Serial: $($AutopilotDevice.serialNumber))" "Yellow"
            return @{ Success = $true; Found = $true; Error = $null }
        } else {
            Invoke-MgGraphRequest -Uri $uri -Method DELETE
            Write-ColorOutput "✓ Successfully queued device $DeviceName for removal from Autopilot" "Green"
            Write-ColorOutput ""
            return @{ Success = $true; Found = $true; Error = $null }
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        
        # Check for common deletion scenarios
        if ($errorMsg -like "*BadRequest*" -or $errorMsg -like "*Bad Request*") {
            if ($errorMsg -like "*already*" -or $errorMsg -like "*pending*") {
                Write-ColorOutput "⚠ Device $DeviceName already queued for deletion from Autopilot" "Yellow"
                return @{ Success = $true; Found = $true; Error = "Already queued for deletion" }
            } else {
                Write-ColorOutput "⚠ Device $DeviceName cannot be deleted from Autopilot (may already be processing)" "Yellow"
                Write-ColorOutput "  Error details: $errorMsg" "Gray"
                return @{ Success = $true; Found = $true; Error = "Cannot delete - likely already processing" }
            }
        }
        elseif ($errorMsg -like "*NotFound*" -or $errorMsg -like "*Not Found*") {
            Write-ColorOutput "⚠ Device $DeviceName no longer exists in Autopilot (already removed)" "Yellow"
            return @{ Success = $true; Found = $true; Error = "Already removed" }
        }
        else {
            Write-ColorOutput "✗ Error removing device $DeviceName from Autopilot: $errorMsg" "Red"
            return @{ Success = $false; Found = $true; Error = $errorMsg }
        }
    }
}

# Function to get Intune device with enhanced search
function Get-IntuneDevice {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    
    $IntuneDevice = $null
    
    # Try by device name first if available
    if ($DeviceName) {
        try {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$DeviceName'"
            $IntuneDevice = (Invoke-MgGraphRequest -Uri $uri -Method GET).value | Select-Object -First 1
            
            if ($IntuneDevice) {
                if (-not $script:MonitoringMode) {
                    Write-ColorOutput "  Found Intune device: $($IntuneDevice.deviceName)" "Green"
                    Write-ColorOutput ""
                }
                return $IntuneDevice
            }
        }
        catch {
            Write-ColorOutput "Error searching Intune by device name: $($_.Exception.Message)" "Yellow"
        }
    }
    
    # If not found by name and we have serial number, try by serial
    if (-not $IntuneDevice -and $SerialNumber) {
        try {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$SerialNumber'"
            $IntuneDevice = (Invoke-MgGraphRequest -Uri $uri -Method GET).value | Select-Object -First 1
            
            if ($IntuneDevice) {
                if (-not $script:MonitoringMode) {
                    Write-ColorOutput "Found Intune device by serial number: $($IntuneDevice.deviceName)" "Green"
                }
            }
        }
        catch {
            Write-ColorOutput "Error searching Intune by serial number: $($_.Exception.Message)" "Yellow"
        }
    }
    
    return $IntuneDevice
}

# Function to remove device from Intune
function Remove-IntuneDevice {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    
    $IntuneDevice = Get-IntuneDevice -DeviceName $DeviceName -SerialNumber $SerialNumber
    
    if (-not $IntuneDevice) {
        Write-ColorOutput "  $DeviceName not found in Intune" "Red"
        Write-ColorOutput ""
        return @{ Success = $false; Found = $false; Error = "Device not found" }
    }
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($IntuneDevice.id)"
        
        if ($WhatIf) {
            Write-ColorOutput "WHATIF: Would remove Intune device: $($IntuneDevice.deviceName) (Serial: $($IntuneDevice.serialNumber))" "Yellow"
            return @{ Success = $true; Found = $true; Error = $null }
        } else {
            Invoke-MgGraphRequest -Uri $uri -Method DELETE
            Write-ColorOutput "✓ Successfully queued device $DeviceName for removal from Intune" "Green"
            Write-ColorOutput ""
            return @{ Success = $true; Found = $true; Error = $null }
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        Write-ColorOutput "✗ Error removing device $DeviceName from Intune: $errorMsg" "Red"
        return @{ Success = $false; Found = $true; Error = $errorMsg }
    }
}

# Function to verify device removal from Intune
function Test-IntuneDeviceRemoved {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null,
        [int]$MaxWaitMinutes = 10
    )
    
    $startTime = Get-Date
    $endTime = $startTime.AddMinutes($MaxWaitMinutes)
    $checkInterval = 30 # seconds
    
    Write-ColorOutput "Verifying device removal from Intune (max wait: $MaxWaitMinutes minutes)..." "Yellow"
    
    do {
        Start-Sleep -Seconds $checkInterval
        $device = Get-IntuneDevice -DeviceName $DeviceName -SerialNumber $SerialNumber
        
        if (-not $device) {
            $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
            Write-ColorOutput "✓ Device confirmed removed from Intune after $elapsedTime minutes" "Green"
            return $true
        }
        
        $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        Write-ColorOutput "Device still present in Intune after $elapsedTime minutes..." "Yellow"
        
    } while ((Get-Date) -lt $endTime)
    
    Write-ColorOutput "⚠ Device still present in Intune after $MaxWaitMinutes minutes" "Red"
    return $false
}

# Function to remove multiple Entra ID devices with enhanced error handling
function Remove-EntraDevices {
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
            $uri = "https://graph.microsoft.com/v1.0/devices/$($AADDevice.id)"
            
            if ($WhatIf) {
                Write-ColorOutput "WHATIF: Would remove Entra ID device: $($AADDevice.displayName) (ID: $($AADDevice.id), Serial: $deviceSerial)" "Yellow"
                $deletedCount++
            } else {
                Invoke-MgGraphRequest -Uri $uri -Method DELETE
                $deletedCount++
                Write-ColorOutput "✓ Successfully queued device $DeviceName for removal from Entra ID" "Green"
                Write-ColorOutput ""
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

# Main execution
Clear-Host
Write-ColorOutput "=================================================" "Magenta"
Write-ColorOutput "    Intune and Autopilot Offboarding PS1" "Magenta"
Write-ColorOutput "=================================================" "Magenta"

if ($WhatIf) {
    Write-ColorOutput "Mode: WHATIF (No actual deletions will be performed)" "Yellow"
}
Write-ColorOutput ""

# Define required modules
$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.DeviceManagement',
    'Microsoft.Graph.Identity.DirectoryManagement'
)

# Check and install required modules
if (-not (Install-RequiredModules -ModuleNames $requiredModules)) {
    Write-ColorOutput "Failed to install required modules. Exiting." "Red"
    exit 1
}
Write-ColorOutput ""

# Check if already connected to Graph
if (-not (Test-GraphConnection)) {
    if (-not (Connect-ToGraph)) {
        Write-ColorOutput "Failed to connect to Microsoft Graph. Exiting." "Red"
        exit 1
    }
}

# Bulk fetch all devices from all services
Write-ColorOutput "Fetching all Autopilot devices..." "Yellow"
$autopilotDevices = Get-GraphPagedResults -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities"
Write-ColorOutput "Found $($autopilotDevices.Count) Autopilot devices" "Green"

if ($autopilotDevices.Count -eq 0) {
    Write-ColorOutput "No Autopilot devices found. Exiting." "Red"
    exit 0
}

Write-ColorOutput "Fetching all Intune devices..." "Yellow"
$allIntuneDevices = Get-GraphPagedResults -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices"
Write-ColorOutput "Found $($allIntuneDevices.Count) Intune devices" "Green"

Write-ColorOutput "Fetching all Entra ID devices..." "Yellow"
$allEntraDevices = Get-GraphPagedResults -Uri "https://graph.microsoft.com/v1.0/devices"
Write-ColorOutput "Found $($allEntraDevices.Count) Entra ID devices" "Green"

# Create HashSets/Hashtables for fast lookups
$intuneBySerial = @{}
$intuneByName = @{}
foreach ($device in $allIntuneDevices) {
    if ($device.serialNumber) {
        $intuneBySerial[$device.serialNumber] = $device
    }
    if ($device.deviceName) {
        $intuneByName[$device.deviceName] = $device
    }
}

$entraByName = @{}
foreach ($device in $allEntraDevices) {
    if ($device.displayName) {
        if (-not $entraByName.ContainsKey($device.displayName)) {
            $entraByName[$device.displayName] = @()
        }
        $entraByName[$device.displayName] += $device
    }
}

Write-ColorOutput ""
Write-ColorOutput "Enriching device information..." "Cyan"
$enrichedDevices = foreach ($device in $autopilotDevices) {
    # Fast local lookup instead of API calls
    $intuneDevice = $null
    if ($device.serialNumber -and $intuneBySerial.ContainsKey($device.serialNumber)) {
        $intuneDevice = $intuneBySerial[$device.serialNumber]
    } elseif ($device.displayName -and $intuneByName.ContainsKey($device.displayName)) {
        $intuneDevice = $intuneByName[$device.displayName]
    }
    
    $entraDevice = $null
    if ($device.displayName -and $entraByName.ContainsKey($device.displayName)) {
        $entraDevice = $entraByName[$device.displayName] | Select-Object -First 1
    }
    
    # Create a meaningful display name
    $displayName = if ($device.displayName -and $device.displayName -ne "") { 
        $device.displayName 
    } elseif ($intuneDevice -and $intuneDevice.deviceName) { 
        $intuneDevice.deviceName 
    } elseif ($entraDevice -and $entraDevice.displayName) { 
        $entraDevice.displayName 
    } elseif ($device.serialNumber) { 
        "Device-$($device.serialNumber)" 
    } else { 
        "Unknown-$($device.id.Substring(0,8))" 
    }
    
    [PSCustomObject]@{
        AutopilotId = $device.id
        DisplayName = $displayName
        SerialNumber = $device.serialNumber
        Model = $device.model
        Manufacturer = $device.manufacturer
        GroupTag = if ($device.groupTag) { $device.groupTag } else { "None" }
        DeploymentProfile = if ($device.deploymentProfileAssignmentStatus) { $device.deploymentProfileAssignmentStatus } else { "None" }
        IntuneFound = if ($intuneDevice) { "Yes" } else { "No" }
        IntuneId = if ($intuneDevice) { $intuneDevice.id } else { $null }
        IntuneName = if ($intuneDevice) { $intuneDevice.deviceName } else { "N/A" }
        EntraFound = if ($entraDevice) { "Yes" } else { "No" }
        EntraId = if ($entraDevice) { $entraDevice.id } else { $null }
        EntraName = if ($entraDevice) { $entraDevice.displayName } else { "N/A" }
        # Store original objects for deletion
        _AutopilotDevice = $device
        _IntuneDevice = $intuneDevice
        _EntraDevice = $entraDevice
    }
}

# Show interactive grid for device selection
$selectedDevices = $enrichedDevices | Select-Object DisplayName, SerialNumber, Model, Manufacturer, GroupTag, DeploymentProfile, IntuneFound, EntraFound, IntuneName, EntraName | Out-GridView -Title "Select Devices to Remove from All Services" -PassThru

if (-not $selectedDevices -or $selectedDevices.Count -eq 0) {
    Write-ColorOutput "No devices selected. Exiting." "Yellow"
    exit 0
}

# Process each selected device
$results = @()
foreach ($selectedDevice in $selectedDevices) {
    # Find the full device info
    $fullDevice = $enrichedDevices | Where-Object { $_.SerialNumber -eq $selectedDevice.SerialNumber }
    $deviceName = $fullDevice.DisplayName
    $serialNumber = $fullDevice.SerialNumber
    
    $deviceResult = [PSCustomObject]@{
        SerialNumber = $serialNumber
        DisplayName = $deviceName
        EntraID = @{ Found = $false; Success = $false; DeletedCount = 0; FailedCount = 0; Errors = @() }
        Intune = @{ Found = $false; Success = $false; Error = $null }
        Autopilot = @{ Found = $false; Success = $false; Error = $null }
    }
    
    # Remove from Intune first (management layer)
    $intuneResult = Remove-IntuneDevice -DeviceName $deviceName -SerialNumber $serialNumber
    $deviceResult.Intune.Found = $intuneResult.Found
    $deviceResult.Intune.Success = $intuneResult.Success
    $deviceResult.Intune.Error = $intuneResult.Error
    
    # Remove from Autopilot second (deployment service)
    $autopilotResult = Remove-AutopilotDevice -DeviceName $deviceName -SerialNumber $serialNumber
    $deviceResult.Autopilot.Found = $autopilotResult.Found
    $deviceResult.Autopilot.Success = $autopilotResult.Success
    $deviceResult.Autopilot.Error = $autopilotResult.Error
    
    # Remove from Entra ID last (identity source)
    $entraDevices = Get-EntraDeviceByName -DeviceName $deviceName -SerialNumber $serialNumber
    if ($entraDevices -and $entraDevices.Count -gt 0) {
        $deviceResult.EntraID.Found = $true
        $entraResult = Remove-EntraDevices -Devices $entraDevices -DeviceName $deviceName -SerialNumber $serialNumber
        $deviceResult.EntraID.Success = $entraResult.Success
        $deviceResult.EntraID.DeletedCount = $entraResult.DeletedCount
        $deviceResult.EntraID.FailedCount = $entraResult.FailedCount
        $deviceResult.EntraID.Errors = $entraResult.Errors
    }
    
    # Automatic monitoring after deletion (not in WhatIf mode)
    if (-not $WhatIf -and ($deviceResult.Autopilot.Success -or $deviceResult.Intune.Success -or $deviceResult.EntraID.Success)) {
        Write-ColorOutput ""
        Write-ColorOutput "Monitoring device removal..." "Cyan"
        
        $startTime = Get-Date
        $maxMonitorMinutes = 30 # Maximum monitoring time
        $endTime = $startTime.AddMinutes($maxMonitorMinutes)
        $checkInterval = 5 # seconds
        
        $autopilotRemoved = -not $deviceResult.Autopilot.Success
        $intuneRemoved = -not $deviceResult.Intune.Success
        $entraRemoved = -not $deviceResult.EntraID.Success
        
        
        do {
            Start-Sleep -Seconds $checkInterval
            
            # Set monitoring mode to suppress verbose messages
            $script:MonitoringMode = $true
            
            $currentTime = Get-Date
            $elapsedMinutes = [math]::Round(($currentTime - $startTime).TotalMinutes, 1)
            
            # Check Intune status first
            if (-not $intuneRemoved) {
                Write-ColorOutput "Waiting for 1 of 1 to be removed from Intune (Elapsed: $elapsedMinutes min)" "Yellow"
                try {
                    $intuneDevice = Get-IntuneDevice -DeviceName $deviceName -SerialNumber $serialNumber
                    if (-not $intuneDevice) {
                        $intuneRemoved = $true
                        Write-ColorOutput "✓ Device removed from Intune" "Green"
                        $deviceResult.Intune.Verified = $true
                    }
                }
                catch {
                    Write-ColorOutput "  Error checking Intune: $($_.Exception.Message)" "Red"
                }
            }
            
            # Check Autopilot status (only after Intune is removed)
            if ($intuneRemoved -and -not $autopilotRemoved) {
                Write-ColorOutput "Waiting for 1 of 1 to be removed from Autopilot (Elapsed: $elapsedMinutes min)" "Yellow"
                try {
                    $autopilotDevice = Get-AutopilotDevice -DeviceName $deviceName -SerialNumber $serialNumber
                    if (-not $autopilotDevice) {
                        $autopilotRemoved = $true
                        Write-ColorOutput "✓ Device removed from Autopilot" "Green"
                        $deviceResult.Autopilot.Verified = $true
                    }
                }
                catch {
                    Write-ColorOutput "  Error checking Autopilot: $($_.Exception.Message)" "Red"
                }
            }
            
            # Check Entra ID status (after both Intune and Autopilot are removed)
            if ($autopilotRemoved -and $intuneRemoved -and -not $entraRemoved) {
                Write-ColorOutput "Waiting for 1 of 1 to be removed from Entra ID (Elapsed: $elapsedMinutes min)" "Yellow"
                try {
                    $entraDevices = Get-EntraDeviceByName -DeviceName $deviceName -SerialNumber $serialNumber
                    if (-not $entraDevices -or $entraDevices.Count -eq 0) {
                        $entraRemoved = $true
                        Write-ColorOutput "✓ Device removed from Entra ID" "Green"
                        $deviceResult.EntraID.Verified = $true
                    }
                }
                catch {
                    Write-ColorOutput "  Error checking Entra ID: $($_.Exception.Message)" "Red"
                }
            }
            
            
            # Exit if all services are cleared
            if ($autopilotRemoved -and $intuneRemoved -and $entraRemoved) {
                $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
                
                # Get device object ID from the original device data
                $deviceObjectId = "N/A"
                $fullDeviceData = $enrichedDevices | Where-Object { $_.SerialNumber -eq $serialNumber }
                if ($fullDeviceData -and $fullDeviceData.EntraId) {
                    $deviceObjectId = $fullDeviceData.EntraId
                } elseif ($fullDeviceData -and $fullDeviceData.IntuneId) {
                    $deviceObjectId = $fullDeviceData.IntuneId
                } elseif ($fullDeviceData -and $fullDeviceData.AutopilotId) {
                    $deviceObjectId = $fullDeviceData.AutopilotId
                }
                
                Write-ColorOutput "Device Serial Number: $serialNumber" "White"
                Write-ColorOutput "Device Object ID: $deviceObjectId" "White"
                Write-ColorOutput ""
                Write-ColorOutput "Removed from Autopilot, Intune, and Entra ID" "Green"
                
                # Play success notification
                try {
                    [System.Console]::Beep(800, 300)
                    [System.Console]::Beep(1000, 300)
                    [System.Console]::Beep(1200, 500)
                } catch { }
                
                break
            }
            
        } while ((Get-Date) -lt $endTime)
        
        # Reset monitoring mode
        $script:MonitoringMode = $false
        
        # Check for timeout
        if ((Get-Date) -ge $endTime) {
            Write-ColorOutput ""
            Write-ColorOutput "⚠ Monitoring timeout reached after $maxMonitorMinutes minutes" "Red"
            Write-ColorOutput "Some devices may still be present in the services" "Yellow"
        }
    }
    
    $results += $deviceResult
}

