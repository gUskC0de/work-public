# VMware-to-Proxmox Migration Automation

Complete PowerShell-based workflow for migrating Windows Server VMs from VMware to Proxmox KVM using Veeam Restore. Handles driver installation, system state capture, network configuration restoration, and post-migration validation.

## Overview

This migration toolkit solves the "chicken-and-egg" problem where domain login requires network connectivity, but network configuration wasn't applied until after migration. The workflow captures network settings before migration and restores them immediately after, ensuring network availability at startup.

### Supported Targets
- Windows Server 2016, 2019, 2022, 2025
- PowerShell 5.1+
- Proxmox 7.x and later (VirtIO NIC)

### Migration Phases

```
Phase 1: ReadinessCheck    (Source VM)  ← Validation only, no changes
Phase 2: Prepare           (Source VM)  ← VirtIO driver + state capture
         [Veeam Restore]   (Migration)  ← Restore to Proxmox
Phase 3: ValidatePost      (Target VM)  ← Network restoration + validation
```

---

## Quick Start

Open **Windows PowerShell as Administrator** on the source VM and run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Migrate-VmwareToProxmox.ps1
```

This displays an interactive menu. Select:
1. **ReadinessCheck** – Validate system readiness (no changes)
2. **Prepare** – Install VirtIO drivers and capture system state
3. **ValidatePost** – Restore network after Veeam restore (run on target Proxmox VM)

---

## Workflow Details

### Phase 1: ReadinessCheck (Source VM)

Performs non-invasive validation checks:

```powershell
.\Migrate-VmwareToProxmox.ps1 -Phase ReadinessCheck
```

**Checks performed:**
- Administrator privileges
- Mounted CD/DVD/ISO media
- VirtIO driver presence
- VMware Tools status (informational)
- Network adapter configuration
- Pending reboot status
- Disk and filesystem health
- Event log errors/warnings
- VSS writer status
- Windows Update state
- System identity

**Output:** Human-readable report + structured JSON report  
**Exit code:** 0 = all green, 1 = warnings, 2 = critical failures

---

### Phase 2: Prepare (Source VM)

Prepares the VM for migration:

```powershell
.\Migrate-VmwareToProxmox.ps1 -Phase Prepare
```

**Actions:**
1. Installs VirtIO SCSI drivers (required for Proxmox block device access)
2. Executes `Export-MigrationState.ps1`:
   - Captures active network adapter configuration (IP, DNS, gateways, routes)
   - Captures system state (computer name, disk configuration, services)
   - Disables VMware Tools services (keeps software installed for rollback)
3. Outputs state files to: `C:\Rutin_migration_YYYY-MM-DD\Export-MigrationState\State\`

**State Files Generated:**
- `PreMigrationState.json` – System info, computer name, disk state
- `NetworkConfiguration.json` – Active adapters, IPv4 settings, DNS, routes

**Important:** After Prepare completes, proceed with Veeam restore immediately. Do not restart or modify network settings.

---

### Phase 3: ValidatePost (Target Proxmox VM)

After Veeam restore completes on the Proxmox VM:

```powershell
.\Migrate-VmwareToProxmox.ps1 -Phase ValidatePost
```

**Actions:**
1. Runs `Restore-And-TestMigrationState.ps1` in Full mode:
   - Restores network configuration to VirtIO adapter (maps source NIC → VirtIO NIC)
   - Enables network adapter and applies IP settings
   - Restores static routes and DNS configuration
   - Validates post-migration state (disks, services, connectivity)
   - **Uninstalls VMware Tools** (only after validation passes)

**Validation checks:**
- System identity verification
- Disk online state
- Network connectivity
- QEMU Guest Agent presence (optional, for Proxmox management)
- VSS writer functionality
- Service comparison (source vs. restored)

**Output:** Structured validation report with pass/fail status for each component

---

## Script Reference

### `Migrate-VmwareToProxmox.ps1` (Main Orchestration)

Interactive workflow orchestrator. Guides users through phases and calls dependent scripts.

**Usage:**
```powershell
.\Migrate-VmwareToProxmox.ps1                          # Interactive menu
.\Migrate-VmwareToProxmox.ps1 -Phase ReadinessCheck    # Direct phase selection
.\Migrate-VmwareToProxmox.ps1 -Phase Prepare
.\Migrate-VmwareToProxmox.ps1 -Phase ValidatePost
```

---

### `mig_prep.ps1` (VirtIO Driver Setup)

Installs and verifies VirtIO SCSI drivers. Called automatically during Prepare phase.

**Manual usage:**
```powershell
.\mig_prep.ps1
.\mig_prep.ps1 -KeepArtifacts                          # Keep downloaded files
.\mig_prep.ps1 -ExpectedInstallerSha256 '<hash>'       # Verify installer hash
.\mig_prep.ps1 -AllowUnsignedInstaller                 # Allow unsigned installer
.\mig_prep.ps1 -Mode offline -InstallerSourcePath 'D:\virtio-win-guest-tools.exe' -InitScriptSourcePath 'D:\load-virtio-scsi-on-boot.ps1'
```

**Verification:** Confirms driver is installed, signed, and boot-configured.  
**Output:** `driver-install.log`, `driver-status.json`

---

### `Test-MigrationReadiness.ps1` (Pre-Migration Validation)

Comprehensive readiness check. Called during ReadinessCheck phase.

**Manual usage:**
```powershell
.\Test-MigrationReadiness.ps1
.\Test-MigrationReadiness.ps1 -EventLookbackHours 48
.\Test-MigrationReadiness.ps1 -CriticalSystemFreeSpaceGB 5
```

**Service Health Check:**
The script validates automatic services and reports stopped services as warnings. However, services with **"Automatic (Trigger Start)"** startup type are intentionally excluded from warnings because they are designed to remain stopped until needed (e.g., Remote Registry). Only truly unconditional "Automatic" services generate warnings if stopped.

**Output:** `C:\Migration\Logs\MigrationReadiness.log` + JSON report

---

### `Export-MigrationState.ps1` (State Capture)

Captures network and system state before migration. Called during Prepare phase.

**Manual usage:**
```powershell
.\Export-MigrationState.ps1
```

**Handling of multiple network adapters:**
- All active adapters are captured and exported, regardless of count
- If multiple adapters detected, a WARNING is logged (not a failure)
- Script completes successfully; you have all adapter configuration data
- Restore script will apply the first adapter automatically
- Additional adapters require manual configuration using the exported data

**Outputs to:**
```
C:\Rutin_migration_YYYY-MM-DD\
├── Export-MigrationState\
│   ├── State\
│   │   ├── PreMigrationState.json      (System info, disks)
│   │   ├── NetworkConfiguration.json   (All adapters, IP, DNS, routes)
│   │   └── [other captured data]
│   └── Logs\
│       └── CaptureData.log
```

**Key actions:** 
- Disables VMware Tools services (keeps software for rollback)
- Exports all network adapter information for reference

---

### `Restore-And-TestMigrationState.ps1` (Post-Migration Restoration)

Restores network config and validates migration success. Called during ValidatePost phase.

**Manual usage:**
```powershell
.\Restore-And-TestMigrationState.ps1 -StateDirectory 'C:\Rutin_migration_2026-10-10\Export-MigrationState\State' -Mode Full
```

**Modes:**
- `ValidateOnly` – Read-only validation (no changes)
- `ApplyNetwork` – Restore network only
- `CompareOnly` – Compare source vs. target state
- `Full` – Apply network + full validation + uninstall VMware Tools (DEFAULT in orchestration)

**Network restoration behavior:**
- **Single active adapter (automatic):** Restores IP, DNS, gateway, and routes to VirtIO adapter
- **Multiple active adapters (mixed):**
  - Automatic restoration applies first adapter configuration only
  - Generates detailed report with all available adapters
  - Manual intervention required to configure additional adapters
  - Use the exported NetworkConfiguration.json for reference

**Example manual configuration for additional adapters:**
```powershell
# Get all exported adapters
$networkConfig = Get-Content 'C:\Rutin_migration_2026-10-10\Export-MigrationState\State\NetworkConfiguration.json' | ConvertFrom-Json

