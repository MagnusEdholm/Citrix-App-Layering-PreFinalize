<#
.SYNOPSIS
	Citrix App Layering - Pre-Finalize for Windows Server 2022
	Author        : Magnus Edholm
	Email         : magnus.edholm@aceiq.com
	Website       : www.aceiq.com
	Date Created  : 2026-10-02 v04.2
	

.DESCRIPTION

    This script is intended for Citrix App Layering on Windows Server 2022 and can
    be used for OS Layers, Application Layers, and Platform Layers.

    Layer-specific behavior:
      - OS Layer:
          * Applies Edge Update policy: Manual updates only
          * Disables automatic WebView2 Runtime updates
          * Stops Edge Update services and leaves them set to Manual
          * Disables Edge Update scheduled tasks
          * Stops active Edge Update processes
          * Verifies the Edge/WebView2 maintenance state before finalize

      - Application Layer:
          * Does NOT change Edge Update policies
          * Does NOT change Edge Update service startup types
          * Does NOT disable Edge Update scheduled tasks
          * Only stops active Edge Update processes temporarily
          * Reports Edge version and performs finalize safety checks

      - Platform Layer:
          * Uses the same conservative behavior as Application Layer

    It performs the following common tasks:
      - Verifies that PowerShell is running as Administrator
      - Checks Windows Firewall profiles
      - Temporarily stops Edge Update processes if they are running
      - Checks RunOnce (HKLM 64-bit + 32-bit and HKCU)
      - Checks PendingFileRenameOperations
      - Checks common pending reboot indicators
      - Checks for active Windows Installer/MSI activity
      - Displays the current Edge version
      - Cleans safe temporary folders
      - Empties the Recycle Bin
      - Flushes the DNS cache
      - Reports ghost/non-present devices if the PnpDevice module is available
      - Does NOT automatically remove ghost devices
      - Does NOT run NGEN by default
      - Does NOT clear Event Logs
      - Does NOT clear SoftwareDistribution
      - Does NOT permanently change Edge Update policies, services, or scheduled tasks
      - Runs ShutdownForFinalize.cmd only when no blocking errors exist
        and the administrator explicitly confirms it.
#>


<#
.USAGE QUICK REFERENCE

Recommended commands by scenario:

OS LAYER - START MAINTENANCE
    Use when opening a new OS Layer version before Windows Update, Edge,
    WebView2, .NET, or other OS maintenance.

    .\Citrix-Layer-PreFinalize.ps1 -LayerType OS -StartMaintenance

OS LAYER - CHECK ONLY, NO SHUTDOWN
    Use before finalize when you want to review all checks without shutting
    down the packaging machine.

    .\Citrix-Layer-PreFinalize.ps1 -LayerType OS -NoShutdown

OS LAYER - NORMAL FINALIZE
    Recommended normal finalize command for an OS Layer.
    Applies the OS-specific Edge/WebView2 finalize configuration, runs all
    checks and cleanup, and asks before ShutdownForFinalize.cmd is started.

    .\Citrix-Layer-PreFinalize.ps1 -LayerType OS

OS LAYER - AUTOMATIC FINALIZE
    Same as normal OS finalize, but automatically starts
    ShutdownForFinalize.cmd when there are no blocking errors.

    .\Citrix-Layer-PreFinalize.ps1 -LayerType OS -AutoFinalize

OS LAYER - REPORT GHOST DEVICES
    Adds a report of non-present/problem devices. No devices are removed.

    .\Citrix-Layer-PreFinalize.ps1 -LayerType OS -ReportGhostDevices

APPLICATION LAYER - NORMAL FINALIZE
    Recommended normal finalize command for an Application Layer.
    Does NOT permanently modify Edge policies, Edge services, or Edge
    scheduled tasks.

    .\Citrix-Layer-PreFinalize.ps1 -LayerType App

APPLICATION LAYER - CHECK ONLY, NO SHUTDOWN
    Recommended when troubleshooting an existing or sensitive Application Layer.

    .\Citrix-Layer-PreFinalize.ps1 -LayerType App -NoShutdown

APPLICATION LAYER - CHECK + GHOST DEVICE REPORT
    Recommended for troubleshooting old or problematic Application Layers.

    .\Citrix-Layer-PreFinalize.ps1 -LayerType App -NoShutdown -ReportGhostDevices

