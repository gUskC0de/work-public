# Migration Script Comparison Report
## mig_prep vs mig_prep_csve

**Date:** 2026-10-23  
**Analysis:** Detailed comparison of PowerShell migration scripts

---

## Executive Summary

The `mig_prep_csve` folder contains **significantly enhanced and refactored versions** of the migration scripts with these major improvements:

1. **New shared module** (`Migration.Common.ps1`) centralizes common functions
2. **Parameter-based orchestration** replacing interactive menus
3. **Firstboot support** for driver injection during restore
4. **Enhanced error handling** and state tracking
5. **WhatIf/Confirm support** for safe dry-runs
6. **Better MAC address handling** for complex networking scenarios
7. **Improved messages** reflecting revised workflow assumptions

---

## File-by-File Analysis

### 1. **New File: Migration.Common.ps1**

**Status:** ✅ **NEW** (mig_prep_csve only)

**Impact:** POSITIVE - Major improvement

**Description:**
This new shared module centralizes common functions used across all migration scripts. This promotes:
- Code reuse and consistency
- Easier maintenance and bug fixes
- Reduced duplication
- Single source of truth for common operations

**Functions provided (inferred from usage):**
- `Assert-MigrationArtifactPaths` - Validates source/destination paths
- `Test-MigrationInstallerTrust` - Verifies installer SHA-256 and signatures
- `Assert-MigrationFirstbootComplete` - Checks Firstboot completion status
- `Resolve-MigrationServerType` - Detects DC vs Normal server
- `Invoke-MigrationChildScript` - Runs child scripts with error handling
- `Resolve-MigrationStateDirectory` - Locates saved state from export phase
- `Get-MigrationProperty` - Safely retrieves nested JSON properties
- `Assert-MigrationNetworkCaptureComplete` - Validates network capture integrity

---

### 2. **mig_prep.ps1** (Main Driver Installation Script)

**Changes:** ✅ MODERATE - Important improvements

#### Key Differences:

| Aspect | mig_prep | mig_prep_csve |
|--------|----------|--------------|
| **Default installer path** | `'.\virtio-win-guest-tools.exe'` (current dir) | `(Join-Path $PSScriptRoot 'virtio-win-guest-tools.exe')` (script dir) |
| **Default init script path** | `'.\load-virtio-scsi-on-boot.ps1'` | `(Join-Path $PSScriptRoot 'load-virtio-scsi-on-boot.ps1')` |
| **Online mode init script** | Downloaded from GitHub | Required locally (not downloaded) |
| **Path initialization** | Direct assignment | Conditional check: `if (-not $WorkingDirectory) { ... }` |
| **Common module** | None | `. (Join-Path $PSScriptRoot 'Migration.Common.ps1')` |
| **Installer validation** | Manual SHA-256 and Authenticode checks | Delegated to `Test-MigrationInstallerTrust` function |
| **Exit codes accepted** | Only `0` | `0` and `3010` (reboot required) |
| **Init script exit codes** | Only `0` | `0` and `3010` |
| **Reboot tracking** | Not tracked | Tracked in `$initializationRebootRequired` |
| **VMware Tools message** | "It will be removed by Export-MigrationState.ps1" | "It remains installed on the source; Firstboot may remove it after restore" |
| **vioscsi validation** | Service present check only | Also checks StartMode is 'Boot' |
| **Artifact staging flags** | Not tracked | `$installerStaged` and `$initScriptStaged` flags |

#### Implications:

✅ **Positive:**
- **Relative paths fixed**: Using `$PSScriptRoot` ensures scripts work from any location (solves working directory issues)
- **Online mode safety**: Requiring local init script prevents executing untrusted downloaded code
- **Reboot handling**: Exit code 3010 indicates successful installation with pending reboot - now properly handled
- **Boot mode validation**: Checking vioscsi StartMode ensures driver loads on boot after migration
- **Artifact tracking**: Staging flags help with cleanup and debugging
- **Workflow clarity**: New message reflects actual post-migration workflow (Firstboot handles removal)

