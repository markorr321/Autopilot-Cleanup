#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, Microsoft.Graph.Identity.DirectoryManagement

<#
.SYNOPSIS
    Identifies and removes devices that are in Windows Autopilot but not enrolled in Microsoft Intune.

.DESCRIPTION
    This PowerShell script provides an interactive interface to identify and clean up orphaned Autopilot devices
    that are not present in Intune management.
    
    Features:
    - Automatic validation and installation of required Microsoft Graph PowerShell modules
    - Bulk retrieval of all Autopilot, Intune, and Entra ID devices using efficient pagination
    - Fast HashSet-based lookups to identify devices in Autopilot but not in Intune
    - Interactive grid view for device selection with detailed device information
    - Removes selected devices from Autopilot
    - Validates serial numbers to prevent accidental deletion of duplicate device names
    - Real-time monitoring of deletion progress with automatic verification
    - Handles edge cases like pending deletions, duplicates, and missing devices
    - Audio notification when device removal is confirmed
    - Supports WhatIf mode for safe testing without actual deletions
    
    Module Installation:
    The script automatically checks for required Microsoft Graph modules and prompts to install any missing dependencies.
    Installation uses CurrentUser scope to avoid requiring administrator privileges.
    
    Required Permissions:
    - DeviceManagementManagedDevices.ReadWrite.All
    - DeviceManagementServiceConfig.ReadWrite.All

.PARAMETER WhatIf
    Preview mode that shows what would be deleted without performing actual deletions

.EXAMPLE
    .\Autopilot-Devices-Not-In-Intune.ps1
    Runs the script in normal mode, allowing selection and deletion of orphaned Autopilot devices.

.EXAMPLE
    .\Autopilot-Devices-Not-In-Intune.ps1 -WhatIf
    Runs the script in preview mode to see what would be deleted without making changes.

.NOTES
    Author: Mark Orr
    Date: December 2024
    Version: 2.0
    Requires: Microsoft Graph PowerShell SDK modules
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

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Helper function to safely convert date strings to DateTime objects
function ConvertTo-SafeDateTime {
    param(
        [Parameter(Mandatory = $false)]
        [string]$dateString
    )
    
    if ([string]::IsNullOrWhiteSpace($dateString)) {
        return $null
    }
    
    # Define supported date formats
    $formats = @(
        "yyyy-MM-ddTHH:mm:ssZ",
        "yyyy-MM-ddTHH:mm:ss.fffffffZ",
        "yyyy-MM-ddTHH:mm:ss",
        "MM/dd/yyyy HH:mm:ss",
        "dd/MM/yyyy HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "M/d/yyyy h:mm:ss tt",
        "M/d/yyyy H:mm:ss"
    )
    
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    
    # Try each format
    foreach ($format in $formats) {
        try {
            $parsedDate = [DateTime]::ParseExact($dateString, $format, $culture, [System.Globalization.DateTimeStyles]::None)
            # Check for DateTime.MinValue (1/1/0001)
            if ($parsedDate -eq [DateTime]::MinValue) {
                return $null
            }
            return $parsedDate
        }
        catch {
            # Continue to next format
            continue
        }
    }
    
    # Try default parse as last resort with InvariantCulture
    try {
        $parsedDate = [DateTime]::Parse($dateString, $culture)
        if ($parsedDate -eq [DateTime]::MinValue) {
            return $null
        }
        return $parsedDate
    }
    catch {
        Write-Warning "Failed to parse date: $dateString"
        return $null
    }
}

function Get-GraphPagedResults {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )
    
    $results = @()
    $nextLink = $Uri
    
    do {
        try {
            $response = Invoke-MgGraphRequest -Uri $nextLink -Method GET
            if ($response.value) {
                $results += $response.value
            }
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Error in pagination: $_"
            break
        }
    } while ($nextLink)
    
    return $results
}

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

function Get-AutopilotNotIntuneDevices {
    try {
        # Get all Autopilot devices
        Write-ColorOutput "Fetching Autopilot devices..." "Cyan"
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities"
        $script:autopilotDevicesRaw = Get-GraphPagedResults -Uri $uri
        Write-ColorOutput "Found $($script:autopilotDevicesRaw.Count) Autopilot devices" "Green"

        # Get all Intune devices
        Write-ColorOutput "Fetching Intune devices..." "Cyan"
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices"
        $intuneDevices = Get-GraphPagedResults -Uri $uri
        Write-ColorOutput "Found $($intuneDevices.Count) Intune devices" "Green"
        
        # Get all Entra ID devices
        Write-ColorOutput "Fetching Entra ID devices..." "Cyan"
        $uri = "https://graph.microsoft.com/v1.0/devices"
        $script:allEntraDevices = Get-GraphPagedResults -Uri $uri
        Write-ColorOutput "Found $($script:allEntraDevices.Count) Entra ID devices" "Green"

        # Create a HashSet of Intune serial numbers for efficient lookup
        $intuneSerialNumbers = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($device in $intuneDevices) {
            if ($device.serialNumber) {
                $intuneSerialNumbers.Add($device.serialNumber) | Out-Null
            }
        }
        
        # Create hashtable for Entra devices by name for efficient lookup
        $script:entraByName = @{}
        foreach ($device in $script:allEntraDevices) {
            if ($device.displayName) {
                if (-not $script:entraByName.ContainsKey($device.displayName)) {
                    $script:entraByName[$device.displayName] = @()
                }
                $script:entraByName[$device.displayName] += $device
            }
        }

        # Find devices in Autopilot but not in Intune using efficient HashSet lookup
        $notEnrolledDevices = $script:autopilotDevicesRaw | Where-Object {
            -not $intuneSerialNumbers.Contains($_.serialNumber)
        } | ForEach-Object {
            [PSCustomObject]@{
                SerialNumber = $_.serialNumber
                Model = $_.model
                Manufacturer = $_.manufacturer
                GroupTag = if ($_.groupTag) { $_.groupTag } else { "None" }
                DeploymentProfile = if ($_.deploymentProfileAssignmentStatus) { $_.deploymentProfileAssignmentStatus } else { "None" }
                AutopilotId = $_.id
                _DisplayName = $_.displayName
                EntraDeviceId = if ($script:entraByName.ContainsKey($_.displayName)) { ($script:entraByName[$_.displayName] | Select-Object -First 1).id } else { "Not Found" }
            }
        }

        Write-ColorOutput "Found $($notEnrolledDevices.Count) devices in Autopilot that are not enrolled in Intune" "Yellow"
        return $notEnrolledDevices
    }
    catch {
        Write-Error "Error executing playbook: $_"
        return $null
    }
}