PLATFORM LAYER - NORMAL FINALIZE
    Uses the same conservative Edge handling as an Application Layer.

    .\Citrix-Layer-PreFinalize.ps1 -LayerType Platform

OPTIONAL SWITCHES

    -SkipCleanup
        Skips TEMP cleanup, Recycle Bin cleanup, and DNS cache flush.

    -ReportGhostDevices
        Reports non-present/problem devices if the PnpDevice module is
        available. No devices are removed.

    -RunNgen
        Runs ngen.exe update for installed .NET Framework versions.
        Do not use routinely. Use only when a specific application or vendor
        requires it.

    -AutoFinalize
        Automatically starts ShutdownForFinalize.cmd if there are no
        blocking errors.

    -NoShutdown
        Runs checks and cleanup, but never starts ShutdownForFinalize.cmd.

    -StartMaintenance
        OS Layer only.
        Removes this script's Edge/WebView2 finalize restrictions, enables
        Edge Update scheduled tasks, sets Edge Update services to Manual,
        and prepares the OS Layer for maintenance.

RECOMMENDED OS LAYER WORKFLOW

    1. Start maintenance:
       .\Citrix-Layer-PreFinalize.ps1 -LayerType OS -StartMaintenance

    2. Perform Windows Update, Edge/WebView2 updates and other OS maintenance.
       Reboot as required.

    3. Optional check-only pass:
       .\Citrix-Layer-PreFinalize.ps1 -LayerType OS -NoShutdown

    4. Finalize:
       .\Citrix-Layer-PreFinalize.ps1 -LayerType OS

RECOMMENDED APPLICATION LAYER WORKFLOW

    Normal:
       .\Citrix-Layer-PreFinalize.ps1 -LayerType App

    Troubleshooting / sensitive old layer:
       .\Citrix-Layer-PreFinalize.ps1 -LayerType App -NoShutdown -ReportGhostDevices

IMPORTANT

    - Do not use -StartMaintenance with App or Platform layers.
    - -LayerType defaults to App if omitted.
    - Ghost devices are never removed automatically.
    - NGEN is disabled by default.
    - Event Logs are not cleared.
    - SoftwareDistribution is not cleared.
    - Edge Update policies/services/tasks are only modified persistently in
      OS Layer mode.
#>

[CmdletBinding()]
param(
    [ValidateSet('OS','App','Platform')]
    [string]$LayerType = 'App',

    [switch]$SkipCleanup,
    [switch]$ReportGhostDevices,
    [switch]$RunNgen,
    [switch]$AutoFinalize,
    [switch]$NoShutdown,
    [switch]$StartMaintenance
)

#Requires -RunAsAdministrator

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$script:Errors   = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

$EdgePolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
$WebView2Guid   = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$EdgeServices   = @(
    'edgeupdate',
    'edgeupdatem',
    'MicrosoftEdgeElevationService'
)

$TimeStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogRoot   = 'C:\Windows\Temp'
$LogFile   = Join-Path $LogRoot "Citrix-Layer-PreFinalize_$TimeStamp.log"

if (-not (Test-Path $LogRoot)) {
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
}

try {
    Start-Transcript -Path $LogFile -Force | Out-Null
}
catch {
    Write-Warning "Could not start transcript: $($_.Exception.Message)"
}

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Text)
    Write-Host "[PASS]    $Text" -ForegroundColor Green
}

function Write-Info {
    param([string]$Text)
    Write-Host "[INFO]    $Text" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Text)
    Write-Host "[WARNING] $Text" -ForegroundColor Yellow
    $script:Warnings.Add($Text)
}

function Write-Fail {
    param([string]$Text)
    Write-Host "[FAIL]    $Text" -ForegroundColor Red
    $script:Errors.Add($Text)
}

function Get-RealRegistryProperties {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        return @()
    }

    try {
        $item = Get-ItemProperty -Path $Path -ErrorAction Stop
        return @(
            $item.PSObject.Properties |
            Where-Object {
                $_.Name -notin @(
                    'PSPath','PSParentPath','PSChildName',
                    'PSDrive','PSProvider'
                )
            }
        )
    }
    catch {
        Write-Warn "Could not read registry path $Path : $($_.Exception.Message)"
        return @()
    }
}

