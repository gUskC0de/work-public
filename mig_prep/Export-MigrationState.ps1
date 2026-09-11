<#
.SYNOPSIS
    Captures pre-migration state from a VMware-hosted Windows Server VM.

.DESCRIPTION
    Captures read-only system, network, disk, service, role, share, task, port, and
    event-log state before a Veeam restore to Proxmox. The safety gate refuses to
    capture when optical media is mounted or the VM has zero or multiple active NICs.
    No drivers, devices, routes, services, disks, credentials, or network settings are
    changed, and no information is transmitted.

.PARAMETER EventLookbackHours
    Number of hours of Critical/Error System and Application events to capture. Default 24.

.PARAMETER ScriptVersion
    Version written into the capture schema. Default 1.0.0.

.PARAMETER ValidateOnly
    Runs only the administrator, mounted-media, and active-NIC safety checks. It writes
    the log and transcript but does not write the complete capture files.

.EXAMPLE
    .\Export-MigrationState.ps1

.EXAMPLE
    .\Export-MigrationState.ps1 -EventLookbackHours 48 -ValidateOnly

.EXAMPLE OUTPUT
    [PASS] Administrator: Running elevated.
    [PASS] Mounted media: No CD/DVD or ISO media is mounted.
    [PASS] Active network adapter: Exactly one active adapter detected: Ethernet.
    Capture completed successfully.
    Exit code: 0

.NOTES
    Supported targets: Windows Server 2016, 2019, 2022, and 2025; PowerShell 5.1+.
    Output schema version: 1.0.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 720)]
    [int]$EventLookbackHours = 24,
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$ScriptVersion = '1.0.0',
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RootPath = 'C:\Migration'
$StatePath = Join-Path $RootPath 'State'
$LogDirectory = Join-Path $RootPath 'Logs'
$LogPath = Join-Path $LogDirectory 'ExportMigrationState.log'
$TranscriptPath = Join-Path $LogDirectory 'ExportMigrationState.transcript.log'
$StateJsonPath = Join-Path $StatePath 'PreMigrationState.json'
$StateTextPath = Join-Path $StatePath 'PreMigrationState.txt'
$NetworkJsonPath = Join-Path $StatePath 'NetworkConfiguration.json'
$RoutePath = Join-Path $StatePath 'route-print-4.txt'
$IpConfigPath = Join-Path $StatePath 'ipconfig-all.txt'
$ArpPath = Join-Path $StatePath 'arp-a.txt'
$SchemaVersion = '1.0'
$script:LogWriter = $null
$script:TranscriptStarted = $false
$script:Results = New-Object System.Collections.ArrayList
$script:StartedAt = [DateTime]::UtcNow
$script:Capture = [ordered]@{}
$script:EventLogCaptureWarnings = New-Object System.Collections.ArrayList

function Get-StateColor {
    param([string]$State)
    switch ($State) {
        'PASS' { return [ConsoleColor]::Green }
        'WARNING' { return [ConsoleColor]::Yellow }
        'FAIL' { return [ConsoleColor]::Red }
        default { return [ConsoleColor]::DarkGray }
    }
}

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

function Get-SafeExecutablePath {
    param([AllowNull()][string]$PathName)
    if ([string]::IsNullOrWhiteSpace($PathName)) { return $null }
    if ($PathName -match '^"([^"]+)"') { return $Matches[1] }
    return ($PathName -split '\s+', 2)[0]
}

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'WARNING', 'FAIL', 'NOT_CHECKED')][string]$State,
        [Parameter(Mandatory = $true)][string]$Summary,
        [object]$Details = @(),
        [string]$FailureMessage = ''
    )
    $result = [ordered]@{
        name = $Name
        state = $State
        summary = $Summary
        details = @($Details)
        error = $FailureMessage
        checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    [void]$script:Results.Add([pscustomobject]$result)
    Write-Log ('[{0}] {1}: {2}' -f $State, $Name, $Summary) (Get-StateColor $State)
    foreach ($detail in @($Details)) { if ($null -ne $detail -and "$detail" -ne '') { Write-Log "    $detail" ([ConsoleColor]::DarkGray) } }
    if ($FailureMessage) { Write-Log "    Error: $FailureMessage" ([ConsoleColor]::Red) }
}

function Invoke-CapturePart {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    try { & $Action }
    catch {
        Add-Result -Name $Name -State 'WARNING' -Summary 'Capture was not available; the remaining capture continued.' -FailureMessage $_.Exception.Message
    }
}

