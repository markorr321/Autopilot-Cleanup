function Show-UpdateNotification {
    <#
    .SYNOPSIS
        Displays the update notification message.

    .DESCRIPTION
        Shows a formatted notification when a newer version of AutopilotCleanup
        is available on PowerShell Gallery.

    .PARAMETER CurrentVersion
        The currently installed version.

    .PARAMETER LatestVersion
        The latest version available on PowerShell Gallery.

    .EXAMPLE
        Show-UpdateNotification -CurrentVersion "2.0.0" -LatestVersion "2.1.0"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [version]$CurrentVersion,

        [Parameter(Mandatory)]
        [version]$LatestVersion
    )

    Write-Host ""
    Write-Host "[!] AutopilotCleanup update available: $CurrentVersion -> $LatestVersion" -ForegroundColor Red
    Write-Host ""

    $response = Read-Host "Update now? (Y/N) [Press Enter to skip]"

    if ($response -eq 'Y' -or $response -eq 'y') {
        Write-Host ""
        Write-Host "Updating AutopilotCleanup..." -ForegroundColor Cyan

        try {
            # Detect how the module was installed and use matching update command
            $installedViaPSResource = $null
            $installedViaPowerShellGet = $null

            # Check PSResourceGet first
            if (Get-Command Get-InstalledPSResource -ErrorAction SilentlyContinue) {
                $installedViaPSResource = Get-InstalledPSResource -Name AutopilotCleanup -ErrorAction SilentlyContinue
            }

            # Check PowerShellGet
            if (Get-Command Get-InstalledModule -ErrorAction SilentlyContinue) {
                $installedViaPowerShellGet = Get-InstalledModule -Name AutopilotCleanup -ErrorAction SilentlyContinue
            }

            if ($installedViaPSResource) {
                # Installed via PSResourceGet - detect scope from installation path
                $installPath = $installedViaPSResource.InstalledLocation
                # AllUsers paths: Windows="Program Files", macOS/Linux="/usr/local"
                $scope = if ($installPath -match 'Program Files|/usr/local') { 'AllUsers' } else { 'CurrentUser' }
                Update-PSResource -Name AutopilotCleanup -Scope $scope -Confirm:$false
            }
            elseif ($installedViaPowerShellGet) {
                # Installed via PowerShellGet, use Update-Module
                Update-Module -Name AutopilotCleanup -Force
            }
            elseif (Get-Command Update-Module -ErrorAction SilentlyContinue) {
                # Fallback to Update-Module if we can't detect installation method
                Update-Module -Name AutopilotCleanup -Force
            }
            else {
                Write-Host "Update commands not found. Please run manually:" -ForegroundColor Yellow
                Write-Host "  Install-Module -Name AutopilotCleanup -Force" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Press Enter to continue"
                $null = [Console]::ReadLine()
                return
            }

            Write-Host ""
            Write-Host "Update complete! Please restart PowerShell and run Start-AutopilotCleanup again." -ForegroundColor Green
            Write-Host ""
            Write-Host "Press Enter to Exit"
            $null = [Console]::ReadLine()
            exit
        }
        catch {
            Write-Host ""
            Write-Host "Update failed: $_" -ForegroundColor Red
            Write-Host "Please update manually with:" -ForegroundColor Yellow
            Write-Host "  Update-Module -Name AutopilotCleanup      (if installed via Install-Module)" -ForegroundColor Yellow
            Write-Host "  Update-PSResource -Name AutopilotCleanup  (if installed via Install-PSResource)" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Press Enter to continue anyway"
            $null = [Console]::ReadLine()
        }
    }
    elseif ($response -eq 'N' -or $response -eq 'n') {
        Write-Host "Skipping update." -ForegroundColor Yellow
        Write-Host ""
    }
    else {
        # Just continue
        Write-Host ""
    }
}