function Stop-EdgeUpdateProcesses {
    Write-Section "Microsoft Edge Update - Process Check"

    $edgeProcesses = @(
        Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -match '^(MicrosoftEdgeUpdate|msedgeupdate)$'
        }
    )

    if ($edgeProcesses.Count -eq 0) {
        Write-Pass "No Microsoft Edge Update process is running."
        return
    }

    foreach ($process in $edgeProcesses) {
        try {
            Write-Info "Stopping $($process.ProcessName) PID $($process.Id)"
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        }
        catch {
            Write-Warn "Could not stop $($process.ProcessName) PID $($process.Id): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2

    $remaining = @(
        Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -match '^(MicrosoftEdgeUpdate|msedgeupdate)$'
        }
    )

    if ($remaining.Count -gt 0) {
        foreach ($process in $remaining) {
            Write-Fail "Edge Update process is still running: $($process.ProcessName) PID $($process.Id)"
        }
    }
    else {
        Write-Pass "Microsoft Edge Update processes are stopped."
    }
}

function Check-Firewall {
    Write-Section "Windows Firewall"

    if (-not (Get-Command Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
        Write-Warn "Get-NetFirewallProfile is not available on this system."
        return
    }

    $profiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)

    if ($profiles.Count -eq 0) {
        Write-Warn "Could not read Firewall profiles."
        return
    }

    foreach ($profile in $profiles) {
        if ($profile.Enabled) {
            Write-Pass "Firewall profile '$($profile.Name)' is Enabled."
        }
        else {
            Write-Warn "Firewall profile '$($profile.Name)' is Disabled."
        }
    }
}

function Check-RunOnce {
    Write-Section "RunOnce"

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    )

    foreach ($path in $paths) {
        $props = @(Get-RealRegistryProperties -Path $path)

        if ($props.Count -eq 0) {
            Write-Pass "$path is empty."
            continue
        }

        # HKLM RunOnce is blocking for Citrix App Layering finalize.
        $blocking = $path -like 'HKLM:*'

        if ($blocking) {
            Write-Fail "RunOnce contains entries: $path"
        }
        else {
            Write-Warn "HKCU RunOnce contains entries: $path"
        }

        foreach ($prop in $props) {
            Write-Host "          Name : $($prop.Name)" -ForegroundColor Yellow
            Write-Host "          Value: $($prop.Value)" -ForegroundColor Yellow
        }
    }
}

function Check-PendingFileRename {
    Write-Section "PendingFileRenameOperations"

    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

    try {
        $value = (Get-ItemProperty -Path $path -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    }
    catch {
        $value = $null
    }

    if ($null -eq $value -or @($value).Count -eq 0) {
        Write-Pass "No PendingFileRenameOperations found."
        return
    }

    Write-Warn "PendingFileRenameOperations exists. Check whether a reboot is required."

    foreach ($entry in @($value)) {
        Write-Host "          $entry" -ForegroundColor Yellow
    }
}

function Check-PendingReboot {
    Write-Section "Pending Reboot"

    $checks = [ordered]@{
        'Windows Update RebootRequired' =
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'

        'CBS RebootPending' =
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'

        'CBS RebootInProgress' =
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'

        'Windows Installer InProgress' =
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress'
    }

    foreach ($check in $checks.GetEnumerator()) {
        if (Test-Path $check.Value) {
            Write-Warn "$($check.Key) is set."
        }
        else {
            Write-Pass "$($check.Key) is not set."
        }
    }

    # Pending computer rename
    try {
        $activeName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction Stop).ComputerName
        $pendingName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop).ComputerName

        if ($activeName -ne $pendingName) {
            Write-Warn "Pending computer rename: '$activeName' -> '$pendingName'."
        }
        else {
            Write-Pass "No pending computer rename."
        }
    }
    catch {
        Write-Warn "Could not check computer rename status."
    }
}

function Check-InstallerProcesses {
    Write-Section "Installation Processes"

    $processNames = @(
        'msiexec',
        'TiWorker',
        'TrustedInstaller',
        'setup',
        'setuphost'
    )

    $found = @(
        Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -in $processNames }
    )

    if ($found.Count -eq 0) {
        Write-Pass "No common installation/servicing processes are running."
        return
    }

    foreach ($process in $found) {
        # TiWorker/TrustedInstaller may run in the background even when the system is healthy.
        if ($process.ProcessName -in @('TiWorker','TrustedInstaller')) {
            Write-Warn "Windows servicing process is running: $($process.ProcessName) PID $($process.Id)"
        }
        else {
            Write-Warn "Installation process is running: $($process.ProcessName) PID $($process.Id)"
        }
    }
}

