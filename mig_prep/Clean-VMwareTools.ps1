#Requires -Version 5.1
<#
.SYNOPSIS
    Automated cleanup script for VMware Tools removal on Windows Server.

.DESCRIPTION
    Removes VMware Tools completely using hybrid approach:
    - Phase 1: Attempts uninstall via MSI (msiexec.exe)
    - Phase 2: If Phase 1 fails, aggressive cleanup (services, registry, processes)
    - Phase 3: Comprehensive verification
    - Exports registry backup before any deletion
    - Checks both 64-bit and 32-bit registry paths
    - Stops and deletes VMware services
    - Auto-discovers VMware Tools registry key
    - Manual reboot required after cleanup
    - Optional VerifyOnly mode to check artifacts without cleanup

.PARAMETER Force
    Skip confirmation prompts and proceed with cleanup.

.PARAMETER VerifyOnly
    Read-only mode: Check what VMware artifacts remain without performing any cleanup or reboot.

.PARAMETER RegistryPath
    Registry path to VMware Tools entry. Default: HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{298083DA-1DC8-4886-97DD-333954302E68}

.EXAMPLE
    .\Clean-VMwareTools.ps1
    # Interactive cleanup with manual reboot

.EXAMPLE
    .\Clean-VMwareTools.ps1 -Force
    # Automatic cleanup without prompts

.EXAMPLE
    .\Clean-VMwareTools.ps1 -VerifyOnly
    # Check what VMware artifacts remain (read-only)

