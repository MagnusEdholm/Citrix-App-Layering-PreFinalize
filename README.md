# Citrix App Layering – Maintenance and Pre-Finalize Script

A PowerShell script for maintaining and safely finalizing **Citrix App Layering** OS, Application, and Platform Layers on **Windows Server 2022**.

The script was created from real-world troubleshooting of Citrix App Layering environments, with a focus on reducing common finalization problems caused by pending operations, Microsoft Edge / WebView2 updates, RunOnce entries, servicing activity, and other state left behind during layer maintenance.

> **Important:** Test the script in a non-production environment before using it in production.

---

## Why this script exists

Citrix App Layering can become difficult to troubleshoot when an OS Layer or Application Layer has been maintained for a long time.

Typical issues include:

- `RunOnce` entries blocking **Shutdown for Finalize**
- pending reboot states
- `PendingFileRenameOperations`
- Windows Installer or servicing processes still running
- Microsoft Edge / WebView2 updates starting during layer maintenance
- Edge Update processes remaining active
- old or mixed Edge versions appearing in Application Layers
- unnecessary cleanup routines from older image-preparation scripts

The goal of this script is to provide a **consistent and conservative maintenance/finalization workflow** without using aggressive cleanup methods that can create additional problems.

---

## Supported layer types

The script supports:

- **OS Layer**
- **Application Layer**
- **Platform Layer**

The behavior changes depending on the selected layer type.

---

## OS Layer behavior

The OS Layer is where Windows, Microsoft Edge, WebView2, .NET, and other shared operating system components should normally be maintained.

### Start maintenance mode

When opening a new OS Layer version for maintenance, run:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType OS -StartMaintenance
```

This prepares the OS Layer for maintenance by:

- removing the Edge/WebView2 restrictions applied by the script during the previous finalize
- setting Edge Update services to `Manual`
- enabling Edge Update scheduled tasks
- attempting to start the available Edge Update services
- verifying that the OS Layer is ready for maintenance

You can then perform:

- Windows Update
- Microsoft Edge updates
- WebView2 Runtime updates
- .NET updates
- Defender/platform updates
- other operating system maintenance

Reboot the packaging machine as required during maintenance.

### Finalize the OS Layer

When maintenance is complete, run:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType OS
```

Before finalization, the script:

- sets Edge Update to manual-update behavior
- prevents automatic WebView2 Runtime updates
- stops Edge Update processes
- stops Edge Update services and leaves them set to `Manual`
- disables Edge Update scheduled tasks
- performs all common pre-finalize checks
- performs safe cleanup
- verifies the final Edge/WebView2 state
- asks before running Citrix `ShutdownForFinalize.cmd`

---

## Application Layer behavior

For a normal Application Layer, run:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType App
```

Application Layer mode is intentionally conservative.

The script does **not** permanently change:

- Edge Update policies
- Edge Update service startup types
- Edge Update scheduled tasks
- WebView2 update policies

This is important because Edge and WebView2 should normally be maintained in the **OS Layer**, not written into individual Application Layers.

The script may temporarily stop an active Edge Update process so that it does not interfere with finalization.

---

## Platform Layer behavior

For a Platform Layer:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType Platform
```

Platform Layer mode uses the same conservative Edge handling as Application Layer mode.

---

## Common pre-finalize checks

The script performs several checks before finalization.

### RunOnce

The following locations are checked:

```text
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce
HKLM\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\RunOnce
HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce
```

HKLM RunOnce entries are treated as blocking conditions because they can prevent Citrix App Layering from finalizing a layer.

### Pending reboot

The script checks common reboot indicators including:

- Windows Update `RebootRequired`
- Component Based Servicing `RebootPending`
- Component Based Servicing `RebootInProgress`
- Windows Installer activity
- pending computer rename

### PendingFileRenameOperations

The script checks:

```text
HKLM\SYSTEM\CurrentControlSet\Control\Session Manager
```

for:

```text
PendingFileRenameOperations
```

### Installation and servicing processes

The script looks for processes such as:

```text
msiexec
TiWorker
TrustedInstaller
setup
setuphost
```

### Microsoft Edge

