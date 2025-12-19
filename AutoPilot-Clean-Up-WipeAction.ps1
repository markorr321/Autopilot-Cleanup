#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Wipes Intune devices and removes all records from Autopilot, Intune, and Entra ID.

.DESCRIPTION
    Complete device cleanup workflow:
    1. Wipes the device remotely via Intune
    2. Forces device check-in to expedite wipe
    3. Monitors until wipe completes
    4. Removes device from Autopilot
    5. Removes device from Entra ID

.PARAMETER DeviceId
    The Intune Managed Device ID to wipe and remove.

.PARAMETER DeviceName
    The device name to search for.

.PARAMETER SerialNumber
    The device serial number to search for.

.PARAMETER KeepEnrollmentData
    Keep enrollment data after wipe.

.PARAMETER KeepUserData
    Keep user data on the device.

.PARAMETER TimeoutMinutes
    Max wait time for wipe. Default: 30 minutes.

.PARAMETER PollIntervalSeconds
    Check interval. Default: 30 seconds.

.PARAMETER SkipWipe
    Skip wipe, only remove records.

.PARAMETER WhatIf
    Preview mode.

.NOTES
    Author: Mark Orr
    Date: December 2024
#>

param(
    [Parameter(Mandatory = $false)][string]$DeviceId,
    [Parameter(Mandatory = $false)][string]$DeviceName,
    [Parameter(Mandatory = $false)][string]$SerialNumber,
    [Parameter(Mandatory = $false)][switch]$KeepEnrollmentData,
    [Parameter(Mandatory = $false)][switch]$KeepUserData,
    [Parameter(Mandatory = $false)][int]$TimeoutMinutes = 30,
    [Parameter(Mandatory = $false)][int]$PollIntervalSeconds = 30,
    [Parameter(Mandatory = $false)][switch]$SkipWipe,
    [Parameter(Mandatory = $false)][switch]$WhatIf
)

