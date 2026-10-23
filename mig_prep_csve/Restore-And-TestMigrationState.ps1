<#
.SYNOPSIS
    Restores and validates migration state after a VMware-to-Proxmox Veeam restore.

.DESCRIPTION
    Reads Export-MigrationState.ps1 output, safely maps former VMware NICs to
    target adapters by preserved MACs or an explicit mapping, optionally restores IPv4/DNS/routes, optionally removes clearly
    identified non-present VMware adapters, optionally repairs offline disks, and
    compares current state with the capture after Firstboot completion. Networking and disk state are never
    changed in ValidateOnly or CompareOnly mode. Every modifying operation is guarded
    by ShouldProcess and therefore supports -WhatIf and -Confirm.

.PARAMETER StateDirectory
    Directory containing PreMigrationState.json and NetworkConfiguration.json.

.PARAMETER Mode
    ValidateOnly (default), ApplyNetwork, CompareOnly, Full, or VmwareUninstall.

.PARAMETER AdapterMappingPath
    Optional JSON mapping every captured source MAC to a target MAC. Without it,
    preserved MACs are matched automatically. Adapter order is never used.

.PARAMETER Force
    Allows validation to continue when the captured computer name differs from the
    current computer name. It does not bypass ambiguous adapter mapping.

.PARAMETER DnsTestHost
    Hostname used for DNS validation. Default is the current domain when available,
    otherwise example.com. No network configuration is changed by this test.

.PARAMETER ApplicationConfigPath
    Optional JSON containing application port objects such as:
    { "tcpPorts": [443, 8443] }

.PARAMETER MigrationTimestamp
    Optional local or ISO timestamp from which post-migration event checks begin.

.EXAMPLE
    .\Restore-And-TestMigrationState.ps1

.EXAMPLE
    .\Restore-And-TestMigrationState.ps1 -Mode ApplyNetwork -Confirm

.EXAMPLE
    .\Restore-And-TestMigrationState.ps1 -Mode CompareOnly -DnsTestHost dc01.contoso.com

.EXAMPLE
    .\Restore-And-TestMigrationState.ps1 -Mode Full -WhatIf

.NOTES
    Supported targets: Windows Server 2016, 2019, 2022, and 2025; PowerShell 5.1+.
    Expected hardware changes are reported as EXPECTED_CHANGE, not failures.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$StateDirectory = '',
    [string]$AdapterMappingPath = '',
    [ValidateSet('ValidateOnly', 'ApplyNetwork', 'CompareOnly', 'Full', 'VmwareUninstall')]
    [string]$Mode = 'ValidateOnly',
    [switch]$Force,
    [string]$DnsTestHost = '',
    [string]$ApplicationConfigPath = '',
    [datetime]$MigrationTimestamp,
    [switch]$DeepScan,
    [switch]$FirstbootNotUsed,
    [switch]$RepairOfflineDisks,
    [switch]$RemoveHiddenVMwareAdapters
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Migration.Common.ps1')

function New-MigrationPath {
    param([string]$ScriptName)
    $datestamp = (Get-Date).ToString('yyyy-MM-dd')
    $baseFolder = "C:\Rutin_migration_$datestamp\$ScriptName"
    if (-not (Test-Path $baseFolder)) {
        if (-not $WhatIfPreference) { New-Item -ItemType Directory -Path $baseFolder -Force | Out-Null }
        return $baseFolder
    }
    $final = $baseFolder
    $suffix = 1
    while (Test-Path $final) {
        $suffix++
        $timestamp = (Get-Date).ToString('HHmm')
        $final = "$baseFolder`_$timestamp`_$suffix"
    }
    if (-not $WhatIfPreference) { New-Item -ItemType Directory -Path $final -Force | Out-Null }
    return $final
}

$RootPath = New-MigrationPath -ScriptName 'Restore-And-TestMigrationState'
$ReportDirectory = Join-Path $RootPath 'Reports'
$LogDirectory = Join-Path $RootPath 'Logs'
$LogPath = Join-Path $LogDirectory 'PostMigrationValidation.log'

# Resolve inside the main try block so failures receive a controlled exit code.
$RequestedStateDirectory = $StateDirectory
$StateJsonPath = $null
$NetworkJsonPath = $null
$RollbackPath = Join-Path $RootPath 'PreNetworkChangeRollback.json'
$PostStatePath = Join-Path $RootPath 'PostMigrationState.json'
$ReportJsonPath = Join-Path $ReportDirectory 'PostMigrationReport.json'
$ReportHtmlPath = Join-Path $ReportDirectory 'PostMigrationReport.html'
$ReportTextPath = Join-Path $ReportDirectory 'PostMigrationReport.txt'
$SchemaVersion = '1.0'
# Fixed internal build stamp to verify which copy is deployed on a target machine.
$CodeRevision = '2026-10-23.1'
$script:LogWriter = $null
$script:Results = New-Object System.Collections.ArrayList
$script:Actions = New-Object System.Collections.ArrayList
$script:PreState = $null
$script:PreNetwork = $null
$script:CurrentNetwork = $null
$script:RollbackCreated = $false
$script:NetworkChanged = $false
$script:AdapterMappings = @()
$script:StartTime = [DateTime]::UtcNow

