# VirtIO SCSI driver setup

`mig_prep.ps1` downloads and installs the pinned VirtIO guest tools release, downloads the pinned `load-virtio-scsi-on-boot.ps1` commit, initializes the VirtIO SCSI driver, and independently verifies the result.

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

## Verification

The runner verifies all of the following independently of the initialization script's console output:

- the `vioscsi` Windows driver service exists
- Windows reports a signed PnP driver for `vioscsi`
- both VirtIO SCSI `CriticalDeviceDatabase` entries exist and point to `vioscsi`

The GitHub initialization script is pinned to commit `d6f5467`. Review and update that pin deliberately when upgrading it. The VirtIO installer URL is pinned to version `0.1.271-1`.

This script modifies boot-critical driver configuration. Test it on the target Windows version in a recoverable VM first and maintain a backup or recovery path.