function Show-EdgeVersion {
    Write-Section "Microsoft Edge"

    $edgeExe = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'

    if (-not (Test-Path $edgeExe)) {
        Write-Info "Microsoft Edge was not found in the default location."
        return
    }

    try {
        $item = Get-Item $edgeExe -ErrorAction Stop
        Write-Host "          msedge.exe version : $($item.VersionInfo.FileVersion)" -ForegroundColor White

        $versionFolders = @(
            Get-ChildItem 'C:\Program Files (x86)\Microsoft\Edge\Application' -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
            Sort-Object Name
        )

        if ($versionFolders.Count -gt 0) {
            Write-Host "          Version folders:" -ForegroundColor White
            foreach ($folder in $versionFolders) {
                Write-Host "            - $($folder.Name)" -ForegroundColor White
            }
        }
    }
    catch {
        Write-Warn "Could not read Edge version: $($_.Exception.Message)"
    }
}

function Report-GhostDevices {
    if (-not $ReportGhostDevices) {
        return
    }

    Write-Section "Non-present / Ghost Devices (Report Only)"

    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) {
        Write-Info "Get-PnpDevice/PnpDevice module is not available. Skipping this check."
        return
    }

    try {
        $devices = @(
            Get-PnpDevice -PresentOnly:$false -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Status -in @('Unknown','Error') -or
                $_.Problem -ne 0
            } |
            Sort-Object Class,FriendlyName
        )

        if ($devices.Count -eq 0) {
            Write-Pass "No obvious non-present/problem devices were found."
            return
        }

        Write-Warn "$($devices.Count) device(s) are reported as Unknown/Error/problem."
        $devices |
            Select-Object Status,Class,FriendlyName,InstanceId |
            Format-Table -AutoSize

        Write-Info "No devices are removed automatically."
    }
    catch {
        Write-Warn "Could not read PnP devices: $($_.Exception.Message)"
    }
}

function Invoke-SafeCleanup {
    if ($SkipCleanup) {
        Write-Info "Cleanup skipped because -SkipCleanup was specified."
        return
    }

    Write-Section "Safe Cleanup"

    $paths = @(
        'C:\Windows\Temp\*',
        "$env:TEMP\*"
    )

    foreach ($path in $paths) {
        try {
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Pass "Cleanup completed: $path"
        }
        catch {
            Write-Warn "Cleanup failed for $path : $($_.Exception.Message)"
        }
    }

    # Recycle Bin
    try {
        if (Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue) {
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            Write-Pass "Recycle Bin emptied."
        }
        else {
            Get-ChildItem 'C:\$Recycle.Bin\' -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Pass "Recycle Bin cleanup completed."
        }
    }
    catch {
        Write-Warn "Could not empty the Recycle Bin."
    }

    # DNS cache
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-Pass "DNS cache flushed."
    }
    catch {
        try {
            & ipconfig.exe /flushdns | Out-Null
            Write-Pass "DNS cache flushed using ipconfig."
        }
        catch {
            Write-Warn "Could not flush the DNS cache."
        }
    }
}

function Invoke-OptionalNgen {
    if (-not $RunNgen) {
        return
    }

    Write-Section "NGEN (.NET Framework) - Optional"

    $roots = @(
        'C:\Windows\Microsoft.NET\Framework',
        'C:\Windows\Microsoft.NET\Framework64'
    )

    $ngenFiles = @()

    foreach ($root in $roots) {
        if (Test-Path $root) {
            $ngenFiles += Get-ChildItem -Path $root -Filter ngen.exe -Recurse -ErrorAction SilentlyContinue
        }
    }

    $ngenFiles = @($ngenFiles | Sort-Object FullName -Unique)

    if ($ngenFiles.Count -eq 0) {
        Write-Info "No ngen.exe was found."
        return
    }

    foreach ($ngen in $ngenFiles) {
        try {
            Write-Info "Running: $($ngen.FullName) update"
            & $ngen.FullName update
            if ($LASTEXITCODE -eq 0) {
                Write-Pass "NGEN completed: $($ngen.FullName)"
            }
            else {
                Write-Warn "NGEN returned exit code $($LASTEXITCODE): $($ngen.FullName)"
            }
        }
        catch {
            Write-Warn "NGEN failed: $($ngen.FullName)"
        }
    }
}