function Get-StateColor {
    param([string]$State)
    switch ($State) {
        'PASS' { [ConsoleColor]::Green }
        'WARNING' { [ConsoleColor]::Yellow }
        'FAIL' { [ConsoleColor]::Red }
        'EXPECTED_CHANGE' { [ConsoleColor]::Cyan }
        default { [ConsoleColor]::DarkGray }
    }
}
function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    if ($script:LogWriter) { $script:LogWriter.WriteLine($line); $script:LogWriter.Flush() }
}
function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'WARNING', 'FAIL', 'EXPECTED_CHANGE', 'NOT_CHECKED')][string]$State,
        [Parameter(Mandatory = $true)][string]$Summary,
        [object]$Details = @(),
        [string]$FailureMessage = ''
    )
    $item = [ordered]@{ name = $Name; state = $State; summary = $Summary; details = @($Details); error = $FailureMessage; checkedAtUtc = [DateTime]::UtcNow.ToString('o') }
    [void]$script:Results.Add([pscustomobject]$item)
    Write-Log ('[{0}] {1}: {2}' -f $State, $Name, $Summary) (Get-StateColor $State)
    foreach ($detail in @($Details)) { if ($null -ne $detail -and "$detail" -ne '') { Write-Log "    $detail" ([ConsoleColor]::DarkGray) } }
    if ($FailureMessage) { Write-Log "    Error: $FailureMessage" ([ConsoleColor]::Red) }
}
function Add-Action {
    param([string]$Type, [string]$State, [string]$Summary, [object]$Details = @())
    [void]$script:Actions.Add([pscustomobject][ordered]@{ type = $Type; state = $State; summary = $Summary; details = @($Details); timestampUtc = [DateTime]::UtcNow.ToString('o') })
}
function Invoke-SafePart {
    param([string]$Name, [scriptblock]$Action)
    try { & $Action } catch { Add-Result $Name 'WARNING' 'The check could not be completed; other checks continued.' -FailureMessage $_.Exception.Message }
}
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Add-Result 'Administrator' 'PASS' 'Running elevated.'; return $true }
    Add-Result 'Administrator' 'FAIL' 'Administrator privileges are required.'; return $false
}
function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path -PathType Leaf)) { throw "Required input file is missing: $Path" }
    $content = Get-Content -Path $Path -Raw -ErrorAction Stop
    if (-not $content.Trim()) { throw "Required input file is empty: $Path" }
    return ($content | ConvertFrom-Json -ErrorAction Stop)
}
function Test-InputData {
    try {
        $script:PreState = Read-JsonFile $StateJsonPath
        $script:PreNetwork = Read-JsonFile $NetworkJsonPath
        if ([string]$script:PreState.schemaVersion -ne $SchemaVersion -or [string]$script:PreNetwork.schemaVersion -ne $SchemaVersion) { throw "Unsupported SchemaVersion. Expected $SchemaVersion." }
        if (-not $script:PreState.systemIdentity -or -not $script:PreState.systemIdentity.computerName) { throw 'The pre-migration computer name is missing.' }
        Assert-MigrationNetworkCaptureComplete $script:PreNetwork
        foreach ($adapter in @($script:PreNetwork.activeAdapters)) {
            if ($adapter.dhcpEnabled -isnot [bool]) { throw 'Captured DHCP state must be a JSON boolean.' }
            foreach ($address in @($adapter.ipv4Addresses)) {
                $parsed = $null
                if (-not [Net.IPAddress]::TryParse([string]$address.address, [ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or [int]$address.prefixLength -lt 0 -or [int]$address.prefixLength -gt 32) { throw 'Invalid captured IPv4 address or prefix.' }
            }
        }
        if ($Mode -in @('Full', 'ApplyNetwork')) {
            $unsafeRoutes = @($script:PreNetwork.ipv4Routes | Where-Object {
                $_.protocol -eq 'Unknown' -or ($_.isPersistentOrStatic -and $_.store -notin @('ActiveStore', 'PersistentStore'))
            })
            if ($unsafeRoutes.Count) { throw 'Legacy capture has unclassified routes or missing persistence. Recapture with the fixed exporter, or configure networking manually and use ValidateOnly.' }
        }
        Add-Result 'Input data' 'PASS' "Loaded compatible schema $SchemaVersion from $StateDirectory." @($StateJsonPath, $NetworkJsonPath)
        return $true
    } catch { Add-Result 'Input data' 'FAIL' 'Pre-migration JSON is missing, unreadable, or incompatible.' -FailureMessage $_.Exception.Message; return $false }
}
function Test-ComputerIdentity {
    $oldName = [string]$script:PreState.systemIdentity.computerName
    if ($oldName -ieq $env:COMPUTERNAME) { Add-Result 'Computer identity' 'PASS' "Captured computer name matches $env:COMPUTERNAME."; return $true }
    if ($Force) { Add-Result 'Computer identity' 'WARNING' "Captured computer '$oldName' differs from current '$env:COMPUTERNAME'; continuing because -Force was supplied."; return $true }
    Add-Result 'Computer identity' 'FAIL' "Captured computer '$oldName' differs from current '$env:COMPUTERNAME'; automatic restoration is blocked. Use -Force only after confirming the target."; return $false
}
function Test-CaptureCompleteness {
    $captureStatus = Get-MigrationProperty $script:PreState 'captureStatus'
    if (-not $captureStatus) { Add-Result 'Capture completeness' 'NOT_CHECKED' 'The pre-migration capture does not report a captureStatus (older capture format).'; return $true }
    if ($captureStatus.complete) { Add-Result 'Capture completeness' 'PASS' 'The pre-migration capture completed without warnings.'; return $true }
    $captureWarnings = @($captureStatus.warnings)
    # Export warnings are serialized as '<check name>: <summary>'. Match the
    # originating check, not words in an unrelated planning warning's summary.
    $networkAffected = @($captureWarnings | Where-Object { $_ -match '^\s*(?:Network configuration|Raw network outputs)\s*:' })
    if (@($networkAffected).Count -gt 0 -and ($Mode -eq 'ApplyNetwork' -or $Mode -eq 'Full')) {
        Add-Result 'Capture completeness' 'FAIL' 'The pre-migration capture reported network-related warnings; automatic network restoration is blocked.' $captureWarnings
        return $false
    }
    Add-Result 'Capture completeness' 'WARNING' 'The pre-migration capture completed with non-critical warnings; review before relying on this baseline.' $captureWarnings
    return $true
}
function Get-RelevantAdapters {
    @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Name -notmatch 'Loopback|ISATAP|Teredo|Tunnel' -and $_.InterfaceDescription -notmatch 'Loopback|ISATAP|Teredo|Tunnel' })
}
function Get-AdapterVendorFamily {
    # Mirrors Export-MigrationState.ps1's classification so a VMware NIC renamed to VirtIO after
    # migration (e.g. "vmxnet3 Ethernet Adapter" -> "Red Hat VirtIO Ethernet Adapter") is recognized.
    param([AllowNull()][string]$InterfaceDescription)
    if ([string]::IsNullOrWhiteSpace($InterfaceDescription)) { return 'Unknown' }
    if ($InterfaceDescription -match 'vmxnet|VMware|PCNet') { return 'VMware' }
    if ($InterfaceDescription -match 'VirtIO|NetKVM|Red Hat') { return 'VirtIO' }
    if ($InterfaceDescription -match 'Hyper-V|Microsoft Hyper-V') { return 'Hyper-V' }
    return 'Other'
}
function Get-AdapterRecord {
    param($Adapter)
    # Snapshot errors must block a network mutation: an empty snapshot is not a
    # safe rollback baseline. A disabled NIC still normally has bound IPv4 state.
    $config = Get-NetIPConfiguration -InterfaceIndex $Adapter.ifIndex -ErrorAction Stop
    $ip = @(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.AddressState -eq 'Preferred' -or $_.PrefixOrigin -eq 'Manual' })
    $dnsClient = Get-DnsClient -InterfaceIndex $Adapter.ifIndex -ErrorAction Stop | Select-Object -First 1
    $dns = @(Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -ExpandProperty ServerAddresses)
    $ipInterface = Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
    if (-not $dnsClient -or -not $ipInterface) { throw "Cannot capture IPv4/DNS state for $($Adapter.Name)." }
    $dnsAutomatic = Get-MigrationAutomaticDns -InterfaceGuid $Adapter.InterfaceGuid
    [pscustomobject][ordered]@{
        adapterName = $Adapter.Name; interfaceAlias = $Adapter.Name; interfaceDescription = $Adapter.InterfaceDescription; adapterVendorFamily = (Get-AdapterVendorFamily $Adapter.InterfaceDescription); interfaceIndex = [int]$Adapter.ifIndex; interfaceGuid = $Adapter.InterfaceGuid; macAddress = $Adapter.MacAddress; linkSpeed = $Adapter.LinkSpeed; status = $Adapter.Status.ToString();
        dhcpEnabled = [bool]($ipInterface -and $ipInterface.Dhcp -eq 'Enabled'); ipv4Addresses = @($ip | ForEach-Object { [pscustomobject][ordered]@{ address = $_.IPAddress; prefixLength = [int]$_.PrefixLength } }); defaultGateways = @($config.IPv4DefaultGateway | Where-Object { $_ } | ForEach-Object NextHop); dnsAutomatic = $dnsAutomatic; dnsServers = @($dns); dnsSuffix = if ($dnsClient) { $dnsClient.ConnectionSpecificSuffix } else { $null }; registerThisConnectionAddress = if ($dnsClient) { $dnsClient.RegisterThisConnectionsAddress } else { $null }; useSuffixWhenRegistering = if ($dnsClient) { $dnsClient.UseSuffixWhenRegistering } else { $null }; interfaceMetric = if ($ipInterface) { [int]$ipInterface.InterfaceMetric } else { 0 }
    }
}
function Find-VirtIOAdapters {
    $pnp = @()
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) { $pnp = @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue) }
    $adapters = @(Get-RelevantAdapters)
    $records = @()
    foreach ($adapter in $adapters) {
        # Win32_PnPSignedDriver exposes DeviceID only; there is no separate PNPDeviceID property.
        $driver = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -eq $adapter.PnPDeviceID } | Select-Object -First 1)
        # Bare-property Where-Object throws on a $null pipeline item (possible during PnP re-enumeration); use scriptblock form.
        $pnpItem = $pnp | Where-Object { $_ -and $_.InstanceId -eq $adapter.PnPDeviceID } | Select-Object -First 1
        $driverProvider = if ($driver) { [string]$driver[0].DriverProviderName } else { '' }
        $driverVersion = if ($driver) { [string]$driver[0].DriverVersion } else { '' }
        $pnpFriendlyName = if ($pnpItem) { [string]$pnpItem.FriendlyName } else { '' }
        $text = "$($adapter.InterfaceDescription) $driverProvider $($adapter.PnPDeviceID) $pnpFriendlyName"
        $isVirtio = $text -match 'VirtIO|NetKVM|Red Hat|1AF4|VEN_1AF4'
        $records += [pscustomobject][ordered]@{ adapter = Get-AdapterRecord $adapter; isVirtIO = [bool]$isVirtio; driverProvider = $driverProvider; driverVersion = $driverVersion; pnpFriendlyName = $pnpFriendlyName; pnpInstanceId = $adapter.PnPDeviceID }
    }
    return @($records)
}
function Report-ManualNetworkHandling {
    $count = @($script:PreNetwork.activeAdapters).Count
    Add-Result 'Captured network adapters' 'PASS' "$count source adapter(s) captured. Every source must map uniquely before network changes; routes remain attached to their source interface."
}

