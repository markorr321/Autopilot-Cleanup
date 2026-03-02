function Invoke-AutopilotCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(HelpMessage = "Client ID of the app registration to use for delegated auth")]
        [string]$ClientId,

        [Parameter(HelpMessage = "Tenant ID to use with the specified app registration")]
        [string]$TenantId,

        [Parameter(HelpMessage = "One or more serial numbers to target for removal. Bypasses the device selection grid.")]
        [string[]]$SerialNumber
    )

    # Main execution
    Clear-Host

    # Initialize module-level variables
    $script:MonitoringMode = $false
    $script:NoLoggingMode = $false

    # Resolve custom app registration: params → env vars → default
    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        $ClientId = $env:AUTOPILOTCLEANUP_CLIENTID
    }
    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        $TenantId = $env:AUTOPILOTCLEANUP_TENANTID
    }

    # Store in module scope for Connect-AutopilotGraph to use
    $script:CustomClientId = $ClientId
    $script:CustomTenantId = $TenantId

    # Get version from module manifest
    $manifestPath = Join-Path (Split-Path $PSScriptRoot) 'AutopilotCleanup.psd1'
    $moduleVersion = if (Test-Path $manifestPath) {
        (Import-PowerShellDataFile $manifestPath).ModuleVersion
    } else { "2.0.0" }

    Write-Host "[ A U T O P I L O T   C L E A N U P ]" -ForegroundColor Magenta -NoNewline
    Write-Host "  v$moduleVersion" -ForegroundColor DarkGray
    Write-Host "    with PowerShell" -ForegroundColor DarkGray
    Write-Host ""

    if ($WhatIfPreference) {
        Write-ColorOutput "Mode: WHATIF (No actual deletions will be performed)" "Yellow"
    }

    # Show which auth mode is being used
    if (-not [string]::IsNullOrWhiteSpace($script:CustomClientId)) {
        Write-ColorOutput "Auth: Custom app registration" "Cyan"
        Write-ColorOutput "  Client ID: $($script:CustomClientId)" "Gray"
        if (-not [string]::IsNullOrWhiteSpace($script:CustomTenantId)) {
            Write-ColorOutput "  Tenant ID: $($script:CustomTenantId)" "Gray"
        }
    } else {
        Write-ColorOutput "Auth: Default Microsoft Graph (delegated)" "Cyan"
    }
    Write-Host ""

    # Define required modules
    $requiredModules = @(
        'Microsoft.Graph.Authentication'
    )

    # Check and install required modules
    if (-not (Install-RequiredGraphModule -ModuleNames $requiredModules)) {
        Write-ColorOutput "Failed to install required modules. Exiting." "Red"
        return
    }
    Write-ColorOutput ""

    # Check if already connected to Graph
    if (-not (Test-GraphConnection)) {
        if (-not (Connect-AutopilotGraph)) {
            Write-ColorOutput "Failed to connect to Microsoft Graph. Exiting." "Red"
            return
        }
    }

    # Bulk fetch all devices from all services
    $autopilotDevices = @()
    $allIntuneDevices = @()
    $allEntraDevices = @()

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        # PowerShell 7+: Fetch all 3 services in parallel using thread jobs
        Write-ColorOutput "Fetching devices from all services in parallel..." "Yellow"

        # Shared progress tracker - thread jobs update this in real time
        $progressTracker = [System.Collections.Concurrent.ConcurrentDictionary[string, hashtable]]::new()
        $progressTracker["Autopilot"] = @{ Pages = 0; Records = 0; Done = $false }
        $progressTracker["Intune"] = @{ Pages = 0; Records = 0; Done = $false }
        $progressTracker["Entra ID"] = @{ Pages = 0; Records = 0; Done = $false }

        $fetchScript = {
            param($Uri, $ServiceName, $Tracker)
            Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
            $allResults = [System.Collections.Generic.List[object]]::new()
            $currentUri = $Uri
            $page = 0
            do {
                $page++
                $response = Invoke-MgGraphRequest -Uri $currentUri -Method GET
                if ($response.value) {
                    $allResults.AddRange($response.value)
                }
                $Tracker[$ServiceName] = @{ Pages = $page; Records = $allResults.Count; Done = $false }
                $currentUri = $response.'@odata.nextLink'
            } while ($currentUri)
            $Tracker[$ServiceName] = @{ Pages = $page; Records = $allResults.Count; Done = $true }
            return @{ Service = $ServiceName; Count = $allResults.Count; Results = $allResults.ToArray() }
        }

        $autopilotJob = Start-ThreadJob -ScriptBlock $fetchScript -ArgumentList "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities", "Autopilot", $progressTracker
        $intuneJob = Start-ThreadJob -ScriptBlock $fetchScript -ArgumentList "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices", "Intune", $progressTracker
        $entraJob = Start-ThreadJob -ScriptBlock $fetchScript -ArgumentList "https://graph.microsoft.com/v1.0/devices", "Entra ID", $progressTracker

        $allJobs = @(
            @{ Job = $autopilotJob; Name = "Autopilot"; Id = 1 }
            @{ Job = $intuneJob; Name = "Intune"; Id = 2 }
            @{ Job = $entraJob; Name = "Entra ID"; Id = 3 }
        )

        # Monitor progress with per-service detail
        $startTime = Get-Date
        while ($allJobs | Where-Object { $_.Job.State -eq 'Running' }) {
            $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds)
            $completedCount = ($allJobs | Where-Object { $_.Job.State -ne 'Running' }).Count
            Write-Progress -Id 0 -Activity "Fetching devices from all services" -Status "$completedCount of 3 services complete ($($elapsed)s)" -PercentComplete (($completedCount / 3) * 100)

            foreach ($entry in $allJobs) {
                $info = $progressTracker[$entry.Name]
                if ($info.Done) {
                    Write-Progress -Id $entry.Id -ParentId 0 -Activity $entry.Name -Status "Done - $($info.Records) records" -PercentComplete 100
                } elseif ($info.Pages -gt 0) {
                    Write-Progress -Id $entry.Id -ParentId 0 -Activity $entry.Name -Status "Page $($info.Pages) - $($info.Records) records"
                } else {
                    Write-Progress -Id $entry.Id -ParentId 0 -Activity $entry.Name -Status "Starting..."
                }
            }

            Start-Sleep -Milliseconds 500
        }

        # Final update before clearing
        foreach ($entry in $allJobs) {
            $info = $progressTracker[$entry.Name]
            Write-Progress -Id $entry.Id -ParentId 0 -Activity $entry.Name -Status "Done - $($info.Records) records" -Completed
        }
        Write-Progress -Id 0 -Activity "Fetching devices from all services" -Completed

        # Collect results and handle errors
        $jobErrors = @()
        foreach ($entry in $allJobs) {
            if ($entry.Job.State -eq 'Failed') {
                $jobErrors += "$($entry.Name): $(Receive-Job -Job $entry.Job -ErrorAction SilentlyContinue 2>&1)"
            }
        }

        if ($jobErrors.Count -gt 0) {
            foreach ($err in $jobErrors) {
                Write-ColorOutput "Parallel fetch error - $err" "Red"
            }
            Write-ColorOutput "Falling back to sequential fetch..." "Yellow"

            # Clean up failed jobs
            $allJobs | ForEach-Object { Remove-Job -Job $_.Job -Force -ErrorAction SilentlyContinue }

            # Sequential fallback
            $autopilotDevices = Get-GraphPagedResults -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities" -ActivityName "Fetching Autopilot devices"
            $allIntuneDevices = Get-GraphPagedResults -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices" -ActivityName "Fetching Intune devices"
            $allEntraDevices = Get-GraphPagedResults -Uri "https://graph.microsoft.com/v1.0/devices" -ActivityName "Fetching Entra ID devices"
        } else {
            $autopilotResult = Receive-Job -Job $autopilotJob -Wait
            $intuneResult = Receive-Job -Job $intuneJob -Wait
            $entraResult = Receive-Job -Job $entraJob -Wait

            $autopilotDevices = $autopilotResult.Results
            $allIntuneDevices = $intuneResult.Results
            $allEntraDevices = $entraResult.Results

            $allJobs | ForEach-Object { Remove-Job -Job $_.Job -Force -ErrorAction SilentlyContinue }
        }

        Write-ColorOutput "Found $($autopilotDevices.Count) Autopilot devices" "Green"
        Write-ColorOutput "Found $($allIntuneDevices.Count) Intune devices" "Green"
        Write-ColorOutput "Found $($allEntraDevices.Count) Entra ID devices" "Green"
    } else {
        # PowerShell 5.1: Sequential fetch with progress bars
        Write-ColorOutput "Fetching all Autopilot devices..." "Yellow"
        $autopilotDevices = Get-GraphPagedResults -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities" -ActivityName "Fetching Autopilot devices"
        Write-ColorOutput "Found $($autopilotDevices.Count) Autopilot devices" "Green"

        Write-ColorOutput "Fetching all Intune devices..." "Yellow"
        $allIntuneDevices = Get-GraphPagedResults -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices" -ActivityName "Fetching Intune devices"
        Write-ColorOutput "Found $($allIntuneDevices.Count) Intune devices" "Green"

        Write-ColorOutput "Fetching all Entra ID devices..." "Yellow"
        $allEntraDevices = Get-GraphPagedResults -Uri "https://graph.microsoft.com/v1.0/devices" -ActivityName "Fetching Entra ID devices"
        Write-ColorOutput "Found $($allEntraDevices.Count) Entra ID devices" "Green"
    }

    if ($autopilotDevices.Count -eq 0) {
        Write-ColorOutput "No Autopilot devices found. Exiting." "Red"
        return
    }

    # Create HashSets/Hashtables for fast lookups
    $intuneBySerial = @{}
    $intuneByName = @{}
    foreach ($device in $allIntuneDevices) {
        if ($device.serialNumber) {
            $intuneBySerial[$device.serialNumber] = $device
        }
        if ($device.deviceName) {
            $intuneByName[$device.deviceName] = $device
        }
    }

    $entraByName = @{}
    $entraByDeviceId = @{}
    foreach ($device in $allEntraDevices) {
        if ($device.displayName) {
            if (-not $entraByName.ContainsKey($device.displayName)) {
                $entraByName[$device.displayName] = @()
            }
            $entraByName[$device.displayName] += $device
        }
        if ($device.deviceId) {
            $entraByDeviceId[$device.deviceId] = $device
        }
    }

    Write-ColorOutput ""
    Write-ColorOutput "Enriching device information..." "Cyan"
    $enrichedDevices = foreach ($device in $autopilotDevices) {
        # Fast local lookup instead of API calls
        $intuneDevice = $null
        if ($device.serialNumber -and $intuneBySerial.ContainsKey($device.serialNumber)) {
            $intuneDevice = $intuneBySerial[$device.serialNumber]
        } elseif ($device.displayName -and $intuneByName.ContainsKey($device.displayName)) {
            $intuneDevice = $intuneByName[$device.displayName]
        }

        $entraDevice = $null
        # First try by Azure AD Device ID (most reliable)
        if ($device.azureActiveDirectoryDeviceId -and $entraByDeviceId.ContainsKey($device.azureActiveDirectoryDeviceId)) {
            $entraDevice = $entraByDeviceId[$device.azureActiveDirectoryDeviceId]
        }
        # Fall back to display name
        elseif ($device.displayName -and $entraByName.ContainsKey($device.displayName)) {
            $entraDevice = $entraByName[$device.displayName] | Select-Object -First 1
        }

        # Create a meaningful display name
        $displayName = if ($device.displayName -and $device.displayName -ne "") {
            $device.displayName
        } elseif ($intuneDevice -and $intuneDevice.deviceName) {
            $intuneDevice.deviceName
        } elseif ($entraDevice -and $entraDevice.displayName) {
            $entraDevice.displayName
        } elseif ($device.serialNumber) {
            "Device-$($device.serialNumber)"
        } else {
            "Unknown-$($device.id.Substring(0,8))"
        }

        [PSCustomObject]@{
            AutopilotId = $device.id
            DisplayName = $displayName
            SerialNumber = $device.serialNumber
            Model = $device.model
            Manufacturer = $device.manufacturer
            GroupTag = if ($device.groupTag) { $device.groupTag } else { "None" }
            IntuneFound = if ($intuneDevice) { "Yes" } else { "No" }
            IntuneId = if ($intuneDevice) { $intuneDevice.id } else { $null }
            IntuneName = if ($intuneDevice) { $intuneDevice.deviceName } else { "N/A" }
            EntraFound = if ($entraDevice) { "Yes" } else { "No" }
            EntraId = if ($entraDevice) { $entraDevice.id } else { $null }
            EntraDeviceId = if ($entraDevice -and $entraDevice.deviceId) { $entraDevice.deviceId } elseif ($device.azureActiveDirectoryDeviceId) { $device.azureActiveDirectoryDeviceId } else { $null }
            EntraName = if ($entraDevice) { $entraDevice.displayName } else { "N/A" }
            # Store original objects for deletion
            _AutopilotDevice = $device
            _IntuneDevice = $intuneDevice
            _EntraDevice = $entraDevice
        }
    }

    # Select devices: by serial number parameter or via WPF grid
    if ($SerialNumber -and $SerialNumber.Count -gt 0) {
        Write-ColorOutput "Selecting devices by serial number..." "Cyan"
        Write-ColorOutput ""

        $selectedDevices = @()
        $notFoundSerials = @()

        foreach ($sn in $SerialNumber) {
            $match = $enrichedDevices | Where-Object { $_.SerialNumber -eq $sn }
            if ($match) {
                $selectedDevices += $match
                Write-ColorOutput "  ✓ Found: $($match.DisplayName) ($sn)" "Green"
            } else {
                $notFoundSerials += $sn
                Write-ColorOutput "  ✗ Not found in Autopilot: $sn" "Yellow"
            }
        }

        Write-ColorOutput ""
        if ($notFoundSerials.Count -gt 0) {
            Write-ColorOutput "$($notFoundSerials.Count) serial number(s) not found in Autopilot" "Yellow"
        }
        Write-ColorOutput "Matched $($selectedDevices.Count) of $($SerialNumber.Count) serial number(s)" "Cyan"
    } else {
        Write-ColorOutput ""
        Write-ColorOutput "Opening device selection window..." "Cyan"
        Write-ColorOutput "  Select the devices you want to remove, then click OK." "Gray"
        Write-ColorOutput "  Waiting for selection..." "Gray"
        $selectedDevices = Show-DeviceSelectionGrid -Devices $enrichedDevices
    }

    if (-not $selectedDevices -or $selectedDevices.Count -eq 0) {
        Write-ColorOutput "No devices selected. Exiting." "Yellow"
        return
    }

    # Validate where each selected device exists before deletion
    Write-ColorOutput ""
    Write-ColorOutput "Validating Selected Device(s)" "Cyan"
    Write-ColorOutput "------------------------------" "DarkGray"
    Write-ColorOutput ""

    foreach ($selectedDevice in $selectedDevices) {
        $fullDevice = $enrichedDevices | Where-Object { $_.SerialNumber -eq $selectedDevice.SerialNumber }
        $deviceName = $fullDevice.DisplayName
        $deviceSerial = $fullDevice.SerialNumber

        Write-ColorOutput "Searching with:" "Yellow"
        Write-ColorOutput "  Device Name:   $deviceName" "White"
        Write-ColorOutput "  Serial Number: $deviceSerial" "White"
        Write-ColorOutput ""

        # Search Intune
        Write-ColorOutput "  Searching Intune..." "Gray"
        $intuneDevice = $null
        try {
            if ($deviceSerial) {
                $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$deviceSerial'"
                $response = Invoke-MgGraphRequest -Uri $uri -Method GET
                if ($response.value -and $response.value.Count -gt 0) {
                    $intuneDevice = $response.value | Select-Object -First 1
                    Write-ColorOutput "    ✓ Found by serial number" "Green"
                }
            }
            if (-not $intuneDevice -and $deviceName) {
                $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$deviceName'"
                $response = Invoke-MgGraphRequest -Uri $uri -Method GET
                if ($response.value -and $response.value.Count -gt 0) {
                    $intuneDevice = $response.value | Select-Object -First 1
                    Write-ColorOutput "    ✓ Found by device name" "Green"
                }
            }
            if (-not $intuneDevice) {
                Write-ColorOutput "    ✗ Not found" "Yellow"
            }
        }
        catch {
            Write-ColorOutput "    Error: $($_.Exception.Message)" "Red"
        }

        # Search Autopilot
        Write-ColorOutput "  Searching Autopilot..." "Gray"
        $autopilotDevice = $null
        try {
            if ($deviceSerial) {
                $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$deviceSerial')"
                $response = Invoke-MgGraphRequest -Uri $uri -Method GET
                if ($response.value -and $response.value.Count -gt 0) {
                    $autopilotDevice = $response.value | Where-Object { $_.serialNumber -eq $deviceSerial } | Select-Object -First 1
                    if ($autopilotDevice) {
                        Write-ColorOutput "    ✓ Found by serial number" "Green"
                    }
                }
            }
            if (-not $autopilotDevice -and $deviceName) {
                $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=displayName eq '$deviceName'"
                $response = Invoke-MgGraphRequest -Uri $uri -Method GET
                if ($response.value -and $response.value.Count -gt 0) {
                    $autopilotDevice = $response.value | Select-Object -First 1
                    Write-ColorOutput "    ✓ Found by device name" "Green"
                }
            }
            if (-not $autopilotDevice) {
                Write-ColorOutput "    ✗ Not found" "Yellow"
            }
        }
        catch {
            Write-ColorOutput "    Error: $($_.Exception.Message)" "Red"
        }

        # Search Entra ID
        Write-ColorOutput "  Searching Entra ID..." "Gray"
        $entraDevices = @()
        $entraDeviceId = $fullDevice.EntraDeviceId
        try {
            # First try by Azure AD Device ID from Autopilot record (most reliable)
            if ($entraDeviceId) {
                $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$entraDeviceId'"
                $response = Invoke-MgGraphRequest -Uri $uri -Method GET
                if ($response.value -and $response.value.Count -gt 0) {
                    $entraDevices = @($response.value)
                    Write-ColorOutput "    ✓ Found by Azure AD Device ID" "Green"
                }
            }
            # Fall back to display name search if not found by ID
            if ($entraDevices.Count -eq 0 -and $deviceName) {
                $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$deviceName'"
                $response = Invoke-MgGraphRequest -Uri $uri -Method GET
                if ($response.value -and $response.value.Count -gt 0) {
                    $entraDevices = @($response.value)
                    Write-ColorOutput "    ✓ Found $($response.value.Count) record(s) by device name" "Green"
                }
            }
            if ($entraDevices.Count -eq 0) {
                Write-ColorOutput "    ✗ Not found" "Yellow"
            }
        }
        catch {
            Write-ColorOutput "    Error: $($_.Exception.Message)" "Red"
        }

        # Display search results summary
        Write-ColorOutput ""
        Write-ColorOutput "Search Results" "Magenta"
        Write-ColorOutput "------------------------------" "DarkGray"
        Write-ColorOutput "  Searched Name:   $deviceName" "White"
        Write-ColorOutput "  Searched Serial: $deviceSerial" "White"
        Write-ColorOutput ""

        # Autopilot info
        if ($autopilotDevice) {
            Write-ColorOutput "  Autopilot:  ✓ FOUND" "Green"
            Write-ColorOutput "              Name: $($autopilotDevice.displayName)" "White"
            Write-ColorOutput "              Serial: $($autopilotDevice.serialNumber)" "White"
            Write-ColorOutput "              Model: $($autopilotDevice.model)" "White"
        } else {
            Write-ColorOutput "  Autopilot:  ✗ NOT FOUND" "Yellow"
        }
        Write-ColorOutput ""

        # Intune info
        if ($intuneDevice) {
            Write-ColorOutput "  Intune:     ✓ FOUND" "Green"
            Write-ColorOutput "              Name: $($intuneDevice.deviceName)" "White"
            Write-ColorOutput "              Serial: $($intuneDevice.serialNumber)" "White"
            Write-ColorOutput "              OS: $($intuneDevice.operatingSystem)" "White"
        } else {
            Write-ColorOutput "  Intune:     ✗ NOT FOUND" "Yellow"
        }
        Write-ColorOutput ""

        # Entra info
        if ($entraDevices.Count -gt 0) {
            Write-ColorOutput "  Entra ID:   ✓ FOUND ($($entraDevices.Count) record(s))" "Green"
            foreach ($entraDevice in $entraDevices) {
                Write-ColorOutput "              Name: $($entraDevice.displayName)" "White"
                Write-ColorOutput "              Device ID: $($entraDevice.deviceId)" "White"
            }
        } else {
            Write-ColorOutput "  Entra ID:   ✗ NOT FOUND" "Yellow"
        }
        Write-ColorOutput ""
    }

    # Ask user if they want to wipe devices first
    $validChoice = $false
    while (-not $validChoice) {
        Write-ColorOutput ""
        Write-ColorOutput "Selected $($selectedDevices.Count) device(s)" "Cyan"
        Write-ColorOutput "------------------------------" "DarkGray"
        Write-ColorOutput ""
        Write-ColorOutput "What action do you want to perform?" "Cyan"
        Write-ColorOutput ""
        Write-ColorOutput "  STANDARD (monitors removal status):" "White"
        Write-ColorOutput "  [1] Remove records only" "White"
        Write-ColorOutput "  [2] WIPE device(s) + remove all records" "Red"
        Write-ColorOutput ""
        Write-ColorOutput "  FAST (skips status checks, exports CSV):" "Green"
        Write-ColorOutput "  [3] Remove records only" "Green"
        Write-ColorOutput "  [4] WIPE device(s) + remove all records" "Red"
        Write-ColorOutput ""
        Write-ColorOutput "  [5] Cancel" "Gray"
        Write-ColorOutput ""

        $actionChoice = Read-Host "Enter your choice (1-5)"

        switch ($actionChoice) {
            "1" {
                $performWipe = $false
                $validChoice = $true
                Write-ColorOutput ""
                Write-ColorOutput "Mode: Remove records only" "Cyan"
            }
            "2" {
                $performWipe = $true
                $validChoice = $true
                Write-ColorOutput ""
                Write-ColorOutput "Mode: WIPE and remove records" "Yellow"
                Write-ColorOutput ""
                Write-ColorOutput "⚠️  WARNING: This will FACTORY RESET the selected device(s)!" "Red"
                $wipeConfirm = Read-Host "Type 'WIPE' to confirm"
                if ($wipeConfirm -ne 'WIPE') {
                    Write-ColorOutput "Wipe cancelled. Exiting." "Yellow"
                    return
                }
            }
            "3" {
                $performWipe = $false
                $script:NoLoggingMode = $true
                $validChoice = $true
                Write-ColorOutput ""
                Write-ColorOutput "Mode: Remove records only - SKIP STATUS CHECKS" "Cyan"
                Write-ColorOutput "Status checks will be skipped. Commands will be sent and devices marked as processed." "Yellow"
            }
            "4" {
                $performWipe = $true
                $script:NoLoggingMode = $true
                $validChoice = $true
                Write-ColorOutput ""
                Write-ColorOutput "Mode: WIPE and remove records - SKIP STATUS CHECKS" "Yellow"
                Write-ColorOutput "Status checks will be skipped. Commands will be sent and devices marked as processed." "Yellow"
                Write-ColorOutput ""
                Write-ColorOutput "⚠️  WARNING: This will FACTORY RESET the selected device(s)!" "Red"
                $wipeConfirm = Read-Host "Type 'WIPE' to confirm"
                if ($wipeConfirm -ne 'WIPE') {
                    Write-ColorOutput "Wipe cancelled. Exiting." "Yellow"
                    return
                }
            }
            "5" {
                Write-ColorOutput "Cancelled." "Yellow"
                return
            }
            default {
                Write-ColorOutput "Invalid choice. Please try again." "Red"
            }
        }
    }

    # Process each selected device
    $results = @()
    foreach ($selectedDevice in $selectedDevices) {
        # Find the full device info
        $fullDevice = $enrichedDevices | Where-Object { $_.SerialNumber -eq $selectedDevice.SerialNumber }
        $deviceName = $fullDevice.DisplayName
        $deviceSerial = $fullDevice.SerialNumber

        $deviceResult = [PSCustomObject]@{
            SerialNumber = $deviceSerial
            DisplayName = $deviceName
            EntraID = @{ Found = $false; Success = $false; DeletedCount = 0; FailedCount = 0; Errors = @() }
            Intune = @{ Found = $false; Success = $false; Error = $null }
            Autopilot = @{ Found = $false; Success = $false; Error = $null }
            Wiped = $false
        }

        Write-ColorOutput ""
        Write-ColorOutput "Processing: $deviceName (Serial: $deviceSerial)" "Cyan"
        Write-ColorOutput "------------------------------" "DarkGray"

        # WIPE device first if requested
        if ($performWipe -and -not $WhatIfPreference) {
            $intuneDevice = Get-IntuneDevice -DeviceName $deviceName -SerialNumber $deviceSerial

            if ($intuneDevice) {
                Write-ColorOutput ""
                Write-ColorOutput "Step 1: Wiping device..." "Yellow"

                $wipeResult = Invoke-IntuneDeviceWipe -ManagedDeviceId $intuneDevice.id

                if ($wipeResult) {
                    Write-ColorOutput "✓ Wipe command sent" "Green"

                    # In No Logging mode, skip waiting for wipe completion
                    if ($script:NoLoggingMode) {
                        Write-ColorOutput "✓ Device processed for wipe (no status check)" "Cyan"
                        $deviceResult.Wiped = $true
                        $deviceResult.Intune.Success = $true
                        $deviceResult.Intune.Found = $true
                    } else {
                        # Force sync
                        Write-ColorOutput "Sending sync to force check-in..." "Yellow"
                        if (Invoke-IntuneDeviceSync -ManagedDeviceId $intuneDevice.id) {
                            Write-ColorOutput "✓ Sync command sent" "Green"
                        }

                        # Wait for wipe to complete
                        Write-ColorOutput ""
                        Write-ColorOutput "Step 2: Waiting for wipe to complete..." "Yellow"
                        $wipeComplete = Wait-ForDeviceWipe -ManagedDeviceId $intuneDevice.id -DeviceName $deviceName -TimeoutMinutes 30 -PollIntervalSeconds 30

                        if ($wipeComplete) {
                            $deviceResult.Wiped = $true
                            $deviceResult.Intune.Success = $true
                            $deviceResult.Intune.Found = $true
                            Write-ColorOutput ""
                            Write-ColorOutput "Step 3: Removing remaining records..." "Yellow"
                        } else {
                            Write-ColorOutput "Wipe did not complete. Skipping record removal for this device." "Red"
                            $results += $deviceResult
                            continue
                        }
                    }
                } else {
                    Write-ColorOutput "Failed to send wipe command. Skipping this device." "Red"
                    $results += $deviceResult
                    continue
                }
            } else {
                Write-ColorOutput "Device not found in Intune. Proceeding with record removal only." "Yellow"
            }
        } elseif ($performWipe -and $WhatIfPreference) {
            Write-ColorOutput "WHATIF: Would wipe device $deviceName" "Yellow"
        } else {
            Write-ColorOutput "Removing records for $deviceName..." "Cyan"
        }

        # Remove from Intune (skip if already removed by wipe)
        if (-not $deviceResult.Wiped) {
            $intuneResult = Remove-IntuneDevice -DeviceName $deviceName -SerialNumber $deviceSerial
            $deviceResult.Intune.Found = $intuneResult.Found
            $deviceResult.Intune.Success = $intuneResult.Success
            $deviceResult.Intune.Error = $intuneResult.Error
        }

        # Remove from Autopilot
        $autopilotResult = Remove-AutopilotDevice -DeviceName $deviceName -SerialNumber $deviceSerial
        $deviceResult.Autopilot.Found = $autopilotResult.Found
        $deviceResult.Autopilot.Success = $autopilotResult.Success
        $deviceResult.Autopilot.Error = $autopilotResult.Error

        # Remove from Entra ID
        $entraDeviceId = $fullDevice.EntraDeviceId
        $entraDevices = Get-EntraDeviceByName -DeviceName $deviceName -SerialNumber $deviceSerial -EntraDeviceId $entraDeviceId
        if ($entraDevices -and $entraDevices.Count -gt 0) {
            $deviceResult.EntraID.Found = $true
            $entraResult = Remove-EntraDevices -Devices $entraDevices -DeviceName $deviceName -SerialNumber $deviceSerial
            $deviceResult.EntraID.Success = $entraResult.Success
            $deviceResult.EntraID.DeletedCount = $entraResult.DeletedCount
            $deviceResult.EntraID.FailedCount = $entraResult.FailedCount
            $deviceResult.EntraID.Errors = $entraResult.Errors
        }

        # In No Logging mode, just show processed message and skip monitoring
        if ($script:NoLoggingMode) {
            # Get device ID from the original device data
            $deviceId = "N/A"
            $fullDeviceData = $enrichedDevices | Where-Object { $_.SerialNumber -eq $deviceSerial }
            if ($fullDeviceData -and $fullDeviceData.EntraDeviceId) {
                $deviceId = $fullDeviceData.EntraDeviceId
            }

            Write-ColorOutput ""
            Write-ColorOutput "✓ Device processed for removal" "Cyan"
            Write-ColorOutput "  Name:           $deviceName" "White"
            Write-ColorOutput "  Serial Number:  $deviceSerial" "White"
            Write-ColorOutput "  Device ID:      $deviceId" "White"
            Write-ColorOutput ""

            # Store device ID for CSV export
            $deviceResult | Add-Member -NotePropertyName "DeviceId" -NotePropertyValue $deviceId -Force
        }
        # Automatic monitoring after deletion (not in WhatIf mode and not in No Logging mode)
        elseif (-not $WhatIfPreference -and ($deviceResult.Autopilot.Success -or $deviceResult.Intune.Success -or $deviceResult.EntraID.Success)) {
            Write-ColorOutput ""
            Write-ColorOutput "Monitoring device removal..." "Cyan"

            $startTime = Get-Date
            $maxMonitorMinutes = 30 # Maximum monitoring time
            $endTime = $startTime.AddMinutes($maxMonitorMinutes)
            $checkInterval = 5 # seconds

            $autopilotRemoved = -not $deviceResult.Autopilot.Success
            $intuneRemoved = -not $deviceResult.Intune.Success
            $entraRemoved = -not $deviceResult.EntraID.Success


            do {
                Start-Sleep -Seconds $checkInterval

                # Set monitoring mode to suppress verbose messages
                $script:MonitoringMode = $true

                $currentTime = Get-Date
                $elapsedMinutes = [math]::Round(($currentTime - $startTime).TotalMinutes, 1)

                # Check Intune status first
                if (-not $intuneRemoved) {
                    Write-ColorOutput "Waiting for 1 of 1 to be removed from Intune (Elapsed: $elapsedMinutes min)" "Yellow"
                    try {
                        $intuneDevice = Get-IntuneDevice -DeviceName $deviceName -SerialNumber $deviceSerial
                        if (-not $intuneDevice) {
                            $intuneRemoved = $true
                            Write-ColorOutput "✓ Device removed from Intune" "Green"
                            $deviceResult.Intune.Verified = $true
                        }
                    }
                    catch {
                        Write-ColorOutput "  Error checking Intune: $($_.Exception.Message)" "Red"
                    }
                }

                # Check Autopilot status (only after Intune is removed)
                if ($intuneRemoved -and -not $autopilotRemoved) {
                    Write-ColorOutput "Waiting for 1 of 1 to be removed from Autopilot (Elapsed: $elapsedMinutes min)" "Yellow"
                    try {
                        $autopilotDevice = Get-AutopilotDevice -DeviceName $deviceName -SerialNumber $deviceSerial
                        if (-not $autopilotDevice) {
                            $autopilotRemoved = $true
                            Write-ColorOutput "✓ Device removed from Autopilot" "Green"
                            $deviceResult.Autopilot.Verified = $true
                        }
                    }
                    catch {
                        Write-ColorOutput "  Error checking Autopilot: $($_.Exception.Message)" "Red"
                    }
                }

                # Check Entra ID status (after both Intune and Autopilot are removed)
                if ($autopilotRemoved -and $intuneRemoved -and -not $entraRemoved) {
                    Write-ColorOutput "Waiting for 1 of 1 to be removed from Entra ID (Elapsed: $elapsedMinutes min)" "Yellow"
                    try {
                        $entraDevices = Get-EntraDeviceByName -DeviceName $deviceName -SerialNumber $deviceSerial -EntraDeviceId $entraDeviceId
                        if (-not $entraDevices -or $entraDevices.Count -eq 0) {
                            $entraRemoved = $true
                            Write-ColorOutput "✓ Device removed from Entra ID" "Green"
                            $deviceResult.EntraID.Verified = $true
                        }
                    }
                    catch {
                        Write-ColorOutput "  Error checking Entra ID: $($_.Exception.Message)" "Red"
                    }
                }


                # Exit if all services are cleared
                if ($autopilotRemoved -and $intuneRemoved -and $entraRemoved) {
                    $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)

                    # Get device ID from the original device data
                    $deviceId = "N/A"
                    $fullDeviceData = $enrichedDevices | Where-Object { $_.SerialNumber -eq $deviceSerial }
                    if ($fullDeviceData -and $fullDeviceData.EntraDeviceId) {
                        $deviceId = $fullDeviceData.EntraDeviceId
                    }

                    Write-ColorOutput ""
                    Write-ColorOutput "✓ Device successfully removed" "Green"
                    Write-ColorOutput "  Name:           $deviceName" "White"
                    Write-ColorOutput "  Serial Number:  $deviceSerial" "White"
                    Write-ColorOutput "  Device ID:      $deviceId" "White"
                    Write-ColorOutput "  Elapsed Time:   $elapsedTime minutes" "White"
                    Write-ColorOutput ""

                    # Play success notification
                    try {
                        [System.Console]::Beep(800, 300)
                        [System.Console]::Beep(1000, 300)
                        [System.Console]::Beep(1200, 500)
                    } catch { }

                    break
                }

            } while ((Get-Date) -lt $endTime)

            # Reset monitoring mode
            $script:MonitoringMode = $false

            # Check for timeout
            if ((Get-Date) -ge $endTime) {
                Write-ColorOutput ""
                Write-ColorOutput "⚠ Monitoring timeout reached after $maxMonitorMinutes minutes" "Red"
                Write-ColorOutput "Some devices may still be present in the services" "Yellow"
            }
        }

        $results += $deviceResult
    }

    # Export CSV for removals in No Logging mode
    if ($script:NoLoggingMode -and $results.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $csvPath = Join-Path -Path (Get-Location) -ChildPath "DeviceRemoval_$timestamp.csv"

        # Build CSV export data
        $csvData = foreach ($result in $results) {
            # Get device ID from enriched data if not already stored
            $deviceId = $result.DeviceId
            if (-not $deviceId) {
                $fullDeviceData = $enrichedDevices | Where-Object { $_.SerialNumber -eq $result.SerialNumber }
                if ($fullDeviceData -and $fullDeviceData.EntraDeviceId) {
                    $deviceId = $fullDeviceData.EntraDeviceId
                } else {
                    $deviceId = "N/A"
                }
            }

            [PSCustomObject]@{
                "Device Display Name" = $result.DisplayName
                "Serial Number" = $result.SerialNumber
                "Device ID" = $deviceId
                "Wipe Sent" = if ($result.Wiped) { "Yes" } else { "No" }
                "Intune Removal Sent" = if ($result.Intune.Success) { "Yes" } else { "No" }
                "Autopilot Removal Sent" = if ($result.Autopilot.Success) { "Yes" } else { "No" }
                "Entra Removal Sent" = if ($result.EntraID.Success) { "Yes" } else { "No" }
                "Processed Time" = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }

        try {
            $csvData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            Write-ColorOutput ""
            Write-ColorOutput "✓ CSV export complete" "Green"
            Write-ColorOutput "  File: $csvPath" "White"
            Write-ColorOutput "  Devices: $($results.Count)" "White"
        }
        catch {
            Write-ColorOutput "Failed to export CSV: $($_.Exception.Message)" "Red"
        }
    }
}
