# 🧹 Autopilot Cleanup

[![Watch a Demo](https://img.youtube.com/vi/SLvbbjJCvHo/hqdefault.jpg)](https://youtu.be/SLvbbjJCvHo?si=lavT9N1emduIkFCH)

[Watch a Demo](https://youtu.be/SLvbbjJCvHo?si=lavT9N1emduIkFCH)


Interactive PowerShell tool for bulk device cleanup across Windows Autopilot, Microsoft Intune, and Microsoft Entra ID. Features automatic module installation, serial number validation, real-time deletion monitoring, and WhatIf mode for safe testing.

## ✨ Features

- 📦 **Automatic Module Installation** - Checks for required Microsoft Graph modules and prompts to install missing dependencies
- 🖱️ **Interactive Device Selection** - Grid view interface to select devices for removal
- 🔄 **Multi-Service Cleanup** - Removes devices from all three services (Autopilot, Intune, and Entra ID)
- 🔍 **Serial Number Validation** - Prevents accidental deletion of devices with duplicate names
- 📊 **Real-Time Monitoring** - Tracks deletion progress with automatic verification
- 👥 **Duplicate Handling** - Identifies and processes duplicate device entries
- 🧪 **WhatIf Mode** - Preview deletions without making actual changes
- ⚙️ **Edge Case Management** - Handles pending deletions, missing devices, and other scenarios
- 🔔 **Sound Notifications** - Plays success beeps when cleanup is complete

## ✨ New Features

- 🔑 **Custom App Registration** - Configure a custom Entra app registration with persistent environment variables via `Configure-AutopilotCleanup` / `Clear-AutopilotCleanupConfig`
- 🚀 **Start-AutopilotCleanup** - Module entry point command, just like `Start-EntraPIM` — run after `Import-Module AutopilotCleanup`
- 🔄 **Automatic Update Check** - Checks PowerShell Gallery for newer versions on launch (supports both `Update-Module` and `Update-PSResource`)
- 🚀 **Fast Bulk Removal Mode** - Supports bulk removal **without status checking**, with results exported to a **CSV** for review
- 🏷️ **GroupTag Filtering in Out Grid View** - Out-GridView device selection now supports **filtering by GroupTag**

## 📋 Prerequisites

- PowerShell 5.1 or later
- Required module (auto-installed if missing):
  - `Microsoft.Graph.Authentication`

## 🔐 Required Permissions

Your account needs the following Microsoft Graph API permissions:

- `Device.ReadWrite.All`
- `DeviceManagementManagedDevices.ReadWrite.All`
- `DeviceManagementServiceConfig.ReadWrite.All`

## 💻 Installation

1. Clone or download this repository
2. Open PowerShell
3. Navigate to the script directory
4. Run the script - it will automatically check and install required modules

```powershell
cd C:\Autopilot-Cleanup
.\Autopilot-CleanUp.ps1
```

Or import the module and use the `Start-AutopilotCleanup` command:

```powershell
Import-Module .\AutopilotCleanup
Start-AutopilotCleanup
```

## 🚀 Usage

### 🎯 Basic Usage

```powershell
.\Autopilot-CleanUp.ps1
```

1. Script will check for required modules and prompt to install if missing
2. Connects to Microsoft Graph (you'll be prompted to sign in)
3. Retrieves all Autopilot devices and enriches with Intune/Entra ID data
4. Displays interactive grid view with all devices
5. **Select device(s) using Ctrl+Click for multiple selection, then press OK**
6. Confirms deletion from all three services
7. Monitors removal progress in real-time

### 🔑 Custom App Registration

Configure a custom app registration for delegated auth (persists across sessions):

```powershell
Import-Module .\AutopilotCleanup
Configure-AutopilotCleanup
```

Or pass credentials directly:

```powershell
.\Autopilot-CleanUp.ps1 -ClientId "your-client-id" -TenantId "your-tenant-id"
```

To clear saved configuration:

```powershell
Clear-AutopilotCleanupConfig
```

**Priority order:** command-line parameters > environment variables > default auth flow

**Required app registration settings:**
- Platform: Mobile and desktop applications
- Redirect URI: `http://localhost`
- Allow public client flows: Yes
- API Permissions (delegated): `Device.ReadWrite.All`, `DeviceManagementManagedDevices.ReadWrite.All`, `DeviceManagementManagedDevices.PrivilegedOperations.All`, `DeviceManagementServiceConfig.ReadWrite.All`

### 🧪 WhatIf Mode (Test Run)

Preview what would be deleted without making actual changes:

```powershell
.\Autopilot-CleanUp.ps1 -WhatIf
```

## 📝 Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-WhatIf` | Switch | No | Preview mode - shows what would be deleted without performing actual deletions |
| `-ClientId` | String | No | Client ID of a custom app registration for delegated auth |
| `-TenantId` | String | No | Tenant ID to use with the custom app registration |

## 🔧 How It Works

1. **Module Validation** - Verifies required PowerShell modules are installed
2. **Authentication** - Connects to Microsoft Graph with required scopes
3. **Data Retrieval** - Fetches all Autopilot devices and enriches with Intune/Entra ID information
4. **Device Selection** - Displays interactive Out-GridView where you select devices to remove
   - **⚠️ Important**: Use Ctrl+Click to select multiple devices, then click OK to confirm
   - Selection works like Windows Explorer (highlight-based, not checkboxes)
5. **Deletion Process** - Removes selected devices in the following order:
   - Microsoft Intune (management layer)
   - Windows Autopilot (deployment service)
   - Microsoft Entra ID (identity source)
6. **Verification** - Monitors and confirms successful removal from all services

## 📋 Device Selection Grid

The Out-GridView displays the following information:

| Column | Description |
|--------|-------------|
| DisplayName | Device display name |
| SerialNumber | Hardware serial number |
| Model | Device model |
| Manufacturer | Device manufacturer |
| GroupTag | Autopilot group tag |
| DeploymentProfile | Assigned deployment profile |
| IntuneFound | Whether device exists in Intune |
| EntraFound | Whether device exists in Entra ID |
| IntuneName | Device name in Intune |
| EntraName | Device name in Entra ID |

**✅ To select devices**:
- **Single device**: Click on the device row, then click **OK**
- **Multiple devices**: Hold **Ctrl** and click on each device you want to select
- **Range of devices**: Click the first device, hold **Shift**, and click the last device
- **All devices**: Press **Ctrl+A** to select all
- Click **OK** when finished selecting

*Note: Out-GridView uses highlight selection (like Windows Explorer) rather than checkboxes. Use Ctrl+Click to build your multi-selection.*

## 📺 Example Output

```
[ A U T O P I L O T   C L E A N U P ]  v2.0.0
    with PowerShell

Auth: Default Microsoft Graph (delegated)

Checking required PowerShell modules...
✓ Module 'Microsoft.Graph.Authentication' is already installed
All required modules are installed.

Connecting to Microsoft Graph...
✓ Successfully connected to Microsoft Graph

Fetching all Autopilot devices...
Found 15 Autopilot devices

Processing: DESKTOP-ABC123 (Serial: 1234-5678-9012)
------------------------------

Step 1: Removing from Intune...
✓ Successfully queued device for removal from Intune

Step 2: Removing from Autopilot...
✓ Successfully queued device for removal from Autopilot

Step 3: Removing from Entra ID...
✓ Successfully queued device for removal from Entra ID

✓ Device successfully removed
  Name:           DESKTOP-ABC123
  Serial Number:  1234-5678-9012
```

## ⚠️ Important Notes

- 🚨 **Deletion is permanent** - Devices removed from these services cannot be easily restored
- 🔢 **Serial number validation** - The script validates serial numbers to prevent accidental deletion of duplicate device names
- ⚡ **Deletion order matters** - Devices are removed in the correct order (Intune → Autopilot → Entra ID) to prevent dependency issues
- ⏱️ **Monitoring timeout** - The script monitors deletion progress for up to 30 minutes
- 👤 **No admin required** - Module installation uses CurrentUser scope, avoiding the need for administrator privileges
- 🔔 **Success notification** - Three ascending beeps play when device cleanup is successfully verified across all services

## 🔧 Troubleshooting

### ❌ Modules Won't Install
- Ensure you have internet connectivity
- Run PowerShell with appropriate permissions
- Manually install modules: `Install-Module -Name Microsoft.Graph -Scope CurrentUser`

### 🔒 Authentication Fails
- Verify your account has the required Graph API permissions
- Check if MFA is properly configured
- Try disconnecting and reconnecting: `Disconnect-MgGraph` then run the script again

### 🔍 Device Not Found
- Device may already be deleted
- Serial number or device name may be incorrect
- Check if device exists in each service individually

### ⏳ Deletion Hangs
- Large deletions can take time (up to 30 minutes)
- Check Azure portal to verify deletion status
- Script will timeout after 30 minutes of monitoring

## ⚙️ Environment Variables

| Variable | Description |
|----------|-------------|
| `AUTOPILOTCLEANUP_CLIENTID` | Saved app registration Client ID (set via `Configure-AutopilotCleanup`) |
| `AUTOPILOTCLEANUP_TENANTID` | Saved Tenant ID (set via `Configure-AutopilotCleanup`) |
| `AUTOPILOTCLEANUP_DISABLE_UPDATE_CHECK` | Set to `true` to skip the update check on launch |

## 📜 Version History

**Version 2.1**
- Custom app registration support (`Configure-AutopilotCleanup` / `Clear-AutopilotCleanupConfig`)
- `Start-AutopilotCleanup` module entry point
- Automatic update check from PowerShell Gallery
- Cleaner console UI

**Version 2.0**
- Enhanced description and documentation
- Automatic module installation with validation
- Improved error handling
- Better serial number validation
- Real-time monitoring improvements

## 👨‍💻 Author

**Mark Orr**  
[![LinkedIn](https://img.shields.io/badge/LinkedIn-Connect-blue?style=flat&logo=linkedin)](https://www.linkedin.com/in/markorr321/)

## 📄 License

This script is provided as-is without warranty. Use at your own risk.
