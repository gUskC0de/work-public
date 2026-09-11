<#!
.SYNOPSIS
    Tests whether a VMware-hosted Windows Server VM is ready for migration to Proxmox with Veeam.

.DESCRIPTION
    Performs read-only checks for mounted media, networking, VirtIO drivers, VMware Tools,
    pending reboots, services, disks, filesystems, event logs, VSS, Windows Update, and identity.
    The script does not install drivers, change services, schedule repairs, or send data over
    the network. It writes local log and report files under C:\Migration.

.PARAMETER EventLookbackHours
    Number of hours of Critical/Error event history to inspect. Default is 24.

.PARAMETER CriticalSystemFreeSpaceGB
    System-volume free-space threshold that produces FAIL. Default is 2 GB.

.PARAMETER WarningSystemFreeSpaceGB
    System-volume free-space threshold that produces WARNING. Default is 10 GB.

.PARAMETER FailedVssWritersAreFailure
    Treat failed VSS writers as FAIL instead of WARNING.

.EXAMPLE
    .\Test-MigrationReadiness.ps1

.EXAMPLE
    .\Test-MigrationReadiness.ps1 -EventLookbackHours 48 -CriticalSystemFreeSpaceGB 5

.EXAMPLE OUTPUT
    [PASS] Administrator: Running with elevated Administrator privileges.
    [PASS] Mounted CD/DVD/ISO media: No CD/DVD drive contains mounted media.
    [WARNING] VMware Tools: Installed but service status is Stopped.
    [FAIL] Network adapters: 2 active network adapters were found; manual network migration planning is required.
    Overall readiness: FAIL
    Reports: C:\Migration\Logs\MigrationReadiness.log, C:\Migration\MigrationReadiness.json, C:\Migration\MigrationReadiness.txt

.NOTES
    Supported targets: Windows Server 2016, 2019, 2022, and 2025; PowerShell 5.1+.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 720)]
    [int]$EventLookbackHours = 24,
    [ValidateRange(1, 1024)]
    [int]$CriticalSystemFreeSpaceGB = 2,
    [ValidateRange(2, 2048)]
    [int]$WarningSystemFreeSpaceGB = 10,
    [switch]$FailedVssWritersAreFailure
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Configuration and report paths. The script only writes these local report artifacts.
$RootPath = 'C:\Migration'
$LogDirectory = Join-Path $RootPath 'Logs'
$LogPath = Join-Path $LogDirectory 'MigrationReadiness.log'
$JsonPath = Join-Path $RootPath 'MigrationReadiness.json'
$TextPath = Join-Path $RootPath 'MigrationReadiness.txt'
$SchemaVersion = '1.0'
$script:Results = New-Object System.Collections.ArrayList
$script:LogWriter = $null
$script:StartedAt = [DateTime]::UtcNow

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    if ($script:LogWriter) { $script:LogWriter.WriteLine($line); $script:LogWriter.Flush() }
}

function Redact-SensitiveText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    $redacted = $Text -replace '(?i)(password|passwd|pwd|token|secret|apikey|api_key)\s*[=:]\s*[^\s;]+', '$1=<redacted>'
    return $redacted.Substring(0, [Math]::Min(1000, $redacted.Length))
}

function Get-StateColor {
    param([string]$State)
    switch ($State) {
        'PASS' { return [ConsoleColor]::Green }
        'WARNING' { return [ConsoleColor]::Yellow }
        'FAIL' { return [ConsoleColor]::Red }
        default { return [ConsoleColor]::DarkGray }
    }
}

function Add-CheckResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'WARNING', 'FAIL', 'NOT_CHECKED')][string]$State,
        [Parameter(Mandatory = $true)][string]$Summary,
        [object]$Details = @(),
        [string]$ErrorMessage = ''
    )
    $result = [ordered]@{
        name = $Name
        state = $State
        summary = $Summary
        details = @($Details)
        error = $ErrorMessage
        checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    [void]$script:Results.Add([pscustomobject]$result)
    Write-Log ('[{0}] {1}: {2}' -f $State, $Name, $Summary) (Get-StateColor $State)
    foreach ($detail in @($Details)) { if ($null -ne $detail -and "$detail" -ne '') { Write-Log "    $detail" ([ConsoleColor]::DarkGray) } }
    if ($ErrorMessage) { Write-Log "    Error: $ErrorMessage" ([ConsoleColor]::Red) }
    return $result
}

