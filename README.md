# Citrix App Layering – Maintenance and Pre-Finalize

PowerShell maintenance and pre-finalization workflow for Citrix App Layering **OS, Application and Platform Layers**.

Created from real-world troubleshooting on Windows Server 2022, with a focus on layer integrity, Edge/WebView2 update control and a repeatable **Shutdown for Finalize** workflow.

**Current version: v1.3.0**  
**Last updated:** 2026-10-23  
**Script:** `Citrix-Layer-PreFinalize.ps1`  
**Author:** Magnus Edholm – Solutions Architect, AceIQ  
**License:** MIT

[Repository](https://github.com/MagnusEdholm/Citrix-App-Layering-PreFinalize) · [Releases](https://github.com/MagnusEdholm/Citrix-App-Layering-PreFinalize/releases) · [Report an issue](https://github.com/MagnusEdholm/Citrix-App-Layering-PreFinalize/issues)

## What's new in v1.3.0

- **Conditional OneDrive handling:** runs only in OS Layer mode and only when an installed OneDrive sync client is detected.
- **Policy-aware finalization:** sets the OneDrive update ring to Deferred only when no ring policy already exists, and preserves existing ring policies.
- **Maintenance recovery:** removes only the script-owned, unchanged Deferred override when starting OS Layer maintenance.
- **Finalize safety:** blocks finalization while the OneDrive sync client, standalone updater or setup process is running, and checks again immediately before handing off to Citrix.
- **OS reporting:** reports the detected Windows caption, version and build for troubleshooting.

The Platform Layer FSLogix/WEM checks and NGEN final-state improvements from v1.2.0 are retained. No new command-line parameters are required.

> Deferred is an update ring, not an update-disable mechanism. OneDrive tasks and services remain unchanged, and an idle-process check cannot guarantee an update-free capture.

## Included improvements from v1.2.0

**All v1.2.0 improvements are included in v1.3.0.** In addition to the new OneDrive handling, this release retains these important pre-finalize checks:

### Platform Layer: FSLogix altitude validation and remediation

With **`-LayerType Platform`**, the script checks the FSLogix `frxdrvvt` driver altitude. If the applicable configuration has an incorrect or missing altitude value, it sets it to **`138010`**, then reads the value back to verify the correction.

### Platform Layer: Citrix WEM RSA key detection and removal

With **`-LayerType Platform`**, the script detects and removes only files with the known WEM RSA key prefix:

```text
C:\ProgramData\Microsoft\Crypto\RSA\S-1-5-18\
fb8cc9e38d3e60ab60c17cdfd6dd6d99_*
```

It verifies that matching files are gone afterward. Unrelated RSA key files are not targeted.

### NGEN: final integrity state determines readiness

The script re-checks NGEN pending work and process activity after automatic queue processing. An architecture-specific non-zero NGEN exit code no longer leaves a permanent blocking error when the final checks confirm that **`WorkPending = 0`** in both applicable registry views and compilation has finished.

Unresolved pending work or active compilation still blocks readiness. Successfully resolved initial pending work does not remain as a stale warning.

> FSLogix and WEM remediation is specific to Platform Layers. NGEN integrity handling applies across OS, Application and Platform Layers. `-NoShutdown` still performs applicable remediation; it only suppresses Shutdown for Finalize.

## Why this script exists

A packaging machine can appear ready while Windows or an installed component still has unfinished work. Typical causes of finalization problems include:

- Machine-wide `RunOnce` entries, including Edge/WebView2 cleanup operations.
- Pending reboots, file rename operations or computer rename operations.
- Active Windows Installer, Windows servicing or setup processes.
- Queued .NET Framework NGEN work or active compilation.
- Edge Update processes and update configuration that conflict with the intended layer state.
- Platform Layer-specific FSLogix and WEM integrity requirements.
- Active OneDrive clients, setup or updater processes in OS Layers with OneDrive installed.

The script checks these conditions before invoking Citrix's own finalization command. It also provides controlled OS Layer maintenance and conservative cleanup without deleting Windows Event Logs, Windows Update cache or devices.

**Citrix's Layer Integrity check remains authoritative.** A successful script result is a readiness assessment, not a guarantee that Citrix will accept or finalize the layer.

## Tested and intended platforms

| Platform | Validation status |
| --- | --- |
| Windows Server 2022 | Tested in the project environment |
| Windows Server 2025 | Intended compatibility; validation pending |
| Windows 11 | Intended compatibility; validation pending |
| Windows 11 Multi-Session | Intended compatibility; validation pending |

The checks largely use standard Windows components, but that does not establish full validation on every Windows build. No fully tested support claim is made for Server 2025 or Windows 11 variants in v1.2.0.

Script compatibility and Citrix product support are separate. Verify the exact Windows edition/build, App Layering release, hypervisor and VDA combination against the [Citrix App Layering documentation](https://docs.citrix.com/en-us/citrix-app-layering) before use.

## Requirements

- A Citrix App Layering packaging machine with the appropriate layer open for editing.
- An elevated Windows PowerShell session with local administrator rights. Windows PowerShell 5.1 is the recommended host; PowerShell 7 is not claimed as validated here.
- The v1.2.0 script, reviewed before execution and permitted by your organization's execution policy.
- Citrix's `ShutdownForFinalize.cmd` for the integrated finalization step, normally located at:

  ```text
  C:\Program Files\Unidesk\Uniservice\ShutdownForFinalize.cmd
  ```

- Installed .NET Framework NGEN tools where NGEN processing is applicable.
- The optional `PnpDevice` module for ghost-device reporting.
- A recoverable layer version or equivalent rollback plan before applying changes.

FSLogix and WEM are optional components, not prerequisites for every layer. Their checks are relevant to Platform Layers where those components or their artifacts exist.

## Quick start

Download the script from [Releases](https://github.com/MagnusEdholm/Citrix-App-Layering-PreFinalize/releases), confirm that its header identifies **1.3.0**, and save it as `Citrix-Layer-PreFinalize.ps1`. If using the supplied `Citrix-Layer-PreFinalize-v1.3.0.ps1` filename, either rename it or substitute that name in the examples.

Open **Windows PowerShell as Administrator**, change to the script directory and start with a run that does not shut down the packaging machine:

```powershell
Set-Location C:\Install
.\Citrix-Layer-PreFinalize.ps1 -LayerType Platform -NoShutdown
```

Review the console output and transcript before running without `-NoShutdown`.

> **`-NoShutdown` is not a dry run.** Normal configuration changes, cleanup and applicable remediation still run. In Platform mode this includes FSLogix altitude correction and removal of matching WEM RSA key files.

## Parameters

| Parameter | Purpose |
| --- | --- |
| `-LayerType <OS\|App\|Platform>` | Selects layer-specific behavior. Default: `App`. Specify it explicitly in operational workflows. |
| `-StartMaintenance` | Opens OS Layer maintenance mode for Edge/WebView2 and removes the script-owned, unchanged OneDrive Deferred override when applicable. Use with `-LayerType OS`; other layer types are rejected. |
| `-NoShutdown` | Runs normal preparation and checks without invoking Shutdown for Finalize. Does not suppress changes or remediation. |
| `-AutoFinalize` | Starts the finalization command without the normal confirmation prompt when the script permits finalization. Review warnings before choosing this mode. |
| `-SkipCleanup` | Skips normal temporary-file cleanup. Other checks and applicable configuration/remediation still apply. |
| `-ReportGhostDevices` | Reports problematic/non-present devices when the required module is available. Does not remove devices. |
| `-RunNgen` | Requests a full `ngen.exe update`. Separate from automatic processing of Citrix-required priority-3 queued work. Use when needed rather than routinely. |

## Layer-specific behavior

| Operation | OS | Application (`App`) | Platform |
| --- | --- | --- | --- |
| Common integrity/readiness checks | Yes | Yes | Yes |
| Automatic NGEN queue handling when needed | Yes | Yes | Yes |
| Persistent Edge/WebView2 update configuration | Yes | No | No |
| OS maintenance mode | Yes | Not intended | Not intended |
| OneDrive policy and idle checks, if installed | Yes | No | No |
| FSLogix altitude validation/remediation | No | No | Yes |
| Known WEM RSA key detection/removal | No | No | Yes |
| Cleanup and optional device reporting | Yes | Yes | Yes |
| Citrix Shutdown for Finalize integration | Yes | Yes | Yes |

### OS Layer: Edge and WebView2

During `-StartMaintenance`, the script removes its finalize-time Edge/WebView2 update restrictions, sets relevant Edge services to `Manual`, enables Edge Update scheduled tasks and attempts to start relevant update services. Perform updates and reboots as required afterward; maintenance mode does not itself install all updates.

During normal OS pre-finalization, the script:

- Applies Edge Update `UpdateDefault = 2` (manual updates only).
- Applies the WebView2 Runtime update override `Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5} = 0`.
- Stops applicable Edge Update services while leaving their startup type at `Manual`.
- Disables Edge Update scheduled tasks and stops active updater processes.
- Verifies the resulting configuration.

Relevant services include `edgeupdate`, `edgeupdatem` and `MicrosoftEdgeElevationService` when present. These settings require an ongoing maintenance process so that Edge/WebView2 security updates continue to be applied to the OS Layer.

### OS Layer: OneDrive (v1.3.0)

OneDrive handling is gated by **`-LayerType OS`** and installed-client detection. The script looks for `OneDrive.exe` under machine-wide installation directories and local profile installation paths, and also checks for a running OneDrive client. An inbox `OneDriveSetup.exe` alone is not considered an installed sync client.

If OneDrive is not detected, the script logs that OneDrive handling is skipped. Detection errors are reported as blocking failures rather than being silently treated as absence. Application and Platform modes do not run this OneDrive handling.

#### Before finalization

The script reads:

```text
HKLM\SOFTWARE\Policies\Microsoft\OneDrive
Value: GPOSetUpdateRing
```

- If no ring value exists, it writes DWORD **`0` (Deferred)** and verifies it.
- If a ring value already exists, it preserves that value. Values outside `0`, `4` and `5` generate a warning for review.
- It records ownership of its override using `ManagedDeferred = 1` under `HKLM\SOFTWARE\CitrixLayerPreFinalize\OneDrive`.
- It reports scheduled tasks whose actions invoke `OneDriveStandaloneUpdater.exe`, leaving their state unchanged. Already-disabled tasks generate a warning; the script does not re-enable them.

The script checks for these processes and records a blocking failure if any is active:

```text
OneDrive.exe
OneDriveStandaloneUpdater.exe
OneDriveSetup.exe
```

Finish updates, close OneDrive normally, reboot if required, and rerun the script. It does not force-kill the client or an installer. Process state is checked during preparation and again after confirmation, immediately before Citrix handoff, including with `-AutoFinalize`.

#### Starting maintenance

With `-LayerType OS -StartMaintenance`, the script removes `GPOSetUpdateRing` only when its ownership marker exists and the current value is still `0`. It then clears its ownership marker. A pre-existing ring policy or a subsequently changed ring value is preserved.

This removes the script's own restriction rather than forcing a Production ring over externally managed policy. OneDrive tasks and services remain unchanged. Complete OneDrive updates through your normal maintenance process, and review any externally disabled updater tasks through the system that manages them.

#### Scope and limits

Deferred does **not** disable OneDrive updates. The script does not disable OneDrive tasks/services or block update endpoints. Updates can still start after an idle check, so keep the interval between preparation and capture short and retain your normal image validation process.

`-NoShutdown` still applies the OneDrive finalize policy when applicable. `-SkipCleanup` does not skip OneDrive handling. OS Layers without a detected installed client receive no OneDrive policy changes, including Server 2022 layers without OneDrive.

### Application Layer

Application mode avoids persistent Edge/WebView2 policy, service startup and scheduled-task changes. An active Edge updater can be stopped temporarily, and Edge version information is reported to help identify older browser components captured in an application layer.

### Platform Layer: FSLogix altitude

With `-LayerType Platform`, v1.2.0 checks the FSLogix `frxdrvvt` altitude at:

```text
HKLM\SYSTEM\CurrentControlSet\Services\frxdrvvt\Instances\frxdrvvt
Value: Altitude
Expected: 138010
```

An incorrect value is changed to **`138010`**, then read back to verify remediation. The operation is specific to the applicable FSLogix driver configuration; FSLogix is not installed by this script.

Review failures instead of manually creating driver configuration or assuming that a missing component is an installation error. Registry verification does not by itself prove that a loaded driver has adopted a changed value; follow any reboot requirement reported by Windows, Citrix or the component installer.

### Platform Layer: Citrix WEM RSA key

The script checks:

```text
C:\ProgramData\Microsoft\Crypto\RSA\S-1-5-18
```

It removes only files whose names start with:

```text
fb8cc9e38d3e60ab60c17cdfd6dd6d99_
```

It then checks again to verify that matching files are gone before continuing.

**Do not delete the entire RSA directory, unrelated keys or all MachineKeys.** This is a targeted Platform Layer preparation step, not general cryptographic-key cleanup. If matching files cannot be removed or reappear, investigate WEM and review the log before finalization.

## Common pre-finalize checks

- **Administrator rights:** elevated execution is required.
- **Firewall:** reports disabled Domain, Private or Public profiles; does not automatically enable them.
- **RunOnce:** checks machine-wide 32-bit/64-bit locations and the current user's RunOnce entries. Machine-wide entries are treated as blockers. Entry names and values are reported for investigation.
- **Pending reboot:** checks Windows Update, Component Based Servicing, Windows Installer state and pending computer rename conditions.
- **PendingFileRenameOperations:** reports queued file operations for review.
- **Installer/servicing activity:** checks processes such as `msiexec`, `TiWorker`, `TrustedInstaller`, `setup` and `setuphost`.
- **Edge:** reports the detected executable version and version directories where applicable.
- **NGEN:** checks pending work and active compilation, processes applicable queued work and verifies the final state.

A process being present can be transient. Allow legitimate installation/servicing work to finish, reboot when required, then run the script again. Do not force-clear reboot markers or RunOnce entries simply to obtain a passing result.

## NGEN integrity handling

Citrix can block Shutdown for Finalize with:

```text
a Microsoft NGen operation is needed
```

The script checks NGEN `WorkPending` in both registry views and detects active `ngen`, `ngentask` and `mscorsvw` processes. If compilation is already running, allow it to finish before proceeding.

When applicable queued priority-3 work is found, automatic remediation uses the available 32-bit and 64-bit .NET Framework tools:

```powershell
& "$env:windir\Microsoft.NET\Framework\v4.0.30319\ngen.exe" eqi 3
& "$env:windir\Microsoft.NET\Framework64\v4.0.30319\ngen.exe" eqi 3
```

The script re-checks pending work and process activity afterward. Initial pending work that is successfully resolved should not remain as a stale warning.

**v1.2.0 evaluates the final integrity state.** An individual architecture-specific NGEN pass may return a non-zero exit code even though the subsequent checks show `WorkPending = 0` in both applicable views. That intermediate exit code alone no longer leaves a permanent blocking failure after successful remediation. Pending work or active compilation still prevents a ready result.

The optional `-RunNgen` full update remains separate from this automatic queue handling.

## Recommended workflows

### OS Layer

1. Create/open a new OS Layer version and start maintenance:

   ```powershell
   .\Citrix-Layer-PreFinalize.ps1 -LayerType OS -StartMaintenance
   ```

2. Apply Windows, .NET, Edge, WebView2, installed OneDrive and other applicable OS updates. Reboot as required and allow servicing to finish. Close OneDrive normally before the pre-finalize run.
3. Prepare and review without shutting down:

   ```powershell
   .\Citrix-Layer-PreFinalize.ps1 -LayerType OS -NoShutdown
   ```

4. Resolve blockers, review warnings and rerun if necessary. If OneDrive activity is reported, finish the update and close the client; do not terminate an installer mid-update. When ready:

   ```powershell
   .\Citrix-Layer-PreFinalize.ps1 -LayerType OS
   ```

5. Review the result and answer `Y` to the finalization prompt. Complete the layer finalization workflow in Citrix App Layering.

### Application Layer

1. Create/open the Application Layer version, install or update the application, and complete any required reboot.
2. Review preparation results:

   ```powershell
   .\Citrix-Layer-PreFinalize.ps1 -LayerType App -NoShutdown
   ```

3. Resolve blockers and review warnings. Then run:

   ```powershell
   .\Citrix-Layer-PreFinalize.ps1 -LayerType App
   ```

4. Confirm Shutdown for Finalize and complete finalization in Citrix App Layering.

### Platform Layer

1. Create/open the Platform Layer version and complete platform-component installation and required reboots.
2. Run preparation, including v1.2.0 FSLogix/WEM remediation:

   ```powershell
   .\Citrix-Layer-PreFinalize.ps1 -LayerType Platform -NoShutdown
   ```

3. Review the FSLogix altitude result, WEM key verification, NGEN state and other readiness checks. Resolve remaining problems.
4. Run again when ready:

   ```powershell
   .\Citrix-Layer-PreFinalize.ps1 -LayerType Platform
   ```

5. Confirm Shutdown for Finalize and complete finalization in Citrix App Layering.

## Additional examples

Report devices while preparing an Application Layer without shutting down:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType App -NoShutdown -ReportGhostDevices
```

Skip normal cleanup while retaining checks and applicable remediation:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType Platform -NoShutdown -SkipCleanup
```

Request a full NGEN update for an application that needs it:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType App -RunNgen -NoShutdown
```

Invoke finalization without the normal confirmation prompt after validating the workflow:

```powershell
.\Citrix-Layer-PreFinalize.ps1 -LayerType OS -AutoFinalize
```

## Cleanup and safety

Normal cleanup includes Windows and current-user temporary files, emptying the Recycle Bin and flushing the DNS cache. Use `-SkipCleanup` when cleanup is inappropriate for the current maintenance task.

OneDrive Deferred policy is not a substitute for an update-maintenance plan. Existing ring policies are preserved, and OneDrive updater tasks/services remain unchanged.

The script preserves Windows Event Logs and does not clear `C:\Windows\SoftwareDistribution` or automatically remove ghost devices. Device reporting is informational.

Run the script on the intended packaging machine and select the correct layer type. Persistent Edge/WebView2 changes belong to OS mode; targeted FSLogix/WEM changes belong to Platform mode. Keep a recovery path and test changes on a non-production layer version first.

`-NoShutdown` and `-SkipCleanup` do not provide a read-only mode. Review the script before execution, especially when a Platform Layer contains WEM key material or a customized FSLogix installation. Coordinate any environment-specific antivirus, sealing or image-preparation requirements separately.

## Logging and result interpretation

Each run uses `Start-Transcript` and writes a timestamped log under:

```text
C:\Windows\Temp
```

Example filename:

```text
Citrix-Layer-PreFinalize_20261022_155107.log
```

The output reports passed checks, information, warnings and failures, followed by error/warning totals and a readiness summary such as:

```text
LAYER LOOKS READY FOR FINALIZE
```

or a message indicating that blockers or warnings need attention. Blocking errors prevent the script from invoking Shutdown for Finalize. Review warnings even when they are not classified as blocking errors.

By default, the finalization step asks:

```text
Run Shutdown for Finalize now? (Y/N)
```

`-NoShutdown` suppresses that shutdown step; `-AutoFinalize` removes the normal prompt when finalization is permitted. Citrix may still reject finalization during its own integrity checks.

Copy relevant transcripts off the packaging machine before shutdown or further cleanup. Logs can contain machine details, registry values and paths; review them before sharing publicly. When reporting an issue, include the script version, layer type, Windows build, App Layering version and relevant sanitized output.

## Changelog

### v1.3.0 — 2026-10-23

- Added installed-client detection and conditional OS Layer OneDrive handling.
- Added Deferred ring configuration only when no existing update-ring policy is present.
- Added ownership tracking and maintenance removal of the script's unchanged Deferred override.
- Preserved existing OneDrive ring policies and scheduled task/service states.
- Added blocking checks for active OneDrive client, updater and setup processes, including a final check immediately before Citrix handoff.
- Added detected Windows caption, version and build reporting.
- Retained v1.2.0 Platform Layer FSLogix/WEM and NGEN handling.

### v1.2.0

- Added Platform Layer-specific FSLogix `frxdrvvt` altitude validation, correction to `138010` and post-change verification.
- Added targeted detection/removal of known Citrix WEM RSA key files and post-removal verification.
- Improved NGEN remediation so an architecture-specific non-zero exit code does not permanently block finalize when the final integrity state is clear.

### v1.1.0

- Added automatic NGEN `WorkPending` detection and priority-3 queue processing for applicable 32-bit and 64-bit .NET Framework tools.
- Added active NGEN process detection and post-remediation verification.
- Corrected stale NGEN warnings after successful remediation.

### v1.0.0

- Initial public release: OS maintenance mode, Edge/WebView2 handling, common readiness checks, cleanup, device reporting and Citrix finalization integration.
- The script in this release used the earlier internal version label **v04.2**. Public release and script numbering were aligned from v1.1.0 onward.

## Disclaimer

This is an independent community project, not an official Citrix or Microsoft product. It is provided **as is**, without warranty. It does not replace vendor documentation, supported installation procedures, backups or environment-specific validation.

You are responsible for reviewing the script and validating its effects in your environment before production use. A successful readiness result does not guarantee a successful layer build, publication or runtime outcome.

## Author

**Magnus Edholm**  
Solutions Architect, AceIQ  
Citrix DaaS · App Layering · WEM · NetScaler · Microsoft Azure

[GitHub profile](https://github.com/MagnusEdholm) · [AceIQ](https://www.aceiq.com)  
Contact: [magnus.edholm@aceiq.com](mailto:magnus.edholm@aceiq.com)

Feedback and reproducible issue reports are welcome through the repository's [Issues](https://github.com/MagnusEdholm/Citrix-App-Layering-PreFinalize/issues) page.

## License

Released under the **MIT License**. See [LICENSE](LICENSE) for the full terms, copyright notice and warranty disclaimer.
