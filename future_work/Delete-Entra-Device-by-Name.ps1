# Delete Entra device by name
param(
    [Parameter(Mandatory=$true)]
    [string]$DeviceName
)

# Connect to Microsoft Graph if not already connected
try {
    Get-MgContext | Out-Null
} catch {
    Connect-MgGraph -Scopes "Device.ReadWrite.All"
}

# Find the device by display name
$device = Get-MgDevice -Filter "displayName eq '$DeviceName'"

if ($device) {
    try {
        Remove-MgDevice -DeviceId $device.Id
        Write-Host "Successfully deleted device: $DeviceName" -ForegroundColor Green
    } catch {
        Write-Host "Failed to delete device: $DeviceName. Error: $_" -ForegroundColor Red
    }
} else {
    Write-Host "Device not found: $DeviceName" -ForegroundColor Yellow
}
