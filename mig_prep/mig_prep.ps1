[CmdletBinding()]
param(
    [ValidateSet('online', 'offline')]
    [string]$Mode = 'offline',
    [string]$WorkingDirectory = (Join-Path $PSScriptRoot 'driver-work'),
    [string]$StatusPath = (Join-Path $PSScriptRoot 'driver-status.json'),
    [string]$LogPath = (Join-Path $PSScriptRoot 'driver-install.log'),
    [string]$ExpectedInstallerSha256 = '',
    [switch]$AllowUnsignedInstaller,
    [switch]$KeepArtifacts,
    [string]$InstallerSourcePath = '.\virtio-win-guest-tools.exe',
    [string]$InitScriptSourcePath = '.\load-virtio-scsi-on-boot.ps1',
    [switch]$SkipVMwareToolsRemoval
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installerUrl = 'https://fedora-virt.repo.nfrance.com/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.271-1/virtio-win-guest-tools.exe'
$initScriptUrl = 'https://raw.githubusercontent.com/croit/load-virtio-scsi-on-boot/d6f54673916e0d9a51bb47e61a67cb803df2585e/load-virtio-scsi-on-boot.ps1'
$installerPath = Join-Path $WorkingDirectory 'virtio-win-guest-tools.exe'
$initScriptPath = Join-Path $WorkingDirectory 'load-virtio-scsi-on-boot.ps1'
$startedAt = [DateTime]::UtcNow
$stages = [ordered]@{}
$verificationDetails = @{}

function Write-Log {
    param([string]$Message)
    $Message | Tee-Object -FilePath $LogPath -Append
}

function Set-Stage {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Message = ''
    )
    $stages[$Name] = [ordered]@{
        status = $Status
        message = $Message
    }
    Write-Log ("[{0}] {1}: {2}" -f $Name, $Status, $Message)
}

function Write-Status {
    param(
        [string]$OverallStatus,
        [string]$Message,
        [hashtable]$Details = @{}
    )
    $report = [ordered]@{
        driver = 'VirtIO SCSI (vioscsi)'
        driverPackageVersion = 'virtio-win-0.1.271-1'
        status = $OverallStatus
        message = $Message
        startedAtUtc = $startedAt.ToString('o')
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        stages = $stages
        details = $Details
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $StatusPath -Encoding UTF8
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run as Administrator.'
    }
}

function Get-VMwareToolsUninstallInfo {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'VMware Tools' } | Select-Object -First 1
}

