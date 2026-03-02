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

    .PARAMETER WhatIf
        Preview mode that shows what would be deleted without performing actual deletions.

    .EXAMPLE
        Start-AutopilotCleanup

    .EXAMPLE
        Start-AutopilotCleanup -ClientId "b7463ebe-e5a7-4a1a-ba64-34b99135a27a" -TenantId "51eb883f-451f-4194-b108-4df354b35bf4"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(HelpMessage = "Client ID of the app registration to use for delegated auth")]
        [string]$ClientId,

        [Parameter(HelpMessage = "Tenant ID to use with the specified app registration")]
        [string]$TenantId
    )

    # Check for module updates
    Test-ModuleUpdate

    # Build parameters to forward
    $invokeParams = @{}
    if ($WhatIfPreference) { $invokeParams['WhatIf'] = $true }
    if ($ClientId) { $invokeParams['ClientId'] = $ClientId }
    if ($TenantId) { $invokeParams['TenantId'] = $TenantId }

    Invoke-AutopilotCleanup @invokeParams
}
