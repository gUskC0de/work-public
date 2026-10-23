# VMware-to-Proxmox Migration Toolkit

For the Swedish operator walkthrough, start with [Användarguide](ANVANDARGUIDE.md).
For Windows Notepad, open [ANVANDARGUIDE.txt](ANVANDARGUIDE.txt) in the same folder.
The text version includes the complete guide, uses UTF-8 with BOM and Windows
line endings, and requires no Markdown viewer or PDF reader.
This README provides the technical reference and advanced options.

When editing the guide, update `ANVANDARGUIDE.md` and regenerate the text mirror
from the repository root with `python3 tools/export_user_guide.py`. Verify it with
`python3 tools/export_user_guide.py --check`. Python is needed only to regenerate
the guide during development, not to read it on the Windows server.

PowerShell scripts for capturing Windows Server state before a Veeam restore,
restoring IPv4 settings after conversion, and validating the migrated server.
Code and user-facing script messages are in English. The Swedish review and
implementation notes are in `GRANSKNING.md`.

Target environment: elevated Windows PowerShell 5.1 on Windows Server
2016, 2019, 2022 or 2025. Platform operations still require validation on the
actual Windows/Veeam/Proxmox combination; the portable test suite uses mocks.
Copy all files from the repository root, including `Migration.Common.ps1`
and `virtio-win-guest-tools.exe`. The migration scripts and installer must remain
in the same folder. The `tests` and `tools` directories are for development only.

## Workflow and ownership

1. **ReadinessCheck on VMware:** read-only health checks and local reports.
2. **Prepare on VMware:** source driver preparation (default) and state capture.
   Original VMware Tools service state is saved, then the source services are
   stopped/disabled (the original workflow). No source Tools uninstall is performed.
3. **Final backup and Veeam restore:** use the restore method verified for your
   environment, with boot-critical storage drivers available at first boot.
4. **Wait for Guestfs/Firstboot to finish on Proxmox.** It may install drivers,
   install QEMU Guest Agent/Balloon, uninstall VMware Tools, online disks and restart
   Windows several times. Reaching the login screen does not mean it has finished.
5. **ValidatePost on Proxmox:** verify Firstboot completion, restore captured IPv4
   configurations to their mapped adapters, and run post-migration checks. It does not
   install agents or uninstall Tools. It does not restart Windows.