function Invoke-Finalize {
    Write-Section "Shutdown for Finalize"

    $finalizeCmd = 'C:\Program Files\Unidesk\Uniservice\ShutdownForFinalize.cmd'

    if (-not (Test-Path $finalizeCmd)) {
        Write-Fail "ShutdownForFinalize.cmd was not found: $finalizeCmd"
        return
    }

    if ($NoShutdown) {
        Write-Info "-NoShutdown specified. Shutdown for Finalize will not be run."
        return
    }

    if ($script:Errors.Count -gt 0) {
        Write-Fail "Shutdown for Finalize is blocked because $($script:Errors.Count) blocking error(s) exist."
        return
    }

    if ($script:Warnings.Count -gt 0) {
        Write-Warn "There are $($script:Warnings.Count) warning(s). Review them before finalizing."
    }

    $runFinalize = $false

    if ($AutoFinalize) {
        $runFinalize = $true
    }
    else {
        Write-Host ""
        $answer = Read-Host "Run Shutdown for Finalize now? (Y/N)"
        if ($answer -match '^[Yy]$') {
            $runFinalize = $true
        }
    }

    if ($runFinalize) {
        Write-Host ""
        Write-Host "Starting Shutdown for Finalize..." -ForegroundColor Green
        & $finalizeCmd
    }
    else {
        Write-Info "Shutdown for Finalize was not started."
    }
}



