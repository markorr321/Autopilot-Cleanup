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
