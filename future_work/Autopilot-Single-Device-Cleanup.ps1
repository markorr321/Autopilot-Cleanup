#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, Microsoft.Graph.Identity.DirectoryManagement

<#
.SYNOPSIS
    Ad-hoc device deletion tool

.DESCRIPTION
    This PowerShell script allows you to delete a device from Microsoft Entra ID, Intune, 
    and/or Autopilot by entering the device name and/or serial number.
    
    You can provide:
    - Just the device name (works best for Entra ID, can work for Intune/Autopilot)
    - Just the serial number (works best for Autopilot/Intune)
    - Both (recommended for best results across all platforms)
    
    Features:
    - Flexible search using whatever identifiers you have
    - Choose to delete from one platform or all platforms
    - Monitors removal status after deletion
    - No wipe functionality - record deletion only
    
    Required Permissions:
    - Device.ReadWrite.All
    - DeviceManagementManagedDevices.ReadWrite.All
    - DeviceManagementServiceConfig.ReadWrite.All

.PARAMETER DeviceName
    Optional. The display name of the device.

.PARAMETER SerialNumber
    Optional. The serial number of the device.

.PARAMETER WhatIf
    Preview mode that shows what would be deleted without performing actual deletions

.NOTES
    Author: Mark Orr
    Version: 2.0
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$DeviceName,
    
    [Parameter(Mandatory=$false)]
    [string]$SerialNumber,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

#region Helper Functions
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Install-RequiredModules {
    param([string[]]$ModuleNames)
    
    Write-ColorOutput "Checking required PowerShell modules..." "Yellow"
    
    $missingModules = @()
    
    foreach ($moduleName in $ModuleNames) {
        if (Get-Module -ListAvailable -Name $moduleName) {
            Write-ColorOutput "✓ Module '$moduleName' is already installed" "Green"
        } else {
            Write-ColorOutput "✗ Module '$moduleName' is not installed" "Red"
            $missingModules += $moduleName
        }
    }
    
    if ($missingModules.Count -gt 0) {
        Write-ColorOutput ""
        Write-ColorOutput "The following modules need to be installed:" "Yellow"
        $missingModules | ForEach-Object { Write-ColorOutput "  - $_" "Cyan" }
        Write-ColorOutput ""
        
        $install = Read-Host "Would you like to install missing modules? (Y/N)"
        
        if ($install -eq 'Y' -or $install -eq 'y') {
            foreach ($module in $missingModules) {
                try {
                    Write-ColorOutput "Installing module: $module..." "Yellow"
                    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                    Write-ColorOutput "✓ Successfully installed $module" "Green"
                }
                catch {
                    Write-ColorOutput "✗ Failed to install $module : $($_.Exception.Message)" "Red"
                    return $false
                }
            }
            return $true
        }
        else {
            Write-ColorOutput "Cannot proceed without required modules. Exiting." "Red"
            return $false
        }
    }
    return $true
}

function Test-GraphConnection {
    try {
        $context = Get-MgContext
        return ($null -ne $context)
    }
    catch {
        return $false
    }
}

function Connect-ToGraph {
    Write-ColorOutput "Connecting to Microsoft Graph..." "Yellow"
    
    $requiredScopes = @(
        "Device.ReadWrite.All",
        "DeviceManagementManagedDevices.ReadWrite.All",
        "DeviceManagementServiceConfig.ReadWrite.All"
    )
    
    try {
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome -WarningAction SilentlyContinue | Out-Null
        Write-ColorOutput "✓ Successfully connected to Microsoft Graph" "Green"
        return $true
    }
    catch {
        Write-ColorOutput "✗ Failed to connect to Microsoft Graph: $($_.Exception.Message)" "Red"
        return $false
    }
}
#endregion Helper Functions