function Invoke-ReadOnlyCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    try { & $Action }
    catch {
        Add-CheckResult -Name $Name -State 'NOT_CHECKED' -Summary 'The check could not be completed.' -ErrorMessage $_.Exception.Message | Out-Null
    }
}

function Test-Administrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Add-CheckResult 'Administrator' 'PASS' 'Running with elevated Administrator privileges.' | Out-Null
            return $true
        }
        Add-CheckResult 'Administrator' 'FAIL' 'The script must be run as Administrator.' | Out-Null
        return $false
    } catch { Add-CheckResult 'Administrator' 'FAIL' 'Administrator status could not be determined.' -ErrorMessage $_.Exception.Message | Out-Null; return $false }
}

function Test-MountedMedia {
    Invoke-ReadOnlyCheck 'Mounted CD/DVD/ISO media' {
        $drives = @(Get-CimInstance Win32_CDROMDrive -ErrorAction Stop)
        $mounted = @($drives | Where-Object { $_.MediaLoaded -eq $true })
        if ($mounted.Count -eq 0) {
            $details = @($drives | ForEach-Object { "Device $($_.Drive) exists but is empty ($($_.Name))." })
            Add-CheckResult 'Mounted CD/DVD/ISO media' 'PASS' 'No CD/DVD drive contains mounted media.' $details | Out-Null
        } else {
            $details = @($mounted | ForEach-Object { "Drive $($_.Drive), label='$($_.VolumeName)', media='$($_.Name)', serial='$($_.SerialNumber)'. Remove mounted media before migration." })
            Add-CheckResult 'Mounted CD/DVD/ISO media' 'FAIL' 'Mounted CD/DVD or ISO media was detected.' $details | Out-Null
        }
    }
}

function Test-NetworkAdapters {
    Invoke-ReadOnlyCheck 'Network adapters' {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.HardwareInterface -and $_.Status -eq 'Up' -and
            $_.Name -notmatch 'Loopback|ISATAP|Teredo|Tunnel' -and
            $_.InterfaceDescription -notmatch 'Loopback|ISATAP|Teredo|Tunnel'
        })
        $details = @()
        foreach ($adapter in $adapters) {
            $ip = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -ExpandProperty IPAddress)
            $gw = @(Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPv4DefaultGateway | Select-Object -ExpandProperty NextHop)
            $details += "Name='$($adapter.Name)', Description='$($adapter.InterfaceDescription)', MAC=$($adapter.MacAddress), IfIndex=$($adapter.ifIndex), Link=$($adapter.Status), IP=$($ip -join ', '), Gateway=$($gw -join ', ')"
        }
        if ($adapters.Count -eq 1) { Add-CheckResult 'Network adapters' 'PASS' 'Exactly one active physical or virtual network adapter was found.' $details | Out-Null }
        elseif ($adapters.Count -gt 1) { Add-CheckResult 'Network adapters' 'FAIL' "$($adapters.Count) active network adapters were found; manual network migration planning is required." $details | Out-Null }
        else { Add-CheckResult 'Network adapters' 'FAIL' 'No active relevant network adapter was found.' | Out-Null }
    }
}