function Test-Administrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Add-Result 'Administrator' 'PASS' 'Running elevated.'
            return $true
        }
        Add-Result 'Administrator' 'FAIL' 'Administrator privileges are required.'
        return $false
    } catch {
        Add-Result 'Administrator' 'FAIL' 'Administrator status could not be determined.' -FailureMessage $_.Exception.Message
        return $false
    }
}

function Get-OpticalMedia {
    $drives = @(Get-CimInstance Win32_CDROMDrive -ErrorAction Stop)
    return @($drives | ForEach-Object {
        [pscustomobject][ordered]@{
            driveLetter = $_.Drive
            deviceName = $_.Name
            mediaLoaded = [bool]$_.MediaLoaded
            volumeName = $_.VolumeName
            serialNumber = $_.SerialNumber
            mediaType = $_.MediaType
        }
    })
}

function Test-MountedMediaSafety {
    try {
        $media = @(Get-OpticalMedia)
        $mounted = @($media | Where-Object mediaLoaded)
        if ($mounted.Count -gt 0) {
            $details = @($mounted | ForEach-Object { "Drive $($_.driveLetter), label='$($_.volumeName)', device='$($_.deviceName)', serial='$($_.serialNumber)'. Remove mounted media before capture." })
            Add-Result 'Mounted media' 'FAIL' 'CD/DVD or ISO media is mounted. State capture was blocked.' $details
            return $false
        }
        Add-Result 'Mounted media' 'PASS' 'No CD/DVD or ISO media is mounted.' @($media | ForEach-Object { "Empty optical device: $($_.driveLetter) ($($_.deviceName))." })
        return $true
    } catch {
        Add-Result 'Mounted media' 'FAIL' 'The optical-media safety check could not be completed; capture was blocked.' -FailureMessage $_.Exception.Message
        return $false
    }
}

function Get-ActiveAdapters {
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
        $_.HardwareInterface -and $_.Status -eq 'Up' -and
        $_.Name -notmatch 'Loopback|ISATAP|Teredo|Tunnel' -and
        $_.InterfaceDescription -notmatch 'Loopback|ISATAP|Teredo|Tunnel'
    })
    return @($adapters | ForEach-Object {
        $configuration = Get-NetIPConfiguration -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue
        $addresses = @(Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object AddressState -eq 'Preferred')
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ServerAddresses)
        $dnsClient = Get-DnsClient -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1
        $ipInterface = $_ | Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $vlan = Get-NetAdapterAdvancedProperty -Name $_.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'VLAN|Priority|Virtual LAN' } | Select-Object DisplayName, DisplayValue
        [pscustomobject][ordered]@{
            adapterName = $_.Name
            interfaceAlias = $_.Name
            interfaceDescription = $_.InterfaceDescription
            interfaceIndex = [int]$_.ifIndex
            interfaceGuid = $_.InterfaceGuid
            macAddress = $_.MacAddress
            linkSpeed = $_.LinkSpeed
            status = $_.Status.ToString()
            dhcpEnabled = [bool]($ipInterface -and $ipInterface.Dhcp -eq 'Enabled')
            ipv4Addresses = @($addresses | ForEach-Object { [pscustomobject][ordered]@{ address = $_.IPAddress; prefixLength = [int]$_.PrefixLength; subnetMask = Convert-PrefixToMask $_.PrefixLength } })
            defaultGateways = if ($configuration) { @($configuration.IPv4DefaultGateway | ForEach-Object NextHop) } else { @() }
            dnsServers = @($dns)
            dnsSuffix = if ($dnsClient) { $dnsClient.ConnectionSpecificSuffix } else { $null }
            registerThisConnectionAddress = if ($dnsClient) { $dnsClient.RegisterThisConnectionsAddress } else { $null }
            useSuffixWhenRegistering = if ($dnsClient) { $dnsClient.UseSuffixWhenRegistering } else { $null }
            interfaceMetric = if ($ipInterface) { [int]$ipInterface.InterfaceMetric } else { 0 }
            vlanInformation = @($vlan)
            networkProfile = Get-NetworkProfileForInterface $_.ifIndex
        }
    })
}

function Convert-PrefixToMask {
    param([int]$PrefixLength)
    if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) { return $null }
    $bits = ('1' * $PrefixLength).PadRight(32, '0')
    return (($bits -split '(?<=\G.{8})' | Where-Object { $_ } | ForEach-Object { [Convert]::ToInt32($_, 2) }) -join '.')
}

