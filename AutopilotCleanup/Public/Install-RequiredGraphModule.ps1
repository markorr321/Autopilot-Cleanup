function Install-RequiredGraphModule {
    param(
        [string[]]$ModuleNames
    )

    Write-Host "Checking required PowerShell modules..." -ForegroundColor Yellow

    $missingModules = @()

    foreach ($moduleName in $ModuleNames) {
        if (Get-Module -ListAvailable -Name $moduleName) {
            Write-Host "✓ Module '$moduleName' is already installed" -ForegroundColor Green
        } else {
            Write-Host "✗ Module '$moduleName' is not installed" -ForegroundColor Red
            $missingModules += $moduleName
        }
    }

    if ($missingModules.Count -gt 0) {
        Write-Host ""
        Write-Host "[!] Missing required modules:" -ForegroundColor Red
        $missingModules | ForEach-Object { Write-Host "  - $_" -ForegroundColor Cyan }
        Write-Host ""

        $response = Read-Host "Install now? (Y/N) [Press Enter to skip]"

        if ($response -eq 'Y' -or $response -eq 'y') {
            Write-Host ""

            foreach ($module in $missingModules) {
                Write-Host "Installing $module..." -ForegroundColor Cyan

                try {
                    # Detect available install method and use matching command
                    if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
                        Install-PSResource -Name $module -Scope CurrentUser -TrustRepository -Confirm:$false -ErrorAction Stop
                    }
                    elseif (Get-Command Install-Module -ErrorAction SilentlyContinue) {
                        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                    }
                    else {
                        Write-Host "No install commands available. Please install manually:" -ForegroundColor Yellow
                        Write-Host "  Install-Module -Name $module -Scope CurrentUser" -ForegroundColor Yellow
                        Write-Host ""
                        Write-Host "Press Enter to exit"
                        $null = [Console]::ReadLine()
                        return $false
                    }

                    Write-Host "✓ Successfully installed $module" -ForegroundColor Green
                }
                catch {
                    Write-Host ""
                    Write-Host "✗ Failed to install $module" -ForegroundColor Red
                    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
                    Write-Host ""
                    Write-Host "Please install manually:" -ForegroundColor Yellow
                    Write-Host "  Install-Module -Name $module -Scope CurrentUser      (PowerShellGet)" -ForegroundColor Yellow
                    Write-Host "  Install-PSResource -Name $module -Scope CurrentUser  (PSResourceGet)" -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "Press Enter to exit"
                    $null = [Console]::ReadLine()
                    return $false
                }
            }

            Write-Host ""
            Write-Host "All required modules installed." -ForegroundColor Green
            return $true
        }
        elseif ($response -eq 'N' -or $response -eq 'n') {
            Write-Host "Cannot proceed without required modules." -ForegroundColor Yellow
            return $false
        }
        else {
            Write-Host "Skipping installation. Cannot proceed without required modules." -ForegroundColor Yellow
            return $false
        }
    }
    else {
        Write-Host "All required modules are installed." -ForegroundColor Green
        return $true
    }
}