function Start-OSLayerMaintenance {
    Write-Section "OS Layer - Start Maintenance"

    if ($LayerType -ne 'OS') {
        Write-Fail "-StartMaintenance can only be used with -LayerType OS."
        return $false
    }

    if ($AutoFinalize -or $NoShutdown -or $RunNgen -or $ReportGhostDevices -or $SkipCleanup) {
        Write-Info "-StartMaintenance ignores finalize/cleanup switches because no finalize workflow is run."
    }

    # --------------------------------------------------------------
    # 1. Remove script-managed Edge/WebView2 update restrictions
    # --------------------------------------------------------------
    if (Test-Path $EdgePolicyPath) {
        try {
            Remove-ItemProperty `
                -Path $EdgePolicyPath `
                -Name 'UpdateDefault' `
                -ErrorAction SilentlyContinue

            Write-Pass "Removed Edge UpdateDefault override."
        }
        catch {
            Write-Warn "Could not remove Edge UpdateDefault override: $($_.Exception.Message)"
        }

        try {
            Remove-ItemProperty `
                -Path $EdgePolicyPath `
                -Name ("Update" + $WebView2Guid) `
                -ErrorAction SilentlyContinue

            Write-Pass "Removed WebView2 update override."
        }
        catch {
            Write-Warn "Could not remove WebView2 update override: $($_.Exception.Message)"
        }
    }
    else {
        Write-Info "EdgeUpdate policy registry key does not exist."
    }

    # --------------------------------------------------------------
    # 2. Enable Edge Update services for maintenance
    # --------------------------------------------------------------
    foreach ($serviceName in $EdgeServices) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

        if (-not $service) {
            Write-Info "$serviceName is not installed."
            continue
        }

        try {
            Set-Service -Name $serviceName -StartupType Manual -ErrorAction Stop
            Write-Pass "$serviceName startup type = Manual."
        }
        catch {
            Write-Warn "Could not set $serviceName startup type to Manual: $($_.Exception.Message)"
        }

        try {
            Start-Service -Name $serviceName -ErrorAction Stop
            Write-Pass "$serviceName started."
        }
        catch {
            # Some Edge services are trigger-start/manual and may not remain running.
            Write-Info "$serviceName was not started or did not remain running. This can be normal for trigger-start services."
        }
    }

    # --------------------------------------------------------------
    # 3. Enable Edge Update scheduled tasks
    # --------------------------------------------------------------
    $edgeTasks = @(
        Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            $_.TaskName -like '*EdgeUpdate*' -or
            $_.TaskName -like '*Edge*Update*'
        }
    )

    if ($edgeTasks.Count -eq 0) {
        Write-Info "No Edge Update scheduled tasks were found."
    }
    else {
        foreach ($task in $edgeTasks) {
            try {
                Enable-ScheduledTask `
                    -TaskName $task.TaskName `
                    -TaskPath $task.TaskPath `
                    -ErrorAction Stop | Out-Null

                Write-Pass "Enabled scheduled task: $($task.TaskPath)$($task.TaskName)"
            }
            catch {
                Write-Warn "Could not enable scheduled task $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)"
            }
        }
    }

    # --------------------------------------------------------------
    # 4. Verification
    # --------------------------------------------------------------
    Write-Section "OS Layer - Maintenance Verification"

    if (Test-Path $EdgePolicyPath) {
        $policy = Get-ItemProperty -Path $EdgePolicyPath -ErrorAction SilentlyContinue

        $updateDefaultProp = $policy.PSObject.Properties['UpdateDefault']
        if ($null -eq $updateDefaultProp) {
            Write-Pass "No script-managed Edge UpdateDefault restriction is present."
        }
        else {
            Write-Warn "Edge UpdateDefault is still configured: $($updateDefaultProp.Value)"
        }

        $webViewName = "Update$WebView2Guid"
        $webViewProp = $policy.PSObject.Properties[$webViewName]

        if ($null -eq $webViewProp) {
            Write-Pass "No script-managed WebView2 update restriction is present."
        }
        else {
            Write-Warn "WebView2 update override is still configured: $($webViewProp.Value)"
        }
    }
    else {
        Write-Pass "No EdgeUpdate policy registry key is present."
    }

    foreach ($serviceName in $EdgeServices) {
        $svc = Get-CimInstance `
            -ClassName Win32_Service `
            -Filter "Name='$serviceName'" `
            -ErrorAction SilentlyContinue

        if ($svc) {
            if ($svc.StartMode -eq 'Manual') {
                Write-Pass "$serviceName startup type = Manual."
            }
            else {
                Write-Warn "$serviceName StartMode=$($svc.StartMode), expected Manual."
            }
        }
    }

    $disabledTasks = @(
        Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            (
                $_.TaskName -like '*EdgeUpdate*' -or
                $_.TaskName -like '*Edge*Update*'
            ) -and
            $_.State -eq 'Disabled'
        }
    )

    if ($disabledTasks.Count -eq 0) {
        Write-Pass "No Edge Update scheduled tasks are disabled."
    }
    else {
        Write-Warn "One or more Edge Update scheduled tasks are still disabled."
        $disabledTasks |
            Select-Object TaskPath,TaskName,State |
            Format-Table -AutoSize
    }

    Write-Host ""
    Write-Host "OS LAYER MAINTENANCE MODE IS READY" -ForegroundColor Green
    Write-Host ""
    Write-Host "You can now perform Windows Update, Edge/WebView2 updates, and other OS maintenance." -ForegroundColor White
    Write-Host "Reboot as required during maintenance." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "When maintenance is complete, run:" -ForegroundColor Cyan
    Write-Host "  .\Citrix-Layer-PreFinalize.ps1 -LayerType OS" -ForegroundColor White
    Write-Host ""

    return $true
}