function Test-VirtIODrivers {
    Invoke-ReadOnlyCheck 'VirtIO driver readiness' {
        $names = @('viostor', 'vioscsi', 'NetKVM', 'Balloon', 'vioserial')
        $driverServices = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop | Where-Object { $_.Name -in @('viostor', 'vioscsi') })
        $driverStoreText = @()
        if (Get-Command pnputil.exe -ErrorAction SilentlyContinue) {
            $driverStoreText = @(& pnputil.exe /enum-drivers 2>&1)
        }
        $driverStoreTextJoined = $driverStoreText -join "`n"
        $driverStoreInstalled = @{}
        $driverStoreEvidence = @{}
        foreach ($driverInf in @('viostor.inf', 'vioscsi.inf')) {
            # pnputil output is localized and its formatting varies by Windows version.
            # Matching the INF name anywhere in /enum-drivers output is intentional.
            $driverName = [System.IO.Path]::GetFileNameWithoutExtension($driverInf)
            $infMatch = $driverStoreTextJoined -match "(?i)(^|[^a-z0-9])$([regex]::Escape($driverInf))([^a-z0-9]|$)"
            $sysPath = Join-Path $env:windir "System32\drivers\$driverName.sys"
            $sysMatch = Test-Path $sysPath -PathType Leaf
            $driverStoreInstalled[$driverInf] = $infMatch -or $sysMatch
            $evidence = @()
            if ($infMatch) { $evidence += 'pnputil Driver Store enumeration' }
            if ($sysMatch) { $evidence += $sysPath }
            $driverStoreEvidence[$driverInf] = @($evidence)
        }
        $drivers = @()
        try { $drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DriverProviderName -match 'Red Hat|VirtIO' -or $_.DeviceName -match 'VirtIO|NetKVM|Balloon' }) } catch { $drivers = @() }
        $found = @{}
        $found['viostor'] = @($driverServices | Where-Object Name -eq 'viostor')
        $found['vioscsi'] = @($driverServices | Where-Object Name -eq 'vioscsi')
        foreach ($name in @('NetKVM', 'Balloon', 'vioserial')) { $found[$name] = @($drivers | Where-Object { $_.DeviceName -match [regex]::Escape($name) -or $_.InfName -match [regex]::Escape($name) }) }
        $missingNet = @($found['NetKVM']).Length -eq 0
        $details = @()
        foreach ($storageDriver in @('viostor', 'vioscsi')) {
            $service = @($found[$storageDriver]) | Select-Object -First 1
            if ($service) {
                $details += "{0}: installed; State={1}; StartMode={2}; PathName={3}" -f $service.Name, $service.State, $service.StartMode, $service.PathName
            } elseif ($driverStoreInstalled["$storageDriver.inf"]) {
                $details += "{0}: installed; no active device service is registered yet; evidence={1}" -f $storageDriver, ($driverStoreEvidence["$storageDriver.inf"] -join ', ')
            } else {
                $details += "{0}: not detected in Driver Store or Win32_SystemDriver" -f $storageDriver
            }
        }
        foreach ($driverName in @('NetKVM', 'Balloon', 'vioserial')) {
            $details += "{0}: " -f $driverName + $(if (@($found[$driverName]).Length -gt 0) { 'present in PnP Driver Store' } else { 'not detected' })
        }
        $agent = Get-Service -Name 'QEMU-GA', 'qemu-ga' -ErrorAction SilentlyContinue | Select-Object -First 1
        $details += "QEMU Guest Agent service: " + $(if ($agent) { "$($agent.Status)" } else { 'not installed' })
        $storageMissing = @()
        foreach ($storageName in @('viostor', 'vioscsi')) {
            if ((@($found[$storageName]).Length -eq 0) -and (-not $driverStoreInstalled["$storageName.inf"])) {
                $storageMissing += $storageName
            }
        }
        $missingStorageCount = @($storageMissing).Length
        if ($missingStorageCount -gt 0) { Add-CheckResult 'VirtIO driver readiness' 'FAIL' "Missing required storage driver(s): $($storageMissing -join ', ')." $details | Out-Null }
        elseif ($missingNet) { Add-CheckResult 'VirtIO driver readiness' 'WARNING' 'VirtIO storage drivers are present, but NetKVM was not detected.' $details | Out-Null }
        else { Add-CheckResult 'VirtIO driver readiness' 'PASS' 'VirtIO storage and NetKVM drivers were detected.' $details | Out-Null }
    }
}

