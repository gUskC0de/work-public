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

**Output:** `C:\Migration\Logs\MigrationReadiness.log` + JSON report

---

### `Export-MigrationState.ps1` (State Capture)

Captures network and system state before migration. Called during Prepare phase.

**Manual usage:**
```powershell
.\Export-MigrationState.ps1
```

**Outputs to:**
```
C:\Rutin_migration_YYYY-MM-DD\
├── Export-MigrationState\
│   ├── State\
│   │   ├── PreMigrationState.json      (System info, disks)
│   │   ├── NetworkConfiguration.json   (Adapters, IP, DNS, routes)
│   │   └── [other captured data]
│   └── Logs\
│       └── CaptureData.log
```

**Key action:** Disables VMware Tools services (keeps software for rollback)

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

The restore script automatically maps the source VM's active NIC to the Proxmox VM's VirtIO adapter:

1. **Detects** single active network adapter from source state
2. **Identifies** VirtIO adapter on target VM (checks MAC, adapter name patterns)
3. **Applies** IP, DNS, gateway settings to VirtIO adapter
4. **Enables** network adapter (if disabled)
5. **Restores** static routes and ARP entries

If multiple adapters were active on source, manual validation and mapping may be required.

---

## Troubleshooting

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