function Configure-OSLayerEdgeMaintenance {
    if ($LayerType -ne 'OS') {
        Write-Section "Edge/WebView2 Layer-Specific Configuration"
        Write-Info "LayerType=$LayerType. No persistent Edge/WebView2 configuration changes will be made."
        return
    }

    Write-Section "OS Layer - Edge/WebView2 Finalize Configuration"

    # --------------------------------------------------------------
    # 1. Edge Update policy
    # --------------------------------------------------------------
    try {
        New-Item -Path $EdgePolicyPath -Force | Out-Null

        New-ItemProperty `
            -Path $EdgePolicyPath `
            -Name 'UpdateDefault' `
            -PropertyType DWord `
            -Value 2 `
            -Force | Out-Null

        Write-Pass "Edge UpdateDefault = 2 (Manual updates only)."

        New-ItemProperty `
            -Path $EdgePolicyPath `
            -Name ("Update" + $WebView2Guid) `
            -PropertyType DWord `
            -Value 0 `
            -Force | Out-Null

        Write-Pass "Automatic WebView2 Runtime updates are disabled."
    }
    catch {
        Write-Fail "Could not configure Edge/WebView2 update policies: $($_.Exception.Message)"
    }

    # --------------------------------------------------------------
    # 2. Stop Edge Update services and leave startup type = Manual
    # --------------------------------------------------------------
    foreach ($serviceName in $EdgeServices) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

        if (-not $service) {
            Write-Info "$serviceName is not installed."
            continue
        }

        if ($service.Status -ne 'Stopped') {
            try {
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
                Write-Pass "$serviceName stopped."
            }
            catch {
                Write-Warn "Could not stop $serviceName : $($_.Exception.Message)"
            }
        }
        else {
            Write-Pass "$serviceName is already stopped."
        }

        try {
            Set-Service -Name $serviceName -StartupType Manual -ErrorAction Stop
            Write-Pass "$serviceName startup type = Manual."
        }
        catch {
            Write-Warn "Could not set $serviceName startup type to Manual: $($_.Exception.Message)"
        }
    }

    # --------------------------------------------------------------
    # 3. Disable Edge Update scheduled tasks
    # --------------------------------------------------------------
    $edgeTasks = @(
        Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            $_.TaskName -like '*EdgeUpdate*' -or
            $_.TaskName -like '*Edge*Update*'
        }
    )

    if ($edgeTasks.Count -eq 0) {
        Write-Pass "No Edge Update scheduled tasks were found."
    }
    else {
        foreach ($task in $edgeTasks) {
            try {
                Disable-ScheduledTask `
                    -TaskName $task.TaskName `
                    -TaskPath $task.TaskPath `
                    -ErrorAction Stop | Out-Null

                Write-Pass "Disabled scheduled task: $($task.TaskPath)$($task.TaskName)"
            }
            catch {
                Write-Warn "Could not disable scheduled task $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)"
            }
        }
    }
}

function Verify-OSLayerEdgeMaintenance {
    if ($LayerType -ne 'OS') {
        return
    }

    Write-Section "OS Layer - Edge/WebView2 Final Verification"

    # Policy verification
    if (Test-Path $EdgePolicyPath) {
        try {
            $policy = Get-ItemProperty -Path $EdgePolicyPath -ErrorAction Stop

            if ($policy.UpdateDefault -eq 2) {
                Write-Pass "Edge Update policy is Manual updates only."
            }
            else {
                Write-Fail "Edge UpdateDefault is not set to 2."
            }

            $webViewName = "Update$WebView2Guid"
            $webViewProp = $policy.PSObject.Properties[$webViewName]

            if ($null -ne $webViewProp -and $webViewProp.Value -eq 0) {
                Write-Pass "Automatic WebView2 updates are disabled."
            }
            else {
                Write-Fail "WebView2 update policy is not set to 0."
            }
        }
        catch {
            Write-Fail "Could not verify Edge/WebView2 policy: $($_.Exception.Message)"
        }
    }
    else {
        Write-Fail "EdgeUpdate policy registry key does not exist."
    }

    # Service verification
    foreach ($serviceName in $EdgeServices) {
        $svc = Get-CimInstance `
            -ClassName Win32_Service `
            -Filter "Name='$serviceName'" `
            -ErrorAction SilentlyContinue

        if (-not $svc) {
            Write-Info "$serviceName is not installed."
            continue
        }

        if ($svc.State -eq 'Stopped' -and $svc.StartMode -eq 'Manual') {
            Write-Pass "$serviceName = Stopped / Manual."
        }
        else {
            Write-Warn "$serviceName State=$($svc.State), StartMode=$($svc.StartMode)."
        }
    }

    # Scheduled task verification
    $enabledEdgeTasks = @(
        Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            (
                $_.TaskName -like '*EdgeUpdate*' -or
                $_.TaskName -like '*Edge*Update*'
            ) -and
            $_.State -ne 'Disabled'
        }
    )

    if ($enabledEdgeTasks.Count -eq 0) {
        Write-Pass "No enabled Edge Update scheduled tasks remain."
    }
    else {
        Write-Warn "One or more Edge Update scheduled tasks are still enabled."
        $enabledEdgeTasks |
            Select-Object TaskPath,TaskName,State |
            Format-Table -AutoSize
    }

    # Process verification
    $edgeProcesses = @(
        Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -match '^(MicrosoftEdgeUpdate|msedgeupdate)$'
        }
    )

    if ($edgeProcesses.Count -eq 0) {
        Write-Pass "No Microsoft Edge Update process is running."
    }
    else {
        foreach ($process in $edgeProcesses) {
            Write-Fail "Edge Update process is still running: $($process.ProcessName) PID $($process.Id)"
        }
    }
}