function Write-ColorOutput {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Test-GraphConnection {
    try {
        $context = Get-MgContext
        return ($null -ne $context)
    }
    catch { return $false }
}

function Connect-ToGraph {
    Write-ColorOutput "Connecting to Microsoft Graph..." "Yellow"
    $scopes = @(
        "Device.ReadWrite.All",
        "DeviceManagementManagedDevices.PrivilegedOperations.All",
        "DeviceManagementManagedDevices.ReadWrite.All",
        "DeviceManagementServiceConfig.ReadWrite.All"
    )
    try {
        Connect-MgGraph -Scopes $scopes -NoWelcome
        Write-ColorOutput "✓ Connected to Microsoft Graph" "Green"
        return $true
    }
    catch {
        Write-ColorOutput "✗ Failed to connect: $($_.Exception.Message)" "Red"
        return $false
    }
}

function Get-GraphPagedResults {
    param([string]$Uri)
    $allResults = @()
    $currentUri = $Uri
    do {
        try {
            $response = Invoke-MgGraphRequest -Uri $currentUri -Method GET
            if ($response.value) { $allResults += $response.value }
            $currentUri = $response.'@odata.nextLink'
        }
        catch { break }
    } while ($currentUri)
    return $allResults
}

function Get-IntuneDeviceById {
    param([string]$Id)
    try {
        return Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$Id" -Method GET
    }
    catch { return $null }
}

function Get-IntuneDeviceByName {
    param([string]$Name)
    try {
        return (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$Name'" -Method GET).value
    }
    catch { return $null }
}

function Get-IntuneDeviceBySerial {
    param([string]$Serial)
    try {
        return (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$Serial'" -Method GET).value | Select-Object -First 1
    }
    catch { return $null }
}

function Get-AutopilotDeviceBySerial {
    param([string]$Serial)
    try {
        return (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$Serial')" -Method GET).value | Select-Object -First 1
    }
    catch { return $null }
}

function Get-EntraDeviceByName {
    param([string]$DeviceName)
    try {
        return (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$DeviceName'" -Method GET).value
    }
    catch { return @() }
}

function Invoke-DeviceWipe {
    param([string]$ManagedDeviceId, [bool]$KeepEnrollmentData, [bool]$KeepUserData)
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
        Write-ColorOutput "Error sending wipe: $($_.Exception.Message)" "Red"
        return $false
    }
}

function Invoke-DeviceSync {
    param([string]$ManagedDeviceId)
    try {
        Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$ManagedDeviceId/syncDevice" -Method POST
        return $true
    }
    catch { return $false }
}

function Wait-ForWipeCompletion {
    param([string]$ManagedDeviceId, [string]$DeviceName, [int]$TimeoutMinutes, [int]$PollIntervalSeconds)
    
    $timeoutSeconds = $TimeoutMinutes * 60
    $startTime = Get-Date
    
    Write-ColorOutput "Monitoring wipe for: $DeviceName (Timeout: ${TimeoutMinutes}m)" "Cyan"
    
    while ($true) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        if ($elapsed -ge $timeoutSeconds) {
            Write-ColorOutput "✗ TIMEOUT after $TimeoutMinutes minutes" "Red"
            return $false
        }
        
        $device = Get-IntuneDeviceById -Id $ManagedDeviceId
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

function Remove-AutopilotDeviceRecord {
    param([string]$SerialNumber)
    $device = Get-AutopilotDeviceBySerial -Serial $SerialNumber
    if (-not $device) {
        Write-ColorOutput "  - Autopilot (not found)" "Yellow"
        return @{ Success = $true; Found = $false; Error = "Device not found" }
    }
    try {
        Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($device.id)" -Method DELETE
        Write-ColorOutput "  ✓ Autopilot deletion initiated" "Green"
        return @{ Success = $true; Found = $true; Error = $null }
    }
    catch {
        $errorMsg = $_.Exception.Message
        if ($errorMsg -match "NotFound|404") {
            Write-ColorOutput "  ✓ Autopilot (already removed)" "Green"
            return @{ Success = $true; Found = $true; Error = "Already removed" }
        }
        if ($errorMsg -like "*BadRequest*" -or $errorMsg -like "*Bad Request*") {
            if ($errorMsg -like "*already*" -or $errorMsg -like "*pending*") {
                Write-ColorOutput "  ⚠ Autopilot device already queued for deletion" "Yellow"
                return @{ Success = $true; Found = $true; Error = "Already queued for deletion" }
            }
            Write-ColorOutput "  ⚠ Autopilot device cannot be deleted (may already be processing)" "Yellow"
            return @{ Success = $true; Found = $true; Error = "Cannot delete - likely already processing" }
        }
        Write-ColorOutput "  ✗ Autopilot: $errorMsg" "Red"
        return @{ Success = $false; Found = $true; Error = $errorMsg }
    }
}

function Wait-ForAutopilotRemoval {
    param(
        [string]$SerialNumber,
        [int]$MaxWaitMinutes = 45,
        [int]$CheckIntervalSeconds = 5
    )
    
    $startTime = Get-Date
    $endTime = $startTime.AddMinutes($MaxWaitMinutes)
    
    Write-ColorOutput "  Verifying Autopilot removal (max wait: ${MaxWaitMinutes}m)..." "Cyan"
    
    do {
        Start-Sleep -Seconds $CheckIntervalSeconds
        $elapsedMinutes = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        
        $device = Get-AutopilotDeviceBySerial -Serial $SerialNumber
        
        if (-not $device) {
            Write-ColorOutput "  ✓ Autopilot removal verified ($elapsedMinutes min)" "Green"
            return $true
        }
        
        Write-ColorOutput "  Waiting for Autopilot removal... ($elapsedMinutes min)" "Yellow"
        
    } while ((Get-Date) -lt $endTime)
    
    Write-ColorOutput "  ⚠ Autopilot removal not verified after $MaxWaitMinutes minutes" "Yellow"
    Write-ColorOutput "  ⚠ Please check the Intune portal manually to verify removal status" "Yellow"
    return $false
}

function Remove-EntraDeviceRecords {
    param([string]$DeviceName)
    $devices = Get-EntraDeviceByName -DeviceName $DeviceName
    if (-not $devices -or $devices.Count -eq 0) {
        Write-ColorOutput "  - Entra ID (not found)" "Yellow"
        return $true
    }
    $count = 0
    foreach ($d in $devices) {
        try {
            Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/devices/$($d.id)" -Method DELETE
            $count++
        }
        catch { }
    }
    Write-ColorOutput "  ✓ Entra ID ($count device(s))" "Green"
    return $true
}

# Main Execution
Clear-Host
Write-ColorOutput "=================================================" "Magenta"
Write-ColorOutput "  Autopilot Cleanup - Wipe & Remove Action" "Magenta"
Write-ColorOutput "=================================================" "Magenta"
Write-ColorOutput ""

if ($WhatIf) {
    Write-ColorOutput "Mode: WHATIF (No actions performed)" "Yellow"
    Write-ColorOutput ""
}

if (-not (Test-GraphConnection)) {
    if (-not (Connect-ToGraph)) { exit 1 }
}
Write-ColorOutput ""

# Find target device(s)
$targetDevices = @()

if ($DeviceId) {
    $device = Get-IntuneDeviceById -Id $DeviceId
    if ($device) {
        $targetDevices += [PSCustomObject]@{
            IntuneId = $device.id; DeviceName = $device.deviceName; SerialNumber = $device.serialNumber
            OS = $device.operatingSystem; Compliance = $device.complianceState; LastSync = $device.lastSyncDateTime
        }
    } else {
        Write-ColorOutput "Device not found." "Red"; exit 1
    }
}
elseif ($DeviceName) {
    $devices = Get-IntuneDeviceByName -Name $DeviceName
    if ($devices) {
        foreach ($d in $devices) {
            $targetDevices += [PSCustomObject]@{
                IntuneId = $d.id; DeviceName = $d.deviceName; SerialNumber = $d.serialNumber
                OS = $d.operatingSystem; Compliance = $d.complianceState; LastSync = $d.lastSyncDateTime
            }
        }
    } else {
        Write-ColorOutput "No device found: $DeviceName" "Red"; exit 1
    }
}
elseif ($SerialNumber) {
    $device = Get-IntuneDeviceBySerial -Serial $SerialNumber
    if ($device) {
        $targetDevices += [PSCustomObject]@{
            IntuneId = $device.id; DeviceName = $device.deviceName; SerialNumber = $device.serialNumber
            OS = $device.operatingSystem; Compliance = $device.complianceState; LastSync = $device.lastSyncDateTime
        }
    } else {
        Write-ColorOutput "No device found: $SerialNumber" "Red"; exit 1
    }
}
else {
    # Interactive grid selection
    Write-ColorOutput "Fetching all Intune devices..." "Yellow"
    $allDevices = Get-GraphPagedResults -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices"
    # Filter to Windows devices only
    $allDevices = $allDevices | Where-Object { $_.operatingSystem -eq 'Windows' }
    Write-ColorOutput "Found $($allDevices.Count) Windows devices" "Green"
    
    $gridDevices = $allDevices | ForEach-Object {
        [PSCustomObject]@{
            DeviceName = $_.deviceName; SerialNumber = $_.serialNumber; OS = $_.operatingSystem
            Compliance = $_.complianceState; LastSync = $_.lastSyncDateTime; IntuneId = $_.id
        }
    }
    
    $selected = $gridDevices | Select-Object DeviceName, SerialNumber, OS, Compliance, LastSync |
        Out-GridView -Title "Select Devices to WIPE and Remove" -PassThru
    
    if (-not $selected) { Write-ColorOutput "No devices selected." "Yellow"; exit 0 }
    
    foreach ($s in $selected) {
        $full = $gridDevices | Where-Object { $_.SerialNumber -eq $s.SerialNumber }
        $targetDevices += $full
    }
}

# Display selected devices
Write-ColorOutput ""
Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
Write-ColorOutput "Selected Device(s):" "Cyan"
Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
foreach ($d in $targetDevices) {
    Write-ColorOutput "  $($d.DeviceName) | Serial: $($d.SerialNumber) | $($d.Compliance)" "White"
}
Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"

# Confirm
Write-ColorOutput ""
if ($SkipWipe) {
    Write-ColorOutput "⚠️  This will REMOVE records (wipe skipped)" "Yellow"
} else {
    Write-ColorOutput "⚠️  WARNING: This will WIPE device(s) and REMOVE all records!" "Red"
}
Write-ColorOutput ""

$confirm = Read-Host "Type 'WIPE' to confirm"
if ($confirm -ne 'WIPE') {
    Write-ColorOutput "Cancelled." "Yellow"
    exit 0
}

# Process each device
$startTime = Get-Date

foreach ($device in $targetDevices) {
    Write-ColorOutput ""
    Write-ColorOutput "════════════════════════════════════════════════════════════" "Cyan"
    Write-ColorOutput "Processing: $($device.DeviceName) (Serial: $($device.SerialNumber))" "Cyan"
    Write-ColorOutput "════════════════════════════════════════════════════════════" "Cyan"
    
    if ($WhatIf) {
        Write-ColorOutput "WHATIF: Would wipe and remove device" "Yellow"
        continue
    }
    
    $wipeSuccess = $true
    
    # Step 1: Wipe (unless skipped)
    if (-not $SkipWipe) {
        Write-ColorOutput ""
        Write-ColorOutput "Step 1: Sending wipe command..." "Yellow"
        $wipeResult = Invoke-DeviceWipe -ManagedDeviceId $device.IntuneId -KeepEnrollmentData $KeepEnrollmentData -KeepUserData $KeepUserData
        
        if (-not $wipeResult) {
            Write-ColorOutput "Failed to send wipe command." "Red"
            continue
        }
        Write-ColorOutput "✓ Wipe command sent" "Green"
        
        # Force sync
        Write-ColorOutput "Sending sync to force check-in..." "Yellow"
        if (Invoke-DeviceSync -ManagedDeviceId $device.IntuneId) {
            Write-ColorOutput "✓ Sync command sent" "Green"
        }
        
        # Wait for wipe
        Write-ColorOutput ""
        Write-ColorOutput "Step 2: Waiting for wipe to complete..." "Yellow"
        $wipeSuccess = Wait-ForWipeCompletion -ManagedDeviceId $device.IntuneId -DeviceName $device.DeviceName -TimeoutMinutes $TimeoutMinutes -PollIntervalSeconds $PollIntervalSeconds
        
        if (-not $wipeSuccess) {
            Write-ColorOutput "Wipe did not complete in time. Skipping record removal." "Red"
            continue
        }
    }
    else {
        Write-ColorOutput "Skipping wipe (SkipWipe flag set)" "Yellow"
    }
    
    # Step 3: Remove records
    Write-ColorOutput ""
    Write-ColorOutput "Step 3: Removing device records..." "Yellow"
    
    $autopilotResult = Remove-AutopilotDeviceRecord -SerialNumber $device.SerialNumber
    
    # Verify Autopilot removal if deletion was initiated
    if ($autopilotResult.Found -and $autopilotResult.Success -and -not $autopilotResult.Error) {
        $autopilotVerified = Wait-ForAutopilotRemoval -SerialNumber $device.SerialNumber -MaxWaitMinutes 45 -CheckIntervalSeconds 5
    }
    
    Remove-EntraDeviceRecords -DeviceName $device.DeviceName
    
    Write-ColorOutput ""
    Write-ColorOutput "════════════════════════════════════════════════════════════" "Green"
    Write-ColorOutput "  ✓ DEVICE CLEANUP COMPLETE: $($device.DeviceName)" "Green"
    Write-ColorOutput "════════════════════════════════════════════════════════════" "Green"
}

# Final summary
$endTime = Get-Date
$duration = $endTime - $startTime
$durationFormatted = "{0:mm\:ss}" -f $duration

Write-ColorOutput ""
Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
Write-ColorOutput "  WIPE & REMOVAL COMPLETE" "Magenta"
Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
Write-ColorOutput "  Devices processed: $($targetDevices.Count)" "White"
Write-ColorOutput "  Total duration:    $durationFormatted" "White"
Write-ColorOutput "  Completed:         $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "White"
Write-ColorOutput "═══════════════════════════════════════════════════" "Magenta"