function Get-NetworkProfileForInterface {
    param([int]$InterfaceIndex)
    try {
        $networkProfileData = Get-NetConnectionProfile -InterfaceIndex $InterfaceIndex -ErrorAction Stop
        return [pscustomobject][ordered]@{ name = $networkProfileData.Name; category = $networkProfileData.NetworkCategory.ToString(); ipv4Connectivity = $networkProfileData.IPv4Connectivity.ToString(); ipv6Connectivity = $networkProfileData.IPv6Connectivity.ToString() }
    } catch { return $null }
}

function Get-StructuredRoutes {
    $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)
    return @($routes | ForEach-Object {
        $adapter = Get-NetAdapter -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue
        $protocol = if ($_.PSObject.Properties['RouteProtocol']) { [string]$_.RouteProtocol } else { 'Unknown' }
        [pscustomobject][ordered]@{
            destinationPrefix = $_.DestinationPrefix
            nextHop = $_.NextHop
            interfaceIndex = [int]$_.ifIndex
            interfaceAlias = if ($adapter) { $adapter.Name } else { $null }
            routeMetric = [int]$_.RouteMetric
            protocol = $protocol
            store = if ($_.PSObject.Properties['Store']) { [string]$_.Store } elseif ($_.PSObject.Properties['PolicyStore']) { [string]$_.PolicyStore } else { $null }
            publish = if ($_.PSObject.Properties['Publish'] -and $null -ne $_.Publish) { $_.Publish.ToString() } else { $null }
            isDefaultRoute = $_.DestinationPrefix -eq '0.0.0.0/0'
            isConnectedRoute = $protocol -eq 'Local'
            isPersistentOrStatic = $protocol -match 'NetMgmt|Manual|Static'
        }
    })
}

function Invoke-RawNetworkCapture {
    $commands = @(
        @{ Name = 'ipconfig /all'; File = $IpConfigPath; Command = 'ipconfig /all' },
        @{ Name = 'route print -4'; File = $RoutePath; Command = 'route print -4' },
        @{ Name = 'arp -a'; File = $ArpPath; Command = 'arp -a' }
    )
    $failed = @()
    foreach ($item in $commands) {
        try {
            $output = & cmd.exe /c $item.Command 2>&1
            $output | Set-Content -Path $item.File -Encoding UTF8
            if ($LASTEXITCODE -ne 0) { $failed += "$($item.Name): command exit code $LASTEXITCODE" }
        } catch { $failed += "$($item.Name): $($_.Exception.Message)" }
    }
    if ($failed.Count) { Add-Result 'Raw network outputs' 'WARNING' 'One or more raw network outputs could not be captured completely.' ($failed + @($IpConfigPath, $RoutePath, $ArpPath)) }
    else { Add-Result 'Raw network outputs' 'PASS' 'Saved ipconfig /all, route print -4, and arp -a output.' @($IpConfigPath, $RoutePath, $ArpPath) }
}

function Get-DiskState {
    $disks = @(Get-Disk -ErrorAction Stop)
    return @($disks | ForEach-Object {
        [pscustomobject][ordered]@{
            diskNumber = [int]$_.Number
            friendlyName = $_.FriendlyName
            serialNumber = $_.SerialNumber
            uniqueId = $_.UniqueId
            busType = $_.BusType.ToString()
            partitionStyle = $_.PartitionStyle.ToString()
            sizeBytes = [int64]$_.Size
            operationalStatus = @($_.OperationalStatus | ForEach-Object ToString)
            healthStatus = $_.HealthStatus.ToString()
            isBoot = [bool]$_.IsBoot
            isSystem = [bool]$_.IsSystem
        }
    })
}

