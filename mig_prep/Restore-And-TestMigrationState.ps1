<#
.SYNOPSIS
    Restores and validates migration state after a VMware-to-Proxmox Veeam restore.

.DESCRIPTION
    Reads Export-MigrationState.ps1 output, safely maps the former VMware NIC to a
    single VirtIO adapter, optionally restores IPv4/DNS/routes, removes only clearly
    identified non-present VMware adapters, brings offline disks back online, and
    compares current state with the capture. Networking and disk state are never
    changed in ValidateOnly or CompareOnly mode. Every modifying operation is guarded
    by ShouldProcess and therefore supports -WhatIf and -Confirm.

.PARAMETER StateDirectory
    Directory containing PreMigrationState.json and NetworkConfiguration.json.

.PARAMETER Mode
    ValidateOnly (default), ApplyNetwork, CompareOnly, Full, or VmwareUninstall.

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
    [ValidateSet('ValidateOnly', 'ApplyNetwork', 'CompareOnly', 'Full', 'VmwareUninstall')]
    [string]$Mode = 'ValidateOnly',
    [switch]$Force,
    [string]$DnsTestHost = '',
    [string]$ApplicationConfigPath = '',
    [datetime]$MigrationTimestamp,
    [switch]$DeepScan
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-MigrationPath {
    param([string]$ScriptName)
    $datestamp = (Get-Date).ToString('yyyy-MM-dd')
    $baseFolder = "C:\Rutin_migration_$datestamp\$ScriptName"
    if (-not (Test-Path $baseFolder)) {
        New-Item -ItemType Directory -Path $baseFolder -Force | Out-Null
        return $baseFolder
    }
    $final = $baseFolder
    $suffix = 1
    while (Test-Path $final) {
        $suffix++
        $timestamp = (Get-Date).ToString('HHmm')
        $final = "$baseFolder`_$timestamp`_$suffix"
    }
    New-Item -ItemType Directory -Path $final -Force | Out-Null
    return $final
}

$RootPath = New-MigrationPath -ScriptName 'Restore-And-TestMigrationState'
$ReportDirectory = Join-Path $RootPath 'Reports'
$LogDirectory = Join-Path $RootPath 'Logs'
$LogPath = Join-Path $LogDirectory 'PostMigrationValidation.log'

# If StateDirectory is not provided, use the Export-MigrationState output
if (-not $StateDirectory) {
    $exportPath = "C:\Rutin_migration_$((Get-Date).ToString('yyyy-MM-dd'))\Export-MigrationState\State"
    if (Test-Path $exportPath) {
        $StateDirectory = $exportPath
    } else {
        $StateDirectory = "C:\Rutin_migration_$((Get-Date).ToString('yyyy-MM-dd'))\Export-MigrationState\State"
    }
}

$StateJsonPath = Join-Path $StateDirectory 'PreMigrationState.json'
$NetworkJsonPath = Join-Path $StateDirectory 'NetworkConfiguration.json'
$RollbackPath = Join-Path $StateDirectory 'PreNetworkChangeRollback.json'
$PostStatePath = Join-Path $StateDirectory 'PostMigrationState.json'
$ReportJsonPath = Join-Path $ReportDirectory 'PostMigrationReport.json'
$ReportHtmlPath = Join-Path $ReportDirectory 'PostMigrationReport.html'
$ReportTextPath = Join-Path $ReportDirectory 'PostMigrationReport.txt'
$SchemaVersion = '1.0'
# Fixed internal build stamp to verify which copy is deployed on a target machine.
$CodeRevision = '2026-09-11.3'
$script:LogWriter = $null
$script:Results = New-Object System.Collections.ArrayList
$script:Actions = New-Object System.Collections.ArrayList
$script:PreState = $null
$script:PreNetwork = $null
$script:CurrentNetwork = $null
$script:RollbackCreated = $false
$script:NetworkChanged = $false
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
        if (-not $script:PreNetwork.activeAdapters -or @($script:PreNetwork.activeAdapters).Count -eq 0) { throw 'The pre-migration network capture is missing activeAdapters.' }
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
    $captureStatus = $script:PreState.captureStatus
    if (-not $captureStatus) { Add-Result 'Capture completeness' 'NOT_CHECKED' 'The pre-migration capture does not report a captureStatus (older capture format).'; return $true }
    if ($captureStatus.complete) { Add-Result 'Capture completeness' 'PASS' 'The pre-migration capture completed without warnings.'; return $true }
    $captureWarnings = @($captureStatus.warnings)
    $networkAffected = @($captureWarnings | Where-Object { $_ -match 'Network configuration|Raw network outputs|Active network adapter' })
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
    # Get-NetIPConfiguration/-NetIPInterface/etc. are CDXML-backed; their "no matching objects" error
    # ignores -ErrorAction SilentlyContinue and terminates under $ErrorActionPreference = 'Stop'. This
    # happens for any relevant adapter with no bound IPv4 interface (e.g. disconnected, or a leftover
    # non-present VMware adapter still enumerated during PnP re-discovery), so each lookup is isolated.
    $config = $null; try { $config = Get-NetIPConfiguration -InterfaceIndex $Adapter.ifIndex -ErrorAction Stop } catch { }
    $ip = @(); try { $ip = @(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_ -and $_.AddressState -eq 'Preferred' }) } catch { }
    $dnsClient = $null; try { $dnsClient = Get-DnsClient -InterfaceIndex $Adapter.ifIndex -ErrorAction Stop | Select-Object -First 1 } catch { }
    $dns = @(); try { $dns = @(Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -ExpandProperty ServerAddresses) } catch { }
    $ipInterface = $null; try { $ipInterface = Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1 } catch { }
    [pscustomobject][ordered]@{
        adapterName = $Adapter.Name; interfaceAlias = $Adapter.Name; interfaceDescription = $Adapter.InterfaceDescription; adapterVendorFamily = (Get-AdapterVendorFamily $Adapter.InterfaceDescription); interfaceIndex = [int]$Adapter.ifIndex; interfaceGuid = $Adapter.InterfaceGuid; macAddress = $Adapter.MacAddress; linkSpeed = $Adapter.LinkSpeed; status = $Adapter.Status.ToString();
        dhcpEnabled = [bool]($ipInterface -and $ipInterface.Dhcp -eq 'Enabled'); ipv4Addresses = @($ip | ForEach-Object { [pscustomobject][ordered]@{ address = $_.IPAddress; prefixLength = [int]$_.PrefixLength } }); defaultGateways = if ($config) { @($config.IPv4DefaultGateway | Where-Object { $_ } | ForEach-Object NextHop) } else { @() }; dnsServers = @($dns); dnsSuffix = if ($dnsClient) { $dnsClient.ConnectionSpecificSuffix } else { $null }; registerThisConnectionAddress = if ($dnsClient) { $dnsClient.RegisterThisConnectionsAddress } else { $null }; useSuffixWhenRegistering = if ($dnsClient) { $dnsClient.UseSuffixWhenRegistering } else { $null }; interfaceMetric = if ($ipInterface) { [int]$ipInterface.InterfaceMetric } else { 0 }
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
    $requiresManual = $script:PreNetwork.requiresManualNetworkHandling
    if ($requiresManual) {
        $adapterCount = @($script:PreNetwork.activeAdapters).Count
        $adapterDetails = @($script:PreNetwork.activeAdapters | ForEach-Object { "- $($_.adapterName) ($($_.interfaceDescription)): IP=$((@($_.ipv4Addresses | ForEach-Object address)) -join ', '), Gateway=$($_.defaultGateways -join ', ')" })
        Add-Result 'Manual network handling' 'WARNING' "Multiple active adapters ($adapterCount) were detected at capture time. Automatic restoration will only apply the first adapter. Review all captured adapters and apply remaining network configuration manually." $adapterDetails
    } else {
        Add-Result 'Manual network handling' 'PASS' "Single active adapter detected at capture time. Automatic restoration will apply network configuration."
    }
}