The observed Firstboot sequence runs six scripts with six restart requests. This
is consistent with documented conversion behavior, not evidence of a crash loop.
See [virt-v2v release notes](https://libguestfs.org/virt-v2v-release-notes-2.6.1.html)
and [Firstboot behavior](https://www.libguestfs.org/virt-customize.1.html#firstboot).
These scripts do not modify Firstboot's injected scripts or reboot policy.

## Quick start

Run from an elevated Windows PowerShell session. Absolute script paths work;
offline files are resolved relative to the script directory by default.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Migrate-VmwareToProxmox.ps1 -Phase ReadinessCheck
.\Migrate-VmwareToProxmox.ps1 -Phase Prepare
```

Without `-Phase`, the main script displays a phase menu. Server role is detected
from Windows; DC checks cannot accidentally be skipped by choosing Normal.
`-ServerType DomainController` or `Normal` may be supplied as an assertion and
must agree with the detected role. Administrator membership is checked; it does
not prove that an account is local or that domain login will work without a network.
Plan console access and appropriate recovery credentials before migration.

### Automatic server-role detection and DC checks

The former Normal/DC prompt is replaced by automatic detection on each run.
The main script reads `Win32_ComputerSystem.DomainRole`: values 4 or 5 identify
a `DomainController`; other values identify `Normal`. A domain-joined member
server is therefore `Normal`. The detected role is printed beside the phase.
An explicit `-ServerType` asserts the expected role; a mismatch stops execution
and cannot be used to bypass DC checks.

| Menu phase | Normal server | Domain controller |
|---|---|---|
| **1) ReadinessCheck** | General readiness checks | General checks, then DC health in `PreMigration` mode |
| **2) Prepare** | Driver preparation and state capture, then Tools service handling | Same preparation flow |
| **3) ValidatePost** | Network restoration and post-migration checks | Same flow, then DC health in `PostMigration` mode |

A blocking failure stops the phase before subsequent checks. DC health requires
the ActiveDirectory module and appropriate permissions. By default, it checks
all writable DCs in the current domain, so findings can concern other DCs too;
RODCs are excluded from that default discovery. It checks services, replication,
DNS, SYSVOL/NETLOGON, time and relevant events without repairing AD or changing
DC roles. The phase modes label the reports; the main script does not automatically
compare pre/post DC reports. Use the standalone `-CompareWith` option below for
that comparison, or `-ComputerName` to select specific DCs.

The workflow remains three phases: **1) ReadinessCheck**, **2) Prepare** and
**3) ValidatePost**, followed by **4) Exit**. Prepare already calls the exporter;
there is no separate export menu step. It captures every active NIC and its routes.
Multiple NICs produce a preparation warning (main exit code 1) rather than a failed
capture. ValidatePost resolves every source-to-target NIC mapping before making
changes. Preserve source MACs in Proxmox, or provide an explicit mapping as below.

Prepare prints the capture's `StateDirectory`. Record this path for the restore.
It is preferable to supply it explicitly:

```powershell
# On the restored Proxmox VM, after Firstboot has finished:
.\Migrate-VmwareToProxmox.ps1 -Phase ValidatePost `
    -StateDirectory 'C:\Rutin_migration_2026-10-22\Export-MigrationState\State'
```

If omitted, the latest matching capture is selected by its captured UTC timestamp
across all `C:\Rutin_migration_*` dates and export suffixes. Missing files,
ambiguous timestamps or unreadable captures require an explicit selection rather
than silently falling back to an older baseline. Computer identity and schema are
checked before restoration. Logs/reports use a new directory for each run.

## Source driver preparation

`-DriverPreparation Install` is the default and preserves source-side VirtIO SCSI
preparation. The offline EXE and reviewed initialization script must be present.
Readiness checks require vioscsi by default; standalone readiness supports
`-RequiredStorageDriver viostor` for a verified VirtIO Block target.
A driver installation or binding failure stops Prepare. Reboot-required status
3010 is reported as a warning; review readiness and complete a planned reboot if
required before taking the final migration backup. If settings change afterward,
run capture again and use the new directory. Main-script Prepare stops/disables
VMware Tools services after capture by default. The standalone exporter remains
read-only unless its service-disable option is supplied.

When a tested restore method provides boot-critical drivers, preparation can be
explicitly delegated to it:

```powershell
.\Migrate-VmwareToProxmox.ps1 -Phase ReadinessCheck -DriverPreparation FirstbootManaged
.\Migrate-VmwareToProxmox.ps1 -Phase Prepare -DriverPreparation FirstbootManaged
```

This records a warning, skips source driver installation and still captures state.
It does not verify Veeam's driver injection or guarantee first boot. Check the exact
Veeam/plugin version, restore type and target controller before choosing it.

Manual driver setup:

```powershell
.\mig_prep.ps1
.\mig_prep.ps1 -Mode offline -InstallerSourcePath 'D:\virtio-win-guest-tools.exe' `
    -InitScriptSourcePath 'D:\load-virtio-scsi-on-boot.ps1' -KeepArtifacts
.\mig_prep.ps1 -Mode online
```

Online mode downloads only the installer and uses the reviewed local initialization
script. `WorkingDirectory`, `StatusPath` and `LogPath` overrides are honored.
Staging over the original source files is rejected, so cleanup cannot delete them.
The installer must have either a valid Authenticode signature or the exact
SHA-256 of the reviewed bundled artifact described below. Other unsigned files
require **both** `-AllowUnsignedInstaller` and an independently trusted
`-ExpectedInstallerSha256`. Explicit expected-hash mismatches and invalid signatures
remain blocked, including for the bundled artifact.

The bundled `virtio-win-guest-tools.exe` version 0.1.271.0 has no embedded
Authenticode signature. On 2026-10-22, it was compared byte-for-byte with a fresh
download from the
[VirtIO project's archive for 0.1.271-1](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.271-1/virtio-win-guest-tools.exe).
Both files had SHA-256
`21a2c7d7607ca52de3d7f57b57c8ba8752b9ba68ca89b54de48ff266091b14e4`.
This exact hash is allowed in `Migration.Common.ps1`, so running the main script
normally and selecting **2) Prepare** needs no extra installer authorization flags.
Renaming another file to the same name does not authorize it. A future replacement
must be reviewed before updating this pinned hash. The comparison establishes
equality with the published artifact, not the installer's behavior.

The boot initialization helper verifies native driver-binding exit codes and
boot-start settings before reporting success.
[PnPUtil exit code 259](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-return-values)
means no device matched or a better/newer driver is already installed; it is not
unconditionally treated as a binding failure. For 259, the helper verifies the
published OEM package and original INF name through `Get-WindowsDriver -Online`,
the driver binary, boot-start service configuration and StartOverride before
continuing with a warning. A missing package/binary, failed query, unsafe boot
settings or any other unsupported exit code still blocks preparation. This checks
source preparation; actual VirtIO hardware binding must be checked after restore. It preserves the existing phantom
device technique. Its Windows SetupAPI/registry behavior must be tested on each
supported Windows release. The bundle does not provide automatic source rollback.

## Firstboot gate

Both the main script and standalone restore script check Firstboot before network
or disk changes, validation, or explicit Tools repair. They inspect the Firstboot
service, pending scripts and a completion marker or the final successful service
uninstall entry in `C:\Program Files\Guestfs\Firstboot\log.txt`.

An existing Firstboot runner service or pending script blocks the run even if a stale completion
marker exists. Installer `.log` files such as `scripts\balloon.log` are excluded
from pending work and reported as `ignoredLogFiles` in the shared status helper.
Other unrecognized non-log files remain blocking. Known installed Balloon/QEMU
Agent executables (`blnsvr.exe`, `qemu-ga.exe`) under this directory are reported
as `installedPayloadServices` and do not count as the conversion runner. A
Firstboot-named service or unrecognized service executable remains blocking,
including a stopped runner. Matching only a payload filename in another program's
arguments cannot authorize continuation. Blocked runs display service identity,
state/start mode/path, pending scripts, marker status and the last Firstboot log
line directly in the normal menu output; no separate diagnostic command is needed. Ignoring a log does not itself
establish completion; the service must be absent and completion evidence present. An existing directory without verifiable completion also blocks.
Investigate pending/failing conversion rather than running a competing repair.
Completion only establishes that conversion finished; the normal health checks
still need to pass.

For a restore method that does **not** use Guestfs/Firstboot:

```powershell
.\Migrate-VmwareToProxmox.ps1 -Phase ValidatePost -FirstbootNotUsed `
    -StateDirectory 'C:\Rutin_migration_2026-10-22\Export-MigrationState\State'
```

This explicit declaration only allows the absence of Firstboot evidence. It cannot
bypass a detected pending or unknown Firstboot conversion.

## Network restoration and rollback

Every captured source NIC must map to a unique target NIC before any network
settings change. With preserved MAC addresses, mapping is automatic, including
multiple adapters and a secondary adapter without a default gateway. Adapter
names, interface indexes and enumeration order may change; they are not evidence
of correspondence. A uniquely identified disabled target can be enabled. The
existing one-source/one-target VirtIO fallback remains available when its MAC changed.
Additional unmapped target adapters are left unchanged.

If target MACs differ, create `AdapterMapping.json` with **one entry for every
captured source NIC**. Replace the example MACs and computer name with the actual
values. Source MACs come from `NetworkConfiguration.json`; target MACs come from
`Get-NetAdapter | Format-Table Name, InterfaceIndex, MacAddress, Status` on Proxmox.
The optional `computerName` must match the captured computer when specified.

```json
{
  "schemaVersion": "1.0",
  "computerName": "REPLACE_WITH_CAPTURED_COMPUTER_NAME",
  "mappings": [
    { "sourceMacAddress": "00-50-56-00-00-01", "targetMacAddress": "02-00-00-00-00-01" },
    { "sourceMacAddress": "00-50-56-00-00-02", "targetMacAddress": "02-00-00-00-00-02" }
  ]
}
```

Pass this file to the main script and choose **3) ValidatePost** in the same menu:

```powershell
.\Migrate-VmwareToProxmox.ps1 -AdapterMappingPath '.\AdapterMapping.json'
```

It also works with `-Phase ValidatePost`, or directly with the restore script.
To inspect the mapping without changing settings, after Firstboot has finished:

```powershell
.\Restore-And-TestMigrationState.ps1 -Mode ApplyNetwork -WhatIf `
    -StateDirectory '<captured State directory>' -AdapterMappingPath '.\AdapterMapping.json'
```

Missing, duplicate or incomplete mappings block restoration of **all** NICs;
there is no partial approval. MAC addresses accept hyphens, colons or no separators.
The script verifies target identity again before changes and rollback. Verify that
each target NIC is connected to the intended Proxmox bridge/VLAN; a Windows MAC
mapping cannot identify the external network wiring.

For every mapped adapter, restoration covers DHCP/static IPv4 mode, addresses and
prefix lengths, DNS assignment/servers/suffix/registration, interface metric,
default gateways and static routes. A route follows its captured **source interface**
to that interface's mapped target; a static route over the second NIC does not
require that NIC to have a default gateway. On-link routes and other next hops are
supported. Active-only routes remain active-only; persistent routes survive restart.
Windows Server 2019 may return null/65535 Protocol for PersistentStore records.
When persistence is established by that explicit store query, these saved routes
are classified as static even without an active counterpart. `protocolSource`
records whether classification came from Protocol or PersistentStore; unknown
active-only routes remain blocking. The same rule applies to target snapshots.
Static routes outside the captured active source interfaces are retained for
reference and produce a warning; they are never assigned to a different NIC.
Existing IP addresses with incorrect prefixes are corrected. Link/address readiness
has a bounded wait, and duplicate addresses cause failure.

Before the first write, **all** mapped targets' network settings and routes are saved
to `Restore-And-TestMigrationState*/PreNetworkChangeRollback.json` (rollback schema
1.1, `adapters` array). If any NIC or route restoration throws, every attempted target
is rolled back in reverse order, including the partially configured failing NIC.
Rollback of the remaining NICs is attempted even if one rollback fails. Failures
are reported distinctly. The previous single-adapter rollback format remains readable.
This snapshot restores the pre-change **target** configuration, not the VMware VM.
DHCP leases remain server-controlled. Keep console access during network changes.

Old exports with `protocol: Unknown` or missing static-route persistence are blocked
for automatic restoration. Recapture with the fixed exporter, or configure the
network manually and use ValidateOnly/CompareOnly to review the legacy baseline.

ValidateOnly/CompareOnly can also check a manually configured migration. Explicit
mapping is used for comparisons when supplied; otherwise validation attempts a
unique MAC/IP match. Ambiguous matches require review. IPv6, VLAN configuration,
NIC teaming, network profiles and firewall policy are not automatically restored.
Exported data is for reference; validate these separately when used by the source VM.

There is no hard-coded two-NIC or route-count limit. A portable regression covers
eight NICs and 800 static IPv4 routes, including repeated destination prefixes on
different interfaces, multiple next hops, on-link routes, metrics, persistence and
changed MACs. Windows calls are mocked in this test; it does not measure real
Windows execution time or certify a large migration. Route operations can take
longer with larger tables.

The source capture includes active NICs. Disabled/disconnected source NICs and
routes belonging to uncaptured interfaces require separate review. Static IPv4
route restoration does not migrate dynamic-routing software/configuration or IPv6.

## Restore modes and optional repairs

| Mode | Behavior |
|---|---|
| `ValidateOnly` (standalone default) | Read-only guest checks and local reports |
| `CompareOnly` | Read-only comparisons/checks and local reports |
| `ApplyNetwork` | Restore the mapped IPv4 configuration and validate |
| `Full` (main ValidatePost) | Restore the mapped IPv4 configuration and run all checks; no Tools uninstall |
| `VmwareUninstall` | Explicit MSI-only Tools repair after the Firstboot gate; no automatic network restore |

Validation includes identity, IP/prefix/DNS/routes, disk inventory/health and drive
letters, previously running automatic services, roles, shares, tasks, listening
ports, filesystem dirty bits, relevant events, DNS/DC discovery, optional TCP
application ports, QEMU Guest Agent and VSS writers. Unavailable or unrecognized
checks produce warnings/NOT_CHECKED, not a successful check. English-dependent
native output parsing may require manual review on localized Windows installs.
Gateway ICMP failure is a warning, as ICMP may be filtered. Member-server DC
discovery does not require the ActiveDirectory PowerShell module.

Optional switches, also accepted by the main ValidatePost phase:

- `-RepairOfflineDisks`: explicitly allow offline-disk repair; default is inspect
  and report. Review all attached disks first. Repair may clear read-only state.
- `-RemoveHiddenVMwareAdapters`: explicitly request removal of confidently
  identified non-present VMware NICs; otherwise leave them alone. If the removal
  cmdlet is unavailable, instructions are reported for manual handling.
- `-DeepScan`: enable online `chkdsk /scan` in Full/ApplyNetwork. It can perform
  online repairs, so it is protected by ShouldProcess and is skipped in read-only
  modes and WhatIf.
- `-DnsTestHost 'dc01.example.test'`: DNS/connectivity target; recommended for a
  workgroup server. No public DNS target is assumed.
- `-ApplicationConfigPath '<file.json>'`: optional `{ "tcpPorts": [443, 8443] }`
  tested against DnsTestHost, or the joined domain if DnsTestHost is omitted.
- `-MigrationTimestamp '2026-10-22T10:00:00'`: event-log starting point. Default is
  the last Windows boot; supply the conversion start to include earlier boots.

All guest changes in the restore script support `-WhatIf`/`-Confirm`. WhatIf writes
no restore logs, reports or rollback files, and starts no modifying native commands.
Checks still read the current configuration and may report differences because
previewed changes have not been applied.

```powershell
.\Migrate-VmwareToProxmox.ps1 -Phase ValidatePost -StateDirectory '<State directory>' -WhatIf
.\Restore-And-TestMigrationState.ps1 -Mode Full -StateDirectory '<State directory>' -WhatIf
```

If VMware Tools remains after conversion, investigate Firstboot first. Separate
repair is available when appropriate:

```powershell
.\Restore-And-TestMigrationState.ps1 -Mode VmwareUninstall -WhatIf
.\Restore-And-TestMigrationState.ps1 -Mode VmwareUninstall -Confirm
```

This uses MSI with `/norestart`, never Win32_Product inventory, forced service
removal, or deletion of product-registration keys. MSI failure preserves the
installation for repair. Reboot-required status is a warning and needs a planned
restart followed by verification. This mode is an explicit repair, not a full
migration health approval.

Storage health reports include controller instance IDs, status, problem codes and
hardware IDs. Known preparation devices must match the exact `ROOT\VIOSCSI` or
`ROOT\VIOSTOR` family, a VirtIO name and the corresponding hardware ID created by
the helper. They produce a separate warning. PCI controllers, unknown ROOT devices
and unverifiable identities remain subject to the normal health checks. No device
or driver is automatically deleted. If only helper devices are found, hardware
health is NOT_CHECKED; their presence does not establish a working storage bus.

After a successful network apply, a later health-check failure leaves that network
configuration in place. To repeat checks without applying it again, run
`Restore-And-TestMigrationState.ps1` without parameters (ValidateOnly by default).
The existing capture is discovered as usual, and new reports are produced.

## State capture, reports and rollback to VMware

Export is read-only by default and preserves software/services. It records network,
disk/volume, service, role, share, task, listening-port and event baselines plus raw
`ipconfig /all`, `route print -4` and `arp -a` outputs. Protect access to capture
files because they contain internal infrastructure information.

The main script's **2) Prepare** preserves the original behavior: it captures and
writes the original service baseline first, then stops/disables `VMTools`,
`VGAuthService`, `VMVss` and `VM3DService` when present. Source Tools are not
uninstalled. A missing original service baseline prevents the service changes;
stop/disable failures are recorded and return a blocking code. The confirmation
prompt describes these changes, and WhatIf launches no modifying child script.
Advanced callers can opt out with `-DisableVMwareTools:$false`. The standalone
exporter remains read-only by default and changes services only with its own
`-DisableVMwareTools` option.

For rollback, start the preserved original VMware VM and restore startup/running
states from its captured `services.all` baseline. Re-enabling only VMTools does
not restore the other services. This source rollback is separate from network
rollback on the Proxmox VM. Preserve the original VMware VM and backup until the
migration is approved; Firstboot may already have removed Tools from the restored
copy.

Tools uninstall on the restored copy belongs to Firstboot. If it fails, review the
log and use the explicit MSI repair mode as needed. No automatic `sc.exe delete`
fallback is applied: [Microsoft documents that this deletes the service registry
subkey](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/sc-delete).
Deleting service registrations does not establish that the product, drivers and
installer registration have been fully removed.

Reports are created in unique `C:\Rutin_migration_yyyy-MM-dd\<script>*` directories.
Post reports are `Reports\PostMigrationReport.json`, `.html` and `.txt`.
The post snapshot and rollback JSON are stored in the restore run directory.
Source exports are never overwritten by post-migration output. If route capture
fails, adapter data is retained with `routeCaptureComplete: false`; that partial
export is diagnostic data and cannot be used for automatic restoration. Prepare
stops before source service changes and reports the capture failure explicitly.
Post-restore checks distinguish capture failures by their originating check-name
prefix. Multi-NIC planning, uncaptured-interface routes and unavailable BitLocker
inventory remain visible warnings; mentioning network configuration in a planning
message does not itself block restoration. Actual network/raw-output capture
failures still block automatic changes.

DC health can also be run separately:

```powershell
.\Test-DCMigrationHealth.ps1 -Mode PreMigration
.\Test-DCMigrationHealth.ps1 -Mode PostMigration -CompareWith '<previous Results.json>'
```

These checks require the ActiveDirectory module and appropriate permissions.
The main script automatically runs them for a detected DC and propagates failures.

## Exit codes

Step 3 includes stable diagnostic identifiers in console messages and, for adapter
mapping, the report. These do not change the numeric exit-code contract:

- `MIG-NET-001`: adapter mapping failed before network restoration. Source and
  target NIC names/MACs are listed. A missing source MAC prompts the operator to
  check whether VMware MACs were copied to Proxmox, whether NICs/drivers are
  present, or whether an explicit mapping is required. Mutating restore modes
  still exit with 20; read-only modes retain a warning.
- `MIG-FIRSTBOOT-001`: Firstboot remains pending/unknown; inspect the evidence.
- `MIG-FIRSTBOOT-002`: no pending scripts, all blocking services are Firstboot-named,
  Running and Disabled, and the last log entry is `Service uninstalled successfully`.
  The gate remains closed but suggests restarting Windows once from the Start menu
  in the Proxmox console and retrying ValidatePost. This is a cleanup hint, not proof
  that Windows marked the service for deletion. No automatic restart/deletion occurs.
  Other pending/unknown conditions do not receive this restart hint. The main
  Firstboot gate still exits with 2 (standalone restore execution failure: 99).

- Main: `0` success, `1` accepted warnings, `2` orchestration/prerequisite failure,
  or a blocking child exit code. Failed phases never print overall success.
- Readiness: `0` success, `1` warnings, `2` failed checks, `3` execution failure.
- Export: `0` complete, `50` capture warnings, `52` incomplete network capture
  (blocks preparation before source service changes), `51` explicit service shutdown
  failure; other nonzero codes indicate blocked/failed capture.
- Driver preparation: `0` success, `3010` reboot required, `1` failure.
- Restore: `0` success, `1` warnings, `2` failed checks, `10` elevation failure,
  `20` invalid input/identity/mapping, `40` network failure with successful rollback,
  `41` rollback failure, `99` execution/Firstboot-gate failure.
- DC health: `0` healthy, `1` warnings, `2` unhealthy, `3` execution failure.

## Validation before production use

From the repository root, run the portable regression tests:

```powershell
.\tests\Test-MigrationLogic.ps1
```

The suite parses every migration script and tests safety/decision logic with
mocked Windows commands. It never runs the real migration scripts or modifies
real adapters, disks, services, drivers or registry keys.

With PSScriptAnalyzer installed:

```powershell
Get-ChildItem -Path . -Filter *.ps1 |
    Invoke-ScriptAnalyzer -Settings .\tests\PSScriptAnalyzerSettings.psd1
```

The settings check PowerShell 5.1 syntax and selected safety rules. They do not
prove Windows API compatibility. Perform an isolated restore rehearsal on the
actual supported Windows releases, including Firstboot, driver bootability,
static/DHCP networking, extra routes, error/rollback paths, applications and DC
health where applicable. Firstboot service/file layouts may differ by restore
version; an unknown layout stops rather than bypasses the gate.