function Resolve-AdapterMapping {
    $failureState = if ($Mode -in @('ApplyNetwork', 'Full')) { 'FAIL' } else { 'WARNING' }
    $sources = @(); $candidates = @()
    try {
        $sources = @($script:PreNetwork.activeAdapters | Where-Object { $_ -and $_.interfaceAlias })
        $candidates = @(Find-VirtIOAdapters | Where-Object { $_ -and $_.adapter })
        if ($sources.Count -eq 0 -or $candidates.Count -eq 0) { throw 'No source or target adapters are available.' }
        $path = [string](Get-Variable -Name AdapterMappingPath -ValueOnly -ErrorAction SilentlyContinue)
        $explicit = @()
        if ($path) {
            $document = Read-JsonFile $path
            if ([string]$document.schemaVersion -ne '1.0') { throw 'Adapter mapping schemaVersion must be 1.0.' }
            $owner = [string](Get-MigrationProperty $document 'computerName' '')
            if ($owner -and $owner -ine $script:PreState.systemIdentity.computerName) { throw 'The adapter mapping file belongs to a different captured computer.' }
            $explicit = @($document.mappings | Where-Object { $_ })
            if ($explicit.Count -ne $sources.Count) { throw 'An explicit mapping must contain exactly one entry for every captured source NIC.' }
        }
        $plan = New-Object System.Collections.ArrayList
        $usedTargets = @(); $usedSources = @(); $usedIndexes = @()
        foreach ($source in $sources) {
            $sourceMac = ''
            $sourceMacValue = [string](Get-MigrationProperty $source 'macAddress' '')
            if ($sourceMacValue) { $sourceMac = ConvertTo-MigrationMacAddress $sourceMacValue }
            if ($sources.Count -gt 1 -and -not $sourceMac) { throw 'Multi-NIC mapping requires a valid MAC on every captured source.' }
            if ($sourceMac -and $sourceMac -in $usedSources) { throw 'Captured source MAC addresses are duplicated.' }
            if ($sources.Count -gt 1) {
                if ([int]$source.interfaceIndex -le 0 -or [int]$source.interfaceIndex -in $usedIndexes) { throw 'Captured source interface indexes must be positive and unique for route ownership.' }
                $usedIndexes += [int]$source.interfaceIndex
            }
            $usedSources += $sourceMac
            $targets = @(); $method = 'Preserved MAC'
            if ($path) {
                $entries = @($explicit | Where-Object { (ConvertTo-MigrationMacAddress $_.sourceMacAddress) -eq $sourceMac })
                if ($entries.Count -ne 1) { throw "No unique explicit entry for source '$($source.interfaceAlias)'." }
                $targetMac = ConvertTo-MigrationMacAddress $entries[0].targetMacAddress
                $method = 'Explicit MAC mapping'
            } else { $targetMac = $sourceMac }
            if ($targetMac) {
                $targets = @($candidates | Where-Object {
                    $mac = [string](Get-MigrationProperty $_.adapter 'macAddress' '')
                    $mac -and (ConvertTo-MigrationMacAddress $mac) -eq $targetMac
                })
            }
            if (-not $path -and $sources.Count -eq 1 -and $candidates.Count -eq 1 -and $targets.Count -eq 0 -and $candidates[0].isVirtIO) {
                $targets = @($candidates[0]); $method = 'Unique single VirtIO adapter'
            }
            if ($targets.Count -ne 1) {
                $reason = "Cannot uniquely map source '$($source.interfaceAlias)' (MAC $sourceMacValue)."
                if (-not $path -and $targets.Count -eq 0) {
                    $reason += ' Its captured VMware MAC is absent from the detected target NICs. The old MAC may not have been copied to Proxmox; also check that the expected NIC exists and its driver is installed.'
                }
                $reason += ' Action: with the target VM shut down, set each source MAC on its corresponding Proxmox NIC and verify bridge/VLAN, then start Windows and run 3) ValidatePost again. Alternatively, supply a complete -AdapterMappingPath file. Adapter order and names are not mapping evidence.'
                throw $reason
            }
            $target = $targets[0]
            $targetIndex = [int](Get-MigrationProperty $target.adapter 'interfaceIndex' 0)
            if ($targetIndex -le 0) { throw 'Target interface indexes must be positive.' }
            $null = ConvertTo-MigrationMacAddress $target.adapter.macAddress
            if ($targetIndex -in $usedTargets) { throw 'Two source NICs would be assigned to the same target NIC.' }
            $usedTargets += $targetIndex
            [void]$plan.Add([pscustomobject]@{ source=$source; target=$target; allAdapters=$candidates; method=$method })
        }
        # Do not publish any usable plan until every source and explicit entry has been checked.
        foreach ($entry in $plan) {
            Add-Result 'Adapter mapping' 'PASS' "$($entry.source.interfaceAlias) -> $($entry.target.adapter.interfaceAlias) using $($entry.method)." @("Source interface=$($entry.source.interfaceIndex); target interface=$($entry.target.adapter.interfaceIndex)")
        }
        if ($candidates.Count -gt $plan.Count) { Add-Result 'Additional target adapters' 'WARNING' 'Unmapped target adapters will be left unchanged.' }
        return $plan.ToArray()
    } catch {
        $inventory = @('Captured source NICs:')
        foreach ($item in @($sources)) { $inventory += "  $(Get-MigrationProperty $item 'interfaceAlias' '<unknown>'): MAC=$(Get-MigrationProperty $item 'macAddress' '<unavailable>')" }
        $inventory += 'Detected target NICs:'
        foreach ($item in @($candidates)) { $inventory += "  $(Get-MigrationProperty $item.adapter 'interfaceAlias' '<unknown>'): MAC=$(Get-MigrationProperty $item.adapter 'macAddress' '<unavailable>')" }
        Add-Result 'Adapter mapping' $failureState ("[MIG-NET-001] " + $_.Exception.Message + ' No network restoration was started.') $inventory
        return $null
    }
}
function Assert-MigrationTargetIdentity {
    param($Mapping)
    $expected = $Mapping.target.adapter
    $mac = [string](Get-MigrationProperty $expected 'macAddress' '')
    if (-not $mac) { return }
    $current = Get-NetAdapter -InterfaceIndex $expected.interfaceIndex -ErrorAction Stop
    if ((ConvertTo-MigrationMacAddress $current.MacAddress) -ne (ConvertTo-MigrationMacAddress $mac)) {
        throw "Target interface $($expected.interfaceIndex) changed identity after mapping. No settings will be applied to this interface."
    }
    $guid = [string](Get-MigrationProperty $expected 'interfaceGuid' '')
    if ($guid -and ([guid]$current.InterfaceGuid) -ne ([guid]$guid)) { throw 'Target interface GUID changed after mapping.' }
}
function Get-HiddenVMwareAdapters {
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) { return @() }
    $present = @(Get-PnpDevice -Class Net -PresentOnly -ErrorAction Stop | ForEach-Object InstanceId)
    $devices = @(Get-PnpDevice -Class Net -ErrorAction Stop | Where-Object {
        $_.InstanceId -notin $present -and ($_.FriendlyName -match 'VMware|VMXNET|PCNet' -or $_.InstanceId -match 'VEN_15AD')
    })
    @($devices | ForEach-Object { [pscustomobject]@{ instanceId=$_.InstanceId; friendlyName=$_.FriendlyName; present=$false } })
}
function Invoke-DiskpartOnline {
    param([Parameter(Mandatory)][uint32]$DiskNumber)
    $scriptPath = [System.IO.Path]::GetTempFileName()
    try {
        @("select disk $DiskNumber", 'attributes disk clear readonly', 'online disk') | Set-Content -Path $scriptPath -Encoding ASCII -ErrorAction Stop
        $output = @(& diskpart.exe /s $scriptPath 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "diskpart exited with code ${LASTEXITCODE}: $($output -join ' ')" }
        return ($output -join ' ')
    }
    finally { Remove-Item -Path $scriptPath -Force -ErrorAction SilentlyContinue }
}
function Repair-OfflineDisks {
    # Data disks commonly come up Offline after a migration because of the Windows SAN policy; bring them
    # back online so subsequent disk/volume comparisons see the real, expected state.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()
    $disks = @(Get-Disk -ErrorAction Stop)
    $offline = @($disks | Where-Object { $_ -and $_.IsOffline })
    $details = @($offline | ForEach-Object { "Disk $($_.Number): '$($_.FriendlyName)', sizeGB=$([math]::Round($_.Size / 1GB, 2)), readOnly=$($_.IsReadOnly)" })
    if ($offline.Count -eq 0) { Add-Result 'Disk online state' 'PASS' 'All disks are online.'; return }
    if (-not $RepairOfflineDisks -or $Mode -notin @('ApplyNetwork', 'Full')) {
        Add-Result 'Disk online state' 'WARNING' "$($offline.Count) disk(s) are offline. Review the disks, then use -RepairOfflineDisks with ApplyNetwork or Full to bring them online." $details
        return
    }
    $broughtOnline = @(); $failed = @(); $previewed = @()
    foreach ($disk in $offline) {
        if (-not $PSCmdlet.ShouldProcess("Disk $($disk.Number) ($($disk.FriendlyName))", 'Bring online')) { $previewed += $disk.Number; continue }
        try {
            $method = 'Set-Disk'
            try {
                if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false -Confirm:$false -ErrorAction Stop }
                Set-Disk -Number $disk.Number -IsOffline $false -Confirm:$false -ErrorAction Stop
            } catch {
                $setDiskError = $_.Exception.Message
                Invoke-DiskpartOnline -DiskNumber $disk.Number | Out-Null
                $method = 'diskpart fallback after Set-Disk error: ' + $setDiskError
            }
            $updatedDisk = Get-Disk -Number $disk.Number -ErrorAction Stop
            if ($updatedDisk.IsOffline) { throw 'The disk remained offline after the requested operation.' }
            $broughtOnline += $disk.Number
            Add-Action 'Disk online state' 'APPLIED' "Brought disk $($disk.Number) ('$($disk.FriendlyName)') online using $method."
        } catch {
            $message = "Disk $($disk.Number): $($_.Exception.Message)"
            $failed += $message
            Add-Action 'Disk online state' 'FAILED' "Could not bring disk $($disk.Number) online: $($_.Exception.Message)"
            Write-Log $message ([ConsoleColor]::Red)
        }
    }
    if ($failed.Count -gt 0) { Add-Result 'Disk online state' 'FAIL' "$($broughtOnline.Count) disk(s) brought online; $($failed.Count) disk(s) could not be brought online." ($details + $failed) }
    elseif ($previewed.Count -gt 0 -and $broughtOnline.Count -eq 0) { Add-Result 'Disk online state' 'WARNING' "$($previewed.Count) offline disk(s) previewed with WhatIf; no changes were made." $details }
    else { Add-Result 'Disk online state' 'PASS' "$($broughtOnline.Count) offline disk(s) were brought online." $details }
}
function Get-TargetStaticRoutes {
    param([int]$InterfaceIndex)
    $persistent = @(Get-MigrationNetRoutes -InterfaceIndex $InterfaceIndex -PolicyStore PersistentStore)
    $keys = @($persistent | ForEach-Object { "$($_.DestinationPrefix)|$($_.NextHop)" })
    $active = @(Get-MigrationNetRoutes -InterfaceIndex $InterfaceIndex -PolicyStore ActiveStore)
    $activeKeys = @($active | ForEach-Object { "$($_.DestinationPrefix)|$($_.NextHop)" })
    $active += @($persistent | Where-Object { "$($_.DestinationPrefix)|$($_.NextHop)" -notin $activeKeys })
    @($active | Where-Object {
        $store = if ("$($_.DestinationPrefix)|$($_.NextHop)" -in $keys) { 'PersistentStore' } else { 'ActiveStore' }
        (Get-MigrationRouteProtocol $_ -PolicyStore $store) -eq 'NetMgmt'
    } | ForEach-Object {
        [pscustomobject]@{ destinationPrefix = $_.DestinationPrefix; nextHop = $_.NextHop; routeMetric = [int]$_.RouteMetric; store = if ("$($_.DestinationPrefix)|$($_.NextHop)" -in $keys) { 'PersistentStore' } else { 'ActiveStore' } }
    })
}
function Save-RollbackState {
    param($Mapping)
    $snapshots = @(
        foreach ($entry in @($Mapping)) {
            Assert-MigrationTargetIdentity $entry
            [pscustomobject]@{
                sourceInterfaceIndex = $entry.source.interfaceIndex
                adapter = $entry.target.adapter
                routes = @(Get-TargetStaticRoutes -InterfaceIndex $entry.target.adapter.interfaceIndex)
            }
        }
    )
    $rollback = [ordered]@{ schemaVersion='1.1'; capturedAtUtc=[DateTime]::UtcNow.ToString('o'); computerName=$env:COMPUTERNAME; adapters=$snapshots }
    $rollback | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $RollbackPath -Encoding UTF8 -ErrorAction Stop
    $script:RollbackCreated = $true
    Add-Action 'Rollback' 'READY' "Saved all $($snapshots.Count) target adapter snapshot(s) before any network changes: $RollbackPath."
}
function Set-CapturedDnsClient {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param($Source, [int]$InterfaceIndex)
    if (-not $PSCmdlet.ShouldProcess($InterfaceIndex, 'Restore captured DNS settings')) { return }
    $dns = @($Source.dnsServers | Where-Object { $_ })
    $automatic = Get-MigrationProperty $Source 'dnsAutomatic' $false
    $dnsInterface = @(Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop)
    if ($dnsInterface.Count -ne 1) { throw 'Cannot uniquely identify the IPv4 DNS client interface.' }
    if ($automatic -or $dns.Count -eq 0) {
        Set-DnsClientServerAddress -InputObject $dnsInterface[0] -ResetServerAddresses -Confirm:$false -ErrorAction Stop
    } else {
        Set-DnsClientServerAddress -InputObject $dnsInterface[0] -ServerAddresses $dns -Confirm:$false -ErrorAction Stop
    }
    Set-DnsClient -InterfaceIndex $InterfaceIndex -ConnectionSpecificSuffix ([string]$Source.dnsSuffix) -RegisterThisConnectionsAddress ([bool]$Source.registerThisConnectionAddress) -UseSuffixWhenRegistering ([bool]$Source.useSuffixWhenRegistering) -Confirm:$false -ErrorAction Stop
}
function Restore-AdapterNetwork {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param($Mapping)
    if (-not $PSCmdlet.ShouldProcess($Mapping.target.adapter.interfaceAlias, 'Restore captured IPv4 and DNS configuration')) {
        Add-Action 'Network configuration' 'WHATIF' 'No network settings changed.'
        return
    }
    Assert-MigrationTargetIdentity $Mapping
    $target = $Mapping.target.adapter
    $source = $Mapping.source
    if (-not $source.dhcpEnabled -and @($source.ipv4Addresses).Count -eq 0) { throw 'Static source configuration has no IPv4 addresses.' }
    Enable-NetAdapter -Name $target.interfaceAlias -Confirm:$false -ErrorAction Stop | Out-Null
    if ($source.dhcpEnabled) {
        # Remove stale manually assigned IPs before requesting DHCP; preserve DHCP/WellKnown addresses.
        foreach ($address in @(Get-NetIPAddress -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -ErrorAction Stop)) {
            if ($address.PrefixOrigin -eq 'Manual') { Remove-NetIPAddress -InputObject $address -Confirm:$false -ErrorAction Stop }
        }
        Set-NetIPInterface -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -Dhcp Enabled -Confirm:$false -ErrorAction Stop
    } else {
        Set-NetIPInterface -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -Dhcp Disabled -Confirm:$false -ErrorAction Stop
        $desired = @($source.ipv4Addresses | ForEach-Object address)
        foreach ($address in @(Get-NetIPAddress -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -ErrorAction Stop)) {
            if ($address.IPAddress -notin $desired -and $address.PrefixOrigin -ne 'WellKnown') { Remove-NetIPAddress -InputObject $address -Confirm:$false -ErrorAction Stop }
        }
        foreach ($address in @($source.ipv4Addresses)) {
            $existing = @(Get-NetIPAddress -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -eq $address.address })
            if ($existing.Count -eq 0) {
                New-NetIPAddress -InterfaceIndex $target.interfaceIndex -IPAddress $address.address -PrefixLength $address.prefixLength -AddressFamily IPv4 -Confirm:$false -ErrorAction Stop | Out-Null
            } elseif ([int]$existing[0].PrefixLength -ne [int]$address.prefixLength) {
                Set-NetIPAddress -InputObject $existing[0] -PrefixLength $address.prefixLength -Confirm:$false -ErrorAction Stop | Out-Null
            }
        }
        foreach ($route in @(Get-TargetStaticRoutes -InterfaceIndex $target.interfaceIndex | Where-Object { $_.destinationPrefix -eq '0.0.0.0/0' -and $_.nextHop -notin @($source.defaultGateways | Where-Object { $_ }) })) {
            Remove-MigrationRoute -Route $route -InterfaceIndex $target.interfaceIndex
        }
        foreach ($gateway in @($source.defaultGateways | Where-Object { $_ })) {
            $captured = @($script:PreNetwork.ipv4Routes | Where-Object { $_.interfaceIndex -eq $source.interfaceIndex -and $_.isDefaultRoute -and $_.nextHop -eq $gateway } | Select-Object -First 1)
            $metric = if ($captured.Count) { [int]$captured[0].routeMetric } else { 256 }
            $store = if ($captured.Count) { Get-MigrationProperty $captured[0] 'store' 'PersistentStore' } else { 'PersistentStore' }
            Set-MigrationRoute -Route ([pscustomobject]@{ destinationPrefix = '0.0.0.0/0'; nextHop = $gateway; routeMetric = $metric; store = $store }) -InterfaceIndex $target.interfaceIndex
        }
    }
    Set-NetIPInterface -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -InterfaceMetric $source.interfaceMetric -Confirm:$false -ErrorAction Stop
    Set-CapturedDnsClient -Source $source -InterfaceIndex $target.interfaceIndex
    # DAD and link initialization may take several seconds after adding an address.
    $ready = $false
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        $nic = Get-NetAdapter -InterfaceIndex $target.interfaceIndex -ErrorAction Stop
        $addresses = @(Get-NetIPAddress -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -ErrorAction Stop)
        if (@($addresses | Where-Object AddressState -eq 'Duplicate').Count) { throw 'Windows detected a duplicate IPv4 address.' }
        $preferred = @($addresses | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object IPAddress)
        $missing = @(if (-not $source.dhcpEnabled) { $source.ipv4Addresses | Where-Object { $_.address -notin $preferred } })
        if ($nic.Status -eq 'Up' -and $preferred.Count -gt 0 -and $missing.Count -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw 'The target link and expected IPv4 addresses did not become ready within 15 seconds.' }
    $script:NetworkChanged = $true
    Add-Action 'Network configuration' 'APPLIED' "Restored IPv4/DNS configuration to $($target.interfaceAlias)."
}
function Remove-MigrationRoute {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param($Route, [int]$InterfaceIndex)
    if (-not $PSCmdlet.ShouldProcess($Route.destinationPrefix, 'Remove matching IPv4 route')) { return }
    foreach ($store in @('PersistentStore', 'ActiveStore')) {
        foreach ($existing in @(Get-MigrationNetRoutes -InterfaceIndex $InterfaceIndex -PolicyStore $store | Where-Object { $_.DestinationPrefix -eq $Route.destinationPrefix -and $_.NextHop -eq $Route.nextHop })) {
            Remove-NetRoute -InputObject $existing -Confirm:$false -ErrorAction Stop
        }
    }
}
function Set-MigrationRoute {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param($Route, [int]$InterfaceIndex)
    if (-not $PSCmdlet.ShouldProcess($Route.destinationPrefix, 'Restore captured IPv4 route')) { return }
    $store = [string](Get-MigrationProperty $Route 'store' '')
    if ($store -notin @('ActiveStore', 'PersistentStore')) { throw "Route $($Route.destinationPrefix) has no supported policy store. Recapture the source routes or configure them manually." }
    $current = @(Get-TargetStaticRoutes -InterfaceIndex $InterfaceIndex | Where-Object { $_.destinationPrefix -eq $Route.destinationPrefix -and $_.nextHop -eq $Route.nextHop })
    if ($current.Count -eq 1 -and $current[0].routeMetric -eq $Route.routeMetric -and $current[0].store -eq $store) { return }
    if ($current.Count) { Remove-MigrationRoute -Route $Route -InterfaceIndex $InterfaceIndex }
    $arguments = @{ DestinationPrefix = $Route.destinationPrefix; NextHop = $Route.nextHop; InterfaceIndex = $InterfaceIndex; RouteMetric = [int]$Route.routeMetric; AddressFamily = 'IPv4'; Confirm = $false; ErrorAction = 'Stop' }
    # New-NetRoute defaults to both ActiveStore and PersistentStore. Active-only routes must opt out.
    if ($store -eq 'ActiveStore') { $arguments.PolicyStore = 'ActiveStore' }
    New-NetRoute @arguments | Out-Null
}
function Restore-StaticRoutes {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param($Mapping)
    $routes = @($script:PreNetwork.ipv4Routes | Where-Object { $_.interfaceIndex -eq $Mapping.source.interfaceIndex -and $_.isPersistentOrStatic -and -not $_.isConnectedRoute -and -not $_.isDefaultRoute })
    foreach ($route in $routes) {
        # NextHop 0.0.0.0 is a valid on-link route. Match ownership by source NIC, not gateway.
        if ($PSCmdlet.ShouldProcess("$($route.destinationPrefix) via $($route.nextHop)", 'Restore captured static route')) {
            Set-MigrationRoute -Route $route -InterfaceIndex $Mapping.target.adapter.interfaceIndex
        }
    }
    Add-Action 'Static routes' 'COMPLETED' "Evaluated $($routes.Count) static route(s) for the mapped source adapter."
}
function Remove-HiddenVMwareAdapters {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()
    $hidden = @(Get-HiddenVMwareAdapters)
    if ($hidden.Count -eq 0) { Add-Action 'Hidden VMware adapters' 'NONE' 'No clearly identified non-present VMware adapters were found.'; return }
    $details = @($hidden | ForEach-Object { "$($_.friendlyName) [$($_.instanceId)]" })
    Add-Result 'Hidden VMware adapters' 'WARNING' "$($hidden.Count) non-present VMware adapter(s) were found and are candidates for removal." $details
    foreach ($device in $hidden) {
        $presentIds = @(Get-PnpDevice -Class Net -PresentOnly -ErrorAction Stop | ForEach-Object InstanceId)
        if ($device.instanceId -in $presentIds) { Add-Action 'Hidden VMware adapters' 'MANUAL_REVIEW' "Skipped $($device.instanceId) because it is currently present."; continue }
        if (-not (Get-Command Remove-PnpDevice -ErrorAction SilentlyContinue)) { Add-Action 'Hidden VMware adapters' 'MANUAL_REVIEW' "Remove-PnpDevice is unavailable. Manually remove $($device.friendlyName) [$($device.instanceId)] in Device Manager."; continue }
        if ($PSCmdlet.ShouldProcess($device.instanceId, "Remove non-present VMware adapter $($device.friendlyName)")) {
            try { Remove-PnpDevice -InstanceId $device.instanceId -Confirm:$false -ErrorAction Stop; Add-Action 'Hidden VMware adapters' 'REMOVED' $device.instanceId } catch { Add-Action 'Hidden VMware adapters' 'MANUAL_REVIEW' "Could not remove $($device.instanceId): $($_.Exception.Message)" }
        } else { Add-Action 'Hidden VMware adapters' 'WHATIF' "Would remove $($device.friendlyName) [$($device.instanceId)]." }
    }
    if (@($script:Actions | Where-Object { $_.type -eq 'Hidden VMware adapters' -and $_.state -eq 'MANUAL_REVIEW' }).Count) { Add-Result 'Hidden VMware adapters' 'WARNING' 'One or more hidden VMware adapters require manual review.' }
}
function Restore-RollbackAdapter {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param($Mapping)
    $rollback = Read-JsonFile $RollbackPath
    $target = $Mapping.target.adapter
    Assert-MigrationTargetIdentity $Mapping
    $snapshots = @(Get-MigrationProperty $rollback 'adapters' @())
    if ($snapshots.Count -gt 0) {
        $selected = @($snapshots | Where-Object { $_.adapter.interfaceIndex -eq $target.interfaceIndex })
        if ($selected.Count -ne 1) { throw 'Rollback snapshot does not uniquely identify the target adapter.' }
        $rollback = $selected[0]
    }
    # The original single-adapter rollback format remains readable.
    $source = $rollback.adapter
    if (-not $PSCmdlet.ShouldProcess($target.interfaceAlias, 'Restore pre-change target network configuration')) { return $false }
    Enable-NetAdapter -Name $target.interfaceAlias -Confirm:$false -ErrorAction Stop | Out-Null
    foreach ($route in @(Get-TargetStaticRoutes -InterfaceIndex $target.interfaceIndex)) { Remove-MigrationRoute -Route $route -InterfaceIndex $target.interfaceIndex }
    foreach ($address in @(Get-NetIPAddress -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.PrefixOrigin -eq 'Manual' })) {
        Remove-NetIPAddress -InputObject $address -Confirm:$false -ErrorAction Stop
    }
    $dhcp = if ($source.dhcpEnabled) { 'Enabled' } else { 'Disabled' }
    Set-NetIPInterface -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -Dhcp $dhcp -InterfaceMetric $source.interfaceMetric -Confirm:$false -ErrorAction Stop
    if (-not $source.dhcpEnabled) {
        foreach ($address in @($source.ipv4Addresses)) {
            New-NetIPAddress -InterfaceIndex $target.interfaceIndex -IPAddress $address.address -PrefixLength $address.prefixLength -AddressFamily IPv4 -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }
    Set-CapturedDnsClient -Source $source -InterfaceIndex $target.interfaceIndex
    foreach ($route in @($rollback.routes)) { Set-MigrationRoute -Route $route -InterfaceIndex $target.interfaceIndex }
    if ($source.status -eq 'Disabled') { Disable-NetAdapter -Name $target.interfaceAlias -Confirm:$false -ErrorAction Stop | Out-Null }
    return $true
}
function Get-CurrentNetworkState {
    $adapters = @(Get-RelevantAdapters | ForEach-Object { Get-AdapterRecord $_ })
    $routes = @(Get-MigrationNetRoutes | ForEach-Object {
        $adapter = Get-NetAdapter -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue
        $protocol = Get-MigrationRouteProtocol $_
        [pscustomobject][ordered]@{ destinationPrefix = $_.DestinationPrefix; nextHop = $_.NextHop; interfaceIndex = [int]$_.ifIndex; interfaceAlias = if ($adapter) { $adapter.Name } else { $null }; routeMetric = [int]$_.RouteMetric; protocol = $protocol; isDefaultRoute = $_.DestinationPrefix -eq '0.0.0.0/0'; isConnectedRoute = $protocol -eq 'Local' }
    })
    [ordered]@{ schemaVersion = $SchemaVersion; captureType = 'PostMigrationState'; capturedAtUtc = [DateTime]::UtcNow.ToString('o'); activeAdapters = @($adapters); ipv4Routes = @($routes) }
}
function Get-PostMigrationState {
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    return [ordered]@{
        schemaVersion = $SchemaVersion
        captureType = 'PostMigrationState'
        capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        systemIdentity = [ordered]@{ computerName = $env:COMPUTERNAME; domainOrWorkgroup = $computer.Domain; partOfDomain = [bool]$computer.PartOfDomain; windowsEdition = $os.Caption; windowsVersion = $os.Version; buildNumber = $os.BuildNumber; timeZone = [TimeZoneInfo]::Local.Id; lastBootTimeUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o') }
        network = $script:CurrentNetwork
        disks = @(Get-Disk -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject][ordered]@{ diskNumber = [int]$_.Number; sizeBytes = [int64]$_.Size; partitionStyle = $_.PartitionStyle.ToString(); operationalStatus = @($_.OperationalStatus | ForEach-Object ToString); healthStatus = $_.HealthStatus.ToString() } })
        runningServices = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.State -eq 'Running' } | ForEach-Object Name)
    }
}
function Compare-Values {
    param([string]$Name, [AllowNull()][object]$Expected, [AllowNull()][object]$Actual,
          [bool]$ExpectedChange = $false, [switch]$Unordered,
          [ValidateSet('WARNING', 'FAIL')][string]$MismatchState = 'WARNING')
    $before = @($Expected | Where-Object { $null -ne $_ })
    $after = @($Actual | Where-Object { $null -ne $_ })
    if ($Unordered) { $before = @($before | Sort-Object); $after = @($after | Sort-Object) }
    # -InputObject preserves empty/single/multiple arrays consistently on PowerShell 5.1.
    $left = ConvertTo-Json -InputObject $before -Compress -Depth 8
    $right = ConvertTo-Json -InputObject $after -Compress -Depth 8
    if ($left -eq $right) { Add-Result $Name 'PASS' 'Expected state matches current state.' }
    elseif ($ExpectedChange) { Add-Result $Name 'EXPECTED_CHANGE' 'Expected hardware difference after migration.' @("Before: $left", "After: $right") }
    else { Add-Result $Name $MismatchState 'Current state differs from the capture.' @("Before: $left", "After: $right") }
}
function Compare-SystemState {
    $os = Get-CimInstance Win32_OperatingSystem; $cs = Get-CimInstance Win32_ComputerSystem
    Compare-Values -Name 'Computer name' -Expected $script:PreState.systemIdentity.computerName -Actual $env:COMPUTERNAME -MismatchState FAIL
    Compare-Values -Name 'Domain membership' -Expected $script:PreState.systemIdentity.domainOrWorkgroup -Actual $cs.Domain -MismatchState FAIL
    Compare-Values -Name 'Windows edition' -Expected $script:PreState.systemIdentity.windowsEdition -Actual $os.Caption
    Compare-Values -Name 'Windows build' -Expected ([string]$script:PreState.systemIdentity.buildNumber) -Actual ([string]$os.BuildNumber)
    Compare-Values -Name 'Time zone' -Expected $script:PreState.systemIdentity.timeZone -Actual ([TimeZoneInfo]::Local.Id)
}
function Compare-NetworkState {
    $usedTargets = @()
    foreach ($source in @($script:PreNetwork.activeAdapters)) {
        $all = @($script:CurrentNetwork.activeAdapters)
        $planned = @($script:AdapterMappings | Where-Object { $_.source.interfaceIndex -eq $source.interfaceIndex })
        $targets = @()
        if ($planned.Count -eq 1) { $targets = @($all | Where-Object { $_.interfaceIndex -eq $planned[0].target.adapter.interfaceIndex }) }
        else { $targets = @($all | Where-Object { $_.interfaceIndex -notin $usedTargets -and $_.macAddress -eq $source.macAddress }) }
        if ($planned.Count -eq 0 -and $targets.Count -ne 1 -and @($script:PreNetwork.activeAdapters).Count -eq 1 -and $all.Count -eq 1) { $targets = $all }
        if ($planned.Count -eq 0 -and $targets.Count -ne 1 -and -not $source.dhcpEnabled) {
            $ips = @($source.ipv4Addresses | ForEach-Object address)
            $targets = @($all | Where-Object { $_.interfaceIndex -notin $usedTargets -and @($_.ipv4Addresses | Where-Object { $_.address -in $ips }).Count -gt 0 })
        }
        if ($targets.Count -ne 1) { Add-Result 'Network comparison' 'FAIL' "Cannot uniquely identify the target for source '$($source.interfaceAlias)'. Verify each adapter manually."; continue }
        $target = $targets[0]
        if ($planned.Count -eq 1 -and (ConvertTo-MigrationMacAddress $target.macAddress) -ne (ConvertTo-MigrationMacAddress $planned[0].target.adapter.macAddress)) {
            Add-Result 'Network comparison' 'FAIL' "Mapped target identity changed for source '$($source.interfaceAlias)'."
            continue
        }
        $usedTargets += $target.interfaceIndex
        $label = [string]$source.interfaceAlias
        Compare-Values -Name "$label DHCP mode" -Expected ([bool]$source.dhcpEnabled) -Actual ([bool]$target.dhcpEnabled) -MismatchState FAIL
        if (-not $source.dhcpEnabled) {
            $before = @($source.ipv4Addresses | ForEach-Object { "$($_.address)/$($_.prefixLength)" })
            $after = @($target.ipv4Addresses | ForEach-Object { "$($_.address)/$($_.prefixLength)" })
            Compare-Values -Name "$label IPv4/prefix" -Expected $before -Actual $after -Unordered -MismatchState FAIL
            Compare-Values -Name "$label default gateways" -Expected @($source.defaultGateways | Where-Object { $_ }) -Actual @($target.defaultGateways) -Unordered -MismatchState FAIL
        }
        $automaticDns = Get-MigrationProperty $source 'dnsAutomatic' $false
        if (-not $automaticDns) { Compare-Values -Name "$label DNS servers" -Expected @($source.dnsServers) -Actual @($target.dnsServers) -MismatchState FAIL }
        Compare-Values -Name "$label DNS suffix" -Expected ([string]$source.dnsSuffix) -Actual ([string]$target.dnsSuffix) -MismatchState FAIL
        Compare-Values -Name "$label DNS registration" -Expected @([bool]$source.registerThisConnectionAddress, [bool]$source.useSuffixWhenRegistering) -Actual @([bool]$target.registerThisConnectionAddress, [bool]$target.useSuffixWhenRegistering) -MismatchState FAIL
        Compare-Values -Name "$label MAC address" -Expected $source.macAddress -Actual $target.macAddress -ExpectedChange $true
        $expectedRoutes = @($script:PreNetwork.ipv4Routes | Where-Object { $_.interfaceIndex -eq $source.interfaceIndex -and $_.isPersistentOrStatic -and -not $_.isDefaultRoute })
        $currentRoutes = @(Get-TargetStaticRoutes -InterfaceIndex $target.interfaceIndex)
        foreach ($route in $expectedRoutes) {
            $routeMatches = @($currentRoutes | Where-Object { $_.destinationPrefix -eq $route.destinationPrefix -and $_.nextHop -eq $route.nextHop -and $_.routeMetric -eq $route.routeMetric })
            if ($routeMatches.Count -eq 0) { Add-Result "$label static route" 'FAIL' "Missing route $($route.destinationPrefix) via $($route.nextHop), metric $($route.routeMetric)." }
            elseif ($route.store -in @('ActiveStore', 'PersistentStore') -and $routeMatches[0].store -ne $route.store) { Add-Result "$label static route" 'FAIL' "Route $($route.destinationPrefix) has incorrect persistence." }
            else { Add-Result "$label static route" 'PASS' "Route $($route.destinationPrefix) matches." }
        }
        if (@($script:PreNetwork.ipv4Routes | Where-Object { $_.interfaceIndex -eq $source.interfaceIndex -and $_.protocol -eq 'Unknown' }).Count) {
            Add-Result "$label static routes" 'NOT_CHECKED' 'Legacy capture has unclassified routes. Recapture with the fixed exporter or verify static routes manually.'
        }
    }
}
function Compare-DiskState {
    $current = @(Get-Disk -ErrorAction Stop)
    $before = @($script:PreState.disks)
    if ($current.Count -lt $before.Count) { Add-Result 'Disk count' 'FAIL' "Expected at least $($before.Count) disks; found $($current.Count)." }
    else { Add-Result 'Disk count' 'PASS' "Found $($current.Count) disks for $($before.Count) captured disks." }
    # Consume matches so two equal-sized source disks cannot match one target disk.
    $used = @()
    foreach ($old in $before) {
        $match = @($current | Where-Object { $_.Number -notin $used -and [math]::Abs($_.Size - $old.sizeBytes) -lt 1MB -and [string]$_.PartitionStyle -eq [string]$old.partitionStyle } | Select-Object -First 1)
        if ($match.Count -eq 0) { Add-Result 'Disk layout' 'FAIL' "No unused target disk matches size $($old.sizeBytes) and partition style $($old.partitionStyle)." }
        else { $used += $match[0].Number; Add-Result 'Disk layout' 'PASS' "Matched source size $($old.sizeBytes) to target disk $($match[0].Number)." }
    }
    $unhealthy = @($current | Where-Object { $_.IsOffline -or $_.HealthStatus -ne 'Healthy' })
    if ($unhealthy.Count) { Add-Result 'Disk health' 'FAIL' 'One or more disks are offline or not healthy.' @($unhealthy | ForEach-Object { "Disk $($_.Number): $($_.HealthStatus), offline=$($_.IsOffline)" }) }
    else { Add-Result 'Disk health' 'PASS' 'All target disks are online and healthy.' }
}
function Test-DriveLetterAssignment {
    <#
    .SYNOPSIS
        Verifies that partitions maintain their drive letter assignments after migration.
        Matches partitions by volume label, file system, and size to handle disk reordering.
    #>
    try {
        # Get pre-migration partitions with drive letters
        $expectedPartitions = @($script:PreState.partitionsAndVolumes | Where-Object { $_.driveLetter })
        
        if ($expectedPartitions.Count -eq 0) {
            Add-Result 'Drive letter assignment' 'PASS' 'No pre-migration partitions with drive letters found.'
            return
        }
        
        # Get current partitions
        $currentPartitions = @(Get-Partition -ErrorAction SilentlyContinue | ForEach-Object {
            $volume = $null
            try { $volume = $_ | Get-Volume -ErrorAction Stop } catch { }
            [pscustomobject][ordered]@{
                partition = $_
                volume = $volume
                driveLetter = if ($volume) { $volume.DriveLetter } else { $null }
                volumeLabel = if ($volume) { $volume.FileSystemLabel } else { $null }
                fileSystem = if ($volume) { $volume.FileSystem } else { $null }
                partitionSize = $_.Size
            }
        })
        
        $driveMismatches = @()
        $unmatchedExpected = @()
        
        # Match each expected partition and verify drive letter
        foreach ($expected in $expectedPartitions) {
            # Match by: volume label (both null or same), file system, and partition size (within 1GB)
            $matched = @($currentPartitions | Where-Object {
                $_.volumeLabel -eq $expected.volumeLabel -and `
                $_.fileSystem -eq $expected.fileSystem -and `
                [math]::Abs($_.partitionSize - $expected.partitionSizeBytes) -lt 1GB
            })
            
            if ($matched.Count -eq 0) {
                $volumeLabel = if ($expected.volumeLabel) { $expected.volumeLabel } else { '(no label)' }
                $driveLtr = $expected.driveLetter
                $fileSystem = $expected.fileSystem
                $sizeGB = [math]::Round($expected.partitionSizeBytes / 1GB, 2)
                $unmatchedExpected += "$driveLtr (label='$volumeLabel', fs=$fileSystem, size=${sizeGB}GB)"
            }
            elseif ($matched.Count -eq 1) {
                # Single match found - verify drive letter
                $current = $matched[0]
                if ($current.driveLetter -ne $expected.driveLetter) {
                    $expLabel = if ($expected.volumeLabel) { $expected.volumeLabel } else { '(no label)' }
                    $currLetter = if ($current.driveLetter) { $current.driveLetter } else { '(no drive letter)' }
                    $expDriveLtr = $expected.driveLetter
                    $driveMismatches += "Volume '$expLabel' expected on drive $expDriveLtr but found on $currLetter"
                }
            }
            else {
                # Multiple matches - ambiguous
                $volumeLabel = if ($expected.volumeLabel) { $expected.volumeLabel } else { '(no label)' }
                $expDriveLtr = $expected.driveLetter
                $matchCount = $matched.Count
                $driveMismatches += "Volume '$volumeLabel' on $expDriveLtr matches $matchCount current partitions; cannot determine correct assignment."
            }
        }
        
        # Report results
        if ($driveMismatches.Count -eq 0 -and $unmatchedExpected.Count -eq 0) {
            $details = @($expectedPartitions | ForEach-Object { 
                $label = if ($_.volumeLabel) { $_.volumeLabel } else { '(no label)' }
                $driveLtr = $_.driveLetter
                $fileSystem = $_.fileSystem
                "${driveLtr}: $label ($fileSystem)"
            })
            Add-Result 'Drive letter assignment' 'PASS' 'All drive letters match pre-migration state.' $details
        }
        else {
            $allIssues = @()
            if ($driveMismatches.Count -gt 0) { $allIssues += $driveMismatches }
            if ($unmatchedExpected.Count -gt 0) { $allIssues += "Missing or unmatched partitions: $($unmatchedExpected -join '; ')" }
            Add-Result 'Drive letter assignment' 'FAIL' 'Drive letter assignment differs from pre-migration state.' $allIssues
        }
    }
    catch {
        Add-Result 'Drive letter assignment' 'NOT_CHECKED' 'Could not verify drive letter assignment.' -FailureMessage $_.Exception.Message
    }
}
function Compare-Services {
    $baseline = @(Get-MigrationProperty $script:PreState.services 'all' @())
    if ($baseline.Count -eq 0) { Add-Result 'Running services' 'NOT_CHECKED' 'The source service baseline is unavailable.'; return }
    $current = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.State -eq 'Running' } | ForEach-Object Name)
    $expected = @($baseline | Where-Object { $_.startType -eq 'Auto' -and $_.status -eq 'Running' } | ForEach-Object name)
    $vmware = @('VMTools', 'VGAuthService', 'VMVss', 'VM3DService', 'vdservice')
    $missing = @($expected | Where-Object { $_ -notin $current -and $_ -notin $vmware -and $_ -notmatch '_[0-9a-fA-F]+$' })
    # A trigger-start service that ran in the baseline is still compared; a trigger
    # registry key must not hide a newly stopped application or networking service.
    if ($missing.Count) { Add-Result 'Running services' 'WARNING' 'Automatic services that were running on the source are now stopped or missing.' $missing }
    else { Add-Result 'Running services' 'PASS' 'Previously running automatic services are running, excluding expected VMware/session service changes.' }
}
function Get-RoleFeatureState {
    if (-not (Get-Module -ListAvailable -Name ServerManager)) { return [pscustomobject][ordered]@{ installed = @(); available = $false } }
    try { Import-Module ServerManager -ErrorAction Stop; return [pscustomobject][ordered]@{ installed = @(Get-WindowsFeature -ErrorAction Stop | Where-Object { $_ -and $_.Installed } | ForEach-Object Name); available = $true } }
    catch { return [pscustomobject][ordered]@{ installed = @(); available = $false } }
}
function Get-SmbShareState {
    if (-not (Get-Command Get-SmbShare -ErrorAction SilentlyContinue)) { return [pscustomobject][ordered]@{ shares = @(); available = $false } }
    return [pscustomobject][ordered]@{ shares = @(Get-SmbShare -ErrorAction Stop | Where-Object Name -notmatch '\$$' | ForEach-Object { [pscustomobject][ordered]@{ name = $_.Name; path = $_.Path } }); available = $true }
}
function Get-ScheduledTaskState {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return @() }
    return @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
        # Principal, RunLevel, and individual actions can be $null for malformed or COM-handler tasks.
        $state = if ($_.State) { $_.State.ToString() } else { $null }
        $runLevel = if ($_.Principal -and $_.Principal.RunLevel) { $_.Principal.RunLevel.ToString() } else { $null }
        [pscustomobject][ordered]@{ taskName = $_.TaskName; taskPath = $_.TaskPath; state = $state; principalUserId = if ($_.Principal) { $_.Principal.UserId } else { $null }; runLevel = $runLevel; actions = @($_.Actions | Where-Object { $_ } | ForEach-Object { [pscustomobject][ordered]@{ execute = $_.Execute; workingDirectory = $_.WorkingDirectory } }) }
    })
}
function Get-ListeningPortState {
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return @() }
    return @(Get-NetTCPConnection -State Listen -ErrorAction Stop | ForEach-Object { $process = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; [pscustomobject][ordered]@{ localAddress = $_.LocalAddress; localPort = [int]$_.LocalPort; owningProcessId = [int]$_.OwningProcess; processName = if ($process) { $process.ProcessName } else { $null } } })
}
function Compare-Collections {
    # Roles and Features
    $currentRoles = Get-RoleFeatureState
    if (-not $script:PreState.rolesAndFeatures.available -or -not $currentRoles.available) { 
        Add-Result 'Server roles and features' 'NOT_CHECKED' 'Role comparison was unavailable on one or both sides.' 
    } else { 
        $roleBefore = @($script:PreState.rolesAndFeatures.installed | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } })
        $roleNow = @($currentRoles.installed)
        Compare-Values -Name 'Server roles and features' -Expected $roleBefore -Actual $roleNow -Unordered
    }
    
    # SMB Shares
    $currentShares = Get-SmbShareState
    if (-not $script:PreState.smbShares.available -or -not $currentShares.available) { 
        Add-Result 'SMB shares' 'NOT_CHECKED' 'SMB share comparison was unavailable on one or both sides.' 
    } else { 
        $shareBefore = @($script:PreState.smbShares.shares | ForEach-Object { "$($_.name)|$($_.path)" })
        $shareNow = @($currentShares.shares | ForEach-Object { "$($_.name)|$($_.path)" })
        Compare-Values -Name 'SMB shares' -Expected $shareBefore -Actual $shareNow -Unordered
    }
    
    # Scheduled Tasks
    $taskBefore = @($script:PreState.scheduledTasks | ForEach-Object { "$($_.taskPath)$($_.taskName)" })
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { 
        Add-Result 'Scheduled tasks' 'NOT_CHECKED' 'Scheduled-task comparison is unavailable on this server.' 
    } else { 
        $taskNow = @(Get-ScheduledTaskState | ForEach-Object { "$($_.taskPath)$($_.taskName)" })
        Compare-Values -Name 'Scheduled tasks' -Expected $taskBefore -Actual $taskNow -Unordered
    }
    
    # Listening Ports
    $portBefore = @($script:PreState.listeningPorts | ForEach-Object { '{0}:{1}' -f $_.localAddress, $_.localPort })
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { 
        Add-Result 'Listening ports' 'NOT_CHECKED' 'Listening-port comparison is unavailable on this server.' 
    } else { 
        $portNow = @(Get-ListeningPortState | ForEach-Object { '{0}:{1}' -f $_.localAddress, $_.localPort })
        Compare-Values -Name 'Listening ports' -Expected $portBefore -Actual $portNow -Unordered
    }
}
function Test-StorageControllerHealth {
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) {
        Add-Result 'Storage driver health' 'NOT_CHECKED' 'PnP cmdlets are unavailable.'
        return
    }
    try { $controllers = @(Get-PnpDevice -Class SCSIAdapter -PresentOnly -ErrorAction Stop) }
    catch { Add-Result 'Storage driver health' 'NOT_CHECKED' 'Present SCSI controller enumeration failed.' -FailureMessage $_.Exception.Message; return }
    $records = @(
        foreach ($controller in $controllers) {
            $instance = [string](Get-MigrationProperty $controller 'InstanceId' '')
            $name = [string](Get-MigrationProperty $controller 'FriendlyName' '<unnamed>')
            $status = [string](Get-MigrationProperty $controller 'Status' 'Unknown')
            $hardwareIds = @(); $problemCode = 'Unknown'; $metadataError = ''
            if (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue) {
                try {
                    $properties = @(Get-PnpDeviceProperty -InstanceId $instance -KeyName @('DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_ProblemCode') -ErrorAction Stop)
                    $hardwareIds = @($properties | Where-Object KeyName -eq 'DEVPKEY_Device_HardwareIds' | ForEach-Object Data)
                    $problem = @($properties | Where-Object KeyName -eq 'DEVPKEY_Device_ProblemCode')
                    if ($problem.Count -eq 1) { $problemCode = [string]$problem[0].Data }
                } catch { $metadataError = $_.Exception.Message }
            } else { $metadataError = 'PnP property reader unavailable.' }
            # Recognize only the exact ROOT device families/hardware IDs created
            # by our preparation helper. A similarly named PCI controller is real
            # hardware and must never be exempted by its friendly name.
            $helperKind = ''
            if ($instance -match '^ROOT\\(VIOSCSI|VIOSTOR)\\[0-9A-F]+$') { $helperKind = $Matches[1] }
            $expectedId = if ($helperKind -ieq 'VIOSCSI') { '^PCI\\VEN_1AF4&DEV_1004(?:&|$)' } else { '^PCI\\VEN_1AF4&DEV_1001(?:&|$)' }
            $isHelper = $helperKind -and $name -match 'VirtIO' -and @($hardwareIds | Where-Object { $_ -match $expectedId }).Count -gt 0
            [pscustomobject]@{ instanceId=$instance; name=$name; status=$status; problemCode=$problemCode; hardwareIds=$hardwareIds; metadataError=$metadataError; isPreparationHelper=[bool]$isHelper }
        }
    )
    $formatRecord = { "Name=$($_.name); InstanceId=$($_.instanceId); Status=$($_.status); ProblemCode=$($_.problemCode); HardwareIds=$($_.hardwareIds -join ', '); MetadataError=$($_.metadataError)" }
    $helpers = @($records | Where-Object isPreparationHelper)
    if ($helpers.Count) {
        Add-Result 'Preparation ROOT storage devices' 'WARNING' "$($helpers.Count) verified preparation helper device(s) remain. They are reported separately from hardware controllers; no device or driver was removed." @($helpers | ForEach-Object $formatRecord)
    }
    $hardware = @($records | Where-Object { -not $_.isPreparationHelper })
    $bad = @($hardware | Where-Object { $_.status -ne 'OK' -or ($_.problemCode -match '^\d+$' -and [int]$_.problemCode -ne 0) })
    if ($hardware.Count -eq 0) { Add-Result 'Storage driver health' 'NOT_CHECKED' 'No hardware SCSI controller was identified outside the verified preparation ROOT devices; verify the selected disk bus.' }
    elseif ($bad.Count) { Add-Result 'Storage driver health' 'FAIL' 'A present storage controller outside the verified preparation ROOT devices is not healthy.' @($bad | ForEach-Object $formatRecord) }
    else { Add-Result 'Storage driver health' 'PASS' 'Present storage controllers outside the verified preparation ROOT devices report OK.' @($hardware | ForEach-Object $formatRecord) }
    $unavailable = @($records | Where-Object { $_.metadataError })
    if ($unavailable.Count) { Add-Result 'Storage device metadata' 'NOT_CHECKED' 'Some device details could not be read. Unverified ROOT devices were not exempted from controller health checks.' @($unavailable | ForEach-Object $formatRecord) }
}
function Test-FilesystemAndEvents {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()
    $volumes = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })
    if ($volumes.Count -eq 0) { Add-Result 'Filesystem health' 'NOT_CHECKED' 'No drive-letter NTFS volumes were available.' }
    foreach ($volume in $volumes) {
        $drive = "$($volume.DriveLetter):"
        $text = (& fsutil.exe dirty query $drive 2>&1) -join ' '
        if ($LASTEXITCODE -ne 0) { Add-Result 'Filesystem health' 'NOT_CHECKED' "Dirty-bit query failed for $drive." @($text) }
        elseif ($text -match '(?i)\bis\s+(?:not\s+)?dirty\b') {
            $dirty = $text -notmatch '(?i)\bis\s+not\s+dirty\b'
            Add-Result 'Filesystem health' $(if ($dirty) { 'WARNING' } else { 'PASS' }) "$drive : $text"
        } else { Add-Result 'Filesystem health' 'NOT_CHECKED' "Unrecognized or localized fsutil output for $drive." @($text) }
        if ($DeepScan) {
            # chkdsk /scan may perform online repairs; do not run it in read-only or preview modes.
            if ($Mode -notin @('ApplyNetwork', 'Full')) { Add-Result 'Deep filesystem scan' 'NOT_CHECKED' 'DeepScan requires ApplyNetwork or Full.' }
            elseif ($PSCmdlet.ShouldProcess($drive, 'Run online chkdsk /scan (may perform online repairs)')) {
                $scan = (& chkdsk.exe $drive /scan 2>&1) -join ' '
                $code = $LASTEXITCODE
                Add-Result 'Deep filesystem scan' $(if ($code -eq 0) { 'PASS' } else { 'WARNING' }) "$drive chkdsk /scan exit code $code." @($scan)
            }
        }
    }
    Test-StorageControllerHealth
    $since = if ($MigrationTimestamp) { $MigrationTimestamp } else { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
    $events = @()
    foreach ($log in @('System', 'Application')) {
        try { $events += @(Get-MigrationEventErrors -LogName $log -StartTime $since) }
        catch { Add-Result 'Post-migration event logs' 'NOT_CHECKED' "Cannot read $log." -FailureMessage $_.Exception.Message }
    }
    $interesting = @($events | Where-Object { $_.ProviderName -match 'Disk|Ntfs|StorPort|volmgr|Service Control Manager|WHEA-Logger' -or $_.Message -match 'disk|NTFS|storage' } | Select-Object -First 25)
    if ($interesting.Count) { Add-Result 'Post-migration event logs' 'WARNING' 'Relevant events require review.' @($interesting | ForEach-Object { "$($_.TimeCreated): $($_.ProviderName) $($_.Id) $($_.Message)" }) }
    else { Add-Result 'Post-migration event logs' 'PASS' 'No relevant storage/filesystem errors were returned from readable logs.' }
}
function Test-Connectivity {
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $adapters = @($script:CurrentNetwork.activeAdapters | Where-Object { $_.status -eq 'Up' })
    if ($adapters.Count -eq 0) { Add-Result 'Connectivity' 'FAIL' 'No active network adapter is available.'; return }
    $hostName = if ($DnsTestHost) { $DnsTestHost } elseif ($computer.PartOfDomain) { $computer.Domain } else { '' }
    if ($hostName) {
        try { Resolve-DnsName -Name $hostName -ErrorAction Stop | Out-Null; Add-Result 'DNS connectivity' 'PASS' "Resolved $hostName." }
        catch { Add-Result 'DNS connectivity' 'FAIL' "Cannot resolve $hostName." -FailureMessage $_.Exception.Message }
    } else { Add-Result 'DNS connectivity' 'NOT_CHECKED' 'Supply -DnsTestHost for a workgroup server; no public hostname is assumed.' }
    foreach ($gateway in @($adapters | ForEach-Object defaultGateways | Sort-Object -Unique)) {
        $responded = Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue
        Add-Result 'Gateway ICMP' $(if ($responded) { 'PASS' } else { 'WARNING' }) "Gateway $gateway responded=$responded. ICMP may be filtered."
    }
    if ($computer.PartOfDomain) {
        # .NET DC discovery also works on member servers without RSAT/ActiveDirectory cmdlets.
        $domain = $null; $dc = $null
        try {
            $context = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext('Domain', $computer.Domain)
            $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($context)
            $dc = $domain.FindDomainController()
            Add-Result 'Domain controller discovery' 'PASS' "Discovered $($dc.Name)."
        } catch { Add-Result 'Domain controller discovery' 'FAIL' 'Domain controller discovery failed.' -FailureMessage $_.Exception.Message }
        finally { if ($dc) { $dc.Dispose() }; if ($domain) { $domain.Dispose() } }
    }
    if ($ApplicationConfigPath) {
        $config = Read-JsonFile $ApplicationConfigPath
        foreach ($port in @($config.tcpPorts)) {
            if ([int]$port -lt 1 -or [int]$port -gt 65535) { throw "Invalid TCP port: $port" }
            if (-not $hostName) { throw 'Application port tests require -DnsTestHost on workgroup servers.' }
            $ok = Test-NetConnection -ComputerName $hostName -Port ([int]$port) -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop
            Add-Result 'Application connectivity' $(if ($ok) { 'PASS' } else { 'FAIL' }) "TCP $hostName port $port reachable=$ok."
        }
    }
}
function Test-PostMigrationVss {
    $output = @(& vssadmin.exe list writers 2>&1)
    if ($LASTEXITCODE -ne 0) { Add-Result 'VSS writers' 'NOT_CHECKED' 'vssadmin could not enumerate writers.'; return }
    $states = @($output | Where-Object { $_ -match '(?i)State:\s*\[\d+\]' })
    if ($states.Count -eq 0) { Add-Result 'VSS writers' 'NOT_CHECKED' 'No recognizable VSS writer states returned (possibly localized output).'; return }
    $bad = @($output | Where-Object { $_ -match '(?i)State:\s*\[(?!1\])|Last error:\s*(?!No error\s*$)\S' })
    if ($bad.Count) { Add-Result 'VSS writers' 'FAIL' 'One or more writers report an unstable state or error.' $bad }
    else { Add-Result 'VSS writers' 'PASS' 'Recognized VSS writers report stable state and no error.' }
}
function Get-VMwareToolsProducts {
    $paths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    @(Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object {
        $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'VMware Tools'
    })
}
function Remove-VMwareToolsUninstall {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()
    $products = @(Get-VMwareToolsProducts)
    $service = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
    if ($products.Count -eq 0 -and -not $service) { Add-Result 'VMware Tools uninstall' 'PASS' 'VMware Tools is not installed.'; return }
    if ($products.Count -ne 1 -or $products[0].PSChildName -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
        Add-Result 'VMware Tools uninstall' 'FAIL' 'A unique MSI product code was not found. No services or registry keys were deleted; repair the installation manually.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($products[0].PSChildName, 'Uninstall VMware Tools using MSI without automatic restart')) {
        Add-Action 'VMware Tools uninstall' 'WHATIF' 'MSI uninstall was not executed.'
        return
    }
    $uninstallLog = Join-Path $LogDirectory 'vmware-tools-uninstall.log'
    $arguments = '/x {0} /qn /norestart /l*v "{1}"' -f $products[0].PSChildName, $uninstallLog
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -ErrorAction Stop
    if ($process.ExitCode -notin @(0, 3010)) {
        Add-Result 'VMware Tools uninstall' 'FAIL' "MSI uninstall failed with exit $($process.ExitCode). Product registration was preserved. See $uninstallLog."
        return
    }
    $remaining = @(Get-VMwareToolsProducts)
    $remainingService = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
    if ($process.ExitCode -eq 3010) {
        Add-Result 'VMware Tools uninstall' 'WARNING' 'MSI uninstall succeeded; a planned restart is required before final verification.'
    } elseif ($remaining.Count -gt 0 -or $remainingService) {
        Add-Result 'VMware Tools uninstall' 'WARNING' 'MSI returned success but product registration or VMTools service remains. Review the installer log.'
    } else { Add-Result 'VMware Tools uninstall' 'PASS' 'MSI uninstall succeeded; product registration and VMTools service are absent.' }
}