# ------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------

Write-Section "Citrix App Layering Pre-Finalize - Windows Server 2022"
Write-Host "          Layer type : $LayerType" -ForegroundColor White
if ($LayerType -eq 'OS') {
    Write-Host "          Edge mode  : OS maintenance protection" -ForegroundColor White
}
else {
    Write-Host "          Edge mode  : Non-invasive / process stop only" -ForegroundColor White
}
Write-Host "          Computer   : $env:COMPUTERNAME" -ForegroundColor White
Write-Host "          User       : $env:USERDOMAIN\$env:USERNAME" -ForegroundColor White
Write-Host "          Time       : $(Get-Date)" -ForegroundColor White
Write-Host "          Log        : $LogFile" -ForegroundColor White
Write-Host "          Help       : Get-Help .\\Citrix-Layer-PreFinalize.ps1 -Full" -ForegroundColor White

try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Write-Host "          OS         : $($os.Caption) $($os.Version) Build $($os.BuildNumber)" -ForegroundColor White
}
catch {
    Write-Warn "Could not read OS version."
}

if ($StartMaintenance) {
    if ($LayerType -ne 'OS') {
        Write-Section "FINAL RESULT"
        Write-Fail "-StartMaintenance requires -LayerType OS."
        Write-Host ""
        Write-Host "Example:" -ForegroundColor Yellow
        Write-Host "  .\Citrix-Layer-PreFinalize.ps1 -LayerType OS -StartMaintenance" -ForegroundColor White
        try { Stop-Transcript | Out-Null } catch {}
        exit 1
    }

    [void](Start-OSLayerMaintenance)

    Write-Section "FINAL RESULT"

    if ($script:Errors.Count -gt 0) {
        Write-Host "MAINTENANCE MODE SETUP FAILED" -ForegroundColor Red
        foreach ($item in $script:Errors) {
            Write-Host " - $item" -ForegroundColor Red
        }
        $exitCode = 1
    }
    elseif ($script:Warnings.Count -gt 0) {
        Write-Host "MAINTENANCE MODE ENABLED WITH WARNINGS" -ForegroundColor Yellow
        foreach ($item in $script:Warnings) {
            Write-Host " - $item" -ForegroundColor Yellow
        }
        $exitCode = 0
    }
    else {
        Write-Host "OS LAYER IS READY FOR MAINTENANCE" -ForegroundColor Green
        $exitCode = 0
    }

    Write-Host ""
    Write-Host "Log      : $LogFile" -ForegroundColor White
    Write-Host ""

    try { Stop-Transcript | Out-Null } catch {}
    exit $exitCode
}

Check-Firewall
Configure-OSLayerEdgeMaintenance
Stop-EdgeUpdateProcesses
Check-RunOnce
Check-PendingFileRename
Check-PendingReboot
Check-InstallerProcesses
Show-EdgeVersion
Report-GhostDevices
Invoke-SafeCleanup
Invoke-OptionalNgen
Verify-OSLayerEdgeMaintenance

Write-Section "FINAL RESULT"

if ($script:Errors.Count -gt 0) {
    Write-Host "DO NOT FINALIZE YET" -ForegroundColor Red
    Write-Host ""
    foreach ($item in $script:Errors) {
        Write-Host " - $item" -ForegroundColor Red
    }
}
elseif ($script:Warnings.Count -gt 0) {
    Write-Host "CHECK WARNINGS BEFORE FINALIZE" -ForegroundColor Yellow
    Write-Host ""
    foreach ($item in $script:Warnings) {
        Write-Host " - $item" -ForegroundColor Yellow
    }
}
else {
    Write-Host "LAYER LOOKS READY FOR FINALIZE" -ForegroundColor Green
}

Write-Host ""
Write-Host "Errors   : $($script:Errors.Count)" -ForegroundColor White
Write-Host "Warnings : $($script:Warnings.Count)" -ForegroundColor White
Write-Host "Log      : $LogFile" -ForegroundColor White
Write-Host ""

Invoke-Finalize

try {
    Stop-Transcript | Out-Null
}
catch {
}
