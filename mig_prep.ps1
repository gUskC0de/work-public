[CmdletBinding()]
param(
    [string]$WorkingDirectory = (Join-Path $PSScriptRoot 'driver-work'),
    [string]$StatusPath = (Join-Path $PSScriptRoot 'driver-status.json'),
    [string]$LogPath = (Join-Path $PSScriptRoot 'driver-install.log'),
    [string]$ExpectedInstallerSha256 = '',
    [switch]$AllowUnsignedInstaller,
    [switch]$KeepArtifacts
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

try {
    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    $logParent = Split-Path -Parent $LogPath
    $statusParent = Split-Path -Parent $StatusPath
    if ($logParent) { New-Item -ItemType Directory -Path $logParent -Force | Out-Null }
    if ($statusParent) { New-Item -ItemType Directory -Path $statusParent -Force | Out-Null }
    Write-Log "Starting VirtIO SCSI driver setup."

    Assert-Administrator
    Set-Stage 'prerequisites' 'Succeeded' 'Running with administrator privileges.'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
    Invoke-WebRequest -Uri $initScriptUrl -OutFile $initScriptPath -UseBasicParsing
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
    Set-Stage 'download' 'Succeeded' "Downloaded and validated installer. SHA-256: $installerHash"

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
    $signedDriver = Get-CimInstance Win32_PnPSignedDriver -Filter "Service='vioscsi'" -ErrorAction SilentlyContinue | Select-Object -First 1
    [string[]]$scOutput = @(& sc.exe query vioscsi 2>&1 | ForEach-Object { $_.ToString() })
    $scExitCode = $LASTEXITCODE
    $scServiceExists = $scExitCode -eq 0
    $scState = 'NOT_INSTALLED'
    $stateLine = $scOutput | Where-Object { $_ -match 'STATE\s+:\s+\d+\s+(\w+)' } | Select-Object -First 1
    if ($stateLine -and $stateLine -match 'STATE\s+:\s+\d+\s+(\w+)') {
        $scState = $Matches[1]
    } elseif ($scServiceExists) {
        $scState = 'UNKNOWN'
    }
    Write-Log "sc.exe query vioscsi exit code: $scExitCode"
    $scOutput | ForEach-Object { Write-Log "sc.exe: $_" }
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
        driverPresent = [bool]$signedDriver
        driverVersion = if ($signedDriver) { $signedDriver.DriverVersion } else { $null }
        scServiceCheck = [ordered]@{
            name = 'vioscsi'
            exists = $scServiceExists
            state = $scState
            exitCode = $scExitCode
            rawOutput = $scOutput
        }
        criticalDeviceEntries = @($criticalEntries)
    }
    if (-not $service -or -not $signedDriver -or -not $scServiceExists -or @($criticalEntries).Count -lt 2 -or (@($criticalEntries) | Where-Object service -ne 'vioscsi')) {
        throw "Independent verification failed: vioscsi service, signed driver, or critical-device entries are missing."
    }
    Set-Stage 'verification' 'Succeeded' 'vioscsi service, signed driver, and critical-device entries are present.'
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