function Test-QemuAgentAndVMwareTools {
    if (@(Get-VMwareToolsProducts).Count -gt 0) { Add-Result 'VMware Tools presence' 'WARNING' 'VMware Tools remains installed. Review Firstboot and use the separate MSI repair mode only if needed.' }
    $agent = Get-Service -Name 'QEMU-GA', 'qemu-ga' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($agent -and $agent.Status -eq 'Running') { Add-Result 'QEMU Guest Agent' 'PASS' 'QEMU Guest Agent is installed and running.' } else { Add-Result 'QEMU Guest Agent' 'WARNING' 'QEMU Guest Agent is missing or stopped.' }
}
function Restore-Network {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param($Mapping)
    $plan = @($Mapping)
    $names = @($plan | ForEach-Object { $_.target.adapter.interfaceAlias }) -join ', '
    if (-not $PSCmdlet.ShouldProcess($names, 'Save all target snapshots and restore the complete source network plan')) {
        Add-Action 'Network restoration' 'WHATIF' 'No rollback file, network settings or devices were changed.'
        return
    }
    # All snapshots must succeed before the first adapter changes.
    Save-RollbackState $plan
    $attempted = New-Object System.Collections.ArrayList
    try {
        foreach ($entry in $plan) {
            [void]$attempted.Add($entry)
            Restore-AdapterNetwork $entry -Confirm:$false
            Restore-StaticRoutes $entry -Confirm:$false
        }
        Add-Result 'Network restoration' 'PASS' "Applied all $($plan.Count) mapped adapter configuration(s) and their routes; subsequent checks verify the result."
    } catch {
        $failure = $_.Exception.Message
        Add-Action 'Network restoration' 'FAILED' $failure
        $rollbackFailures = @()
        # Restore every attempted NIC, even if rollback of one NIC fails.
        for ($index = $attempted.Count - 1; $index -ge 0; $index--) {
            $entry = $attempted[$index]
            try {
                if (-not (Restore-RollbackAdapter $entry -Confirm:$false)) { throw 'Rollback was not applied.' }
                Add-Action 'Rollback' 'SUCCEEDED' "Restored target '$($entry.target.adapter.interfaceAlias)'."
            } catch { $rollbackFailures += "$($entry.target.adapter.interfaceAlias): $($_.Exception.Message)" }
        }
        if ($rollbackFailures.Count) {
            Add-Result 'Network restoration' 'FAIL' 'Network restoration failed and one or more target rollbacks failed. Use the complete saved snapshot from the console.' $rollbackFailures
            throw 'RESTORE_FAILED_NO_ROLLBACK'
        }
        Add-Result 'Network restoration' 'FAIL' 'Network restoration failed; all attempted target adapters were rolled back.' -FailureMessage $failure
        throw 'RESTORE_FAILED_ROLLBACK_SAVED'
    }
}
function Get-Summary {
    $counts = @{}; foreach ($state in @('PASS', 'WARNING', 'FAIL', 'EXPECTED_CHANGE', 'NOT_CHECKED')) { $counts[$state] = @($script:Results | Where-Object state -eq $state).Count }
    $status = if ($counts.FAIL -gt 0) { 'FAIL' } elseif ($counts.WARNING -gt 0 -or $counts.NOT_CHECKED -gt 0) { 'WARNING' } else { 'PASS' }
    return [ordered]@{ overallStatus = $status; counts = $counts; blockingFailures = @($script:Results | Where-Object state -eq 'FAIL' | ForEach-Object { "$($_.name): $($_.summary)" }); warnings = @($script:Results | Where-Object { $_.state -eq 'WARNING' -or $_.state -eq 'NOT_CHECKED' } | ForEach-Object { "$($_.name): $($_.summary)" }); manualActions = @($script:Actions | Where-Object { $_.state -match 'MANUAL|FAILED' } | ForEach-Object { $_.summary }) }
}
function Write-Reports {
    $summary = Get-Summary
    if ($WhatIfPreference) { Write-Log "Preview result: $($summary.overallStatus). No files were written."; return $summary }
    $report = [ordered]@{ schemaVersion = $SchemaVersion; generatedAtUtc = [DateTime]::UtcNow.ToString('o'); mode = $Mode; stateDirectory = $StateDirectory; summary = $summary; results = @($script:Results); actions = @($script:Actions); preMigrationStatePath = $StateJsonPath; postMigrationStatePath = $PostStatePath; rollbackPath = if ($script:RollbackCreated) { $RollbackPath } else { $null } }
    $report | ConvertTo-Json -Depth 15 | Set-Content -Path $ReportJsonPath -Encoding UTF8
    $html = @('<!doctype html><html><head><meta charset="utf-8"><title>Post-Migration Validation</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:2rem;color:#202124}h1{color:#174a7e}.PASS{color:#187a3d}.WARNING{color:#9a6700}.FAIL{color:#b42318}.EXPECTED_CHANGE{color:#176b87}table{border-collapse:collapse;width:100%;margin-bottom:1.5rem}th,td{border:1px solid #d0d7de;padding:.45rem;text-align:left;vertical-align:top}th{background:#eef2f6}.summary{padding:1rem;background:#f5f7fa;border-left:5px solid #174a7e}</style></head><body>'); $html += "<h1>Post-Migration Validation</h1><div class='summary'><strong>Overall result: <span class='$($summary.overallStatus)'>$($summary.overallStatus)</span></strong><br>Generated UTC: $($report.generatedAtUtc)<br>Mode: $Mode</div><h2>Summary counts</h2><table><tr><th>State</th><th>Count</th></tr>"; foreach ($key in $summary.counts.Keys) { $html += "<tr><td>$key</td><td>$($summary.counts[$key])</td></tr>" }; $html += '</table><h2>Results</h2><table><tr><th>State</th><th>Check</th><th>Summary</th><th>Details</th></tr>'; foreach ($item in $script:Results) { $html += "<tr><td class='$($item.state)'>$($item.state)</td><td>$($item.name)</td><td>$($item.summary)</td><td>$([System.Net.WebUtility]::HtmlEncode(($item.details -join '<br>')))</td></tr>" }; $html += '</table><h2>Actions and manual follow-up</h2><pre>'; $html += [System.Net.WebUtility]::HtmlEncode((@($script:Actions | ConvertTo-Json -Depth 10) -join "`r`n")); $html += '</pre></body></html>'; $html | Set-Content -Path $ReportHtmlPath -Encoding UTF8
    
    # Text report with deferred route restoration commands
    $lines = @('Post-migration validation report', "Overall result: $($summary.overallStatus)", "Generated UTC: $($report.generatedAtUtc)", '', 'Summary counts:')
    foreach ($key in $summary.counts.Keys) { $lines += ('  {0}: {1}' -f $key, $summary.counts[$key]) }
    $lines += ''
    foreach ($item in $script:Results) { $lines += "[$($item.state)] $($item.name): $($item.summary)"; foreach ($detail in $item.details) { $lines += "    $detail" } }
    $lines += ''
    $lines += 'Manual follow-up actions:'
    $lines += $(if ($summary.manualActions.Count) { $summary.manualActions } else { '  None' })
    
    $lines | Set-Content -Path $ReportTextPath -Encoding UTF8
    Write-Log "Reports: $ReportJsonPath, $ReportHtmlPath, $ReportTextPath" ([ConsoleColor]::Cyan)
    return $summary
}
try {
    if (-not $WhatIfPreference) {
        New-Item -ItemType Directory -Path $ReportDirectory, $LogDirectory -Force | Out-Null
        $script:LogWriter = New-Object System.IO.StreamWriter($LogPath, $false, [Text.Encoding]::UTF8)
    }
    Write-Log "Starting post-migration validation in $Mode mode (code revision $CodeRevision)."
    if (-not (Test-Administrator)) { $null = Write-Reports; exit 10 }
    $firstboot = Assert-MigrationFirstbootComplete -FirstbootNotUsed:$FirstbootNotUsed
    Add-Result 'Firstboot completion' 'PASS' "Firstboot status: $($firstboot.state)."
    if ($Mode -eq 'VmwareUninstall') {
        Remove-VMwareToolsUninstall
    } else {
        $StateDirectory = Resolve-MigrationStateDirectory -StateDirectory $RequestedStateDirectory
        $StateJsonPath = Join-Path $StateDirectory 'PreMigrationState.json'
        $NetworkJsonPath = Join-Path $StateDirectory 'NetworkConfiguration.json'
        if (-not (Test-InputData)) { $null = Write-Reports; exit 20 }
        if (-not (Test-CaptureCompleteness)) { $null = Write-Reports; exit 20 }
        if (-not (Test-ComputerIdentity)) { $null = Write-Reports; exit 20 }
        Report-ManualNetworkHandling
        $mappings = @(Resolve-AdapterMapping | Where-Object { $null -ne $_ })
        $script:AdapterMappings = $mappings
        # An ambiguous mapping must block every change, including optional disk repair.
        if ($Mode -in @('ApplyNetwork', 'Full') -and ($mappings.Count -eq 0 -or $mappings.Count -ne @($script:PreNetwork.activeAdapters).Count)) { $null = Write-Reports; exit 20 }
        Invoke-SafePart 'Disk online state' { Repair-OfflineDisks }
        if ($Mode -in @('ApplyNetwork', 'Full')) {
            Restore-Network $mappings
            if ($RemoveHiddenVMwareAdapters) { Remove-HiddenVMwareAdapters }
        }
        $script:CurrentNetwork = Get-CurrentNetworkState
        $postState = Get-PostMigrationState
        if (-not $WhatIfPreference) { $postState | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $PostStatePath -Encoding UTF8 }
        Invoke-SafePart 'Drive letter assignment' { Test-DriveLetterAssignment }
        Invoke-SafePart 'System state comparison' { Compare-SystemState }
        Invoke-SafePart 'Network state comparison' { Compare-NetworkState }
        Invoke-SafePart 'Disk state comparison' { Compare-DiskState }
        Invoke-SafePart 'Service comparison' { Compare-Services }
        Invoke-SafePart 'Collection comparison' { Compare-Collections }
        Invoke-SafePart 'Filesystem and event checks' { Test-FilesystemAndEvents }
        Invoke-SafePart 'Connectivity' { Test-Connectivity }
        Invoke-SafePart 'Guest agent and Tools' { Test-QemuAgentAndVMwareTools }
        Invoke-SafePart 'VSS writers' { Test-PostMigrationVss }
    }
    $summary = Write-Reports
    Write-Log "Overall result: $($summary.overallStatus)" (Get-StateColor $summary.overallStatus)
    if ($summary.overallStatus -eq 'FAIL') { exit 2 }
    if ($summary.overallStatus -eq 'WARNING') { exit 1 }
    exit 0
} catch {
    if ($_.Exception.Message -eq 'RESTORE_FAILED_ROLLBACK_SAVED') { $null = Write-Reports; exit 40 }
    if ($_.Exception.Message -eq 'RESTORE_FAILED_NO_ROLLBACK') { $null = Write-Reports; exit 41 }
    try { Add-Result 'Script execution' 'FAIL' 'Validation stopped.' -FailureMessage $_.Exception.Message; $null = Write-Reports } catch { }
    exit 99
} finally { if ($script:LogWriter) { $script:LogWriter.Dispose() } }