function Test-VMwareTools {
    Invoke-ReadOnlyCheck 'VMware Tools' {
        $service = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
        $app = Get-ItemProperty 'HKLM:\SOFTWARE\VMware, Inc.\VMware Tools', 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Tools' -ErrorAction SilentlyContinue | Select-Object -First 1
        $version = $null
        if ($app) {
            $versionProperty = $app.PSObject.Properties['Version']
            $productVersionProperty = $app.PSObject.Properties['ProductVersion']
            if ($versionProperty -and $versionProperty.Value) { $version = $versionProperty.Value }
            elseif ($productVersionProperty -and $productVersionProperty.Value) { $version = $productVersionProperty.Value }
        }
        if (-not $service -and -not $app) { Add-CheckResult 'VMware Tools' 'PASS' 'VMware Tools is not installed.' | Out-Null }
        elseif (-not $service) { Add-CheckResult 'VMware Tools' 'FAIL' "VMware Tools registry data is present, but the service was not detected. Remove VMware Tools before migration. Version: $(if ($version) {$version} else {'not available'})." | Out-Null }
        elseif ($service.Status -eq 'Running') { Add-CheckResult 'VMware Tools' 'FAIL' "VMware Tools is still installed and running. Remove VMware Tools before migration. Version: $(if ($version) {$version} else {'not available'})." | Out-Null }
        else { Add-CheckResult 'VMware Tools' 'FAIL' "VMware Tools is still installed; service status is $($service.Status). Remove VMware Tools before migration. Version: $(if ($version) {$version} else {'not available'})." | Out-Null }
    }
}

function Test-PendingReboot {
    Invoke-ReadOnlyCheck 'Pending reboot' {
        $reasons = @()
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Component Based Servicing' }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
        $session = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
        if ($session.PendingFileRenameOperations) { $reasons += 'Pending file rename operations' }
        if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName') {
            $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
            $pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
            if ($active -and $pending -and $active -ne $pending) { $reasons += 'Computer rename pending' }
        }
        if ($reasons.Count -gt 0) { Add-CheckResult 'Pending reboot' 'WARNING' 'A reboot is pending.' $reasons | Out-Null }
        else { Add-CheckResult 'Pending reboot' 'PASS' 'No common pending reboot indicators were detected.' | Out-Null }
    }
}

function Test-ServiceHealth {
    Invoke-ReadOnlyCheck 'Windows service health' {
        $services = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" -ErrorAction Stop)
        $stopped = @($services | Where-Object {
            $delayedPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.Name)"
            $delayedProperties = Get-ItemProperty -Path $delayedPath -ErrorAction SilentlyContinue
            $delayedProperty = if ($delayedProperties) { $delayedProperties.PSObject.Properties['DelayedAutostart'] } else { $null }
            $delayed = if ($delayedProperty) { $delayedProperty.Value } else { 0 }
            [int]$delayed -ne 1
        })
        $details = @($stopped | ForEach-Object { "$($_.Name): state=$($_.State), start=$($_.StartMode), display='$($_.DisplayName)'" })
        if ($services.Count -eq 0) { Add-CheckResult 'Windows service health' 'NOT_CHECKED' 'Automatic service state could not be enumerated.' | Out-Null }
        elseif ($stopped.Count -gt 0) { Add-CheckResult 'Windows service health' 'WARNING' "$($stopped.Count) non-delayed automatic service(s) are not running; review whether they are expected." $details | Out-Null }
        else { Add-CheckResult 'Windows service health' 'PASS' 'No unexpected stopped automatic services were detected.' | Out-Null }
    }
}

