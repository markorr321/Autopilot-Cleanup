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
        "DeviceManagementManagedDevices.PrivilegedOperations.All",
        "DeviceManagementServiceConfig.ReadWrite.All"
    )
    
    try {
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
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
            if (-not $script:MonitoringMode) {
                Write-ColorOutput "  - Entra ID (not found)" "Yellow"
            }
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
        Write-ColorOutput "  - Autopilot (not found)" "Yellow"
        return @{ Success = $false; Found = $false; Error = "Device not found" }
    }
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($AutopilotDevice.id)"
        
        if ($WhatIf) {
            Write-ColorOutput "WHATIF: Would remove Autopilot device: $($AutopilotDevice.displayName) (Serial: $($AutopilotDevice.serialNumber))" "Yellow"
            return @{ Success = $true; Found = $true; Error = $null }
        } else {
            Invoke-MgGraphRequest -Uri $uri -Method DELETE
            Write-ColorOutput "  ✓ Autopilot" "Green"
            return @{ Success = $true; Found = $true; Error = $null }
        }
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
            
        }
        catch {
            Write-ColorOutput "Error searching Intune by serial number: $($_.Exception.Message)" "Yellow"
        }
    }
    
    return $IntuneDevice
}

# Function to wipe device via Intune
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

# Function to sync device (force check-in)
function Invoke-IntuneDeviceSync {
    param([string]$ManagedDeviceId)
    
    try {
        Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$ManagedDeviceId/syncDevice" -Method POST
        return $true
    }
    catch { return $false }
}

