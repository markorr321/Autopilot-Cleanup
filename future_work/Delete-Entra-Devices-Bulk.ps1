# Delete Entra devices in bulk from a text file
param(
    [Parameter(Mandatory=$true)]
    [string]$DeviceListFile
)

# Validate file exists
if (-not (Test-Path $DeviceListFile)) {
    Write-Host "File not found: $DeviceListFile" -ForegroundColor Red
    exit
}

# Connect to Microsoft Graph if not already connected
try {
    Get-MgContext | Out-Null
} catch {
    Connect-MgGraph -Scopes "Device.ReadWrite.All"
}

# Load device names from file (one per line)
$deviceNames = Get-Content $DeviceListFile | Where-Object { $_.Trim() -ne "" }
Write-Host "Loaded $($deviceNames.Count) device(s) from file: $DeviceListFile" -ForegroundColor Cyan
Write-Host ""

# Counters for summary
$successCount = 0
$failCount = 0
$notFoundCount = 0

# Process each device
foreach ($name in $deviceNames) {
    $name = $name.Trim()
    
    # Find the device by display name
    $device = Get-MgDevice -Filter "displayName eq '$name'"

    if ($device) {
        try {
            Remove-MgDevice -DeviceId $device.Id
            Write-Host "Successfully deleted device: $name" -ForegroundColor Green
            $successCount++
        } catch {
            Write-Host "Failed to delete device: $name. Error: $_" -ForegroundColor Red
            $failCount++
        }
    } else {
        Write-Host "Device not found: $name" -ForegroundColor Yellow
        $notFoundCount++
    }
}

# Summary
Write-Host ""
Write-Host "========== Summary ==========" -ForegroundColor Cyan
Write-Host "Deleted:   $successCount" -ForegroundColor Green
Write-Host "Failed:    $failCount" -ForegroundColor Red
Write-Host "Not Found: $notFoundCount" -ForegroundColor Yellow
