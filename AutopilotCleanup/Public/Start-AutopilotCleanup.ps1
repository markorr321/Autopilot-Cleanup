function Start-AutopilotCleanup {
    <#
    .SYNOPSIS
        Launches the Autopilot Cleanup tool.

    .DESCRIPTION
        Opens an interactive console application for bulk removal of devices from
        Windows Autopilot, Microsoft Intune, and Microsoft Entra ID.

        If ClientId and TenantId are not provided as parameters, the function will
        check for environment variables set via Configure-AutopilotCleanup. If neither
        are found, it uses the default authentication flow.

    .PARAMETER ClientId
        Client ID of the app registration to use for delegated auth.
        If not provided, checks AUTOPILOTCLEANUP_CLIENTID environment variable.

    .PARAMETER TenantId
        Tenant ID to use with the specified app registration.
        If not provided, checks AUTOPILOTCLEANUP_TENANTID environment variable.

    .PARAMETER SerialNumber
        One or more device serial numbers to target for removal.
        When provided, bypasses the interactive device selection grid and
        automatically selects the matching devices for the cleanup routine.

    .PARAMETER WhatIf
        Preview mode that shows what would be deleted without performing actual deletions.

    .EXAMPLE
        Start-AutopilotCleanup

    .EXAMPLE
        Start-AutopilotCleanup -SerialNumber "ABC1234"

    .EXAMPLE
        Start-AutopilotCleanup -SerialNumber "ABC1234", "DEF5678", "GHI9012"

    .EXAMPLE
        Start-AutopilotCleanup -ClientId "b7463ebe-e5a7-4a1a-ba64-34b99135a27a" -TenantId "51eb883f-451f-4194-b108-4df354b35bf4"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(HelpMessage = "Client ID of the app registration to use for delegated auth")]
        [string]$ClientId,

        [Parameter(HelpMessage = "Tenant ID to use with the specified app registration")]
        [string]$TenantId,

        [Parameter(HelpMessage = "One or more serial numbers to target for removal. Bypasses the device selection grid.")]
        [string[]]$SerialNumber
    )

    # Check for module updates
    Test-ModuleUpdate

    # Build parameters to forward
    $invokeParams = @{}
    if ($WhatIfPreference) { $invokeParams['WhatIf'] = $true }
    if ($ClientId) { $invokeParams['ClientId'] = $ClientId }
    if ($TenantId) { $invokeParams['TenantId'] = $TenantId }
    if ($SerialNumber) { $invokeParams['SerialNumber'] = $SerialNumber }

    Invoke-AutopilotCleanup @invokeParams
}