function Remove-VMwareTools {
    if ($SkipVMwareToolsRemoval) {
        Set-Stage 'vmwareToolsRemoval' 'Skipped' '-SkipVMwareToolsRemoval was supplied.'
        return
    }
    $service = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
    $uninstallInfo = Get-VMwareToolsUninstallInfo
    if (-not $service -and -not $uninstallInfo) {
        Set-Stage 'vmwareToolsRemoval' 'Succeeded' 'VMware Tools is not installed.'
        return
    }
    # PSChildName on the Uninstall registry key is the MSI product code, required for a silent msiexec /x removal.
    if (-not $uninstallInfo -or -not $uninstallInfo.PSChildName) {
        throw 'VMware Tools appears installed, but its MSI product code could not be determined for silent removal. Remove it manually via Programs and Features.'
    }
    $productCode = $uninstallInfo.PSChildName
    $uninstallLog = Join-Path $WorkingDirectory 'vmware-tools-uninstall.log'
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $productCode, '/qn', '/norestart', '/l*v', "`"$uninstallLog`"") -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) {
        throw "VMware Tools uninstall failed with exit code $($process.ExitCode). See $uninstallLog."
    }
    $remainingService = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
    $remainingUninstallInfo = Get-VMwareToolsUninstallInfo
    if ($remainingService -or $remainingUninstallInfo) {
        throw 'VMware Tools uninstall reported success, but the service or registry entry is still present.'
    }
    $message = "VMware Tools removed (product code $productCode)."
    if ($process.ExitCode -eq 3010) { $message += ' A reboot is pending to complete the removal.' }
    Set-Stage 'vmwareToolsRemoval' 'Succeeded' $message
}

try {
    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    $logParent = Split-Path -Parent $LogPath
    $statusParent = Split-Path -Parent $StatusPath
    if ($logParent) { New-Item -ItemType Directory -Path $logParent -Force | Out-Null }
    if ($statusParent) { New-Item -ItemType Directory -Path $statusParent -Force | Out-Null }
    Write-Log "Starting VirtIO SCSI driver setup."

    Assert-Administrator
    Set-Stage 'prerequisites' 'Succeeded' 'Running with administrator privileges.'

    if ($Mode -eq 'offline') {
        if (-not $InstallerSourcePath -or -not $InitScriptSourcePath) {
            throw '-Mode offline requires -InstallerSourcePath and -InitScriptSourcePath.'
        }
        if (-not (Test-Path $InstallerSourcePath -PathType Leaf)) {
            throw "InstallerSourcePath must point to virtio-win-guest-tools.exe, not a directory: $InstallerSourcePath"
        }
        if (-not (Test-Path $InitScriptSourcePath -PathType Leaf)) {
            throw "InitScriptSourcePath must point to load-virtio-scsi-on-boot.ps1, not a directory: $InitScriptSourcePath"
        }
        Copy-Item -Path $InstallerSourcePath -Destination $installerPath -Force
        Copy-Item -Path $InitScriptSourcePath -Destination $initScriptPath -Force
        $stageMessage = 'Used local offline installer and init script.'
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
            Invoke-WebRequest -Uri $initScriptUrl -OutFile $initScriptPath -UseBasicParsing
        } catch {
            throw "Online download failed. For a machine without internet access, copy virtio-win-guest-tools.exe and load-virtio-scsi-on-boot.ps1 locally and rerun with -Mode offline -InstallerSourcePath '<path to installer>' -InitScriptSourcePath '<path to init script>'. Original error: $($_.Exception.Message)"
        }
        $stageMessage = 'Downloaded installer and init script.'
    }
    $installerHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash
    if ($ExpectedInstallerSha256 -and $installerHash -ne $ExpectedInstallerSha256.ToUpperInvariant()) {
        throw "Installer SHA-256 mismatch. Expected $ExpectedInstallerSha256, got $installerHash."
    }
    $signature = Get-AuthenticodeSignature -FilePath $installerPath
    if ($signature.Status -eq 'NotSigned' -and $AllowUnsignedInstaller) {
        Write-Log 'WARNING: Installer is not Authenticode-signed; continuing because -AllowUnsignedInstaller was supplied.'
    } elseif ($signature.Status -ne 'Valid') {
        throw "Installer Authenticode signature is not valid: $($signature.Status)."
    }
    Set-Stage 'download' 'Succeeded' "$stageMessage SHA-256: $installerHash"

    $installProcess = Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait -PassThru
    if ($installProcess.ExitCode -ne 0) {
        throw "Guest tools installer failed with exit code $($installProcess.ExitCode)."
    }
    Set-Stage 'installation' 'Succeeded' 'virtio-win-guest-tools.exe completed successfully.'

    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $initScriptPath -Driver scsi
    if ($LASTEXITCODE -ne 0) {
        throw "VirtIO SCSI initialization script failed with exit code $LASTEXITCODE."
    }
    Set-Stage 'initialization' 'Succeeded' 'load-virtio-scsi-on-boot.ps1 completed successfully.'

    $service = Get-CimInstance Win32_SystemDriver -Filter "Name='vioscsi'" -ErrorAction SilentlyContinue
    $criticalPaths = @(
        'HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\PCI#VEN_1AF4&DEV_1004',
        'HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\PCI#VEN_1AF4&DEV_1004&SUBSYS_00081AF4&REV_00'
    )
    $criticalEntries = foreach ($path in $criticalPaths) {
        if (Test-Path $path) {
            $entry = Get-ItemProperty -Path $path
            [pscustomobject]@{ path = $path; service = $entry.Service }
        }
    }
    $verificationDetails = @{
        servicePresent = [bool]$service
        serviceState = if ($service) { $service.State } else { $null }
        criticalDeviceEntries = @($criticalEntries)
    }
    $failedChecks = @()
    if (-not $service) { $failedChecks += 'vioscsi service' }
    if (@($criticalEntries).Count -lt 2) { $failedChecks += 'critical-device entry count' }
    if (@($criticalEntries) | Where-Object service -ne 'vioscsi') { $failedChecks += 'critical-device service mapping' }
    $verificationDetails.failedChecks = $failedChecks
    if ($failedChecks.Count -gt 0) {
        throw "Independent verification failed: $($failedChecks -join ', ')."
    }
    Set-Stage 'verification' 'Succeeded' 'vioscsi service and critical-device entries are present.'

    try {
        Remove-VMwareTools
    } catch {
        # VMware Tools removal is best-effort; a failure here must not mask a successful VirtIO driver install.
        Set-Stage 'vmwareToolsRemoval' 'Failed' $_.Exception.Message
        Write-Log "WARNING: VMware Tools removal failed: $($_.Exception.Message)"
    }

    Write-Status 'Succeeded' 'VirtIO SCSI driver installed, initialized, and verified.' $verificationDetails
    Write-Log "Completed successfully. Status written to $StatusPath"
    exit 0
}
catch {
    $failedStage = ($stages.Keys | Where-Object { $stages[$_].status -eq 'Running' } | Select-Object -Last 1)
    if ($failedStage) { Set-Stage $failedStage 'Failed' $_.Exception.Message }
    else { Set-Stage 'execution' 'Failed' $_.Exception.Message }
    Write-Status 'Failed' $_.Exception.Message $verificationDetails
    Write-Log "FAILED: $($_.Exception.Message)"
    exit 1
}
finally {
    if (-not $KeepArtifacts) {
        Remove-Item -Path $installerPath, $initScriptPath -Force -ErrorAction SilentlyContinue
    }
}