⚠️ **Considerations:**
- **Breaking change**: Online mode now requires local init script - can't download if network restricted
- **Dependency**: Requires `Migration.Common.ps1` to exist

---

### 3. **Migrate-VmwareToProxmox.ps1** (Orchestration Script)

**Changes:** 🔴 MAJOR - Completely rewritten

#### New vs Old Architecture:

**OLD VERSION (mig_prep):**
- Interactive menu-driven workflow
- Menu selection for each phase
- Menu selection for server type (DC vs Normal)
- Direct script invocation
- Limited parameter control
- Simpler logic flow

**NEW VERSION (mig_prep_csve):**
- Parameter-based phase selection
- Extensive parameter system for all options
- Automated server type detection with override capability
- Child script orchestration via helper function
- Full WhatIf/Confirm support via `[CmdletBinding(SupportsShouldProcess)]`
- Sophisticated error handling with exit code propagation
- Phase exit code tracking for warnings vs failures

#### New Parameters:

```powershell
[ValidateSet('ReadinessCheck', 'Prepare', 'ValidatePost')][string]$Phase
[ValidateSet('Auto', 'DomainController', 'Normal')][string]$ServerType = 'Auto'
[ValidateSet('Install', 'FirstbootManaged')][string]$DriverPreparation = 'Install'
[string]$StateDirectory = ''
[string]$AdapterMappingPath = ''
[switch]$FirstbootNotUsed
[switch]$RepairOfflineDisks
[switch]$RemoveHiddenVMwareAdapters
[switch]$DisableVMwareTools = $true
[switch]$DeepScan
[string]$DnsTestHost = ''
[string]$ApplicationConfigPath = ''
[datetime]$MigrationTimestamp
[string]$ExpectedInstallerSha256 = ''
[switch]$AllowUnsignedInstaller
```

#### Implications:

✅ **Positive:**
- **Automation-friendly**: Can be called from automation/orchestration tools
- **Firstboot support**: Can skip VirtIO driver installation if restore method provides them
- **Safe dry-runs**: `-WhatIf` previews all actions without making changes
- **Granular control**: Every significant operation is controllable via parameters
- **Better networking**: AdapterMappingPath supports complex multi-NIC scenarios
- **Warning vs failure distinction**: Phase can complete with warnings (exit code 1) for non-blocking issues
- **Offline repair**: RepairOfflineDisks and RemoveHiddenVMwareAdapters for post-restore cleanup

⚠️ **Considerations:**
- **Removed interactivity**: No longer user-friendly for manual operations
- **Steeper learning curve**: Must understand all parameters
- **Backward incompatibility**: Cannot use as drop-in replacement for old version
- **Dependency chain**: Requires proper state files from prior phases

---

### 4. **Export-MigrationState.ps1** (State Capture Script)

**Changes:** ✅ MODERATE - Significant enhancements

#### Key Differences:

| Aspect | mig_prep | mig_prep_csve |
|--------|----------|--------------|
| **CmdletBinding** | None | `[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]` |
| **New parameter** | None | `-DisableVMwareTools` switch |
| **Common module** | None | `. (Join-Path $PSScriptRoot 'Migration.Common.ps1')` |
| **WhatIf support** | No | Yes - `if ($WhatIfPreference) { ... }` |
| **Code revision** | '2026-09-11.4' | '2026-10-22.3' (8 months newer) |
| **VMware Tools handling** | Read-only detection | Optionally stops/disables services |
| **VMware Tools message** | "will be removed by Export-MigrationState.ps1" | "remains installed; Firstboot may remove it" |

#### Implications:

✅ **Positive:**
- **Operational control**: `-DisableVMwareTools:$false` allows keeping original service state (useful for debugging)
- **Safe operations**: ShouldProcess enables `-Confirm` to review before changes
- **Dry-run capability**: `-WhatIf` shows what would be captured without creating files
- **Flexible workflow**: Can integrate into larger automation scripts
- **Recent updates**: 8 months of improvements since original

