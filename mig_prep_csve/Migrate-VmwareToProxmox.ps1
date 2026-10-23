<#
.SYNOPSIS
    Runs pre-migration checks, source preparation, or post-Firstboot validation.
.DESCRIPTION
    Each child script runs in an isolated PowerShell process. Blocking failures stop
    the phase and warning exit codes are propagated. Full validation never removes
    VMware Tools; the restore conversion owns that operation.
.PARAMETER DriverPreparation
    Install (default) preserves source VirtIO preparation. FirstbootManaged skips
    it only when the selected restore method supplies boot-critical drivers.
.PARAMETER FirstbootNotUsed
    Explicitly declares a restore method without Guestfs/Firstboot. This cannot
    bypass an existing pending or unverified Firstboot conversion.
.PARAMETER AdapterMappingPath
    Optional complete source-MAC to target-MAC JSON mapping for ValidatePost.
    Omit when source MACs are preserved. Works with menu selection 3 as well.
.PARAMETER DisableVMwareTools
    Enabled by default in Prepare to preserve the original migration workflow.
    Captures original service state before stopping/disabling Tools on the source.
    Use -DisableVMwareTools:$false to keep source services unchanged.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('ReadinessCheck', 'Prepare', 'ValidatePost')][string]$Phase,
    [ValidateSet('Auto', 'DomainController', 'Normal')][string]$ServerType = 'Auto',
    [ValidateSet('Install', 'FirstbootManaged')][string]$DriverPreparation = 'Install',
    [string]$StateDirectory = '',
    [string]$AdapterMappingPath = '',
    [switch]$FirstbootNotUsed,
    [switch]$RepairOfflineDisks,
    [switch]$RemoveHiddenVMwareAdapters,
    [switch]$DisableVMwareTools = $true,
    [switch]$DeepScan,
    [string]$DnsTestHost = '',
    [string]$ApplicationConfigPath = '',
    [datetime]$MigrationTimestamp,
    [string]$ExpectedInstallerSha256 = '',
    [switch]$AllowUnsignedInstaller
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Migration.Common.ps1')
$script:PhaseExitCode = 0

function Invoke-CheckedMigrationScript {
    param([string]$Name, [hashtable]$Arguments = @{}, [int[]]$WarningCodes = @(1))
    $code = Invoke-MigrationChildScript -Path (Join-Path $PSScriptRoot $Name) -Arguments $Arguments
    if ($code -eq 0) { return }
    if ($code -in $WarningCodes) {
        $script:PhaseExitCode = 1
        Write-Warning "$Name completed with warnings (exit $code). Review its report."
        return
    }
    $exception = New-Object System.InvalidOperationException("$Name failed with exit code $code. The phase was stopped.")
    $exception.Data['MigrationExitCode'] = $code
    throw $exception
}

function Resolve-MigrationServerType {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $detected = if ([int]$computer.DomainRole -ge 4) { 'DomainController' } else { 'Normal' }
    if ($ServerType -ne 'Auto' -and $ServerType -ne $detected) {
        throw "Selected server type '$ServerType' conflicts with detected type '$detected'."
    }
    return $detected
}