function Get-PartitionVolumeState {
    $items = New-Object System.Collections.ArrayList
    foreach ($partition in @(Get-Partition -ErrorAction Stop)) {
        $volume = $null
        try { $volume = $partition | Get-Volume -ErrorAction Stop } catch { }
        $bitLockerStatus = $null
        if ($volume -and $volume.DriveLetter -and (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
            try { $bitLockerStatus = Get-BitLockerVolume -MountPoint "$($volume.DriveLetter):" -ErrorAction Stop | Select-Object VolumeStatus, ProtectionStatus, EncryptionPercentage } catch { $bitLockerStatus = $null }
        }
        [void]$items.Add([pscustomobject][ordered]@{
            diskNumber = [int]$partition.DiskNumber
            partitionNumber = [int]$partition.PartitionNumber
            partitionSizeBytes = [int64]$partition.Size
            partitionType = $partition.Type.ToString()
            driveLetter = if ($volume) { $volume.DriveLetter } else { $null }
            volumeLabel = if ($volume) { $volume.FileSystemLabel } else { $null }
            fileSystem = if ($volume) { $volume.FileSystem } else { $null }
            volumeSizeBytes = if ($volume) { [int64]$volume.Size } else { $null }
            freeSpaceBytes = if ($volume) { [int64]$volume.SizeRemaining } else { $null }
            allocationUnitSizeBytes = if ($volume -and $volume.PSObject.Properties.Name -contains 'AllocationUnitSize') { [int64]$volume.AllocationUnitSize } else { $null }
            bitLocker = $bitLockerStatus
            mountPoints = @($partition.AccessPaths)
        })
    }
    return @($items)
}

function Get-ServiceState {
    $services = @(Get-CimInstance Win32_Service -ErrorAction Stop)
    return [pscustomobject][ordered]@{
        all = @($services | ForEach-Object { [pscustomobject][ordered]@{ name = $_.Name; displayName = $_.DisplayName; status = $_.State; startType = $_.StartMode; serviceAccount = $_.StartName; executablePath = Get-SafeExecutablePath $_.PathName } })
        runningBeforeMigration = @($services | Where-Object State -eq 'Running' | ForEach-Object Name)
    }
}

function Get-RoleFeatureState {
    if (-not (Get-Module -ListAvailable -Name ServerManager)) { return [pscustomobject][ordered]@{ available = $false; installed = @(); message = 'ServerManager module is not available; role capture was not performed.' } }
    try {
        Import-Module ServerManager -ErrorAction Stop
        return [pscustomobject][ordered]@{ available = $true; installed = @(Get-WindowsFeature | Where-Object Installed | ForEach-Object { [pscustomobject][ordered]@{ name = $_.Name; displayName = $_.DisplayName; featureType = $_.FeatureType.ToString(); installState = $_.InstallState.ToString() } }); message = $null }
    } catch { return [pscustomobject][ordered]@{ available = $false; installed = @(); message = $_.Exception.Message } }
}

function Get-SmbShareState {
    if (-not (Get-Command Get-SmbShare -ErrorAction SilentlyContinue)) { return [pscustomobject][ordered]@{ available = $false; includeAdministrativeShares = $false; shares = @(); message = 'SMB cmdlets are unavailable.' } }
    $shares = @(Get-SmbShare -ErrorAction Stop | Where-Object { $_.Name -notmatch '\$$' })
    return [pscustomobject][ordered]@{ available = $true; includeAdministrativeShares = $false; shares = @($shares | ForEach-Object { [pscustomobject][ordered]@{ name = $_.Name; path = $_.Path; description = $_.Description; scopeName = $_.ScopeName; encryptData = $_.EncryptData; continuouslyAvailable = $_.ContinuouslyAvailable } }); message = $null }
}

function Get-ScheduledTaskState {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return @() }
    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' })
    return @($tasks | ForEach-Object {
        $info = Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue
        [pscustomobject][ordered]@{ taskName = $_.TaskName; taskPath = $_.TaskPath; state = $_.State.ToString(); author = $_.Author; description = $_.Description; principalUserId = $_.Principal.UserId; runLevel = $_.Principal.RunLevel.ToString(); lastRunTime = if ($info) { $info.LastRunTime.ToString('o') } else { $null }; nextRunTime = if ($info) { $info.NextRunTime.ToString('o') } else { $null }; actions = @($_.Actions | ForEach-Object { [pscustomobject][ordered]@{ execute = $_.Execute; workingDirectory = $_.WorkingDirectory } }) }
    })
}

function Get-ListeningPortState {
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return @() }
    $connections = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    return @($connections | ForEach-Object {
        $process = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        $processPath = $null
        if ($process) { try { $processPath = $process.Path } catch { $processPath = $null } }
        [pscustomobject][ordered]@{ localAddress = $_.LocalAddress; localPort = [int]$_.LocalPort; state = $_.State.ToString(); owningProcessId = [int]$_.OwningProcess; processName = if ($process) { $process.ProcessName } else { $null }; processPath = $processPath }
    })
}