function Test-DiskHealth {
    Invoke-ReadOnlyCheck 'Disk and volume health' {
        $disks = @(Get-Disk -ErrorAction Stop)
        $bad = @($disks | Where-Object { $_.OperationalStatus -notcontains 'Online' -or $_.HealthStatus -eq 'Unhealthy' -or $_.HealthStatus -eq 'Failed' })
        $unknown = @($disks | Where-Object { $_.HealthStatus -eq 'Unknown' })
        $details = @($disks | ForEach-Object { "Disk $($_.Number): status=$($_.OperationalStatus -join ','), health=$($_.HealthStatus), style=$($_.PartitionStyle), sizeGB=$([math]::Round($_.Size / 1GB, 2))" })
        $volumes = @(Get-Volume -ErrorAction Stop)
        $unhealthyVolumes = @($volumes | Where-Object { $_.HealthStatus -eq 'Unhealthy' -or $_.HealthStatus -eq 'Failed' })
        $bitLockerUnavailable = 0
        foreach ($volume in $volumes) {
            $bitLockerStatus = 'Unavailable'
            if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
                try {
                    $bitLocker = Get-BitLockerVolume -MountPoint "$($volume.DriveLetter):" -ErrorAction Stop
                    $bitLockerStatus = "$($bitLocker.VolumeStatus), protection=$($bitLocker.ProtectionStatus), encryption=$($bitLocker.EncryptionPercentage)%"
                } catch { $bitLockerStatus = "Unavailable: $($_.Exception.Message)"; $bitLockerUnavailable++ }
            } else {
                $bitLockerUnavailable++
            }
            $details += "Volume $($volume.DriveLetter): label='$($volume.FileSystemLabel)', fs=$($volume.FileSystem), health=$($volume.HealthStatus), sizeGB=$([math]::Round($volume.Size / 1GB, 2)), freeGB=$([math]::Round($volume.SizeRemaining / 1GB, 2)), BitLocker=$bitLockerStatus"
        }
        $system = $volumes | Where-Object { $_.DriveLetter -eq $env:SystemDrive.TrimEnd(':') } | Select-Object -First 1
        if ($disks.Count -eq 0) { Add-CheckResult 'Disk and volume health' 'NOT_CHECKED' 'Disk inventory could not be enumerated.' $details | Out-Null }
        elseif ($bad.Count -gt 0) { Add-CheckResult 'Disk and volume health' 'FAIL' 'One or more disks are offline or unhealthy.' $details | Out-Null }
        elseif ($unhealthyVolumes.Count -gt 0) { Add-CheckResult 'Disk and volume health' 'FAIL' 'One or more volumes reported an unhealthy or failed state.' $details | Out-Null }
        elseif ($unknown.Count -gt 0) { Add-CheckResult 'Disk and volume health' 'WARNING' 'One or more disks reported unknown health.' $details | Out-Null }
        elseif (-not $system) { Add-CheckResult 'Disk and volume health' 'FAIL' 'The system volume could not be identified or is inaccessible.' $details | Out-Null }
        elseif (($system.SizeRemaining / 1GB) -lt $CriticalSystemFreeSpaceGB) { Add-CheckResult 'Disk and volume health' 'FAIL' "System volume has less than $CriticalSystemFreeSpaceGB GB free." $details | Out-Null }
        elseif ($system -and ($system.SizeRemaining / 1GB) -lt $WarningSystemFreeSpaceGB) { Add-CheckResult 'Disk and volume health' 'WARNING' "System volume has less than $WarningSystemFreeSpaceGB GB free." $details | Out-Null }
        elseif ($bitLockerUnavailable -gt 0) { Add-CheckResult 'Disk and volume health' 'WARNING' "BitLocker status was unavailable for $bitLockerUnavailable volume(s)." $details | Out-Null }
        else { Add-CheckResult 'Disk and volume health' 'PASS' 'Disks and volumes appear operational; volume inventory captured.' $details | Out-Null }
    }
}

function Test-FileSystems {
    Invoke-ReadOnlyCheck 'Filesystem checks' {
        $checked = @(); $issues = @()
        $volumes = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })
        foreach ($volume in $volumes) {
            $drive = "$($volume.DriveLetter):"
            $output = & fsutil dirty query $drive 2>&1
            $text = ($output -join ' ').Trim()
            $checked += "$drive NTFS: $text"
            if ($LASTEXITCODE -ne 0 -or $text -match '(?i)(is dirty|cannot|failed|error)') { $issues += "$($drive): $text" }
        }
        if ($volumes.Count -eq 0) { Add-CheckResult 'Filesystem checks' 'NOT_CHECKED' 'No drive-letter NTFS volumes were available.' | Out-Null }
        elseif ($issues.Count -gt 0) { Add-CheckResult 'Filesystem checks' 'WARNING' 'One or more NTFS volumes require review; only the read-only dirty-bit query was run.' ($checked + $issues) | Out-Null }
        else { Add-CheckResult 'Filesystem checks' 'PASS' 'Read-only NTFS dirty-bit checks completed; no dirty volumes were reported.' $checked | Out-Null }
    }
}

