function Configure-AutopilotCleanup {
    <#
    .SYNOPSIS
        Configure Autopilot-Cleanup with custom app registration credentials.

    .DESCRIPTION
        Interactively prompts for ClientId and TenantId and saves them as user-level
        environment variables. Once configured, Invoke-AutopilotCleanup will automatically
        use these credentials without requiring parameters.

    .EXAMPLE
        Configure-AutopilotCleanup
    #>
    [CmdletBinding()]
    param()

    Write-Host "`nAutopilot-Cleanup Configuration" -ForegroundColor Cyan
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host "`nThis will configure your custom app registration for Autopilot-Cleanup."
    Write-Host "These settings will be saved as user-level environment variables.`n"

    # Prompt for ClientId
    $clientId = Read-Host "Enter your App Registration Client ID"
    if ([string]::IsNullOrWhiteSpace($clientId)) {
        Write-Host "ClientId cannot be empty. Configuration cancelled." -ForegroundColor Yellow
        return
    }

    # Prompt for TenantId
    $tenantId = Read-Host "Enter your Tenant ID"
    if ([string]::IsNullOrWhiteSpace($tenantId)) {
        Write-Host "TenantId cannot be empty. Configuration cancelled." -ForegroundColor Yellow
        return
    }

    # Set user-level environment variables
    try {
        [System.Environment]::SetEnvironmentVariable('AUTOPILOTCLEANUP_CLIENTID', $clientId, 'User')
        [System.Environment]::SetEnvironmentVariable('AUTOPILOTCLEANUP_TENANTID', $tenantId, 'User')

        # Also set for current session
        $env:AUTOPILOTCLEANUP_CLIENTID = $clientId
        $env:AUTOPILOTCLEANUP_TENANTID = $tenantId

        Write-Host "`nConfiguration saved successfully!" -ForegroundColor Green
        Write-Host "You can now run Invoke-AutopilotCleanup without parameters.`n" -ForegroundColor Green

        # macOS-specific handling
        $isRunningOnMac = if ($null -ne $IsMacOS) { $IsMacOS } else { $PSVersionTable.OS -match 'Darwin' }
        if ($isRunningOnMac) {
            Write-Host "macOS Note:" -ForegroundColor Yellow
            Write-Host "Environment variables may not persist across terminal sessions on macOS." -ForegroundColor Gray
            Write-Host "To ensure persistence, add the following to your PowerShell profile:`n" -ForegroundColor Gray
            Write-Host "`$env:AUTOPILOTCLEANUP_CLIENTID = `"$clientId`"" -ForegroundColor Cyan
            Write-Host "`$env:AUTOPILOTCLEANUP_TENANTID = `"$tenantId`"`n" -ForegroundColor Cyan

            Write-Host "Would you like to:" -ForegroundColor Yellow
            Write-Host "  1) Add automatically to PowerShell profile" -ForegroundColor White
            Write-Host "  2) Do it manually later" -ForegroundColor White
            Write-Host ""
            $choice = Read-Host "Enter choice (1 or 2)"

            if ($choice -eq "1") {
                $profilePath = $PROFILE.CurrentUserAllHosts
                if (-not (Test-Path $profilePath)) {
                    New-Item -Path $profilePath -ItemType File -Force | Out-Null
                }

                $profileContent = @"

# Autopilot-Cleanup Configuration
`$env:AUTOPILOTCLEANUP_CLIENTID = "$clientId"
`$env:AUTOPILOTCLEANUP_TENANTID = "$tenantId"
"@
                Add-Content -Path $profilePath -Value $profileContent
                Write-Host "`nAdded to PowerShell profile: $profilePath" -ForegroundColor Green
                Write-Host "Configuration will persist across sessions.`n" -ForegroundColor Green
            } else {
                Write-Host "`nYou can add it manually later to: $($PROFILE.CurrentUserAllHosts)`n" -ForegroundColor Gray
            }
        }
    }
    catch {
        Write-Host "`nFailed to save configuration: $_" -ForegroundColor Red
    }
}