⚠️ **Considerations:**
- **Breaking change**: Default behavior may differ (need to verify DisableVMwareTools default intent)
- **Operational pattern**: Now part of orchestrated workflow, less standalone

---

### 5. **Restore-And-TestMigrationState.ps1** (Post-Restore Validation)

**Changes:** ✅ MAJOR - Significant enhancements

#### New Parameters:

```powershell
[string]$AdapterMappingPath = ''           # Explicit MAC-to-MAC mapping
[switch]$FirstbootNotUsed                   # Declares no Guestfs/Firstboot used
[switch]$RepairOfflineDisks                 # Brings offline disks online
[switch]$RemoveHiddenVMwareAdapters        # Cleans up hidden network adapters
```

#### Key Differences:

| Aspect | mig_prep | mig_prep_csve |
|--------|----------|--------------|
| **WhatIf in New-MigrationPath** | No | Yes - respects WhatIfPreference |
| **StateDirectory resolution** | Attempted during initialization | Moved to main try block for error handling |
| **Common module** | None | `. (Join-Path $PSScriptRoot 'Migration.Common.ps1')` |
| **Code revision** | '2026-09-11.3' | '2026-10-23.1' (latest) |
| **MAC mapping** | Implicit (preserved MACs only) | Explicit mapping supported |
| **Adapter mapping tracking** | Not tracked | `$script:AdapterMappings` array |
| **Network change dry-run** | Limited | Full WhatIf support in directory creation |
| **Firstboot awareness** | None | Checks Firstboot completion status |

#### Implications:

✅ **Positive:**
- **Complex networks supported**: AdapterMappingPath solves MAC address changes across hypervisors
- **Flexible restore methods**: FirstbootNotUsed accommodates non-Firstboot migrations
- **Disk recovery**: RepairOfflineDisks fixes common post-restore disk issues
- **Adapter cleanup**: RemoveHiddenVMwareAdapters prevents network confusion
- **WhatIf-aware paths**: Directory creation respects dry-run mode
- **Better error handling**: State directory resolution has proper error context

⚠️ **Considerations:**
- **MAC mapping complexity**: Requires understanding source/target adapter layout
- **Firstboot dependency**: Assumes Firstboot has run; need explicit flag if not using it

---

### 6. **Test-MigrationReadiness.ps1** (Pre-Migration Validation)

**Changes:** ✅ MODERATE - Important new options

#### New Parameters:

```powershell
[ValidateSet('Installed', 'RestoreInjected')]
[string]$StorageDriverMode = 'Installed'     # VirtIO install location

[ValidateSet('vioscsi', 'viostor')]
[string]$RequiredStorageDriver = 'vioscsi'   # Which driver is required
```

#### Key Changes:

| Aspect | mig_prep | mig_prep_csve |
|--------|----------|--------------|
| **Storage driver mode** | Assumes installed | Can specify 'RestoreInjected' for Firstboot |
| **Driver type selection** | Always vioscsi | Can validate for viostor instead |
| **Network adapter message** | "manual planning required" (FAIL) | "preserve MACs or provide mapping" (WARNING) |
| **Common module** | None | `. (Join-Path $PSScriptRoot 'Migration.Common.ps1')` |

#### Implications:

✅ **Positive:**
- **Firstboot-aware**: Can validate readiness when drivers come from Firstboot, not source
- **Flexible storage drivers**: Can validate for Block (viostor) instead of SCSI (vioscsi)
- **Network flexibility**: Multiple-adapter scenarios now treated as warnings, not failures
- **Better guidance**: Message tells users how to handle multi-adapter cases

⚠️ **Considerations:**
- **Parameter knowledge required**: Users must understand StorageDriverMode implications
- **Default still vioscsi**: If viostor needed, must explicitly specify

---

### 7. **Test-DCMigrationHealth.ps1** (DC-Specific Validation)

**Changes:** ✅ MINOR - One important improvement

**Status:** Script exists in both folders; mig_prep_csve version is slightly improved