function Test-EventLogs {
    Invoke-ReadOnlyCheck 'Event log health' {
        $start = (Get-Date).AddHours(-$EventLookbackHours)
        $events = @()
        $unavailableLogs = @()
        foreach ($log in @('System', 'Application')) {
            try { $events += @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1, 2; StartTime = $start } -MaxEvents 200 -ErrorAction Stop) } catch { $unavailableLogs += ('{0}: {1}' -f $log, $_.Exception.Message) }
        }
        $providers = @('Disk', 'Ntfs', 'storport', 'volmgr', 'Service Control Manager', 'WHEA-Logger')
        $selected = @($events | Where-Object { $_.ProviderName -in $providers -or $_.Message -match 'disk|filesystem|NTFS|storage|WHEA' } | Sort-Object TimeCreated -Descending | Select-Object -Unique Id, ProviderName, TimeCreated, Message -First 25)
        $details = @($selected | ForEach-Object { "$($_.TimeCreated): ID=$($_.Id), Provider=$($_.ProviderName), $(Redact-SensitiveText (($_.Message -replace '\s+', ' ').Trim()))" })
        if ($unavailableLogs.Count -gt 0) { Add-CheckResult 'Event log health' 'NOT_CHECKED' 'One or more event logs could not be read.' ($unavailableLogs + $details) | Out-Null }
        elseif ($selected.Count -gt 0) { Add-CheckResult 'Event log health' 'WARNING' "$($selected.Count) relevant Critical/Error event(s) found in the last $EventLookbackHours hour(s)." $details | Out-Null }
        else { Add-CheckResult 'Event log health' 'PASS' "No relevant Critical/Error events found in the last $EventLookbackHours hour(s)." | Out-Null }
    }
}

function Test-VssHealth {
    Invoke-ReadOnlyCheck 'VSS health' {
        $output = @(& vssadmin list writers 2>&1)
        if ($LASTEXITCODE -ne 0) { Add-CheckResult 'VSS health' 'NOT_CHECKED' 'vssadmin could not enumerate VSS writers.' -ErrorMessage ($output -join ' ') | Out-Null; return }
        $bad = @($output | Where-Object { $_ -match 'State: \[(?!1\])|Last error: (?!No error)' })
        if ($bad.Count -gt 0) { Add-CheckResult 'VSS health' $(if ($FailedVssWritersAreFailure) { 'FAIL' } else { 'WARNING' }) 'One or more VSS writers are not stable or report an error.' $bad | Out-Null }
        else { Add-CheckResult 'VSS health' 'PASS' 'VSS writers reported stable with no errors.' | Out-Null }
    }
}

function Test-WindowsUpdate {
    Invoke-ReadOnlyCheck 'Windows Update status' {
        $last = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings' -ErrorAction SilentlyContinue
        $details = @("LastSuccessTime: $($last.LastSuccessTime)", "RebootRequired: $([bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))")
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { Add-CheckResult 'Windows Update status' 'WARNING' 'Windows Update reports a pending reboot.' $details | Out-Null }
        else { Add-CheckResult 'Windows Update status' 'PASS' 'No Windows Update pending reboot was detected; no updates were installed.' $details | Out-Null }
    }
}

function Get-SystemIdentity {
    Invoke-ReadOnlyCheck 'Basic system identity' {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $details = @(
            "Computer: $env:COMPUTERNAME",
            "Domain/workgroup: $($cs.Domain) (joined=$($cs.PartOfDomain))",
            "Edition: $($os.Caption)",
            "Version/build: $($os.Version) / $($os.BuildNumber)",
            "Boot time: $($os.LastBootUpTime)",
            "Time zone: $([TimeZoneInfo]::Local.Id)"
        )
        Add-CheckResult 'Basic system identity' 'PASS' 'System identity was captured.' $details | Out-Null
    }
}

