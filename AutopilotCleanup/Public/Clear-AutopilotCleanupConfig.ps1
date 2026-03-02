function Clear-AutopilotCleanupConfig {
    <#
    .SYNOPSIS
        Clears the saved Autopilot-Cleanup configuration.

    .DESCRIPTION
        Removes the user-level environment variables for ClientId and TenantId.
        On macOS, also offers to remove the configuration from PowerShell profile.
        After clearing, Invoke-AutopilotCleanup will use the default authentication flow.

    .EXAMPLE
        Clear-AutopilotCleanupConfig
    #>
    [CmdletBinding()]
    param()

    try {
        [System.Environment]::SetEnvironmentVariable('AUTOPILOTCLEANUP_CLIENTID', $null, 'User')
        [System.Environment]::SetEnvironmentVariable('AUTOPILOTCLEANUP_TENANTID', $null, 'User')

        # Also clear from current session
        $env:AUTOPILOTCLEANUP_CLIENTID = $null
        $env:AUTOPILOTCLEANUP_TENANTID = $null

        Write-Host "Autopilot-Cleanup configuration cleared successfully." -ForegroundColor Green
        Write-Host "Invoke-AutopilotCleanup will now use the default authentication flow.`n" -ForegroundColor Green

        # macOS-specific handling - check if profile has the config
        $isRunningOnMac = if ($null -ne $IsMacOS) { $IsMacOS } else { $PSVersionTable.OS -match 'Darwin' }
        if ($isRunningOnMac) {
            $profilePath = $PROFILE.CurrentUserAllHosts
            if (Test-Path $profilePath) {
                $profileContent = Get-Content -Path $profilePath -Raw
                if ($profileContent -match 'AUTOPILOTCLEANUP_CLIENTID' -or $profileContent -match 'AUTOPILOTCLEANUP_TENANTID') {
                    Write-Host "macOS Note:" -ForegroundColor Yellow
                    Write-Host "Configuration found in PowerShell profile." -ForegroundColor Gray
                    Write-Host "Would you like to remove it from your profile? (y/n)" -ForegroundColor Yellow
                    $choice = Read-Host

                    if ($choice -eq 'y' -or $choice -eq 'Y') {
                        # Remove Autopilot-Cleanup configuration section from profile
                        $newContent = $profileContent -replace '(?ms)# Autopilot-Cleanup Configuration.*?\$env:AUTOPILOTCLEANUP_TENANTID = ".*?"', ''
                        Set-Content -Path $profilePath -Value $newContent.Trim()
                        Write-Host "Removed from PowerShell profile: $profilePath`n" -ForegroundColor Green
                    } else {
                        Write-Host "Profile not modified. You can manually edit: $profilePath`n" -ForegroundColor Gray
                    }
                }
            }
        }
    }
    catch {
        Write-Host "Failed to clear configuration: $_" -ForegroundColor Red
    }
}