.NOTES
    Must be run as Administrator.
    Designed for Windows Server 2016, 2019, 2022, 2025.
    Exit codes: 0 = Success, 1 = Failure, 2 = User cancelled
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$VerifyOnly,
    [string]$RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{298083DA-1DC8-4886-97DD-333954302E68}',
    [string]$ExportPath = (Join-Path (Split-Path $PSScriptRoot) 'Migration-Export')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Verify Administrator
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )
    $color = switch ($Type) {
        'Info'    { 'Cyan' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }
    $prefix = switch ($Type) {
        'Info'    { '[*]' }
        'Success' { '[✓]' }
        'Warning' { '[!]' }
        'Error'   { '[✗]' }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Get-UserConfirmation {
    param([string]$Message)
    if ($Force) { return $true }
    
    $response = Read-Host "$Message (y/n)"
    return $response -eq 'y' -or $response -eq 'yes'
}

function Discover-VMwareToolsKey {
    Write-Status 'Discovering VMware Tools registry key...'
    
    $found = @(
        Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
    ) | Where-Object DisplayName -Match 'VMware Tools'
    
    if ($found.Count -eq 0) {
        return $null
    } elseif ($found.Count -eq 1) {
        $key = $found.PSChildName
        $path = if ($found.PSPath -match 'WOW6432Node') {
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$key"
        } else {
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$key"
        }
        Write-Status "Found VMware Tools key: $key" 'Success'
        return $path
    } else {
        Write-Status "Multiple VMware Tools entries found:" 'Warning'
        $i = 0
        foreach ($entry in $found) {
            $hive = if ($entry.PSPath -match 'WOW6432Node') { '(32-bit)' } else { '(64-bit)' }
            Write-Host "  [$i] $($entry.PSChildName) - $($entry.DisplayVersion) $hive" -ForegroundColor Yellow
            $i++
        }
        if (-not $Force) {
            $selection = Read-Host "Select entry (0-$($found.Count - 1))"
            if ($selection -match '^\d+$' -and [int]$selection -lt $found.Count) {
                $key = $found[$selection].PSChildName
                $path = if ($found[$selection].PSPath -match 'WOW6432Node') {
                    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$key"
                } else {
                    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$key"
                }
                return $path
            }
        }
        return $null
    }
}

# Main cleanup logic
try {
    if (-not (Test-Administrator)) {
        Write-Status 'This script must run as Administrator.' 'Error'
        exit 1
    }

    Write-Host "`n" + ('='*60)
    Write-Host "  VMware Tools Cleanup Utility" -ForegroundColor Cyan
    Write-Host ('='*60) + "`n"

    # Initialize timestamp for export files
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    # Step 1: Check registry and setup (skip in VerifyOnly mode)
    if (-not $VerifyOnly) {
        Write-Status 'Checking for VMware Tools registry entry...'
    
    if (-not $VerifyOnly) {
            Write-Status "Default key not found at $RegistryPath" 'Warning'
            $discoveredPath = Discover-VMwareToolsKey
            
            if ($discoveredPath) {
                $RegistryPath = $discoveredPath
            } else {
                Write-Status 'No VMware Tools registry entry found. Already cleaned?' 'Error'
                exit 1
            }
        }
        
        $regEntry = Get-ItemProperty -LiteralPath $RegistryPath
        Write-Status "Found: $($regEntry.DisplayName)" 'Success'

        # Step 1.5: Export registry before deletion
        Write-Status "`nExporting registry backup..."
    
        try {
            if (-not (Test-Path -LiteralPath $ExportPath)) {
                New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
                Write-Status "Created export folder: $ExportPath" 'Success'
            }
        
        $exportFile = Join-Path $ExportPath "VMwareTools_Backup_$timestamp.reg"
        
        # Extract the registry path without HKLM:\ prefix for reg export command
        $regPathForExport = $RegistryPath -replace 'HKLM:\\', ''
        
        & reg export "HKLM\$regPathForExport" "$exportFile" /y 2>&1 | Out-Null
        
        if (Test-Path -LiteralPath $exportFile) {
            Write-Status "Registry exported to: $exportFile" 'Success'
        } else {
            throw 'Export file not created'
        }
        }
        catch {
            Write-Status "Failed to export registry: $($_.Exception.Message)" 'Warning'
        }
    }

    # Step 2: Phase 1 - Try uninstall via MSI (skip in VerifyOnly mode)
    if (-not $VerifyOnly) {
        Write-Status "`nPhase 1: Attempting MSI uninstall..."
        $msiUninstallSuccess = $false
        
        try {
            # Get product code from registry
            $productCode = $regEntry.PSChildName
            if ($productCode -match '^\{[0-9A-F\-]+\}$') {
                Write-Host "   Product Code: $productCode" -ForegroundColor Gray
                
                if (Get-UserConfirmation 'Execute MSI uninstall?') {
                    $uninstallLog = Join-Path $ExportPath "VMwareTools_Uninstall_$timestamp.log"
                    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $productCode, '/qn', '/norestart', '/l*v', $uninstallLog) -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
                    
                    Write-Host "   msiexec exit code: $($process.ExitCode)" -ForegroundColor Gray
                    if ($process.ExitCode -in @(0, 3010)) {
                        $msiUninstallSuccess = $true
                        Write-Status "Phase 1 (MSI) succeeded! Exit code: $($process.ExitCode)" 'Success'
                        if ($process.ExitCode -eq 3010) {
                            Write-Status "Note: Reboot will be required to complete uninstall." 'Info'
                        }
                        Start-Sleep -Seconds 2
                    } else {
                        Write-Status "Phase 1 (MSI) failed with exit code $($process.ExitCode). Proceeding to Phase 2." 'Warning'
                    }
                } else {
                    Write-Status 'Cancelled by user' 'Warning'
                    exit 2
                }
            } else {
                Write-Status "Invalid product code format: $productCode. Proceeding to Phase 2." 'Warning'
            }
        }
        catch {
            Write-Status "Phase 1 error: $($_.Exception.Message)" 'Warning'
            Write-Status 'Proceeding to Phase 2 (aggressive cleanup)...' 'Info'
        }
    }

    # Step 3: Phase 2 - If Phase 1 failed, aggressive cleanup (skip in VerifyOnly mode)
    if (-not $VerifyOnly -and -not $msiUninstallSuccess) {
        Write-Status "`nPhase 2: Aggressive cleanup..."
        
        # Stop VMware services
        Write-Status "Stopping VMware services..."
        $servicesToStop = @('VMTools', 'VGAuthService', 'VMVss', 'VM3DService', 'vm3dservice')
        foreach ($svc in $servicesToStop) {
            $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($service -and $service.Status -eq 'Running') {
                try {
                    Stop-Service -Name $svc -Force -ErrorAction Stop
                    Write-Status "Stopped service: $svc" 'Success'
                } catch {
                    Write-Status "Failed to stop service $svc : $($_.Exception.Message)" 'Warning'
                }
            }
        }
        Start-Sleep -Milliseconds 500
        
        # Delete services via sc.exe
        Write-Status "Deleting VMware services..."
        foreach ($svc in $servicesToStop) {
            & sc.exe delete $svc 2>&1 | Out-Null
            $scExitCode = $LASTEXITCODE
            if ($scExitCode -eq 0 -or $scExitCode -eq 1072) {
                Write-Status "Deleted service: $svc" 'Success'
            } else {
                Write-Status "Service $svc : exit code $scExitCode" 'Info'
            }
        }
        
        # Delete all VMware registry entries (both 64-bit and 32-bit)
        Write-Status "Removing VMware registry entries..."
        $vmwareKeys = @(
            Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
            Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        ) | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'VMware Tools' }
        
        foreach ($key in $vmwareKeys) {
            try {
                $regPath = $key.PSPath
                $keyName = Split-Path -Leaf $regPath
                Write-Host "   Found registry key: $keyName" -ForegroundColor Gray
                
                # Export for audit trail
                $auditExport = Join-Path $ExportPath "VMwareTools_${keyName}_audit.reg"
                & reg export $regPath $auditExport /y 2>&1 | Out-Null
                Write-Host "   Exported to: $auditExport" -ForegroundColor Gray
                
                # Delete the registry key
                Remove-Item -Path $regPath -Recurse -Force -ErrorAction Stop
                Write-Status "Deleted registry key: $keyName" 'Success'
            } catch {
                Write-Status "Error processing registry key: $($_.Exception.Message)" 'Warning'
            }
        }
    }

    # Step 4: Kill remaining VMware processes (skip in VerifyOnly mode)
    Write-Status "`nStopping VMware processes..."
    if (-not $VerifyOnly) {
    
    if ($vmwareProcesses) {
        foreach ($proc in $vmwareProcesses) {
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                Write-Status "Stopped: $($proc.Name) (PID $($proc.Id))" 'Success'
            }
            catch {
                Write-Status "Failed to stop $($proc.Name): $($_.Exception.Message)" 'Warning'
            }
        }
        Start-Sleep -Seconds 2
    } else {
        Write-Status 'No VMware processes found' 'Info'
    }

    # Step 5: Delete program files
    Write-Status "`nRemoving program files..."
    if (-not $VerifyOnly) {
        'C:\Program Files\VMware\VMware Tools',
        'C:\Program Files (x86)\VMware\VMware Tools',
        'C:\Program Files\VMware',
        'C:\Program Files (x86)\VMware'
        )

        foreach ($path in $pathsToClean) {
            if (Test-Path -LiteralPath $path) {
                try {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                    Write-Status "Deleted: $path" 'Success'
                }
                catch {
                    Write-Status "Failed to delete $path : $($_.Exception.Message)" 'Warning'
                }
            }
        }
    } else {
        Write-Status 'Skipped (VerifyOnly mode)' 'Info'
    }

    # Step 6: Phase 3 - Comprehensive verification
    Write-Status "`nPhase 3: Verification..."
    Start-Sleep -Milliseconds 1000
    
    # Check WMI for VMware products and remove if found
    Write-Status "Checking WMI for VMware products..."
    $wmiProducts = Get-WmiObject Win32_Product -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'VMware' }
    if ($wmiProducts) {
        Write-Status "Found VMware products in WMI. Attempting to remove..." 'Warning'
        foreach ($product in $wmiProducts) {
            try {
                Write-Host "   Removing: $($product.Name) (Version: $($product.Version))" -ForegroundColor Gray
                $product.Uninstall() | Out-Null
                Write-Status "Removed WMI product: $($product.Name)" 'Success'
            } catch {
                Write-Status "Warning: Could not remove WMI product $($product.Name): $($_.Exception.Message)" 'Warning'
            }
        }
        # Verify removal
        Start-Sleep -Seconds 2
        $wmiCheck = Get-WmiObject Win32_Product -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'VMware' }
        if ($wmiCheck) {
            Write-Status "Warning: VMware products still in WMI after uninstall attempt" 'Warning'
        } else {
            Write-Status "All VMware products removed from WMI" 'Success'
        }
    } else {
        Write-Status "No VMware products found in WMI" 'Success'
    }
    
    # Check for VMware services
    Write-Status "Checking for VMware services..."
    $vmServices = Get-Service -Name '*vm*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'VM|VMware|vgauth' }
    if ($vmServices) {
        Write-Status "Warning: Services still present: $($vmServices.Name -join ', ')" 'Warning'
    } else {
        Write-Status "No VMware services found" 'Success'
    }
    
    # Check registry (both 64-bit and 32-bit)
    Write-Status "Checking registry for VMware Tools entries..."
    $regCheck = @(
        Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
    ) | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'VMware Tools' }
    
    if ($regCheck) {
        Write-Status "Warning: VMware Tools registry entry still present" 'Warning'
        $regCheck | ForEach-Object { Write-Host "  - $($_.PSChildName): $($_.DisplayName)" -ForegroundColor Yellow }
    } else {
        Write-Status "No VMware Tools entries in registry" 'Success'
    }

    # Step 7: Summary
    Write-Host "`n" + ('='*60)
    
    if ($VerifyOnly) {
        Write-Status 'Verification complete. No cleanup was performed.' 'Info'
    } else {
        Write-Status 'Cleanup complete.' 'Success'
    }
    
    Write-Status 'IMPORTANT: Manual reboot is required to complete the process.' 'Warning'
    Write-Host "`nReboot command: Restart-Computer -Force`n" -ForegroundColor Yellow

    exit 0
}
catch {
    Write-Status "Unexpected error: $($_.Exception.Message)" 'Error'
    exit 1
}