# Main execution
Clear-Host
Write-ColorOutput "=================================================" "Magenta"
Write-ColorOutput "  Autopilot Devices Not In Intune - Cleanup Tool" "Magenta"
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
Write-ColorOutput ""

# Execute the playbook and return results
$results = Get-AutopilotNotIntuneDevices

if (-not $results -or $results.Count -eq 0) {
    Write-ColorOutput "No devices found in Autopilot that are not in Intune." "Yellow"
    Write-Host "No devices found in Autopilot that are not in Intune." -ForegroundColor Yellow
    exit 0
}

# Show interactive grid for device selection
$selectedDevices = $results | Select-Object SerialNumber, Model, Manufacturer, GroupTag, DeploymentProfile, EntraDeviceId | Out-GridView -Title "Select Devices to Remove from Autopilot (Not in Intune)" -PassThru

if (-not $selectedDevices -or $selectedDevices.Count -eq 0) {
    Write-ColorOutput "No devices selected. Exiting." "Yellow"
    exit 0
}

Write-ColorOutput ""
Write-ColorOutput "Selected $($selectedDevices.Count) device(s) for removal:" "Cyan"
$selectedDevices | ForEach-Object {
    Write-ColorOutput "  - Serial: $($_.SerialNumber)" "White"
}

if ($WhatIf) {
    Write-ColorOutput ""
    Write-ColorOutput "Mode: WHATIF (No actual deletions will be performed)" "Yellow"
}

# Process each selected device
$deviceResults = @()
foreach ($selectedDevice in $selectedDevices) {
    # Find the full device info from results
    $fullDevice = $results | Where-Object { $_.SerialNumber -eq $selectedDevice.SerialNumber }
    $deviceName = $fullDevice._DisplayName
    $serialNumber = $fullDevice.SerialNumber
    $autopilotId = $fullDevice.AutopilotId
    
    Write-ColorOutput ""
    Write-ColorOutput "Processing: Serial $serialNumber" "Cyan"
    Write-ColorOutput "═══════════════════════════════════════════════════" "White"
    
    $deviceResult = [PSCustomObject]@{
        SerialNumber = $serialNumber
        DisplayName = $deviceName
        AutopilotId = $autopilotId
        Autopilot = @{ Found = $false; Success = $false; Error = $null }
    }
    
    # Remove from Autopilot first
    $autopilotResult = Remove-AutopilotDevice -DeviceName $deviceName -SerialNumber $serialNumber
    $deviceResult.Autopilot.Found = $autopilotResult.Found
    $deviceResult.Autopilot.Success = $autopilotResult.Success
    $deviceResult.Autopilot.Error = $autopilotResult.Error
    
    # Automatic monitoring after deletion (not in WhatIf mode)
    if (-not $WhatIf -and $deviceResult.Autopilot.Success) {
        Write-ColorOutput ""
        Write-ColorOutput "Monitoring device removal..." "Cyan"
        
        $startTime = Get-Date
        $maxMonitorMinutes = 30 # Maximum monitoring time
        $endTime = $startTime.AddMinutes($maxMonitorMinutes)
        $checkInterval = 5 # seconds
        
        $autopilotRemoved = -not $deviceResult.Autopilot.Success
        
        do {
            Start-Sleep -Seconds $checkInterval
            
            # Set monitoring mode to suppress verbose messages
            $script:MonitoringMode = $true
            
            $currentTime = Get-Date
            $elapsedMinutes = [math]::Round(($currentTime - $startTime).TotalMinutes, 1)
            
            # Check Autopilot status
            if (-not $autopilotRemoved) {
                Write-ColorOutput "Waiting for device to be removed from Autopilot (Elapsed: $elapsedMinutes min)" "Yellow"
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
            
            # Exit if Autopilot removal is confirmed
            if ($autopilotRemoved) {
                $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
                
                Write-ColorOutput ""
                Write-ColorOutput "Device Serial Number: $serialNumber" "White"
                Write-ColorOutput "Autopilot ID: $autopilotId" "White"
                Write-ColorOutput "Removed from Autopilot" "Green"
                
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
            Write-ColorOutput "Device may still be present in some services" "Yellow"
        }
    }
    
    $deviceResults += $deviceResult
}

Write-ColorOutput ""
Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
Write-ColorOutput "Removal process complete for $($deviceResults.Count) device(s)" "Green"
Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