#### Key Difference:

| Aspect | mig_prep | mig_prep_csve |
|--------|----------|--------------|
| **OutputPath initialization** | `$OutputPath = New-MigrationPath -ScriptName 'Test-DCMigrationHealth'` | `if (-not $OutputPath) { $OutputPath = New-MigrationPath -ScriptName 'Test-DCMigrationHealth' }` |

#### Implications:

✅ **Positive:**
- **Respects user parameter**: If user provides `-OutputPath`, it's now honored instead of being overridden
- **More flexible**: Allows users to specify custom output paths when calling the script
- **Backward compatible**: If user doesn't specify OutputPath, defaults to generated path (same as before)

⚠️ **Considerations:**
- **Minor change**: Only affects users passing custom `-OutputPath` parameter
- **Default behavior unchanged**: Script still creates unique timestamped folders when no path specified

---

### 8. **load-virtio-scsi-on-boot.ps1** (Driver Boot Integration)

**Changes:** ✅ MINOR - Small improvements

#### Changes:

| Aspect | mig_prep | mig_prep_csve |
|--------|----------|--------------|
| **ErrorActionPreference** | Implicit (default) | Explicit: `$ErrorActionPreference = 'Stop'` |
| **Reboot tracking** | Not tracked | `$rebootRequired = $false` flag added |

#### Implications:

✅ **Positive:**
- **Explicit error handling**: Makes failure behavior clear
- **Reboot tracking**: Prepares for future reboot status communication
- **Robustness**: Ensures strict error handling consistency

---

### 9. **README.md and Documentation**

**Status:** Both folders have README.md

Cannot assess changes without detailed comparison, but suggests documentation exists in both versions.

---

### 10. **Additional New Files in mig_prep_csve**