# Function to wait for wipe completion
function Wait-ForDeviceWipe {
    param(
        [string]$ManagedDeviceId,
        [string]$DeviceName,
        [int]$TimeoutMinutes = 30,
        [int]$PollIntervalSeconds = 30
    )
    
    $timeoutSeconds = $TimeoutMinutes * 60
    $startTime = Get-Date
    
    while ($true) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        if ($elapsed -ge $timeoutSeconds) {
            Write-ColorOutput "✗ TIMEOUT - Wipe did not complete within $TimeoutMinutes minutes" "Red"
            return $false
        }
        
        $device = Get-IntuneDevice -DeviceName $DeviceName
        $timestamp = Get-Date -Format "HH:mm:ss"
        $elapsedFormatted = [math]::Round($elapsed, 0)
        
        if ($null -eq $device) {
            Write-ColorOutput "[$timestamp] ✓ Device removed from Intune (wipe complete)" "Green"
            return $true
        }
        
        $state = $device.managementState
        switch ($state) {
            "wipePending" { Write-ColorOutput "[$timestamp] IN PROGRESS - Wipe pending ($elapsedFormatted`s)" "Yellow" }
            "retirePending" { Write-ColorOutput "[$timestamp] IN PROGRESS - Retire pending ($elapsedFormatted`s)" "Yellow" }
            default { Write-ColorOutput "[$timestamp] WAITING - State: $state ($elapsedFormatted`s)" "Gray" }
        }
        
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

# Function to remove device from Intune
function Remove-IntuneDevice {
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
        
        if ($WhatIf) {
            Write-ColorOutput "WHATIF: Would remove Intune device: $($IntuneDevice.deviceName) (Serial: $($IntuneDevice.serialNumber))" "Yellow"
            return @{ Success = $true; Found = $true; Error = $null }
        } else {
            Invoke-MgGraphRequest -Uri $uri -Method DELETE
            Write-ColorOutput "  ✓ Intune" "Green"
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
            if ($WhatIf) {
                Write-ColorOutput "WHATIF: Would remove Entra ID device: $($AADDevice.displayName) (ID: $($AADDevice.id), Serial: $deviceSerial)" "Yellow"
                $deletedCount++
            } else {
                Remove-MgDevice -DeviceId $AADDevice.id -ErrorAction Stop
                $deletedCount++
                Write-ColorOutput "  ✓ Entra ID" "Green"
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
Write-ColorOutput "    Intune and Autopilot Cleanup PS" "Magenta"
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
        EntraDeviceId = if ($entraDevice -and $entraDevice.deviceId) { $entraDevice.deviceId } elseif ($device.azureActiveDirectoryDeviceId) { $device.azureActiveDirectoryDeviceId } else { $null }
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

# Validate where each selected device exists before deletion
Write-ColorOutput ""
Write-ColorOutput "═══════════════════════════════════════════════════" "Cyan"
Write-ColorOutput "  Validating Selected Device(s)" "Cyan"
Write-ColorOutput "═══════════════════════════════════════════════════" "Cyan"
Write-ColorOutput ""

foreach ($selectedDevice in $selectedDevices) {
    $fullDevice = $enrichedDevices | Where-Object { $_.SerialNumber -eq $selectedDevice.SerialNumber }
    $deviceName = $fullDevice.DisplayName
    $serialNumber = $fullDevice.SerialNumber

    Write-ColorOutput "Searching with:" "Yellow"
    Write-ColorOutput "  Device Name:   $deviceName" "White"
    Write-ColorOutput "  Serial Number: $serialNumber" "White"
    Write-ColorOutput ""

    # Search Intune
    Write-ColorOutput "  Searching Intune..." "Gray"
    $intuneDevice = $null
    try {
        if ($serialNumber) {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$serialNumber'"
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($response.value -and $response.value.Count -gt 0) {
                $intuneDevice = $response.value | Select-Object -First 1
                Write-ColorOutput "    ✓ Found by serial number" "Green"
            }
        }
        if (-not $intuneDevice -and $deviceName) {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$deviceName'"
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($response.value -and $response.value.Count -gt 0) {
                $intuneDevice = $response.value | Select-Object -First 1
                Write-ColorOutput "    ✓ Found by device name" "Green"
            }
        }
        if (-not $intuneDevice) {
            Write-ColorOutput "    ✗ Not found" "Yellow"
        }
    }
    catch {
        Write-ColorOutput "    Error: $($_.Exception.Message)" "Red"
    }

    # Search Autopilot
    Write-ColorOutput "  Searching Autopilot..." "Gray"
    $autopilotDevice = $null
    try {
        if ($serialNumber) {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$serialNumber')"
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($response.value -and $response.value.Count -gt 0) {
                $autopilotDevice = $response.value | Where-Object { $_.serialNumber -eq $serialNumber } | Select-Object -First 1
                if ($autopilotDevice) {
                    Write-ColorOutput "    ✓ Found by serial number" "Green"
                }
            }
        }
        if (-not $autopilotDevice -and $deviceName) {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=displayName eq '$deviceName'"
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($response.value -and $response.value.Count -gt 0) {
                $autopilotDevice = $response.value | Select-Object -First 1
                Write-ColorOutput "    ✓ Found by device name" "Green"
            }
        }
        if (-not $autopilotDevice) {
            Write-ColorOutput "    ✗ Not found" "Yellow"
        }
    }
    catch {
        Write-ColorOutput "    Error: $($_.Exception.Message)" "Red"
    }

    # Search Entra ID
    Write-ColorOutput "  Searching Entra ID..." "Gray"
    $entraDevices = @()
    try {
        if ($deviceName) {
            $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'"
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($response.value -and $response.value.Count -gt 0) {
                $entraDevices = @($response.value)
                Write-ColorOutput "    ✓ Found $($response.value.Count) record(s) by device name" "Green"
            }
            else {
                Write-ColorOutput "    ✗ Not found" "Yellow"
            }
        }
        else {
            Write-ColorOutput "    ⚠ Skipped (device name required for Entra ID search)" "Yellow"
        }
    }
    catch {
        Write-ColorOutput "    Error: $($_.Exception.Message)" "Red"
    }

    # Display search results summary
    Write-ColorOutput ""
    Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
    Write-ColorOutput "  Search Results" "Magenta"
    Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
    Write-ColorOutput "  Searched Name:   $deviceName" "White"
    Write-ColorOutput "  Searched Serial: $serialNumber" "White"
    Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
    Write-ColorOutput ""

    # Autopilot info
    if ($autopilotDevice) {
        Write-ColorOutput "  Autopilot:  ✓ FOUND" "Green"
        Write-ColorOutput "              Name: $($autopilotDevice.displayName)" "White"
        Write-ColorOutput "              Serial: $($autopilotDevice.serialNumber)" "White"
        Write-ColorOutput "              Model: $($autopilotDevice.model)" "White"
    } else {
        Write-ColorOutput "  Autopilot:  ✗ NOT FOUND" "Yellow"
    }
    Write-ColorOutput ""

    # Intune info
    if ($intuneDevice) {
        Write-ColorOutput "  Intune:     ✓ FOUND" "Green"
        Write-ColorOutput "              Name: $($intuneDevice.deviceName)" "White"
        Write-ColorOutput "              Serial: $($intuneDevice.serialNumber)" "White"
        Write-ColorOutput "              OS: $($intuneDevice.operatingSystem)" "White"
    } else {
        Write-ColorOutput "  Intune:     ✗ NOT FOUND" "Yellow"
    }
    Write-ColorOutput ""

    # Entra info
    if ($entraDevices.Count -gt 0) {
        Write-ColorOutput "  Entra ID:   ✓ FOUND ($($entraDevices.Count) record(s))" "Green"
        foreach ($entraDevice in $entraDevices) {
            Write-ColorOutput "              Name: $($entraDevice.displayName)" "White"
            Write-ColorOutput "              Device ID: $($entraDevice.deviceId)" "White"
        }
    } else {
        Write-ColorOutput "  Entra ID:   ✗ NOT FOUND" "Yellow"
    }
    Write-ColorOutput ""
}

# Ask user if they want to wipe devices first
Write-ColorOutput ""
Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
Write-ColorOutput "  Selected $($selectedDevices.Count) device(s)" "Cyan"
Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
Write-ColorOutput ""
Write-ColorOutput "What action do you want to perform?" "Cyan"
Write-ColorOutput ""
Write-ColorOutput "  STANDARD (monitors removal status):" "White"
Write-ColorOutput "  [1] Remove records only" "White"
Write-ColorOutput "  [2] WIPE device(s) + remove all records" "Red"
Write-ColorOutput ""
Write-ColorOutput "  FAST (skips status checks, exports CSV):" "Green"
Write-ColorOutput "  [3] Remove records only" "Green"
Write-ColorOutput "  [4] WIPE device(s) + remove all records" "Red"
Write-ColorOutput ""
Write-ColorOutput "  [5] Cancel" "Gray"
Write-ColorOutput ""

$actionChoice = Read-Host "Enter your choice (1-5)"

# Initialize no-logging mode flag
$script:NoLoggingMode = $false

switch ($actionChoice) {
    "1" {
        $performWipe = $false
        Write-ColorOutput ""
        Write-ColorOutput "Mode: Remove records only" "Cyan"
    }
    "2" {
        $performWipe = $true
        Write-ColorOutput ""
        Write-ColorOutput "Mode: WIPE and remove records" "Yellow"
        Write-ColorOutput ""
        Write-ColorOutput "⚠️  WARNING: This will FACTORY RESET the selected device(s)!" "Red"
        $wipeConfirm = Read-Host "Type 'WIPE' to confirm"
        if ($wipeConfirm -ne 'WIPE') {
            Write-ColorOutput "Wipe cancelled. Exiting." "Yellow"
            exit 0
        }
    }
    "3" {
        $performWipe = $false
        $script:NoLoggingMode = $true
        Write-ColorOutput ""
        Write-ColorOutput "Mode: Remove records only - SKIP STATUS CHECKS" "Cyan"
        Write-ColorOutput "Status checks will be skipped. Commands will be sent and devices marked as processed." "Yellow"
    }
    "4" {
        $performWipe = $true
        $script:NoLoggingMode = $true
        Write-ColorOutput ""
        Write-ColorOutput "Mode: WIPE and remove records - SKIP STATUS CHECKS" "Yellow"
        Write-ColorOutput "Status checks will be skipped. Commands will be sent and devices marked as processed." "Yellow"
        Write-ColorOutput ""
        Write-ColorOutput "⚠️  WARNING: This will FACTORY RESET the selected device(s)!" "Red"
        $wipeConfirm = Read-Host "Type 'WIPE' to confirm"
        if ($wipeConfirm -ne 'WIPE') {
            Write-ColorOutput "Wipe cancelled. Exiting." "Yellow"
            exit 0
        }
    }
    "5" {
        Write-ColorOutput "Cancelled." "Yellow"
        exit 0
    }
    default {
        Write-ColorOutput "Invalid choice. Exiting." "Red"
        exit 1
    }
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
        Wiped = $false
    }
    
    Write-ColorOutput ""
    Write-ColorOutput "════════════════════════════════════════════════════════════" "Cyan"
    Write-ColorOutput "Processing: $deviceName (Serial: $serialNumber)" "Cyan"
    Write-ColorOutput "════════════════════════════════════════════════════════════" "Cyan"
    
    # WIPE device first if requested
    if ($performWipe -and -not $WhatIf) {
        $intuneDevice = Get-IntuneDevice -DeviceName $deviceName -SerialNumber $serialNumber
        
        if ($intuneDevice) {
            Write-ColorOutput ""
            Write-ColorOutput "Step 1: Wiping device..." "Yellow"
            
            $wipeResult = Invoke-IntuneDeviceWipe -ManagedDeviceId $intuneDevice.id
            
            if ($wipeResult) {
                Write-ColorOutput "✓ Wipe command sent" "Green"
                
                # In No Logging mode, skip waiting for wipe completion
                if ($script:NoLoggingMode) {
                    Write-ColorOutput "✓ Device processed for wipe (no status check)" "Cyan"
                    $deviceResult.Wiped = $true
                    $deviceResult.Intune.Success = $true
                    $deviceResult.Intune.Found = $true
                } else {
                    # Force sync
                    Write-ColorOutput "Sending sync to force check-in..." "Yellow"
                    if (Invoke-IntuneDeviceSync -ManagedDeviceId $intuneDevice.id) {
                        Write-ColorOutput "✓ Sync command sent" "Green"
                    }
                    
                    # Wait for wipe to complete
                    Write-ColorOutput ""
                    Write-ColorOutput "Step 2: Waiting for wipe to complete..." "Yellow"
                    $wipeComplete = Wait-ForDeviceWipe -ManagedDeviceId $intuneDevice.id -DeviceName $deviceName -TimeoutMinutes 30 -PollIntervalSeconds 30
                    
                    if ($wipeComplete) {
                        $deviceResult.Wiped = $true
                        $deviceResult.Intune.Success = $true
                        $deviceResult.Intune.Found = $true
                        Write-ColorOutput ""
                        Write-ColorOutput "Step 3: Removing remaining records..." "Yellow"
                    } else {
                        Write-ColorOutput "Wipe did not complete. Skipping record removal for this device." "Red"
                        $results += $deviceResult
                        continue
                    }
                }
            } else {
                Write-ColorOutput "Failed to send wipe command. Skipping this device." "Red"
                $results += $deviceResult
                continue
            }
        } else {
            Write-ColorOutput "Device not found in Intune. Proceeding with record removal only." "Yellow"
        }
    } elseif ($performWipe -and $WhatIf) {
        Write-ColorOutput "WHATIF: Would wipe device $deviceName" "Yellow"
    } else {
        Write-ColorOutput "Removing records for $deviceName..." "Cyan"
    }
    
    # Remove from Intune (skip if already removed by wipe)
    if (-not $deviceResult.Wiped) {
        $intuneResult = Remove-IntuneDevice -DeviceName $deviceName -SerialNumber $serialNumber
        $deviceResult.Intune.Found = $intuneResult.Found
        $deviceResult.Intune.Success = $intuneResult.Success
        $deviceResult.Intune.Error = $intuneResult.Error
    }
    
    # Remove from Autopilot
    $autopilotResult = Remove-AutopilotDevice -DeviceName $deviceName -SerialNumber $serialNumber
    $deviceResult.Autopilot.Found = $autopilotResult.Found
    $deviceResult.Autopilot.Success = $autopilotResult.Success
    $deviceResult.Autopilot.Error = $autopilotResult.Error
    
    # Remove from Entra ID
    $entraDevices = Get-EntraDeviceByName -DeviceName $deviceName -SerialNumber $serialNumber
    if ($entraDevices -and $entraDevices.Count -gt 0) {
        $deviceResult.EntraID.Found = $true
        $entraResult = Remove-EntraDevices -Devices $entraDevices -DeviceName $deviceName -SerialNumber $serialNumber
        $deviceResult.EntraID.Success = $entraResult.Success
        $deviceResult.EntraID.DeletedCount = $entraResult.DeletedCount
        $deviceResult.EntraID.FailedCount = $entraResult.FailedCount
        $deviceResult.EntraID.Errors = $entraResult.Errors
    }
    
    # In No Logging mode, just show processed message and skip monitoring
    if ($script:NoLoggingMode) {
        # Get device ID from the original device data
        $deviceId = "N/A"
        $fullDeviceData = $enrichedDevices | Where-Object { $_.SerialNumber -eq $serialNumber }
        if ($fullDeviceData -and $fullDeviceData.EntraDeviceId) {
            $deviceId = $fullDeviceData.EntraDeviceId
        }
        
        Write-ColorOutput ""
        Write-ColorOutput "════════════════════════════════════════════════════════════" "Cyan"
        Write-ColorOutput "  ✓ DEVICE PROCESSED FOR REMOVAL" "Cyan"
        Write-ColorOutput "════════════════════════════════════════════════════════════" "Cyan"
        Write-ColorOutput "  Name:           $deviceName" "White"
        Write-ColorOutput "  Serial Number:  $serialNumber" "White"
        Write-ColorOutput "  Device ID:      $deviceId" "White"
        Write-ColorOutput "════════════════════════════════════════════════════════════" "Cyan"
        Write-ColorOutput ""
        
        # Store device ID for CSV export
        $deviceResult | Add-Member -NotePropertyName "DeviceId" -NotePropertyValue $deviceId -Force
    }
    # Automatic monitoring after deletion (not in WhatIf mode and not in No Logging mode)
    elseif (-not $WhatIf -and ($deviceResult.Autopilot.Success -or $deviceResult.Intune.Success -or $deviceResult.EntraID.Success)) {
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
                
                # Get device ID from the original device data
                $deviceId = "N/A"
                $fullDeviceData = $enrichedDevices | Where-Object { $_.SerialNumber -eq $serialNumber }
                if ($fullDeviceData -and $fullDeviceData.EntraDeviceId) {
                    $deviceId = $fullDeviceData.EntraDeviceId
                }
                
                Write-ColorOutput ""
                Write-ColorOutput "════════════════════════════════════════════════════════════" "Green"
                Write-ColorOutput "  ✓ DEVICE SUCCESSFULLY REMOVED" "Green"
                Write-ColorOutput "════════════════════════════════════════════════════════════" "Green"
                Write-ColorOutput "  Name:           $deviceName" "White"
                Write-ColorOutput "  Serial Number:  $serialNumber" "White"
                Write-ColorOutput "  Device ID:      $deviceId" "White"
                Write-ColorOutput "  Elapsed Time:   $elapsedTime minutes" "White"
                Write-ColorOutput "════════════════════════════════════════════════════════════" "Green"
                Write-ColorOutput ""
                
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

# Export CSV for removals in No Logging mode
if ($script:NoLoggingMode -and $results.Count -gt 0) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $csvPath = Join-Path -Path $PSScriptRoot -ChildPath "DeviceRemoval_$timestamp.csv"
    
    # Build CSV export data
    $csvData = foreach ($result in $results) {
        # Get device ID from enriched data if not already stored
        $deviceId = $result.DeviceId
        if (-not $deviceId) {
            $fullDeviceData = $enrichedDevices | Where-Object { $_.SerialNumber -eq $result.SerialNumber }
            if ($fullDeviceData -and $fullDeviceData.EntraDeviceId) {
                $deviceId = $fullDeviceData.EntraDeviceId
            } else {
                $deviceId = "N/A"
            }
        }
        
        [PSCustomObject]@{
            "Device Display Name" = $result.DisplayName
            "Serial Number" = $result.SerialNumber
            "Device ID" = $deviceId
            "Wipe Sent" = if ($result.Wiped) { "Yes" } else { "No" }
            "Intune Removal Sent" = if ($result.Intune.Success) { "Yes" } else { "No" }
            "Autopilot Removal Sent" = if ($result.Autopilot.Success) { "Yes" } else { "No" }
            "Entra Removal Sent" = if ($result.EntraID.Success) { "Yes" } else { "No" }
            "Processed Time" = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    try {
        $csvData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-ColorOutput ""
        Write-ColorOutput "════════════════════════════════════════════════════════════" "Green"
        Write-ColorOutput "  CSV EXPORT COMPLETE" "Green"
        Write-ColorOutput "════════════════════════════════════════════════════════════" "Green"
        Write-ColorOutput "  File: $csvPath" "White"
        Write-ColorOutput "  Devices: $($results.Count)" "White"
        Write-ColorOutput "════════════════════════════════════════════════════════════" "Green"
    }
    catch {
        Write-ColorOutput "Failed to export CSV: $($_.Exception.Message)" "Red"
    }
}