#region Device Lookup Functions
function Get-DeviceFromAllPlatforms {
    param(
        [string]$Name,
        [string]$Serial
    )
    
    $result = @{
        Autopilot = $null
        Intune = $null
        Entra = @()
    }
    
    # Search Intune
    Write-ColorOutput "  Searching Intune..." "Gray"
    try {
        # Try serial first if available
        if ($Serial) {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$Serial'"
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($response.value -and $response.value.Count -gt 0) {
                $result.Intune = $response.value | Select-Object -First 1
                Write-ColorOutput "    ✓ Found by serial number" "Green"
            }
        }
        
        # Try name if not found by serial (or if serial wasn't provided)
        if (-not $result.Intune -and $Name) {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$Name'"
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($response.value -and $response.value.Count -gt 0) {
                $result.Intune = $response.value | Select-Object -First 1
                Write-ColorOutput "    ✓ Found by device name" "Green"
            }
        }
        
        if (-not $result.Intune) {
            Write-ColorOutput "    ✗ Not found" "Yellow"
        }
    }
    catch {
        Write-ColorOutput "    Error: $($_.Exception.Message)" "Red"
    }
    
    # Search Autopilot
    Write-ColorOutput "  Searching Autopilot..." "Gray"
    try {
        # Try serial first if available (best method for Autopilot)
        if ($Serial) {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$Serial')"
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($response.value -and $response.value.Count -gt 0) {
                $result.Autopilot = $response.value | Where-Object { $_.serialNumber -eq $Serial } | Select-Object -First 1
                if ($result.Autopilot) {
                    Write-ColorOutput "    ✓ Found by serial number" "Green"
                }
            }
        }
        
        # Try display name if not found by serial
        if (-not $result.Autopilot -and $Name) {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=displayName eq '$Name'"
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($response.value -and $response.value.Count -gt 0) {
                $result.Autopilot = $response.value | Select-Object -First 1
                Write-ColorOutput "    ✓ Found by device name" "Green"
            }
        }
        
        if (-not $result.Autopilot) {
            Write-ColorOutput "    ✗ Not found" "Yellow"
        }
    }
    catch {
        Write-ColorOutput "    Error: $($_.Exception.Message)" "Red"
    }
    
    # Search Entra ID (device name is the only reliable method)
    Write-ColorOutput "  Searching Entra ID..." "Gray"
    try {
        if ($Name) {
            $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$Name'"
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($response.value -and $response.value.Count -gt 0) {
                $result.Entra = @($response.value)
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
    
    return $result
}
#endregion Device Lookup Functions

#region Deletion Functions
function Remove-FromAutopilot {
    param(
        [object]$Device,
        [switch]$WhatIfMode
    )
    
    if (-not $Device) {
        Write-ColorOutput "  ✗ Autopilot: Device not found" "Yellow"
        return @{ Success = $false; Found = $false }
    }
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($Device.id)"
        
        if ($WhatIfMode) {
            Write-ColorOutput "  WHATIF: Would remove from Autopilot: $($Device.displayName) (Serial: $($Device.serialNumber))" "Yellow"
            return @{ Success = $true; Found = $true }
        }
        
        Invoke-MgGraphRequest -Uri $uri -Method DELETE
        Write-ColorOutput "  ✓ Autopilot: Deleted successfully" "Green"
        return @{ Success = $true; Found = $true }
    }
    catch {
        $errorMsg = $_.Exception.Message
        if ($errorMsg -like "*NotFound*" -or $errorMsg -like "*Not Found*") {
            Write-ColorOutput "  ⚠ Autopilot: Already removed" "Yellow"
            return @{ Success = $true; Found = $true }
        }
        elseif ($errorMsg -like "*BadRequest*" -or $errorMsg -like "*pending*") {
            Write-ColorOutput "  ⚠ Autopilot: Already queued for deletion" "Yellow"
            return @{ Success = $true; Found = $true }
        }
        Write-ColorOutput "  ✗ Autopilot: Error - $errorMsg" "Red"
        return @{ Success = $false; Found = $true }
    }
}

function Remove-FromIntune {
    param(
        [object]$Device,
        [switch]$WhatIfMode
    )
    
    if (-not $Device) {
        Write-ColorOutput "  ✗ Intune: Device not found" "Yellow"
        return @{ Success = $false; Found = $false }
    }
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($Device.id)"
        
        if ($WhatIfMode) {
            Write-ColorOutput "  WHATIF: Would remove from Intune: $($Device.deviceName) (Serial: $($Device.serialNumber))" "Yellow"
            return @{ Success = $true; Found = $true }
        }
        
        Invoke-MgGraphRequest -Uri $uri -Method DELETE
        Write-ColorOutput "  ✓ Intune: Deleted successfully" "Green"
        return @{ Success = $true; Found = $true }
    }
    catch {
        $errorMsg = $_.Exception.Message
        if ($errorMsg -like "*NotFound*" -or $errorMsg -like "*Not Found*") {
            Write-ColorOutput "  ⚠ Intune: Already removed" "Yellow"
            return @{ Success = $true; Found = $true }
        }
        Write-ColorOutput "  ✗ Intune: Error - $errorMsg" "Red"
        return @{ Success = $false; Found = $true }
    }
}

function Remove-FromEntra {
    param(
        [array]$Devices,
        [switch]$WhatIfMode
    )
    
    if (-not $Devices -or $Devices.Count -eq 0) {
        Write-ColorOutput "  ✗ Entra ID: Device not found" "Yellow"
        return @{ Success = $false; Found = $false; DeletedCount = 0 }
    }
    
    $deletedCount = 0
    $failedCount = 0
    
    foreach ($device in $Devices) {
        try {
            $uri = "https://graph.microsoft.com/v1.0/devices/$($device.id)"
            
            if ($WhatIfMode) {
                Write-ColorOutput "  WHATIF: Would remove from Entra ID: $($device.displayName) (ID: $($device.id))" "Yellow"
                $deletedCount++
                continue
            }
            
            Invoke-MgGraphRequest -Uri $uri -Method DELETE
            $deletedCount++
        }
        catch {
            $failedCount++
            Write-ColorOutput "  ✗ Entra ID: Error deleting $($device.displayName) - $($_.Exception.Message)" "Red"
        }
    }
    
    if ($deletedCount -gt 0 -and $failedCount -eq 0) {
        Write-ColorOutput "  ✓ Entra ID: Deleted $deletedCount device(s) successfully" "Green"
        return @{ Success = $true; Found = $true; DeletedCount = $deletedCount }
    }
    elseif ($deletedCount -gt 0) {
        Write-ColorOutput "  ⚠ Entra ID: Deleted $deletedCount, failed $failedCount" "Yellow"
        return @{ Success = $true; Found = $true; DeletedCount = $deletedCount }
    }
    
    return @{ Success = $false; Found = $true; DeletedCount = 0 }
}
#endregion Deletion Functions

#region Verification Functions
function Test-DeviceStillExists {
    param(
        [string]$Name,
        [string]$Serial,
        [ValidateSet("Intune", "Autopilot", "Entra")]
        [string]$Platform
    )
    
    switch ($Platform) {
        "Intune" {
            try {
                if ($Serial) {
                    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$Serial'"
                    $response = Invoke-MgGraphRequest -Uri $uri -Method GET
                    if ($response.value -and $response.value.Count -gt 0) { return $true }
                }
                if ($Name) {
                    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$Name'"
                    $response = Invoke-MgGraphRequest -Uri $uri -Method GET
                    if ($response.value -and $response.value.Count -gt 0) { return $true }
                }
                return $false
            }
            catch { return $false }
        }
        "Autopilot" {
            try {
                if ($Serial) {
                    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$Serial')"
                    $response = Invoke-MgGraphRequest -Uri $uri -Method GET
                    $device = $response.value | Where-Object { $_.serialNumber -eq $Serial }
                    if ($device) { return $true }
                }
                if ($Name) {
                    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=displayName eq '$Name'"
                    $response = Invoke-MgGraphRequest -Uri $uri -Method GET
                    if ($response.value -and $response.value.Count -gt 0) { return $true }
                }
                return $false
            }
            catch { return $false }
        }
        "Entra" {
            if (-not $Name) { return $false }
            try {
                $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$Name'"
                $response = Invoke-MgGraphRequest -Uri $uri -Method GET
                return ($response.value -and $response.value.Count -gt 0)
            }
            catch { return $false }
        }
    }
    return $false
}

function Wait-ForRemoval {
    param(
        [string]$Name,
        [string]$Serial,
        [array]$Platforms,
        [int]$MaxWaitMinutes = 10,
        [int]$CheckIntervalSeconds = 5
    )
    
    Write-ColorOutput ""
    Write-ColorOutput "Monitoring removal status..." "Cyan"
    
    $startTime = Get-Date
    $endTime = $startTime.AddMinutes($MaxWaitMinutes)
    
    # Track what still needs to be verified
    $pending = @{}
    foreach ($platform in $Platforms) {
        $pending[$platform] = $true
    }
    
    while ($pending.Count -gt 0 -and (Get-Date) -lt $endTime) {
        Start-Sleep -Seconds $CheckIntervalSeconds
        
        $elapsedMinutes = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        
        foreach ($platform in @($pending.Keys)) {
            $stillExists = Test-DeviceStillExists -Name $Name -Serial $Serial -Platform $platform
            
            if (-not $stillExists) {
                Write-ColorOutput "  ✓ Verified: Device removed from $platform" "Green"
                $pending.Remove($platform)
            }
            else {
                Write-ColorOutput "  ⏳ Waiting: $platform removal pending... ($elapsedMinutes min)" "Yellow"
            }
        }
    }
    
    # Final status
    Write-ColorOutput ""
    if ($pending.Count -eq 0) {
        Write-ColorOutput "═══════════════════════════════════════════════════" "Green"
        Write-ColorOutput "  ✓ DEVICE SUCCESSFULLY REMOVED" "Green"
        Write-ColorOutput "═══════════════════════════════════════════════════" "Green"
        if ($Name) { Write-ColorOutput "  Device Name:   $Name" "White" }
        if ($Serial) { Write-ColorOutput "  Serial Number: $Serial" "White" }
        Write-ColorOutput "  Elapsed Time:  $([math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)) minutes" "White"
        Write-ColorOutput "═══════════════════════════════════════════════════" "Green"
        
        # Play success sound
        try {
            (New-Object Media.SoundPlayer "C:\Windows\Media\Alarm01.wav").PlaySync()
        } catch { }
        
        return $true
    }
    else {
        Write-ColorOutput "═══════════════════════════════════════════════════" "Yellow"
        Write-ColorOutput "  ⚠ TIMEOUT - Some platforms may still be processing" "Yellow"
        Write-ColorOutput "═══════════════════════════════════════════════════" "Yellow"
        Write-ColorOutput "  Still pending: $($pending.Keys -join ', ')" "White"
        Write-ColorOutput "═══════════════════════════════════════════════════" "Yellow"
        return $false
    }
}
#endregion Verification Functions

#region Main Menu
function Show-Menu {
    Write-ColorOutput ""
    Write-ColorOutput "═══════════════════════════════════════════════════" "Cyan"
    Write-ColorOutput "  What would you like to do?" "Cyan"
    Write-ColorOutput "═══════════════════════════════════════════════════" "Cyan"
    Write-ColorOutput ""
    Write-ColorOutput "  [1] Delete from Entra ID only" "White"
    Write-ColorOutput "  [2] Delete from Intune only" "White"
    Write-ColorOutput "  [3] Delete from Autopilot only" "White"
    Write-ColorOutput "  [4] Delete from ALL platforms" "Yellow"
    Write-ColorOutput ""
    Write-ColorOutput "  [5] Search for another device" "Gray"
    Write-ColorOutput "  [6] Exit" "Gray"
    Write-ColorOutput ""
    
    return Read-Host "Enter your choice (1-6)"
}

function Show-DeviceInfo {
    param(
        [string]$Name,
        [string]$Serial,
        [object]$DeviceData
    )
    
    Write-ColorOutput ""
    Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
    Write-ColorOutput "  Search Results" "Magenta"
    Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
    if ($Name) { Write-ColorOutput "  Searched Name:   $Name" "White" }
    if ($Serial) { Write-ColorOutput "  Searched Serial: $Serial" "White" }
    Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
    Write-ColorOutput ""
    
    # Autopilot info
    if ($DeviceData.Autopilot) {
        Write-ColorOutput "  Autopilot:  ✓ FOUND" "Green"
        Write-ColorOutput "              Name: $($DeviceData.Autopilot.displayName)" "White"
        Write-ColorOutput "              Serial: $($DeviceData.Autopilot.serialNumber)" "White"
        Write-ColorOutput "              Model: $($DeviceData.Autopilot.model)" "White"
        if ($DeviceData.Autopilot.groupTag) {
            Write-ColorOutput "              Group Tag: $($DeviceData.Autopilot.groupTag)" "White"
        }
    } else {
        Write-ColorOutput "  Autopilot:  ✗ NOT FOUND" "Yellow"
    }
    
    Write-ColorOutput ""
    
    # Intune info
    if ($DeviceData.Intune) {
        Write-ColorOutput "  Intune:     ✓ FOUND" "Green"
        Write-ColorOutput "              Name: $($DeviceData.Intune.deviceName)" "White"
        Write-ColorOutput "              Serial: $($DeviceData.Intune.serialNumber)" "White"
        Write-ColorOutput "              OS: $($DeviceData.Intune.operatingSystem)" "White"
        Write-ColorOutput "              Last Sync: $($DeviceData.Intune.lastSyncDateTime)" "White"
    } else {
        Write-ColorOutput "  Intune:     ✗ NOT FOUND" "Yellow"
    }
    
    Write-ColorOutput ""
    
    # Entra info
    if ($DeviceData.Entra -and $DeviceData.Entra.Count -gt 0) {
        Write-ColorOutput "  Entra ID:   ✓ FOUND ($($DeviceData.Entra.Count) record(s))" "Green"
        foreach ($entraDevice in $DeviceData.Entra) {
            Write-ColorOutput "              Name: $($entraDevice.displayName)" "White"
            Write-ColorOutput "              Device ID: $($entraDevice.deviceId)" "White"
        }
    } else {
        Write-ColorOutput "  Entra ID:   ✗ NOT FOUND" "Yellow"
    }
    
    Write-ColorOutput ""
}
#endregion Main Menu

#region Main Execution
Clear-Host
Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
Write-ColorOutput "    Device Cleanup Tool - Ad Hoc Deletion" "Magenta"
Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"

if ($WhatIf) {
    Write-ColorOutput "Mode: WHATIF (No actual deletions)" "Yellow"
}
Write-ColorOutput ""

# Check and install required modules
$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.DeviceManagement',
    'Microsoft.Graph.Identity.DirectoryManagement'
)