function Get-EventBaseline {
    $start = (Get-Date).AddHours(-$EventLookbackHours)
    $events = New-Object System.Collections.ArrayList
    foreach ($logName in @('System', 'Application')) {
        try {
            foreach ($eventRecord in @(Get-WinEvent -FilterHashtable @{ LogName = $logName; Level = 1, 2; StartTime = $start } -MaxEvents 500 -ErrorAction Stop)) {
                [void]$events.Add([pscustomobject][ordered]@{ logName = $logName; timeCreated = $eventRecord.TimeCreated.ToUniversalTime().ToString('o'); eventId = [int]$eventRecord.Id; provider = $eventRecord.ProviderName; level = $eventRecord.LevelDisplayName; message = (Redact-SensitiveText (($eventRecord.Message -replace '\s+', ' ').Trim())) })
            }
        } catch { [void]$script:EventLogCaptureWarnings.Add(('{0}: {1}' -f $logName, (Redact-SensitiveText $_.Exception.Message))) }
    }
    return @($events | Sort-Object timeCreated -Descending | Select-Object -Unique logName, eventId, provider, timeCreated, message)
}

function Get-NetworkCapture {
    $adapters = @(Get-ActiveAdapters)
    return [ordered]@{ schemaVersion = $SchemaVersion; capturedAtUtc = [DateTime]::UtcNow.ToString('o'); activeAdapterCount = $adapters.Count; activeAdapters = $adapters; ipv4Routes = @(Get-StructuredRoutes); rawOutputFiles = @($IpConfigPath, $RoutePath, $ArpPath) }
}

function Write-TextReport {
    $lines = @('Pre-migration state capture', ('Schema version: ' + $SchemaVersion), ('Captured UTC: ' + $script:Capture.capturedAtUtc), ('Computer: ' + $script:Capture.systemIdentity.computerName), '', 'Safety results:')
    foreach ($result in $script:Results) { $lines += "[$($result.state)] $($result.name): $($result.summary)" }
    $lines += ''; $lines += 'Output files:'; $lines += $StateJsonPath; $lines += $NetworkJsonPath; $lines += $RoutePath; $lines += $IpConfigPath; $lines += $ArpPath
    $lines | Set-Content -Path $StateTextPath -Encoding UTF8
}

function Write-CaptureFiles {
    $script:Capture | ConvertTo-Json -Depth 15 | Set-Content -Path $StateJsonPath -Encoding UTF8
    $script:Capture.network | ConvertTo-Json -Depth 12 | Set-Content -Path $NetworkJsonPath -Encoding UTF8
    Write-TextReport
}