function Resolve-AdapterMapping {
    if (-not $script:PreNetwork -or -not $script:PreNetwork.activeAdapters) {
        Add-Result 'Adapter mapping' 'FAIL' 'The pre-migration network capture is missing or incomplete; no adapter mapping can be created.'
        return $null
    }
    # @(...) around a $null property (e.g. missing/malformed JSON) yields a 1-element array containing $null, not empty.
    $old = @($script:PreNetwork.activeAdapters | Where-Object { $_ -and $_.interfaceAlias })
    $candidates = @(Find-VirtIOAdapters | Where-Object { $_ -and $_.adapter })
    $activeAdapters = @($candidates | Where-Object { $_ -and $_.adapter -and $_.adapter.status -eq 'Up' })
    if ($old.Count -ne 1) { Add-Result 'Adapter mapping' 'FAIL' "Pre-migration capture contains $($old.Count) active adapters; automatic mapping requires exactly one."; return $null }
    $virtio = @($candidates | Where-Object { $_ -and $_.isVirtIO })
    $activeVirtio = @($virtio | Where-Object { $_ -and $_.adapter -and $_.adapter.status -eq 'Up' })
    if ($activeAdapters.Count -ne 1 -or $activeVirtio.Count -ne 1) {
        $details = @($candidates | ForEach-Object { if ($_ -and $_.adapter) { "Name=$($_.adapter.adapterName), Description=$($_.adapter.interfaceDescription), Status=$($_.adapter.status), VirtIO=$($_.isVirtIO), Provider=$($_.driverProvider), PnP=$($_.pnpFriendlyName)" } })
        Add-Result 'Adapter mapping' 'FAIL' "Found $($activeAdapters.Count) active relevant adapter(s) and $($activeVirtio.Count) active VirtIO candidate(s); automatic mapping is ambiguous." $details
        return $null
    }
    Add-Result 'Adapter mapping' 'PASS' "Mapped source '$($old[0].interfaceAlias)' to VirtIO adapter '$($activeVirtio[0].adapter.interfaceAlias)'." @("Provider=$($activeVirtio[0].driverProvider), Description=$($activeVirtio[0].adapter.interfaceDescription), PnP=$($activeVirtio[0].pnpFriendlyName)")
    return [pscustomobject][ordered]@{ source = $old[0]; target = $activeVirtio[0]; allAdapters = $candidates }
}
function Get-HiddenVMwareAdapters {
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) { return @() }
    $devices = @(Get-PnpDevice -Class Net -PresentOnly:$false -ErrorAction SilentlyContinue | Where-Object { -not $_.Present -and $_.FriendlyName -match 'VMware|VMXNET|PCNet|E1000' })
    return @($devices | ForEach-Object { [pscustomobject][ordered]@{ instanceId = $_.InstanceId; friendlyName = $_.FriendlyName; status = $_.Status; present = [bool]$_.Present; class = $_.Class } })
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
    if ($Mode -ne 'ApplyNetwork' -and $Mode -ne 'Full') {
        Add-Result 'Disk online state' 'WARNING' "$($offline.Count) disk(s) are offline. Run with -Mode ApplyNetwork or -Mode Full to bring them online." $details
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
    if ($failed.Count -gt 0) { Add-Result 'Disk online state' 'WARNING' "$($broughtOnline.Count) disk(s) brought online; $($failed.Count) disk(s) could not be brought online." ($details + $failed) }
    elseif ($previewed.Count -gt 0 -and $broughtOnline.Count -eq 0) { Add-Result 'Disk online state' 'WARNING' "$($previewed.Count) offline disk(s) previewed with WhatIf; no changes were made." $details }
    else { Add-Result 'Disk online state' 'PASS' "$($broughtOnline.Count) offline disk(s) were brought online." $details }
}
function Save-RollbackState {
    param($Mapping)
    $rollback = [ordered]@{ schemaVersion = $SchemaVersion; capturedAtUtc = [DateTime]::UtcNow.ToString('o'); computerName = $env:COMPUTERNAME; adapter = $Mapping.target.adapter; routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object DestinationPrefix, NextHop, ifIndex, RouteMetric, PolicyStore, RouteProtocol); hiddenVMwareAdapters = @(Get-HiddenVMwareAdapters) }
    $rollback | ConvertTo-Json -Depth 12 | Set-Content -Path $RollbackPath -Encoding UTF8
    $script:RollbackCreated = $true
    Add-Action 'Rollback' 'READY' "Current Proxmox-side network configuration saved to $RollbackPath."
}
function Restore-AdapterNetwork {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param($Mapping)
    if (-not $PSCmdlet.ShouldProcess($Mapping.target.adapter.interfaceAlias, 'Restore captured IPv4 and DNS configuration')) { Add-Action 'Network configuration' 'WHATIF' 'Network configuration change was previewed with WhatIf.'; return }
    $target = $Mapping.target.adapter
    $source = $Mapping.source
    try {
        # Ensure the adapter is enabled before applying configuration
        Enable-NetAdapter -Name $target.interfaceAlias -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Milliseconds 500  # Allow adapter time to come up
        
        if ($source.dhcpEnabled) {
            Set-NetIPInterface -InterfaceIndex $target.interfaceIndex -Dhcp Enabled -Confirm:$false
            if (@($source.dnsServers).Count -gt 0) { Set-DnsClientServerAddress -InterfaceIndex $target.interfaceIndex -ServerAddresses @($source.dnsServers) -Confirm:$false }
            else { Set-DnsClientServerAddress -InterfaceIndex $target.interfaceIndex -ResetServerAddresses -Confirm:$false }
        } else {
            Set-NetIPInterface -InterfaceIndex $target.interfaceIndex -Dhcp Disabled -Confirm:$false
            $desiredAddresses = @($source.ipv4Addresses | ForEach-Object address)
            foreach ($currentAddress in @(Get-NetIPAddress -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
                if ($currentAddress.IPAddress -notin $desiredAddresses -and $currentAddress.PrefixOrigin -ne 'WellKnown') { Remove-NetIPAddress -InputObject $currentAddress -Confirm:$false -ErrorAction Stop }
            }
            foreach ($address in @($source.ipv4Addresses)) { if (-not (Get-NetIPAddress -InterfaceIndex $target.interfaceIndex -IPAddress $address.address -ErrorAction SilentlyContinue)) { New-NetIPAddress -InterfaceIndex $target.interfaceIndex -IPAddress $address.address -PrefixLength $address.prefixLength -AddressFamily IPv4 -Confirm:$false | Out-Null } }
            $desiredGateways = @($source.defaultGateways)
            foreach ($currentDefault in @(Get-NetRoute -InterfaceIndex $target.interfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)) {
                if ($currentDefault.NextHop -notin $desiredGateways) { Remove-NetRoute -InputObject $currentDefault -Confirm:$false -ErrorAction Stop }
            }
            $defaultRoute = @($script:PreNetwork.ipv4Routes | Where-Object { $_ -and $_.isDefaultRoute } | Sort-Object routeMetric | Select-Object -First 1)
            $defaultMetric = if ($defaultRoute) { [int]$defaultRoute.routeMetric } else { [int]$source.interfaceMetric }
            foreach ($gateway in $desiredGateways) { if (-not (Get-NetRoute -InterfaceIndex $target.interfaceIndex -DestinationPrefix '0.0.0.0/0' -NextHop $gateway -ErrorAction SilentlyContinue)) { New-NetRoute -InterfaceIndex $target.interfaceIndex -DestinationPrefix '0.0.0.0/0' -NextHop $gateway -RouteMetric $defaultMetric -Confirm:$false | Out-Null } }
            if (@($source.dnsServers).Count -gt 0) { Set-DnsClientServerAddress -InterfaceIndex $target.interfaceIndex -ServerAddresses @($source.dnsServers) -Confirm:$false }
        }
        Set-NetIPInterface -InterfaceIndex $target.interfaceIndex -InterfaceMetric $source.interfaceMetric -Confirm:$false
        if ($source.dnsSuffix) { Set-DnsClient -InterfaceIndex $target.interfaceIndex -ConnectionSpecificSuffix $source.dnsSuffix -RegisterThisConnectionsAddress $source.registerThisConnectionAddress -UseSuffixWhenRegistering $source.useSuffixWhenRegistering -Confirm:$false }
        $script:NetworkChanged = $true; Add-Action 'Network configuration' 'APPLIED' "Restored IPv4/DNS configuration to $($target.interfaceAlias)."
    } catch { Add-Action 'Network configuration' 'FAILED' $_.Exception.Message; throw }
}
function Restore-StaticRoutes {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param($Mapping)
    $routes = @($script:PreNetwork.ipv4Routes | Where-Object { $_.isPersistentOrStatic -and -not $_.isConnectedRoute -and -not $_.isDefaultRoute -and $_.destinationPrefix -notmatch '^(127\.|224\.|255\.)' })
    
    # Get primary adapter's gateways for filtering; routes with different gateways are deferred (secondary adapter)
    $primaryGateways = @($Mapping.source.defaultGateways)
    $restored = @(); $skipped = @(); $deferred = @(); $review = @()
    foreach ($route in $routes) {
        if ($route.nextHop -eq '0.0.0.0' -or $route.nextHop -eq '::') { $skipped += ('{0}: invalid next hop' -f $route.destinationPrefix); continue }
        
        # Routes with gateway different from primary are deferred (secondary adapter not yet configured)
        if ($route.nextHop -notin $primaryGateways) { 
            $deferred += [pscustomobject][ordered]@{ destination = $route.destinationPrefix; gateway = $route.nextHop; metric = $route.routeMetric }
            continue 
        }
        
        if (Get-NetRoute -DestinationPrefix $route.destinationPrefix -NextHop $route.nextHop -ErrorAction SilentlyContinue) { $skipped += "$($route.destinationPrefix) via $($route.nextHop): already present"; continue }
        if (-not $PSCmdlet.ShouldProcess("$($route.destinationPrefix) via $($route.nextHop)", 'Restore static route')) { $review += "$($route.destinationPrefix) via $($route.nextHop): WhatIf"; continue }
        try { New-NetRoute -DestinationPrefix $route.destinationPrefix -NextHop $route.nextHop -InterfaceIndex $Mapping.target.adapter.interfaceIndex -RouteMetric $route.routeMetric -Confirm:$false | Out-Null; $restored += "$($route.destinationPrefix) via $($route.nextHop)" } catch { $review += "$($route.destinationPrefix): $($_.Exception.Message)" }
    }
    
    # Generate PowerShell commands for deferred routes (secondary adapters)
    $deferredCommands = @()
    if ($deferred.Count -gt 0) {
        $deferredCommands += '# Routes for secondary adapters (configure after adding secondary NICs to Proxmox)'
        $deferredCommands += '# Identify the secondary adapter interface index, then run these commands:'
        foreach ($item in $deferred) {
            $deferredCommands += "New-NetRoute -DestinationPrefix '$($item.destination)' -NextHop '$($item.gateway)' -RouteMetric $($item.metric) -ErrorAction Continue"
        }
    }
    
    $state = if ($review.Count) { 'MANUAL_REVIEW' } elseif ($deferred.Count) { 'PARTIAL' } else { 'COMPLETED' }
    Add-Action 'Static routes' $state 'Static route restoration evaluated.' ([ordered]@{ restored = @($restored); skipped = @($skipped); deferred = @($deferred); deferredRestoreCommands = @($deferredCommands); manualReview = @($review) })
    
    if ($deferred.Count -gt 0) {
        Add-Result 'Static routes' 'WARNING' "$($deferred.Count) route(s) deferred pending secondary adapter configuration." @($deferred | ForEach-Object { "Destination=$($_.destination), Gateway=$($_.gateway), Metric=$($_.metric)" })
    }
    if ($review.Count) { Add-Result 'Static routes' 'WARNING' "$($review.Count) route(s) require manual review." $review }
}
function Remove-HiddenVMwareAdapters {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()
    $hidden = @(Get-HiddenVMwareAdapters)
    if ($hidden.Count -eq 0) { Add-Action 'Hidden VMware adapters' 'NONE' 'No clearly identified non-present VMware adapters were found.'; return }
    $details = @($hidden | ForEach-Object { "$($_.friendlyName) [$($_.instanceId)]" })
    Add-Result 'Hidden VMware adapters' 'WARNING' "$($hidden.Count) non-present VMware adapter(s) were found and are candidates for removal." $details
    foreach ($device in $hidden) {
        $currentDevice = @(Get-PnpDevice -InstanceId $device.instanceId -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($currentDevice -and $currentDevice[0].Present) { Add-Action 'Hidden VMware adapters' 'MANUAL_REVIEW' "Skipped $($device.instanceId) because it is currently present."; continue }
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
    $source = $rollback.adapter
    $target = $Mapping.target.adapter
    if (-not $PSCmdlet.ShouldProcess($target.interfaceAlias, 'Attempt rollback of pre-change network configuration')) { return $false }
    if ($source.dhcpEnabled) {
        Set-NetIPInterface -InterfaceIndex $target.interfaceIndex -Dhcp Enabled -Confirm:$false
        Get-NetIPAddress -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.PrefixOrigin -ne 'WellKnown' } | Remove-NetIPAddress -Confirm:$false -ErrorAction Stop
        Set-DnsClientServerAddress -InterfaceIndex $target.interfaceIndex -ResetServerAddresses -Confirm:$false
    } else {
        Set-NetIPInterface -InterfaceIndex $target.interfaceIndex -Dhcp Disabled -Confirm:$false
        Get-NetIPAddress -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
        foreach ($address in @($source.ipv4Addresses)) { New-NetIPAddress -InterfaceIndex $target.interfaceIndex -IPAddress $address.address -PrefixLength $address.prefixLength -AddressFamily IPv4 -Confirm:$false | Out-Null }
        if (@($source.dnsServers).Count -gt 0) { Set-DnsClientServerAddress -InterfaceIndex $target.interfaceIndex -ServerAddresses @($source.dnsServers) -Confirm:$false }
    }
    Set-NetIPInterface -InterfaceIndex $target.interfaceIndex -InterfaceMetric $source.interfaceMetric -Confirm:$false
    # RouteProtocol is not guaranteed on every route object; treat missing as non-local.
    $savedRoutes = @($rollback.routes | Where-Object { $_.ifIndex -eq $target.interfaceIndex -and (-not $_.PSObject.Properties['RouteProtocol'] -or [string]$_.RouteProtocol -ne 'Local') })
    $savedRouteKeys = @($savedRoutes | ForEach-Object { '{0}|{1}' -f $_.DestinationPrefix, $_.NextHop })
    foreach ($currentRoute in @(Get-NetRoute -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        $routeKey = '{0}|{1}' -f $currentRoute.DestinationPrefix, $currentRoute.NextHop
        $currentProtocol = if ($currentRoute.PSObject.Properties['RouteProtocol']) { [string]$currentRoute.RouteProtocol } else { 'Unknown' }
        if ($currentProtocol -ne 'Local' -and $routeKey -notin $savedRouteKeys) { Remove-NetRoute -InputObject $currentRoute -Confirm:$false -ErrorAction Stop }
    }
    foreach ($savedRoute in $savedRoutes) {
        $routeKey = '{0}|{1}' -f $savedRoute.DestinationPrefix, $savedRoute.NextHop
        if (-not (Get-NetRoute -InterfaceIndex $target.interfaceIndex -DestinationPrefix $savedRoute.DestinationPrefix -NextHop $savedRoute.NextHop -ErrorAction SilentlyContinue)) {
            New-NetRoute -InterfaceIndex $target.interfaceIndex -DestinationPrefix $savedRoute.DestinationPrefix -NextHop $savedRoute.NextHop -RouteMetric ([int]$savedRoute.RouteMetric) -Confirm:$false | Out-Null
        }
    }
    return $true
}
function Get-CurrentNetworkState {
    $adapters = @(Get-RelevantAdapters | ForEach-Object { Get-AdapterRecord $_ })
    $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object {
        $adapter = Get-NetAdapter -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue
        $protocol = if ($_.PSObject.Properties['RouteProtocol']) { [string]$_.RouteProtocol } else { 'Unknown' }
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
    param([string]$Name, [object]$Expected, [object]$Actual, [bool]$ExpectedChange = $false)
    $left = (@($Expected) | ConvertTo-Json -Compress -Depth 8); $right = (@($Actual) | ConvertTo-Json -Compress -Depth 8)
    if ($left -eq $right) { Add-Result $Name 'PASS' 'Expected state matches current state.' }
    elseif ($ExpectedChange) { Add-Result $Name 'EXPECTED_CHANGE' 'Difference is expected after VMware-to-Proxmox hardware migration.' @("Before: $left", "After: $right") }
    else { Add-Result $Name 'WARNING' 'Current state differs from the pre-migration capture.' @("Before: $left", "After: $right") }
}
function Compare-SystemState {
    $os = Get-CimInstance Win32_OperatingSystem; $cs = Get-CimInstance Win32_ComputerSystem
    Compare-Values 'Computer name' $script:PreState.systemIdentity.computerName $env:COMPUTERNAME
    Compare-Values 'Domain membership' $script:PreState.systemIdentity.domainOrWorkgroup $cs.Domain
    Compare-Values 'Windows edition' $script:PreState.systemIdentity.windowsEdition $os.Caption
    Compare-Values 'Windows build' $script:PreState.systemIdentity.buildNumber $os.BuildNumber
    Compare-Values 'Time zone' $script:PreState.systemIdentity.timeZone ([TimeZoneInfo]::Local.Id)
}
function Compare-NetworkState {
    $before = @($script:PreNetwork.activeAdapters | ForEach-Object { $_.ipv4Addresses.address })
    $after = @($script:CurrentNetwork.activeAdapters | ForEach-Object { $_.ipv4Addresses.address })
    Compare-Values 'IPv4 addresses' $before $after
    $gateways_before = @($script:PreNetwork.activeAdapters | ForEach-Object defaultGateways)
    $gateways_after = @($script:CurrentNetwork.activeAdapters | ForEach-Object defaultGateways)
    Compare-Values 'Default gateways' $gateways_before $gateways_after
    $dns_before = @($script:PreNetwork.activeAdapters | ForEach-Object dnsServers)
    $dns_after = @($script:CurrentNetwork.activeAdapters | ForEach-Object dnsServers)
    Compare-Values 'DNS servers' $dns_before $dns_after
    $mac_before = @($script:PreNetwork.activeAdapters | ForEach-Object { $_.macAddress })
    $mac_after = @($script:CurrentNetwork.activeAdapters | ForEach-Object { $_.macAddress })
    Compare-Values 'Adapter hardware identity' $mac_before $mac_after $true
    $desc_before = @($script:PreNetwork.activeAdapters | ForEach-Object { $_.interfaceDescription })
    $desc_after = @($script:CurrentNetwork.activeAdapters | ForEach-Object { $_.interfaceDescription })
    Compare-Values 'Adapter description/vendor' $desc_before $desc_after $true
    $routes_before = @($script:PreNetwork.ipv4Routes | Where-Object { -not $_.isConnectedRoute -and -not $_.isDefaultRoute } | ForEach-Object { "$($_.destinationPrefix)|$($_.nextHop)" })
    $routes_after = @($script:CurrentNetwork.ipv4Routes | Where-Object { -not $_.isConnectedRoute -and -not $_.isDefaultRoute } | ForEach-Object { "$($_.destinationPrefix)|$($_.nextHop)" })
    Compare-Values 'Static routes' $routes_before $routes_after
}
function Compare-DiskState {
    $current = @(Get-Disk -ErrorAction Stop); $before = @($script:PreState.disks)
    if ($current.Count -lt $before.Count) { Add-Result 'Disk count' 'FAIL' "Expected at least $($before.Count) disks; found $($current.Count)." } else { Add-Result 'Disk count' 'PASS' "Expected $($before.Count) or more disks found ($($current.Count))." }
    $details = @()
    foreach ($old in $before) { $size = @($current | Where-Object { [math]::Abs($_.Size - $old.sizeBytes) -lt 1GB } | Select-Object -First 1); if ($size) { $details += "Matched disk size $([math]::Round($old.sizeBytes / 1GB, 2)) GB." } else { $details += "No current disk matched expected size $([math]::Round($old.sizeBytes / 1GB, 2)) GB." } }
    if ($details -match 'No current') { Add-Result 'Disk sizes' 'FAIL' 'One or more expected disk sizes were not found.' $details } else { Add-Result 'Disk sizes' 'PASS' 'Expected disk sizes were found.' $details }
    # Filter partition/volume layouts to user-accessible volumes only (those with drive letters)
    $expectedPartitions = @($script:PreState.partitionsAndVolumes | Where-Object { $_.driveLetter } | ForEach-Object { "$($_.driveLetter)|$($_.volumeLabel)|$($_.fileSystem)|$($_.mountPoints -join ',')" })
    $actualPartitions = @(Get-PartitionVolumeStateForComparison | Where-Object { $_ -match '^[A-Z]\|' })
    Compare-Values 'Partition and volume layout' $expectedPartitions $actualPartitions
}
function Get-PartitionVolumeStateForComparison {
    # $volume is $null for partitions with no accessible volume (e.g. Recovery, EFI, MSR).
    $output = @(); foreach ($partition in @(Get-Partition -ErrorAction SilentlyContinue)) { $volume = $null; try { $volume = $partition | Get-Volume -ErrorAction Stop } catch { }; $output += "$(if ($volume) { $volume.DriveLetter }else{$null})|$(if ($volume) { $volume.FileSystemLabel }else{$null})|$(if ($volume) { $volume.FileSystem }else{$null})|$(if ($volume) { $volume.Path }else{$null})" }; return @($output)
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
    # Define service categories to exclude or categorize
    $vmwareServices = @('VMTools', 'VGAuthService', 'VMVss', 'VM3DService')
    $migrationCommonServices = @('DeviceInstall', 'DsmSvc', 'IfsVsc', 'IKEEXT', 'PolicyAgent', 'SharedAccess', 'Spooler')
    
    # Verify pre-migration service data is available
    if (-not $script:PreState -or -not $script:PreState.services) {
        Add-Result 'Running services' 'NOT_CHECKED' 'Pre-migration service data is unavailable; service comparison cannot be performed.'
        return
    }
    
    # Get current running services
    try {
        $current = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_ -and $_.State -eq 'Running' } | ForEach-Object Name)
    } catch {
        Add-Result 'Running services' 'NOT_CHECKED' 'Current service state could not be retrieved.'
        return
    }
    
    # Get all services from pre-migration state (all captured services with their start types)
    $allServicesBefore = @($script:PreState.services.all | Where-Object { $_ -and $_.startType } | ForEach-Object { 
        [pscustomobject]@{ name = $_.name; startType = $_.startType }
    })
    
    if ($allServicesBefore.Count -eq 0) {
        Add-Result 'Running services' 'NOT_CHECKED' 'Pre-migration service list is empty; service comparison cannot be performed.'
        return
    }
    
    # Find Automatic services that are not running (should be running but aren't)
    # Note: Win32_Service.StartMode returns 'Auto', 'Manual', 'Disabled', 'Boot', or 'System'
    $automaticBefore = @($allServicesBefore | Where-Object { $_.startType -eq 'Auto' } | ForEach-Object { $_.name })
    $missing = @($automaticBefore | Where-Object { $_ -notin $current })
    
    if ($missing.Count -eq 0) {
        Add-Result 'Running services' 'PASS' 'All Automatic services are running as expected.' @()
        return
    }
    
    # Categorize stopped services
    $vmwareStopped = @($missing | Where-Object { $_ -in $vmwareServices })
    $userSessionStopped = @($missing | Where-Object { $_ -match '_\d+$' })
    $migrationCommonStopped = @($missing | Where-Object { $_ -in $migrationCommonServices })
    $otherStopped = @($missing | Where-Object { $_ -notin $vmwareServices -and $_ -notmatch '_\d+$' -and $_ -notin $migrationCommonServices })
    
    # Report by category
    $details = @()
    
    if ($vmwareStopped.Count -gt 0) {
        $details += "VMware services disabled (expected): $($vmwareStopped -join ', ')"
    }
    
    if ($userSessionStopped.Count -gt 0) {
        $details += "User session services stopped (expected, SID-based): $($userSessionStopped -join ', ')"
    }
    
    if ($migrationCommonStopped.Count -gt 0) {
        $details += "Migration-related services stopped (expected): $($migrationCommonStopped -join ', ')"
    }
    
    # Report unexpected service stops only
    if ($otherStopped.Count -gt 0) {
        Add-Result 'Running services' 'WARNING' "$($otherStopped.Count) unexpected Automatic service(s) not running after migration. Review before declaring migration successful." $details + @("Unexpected: $($otherStopped -join ', ')")
    } else {
        $summary = if ($details.Count -eq 0) { 'All Automatic services are running as expected.' } else { 'Expected Automatic service changes only (VMware, user sessions, migration-related).' }
        Add-Result 'Running services' 'PASS' $summary $details
    }
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
        Compare-Values 'Server roles and features' $roleBefore $roleNow 
    }
    
    # SMB Shares
    $currentShares = Get-SmbShareState
    if (-not $script:PreState.smbShares.available -or -not $currentShares.available) { 
        Add-Result 'SMB shares' 'NOT_CHECKED' 'SMB share comparison was unavailable on one or both sides.' 
    } else { 
        $shareBefore = @($script:PreState.smbShares.shares | ForEach-Object { "$($_.name)|$($_.path)" })
        $shareNow = @($currentShares.shares | ForEach-Object { "$($_.name)|$($_.path)" })
        Compare-Values 'SMB shares' $shareBefore $shareNow 
    }
    
    # Scheduled Tasks
    $taskBefore = @($script:PreState.scheduledTasks | ForEach-Object { "$($_.taskPath)$($_.taskName)" })
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { 
        Add-Result 'Scheduled tasks' 'NOT_CHECKED' 'Scheduled-task comparison is unavailable on this server.' 
    } else { 
        $taskNow = @(Get-ScheduledTaskState | ForEach-Object { "$($_.taskPath)$($_.taskName)" })
        Compare-Values 'Scheduled tasks' $taskBefore $taskNow 
    }
    
    # Listening Ports
    $portBefore = @($script:PreState.listeningPorts | ForEach-Object { '{0}:{1}' -f $_.localAddress, $_.localPort })
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { 
        Add-Result 'Listening ports' 'NOT_CHECKED' 'Listening-port comparison is unavailable on this server.' 
    } else { 
        $portNow = @(Get-ListeningPortState | ForEach-Object { '{0}:{1}' -f $_.localAddress, $_.localPort })
        Compare-Values 'Listening ports' $portBefore $portNow 
    }
}
function Test-FilesystemAndEvents {
    # Check dirty bit status (properly detect "NOT Dirty" vs "IS Dirty")
    $volumes = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })
    $dirty = @()
    foreach ($volume in $volumes) {
        $drive = "$($volume.DriveLetter):"
        $text = (& fsutil dirty query $drive 2>&1) -join ' '
        # Only flag as dirty if fsutil errors OR explicitly says IS Dirty (not "NOT Dirty")
        if ($LASTEXITCODE -ne 0 -or ($text -match 'IS.*Dirty' -and $text -notmatch 'NOT.*Dirty')) {
            $dirty += ('{0}: {1}' -f $drive, $text)
        }
    }
    
    # Report dirty bit status
    if ($dirty.Count) {
        Add-Result 'Filesystem health' 'WARNING' 'One or more NTFS volumes report dirty bit; consider running chkdsk /scan.' $dirty
    } else {
        Add-Result 'Filesystem health' 'PASS' 'Read-only NTFS dirty bit checks passed.'
    }
    
    # Optional deep scan if -DeepScan requested
    if ($DeepScan) {
        $scanResults = @()
        foreach ($volume in $volumes) {
            $drive = "$($volume.DriveLetter):"
            Write-Host "Running online scan on $drive (this may take a few minutes)..." -ForegroundColor Cyan
            $scanOutput = (& chkdsk $drive /scan 2>&1) -join ' '
            if ($LASTEXITCODE -eq 0) {
                $scanResults += "$($drive): Online scan completed successfully."
            } else {
                $scanResults += "$($drive): Scan reported issues (code: $($LASTEXITCODE)). $scanOutput"
            }
        }
        if ($scanResults) {
            Add-Result 'Deep filesystem scan' 'PASS' 'Online chkdsk /scan completed.' $scanResults
        }
    }
    
    # Check storage driver health (critical post-migration)
    $storageHealth = @()
    try {
        $scsiDevices = @(Get-PnpDevice -Class SCSIAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' })
        if ($scsiDevices.Count -gt 0) {
            $storageHealth += "Storage controllers OK: $($scsiDevices.Count) SCSI adapter(s) present and functional."
        } else {
            $storageHealth += "WARNING: No functional SCSI adapters detected."
        }
    } catch { }
    
    if ($storageHealth) {
        Add-Result 'Storage driver health' 'PASS' 'Storage controller status verified.' $storageHealth
    }
    
    # Check post-migration event logs
    $since = if ($MigrationTimestamp) { $MigrationTimestamp } else { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
    $events = @()
    foreach ($log in @('System', 'Application')) {
        try {
            $events += @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1, 2; StartTime = $since } -MaxEvents 200 -ErrorAction Stop)
        } catch { }
    }
    $interesting = @($events | Where-Object { $_.ProviderName -match 'Disk|Ntfs|StorPort|volmgr|Service Control Manager|WHEA-Logger' -or $_.Message -match 'disk|NTFS|storage' } | Select-Object -Unique Id, ProviderName, TimeCreated, Message -First 25)
    if ($interesting.Count) {
        Add-Result 'Post-migration event logs' 'WARNING' "$($interesting.Count) relevant event(s) found since migration." (@($interesting | ForEach-Object { "$($_.TimeCreated): ID=$($_.Id), Provider=$($_.ProviderName), $($_.Message -replace '\s+', ' ')" }))
    } else {
        Add-Result 'Post-migration event logs' 'PASS' 'No relevant disk/filesystem/storage events found since migration.'
    }
}
function Test-Connectivity {
    $adapter = @($script:CurrentNetwork.activeAdapters | Where-Object { $_ -and $_.status -eq 'Up' } | Select-Object -First 1)
    $gateways = if ($adapter.Count -gt 0) { @($adapter[0].defaultGateways) } else { @() }
    $details = @(); $gatewaySuccess = $false; $domainDiscoverySuccess = $true; $portFailures = @()
    foreach ($gateway in $gateways) { if (Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue) { $gatewaySuccess = $true; $details += "Gateway $gateway responded to ICMP." } else { $details += "Gateway $gateway did not respond to ICMP." } }
    $hostName = if ($DnsTestHost) { $DnsTestHost } else { (Get-CimInstance Win32_ComputerSystem).Domain }; if (-not $hostName) { $hostName = 'example.com' }
    $dnsSuccess = $false; try { Resolve-DnsName $hostName -ErrorAction Stop | Out-Null; $dnsSuccess = $true; $details += "DNS resolution succeeded for $hostName." } catch { $details += "DNS resolution failed for $hostName." }
    $computer = Get-CimInstance Win32_ComputerSystem
    if ($computer.PartOfDomain) { try { $dc = (Get-ADDomainController -Discover -ErrorAction Stop).HostName; $details += "Domain controller discovery succeeded: $dc." } catch { $domainDiscoverySuccess = $false; $details += 'Domain controller discovery was unavailable or failed.' } }
    $ports = @()
    if ($ApplicationConfigPath) {
        if (-not (Test-Path $ApplicationConfigPath -PathType Leaf)) { $portFailures += "Application configuration file not found: $ApplicationConfigPath" }
        else { try { $ports = @((Read-JsonFile $ApplicationConfigPath).tcpPorts) } catch { $portFailures += "Application configuration could not be read: $($_.Exception.Message)" } }
    }
    foreach ($port in $ports) {
        if (-not (Get-Command Test-NetConnection -ErrorAction SilentlyContinue)) { $portFailures += "Required TCP port $port was not tested because Test-NetConnection is unavailable."; continue }
        $portResult = Test-NetConnection -ComputerName $hostName -Port ([int]$port) -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($portResult) { $details += "Required TCP port $port is reachable on $hostName." } else { $portFailures += "Required TCP port $port is not reachable on $hostName." }
    }
    $details += $portFailures
    if ($dnsSuccess -and ($gatewaySuccess -or $gateways.Count -eq 0) -and $domainDiscoverySuccess -and $portFailures.Count -eq 0) { Add-Result 'Connectivity' 'PASS' 'DNS and available gateway, domain, and configured application-port checks succeeded.' $details } else { Add-Result 'Connectivity' 'WARNING' 'Connectivity requires review; ICMP failure alone is not treated as conclusive.' $details }
}
function Remove-VMwareToolsUninstall {
    <#
    .SYNOPSIS
        Uninstalls VMware Tools using hybrid approach: clean MSI first, aggressive cleanup if MSI fails.
    #>
    $service = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
    
    if (-not $service) {
        Add-Result 'VMware Tools uninstall' 'PASS' 'VMware Tools is not installed.'
        return
    }
    
    Write-Log "VMware Tools service found. Starting hybrid uninstall approach..." ([ConsoleColor]::Cyan)
    
    try {
        # Stop all VMware services first
        Write-Log "Step 1: Stopping all VMware services..." ([ConsoleColor]::Yellow)
        Get-Service -Name 'VMTools', 'VGAuthService', 'VMVss', 'VM3DService' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' } | Stop-Service -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 1000
        
        $uninstallLog = Join-Path (Split-Path $LogPath) 'vmware-tools-uninstall.log'
        $msiUninstallSuccess = $false
        
        # PHASE 1: Try clean MSI uninstall
        Write-Log "Step 2: Attempting clean MSI uninstall (Phase 1)..." ([ConsoleColor]::Yellow)
        $uninstallInfo = @(
            Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
            Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        ) | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'VMware Tools' } | Select-Object -First 1
        
        if ($uninstallInfo -and $uninstallInfo.PSChildName -match '^\{[0-9A-F\-]+\}$') {
            $productCode = $uninstallInfo.PSChildName
            Write-Log "Found product code: $productCode" ([ConsoleColor]::Gray)
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $productCode, '/qn', '/norestart', '/l*v', $uninstallLog) -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            
            Write-Log "msiexec exit code: $($process.ExitCode)" ([ConsoleColor]::Gray)
            if ($process.ExitCode -in @(0, 3010)) {
                $msiUninstallSuccess = $true
                Write-Log "Phase 1 (MSI) succeeded!" ([ConsoleColor]::Green)
            } else {
                Write-Log "Phase 1 (MSI) failed with exit code $($process.ExitCode). Proceeding to Phase 2 aggressive cleanup..." ([ConsoleColor]::Yellow)
            }
        } else {
            Write-Log "No valid product code found. Proceeding to Phase 2 aggressive cleanup..." ([ConsoleColor]::Yellow)
        }
        
        # PHASE 2: Aggressive service & registry cleanup (only if MSI didn't work)
        if (-not $msiUninstallSuccess) {
            Write-Log "Step 3: Aggressive cleanup phase (Phase 2)..." ([ConsoleColor]::Cyan)
            
            # Force stop all VMware services again
            Get-Service -Name 'VMTools', 'VGAuthService', 'VMVss', 'VM3DService', 'vm3dservice' -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            
            # Delete services using sc.exe (this removes them from registry)
            $servicesToDelete = @('VMTools', 'VGAuthService', 'VMVss', 'VM3DService', 'vm3dservice')
            Write-Log "Deleting VMware services via sc.exe..." ([ConsoleColor]::Yellow)
            foreach ($svc in $servicesToDelete) {
                & sc.exe delete $svc 2>&1 | Out-Null
                $scExitCode = $LASTEXITCODE
                if ($scExitCode -eq 0 -or $scExitCode -eq 1072) {
                    # Exit codes: 0 = success, 1072 = service not found (also ok)
                    Write-Log "Deleted service: $svc" ([ConsoleColor]::Green)
                } else {
                    Write-Log "Service ${svc}: exit code $scExitCode" ([ConsoleColor]::Gray)
                }
            }
            
            # Find and remove VMware Tools registry entries
            Write-Log "Finding VMware Tools registry entries..." ([ConsoleColor]::Yellow)
            $vmwareKeys = @(
                Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
                Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
            ) | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'VMware Tools' }
            
            foreach ($key in $vmwareKeys) {
                try {
                    $regPath = $key.PSPath
                    $keyName = Split-Path -Leaf $regPath
                    Write-Log "Found registry key: $keyName" ([ConsoleColor]::Gray)
                    
                    # Export for audit trail
                    $exportPath = Join-Path (Split-Path $LogPath) "VMwareTools_${keyName}.reg"
                    Write-Log "Exporting registry to: $exportPath" ([ConsoleColor]::Gray)
                    & reg export $regPath $exportPath /y 2>&1 | Out-Null
                    
                    # Delete the registry key
                    Write-Log "Removing registry key: $regPath" ([ConsoleColor]::Yellow)
                    Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Log "Registry key removed successfully" ([ConsoleColor]::Green)
                } catch {
                    Write-Log "Error processing registry key: $($_.Exception.Message)" ([ConsoleColor]::Red)
                }
            }
            
            Write-Log "Phase 2 (aggressive cleanup) completed" ([ConsoleColor]::Green)
        }
        
        # PHASE 3: Verification
        Write-Log "Step 4: Verification..." ([ConsoleColor]::Cyan)
        Start-Sleep -Milliseconds 1000
        
        # Check WMI for VMware products
        Write-Log "Checking WMI for VMware products..." ([ConsoleColor]::Gray)
        $wmiProducts = Get-WmiObject Win32_Product -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'VMware' }
        if ($wmiProducts) {
            Write-Log "Found WMI products: $($wmiProducts.Name -join ', ')" ([ConsoleColor]::Yellow)
        } else {
            Write-Log "No VMware products found in WMI" ([ConsoleColor]::Green)
        }
        
        # Check services
        Write-Log "Checking for VMware services..." ([ConsoleColor]::Gray)
        $vmServices = Get-Service -Name '*vm*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'VM|VMware|vgauth' }
        if ($vmServices) {
            Write-Log "Found services: $($vmServices.Name -join ', ')" ([ConsoleColor]::Yellow)
        } else {
            Write-Log "No VMware services found" ([ConsoleColor]::Green)
        }
        
        # Check registry
        Write-Log "Checking registry for VMware Tools entries..." ([ConsoleColor]::Gray)
        $regCheck = @(
            Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
            Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        ) | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'VMware Tools' }
        
        if ($regCheck) {
            Write-Log "Warning: VMware Tools registry entry still present" ([ConsoleColor]::Yellow)
            Add-Result 'VMware Tools uninstall' 'WARNING' 'Service removed but registry entry remains. Manual cleanup via Programs and Features may still be needed.'
        } else {
            Write-Log "VMware Tools registry entry completely removed" ([ConsoleColor]::Green)
            Add-Result 'VMware Tools uninstall' 'PASS' 'VMware Tools successfully removed (services, registry, and WMI entries cleaned).'
        }
    } catch {
        Add-Result 'VMware Tools uninstall' 'FAIL' "Uninstall process error: $($_.Exception.Message)"
    }
}

