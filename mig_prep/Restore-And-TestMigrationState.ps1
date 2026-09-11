<#
.SYNOPSIS
    Restores and validates migration state after a VMware-to-Proxmox Veeam restore.

.DESCRIPTION
    Reads Export-MigrationState.ps1 output, safely maps the former VMware NIC to a
    single VirtIO adapter, optionally restores IPv4/DNS/routes, removes only clearly
    identified non-present VMware adapters, and compares current state with the capture.
    Networking is never changed in ValidateOnly or CompareOnly mode. Every modifying
    operation is guarded by ShouldProcess and therefore supports -WhatIf and -Confirm.

.PARAMETER StateDirectory
    Directory containing PreMigrationState.json and NetworkConfiguration.json.

.PARAMETER Mode
    ValidateOnly (default), ApplyNetwork, CompareOnly, or Full.

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
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$StateDirectory = 'C:\Migration\State',
    [ValidateSet('ValidateOnly', 'ApplyNetwork', 'CompareOnly', 'Full')]
    [string]$Mode = 'ValidateOnly',
    [switch]$Force,
    [string]$DnsTestHost = '',
    [string]$ApplicationConfigPath = '',
    [datetime]$MigrationTimestamp
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$RootPath = 'C:\Migration'
$ReportDirectory = Join-Path $RootPath 'Reports'
$LogDirectory = Join-Path $RootPath 'Logs'
$LogPath = Join-Path $LogDirectory 'PostMigrationValidation.log'
$StateJsonPath = Join-Path $StateDirectory 'PreMigrationState.json'
$NetworkJsonPath = Join-Path $StateDirectory 'NetworkConfiguration.json'
$RollbackPath = Join-Path $StateDirectory 'PreNetworkChangeRollback.json'
$PostStatePath = Join-Path $StateDirectory 'PostMigrationState.json'
$ReportJsonPath = Join-Path $ReportDirectory 'PostMigrationReport.json'
$ReportHtmlPath = Join-Path $ReportDirectory 'PostMigrationReport.html'
$ReportTextPath = Join-Path $ReportDirectory 'PostMigrationReport.txt'
$SchemaVersion = '1.0'
# Fixed internal build stamp to verify which copy is deployed on a target machine.
$CodeRevision = '2026-09-11.2'
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
        if (-not $script:PreState.systemIdentity.computerName) { throw 'The pre-migration computer name is missing.' }
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
function Get-AdapterRecord {
    param($Adapter)
    $config = Get-NetIPConfiguration -InterfaceIndex $Adapter.ifIndex -ErrorAction SilentlyContinue
    $ip = @(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object AddressState -eq 'Preferred')
    $dnsClient = Get-DnsClient -InterfaceIndex $Adapter.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1
    $dns = @(Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ServerAddresses)
    $ipInterface = Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    [pscustomobject][ordered]@{
        adapterName = $Adapter.Name; interfaceAlias = $Adapter.Name; interfaceDescription = $Adapter.InterfaceDescription; interfaceIndex = [int]$Adapter.ifIndex; interfaceGuid = $Adapter.InterfaceGuid; macAddress = $Adapter.MacAddress; linkSpeed = $Adapter.LinkSpeed; status = $Adapter.Status.ToString();
        dhcpEnabled = [bool]($ipInterface -and $ipInterface.Dhcp -eq 'Enabled'); ipv4Addresses = @($ip | ForEach-Object { [pscustomobject][ordered]@{ address = $_.IPAddress; prefixLength = [int]$_.PrefixLength } }); defaultGateways = @($config.IPv4DefaultGateway | ForEach-Object NextHop); dnsServers = @($dns); dnsSuffix = if ($dnsClient) { $dnsClient.ConnectionSpecificSuffix } else { $null }; registerThisConnectionAddress = if ($dnsClient) { $dnsClient.RegisterThisConnectionsAddress } else { $null }; useSuffixWhenRegistering = if ($dnsClient) { $dnsClient.UseSuffixWhenRegistering } else { $null }; interfaceMetric = if ($ipInterface) { [int]$ipInterface.InterfaceMetric } else { 0 }
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
        $pnpItem = $pnp | Where-Object InstanceId -eq $adapter.PnPDeviceID | Select-Object -First 1
        $driverProvider = if ($driver) { [string]$driver[0].DriverProviderName } else { '' }
        $driverVersion = if ($driver) { [string]$driver[0].DriverVersion } else { '' }
        $pnpFriendlyName = if ($pnpItem) { [string]$pnpItem.FriendlyName } else { '' }
        $text = "$($adapter.InterfaceDescription) $driverProvider $($adapter.PnPDeviceID) $pnpFriendlyName"
        $isVirtio = $text -match 'VirtIO|NetKVM|Red Hat|1AF4|VEN_1AF4'
        $records += [pscustomobject][ordered]@{ adapter = Get-AdapterRecord $adapter; isVirtIO = [bool]$isVirtio; driverProvider = $driverProvider; driverVersion = $driverVersion; pnpFriendlyName = $pnpFriendlyName; pnpInstanceId = $adapter.PnPDeviceID }
    }
    return @($records)
}
function Resolve-AdapterMapping {
    $old = @($script:PreNetwork.activeAdapters)
    $candidates = @(Find-VirtIOAdapters)
    $activeAdapters = @($candidates | Where-Object { $_.adapter.status -eq 'Up' })
    if ($old.Count -ne 1) { Add-Result 'Adapter mapping' 'FAIL' "Pre-migration capture contains $($old.Count) active adapters; automatic mapping requires exactly one."; return $null }
    $virtio = @($candidates | Where-Object isVirtIO)
    $activeVirtio = @($virtio | Where-Object { $_.adapter.status -eq 'Up' })
    if ($activeAdapters.Count -ne 1 -or $activeVirtio.Count -ne 1) {
        $details = @($candidates | ForEach-Object { "Name=$($_.adapter.adapterName), Description=$($_.adapter.interfaceDescription), Status=$($_.adapter.status), VirtIO=$($_.isVirtIO), Provider=$($_.driverProvider), PnP=$($_.pnpFriendlyName)" })
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
            $defaultRoute = @($script:PreNetwork.ipv4Routes | Where-Object isDefaultRoute | Sort-Object routeMetric | Select-Object -First 1)
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
    $restored = @(); $skipped = @(); $review = @()
    foreach ($route in $routes) {
        if ($route.nextHop -eq '0.0.0.0' -or $route.nextHop -eq '::') { $skipped += ('{0}: invalid next hop' -f $route.destinationPrefix); continue }
        if (Get-NetRoute -DestinationPrefix $route.destinationPrefix -NextHop $route.nextHop -ErrorAction SilentlyContinue) { $skipped += "$($route.destinationPrefix) via $($route.nextHop): already present"; continue }
        if (-not $PSCmdlet.ShouldProcess("$($route.destinationPrefix) via $($route.nextHop)", 'Restore static route')) { $review += "$($route.destinationPrefix) via $($route.nextHop): WhatIf"; continue }
        try { New-NetRoute -DestinationPrefix $route.destinationPrefix -NextHop $route.nextHop -InterfaceIndex $Mapping.target.adapter.interfaceIndex -RouteMetric $route.routeMetric -Confirm:$false | Out-Null; $restored += "$($route.destinationPrefix) via $($route.nextHop)" } catch { $review += "$($route.destinationPrefix): $($_.Exception.Message)" }
    }
    $state = if ($review.Count) { 'MANUAL_REVIEW' } else { 'COMPLETED' }
    Add-Action 'Static routes' $state 'Static route restoration evaluated.' ([ordered]@{ restored = @($restored); skipped = @($skipped); manualReview = @($review) })
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
        Get-NetIPAddress -InterfaceIndex $target.interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object PrefixOrigin -ne 'WellKnown' | Remove-NetIPAddress -Confirm:$false -ErrorAction Stop
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
        runningServices = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object State -eq 'Running' | ForEach-Object Name)
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
    Compare-Values 'Default gateways' (@($script:PreNetwork.activeAdapters | ForEach-Object defaultGateways)) (@($script:CurrentNetwork.activeAdapters | ForEach-Object defaultGateways))
    Compare-Values 'DNS servers' (@($script:PreNetwork.activeAdapters | ForEach-Object dnsServers)) (@($script:CurrentNetwork.activeAdapters | ForEach-Object dnsServers))
    Compare-Values 'Adapter hardware identity' (@($script:PreNetwork.activeAdapters | ForEach-Object { $_.macAddress })) (@($script:CurrentNetwork.activeAdapters | ForEach-Object { $_.macAddress })) $true
    Compare-Values 'Static routes' (@($script:PreNetwork.ipv4Routes | Where-Object { -not $_.isConnectedRoute -and -not $_.isDefaultRoute } | ForEach-Object { "$($_.destinationPrefix)|$($_.nextHop)" })) (@($script:CurrentNetwork.ipv4Routes | Where-Object { -not $_.isConnectedRoute -and -not $_.isDefaultRoute } | ForEach-Object { "$($_.destinationPrefix)|$($_.nextHop)" }))
}
function Compare-DiskState {
    $current = @(Get-Disk -ErrorAction Stop); $before = @($script:PreState.disks)
    if ($current.Count -lt $before.Count) { Add-Result 'Disk count' 'FAIL' "Expected at least $($before.Count) disks; found $($current.Count)." } else { Add-Result 'Disk count' 'PASS' "Expected $($before.Count) or more disks found ($($current.Count))." }
    $details = @()
    foreach ($old in $before) { $size = @($current | Where-Object { [math]::Abs($_.Size - $old.sizeBytes) -lt 1GB } | Select-Object -First 1); if ($size) { $details += "Matched disk size $([math]::Round($old.sizeBytes / 1GB, 2)) GB." } else { $details += "No current disk matched expected size $([math]::Round($old.sizeBytes / 1GB, 2)) GB." } }
    if ($details -match 'No current') { Add-Result 'Disk sizes' 'FAIL' 'One or more expected disk sizes were not found.' $details } else { Add-Result 'Disk sizes' 'PASS' 'Expected disk sizes were found.' $details }
    Compare-Values 'Partition and volume layout' (@($script:PreState.partitionsAndVolumes | ForEach-Object { "$($_.driveLetter)|$($_.volumeLabel)|$($_.fileSystem)|$($_.mountPoints -join ',')" })) (@(Get-PartitionVolumeStateForComparison))
}
function Get-PartitionVolumeStateForComparison {
    $output = @(); foreach ($partition in @(Get-Partition -ErrorAction SilentlyContinue)) { $volume = $partition | Get-Volume -ErrorAction SilentlyContinue; $output += "$($volume.DriveLetter)|$($volume.FileSystemLabel)|$($volume.FileSystem)|$($volume.Path)" }; return @($output)
}
function Compare-Services {
    $current = @(Get-CimInstance Win32_Service | Where-Object State -eq 'Running' | ForEach-Object Name); $before = @($script:PreState.services.runningBeforeMigration); $missing = @($before | Where-Object { $_ -notin $current -and $_ -notmatch 'VMTools|VGAuthService' })
    if ($missing.Count) { Add-Result 'Running services' 'WARNING' "$($missing.Count) services running before migration are stopped now." $missing } else { Add-Result 'Running services' 'PASS' 'Services running before migration are still running, excluding VMware Tools differences.' }
}
function Get-RoleFeatureState {
    if (-not (Get-Module -ListAvailable -Name ServerManager)) { return [pscustomobject][ordered]@{ installed = @(); available = $false } }
    try { Import-Module ServerManager -ErrorAction Stop; return [pscustomobject][ordered]@{ installed = @(Get-WindowsFeature -ErrorAction Stop | Where-Object Installed | ForEach-Object Name); available = $true } }
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
    $currentRoles = Get-RoleFeatureState
    if (-not $script:PreState.rolesAndFeatures.available -or -not $currentRoles.available) { Add-Result 'Server roles and features' 'NOT_CHECKED' 'Role comparison was unavailable on one or both sides.' }
    else { $roleBefore = @($script:PreState.rolesAndFeatures.installed | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } }); Compare-Values 'Server roles and features' $roleBefore @($currentRoles.installed) }
    $currentShares = Get-SmbShareState
    if (-not $script:PreState.smbShares.available -or -not $currentShares.available) { Add-Result 'SMB shares' 'NOT_CHECKED' 'SMB share comparison was unavailable on one or both sides.' }
    else { $shareBefore = @($script:PreState.smbShares.shares | ForEach-Object { "$($_.name)|$($_.path)" }); $shareNow = @($currentShares.shares | ForEach-Object { "$($_.name)|$($_.path)" }); Compare-Values 'SMB shares' $shareBefore $shareNow }
    $taskBefore = @($script:PreState.scheduledTasks | ForEach-Object { "$($_.taskPath)$($_.taskName)" }); if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { Add-Result 'Scheduled tasks' 'NOT_CHECKED' 'Scheduled-task comparison is unavailable on this server.' } else { $taskNow = @((Get-ScheduledTaskState) | ForEach-Object { "$($_.taskPath)$($_.taskName)" }); Compare-Values 'Scheduled tasks' $taskBefore $taskNow }
    $portBefore = @($script:PreState.listeningPorts | ForEach-Object { '{0}:{1}' -f $_.localAddress, $_.localPort }); if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { Add-Result 'Listening ports' 'NOT_CHECKED' 'Listening-port comparison is unavailable on this server.' } else { $portNow = @((Get-ListeningPortState) | ForEach-Object { '{0}:{1}' -f $_.localAddress, $_.localPort }); Compare-Values 'Listening ports' $portBefore $portNow }
}
function Test-FilesystemAndEvents {
    $volumes = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' }); $dirty = @(); foreach ($volume in $volumes) { $drive = "$($volume.DriveLetter):"; $text = (& fsutil dirty query $drive 2>&1) -join ' '; if ($LASTEXITCODE -ne 0 -or $text -match 'dirty') { $dirty += ('{0}: {1}' -f $drive, $text) } }
    if ($dirty.Count) { Add-Result 'Filesystem health' 'WARNING' 'One or more NTFS volumes require review; only read-only checks were run.' $dirty } else { Add-Result 'Filesystem health' 'PASS' 'Read-only NTFS checks passed.' }
    $since = if ($MigrationTimestamp) { $MigrationTimestamp } else { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }; $events = @(); foreach ($log in @('System', 'Application')) { try { $events += @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1, 2; StartTime = $since } -MaxEvents 200 -ErrorAction Stop) } catch { } }
    $interesting = @($events | Where-Object { $_.ProviderName -match 'Disk|Ntfs|StorPort|volmgr|Service Control Manager|WHEA-Logger' -or $_.Message -match 'disk|NTFS|storage' } | Select-Object -Unique Id, ProviderName, TimeCreated, Message -First 25); if ($interesting.Count) { Add-Result 'Post-migration event logs' 'WARNING' "$($interesting.Count) relevant event(s) found since migration." (@($interesting | ForEach-Object { "$($_.TimeCreated): ID=$($_.Id), Provider=$($_.ProviderName), $($_.Message -replace '\s+', ' ')" })) } else { Add-Result 'Post-migration event logs' 'PASS' 'No relevant disk/filesystem/storage events found since migration.' }
}
function Test-Connectivity {
    $adapter = @($script:CurrentNetwork.activeAdapters | Where-Object status -eq 'Up' | Select-Object -First 1); $gateways = @($adapter.defaultGateways); $details = @(); $gatewaySuccess = $false; $domainDiscoverySuccess = $true; $portFailures = @()
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
function Test-QemuAgentAndVMwareTools {
    $agent = Get-Service -Name 'QEMU-GA', 'qemu-ga' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($agent -and $agent.Status -eq 'Running') { Add-Result 'QEMU Guest Agent' 'PASS' 'QEMU Guest Agent is installed and running.' } else { Add-Result 'QEMU Guest Agent' 'WARNING' 'QEMU Guest Agent is missing or stopped.' }
    $vmware = Get-Service -Name VMTools -ErrorAction SilentlyContinue; if ($vmware) { Add-Result 'VMware Tools cleanup' 'WARNING' 'VMware Tools remains installed; remove it only as a separate deliberate engineering action.' } else { Add-Result 'VMware Tools cleanup' 'PASS' 'VMware Tools service is not installed.' }
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
    return [ordered]@{ overallStatus = $status; counts = $counts; blockingFailures = @($script:Results | Where-Object state -eq 'FAIL' | ForEach-Object { "$($_.name): $($_.summary)" }); warnings = @($script:Results | Where-Object { $_.state -eq 'WARNING' -or $_.state -eq 'NOT_CHECKED' } | ForEach-Object { "$($_.name): $($_.summary)" }); manualActions = @($script:Actions | Where-Object { $_.state -match 'MANUAL|FAILED' } | ForEach-Object summary) }
}
function Write-Reports {
    $summary = Get-Summary
    $report = [ordered]@{ schemaVersion = $SchemaVersion; generatedAtUtc = [DateTime]::UtcNow.ToString('o'); mode = $Mode; stateDirectory = $StateDirectory; summary = $summary; results = @($script:Results); actions = @($script:Actions); preMigrationStatePath = $StateJsonPath; postMigrationStatePath = $PostStatePath; rollbackPath = if ($script:RollbackCreated) { $RollbackPath } else { $null } }
    $report | ConvertTo-Json -Depth 15 | Set-Content -Path $ReportJsonPath -Encoding UTF8
    $html = @('<!doctype html><html><head><meta charset="utf-8"><title>Post-Migration Validation</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:2rem;color:#202124}h1{color:#174a7e}.PASS{color:#187a3d}.WARNING{color:#9a6700}.FAIL{color:#b42318}.EXPECTED_CHANGE{color:#176b87}table{border-collapse:collapse;width:100%;margin-bottom:1.5rem}th,td{border:1px solid #d0d7de;padding:.45rem;text-align:left;vertical-align:top}th{background:#eef2f6}.summary{padding:1rem;background:#f5f7fa;border-left:5px solid #174a7e}</style></head><body>'); $html += "<h1>Post-Migration Validation</h1><div class='summary'><strong>Overall result: <span class='$($summary.overallStatus)'>$($summary.overallStatus)</span></strong><br>Generated UTC: $($report.generatedAtUtc)<br>Mode: $Mode</div><h2>Summary counts</h2><table><tr><th>State</th><th>Count</th></tr>"; foreach ($key in $summary.counts.Keys) { $html += "<tr><td>$key</td><td>$($summary.counts[$key])</td></tr>" }; $html += '</table><h2>Results</h2><table><tr><th>State</th><th>Check</th><th>Summary</th><th>Details</th></tr>'; foreach ($item in $script:Results) { $html += "<tr><td class='$($item.state)'>$($item.state)</td><td>$($item.name)</td><td>$($item.summary)</td><td>$([System.Web.HttpUtility]::HtmlEncode(($item.details -join '<br>')))</td></tr>" }; $html += '</table><h2>Actions and manual follow-up</h2><pre>'; $html += [System.Web.HttpUtility]::HtmlEncode((@($script:Actions | ConvertTo-Json -Depth 10) -join "`r`n")); $html += '</pre></body></html>'; $html | Set-Content -Path $ReportHtmlPath -Encoding UTF8
    $lines = @('Post-migration validation report', "Overall result: $($summary.overallStatus)", "Generated UTC: $($report.generatedAtUtc)", '', 'Summary counts:'); foreach ($key in $summary.counts.Keys) { $lines += ('  {0}: {1}' -f $key, $summary.counts[$key]) }; $lines += ''; foreach ($item in $script:Results) { $lines += "[$($item.state)] $($item.name): $($item.summary)"; foreach ($detail in $item.details) { $lines += "    $detail" } }; $lines += ''; $lines += 'Manual follow-up actions:'; $lines += $(if ($summary.manualActions.Count) { $summary.manualActions } else { '  None' }); $lines | Set-Content -Path $ReportTextPath -Encoding UTF8
    Write-Log "Reports: $ReportJsonPath, $ReportHtmlPath, $ReportTextPath" ([ConsoleColor]::Cyan)
    return $summary
}
try {
    New-Item -ItemType Directory -Path $StateDirectory, $ReportDirectory, $LogDirectory -Force | Out-Null
    if (Test-Path $LogPath) { Move-Item $LogPath (Join-Path $LogDirectory ('PostMigrationValidation_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))) -Force }
    $script:LogWriter = New-Object System.IO.StreamWriter($LogPath, $false, [Text.Encoding]::UTF8)
    Write-Log "Starting post-migration validation in $Mode mode (code revision $CodeRevision)." ([ConsoleColor]::Cyan)
    if (-not (Test-Administrator)) { $null = Write-Reports; exit 10 }
    if (-not (Test-InputData)) { $null = Write-Reports; exit 20 }
    if (-not (Test-CaptureCompleteness)) { $null = Write-Reports; exit 20 }
    if (-not (Test-ComputerIdentity)) { $null = Write-Reports; exit 20 }
    $mapping = Resolve-AdapterMapping
    if (-not $mapping) { $null = Write-Reports; exit 30 }
    if ($Mode -eq 'ValidateOnly') { Add-Result 'Mode' 'PASS' 'Validation-only mode selected; no network changes were requested.' }
    if ($Mode -eq 'ApplyNetwork' -or $Mode -eq 'Full') { Restore-Network $mapping }
    $script:CurrentNetwork = Get-CurrentNetworkState
    $postState = Get-PostMigrationState
    $postState | ConvertTo-Json -Depth 12 | Set-Content -Path $PostStatePath -Encoding UTF8
    Compare-SystemState; Compare-NetworkState; Compare-DiskState; Compare-Services; Compare-Collections; Test-FilesystemAndEvents; Test-Connectivity; Test-QemuAgentAndVMwareTools
    $summary = Write-Reports
    Write-Log "Overall result: $($summary.overallStatus)" (Get-StateColor $summary.overallStatus)
    if ($summary.overallStatus -eq 'FAIL') { exit 2 }; if ($summary.overallStatus -eq 'WARNING') { exit 1 }; exit 0
} catch {
    if ($_.Exception.Message -eq 'RESTORE_FAILED_ROLLBACK_SAVED') { $null = Write-Reports; exit 40 }
    if ($_.Exception.Message -eq 'RESTORE_FAILED_NO_ROLLBACK') { $null = Write-Reports; exit 41 }
    try { Add-Result 'Script execution' 'NOT_CHECKED' 'Unexpected error stopped validation.' -FailureMessage $_.Exception.Message; $null = Write-Reports } catch { }
    exit 99
} finally { if ($script:LogWriter) { $script:LogWriter.Dispose() } }
