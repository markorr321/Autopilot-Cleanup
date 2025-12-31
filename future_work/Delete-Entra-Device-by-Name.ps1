# Delete Entra device by name
param(
    [Parameter(Mandatory=$true)]
    [string]$DeviceName
)

# Connect to Microsoft Graph if not already connected
$context = Get-MgContext
if (-not $context) {
    try {
        Connect-MgGraph -Scopes "Device.ReadWrite.All" -NoWelcome -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "Failed to connect to Microsoft Graph. Exiting." -ForegroundColor Red
        exit
    }
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
