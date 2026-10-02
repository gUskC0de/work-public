# VirtIO SCSI driver setup

`mig_prep.ps1` downloads and installs the pinned VirtIO guest tools release, downloads the pinned `load-virtio-scsi-on-boot.ps1` commit, initializes the VirtIO SCSI driver, independently verifies the result, and detects whether VMware Tools is installed (but does not remove it).

## Run

Open **Windows PowerShell as Administrator** and run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\mig_prep.ps1
```

The command returns exit code `0` only when installation, initialization, and verification succeed. A nonzero exit code indicates failure.

The default outputs are:

- `driver-install.log`: human-readable execution log
- `driver-status.json`: structured status report for later collection by monitoring, automation, or an API
- `driver-work`: temporary downloaded files, removed at the end unless `-KeepArtifacts` is supplied

To enforce a known installer hash, obtain the expected SHA-256 from a trusted release source and run:

```powershell
.\mig_prep.ps1 -ExpectedInstallerSha256 '<64-character SHA-256>'
```

If the downloaded installer is reported as `NotSigned`, do not bypass that check unless the file was obtained from a trusted source. After verifying its SHA-256, run with both options:

```powershell
.\mig_prep.ps1 -ExpectedInstallerSha256 '<64-character SHA-256>' -AllowUnsignedInstaller
```

An invalid Authenticode signature is always rejected.

To retain downloaded files for troubleshooting:

```powershell
.\mig_prep.ps1 -KeepArtifacts
```

To place the status and log files elsewhere:

```powershell
.\mig_prep.ps1 -StatusPath 'C:\ProgramData\VirtIO\driver-status.json' -LogPath 'C:\ProgramData\VirtIO\driver-install.log'
```

## VMware Tools handling

If VMware Tools is detected during the driver setup, it will be reported in `driver-status.json` as `vmwareToolsDetected`. The script does **not** remove VMware Tools automatically, since doing so would disconnect the network before the migration is complete.

VMware Tools should be removed by `Export-MigrationState.ps1` as the final step of the migration workflow, after the system is ready to migrate to the KVM/Proxmox hypervisor.

## Offline use

Download `virtio-win-guest-tools.exe` and `load-virtio-scsi-on-boot.ps1` on a machine with internet access, and copy them along with `mig_prep.ps1` onto the target VM (e.g. via a self-made ISO, USB drive, or shared folder). Then run as Administrator with `-Mode offline`, no internet access required:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\mig_prep.ps1 -Mode offline -InstallerSourcePath 'D:\virtio-win-guest-tools.exe' -InitScriptSourcePath 'D:\load-virtio-scsi-on-boot.ps1'
```

`-Mode` defaults to `online`, which downloads both files as before. `-Mode offline` requires both `-InstallerSourcePath` and `-InitScriptSourcePath`.

## Verification

The runner verifies all of the following independently of the initialization script's console output:

- the `vioscsi` Windows driver service exists
- Windows reports a signed PnP driver for `vioscsi`
- both VirtIO SCSI `CriticalDeviceDatabase` entries exist and point to `vioscsi`

The GitHub initialization script is pinned to commit `d6f5467`. Review and update that pin deliberately when upgrading it. The VirtIO installer URL is pinned to version `0.1.271-1`.

This script modifies boot-critical driver configuration. Test it on the target Windows version in a recoverable VM first and maintain a backup or recovery path.