if (-not (Install-RequiredModules -ModuleNames $requiredModules)) {
    exit 1
}
Write-ColorOutput ""

# Connect to Graph
if (-not (Test-GraphConnection)) {
    if (-not (Connect-ToGraph)) {
        exit 1
    }
}
Write-ColorOutput ""

# Main loop
$continue = $true
while ($continue) {
    # Get device identifiers
    if (-not $DeviceName -and -not $SerialNumber) {
        Write-ColorOutput "═══════════════════════════════════════════════════" "Cyan"
        Write-ColorOutput "  Enter device identifier(s)" "Cyan"
        Write-ColorOutput "  (Provide at least one - press Enter to skip)" "Gray"
        Write-ColorOutput "═══════════════════════════════════════════════════" "Cyan"
        Write-ColorOutput ""
        $DeviceName = Read-Host "Device Name (best for Entra ID)"
        $SerialNumber = Read-Host "Serial Number (best for Autopilot)"
    }
    
    # Trim whitespace
    $DeviceName = if ($DeviceName) { $DeviceName.Trim() } else { $null }
    $SerialNumber = if ($SerialNumber) { $SerialNumber.Trim() } else { $null }
    
    # Convert empty strings to null
    if ([string]::IsNullOrWhiteSpace($DeviceName)) { $DeviceName = $null }
    if ([string]::IsNullOrWhiteSpace($SerialNumber)) { $SerialNumber = $null }
    
    # Validate at least one is provided
    if (-not $DeviceName -and -not $SerialNumber) {
        Write-ColorOutput ""
        Write-ColorOutput "✗ You must provide at least one identifier (device name or serial number)." "Red"
        Write-ColorOutput ""
        continue
    }
    
    # Show what we're searching with
    Write-ColorOutput ""
    Write-ColorOutput "Searching with:" "Yellow"
    if ($DeviceName) { Write-ColorOutput "  Device Name:   $DeviceName" "White" }
    if ($SerialNumber) { Write-ColorOutput "  Serial Number: $SerialNumber" "White" }
    Write-ColorOutput ""
    
    # Search for device
    $deviceData = Get-DeviceFromAllPlatforms -Name $DeviceName -Serial $SerialNumber
    
    # Check if device found anywhere
    $foundAnywhere = ($null -ne $deviceData.Autopilot) -or ($null -ne $deviceData.Intune) -or ($deviceData.Entra.Count -gt 0)
    
    if (-not $foundAnywhere) {
        Write-ColorOutput ""
        Write-ColorOutput "═══════════════════════════════════════════════════" "Red"
        Write-ColorOutput "  ✗ Device not found in any platform" "Red"
        Write-ColorOutput "═══════════════════════════════════════════════════" "Red"
        Write-ColorOutput ""
        Write-ColorOutput "Tips:" "Yellow"
        Write-ColorOutput "  - For Entra ID: Device name is required" "Gray"
        Write-ColorOutput "  - For Autopilot: Serial number works best" "Gray"
        Write-ColorOutput "  - Try providing both identifiers" "Gray"
        Write-ColorOutput ""
        $DeviceName = $null
        $SerialNumber = $null
        continue
    }
    
    # Show device info
    Show-DeviceInfo -Name $DeviceName -Serial $SerialNumber -DeviceData $deviceData
    
    # Show menu and process choice
    $choice = Show-Menu
    
    Write-ColorOutput ""
    
    switch ($choice) {
        "1" {
            Write-ColorOutput "Deleting from Entra ID..." "Cyan"
            $result = Remove-FromEntra -Devices $deviceData.Entra -WhatIfMode:$WhatIf
            
            if (-not $WhatIf -and $result.Success) {
                Wait-ForRemoval -Name $DeviceName -Serial $SerialNumber -Platforms @("Entra") | Out-Null
            }
        }
        "2" {
            Write-ColorOutput "Deleting from Intune..." "Cyan"
            $result = Remove-FromIntune -Device $deviceData.Intune -WhatIfMode:$WhatIf
            
            if (-not $WhatIf -and $result.Success) {
                Wait-ForRemoval -Name $DeviceName -Serial $SerialNumber -Platforms @("Intune") | Out-Null
            }
        }
        "3" {
            Write-ColorOutput "Deleting from Autopilot..." "Cyan"
            $result = Remove-FromAutopilot -Device $deviceData.Autopilot -WhatIfMode:$WhatIf
            
            if (-not $WhatIf -and $result.Success) {
                Wait-ForRemoval -Name $DeviceName -Serial $SerialNumber -Platforms @("Autopilot") | Out-Null
            }
        }
        "4" {
            Write-ColorOutput "Deleting from ALL platforms..." "Cyan"
            Write-ColorOutput ""
            
            # Delete in order: Intune -> Autopilot -> Entra
            $intuneResult = Remove-FromIntune -Device $deviceData.Intune -WhatIfMode:$WhatIf
            $autopilotResult = Remove-FromAutopilot -Device $deviceData.Autopilot -WhatIfMode:$WhatIf
            $entraResult = Remove-FromEntra -Devices $deviceData.Entra -WhatIfMode:$WhatIf
            
            if (-not $WhatIf) {
                $platformsToVerify = @()
                if ($intuneResult.Found) { $platformsToVerify += "Intune" }
                if ($autopilotResult.Found) { $platformsToVerify += "Autopilot" }
                if ($entraResult.Found) { $platformsToVerify += "Entra" }
                
                if ($platformsToVerify.Count -gt 0) {
                    Wait-ForRemoval -Name $DeviceName -Serial $SerialNumber -Platforms $platformsToVerify | Out-Null
                }
            }
            else {
                Write-ColorOutput ""
                Write-ColorOutput "═══════════════════════════════════════════════════" "Green"
                Write-ColorOutput "  WHATIF: Deletion Complete" "Green"
                Write-ColorOutput "═══════════════════════════════════════════════════" "Green"
            }
        }
        "5" {
            $DeviceName = $null
            $SerialNumber = $null
            continue
        }
        "6" {
            $continue = $false
            Write-ColorOutput "Goodbye!" "Cyan"
            continue
        }
        default {
            Write-ColorOutput "Invalid choice. Please try again." "Red"
            continue
        }
    }
    
    Write-ColorOutput ""
    $another = Read-Host "Delete another device? (Y/N)"
    if ($another -eq 'Y' -or $another -eq 'y') {
        $DeviceName = $null
        $SerialNumber = $null
    } else {
        $continue = $false
        Write-ColorOutput ""
        Write-ColorOutput "Disconnecting from Microsoft Graph..." "Yellow"
        try {
            Disconnect-MgGraph | Out-Null
            Write-ColorOutput "✓ Disconnected" "Green"
        } catch { }
        Write-ColorOutput ""
        Write-ColorOutput "Goodbye!" "Cyan"
    }
}
#endregion Main Execution

