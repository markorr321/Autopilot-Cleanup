# 🧹 Autopilot Cleanup Tool

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

## 📋 Prerequisites

- PowerShell 5.1 or later
- Microsoft Graph PowerShell SDK modules (auto-installed if missing):
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.DeviceManagement`
  - `Microsoft.Graph.Identity.DirectoryManagement`

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

## 🚀 Usage

### 🎯 Basic Usage

```powershell
.\Autopilot-CleanUp.ps1
```

1. Script will check for required modules and prompt to install if missing
2. Connects to Microsoft Graph (you'll be prompted to sign in)
3. Retrieves all Autopilot devices and enriches with Intune/Entra ID data
4. Displays interactive grid view with all devices
5. **Select the device(s) you want to remove and press OK (or hit Enter)**
6. Confirms deletion from all three services
7. Monitors removal progress in real-time

### 🧪 WhatIf Mode (Test Run)

Preview what would be deleted without making actual changes:

```powershell
.\Autopilot-CleanUp.ps1 -WhatIf
```

## 📝 Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-WhatIf` | Switch | No | Preview mode - shows what would be deleted without performing actual deletions |

## 🔧 How It Works

1. **Module Validation** - Verifies required PowerShell modules are installed
2. **Authentication** - Connects to Microsoft Graph with required scopes
3. **Data Retrieval** - Fetches all Autopilot devices and enriches with Intune/Entra ID information
4. **Device Selection** - Displays interactive Out-GridView where you select devices to remove
   - **⚠️ Important**: Select the device(s) and click OK or press Enter to confirm selection
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

**✅ To select devices**: Check the checkbox next to each device you want to remove, then click **OK** or press **Enter**.

## 📺 Example Output

```
=================================================
    Intune and Autopilot Offboarding PS1
=================================================

Checking required PowerShell modules...
✓ Module 'Microsoft.Graph.Authentication' is already installed
✓ Module 'Microsoft.Graph.DeviceManagement' is already installed
✓ Module 'Microsoft.Graph.Identity.DirectoryManagement' is already installed
All required modules are installed.

Connecting to Microsoft Graph...
✓ Successfully connected to Microsoft Graph

Retrieving all Autopilot devices...
Found 15 Autopilot devices

Enriching device information...

✓ Successfully queued device DESKTOP-ABC123 for removal from Intune
✓ Successfully queued device DESKTOP-ABC123 for removal from Autopilot
✓ Successfully queued device DESKTOP-ABC123 for removal from Entra ID

Monitoring device removal...
✓ Device removed from Intune
✓ Device removed from Autopilot
✓ Device removed from Entra ID
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

## 📜 Version History

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