function Write-MigrationCaptureSummary {
    $selectedState = Resolve-MigrationStateDirectory
    $network = Get-Content -LiteralPath (Join-Path $selectedState 'NetworkConfiguration.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Assert-MigrationNetworkCaptureComplete $network
    $count = @(Get-MigrationProperty $network 'activeAdapters' @() | Where-Object { $_ }).Count
    Write-Host "StateDirectory: $selectedState"
    if ($count -gt 1) {
        $script:PhaseExitCode = 1
        Write-Warning "Captured all $count adapters and their routes. Preparation completed with warnings; preserve every source MAC in Proxmox or supply -AdapterMappingPath in ValidatePost so every NIC and route can be restored safely."
    }
}

try {
    if (-not $Phase) {
        Write-Host '1) ReadinessCheck  2) Prepare  3) ValidatePost  4) Exit'
        switch (Read-Host 'Select phase') {
            '1' { $Phase = 'ReadinessCheck' }
            '2' { $Phase = 'Prepare' }
            '3' { $Phase = 'ValidatePost' }
            '4' { exit 0 }
            default { throw 'Invalid phase selection.' }
        }
    }
    if ($StateDirectory -and $Phase -ne 'ValidatePost') { throw '-StateDirectory selects a restore baseline and is only supported with ValidatePost.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script in an elevated Administrator PowerShell session.'
    }
    $role = Resolve-MigrationServerType
    Write-Host "Phase: $Phase. Detected server type: $role."
    switch ($Phase) {
        'ReadinessCheck' {
            $readinessArgs = @{}
            if ($DriverPreparation -eq 'FirstbootManaged') { $readinessArgs.StorageDriverMode = 'RestoreInjected' }
            Invoke-CheckedMigrationScript 'Test-MigrationReadiness.ps1' $readinessArgs
            if ($role -eq 'DomainController') {
                Invoke-CheckedMigrationScript 'Test-DCMigrationHealth.ps1' @{ Mode = 'PreMigration' }
            }
        }
        'Prepare' {
            $prepareAction = 'Prepare the source VM and capture migration state'
            if ($DisableVMwareTools) { $prepareAction += ', then stop and disable VMware Tools services (preserving original service state)' }
            if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, $prepareAction)) {
                if ($DriverPreparation -eq 'Install') {
                    $driverArgs = @{}
                    if ($ExpectedInstallerSha256) { $driverArgs.ExpectedInstallerSha256 = $ExpectedInstallerSha256 }
                    if ($AllowUnsignedInstaller) { $driverArgs.AllowUnsignedInstaller = $true }
                    Invoke-CheckedMigrationScript 'mig_prep.ps1' $driverArgs -WarningCodes @(3010)
                } else {
                    Write-Warning 'Source driver installation skipped. Confirm that the restore method supplies boot-critical storage drivers before the first Windows boot.'
                    $script:PhaseExitCode = 1
                }
                # The standalone exporter is read-only by default; Prepare preserves the original service-disable workflow.
                $exportArgs = @{}
                if ($DisableVMwareTools) { $exportArgs.DisableVMwareTools = $true; $exportArgs.Confirm = $false }
                Invoke-CheckedMigrationScript 'Export-MigrationState.ps1' $exportArgs -WarningCodes @(50)
                Write-MigrationCaptureSummary
            } elseif (-not $WhatIfPreference) { $script:PhaseExitCode = 1 }
        }
        'ValidatePost' {
            $selectedState = Resolve-MigrationStateDirectory -StateDirectory $StateDirectory
            # Also checked by the standalone restore script; never race Firstboot.
            $firstboot = Assert-MigrationFirstbootComplete -FirstbootNotUsed:$FirstbootNotUsed
            Write-Host "Firstboot status: $($firstboot.state)"
            if (-not $WhatIfPreference -and -not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Restore captured network settings and validate after Firstboot')) {
                $script:PhaseExitCode = 1
                break
            }
            $restoreArgs = @{ Mode = 'Full'; StateDirectory = $selectedState; Confirm = $false }
            if ($AdapterMappingPath) { $restoreArgs.AdapterMappingPath = $AdapterMappingPath }
            if ($FirstbootNotUsed) { $restoreArgs.FirstbootNotUsed = $true }
            if ($RepairOfflineDisks) { $restoreArgs.RepairOfflineDisks = $true }
            if ($RemoveHiddenVMwareAdapters) { $restoreArgs.RemoveHiddenVMwareAdapters = $true }
            if ($DeepScan) { $restoreArgs.DeepScan = $true }
            if ($DnsTestHost) { $restoreArgs.DnsTestHost = $DnsTestHost }
            if ($ApplicationConfigPath) { $restoreArgs.ApplicationConfigPath = $ApplicationConfigPath }
            if ($PSBoundParameters.ContainsKey('MigrationTimestamp')) { $restoreArgs.MigrationTimestamp = $MigrationTimestamp.ToString('o') }
            if ($WhatIfPreference) { $restoreArgs.WhatIf = $true }
            Invoke-CheckedMigrationScript 'Restore-And-TestMigrationState.ps1' $restoreArgs
            if ($role -eq 'DomainController' -and -not $WhatIfPreference) {
                Invoke-CheckedMigrationScript 'Test-DCMigrationHealth.ps1' @{ Mode = 'PostMigration' }
            }
        }
    }
    if ($WhatIfPreference) { Write-Host "$Phase preview completed; no preparation or restoration was applied." }
    elseif ($script:PhaseExitCode -eq 0) { Write-Host "$Phase completed successfully." }
    else { Write-Warning "$Phase completed with warnings. Review the reports before approving the migration." }
    exit $script:PhaseExitCode
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    $code = Get-MigrationProperty $_.Exception.Data 'MigrationExitCode' 2
    exit ([int]$code)
}