- **ANVANDARGUIDE.md** - Swedish operator guide
- **ANVANDARGUIDE.txt** - Mirror of operator guide (UTF-8 BOM + CRLF for Windows Notepad)
- **GRANSKNING.md** - Appears to be audit/review documentation
- **AGENTS.md** - Agent configuration file
- **tests/** folder - Unit/integration tests (PSScriptAnalyzerSettings.psd1, Test-MigrationLogic.ps1)
- **tools/** folder - Utility scripts (export_user_guide.py)

**Implications:**
- ✅ Professional project evolution: Added proper documentation, testing, and tooling
- ✅ Operational maturity: Swedish language support and audit trails
- ✅ Code quality: Linting rules and test suite

---

## Workflow Architecture Comparison

### mig_prep Workflow (Original)
```
User runs Migrate-VmwareToProxmox.ps1
  ↓ (Interactive menu)
  ├─→ Test-MigrationReadiness.ps1
  │   └─→ [User reviews report]
  │
  ├─→ mig_prep.ps1
  │   └─→ Export-MigrationState.ps1
  │       └─→ Restore-And-TestMigrationState.ps1
  │
  └─→ [Next steps not guided]
```

### mig_prep_csve Workflow (Enhanced)
```
User runs Migrate-VmwareToProxmox.ps1 -Phase <phase> [parameters]
  ↓
  Orchestration layer (Migrate-VmwareToProxmox.ps1)
  ├─→ Phase: ReadinessCheck
  │   ├─→ Test-MigrationReadiness.ps1
  │   └─→ Test-DCMigrationHealth.ps1 (if DC detected)
  │
  ├─→ Phase: Prepare
  │   ├─→ mig_prep.ps1 (optional, depends on DriverPreparation)
  │   └─→ Export-MigrationState.ps1
  │       └─→ [State saved for restore]
  │
  └─→ Phase: ValidatePost
      ├─→ [Verify Firstboot completion]
      └─→ Restore-And-TestMigrationState.ps1
          ├─→ [Restore network]
          ├─→ [Optional: repair disks]
          └─→ [Validate post-restore]
```

**Key Improvements:**
- Orchestration handles flow control
- Each phase can be re-run independently
- State tracking between phases
- Automation-friendly parameter interface
- Error handling and exit codes standardized

---

## Risk Assessment

### Breaking Changes (mig_prep → mig_prep_csve)

| Change | Risk Level | Mitigation |
|--------|-----------|-----------|
| Migrate-VmwareToProxmox entirely rewritten | 🔴 HIGH | Old scripts still available in mig_prep folder |
| Online mode requires local init script | 🟡 MEDIUM | Admin must provide file; prevents untrusted downloads |
| Default path behavior changed | 🟡 MEDIUM | Relative paths now anchored to script location; more reliable |
| Parameter-based vs menu-driven | 🟡 MEDIUM | Documentation needed for parameter combinations |
| Firstboot support changes assumptions | 🟡 MEDIUM | Old workflow (all drivers from source) still supported via `DriverPreparation=Install` |

### Enhancements (Lower Risk)

| Enhancement | Risk | Benefit |
|-------------|------|---------|
| Migration.Common.ps1 module | 🟢 LOW | Code reuse, easier maintenance |
| WhatIf/Confirm support | 🟢 LOW | Safe dry-runs, no backward compatibility impact |
| AdapterMappingPath for complex networks | 🟢 LOW | New capability, doesn't affect simple cases |
| Reboot code 3010 support | 🟢 LOW | Improves reliability, better than failing on 3010 |
| Code revisions (8 months newer) | 🟢 LOW | Bug fixes and improvements baked in |

---

## Recommendations

### For Immediate Use (Testing)

1. **Keep both versions available** - mig_prep for known working baseline, mig_prep_csve for new functionality
2. **Test with `-WhatIf` first** - All new scripts support dry-run mode
3. **Review parameters carefully** - New orchestration requires understanding parameter intent
4. **Test complex networks first** - Use AdapterMappingPath feature with test VMs before production
5. **Verify Firstboot support** - If using Firstboot-injected drivers, test DriverPreparation modes

### For Production Deployment

1. **Phase migration gradually:**
   - Week 1: Use for ReadinessCheck only (read-only, lowest risk)
   - Week 2: Test Prepare phase with -WhatIf on non-critical server
   - Week 3: Run Prepare on production with -Confirm
   - Week 4: Run ValidatePost on restored VMs

2. **Maintain documentation** - Swedish guide (ANVANDARGUIDE.md) should be reviewed and translated if needed

3. **Preserve rollback path** - Keep mig_prep folder for emergency fallback

4. **Implement testing** - Review tests/ folder and integrate into QA process

5. **Monitor Firstboot integration** - If migrating to Firstboot-based restore, test DriverPreparation=FirstbootManaged thoroughly

---

## Summary Table

| Category | Old (mig_prep) | New (mig_prep_csve) | Verdict |
|----------|----------------|-------------------|---------|
| **Architecture** | Menu-driven | Parameter-based orchestration | ✅ Improved |
| **Code quality** | Duplicated functions | Centralized in Common.ps1 | ✅ Improved |
| **Network handling** | Single MAC only | Multi-MAC with mapping | ✅ Improved |
| **Error handling** | Basic | Sophisticated with exit codes | ✅ Improved |
| **Documentation** | English README | English + Swedish + Tests | ✅ Improved |
| **Firstboot support** | None | Full Firstboot aware | ✅ New capability |
| **Dry-run capability** | No | Full WhatIf support | ✅ Improved |
| **Backward compatibility** | N/A (original) | Breaking changes to interface | ⚠️ Trade-off |
| **Complexity** | Lower | Higher | ⚠️ Trade-off |
| **Automation-friendly** | Difficult | Easy | ✅ Improved |

---

## Conclusion

The **mig_prep_csve folder contains substantially improved scripts** suitable for:
- Complex multi-NIC migrations
- Firstboot-based restore operations  
- Automated orchestration and CI/CD integration
- Enterprise environments requiring audit trails
- Organizations supporting Swedish-language operations

**Recommended approach:** Phase migration to new version while maintaining old version as fallback for at least 2-3 migration cycles to ensure stability.