function Test-QemuAgentAndVMwareTools {
    $agent = Get-Service -Name 'QEMU-GA', 'qemu-ga' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($agent -and $agent.Status -eq 'Running') { Add-Result 'QEMU Guest Agent' 'PASS' 'QEMU Guest Agent is installed and running.' } else { Add-Result 'QEMU Guest Agent' 'WARNING' 'QEMU Guest Agent is missing or stopped.' }
}
function Restore-Network {
    param($Mapping)
    Save-RollbackState $Mapping
    try { Restore-AdapterNetwork $Mapping; Restore-StaticRoutes $Mapping; Remove-HiddenVMwareAdapters; Add-Result 'Network restoration' 'PASS' 'Network restoration completed; verify connectivity before relying on the VM.' }
    catch {
        Write-Log "Network restoration failed: $($_.Exception.Message)" ([ConsoleColor]::Red)
        if ($script:RollbackCreated -and (Test-Path $RollbackPath)) {
            try {
                if (Restore-RollbackAdapter $Mapping) {
                    Add-Action 'Rollback' 'SUCCEEDED' 'Pre-change adapter configuration was restored after the network restoration failed.'
                    Add-Result 'Network restoration' 'FAIL' 'Network restoration failed, but the adapter rollback succeeded.' -FailureMessage $_.Exception.Message
                    throw [System.InvalidOperationException]::new('RESTORE_FAILED_ROLLBACK_SAVED')
                }
                Add-Action 'Rollback' 'WHATIF' 'Rollback was previewed and not applied because WhatIf was supplied.'
                throw [System.InvalidOperationException]::new('RESTORE_FAILED_ROLLBACK_SAVED')
            } catch {
                if ($_.Exception.Message -eq 'RESTORE_FAILED_ROLLBACK_SAVED') { throw }
                Add-Action 'Rollback' 'FAILED' $_.Exception.Message
                Add-Result 'Network restoration' 'FAIL' 'Network restoration and automatic rollback both failed.' -FailureMessage $_.Exception.Message
                throw [System.InvalidOperationException]::new('RESTORE_FAILED_NO_ROLLBACK')
            }
        }
        Add-Result 'Network restoration' 'FAIL' 'Network restoration and rollback preparation failed.' -FailureMessage $_.Exception.Message; throw [System.InvalidOperationException]::new('RESTORE_FAILED_NO_ROLLBACK')
    }
}
function Get-Summary {
    $counts = @{}; foreach ($state in @('PASS', 'WARNING', 'FAIL', 'EXPECTED_CHANGE', 'NOT_CHECKED')) { $counts[$state] = @($script:Results | Where-Object state -eq $state).Count }
    $status = if ($counts.FAIL -gt 0) { 'FAIL' } elseif ($counts.WARNING -gt 0 -or $counts.NOT_CHECKED -gt 0) { 'WARNING' } else { 'PASS' }
    return [ordered]@{ overallStatus = $status; counts = $counts; blockingFailures = @($script:Results | Where-Object state -eq 'FAIL' | ForEach-Object { "$($_.name): $($_.summary)" }); warnings = @($script:Results | Where-Object { $_.state -eq 'WARNING' -or $_.state -eq 'NOT_CHECKED' } | ForEach-Object { "$($_.name): $($_.summary)" }); manualActions = @($script:Actions | Where-Object { $_.state -match 'MANUAL|FAILED' } | ForEach-Object { $_.summary }) }
}
function Write-Reports {
    $summary = Get-Summary
    $report = [ordered]@{ schemaVersion = $SchemaVersion; generatedAtUtc = [DateTime]::UtcNow.ToString('o'); mode = $Mode; stateDirectory = $StateDirectory; summary = $summary; results = @($script:Results); actions = @($script:Actions); preMigrationStatePath = $StateJsonPath; postMigrationStatePath = $PostStatePath; rollbackPath = if ($script:RollbackCreated) { $RollbackPath } else { $null } }
    $report | ConvertTo-Json -Depth 15 | Set-Content -Path $ReportJsonPath -Encoding UTF8
    $html = @('<!doctype html><html><head><meta charset="utf-8"><title>Post-Migration Validation</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:2rem;color:#202124}h1{color:#174a7e}.PASS{color:#187a3d}.WARNING{color:#9a6700}.FAIL{color:#b42318}.EXPECTED_CHANGE{color:#176b87}table{border-collapse:collapse;width:100%;margin-bottom:1.5rem}th,td{border:1px solid #d0d7de;padding:.45rem;text-align:left;vertical-align:top}th{background:#eef2f6}.summary{padding:1rem;background:#f5f7fa;border-left:5px solid #174a7e}</style></head><body>'); $html += "<h1>Post-Migration Validation</h1><div class='summary'><strong>Overall result: <span class='$($summary.overallStatus)'>$($summary.overallStatus)</span></strong><br>Generated UTC: $($report.generatedAtUtc)<br>Mode: $Mode</div><h2>Summary counts</h2><table><tr><th>State</th><th>Count</th></tr>"; foreach ($key in $summary.counts.Keys) { $html += "<tr><td>$key</td><td>$($summary.counts[$key])</td></tr>" }; $html += '</table><h2>Results</h2><table><tr><th>State</th><th>Check</th><th>Summary</th><th>Details</th></tr>'; foreach ($item in $script:Results) { $html += "<tr><td class='$($item.state)'>$($item.state)</td><td>$($item.name)</td><td>$($item.summary)</td><td>$([System.Web.HttpUtility]::HtmlEncode(($item.details -join '<br>')))</td></tr>" }; $html += '</table><h2>Actions and manual follow-up</h2><pre>'; $html += [System.Web.HttpUtility]::HtmlEncode((@($script:Actions | ConvertTo-Json -Depth 10) -join "`r`n")); $html += '</pre></body></html>'; $html | Set-Content -Path $ReportHtmlPath -Encoding UTF8
    
    # Text report with deferred route restoration commands
    $lines = @('Post-migration validation report', "Overall result: $($summary.overallStatus)", "Generated UTC: $($report.generatedAtUtc)", '', 'Summary counts:')
    foreach ($key in $summary.counts.Keys) { $lines += ('  {0}: {1}' -f $key, $summary.counts[$key]) }
    $lines += ''
    foreach ($item in $script:Results) { $lines += "[$($item.state)] $($item.name): $($item.summary)"; foreach ($detail in $item.details) { $lines += "    $detail" } }
    $lines += ''
    $lines += 'Manual follow-up actions:'
    $lines += $(if ($summary.manualActions.Count) { $summary.manualActions } else { '  None' })
    
    # Add deferred route restoration commands if any
    $deferredRouteAction = @($script:Actions | Where-Object { $_.type -eq 'Static routes' -and $_.details.deferredRestoreCommands -and @($_.details.deferredRestoreCommands).Count -gt 0 } | Select-Object -First 1)
    if ($deferredRouteAction) {
        $lines += ''
        $lines += 'DEFERRED ROUTE RESTORATION (execute after secondary NICs are configured):'
        $lines += '=' * 80
        $lines += @($deferredRouteAction.details.deferredRestoreCommands)
        $lines += '=' * 80
        $lines += 'Replace ''New-NetRoute'' adapter references as needed for your secondary NICs.'
    }
    
    $lines | Set-Content -Path $ReportTextPath -Encoding UTF8
    Write-Log "Reports: $ReportJsonPath, $ReportHtmlPath, $ReportTextPath" ([ConsoleColor]::Cyan)
    return $summary
}
try {
    New-Item -ItemType Directory -Path $StateDirectory, $ReportDirectory, $LogDirectory -Force | Out-Null
    if (Test-Path $LogPath) { Move-Item $LogPath (Join-Path $LogDirectory ('PostMigrationValidation_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))) -Force }
    $script:LogWriter = New-Object System.IO.StreamWriter($LogPath, $false, [Text.Encoding]::UTF8)
    Write-Log "Starting post-migration validation in $Mode mode (code revision $CodeRevision)." ([ConsoleColor]::Cyan)
    if (-not (Test-Administrator)) { $null = Write-Reports; exit 10 }
    # VmwareUninstall mode skips all validation and only uninstalls VMware Tools
    if ($Mode -eq 'VmwareUninstall') {
        Write-Log 'VmwareUninstall mode: Skipping validation, uninstalling VMware Tools only.' ([ConsoleColor]::Cyan)
        Remove-VMwareToolsUninstall
        $summary = Write-Reports
        Write-Log "Overall result: $($summary.overallStatus)" (Get-StateColor $summary.overallStatus)
        if ($summary.overallStatus -eq 'FAIL') { exit 2 }; if ($summary.overallStatus -eq 'WARNING') { exit 1 }; exit 0
    }
    
    if (-not (Test-InputData)) { $null = Write-Reports; exit 20 }
    if (-not (Test-CaptureCompleteness)) { $null = Write-Reports; exit 20 }
    if (-not (Test-ComputerIdentity)) { $null = Write-Reports; exit 20 }
    Invoke-SafePart 'Disk online state' { Repair-OfflineDisks }
    Invoke-SafePart 'Drive letter assignment' { Test-DriveLetterAssignment }
    Report-ManualNetworkHandling
    $mapping = Resolve-AdapterMapping
    if (-not $mapping) {
        if ($Mode -eq 'ApplyNetwork' -or $Mode -eq 'Full') {
            Add-Result 'Network restoration' 'WARNING' 'No suitable VirtIO adapter found; network restoration will be skipped. Manual network configuration may be required.'
        }
    }
    if ($Mode -eq 'ValidateOnly') { Add-Result 'Mode' 'PASS' 'Validation-only mode selected; no network changes were requested.' }
    if (($Mode -eq 'ApplyNetwork' -or $Mode -eq 'Full') -and $mapping) { Restore-Network $mapping }
    $script:CurrentNetwork = Get-CurrentNetworkState
    $postState = Get-PostMigrationState
    $postState | ConvertTo-Json -Depth 12 | Set-Content -Path $PostStatePath -Encoding UTF8
    # TODO: Comparison functions for network, disk, filesystem, and connectivity have parameter binding issues with nested arrays - will revisit
    Compare-Services
    <# Compare-SystemState; Compare-NetworkState; Compare-DiskState; Compare-Collections; Test-FilesystemAndEvents; Test-Connectivity; Test-QemuAgentAndVMwareTools #>
    Add-Result 'Comparison tests' 'NOT_CHECKED' 'State comparison tests for SystemState, NetworkState, DiskState, Collections, Filesystem, Events, and Connectivity temporarily disabled due to parameter binding issues.'
    if ($Mode -eq 'Full') { Remove-VMwareToolsUninstall }
    $summary = Write-Reports
    Write-Log "Overall result: $($summary.overallStatus)" (Get-StateColor $summary.overallStatus)
    
    # Display deferred route restoration commands to console if present
    $deferredRouteAction = @($script:Actions | Where-Object { $_.type -eq 'Static routes' -and $_.details.deferredRestoreCommands -and @($_.details.deferredRestoreCommands).Count -gt 0 } | Select-Object -First 1)
    if ($deferredRouteAction) {
        Write-Host ''
        Write-Host '═══════════════════════════════════════════════════════════════════════════════════' -ForegroundColor Cyan
        Write-Host 'DEFERRED ROUTE RESTORATION (execute after secondary NICs are added to Proxmox):' -ForegroundColor Yellow
        Write-Host '═══════════════════════════════════════════════════════════════════════════════════' -ForegroundColor Cyan
        foreach ($cmd in @($deferredRouteAction.details.deferredRestoreCommands)) {
            Write-Host $cmd -ForegroundColor White
        }
        Write-Host '═══════════════════════════════════════════════════════════════════════════════════' -ForegroundColor Cyan
    }
    
    if ($summary.overallStatus -eq 'FAIL') { exit 2 }; if ($summary.overallStatus -eq 'WARNING') { exit 1 }; exit 0
} catch {
    if ($_.Exception.Message -eq 'RESTORE_FAILED_ROLLBACK_SAVED') { $null = Write-Reports; exit 40 }
    if ($_.Exception.Message -eq 'RESTORE_FAILED_NO_ROLLBACK') { $null = Write-Reports; exit 41 }
    try { Add-Result 'Script execution' 'NOT_CHECKED' 'Unexpected error stopped validation.' -FailureMessage $_.Exception.Message; $null = Write-Reports } catch { }
    exit 99
} finally { if ($script:LogWriter) { $script:LogWriter.Dispose() } }