function Write-Reports {
    $counts = @{}
    foreach ($state in @('PASS', 'WARNING', 'FAIL', 'NOT_CHECKED')) { $counts[$state] = @($script:Results | Where-Object state -eq $state).Count }
    $overall = if ($counts['FAIL'] -gt 0) { 'FAIL' } elseif ($counts['WARNING'] -gt 0 -or $counts['NOT_CHECKED'] -gt 0) { 'WARNING' } else { 'PASS' }
    $blocking = @($script:Results | Where-Object state -eq 'FAIL' | ForEach-Object { "$($_.name): $($_.summary)" })
    $warnings = @($script:Results | Where-Object { $_.state -eq 'WARNING' -or $_.state -eq 'NOT_CHECKED' } | ForEach-Object { "$($_.name): $($_.summary)" })
    $report = [ordered]@{ schemaVersion = $SchemaVersion; scriptVersion = '1.0.0'; generatedAtUtc = [DateTime]::UtcNow.ToString('o'); overallStatus = $overall; counts = $counts; parameters = @{ eventLookbackHours = $EventLookbackHours; criticalSystemFreeSpaceGB = $CriticalSystemFreeSpaceGB; warningSystemFreeSpaceGB = $WarningSystemFreeSpaceGB; failedVssWritersAreFailure = [bool]$FailedVssWritersAreFailure }; checks = @($script:Results); blockingIssues = $blocking; warnings = $warnings }
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $JsonPath -Encoding UTF8
    $lines = @('Migration readiness report', ('Generated UTC: ' + $report.generatedAtUtc), ('Overall status: ' + $overall), '', 'Counts:')
    foreach ($state in @('PASS', 'WARNING', 'FAIL', 'NOT_CHECKED')) { $lines += "  $($state): $($counts[$state])" }
    $lines += ''; $lines += 'Checks:'; foreach ($item in $script:Results) { $lines += "[$($item.state)] $($item.name) - $($item.summary)"; foreach ($detail in $item.details) { $lines += "    $detail" } }
    $lines += ''; $lines += 'Blocking issues:'; $lines += $(if ($blocking.Count) { $blocking } else { '  None' }); $lines += ''; $lines += 'Warnings:'; $lines += $(if ($warnings.Count) { $warnings } else { '  None' })
    $lines | Set-Content -Path $TextPath -Encoding UTF8
    Write-Log "Overall readiness: $overall" (Get-StateColor $overall)
    Write-Log "Reports: $LogPath, $JsonPath, $TextPath" ([ConsoleColor]::Cyan)
    return @{ Overall = $overall; Counts = $counts }
}

try {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    if (Test-Path $LogPath) { Move-Item -Path $LogPath -Destination (Join-Path $LogDirectory ('MigrationReadiness_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))) -Force }
    $script:LogWriter = New-Object System.IO.StreamWriter($LogPath, $false, [Text.Encoding]::UTF8)
    Write-Log 'Starting migration readiness checks.' ([ConsoleColor]::Cyan)
    if (-not (Test-Administrator)) { Write-Reports | Out-Null; exit 2 }
    Test-MountedMedia
    Test-NetworkAdapters
    Test-VirtIODrivers
    Test-VMwareTools
    Test-PendingReboot
    Test-ServiceHealth
    Test-DiskHealth
    Test-FileSystems
    Test-EventLogs
    Test-VssHealth
    Test-WindowsUpdate
    Get-SystemIdentity
    $summary = Write-Reports
    if ($summary.Overall -eq 'FAIL') { exit 2 }
    if ($summary.Overall -eq 'WARNING') { exit 1 }
    exit 0
} catch {
    try { Write-Log "Unexpected script error: $($_.Exception.Message)" ([ConsoleColor]::Red); Add-CheckResult 'Script execution' 'NOT_CHECKED' 'The script encountered an unexpected error.' -ErrorMessage $_.Exception.Message | Out-Null; Write-Reports | Out-Null } catch { }
    exit 3
} finally {
    if ($script:LogWriter) { $script:LogWriter.Dispose() }
}
