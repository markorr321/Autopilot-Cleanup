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