The script reports the active Microsoft Edge version from:

```text
C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe
```

and lists installed Edge version directories.

This is useful when troubleshooting Application Layers that may contain older Edge components.

---

## Safe cleanup

By default, the script performs conservative cleanup of:

- Windows temporary files
- user temporary files
- Recycle Bin
- DNS cache

It deliberately does **not**:

- clear Windows Event Logs
- delete `SoftwareDistribution`
- automatically remove ghost devices
- run NGEN by default

These operations were commonly used in older image-preparation scripts but are intentionally avoided here unless specifically requested.

---

## Ghost device reporting

To report non-present/problem devices:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType App -ReportGhostDevices
```

No devices are automatically removed.

For troubleshooting an older or sensitive Application Layer:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType App -NoShutdown -ReportGhostDevices
```

---

## NGEN

NGEN is disabled by default.

If a specific application or vendor explicitly requires it:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType App -RunNgen
```

Do not use `-RunNgen` as part of the normal workflow unless there is a specific requirement.

---

## Parameters

| Parameter | Description |
|---|---|
| `-LayerType OS` | OS Layer mode with OS-specific Edge/WebView2 handling |
| `-LayerType App` | Application Layer mode. This is the default if no LayerType is specified |
| `-LayerType Platform` | Platform Layer mode |
| `-StartMaintenance` | OS Layer only. Enables maintenance mode for Windows/Edge/WebView2 updates |
| `-NoShutdown` | Runs checks and cleanup but does not run Shutdown for Finalize |
| `-AutoFinalize` | Automatically starts Shutdown for Finalize if no blocking errors are found |
| `-SkipCleanup` | Skips TEMP, Recycle Bin, and DNS cleanup |
| `-ReportGhostDevices` | Reports non-present/problem devices without removing them |
| `-RunNgen` | Runs .NET Framework NGEN update. Disabled by default |

---

## Recommended workflows

### OS Layer

Start maintenance:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType OS -StartMaintenance
```

Perform Windows/Edge/WebView2 maintenance and reboot as required.

Optional check-only pass:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType OS -NoShutdown
```

Finalize:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType OS
```

### Application Layer

Normal finalize:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType App
```

Troubleshooting / sensitive older Application Layer:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType App -NoShutdown -ReportGhostDevices
```

### Platform Layer

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType Platform
```

---

## Script output

The script uses clear status messages:

- `[PASS]` – check passed
- `[INFO]` – informational message
- `[WARNING]` – review before finalizing
- `[FAIL]` – blocking problem found

If a blocking error is detected, the script will not proceed with Shutdown for Finalize.

---

## Logging

Each run is logged using PowerShell transcript logging.

Logs are written to:

```text
C:\Windows\Temp
```

with a timestamped filename similar to:

```text
Citrix-Layer-PreFinalize_20261002_155107.log
```

---

## Shutdown for Finalize

When all checks are complete, the script uses the Citrix App Layering command:

```text
C:\Program Files\Unidesk\Uniservice\ShutdownForFinalize.cmd
```

By default, the administrator is prompted before shutdown.

To automatically finalize if no blocking errors are found:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType OS -AutoFinalize
```

---

## Default behavior

If the script is run without specifying `-LayerType`:

```powershell
.\Citrix-Layer-PreFinalize.ps1
```

it defaults to:

```text
LayerType = App
```

Application Layer mode is the safest default because it does not persistently modify Edge/WebView2 update configuration.

---

## Requirements

- Windows Server 2022
- Windows PowerShell 5.1
- Citrix App Layering Packaging Machine
- Run PowerShell as Administrator

---

## Disclaimer

This script is provided as-is.

Always test changes in a non-production environment before using them in production. Review the output before finalizing a layer, especially when warnings or pending operations are reported.

Environment-specific software, security policies, servicing tools, and Citrix App Layering versions may require additional validation.

---

## Author

**Magnus Edholm**  
AceIQ AB

Solutions Architect  
Citrix DaaS | Citrix App Layering | WEM | NetScaler | Microsoft Azure

This script was developed from practical troubleshooting and maintenance work in Citrix App Layering environments.