# Apply second adapter configuration manually
$secondAdapter = $networkConfig.activeAdapters[1]
Get-NetAdapter -Name $secondAdapter.adapterName | New-NetIPAddress -IPAddress $secondAdapter.ipv4Addresses[0].address -PrefixLength $secondAdapter.ipv4Addresses[0].prefixLength
Get-DnsClientServerAddress -InterfaceAlias $secondAdapter.adapterName -AddressFamily IPv4 | Set-DnsClientServerAddress -ServerAddresses $secondAdapter.dnsServers
```

**Outputs to:**
```
C:\Rutin_migration_YYYY-MM-DD\
└── Restore-And-TestMigrationState\
    ├── Logs\
    │   ├── PostMigrationValidation.log
    │   └── vmware-tools-uninstall.log
    └── Reports\
        ├── PostMigrationValidation.json
        └── PostMigrationValidation.txt
```

---

### `Test-DCMigrationHealth.ps1` (Domain Controller Only)

Domain Controller-specific health checks. Optional for DC migrations.

**Usage:**
```powershell
.\Test-DCMigrationHealth.ps1 -Mode PreMigration    # Source VM
.\Test-DCMigrationHealth.ps1 -Mode PostMigration   # Target VM
```

---

## Technical Updates

### PowerShell 5.1 Compatibility (Recent Fix)

All scripts have been validated for **PowerShell 5.1+** compatibility (Windows Server 2016+). Specifically:

- **Restore-And-TestMigrationState.ps1**: Removed PowerShell 7+ null-coalescing operators (`??`) and replaced with PowerShell 5.1-compatible ternary expressions
- All scripts avoid PowerShell 7+ specific syntax to ensure broad compatibility

### Service Health Check Improvements

**Test-MigrationReadiness.ps1** (pre-migration) and **Restore-And-TestMigrationState.ps1** (post-migration) now intelligently exclude services designed to be stopped:

**Pre-Migration (Test-MigrationReadiness.ps1):**
- **Trigger-start services** (checked via `TriggerInfo` registry key) – Excluded from warnings (e.g., Remote Registry)
- **Delayed-start services** – Excluded from warnings (by design, start after boot)
- **Task Scheduler managed** (GoogleUpdater*, etc.) – Excluded from warnings
- **Only unconditional Automatic services** that are stopped generate warnings

**Post-Migration Service Comparison (Restore-And-TestMigrationState.ps1):**
Validates that Automatic services captured before migration are still running after migration. Intelligently categorizes stopped services:
- **VMware services** (VMTools, VGAuthService, vdservice, VM3DService) – Expected to be stopped, informational only
- **User session services** (SID-based, e.g., EventSystem_1) – Expected to be stopped, informational only
- **Migration-related services** (DeviceInstall, DsmSvc, IfsVsc, IKEEXT, PolicyAgent, SharedAccess) – Expected to be stopped, informational only
- **QEMU guest services** (spice-agent, qemu-ga, QEMU-GA) – Expected to be stopped, informational only
- **Trigger-start services** – Automatically excluded (via TriggerInfo registry check)
- **Task Scheduler managed** (GoogleUpdater*, GoogleUpdaterInternal*) – Automatically excluded

Only **truly unexpected** Automatic service stops generate a WARNING and require review.

This eliminates false positives and focuses warnings on actual migration issues.

---

## VMware Tools Handling

### Timeline
1. **Prepare Phase (Source VM):**
   - Test-MigrationReadiness reports VMware Tools status (informational only)
   - Export-MigrationState **disables** VMware Tools services
   - VMware Tools software **remains installed** (rollback safety)

2. **After Veeam Restore (Target VM):**
   - Restore-And-TestMigrationState runs validation
   - **Uninstalls** VMware Tools only after network and validation pass
   - Exit code indicates success/failure

### Why This Approach?
- **Safe rollback:** If migration fails, re-enable VMware Tools and stay on VMware
- **No reinstall overhead:** Don't reinstall tools if you abort early
- **Committed path:** Only uninstall after validation succeeds

---

## Network Adapter Mapping

The restore script automatically maps the source VM's active NIC(s) to the Proxmox VM's VirtIO adapter:

1. **Detects** all active network adapters from source state
2. **Single NIC case (automatic):**
   - Identifies VirtIO adapter on target VM (checks MAC, adapter name patterns)
   - Applies IP, DNS, gateway settings to VirtIO adapter
   - Enables network adapter (if disabled)
   - Restores static routes and ARP entries
3. **Multiple NIC case (manual):**
   - Exports all adapter configurations to `NetworkConfiguration.json`
   - Sets `requiresManualNetworkHandling: true` flag in output
   - Automatic restoration applies the first active adapter
   - You must manually configure additional adapters using the exported configuration data
   - All adapter details are available for reference in the state files
4. **No VirtIO adapter case:**
   - Network restoration is gracefully skipped (no exit/failure)
   - All other validation checks continue
   - Useful in ValidateOnly mode or when manually handling network configuration

**Exported data for multiple NICs includes:**
- Adapter names, descriptions, and hardware addresses (MAC)
- IPv4 addresses, subnet masks, and gateway settings
- DNS server addresses and suffixes
- Static routes and metrics
- VLAN information (if configured)
- Network profiles and connectivity status

---

## Troubleshooting

### Multiple Network Adapters Detected
1. Check the capture log: `C:\Rutin_migration_YYYY-MM-DD\Export-MigrationState\Logs\CaptureData.log`
2. Review all captured adapter configurations: `NetworkConfiguration.json`
3. After restore, verify first adapter restored correctly: `Get-NetIPConfiguration`
4. Manually apply remaining adapter configurations using the exported configuration data (see Restore script reference)

### Network Not Active After Restore
1. Check logs: `C:\Rutin_migration_YYYY-MM-DD\Restore-And-TestMigrationState\Logs\PostMigrationValidation.log`
2. Verify VirtIO adapter is enabled: `Get-NetAdapter` in PowerShell
3. Manually apply IP config if needed: `New-NetIPAddress -InterfaceAlias <adapter> -IPAddress <ip> -PrefixLength <mask>`

### VMware Tools Uninstall Failed
1. Check uninstall log: `C:\Rutin_migration_YYYY-MM-DD\Restore-And-TestMigrationState\Logs\vmware-tools-uninstall.log`
2. Uninstall manually: Control Panel → Programs → Programs and Features
3. Restart VM to complete uninstall

### Rollback to VMware
1. If migration fails, return to source VM
2. Re-enable VMware Tools services: `Get-Service VMTools | Set-Service -StartupType Automatic; Start-Service VMTools`
3. Restart VM to reconnect network

---

## File Structure

```
mig_prep/
├── Migrate-VmwareToProxmox.ps1         # Main orchestration (entry point)
├── mig_prep.ps1                        # VirtIO driver installation
├── load-virtio-scsi-on-boot.ps1        # VirtIO boot initialization
├── Test-MigrationReadiness.ps1         # Pre-migration validation
├── Test-DCMigrationHealth.ps1          # DC-specific checks (optional)
├── Export-MigrationState.ps1           # State capture before migration
├── Restore-And-TestMigrationState.ps1  # State restoration after migration
└── README.md                           # This file
```

---

## Exit Codes

Scripts return standard exit codes:

- `0` – Success
- `1` – Warnings (non-blocking issues)
- `2` – Failures (blocking issues)
- `10–49` – Phase-specific errors (see logs for details)
- `99` – Unexpected error (see exception message in logs)

---

## Security Notes

- Scripts require Administrator privileges
- Network credentials are not stored; domain login occurs at normal Windows startup
- State files contain network configuration (sensitive) – protect access to `C:\Rutin_migration_*`
- All operations are logged; review logs for compliance/auditing
- VMware Tools uninstall is irreversible; validate migration success before this step

---

## Support & Logging

All scripts generate detailed logs and JSON reports:

- Text logs: Human-readable execution flow
- JSON reports: Structured data for programmatic analysis
- Location: `C:\Rutin_migration_YYYY-MM-DD\` with phase-specific subdirectories

Review logs when troubleshooting or reporting issues. Include relevant log file excerpts when seeking support.