try {
    New-Item -ItemType Directory -Path $StatePath -Force | Out-Null
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    if (Test-Path $LogPath) { Move-Item -Path $LogPath -Destination (Join-Path $LogDirectory ('ExportMigrationState_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))) -Force }
    $script:LogWriter = New-Object System.IO.StreamWriter($LogPath, $false, [Text.Encoding]::UTF8)
    try { Start-Transcript -Path $TranscriptPath -Append -ErrorAction Stop | Out-Null; $script:TranscriptStarted = $true } catch { Write-Log "Transcript unavailable: $($_.Exception.Message)" ([ConsoleColor]::Yellow) }
    Write-Log "Starting pre-migration state capture version $ScriptVersion." ([ConsoleColor]::Cyan)

    if (-not (Test-Administrator)) { Write-Log 'Capture blocked: not elevated.' ([ConsoleColor]::Red); exit 10 }
    if (-not (Test-MountedMediaSafety)) { Write-Log 'Capture blocked: mounted media detected or safety check failed.' ([ConsoleColor]::Red); exit 20 }

    $activeAdapters = @(Get-ActiveAdapters)
    if ($activeAdapters.Count -gt 1) {
        $details = @($activeAdapters | ForEach-Object { "Name=$($_.adapterName), Description=$($_.interfaceDescription), IfIndex=$($_.interfaceIndex), MAC=$($_.macAddress), IP=$((@($_.ipv4Addresses | ForEach-Object address)) -join ', '), Gateway=$($_.defaultGateways -join ', ')" })
        Add-Result 'Active network adapter' 'FAIL' "$($activeAdapters.Count) active adapters detected. Manual network handling is required; automatic capture stopped." $details
        exit 30
    }
    if ($activeAdapters.Count -eq 0) {
        Add-Result 'Active network adapter' 'FAIL' 'No active network adapter detected; automatic capture stopped.'
        exit 40
    }
    Add-Result 'Active network adapter' 'PASS' "Exactly one active adapter detected: $($activeAdapters[0].interfaceAlias)." @("$($activeAdapters[0].interfaceDescription), MAC=$($activeAdapters[0].macAddress), IfIndex=$($activeAdapters[0].interfaceIndex)")
    if ($ValidateOnly) { Write-Log 'ValidateOnly completed; no complete capture files were written.' ([ConsoleColor]::Cyan); exit 0 }

    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $script:Capture = [ordered]@{
        schemaVersion = $SchemaVersion
        scriptVersion = $ScriptVersion
        captureType = 'PreMigrationState'
        capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        sourcePlatform = 'VMware'
        systemIdentity = [ordered]@{ computerName = $env:COMPUTERNAME; domainOrWorkgroup = $computer.Domain; partOfDomain = [bool]$computer.PartOfDomain; windowsEdition = $os.Caption; windowsVersion = $os.Version; buildNumber = $os.BuildNumber; timeZone = [TimeZoneInfo]::Local.Id; lastBootTimeUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o'); captureTimestampUtc = [DateTime]::UtcNow.ToString('o'); scriptVersion = $ScriptVersion }
        network = [ordered]@{}
        disks = @()
        partitionsAndVolumes = @()
        services = [ordered]@{}
        rolesAndFeatures = [ordered]@{}
        smbShares = [ordered]@{}
        scheduledTasks = @()
        listeningPorts = @()
        eventBaseline = @()
        collectionAvailability = [ordered]@{ serverManager = [bool](Get-Module -ListAvailable -Name ServerManager); smb = [bool](Get-Command Get-SmbShare -ErrorAction SilentlyContinue); scheduledTasks = [bool](Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue); listeningPorts = [bool](Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue); bitLocker = [bool](Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) }
        captureStatus = [ordered]@{ complete = $false; warnings = @() }
        outputFiles = @($StateJsonPath, $StateTextPath, $NetworkJsonPath, $RoutePath, $IpConfigPath, $ArpPath, $LogPath, $TranscriptPath)
    }
    Invoke-CapturePart 'Network configuration' { $script:Capture.network = Get-NetworkCapture }
    Invoke-CapturePart 'Raw network outputs' { Invoke-RawNetworkCapture }
    Invoke-CapturePart 'Disk information' { $script:Capture.disks = @(Get-DiskState) }
    Invoke-CapturePart 'Partition and volume information' { $script:Capture.partitionsAndVolumes = @(Get-PartitionVolumeState) }
    Invoke-CapturePart 'Services' { $script:Capture.services = Get-ServiceState }
    Invoke-CapturePart 'Server roles and features' { $script:Capture.rolesAndFeatures = Get-RoleFeatureState }
    Invoke-CapturePart 'SMB shares' { $script:Capture.smbShares = Get-SmbShareState }
    Invoke-CapturePart 'Scheduled tasks' { $script:Capture.scheduledTasks = @(Get-ScheduledTaskState) }
    Invoke-CapturePart 'Listening ports' { $script:Capture.listeningPorts = @(Get-ListeningPortState) }
    Invoke-CapturePart 'Event log baseline' { $script:Capture.eventBaseline = @(Get-EventBaseline) }
    $warningResults = @($script:Results | Where-Object state -eq 'WARNING' | ForEach-Object { "$($_.name): $($_.summary)" })
    $warningResults += @($script:EventLogCaptureWarnings)
    foreach ($collectionName in @('smb', 'scheduledTasks', 'listeningPorts', 'bitLocker')) {
        if (-not $script:Capture.collectionAvailability[$collectionName]) { $warningResults += "Collection unavailable: $collectionName" }
    }
    $script:Capture.captureStatus = [ordered]@{ complete = ($warningResults.Count -eq 0); warnings = @($warningResults) }
    Write-CaptureFiles
    $warningCount = $warningResults.Count
    Write-Log 'Pre-migration state capture completed.' ([ConsoleColor]::Green)
    Write-Log "Output paths: $StateJsonPath, $StateTextPath, $NetworkJsonPath, $RoutePath, $IpConfigPath, $ArpPath, $LogPath" ([ConsoleColor]::Cyan)
    if ($warningCount -gt 0) { Write-Log "Capture completed with $warningCount non-critical warning(s)." ([ConsoleColor]::Yellow); exit 50 }
    exit 0
} catch {
    try {
        Write-Log "Unexpected error: $($_.Exception.Message)" ([ConsoleColor]::Red)
        Add-Result 'Script execution' 'NOT_CHECKED' 'An unexpected error stopped the capture.' -FailureMessage $_.Exception.Message
    } catch { }
    exit 99
} finally {
    if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    if ($script:LogWriter) { $script:LogWriter.Dispose() }
}
